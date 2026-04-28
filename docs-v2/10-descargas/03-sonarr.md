# Sonarr

## Descripción

Despliegue de **Sonarr v4** ([imagen `lscr.io/linuxserver/sonarr`](https://docs.linuxserver.io/images/docker-sonarr/)) como **PVR de series de TV** del homelab. Es la tercera pieza de la **Fase 10 — Gestión de Descargas** y el **cerebro de catalogación de series**: Sonarr toma indexadores de **Prowlarr** ([`./02-prowlarr.md`](./02-prowlarr.md)), busca episodios faltantes (o monitoriza nuevas emisiones), envía el `.torrent`/`magnet:` a **Transmission** ([`./01-transmission.md`](./01-transmission.md)) y, cuando la descarga termina, **mueve/hardlinka** el fichero desde `/mnt/hd2t/downloads/complete/` a `/mnt/hd2t/media/tv/<Show>/Season XX/<Show> - SxxEyy - <Title>.<ext>`, con renombrado consistente para que **Jellyfin** ([`../09-multimedia/01-jellyfin.md`](../09-multimedia/01-jellyfin.md)) las identifique sin reglas custom. Radarr ([`./04-radarr.md`](./04-radarr.md)) hace exactamente lo mismo para películas; ambos comparten Prowlarr y Transmission.

Este doc cubre, en orden:

1. **Por qué Sonarr v4** y no Sonarr v3 / SickChill / Medusa, qué se asume y qué se descarta.
2. **Plan de variables y archivos**: `.env.example` versionable, `.env` real con la `API key` (autogenerada por Sonarr en el primer arranque) y las credenciales RPC de Transmission en `/mnt/hd2t/services/sonarr/.env` (chmod 600), layout de directorios bajo `/mnt/hd2t/services/sonarr/`.
3. **`docker-compose.yml`** con bind mounts de `/config` (respaldable), `/downloads` (RW, apuntando a `/mnt/hd2t/downloads/`) y `/tv` (RW, apuntando a `/mnt/hd2t/media/tv/`), `networks: [homelab]`, **sin** publicar el puerto `8989` (Caddy llega por DNS interno).
4. **Despliegue, onboarding inicial** (recoger la `API key` de `config.xml`, configurar `Authentication = Forms`, password fuerte).
5. **Integración con Caddy** ([`../03-red/04-caddy.md`](../03-red/04-caddy.md) §4.3): bloque `sonarr.{$LAN_DOMAIN}` con `forward_auth` a Authelia (`sonarr.{$LAN_DOMAIN}` ya está reservado en [`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md) §4 — política `two_factor`, `group:admin`).
6. **Configuración del proceso**: añadir Root Folder `/tv`, Download Client Transmission con categoría `tv-sonarr`, Quality Profiles (HD-1080p, HD-720p, Any), Language Profile (`Spanish`, `English`), Custom Formats opcionales (preferir x265, evitar HDR si la TV no lo soporta), Naming (formato Plex/Jellyfin estándar), Media Management (hardlinks **on**, recycle bin habilitado).
7. **Sincronización con Prowlarr**: registrar Sonarr en Prowlarr → Apps (visto al revés en [`./02-prowlarr.md`](./02-prowlarr.md) §7.4); los indexadores aparecen en Sonarr automáticamente.
8. **Backup**: `/config/sonarr.db` (SQLite, vía `sqlite3 .backup`) + `/config/config.xml` (la API key vive ahí) + `/config/Backups/` propios de Sonarr; `logs/`, `MediaCover/`, `MediaInfo/` excluidos por regenerables. Política coherente con [`../07-backups/03-backup-docker-volumes.md`](../07-backups/03-backup-docker-volumes.md) §4.8.
9. **Operaciones cotidianas**: añadir una serie nueva, monitorizar temporadas, manejar episodios que no llegan (Manual Search), gestión de la History, importación manual de un fichero existente (`Library Import`), corregir un episodio mal nombrado, subir un nivel de calidad sin reimportar.
10. **Variantes opt-in**: **bazarr** sidecar para subtítulos automáticos, IMAX Enhanced/Atmos en Custom Formats, integración con Notifiarr/Telegram, hardlinks en cross-fs (no aplica aquí pero documentado), múltiples instancias (Sonarr 4K aparte) con `Sonarr.Anime` para la rama anime separada.

> **Alcance de red**: la **UI web** (8989) **solo se accede vía Caddy** sobre `https://sonarr.lan` (LAN) o `https://sonarr.${TS_DOMAIN}` (Tailscale). **No hay puerto publicado al host.** Sonarr **no necesita conexiones entrantes** desde internet — solo hace **salientes** a Prowlarr (para sincronizar y buscar), a Transmission (para enviar torrents y consultar estado) y a TheTVDB/TMDb/TVMaze (para metadatos). Es del mismo perfil "tranquilo" de red que Prowlarr.

> **Diferencia con Transmission**: en [`./01-transmission.md`](./01-transmission.md) se abrió `51413/tcp+udp` en el router para BitTorrent P2P. **Sonarr no abre nada**: solo HTTPS saliente y HTTP a `transmission:9091` por la red interna. Si el operador quitó incluso ese único port forward, Sonarr funciona igual; solo Transmission se vería degradado.

---

## Requisitos Previos

- **Sistema base operativo** según Fase 1: usuario `homelab` (UID 1000), grupo `media` (GID 1100) con `homelab` como miembro, `/mnt/hd2t/` montado, directorio `/mnt/hd2t/services/sonarr/` ya creado por el bootstrap de [`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) §4 (loop "Fase 10 — Descargas") y `/mnt/hd2t/media/tv/` con grupo `media` y bit `setgid` (ídem §6).
- **Docker + red `homelab`** según Fase 2: red bridge `homelab` creada, convenciones de Compose ([`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §3.5 — bind mounts; §4.3 — red compartida; §5.2 — `PUID=1000`/`PGID=1100` para acceso al grupo `media`).
- **Caddy desplegado** ([`../03-red/04-caddy.md`](../03-red/04-caddy.md)) con `lan_internal_tls` operativo y la red `homelab` accesible. Sin Caddy no hay HTTPS para la UI de Sonarr y el `forward_auth` de Authelia no aplica.
- **Pi-hole desplegado** ([`../03-red/02-pihole.md`](../03-red/02-pihole.md)) con la posibilidad de añadir registros A locales (`sonarr.lan` → IP de la Pi).
- **Authelia desplegado** ([`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md)) con el dominio `sonarr.{$LAN_DOMAIN}` ya registrado en `access_control.rules` (política `two_factor`, `subject: group:admin`). En el `Caddyfile` el bloque de Sonarr usa `forward_auth http://authelia:9091`.
- **Transmission desplegado** ([`./01-transmission.md`](./01-transmission.md)) con `rpc-username`/`rpc-password` en `.env`, `download-dir: /downloads/complete`, accesible desde la red `homelab` por nombre `transmission:9091` con URL base `/transmission/`. Sonarr **no funciona** sin un download client al que enviar los torrents.
- **Prowlarr desplegado** ([`./02-prowlarr.md`](./02-prowlarr.md)) con al menos un indexador testeado en verde. Sonarr **sí** puede arrancar sin Prowlarr (lo hará en cualquier caso — es desacoplado), pero el flujo de búsqueda fallará hasta que Prowlarr le inyecte indexadores vía Sync App.
- **Watchtower desplegado** ([`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md)). Sonarr lleva la etiqueta `com.centurylinklabs.watchtower.enable: "true"` por política — la imagen LSIO publica `latest` con cambios menores y la BD SQLite de Sonarr (`/config/sonarr.db`) es **forward-compatible** entre versiones (Sonarr corre migraciones automáticamente al subir; un downgrade puede romper, pero no se hace nunca).
- **Borgmatic operativo** ([`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md)) para que `/mnt/hd2t/services/sonarr/config/` sea archivado. Sonarr cae en la sección **§4.8 (servicios SQLite simples)** del doc de Borgmatic y el patrón de [`../07-backups/03-backup-docker-volumes.md`](../07-backups/03-backup-docker-volumes.md) §4.8 (uso de `sqlite3 .backup` para evitar copia inconsistente).
- **Disco hd2t libre**: ~200 MB para `/mnt/hd2t/services/sonarr/config/` (la BD crece con el tamaño de la biblioteca: ~1 KB por episodio + posters cacheados ~2 MB por serie + logs rotados ~50 MB). El consumo "real" lo absorben las series en `/mnt/hd2t/media/tv/`, que se contabiliza por separado en [`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md).
- **Cuentas en TheTVDB / TVMaze**: **no necesarias**. Sonarr v4 usa Skyhook (proxy oficial Servarr a TheTVDB) sin API key del usuario. Si el operador se cuestiona por qué Sonarr v3 pedía login a TheTVDB, esa fricción desapareció en v4.

### Decisiones de diseño asumidas

| Decisión | Valor por defecto | Justificación |
|---|---|---|
| PVR de TV | **Sonarr** v4 | Es el estándar *arr para series desde hace una década. SickChill/Medusa han perdido ritmo de releases y no integran con Prowlarr de forma nativa (siguen usando indexadores definidos en su propia UI, sin sync). Sonarr v4 es .NET 6 (vs v3 mono), arranca en ~5s, soporta Custom Formats en lugar de los antiguos "Release Profiles", y tiene API v3 estable. Es la única elección racional para el homelab. |
| Imagen | **`lscr.io/linuxserver/sonarr`** | LSIO publica con `s6-overlay`, healthchecks y `PUID/PGID`. La imagen "oficial" `linuxserver/sonarr` es la misma redistribuida con más latencia. Cambiar a `hotio/sonarr` rompería permisos por UID interno distinto (nano vs LSIO usan UIDs diferentes). |
| Tag de imagen | **`4.0.10.2544-ls248`** (no `latest`, no `develop`) | LSIO publica tags semánticos `<upstream>-<lsio_revision>` desde el branch `main` de Sonarr. Pinear el patch fuerza al operador a leer https://github.com/linuxserver/docker-sonarr/releases antes de actualizar. Watchtower está habilitado pero respeta el tag fijo (compara digest del mismo tag, ver [`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §3); para subir de minor el operador edita `.env` y hace `docker compose pull`. |
| Arquitectura | `linux/arm64` (Pi 5) | Manifest multi-arch oficial. La Pi 5 es nativa 64-bit. |
| Red Docker | **`homelab`** (bridge, [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §4.3). **Sin** `8989` publicado. | Caddy llega a la UI por nombre (`http://sonarr:8989`). Prowlarr llega por sync (`http://sonarr:8989/api/v3/...`). Bazarr (opt-in §12.1) llegaría también por nombre. Sin tráfico entrante desde internet, no hay justificación para publicar el puerto al host. |
| Modelo de almacenamiento | **Bind mount** `/mnt/hd2t/services/sonarr/config:/config` + **Bind mount** `/mnt/hd2t/downloads:/downloads` (RW) + **Bind mount** `/mnt/hd2t/media/tv:/tv` (RW) | Patrón estándar del homelab. **Las dos rutas multimedia tienen que estar en el mismo filesystem** (`/mnt/hd2t/`) para que Sonarr pueda hacer **hardlink** de `/downloads/complete/<algo>` a `/tv/<Show>/Season XX/...` y no duplicar espacio mientras Transmission siga seedeando. Un cross-mount entre HDDs degradaría a `cp` (doble espacio) o `mv` (rompería el seeding). Por eso Sonarr **no monta `/mnt/hd5t/`** ni nada externo a `hd2t`. |
| Bibliotecas | **Solo `/tv`** | Sonarr **es exclusivo de TV**. Películas las gestiona Radarr ([`./04-radarr.md`](./04-radarr.md)) en `/mnt/hd2t/media/movies/`. Audiobooks/música no entran en el *arr stack base. |
| Usuario dentro del contenedor | **`PUID=1000` (homelab) + `PGID=1100` (media)** vía las variables que respeta LSIO | Coherente con [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §5.2. `PGID=1100` (no `1000`) porque Sonarr **escribe en `/mnt/hd2t/media/tv/`** y necesita el grupo `media` para que el bit `setgid` funcione (los ficheros nuevos heredan `homelab:media` y Jellyfin/Samba pueden leerlos). En Prowlarr usábamos `PGID=1000` porque solo escribía en `/config`; aquí no aplica. |
| Auth de la UI | **Authelia delante** (Caddy `forward_auth`) **+** auth nativa Forms | Doble defensa, mismo patrón que Prowlarr/Transmission. Sonarr **siempre** usa auth nativa (Forms) porque desde la 4.0.0 rechaza arrancar sin auth en redes no-loopback. Authelia añade SSO + 2FA TOTP delante. La API (`X-Api-Key`) **no pasa por Caddy** — Prowlarr la usa directamente por la red interna `homelab`. |
| `Authentication Method` (Settings → General) | **`Forms (Login Page)`** | `Basic` rompe Authelia (doble basic auth simultáneo confunde al navegador). `External` es para entornos donde Authelia/SSO ya gestiona TODO via headers `Remote-User` — es viable si el operador quiere SSO 100% transparente, pero requiere reglas Authelia más finas (un fallo y Sonarr queda abierto). Forms con Authelia delante es defensa en profundidad: si Authelia se cae, Forms sigue protegiendo. |
| `Authentication Required` | **`Disabled for Local Addresses`** | Esto desactiva la auth de Forms para peticiones provenientes de la subred `homelab` Docker (172.20.0.0/24) — exactamente la subred desde la que llegan Prowlarr y Bazarr. Significa: Authelia delante para humanos vía Caddy, API por la red interna sin auth nativa adicional pero **sí** con `X-Api-Key`. |
| `URL Base` | **vacío** (`/`) | Caddy reenvía `/` directamente a `http://sonarr:8989/`. No hay path-based routing necesario — cada *arr tiene su propio subdominio (`sonarr.lan`, `radarr.lan`, `prowlarr.lan`). |
| `API Key` | **autogenerada al primer arranque**, expuesta por `.env` después | Sonarr genera la API key en `/config/config.xml` al primer `docker compose up -d`. La leemos con `xmllint` o `grep`, la metemos en el `.env` real y la consumen Prowlarr (Sync App), Bazarr y Homepage. El `.env` queda chmod 600. |
| `Log Level` | **`info`** | Default. `debug`/`trace` solo bajo demanda — los logs los rota LSIO en `/config/logs/`. |
| `Backup Folder` | **`/config/Backups`** (default) | Sonarr hace backups internos `.zip` con `sonarr.db` + `config.xml` cada cierto tiempo. Esto **se incluye** en Borg además del backup externo. |
| Indexadores | **Sincronizados desde Prowlarr** (no añadidos manualmente aquí) | Cualquier indexador añadido a mano en Sonarr → Settings → Indexers se mantiene, pero rompe la "fuente única de verdad" de Prowlarr. Política del homelab: en Sonarr **no se añade ningún indexador manualmente**; todos llegan vía Prowlarr Sync App. |
| Download client | **Transmission** ([`./01-transmission.md`](./01-transmission.md)) | Único cliente del homelab. Si en el futuro se añade SABnzbd para Usenet (opt-in en [`./02-prowlarr.md`](./02-prowlarr.md) §12.2), Sonarr soporta múltiples download clients en paralelo y elige por categoría. |
| Categoría en Transmission | **`tv-sonarr`** | Etiqueta el torrent en Transmission para que Sonarr filtre solo los suyos en la queue. Radarr usa `movies-radarr`. |
| Hardlinks | **`Use Hardlinks instead of Copy = ON`** | Permite que un episodio descargado en `/downloads/complete/<release>/episode.mkv` también aparezca en `/tv/<Show>/Season XX/episode.mkv` **sin duplicar espacio en disco** mientras Transmission siga seedeando. Funciona porque ambos paths están en el mismo `ext4` (hd2t). Sin hardlinks, Sonarr `cp` el fichero (doble espacio) o `mv` (rompe seeding) — ambos peores. |
| Recycle Bin | **`/tv/.recycle`**, retención 7 días | Antes de borrar definitivamente, Sonarr mueve el fichero a `.recycle`. Recuperación inmediata si el operador se equivoca. La carpeta no entra en backup (regenerable). |
| Quality Profile principal | **HD-1080p** (Bluray > WEB-DL > HDTV, sin SDTV) | Default razonable para una TV moderna. Calidades inferiores quedan disponibles como fallback si no hay versión HD del episodio. |
| Custom Formats | **Mínimos**: penalizar `HDR` si la pantalla del operador no lo soporta, preferir `x265` para ahorrar espacio (compromiso CPU/storage). | Default conservador. Casos avanzados (Atmos, IMAX Enhanced) en §12.3. |
| Naming | **Plex/Jellyfin estándar**: `{Series Title} - S{season:00}E{episode:00} - {Episode Title} {Quality Full}` para episodios; `Season {season:00}` para subcarpetas. | Coherente con Jellyfin. Cambiar el formato más tarde es seguro — Sonarr renombra ficheros existentes con `Mass Editor`, pero rompe enlaces de Plex/Jellyfin si el operador ya tenía vistas registradas. |
| Backup | **Solo `/config`** vía Borgmatic | Patrón [`../07-backups/03-backup-docker-volumes.md`](../07-backups/03-backup-docker-volumes.md) §4.8: SQLite con `sqlite3 .backup` (no `cp` directo). Las series en `/mnt/hd2t/media/tv/` se respaldan según política propia (ver [`../07-backups/01-estrategia-backup.md`](../07-backups/01-estrategia-backup.md) — generalmente excluidas o con retención corta). |
| Watchtower | **`com.centurylinklabs.watchtower.enable: "true"`** | Por política ([`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §4.2, sección "stateless o de lectura ligera"): Sonarr no muta esquema BD entre patches, los upgrades minor son seguros, y un nightly defectuoso sería re-arrancado por `restart: unless-stopped` y alertado por Uptime Kuma. |
| Reverse proxy | **Caddy con `forward_auth` a Authelia** | Doble capa: TLS interno + SSO/2FA. La API para Prowlarr/Bazarr **no pasa por Caddy** sino por la red interna (`http://sonarr:8989/api/v3/...` con `X-Api-Key`); por tanto Authelia no estorba a la sync. |
| Acceso remoto | **Vía Tailscale** ([`../03-red/05-tailscale.md`](../03-red/05-tailscale.md)) — `sonarr.${TS_DOMAIN}` con `tls /data/tailscale-certs/sonarr.crt /data/tailscale-certs/sonarr.key` | Sin port forwarding HTTP ni DDNS para la UI. El homelab no necesita exponer Sonarr a internet. |

---

## 1. Resumen de la arquitectura

```
                            Internet (HTTPS saliente, sin entrante)
                              ▲
                              │ - búsquedas: Prowlarr (no aquí)
                              │ - metadatos: skyhook.sonarr.tv,
                              │              api.thetvdb.com
                              │ - calendarios: tvmaze
                              │
                  ┌───────────┴────────────────────┐
                  │   Pi 5 (host)  192.168.1.x     │
                  │   sin puertos publicados       │
                  └────────────────┬───────────────┘
                                   │
                                   ▼ docker network: homelab (172.20.0.0/24)
        ┌────────────────────────────────────────────────────────────┐
        │                          Sonarr                            │
        │     (este doc, :8989 INTERNO)                              │
        │                                                            │
        │  /config (RW) ─► /mnt/hd2t/services/sonarr/config/         │
        │     ├── sonarr.db   (SQLite — series, episodios, history)  │
        │     ├── config.xml  (API key, port)                        │
        │     ├── Backups/    (zips internos)                        │
        │     ├── MediaCover/ (posters cacheados)                    │
        │     └── logs/                                              │
        │                                                            │
        │  /downloads (RW) ─► /mnt/hd2t/downloads/                   │
        │     └── complete/ <Release>/  ← Transmission deja aquí     │
        │                                  Sonarr LEE de aquí        │
        │  /tv (RW) ─► /mnt/hd2t/media/tv/                           │
        │     └── <Show>/Season XX/<file>  ← Sonarr ESCRIBE aquí     │
        │                                  (hardlink desde complete) │
        └─┬───────────────┬────────────────┬───────────────┬─────────┘
          │               │                │               │
          │ http://       │ http://        │ http://       │ http://
          │ sonarr:8989/  │ prowlarr:9696  │ transmission: │ skyhook
          │   (UI)        │   (sync)       │   9091/RPC    │ + thetvdb
          ▼               ▼                ▼               (HTTPS)
   ┌──────────────┐ ┌──────────────┐ ┌──────────────┐
   │    Caddy     │ │   Prowlarr   │ │ Transmission │
   │  sonarr.lan  │ │ (sync app    │ │ (download    │
   │      ▲       │ │  empuja      │ │  client)     │
   │      │       │ │  indexers    │ └──────────────┘
   │  forward_auth│ │  a Sonarr)   │
   │      │       │ └──────────────┘
   │      ▼       │
   │   Authelia   │   (../04-seguridad/01-authelia.md)
   └──────────────┘
          ▲
          │
    Operador (web)
    ─► https://sonarr.lan
       [Authelia OTP]
       [Sonarr Forms login (cacheado)]
```

Lo crítico de este diagrama:

1. **Tres rutas distintas, tres niveles de auth distintos.** Igual que Prowlarr.
   - **Operador → UI**: pasa por Caddy → Authelia (cookie SSO + 2FA TOTP) → Sonarr (Forms login, cacheado en el navegador).
   - **Prowlarr → Sonarr API**: por la red interna `homelab` directamente al puerto `8989` del contenedor — Caddy no la ve, Authelia no la ve. Su credencial es el `X-Api-Key` de Sonarr.
   - **Sonarr → Transmission RPC**: HTTP Basic con `${TRANSMISSION_RPC_USERNAME}:${TRANSMISSION_RPC_PASSWORD}` por la red interna `homelab`, **sin** Caddy ni Authelia.
2. **Ninguna ruta `Sonarr → indexadores` directa.** A diferencia de Prowlarr, Sonarr **no busca** en trackers públicos/privados directamente: pide a Prowlarr ("búscame `Show.S05E03 1080p`") y Prowlarr le devuelve la lista. Sonarr solo elige qué descarga concreta encolar en Transmission. Esto **simplifica enormemente** el modelo de red de Sonarr (no hay cookies de trackers, no hay Cloudflare challenges, no hay rate limits — todo eso lo absorbe Prowlarr).
3. **Mismo filesystem entre `/downloads` y `/tv`.** La pieza crítica: ambos son bind mounts dentro de `/mnt/hd2t/`, que es un único `ext4`. **Esto habilita hardlinks** y, por tanto, que un fichero pueda existir simultáneamente en `complete/` (para que Transmission lo siga seedeando) y en `tv/` (para que Jellyfin lo escanee) sin ocupar el doble. Si en el futuro alguien decide mover `media/` a `hd5t` o a un NFS externo, hardlinks dejan de funcionar y Sonarr cae a `cp`.
4. **API key separada de la sesión Forms.** El flujo humano (Forms cacheado) y el flujo máquina (`X-Api-Key`) son completamente independientes. Cambiar la password del usuario `homelab` no invalida la API key, y rotar la API key (§10.5) no echa al operador de la UI.

---

## 2. Plan de variables y archivos

### 2.1. Variables del stack (`.env.example` versionable)

`~/homelab/stacks/sonarr/.env.example`:

```env
# ~/homelab/stacks/sonarr/.env.example
# Versión control: ~/homelab/stacks/sonarr/.env.example
# Valores reales en /mnt/hd2t/services/sonarr/.env (chmod 600).
# La SONARR_API_KEY se rellena DESPUÉS del primer arranque, leyéndola de
# /mnt/hd2t/services/sonarr/config/config.xml (§5.3).

# --- Comunes del homelab ---
HOMELAB_USER=homelab
HOMELAB_UID=1000
HOMELAB_GID=1000
MEDIA_GID=1100
TZ=Europe/Madrid

# --- Dominios internos (consistentes con dns/.env y proxy/.env) ---
LAN_DOMAIN=lan
TS_DOMAIN=tailnet.ts.net

# --- Sonarr ---
# https://github.com/linuxserver/docker-sonarr/releases
# Lista de cambios upstream: https://github.com/Sonarr/Sonarr/releases
SONARR_IMAGE_TAG=4.0.10.2544-ls248

# Hostname público (sin esquema). Usado en Caddyfile y en Sonarr → URL Base.
SONARR_HOSTNAME=sonarr
SONARR_LAN_HOST=sonarr.lan
SONARR_TS_HOST=sonarr.tailnet.ts.net

# API key — autogenerada por Sonarr al primer arranque.
# Se rellena tras leer /mnt/hd2t/services/sonarr/config/config.xml.
# Prowlarr la consume por la sync app (../10-descargas/02-prowlarr.md §7.4).
# Bazarr la consume si se despliega (§12.1).
SONARR_API_KEY=__rellenar_tras_primer_arranque__

# --- Credenciales del download client (Transmission) ---
# Mismas credenciales que en /mnt/hd2t/services/transmission/.env
# (../10-descargas/01-transmission.md §2). Sonarr las usa para la API RPC.
TRANSMISSION_RPC_USERNAME=homelab
TRANSMISSION_RPC_PASSWORD=__copiar_de_transmission_env__

# Subred de la red `homelab` (../02-docker/02-estructura-compose.md §4.1).
# Sonarr necesita confiar en esta subred para "Disabled for Local Addresses".
HOMELAB_SUBNET=172.20.0.0/24
```

### 2.2. `.env` real (`/mnt/hd2t/services/sonarr/.env`)

Primera versión (sin `SONARR_API_KEY` aún — la rellenamos en §5.3):

```bash
# Crear el directorio del servicio si no existe (lo crea el bootstrap
# de ../01-sistema/04-estructura-directorios.md §4, paso "Fase 10").
sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/services/sonarr

# Crear el .env con permisos correctos.
sudo install -o homelab -g homelab -m 600 /dev/null \
  /mnt/hd2t/services/sonarr/.env

# Leer la password RPC de Transmission (debe existir ya, ./01-transmission.md §5).
TRPC_PASS=$(sudo grep '^TRANSMISSION_RPC_PASSWORD=' \
  /mnt/hd2t/services/transmission/.env | cut -d= -f2-)

# Volcar contenido inicial (la API key vendrá tras el primer up).
sudo -u homelab tee /mnt/hd2t/services/sonarr/.env > /dev/null <<EOF
HOMELAB_USER=homelab
HOMELAB_UID=1000
HOMELAB_GID=1000
MEDIA_GID=1100
TZ=Europe/Madrid
LAN_DOMAIN=lan
TS_DOMAIN=tailnet.ts.net
SONARR_IMAGE_TAG=4.0.10.2544-ls248
SONARR_HOSTNAME=sonarr
SONARR_LAN_HOST=sonarr.lan
SONARR_TS_HOST=sonarr.tailnet.ts.net
SONARR_API_KEY=
TRANSMISSION_RPC_USERNAME=homelab
TRANSMISSION_RPC_PASSWORD=${TRPC_PASS}
HOMELAB_SUBNET=172.20.0.0/24
EOF

# Verificar.
ls -l /mnt/hd2t/services/sonarr/.env
# Esperado: -rw------- 1 homelab homelab ... .env
```

> **Por qué duplicamos `TRANSMISSION_RPC_PASSWORD` aquí**: Sonarr necesita la password RPC para llamar a `transmission:9091`. La fuente de verdad sigue siendo el `.env` de Transmission; rotar la password ahí obliga a actualizarla aquí (operación documentada en §10.6). Alternativa: usar Docker secrets con un fichero compartido — más complejidad para un solo secreto, no compensa.

### 2.3. Cómo se inyectan al contenedor

El `docker-compose.yml` (§4) declara `env_file: /mnt/hd2t/services/sonarr/.env`. Compose carga el fichero **a la hora de interpolar `${...}` en el YAML** y **además** lo expone al proceso del contenedor. Las variables que la imagen LSIO **lee directamente** son:

- `PUID`, `PGID`, `TZ`, `UMASK_SET` (LSIO universal).
- **Nada específico de Sonarr.** A diferencia de Transmission (que tenía `USER`/`PASS`/`PEERPORT`), la imagen LSIO de Sonarr no inyecta nada de configuración runtime: todo se gestiona desde la UI o editando `config.xml` a mano. Por eso `SONARR_API_KEY` y `TRANSMISSION_RPC_PASSWORD` se usan **fuera** del contenedor (en Caddyfile, en `.env` de Prowlarr/Bazarr) o por la UI de Sonarr (introducir Transmission con esa password) pero **no** se inyectan por env al contenedor de Sonarr.

El resto (`SONARR_HOSTNAME`, `SONARR_LAN_HOST`, `LAN_DOMAIN`, …) solo se usa **fuera** del contenedor: en el `Caddyfile` y en este `docker-compose.yml`.

> **Por qué `SONARR_API_KEY` sí va en `.env`** (a diferencia de la password de Authelia, que es secreto en `/run/secrets/`): es **la única credencial** que Prowlarr/Bazarr/Homepage necesitan para hablar con Sonarr. Compartirla por `.env` (chmod 600) es coherente con cómo `TRANSMISSION_RPC_PASSWORD` y `PROWLARR_API_KEY` viven en sus respectivos `.env`. El modelo de amenaza es el mismo: usuario `root` o `homelab` sí ven el secreto, pero ningún otro proceso del sistema lo hace.

---

## 3. Preparar el árbol de datos

### 3.1. Crear el directorio del stack

```bash
mkdir -p ~/homelab/stacks/sonarr
cd ~/homelab/stacks/sonarr
```

### 3.2. Crear el árbol de datos persistentes del servicio

```bash
# /mnt/hd2t/services/sonarr/  (homelab:homelab 750)
sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/services/sonarr
sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/services/sonarr/config
```

LSIO crea el resto de subdirectorios (`logs/`, `Backups/`, `MediaCover/`, `MediaInfo/`, `xdg/`, …) en su entrypoint.

Las dos rutas de bibliotecas (`/mnt/hd2t/downloads/`, `/mnt/hd2t/media/tv/`) ya existen tras el bootstrap de [`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) §6 con `homelab:media 2775`. Verificar:

```bash
ls -ld /mnt/hd2t/downloads /mnt/hd2t/downloads/complete /mnt/hd2t/media/tv
# drwxrwsr-x 2 homelab media ... /mnt/hd2t/downloads
# drwxrwsr-x 2 homelab media ... /mnt/hd2t/downloads/complete
# drwxrwsr-x 2 homelab media ... /mnt/hd2t/media/tv

# El bit `s` (setgid) en el grupo es lo crítico: ficheros nuevos heredan el grupo media.
```

### 3.3. Tabla resumen de permisos

| Ruta | Owner:Group | Modo | Notas |
|---|---|---|---|
| `/mnt/hd2t/services/sonarr/` | `homelab:homelab` | `750` | Directorio raíz del servicio. Solo `homelab`. |
| `/mnt/hd2t/services/sonarr/.env` | `homelab:homelab` | `600` | Contiene `SONARR_API_KEY` y `TRANSMISSION_RPC_PASSWORD`. Solo legible por `homelab` (y `root`). |
| `/mnt/hd2t/services/sonarr/config/` | `homelab:homelab` | `750` | Datos de Sonarr: `sonarr.db`, `config.xml`, `Backups/`, `MediaCover/`, `logs/`. Respaldable con `sqlite3 .backup`. |
| `/mnt/hd2t/services/sonarr/config/sonarr.db` | `homelab:homelab` | `644` (default LSIO) | BD SQLite con series, episodios, history, indexers sincronizados, download client. Backup vía `sqlite3 .backup`, no `cp` ([`../07-backups/03-backup-docker-volumes.md`](../07-backups/03-backup-docker-volumes.md) §4.8). |
| `/mnt/hd2t/services/sonarr/config/config.xml` | `homelab:homelab` | `644` | API key, port, URL base, log level. Texto plano XML. |
| `/mnt/hd2t/downloads/` | `homelab:media` | `2775` | Ya existe ([`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) §6). `setgid` activo. |
| `/mnt/hd2t/media/tv/` | `homelab:media` | `2775` | Ya existe. Sonarr escribe aquí: nuevos ficheros heredan grupo `media`. |
| `/mnt/hd2t/media/tv/.recycle/` | (creado por Sonarr) `homelab:media` | `2775` | Recycle bin de Sonarr. Borrado periódico por la propia Sonarr (retención 7 días, ver §7.4). |

### 3.4. Permisos para el proceso del contenedor

LSIO ejecuta el entrypoint como `root` y dentro hace `chown -R abc:abc /config /downloads /tv` con `abc` mapeado al `PUID:PGID` del env. Por tanto, **dentro del contenedor** el proceso `Sonarr` corre como UID 1000, GID 1100.

**Importante**: el `chown -R` sobre `/downloads` y `/tv` **puede tardar varios minutos** si el operador ya tiene cientos de GB de descargas/series. LSIO ofrece la variable `LSIO_NON_ROOT_USER=true` (sin chown recursivo, asume que el host ya tiene los permisos correctos), pero rompe casos donde un fichero nuevo aparece con otro owner. **Recomendación: el primer arranque sin `LSIO_NON_ROOT_USER`**, dejar que termine el chown, y si en el futuro se siente lento añadirlo (los siguientes arranques son instantáneos).

El `start_period` del healthcheck (120s) cubre el primer arranque incluyendo el chown.

---

## 4. `docker-compose.yml`

`~/homelab/stacks/sonarr/docker-compose.yml`:

```yaml
# ~/homelab/stacks/sonarr/docker-compose.yml
# Stack: sonarr (PVR de TV del *arr stack, Fase 10).
# Datos en /mnt/hd2t/services/sonarr/config/.
# Bibliotecas en /mnt/hd2t/downloads/ (RW, lee de complete/) y /mnt/hd2t/media/tv/ (RW, escribe).

name: sonarr

services:
  sonarr:
    image: lscr.io/linuxserver/sonarr:${SONARR_IMAGE_TAG}
    container_name: sonarr
    hostname: sonarr
    restart: unless-stopped
    env_file: /mnt/hd2t/services/sonarr/.env

    environment:
      # PUID 1000 (homelab), PGID 1100 (media). Sonarr escribe en /tv y necesita
      # el grupo `media` para que el setgid heredado funcione (ficheros nuevos
      # con grupo media → Jellyfin/Samba los pueden leer).
      PUID: ${HOMELAB_UID}
      PGID: ${MEDIA_GID}
      TZ: ${TZ}
      # umask 002 → ficheros 0664, dirs 0775. Combinado con setgid en /tv y
      # /downloads, los ficheros nuevos quedan homelab:media 0664 — leíbles y
      # escribibles por Jellyfin/Bazarr/Samba (todos miembros del grupo media).
      UMASK_SET: "002"

    volumes:
      # Config respaldable: sonarr.db (SQLite), config.xml (API key),
      # Backups/, MediaCover/ (cache), logs/.
      - /mnt/hd2t/services/sonarr/config:/config
      # Descargas (RW): Sonarr lee de /downloads/complete/<release>/, hace hardlink
      # a /tv/<Show>/Season XX/, deja la copia "vieja" en complete/ para que
      # Transmission siga seedeando. NO escribe en incomplete/ ni watch/.
      - /mnt/hd2t/downloads:/downloads
      # Biblioteca de TV (RW): destino de los hardlinks. Mismo filesystem que
      # /downloads (CRÍTICO para hardlinks).
      - /mnt/hd2t/media/tv:/tv
      # TZ y reloj sincronizados con el host (timestamps en logs).
      - /etc/localtime:/etc/localtime:ro

    # NO PUBLICAR PUERTOS. Caddy llega por DNS interno (http://sonarr:8989).
    # Prowlarr llega por la API por la red `homelab`. Bazarr (opt-in) idem.
    # Si alguien añade `ports: - "8989:8989"`, romperá el modelo de seguridad
    # (Authelia bypassable saltándose Caddy con curl al host:8989).

    networks:
      - homelab

    # Recursos: Sonarr arranca con ~250 MB (.NET 6 + SQLite + libs). En reposo
    # se estabiliza en 300-500 MB (depende del tamaño de la biblioteca).
    # Picos durante una RSS Sync masiva o un Mass Editor hasta 1 GB.
    mem_limit: 1280m
    mem_reservation: 256m

    # Healthcheck: GET /ping devuelve 200 con `Pong` cuando Sonarr está vivo.
    # Este endpoint es público (no requiere API key) desde Sonarr 3.0+.
    healthcheck:
      test: ["CMD-SHELL", "curl -fsS http://localhost:8989/ping || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 120s

    security_opt:
      - no-new-privileges:true

    labels:
      # Watchtower: actualizar automáticamente.
      # Política: ../02-docker/04-watchtower.md §4.2.
      com.centurylinklabs.watchtower.enable: "true"
      # Para Dozzle: agrupar logs del *arr stack.
      dev.dozzle.group: "arr"

networks:
  homelab:
    external: true
```

### 4.1. Por qué cada bloque

| Bloque | Por qué |
|---|---|
| `name: sonarr` | Nombre del proyecto Compose. Cada servicio del *arr stack tiene su propio stack folder — un `down` afecta solo a Sonarr y no para Prowlarr/Radarr/Transmission. |
| `image: lscr.io/linuxserver/sonarr:${SONARR_IMAGE_TAG}` | Tag pinned vía `.env`. Vive en LinuxServer Container Registry. |
| `container_name: sonarr` / `hostname: sonarr` | Nombre estable para que Caddy llegue por DNS (`reverse_proxy http://sonarr:8989`) y para que Prowlarr use `sonarr` como host de la sync app. Sin esto, Compose le pone un nombre tipo `sonarr-sonarr-1` y rompe el DNS interno. |
| `env_file: /mnt/hd2t/services/sonarr/.env` | Carga de variables — patrón estándar del homelab. |
| `environment.PUID` / `PGID` | UID 1000 (escribe en `/config`), GID 1100 (escribe en `/tv` y `/downloads/complete` con `setgid` heredado). |
| `environment.TZ` | Sonarr loguea timestamps en zona local y planifica RSS sync con horario local. |
| `environment.UMASK_SET: "002"` | Ficheros nuevos `0664`, directorios `0775`. Jellyfin/Bazarr/Samba (todos GID 1100 o miembros) pueden leer. |
| `volumes: /mnt/hd2t/services/sonarr/config:/config` | Bind mount canónico de la BD. Sin `:Z`/`:z` (no SELinux en Pi OS). |
| `volumes: /mnt/hd2t/downloads:/downloads` | Bind mount **del directorio padre completo** de descargas (no solo `complete/`). Sonarr necesita ver `incomplete/` aunque no escriba en él, porque consulta el progreso de descargas activas en Transmission y mapea al fichero. **No** se monta `:ro` aunque solo "leamos" porque Sonarr **mueve/borra** ficheros de `complete/` con hardlinks (la operación de hardlink es escritura). |
| `volumes: /mnt/hd2t/media/tv:/tv` | Bind mount de la biblioteca destino. **Mismo filesystem** que `/downloads` para hardlinks. |
| `volumes: /etc/localtime:ro` | Sincroniza la zona del host con el contenedor — backup ante un usuario que olvide poner `TZ` en `.env`. |
| **Sin `ports:`** | Patrón canónico del homelab. Caddy llega por DNS interno; el operador no necesita `curl http://localhost:8989` desde el host (puede hacer `docker exec sonarr curl http://localhost:8989/ping` para debug). |
| `networks: [homelab]` | Solo la red compartida. Caddy ya está ahí; Prowlarr/Radarr/Transmission/Bazarr también. |
| `mem_limit: 1280m` | Sonarr ronda 300-500 MB; picos al hacer Mass Editor o RSS Sync de una biblioteca grande hasta 1 GB. 1280 MB de tope deja margen sin pegarse con el resto del homelab. La Pi 5 (8 GB) tiene ~6 GB libres tras descontar el SO; Sonarr ocupa el ~6%. |
| `mem_reservation: 256m` | Garantía mínima en presión de memoria. Sonarr no degrada bien con OOM (corrupción posible de `sonarr.db` si crashea durante un commit). |
| `healthcheck` con `curl` a `/ping` | Endpoint público sin auth desde 3.0+. `start_period: 120s` cubre el primer arranque (chown recursivo + migraciones de BD + carga inicial; en una Pi 5 con biblioteca pequeña tarda ~30s, con biblioteca grande hasta 90s). |
| `security_opt: no-new-privileges:true` | Patrón base ([`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §0). |
| `com.centurylinklabs.watchtower.enable: "true"` | Watchtower opt-in ([`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §4.2). Sonarr es elegible por el mismo argumento que Prowlarr: BD pequeña con migraciones reversibles, imagen LSIO valida arranque antes de marcar el `latest`. |
| `dev.dozzle.group: "arr"` | Agrupa logs con Prowlarr, Radarr y Transmission cuando Dozzle ([`../05-monitorizacion/06-dozzle.md`](../05-monitorizacion/06-dozzle.md)) levante. |
| `networks.homelab.external: true` | Patrón de [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §4.4: la red se crea **una vez** durante el bootstrap. |

### 4.2. Validar antes de levantar

```bash
cd ~/homelab/stacks/sonarr
docker compose --env-file /mnt/hd2t/services/sonarr/.env config
```

Esperado: salida YAML resuelta sin warnings. Verificar especialmente:

- `image: lscr.io/linuxserver/sonarr:4.0.10.2544-ls248` (el tag interpolado).
- `PUID: "1000"`, `PGID: "1100"` (no `1000` en `PGID`).
- `networks: [homelab]`.
- **No** debe aparecer ningún `ports:` (si aparece, alguien lo añadió por error).
- Los tres bind mounts (`/config`, `/downloads`, `/tv`) están presentes con sus paths del host correctos.

Si Compose se queja de `version` en el YAML: la spec moderna no necesita `version: "3.x"`; está omitido a propósito.

---

## 5. Despliegue

### 5.1. Levantar el stack

```bash
cd ~/homelab/stacks/sonarr

# Pull explícito antes del up: separa errores de imagen de errores de runtime.
docker compose --env-file /mnt/hd2t/services/sonarr/.env pull
docker compose --env-file /mnt/hd2t/services/sonarr/.env up -d

docker compose ps
# sonarr   running (starting → healthy ~60-120s después)
```

### 5.2. Estado del contenedor

```bash
docker inspect sonarr \
  --format '{{.State.Status}} | {{.State.Health.Status}}'
# running | healthy

docker logs sonarr --tail 80
```

Logs típicos del primer arranque:

```
[migrations] started
[migrations] no migrations found
─────────────────────────────────────
       _         ()
      | |        |||
   _  | | __  __ ||| ___    LinuxServer.io
  | |_| | \  \/  /  / __|   image  by   :
  | __ | / /\  \ / / __ \   linuxserver.io
  |_| | \____\____\\____\
─────────────────────────────────────
GID/UID
─────────────────────────────────────
User uid:    1000
User gid:    1100
─────────────────────────────────────
[Info] Bootstrap: Starting Sonarr - /app/sonarr/bin/Sonarr
[Info] Bootstrap: Sonarr X64 v4.0.10.2544 main
[Info] AppFolderInfo: Data folder: /config
[Info] MigrationController: *** Migrating data source=/config/sonarr.db ***
[Info] MigrationController: *** N: ... migrating ***
[Info] OwinHostController: Listening on http://0.0.0.0:8989
[Info] OwinHostController: Started Sonarr.
```

Si en lugar de `Listening on http://0.0.0.0:8989` aparece un stack trace de SQLite con `database is locked` o `Malformed database`, ver §11.

### 5.3. Recoger la API key autogenerada

Sonarr genera la API key al arrancar y la escribe en `/config/config.xml`. La leemos y la metemos en el `.env`:

```bash
# Leer la API key generada.
SONARR_API_KEY=$(sudo grep '<ApiKey>' /mnt/hd2t/services/sonarr/config/config.xml \
  | sed -E 's,.*<ApiKey>([^<]+)</ApiKey>.*,\1,')
echo "API key: $SONARR_API_KEY"
# Esperado: 32 chars hex, p. ej. a1b2c3d4e5f60718293a4b5c6d7e8f90

# Apuntarla en el password manager bajo "Homelab → Sonarr API key"
# (la necesitarás al configurar Prowlarr → Apps).

# Inyectarla en el .env (preservando el resto del fichero).
sudo sed -i \
  -e "s|^SONARR_API_KEY=.*|SONARR_API_KEY=${SONARR_API_KEY}|" \
  /mnt/hd2t/services/sonarr/.env

# Verificar.
sudo grep '^SONARR_API_KEY=' /mnt/hd2t/services/sonarr/.env
```

> **Por qué no la generamos nosotros antes**: Sonarr **siempre** regenera la API key si encuentra `<ApiKey></ApiKey>` vacío en `config.xml`. Pre-poblar la key en el `.env` no la inyecta automáticamente — habría que editarla manualmente en `config.xml`, parar el contenedor (porque Sonarr lee `config.xml` solo al arrancar) y volverlo a levantar. Es más simple dejarla autogenerar y leerla.

### 5.4. Smoke check de la API antes de la UI

A partir de aquí Sonarr está accesible **internamente** en `http://sonarr:8989/` desde la red `homelab`. No es accesible desde el host hasta que Caddy esté configurado (§6). Verificación pre-UI:

```bash
# Ping interno (desde otro contenedor en la red homelab).
docker run --rm --network homelab curlimages/curl:latest \
  http://sonarr:8989/ping
# {"status":"OK"}

# API authenticada (status del sistema).
docker run --rm --network homelab curlimages/curl:latest \
  -H "X-Api-Key: ${SONARR_API_KEY}" \
  http://sonarr:8989/api/v3/system/status
# {"appName":"Sonarr","instanceName":"Sonarr","version":"4.0.10.2544",...}
```

### 5.5. Crear el primer usuario (Authentication = Forms)

En la UI Sonarr **fuerza** crear un usuario admin la primera vez que se accede sin auth. Como queremos hacerlo *antes* de que Caddy enrute (para no tener que pasar por Authelia en este paso de bootstrap), hacemos un port-forward temporal al host:

```bash
# Túnel SSH: localhost:8989 → contenedor sonarr:8989
# (suponiendo que estás trabajando en remoto; en local, ssh -L 8989 desde tu laptop).
SONARR_IP=$(docker inspect sonarr \
  --format '{{.NetworkSettings.Networks.homelab.IPAddress}}')
ssh -L 8989:${SONARR_IP}:8989 homelab@pi
```

Abrir `http://localhost:8989/` en el navegador → Sonarr pide:

- **Authentication Method**: Forms (Login Page).
- **Username**: `homelab` (mismo usuario que Authelia, por consistencia).
- **Password**: el del password manager bajo "Homelab → Sonarr UI" (32 chars urlsafe).
- **Authentication Required**: **Disabled for Local Addresses** (clave para que Prowlarr/Bazarr puedan usar la API por la red interna sin pasar por el formulario de login).

Tras guardar, Sonarr persiste la config en `sonarr.db` y `config.xml`. Cerrar el túnel SSH:

```bash
# Ctrl+C en la terminal del túnel.
```

> Alternativa sin túnel SSH: configurar Caddy primero (§6), añadir el bloque `sonarr.lan` **sin** Authelia (comentar el `forward_auth`), hacer el primer login, y luego añadir Authelia y recargar. Es más pasos pero evita el túnel.

---

## 6. Integración con Caddy

### 6.1. Añadir el bloque `sonarr.{$LAN_DOMAIN}` al `Caddyfile`

`~/homelab/stacks/proxy/Caddyfile`, sección de bloques de host (siguiendo el patrón de §4.3 de [`../03-red/04-caddy.md`](../03-red/04-caddy.md)):

```caddy
# ----- Sonarr (../10-descargas/03-sonarr.md) -----
sonarr.{$LAN_DOMAIN} {
    import lan_internal_tls
    import security_headers

    # Authelia delante: 2FA TOTP obligatorio (group:admin), ../04-seguridad/01-authelia.md §4.
    forward_auth http://authelia:9091 {
        uri /api/authz/forward-auth
        copy_headers Remote-User Remote-Groups Remote-Name Remote-Email
    }

    reverse_proxy http://sonarr:8989 {
        # Sonarr no necesita rewrite — sirve la UI en /.
        header_up X-Forwarded-Proto https
        header_up X-Real-IP {remote_host}
    }
}
```

Recargar Caddy:

```bash
docker exec proxy caddy reload --config /etc/caddy/Caddyfile
```

### 6.2. Trusted proxies en Sonarr

Sonarr soporta `Settings → General → Reverse Proxy → Trusted Proxies`. Recomendado para que la cabecera `X-Forwarded-For` se honre correctamente (Sonarr la usa en logs y en la lógica de "Disabled for Local Addresses"). Sin esto, Sonarr ve todas las peticiones provenientes de la IP del bridge Docker (`172.20.0.1`) en lugar de la IP real del cliente.

UI → Settings → General → Security → **Trusted Proxies**: `172.20.0.0/24`. Save.

### 6.3. Registro DNS local en Pi-hole

`https://pihole.lan/admin/` → **Local DNS → DNS Records**:

| Domain | IP Address |
|---|---|
| `sonarr.lan` | `192.168.1.x` (IP fija de la Pi) |

Verificar:

```bash
dig +short sonarr.lan @192.168.1.2
# 192.168.1.x   (IP de la Pi)
```

### 6.4. Probar el acceso

Desde un equipo de la LAN con la CA interna confiada (paso 6.5 de [`../03-red/04-caddy.md`](../03-red/04-caddy.md)):

```
https://sonarr.lan
```

Flujo esperado:

1. **Authelia** redirige a `https://auth.lan/?rd=https://sonarr.lan/`.
2. Login con usuario `homelab` (con grupo `admin`).
3. **2FA TOTP** (configurado en el primer login a Authelia, [`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md)).
4. Tras OK, Caddy reenvía a `http://sonarr:8989/` y **Sonarr no vuelve a pedir login** porque la cookie de Forms está cacheada (si es el primer login: la pide una vez y luego ya queda).

> **Por qué doble auth visible solo el primer día**: el navegador cachea la cookie de Forms `Sonarr` por 30 días, así que tras el primer login solo se ve Authelia. Si el operador limpia cookies o cambia de navegador, ve los dos formularios consecutivos.

### 6.5. Por qué Authelia delante de Sonarr por defecto

Mismas razones que Prowlarr ([`./02-prowlarr.md`](./02-prowlarr.md) §6.5) y Transmission ([`./01-transmission.md`](./01-transmission.md) §6.5):

- **Authelia delante**: la auth Forms de Sonarr es razonable (PBKDF2, lockout interno) pero sin 2FA. Authelia cubre ese hueco con TOTP obligatorio.
- **No interfiere con Prowlarr/Bazarr**: ellos hablan al puerto interno 8989 con `X-Api-Key`, **sin** pasar por Caddy ni Authelia.
- **No interfiere con apps móviles**: Sonarr tiene apps Android/iOS no oficiales (nzb360, Sonarr Companion) que usan la API directa con `X-Api-Key`. Si el operador las usa **desde fuera de la LAN**, debe enchufarlas a la URL Tailscale (`sonarr.${TS_DOMAIN}`) y configurarlas con la API key — pasan por Caddy pero **no** por Authelia (el `forward_auth` ignora rutas `/api/...` solo si el operador lo declara explícitamente; ver §12.4 si esto se necesita).

### 6.6. Acceso vía Tailscale (preparado)

Cuando Tailscale esté operativo ([`../03-red/05-tailscale.md`](../03-red/05-tailscale.md)), añadir al `Caddyfile`:

```caddy
sonarr.{$TS_DOMAIN} {
    import tailscale_tls sonarr
    import security_headers

    # Authelia también delante en Tailscale (no es un "remoto de confianza").
    forward_auth http://authelia:9091 {
        uri /api/authz/forward-auth
        copy_headers Remote-User Remote-Groups Remote-Name Remote-Email
    }

    reverse_proxy http://sonarr:8989 {
        header_up X-Forwarded-Proto https
        header_up X-Real-IP {remote_host}
    }
}
```

---

## 7. Configuración post-despliegue

La mayoría de la configuración va por la UI (Sonarr no expone variables de entorno para series ni quality profiles; es BD-driven).

### 7.1. Settings → General

| Sección | Campo | Valor recomendado | Notas |
|---|---|---|---|
| Host | `Bind Address` | `*` | Default. |
| Host | `Port Number` | `8989` | Default. **No cambiar** — coincide con el `EXPOSE` de la imagen LSIO y con el `http://sonarr:8989` del Caddyfile. |
| Host | `URL Base` | (vacío) | Caddy reenvía `/` directamente. |
| Host | `Enable SSL` | `Off` | TLS lo gestiona Caddy. |
| Security | `Authentication` | `Forms (Login Page)` | (ver §5.5). |
| Security | `Authentication Required` | `Disabled for Local Addresses` | Permite que Prowlarr/Bazarr pasen sin form-auth (siguen necesitando `X-Api-Key`). |
| Security | `Trusted Proxies` | `172.20.0.0/24` | (ver §6.2). |
| Logging | `Log Level` | `Info` | Default. `Debug`/`Trace` solo bajo demanda. |
| Updates | `Branch` | `main` | Default. **No** seleccionar `develop` — el `latest` de LSIO ya empaqueta `main`. |
| Updates | `Automatic` | `Off` | Watchtower hace el upgrade del contenedor. La opción "Automatic" interna de Sonarr (descarga el binario dentro del contenedor) **no es relevante** en imágenes Docker — además choca con la política Watchtower. |
| Updates | `Mechanism` | `Docker` | Etiqueta solo descriptiva en imágenes Docker; deshabilita el botón "Update" de la UI para evitar confusión. |
| Backup | `Folder` | `/config/Backups` | Default. Borg lo respaldará dentro de `/config`. |
| Backup | `Interval` | `7 days` | Default. Generación de `.zip` interno cada semana. |
| Backup | `Retention` | `28 days` | Default. ~4 zips guardados. |

### 7.2. Settings → Media Management

Configuración crítica de Sonarr — controla cómo Sonarr renombra y ubica los ficheros. Los valores se guardan en `Settings → Media Management`.

| Sección | Campo | Valor recomendado | Notas |
|---|---|---|---|
| Episode Naming | `Rename Episodes` | `Yes` | Sin rename, los ficheros mantienen el nombre del release (`Show.S05E03.1080p.WEB-DL.x264-GROUP.mkv`), feo en Jellyfin. |
| Episode Naming | `Replace Illegal Characters` | `Yes` | Default. Reemplaza `:`, `?`, `<`, `>`, `*`, `|` por `_`. |
| Episode Naming | `Standard Episode Format` | `{Series Title} - S{season:00}E{episode:00} - {Episode Title} {Quality Full}` | Formato Plex/Jellyfin estándar. |
| Episode Naming | `Daily Episode Format` | `{Series Title} - {Air-Date} - {Episode Title} {Quality Full}` | Para shows diarios (talk shows). |
| Episode Naming | `Anime Episode Format` | `{Series Title} - S{season:00}E{episode:00} - {absolute:000} - {Episode Title} {Quality Full}` | Para anime con numeración absoluta. |
| Episode Naming | `Series Folder Format` | `{Series Title}` | Default. Sin año por defecto; Sonarr lo añade si hay colisión. |
| Episode Naming | `Season Folder Format` | `Season {season:00}` | Default. `Season 01`, `Season 02`, …; `Specials` para temporada 0. |
| Folders | `Create empty series folders` | `No` | Si una serie no tiene episodios descargados, no crear carpeta vacía en `/tv/`. |
| Folders | `Delete empty folders` | `Yes` | Limpia carpetas vacías tras eliminar episodios. |
| Importing | `Episode Title Required` | `Always` | Sin título no hay rename; ficheros sin metadata se quedan en `complete/` esperando el título. |
| Importing | **`Use Hardlinks instead of Copy`** | **`Yes`** | **Crítico**. Permite que `/downloads/complete/<x>/episode.mkv` y `/tv/<Show>/Season XX/episode.mkv` sean el mismo inodo — sin duplicar espacio. |
| Importing | `Import Extra Files` | `Yes`, extensiones `srt,nfo,info,sub` | Importa subtítulos sueltos del release. |
| File Management | `Unmonitor Deleted Episodes` | `Yes` | Si el operador borra un fichero, Sonarr no lo re-baja. |
| File Management | `Propers and Repacks` | `Do Not Prefer` | Cambiar a `Prefer` si el operador es purista de calidad y quiere upgrade automático de releases con bugs. Por defecto evita re-descargar lo mismo. |
| File Management | `Analyse video files` | `Yes` | Sonarr lee el header del .mkv para extraer codec, resolución, audio. Lento pero útil para Custom Formats. |
| File Management | **`Recycling Bin`** | **`/tv/.recycle`** | (ver §7.4). |
| File Management | `Recycling Bin Cleanup` | `7 days` | Borrar `.recycle/` automáticamente tras 7 días. |
| Permissions | `Set Permissions` | `Yes` | LSIO maneja permisos por `umask`/`PUID`/`PGID`; este flag asegura que Sonarr re-aplica el `chmod` después de mover un fichero. |
| Permissions | `chmod Folder` | `775` | Coherente con `umask 002`. |
| Permissions | `chmod File` | `664` | Idem. |
| Permissions | `chown Group` | (vacío) | Sonarr corre con `homelab:media`; los ficheros nuevos heredan grupo `media` por `setgid`. |

### 7.3. Settings → Quality

Sonarr define `Quality Profiles` que dicen qué resolución/codec/release-type aceptar y en qué orden. La configuración por defecto es razonable para HD.

#### 7.3.1. Quality Definitions (megabytes/minuto por calidad)

`Settings → Quality → Quality Definitions` define los **tamaños esperados** por minuto de episodio. Sonarr usa esto para descartar releases obviamente mal etiquetados (un "1080p" de 50 MB no es 1080p real).

Los defaults son razonables. Solo ajustar si:

- El operador tiene mucho espacio y quiere admitir versiones grandes (subir el `Max` de `WEBDL-1080p` de 100 a 200 MB/min).
- El operador tiene poco espacio y quiere descartar Bluray REMUX (bajar el `Max` de `Bluray-1080p` de 250 a 100 MB/min).

#### 7.3.2. Quality Profiles

`Settings → Profiles → Quality Profiles` — definir **un profile principal** y opcionalmente uno de fallback:

```
Quality Profile: HD-1080p
- Allowed:
  - WEBDL-1080p
  - Bluray-1080p
  - WEBRip-1080p
- Cutoff: WEBDL-1080p
- Upgrade Allowed: Yes
- Custom Formats:
  - (vacío al inicio; rellenar tras §7.3.3)
```

```
Quality Profile: HD-720p (fallback)
- Allowed:
  - WEBDL-720p
  - HDTV-720p
- Cutoff: WEBDL-720p
- Upgrade Allowed: Yes
```

```
Quality Profile: Any (último recurso)
- Allowed: TODAS excepto Unknown y Raw-HD
- Cutoff: WEBDL-1080p
```

`Cutoff` significa "para de buscar upgrades cuando alcances esta calidad". Sin cutoff, Sonarr re-descarga eternamente intentando llegar al máximo permitido — caro en bandwidth.

#### 7.3.3. Custom Formats (opcional, recomendado)

Las Custom Formats reemplazan a los antiguos Release Profiles. Permiten preferir/penalizar ciertos releases más allá de la calidad pura. Mínimo recomendado:

```
Custom Format: Penalizar HDR (si la TV no lo soporta)
- Match: Resolution = (cualquiera) AND VideoDynamicRangeType = (HDR10, HDR10Plus, DolbyVision)
- Score: -10000  (efectivamente prohibido)
```

```
Custom Format: Preferir x265
- Match: Codec = x265
- Score: +50
```

```
Custom Format: Penalizar GROUP basura (opcional)
- Match: ReleaseGroupRegex = ^(EVO|RARBG|YIFY)$
- Score: -100  (no descartar, pero preferir otros)
```

Asignar las Custom Formats a los Quality Profiles: `Settings → Profiles → Quality Profiles → HD-1080p → Custom Formats` → puntuar cada una.

> **Empezar mínimo**: añadir Custom Formats de a poco y verificar el efecto en la History. Una Custom Format mal escrita rechaza todos los releases.

### 7.4. Settings → Profiles → Language Profiles

| Profile | Languages | Comentario |
|---|---|---|
| `Spanish/English` | Spanish, English (en ese orden de preferencia, dejar `Allowed Languages` con ambos). | Default razonable para España. Sonarr prefiere ES si existe el release; si no, EN; si no, descarta. |
| `Original` | Original | Para series que solo quieres en idioma original (anime, K-drama). |

### 7.5. Settings → Indexers

**No añadir nada manualmente**. Tras desplegar Prowlarr ([`./02-prowlarr.md`](./02-prowlarr.md)) y registrar Sonarr en `Prowlarr → Apps`, los indexadores aparecerán aquí automáticamente vía Sync App. El operador puede ver la lista pero no debe editarla — cualquier cambio se sobrescribe en el siguiente sync.

Verificar tras el sync inicial (§7.10):

```bash
docker run --rm --network homelab curlimages/curl:latest \
  -H "X-Api-Key: ${SONARR_API_KEY}" \
  http://sonarr:8989/api/v3/indexer | jq '.[] | .name'
# Lista de indexadores propagados desde Prowlarr.
```

### 7.6. Settings → Download Clients — Transmission

Pieza crítica: cómo Sonarr habla con Transmission.

```
Settings → Download Clients → [+] → Transmission

Name:           Transmission
Enable:         Yes
Host:           transmission
Port:           9091
URL Base:       /transmission/
Username:       ${TRANSMISSION_RPC_USERNAME}    (= homelab)
Password:       ${TRANSMISSION_RPC_PASSWORD}    (de /mnt/hd2t/services/transmission/.env)
Category:       tv-sonarr
Directory:      (vacío — usa download-dir de Transmission, /downloads/complete/)
Use SSL:        No
Recent Priority:  Normal
Older Priority:   Normal
```

Tras `Test → Save`, Sonarr verifica que puede conectarse a Transmission. Si falla:

- `Connection refused`: Transmission no está corriendo o no está en la red `homelab` (verificar con `docker network inspect homelab`).
- `Unauthorized`: password mal copiada (revisar `.env`).
- `URL Base`: si Transmission tiene `rpc-url: /transmission/` (default LSIO), `URL Base: /transmission/` es correcto. Si alguien lo cambió en `settings.json`, ajustar aquí.

### 7.7. Remote Path Mappings — **NO necesarios**

Importante: en este homelab **no hay que configurar Remote Path Mappings**. Razón:

- Transmission ve los ficheros completos en `/downloads/complete/<release>/episode.mkv` (paths internos del contenedor Transmission).
- Sonarr ve los mismos ficheros en `/downloads/complete/<release>/episode.mkv` (paths internos del contenedor Sonarr).
- Ambos contenedores comparten el bind mount `/mnt/hd2t/downloads/` → `/downloads/`. **Los paths internos coinciden**.

Esto evita la fricción típica del setup multi-host (donde Sonarr corre en una máquina y Transmission en otra, y los paths son distintos). Si en el futuro alguien mueve Transmission a otra máquina, **entonces** habría que añadir un Remote Path Mapping (`Settings → Download Clients → Remote Path Mappings → Add` con `Host: transmission`, `Remote Path: /downloads`, `Local Path: /downloads`). En esta arquitectura, **no**.

### 7.8. Settings → Connect — Notifications

Configurar al menos una notificación para detectar fallos de descarga:

```
Settings → Connect → [+] → Telegram

Name:                 Telegram
Bot Token:            <token>
Chat ID:              <chat>
Send Silently:        No
Notification Triggers:
  ☐ On Grab           (mucho ruido si se descargan muchos episodios diarios)
  ☑ On Import         (avisa cuando un episodio entra en /tv/)
  ☐ On Episode File Delete
  ☑ On Health Issue   (avisa de errores: indexer roto, download client caído)
  ☑ On Health Issue Resolved
  ☑ On Application Update
```

Otras opciones disponibles: Email, ntfy, Discord, Pushover, Notifiarr, Custom Script (§12.5).

### 7.9. Root Folders

Definir la ubicación de la biblioteca:

```
Settings → Media Management → Root Folders → Add Root Folder

Path: /tv
```

Al guardar, Sonarr escanea `/tv/` por carpetas que parezcan series (heurística por nombre + búsqueda en TheTVDB). Si el operador ya tenía series ahí, las detecta y propone "Library Import" (§10.7).

Sonarr verifica que `/tv` es **escribible** (toca un fichero de prueba). Si falla, revisar que el bind mount `/mnt/hd2t/media/tv:/tv` está RW y que `homelab:media` tiene el bit `setgid` en `/mnt/hd2t/media/tv/` ([`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) §6).

### 7.10. Sincronizar con Prowlarr

Tras configurar todo lo anterior en Sonarr, ir al **Prowlarr** ([`./02-prowlarr.md`](./02-prowlarr.md) §7.4) y registrar Sonarr en `Prowlarr → Apps`:

```
Prowlarr UI → Settings → Apps → Add Application ([+]) → Sonarr

Name:           Sonarr
Sync Level:     Add and Remove Only
Tags:           (vacío o "tv-sonarr")
Prowlarr Server: http://prowlarr:9696
Sonarr Server:   http://sonarr:8989
ApiKey:          <SONARR_API_KEY de §5.3>

Test → Save.
```

A los pocos segundos, los indexadores configurados en Prowlarr aparecerán en `Sonarr → Settings → Indexers`. Verificar:

```bash
docker run --rm --network homelab curlimages/curl:latest \
  -H "X-Api-Key: ${SONARR_API_KEY}" \
  http://sonarr:8989/api/v3/indexer | jq '.[].name'
# Lista de indexadores que coincide con la de Prowlarr.
```

### 7.11. Aplicar y verificar

```bash
# Verificar que Sonarr ha persistido el download client y los root folders:
sudo sqlite3 /mnt/hd2t/services/sonarr/config/sonarr.db \
  "SELECT Name, Implementation, Settings FROM DownloadClients;"
# Transmission|Transmission|{"host":"transmission","port":9091,...}

sudo sqlite3 /mnt/hd2t/services/sonarr/config/sonarr.db \
  "SELECT Path FROM RootFolders;"
# /tv
```

> **Cuidado al hacer queries directas a `sonarr.db`**: hacer `sqlite3 ... write` con el contenedor corriendo puede corromper la BD. Para read-only basta con `sudo sqlite3 sonarr.db ".dump"`.

---

## 8. Verificación

### 8.1. Contenedor sano

```bash
docker compose ps
# sonarr   running (healthy)
docker inspect sonarr --format '{{.State.Health.Status}}'
# healthy
```

### 8.2. Sonarr no escucha al host (solo dentro de la red `homelab`)

```bash
# Desde dentro del contenedor: sí escucha 8989.
docker exec sonarr ss -tnlp | grep ':8989'
# tcp   LISTEN  0  100  *:8989   *:*   users:(("Sonarr",pid=...,fd=...))

# Desde el host: 8989 NO publicado.
ss -tnlp | grep ':8989'   # vacío (correcto)
```

Si `ss -tnlp | grep ':8989'` en el host devuelve algo, alguien añadió `ports: - "8989:8989"` al compose. Quitarlo y `docker compose up -d`.

### 8.3. Bibliotecas montadas y escribibles

```bash
docker exec sonarr ls -ld /config /downloads /downloads/complete /tv
# drwxr-x---  ... abc abc   ... /config        (homelab:homelab 750)
# drwxrwsr-x  ... abc users ... /downloads     (homelab:media 2775)
# drwxrwsr-x  ... abc users ... /downloads/complete
# drwxrwsr-x  ... abc users ... /tv            (homelab:media 2775)

# Smoke test de escritura en /tv (con setgid, debe heredar grupo media).
docker exec sonarr touch /tv/.smoke
docker exec sonarr ls -l /tv/.smoke
# -rw-rw-r-- 1 abc users ... .smoke   (group "users" = GID 1100 = "media" en host)
docker exec sonarr rm /tv/.smoke

# Smoke test de hardlink entre /downloads y /tv (mismo FS).
docker exec sonarr sh -c '
  mkdir -p /downloads/complete/.smoke
  echo test > /downloads/complete/.smoke/file.txt
  ln /downloads/complete/.smoke/file.txt /tv/.smoke-link
  ls -l /downloads/complete/.smoke/file.txt /tv/.smoke-link
'
# Esperado: ambos ficheros con el mismo número de inodo (columna después del modo)
# y nlink=2. Si se crea como copia (nlink=1, distinto inodo), hardlinks no funcionan
# — verificar que /downloads y /tv apuntan al mismo filesystem (df -T).

docker exec sonarr rm -rf /downloads/complete/.smoke /tv/.smoke-link
```

### 8.4. UI accesible vía Caddy

```bash
curl -ks https://sonarr.lan/ -o /dev/null -w '%{http_code}\n'
# 302    (redirect a Authelia)
```

Desde un navegador con la CA interna confiada:

1. `https://sonarr.lan` → redirect a Authelia.
2. Login + TOTP → redirect a Sonarr.
3. La UI de Sonarr carga con el banner "Sonarr Version 4.0.10.2544".

### 8.5. API operativa (autenticada)

```bash
docker run --rm --network homelab curlimages/curl:latest \
  -H "X-Api-Key: ${SONARR_API_KEY}" \
  http://sonarr:8989/api/v3/system/status \
  | jq '.version, .branch, .runtimeVersion'
# "4.0.10.2544"
# "main"
# "6.0.36"   (.NET 6 runtime)
```

Sin API key:

```bash
docker run --rm --network homelab curlimages/curl:latest \
  http://sonarr:8989/api/v3/system/status -o /dev/null -w '%{http_code}\n'
# 401   (correcto: la API exige X-Api-Key incluso con "Disabled for Local Addresses",
#        que solo desactiva el form-auth; X-Api-Key sigue siendo obligatorio).
```

### 8.6. Test del download client (Transmission)

```bash
docker run --rm --network homelab curlimages/curl:latest \
  -H "X-Api-Key: ${SONARR_API_KEY}" \
  -X POST http://sonarr:8989/api/v3/downloadclient/test \
  -H 'Content-Type: application/json' \
  --data-binary @- <<EOF
{
  "id": $(docker run --rm --network homelab curlimages/curl:latest \
    -s -H "X-Api-Key: ${SONARR_API_KEY}" \
    http://sonarr:8989/api/v3/downloadclient | jq '.[0].id')
}
EOF
# (HTTP 200 si OK; 400 con mensaje si falla)
```

O por la UI: `Settings → Download Clients → Transmission → Test`.

### 8.7. Smoke test: añadir una serie de prueba

Vía UI: `Series → [+] → Add New` → buscar una serie pequeña (p.ej. "Big Buck Bunny" no es una serie, pero "Pioneer One" o cualquier dominio público sirve como test sintético). Configurar:

- **Root Folder**: `/tv`.
- **Quality Profile**: `HD-1080p`.
- **Language Profile**: `Spanish/English`.
- **Series Type**: `Standard`.
- **Season Folder**: `Yes`.
- **Monitor**: `All Episodes`.
- **Search**: `Start search for missing episodes` (opcional).

Tras `Add Series`, Sonarr crea la carpeta `/mnt/hd2t/media/tv/<Show>/` y empieza a buscar episodios. Verificar:

```bash
ls -la /mnt/hd2t/media/tv/
# Debe aparecer la carpeta de la serie con owner homelab:media.
```

### 8.8. Persistencia tras reboot

```bash
sudo reboot
# (esperar)
ssh homelab@pi
docker compose -f ~/homelab/stacks/sonarr/docker-compose.yml ps
# sonarr   running (healthy)

# Series siguen registradas:
docker run --rm --network homelab curlimages/curl:latest \
  -H "X-Api-Key: ${SONARR_API_KEY}" \
  http://sonarr:8989/api/v3/series | jq '.[] | .title'
```

### 8.9. Lista de verificación

- [ ] Contenedor `sonarr` está `running (healthy)`.
- [ ] Puerto `8989` **no** está publicado en el host (`ss -tnlp | grep 8989` vacío).
- [ ] `https://sonarr.lan` redirige a Authelia, login con TOTP funciona, UI de Sonarr carga.
- [ ] API responde `200` con `X-Api-Key` correcta y `401` sin ella.
- [ ] Bind mounts `/config`, `/downloads`, `/tv` montados RW dentro del contenedor con permisos correctos (`homelab:media` 2775 en `/downloads` y `/tv`).
- [ ] Hardlink entre `/downloads/complete/<x>` y `/tv/<y>` funciona (nlink>=2 con mismo inodo).
- [ ] Download Client Transmission añadido y `Test` en verde.
- [ ] Root Folder `/tv` añadido y escribible.
- [ ] Indexadores propagados desde Prowlarr (lista no vacía).
- [ ] Notifications (Telegram o equivalente) configurado.
- [ ] `SONARR_API_KEY` está en `/mnt/hd2t/services/sonarr/.env` (chmod 600).
- [ ] Tras reboot, Sonarr arranca solo y las series siguen registradas.

---

## 9. Backup

### 9.1. Qué se respalda y qué no

| Ruta | Backup | Por qué |
|---|---|---|
| `/mnt/hd2t/services/sonarr/config/sonarr.db` | **Sí** (vía `sqlite3 .backup`) | BD principal: series, episodios monitorizados, history, quality profiles, indexers sincronizados, download client. Sin esto se pierde toda la biblioteca catalogada (los ficheros físicos en `/tv/` siguen ahí, pero hay que re-añadir cada serie y re-vincular cada episodio — horas de trabajo manual). |
| `/mnt/hd2t/services/sonarr/config/sonarr.db-shm` / `-wal` | No (parte del backup atómico) | Ficheros WAL de SQLite. `sqlite3 .backup` consolida WAL en `.db` antes de copiar. |
| `/mnt/hd2t/services/sonarr/config/config.xml` | **Sí** | API key, port, log level, branch. Recuperarlo permite que Prowlarr siga funcionando con la **misma** API key tras restore. Sin esto, hay que rotarla en los dos extremos. |
| `/mnt/hd2t/services/sonarr/config/Backups/*.zip` | **Sí** (regenerable, pero barato) | Backups internos de Sonarr. Borg los deduplica entre runs. ~5 MB cada uno × 4 = 20 MB. Gratis incluirlos. |
| `/mnt/hd2t/services/sonarr/config/MediaCover/` | No (regenerable) | Posters/thumbnails cacheados por serie. Sonarr los redescarga al detectar falta. ~2 MB por serie × 50 series = 100 MB; no merece backup. |
| `/mnt/hd2t/services/sonarr/config/MediaInfo/` | No (regenerable) | Cache de metadata extraída de los `.mkv`. Sonarr la regenera con `Refresh Series`. |
| `/mnt/hd2t/services/sonarr/config/logs/` | No (regenerable) | Logs operacionales. No tienen valor histórico fuera de debug puntual. |
| `/mnt/hd2t/services/sonarr/.env` | **Sí** (vía `/mnt/hd2t/backups/configs/`) | Contiene `SONARR_API_KEY` y `TRANSMISSION_RPC_PASSWORD`. Sin esto, hay que rotarlas y reconfigurar Prowlarr y Sonarr → Download Clients. |
| `/mnt/hd2t/media/tv/` | **Política aparte** | Ver [`../07-backups/01-estrategia-backup.md`](../07-backups/01-estrategia-backup.md). Por defecto **excluida** del backup primario por tamaño (cientos de GB de re-descargables). El operador puede activar backup parcial de "favoritas" con un patrón Borg explícito. |
| `/mnt/hd2t/media/tv/.recycle/` | No | Excluida explícitamente — son ficheros que el operador eligió borrar. |

### 9.2. Patrón Borgmatic — respaldo SQLite

Coherente con [`../07-backups/03-backup-docker-volumes.md`](../07-backups/03-backup-docker-volumes.md) §4.8 ("Servicios SQLite simples"). El hook pre-backup hace `sqlite3 sonarr.db ".backup '/tmp/sonarr.bak'"` para evitar copia inconsistente:

`~/homelab/stacks/borgmatic/borgmatic.d/sonarr.yaml` (o sección dentro del config global de Borgmatic):

```yaml
# Sección dentro del config global. Coherente con ../07-backups/03-backup-docker-volumes.md §4.8.

before_backup:
  - sudo -u homelab docker exec sonarr sh -c \
      'sqlite3 /config/sonarr.db ".backup /config/Backups/sonarr-prebackup.db"'

source_directories:
  # ... otras rutas ...
  - /mnt/hd2t/services/sonarr/config

# La BD viva (con WAL en uso) sigue siendo respaldada por el include genérico,
# pero Borg deduplica frente a la copia consistente de Backups/sonarr-prebackup.db.

exclude_patterns:
  - /mnt/hd2t/services/sonarr/config/logs
  - /mnt/hd2t/services/sonarr/config/MediaCover
  - /mnt/hd2t/services/sonarr/config/MediaInfo
  - /mnt/hd2t/media/tv/.recycle
```

### 9.3. Restore (resumen)

```bash
# 1. Parar el contenedor.
docker compose -f ~/homelab/stacks/sonarr/docker-compose.yml stop

# 2. Mover el config actual a un lado (por seguridad).
sudo mv /mnt/hd2t/services/sonarr/config /mnt/hd2t/services/sonarr/config.old

# 3. Restaurar /mnt/hd2t/services/sonarr/config/ desde Borg.
borgmatic extract --archive latest \
  --path /mnt/hd2t/services/sonarr/config \
  --destination /

# 4. Restaurar el .env.
borgmatic extract --archive latest \
  --path /mnt/hd2t/services/sonarr/.env \
  --destination /

# 5. Si la BD viva quedó corrupta tras el `mv`, restaurar la consistente:
sudo cp /mnt/hd2t/services/sonarr/config/Backups/sonarr-prebackup.db \
        /mnt/hd2t/services/sonarr/config/sonarr.db

# 6. Levantar de nuevo.
docker compose -f ~/homelab/stacks/sonarr/docker-compose.yml up -d

# 7. Verificar.
docker run --rm --network homelab curlimages/curl:latest \
  -H "X-Api-Key: ${SONARR_API_KEY}" \
  http://sonarr:8989/api/v3/series | jq 'length'
# Número esperado de series.

# 8. Borrar el config.old si todo OK.
sudo rm -rf /mnt/hd2t/services/sonarr/config.old
```

### 9.4. Smoke test mensual de restore

```bash
sudo rm -rf /tmp/restore_test
mkdir -p /tmp/restore_test
borgmatic extract --archive latest \
  --path /mnt/hd2t/services/sonarr/config \
  --destination /tmp/restore_test

# Verificar que sonarr.db es válida sin levantarla en producción:
sqlite3 /tmp/restore_test/mnt/hd2t/services/sonarr/config/sonarr.db \
  "SELECT count(*) FROM Series;"
# > 0   (al menos una serie)

sqlite3 /tmp/restore_test/mnt/hd2t/services/sonarr/config/sonarr.db \
  "SELECT count(*) FROM Episodes WHERE EpisodeFileId > 0;"
# Número de episodios con fichero importado.

# Verificar config.xml:
grep '<ApiKey>' /tmp/restore_test/mnt/hd2t/services/sonarr/config/config.xml
# <ApiKey>...</ApiKey>

sudo rm -rf /tmp/restore_test
```

---

## 10. Operaciones cotidianas

### 10.1. Upgrade automático (Watchtower)

Política en [`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md): Watchtower revisa `lscr.io/linuxserver/sonarr:4.0.10.2544-ls248` cada noche, compara digest de ese tag exacto y actualiza si LSIO ha re-publicado el tag (típicamente cuando hay un patch de seguridad del *base image*). Si el operador quiere saltar a `4.0.11.x`, edita `SONARR_IMAGE_TAG` en `.env`, hace `docker compose pull && docker compose up -d` y revisa logs por si hubiera migración. Sonarr 4.x es compatible hacia delante; el `sonarr.db` no rompe.

```bash
# Lista de upgrades aplicados por Watchtower:
docker logs watchtower 2>&1 | grep -i sonarr | tail -20
```

### 10.2. Añadir una serie nueva

UI: `Series → [+] → Add New` → buscar título → seleccionar → configurar (Quality Profile, Language Profile, Monitor) → `Add Series`.

Por API (útil para scripts):

```bash
# Buscar el TVDB ID de la serie:
docker run --rm --network homelab curlimages/curl:latest \
  -H "X-Api-Key: ${SONARR_API_KEY}" \
  "http://sonarr:8989/api/v3/series/lookup?term=Breaking+Bad" \
  | jq '.[0] | {title, tvdbId, year}'
# {"title":"Breaking Bad","tvdbId":81189,"year":2008}

# Añadir la serie:
docker run --rm --network homelab curlimages/curl:latest \
  -H "X-Api-Key: ${SONARR_API_KEY}" \
  -H 'Content-Type: application/json' \
  -X POST http://sonarr:8989/api/v3/series \
  --data-binary @- <<'EOF'
{
  "tvdbId": 81189,
  "title": "Breaking Bad",
  "qualityProfileId": 1,
  "languageProfileId": 1,
  "rootFolderPath": "/tv",
  "monitored": true,
  "addOptions": {"searchForMissingEpisodes": true}
}
EOF
```

### 10.3. Buscar manualmente un episodio que no llega

Cuando un episodio no se descarga automáticamente (RSS Sync no encontró release adecuado):

```
Series → [serie] → Season XX → click episodio → Manual Search

Sonarr lista todas las releases disponibles desde los indexadores activos
con su score (calidad + custom formats).
Click "Download" en la release deseada.
```

Por API:

```bash
# Buscar un episodio (Manual Search):
docker run --rm --network homelab curlimages/curl:latest \
  -H "X-Api-Key: ${SONARR_API_KEY}" \
  "http://sonarr:8989/api/v3/release?episodeId=12345" \
  | jq '.[] | {title, indexer, size, seeders, customFormats: [.customFormats[].name]}'

# Trigger una búsqueda automática del episodio:
docker run --rm --network homelab curlimages/curl:latest \
  -H "X-Api-Key: ${SONARR_API_KEY}" \
  -X POST http://sonarr:8989/api/v3/command \
  -H 'Content-Type: application/json' \
  -d '{"name":"EpisodeSearch","episodeIds":[12345]}'
```

### 10.4. Importar manualmente un fichero ya descargado (Library Import)

Si el operador tiene episodios fuera del control de Sonarr (descargados a mano, comprados en BD):

```
1. Copiar los ficheros a /mnt/hd2t/media/tv/<Show>/Season XX/
   (o al directorio donde Sonarr ya tenga la serie, o a /tv/ a pelo).

2. UI → Wanted → Manual Import → seleccionar carpeta → Sonarr identifica
   los episodios por nombre + fingerprint y los enlaza.

3. Si el reconocimiento es ambiguo, ajustar manualmente la serie/temporada/episodio.

4. Click "Import" → Sonarr renombra y mueve.
```

### 10.5. Corregir un episodio mal nombrado o mal importado

```
Series → [serie] → Season XX → click episodio → ver "File"

- Si el fichero tiene mal nombre: click "Rename" → Sonarr aplica el formato.
- Si el fichero está mal mapeado a otro episodio: borrar el File desde la UI,
  re-importar manualmente con "Manual Import".
- Si el episodio entero no existe en TheTVDB (ep especial sin metadatos):
  añadirlo manualmente en TheTVDB (requiere cuenta y revisión del staff).
```

### 10.6. Rotar la API key o la password de Transmission RPC

Cuando el operador sospeche compromiso:

#### 10.6.1. Rotar `SONARR_API_KEY`

```
UI → Settings → General → Security → API Key → [Reset] → Save → Reload
```

Tras esto:

1. Prowlarr **fallará** al sincronizar hasta que el operador actualice `Prowlarr → Apps → Sonarr → ApiKey`.
2. Bazarr (si está) idem.
3. Leer la nueva key del `config.xml` y actualizar el `.env`:

```bash
NEW_KEY=$(sudo grep '<ApiKey>' /mnt/hd2t/services/sonarr/config/config.xml \
  | sed -E 's,.*<ApiKey>([^<]+)</ApiKey>.*,\1,')
sudo sed -i \
  -e "s|^SONARR_API_KEY=.*|SONARR_API_KEY=${NEW_KEY}|" \
  /mnt/hd2t/services/sonarr/.env
```

4. Actualizar Prowlarr → Apps → Sonarr → ApiKey con `NEW_KEY`. Reiniciar Prowlarr para descartar caches: `docker compose restart prowlarr`.

#### 10.6.2. Rotar `TRANSMISSION_RPC_PASSWORD`

Si se rota la password de Transmission ([`./01-transmission.md`](./01-transmission.md) §10.6):

1. Actualizar el `.env` de Sonarr:

```bash
NEW_TRPC_PASS=$(sudo grep '^TRANSMISSION_RPC_PASSWORD=' \
  /mnt/hd2t/services/transmission/.env | cut -d= -f2-)
sudo sed -i \
  -e "s|^TRANSMISSION_RPC_PASSWORD=.*|TRANSMISSION_RPC_PASSWORD=${NEW_TRPC_PASS}|" \
  /mnt/hd2t/services/sonarr/.env
```

2. Actualizar la password en la UI de Sonarr: `Settings → Download Clients → Transmission → Password` → pegar nueva → `Test → Save`. (Sonarr **no** lee `TRANSMISSION_RPC_PASSWORD` del env directamente; solo de la BD `sonarr.db`.)

### 10.7. Library Import inicial (cuando se llega con biblioteca preexistente)

Si el operador despliega Sonarr con `/mnt/hd2t/media/tv/` ya poblado (de un homelab anterior, descargas manuales, ripeos):

```
UI → Wanted → Manual Import → seleccionar /tv/

Sonarr escanea, identifica cada carpeta de serie, busca en TheTVDB,
y propone las series detectadas con sus episodios.

Click "Import All" tras revisar.
```

Tras el import inicial, Sonarr empieza a monitorizar episodios faltantes y a descargar lo que encuentre. Recomendación: revisar la History en los primeros días para detectar series mal identificadas.

### 10.8. Mass Editor — cambiar Quality Profile en bloque

```
UI → Series → Mass Editor

Seleccionar series → cambiar Quality Profile / Language Profile / Monitor /
Root Folder en bloque → Apply.
```

Útil cuando se decide cambiar de 720p a 1080p para toda la biblioteca: `Mass Editor → seleccionar todas → Quality Profile: HD-1080p → Apply`. Sonarr empezará a buscar upgrades para los episodios ya descargados.

### 10.9. Logs

```bash
# En vivo:
docker logs -f sonarr

# Logs persistidos en /config/logs/:
docker exec sonarr ls -lh /config/logs/
# sonarr.txt           (log actual)
# sonarr.txt.0         (último rotado)
# sonarr.debug.txt     (si Log Level >= Debug)
# update.txt           (log de upgrades internos, irrelevante en Docker)
```

LSIO redirige los logs internos al stdout del contenedor, donde Docker los captura y Dozzle los muestra. No hace falta tocar `/config/logs/` salvo para grep histórico.

### 10.10. Comportamiento durante mantenimiento

- **Pi-hole caído**: Sonarr no resuelve dominios externos (TheTVDB, Skyhook), las búsquedas de metadata fallan. **No corrompe nada**: las búsquedas vuelven al recuperar Pi-hole.
- **Caddy caído**: la UI no es accesible, pero **Sonarr sigue funcionando**: descarga, importa y notifica. Prowlarr sigue sincronizando porque va por la red interna `homelab`.
- **Prowlarr caído**: Sonarr **no puede buscar nuevos episodios** (no tiene indexadores activos). Las descargas en curso y los imports siguen.
- **Transmission caído**: Sonarr **no puede enviar nuevas descargas** ("Unable to connect to Transmission" en la History). Episodios marcados como "Wanted" se quedan en cola; al recuperar Transmission, RSS Sync los retoma.
- **`sonarr.db` corrupta** (raro pero posible si el host pierde corriente sin parar limpio): Sonarr se niega a arrancar con `Malformed database`. Restaurar desde `/config/Backups/sonarr-prebackup.db` (§9.3 paso 5).

---

## 11. Solución de Problemas

| Síntoma | Causa probable | Diagnóstico / Fix |
|---|---|---|
| `https://sonarr.lan` muestra "502 Bad Gateway" en Caddy | Contenedor Sonarr caído o `unhealthy`. | `docker compose ps`, `docker logs sonarr`. |
| Authelia no aparece al ir a `sonarr.lan`; va directo al login de Forms | El bloque `forward_auth` no está en el `Caddyfile`, o Caddy no se recargó. | Verificar `~/homelab/stacks/proxy/Caddyfile` §6.1, recargar `docker exec proxy caddy reload --config /etc/caddy/Caddyfile`. |
| Tras login Authelia, la UI de Sonarr pide login de Forms | La cookie de Forms no se ha establecido aún. Hacer login una vez y luego la cachea 30 días. | Normal en el primer acceso. Si persiste tras hacer login: comprobar que el dominio del cookie es `sonarr.lan` y que el navegador acepta cookies. |
| Prowlarr no puede sincronizar con Sonarr ("Unable to connect") | API key mal configurada en Prowlarr → Apps, o `Trusted Proxies` no incluye `172.20.0.0/24`. | `docker exec prowlarr curl -H "X-Api-Key: $SONARR_API_KEY" http://sonarr:8989/api/v3/system/status`. Si devuelve 200, la conexión es OK; si 401, la key está mal. |
| `Settings → Download Clients → Test` falla con "Unable to connect" | Transmission no está corriendo o no está en la red `homelab`. | `docker network inspect homelab` debe listar tanto `sonarr` como `transmission`. Si no, verificar `networks: [homelab]` en ambos compose. |
| `Settings → Download Clients → Test` falla con "Unauthorized" | Password RPC mal copiada. | Comparar `TRANSMISSION_RPC_PASSWORD` en `/mnt/hd2t/services/transmission/.env` y la password introducida en la UI de Sonarr (Settings → Download Clients → Transmission). |
| Episodios descargan pero no se importan ("Unable to import: file is locked") | Transmission sigue seedeando con el fichero abierto, y Sonarr intenta hacer `cp` (no hardlink). Indica que Hardlinks están desactivados o que `/downloads` y `/tv` están en filesystems distintos. | UI → Settings → Media Management → `Use Hardlinks instead of Copy` = `Yes`. Verificar `df -T /mnt/hd2t/downloads /mnt/hd2t/media/tv` muestra el mismo `Filesystem`. |
| Episodios descargan pero se duplica el espacio | Hardlinks desactivados. | Mismo fix que el anterior. Para los ya duplicados: borrar manualmente desde `complete/` (con cuidado de no romper torrents activos). |
| Sonarr renombra a `Show.S01E01.mkv` (no aplica el formato Plex) | `Rename Episodes = No` en Settings → Media Management. | Cambiar a `Yes`, luego `Series → Mass Editor → Rename Files` para los ya importados. |
| Imports fallan con "Permission denied" en `/tv/` | El bit `setgid` de `/mnt/hd2t/media/tv/` se perdió, o un fichero fue creado por otro UID/GID antes de configurar `setgid`. | `sudo chmod 2775 /mnt/hd2t/media/tv` y `sudo chgrp -R media /mnt/hd2t/media/tv` para arreglar lo existente. |
| Sonarr ocupa > 1.5 GB de RAM | Mass Editor con cientos de series, o RSS Sync de una biblioteca enorme. | `docker compose restart sonarr`. Si recurre, subir `mem_limit` a `2048m`. |
| `database is locked` en logs al arrancar | Otro Sonarr antiguo no parado, o un `sqlite3` interactivo abierto. | `docker compose down`, `lsof /mnt/hd2t/services/sonarr/config/sonarr.db` para ver quién la abre, matar ese proceso, `docker compose up -d`. |
| `Malformed database` en logs | Corrupción de `sonarr.db` (típicamente tras un kill -9 o un corte de luz). | Restaurar desde `/config/Backups/sonarr-prebackup.db` (§9.3 paso 5) o desde Borg. |
| RSS Sync no encuentra nada aunque hay episodios disponibles | Quality Profile demasiado restrictivo (solo `Bluray-1080p`, no hay), o Custom Formats con score muy negativo. | UI → Wanted → Missing → click episodio → Manual Search. Comparar releases ofrecidas vs Quality Profile activo. |
| Tras un `docker compose down && up`, las series aparecen pero sin episodios | El bind mount de `/config` no es correcto o el `chown` del entrypoint LSIO no terminó antes del crash. | Verificar `docker exec sonarr ls -la /config/` que muestra `sonarr.db` con owner `abc:abc` (UID 1000, GID 1100). Si está como `root:root`, el contenedor no tuvo permisos para `chown` (revisar `/mnt/hd2t/services/sonarr/config/` en el host: debe ser `homelab:homelab 750`). |
| `config.xml` tiene `<ApiKey></ApiKey>` vacío tras un restore | El restore vino de un backup antes del primer arranque. | Levantar Sonarr (regenera la API key). Leer la nueva, actualizar `.env`. Si Prowlarr/Bazarr ya estaban configurados con la antigua, rotar también allí. |
| "Health Issue: No indexers available with RSS sync enabled" | Sonarr no tiene indexadores. | Verificar que Prowlarr está corriendo y registrado en `Prowlarr → Apps → Sonarr` (§7.10). Forzar sync desde Prowlarr UI. |
| "Health Issue: Download client is set to remove completed downloads" | Transmission borra los torrents al terminar (incompatible con hardlinks: el .torrent se va antes de que Sonarr importe). | UI → Sonarr → Settings → Download Clients → Transmission → `Remove Completed`: `No`. Sonarr gestiona el ciclo de vida (mueve a `.recycle/` cuando ya no se necesita). |
| "Health Issue: Branch is for a different app" | El operador cambió `Branch` a `develop` y descargó la build de develop, pero en Docker el branch lo gestiona LSIO. | Settings → General → Updates → Branch: `main`. |

---

## 12. Variantes opt-in

### 12.1. Bazarr — subtítulos automáticos

**Bazarr** complementa a Sonarr/Radarr buscando subtítulos en OpenSubtitles, Subscene, Addic7ed, etc. para las series ya descargadas. **No es parte del MVP** del homelab; se documenta aquí por ser la integración natural más común.

`~/homelab/stacks/sonarr/docker-compose.yml`, **añadir** un servicio extra (o crear un stack `~/homelab/stacks/bazarr/` aparte):

```yaml
services:
  sonarr:
    # ... igual que en §4 ...

  bazarr:
    image: lscr.io/linuxserver/bazarr:1.4.4-ls294
    container_name: bazarr
    hostname: bazarr
    restart: unless-stopped
    environment:
      PUID: ${HOMELAB_UID}
      PGID: ${MEDIA_GID}
      TZ: ${TZ}
      UMASK_SET: "002"
    volumes:
      - /mnt/hd2t/services/bazarr/config:/config
      - /mnt/hd2t/media/tv:/tv
      - /mnt/hd2t/media/movies:/movies   # también para Radarr
      - /etc/localtime:/etc/localtime:ro
    networks:
      - homelab
    mem_limit: 768m
    healthcheck:
      test: ["CMD-SHELL", "curl -fsS http://localhost:6767/ || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 60s
    labels:
      com.centurylinklabs.watchtower.enable: "true"
      dev.dozzle.group: "arr"
```

Configuración Bazarr post-deploy: `Settings → Sonarr → Address: sonarr, Port: 8989, API Key: ${SONARR_API_KEY}`. Análogo para Radarr.

Caddy: añadir bloque `bazarr.{$LAN_DOMAIN}` con `forward_auth` a Authelia (mismo patrón que §6.1).

### 12.2. Múltiples instancias (Sonarr 4K, Sonarr Anime)

El patrón "*arr stack split" usa **dos Sonarr en paralelo**: uno para `HD-1080p` (estándar) y otro para `2160p` (4K), cada uno con su propia BD y Quality Profile. Ventaja: separar bibliotecas evita re-descargar 4K cuando el operador solo quería 1080p. Desventaja: doble RAM, doble mantenimiento.

Stack alternativo:

```yaml
services:
  sonarr-4k:
    image: lscr.io/linuxserver/sonarr:${SONARR_IMAGE_TAG}
    container_name: sonarr-4k
    hostname: sonarr-4k
    # ... igual que sonarr, pero con:
    volumes:
      - /mnt/hd2t/services/sonarr-4k/config:/config
      - /mnt/hd2t/downloads:/downloads
      - /mnt/hd2t/media/tv-4k:/tv   # biblioteca aparte
      - /etc/localtime:/etc/localtime:ro
```

Caddy: `sonarr-4k.{$LAN_DOMAIN}`. Prowlarr → Apps → registrar las dos instancias con tags distintos (`tv-sonarr-1080p`, `tv-sonarr-4k`) para que Prowlarr filtre indexadores 4K-only solo a `sonarr-4k`.

**No por defecto** porque la mayoría de operadores se conforman con un Quality Profile que tolere 1080p y 4K en la misma serie según disponibilidad.

Para anime (con numeración absoluta) la práctica habitual es registrar las series como `Series Type: Anime` en la **misma** instancia de Sonarr (Sonarr maneja los dos tipos en paralelo) y usar Custom Formats / tags de Prowlarr para filtrar indexadores anime-only (Nyaa) a esas series.

### 12.3. Custom Formats avanzadas (Atmos, IMAX Enhanced, HDR matrix)

El catálogo público [TRaSH-Guides](https://trash-guides.info/Sonarr/) define un set de Custom Formats curado por la comunidad para escenarios específicos:

- "Atmos / TrueHD" — preferir audio Dolby Atmos.
- "IMAX Enhanced" — preferir versiones IMAX.
- "Hybrid" / "Repack" / "Proper" — preferir versiones corregidas.

Importarlas:

```
UI → Settings → Custom Formats → Import → pegar el JSON de TRaSH-Guides.
```

Asignarlas a Quality Profiles con scores positivos (preferir) o negativos (penalizar).

Recomendación: empezar con HD-1080p simple, dejar que el operador rode el stack 1-2 meses y luego importar Custom Formats avanzadas según necesidad real.

### 12.4. Permitir API directa (apps móviles) sin Authelia

Si el operador usa nzb360 / Sonarr Companion / LunaSea desde el móvil con la URL Tailscale (`sonarr.${TS_DOMAIN}`), Authelia delante rompe la app móvil (las apps no manejan el cookie SSO). Solución: permitir `/api/...` y `/ping` sin Authelia, mantener la UI con Authelia:

`Caddyfile`:

```caddy
sonarr.{$TS_DOMAIN} {
    import tailscale_tls sonarr
    import security_headers

    # API y ping: sin Authelia. Sonarr exige X-Api-Key igualmente.
    @api path /api/* /ping
    handle @api {
        reverse_proxy http://sonarr:8989 {
            header_up X-Forwarded-Proto https
            header_up X-Real-IP {remote_host}
        }
    }

    # Resto: con Authelia.
    handle {
        forward_auth http://authelia:9091 {
            uri /api/authz/forward-auth
            copy_headers Remote-User Remote-Groups Remote-Name Remote-Email
        }
        reverse_proxy http://sonarr:8989 {
            header_up X-Forwarded-Proto https
            header_up X-Real-IP {remote_host}
        }
    }
}
```

**Análisis de seguridad**: la API key de Sonarr es de 32 chars hex (~128 bits de entropía). Sin lockout, un atacante podría intentar fuerza bruta — pero a 1000 reqs/seg necesitaría 10^33 años. Es seguro en la práctica.

**Limitaciones**: la app móvil debe configurarse con la API key directamente. Si el operador rota la API key (§10.6), hay que actualizarla en cada app.

### 12.5. Notificaciones avanzadas a Telegram con Custom Script

Para granularidad mayor que las notifications nativas:

`Settings → Connect → [+] → Custom Script`:

```bash
sudo install -d -o homelab -g homelab -m 750 \
  /mnt/hd2t/services/sonarr/config/scripts

sudo tee /mnt/hd2t/services/sonarr/config/scripts/notify-telegram.sh > /dev/null <<'EOF'
#!/bin/sh
# Variables expuestas por Sonarr:
#   sonarr_eventtype, sonarr_series_title, sonarr_episodefile_episodetitles,
#   sonarr_episodefile_seasonnumber, sonarr_episodefile_episodenumbers, ...
case "$sonarr_eventtype" in
  Download|Upgrade)
    TG_BOT="${TELEGRAM_BOT_TOKEN}"
    TG_CHAT="${TELEGRAM_CHAT_ID}"
    MSG="📺 Sonarr: ${sonarr_series_title} S${sonarr_episodefile_seasonnumber}E${sonarr_episodefile_episodenumbers} importado"
    curl -s -X POST "https://api.telegram.org/bot${TG_BOT}/sendMessage" \
      -d chat_id="${TG_CHAT}" \
      -d text="${MSG}"
    ;;
  HealthIssue)
    TG_BOT="${TELEGRAM_BOT_TOKEN}"
    TG_CHAT="${TELEGRAM_CHAT_ID}"
    curl -s -X POST "https://api.telegram.org/bot${TG_BOT}/sendMessage" \
      -d chat_id="${TG_CHAT}" \
      -d text="⚠️ Sonarr: ${sonarr_health_issue_message}"
    ;;
esac
EOF
sudo chmod +x /mnt/hd2t/services/sonarr/config/scripts/notify-telegram.sh
```

Luego en la UI: `Connect → Custom Script → /config/scripts/notify-telegram.sh`. Triggers: `On Import`, `On Upgrade`, `On Health Issue`.

### 12.6. Quitar Authelia para uso solo en LAN cableada confiada

No recomendado. Si el operador insiste:

```caddy
sonarr.{$LAN_DOMAIN} {
    import lan_internal_tls
    import security_headers
    # forward_auth http://authelia:9091 ...   ← comentado
    reverse_proxy http://sonarr:8989
}
```

La auth nativa de Forms queda como única defensa. Tiene rate-limit interno pero carece de 2FA. Por eso Authelia es el default.

### 12.7. Acceso solo desde Tailscale (sin LAN)

Si el operador no quiere `sonarr.lan` accesible en LAN (modelo "trabajo solo desde Tailscale"), eliminar el bloque `sonarr.{$LAN_DOMAIN}` del `Caddyfile` y dejar solo el de Tailscale (§6.6). El stack interno sigue funcionando (Prowlarr lo ve por nombre).

### 12.8. Importar quality profiles de TRaSH-Guides

[TRaSH-Guides](https://trash-guides.info/Sonarr/) ofrece configuraciones tuneadas (Custom Formats + Quality Profiles + Naming) para escenarios específicos. La forma "ninja" de aplicarlas es vía [recyclarr](https://github.com/recyclarr/recyclarr), un sidecar que sincroniza la BD de Sonarr con un YAML versionable:

```yaml
# ~/homelab/stacks/recyclarr/recyclarr.yml
sonarr:
  homelab:
    base_url: http://sonarr:8989
    api_key: !env_var SONARR_API_KEY
    quality_definition:
      type: series
    custom_formats:
      - trash_ids:
          - 32b367365729d530ca1c124a0b180c64   # Bad Dual Groups
          - 82d40da2bc6923f41e14394075dd4b03   # No-RlsGroup
        quality_profiles:
          - name: HD-1080p
            score: -10000
```

`recyclarr sync` (cron diario) mantiene Sonarr alineado con el YAML. **No por defecto** porque añade complejidad operativa: requiere otro contenedor, gestionar el `recyclarr.yml`, y entender la sintaxis TRaSH. Útil para operadores avanzados que quieran configuraciones reproducibles cross-instance.

---

## Referencias

- Documentación oficial Servarr (Sonarr): https://wiki.servarr.com/sonarr
- Repositorio Sonarr: https://github.com/Sonarr/Sonarr
- Releases upstream: https://github.com/Sonarr/Sonarr/releases
- Imagen LinuxServer.io: https://docs.linuxserver.io/images/docker-sonarr/
- Releases LSIO: https://github.com/linuxserver/docker-sonarr/releases
- API v3 (especificación): https://sonarr.tv/docs/api/
- TRaSH-Guides (Custom Formats curados): https://trash-guides.info/Sonarr/
- recyclarr (sync de TRaSH-Guides): https://github.com/recyclarr/recyclarr
- Bazarr (subtítulos): https://github.com/morpheus65535/bazarr
- Watchtower (política del homelab): [`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md)
- Caddy (reverse proxy): [`../03-red/04-caddy.md`](../03-red/04-caddy.md)
- Authelia (SSO + 2FA): [`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md)
- Borgmatic (backup): [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md)
- Backup Docker volumes (SQLite): [`../07-backups/03-backup-docker-volumes.md`](../07-backups/03-backup-docker-volumes.md)
- Estructura de directorios: [`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md)
- Transmission (cliente BitTorrent): [`./01-transmission.md`](./01-transmission.md)
- Prowlarr (indexadores): [`./02-prowlarr.md`](./02-prowlarr.md)
- Radarr (películas): [`./04-radarr.md`](./04-radarr.md)
- Jellyfin (reproductor): [`../09-multimedia/01-jellyfin.md`](../09-multimedia/01-jellyfin.md)
