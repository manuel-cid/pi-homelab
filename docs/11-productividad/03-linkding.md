# Linkding (gestor de marcadores ligero, autohospedado)

## Descripción

Despliegue de **Linkding** como **gestor de marcadores web** del operador y de la familia: bóveda local de bookmarks con etiquetas, búsqueda full-text sobre títulos y descripciones, _snapshots_ del contenido de cada URL (vía _Internet Archive_ o _Singlefile_ local, opcional), API REST para extensiones de navegador y CLIs, y **una única instancia para todos los dispositivos** (escritorio, portátil, móvil) — sustituyendo el zoo de "favoritos del navegador X" + "Pocket" + "Raindrop.io" con un único punto de verdad bajo control del operador. Se convierte, junto con Bookstack, en uno de los dos servicios donde **vive la memoria operativa** del homelab: páginas de docs upstream que el operador consulta a menudo (LinuxServer.io, Docker Hub, Caddy docs), tutoriales útiles, _gists_ con _snippets_ que vienen bien tener a mano.

Este documento **continúa el _stack_ `productividad`** (`~/homelab/productividad/`) que estrenó `docs/11-productividad/01-vaultwarden.md` y amplió `docs/11-productividad/02-bookstack.md`. A diferencia de Bookstack, Linkding **no necesita BD aparte** (vive sobre SQLite local, igual que Vaultwarden) y **no requiere ampliar la red `productividad-internal`**: con un único contenedor en la red `homelab` basta. Aquí se materializa un único servicio:

- **`linkding`** — aplicación Django + Gunicorn (imagen oficial-comunitaria `sissbruecker/linkding`). Una sola pieza: el binario sirve la web UI, la API REST y los _snapshots_ por el mismo puerto. Persistencia en SQLite local (`/etc/linkding/data/db.sqlite3`), sin BD aparte.

Caddy (stack `red`, `docs/03-red/04-caddy.md`) expone Linkding en `https://linkding.lan/` con TLS interno (CA local). Para acceso remoto vía Tailscale (`docs/03-red/05-tailscale.md`), `https://pi.<tailnet>.ts.net/` con MagicDNS sirve la misma bóveda al móvil cuando se está fuera de la LAN.

> **Alcance**: este documento despliega Linkding con su autenticación nativa (username + password, opcionalmente 2FA TOTP via la app `django-mfa2` integrada), crea **el usuario operador** vía las variables `LD_SUPERUSER_*` del primer arranque, **deshabilita el registro abierto** (Linkding lo trae **off por defecto**, sólo se confirma desde Django admin), genera el **token de API** del operador para que la **extensión de navegador** y los _clients_ móviles funcionen, **descomenta el bloque del _hook_ de Borgmatic** que dejó preparado `docs/07-backups/03-backup-docker-volumes.md` con `dump_sqlite linkding linkding /etc/linkding/data/db.sqlite3`. **No** delega autenticación a Authelia vía `forward_auth` (mismo razonamiento que Vaultwarden y Bookstack — la API REST con _bearer tokens_ para la extensión rompe con un redirect HTML; ver **Decisiones de diseño**). **No** activa _snapshots_ por _Singlefile_ local (se documenta como **opcional** al final; arquitectónicamente es _sidecar_-compatible pero añade un Chromium headless en la Pi que la mayoría de operadores no necesitan). **No** activa OIDC contra Authelia (queda como **opcional** al final, mismo patrón que Bookstack). **No** configura SMTP en este documento.

> **Recordatorio de red**: Linkding **no se publica al host**. Caddy la alcanza por DNS interno de Docker (`linkding:9090` en la red `homelab`). No hay BD que aislar (SQLite vive dentro del propio contenedor sobre un _bind mount_), por lo que **no** hace falta ampliar `productividad-internal` (se queda con sólo `bookstack` y `bookstack-db` dentro). Pi-hole resuelve `linkding.lan → 192.168.1.3` por el _wildcard_ de `02-homelab-local.conf` (ver `docs/03-red/02-pihole.md`).

---

## Requisitos previos

- `docs/02-docker/02-estructura-compose.md` completado: la tabla de stacks reserva el _slot_ `productividad`, la red Docker `homelab` (`br-homelab`, `172.20.10.0/24`) externa está creada, `~/homelab/.env` global con `TZ=Europe/Madrid`, `PUID=1000`, `PGID=1000`, `HOMELAB_DOMAIN=lan` está rellenado, y el _Makefile_ de operación expone `make up STACK=<stack>`.
- `docs/01-sistema/04-estructura-directorios.md` completado: `/mnt/hd2t/services/linkding/` ya existe vacío. En este documento se crea además `/mnt/hd2t/services/linkding/data/`.
- `docs/02-docker/04-watchtower.md` completado: la convención `com.centurylinklabs.watchtower.enable` está documentada. Linkding aparece en la lista de **opt-in** desde el principio (ver **Decisiones de diseño**).
- `docs/03-red/02-pihole.md` completado: Pi-hole resuelve `*.lan → 192.168.1.3`. **No hay que añadir nada** para `linkding.lan` — el _wildcard_ ya lo cubre.
- `docs/03-red/04-caddy.md` completado: Caddy escucha en `192.168.1.3:443` con `tls internal`, los _snippets_ `security-headers.caddy` y `logging.caddy` existen, y la directiva `import /etc/caddy/snippets/*.caddy` está activa en el `Caddyfile`. La CA local ya firma `*.lan`.
- `docs/07-backups/03-backup-docker-volumes.md` completado: el helper `dump_sqlite` está cargado en `~/homelab/backups/borgmatic/hooks/dump-databases.sh` y el bloque comentado `# dump_sqlite linkding linkding /etc/linkding/data/db.sqlite3` está listo para descomentar.
- `docs/11-productividad/01-vaultwarden.md` completado: el _stack_ `productividad` ya existe con `~/homelab/productividad/{docker-compose.yml,.env,.env.example,.gitignore}` y al menos Vaultwarden corriendo. **Este documento amplía** esos ficheros — no los crea desde cero. Tener Vaultwarden vivo también significa que el operador **ya tiene una bóveda** donde guardar el _superuser password_ inicial y el _API token_ que se generan abajo.
- `docs/11-productividad/02-bookstack.md` **no** es requisito previo estricto: el _stack_ `productividad` ya creó la red `productividad-internal` por Bookstack, pero Linkding **no se engancha** a esa red (ver **Decisiones de diseño**). Si Bookstack aún no se ha desplegado, tampoco pasa nada — `productividad-internal` se crea con sólo `bookstack`+`bookstack-db` cuando aterrice ese servicio.
- Conectividad saliente para descargar la imagen (sólo la primera vez):
  ```bash
  docker pull --platform linux/arm64 sissbruecker/linkding:1.36.0 >/dev/null && echo OK
  ```
- Que el host **no** tenga ya un servicio escuchando en `:9090` por error (`docker ps --format '{{.Names}} {{.Ports}}' | grep ':9090->' || echo OK`). Este _stack_ no publica puertos al host; Caddy es quien recibe el tráfico HTTPS.
- Espacio en `/mnt/hd2t`: Linkding es **muy ligero**. La aplicación idle ocupa ~150 MB de RAM, la BD SQLite recién creada <1 MB, y los _snapshots_ (si se activan) raramente superan unos cientos de MB en uso normal. Verificar holgura mínima:
  ```bash
  df -h /mnt/hd2t
  # Debe quedar holgado. Linkding ocupará <100 MB iniciales en /mnt/hd2t.
  ```

---

## Decisiones de diseño

### Por qué Linkding (y no Shaarli / Wallabag / LinkAce / Pinboard cloud / Raindrop self-hosted)

El homelab necesita **un gestor de marcadores** que cumpla a la vez: UI web rápida, etiquetas jerárquicas, búsqueda full-text, **API REST** para que las extensiones de navegador funcionen sin reinventarlas, _self-hosting_ ARM64 maduro, y un footprint pequeño (es la décima aplicación del homelab; ya hay suficientes piezas pesadas con Nextcloud, Jellyfin y Home Assistant). Cuatro candidatos descartados y por qué:

| Candidato      | Por qué se descarta                                                                                                                                                   |
|----------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **Shaarli**    | PHP clásico, ligero, sin BD (ficheros de texto). UI muy minimalista — adecuada como diario de _links_ tipo blog, **inadecuada** como gestor con etiquetas anidadas y búsqueda. Sin API REST estable; las extensiones de navegador para Shaarli son _bookmarklets_ JavaScript. |
| **Wallabag**   | Excelente como _read-it-later_ (guarda el contenido completo del artículo, lo limpia, lo presenta como _ePub_/PDF). Pero es un _read-it-later_, no un gestor de marcadores: la unidad mental es "artículo guardado para leer", no "URL etiquetada". Stack más pesado (Symfony + MariaDB/Postgres). El operador ya descartó "leer offline" como caso de uso prioritario. |
| **LinkAce**    | Stack Laravel + MariaDB. Funcionalmente muy completo (alertas de URLs caídas, _imports_ de varios formatos), pero **dos veces más pesado** que Linkding por traer toda la pila Laravel + BD relacional para un caso de uso que SQLite cubre sobrado. Si Bookstack ya añade una MariaDB al _stack_ `productividad`, replicarla por Linkding sería redundante. |
| **Pinboard**   | Servicio cloud histórico, no _self-hosted_. Suscripción anual, datos fuera del homelab, dependencia de un único mantenedor. Modelo opuesto al objetivo del homelab.    |
| **Raindrop.io** | Existe versión _self-hosted_ "Raindrop.io for Teams" pero es de pago y propietaria; las _self-hosted_ comunitarias compatibles son experimentales. UI espectacular pero el _vendor lock-in_ y la incertidumbre de licenciamiento la dejan fuera. |

