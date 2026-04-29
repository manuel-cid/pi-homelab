# Sonarr

## Descripción

Tras desplegar Transmission (`01-transmission.md`) como motor de descarga y Prowlarr (`02-prowlarr.md`) como gestor de indexadores, el homelab tiene cómo **bajar bytes** y cómo **encontrarlos**, pero todavía no tiene **quién decida qué descargar y cómo organizarlo**. Esa es la motivación de este documento.

**Sonarr** es el *PVR* (Personal Video Recorder) del stack `*arr` para **series de televisión**. Su rol concreto en este homelab:

1. **Mantener el catálogo de series**: el operador añade una serie por nombre (TVDB ID, IMDb), Sonarr la guarda en su base de datos SQLite con todos los episodios (pasados y futuros), su *quality profile*, su *language profile* y su *root folder*.
2. **Monitorizar nuevas releases** consultando a Prowlarr (`http://prowlarr:9696/api/v1/search`) periódicamente, evaluando cada resultado contra el *quality profile* (preferencias de resolución, codec, source, grupo de release) y descartando lo que no encaje.
3. **Encolar la mejor release** en Transmission (`http://transmission:9091/transmission/rpc`) vía RPC, con autenticación HTTP Basic (las mismas credenciales que ya usa el operador desde la UI).
4. **Importar al terminar**: cuando Transmission marca un torrent como completo, Sonarr lo detecta por polling al RPC, mueve los ficheros desde `/downloads/complete/<release>/` a `/media/tv/<Serie>/Season XX/<Serie> - SXXEYY - Title.ext` aplicando su esquema de nombres, y crea un **hardlink** en lugar de copiar (origen y destino comparten filesystem en hd2t; ver `01-transmission.md` "Decisión: hardlinks vs copy"). Transmission sigue seedeando el original hasta cumplir ratio; el hardlink en `/media/tv/` queda visible para Jellyfin (Fase 9) inmediatamente.
5. **Reescanear y mantener**: vigila la biblioteca por cambios fuera de su control (ficheros añadidos manualmente, episodios borrados), procesa renombres si el operador cambia el esquema, y reintenta descargas fallidas.
6. **Exponer una UI web** (`https://sonarr.${DOMAIN_LAN}/`) protegida por Authelia 2FA, donde el operador añade series, ajusta calidades, revisa la cola y diagnostica errores.

Lo que este documento **no** decide:

- **Qué series ver**: las añade el operador desde la UI según gusto. No se versiona la lista en git.
- **Política de retención de calidad** más allá de los *quality profiles* recomendados: si el operador prefiere upgrade hasta 4K REMUX o detenerse en 1080p WEBDL, lo decide en *Settings → Profiles*.
- **Anime vs Series occidentales en una sola instancia**: Sonarr soporta ambas con *Series Type: Anime* en cada serie individual, ajustando numeración (absolute vs season/episode). Aquí se documenta una **única instancia** que sirve para los dos casos. Si en el futuro la divergencia operativa se hace evidente (perfiles muy distintos, indexadores muy distintos), se podría duplicar como `sonarr-anime` con su propio stack — reabrible pero no por defecto.
- **Cliente de descarga alternativo**: solo Transmission, ya documentado. Sonarr soporta varios; aquí solo se configura uno.
- **Notificaciones a Telegram, Discord, Apprise**: la integración existe en `Settings → Connect`, se difiere a un doc transversal de notificaciones (Fase 5/12, no aquí).
- **Subtítulos automáticos** (Bazarr): es un servicio aparte que se acopla a Sonarr/Radarr; no está en el plan actual de la Fase 10. Reabrible.
- **Apertura al exterior**: como el resto del homelab, Sonarr es **solo LAN + tailnet**. Su UI y su API solo se acceden por Caddy con Authelia. Sonarr le habla a Prowlarr y a Transmission **directamente al bridge `homelab`** sin pasar por Caddy.

Cuando este documento se haya aplicado, el operador puede:

- Abrir `https://sonarr.${DOMAIN_LAN}/` desde la LAN (con CA interna instalada, protegida por Authelia 2FA) o `https://sonarr.${DOMAIN_TS}/` desde el tailnet, autenticarse con Authelia y ver la UI de Sonarr.
- Tener Prowlarr conectado en *Settings → Indexers* como única fuente, con todos los indexadores activos en Prowlarr replicados automáticamente.
- Tener Transmission conectado en *Settings → Download Clients* con autenticación verificada (Sonarr puede listar la cola actual de TR).
- Tener un *Root Folder* configurado en `/media/tv` (bind mount a `/mnt/hd2t/media/tv`), un *Quality Profile* "1080p WEBDL/Bluray" por defecto y un *Language Profile* "Spanish + English".
- Añadir una serie de prueba (p. ej. "Big Buck Bunny" o cualquiera disponible en los indexadores), monitorizarla, y observar el ciclo completo: búsqueda → encolado en TR → descarga → import por hardlink → aparición en `/mnt/hd2t/media/tv/...` con el esquema de nombres aplicado.
- Tener `/mnt/hd2t/apps/sonarr/config/` respaldado por Borgmatic (`config.xml`, `sonarr.db`, `Backups/`), excluyendo `MediaCover/` y `logs/`.

> **Recordatorio de alcance**: el tráfico saliente que genera Sonarr (consultas a TVDB, búsquedas vía Prowlarr a indexadores, `.torrent` descargados antes de pasarlos a TR) sale por HTTPS estándar. No requiere apertura de puertos entrantes. La política del homelab (no port-forwarding) se mantiene intacta.

---

## Requisitos Previos

- **Fase 0–1** completas: discos `hd2t` montado en `/mnt/hd2t`, grupo `media` con GID `1100`, usuario `homelab` (UID 1000) miembro del grupo, estructura `/mnt/hd2t/media/tv/` con owner `homelab:media` y modo `2770` (setgid). Ver `01-sistema/04-estructura-directorios.md`.
- **Fase 2** completa: Docker Engine + Compose v2; red `homelab` en `172.30.10.0/24`; convenciones `stacks/<svc>/`; `.env` global con `TZ=Europe/Madrid`, `PUID=1000`, `PGID=1000`, `DOMAIN_LAN=lan`, `DOMAIN_TS` si aplica.
- **Fase 3** completa, en particular:
  - Pi-hole con el comodín `address=/lan/192.168.1.10` (cubre `sonarr.${DOMAIN_LAN}` automáticamente).
  - Caddy desplegado y los snippets `(lan_tls)`, `(security_headers)`, `(healthcheck)`, `(authelia_two_factor)` en `Caddyfile`.
  - Tailscale operativo y, si se quiere acceso por `sonarr.${DOMAIN_TS}`, `tailscale cert` ya emitiendo (`03-red/05-tailscale.md`).
