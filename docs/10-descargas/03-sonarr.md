# Sonarr (gestor de series de TV)

## Descripción

Despliegue de **Sonarr** como **gestor automatizado de series de TV** del homelab: vigila la lista de series _monitorizadas_ del operador, busca nuevos episodios contra los _indexers_ centralizados en Prowlarr (`docs/10-descargas/02-prowlarr.md`), entrega los releases que cumplen el _Quality Profile_ a **Transmission** (`docs/10-descargas/01-transmission.md`) como cliente BitTorrent, y, una vez la descarga termina, _importa_ los ficheros desde `/mnt/hd2t/services/transmission/downloads/` a `/mnt/hd2t/services/shared/media/series/` (la biblioteca que **Jellyfin** lee en `:ro` desde `docs/09-multimedia/01-jellyfin.md`). El paso de _Transmission → biblioteca_ se hace por **hardlink** (cero copia de bytes, cero duplicación de espacio en `hd2t`) gracias a que ambos directorios viven en el mismo _filesystem_ y a que Sonarr corre con `MEDIA_GID` como _supplementary group_ para escribir en `/services/shared/media/` con bit `setgid`. Toda la configuración persistente (`/config/config.xml`, `/config/sonarr.db` SQLite, `MediaCover/`, _backups_ internos, logs) vive en el disco externo **hd2t** (`/mnt/hd2t/services/sonarr/`), pre-creado y reasignado a `1000:1000` en `docs/01-sistema/04-estructura-directorios.md` (paso 7, "Reasignar ownership de los servicios LinuxServer.io").

Este documento **continúa el _stack_ `descargas`** (`~/homelab/descargas/`) estrenado por Transmission y extendido por Prowlarr: añade el contenedor `sonarr` al `docker-compose.yml` existente, crea el bloque `sonarr.lan` en el `Caddyfile`, **descomenta** la línea `dump_sqlite sonarr sonarr /config/sonarr.db` en `~/homelab/backups/borgmatic/hooks/dump-databases.sh` (Patrón S — SQLite) y deja documentado el _Apps Sync_ desde **Prowlarr → Sonarr** (la dirección correcta de la integración) y el _Download Client_ **Sonarr → Transmission**, ambos por DNS interno de Docker.

Caddy (stack `red`, `docs/03-red/04-caddy.md`) expone Sonarr en `https://sonarr.lan/` con TLS interno (CA local). Para acceso remoto vía Tailscale (`docs/03-red/05-tailscale.md`), MagicDNS resuelve `pi.<tailnet>.ts.net` y desde ahí el operador llega al mismo backend. Las integraciones internas — Prowlarr poblando _indexers_ en Sonarr, Sonarr enviando _torrents_ a Transmission — viajan por **DNS interno de Docker** (`http://sonarr:8989/`, `http://prowlarr:9696/`, `http://transmission:9091/`), saltándose Caddy y autenticándose por _API key_ o por _basic auth_ según el caso.

> **Alcance**: este documento despliega Sonarr con su autenticación nativa de _Forms_ (usuario + contraseña, _cookie_ de sesión) **activada desde el primer arranque** vía `SONARR__AUTH__METHOD=Forms` y `SONARR__AUTH__REQUIRED=Enabled`, configura `SONARR__APP__INSTANCENAME=Sonarr`, deja `URL Base` vacía (acceso por _vhost_ propio en Caddy, no por _path_ compartido), añade Sonarr al grupo `homelab-media` (vía `group_add`) para que los _hardlinks_ contra `/services/shared/media/` no fallen por permisos, y entrega el _runbook_ de respaldo Patrón S sobre `sonarr.db`. **No** delega autenticación a Authelia vía `forward_auth` (rompería el `Apps → Test` de Prowlarr y la API de Jellyfin/Homepage si en algún momento se rutaran por Caddy, y la _Forms auth_ nativa de Sonarr ya cubre el caso humano; ver **Decisiones de diseño**). **No** despliega Radarr (`docs/10-descargas/04-radarr.md`), **no** despliega Bazarr (subtítulos, fuera del alcance del homelab por ahora), **no** despliega Recyclarr (sincronización de _Custom Formats_ con TRaSH-Guides, _opt-in_ avanzado que el operador puede añadir después). **No** importa series previas existentes; la biblioteca arranca vacía y el operador añade series una a una desde la web UI o vía `Series → Import`.

> **Recordatorio de red**: Sonarr **no se publica al host**. La web UI (`:8989`) la alcanza Caddy por DNS interno de Docker (`sonarr:8989` en la red `homelab`). Pi-hole resuelve `sonarr.lan → 192.168.1.3` por el _wildcard_ de `02-homelab-local.conf` (ver `docs/03-red/02-pihole.md`). El operador entra siempre por `https://sonarr.lan/` (LAN) o por el nombre _MagicDNS_ del nodo Tailscale.

---

## Requisitos previos

- `docs/10-descargas/01-transmission.md` completado: el _stack_ `descargas` (`~/homelab/descargas/`) ya existe, el contenedor `transmission` está `(healthy)` y resuelve por DNS interno como `transmission:9091`. La _basic auth_ está activa (`TRANSMISSION_USER`/`TRANSMISSION_PASS` del `.env`).
- `docs/10-descargas/02-prowlarr.md` completado: Prowlarr está desplegado y `(healthy)`, su `<ApiKey>` está apuntado en el gestor del operador, y resuelve por DNS interno como `prowlarr:9696`.
- `docs/01-sistema/04-estructura-directorios.md` completado:
    - `/mnt/hd2t/services/sonarr/` ya existe con ownership `1000:1000` (paso 7, "Reasignar ownership de los servicios LinuxServer.io"). **No hay que crear nada**: Sonarr poblará la estructura interna (`Backups/`, `logs/`, `MediaCover/`, `sonarr.db`, `config.xml`) en el primer arranque.
    - `/mnt/hd2t/services/shared/media/` existe con `root:homelab-media 2775` (bit `setgid`) y el GID de `homelab-media` está en `~/homelab/.env` como `MEDIA_GID`.
- `docs/01-sistema/03-seguridad-base.md` completado: `nftables` con `input drop` por defecto. Este documento **no añade** ninguna regla de _firewall_ — Sonarr no publica puertos al host.
- `docs/02-docker/04-watchtower.md` completado: Sonarr se etiquetará como **opt-in** explícito (`com.centurylinklabs.watchtower.enable: "true"`), coherente con la lista de "candidatos a _opt-in_ desde el principio" de aquel doc.
- `docs/03-red/02-pihole.md` completado: Pi-hole resuelve `*.lan → 192.168.1.3`. **No hay que añadir nada** para `sonarr.lan` — el _wildcard_ ya lo cubre.
- `docs/03-red/04-caddy.md` completado: Caddy escucha en `192.168.1.3:443` con `tls internal`, los _snippets_ `security-headers.caddy` y `logging.caddy` existen, la directiva `import /etc/caddy/snippets/*.caddy` está activa en el `Caddyfile` y la CA local firma `*.lan`.
- `docs/04-seguridad/01-authelia.md` completado **opcionalmente**: si Authelia ya está montada, en este documento se decide explícitamente **no** poner Sonarr detrás de `forward_auth`. La lista `two_factor` del `access_control.rules` de Authelia **no incluye** `sonarr.lan` (ni siquiera comentado).
- `docs/07-backups/02-borgmatic.md` y `docs/07-backups/03-backup-docker-volumes.md` completados: el `source_directories: /mnt/hd2t/services` ya engloba `sonarr/`, y la línea `dump_sqlite sonarr sonarr /config/sonarr.db` ya está **comentada** en `~/homelab/backups/borgmatic/hooks/dump-databases.sh`. Este documento la **descomenta**.
- `docs/09-multimedia/01-jellyfin.md` completado o pendiente: Jellyfin lee `/mnt/hd2t/services/shared/media/` en `:ro`. Si Jellyfin aún no está desplegado no pasa nada — Sonarr crea la subcarpeta `series/` la primera vez que importa un episodio, y Jellyfin la encontrará cuando se despliegue. Si Jellyfin **sí** está desplegado, tras el primer _import_ exitoso de Sonarr se hace _Library → Scan_ desde Jellyfin (o se deja al cron interno).
- Conectividad saliente para descargar la imagen (sólo la primera vez):

  ```bash
  docker pull --platform linux/arm64 lscr.io/linuxserver/sonarr:4.0.10 >/dev/null && echo OK
  ```

  El _tag_ exacto se consulta en <https://github.com/linuxserver/docker-sonarr/pkgs/container/sonarr>; la convención del homelab prohíbe `:latest` (ver `docs/02-docker/02-estructura-compose.md`, sección **Imágenes**).

- Que el host **no** tenga ya un servicio escuchando en `:8989`:

  ```bash
  sudo ss -tulpn '( sport = :8989 )'
  ```

  Salida esperada: vacía. Sonarr no publica `:8989` al host (Caddy lo alcanza por DNS interno), pero conviene confirmar que ningún binario residual lo ocupa por si más adelante el operador, durante un _troubleshoot_, añadiese un `ports: ["8989:8989"]` improvisado.

- Co-residencia de `services/transmission/downloads` y `services/shared/media` en el **mismo filesystem**, requisito imprescindible para que los _hardlinks_ de Sonarr funcionen:

  ```bash
  stat -c '%m' /mnt/hd2t/services/transmission/downloads /mnt/hd2t/services/shared/media
  # /mnt/hd2t
  # /mnt/hd2t
  ```

  Si los dos montajes devolvieran puntos distintos, los _hardlinks_ caerían silenciosamente a copia (Sonarr lo hace pero gasta el doble de espacio en `hd2t`). Revisar `fstab` y montajes antes de seguir.

- Espacio en `/mnt/hd2t`: como mínimo **500 MB libres** para `sonarr/` en estado estable. `sonarr.db` SQLite con un par de centenares de series ronda **20-100 MB**, `logs/` con rotación interna **10-50 MB**, `Backups/` internos diarios de Sonarr **10-50 MB cada uno**, `MediaCover/` con _posters_/_fanart_ de cada serie a varios tamaños puede ocupar **100-300 MB** según la biblioteca.

  ```bash
  df -h /mnt/hd2t
  ```

---

## Decisiones de diseño

### Por qué Sonarr (y no SickChill / Medusa / mantenimiento manual)

El homelab necesita un gestor automatizado de series de TV que se integre con Prowlarr (centralización de _indexers_) y con un cliente BitTorrent (Transmission). Tres alternativas evaluadas:

| Candidato     | Por qué se descarta / acepta                                                                                                                                                                                                                                                                                                                                                                                       |
|---------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **SickChill** | Sucesor de SickRage / SickBeard. Mantenimiento de comunidad activo pero más artesanal que Sonarr. Soporta menos clientes BitTorrent de primera clase y la integración con Prowlarr es secundaria (Prowlarr soporta SickChill como _App_, pero el flujo está peor pulido).                                                                                                                                                                                                  |
| **Medusa**    | Otro fork de SickRage. Funciona, comunidad pequeña, _release cadence_ irregular. Sin razones para cambiar a él si el resto del homelab vive en la familia _Servarr_ (Prowlarr es de los mismos autores que Sonarr).                                                                                                                                                                                                                                                       |
| **Sonarr** ✅ | Mantenido por el equipo _Servarr_ (mismos autores que Prowlarr/Radarr/Lidarr/Readarr). _Apps Sync_ bidireccional con Prowlarr vía API (añadir un _indexer_ en Prowlarr lo propaga a Sonarr automáticamente). Soporta Transmission de primera clase (Sonarr v4 lleva años con la integración estable). _Custom Formats_ y _Quality Profiles_ son la _state of the art_ para automatizar selección de releases (HDR, _release group_, audio, idioma, etc.). |
| Mantenimiento manual | Operativamente indefendible salvo para 1-2 series puntuales. El homelab quiere automatizar el _watch_ de novedades sin abrir el navegador cada noche.                                                                                                                                                                                                                                                                                              |