Linkding gana por:

- **Stack mínimo** — Django + SQLite + Gunicorn. Un único contenedor de ~80 MB, BD que cabe en un disquete los primeros años de uso. No hay sidecar de BD, ni Redis, ni cola de jobs externa.
- **API REST documentada y estable** (`/api/bookmarks/`) con autenticación por _token_ de usuario (`Authorization: Token <token>`). La extensión oficial de navegador, los _clients_ Android (Linkdroid, _bookmarks share targets_) y los CLIs (`ldcli`, scripts curl) funcionan sobre esta API. Imprescindible para que la wiki de marcadores **se use de verdad**: si añadir un marcador requiere abrir la web, copiar la URL y pegarla, el operador vuelve a los favoritos del navegador en una semana.
- **Etiquetas jerárquicas** vía notación `parent/child` en el campo de _tags_ — sintaxis ligera, no requiere árbol explícito en BD.
- **Búsqueda full-text** sobre título, descripción, notas, etiquetas y URL. Implementada con SQLite FTS5 (índice nativo); rapidísima hasta decenas de miles de marcadores.
- **Snapshots opcionales** — pide al _Internet Archive_ que indexe cada URL nueva, o (vía sidecar) ejecuta `singlefile` localmente para guardar una copia HTML completa. _Defensa_ ante que la URL desaparezca. Off por defecto en este documento; activación documentada al final.
- **Soporte ARM64 oficial-comunitario** vía `sissbruecker/linkding`, multi-arch, mantenido por el upstream (no hay imagen LinuxServer.io ni hace falta).
- **Migración fuera trivial** — exporta a HTML estándar (`Netscape Bookmarks File Format`) que cualquier navegador o gestor importa. **Sin lock-in**.

### Imagen y _tag_

- **`sissbruecker/linkding:1.36.0`** — Linkding 1.36.x empaquetada por el upstream (Sascha Ißbrücker), multi-arch (`linux/arm64`). Pinneada a _tag_ "major.minor.patch" semver siguiendo la convención del homelab (ver `docs/02-docker/02-estructura-compose.md`, sección **Imágenes**: nada de `:latest`). Linkding publica versiones cada pocas semanas; los _bumps_ de **patch** (1.36.0 → 1.36.1) son seguros y los gestiona Watchtower (ver más abajo). Los _bumps_ de **minor** (1.36.x → 1.37.0) traen funcionalidades nuevas y a veces migraciones de schema; se gestionan a mano leyendo el _changelog_.
- **No se usa el _tag_ `:latest`** — al ser Linkding una aplicación con BD propia, un `pull` de `:latest` que cruzase un _bump major_ podría ejecutar migraciones irreversibles. El _tag_ pinneado da la libertad de elegir cuándo migrar.

#### Watchtower opt-in en este contenedor

A diferencia de Vaultwarden y Bookstack (ambos _opt-out_ por criticidad de la BD y migraciones), **Linkding entra como _opt-in_** explícito:

- El proyecto sigue **semver estricto**: los _bumps_ de **patch** son retrocompatibles y nunca incluyen migraciones de _schema_ rompedoras. Watchtower puede aplicarlos sin riesgo. _docs/02-docker/04-watchtower.md_ → tabla de servicios _opt-in_ ya lista a Linkding.
- La superficie de criticidad es baja: si Linkding cae 30 segundos durante un `restart` post-pull de Watchtower, el operador no pierde nada (los marcadores siguen accesibles desde el cache del navegador hasta que vuelva).
- El SQLite es ligero. `migrate` corre en <2 s en una Pi 5; un fallo de migración que dejara la BD a medias se detectaría en el _healthcheck_ inmediatamente y Watchtower no aplicaría más actualizaciones.

Etiquetar con `com.centurylinklabs.watchtower.enable: "true"` y, si más tarde el operador quiere pinear a un _tag_ minor concreto (`1.36.x`), Watchtower **respeta el _tag_** del compose: no cruza de `:1.36.0` a `:1.37.0` solo porque exista un `:latest` distinto. Lo único que hace es _re-pull_ del mismo _tag_ por si hubo un _rebuild_ con un _digest_ nuevo. En la práctica, para _bumps minor_ (1.36 → 1.37) habrá que editar `LINKDING_IMAGE_TAG` a mano.

> **Coherencia con `docs/02-docker/04-watchtower.md`**: ese documento ya lista a "Linkding" en la lista explícita de servicios **opt-in** desde el principio. No hace falta justificar nada extra aquí; sólo aplicar la etiqueta.

### SQLite en lugar de PostgreSQL/MariaDB

Linkding soporta los tres backends (SQLite default, PostgreSQL vía `LD_DB_ENGINE=postgres`, MariaDB sin soporte oficial). La elección **forzada por el caso de uso** del homelab es **SQLite**:

- **Volumen de datos**: un operador típico acumula entre 1.000 y 10.000 marcadores en su vida. SQLite con FTS5 maneja eso con una latencia de búsqueda de <50 ms. Para llegar a justificar Postgres habría que estar en el orden de cientos de miles de marcadores con concurrencia de escritura — escenario absurdo en un homelab personal.
- **Cero overhead operativo**: sin sidecar, sin _hostname_ adicional en `productividad-internal`, sin `MYSQL_ROOT_PASSWORD` que custodiar, sin `mariadb-dump` en el _hook_ de Borgmatic (basta con `dump_sqlite`, el patrón S de `docs/07-backups/03-backup-docker-volumes.md`).
- **Backup más simple**: una llamada a `sqlite3 .backup` produce un fichero binario consistente sin parar el contenedor. Un dump SQL de Postgres requiere un _client_ instalado en el contenedor (o un sidecar `pg_dump`). El SQLite gana en tres líneas de _hook_ frente a quince.
- **Restauración más simple**: copiar el fichero `.sqlite3` a su sitio y arrancar el contenedor. Sin _hostname_ de BD, sin _user_/`password`, sin `CREATE DATABASE` previo.

> **Si en el futuro Linkding pasase a "muchos usuarios escribiendo en paralelo"** (improbable), la migración a Postgres está documentada upstream y consiste en `dump_sqlite` + `loaddata` desde el contenedor. Operación de un par de horas, no irreversible.

### `forward_auth` con Authelia: **NO** para Linkding

Misma decisión que en Bookstack y Vaultwarden. Razones específicas para Linkding:

- **API REST con _Token bearer_**: Linkding expone `/api/*` con autenticación por _token_ (`Authorization: Token <token>`). No sigue redirects HTML. Si Caddy intercepta una petición a `/api/bookmarks/` con un `302` hacia `https://auth.lan/?rd=...`, la **extensión de navegador**, los _clients_ Android (Linkdroid, intent _share_ desde Firefox móvil) y los scripts curl reciben HTML en lugar del JSON esperado y fallan con errores opacos. El operador vería "la extensión no funciona" sin pista de que el problema es Authelia.
- **Compartir un marcador desde el móvil**: el _intent_ "Share to Linkding" en Android Firefox dispara una llamada POST a `/bookmarks/new` con cookies; un redirect a Authelia rompería el flujo, y volver a desbloquear Authelia desde el _share sheet_ del móvil es un sufrimiento UX inaceptable.
- **OIDC nativo**: Linkding soporta **OIDC desde 1.30** vía `LD_ENABLE_OIDC=True`. Igual que en Bookstack, el camino correcto para unificar el _login_ con Authelia es **dentro** de Linkding, **no** poniendo Authelia delante con `forward_auth`. La sección **Migrar a OIDC con Authelia (opcional)** del final de este documento describe ese camino.

> **Resumen operativo**: el bloque `linkding.lan` del `Caddyfile` lleva `import security-headers` y `import logging`, pero **no** `import authelia`. Caddy actúa como _reverse proxy_ "tonto"; Linkding autentica con su sistema nativo (username + password + opcional MFA TOTP) y, cuando se decida, con OIDC contra Authelia desde dentro de la propia app.

### `LD_HOST_NAME` + `LD_HOST_PROTOCOL` byte a byte

Linkding genera URLs absolutas en _password reset_ (si SMTP está activo), en los _share links_ y en los _OAuth redirect URIs_ a partir de las dos variables `LD_HOST_NAME` y `LD_HOST_PROTOCOL`. Si no se le dicen, las construye con el _hostname_ que Gunicorn ve en la request — y como Caddy reescribe `Host` a `linkding.lan` por defecto, lo natural es que coincidan… pero **lo natural no es lo seguro**, y además `LD_HOST_NAME` se usa también para la **lista de orígenes CSRF** (`CSRF_TRUSTED_ORIGINS` interno de Django).

Política:

```bash
LD_HOST_NAME=linkding.lan
LD_HOST_PROTOCOL=https
LD_CSRF_TRUSTED_ORIGINS=https://linkding.lan,https://pi.tailnet.ts.net
```

…fijado en el `.env`. Coincide byte a byte con el dominio del bloque del `Caddyfile`. La inclusión de la URL de Tailscale en `LD_CSRF_TRUSTED_ORIGINS` permite que la wiki funcione **también** cuando se accede vía MagicDNS desde fuera de la LAN (ver `docs/03-red/05-tailscale.md`); sin ella, los formularios POST devuelven `403 CSRF verification failed` al hacerlos vía Tailscale.

> Si el operador no ha configurado Tailscale aún (es un paso opcional al final de la fase 3), poner sólo `LD_CSRF_TRUSTED_ORIGINS=https://linkding.lan`. Cuando Tailscale aterrice, ampliar la lista y `up -d linkding`.

### Bootstrap del superuser por env vars (no por `manage.py`)

