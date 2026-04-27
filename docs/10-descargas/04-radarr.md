# Radarr (gestor de películas)

## Descripción

Despliegue de **Radarr** como **gestor automatizado de películas** del homelab: vigila la lista de películas _monitorizadas_ del operador, busca nuevos releases contra los _indexers_ centralizados en Prowlarr (`docs/10-descargas/02-prowlarr.md`), entrega los releases que cumplen el _Quality Profile_ a **Transmission** (`docs/10-descargas/01-transmission.md`) como cliente BitTorrent, y, una vez la descarga termina, _importa_ los ficheros desde `/mnt/hd2t/services/transmission/downloads/` a `/mnt/hd2t/services/shared/media/movies/` (la biblioteca que **Jellyfin** lee en `:ro` desde `docs/09-multimedia/01-jellyfin.md`). El paso de _Transmission → biblioteca_ se hace por **hardlink** (cero copia de bytes, cero duplicación de espacio en `hd2t`) gracias a que ambos directorios viven en el mismo _filesystem_ y a que Radarr corre con `MEDIA_GID` como _supplementary group_ para escribir en `/services/shared/media/` con bit `setgid`. Toda la configuración persistente (`/config/config.xml`, `/config/radarr.db` SQLite, `MediaCover/`, _backups_ internos, logs) vive en el disco externo **hd2t** (`/mnt/hd2t/services/radarr/`), pre-creado y reasignado a `1000:1000` en `docs/01-sistema/04-estructura-directorios.md` (paso 7, "Reasignar ownership de los servicios LinuxServer.io").

Este documento **cierra el _stack_ `descargas`** (`~/homelab/descargas/`) estrenado por Transmission, extendido por Prowlarr y Sonarr: añade el contenedor `radarr` al `docker-compose.yml` existente, crea el bloque `radarr.lan` en el `Caddyfile`, **descomenta** la línea `dump_sqlite radarr radarr /config/radarr.db` en `~/homelab/backups/borgmatic/hooks/dump-databases.sh` (Patrón S — SQLite) y deja documentado el _Apps Sync_ desde **Prowlarr → Radarr** (la dirección correcta de la integración) y el _Download Client_ **Radarr → Transmission**, ambos por DNS interno de Docker. Tras este documento, los tres servicios de la familia _\*arr_ del homelab (Prowlarr/Sonarr/Radarr) están desplegados, con sus tres dumps SQLite descomentados en el _hook_ de Borgmatic, y el _stack_ `descargas` queda en estado estable.

Caddy (stack `red`, `docs/03-red/04-caddy.md`) expone Radarr en `https://radarr.lan/` con TLS interno (CA local). Para acceso remoto vía Tailscale (`docs/03-red/05-tailscale.md`), MagicDNS resuelve `pi.<tailnet>.ts.net` y desde ahí el operador llega al mismo backend. Las integraciones internas — Prowlarr poblando _indexers_ en Radarr, Radarr enviando _torrents_ a Transmission — viajan por **DNS interno de Docker** (`http://radarr:7878/`, `http://prowlarr:9696/`, `http://transmission:9091/`), saltándose Caddy y autenticándose por _API key_ o por _basic auth_ según el caso.

> **Alcance**: este documento despliega Radarr con su autenticación nativa de _Forms_ (usuario + contraseña, _cookie_ de sesión) **activada desde el primer arranque** vía `RADARR__AUTH__METHOD=Forms` y `RADARR__AUTH__REQUIRED=Enabled`, configura `RADARR__APP__INSTANCENAME=Radarr`, deja `URL Base` vacía (acceso por _vhost_ propio en Caddy, no por _path_ compartido), añade Radarr al grupo `homelab-media` (vía `group_add`) para que los _hardlinks_ contra `/services/shared/media/` no fallen por permisos, y entrega el _runbook_ de respaldo Patrón S sobre `radarr.db`. **No** delega autenticación a Authelia vía `forward_auth` (rompería el `Apps → Test` de Prowlarr y la API de Jellyfin/Homepage si en algún momento se rutaran por Caddy, y la _Forms auth_ nativa de Radarr ya cubre el caso humano; ver **Decisiones de diseño**). **No** despliega Bazarr (subtítulos, fuera del alcance del homelab por ahora), **no** despliega Recyclarr (sincronización de _Custom Formats_ con TRaSH-Guides, _opt-in_ avanzado que el operador puede añadir después). **No** importa películas previas existentes; la biblioteca arranca vacía y el operador añade películas una a una desde la web UI o vía `Movies → Import`.

> **Recordatorio de red**: Radarr **no se publica al host**. La web UI (`:7878`) la alcanza Caddy por DNS interno de Docker (`radarr:7878` en la red `homelab`). Pi-hole resuelve `radarr.lan → 192.168.1.3` por el _wildcard_ de `02-homelab-local.conf` (ver `docs/03-red/02-pihole.md`). El operador entra siempre por `https://radarr.lan/` (LAN) o por el nombre _MagicDNS_ del nodo Tailscale.

---

## Requisitos previos

- `docs/10-descargas/01-transmission.md` completado: el _stack_ `descargas` (`~/homelab/descargas/`) ya existe, el contenedor `transmission` está `(healthy)` y resuelve por DNS interno como `transmission:9091`. La _basic auth_ está activa (`TRANSMISSION_USER`/`TRANSMISSION_PASS` del `.env`).
- `docs/10-descargas/02-prowlarr.md` completado: Prowlarr está desplegado y `(healthy)`, su `<ApiKey>` está apuntado en el gestor del operador, y resuelve por DNS interno como `prowlarr:9696`.
- `docs/10-descargas/03-sonarr.md` completado: Sonarr está desplegado y `(healthy)`, el _Apps Sync_ Prowlarr → Sonarr funciona y la línea `dump_sqlite sonarr sonarr /config/sonarr.db` está **descomentada** en `~/homelab/backups/borgmatic/hooks/dump-databases.sh`. Radarr replica el patrón de Sonarr — si algún paso aquí parece poco familiar, conviene revisar primero ese documento.
- `docs/01-sistema/04-estructura-directorios.md` completado:
    - `/mnt/hd2t/services/radarr/` ya existe con ownership `1000:1000` (paso 7, "Reasignar ownership de los servicios LinuxServer.io"). **No hay que crear nada**: Radarr poblará la estructura interna (`Backups/`, `logs/`, `MediaCover/`, `radarr.db`, `config.xml`) en el primer arranque.
    - `/mnt/hd2t/services/shared/media/` existe con `root:homelab-media 2775` (bit `setgid`) y el GID de `homelab-media` está en `~/homelab/.env` como `MEDIA_GID`.
- `docs/01-sistema/03-seguridad-base.md` completado: `nftables` con `input drop` por defecto. Este documento **no añade** ninguna regla de _firewall_ — Radarr no publica puertos al host.
- `docs/02-docker/04-watchtower.md` completado: Radarr se etiquetará como **opt-in** explícito (`com.centurylinklabs.watchtower.enable: "true"`), coherente con la lista de "candidatos a _opt-in_ desde el principio" de aquel doc.
- `docs/03-red/02-pihole.md` completado: Pi-hole resuelve `*.lan → 192.168.1.3`. **No hay que añadir nada** para `radarr.lan` — el _wildcard_ ya lo cubre.
- `docs/03-red/04-caddy.md` completado: Caddy escucha en `192.168.1.3:443` con `tls internal`, los _snippets_ `security-headers.caddy` y `logging.caddy` existen, la directiva `import /etc/caddy/snippets/*.caddy` está activa en el `Caddyfile` y la CA local firma `*.lan`.
- `docs/04-seguridad/01-authelia.md` completado **opcionalmente**: si Authelia ya está montada, en este documento se decide explícitamente **no** poner Radarr detrás de `forward_auth`. La lista `two_factor` del `access_control.rules` de Authelia **no incluye** `radarr.lan` (ni siquiera comentado).
- `docs/07-backups/02-borgmatic.md` y `docs/07-backups/03-backup-docker-volumes.md` completados: el `source_directories: /mnt/hd2t/services` ya engloba `radarr/`, y la línea `dump_sqlite radarr radarr /config/radarr.db` ya está **comentada** en `~/homelab/backups/borgmatic/hooks/dump-databases.sh`. Este documento la **descomenta**.
- `docs/09-multimedia/01-jellyfin.md` completado o pendiente: Jellyfin lee `/mnt/hd2t/services/shared/media/` en `:ro`. Si Jellyfin aún no está desplegado no pasa nada — Radarr crea la subcarpeta `movies/` la primera vez que importa una película, y Jellyfin la encontrará cuando se despliegue. Si Jellyfin **sí** está desplegado, tras el primer _import_ exitoso de Radarr se hace _Library → Scan_ desde Jellyfin (o se deja al cron interno).
- Conectividad saliente para descargar la imagen (sólo la primera vez):

  ```bash
  docker pull --platform linux/arm64 lscr.io/linuxserver/radarr:5.7.0 >/dev/null && echo OK
  ```

  El _tag_ exacto se consulta en <https://github.com/linuxserver/docker-radarr/pkgs/container/radarr>; la convención del homelab prohíbe `:latest` (ver `docs/02-docker/02-estructura-compose.md`, sección **Imágenes**).

- Que el host **no** tenga ya un servicio escuchando en `:7878`:

  ```bash
  sudo ss -tulpn '( sport = :7878 )'
  ```

  Salida esperada: vacía. Radarr no publica `:7878` al host (Caddy lo alcanza por DNS interno), pero conviene confirmar que ningún binario residual lo ocupa por si más adelante el operador, durante un _troubleshoot_, añadiese un `ports: ["7878:7878"]` improvisado.

- Co-residencia de `services/transmission/downloads` y `services/shared/media` en el **mismo filesystem**, requisito imprescindible para que los _hardlinks_ de Radarr funcionen:

  ```bash
  stat -c '%m' /mnt/hd2t/services/transmission/downloads /mnt/hd2t/services/shared/media
  # /mnt/hd2t
  # /mnt/hd2t
  ```

  Si los dos montajes devolvieran puntos distintos, los _hardlinks_ caerían silenciosamente a copia (Radarr lo hace pero gasta el doble de espacio en `hd2t`). Revisar `fstab` y montajes antes de seguir. Si Sonarr ya está funcionando con _hardlinks_ en `/media/series/`, este requisito ya está validado de facto.

- Espacio en `/mnt/hd2t`: como mínimo **500 MB libres** para `radarr/` en estado estable. `radarr.db` SQLite con un par de centenares de películas ronda **20-100 MB**, `logs/` con rotación interna **10-50 MB**, `Backups/` internos diarios de Radarr **10-50 MB cada uno**, `MediaCover/` con _posters_/_fanart_ de cada película a varios tamaños puede ocupar **100-300 MB** según la biblioteca.

  ```bash
  df -h /mnt/hd2t
  ```

---

## Decisiones de diseño

### Por qué Radarr (y no CouchPotato / Watcher / mantenimiento manual)

El homelab necesita un gestor automatizado de películas que se integre con Prowlarr (centralización de _indexers_) y con un cliente BitTorrent (Transmission). Tres alternativas evaluadas:

| Candidato       | Por qué se descarta / acepta                                                                                                                                                                                                                                                                                                                                                                                  |
|-----------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **CouchPotato** | Proyecto **abandonado** desde 2018. Sin actualizaciones, sin soporte de Prowlarr, sin compatibilidad con _indexers_ modernos. Descartado de plano.                                                                                                                                                                                                                                                            |
| **Watcher3**    | Fork minimalista, comunidad muy pequeña, integración con Prowlarr inexistente (Prowlarr no lo soporta como _App_). Inviable si la fuente única de _indexers_ es Prowlarr.                                                                                                                                                                                                                                     |
| **Radarr** ✅    | Mantenido por el equipo _Servarr_ (mismos autores que Prowlarr/Sonarr/Lidarr/Readarr). _Apps Sync_ bidireccional con Prowlarr vía API (añadir un _indexer_ en Prowlarr lo propaga a Radarr automáticamente). Soporta Transmission de primera clase. _Custom Formats_ y _Quality Profiles_ son la _state of the art_ para automatizar selección de releases (HDR, _release group_, audio, idioma, codec, etc.). |
| Mantenimiento manual | Operativamente indefendible para más de 5-10 películas al mes. El homelab quiere automatizar el _watch_ de novedades y de la _wishlist_ del operador sin abrir el navegador cada noche.                                                                                                                                                                                                                  |

