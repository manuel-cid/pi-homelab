# Mealie (gestor de recetas, planificación y lista de la compra)

## Descripción

Despliegue de **Mealie** como **recetario de la familia** del homelab: bóveda local de recetas con _scraper_ automático de URLs (cualquier blog o web pública con metadatos `schema.org/Recipe` se importa con un clic), categorías, etiquetas, valoraciones, fotos por receta, **planificador de comidas** semanal, **lista de la compra** generada a partir de los ingredientes del plan, _meal sharing_ entre los miembros del hogar, e importadores desde **Paprika**, **Nextcloud Cookbook**, **Tandoor**, **Yummly** y exportadores a JSON/PDF/Markdown. Sustituye al cuaderno con notas pegadas, a las capturas de pantalla del móvil que nunca se vuelven a abrir, y al "manda la receta por WhatsApp" como _solución_ para compartir lo que cocinaste anoche. La promesa operativa: el operador (y la pareja, los hijos, quien cocine) abre el móvil, busca "lentejas", encuentra _su_ versión de las lentejas con sus notas; el domingo, planifica la semana arrastrando recetas a un calendario; el lunes por la mañana, la lista de la compra ya está generada con los ingredientes que faltan en la despensa.

Este documento **continúa el _stack_ `productividad`** (`~/homelab/productividad/`) que estrenó `docs/11-productividad/01-vaultwarden.md`, amplió `docs/11-productividad/02-bookstack.md` (introduciendo la red privada `productividad-internal` y MariaDB), `docs/11-productividad/03-linkding.md` (mismo patrón Django + SQLite + token de API que aquí) y `docs/11-productividad/04-paperless-ngx.md` (Postgres + Redis + Gotenberg + Tika para el archivo documental). A diferencia de Paperless, Mealie **no necesita BD aparte** (vive sobre SQLite local, igual que Vaultwarden y Linkding) y **no requiere ampliar la red `productividad-internal`**: con un único contenedor en la red `homelab` basta. Aquí se materializa un único servicio:

- **`mealie`** — aplicación FastAPI + SQLAlchemy + Alembic + frontend SPA (imagen oficial `ghcr.io/mealie-recipes/mealie`). Una sola pieza: el binario sirve la API REST, la web UI y los assets estáticos por el mismo puerto. Persistencia en SQLite local (`/app/data/mealie.db`), sin BD aparte. La _rutina nocturna_ de Celery-Beat de Paperless **no aplica aquí**: Mealie no tiene cola de tasks externa.

Caddy (stack `red`, `docs/03-red/04-caddy.md`) expone Mealie en `https://mealie.lan/` con TLS interno (CA local). Para acceso remoto vía Tailscale (`docs/03-red/05-tailscale.md`), `https://pi.<tailnet>.ts.net/` con MagicDNS sirve el mismo recetario al móvil de quien esté en el supermercado consultando si la receta llevaba comino o cilantro.

> **Alcance**: este documento despliega Mealie con su autenticación nativa (email + password, opcional 2FA TOTP integrada desde 2.x), crea **el usuario operador** vía las variables `DEFAULT_EMAIL` y `DEFAULT_PASSWORD` del primer arranque, **deshabilita el registro abierto** (`ALLOW_SIGNUP=false`), genera el **token de API** del operador para que las apps móviles (no oficiales pero compatibles vía la API) y los _bookmarklets_ de _scraping_ funcionen, configura **el _scraper_ de recetas** sobre URLs (es la feature estrella — Mealie hace una petición a la URL, parsea el JSON-LD `schema.org/Recipe` o cae a heurísticas, y genera la receta con ingredientes, instrucciones y foto), y **descomenta el bloque del _hook_ de Borgmatic** que dejó preparado `docs/07-backups/03-backup-docker-volumes.md` con `dump_sqlite mealie mealie /app/data/mealie.db`. **No** delega autenticación a Authelia vía `forward_auth` (mismo razonamiento que Vaultwarden, Bookstack, Linkding y Paperless — la API REST con _bearer tokens_ y los _intents_ de _share_ desde el navegador móvil rompen con un redirect HTML; ver **Decisiones de diseño**). **No** activa OIDC contra Authelia (queda como **opcional** al final, mismo patrón que Linkding y Paperless). **No** configura SMTP en este documento (queda como **opcional** al final).

> **Recordatorio de red**: Mealie **no se publica al host**. Caddy la alcanza por DNS interno de Docker (`mealie:9000` en la red `homelab`). No hay BD que aislar (SQLite vive dentro del propio contenedor sobre un _bind mount_), por lo que **no** hace falta ampliar `productividad-internal` (se queda con `bookstack`, `bookstack-db`, `paperless`, `paperless-db`, `paperless-redis`, `paperless-gotenberg`, `paperless-tika` dentro). Pi-hole resuelve `mealie.lan → 192.168.1.3` por el _wildcard_ de `02-homelab-local.conf` (ver `docs/03-red/02-pihole.md`).

---

## Requisitos previos

- `docs/02-docker/02-estructura-compose.md` completado: la tabla de stacks reserva el _slot_ `productividad`, la red Docker `homelab` (`br-homelab`, `172.20.10.0/24`) externa está creada, `~/homelab/.env` global con `TZ=Europe/Madrid`, `PUID=1000`, `PGID=1000`, `HOMELAB_DOMAIN=lan` está rellenado, y el _Makefile_ de operación expone `make up STACK=<stack>`.
- `docs/01-sistema/04-estructura-directorios.md` completado: `/mnt/hd2t/services/mealie/` ya existe vacío. En este documento se crea además `/mnt/hd2t/services/mealie/data/` por _populate_ del bind mount.
- `docs/02-docker/04-watchtower.md` completado: la convención `com.centurylinklabs.watchtower.enable` está documentada. Mealie aparece en la lista de **opt-in** desde el principio (justificación en **Decisiones de diseño**).
- `docs/03-red/02-pihole.md` completado: Pi-hole resuelve `*.lan → 192.168.1.3`. **No hay que añadir nada** para `mealie.lan` — el _wildcard_ ya lo cubre.
- `docs/03-red/04-caddy.md` completado: Caddy escucha en `192.168.1.3:443` con `tls internal`, los _snippets_ `security-headers.caddy` y `logging.caddy` existen, y la directiva `import /etc/caddy/snippets/*.caddy` está activa en el `Caddyfile`. La CA local ya firma `*.lan`.
- `docs/07-backups/03-backup-docker-volumes.md` completado: el helper `dump_sqlite` está cargado en `~/homelab/backups/borgmatic/hooks/dump-databases.sh` y el bloque comentado `# dump_sqlite mealie mealie /app/data/mealie.db` está listo para descomentar.
- `docs/11-productividad/01-vaultwarden.md` completado: el _stack_ `productividad` ya existe con `~/homelab/productividad/{docker-compose.yml,.env,.env.example,.gitignore}`. **Este documento amplía** esos ficheros — no los crea desde cero. Tener Vaultwarden vivo también significa que el operador **ya tiene una bóveda** donde guardar el _bootstrap password_ inicial y el _API token_ que se generan abajo.
- `docs/11-productividad/04-paperless-ngx.md` completado: el _stack_ `productividad` está vivo con nueve servicios (Vaultwarden, Bookstack, Bookstack-db, Linkding, Paperless, Paperless-db, Paperless-redis, Paperless-gotenberg, Paperless-tika) en `(healthy)`. **Este documento sólo añade un décimo contenedor.**
- Conectividad saliente para descargar la imagen (sólo la primera vez):
  ```bash
  docker pull --platform linux/arm64 ghcr.io/mealie-recipes/mealie:2.8.0 >/dev/null && echo OK
  ```
- Que el host **no** tenga ya un servicio escuchando en `:9000` por error (`docker ps --format '{{.Names}} {{.Ports}}' | grep ':9000->' || echo OK`). Este _stack_ no publica puertos al host; Caddy es quien recibe el tráfico HTTPS.
- Espacio en `/mnt/hd2t`: Mealie es **muy ligero**. La aplicación idle ocupa ~250 MB de RAM (FastAPI + el frontend cacheado), la BD SQLite recién creada <1 MB, y las fotos de las recetas raramente superan unos cientos de MB en uso normal (cada foto ~100-500 KB tras compresión interna). Verificar holgura mínima:
  ```bash
  df -h /mnt/hd2t
  # Debe quedar holgado. Mealie ocupará <500 MB iniciales en /mnt/hd2t
  # incluso con varios cientos de recetas con foto.
  ```

---

## Decisiones de diseño

### Por qué Mealie (y no Tandoor / Grocy / Cooklang / Paprika cloud / Nextcloud Cookbook)

El homelab necesita **un gestor de recetas** que cumpla a la vez: scraper de URLs (parsear `schema.org/Recipe` JSON-LD que casi todos los blogs ya emiten), planificador semanal, lista de la compra _generada_ (no manual), API REST decente, _self-hosting_ ARM64 maduro, multilenguaje (ES + EN al menos), UI usable desde el móvil y un _footprint_ pequeño (es la décima aplicación del homelab). Cinco candidatos descartados y por qué:

| Candidato                | Por qué se descarta                                                                                                                                                  |
|--------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **Tandoor**              | Funcionalmente más completo: cookbooks, _meal types_ avanzados, supermercado con secciones, soporte de **Cooklang**. Pero el _stack_ es **Django + Postgres + Redis + nginx** (mínimo cuatro contenedores) y la UI, aunque potente, tiene curva de aprendizaje. _Overkill_ para una familia que sólo quiere "guardar recetas y planificar la cena". Se reconsidera si en el futuro la cocina se vuelve más sofisticada. |
| **Grocy**                | Modelo conceptual orientado a **inventario doméstico** (qué hay en la nevera, qué caduca cuándo). Las recetas son una _feature_ secundaria y la planificación es básica. Útil si el caso de uso prioritario es "no tirar comida"; no lo es aquí. |
| **Cooklang + Open Cookbook** | _Cooklang_ es un formato de texto plano (`.cook`) brillante para versionar recetas en git. El visor _Open Cookbook_ está en alfa. Sin scraper de URLs, sin planificador, sin lista de compra automática. Demasiado austero como gestor familiar. |
| **Paprika Recipe Manager** | App propietaria con sincronización cloud en sus servidores. Excelente UX, pero modelo opuesto al objetivo del homelab (datos fuera). Mealie **importa desde Paprika** (`.paprikarecipes`), así que es una rampa de salida si alguien viene de allí. |
| **Nextcloud Cookbook**    | Plugin de Nextcloud (que ya está desplegado, ver `docs/06-almacenamiento/01-nextcloud.md`). Tentación natural: aprovechar la pila Nextcloud existente. Descartado porque (a) **el plugin es básico** (sin planificador real, sin lista de compra generada), (b) acopla el ciclo de vida de las recetas al de Nextcloud (un upgrade de NC podría romper el plugin), y (c) la app móvil de Mealie (PWA + clientes comunitarios) es notablemente mejor que la del plugin. |

Mealie gana por:

- **Stack mínimo viable**: un único contenedor sobre SQLite. Cero sidecar, cero Redis, cero cola externa. Mealie 2.x abandonó la dependencia obligatoria de Postgres que tenía la 1.x — para uso doméstico, SQLite es perfecto.
- **Scraper de URLs robusto**: la _killer feature_. Mealie parsea `application/ld+json` con `schema.org/Recipe` (estándar que casi todo blog moderno de cocina emite — Google los premia en SEO) y extrae nombre, ingredientes, instrucciones, tiempo, raciones, foto. Para sitios sin JSON-LD, hay heurísticas. **El operador pega una URL, le da a "Importar", y en 3 s tiene la receta editable, con foto, en su recetario**.
- **Planificador y lista de la compra integrados**: arrastrar recetas al calendario semanal genera automáticamente la lista de la compra agregando ingredientes (con _aliases_ de unidades: "1 taza" + "200 ml" se mantienen separados; "2 cebollas" + "1 cebolla" se suman a "3 cebollas"). _Tickable_ desde el móvil en el supermercado.
- **API REST documentada**: `/api/*` con OpenAPI 3.0 autogenerada (visible en `https://mealie.lan/docs`). Autenticación por _Bearer token_ por usuario. Aprovechable para integraciones (n8n, Home Assistant: "el lunes pregunta qué hay para cenar y ofrece a Alexa la lista de la compra"…) o scripts de import masivo.
- **Multitenancy ligera**: el modelo "Households" introducido en 2.x permite que varios miembros de la familia tengan sus recetas privadas y compartan algunas en un grupo "Casa". Para empezar, basta con un único household y todos los usuarios dentro.
- **Soporte ARM64 oficial** vía `ghcr.io/mealie-recipes/mealie`. Multi-arch nativo, mantenido por el upstream (Hayden Pearce + comunidad). **Sin** dependencia de LinuxServer.io aquí.
- **Migración fuera trivial**: exportador a JSON estándar (uno por receta, con todos los campos) y a Markdown. Cualquier sustituto futuro (Tandoor, scripts caseros) puede importarlo. **Sin lock-in**.

### Imagen y _tag_

- **`ghcr.io/mealie-recipes/mealie:2.8.0`** — Mealie 2.8.x empaquetada por el upstream, multi-arch (`linux/arm64`). Pinneada a _tag_ "major.minor.patch" semver siguiendo la convención del homelab (ver `docs/02-docker/02-estructura-compose.md`, sección **Imágenes**: nada de `:latest`). Mealie publica versiones cada pocas semanas; los _bumps_ de **patch** (2.8.0 → 2.8.1) son seguros y los gestiona Watchtower (ver más abajo). Los _bumps_ de **minor** (2.8.x → 2.9.0) traen funcionalidades nuevas y a veces migraciones de schema (Alembic); se gestionan a mano leyendo el _changelog_. Los _bumps_ de **major** (2.x → 3.x) suelen ser raros y exigen leer las _release notes_ con calma.
- **No se usa el _tag_ `:latest`** — al ser Mealie una aplicación con BD propia y migraciones automáticas, un `pull` de `:latest` que cruzase un _bump_ minor podría aplicar migraciones irreversibles. El _tag_ pinneado da la libertad de elegir cuándo migrar.

#### Watchtower opt-in en este contenedor

Razones, mismo patrón que Linkding:

- El proyecto sigue **semver semi-estricto**: los _bumps_ de **patch** son retrocompatibles y normalmente no incluyen migraciones de _schema_ rompedoras. Watchtower puede aplicarlos sin riesgo.
- La superficie de criticidad es baja: si Mealie cae 30 segundos durante un `restart` post-pull, la familia no pierde nada (las recetas siguen siendo accesibles desde el cache del navegador hasta que vuelva, y la lista de la compra se recarga sola al cabo de 30 s).
- El SQLite es ligero. `alembic upgrade head` corre en <2 s en una Pi 5; un fallo de migración que dejara la BD a medias se detectaría en el _healthcheck_ inmediatamente y Watchtower no aplicaría más actualizaciones.

Etiquetar con `com.centurylinklabs.watchtower.enable: "true"`. Para _bumps minor_ (2.8 → 2.9), Watchtower **respeta el _tag_** del compose: no cruza de `:2.8.0` a `:2.9.0` solo porque exista un `:latest` distinto. Lo único que hace es _re-pull_ del mismo _tag_ por si hubo un _rebuild_ con un _digest_ nuevo. En la práctica, para _bumps minor_ habrá que editar `MEALIE_IMAGE_TAG` a mano.

> **Coherencia con `docs/02-docker/04-watchtower.md`**: ese documento ya lista a "Mealie" en la lista explícita de servicios **opt-in** desde el principio. No hace falta justificar nada extra aquí; sólo aplicar la etiqueta.

### SQLite en lugar de PostgreSQL

Mealie 2.x soporta los dos backends (SQLite por defecto, PostgreSQL vía `DB_ENGINE=postgres`). La elección **forzada por el caso de uso** del homelab es **SQLite**:

- **Volumen de datos**: una familia típica acumula entre 200 y 2.000 recetas a lo largo de los años. SQLite con FTS5 maneja eso con una latencia de búsqueda de <50 ms. Para llegar a justificar Postgres habría que estar en el orden de cientos de miles de recetas con concurrencia de escritura masiva — escenario absurdo en un homelab familiar.
- **Cero overhead operativo**: sin sidecar, sin _hostname_ adicional en `productividad-internal`, sin `POSTGRES_PASSWORD` que custodiar, sin `pg_dump` extra en el _hook_ de Borgmatic (basta con `dump_sqlite`, el patrón S de `docs/07-backups/03-backup-docker-volumes.md`).
- **Backup más simple**: una llamada a `sqlite3 .backup` produce un fichero binario consistente sin parar el contenedor. Un dump SQL de Postgres requiere un _client_ instalado en el contenedor (o un sidecar `pg_dump`). El SQLite gana en tres líneas de _hook_ frente a quince.
- **Restauración más simple**: copiar el fichero `.db` a su sitio y arrancar el contenedor. Sin _hostname_ de BD, sin _user_/`password`, sin `CREATE DATABASE` previo.
- **Coherencia**: Linkding y Vaultwarden ya viven sobre SQLite en el mismo _stack_. Mealie sigue el mismo patrón. **Paperless** es la excepción (forzada por su volumen de full-text search y la concurrencia de Celery, ver `docs/11-productividad/04-paperless-ngx.md`).

> **Si en el futuro Mealie pasase a "muchos usuarios escribiendo en paralelo"** (improbable en un hogar familiar), la migración a Postgres está documentada upstream y consiste en `mealie export` + cambiar `DB_ENGINE=postgres` + `mealie import`. Operación de un par de horas, no irreversible.

> **Coherencia con `docs/07-backups/03-backup-docker-volumes.md`**: ese documento dejó preparados **dos** bloques comentados — uno para Postgres (`# dump_postgres mealie mealie-db ...`) y otro para SQLite (`# dump_sqlite mealie mealie /app/data/mealie.db`). Aquí se descomenta **sólo** el segundo. El primero queda como comentario de referencia para una eventual migración futura.

### `forward_auth` con Authelia: **NO** para Mealie

Misma decisión que en Vaultwarden, Bookstack, Linkding y Paperless. Razones específicas para Mealie:

- **API REST con _Bearer tokens_**: Mealie expone `/api/*` con autenticación por _token_ (`Authorization: Bearer <jwt>`). No sigue redirects HTML. Si Caddy intercepta una petición a `/api/recipes` con un `302` hacia `https://auth.lan/?rd=...`, los _clients_ que usen la API (n8n, Home Assistant, scripts caseros, _bookmarklets_ de import desde el móvil) reciben HTML en lugar del JSON esperado y fallan con errores opacos.
- **PWA y _share intent_**: Mealie es instalable como PWA en Android e iOS. Cuando el operador comparte una URL desde el navegador móvil ("Compartir → Mealie"), el _intent_ dispara una llamada a `/recipes/create-from-url` con la URL como _payload_. Cualquier redirect a Authelia rompe el flujo, y volver a desbloquear Authelia desde el _share sheet_ del móvil es un sufrimiento UX inaceptable.
- **OIDC nativo**: Mealie soporta **OIDC desde 1.10** vía las variables `OIDC_*`. Igual que en Linkding, el camino correcto para unificar el _login_ con Authelia es **dentro** de Mealie, **no** poniendo Authelia delante con `forward_auth`. La sección **Migrar a OIDC con Authelia (opcional)** del final de este documento describe ese camino.

> **Resumen operativo**: el bloque `mealie.lan` del `Caddyfile` lleva `import security-headers` y `import logging`, pero **no** `import authelia`. Caddy actúa como _reverse proxy_ "tonto"; Mealie autentica con su sistema nativo (email + password + opcional MFA TOTP) y, cuando se decida, con OIDC contra Authelia desde dentro de la propia app.

### `BASE_URL` byte a byte

Mealie genera URLs absolutas en _password reset_ (si SMTP está activo), en los _share links_ de receta y en los _OAuth redirect URIs_ a partir de la variable `BASE_URL`. Si no se le dice, las construye con el _hostname_ que el WSGI ve en la request — y como Caddy reescribe `Host` a `mealie.lan` por defecto, lo natural es que coincidan… pero **lo natural no es lo seguro**, y además `BASE_URL` se usa también para la **lista de orígenes confiables CSRF** del frontend.

Política:

```bash
BASE_URL=https://mealie.lan
```

…fijado en el `.env`. Coincide byte a byte con el dominio del bloque del `Caddyfile`. **Importante**: incluye el esquema `https://` y **no lleva barra final**. Mealie es estricto con esto: `https://mealie.lan/` (con barra) genera URLs `https://mealie.lan//api/...` (con doble barra) que rompen algunos clientes.

> **Tailscale**: a diferencia de Paperless (que tiene `PAPERLESS_CSRF_TRUSTED_ORIGINS` independiente y ampliable a `pi.tailnet.ts.net`), Mealie 2.x **no** expone una variable equivalente. La forma de acceder vía Tailscale es: el operador entra por `https://pi.tailnet.ts.net/`, Caddy reescribe `Host` a `mealie.lan` para el backend, Mealie cree que sigue siendo `mealie.lan` y construye URLs `https://mealie.lan/...` que el navegador del operador resuelve a través de la VPN. Funciona porque Pi-hole en el _tailnet_ resuelve también `mealie.lan → 192.168.1.3`. **Si MagicDNS no está enrutando Pi-hole en el tailnet**, la PWA en remoto verá las URLs absolutas como inalcanzables — solución: añadir `mealie.lan` al `/etc/hosts` del cliente Tailscale, o asegurar que `tailscale up --accept-dns` está activo.

### Bootstrap del superuser por env vars

Mealie ofrece dos caminos para crear el primer usuario:

1. `docker exec -it mealie /app/venv/bin/python -m mealie.app.cli create-user` (CLI interactiva): pregunta email, password, full name.
2. Variables `DEFAULT_EMAIL` y `DEFAULT_PASSWORD` en el `.env`: el _entrypoint_ las lee en cada arranque y, si **no existe ya** un usuario administrador, lo crea con esas credenciales. Si existe, no toca nada (no resetea la password).

Política aplicada: **opción 2**. Razones idénticas a Linkding y Paperless:

- **Reproducibilidad**: el bootstrap está en `~/homelab/productividad/.env`, custodiado igual que el resto de secrets. Una restauración en una Pi nueva crea automáticamente el operador en el primer arranque.
- **Cero interactividad**: no hay que ejecutar comandos manuales después de `make up`. El despliegue queda en `up -d` + verificar.
- **Seguridad**: tras el primer login, **se cambia la password** desde la UI a una nueva (anotada en Vaultwarden). La password del `.env` deja de ser válida (Mealie no la sobrescribe en futuros arranques porque "el usuario ya existe"). El `.env` se queda con la password vieja como fósil; no es un secreto activo.

> **Atención**: si se borra el usuario administrador desde la UI por error, **el siguiente arranque del contenedor NO lo recreará automáticamente** (Mealie comprueba "¿existe algún superuser?", no "¿existe un superuser con el email del `.env`?"). Si no queda **ningún** superuser, sí lo recrea. Si queda al menos uno (otro miembro de la familia con privilegios), Mealie no toca nada. **Ruta de DR**: si el operador queda fuera y otro usuario aún tiene admin, ese otro usuario hace `Settings → Users → Reset password` del operador. Si no queda nadie, borrar todos los superusers desde el _shell_ de Mealie y reiniciar (descrito en **Troubleshooting**).

### `ALLOW_SIGNUP=false` y _household tokens_

Mealie permite, por defecto, que cualquiera con acceso a la URL se registre como usuario nuevo (`ALLOW_SIGNUP=true` por histórico). Política del homelab: **off**. Razones:

- Mealie está accesible desde la LAN y vía Tailscale; nadie debería _registrarse_ por su cuenta.
- Los nuevos usuarios (familia, invitados con acceso temporal a recetas concretas) se crean **explícitamente** desde `Settings → Users → Add user` por el operador.
- Para invitar usuarios externos a un _household_ específico (ej. una hermana que también quiera ver el recetario familiar), Mealie 2.x ofrece **household invite tokens** de un solo uso desde `Households → Invitations`. El usuario invitado pone email + password + el token y queda dentro de ese household sin que se haya tocado `ALLOW_SIGNUP`.

Por tanto:

```bash
ALLOW_SIGNUP=false
```

…fijado en el `.env`. Si en el futuro la familia decide abrir un _share público_ del recetario (ej. `https://mealie.lan/g/family/cookbook/recetas-de-mama`), Mealie permite enlaces de "lectura pública" por receta o cookbook desde la propia UI **sin** activar el signup.

### `PUID`/`PGID` y permisos del bind mount

Mealie corre internamente como **`abc:abc`** (UID 911:911 en la imagen oficial, no como un UID típico tipo 1000) por convención de la imagen base de `python:3.12-slim`. A diferencia de Paperless (que tiene `USERMAP_UID/USERMAP_GID` y se reasigna en runtime), Mealie **no expone variables para cambiar el UID interno**. Esto significa que el bind mount `/mnt/hd2t/services/mealie/data/` quedará con ownership `911:911` tras el primer arranque, y el host lo verá como `911:911 (sin nombre)`.

**Esto está bien**, igual que el caso del directorio `db/` de Paperless con UID 999. Sólo Mealie escribe ahí; el operador no debería tocar esos ficheros directamente. **Importante**: si por error se hace `chown` antes del primer arranque, el _entrypoint_ puede fallar al inicializar la BD. **Ruta correcta**: dejar `/mnt/hd2t/services/mealie/data/` vacío y con ownership `root:root 0755` (como lo dejó `docs/01-sistema/04-estructura-directorios.md`), y dejar que Mealie haga su `chown` recursivo en el primer arranque.

> Si por alguna razón se necesita acceso desde el host (debug, edición manual de ficheros, copia rápida sin Borgmatic): `sudo cat /mnt/hd2t/services/mealie/data/mealie.db` funciona (root puede leer todo); `cat` desde el usuario `homelab` da _Permission denied_ — eso es lo esperado. Para alinear UIDs (raro y desaconsejable), añadir `homelab` al grupo `911` y dar `g+r` recursivo, pero rompe la convención.

### Almacenamiento

| Ruta en el host                                | Contenido                                                                              | Versionable | Backup |
|------------------------------------------------|----------------------------------------------------------------------------------------|-------------|--------|
| `~/homelab/productividad/docker-compose.yml`   | Definición del _stack_ (modificada — añade `mealie`)                                   | git         | git    |
| `~/homelab/productividad/.env`                 | Imágenes pinneadas + `DEFAULT_EMAIL` + `DEFAULT_PASSWORD`                              | **NO** (`.gitignore`) | nota local (custodia separada) |
| `~/homelab/productividad/.env.example`         | Plantilla con nombres de variables, sin valores                                        | git         | git    |
| `/mnt/hd2t/services/mealie/data/`              | SQLite (`mealie.db`), fotos de recetas, exportaciones, plugins                         | **NO**     | **Sí** (Borgmatic, vía `dump_sqlite` + copia raw del directorio) |
| `/mnt/hd2t/services/mealie/data/recipes/`      | Fotos y assets binarios por receta                                                     | **NO**     | **Sí** (raw — ligero, ~hundreds KB por receta con foto) |
| `/mnt/hd2t/services/mealie/data/backups/`      | Backups internos de Mealie (UI: `Settings → Backups → Create backup`). _Regenerable_   | **NO**     | No (excluido — son redundantes con el dump SQLite + Borgmatic) |
| `/mnt/hd2t/services/mealie/data/mealie.log`    | Log _runtime_ de Mealie. Útil para troubleshooting; rotación nativa.                   | **NO**     | No (excluido — no aporta nada en una restauración) |

> **Permisos**: tras el primer arranque, todo `/mnt/hd2t/services/mealie/data/` tiene ownership `911:911` (= `abc:abc` dentro del contenedor; en el host aparecen como `911:911` sin nombre porque ese UID no está mapeado a un usuario del host). **Es lo esperado** — no hay que hacer `chown` manual. **Confirmar** después del primer arranque:
> ```bash
> stat -c '%U:%G' /mnt/hd2t/services/mealie/data/mealie.db
> # 911:911    (UNKNOWN UID/GID, normal)
> ```

> **Política sobre `data/backups/`**: Mealie tiene una feature en la UI llamada "Create backup" que produce un `.zip` con todo dentro. **No la usamos como backup primario**: es un fichero más para Borgmatic, redundante con el dump SQLite + la copia raw del directorio. Sí se puede usar para _exports puntuales_ (ej. "envíame todo el recetario antes de que cancele el homelab") — esos casos puntuales no necesitan retención automática. Por eso `data/backups/` se **excluye** del backup en `exclude_patterns` de Borgmatic.

---

## Estructura del _stack_ `productividad` tras este documento

Antes de este documento (tras `docs/11-productividad/04-paperless-ngx.md`):

```
~/homelab/productividad/
├── docker-compose.yml        # contiene vaultwarden + bookstack + bookstack-db + linkding +
│                             #          paperless + paperless-db + paperless-redis +
│                             #          paperless-gotenberg + paperless-tika
├── .env                      # APP vars de los nueve
├── .env.example
└── .gitignore
```

Tras este documento:

```
~/homelab/productividad/
├── docker-compose.yml        # ← MODIFICADO: añade mealie
├── .env                      # ← MODIFICADO: añade MEALIE_*
├── .env.example              # ← MODIFICADO: añade plantilla MEALIE_*
└── .gitignore                # sin cambios
```

Y en el disco externo, sobre lo que ya creó `docs/01-sistema/04-estructura-directorios.md`:

```
/mnt/hd2t/services/mealie/
└── data/                     # ← se crea al primer arranque del contenedor mealie
    ├── mealie.db
    ├── mealie.db-wal
    ├── mealie.db-shm
    ├── recipes/              # ← fotos por receta
    ├── backups/              # ← backups internos de Mealie (UI), excluidos de Borgmatic
    └── mealie.log
```

Ningún cambio en `~/homelab/productividad/.gitignore` (ya excluye `.env`). Ningún subdirectorio _stub_ que crear a mano: la imagen hace _populate_ del bind mount en el primer arranque.

> **Confirmar el árbol** antes de seguir:
> ```bash
> ls -la /mnt/hd2t/services/mealie/
> # vacío, ownership root:root      (creado por 04-estructura-directorios.md)
> ```
> Si por algún intento previo ya existiese `data/` con datos antiguos, **borrarlo** antes del primer arranque limpio:
> ```bash
> sudo rm -rf /mnt/hd2t/services/mealie/data
> ```

---

## Variables de entorno

### Ampliar `~/homelab/productividad/.env.example`

Abrir el fichero existente (ampliado en `docs/11-productividad/04-paperless-ngx.md`) y **añadir al final** un nuevo bloque (no tocar las líneas de Vaultwarden, Bookstack, Linkding ni Paperless):

```bash
# ============================================================================
# Mealie — gestor de recetas (docs/11-productividad/05-mealie.md)
# ============================================================================

# --- Imagen pinneada --------------------------------------------------------
MEALIE_IMAGE_TAG=2.8.0

# --- Mealie — endpoint y dominio -------------------------------------------
# CRÍTICO: Mealie lo usa para construir URLs absolutas (share links, password
# reset si SMTP, OIDC redirects). Incluye esquema, NO barra final.
BASE_URL=https://mealie.lan

# --- Mealie — bootstrap del usuario administrador --------------------------
# Variables leídas en el primer arranque (cuando no hay superuser). Crean el
# usuario operador automáticamente. Tras el primer login, el operador cambia
# la password desde 'User profile → Change password' y deja estas variables
# como fósiles inertes (Mealie no las re-aplica si ya existe algún superuser).
#
# Generación del DEFAULT_PASSWORD recomendada (al rellenar el .env real):
#   openssl rand -base64 32 | tr -d '/+=' | head -c 24
# Custodia: nota "Homelab — Mealie bootstrap" en Vaultwarden.
DEFAULT_EMAIL=operador@homelab.lan
DEFAULT_PASSWORD=

# --- Mealie — política de registro -----------------------------------------
# Off por homelab (LAN + Tailscale). Para invitar a otros usuarios al
# household, usar 'Households → Invitations' (genera tokens de un solo uso).
ALLOW_SIGNUP=false

# --- Mealie — base de datos ------------------------------------------------
# SQLite (default). Si se quisiera Postgres, cambiar a 'postgres' y rellenar
# las POSTGRES_* (entonces hay que añadir un servicio mealie-db al compose,
# ver sección 'Migrar a PostgreSQL' al final de este documento).
DB_ENGINE=sqlite

# --- Mealie — locale y zona horaria ----------------------------------------
# DEFAULT_GROUP es el nombre del grupo inicial (un grupo agrupa varios
# households; en uso familiar, un único grupo 'Casa' con un único household
# 'Familia' es suficiente).
DEFAULT_GROUP=Casa
DEFAULT_HOUSEHOLD=Familia

# --- Mealie — TLS detrás del reverse proxy --------------------------------
# Hace que Mealie respete las cabeceras X-Forwarded-* de Caddy y construya
# cookies con el flag 'Secure'. Sin esto, las cookies se quedan a no-Secure
# y Chrome las rechaza en https://mealie.lan/.
TOKEN_TIME=48                       # horas de validez del JWT de sesión
SESSION_SECRET=                     # 32+ chars random, secret cookie signing

# --- Mealie — API y CORS ---------------------------------------------------
# Cabeceras CORS ya las gestiona Caddy si fuera necesario. Mealie no necesita
# CORS en uso normal (la web y la API viven bajo el mismo origen).
API_PORT=9000

# --- Mealie — features -----------------------------------------------------
# Si la familia comparte el recetario por enlace público (URLs /g/...), Mealie
# expone páginas de "share" sin login. Útil; mantener en true.
ALLOW_PASSWORD_LOGIN=true
SECURITY_MAX_LOGIN_ATTEMPTS=5
SECURITY_USER_LOCKOUT_TIME=24       # horas

# --- Mealie — log -----------------------------------------------------------
LOG_LEVEL=INFO

# --- SMTP (opcional, ver sección 'SMTP opcional' al final) -----------------
# Vacío = funcionalidad de email deshabilitada. Mealie sin SMTP funciona
# perfectamente; sólo se pierde la auto-recuperación de password (queda
# disponible la ruta admin) y los emails de invitaciones a household
# (las invitaciones se entregan por copy-paste del token).
# SMTP_HOST=
# SMTP_PORT=587
# SMTP_FROM_NAME=Mealie
# SMTP_FROM_EMAIL=mealie@homelab.example
# SMTP_AUTH_STRATEGY=TLS
# SMTP_USER=
# SMTP_PASSWORD=

# --- OIDC (opcional, ver sección 'Migrar a OIDC con Authelia' al final) ----
# OIDC_AUTH_ENABLED=false
# OIDC_PROVIDER_NAME=Authelia
# OIDC_CONFIGURATION_URL=https://auth.lan/.well-known/openid-configuration
# OIDC_CLIENT_ID=mealie
# OIDC_CLIENT_SECRET=
# OIDC_AUTO_REDIRECT=false
# OIDC_USER_CLAIM=preferred_username
# OIDC_GROUPS_CLAIM=groups
# OIDC_ADMIN_GROUP=mealie-admin
# OIDC_USER_GROUP=mealie-user
```

### Ampliar `~/homelab/productividad/.env`