Linkding ofrece dos caminos para crear el primer usuario:

1. `docker exec linkding python manage.py createsuperuser` (Django clásico): pregunta interactivamente username, email, password.
2. Variables `LD_SUPERUSER_NAME` y `LD_SUPERUSER_PASSWORD` en el `.env`: el _entrypoint_ las lee en cada arranque y, si **no existe ya** un usuario con ese nombre, lo crea con esas credenciales. Si existe, no toca nada (no resetea la password).

Política aplicada: **opción 2**. Razones:

- **Reproducibilidad**: el bootstrap está en `~/homelab/productividad/.env`, custodiado igual que el resto de secrets. Una restauración en una Pi nueva crea automáticamente el operador en el primer arranque.
- **Cero interactividad**: no hay que ejecutar comandos manuales después de `make up`. El despliegue queda en `up -d` + verificar.
- **Seguridad**: tras el primer login, **se cambia la password** desde la UI a una nueva (anotada en Vaultwarden). La password del `.env` deja de ser válida (Linkding no la sobrescribe en futuros arranques porque "el usuario ya existe"). El `.env` se queda con la password vieja como fósil; no es un secreto activo.

> **Atención**: si se borra el usuario desde la UI por error, el siguiente arranque del contenedor lo **recreará** con la password del `.env`. Esto es deseable como "ruta de recuperación" si el operador queda fuera. Si el operador no quiere ese comportamiento (porque considera la password del `.env` quemada), debe **vaciar `LD_SUPERUSER_PASSWORD`** tras el primer arranque.

### Almacenamiento

| Ruta en el host                                      | Contenido                                                              | Versionable | Backup |
|------------------------------------------------------|------------------------------------------------------------------------|-------------|--------|
| `~/homelab/productividad/docker-compose.yml`          | Definición del _stack_ (modificada — añade `linkding`)                 | git         | git    |
| `~/homelab/productividad/.env`                        | Imágenes pinneadas + `LD_SUPERUSER_*` + `LD_CSRF_TRUSTED_ORIGINS`      | **NO** (`.gitignore`) | nota local (custodia separada) |
| `~/homelab/productividad/.env.example`                | Plantilla con nombres de variables, sin valores                        | git         | git    |
| `/mnt/hd2t/services/linkding/data/`                   | SQLite (`db.sqlite3`, `db.sqlite3-wal`, `db.sqlite3-shm`) + uploads de favicons + assets generados | **NO** | **Sí** (Borgmatic, vía `dump_sqlite`) |

> **Una sola jerarquía bajo `/mnt/hd2t/services/linkding/`**: a diferencia de Bookstack (que separa `config/` y `db/` por tener dos contenedores), Linkding es un único contenedor con un único bind mount. La imagen monta `/etc/linkding/data` como punto de persistencia y dentro va todo: la BD SQLite, los favicons cacheados, los assets compilados de Django.

> **Permisos de `/mnt/hd2t/services/linkding/data/`**: la imagen `sissbruecker/linkding` corre como `www-data:www-data` (UID/GID `33:33` en Debian). El _entrypoint_ hace `chown` recursivo de `/etc/linkding/data` en el primer arranque. Como el directorio padre (`/mnt/hd2t/services/linkding/`) se creó con `root:root 0755` en `docs/01-sistema/04-estructura-directorios.md`, **no hay nada que pre-chown-ear**.

> **Sin `PUID`/`PGID`**: la imagen oficial de Linkding **no soporta** las variables LinuxServer-style `PUID`/`PGID`. Corre fija como `www-data` (UID 33). Si en algún momento se quiere cambiar, hay que reconstruir la imagen — fuera de alcance.

---

## Estructura del _stack_ `productividad` tras este documento

Antes de este documento (tras `docs/11-productividad/02-bookstack.md`):

```
~/homelab/productividad/
├── docker-compose.yml        # contiene vaultwarden + bookstack + bookstack-db
├── .env                      # APP vars de Vaultwarden + Bookstack
├── .env.example
└── .gitignore
```

Tras este documento:

```
~/homelab/productividad/
├── docker-compose.yml        # ← MODIFICADO: añade linkding (en red 'homelab', sin productividad-internal)
├── .env                      # ← MODIFICADO: añade LD_*
├── .env.example              # ← MODIFICADO: añade plantilla LD_*
└── .gitignore                # sin cambios
```

Y en el disco externo, sobre lo que ya creó `docs/01-sistema/04-estructura-directorios.md`:

```
/mnt/hd2t/services/linkding/
└── data/                     # ← se crea al primer arranque del contenedor linkding
```

Ningún cambio en `~/homelab/productividad/.gitignore` (ya excluye `.env`). Ningún subdirectorio _stub_ que crear a mano: la imagen hace _populate_ del bind mount en el primer arranque.

> **Confirmar el árbol** antes de seguir:
> ```bash
> ls -la /mnt/hd2t/services/linkding/
> # drwxr-xr-x 2 root root 4096 ... .   <- vacío
> # drwxr-xr-x ...               ..
> ```
> Si ya hay un subdirectorio `data/` aquí (de un intento previo), **borrarlo** antes del primer arranque limpio:
> ```bash
> sudo rm -rf /mnt/hd2t/services/linkding/data
> ```

---

## Variables de entorno

### Ampliar `~/homelab/productividad/.env.example`

Abrir el fichero existente (ampliado en `docs/11-productividad/02-bookstack.md`) y **añadir al final** un nuevo bloque (no tocar las líneas de Vaultwarden ni Bookstack):

```bash
# ============================================================================
# Linkding — gestor de marcadores (docs/11-productividad/03-linkding.md)
# ============================================================================

# --- Imagen pinneada --------------------------------------------------------
LINKDING_IMAGE_TAG=1.36.0

# --- Linkding — endpoint y dominio -----------------------------------------
# Hostname público canónico. CRÍTICO: Linkding lo usa para construir URLs
# absolutas (snapshots, password reset si SMTP, OAuth redirects) y para la
# lista de orígenes confiables de CSRF interna de Django.
LD_HOST_NAME=linkding.lan
LD_HOST_PROTOCOL=https

# Lista de orígenes confiables para POST/CSRF. Coma-separada. Coincide con
# el bloque del Caddyfile + la URL de Tailscale (si aplica). Sin ella, el
# login devolvería 403 CSRF verification failed cuando se accede por
# Tailscale (host distinto de linkding.lan).
LD_CSRF_TRUSTED_ORIGINS=https://linkding.lan

# --- Linkding — bootstrap del superuser ------------------------------------
# Variables leídas SÓLO en el primer arranque (cuando no hay usuarios en la
# BD). Crean el usuario operador automáticamente. Tras el primer login, el
# operador cambia la password desde 'Settings → Password' y deja estas
# variables como fósiles inertes (Linkding no las re-aplica si el usuario
# ya existe).
#
# Generación del LD_SUPERUSER_PASSWORD recomendada (al rellenar el .env real):
#   openssl rand -base64 32 | tr -d '/+=' | head -c 24
# Custodia: nota "Homelab — Linkding bootstrap" en Vaultwarden.
LD_SUPERUSER_NAME=operador
LD_SUPERUSER_PASSWORD=

# --- Linkding — registro abierto -------------------------------------------
# Por defecto Linkding NO permite registro abierto. Esta variable es 'False'
# explícitamente para que el operador, al añadir más usuarios (familia), lo
# haga desde el panel admin de Django (/admin/), no por self-service.
LD_ENABLE_PUBLIC_SHARES=False

# --- Linkding — features -----------------------------------------------------
# Permite que un usuario marque cualquier marcador como 'compartido' y que
# se puedan navegar de forma anónima en /shared/<usuario>. Off para una
# wiki personal — cambiarlo a True si la familia comparte marcadores.
LD_ENABLE_SHARING=False

# Validación de URLs al añadir un marcador (HEAD HTTP a la URL). Útil para
# detectar typos. Costoso si se importan miles de marcadores de golpe.
LD_DISABLE_URL_VALIDATION=False

# --- Linkding — proxy reverso (Caddy) --------------------------------------
# Linkding (Django) confía en X-Forwarded-Proto si esta var está a True.
# Sin esto, el flag 'secure' de las cookies queda mal y los redirects van
# a http://.
LD_REQUEST_TIMEOUT=60

# Loguea la cabecera X-Forwarded-For de Caddy en los access logs internos
# (útil para fail2ban, aunque en este homelab no hay jail Linkding).
LD_LOG_X_FORWARDED_FOR=True

# --- Linkding — snapshots (off por defecto) --------------------------------
# Si se activa, cada URL nueva pide al Internet Archive que la indexe.
# Off por defecto: ahorra tráfico saliente y respeta a IA. Activación
# manual desde Settings → Bookmarks → 'Enable web archive integration'.
LD_ENABLE_SNAPSHOTS=False

# --- Linkding — locale ------------------------------------------------------
LD_TIMEZONE=Europe/Madrid

# --- SMTP (opcional, ver sección 'SMTP opcional' al final) -----------------
# Vacío = funcionalidad de email deshabilitada. Linkding sin SMTP funciona
# perfectamente; sólo se pierde la auto-recuperación de password (queda
# disponible la ruta admin de Django).
# LD_EMAIL_HOST=
# LD_EMAIL_PORT=587
# LD_EMAIL_HOST_USER=
# LD_EMAIL_HOST_PASSWORD=
# LD_EMAIL_USE_TLS=True
# LD_EMAIL_FROM=linkding@homelab.example

# --- OIDC (opcional, ver sección 'Migrar a OIDC con Authelia' al final) ----
# LD_ENABLE_OIDC=False
# LD_OIDC_ISSUER_URL=
# LD_OIDC_CLIENT_ID=
# LD_OIDC_CLIENT_SECRET=
```

