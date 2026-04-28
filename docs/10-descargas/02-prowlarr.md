# Prowlarr

## Descripción

Tras desplegar Transmission (`01-transmission.md`), el homelab tiene **motor de descarga** pero todavía no sabe **dónde buscar** los `.torrent` que va a entregarle a TR. Esa es la motivación de este documento.

**Prowlarr** es el *indexer manager* del stack `*arr`: un servicio que centraliza la definición y mantenimiento de **indexadores BitTorrent (y NZB, no usado aquí)** y los **sincroniza automáticamente** con Sonarr (`03-sonarr.md`) y Radarr (`04-radarr.md`). Su rol concreto en este homelab:

1. **Mantener una lista única de indexadores** (trackers públicos como `1337x`, `RARBG mirrors`, `EZTV`, `LimeTorrents`; trackers semi-públicos; y privados que el operador añada con sus credenciales). Sin Prowlarr, cada `*arr` tendría su propia lista de indexadores y, por cada cambio (URL caída, nuevo dominio espejo, nueva cookie), habría que tocar dos sitios. Con Prowlarr, **se toca un único sitio** y los demás reciben el cambio por API.
2. **Servir como gateway de búsqueda** para Sonarr y Radarr. Cuando estos quieren localizar una *release*, llaman a Prowlarr (`http://prowlarr:9696/...`); Prowlarr abanica la búsqueda a todos los indexadores configurados, agrega resultados, los normaliza al formato Newznab/Torznab y los devuelve. Sonarr/Radarr deciden cuál descargar y se lo pasan a TR.
3. **Encapsular las "definiciones de indexador"** que la comunidad mantiene. Prowlarr trae un catálogo (~500 indexadores en su última versión) con la lógica de scraping/API por tracker; el operador solo pulsa "Add" y rellena URL + credenciales si las hay. Cuando un tracker cambia su HTML o su API, basta con `docker compose pull` para que Prowlarr traiga la definición actualizada — sin tocar Sonarr/Radarr.
4. **Centralizar estadísticas** (búsquedas, fallos, latencia por indexador) y health-checks: si un indexador está caído, Prowlarr lo marca y lo notifica vía Notifications (en este homelab, opcionalmente vía Apprise → Gotify; ver "Decisión: notificaciones" más abajo).
5. **Exponer una UI web** (`https://prowlarr.${DOMAIN_LAN}/`) protegida por Authelia 2FA, donde el operador gestiona indexadores, prueba búsquedas manuales y revisa errores.

Lo que este documento **no** decide:

- **Qué indexadores usar específicamente**: la elección depende del contenido buscado (anime → Nyaa, series → EZTV/AnimeTosho, películas → 1337x, libros → Bibliotik si se tiene cuenta, etc.). En este doc se documenta **cómo añadirlos** y se recomiendan **un par de públicos** para arrancar; la lista viva del operador no se versiona en git (cambia con frecuencia y puede contener credenciales).
- **Política sobre indexadores privados (trackers cerrados con ratio)**: el homelab los soporta —Prowlarr maneja credenciales, cookies y *passkeys*— pero **no se documentan trackers concretos** porque (a) el acceso depende de invitaciones personales, (b) las URLs y nombres cambian, y (c) son datos sensibles. Las credenciales viven cifradas en `config.xml` de Prowlarr y se respaldan junto al resto del config.
- **NZB / Usenet**: igual que en `01-transmission.md`, no hay cuenta de Usenet en el homelab. Prowlarr soporta indexadores NZB (Newznab) pero solo se configurarán los Torznab (BitTorrent). Reabrible si en algún momento se contrata un proveedor.
- **FlareSolverr** (proxy para evadir Cloudflare en indexadores protegidos): se contempla como **sidecar opcional** y se documenta su receta abajo, pero no se despliega por defecto. Solo se levanta si algún indexador concreto lo exige.
- **Búsqueda directa desde la UI** como sustituto de Sonarr/Radarr: Prowlarr permite "Search" manual desde su UI y entregar el resultado a TR directamente, pero esto **rompe el patrón del catálogo**. El uso humano de la búsqueda en Prowlarr es solo para diagnóstico (¿devuelve resultados este indexador?), no operativo.
- **Apertura al exterior**: como el resto del homelab, Prowlarr es **solo LAN + tailnet**. Su UI y su API solo se acceden por Caddy con Authelia. Sonarr/Radarr le hablan **directamente al bridge `homelab`** sin pasar por Caddy.

Cuando este documento se haya aplicado, el operador puede:

- Abrir `https://prowlarr.${DOMAIN_LAN}/` desde la LAN (con la CA interna instalada, protegido por Authelia 2FA) o `https://prowlarr.${DOMAIN_TS}/` desde el tailnet, autenticarse y ver la UI de Prowlarr.
- Añadir uno o más indexadores públicos (definiciones precargadas) y verificar con *Test* que devuelven resultados.
- Tener registrada la **API key** de Prowlarr en `stacks/prowlarr/.env` (única por instalación, generada al primer arranque), lista para que Sonarr y Radarr la consuman en sus respectivos docs.
- Tener `/mnt/hd2t/apps/prowlarr/config/` respaldado por Borgmatic (`config.xml`, `prowlarr.db`, definiciones cacheadas), excluyendo logs y `MediaCover/`.
- Confirmar que el endpoint `http://prowlarr:9696/api/v1/...` está accesible **solo** desde la red Docker `homelab`, autenticado con la API key, listo para que Sonarr/Radarr llamen al `/api/v1/search` cuando se desplieguen.
- Tener establecida la **integración futura con Sonarr/Radarr** (sección *Apps* de Prowlarr, vacía por ahora; se rellena en `03-sonarr.md` y `04-radarr.md` una vez existan esos servicios).

