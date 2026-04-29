# Audiobookshelf

## Descripción

Con `01-jellyfin.md` y `02-navidrome.md` aplicados, el homelab ya cubre vídeo y música. Falta la tercera familia de "audio que se escucha sentado": **audiolibros y podcasts**. Ninguno de los dos servicios anteriores los gestiona bien:

- **Jellyfin** tiene un tipo "Books"/"Audiobooks", pero su modelo está diseñado para "una pista = una canción" o "un episodio = un fichero". No entiende bien capítulos, no recuerda la posición exacta entre dispositivos, no maneja libros divididos en docenas de MP3, y los clientes oficiales no tienen UI específica para audiolibros (sleep timer dependiente de capítulo, control de velocidad por libro, etc.).
- **Navidrome** **explícitamente no** es para audiolibros (decisión documentada en `02-navidrome.md`): Subsonic API trata todo como "canción", lo que destroza el seguimiento por capítulo.

**Audiobookshelf** (en adelante, ABS) es un servidor self-hosted específico para audiolibros y podcasts, escrito en Node.js, con tres ventajas frente a las alternativas:

1. **Modelo de datos correcto**: una "Item" = un audiolibro = N ficheros de audio + capítulos (parseados de tags M4B, fichero `chapters.json`, o derivados del orden de tracks). Posición de escucha sincronizada por usuario y por dispositivo.
2. **Podcasts integrados**: añadir un feed RSS, ABS descarga episodios nuevos automáticamente, recuerda los escuchados, gestiona limpieza por antigüedad.
3. **Apps móviles oficiales** maduras (Android, iOS) con caché offline, sleep timer, ajuste de velocidad, sincronización de progreso, capítulos, y autenticación por token (no se puede meter Authelia delante).

Su rol concreto en el homelab:

1. **Catalogar audiolibros** que viven en `/mnt/hd2t/media/audiobooks/` (M4B/MP3/M4A/FLAC/OGG/OPUS). Lee tags ID3/M4B/Vorbis y, opcionalmente, scrapea metadatos enriquecidos de Audible / Google Books / Open Library / iTunes.
2. **Catalogar podcasts** en `/mnt/hd2t/media/podcasts/`, descargando episodios desde feeds RSS (a diferencia de la biblioteca de audiolibros, ABS **escribe** aquí cuando descarga un episodio nuevo).
3. **Servir todo** vía:
   - **UI web propia** accesible en `https://audiobookshelf.${DOMAIN_LAN}/` y `https://audiobookshelf.${DOMAIN_TS}/`.
   - **API REST + WebSocket** propias, consumidas por las apps oficiales y por algunos clientes terceros (Plappa en iOS, ShelfPlayer).
4. **Sincronizar progreso** entre dispositivos: el segundo exacto al que llegaste con la app móvil queda guardado, y al volver a abrir el libro en otro dispositivo (o en la web) sigues por ahí.
5. **Convertir a M4B** bajo demanda (opcional, vía `ffmpeg`/`tone` integrados): unifica un libro repartido en 30 MP3s en un único M4B con capítulos. La conversión se ejecuta como tarea en background.

Lo que este documento **no** decide:

- **Si se usan apps móviles oficiales o terceros**: el operador instala una app en su móvil, pega `https://audiobookshelf.${DOMAIN_LAN}` (o el de Tailscale), usuario/contraseña, y listo. No se entra en la configuración interna de cada app.
- **Si se monta `/mnt/hd2t/media/music/`** desde ABS para "audiolibros que el rip los puso en music/": no. La biblioteca de música pertenece a Navidrome y a Jellyfin; si hay audiolibros mezclados con música, el operador los mueve a `audiobooks/` antes de indexarlos en ABS.
- **Carga automática desde un servicio externo (Mam, Audible, etc.)**: fuera de alcance. ABS toma lo que esté en `audiobooks/`. Cómo llegue ahí es asunto del operador (descarga manual, ripping de CDs, sincronización de Audible con Libation u OpenAudible — todo fuera del homelab).
- **Generación de TTS / audiolibros sintéticos**: fuera de alcance.
- **Multi-tenant complejo (perfiles infantiles)**: ABS soporta múltiples usuarios con permisos por biblioteca y "tags allowed/restricted". Se documenta la creación de usuarios y un caso simple de restricción; no se entra en flujos elaborados.
- **Authelia delante de ABS**: descartado. Las apps móviles oficiales se autentican con `Bearer <token>` contra `/api/...` y no propagan cookies; Authelia rompería ese flujo, igual que con JF y ND.

Cuando este documento se haya aplicado, el operador puede:

- Abrir `https://audiobookshelf.${DOMAIN_LAN}/` desde la LAN (con CA interna) o `https://audiobookshelf.${DOMAIN_TS}/` desde el tailnet, completar el setup inicial (crear root user), crear las bibliotecas "Audiobooks" y "Podcasts", y forzar el primer escaneo.
- Instalar la app oficial de Audiobookshelf en el móvil, apuntar al servidor, hacer login con un usuario no-admin, y reproducir un libro con sleep timer y posición sincronizada.
- Confirmar que ABS lee `/mnt/hd2t/media/audiobooks/` en `:ro` (no escribe en la biblioteca), pero que `/mnt/hd2t/media/podcasts/` está en `:rw` para que el descargador automático de feeds funcione.
- Tener `config/` y `metadata/` en `hd2t` listos para Borg en T1.

> **Recordatorio de alcance**: ABS es **solo LAN + tailnet**. La app móvil sincroniza vía Tailscale cuando el operador está fuera de casa; no se abre puerto en el router. La caché offline de la app permite escuchar libros descargados aunque el tailnet no esté disponible (avión, túnel, etc.).

---

## Requisitos Previos

- **Fase 1** completa (sistema base, hostname `pi5`, zona horaria `Europe/Madrid`, **grupo `media` con GID 1100** y `homelab` miembro de él, ver `01-sistema/04-estructura-directorios.md`).
- **Fase 2** completa (Docker Engine + Compose v2; red `homelab` en `172.30.10.0/24`; convención `stacks/<svc>/`; `.env` global con `TZ`, `PUID=1000`, `PGID=1000`, `DOMAIN_LAN`, `DOMAIN_TS` si aplica).
- **Fase 3** completa, en particular:
  - Pi-hole con `address=/lan/192.168.1.10` (cubre `audiobookshelf.${DOMAIN_LAN}` automáticamente).
  - Caddy desplegado y los snippets `(lan_tls)`, `(security_headers)`, `(healthcheck)` en `Caddyfile`.
  - Tailscale operativo y, si se quiere `audiobookshelf.${DOMAIN_TS}`, `tailscale cert` activo (`03-red/05-tailscale.md`).
- **Fase 4** completa: Authelia desplegado (aunque ABS queda en `bypass` por las razones descritas, ver "Decisión: autenticación").
- **Fase 7** opcional pero recomendable: Borgmatic operativo, para incluir `/mnt/hd2t/apps/audiobookshelf/{config,metadata}/` en T1.
- **Documentos `01-jellyfin.md` y `02-navidrome.md` aplicados**: no son bloqueantes técnicos, pero las decisiones comunes (estructura `apps/`, `:ro` sobre `media/`, política de bypass en Authelia, Caddy drop-ins por servicio, watchtower deshabilitado por servicio) ya están tomadas allí y aquí se aplican igual.
- Disco `hd2t` montado en `/mnt/hd2t` con `/mnt/hd2t/media/audiobooks/` ya creado por `01-sistema/04-estructura-directorios.md` con owner `homelab:media` y modo `2770` (setgid). Espacio: depende del catálogo del operador (un audiolibro M4B típico pesa 100–500 MiB; bibliotecas de cientos de libros caben holgadamente). `metadata/` se mantiene pequeño (<1 GiB para bibliotecas razonables).
- Operador con la **CA interna instalada** en navegador y, si va a usar la app móvil, en el dispositivo (Android/iOS).

