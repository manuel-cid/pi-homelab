# Radarr

## Descripción

Sonarr (`03-sonarr.md`) ya cubre el lado **series** del catálogo: catalogación, búsqueda, encolado en Transmission e import por hardlink. Falta su gemelo para **películas**: añadir un título por nombre, monitorizarlo, encolar la mejor release según un *quality profile*, e importar a la biblioteca con el esquema de nombres que entienda Jellyfin. Esa es la motivación de este documento.

**Radarr** es el *PVR* (Personal Video Recorder) del stack `*arr` para **películas**. Su rol concreto en este homelab:

1. **Mantener el catálogo de películas**: el operador añade una película por nombre o por TMDB ID, Radarr la guarda en su base de datos SQLite con todos sus metadatos (título, año, sinopsis, géneros, *runtime*, lista de releases conocidas), su *quality profile*, su *minimum availability* y su *root folder*.
2. **Monitorizar disponibilidad de releases** consultando a Prowlarr (`http://prowlarr:9696/api/v1/search`) periódicamente — pero solo para películas que han alcanzado el umbral de *minimum availability* (ver "Decisión: minimum availability" abajo). Para cada película monitorizada, evalúa los resultados contra el *quality profile* y descarta lo que no encaje.
3. **Encolar la mejor release** en Transmission (`http://transmission:9091/transmission/rpc`) vía RPC con autenticación HTTP Basic (las mismas credenciales que ya usa el operador desde la UI). Una sola release por película, no por episodio: la unidad atómica en Radarr es la película completa.
4. **Importar al terminar**: cuando Transmission marca un torrent como completo, Radarr lo detecta por polling al RPC, mueve el fichero principal desde `/downloads/complete/<release>/` a `/media/movies/<Movie> (Year)/<Movie> (Year) [Quality].ext` aplicando su esquema de nombres, y crea un **hardlink** en lugar de copiar (origen y destino comparten filesystem en hd2t; ver `01-transmission.md` "Decisión: hardlinks vs copy"). Transmission sigue seedeando el original hasta cumplir ratio; el hardlink en `/media/movies/` queda visible para Jellyfin (Fase 9) inmediatamente.
5. **Reescanear y mantener**: vigila la biblioteca por cambios fuera de su control (ficheros añadidos manualmente, películas borradas), procesa renombres si el operador cambia el esquema, gestiona *upgrades* (sustituir una release 720p por una 1080p si está disponible) y reintenta descargas fallidas.
6. **Exponer una UI web** (`https://radarr.${DOMAIN_LAN}/`) protegida por Authelia 2FA, donde el operador añade películas, ajusta calidades, revisa la cola y diagnostica errores.

Lo que este documento **no** decide:

- **Qué películas ver**: las añade el operador desde la UI según gusto. No se versiona la lista en git.
- **Auto-descarga por listas** (TMDB Popular, IMDb Top 250, Trakt watchlist): Radarr soporta *Lists* en `Settings → Lists`, que añaden películas automáticamente al catálogo. **Desactivado por defecto** en este homelab para no saturar la biblioteca con películas que el operador no eligió. Reabrible: si en el futuro se quiere "auto-bajar todo lo nuevo de Marvel", se documenta entonces.
- **Política de upgrade hasta 4K REMUX**: si el operador prefiere parar en 1080p Bluray o subir hasta UHD-2160p REMUX, lo decide en el *Quality Profile*. Aquí se recomienda un perfil HD-1080p por defecto y se deja UHD-2160p como opcional.
- **Cliente de descarga alternativo**: solo Transmission, ya documentado. Radarr soporta varios; aquí solo se configura uno.
- **Notificaciones a Telegram, Discord, Apprise**: integración existe en `Settings → Connect`, se difiere a un doc transversal de notificaciones (Fase 5/12, no aquí).
- **Subtítulos automáticos** (Bazarr): es un servicio aparte que se acopla a Sonarr/Radarr; no está en el plan actual de la Fase 10. Reabrible.
- **Whisparr / Stash** (películas para adultos): Stash (Fase 9) gestiona ese contenido aparte con su propia ingesta, no se mezcla con Radarr. Cero solapamiento.
- **Apertura al exterior**: como el resto del homelab, Radarr es **solo LAN + tailnet**. Su UI y su API solo se acceden por Caddy con Authelia. Radarr le habla a Prowlarr y a Transmission **directamente al bridge `homelab`** sin pasar por Caddy.

Cuando este documento se haya aplicado, el operador puede:

- Abrir `https://radarr.${DOMAIN_LAN}/` desde la LAN (con CA interna instalada, protegida por Authelia 2FA) o `https://radarr.${DOMAIN_TS}/` desde el tailnet, autenticarse con Authelia y ver la UI de Radarr.
- Tener Prowlarr conectado en *Settings → Indexers* como única fuente, con todos los indexadores activos en Prowlarr replicados automáticamente (sincronizados desde Prowlarr → *Apps* → *Radarr*).
- Tener Transmission conectado en *Settings → Download Clients* con autenticación verificada (Radarr puede listar la cola actual de TR).
- Tener un *Root Folder* configurado en `/media/movies` (bind mount a `/mnt/hd2t/media/movies`), un *Quality Profile* "HD-1080p" por defecto y *Minimum Availability* en `Released` (no se buscan torrents de películas que aún están en cines).
- Añadir una película de prueba (p. ej. *Big Buck Bunny*, *Sintel*, o cualquiera disponible en los indexadores), monitorizarla, y observar el ciclo completo: búsqueda → encolado en TR → descarga → import por hardlink → aparición en `/mnt/hd2t/media/movies/...` con el esquema de nombres aplicado.
- Tener `/mnt/hd2t/apps/radarr/config/` respaldado por Borgmatic (`config.xml`, `radarr.db`, `Backups/`), excluyendo `MediaCover/` y `logs/`.

> **Recordatorio de alcance**: el tráfico saliente que genera Radarr (consultas a TMDB, búsquedas vía Prowlarr a indexadores, `.torrent` descargados antes de pasarlos a TR) sale por HTTPS estándar. No requiere apertura de puertos entrantes. La política del homelab (no port-forwarding) se mantiene intacta.

---

## Requisitos Previos

- **Fase 0–1** completas: discos `hd2t` montado en `/mnt/hd2t`, grupo `media` con GID `1100`, usuario `homelab` (UID 1000) miembro del grupo, estructura `/mnt/hd2t/media/movies/` con owner `homelab:media` y modo `2770` (setgid). Ver `01-sistema/04-estructura-directorios.md`.
- **Fase 2** completa: Docker Engine + Compose v2; red `homelab` en `172.30.10.0/24`; convenciones `stacks/<svc>/`; `.env` global con `TZ=Europe/Madrid`, `PUID=1000`, `PGID=1000`, `DOMAIN_LAN=lan`, `DOMAIN_TS` si aplica.
- **Fase 3** completa, en particular:
  - Pi-hole con el comodín `address=/lan/192.168.1.10` (cubre `radarr.${DOMAIN_LAN}` automáticamente).
  - Caddy desplegado y los snippets `(lan_tls)`, `(security_headers)`, `(healthcheck)`, `(authelia_two_factor)` en `Caddyfile`.
  - Tailscale operativo y, si se quiere acceso por `radarr.${DOMAIN_TS}`, `tailscale cert` ya emitiendo (`03-red/05-tailscale.md`).