> **Recordatorio de alcance**: el tráfico saliente que genera Prowlarr al consultar trackers públicos sí sale al exterior (HTTPS a las webs/APIs de los indexadores). Es tráfico HTTP estándar, no P2P; no requiere apertura de puertos entrantes. La política del homelab (no port-forwarding) se mantiene intacta.

---

## Requisitos Previos

- **Fase 0–1** completas: discos `hd2t` montado en `/mnt/hd2t`, usuario `homelab` (UID 1000) y grupo `homelab` (GID 1000). Prowlarr **no necesita** el grupo `media` (no toca ficheros multimedia, solo HTTP a indexadores y su propia base SQLite).
- **Fase 2** completa: Docker Engine + Compose v2; red `homelab` en `172.30.10.0/24`; convenciones `stacks/<svc>/`; `.env` global con `TZ=Europe/Madrid`, `PUID=1000`, `PGID=1000`, `DOMAIN_LAN=lan`, `DOMAIN_TS` si aplica.
- **Fase 3** completa, en particular:
  - Pi-hole con el comodín `address=/lan/192.168.1.10` (cubre `prowlarr.${DOMAIN_LAN}` automáticamente).
  - Caddy desplegado y los snippets `(lan_tls)`, `(security_headers)`, `(healthcheck)`, `(authelia_two_factor)` en `Caddyfile`.
  - Tailscale operativo y, si se quiere acceso por `prowlarr.${DOMAIN_TS}`, `tailscale cert` ya emitiendo (`03-red/05-tailscale.md`).
- **Fase 4** completa: Authelia desplegado con 2FA; Prowlarr se protege con `forward_auth`. El **endpoint `/api/v1/...`** se exonera por path para que la API key nativa de Prowlarr siga siendo el mecanismo de auth para Sonarr/Radarr (ver "Decisión: autenticación" abajo).
- **Fase 7** opcional pero recomendable: Borgmatic operativo, para añadir `/mnt/hd2t/apps/prowlarr/config` al inventario de fuentes.
- **Fase 10 paso anterior**: Transmission desplegado (`01-transmission.md`). Prowlarr **no le habla a TR directamente** (eso lo hacen Sonarr/Radarr), pero conviene tener TR sano antes de avanzar; si TR está roto, Sonarr/Radarr no podrán cerrar el ciclo y la prueba final del stack queda incompleta.

> **Sobre Sonarr/Radarr como prerequisito inverso**: Prowlarr puede vivir sin ellos. La integración bidireccional (sección *Apps* de Prowlarr) se configura **desde el lado de Sonarr/Radarr cuando estos se desplieguen**, no aquí. Este documento deja Prowlarr "listo para recibir" y nada más.

Comprobaciones rápidas:

```bash
# La red Docker compartida existe y Caddy/Authelia están sanos
docker network inspect homelab --format '{{.Name}}' | grep -q '^homelab$' && echo ok
docker ps --filter name=caddy --filter name=authelia --format '{{.Names}} {{.Status}}'

# prowlarr.lan resuelve al IP de la Pi (gracias al comodín de Pi-hole)
dig +short prowlarr.lan @192.168.1.2
# 192.168.1.10

# Conectividad saliente HTTPS a un indexador típico (sin exponer credenciales)
curl -sI -o /dev/null -w '%{http_code}\n' https://1337x.to/
# 200 (o 403 con Cloudflare, lo que indica que se llega al edge — caso de FlareSolverr)
```

---

## Decisión: gestor de indexadores — Prowlarr, no Jackett

Prowlarr es el sucesor espiritual de **Jackett** (mismo dominio funcional: traducir indexadores a Torznab/Newznab) escrito por el equipo de Sonarr.

| Gestor | Pros | Contras | Veredicto |
|---|---|---|---|
| **Prowlarr** | Sincronización **bidireccional** con Sonarr/Radarr (añadir un indexador en Prowlarr lo crea en los `*arr`; borrar lo borra). Stack `.NET` homogéneo con el resto del catálogo `*arr`. UI moderna y consistente. Estadísticas centralizadas. Mantenimiento activo (Servarr team). Reemplaza Jackett "definitivamente" según los maintainers (no hay nuevas funcionalidades en Jackett). | Una vez establecido, Sonarr/Radarr **no funcionan sin él** (si se cae, no hay búsquedas). En la práctica eso es lo deseado: punto único de configuración. | **Aceptado**. |
| Jackett | Histórico, muy maduro, comunidad enorme, definiciones aún más numerosas en algunos casos. | Sin sincronización con `*arr`: hay que copiar URL + API key en cada Sonarr/Radarr manualmente, y mantenerlo. UI antigua, mantenimiento en modo reactivo (solo bug-fixes mayores, las nuevas definiciones llegan a Prowlarr antes). | Descartado. |
| `nzbhydra2` | Multi-protocolo (NZB + Torrent). | El homelab no usa NZB; aporta complejidad sin beneficio. | Descartado. |
| Configurar indexadores manualmente en cada `*arr` | Sin servicio extra. | Inviable: cada `*arr` solo soporta un puñado de indexadores nativos (Newznab, Torznab "genérico"); las definiciones específicas de tracker (1337x, EZTV, etc.) son responsabilidad de Prowlarr/Jackett. | Descartado. |

