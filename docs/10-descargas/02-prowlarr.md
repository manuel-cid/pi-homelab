# Prowlarr (gestor unificado de indexadores)

## Descripción

Despliegue de **Prowlarr** como **gestor unificado de indexadores** del homelab: centraliza la configuración de los _indexers_ (privados y públicos, _torrent_ y _Usenet_) y los **propaga automáticamente** a las aplicaciones consumidoras de la familia _\*arr_ (Sonarr en `docs/10-descargas/03-sonarr.md`, Radarr en `docs/10-descargas/04-radarr.md`) vía su API. Sin Prowlarr, cada _arr_ duplicaría la lista de _indexers_ y tendría que mantenerla a mano; con Prowlarr, se añade un _indexer_ una sola vez y se sincroniza con los _arr_ aplicables. Toda la configuración persistente (`/config/config.xml`, `/config/prowlarr.db` SQLite, logs, _backups_ internos) vive en el disco externo **hd2t** (`/mnt/hd2t/services/prowlarr/`), pre-creado y reasignado a `1000:1000` en `docs/01-sistema/04-estructura-directorios.md` (paso 7, "Reasignar ownership de los servicios LinuxServer.io").

Este documento **continúa el _stack_ `descargas`** (`~/homelab/descargas/`) estrenado por Transmission (`docs/10-descargas/01-transmission.md`): añade el contenedor `prowlarr` al `docker-compose.yml` existente, crea el bloque `prowlarr.lan` en el `Caddyfile`, **descomenta** la línea `dump_sqlite prowlarr prowlarr /config/prowlarr.db` en `~/homelab/backups/borgmatic/hooks/dump-databases.sh` (Patrón S — SQLite) y deja los _placeholders_ vacíos para que Sonarr/Radarr (fases siguientes) hagan el _Apps_ → _Add Application_ contra Prowlarr cuando lleguen.

Caddy (stack `red`, `docs/03-red/04-caddy.md`) expone Prowlarr en `https://prowlarr.lan/` con TLS interno (CA local). Para acceso remoto vía Tailscale (`docs/03-red/05-tailscale.md`), MagicDNS resuelve `pi.<tailnet>.ts.net` y desde ahí el operador llega al mismo backend. Sonarr y Radarr (cuando lleguen) **hablan con Prowlarr por DNS interno de Docker** (`http://prowlarr:9696/`), saltándose Caddy, autenticándose con el _API key_ de Prowlarr.

> **Alcance**: este documento despliega Prowlarr con su autenticación nativa de _Forms_ (usuario + contraseña, _cookie_ de sesión) **activada desde el primer arranque** vía `PROWLARR__AUTH__METHOD=Forms` y `PROWLARR__AUTH__REQUIRED=Enabled`, configura `PROWLARR__APP__INSTANCENAME=Prowlarr`, deja `URL Base` vacía (acceso por _vhost_ propio en Caddy, no por _path_ compartido), y entrega el _runbook_ de respaldo Patrón S sobre `prowlarr.db`. **No** delega autenticación a Authelia vía `forward_auth` (rompería el flujo `Apps → Test` de Sonarr/Radarr si en algún momento se rutara por Caddy, y la _Forms auth_ nativa de Prowlarr ya cubre el caso humano; ver **Decisiones de diseño**). **No** despliega Sonarr (`docs/10-descargas/03-sonarr.md`), **no** despliega Radarr (`docs/10-descargas/04-radarr.md`), **no** despliega FlareSolverr (resolución de retos Cloudflare en _indexers_ públicos): si en el futuro el operador añade _indexers_ que requieran FlareSolverr, se documentará al final de este doc como _opt-in_, pero **no** entra por defecto. **No** carga _indexers_ pre-configurados — son responsabilidad del operador (la elección de _indexers_ es personal y a menudo privada).

> **Recordatorio de red**: Prowlarr **no se publica al host**. La web UI (`:9696`) la alcanza Caddy por DNS interno de Docker (`prowlarr:9696` en la red `homelab`). Pi-hole resuelve `prowlarr.lan → 192.168.1.3` por el _wildcard_ de `02-homelab-local.conf` (ver `docs/03-red/02-pihole.md`). El operador entra siempre por `https://prowlarr.lan/` (LAN) o por el nombre _MagicDNS_ del nodo Tailscale.

---

## Requisitos previos

- `docs/10-descargas/01-transmission.md` completado: el _stack_ `descargas` (`~/homelab/descargas/`) ya existe, su `docker-compose.yml` ya define la red `homelab` como `external`, su `.env` ya tiene `PUID=1000`, `PGID=1000`, `TZ=Europe/Madrid` heredados del `.env` global, y el _Makefile_ del homelab expone `make up STACK=descargas`.
- `docs/01-sistema/04-estructura-directorios.md` completado: `/mnt/hd2t/services/prowlarr/` ya existe con ownership `1000:1000` (paso 7, "Reasignar ownership de los servicios LinuxServer.io"). **No hay que crear nada**: Prowlarr poblará la estructura interna (`Backups/`, `logs/`, `MediaCover/`, `prowlarr.db`, `config.xml`) en el primer arranque.
- `docs/01-sistema/03-seguridad-base.md` completado: `nftables` con `input drop` por defecto. Este documento **no añade** ninguna regla de _firewall_ — Prowlarr no publica puertos al host.
- `docs/02-docker/04-watchtower.md` completado: Prowlarr se etiquetará como **opt-in** explícito (`com.centurylinklabs.watchtower.enable: "true"`), coherente con la lista de "candidatos a _opt-in_ desde el principio" de aquel doc, donde Sonarr/Radarr/Prowlarr aparecen nominalmente.
- `docs/03-red/02-pihole.md` completado: Pi-hole resuelve `*.lan → 192.168.1.3`. **No hay que añadir nada** para `prowlarr.lan` — el _wildcard_ ya lo cubre.
- `docs/03-red/04-caddy.md` completado: Caddy escucha en `192.168.1.3:443` con `tls internal`, los _snippets_ `security-headers.caddy` y `logging.caddy` existen, la directiva `import /etc/caddy/snippets/*.caddy` está activa en el `Caddyfile` y la CA local firma `*.lan`.
- `docs/04-seguridad/01-authelia.md` completado **opcionalmente**: si Authelia ya está montada, en este documento se decide explícitamente **no** poner Prowlarr detrás de `forward_auth`. La lista `two_factor` del `access_control.rules` de Authelia **no incluye** `prowlarr.lan` (ni siquiera comentado).
- `docs/07-backups/02-borgmatic.md` y `docs/07-backups/03-backup-docker-volumes.md` completados: el `source_directories: /mnt/hd2t/services` ya engloba `prowlarr/`, y la línea `dump_sqlite prowlarr prowlarr /config/prowlarr.db` ya está **comentada** en `~/homelab/backups/borgmatic/hooks/dump-databases.sh`. Este documento la **descomenta**.
- Conectividad saliente para descargar la imagen (sólo la primera vez):

  ```bash
  docker pull --platform linux/arm64 lscr.io/linuxserver/prowlarr:1.21.2 >/dev/null && echo OK
  ```

  El _tag_ exacto se consulta en <https://github.com/linuxserver/docker-prowlarr/pkgs/container/prowlarr>; la convención del homelab prohíbe `:latest` (ver `docs/02-docker/02-estructura-compose.md`, sección **Imágenes**).

- Que el host **no** tenga ya un servicio escuchando en `:9696`:

  ```bash
  sudo ss -tulpn '( sport = :9696 )'
  ```

  Salida esperada: vacía. Prowlarr no publica `:9696` al host (Caddy lo alcanza por DNS interno), pero conviene confirmar que ningún binario residual lo ocupa por si más adelante el operador, durante un _troubleshoot_, añadiese un `ports: ["9696:9696"]` improvisado.

- Espacio en `/mnt/hd2t`: como mínimo **500 MB libres** para `prowlarr/` en estado estable (`prowlarr.db` SQLite con un par de docenas de _indexers_ ronda **5-20 MB**, `logs/` con rotación interna **10-50 MB**, `Backups/` internos diarios de Prowlarr **5-30 MB**, `MediaCover/` con _favicons_ y _thumbnails_ de _indexers_ **5-15 MB**). El crecimiento del fichero `prowlarr.db` es muy lento — cada _query_ a un _indexer_ no añade fila permanente (los _Search History_ y _Stats_ se mantienen acotados internamente).

  ```bash
  df -h /mnt/hd2t
  ```

---

## Decisiones de diseño

### Por qué Prowlarr (y no Jackett)

El homelab necesita un agregador de _indexers_ que sirva de _backend_ a Sonarr/Radarr. Dos candidatos:

| Candidato     | Por qué se descarta / acepta                                                                                                                                                                                                                                                                                                                                |
|---------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **Jackett**   | Pionero en el espacio, soporta el catálogo más amplio de _indexers_ públicos vía sus definiciones C# (carto-base). Pero **no propaga** los _indexers_ a Sonarr/Radarr automáticamente: hay que copiar la URL Torznab/Newznab + el _API key_ a mano en cada _arr_, y mantenerla cuando un _indexer_ cambia de URL. Cada nuevo _arr_ multiplica la fricción.   |
| **Prowlarr** ✅ | Mantenido por el equipo _Servarr_ (mismos autores que Sonarr/Radarr/Lidarr/Readarr). _Sync_ automático bidireccional con los _arr_ vía API: añadir un _indexer_ en Prowlarr lo hace aparecer en todos los _arr_ configurados. Soporta el mismo catálogo (definiciones YAML/C# heredadas de Jackett) y suma _indexers_ Newznab para Usenet. Estadísticas centralizadas (`Indexer Stats`), _History_ unificado, _Apps_ tab que evita ir a cada _arr_ a configurar manualmente. |

Prowlarr es el sucesor natural cuando hay más de un _arr_ en el homelab (Sonarr **y** Radarr aquí, en el futuro posiblemente Lidarr/Readarr). El _footprint_ es similar (~150 MB RAM, .NET 6 _runtime_).

### Imagen y _tag_

- **`lscr.io/linuxserver/prowlarr:1.21.2`** — imagen LSIO (LinuxServer.io) sobre upstream Prowlarr `1.21.2.x`. _Tag_ "major.minor.patch" pinneado a la versión exacta. Multi-arch (`linux/arm64`).
- **Por qué LSIO**: convención del homelab para servicios que se benefician de `PUID`/`PGID` y `s6-overlay`, igual que el resto de la familia _\*arr_ y Transmission. La imagen "oficial" de Prowlarr en Docker Hub (`hotio/prowlarr`, `linuxserver/prowlarr`) son las únicas mantenidas activamente; LSIO encaja con todo el resto del homelab.
- **Por qué `1.21.2` y no `:latest` ni `:develop`**: la rama `develop` recibe _commits_ diarios y a veces _breaking changes_ en el formato del `prowlarr.db`. La rama `master` (`:latest`) es estable pero el _tag_ corto recibe re-builds del _wrapper_ LSIO varias veces por semana. Pinear al patch concreto convierte cada re-build en una decisión humana — Watchtower (cuando se active el _opt-in_) recoge re-builds del **mismo `1.21.2`** sin cambiar el _tag_; los _bumps_ de minor (`1.21.x → 1.22.x`) son cambios explícitos en el `.env`.
- **Por qué no la rama `1.0.x` antigua**: las versiones `1.0` no soportan _Apps_ con _Sync Profiles_ avanzados ni varios formatos modernos de Cloudflare. La rama `1.21.x` es la _stable_ vigente.

> **Cómo consultar el _tag_ vigente**: <https://github.com/linuxserver/docker-prowlarr/pkgs/container/prowlarr>. Los `release notes` de upstream Prowlarr se siguen en <https://github.com/Prowlarr/Prowlarr/releases>; los re-builds del _wrapper_ LSIO en <https://github.com/linuxserver/docker-prowlarr/releases>.

#### Watchtower **opt-in**

Razones:

- **Patches frecuentes sin _breaking changes_** dentro de la rama `1.21.x`: re-builds semanales con definiciones nuevas de _indexers_, _bug fixes_ del propio Prowlarr y _security updates_ de la base Alpine.
- **Estado estable dentro de la `1.21.x`**: el formato de `prowlarr.db` y `config.xml` está congelado dentro de la _minor_. Watchtower puede reciclar el contenedor con seguridad.
- **Tolerancia a reinicios**: Prowlarr es _stateless_ entre arranques excepto por el `prowlarr.db` y los _backups_ internos diarios. Sonarr/Radarr toleran reinicios puntuales del _backend_ (retry exponencial sobre el _Apps Sync_); un reinicio de un par de minutos en la madrugada (ventana Watchtower domingo 04:00 UTC) no afecta operación.
- **Migraciones de BD automáticas y reversibles**: el _entrypoint_ de Prowlarr ejecuta `Migrate` sobre `prowlarr.db` al arrancar; las migraciones internas dentro de la `1.21.x` son aditivas.

Etiquetar el contenedor con `com.centurylinklabs.watchtower.enable: "true"`.

> **Bumps de _minor_** (`1.21 → 1.22`, `1.x → 2.x`): se hacen **a mano**, fuera de Watchtower. Cambiar `PROWLARR_IMAGE_TAG=1.22.0` en `~/homelab/descargas/.env`, leer las _release notes_ de upstream y de LSIO, hacer backup del `prowlarr.db` previo (Borgmatic + dump SQLite), y aplicar `make pull STACK=descargas && make up STACK=descargas`. Watchtower con _tag_ `1.21.2` no salta a `1.22.0` automáticamente porque mira el _digest_ del _tag_ exacto pinneado.

### Modo de red: `bridge` (red `homelab`) sin `ports:` publicados

Decisión opinada y consistente con el resto del homelab. Las dos opciones razonables:

| Opción                                     | Ventajas                                                                                                                                                                                | Inconvenientes                                                                                                                                                                                                                  |
|--------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **`network_mode: host`**                   | Trivial: Prowlarr escucha en `192.168.1.3:9696`. Caddy puede _reverse-proxy_ a `127.0.0.1:9696`.                                                                                          | Rompe el patrón "Caddy delante de cada servicio". Expone la web UI al host: cualquier proceso local pinchea la API sin Caddy. Hay que abrir un agujero en `nftables` para `:9696` o aceptar el _bind_ a `0.0.0.0`.                |
| **`bridge` en red `homelab` sin `ports:`** ✅ | Coherente con todos los demás servicios del homelab: Prowlarr se alcanza por DNS interno (`prowlarr:9696`), no expone la web UI al host, Caddy es el _único_ camino al servicio para humanos y Sonarr/Radarr lo alcanzan por nombre. Aislamiento limpio. | Un cliente externo (un _arr_ de otro Docker host, una herramienta CLI desde la Pi misma) no puede llegar a Prowlarr salvo por Caddy (`https://prowlarr.lan/`). Para el homelab es lo correcto: no hay clientes "externos".         |

Se elige `bridge` con red externa `homelab`. Prowlarr no necesita ningún puerto publicado al host.

### `forward_auth` con Authelia: **NO** para Prowlarr

Tentación natural una vez Authelia está montada: añadir `import authelia` al bloque `prowlarr.lan` del `Caddyfile`. **No se hace**, por estas razones técnicas:

- **Sonarr/Radarr hablan con Prowlarr por DNS interno** (`prowlarr:9696`), saltándose Caddy. Ahí Authelia no influye en absoluto. Sería sólo una protección extra para la web UI humana.
- **Prowlarr ya tiene autenticación nativa _Forms_** desde la rama `1.x`: el operador la activa en _Settings → General → Security → Authentication: Forms (Login Page)_ con _Authentication Required: Enabled_. La _cookie_ de sesión protege la web UI, y todas las llamadas API requieren un _API key_ que Prowlarr genera y muestra en el mismo panel. Doble capa nativa, suficiente.
- **Endpoints API y `/api/v1/system/health` que pollean Sonarr/Radarr** desde fuera de Caddy (vía DNS interno) **no** ven Authelia. Si el operador en algún momento decidiese exponer el _API_ por Caddy (p. ej. para que un cliente externo en Tailscale lo consulte), Authelia rompería el flujo (las apps no siguen redirects a `auth.lan` ni rellenan formularios).
- **Si en el futuro se quisiera proteger adicionalmente la UI con Authelia** (no la API), se podría hacer un _path matcher_ en el bloque `prowlarr.lan` aplicando `forward_auth` sólo a los _paths_ humanos (`/`, `/login`, `/UI/*`) y dejando `/api/*` sin Authelia. **Fuera de alcance** de este documento; documentar como _opt-in_ avanzado si llega el caso.

Solución correcta para este homelab: **Prowlarr autentica con su sistema nativo** (Forms login, _API key_), Caddy actúa como _reverse proxy_ "tonto" que termina TLS y propaga las cabeceras, y la _Forms auth_ viaja cifrada por TLS gracias al propio Caddy.

> **Resumen operativo**: el bloque `prowlarr.lan` del `Caddyfile` lleva `import security-headers` y `import logging`, pero **no** `import authelia`. La sesión Forms (cookie `Prowlarr-`) protege la UI; el _API key_ protege `/api/*`.

### `URL Base` vacía + acceso por _vhost_ propio

Prowlarr soporta `URL Base = /prowlarr` para servir bajo un _path_ compartido (modelo "todos los \*arr bajo una sola URL"). Como cada servicio del homelab tiene su propio _vhost_ (`prowlarr.lan`, `sonarr.lan`, `radarr.lan`, …), **`URL Base` se mantiene vacía**:

- Más simple: ningún _rewrite_ de _path_ en Caddy, ningún ajuste de `app.baseUrl` en el cliente JS de Prowlarr.
- _Apps Sync_ con Sonarr/Radarr usa _Prowlarr Server_ = `http://prowlarr:9696/` (DNS interno), donde no hay _path_; consistente.
- El operador no tiene que recordar diferencias entre el acceso por LAN, Tailscale y DNS interno.

Si en algún momento se prefiriese rutar todo bajo `https://hub.lan/prowlarr`, `https://hub.lan/sonarr`, etc., se documentará en una posible refactor del `Caddyfile`. Por ahora: un _vhost_ por servicio.

### `Authentication Method: Forms` con `Authentication Required: Enabled` desde el primer arranque

Prowlarr `1.x` exige autenticación obligatoria desde la primera versión `1.0` (no se puede dejar la web UI abierta como sí permitía `0.x`). Las dos opciones que ofrece:

| Método                                  | Comportamiento                                                                                                                                                                                                       |
|-----------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **Basic (Browser Popup)**               | El navegador muestra un diálogo HTTP _Basic Auth_. Limpio para CLI/clientes _native_, pero los gestores de contraseñas no rellenan _basic auth_ y no hay logout limpio.                                              |
| **Forms (Login Page)** ✅                | Página de login HTML, _cookie_ de sesión, _Remember me_, logout explícito. Encaja con la familia _\*arr_ (Sonarr/Radarr usan el mismo patrón) y los gestores de contraseñas (Vaultwarden cuando llegue) lo soportan. |

`Authentication Required` tiene además dos sub-opciones:

| Sub-opción                                                | Comportamiento                                                                                                                            |
|-----------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------|
| **Enabled** ✅                                             | Toda petición exige sesión válida (UI) o _API key_ (API).                                                                                 |
| **Disabled for Local Addresses**                          | Las peticiones desde la LAN no piden auth. **Desactivado** aquí: Caddy hace _reverse proxy_ desde la red Docker `homelab` (`172.20.10.x`), y aunque eso es "local" desde el punto de vista de Prowlarr, no queremos diferenciar — la UX uniforme (siempre login) es mejor. |

Variables de entorno LSIO específicas que activan este comportamiento desde el primer arranque (en lugar de tener que entrar a la web UI a configurarlas):

```ini
PROWLARR__AUTH__METHOD=Forms
PROWLARR__AUTH__REQUIRED=Enabled
```

> Estas variables **sólo aplican en el primer arranque** (cuando `config.xml` no existe). En arranques posteriores, `config.xml` es la fuente de verdad. Para cambiarlas a posteriori, editar `config.xml` con el contenedor parado o usar la web UI.

### `prowlarr.db` (SQLite) — Patrón S de respaldo

Prowlarr usa una BD SQLite (`/config/prowlarr.db` + `/config/prowlarr.db-shm` + `/config/prowlarr.db-wal`) como almacén persistente de:

- _Indexers_ configurados con sus credenciales/cookies/API keys.
- _Apps_ conectadas (Sonarr, Radarr, …) con sus URLs y _API keys_.
- _Sync Profiles_ entre _indexers_ y _apps_.
- Histórico de búsquedas y descargas (acotado, retención interna).
- _Notifications_, _Tags_, _Settings_.

La imagen LSIO **incluye `sqlite3`** dentro del contenedor — `dump_sqlite` del Patrón S funciona directamente:

```bash
docker exec prowlarr sqlite3 -version
# 3.40.x ...
```

Por tanto, en `~/homelab/backups/borgmatic/hooks/dump-databases.sh`, la línea para Prowlarr (que ya existe **comentada** desde `docs/07-backups/03-backup-docker-volumes.md`) se descomenta tal cual:

```bash
# Antes:
# dump_sqlite prowlarr prowlarr /config/prowlarr.db

# Después:
dump_sqlite prowlarr prowlarr /config/prowlarr.db
```

Cada _run_ de Borgmatic produce un fichero `prowlarr-<fecha>.sqlite.gz` en `/mnt/hd2t/backups/dumps/` (Patrón S), que se respalda como cualquier otro fichero. Adicionalmente, el árbol entero `/mnt/hd2t/services/prowlarr/` entra en `source_directories:` de Borgmatic — esto cubre `config.xml`, `MediaCover/`, `logs/` y los _backups_ internos de Prowlarr en `Backups/`. Patrón **S** + redundancia de _filesystem_ por si el dump SQLite fallase un día (la rama de "fichero plano" sirve como respaldo de respaldo).

### `Backups/` interno de Prowlarr — se mantiene, no se respalda con prioridad

Prowlarr genera automáticamente _backups_ internos cada noche en `/config/Backups/scheduled/prowlarr_backup_*.zip` (con retención de 7 días por defecto). Son _zip_ que contienen `prowlarr.db` + `config.xml` + carpetas auxiliares.

- **No se desactivan** en este documento: son útiles para restauraciones rápidas desde la propia web UI (_System → Backup → Restore_) sin tener que tocar Borgmatic.
- **No se excluyen** de Borgmatic: ocupan poco (5-30 MB cada uno), se deduplican muy bien (dos _backups_ de noches consecutivas tienen la mayor parte del contenido binario en común).
- **Frecuencia**: ajustable en _Settings → General → Backups_ (`Backup Interval`, `Backup Retention`). Defaults razonables, no se tocan.

---

## Estructura del _stack_ `descargas` tras este documento

Aprovecha el _stack_ creado por Transmission (`docs/10-descargas/01-transmission.md`):

```
~/homelab/descargas/
├── docker-compose.yml        # ← extendido (añade servicio prowlarr)
├── .env                      # ← extendido (añade PROWLARR_IMAGE_TAG)
├── .env.example              # ← extendido (añade PROWLARR_IMAGE_TAG)
└── .gitignore                # (sin cambios)
```

Y en los discos externos, sobre lo que ya creó `docs/01-sistema/04-estructura-directorios.md`:

```
/mnt/hd2t/services/prowlarr/
└── (vacío al empezar; el primer arranque lo puebla con
    Backups/, MediaCover/, logs/, config.xml, prowlarr.db, …)
```

Verificar que el bind mount existe y tiene el ownership correcto antes de arrancar:

```bash
ls -la /mnt/hd2t/services/prowlarr
# total 8
# drwxr-xr-x 2 1000 1000 4096 ... .
# drwxr-xr-x ... services
```

Si por error está como `root:root`, restaurar:

```bash
sudo chown -R 1000:1000 /mnt/hd2t/services/prowlarr
sudo chmod 0755 /mnt/hd2t/services/prowlarr
```

> **No** crear subdirectorios a mano — Prowlarr crea `Backups/`, `MediaCover/`, `logs/`, `xdg/`, etc. con los permisos correctos en el primer arranque. Pre-crearlos sólo añade ruido.

---

## Variables de entorno

Editar `~/homelab/descargas/.env.example` (versionado en git) y añadir el bloque de Prowlarr **al final** (preservando lo que ya tenía Transmission):

```bash
# --- Imágenes pinneadas -----------------------------------------------------
# Patches automáticos vía Watchtower. Bumps de minor/major a mano leyendo
# https://github.com/Prowlarr/Prowlarr/releases y
# https://github.com/linuxserver/docker-prowlarr/releases.
PROWLARR_IMAGE_TAG=1.21.2
```

Replicar el cambio en `~/homelab/descargas/.env`:

```bash
$EDITOR ~/homelab/descargas/.env
# Añadir:
# PROWLARR_IMAGE_TAG=1.21.2
chmod 0600 ~/homelab/descargas/.env
```

> **Sin secretos en `.env`**: a diferencia de Transmission (`TRANSMISSION_USER`/`TRANSMISSION_PASS`), Prowlarr **no acepta** la contraseña de _Forms auth_ vía variables de entorno. La cuenta inicial se crea desde la web UI en el primer acceso (ver **Configuración tras primer arranque**). El _API key_ se autogenera por Prowlarr y se lee desde `/config/config.xml` cuando lo necesiten Sonarr/Radarr.

---

## `~/homelab/descargas/docker-compose.yml`

Editar el `docker-compose.yml` existente (creado por `docs/10-descargas/01-transmission.md`) y añadir el servicio `prowlarr`. La estructura final relevante queda:

```yaml
---
# Stack: descargas — Transmission + Prowlarr (Sonarr y Radarr en docs siguientes).
# Documentación: docs/10-descargas/01-transmission.md y 02-prowlarr.md

services:

  transmission:
    # ... (sin cambios; ver docs/10-descargas/01-transmission.md)

  # ---------------------------------------------------------------------------
  # Prowlarr — gestor unificado de indexadores.
  # En 'homelab' (Caddy y Sonarr/Radarr la alcanzan por nombre).
  # No publica puertos al host: la web UI y la API sólo se acceden via Caddy
  # (https://prowlarr.lan/) o por DNS interno desde otros servicios del stack.
  # ---------------------------------------------------------------------------
  prowlarr:
    image: lscr.io/linuxserver/prowlarr:${PROWLARR_IMAGE_TAG}
    container_name: prowlarr
    hostname: prowlarr
    restart: unless-stopped
    environment:
      PUID: ${PUID}
      PGID: ${PGID}
      TZ: ${TZ}
      # Activar Forms auth desde el primer arranque para evitar el "wizard"
      # interactivo de Prowlarr (que aparece sólo si AUTH no está configurado).
      # Tras el primer arranque, /config/config.xml manda — estas variables
      # ya no se vuelven a aplicar.
      PROWLARR__AUTH__METHOD: Forms
      PROWLARR__AUTH__REQUIRED: Enabled
      # Nombre de instancia visible en la barra superior y en logs.
      PROWLARR__APP__INSTANCENAME: Prowlarr
      # Sin URL base: cada servicio tiene su propio vhost en Caddy.
      PROWLARR__SERVER__URLBASE: ""
    volumes:
      - /mnt/hd2t/services/prowlarr:/config
      # Hora del host (timestamps de logs y de Search History).
      - /etc/localtime:/etc/localtime:ro
    # Sin 'ports:' — la web UI :9696 sólo se alcanza por DNS interno.
    networks:
      homelab:
        aliases:
          - prowlarr           # Caddy y Sonarr/Radarr resuelven 'prowlarr:9696'
    labels:
      homelab.stack: "descargas"
      homelab.backup: "true"   # /mnt/hd2t/services/prowlarr entra en Borgmatic (Cat. S+F)
      # Opt-in: patches dentro de 1.21.x son seguros (sin breaking changes en
      # prowlarr.db ni en config.xml).
      com.centurylinklabs.watchtower.enable: "true"
    healthcheck:
      # /ping responde 200 sin auth — endpoint público diseñado para healthchecks.
      # No usamos /api/v1/system/status (requiere API key) ni / (requiere sesión
      # Forms): /ping es el endpoint canónico de Prowlarr para liveness.
      test:
        - CMD-SHELL
        - "wget -qO- --tries=1 --timeout=5 http://localhost:9696/ping 2>&1 | grep -q -i 'pong\\|OK' || exit 1"
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 60s

# ---------------------------------------------------------------------------
# Redes (sin cambios respecto a docs/10-descargas/01-transmission.md)
# ---------------------------------------------------------------------------
networks:
  homelab:
    external: true               # creada en docs/02-docker/02-estructura-compose.md
```

Notas de diseño:

- **`PUID/PGID` vía `environment:`**: la imagen LSIO espera estos en el _entrypoint_ (no es la convención `user:` que usa Jellyfin). Equivalente funcionalmente.
- **`PROWLARR__AUTH__METHOD` y `PROWLARR__AUTH__REQUIRED`**: la imagen LSIO traduce variables `PROWLARR__SECCION__CLAVE=valor` a entradas en `config.xml` en el primer arranque (vía `s6-overlay`). Son las mismas que aparecen en _Settings → General → Security_ de la web UI. Sólo se aplican si `config.xml` aún **no** existe; en arranques posteriores `config.xml` es la fuente de verdad.
- **`PROWLARR__SERVER__URLBASE: ""`**: explícito para evitar que un wizard previo o un copy-paste de otro homelab haya dejado un valor distinto. Vacío = servicio en raíz.
- **Sin `user:` explícito**: LSIO maneja el UID/GID con su propio _entrypoint_ s6-overlay; usar `user:` en paralelo confunde al `s6-overlay` y rompe el `chown` automático del nivel superior.
- **Sin `ports:`**: Prowlarr es accesible sólo via Caddy (`prowlarr.lan`) y via DNS interno (`prowlarr:9696` desde Sonarr/Radarr). No hay clientes _native_ que necesiten acceso directo al host.
- **`/etc/localtime:/etc/localtime:ro`**: además de `TZ`, montar `/etc/localtime` cubre los _timestamps_ que Prowlarr imprime en `Search History` y en los logs.
- **`start_period: 60s`**: el primer arranque de Prowlarr es más lento que el de Transmission (~30-45 s) — el _entrypoint_ ejecuta `Migrate` sobre `prowlarr.db` (vacío al principio, así que es rápido, pero el _runtime_ .NET necesita su tiempo). `start_period: 60s` deja margen suficiente sin bloqueos espurios del _healthcheck_ durante el _bootstrap_.
- **Healthcheck sobre `/ping`**: Prowlarr expone `GET /ping` sin autenticación — endpoint canónico para _liveness probes_. Devuelve `200 OK` con cuerpo `{"status":"OK"}` (o `pong`/`OK` según la versión). El _healthcheck_ marca _unhealthy_ si el _daemon_ no responde HTTP.
- **Watchtower opt-in**: razones explicadas en **Decisiones de diseño** → _Imagen y tag_.
- **No `mem_limit` ni `cpus`**: Prowlarr consume poco (~150-200 MB RAM idle, <2 % CPU idle, picos breves de ~30 % CPU durante búsquedas masivas a _indexers_). La política por defecto (sin límite) está bien.

---

## Despliegue

### Primer arranque

```bash
cd ~/homelab/descargas
docker compose --env-file ../.env --env-file .env config | head -60   # validar sintaxis
docker compose --env-file ../.env --env-file .env up -d prowlarr
```

O, equivalente, con el _Makefile_ (ver `docs/02-docker/02-estructura-compose.md`):

```bash
cd ~/homelab
make up STACK=descargas
```

Vigilar el primer arranque (tarda ~30-45 s):

```bash
docker compose -f ~/homelab/descargas/docker-compose.yml logs -f prowlarr
# ...
# prowlarr | [migrations] started
# prowlarr | [migrations] no migrations found
# prowlarr | [custom-init] No custom files found, skipping...
# prowlarr | [ls.io-init] done.
# prowlarr | [Info] Microsoft.Hosting.Lifetime: Now listening on: http://[::]:9696
# prowlarr | [Info] Microsoft.Hosting.Lifetime: Application started.
# prowlarr | [s6-init] ready.
```

Verificar que el contenedor está `(healthy)`:

```bash
docker compose -f ~/homelab/descargas/docker-compose.yml ps prowlarr
# NAME       STATUS                   PORTS
# prowlarr   Up X seconds (healthy)
```

> El `(healthy)` lo otorga el _healthcheck_ que confirma que `/ping` responde HTTP `200`. Si tras 90-120 s sigue `starting`, ir a **Troubleshooting** → primer arranque.

Comprobar que `config.xml` se ha generado con los valores esperados:

```bash
sudo cat /mnt/hd2t/services/prowlarr/config.xml
# <Config>
#   <BindAddress>*</BindAddress>
#   <Port>9696</Port>
#   <SslPort>9898</SslPort>
#   <EnableSsl>False</EnableSsl>
#   <LogLevel>info</LogLevel>
#   <AnalyticsEnabled>True</AnalyticsEnabled>
#   <UrlBase></UrlBase>
#   <InstanceName>Prowlarr</InstanceName>
#   <ApiKey>abc123def456...</ApiKey>           ← autogenerado, anótalo
#   <AuthenticationMethod>Forms</AuthenticationMethod>
#   <AuthenticationRequired>Enabled</AuthenticationRequired>
#   <Branch>master</Branch>
#   <LaunchBrowser>False</LaunchBrowser>
# </Config>
```

> **Apuntar el `<ApiKey>`**: lo necesitará Sonarr/Radarr en sus fases para configurar el _Apps Sync_ contra Prowlarr. También se puede consultar después en _Settings → General → Security → API Key_ desde la web UI.

### Caddy: bloque `prowlarr.lan`

Editar `~/homelab/red/Caddyfile` y añadir el bloque (situarlo junto al de `transmission.lan` para mantener la sección de `descargas` agrupada):

```caddy
prowlarr.lan {
    tls internal
    import security-headers
    import logging

    reverse_proxy prowlarr:9696 {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
    }
}
```

> **No** se necesita `redir / /...` (a diferencia de Transmission): Prowlarr ya sirve la UI en la raíz. **No** se añade `import authelia` (ver **Decisiones de diseño**).

Validar y recargar Caddy:

```bash
docker exec caddy caddy validate --config /etc/caddy/Caddyfile
docker exec caddy caddy reload --config /etc/caddy/Caddyfile
```

Probar (la CA local debe estar importada en el navegador, ver `docs/03-red/04-caddy.md`):

```bash
# /ping: sin auth, debe responder 200
curl -k --resolve prowlarr.lan:443:192.168.1.3 \
     -I https://prowlarr.lan/ping
# HTTP/2 200

# /: redirige al login si no hay sesión (302 hacia /login)
curl -k --resolve prowlarr.lan:443:192.168.1.3 \
     -I https://prowlarr.lan/
# HTTP/2 302
# location: /login

# /api/v1/system/status sin API key: 401
curl -k --resolve prowlarr.lan:443:192.168.1.3 \
     -I https://prowlarr.lan/api/v1/system/status
# HTTP/2 401
```

Y desde el navegador: `https://prowlarr.lan/` → redirección a `/login` → formulario _Forms_ → primera vez se crea la cuenta administrador (ver siguiente sección).

---

## Configuración tras primer arranque

### 1. Crear la cuenta administrador

En el primer acceso a `https://prowlarr.lan/`, Prowlarr muestra el formulario de _Forms_ pidiendo **crear** el usuario administrador (no es un login contra una cuenta existente — es un _setup_ inicial):

- **Username**: el operador elige (no tiene que coincidir con el del sistema).
- **Password**: contraseña fuerte. Apuntar en el gestor del operador (cuando llegue Vaultwarden, mover allí).

Tras crear la cuenta, Prowlarr redirige al _dashboard_ vacío. Confirmar que el icono "_Settings → General → Security_" muestra:

- _Authentication: Forms (Login Page)_
- _Authentication Required: Enabled_
- _API Key_: el mismo valor que aparece en `config.xml`.

### 2. Verificar el `<ApiKey>` y guardarlo

```bash
sudo grep -oP '<ApiKey>\K[^<]+' /mnt/hd2t/services/prowlarr/config.xml
# abc123def456...
```

Apuntar este valor en el gestor del operador con la etiqueta `prowlarr-api-key`. Lo necesitarán Sonarr y Radarr en sus respectivas fases (_Apps → Add Application → Prowlarr → API Key_) — **aunque la conexión vaya por DNS interno** (`http://prowlarr:9696/`), Prowlarr exige el _API key_.

### 3. Añadir _indexers_ (responsabilidad del operador)

_Indexers → Add Indexer_:

- **Públicos** (sin cuenta): seleccionar de la lista (1337x, RARBG-style, The Pirate Bay-style trackers, etc.). Los detalles dependen del estado actual de cada _tracker_; algunos vienen y van.
- **Privados** (cuenta requerida): _site URL_ + credenciales (cookie/API key/_passkey_). Las credenciales se guardan **encriptadas** en `prowlarr.db`.
- **Newznab/Torznab genéricos**: para _indexers_ con definición personalizada.

Para cada _indexer_ añadido:
1. _Test_ debe pasar (Prowlarr hace una búsqueda de prueba).
2. Asignarlo a una _Tag_ (`tv`, `movies`, `general`, …) para que el _Sync Profile_ lo distribuya selectivamente a Sonarr/Radarr.
3. Activarlo (_Enable_).

> **Recomendación operativa**: añadir 1-2 _indexers_ públicos al inicio para validar el flujo. Los _indexers_ privados se incorporan a medida que el operador obtiene cuentas; cada uno suele tener su propio _onboarding_ (ratio mínimo, antigüedad, etc.).

> **Cloudflare y FlareSolverr**: si un _indexer_ devuelve `403 Forbidden` con _challenge_ Cloudflare, Prowlarr necesita un _solver_ externo. **No se despliega** en este documento — si llega el caso, añadir un servicio `flaresolverr` al `docker-compose.yml` del _stack_ `descargas` (`ghcr.io/flaresolverr/flaresolverr:v3.x.x`, sin _ports_, en la red `homelab`) y configurar Prowlarr en _Settings → Indexers → FlareSolverr URL: `http://flaresolverr:8191/`_. Documentar entonces como _Anexo_ a este doc.

### 4. Configurar `Backup Retention` (opcional)

`Settings → General → Backups`:

- **Backup Folder**: `/config/Backups` (default, **no tocar**).
- **Backup Interval**: `7` días (default).
- **Backup Retention**: `28` días (subido respecto al default `7` para tener un mes de _backups_ internos rotables; ocupa poco y son muy útiles para restauraciones rápidas).

### 5. _Apps Sync_ con Sonarr/Radarr — pendiente para fases siguientes

Las pestañas _Apps_ y _Sync Profiles_ se rellenarán cuando lleguen `docs/10-descargas/03-sonarr.md` y `docs/10-descargas/04-radarr.md`. En este documento se deja Prowlarr listo pero sin _apps_ conectadas.

> Foreshadow operativo: en Sonarr (cuando llegue), _Settings → Indexers → Add → Prowlarr_ no es la dirección correcta; la integración real es **inversa**: en **Prowlarr**, _Settings → Apps → Add Application → Sonarr_, con `Prowlarr Server: http://prowlarr:9696/`, `Sonarr Server: http://sonarr:8989/`, `API Key (Sonarr)`, `Sync Level: Full Sync`. Cuando se haga _Test_ y _Save_, Prowlarr crea automáticamente las entradas de _indexer_ en Sonarr. El operador no toca _Settings → Indexers_ en Sonarr.

---

## Almacenamiento

Tras el primer arranque, el árbol `/mnt/hd2t/services/prowlarr/` queda con los siguientes ficheros relevantes:

```
/mnt/hd2t/services/prowlarr/
├── config.xml                      # <ApiKey>, <AuthenticationMethod>, etc.
├── prowlarr.db                     # SQLite — indexers, apps, sync profiles, history
├── prowlarr.db-shm                 # SQLite shared memory (transitorio)
├── prowlarr.db-wal                 # SQLite WAL (transitorio)
├── Backups/
│   ├── manual/
│   └── scheduled/
│       └── prowlarr_backup_v1.21.2.4649_2026.04.26_03.00.00.zip
├── MediaCover/                     # favicons y thumbnails de indexers
│   └── 1/
├── logs/
│   ├── prowlarr.txt                # log activo
│   └── archive/
│       └── prowlarr.X.txt.gz       # logs rotados
├── xdg/                            # caché de .NET runtime (efímero)
│   └── ...
└── update_logs/
    └── ...
```

| Ruta                                                | Permisos          | Contenido                                                  |
|-----------------------------------------------------|-------------------|------------------------------------------------------------|
| `/mnt/hd2t/services/prowlarr/`                      | `1000:1000 0755`  | Raíz del bind mount                                        |
| `/mnt/hd2t/services/prowlarr/config.xml`            | `1000:1000 0644`  | Configuración (incluye el `<ApiKey>` en claro)             |
| `/mnt/hd2t/services/prowlarr/prowlarr.db`           | `1000:1000 0644`  | BD SQLite (incluye credenciales de _indexers_ encriptadas) |
| `/mnt/hd2t/services/prowlarr/Backups/scheduled/`    | `1000:1000 0755`  | _Backups_ internos diarios                                 |
| `/mnt/hd2t/services/prowlarr/MediaCover/`           | `1000:1000 0755`  | _Favicons_ y _thumbnails_ de _indexers_                    |
| `/mnt/hd2t/services/prowlarr/logs/`                 | `1000:1000 0755`  | Logs (rotación interna por Prowlarr)                       |

> **Sobre `config.xml` con permisos `0644`**: contiene el `<ApiKey>` en claro. La imagen LSIO crea el fichero con `0644` por defecto (lectura para el grupo). Endurecer a `0640` o `0600` está bien y no rompe nada (Prowlarr corre como `1000:1000` y siempre puede leerlo):
>
> ```bash
> sudo chmod 0640 /mnt/hd2t/services/prowlarr/config.xml
> ```
>
> No es estrictamente necesario — el _bind mount_ lo posee `1000:1000` y otros usuarios del sistema no deberían poder llegar (los discos externos están bajo `/mnt/hd2t` con `0755` para `1000:1000`). Pero es defensa en profundidad.

> **Sobre `prowlarr.db`**: Prowlarr **encripta** las credenciales sensibles de _indexers_ y _apps_ usando una clave derivada de `<ApiKey>` + un _salt_ guardado en la propia BD. Si se filtra `prowlarr.db` **sin** `config.xml`, las credenciales no son trivialmente extraíbles; con ambos, sí. Por eso el _bind mount_ entero es Categoría A en términos de sensibilidad (ver `docs/07-backups/01-estrategia-backup.md`).

---

## Backup

Patrón **S** (SQLite vía `dump_sqlite`) + Patrón **F** (filesystem-only para `config.xml`, `MediaCover/`, `Backups/`).

### 1. Confirmar que `source_directories:` ya cubre Prowlarr

El `config.yaml` de Borgmatic (`docs/07-backups/02-borgmatic.md`) ya incluye `/mnt/hd2t/services/prowlarr` en `source_directories:` (ver `docs/07-backups/01-estrategia-backup.md` → **Inventario consolidado de fuentes**, línea `- /mnt/hd2t/services/prowlarr`). **No hay que añadir nada**.

### 2. Excluir el WAL de SQLite (opcional pero recomendado)

Los ficheros `prowlarr.db-shm` y `prowlarr.db-wal` son transitorios — el dump SQLite del Patrón S los _checkpoint_ea en `prowlarr.db` antes de leer. Respaldarlos en bruto puede dar un `db-wal` inconsistente con el `prowlarr.db` del archive (no fatal, pero ruidoso). Excluirlos:

```bash
$EDITOR ~/homelab/backups/borgmatic/config.yaml
```

```yaml
exclude_patterns:
  # ... entradas existentes ...

  # Prowlarr — SQLite WAL/SHM transitorios; el dump del Patrón S los integra
  # en prowlarr.db antes de leer. La copia "viva" del .db sí entra como
  # filesystem-only (defensa en profundidad), pero el WAL no aporta nada.
  - /mnt/hd2t/services/prowlarr/prowlarr.db-wal
  - /mnt/hd2t/services/prowlarr/prowlarr.db-shm

  # xdg/ es caché del runtime .NET; regenerable.
  - /mnt/hd2t/services/prowlarr/xdg
```

> El propio `prowlarr.db` **se mantiene** en los _source_directories_ (no se excluye): es la "copia viva" que entra como Categoría F, complementaria al dump del Patrón S. Si el dump fallase un día, todavía tendríamos el `.db` plano (puede ser un poco inconsistente respecto al WAL del momento, pero recuperable con `sqlite3 prowlarr.db ".recover"` en el peor caso).

### 3. Descomentar el bloque del hook `dump-databases.sh`

Este es el cambio principal del documento sobre el sistema de backups. Editar el script:

```bash
$EDITOR ~/homelab/backups/borgmatic/hooks/dump-databases.sh
```

Localizar el bloque **comentado** que dice:

```bash
# --- *arr family (Sonarr/Radarr/Prowlarr — SQLite) — docs/10-descargas/0[3-2].md
# dump_sqlite sonarr   sonarr   /config/sonarr.db
# dump_sqlite radarr   radarr   /config/radarr.db
# dump_sqlite prowlarr prowlarr /config/prowlarr.db
```

Y descomentar **únicamente** la línea de Prowlarr (las de Sonarr y Radarr quedan comentadas hasta que sus respectivos docs lleguen):

```bash
# --- *arr family (Sonarr/Radarr/Prowlarr — SQLite) — docs/10-descargas/0[3-2].md
# dump_sqlite sonarr   sonarr   /config/sonarr.db
# dump_sqlite radarr   radarr   /config/radarr.db
dump_sqlite prowlarr prowlarr /config/prowlarr.db
```

> **Por qué sólo Prowlarr**: cuando llegue `docs/10-descargas/03-sonarr.md` y `04-radarr.md`, esos documentos descomentarán **sus** líneas correspondientes. La política del homelab (`docs/07-backups/03-backup-docker-volumes.md`, sección _"cuando un servicio se despliega, su doc termina con un commit que descomenta el bloque correspondiente"_) lo deja claro.

Reinstalar el script con el cambio:

```bash
~/homelab/backups/borgmatic/install.sh
```

### 4. Verificar el dump manualmente

Antes de confiar en el _run_ programado, validar el flujo manualmente:

```bash
sudo /etc/borgmatic.d/hooks/dump-databases.sh
# [dump] prowlarr: OK -> /mnt/hd2t/backups/dumps/prowlarr-2026-04-26.sqlite.gz
ls -la /mnt/hd2t/backups/dumps/prowlarr-*.sqlite.gz | tail -3
```

Validar que el dump es íntegro:

```bash
gunzip -c /mnt/hd2t/backups/dumps/prowlarr-2026-04-26.sqlite.gz | file -
# /dev/stdin: SQLite 3.x database, ...
```

Y que se puede leer:

```bash
gunzip -c /mnt/hd2t/backups/dumps/prowlarr-2026-04-26.sqlite.gz \
  > /tmp/prowlarr-restore-test.db
sqlite3 /tmp/prowlarr-restore-test.db '.tables' | head -10
# Apps                  Indexers              Tags
# Backup                NamingConfig          Users
# Blocklist             Notifications         VersionInfo
# Commands              Restrictions          ...
rm /tmp/prowlarr-restore-test.db
```

### 5. Confirmar que el archive incluye Prowlarr tras el siguiente run

Tras el siguiente _run_ programado (madrugada), Prowlarr aparece en la lista de archives:

```bash
sudo bash -c '
  set -a; . /etc/borgmatic.d/secrets.env; set +a
  borg list --short "$BORG_REPO_LOCAL" | tail -1
'
# pi-2026-04-27T03:30:30

sudo bash -c '
  set -a; . /etc/borgmatic.d/secrets.env; set +a
  borg list "$BORG_REPO_LOCAL::pi-2026-04-27T03:30:30" \
    | grep -E "prowlarr" | head -10
'
# -rw-r--r-- 1000 1000 1.2K Apr 27 02:00 mnt/hd2t/services/prowlarr/config.xml
# -rw-r--r-- 1000 1000  18M Apr 27 02:00 mnt/hd2t/services/prowlarr/prowlarr.db
# drwxr-xr-x 1000 1000    - Apr 27 02:00 mnt/hd2t/services/prowlarr/Backups
# ...
# -rw-r--r-- root  root   2.1M Apr 27 03:30 mnt/hd2t/backups/dumps/prowlarr-2026-04-27.sqlite.gz
# ...
```

Confirmar que **NO** aparece `prowlarr.db-wal` ni `prowlarr.db-shm` (excluidos):

```bash
sudo bash -c '
  set -a; . /etc/borgmatic.d/secrets.env; set +a
  borg list "$BORG_REPO_LOCAL::pi-2026-04-27T03:30:30" \
    | grep -E "prowlarr.db-(wal|shm)|prowlarr/xdg"
'
# (vacío)
```

### Restauración

Procedimiento del **Patrón S — SQLite** documentado en `docs/07-backups/03-backup-docker-volumes.md` → _Restauración: una base de datos (Patrón S — SQLite)_. En resumen:

1. `docker compose -f ~/homelab/descargas/docker-compose.yml stop prowlarr`.
2. Mover `/mnt/hd2t/services/prowlarr/prowlarr.db{,-shm,-wal}` a `prowlarr.db.broken-<ts>` (no borrar — preservar 24-48 h).
3. Restaurar el dump más reciente:

   ```bash
   sudo gunzip -c /mnt/hd2t/backups/dumps/prowlarr-<fecha>.sqlite.gz \
     > /mnt/hd2t/services/prowlarr/prowlarr.db
   sudo chown 1000:1000 /mnt/hd2t/services/prowlarr/prowlarr.db
   sudo chmod 0644 /mnt/hd2t/services/prowlarr/prowlarr.db
   ```

4. **Caso especial — `config.xml` también corrupto o perdido**: extraer del archive Borg el `config.xml` correspondiente:

   ```bash
   sudo bash -c '
     set -a; . /etc/borgmatic.d/secrets.env; set +a
     borg extract --strip-components 4 \
       "$BORG_REPO_LOCAL::pi-<fecha>" \
       mnt/hd2t/services/prowlarr/config.xml
   '
   sudo mv config.xml /mnt/hd2t/services/prowlarr/config.xml
   sudo chown 1000:1000 /mnt/hd2t/services/prowlarr/config.xml
   ```

   > **Importante**: `config.xml` y `prowlarr.db` deben venir del **mismo archive** (mismo `<ApiKey>`). El `<ApiKey>` se usa para derivar la clave de encriptación de credenciales en `prowlarr.db`; mezclar archives distintos invalida las credenciales encriptadas.

5. `docker compose -f ~/homelab/descargas/docker-compose.yml up -d prowlarr`.
6. Esperar al `(healthy)`. Prowlarr re-leerá `config.xml` y `prowlarr.db`; en la web UI, los _indexers_ y _apps_ deben aparecer tal y como estaban.
7. **Sonarr/Radarr** (cuando lleguen): si el `<ApiKey>` cambió por la restauración (no debería, viene del archive), reconfigurar las _Apps_ con el nuevo valor. Si vienen del mismo archive, sigue siendo el mismo `<ApiKey>` y no hay que tocar nada.

> **Restauración alternativa desde el _backup_ interno de Prowlarr**: si el operador prefiere usar el _zip_ que Prowlarr genera en `Backups/scheduled/`, puede importarlo desde la web UI (_System → Backup → Choose File → Restore_). Es más cómodo para restauraciones rápidas pero **sólo cubre los últimos 7-28 días** (según `Backup Retention`); para algo más antiguo, ir al archive Borg.

---

## Verificación

Antes de dar por cerrado este documento:

- [ ] `~/homelab/descargas/docker-compose.yml` y `~/homelab/descargas/.env.example` versionados en git con la sección de `prowlarr` añadida; `~/homelab/descargas/.env` **no** versionado y con `PROWLARR_IMAGE_TAG` rellenado.
- [ ] `docker compose -f ~/homelab/descargas/docker-compose.yml ps prowlarr` muestra `prowlarr` como `(healthy)`.
- [ ] `docker exec prowlarr wget -qO- http://localhost:9696/ping` devuelve un cuerpo con `OK`/`pong` (HTTP 200).
- [ ] `docker exec prowlarr id` muestra `uid=1000 gid=1000`.
- [ ] `sudo grep -oP '<ApiKey>\K[^<]+' /mnt/hd2t/services/prowlarr/config.xml` devuelve un valor de 32 caracteres alfanuméricos.
- [ ] `sudo grep -oP '<AuthenticationMethod>\K[^<]+' /mnt/hd2t/services/prowlarr/config.xml` devuelve `Forms`.
- [ ] `sudo grep -oP '<AuthenticationRequired>\K[^<]+' /mnt/hd2t/services/prowlarr/config.xml` devuelve `Enabled`.
- [ ] `docker exec caddy caddy validate --config /etc/caddy/Caddyfile` acepta el bloque `prowlarr.lan` añadido.
- [ ] `curl -k --resolve prowlarr.lan:443:192.168.1.3 -I https://prowlarr.lan/ping` devuelve `HTTP/2 200`.
- [ ] `curl -k --resolve prowlarr.lan:443:192.168.1.3 -I https://prowlarr.lan/` devuelve `HTTP/2 302` con `location: /login`.
- [ ] `curl -k --resolve prowlarr.lan:443:192.168.1.3 -I https://prowlarr.lan/api/v1/system/status` devuelve `HTTP/2 401`.
- [ ] `curl -k --resolve prowlarr.lan:443:192.168.1.3 -H "X-Api-Key: <APIKEY>" https://prowlarr.lan/api/v1/system/status | jq .version` devuelve un string tipo `"1.21.2.4649"`.
- [ ] Login interactivo desde el navegador con la cuenta administrador funciona; tras login se ve el _dashboard_ vacío.
- [ ] `ss -tulpn '( sport = :9696 )'` en el host **NO** muestra ningún proceso bindeando ese puerto (Prowlarr no publica al host).
- [ ] `docker port prowlarr` no lista ningún _mapping_.
- [ ] El bloque `prowlarr.lan` del `Caddyfile` lleva `import security-headers` y `import logging`; **no** lleva `import authelia`.
- [ ] La lista `two_factor` del `access_control.rules` de Authelia **no** menciona `prowlarr.lan` (ni siquiera comentado).
- [ ] Watchtower vigila el contenedor: `docker logs watchtower --tail 50 | grep prowlarr` muestra al menos un check (label `enable: "true"` activo).
- [ ] `stat -c '%U:%G' /mnt/hd2t/services/prowlarr /mnt/hd2t/services/prowlarr/{config.xml,prowlarr.db,Backups,logs}` devuelve `1000:1000` en todos.
- [ ] `~/homelab/backups/borgmatic/hooks/dump-databases.sh` tiene la línea `dump_sqlite prowlarr prowlarr /config/prowlarr.db` **descomentada**; las de `sonarr` y `radarr` siguen comentadas.
- [ ] `sudo /etc/borgmatic.d/hooks/dump-databases.sh && ls /mnt/hd2t/backups/dumps/prowlarr-*.sqlite.gz` muestra al menos un dump del día.
- [ ] `gunzip -c /mnt/hd2t/backups/dumps/prowlarr-*.sqlite.gz | file -` reporta `SQLite 3.x database`.
- [ ] El siguiente run de Borgmatic incluye `mnt/hd2t/services/prowlarr/` y **excluye** `prowlarr.db-wal`, `prowlarr.db-shm` y `xdg/`.
- [ ] _Settings → General → Security_ en la web UI muestra `Authentication: Forms`, `Authentication Required: Enabled`, y el _API key_ coincide con el del `config.xml`.
- [ ] Añadir un _indexer_ público de prueba (uno que no requiera cuenta), hacer _Test_ y verificar que pasa. Después borrarlo si se quiere mantener Prowlarr "limpio" hasta que llegue Sonarr/Radarr.

---

## Troubleshooting

### Primer arranque: el contenedor se queda en `starting` indefinidamente

```bash
docker logs prowlarr --tail 50
```

Causas comunes:

- **Permisos del bind mount**: si por error se hizo un `chown -R root:root /mnt/hd2t/services/prowlarr`, el _entrypoint_ de LSIO falla al hacer `chown` del nivel superior. Restaurar:

  ```bash
  sudo chown -R 1000:1000 /mnt/hd2t/services/prowlarr
  docker compose -f ~/homelab/descargas/docker-compose.yml restart prowlarr
  ```

- **Migración de BD que falla**: log con `Microsoft.Data.Sqlite.SqliteException: SQLite Error 5: 'database is locked'` o similar. Suele ser por un `prowlarr.db-wal` huérfano de un arranque previo no limpio. Solución:

  ```bash
  docker compose -f ~/homelab/descargas/docker-compose.yml stop prowlarr
  sudo rm /mnt/hd2t/services/prowlarr/prowlarr.db-wal \
          /mnt/hd2t/services/prowlarr/prowlarr.db-shm
  docker compose -f ~/homelab/descargas/docker-compose.yml start prowlarr
  # Prowlarr regenera el WAL al arrancar.
  ```

- **`PROWLARR__AUTH__*` ignoradas porque `config.xml` ya existía**: si el bind mount tenía un `config.xml` previo de un experimento anterior, las variables de entorno **no** se aplican. Para reset completo:

  ```bash
  docker compose -f ~/homelab/descargas/docker-compose.yml stop prowlarr
  sudo mv /mnt/hd2t/services/prowlarr/config.xml /mnt/hd2t/services/prowlarr/config.xml.bak
  docker compose -f ~/homelab/descargas/docker-compose.yml start prowlarr
  # Se regenera config.xml con los defaults + variables de entorno.
  ```

  > **Atención**: esto **invalida** las credenciales encriptadas en `prowlarr.db` (cambia el `<ApiKey>`). Sólo hacer en _bootstrap_ inicial sin _indexers_ aún configurados, o tras restaurar también `prowlarr.db` desde un archive del **mismo** `config.xml`.

### `502 Bad Gateway` desde Caddy

```bash
docker logs caddy --tail 20
# {"level":"error", ..., "msg":"dial tcp: lookup prowlarr on 127.0.0.11:53: no such host"}
```

Causa: Caddy y Prowlarr no están en la misma red. Verificar:

```bash
docker inspect caddy --format '{{range $net, $cfg := .NetworkSettings.Networks}}{{$net}} {{end}}'
docker inspect prowlarr --format '{{range $net, $cfg := .NetworkSettings.Networks}}{{$net}} {{end}}'
# Ambos deben listar 'homelab'.
```

Si Prowlarr no está en `homelab`, revisar el `docker-compose.yml`: la sección `networks: homelab:` del servicio debe estar bien indentada y la red declarada como `external: true` al final del compose.

### Login en `https://prowlarr.lan/login` devuelve `Username or password is incorrect` con la contraseña correcta

- **Cookie bloqueada**: algunos navegadores bloquean cookies de _hosts_ con TLDs no estándar (`.lan`). Comprobar la consola del navegador (`F12 → Network → login`) y la respuesta del POST. Si vuelve `200` con cuerpo de error pero las _cookies_ no se setearon, el navegador está bloqueando. Solución: añadir `prowlarr.lan` a la lista de _hosts confiables_ del navegador o usar Chrome/Firefox con configuración por defecto.
- **`config.xml` con `<AuthenticationMethod>None</AuthenticationMethod>`**: el operador (o un experimento) deshabilitó la auth. Reactivar:

  ```bash
  docker compose -f ~/homelab/descargas/docker-compose.yml stop prowlarr
  sudo sed -i 's|<AuthenticationMethod>None</AuthenticationMethod>|<AuthenticationMethod>Forms</AuthenticationMethod>|' \
      /mnt/hd2t/services/prowlarr/config.xml
  sudo sed -i 's|<AuthenticationRequired>DisabledForLocalAddresses</AuthenticationRequired>|<AuthenticationRequired>Enabled</AuthenticationRequired>|' \
      /mnt/hd2t/services/prowlarr/config.xml
  docker compose -f ~/homelab/descargas/docker-compose.yml start prowlarr
  ```

### `Test` de un _indexer_ devuelve `Cloudflare protection encountered`

El _indexer_ está protegido por Cloudflare con _challenge_ JS. Prowlarr no lo resuelve por sí solo. Opciones:

1. **Esperar** y reintentar — a veces Cloudflare relaja el _challenge_ al cabo de unos minutos.
2. **Añadir cookies _CF clearance_** manualmente: navegar al _indexer_ desde el navegador del operador, resolver el _challenge_, copiar las _cookies_ `cf_clearance` y `cf_bm` desde DevTools, pegarlas en _Settings → Indexer → <indexer> → Cookie_. Caducan a las 24-72 h, hay que renovar.
3. **Desplegar FlareSolverr** como side-car (fuera de alcance de este doc — ver **Configuración** → _Cloudflare y FlareSolverr_).

### El `<ApiKey>` cambia inesperadamente entre arranques

No debería pasar. Causas conocidas:

- `config.xml` se borró y se regeneró (el _entrypoint_ LSIO regenera un `<ApiKey>` distinto cada vez). Solución: restaurar `config.xml` desde Borg.
- Una restauración mal coordinada (`config.xml` de un día, `prowlarr.db` de otro). Resultado: las credenciales encriptadas de `prowlarr.db` no se pueden desencriptar con el nuevo `<ApiKey>`. Solución: restaurar **ambos** ficheros del **mismo** archive.

Cuando el `<ApiKey>` cambia, Sonarr/Radarr (cuando lleguen) reportarán `401 Unauthorized` en _System → Health_. Actualizar el _API key_ en _Sonarr/Radarr → Settings → Apps → Prowlarr_.

### Prowlarr reporta `Unable to load apps: ECONNREFUSED sonarr:8989`

Esperado mientras Sonarr no está desplegado. Esa _health warning_ aparecerá automáticamente cuando se haya configurado un _App_ contra Sonarr/Radarr antes de que esos contenedores estén corriendo. Se silencia añadiendo el _App_ en orden inverso: primero desplegar Sonarr/Radarr (`docs/10-descargas/03-sonarr.md`, `04-radarr.md`), después configurar el _App_ en Prowlarr.

### `Activity → History` está vacío después de horas de uso

`Settings → Profiles → Sync Profile`: el perfil controla qué se registra. Si _History Retention_ es `0` o muy bajo, el _History_ se purga inmediatamente. Defaults razonables: `30` días.

### Logs en `/config/logs/prowlarr.txt` crecen sin parar

Prowlarr rota internamente cuando `prowlarr.txt` supera `1 MB` (default), pero si el _LogLevel_ está en `Debug` o `Trace`, el ritmo es altísimo. Volver a `Info`:

`Settings → General → Logging → Log Level: Info` (o ajustar `<LogLevel>info</LogLevel>` en `config.xml` con el contenedor parado).

---

## Actualización

### Patches de la línea `1.21.x` (vía Watchtower, automático)

Watchtower opt-in está activo. Cada domingo a las 04:00 UTC, Watchtower comprueba el _digest_ del _tag_ `1.21.2`; si LSIO publica un re-build (mismo _tag_, distinto _digest_), Watchtower hace `pull` + `recreate` del contenedor. Sin acción del operador.

Verificar tras un domingo:

```bash
docker logs watchtower --tail 50 | grep prowlarr
# time=... msg="Found new lscr.io/linuxserver/prowlarr:1.21.2 image"
# time=... msg="Stopping /prowlarr"
# time=... msg="Creating /prowlarr"
```

Si tras la recreación el `(healthy)` no llega en 120 s, ir a **Troubleshooting**.

### Bumps de patch (`1.21.2 → 1.21.3`, manual)

```bash
# 1. Leer las release notes
xdg-open https://github.com/Prowlarr/Prowlarr/releases/tag/v1.21.3.4700
xdg-open https://github.com/linuxserver/docker-prowlarr/releases

# 2. Backup completo previo
sudo /usr/bin/borgmatic --verbosity 1
# Verificar que el último archive tiene fecha de hoy y que el dump
# /mnt/hd2t/backups/dumps/prowlarr-<fecha>.sqlite.gz se ha generado.

# 3. Cambiar el tag y aplicar
$EDITOR ~/homelab/descargas/.env
# PROWLARR_IMAGE_TAG=1.21.3
cd ~/homelab
make pull STACK=descargas
make up STACK=descargas

# 4. Vigilar el log durante el reinicio
docker compose -f ~/homelab/descargas/docker-compose.yml logs -f prowlarr
# Buscar:
#   prowlarr | [Info] Microsoft.Hosting.Lifetime: Application started.
# Si el log muestra ERROR o el contenedor entra en restart loop, ir a Troubleshooting.

# 5. Validar la web UI, los indexers existentes, y System → Status muestra la
#    nueva versión.
```

### Bumps de _minor_ (`1.21 → 1.22`)

- Suelen incluir migraciones de `prowlarr.db` (claves nuevas, índices). _Hacer SIEMPRE backup completo del bind mount antes_:

  ```bash
  sudo systemctl stop docker
  sudo tar czf /mnt/hd2t/backups/prowlarr-pre-bump-$(date +%F).tar.gz \
      -C /mnt/hd2t/services prowlarr
  sudo systemctl start docker
  ```

- Planificar la actualización en una ventana de mantenimiento.
- Considerar saltar a `1.22.1` o similar (la versión `.0` a menudo tiene bugs que se arreglan en el primer _patch_).
- Tras el _upgrade_, comprobar que los _indexers_ y _Apps_ siguen activos en la web UI; si Sonarr/Radarr ya están desplegados, comprobar el _Sync_ desde Prowlarr → Sonarr/Radarr.

### Bumps de _major_ (`1.x → 2.x`)

- Cambios estructurales relevantes; Prowlarr aún no ha tenido un `2.x` en el momento de escribir este doc, pero cuando ocurra:
- Leer la guía de migración del proyecto.
- Verificar compatibilidad con Sonarr/Radarr/Lidarr/Readarr (puede requerir actualizar el cliente _arr_ a una versión que entienda la nueva API _Apps_).
- Backup previo (Borgmatic + tar.gz manual del bind mount).
- Plan de _rollback_ (`PROWLARR_IMAGE_TAG=1.21.2` y `make up STACK=descargas` para volver atrás, restaurando el bind mount del tar.gz si las migraciones de BD eran irreversibles).

---

## Referencias

- Documentación oficial — Prowlarr Wiki: <https://wiki.servarr.com/prowlarr>
- API v1 — referencia: <https://prowlarr.com/docs/api/>
- Imagen Docker — LinuxServer.io `prowlarr`: <https://github.com/linuxserver/docker-prowlarr>
- LSIO `prowlarr` — Docker Hub: <https://hub.docker.com/r/linuxserver/prowlarr>
- Releases de Prowlarr (upstream): <https://github.com/Prowlarr/Prowlarr/releases>
- Variables de entorno LSIO `PROWLARR__*`: <https://github.com/linuxserver/docker-prowlarr#parameters>
- Reverse proxy con Caddy — _Servarr_ general: <https://wiki.servarr.com/prowlarr/installation#reverse-proxy>
- FlareSolverr (opcional, para _indexers_ con _challenge_ Cloudflare): <https://github.com/FlareSolverr/FlareSolverr>
- Documentos relacionados del homelab:
  - `docs/01-sistema/04-estructura-directorios.md` — `/mnt/hd2t/services/prowlarr` con ownership `1000:1000`.
  - `docs/02-docker/02-estructura-compose.md` — convenciones de stacks, red `homelab`, regla `:ro`/`:rw`.
  - `docs/02-docker/04-watchtower.md` — opt-in para `1.21.x`, ventana dominical.
  - `docs/03-red/02-pihole.md` — DNS local `*.lan` (cubre `prowlarr.lan` por wildcard).
  - `docs/03-red/04-caddy.md` — Caddy, CA local, _snippets_ `security-headers` y `logging`.
  - `docs/03-red/05-tailscale.md` — acceso remoto vía VPN sin abrir puertos en el router.
  - `docs/04-seguridad/01-authelia.md` — por qué Prowlarr **no** entra en `forward_auth`.
  - `docs/07-backups/01-estrategia-backup.md` — Categoría A (credenciales de _indexers_) + Patrón S (SQLite).
  - `docs/07-backups/02-borgmatic.md` — `source_directories`, `exclude_patterns`.
  - `docs/07-backups/03-backup-docker-volumes.md` — Patrón S y línea `dump_sqlite prowlarr prowlarr /config/prowlarr.db` (descomentada por este doc).
  - `docs/10-descargas/01-transmission.md` — _stack_ `descargas`, convenciones del compose.
  - `docs/10-descargas/03-sonarr.md` — _consumer_ de Prowlarr vía _Apps Sync_ (fase siguiente).
  - `docs/10-descargas/04-radarr.md` — _consumer_ de Prowlarr vía _Apps Sync_ (fase siguiente).