Sonarr es el sucesor natural de NzbDrone (rebrand 2014) y la opción canónica cuando Prowlarr ya está montado. El _footprint_ es similar a Prowlarr (~200-300 MB RAM con una biblioteca pequeña, .NET 6 _runtime_).

### Imagen y _tag_

- **`lscr.io/linuxserver/sonarr:4.0.10`** — imagen LSIO (LinuxServer.io) sobre upstream Sonarr `4.0.10.x`. _Tag_ "major.minor.patch" pinneado a la versión exacta. Multi-arch (`linux/arm64`).
- **Por qué LSIO**: convención del homelab para servicios que se benefician de `PUID`/`PGID` y `s6-overlay`, igual que el resto de la familia _\*arr_ (Prowlarr, Radarr, Transmission). La imagen "oficial" de Sonarr en Docker Hub (`linuxserver/sonarr`, `hotio/sonarr`) son las únicas mantenidas activamente; LSIO encaja con todo el resto del homelab.
- **Por qué `4.0.10` y no `:latest` ni `develop`**: la rama `develop` recibe _commits_ diarios y a veces _breaking changes_ en el formato del `sonarr.db`. La rama `master` (`:latest`) es estable pero el _tag_ corto recibe re-builds del _wrapper_ LSIO varias veces por semana. Pinear al patch concreto convierte cada re-build en una decisión humana — Watchtower (cuando se active el _opt-in_) recoge re-builds del **mismo `4.0.10`** sin cambiar el _tag_; los _bumps_ de patch (`4.0.10 → 4.0.11`) son cambios explícitos en el `.env`.
- **Por qué no la rama `3.0.x` _legacy_**: Sonarr v3 fue reemplazado por v4 en 2023. v4 introduce _Custom Formats_ unificados con Radarr (TRaSH-Guides los aplica con el mismo formato), un nuevo _scheduler_ y mejoras de _import_ (incluido _hardlink_ atómico que respeta `setgid`). v3 está en _maintenance only_; v4 es la línea estable vigente.

> **Cómo consultar el _tag_ vigente**: <https://github.com/linuxserver/docker-sonarr/pkgs/container/sonarr>. Los `release notes` de upstream Sonarr se siguen en <https://github.com/Sonarr/Sonarr/releases>; los re-builds del _wrapper_ LSIO en <https://github.com/linuxserver/docker-sonarr/releases>.

#### Watchtower **opt-in**

Razones (mismas que Prowlarr y Transmission):

- **Patches frecuentes sin _breaking changes_** dentro de la rama `4.0.x`: re-builds semanales con _bug fixes_ del propio Sonarr y _security updates_ de la base Alpine.
- **Estado estable dentro de `4.0.x`**: el formato de `sonarr.db` y `config.xml` está congelado dentro de la _minor_. Watchtower puede reciclar el contenedor con seguridad. Las migraciones internas son aditivas.
- **Tolerancia a reinicios**: Sonarr es _stateless_ entre arranques excepto por el `sonarr.db` y los _backups_ internos diarios. Un reinicio de un par de minutos en la madrugada (ventana Watchtower domingo 04:00 UTC) no afecta operación; los _torrents_ activos en Transmission siguen descargando, y al volver Sonarr se sincroniza con la cola de Transmission y procesa los completados.
- **Migraciones de BD automáticas y reversibles**: el _entrypoint_ de Sonarr ejecuta `Migrate` sobre `sonarr.db` al arrancar; las migraciones internas dentro de la `4.0.x` son aditivas.

Etiquetar el contenedor con `com.centurylinklabs.watchtower.enable: "true"`.

> **Bumps de _minor_** (`4.0 → 4.1`, `4.x → 5.x`): se hacen **a mano**, fuera de Watchtower. Cambiar `SONARR_IMAGE_TAG=4.1.0` en `~/homelab/descargas/.env`, leer las _release notes_ de upstream y de LSIO, hacer backup del `sonarr.db` previo (Borgmatic + dump SQLite), y aplicar `make pull STACK=descargas && make up STACK=descargas`. Watchtower con _tag_ `4.0.10` no salta a `4.1.0` automáticamente porque mira el _digest_ del _tag_ exacto pinneado.

### Modo de red: `bridge` (red `homelab`) sin `ports:` publicados

Decisión opinada y consistente con el resto del homelab. Las dos opciones razonables son las mismas que para Prowlarr (ver `docs/10-descargas/02-prowlarr.md` → **Modo de red**); el resumen para Sonarr:

| Opción                                     | Ventajas                                                                                       | Inconvenientes                                                                                          |
|--------------------------------------------|------------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------|
| **`network_mode: host`**                   | Trivial: Sonarr escucha en `192.168.1.3:8989`. Caddy puede _reverse-proxy_ a `127.0.0.1:8989`. | Rompe el patrón "Caddy delante de cada servicio". Expone la web UI al host: cualquier proceso local pinchea la API sin Caddy. |
| **`bridge` en red `homelab` sin `ports:`** ✅ | Coherente con todos los demás servicios del homelab: Sonarr se alcanza por DNS interno (`sonarr:8989`), Caddy es el _único_ camino al servicio para humanos, y Prowlarr/Transmission lo alcanzan por nombre. | Un cliente CLI desde la Pi misma sin pasar por Caddy debe usar `docker exec` o llamar a la URL `https://sonarr.lan/` con la CA local — apropiado para el homelab. |

Se elige `bridge` con red externa `homelab`. Sonarr no necesita ningún puerto publicado al host.

### `forward_auth` con Authelia: **NO** para Sonarr

La misma decisión que con Prowlarr (`docs/10-descargas/02-prowlarr.md` → **`forward_auth` con Authelia: NO**). Razones técnicas concretas para Sonarr:

- **Prowlarr habla con Sonarr por DNS interno** (`http://sonarr:8989/`) saltándose Caddy. Authelia ahí no influye en absoluto. Sería sólo una protección extra para la web UI humana.
- **Jellyfin / Homepage / Homarr (cuando lleguen) consumen la API de Sonarr** (calendario de próximos episodios, _Activity → Queue_, _History_) por DNS interno o eventualmente por Caddy. Si Caddy estuviese protegido por Authelia, las apps clientes (no humanas) tendrían que seguir un flujo de _OIDC_ que **no soportan** — usan _API key_ vía header `X-Api-Key`.
- **Sonarr ya tiene autenticación nativa _Forms_** desde la rama `3.x`: el operador la activa en _Settings → General → Security → Authentication: Forms (Login Page)_ con _Authentication Required: Enabled_. La _cookie_ de sesión protege la web UI, y todas las llamadas API requieren un _API key_ que Sonarr genera y muestra en el mismo panel. Doble capa nativa, suficiente.

Solución correcta para este homelab: **Sonarr autentica con su sistema nativo** (Forms login, _API key_), Caddy actúa como _reverse proxy_ "tonto" que termina TLS y propaga las cabeceras. Si en el futuro se quisiera proteger adicionalmente la UI con Authelia, se podría añadir un _path matcher_ aplicando `forward_auth` sólo a los _paths_ humanos (`/`, `/login`, `/UI/*`) dejando `/api/*` libre — _opt-in_ avanzado, fuera de alcance.

> **Resumen operativo**: el bloque `sonarr.lan` del `Caddyfile` lleva `import security-headers` y `import logging`, pero **no** `import authelia`. La sesión Forms (cookie `Sonarr-`) protege la UI; el _API key_ protege `/api/*`.

### `URL Base` vacía + acceso por _vhost_ propio

Idéntica decisión que para Prowlarr. Sonarr soporta `URL Base = /sonarr` para servir bajo un _path_ compartido, pero como cada servicio del homelab tiene su propio _vhost_ (`sonarr.lan`, `radarr.lan`, `prowlarr.lan`, …), **`URL Base` se mantiene vacía**:

- Más simple: ningún _rewrite_ de _path_ en Caddy, ningún ajuste de `app.baseUrl` en el cliente JS de Sonarr.
- _Apps Sync_ desde Prowlarr usa _Sonarr Server_ = `http://sonarr:8989/` (DNS interno), donde no hay _path_; consistente.
- El operador no tiene que recordar diferencias entre el acceso por LAN, Tailscale y DNS interno.

### Volúmenes: `/downloads` (rw) + `/media` (rw, con `MEDIA_GID`)

Sonarr necesita ambos:

| Volumen del host                            | Punto de montaje en el contenedor | Modo | Propósito                                                                                                |
|---------------------------------------------|-----------------------------------|------|----------------------------------------------------------------------------------------------------------|
| `/mnt/hd2t/services/sonarr/`                | `/config`                         | rw   | `config.xml`, `sonarr.db`, `Backups/`, `MediaCover/`, `logs/`                                            |
| `/mnt/hd2t/services/transmission/downloads/`| `/downloads`                      | rw   | Sonarr lee aquí los `.mkv` que Transmission ha terminado y los _hardlink_-a a `/media/series/`           |
| `/mnt/hd2t/services/shared/media/`          | `/media`                          | rw   | Sonarr crea/actualiza `/media/series/<Serie>/Season X/<Serie> - SXXEYY - <Title>.mkv` por _hardlink_     |

> **Por qué `/downloads` en `rw` y no `:ro`**: Sonarr necesita _crear el hardlink en el árbol de Transmission_ de forma transitoria (no, en realidad lo crea en `/media/series/`, no en `/downloads/`), pero **además** la opción _Completed Download Handling → Remove from client when import is successful_ (recomendada, ver **Configuración tras primer arranque**) requiere que Sonarr le pida a Transmission que **borre** el `.torrent` finalizado vía RPC; eso lo hace por API HTTP, sin tocar el filesystem. Sin embargo, si en el futuro se activa _Completed Download Handling → Remove files when_ + _Hard delete_, Sonarr **sí** borra del filesystem `/downloads/`. Mantener `rw` por simplicidad; la _Categoría C_ del backup (descargas regenerables) ya asume que `/downloads` no es sagrado.

> **Por qué `/media` en `rw`**: Sonarr **escribe** la jerarquía `/media/series/<Serie>/Season X/...` por _hardlink_. El _hardlink_ en POSIX es una entrada de directorio nueva apuntando al mismo _inode_; `link(2)` requiere permiso de **escritura** sobre el directorio destino — por eso `:rw` y no `:ro`.