**Decisión**: Prowlarr. Es el "siguiente paso natural" del catálogo Servarr/LSIO que ya domina la Fase 9 y la 10.

---

## Decisión: imagen — LinuxServer.io

Prowlarr tiene varias imágenes públicas relevantes:

| Imagen | Mantenedor | Tag | Pros | Contras |
|---|---|---|---|---|
| `lscr.io/linuxserver/prowlarr` | LinuxServer.io | `:1.21.2` (multi-arch arm64) | UID/GID configurables, mismo patrón que Transmission/Sonarr/Radarr/Jellyfin/Audiobookshelf/Calibre-Web/Stash, scripts s6-overlay, *automatic permissions fix* del directorio `/config` al arrancar. | Una capa entre upstream y operador. |
| `ghcr.io/hotio/prowlarr` | hotio | `:release` | Tag `release` que sigue los stable de upstream, opciones de *backup nativo* y mods. | Convenciones distintas (no usa `PUID`/`PGID` clásico, usa `UMASK_SET`, paths ligeramente distintos). Romper la homogeneidad del homelab no compensa el extra. |
| Imagen oficial `prowlarr/prowlarr` | Servarr team | varios | Construida por upstream. | Menos opinada (sin handler de permisos automático), tag `latest` apunta a `develop` por defecto en algunas variantes. Hay que vigilar más. |

**Decisión**: `lscr.io/linuxserver/prowlarr:1.21.2`.

Razones:

- **Coherencia con todo el catálogo Fase 9 + Fase 10**: misma forma (`PUID`/`PGID`/`UMASK`/`TZ`), misma idea de bind mounts, misma s6-overlay debajo.
- **Pin de versión completa** (no `latest`, no `1.21`): Prowlarr corre sobre `.NET` y las definiciones de indexadores se sincronizan con la app vía *Indexer Sync* (transparente al operador). Pin estricto evita un *salto silencioso* a una versión que rompa el formato de `prowlarr.db`. Watchtower NO actualiza automáticamente este contenedor.

Actualizaciones: `docker compose pull && up -d` tras leer el changelog de Prowlarr (cambios de schema de DB requieren a veces backup previo). La etiqueta de Watchtower deja explícito el opt-out:

```yaml
labels:
  com.centurylinklabs.watchtower.enable: "false"
```

---

## Decisión: networking — bridge `homelab`, sin `ports:` publicados

| Modo | Pros | Contras | Veredicto |
|---|---|---|---|
| **Bridge `homelab`** (sin `ports:`) | Prowlarr en `172.30.10.X`. Caddy hace `reverse_proxy http://prowlarr:9696`. API interna entre `prowlarr`, `sonarr`, `radarr` por DNS de Docker. | Ningún acceso desde el host directamente (lo que es deseado: la UI siempre va por Caddy). | **Aceptado**. |
| `network_mode: host` | Prowlarr escucha en `:9696/tcp` del host. | Innecesario (Prowlarr no necesita pila de red completa del host como sí pasa con Pi-hole o servicios mDNS), rompe el patrón del bridge, complica el `Caddyfile`. | Descartado. |
| Bridge **+** `ports: ["9696:9696"]` | Acceso directo desde la LAN al `:9696`. | Comprometería el patrón "todo por Caddy con Authelia": cualquiera de la LAN podría hablarle al `:9696` saltándose el 2FA. La API key seguiría como única defensa. | Descartado. |

Resultado: **bridge `homelab`**, sin `ports`. La UI y API se acceden únicamente vía Caddy (`https://prowlarr.${DOMAIN_LAN}/`). Sonarr/Radarr le hablan a `http://prowlarr:9696` por la red interna.

---

## Decisión: autenticación — Authelia delante de la UI, API key nativa para `*arr`

Prowlarr trae **autenticación nativa** propia (Forms con username/password almacenados en `config.xml`, hash bcrypt) y **API key** para clientes programáticos. El homelab combina ambas:

| Path | Quién accede | Estrategia |
|---|---|---|
| `/` y `/static/...`, `/login`, `/UI/...` (UI humana) | Operador desde navegador | **Authelia 2FA** (`forward_auth`). Tras superar Authelia, Caddy reenvía a `http://prowlarr:9696`. La autenticación nativa de Prowlarr se **deshabilita** poniendo `AuthenticationMethod=External` + `AuthenticationRequired=DisabledForLocalAddresses` (ver "Configuración" abajo): así Prowlarr confía en que quien le llega ya está autenticado por la capa anterior. |
| `/api/v1/...` | Sonarr y Radarr (otros contenedores en el bridge `homelab`) | **Bypass de Authelia**: Sonarr/Radarr usan la **API key** de Prowlarr (header `X-Api-Key`). Authelia no se aplica a este path. |
| `/feed/...` (RSS/Torznab feeds) | Cualquier cliente programático | **Bypass de Authelia** + API key embebida en la URL del feed. Mismo razonamiento. |
| `/ping` | Health-checks | **Bypass de Authelia** (sin auth en absoluto; el endpoint solo dice "alive"). |