Copiar las nuevas líneas de la plantilla y rellenar los valores reales. Hay dos secrets a generar (la _session secret_ del JWT y la password del superuser):

```bash
# Editar el .env existente (tiene ya los valores de Vaultwarden, Bookstack,
# Linkding y Paperless; AÑADIR debajo las nuevas líneas).
$EDITOR ~/homelab/productividad/.env

# 1. Generar SESSION_SECRET (32 chars sin /+=)
session_secret=$(openssl rand -base64 48 | tr -d '/+=' | head -c 32)
echo "SESSION_SECRET (anotar en Vaultwarden — nota 'Homelab — Mealie secrets'): $session_secret"
sed -i "s|^SESSION_SECRET=$|SESSION_SECRET=$session_secret|" ~/homelab/productividad/.env

# 2. Generar DEFAULT_PASSWORD (24 chars sin /+=)
admin_pass=$(openssl rand -base64 32 | tr -d '/+=' | head -c 24)
echo "DEFAULT_PASSWORD (anotar en Vaultwarden — nota 'Homelab — Mealie bootstrap'): $admin_pass"
sed -i "s|^DEFAULT_PASSWORD=$|DEFAULT_PASSWORD=$admin_pass|" ~/homelab/productividad/.env

# 3. Confirmar que están
grep -E '^(SESSION_SECRET|DEFAULT_EMAIL|DEFAULT_PASSWORD)=' ~/homelab/productividad/.env
# SESSION_SECRET=...
# DEFAULT_EMAIL=operador@homelab.lan
# DEFAULT_PASSWORD=...

# 4. Asegurar permisos restrictivos del .env
chmod 0600 ~/homelab/productividad/.env

# 5. Limpiar las variables de la sesión
unset session_secret admin_pass
```

> **Custodia inmediata**: añadir las dos entradas a Vaultwarden **antes** de seguir adelante. La pérdida de `SESSION_SECRET` invalida sesiones JWT activas (todos los usuarios tendrán que volver a hacer login una vez); las recetas y la BD están a salvo. Custodia separada del repo:
>
> - `Homelab — Mealie secrets`: `SESSION_SECRET`.
> - `Homelab — Mealie bootstrap`: `DEFAULT_EMAIL` + `DEFAULT_PASSWORD` (la del primer arranque, que dejará de ser canon tras cambiar la del operador en runtime).

> **Por qué `tr -d '/+='`**: igual razón que en los documentos previos del _stack_ — `openssl rand -base64` puede emitir `/`, `+` o `=`; molestos al copiar/pegar y problemáticos si algún cliente parsea los valores como _URL_ sin escapar.

> **No commitear `.env` jamás**. El `.gitignore` del _stack_ ya lo excluye explícitamente.

---

## Modificar `~/homelab/productividad/docker-compose.yml`

El _docker-compose.yml_ de este _stack_ ya existe con nueve servicios (`vaultwarden`, `bookstack`, `bookstack-db`, `linkding`, `paperless`, `paperless-db`, `paperless-redis`, `paperless-gotenberg`, `paperless-tika`). **Editarlo, no recrearlo**: añadir el servicio `mealie`, dejando intactos los nueve bloques previos.

El nuevo servicio se añade al final de la sección `services:`, justo antes de la sección `networks:`:

```yaml
  # ===========================================================================
  # Mealie — gestor de recetas (FastAPI + SQLite).
  # Único contenedor. Sólo en la red 'homelab' (Caddy lo alcanza por DNS).
  # NO se engancha a productividad-internal (no comparte BD con nadie).
  # ===========================================================================
  mealie:
    image: ghcr.io/mealie-recipes/mealie:${MEALIE_IMAGE_TAG}
    container_name: mealie
    hostname: mealie
    restart: unless-stopped
    environment:
      TZ: ${TZ}
      PUID: ${PUID}
      PGID: ${PGID}

      # --- Endpoint y reverse proxy ---
      BASE_URL: ${BASE_URL}
      API_PORT: ${API_PORT}

      # --- Bootstrap del superuser (idempotente: ignorado si ya existe) ---
      DEFAULT_EMAIL: ${DEFAULT_EMAIL}
      DEFAULT_PASSWORD: ${DEFAULT_PASSWORD}
      DEFAULT_GROUP: ${DEFAULT_GROUP}
      DEFAULT_HOUSEHOLD: ${DEFAULT_HOUSEHOLD}

      # --- Política de registro ---
      ALLOW_SIGNUP: ${ALLOW_SIGNUP}

      # --- Base de datos ---
      DB_ENGINE: ${DB_ENGINE}

      # --- Sesión / JWT ---
      TOKEN_TIME: ${TOKEN_TIME}
      SESSION_SECRET: ${SESSION_SECRET}

      # --- Login y rate limiting ---
      ALLOW_PASSWORD_LOGIN: ${ALLOW_PASSWORD_LOGIN}
      SECURITY_MAX_LOGIN_ATTEMPTS: ${SECURITY_MAX_LOGIN_ATTEMPTS}
      SECURITY_USER_LOCKOUT_TIME: ${SECURITY_USER_LOCKOUT_TIME}

      # --- Log ---
      LOG_LEVEL: ${LOG_LEVEL}

      # --- SMTP (opcional, descomentar cuando se configure) ---
      # SMTP_HOST: ${SMTP_HOST}
      # SMTP_PORT: ${SMTP_PORT}
      # SMTP_FROM_NAME: ${SMTP_FROM_NAME}
      # SMTP_FROM_EMAIL: ${SMTP_FROM_EMAIL}
      # SMTP_AUTH_STRATEGY: ${SMTP_AUTH_STRATEGY}
      # SMTP_USER: ${SMTP_USER}
      # SMTP_PASSWORD: ${SMTP_PASSWORD}

      # --- OIDC (opcional, descomentar cuando se configure) ---
      # OIDC_AUTH_ENABLED: ${OIDC_AUTH_ENABLED}
      # OIDC_PROVIDER_NAME: ${OIDC_PROVIDER_NAME}
      # OIDC_CONFIGURATION_URL: ${OIDC_CONFIGURATION_URL}
      # OIDC_CLIENT_ID: ${OIDC_CLIENT_ID}
      # OIDC_CLIENT_SECRET: ${OIDC_CLIENT_SECRET}
      # OIDC_AUTO_REDIRECT: ${OIDC_AUTO_REDIRECT}
      # OIDC_USER_CLAIM: ${OIDC_USER_CLAIM}
      # OIDC_GROUPS_CLAIM: ${OIDC_GROUPS_CLAIM}
      # OIDC_ADMIN_GROUP: ${OIDC_ADMIN_GROUP}
      # OIDC_USER_GROUP: ${OIDC_USER_GROUP}
    volumes:
      - /mnt/hd2t/services/mealie/data:/app/data
    networks:
      homelab:
        aliases:
          - mealie         # Caddy resuelve 'mealie:9000' por este alias
    labels:
      homelab.stack: "productividad"
      homelab.backup: "true"      # /mnt/hd2t/services/mealie/data (vía .backup SQLite + raw)
      # Opt-in: semver semi-estricto, patches sin migraciones rompedoras.
      com.centurylinklabs.watchtower.enable: "true"
    healthcheck:
      # /api/app/about devuelve un JSON con la versión cuando la app está
      # sirviendo y la BD responde. Endpoint público estable desde Mealie 1.x.
      test:
        - CMD-SHELL
        - "wget -qO- http://localhost:9000/api/app/about >/dev/null"
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 60s   # primer arranque: alembic upgrade head + bootstrap admin ~30s
```

> **Importante** — `mealie` se añade **dentro** del bloque `services:` ya existente, NO sustituye nada. Validar después con `docker compose config | grep -E '^\s+(vaultwarden|bookstack|bookstack-db|linkding|paperless|paperless-db|paperless-redis|paperless-gotenberg|paperless-tika|mealie):'` que los diez siguen estando.

Notas de diseño:

- **Sólo en `homelab`**, no en `productividad-internal`. La BD vive dentro del propio contenedor (SQLite en el bind mount); no hay nada que aislar entre contenedores. Mealie **no se beneficia** de la red privada del _stack_, igual que Linkding y Vaultwarden.
- **Sin `ports:`**. Caddy alcanza Mealie por DNS interno (`mealie:9000`). Si el operador, durante troubleshooting, necesita acceder sin pasar por Caddy: `docker exec -it mealie wget -qO- http://localhost:9000/api/app/about`.
- **`start_period: 60s`**: Mealie arranca relativamente rápido. El primer arranque ejecuta `alembic upgrade head` (~10 migraciones), bootstrappea el superuser y el grupo/household por defecto, y monta el cache del frontend. 60 s da margen sobrado en una Pi 5; en arranques posteriores, `(healthy)` llega en <15 s.
- **Watchtower opt-in**: razones explicadas en **Decisiones de diseño** → _Imagen y tag_.
- **Sin `depends_on`**: Mealie es un único contenedor sin dependencias internas al _stack_. Vaultwarden, Bookstack, Linkding y Paperless viven en paralelo sin que Mealie necesite saber de ellos.
- **`wget` en el _healthcheck_**: la imagen base de Mealie usa `python:3.12-slim-bookworm`, que **no trae `curl`** (sí `wget`). Esto coincide con Linkding.
- **`PUID`/`PGID` declarados pero no aplicados internamente**: Mealie 2.x los lee y, si están definidos, intenta `chown` del bind mount al iniciar, pero el proceso sigue corriendo como UID 911. Pasarlos no rompe nada y deja la puerta abierta a un futuro upgrade del upstream donde sí se respeten.

---

## Despliegue

### Primer arranque

```bash
cd ~/homelab/productividad
# Validar la sintaxis sin levantar nada (recomendado tras editar el compose).
docker compose --env-file ../.env --env-file .env config | \
    grep -E '^\s+(vaultwarden|bookstack|bookstack-db|linkding|paperless|paperless-db|paperless-redis|paperless-gotenberg|paperless-tika|mealie):'
# vaultwarden:
# bookstack-db:
# bookstack:
# linkding:
# paperless-db:
# paperless-redis:
# paperless-gotenberg:
# paperless-tika:
# paperless:
# mealie:

# Levantar SÓLO el servicio nuevo (los otros nueve ya están corriendo y healthy):
docker compose --env-file ../.env --env-file .env up -d mealie
```

O, equivalente, con el _Makefile_ (ver `docs/02-docker/02-estructura-compose.md`):

```bash
cd ~/homelab
make up STACK=productividad
# El make up no es selectivo: lleva el stack completo al estado deseado.
# Como los nueve previos ya están up y nada del compose los cambia,
# Compose los deja tal cual y sólo arranca mealie.
```

Vigilar el primer arranque (~30 s):

```bash
docker compose -f ~/homelab/productividad/docker-compose.yml logs -f mealie
# mealie | INFO  Mealie starting...
# mealie | INFO  Running database migrations...
# mealie | INFO  alembic.runtime.migration  Running upgrade  -> abc123, initial
# mealie | INFO  alembic.runtime.migration  Running upgrade abc123 -> def456, ...
# mealie | INFO  Database is up to date.
# mealie | INFO  Bootstrap: creating default group 'Casa' and household 'Familia'
# mealie | INFO  Bootstrap: creating admin user 'operador@homelab.lan'
# mealie | INFO  Application startup complete.
# mealie | INFO  Uvicorn running on http://0.0.0.0:9000
```

Verificar que el contenedor está `(healthy)`:

```bash
docker compose -f ~/homelab/productividad/docker-compose.yml ps
# NAME                  STATUS                   PORTS
# vaultwarden           Up X minutes (healthy)
# bookstack-db          Up X minutes (healthy)
# bookstack             Up X minutes (healthy)
# linkding              Up X minutes (healthy)
# paperless-db          Up X minutes (healthy)
# paperless-redis       Up X minutes (healthy)
# paperless-gotenberg   Up X minutes (healthy)
# paperless-tika        Up X minutes (healthy)
# paperless             Up X minutes (healthy)
# mealie                Up X seconds (healthy)
```