> **`MEDIA_GID` como `group_add`**: el bit `setgid` en `/mnt/hd2t/services/shared/media/` (modo `2775`, grupo `homelab-media`) garantiza que cualquier fichero/directorio nuevo herede el grupo `homelab-media`, no el grupo primario del proceso (`1000`). Pero para _crear_ el fichero, el proceso necesita ser miembro del grupo `homelab-media`. Como Sonarr corre con `PGID=1000` (su grupo primario, igual que Transmission y los demás LSIO), hay que añadirle `homelab-media` como _supplementary group_ vía `group_add: ["${MEDIA_GID}"]` en el compose. Sin esto, Sonarr lograría leer `/media/series/` (modo `0755` permite a "otros") pero **fallaría** al crear/escribir con `Permission denied`.

### `sonarr.db` (SQLite) — Patrón S de respaldo

Idéntica al esquema de Prowlarr. Sonarr usa una BD SQLite (`/config/sonarr.db` + `/config/sonarr.db-shm` + `/config/sonarr.db-wal`) como almacén persistente de:

- _Series_ monitorizadas, episodios, _Quality Profiles_, _Custom Formats_.
- _Indexers_ (poblados por el _Apps Sync_ de Prowlarr; el operador no los toca a mano).
- _Download Clients_ (Transmission con sus credenciales).
- _History_ y _Activity_ (acotados por retención).
- _Notifications_, _Tags_, _Naming_, _Settings_.

La imagen LSIO incluye `sqlite3` dentro del contenedor — `dump_sqlite` del Patrón S funciona directamente:

```bash
docker exec sonarr sqlite3 -version
# 3.40.x ...
```

Por tanto, en `~/homelab/backups/borgmatic/hooks/dump-databases.sh`, la línea para Sonarr (que ya existe **comentada** desde `docs/07-backups/03-backup-docker-volumes.md` y que **no** descomentaron ni `01-transmission.md` ni `02-prowlarr.md`) se descomenta tal cual:

```bash
# Antes:
# dump_sqlite sonarr   sonarr   /config/sonarr.db

# Después:
dump_sqlite sonarr   sonarr   /config/sonarr.db
```

Cada _run_ de Borgmatic produce un fichero `sonarr-<fecha>.sqlite.gz` en `/mnt/hd2t/backups/dumps/` (Patrón S), que se respalda como cualquier otro fichero. Adicionalmente, el árbol entero `/mnt/hd2t/services/sonarr/` entra en `source_directories:` de Borgmatic — esto cubre `config.xml`, `MediaCover/`, `logs/` y los _backups_ internos de Sonarr en `Backups/`. Patrón **S** + redundancia de _filesystem_ por si el dump SQLite fallase un día.

### `Backups/` interno de Sonarr — se mantiene, no se respalda con prioridad

Sonarr genera automáticamente _backups_ internos cada noche en `/config/Backups/scheduled/sonarr_backup_*.zip` (con retención de 7 días por defecto). Son _zip_ que contienen `sonarr.db` + `config.xml` + carpetas auxiliares.

- **No se desactivan**: son útiles para restauraciones rápidas desde la propia web UI (_System → Backup → Restore_) sin tener que tocar Borgmatic.
- **No se excluyen**: ocupan poco (10-50 MB cada uno), se deduplican muy bien.
- **Frecuencia**: ajustable en _Settings → General → Backups_ (`Backup Interval`, `Backup Retention`). Defaults razonables, no se tocan.

### Calendario de _Apps Sync_: Prowlarr → Sonarr (la dirección importa)

Tentación natural del recién llegado a la familia _\*arr_: ir a _Sonarr → Settings → Indexers → Add → Torznab_ y rellenar URL/_API key_ a mano por cada _indexer_. **No se hace así**. La integración correcta es **inversa**:

1. **Sonarr** se despliega sin _indexers_ configurados (este documento).
2. **En Prowlarr**, _Settings → Apps → Add Application → Sonarr_, con:
   - _Sync Level_: `Full Sync`.
   - _Prowlarr Server_: `http://prowlarr:9696/` (DNS interno).
   - _Sonarr Server_: `http://sonarr:8989/` (DNS interno).
   - _API Key_: el `<ApiKey>` de **Sonarr** (no el de Prowlarr — ver **Configuración tras primer arranque**, paso 2).
3. Tras `Test` → `Save`, Prowlarr **propaga** automáticamente cada _indexer_ aplicable a Sonarr. El operador **no toca** _Sonarr → Settings → Indexers_; aparece todo poblado.

Este orden se concreta en **Configuración tras primer arranque** → paso 5. La razón estructural: si el operador añade _indexers_ manualmente en Sonarr antes de hacer el _Apps Sync_, Prowlarr no los reconoce como suyos y duplica entradas; o peor, sobreescribe credenciales si se confunden los nombres. **Una sola fuente de verdad para indexers: Prowlarr.**

### Ubicación de la biblioteca: `/media/series/`

El árbol `/mnt/hd2t/services/shared/media/` ya tiene preparada (o se preparará la primera vez que Sonarr importe) la subcarpeta `series/`. Convención de nombres (consistente con Jellyfin, ver `docs/09-multimedia/01-jellyfin.md`):

```
/mnt/hd2t/services/shared/media/
├── movies/                      ← Radarr (docs/10-descargas/04-radarr.md)
├── series/                      ← Sonarr (este doc)
│   ├── The Expanse (2015)/
│   │   ├── Season 01/
│   │   │   ├── The Expanse - S01E01 - Dulcinea.mkv
│   │   │   └── ...
│   │   └── Season 02/
│   └── ...
└── ...
```

- **Nombre del directorio raíz por serie**: `<Title> (<Year>)` — Sonarr lo deriva del scraper TVDB/TheMovieDB. Permite distinguir _remakes_ y series con el mismo título de años distintos.
- **`Season 01`, `Season 02`, …**: zero-padded a dos dígitos. Convención TRaSH-Guides; Jellyfin las reconoce sin _quirks_.
- **Episodios**: `<Series Title> - SXXEYY - <Episode Title>.mkv`. _Naming pattern_ recomendado por TRaSH (sub-bloque _Sonarr_): `{Series Title} - S{season:00}E{episode:00} - {Episode Title}` para _Standard_ y `{Series Title} - {air-date} - {Episode Title}` para _Daily_. Se aplica en _Settings → Media Management → Episode Naming_ (ver **Configuración tras primer arranque**).

> **Por qué `series/` en singular plural mixto**: convención del homelab para seguir el mismo patrón que `movies/`, `music/`, `audiobooks/`. La forma plural inglesa (`series` ya lo es) evita ambigüedad respecto a `serie/`. Jellyfin también muestra "TV Shows" como categoría; el nombre del directorio es interno y arbitrario.

### `Authentication Method: Forms` con `Authentication Required: Enabled` desde el primer arranque

Idéntica a Prowlarr. Sonarr v3+ exige autenticación obligatoria desde la primera versión `3.0` (no se puede dejar la web UI abierta). Las dos opciones nativas:

| Método                                  | Comportamiento                                                                                                                                                                                                       |
|-----------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **Basic (Browser Popup)**               | Diálogo HTTP _Basic Auth_. Limpio para CLI/clientes _native_, pero los gestores de contraseñas no rellenan _basic auth_ y no hay logout limpio.                                                                       |
| **Forms (Login Page)** ✅                | Página de login HTML, _cookie_ de sesión, _Remember me_, logout explícito. Encaja con la familia _\*arr_ (Prowlarr/Radarr usan el mismo patrón) y los gestores de contraseñas (Vaultwarden cuando llegue) lo soportan. |

Variables de entorno LSIO específicas que activan este comportamiento desde el primer arranque (en lugar de tener que entrar a la web UI a configurarlas):

```ini
SONARR__AUTH__METHOD=Forms
SONARR__AUTH__REQUIRED=Enabled
```

> Estas variables **sólo aplican en el primer arranque** (cuando `config.xml` no existe). En arranques posteriores, `config.xml` es la fuente de verdad. Para cambiarlas a posteriori, editar `config.xml` con el contenedor parado o usar la web UI.

---

## Estructura del _stack_ `descargas` tras este documento

Aprovecha el _stack_ ya existente, extendido por Transmission (`docs/10-descargas/01-transmission.md`) y Prowlarr (`docs/10-descargas/02-prowlarr.md`):

```
~/homelab/descargas/
├── docker-compose.yml        # ← extendido (añade servicio sonarr)
├── .env                      # ← extendido (añade SONARR_IMAGE_TAG)
├── .env.example              # ← extendido (añade SONARR_IMAGE_TAG)
└── .gitignore                # (sin cambios)
```

Y en los discos externos, sobre lo que ya creó `docs/01-sistema/04-estructura-directorios.md`:

```
/mnt/hd2t/services/sonarr/
└── (vacío al empezar; el primer arranque lo puebla con
    Backups/, MediaCover/, logs/, config.xml, sonarr.db, …)
```

Verificar que el bind mount existe y tiene el ownership correcto antes de arrancar:

```bash
ls -la /mnt/hd2t/services/sonarr
# total 8
# drwxr-xr-x 2 1000 1000 4096 ... .
# drwxr-xr-x ... services
```

Si por error está como `root:root`, restaurar:

```bash
sudo chown -R 1000:1000 /mnt/hd2t/services/sonarr
sudo chmod 0755 /mnt/hd2t/services/sonarr
```

> **No** crear subdirectorios a mano — Sonarr crea `Backups/`, `MediaCover/`, `logs/`, `xdg/`, etc. con los permisos correctos en el primer arranque.

> **No** pre-crear `/mnt/hd2t/services/shared/media/series/`: Sonarr lo crea al hacer el primer _import_, y al heredar el `setgid` del padre el grupo será `homelab-media` automáticamente. Si por algún motivo el operador prefiere pre-crearlo (p. ej. para hacer un `rsync` previo de una colección), debe hacerlo así:
>
> ```bash
> sudo install -d -o 1000 -g homelab-media -m 2775 /mnt/hd2t/services/shared/media/series
> ```

---

## Variables de entorno

Editar `~/homelab/descargas/.env.example` (versionado en git) y añadir el bloque de Sonarr **al final** (preservando lo que ya tenían Transmission y Prowlarr):

```bash
# --- Imágenes pinneadas -----------------------------------------------------
# Patches automáticos vía Watchtower. Bumps de minor/major a mano leyendo
# https://github.com/Sonarr/Sonarr/releases y
# https://github.com/linuxserver/docker-sonarr/releases.
SONARR_IMAGE_TAG=4.0.10
```

Replicar el cambio en `~/homelab/descargas/.env`:

```bash
$EDITOR ~/homelab/descargas/.env
# Añadir:
# SONARR_IMAGE_TAG=4.0.10
chmod 0600 ~/homelab/descargas/.env
```

> **Sin secretos en `.env`**: igual que Prowlarr, Sonarr **no acepta** la contraseña de _Forms auth_ vía variables de entorno. La cuenta inicial se crea desde la web UI en el primer acceso (ver **Configuración tras primer arranque**). El _API key_ se autogenera por Sonarr y se lee desde `/config/config.xml` cuando lo necesiten Prowlarr (para _Apps Sync_) o cualquier otro consumidor (Homepage/Homarr/Jellyfin).

> **`MEDIA_GID` ya está en el `.env` global** (`~/homelab/.env`, ver `docs/01-sistema/04-estructura-directorios.md` paso 8). Aquí no hace falta declararla de nuevo en `~/homelab/descargas/.env`; el `docker-compose.yml` la referencia con `${MEDIA_GID}`.

---

## `~/homelab/descargas/docker-compose.yml`