En la práctica, **Sonarr y Radarr no pasan por Caddy en absoluto**: hablan directamente al bridge `homelab` con `http://prowlarr:9696/api/v1/...` y la API key. La razón de mantener los bypasses por path en el `Caddyfile` es por si algún día se quiere que un cliente externo (en el tailnet, p. ej.) llame a la API sin pasar por Authelia. Reabrible.

> **Sobre `AuthenticationRequired=DisabledForLocalAddresses`**: en Prowlarr, "Local Addresses" se interpreta como las redes RFC1918 que llamen al servicio. La red `homelab` (`172.30.10.0/24`) y `127.0.0.1` cuentan como locales. Esto permite que **Sonarr/Radarr no necesiten password de Prowlarr** (solo API key) mientras que la UI sigue exigiendo Authelia delante (porque la conexión externa entra por Caddy y se trata como remota). Si se quisiera blindar más, cambiar a `Enabled` y manejar tanto cookie de Authelia como API key — innecesario en este alcance.

> **¿Por qué no usar la auth nativa Forms?** Tres razones: (a) duplicaría credenciales (Authelia ya gestiona el login del homelab), (b) la auth nativa no es 2FA, (c) sería el único servicio del homelab autenticado fuera del SSO. La elección es coherente con cómo se trata el resto de UIs del catálogo.

---

## Decisión: dónde viven los datos y permisos

Prowlarr tiene **un único directorio de estado** (no descarga ficheros multimedia, solo HTTP):

| Tipo | Dónde | Owner:Group | Modo | Observaciones |
|---|---|---|---|---|
| **Config + DB** (`config.xml`, `prowlarr.db`, `prowlarr.db-wal`, `prowlarr.db-shm`, `Backups/`, `Definitions/`, `MediaCover/`, `logs/`) | `/mnt/hd2t/apps/prowlarr/config/` | `homelab:homelab` (`1000:1000`) | `0750` | LSIO escribe como `PUID:PGID`. Crítico para backup (DB SQLite con la lista de indexadores, credenciales cifradas, *Apps* sincronizadas). |

Bind mount elegido:

```yaml
volumes:
  - /mnt/hd2t/apps/prowlarr/config:/config
```

Razones:

- Volumen Docker nombrado para `config/` queda descartado: la DB y los backups crecen modestamente (~100–500 MiB sostenidos) y vivir en hd2t junto al resto de apps mantiene la unidad operativa.
- **No** se requiere bind mount adicional: Prowlarr no escribe en `/downloads/` ni en `/media/`. Es un servicio puramente *meta*.
- **`UMASK=022`** (el global): los ficheros de `/config/` solo los lee/escribe Prowlarr; no hay otro contenedor que necesite escribir ahí. Sonarr/Radarr usan **HTTP API**, no NFS sobre el config.

---

## Stack: `stacks/prowlarr/`

### Layout en disco

| Ruta | Soporte | Contenido |
|---|---|---|
| `stacks/prowlarr/docker-compose.yml` | microSD (git) | Stack (servicio `prowlarr` + sidecar `flaresolverr` opcional, comentado por defecto). |
| `stacks/prowlarr/.env.example` | microSD (git) | Plantilla con la API key (vacía hasta el primer arranque) que Sonarr/Radarr leerán cuando se desplieguen. |
| `stacks/caddy/conf.d/11-prowlarr.caddy` | microSD (git) | Drop-in del bloque LAN+tailnet para `prowlarr.${DOMAIN_LAN}` y `prowlarr.${DOMAIN_TS}`. |
| `/mnt/hd2t/apps/prowlarr/config/` | hd2t | `config.xml`, `prowlarr.db`, `Backups/`, `Definitions/`, `MediaCover/`, `logs/`. Owner `homelab:homelab`, modo `0750`. |

### `stacks/prowlarr/docker-compose.yml`