> El `(healthy)` lo otorga el _healthcheck_ de `/api/app/about`. Si tras 2 minutos sigue `starting`/`unhealthy`, ir a **Troubleshooting** → primer arranque.

Confirmar que el SQLite se creó bien y que el bootstrap pobló las tablas iniciales:

```bash
ls -la /mnt/hd2t/services/mealie/data/
# -rw-r--r-- 1 911 911 245760 Apr 25 12:00 mealie.db
# -rw-r--r-- 1 911 911  32768 Apr 25 12:00 mealie.db-shm
# -rw-r--r-- 1 911 911      0 Apr 25 12:00 mealie.db-wal
# drwxr-xr-x 2 911 911   4096 Apr 25 12:00 recipes/
# drwxr-xr-x 2 911 911   4096 Apr 25 12:00 backups/
# -rw-r--r-- 1 911 911   2048 Apr 25 12:00 mealie.log
```

(Los UID/GID `911:911` son `abc:abc` dentro del contenedor; en el host aparecen como `911:911` sin nombre porque ese UID no está mapeado a un usuario del host. **Es lo esperado**.)

Y confirmar que el superuser fue creado:

```bash
docker exec mealie wget -qO- http://localhost:9000/api/app/about
# {"version":"2.8.0","production":true,"demoStatus":false,...}

# La consulta directa a SQLite (requiere el binario del contenedor):
docker exec mealie /app/venv/bin/python -c "
from mealie.db.db_setup import session_context
from mealie.db.models.users.users import User
with session_context() as db:
    print('users:', [(u.email, u.admin) for u in db.query(User).all()])
"
# users: [('operador@homelab.lan', True)]
```

### Caddy: bloque `mealie.lan`

Editar `~/homelab/red/Caddyfile` y añadir el bloque:

```caddy
mealie.lan {
    tls internal
    import security-headers
    import logging

    # Subidas de fotos de receta. Mealie acepta JPEG/PNG/WEBP por defecto.
    # 50 MB es generoso para fotos de cocina (rara vez >5 MB tras compresión).
    request_body {
        max_size 50MB
    }

    # Pasar a Mealie tal cual. Caddy reescribe Host por defecto, lo que
    # combinado con BASE_URL=https://mealie.lan del .env, permite a Mealie
    # construir URLs https:// correctas (share links, OIDC redirects).
    reverse_proxy mealie:9000 {
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
curl -k --resolve mealie.lan:443:192.168.1.3 https://mealie.lan/api/app/about
# {"version":"2.8.0","production":true,...}

# Y el endpoint de la web (200):
curl -k --resolve mealie.lan:443:192.168.1.3 -o /dev/null -s -w "%{http_code}\n" \
    https://mealie.lan/
# 200
```

Y desde el navegador: `https://mealie.lan/` → pantalla de login con candado verde y un formulario que pide email + password.

---

## Configuración tras primer arranque

### 1. Login y cambio de password

El bootstrap creó el usuario `operador@homelab.lan` con la password de `DEFAULT_PASSWORD`. **Antes de cualquier otra cosa**:

1. `Log in` con `operador@homelab.lan` / la password del `.env`.
2. Click en el avatar (esquina superior derecha) → `User Profile` → `Change password`.
3. Generar una password fuerte (≥ 16 chars) en Vaultwarden, anotarla _antes_ de pegarla. Confirmar.
4. Logout y volver a hacer login con la nueva password. Verificar que se entra sin pedir reset.
5. Actualizar la nota "Homelab — Mealie bootstrap" en Vaultwarden con la **nueva** password (la del runtime), dejando como histórico la del bootstrap.

> **No vaciar `DEFAULT_PASSWORD` del `.env`** automáticamente: dejarlo permite, en un escenario de DR, recrear el superuser si por error se borrasen todos. Si el operador prefiere que el `.env` no contenga la password vieja (limpieza), vaciar `DEFAULT_PASSWORD=` y hacer `up -d mealie` — el _entrypoint_ no recrea ni borra al usuario existente; sólo dejaría de tener fallback automático.

### 2. Activar 2FA TOTP (recomendado)

Mealie integra TOTP nativo desde 2.x:

1. `User Profile → Two-Factor Authentication → Enable`.
2. Escanear el QR con Aegis / Authy / 1Password / `oath-tool`.
3. Confirmar con un código TOTP válido.
4. Mealie muestra los **recovery codes** (8-10 códigos de un solo uso). **Imprescindible**: copiarlos a la nota "Homelab — Mealie secrets" en Vaultwarden. Si el dispositivo TOTP se pierde y los recovery codes también, el único camino es resetear el MFA del usuario desde el _shell_ de Mealie (descrito en **Troubleshooting**).

> **Por qué activar MFA antes de generar el API token**: el token de API **no respeta** MFA — un atacante con el token bypassea TOTP. MFA blinda el _login web_ y la creación de **nuevos** tokens. El token ya creado, si se filtra, sigue siendo válido hasta que se revoque. Por eso (a) MFA primero, (b) token después con custodia estricta en Vaultwarden.

### 3. Generar el token de API para PWAs y _bookmarklets_

Los _clients_ que consumen la API (n8n, Home Assistant, scripts caseros, _bookmarklets_ de _scrape_ desde el navegador móvil) autentican con un token por usuario:

1. `User Profile → API Tokens → Create New Token`.
2. Mealie pide un nombre (ej. "iPhone-share", "n8n-integration") y muestra el token JWT (largo, ~200 chars). **Copiarlo en cuanto aparezca** — Mealie no lo vuelve a mostrar.
3. **Copiarlo a Vaultwarden** (nota "Homelab — Mealie API token") — si se pierde, hay que revocarlo y generar uno nuevo (operación reversible pero molesta porque rompe ese cliente concreto).

> **Múltiples tokens por usuario**: a diferencia de Linkding (un único token por usuario), Mealie permite generar varios tokens (uno por dispositivo/uso). Recomendable mantener uno por dispositivo: "iPhone-share", "Android-bookmarklet", "n8n-integration", "ha-shopping-list", para revocar selectivamente si uno se filtra.

### 4. Instalar la PWA en el móvil

Mealie 2.x está empaquetado como **PWA** (Progressive Web App). En Android (Chrome/Firefox) e iOS (Safari):

1. Visitar `https://mealie.lan/` desde el móvil (asegúrate de que la CA local del homelab está importada y de confianza, ver `docs/03-red/04-caddy.md`).
2. **Android Chrome**: menú de tres puntos → `Add to home screen`. Confirmar. La PWA aparece como icono de Mealie en el _launcher_ y abre _full screen_ sin barra del navegador.
3. **Android Firefox**: menú → `Install`. Mismo resultado.
4. **iOS Safari**: botón de _share_ → `Add to Home Screen`.
5. La PWA mantiene la sesión (cookie + JWT) entre aperturas. Cuando expire (`TOKEN_TIME=48` horas), pide login de nuevo.