- **Fase 4** completa: Authelia desplegado con 2FA; Radarr se protege con `forward_auth`. El **endpoint `/api/v3/...`** se exonera por path para que la API key nativa de Radarr siga siendo el mecanismo de auth para clientes programáticos (Prowlarr Apps Sync, Bazarr en el futuro, etc.). Ver "Decisión: autenticación" abajo.
- **Fase 7** opcional pero recomendable: Borgmatic operativo, para añadir `/mnt/hd2t/apps/radarr/config` al inventario de fuentes.
- **Fase 10 pasos anteriores**:
  - Transmission desplegado (`01-transmission.md`) con su RPC accesible en `http://transmission:9091/transmission/rpc`, credenciales en `stacks/transmission/.env` (`TRANSMISSION_RPC_USER`, `TRANSMISSION_RPC_PASS`).
  - Prowlarr desplegado (`02-prowlarr.md`) con al menos un indexador público probado y la API key disponible en `stacks/prowlarr/.env` (`PROWLARR_API_KEY`).
  - Sonarr desplegado (`03-sonarr.md`): no es dependencia funcional de Radarr (son servicios independientes), pero la mayoría de decisiones de Radarr replican las de Sonarr y conviene tener ambas a mano para comparar UI y verificar que el patrón funciona con dos clientes contra Prowlarr.
- Conocimiento del **TMDB ID** o nombre exacto de las primeras películas a probar (Radarr usa TMDB como fuente de metadatos por defecto; ver "Decisión: metadatos" abajo).

Comprobaciones rápidas:

```bash
# La red Docker compartida existe y los servicios previos están sanos
docker network inspect homelab --format '{{.Name}}' | grep -q '^homelab$' && echo ok
docker ps --filter name=caddy --filter name=authelia \
          --filter name=transmission --filter name=prowlarr \
          --format '{{.Names}} {{.Status}}'

# radarr.lan resuelve al IP de la Pi (gracias al comodín de Pi-hole)
dig +short radarr.lan @192.168.1.2
# 192.168.1.10

# Estructura de biblioteca correcta
stat -c '%a %U:%G %n' /mnt/hd2t/media /mnt/hd2t/media/movies
# 2770 homelab:media /mnt/hd2t/media
# 2770 homelab:media /mnt/hd2t/media/movies

# downloads/ y media/ están en el MISMO filesystem (requisito para hardlinks)
stat -c '%m' /mnt/hd2t/downloads/complete /mnt/hd2t/media/movies
# /mnt/hd2t
# /mnt/hd2t

# Conectividad interna a los servicios consumidos
docker run --rm --network homelab curlimages/curl -fsS \
    -o /dev/null -w 'transmission:%{http_code}\n' \
    http://transmission:9091/transmission/rpc
# transmission:409   (handshake CSRF — prueba que TR responde)

docker run --rm --network homelab curlimages/curl -fsS \
    -H "X-Api-Key: $(grep ^PROWLARR_API_KEY stacks/prowlarr/.env | cut -d= -f2)" \
    -o /dev/null -w 'prowlarr:%{http_code}\n' \
    http://prowlarr:9696/api/v1/system/status
# prowlarr:200
```

---

## Decisión: PVR — Radarr (v5), no CouchPotato ni Watcher