```yaml
# Prowlarr — gestor de indexadores BitTorrent del homelab.
# Documentado en docs/10-descargas/02-prowlarr.md.
#
# Networking: bridge homelab. Caddy hace reverse proxy hacia prowlarr:9696.
# Sonarr/Radarr (Fase 10) consumen el API directamente por el bridge.

name: prowlarr

networks:
  homelab:
    external: true

services:
  prowlarr:
    image: lscr.io/linuxserver/prowlarr:1.21.2
    container_name: prowlarr
    hostname: prowlarr
    restart: unless-stopped

    networks:
      - homelab

    # NO se publican puertos al host. La UI va por Caddy (https://prowlarr.lan)
    # y el API lo consumen Sonarr/Radarr dentro del bridge homelab.
    # ports:
    #   - "9696:9696"   # NO: comprometería el patrón de Caddy + Authelia.

    environment:
      TZ: ${TZ}
      PUID: ${PUID}              # 1000 (homelab)
      PGID: ${PGID}              # 1000 (homelab)
      UMASK: "022"               # config sólo escrito por prowlarr; no se comparte.

    volumes:
      - /mnt/hd2t/apps/prowlarr/config:/config
      - /etc/localtime:/etc/localtime:ro

    healthcheck:
      # /ping es endpoint público sin auth ni API key: 200 ⇒ alive.
      test:
        - CMD-SHELL
        - >
          curl -fsS -o /dev/null -w '%{http_code}' http://127.0.0.1:9696/ping |
          grep -E '^200$' >/dev/null
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 30s

    labels:
      homelab.role: "indexer-manager"
      homelab.backup: "true"
      # Watchtower NO actualiza automáticamente: tag completo (1.21.2).
      # Cambios de Prowlarr a veces migran schema de prowlarr.db: leer release
      # notes y hacer backup antes de subir versión.
      com.centurylinklabs.watchtower.enable: "false"

  # ----------------------------------------------------------------------
  # FlareSolverr — proxy para evadir Cloudflare en indexadores protegidos.
  # OPCIONAL: descomentar SOLO si algún indexador concreto lo exige.
  # Configuración en Prowlarr: Settings → Indexers → "FlareSolverr API URL"
  # = http://flaresolverr:8191/ (resolución por DNS del bridge).
  # ----------------------------------------------------------------------
  # flaresolverr:
  #   image: ghcr.io/flaresolverr/flaresolverr:v3.3.21
  #   container_name: flaresolverr
  #   hostname: flaresolverr
  #   restart: unless-stopped
  #   networks:
  #     - homelab
  #   environment:
  #     LOG_LEVEL: info
  #     TZ: ${TZ}
  #   healthcheck:
  #     test:
  #       - CMD-SHELL
  #       - >
  #         curl -fsS -o /dev/null -w '%{http_code}' http://127.0.0.1:8191/health |
  #         grep -E '^200$' >/dev/null
  #     interval: 60s
  #     timeout: 10s
  #     retries: 3
  #     start_period: 30s
  #   labels:
  #     homelab.role: "cf-bypass"
  #     homelab.backup: "false"
  #     com.centurylinklabs.watchtower.enable: "false"
```

> **Sobre FlareSolverr**: es un proceso headless de Chromium que ejecuta el desafío JS de Cloudflare y devuelve las cookies resueltas. Se mantiene **comentado** por dos razones: (a) consume RAM no trivial (~250–400 MiB en idle por una instancia de Chromium), (b) la mayoría de indexadores que lo requerían (`1337x`, `RARBG legacy`) o han caído o han adoptado mecanismos alternativos. Si un indexador concreto reporta error de Cloudflare en Prowlarr, descomentar el sidecar y configurar la URL en *Settings → Indexers*.

### `stacks/prowlarr/.env.example`

```bash
# stacks/prowlarr/.env.example
# Copiar a stacks/prowlarr/.env (chmod 0600) y rellenar.
#
# Las generales (TZ, PUID, PGID, DOMAIN_LAN, DOMAIN_TS) vienen del .env GLOBAL.

# API key de Prowlarr.
#
# Se genera automáticamente al primer arranque y queda en config.xml
# (clave <ApiKey>). Tras el primer up:
#   docker exec prowlarr grep -oP '(?<=<ApiKey>)[^<]+' /config/config.xml
# Copiar el valor aquí. Sonarr y Radarr leerán esta misma variable en sus .env
# cuando se desplieguen (Fase 10).
PROWLARR_API_KEY=
```

### Drop-in de Caddy: `stacks/caddy/conf.d/11-prowlarr.caddy`

```caddy
# /etc/caddy/conf.d/11-prowlarr.caddy — bloques de Prowlarr.
# Documentado en docs/10-descargas/02-prowlarr.md.
#
# UI protegida por Authelia 2FA. Endpoint /api/v1, /feed y /ping en bypass
# para permitir que clientes legítimos (Sonarr/Radarr y health-checks) sigan
# funcionando si en algún momento se accediera vía Caddy en lugar de
# directamente al bridge.

# ---- Acceso LAN -----------------------------------------------------------
prowlarr.{$DOMAIN_LAN} {
    import lan_tls
    import security_headers
    import healthcheck

    # Bypass para API y feeds: la integración con Sonarr/Radarr usa la API
    # key nativa de Prowlarr, no el flujo de Authelia.
    @api {
        path /api/v1 /api/v1/*
        path /feed/* /feed
        path /ping
    }
    handle @api {
        reverse_proxy http://prowlarr:9696
    }

    # UI humana: Authelia 2FA delante.
    handle {
        import authelia_two_factor
        reverse_proxy http://prowlarr:9696
    }
}

# ---- Acceso Tailscale -----------------------------------------------------
# Solo se materializa si DOMAIN_TS está definido (tailnet con tailscale cert).
prowlarr.{$DOMAIN_TS} {
    tls {
        get_certificate tailscale
    }
    import security_headers
    import healthcheck

    @api {
        path /api/v1 /api/v1/*
        path /feed/* /feed
        path /ping
    }
    handle @api {
        reverse_proxy http://prowlarr:9696
    }

    handle {
        import authelia_two_factor
        reverse_proxy http://prowlarr:9696
    }
}
```

### Crear directorios y desplegar