Editar el `docker-compose.yml` existente (creado por `docs/10-descargas/01-transmission.md` y extendido por `docs/10-descargas/02-prowlarr.md`) y añadir el servicio `sonarr`. La estructura final relevante queda:

```yaml
---
# Stack: descargas — Transmission + Prowlarr + Sonarr (Radarr en doc siguiente).
# Documentación: docs/10-descargas/{01-transmission,02-prowlarr,03-sonarr}.md

services:

  transmission:
    # ... (sin cambios; ver docs/10-descargas/01-transmission.md)

  prowlarr:
    # ... (sin cambios; ver docs/10-descargas/02-prowlarr.md)

  # ---------------------------------------------------------------------------
  # Sonarr — gestor automatizado de series de TV.
  # En 'homelab' (Caddy, Prowlarr y Transmission la alcanzan por nombre).
  # No publica puertos al host: la web UI y la API sólo se acceden via Caddy
  # (https://sonarr.lan/) o por DNS interno desde Prowlarr/Jellyfin/Homepage.
  # ---------------------------------------------------------------------------
  sonarr:
    image: lscr.io/linuxserver/sonarr:${SONARR_IMAGE_TAG}
    container_name: sonarr
    hostname: sonarr
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
      # interactivo de Sonarr (que aparece sólo si AUTH no está configurado).
      # Tras el primer arranque, /config/config.xml manda — estas variables
      # ya no se vuelven a aplicar.
      SONARR__AUTH__METHOD: Forms
      SONARR__AUTH__REQUIRED: Enabled
      # Nombre de instancia visible en la barra superior y en logs.
      SONARR__APP__INSTANCENAME: Sonarr
      # Sin URL base: cada servicio tiene su propio vhost en Caddy.
      SONARR__SERVER__URLBASE: ""
    # Supplementary group: Sonarr necesita pertenecer a 'homelab-media' para
    # poder crear ficheros bajo /mnt/hd2t/services/shared/media/series/ (que
    # tiene bit setgid y grupo homelab-media). Sin este group_add, los
    # hardlinks fallan con EACCES aunque PUID/PGID estén bien.
    group_add:
      - "${MEDIA_GID}"
    volumes:
      - /mnt/hd2t/services/sonarr:/config
      # Lectura+escritura sobre las descargas de Transmission. Sonarr lee los
      # ficheros completados aquí; el hardlink lo crea en /media/series/, no
      # aquí. /downloads se mantiene rw por si se activa "Remove files when
      # imported -> Hard delete" en Sonarr (no es lo recomendado).
      - /mnt/hd2t/services/transmission/downloads:/downloads
      # Lectura+escritura sobre la biblioteca compartida. Imprescindible para
      # los hardlinks de los .mkv/.mp4 importados.
      - /mnt/hd2t/services/shared/media:/media
      # Hora del host (timestamps de logs y de History).
      - /etc/localtime:/etc/localtime:ro
    # Sin 'ports:' — la web UI :8989 sólo se alcanza por DNS interno.
    networks:
      homelab:
        aliases:
          - sonarr             # Caddy, Prowlarr y futuros consumidores
                               # resuelven 'sonarr:8989'
    labels:
      homelab.stack: "descargas"
      homelab.backup: "true"   # /mnt/hd2t/services/sonarr entra en Borgmatic (Cat. S+F)
      # Opt-in: patches dentro de 4.0.x son seguros (sin breaking changes en
      # sonarr.db ni en config.xml).
      com.centurylinklabs.watchtower.enable: "true"
    healthcheck:
      # /ping responde 200 sin auth — endpoint público diseñado para healthchecks.
      # No usamos /api/v3/system/status (requiere API key) ni / (requiere sesión
      # Forms): /ping es el endpoint canónico de Sonarr para liveness.
      test:
        - CMD-SHELL
        - "wget -qO- --tries=1 --timeout=5 http://localhost:8989/ping 2>&1 | grep -q -i 'pong\\|OK' || exit 1"
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
- **`group_add: ["${MEDIA_GID}"]`**: imprescindible para los _hardlinks_ contra `/services/shared/media/series/`. Si en el futuro `MEDIA_GID` cambiara (regeneración del grupo `homelab-media`), recordar `docker compose up -d --force-recreate sonarr`.
- **`depends_on` con `condition: service_healthy`**: Sonarr arranca tras Transmission y Prowlarr para que sus _Health checks_ internos no dejen avisos amarillos durante el primer arranque del stack. Si Prowlarr o Transmission cayeran después, Sonarr **no** se reinicia automáticamente — `depends_on` sólo aplica al _start_, no al _runtime_.
- **`SONARR__AUTH__METHOD` y `SONARR__AUTH__REQUIRED`**: la imagen LSIO traduce variables `SONARR__SECCION__CLAVE=valor` a entradas en `config.xml` en el primer arranque (vía `s6-overlay`). Sólo se aplican si `config.xml` aún **no** existe.
- **`SONARR__SERVER__URLBASE: ""`**: explícito para evitar que un wizard previo o un copy-paste de otro homelab haya dejado un valor distinto.
- **Sin `user:` explícito**: LSIO maneja el UID/GID con su propio _entrypoint_ s6-overlay; usar `user:` en paralelo confunde al `s6-overlay` y rompe el `chown` automático del nivel superior y el `group_add`.
- **Sin `ports:`**: Sonarr es accesible sólo via Caddy (`sonarr.lan`) y via DNS interno (`sonarr:8989` desde Prowlarr / Jellyfin / Homepage / etc.).
- **`/etc/localtime:/etc/localtime:ro`**: además de `TZ`, montar `/etc/localtime` cubre los _timestamps_ que Sonarr imprime en `History` y en los logs.
- **`start_period: 90s`**: el primer arranque de Sonarr es **más lento** que el de Prowlarr (~60-90 s) — el _entrypoint_ ejecuta `Migrate` sobre `sonarr.db` (vacío al principio, así que es rápido, pero el _runtime_ .NET necesita su tiempo) y el _scraper_ inicial de TheTVDB se hace en _background_. `start_period: 90s` deja margen suficiente sin bloqueos espurios del _healthcheck_ durante el _bootstrap_.
- **Healthcheck sobre `/ping`**: Sonarr expone `GET /ping` sin autenticación — endpoint canónico para _liveness probes_. Devuelve `200 OK` con cuerpo `{"status":"OK"}` (o `pong`/`OK` según la versión).
- **Watchtower opt-in**: razones explicadas en **Decisiones de diseño** → _Imagen y tag_.
- **No `mem_limit` ni `cpus`**: Sonarr consume poco-medio (~200-400 MB RAM con una biblioteca de 50-100 series, <5 % CPU idle, picos breves de ~30-50 % CPU durante búsquedas masivas o _RSS Sync_). La política por defecto (sin límite) está bien.

---

## Despliegue

### Primer arranque

```bash
cd ~/homelab/descargas
docker compose --env-file ../.env --env-file .env config | head -80   # validar sintaxis
docker compose --env-file ../.env --env-file .env up -d sonarr
```

O, equivalente, con el _Makefile_ (ver `docs/02-docker/02-estructura-compose.md`):

```bash
cd ~/homelab
make up STACK=descargas
```

Vigilar el primer arranque (tarda ~60-90 s):

```bash
docker compose -f ~/homelab/descargas/docker-compose.yml logs -f sonarr
# ...
# sonarr | [migrations] started
# sonarr | [migrations] no migrations found
# sonarr | [custom-init] No custom files found, skipping...
# sonarr | [ls.io-init] done.
# sonarr | [Info] Microsoft.Hosting.Lifetime: Now listening on: http://[::]:8989
# sonarr | [Info] Microsoft.Hosting.Lifetime: Application started.
# sonarr | [s6-init] ready.
```

Verificar que el contenedor está `(healthy)`:

```bash
docker compose -f ~/homelab/descargas/docker-compose.yml ps sonarr
# NAME    STATUS                   PORTS
# sonarr  Up X seconds (healthy)
```

> El `(healthy)` lo otorga el _healthcheck_ que confirma que `/ping` responde HTTP `200`. Si tras 120 s sigue `starting`, ir a **Troubleshooting** → primer arranque.

Comprobar que `config.xml` se ha generado con los valores esperados:

```bash
sudo cat /mnt/hd2t/services/sonarr/config.xml
# <Config>
#   <BindAddress>*</BindAddress>
#   <Port>8989</Port>
#   <SslPort>9898</SslPort>
#   <EnableSsl>False</EnableSsl>
#   <LogLevel>info</LogLevel>
#   <AnalyticsEnabled>True</AnalyticsEnabled>
#   <UrlBase></UrlBase>
#   <InstanceName>Sonarr</InstanceName>
#   <ApiKey>abc123def456...</ApiKey>           ← autogenerado, anótalo
#   <AuthenticationMethod>Forms</AuthenticationMethod>
#   <AuthenticationRequired>Enabled</AuthenticationRequired>
#   <Branch>main</Branch>
#   <LaunchBrowser>False</LaunchBrowser>
# </Config>
```

> **Apuntar el `<ApiKey>`**: lo necesitará Prowlarr en su _Apps → Add Application → Sonarr → API Key_. También lo consumirán Jellyfin/Homepage/Homarr cuando lleguen.

Comprobar que el _supplementary group_ está activo dentro del contenedor:

```bash
docker exec sonarr id
# uid=1000(abc) gid=1000(abc) groups=1000(abc),100(users),<MEDIA_GID>(homelab-media)
```

Si `homelab-media` **no** aparece, el `group_add` no se aplicó — revisar el `.env` global (`MEDIA_GID` debe estar rellenado con el GID real) y `docker compose up -d --force-recreate sonarr`.

### Caddy: bloque `sonarr.lan`

Editar `~/homelab/red/Caddyfile` y añadir el bloque (situarlo junto al de `prowlarr.lan` para mantener la sección de `descargas` agrupada):

```caddy
sonarr.lan {
    tls internal
    import security-headers
    import logging

    reverse_proxy sonarr:8989 {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
    }
}
```

> **No** se necesita `redir / /...` (a diferencia de Transmission): Sonarr ya sirve la UI en la raíz. **No** se añade `import authelia` (ver **Decisiones de diseño**).

Validar y recargar Caddy:

```bash
docker exec caddy caddy validate --config /etc/caddy/Caddyfile
docker exec caddy caddy reload --config /etc/caddy/Caddyfile
```

Probar (la CA local debe estar importada en el navegador, ver `docs/03-red/04-caddy.md`):

```bash
# /ping: sin auth, debe responder 200
curl -k --resolve sonarr.lan:443:192.168.1.3 \
     -I https://sonarr.lan/ping
# HTTP/2 200

# /: redirige al login si no hay sesión (302 hacia /login)
curl -k --resolve sonarr.lan:443:192.168.1.3 \
     -I https://sonarr.lan/
# HTTP/2 302
# location: /login

# /api/v3/system/status sin API key: 401
curl -k --resolve sonarr.lan:443:192.168.1.3 \
     -I https://sonarr.lan/api/v3/system/status
# HTTP/2 401
```

Y desde el navegador: `https://sonarr.lan/` → redirección a `/login` → formulario _Forms_ → primera vez se crea la cuenta administrador (ver siguiente sección).

---

## Configuración tras primer arranque

### 1. Crear la cuenta administrador

