# Mealie

## Descripción

Vaultwarden (`01-vaultwarden.md`), Bookstack (`02-bookstack.md`), Linkding (`03-linkding.md`) y Paperless-ngx (`04-paperless-ngx.md`) cubren respectivamente **secretos**, **conocimiento estructurado**, **marcadores web** y **papel digitalizado**. Queda otro vector de "memoria del hogar" especialmente desordenado: **las recetas de cocina**. El estado típico antes de tener una herramienta dedicada:

- Capturas de pantalla de Instagram/TikTok en `Pictures/Recetas/IMG_20240412_193456.jpg`. Búsqueda imposible.
- Pestañas abiertas eternamente en el navegador en blogs ("la receta del bizcocho que mi hermana usó en Navidades"), que en seis meses devolverán 404.
- Notas en Google Keep o iOS Notes con copias parciales del texto + un enlace, sin foto, sin escalado, sin lista de la compra.
- Servicios cloud (Paprika, BigOven, Yummly, Cookpad) con OCR/import por URL. Funcionan, pero las recetas — y la **lista de la compra**, que es dato bastante íntimo — viven en servidores de terceros.

Este documento despliega **Mealie** — gestor de recetas y planificador de menús autohospedado (Python/FastAPI + Vue 3 + SQLite/PostgreSQL) creado por Hayden Brivinski. Es el equivalente *self-hosted* de Paprika 3 / BigOven, con app móvil PWA, importación de recetas desde URL (vía `recipe-scrapers`), planificador semanal y generador de listas de la compra. Su rol concreto en el homelab:

1. **Servir la UI** en `https://mealie.${DOMAIN_LAN}/` con TLS terminado en Caddy (CA interna, igual que el resto). Detrás de Caddy, sin `ports:` al host.
2. **Persistir todo en SQLite** (`/app/data/mealie.db` dentro del contenedor → `/mnt/hd2t/apps/mealie/data/mealie.db` en el host). Mismo patrón y por las mismas razones que Vaultwarden y Linkding (1–5 usuarios humanos, una BBDD relacional dedicada con su propio contenedor sería sobreingeniería). Reabrible a PostgreSQL si la familia escala.
3. **Importación de recetas por URL**: el operador pega `https://www.recetasdelaabuela.com/bizcocho-yogur` y Mealie scrapea el JSON-LD `schema.org/Recipe` (o, como fallback, el HTML estructurado). Soporta ~400 sitios populares vía la librería upstream `recipe-scrapers`. Para sitios sin metadata estructurada, hay un editor manual con asistente OCR (vía adjuntar foto).
4. **Imágenes y assets de cada receta** en `/mnt/hd2t/apps/mealie/data/recipes/<group>/<recipe-slug>/images/`. Foto principal + miniaturas + adjuntos (PDFs, vídeos cortos). Crece despacio (~200–500 KiB/receta).
5. **Múltiples *groups* y *households***. Mealie 2.x distingue entre **group** (la unidad de aislamiento — "la familia", con su catálogo de recetas, ingredientes y unidades) y **household** (subdivisiones dentro del group para listas de la compra y planes de menú separados — "padres" / "tía Pepa que viene los domingos"). El homelab estandariza un único group `home` con un único household `home`; los miembros de la familia comparten todas las recetas.
6. **Planificador semanal y *meal plans***. La UI permite arrastrar recetas a un calendario semanal (o aleatorizar entre tags `quick`, `vegetarian`, etc.) y generar la lista de la compra agregando ingredientes con su unidad — útil cuando dos recetas distintas piden "huevos" y se suman.
7. **Lista de la compra colaborativa**. La PWA (instalable desde Android/iOS añadiendo el sitio al home screen) permite ir tachando ingredientes en el supermercado en tiempo real desde varios móviles del mismo household.
8. **Autenticación contra Authelia vía OIDC** (Mealie ≥ 1.4 soporta OIDC nativamente con PKCE; en 2.x está estabilizado). Flujo idéntico al de Bookstack, Linkding y Paperless: redirect a Authelia, claims `sub`, `email`, `groups`, sesión propia tras autenticar. La cuenta superuser local (`changeme@example.com`/`MyPassword`) creada automáticamente en bootstrap se elimina inmediatamente o se le rota la password como cuenta de contingencia.
9. **API REST** estable en `/api/...` con autenticación por **token de usuario** (cabecera `Authorization: Bearer <jwt>`), generable desde `User Settings → API Tokens`. Es el canal que usan los scripts del operador (`yt-dlp` que extrae transcripción de un vídeo de cocina y crea una entrada borrador en Mealie, por ejemplo).
10. **Respaldarse vía Borgmatic** con un hook `before_backup` que hace `VACUUM INTO` sobre la SQLite (idéntico al script de Vaultwarden y Linkding) más el directorio `data/recipes/` como ficheros.

Lo que este documento **no** decide:

- **PostgreSQL como backend**. Mealie soporta `DB_ENGINE=postgres`. Para 1–5 usuarios, una familia con ~500–2000 recetas en horizonte de 5 años, SQLite es suficiente y más simple de respaldar (un único fichero vs un sidecar entero). Reabrible si en el futuro el operador quiere replicación o cargas más altas.
- **Notificaciones por email** (recordatorios de planes, invitaciones de usuarios). Mealie soporta SMTP nativo. Igual que Bookstack, Vaultwarden y Linkding, queda **deshabilitado** hasta Mailrise (Fase 11). Las invitaciones se materializan vía URL de invite que se copia/pega.
- **Apprise para notificaciones de meal plan**. Mealie 2.x soporta Apprise como destino de notificaciones (Telegram, ntfy, Discord). Diferido hasta Mailrise; el operador puede activar Telegram bot directamente sin Apprise si lo necesita pronto.
- **Sincronización con Nextcloud Cookbook**. Mealie tiene importer para Nextcloud Cookbook (formato `recipe.json` Schema.org). Documentado en "Configuración → Importación", no como flujo activo (no hay Nextcloud en el homelab por ahora).
- **Reconocimiento de voz para "lista de la compra"** (Mealie 2.x experimental). No se activa: requiere modelos LLM externos.
- **OCR de fotos de recetas**. Mealie soporta adjuntar imágenes pero el OCR no es nativo. Si el operador quiere extraer texto de una foto de un libro de recetas, lo hace con Paperless-ngx (`04-paperless-ngx.md`) y luego copia/pega.
- **Multi-household real (operador + abuela)**. Aceptable como evolución natural si la abuela quiere su propio plan; pero por defecto un único household `home` mantiene la lista de la compra unificada para la pareja.
- **Backup automático nativo de Mealie** (`/api/admin/backups`). La API permite generar un `.zip` con toda la BBDD + media. Es útil para migrar a otro Mealie, pero **redundante** con Borg para *disaster recovery* (Borg ya respalda la BBDD vía `VACUUM INTO` y los assets como ficheros). Documentado como "exportable bajo demanda", no automatizado.

Cuando este documento se haya aplicado:

- `https://mealie.${DOMAIN_LAN}/` muestra la UI con cert de la CA interna.
- El primer login del operador pasa por Authelia (login + TOTP), Mealie recibe el `id_token` vía OIDC con PKCE y crea automáticamente su cuenta con permisos de admin (porque pertenece al grupo `mealie-admins` configurado en Authelia).
- La cuenta `changeme@example.com` que Mealie crea por defecto al primer arranque queda con password aleatoria (KeePassXC offline) **o** se elimina con `User Management → Delete`.
- El operador pega la URL de un blog de cocina, Mealie descarga el JSON-LD, rellena ingredientes/instrucciones/imagen y queda guardada con un click.
- La SQLite vive en `/mnt/hd2t/apps/mealie/data/mealie.db`; los assets de cada receta en `/mnt/hd2t/apps/mealie/data/recipes/`.
- Borgmatic respalda diariamente la SQLite con `VACUUM INTO` consistente y los assets como ficheros (T1: las recetas son contenido del operador, no derivable).
- Uptime Kuma tiene un monitor HTTPS sobre `https://mealie.lan/api/app/about` con alerta Telegram + email.

> **Recordatorio de alcance**: Mealie es **solo LAN + Tailscale**. **No publica `ports:` al host**, **no se expone a Internet**, **no usa Let's Encrypt**. La PWA instalada en el móvil habla con `https://mealie.lan` directamente cuando la familia está en LAN; vía Tailscale, MagicDNS resuelve el mismo nombre desde fuera de casa (siempre y cuando el cliente tenga la CA interna instalada — si no, el service worker de la PWA se queda en estado `redundant` y la app no carga).

---

## Requisitos Previos