- **Fase 4** completa: Authelia desplegado con 2FA; Sonarr se protege con `forward_auth`. El **endpoint `/api/v3/...`** se exonera por path para que la API key nativa de Sonarr siga siendo el mecanismo de auth para clientes programáticos (Prowlarr sync, Bazarr en el futuro, etc.). Ver "Decisión: autenticación" abajo.
- **Fase 7** opcional pero recomendable: Borgmatic operativo, para añadir `/mnt/hd2t/apps/sonarr/config` al inventario de fuentes.
- **Fase 10 pasos anteriores**:
  - Transmission desplegado (`01-transmission.md`) con su RPC accesible en `http://transmission:9091/transmission/rpc`, credenciales en `stacks/transmission/.env` (`TRANSMISSION_RPC_USER`, `TRANSMISSION_RPC_PASS`).
  - Prowlarr desplegado (`02-prowlarr.md`) con al menos un indexador público probado y la API key disponible en `stacks/prowlarr/.env` (`PROWLARR_API_KEY`).
- Conocimiento del **TVDB ID** o nombre exacto de las primeras series a probar (Sonarr usa TVDB como fuente de metadatos por defecto; ver "Decisión: metadatos" abajo).

Comprobaciones rápidas:

```bash
# La red Docker compartida existe y los servicios previos están sanos
docker network inspect homelab --format '{{.Name}}' | grep -q '^homelab$' && echo ok
docker ps --filter name=caddy --filter name=authelia \
          --filter name=transmission --filter name=prowlarr \
          --format '{{.Names}} {{.Status}}'

# sonarr.lan resuelve al IP de la Pi (gracias al comodín de Pi-hole)
dig +short sonarr.lan @192.168.1.2
# 192.168.1.10

# Estructura de biblioteca correcta
stat -c '%a %U:%G %n' /mnt/hd2t/media /mnt/hd2t/media/tv
# 2770 homelab:media /mnt/hd2t/media
# 2770 homelab:media /mnt/hd2t/media/tv

# downloads/ y media/ están en el MISMO filesystem (requisito para hardlinks)
stat -c '%m' /mnt/hd2t/downloads/complete /mnt/hd2t/media/tv
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

## Decisión: PVR — Sonarr (v4), no SickChill ni Medusa

| PVR | Pros | Contras | Veredicto |
|---|---|---|---|
| **Sonarr** (v4) | Estándar de facto del ecosistema `*arr`, integración bidireccional con Prowlarr (Apps Sync), soporte nativo de hardlinks, `quality profiles` con *custom formats* (TRaSH-style), naming flexible, comunidad enorme. v4 estabilizó migrations desde v3 y mejoró el manejo de anime (numeración absoluta + season). | Stack `.NET` con consumo moderado de RAM (~250–400 MiB). Curva de aprendizaje en *quality profiles* + *custom formats*. | **Aceptado**. |
| SickChill | Histórico, Python, ligero. | Mantenimiento intermitente, sin sync con Prowlarr (usaría Jackett), UI antigua, hardlinks con configuración manual. | Descartado. |
| Medusa | Fork de SickRage, comunidad activa, Python. | Igual que SickChill respecto a Prowlarr (sin sync nativo, Jackett), pierde la coherencia LSIO/`*arr` del homelab. | Descartado. |
| Sonarr v3 | Estable, conocido. | EOL anunciado, Prowlarr v1 está orientado a v3+v4, los releases nuevos son solo en v4. | Descartado. |

**Decisión**: Sonarr v4. Es el siguiente eslabón natural del catálogo Servarr/LSIO ya en uso (Transmission, Prowlarr) y es lo que entiende Prowlarr al sincronizar.

---

## Decisión: imagen — LinuxServer.io

Sonarr v4 tiene varias imágenes públicas relevantes:

| Imagen | Mantenedor | Tag | Pros | Contras |
|---|---|---|---|---|
| `lscr.io/linuxserver/sonarr` | LinuxServer.io | `:4.0.9` (multi-arch arm64) | UID/GID configurables, mismo patrón que Transmission/Prowlarr/Radarr/Jellyfin/Audiobookshelf/Calibre-Web/Stash, scripts s6-overlay, *automatic permissions fix* del directorio `/config` al arrancar. | Una capa entre upstream y operador. |
| `ghcr.io/hotio/sonarr` | hotio | `:release` | Sigue stables de upstream, opciones de mods. | Convenciones distintas (no usa `PUID`/`PGID` clásico, usa `UMASK_SET`). Romper la homogeneidad del homelab no compensa. |
| Imagen oficial `sonarr/sonarr` | Servarr team | varios | Construida por upstream. | Menos opinada (sin handler de permisos automático), tag `latest` puede apuntar a `develop` en algunas variantes. Hay que vigilar más. |

**Decisión**: `lscr.io/linuxserver/sonarr:4.0.9`.

Razones:

- **Coherencia con todo el catálogo Fase 9 + Fase 10**: misma forma (`PUID`/`PGID`/`UMASK`/`TZ`), misma idea de bind mounts, misma s6-overlay debajo.
- **Pin de versión completa** (no `latest`, no `4.0`): Sonarr v4 ha tenido cambios de schema en `sonarr.db` durante la serie 4.0.x; pin estricto evita un *salto silencioso* a una versión que rompa las migrations sin que el operador haya hecho backup. Watchtower NO actualiza automáticamente este contenedor.

Actualizaciones: `docker compose pull && up -d` tras leer el changelog de Sonarr (cambios de schema requieren backup previo del config). La etiqueta de Watchtower deja explícito el opt-out:

```yaml
labels:
  com.centurylinklabs.watchtower.enable: "false"
```

---

## Decisión: networking — bridge `homelab`, sin `ports:` publicados

| Modo | Pros | Contras | Veredicto |
|---|---|---|---|
| **Bridge `homelab`** (sin `ports:`) | Sonarr en `172.30.10.X`. Caddy hace `reverse_proxy http://sonarr:8989`. API interna entre `sonarr`, `prowlarr`, `transmission` por DNS de Docker. | Ningún acceso desde el host directamente (lo que es deseado: la UI siempre va por Caddy). | **Aceptado**. |
| `network_mode: host` | Sonarr escucha en `:8989/tcp` del host. | Innecesario (Sonarr no necesita pila de red completa del host), rompe el patrón del bridge, complica el `Caddyfile`. | Descartado. |
| Bridge **+** `ports: ["8989:8989"]` | Acceso directo desde la LAN al `:8989`. | Comprometería el patrón "todo por Caddy con Authelia": cualquiera de la LAN podría hablarle al `:8989` saltándose el 2FA. La API key seguiría como única defensa en ese path. | Descartado. |