En el primer acceso a `https://sonarr.lan/`, Sonarr muestra el formulario de _Forms_ pidiendo **crear** el usuario administrador (no es un login contra una cuenta existente — es un _setup_ inicial):

- **Username**: el operador elige (no tiene que coincidir con el del sistema).
- **Password**: contraseña fuerte. Apuntar en el gestor del operador (cuando llegue Vaultwarden, mover allí).

Tras crear la cuenta, Sonarr redirige al _dashboard_ vacío. Confirmar que _Settings → General → Security_ muestra:

- _Authentication: Forms (Login Page)_
- _Authentication Required: Enabled_
- _API Key_: el mismo valor que aparece en `config.xml`.

### 2. Verificar el `<ApiKey>` y guardarlo

```bash
sudo grep -oP '<ApiKey>\K[^<]+' /mnt/hd2t/services/sonarr/config.xml
# abc123def456...
```

Apuntar este valor en el gestor del operador con la etiqueta `sonarr-api-key`. Lo necesitarán:

- **Prowlarr** en _Settings → Apps → Add Application → Sonarr → API Key_.
- **Jellyfin/Homepage/Homarr** (cuando lleguen) para consultar la cola y el calendario de Sonarr vía `X-Api-Key`.

### 3. Configurar _Media Management_

_Settings → Media Management_ — los valores por defecto son razonables; los cambios mínimos del homelab:

- **Episode Naming**:
  - _Rename Episodes_: `Yes`
  - _Replace Illegal Characters_: `Yes`
  - _Standard Episode Format_: `{Series Title} - S{season:00}E{episode:00} - {Episode Title} {Quality Full}` _(o el patrón TRaSH-Guides actual; ver Referencias)_
  - _Daily Episode Format_: `{Series Title} - {air-date} - {Episode Title} {Quality Full}`
  - _Series Folder Format_: `{Series Title} ({Series Year})`
  - _Season Folder Format_: `Season {season:00}`

- **Folders**:
  - _Create empty series folders_: `No` (evita folders fantasma cuando Sonarr aún no ha descargado nada).
  - _Delete empty folders_: `Yes`.

- **Importing**:
  - _Use Hardlinks instead of Copy_: ✅ **Yes** (crítico — sin esto los _imports_ duplican espacio).
  - _Import Extra Files_: `srt, ass, ssa, sub, idx` (subtítulos junto al `.mkv`).
  - _Unmonitor Deleted Episodes_: `Yes` (cuando se borra un episodio del filesystem, deja de buscarlo).

- **File Management**:
  - _Use hardlinks instead of copy_: ✅ **Yes** (redundante con _Importing_; actívalo en ambos).
  - _Set Permissions_: `Yes`.
  - _chmod Folder_: `775`, _chmod File_: `664`.
  - _chown Group_: dejar en blanco (el `setgid` del padre se encarga; forzarlo aquí provoca conflictos).

- **Add Root Folder**:
  - _Path_: `/media/series` (la ruta dentro del contenedor; el host es `/mnt/hd2t/services/shared/media/series/`).
  - Sonarr crea el directorio si no existe — al heredar `setgid` del padre, el grupo será `homelab-media`.

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
| **Category**             | `tv-sonarr` (Sonarr la pasa como label a Transmission)            |
| **Post-Import Category** | _vacío_ (opcional; se puede usar para agrupar imports completos)  |
| **Recent Priority**      | `Last`                                                            |
| **Older Priority**       | `Last`                                                            |
| **Use SSL**              | ❌ (DNS interno, sin TLS — Caddy es el único punto TLS del homelab) |

_Test_ debe pasar (Sonarr hace una llamada `session-stats` contra Transmission y comprueba la respuesta). Si falla:

- `401 Unauthorized`: revisar usuario/contraseña; si coinciden con el `.env` del `descargas` y siguen fallando, ver Transmission → _Troubleshooting_ → "401 Unauthorized desde el navegador a pesar de tener la contraseña correcta".
- `409 Conflict`: la _CSRF_ de Transmission. Sonarr la maneja correctamente; si aparece, suele ser por una versión muy vieja de Transmission o de Sonarr. Pinear las versiones del homelab cubre el caso.
- `Failed to connect`: revisar que `transmission` resuelve por DNS interno: `docker exec sonarr getent hosts transmission` debe devolver una IP `172.20.10.x`.

_Save_ y comprobar que el _Health check_ de Sonarr (_System → Health_) **no** reporta avisos sobre _Download Clients_.

> _Settings → Download Clients → Completed Download Handling_ — defaults razonables, no se tocan: _Enable: Yes_, _Redownload: No_. Esto activa el flujo "Transmission marca completed → Sonarr lo importa por hardlink → Sonarr le pide a Transmission que retire el _torrent_ (manteniendo o no los ficheros según _Remove Completed_)".

> _Remove Completed_ y _Remove Failed_: dejar **deshabilitados** por defecto. Si en el futuro se quiere "limpiar" Transmission tras el _import_, activarlos con cuidado: _Remove Completed_ borra el `.torrent` de Transmission **pero** mantiene los ficheros en `/downloads/` (el _hardlink_ ya está creado en `/media/series/`, así que no hay pérdida de espacio gracias al _hardlink_, pero sí se pierde el _seeding_ del torrent original). Tradeoff entre _seeding ratio_ y _disk hygiene_.

### 5. _Apps Sync_ desde Prowlarr → Sonarr

Aquí se cierra el círculo del **stack `descargas`**. **En Prowlarr**, _Settings → Apps → Add Application → Sonarr_:

| Campo               | Valor                                                                 |
|---------------------|-----------------------------------------------------------------------|
| **Name**            | `Sonarr`                                                              |
| **Sync Level**      | `Full Sync` (Prowlarr crea/actualiza/borra _indexers_ en Sonarr)      |
| **Tags**            | _vacío_ (o un Tag específico si se quiere segmentar)                  |
| **Prowlarr Server** | `http://prowlarr:9696`                                                |
| **Sonarr Server**   | `http://sonarr:8989`                                                  |
| **API Key**         | el `<ApiKey>` de **Sonarr** (paso 2 — no el de Prowlarr)              |

_Test_ debe pasar (Prowlarr hace `GET /api/v3/system/status` contra Sonarr con el _API key_). _Save_.

Tras `Save`, ir a **Sonarr → Settings → Indexers** y verificar que aparecen los _indexers_ que el operador haya configurado en Prowlarr. **No tocar** estos _indexers_ desde Sonarr — son administrados por Prowlarr; cualquier cambio se hace desde Prowlarr y se sincroniza.

> Si _Settings → Indexers_ en Sonarr está vacío tras el _Sync_, comprobar:
>
> - Que en **Prowlarr** hay al menos un _indexer_ activo.
> - Que el _Sync Profile_ asociado a ese _indexer_ permite tipo "TV". Por defecto, todos los _indexers_ pasan a Sonarr; si el operador acotó el _Sync Profile_ a sólo "Movies", Sonarr no recibe nada.
> - El log de Prowlarr (_System → Logs_) debe mostrar `Synced indexers to <App>:Sonarr` tras el _Save_.

### 6. Configurar _Quality Profiles_ y _Custom Formats_

_Settings → Profiles → Quality Profiles_ — los _profiles_ por defecto (`Any`, `SD`, `HD-720p`, `HD-1080p`, `Ultra-HD`) cubren el caso básico. Para una configuración _state of the art_ alineada con TRaSH-Guides:

- _Settings → Custom Formats_: importar JSON de TRaSH-Guides (ver Referencias). Cubre HDR, _release groups_, codecs, etc.
- _Settings → Profiles → Quality Profiles → HD-1080p_: ajustar _Custom Formats_ con _scores_ recomendados de TRaSH para priorizar releases con HDR10/Dolby Vision sobre SDR, evitar _CAM/Telesync_, etc.

> **Recomendación operativa**: para empezar, _Quality Profile = HD-1080p_ con _Cutoff = HDTV-1080p_ y _Custom Formats_ vacío. Cuando Sonarr esté funcionando con un par de series, importar TRaSH-Guides. La automatización fina es un trabajo iterativo; no bloquea el _bootstrap_.

> **Recyclarr** (sincronización automática de _Quality Profiles_ y _Custom Formats_ desde TRaSH-Guides): _opt-in_ avanzado. Se documenta como anexo cuando el operador lo pida. Para empezar, configuración manual es suficiente.

### 7. Conectar Sonarr a Jellyfin (opcional)

_Settings → Connect → Add → Jellyfin_:

| Campo            | Valor                                                                     |
|------------------|---------------------------------------------------------------------------|
| **Name**         | `Jellyfin`                                                                |
| **On Grab**      | ❌                                                                        |
| **On Import**    | ✅ (notifica a Jellyfin para que escanee la biblioteca tras un import)    |
| **On Upgrade**   | ✅                                                                        |
| **On Rename**    | ✅                                                                        |
| **On Delete**    | ✅                                                                        |
| **Host**         | `jellyfin` (DNS interno)                                                  |
| **Port**         | `8096`                                                                    |
| **API Key**      | el `<ApiKey>` de Jellyfin (`docs/09-multimedia/01-jellyfin.md`)           |
| **Use SSL**      | ❌                                                                        |
| **Send Notifications** | ✅                                                                  |

_Test_ debe pasar. Tras esto, cuando Sonarr importe un episodio nuevo, le pedirá a Jellyfin que refresque la biblioteca `series` — el episodio aparece en Jellyfin sin esperar al cron interno (que sería cada hora o así).

> Si Jellyfin aún no está desplegado, saltarse este paso. Volver a él cuando se complete `docs/09-multimedia/01-jellyfin.md`.

### 8. Añadir la primera serie

_Series → Add New → Buscar "<título>"_ → seleccionar la serie correcta (ojo a remakes, _years_) → _Add Series_:

- _Root Folder_: `/media/series` (debe estar en la lista; lo añadimos en paso 3).
- _Monitor_: `Future Episodes` (a partir de "ahora" busca episodios nuevos), `All Episodes` (busca catálogo entero — ojo al ancho de banda y al espacio), o el granular que prefiera el operador.
- _Quality Profile_: `HD-1080p` (o el que se haya configurado).
- _Series Type_: `Standard` (la mayoría) / `Daily` (talkshows, news) / `Anime` (numeración absoluta).
- _Season Folder_: ✅.
- _Tags_: opcional, útil para reglas avanzadas.
- _Start search for missing episodes_: ✅ (Sonarr lanza una búsqueda automática tras el _Add_).

Sonarr empieza a buscar releases en los _indexers_, pasa los _torrents_ que cumplen el _Quality Profile_ a Transmission con la categoría `tv-sonarr`, y, una vez Transmission completa la descarga, Sonarr la importa por _hardlink_ a `/media/series/<Serie>/Season XX/`.

> **Verificar el flujo completo**: tras añadir la primera serie y esperar unos minutos:
>
> ```bash
> # 1. Sonarr ha enviado el .torrent a Transmission:
> docker exec transmission transmission-remote -n "${TRANSMISSION_USER}:${TRANSMISSION_PASS}" -l
> # Debe listar al menos un torrent con label "tv-sonarr".
>
> # 2. Cuando Transmission termina y Sonarr importa, el fichero aparece en /media/series:
> ls /mnt/hd2t/services/shared/media/series/
> # The Expanse (2015)/  ...
>
> # 3. El fichero es un hardlink (mismo inode que el de /downloads):
> stat -c '%i' /mnt/hd2t/services/transmission/downloads/<release>.mkv \
>             /mnt/hd2t/services/shared/media/series/<Serie>/Season\ 01/<...>.mkv
> # Ambos números deben coincidir — confirma hardlink, no copia.
> ```