- **Fase 2** completa: Docker Engine + Compose v2; red `homelab` en `172.30.10.0/24`; convenciones `stacks/<svc>/`; `.env` global con `TZ`, `PUID`, `PGID`, `DOMAIN_LAN=lan`, `LAN_IP=192.168.1.10`.
- **Fase 3** completa, en particular:
  - Pi-hole con el comodín `address=/lan/192.168.1.10` (cubre `mealie.${DOMAIN_LAN}` sin tocar Pi-hole).
  - Caddy con los snippets `(lan_tls)`, `(security_headers)`, `(healthcheck)` definidos.
- **Fase 4** completa, en particular:
  - Authelia desplegado **con OIDC habilitado**. Mealie consume OIDC (no `forward_auth`); patrón idéntico al de Bookstack, Linkding y Paperless.
  - El **client OIDC** `mealie` registrado en `configuration.yml` de Authelia (ver "Configuración → 2. Registrar el client OIDC en Authelia").
  - Los **grupos de Authelia** `mealie-users` y `mealie-admins` existen en el backend de Authelia (file backend o LDAP) y el operador pertenece a `mealie-admins`.
- **Fase 7** completa: Borgmatic operativo con `homelab.backup=true` como discriminador. La SQLite se respalda con un hook `before_backup` (mismo patrón que Vaultwarden y Linkding).
- **Operador** con la **CA interna instalada** en navegador (PC + móvil) — y, **muy importante**, en el almacén de **certificados de usuario** del navegador del móvil donde se instalará la PWA (Android: Configuración → Seguridad → Cifrado → Instalar certificado; iOS: instalar perfil con Apple Configurator). Sin la CA, la PWA falla en el primer `fetch()` con `net::ERR_CERT_AUTHORITY_INVALID` y queda inutilizable offline.
- **Disco `hd2t`** montado en `/mnt/hd2t` con al menos **3 GiB** libres reservados para Mealie:
  - `data/mealie.db`: 20–80 MiB con miles de recetas.
  - `data/recipes/`: ~250 KiB × N recetas (foto principal + miniaturas). 1000 recetas ≈ 250 MiB.
  - `data/.temp/`: temporales de import (zips de Paprika, capturas de scraping). Volátil.
  - Margen + dumps Borg + crecimiento: ~3 GiB sobrados a 5 años.
- Una contraseña aleatoria larga (`openssl rand -base64 30`) para la cuenta inicial `changeme@example.com` que Mealie crea al primer arranque, anotada en KeePassXC offline (cuenta de contingencia).

Comprobaciones rápidas:

```bash
# La red Docker compartida existe
docker network inspect homelab --format '{{.Name}}' | grep -q '^homelab$' && echo ok

# Caddy y Authelia corriendo
docker ps --filter name=caddy --filter name=authelia --format '{{.Names}} {{.Status}}'

# mealie.lan resuelve al IP de la Pi (gracias al comodín de Pi-hole)
dig +short mealie.lan @192.168.1.2
# 192.168.1.10

# Espacio en hd2t
df -h /mnt/hd2t | awk 'NR==2 {print $4 " libres"}'

# Authelia tiene OIDC habilitado y los grupos definidos
docker exec authelia grep -E '^identity_providers:|mealie-' /config/configuration.yml | head
```

---

## Decisión: imagen y versión

Mealie se publica en GitHub Container Registry como `ghcr.io/mealie-recipes/mealie`, con manifests multi-arch (`amd64`, `arm64`). En la Pi 5 (aarch64) se usa el manifest `arm64`. Desde la 1.0 (mediados de 2023) el frontend Vue se compila como assets estáticos servidos por el mismo backend FastAPI: **una sola imagen, un solo contenedor**, simplificando el compose.

| Tag | Cuándo usar | Decisión aquí |
|---|---|---|
| `latest` | Demos, primera prueba. | Descartado (convención de Fase 2: tags exactos). |
| `nightly` | Builds nocturnos contra `mealie-next`. | Descartado: rompe sin previo aviso. |
| `v2` | Major track. | Descartado: avanza con cada minor. |
| `v2.7` | Minor track (parcheo de bugs). | Descartado: prefiero tag exacto para auditoría. |
| `v2.7.0` (ejemplo de tag exacto) | Reproducibilidad estricta. | **Aceptado**. |

> **Tag exacto en uso**: `ghcr.io/mealie-recipes/mealie:v2.7.0`. Si en el momento de aplicar este documento existe una `v2.7.x` superior con changelog limpio (sin migración mayor de schema), se actualiza el tag aquí y en el `docker-compose.yml`, y se anota en el commit. **Nunca `latest`**, **nunca `nightly`**.

> **Por qué Mealie y no Tandoor, Grocy, Cooklang, Chowdown o Paprika sync server**.
> - **Tandoor Recipes**: muy potente (workflow de meal planning, shopping list, supermarket categorization), Django + Postgres + Redis + workers + nginx. Pesa ~3–4 GiB de imagen y RAM acumulada >500 MiB. Sobreingeniería para uso doméstico, y la UI es algo más anticuada.
> - **Grocy**: gestor de inventario casero (con módulo de recetas como secundario). Excelente si la prioridad es "qué hay en el frigo" más que "encontrar recetas"; queda fuera de scope para esta fase. Reabrible si se quiere unificar despensa.
> - **Cooklang / cooked.wiki**: formato/CLI para escribir recetas en texto plano + plataforma SaaS. No tiene UI self-hosted madura comparable. Útil como **input** (Mealie soporta importar Cooklang).
> - **Chowdown**: estático (Jekyll), no tiene API ni planificador. Demasiado limitado.
> - **Servidor sincronización Paprika**: cerrado/comercial, no open source.
> - **Mealie**: punto de equilibrio: FastAPI + SQLite (o Postgres si se quiere), ~250 MiB en idle, OIDC nativo, PWA pulida, app móvil de comunidad (mealie-mobile), `recipe-scrapers` como motor de import, multi-arch arm64 estable, comunidad activa (>7k stars). **Decidido**.

> **Por qué tag exacto y no `v2.7`**. Mealie 2.x ha hecho migrations de schema en releases minores (mover de `householders` a `households` en 2.0, cambios en grupos en 2.4, etc.). Un tag flotante puede dejar la SQLite en estado intermedio si el contenedor se cae a media migration. Con tag exacto las actualizaciones son **deliberadas**: el operador lee el changelog, hace `borgmatic create --tag pre-mealie-upgrade-X.Y.Z`, edita el tag, `up -d`, valida con `/api/app/about` y un par de búsquedas. Watchtower **deshabilitado** para este stack.

---

## Decisión: cómo se expone Mealie

Mealie 2.x corre **uvicorn** (ASGI) con todos los assets estáticos del frontend Vue empaquetados, escuchando en `:9000` dentro del contenedor (HTTP plano; el TLS lo termina Caddy delante).

| Opción | Cómo se ve | Discusión |
|---|---|---|
| `network_mode: host` | Mealie ata `:9000` directamente. | Funcionaría, pero rompe la convención del homelab. Descartado. |
| Bridge `homelab` con `ports: ["9000:9000"]` | Acceso directo desde la LAN sin pasar por Caddy. | HTTP plano sin TLS y sin Authelia delante; la PWA del móvil **no** instala con `http://` (los service workers exigen `https://` salvo en `localhost`). Descartado. |
| Bridge `homelab` con `expose: 9000`, **sin `ports:`** | Mealie alcanzable solo dentro de la red Docker. Caddy hace `reverse_proxy http://mealie:9000`. | Termina TLS en Caddy con la CA interna. Patrón establecido. **Aceptado**. |

Resultado: `expose: 9000` en el compose (no `ports:`), un drop-in `stacks/caddy/conf.d/44-mealie.caddy` que hace `reverse_proxy http://mealie:9000`, y todo el tráfico externo pasa por `https://mealie.${DOMAIN_LAN}/` con cert de la CA interna.

> **Sobre WebSocket / SSE**. Mealie usa polling para refrescar la lista de la compra colaborativa (no WebSocket en 2.x). El reverse proxy estándar de Caddy basta sin directivas adicionales. Si una versión futura introduce WebSocket, `reverse_proxy` lo gestiona transparentemente.

> **Sobre el subpath**. Mealie soporta `BASE_URL` con prefijo de subpath (`https://lan/mealie`) **a medias**: el frontend lo respeta pero algunos endpoints del scheduler no. **No** se usa: la convención es **un subdominio por servicio** (Fase 3), más simple.

> **Sobre `BASE_URL`**. Mealie construye URLs absolutas con esta variable (links en emails, `redirect_uri` de OIDC, manifest de la PWA). Debe coincidir con el FQDN externo: `https://mealie.${DOMAIN_LAN}`. Si no se setea, la PWA queda con `start_url=/` ambiguo y el flujo OIDC falla con `redirect_uri_mismatch` (igual que Linkding y Paperless).

---

## Decisión: autenticación — Authelia OIDC + JWT para API

Mealie tiene tres tipos de cliente:

1. **Navegador humano** sobre la UI web — auth por sesión + JWT en cookie.
2. **PWA en el móvil** (instalable desde el navegador) — auth por la misma sesión que el navegador.
3. **Scripts del operador** vía API REST (importar recetas en bulk, dump puntual) — auth por **token API** (`User → Settings → API Tokens`, JWT de larga duración).

| Componente | Patrón de auth | Justificación |
|---|---|---|
| UI web (`/`, `/g/<group>/`, `/admin/`) | **OIDC contra Authelia** | El operador entra desde un navegador; flujo OIDC interactivo con PKCE; SSO real con Bookstack, Linkding y Paperless. |
| API (`/api/...`) | **JWT** (no OIDC interactivo) | Los scripts no pueden hacer flujos OAuth interactivos. Token generado **una vez** por usuario en `User → Settings → API Tokens` tras login OIDC. |
| Admin (`/admin`) | **OIDC contra Authelia, grupo `mealie-admins`** | El claim `groups` del `id_token` debe contener `mealie-admins` para que Mealie marque al usuario como admin. |

Mealie soporta **OIDC con PKCE** (cliente público, sin `client_secret`) y con `client_secret` (cliente confidencial). En Authelia ambos modelos son soportados; el homelab elige **PKCE puro** (cliente público) por dos razones:

- Mealie es una SPA: el secret iría incrustado en el bundle JS y sería trivialmente extraíble. PKCE elimina ese vector.
- Es más simple: sin secret que rotar, sin variable extra en `.env`.

Resultado: registro de un client `mealie` en `configuration.yml` de Authelia con `public: true`, `redirect_uris: ["https://mealie.${DOMAIN_LAN}/login"]`, `pkce_challenge_method: S256`, y Caddy hace bypass total: el flujo OIDC pasa por Authelia internamente cuando Mealie redirige.

> **Sobre el grupo `mealie-users` vs `mealie-admins`**. Mealie distingue (vía `OIDC_USER_GROUP` y `OIDC_ADMIN_GROUP`):
> - Si el `id_token` no contiene **ningún** grupo de los dos, el usuario es **rechazado** (no puede entrar). Filtra a quién deja entrar Authelia.
> - Si contiene `mealie-users` pero no `mealie-admins`, el usuario es **regular** (puede ver y editar recetas, no puede crear users ni cambiar settings globales).
> - Si contiene `mealie-admins`, el usuario es **admin**.
> El operador queda en `mealie-admins`; la pareja en `mealie-users`. Los hijos pequeños no entran (no están en ningún grupo).

> **Sobre la cuenta `changeme@example.com`**. En el primer arranque Mealie crea automáticamente una cuenta admin con `email=changeme@example.com` y `password=MyPassword`. **Riesgo crítico** si quedara con esa password por defecto — cualquier persona en la LAN podría entrar como admin. El bootstrap (sección "Despliegue → 4") **rota la password a un valor aleatorio largo** y la guarda en KeePassXC offline. Es la cuenta de contingencia para "Authelia roto"; mantener login local activo (`ALLOW_PASSWORD_LOGIN=true`).

> **Sobre el JWT token de la API**. Cuando el operador entra a la UI vía OIDC y va a `User → Settings → API Tokens → Generate`, Mealie genera un JWT con expiración configurable (por defecto **sin expiración** salvo que el operador la fije). Las invocaciones de scripts mandan `Authorization: Bearer <jwt>` en la cabecera; **no** pasan por Authelia (es un endpoint API, no UI). Defensa para fuerza bruta sobre `/api/`: queda a una jail fail2ban — diferida (los JWT son ~150 caracteres aleatorios y Mealie rate-limita login con `RATE_LIMIT_LOGIN_ATTEMPTS=5`).

---

## Decisión: persistencia y base de datos

Mealie soporta dos backends: **SQLite** (default) y **PostgreSQL**. Para 1–5 usuarios y el volumen doméstico esperado (cientos a un par de miles de recetas, sin escrituras concurrentes intensas), SQLite es el camino más simple — exactamente como en Vaultwarden y Linkding.

| Opción | Pros | Contras | Veredicto |
|---|---|---|---|
| **SQLite** (`/app/data/mealie.db`) | Cero piezas adicionales, snapshot consistente con `VACUUM INTO`, fichero único portable, mismo patrón que Vaultwarden y Linkding (un solo hook `before_backup` reusable). | Worse para >50 usuarios concurrentes editando simultáneamente la lista de la compra. No es el caso doméstico. | **Aceptado**. |
| PostgreSQL | Mejor concurrencia, full-text con `GIN` index nativo, opción más usada por la propia comunidad Mealie cuando se acerca a "muchos hogares". | Otro contenedor (`mealie-db`), otra contraseña, ~120–180 MiB de RAM extra, hook `postgresql_databases` (más complejo). | Sobreingeniería para 1–5 usuarios. Descartado. |

Resultado: SQLite en `/mnt/hd2t/apps/mealie/data/mealie.db`. Mealie usa `journal_mode=WAL` por defecto. El hook `before_backup` de Borgmatic ejecuta `VACUUM INTO` antes de cada run, idéntico a Vaultwarden y Linkding — el script `borg-pre-backup.sh` de este stack es un clon ajustando ruta y nombre de contenedor.

Mealie guarda tres tipos de estado:

1. **BBDD relacional** — usuarios, groups, households, recetas, ingredientes, unidades, plans, shopping_lists, tokens. En SQLite (`mealie.db`).
2. **Assets de recetas** — `data/recipes/<group>/<recipe-slug>/images/` (foto principal + miniaturas auto-generadas) y `data/recipes/<group>/<recipe-slug>/assets/` (PDFs, vídeos cortos). Filesystem.
3. **Temporales y backups exportados** — `data/.temp/` (volátil, por scrape/import) y `data/backups/<archive>.zip` (cuando el operador exporta manualmente desde la UI). Filesystem.

| Aspecto | Decisión | Por qué |
|---|---|---|
| BBDD | SQLite con WAL en `/mnt/hd2t/apps/mealie/data/mealie.db`. | Suficiente para 1–5 usuarios; respaldable con `VACUUM INTO`. |
| Imágenes y assets | Bind mount al subdirectorio `recipes/` dentro de `/mnt/hd2t/apps/mealie/data/`. | Datos respaldables como ficheros (no derivables — son lo que el operador subió). |
| Temporales | `data/.temp/`. **Excluido** del backup. | Volátiles, los regenera Mealie en cada scrape. |
| Backups exportados | `data/backups/`. **Se respaldan** si tienen contenido. | El operador puede haberlos generado bajo demanda (auditoría, migración). |
| Configuración | Solo `.env` del compose, versionable (`.env.example`) salvo secretos. | Reproducible desde git + Borg. |
| Snapshot consistente BBDD | `sqlite3 mealie.db 'VACUUM INTO mealie.snapshot.db'` vía hook `before_backup`. | Atómico, no requiere parar el contenedor; mismo patrón Vaultwarden / Linkding. |

> **Por qué no parar el contenedor para hacer backup**. Mealie atiende requests interactivos (la familia chequeando una receta mientras cocina, la pareja tachando ingredientes en la lista de la compra). Parar el contenedor cada noche para Borg implica downtime. Con `VACUUM INTO` es online y consistente.

> **Sobre `data/recipes/` y crecimiento**. Cada receta con foto principal + 2 miniaturas (Mealie las pre-genera en 3 tamaños) ronda 200–600 KiB. Con 2000 recetas (objetivo a 5 años para una familia ávida), el directorio crece ~1 GiB. Reabrir si se acerca al 10 % de hd2t.

---

## Stack: `stacks/mealie/`

### Layout en disco

| Ruta | Soporte | Contenido |
|---|---|---|
| `stacks/mealie/docker-compose.yml` | microSD (git) | Stack (mealie único contenedor). |
| `stacks/mealie/.env.example` | microSD (git) | Plantilla con `OIDC_*` y password del admin de bootstrap. |
| `stacks/mealie/.env` | microSD (NO git) | Versión rellena con secretos reales. Modo `0600`. |
| `stacks/mealie/scripts/borg-pre-backup.sh` | microSD (git) | Hook `before_backup`: snapshot consistente de SQLite con `VACUUM INTO`. |
| `stacks/caddy/conf.d/44-mealie.caddy` | microSD (git) | Drop-in Caddy para `mealie.${DOMAIN_LAN}`. |
| `/mnt/hd2t/apps/mealie/data/` | hd2t | `mealie.db`, `recipes/`, `backups/`, `.temp/`. **Se respalda** (excluyendo `.temp/`). |
| `/mnt/hd2t/apps/mealie/dumps/` | hd2t | `mealie.snapshot.db` generado por el hook. **Se respalda**. |

### `stacks/mealie/docker-compose.yml`