```bash
# 1) Verificar prerequisitos.
docker network inspect homelab >/dev/null 2>&1 \
    || { echo "ERROR: red Docker 'homelab' no existe (Fase 2)."; exit 1; }
docker ps --filter name=caddy --filter status=running -q | grep -q . \
    || { echo "ERROR: caddy no está corriendo (Fase 3)."; exit 1; }
docker ps --filter name=authelia --filter status=running -q | grep -q . \
    || { echo "ERROR: authelia no está corriendo (Fase 4)."; exit 1; }

# 2) Crear directorios persistentes del servicio (idempotente).
sudo install -d -o homelab -g homelab -m 0750 /mnt/hd2t/apps/prowlarr
sudo install -d -o homelab -g homelab -m 0750 /mnt/hd2t/apps/prowlarr/config

# 3) Crear .env (vacía la API key; se rellena tras el primer arranque).
cp stacks/prowlarr/.env.example stacks/prowlarr/.env
chmod 0600 stacks/prowlarr/.env

# 4) Materializar Caddy drop-in.
install -o homelab -g homelab -m 0644 \
    stacks/caddy/conf.d/11-prowlarr.caddy \
    /mnt/hd2t/apps/caddy/etc/conf.d/11-prowlarr.caddy

# 5) Levantar el stack.
docker compose \
    -f stacks/prowlarr/docker-compose.yml \
    --env-file .env --env-file stacks/prowlarr/.env \
    up -d

# 6) Recargar Caddy para que aplique el nuevo drop-in.
docker exec caddy caddy reload --config /etc/caddy/Caddyfile

# 7) Esperar healthy (Prowlarr tarda ~15 s en su primer arranque migrando DB).
docker ps --filter name=prowlarr --format '{{.Names}} {{.Status}}'
# prowlarr   Up 30s (healthy)

# 8) Extraer la API key generada y rellenarla en .env.
API_KEY="$(docker exec prowlarr grep -oP '(?<=<ApiKey>)[^<]+' /config/config.xml)"
sed -i "s|^PROWLARR_API_KEY=$|PROWLARR_API_KEY=${API_KEY}|" stacks/prowlarr/.env
echo "PROWLARR_API_KEY=${API_KEY}" >&2   # confirmación visual; no commitear el valor.
```

---

## Configuración

Tras el primer arranque, Prowlarr genera `/mnt/hd2t/apps/prowlarr/config/config.xml` y `prowlarr.db` con valores por defecto. Hay que ajustar tres cosas: **autenticación** (delegar a Authelia), **URL base** (innecesaria con subdominio dedicado) y **cadena de indexadores**.

### 1) Ajustar `config.xml` para Authelia

`config.xml` se reescribe por Prowlarr al cambiar settings desde la UI; las modificaciones manuales **se hacen con el contenedor parado**.

```bash
docker compose -f stacks/prowlarr/docker-compose.yml stop prowlarr
sudo -u homelab "$EDITOR" /mnt/hd2t/apps/prowlarr/config/config.xml
docker compose -f stacks/prowlarr/docker-compose.yml start prowlarr
```

Valores relevantes:

```xml
<Config>
  <BindAddress>*</BindAddress>
  <Port>9696</Port>
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
  <InstanceName>Prowlarr</InstanceName>
  <UpdateMechanism>Docker</UpdateMechanism>
</Config>
```

Justificación de los valores:

| Clave | Valor | Razón |
|---|---|---|
| `AuthenticationMethod` | `External` | Prowlarr asume que la auth la resuelve la capa de delante (Authelia/Caddy). No pide login propio. |
| `AuthenticationRequired` | `DisabledForLocalAddresses` | Sonarr/Radarr (en `172.30.10.0/24`, RFC1918) acceden con solo API key. Conexiones desde "fuera" (vía Caddy) se tratan como autenticadas por Authelia. |
| `EnableSsl` | `False` | TLS lo termina Caddy. Innecesario en el upstream. |
| `LaunchBrowser` | `False` | Headless. |
| `UrlBase` | vacío | Subdominio dedicado (`prowlarr.lan`), no se necesita prefijo. Si en el futuro se quisiera servir como `https://homelab.lan/prowlarr/`, poner `<UrlBase>/prowlarr</UrlBase>` y reflejarlo en Caddyfile. |
| `UpdateMechanism` | `Docker` | Indica a Prowlarr que **no** intente auto-actualizar el binario interno (lo hace el operador con `docker compose pull`). |
| `LogLevel` | `info` | Suficiente; subir a `debug` solo para investigación puntual. |
| `Branch` | `master` | Stable. La rama `develop` no se usa en homelab. |

### 2) Verificar UI

1. `https://prowlarr.${DOMAIN_LAN}/` → Authelia pide 2FA → al pasar, aparece la UI de Prowlarr (sin login propio adicional, gracias a `AuthenticationMethod=External`).
2. `Settings → General`: confirmar *Authentication: External*.
3. `Settings → General → Security`: copiar la **API Key** (es la misma que ya está en `.env`); si por algún motivo la quisieras rotar, *Reset* la regenera y hay que actualizar `.env` y todos los `*arr` que la consuman.

### 3) Añadir indexadores

Desde la UI, *Indexers → Add Indexer*:

1. Buscar por nombre o categoría (Public Trackers; Private Trackers; Semi-Private).
2. Seleccionar el deseado. Para públicos suele bastar con **URL** (Prowlarr trae varios mirrors precargados; usar el primario y dejar los espejos como fallback).
3. Para privados: pegar la **passkey** o **API key** del tracker, según pida.
4. Pulsar *Test* (Prowlarr hace una búsqueda de prueba). Si pasa, *Save*.