Resultado: **bridge `homelab`**, sin `ports`. La UI y API se acceden únicamente vía Caddy (`https://sonarr.${DOMAIN_LAN}/`). Prowlarr, Transmission y, en el futuro, Bazarr le hablan a `http://sonarr:8989` por la red interna.

---

## Decisión: autenticación — Authelia delante de la UI, API key nativa para clientes

Sonarr v4 trae **autenticación nativa** propia (Forms con username/password almacenados en `config.xml`, hash bcrypt) y **API key** para clientes programáticos. El homelab combina ambas, igual que con Prowlarr:

| Path | Quién accede | Estrategia |
|---|---|---|
| `/`, `/static/...`, `/login`, `/UI/...` (UI humana) | Operador desde navegador | **Authelia 2FA** (`forward_auth`). Tras superar Authelia, Caddy reenvía a `http://sonarr:8989`. La autenticación nativa de Sonarr se **deshabilita** poniendo `AuthenticationMethod=External` + `AuthenticationRequired=DisabledForLocalAddresses` (ver "Configuración" abajo): así Sonarr confía en que quien le llega ya está autenticado por la capa anterior. |
| `/api/v3/...` | Prowlarr (Apps Sync), Bazarr futuro, scripts del operador | **Bypass de Authelia**: usan la **API key** de Sonarr (header `X-Api-Key`). Authelia no se aplica a este path. |
| `/feed/...`, `/ping` | Health-checks y feeds RSS internos | **Bypass de Authelia** (sin auth en `/ping`; API key para feeds). |

En la práctica, **Prowlarr y Transmission no pasan por Caddy en absoluto**: hablan directamente al bridge `homelab` con `http://sonarr:8989/api/v3/...` y la API key. Sonarr, a su vez, le habla a Prowlarr y a Transmission sin pasar por Caddy. La razón de mantener los bypasses por path en el `Caddyfile` es para clientes externos (en el tailnet, p. ej.) que quieran consumir la API sin pasar por Authelia. Reabrible.

> **Sobre `AuthenticationRequired=DisabledForLocalAddresses`**: en Sonarr, "Local Addresses" se interpreta como las redes RFC1918 que llamen al servicio. La red `homelab` (`172.30.10.0/24`) y `127.0.0.1` cuentan como locales. Esto permite que **Prowlarr no necesite password de Sonarr** (solo API key) mientras que la UI sigue exigiendo Authelia delante (porque la conexión externa entra por Caddy y se trata como remota). Si se quisiera blindar más, cambiar a `Enabled` y manejar tanto cookie de Authelia como API key — innecesario en este alcance.

> **¿Por qué no usar la auth nativa Forms?** Tres razones, idénticas a las de Prowlarr: (a) duplicaría credenciales (Authelia ya gestiona el login del homelab), (b) la auth nativa no es 2FA, (c) sería el único servicio del homelab autenticado fuera del SSO. La elección es coherente con cómo se trata el resto de UIs del catálogo.

---

## Decisión: dónde viven los datos y permisos

Sonarr maneja **tres zonas de disco**, cada una con su régimen de permisos:

| Tipo | Dónde | Owner:Group | Modo | Observaciones |
|---|---|---|---|---|
| **Config + DB** (`config.xml`, `sonarr.db`, `sonarr.db-wal`, `sonarr.db-shm`, `Backups/`, `MediaCover/`, `logs/`) | `/mnt/hd2t/apps/sonarr/config/` | `homelab:homelab` (`1000:1000`) | `0750` | LSIO escribe como `PUID:PGID`. Crítico para backup (DB SQLite con catálogo de series, profiles, naming, history, queue). |
| **Descargas terminadas** (lectura) | `/mnt/hd2t/downloads/` | `homelab:media` (`1000:1100`) | `2770` | Sonarr necesita **leer** los ficheros que TR ha dejado en `complete/` para importarlos. Compartido vía bind mount con TR. |
| **Biblioteca de TV** (lectura+escritura) | `/mnt/hd2t/media/tv/` | `homelab:media` (`1000:1100`) | `2770` | Sonarr crea aquí los hardlinks tras el import, los renombra y los borra cuando hace upgrade. |

Bind mounts elegidos:

```yaml
volumes:
  - /mnt/hd2t/apps/sonarr/config:/config
  # Punto único de montaje de descargas. Compartido con Transmission y Radarr.
  # CRÍTICO para hardlinks: ver razón abajo.
  - /mnt/hd2t/downloads:/downloads
  - /mnt/hd2t/media/tv:/media/tv
```

Razones:

- **Bind mount `/downloads` exactamente como en Transmission** (mismo path en el host, mismo path dentro del contenedor). Si Sonarr montara `/downloads/complete` en lugar de `/downloads`, los paths que devuelve TR por RPC (`/downloads/complete/<release>/`) **no coincidirían** con lo que Sonarr ve dentro de su contenedor, y el import fallaría con un error críptico de "remote path mapping". Mantener **el mismo prefijo** en ambos contenedores es la regla de oro.
- **Bind mount `/media/tv` con el mismo path en host y contenedor**: Jellyfin (Fase 9) ya monta `/mnt/hd2t/media` con `/media` como prefijo. Sonarr debe usar **el mismo prefijo dentro del contenedor** para que los hardlinks queden en una ruta que Jellyfin pueda leer (mismo inodo, distinto bind, mismo filesystem).
- **`UMASK=002`** (en lugar del `022` global): coherente con TR. Los ficheros que Sonarr crea o renombra en `/media/tv/` salen con grupo escribible (`0664`), y los directorios con `0775`. Permite que Radarr (UID 1000, grupo 1100) o, en el futuro, Bazarr puedan operar en la misma jerarquía.
- **`group_add: [1100]`**: Sonarr corre con `PUID=1000, PGID=1000`, pero necesita ser miembro del grupo `media` (1100) para escribir en `/media/tv/` (modo `2770`). El `group_add` es la vía estándar en LSIO para añadir grupos suplementarios al UID del proceso.
- **Hardlinks comprobados al arrancar**: en *Settings → Media Management*, activar "Use Hardlinks instead of Copy" (es el default de v4, pero conviene confirmarlo). Sonarr probará al primer import si puede hacer un hardlink entre `/downloads/complete/...` y `/media/tv/...`; si no puede (filesystems distintos, permisos), caerá a copy con un warning visible en la UI.