```yaml
# Mealie — gestor de recetas y planificador de menús.
# Convenciones: ver docs/02-docker/02-estructura-compose.md y
# docs/11-productividad/05-mealie.md.

name: mealie

x-restart: &default-restart
  restart: unless-stopped

services:

  mealie:
    image: ghcr.io/mealie-recipes/mealie:v2.7.0
    container_name: mealie
    hostname: mealie
    <<: *default-restart

    environment:
      # Usuario del proceso (Mealie respeta PUID/PGID estilo LSIO).
      PUID: ${PUID}
      PGID: ${PGID}
      TZ: ${TZ}

      # URL canónica externa. CRÍTICO: redirect OIDC y manifest de la PWA
      # se construyen desde aquí.
      BASE_URL: https://mealie.${DOMAIN_LAN}

      # Nombre legible de la instancia (header de la UI).
      ALLOW_SIGNUP: "false"          # nadie crea cuentas con `/register`
      DEFAULT_GROUP: home
      DEFAULT_HOUSEHOLD: home
      DEFAULT_EMAIL: changeme@example.com   # cuenta inicial; rotar password en bootstrap

      # BBDD: SQLite por defecto (no DB_ENGINE=postgres).
      DB_ENGINE: sqlite

      # Logging
      LOG_LEVEL: INFO

      # OIDC contra Authelia — cliente público con PKCE.
      OIDC_AUTH_ENABLED: "true"
      OIDC_PROVIDER_NAME: Authelia
      OIDC_CONFIGURATION_URL: https://auth.${DOMAIN_LAN}/.well-known/openid-configuration
      OIDC_CLIENT_ID: mealie
      # Sin OIDC_CLIENT_SECRET: cliente público con PKCE.
      OIDC_AUTO_REDIRECT: "false"     # mantenemos el botón "Sign in with Authelia"
                                      # junto al login local de la cuenta de fallback
      OIDC_SIGNUP_ENABLED: "true"     # primera vez que un user OIDC entra, se crea automáticamente
      OIDC_REMEMBER_ME: "true"
      OIDC_USER_CLAIM: email          # default; explícito por trazabilidad
      OIDC_NAME_CLAIM: name
      OIDC_GROUPS_CLAIM: groups
      OIDC_USER_GROUP: mealie-users
      OIDC_ADMIN_GROUP: mealie-admins
      OIDC_TLS_CACERTFILE: /etc/ssl/certs/homelab-ca.crt   # ver "Configuración → 1"

      # Login local (cuenta de contingencia changeme@example.com).
      ALLOW_PASSWORD_LOGIN: "true"

      # Rate-limit del login local (defensa antibruteforce).
      RATE_LIMIT_LOGIN_ATTEMPTS: "5"
      RATE_LIMIT_LOGIN_PER_MINUTE: "1"

      # SMTP DESHABILITADO hasta Mailrise (Fase 11).
      SMTP_HOST: ""
      SMTP_PORT: ""
      SMTP_AUTH_STRATEGY: ""

    networks:
      - homelab               # Caddy llega por aquí

    expose:
      - "9000"
    # NO `ports:`. Acceso solo vía Caddy.

    volumes:
      - /mnt/hd2t/apps/mealie/data:/app/data
      # Carpeta para los snapshots SQL (VACUUM INTO) que respalda Borg.
      - /mnt/hd2t/apps/mealie/dumps:/app/dumps
      # Hook de pre-backup montado read-only para que Borgmatic pueda
      # invocarlo via `docker exec`.
      - /home/homelab/homelab/stacks/mealie/scripts/borg-pre-backup.sh:/usr/local/bin/borg-pre-backup.sh:ro
      # CA interna disponible al proceso para que la verificación TLS contra
      # auth.lan/.well-known/openid-configuration funcione sin --insecure.
      - /mnt/hd2t/apps/caddy/etc/ca/homelab-ca.crt:/etc/ssl/certs/homelab-ca.crt:ro

    healthcheck:
      test: ["CMD-SHELL", "wget -q -O - http://127.0.0.1:9000/api/app/about >/dev/null || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 60s

    security_opt:
      - "no-new-privileges:true"

    labels:
      homelab.role: "recipes"
      homelab.backup: "true"
      com.centurylinklabs.watchtower.enable: "false"

networks:
  homelab:
    external: true
```

> **Sobre el `start_period: 60s`**. El primer arranque ejecuta `alembic upgrade head` (migraciones de schema), inicializa la BBDD si no existe, crea la cuenta `changeme@example.com` y arranca uvicorn. En la Pi 5 esto tarda 30–45 s. Si el periodo es más corto, Compose marca el contenedor como unhealthy antes de tiempo y `restart: unless-stopped` entra en bucle.

> **Sobre `OIDC_TLS_CACERTFILE`**. Mealie hace una llamada HTTPS a `auth.lan/.well-known/openid-configuration` para descubrir endpoints OIDC. Como el cert lo emite la CA interna del homelab (no una pública), el contenedor debe confiar en ella explícitamente. Hay dos opciones equivalentes: (a) inyectar la CA en el truststore Python con `OIDC_TLS_CACERTFILE` apuntando al fichero, (b) montar `homelab-ca.crt` en `/etc/ssl/certs/` y dejar al sistema confiar. La imagen de Mealie usa `httpx` que lee `SSL_CERT_FILE` o el bundle del sistema; `OIDC_TLS_CACERTFILE` es el control específico de Mealie y precede al sistema. **Documentado** explícitamente porque sin esta variable Mealie loguea `[SSL: CERTIFICATE_VERIFY_FAILED]` y el botón OIDC queda inerte.

### `stacks/mealie/.env.example`

```bash
# stacks/mealie/.env.example
# Variables específicas del stack Mealie. Las generales (TZ, PUID, PGID,
# DOMAIN_LAN) viven en el .env GLOBAL.
#
# Mealie usa cliente OIDC público con PKCE: NO HAY CLIENT_SECRET.
# Si en el futuro se cambia a cliente confidencial (no recomendado para SPA),
# añadir OIDC_CLIENT_SECRET aquí.

# Password de la cuenta inicial `changeme@example.com` que Mealie crea al
# primer arranque. SOLO se usa hasta la primera rotación en bootstrap.
# Después se ROTA a un random largo y se guarda en KeePassXC offline como
# cuenta de contingencia.
#   openssl rand -base64 30
MEALIE_BOOTSTRAP_PASSWORD=CHANGEME_RANDOM_30_BASE64_TEMPORAL
```

### `stacks/caddy/conf.d/44-mealie.caddy`

```caddy
# /etc/caddy/conf.d/44-mealie.caddy — bloque LAN para Mealie.
# UI + API + endpoints OIDC en http://mealie:9000 dentro de `homelab`.
# Auth UI: OIDC contra Authelia (cliente público con PKCE; no forward_auth).
# Auth API: JWT (cabecera Authorization: Bearer <jwt>).
# Documentado en docs/11-productividad/05-mealie.md.

mealie.{$DOMAIN_LAN} {
    import lan_tls
    import security_headers
    import healthcheck

    # Subida de imágenes de receta puede ser grande (foto principal HQ +
    # bulk import desde un .zip de Paprika export con cientos de fotos).
    # Mealie internamente acepta hasta 50 MiB; Caddy con margen.
    request_body {
        max_size 100MB
    }

    reverse_proxy http://mealie:9000 {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
        header_up X-Forwarded-Host {host}
    }
}
```

> **Sobre `request_body max_size`**. Sin esta directiva, Caddy aplica el límite por defecto (10 MiB) y subir un `.zip` de export de Paprika de 80 MiB falla con `413 Request Entity Too Large`. 100 MiB cubre el 99 % del caso de uso doméstico.

### `stacks/mealie/scripts/borg-pre-backup.sh`

```bash
#!/usr/bin/env bash
# stacks/mealie/scripts/borg-pre-backup.sh
# Hook `before_backup` de Borgmatic: snapshot consistente de SQLite vía
# `VACUUM INTO`. Idéntico patrón al de Vaultwarden y Linkding.

set -euo pipefail

DB_SRC="/app/data/mealie.db"
DB_OUT="/app/dumps/mealie.snapshot.db"

mkdir -p "$(dirname "$DB_OUT")"

# Borrar el snapshot anterior; VACUUM INTO falla si el destino existe.
rm -f "$DB_OUT"

# VACUUM INTO es atómico desde SQLite 3.27 (2019). Mantiene la BBDD viva
# (ningún lock global), genera un fichero limpio (sin WAL pendiente).
sqlite3 "$DB_SRC" "VACUUM INTO '$DB_OUT';"

# Permisos legibles solo por el dueño del bind mount (1000:1000).
chmod 0600 "$DB_OUT"

echo "[borg-pre-backup] mealie snapshot OK: $(stat -c %s "$DB_OUT") bytes"
```