Comprobaciones rápidas:

```bash
# La red Docker compartida y Caddy
docker network inspect homelab --format '{{.Name}}' | grep -q '^homelab$' && echo ok
docker ps --filter name=caddy --format '{{.Names}} {{.Status}}'

# DNS interno resuelve audiobookshelf.lan
dig +short audiobookshelf.lan @192.168.1.2
# 192.168.1.10

# Estructura audiobooks/ correcta
getent group media
# media:x:1100:homelab
stat -c '%a %U:%G' /mnt/hd2t/media/audiobooks
# 2770 homelab:media

# Que hay al menos un audiolibro de prueba
find /mnt/hd2t/media/audiobooks -type f \( -iname '*.m4b' -o -iname '*.mp3' -o -iname '*.m4a' \) | head -3
```

---

## Decisión: imagen — `lscr.io/linuxserver/audiobookshelf` (LSIO)

Existen dos imágenes principales para Audiobookshelf:

| Imagen | Mantenedor | Tag de referencia | Pros | Contras |
|---|---|---|---|---|
| `ghcr.io/advplyr/audiobookshelf` | Equipo upstream (`advplyr`) | `:2.17.7` (multi-arch amd64/arm64) | Imagen oficial, publicada por el creador. Cambios upstream llegan inmediatamente. | UID/GID fijos en `1000:1000` (en este homelab coinciden, pero rompe el patrón `PUID/PGID` del resto de Fase 9). No incluye `tone`/`ffmpeg` en algunas builds antiguas (resuelto en 2.17+). |
| `lscr.io/linuxserver/audiobookshelf` | LinuxServer.io | `:2.17.7` (multi-arch incluyendo arm64) | UID/GID configurables (`PUID`/`PGID`), patrón homogéneo con Jellyfin/Calibre-Web/Stash y los `*arr` de la Fase 10. Soporta `group_add` cómodamente. `ffmpeg`+`tone` empaquetados. Healthcheck script integrado. | Una capa más entre upstream y el operador (s6-overlay, scripts LSIO). Las versiones llegan con 1–3 días de desfase respecto a upstream. |

**Decisión**: `lscr.io/linuxserver/audiobookshelf:2.17.7`.

Razones:

- **Coherencia con Fase 9**: Jellyfin, Calibre-Web y Stash usan LSIO (decisión heredada de `01-jellyfin.md`). Mismas variables (`PUID`, `PGID`, `TZ`, `UMASK`), mismo modelo de timezone, mismo arranque s6 → operativa idéntica.
- **`group_add: ["1100"]`** funciona limpio: el grupo `media` se inyecta sin tocar la imagen.
- Pin a versión completa (`2.17.7`), no a `latest` ni a `2.17`. ABS sube de versión menor con frecuencia (una al mes aprox.); algunas migraciones tocan la BBDD (SQLite `absdatabase.sqlite`) y conviene aplicarlas deliberadamente.
- **`ffmpeg`+`tone` ya empaquetados**: el operador puede usar la conversión a M4B desde la UI sin instalar nada extra.

Actualizaciones: `docker compose pull && up -d` después de leer release notes en `https://github.com/advplyr/audiobookshelf/releases`. Watchtower etiqueta el contenedor con `homelab.role: "audiobook-server"` y, **dado que el tag es completo**, no hace pull automático.

> **Sobre `:latest`**: ABS está en serie 2.x y los autores publican varias releases al mes. Pin estricto evita sorpresas (en el pasado, una migración 2.4 → 2.5 reorganizó la estructura de `metadata/items/`; arrancar con `:latest` sin advertirlo dejó a varios homelabs con scans repetidos durante horas).

---

## Decisión: networking — bridge `homelab` (sin `ports:`)

Igual que Jellyfin (`01-jellyfin.md`) y Navidrome (`02-navidrome.md`):

- ABS escucha en `:80/tcp` dentro del contenedor (puerto por defecto de la imagen LSIO; cambiable con la env `PORT`, pero no se altera).
- **Sin `ports:`** publicados al host: Caddy hace `reverse_proxy http://audiobookshelf:80` resolviendo el nombre por DNS interno del bridge.
- API REST y UI web comparten puerto, así que una sola entrada de Caddy cubre todo. La app móvil consume `/api/...` y `/socket.io/...` (WebSocket) — Caddy v2 los proxypasa sin configuración extra (ABS upgrade de HTTP → WS automático).
- **Streaming de audio** (`/api/items/<id>/file/.../stream`) viaja por el mismo puerto; los clientes piden con `Range:` para seek. Caddy soporta range requests transparentemente.
- **mDNS / discovery**: ABS no implementa discovery automático; las apps piden la URL a mano. No se intenta `network_mode: host`.

---

## Decisión: dónde viven los datos y permisos

Cuatro tipos de datos:

| Tipo | Dónde | Owner:Group | Modo | Observaciones |
|---|---|---|---|---|
| **Configuración + BBDD** (`config/`): SQLite `absdatabase.sqlite` con usuarios, progreso, sesiones, ajustes; ficheros `Settings.json`, `Users.json` (legacy). | `/mnt/hd2t/apps/audiobookshelf/config/` | `homelab:homelab` (`1000:1000`) | `0750` | El "alma" de ABS. Crítico para backup. Pérdida = re-escaneo + pérdida de progreso de escucha. |
| **Metadatos descargados** (`metadata/`): portadas, fichas de Audible/Google Books, transcoding cache, autoría/serie cacheadas, sesiones de podcast. | `/mnt/hd2t/apps/audiobookshelf/metadata/` | `homelab:homelab` | `0750` | Regenerable parcialmente (re-scrapeable), pero contiene también ficheros de capítulos extraídos manualmente y resultados de "Match" del operador. **Sí se respalda** (T2). |
| **Biblioteca de audiolibros** (`/audiobooks/...`): los ficheros reales (M4B/MP3/M4A/FLAC). | `/mnt/hd2t/media/audiobooks/` | `homelab:media` (`1000:1100`) | `2770` (setgid) | ABS lo monta **read-only** (`:ro`): no escribe nunca. La opción "Store metadata with library" queda **desactivada**, así toda la metadata sidecar va a `metadata/`. |
| **Biblioteca de podcasts** (`/podcasts/...`): episodios descargados por ABS desde feeds RSS. | `/mnt/hd2t/media/podcasts/` | `homelab:media` (`1000:1100`) | `2770` (setgid) | ABS lo monta **read-write** (`:rw`): es el único directorio de `media/` donde un servicio escribe contenido nuevo. La descarga se hace como `homelab:media` con UMASK 002 → ficheros legibles por todo el grupo `media`. |