### Ampliar `~/homelab/productividad/.env`

Copiar las nuevas líneas de la plantilla y rellenar los valores reales. El paso clave es generar el `LD_SUPERUSER_PASSWORD`:

```bash
# Editar el .env existente (tiene ya los valores de Vaultwarden y Bookstack;
# AÑADIR debajo las nuevas líneas).
$EDITOR ~/homelab/productividad/.env

# 1. Generar el LD_SUPERUSER_PASSWORD (24 chars sin /+=)
ld_pass=$(openssl rand -base64 32 | tr -d '/+=' | head -c 24)
echo "LD_SUPERUSER_PASSWORD (anotar en Vaultwarden — nota 'Homelab — Linkding bootstrap'): $ld_pass"
sed -i "s|^LD_SUPERUSER_PASSWORD=$|LD_SUPERUSER_PASSWORD=$ld_pass|" ~/homelab/productividad/.env

# 2. Confirmar que está
grep -E '^(LD_SUPERUSER_NAME|LD_SUPERUSER_PASSWORD)=' ~/homelab/productividad/.env
# LD_SUPERUSER_NAME=operador
# LD_SUPERUSER_PASSWORD=...

# 3. Asegurar permisos restrictivos del .env
chmod 0600 ~/homelab/productividad/.env

# 4. Limpiar la variable de la sesión
unset ld_pass
```

> **Custodia inmediata**: añadir la línea (`LD_SUPERUSER_PASSWORD`) a la nota de Vaultwarden "Homelab — Linkding bootstrap", **antes** de seguir adelante. Una vez se haya hecho login y cambiado la password desde la UI (paso 1 de **Configuración tras primer arranque**), la password del bootstrap deja de ser válida; el operador puede actualizar la nota de Vaultwarden con la **nueva** password (la del usuario en runtime) y dejar la del bootstrap como histórico.

> **Por qué `tr -d '/+='`**: igual razón que en `docs/11-productividad/02-bookstack.md` y `docs/06-almacenamiento/01-nextcloud.md` — `openssl rand -base64` puede emitir `/`, `+` o `=`, todos válidos pero molestos al copiar/pegar y problemáticos en algunos shells o ficheros `.env` mal parseados.

> **No commitear `.env` jamás**. El `.gitignore` del _stack_ ya lo excluye explícitamente.

---

## Modificar `~/homelab/productividad/docker-compose.yml`

El _docker-compose.yml_ de este _stack_ ya existe con `vaultwarden`, `bookstack` y `bookstack-db`. **Editarlo, no recrearlo**: añadir el servicio `linkding`, dejando intactos los tres bloques previos.

El nuevo servicio se añade al final de la sección `services:`, justo antes de la sección `networks:`:

```yaml
  # ===========================================================================
  # Linkding — gestor de marcadores ligero (Django + SQLite).
  # Único contenedor. Sólo en la red 'homelab' (Caddy lo alcanza por DNS).
  # NO se engancha a productividad-internal (no comparte BD con nadie).
  # ===========================================================================
  linkding:
    image: sissbruecker/linkding:${LINKDING_IMAGE_TAG}
    container_name: linkding
    hostname: linkding
    restart: unless-stopped
    environment:
      TZ: ${TZ}

      # --- Endpoint y reverse proxy ---
      LD_HOST_NAME: ${LD_HOST_NAME}
      LD_HOST_PROTOCOL: ${LD_HOST_PROTOCOL}
      LD_CSRF_TRUSTED_ORIGINS: ${LD_CSRF_TRUSTED_ORIGINS}
      LD_REQUEST_TIMEOUT: ${LD_REQUEST_TIMEOUT}
      LD_LOG_X_FORWARDED_FOR: ${LD_LOG_X_FORWARDED_FOR}

      # --- Bootstrap del superuser (idempotente: ignorado si ya existe) ---
      LD_SUPERUSER_NAME: ${LD_SUPERUSER_NAME}
      LD_SUPERUSER_PASSWORD: ${LD_SUPERUSER_PASSWORD}

      # --- Features ---
      LD_ENABLE_PUBLIC_SHARES: ${LD_ENABLE_PUBLIC_SHARES}
      LD_ENABLE_SHARING: ${LD_ENABLE_SHARING}
      LD_DISABLE_URL_VALIDATION: ${LD_DISABLE_URL_VALIDATION}
      LD_ENABLE_SNAPSHOTS: ${LD_ENABLE_SNAPSHOTS}

      # --- Locale ---
      LD_TIMEZONE: ${LD_TIMEZONE}

      # --- SMTP (opcional, descomentar cuando se configure) ---
      # LD_EMAIL_HOST: ${LD_EMAIL_HOST}
      # LD_EMAIL_PORT: ${LD_EMAIL_PORT}
      # LD_EMAIL_HOST_USER: ${LD_EMAIL_HOST_USER}
      # LD_EMAIL_HOST_PASSWORD: ${LD_EMAIL_HOST_PASSWORD}
      # LD_EMAIL_USE_TLS: ${LD_EMAIL_USE_TLS}
      # LD_EMAIL_FROM: ${LD_EMAIL_FROM}

      # --- OIDC (opcional, ver Migrar a OIDC con Authelia) ---
      # LD_ENABLE_OIDC: ${LD_ENABLE_OIDC}
      # LD_OIDC_ISSUER_URL: ${LD_OIDC_ISSUER_URL}
      # LD_OIDC_CLIENT_ID: ${LD_OIDC_CLIENT_ID}
      # LD_OIDC_CLIENT_SECRET: ${LD_OIDC_CLIENT_SECRET}
    volumes:
      - /mnt/hd2t/services/linkding/data:/etc/linkding/data
    networks:
      homelab:
        aliases:
          - linkding         # Caddy resuelve 'linkding:9090' por este alias
    labels:
      homelab.stack: "productividad"
      homelab.backup: "true"      # /mnt/hd2t/services/linkding/data (vía .backup SQLite)
      # Opt-in: semver estricto, patches sin migraciones rompedoras.
      com.centurylinklabs.watchtower.enable: "true"
    healthcheck:
      # /health devuelve "healthy" en texto plano cuando la app está sirviendo
      # y la BD responde. Endpoint público desde Linkding 1.20+.
      test:
        - CMD-SHELL
        - "wget -qO- http://localhost:9090/health >/dev/null"
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 30s
```

> **Importante** — `linkding` se añade **dentro** del bloque `services:` ya existente, NO sustituye nada. Validar después con `docker compose config | grep -E '^\s+(vaultwarden|bookstack|bookstack-db|linkding):'` que los cuatro siguen estando.

Notas de diseño:

- **Sólo en `homelab`**, no en `productividad-internal`. La BD vive dentro del propio contenedor (SQLite en el bind mount); no hay nada que aislar entre contenedores. Linkding **no se beneficia** de la red privada del _stack_.
- **Sin `ports:`**. Caddy alcanza Linkding por DNS interno (`linkding:9090`). Si el operador, durante troubleshooting, necesita acceder a Linkding sin pasar por Caddy: `docker exec -it linkding wget -qO- http://localhost:9090/health`.
- **`start_period: 30s`**: Linkding arranca rápido. La primera vez crea el SQLite y ejecuta `migrate` (~25 migraciones de Django, ~5 s en una Pi 5). 30 s da margen sobrado.
- **Watchtower opt-in**: razones explicadas en **Decisiones de diseño** → _Imagen y tag_.
- **Sin `depends_on`**: Linkding es un único contenedor sin dependencias internas al _stack_. Vaultwarden y Bookstack viven en paralelo sin que Linkding necesite saber de ellos.
- **`wget` en el _healthcheck_**: la imagen base `python:3.12-slim-bookworm` que usa Linkding **no trae `curl`** (sí `wget`). Esto difiere de Bookstack (que usa `curl`).

---

## Despliegue

### Primer arranque

```bash
cd ~/homelab/productividad
# Validar la sintaxis sin levantar nada (recomendado tras editar el compose).
docker compose --env-file ../.env --env-file .env config | grep -E '^\s+(vaultwarden|bookstack|bookstack-db|linkding):'
# vaultwarden:
# bookstack-db:
# bookstack:
# linkding:

# Levantar SÓLO el servicio nuevo (los otros tres ya están corriendo y healthy):
docker compose --env-file ../.env --env-file .env up -d linkding
```

O, equivalente, con el _Makefile_ (ver `docs/02-docker/02-estructura-compose.md`):

```bash
cd ~/homelab
make up STACK=productividad
# El make up no es selectivo: lleva el stack completo al estado deseado.
# Como Vaultwarden, Bookstack y Bookstack-db ya están up y nada del compose
# los cambia, Compose los deja tal cual y sólo arranca linkding.
```

Vigilar el primer arranque (es muy rápido, ~10 s):

```bash
docker compose -f ~/homelab/productividad/docker-compose.yml logs -f linkding
# linkding | [migrate] Operations to perform:
# linkding | [migrate]   Apply all migrations: admin, auth, bookmarks, contenttypes, ...
# linkding | [migrate] Applying contenttypes.0001_initial... OK
# linkding | [migrate] Applying auth.0001_initial... OK
# ... (~25 migraciones más) ...
# linkding | [migrate] Applying bookmarks.0001_initial... OK
# linkding | [bootstrap] Created superuser 'operador'
# linkding | [gunicorn] Listening at: http://0.0.0.0:9090
# linkding | [gunicorn] Worker spawned (pid: 12)
```

Verificar que el contenedor está `(healthy)`:

```bash
docker compose -f ~/homelab/productividad/docker-compose.yml ps
# NAME            STATUS                   PORTS
# vaultwarden     Up X minutes (healthy)
# bookstack-db    Up X minutes (healthy)
# bookstack       Up X minutes (healthy)
# linkding        Up X seconds (healthy)
```

> El `(healthy)` lo otorga el _healthcheck_ de `/health`. Si tras 1 minuto sigue `starting`/`unhealthy`, ir a **Troubleshooting** → primer arranque.

Confirmar que el SQLite se creó bien:

```bash
ls -la /mnt/hd2t/services/linkding/data/
# -rw-r--r-- 1 33 33 188416 Apr 25 12:00 db.sqlite3
# -rw-r--r-- 1 33 33  32768 Apr 25 12:00 db.sqlite3-shm
# -rw-r--r-- 1 33 33      0 Apr 25 12:00 db.sqlite3-wal
# drwxr-xr-x 2 33 33   4096 Apr 25 12:00 favicons/
```

(Los UID/GID `33:33` son `www-data` dentro del contenedor; en el host aparecen como `33:33` sin nombre porque ese UID no está mapeado a un usuario del host. **Es lo esperado**.)

Y confirmar que el superuser fue creado:

```bash
docker exec linkding python manage.py shell -c "
from django.contrib.auth.models import User
print('users:', list(User.objects.values_list('username', 'is_superuser')))
"
# users: [('operador', True)]
```

### Caddy: bloque `linkding.lan`

Editar `~/homelab/red/Caddyfile` y añadir el bloque:

```caddy
linkding.lan {
    tls internal
    import security-headers
    import logging

    # Pasar a Linkding tal cual. Caddy reescribe Host por defecto, lo que
    # combinado con LD_HOST_NAME=linkding.lan y LD_CSRF_TRUSTED_ORIGINS del
    # .env, permite a Linkding pasar la verificación CSRF de Django y
    # construir URLs https:// correctas.
    reverse_proxy linkding:9090 {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
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
curl -k --resolve linkding.lan:443:192.168.1.3 https://linkding.lan/health
# healthy

# Y el endpoint de la web (200 + redirect a /login si no hay cookie):
curl -k --resolve linkding.lan:443:192.168.1.3 -o /dev/null -s -w "%{http_code}\n" \
    https://linkding.lan/
# 302
```

Y desde el navegador: `https://linkding.lan/` → pantalla de login con candado verde y un formulario que pide username + password.

---

## Configuración tras primer arranque

### 1. Login y cambio de password

El bootstrap creó el usuario `operador` con la password de `LD_SUPERUSER_PASSWORD`. **Antes de cualquier otra cosa**:

1. `Log in` con `operador` / la password del `.env`.
2. Ir a `Settings` (esquina inferior izquierda) → `Account` → `Change password`.
3. Generar una password fuerte (≥ 16 chars) en Vaultwarden, anotarla _antes_ de pegarla. Confirmar.
4. Logout y volver a hacer login con la nueva password. Verificar que se entra sin pedir reset.
5. Actualizar la nota "Homelab — Linkding bootstrap" en Vaultwarden con la **nueva** password (la del runtime), dejando como histórico la del bootstrap.

> **No vaciar `LD_SUPERUSER_PASSWORD` del `.env`** automáticamente: dejarlo permite, en un escenario de DR, recrear el usuario si por error se borrase. Si el operador prefiere que el `.env` no contenga la password vieja (limpieza), vaciar `LD_SUPERUSER_PASSWORD=` y hacer `up -d linkding` — el _entrypoint_ no recrea ni borra al usuario existente; sólo dejaría de tener fallback automático.

### 2. Activar 2FA TOTP (recomendado)

Linkding integra `django-mfa2` desde la 1.30. Cada usuario lo activa desde su perfil:

1. `Settings → Security → Two-factor authentication → Enable`.
2. Escanear el QR con Aegis / Authy / 1Password / `oath-tool`.
3. Confirmar con un código TOTP válido.
4. Linkding muestra **8 recovery codes** de un solo uso. **Imprescindible**: copiarlos a la nota "Homelab — Linkding secrets" en Vaultwarden. Si el dispositivo TOTP se pierde y los recovery codes se pierden, el único camino es resetear el MFA del usuario desde el shell de Django (descrito en **Troubleshooting**).

> **Por qué activar MFA antes de generar el API token**: el token de API **no respeta** MFA — un atacante con el token bypassea TOTP. MFA blinda **el login web** y la creación de **nuevos** tokens. El token ya creado, si se filtra, sigue siendo válido hasta que se revoque. Por eso (a) MFA primero, (b) token después con custodia estricta en Vaultwarden.

### 3. Generar el token de API para la extensión y los _clients_

La extensión de navegador y los _clients_ móviles autentican con un token por usuario:

1. `Settings → Integrations → REST API → Show token`.
2. Linkding muestra un token de 40 chars hex (ej. `1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b`).
3. **Copiarlo a Vaultwarden** (nota "Homelab — Linkding API token") — no se vuelve a mostrar; si se pierde, hay que revocarlo y generar uno nuevo (operación reversible pero molesta porque rompe todas las extensiones a la vez).

> **Token único por usuario en Linkding**: a diferencia de Bookstack (que admite múltiples tokens por usuario, uno por cliente), Linkding tiene **un solo token por usuario**. Si se quiere "revocar el del móvil sin tirar el del navegador", la única opción es revocar y volver a configurar todos los clients. Es un compromiso del upstream; en la práctica no molesta (un operador suele tener 2-3 clients).

### 4. Instalar la extensión de navegador

Linkding tiene **extensión oficial** para Firefox y Chrome/Chromium:

- **Firefox**: <https://addons.mozilla.org/firefox/addon/linkding-extension/>
- **Chrome**: <https://chrome.google.com/webstore/detail/linkding-extension/beakmhbijpdhipnjhnclmhgjlddhidpe>

Tras instalar, el primer arranque pide:

- **Linkding URL**: `https://linkding.lan/` (con la barra final).
- **API token**: el de `Settings → Integrations` (paso anterior).
- **Test connection**: la extensión hace `GET /api/bookmarks/?limit=1`. Debe responder 200 con un JSON.

> **Si el navegador no confía en la CA local del homelab**, la extensión falla con `Network error` en el _Test connection_. Importar la CA local antes (ver `docs/03-red/04-caddy.md`). Esto suele ser la causa #1 de problemas con la extensión recién instalada.

> **Acceso desde el móvil**: la extensión no existe para móviles. En Android, la wiki se usa vía:
> - **Linkdroid** (open source, Play Store / F-Droid): cliente nativo. Configurar URL + token.
> - **Share intent** desde Firefox/Chrome móvil: `Compartir → Linkding (PWA)` si se tiene Linkding instalado como PWA. Linkding sí soporta `intent share` con un endpoint `/bookmarks/new`.

### 5. Estructura inicial de etiquetas recomendada

A diferencia de Bookstack (estanterías → libros → capítulos), Linkding usa **etiquetas planas con notación jerárquica** `parent/child`. Esquema mínimo recomendado para un homelab:

| Etiqueta              | Uso                                                                                  |
|-----------------------|--------------------------------------------------------------------------------------|
| `homelab/docs`        | Documentación oficial de servicios desplegados (LinuxServer, Caddy, Pi-hole)        |
| `homelab/runbook`     | Tutoriales y how-tos que el operador consulta a menudo                              |
| `homelab/post`        | Blog posts sobre patrones/decisiones de homelab que vale la pena recordar           |
| `dev/python`, `dev/bash`, `dev/docker` | Material de trabajo del operador (gists, snippets, refs)                  |
| `read-later`          | Artículos largos para leer cuando haya tiempo (alternativa ligera a Wallabag)      |
| `archive`             | Marcadores que ya no se usan pero no se quieren borrar (referencia histórica)       |

> **Convivencia con `~/workspace/homelab/docs/` y con Bookstack**: Linkding es para **enlaces externos**. La doc canónica del homelab vive en git (ver `docs/`) y la operativa interna en Bookstack. **No mezclar**: copiar texto de un blog post a Bookstack es duplicación; bookmarkear el blog post original en Linkding es archivar la fuente.

### 6. (Opcional) Activar snapshots por Internet Archive

Linkding puede pedir a Internet Archive que indexe cada URL nueva:

1. `Settings → Bookmarks → Web archive integration → Enable`.
2. A partir de aquí, cada vez que se añade un marcador, Linkding hace un POST a la _Wayback Machine API_ pidiendo un _snapshot_. Tarda <2 s y no bloquea el guardado.
3. En la lista de marcadores aparece un icono "🕰️ Wayback" junto a cada uno; clicando se abre la copia de IA en una pestaña nueva.

> **Por qué empieza desactivado**: respeta el _rate limit_ de Internet Archive (no martillear con miles de POST si se hace un import inicial de 5.000 marcadores), y deja que el operador decida si está cómodo enviando todas sus URLs a IA. Activación es trivial cuando se quiera.

> **Snapshot local con _Singlefile_**: alternativa al de IA, guarda una copia HTML completa en `/etc/linkding/data/assets/`. Requiere un _sidecar_ con Chromium headless (~250 MB de imagen + ~150 MB RAM). Documentado en **SingleFile opcional** al final de este documento.

### 7. Activar el bloque del _hook_ de Borgmatic

`docs/07-backups/03-backup-docker-volumes.md` dejó preparada la línea comentada:

```bash
# --- Linkding (SQLite por defecto) — docs/11-productividad/03-linkding.md
# dump_sqlite linkding linkding /etc/linkding/data/db.sqlite3
```

Descomentarla:

```bash
# Localizar el script del hook
hook=~/homelab/backups/borgmatic/hooks/dump-databases.sh
ls -la "$hook"

# Descomentar la línea (o usar el editor interactivo).
# Variante con sed:
sed -i 's|^# dump_sqlite linkding linkding /etc/linkding/data/db\.sqlite3$|dump_sqlite linkding linkding /etc/linkding/data/db.sqlite3|' "$hook"

# Validar la sintaxis bash:
bash -n "$hook" && echo OK

# Reinstalar el hook (copia el script a /etc/borgmatic.d/hooks/, ver
# docs/07-backups/03-backup-docker-volumes.md → install.sh):
~/homelab/backups/borgmatic/install.sh
```

Probar el _hook_ ad hoc sin esperar a las 03:30 AM:

```bash
sudo BORG_PASSPHRASE_FILE=/etc/borgmatic.d/secrets.env \
    bash /etc/borgmatic.d/hooks/dump-databases.sh

ls -la /mnt/hd2t/backups/dumps/ | grep linkding
# linkding-2026-04-26.sqlite.gz   ~50 KB para una BD recién creada
```

Verificar que el dump es válido:

```bash
gunzip -c /mnt/hd2t/backups/dumps/linkding-$(date +%F).sqlite.gz | file -
# /dev/stdin: SQLite 3.x database, ...

# Y que las tablas esperadas existen:
gunzip -c /mnt/hd2t/backups/dumps/linkding-$(date +%F).sqlite.gz > /tmp/linkding.sqlite
sqlite3 /tmp/linkding.sqlite ".tables" | tr ' ' '\n' | sort -u
# auth_group
# auth_permission
# auth_user
# bookmarks_bookmark
# bookmarks_tag
# bookmarks_userprofile
# django_admin_log
# django_content_type
# django_migrations
# django_session
# ... (tablas de mfa2 si MFA activo)
rm /tmp/linkding.sqlite
```

> **Por qué `.backup` y no `cp`**: igual razón que en Vaultwarden — `cp db.sqlite3` durante una escritura activa puede coger un fichero a medio _commit_ (el WAL aún no fusionado). El helper `dump_sqlite` usa la _Online Backup API_ de SQLite, que produce un fichero binario consistente con el último _commit_ sin bloquear a Linkding.

### 8. (No aplica) Activar un _jail_ de fail2ban

A diferencia de Vaultwarden (que tiene un _jail_ explícito en `docs/04-seguridad/02-fail2ban.md`), **Linkding no tiene un _jail_ pre-configurado**. Las razones:

- Linkding no expone un endpoint público a internet — vive sólo en LAN + Tailscale, donde el modelo de amenaza de _brute force_ es muy bajo.
- El log de Linkding **no escribe líneas estructuradas para fallos de login**: una autenticación fallida aparece como un `POST /login HTTP/1.1 200` en el access log de Gunicorn, indistinguible de un login exitoso (la diferencia es la cookie en la response, no parseable por fail2ban con un regex razonable).
- Para tener un _jail_ útil habría que añadir un _signal handler_ en Django que escribiera un log estructurado en cada fallo, **más** un filtro `fail2ban` _ad hoc_. Es factible (existen plugins comunitarios) pero el _ROI_ es bajo en una wiki personal en LAN.

**Política asumida**: no se configura jail. Si en el futuro Linkding se publicase en internet (cambio de modelo de red), este documento se complementaría con un _jail_ específico, en línea con el patrón Vaultwarden.

---

## Verificación final

Antes de pasar a `docs/11-productividad/04-paperless-ngx.md`, comprobar:

- [ ] `docker compose -f ~/homelab/productividad/docker-compose.yml ps` muestra `vaultwarden`, `bookstack-db`, `bookstack` y `linkding` los cuatro en `(healthy)`.
- [ ] `curl -k --resolve linkding.lan:443:192.168.1.3 https://linkding.lan/health` devuelve `healthy`.
- [ ] `https://linkding.lan/` carga la pantalla de login en el navegador con candado verde (CA local importada).
- [ ] El usuario operador puede hacer login con su username + password (ya cambiada desde la del bootstrap).
- [ ] La password actual del operador está almacenada en Vaultwarden en una nota titulada "Homelab — Linkding".
- [ ] El operador tiene MFA TOTP activo en su cuenta y los _recovery codes_ están **anotados en Vaultwarden** y en papel.
- [ ] El **token de API** del operador está generado y almacenado en Vaultwarden en una nota "Homelab — Linkding API token".
- [ ] La extensión de navegador (Firefox o Chrome) está instalada, configurada con la URL `https://linkding.lan/` y el token, y `Test connection` devuelve OK.
- [ ] Crear un marcador desde la extensión (cualquier URL, p. ej. `https://www.bookstackapp.com/`), añadir 2 etiquetas, guardarlo. Recargar `https://linkding.lan/` y verificar que aparece en la lista con sus etiquetas.
- [ ] `docker exec linkding python manage.py shell -c "from bookmarks.models import Bookmark; print('marcadores:', Bookmark.objects.count())"` muestra el contador esperado (>= 1 tras el paso anterior).
- [ ] El _hook_ de Borgmatic genera `dumps/linkding-YYYY-MM-DD.sqlite.gz`. Verificar que el dump es un SQLite válido (`file -` lo identifica) y que contiene las tablas `bookmarks_bookmark`, `bookmarks_tag`, `auth_user`.
- [ ] `docker network inspect homelab --format '{{range .Containers}}{{.Name}} {{end}}'` lista a `linkding` (entre los demás del homelab); **NO** lista a `linkding` en `productividad-internal`:
  ```bash
  docker network inspect productividad-internal --format '{{range .Containers}}{{.Name}} {{end}}'
  # Debe listar SÓLO bookstack bookstack-db (linkding no debe estar).
  ```
- [ ] Tras un `docker compose -f ~/homelab/productividad/docker-compose.yml restart linkding`, la página vuelve a `(healthy)` en <30 s y el operador sigue logueado (la sesión sobrevive porque la `SECRET_KEY` interna de Django no cambia entre restarts de contenedor).
- [ ] Tras un `sudo reboot` de la Pi, los cuatro contenedores vuelven a estar `(healthy)` sin intervención manual y `https://linkding.lan/` responde.
- [ ] `git -C ~/homelab status` muestra como **modificados**: `productividad/docker-compose.yml`, `productividad/.env.example`, `red/Caddyfile`, `backups/borgmatic/hooks/dump-databases.sh`. **No** muestra `productividad/.env` ni nada bajo `/mnt/hd2t/`. _Commit_:

  ```bash
  cd ~/homelab
  git add productividad/docker-compose.yml productividad/.env.example \
          red/Caddyfile backups/borgmatic/hooks/dump-databases.sh
  git commit -m "feat(productividad): add Linkding and activate borgmatic dump hook"
  ```

---

## Backup

| Qué                                     | Dónde                                                          | Cómo                                                       |
|-----------------------------------------|----------------------------------------------------------------|------------------------------------------------------------|
| `docker-compose.yml`, `.env.example`    | `~/homelab/productividad/`                                     | git                                                        |
| `linkding` schema + datos               | SQLite en `/mnt/hd2t/services/linkding/data/db.sqlite3`        | **Dump consistente** vía `dump_sqlite` (`sqlite3 .backup`) en el _hook_ de Borgmatic. El fichero binario _raw_ del directorio entra **además** como _source_directory_ del set "data" para preservar también `favicons/` y los assets. |
| `data/favicons/`                        | `/mnt/hd2t/services/linkding/data/favicons/`                   | Borgmatic — copia raw, retención normal del set "data". Aquí viven los favicons cacheados de cada dominio bookmarkeado. **Regenerable** (Linkding los redescarga si faltan), pero más rápido restaurarlos. |
| `data/assets/` (si Singlefile activo)   | `/mnt/hd2t/services/linkding/data/assets/`                     | Borgmatic — copia raw. Aquí viven los _snapshots_ HTML completos. **Crece notablemente** si snapshots están on; ajustar retención si se llena `/mnt/hd2t`. |
| Token de API del operador               | Nota dentro de Vaultwarden                                     | Custodia humana. NUNCA en git, NUNCA en backups con la misma passphrase que el repo. |
| Password del operador                   | Nota dentro de Vaultwarden                                     | Idem.                                                      |
| `LD_SUPERUSER_PASSWORD` (bootstrap)     | Nota dentro de Vaultwarden + papel                             | Idem; queda como ruta de DR si la password de runtime se pierde. |

Verificar que las inclusiones del set "data" de Borgmatic (en `~/homelab/backups/borgmatic/config.d/`) cubren `**/services/linkding/`. Por defecto sí, ya que `docs/07-backups/01-estrategia-backup.md` lista a `/mnt/hd2t/services/linkding` como _source_directory_ del set "data". Verificación rápida:

```bash
grep -A2 source_directories ~/homelab/backups/borgmatic/config.d/data.yaml | grep linkding
# - /mnt/hd2t/services/linkding
```

Si no aparece, añadir esa línea bajo `source_directories:` y validar:

```bash
sudo borgmatic config validate
```

> **Por qué dump SQL _y_ copia raw del directorio `data/`**: el dump (`.sqlite.gz`) es el **canónico para la BD** (consistente, deduplicable, restaurable a cualquier versión de Linkding). La copia raw del directorio `data/` es lo que permite **restaurar `favicons/` y `assets/`**, que viven _fuera_ de la BD pero son referenciados desde ella. Cinturón y tirantes — la BD sin los favicons funciona pero las URLs aparecen sin icono; los favicons sin la BD son carpetas huérfanas.