### Crear los directorios persistentes y desplegar

```bash
# 0) Asegurar el árbol de datos en hd2t (idempotente)
sudo install -d -o root -g root -m 0755 /mnt/hd2t/apps/mealie

# Mealie corre como PUID/PGID = 1000:1000.
sudo install -d -o 1000 -g 1000 -m 0750 /mnt/hd2t/apps/mealie/data
sudo install -d -o 1000 -g 1000 -m 0750 /mnt/hd2t/apps/mealie/dumps

# 1) Generar password de bootstrap para changeme@example.com (UNA SOLA VEZ)
openssl rand -base64 30
# Pegar en stacks/mealie/.env como MEALIE_BOOTSTRAP_PASSWORD.

# 2) Materializar stacks/mealie/.env
cd /home/homelab/homelab
cp stacks/mealie/.env.example stacks/mealie/.env
chmod 0600 stacks/mealie/.env
# Editar y pegar MEALIE_BOOTSTRAP_PASSWORD generado en (1).

# 3) Drop-in de Caddy
install -o homelab -g homelab -m 0644 \
    stacks/caddy/conf.d/44-mealie.caddy \
    /mnt/hd2t/apps/caddy/etc/conf.d/44-mealie.caddy

# 4) Validar el Caddyfile
docker exec caddy caddy validate --config /etc/caddy/Caddyfile
# Successful

# 5) Validar el compose
docker compose \
    -f stacks/mealie/docker-compose.yml \
    --env-file .env --env-file stacks/mealie/.env \
    config >/dev/null && echo "compose OK"

# 6) Levantar el stack
docker compose \
    -f stacks/mealie/docker-compose.yml \
    --env-file .env --env-file stacks/mealie/.env \
    up -d

# 7) Recargar Caddy
docker kill --signal=SIGUSR1 caddy
```

Tras `up -d`:

```bash
docker ps --filter name=mealie --format 'table {{.Names}}\t{{.Status}}'
# mealie               Up 1 minute (healthy)

# Logs de migrations (primer arranque)
docker logs mealie 2>&1 | grep -E 'alembic|migration|Application startup' | head
# INFO  [alembic.runtime.migration] Context impl SQLiteImpl.
# INFO  [alembic.runtime.migration] Will assume non-transactional DDL.
# INFO  [alembic.runtime.migration] Running upgrade  -> ...
# INFO  Application startup complete.
```

Si el contenedor `mealie` no llega a `(healthy)` en 90 s, lo más probable es:
- UID 1000 sin acceso a `/mnt/hd2t/apps/mealie/data/` → logs muestran `PermissionError: [Errno 13]`.
- `OIDC_CONFIGURATION_URL` apunta a un Authelia no resuelto desde el contenedor (red Docker mal configurada o auth.lan no en Pi-hole) → logs muestran `httpx.ConnectError` y Mealie aborta el startup (con `OIDC_AUTH_ENABLED=true` la URL es validada al boot).
- CA interna no inyectada → logs muestran `ssl.SSLCertVerificationError`.
- Disco hd2t lleno.

Comprobación de extremo a extremo:

```bash
# UI responde 200 con la página de login
curl -skI https://mealie.lan/login
# HTTP/2 200

# API "about" responde 200 (no requiere auth para versión + features)
curl -sk https://mealie.lan/api/app/about | jq '.version'
# "v2.7.0"
```

---

## Configuración

### 1) Bootstrap: rotar la password de `changeme@example.com` (cuenta de contingencia)

Mealie crea automáticamente al primer arranque una cuenta admin con `email=changeme@example.com` y `password=MyPassword`. **Antes de exponer el servicio a la familia**, rotar la password al valor de `MEALIE_BOOTSTRAP_PASSWORD` generado:

1. Entrar a `https://mealie.lan/login`.
2. Login con `changeme@example.com` / `MyPassword`.
3. `User Settings → Change Password` → pegar el random de `MEALIE_BOOTSTRAP_PASSWORD`.
4. `Logout`.

Anotar `changeme@example.com` + nueva password **solo** en KeePassXC offline. Esta cuenta no se usa día a día — es el fallback para "Authelia roto".

> **Por qué no eliminarla del todo**. Mealie valida en startup que **al menos un admin** existe; si se elimina la única cuenta admin antes de tener otra, el siguiente restart aborta. La secuencia segura es: (a) crear el operador admin vía OIDC, (b) verificar que entra y administra, (c) **opcionalmente** demote o eliminar `changeme@example.com`. El homelab opta por **mantenerla** como fallback con password rotada.

### 2) Registrar el client OIDC `mealie` en Authelia

En `/mnt/hd2t/apps/authelia/config/configuration.yml`, dentro de `identity_providers.oidc.clients`, añadir el bloque:

```yaml
identity_providers:
  oidc:
    # ... hmac_secret, issuer_private_key (ya definidos en 04-seguridad/01-authelia.md)
    clients:
      # ... otros clients existentes (bookstack, linkding, paperless, ...)
      - client_id: mealie
        client_name: Mealie
        # Cliente PÚBLICO con PKCE: NO hay client_secret.
        public: true
        require_pkce: true
        pkce_challenge_method: S256
        authorization_policy: two_factor
        redirect_uris:
          - https://mealie.lan/login
        scopes:
          - openid
          - profile
          - email
          - groups
        userinfo_signed_response_alg: none
        token_endpoint_auth_method: none    # cliente público
        consent_mode: implicit
```

Asegurar también que los grupos `mealie-users` y `mealie-admins` existen en el backend de Authelia. Para el file backend (`/mnt/hd2t/apps/authelia/config/users_database.yml`):

```yaml
users:
  operator:
    displayname: "Operador"
    password: "$argon2id$..."
    email: operator@homelab.lan
    groups:
      - admins
      - mealie-admins
      - mealie-users
  pareja:
    displayname: "Pareja"
    password: "$argon2id$..."
    email: pareja@homelab.lan
    groups:
      - mealie-users
```

Recargar Authelia:

```bash
docker compose -f /home/homelab/homelab/stacks/authelia/docker-compose.yml \
    up -d --force-recreate
docker logs authelia 2>&1 | grep 'client_id=mealie' | tail
# expected: "Provider: registered client" client_id=mealie
```

> **Sobre la URL exacta de `redirect_uris`**. Mealie 2.x usa `/login` como callback (la SPA captura el `code` del fragmento/query y lo intercambia llamando a su propio `/api/auth/oauth`). Authelia es estricto: si la URL no coincide carácter a carácter (incluida la barra final si el registro la lleva), rechaza con `redirect_uri_mismatch`. **Sin** barra final tras `login`.

### 3) Primer login OIDC del operador

Tras el restart de Authelia, refrescar `https://mealie.lan/login`. Aparece el botón **"Sign in with Authelia"** (junto al formulario de login local). Pulsar el botón:

1. Redirige a `https://auth.lan/?rd=...&workflow=openid_connect`.
2. Authelia pide login + TOTP (política `two_factor`).
3. Authelia devuelve el `id_token` con claims `sub`, `email`, `name`, `groups: ["admins","mealie-admins","mealie-users"]`.
4. Mealie crea automáticamente la cuenta del operador (`OIDC_SIGNUP_ENABLED=true`) y la marca como **admin** (porque el claim `groups` contiene `mealie-admins`).
5. Sesión iniciada en Mealie como `operator@homelab.lan`.

Verificar:

```bash
# El admin local de fallback sigue existiendo
curl -sk https://mealie.lan/api/admin/users \
    -H "Authorization: Bearer <token-del-operador-vía-UI>" | \
    jq '.items[] | {email, admin}'
# {"email": "changeme@example.com", "admin": true}
# {"email": "operator@homelab.lan",  "admin": true}
```

### 4) Forzar SSO por defecto (opcional)

Tras validar que la familia entra sin fricción vía Authelia, redirigir `/login` directamente a SSO:

```bash
sed -i 's|^OIDC_AUTO_REDIRECT: .*|OIDC_AUTO_REDIRECT: "true"|' \
    stacks/mealie/docker-compose.yml
docker compose -f stacks/mealie/docker-compose.yml \
    --env-file .env --env-file stacks/mealie/.env \
    up -d --force-recreate
```

Con `OIDC_AUTO_REDIRECT=true`, abrir `https://mealie.lan/` redirige inmediatamente a Authelia sin mostrar formulario local. El login local sigue accesible en `https://mealie.lan/login?direct=true` (parámetro que Mealie respeta para bypass) — útil si Authelia se rompe.

### 5) Crear el group y el household por defecto

Mealie crea automáticamente un group `home` con household `home` (porque `DEFAULT_GROUP=home` y `DEFAULT_HOUSEHOLD=home` en el compose). Verificar y, si se desea, añadir miembros:

1. Como admin, ir a `Admin → Group Management → home`.
2. Añadir a `pareja@homelab.lan` al group + household `home`.
3. Configurar la zona horaria del group (`Group Settings`) a `Europe/Madrid`.
4. Configurar el primer día de la semana (`First Day of Week`) según preferencia (`Monday` / `Sunday`).

### 6) Importar recetas — flujos típicos

Mealie soporta varios pipelines de importación:

| Origen | Cómo |
|---|---|
| URL pública (blog, portal de recetas) | `Recipes → Create → From URL` → pega URL → Mealie scrapea JSON-LD `schema.org/Recipe`. ~400 sitios soportados nativamente vía `recipe-scrapers`. |
| Múltiples URLs en bulk | `Admin → Site Settings → Bulk URL Import` → lista de URLs. Útil tras una sesión de "Pinterest cleanup". |
| Export de Paprika | `Group Settings → Migrations → Paprika` → subir el `.paprikarecipes` (zip de Paprika export). |
| Export de Nextcloud Cookbook | `Group Settings → Migrations → Nextcloud` → subir el `.zip` de `Cookbook` export. |
| Export de Chowdown | `Group Settings → Migrations → Chowdown` → subir el repo zip. |
| Manual con OCR | `Recipes → Create → Manual` → adjuntar foto del libro de cocina y completar el formulario. (OCR no es nativo; usar Paperless si se quiere extraer texto previamente.) |
| Cooklang | Pegar el bloque de texto Cooklang en el editor de receta; Mealie lo parsea en 2.x. |

> **Sobre el rate-limit del scraping**. Si el operador hace bulk import de 200 URLs del mismo dominio, el sitio puede devolver 429. Mealie añade `User-Agent: Mealie/2.x` y respeta `Retry-After`, pero con dominios agresivos es más rápido importar lotes de 20.

### 7) Tags, categorías, herramientas y unidades

Mealie ofrece dimensiones múltiples para clasificar recetas:

| Dimensión | Ejemplo | Cuándo usar |
|---|---|---|
| **Categories** | `Postre`, `Plato principal`, `Aperitivo`. | Categorías mutuamente excluyentes "tipo de plato". |
| **Tags** | `vegetariano`, `rápido`, `italiano`, `Navidad`. | Etiquetas libres acumulables. |
| **Tools** | `Olla a presión`, `Horno`, `Air fryer`. | Filtrado por equipo disponible — el típico "no enciendo el horno hoy". |
| **Foods + Units** | `Harina (g)`, `Aceite (ml)`. | Componentes de ingredientes; aprende del primer ingreso y se autocompleta en futuras recetas. |

Workflow recomendado para los primeros meses:
1. Importar 50–100 recetas para tener masa crítica.
2. Definir 5–8 tags principales (`familia`, `rápido`, `domingo`, etc.).
3. Definir 4–5 categorías (`Plato principal`, `Postre`, `Cena`, `Desayuno`).
4. A partir del mes 2, añadir nuevas tags solo si aparecen 3+ veces.

### 8) Plan de menú semanal y lista de la compra

`Group → Meal Planner` permite arrastrar recetas a días concretos de la semana. Mealie mantiene también un modo **rules-based**: definir reglas tipo "cena de lunes: random entre tag `rápido`" y pulsar `Auto-fill week`.

Una vez un día tiene receta(s) asignada(s), `Group → Shopping Lists → Create from Meal Plan` agrega los ingredientes de las recetas asignadas en una lista única, **fusionando ingredientes idénticos con sus unidades** (dos recetas que pidan "huevo" suman; "harina (200g)" + "harina (50g)" = "harina (250g)").

La lista se sincroniza en tiempo real (polling cada ~10 s en 2.x) entre los miembros del household — ambos móviles ven los `[x]` que el otro tacha en el supermercado.

### 9) Notificaciones (diferido)

`Group Settings → Webhooks → Add Notification` soporta:
- **Apprise URLs**: `tgram://<token>/<chat_id>`, `ntfy://...`, `discord://...`. Para uso doméstico, telegram bot directo es lo más práctico.
- Eventos: receta creada, receta actualizada, plan de menú generado.

Diferido hasta Mailrise (Fase 11). Tras Mailrise el operador puede mandar notificaciones del meal planner del domingo a un canal de Telegram familiar.

### 10) Integrar el snapshot SQLite en Borgmatic

En `/etc/borgmatic.d/borgmatic.yaml`:

```yaml
before_backup:
  # ... otros hooks (vaultwarden, linkding)
  - docker exec mealie /usr/local/bin/borg-pre-backup.sh

source_directories:
  # ... otros directorios
  - /home/homelab/homelab
  - /mnt/hd2t/apps/mealie/data
  - /mnt/hd2t/apps/mealie/dumps

exclude_patterns:
  # ... otros excludes
  - '/mnt/hd2t/apps/mealie/data/.temp'           # temporales de scraping
  - '/mnt/hd2t/apps/mealie/data/mealie.db-shm'   # SQLite WAL: respaldar el snapshot
  - '/mnt/hd2t/apps/mealie/data/mealie.db-wal'
  - '/mnt/hd2t/apps/mealie/data/mealie.db'       # se respalda mealie.snapshot.db
```

Verificar:

```bash
sudo borgmatic config validate
# All configs valid

# Disparar el hook a mano
docker exec mealie /usr/local/bin/borg-pre-backup.sh
# [borg-pre-backup] mealie snapshot OK: 12345678 bytes

ls -lh /mnt/hd2t/apps/mealie/dumps/
# -rw------- 1 1000 1000 12M ...  mealie.snapshot.db

# Dry-run completo
sudo borgmatic create --dry-run --list 2>&1 | grep -i mealie | head
```

> **Sobre excluir `mealie.db` del archive**. La SQLite con WAL puede tener escrituras pendientes en `mealie.db-wal` cuando Borg la copia "en frío"; el snapshot copiado puede quedar inconsistente. El hook `before_backup` genera `mealie.snapshot.db` (consistent), y el archive incluye **solo** ese fichero. Mismo patrón documentado para Vaultwarden y Linkding en `07-backups/02-borgmatic.md`.

### 11) Monitor en Uptime Kuma

En `https://uptime.${DOMAIN_LAN}/` añadir un **monitor HTTP(s)**:

| Campo | Valor |
|---|---|
| Friendly Name | `Mealie` |
| URL | `https://mealie.lan/api/app/about` |
| Heartbeat Interval | 60 s |
| Retries | 3 |
| Accepted Status Codes | 200 |
| Notification | Telegram + email (Mailrise cuando exista) |
| Public on status page | Sí |

`/api/app/about` responde 200 sin auth (devuelve versión + features habilitados); es el equivalente a `/api/` de Paperless y `/health` de Linkding para health checks externos.

### 12) Instalar la PWA en el móvil

En el móvil del operador y de la pareja, abrir `https://mealie.lan/` con Chrome/Firefox/Safari:
- **Android (Chrome)**: `⋮ → Install app`. Mealie aparece como app independiente con icono propio.
- **iOS (Safari)**: `Compartir → Añadir a pantalla de inicio`.
- **Firefox Android**: requiere extensión `PWAs for Firefox` o usar Edge/Brave.

Tras la instalación, la PWA cachea el shell de la app y permite ver recetas guardadas **offline** (sin conexión). El flujo de login OIDC requiere conectividad (la PWA redirige al sistema operativo a abrir Authelia en navegador externo).

> **Importante**: la CA interna debe estar instalada **a nivel sistema** (no solo en el navegador). Sin eso, el service worker de la PWA queda en estado `redundant` y `Failed to fetch` aparece tras unos segundos. Verificable en `Settings → Apps → Mealie → Storage → Cache` (Android) que muestra > 0 bytes tras la primera carga exitosa.

---

## Almacenamiento