---

## Stack: `stacks/sonarr/`

### Layout en disco

| Ruta | Soporte | Contenido |
|---|---|---|
| `stacks/sonarr/docker-compose.yml` | microSD (git) | Stack (servicio `sonarr`). |
| `stacks/sonarr/.env.example` | microSD (git) | Plantilla con `SONARR_API_KEY` (vacía hasta el primer arranque) y referencias a `PROWLARR_API_KEY` y credenciales de Transmission. |
| `stacks/caddy/conf.d/12-sonarr.caddy` | microSD (git) | Drop-in del bloque LAN+tailnet para `sonarr.${DOMAIN_LAN}` y `sonarr.${DOMAIN_TS}`. |
| `/mnt/hd2t/apps/sonarr/config/` | hd2t | `config.xml`, `sonarr.db`, `Backups/`, `MediaCover/`, `logs/`. Owner `homelab:homelab`, modo `0750`. |
| `/mnt/hd2t/media/tv/` | hd2t | Biblioteca destino (compartida con Jellyfin). Owner `homelab:media`, modo `2770`. |

### `stacks/sonarr/docker-compose.yml`

```yaml
# Sonarr — PVR de series del homelab.
# Documentado en docs/10-descargas/03-sonarr.md.
#
# Networking: bridge homelab. Caddy hace reverse proxy hacia sonarr:8989.
# Sonarr le habla a prowlarr:9696 (búsquedas) y a transmission:9091 (descargas)
# por la red interna; Prowlarr le habla a sonarr:8989 para el sync de Apps.

name: sonarr

networks:
  homelab:
    external: true

services:
  sonarr:
    image: lscr.io/linuxserver/sonarr:4.0.9
    container_name: sonarr
    hostname: sonarr
    restart: unless-stopped

    networks:
      - homelab

    # NO se publican puertos al host. La UI va por Caddy (https://sonarr.lan)
    # y el API lo consumen Prowlarr/Bazarr dentro del bridge homelab.
    # ports:
    #   - "8989:8989"   # NO: comprometería el patrón de Caddy + Authelia.

    environment:
      TZ: ${TZ}
      PUID: ${PUID}              # 1000 (homelab)
      PGID: ${PGID}              # 1000 (homelab)
      UMASK: "002"               # ficheros 0664, dirs 0775 → grupo media escribe

    # group_add para que el contenedor escriba en /media/tv y lea /downloads
    # como grupo media. Igual que Transmission.
    group_add:
      - "1100"   # media (creado en 01-sistema/04-estructura-directorios.md)

    volumes:
      - /mnt/hd2t/apps/sonarr/config:/config
      # MISMO prefijo que en Transmission (CRÍTICO para que los paths del
      # RPC de TR coincidan dentro de Sonarr y los hardlinks funcionen).
      - /mnt/hd2t/downloads:/downloads
      # MISMO prefijo que en Jellyfin (CRÍTICO para que el media server vea
      # los hardlinks tras el import).
      - /mnt/hd2t/media/tv:/media/tv
      - /etc/localtime:/etc/localtime:ro

    healthcheck:
      # /ping es endpoint público sin auth ni API key: 200 ⇒ alive.
      test:
        - CMD-SHELL
        - >
          curl -fsS -o /dev/null -w '%{http_code}' http://127.0.0.1:8989/ping |
          grep -E '^200$' >/dev/null
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 45s

    labels:
      homelab.role: "pvr-tv"
      homelab.backup: "true"
      # Watchtower NO actualiza automáticamente: tag completo (4.0.9).
      # Cambios menores de Sonarr a veces migran schema de sonarr.db: leer
      # release notes y hacer backup antes de subir versión.
      com.centurylinklabs.watchtower.enable: "false"
```

> **Sobre el `start_period: 45s`**: Sonarr tarda más que Prowlarr en arrancar la primera vez (migrations de DB + warm-up de `.NET`). En arranques sucesivos suele estar healthy en 15–20 s, pero el margen amplio evita falsos `unhealthy` en upgrades.

### `stacks/sonarr/.env.example`

```bash
# stacks/sonarr/.env.example
# Copiar a stacks/sonarr/.env (chmod 0600) y rellenar.
#
# Las generales (TZ, PUID, PGID, DOMAIN_LAN, DOMAIN_TS) vienen del .env GLOBAL.

# API key de Sonarr.
#
# Se genera automáticamente al primer arranque y queda en config.xml
# (clave <ApiKey>). Tras el primer up:
#   docker exec sonarr grep -oP '(?<=<ApiKey>)[^<]+' /config/config.xml
# Copiar el valor aquí. Prowlarr (Apps sync) y, en el futuro, Bazarr leerán
# esta variable.
SONARR_API_KEY=

# Credenciales de servicios consumidos. NO se duplican aquí: se importan
# del .env GLOBAL al levantar el stack con --env-file. Documentadas para
# que el operador sepa qué necesita Sonarr en Settings:
#
#   PROWLARR_API_KEY        (de stacks/prowlarr/.env)  → Settings → Indexers
#   TRANSMISSION_RPC_USER   (de stacks/transmission/.env) → Settings → Download Clients
#   TRANSMISSION_RPC_PASS   (de stacks/transmission/.env) → idem
```

### Drop-in de Caddy: `stacks/caddy/conf.d/12-sonarr.caddy`