| Opción | Pros | Contras | Veredicto |
|---|---|---|---|
| Volumen Docker nombrado para `config/` y `metadata/` | Menos pelea con permisos. | Datos en `/var/lib/docker/volumes/...` (microSD). `metadata/` puede crecer 1–5 GiB; rompe la convención del homelab. | Descartado. |
| Bind mount con `PUID=0` | Ninguna ventaja real. | LSIO desaconseja explícitamente correr como root. | Descartado. |
| **Bind mount `homelab:homelab` con `PUID=1000`, `PGID=1000`, `group_add: [1100]`** | UI legible, ACLs simples, biblioteca accesible de lectura sin convertir a ABS en propietario, podcasts escribibles vía `media`. | Ninguno relevante. | **Aceptado**. |

Resultado: bind mounts a `/mnt/hd2t/apps/audiobookshelf/{config,metadata}` con `PUID=1000:PGID=1000`, `group_add: [1100]` para acceso al árbol `media/`. Audiolibros `:ro`, podcasts `:rw`.

> **Por qué `:ro` en `/audiobooks` pero `:rw` en `/podcasts`**: ABS no necesita escribir en la biblioteca de audiolibros (todo el sidecar va a `metadata/` si "Store metadata with library" está desactivado). Pero **sí** necesita escribir en podcasts porque el descargador automático crea `<podcast>/<episodio>.mp3` cuando aparece un nuevo episodio. Mantener `:ro` donde se puede es defensa en profundidad.

> **Por qué `metadata/` separado de `config/`**: ABS los separa en su modelo (es la nomenclatura oficial). Tenerlos en bind mounts distintos permite políticas de backup distintas (config T1, metadata T2) y limpiar `metadata/` por separado si crece sin control sin tocar la BBDD.

> **Sobre "Store metadata with library"**: si se activa, ABS escribe `metadata.json`, `cover.jpg`, `chapters.json` dentro de cada carpeta del libro en `/audiobooks/<libro>/`. Eso obligaría a montar `/audiobooks` en `:rw`, perdiendo defensa en profundidad. **Decisión: desactivado** (configurar en la UI durante el setup). Solo activarlo si se quiere portabilidad entre servidores ABS.

---

## Decisión: autenticación — ABS nativa, **no** Authelia

ABS tiene autenticación nativa (usuarios locales con bcrypt) y emite **tokens JWT** que las apps móviles guardan y envían como `Authorization: Bearer <token>` en cada petición. Meterlo detrás del `forward_auth` de Authelia es contraindicado por razones gemelas a JF/ND:

| Razón | Impacto |
|---|---|
| **API REST con Bearer tokens** (`/api/...`) | Las apps móviles **no mantienen cookies**. Authelia, cookie-based, las ve "no autenticadas" y redirige al portal. **Resultado**: ninguna app móvil funciona. |
| **Streaming de audio** (`/api/items/<id>/file/.../stream`) | Las URLs llevan token en query string o cabecera `Authorization`, no cookie. |
| **WebSocket de progreso en tiempo real** (`/socket.io/...`) | Authelia forward_auth interfiere con el upgrade HTTP→WS y con el primer mensaje de auth de socket.io. |
| **App móvil: caché offline + reconexión** | Tras semanas offline, la app reintenta con su token cacheado; Authelia lo descarta y la app no sabe re-loguear sin intervención del usuario. |
| **OPDS** (catálogo navegable por apps externas tipo PocketBook) | Aunque no es el caso primario, ABS expone OPDS para clientes terceros con auth básica nativa; Authelia rompe. |

La política sana: **ABS gestiona su propia autenticación**. Compensaciones:

- ABS **no** sale de la LAN/tailnet. Quien quiera atacar el endpoint API necesita ya estar dentro.
- ABS aplica **rate limiting nativo** sobre `/login` (configurable; por defecto 5 intentos / 5 min), pero no es robusto. **`fail2ban` (Fase 4) puede añadir un jail para `Audiobookshelf`** parseando `config/logs/`. Reabrible.
- **Contraseñas fuertes obligatorias**: ABS no fuerza política de complejidad; el operador es responsable. Mínimo 16 caracteres por usuario, gestionado en gestor de contraseñas.
- **Cuenta root separada** del uso diario.
- **Tokens revocables**: si un dispositivo se pierde, en `Settings → Authentication → Active Sessions` se invalida la sesión específica sin tocar la contraseña.

Reflejo en Caddy: `Caddyfile` para ABS importa **solo** `lan_tls`, `security_headers`, `healthcheck`; **no** `authelia_two_factor`. En Authelia, `audiobookshelf.${DOMAIN_LAN}` queda en `bypass`:

```yaml
# stacks/authelia/conf.d/09-audiobookshelf-bypass.yml
- domain: "audiobookshelf.{$DOMAIN_LAN}"
  policy: bypass
- domain: "audiobookshelf.{$DOMAIN_TS}"
  policy: bypass
```

> **Si un día se quiere SSO**: ABS desde 2.7 tiene soporte experimental para OIDC (`Settings → Authentication → OpenID Connect`). Permite delegar el login en Authelia OIDC para la UI web; la app móvil tiene un flujo OIDC mediante deep link. Reabrible cuando Authelia OIDC esté maduro en este homelab y se quiera unificar SSO.

---

## Stack: `stacks/audiobookshelf/`

### Layout en disco

| Ruta | Soporte | Contenido |
|---|---|---|
| `stacks/audiobookshelf/docker-compose.yml` | microSD (git) | Stack (servicio `audiobookshelf`). |
| `stacks/audiobookshelf/.env.example` | microSD (git) | Plantilla con variables específicas (vacía por defecto; ABS no necesita secretos en env). |
| `stacks/caddy/conf.d/09-audiobookshelf.caddy` | microSD (git) | Drop-in del bloque LAN+tailnet para `audiobookshelf.${DOMAIN_LAN}` y `audiobookshelf.${DOMAIN_TS}`. |
| `stacks/authelia/conf.d/09-audiobookshelf-bypass.yml` | microSD (git) | Fragmento de access_control para añadir bypass de `audiobookshelf.*`. |
| `/mnt/hd2t/apps/audiobookshelf/config/` | hd2t | BBDD SQLite, Settings, sesiones. Owner `homelab:homelab`, modo `0750`. |
| `/mnt/hd2t/apps/audiobookshelf/metadata/` | hd2t | Portadas cacheadas, scrapes, transcoding cache. Owner `homelab:homelab`, modo `0750`. |
| `/mnt/hd2t/media/audiobooks/` | hd2t | **Read-only** desde ABS. Owner `homelab:media`, modo `2770`. |
| `/mnt/hd2t/media/podcasts/` | hd2t | **Read-write** desde ABS. Owner `homelab:media`, modo `2770`. |

### `stacks/audiobookshelf/docker-compose.yml`