> **Restauración desde backup**:
> 1. Restaurar `/mnt/hd2t/services/linkding/data/` desde Borgmatic (incluye `favicons/`, `assets/`).
> 2. **Sustituir** el `db.sqlite3` restaurado por el dump más reciente (el dump es siempre más nuevo y consistente que la copia raw):
>    ```bash
>    docker stop linkding
>    sudo gunzip -c /mnt/hd2t/backups/dumps/linkding-YYYY-MM-DD.sqlite.gz \
>        > /mnt/hd2t/services/linkding/data/db.sqlite3
>    sudo chown 33:33 /mnt/hd2t/services/linkding/data/db.sqlite3
>    sudo rm -f /mnt/hd2t/services/linkding/data/db.sqlite3-{wal,shm}
>    docker start linkding
>    ```
> 3. Verificar login con la cuenta operador y que los marcadores y etiquetas están en su sitio.

> **Antes de cualquier upgrade _minor_ de Linkding** (1.36 → 1.37 → 1.38):
> 1. `docker compose stop linkding`.
> 2. Backup completo `data/` + dump SQLite (Borgmatic _on-demand_).
> 3. Editar `.env`: `LINKDING_IMAGE_TAG=1.37.0` (leer el _changelog_ upstream).
> 4. `docker compose pull linkding && docker compose up -d linkding`.
> 5. `docker logs -f linkding` — esperar a `[migrate] Applying ... OK` (las migraciones de la nueva versión) y `(healthy)`.
> 6. `curl -k https://linkding.lan/health` — confirmar response.
> 7. Verificación final completa de la sección anterior.
> 8. Si algo va mal: `docker compose down linkding`, restaurar `data/` y dump SQLite, `LINKDING_IMAGE_TAG=1.36.0`, `up -d linkding`.
>
> Los _bumps_ de **patch** (1.36.0 → 1.36.1) los gestiona Watchtower automáticamente; el operador no necesita intervenir, pero **debería revisar el `docker logs linkding` el día siguiente al pull** para confirmar que arrancó bien.

---

## Troubleshooting

### `linkding` arranca y queda en `unhealthy`

El `start_period: 30s` da margen para `migrate` + bootstrap. Si tras 1 minuto sigue `starting`/`unhealthy`, mirar los logs:

```bash
docker logs linkding --tail 80
```

Causas frecuentes:

1. **Migraciones fallaron**: aparece como `django.db.migrations.exceptions.MigrationError: ...`. Causas habituales:
   - Schema previo de otra versión de Linkding incompatible (si el bind mount estaba sucio). Solución: backup del `db.sqlite3` actual a otra ruta, borrar `data/`, dejar que se recree limpia, reimportar marcadores desde la copia.
   - SQLite corrupto (rara vez; pasa si se hizo un `kill -9` durante una escritura). Solución:
     ```bash
     docker exec -u 33 linkding sqlite3 /etc/linkding/data/db.sqlite3 "PRAGMA integrity_check;"
     # Debe responder 'ok'. Si no: restaurar desde el dump más reciente (sección Backup).
     ```

2. **`LD_HOST_NAME` o `LD_CSRF_TRUSTED_ORIGINS` malformados**: si el `.env` tiene `LD_HOST_NAME=https://linkding.lan` (con esquema en el hostname, error común) o `LD_CSRF_TRUSTED_ORIGINS=linkding.lan` (sin esquema, error opuesto), Django falla al arrancar con `ImproperlyConfigured`. Soluciones:
   - `LD_HOST_NAME` es **sólo el hostname**, sin esquema: `linkding.lan` (NO `https://linkding.lan`).
   - `LD_HOST_PROTOCOL` es **sólo el esquema**: `https` (NO `https://`).
   - `LD_CSRF_TRUSTED_ORIGINS` es **lista coma-separada de URLs completas**: `https://linkding.lan,https://pi.tailnet.ts.net` (con esquema, sin barra final).

3. **Permisos del bind mount**: si por error se hizo un `chown` antes del primer arranque (operador siguiendo un tutorial genérico), el `entrypoint` puede fallar al hacer su propio `chown` recursivo. Solución: `sudo chown -R 33:33 /mnt/hd2t/services/linkding/data` (UID 33 = `www-data`).

### `403 CSRF verification failed` al hacer login o al añadir un marcador

Django devuelve este error cuando el _origin_ de la petición no está en `LD_CSRF_TRUSTED_ORIGINS`. Causas:

1. **Acceso por una URL no incluida en la lista**: el operador entra por `https://pi.tailnet.ts.net/linkding/...` (sin que `pi.tailnet.ts.net` esté en `LD_CSRF_TRUSTED_ORIGINS`). Solución: añadir esa URL a la lista (`LD_CSRF_TRUSTED_ORIGINS=https://linkding.lan,https://pi.tailnet.ts.net`) y `up -d linkding`.

2. **Mismatch de `Host`**: Caddy reescribe `Host` por defecto, pero si el bloque del `Caddyfile` tiene un `header_up Host` distinto, llega un valor inesperado a Django. Solución: confirmar que el `Caddyfile` tiene `header_up Host {host}` (no `{remote_host}` ni un literal).

3. **Cookie de sesión bloqueada por el navegador**: pasa si `LD_HOST_PROTOCOL=http` pero el navegador entró por `https://`. Solución: `LD_HOST_PROTOCOL=https`.

### `502 Bad Gateway` desde Caddy hacia `linkding`

Caddy responde 502 si no puede alcanzar `linkding:9090` desde la red `homelab`. Probar:

```bash
docker exec caddy wget -qO- http://linkding:9090/health
# Debe devolver 'healthy'. Si "Connection refused": Linkding no está sirviendo.

docker exec caddy nslookup linkding
# Debe resolver a una IP del 172.20.10.0/24.
```

Causas:

1. Linkding en `unhealthy` — ver caso anterior.
2. `linkding` no está enganchada a `homelab` (mira con `docker network inspect homelab`). Si no está, revisar la sección `networks:` del compose y `up -d linkding` de nuevo.
3. La red `homelab` está sin `linkding` por un fallo silencioso de Compose. `docker compose down linkding && docker compose up -d linkding` lo recrea.

### La extensión devuelve "Network error" o "Invalid token"

1. **CA local no importada**: el navegador rechaza el certificado autofirmado y la extensión no llega a hacer la petición. Solución: importar la CA local de Caddy en el navegador (ver `docs/03-red/04-caddy.md`).
2. **Token caducado o cambiado**: el operador regeneró el token desde Settings y olvidó actualizarlo en la extensión. Solución: copiar el token actual desde `Settings → Integrations` y pegarlo en la configuración de la extensión.
3. **URL mal escrita**: la extensión exige la URL **con barra final**: `https://linkding.lan/`, no `https://linkding.lan`. Causa común de "Network error" silencioso.
4. **Tailscale y MagicDNS**: si la extensión apunta a `https://pi.tailnet.ts.net/` desde fuera de casa, asegúrate de que ese dominio está en `LD_CSRF_TRUSTED_ORIGINS` (y de que el operador realmente está conectado al _tailnet_).

### Resetear la password del usuario desde el contenedor

Si se perdió la password del operador y SMTP no está configurado (no hay forma de hacer `Reset password` desde el formulario):

```bash
docker exec -it -u 33 linkding python manage.py changepassword operador
# Changing password for user 'operador'
# Password:
# Password (again):
# Password changed successfully for user 'operador'
```

> Esto sólo es seguro si **el contenedor sigue arrancado**. Si Linkding está caído por la propia razón que motivó perder la password (raro), levantar primero `docker start linkding`.

> **Alternativa de DR**: si por algún motivo `manage.py changepassword` no funciona, basta con borrar el usuario con `manage.py shell` y reiniciar el contenedor; el _entrypoint_ recreará al operador con `LD_SUPERUSER_PASSWORD`. La nota fósil de Vaultwarden ("Homelab — Linkding bootstrap") es exactamente para este caso.

### Reset de MFA (si el operador perdió el TOTP y los recovery codes)

```bash
docker exec -it -u 33 linkding python manage.py shell <<'PY'
from django.contrib.auth.models import User
from mfa.models import User_Keys
u = User.objects.get(username='operador')
User_Keys.objects.filter(username=u.username).delete()
print("MFA cleared for operador")
PY
```

El usuario podrá hacer login sólo con username + password (sin MFA) hasta que vuelva a configurarlo desde `Settings → Security`.

### El dump de Borgmatic falla con `database is locked`

```
[dump] linkding: FAIL
Error: database is locked
```

Causa: el helper `dump_sqlite` ejecuta `sqlite3 .backup` _dentro_ del contenedor mientras Linkding (Gunicorn) tiene la BD abierta en modo WAL. Esto debería funcionar siempre (la _Online Backup API_ de SQLite está diseñada exactamente para eso), pero hay un caso patológico: si Linkding está procesando un `bulk import` de marcadores (miles a la vez), la transacción puede ser tan larga que SQLite considere la BD bloqueada.

Soluciones:

**Opción A — reintentar más tarde (recomendada)**: el _hook_ corre a las 03:30; si falla, Borgmatic lo reintenta el día siguiente. Los _imports_ masivos no son frecuentes.

**Opción B — _cold copy_** (si el problema persiste): cambiar a `dump_sqlite_cold` en el _hook_ para Linkding:
```bash
# En ~/homelab/backups/borgmatic/hooks/dump-databases.sh:
# dump_sqlite linkding linkding /etc/linkding/data/db.sqlite3
dump_sqlite_cold linkding linkding /mnt/hd2t/services/linkding/data/db.sqlite3
```
Esto para el contenedor durante ~3 s para hacer el dump. Aceptable para una wiki personal; **inaceptable** si hay que mantener Linkding 100% disponible (no es el caso de un homelab).