| PVR | Pros | Contras | Veredicto |
|---|---|---|---|
| **Radarr** (v5) | Estándar de facto del ecosistema `*arr` para películas, integración bidireccional con Prowlarr (Apps Sync), soporte nativo de hardlinks, *quality profiles* con *custom formats* (TRaSH-style), naming flexible, comunidad enorme, comparte modelo mental con Sonarr (operador aprende uno, gana ambos). v5 estabilizó *custom formats* y mejoró el manejo de *editions* (Director's Cut, Extended, etc.). | Stack `.NET` con consumo moderado de RAM (~250–400 MiB). Curva de aprendizaje en *quality profiles* + *custom formats*. | **Aceptado**. |
| CouchPotato | Histórico, Python, ligero. | **EOL desde 2019**, sin sync con Prowlarr, UI antigua, no soporta hardlinks de forma decente. | Descartado. |
| Watcher | Python, ligero, todavía mantenido a marcha lenta. | Sin sync con Prowlarr (usaría Jackett), comunidad pequeña, perdería la coherencia LSIO/`*arr` del homelab. | Descartado. |
| Radarr v3 | Estable, conocido. | EOL anunciado, Prowlarr v1 está orientado a v4+v5, los releases nuevos son solo en v5. | Descartado. |

**Decisión**: Radarr v5. Es el siguiente eslabón natural del catálogo Servarr/LSIO ya en uso (Transmission, Prowlarr, Sonarr) y es lo que entiende Prowlarr al sincronizar.

---

## Decisión: imagen — LinuxServer.io

Radarr v5 tiene varias imágenes públicas relevantes:

| Imagen | Mantenedor | Tag | Pros | Contras |
|---|---|---|---|---|
| `lscr.io/linuxserver/radarr` | LinuxServer.io | `:5.14.0` (multi-arch arm64) | UID/GID configurables, mismo patrón que Transmission/Prowlarr/Sonarr/Jellyfin/Audiobookshelf/Calibre-Web/Stash, scripts s6-overlay, *automatic permissions fix* del directorio `/config` al arrancar. | Una capa entre upstream y operador. |
| `ghcr.io/hotio/radarr` | hotio | `:release` | Sigue stables de upstream, opciones de mods. | Convenciones distintas (no usa `PUID`/`PGID` clásico, usa `UMASK_SET`). Romper la homogeneidad del homelab no compensa. |
| Imagen oficial `radarr/radarr` | Servarr team | varios | Construida por upstream. | Menos opinada (sin handler de permisos automático), tag `latest` puede apuntar a `develop` en algunas variantes. Hay que vigilar más. |

**Decisión**: `lscr.io/linuxserver/radarr:5.14.0`.

Razones:

- **Coherencia con todo el catálogo Fase 9 + Fase 10**: misma forma (`PUID`/`PGID`/`UMASK`/`TZ`), misma idea de bind mounts, misma s6-overlay debajo, idéntica al patrón de Sonarr.
- **Pin de versión completa** (no `latest`, no `5.14`): Radarr v5 ha tenido cambios de schema en `radarr.db` durante la serie 5.x (especialmente entre 5.0→5.4 con la reorganización de *custom formats*); pin estricto evita un *salto silencioso* a una versión que rompa las migrations sin que el operador haya hecho backup. Watchtower NO actualiza automáticamente este contenedor.

Actualizaciones: `docker compose pull && up -d` tras leer el changelog de Radarr (cambios de schema requieren backup previo del config). La etiqueta de Watchtower deja explícito el opt-out:

```yaml
labels:
  com.centurylinklabs.watchtower.enable: "false"
```

---

## Decisión: networking — bridge `homelab`, sin `ports:` publicados

| Modo | Pros | Contras | Veredicto |
|---|---|---|---|
| **Bridge `homelab`** (sin `ports:`) | Radarr en `172.30.10.X`. Caddy hace `reverse_proxy http://radarr:7878`. API interna entre `radarr`, `prowlarr`, `transmission` por DNS de Docker. | Ningún acceso desde el host directamente (lo que es deseado: la UI siempre va por Caddy). | **Aceptado**. |
| `network_mode: host` | Radarr escucha en `:7878/tcp` del host. | Innecesario (Radarr no necesita pila de red completa del host), rompe el patrón del bridge, complica el `Caddyfile`. | Descartado. |
| Bridge **+** `ports: ["7878:7878"]` | Acceso directo desde la LAN al `:7878`. | Comprometería el patrón "todo por Caddy con Authelia": cualquiera de la LAN podría hablarle al `:7878` saltándose el 2FA. La API key seguiría como única defensa en ese path. | Descartado. |

Resultado: **bridge `homelab`**, sin `ports`. La UI y API se acceden únicamente vía Caddy (`https://radarr.${DOMAIN_LAN}/`). Prowlarr, Transmission y, en el futuro, Bazarr le hablan a `http://radarr:7878` por la red interna.

---

## Decisión: autenticación — Authelia delante de la UI, API key nativa para clientes

Radarr v5 trae **autenticación nativa** propia (Forms con username/password almacenados en `config.xml`, hash bcrypt) y **API key** para clientes programáticos. El homelab combina ambas, igual que con Prowlarr y Sonarr:

| Path | Quién accede | Estrategia |
|---|---|---|
| `/`, `/static/...`, `/login`, `/UI/...` (UI humana) | Operador desde navegador | **Authelia 2FA** (`forward_auth`). Tras superar Authelia, Caddy reenvía a `http://radarr:7878`. La autenticación nativa de Radarr se **deshabilita** poniendo `AuthenticationMethod=External` + `AuthenticationRequired=DisabledForLocalAddresses` (ver "Configuración" abajo): así Radarr confía en que quien le llega ya está autenticado por la capa anterior. |
| `/api/v3/...` | Prowlarr (Apps Sync), Bazarr futuro, scripts del operador | **Bypass de Authelia**: usan la **API key** de Radarr (header `X-Api-Key`). Authelia no se aplica a este path. |
| `/feed/...`, `/ping` | Health-checks y feeds RSS internos | **Bypass de Authelia** (sin auth en `/ping`; API key para feeds). |

En la práctica, **Prowlarr y Transmission no pasan por Caddy en absoluto**: hablan directamente al bridge `homelab` con `http://radarr:7878/api/v3/...` y la API key. Radarr, a su vez, le habla a Prowlarr y a Transmission sin pasar por Caddy. La razón de mantener los bypasses por path en el `Caddyfile` es para clientes externos (en el tailnet, p. ej.) que quieran consumir la API sin pasar por Authelia. Reabrible.

> **Sobre `AuthenticationRequired=DisabledForLocalAddresses`**: en Radarr, "Local Addresses" se interpreta como las redes RFC1918 que llamen al servicio. La red `homelab` (`172.30.10.0/24`) y `127.0.0.1` cuentan como locales. Esto permite que **Prowlarr no necesite password de Radarr** (solo API key) mientras que la UI sigue exigiendo Authelia delante (porque la conexión externa entra por Caddy y se trata como remota). Si se quisiera blindar más, cambiar a `Enabled` y manejar tanto cookie de Authelia como API key — innecesario en este alcance.

> **¿Por qué no usar la auth nativa Forms?** Tres razones, idénticas a las de Sonarr y Prowlarr: (a) duplicaría credenciales (Authelia ya gestiona el login del homelab), (b) la auth nativa no es 2FA, (c) sería el único servicio del homelab autenticado fuera del SSO. La elección es coherente con cómo se trata el resto de UIs del catálogo.

---

## Decisión: metadatos — TMDB (default), no IMDb

Radarr usa **TMDB** (The Movie Database) como fuente primaria de metadatos. No hay backend alternativo configurable: TMDB es la única fuente para *poster*, *fanart*, sinopsis, *runtime*, géneros y la propia función de búsqueda al añadir películas. IMDb se usa de forma indirecta (via *IMDb ID* como identificador alternativo), pero los metadatos vienen de TMDB.

Implicaciones operativas:

- **No requiere API key**: TMDB tiene un endpoint público que Radarr usa con su clave embebida.
- **Requiere conectividad saliente HTTPS** a `api.themoviedb.org`. Si Pi-hole bloqueara el dominio (improbable, pero podría pasar con listas agresivas), Radarr no podría buscar. Verificación rápida:
  ```bash
  docker exec radarr curl -fsSI https://api.themoviedb.org/3/configuration | head -1
  # HTTP/2 200 — ok (sin API key, devuelve 401 con cuerpo JSON; el TLS handshake basta para confirmar conectividad)
  ```
- **Idioma de metadatos**: por defecto en inglés. Se cambia en `Settings → UI → Movie Info Language` a `Spanish`. Afecta solo a la UI y a los nombres de géneros; el título de la película sigue el original (TMDB devuelve título original + traducción), y el operador elige cuál usar en el esquema de naming.

No es decisión reabrible: TMDB es la única opción.

---

## Decisión: minimum availability — `Released`, no `Announced` ni `In Cinemas`

Radarr introduce un concepto que Sonarr no tiene: *Minimum Availability*. Define **cuándo una película es elegible para búsqueda**.

| Valor | Significado | Pros | Contras |
|---|---|---|---|
| `Announced` | Cualquier película anunciada en TMDB. | Búsquedas inmediatas. | Genera ruido enorme: la mayoría de "releases" antes del estreno son spam, fakes o screeners de baja calidad. |
| `In Cinemas` | La película ya está en cines. | Permite cazar screeners (CAM, TS, TC) si el operador los quisiera. | Calidad pésima por definición; no compensa. |
| **`Released`** | La película tiene fecha de release físico/digital (Bluray, WEB-DL, VOD). | Solo busca cuando hay probabilidad razonable de encontrar releases de calidad. **Default en este homelab**. | Espera de semanas/meses tras el estreno en cines (lo cual es lo correcto para una biblioteca personal). |
| `Predicted` | Heurística de Radarr: estima cuándo una release Bluray estará disponible (~3–6 meses post-estreno). | Búsquedas un poco más temprano que `Released` sin mucho ruido extra. | Heurística, falible. Para un homelab personal sin urgencias, `Released` es más conservador. |

**Decisión**: `Released` como default global y por película. El operador siempre puede ajustar por película (botón *Edit* en cada movie), p. ej. poner `In Cinemas` para una película muy esperada y aceptar el riesgo de WEBRips de baja calidad.

> **Sobre el comportamiento de la búsqueda**: si `Minimum Availability` no se ha alcanzado, Radarr **no llama a Prowlarr** en absoluto para esa película. Es protección contra ruido en los logs y contra encolar releases inválidas. Cuando TMDB actualiza la fecha de release, Radarr la detecta en su rescaneo periódico (~12 h) y empieza a buscar.

---

## Decisión: dónde viven los datos y permisos

Radarr maneja **tres zonas de disco**, cada una con su régimen de permisos (idéntico al patrón de Sonarr):

| Tipo | Dónde | Owner:Group | Modo | Observaciones |
|---|---|---|---|---|
| **Config + DB** (`config.xml`, `radarr.db`, `radarr.db-wal`, `radarr.db-shm`, `Backups/`, `MediaCover/`, `logs/`) | `/mnt/hd2t/apps/radarr/config/` | `homelab:homelab` (`1000:1000`) | `0750` | LSIO escribe como `PUID:PGID`. Crítico para backup (DB SQLite con catálogo de películas, profiles, naming, history, queue). |
| **Descargas terminadas** (lectura) | `/mnt/hd2t/downloads/` | `homelab:media` (`1000:1100`) | `2770` | Radarr necesita **leer** los ficheros que TR ha dejado en `complete/` para importarlos. Compartido vía bind mount con TR y Sonarr. |
| **Biblioteca de películas** (lectura+escritura) | `/mnt/hd2t/media/movies/` | `homelab:media` (`1000:1100`) | `2770` | Radarr crea aquí los hardlinks tras el import, los renombra y los borra cuando hace upgrade. |

Bind mounts elegidos:

```yaml
volumes:
  - /mnt/hd2t/apps/radarr/config:/config
  # Punto único de montaje de descargas. Compartido con Transmission y Sonarr.
  # CRÍTICO para hardlinks: ver razón abajo.
  - /mnt/hd2t/downloads:/downloads
  - /mnt/hd2t/media/movies:/media/movies
```

Razones:

- **Bind mount `/downloads` exactamente como en Transmission y Sonarr** (mismo path en el host, mismo path dentro del contenedor). Si Radarr montara `/downloads/complete` en lugar de `/downloads`, los paths que devuelve TR por RPC (`/downloads/complete/<release>/`) **no coincidirían** con lo que Radarr ve dentro de su contenedor, y el import fallaría con un error críptico de "remote path mapping". Mantener **el mismo prefijo** en los tres contenedores es la regla de oro.
- **Bind mount `/media/movies` con el mismo path en host y contenedor**: Jellyfin (Fase 9) ya monta `/mnt/hd2t/media` con `/media` como prefijo. Radarr debe usar **el mismo prefijo dentro del contenedor** para que los hardlinks queden en una ruta que Jellyfin pueda leer (mismo inodo, distinto bind, mismo filesystem).
- **`UMASK=002`** (en lugar del `022` global): coherente con TR y Sonarr. Los ficheros que Radarr crea o renombra en `/media/movies/` salen con grupo escribible (`0664`), y los directorios con `0775`. Permite que Sonarr o, en el futuro, Bazarr puedan operar en la misma jerarquía si fuera necesario (no lo es por ahora — Sonarr y Radarr operan en sub-árboles disjuntos `tv/` y `movies/`, pero el patrón uniforme simplifica todo).
- **`group_add: [1100]`**: Radarr corre con `PUID=1000, PGID=1000`, pero necesita ser miembro del grupo `media` (1100) para escribir en `/media/movies/` (modo `2770`). El `group_add` es la vía estándar en LSIO para añadir grupos suplementarios al UID del proceso.
- **Hardlinks comprobados al arrancar**: en *Settings → Media Management*, activar "Use Hardlinks instead of Copy" (es el default de v5, pero conviene confirmarlo). Radarr probará al primer import si puede hacer un hardlink entre `/downloads/complete/...` y `/media/movies/...`; si no puede (filesystems distintos, permisos), caerá a copy con un warning visible en la UI.

---

## Stack: `stacks/radarr/`

### Layout en disco

| Ruta | Soporte | Contenido |
|---|---|---|
| `stacks/radarr/docker-compose.yml` | microSD (git) | Stack (servicio `radarr`). |
| `stacks/radarr/.env.example` | microSD (git) | Plantilla con `RADARR_API_KEY` (vacía hasta el primer arranque) y referencias a `PROWLARR_API_KEY` y credenciales de Transmission. |
| `stacks/caddy/conf.d/13-radarr.caddy` | microSD (git) | Drop-in del bloque LAN+tailnet para `radarr.${DOMAIN_LAN}` y `radarr.${DOMAIN_TS}`. |
| `/mnt/hd2t/apps/radarr/config/` | hd2t | `config.xml`, `radarr.db`, `Backups/`, `MediaCover/`, `logs/`. Owner `homelab:homelab`, modo `0750`. |
| `/mnt/hd2t/media/movies/` | hd2t | Biblioteca destino (compartida con Jellyfin). Owner `homelab:media`, modo `2770`. |

### `stacks/radarr/docker-compose.yml`

```yaml
# Radarr — PVR de películas del homelab.
# Documentado en docs/10-descargas/04-radarr.md.
#
# Networking: bridge homelab. Caddy hace reverse proxy hacia radarr:7878.
# Radarr le habla a prowlarr:9696 (búsquedas) y a transmission:9091 (descargas)
# por la red interna; Prowlarr le habla a radarr:7878 para el sync de Apps.

name: radarr

networks:
  homelab:
    external: true

services:
  radarr:
    image: lscr.io/linuxserver/radarr:5.14.0
    container_name: radarr
    hostname: radarr
    restart: unless-stopped

    networks:
      - homelab

    # NO se publican puertos al host. La UI va por Caddy (https://radarr.lan)
    # y el API lo consumen Prowlarr/Bazarr dentro del bridge homelab.
    # ports:
    #   - "7878:7878"   # NO: comprometería el patrón de Caddy + Authelia.

    environment:
      TZ: ${TZ}
      PUID: ${PUID}              # 1000 (homelab)
      PGID: ${PGID}              # 1000 (homelab)
      UMASK: "002"               # ficheros 0664, dirs 0775 → grupo media escribe

    # group_add para que el contenedor escriba en /media/movies y lea /downloads
    # como grupo media. Igual que Transmission y Sonarr.
    group_add:
      - "1100"   # media (creado en 01-sistema/04-estructura-directorios.md)

    volumes:
      - /mnt/hd2t/apps/radarr/config:/config
      # MISMO prefijo que en Transmission y Sonarr (CRÍTICO para que los paths
      # del RPC de TR coincidan dentro de Radarr y los hardlinks funcionen).
      - /mnt/hd2t/downloads:/downloads
      # MISMO prefijo que en Jellyfin (CRÍTICO para que el media server vea
      # los hardlinks tras el import).
      - /mnt/hd2t/media/movies:/media/movies
      - /etc/localtime:/etc/localtime:ro

    healthcheck:
      # /ping es endpoint público sin auth ni API key: 200 ⇒ alive.
      test:
        - CMD-SHELL
        - >
          curl -fsS -o /dev/null -w '%{http_code}' http://127.0.0.1:7878/ping |
          grep -E '^200$' >/dev/null
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 45s

    labels:
      homelab.role: "pvr-movies"
      homelab.backup: "true"
      # Watchtower NO actualiza automáticamente: tag completo (5.14.0).
      # Cambios menores de Radarr a veces migran schema de radarr.db: leer
      # release notes y hacer backup antes de subir versión.
      com.centurylinklabs.watchtower.enable: "false"
```

> **Sobre el `start_period: 45s`**: igual que Sonarr, Radarr tarda más que Prowlarr en arrancar la primera vez (migrations de DB + warm-up de `.NET`). En arranques sucesivos suele estar healthy en 15–20 s, pero el margen amplio evita falsos `unhealthy` en upgrades.

### `stacks/radarr/.env.example`

```bash
# stacks/radarr/.env.example
# Copiar a stacks/radarr/.env (chmod 0600) y rellenar.
#
# Las generales (TZ, PUID, PGID, DOMAIN_LAN, DOMAIN_TS) vienen del .env GLOBAL.

# API key de Radarr.
#
# Se genera automáticamente al primer arranque y queda en config.xml
# (clave <ApiKey>). Tras el primer up:
#   docker exec radarr grep -oP '(?<=<ApiKey>)[^<]+' /config/config.xml
# Copiar el valor aquí. Prowlarr (Apps sync) y, en el futuro, Bazarr leerán
# esta variable.
RADARR_API_KEY=

# Credenciales de servicios consumidos. NO se duplican aquí: se importan
# del .env GLOBAL al levantar el stack con --env-file. Documentadas para
# que el operador sepa qué necesita Radarr en Settings:
#
#   PROWLARR_API_KEY        (de stacks/prowlarr/.env)  → Settings → Indexers
#   TRANSMISSION_RPC_USER   (de stacks/transmission/.env) → Settings → Download Clients
#   TRANSMISSION_RPC_PASS   (de stacks/transmission/.env) → idem
```

### Drop-in de Caddy: `stacks/caddy/conf.d/13-radarr.caddy`

```caddy
# /etc/caddy/conf.d/13-radarr.caddy — bloques de Radarr.
# Documentado en docs/10-descargas/04-radarr.md.
#
# UI protegida por Authelia 2FA. Endpoint /api/v3, /feed y /ping en bypass
# para permitir que clientes legítimos (Prowlarr Apps Sync, futuras
# integraciones) sigan funcionando si en algún momento se accediera vía
# Caddy en lugar de directamente al bridge.

# ---- Acceso LAN -----------------------------------------------------------
radarr.{$DOMAIN_LAN} {
    import lan_tls
    import security_headers
    import healthcheck

    # Bypass para API y feeds: la integración con clientes programáticos usa
    # la API key nativa de Radarr, no el flujo de Authelia.
    @api {
        path /api/v3 /api/v3/*
        path /feed/* /feed
        path /ping
    }
    handle @api {
        reverse_proxy http://radarr:7878
    }

    # UI humana: Authelia 2FA delante.
    handle {
        import authelia_two_factor
        reverse_proxy http://radarr:7878
    }
}

# ---- Acceso Tailscale -----------------------------------------------------
# Solo se materializa si DOMAIN_TS está definido (tailnet con tailscale cert).
radarr.{$DOMAIN_TS} {
    tls {
        get_certificate tailscale
    }
    import security_headers
    import healthcheck

    @api {
        path /api/v3 /api/v3/*
        path /feed/* /feed
        path /ping
    }
    handle @api {
        reverse_proxy http://radarr:7878
    }

    handle {
        import authelia_two_factor
        reverse_proxy http://radarr:7878
    }
}
```

### Crear directorios y desplegar

```bash
# Cargar variables globales en el shell (ver quirk Compose v2 en 02-estructura-compose.md)
cd /home/homelab/homelab
set -a; source .env; set +a

# 1) Verificar prerequisitos.
docker network inspect homelab >/dev/null 2>&1 \
    || { echo "ERROR: red Docker 'homelab' no existe (Fase 2)."; exit 1; }
for svc in caddy authelia transmission prowlarr; do
    docker ps --filter name="^${svc}$" --filter status=running -q | grep -q . \
        || { echo "ERROR: ${svc} no está corriendo."; exit 1; }
done

# 2) Verificar estructura de biblioteca.
getent group media | grep -q '^media:x:1100:' || {
    echo "ERROR: grupo media (GID 1100) no existe. Aplicar 01-sistema/04-estructura-directorios.md."
    exit 1
}
[ -d /mnt/hd2t/media/movies ] \
    || sudo install -d -o homelab -g media -m 2770 /mnt/hd2t/media/movies

# 3) Confirmar que downloads/ y media/ comparten filesystem (hardlinks).
[ "$(stat -c '%m' /mnt/hd2t/downloads/complete)" = \
  "$(stat -c '%m' /mnt/hd2t/media/movies)" ] \
  || { echo "ERROR: downloads y media en filesystems distintos."; exit 1; }

# 4) Crear directorios persistentes del servicio (idempotente).
sudo install -d -o homelab -g homelab -m 0750 /mnt/hd2t/apps/radarr
sudo install -d -o homelab -g homelab -m 0750 /mnt/hd2t/apps/radarr/config

# 5) Crear .env (vacía la API key; se rellena tras el primer arranque).
cp stacks/radarr/.env.example stacks/radarr/.env
chmod 0600 stacks/radarr/.env

# 6) Materializar Caddy drop-in.
install -o homelab -g homelab -m 0644 \
    stacks/radarr/../caddy/conf.d/13-radarr.caddy \
    /mnt/hd2t/apps/caddy/etc/conf.d/13-radarr.caddy

# 7) Levantar el stack.
docker compose \
    -f stacks/radarr/docker-compose.yml \
    --env-file stacks/radarr/.env \
    up -d

# 8) Recargar Caddy para que aplique el nuevo drop-in.
docker exec caddy caddy reload --config /etc/caddy/Caddyfile

# 9) Esperar healthy (Radarr tarda ~30 s en su primer arranque).
docker ps --filter name=radarr --format '{{.Names}} {{.Status}}'
# radarr   Up 45s (healthy)

# 10) Extraer la API key generada y rellenarla en .env.
API_KEY="$(docker exec radarr grep -oP '(?<=<ApiKey>)[^<]+' /config/config.xml)"
sed -i "s|^RADARR_API_KEY=$|RADARR_API_KEY=${API_KEY}|" stacks/radarr/.env
echo "RADARR_API_KEY=${API_KEY}" >&2   # confirmación visual; no commitear el valor.
```

---

## Configuración

Tras el primer arranque, Radarr genera `/mnt/hd2t/apps/radarr/config/config.xml` y `radarr.db` con valores por defecto. Hay cuatro bloques que configurar **en este orden**: autenticación (igual que Sonarr/Prowlarr), root folder + media management, indexador (Prowlarr) y download client (Transmission). Después se ajustan profiles de calidad y *minimum availability*.

### 1) Ajustar `config.xml` para Authelia

`config.xml` se reescribe por Radarr al cambiar settings desde la UI; las modificaciones manuales **se hacen con el contenedor parado**.

```bash
docker compose -f stacks/radarr/docker-compose.yml stop radarr
sudo -u homelab "$EDITOR" /mnt/hd2t/apps/radarr/config/config.xml
docker compose -f stacks/radarr/docker-compose.yml start radarr
```

Valores relevantes:

```xml
<Config>
  <BindAddress>*</BindAddress>
  <Port>7878</Port>
  <SslPort>9898</SslPort>
  <EnableSsl>False</EnableSsl>
  <LaunchBrowser>False</LaunchBrowser>
  <ApiKey>...generada al primer arranque, NO TOCAR...</ApiKey>
  <AuthenticationMethod>External</AuthenticationMethod>
  <AuthenticationRequired>DisabledForLocalAddresses</AuthenticationRequired>
  <Branch>master</Branch>
  <LogLevel>info</LogLevel>
  <SslCertPath></SslCertPath>
  <SslCertPassword></SslCertPassword>
  <UrlBase></UrlBase>
  <InstanceName>Radarr</InstanceName>
  <UpdateMechanism>Docker</UpdateMechanism>
</Config>
```

Justificación de los valores (idénticos en espíritu a Sonarr salvo `Branch`):

| Clave | Valor | Razón |
|---|---|---|
| `AuthenticationMethod` | `External` | Radarr asume que la auth la resuelve la capa de delante (Authelia/Caddy). No pide login propio. |
| `AuthenticationRequired` | `DisabledForLocalAddresses` | Prowlarr (Apps Sync) y futuras integraciones acceden con solo API key. Conexiones externas (vía Caddy) se tratan como autenticadas por Authelia. |
| `EnableSsl` | `False` | TLS lo termina Caddy. |
| `LaunchBrowser` | `False` | Headless. |
| `UrlBase` | vacío | Subdominio dedicado (`radarr.lan`), no se necesita prefijo. |
| `UpdateMechanism` | `Docker` | Indica a Radarr que **no** intente auto-actualizar el binario interno. |
| `LogLevel` | `info` | Suficiente; subir a `debug` solo para investigación puntual. |
| `Branch` | `master` | Stable en v5. (A diferencia de Sonarr v4, que usa `main`, Radarr conserva `master`. Si se cambia por error a `develop` o `nightly`, los upgrades pasan a builds de desarrollo.) |

### 2) Verificar UI

1. `https://radarr.${DOMAIN_LAN}/` → Authelia pide 2FA → al pasar, aparece la UI de Radarr (sin login propio adicional, gracias a `AuthenticationMethod=External`).
2. `Settings → General → Security`: confirmar **Authentication: External**, copiar la **API Key** (la misma que ya está en `.env`).
3. Si por algún motivo la quisieras rotar, *Reset* la regenera y hay que actualizar `stacks/radarr/.env` y todos los clientes que la consuman (Prowlarr Apps).

### 3) Configurar *Root Folder* y *Media Management*

`Settings → Media Management`:

| Sección | Clave | Valor | Razón |
|---|---|---|---|
| Movie Naming | Rename Movies | **on** | Radarr aplica esquema al importar. |
| Movie Naming | Replace Illegal Characters | **on** | Para que ext4/NTFS futuros no se rompan. |
| Movie Naming | Standard Movie Format | `{Movie Title} ({Release Year}) [{Quality Title}]` | Esquema clásico, legible por Jellyfin. Una sola línea (las películas son un fichero, no episodios). |
| Movie Naming | Movie Folder Format | `{Movie Title} ({Release Year})` | Convención TMDB/Jellyfin: una carpeta por película. |
| Folders | Create empty movie folders | **off** | No ensucia con carpetas vacías. |
| Folders | Delete empty folders | **on** | Limpieza tras *unmonitor* y borrado. |
| Importing | Use Hardlinks instead of Copy | **on** | **Crítico**. Es el default en v5, confirmar. |
| Importing | Import Extra Files | **off** | No importa `.nfo`, `.srt` sueltos del torrent (Bazarr los gestionará a futuro). |
| Importing | Unpack | **off** | Los releases que importan suelen venir sin compresión; si llegan en `.rar`, se gestiona caso a caso (no merece la pena el riesgo de unpack automático). |
| File Management | Unmonitor Deleted Movies | **on** | Si el operador borra un fichero a mano, Radarr no lo re-descarga. |
| File Management | Set Permissions | **on** | Aplica `chmod` tras import (con UMASK 002). |
| Root Folders | (añadir) | `/media/movies` | Path **dentro del contenedor**; corresponde a `/mnt/hd2t/media/movies` en host. |

> **Sobre "Set Permissions"**: combinado con `UMASK=002` y `group_add: 1100`, garantiza que ficheros importados sean `0664` `homelab:media`. Sin esto, Radarr respeta el modo del torrent original (que TR ya entrega correcto, así que es defensa en profundidad).

> **Sobre el formato de naming**: el esquema documentado es **simplificado** respecto a las recomendaciones TRaSH (que añaden tags de release group, codec, edition, MediaInfo). Para un homelab personal el esquema corto basta y deja nombres legibles. Si se quiere alinear con TRaSH al 100%, los esquemas oficiales están en [TRaSH guides — Radarr naming](https://trash-guides.info/Radarr/Radarr-recommended-naming-scheme/) y son drop-in replacements.

### 4) Conectar a Prowlarr (vía Apps de Prowlarr, no aquí)

A diferencia de instalaciones legacy con Jackett, **Radarr no añade indexadores manualmente**: los recibe vía sync desde Prowlarr.

Desde la UI de **Prowlarr** (`https://prowlarr.${DOMAIN_LAN}/`):

1. *Settings → Apps → Add → Radarr*.
2. Rellenar:
   - **Name**: `Radarr`
   - **Sync Level**: `Full Sync` (Prowlarr replica indexadores y *Tags* con bidirección).
   - **Prowlarr Server**: `http://prowlarr:9696` (DNS interno; **no** el subdominio de Caddy).
   - **Radarr Server**: `http://radarr:7878`
   - **API Key**: la `RADARR_API_KEY` de `stacks/radarr/.env`.
3. *Test* → debe pasar. *Save*.
4. Volver a *Settings → Indexers* en Prowlarr y forzar un *Sync App Indexers* desde el menú contextual de cada indexador, o esperar al sync periódico (cada 15 min).
5. En Radarr, *Settings → Indexers*: deben aparecer los indexadores de Prowlarr con el tag `prowlarr`. **No tocar manualmente**: los gestiona Prowlarr.

> **Sobre Sync Level "Full Sync" vs "Add and Remove Only"**: igual que con Sonarr, **Full Sync** es la opción correcta para mantener Prowlarr como única fuente de verdad. Cualquier cambio en Prowlarr (URL del tracker, prioridad, categorías, *Sync Profile*) se propaga a Radarr.

### 5) Conectar a Transmission

`Settings → Download Clients → Add → Transmission`:

| Clave | Valor | Razón |
|---|---|---|
| Name | `Transmission` | Identificador. |
| Enable | **on** | |
| Host | `transmission` | DNS interno del bridge. |
| Port | `9091` | Puerto RPC de TR. |
| URL Base | `/transmission/` | Path del RPC en TR. |
| Username | valor de `TRANSMISSION_RPC_USER` | Del `.env` de TR. |
| Password | valor de `TRANSMISSION_RPC_PASS` | Idem. |
| Category | (vacío) | TR no usa categorías. Si se quiere segregar, Radarr puede añadir un label de TR (`radarr`) — opcional, no necesario. |
| Directory | (vacío) | TR ya está configurado para escribir en `/downloads/complete/`. Si se rellena, Radarr le pide a TR que escriba en *otra* ruta, lo que rompe el patrón. |
| Recent Priority | `Last` | Releases recientes con prioridad estándar. |
| Older Priority | `Last` | Idem. |
| Use SSL | **off** | Comunicación interna en el bridge `homelab`. |
| Add Paused | **off** | Encolar = empezar a bajar inmediatamente. |
| Client | `Transmission` | Tipo. |

*Test* → debe responder OK con detalles de la versión de TR. *Save*.

`Settings → Download Clients → Completed Download Handling`:

| Clave | Valor | Razón |
|---|---|---|
| Enable | **on** | Radarr hace polling al RPC y recoge los completos. |
| Redownload Failed | **on** | Si un import falla (fichero corrupto, naming inválido), Radarr reintenta con otra release. |

`Settings → Download Clients → Failed Download Handling`:

| Clave | Valor | Razón |
|---|---|---|
| Redownload | **on** | Si TR reporta un fallo, Radarr busca otra release. |
| Remove from Client | **On Import** | Tras import exitoso, Radarr le pide a TR que borre el torrent **sin borrar fichero local** (`delete-local-data: false`). El hardlink en `/media/movies/` mantiene los bytes vivos para el reproductor; TR seedea hasta cumplir su ratio sobre el `/downloads/complete/...` y luego se autodelete por la política de TR. |

> **Sobre la coordinación TR↔Radarr para el ratio**: idéntica al caso de Sonarr. Recomendación práctica: dejar que la política de TR (`ratio-limit` y `idle-seeding-limit`, definidas en `01-transmission.md`) gestione el ciclo de vida del torrent, y que Radarr solo mande `torrent-remove` "tracker-side" en el momento del import. Esto suele "funcionar solo" si los defaults de TR y Radarr no se tocan.

### 6) Ajustar *Quality Profiles*

`Settings → Profiles → Quality Profiles`:

Radarr trae varios perfiles preconfigurados. La recomendación para el homelab (Pi 5 + biblioteca personal) es uno o dos perfiles, no proliferar:

| Perfil | Allowed | Upgrade Allowed | Cutoff | Uso |
|---|---|---|---|---|
| **HD-1080p** | `WEBDL-1080p`, `WEBRip-1080p`, `Bluray-1080p`, `Bluray-1080p Remux` | **on** | `Bluray-1080p` | Default para cualquier película nueva. Cubre el 99% de los casos. Pi 5 + Jellyfin transcoden 1080p sin problema y la biblioteca cabe holgada en hd2t. |
| **HD-720p** *(opcional)* | `WEBDL-720p`, `WEBRip-720p`, `Bluray-720p` | **on** | `Bluray-720p` | Para películas en las que 1080p sería excesivo (animación clásica, contenido de archivo). Casi nadie lo usa. |
| **UHD-2160p** *(opcional)* | `WEBDL-2160p`, `Bluray-2160p`, `Bluray-2160p Remux` | **on** | `Bluray-2160p` | Solo para películas seleccionadas a mano por el operador (asignación por película, no global). 4K REMUX es **muy** pesado (40–80 GiB por película) y Pi 5 puede transcoder 4K HEVC con esfuerzo o requerir *direct play* en el cliente. Reabrible/usable; no es el default. |

Crear el perfil `HD-1080p` (o editar el existente del mismo nombre): activar las cualidades listadas arriba en orden ascendente de preferencia (Radarr selecciona la más alta disponible que cumpla las restricciones), poner *Cutoff* en `Bluray-1080p` (cuando esa cualidad esté disponible, parar de buscar upgrades).

> **Sobre Bluray REMUX vs Bluray normal**: REMUX = video y audio extraídos sin re-encode del Bluray; tamaño 30–60 GiB para 1080p, 40–80 GiB para 4K. Es pristino pero pesa muchísimo. Para HD-1080p del homelab, dejar REMUX habilitado pero con menor prioridad que Bluray-1080p estándar (releases x264 8 GiB) deja a Radarr coger lo que haya: REMUX si está disponible y cabe, normal si no. Si el operador prefiere economizar disco, eliminar REMUX del perfil.

> **Custom Formats** (avanzado): Radarr v5 soporta *custom formats* para puntuar releases por release group, codec (x265 vs x264), HDR, audio (Atmos), edition (Director's Cut, Extended), etc. Para el homelab inicial **no se configuran**: añade complejidad sin un beneficio claro hasta que el operador descubra qué releases concretas le funcionan mejor. Reabrible siguiendo TRaSH guides.

### 7) Ajustar *Minimum Availability*

`Settings → Profiles → ...` (parte inferior) o como ajuste por película al añadirla:

- **Default**: `Released`. (Decisión documentada arriba.)
- Si una película muy esperada se quiere "cazar" antes (con releases CAM/WEBRip previas al Bluray), editar la película individual y bajar a `In Cinemas` o `Predicted`. No tocar el default global.

### 8) Ajustar idioma de UI

`Settings → UI → Movie Info Language`: `Spanish`.

> Esto cambia los textos de UI de Radarr (no los títulos de las películas, que siguen TMDB). Si se quiere que el título mostrado en la biblioteca sea el español traducido por TMDB, en `Settings → UI → Movie Display Order` no hay opción directa: se mantiene el título original. Para Jellyfin, el título se toma del nombre de fichero, así que el esquema `{Movie Title} ({Release Year}) [...]` puede ajustarse a `{Movie Original Title}` si se prefiere fijar siempre el original.

### 9) Smoke test del ciclo completo

Desde la UI de Radarr:

1. *Movies → Add New → Search* "Big Buck Bunny" (o cualquier película/short legal disponible en los indexadores configurados).
2. *Quality Profile*: `HD-1080p`. *Root Folder*: `/media/movies`. *Monitor*: `Movie Only`. *Minimum Availability*: `Released`. *Search for movie*: **on**.
3. *Add Movie*. Radarr lanza una búsqueda; tras unos segundos debería aparecer una *Activity → Queue* con un release encolado.
4. Abrir Transmission (`https://transmission.${DOMAIN_LAN}/`) y confirmar que el torrent está bajando en `/downloads/incomplete/`.
5. Esperar a que termine (depende del tamaño y peers). Radarr lo detectará por polling (intervalo por defecto: ~1 min).
6. Verificar que Radarr ha hecho el import: en *Activity → History*, debe aparecer `Movie Imported`. En el host:
   ```bash
   ls -lh /mnt/hd2t/media/movies/
   stat /mnt/hd2t/media/movies/Big\ Buck\ Bunny\ \(2008\)/Big\ Buck\ Bunny\ \(2008\)\ \[Bluray-1080p\].mkv
   # Links: 2  ← prueba del hardlink (1 en /downloads/complete + 1 en /media/movies)
   ```
7. Refrescar la biblioteca en Jellyfin (Fase 9): la nueva película debería aparecer.
8. (Opcional) Borrar la película de prueba: *Movie → … → Delete* con "Delete files" si se quiere limpiar; el torrent en TR seguirá hasta cumplir ratio si así está configurado.

### 10) Smoke test del API

Desde otro contenedor del bridge:

```bash
docker run --rm --network homelab curlimages/curl \
  -H "X-Api-Key: $(grep ^RADARR_API_KEY stacks/radarr/.env | cut -d= -f2)" \
  http://radarr:7878/api/v3/system/status
# JSON con appName=Radarr, version=5.14.0.x, branch=master, instanceName=Radarr...

# Películas catalogadas
docker run --rm --network homelab curlimages/curl \
  -H "X-Api-Key: $(grep ^RADARR_API_KEY stacks/radarr/.env | cut -d= -f2)" \
  http://radarr:7878/api/v3/movie | head -c 200
# Array JSON con la película de prueba.
```

---

## Almacenamiento

Volúmenes y bind mounts:

| Mount en contenedor | Bind en host | Contenido | Tamaño esperado |
|---|---|---|---|
| `/config` | `/mnt/hd2t/apps/radarr/config` | `config.xml`, `radarr.db` (+ `-wal`, `-shm`), `Backups/`, `MediaCover/` (posters cacheados de TMDB), `logs/`, `update_logs/` | 200 MiB – 2 GiB sostenidos. `MediaCover/` crece linealmente con el catálogo (1–5 MiB por película); `Backups/` rota automáticamente. |
| `/downloads` | `/mnt/hd2t/downloads` | Solo **lectura** desde el punto de vista de Radarr (los ficheros los crea TR; Radarr los hardlinkea a `/media/movies/`). | Variable, no aporta huella propia (compartido). |
| `/media/movies` | `/mnt/hd2t/media/movies` | Biblioteca destino: `<Movie> ({Year})/<Movie> ({Year}) [Quality].ext`. | Función del catálogo. Cientos de GiB realistas; con UHD-2160p REMUX puede llegar a TiB. |
| `/etc/localtime` | `/etc/localtime:ro` | Zona horaria del host | KiB. Mantiene logs y horarios de búsqueda coherentes. |

Permisos:

- `/mnt/hd2t/apps/radarr/config/`: `homelab:homelab` `0750`. Radarr escribe como UID 1000.
- `/mnt/hd2t/downloads/`: heredado de TR (`homelab:media` `2770`). Radarr lee/borra (al hacer import + cleanup) gracias a `group_add: 1100`.
- `/mnt/hd2t/media/movies/`: `homelab:media` `2770`. Radarr crea hardlinks como `homelab:media` `0664` (gracias a `UMASK=002`) y directorios como `0775`. Jellyfin (mismo UID/grupo) podrá leerlos.

Comprobación en cualquier momento:

```bash
# Tamaño y contenido del directorio de config
sudo du -sh /mnt/hd2t/apps/radarr/config /mnt/hd2t/apps/radarr/config/*

# DB SQLite saludable
docker exec radarr sqlite3 /config/radarr.db 'PRAGMA integrity_check;'
# ok

# Hardlinks correctos en /media/movies (Links: >=2 = hardlink activo a /downloads)
sudo find /mnt/hd2t/media/movies -type f -name '*.mkv' -newer /tmp \
    -exec stat -c '%n nlink=%h' {} \; | head

# Backups internos de Radarr (rotación automática)
ls -lh /mnt/hd2t/apps/radarr/config/Backups/scheduled/
```

> **Sobre los backups internos de Radarr**: igual que Sonarr y Prowlarr, la app genera backups completos del config en `Backups/scheduled/` cada semana (ZIP con `config.xml` + `radarr.db`). Son **complementarios** a Borgmatic, no sustitutivos: sirven para *Restore* desde la propia UI tras un cambio mal hecho (rollback rápido sin tocar Borg). Borgmatic los respaldará junto al resto de `/config/`.

---

## Backup

Política para Borgmatic (Fase 7) — fragmento a integrar en su `config.yaml`:

```yaml
# borgmatic — fragmento para Radarr
source_directories:
  - /mnt/hd2t/apps/radarr/config

exclude_patterns:
  # Cache regenerable: Radarr lo recrea desde TMDB al primer arranque.
  - /mnt/hd2t/apps/radarr/config/MediaCover
  # Logs no son esenciales para restaurar el servicio.
  - /mnt/hd2t/apps/radarr/config/logs
  - /mnt/hd2t/apps/radarr/config/update_logs
  # WAL y SHM de SQLite pueden estar a medio escribir; Radarr los regenera.
  - /mnt/hd2t/apps/radarr/config/radarr.db-wal
  - /mnt/hd2t/apps/radarr/config/radarr.db-shm

# /mnt/hd2t/media/movies/ NO se respalda como backup del homelab. La biblioteca
# multimedia es contenido reconstruible (vía Radarr + indexadores) y se
# considera "fuente externa" en términos de backup. Si se quisiera respaldar,
# iría a un disco externo aparte con su propia política, NO a Borg.
```

Qué se respalda:

| Fichero | Por qué se incluye |
|---|---|
| `config.xml` | Configuración global: API key, auth method, URL base, branch, log level. Restaurarlo basta para reanudar Radarr como estaba (excepto el catálogo de películas, que vive en la DB). |
| `radarr.db` | **Crítico**: catálogo de películas con sus *quality profiles*, *minimum availability*, *root folders*, indexadores sincronizados, download clients, history, queue. Sin esto, hay que reañadir todas las películas a mano (TMDB ID, monitorización, calidad, etc.). |
| `Backups/scheduled/*.zip` | Backups internos del propio Radarr; redundantes con Borg pero útiles para restore rápido desde la UI. Pequeños (~MiB cada uno). |

Qué **no** se respalda:

| Fichero / dir | Por qué se excluye |
|---|---|
| `MediaCover/` | Cache regenerable. Radarr re-descarga posters desde TMDB al rescaneo. Decenas a cientos de MiB que no aportan al backup. |
| `logs/`, `update_logs/` | Diagnóstico, no estado. Si se pierden, no afecta al servicio. |
| `radarr.db-wal`, `radarr.db-shm` | Estado *write-ahead log* de SQLite. Borg podría capturarlos a medio commit; SQLite los recrea consistentes desde `radarr.db` al abrir. Mismo razonamiento que Sonarr y Prowlarr. |
| `/mnt/hd2t/media/movies/` | **Nunca**. La biblioteca es reconstruible vía indexadores; respaldarla cientos de GiB en Borg es desproporcionado. Si en el futuro se quiere protección, considerar un disco USB externo con `rsync` periódico (fuera de Borg). |

Procedimiento de restauración (si se cae el config):

```bash
# 1) Detener Radarr y mover el config corrupto a un lado
docker compose -f stacks/radarr/docker-compose.yml stop radarr
sudo mv /mnt/hd2t/apps/radarr/config{,.broken-$(date +%F)}

# 2) Restaurar desde Borg
sudo borg extract /mnt/hd2t/backups/borg::ARCHIVO mnt/hd2t/apps/radarr/config

# 3) Reajustar permisos por si el extract los movió
sudo chown -R homelab:homelab /mnt/hd2t/apps/radarr/config
sudo chmod 0750 /mnt/hd2t/apps/radarr/config

# 4) Arrancar Radarr
docker compose -f stacks/radarr/docker-compose.yml start radarr
docker logs -f radarr
# Esperar "Application started" en el log.

# 5) Verificar API key intacta
docker exec radarr grep -oP '(?<=<ApiKey>)[^<]+' /config/config.xml
# (debe coincidir con stacks/radarr/.env; si no coincide, actualizar
# Prowlarr Apps con la nueva)

# 6) Re-rescaneo de la biblioteca (Radarr verifica los hardlinks existentes)
# UI: System → Tasks → "Refresh Movie" → Run.
```

Frecuencia recomendada en Borgmatic: la ya documentada en `07-backups/02-borgmatic.md` (diaria). El `config/` de Radarr es modesto (cientos de MiB tras excluir caches) y muy comprimible/deduplicable: el coste marginal en cada snapshot es bajo.

---

## Referencias

- **Documentación oficial Radarr**: <https://wiki.servarr.com/radarr>
- **Quick Start (Radarr Wiki)**: <https://wiki.servarr.com/radarr/quick-start-guide>
- **API v3 reference**: <https://radarr.video/docs/api/>
- **Imagen Docker LinuxServer.io**: <https://docs.linuxserver.io/images/docker-radarr/>
- **Repositorio LSIO**: <https://github.com/linuxserver/docker-radarr>
- **Releases (changelog antes de subir versión)**: <https://github.com/Radarr/Radarr/releases>
- **TRaSH guides — Radarr quality profiles (HD)**: <https://trash-guides.info/Radarr/Radarr-Quality-Settings-File-Size/>
- **TRaSH guides — Radarr quality profiles (UHD)**: <https://trash-guides.info/Radarr/radarr-setup-quality-profiles-anime/>
- **TRaSH guides — Radarr naming scheme**: <https://trash-guides.info/Radarr/Radarr-recommended-naming-scheme/>
- **TRaSH guides — Hardlinks e Instant Moves**: <https://trash-guides.info/Hardlinks/Hardlinks-and-Instant-Moves/>
- **TMDB (fuente de metadatos)**: <https://www.themoviedb.org/>
- **Documentos hermanos en este repo**:
  - `01-transmission.md` (cliente BitTorrent que Radarr usa como *download client*).
  - `02-prowlarr.md` (gestor de indexadores; Radarr recibe sus indexadores vía Apps Sync).
  - `03-sonarr.md` (gemelo de Radarr para series; mismo patrón aplicado a TV).
  - `09-multimedia/01-jellyfin.md` (consumidor final de `/mnt/hd2t/media/movies`).
  - `03-red/04-caddy.md` (snippets `lan_tls`, `security_headers`, `healthcheck`, `authelia_two_factor`).
  - `04-seguridad/01-authelia.md` (regla `forward_auth` y mecanismo de bypass por path).
  - `07-backups/02-borgmatic.md` (políticas y rotación; aquí solo aporta el fragmento de fuentes/exclusiones).
  - `01-sistema/04-estructura-directorios.md` (estructura `/mnt/hd2t/media/movies` y grupo `media`).