```yaml
# Audiobookshelf — servidor de audiolibros y podcasts del homelab.
# Documentado en docs/09-multimedia/03-audiobookshelf.md.
#
# Networking: bridge homelab. Caddy hace reverse proxy hacia audiobookshelf:80.
# La biblioteca /mnt/hd2t/media/audiobooks/ se monta read-only.
# La biblioteca /mnt/hd2t/media/podcasts/ se monta read-write (descarga RSS).

name: audiobookshelf

networks:
  homelab:
    external: true

services:
  audiobookshelf:
    image: lscr.io/linuxserver/audiobookshelf:2.17.7
    container_name: audiobookshelf
    hostname: audiobookshelf
    restart: unless-stopped

    networks:
      - homelab

    # NO se publican puertos al host: el acceso humano va por Caddy
    # (https://audiobookshelf.lan). La API y los WebSockets comparten puerto.

    # El grupo media (1100) habilita lectura de /audiobooks y escritura
    # controlada de /podcasts; PUID/PGID los inyecta LSIO desde el .env global.
    group_add:
      - "1100"   # media (creado en 01-sistema/04-estructura-directorios.md)

    environment:
      TZ: ${TZ}
      PUID: ${PUID:-1000}
      PGID: ${PGID:-1000}
      UMASK: "002"          # ficheros nuevos (podcasts descargados) legibles por grupo media
      # PORT: "80"           # default LSIO; no se altera

    volumes:
      - /mnt/hd2t/apps/audiobookshelf/config:/config
      - /mnt/hd2t/apps/audiobookshelf/metadata:/metadata
      # Audiolibros: read-only (defensa en profundidad).
      - /mnt/hd2t/media/audiobooks:/audiobooks:ro
      # Podcasts: read-write (descargador RSS escribe nuevos episodios).
      - /mnt/hd2t/media/podcasts:/podcasts
      - /etc/localtime:/etc/localtime:ro

    healthcheck:
      # ABS expone /healthcheck devolviendo 200 cuando la app y la BBDD están vivas.
      test: ["CMD", "curl", "-fsSL", "http://127.0.0.1/healthcheck"]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 90s

    labels:
      homelab.role: "audiobook-server"
      homelab.backup: "true"
      # Watchtower NO actualiza automáticamente: el tag es completo y los
      # bumps de minor de ABS a veces requieren atención (migraciones SQLite).
      com.centurylinklabs.watchtower.enable: "false"
```

> **Sobre `UMASK: "002"`**: el descargador de podcasts crea ficheros nuevos en `/podcasts/`. UMASK 002 garantiza modo `0664` (rw-rw-r--), legible por todo el grupo `media`, así otros servicios (Jellyfin si un día indexara podcasts, scripts del operador) no encuentran ficheros con permisos `0644` que el grupo no puede tocar.

> **Sobre el healthcheck**: la imagen LSIO de Audiobookshelf incluye `curl`. ABS expone `/healthcheck` que devuelve 200 cuando el HTTP server está vivo y la BBDD se ha abierto correctamente. Si en algún momento upstream cambia, alternativa: `wget -qO- http://127.0.0.1/api/ping` (siempre 200 si ABS responde, requiere que `wget` esté en la imagen).

> **Sobre `start_period: 90s`**: en una Pi 5 con SQLite en disco USB, el primer arranque tras una migración de minor puede tardar 30–60 s aplicando esquema; 90 s da margen sin marcar `unhealthy` espurio.

### `stacks/audiobookshelf/.env.example`

```bash
# stacks/audiobookshelf/.env.example
# Audiobookshelf no requiere variables propias por defecto. Las generales
# (TZ, PUID, PGID, DOMAIN_LAN, DOMAIN_TS) vienen del .env GLOBAL del homelab.
#
# Si en el futuro se activan integraciones (OIDC con Authelia, métricas
# prometheus, etc.), añadir aquí. Nada por ahora.
```

### Drop-in de Caddy: `stacks/caddy/conf.d/09-audiobookshelf.caddy`

```caddy
# /etc/caddy/conf.d/09-audiobookshelf.caddy — bloques de Audiobookshelf.
# Documentado en docs/09-multimedia/03-audiobookshelf.md.
#
# IMPORTANTE: NO se importa authelia_two_factor (decisión documentada en
# "Decisión: autenticación"). ABS gestiona su propio login y la API móvil
# usa Bearer tokens propios.

# ---- Acceso LAN ------------------------------------------------------------
audiobookshelf.{$DOMAIN_LAN} {
    import lan_tls
    import security_headers
    import healthcheck

    reverse_proxy http://audiobookshelf:80 {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}

        # Streams largos (un audiolibro completo en una sesión HTTP/2):
        # subir read/write timeouts. La app móvil mantiene el WebSocket
        # de progreso abierto durante toda la escucha.
        transport http {
            read_timeout 8h
            write_timeout 8h
            read_buffer 64KB
        }
    }

    # Subir el límite de body para uploads desde la UI (subida manual
    # de portada custom o ficheros sueltos vía "Upload"); por defecto Caddy
    # no fija límite, pero ABS sí tiene chequeos internos.
    request_body {
        max_size 100MB
    }
}

# ---- Acceso Tailscale ------------------------------------------------------
# Solo se materializa si DOMAIN_TS está definido (tailnet con tailscale cert).
audiobookshelf.{$DOMAIN_TS} {
    tls {
        get_certificate tailscale
    }
    import security_headers
    import healthcheck

    reverse_proxy http://audiobookshelf:80 {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}

        transport http {
            read_timeout 8h
            write_timeout 8h
            read_buffer 64KB
        }
    }

    request_body {
        max_size 100MB
    }
}
```

> **Sobre `read_timeout 8h`**: un audiolibro entero puede durar 20–30 horas, pero la app móvil **no** mantiene una única conexión HTTP; pide rangos a medida que los reproduce y reabre tras pausa larga. 8 h es holgado para "una sesión de escucha continuada" y suficientemente bajo para no acumular sockets zombi.

> **Sobre WebSocket**: ABS usa socket.io (basado en WebSocket) para sincronizar progreso y notificar de nuevos episodios de podcast. Caddy v2 hace upgrade automático cuando el cliente envía `Upgrade: websocket`; no se necesita configuración adicional (a diferencia de Caddy v1).

### Fragmento de Authelia: `stacks/authelia/conf.d/09-audiobookshelf-bypass.yml`

```yaml
# stacks/authelia/conf.d/09-audiobookshelf-bypass.yml
# Excluir Audiobookshelf del control de acceso de Authelia.
# Se incluye desde stacks/authelia/configuration.yml mediante el mecanismo
# de merge documentado en 04-seguridad/01-authelia.md.

- domain: "audiobookshelf.{$DOMAIN_LAN}"
  policy: bypass
- domain: "audiobookshelf.{$DOMAIN_TS}"
  policy: bypass
```

### Crear directorios y desplegar

```bash
# Cargar variables globales en el shell (ver quirk Compose v2 en 02-estructura-compose.md)
cd /home/homelab/homelab
set -a; source .env; set +a

# 1) Verificar prerequisitos de estructura (Fase 1).
getent group media | grep -q '^media:x:1100:' || {
    echo "ERROR: grupo media (GID 1100) no existe. Aplicar 01-sistema/04-estructura-directorios.md."
    exit 1
}
[ -d /mnt/hd2t/media/audiobooks ] || {
    echo "ERROR: /mnt/hd2t/media/audiobooks no existe. Aplicar 01-sistema/04-estructura-directorios.md."
    exit 1
}

# 2) Crear directorio de podcasts si no existe (la Fase 1 define audiobooks/
#    pero podcasts/ se materializa aquí, primer servicio que lo usa).
sudo install -d -o homelab -g media -m 2770 /mnt/hd2t/media/podcasts

# 3) Crear directorios persistentes del servicio (idempotente).
sudo install -d -o homelab -g homelab -m 0750 /mnt/hd2t/apps/audiobookshelf
sudo install -d -o homelab -g homelab -m 0750 /mnt/hd2t/apps/audiobookshelf/config
sudo install -d -o homelab -g homelab -m 0750 /mnt/hd2t/apps/audiobookshelf/metadata

# 4) Materializar Caddy drop-in y fragmento de Authelia.
install -o homelab -g homelab -m 0644 \
    stacks/caddy/conf.d/09-audiobookshelf.caddy \
    /mnt/hd2t/apps/caddy/etc/conf.d/09-audiobookshelf.caddy

install -o homelab -g homelab -m 0644 \
    stacks/authelia/conf.d/09-audiobookshelf-bypass.yml \
    /mnt/hd2t/apps/authelia/etc/conf.d/09-audiobookshelf-bypass.yml

# 5) .env del stack: copiar la plantilla (vacía) por consistencia.
cp stacks/audiobookshelf/.env.example stacks/audiobookshelf/.env
chmod 0600 stacks/audiobookshelf/.env

# 6) Levantar el stack.
docker compose \
    -f stacks/audiobookshelf/docker-compose.yml \
    --env-file stacks/audiobookshelf/.env \
    up -d

# 7) Recargar Caddy y Authelia para tomar drop-ins.
docker exec caddy caddy validate --config /etc/caddy/Caddyfile && \
    docker kill --signal=SIGUSR1 caddy
docker exec authelia kill -HUP 1 || \
    docker compose -f stacks/authelia/docker-compose.yml restart authelia
```