| Ruta | Soporte | Owner:Group | Modo | Contenido |
|---|---|---|---|---|
| `/home/homelab/homelab/stacks/mealie/docker-compose.yml` | microSD | `homelab:homelab` | `0640` | Stack versionado en git. |
| `/home/homelab/homelab/stacks/mealie/.env.example` | microSD | `homelab:homelab` | `0644` | Plantilla versionada. |
| `/home/homelab/homelab/stacks/mealie/.env` | microSD | `homelab:homelab` | `0600` | `MEALIE_BOOTSTRAP_PASSWORD`. **No** versionado. |
| `/home/homelab/homelab/stacks/mealie/scripts/borg-pre-backup.sh` | microSD | `homelab:homelab` | `0750` | Hook de pre-backup. **Versionado**. |
| `/home/homelab/homelab/stacks/caddy/conf.d/44-mealie.caddy` | microSD | `homelab:homelab` | `0644` | Drop-in Caddy. **Versionado**. |
| `/mnt/hd2t/apps/caddy/etc/conf.d/44-mealie.caddy` | hd2t | `homelab:homelab` | `0644` | Drop-in materializado. |
| `/mnt/hd2t/apps/mealie/data/mealie.db` | hd2t | `1000:1000` | `0640` | SQLite live (WAL). **Excluido** del archive (se respalda el snapshot). |
| `/mnt/hd2t/apps/mealie/data/mealie.db-wal` | hd2t | `1000:1000` | `0640` | WAL de SQLite. **Excluido**. |
| `/mnt/hd2t/apps/mealie/data/mealie.db-shm` | hd2t | `1000:1000` | `0640` | Shared memory de SQLite. **Excluido**. |
| `/mnt/hd2t/apps/mealie/data/recipes/` | hd2t | `1000:1000` | `0750` | Imágenes y assets de cada receta. **Sí se respalda** (T1, no derivable). |
| `/mnt/hd2t/apps/mealie/data/backups/` | hd2t | `1000:1000` | `0750` | Backups exportados desde la UI (`Admin → Backups`). **Sí se respalda** si tiene contenido. |
| `/mnt/hd2t/apps/mealie/data/.temp/` | hd2t | `1000:1000` | `0750` | Temporales de scraping/import. **Excluido** del archive. |
| `/mnt/hd2t/apps/mealie/dumps/mealie.snapshot.db` | hd2t | `1000:1000` | `0600` | Snapshot consistente generado por el hook. **Sí se respalda** (T1). |

> **Tamaño esperado a 5 años (2000 recetas, 5 usuarios light)**:
> - `mealie.db`: ~80–150 MiB.
> - `data/recipes/`: ~1 GiB (foto principal + 2 thumbs por receta).
> - `data/backups/`: ~50–200 MiB si el operador ejecuta export mensual.
> - `dumps/mealie.snapshot.db`: ~mismo orden que `mealie.db`.
> - Total: ~1.5 GiB.

---

## Backup

A nivel del repositorio del homelab:

| Artefacto | Estrategia |
|---|---|
| `stacks/mealie/docker-compose.yml`, `.env.example`, `scripts/borg-pre-backup.sh` | Versionados en git. Reproducibles tras un reflasheo. |
| `stacks/caddy/conf.d/44-mealie.caddy` | Versionado en git. |
| `stacks/mealie/.env` (con `MEALIE_BOOTSTRAP_PASSWORD` real, post-rotación) | **No** versionado. Respaldado por Borg como parte de `/home/homelab/homelab/`. |
| Decisiones (SQLite, OIDC con PKCE público, grupos `mealie-{users,admins}`) | Documentadas en este fichero. |

A nivel de datos (Borgmatic, Fase 7):

| Ruta | Tier | ¿Se respalda? | Por qué |
|---|---|---|---|
| `/mnt/hd2t/apps/mealie/dumps/mealie.snapshot.db` | T1 | **Sí** (vía hook `before_backup` que ejecuta `VACUUM INTO`) | Fuente de verdad para restore relacional. Atómico, consistente. |
| `/mnt/hd2t/apps/mealie/data/recipes/` | T1 | **Sí** | Imágenes y assets — no son derivables (los subió el operador). |
| `/mnt/hd2t/apps/mealie/data/backups/` | T2 | **Sí** | Solo si el operador ha generado export manual desde la UI. |
| `/mnt/hd2t/apps/mealie/data/mealie.db` (live) | — | **Excluido** | Puede tener WAL pendiente; usar el snapshot. |
| `/mnt/hd2t/apps/mealie/data/.temp/` | — | **Excluido** | Volátil. |

Patrón en `borgmatic.yaml`:

```yaml
before_backup:
  - docker exec mealie /usr/local/bin/borg-pre-backup.sh

source_directories:
  - /home/homelab/homelab
  - /mnt/hd2t/apps/mealie/data
  - /mnt/hd2t/apps/mealie/dumps

exclude_patterns:
  - '/mnt/hd2t/apps/mealie/data/.temp'
  - '/mnt/hd2t/apps/mealie/data/mealie.db'
  - '/mnt/hd2t/apps/mealie/data/mealie.db-shm'
  - '/mnt/hd2t/apps/mealie/data/mealie.db-wal'
```

Verificación trimestral de restore (Fase 7, calendario Q2 → Mealie, ver `07-backups/03-backup-docker-volumes.md`):

```bash
# 1) Levantar un Mealie aislado en /tmp con datos restaurados
mkdir -p /tmp/drill-mealie/{data,dumps}
sudo chown -R 1000:1000 /tmp/drill-mealie

# 2) Restaurar el snapshot SQLite y los assets
sudo borg extract --list \
    /mnt/hd2t/backups/borg::homelab-LATEST \
    mnt/hd2t/apps/mealie/dumps/mealie.snapshot.db \
    mnt/hd2t/apps/mealie/data/recipes \
    -o /tmp/drill-mealie/

# 3) Renombrar el snapshot a mealie.db (Mealie no entiende "snapshot")
mv /tmp/drill-mealie/mnt/hd2t/apps/mealie/dumps/mealie.snapshot.db \
   /tmp/drill-mealie/data/mealie.db
mv /tmp/drill-mealie/mnt/hd2t/apps/mealie/data/recipes \
   /tmp/drill-mealie/data/recipes
sudo chown -R 1000:1000 /tmp/drill-mealie/data

# 4) Levantar un Mealie temporal contra esa BBDD
docker run -d --rm --name drill-mealie \
    -e BASE_URL=http://localhost:18000 \
    -e DB_ENGINE=sqlite \
    -e ALLOW_SIGNUP=false \
    -e OIDC_AUTH_ENABLED=false \
    -v /tmp/drill-mealie/data:/app/data \
    -p 18000:9000 \
    ghcr.io/mealie-recipes/mealie:v2.7.0

# 5) Esperar healthy
sleep 30
curl -s http://127.0.0.1:18000/api/app/about | jq '.version'
# "v2.7.0"

# 6) Validar count de recetas
curl -s http://127.0.0.1:18000/api/app/about/statistics | jq '.totalRecipes'
# 432

# 7) Cleanup
docker stop drill-mealie
sudo rm -rf /tmp/drill-mealie
```

Procedimiento de restore tras pérdida del contenedor (datos intactos en `hd2t`):

```bash
docker compose -f /home/homelab/homelab/stacks/mealie/docker-compose.yml \
    --env-file /home/homelab/homelab/.env \
    --env-file /home/homelab/homelab/stacks/mealie/.env \
    up -d --force-recreate
# Mealie reusa todos los bind mounts en hd2t.
```

Procedimiento de restore tras pérdida total (reflasheo + restauración Borg):

1. Recrear sistema base (Fase 1), Docker (Fase 2.1), red `homelab` (Fase 2.2), Pi-hole, Caddy, Authelia.
2. Restaurar el repo del homelab y los secrets:
   ```bash
   sudo borg extract /mnt/hd2t/backups/borg::homelab-LATEST \
       home/homelab/homelab
   sudo chown -R homelab:homelab /home/homelab/homelab
   sudo chmod 0600 /home/homelab/homelab/stacks/mealie/.env
   ```
3. Restaurar `data/recipes/`, `data/backups/` y el snapshot SQLite:
   ```bash
   sudo borg extract /mnt/hd2t/backups/borg::homelab-LATEST \
       mnt/hd2t/apps/mealie/data/recipes \
       mnt/hd2t/apps/mealie/data/backups \
       mnt/hd2t/apps/mealie/dumps/mealie.snapshot.db
   ```
4. Promover el snapshot a la BBDD live (Mealie carga `data/mealie.db`):
   ```bash
   sudo cp /mnt/hd2t/apps/mealie/dumps/mealie.snapshot.db \
           /mnt/hd2t/apps/mealie/data/mealie.db
   sudo chown 1000:1000 /mnt/hd2t/apps/mealie/data/mealie.db
   sudo chmod 0640 /mnt/hd2t/apps/mealie/data/mealie.db
   ```
5. Levantar el stack:
   ```bash
   cd /home/homelab/homelab
   docker compose -f stacks/mealie/docker-compose.yml \
       --env-file .env --env-file stacks/mealie/.env \
       up -d
   ```
6. Verificar `https://mealie.lan/api/app/about` (200), login OIDC, count de recetas en `/api/app/about/statistics` coincide con el del archive.

> **Punto de no retorno**: el RPO máximo es **24 h** (frecuencia diaria de Borgmatic). Recetas creadas o editadas entre el último backup y la pérdida se pierden de la BBDD; **pero** las imágenes adjuntadas en `data/recipes/` se respaldan en cada run, así que tras restore quedan huérfanas (Mealie ignora ficheros sin entrada en la BBDD). El operador puede re-importarlas si tiene la URL original anotada. Si el operador quiere RPO menor, añadir un timer `mealie-borg-only.timer` cada 6 h (reabrible).

