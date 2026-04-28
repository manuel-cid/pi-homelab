# Radarr

## Descripción

Despliegue de **Radarr v5** ([imagen `lscr.io/linuxserver/radarr`](https://docs.linuxserver.io/images/docker-radarr/)) como **PVR de películas** del homelab. Es la cuarta y última pieza de la **Fase 10 — Gestión de Descargas** y el **gemelo de Sonarr** ([`./03-sonarr.md`](./03-sonarr.md)) para cine: Radarr toma indexadores de **Prowlarr** ([`./02-prowlarr.md`](./02-prowlarr.md)), busca películas faltantes (o monitoriza estrenos próximos), envía el `.torrent`/`magnet:` a **Transmission** ([`./01-transmission.md`](./01-transmission.md)) y, cuando la descarga termina, **mueve/hardlinka** el fichero desde `/mnt/hd2t/downloads/complete/` a `/mnt/hd2t/media/movies/<Title> (Year)/<Title> (Year) [Quality].<ext>`, con renombrado consistente para que **Jellyfin** ([`../09-multimedia/01-jellyfin.md`](../09-multimedia/01-jellyfin.md)) las identifique sin reglas custom.

Este doc cubre, en orden:

1. **Por qué Radarr v5** y no Radarr v3 / CouchPotato / Watcher, qué se asume y qué se descarta.
2. **Plan de variables y archivos**: `.env.example` versionable, `.env` real con la `API key` (autogenerada por Radarr en el primer arranque) y las credenciales RPC de Transmission en `/mnt/hd2t/services/radarr/.env` (chmod 600), layout de directorios bajo `/mnt/hd2t/services/radarr/`.
3. **`docker-compose.yml`** con bind mounts de `/config` (respaldable), `/downloads` (RW, apuntando a `/mnt/hd2t/downloads/`) y `/movies` (RW, apuntando a `/mnt/hd2t/media/movies/`), `networks: [homelab]`, **sin** publicar el puerto `7878` (Caddy llega por DNS interno).
4. **Despliegue, onboarding inicial** (recoger la `API key` de `config.xml`, configurar `Authentication = Forms`, password fuerte).
5. **Integración con Caddy** ([`../03-red/04-caddy.md`](../03-red/04-caddy.md) §4.3): bloque `radarr.{$LAN_DOMAIN}` con `forward_auth` a Authelia (`radarr.{$LAN_DOMAIN}` ya está reservado en [`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md) §4 — política `two_factor`, `group:admin`).
6. **Configuración del proceso**: añadir Root Folder `/movies`, Download Client Transmission con categoría `movies-radarr`, Quality Profiles (HD-1080p, UHD-2160p, HD-720p), Custom Formats opcionales (preferir x265, evitar HDR si la TV no lo soporta, preferir IMAX/Atmos), Naming (formato Plex/Jellyfin estándar), Media Management (hardlinks **on**, recycle bin habilitado).
7. **Sincronización con Prowlarr**: registrar Radarr en Prowlarr → Apps (visto al revés en [`./02-prowlarr.md`](./02-prowlarr.md) §7.4); los indexadores aparecen en Radarr automáticamente.
8. **Backup**: `/config/radarr.db` (SQLite, vía `sqlite3 .backup`) + `/config/config.xml` (la API key vive ahí) + `/config/Backups/` propios de Radarr; `logs/`, `MediaCover/`, `MediaInfo/` excluidos por regenerables. Política coherente con [`../07-backups/03-backup-docker-volumes.md`](../07-backups/03-backup-docker-volumes.md) §4.8.
9. **Operaciones cotidianas**: añadir una película nueva, monitorizar próximos estrenos (Coming Soon), manejar películas que no llegan (Manual Search), gestión de la History, importación manual de un fichero existente (`Library Import`), corregir una película mal nombrada, subir un nivel de calidad sin reimportar, listas (Lists) de IMDb/TMDb/Trakt.
10. **Variantes opt-in**: **bazarr** sidecar para subtítulos automáticos (compartido con Sonarr), Atmos/IMAX Enhanced en Custom Formats, integración con Notifiarr/Telegram, hardlinks en cross-fs (no aplica aquí pero documentado), múltiples instancias (Radarr 4K aparte) con `Radarr.Anime` para anime cinematográfico, importación de TRaSH-Guides vía recyclarr.

> **Alcance de red**: la **UI web** (7878) **solo se accede vía Caddy** sobre `https://radarr.lan` (LAN) o `https://radarr.${TS_DOMAIN}` (Tailscale). **No hay puerto publicado al host.** Radarr **no necesita conexiones entrantes** desde internet — solo hace **salientes** a Prowlarr (para sincronizar y buscar), a Transmission (para enviar torrents y consultar estado) y a TMDb (para metadatos). Es del mismo perfil "tranquilo" de red que Prowlarr y Sonarr.

> **Diferencia con Transmission**: en [`./01-transmission.md`](./01-transmission.md) se abrió `51413/tcp+udp` en el router para BitTorrent P2P. **Radarr no abre nada**: solo HTTPS saliente y HTTP a `transmission:9091` por la red interna. Si el operador quitó incluso ese único port forward, Radarr funciona igual; solo Transmission se vería degradado.

> **Diferencia con Sonarr**: el modelo es **idéntico** salvo por el dominio (películas vs series), el puerto (7878 vs 8989), la categoría en Transmission (`movies-radarr` vs `tv-sonarr`), la biblioteca destino (`/mnt/hd2t/media/movies/` vs `/mnt/hd2t/media/tv/`) y la fuente de metadatos (TMDb vs TheTVDB). Los demás patrones (red, auth, Caddy, Authelia, hardlinks, backup) son los mismos. Cuando este doc dice "ver §X de Sonarr", la justificación es literalmente la misma.

---

## Requisitos Previos

- **Sistema base operativo** según Fase 1: usuario `homelab` (UID 1000), grupo `media` (GID 1100) con `homelab` como miembro, `/mnt/hd2t/` montado, directorio `/mnt/hd2t/services/radarr/` ya creado por el bootstrap de [`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) §4 (loop "Fase 10 — Descargas") y `/mnt/hd2t/media/movies/` con grupo `media` y bit `setgid` (ídem §6).
- **Docker + red `homelab`** según Fase 2: red bridge `homelab` creada, convenciones de Compose ([`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §3.5 — bind mounts; §4.3 — red compartida; §5.2 — `PUID=1000`/`PGID=1100` para acceso al grupo `media`).
- **Caddy desplegado** ([`../03-red/04-caddy.md`](../03-red/04-caddy.md)) con `lan_internal_tls` operativo y la red `homelab` accesible. Sin Caddy no hay HTTPS para la UI de Radarr y el `forward_auth` de Authelia no aplica.
- **Pi-hole desplegado** ([`../03-red/02-pihole.md`](../03-red/02-pihole.md)) con la posibilidad de añadir registros A locales (`radarr.lan` → IP de la Pi).
- **Authelia desplegado** ([`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md)) con el dominio `radarr.{$LAN_DOMAIN}` ya registrado en `access_control.rules` (política `two_factor`, `subject: group:admin`). En el `Caddyfile` el bloque de Radarr usa `forward_auth http://authelia:9091`.
- **Transmission desplegado** ([`./01-transmission.md`](./01-transmission.md)) con `rpc-username`/`rpc-password` en `.env`, `download-dir: /downloads/complete`, accesible desde la red `homelab` por nombre `transmission:9091` con URL base `/transmission/`. Radarr **no funciona** sin un download client al que enviar los torrents.
- **Prowlarr desplegado** ([`./02-prowlarr.md`](./02-prowlarr.md)) con al menos un indexador testeado en verde. Radarr **sí** puede arrancar sin Prowlarr (lo hará en cualquier caso — es desacoplado), pero el flujo de búsqueda fallará hasta que Prowlarr le inyecte indexadores vía Sync App.
- **Sonarr desplegado** ([`./03-sonarr.md`](./03-sonarr.md)) — **no es estrictamente requisito**, pero la convención del *arr stack es desplegarlos en este orden (Transmission → Prowlarr → Sonarr → Radarr) para que Prowlarr tenga ya un consumidor antes de añadir el segundo. Si el operador solo quiere cine (sin TV), Radarr puede ir antes que Sonarr sin más adaptaciones.
- **Watchtower desplegado** ([`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md)). Radarr lleva la etiqueta `com.centurylinklabs.watchtower.enable: "true"` por política — la imagen LSIO publica `latest` con cambios menores y la BD SQLite de Radarr (`/config/radarr.db`) es **forward-compatible** entre versiones (Radarr corre migraciones automáticamente al subir; un downgrade puede romper, pero no se hace nunca).
- **Borgmatic operativo** ([`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md)) para que `/mnt/hd2t/services/radarr/config/` sea archivado. Radarr cae en la sección **§4.8 (servicios SQLite simples)** del doc de Borgmatic y el patrón de [`../07-backups/03-backup-docker-volumes.md`](../07-backups/03-backup-docker-volumes.md) §4.8 (uso de `sqlite3 .backup` para evitar copia inconsistente).
- **Disco hd2t libre**: ~150 MB para `/mnt/hd2t/services/radarr/config/` (la BD crece con el tamaño de la biblioteca: ~5 KB por película + posters/fanart cacheados ~5 MB por película + logs rotados ~50 MB; menos que Sonarr porque hay menos "items" — una película es atómica, una serie tiene muchos episodios). El consumo "real" lo absorben las películas en `/mnt/hd2t/media/movies/`, que se contabiliza por separado en [`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md).
- **Cuentas en TheMovieDB (TMDb)**: **no necesarias para Radarr nativo**. Radarr v5 usa Skyhook (proxy oficial Servarr a TMDb) sin API key del usuario. Si en el futuro el operador quiere usar las **Lists** de TMDb (importar la lista "favoritos" del usuario) sí necesitará crear una cuenta TMDb gratis y enchufar la API key — opt-in (§10.10).

### Decisiones de diseño asumidas

| Decisión | Valor por defecto | Justificación |
|---|---|---|
| PVR de cine | **Radarr** v5 | Es el estándar *arr para películas desde 2018. CouchPotato lleva años abandonado, Watcher3 nunca despegó, FilmKodi es Kodi-céntrico. Radarr v5 es .NET 6 (vs v3 mono), arranca en ~5s, soporta Custom Formats con motor TRaSH-compatible y tiene API v3 estable. Es la única elección racional para el homelab. |
| Imagen | **`lscr.io/linuxserver/radarr`** | LSIO publica con `s6-overlay`, healthchecks y `PUID/PGID`. La imagen "oficial" `linuxserver/radarr` es la misma redistribuida con más latencia. Cambiar a `hotio/radarr` rompería permisos por UID interno distinto (nano vs LSIO usan UIDs diferentes). |
| Tag de imagen | **`5.14.0.9383-ls248`** (no `latest`, no `nightly`) | LSIO publica tags semánticos `<upstream>-<lsio_revision>` desde el branch `master` de Radarr. Pinear el patch fuerza al operador a leer https://github.com/linuxserver/docker-radarr/releases antes de actualizar. Watchtower está habilitado pero respeta el tag fijo (compara digest del mismo tag, ver [`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §3); para subir de minor el operador edita `.env` y hace `docker compose pull`. |
| Arquitectura | `linux/arm64` (Pi 5) | Manifest multi-arch oficial. La Pi 5 es nativa 64-bit. |
| Red Docker | **`homelab`** (bridge, [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §4.3). **Sin** `7878` publicado. | Caddy llega a la UI por nombre (`http://radarr:7878`). Prowlarr llega por sync (`http://radarr:7878/api/v3/...`). Bazarr (opt-in §12.1) llegaría también por nombre. Sin tráfico entrante desde internet, no hay justificación para publicar el puerto al host. |
| Modelo de almacenamiento | **Bind mount** `/mnt/hd2t/services/radarr/config:/config` + **Bind mount** `/mnt/hd2t/downloads:/downloads` (RW) + **Bind mount** `/mnt/hd2t/media/movies:/movies` (RW) | Patrón estándar del homelab, idéntico al de Sonarr. **Las dos rutas multimedia tienen que estar en el mismo filesystem** (`/mnt/hd2t/`) para que Radarr pueda hacer **hardlink** de `/downloads/complete/<algo>` a `/movies/<Title> (Year)/...` y no duplicar espacio mientras Transmission siga seedeando. Un cross-mount entre HDDs degradaría a `cp` (doble espacio) o `mv` (rompería el seeding). Por eso Radarr **no monta `/mnt/hd5t/`** ni nada externo a `hd2t`. |
| Bibliotecas | **Solo `/movies`** | Radarr **es exclusivo de cine**. Series las gestiona Sonarr ([`./03-sonarr.md`](./03-sonarr.md)) en `/mnt/hd2t/media/tv/`. Audiobooks/música no entran en el *arr stack base. |
| Usuario dentro del contenedor | **`PUID=1000` (homelab) + `PGID=1100` (media)** vía las variables que respeta LSIO | Coherente con [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §5.2. `PGID=1100` (no `1000`) porque Radarr **escribe en `/mnt/hd2t/media/movies/`** y necesita el grupo `media` para que el bit `setgid` funcione (los ficheros nuevos heredan `homelab:media` y Jellyfin/Samba pueden leerlos). En Prowlarr usábamos `PGID=1000` porque solo escribía en `/config`; aquí no aplica. |
| Auth de la UI | **Authelia delante** (Caddy `forward_auth`) **+** auth nativa Forms | Doble defensa, mismo patrón que Prowlarr/Sonarr/Transmission. Radarr **siempre** usa auth nativa (Forms) porque desde la 4.0.0 rechaza arrancar sin auth en redes no-loopback. Authelia añade SSO + 2FA TOTP delante. La API (`X-Api-Key`) **no pasa por Caddy** — Prowlarr la usa directamente por la red interna `homelab`. |
| `Authentication Method` (Settings → General) | **`Forms (Login Page)`** | `Basic` rompe Authelia (doble basic auth simultáneo confunde al navegador). `External` es para entornos donde Authelia/SSO ya gestiona TODO via headers `Remote-User` — es viable si el operador quiere SSO 100% transparente, pero requiere reglas Authelia más finas (un fallo y Radarr queda abierto). Forms con Authelia delante es defensa en profundidad: si Authelia se cae, Forms sigue protegiendo. |
| `Authentication Required` | **`Disabled for Local Addresses`** | Esto desactiva la auth de Forms para peticiones provenientes de la subred `homelab` Docker (172.20.0.0/24) — exactamente la subred desde la que llegan Prowlarr y Bazarr. Significa: Authelia delante para humanos vía Caddy, API por la red interna sin auth nativa adicional pero **sí** con `X-Api-Key`. |
| `URL Base` | **vacío** (`/`) | Caddy reenvía `/` directamente a `http://radarr:7878/`. No hay path-based routing necesario — cada *arr tiene su propio subdominio (`sonarr.lan`, `radarr.lan`, `prowlarr.lan`). |
| `API Key` | **autogenerada al primer arranque**, expuesta por `.env` después | Radarr genera la API key en `/config/config.xml` al primer `docker compose up -d`. La leemos con `xmllint` o `grep`, la metemos en el `.env` real y la consumen Prowlarr (Sync App), Bazarr y Homepage. El `.env` queda chmod 600. |
| `Log Level` | **`info`** | Default. `debug`/`trace` solo bajo demanda — los logs los rota LSIO en `/config/logs/`. |
| `Backup Folder` | **`/config/Backups`** (default) | Radarr hace backups internos `.zip` con `radarr.db` + `config.xml` cada cierto tiempo. Esto **se incluye** en Borg además del backup externo. |
| Indexadores | **Sincronizados desde Prowlarr** (no añadidos manualmente aquí) | Cualquier indexador añadido a mano en Radarr → Settings → Indexers se mantiene, pero rompe la "fuente única de verdad" de Prowlarr. Política del homelab: en Radarr **no se añade ningún indexador manualmente**; todos llegan vía Prowlarr Sync App. |
| Download client | **Transmission** ([`./01-transmission.md`](./01-transmission.md)) | Único cliente del homelab. Si en el futuro se añade SABnzbd para Usenet (opt-in en [`./02-prowlarr.md`](./02-prowlarr.md) §12.2), Radarr soporta múltiples download clients en paralelo y elige por categoría. |
| Categoría en Transmission | **`movies-radarr`** | Etiqueta el torrent en Transmission para que Radarr filtre solo los suyos en la queue. Sonarr usa `tv-sonarr`. Coherente con la convención `<tipo>-<servicio>`. |
| Hardlinks | **`Use Hardlinks instead of Copy = ON`** | Permite que una película descargada en `/downloads/complete/<release>/movie.mkv` también aparezca en `/movies/<Title> (Year)/<Title> (Year).mkv` **sin duplicar espacio en disco** mientras Transmission siga seedeando. Funciona porque ambos paths están en el mismo `ext4` (hd2t). Sin hardlinks, Radarr `cp` el fichero (doble espacio) o `mv` (rompe seeding) — ambos peores. |
| Recycle Bin | **`/movies/.recycle`**, retención 7 días | Antes de borrar definitivamente, Radarr mueve el fichero a `.recycle`. Recuperación inmediata si el operador se equivoca. La carpeta no entra en backup (regenerable). |
| Quality Profile principal | **HD-1080p** (Bluray > WEB-DL > WEBRip, sin DVDRip) | Default razonable para una TV moderna. Calidades inferiores quedan disponibles como fallback si no hay versión HD. UHD-2160p es opt-in (§7.3.2) — no por defecto porque la Pi 5 no transcodifica 4K en hardware ([`../09-multimedia/01-jellyfin.md`](../09-multimedia/01-jellyfin.md)) y muchas TVs no soportan HDR/Dolby Vision sin tone-mapping. |
| Custom Formats | **Mínimos**: penalizar `HDR` si la pantalla del operador no lo soporta, preferir `x265` para ahorrar espacio (compromiso CPU/storage). | Default conservador. Casos avanzados (Atmos, IMAX Enhanced, Dolby Vision profile 8) en §12.3. |
| Naming | **Plex/Jellyfin estándar**: `{Movie Title} ({Release Year}) {Edition Tags} {Quality Full}` para ficheros; `{Movie Title} ({Release Year})` para carpetas. | Coherente con Jellyfin. Cambiar el formato más tarde es seguro — Radarr renombra ficheros existentes con `Mass Editor`, pero rompe enlaces de Plex/Jellyfin si el operador ya tenía vistas registradas. |
| Backup | **Solo `/config`** vía Borgmatic | Patrón [`../07-backups/03-backup-docker-volumes.md`](../07-backups/03-backup-docker-volumes.md) §4.8: SQLite con `sqlite3 .backup` (no `cp` directo). Las películas en `/mnt/hd2t/media/movies/` se respaldan según política propia (ver [`../07-backups/01-estrategia-backup.md`](../07-backups/01-estrategia-backup.md) — generalmente excluidas o con retención corta). |
| Watchtower | **`com.centurylinklabs.watchtower.enable: "true"`** | Por política ([`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §4.2, sección "stateless o de lectura ligera"): Radarr no muta esquema BD entre patches, los upgrades minor son seguros, y un nightly defectuoso sería re-arrancado por `restart: unless-stopped` y alertado por Uptime Kuma. |
| Reverse proxy | **Caddy con `forward_auth` a Authelia** | Doble capa: TLS interno + SSO/2FA. La API para Prowlarr/Bazarr **no pasa por Caddy** sino por la red interna (`http://radarr:7878/api/v3/...` con `X-Api-Key`); por tanto Authelia no estorba a la sync. |
| Acceso remoto | **Vía Tailscale** ([`../03-red/05-tailscale.md`](../03-red/05-tailscale.md)) — `radarr.${TS_DOMAIN}` con `tls /data/tailscale-certs/radarr.crt /data/tailscale-certs/radarr.key` | Sin port forwarding HTTP ni DDNS para la UI. El homelab no necesita exponer Radarr a internet. |
| Lists (auto-add) | **Deshabilitado por defecto** | Radarr soporta importar listas externas (IMDb Top 250, TMDb populares, Trakt collections) que se traducen a "películas a buscar". Útil pero genera mucha cola en disco si no se filtra. Opt-in en §10.10 cuando el operador haya curado sus indexadores y Quality Profiles. |

---

## 1. Resumen de la arquitectura

```
                            Internet (HTTPS saliente, sin entrante)
                              ▲
                              │ - búsquedas: Prowlarr (no aquí)
                              │ - metadatos: skyhook.radarr.video,
                              │              api.themoviedb.org
                              │ - releases: trakt.tv (opt-in §10.10)
                              │
                  ┌───────────┴────────────────────┐
                  │   Pi 5 (host)  192.168.1.x     │
                  │   sin puertos publicados       │
                  └────────────────┬───────────────┘
                                   │
                                   ▼ docker network: homelab (172.20.0.0/24)
        ┌────────────────────────────────────────────────────────────┐
        │                          Radarr                            │
        │     (este doc, :7878 INTERNO)                              │
        │                                                            │
        │  /config (RW) ─► /mnt/hd2t/services/radarr/config/         │
        │     ├── radarr.db   (SQLite — películas, history, cf)      │
        │     ├── config.xml  (API key, port)                        │
        │     ├── Backups/    (zips internos)                        │
        │     ├── MediaCover/ (posters/fanart cacheados)             │
        │     └── logs/                                              │
        │                                                            │
        │  /downloads (RW) ─► /mnt/hd2t/downloads/                   │
        │     └── complete/ <Release>/  ← Transmission deja aquí     │
        │                                  Radarr LEE de aquí        │
        │  /movies (RW) ─► /mnt/hd2t/media/movies/                   │
        │     └── <Title> (Year)/<file>  ← Radarr ESCRIBE aquí       │
        │                                  (hardlink desde complete) │
        └─┬───────────────┬────────────────┬───────────────┬─────────┘
          │               │                │               │
          │ http://       │ http://        │ http://       │ http://
          │ radarr:7878/  │ prowlarr:9696  │ transmission: │ skyhook
          │   (UI)        │   (sync)       │   9091/RPC    │ + tmdb
          ▼               ▼                ▼               (HTTPS)
   ┌──────────────┐ ┌──────────────┐ ┌──────────────┐
   │    Caddy     │ │   Prowlarr   │ │ Transmission │
   │  radarr.lan  │ │ (sync app    │ │ (download    │
   │      ▲       │ │  empuja      │ │  client)     │
   │      │       │ │  indexers    │ └──────────────┘
   │  forward_auth│ │  a Radarr)   │
   │      │       │ └──────────────┘
   │      ▼       │
   │   Authelia   │   (../04-seguridad/01-authelia.md)
   └──────────────┘
          ▲
          │
    Operador (web)
    ─► https://radarr.lan
       [Authelia OTP]
       [Radarr Forms login (cacheado)]
```

Lo crítico de este diagrama:

1. **Tres rutas distintas, tres niveles de auth distintos.** Igual que Prowlarr y Sonarr.
   - **Operador → UI**: pasa por Caddy → Authelia (cookie SSO + 2FA TOTP) → Radarr (Forms login, cacheado en el navegador).
   - **Prowlarr → Radarr API**: por la red interna `homelab` directamente al puerto `7878` del contenedor — Caddy no la ve, Authelia no la ve. Su credencial es el `X-Api-Key` de Radarr.
   - **Radarr → Transmission RPC**: HTTP Basic con `${TRANSMISSION_RPC_USERNAME}:${TRANSMISSION_RPC_PASSWORD}` por la red interna `homelab`, **sin** Caddy ni Authelia.
2. **Ninguna ruta `Radarr → indexadores` directa.** A diferencia de Prowlarr, Radarr **no busca** en trackers públicos/privados directamente: pide a Prowlarr ("búscame `Inception 2010 1080p`") y Prowlarr le devuelve la lista. Radarr solo elige qué descarga concreta encolar en Transmission. Esto **simplifica enormemente** el modelo de red de Radarr (no hay cookies de trackers, no hay Cloudflare challenges, no hay rate limits — todo eso lo absorbe Prowlarr).
3. **Mismo filesystem entre `/downloads` y `/movies`.** La pieza crítica: ambos son bind mounts dentro de `/mnt/hd2t/`, que es un único `ext4`. **Esto habilita hardlinks** y, por tanto, que un fichero pueda existir simultáneamente en `complete/` (para que Transmission lo siga seedeando) y en `movies/` (para que Jellyfin lo escanee) sin ocupar el doble. Si en el futuro alguien decide mover `media/` a `hd5t` o a un NFS externo, hardlinks dejan de funcionar y Radarr cae a `cp`.
4. **API key separada de la sesión Forms.** El flujo humano (Forms cacheado) y el flujo máquina (`X-Api-Key`) son completamente independientes. Cambiar la password del usuario `homelab` no invalida la API key, y rotar la API key (§10.6) no echa al operador de la UI.
5. **El downloads bind mount se comparte con Sonarr y Transmission.** Los tres contenedores ven `/downloads/` apuntando a `/mnt/hd2t/downloads/` con el mismo path interno. Esto evita "Remote Path Mappings" (§7.7) que serían necesarios si los paths internos divergieran.

---

## 2. Plan de variables y archivos

### 2.1. Variables del stack (`.env.example` versionable)

`~/homelab/stacks/radarr/.env.example`:

```env
# ~/homelab/stacks/radarr/.env.example
# Versión control: ~/homelab/stacks/radarr/.env.example
# Valores reales en /mnt/hd2t/services/radarr/.env (chmod 600).
# La RADARR_API_KEY se rellena DESPUÉS del primer arranque, leyéndola de
# /mnt/hd2t/services/radarr/config/config.xml (§5.3).

# --- Comunes del homelab ---
HOMELAB_USER=homelab
HOMELAB_UID=1000
HOMELAB_GID=1000
MEDIA_GID=1100
TZ=Europe/Madrid

# --- Dominios internos (consistentes con dns/.env y proxy/.env) ---
LAN_DOMAIN=lan
TS_DOMAIN=tailnet.ts.net

# --- Radarr ---
# https://github.com/linuxserver/docker-radarr/releases
# Lista de cambios upstream: https://github.com/Radarr/Radarr/releases
RADARR_IMAGE_TAG=5.14.0.9383-ls248

# Hostname público (sin esquema). Usado en Caddyfile y en Radarr → URL Base.
RADARR_HOSTNAME=radarr
RADARR_LAN_HOST=radarr.lan
RADARR_TS_HOST=radarr.tailnet.ts.net

# API key — autogenerada por Radarr al primer arranque.
# Se rellena tras leer /mnt/hd2t/services/radarr/config/config.xml.
# Prowlarr la consume por la sync app (../10-descargas/02-prowlarr.md §7.4).
# Bazarr la consume si se despliega (§12.1).
RADARR_API_KEY=__rellenar_tras_primer_arranque__

# --- Credenciales del download client (Transmission) ---
# Mismas credenciales que en /mnt/hd2t/services/transmission/.env
# (../10-descargas/01-transmission.md §2). Radarr las usa para la API RPC.
TRANSMISSION_RPC_USERNAME=homelab
TRANSMISSION_RPC_PASSWORD=__copiar_de_transmission_env__

# Subred de la red `homelab` (../02-docker/02-estructura-compose.md §4.1).
# Radarr necesita confiar en esta subred para "Disabled for Local Addresses".
HOMELAB_SUBNET=172.20.0.0/24
```

### 2.2. `.env` real (`/mnt/hd2t/services/radarr/.env`)

Primera versión (sin `RADARR_API_KEY` aún — la rellenamos en §5.3):

```bash
# Crear el directorio del servicio si no existe (lo crea el bootstrap
# de ../01-sistema/04-estructura-directorios.md §4, paso "Fase 10").
sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/services/radarr

# Crear el .env con permisos correctos.
sudo install -o homelab -g homelab -m 600 /dev/null \
  /mnt/hd2t/services/radarr/.env

# Leer la password RPC de Transmission (debe existir ya, ./01-transmission.md §5).
TRPC_PASS=$(sudo grep '^TRANSMISSION_RPC_PASSWORD=' \
  /mnt/hd2t/services/transmission/.env | cut -d= -f2-)

# Volcar contenido inicial (la API key vendrá tras el primer up).
sudo -u homelab tee /mnt/hd2t/services/radarr/.env > /dev/null <<EOF
HOMELAB_USER=homelab
HOMELAB_UID=1000
HOMELAB_GID=1000
MEDIA_GID=1100
TZ=Europe/Madrid
LAN_DOMAIN=lan
TS_DOMAIN=tailnet.ts.net
RADARR_IMAGE_TAG=5.14.0.9383-ls248
RADARR_HOSTNAME=radarr
RADARR_LAN_HOST=radarr.lan
RADARR_TS_HOST=radarr.tailnet.ts.net
RADARR_API_KEY=
TRANSMISSION_RPC_USERNAME=homelab
TRANSMISSION_RPC_PASSWORD=${TRPC_PASS}
HOMELAB_SUBNET=172.20.0.0/24
EOF

# Verificar.
ls -l /mnt/hd2t/services/radarr/.env
# Esperado: -rw------- 1 homelab homelab ... .env
```

> **Por qué duplicamos `TRANSMISSION_RPC_PASSWORD` aquí**: Radarr necesita la password RPC para llamar a `transmission:9091`. La fuente de verdad sigue siendo el `.env` de Transmission; rotar la password ahí obliga a actualizarla aquí (operación documentada en §10.6). Alternativa: usar Docker secrets con un fichero compartido — más complejidad para un solo secreto, no compensa. El mismo razonamiento aplica al `.env` de Sonarr.

### 2.3. Cómo se inyectan al contenedor

El `docker-compose.yml` (§4) declara `env_file: /mnt/hd2t/services/radarr/.env`. Compose carga el fichero **a la hora de interpolar `${...}` en el YAML** y **además** lo expone al proceso del contenedor. Las variables que la imagen LSIO **lee directamente** son:

- `PUID`, `PGID`, `TZ`, `UMASK_SET` (LSIO universal).
- **Nada específico de Radarr.** A diferencia de Transmission (que tenía `USER`/`PASS`/`PEERPORT`), la imagen LSIO de Radarr no inyecta nada de configuración runtime: todo se gestiona desde la UI o editando `config.xml` a mano. Por eso `RADARR_API_KEY` y `TRANSMISSION_RPC_PASSWORD` se usan **fuera** del contenedor (en Caddyfile, en `.env` de Prowlarr/Bazarr) o por la UI de Radarr (introducir Transmission con esa password) pero **no** se inyectan por env al contenedor de Radarr.

El resto (`RADARR_HOSTNAME`, `RADARR_LAN_HOST`, `LAN_DOMAIN`, …) solo se usa **fuera** del contenedor: en el `Caddyfile` y en este `docker-compose.yml`.

> **Por qué `RADARR_API_KEY` sí va en `.env`** (a diferencia de la password de Authelia, que es secreto en `/run/secrets/`): es **la única credencial** que Prowlarr/Bazarr/Homepage necesitan para hablar con Radarr. Compartirla por `.env` (chmod 600) es coherente con cómo `TRANSMISSION_RPC_PASSWORD`, `PROWLARR_API_KEY` y `SONARR_API_KEY` viven en sus respectivos `.env`. El modelo de amenaza es el mismo: usuario `root` o `homelab` sí ven el secreto, pero ningún otro proceso del sistema lo hace.

---

## 3. Preparar el árbol de datos

### 3.1. Crear el directorio del stack

```bash
mkdir -p ~/homelab/stacks/radarr
cd ~/homelab/stacks/radarr
```

### 3.2. Crear el árbol de datos persistentes del servicio

```bash
# /mnt/hd2t/services/radarr/  (homelab:homelab 750)
sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/services/radarr
sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/services/radarr/config
```

LSIO crea el resto de subdirectorios (`logs/`, `Backups/`, `MediaCover/`, `MediaInfo/`, `xdg/`, …) en su entrypoint.

Las dos rutas de bibliotecas (`/mnt/hd2t/downloads/`, `/mnt/hd2t/media/movies/`) ya existen tras el bootstrap de [`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) §6 con `homelab:media 2775`. Verificar:

```bash
ls -ld /mnt/hd2t/downloads /mnt/hd2t/downloads/complete /mnt/hd2t/media/movies
# drwxrwsr-x 2 homelab media ... /mnt/hd2t/downloads
# drwxrwsr-x 2 homelab media ... /mnt/hd2t/downloads/complete
# drwxrwsr-x 2 homelab media ... /mnt/hd2t/media/movies

# El bit `s` (setgid) en el grupo es lo crítico: ficheros nuevos heredan el grupo media.
```

### 3.3. Tabla resumen de permisos

| Ruta | Owner:Group | Modo | Notas |
|---|---|---|---|
| `/mnt/hd2t/services/radarr/` | `homelab:homelab` | `750` | Directorio raíz del servicio. Solo `homelab`. |
| `/mnt/hd2t/services/radarr/.env` | `homelab:homelab` | `600` | Contiene `RADARR_API_KEY` y `TRANSMISSION_RPC_PASSWORD`. Solo legible por `homelab` (y `root`). |
| `/mnt/hd2t/services/radarr/config/` | `homelab:homelab` | `750` | Datos de Radarr: `radarr.db`, `config.xml`, `Backups/`, `MediaCover/`, `logs/`. Respaldable con `sqlite3 .backup`. |
| `/mnt/hd2t/services/radarr/config/radarr.db` | `homelab:homelab` | `644` (default LSIO) | BD SQLite con películas, history, indexers sincronizados, download client, custom formats. Backup vía `sqlite3 .backup`, no `cp` ([`../07-backups/03-backup-docker-volumes.md`](../07-backups/03-backup-docker-volumes.md) §4.8). |
| `/mnt/hd2t/services/radarr/config/config.xml` | `homelab:homelab` | `644` | API key, port, URL base, log level. Texto plano XML. |
| `/mnt/hd2t/downloads/` | `homelab:media` | `2775` | Ya existe ([`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) §6). `setgid` activo. Compartido con Transmission y Sonarr. |
| `/mnt/hd2t/media/movies/` | `homelab:media` | `2775` | Ya existe. Radarr escribe aquí: nuevos ficheros heredan grupo `media`. |
| `/mnt/hd2t/media/movies/.recycle/` | (creado por Radarr) `homelab:media` | `2775` | Recycle bin de Radarr. Borrado periódico por la propia Radarr (retención 7 días, ver §7.4). |

### 3.4. Permisos para el proceso del contenedor

LSIO ejecuta el entrypoint como `root` y dentro hace `chown -R abc:abc /config /downloads /movies` con `abc` mapeado al `PUID:PGID` del env. Por tanto, **dentro del contenedor** el proceso `Radarr` corre como UID 1000, GID 1100.

**Importante**: el `chown -R` sobre `/downloads` y `/movies` **puede tardar varios minutos** si el operador ya tiene cientos de GB de descargas/películas. LSIO ofrece la variable `LSIO_NON_ROOT_USER=true` (sin chown recursivo, asume que el host ya tiene los permisos correctos), pero rompe casos donde un fichero nuevo aparece con otro owner. **Recomendación: el primer arranque sin `LSIO_NON_ROOT_USER`**, dejar que termine el chown, y si en el futuro se siente lento añadirlo (los siguientes arranques son instantáneos).

> **Fricción esperada con Sonarr ya desplegado**: si Sonarr lleva días corriendo, el `chown -R` de `/downloads` ya está hecho por su entrypoint y solo se modifican atributos de los nuevos ficheros que Radarr toque. El primer arranque de Radarr suele ser ~30s, no varios minutos, gracias a esto.

El `start_period` del healthcheck (120s) cubre el primer arranque incluyendo el chown.

---

## 4. `docker-compose.yml`

`~/homelab/stacks/radarr/docker-compose.yml`:

```yaml
# ~/homelab/stacks/radarr/docker-compose.yml
# Stack: radarr (PVR de cine del *arr stack, Fase 10).
# Datos en /mnt/hd2t/services/radarr/config/.
# Bibliotecas en /mnt/hd2t/downloads/ (RW, lee de complete/) y /mnt/hd2t/media/movies/ (RW, escribe).

name: radarr

services:
  radarr:
    image: lscr.io/linuxserver/radarr:${RADARR_IMAGE_TAG}
    container_name: radarr
    hostname: radarr
    restart: unless-stopped
    env_file: /mnt/hd2t/services/radarr/.env

    environment:
      # PUID 1000 (homelab), PGID 1100 (media). Radarr escribe en /movies y necesita
      # el grupo `media` para que el setgid heredado funcione (ficheros nuevos
      # con grupo media → Jellyfin/Samba los pueden leer).
      PUID: ${HOMELAB_UID}
      PGID: ${MEDIA_GID}
      TZ: ${TZ}
      # umask 002 → ficheros 0664, dirs 0775. Combinado con setgid en /movies y
      # /downloads, los ficheros nuevos quedan homelab:media 0664 — leíbles y
      # escribibles por Jellyfin/Bazarr/Samba (todos miembros del grupo media).
      UMASK_SET: "002"

    volumes:
      # Config respaldable: radarr.db (SQLite), config.xml (API key),
      # Backups/, MediaCover/ (cache), logs/.
      - /mnt/hd2t/services/radarr/config:/config
      # Descargas (RW): Radarr lee de /downloads/complete/<release>/, hace hardlink
      # a /movies/<Title> (Year)/, deja la copia "vieja" en complete/ para que
      # Transmission siga seedeando. NO escribe en incomplete/ ni watch/.
      - /mnt/hd2t/downloads:/downloads
      # Biblioteca de cine (RW): destino de los hardlinks. Mismo filesystem que
      # /downloads (CRÍTICO para hardlinks).
      - /mnt/hd2t/media/movies:/movies
      # TZ y reloj sincronizados con el host (timestamps en logs).
      - /etc/localtime:/etc/localtime:ro

    # NO PUBLICAR PUERTOS. Caddy llega por DNS interno (http://radarr:7878).
    # Prowlarr llega por la API por la red `homelab`. Bazarr (opt-in) idem.
    # Si alguien añade `ports: - "7878:7878"`, romperá el modelo de seguridad
    # (Authelia bypassable saltándose Caddy con curl al host:7878).

    networks:
      - homelab

    # Recursos: Radarr arranca con ~250 MB (.NET 6 + SQLite + libs). En reposo
    # se estabiliza en 250-400 MB (depende del tamaño de la biblioteca; menor
    # que Sonarr porque hay menos "items" — una película es atómica).
    # Picos durante una RSS Sync masiva o un Mass Editor hasta 800 MB.
    mem_limit: 1024m
    mem_reservation: 256m

    # Healthcheck: GET /ping devuelve 200 con `Pong` cuando Radarr está vivo.
    # Este endpoint es público (no requiere API key) desde Radarr 3.0+.
    healthcheck:
      test: ["CMD-SHELL", "curl -fsS http://localhost:7878/ping || exit 1"]
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
| `name: radarr` | Nombre del proyecto Compose. Cada servicio del *arr stack tiene su propio stack folder — un `down` afecta solo a Radarr y no para Prowlarr/Sonarr/Transmission. |
| `image: lscr.io/linuxserver/radarr:${RADARR_IMAGE_TAG}` | Tag pinned vía `.env`. Vive en LinuxServer Container Registry. |
| `container_name: radarr` / `hostname: radarr` | Nombre estable para que Caddy llegue por DNS (`reverse_proxy http://radarr:7878`) y para que Prowlarr use `radarr` como host de la sync app. Sin esto, Compose le pone un nombre tipo `radarr-radarr-1` y rompe el DNS interno. |
| `env_file: /mnt/hd2t/services/radarr/.env` | Carga de variables — patrón estándar del homelab. |
| `environment.PUID` / `PGID` | UID 1000 (escribe en `/config`), GID 1100 (escribe en `/movies` y `/downloads/complete` con `setgid` heredado). |
| `environment.TZ` | Radarr loguea timestamps en zona local y planifica RSS sync con horario local. |
| `environment.UMASK_SET: "002"` | Ficheros nuevos `0664`, directorios `0775`. Jellyfin/Bazarr/Samba (todos GID 1100 o miembros) pueden leer. |
| `volumes: /mnt/hd2t/services/radarr/config:/config` | Bind mount canónico de la BD. Sin `:Z`/`:z` (no SELinux en Pi OS). |
| `volumes: /mnt/hd2t/downloads:/downloads` | Bind mount **del directorio padre completo** de descargas (no solo `complete/`). Radarr necesita ver `incomplete/` aunque no escriba en él, porque consulta el progreso de descargas activas en Transmission y mapea al fichero. **No** se monta `:ro` aunque solo "leamos" porque Radarr **mueve/borra** ficheros de `complete/` con hardlinks (la operación de hardlink es escritura). |
| `volumes: /mnt/hd2t/media/movies:/movies` | Bind mount de la biblioteca destino. **Mismo filesystem** que `/downloads` para hardlinks. |
| `volumes: /etc/localtime:ro` | Sincroniza la zona del host con el contenedor — backup ante un usuario que olvide poner `TZ` en `.env`. |
| **Sin `ports:`** | Patrón canónico del homelab. Caddy llega por DNS interno; el operador no necesita `curl http://localhost:7878` desde el host (puede hacer `docker exec radarr curl http://localhost:7878/ping` para debug). |
| `networks: [homelab]` | Solo la red compartida. Caddy ya está ahí; Prowlarr/Sonarr/Transmission/Bazarr también. |
| `mem_limit: 1024m` | Radarr ronda 250-400 MB; picos al hacer Mass Editor o RSS Sync de una biblioteca grande hasta 800 MB. 1024 MB de tope deja margen sin pegarse con el resto del homelab. La Pi 5 (8 GB) tiene ~6 GB libres tras descontar el SO; Radarr ocupa el ~5%. Por debajo del límite de Sonarr (1280 MB) porque películas son atómicas (menos episodios = menos memoria de catálogo). |
| `mem_reservation: 256m` | Garantía mínima en presión de memoria. Radarr no degrada bien con OOM (corrupción posible de `radarr.db` si crashea durante un commit). |
| `healthcheck` con `curl` a `/ping` | Endpoint público sin auth desde 3.0+. `start_period: 120s` cubre el primer arranque (chown recursivo + migraciones de BD + carga inicial; en una Pi 5 con biblioteca pequeña tarda ~30s, con biblioteca grande hasta 90s). |
| `security_opt: no-new-privileges:true` | Patrón base ([`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §0). |
| `com.centurylinklabs.watchtower.enable: "true"` | Watchtower opt-in ([`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §4.2). Radarr es elegible por el mismo argumento que Prowlarr/Sonarr: BD pequeña con migraciones reversibles, imagen LSIO valida arranque antes de marcar el `latest`. |
| `dev.dozzle.group: "arr"` | Agrupa logs con Prowlarr, Sonarr y Transmission cuando Dozzle ([`../05-monitorizacion/06-dozzle.md`](../05-monitorizacion/06-dozzle.md)) levante. |
| `networks.homelab.external: true` | Patrón de [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §4.4: la red se crea **una vez** durante el bootstrap. |

### 4.2. Validar antes de levantar

```bash
cd ~/homelab/stacks/radarr
docker compose --env-file /mnt/hd2t/services/radarr/.env config
```

Esperado: salida YAML resuelta sin warnings. Verificar especialmente:

- `image: lscr.io/linuxserver/radarr:5.14.0.9383-ls248` (el tag interpolado).
- `PUID: "1000"`, `PGID: "1100"` (no `1000` en `PGID`).
- `networks: [homelab]`.
- **No** debe aparecer ningún `ports:` (si aparece, alguien lo añadió por error).
- Los tres bind mounts (`/config`, `/downloads`, `/movies`) están presentes con sus paths del host correctos.

Si Compose se queja de `version` en el YAML: la spec moderna no necesita `version: "3.x"`; está omitido a propósito.

---

## 5. Despliegue

### 5.1. Levantar el stack

```bash
cd ~/homelab/stacks/radarr

# Pull explícito antes del up: separa errores de imagen de errores de runtime.
docker compose --env-file /mnt/hd2t/services/radarr/.env pull
docker compose --env-file /mnt/hd2t/services/radarr/.env up -d

docker compose ps
# radarr   running (starting → healthy ~60-120s después)
```

### 5.2. Estado del contenedor

```bash
docker inspect radarr \
  --format '{{.State.Status}} | {{.State.Health.Status}}'
# running | healthy

docker logs radarr --tail 80
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
[Info] Bootstrap: Starting Radarr - /app/radarr/bin/Radarr
[Info] Bootstrap: Radarr X64 v5.14.0.9383 master
[Info] AppFolderInfo: Data folder: /config
[Info] MigrationController: *** Migrating data source=/config/radarr.db ***
[Info] MigrationController: *** N: ... migrating ***
[Info] OwinHostController: Listening on http://0.0.0.0:7878
[Info] OwinHostController: Started Radarr.
```

Si en lugar de `Listening on http://0.0.0.0:7878` aparece un stack trace de SQLite con `database is locked` o `Malformed database`, ver §11.

### 5.3. Recoger la API key autogenerada

Radarr genera la API key al arrancar y la escribe en `/config/config.xml`. La leemos y la metemos en el `.env`:

```bash
# Leer la API key generada.
RADARR_API_KEY=$(sudo grep '<ApiKey>' /mnt/hd2t/services/radarr/config/config.xml \
  | sed -E 's,.*<ApiKey>([^<]+)</ApiKey>.*,\1,')
echo "API key: $RADARR_API_KEY"
# Esperado: 32 chars hex, p. ej. a1b2c3d4e5f60718293a4b5c6d7e8f90

# Apuntarla en el password manager bajo "Homelab → Radarr API key"
# (la necesitarás al configurar Prowlarr → Apps).

# Inyectarla en el .env (preservando el resto del fichero).
sudo sed -i \
  -e "s|^RADARR_API_KEY=.*|RADARR_API_KEY=${RADARR_API_KEY}|" \
  /mnt/hd2t/services/radarr/.env

# Verificar.
sudo grep '^RADARR_API_KEY=' /mnt/hd2t/services/radarr/.env
```

> **Por qué no la generamos nosotros antes**: Radarr **siempre** regenera la API key si encuentra `<ApiKey></ApiKey>` vacío en `config.xml`. Pre-poblar la key en el `.env` no la inyecta automáticamente — habría que editarla manualmente en `config.xml`, parar el contenedor (porque Radarr lee `config.xml` solo al arrancar) y volverlo a levantar. Es más simple dejarla autogenerar y leerla.

### 5.4. Smoke check de la API antes de la UI

A partir de aquí Radarr está accesible **internamente** en `http://radarr:7878/` desde la red `homelab`. No es accesible desde el host hasta que Caddy esté configurado (§6). Verificación pre-UI:

```bash
# Ping interno (desde otro contenedor en la red homelab).
docker run --rm --network homelab curlimages/curl:latest \
  http://radarr:7878/ping
# {"status":"OK"}

# API authenticada (status del sistema).
docker run --rm --network homelab curlimages/curl:latest \
  -H "X-Api-Key: ${RADARR_API_KEY}" \
  http://radarr:7878/api/v3/system/status
# {"appName":"Radarr","instanceName":"Radarr","version":"5.14.0.9383",...}
```

### 5.5. Crear el primer usuario (Authentication = Forms)

En la UI Radarr **fuerza** crear un usuario admin la primera vez que se accede sin auth. Como queremos hacerlo *antes* de que Caddy enrute (para no tener que pasar por Authelia en este paso de bootstrap), hacemos un port-forward temporal al host:

```bash
# Túnel SSH: localhost:7878 → contenedor radarr:7878
# (suponiendo que estás trabajando en remoto; en local, ssh -L 7878 desde tu laptop).
RADARR_IP=$(docker inspect radarr \
  --format '{{.NetworkSettings.Networks.homelab.IPAddress}}')
ssh -L 7878:${RADARR_IP}:7878 homelab@pi
```

Abrir `http://localhost:7878/` en el navegador → Radarr pide:

- **Authentication Method**: Forms (Login Page).
- **Username**: `homelab` (mismo usuario que Authelia, por consistencia).
- **Password**: el del password manager bajo "Homelab → Radarr UI" (32 chars urlsafe).
- **Authentication Required**: **Disabled for Local Addresses** (clave para que Prowlarr/Bazarr puedan usar la API por la red interna sin pasar por el formulario de login).

Tras guardar, Radarr persiste la config en `radarr.db` y `config.xml`. Cerrar el túnel SSH:

```bash
# Ctrl+C en la terminal del túnel.
```

> Alternativa sin túnel SSH: configurar Caddy primero (§6), añadir el bloque `radarr.lan` **sin** Authelia (comentar el `forward_auth`), hacer el primer login, y luego añadir Authelia y recargar. Es más pasos pero evita el túnel.

---

## 6. Integración con Caddy

### 6.1. Añadir el bloque `radarr.{$LAN_DOMAIN}` al `Caddyfile`

`~/homelab/stacks/proxy/Caddyfile`, sección de bloques de host (siguiendo el patrón de §4.3 de [`../03-red/04-caddy.md`](../03-red/04-caddy.md)):

```caddy
# ----- Radarr (../10-descargas/04-radarr.md) -----
radarr.{$LAN_DOMAIN} {
    import lan_internal_tls
    import security_headers

    # Authelia delante: 2FA TOTP obligatorio (group:admin), ../04-seguridad/01-authelia.md §4.
    forward_auth http://authelia:9091 {
        uri /api/authz/forward-auth
        copy_headers Remote-User Remote-Groups Remote-Name Remote-Email
    }

    reverse_proxy http://radarr:7878 {
        # Radarr no necesita rewrite — sirve la UI en /.
        header_up X-Forwarded-Proto https
        header_up X-Real-IP {remote_host}
    }
}
```

Recargar Caddy:

```bash
docker exec proxy caddy reload --config /etc/caddy/Caddyfile
```

### 6.2. Trusted proxies en Radarr

Radarr soporta `Settings → General → Reverse Proxy → Trusted Proxies`. Recomendado para que la cabecera `X-Forwarded-For` se honre correctamente (Radarr la usa en logs y en la lógica de "Disabled for Local Addresses"). Sin esto, Radarr ve todas las peticiones provenientes de la IP del bridge Docker (`172.20.0.1`) en lugar de la IP real del cliente.

UI → Settings → General → Security → **Trusted Proxies**: `172.20.0.0/24`. Save.

### 6.3. Registro DNS local en Pi-hole

`https://pihole.lan/admin/` → **Local DNS → DNS Records**:

| Domain | IP Address |
|---|---|
| `radarr.lan` | `192.168.1.x` (IP fija de la Pi) |

Verificar:

```bash
dig +short radarr.lan @192.168.1.2
# 192.168.1.x   (IP de la Pi)
```

### 6.4. Probar el acceso

Desde un equipo de la LAN con la CA interna confiada (paso 6.5 de [`../03-red/04-caddy.md`](../03-red/04-caddy.md)):

```
https://radarr.lan
```

Flujo esperado:

1. **Authelia** redirige a `https://auth.lan/?rd=https://radarr.lan/`.
2. Login con usuario `homelab` (con grupo `admin`).
3. **2FA TOTP** (configurado en el primer login a Authelia, [`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md)).
4. Tras OK, Caddy reenvía a `http://radarr:7878/` y **Radarr no vuelve a pedir login** porque la cookie de Forms está cacheada (si es el primer login: la pide una vez y luego ya queda).

> **Por qué doble auth visible solo el primer día**: el navegador cachea la cookie de Forms `Radarr` por 30 días, así que tras el primer login solo se ve Authelia. Si el operador limpia cookies o cambia de navegador, ve los dos formularios consecutivos.

### 6.5. Por qué Authelia delante de Radarr por defecto

Mismas razones que Sonarr ([`./03-sonarr.md`](./03-sonarr.md) §6.5), Prowlarr ([`./02-prowlarr.md`](./02-prowlarr.md) §6.5) y Transmission ([`./01-transmission.md`](./01-transmission.md) §6.5):

- **Authelia delante**: la auth Forms de Radarr es razonable (PBKDF2, lockout interno) pero sin 2FA. Authelia cubre ese hueco con TOTP obligatorio.
- **No interfiere con Prowlarr/Bazarr**: ellos hablan al puerto interno 7878 con `X-Api-Key`, **sin** pasar por Caddy ni Authelia.
- **No interfiere con apps móviles**: Radarr tiene apps Android/iOS no oficiales (nzb360, LunaSea, Radarr Companion) que usan la API directa con `X-Api-Key`. Si el operador las usa **desde fuera de la LAN**, debe enchufarlas a la URL Tailscale (`radarr.${TS_DOMAIN}`) y configurarlas con la API key — pasan por Caddy pero **no** por Authelia (el `forward_auth` ignora rutas `/api/...` solo si el operador lo declara explícitamente; ver §12.4 si esto se necesita).

### 6.6. Acceso vía Tailscale (preparado)

Cuando Tailscale esté operativo ([`../03-red/05-tailscale.md`](../03-red/05-tailscale.md)), añadir al `Caddyfile`:

```caddy
radarr.{$TS_DOMAIN} {
    import tailscale_tls radarr
    import security_headers

    # Authelia también delante en Tailscale (no es un "remoto de confianza").
    forward_auth http://authelia:9091 {
        uri /api/authz/forward-auth
        copy_headers Remote-User Remote-Groups Remote-Name Remote-Email
    }

    reverse_proxy http://radarr:7878 {
        header_up X-Forwarded-Proto https
        header_up X-Real-IP {remote_host}
    }
}
```

---

## 7. Configuración post-despliegue

La mayoría de la configuración va por la UI (Radarr no expone variables de entorno para películas ni quality profiles; es BD-driven).

### 7.1. Settings → General

| Sección | Campo | Valor recomendado | Notas |
|---|---|---|---|
| Host | `Bind Address` | `*` | Default. |
| Host | `Port Number` | `7878` | Default. **No cambiar** — coincide con el `EXPOSE` de la imagen LSIO y con el `http://radarr:7878` del Caddyfile. |
| Host | `URL Base` | (vacío) | Caddy reenvía `/` directamente. |
| Host | `Enable SSL` | `Off` | TLS lo gestiona Caddy. |
| Security | `Authentication` | `Forms (Login Page)` | (ver §5.5). |
| Security | `Authentication Required` | `Disabled for Local Addresses` | Permite que Prowlarr/Bazarr pasen sin form-auth (siguen necesitando `X-Api-Key`). |
| Security | `Trusted Proxies` | `172.20.0.0/24` | (ver §6.2). |
| Logging | `Log Level` | `Info` | Default. `Debug`/`Trace` solo bajo demanda. |
| Updates | `Branch` | `master` | Default. **No** seleccionar `develop` — el `latest` de LSIO ya empaqueta `master`. (En Sonarr la rama estable se llama `main`; en Radarr es `master` por razones históricas.) |
| Updates | `Automatic` | `Off` | Watchtower hace el upgrade del contenedor. La opción "Automatic" interna de Radarr (descarga el binario dentro del contenedor) **no es relevante** en imágenes Docker — además choca con la política Watchtower. |
| Updates | `Mechanism` | `Docker` | Etiqueta solo descriptiva en imágenes Docker; deshabilita el botón "Update" de la UI para evitar confusión. |
| Backup | `Folder` | `/config/Backups` | Default. Borg lo respaldará dentro de `/config`. |
| Backup | `Interval` | `7 days` | Default. Generación de `.zip` interno cada semana. |
| Backup | `Retention` | `28 days` | Default. ~4 zips guardados. |

### 7.2. Settings → Media Management

Configuración crítica de Radarr — controla cómo Radarr renombra y ubica los ficheros. Los valores se guardan en `Settings → Media Management`.

| Sección | Campo | Valor recomendado | Notas |
|---|---|---|---|
| Movie Naming | `Rename Movies` | `Yes` | Sin rename, los ficheros mantienen el nombre del release (`Inception.2010.1080p.BluRay.x264-GROUP.mkv`), feo en Jellyfin. |
| Movie Naming | `Replace Illegal Characters` | `Yes` | Default. Reemplaza `:`, `?`, `<`, `>`, `*`, `|` por `_`. |
| Movie Naming | `Standard Movie Format` | `{Movie Title} ({Release Year}) {Edition Tags} {Quality Full}` | Formato Plex/Jellyfin estándar. `Edition Tags` añade `[IMAX]`, `[Director's Cut]`, etc. cuando aplique. |
| Movie Naming | `Movie Folder Format` | `{Movie Title} ({Release Year})` | Default. Una carpeta por película, año entre paréntesis para desambiguar (Spider-Man 2002 vs 2017 vs 2018). |
| Folders | `Create empty movie folders` | `No` | Si una película no tiene fichero, no crear carpeta vacía en `/movies/`. |
| Folders | `Delete empty folders` | `Yes` | Limpia carpetas vacías tras eliminar películas. |
| Importing | `Minimum Free Space` | `100 MB` | Radarr no importa si quedaría menos de 100 MB en `/movies` tras la copia. Salvaguarda sensata. |
| Importing | **`Use Hardlinks instead of Copy`** | **`Yes`** | **Crítico**. Permite que `/downloads/complete/<x>/movie.mkv` y `/movies/<Title> (Year)/<Title> (Year).mkv` sean el mismo inodo — sin duplicar espacio. |
| Importing | `Import Extra Files` | `Yes`, extensiones `srt,nfo,info,sub,idx` | Importa subtítulos sueltos del release. |
| File Management | `Unmonitor Deleted Movies` | `Yes` | Si el operador borra un fichero, Radarr no lo re-baja. |
| File Management | `Propers and Repacks` | `Do Not Prefer` | Cambiar a `Prefer` si el operador es purista de calidad y quiere upgrade automático de releases con bugs. Por defecto evita re-descargar lo mismo. |
| File Management | `Analyse video files` | `Yes` | Radarr lee el header del .mkv para extraer codec, resolución, audio, HDR flags. Útil para Custom Formats avanzadas. |
| File Management | **`Recycling Bin`** | **`/movies/.recycle`** | (ver §7.4). |
| File Management | `Recycling Bin Cleanup` | `7 days` | Borrar `.recycle/` automáticamente tras 7 días. |
| Permissions | `Set Permissions` | `Yes` | LSIO maneja permisos por `umask`/`PUID`/`PGID`; este flag asegura que Radarr re-aplica el `chmod` después de mover un fichero. |
| Permissions | `chmod Folder` | `775` | Coherente con `umask 002`. |
| Permissions | `chmod File` | `664` | Idem. |
| Permissions | `chown Group` | (vacío) | Radarr corre con `homelab:media`; los ficheros nuevos heredan grupo `media` por `setgid`. |

> **Nota sobre `Standard Movie Format`**: el formato exacto puede variar según preferencias. Algunas alternativas útiles:
>
> - `{Movie Title} ({Release Year}) [{Quality Full}]` — calidad entre corchetes en lugar de al final.
> - `{Movie Title} ({Release Year}) - {Quality Full}` — separador con guion.
> - `{Movie Title} ({Release Year}) {Edition Tags} [{Mediainfo VideoDynamicRangeType}] {Quality Full}` — incluye HDR/SDR explícito (útil si la biblioteca mezcla versiones HDR y SDR de la misma película).
>
> Cualquier cambio futuro requiere `Library → Mass Editor → Rename Movies` para aplicar a las películas ya importadas.

### 7.3. Settings → Quality

Radarr define `Quality Profiles` que dicen qué resolución/codec/release-type aceptar y en qué orden. La configuración por defecto es razonable para HD.

#### 7.3.1. Quality Definitions (megabytes/minuto por calidad)

`Settings → Quality → Quality Definitions` define los **tamaños esperados** por minuto de película. Radarr usa esto para descartar releases obviamente mal etiquetados (un "1080p" de 200 MB no es 1080p real de una peli de 2 horas).

Los defaults son razonables. Solo ajustar si:

- El operador tiene mucho espacio y quiere admitir REMUX (subir el `Max` de `Bluray-1080p` de 137 a 200 MB/min).
- El operador tiene poco espacio y quiere descartar Bluray REMUX (bajar el `Max` de `Bluray-1080p` a 80 MB/min).

#### 7.3.2. Quality Profiles

`Settings → Profiles → Quality Profiles` — definir **un profile principal** y opcionalmente uno de fallback:

```
Quality Profile: HD-1080p
- Allowed:
  - Bluray-1080p
  - WEBDL-1080p
  - WEBRip-1080p
- Cutoff: WEBDL-1080p
- Upgrade Allowed: Yes
- Custom Formats:
  - (vacío al inicio; rellenar tras §7.3.3)
```

```
Quality Profile: HD-720p (fallback)
- Allowed:
  - Bluray-720p
  - WEBDL-720p
  - HDTV-720p
- Cutoff: WEBDL-720p
- Upgrade Allowed: Yes
```

```
Quality Profile: UHD-2160p (opt-in, si la TV soporta 4K HDR)
- Allowed:
  - Bluray-2160p
  - WEBDL-2160p
  - WEBRip-2160p
- Cutoff: WEBDL-2160p
- Upgrade Allowed: Yes
- Custom Formats:
  - HDR10/HDR10+/Dolby Vision: score positivo
  - x265/HEVC: score positivo (los releases 4K casi siempre son x265)
```

```
Quality Profile: Any (último recurso)
- Allowed: TODAS excepto Unknown y Raw-HD
- Cutoff: WEBDL-1080p
```

`Cutoff` significa "para de buscar upgrades cuando alcances esta calidad". Sin cutoff, Radarr re-descarga eternamente intentando llegar al máximo permitido — caro en bandwidth.

> **Sobre UHD-2160p**: la Pi 5 **no transcodifica 4K en hardware** ([`../09-multimedia/01-jellyfin.md`](../09-multimedia/01-jellyfin.md)). Si el operador reproduce 4K HDR en una TV moderna (LG/Samsung/Sony OLED) que soporta direct-play HEVC + HDR sin transcoding, UHD-2160p es viable. Si la TV no soporta HDR o Jellyfin necesita transcodear (cambiar bitrate, idioma de audio, subtítulos quemados), la Pi se ahogará. Por defecto el homelab **no activa** UHD; es opt-in informado.

#### 7.3.3. Custom Formats (opcional, recomendado)

Las Custom Formats permiten preferir/penalizar ciertos releases más allá de la calidad pura. Mínimo recomendado:

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
Custom Format: Preferir IMAX Enhanced
- Match: Edition = IMAX
- Score: +200
```

```
Custom Format: Preferir Atmos / TrueHD
- Match: AudioCodec = TrueHD AND AudioCodecAttributes contains "Atmos"
- Score: +100
```

```
Custom Format: Penalizar GROUP basura (opcional)
- Match: ReleaseGroupRegex = ^(EVO|RARBG|YIFY|YTS)$
- Score: -100  (no descartar, pero preferir otros)
```

```
Custom Format: Penalizar 3D Blu-ray
- Match: Edition = 3D
- Score: -10000  (las versiones 3D requieren TV 3D, ya casi extinta)
```

Asignar las Custom Formats a los Quality Profiles: `Settings → Profiles → Quality Profiles → HD-1080p → Custom Formats` → puntuar cada una.

> **Empezar mínimo**: añadir Custom Formats de a poco y verificar el efecto en la History. Una Custom Format mal escrita rechaza todos los releases. Para configuraciones avanzadas curadas por la comunidad, ver §12.3 (TRaSH-Guides) y §12.8 (recyclarr).

### 7.4. Lenguaje original y "Original Language"

Radarr v5 tiene una particularidad **importante** que Sonarr no tiene: cada película tiene un `Original Language` (`en`, `es`, `fr`, `ja`, `ko`, …) que viene de TMDb. En `Quality Profile → Language` se puede especificar:

- **`Original`**: Radarr acepta releases en el idioma original de la película (un anime japonés en japonés, una peli francesa en francés). Recomendado: el operador puede elegir luego subtítulos.
- **`Spanish`** / **`English`** / etc.: Radarr **filtra** releases por idioma de audio. Útil si el operador solo quiere doblajes ES.
- **`Any`**: cualquier idioma. Default permisivo.

Recomendación para el homelab español:

```
Quality Profile: HD-1080p
- Language: Original
```

Y luego Bazarr (§12.1) baja subtítulos ES automáticamente. Esto evita que Radarr rechace una peli francesa porque "no hay versión en español" — la baja en francés y Bazarr le pone subs en español.

Si el operador quiere **forzar** doblaje en español (películas comerciales que lo tienen):

```
Quality Profile: HD-1080p Spanish
- Language: Spanish
```

Y el resto de profiles (HD-720p, UHD-2160p) con `Original`.

> **Diferencia clave con Sonarr**: en Sonarr v4 los Language Profiles son una entidad separada (Settings → Profiles → Language Profiles). En Radarr v5 el lenguaje se ha **fusionado** en el Quality Profile (una sola pantalla). Si el operador llega del modelo viejo de Sonarr, esto despista — no hay tab "Language Profiles" en Radarr v5.

### 7.5. Settings → Indexers

**No añadir nada manualmente**. Tras desplegar Prowlarr ([`./02-prowlarr.md`](./02-prowlarr.md)) y registrar Radarr en `Prowlarr → Apps`, los indexadores aparecerán aquí automáticamente vía Sync App. El operador puede ver la lista pero no debe editarla — cualquier cambio se sobrescribe en el siguiente sync.

Verificar tras el sync inicial (§7.10):

```bash
docker run --rm --network homelab curlimages/curl:latest \
  -H "X-Api-Key: ${RADARR_API_KEY}" \
  http://radarr:7878/api/v3/indexer | jq '.[] | .name'
# Lista de indexadores propagados desde Prowlarr.
```

### 7.6. Settings → Download Clients — Transmission

Pieza crítica: cómo Radarr habla con Transmission.

```
Settings → Download Clients → [+] → Transmission

Name:           Transmission
Enable:         Yes
Host:           transmission
Port:           9091
URL Base:       /transmission/
Username:       ${TRANSMISSION_RPC_USERNAME}    (= homelab)
Password:       ${TRANSMISSION_RPC_PASSWORD}    (de /mnt/hd2t/services/transmission/.env)
Category:       movies-radarr
Directory:      (vacío — usa download-dir de Transmission, /downloads/complete/)
Use SSL:        No
Recent Priority:  Normal
Older Priority:   Normal
```

Tras `Test → Save`, Radarr verifica que puede conectarse a Transmission. Si falla:

- `Connection refused`: Transmission no está corriendo o no está en la red `homelab` (verificar con `docker network inspect homelab`).
- `Unauthorized`: password mal copiada (revisar `.env`).
- `URL Base`: si Transmission tiene `rpc-url: /transmission/` (default LSIO), `URL Base: /transmission/` es correcto. Si alguien lo cambió en `settings.json`, ajustar aquí.

> **Importante: la categoría debe ser distinta entre Sonarr y Radarr.** Sonarr usa `tv-sonarr`, Radarr usa `movies-radarr`. Si por error ambos usan la misma categoría, cuando un torrent termina de descargarse cada *arr intenta importarlo y se pisan (uno renombra "Episode S01E01" y el otro intenta renombrar "Movie 2024" sobre el mismo fichero). Verificar en Transmission UI que los torrents activos tengan la etiqueta correcta.

### 7.7. Remote Path Mappings — **NO necesarios**

Importante: en este homelab **no hay que configurar Remote Path Mappings**. Razón:

- Transmission ve los ficheros completos en `/downloads/complete/<release>/movie.mkv` (paths internos del contenedor Transmission).
- Radarr ve los mismos ficheros en `/downloads/complete/<release>/movie.mkv` (paths internos del contenedor Radarr).
- Ambos contenedores comparten el bind mount `/mnt/hd2t/downloads/` → `/downloads/`. **Los paths internos coinciden**.

Esto evita la fricción típica del setup multi-host (donde Radarr corre en una máquina y Transmission en otra, y los paths son distintos). Si en el futuro alguien mueve Transmission a otra máquina, **entonces** habría que añadir un Remote Path Mapping (`Settings → Download Clients → Remote Path Mappings → Add` con `Host: transmission`, `Remote Path: /downloads`, `Local Path: /downloads`). En esta arquitectura, **no**.

### 7.8. Settings → Connect — Notifications

Configurar al menos una notificación para detectar fallos de descarga:

```
Settings → Connect → [+] → Telegram

Name:                 Telegram
Bot Token:            <token>
Chat ID:              <chat>
Send Silently:        No
Notification Triggers:
  ☐ On Grab           (puede ser ruido si se descargan muchas pelis a la vez)
  ☑ On Import         (avisa cuando una peli entra en /movies/)
  ☐ On Movie File Delete
  ☑ On Health Issue   (avisa de errores: indexer roto, download client caído)
  ☑ On Health Issue Resolved
  ☑ On Application Update
```

Otras opciones disponibles: Email, ntfy, Discord, Pushover, Notifiarr, Custom Script (§12.5).

### 7.9. Root Folders

Definir la ubicación de la biblioteca:

```
Settings → Media Management → Root Folders → Add Root Folder

Path: /movies
```

Al guardar, Radarr escanea `/movies/` por carpetas que parezcan películas (heurística por nombre + año + búsqueda en TMDb). Si el operador ya tenía películas ahí, las detecta y propone "Library Import" (§10.7).

Radarr verifica que `/movies` es **escribible** (toca un fichero de prueba). Si falla, revisar que el bind mount `/mnt/hd2t/media/movies:/movies` está RW y que `homelab:media` tiene el bit `setgid` en `/mnt/hd2t/media/movies/` ([`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) §6).

### 7.10. Sincronizar con Prowlarr

Tras configurar todo lo anterior en Radarr, ir al **Prowlarr** ([`./02-prowlarr.md`](./02-prowlarr.md) §7.4) y registrar Radarr en `Prowlarr → Apps`:

```
Prowlarr UI → Settings → Apps → Add Application ([+]) → Radarr

Name:           Radarr
Sync Level:     Add and Remove Only
Tags:           (vacío o "movies-radarr")
Prowlarr Server: http://prowlarr:9696
Radarr Server:   http://radarr:7878
ApiKey:          <RADARR_API_KEY de §5.3>

Test → Save.
```

A los pocos segundos, los indexadores configurados en Prowlarr aparecerán en `Radarr → Settings → Indexers`. Verificar:

```bash
docker run --rm --network homelab curlimages/curl:latest \
  -H "X-Api-Key: ${RADARR_API_KEY}" \
  http://radarr:7878/api/v3/indexer | jq '.[].name'
# Lista de indexadores que coincide con la de Prowlarr.
```

> **Si el operador usa tags para separar TV y cine** (recomendado, ver [`./02-prowlarr.md`](./02-prowlarr.md) §7.5): los indexadores anime-only no se sincronizan a Radarr (anime cinematográfico es minoría; el grueso del anime es serie y va a Sonarr). Para anime cinematográfico se puede levantar una segunda instancia (§12.2) o aceptar el ruido.

### 7.11. Aplicar y verificar

```bash
# Verificar que Radarr ha persistido el download client y los root folders:
sudo sqlite3 /mnt/hd2t/services/radarr/config/radarr.db \
  "SELECT Name, Implementation, Settings FROM DownloadClients;"
# Transmission|Transmission|{"host":"transmission","port":9091,...}

sudo sqlite3 /mnt/hd2t/services/radarr/config/radarr.db \
  "SELECT Path FROM RootFolders;"
# /movies
```

> **Cuidado al hacer queries directas a `radarr.db`**: hacer `sqlite3 ... write` con el contenedor corriendo puede corromper la BD. Para read-only basta con `sudo sqlite3 radarr.db ".dump"`.

---

## 8. Verificación

### 8.1. Contenedor sano

```bash
docker compose ps
# radarr   running (healthy)
docker inspect radarr --format '{{.State.Health.Status}}'
# healthy
```

### 8.2. Radarr no escucha al host (solo dentro de la red `homelab`)

```bash
# Desde dentro del contenedor: sí escucha 7878.
docker exec radarr ss -tnlp | grep ':7878'
# tcp   LISTEN  0  100  *:7878   *:*   users:(("Radarr",pid=...,fd=...))

# Desde el host: 7878 NO publicado.
ss -tnlp | grep ':7878'   # vacío (correcto)
```

Si `ss -tnlp | grep ':7878'` en el host devuelve algo, alguien añadió `ports: - "7878:7878"` al compose. Quitarlo y `docker compose up -d`.

### 8.3. Bibliotecas montadas y escribibles

```bash
docker exec radarr ls -ld /config /downloads /downloads/complete /movies
# drwxr-x---  ... abc abc   ... /config        (homelab:homelab 750)
# drwxrwsr-x  ... abc users ... /downloads     (homelab:media 2775)
# drwxrwsr-x  ... abc users ... /downloads/complete
# drwxrwsr-x  ... abc users ... /movies        (homelab:media 2775)

# Smoke test de escritura en /movies (con setgid, debe heredar grupo media).
docker exec radarr touch /movies/.smoke
docker exec radarr ls -l /movies/.smoke
# -rw-rw-r-- 1 abc users ... .smoke   (group "users" = GID 1100 = "media" en host)
docker exec radarr rm /movies/.smoke

# Smoke test de hardlink entre /downloads y /movies (mismo FS).
docker exec radarr sh -c '
  mkdir -p /downloads/complete/.smoke
  echo test > /downloads/complete/.smoke/file.txt
  ln /downloads/complete/.smoke/file.txt /movies/.smoke-link
  ls -l /downloads/complete/.smoke/file.txt /movies/.smoke-link
'
# Esperado: ambos ficheros con el mismo número de inodo (columna después del modo)
# y nlink=2. Si se crea como copia (nlink=1, distinto inodo), hardlinks no funcionan
# — verificar que /downloads y /movies apuntan al mismo filesystem (df -T).

docker exec radarr rm -rf /downloads/complete/.smoke /movies/.smoke-link
```

### 8.4. UI accesible vía Caddy

```bash
curl -ks https://radarr.lan/ -o /dev/null -w '%{http_code}\n'
# 302    (redirect a Authelia)
```

Desde un navegador con la CA interna confiada:

1. `https://radarr.lan` → redirect a Authelia.
2. Login + TOTP → redirect a Radarr.
3. La UI de Radarr carga con el banner "Radarr Version 5.14.0.9383".

### 8.5. API operativa (autenticada)

```bash
docker run --rm --network homelab curlimages/curl:latest \
  -H "X-Api-Key: ${RADARR_API_KEY}" \
  http://radarr:7878/api/v3/system/status \
  | jq '.version, .branch, .runtimeVersion'
# "5.14.0.9383"
# "master"
# "6.0.36"   (.NET 6 runtime)
```

Sin API key:

```bash
docker run --rm --network homelab curlimages/curl:latest \
  http://radarr:7878/api/v3/system/status -o /dev/null -w '%{http_code}\n'
# 401   (correcto: la API exige X-Api-Key incluso con "Disabled for Local Addresses",
#        que solo desactiva el form-auth; X-Api-Key sigue siendo obligatorio).
```

### 8.6. Test del download client (Transmission)

```bash
docker run --rm --network homelab curlimages/curl:latest \
  -H "X-Api-Key: ${RADARR_API_KEY}" \
  -X POST http://radarr:7878/api/v3/downloadclient/test \
  -H 'Content-Type: application/json' \
  --data-binary @- <<EOF
{
  "id": $(docker run --rm --network homelab curlimages/curl:latest \
    -s -H "X-Api-Key: ${RADARR_API_KEY}" \
    http://radarr:7878/api/v3/downloadclient | jq '.[0].id')
}
EOF
# (HTTP 200 si OK; 400 con mensaje si falla)
```

O por la UI: `Settings → Download Clients → Transmission → Test`.

### 8.7. Smoke test: añadir una película de prueba

Vía UI: `Movies → [+] → Add New` → buscar una película (p.ej. "Big Buck Bunny" — peli libre del Blender Institute, en TMDb como tt1254207). Configurar:

- **Root Folder**: `/movies`.
- **Quality Profile**: `HD-1080p`.
- **Minimum Availability**: `Released` (para que solo busque pelis ya estrenadas; alternativas: `Announced`, `In Cinemas`).
- **Monitor**: `Movie Only`.
- **Search**: `Start search for movie` (opcional).

Tras `Add Movie`, Radarr crea la carpeta `/mnt/hd2t/media/movies/Big Buck Bunny (2008)/` y empieza a buscar releases. Verificar:

```bash
ls -la /mnt/hd2t/media/movies/
# Debe aparecer la carpeta de la peli con owner homelab:media.
```

### 8.8. Persistencia tras reboot

```bash
sudo reboot
# (esperar)
ssh homelab@pi
docker compose -f ~/homelab/stacks/radarr/docker-compose.yml ps
# radarr   running (healthy)

# Películas siguen registradas:
docker run --rm --network homelab curlimages/curl:latest \
  -H "X-Api-Key: ${RADARR_API_KEY}" \
  http://radarr:7878/api/v3/movie | jq '.[] | .title'
```

### 8.9. Lista de verificación

- [ ] Contenedor `radarr` está `running (healthy)`.
- [ ] Puerto `7878` **no** está publicado en el host (`ss -tnlp | grep 7878` vacío).
- [ ] `https://radarr.lan` redirige a Authelia, login con TOTP funciona, UI de Radarr carga.
- [ ] API responde `200` con `X-Api-Key` correcta y `401` sin ella.
- [ ] Bind mounts `/config`, `/downloads`, `/movies` montados RW dentro del contenedor con permisos correctos (`homelab:media` 2775 en `/downloads` y `/movies`).
- [ ] Hardlink entre `/downloads/complete/<x>` y `/movies/<y>` funciona (nlink>=2 con mismo inodo).
- [ ] Download Client Transmission añadido con categoría `movies-radarr` y `Test` en verde.
- [ ] Root Folder `/movies` añadido y escribible.
- [ ] Indexadores propagados desde Prowlarr (lista no vacía).
- [ ] Notifications (Telegram o equivalente) configurado.
- [ ] `RADARR_API_KEY` está en `/mnt/hd2t/services/radarr/.env` (chmod 600).
- [ ] Tras reboot, Radarr arranca solo y las películas siguen registradas.

---

## 9. Backup

### 9.1. Qué se respalda y qué no

| Ruta | Backup | Por qué |
|---|---|---|
| `/mnt/hd2t/services/radarr/config/radarr.db` | **Sí** (vía `sqlite3 .backup`) | BD principal: películas, monitorización, history, quality profiles, indexers sincronizados, download client, custom formats. Sin esto se pierde toda la biblioteca catalogada (los ficheros físicos en `/movies/` siguen ahí, pero hay que re-añadir cada peli y re-vincular cada fichero — horas de trabajo manual). |
| `/mnt/hd2t/services/radarr/config/radarr.db-shm` / `-wal` | No (parte del backup atómico) | Ficheros WAL de SQLite. `sqlite3 .backup` consolida WAL en `.db` antes de copiar. |
| `/mnt/hd2t/services/radarr/config/config.xml` | **Sí** | API key, port, log level, branch. Recuperarlo permite que Prowlarr siga funcionando con la **misma** API key tras restore. Sin esto, hay que rotarla en los dos extremos. |
| `/mnt/hd2t/services/radarr/config/Backups/*.zip` | **Sí** (regenerable, pero barato) | Backups internos de Radarr. Borg los deduplica entre runs. ~5 MB cada uno × 4 = 20 MB. Gratis incluirlos. |
| `/mnt/hd2t/services/radarr/config/MediaCover/` | No (regenerable) | Posters/fanart cacheados por película. Radarr los redescarga al detectar falta. ~5 MB por película × 200 pelis = 1 GB; no merece backup. |
| `/mnt/hd2t/services/radarr/config/MediaInfo/` | No (regenerable) | Cache de metadata extraída de los `.mkv`. Radarr la regenera con `Refresh Movie`. |
| `/mnt/hd2t/services/radarr/config/logs/` | No (regenerable) | Logs operacionales. No tienen valor histórico fuera de debug puntual. |
| `/mnt/hd2t/services/radarr/.env` | **Sí** (vía `/mnt/hd2t/backups/configs/`) | Contiene `RADARR_API_KEY` y `TRANSMISSION_RPC_PASSWORD`. Sin esto, hay que rotarlas y reconfigurar Prowlarr y Radarr → Download Clients. |
| `/mnt/hd2t/media/movies/` | **Política aparte** | Ver [`../07-backups/01-estrategia-backup.md`](../07-backups/01-estrategia-backup.md). Por defecto **excluida** del backup primario por tamaño (cientos de GB de re-descargables). El operador puede activar backup parcial de "favoritas" con un patrón Borg explícito. |
| `/mnt/hd2t/media/movies/.recycle/` | No | Excluida explícitamente — son ficheros que el operador eligió borrar. |

### 9.2. Patrón Borgmatic — respaldo SQLite

Coherente con [`../07-backups/03-backup-docker-volumes.md`](../07-backups/03-backup-docker-volumes.md) §4.8 ("Servicios SQLite simples"). El hook pre-backup hace `sqlite3 radarr.db ".backup '/tmp/radarr.bak'"` para evitar copia inconsistente:

`~/homelab/stacks/borgmatic/borgmatic.d/radarr.yaml` (o sección dentro del config global de Borgmatic):

```yaml
# Sección dentro del config global. Coherente con ../07-backups/03-backup-docker-volumes.md §4.8.

before_backup:
  - sudo -u homelab docker exec radarr sh -c \
      'sqlite3 /config/radarr.db ".backup /config/Backups/radarr-prebackup.db"'

source_directories:
  # ... otras rutas ...
  - /mnt/hd2t/services/radarr/config

# La BD viva (con WAL en uso) sigue siendo respaldada por el include genérico,
# pero Borg deduplica frente a la copia consistente de Backups/radarr-prebackup.db.

exclude_patterns:
  - /mnt/hd2t/services/radarr/config/logs
  - /mnt/hd2t/services/radarr/config/MediaCover
  - /mnt/hd2t/services/radarr/config/MediaInfo
  - /mnt/hd2t/media/movies/.recycle
```

### 9.3. Restore (resumen)

```bash
# 1. Parar el contenedor.
docker compose -f ~/homelab/stacks/radarr/docker-compose.yml stop

# 2. Mover el config actual a un lado (por seguridad).
sudo mv /mnt/hd2t/services/radarr/config /mnt/hd2t/services/radarr/config.old

# 3. Restaurar /mnt/hd2t/services/radarr/config/ desde Borg.
borgmatic extract --archive latest \
  --path /mnt/hd2t/services/radarr/config \
  --destination /

# 4. Restaurar el .env.
borgmatic extract --archive latest \
  --path /mnt/hd2t/services/radarr/.env \
  --destination /

# 5. Si la BD viva quedó corrupta tras el `mv`, restaurar la consistente:
sudo cp /mnt/hd2t/services/radarr/config/Backups/radarr-prebackup.db \
        /mnt/hd2t/services/radarr/config/radarr.db

# 6. Levantar de nuevo.
docker compose -f ~/homelab/stacks/radarr/docker-compose.yml up -d

# 7. Verificar.
docker run --rm --network homelab curlimages/curl:latest \
  -H "X-Api-Key: ${RADARR_API_KEY}" \
  http://radarr:7878/api/v3/movie | jq 'length'
# Número esperado de películas.

# 8. Borrar el config.old si todo OK.
sudo rm -rf /mnt/hd2t/services/radarr/config.old
```

### 9.4. Smoke test mensual de restore

```bash
sudo rm -rf /tmp/restore_test
mkdir -p /tmp/restore_test
borgmatic extract --archive latest \
  --path /mnt/hd2t/services/radarr/config \
  --destination /tmp/restore_test

# Verificar que radarr.db es válida sin levantarla en producción:
sqlite3 /tmp/restore_test/mnt/hd2t/services/radarr/config/radarr.db \
  "SELECT count(*) FROM Movies;"
# > 0   (al menos una peli)

sqlite3 /tmp/restore_test/mnt/hd2t/services/radarr/config/radarr.db \
  "SELECT count(*) FROM Movies WHERE MovieFileId > 0;"
# Número de películas con fichero importado.

# Verificar config.xml:
grep '<ApiKey>' /tmp/restore_test/mnt/hd2t/services/radarr/config/config.xml
# <ApiKey>...</ApiKey>

sudo rm -rf /tmp/restore_test
```

---

## 10. Operaciones cotidianas

### 10.1. Upgrade automático (Watchtower)

Política en [`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md): Watchtower revisa `lscr.io/linuxserver/radarr:5.14.0.9383-ls248` cada noche, compara digest de ese tag exacto y actualiza si LSIO ha re-publicado el tag (típicamente cuando hay un patch de seguridad del *base image*). Si el operador quiere saltar a `5.15.x`, edita `RADARR_IMAGE_TAG` en `.env`, hace `docker compose pull && docker compose up -d` y revisa logs por si hubiera migración. Radarr 5.x es compatible hacia delante; el `radarr.db` no rompe.

```bash
# Lista de upgrades aplicados por Watchtower:
docker logs watchtower 2>&1 | grep -i radarr | tail -20
```

### 10.2. Añadir una película nueva

UI: `Movies → [+] → Add New` → buscar título → seleccionar → configurar (Quality Profile, Minimum Availability, Monitor) → `Add Movie`.

Por API (útil para scripts):

```bash
# Buscar el TMDb ID de la película:
docker run --rm --network homelab curlimages/curl:latest \
  -H "X-Api-Key: ${RADARR_API_KEY}" \
  "http://radarr:7878/api/v3/movie/lookup?term=Inception" \
  | jq '.[0] | {title, tmdbId, year}'
# {"title":"Inception","tmdbId":27205,"year":2010}

# Añadir la peli:
docker run --rm --network homelab curlimages/curl:latest \
  -H "X-Api-Key: ${RADARR_API_KEY}" \
  -H 'Content-Type: application/json' \
  -X POST http://radarr:7878/api/v3/movie \
  --data-binary @- <<'EOF'
{
  "tmdbId": 27205,
  "title": "Inception",
  "year": 2010,
  "qualityProfileId": 1,
  "rootFolderPath": "/movies",
  "monitored": true,
  "minimumAvailability": "released",
  "addOptions": {"searchForMovie": true}
}
EOF
```

### 10.3. Buscar manualmente una película que no llega

Cuando una peli no se descarga automáticamente (RSS Sync no encontró release adecuado):

```
Movies → [película] → Manual Search

Radarr lista todas las releases disponibles desde los indexadores activos
con su score (calidad + custom formats).
Click "Download" en la release deseada.
```

Por API:

```bash
# Buscar releases (Manual Search):
docker run --rm --network homelab curlimages/curl:latest \
  -H "X-Api-Key: ${RADARR_API_KEY}" \
  "http://radarr:7878/api/v3/release?movieId=12345" \
  | jq '.[] | {title, indexer, size, seeders, customFormats: [.customFormats[].name]}'

# Trigger una búsqueda automática de la peli:
docker run --rm --network homelab curlimages/curl:latest \
  -H "X-Api-Key: ${RADARR_API_KEY}" \
  -X POST http://radarr:7878/api/v3/command \
  -H 'Content-Type: application/json' \
  -d '{"name":"MoviesSearch","movieIds":[12345]}'
```

### 10.4. Importar manualmente un fichero ya descargado (Library Import)

Si el operador tiene películas fuera del control de Radarr (descargadas a mano, ripeadas de Blu-ray):

```
1. Copiar los ficheros a /mnt/hd2t/media/movies/<Title> (Year)/<Title> (Year).mkv
   (o al directorio donde Radarr ya tenga la peli, o a /movies/ a pelo).

2. UI → Wanted → Manual Import → seleccionar carpeta → Radarr identifica
   las películas por nombre + año + fingerprint y las enlaza.

3. Si el reconocimiento es ambiguo, ajustar manualmente la peli (TMDb lookup).

4. Click "Import" → Radarr renombra y mueve.
```

### 10.5. Corregir una película mal nombrada o mal importada

```
Movies → [película] → "..." menu → Manage / Edit Movie

- Si el fichero tiene mal nombre: click "Rename" → Radarr aplica el formato.
- Si el fichero está mapeado a otra peli (caso típico: trailer de "Inception"
  importado como la peli completa): borrar el File desde la UI,
  re-importar manualmente con "Manual Import".
- Si la peli entera no existe en TMDb (fan edit, peli muy oscura):
  añadirla manualmente en TMDb (requiere cuenta y revisión moderadores).
```

### 10.6. Rotar la API key o la password de Transmission RPC

Cuando el operador sospeche compromiso:

#### 10.6.1. Rotar `RADARR_API_KEY`

```
UI → Settings → General → Security → API Key → [Reset] → Save → Reload
```

Tras esto:

1. Prowlarr **fallará** al sincronizar hasta que el operador actualice `Prowlarr → Apps → Radarr → ApiKey`.
2. Bazarr (si está) idem.
3. Leer la nueva key del `config.xml` y actualizar el `.env`:

```bash
NEW_KEY=$(sudo grep '<ApiKey>' /mnt/hd2t/services/radarr/config/config.xml \
  | sed -E 's,.*<ApiKey>([^<]+)</ApiKey>.*,\1,')
sudo sed -i \
  -e "s|^RADARR_API_KEY=.*|RADARR_API_KEY=${NEW_KEY}|" \
  /mnt/hd2t/services/radarr/.env
```

4. Actualizar Prowlarr → Apps → Radarr → ApiKey con `NEW_KEY`. Reiniciar Prowlarr para descartar caches: `docker compose restart prowlarr`.

#### 10.6.2. Rotar `TRANSMISSION_RPC_PASSWORD`

Si se rota la password de Transmission ([`./01-transmission.md`](./01-transmission.md) §10.6):

1. Actualizar el `.env` de Radarr:

```bash
NEW_TRPC_PASS=$(sudo grep '^TRANSMISSION_RPC_PASSWORD=' \
  /mnt/hd2t/services/transmission/.env | cut -d= -f2-)
sudo sed -i \
  -e "s|^TRANSMISSION_RPC_PASSWORD=.*|TRANSMISSION_RPC_PASSWORD=${NEW_TRPC_PASS}|" \
  /mnt/hd2t/services/radarr/.env
```

2. Actualizar la password en la UI de Radarr: `Settings → Download Clients → Transmission → Password` → pegar nueva → `Test → Save`. (Radarr **no** lee `TRANSMISSION_RPC_PASSWORD` del env directamente; solo de la BD `radarr.db`.)

### 10.7. Library Import inicial (cuando se llega con biblioteca preexistente)

Si el operador despliega Radarr con `/mnt/hd2t/media/movies/` ya poblado (de un homelab anterior, descargas manuales, ripeos):

```
UI → Wanted → Manual Import → seleccionar /movies/

Radarr escanea, identifica cada carpeta de película, busca en TMDb,
y propone las pelis detectadas con sus ficheros.

Click "Import All" tras revisar.
```

Tras el import inicial, Radarr empieza a monitorizar películas (si están marcadas como `Monitored: yes`) y a buscar upgrades de calidad. Recomendación: revisar la History en los primeros días para detectar pelis mal identificadas.

### 10.8. Mass Editor — cambiar Quality Profile en bloque

```
UI → Movies → Mass Editor

Seleccionar pelis → cambiar Quality Profile / Monitor / Root Folder /
Minimum Availability en bloque → Apply.
```

Útil cuando se decide cambiar de 720p a 1080p para toda la biblioteca: `Mass Editor → seleccionar todas → Quality Profile: HD-1080p → Apply`. Radarr empezará a buscar upgrades para las pelis ya descargadas.

### 10.9. Calendar y Discover

Radarr v5 incluye dos vistas que en Sonarr son menos prominentes:

- **Calendar** (`Calendar` en la barra lateral): muestra pelis monitorizadas con fecha de estreno cercana (cines / disco / streaming según el provider de TMDb). Útil para "recordar" pelis que están a punto de salir en disco.
- **Discover** (`Movies → Discover`): recomendaciones basadas en TMDb popular / TMDb top rated / "similar to" de pelis ya en biblioteca. Una forma rápida de añadir pelis sin saber el título exacto.

Ambas son view-only — añadir desde ahí simplemente abre el `Add New` de §10.2.

### 10.10. Lists — auto-añadir desde IMDb/TMDb/Trakt (opt-in)

**Lists** es la feature más distintiva de Radarr respecto a Sonarr (Sonarr no las tiene en el mismo formato). Radarr puede importar listas externas y **auto-añadir** todas las películas de la lista a la biblioteca, monitorizándolas automáticamente.

**No por defecto** porque puede saturar la cola si la lista tiene 1000+ pelis y Quality Profile es UHD-2160p. Si el operador quiere activarlo:

```
Settings → Lists → [+] → IMDb List

Name:           IMDb Top 250
URL/IMDB List:  ls004273781   (Top 250 oficial)
Enabled:        Yes
Monitor:        Movie Only
Search on Add:  No   (recomendado: añadir sin buscar; el RSS sync los pillará)
Quality Profile: HD-1080p
Minimum Availability: Released
```

Tipos de Lists soportadas:

| Tipo | Ejemplo | Notas |
|---|---|---|
| **IMDb List** | `ls004273781` (Top 250) | Lista pública o privada (con auth IMDb). Útil para curaduría comunitaria. |
| **IMDb Watchlist** | usuario IMDb | El "Watchlist" del propio usuario IMDb. Requiere ID público. |
| **TMDb List** | ID de lista TMDb | Listas curadas por usuarios TMDb (incluye listas oficiales como "Marvel Cinematic Universe"). |
| **TMDb Popular** | (sin parámetro) | Top 100 popular del momento según TMDb. Se actualiza diariamente. |
| **TMDb Top Rated** | (sin parámetro) | Top rated histórico. |
| **Trakt User List** | usuario Trakt | Listas de Trakt.tv. Requiere autorización OAuth (Trakt API). |
| **Trakt Popular** | (varios) | Trending, popular, watched. |
| **StevenLu** | (popular) | Lista curada de StevenLu (https://github.com/sjlu/popular-movies). Pelis "que merece la pena ver" según consenso. |

Política recomendada: empezar con **una sola lista de tamaño moderado** (StevenLu Popular tiene ~50 pelis, manejable). Si la cola y la calidad de las descargas son razonables tras una semana, añadir otras.

### 10.11. Logs

```bash
# En vivo:
docker logs -f radarr

# Logs persistidos en /config/logs/:
docker exec radarr ls -lh /config/logs/
# radarr.txt           (log actual)
# radarr.txt.0         (último rotado)
# radarr.debug.txt     (si Log Level >= Debug)
# update.txt           (log de upgrades internos, irrelevante en Docker)
```

LSIO redirige los logs internos al stdout del contenedor, donde Docker los captura y Dozzle los muestra. No hace falta tocar `/config/logs/` salvo para grep histórico.

### 10.12. Comportamiento durante mantenimiento

- **Pi-hole caído**: Radarr no resuelve dominios externos (TMDb, Skyhook), las búsquedas de metadata fallan. **No corrompe nada**: las búsquedas vuelven al recuperar Pi-hole.
- **Caddy caído**: la UI no es accesible, pero **Radarr sigue funcionando**: descarga, importa y notifica. Prowlarr sigue sincronizando porque va por la red interna `homelab`.
- **Prowlarr caído**: Radarr **no puede buscar nuevas pelis** (no tiene indexadores activos). Las descargas en curso y los imports siguen.
- **Transmission caído**: Radarr **no puede enviar nuevas descargas** ("Unable to connect to Transmission" en la History). Pelis marcadas como "Wanted" se quedan en cola; al recuperar Transmission, RSS Sync los retoma.
- **Sonarr caído**: irrelevante para Radarr — son independientes.
- **`radarr.db` corrupta** (raro pero posible si el host pierde corriente sin parar limpio): Radarr se niega a arrancar con `Malformed database`. Restaurar desde `/config/Backups/radarr-prebackup.db` (§9.3 paso 5).

---

## 11. Solución de Problemas

| Síntoma | Causa probable | Diagnóstico / Fix |
|---|---|---|
| `https://radarr.lan` muestra "502 Bad Gateway" en Caddy | Contenedor Radarr caído o `unhealthy`. | `docker compose ps`, `docker logs radarr`. |
| Authelia no aparece al ir a `radarr.lan`; va directo al login de Forms | El bloque `forward_auth` no está en el `Caddyfile`, o Caddy no se recargó. | Verificar `~/homelab/stacks/proxy/Caddyfile` §6.1, recargar `docker exec proxy caddy reload --config /etc/caddy/Caddyfile`. |
| Tras login Authelia, la UI de Radarr pide login de Forms | La cookie de Forms no se ha establecido aún. Hacer login una vez y luego la cachea 30 días. | Normal en el primer acceso. Si persiste tras hacer login: comprobar que el dominio del cookie es `radarr.lan` y que el navegador acepta cookies. |
| Prowlarr no puede sincronizar con Radarr ("Unable to connect") | API key mal configurada en Prowlarr → Apps, o `Trusted Proxies` no incluye `172.20.0.0/24`. | `docker exec prowlarr curl -H "X-Api-Key: $RADARR_API_KEY" http://radarr:7878/api/v3/system/status`. Si devuelve 200, la conexión es OK; si 401, la key está mal. |
| `Settings → Download Clients → Test` falla con "Unable to connect" | Transmission no está corriendo o no está en la red `homelab`. | `docker network inspect homelab` debe listar tanto `radarr` como `transmission`. Si no, verificar `networks: [homelab]` en ambos compose. |
| `Settings → Download Clients → Test` falla con "Unauthorized" | Password RPC mal copiada. | Comparar `TRANSMISSION_RPC_PASSWORD` en `/mnt/hd2t/services/transmission/.env` y la password introducida en la UI de Radarr (Settings → Download Clients → Transmission). |
| Películas descargan pero no se importan ("Unable to import: file is locked") | Transmission sigue seedeando con el fichero abierto, y Radarr intenta hacer `cp` (no hardlink). Indica que Hardlinks están desactivados o que `/downloads` y `/movies` están en filesystems distintos. | UI → Settings → Media Management → `Use Hardlinks instead of Copy` = `Yes`. Verificar `df -T /mnt/hd2t/downloads /mnt/hd2t/media/movies` muestra el mismo `Filesystem`. |
| Películas descargan pero se duplica el espacio | Hardlinks desactivados. | Mismo fix que el anterior. Para los ya duplicados: borrar manualmente desde `complete/` (con cuidado de no romper torrents activos). |
| Radarr importa el trailer en vez de la peli | El release tenía un fichero `Movie.Trailer.mkv` y otro `Movie.mkv`, y Radarr eligió el más pequeño. | UI → Settings → Media Management → `Importing → Minimum Free Space`: 100 MB no resuelve esto. Mejor: añadir una Custom Format que penalice ficheros < 500 MB en Quality Profile, o esperar la importación y reasignar manualmente con Manual Import. Radarr v5.6+ tiene un detector de trailers/samples mejor que las versiones anteriores. |
| Radarr renombra a `Movie.2010.mkv` (no aplica el formato Plex) | `Rename Movies = No` en Settings → Media Management. | Cambiar a `Yes`, luego `Library → Mass Editor → Rename Files` para los ya importados. |
| Imports fallan con "Permission denied" en `/movies/` | El bit `setgid` de `/mnt/hd2t/media/movies/` se perdió, o un fichero fue creado por otro UID/GID antes de configurar `setgid`. | `sudo chmod 2775 /mnt/hd2t/media/movies` y `sudo chgrp -R media /mnt/hd2t/media/movies` para arreglar lo existente. |
| Radarr ocupa > 1.2 GB de RAM | Mass Editor con cientos de pelis, RSS Sync de una biblioteca enorme, o Lists con 1000+ pelis sin filtro. | `docker compose restart radarr`. Si recurre, subir `mem_limit` a `2048m` o desactivar Lists temporalmente. |
| `database is locked` en logs al arrancar | Otro Radarr antiguo no parado, o un `sqlite3` interactivo abierto. | `docker compose down`, `lsof /mnt/hd2t/services/radarr/config/radarr.db` para ver quién la abre, matar ese proceso, `docker compose up -d`. |
| `Malformed database` en logs | Corrupción de `radarr.db` (típicamente tras un kill -9 o un corte de luz). | Restaurar desde `/config/Backups/radarr-prebackup.db` (§9.3 paso 5) o desde Borg. |
| RSS Sync no encuentra nada aunque hay pelis disponibles | Quality Profile demasiado restrictivo (solo `Bluray-2160p`, no hay), Custom Formats con score muy negativo, o Language filter excluyente. | UI → Wanted → Missing → click peli → Manual Search. Comparar releases ofrecidas vs Quality Profile activo. |
| Tras un `docker compose down && up`, las pelis aparecen pero sin fichero importado | El bind mount de `/config` no es correcto o el `chown` del entrypoint LSIO no terminó antes del crash. | Verificar `docker exec radarr ls -la /config/` que muestra `radarr.db` con owner `abc:abc` (UID 1000, GID 1100). Si está como `root:root`, el contenedor no tuvo permisos para `chown` (revisar `/mnt/hd2t/services/radarr/config/` en el host: debe ser `homelab:homelab 750`). |
| `config.xml` tiene `<ApiKey></ApiKey>` vacío tras un restore | El restore vino de un backup antes del primer arranque. | Levantar Radarr (regenera la API key). Leer la nueva, actualizar `.env`. Si Prowlarr/Bazarr ya estaban configurados con la antigua, rotar también allí. |
| "Health Issue: No indexers available with RSS sync enabled" | Radarr no tiene indexadores. | Verificar que Prowlarr está corriendo y registrado en `Prowlarr → Apps → Radarr` (§7.10). Forzar sync desde Prowlarr UI. |
| "Health Issue: Download client is set to remove completed downloads" | Transmission borra los torrents al terminar (incompatible con hardlinks: el .torrent se va antes de que Radarr importe). | UI → Radarr → Settings → Download Clients → Transmission → `Remove Completed`: `No`. Radarr gestiona el ciclo de vida (mueve a `.recycle/` cuando ya no se necesita). |
| "Health Issue: Branch is for a different app" | El operador cambió `Branch` a `develop` y descargó la build de develop, pero en Docker el branch lo gestiona LSIO. | Settings → General → Updates → Branch: `master`. |
| Lista importada de IMDb/TMDb tarda horas en procesar | Lista con 500+ pelis, Radarr resuelve TMDb metadata 1 a 1. | Esperar (procesa ~1 peli/seg con TMDb behind Cloudflare). Si en producción molesta, `Settings → Lists → [lista] → Enabled: No` y reactivar fuera de horas pico. |

---

## 12. Variantes opt-in

### 12.1. Bazarr — subtítulos automáticos (compartido con Sonarr)

**Bazarr** complementa a Sonarr/Radarr buscando subtítulos en OpenSubtitles, Subscene, Addic7ed, etc. para las pelis y series ya descargadas. **No es parte del MVP** del homelab; se documenta aquí por ser la integración natural más común.

Si Bazarr ya fue desplegado al hacer Sonarr ([`./03-sonarr.md`](./03-sonarr.md) §12.1), **no hay que crear otro** — el mismo Bazarr atiende a las dos instancias. Solo configurar:

```
Bazarr UI → Settings → Radarr

Address:        radarr
Port:           7878
URL Base:       (vacío)
API Key:        ${RADARR_API_KEY}
SSL:            Off
```

Tras `Test → Save`, Bazarr empieza a sincronizar la lista de pelis con Radarr y a buscar subs.

Si el operador no había desplegado Bazarr todavía, levantarlo desde el stack de Sonarr ([`./03-sonarr.md`](./03-sonarr.md) §12.1) — el bind mount `- /mnt/hd2t/media/movies:/movies` ya está incluido en el ejemplo de allí.

Caddy: añadir bloque `bazarr.{$LAN_DOMAIN}` con `forward_auth` a Authelia (mismo patrón que §6.1).

### 12.2. Múltiples instancias (Radarr 4K, Radarr Anime)

El patrón "*arr stack split" usa **dos Radarr en paralelo**: uno para `HD-1080p` (estándar) y otro para `2160p` (4K), cada uno con su propia BD y Quality Profile. Ventaja: separar bibliotecas evita re-descargar 4K cuando el operador solo quería 1080p. Desventaja: doble RAM, doble mantenimiento.

Stack alternativo:

```yaml
services:
  radarr-4k:
    image: lscr.io/linuxserver/radarr:${RADARR_IMAGE_TAG}
    container_name: radarr-4k
    hostname: radarr-4k
    # ... igual que radarr, pero con:
    volumes:
      - /mnt/hd2t/services/radarr-4k/config:/config
      - /mnt/hd2t/downloads:/downloads
      - /mnt/hd2t/media/movies-4k:/movies   # biblioteca aparte
      - /etc/localtime:/etc/localtime:ro
```

Caddy: `radarr-4k.{$LAN_DOMAIN}`. Prowlarr → Apps → registrar las dos instancias con tags distintos (`movies-radarr-1080p`, `movies-radarr-4k`) para que Prowlarr filtre indexadores 4K-only solo a `radarr-4k`. La categoría en Transmission también debería ser distinta (`movies-radarr-4k`) para evitar choques.

**No por defecto** porque la mayoría de operadores se conforman con un Quality Profile que tolere 1080p y 4K en la misma peli según disponibilidad — y porque la Pi 5 no transcodifica 4K, así que tener una biblioteca 4K que Jellyfin no puede direct-play en una TV no-HDR es desperdicio de espacio.

Para anime cinematográfico (Studio Ghibli, anime films) la práctica habitual es **registrar las pelis en la misma instancia** y usar tags de Prowlarr (filtrar AnimeTosho/Nyaa solo a un subset de pelis con tag `anime`). Lista de Custom Formats curada para anime cinematográfico en TRaSH-Guides.

### 12.3. Custom Formats avanzadas (Atmos, IMAX Enhanced, HDR matrix, x265)

El catálogo público [TRaSH-Guides Radarr](https://trash-guides.info/Radarr/) define un set de Custom Formats curado por la comunidad para escenarios específicos:

- "Atmos / TrueHD" — preferir audio Dolby Atmos.
- "IMAX Enhanced" — preferir versiones IMAX.
- "HDR formats" — separar HDR10 / HDR10+ / Dolby Vision profile 5/7/8 / SDR.
- "x265 HD" — preferir x265 en HD (ahorrar espacio sin perder calidad visible).
- "Hybrid" / "Repack" / "Proper" — preferir versiones corregidas.
- "Bad releases" — penalizar grupos conocidos por reencodes malos (LAMA, RARBG, YIFY).

Importarlas:

```
UI → Settings → Custom Formats → Import → pegar el JSON de TRaSH-Guides.
```

Asignarlas a Quality Profiles con scores positivos (preferir) o negativos (penalizar).

Recomendación: empezar con HD-1080p simple, dejar que el operador rode el stack 1-2 meses y luego importar Custom Formats avanzadas según necesidad real. Para sincronización automática de TRaSH-Guides ver §12.8.

### 12.4. Permitir API directa (apps móviles) sin Authelia

Si el operador usa nzb360 / LunaSea / Radarr Companion desde el móvil con la URL Tailscale (`radarr.${TS_DOMAIN}`), Authelia delante rompe la app móvil (las apps no manejan el cookie SSO). Solución: permitir `/api/...` y `/ping` sin Authelia, mantener la UI con Authelia:

`Caddyfile`:

```caddy
radarr.{$TS_DOMAIN} {
    import tailscale_tls radarr
    import security_headers

    # API y ping: sin Authelia. Radarr exige X-Api-Key igualmente.
    @api path /api/* /ping
    handle @api {
        reverse_proxy http://radarr:7878 {
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
        reverse_proxy http://radarr:7878 {
            header_up X-Forwarded-Proto https
            header_up X-Real-IP {remote_host}
        }
    }
}
```

**Análisis de seguridad**: la API key de Radarr es de 32 chars hex (~128 bits de entropía). Sin lockout, un atacante podría intentar fuerza bruta — pero a 1000 reqs/seg necesitaría 10^33 años. Es seguro en la práctica.

**Limitaciones**: la app móvil debe configurarse con la API key directamente. Si el operador rota la API key (§10.6), hay que actualizarla en cada app.

### 12.5. Notificaciones avanzadas a Telegram con Custom Script

Para granularidad mayor que las notifications nativas:

`Settings → Connect → [+] → Custom Script`:

```bash
sudo install -d -o homelab -g homelab -m 750 \
  /mnt/hd2t/services/radarr/config/scripts

sudo tee /mnt/hd2t/services/radarr/config/scripts/notify-telegram.sh > /dev/null <<'EOF'
#!/bin/sh
# Variables expuestas por Radarr:
#   radarr_eventtype, radarr_movie_title, radarr_movie_year,
#   radarr_moviefile_quality, radarr_moviefile_path, ...
case "$radarr_eventtype" in
  Download|Upgrade)
    TG_BOT="${TELEGRAM_BOT_TOKEN}"
    TG_CHAT="${TELEGRAM_CHAT_ID}"
    MSG="🎬 Radarr: ${radarr_movie_title} (${radarr_movie_year}) [${radarr_moviefile_quality}] importada"
    curl -s -X POST "https://api.telegram.org/bot${TG_BOT}/sendMessage" \
      -d chat_id="${TG_CHAT}" \
      -d text="${MSG}"
    ;;
  HealthIssue)
    TG_BOT="${TELEGRAM_BOT_TOKEN}"
    TG_CHAT="${TELEGRAM_CHAT_ID}"
    curl -s -X POST "https://api.telegram.org/bot${TG_BOT}/sendMessage" \
      -d chat_id="${TG_CHAT}" \
      -d text="⚠️ Radarr: ${radarr_health_issue_message}"
    ;;
esac
EOF
sudo chmod +x /mnt/hd2t/services/radarr/config/scripts/notify-telegram.sh
```

Luego en la UI: `Connect → Custom Script → /config/scripts/notify-telegram.sh`. Triggers: `On Import`, `On Upgrade`, `On Health Issue`.

### 12.6. Quitar Authelia para uso solo en LAN cableada confiada

No recomendado. Si el operador insiste:

```caddy
radarr.{$LAN_DOMAIN} {
    import lan_internal_tls
    import security_headers
    # forward_auth http://authelia:9091 ...   ← comentado
    reverse_proxy http://radarr:7878
}
```

La auth nativa de Forms queda como única defensa. Tiene rate-limit interno pero carece de 2FA. Por eso Authelia es el default.

### 12.7. Acceso solo desde Tailscale (sin LAN)

Si el operador no quiere `radarr.lan` accesible en LAN (modelo "trabajo solo desde Tailscale"), eliminar el bloque `radarr.{$LAN_DOMAIN}` del `Caddyfile` y dejar solo el de Tailscale (§6.6). El stack interno sigue funcionando (Prowlarr lo ve por nombre).

### 12.8. Importar quality profiles de TRaSH-Guides con recyclarr

[TRaSH-Guides](https://trash-guides.info/Radarr/) ofrece configuraciones tuneadas (Custom Formats + Quality Profiles + Naming) para escenarios específicos. La forma "ninja" de aplicarlas es vía [recyclarr](https://github.com/recyclarr/recyclarr), un sidecar que sincroniza la BD de Radarr con un YAML versionable:

```yaml
# ~/homelab/stacks/recyclarr/recyclarr.yml
radarr:
  homelab:
    base_url: http://radarr:7878
    api_key: !env_var RADARR_API_KEY
    quality_definition:
      type: movie
    custom_formats:
      # TRaSH HD Bluray + WEB
      - trash_ids:
          - ed38b889b31be83fda192888e2286d83   # BR-DISK
          - 90a6f9a8e697e1382172a4af631fa180   # x265 (HD)
        quality_profiles:
          - name: HD-1080p
            score: -10000   # rechazar BR-DISK y x265 en HD-1080p
      # TRaSH Misc
      - trash_ids:
          - 7357cf5161efbf8c4d5d0c30b4815ee2   # Obfuscated
          - 5d96ce331b98e077abb8ceb60553aa16   # DV (WEBDL)
          - 0a3f082873eb454bde444150b70253cc   # Extras
        quality_profiles:
          - name: HD-1080p
            score: -10000
```

`recyclarr sync` (cron diario) mantiene Radarr alineado con el YAML. **No por defecto** porque añade complejidad operativa: requiere otro contenedor, gestionar el `recyclarr.yml`, y entender la sintaxis TRaSH. Útil para operadores avanzados que quieran configuraciones reproducibles cross-instance.

El mismo `recyclarr.yml` puede sincronizar Sonarr y Radarr en paralelo, manteniendo ambos alineados con TRaSH-Guides.

### 12.9. Overseerr / Jellyseerr — solicitudes de pelis desde el móvil

Una variante popular: **Jellyseerr** (fork de Overseerr) permite a usuarios no-admin "solicitar" pelis (vía web/móvil con UI tipo Netflix), y la solicitud se reenvía automáticamente a Radarr para descarga. Útil si el homelab tiene varios usuarios (familia) que no deben tener acceso completo a Radarr.

**No por defecto** porque añade un servicio más, otra UI, otra integración con Authelia. Si el operador quiere implementarlo:

```yaml
services:
  jellyseerr:
    image: fallenbagel/jellyseerr:2.7.0
    # ... estándar del homelab ...
    environment:
      LOG_LEVEL: info
    volumes:
      - /mnt/hd2t/services/jellyseerr/config:/app/config
    networks:
      - homelab
    # ... healthcheck ...
```

Configurar Jellyseerr → Settings → Services → Radarr → `http://radarr:7878` con `${RADARR_API_KEY}`. Este patrón se documentaría en su propio doc si se incorpora al MVP — por ahora es una nota.

---

## Referencias

- Documentación oficial Servarr (Radarr): https://wiki.servarr.com/radarr
- Repositorio Radarr: https://github.com/Radarr/Radarr
- Releases upstream: https://github.com/Radarr/Radarr/releases
- Imagen LinuxServer.io: https://docs.linuxserver.io/images/docker-radarr/
- Releases LSIO: https://github.com/linuxserver/docker-radarr/releases
- API v3 (especificación): https://radarr.video/docs/api/
- TheMovieDB (TMDb): https://www.themoviedb.org/
- TRaSH-Guides Radarr (Custom Formats curados): https://trash-guides.info/Radarr/
- recyclarr (sync de TRaSH-Guides): https://github.com/recyclarr/recyclarr
- Bazarr (subtítulos): https://github.com/morpheus65535/bazarr
- Jellyseerr (solicitudes de usuarios): https://github.com/Fallenbagel/jellyseerr
- Watchtower (política del homelab): [`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md)
- Caddy (reverse proxy): [`../03-red/04-caddy.md`](../03-red/04-caddy.md)
- Authelia (SSO + 2FA): [`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md)
- Borgmatic (backup): [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md)
- Backup Docker volumes (SQLite): [`../07-backups/03-backup-docker-volumes.md`](../07-backups/03-backup-docker-volumes.md)
- Estructura de directorios: [`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md)
- Transmission (cliente BitTorrent): [`./01-transmission.md`](./01-transmission.md)
- Prowlarr (indexadores): [`./02-prowlarr.md`](./02-prowlarr.md)
- Sonarr (series de TV): [`./03-sonarr.md`](./03-sonarr.md)