Tras `up -d`:

```bash
docker ps --filter name=audiobookshelf
# CONTAINER ID  IMAGE                                          STATUS
# ...           lscr.io/linuxserver/audiobookshelf:2.17.7      Up 1 minute (healthy)

docker logs audiobookshelf --tail 30
# ... [INFO] Server running on port 80
# ... [INFO] Database opened: /config/absdatabase.sqlite
# ... [INFO] Listening on port 80

# Confirmar puertos NO publicados al host
ss -tlnp | grep ':80 ' | grep -v 'caddy' || echo "OK: audiobookshelf NO publica al host"

# Probar el endpoint vía Caddy
curl -ksI https://audiobookshelf.lan/healthcheck
# HTTP/2 200
```

---

## Configuración

### 1) Setup inicial

Desde un cliente de la LAN con la CA interna instalada:

```text
1. Abrir https://audiobookshelf.lan/
2. ABS muestra "Initial Setup":
   - Username: root
   - Password: gestor de contraseñas; mínimo 16 caracteres
3. Submit. Redirige al login → introducir root / <password>.
4. Aparece la UI con "No libraries". Esto es normal: aún no se ha
   creado ninguna biblioteca.
```

> **Si el formulario no aparece**: ya hay configuración previa (`/mnt/hd2t/apps/audiobookshelf/config/absdatabase.sqlite` existe). Si no es la deseada, parar el contenedor, **borrar el contenido de `config/` y `metadata/`** (perderás usuarios y progreso) y volver a levantar.

### 2) Crear las bibliotecas

`Settings (engranaje) → Libraries → Add Library`.

#### Biblioteca "Audiobooks"

```text
- Name: Audiobooks
- Icon: book-1 (o el que se prefiera)
- Folder: /audiobooks                # bind mount read-only
- Media Type: Book
- Disable Watcher: NO                # detección rápida de adiciones
- Skip Matching Tracks With Tag: (vacío)
- Provider: Audible.es / iTunes / Open Library (escoger el que mejor
            cubra el catálogo en español)
- Prefer Overdrive Media Markers: ON (si los libros vienen de OverDrive)
- Settings → Library:
  - "Store metadata with library"  → DESACTIVADO (no escribir en /audiobooks)
  - "Store cover with library"     → DESACTIVADO
  - "Use square book covers"       → según gusto
```

#### Biblioteca "Podcasts"

```text
- Name: Podcasts
- Icon: podcast
- Folder: /podcasts                  # bind mount read-write
- Media Type: Podcast
- Disable Watcher: NO
- Settings → Library:
  - "Store metadata with library"  → ACTIVADO (en podcasts es razonable:
                                     ABS escribe metadata.json junto al
                                     OPML, y el bind mount es :rw)
```

> **Por qué la diferencia**: en audiobooks el bind mount es `:ro` y obligar a "metadata with library" rompería; en podcasts ABS ya escribe los `.mp3` ahí, así que añadir `metadata.json` por podcast es coherente y portable.

### 3) Forzar el primer escaneo

Con las bibliotecas creadas:

```text
Libraries → <Library> → "..." → Force Re-Scan
```

O por API:

```bash
# Listar bibliotecas (auth Bearer; el token está en Settings → Users → API Token)
curl -ks -H "Authorization: Bearer $ABS_TOKEN" \
     "https://audiobookshelf.lan/api/libraries" | jq '.libraries[].id'

# Disparar escaneo
curl -ks -X POST -H "Authorization: Bearer $ABS_TOKEN" \
     "https://audiobookshelf.lan/api/libraries/<id>/scan"
```

El primer escaneo de una biblioteca de unos cientos de audiolibros tarda **2–10 minutos** en una Pi 5 con `hd2t` USB 3.0; depende de cuántos M4B requieran extracción de capítulos y de cuánto tarde el provider externo en responder al match.

### 4) Crear los usuarios del hogar

`Settings → Users → Create User`:

```text
- Username: <nombre del miembro>
- Password: gestor de contraseñas
- Type: User    (no admin; la cuenta root ya cubre admin)
- Permissions:
  - Can download: SÍ (necesario para caché offline en la app móvil)
  - Can update: NO (no editar metadatos ni capítulos)
  - Can delete: NO
  - Can upload: NO
- Library Access:
  - Audiobooks: SÍ
  - Podcasts:   SÍ (o solo uno si se quiere segmentar)
- Item Tags Allowed/Restricted: (opcional, para ocultar libros con tag "explicit"
  a un perfil infantil)
```

> **Sobre la cuenta root**: usar `root` solo para administración. Para escuchar día a día, crear un usuario propio sin permisos de admin. El progreso de escucha se guarda **por usuario**: si dos miembros del hogar usan la misma cuenta, comparten posición y "última escucha", lo que es indeseable.

### 5) Configurar la app móvil

#### Android: app oficial Audiobookshelf

```text
Repo: F-Droid / Play Store ("Audiobookshelf")
Package: com.audiobookshelf.app
```

Configuración:

```text
1. Abrir la app → "Add Server"
2. URL: https://audiobookshelf.lan
        (o https://audiobookshelf.<ts-tailnet>.ts.net si fuera de casa)
3. Username: <usuario no-admin>
4. Password: <password>
5. Login → la app guarda el token; aparece la biblioteca.
```

> **CA interna en Android**: la app oficial confía en certificados instalados como "user CA" desde Android 7+ (su `network_security_config` lo permite explícitamente). Si la app no acepta el cert, alternativas: (a) usar Tailscale, que trae cert legítimo en `audiobookshelf.<ts-tailnet>.ts.net`; (b) marcar "Allow self-signed" en Settings → Connection (solo aceptable en LAN).

#### iOS: app oficial Audiobookshelf, o Plappa, o ShelfPlayer

| Cliente | Tienda | Comentario |
|---|---|---|
| **Audiobookshelf** | App Store (gratis) | Oficial. Calidad mejorada en 2024. |
| **Plappa** | App Store (de pago) | Tercero, UI muy pulida, escenas y atajos Siri. |
| **ShelfPlayer** | App Store (gratis, código abierto) | Tercero, alternativa nativa SwiftUI. |

Configuración análoga (URL del servidor + credenciales).

#### Escritorio: navegador

ABS no tiene cliente de escritorio dedicado. La UI web cubre el caso (audio HTML5 nativo, atajos de teclado, sleep timer). En navegadores Chromium, **PWA-install** (`Instalar Audiobookshelf` en el menú) deja un icono de "app de escritorio" sin Electron.