---

## Errores frecuentes y troubleshooting

| Síntoma | Causa probable | Resolución |
|---|---|---|
| `mealie` queda en `(starting)` 2+ minutos y luego cae a `unhealthy` | Migrations alembic fallaron por permisos en `/app/data`. | `sudo chown -R 1000:1000 /mnt/hd2t/apps/mealie/data && docker compose up -d --force-recreate mealie`. |
| Login OIDC redirige a Authelia y vuelve con `redirect_uri_mismatch` | El `redirect_uri` registrado en Authelia tiene barra final extra, o Caddy no manda `X-Forwarded-Proto`. | Verificar `redirect_uris: ['https://mealie.lan/login']` (sin barra final tras `login`) y que el drop-in 44 tiene `header_up X-Forwarded-Proto {scheme}`. Reload Caddy + Authelia. |
| Login OIDC redirige y vuelve con `invalid_grant` | El cliente está registrado como `public: false` en Authelia pero Mealie no manda `client_secret` (porque es PKCE). | Cambiar a `public: true` + `require_pkce: true` + `token_endpoint_auth_method: none` en Authelia. |
| Logs de Mealie muestran `[SSL: CERTIFICATE_VERIFY_FAILED]` al arrancar | `OIDC_TLS_CACERTFILE` no apunta a la CA interna o el bind mount está vacío. | Verificar `ls -l /mnt/hd2t/apps/caddy/etc/ca/homelab-ca.crt` y que el path en el compose coincide. |
| Login OIDC funciona pero el usuario aparece como **no admin** | El claim `groups` del `id_token` no contiene `mealie-admins`, o `OIDC_GROUPS_CLAIM` está mal nombrado. | Revisar `users_database.yml` de Authelia y `OIDC_GROUPS_CLAIM=groups` (default). Decodificar el id_token con `jwt.io` para inspeccionar el claim. |
| Login OIDC devuelve `User is not authorized` | El usuario no pertenece ni a `mealie-users` ni a `mealie-admins`. | Añadir al usuario al grupo apropiado en Authelia y recargar. |
| Importación desde URL falla con "Could not find recipe" | El sitio no expone JSON-LD `schema.org/Recipe` y `recipe-scrapers` no tiene parser específico. | Crear la receta manualmente, o pedir el parser upstream en `recipe-scrapers/recipe-scrapers`. |
| Bulk URL import se queda colgado en "Processing..." indefinidamente | `recipe-scrapers` agota timeouts contra un dominio lento. | Reducir el lote a 10–20 URLs, o usar un dominio distinto. Mealie no tiene cancel button granular en 2.x. |
| Lista de la compra no se sincroniza entre dos móviles del mismo household | Ambos navegadores tienen la PWA cacheada con datos viejos. Polling cada ~10 s no ha pasado. | Verificar `Network → /api/groups/shopping/items` 200. Cerrar y reabrir la PWA en uno de los móviles (`Settings → Apps → Mealie → Force stop`). |
| PWA queda con icono pero al abrir falla con "Failed to fetch" | La CA interna **no** está instalada a nivel sistema en el móvil; el service worker rechaza el cert. | Instalar la CA en el almacén del SO (no solo del navegador). Reiniciar la PWA. |
| Tras subir versión (`v2.7.0` → `v2.8.0`) Mealie arranca con HTTP 500 | Migration alembic pendiente. La imagen ejecuta `alembic upgrade head` automáticamente, pero si fallara por incompat de schema queda manual. | `docker exec mealie alembic upgrade head`. **Antes de cualquier upgrade**: `borgmatic create --tag pre-mealie-upgrade-X.Y.Z`. |
| `borgmatic create` reporta `mealie.db cambió durante el archive` | El hook `before_backup` no se ejecutó (Borgmatic no encuentra el comando) o no se excluyó `mealie.db` del archive. | Verificar `before_backup:` apunta a `docker exec mealie /usr/local/bin/borg-pre-backup.sh` y `exclude_patterns:` lista `mealie.db`, `mealie.db-wal`, `mealie.db-shm`. |
| `data/recipes/` crece descontroladamente (>5 GiB en 1 año) | El operador sube fotos a 4K/originales sin recortar. | Mealie redimensiona a 1280px para `original.webp`, pero adjuntos manuales (PDFs de "instrucciones del paquete") **no** se redimensionan. Aceptar el coste o limpiar `Group Settings → Storage`. |
| `OIDC_AUTO_REDIRECT=true` pero el operador necesita login local urgente (Authelia caído) | La redirección automática se hace en frontend a partir del primer hit. | Usar `https://mealie.lan/login?direct=true`: parámetro reservado que bypassa el redirect y muestra el formulario local. |
| Health check falla con `wget: command not found` | La imagen oficial de Mealie incluye `wget`; pero si una variante ligera lo elimina, el healthcheck queda roto. | Sustituir por `curl -fsS http://127.0.0.1:9000/api/app/about` o usar `python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:9000/api/app/about').read()"`. |

---

## Decisiones que **no** se toman en este documento

- **PostgreSQL como backend**: SQLite es suficiente para 1–5 usuarios. Reabrible si la familia ampliada (>10 personas, varios households) lo requiere; la migración es soportada por Mealie con `mealie-cli` (export `.zip` de un Mealie SQLite, import en uno Postgres).
- **Cliente OIDC confidencial (con `client_secret`)**: PKCE puro es más simple para una SPA; el secret de un cliente confidencial no aporta seguridad adicional cuando el frontend lo distribuye. Reabrible si una versión futura de Mealie lo exige.
- **Auto-redirect a SSO desde el primer arranque**: bootstrap requiere acceso al login local para rotar la password de `changeme@example.com`. Una vez la familia está validada, `OIDC_AUTO_REDIRECT=true` puede activarse opcionalmente.
- **SMTP / notificaciones por email**: diferido a Mailrise (Fase 11). Sin SMTP, Mealie no envía emails de invitación; se materializan vía URL de invite copiada manualmente.
- **Apprise para webhooks de meal plan**: misma razón. Diferido a Fase 11.
- **OCR nativo de fotos de recetas**: Mealie no lo trae. Si se necesita, usar Paperless-ngx (`04-paperless-ngx.md`) y copiar el texto OCR resultante.
- **Sincronización con Google Calendar de planes de menú**: requeriría un script externo y credenciales OAuth de Google. No se documenta.
- **Reconocimiento de voz para añadir a la lista de la compra**: feature experimental en Mealie 2.x con dependencias LLM; no se activa.
- **Multi-household real (operador / pareja con listas separadas)**: el homelab estandariza un único household. Reabrible.
- **Métricas Prometheus**: Mealie no expone `/metrics`. cAdvisor cubre RAM/CPU, Uptime Kuma cubre disponibilidad, `docker logs` cubre auditoría. Diferido.
- **App móvil de comunidad (mealie-mobile)**: la PWA cubre el caso de uso. La app de comunidad es alternativa, no requisito; cada miembro de la familia decide.
- **Auto-backup nativo de Mealie** (`/api/admin/backups`): redundante con Borg. El operador puede ejecutarlo bajo demanda para tener un `.zip` portable (auditoría, migración a otro Mealie); no se automatiza.

---

## Referencias

- Documentación oficial Mealie: <https://docs.mealie.io/>
- Setup recomendado por la comunidad: <https://docs.mealie.io/documentation/getting-started/installation/sqlite/>
- Variables de configuración: <https://docs.mealie.io/documentation/getting-started/installation/backend-config/>
- Documentación OIDC: <https://docs.mealie.io/documentation/getting-started/authentication/oidc-v2/>
- Imagen Docker: <https://github.com/mealie-recipes/mealie/pkgs/container/mealie>
- Repositorio: <https://github.com/mealie-recipes/mealie>
- `recipe-scrapers` (motor de import por URL): <https://github.com/hhursev/recipe-scrapers>
- API REST (OpenAPI Swagger): `https://mealie.lan/docs` tras el despliegue
- App móvil de comunidad (Android): <https://github.com/MealieRecipes/Mealie-Mobile>
- Cooklang (formato de recetas en texto plano): <https://cooklang.org/>
- Documentos del homelab relacionados:
  - `02-docker/02-estructura-compose.md` — convenciones del compose y de las redes Docker.
  - `03-red/04-caddy.md` — TLS interno con CA y `(lan_tls)`.
  - `04-seguridad/01-authelia.md` — registro de clients OIDC y backend de usuarios.
  - `07-backups/02-borgmatic.md` — hooks `before_backup` con `VACUUM INTO`.
  - `11-productividad/01-vaultwarden.md` — patrón SQLite + hook de pre-backup del que este documento se inspira.
  - `11-productividad/03-linkding.md` — patrón Django/SQLite + OIDC + extensión de cliente.