Radarr es el sucesor natural de CouchPotato y la opción canónica cuando Prowlarr ya está montado y Sonarr funciona. El _footprint_ es similar al de Sonarr (~200-300 MB RAM con una biblioteca pequeña, .NET 6 _runtime_).

### Imagen y _tag_

- **`lscr.io/linuxserver/radarr:5.7.0`** — imagen LSIO (LinuxServer.io) sobre upstream Radarr `5.7.0.x`. _Tag_ "major.minor.patch" pinneado a la versión exacta. Multi-arch (`linux/arm64`).
- **Por qué LSIO**: convención del homelab para servicios que se benefician de `PUID`/`PGID` y `s6-overlay`, igual que el resto de la familia _\*arr_ (Prowlarr, Sonarr, Transmission). La imagen "oficial" de Radarr en Docker Hub (`linuxserver/radarr`, `hotio/radarr`) son las únicas mantenidas activamente; LSIO encaja con todo el resto del homelab.
- **Por qué `5.7.0` y no `:latest` ni `nightly`**: la rama `nightly` recibe _commits_ diarios y a veces _breaking changes_ en el formato del `radarr.db`. La rama `master` (`:latest`) es estable pero el _tag_ corto recibe re-builds del _wrapper_ LSIO varias veces por semana. Pinear al patch concreto convierte cada re-build en una decisión humana — Watchtower (cuando se active el _opt-in_) recoge re-builds del **mismo `5.7.0`** sin cambiar el _tag_; los _bumps_ de patch (`5.7.0 → 5.7.1`) son cambios explícitos en el `.env`. **El operador debe consultar el _tag_ vigente en el momento de desplegar** (referencia abajo) y rellenar `RADARR_IMAGE_TAG` con el más reciente de la rama estable v5.
- **Por qué no la rama `4.x` _legacy_**: Radarr v4 fue reemplazado por v5 en 2023-2024. v5 introduce _Custom Formats_ unificados con Sonarr v4 (TRaSH-Guides los aplica con el mismo formato), un nuevo _scheduler_ y mejoras de _import_ (incluido _hardlink_ atómico que respeta `setgid`). v4 está en _maintenance only_; v5 es la línea estable vigente.

> **Cómo consultar el _tag_ vigente**: <https://github.com/linuxserver/docker-radarr/pkgs/container/radarr>. Los `release notes` de upstream Radarr se siguen en <https://github.com/Radarr/Radarr/releases>; los re-builds del _wrapper_ LSIO en <https://github.com/linuxserver/docker-radarr/releases>.

#### Watchtower **opt-in**

Razones (mismas que Sonarr y Prowlarr):

- **Patches frecuentes sin _breaking changes_** dentro de la rama `5.x`: re-builds semanales con _bug fixes_ del propio Radarr y _security updates_ de la base Alpine.
- **Estado estable dentro de `5.x`**: el formato de `radarr.db` y `config.xml` está congelado dentro de la _minor_. Watchtower puede reciclar el contenedor con seguridad. Las migraciones internas son aditivas.
- **Tolerancia a reinicios**: Radarr es _stateless_ entre arranques excepto por el `radarr.db` y los _backups_ internos diarios. Un reinicio de un par de minutos en la madrugada (ventana Watchtower domingo 04:00 UTC) no afecta operación; los _torrents_ activos en Transmission siguen descargando, y al volver Radarr se sincroniza con la cola de Transmission y procesa los completados.
- **Migraciones de BD automáticas y reversibles**: el _entrypoint_ de Radarr ejecuta `Migrate` sobre `radarr.db` al arrancar; las migraciones internas dentro de la `5.x` son aditivas.

Etiquetar el contenedor con `com.centurylinklabs.watchtower.enable: "true"`.

> **Bumps de _minor_** (`5.7 → 5.8`, `5.x → 6.x`): se hacen **a mano**, fuera de Watchtower. Cambiar `RADARR_IMAGE_TAG=5.8.0` en `~/homelab/descargas/.env`, leer las _release notes_ de upstream y de LSIO, hacer backup del `radarr.db` previo (Borgmatic + dump SQLite), y aplicar `make pull STACK=descargas && make up STACK=descargas`. Watchtower con _tag_ `5.7.0` no salta a `5.8.0` automáticamente porque mira el _digest_ del _tag_ exacto pinneado.

### Modo de red: `bridge` (red `homelab`) sin `ports:` publicados

Decisión opinada y consistente con el resto del homelab. Las dos opciones razonables son las mismas que para Sonarr/Prowlarr (ver `docs/10-descargas/03-sonarr.md` → **Modo de red**); el resumen para Radarr:

| Opción                                     | Ventajas                                                                                       | Inconvenientes                                                                                          |
|--------------------------------------------|------------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------|
| **`network_mode: host`**                   | Trivial: Radarr escucha en `192.168.1.3:7878`. Caddy puede _reverse-proxy_ a `127.0.0.1:7878`. | Rompe el patrón "Caddy delante de cada servicio". Expone la web UI al host: cualquier proceso local pinchea la API sin Caddy. |
| **`bridge` en red `homelab` sin `ports:`** ✅ | Coherente con todos los demás servicios del homelab: Radarr se alcanza por DNS interno (`radarr:7878`), Caddy es el _único_ camino al servicio para humanos, y Prowlarr/Transmission lo alcanzan por nombre. | Un cliente CLI desde la Pi misma sin pasar por Caddy debe usar `docker exec` o llamar a la URL `https://radarr.lan/` con la CA local — apropiado para el homelab. |

Se elige `bridge` con red externa `homelab`. Radarr no necesita ningún puerto publicado al host.

### `forward_auth` con Authelia: **NO** para Radarr

La misma decisión que con Sonarr (`docs/10-descargas/03-sonarr.md` → **`forward_auth` con Authelia: NO**). Razones técnicas concretas para Radarr:

- **Prowlarr habla con Radarr por DNS interno** (`http://radarr:7878/`) saltándose Caddy. Authelia ahí no influye en absoluto. Sería sólo una protección extra para la web UI humana.
- **Jellyfin / Homepage / Homarr (cuando lleguen) consumen la API de Radarr** (calendario de próximos estrenos, _Activity → Queue_, _History_) por DNS interno o eventualmente por Caddy. Si Caddy estuviese protegido por Authelia, las apps clientes (no humanas) tendrían que seguir un flujo de _OIDC_ que **no soportan** — usan _API key_ vía header `X-Api-Key`.
- **Radarr ya tiene autenticación nativa _Forms_** desde la rama `4.x`: el operador la activa en _Settings → General → Security → Authentication: Forms (Login Page)_ con _Authentication Required: Enabled_. La _cookie_ de sesión protege la web UI, y todas las llamadas API requieren un _API key_ que Radarr genera y muestra en el mismo panel. Doble capa nativa, suficiente.

Solución correcta para este homelab: **Radarr autentica con su sistema nativo** (Forms login, _API key_), Caddy actúa como _reverse proxy_ "tonto" que termina TLS y propaga las cabeceras. Si en el futuro se quisiera proteger adicionalmente la UI con Authelia, se podría añadir un _path matcher_ aplicando `forward_auth` sólo a los _paths_ humanos (`/`, `/login`, `/UI/*`) dejando `/api/*` libre — _opt-in_ avanzado, fuera de alcance.

> **Resumen operativo**: el bloque `radarr.lan` del `Caddyfile` lleva `import security-headers` y `import logging`, pero **no** `import authelia`. La sesión Forms (cookie `Radarr-`) protege la UI; el _API key_ protege `/api/*`.

### `URL Base` vacía + acceso por _vhost_ propio

Idéntica decisión que para Sonarr y Prowlarr. Radarr soporta `URL Base = /radarr` para servir bajo un _path_ compartido, pero como cada servicio del homelab tiene su propio _vhost_ (`sonarr.lan`, `radarr.lan`, `prowlarr.lan`, …), **`URL Base` se mantiene vacía**:

- Más simple: ningún _rewrite_ de _path_ en Caddy, ningún ajuste de `app.baseUrl` en el cliente JS de Radarr.
- _Apps Sync_ desde Prowlarr usa _Radarr Server_ = `http://radarr:7878/` (DNS interno), donde no hay _path_; consistente.
- El operador no tiene que recordar diferencias entre el acceso por LAN, Tailscale y DNS interno.

### Volúmenes: `/downloads` (rw) + `/media` (rw, con `MEDIA_GID`)

Radarr necesita ambos:

| Volumen del host                            | Punto de montaje en el contenedor | Modo | Propósito                                                                                                |
|---------------------------------------------|-----------------------------------|------|----------------------------------------------------------------------------------------------------------|
| `/mnt/hd2t/services/radarr/`                | `/config`                         | rw   | `config.xml`, `radarr.db`, `Backups/`, `MediaCover/`, `logs/`                                            |
| `/mnt/hd2t/services/transmission/downloads/`| `/downloads`                      | rw   | Radarr lee aquí los `.mkv` que Transmission ha terminado y los _hardlink_-a a `/media/movies/`           |
| `/mnt/hd2t/services/shared/media/`          | `/media`                          | rw   | Radarr crea/actualiza `/media/movies/<Movie> (<Year>)/<Movie> (<Year>) {Quality}.mkv` por _hardlink_     |

> **Por qué `/downloads` en `rw` y no `:ro`**: Radarr necesita _crear el hardlink en el árbol de la biblioteca_ (`/media/movies/`, no en `/downloads/`), pero **además** la opción _Completed Download Handling → Remove from client when import is successful_ (recomendada, ver **Configuración tras primer arranque**) requiere que Radarr le pida a Transmission que **borre** el `.torrent` finalizado vía RPC; eso lo hace por API HTTP, sin tocar el filesystem. Sin embargo, si en el futuro se activa _Completed Download Handling → Remove files when_ + _Hard delete_, Radarr **sí** borra del filesystem `/downloads/`. Mantener `rw` por simplicidad; la _Categoría C_ del backup (descargas regenerables) ya asume que `/downloads` no es sagrado.

> **Por qué `/media` en `rw`**: Radarr **escribe** la jerarquía `/media/movies/<Movie> (<Year>)/...` por _hardlink_. El _hardlink_ en POSIX es una entrada de directorio nueva apuntando al mismo _inode_; `link(2)` requiere permiso de **escritura** sobre el directorio destino — por eso `:rw` y no `:ro`.

> **`MEDIA_GID` como `group_add`**: el bit `setgid` en `/mnt/hd2t/services/shared/media/` (modo `2775`, grupo `homelab-media`) garantiza que cualquier fichero/directorio nuevo herede el grupo `homelab-media`, no el grupo primario del proceso (`1000`). Pero para _crear_ el fichero, el proceso necesita ser miembro del grupo `homelab-media`. Como Radarr corre con `PGID=1000` (su grupo primario, igual que Sonarr/Transmission y los demás LSIO), hay que añadirle `homelab-media` como _supplementary group_ vía `group_add: ["${MEDIA_GID}"]` en el compose. Sin esto, Radarr lograría leer `/media/movies/` (modo `0755` permite a "otros") pero **fallaría** al crear/escribir con `Permission denied`.

### `radarr.db` (SQLite) — Patrón S de respaldo

Idéntica al esquema de Sonarr y Prowlarr. Radarr usa una BD SQLite (`/config/radarr.db` + `/config/radarr.db-shm` + `/config/radarr.db-wal`) como almacén persistente de:

- _Movies_ monitorizadas, _Quality Profiles_, _Custom Formats_.
- _Indexers_ (poblados por el _Apps Sync_ de Prowlarr; el operador no los toca a mano).
- _Download Clients_ (Transmission con sus credenciales).
- _Lists_ (TMDb collections, IMDb watchlist, Trakt — opcional).
- _History_ y _Activity_ (acotados por retención).
- _Notifications_, _Tags_, _Naming_, _Settings_.

La imagen LSIO incluye `sqlite3` dentro del contenedor — `dump_sqlite` del Patrón S funciona directamente:

```bash
docker exec radarr sqlite3 -version
# 3.40.x ...
```

Por tanto, en `~/homelab/backups/borgmatic/hooks/dump-databases.sh`, la línea para Radarr (que ya existe **comentada** desde `docs/07-backups/03-backup-docker-volumes.md` y que **no** descomentaron `01-transmission.md`, `02-prowlarr.md` ni `03-sonarr.md`) se descomenta tal cual:

```bash
# Antes:
# dump_sqlite radarr   radarr   /config/radarr.db

# Después:
dump_sqlite radarr   radarr   /config/radarr.db
```

Cada _run_ de Borgmatic produce un fichero `radarr-<fecha>.sqlite.gz` en `/mnt/hd2t/backups/dumps/` (Patrón S), que se respalda como cualquier otro fichero. Adicionalmente, el árbol entero `/mnt/hd2t/services/radarr/` entra en `source_directories:` de Borgmatic — esto cubre `config.xml`, `MediaCover/`, `logs/` y los _backups_ internos de Radarr en `Backups/`. Patrón **S** + redundancia de _filesystem_ por si el dump SQLite fallase un día.

### `Backups/` interno de Radarr — se mantiene, no se respalda con prioridad

Radarr genera automáticamente _backups_ internos cada noche en `/config/Backups/scheduled/radarr_backup_*.zip` (con retención de 7 días por defecto). Son _zip_ que contienen `radarr.db` + `config.xml` + carpetas auxiliares.

- **No se desactivan**: son útiles para restauraciones rápidas desde la propia web UI (_System → Backup → Restore_) sin tener que tocar Borgmatic.
- **No se excluyen**: ocupan poco (10-50 MB cada uno), se deduplican muy bien.
- **Frecuencia**: ajustable en _Settings → General → Backups_ (`Backup Interval`, `Backup Retention`). Defaults razonables, no se tocan.

### Calendario de _Apps Sync_: Prowlarr → Radarr (la dirección importa)

Misma lógica que con Sonarr. Tentación natural del recién llegado a la familia _\*arr_: ir a _Radarr → Settings → Indexers → Add → Torznab_ y rellenar URL/_API key_ a mano por cada _indexer_. **No se hace así**. La integración correcta es **inversa**:

1. **Radarr** se despliega sin _indexers_ configurados (este documento).
2. **En Prowlarr**, _Settings → Apps → Add Application → Radarr_, con:
   - _Sync Level_: `Full Sync`.
   - _Prowlarr Server_: `http://prowlarr:9696/` (DNS interno).
   - _Radarr Server_: `http://radarr:7878/` (DNS interno).
   - _API Key_: el `<ApiKey>` de **Radarr** (no el de Prowlarr — ver **Configuración tras primer arranque**, paso 2).
3. Tras `Test` → `Save`, Prowlarr **propaga** automáticamente cada _indexer_ aplicable a Radarr. El operador **no toca** _Radarr → Settings → Indexers_; aparece todo poblado.

Este orden se concreta en **Configuración tras primer arranque** → paso 5. La razón estructural: si el operador añade _indexers_ manualmente en Radarr antes de hacer el _Apps Sync_, Prowlarr no los reconoce como suyos y duplica entradas; o peor, sobreescribe credenciales si se confunden los nombres. **Una sola fuente de verdad para indexers: Prowlarr.**

### Ubicación de la biblioteca: `/media/movies/`

El árbol `/mnt/hd2t/services/shared/media/` ya tiene preparada (o se preparará la primera vez que Radarr importe) la subcarpeta `movies/`. Convención de nombres (consistente con Jellyfin, ver `docs/09-multimedia/01-jellyfin.md`):

```
/mnt/hd2t/services/shared/media/
├── movies/                      ← Radarr (este doc)
│   ├── Blade Runner 2049 (2017)/
│   │   ├── Blade Runner 2049 (2017) - Bluray-1080p.mkv
│   │   └── Blade Runner 2049 (2017) - Bluray-1080p.srt
│   ├── Dune (2021)/
│   │   └── Dune (2021) - WEBDL-2160p.mkv
│   └── ...
├── series/                      ← Sonarr (docs/10-descargas/03-sonarr.md)
└── ...
```

- **Nombre del directorio por película**: `<Title> (<Year>)` — Radarr lo deriva del scraper TheMovieDB. Permite distinguir _remakes_ y películas con el mismo título de años distintos (ej. `The Thing (1982)` vs `The Thing (2011)`).
- **Fichero**: `<Movie Title> (<Year>) - {Quality Full}.mkv`. _Naming pattern_ recomendado por TRaSH-Guides (sub-bloque _Radarr_): `{Movie Title} ({Release Year}) {Quality Full}{[ Custom Formats]}` para el fichero, y `{Movie Title} ({Release Year})` para la carpeta. Se aplica en _Settings → Media Management → Movie Naming_ (ver **Configuración tras primer arranque**).
- **Una película = una carpeta**: a diferencia de Sonarr (que agrupa series y temporadas), Radarr crea **un directorio por película** que contiene el fichero `.mkv` principal y los _sidecar_ (subtítulos, _trickplay_ thumbnails de Jellyfin, etc.). Es la convención _Plex/Jellyfin standard_ y la que TRaSH-Guides recomienda.

> **Por qué `movies/` en plural**: convención del homelab para seguir el mismo patrón que `series/`, `music/`, `audiobooks/`. Jellyfin también muestra "Movies" como categoría; el nombre del directorio es interno y arbitrario.

### `Authentication Method: Forms` con `Authentication Required: Enabled` desde el primer arranque

Idéntica a Sonarr y Prowlarr. Radarr v4+ exige autenticación obligatoria desde la primera versión `4.0` (no se puede dejar la web UI abierta). Las dos opciones nativas:

| Método                                  | Comportamiento                                                                                                                                                                                                       |
|-----------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **Basic (Browser Popup)**               | Diálogo HTTP _Basic Auth_. Limpio para CLI/clientes _native_, pero los gestores de contraseñas no rellenan _basic auth_ y no hay logout limpio.                                                                       |
| **Forms (Login Page)** ✅                | Página de login HTML, _cookie_ de sesión, _Remember me_, logout explícito. Encaja con la familia _\*arr_ (Sonarr/Prowlarr usan el mismo patrón) y los gestores de contraseñas (Vaultwarden cuando llegue) lo soportan. |

Variables de entorno LSIO específicas que activan este comportamiento desde el primer arranque (en lugar de tener que entrar a la web UI a configurarlas):

```ini
RADARR__AUTH__METHOD=Forms
RADARR__AUTH__REQUIRED=Enabled
```

> Estas variables **sólo aplican en el primer arranque** (cuando `config.xml` no existe). En arranques posteriores, `config.xml` es la fuente de verdad. Para cambiarlas a posteriori, editar `config.xml` con el contenedor parado o usar la web UI.

---

## Estructura del _stack_ `descargas` tras este documento

Aprovecha el _stack_ ya existente, estrenado por Transmission (`docs/10-descargas/01-transmission.md`) y extendido por Prowlarr (`docs/10-descargas/02-prowlarr.md`) y Sonarr (`docs/10-descargas/03-sonarr.md`). Tras este documento, el _stack_ queda **completo**:

```
~/homelab/descargas/
├── docker-compose.yml        # ← extendido (añade servicio radarr)
├── .env                      # ← extendido (añade RADARR_IMAGE_TAG)
├── .env.example              # ← extendido (añade RADARR_IMAGE_TAG)
└── .gitignore                # (sin cambios)
```

Y en los discos externos, sobre lo que ya creó `docs/01-sistema/04-estructura-directorios.md`:

```
/mnt/hd2t/services/radarr/
└── (vacío al empezar; el primer arranque lo puebla con
    Backups/, MediaCover/, logs/, config.xml, radarr.db, …)
```

Verificar que el bind mount existe y tiene el ownership correcto antes de arrancar:

```bash
ls -la /mnt/hd2t/services/radarr
# total 8
# drwxr-xr-x 2 1000 1000 4096 ... .
# drwxr-xr-x ... services
```

Si por error está como `root:root`, restaurar:

```bash
sudo chown -R 1000:1000 /mnt/hd2t/services/radarr
sudo chmod 0755 /mnt/hd2t/services/radarr
```

> **No** crear subdirectorios a mano — Radarr crea `Backups/`, `MediaCover/`, `logs/`, `xdg/`, etc. con los permisos correctos en el primer arranque.

> **No** pre-crear `/mnt/hd2t/services/shared/media/movies/`: Radarr lo crea al hacer el primer _import_, y al heredar el `setgid` del padre el grupo será `homelab-media` automáticamente. Si por algún motivo el operador prefiere pre-crearlo (p. ej. para hacer un `rsync` previo de una colección), debe hacerlo así:
>
> ```bash
> sudo install -d -o 1000 -g homelab-media -m 2775 /mnt/hd2t/services/shared/media/movies
> ```

---

## Variables de entorno

Editar `~/homelab/descargas/.env.example` (versionado en git) y añadir el bloque de Radarr **al final** (preservando lo que ya tenían Transmission, Prowlarr y Sonarr):

```bash
# --- Imágenes pinneadas -----------------------------------------------------
# Patches automáticos vía Watchtower. Bumps de minor/major a mano leyendo
# https://github.com/Radarr/Radarr/releases y
# https://github.com/linuxserver/docker-radarr/releases.
RADARR_IMAGE_TAG=5.7.0
```

Replicar el cambio en `~/homelab/descargas/.env`:

```bash
$EDITOR ~/homelab/descargas/.env
# Añadir:
# RADARR_IMAGE_TAG=5.7.0
chmod 0600 ~/homelab/descargas/.env
```

> **Sin secretos en `.env`**: igual que Sonarr y Prowlarr, Radarr **no acepta** la contraseña de _Forms auth_ vía variables de entorno. La cuenta inicial se crea desde la web UI en el primer acceso (ver **Configuración tras primer arranque**). El _API key_ se autogenera por Radarr y se lee desde `/config/config.xml` cuando lo necesiten Prowlarr (para _Apps Sync_) o cualquier otro consumidor (Homepage/Homarr/Jellyfin).

> **`MEDIA_GID` ya está en el `.env` global** (`~/homelab/.env`, ver `docs/01-sistema/04-estructura-directorios.md` paso 8). Aquí no hace falta declararla de nuevo en `~/homelab/descargas/.env`; el `docker-compose.yml` la referencia con `${MEDIA_GID}`.

---

## `~/homelab/descargas/docker-compose.yml`

Editar el `docker-compose.yml` existente (creado por `docs/10-descargas/01-transmission.md` y extendido por `02-prowlarr.md` y `03-sonarr.md`) y añadir el servicio `radarr`. La estructura final relevante queda:

```yaml
---
# Stack: descargas — Transmission + Prowlarr + Sonarr + Radarr.
# Documentación: docs/10-descargas/{01-transmission,02-prowlarr,03-sonarr,04-radarr}.md

services:

  transmission:
    # ... (sin cambios; ver docs/10-descargas/01-transmission.md)

  prowlarr:
    # ... (sin cambios; ver docs/10-descargas/02-prowlarr.md)

  sonarr:
    # ... (sin cambios; ver docs/10-descargas/03-sonarr.md)

  # ---------------------------------------------------------------------------
  # Radarr — gestor automatizado de películas.
  # En 'homelab' (Caddy, Prowlarr y Transmission la alcanzan por nombre).
  # No publica puertos al host: la web UI y la API sólo se acceden via Caddy
  # (https://radarr.lan/) o por DNS interno desde Prowlarr/Jellyfin/Homepage.
  # ---------------------------------------------------------------------------
  radarr:
    image: lscr.io/linuxserver/radarr:${RADARR_IMAGE_TAG}
    container_name: radarr
    hostname: radarr
    restart: unless-stopped
    depends_on:
      transmission:
        condition: service_healthy
      prowlarr:
        condition: service_healthy
    environment:
      PUID: ${PUID}
      PGID: ${PGID}
      TZ: ${TZ}
      # Activar Forms auth desde el primer arranque para evitar el "wizard"
      # interactivo de Radarr (que aparece sólo si AUTH no está configurado).
      # Tras el primer arranque, /config/config.xml manda — estas variables
      # ya no se vuelven a aplicar.
      RADARR__AUTH__METHOD: Forms
      RADARR__AUTH__REQUIRED: Enabled
      # Nombre de instancia visible en la barra superior y en logs.
      RADARR__APP__INSTANCENAME: Radarr
      # Sin URL base: cada servicio tiene su propio vhost en Caddy.
      RADARR__SERVER__URLBASE: ""
    # Supplementary group: Radarr necesita pertenecer a 'homelab-media' para
    # poder crear ficheros bajo /mnt/hd2t/services/shared/media/movies/ (que
    # tiene bit setgid y grupo homelab-media). Sin este group_add, los
    # hardlinks fallan con EACCES aunque PUID/PGID estén bien.
    group_add:
      - "${MEDIA_GID}"
    volumes:
      - /mnt/hd2t/services/radarr:/config
      # Lectura+escritura sobre las descargas de Transmission. Radarr lee los
      # ficheros completados aquí; el hardlink lo crea en /media/movies/, no
      # aquí. /downloads se mantiene rw por si se activa "Remove files when
      # imported -> Hard delete" en Radarr (no es lo recomendado).
      - /mnt/hd2t/services/transmission/downloads:/downloads
      # Lectura+escritura sobre la biblioteca compartida. Imprescindible para
      # los hardlinks de los .mkv/.mp4 importados.
      - /mnt/hd2t/services/shared/media:/media
      # Hora del host (timestamps de logs y de History).
      - /etc/localtime:/etc/localtime:ro
    # Sin 'ports:' — la web UI :7878 sólo se alcanza por DNS interno.
    networks:
      homelab:
        aliases:
          - radarr             # Caddy, Prowlarr y futuros consumidores
                               # resuelven 'radarr:7878'
    labels:
      homelab.stack: "descargas"
      homelab.backup: "true"   # /mnt/hd2t/services/radarr entra en Borgmatic (Cat. S+F)
      # Opt-in: patches dentro de 5.x son seguros (sin breaking changes en
      # radarr.db ni en config.xml).
      com.centurylinklabs.watchtower.enable: "true"
    healthcheck:
      # /ping responde 200 sin auth — endpoint público diseñado para healthchecks.
      # No usamos /api/v3/system/status (requiere API key) ni / (requiere sesión
      # Forms): /ping es el endpoint canónico de Radarr para liveness.
      test:
        - CMD-SHELL
        - "wget -qO- --tries=1 --timeout=5 http://localhost:7878/ping 2>&1 | grep -q -i 'pong\\|OK' || exit 1"
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 90s

# ---------------------------------------------------------------------------
# Redes (sin cambios respecto a los docs anteriores)
# ---------------------------------------------------------------------------
networks:
  homelab:
    external: true               # creada en docs/02-docker/02-estructura-compose.md
```

Notas de diseño:

- **`PUID/PGID` vía `environment:`**: la imagen LSIO espera estos en el _entrypoint_. `PUID=1000`, `PGID=1000` heredados del `.env` global.
- **`group_add: ["${MEDIA_GID}"]`**: imprescindible para los _hardlinks_ contra `/services/shared/media/movies/`. Si en el futuro `MEDIA_GID` cambiara (regeneración del grupo `homelab-media`), recordar `docker compose up -d --force-recreate radarr`.
- **`depends_on` con `condition: service_healthy`**: Radarr arranca tras Transmission y Prowlarr para que sus _Health checks_ internos no dejen avisos amarillos durante el primer arranque del stack. Si Prowlarr o Transmission cayeran después, Radarr **no** se reinicia automáticamente — `depends_on` sólo aplica al _start_, no al _runtime_. **No** depende de `sonarr`: Sonarr y Radarr son independientes entre sí (no se comunican); sólo comparten upstream Prowlarr y downstream Transmission.
- **`RADARR__AUTH__METHOD` y `RADARR__AUTH__REQUIRED`**: la imagen LSIO traduce variables `RADARR__SECCION__CLAVE=valor` a entradas en `config.xml` en el primer arranque (vía `s6-overlay`). Sólo se aplican si `config.xml` aún **no** existe.
- **`RADARR__SERVER__URLBASE: ""`**: explícito para evitar que un wizard previo o un copy-paste de otro homelab haya dejado un valor distinto.
- **Sin `user:` explícito**: LSIO maneja el UID/GID con su propio _entrypoint_ s6-overlay; usar `user:` en paralelo confunde al `s6-overlay` y rompe el `chown` automático del nivel superior y el `group_add`.
- **Sin `ports:`**: Radarr es accesible sólo via Caddy (`radarr.lan`) y via DNS interno (`radarr:7878` desde Prowlarr / Jellyfin / Homepage / etc.).
- **`/etc/localtime:/etc/localtime:ro`**: además de `TZ`, montar `/etc/localtime` cubre los _timestamps_ que Radarr imprime en `History` y en los logs.
- **`start_period: 90s`**: el primer arranque de Radarr es **más lento** que el de Prowlarr (~60-90 s) — el _entrypoint_ ejecuta `Migrate` sobre `radarr.db` (vacío al principio, así que es rápido, pero el _runtime_ .NET necesita su tiempo) y el _scraper_ inicial de TheMovieDB se hace en _background_. `start_period: 90s` deja margen suficiente sin bloqueos espurios del _healthcheck_ durante el _bootstrap_.
- **Healthcheck sobre `/ping`**: Radarr expone `GET /ping` sin autenticación — endpoint canónico para _liveness probes_. Devuelve `200 OK` con cuerpo `{"status":"OK"}` (o `pong`/`OK` según la versión).
- **Watchtower opt-in**: razones explicadas en **Decisiones de diseño** → _Imagen y tag_.
- **No `mem_limit` ni `cpus`**: Radarr consume poco-medio (~200-400 MB RAM con una biblioteca de 100-300 películas, <5 % CPU idle, picos breves de ~30-50 % CPU durante búsquedas masivas o _RSS Sync_). La política por defecto (sin límite) está bien.

---

## Despliegue

### Primer arranque

```bash
cd ~/homelab/descargas
docker compose --env-file ../.env --env-file .env config | head -80   # validar sintaxis
docker compose --env-file ../.env --env-file .env up -d radarr
```

O, equivalente, con el _Makefile_ (ver `docs/02-docker/02-estructura-compose.md`):

```bash
cd ~/homelab
make up STACK=descargas
```

Vigilar el primer arranque (tarda ~60-90 s):

```bash
docker compose -f ~/homelab/descargas/docker-compose.yml logs -f radarr
# ...
# radarr | [migrations] started
# radarr | [migrations] no migrations found
# radarr | [custom-init] No custom files found, skipping...
# radarr | [ls.io-init] done.
# radarr | [Info] Microsoft.Hosting.Lifetime: Now listening on: http://[::]:7878
# radarr | [Info] Microsoft.Hosting.Lifetime: Application started.
# radarr | [s6-init] ready.
```

Verificar que el contenedor está `(healthy)`:

```bash
docker compose -f ~/homelab/descargas/docker-compose.yml ps radarr
# NAME    STATUS                   PORTS
# radarr  Up X seconds (healthy)
```

> El `(healthy)` lo otorga el _healthcheck_ que confirma que `/ping` responde HTTP `200`. Si tras 120 s sigue `starting`, ir a **Troubleshooting** → primer arranque.

Comprobar que `config.xml` se ha generado con los valores esperados:

```bash
sudo cat /mnt/hd2t/services/radarr/config.xml
# <Config>
#   <BindAddress>*</BindAddress>
#   <Port>7878</Port>
#   <SslPort>9898</SslPort>
#   <EnableSsl>False</EnableSsl>
#   <LogLevel>info</LogLevel>
#   <AnalyticsEnabled>True</AnalyticsEnabled>
#   <UrlBase></UrlBase>
#   <InstanceName>Radarr</InstanceName>
#   <ApiKey>abc123def456...</ApiKey>           ← autogenerado, anótalo
#   <AuthenticationMethod>Forms</AuthenticationMethod>
#   <AuthenticationRequired>Enabled</AuthenticationRequired>
#   <Branch>master</Branch>
#   <LaunchBrowser>False</LaunchBrowser>
# </Config>
```

> **Apuntar el `<ApiKey>`**: lo necesitará Prowlarr en su _Apps → Add Application → Radarr → API Key_. También lo consumirán Jellyfin/Homepage/Homarr cuando lleguen.

Comprobar que el _supplementary group_ está activo dentro del contenedor:

```bash
docker exec radarr id
# uid=1000(abc) gid=1000(abc) groups=1000(abc),100(users),<MEDIA_GID>(homelab-media)
```

Si `homelab-media` **no** aparece, el `group_add` no se aplicó — revisar el `.env` global (`MEDIA_GID` debe estar rellenado con el GID real) y `docker compose up -d --force-recreate radarr`.

### Caddy: bloque `radarr.lan`

Editar `~/homelab/red/Caddyfile` y añadir el bloque (situarlo junto al de `sonarr.lan` para mantener la sección de `descargas` agrupada):

```caddy
radarr.lan {
    tls internal
    import security-headers
    import logging

    reverse_proxy radarr:7878 {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
    }
}
```

> **No** se necesita `redir / /...` (a diferencia de Transmission): Radarr ya sirve la UI en la raíz. **No** se añade `import authelia` (ver **Decisiones de diseño**).

Validar y recargar Caddy:

```bash
docker exec caddy caddy validate --config /etc/caddy/Caddyfile
docker exec caddy caddy reload --config /etc/caddy/Caddyfile
```

Probar (la CA local debe estar importada en el navegador, ver `docs/03-red/04-caddy.md`):

```bash
# /ping: sin auth, debe responder 200
curl -k --resolve radarr.lan:443:192.168.1.3 \
     -I https://radarr.lan/ping
# HTTP/2 200

# /: redirige al login si no hay sesión (302 hacia /login)
curl -k --resolve radarr.lan:443:192.168.1.3 \
     -I https://radarr.lan/
# HTTP/2 302
# location: /login

# /api/v3/system/status sin API key: 401
curl -k --resolve radarr.lan:443:192.168.1.3 \
     -I https://radarr.lan/api/v3/system/status
# HTTP/2 401
```

Y desde el navegador: `https://radarr.lan/` → redirección a `/login` → formulario _Forms_ → primera vez se crea la cuenta administrador (ver siguiente sección).

---

## Configuración tras primer arranque

### 1. Crear la cuenta administrador

En el primer acceso a `https://radarr.lan/`, Radarr muestra el formulario de _Forms_ pidiendo **crear** el usuario administrador (no es un login contra una cuenta existente — es un _setup_ inicial):

- **Username**: el operador elige (no tiene que coincidir con el del sistema; puede ser distinto al de Sonarr).
- **Password**: contraseña fuerte. Apuntar en el gestor del operador (cuando llegue Vaultwarden, mover allí).

Tras crear la cuenta, Radarr redirige al _dashboard_ vacío. Confirmar que _Settings → General → Security_ muestra:

- _Authentication: Forms (Login Page)_
- _Authentication Required: Enabled_
- _API Key_: el mismo valor que aparece en `config.xml`.

### 2. Verificar el `<ApiKey>` y guardarlo

```bash
sudo grep -oP '<ApiKey>\K[^<]+' /mnt/hd2t/services/radarr/config.xml
# abc123def456...
```

Apuntar este valor en el gestor del operador con la etiqueta `radarr-api-key`. Lo necesitarán:

- **Prowlarr** en _Settings → Apps → Add Application → Radarr → API Key_.
- **Jellyfin/Homepage/Homarr** (cuando lleguen) para consultar la cola y el calendario de Radarr vía `X-Api-Key`.

### 3. Configurar _Media Management_

_Settings → Media Management_ — los valores por defecto son razonables; los cambios mínimos del homelab:

- **Movie Naming**:
  - _Rename Movies_: `Yes`
  - _Replace Illegal Characters_: `Yes`
  - _Standard Movie Format_: `{Movie Title} ({Release Year}) - {Quality Full}{[ Custom Formats]}` _(o el patrón TRaSH-Guides actual; ver Referencias)_
  - _Movie Folder Format_: `{Movie Title} ({Release Year})`

- **Folders**:
  - _Create empty movie folders_: `No` (evita folders fantasma cuando Radarr aún no ha descargado nada).
  - _Delete empty folders_: `Yes`.

- **Importing**:
  - _Use Hardlinks instead of Copy_: ✅ **Yes** (crítico — sin esto los _imports_ duplican espacio).
  - _Import Extra Files_: `srt, ass, ssa, sub, idx` (subtítulos junto al `.mkv`).
  - _Unmonitor Deleted Movies_: `Yes` (cuando se borra una película del filesystem, deja de buscarla).

- **File Management**:
  - _Use hardlinks instead of copy_: ✅ **Yes** (redundante con _Importing_; actívalo en ambos).
  - _Set Permissions_: `Yes`.
  - _chmod Folder_: `775`, _chmod File_: `664`.
  - _chown Group_: dejar en blanco (el `setgid` del padre se encarga; forzarlo aquí provoca conflictos).

- **Add Root Folder**:
  - _Path_: `/media/movies` (la ruta dentro del contenedor; el host es `/mnt/hd2t/services/shared/media/movies/`).
  - Radarr crea el directorio si no existe — al heredar `setgid` del padre, el grupo será `homelab-media`.

### 4. Configurar el _Download Client_ (Transmission)

_Settings → Download Clients → Add Download Client → Transmission_:

| Campo                    | Valor                                                             |
|--------------------------|-------------------------------------------------------------------|
| **Name**                 | `transmission` (libre, sólo etiqueta interna)                     |
| **Enable**               | ✅                                                                |
| **Host**                 | `transmission` (DNS interno de Docker, no `transmission.lan`)     |
| **Port**                 | `9091`                                                            |
| **Url Base**             | `/transmission/`                                                  |
| **Username**             | `${TRANSMISSION_USER}` (el del `.env` del stack `descargas`)      |
| **Password**             | `${TRANSMISSION_PASS}` (idem)                                     |
| **Category**             | `movies-radarr` (Radarr la pasa como label a Transmission)        |
| **Post-Import Category** | _vacío_ (opcional; se puede usar para agrupar imports completos)  |
| **Recent Priority**      | `Last`                                                            |
| **Older Priority**       | `Last`                                                            |
| **Use SSL**              | ❌ (DNS interno, sin TLS — Caddy es el único punto TLS del homelab) |

> **Importante**: la categoría es `movies-radarr` (distinta de `tv-sonarr` que usa Sonarr). Esto permite que en Transmission el operador filtre por origen y, si en algún momento se activa _Remove Completed_ en uno solo de los dos _arr_, no se le borren al otro los _torrents_ por error.

_Test_ debe pasar (Radarr hace una llamada `session-stats` contra Transmission y comprueba la respuesta). Si falla:

- `401 Unauthorized`: revisar usuario/contraseña; si coinciden con el `.env` del `descargas` y siguen fallando, ver Transmission → _Troubleshooting_ → "401 Unauthorized desde el navegador a pesar de tener la contraseña correcta".
- `409 Conflict`: la _CSRF_ de Transmission. Radarr la maneja correctamente; si aparece, suele ser por una versión muy vieja de Transmission o de Radarr. Pinear las versiones del homelab cubre el caso.
- `Failed to connect`: revisar que `transmission` resuelve por DNS interno: `docker exec radarr getent hosts transmission` debe devolver una IP `172.20.10.x`.

_Save_ y comprobar que el _Health check_ de Radarr (_System → Health_) **no** reporta avisos sobre _Download Clients_.

> _Settings → Download Clients → Completed Download Handling_ — defaults razonables, no se tocan: _Enable: Yes_, _Redownload: No_. Esto activa el flujo "Transmission marca completed → Radarr lo importa por hardlink → Radarr le pide a Transmission que retire el _torrent_ (manteniendo o no los ficheros según _Remove Completed_)".

> _Remove Completed_ y _Remove Failed_: dejar **deshabilitados** por defecto. Si en el futuro se quiere "limpiar" Transmission tras el _import_, activarlos con cuidado: _Remove Completed_ borra el `.torrent` de Transmission **pero** mantiene los ficheros en `/downloads/` (el _hardlink_ ya está creado en `/media/movies/`, así que no hay pérdida de espacio gracias al _hardlink_, pero sí se pierde el _seeding_ del torrent original). Tradeoff entre _seeding ratio_ y _disk hygiene_.

### 5. _Apps Sync_ desde Prowlarr → Radarr

Aquí se cierra el círculo del **stack `descargas`** y se completa la familia _\*arr_ (Prowlarr/Sonarr/Radarr). **En Prowlarr**, _Settings → Apps → Add Application → Radarr_:

| Campo               | Valor                                                                 |
|---------------------|-----------------------------------------------------------------------|
| **Name**            | `Radarr`                                                              |
| **Sync Level**      | `Full Sync` (Prowlarr crea/actualiza/borra _indexers_ en Radarr)      |
| **Tags**            | _vacío_ (o un Tag específico si se quiere segmentar)                  |
| **Prowlarr Server** | `http://prowlarr:9696`                                                |
| **Radarr Server**   | `http://radarr:7878`                                                  |
| **API Key**         | el `<ApiKey>` de **Radarr** (paso 2 — no el de Prowlarr ni el de Sonarr) |

_Test_ debe pasar (Prowlarr hace `GET /api/v3/system/status` contra Radarr con el _API key_). _Save_.

Tras `Save`, ir a **Radarr → Settings → Indexers** y verificar que aparecen los _indexers_ que el operador haya configurado en Prowlarr. **No tocar** estos _indexers_ desde Radarr — son administrados por Prowlarr; cualquier cambio se hace desde Prowlarr y se sincroniza.

> Si _Settings → Indexers_ en Radarr está vacío tras el _Sync_, comprobar:
>
> - Que en **Prowlarr** hay al menos un _indexer_ activo.
> - Que el _Sync Profile_ asociado a ese _indexer_ permite tipo "Movies". Por defecto, todos los _indexers_ pasan a Radarr; si el operador acotó el _Sync Profile_ a sólo "TV", Radarr no recibe nada.
> - El log de Prowlarr (_System → Logs_) debe mostrar `Synced indexers to <App>:Radarr` tras el _Save_.

> Tras este paso, en _Prowlarr → Settings → Apps_ deben aparecer **dos** entradas: `Sonarr` y `Radarr`, ambas con `Test` ✅. En _Prowlarr → Indexer Stats_ se ven las consultas de cada _arr_ por separado.

### 6. Configurar _Quality Profiles_ y _Custom Formats_

_Settings → Profiles → Quality Profiles_ — los _profiles_ por defecto (`Any`, `SD`, `HD-720p`, `HD-1080p`, `Ultra-HD`) cubren el caso básico. Para una configuración _state of the art_ alineada con TRaSH-Guides:

- _Settings → Custom Formats_: importar JSON de TRaSH-Guides para Radarr (ver Referencias). Cubre HDR, _release groups_, codecs, _audio channels_, _audio types_ (Atmos, DTS-X), etc. **Importante**: los _Custom Formats_ de Radarr son **distintos** a los de Sonarr — TRaSH-Guides los publica en directorios separados. No mezclar.
- _Settings → Profiles → Quality Profiles → HD-1080p_: ajustar _Custom Formats_ con _scores_ recomendados de TRaSH para priorizar releases con HDR10/Dolby Vision sobre SDR, evitar _CAM/Telesync_, preferir _Bluray_ sobre _WEBDL_ cuando ambos están disponibles, etc.

> **Recomendación operativa**: para empezar, _Quality Profile = HD-1080p_ con _Cutoff = HDTV-1080p_ y _Custom Formats_ vacío. Cuando Radarr esté funcionando con un par de películas, importar TRaSH-Guides. La automatización fina es un trabajo iterativo; no bloquea el _bootstrap_.

> **Recyclarr** (sincronización automática de _Quality Profiles_ y _Custom Formats_ desde TRaSH-Guides para Sonarr **y** Radarr): _opt-in_ avanzado. Se documenta como anexo cuando el operador lo pida. Para empezar, configuración manual es suficiente. Recyclarr soporta los dos _arr_ con un único `recyclarr.yml`.

### 7. Conectar Radarr a Jellyfin (opcional)

_Settings → Connect → Add → Jellyfin_:

| Campo            | Valor                                                                     |
|------------------|---------------------------------------------------------------------------|
| **Name**         | `Jellyfin`                                                                |
| **On Grab**      | ❌                                                                        |
| **On Import**    | ✅ (notifica a Jellyfin para que escanee la biblioteca tras un import)    |
| **On Upgrade**   | ✅                                                                        |
| **On Rename**    | ✅                                                                        |
| **On Movie Delete** | ✅                                                                     |
| **On Movie File Delete** | ✅                                                                |
| **Host**         | `jellyfin` (DNS interno)                                                  |
| **Port**         | `8096`                                                                    |
| **API Key**      | el `<ApiKey>` de Jellyfin (`docs/09-multimedia/01-jellyfin.md`)           |
| **Use SSL**      | ❌                                                                        |
| **Send Notifications** | ✅                                                                  |

_Test_ debe pasar. Tras esto, cuando Radarr importe una película nueva, le pedirá a Jellyfin que refresque la biblioteca `movies` — la película aparece en Jellyfin sin esperar al cron interno (que sería cada hora o así).

> Si Jellyfin aún no está desplegado, saltarse este paso. Volver a él cuando se complete `docs/09-multimedia/01-jellyfin.md`.

### 8. Añadir la primera película

_Movies → Add New → Buscar "<título>"_ → seleccionar la película correcta (ojo a remakes, _years_) → _Add Movie_:

- _Root Folder_: `/media/movies` (debe estar en la lista; lo añadimos en paso 3).
- _Monitor_: `Movie Only` (sólo el corte cinematográfico) / `Movie and Collection` (también las secuelas/precuelas si están en la misma _collection_ de TMDb) — el operador elige según gusto.
- _Minimum Availability_: `Released` (busca releases sólo cuando la película ya tiene fecha de estreno físico/digital). Las opciones más permisivas (`In Cinemas`, `Announced`) suelen producir basura (CAM, Telesync) si no se filtran por _Custom Format_.
- _Quality Profile_: `HD-1080p` (o el que se haya configurado).
- _Tags_: opcional, útil para reglas avanzadas.
- _Start search for missing movie_: ✅ (Radarr lanza una búsqueda automática tras el _Add_).

Radarr empieza a buscar releases en los _indexers_, pasa los _torrents_ que cumplen el _Quality Profile_ a Transmission con la categoría `movies-radarr`, y, una vez Transmission completa la descarga, Radarr la importa por _hardlink_ a `/media/movies/<Movie> (<Year>)/`.

> **Verificar el flujo completo**: tras añadir la primera película y esperar unos minutos:
>
> ```bash
> # 1. Radarr ha enviado el .torrent a Transmission:
> docker exec transmission transmission-remote -n "${TRANSMISSION_USER}:${TRANSMISSION_PASS}" -l
> # Debe listar al menos un torrent con label "movies-radarr".
>
> # 2. Cuando Transmission termina y Radarr importa, el fichero aparece en /media/movies:
> ls /mnt/hd2t/services/shared/media/movies/
> # Blade Runner 2049 (2017)/  ...
>
> # 3. El fichero es un hardlink (mismo inode que el de /downloads):
> stat -c '%i' /mnt/hd2t/services/transmission/downloads/<release>.mkv \
>             /mnt/hd2t/services/shared/media/movies/<Movie>\ \(<Year>\)/<...>.mkv
> # Ambos números deben coincidir — confirma hardlink, no copia.
> ```