### 6) Añadir podcasts

```text
Libraries → Podcasts → "+" (nuevo) → "Add Podcast"
1. URL del feed RSS: https://feeds.example.com/some-podcast.xml
2. ABS pre-escanea el feed: muestra portada, descripción, episodios disponibles.
3. Configurar:
   - Auto Download Episodes:    SÍ
   - Max Episodes To Keep:      10  (o "0" para no limitar)
   - Auto Download Schedule:    @every 6h  (cron)
4. Submit → ABS crea /podcasts/<podcast-name>/ y descarga episodios.
```

> **Aviso sobre tamaño**: los podcasts no son enormes pero suman: 50 podcasts × 10 episodios × 50 MiB = 25 GiB. Configurar `Max Episodes To Keep` para todos los podcasts evita que `/mnt/hd2t/media/podcasts/` crezca indefinidamente. ABS borra los episodios más antiguos automáticamente cuando se supera el límite.

### 7) Operación diaria

| Acción | Comando |
|---|---|
| Ver el log activo | `docker logs audiobookshelf -f` |
| Reescaneo manual | UI: Library → "..." → "Force Re-Scan", o `POST /api/libraries/<id>/scan` |
| Reiniciar ABS | `docker compose -f stacks/audiobookshelf/docker-compose.yml restart audiobookshelf` |
| Backup manual del config | `sudo tar czf /mnt/hd2t/backups/abs-snapshot-$(date +%F).tgz -C /mnt/hd2t/apps/audiobookshelf config` |
| Tamaño actual de la BBDD | `du -sh /mnt/hd2t/apps/audiobookshelf/config/absdatabase.sqlite` |
| Limpiar metadata cache | `docker exec audiobookshelf rm -rf /metadata/cache` (con ABS parado o no, ABS regenera bajo demanda) |
| Listar usuarios | UI: Settings → Users; o `GET /api/users` con token Bearer |
| Forzar descarga de podcasts | UI: Podcast → "..." → "Check & Download Episodes" |
| Convertir un libro a M4B | UI: Item → "..." → "Convert to M4B" (background job, requiere `tone`+`ffmpeg` empaquetados — ya lo están) |
| Exportar progreso de escucha | UI: Settings → Item → "Save backup" (incluye historial); o backup de la BBDD entera |

---

## Almacenamiento

| Ruta | Soporte | Owner:Group | Modo | Contenido |
|---|---|---|---|---|
| `/home/homelab/homelab/stacks/audiobookshelf/docker-compose.yml` | microSD | `homelab:homelab` | `0640` | Stack versionado en git. |
| `/home/homelab/homelab/stacks/audiobookshelf/.env.example` | microSD | `homelab:homelab` | `0644` | Plantilla. |
| `/home/homelab/homelab/stacks/audiobookshelf/.env` | microSD | `homelab:homelab` | `0600` | Vacío en este servicio (consistencia con resto de stacks). |
| `/home/homelab/homelab/stacks/caddy/conf.d/09-audiobookshelf.caddy` | microSD | `homelab:homelab` | `0644` | Drop-in de Caddy. |
| `/home/homelab/homelab/stacks/authelia/conf.d/09-audiobookshelf-bypass.yml` | microSD | `homelab:homelab` | `0644` | Fragmento de bypass. |
| `/mnt/hd2t/apps/audiobookshelf/config/` | hd2t | `homelab:homelab` | `0750` | Datos del servicio. **Crítico**, se respalda. |
| `/mnt/hd2t/apps/audiobookshelf/config/absdatabase.sqlite` | hd2t | `homelab:homelab` | `0640` | BBDD principal (usuarios, progreso, sesiones, ajustes, podcasts subscriptions). |
| `/mnt/hd2t/apps/audiobookshelf/metadata/` | hd2t | `homelab:homelab` | `0750` | Portadas, scrapes, capítulos extraídos. **Se respalda en T2** (regenerable parcialmente, pero costoso). |
| `/mnt/hd2t/apps/audiobookshelf/metadata/cache/` | hd2t | `homelab:homelab` | `0750` | Caché de portadas escaladas. **No se respalda** (regenerable rápido). |
| `/mnt/hd2t/media/audiobooks/` | hd2t | `homelab:media` | `2770` | **No se respalda** desde ABS (compartido, política heredada de `01-jellyfin.md`). Bind mount `:ro`. |
| `/mnt/hd2t/media/podcasts/` | hd2t | `homelab:media` | `2770` | **No se respalda**: regenerable desde feeds RSS. Bind mount `:rw`. |

> **Tamaño esperado**. Para una biblioteca de ~500 audiolibros, `config/absdatabase.sqlite` se estabiliza en torno a **20–80 MiB**. `metadata/` (portadas + scrapes) puede crecer hasta 1–3 GiB según resoluciones de portada. `metadata/cache/` añade unos cientos de MiB. Reservar **5 GiB** para `apps/audiobookshelf/` es holgado.

> **Tamaño de podcasts**. Crece según política. Para 30 podcasts con `Max Episodes = 10` y duración media de 1 h con bitrate 96 kbps: ~12 GiB. Configurar `Max Episodes` con cabeza.

> **Por qué no microSD**. Como en JF y ND: SQLite + escrituras frecuentes (cada segundo de progreso de escucha sincronizado, cada chequeo de feed) en microSD = cuenta atrás para corrupción.

---

## Backup

A nivel de repositorio (git):

| Artefacto | Estrategia |
|---|---|
| `stacks/audiobookshelf/docker-compose.yml`, `.env.example` | Versionados. |
| `stacks/audiobookshelf/.env` | **NO** versionado (consistencia; aunque hoy esté vacío). En `.gitignore`. |
| `stacks/caddy/conf.d/09-audiobookshelf.caddy` | Versionado. |
| `stacks/authelia/conf.d/09-audiobookshelf-bypass.yml` | Versionado. |
| Decisiones (LSIO, bridge, sin Authelia, biblioteca `:ro`, podcasts `:rw`) | Documentadas en este fichero. |

A nivel de datos (Borgmatic, Fase 7):

| Ruta | ¿Se respalda? | Tier (`07-backups/01-estrategia-backup.md`) | Por qué |
|---|---|---|---|
| `/mnt/hd2t/apps/audiobookshelf/config/absdatabase.sqlite` | Sí. | T1 | Usuarios, contraseñas hashed (bcrypt), progreso de escucha por usuario y por libro, sesiones, suscripciones a podcasts. **Pérdida = re-escaneo + re-creación manual de usuarios + pérdida de progreso**. |
| `/mnt/hd2t/apps/audiobookshelf/config/` (resto) | Sí. | T1 | Settings.json, ficheros de configuración auxiliares. |
| `/mnt/hd2t/apps/audiobookshelf/metadata/` (excluyendo `cache/`) | Sí. | T2 | Portadas custom, scrapes confirmados por el operador (matches manuales), capítulos extraídos. Re-scrapeable pero costoso (cuotas de provider, intervención manual). |
| `/mnt/hd2t/apps/audiobookshelf/metadata/cache/` | **No.** | T4 | Caché de portadas escaladas; ABS regenera bajo demanda. |
| `/mnt/hd2t/media/audiobooks/` | **No.** | T5 | **Política del homelab**: la biblioteca es voluminosa y reconstituible desde la fuente externa (rips propios, compras digitales). No se respalda. |
| `/mnt/hd2t/media/podcasts/` | **No.** | T5 | Regenerable desde los feeds RSS (mientras estén vivos). El conjunto de feeds suscritos sí se respalda (vive en la BBDD). |