> **Para "compartir" recetas desde el navegador móvil al recetario**: Mealie expone un endpoint `/recipes/create-from-url` que acepta una URL y la _scrapea_. La forma cómoda en Android:
>
> 1. **Bookmarklet** (Firefox móvil): un _bookmark_ con JavaScript que llama a la API con el token. Hay ejemplos en `https://github.com/mealie-recipes/mealie/discussions`. Tras instalarlo, "Compartir → Bookmarklet de Mealie" agrega la receta de la página actual.
> 2. **Share intent** (Android nativo): instalar [Mealie Mobile Companion](https://github.com/atrope/mealie-app) (no oficial pero comunitario), introducir URL + token, y aparece como destino en el _share sheet_. **NB**: a diferencia de Paperless Mobile (mantenida por un dev), las apps móviles para Mealie son comunitarias y la mantención varía. Para uso sencillo, el _bookmarklet_ funciona perfectamente y no añade dependencias.

> **Si el móvil no confía en la CA local del homelab**, la PWA falla con `Network error` o `Certificate error`. Importar la CA local en el móvil (ver `docs/03-red/04-caddy.md`). En iOS hay que **además** instalar la CA en `Settings → General → About → Certificate Trust Settings` y activarla manualmente.

### 5. Estructura inicial de categorías, tags y _meal types_

Mealie modela cada receta con **categorías** (ortogonales, como _correspondents_ en Paperless), **tags** (libres, como _tags_), y **meal types** (`Breakfast`, `Lunch`, `Dinner`, `Snack`, `Dessert`, `Side`, `Drink`). El bootstrap crea las _meal types_ por defecto; **categorías y tags** quedan vacías y se pueblan según se importen recetas.

Esquema mínimo recomendado para empezar:

**Categorías** (`Settings → Categories → Create`):

| Categoría        | Comentario                                                    |
|------------------|---------------------------------------------------------------|
| `Pasta`          | Cualquier plato basado en pasta                               |
| `Legumbres`      | Lentejas, garbanzos, alubias, fabada, ...                     |
| `Carne`          | Platos cuyo protagonista es la carne                          |
| `Pescado`        | Idem con pescado/marisco                                      |
| `Vegetarianas`   | Sin carne ni pescado                                          |
| `Postres`        | Tartas, helados, flanes, ...                                  |
| `Repostería`     | Galletas, bizcochos, panes dulces                             |
| `Sopas y cremas` | Caldos, gazpachos, ajoblancos, ...                            |
| `Internacional`  | Curry, ramen, tacos, pad thai, ...                            |

**Tags** (`Settings → Tags → Create`):

| Tag             | Comentario                                                  |
|-----------------|-------------------------------------------------------------|
| `rápido`        | <30 min de tiempo total                                     |
| `fin-de-semana` | Recetas largas, para cuando hay tiempo                      |
| `niños`         | Aprobado por los niños de la casa                           |
| `bajo-en-sal`   | Para los miembros con hipertensión                          |
| `sin-gluten`    | Para celíacos / intolerantes                                |
| `congelar`      | Recetas que se pueden hacer en _batch_ y congelar           |
| `imprescindible`| Las clásicas familiares que no fallan nunca                 |

> **No hace falta pre-crear todo**: Mealie permite crear categorías y tags _on-the-fly_ desde el formulario de receta. La idea de pre-crear el esqueleto es tener algo ya listo para arrastrar al importar las primeras recetas y no perderse en clasificar todo a posteriori.

### 6. Importar las primeras recetas (test del scraper)

El scraper es la _killer feature_. Probar con una URL conocida:

1. `Recipes → Add → Import from URL`.
2. Pegar una URL de un blog popular (ej. `https://www.directoalpaladar.com/...` o cualquier blog de cocina con buena estructura). **Importante**: la URL debe ser pública (no requerir login) y Mealie debe poder alcanzarla — si el blog está detrás de Cloudflare con JS Challenge, el scrape puede fallar (workaround: copiar/pegar manualmente).
3. En 3-5 s, Mealie devuelve la receta con título, ingredientes (lista parseada), instrucciones (paso a paso si el blog las tiene como JSON-LD), tiempo, raciones, y la foto principal.
4. Editar lo que haga falta (los blogs varían en calidad de los metadatos), asignar categoría/tags, guardar.
5. **Verificar** que la receta aparece en `https://mealie.lan/g/Casa/r/<slug>`. Esa URL es _pública dentro del household_ — un miembro del household puede consultarla sin login en el panel; un externo, no.

> **Si el scrape falla**: Mealie muestra un mensaje genérico y queda la receta vacía. Causas: (a) el blog no emite `schema.org/Recipe` (raro hoy en día), (b) Cloudflare/Akamai bloquea el _user agent_ de Mealie, (c) timeout. Workaround: importar manualmente con `Recipes → Add → Manual Entry` y pegar texto.

### 7. (Opcional) Importar desde Paprika / Nextcloud Cookbook / Tandoor

Mealie acepta exports de los principales gestores de recetas:

- **Paprika** (`.paprikarecipes`): `Settings → Migrations → Paprika`. Sube el fichero, Mealie importa todo (a veces las fotos se quedan grandes; comprimir desde la UI luego con `Settings → Maintenance → Optimize Images`).
- **Nextcloud Cookbook** (carpeta con `recipe.json` por receta): `Settings → Migrations → Nextcloud`. Sube un ZIP de la carpeta entera.
- **Tandoor**: export desde Tandoor (`Settings → Export → Default Format`), importar en Mealie con `Settings → Migrations → Tandoor`.
- **Genérico JSON / Markdown**: importar uno a uno con `Recipes → Add → Manual Entry → Paste from clipboard` (Mealie autodetecta varios formatos: JSON crudo, Markdown con front-matter, texto libre con heurísticas).

### 8. Activar el bloque del _hook_ de Borgmatic

`docs/07-backups/03-backup-docker-volumes.md` dejó preparada la línea comentada (la del SQLite, no la de Postgres):

```bash
# --- Mealie (PostgreSQL o SQLite) — docs/11-productividad/05-mealie.md
# dump_postgres mealie mealie-db "$HOMELAB/productividad/.env"
# o, si quedó en SQLite por simplicidad:
# dump_sqlite mealie mealie /app/data/mealie.db
```

Descomentar **sólo** la línea de SQLite (la elección hecha en este documento):

```bash
# Localizar el script del hook
hook=~/homelab/backups/borgmatic/hooks/dump-databases.sh
ls -la "$hook"

# Descomentar la línea (o usar el editor interactivo).
# Variante con sed:
sed -i 's|^# dump_sqlite mealie mealie /app/data/mealie\.db$|dump_sqlite mealie mealie /app/data/mealie.db|' "$hook"

# Confirmar que la línea de Postgres SIGUE comentada (no aplica a este despliegue):
grep -E '^[# ]*dump_postgres mealie' "$hook"
# # dump_postgres mealie mealie-db "$HOMELAB/productividad/.env"

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

ls -la /mnt/hd2t/backups/dumps/ | grep mealie
# mealie-2026-04-26.sqlite.gz   ~80 KB para una BD recién creada con un par de recetas
```

Verificar que el dump es válido:

```bash
gunzip -c /mnt/hd2t/backups/dumps/mealie-$(date +%F).sqlite.gz | file -
# /dev/stdin: SQLite 3.x database, ...

# Y que las tablas esperadas existen:
gunzip -c /mnt/hd2t/backups/dumps/mealie-$(date +%F).sqlite.gz > /tmp/mealie.sqlite
sqlite3 /tmp/mealie.sqlite ".tables" | tr ' ' '\n' | sort -u
# alembic_version
# api_tokens
# categories
# group_meal_plan
# group_shopping_list
# groups
# households
# recipes
# recipes_ingredients
# recipes_instructions
# recipes_tags
# tags
# users
# ... (varias tablas más)
rm /tmp/mealie.sqlite
```

> **Por qué `.backup` y no `cp`**: igual razón que en Vaultwarden y Linkding — `cp mealie.db` durante una escritura activa puede coger un fichero a medio _commit_ (el WAL aún no fusionado). El helper `dump_sqlite` usa la _Online Backup API_ de SQLite, que produce un fichero binario consistente con el último _commit_ sin bloquear a Mealie.

### 9. Asegurar que el directorio `data/` entra como _source_directory_ de Borgmatic

El dump SQLite cubre la BD, pero las **fotos de receta** viven en `/mnt/hd2t/services/mealie/data/recipes/` y deben respaldarse aparte. `docs/07-backups/01-estrategia-backup.md` ya lista a `/mnt/hd2t/services/mealie` como _source_directory_ del set "data". Verificación rápida:

```bash
grep -A2 source_directories ~/homelab/backups/borgmatic/config.d/data.yaml | grep mealie
# - /mnt/hd2t/services/mealie
```

Si no aparece (raro), añadir esa línea bajo `source_directories:` y validar. Y excluir el directorio `data/backups/` (los _exports_ internos de Mealie son redundantes):

```bash
# Editar el config de Borgmatic; sección 'exclude_patterns:' del set "data".
$EDITOR ~/homelab/backups/borgmatic/config.d/data.yaml
# Confirmar / añadir bajo exclude_patterns:
#   - '**/services/mealie/data/backups'
#   - '**/services/mealie/data/mealie.log'
#   - '**/services/mealie/data/mealie.db-wal'    # WAL siempre cambia, ruido en backup
#   - '**/services/mealie/data/mealie.db-shm'

sudo borgmatic config validate
```

> **Por qué dump SQLite _y_ copia raw del directorio `data/`**: el dump (`.sqlite.gz`) es el **canónico para la BD** (consistente, deduplicable, restaurable a cualquier versión de Mealie). La copia raw del directorio `data/recipes/` es lo que permite **restaurar las fotos**, que viven _fuera_ de la BD pero son referenciadas desde ella (cada `recipes_id` tiene un directorio `recipes/<id>/` con `original.jpg`, `thumbnail.jpg`, etc.). Cinturón y tirantes — la BD sin las fotos funciona pero las recetas aparecen sin imagen; las fotos sin la BD son carpetas huérfanas.

### 10. (No aplica) Activar un _jail_ de fail2ban

A diferencia de Vaultwarden (que tiene un _jail_ explícito en `docs/04-seguridad/02-fail2ban.md`), **Mealie no tiene un _jail_ pre-configurado**. Las razones:

- Mealie no expone un endpoint público a internet — vive sólo en LAN + Tailscale, donde el modelo de amenaza de _brute force_ es muy bajo.
- Mealie 2.x tiene **rate limiting interno** (`SECURITY_MAX_LOGIN_ATTEMPTS=5` y `SECURITY_USER_LOCKOUT_TIME=24` horas configurados en el `.env`): tras 5 intentos fallidos, la cuenta queda bloqueada 24 horas. Es suficiente como primera capa.
- El log de Mealie no escribe líneas estructuradas para fallos de login: una autenticación fallida aparece como un `POST /api/auth/token HTTP/1.1 401` en el access log de Uvicorn, pero indistinguible (con la información disponible) de un token JWT caducado. Un filtro `fail2ban` daría falsos positivos.
- Para tener un _jail_ útil habría que añadir un _signal handler_ en FastAPI + un filtro `fail2ban` _ad hoc_. Es factible pero el _ROI_ es bajo en un recetario familiar en LAN.

**Política asumida**: no se configura jail. Si en el futuro Mealie se publicase en internet (cambio de modelo de red), este documento se complementaría con un _jail_ específico, en línea con el patrón Vaultwarden.

---

## Verificación final

Antes de pasar a `docs/11-productividad/06-stirling-pdf.md`, comprobar:

- [ ] `docker compose -f ~/homelab/productividad/docker-compose.yml ps` muestra los **diez** contenedores (`vaultwarden`, `bookstack-db`, `bookstack`, `linkding`, `paperless-db`, `paperless-redis`, `paperless-gotenberg`, `paperless-tika`, `paperless`, `mealie`) en `(healthy)`.
- [ ] `curl -k --resolve mealie.lan:443:192.168.1.3 https://mealie.lan/api/app/about` devuelve un JSON con la versión de Mealie y `production:true`.
- [ ] `https://mealie.lan/` carga la pantalla de login en el navegador con candado verde (CA local importada).
- [ ] El usuario operador puede hacer login con su email + password (ya cambiada desde la del bootstrap).
- [ ] La password actual del operador está almacenada en Vaultwarden en una nota titulada "Homelab — Mealie".
- [ ] El operador tiene MFA TOTP activo en su cuenta y los _recovery codes_ están **anotados en Vaultwarden** y en papel.
- [ ] Al menos **un token de API** está generado y almacenado en Vaultwarden en una nota "Homelab — Mealie API token".
- [ ] La PWA está instalada en al menos un dispositivo móvil del operador y mantiene la sesión sin pedir login en cada apertura.
- [ ] **Test del scraper**: importar una receta cualquiera desde una URL pública. La receta aparece con título, ingredientes y foto en `https://mealie.lan/g/Casa/r/<slug>`.
- [ ] **Test del planificador**: crear un plan semanal con 2-3 recetas, generar la lista de la compra desde el plan. Verificar que los ingredientes se agregan correctamente (cebollas se suman, unidades distintas se mantienen separadas).
- [ ] El _hook_ de Borgmatic genera `dumps/mealie-YYYY-MM-DD.sqlite.gz`. Verificar que el dump es un SQLite válido (`file -` lo identifica) y que contiene las tablas `recipes`, `categories`, `tags`, `users`, `groups`, `households`.
- [ ] `~/homelab/backups/borgmatic/config.d/data.yaml` lista a `/mnt/hd2t/services/mealie` en `source_directories:` y excluye `**/services/mealie/data/backups` en `exclude_patterns:`.
- [ ] `docker network inspect homelab --format '{{range .Containers}}{{.Name}} {{end}}'` lista a `mealie` (entre los demás del homelab); **NO** lista a `mealie` en `productividad-internal`:
  ```bash
  docker network inspect productividad-internal --format '{{range .Containers}}{{.Name}} {{end}}'
  # Debe listar bookstack bookstack-db paperless paperless-db paperless-redis
  # paperless-gotenberg paperless-tika  (mealie NO debe estar).
  ```
- [ ] Permisos del bind mount:
  ```bash
  stat -c '%U:%G' /mnt/hd2t/services/mealie/data
  # 911:911 (UNKNOWN UID/GID — normal, ver Decisiones de diseño).
  ```
- [ ] Tras un `docker compose -f ~/homelab/productividad/docker-compose.yml restart mealie`, la página vuelve a `(healthy)` en <30 s y el operador sigue logueado (la sesión sobrevive porque `SESSION_SECRET` no cambia entre restarts).
- [ ] Tras un `sudo reboot` de la Pi, los diez contenedores vuelven a estar `(healthy)` sin intervención manual y `https://mealie.lan/` responde.
- [ ] `git -C ~/homelab status` muestra como **modificados**: `productividad/docker-compose.yml`, `productividad/.env.example`, `red/Caddyfile`, `backups/borgmatic/hooks/dump-databases.sh`, `backups/borgmatic/config.d/data.yaml`. **No** muestra `productividad/.env` ni nada bajo `/mnt/hd2t/`. _Commit_:

  ```bash
  cd ~/homelab
  git add productividad/docker-compose.yml productividad/.env.example \
          red/Caddyfile backups/borgmatic/hooks/dump-databases.sh \
          backups/borgmatic/config.d/data.yaml
  git commit -m "feat(productividad): add Mealie (SQLite) and activate borgmatic dump hook"
  ```

---

## Backup

| Qué                                       | Dónde                                                                          | Cómo                                                       |
|-------------------------------------------|--------------------------------------------------------------------------------|------------------------------------------------------------|
| `docker-compose.yml`, `.env.example`      | `~/homelab/productividad/`                                                     | git                                                        |
| `mealie` schema + datos                   | SQLite en `/mnt/hd2t/services/mealie/data/mealie.db`                           | **Dump consistente** vía `dump_sqlite` (`sqlite3 .backup`) en el _hook_ de Borgmatic. El fichero binario _raw_ del directorio entra **además** como _source_directory_ del set "data" para preservar también las fotos de receta. |
| `data/recipes/` (fotos)                   | `/mnt/hd2t/services/mealie/data/recipes/`                                      | Borgmatic — copia raw, retención normal del set "data". Cada receta tiene `<id>/original.jpg` + `thumbnail.jpg`. **Categoría B**: pérdida ≡ recetas sin foto (recuperables si se vuelve a importar desde URL, costoso a mano). |
| `data/backups/` (exports internos)        | `/mnt/hd2t/services/mealie/data/backups/`                                      | **Excluido** del backup (regenerable desde la UI a demanda; redundante con el dump SQLite). |
| `data/mealie.log`                         | `/mnt/hd2t/services/mealie/data/mealie.log`                                    | **Excluido** (log _runtime_, ruidoso, sin valor en restauración). |
| `SESSION_SECRET`, `DEFAULT_PASSWORD`      | Notas dentro de Vaultwarden + papel                                            | Custodia humana. NUNCA en git, NUNCA en backups con la misma passphrase que el repo. |
| Token(s) de API del operador              | Nota dentro de Vaultwarden                                                     | Idem.                                                      |
| Recovery codes de MFA                     | Nota dentro de Vaultwarden + papel                                             | Idem.                                                      |

> **Restauración desde backup**:
> 1. Restaurar `/mnt/hd2t/services/mealie/data/` desde Borgmatic (incluye `recipes/` con todas las fotos).
> 2. **Sustituir** el `mealie.db` restaurado por el dump más reciente (el dump es siempre más nuevo y consistente que la copia raw):
>    ```bash
>    docker stop mealie
>    sudo gunzip -c /mnt/hd2t/backups/dumps/mealie-YYYY-MM-DD.sqlite.gz \
>        > /mnt/hd2t/services/mealie/data/mealie.db
>    sudo chown 911:911 /mnt/hd2t/services/mealie/data/mealie.db
>    sudo rm -f /mnt/hd2t/services/mealie/data/mealie.db-{wal,shm}
>    docker start mealie
>    ```
> 3. Verificar login con la cuenta operador y abrir una receta aleatoria: la página debe cargar (la BD se importó) y la foto debe verse (los `recipes/<id>/original.jpg` están en su sitio).

> **Antes de cualquier upgrade _minor_ de Mealie** (2.8 → 2.9 → 2.10):
> 1. `docker compose stop mealie`.
> 2. Backup completo `data/` + dump SQLite (Borgmatic _on-demand_).
> 3. Editar `.env`: `MEALIE_IMAGE_TAG=2.9.0` (leer el _changelog_ upstream).
> 4. `docker compose pull mealie && docker compose up -d mealie`.
> 5. `docker logs -f mealie` — esperar a `alembic.runtime.migration  Running upgrade ... -> ...` y `Application startup complete.` y `(healthy)`.
> 6. `curl -k https://mealie.lan/api/app/about` — confirmar version actualizada.
> 7. Verificación final completa de la sección anterior.
> 8. Si algo va mal: `docker compose down mealie`, restaurar `data/` y dump SQLite, `MEALIE_IMAGE_TAG=2.8.0`, `up -d mealie`.
>
> Los _bumps_ de **patch** (2.8.0 → 2.8.1) los gestiona Watchtower automáticamente; el operador no necesita intervenir, pero **debería revisar el `docker logs mealie` el día siguiente al pull** para confirmar que arrancó bien.

---

## Troubleshooting

### `mealie` arranca y queda en `unhealthy`

El `start_period: 60s` da margen para `alembic upgrade head` + bootstrap. Si tras 2 minutos sigue `starting`/`unhealthy`, mirar los logs:

```bash
docker logs mealie --tail 80
```

Causas frecuentes:

1. **Migraciones fallaron**: aparece como `alembic.util.exc.CommandError: ...`. Causas habituales:
   - Schema previo de otra versión de Mealie incompatible (si el bind mount `data/` estaba sucio). Solución: backup del `mealie.db` actual a otra ruta, borrar `data/`, dejar que se recree limpia, reimportar las recetas desde la copia (vía export/import de Mealie en una instancia _offline_).
   - SQLite corrupto (rara vez; pasa si se hizo un `kill -9` durante una escritura). Solución:
     ```bash
     docker exec -u 911 mealie sqlite3 /app/data/mealie.db "PRAGMA integrity_check;"
     # Debe responder 'ok'. Si no: restaurar desde el dump más reciente (sección Backup).
     ```

2. **`BASE_URL` malformado**: si el `.env` tiene `BASE_URL=mealie.lan` (sin esquema, error común) o `BASE_URL=https://mealie.lan/` (con barra final, otro error común), el frontend se carga pero las URLs absolutas (share links, OIDC redirects) salen mal. Solución: `BASE_URL=https://mealie.lan` (con esquema, sin barra final).

3. **`SESSION_SECRET` vacío o demasiado corto**: FastAPI falla con `ValueError: SESSION_SECRET must be at least 32 chars`. Solución: regenerar siguiendo la sección **Variables de entorno** y reiniciar.

4. **Permisos del bind mount**: si por error se hizo un `chown` antes del primer arranque, el `entrypoint` puede fallar al inicializar. Solución: parar el contenedor, **NO** borrar `data/`, hacer `sudo chown -R 911:911 /mnt/hd2t/services/mealie/data` y reiniciar.

5. **Espacio en `/mnt/hd2t`**: si el disco está lleno, SQLite no puede crear la BD. Verificar con `df -h /mnt/hd2t`.

### `502 Bad Gateway` desde Caddy hacia `mealie`

Caddy responde 502 si no puede alcanzar `mealie:9000` desde la red `homelab`. Probar:

```bash
docker exec caddy wget -qO- http://mealie:9000/api/app/about
# Debe devolver un JSON. Si "Connection refused": Mealie no está sirviendo.

docker exec caddy nslookup mealie
# Debe resolver a una IP del 172.20.10.0/24.
```

Causas:

1. Mealie en `unhealthy` — ver caso anterior.
2. `mealie` no está enganchada a `homelab` (mira con `docker network inspect homelab`). Si no está, revisar la sección `networks:` del compose y `up -d mealie` de nuevo.
3. La red `homelab` está sin `mealie` por un fallo silencioso de Compose. `docker compose down mealie && docker compose up -d mealie` lo recrea.

### El scraper de URLs falla constantemente

Síntomas: el operador pega una URL y Mealie devuelve "Could not parse recipe" o un mensaje vacío.

Causas:

1. **El blog no emite `schema.org/Recipe`**: comprobar manualmente con `curl -A "Mealie/2.8.0" <url> | grep -A1 ld+json | head` — si no hay `application/ld+json` con type Recipe, no hay nada que parsear. Solución: importar la receta a mano o intentar con otro blog del mismo autor que sí tenga estructura.
2. **Cloudflare / DDoS protection**: el blog devuelve HTML de "verificación" en lugar del HTML real. El _user agent_ de Mealie no pasa la verificación. Solución: pegar la URL en el navegador, copiar el HTML resultante, y usar `Recipes → Add → Manual Entry → Paste from clipboard` (Mealie autodetecta JSON-LD pegado).
3. **Timeout**: el blog tarda demasiado en responder. Reintentar; si persiste, el blog está caído o muy lento.
4. **DNS interno**: Mealie hace la petición desde dentro del contenedor, así que necesita resolver el dominio externo. Confirmar:
   ```bash
   docker exec mealie wget -qO- https://www.google.com >/dev/null && echo "OK red"
   # OK red
   ```
   Si falla, hay un problema con la salida a internet desde la red Docker. Verificar Pi-hole / DNS upstream.

### Resetear la password del usuario desde el contenedor

Si se perdió la password del operador y SMTP no está configurado (no hay forma de hacer `Forgot password` desde el formulario):

```bash
docker exec -it mealie /app/venv/bin/python -m mealie.app.cli change-password \
    --email operador@homelab.lan
# Enter new password:
# Repeat new password:
# Password updated successfully for operador@homelab.lan
```

> Esto sólo es seguro si **el contenedor sigue arrancado**. Si Mealie está caído, levantar primero `docker start mealie`.

> **Alternativa de DR**: si por algún motivo `change-password` no funciona, basta con borrar todos los superusers desde el _shell_ de Python y reiniciar el contenedor; el _entrypoint_ recreará al operador con `DEFAULT_PASSWORD`. La nota fósil de Vaultwarden ("Homelab — Mealie bootstrap") es exactamente para este caso:
> ```bash
> docker exec -it mealie /app/venv/bin/python <<'PY'
> from mealie.db.db_setup import session_context
> from mealie.db.models.users.users import User
> with session_context() as db:
>     for u in db.query(User).filter(User.admin == True).all():
>         db.delete(u)
>     db.commit()
> print("All superusers deleted")
> PY
> docker restart mealie
> # Esperar a que el bootstrap recree al operador con DEFAULT_PASSWORD del .env.
> ```

### Reset de MFA (si el operador perdió el TOTP y los recovery codes)

```bash
docker exec -it mealie /app/venv/bin/python <<'PY'
from mealie.db.db_setup import session_context
from mealie.db.models.users.users import User
with session_context() as db:
    u = db.query(User).filter(User.email == 'operador@homelab.lan').first()
    if u:
        u.auth_method = "Mealie"        # de "TOTP" o similar
        u.totp_secret = None
        u.recovery_codes = []
        db.commit()
        print(f"MFA cleared for {u.email}")
PY
```

El usuario podrá hacer login sólo con email + password (sin MFA) hasta que vuelva a configurarlo desde `User Profile → Two-Factor Authentication`.

### El dump de Borgmatic falla con `database is locked`

```
[dump] mealie: FAIL
Error: database is locked
```

Causa: el helper `dump_sqlite` ejecuta `sqlite3 .backup` _dentro_ del contenedor mientras Mealie (FastAPI/Uvicorn) tiene la BD abierta en modo WAL. Esto debería funcionar siempre (la _Online Backup API_ de SQLite está diseñada exactamente para eso), pero hay un caso patológico: si Mealie está procesando un _import_ masivo de Paprika con miles de recetas, la transacción puede ser tan larga que SQLite considere la BD bloqueada.

Soluciones:

**Opción A — reintentar más tarde (recomendada)**: el _hook_ corre a las 03:30; si falla, Borgmatic lo reintenta el día siguiente. Los _imports_ masivos no son frecuentes.

**Opción B — _cold copy_** (si el problema persiste): cambiar a `dump_sqlite_cold` en el _hook_ para Mealie:
```bash
# En ~/homelab/backups/borgmatic/hooks/dump-databases.sh:
# dump_sqlite mealie mealie /app/data/mealie.db
dump_sqlite_cold mealie mealie /mnt/hd2t/services/mealie/data/mealie.db
```
Esto para el contenedor durante ~3 s para hacer el dump. Aceptable para un recetario familiar; **inaceptable** sólo si hay que mantener Mealie 100% disponible (no es el caso).

### Las fotos de receta no se ven (después de un upgrade o restore)

Síntomas: las recetas existen, pero en lugar de la foto se ve un placeholder genérico de "imagen no disponible".

Causas:

1. **Permisos del directorio `recipes/`**: tras una restauración, el ownership puede estar desalineado. Solución:
   ```bash
   sudo chown -R 911:911 /mnt/hd2t/services/mealie/data/recipes
   docker restart mealie
   ```

2. **Ficheros `original.jpg` / `thumbnail.jpg` ausentes**: las fotos no se respaldaron por un error en el `source_directory` de Borgmatic. Verificar:
   ```bash
   ls /mnt/hd2t/services/mealie/data/recipes/ | head
   # Debe haber subdirectorios <UUID>/ con original.jpg dentro de cada uno.
   ```
   Si los UUIDs están pero los `original.jpg` faltan, regenerar thumbnails desde la UI: `Settings → Maintenance → Regenerate Thumbnails`. Si los UUIDs en sí faltan, **recuperar desde el último backup** que sí los incluyera, o aceptar la pérdida e ir reimportando recetas.

3. **Cache del navegador**: tras un restore, el navegador puede mostrar el placeholder antiguo. `Ctrl+Shift+R` para forzar recarga.

### Mover el _stack_ a otra Pi (DR scenario)

1. En la Pi nueva: instalar Pi OS, Docker, montar hd2t, restaurar `~/homelab/` (git clone + `.env` desde la copia papel/Vaultwarden).
2. Restaurar `/mnt/hd2t/services/mealie/data/` desde Borgmatic.
3. Sustituir `data/mealie.db` por el dump más reciente (ver **Backup → Restauración**).
4. Levantar el _stack_ con `make up STACK=productividad`.
5. Esperar a `mealie (healthy)`, después hacer login con la password del operador (custodiada en Vaultwarden) y verificar que las recetas y fotos están en su sitio.

> **Crítico**: el `SESSION_SECRET` en el `.env` restaurado **debe ser el mismo** que el que se usó cuando se generaron los JWT de los tokens de API. Si el `.env` se perdió y sólo hay backup del `data/`, los _tokens API_ ya generados quedan invalidados y el operador tendrá que generarlos de nuevo desde la UI; las recetas y los _logins_ por email/password no se ven afectados.

---

## SMTP opcional

Mealie funciona sin SMTP, pero algunas funcionalidades quedan limitadas:

- **Recuperación de password** del usuario olvidadizo: sin SMTP, el _link de reset_ no se envía y la única ruta es `change-password` desde dentro del contenedor (descrito en **Troubleshooting**).
- **Invitaciones a household por email**: sin SMTP, las invitaciones se entregan por copy-paste del token (la UI lo muestra), no por correo automático. Para uso familiar es perfectamente válido (el operador comparte el token por Signal, WhatsApp o lo dicta).
- **Notificaciones de _shopping list_ / _meal plan reminder_**: si en el futuro se activa la feature opcional "recordatorio diario de la lista de la compra", sin SMTP queda muda.

Para activar, descomentar el bloque correspondiente del `~/homelab/productividad/.env`:

```bash
SMTP_HOST=smtp.tu-proveedor.com
SMTP_PORT=587
SMTP_FROM_NAME=Mealie
SMTP_FROM_EMAIL=mealie@tu-dominio.example
SMTP_AUTH_STRATEGY=TLS
SMTP_USER=tu-cuenta-smtp
SMTP_PASSWORD=tu-password-de-aplicacion
```

…y descomentar el bloque correspondiente del `docker-compose.yml`. Reiniciar:

```bash
docker compose -f ~/homelab/productividad/docker-compose.yml up -d mealie
```

Probar enviando una invitación a un email cualquiera desde `Households → Invitations → Invite member` y comprobar que llega.

> **`SMTP_AUTH_STRATEGY`**: valores válidos `TLS` (STARTTLS sobre 587), `SSL` (TLS implícito sobre 465), `NONE` (sin TLS — sólo para relays internos como Postfix _null client_ en localhost; nunca contra un proveedor cloud).

---

## Migrar a OIDC con Authelia (opcional, futuro)

Mealie soporta **OIDC nativo desde 1.10** vía las variables `OIDC_*`. La integración con Authelia (`docs/04-seguridad/01-authelia.md`) consiste en:

1. **Registrar un cliente OIDC en Authelia**: añadir al `configuration.yml` de Authelia un nuevo `identity_providers.oidc.clients[]` con:
   - `id: mealie`
   - `secret: $argon2id$<hash>` (generado con `authelia crypto hash generate argon2`)
   - `redirect_uris: [https://mealie.lan/login]`
   - `scopes: [openid, profile, email, groups]`
   - `userinfo_signing_algorithm: none`
2. **(Opcional) Crear los _groups_ en Authelia** que Mealie va a mapear a roles:
   ```yaml
   # En Authelia users_database.yml o el LDAP backend:
   users:
     operador:
       groups:
         - mealie-admin
   ```
3. **Configurar Mealie** añadiendo al `~/homelab/productividad/.env`:
   ```bash
   OIDC_AUTH_ENABLED=true
   OIDC_PROVIDER_NAME=Authelia
   OIDC_CONFIGURATION_URL=https://auth.lan/.well-known/openid-configuration
   OIDC_CLIENT_ID=mealie
   OIDC_CLIENT_SECRET=<el secret en plano, NO el hash>
   OIDC_AUTO_REDIRECT=false              # true = redirect automático a Authelia (sin pantalla de login local)
   OIDC_USER_CLAIM=preferred_username
   OIDC_GROUPS_CLAIM=groups
   OIDC_ADMIN_GROUP=mealie-admin
   OIDC_USER_GROUP=mealie-user
   ```
4. Descomentar el bloque OIDC en el `docker-compose.yml`.
5. Reiniciar Mealie: `docker compose up -d mealie`.
6. Probar el login desde un navegador limpio: `https://mealie.lan/login` muestra ahora un botón "Sign in with Authelia"; al pulsar, redirige a `https://auth.lan/?rd=...`, el operador hace su login + 2FA en Authelia, vuelve a Mealie y entra ya autenticado.

**No** se aplica en este documento por las mismas razones que en Linkding y Paperless:

- El operador único del homelab (y posiblemente la familia) no se beneficia mucho del SSO: ya hay 2FA TOTP nativo en Mealie, y el _login_ con email + password ya está unificado en Vaultwarden.
- OIDC añade una **dependencia operativa**: si Authelia se cae, Mealie queda inaccesible aunque la propia app esté `(healthy)`. La opción nativa (email + password) sigue funcionando sin cadenas de dependencia.
- Mealie **mantiene los usuarios locales en paralelo** a los OIDC (no rompe nada). La migración es **incremental** (activar OIDC manteniendo `ALLOW_PASSWORD_LOGIN=true` en paralelo, migrar el operador, y al final apagar el local con `ALLOW_PASSWORD_LOGIN=false`).

> **Atención al token de API**: el _token_ se asocia al **usuario interno de Mealie**, no al _claim_ OIDC. Si tras migrar a OIDC el email cambia (ej. de `operador@homelab.lan` a `operador@tu-dominio.example` porque el _claim_ `email` de Authelia tiene esa forma), Mealie crea un usuario **nuevo** en su BD interna; el token del usuario antiguo deja de funcionar y los _bookmarklets_/PWAs necesitan reconfigurarse con un token nuevo del usuario OIDC.

---

## Migrar a PostgreSQL (opcional, futuro)

Si en el futuro la familia crece, las recetas pasan de centenares a miles, o hay concurrencia de escritura significativa (varios miembros editando simultáneamente desde móviles distintos), la migración a PostgreSQL es trivial:

1. **Backup completo** del estado actual:
   ```bash
   docker exec mealie /app/venv/bin/python -m mealie.app.cli export --output /app/data/backups/pre-postgres.zip
   sudo cp /mnt/hd2t/services/mealie/data/backups/pre-postgres.zip ~/mealie-pre-postgres.zip
   ```
2. **Añadir un servicio `mealie-db`** al `docker-compose.yml` (Postgres 16 sobre `productividad-internal`, mismo patrón que `paperless-db`):
   ```yaml
   mealie-db:
     image: postgres:16-bookworm
     container_name: mealie-db
     hostname: mealie-db
     restart: unless-stopped
     environment:
       TZ: ${TZ}
       POSTGRES_DB: ${POSTGRES_MEALIE_DB}
       POSTGRES_USER: ${POSTGRES_MEALIE_USER}
       POSTGRES_PASSWORD: ${POSTGRES_MEALIE_PASSWORD}
       POSTGRES_INITDB_ARGS: "--locale=es_ES.UTF-8 --encoding=UTF-8"
     volumes:
       - /mnt/hd2t/services/mealie/db:/var/lib/postgresql/data
     networks:
       - productividad-internal
     # ... (labels, healthcheck, watchtower opt-out — copiar de paperless-db)
   ```
3. **Cambiar `mealie`** para usar Postgres y unirse a `productividad-internal`:
   ```yaml
   mealie:
     environment:
       DB_ENGINE: postgres
       POSTGRES_SERVER: mealie-db
       POSTGRES_PORT: 5432
       POSTGRES_DB: ${POSTGRES_MEALIE_DB}
       POSTGRES_USER: ${POSTGRES_MEALIE_USER}
       POSTGRES_PASSWORD: ${POSTGRES_MEALIE_PASSWORD}
     networks:
       homelab:
         aliases:
           - mealie
       productividad-internal:
   ```
4. **Borrar el `mealie.db` SQLite** (¡tras tener el export!):
   ```bash
   docker compose down mealie
   sudo rm /mnt/hd2t/services/mealie/data/mealie.db*
   ```
5. **Levantar el nuevo stack**: `docker compose up -d mealie-db` (esperar a `(healthy)`), luego `up -d mealie`. Mealie ejecuta `alembic upgrade head` sobre la BD vacía y arranca limpio.
6. **Importar el export** desde la UI: `Settings → Migrations → Mealie → Upload pre-postgres.zip`. Mealie restaura recetas, usuarios, planes, listas y categorías.
7. **Cambiar el _hook_ de Borgmatic**: descomentar `dump_postgres mealie mealie-db "$HOMELAB/productividad/.env"` y comentar `dump_sqlite mealie mealie /app/data/mealie.db`.
8. Verificación final completa.

> **Atención**: las **fotos de receta** viven en `data/recipes/` y **NO** se mueven a Postgres (Mealie nunca las guarda en BD; siempre en filesystem). Sólo cambia el backend de la metadata. La copia raw de `data/` en Borgmatic sigue siendo necesaria.

---

## Referencias

- Documentación oficial de Mealie: <https://docs.mealie.io/>
  - Variables de configuración: <https://docs.mealie.io/documentation/getting-started/installation/backend-config/>
  - API REST + OpenAPI: <https://demo.mealie.io/docs> (instancia demo) y `/docs` en cualquier instancia local
  - OIDC / SSO: <https://docs.mealie.io/documentation/getting-started/authentication/oidc-v2/>
  - Reverse proxy: <https://docs.mealie.io/documentation/getting-started/installation/installation-checklist/#reverse-proxy>
  - Backup y migration: <https://docs.mealie.io/documentation/getting-started/usage/backups-and-restoring-backups/>
- Repositorio upstream: <https://github.com/mealie-recipes/mealie>
- Imagen Docker oficial: <https://github.com/mealie-recipes/mealie/pkgs/container/mealie>
- App móvil comunitaria (no oficial): <https://github.com/atrope/mealie-app>
- Bookmarklets de _scrape_ desde el navegador: <https://github.com/mealie-recipes/mealie/discussions> (buscar "bookmarklet")
- Backup de SQLite con `.backup` (Patrón S): `docs/07-backups/03-backup-docker-volumes.md` → _Patrón S_.
- Documento adyacente: `docs/11-productividad/01-vaultwarden.md` (estrenó el _stack_ `productividad`; mismo patrón SQLite-only).
- Documento adyacente: `docs/11-productividad/03-linkding.md` (mismo patrón Watchtower opt-in + SQLite + token de API).
- Documento adyacente: `docs/11-productividad/04-paperless-ngx.md` (precedente del Postgres en este _stack_; útil para la sección **Migrar a PostgreSQL**).
- `docs/01-sistema/04-estructura-directorios.md` — pre-creación de `/mnt/hd2t/services/mealie/`.
- `docs/02-docker/02-estructura-compose.md` — un compose por dominio, redes externas/internas, convenciones de _naming_.
- `docs/02-docker/04-watchtower.md` — opt-in de Mealie (semver semi-estricto, patches seguros).
- `docs/03-red/02-pihole.md` — wildcard `*.lan → 192.168.1.3`.
- `docs/03-red/04-caddy.md` — Caddy, CA local, _snippets_ `security-headers` y `logging`.
- `docs/03-red/05-tailscale.md` — acceso remoto vía MagicDNS.
- `docs/04-seguridad/01-authelia.md` — por qué Mealie **no** entra hoy en `forward_auth`; cómo migraría a OIDC en el futuro.
- `docs/07-backups/01-estrategia-backup.md` — Categoría B (datos generados por la app) + Patrón S.
- `docs/07-backups/03-backup-docker-volumes.md` — helper `dump_sqlite` y bloque comentado del _hook_ (con la línea Postgres como alternativa documentada).
- _schema.org/Recipe_ (estándar de metadatos que parsea el scraper): <https://schema.org/Recipe>