```caddy
# /etc/caddy/conf.d/12-sonarr.caddy — bloques de Sonarr.
# Documentado en docs/10-descargas/03-sonarr.md.
#
# UI protegida por Authelia 2FA. Endpoint /api/v3, /feed y /ping en bypass
# para permitir que clientes legítimos (Prowlarr Apps Sync, futuras
# integraciones) sigan funcionando si en algún momento se accediera vía
# Caddy en lugar de directamente al bridge.

# ---- Acceso LAN -----------------------------------------------------------
sonarr.{$DOMAIN_LAN} {
    import lan_tls
    import security_headers
    import healthcheck

    # Bypass para API y feeds: la integración con clientes programáticos usa
    # la API key nativa de Sonarr, no el flujo de Authelia.
    @api {
        path /api/v3 /api/v3/*
        path /feed/* /feed
        path /ping
    }
    handle @api {
        reverse_proxy http://sonarr:8989
    }

    # UI humana: Authelia 2FA delante.
    handle {
        import authelia_two_factor
        reverse_proxy http://sonarr:8989
    }
}

# ---- Acceso Tailscale -----------------------------------------------------
# Solo se materializa si DOMAIN_TS está definido (tailnet con tailscale cert).
sonarr.{$DOMAIN_TS} {
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
        reverse_proxy http://sonarr:8989
    }

    handle {
        import authelia_two_factor
        reverse_proxy http://sonarr:8989
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
[ -d /mnt/hd2t/media/tv ] \
    || sudo install -d -o homelab -g media -m 2770 /mnt/hd2t/media/tv

# 3) Confirmar que downloads/ y media/ comparten filesystem (hardlinks).
[ "$(stat -c '%m' /mnt/hd2t/downloads/complete)" = \
  "$(stat -c '%m' /mnt/hd2t/media/tv)" ] \
  || { echo "ERROR: downloads y media en filesystems distintos."; exit 1; }

# 4) Crear directorios persistentes del servicio (idempotente).
sudo install -d -o homelab -g homelab -m 0750 /mnt/hd2t/apps/sonarr
sudo install -d -o homelab -g homelab -m 0750 /mnt/hd2t/apps/sonarr/config

# 5) Crear .env (vacía la API key; se rellena tras el primer arranque).
cp stacks/sonarr/.env.example stacks/sonarr/.env
chmod 0600 stacks/sonarr/.env

# 6) Materializar Caddy drop-in.
install -o homelab -g homelab -m 0644 \
    stacks/sonarr/../caddy/conf.d/12-sonarr.caddy \
    /mnt/hd2t/apps/caddy/etc/conf.d/12-sonarr.caddy

# 7) Levantar el stack.
docker compose \
    -f stacks/sonarr/docker-compose.yml \
    --env-file stacks/sonarr/.env \
    up -d

# 8) Recargar Caddy para que aplique el nuevo drop-in.
docker exec caddy caddy reload --config /etc/caddy/Caddyfile

# 9) Esperar healthy (Sonarr tarda ~30 s en su primer arranque).
docker ps --filter name=sonarr --format '{{.Names}} {{.Status}}'
# sonarr   Up 45s (healthy)

# 10) Extraer la API key generada y rellenarla en .env.
API_KEY="$(docker exec sonarr grep -oP '(?<=<ApiKey>)[^<]+' /config/config.xml)"
sed -i "s|^SONARR_API_KEY=$|SONARR_API_KEY=${API_KEY}|" stacks/sonarr/.env
echo "SONARR_API_KEY=${API_KEY}" >&2   # confirmación visual; no commitear el valor.
```

---

## Configuración

Tras el primer arranque, Sonarr genera `/mnt/hd2t/apps/sonarr/config/config.xml` y `sonarr.db` con valores por defecto. Hay cuatro bloques que configurar **en este orden**: autenticación (igual que Prowlarr), root folder + media management, indexador (Prowlarr) y download client (Transmission). Después se ajustan profiles de calidad e idioma.

### 1) Ajustar `config.xml` para Authelia

`config.xml` se reescribe por Sonarr al cambiar settings desde la UI; las modificaciones manuales **se hacen con el contenedor parado**.

```bash
docker compose -f stacks/sonarr/docker-compose.yml stop sonarr
sudo -u homelab "$EDITOR" /mnt/hd2t/apps/sonarr/config/config.xml
docker compose -f stacks/sonarr/docker-compose.yml start sonarr
```

Valores relevantes:

```xml
<Config>
  <BindAddress>*</BindAddress>
  <Port>8989</Port>
  <SslPort>9898</SslPort>
  <EnableSsl>False</EnableSsl>
  <LaunchBrowser>False</LaunchBrowser>
  <ApiKey>...generada al primer arranque, NO TOCAR...</ApiKey>
  <AuthenticationMethod>External</AuthenticationMethod>
  <AuthenticationRequired>DisabledForLocalAddresses</AuthenticationRequired>
  <Branch>main</Branch>
  <LogLevel>info</LogLevel>
  <SslCertPath></SslCertPath>
  <SslCertPassword></SslCertPassword>
  <UrlBase></UrlBase>
  <InstanceName>Sonarr</InstanceName>
  <UpdateMechanism>Docker</UpdateMechanism>
</Config>
```

Justificación de los valores (idénticos en espíritu a Prowlarr):

| Clave | Valor | Razón |
|---|---|---|
| `AuthenticationMethod` | `External` | Sonarr asume que la auth la resuelve la capa de delante (Authelia/Caddy). No pide login propio. |
| `AuthenticationRequired` | `DisabledForLocalAddresses` | Prowlarr (Apps Sync) y futuras integraciones acceden con solo API key. Conexiones externas (vía Caddy) se tratan como autenticadas por Authelia. |
| `EnableSsl` | `False` | TLS lo termina Caddy. |
| `LaunchBrowser` | `False` | Headless. |
| `UrlBase` | vacío | Subdominio dedicado (`sonarr.lan`), no se necesita prefijo. |
| `UpdateMechanism` | `Docker` | Indica a Sonarr que **no** intente auto-actualizar el binario interno. |
| `LogLevel` | `info` | Suficiente; subir a `debug` solo para investigación puntual. |
| `Branch` | `main` | Stable en v4. (En v3 era `master`; el rename ocurrió en la transición.) |

### 2) Verificar UI

1. `https://sonarr.${DOMAIN_LAN}/` → Authelia pide 2FA → al pasar, aparece la UI de Sonarr (sin login propio adicional, gracias a `AuthenticationMethod=External`).
2. `Settings → General → Security`: confirmar **Authentication: External**, copiar la **API Key** (la misma que ya está en `.env`).
3. Si por algún motivo la quisieras rotar, *Reset* la regenera y hay que actualizar `stacks/sonarr/.env` y todos los clientes que la consuman (Prowlarr Apps).

### 3) Configurar *Root Folder* y *Media Management*

`Settings → Media Management`:

| Sección | Clave | Valor | Razón |
|---|---|---|---|
| Episode Naming | Rename Episodes | **on** | Sonarr aplica esquema al importar. |
| Episode Naming | Replace Illegal Characters | **on** | Para que ext4/NTFS futuros no se rompan. |
| Episode Naming | Standard Episode Format | `{Series Title} - S{season:00}E{episode:00} - {Episode Title} [{Quality Title}]` | Esquema clásico, legible por Jellyfin. |
| Episode Naming | Daily Episode Format | `{Series Title} - {Air-Date} - {Episode Title} [{Quality Title}]` | Para *Daily* shows (talk shows). |
| Episode Naming | Anime Episode Format | `{Series Title} - S{season:00}E{episode:00} - {absolute:000} - {Episode Title} [{Quality Title}]` | Numeración absoluta + season/episode. |
| Episode Naming | Series Folder Format | `{Series Title} ({Year})` | Convención TVDB. |
| Episode Naming | Season Folder Format | `Season {season:00}` | Compatible con Jellyfin. |
| Folders | Create empty series folders | **off** | No ensucia con carpetas vacías. |
| Folders | Delete empty folders | **on** | Limpieza tras *unmonitor* y borrado. |
| Importing | Use Hardlinks instead of Copy | **on** | **Crítico**. Es el default en v4, confirmar. |
| Importing | Import Extra Files | **off** | No importa `.nfo`, `.srt` sueltos del torrent (Bazarr los gestionará a futuro). |
| Importing | Unpack | **off** | Los releases que importan suelen venir sin compresión; si llegan en `.rar`, se gestiona caso a caso (no merece la pena el riesgo de unpack automático). |
| File Management | Unmonitor Deleted Episodes | **on** | Si el operador borra un fichero a mano, Sonarr no lo re-descarga. |
| File Management | Set Permissions | **on** | Aplica `chmod` tras import (con UMASK 002). |
| Root Folders | (añadir) | `/media/tv` | Path **dentro del contenedor**; corresponde a `/mnt/hd2t/media/tv` en host. |

> **Sobre "Set Permissions"**: combinado con `UMASK=002` y `group_add: 1100`, garantiza que ficheros importados sean `0664` `homelab:media`. Sin esto, Sonarr respeta el modo del torrent original (que TR ya entrega correcto, así que es defensa en profundidad).