Entrada en `borgmatic.yaml` (parche relativo al patrón de `07-backups/02-borgmatic.md`):

```yaml
source_directories:
  # ...
  - /mnt/hd2t/apps/audiobookshelf/config
  - /mnt/hd2t/apps/audiobookshelf/metadata

# Excluir lo regenerable.
patterns:
  # ...
  - '!/mnt/hd2t/apps/audiobookshelf/metadata/cache'

# Hooks: snapshot consistente de SQLite antes del backup.
before_backup:
  - 'docker exec audiobookshelf sqlite3 /config/absdatabase.sqlite ".backup ''/config/absdatabase.sqlite.borg''"'
after_backup:
  - 'docker exec audiobookshelf rm -f /config/absdatabase.sqlite.borg'
```

> **Política sobre la BBDD**. Snapshot consistente con `.backup` de SQLite (atómico). Para una BBDD de ~50 MiB, el snapshot tarda <1 s y es seguro hacerlo con ABS corriendo (a diferencia de `cp`, que puede capturar un fichero a medio escribir).

> **Política sobre `/mnt/hd2t/media/podcasts/`**. Excluida del backup. Los feeds RSS quedan en la BBDD (`config/absdatabase.sqlite`); tras restore, ABS recrea cada subscripción y vuelve a descargar episodios según `Max Episodes To Keep`. Se pierde el histórico de "qué episodios escuché y al minuto exacto" salvo en lo que la BBDD ya guarda como progreso.

> **Política sobre `/mnt/hd2t/media/audiobooks/`**. Excluida del backup, igual que el resto de `media/`. Si la biblioteca contiene grabaciones únicas (audiolibros sintetizados localmente, charlas familiares grabadas que se han metadado como audiolibros), separarlas a `/mnt/hd2t/personal/audiobooks/` (fuera de `media/`) y respaldarlas como archivos personales.

Procedimiento de restore tras pérdida del contenedor (datos intactos en `hd2t`):

```bash
docker compose -f /home/homelab/homelab/stacks/audiobookshelf/docker-compose.yml up -d --force-recreate
# ABS reusa /mnt/hd2t/apps/audiobookshelf/{config,metadata}: arranque normal
# en ~20 s, todos los usuarios, progreso y suscripciones siguen ahí.
```

Procedimiento de restore tras pérdida total (reflasheo + restauración Borg):

1. Recrear Fases 1 → 7.
2. `borgmatic extract --archive latest --path mnt/hd2t/apps/audiobookshelf`.
3. Verificar permisos: `sudo chown -R homelab:homelab /mnt/hd2t/apps/audiobookshelf && sudo chmod 0750 /mnt/hd2t/apps/audiobookshelf/{config,metadata}`.
4. Confirmar/recrear `/mnt/hd2t/media/{audiobooks,podcasts}` (vacíos al inicio; reabsorber contenido por separado).
5. `docker compose -f stacks/audiobookshelf/docker-compose.yml up -d`.
6. `https://audiobookshelf.lan` → login con credenciales pre-existentes; cuando se vuelva a poblar `/audiobooks`, ABS re-escanea y la BBDD restaurada re-asocia (los IDs internos son hashes basados en path + tags). Los podcasts vuelven a descargarse según `Auto Download Schedule`.

---

## Errores frecuentes y troubleshooting

| Síntoma | Causa probable | Resolución |
|---|---|---|
| `https://audiobookshelf.lan` da `502 Bad Gateway` | Caddy no resuelve `audiobookshelf` (contenedor caído o no en la red `homelab`). | `docker ps --filter name=audiobookshelf`. Si está caído, `docker logs audiobookshelf --tail 100`. Si está vivo: `docker network inspect homelab` debe listarlo. |
| UI carga pero "No items in this library" tras primer escaneo | ABS no encuentra ficheros en `/audiobooks`, o no tiene permisos. | `docker exec audiobookshelf ls /audiobooks \| head`. Si vacío: revisar bind mount; si "Permission denied": `group_add: ["1100"]` y permisos `2770` en el árbol. |
| Logs ABS: `EACCES: permission denied, open '/audiobooks/...'` | El usuario interno (PUID 1000) no es miembro del grupo `media` (1100). | Confirmar `group_add: ["1100"]` del compose. `docker exec audiobookshelf id` debe listar `1100`. |
| Logs ABS: `EROFS: read-only file system, ... '/audiobooks/...'` durante un escaneo | "Store metadata with library" está activado para la biblioteca de audiobooks, pero el bind mount es `:ro`. | Settings → Library → Audiobooks → "Store metadata with library" → DESACTIVAR. |
| App móvil: "Unable to connect" en LAN | El móvil usa DNS distinto (CGNAT del operador) que no resuelve `audiobookshelf.lan`. | Forzar el móvil a usar Pi-hole (DHCP del router → Primary DNS = 192.168.1.2) o añadir `audiobookshelf.lan -> 192.168.1.10` al DNS del dispositivo. |
| App móvil: "Server certificate is invalid" | El móvil no tiene la CA interna instalada o la app no la confía. | Instalar la CA en el sistema; o usar tailnet (`audiobookshelf.<ts-tailnet>.ts.net` con cert legítimo); o "Allow self-signed certificates" en la app (solo aceptable en LAN). |
| Reproducción se corta cada N minutos en la app móvil | El WebSocket de progreso se desconecta por el reverse proxy (timeout demasiado bajo) o por NAT del móvil al hibernar. | `read_timeout 8h` ya cubre el primer caso. Para el segundo, la app reabre WebSocket automáticamente al volver a foreground; si se corta el audio, comprobar que la app tiene "Allow background audio" y exclusión de optimización de batería. |
| Podcasts no se descargan | El bind mount `/podcasts` no es `:rw`, o el feed RSS no responde. | `docker exec audiobookshelf touch /podcasts/.write_test && docker exec audiobookshelf rm /podcasts/.write_test`. Si falla: revisar que el bind mount esté SIN `:ro`. Si tiene éxito: revisar `docker logs audiobookshelf` durante el chequeo programado. |
| Logs ABS: "Error fetching feed" recurrente | Feed RSS caído o cambió de URL. | Settings → Podcast → editar URL; o quitar el podcast si está abandonado. |
| Conversión a M4B falla con "ffmpeg: command not found" | Imagen distinta de la documentada (sin `ffmpeg` empaquetado). | Verificar imagen: `docker inspect audiobookshelf --format '{{.Config.Image}}'`; debe ser `lscr.io/linuxserver/audiobookshelf:2.17.7`. |
| Match de provider devuelve resultados pobres en libros en español | Audible.com (default) tiene poco catálogo en español. | Cambiar Provider a Audible.es, iTunes (.es), o Google Books con idioma forzado a `es`. |
| Tras `docker compose pull`, ABS no arranca: "database migration failed" | Bump de minor con migración fallida (raro). | Restore `config/absdatabase.sqlite` desde el snapshot Borg de la noche anterior. Reportar issue upstream. |
| `https://audiobookshelf.lan/healthcheck` da 500 | ABS arrancado pero la BBDD no se abrió (bloqueo, permisos). | `docker logs audiobookshelf \| grep -i "database\|sqlite"`. Si lock: parar ABS, mover `config/absdatabase.sqlite-journal` y reabrir. Si permisos: verificar owner. |
| `Authelia` interfiere a pesar del bypass | El fragmento `09-audiobookshelf-bypass.yml` no se cargó en `configuration.yml`. | `docker logs authelia \| grep audiobookshelf`; revisar la inclusión del fragmento; reiniciar Authelia. |
| `https://audiobookshelf.lan` muestra cert "no confiable" tras instalar la CA | Caddy no recargó el `Caddyfile` (drop-in nuevo). | `docker exec caddy caddy validate --config /etc/caddy/Caddyfile && docker kill --signal=SIGUSR1 caddy`. |
| Progreso no se sincroniza entre móvil y web | El usuario logueado en el móvil es distinto al de la web (sesión cacheada de un usuario antiguo). | Settings → Users → Active Sessions; revocar; volver a loguear. |
| ABS marca libros como "duplicados" innecesariamente | Tags ID3 inconsistentes (mismo álbum/título pero artist distinto entre tracks de un mismo libro). | Re-tagging con `tone` (CLI incluido en LSIO: `docker exec audiobookshelf tone tag --help`) o con MusicBrainz Picard. Forzar re-scan tras la limpieza. |