### 9. _Lists_ (opcional)

_Settings → Lists_ — Radarr soporta importar películas en bloque desde fuentes externas:

- **TMDb Popular / TMDb Top Rated**: listas curadas por TheMovieDB.
- **TMDb User List**: una lista personal del operador en TMDb (requiere _List ID_).
- **IMDb List**: idem para IMDb (requiere _List ID_, opcionalmente _IMDb Auth Token_ para listas privadas).
- **Trakt**: listas de Trakt (requiere _OAuth_ con la cuenta de Trakt — el operador autoriza Radarr en una página externa).

_Lists_ es **opt-in**: el flujo más simple es añadir películas a mano vía _Movies → Add New_. Las _Lists_ son útiles cuando el operador mantiene una _watchlist_ en TMDb/IMDb/Trakt y quiere que Radarr la replique automáticamente. **No** se configura en este documento; se deja anotado como _siguiente paso opcional_.

### 10. Configurar `Backup Retention` (opcional)

_Settings → General → Backups_:

- **Backup Folder**: `/config/Backups` (default, **no tocar**).
- **Backup Interval**: `7` días (default).
- **Backup Retention**: `28` días (subido respecto al default `7` para tener un mes de _backups_ internos rotables).

---

## Almacenamiento

Tras el primer arranque y la importación de varias películas, el árbol `/mnt/hd2t/services/radarr/` queda con los siguientes ficheros relevantes:

```
/mnt/hd2t/services/radarr/
├── config.xml                      # <ApiKey>, <AuthenticationMethod>, etc.
├── radarr.db                       # SQLite — movies, history, profiles, custom formats
├── radarr.db-shm                   # SQLite shared memory (transitorio)
├── radarr.db-wal                   # SQLite WAL (transitorio)
├── Backups/
│   ├── manual/
│   └── scheduled/
│       └── radarr_backup_v5.7.0.x_2026.04.27_03.00.00.zip
├── MediaCover/                     # posters, fanart por película
│   ├── 1/
│   ├── 2/
│   └── ...
├── logs/
│   ├── radarr.txt                  # log activo
│   └── archive/
│       └── radarr.X.txt.gz         # logs rotados
├── xdg/                            # caché de .NET runtime (efímero)
│   └── ...
└── update_logs/
    └── ...
```

| Ruta                                                | Permisos          | Contenido                                                  |
|-----------------------------------------------------|-------------------|------------------------------------------------------------|
| `/mnt/hd2t/services/radarr/`                        | `1000:1000 0755`  | Raíz del bind mount                                        |
| `/mnt/hd2t/services/radarr/config.xml`              | `1000:1000 0644`  | Configuración (incluye el `<ApiKey>` en claro)             |
| `/mnt/hd2t/services/radarr/radarr.db`               | `1000:1000 0644`  | BD SQLite (incluye credenciales de Transmission y Jellyfin encriptadas con clave derivada de `<ApiKey>`) |
| `/mnt/hd2t/services/radarr/Backups/scheduled/`      | `1000:1000 0755`  | _Backups_ internos diarios                                 |
| `/mnt/hd2t/services/radarr/MediaCover/`             | `1000:1000 0755`  | _Posters_ y _fanart_ por película                          |
| `/mnt/hd2t/services/radarr/logs/`                   | `1000:1000 0755`  | Logs (rotación interna por Radarr)                         |
| `/mnt/hd2t/services/shared/media/movies/`           | `1000:homelab-media 2775` | Biblioteca de películas (heredado del padre con setgid) |
| `/mnt/hd2t/services/shared/media/movies/<M>/<...>.mkv` | `1000:homelab-media 0664` | Películas — hardlinks a `/services/transmission/downloads/...` |

> **Sobre `config.xml` con permisos `0644`**: contiene el `<ApiKey>` en claro. Consideraciones idénticas a Sonarr y Prowlarr (ver `docs/10-descargas/03-sonarr.md` → **Almacenamiento**). Endurecer a `0640` o `0600` está bien y no rompe nada:
>
> ```bash
> sudo chmod 0640 /mnt/hd2t/services/radarr/config.xml
> ```

> **Sobre `radarr.db`**: Radarr **encripta** las credenciales sensibles (contraseña de Transmission, _API key_ de Jellyfin) usando una clave derivada de `<ApiKey>`. Si se filtra `radarr.db` **sin** `config.xml`, las credenciales no son trivialmente extraíbles; con ambos, sí. Por eso el _bind mount_ entero es Categoría A en términos de sensibilidad.

> **Sobre los _hardlinks_**: cada `.mkv` en `/media/movies/` ocupa **0 bytes adicionales** mientras el mismo _inode_ siga referenciado desde `/downloads/`. Cuando el operador (o Transmission tras `Remove Completed`) borra el `.torrent`, el _link count_ del _inode_ baja de 2 a 1, y el fichero pasa a "vivir" en `/media/movies/` exclusivamente. `du -h /mnt/hd2t/services/shared/media/movies/` puede dar números engañosamente grandes si se cuentan los _inodes_ compartidos; usar `du -hs --apparent-size` para "tamaño aparente" o `find ... -links 1` para "ficheros que ya no comparten".

---

## Backup

Patrón **S** (SQLite vía `dump_sqlite`) + Patrón **F** (filesystem-only para `config.xml`, `MediaCover/`, `Backups/`).

### 1. Confirmar que `source_directories:` ya cubre Radarr

El `config.yaml` de Borgmatic (`docs/07-backups/02-borgmatic.md`) ya incluye `/mnt/hd2t/services/radarr` en `source_directories:` (ver `docs/07-backups/01-estrategia-backup.md` → **Inventario consolidado de fuentes**, línea `- /mnt/hd2t/services/radarr`). **No hay que añadir nada**.

### 2. Excluir el WAL de SQLite y `xdg/` (recomendado)

Análogo a Sonarr y Prowlarr. Editar:

```bash
$EDITOR ~/homelab/backups/borgmatic/config.yaml
```

```yaml
exclude_patterns:
  # ... entradas existentes ...

  # Radarr — SQLite WAL/SHM transitorios; el dump del Patrón S los integra
  # en radarr.db antes de leer. La copia "viva" del .db sí entra como
  # filesystem-only (defensa en profundidad), pero el WAL no aporta nada.
  - /mnt/hd2t/services/radarr/radarr.db-wal
  - /mnt/hd2t/services/radarr/radarr.db-shm

  # xdg/ es caché del runtime .NET; regenerable.
  - /mnt/hd2t/services/radarr/xdg
```

> El propio `radarr.db` **se mantiene** en los _source_directories_ (no se excluye): es la "copia viva" que entra como Categoría F, complementaria al dump del Patrón S.