### 9. Configurar `Backup Retention` (opcional)

_Settings → General → Backups_:

- **Backup Folder**: `/config/Backups` (default, **no tocar**).
- **Backup Interval**: `7` días (default).
- **Backup Retention**: `28` días (subido respecto al default `7` para tener un mes de _backups_ internos rotables).

---

## Almacenamiento

Tras el primer arranque y la importación de varias series, el árbol `/mnt/hd2t/services/sonarr/` queda con los siguientes ficheros relevantes:

```
/mnt/hd2t/services/sonarr/
├── config.xml                      # <ApiKey>, <AuthenticationMethod>, etc.
├── sonarr.db                       # SQLite — series, episodes, history, profiles
├── sonarr.db-shm                   # SQLite shared memory (transitorio)
├── sonarr.db-wal                   # SQLite WAL (transitorio)
├── Backups/
│   ├── manual/
│   └── scheduled/
│       └── sonarr_backup_v4.0.10.x_2026.04.27_03.00.00.zip
├── MediaCover/                     # posters, fanart por serie
│   ├── 1/
│   ├── 2/
│   └── ...
├── logs/
│   ├── sonarr.txt                  # log activo
│   └── archive/
│       └── sonarr.X.txt.gz         # logs rotados
├── xdg/                            # caché de .NET runtime (efímero)
│   └── ...
└── update_logs/
    └── ...
```

| Ruta                                                | Permisos          | Contenido                                                  |
|-----------------------------------------------------|-------------------|------------------------------------------------------------|
| `/mnt/hd2t/services/sonarr/`                        | `1000:1000 0755`  | Raíz del bind mount                                        |
| `/mnt/hd2t/services/sonarr/config.xml`              | `1000:1000 0644`  | Configuración (incluye el `<ApiKey>` en claro)             |
| `/mnt/hd2t/services/sonarr/sonarr.db`               | `1000:1000 0644`  | BD SQLite (incluye credenciales de Transmission y Jellyfin encriptadas con clave derivada de `<ApiKey>`) |
| `/mnt/hd2t/services/sonarr/Backups/scheduled/`      | `1000:1000 0755`  | _Backups_ internos diarios                                 |
| `/mnt/hd2t/services/sonarr/MediaCover/`             | `1000:1000 0755`  | _Posters_ y _fanart_ por serie                             |
| `/mnt/hd2t/services/sonarr/logs/`                   | `1000:1000 0755`  | Logs (rotación interna por Sonarr)                         |
| `/mnt/hd2t/services/shared/media/series/`           | `1000:homelab-media 2775` | Biblioteca de series (heredado del padre con setgid) |
| `/mnt/hd2t/services/shared/media/series/<S>/<...>.mkv` | `1000:homelab-media 0664` | Episodios — hardlinks a `/services/transmission/downloads/...` |

> **Sobre `config.xml` con permisos `0644`**: contiene el `<ApiKey>` en claro. Consideraciones idénticas a Prowlarr (ver `docs/10-descargas/02-prowlarr.md` → **Almacenamiento**). Endurecer a `0640` o `0600` está bien y no rompe nada:
>
> ```bash
> sudo chmod 0640 /mnt/hd2t/services/sonarr/config.xml
> ```

> **Sobre `sonarr.db`**: Sonarr **encripta** las credenciales sensibles (contraseña de Transmission, _API key_ de Jellyfin) usando una clave derivada de `<ApiKey>`. Si se filtra `sonarr.db` **sin** `config.xml`, las credenciales no son trivialmente extraíbles; con ambos, sí. Por eso el _bind mount_ entero es Categoría A en términos de sensibilidad.

> **Sobre los _hardlinks_**: cada `.mkv` en `/media/series/` ocupa **0 bytes adicionales** mientras el mismo _inode_ siga referenciado desde `/downloads/`. Cuando el operador (o Transmission tras `Remove Completed`) borra el `.torrent`, el _link count_ del _inode_ baja de 2 a 1, y el fichero pasa a "vivir" en `/media/series/` exclusivamente. `du -h /mnt/hd2t/services/shared/media/series/` puede dar números engañosamente grandes si se cuentan los _inodes_ compartidos; usar `du -hs --apparent-size` para "tamaño aparente" o `find ... -links 1` para "ficheros que ya no comparten".

---

## Backup

Patrón **S** (SQLite vía `dump_sqlite`) + Patrón **F** (filesystem-only para `config.xml`, `MediaCover/`, `Backups/`).

### 1. Confirmar que `source_directories:` ya cubre Sonarr

El `config.yaml` de Borgmatic (`docs/07-backups/02-borgmatic.md`) ya incluye `/mnt/hd2t/services/sonarr` en `source_directories:` (ver `docs/07-backups/01-estrategia-backup.md` → **Inventario consolidado de fuentes**, línea `- /mnt/hd2t/services/sonarr`). **No hay que añadir nada**.

### 2. Excluir el WAL de SQLite y `xdg/` (recomendado)

Análogo a Prowlarr. Editar:

```bash
$EDITOR ~/homelab/backups/borgmatic/config.yaml
```

```yaml
exclude_patterns:
  # ... entradas existentes ...

  # Sonarr — SQLite WAL/SHM transitorios; el dump del Patrón S los integra
  # en sonarr.db antes de leer. La copia "viva" del .db sí entra como
  # filesystem-only (defensa en profundidad), pero el WAL no aporta nada.
  - /mnt/hd2t/services/sonarr/sonarr.db-wal
  - /mnt/hd2t/services/sonarr/sonarr.db-shm

  # xdg/ es caché del runtime .NET; regenerable.
  - /mnt/hd2t/services/sonarr/xdg
```

> El propio `sonarr.db` **se mantiene** en los _source_directories_ (no se excluye): es la "copia viva" que entra como Categoría F, complementaria al dump del Patrón S.

> **Sobre `/mnt/hd2t/services/shared/media/series/`**: **NO** se respalda con Borgmatic (Categoría C en la estrategia — regenerable mediante re-descarga). Ya está cubierto por la exclusión global de `/mnt/hd2t/services/shared/media/` que añadió `docs/07-backups/01-estrategia-backup.md`. Si el operador prefiere respaldarlo igualmente (porque ciertas series no son re-descargables fácilmente), debe quitarse esa exclusión — fuera de alcance de este doc.

### 3. Descomentar el bloque del hook `dump-databases.sh`

Editar el script:

```bash
$EDITOR ~/homelab/backups/borgmatic/hooks/dump-databases.sh
```

Localizar el bloque (Prowlarr lo dejó así tras `docs/10-descargas/02-prowlarr.md`):

```bash
# --- *arr family (Sonarr/Radarr/Prowlarr — SQLite) — docs/10-descargas/0[3-2].md
# dump_sqlite sonarr   sonarr   /config/sonarr.db
# dump_sqlite radarr   radarr   /config/radarr.db
dump_sqlite prowlarr prowlarr /config/prowlarr.db
```

Y descomentar **únicamente** la línea de Sonarr (la de Radarr queda comentada hasta `docs/10-descargas/04-radarr.md`):

```bash
# --- *arr family (Sonarr/Radarr/Prowlarr — SQLite) — docs/10-descargas/0[3-2].md
dump_sqlite sonarr   sonarr   /config/sonarr.db
# dump_sqlite radarr   radarr   /config/radarr.db
dump_sqlite prowlarr prowlarr /config/prowlarr.db
```

Reinstalar el script con el cambio:

```bash
~/homelab/backups/borgmatic/install.sh
```

### 4. Verificar el dump manualmente

```bash
sudo /etc/borgmatic.d/hooks/dump-databases.sh
# [dump] sonarr: OK -> /mnt/hd2t/backups/dumps/sonarr-2026-04-27.sqlite.gz
# [dump] prowlarr: OK -> /mnt/hd2t/backups/dumps/prowlarr-2026-04-27.sqlite.gz
ls -la /mnt/hd2t/backups/dumps/sonarr-*.sqlite.gz | tail -3
```

Validar integridad:

```bash
gunzip -c /mnt/hd2t/backups/dumps/sonarr-2026-04-27.sqlite.gz | file -
# /dev/stdin: SQLite 3.x database, ...
```

Y que se puede leer:

```bash
gunzip -c /mnt/hd2t/backups/dumps/sonarr-2026-04-27.sqlite.gz \
  > /tmp/sonarr-restore-test.db
sqlite3 /tmp/sonarr-restore-test.db '.tables' | head -10
# Blocklist               History               PendingReleases
# Commands                Indexers              Profiles
# Config                  MetadataFiles         QualityDefinitions
# CustomFormats           Notifications         Restrictions
# DownloadClients         ...
rm /tmp/sonarr-restore-test.db
```

### 5. Confirmar que el archive incluye Sonarr tras el siguiente run

```bash
sudo bash -c '
  set -a; . /etc/borgmatic.d/secrets.env; set +a
  borg list --short "$BORG_REPO_LOCAL" | tail -1
'
# pi-2026-04-28T03:30:30

sudo bash -c '
  set -a; . /etc/borgmatic.d/secrets.env; set +a
  borg list "$BORG_REPO_LOCAL::pi-2026-04-28T03:30:30" \
    | grep -E "sonarr" | head -10
'
# -rw-r--r-- 1000 1000 1.4K Apr 28 02:00 mnt/hd2t/services/sonarr/config.xml
# -rw-r--r-- 1000 1000  35M Apr 28 02:00 mnt/hd2t/services/sonarr/sonarr.db
# drwxr-xr-x 1000 1000    - Apr 28 02:00 mnt/hd2t/services/sonarr/Backups
# ...
# -rw-r--r-- root root  4.2M Apr 28 03:30 mnt/hd2t/backups/dumps/sonarr-2026-04-28.sqlite.gz
# ...
```

Confirmar que **NO** aparecen `sonarr.db-wal`, `sonarr.db-shm` ni `xdg/`:

```bash
sudo bash -c '
  set -a; . /etc/borgmatic.d/secrets.env; set +a
  borg list "$BORG_REPO_LOCAL::pi-2026-04-28T03:30:30" \
    | grep -E "sonarr.db-(wal|shm)|sonarr/xdg"
'
# (vacío)
```

### Restauración

Procedimiento del **Patrón S — SQLite** documentado en `docs/07-backups/03-backup-docker-volumes.md`. Análogo al de Prowlarr:

1. `docker compose -f ~/homelab/descargas/docker-compose.yml stop sonarr`.
2. Mover `/mnt/hd2t/services/sonarr/sonarr.db{,-shm,-wal}` a `sonarr.db.broken-<ts>` (no borrar — preservar 24-48 h).
3. Restaurar el dump más reciente:

   ```bash
   sudo gunzip -c /mnt/hd2t/backups/dumps/sonarr-<fecha>.sqlite.gz \
     > /mnt/hd2t/services/sonarr/sonarr.db
   sudo chown 1000:1000 /mnt/hd2t/services/sonarr/sonarr.db
   sudo chmod 0644 /mnt/hd2t/services/sonarr/sonarr.db
   ```