---

## Decisiones que **no** se toman en este documento

- **Authelia delante de ABS**: descartado por compatibilidad con apps móviles. Reabrible solo con OIDC nativo (ABS 2.7+) cuando Authelia OIDC esté maduro en este homelab.
- **OIDC con Authelia**: posible pero pendiente. La UI web podría delegar login a Authelia OIDC; las apps móviles tienen flujo OIDC con deep link, pero el setup es delicado y los tokens caducan distinto que la sesión nativa de ABS.
- **Migración a Bookreader / Storyteller / alternativas**: ABS es el más activo y mejor mantenido. No se considera migración salvo que el proyecto se estanque.
- **Indexación de música**: ABS no es la herramienta. La biblioteca de música pertenece a Navidrome (`02-navidrome.md`).
- **Carga automática desde Audible / catálogos comerciales**: fuera de alcance. El operador alimenta `/mnt/hd2t/media/audiobooks/` por su cuenta.
- **TTS / generación de audiolibros sintéticos**: fuera de alcance. ABS solo cataloga.
- **Backups del catálogo de audiolibros**: política deliberada de no respaldar `/mnt/hd2t/media/audiobooks/` desde ABS (igual que JF/ND). Documentada arriba.
- **Métricas Prometheus**: ABS **no** expone métricas Prometheus nativas (a diferencia de ND). Si se quieren, hay un exporter terciario (`audiobookshelf-prometheus-exporter`) que consume la API. Reabrible en Fase 5.
- **Streaming a un altavoz externo (DLNA/Chromecast)**: la app oficial soporta Cast a Chromecast cuando el dispositivo está en la misma LAN; no requiere configuración en el servidor. No se entra en detalle aquí.

---

## Verificación Final

Antes de pasar a `04-calibre-web.md`:

| Comprobación | Comando | Resultado esperado |
|---|---|---|
| Stack desplegado y saludable | `docker compose -f stacks/audiobookshelf/docker-compose.yml ps` | `audiobookshelf ... Up (healthy)` |
| Imagen correcta y fija | `docker inspect audiobookshelf --format '{{.Config.Image}}'` | `lscr.io/linuxserver/audiobookshelf:2.17.7` |
| Conectado a la red homelab y NO a host | `docker inspect audiobookshelf --format '{{.HostConfig.NetworkMode}}'` | `default` o `homelab` (no `host`) |
| Sin puertos publicados al host | `docker port audiobookshelf` | salida vacía |
| `audiobookshelf.lan` resuelve al IP de la Pi | `dig +short audiobookshelf.lan @192.168.1.2` | `192.168.1.10` |
| Caddy sirve `audiobookshelf.lan` con cert de la CA interna | `echo \| openssl s_client -connect audiobookshelf.lan:443 -servername audiobookshelf.lan 2>/dev/null \| openssl x509 -noout -issuer` | `issuer=CN=Homelab Internal CA` |
| Health endpoint responde | `curl -ksS https://audiobookshelf.lan/healthcheck` | `HTTP 200` |
| Usuario interno con grupos correctos | `docker exec audiobookshelf id` | `uid=1000 gid=1000 groups=1000,1100` |
| `/audiobooks` montado read-only | `docker exec audiobookshelf sh -c 'touch /audiobooks/.write_test 2>&1 \| head -1'` | `touch: ... Read-only file system` |
| `/podcasts` montado read-write | `docker exec audiobookshelf sh -c 'touch /podcasts/.write_test && rm /podcasts/.write_test && echo OK'` | `OK` |
| API REST responde a un usuario válido | `curl -ksS -H "Authorization: Bearer $ABS_TOKEN" https://audiobookshelf.lan/api/me \| jq .username` | `"<usuario>"` |
| Catálogo poblado tras escaneo | UI: pantalla principal con libros listados; o `GET /api/libraries/<id>/items` | lista no vacía |
| Login funciona desde navegador | navegador con CA instalada | UI carga el dashboard tras login |
| App móvil real funciona | App oficial en móvil | reproducción de un libro con progreso sincronizado |
| Owner correcto del config | `stat -c '%u:%g %a' /mnt/hd2t/apps/audiobookshelf/config` | `1000:1000 750` |
| Owner correcto del podcasts dir | `stat -c '%u:%g %a' /mnt/hd2t/media/podcasts` | `1000:1100 2770` |
| Authelia bypass para `audiobookshelf.lan` | `curl -ksI https://audiobookshelf.lan/` | sin `Location` apuntando a `auth.lan` |
| WebSocket de progreso operativo | abrir DevTools en la UI y comprobar conexión `wss://audiobookshelf.lan/socket.io/...` | conexión establecida (101 Switching Protocols) |
| Sin warnings críticos en logs | `docker logs audiobookshelf 2>&1 \| grep -iE 'error\|fail' \| head` | salida razonable (no errores recurrentes de permisos o BBDD) |

---

## Referencias

- Documentación oficial Audiobookshelf — https://www.audiobookshelf.org/docs
- Configuration & guides — https://www.audiobookshelf.org/guides
- API REST reference — https://api.audiobookshelf.org/
- Imagen LinuxServer.io — https://docs.linuxserver.io/images/docker-audiobookshelf/
- Imagen Docker LSIO — https://lscr.io/linuxserver/audiobookshelf
- Imagen Docker upstream — https://hub.docker.com/r/advplyr/audiobookshelf
- Repo del proyecto — https://github.com/advplyr/audiobookshelf
- App móvil (código fuente) — https://github.com/advplyr/audiobookshelf-app
- Plappa (cliente iOS terciario) — https://apps.apple.com/app/plappa/
- ShelfPlayer (cliente iOS open source) — https://github.com/rasmuslos/ShelfPlayer
- `tone` (tagger CLI integrado en LSIO) — https://github.com/sandreas/tone
- OPDS spec (catálogo expuesto por ABS) — https://specs.opds.io/
- Documentos hermanos: `01-jellyfin.md`, `02-navidrome.md`, `04-calibre-web.md`, `05-stash.md`.
- Documentos referenciados: `01-sistema/04-estructura-directorios.md`, `02-docker/02-estructura-compose.md`, `03-red/02-pihole.md`, `03-red/04-caddy.md`, `03-red/05-tailscale.md`, `04-seguridad/01-authelia.md`, `07-backups/01-estrategia-backup.md`, `07-backups/02-borgmatic.md`.