> **Sobre `/mnt/hd2t/services/shared/media/movies/`**: **NO** se respalda con Borgmatic (Categoría C en la estrategia — regenerable mediante re-descarga). Ya está cubierto por la exclusión global de `/mnt/hd2t/services/shared/media/` que añadió `docs/07-backups/01-estrategia-backup.md`. Si el operador prefiere respaldarlo igualmente (porque ciertas películas no son re-descargables fácilmente — _rare cuts_, _director's cuts_ con audio comentario, etc.), debe quitarse esa exclusión — fuera de alcance de este doc.

### 3. Descomentar el bloque del hook `dump-databases.sh`

Editar el script:

```bash
$EDITOR ~/homelab/backups/borgmatic/hooks/dump-databases.sh
```

Localizar el bloque (Sonarr lo dejó así tras `docs/10-descargas/03-sonarr.md`):

```bash
# --- *arr family (Sonarr/Radarr/Prowlarr — SQLite) — docs/10-descargas/0[3-2].md
dump_sqlite sonarr   sonarr   /config/sonarr.db
# dump_sqlite radarr   radarr   /config/radarr.db
dump_sqlite prowlarr prowlarr /config/prowlarr.db
```

Y descomentar la línea de Radarr:

```bash
# --- *arr family (Sonarr/Radarr/Prowlarr — SQLite) — docs/10-descargas/0[3-2].md
dump_sqlite sonarr   sonarr   /config/sonarr.db
dump_sqlite radarr   radarr   /config/radarr.db
dump_sqlite prowlarr prowlarr /config/prowlarr.db
```

> Tras este cambio, las **tres** líneas de la familia _\*arr_ están descomentadas — coherente con que los tres servicios están desplegados.

Reinstalar el script con el cambio:

```bash
~/homelab/backups/borgmatic/install.sh
```

### 4. Verificar el dump manualmente

```bash
sudo /etc/borgmatic.d/hooks/dump-databases.sh
# [dump] sonarr: OK -> /mnt/hd2t/backups/dumps/sonarr-2026-04-27.sqlite.gz
# [dump] radarr: OK -> /mnt/hd2t/backups/dumps/radarr-2026-04-27.sqlite.gz
# [dump] prowlarr: OK -> /mnt/hd2t/backups/dumps/prowlarr-2026-04-27.sqlite.gz
ls -la /mnt/hd2t/backups/dumps/radarr-*.sqlite.gz | tail -3
```

Validar integridad:

```bash
gunzip -c /mnt/hd2t/backups/dumps/radarr-2026-04-27.sqlite.gz | file -
# /dev/stdin: SQLite 3.x database, ...
```

Y que se puede leer:

```bash
gunzip -c /mnt/hd2t/backups/dumps/radarr-2026-04-27.sqlite.gz \
  > /tmp/radarr-restore-test.db
sqlite3 /tmp/radarr-restore-test.db '.tables' | head -10
# Blocklist               History               PendingReleases
# Commands                Indexers              Profiles
# Config                  MetadataFiles         QualityDefinitions
# CustomFormats           Movies                Restrictions
# DownloadClients         ImportLists           ...
rm /tmp/radarr-restore-test.db
```

### 5. Confirmar que el archive incluye Radarr tras el siguiente run

```bash
sudo bash -c '
  set -a; . /etc/borgmatic.d/secrets.env; set +a
  borg list --short "$BORG_REPO_LOCAL" | tail -1
'
# pi-2026-04-28T03:30:30

sudo bash -c '
  set -a; . /etc/borgmatic.d/secrets.env; set +a
  borg list "$BORG_REPO_LOCAL::pi-2026-04-28T03:30:30" \
    | grep -E "radarr" | head -10
'
# -rw-r--r-- 1000 1000 1.4K Apr 28 02:00 mnt/hd2t/services/radarr/config.xml
# -rw-r--r-- 1000 1000  35M Apr 28 02:00 mnt/hd2t/services/radarr/radarr.db
# drwxr-xr-x 1000 1000    - Apr 28 02:00 mnt/hd2t/services/radarr/Backups
# ...
# -rw-r--r-- root root  4.2M Apr 28 03:30 mnt/hd2t/backups/dumps/radarr-2026-04-28.sqlite.gz
# ...
```

Confirmar que **NO** aparecen `radarr.db-wal`, `radarr.db-shm` ni `xdg/`:

```bash
sudo bash -c '
  set -a; . /etc/borgmatic.d/secrets.env; set +a
  borg list "$BORG_REPO_LOCAL::pi-2026-04-28T03:30:30" \
    | grep -E "radarr.db-(wal|shm)|radarr/xdg"
'
# (vacío)
```

### Restauración

Procedimiento del **Patrón S — SQLite** documentado en `docs/07-backups/03-backup-docker-volumes.md`. Análogo al de Sonarr y Prowlarr:

1. `docker compose -f ~/homelab/descargas/docker-compose.yml stop radarr`.
2. Mover `/mnt/hd2t/services/radarr/radarr.db{,-shm,-wal}` a `radarr.db.broken-<ts>` (no borrar — preservar 24-48 h).
3. Restaurar el dump más reciente:

   ```bash
   sudo gunzip -c /mnt/hd2t/backups/dumps/radarr-<fecha>.sqlite.gz \
     > /mnt/hd2t/services/radarr/radarr.db
   sudo chown 1000:1000 /mnt/hd2t/services/radarr/radarr.db
   sudo chmod 0644 /mnt/hd2t/services/radarr/radarr.db
   ```

4. **Caso especial — `config.xml` también corrupto o perdido**: extraer del archive Borg el `config.xml` correspondiente:

   ```bash
   sudo bash -c '
     set -a; . /etc/borgmatic.d/secrets.env; set +a
     borg extract --strip-components 4 \
       "$BORG_REPO_LOCAL::pi-<fecha>" \
       mnt/hd2t/services/radarr/config.xml
   '
   sudo mv config.xml /mnt/hd2t/services/radarr/config.xml
   sudo chown 1000:1000 /mnt/hd2t/services/radarr/config.xml
   ```

   > **Importante**: `config.xml` y `radarr.db` deben venir del **mismo archive** (mismo `<ApiKey>`). El `<ApiKey>` se usa para derivar la clave de encriptación de credenciales en `radarr.db`; mezclar archives distintos invalida las credenciales encriptadas (Transmission `Test` devolverá `401`, Jellyfin `Test` también).

5. `docker compose -f ~/homelab/descargas/docker-compose.yml up -d radarr`.
6. Esperar al `(healthy)`. Radarr re-leerá `config.xml` y `radarr.db`; en la web UI, las películas, _Quality Profiles_ y _Custom Formats_ deben aparecer tal y como estaban.
7. **Re-validar conexión a Transmission y a Prowlarr**: _Settings → Download Clients → Test_ y _Settings → General → Health_. Si Transmission falla, ver paso 4 (mismo archive).
8. **Re-validar el _Apps Sync_ desde Prowlarr**: ir a Prowlarr → _Settings → Apps → Radarr → Test_. Si el `<ApiKey>` cambió por la restauración (no debería, viene del archive), reconfigurar el _API Key_ en Prowlarr.

> **Restauración alternativa desde el _backup_ interno de Radarr**: si el operador prefiere usar el _zip_ que Radarr genera en `Backups/scheduled/`, puede importarlo desde la web UI (_System → Backup → Choose File → Restore_). Es más cómodo para restauraciones rápidas pero **sólo cubre los últimos 7-28 días** (según `Backup Retention`); para algo más antiguo, ir al archive Borg.

> **Restauración del filesystem `/media/movies/`**: **no** se hace desde Borg (excluido). Las películas se re-descargan automáticamente cuando Radarr arranca limpio: con la BD restaurada, Radarr conoce las películas, ve que los ficheros físicos no están, y vuelve a buscar y descargar. Tarda lo que tarde el ancho de banda y los _indexers_.

---

## Verificación

Antes de dar por cerrado este documento:

- [ ] `~/homelab/descargas/docker-compose.yml` y `~/homelab/descargas/.env.example` versionados en git con la sección de `radarr` añadida; `~/homelab/descargas/.env` **no** versionado y con `RADARR_IMAGE_TAG` rellenado.
- [ ] `docker compose -f ~/homelab/descargas/docker-compose.yml ps radarr` muestra `radarr` como `(healthy)`.
- [ ] `docker exec radarr wget -qO- http://localhost:7878/ping` devuelve un cuerpo con `OK`/`pong` (HTTP 200).
- [ ] `docker exec radarr id` muestra `uid=1000 gid=1000` y `groups=...,<MEDIA_GID>(homelab-media)`.
- [ ] `sudo grep -oP '<ApiKey>\K[^<]+' /mnt/hd2t/services/radarr/config.xml` devuelve un valor de 32 caracteres alfanuméricos.
- [ ] `sudo grep -oP '<AuthenticationMethod>\K[^<]+' /mnt/hd2t/services/radarr/config.xml` devuelve `Forms`.
- [ ] `sudo grep -oP '<AuthenticationRequired>\K[^<]+' /mnt/hd2t/services/radarr/config.xml` devuelve `Enabled`.
- [ ] `docker exec caddy caddy validate --config /etc/caddy/Caddyfile` acepta el bloque `radarr.lan` añadido.
- [ ] `curl -k --resolve radarr.lan:443:192.168.1.3 -I https://radarr.lan/ping` devuelve `HTTP/2 200`.
- [ ] `curl -k --resolve radarr.lan:443:192.168.1.3 -I https://radarr.lan/` devuelve `HTTP/2 302` con `location: /login`.
- [ ] `curl -k --resolve radarr.lan:443:192.168.1.3 -I https://radarr.lan/api/v3/system/status` devuelve `HTTP/2 401`.
- [ ] `curl -k --resolve radarr.lan:443:192.168.1.3 -H "X-Api-Key: <APIKEY>" https://radarr.lan/api/v3/system/status | jq .version` devuelve un string tipo `"5.7.0.x"`.
- [ ] Login interactivo desde el navegador con la cuenta administrador funciona; tras login se ve el _dashboard_ vacío.
- [ ] `ss -tulpn '( sport = :7878 )'` en el host **NO** muestra ningún proceso bindeando ese puerto (Radarr no publica al host).
- [ ] `docker port radarr` no lista ningún _mapping_.
- [ ] El bloque `radarr.lan` del `Caddyfile` lleva `import security-headers` y `import logging`; **no** lleva `import authelia`.
- [ ] La lista `two_factor` del `access_control.rules` de Authelia **no** menciona `radarr.lan` (ni siquiera comentado).
- [ ] Watchtower vigila el contenedor: `docker logs watchtower --tail 50 | grep radarr` muestra al menos un check (label `enable: "true"` activo).
- [ ] `stat -c '%U:%G' /mnt/hd2t/services/radarr /mnt/hd2t/services/radarr/{config.xml,radarr.db,Backups,logs}` devuelve `1000:1000` en todos.
- [ ] `~/homelab/backups/borgmatic/hooks/dump-databases.sh` tiene la línea `dump_sqlite radarr radarr /config/radarr.db` **descomentada**; las de `sonarr` y `prowlarr` siguen descomentadas también (las tres _\*arr_ activas).
- [ ] `sudo /etc/borgmatic.d/hooks/dump-databases.sh && ls /mnt/hd2t/backups/dumps/radarr-*.sqlite.gz` muestra al menos un dump del día.
- [ ] `gunzip -c /mnt/hd2t/backups/dumps/radarr-*.sqlite.gz | file -` reporta `SQLite 3.x database`.
- [ ] El siguiente run de Borgmatic incluye `mnt/hd2t/services/radarr/` y **excluye** `radarr.db-wal`, `radarr.db-shm` y `xdg/`.
- [ ] _Settings → General → Security_ en la web UI muestra `Authentication: Forms`, `Authentication Required: Enabled`, y el _API key_ coincide con el del `config.xml`.
- [ ] _Settings → Download Clients_ en Radarr muestra `transmission` con _Test_ pasando y categoría `movies-radarr`.
- [ ] _Settings → Indexers_ en Radarr aparece poblado **automáticamente** por el _Apps Sync_ desde Prowlarr (no se han tocado a mano).
- [ ] _Settings → Media Management_ tiene _Use Hardlinks instead of Copy_ activado en _Importing_ y en _File Management_, y _Root Folder_ apunta a `/media/movies`.
- [ ] _Prowlarr → Settings → Apps_ muestra **dos** entradas: `Sonarr` y `Radarr`, ambas con _Test_ ✅.
- [ ] Tras añadir una película de prueba y dejar pasar tiempo, _Activity → Queue_ muestra el _torrent_ pasado a Transmission con label `movies-radarr`.
- [ ] Tras la finalización del _torrent_, _Activity → History_ muestra el _import_ exitoso, y `/mnt/hd2t/services/shared/media/movies/<Movie> (<Year>)/<...>.mkv` existe con permisos `1000:homelab-media 0664`.
- [ ] El fichero importado es un **hardlink**: `stat -c '%i %h' /mnt/hd2t/services/transmission/downloads/<release>.mkv` y `stat -c '%i %h' /mnt/hd2t/services/shared/media/movies/<...>.mkv` devuelven el **mismo `inode`** (primer número) y un `link count` (segundo número) **≥ 2**.

---

## Troubleshooting

### Primer arranque: el contenedor se queda en `starting` indefinidamente

```bash
docker logs radarr --tail 80
```

Causas comunes:

- **Permisos del bind mount**: si por error se hizo un `chown -R root:root /mnt/hd2t/services/radarr`, el _entrypoint_ de LSIO falla al hacer `chown` del nivel superior. Restaurar:

  ```bash
  sudo chown -R 1000:1000 /mnt/hd2t/services/radarr
  docker compose -f ~/homelab/descargas/docker-compose.yml restart radarr
  ```

- **Migración de BD que falla**: log con `Microsoft.Data.Sqlite.SqliteException: SQLite Error 5: 'database is locked'` o similar. Suele ser por un `radarr.db-wal` huérfano de un arranque previo no limpio. Solución:

  ```bash
  docker compose -f ~/homelab/descargas/docker-compose.yml stop radarr
  sudo rm /mnt/hd2t/services/radarr/radarr.db-wal \
          /mnt/hd2t/services/radarr/radarr.db-shm
  docker compose -f ~/homelab/descargas/docker-compose.yml start radarr
  ```

- **`RADARR__AUTH__*` ignoradas porque `config.xml` ya existía**: si el bind mount tenía un `config.xml` previo, las variables de entorno **no** se aplican. Para reset completo (mismas precauciones que con Sonarr):

  ```bash
  docker compose -f ~/homelab/descargas/docker-compose.yml stop radarr
  sudo mv /mnt/hd2t/services/radarr/config.xml /mnt/hd2t/services/radarr/config.xml.bak
  docker compose -f ~/homelab/descargas/docker-compose.yml start radarr
  ```

  > **Atención**: esto **invalida** las credenciales encriptadas en `radarr.db` (cambia el `<ApiKey>`). Sólo en _bootstrap_ inicial sin _Download Clients_ aún configurados, o tras restaurar también `radarr.db` desde un archive del **mismo** `config.xml`.

### `502 Bad Gateway` desde Caddy

Idéntica al equivalente de Sonarr (`docs/10-descargas/03-sonarr.md` → **Troubleshooting**). Verificar:

```bash
docker inspect caddy   --format '{{range $net, $cfg := .NetworkSettings.Networks}}{{$net}} {{end}}'
docker inspect radarr  --format '{{range $net, $cfg := .NetworkSettings.Networks}}{{$net}} {{end}}'
# Ambos deben listar 'homelab'.
```

### `Permission denied` al importar películas — _hardlink_ falla

El _import_ aparece en _Activity → Queue_ con error `Failed to import` o similar, y _System → Logs_ muestra:

```
[Error] MovieImport: Couldn't import movie /downloads/<release>/<file>.mkv:
  System.UnauthorizedAccessException: Access to the path '/media/movies/<...>'
  is denied.
```

Causas y soluciones:

- **`MEDIA_GID` no se aplicó como _supplementary group_**: confirmar con `docker exec radarr id`. Si `homelab-media` no está en `groups`, revisar:
  - `~/homelab/.env` global tiene `MEDIA_GID=<gid real>` (no vacío, no `0`).
  - El compose de Radarr lleva `group_add: ["${MEDIA_GID}"]`.
  - Recrear: `docker compose -f ~/homelab/descargas/docker-compose.yml up -d --force-recreate radarr`.

- **Bit `setgid` perdido en `/services/shared/media/`**: comprobar con `stat -c '%a %U:%G' /mnt/hd2t/services/shared/media`:

  ```bash
  # Esperado: 2775 root:homelab-media
  ```

  Si sale `0775` o `0755`, restaurar:

  ```bash
  sudo chmod 2775 /mnt/hd2t/services/shared/media
  sudo find /mnt/hd2t/services/shared/media -type d -exec sudo chmod 2775 {} +
  ```

- **Filesystem distinto** entre `/downloads` y `/media/movies`: `link(2)` falla con `EXDEV`. Comprobar `stat -c '%m' /mnt/hd2t/services/transmission/downloads /mnt/hd2t/services/shared/media`. Si difieren, no se puede _hardlink_-ar; Radarr cae a copia (gasta el doble de espacio). Revisar `fstab` y montajes.

### `Test` del _Download Client_ Transmission devuelve `401 Unauthorized`

Radarr no autentica contra Transmission. Causas:

- Usuario/contraseña incorrectos: comparar con `~/homelab/descargas/.env` (`TRANSMISSION_USER`, `TRANSMISSION_PASS`).
- Tras una restauración de Transmission, el hash MD5+salt de la password en `settings.json` no es el mismo que la _plain text_ de la `.env`. Ver `docs/10-descargas/01-transmission.md` → **Cambiar la contraseña RPC más adelante**.

### `Test` del _Download Client_ Transmission devuelve `Failed to connect`

DNS interno no resuelve `transmission`. Comprobar:

```bash
docker exec radarr getent hosts transmission
# 172.20.10.X transmission
```

Si está vacío:

- Radarr no está en la red `homelab`: revisar el compose.
- Transmission no está corriendo: `docker ps --filter name=transmission`.

### `Test` del _Apps Sync_ desde Prowlarr → Radarr devuelve `401 Unauthorized`

El `<ApiKey>` que el operador puso en Prowlarr no es el de Radarr (puede haber pegado el de Sonarr por error — el formato es idéntico). Confirmar con:

```bash
sudo grep -oP '<ApiKey>\K[^<]+' /mnt/hd2t/services/radarr/config.xml
# Debe coincidir EXACTAMENTE con el campo "API Key" de Prowlarr → Apps → Radarr.
```

### `Test` del _Apps Sync_ desde Prowlarr → Radarr devuelve `Connection failed`

DNS interno entre Prowlarr y Radarr roto. Comprobar:

```bash
docker exec prowlarr getent hosts radarr
# 172.20.10.X radarr
```

Si está vacío, ambos contenedores deben estar en la red `homelab`.

### Radarr no encuentra ninguna release tras añadir una película

- _Settings → Indexers_ está vacío: el _Apps Sync_ desde Prowlarr no se ha hecho o falló (ver paso 5 de **Configuración tras primer arranque**).
- _Settings → Indexers_ tiene _indexers_ pero el _Test_ falla: el problema es upstream, en Prowlarr. Ir a `docs/10-descargas/02-prowlarr.md` → **Troubleshooting**.
- _Quality Profile_ demasiado restrictivo: la película tiene releases pero ninguno cumple. Ajustar.
- _Minimum Availability_ demasiado estricto: si la película es muy reciente y aún no tiene fecha de _Released_, Radarr no busca. Cambiar a `In Cinemas` temporalmente, o esperar.
- _Sync Profile_ en Prowlarr filtra "Movies" para ese _indexer_: revisar Prowlarr → _Indexer → Sync Profile_ y asegurarse de que pasa contenido de tipo "Movies" a Radarr.

### Películas importadas aparecen en `/media/movies/` pero **NO** en Jellyfin

- Jellyfin no ha refrescado la biblioteca. Forzar: _Jellyfin → Dashboard → Libraries → Movies → Scan Library_.
- Si el _Connect_ de Radarr → Jellyfin estaba configurado, _Activity → History_ debería mostrar la notificación. Si no, revisar _Settings → Connect → Jellyfin → Test_.
- El _Library Path_ de Jellyfin no incluye `/media/movies`. Revisar en `docs/09-multimedia/01-jellyfin.md` que la _Library_ "Movies" apunta a `/media/movies`.

### `Health → All Indexers Are Unavailable`

- Si **todos** los _indexers_ están "_unavailable_", el problema es de red/DNS de Radarr → Prowlarr o de internet → Prowlarr → upstream. Diagnóstico:

  ```bash
  # 1. Radarr alcanza Prowlarr?
  docker exec radarr wget -qO- http://prowlarr:9696/ping
  # Debe devolver OK/pong.

  # 2. Prowlarr alcanza upstream?
  docker exec prowlarr wget -qO- https://www.google.com -O /dev/null -S 2>&1 | head -5
  # Debe devolver HTTP/200.
  ```

- Si sólo algunos _indexers_ fallan, suele ser específico de cada _indexer_ (Cloudflare, _site down_, credenciales caducadas). Ir a Prowlarr → _Indexers → <Indexer> → Test_.

### Radarr y Sonarr "se pelean" por el mismo torrent

Síntoma: el operador añade una serie en Sonarr y, simultáneamente, una película con el mismo título (poco frecuente, pero ocurre con _crossovers_, _spin-offs_, o nombres genéricos como `The One`). Los dos _arr_ envían _torrents_ distintos a Transmission con _categorías_ distintas (`tv-sonarr` vs `movies-radarr`), pero algún _release group_ etiqueta los ficheros con metadatos ambiguos que confunden al _scraper_.

- **Categorías separadas resuelven el 99 % de los casos**: cada _arr_ ignora los _torrents_ que llevan la categoría del otro. Confirmar que en _Settings → Download Clients → Transmission_ de cada _arr_ la categoría es la propia (`tv-sonarr` para Sonarr, `movies-radarr` para Radarr).
- Si aún así un fichero aparece en _Manual Import_ de los dos _arr_, ignorar uno de los dos manualmente.

### Logs en `/config/logs/radarr.txt` crecen sin parar

Idéntico a Sonarr/Prowlarr: el _LogLevel_ probablemente está en `Debug` o `Trace`. Volver a `Info`:

`Settings → General → Logging → Log Level: Info` (o ajustar `<LogLevel>info</LogLevel>` en `config.xml` con el contenedor parado).

---

## Actualización

### Patches de la línea `5.x` (vía Watchtower, automático)

Watchtower opt-in está activo. Cada domingo a las 04:00 UTC, Watchtower comprueba el _digest_ del _tag_ `5.7.0`; si LSIO publica un re-build (mismo _tag_, distinto _digest_), Watchtower hace `pull` + `recreate` del contenedor. Sin acción del operador.

Verificar tras un domingo:

```bash
docker logs watchtower --tail 50 | grep radarr
# time=... msg="Found new lscr.io/linuxserver/radarr:5.7.0 image"
# time=... msg="Stopping /radarr"
# time=... msg="Creating /radarr"
```

Si tras la recreación el `(healthy)` no llega en 120 s, ir a **Troubleshooting**.

### Bumps de patch (`5.7.0 → 5.7.1`, manual)

```bash
# 1. Leer las release notes
xdg-open https://github.com/Radarr/Radarr/releases/tag/v5.7.1
xdg-open https://github.com/linuxserver/docker-radarr/releases

# 2. Backup completo previo
sudo /usr/bin/borgmatic --verbosity 1
# Verificar que el último archive tiene fecha de hoy y que el dump
# /mnt/hd2t/backups/dumps/radarr-<fecha>.sqlite.gz se ha generado.

# 3. Cambiar el tag y aplicar
$EDITOR ~/homelab/descargas/.env
# RADARR_IMAGE_TAG=5.7.1
cd ~/homelab
make pull STACK=descargas
make up STACK=descargas

# 4. Vigilar el log durante el reinicio
docker compose -f ~/homelab/descargas/docker-compose.yml logs -f radarr
# Buscar:
#   radarr | [Info] Microsoft.Hosting.Lifetime: Application started.
# Si el log muestra ERROR o el contenedor entra en restart loop, ir a Troubleshooting.

# 5. Validar la web UI, los Download Clients y los Indexers, y System → Status muestra la
#    nueva versión.
```

### Bumps de _minor_ (`5.7 → 5.8`)

- Suelen incluir migraciones de `radarr.db` (claves nuevas, índices). Hacer SIEMPRE backup completo del bind mount antes:

  ```bash
  sudo systemctl stop docker
  sudo tar czf /mnt/hd2t/backups/radarr-pre-bump-$(date +%F).tar.gz \
      -C /mnt/hd2t/services radarr
  sudo systemctl start docker
  ```

- Planificar la actualización en una ventana de mantenimiento.
- Considerar saltar a `5.8.1` o similar (la versión `.0` a menudo tiene bugs que se arreglan en el primer _patch_).
- Tras el _upgrade_, comprobar que las películas, _Quality Profiles_, _Custom Formats_ y _Download Client_ siguen activos en la web UI; comprobar también el _Apps Sync_ desde Prowlarr → Radarr.

### Bumps de _major_ (`5.x → 6.x`)

- Cambios estructurales relevantes; cuando ocurra:
- Leer la guía de migración del proyecto.
- Verificar compatibilidad con Prowlarr (puede requerir actualizar Prowlarr a una versión que entienda la nueva API _Apps_).
- Backup previo (Borgmatic + tar.gz manual del bind mount).
- Plan de _rollback_ (`RADARR_IMAGE_TAG=5.7.0` y `make up STACK=descargas` para volver atrás, restaurando el bind mount del tar.gz si las migraciones de BD eran irreversibles).

---

## Referencias

- Documentación oficial — Radarr Wiki: <https://wiki.servarr.com/radarr>
- API v3 — referencia: <https://radarr.video/docs/api/>
- Imagen Docker — LinuxServer.io `radarr`: <https://github.com/linuxserver/docker-radarr>
- LSIO `radarr` — Docker Hub: <https://hub.docker.com/r/linuxserver/radarr>
- Releases de Radarr (upstream): <https://github.com/Radarr/Radarr/releases>
- Variables de entorno LSIO `RADARR__*`: <https://github.com/linuxserver/docker-radarr#parameters>
- TRaSH-Guides — _Quality Profiles_, _Custom Formats_ y _Naming_ para Radarr: <https://trash-guides.info/Radarr/>
- Reverse proxy con Caddy — _Servarr_ general: <https://wiki.servarr.com/radarr/installation#reverse-proxy>
- Recyclarr (sincronización TRaSH-Guides para Sonarr **y** Radarr, _opt-in_ avanzado): <https://recyclarr.dev/>
- TheMovieDB (TMDb) — fuente principal de metadatos de películas: <https://www.themoviedb.org/>
- Documentos relacionados del homelab:
  - `docs/01-sistema/04-estructura-directorios.md` — `/mnt/hd2t/services/radarr` con ownership `1000:1000`; `/services/shared/media/` con `setgid` y `homelab-media`.
  - `docs/02-docker/02-estructura-compose.md` — convenciones de stacks, red `homelab`, regla `:ro`/`:rw`, `MEDIA_GID` en `.env` global.
  - `docs/02-docker/04-watchtower.md` — opt-in para `5.x`, ventana dominical.
  - `docs/03-red/02-pihole.md` — DNS local `*.lan` (cubre `radarr.lan` por wildcard).
  - `docs/03-red/04-caddy.md` — Caddy, CA local, _snippets_ `security-headers` y `logging`.
  - `docs/03-red/05-tailscale.md` — acceso remoto vía VPN sin abrir puertos en el router.
  - `docs/04-seguridad/01-authelia.md` — por qué Radarr **no** entra en `forward_auth`.
  - `docs/07-backups/01-estrategia-backup.md` — Categoría A (credenciales encriptadas) + Patrón S (SQLite); Categoría C para `/services/shared/media/movies/`.
  - `docs/07-backups/02-borgmatic.md` — `source_directories`, `exclude_patterns`.
  - `docs/07-backups/03-backup-docker-volumes.md` — Patrón S y línea `dump_sqlite radarr radarr /config/radarr.db` (descomentada por este doc).
  - `docs/09-multimedia/01-jellyfin.md` — biblioteca multimedia que consume `/media/movies/` en `:ro`.
  - `docs/10-descargas/01-transmission.md` — _stack_ `descargas`, _Download Client_ que recibe los _torrents_ de Radarr.
  - `docs/10-descargas/02-prowlarr.md` — _Apps Sync_ que pobla los _Indexers_ de Radarr automáticamente.
  - `docs/10-descargas/03-sonarr.md` — gemelo de Radarr para series; comparten Prowlarr (upstream) y Transmission (downstream).