> **Sobre el formato de naming**: el esquema documentado es **simplificado** respecto a las recomendaciones TRaSH (que añaden tags de release group, codec, MediaInfo). Para un homelab personal sin pretensión de "release archival", el esquema corto basta y deja nombres legibles. Si en el futuro se quiere alinear con TRaSH al 100%, los esquemas oficiales están en [TRaSH guides — Sonarr naming](https://trash-guides.info/Sonarr/Sonarr-recommended-naming-scheme/) y son drop-in replacements.

### 4) Conectar a Prowlarr (vía Apps de Prowlarr, no aquí)

A diferencia de instalaciones legacy con Jackett, **Sonarr no añade indexadores manualmente**: los recibe vía sync desde Prowlarr.

Desde la UI de **Prowlarr** (`https://prowlarr.${DOMAIN_LAN}/`):

1. *Settings → Apps → Add → Sonarr*.
2. Rellenar:
   - **Name**: `Sonarr`
   - **Sync Level**: `Full Sync` (Prowlarr replica indexadores y *Tags* con bidirección).
   - **Prowlarr Server**: `http://prowlarr:9696` (DNS interno; **no** el subdominio de Caddy).
   - **Sonarr Server**: `http://sonarr:8989`
   - **API Key**: la `SONARR_API_KEY` de `stacks/sonarr/.env`.
3. *Test* → debe pasar. *Save*.
4. Volver a *Settings → Indexers* en Prowlarr y forzar un *Sync App Indexers* desde el menú contextual de cada indexador, o esperar al sync periódico (cada 15 min).
5. En Sonarr, *Settings → Indexers*: deben aparecer los indexadores de Prowlarr con el tag `prowlarr`. **No tocar manualmente**: los gestiona Prowlarr.

> **Sobre Sync Level "Full Sync" vs "Add and Remove Only"**: con *Full Sync*, cualquier cambio en Prowlarr (URL del tracker, prioridad, categorías, *Sync Profile*) se propaga. Con *Add and Remove Only*, una vez creados los indexadores en Sonarr, los cambios son del lado Sonarr. **Full Sync** es la opción correcta para mantener Prowlarr como única fuente de verdad.

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
| Category | (vacío) | TR no usa categorías. |
| Directory | (vacío) | TR ya está configurado para escribir en `/downloads/complete/`. Si se rellena, Sonarr le pide a TR que escriba en *otra* ruta, lo que rompe el patrón. |
| Recent Priority | `Last` | Releases recientes con prioridad estándar. |
| Older Priority | `Last` | Idem. |
| Use SSL | **off** | Comunicación interna en el bridge `homelab`. |
| Add Paused | **off** | Encolar = empezar a bajar inmediatamente. |
| Client | `Transmission` | Tipo. |

*Test* → debe responder OK con detalles de la versión de TR. *Save*.

`Settings → Download Clients → Completed Download Handling`:

| Clave | Valor | Razón |
|---|---|---|
| Enable | **on** | Sonarr hace polling al RPC y recoge los completos. |
| Redownload Failed | **on** | Si un import falla (fichero corrupto, naming inválido), Sonarr reintenta con otro release. |

`Settings → Download Clients → Failed Download Handling`:

| Clave | Valor | Razón |
|---|---|---|
| Redownload | **on** | Si TR reporta un fallo, Sonarr busca otra release. |
| Remove from Client | **on** (o "On Import") | Tras import exitoso, Sonarr le pide a TR que borre el torrent (TR seguirá hasta cumplir ratio si esa policy está en TR; si Sonarr le pide remove inmediato, lo hace). Por defecto, dejar en **On Import** para no cortar el seeding antes de tiempo. |

> **Sobre "Remove Completed"**: la interacción TR↔Sonarr respecto a borrar el torrent tras import tiene sutilezas. Recomendación práctica: dejar a Sonarr que llame a `torrent-remove` **sin borrar fichero** (`delete-local-data: false`). El hardlink en `/media/tv/` mantiene los bytes vivos para el reproductor; TR seedea hasta cumplir su ratio sobre el `/downloads/complete/...` y luego se autodelete por la política de TR (`ratio-limit` y `idle-seeding-limit`). Esto suele "funcionar solo" si los defaults de TR y Sonarr no se tocan.

### 6) Ajustar *Quality Profiles*

`Settings → Profiles → Quality Profiles`:

Sonarr trae varios perfiles preconfigurados. La recomendación para el homelab (Pi 5 + biblioteca personal) es uno o dos perfiles, no proliferar:

| Perfil | Allowed | Upgrade Allowed | Cutoff | Uso |
|---|---|---|---|---|
| **HD-1080p** | `HDTV-1080p`, `WEBDL-1080p`, `WEBRip-1080p`, `Bluray-1080p` | **on** | `Bluray-1080p` | Default para cualquier serie nueva. Cubre el 99% de los casos. Pi 5 + Jellyfin transcoden 1080p sin problema y la biblioteca cabe holgada en hd5t. |
| **HD-720p** *(opcional)* | `HDTV-720p`, `WEBDL-720p`, `WEBRip-720p`, `Bluray-720p` | **on** | `WEBDL-720p` | Para series con muchas temporadas/episodios donde 1080p sería excesivo (procedurals largos). |
| ~~UHD-2160p~~ | — | — | — | **No** por defecto. La biblioteca de TV no necesita 4K en este homelab; 4K se reserva para películas seleccionadas en Radarr (`04-radarr.md`) si el operador lo decide. Reabrible. |

Crear el perfil `HD-1080p` (o editar el existente del mismo nombre): activar las cualidades listadas arriba en orden ascendente de preferencia (Sonarr selecciona la más alta disponible que cumpla las restricciones), poner *Cutoff* en `Bluray-1080p` (cuando esa cualidad esté disponible, parar de buscar upgrades).

> **Custom Formats** (avanzado): Sonarr v4 soporta *custom formats* para puntuar releases por release group, codec (x265 vs x264), HDR, audio (Atmos), etc. Para el homelab inicial **no se configuran**: añade complejidad sin un beneficio claro hasta que el operador descubra qué releases concretas le funcionan mejor. Reabrible siguiendo TRaSH guides.

### 7) Ajustar *Language Profile* (deprecated en v4: ahora "Languages" por serie)

En Sonarr v4, los *Language Profiles* fueron reemplazados por una columna **Original Language** + selección por serie. En `Settings → UI → Movie Info Language` (o equivalente para series): elegir `Spanish` como idioma de UI/metadatos. Por serie, en *Edit*, se puede fijar el idioma esperado (típicamente `Original`, que se traduce a inglés para la mayoría de series).

> **Sobre Bazarr**: si en el futuro se quiere subtítulos en español automáticamente, Bazarr es el complemento estándar; toma idiomas configurados aquí como input. No se despliega en este doc.

### 8) Smoke test del ciclo completo

Desde la UI de Sonarr:

1. *Series → Add New → Search* "Big Buck Bunny" (o cualquier serie/short legal disponible en los indexadores configurados).
2. *Quality Profile*: `HD-1080p`. *Root Folder*: `/media/tv`. *Monitor*: `All Episodes`. *Series Type*: `Standard`. *Search for missing episodes*: **on**.
3. *Add Series*. Sonarr lanza una búsqueda; tras unos segundos debería aparecer una *Activity → Queue* con un release encolado.
4. Abrir Transmission (`https://transmission.${DOMAIN_LAN}/`) y confirmar que el torrent está bajando en `/downloads/incomplete/`.
5. Esperar a que termine (depende del tamaño y peers). Sonarr lo detectará por polling (intervalo por defecto: ~1 min).
6. Verificar que Sonarr ha hecho el import: en *Activity → History*, debe aparecer `Episode Imported`. En el host:
   ```bash
   ls -lh /mnt/hd2t/media/tv/
   stat /mnt/hd2t/media/tv/<Serie>/Season\ 01/<file>.mkv
   # Links: 2  ← prueba del hardlink (1 en /downloads/complete + 1 en /media/tv)
   ```
7. Refrescar la biblioteca en Jellyfin (Fase 9): la nueva serie debería aparecer.
8. (Opcional) Borrar la serie de prueba: *Series → … → Delete* con "Delete files" si se quiere limpiar; el torrent en TR seguirá hasta cumplir ratio si así está configurado.

### 9) Smoke test del API

Desde otro contenedor del bridge:

```bash
docker run --rm --network homelab curlimages/curl \
  -H "X-Api-Key: $(grep ^SONARR_API_KEY stacks/sonarr/.env | cut -d= -f2)" \
  http://sonarr:8989/api/v3/system/status
# JSON con appName=Sonarr, version=4.0.9.x, branch=main, instanceName=Sonarr...

# Series catalogadas
docker run --rm --network homelab curlimages/curl \
  -H "X-Api-Key: $(grep ^SONARR_API_KEY stacks/sonarr/.env | cut -d= -f2)" \
  http://sonarr:8989/api/v3/series | head -c 200
# Array JSON con la serie de prueba.
```

---

## Almacenamiento

Volúmenes y bind mounts:

| Mount en contenedor | Bind en host | Contenido | Tamaño esperado |
|---|---|---|---|
| `/config` | `/mnt/hd2t/apps/sonarr/config` | `config.xml`, `sonarr.db` (+ `-wal`, `-shm`), `Backups/`, `MediaCover/` (posters cacheados de TVDB), `logs/`, `update_logs/` | 200 MiB – 2 GiB sostenidos. `MediaCover/` crece linealmente con el catálogo (1–5 MiB por serie); `Backups/` rota automáticamente. |
| `/downloads` | `/mnt/hd2t/downloads` | Solo **lectura** desde el punto de vista de Sonarr (los ficheros los crea TR; Sonarr los hardlinkea a `/media/tv/`). | Variable, no aporta huella propia (compartido). |
| `/media/tv` | `/mnt/hd2t/media/tv` | Biblioteca destino: `<Serie> ({Year})/Season XX/...`. | Función del catálogo. Cientos de GiB realistas. |
| `/etc/localtime` | `/etc/localtime:ro` | Zona horaria del host | KiB. Mantiene logs y horarios de búsqueda coherentes. |

Permisos:

- `/mnt/hd2t/apps/sonarr/config/`: `homelab:homelab` `0750`. Sonarr escribe como UID 1000.
- `/mnt/hd2t/downloads/`: heredado de TR (`homelab:media` `2770`). Sonarr lee/borra (al hacer import + cleanup) gracias a `group_add: 1100`.
- `/mnt/hd2t/media/tv/`: `homelab:media` `2770`. Sonarr crea hardlinks como `homelab:media` `0664` (gracias a `UMASK=002`) y directorios como `0775`. Jellyfin (mismo UID/grupo) podrá leerlos.

Comprobación en cualquier momento:

```bash
# Tamaño y contenido del directorio de config
sudo du -sh /mnt/hd2t/apps/sonarr/config /mnt/hd2t/apps/sonarr/config/*

# DB SQLite saludable
docker exec sonarr sqlite3 /config/sonarr.db 'PRAGMA integrity_check;'
# ok

# Hardlinks correctos en /media/tv (Links: >=2 = hardlink activo a /downloads)
sudo find /mnt/hd2t/media/tv -type f -name '*.mkv' -newer /tmp \
    -exec stat -c '%n nlink=%h' {} \; | head

# Backups internos de Sonarr (rotación automática)
ls -lh /mnt/hd2t/apps/sonarr/config/Backups/scheduled/
```

> **Sobre los backups internos de Sonarr**: igual que Prowlarr, la app genera backups completos del config en `Backups/scheduled/` cada semana (ZIP con `config.xml` + `sonarr.db`). Son **complementarios** a Borgmatic, no sustitutivos: sirven para *Restore* desde la propia UI tras un cambio mal hecho (rollback rápido sin tocar Borg). Borgmatic los respaldará junto al resto de `/config/`.

---

## Backup

Política para Borgmatic (Fase 7) — fragmento a integrar en su `config.yaml`:

```yaml
# borgmatic — fragmento para Sonarr
source_directories:
  - /mnt/hd2t/apps/sonarr/config

exclude_patterns:
  # Cache regenerable: Sonarr lo recrea desde TVDB al primer arranque.
  - /mnt/hd2t/apps/sonarr/config/MediaCover
  # Logs no son esenciales para restaurar el servicio.
  - /mnt/hd2t/apps/sonarr/config/logs
  - /mnt/hd2t/apps/sonarr/config/update_logs
  # WAL y SHM de SQLite pueden estar a medio escribir; Sonarr los regenera.
  - /mnt/hd2t/apps/sonarr/config/sonarr.db-wal
  - /mnt/hd2t/apps/sonarr/config/sonarr.db-shm

# /mnt/hd2t/media/tv/ NO se respalda como backup del homelab. La biblioteca
# multimedia es contenido reconstruible (vía Sonarr + indexadores) y se
# considera "fuente externa" en términos de backup. Si se quisiera respaldar,
# iría a un disco externo aparte con su propia política, NO a Borg.
```

Qué se respalda:

| Fichero | Por qué se incluye |
|---|---|
| `config.xml` | Configuración global: API key, auth method, URL base, branch, log level. Restaurarlo basta para reanudar Sonarr como estaba (excepto el catálogo de series, que vive en la DB). |
| `sonarr.db` | **Crítico**: catálogo de series con sus *quality profiles*, *language profiles*, *root folders*, indexadores sincronizados, download clients, history, queue. Sin esto, hay que reañadir todas las series a mano (TVDB ID, monitorización, calidad, etc.). |
| `Backups/scheduled/*.zip` | Backups internos del propio Sonarr; redundantes con Borg pero útiles para restore rápido desde la UI. Pequeños (~MiB cada uno). |

Qué **no** se respalda:

| Fichero / dir | Por qué se excluye |
|---|---|
| `MediaCover/` | Cache regenerable. Sonarr re-descarga posters desde TVDB al rescaneo. Decenas a cientos de MiB que no aportan al backup. |
| `logs/`, `update_logs/` | Diagnóstico, no estado. Si se pierden, no afecta al servicio. |
| `sonarr.db-wal`, `sonarr.db-shm` | Estado *write-ahead log* de SQLite. Borg podría capturarlos a medio commit; SQLite los recrea consistentes desde `sonarr.db` al abrir. Mismo razonamiento que Prowlarr. |
| `/mnt/hd2t/media/tv/` | **Nunca**. La biblioteca es reconstruible vía indexadores; respaldarla cientos de GiB en Borg es desproporcionado. Si en el futuro se quiere protección, considerar un disco USB externo con `rsync` periódico (fuera de Borg). |

Procedimiento de restauración (si se cae el config):

```bash
# 1) Detener Sonarr y mover el config corrupto a un lado
docker compose -f stacks/sonarr/docker-compose.yml stop sonarr
sudo mv /mnt/hd2t/apps/sonarr/config{,.broken-$(date +%F)}

# 2) Restaurar desde Borg
sudo borg extract /mnt/hd2t/backups/borg::ARCHIVO mnt/hd2t/apps/sonarr/config

# 3) Reajustar permisos por si el extract los movió
sudo chown -R homelab:homelab /mnt/hd2t/apps/sonarr/config
sudo chmod 0750 /mnt/hd2t/apps/sonarr/config

# 4) Arrancar Sonarr
docker compose -f stacks/sonarr/docker-compose.yml start sonarr
docker logs -f sonarr
# Esperar "Application started" en el log.

# 5) Verificar API key intacta
docker exec sonarr grep -oP '(?<=<ApiKey>)[^<]+' /config/config.xml
# (debe coincidir con stacks/sonarr/.env; si no coincide, actualizar
# Prowlarr Apps con la nueva)

# 6) Re-rescaneo de la biblioteca (Sonarr verifica los hardlinks existentes)
# UI: System → Tasks → "Refresh Series" → Run.
```

Frecuencia recomendada en Borgmatic: la ya documentada en `07-backups/02-borgmatic.md` (diaria). El `config/` de Sonarr es modesto (cientos de MiB tras excluir caches) y muy comprimible/deduplicable: el coste marginal en cada snapshot es bajo.

---

## Referencias

- **Documentación oficial Sonarr**: <https://wiki.servarr.com/sonarr>
- **Quick Start (Sonarr Wiki)**: <https://wiki.servarr.com/sonarr/quick-start-guide>
- **API v3 reference**: <https://sonarr.tv/docs/api/>
- **Imagen Docker LinuxServer.io**: <https://docs.linuxserver.io/images/docker-sonarr/>
- **Repositorio LSIO**: <https://github.com/linuxserver/docker-sonarr>
- **Releases (changelog antes de subir versión)**: <https://github.com/Sonarr/Sonarr/releases>
- **TRaSH guides — Sonarr quality profiles**: <https://trash-guides.info/Sonarr/Sonarr-Quality-Settings-File-Size/>
- **TRaSH guides — Sonarr naming scheme**: <https://trash-guides.info/Sonarr/Sonarr-recommended-naming-scheme/>
- **TRaSH guides — Hardlinks e Instant Moves**: <https://trash-guides.info/Hardlinks/Hardlinks-and-Instant-Moves/>
- **TVDB (fuente de metadatos)**: <https://thetvdb.com/>
- **Documentos hermanos en este repo**:
  - `01-transmission.md` (cliente BitTorrent que Sonarr usa como *download client*).
  - `02-prowlarr.md` (gestor de indexadores; Sonarr recibe sus indexadores vía Apps Sync).
  - `04-radarr.md` (gemelo de Sonarr para películas; mismo patrón).
  - `09-multimedia/01-jellyfin.md` (consumidor final de `/mnt/hd2t/media/tv`).
  - `03-red/04-caddy.md` (snippets `lan_tls`, `security_headers`, `healthcheck`, `authelia_two_factor`).
  - `04-seguridad/01-authelia.md` (regla `forward_auth` y mecanismo de bypass por path).
  - `07-backups/02-borgmatic.md` (políticas y rotación; aquí solo aporta el fragmento de fuentes/exclusiones).
  - `01-sistema/04-estructura-directorios.md` (estructura `/mnt/hd2t/media/tv` y grupo `media`).