### `Search engine is broken` o búsqueda muy lenta

Linkding usa SQLite FTS5 para la búsqueda. Si la búsqueda no devuelve resultados o tarda más de 5 segundos en una BD pequeña, el índice FTS puede estar desincronizado:

```bash
docker exec -it -u 33 linkding python manage.py reindex_bookmarks
# Reindexed N bookmarks
```

Para BDs grandes puede tardar minutos.

### Mover el _stack_ a otra Pi (DR scenario)

1. En la Pi nueva: instalar Pi OS, Docker, montar hd2t, restaurar `~/homelab/` (git clone + `.env` desde la copia papel/Vaultwarden).
2. Restaurar `/mnt/hd2t/services/linkding/data/` desde Borgmatic.
3. Sustituir `data/db.sqlite3` por el dump más reciente (ver **Backup → Restauración**).
4. Levantar el _stack_ con `make up STACK=productividad`.
5. Esperar a `linkding (healthy)`, después hacer login con la password del operador (custodiada en Vaultwarden) y verificar marcadores.
6. Si Linkding insiste en pedir reset, usar `LD_SUPERUSER_PASSWORD` del `.env` como ruta de DR (en una BD restaurada el usuario debería existir y el `.env` es ignorado, pero por algún motivo el operador no recuerda la password de runtime: borrar al usuario desde `manage.py shell` y reiniciar para que el bootstrap lo recree).

---

## SMTP opcional

Linkding funciona sin SMTP, pero algunas funcionalidades quedan limitadas:

- **Recuperación de password** del usuario olvidadizo: sin SMTP, el _link de reset_ no se envía y la única ruta es `manage.py changepassword` desde dentro del contenedor (descrito en **Troubleshooting**).
- **Notificaciones de URLs caídas** (si en el futuro se activa la feature `LD_ENABLE_LINK_PRESERVATION_REMINDER`): por defecto Linkding envía un email cada cierto tiempo con marcadores cuyas URLs devuelven 4xx/5xx. Sin SMTP, esa feature queda muda.
- **Invitar a un usuario nuevo**: Linkding no tiene flujo de invitación por email — los usuarios se crean siempre desde el panel admin de Django (`/admin/`) y la password se pasa al usuario por canal seguro (Vaultwarden Send, Signal). SMTP no aporta nada aquí.

Para activar, descomentar el bloque correspondiente del `~/homelab/productividad/.env`:

```bash
LD_EMAIL_HOST=smtp.tu-proveedor.com
LD_EMAIL_PORT=587
LD_EMAIL_HOST_USER=tu-cuenta-smtp
LD_EMAIL_HOST_PASSWORD=tu-password-de-aplicacion
LD_EMAIL_USE_TLS=True
LD_EMAIL_FROM=linkding@tu-dominio.example
```

…y descomentar el bloque correspondiente del `docker-compose.yml`. Reiniciar:

```bash
docker compose -f ~/homelab/productividad/docker-compose.yml up -d linkding
```

Probar desde el shell de Django:

```bash
docker exec -it -u 33 linkding python manage.py shell <<'PY'
from django.core.mail import send_mail
send_mail("Test SMTP", "Funciona.", None, ["operador@tu-dominio.example"])
PY
```

Si falla, los detalles aparecen en `docker logs linkding`.

> **Por qué `True/False` capitalizados**: `LD_EMAIL_USE_TLS` se pasa a Python; los valores válidos son `True`/`False` (Pascal case), no `true`/`false` ni `1`/`0`. Esta convención está heredada de Django y la imagen no la convierte; respetar el caso exacto.

---

## SingleFile opcional (snapshots locales)

Si no se quiere depender de Internet Archive (porque la URL es interna, o porque el operador desconfía de IA, o porque quiere snapshots offline-resistentes), Linkding integra un sidecar con _Singlefile_ + Chromium headless:

```yaml
  # En ~/homelab/productividad/docker-compose.yml, AÑADIR junto a linkding:
  singlefile:
    image: capsulecorplab/singlefile:latest
    container_name: singlefile
    hostname: singlefile
    restart: unless-stopped
    networks:
      - homelab
    labels:
      homelab.stack: "productividad"
      com.centurylinklabs.watchtower.enable: "true"
```

Y en el `.env`, activar la integración:

```bash
LD_ENABLE_SNAPSHOTS=True
LD_SINGLEFILE_URL=http://singlefile:3000
```

Al guardar un marcador nuevo, Linkding hace un POST a `singlefile:3000` con la URL. El sidecar arranca Chromium, navega, captura todo el HTML+CSS+imágenes en un único `.html` y lo guarda en `/etc/linkding/data/assets/`. Tarda 5-15 s por URL en una Pi 5.

> **Coste**: ~250 MB de imagen + ~150 MB RAM idle (Chromium headless) + ~100 MB por captura. Activar **sólo** si el operador realmente lo necesita; si no, usar el snapshots de Internet Archive (gratis, sin coste local) o nada.

> **Watchtower opt-in** en singlefile: la imagen es de un mantenedor comunitario, _bumps_ patch suelen ser seguros. Si se quiere ser más conservador, cambiar a `false`.

---

## Migrar a OIDC con Authelia (opcional, futuro)

Linkding soporta **OIDC nativo desde 1.30** vía `LD_ENABLE_OIDC=True`. La integración con Authelia (`docs/04-seguridad/01-authelia.md`) consiste en:

1. **Registrar un cliente OIDC en Authelia**: añadir al `configuration.yml` de Authelia un nuevo `identity_providers.oidc.clients[]` con:
   - `id: linkding`
   - `secret: $argon2id$<hash>` (generado con `authelia crypto hash generate argon2`)
   - `redirect_uris: [https://linkding.lan/oidc/callback/]`
   - `scopes: [openid, profile, email]`
   - `userinfo_signing_algorithm: none`
2. **Configurar Linkding** añadiendo al `~/homelab/productividad/.env`:
   ```bash
   LD_ENABLE_OIDC=True
   LD_OIDC_ISSUER_URL=https://auth.lan
   LD_OIDC_CLIENT_ID=linkding
   LD_OIDC_CLIENT_SECRET=<el secret en plano, NO el hash>
   ```
3. Reiniciar Linkding: `docker compose up -d linkding`.
4. Probar el login desde un navegador limpio: `https://linkding.lan/login` muestra ahora un botón "Sign in with Authelia"; al pulsar, redirige a `https://auth.lan/?rd=...`, el operador hace su login + 2FA en Authelia, vuelve a Linkding y entra ya autenticado.

**No** se aplica en este documento por las mismas razones que en Bookstack:

- El operador único del homelab (y posiblemente la familia) no se beneficia mucho del SSO: ya hay 2FA TOTP nativo en Linkding, y el _login_ con username + password ya está unificado en Vaultwarden.
- OIDC añade una **dependencia operativa**: si Authelia se cae, Linkding queda inaccesible aunque la propia app esté `(healthy)`. La opción nativa (username + password) sigue funcionando sin cadenas de dependencia.
- Linkding **mantiene los usuarios locales en paralelo** a los OIDC (no rompe nada). La migración es **incremental** (activar OIDC manteniendo login local en paralelo, migrar el operador, y al final apagar el local con `LD_DISABLE_LOCAL_LOGIN=True`).

> **Atención al token de API**: el _token_ se asocia al **usuario interno de Django**, no al _claim_ OIDC. Si tras migrar a OIDC el username cambia (ej. de `operador` a `operador@tu-dominio.example` porque el _claim_ `sub` de Authelia tiene esa forma), Linkding crea un usuario **nuevo** en su BD interna; el token del usuario antiguo deja de funcionar y la extensión necesita reconfigurarse con un token nuevo del usuario OIDC.

---

## Referencias

- Documentación oficial de Linkding: <https://linkding.link/>
  - Variables de configuración: <https://linkding.link/options/>
  - API REST: <https://linkding.link/api/>
  - OIDC / SSO: <https://linkding.link/options/#ld_enable_oidc>
  - Reverse proxy: <https://linkding.link/setup/#hosting-with-a-reverse-proxy>
  - Snapshots y archive: <https://linkding.link/archive/>
- Repositorio upstream: <https://github.com/sissbruecker/linkding>
- Imagen Docker oficial-comunitaria: <https://hub.docker.com/r/sissbruecker/linkding>
- Extensión de navegador (Firefox + Chrome): <https://github.com/sissbruecker/linkding-extension>
- Cliente Android **Linkdroid**: <https://github.com/RyseHuang/Linkdroid> (alternativa al share intent)
- Backup de SQLite con `.backup` (Patrón S): `docs/07-backups/03-backup-docker-volumes.md` → _Patrón S_.
- Documento adyacente: `docs/11-productividad/01-vaultwarden.md` (estrenó el _stack_ `productividad`; mismo patrón SQLite-only).
- Documento adyacente: `docs/11-productividad/02-bookstack.md` (introdujo `productividad-internal`, no usada aquí; mismo patrón Caddy + CSRF).
- `docs/02-docker/02-estructura-compose.md` — un compose por dominio, redes externas/internas, convenciones de _naming_.
- `docs/02-docker/04-watchtower.md` — opt-in de Linkding (semver estricto, patches seguros).
- `docs/03-red/04-caddy.md` — Caddy, CA local, _snippets_ `security-headers` y `logging`.
- `docs/04-seguridad/01-authelia.md` — por qué Linkding **no** entra hoy en `forward_auth`; cómo migraría a OIDC en el futuro.
- `docs/07-backups/01-estrategia-backup.md` — Categoría B (datos generados por la app) + Patrón S.
- `docs/07-backups/03-backup-docker-volumes.md` — helper `dump_sqlite` y bloque comentado del _hook_.