4. **Caso especial — `config.xml` también corrupto o perdido**: extraer del archive Borg el `config.xml` correspondiente:

   ```bash
   sudo bash -c '
     set -a; . /etc/borgmatic.d/secrets.env; set +a
     borg extract --strip-components 4 \
       "$BORG_REPO_LOCAL::pi-<fecha>" \
       mnt/hd2t/services/sonarr/config.xml
   '
   sudo mv config.xml /mnt/hd2t/services/sonarr/config.xml
   sudo chown 1000:1000 /mnt/hd2t/services/sonarr/config.xml
   ```

   > **Importante**: `config.xml` y `sonarr.db` deben venir del **mismo archive** (mismo `<ApiKey>`). El `<ApiKey>` se usa para derivar la clave de encriptación de credenciales en `sonarr.db`; mezclar archives distintos invalida las credenciales encriptadas (Transmission `Test` devolverá `401`, Jellyfin `Test` también).

5. `docker compose -f ~/homelab/descargas/docker-compose.yml up -d sonarr`.
6. Esperar al `(healthy)`. Sonarr re-leerá `config.xml` y `sonarr.db`; en la web UI, las series, _Quality Profiles_ y _Custom Formats_ deben aparecer tal y como estaban.
7. **Re-validar conexión a Transmission y a Prowlarr**: _Settings → Download Clients → Test_ y _Settings → General → Health_. Si Transmission falla, ver paso 4 (mismo archive).
8. **Re-validar el _Apps Sync_ desde Prowlarr**: ir a Prowlarr → _Settings → Apps → Sonarr → Test_. Si el `<ApiKey>` cambió por la restauración (no debería, viene del archive), reconfigurar el _API Key_ en Prowlarr.

> **Restauración alternativa desde el _backup_ interno de Sonarr**: si el operador prefiere usar el _zip_ que Sonarr genera en `Backups/scheduled/`, puede importarlo desde la web UI (_System → Backup → Choose File → Restore_). Es más cómodo para restauraciones rápidas pero **sólo cubre los últimos 7-28 días** (según `Backup Retention`); para algo más antiguo, ir al archive Borg.

> **Restauración del filesystem `/media/series/`**: **no** se hace desde Borg (excluido). Las series se re-descargan automáticamente cuando Sonarr arranca limpio: con la BD restaurada, Sonarr conoce las series y los episodios, ve que los ficheros físicos no están, y vuelve a buscar y descargar. Tarda lo que tarde el ancho de banda y los _indexers_.

---

## Verificación

Antes de dar por cerrado este documento:

- [ ] `~/homelab/descargas/docker-compose.yml` y `~/homelab/descargas/.env.example` versionados en git con la sección de `sonarr` añadida; `~/homelab/descargas/.env` **no** versionado y con `SONARR_IMAGE_TAG` rellenado.
- [ ] `docker compose -f ~/homelab/descargas/docker-compose.yml ps sonarr` muestra `sonarr` como `(healthy)`.
- [ ] `docker exec sonarr wget -qO- http://localhost:8989/ping` devuelve un cuerpo con `OK`/`pong` (HTTP 200).
- [ ] `docker exec sonarr id` muestra `uid=1000 gid=1000` y `groups=...,<MEDIA_GID>(homelab-media)`.
- [ ] `sudo grep -oP '<ApiKey>\K[^<]+' /mnt/hd2t/services/sonarr/config.xml` devuelve un valor de 32 caracteres alfanuméricos.
- [ ] `sudo grep -oP '<AuthenticationMethod>\K[^<]+' /mnt/hd2t/services/sonarr/config.xml` devuelve `Forms`.
- [ ] `sudo grep -oP '<AuthenticationRequired>\K[^<]+' /mnt/hd2t/services/sonarr/config.xml` devuelve `Enabled`.
- [ ] `docker exec caddy caddy validate --config /etc/caddy/Caddyfile` acepta el bloque `sonarr.lan` añadido.
- [ ] `curl -k --resolve sonarr.lan:443:192.168.1.3 -I https://sonarr.lan/ping` devuelve `HTTP/2 200`.
- [ ] `curl -k --resolve sonarr.lan:443:192.168.1.3 -I https://sonarr.lan/` devuelve `HTTP/2 302` con `location: /login`.
- [ ] `curl -k --resolve sonarr.lan:443:192.168.1.3 -I https://sonarr.lan/api/v3/system/status` devuelve `HTTP/2 401`.
- [ ] `curl -k --resolve sonarr.lan:443:192.168.1.3 -H "X-Api-Key: <APIKEY>" https://sonarr.lan/api/v3/system/status | jq .version` devuelve un string tipo `"4.0.10.x"`.
- [ ] Login interactivo desde el navegador con la cuenta administrador funciona; tras login se ve el _dashboard_ vacío.
- [ ] `ss -tulpn '( sport = :8989 )'` en el host **NO** muestra ningún proceso bindeando ese puerto (Sonarr no publica al host).
- [ ] `docker port sonarr` no lista ningún _mapping_.
- [ ] El bloque `sonarr.lan` del `Caddyfile` lleva `import security-headers` y `import logging`; **no** lleva `import authelia`.
- [ ] La lista `two_factor` del `access_control.rules` de Authelia **no** menciona `sonarr.lan` (ni siquiera comentado).
- [ ] Watchtower vigila el contenedor: `docker logs watchtower --tail 50 | grep sonarr` muestra al menos un check (label `enable: "true"` activo).
- [ ] `stat -c '%U:%G' /mnt/hd2t/services/sonarr /mnt/hd2t/services/sonarr/{config.xml,sonarr.db,Backups,logs}` devuelve `1000:1000` en todos.
- [ ] `~/homelab/backups/borgmatic/hooks/dump-databases.sh` tiene la línea `dump_sqlite sonarr sonarr /config/sonarr.db` **descomentada**; la de `radarr` sigue comentada; la de `prowlarr` sigue descomentada.
- [ ] `sudo /etc/borgmatic.d/hooks/dump-databases.sh && ls /mnt/hd2t/backups/dumps/sonarr-*.sqlite.gz` muestra al menos un dump del día.
- [ ] `gunzip -c /mnt/hd2t/backups/dumps/sonarr-*.sqlite.gz | file -` reporta `SQLite 3.x database`.
- [ ] El siguiente run de Borgmatic incluye `mnt/hd2t/services/sonarr/` y **excluye** `sonarr.db-wal`, `sonarr.db-shm` y `xdg/`.
- [ ] _Settings → General → Security_ en la web UI muestra `Authentication: Forms`, `Authentication Required: Enabled`, y el _API key_ coincide con el del `config.xml`.
- [ ] _Settings → Download Clients_ en Sonarr muestra `transmission` con _Test_ pasando.
- [ ] _Settings → Indexers_ en Sonarr aparece poblado **automáticamente** por el _Apps Sync_ desde Prowlarr (no se han tocado a mano).
- [ ] _Settings → Media Management_ tiene _Use Hardlinks instead of Copy_ activado en _Importing_ y en _File Management_.
- [ ] Tras añadir una serie de prueba y dejar pasar tiempo, _Activity → Queue_ muestra el _torrent_ pasado a Transmission con label `tv-sonarr`.
- [ ] Tras la finalización del _torrent_, _Activity → History_ muestra el _import_ exitoso, y `/mnt/hd2t/services/shared/media/series/<Serie>/Season XX/<...>.mkv` existe con permisos `1000:homelab-media 0664`.
- [ ] El fichero importado es un **hardlink**: `stat -c '%i %h' /mnt/hd2t/services/transmission/downloads/<release>.mkv` y `stat -c '%i %h' /mnt/hd2t/services/shared/media/series/<...>.mkv` devuelven el **mismo `inode`** (primer número) y un `link count` (segundo número) **≥ 2**.

---

## Troubleshooting

### Primer arranque: el contenedor se queda en `starting` indefinidamente

```bash
docker logs sonarr --tail 80
```

Causas comunes:

- **Permisos del bind mount**: si por error se hizo un `chown -R root:root /mnt/hd2t/services/sonarr`, el _entrypoint_ de LSIO falla al hacer `chown` del nivel superior. Restaurar:

  ```bash
  sudo chown -R 1000:1000 /mnt/hd2t/services/sonarr
  docker compose -f ~/homelab/descargas/docker-compose.yml restart sonarr
  ```

- **Migración de BD que falla**: log con `Microsoft.Data.Sqlite.SqliteException: SQLite Error 5: 'database is locked'` o similar. Suele ser por un `sonarr.db-wal` huérfano de un arranque previo no limpio. Solución:

  ```bash
  docker compose -f ~/homelab/descargas/docker-compose.yml stop sonarr
  sudo rm /mnt/hd2t/services/sonarr/sonarr.db-wal \
          /mnt/hd2t/services/sonarr/sonarr.db-shm
  docker compose -f ~/homelab/descargas/docker-compose.yml start sonarr
  ```

- **`SONARR__AUTH__*` ignoradas porque `config.xml` ya existía**: si el bind mount tenía un `config.xml` previo, las variables de entorno **no** se aplican. Para reset completo (mismas precauciones que con Prowlarr):

  ```bash
  docker compose -f ~/homelab/descargas/docker-compose.yml stop sonarr
  sudo mv /mnt/hd2t/services/sonarr/config.xml /mnt/hd2t/services/sonarr/config.xml.bak
  docker compose -f ~/homelab/descargas/docker-compose.yml start sonarr
  ```

  > **Atención**: esto **invalida** las credenciales encriptadas en `sonarr.db` (cambia el `<ApiKey>`). Sólo en _bootstrap_ inicial sin _Download Clients_ aún configurados, o tras restaurar también `sonarr.db` desde un archive del **mismo** `config.xml`.

### `502 Bad Gateway` desde Caddy

Idéntica al equivalente de Prowlarr (`docs/10-descargas/02-prowlarr.md` → **Troubleshooting**). Verificar:

```bash
docker inspect caddy   --format '{{range $net, $cfg := .NetworkSettings.Networks}}{{$net}} {{end}}'
docker inspect sonarr  --format '{{range $net, $cfg := .NetworkSettings.Networks}}{{$net}} {{end}}'
# Ambos deben listar 'homelab'.
```

### `Permission denied` al importar episodios — _hardlink_ falla

El _import_ aparece en _Activity → Queue_ con error `Failed to import` o similar, y _System → Logs_ muestra:

```
[Error] EpisodeImport: Couldn't import episode /downloads/<release>/<file>.mkv:
  System.UnauthorizedAccessException: Access to the path '/media/series/<...>'
  is denied.
```

Causas y soluciones:

- **`MEDIA_GID` no se aplicó como _supplementary group_**: confirmar con `docker exec sonarr id`. Si `homelab-media` no está en `groups`, revisar:
  - `~/homelab/.env` global tiene `MEDIA_GID=<gid real>` (no vacío, no `0`).
  - El compose de Sonarr lleva `group_add: ["${MEDIA_GID}"]`.
  - Recrear: `docker compose -f ~/homelab/descargas/docker-compose.yml up -d --force-recreate sonarr`.