Recomendaciones de arranque (orientativas, ajustar al gusto y disponibilidad del tracker):

| Indexador | Tipo | Notas |
|---|---|---|
| `1337x` | Público (general) | Buena cobertura de películas y series. Cloudflare ocasional → considerar FlareSolverr si falla. |
| `EZTV` | Público (TV) | Series. Más estable que muchos. |
| `Nyaa` | Público (anime) | Solo si interesa anime. |
| `LimeTorrents` | Público (general) | Fallback genérico. |
| `The Pirate Bay` | Público (general) | Latencia variable, mantener como secundario. |

> **Hint**: añadir 3–5 indexadores diversos. Más indexadores = búsquedas más lentas (Sonarr/Radarr esperan a todos) y mayor probabilidad de duplicados. Prowlarr tiene *Sync Profile* para limitar qué se replica a cada `*arr`, pero por defecto todos van a todos.

### 4) Configurar *Apps* (vacío en este doc)

`Settings → Apps` es donde se conectan Sonarr y Radarr. **Aquí no se hace nada todavía**: ni Sonarr ni Radarr existen aún en el homelab. La sección se rellena en `03-sonarr.md` y `04-radarr.md`, donde cada `*arr` añade Prowlarr como *indexer source* y, recíprocamente, Prowlarr aprende a replicar indexadores hacia ellos.

> **Verificación post-Sonarr/Radarr**: cuando se hayan desplegado, volver a la UI de Prowlarr y confirmar en *Apps* que Sonarr/Radarr aparecen con estado *Sync Successful*. Cualquier indexador añadido aquí debería propagarse en segundos.

### 5) Notificaciones (opcional)

`Settings → Notifications` permite avisar de fallos de indexador (caído, auth expirada). Si la Fase 5 incluyó **Apprise** o **Gotify** para notificaciones del homelab, añadir aquí un *Connection* de tipo `Apprise` apuntando al endpoint interno (`http://apprise:8000/notify/...`). Diferido fuera del alcance de este doc.

### 6) Smoke test del API

Desde otro contenedor del bridge, comprobar que la API responde con la key:

```bash
docker run --rm --network homelab curlimages/curl \
  -H "X-Api-Key: $(grep ^PROWLARR_API_KEY stacks/prowlarr/.env | cut -d= -f2)" \
  http://prowlarr:9696/api/v1/system/status
# JSON con appName=Prowlarr, version=1.21.2.x, branch=master, etc.

# Búsqueda de prueba (ejemplo: "ubuntu", una distro Linux pública con torrents legales).
docker run --rm --network homelab curlimages/curl \
  -H "X-Api-Key: $(grep ^PROWLARR_API_KEY stacks/prowlarr/.env | cut -d= -f2)" \
  "http://prowlarr:9696/api/v1/search?query=ubuntu&type=search&limit=5"
# Lista de releases con title, downloadUrl, indexer, size, seeders...
```

Si esto funciona, Sonarr/Radarr (cuando se desplieguen) podrán consumir Prowlarr sin sorpresas.

---

## Almacenamiento

Volúmenes y bind mounts:

| Mount en contenedor | Bind en host | Contenido | Tamaño esperado |
|---|---|---|---|
| `/config` | `/mnt/hd2t/apps/prowlarr/config` | `config.xml`, `prowlarr.db` (+ `-wal`, `-shm`), `Backups/`, `Definitions/` (cache de YAMLs de indexadores), `MediaCover/` (iconos de tracker), `logs/`, `update_logs/` | 100–500 MiB sostenidos. `MediaCover/` y `Definitions/` son regenerables. `logs/` rota automáticamente (10 ficheros × 1 MiB por defecto). |
| `/etc/localtime` | `/etc/localtime:ro` | Zona horaria del host | KiB. Mantiene logs y horarios de retry coherentes con el reloj del operador. |

Permisos:

- `/mnt/hd2t/apps/prowlarr/config/`: `homelab:homelab` `0750`. Prowlarr escribe como UID 1000.
- **No** se requiere acceso al grupo `media`: Prowlarr no toca ficheros multimedia.

Comprobación en cualquier momento:

```bash
# Tamaño y contenido del directorio de config
sudo du -sh /mnt/hd2t/apps/prowlarr/config /mnt/hd2t/apps/prowlarr/config/*

# DB SQLite saludable
docker exec prowlarr sqlite3 /config/prowlarr.db 'PRAGMA integrity_check;'
# ok

# Backups internos de Prowlarr (rotación automática semanal)
ls -lh /mnt/hd2t/apps/prowlarr/config/Backups/scheduled/
```

> **Sobre los backups internos de Prowlarr**: la app genera backups completos del config en `Backups/scheduled/` cada semana (ZIP con `config.xml` + `prowlarr.db`). Son **complementarios** a Borgmatic, no sustitutivos: sirven para *Restore* desde la propia UI tras un cambio mal hecho (rollback rápido sin tocar Borg). Borgmatic los respaldará junto al resto de `/config/`.

---

## Backup

Política para Borgmatic (Fase 7) — fragmento a integrar en su `config.yaml`:

```yaml
# borgmatic — fragmento para Prowlarr
source_directories:
  - /mnt/hd2t/apps/prowlarr/config

exclude_patterns:
  # Cache regenerable: Prowlarr lo recrea al primer arranque tras restore.
  - /mnt/hd2t/apps/prowlarr/config/MediaCover
  - /mnt/hd2t/apps/prowlarr/config/Definitions
  # Logs no son esenciales para restaurar el servicio.
  - /mnt/hd2t/apps/prowlarr/config/logs
  - /mnt/hd2t/apps/prowlarr/config/update_logs
  # WAL y SHM de SQLite pueden estar a medio escribir; Prowlarr los regenera.
  - /mnt/hd2t/apps/prowlarr/config/prowlarr.db-wal
  - /mnt/hd2t/apps/prowlarr/config/prowlarr.db-shm
```

Qué se respalda:

| Fichero | Por qué se incluye |
|---|---|
| `config.xml` | Configuración global: API key, auth method, URL base, branch, log level. Restaurarlo basta para reanudar Prowlarr como estaba (excepto los indexadores, que viven en la DB). |
| `prowlarr.db` | **Crítico**: lista de indexadores con sus credenciales cifradas, sync con apps, *Notification connections*, historial de búsquedas. Sin esto, hay que reconstruir todo a mano. |
| `Backups/scheduled/*.zip` | Backups internos del propio Prowlarr; redundantes con Borg pero útiles para restore rápido desde la UI. Pequeños (~MiB cada uno). |

Qué **no** se respalda:

| Fichero / dir | Por qué se excluye |
|---|---|
| `MediaCover/`, `Definitions/` | Cache regenerable. Prowlarr los rebaja al arrancar (sincroniza definiciones desde sus servidores upstream y descarga iconos). 50–200 MiB que no aportan al backup. |
| `logs/`, `update_logs/` | Diagnóstico, no estado. Si se pierden, no afecta al servicio. |
| `prowlarr.db-wal`, `prowlarr.db-shm` | Estado *write-ahead log* de SQLite. Borg podría capturarlos a medio commit; SQLite los recrea consistentes desde `prowlarr.db` al abrir. **Importante**: si la DB tiene mucha actividad en el momento del backup, Borg ve un snapshot inconsistente. Mitigación: SQLite con WAL + `journal_mode=WAL` es resistente a esto, y el grueso del estado está en `prowlarr.db`. Para máxima seguridad, parar Prowlarr durante el snapshot semanal (no se hace por defecto; el riesgo práctico es bajo). |

Procedimiento de restauración (si se cae el config):

```bash
# 1) Detener Prowlarr y mover el config corrupto a un lado
docker compose -f stacks/prowlarr/docker-compose.yml stop prowlarr
sudo mv /mnt/hd2t/apps/prowlarr/config{,.broken-$(date +%F)}

# 2) Restaurar desde Borg
sudo borg extract /mnt/hd2t/backups/borg::ARCHIVO mnt/hd2t/apps/prowlarr/config

# 3) Reajustar permisos por si el extract los movió
sudo chown -R homelab:homelab /mnt/hd2t/apps/prowlarr/config
sudo chmod 0750 /mnt/hd2t/apps/prowlarr/config

# 4) Arrancar Prowlarr
docker compose -f stacks/prowlarr/docker-compose.yml start prowlarr
docker logs -f prowlarr
# Esperar "Application started" en el log.

# 5) Verificar API key intacta y resincronizar Apps si las había
docker exec prowlarr grep -oP '(?<=<ApiKey>)[^<]+' /config/config.xml
# (debe coincidir con stacks/prowlarr/.env; si no coincide, actualizar
# Sonarr/Radarr con la nueva)
```

Frecuencia recomendada en Borgmatic: la ya documentada en `07-backups/02-borgmatic.md` (diaria). El `config/` de Prowlarr es pequeño (decenas de MiB tras excluir caches) y muy comprimible/deduplicable: el coste marginal en cada snapshot es cercano a cero.

---

## Referencias

- **Documentación oficial Prowlarr**: <https://wiki.servarr.com/prowlarr>
- **Quick Start (Prowlarr Wiki)**: <https://wiki.servarr.com/prowlarr/quick-start-guide>
- **API v1 reference**: <https://prowlarr.com/docs/api/>
- **Imagen Docker LinuxServer.io**: <https://docs.linuxserver.io/images/docker-prowlarr/>
- **Repositorio LSIO**: <https://github.com/linuxserver/docker-prowlarr>
- **Releases (changelog antes de subir versión)**: <https://github.com/Prowlarr/Prowlarr/releases>
- **FlareSolverr (sidecar opcional)**: <https://github.com/FlareSolverr/FlareSolverr>
- **TRaSH guides — Prowlarr setup recomendado**: <https://trash-guides.info/Prowlarr/>
- **Documentos hermanos en este repo**:
  - `01-transmission.md` (cliente BitTorrent al que apuntarán Sonarr/Radarr; Prowlarr no le habla directamente).
  - `03-sonarr.md` (consumirá `PROWLARR_API_KEY` y se registrará en *Apps* de Prowlarr).
  - `04-radarr.md` (idem).
  - `03-red/04-caddy.md` (snippets `lan_tls`, `security_headers`, `healthcheck`, `authelia_two_factor`).
  - `04-seguridad/01-authelia.md` (regla `forward_auth` y mecanismo de bypass por path).
  - `07-backups/02-borgmatic.md` (políticas y rotación; aquí solo aporta el fragmento de fuentes/exclusiones).