- **Bit `setgid` perdido en `/services/shared/media/`**: comprobar con `stat -c '%a %U:%G' /mnt/hd2t/services/shared/media`:

  ```bash
  # Esperado: 2775 root:homelab-media
  ```

  Si sale `0775` o `0755`, restaurar:

  ```bash
  sudo chmod 2775 /mnt/hd2t/services/shared/media
  sudo find /mnt/hd2t/services/shared/media -type d -exec sudo chmod 2775 {} +
  ```

- **Filesystem distinto** entre `/downloads` y `/media/series`: `link(2)` falla con `EXDEV`. Comprobar `stat -c '%m' /mnt/hd2t/services/transmission/downloads /mnt/hd2t/services/shared/media`. Si difieren, no se puede _hardlink_-ar; Sonarr cae a copia (gasta el doble de espacio). Revisar `fstab` y montajes.

### `Test` del _Download Client_ Transmission devuelve `401 Unauthorized`

Sonarr no autentica contra Transmission. Causas:

- Usuario/contraseña incorrectos: comparar con `~/homelab/descargas/.env` (`TRANSMISSION_USER`, `TRANSMISSION_PASS`).
- Tras una restauración de Transmission, el hash MD5+salt de la password en `settings.json` no es el mismo que la _plain text_ de la `.env`. Ver `docs/10-descargas/01-transmission.md` → **Cambiar la contraseña RPC más adelante**.

### `Test` del _Download Client_ Transmission devuelve `Failed to connect`

DNS interno no resuelve `transmission`. Comprobar:

```bash
docker exec sonarr getent hosts transmission
# 172.20.10.X transmission
```

Si está vacío:

- Sonarr no está en la red `homelab`: revisar el compose.
- Transmission no está corriendo: `docker ps --filter name=transmission`.

### `Test` del _Apps Sync_ desde Prowlarr → Sonarr devuelve `401 Unauthorized`

El `<ApiKey>` que el operador puso en Prowlarr no es el de Sonarr. Confirmar con:

```bash
sudo grep -oP '<ApiKey>\K[^<]+' /mnt/hd2t/services/sonarr/config.xml
# Debe coincidir EXACTAMENTE con el campo "API Key" de Prowlarr → Apps → Sonarr.
```

### `Test` del _Apps Sync_ desde Prowlarr → Sonarr devuelve `Connection failed`

DNS interno entre Prowlarr y Sonarr roto. Comprobar:

```bash
docker exec prowlarr getent hosts sonarr
# 172.20.10.X sonarr
```

Si está vacío, ambos contenedores deben estar en la red `homelab`.

### Sonarr no encuentra ninguna release tras añadir una serie

- _Settings → Indexers_ está vacío: el _Apps Sync_ desde Prowlarr no se ha hecho o falló (ver paso 5 de **Configuración tras primer arranque**).
- _Settings → Indexers_ tiene _indexers_ pero el _Test_ falla: el problema es upstream, en Prowlarr. Ir a `docs/10-descargas/02-prowlarr.md` → **Troubleshooting**.
- _Quality Profile_ demasiado restrictivo: la serie tiene releases pero ninguno cumple. Ajustar.
- _Daily Episode_ vs _Standard Episode_: si la serie es _Daily_ (talkshows, news), Sonarr la trata por fecha de aire en lugar de SXXEYY; releases con SXXEYY no _matchean_. Cambiar el _Series Type_ en _Series → <Serie> → Edit_.

### Episodios importados aparecen en `/media/series/` pero **NO** en Jellyfin

- Jellyfin no ha refrescado la biblioteca. Forzar: _Jellyfin → Dashboard → Libraries → Series → Scan Library_.
- Si el _Connect_ de Sonarr → Jellyfin estaba configurado, _Activity → History_ debería mostrar la notificación. Si no, revisar _Settings → Connect → Jellyfin → Test_.
- El _Library Path_ de Jellyfin no incluye `/media/series`. Revisar en `docs/09-multimedia/01-jellyfin.md` que la _Library_ "TV Shows" apunta a `/media/series`.

### `Health → All Indexers Are Unavailable`

- Si **todos** los _indexers_ están "_unavailable_", el problema es de red/DNS de Sonarr → Prowlarr o de internet → Prowlarr → upstream. Diagnóstico:

  ```bash
  # 1. Sonarr alcanza Prowlarr?
  docker exec sonarr wget -qO- http://prowlarr:9696/ping
  # Debe devolver OK/pong.

  # 2. Prowlarr alcanza upstream?
  docker exec prowlarr wget -qO- https://www.google.com -O /dev/null -S 2>&1 | head -5
  # Debe devolver HTTP/200.
  ```

- Si sólo algunos _indexers_ fallan, suele ser específico de cada _indexer_ (Cloudflare, _site down_, credenciales caducadas). Ir a Prowlarr → _Indexers → <Indexer> → Test_.

### Logs en `/config/logs/sonarr.txt` crecen sin parar

Idéntico a Prowlarr: el _LogLevel_ probablemente está en `Debug` o `Trace`. Volver a `Info`:

`Settings → General → Logging → Log Level: Info` (o ajustar `<LogLevel>info</LogLevel>` en `config.xml` con el contenedor parado).

---

## Actualización

### Patches de la línea `4.0.x` (vía Watchtower, automático)

Watchtower opt-in está activo. Cada domingo a las 04:00 UTC, Watchtower comprueba el _digest_ del _tag_ `4.0.10`; si LSIO publica un re-build (mismo _tag_, distinto _digest_), Watchtower hace `pull` + `recreate` del contenedor. Sin acción del operador.

Verificar tras un domingo:

```bash
docker logs watchtower --tail 50 | grep sonarr
# time=... msg="Found new lscr.io/linuxserver/sonarr:4.0.10 image"
# time=... msg="Stopping /sonarr"
# time=... msg="Creating /sonarr"
```

Si tras la recreación el `(healthy)` no llega en 120 s, ir a **Troubleshooting**.

### Bumps de patch (`4.0.10 → 4.0.11`, manual)

```bash
# 1. Leer las release notes
xdg-open https://github.com/Sonarr/Sonarr/releases/tag/v4.0.11
xdg-open https://github.com/linuxserver/docker-sonarr/releases

# 2. Backup completo previo
sudo /usr/bin/borgmatic --verbosity 1
# Verificar que el último archive tiene fecha de hoy y que el dump
# /mnt/hd2t/backups/dumps/sonarr-<fecha>.sqlite.gz se ha generado.

# 3. Cambiar el tag y aplicar
$EDITOR ~/homelab/descargas/.env
# SONARR_IMAGE_TAG=4.0.11
cd ~/homelab
make pull STACK=descargas
make up STACK=descargas

# 4. Vigilar el log durante el reinicio
docker compose -f ~/homelab/descargas/docker-compose.yml logs -f sonarr
# Buscar:
#   sonarr | [Info] Microsoft.Hosting.Lifetime: Application started.
# Si el log muestra ERROR o el contenedor entra en restart loop, ir a Troubleshooting.

# 5. Validar la web UI, los Download Clients y los Indexers, y System → Status muestra la
#    nueva versión.
```

### Bumps de _minor_ (`4.0 → 4.1`)

- Suelen incluir migraciones de `sonarr.db` (claves nuevas, índices). Hacer SIEMPRE backup completo del bind mount antes:

  ```bash
  sudo systemctl stop docker
  sudo tar czf /mnt/hd2t/backups/sonarr-pre-bump-$(date +%F).tar.gz \
      -C /mnt/hd2t/services sonarr
  sudo systemctl start docker
  ```

- Planificar la actualización en una ventana de mantenimiento.
- Considerar saltar a `4.1.1` o similar (la versión `.0` a menudo tiene bugs que se arreglan en el primer _patch_).
- Tras el _upgrade_, comprobar que las series, _Quality Profiles_, _Custom Formats_ y _Download Client_ siguen activos en la web UI; comprobar también el _Apps Sync_ desde Prowlarr → Sonarr.

### Bumps de _major_ (`4.x → 5.x`)

- Cambios estructurales relevantes; cuando ocurra:
- Leer la guía de migración del proyecto.
- Verificar compatibilidad con Prowlarr (puede requerir actualizar Prowlarr a una versión que entienda la nueva API _Apps_).
- Backup previo (Borgmatic + tar.gz manual del bind mount).
- Plan de _rollback_ (`SONARR_IMAGE_TAG=4.0.10` y `make up STACK=descargas` para volver atrás, restaurando el bind mount del tar.gz si las migraciones de BD eran irreversibles).

---

## Referencias

- Documentación oficial — Sonarr Wiki: <https://wiki.servarr.com/sonarr>
- API v3 — referencia: <https://sonarr.tv/docs/api/>
- Imagen Docker — LinuxServer.io `sonarr`: <https://github.com/linuxserver/docker-sonarr>
- LSIO `sonarr` — Docker Hub: <https://hub.docker.com/r/linuxserver/sonarr>
- Releases de Sonarr (upstream): <https://github.com/Sonarr/Sonarr/releases>
- Variables de entorno LSIO `SONARR__*`: <https://github.com/linuxserver/docker-sonarr#parameters>
- TRaSH-Guides — _Quality Profiles_, _Custom Formats_ y _Naming_: <https://trash-guides.info/Sonarr/>
- Reverse proxy con Caddy — _Servarr_ general: <https://wiki.servarr.com/sonarr/installation#reverse-proxy>
- Recyclarr (sincronización TRaSH-Guides, _opt-in_ avanzado): <https://recyclarr.dev/>
- Documentos relacionados del homelab:
  - `docs/01-sistema/04-estructura-directorios.md` — `/mnt/hd2t/services/sonarr` con ownership `1000:1000`; `/services/shared/media/` con `setgid` y `homelab-media`.
  - `docs/02-docker/02-estructura-compose.md` — convenciones de stacks, red `homelab`, regla `:ro`/`:rw`, `MEDIA_GID` en `.env` global.
  - `docs/02-docker/04-watchtower.md` — opt-in para `4.0.x`, ventana dominical.
  - `docs/03-red/02-pihole.md` — DNS local `*.lan` (cubre `sonarr.lan` por wildcard).
  - `docs/03-red/04-caddy.md` — Caddy, CA local, _snippets_ `security-headers` y `logging`.
  - `docs/03-red/05-tailscale.md` — acceso remoto vía VPN sin abrir puertos en el router.
  - `docs/04-seguridad/01-authelia.md` — por qué Sonarr **no** entra en `forward_auth`.
  - `docs/07-backups/01-estrategia-backup.md` — Categoría A (credenciales encriptadas) + Patrón S (SQLite); Categoría C para `/services/shared/media/series/`.
  - `docs/07-backups/02-borgmatic.md` — `source_directories`, `exclude_patterns`.
  - `docs/07-backups/03-backup-docker-volumes.md` — Patrón S y línea `dump_sqlite sonarr sonarr /config/sonarr.db` (descomentada por este doc).
  - `docs/09-multimedia/01-jellyfin.md` — biblioteca multimedia que consume `/media/series/` en `:ro`.
  - `docs/10-descargas/01-transmission.md` — _stack_ `descargas`, _Download Client_ que recibe los _torrents_ de Sonarr.
  - `docs/10-descargas/02-prowlarr.md` — _Apps Sync_ que pobla los _Indexers_ de Sonarr automáticamente.
  - `docs/10-descargas/04-radarr.md` — gemelo de Sonarr para películas (fase siguiente).
  - `docs/13-operaciones/04-red-y-puertos.md` — política de puertos del homelab.
