# Mealie

## Descripción

Despliegue de **Mealie** ([imagen `ghcr.io/mealie-recipes/mealie`](https://github.com/mealie-recipes/mealie/pkgs/container/mealie)) como **gestor de recetas + planificador de comidas + lista de la compra** del homelab. Mealie es una aplicación FastAPI (Python 3.12) + frontend Nuxt 3 (Vue.js + TypeScript) que **importa recetas desde URLs públicas** mediante `recipe-scrapers` (>500 sitios soportados: cookpad, allrecipes, sehat, sur la table, NYT Cooking…), las **normaliza** a un esquema interno (`Recipe`, `Ingredient`, `Step`, `Note`, `Tag`, `Category`, `Tool`), y permite **planificar el menú semanal** (`MealPlan`) con generación automática de **lista de la compra** (`ShoppingList`) por categorías de supermercado. Sus piezas mecánicas: backend FastAPI con Uvicorn + Gunicorn (uno o varios workers), motor `recipe-scrapers` (que hace `GET` con un User-Agent realista a la URL, parsea Schema.org `Recipe`/`HowToStep`/`HowToSection`, y cae a heurísticas de microformatos cuando falta), conversor Pint para escalado de unidades de medida, motor de **OCR opcional** (Tesseract via `recipe-scrapers` para fotos de recetas en papel — opt-in), y un task scheduler interno (`apscheduler`) para webhooks programados (export OPDS de la lista de la compra a Bring!, notificaciones del meal plan). Es la pieza canónica del homelab para "una receta entró por URL, se etiquetó por categoría, se planificó en el calendario, generó lista de la compra agrupada por pasillo".

Por qué exactamente esta arquitectura, y no otra:

1. **Mealie, no Tandoor Recipes, no Cooklang server, no Grocy, no Paprika.** Mealie es el sweet spot del homelab para gestión de recetas con planificador y lista de la compra: (a) **Tandoor Recipes** es la alternativa más cercana en features (importer, meal plan, shopping list, soporte multiidioma), pero su stack es Django + Celery + Redis + PostgreSQL + Beat (5 contenedores), pesa ~600-900 MB de RAM en idle vs los ~250-400 MB de Mealie, y su importer es más estricto (rechaza páginas sin Schema.org bien formado, mientras que Mealie cae a heurísticas y rara vez devuelve receta vacía); (b) **Cooklang server** apunta a un ecosistema basado en el formato `.cook` (texto plano markdown-like) — perfecto si el operador escribe sus recetas a mano, pero pésimo para "tiré la URL del NYT Cooking y quiero que me extraiga ingredientes y pasos"; (c) **Grocy** es ERP doméstico (despensa + stock + caducidades + recetas + chores + tareas), enorme y holístico, pero la parte de recetas es secundaria y muy pobre en importer (no tiene scraper de URLs nativo); (d) **Paprika** es propietaria, cloud-only, no hay versión self-hosted. Mealie es la talla justa: 1 contenedor de app + 0 contenedores extra (con SQLite) o + 1 PostgreSQL (con la variante PG), arquitectura simple, comunidad activa (>9 k estrellas, releases mensuales en 2024-2025, equipo de mantenedores reorganizado tras el fork v1 → v2 de 2024), y export oficial JSON/Markdown/ZIP que permite migrar fuera del homelab sin lock-in.
2. **Imagen `ghcr.io/mealie-recipes/mealie:<version>` upstream, no LinuxServer.io.** A diferencia de Bookstack ([`./02-bookstack.md`](./02-bookstack.md) §0 punto 2, donde LSIO bundlea Apache + PHP-FPM + nginx) o Calibre-Web ([`../09-multimedia/04-calibre-web.md`](../09-multimedia/04-calibre-web.md)), la imagen **upstream** de Mealie ya **es** monolítica para todo lo que es la app: bundlea Python 3.12 + FastAPI + Uvicorn + Gunicorn + Caddy interno (sirve el frontend Nuxt 3 build estático y proxy-pasa `/api/*` a Uvicorn) + supervisord + libpq (cliente PostgreSQL para la variante PG) + Crowdin runtime para i18n + recipe-scrapers + Pint + Pillow + Tesseract opcional. LSIO no publica `mealie`. La imagen upstream está mantenida por el equipo de Mealie (etiquetas `latest`, `vX.Y.Z`, `nightly`, `sha-<gitsha>` y digests inmutables), publica notas de release detalladas en cada minor, y es la que recomienda la propia documentación. La etiqueta usada en este doc es `vX.Y.Z` puntual (no `v1`, no `latest`, no `nightly`).
3. **SQLite, no PostgreSQL.** Mealie soporta nominalmente **ambos** (`DB_ENGINE=sqlite|postgres`) y la **documentación oficial recomienda PostgreSQL** "para deploys productivos" — pero el matiz importante es **qué cuenta como "productivo"**. Para un homelab familiar con 1-5 usuarios, ~1 000-3 000 recetas y ~100-300 meal plans históricos, SQLite tiene exactamente el perfil que pide la app: las escrituras son **del orden de decenas por día** (`POST /api/recipes` cuando el operador importa una URL; `PATCH /api/recipes/<slug>` al editar; `POST /api/groups/mealplans` semanal), las lecturas dominan abrumadoramente (visualización del libro, búsquedas, render del calendario semanal). SQLite con WAL absorbe ese throughput sin sudar. El motor PostgreSQL es valioso cuando hay >10 usuarios concurrentes editando o cuando la BD tiene >50 k recetas (escenarios de instancias multitenant tipo "Mealie como SaaS para varios hogares"). Aquí no es el caso. SQLite elimina **un contenedor entero** (no hay `postgres-mealie` aparte), un volumen, una red interna, dos secrets (password BD + password admin) — exactamente la misma decisión que tomó Linkding ([`./03-linkding.md`](./03-linkding.md) §0 punto 3) y FreshRSS ([`./07-freshrss.md`](./07-freshrss.md)). La línea `mealie` se añade en este doc al bloque `sqlite_databases:` de Borgmatic ([`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §6, líneas 537-548; el comentario "MariaDB: Bookstack, Mealie" en línea 528 está **mal redactado** — Mealie nunca usó MariaDB, soporta solo SQLite o PostgreSQL — este doc deja constancia y añade la entrada correcta bajo `sqlite_databases`). PostgreSQL queda como variante opt-in (§12.2) para el operador con un volumen de uso fuera de norma.
4. **Detrás de Caddy con CA interna, **sin** Authelia delante.** Coherente con la lógica de [`./03-linkding.md`](./03-linkding.md) §0 punto 4: Mealie tiene **dos perfiles de cliente** que se autentican contra `/api/*` y serían incompatibles con `forward_auth` de Authelia — (a) el **propio frontend Nuxt** que la imagen sirve en `/` se autentica vía `POST /api/auth/token` (devuelve un JWT firmado con `JWT_SECRET`), guarda el token en `localStorage`, y todas sus llamadas posteriores son `Authorization: Bearer <jwt>` contra `/api/*`; (b) las **apps móviles de la comunidad** ("Mealie Mobile" para Android, los integraciones con Home Assistant y con Bring!) usan **API tokens permanentes** generados desde la UI (`/user/profile/api-tokens`) y enviados también como `Authorization: Bearer <token>`. Authelia en `forward_auth` interceptaría todas las requests a `/api/*` redirigiendo a `https://auth.lan/?rd=...` — el frontend recibiría HTML en lugar de JSON y no podría ni hacer login. Y a diferencia de Paperless-ngx ([`./04-paperless-ngx.md`](./04-paperless-ngx.md) §0 punto 4), donde `/api/*` y la UI están en paths diferentes y se pueden separar con dos `handle` blocks en Caddy, **el frontend de Mealie y su API comparten host pero no tendría sentido proteger solo la UI** (que es un fichero `index.html` vacío que carga `/api/*` para vivir). La salida es Caddy reverse-proxy directo, sin Authelia. La regla `mealie.{{ env "LAN_DOMAIN" }}` **no** se añade a `access_control.rules` de Authelia ([`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md) línea 422 lista `paperless`, no `mealie`). La auth la lleva el propio Mealie (bcrypt + JWT). La variante con **OIDC** (Authelia como provider OIDC, Mealie como cliente OIDC) queda en §12.3 — es la forma correcta de aplicar SSO a Mealie sin romper su SPA.
5. **Datos persistentes en `hd2t`, en `/mnt/hd2t/services/mealie/`.** Coherente con [`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) §4.1 (loop "Fase 11 — Productividad", línea 241: `for svc in vaultwarden bookstack linkding paperless-ngx mealie stirling-pdf freshrss`). El árbol que se materializa en §3:
   - `/mnt/hd2t/services/mealie/.env` — configuración del stack (chmod 600).
   - `/mnt/hd2t/services/mealie/secrets/` — secretos individuales (`jwt_secret`, `default_password`): cada fichero `chmod 600 root:homelab`.
   - `/mnt/hd2t/services/mealie/data/` — bind mount de `/app/data/` del contenedor: `mealie_v1.0.0b.db` (SQLite con WAL), `recipes/` (imágenes y assets de cada receta organizadas por slug), `users/` (avatares), `backups/` (ZIPs de backup nativos de Mealie programados internamente), `groups/` (datos por "grupo" — Mealie soporta grupos lógicos de usuarios), `nltk_data/` (corpus pre-bajado para el parser de ingredientes — ~30 MB).
   - **Los assets de las recetas (`recipes/<slug>/images/`)** son lo más voluminoso del estado: una imagen original + thumbnails (`min-original.webp`, `tiny-original.webp`, `large-original.webp`). Para 1 000 recetas con foto, son ~500 MB-1 GB. Borgmatic los respalda directamente desde el bind mount.
6. **Imagen pinned a release puntual; Watchtower DESHABILITADO.** Misma regla del homelab: nunca `latest`, nunca `v1` rolling, nunca `nightly`. Mealie ha tenido al menos **dos breaking changes en migraciones de BD** entre minor releases (v1.0 → v1.4 introdujo `household_id` como FK obligatoria; v1.4 → v2.0 reorganizó la tabla `users` con un esquema de "households" anidados). Un `docker pull` automático seguido de `up -d` corre las migraciones Alembic incluidas en la imagen — y si una migración falla a las 04:00 de la mañana, el operador despierta con la app caída y la BD a medio migrar. Misma justificación que Bookstack ([`./02-bookstack.md`](./02-bookstack.md) §0 punto 6) y Paperless-ngx ([`./04-paperless-ngx.md`](./04-paperless-ngx.md) §0 punto 6) — y a diferencia de Linkding ([`./03-linkding.md`](./03-linkding.md) §0 punto 6), Mealie **lleva la etiqueta `com.centurylinklabs.watchtower.enable: "false"`**: el operador actualiza manualmente, leyendo previamente las release notes (sección "Breaking changes"), haciendo dump de la BD y export ZIP nativo de Mealie (§10.1). Está consistente con Watchtower §4.2 (línea ~458, lista de servicios con `Migraciones`).
7. **PUID/PGID `1000:1000` (`homelab`) para el proceso del contenedor, vía variables `PUID` / `PGID`.** La imagen oficial de Mealie soporta el patrón LSIO-like de `PUID`/`PGID` que su `docker-entrypoint.sh` (heredado de los scripts de bootstrap) traduce a `chown -R` en `/app/data/` antes de dropear privilegios. La diferencia con Linkding es importante: Linkding queda como `www-data` (UID 33) porque sus assets están aislados del host y el operador nunca los toca; Mealie en cambio guarda **fotos JPG/PNG de recetas** en `recipes/<slug>/images/` que el operador a menudo quiere subir desde su Mac vía Samba (drag&drop a `\\pi.lan\mealie-uploads\` para que un cron las indexe), o copiar desde `/mnt/hd2t/nextcloud/.../Recetas escaneadas/` con un `cp -r`. UID 1000 elimina la fricción del `sudo chown 33:33`. Coherente con la convención del homelab y con [`../06-almacenamiento/02-samba.md`](../06-almacenamiento/02-samba.md).
8. **`ALLOW_SIGNUP=false` desde el día 1.** Mealie permite por defecto (en algunas releases) que cualquier visitante de `/register` se registre como usuario con privilegios mínimos. En un homelab cerrado con DNS solo LAN + Tailscale, el riesgo es bajo (un atacante necesitaría estar dentro de la LAN o del tailnet) **pero distinto de cero**: cualquier dispositivo IoT comprometido en la LAN podría hacer `POST /api/users/register`. La política del homelab es: **`ALLOW_SIGNUP=false`** desde el primer arranque. Las altas se hacen desde la UI por el admin (`/admin/manage/users`) o por la API con un token admin. Las cuentas para los familiares se crean a mano en §7.5.
9. **Sin SMTP por defecto.** El homelab no tiene MTA (consistente con [`./01-vaultwarden.md`](./01-vaultwarden.md) §0 punto 4 y [`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md) §0 punto 7). Mealie usa email para: (a) reset de password (`/forgot-password` → genera token y manda link por email), (b) invitaciones de nuevos usuarios al "household". Sin SMTP: los resets se hacen desde la consola con `docker compose exec mealie mealie-cli reset-password <email> <new_password>` (script CLI provisto por Mealie 1.4+) o, en su defecto, editando el hash directamente en la BD (§11.1); las invitaciones se materializan creando la cuenta en `/admin/manage/users`. Variante con SMTP relay externo en §12.4.
10. **Superusuario inicial creado por env vars `BASE_URL` + `DEFAULT_EMAIL` + `DEFAULT_PASSWORD`, **luego rotado**.** En el primer arranque, si la BD está vacía, Mealie crea un usuario `admin@admin.com` (o el que diga `DEFAULT_EMAIL`) con la password de `DEFAULT_PASSWORD`. La práctica del homelab: setear ambas en `.env` para el bootstrap (§5.2), iniciar sesión, **rotar la password desde la UI** (`/user/profile`) y **comentar `DEFAULT_PASSWORD` en el `.env`** (Mealie no la vuelve a leer en arranques posteriores si el usuario ya existe, pero dejarla escrita en disco es un riesgo innecesario). La password real solo vive en la BD como bcrypt.
11. **`recipe-scrapers` necesita salida a internet (HTTP/HTTPS); el homelab opera en LAN + Tailscale pero **sí permite egress** a internet desde los contenedores.** Crítico no confundir el "alcance de red" (no exposición entrante) con la salida saliente: Mealie **necesita** poder hacer `GET https://www.allrecipes.com/recipe/...` para extraer la receta. El firewall del host (`ufw` con default-allow para outbound, [`../01-sistema/03-seguridad-base.md`](../01-sistema/03-seguridad-base.md)) y la red `homelab` Docker no bloquean egress. Pi-hole **sí** filtra DNS — si una URL apunta a un dominio bloqueado por las listas de ads/tracking, el scraper devolverá `DNS resolution failed`. En la práctica los sitios de recetas no están en listas de bloqueo.
12. **Backups híbridos: dump SQLite + bind mount de `data/`, además del export ZIP nativo de Mealie como capa adicional.** Mealie tiene un mecanismo de export ZIP propio (`POST /api/admin/backups`) que produce un `mealie_<timestamp>.zip` con: (a) JSON dump completo de todas las tablas (recetas, meal plans, listas de compra, usuarios, etiquetas), (b) imágenes en `recipes/`, (c) metadata. Es **portable** (un Mealie en otra máquina puede importarlo con `POST /api/admin/backups/import`) y a salvo de cambios de schema porque el formato JSON es estable entre minor releases. La política del homelab: **(1)** dump SQLite vía `sqlite_databases` de Borgmatic (granular, dedup-friendly, pero acoplado al schema actual); **(2)** bind mount de `data/recipes/` y `data/backups/` directamente en el repo Borg (cubre imágenes); **(3)** export ZIP nativo programado **mensual** por el scheduler interno de Mealie como "tornillo extra" portable, también respaldado por Borgmatic. Tres capas porque la pérdida de recetas (que el operador ha curado durante años) es tan irreplicable como la de Bookstack.

> **Alcance de red**: la UI de Mealie **no** publica puertos al host. Se accede únicamente vía `https://mealie.${LAN_DOMAIN}` (Caddy + CA interna, **sin** Authelia delante por defecto, justificado en §0 punto 4) y, una vez completada la fase Tailscale, vía `https://mealie.${TS_DOMAIN}`. El homelab opera en LAN + Tailscale, sin exposición a internet, sin Let's Encrypt público, sin port forwarding.

> **Alcance de auth**: una sola capa. Mealie maneja su propio login (bcrypt + JWT firmado con `JWT_SECRET`) tanto para humanos vía la UI como para apps/integraciones vía API tokens. Fail2ban ([`../04-seguridad/02-fail2ban.md`](../04-seguridad/02-fail2ban.md)) cubre intentos de fuerza bruta vía los logs de Caddy (los `4xx` quedan registrados aunque el filtrado fino de `/api/auth/token` requiere un jail dedicado, ver §12.5).

---

## Requisitos Previos

- **Sistema base operativo** según Fase 1: usuario `homelab` (UID 1000), `/mnt/hd2t/` montado, directorio `/mnt/hd2t/services/mealie/` ya creado por el bootstrap de [`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) §4.1 (loop "Fase 11 — Productividad", línea 241: `for svc in vaultwarden bookstack linkding paperless-ngx mealie stirling-pdf freshrss`).
- **Docker + red `homelab`** según Fase 2: red bridge `homelab` creada (`172.20.0.0/24`, `external: true`), convenciones de Compose ([`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §3 y §5).
- **Caddy desplegado** ([`../03-red/04-caddy.md`](../03-red/04-caddy.md)) con `lan_internal_tls` y `security_headers` operativos.
- **CA interna de Caddy** instalada en al menos un dispositivo del operador (navegador) y en cualquier dispositivo donde se quiera usar la app móvil de comunidad o las integraciones con Home Assistant — sin la CA confiada, las apps móviles arrancan pero el handshake TLS falla.
- **Pi-hole desplegado** ([`../03-red/02-pihole.md`](../03-red/02-pihole.md)) con la posibilidad de añadir un registro DNS local: `mealie.${LAN_DOMAIN}` → IP del host donde escucha Caddy.
- **Borgmatic operativo** ([`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md)). Este doc añade una entrada `mealie` al bloque `sqlite_databases:` (§9.2). El comentario en línea 528 del config Borgmatic actual dice "MariaDB: Bookstack, Mealie" — es **inexacto** (Mealie no usa MariaDB) y se documenta para corrección posterior; no bloquea el despliegue.
- **Watchtower desplegado** ([`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md)). Mealie **lleva** la etiqueta `com.centurylinklabs.watchtower.enable: "false"` (justificado en §0 punto 6 y consistente con Watchtower §4.2).
- **Fail2ban desplegado** ([`../04-seguridad/02-fail2ban.md`](../04-seguridad/02-fail2ban.md)) con el jail `caddy-status` ya activo (cubre login web Mealie al venir todos por Caddy con `4xx`).
- **`ufw` activo** según [`../01-sistema/03-seguridad-base.md`](../01-sistema/03-seguridad-base.md). No se añaden reglas: Mealie no publica puertos al host; el tráfico entra por Caddy.
- **Vaultwarden desplegado** ([`./01-vaultwarden.md`](./01-vaultwarden.md)). No es bloqueante, pero la convención del homelab es que el operador ya tenga Vaultwarden activo cuando empieza la Fase 11; cualquier credencial nueva (`JWT_SECRET`, password admin, API tokens generados desde la UI) se anota allí.
- **Salida a internet desde la red `homelab` operativa**. Crítico para `recipe-scrapers`: si el operador ha endurecido el firewall a default-deny en outbound, hay que abrir explícitamente `tcp/443` y `tcp/80` desde la red bridge `homelab` hacia internet. La configuración del homelab por defecto ([`../01-sistema/03-seguridad-base.md`](../01-sistema/03-seguridad-base.md)) es default-allow en outbound, así que típicamente no hace falta tocar nada.
- **Espacio libre en `hd2t`** ≥ 5 GB recomendado. El crecimiento típico de un hogar es ~200-500 recetas/año con imagen, ~1-3 MB cada una entre original + thumbnails → ~0.5-1.5 GB/año. Más backups ZIP nativos mensuales (~50 MB cada uno con 12 retenidos = ~600 MB). Reservar margen para la importación masiva inicial (un usuario que migra desde Paprika con 800 recetas mete ~1 GB de un tirón).
- **Comprobaciones rápidas**:
  ```bash
  # Red homelab existe:
  docker network inspect homelab --format '{{(index .IPAM.Config 0).Subnet}}'
  # Esperado: 172.20.0.0/24

  # Caddy está sano:
  docker inspect caddy --format '{{.Name}}: {{.State.Health.Status}}'

  # Path base existe y es del usuario homelab:
  stat -c '%U:%G %a %n' /mnt/hd2t/services/mealie
  # Esperado: homelab:homelab 750 /mnt/hd2t/services/mealie

  # Acceso a internet vía DNS (Pi-hole no bloquea allrecipes.com):
  docker run --rm --network homelab alpine sh -c 'apk add --no-cache curl >/dev/null 2>&1 && curl -fsSI https://www.allrecipes.com -o /dev/null && echo OK'
  # Esperado: OK
  ```

### Decisiones de diseño asumidas

| # | Decisión | Justificación breve | Variante en §12 |
|---|---|---|---|
| 1 | Imagen `ghcr.io/mealie-recipes/mealie:vX.Y.Z` | Upstream oficial, multi-arch, releases puntuales. | — |
| 2 | SQLite (`DB_ENGINE=sqlite`) | 1-5 usuarios, ~1-3 k recetas. PostgreSQL es overkill. | §12.2 PostgreSQL |
| 3 | Sin Authelia delante | El frontend Nuxt comparte host con `/api/*`; `forward_auth` rompería el SPA. | §12.3 OIDC con Authelia |
| 4 | Watchtower DESHABILITADO | Migraciones Alembic en cada minor release; el operador actualiza manualmente. | — |
| 5 | `PUID/PGID=1000:1000` (homelab) | Permite drag&drop de imágenes desde Samba sin `sudo chown`. | — |
| 6 | `ALLOW_SIGNUP=false` | Homelab cerrado; altas las hace el admin. | — |
| 7 | Sin SMTP | El homelab no tiene MTA. Reset de password por consola. | §12.4 SMTP relay |
| 8 | `BASE_URL=https://mealie.lan` desde el día 1 | Sin él, los links generados (reset, share, OPDS) llevan al host interno. | — |
| 9 | Backup triple: dump SQLite + bind mount + export ZIP mensual | Recetas son irreplicables. Tres capas redundantes. | — |
| 10 | Sin LDAP | Hay <5 humanos en el homelab; gestión manual es más barata. | §12.6 LDAP via Authelia |

---

## 1. Resumen de la arquitectura

```
                        ┌──────────────────────────────────────┐
   navegador ─HTTPS──▶  │ Caddy (host:443) ──http──┐           │
   app móvil ─HTTPS──▶  │ red homelab (172.20.0.0/24)          │
                        │                          │           │
                        │                          ▼           │
                        │                ┌──────────────────┐  │
                        │                │ mealie:9000      │  │
                        │                │ ┌──────────────┐ │  │
                        │                │ │ Caddy interno│ │  │
                        │                │ │ (sirve Nuxt) │ │  │
                        │                │ └─────┬────────┘ │  │
                        │                │       │ /api/*   │  │
                        │                │       ▼          │  │
                        │                │ ┌──────────────┐ │  │
                        │                │ │ Uvicorn +    │ │  │
                        │                │ │ FastAPI      │ │  │
                        │                │ │ + scheduler  │ │  │
                        │                │ └─────┬────────┘ │  │
                        │                │       │          │  │
                        │                │       ▼          │  │
                        │                │ /app/data/       │  │
                        │                └────┬─────────────┘  │
                        │                     │ bind mount     │
                        │                     ▼                │
                        │  /mnt/hd2t/services/mealie/data/     │
                        │  ├── mealie_v1.0.0b.db (+ wal/shm)   │
                        │  ├── recipes/<slug>/images/*.webp    │
                        │  ├── users/<uuid>/avatar.png         │
                        │  ├── backups/mealie_*.zip            │
                        │  ├── groups/<gid>/...                │
                        │  └── nltk_data/                      │
                        └──────────────────────────────────────┘

   recipe-scrapers ─https outbound─▶ allrecipes.com / cookpad.com / ...
                                     (a través del bridge homelab + NAT host)

   borgmatic ─pre─▶ sqlite_databases (mealie.db) ─copia a dumps/─▶ borg create
             ─bind mount─▶ /mnt/hd2t/services/mealie/data/recipes/ + backups/
```

**Componentes mecánicos del contenedor (un único PID 1):**

| Componente | Función | Puerto interno |
|---|---|---|
| **Caddy interno** (compilado en la imagen) | Sirve el frontend Nuxt 3 build (HTML/JS/CSS estáticos) en `/`; proxy-pasa `/api/*` y `/docs` a Uvicorn | `:9000` (escucha externa) |
| **Uvicorn + Gunicorn** (workers configurables) | Backend FastAPI; rutas `/api/*` y `/docs` (Swagger UI) | `:9091` (loopback interno) |
| **APScheduler** (thread interno de FastAPI) | Tareas programadas: backup ZIP automático, scraper de webhooks, refresh de token | — (dentro del proceso) |
| **SQLite** (file-based) | BD principal en `/app/data/mealie_v1.0.0b.db` con WAL | — (no escucha) |
| **NLTK + recipe-scrapers** | Parser de ingredientes + scraping de URLs públicas | — (módulos Python) |

**Flujo de auth (humano):**

1. Operador entra a `https://mealie.lan` → Caddy externo termina TLS → proxy plano a `mealie:9000`.
2. Caddy interno de Mealie sirve `index.html` del frontend Nuxt.
3. Frontend pide `GET /api/app/about` (sin auth) para detectar versión y branding.
4. Operador escribe credenciales en `/login` → frontend envía `POST /api/auth/token` con `{username, password}`.
5. Backend valida bcrypt vs `users.password_hash`, firma un JWT con `JWT_SECRET`, lo devuelve.
6. Frontend guarda el JWT en `localStorage`. Cada llamada subsiguiente lleva `Authorization: Bearer <jwt>`.
7. JWT caduca a los `TOKEN_TIME` minutos (default 48 h). Refresh transparente con `/api/auth/refresh`.

**Flujo de auth (app móvil / API token):**

1. Operador entra desde la UI a `/user/profile/api-tokens` y crea un token con descripción "Móvil Android Pixel 7".
2. Mealie genera un token random (no JWT — token opaco con prefijo `mealie_pat_`) y lo muestra **una sola vez**.
3. Operador lo copia a la app móvil.
4. App envía `Authorization: Bearer mealie_pat_<random>` en cada request a `/api/*`.
5. Backend valida el token consultando la tabla `api_tokens`; si vale, asocia la request al user_id del token.

**Flujo de scraper (importar receta desde URL):**

1. Operador pega URL en `/recipes/create/url` → frontend envía `POST /api/recipes/create-url` con `{url}`.
2. Backend resuelve el dominio, hace `GET <url>` con User-Agent realista.
3. `recipe-scrapers` parsea el HTML, busca Schema.org `Recipe` JSON-LD; cae a microformatos `hrecipe`/`v-recipe`; cae a heurísticas regex.
4. Si encuentra ingredientes/pasos, devuelve `{title, ingredients, instructions, image_url, ...}`.
5. Backend guarda la receta en BD, descarga la `image_url` con Pillow, genera 4 variantes (`min`, `tiny`, `large`, `original`) en `recipes/<slug>/images/`.

---

## 2. Plan de variables y archivos

### 2.1. Variables del stack (`.env.example` versionable)

`~/homelab/stacks/mealie/.env.example`:

```dotenv
# ─── Versión de la imagen ──────────────────────────────────────────────────
# https://github.com/mealie-recipes/mealie/releases  → release notes obligatorias antes de bump
MEALIE_IMAGE=ghcr.io/mealie-recipes/mealie:v2.5.0

# ─── Identidad del proceso del contenedor ──────────────────────────────────
PUID=1000
PGID=1000
TZ=Europe/Madrid

# ─── URL canónica + hosts confiados ────────────────────────────────────────
# Sin BASE_URL los links de share, OPDS export y reset email apuntan a localhost:9000.
BASE_URL=https://mealie.lan
HOST_IP=127.0.0.1                             # placeholder; Mealie ignora esta var pero la dejamos por consistencia con LSIO

# ─── Idioma y formato de medidas ───────────────────────────────────────────
DEFAULT_GROUP=Home                            # nombre del grupo default
DEFAULT_HOUSEHOLD=Familia                     # Mealie ≥ v2 usa "households" anidados al grupo
ALLOW_SIGNUP=false                            # JUSTIFICACIÓN §0 punto 8

# ─── Auth ──────────────────────────────────────────────────────────────────
TOKEN_TIME=48                                 # horas que dura el JWT antes de exigir refresh; 48h es default y razonable
SECURITY_USER_LOGIN_ATTEMPTS=5                # tras 5 intentos fallidos se bloquea la cuenta SECURITY_USER_LOCKOUT_TIME min
SECURITY_USER_LOCKOUT_TIME=24                 # horas de bloqueo tras superar attempts (default 24h)

# ─── Bootstrap del usuario admin (USAR Y ROTAR — ver §7.1) ────────────────
DEFAULT_EMAIL=admin@mealie.lan
# DEFAULT_PASSWORD se inyecta como secret; rotarla desde la UI tras el primer login y comentarla aquí
# DEFAULT_PASSWORD=<rotated>

# ─── Motor de BD ───────────────────────────────────────────────────────────
DB_ENGINE=sqlite
# Variante PostgreSQL (§12.2):
# DB_ENGINE=postgres
# POSTGRES_USER=mealie
# POSTGRES_PASSWORD=<from secret>
# POSTGRES_SERVER=postgres-mealie
# POSTGRES_PORT=5432
# POSTGRES_DB=mealie

# ─── Workers Uvicorn / Gunicorn ────────────────────────────────────────────
# La Pi 5 tiene 4 cores; con 1 worker Mealie consume ~250 MB RAM.
# 2 workers = ~400 MB y atienden búsquedas concurrentes mejor.
WEB_CONCURRENCY=2
MAX_WORKERS=2
WORKERS_PER_CORE=0.5

# ─── Logs ──────────────────────────────────────────────────────────────────
LOG_LEVEL=INFO                                # DEBUG solo durante troubleshooting; tira mucho ruido

# ─── Paths internos del contenedor (NO cambiar salvo upstream change) ─────
DATA_DIR=/app/data

# ─── Path del bind mount (host) ───────────────────────────────────────────
DATA_PATH=/mnt/hd2t/services/mealie/data

# ─── Recursos ──────────────────────────────────────────────────────────────
MEALIE_MEMORY_LIMIT=512M
MEALIE_CPU_LIMIT=1.5
```

> **Por qué cada bloque importa:**
>
> - **`MEALIE_IMAGE`** pinned. Las release notes son obligatorias antes de bump (§10.1).
> - **`PUID/PGID=1000/1000`** justificado en §0 punto 7.
> - **`BASE_URL`** sin scheme `https://` rompe los links generados que el frontend expone (share `/g/<token>`, export OPDS, reset email).
> - **`ALLOW_SIGNUP=false`** desde el primer arranque; las altas las hace el admin desde `/admin/manage/users`.
> - **`SECURITY_USER_LOGIN_ATTEMPTS=5`** + **`SECURITY_USER_LOCKOUT_TIME=24`** son la primera línea de defensa contra brute-force a nivel app (Fail2ban es la segunda, vía logs de Caddy — §12.5).
> - **`DEFAULT_EMAIL` + `DEFAULT_PASSWORD`** solo se usan en el primer arranque (creación del admin). Rotar password desde UI y comentar la var en §7.1.
> - **`WEB_CONCURRENCY=2`** equilibra throughput y RAM en una Pi 5. Con 1 worker la app es serial (un import largo de URL bloquea la UI 5-10 s). Con 2 workers eso desaparece. Con >2 los workers compiten por la BD SQLite y se ven lock waits.
> - **`DATA_DIR=/app/data`** es el path interno **canónico** de la imagen oficial. Cambiarlo es asking-for-trouble: hay rutas hardcodeadas para `recipes/`, `users/`, `backups/`.

### 2.2. `.env` real (`/mnt/hd2t/services/mealie/.env`)

Mismo contenido que `.env.example` con los valores reales rellenados. **No** se versiona en git: vive solo en `/mnt/hd2t/services/mealie/.env`, `chmod 600 root:homelab`. Justificado por [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §5.1.

Las variables sensibles (`DEFAULT_PASSWORD`) **no** van directamente en el `.env` — se materializan como ficheros separados en `secrets/` y se inyectan via la directiva `secrets:` del Compose o vía wrapper de `entrypoint`. La variante simple (sin Docker secrets) es exportarlas via `env_file` con `chmod 600` extricto. Este doc usa `env_file` por simplicidad y consistencia con Linkding ([`./03-linkding.md`](./03-linkding.md) §3.4).

### 2.3. Cómo se inyectan al contenedor

El `docker-compose.yml` (§4) usa `env_file: /mnt/hd2t/services/mealie/.env` (path absoluto fuera del repo) y, opcionalmente, re-declara cada variable en el bloque `environment:` para que `docker compose config` muestre el resultado interpolado completo (depuración). Patrón idéntico al de Linkding §2.3.

---

## 3. Preparar el árbol de datos

### 3.1. Crear el directorio del stack

```bash
sudo install -d -o homelab -g homelab -m 750 ~/homelab/stacks/mealie
```

El `docker-compose.yml` y el `.env.example` viven aquí, versionados en git. Los datos persistentes y el `.env` real viven en `/mnt/hd2t/services/mealie/`.

### 3.2. Crear el árbol de datos persistentes del servicio

```bash
# Bind mount principal (BD, recetas, imágenes, backups internos):
sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/services/mealie/data

# Subdirectorios que Mealie crea al primer arranque (los pre-creamos para
# fijar permisos sin esperar al chown del entrypoint):
for sub in recipes users backups groups nltk_data; do
  sudo install -d -o homelab -g homelab -m 750 "/mnt/hd2t/services/mealie/data/${sub}"
done

# Directorio de secretos (si se usa, ver §3.3 para la password admin):
sudo install -d -o root -g homelab -m 750 /mnt/hd2t/services/mealie/secrets

# Verificación:
ls -la /mnt/hd2t/services/mealie/
# Esperado:
#   drwxr-x--- ... homelab homelab data
#   drwxr-x--- ... root    homelab secrets
```

### 3.3. Generar el secret `JWT_SECRET` y la password inicial del admin

Mealie firma todos los JWTs con `JWT_SECRET`. Si el secret cambia entre arranques, todos los JWTs emitidos previamente se invalidan (los usuarios tienen que volver a loguear). Si el secret es predecible, un atacante con acceso al volumen puede falsificar tokens. Política del homelab: **64 bytes random**, generados una vez, fichero `chmod 600`.

```bash
# JWT_SECRET (un token largo random):
sudo install -m 600 -o root -g root /dev/null /mnt/hd2t/services/mealie/secrets/jwt_secret
openssl rand -hex 64 | sudo tee /mnt/hd2t/services/mealie/secrets/jwt_secret >/dev/null
sudo chmod 600 /mnt/hd2t/services/mealie/secrets/jwt_secret

# Password inicial del usuario admin (rotable, ver §7.1):
sudo install -m 600 -o root -g root /dev/null /mnt/hd2t/services/mealie/secrets/default_password
openssl rand -base64 24 | tr -d '\n' | sudo tee /mnt/hd2t/services/mealie/secrets/default_password >/dev/null
sudo chmod 600 /mnt/hd2t/services/mealie/secrets/default_password

# Verificación:
sudo ls -la /mnt/hd2t/services/mealie/secrets/
# Esperado: -rw------- 1 root root ... jwt_secret
#           -rw------- 1 root root ... default_password
```

> **Anotar la password admin en Vaultwarden** ([`./01-vaultwarden.md`](./01-vaultwarden.md)) **antes** de rotarla en la UI:
> ```bash
> sudo cat /mnt/hd2t/services/mealie/secrets/default_password
> # Copiar al item "Mealie - admin (initial)" en Vaultwarden
> ```

### 3.4. Materializar el `.env` real

```bash
sudo install -m 600 -o root -g homelab \
    ~/homelab/stacks/mealie/.env.example \
    /mnt/hd2t/services/mealie/.env

# Inyectar el JWT_SECRET y la DEFAULT_PASSWORD desde los secrets:
JWT="$(sudo cat /mnt/hd2t/services/mealie/secrets/jwt_secret)"
PWD="$(sudo cat /mnt/hd2t/services/mealie/secrets/default_password)"
sudo tee -a /mnt/hd2t/services/mealie/.env >/dev/null <<EOF

# ─── Inyectados desde secrets/ (no copiar a git) ────────────────────────
MEALIE_JWT_SECRET=${JWT}
DEFAULT_PASSWORD=${PWD}
EOF

# Verificar permisos finales (el .env contiene plaintext de password):
sudo ls -la /mnt/hd2t/services/mealie/.env
# Esperado: -rw------- 1 root homelab ... .env
```

### 3.5. Tabla resumen de permisos

| Path | Owner:Group | Modo | Por qué |
|---|---|---|---|
| `/mnt/hd2t/services/mealie/` | `homelab:homelab` | `750` | Directorio raíz del servicio. |
| `/mnt/hd2t/services/mealie/.env` | `root:homelab` | `600` | Plaintext de `JWT_SECRET` y `DEFAULT_PASSWORD`. Solo root lee. El grupo `homelab` se mantiene para que comandos de mantenimiento del operador puedan escribir vía `sudo`. |
| `/mnt/hd2t/services/mealie/secrets/` | `root:homelab` | `750` | Solo root entra y lista. |
| `/mnt/hd2t/services/mealie/secrets/jwt_secret` | `root:root` | `600` | Token sensible. |
| `/mnt/hd2t/services/mealie/secrets/default_password` | `root:root` | `600` | Password en plaintext (temporal hasta rotación). |
| `/mnt/hd2t/services/mealie/data/` | `homelab:homelab` | `750` | Bind mount; el contenedor escribe aquí como UID 1000 vía `PUID/PGID`. |
| `/mnt/hd2t/services/mealie/data/recipes/` | `homelab:homelab` | `750` | Imágenes y assets de las recetas. |
| `/mnt/hd2t/services/mealie/data/backups/` | `homelab:homelab` | `750` | ZIPs de backup nativos de Mealie. Borgmatic lo respalda directamente. |

### 3.6. Permisos para el proceso del contenedor

La imagen oficial Mealie ejecuta su `entrypoint.sh` como root al arranque y, tras un `chown -R ${PUID}:${PGID} /app/data`, dropea privilegios al UID `${PUID}` antes de ejecutar Caddy interno + Uvicorn. Por eso:

- El bind mount `/mnt/hd2t/services/mealie/data/` debe ser leído/escrito por UID 1000 → ya lo es.
- No se necesita `chmod g+w` en el host porque el contenedor opera con UID/GID 1000 directamente.

---

## 4. `docker-compose.yml`

`~/homelab/stacks/mealie/docker-compose.yml`:

```yaml
# ~/homelab/stacks/mealie/docker-compose.yml
# Stack: productivity (../02-docker/02-estructura-compose.md §1.1, fila
# 'productivity'). Datos en /mnt/hd2t/services/mealie/.

name: mealie

services:
  mealie:
    image: ${MEALIE_IMAGE}
    container_name: mealie
    hostname: mealie
    restart: unless-stopped

    env_file:
      - /mnt/hd2t/services/mealie/.env
    environment:
      # Identidad
      PUID: ${PUID}
      PGID: ${PGID}
      TZ: ${TZ}

      # URL y branding
      BASE_URL: ${BASE_URL}
      ALLOW_SIGNUP: ${ALLOW_SIGNUP}
      DEFAULT_GROUP: ${DEFAULT_GROUP}
      DEFAULT_HOUSEHOLD: ${DEFAULT_HOUSEHOLD}

      # BD
      DB_ENGINE: ${DB_ENGINE}

      # Auth
      MEALIE_JWT_SECRET: ${MEALIE_JWT_SECRET}
      TOKEN_TIME: ${TOKEN_TIME}
      SECURITY_USER_LOGIN_ATTEMPTS: ${SECURITY_USER_LOGIN_ATTEMPTS}
      SECURITY_USER_LOCKOUT_TIME: ${SECURITY_USER_LOCKOUT_TIME}

      # Bootstrap admin (rotar y comentar tras §7.1)
      DEFAULT_EMAIL: ${DEFAULT_EMAIL}
      DEFAULT_PASSWORD: ${DEFAULT_PASSWORD}

      # Workers
      WEB_CONCURRENCY: ${WEB_CONCURRENCY}
      MAX_WORKERS: ${MAX_WORKERS}
      WORKERS_PER_CORE: ${WORKERS_PER_CORE}

      # Logs
      LOG_LEVEL: ${LOG_LEVEL}

    volumes:
      - ${DATA_PATH}:/app/data:rw

    networks:
      - homelab

    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true

    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://127.0.0.1:9000/api/app/about >/dev/null || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 90s

    deploy:
      resources:
        limits:
          memory: ${MEALIE_MEMORY_LIMIT}
          cpus: '${MEALIE_CPU_LIMIT}'

    labels:
      # JUSTIFICACIÓN §0 punto 6: Watchtower DESHABILITADO; el operador
      # actualiza manualmente leyendo release notes y haciendo dump previo.
      com.centurylinklabs.watchtower.enable: "false"

networks:
  homelab:
    external: true
```

### 4.1. Por qué cada bloque

| Línea | Por qué |
|---|---|
| `name: mealie` | Hace el `compose project name` explícito en lugar de inferirlo del directorio. Aparece en `docker compose ls`. |
| `image: ${MEALIE_IMAGE}` | Tag completo desde `.env`. Cualquier upgrade es grep-able y `git diff`-able. |
| `container_name: mealie` | DNS interno: Caddy llama `http://mealie:9000`. Sin `container_name` Compose le pondría `mealie-mealie-1`. |
| `hostname: mealie` | Alineado con `container_name`. |
| `restart: unless-stopped` | Auto-arranque tras reboot. |
| **No** `user:` | La imagen usa `PUID`/`PGID` (env vars) en su entrypoint para hacer `chown -R` y dropear privilegios — **no** se debe usar el campo `user:` del Compose, porque ese fija el UID antes de ejecutar el entrypoint y rompe el `chown`. Justificado en §0 punto 7. |
| `env_file: /mnt/hd2t/services/mealie/.env` | Path absoluto, fuera del repo. Justificado en [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §5.1. |
| `environment:` (re-declaración explícita) | Aunque `env_file` ya carga las vars, declararlas aquí explícitamente sirve de contrato: `docker compose config` muestra siempre la lista efectiva interpolada. |
| `volumes: - ${DATA_PATH}:/app/data:rw` | Único bind mount. `/app/data` es el path interno canónico. |
| `networks: [homelab]` | Sin red interna lateral — Mealie no tiene BD aparte (SQLite). En la variante PostgreSQL (§12.2) se añade un `mealie-internal` para aislar `postgres-mealie`. |
| `cap_drop: ALL` | Patrón estándar del homelab. Mealie no necesita ningún capability (Uvicorn corre como UID 1000, no abre puertos privilegiados, no toca raw sockets). |
| `security_opt: no-new-privileges:true` | Bloquea `setuid`/`setgid` dentro del contenedor. Defensa en profundidad. |
| `healthcheck: /api/app/about` | Endpoint canónico sin auth de Mealie 1.x+ (devuelve `200 OK` con JSON `{version, "production": true, ...}`). Probado en cada release. |
| `start_period: 90s` | Mealie tarda ~30-60 s en arrancar la primera vez (corre migraciones Alembic + descarga corpus NLTK + compila Caddy interno + warm-up de Pillow). 90 s deja margen sin marcar `unhealthy` falso, especialmente tras un upgrade que añada migraciones nuevas. |
| `deploy.resources.limits` | 512 MB de RAM y 1.5 CPUs. Mealie consume ~200-400 MB en uso normal con 2 workers; 512 MB cubre picos durante import masivo de URLs. La Pi 5 (8 GB) no lo nota. |
| `labels: watchtower.enable: "false"` | Mealie **NO** está en el grupo de auto-update. Justificado en §0 punto 6. |
| `networks.homelab.external: true` | Convención §4.3 de estructura-compose. |

### 4.2. Validar antes de levantar

```bash
cd ~/homelab/stacks/mealie
docker compose --env-file /mnt/hd2t/services/mealie/.env config
```

La salida debe mostrar:

- `image: ghcr.io/mealie-recipes/mealie:v2.5.0`,
- el bloque `environment:` totalmente interpolado (sin `${...}`),
- `BASE_URL: https://mealie.lan`,
- `ALLOW_SIGNUP: "false"` (atención al type — algunos releases de Mealie son estrictos con string vs bool),
- `MEALIE_JWT_SECRET: <hex-128-chars>` (validar que está, **no** copiar a logs),
- `DEFAULT_PASSWORD: <plaintext>` (validar que está, **no** copiar a logs),
- el volume `/mnt/hd2t/services/mealie/data:/app/data:rw`,
- `labels: com.centurylinklabs.watchtower.enable: "false"`.

Si alguna variable aparece como `${...}` literal, el `env_file` no se está cargando (revisar permisos: el wrapper `docker` corre como `homelab`, así que el `.env` debe ser legible por `g+r`).

---

## 5. Despliegue

### 5.1. Levantar el stack

```bash
cd ~/homelab/stacks/mealie
docker compose --env-file /mnt/hd2t/services/mealie/.env up -d
```

Salida esperada:

```
[+] Running 2/2
 ⠿ Network homelab     External
 ⠿ Container mealie    Started
```

### 5.2. Estado del contenedor

```bash
# Inicialmente (~30-60 s) estará "starting":
docker inspect mealie --format '{{.State.Health.Status}}'

# Esperar hasta "healthy":
until [ "$(docker inspect mealie --format '{{.State.Health.Status}}')" = "healthy" ]; do
  sleep 5
done
echo "Mealie listo."
```

Logs del primer arranque (esperados):

```bash
docker logs mealie --tail 200
```

Buscar en orden:

1. `[entrypoint] Setting UID/GID to 1000:1000` — el chown del bind mount ha terminado.
2. `INFO:     Will watch for changes in these directories: ['/app']` — Uvicorn arranca.
3. `INFO:     Started server process [PID]` — workers operativos.
4. `INFO:     Application startup complete.` — FastAPI listo.
5. `INFO:     Default user 'admin@mealie.lan' created.` — bootstrap del admin OK.
6. `[NLTK] data already downloaded` — corpus presente (o `[NLTK] downloading punkt...` si es primera vez).
7. `INFO:     127.0.0.1:NNNN - "GET /api/app/about HTTP/1.1" 200 OK` — el healthcheck pasa.

Si no aparece "Default user ... created" en los primeros 60 s, revisar `DEFAULT_EMAIL` + `DEFAULT_PASSWORD` en el `.env` (§11.4).

### 5.3. Verificar ficheros físicos

```bash
sudo ls -la /mnt/hd2t/services/mealie/data/
# Esperado tras el primer arranque:
#   mealie_v1.0.0b.db          (~ 1-2 MB)
#   mealie_v1.0.0b.db-wal      (presente con WAL activo)
#   mealie_v1.0.0b.db-shm      (presente con WAL activo)
#   recipes/                   (vacío hasta primera receta)
#   users/                     (con avatar default del admin)
#   backups/                   (vacío hasta primer backup automático mensual)
#   groups/Home/               (grupo default)
#   nltk_data/                 (~ 30 MB, corpus pre-bajado)

# Permisos correctos (UID 1000):
stat -c '%U:%G %n' /mnt/hd2t/services/mealie/data/mealie_v1.0.0b.db
# Esperado: homelab:homelab /mnt/hd2t/services/mealie/data/mealie_v1.0.0b.db
```

### 5.4. Smoke check antes de publicar por Caddy

Mealie responde solo dentro de la red `homelab`. Smoke desde el host:

```bash
# Lanzar un curl efímero dentro de la red homelab:
docker run --rm --network homelab alpine sh -c \
  'apk add --no-cache curl >/dev/null 2>&1 && curl -fsS http://mealie:9000/api/app/about | head -c 200'
```

Esperado: JSON con `{"production":true,"version":"v2.5.0","demoStatus":false,"allowSignup":false,...}`.

Si el campo `allowSignup` es `true`, revisar `ALLOW_SIGNUP=false` en el `.env` (§11.5).

### 5.5. Backup inicial del estado virgen

Antes de empezar a meter recetas reales, se respalda el estado vacío para tener una baseline:

```bash
sudo mkdir -p /mnt/hd2t/backups/mealie/initial
sudo cp -a /mnt/hd2t/services/mealie/data /mnt/hd2t/backups/mealie/initial/data-$(date +%F)
sudo tar -caf /mnt/hd2t/backups/mealie/initial/mealie-virgin-$(date +%F).tar.zst -C /mnt/hd2t/services/mealie data
```

---

## 6. Integración con Caddy

### 6.1. Añadir el bloque `mealie.{$LAN_DOMAIN}` al `Caddyfile`

`~/homelab/stacks/proxy/Caddyfile` (extracto):

```caddy
# ───── Mealie ────────────────────────────────────────────────────────────
mealie.{$LAN_DOMAIN} {
    import lan_internal_tls
    import security_headers

    # Frontend Nuxt + API expuestos en el mismo host:9000.
    # No se separa /api/* — el SPA y la API comparten origen (justificado en §0 punto 4).
    reverse_proxy mealie:9000 {
        # Pasar el host original — Mealie usa BASE_URL para los links pero
        # respeta X-Forwarded-Host para algunos casos de scraping reverse:
        header_up Host {http.reverse_proxy.upstream.hostport}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
        header_up X-Forwarded-Host {host}

        # Algunas requests del frontend (upload de imágenes >5 MB) tardan;
        # subir el timeout de read body para evitar 502 prematuros.
        transport http {
            read_timeout 60s
            write_timeout 60s
        }
    }
}

# Variante Tailscale (preparada, no activa hasta Fase 3.5 + cert):
# mealie.{$TS_DOMAIN} {
#     tls /etc/caddy/ts/mealie.{$TS_DOMAIN}.crt /etc/caddy/ts/mealie.{$TS_DOMAIN}.key
#     import security_headers
#     reverse_proxy mealie:9000 { ... }
# }
```

### 6.2. Recargar Caddy

```bash
docker exec caddy caddy validate --config /etc/caddy/Caddyfile
docker exec caddy caddy reload --config /etc/caddy/Caddyfile
```

Si `validate` falla, revisar la indentación del bloque (Caddyfile es sensible a tabs vs spaces dentro del mismo fichero).

### 6.3. Registro DNS local en Pi-hole

```bash
# Vía UI de Pi-hole: Local DNS → DNS Records → Add
# Nombre:  mealie.lan         (sustituir lan por ${LAN_DOMAIN} si difiere)
# IP:      192.168.1.10       (IP del host con Caddy)
```

O equivalente vía CLI dentro del contenedor Pi-hole, según [`../03-red/02-pihole.md`](../03-red/02-pihole.md).

### 6.4. Probar el acceso desde el navegador

Desde un dispositivo con la CA interna de Caddy ya confiada:

1. Navegar a `https://mealie.lan`.
2. Debería aparecer el frontend Nuxt con el formulario de login.
3. Login con `admin@mealie.lan` + password de `secrets/default_password`.
4. Validar que entra al dashboard y que la URL en el browser es `https://mealie.lan/...` (no `localhost:9000`).

Si aparece advertencia de cert: la CA interna de Caddy no está confiada en ese dispositivo (no es bloqueante, se puede aceptar excepción para testing — pero las apps móviles **sí** la requerirán confiada).

### 6.5. Acceso vía Tailscale (preparado, no activo)

El bloque `mealie.{$TS_DOMAIN}` está comentado en el Caddyfile. Se activa cuando se llega a [`../03-red/05-tailscale.md`](../03-red/05-tailscale.md) §X.X (emisión de cert con `tailscale cert` y descomentado del bloque). Tras ello, Mealie es accesible desde fuera de la LAN vía VPN sin tocar nada más.

---

## 7. Configuración post-despliegue

### 7.1. Login del operador y rotación de la password del admin

1. Ir a `https://mealie.lan` y loguear con `admin@mealie.lan` + password de `default_password`.
2. Click en el avatar (esquina superior derecha) → **Manage Account** → **Change Password**.
3. Generar password fuerte (`openssl rand -base64 24`) y guardarla en Vaultwarden bajo "Mealie - admin".
4. Confirmar el cambio.
5. **Editar el `.env`** y comentar (o borrar) la línea `DEFAULT_PASSWORD=...`:
   ```bash
   sudo sed -i 's/^DEFAULT_PASSWORD=/# DEFAULT_PASSWORD=/' /mnt/hd2t/services/mealie/.env
   ```
6. Borrar el secret en disco (ya no es válido):
   ```bash
   sudo shred -u /mnt/hd2t/services/mealie/secrets/default_password
   ```

> **Importante**: Mealie **no** vuelve a leer `DEFAULT_PASSWORD` si el usuario ya existe (a diferencia de Paperless-ngx que sí lo hace). Aun así, la práctica del homelab es **borrarla** del `.env` por higiene mínima de secretos.

### 7.2. Configurar settings del sitio

Desde la UI:

- **Settings** (`/admin/site-settings`):
  - Site Name: "Cocina del Homelab" (o lo que el operador quiera).
  - Default Recipe Theme: "Classic" o "Cards".
  - Language: `es-ES` (interfaz en español; `recipe-scrapers` sigue funcionando con URLs en cualquier idioma).
  - First Day of Week: Lunes.
  - Time Format: 24 h.
  - Default Measurement System: Metric.
- **Backup Settings** (`/admin/backups`):
  - **Schedule**: cada 1 mes (1 backup ZIP/mes auto-generado).
  - Retention: 6 (los 6 últimos backups en disco; los anteriores se borran).
  - Mealie respalda en `/app/data/backups/`. Borgmatic los recoge desde el bind mount (no hay que tocar nada extra).

### 7.3. Generar el token API para apps móviles

1. Avatar → **Manage Account** → **API Tokens**.
2. **Create New Token**:
   - Description: `Móvil Android Pixel 7` (o similar).
   - **Generate**.
3. Mealie muestra el token **una sola vez**. Copiar a Vaultwarden bajo "Mealie - API Móvil".
4. Configurar la app móvil con: URL = `https://mealie.lan`, Token = `mealie_pat_<random>`.

### 7.4. Crear cuentas para familiares (opcional)

Desde `/admin/manage/users` → **Create User**:

- Email: `familia@mealie.lan` (cualquier email, no requiere ser real).
- Username: `familia`.
- Group: Home (default).
- Household: Familia (default).
- Admin: **NO** (rol `user`).
- Password: generar con `openssl rand -base64 24` y compartir con el familiar por canal seguro.

Cada usuario:

- Ve sus propias **Recipe Notes** (notas privadas por receta).
- Comparte el **libro común de recetas** (a nivel grupo/household).
- Tiene su propia **Meal Plan** (calendario individual) y **Shopping List** (lista de la compra individual o compartida según se elija al crearla).

### 7.5. Verificación post-despliegue

- [ ] Login con admin OK.
- [ ] Password admin rotada y `DEFAULT_PASSWORD` comentada en `.env` y secret borrado.
- [ ] `ALLOW_SIGNUP=false` confirmado en `/api/app/about` JSON.
- [ ] Site name + idioma + medidas configurados.
- [ ] Backup automático mensual programado.
- [ ] Token API de móvil generado y guardado en Vaultwarden.
- [ ] Familiares (si aplica) creados con rol `user`.

---

## 8. Verificación

### 8.1. Contenedor sano y permisos correctos

```bash
docker inspect mealie --format '{{.Name}}: {{.State.Health.Status}}'
# Esperado: /mealie: healthy

# Permisos del bind mount (UID 1000):
stat -c '%U:%G %a %n' /mnt/hd2t/services/mealie/data/mealie_v1.0.0b.db
# Esperado: homelab:homelab 644 ...
```

### 8.2. Mealie no escucha al host

```bash
# El puerto 9000 NO debe estar publicado al host:
sudo ss -tlnp | grep ':9000' || echo "OK: 9000 no expuesto"
```

Si aparece algo, hay un `ports:` extraviado en el Compose (el doc no lo declara — debe estar vacío).

### 8.3. UI accesible vía Caddy

```bash
curl -fsS --resolve mealie.lan:443:127.0.0.1 https://mealie.lan/api/app/about | jq
# Esperado:
# {
#   "version": "v2.5.0",
#   "production": true,
#   "demoStatus": false,
#   "allowSignup": false,
#   ...
# }
```

### 8.4. API accesible con token

```bash
TOKEN="mealie_pat_<el token generado en §7.3>"
curl -fsS -H "Authorization: Bearer ${TOKEN}" \
  --resolve mealie.lan:443:127.0.0.1 \
  https://mealie.lan/api/users/self | jq '.email'
# Esperado: "admin@mealie.lan"
```

### 8.5. Importar una receta de prueba

```bash
TOKEN="mealie_pat_<el token>"
curl -fsS -X POST \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  --resolve mealie.lan:443:127.0.0.1 \
  https://mealie.lan/api/recipes/create-url \
  -d '{"url":"https://www.allrecipes.com/recipe/213742/cheesy-chicken-broccoli-and-rice-casserole/"}'
# Esperado: devuelve el slug de la receta importada (ej "cheesy-chicken-broccoli-and-rice-casserole")
```

Verificar que el directorio físico se creó:

```bash
ls /mnt/hd2t/services/mealie/data/recipes/<slug>/images/
# Esperado: original.webp, min-original.webp, tiny-original.webp, large-original.webp
```

### 8.6. Persistencia tras reboot

```bash
docker compose -f ~/homelab/stacks/mealie/docker-compose.yml down
docker compose --env-file /mnt/hd2t/services/mealie/.env -f ~/homelab/stacks/mealie/docker-compose.yml up -d
sleep 30
curl -fsS --resolve mealie.lan:443:127.0.0.1 https://mealie.lan/api/app/about | jq '.version'
# La receta importada en §8.5 sigue presente: GET /api/recipes/<slug>
```

### 8.7. Backup hooks Borgmatic ejecutándose

Tras añadir la entrada SQLite en §9.2:

```bash
sudo borgmatic --dry-run --verbosity 1 2>&1 | grep -i mealie
# Esperado: "Dumping SQLite database 'mealie' ..."
```

### 8.8. Lista de verificación

- [ ] `docker inspect mealie` → `healthy`.
- [ ] Puerto 9000 NO expuesto al host.
- [ ] `https://mealie.lan/api/app/about` devuelve JSON con `production:true` y `allowSignup:false`.
- [ ] Token API funciona (`/api/users/self` responde).
- [ ] Import de URL crea receta y materializa imágenes en disco.
- [ ] Reboot del contenedor preserva recetas, usuarios y settings.
- [ ] `borgmatic --dry-run` reconoce la entrada `mealie` en `sqlite_databases`.

---

## 9. Backup

### 9.1. Qué se respalda y qué no

| Capa | Qué | Cómo | Frecuencia |
|---|---|---|---|
| **A. Dump SQLite** | `mealie_v1.0.0b.db` consistente (vía `sqlite3 .backup`) | Borgmatic `sqlite_databases:` | Diaria (la del global) |
| **B. Bind mount completo** | `data/recipes/`, `data/users/`, `data/groups/`, `data/backups/`, `data/nltk_data/` | Borgmatic source path | Diaria (la del global) |
| **C. Export ZIP nativo** | Mealie genera `mealie_<timestamp>.zip` en `data/backups/` | Scheduler interno de Mealie | Mensual (configurable §7.2) |
| **D. Storage encryption del JWT_SECRET** | Si se rotan tokens y se quiere recuperarlos, el `JWT_SECRET` necesita acompañar al dump | Hook `before_backup` copia `secrets/jwt_secret` a `dumps/mealie/` | Diaria |
| **NO se respalda** | `mealie_v1.0.0b.db-wal` y `-shm` directamente (transitorios; el dump SQLite los consolida) | — | — |

> **Por qué tres capas redundantes**: las recetas son irreplicables (curación manual de años). La capa A (dump SQLite) es eficiente en dedup pero acoplada al schema actual. La capa B (bind mount) cubre las imágenes que el dump no toca. La capa C (ZIP nativo) es portable a otra Mealie (o a otro servicio que importe el formato) y a salvo de cambios de schema entre minor releases.

### 9.2. Patrón Borgmatic — respaldo SQLite + storage encryption

Añadir al `~/homelab/stacks/backups/borgmatic/borgmatic-config.yaml` (extiende §6 de [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md)):

```yaml
sqlite_databases:
  # ... entradas existentes (authelia, uptime-kuma, vaultwarden, linkding, freshrss) ...
  - name: mealie
    path: /mnt/hd2t/services/mealie/data/mealie_v1.0.0b.db

before_backup:
  # ... entradas existentes ...
  # Mealie: copiar el JWT_SECRET junto al dump (sin él, los API tokens
  # emitidos previamente quedan inútiles tras restore — fuerza re-login).
  - 'install -m 600 /mnt/hd2t/services/mealie/secrets/jwt_secret /mnt/hd2t/backups/dumps/mealie/jwt_secret-$(date +%F)'

source_directories:
  # ... entradas existentes ...
  - /mnt/hd2t/services/mealie/data
```

> **Atención**: el path del fichero SQLite (`mealie_v1.0.0b.db`) puede cambiar en futuras releases mayores de Mealie (si el equipo decide bumpear el sufijo `_v1.0.0b` a `_v2.0.0`, el path cambiará). Documentar el path actual en una nota junto al `.env` y verificar tras cada upgrade mayor.

### 9.3. Restore (resumen)

Procedimiento completo en [`../07-backups/03-backup-docker-volumes.md`](../07-backups/03-backup-docker-volumes.md) §4.8 (servicios SQLite simples). Resumen:

```bash
# 1. Detener Mealie:
docker compose -f ~/homelab/stacks/mealie/docker-compose.yml down

# 2. Restaurar el bind mount completo desde Borg:
sudo borg extract /mnt/hd2t/borg/repo::mealie-2025-XX-XX \
  mnt/hd2t/services/mealie/data/

# 3. Restaurar el dump SQLite (sobreescribe el .db restaurado por el bind mount):
sudo borgmatic restore --archive mealie-2025-XX-XX --database mealie

# 4. Restaurar el jwt_secret:
sudo cp /mnt/hd2t/backups/dumps/mealie/jwt_secret-2025-XX-XX \
        /mnt/hd2t/services/mealie/secrets/jwt_secret

# 5. Levantar el stack:
docker compose --env-file /mnt/hd2t/services/mealie/.env \
  -f ~/homelab/stacks/mealie/docker-compose.yml up -d

# 6. Verificar:
sleep 30
curl -fsS --resolve mealie.lan:443:127.0.0.1 https://mealie.lan/api/app/about | jq '.version'
```

### 9.4. Smoke test mensual

El primer lunes de cada mes (consistente con [`../13-operaciones/01-mantenimiento-periodico.md`](../13-operaciones/01-mantenimiento-periodico.md)):

```bash
# Listar archives de Borg con prefijo "mealie":
borgmatic list --archive 'mealie-*'

# Restaurar el último a /tmp y comprobar que la BD abre:
sudo borgmatic restore --archive $(borgmatic list --json | jq -r '.[0].archive') \
  --database mealie --destination /tmp/mealie-restore

sqlite3 /tmp/mealie-restore/mealie_v1.0.0b.db 'SELECT COUNT(*) FROM recipes;'
# Esperado: número >0 (cuántas recetas tiene la última copia)

# Limpieza:
sudo rm -rf /tmp/mealie-restore
```

---

## 10. Operaciones cotidianas

### 10.1. Upgrade (Watchtower DESHABILITADO)

Mealie **no** se actualiza automáticamente. El procedimiento manual:

1. **Leer release notes**: https://github.com/mealie-recipes/mealie/releases. Buscar sección "Breaking changes" y "Database migrations".
2. **Backup previo**:
   ```bash
   # Dump SQLite + export ZIP nativo:
   docker exec mealie sh -c 'sqlite3 /app/data/mealie_v1.0.0b.db ".backup /app/data/backups/pre-upgrade-$(date +%F).db"'
   # (o disparar export ZIP desde la UI: /admin/backups → Create Backup)
   ```
3. **Bump del tag**:
   ```bash
   sudo sed -i 's|MEALIE_IMAGE=.*|MEALIE_IMAGE=ghcr.io/mealie-recipes/mealie:v2.6.0|' /mnt/hd2t/services/mealie/.env
   git -C ~/homelab diff stacks/mealie/.env.example  # opcional: actualizar el example también
   ```
4. **Pull + recreate**:
   ```bash
   cd ~/homelab/stacks/mealie
   docker compose --env-file /mnt/hd2t/services/mealie/.env pull
   docker compose --env-file /mnt/hd2t/services/mealie/.env up -d
   ```
5. **Watch logs** (las migraciones Alembic corren al arranque):
   ```bash
   docker logs -f mealie
   # Buscar líneas: "Running migration ... -> ..." y final "Application startup complete."
   ```
6. **Smoke check**:
   ```bash
   curl -fsS --resolve mealie.lan:443:127.0.0.1 https://mealie.lan/api/app/about | jq '.version'
   # Debe mostrar la nueva versión.
   ```
7. Si algo falla, **rollback**:
   ```bash
   # Restaurar el .db pre-upgrade:
   docker compose down
   sudo cp /mnt/hd2t/services/mealie/data/backups/pre-upgrade-YYYY-MM-DD.db \
           /mnt/hd2t/services/mealie/data/mealie_v1.0.0b.db
   # Volver al tag anterior:
   sudo sed -i 's|MEALIE_IMAGE=.*|MEALIE_IMAGE=ghcr.io/mealie-recipes/mealie:v2.5.0|' /mnt/hd2t/services/mealie/.env
   docker compose up -d
   ```

### 10.2. Añadir un usuario nuevo

UI: `/admin/manage/users` → **Create User** (ver §7.4).

API:
```bash
TOKEN="<admin token>"
curl -fsS -X POST -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  https://mealie.lan/api/admin/users \
  -d '{"email":"x@mealie.lan","username":"x","fullName":"X","password":"...","admin":false}'
```

### 10.3. Reset de password (sin SMTP)

Mealie 1.4+ trae un CLI:

```bash
docker exec mealie mealie-cli reset-password admin@mealie.lan 'NewPasswordHere'
```

Si la imagen actual no expone `mealie-cli`, alternativa directa SQL (UID 1000):

```bash
# Generar bcrypt nuevo (Python interactivo dentro del contenedor):
docker exec -it mealie python3 -c \
  'from passlib.context import CryptContext; \
   ctx = CryptContext(schemes=["bcrypt"], deprecated="auto"); \
   import getpass; print(ctx.hash(getpass.getpass("New password: ")))'

# Update directo en SQLite (sustituir el hash):
docker exec mealie sqlite3 /app/data/mealie_v1.0.0b.db \
  "UPDATE users SET password = '<bcrypt_hash>' WHERE email = 'admin@mealie.lan';"
```

### 10.4. Rotar el JWT_SECRET

**Atención**: rotar `JWT_SECRET` invalida **todos los JWTs y tokens API existentes** — todos los usuarios y todas las apps tienen que re-loguear y re-emitir tokens.

```bash
# 1. Generar nuevo secret:
NEW=$(openssl rand -hex 64)
echo "$NEW" | sudo tee /mnt/hd2t/services/mealie/secrets/jwt_secret >/dev/null

# 2. Sustituir en el .env:
sudo sed -i "s|^MEALIE_JWT_SECRET=.*|MEALIE_JWT_SECRET=${NEW}|" /mnt/hd2t/services/mealie/.env

# 3. Recreate del contenedor (no basta con restart):
docker compose -f ~/homelab/stacks/mealie/docker-compose.yml \
  --env-file /mnt/hd2t/services/mealie/.env up -d --force-recreate

# 4. Notificar a usuarios y re-emitir API tokens.
```

### 10.5. Importar / exportar recetas (export ZIP nativo)

**Export** (manual, desde la UI):
- `/admin/backups` → **Create Backup** → genera `mealie_<timestamp>.zip` en `/app/data/backups/`.

**Export** (vía API):
```bash
TOKEN="<admin token>"
curl -fsS -X POST -H "Authorization: Bearer ${TOKEN}" \
  https://mealie.lan/api/admin/backups
# Devuelve { "filename": "mealie_2025-01-15-X.zip" }

# Descargar:
curl -fsS -H "Authorization: Bearer ${TOKEN}" \
  https://mealie.lan/api/admin/backups/mealie_2025-01-15-X.zip \
  -o ~/mealie_export.zip
```

**Import** (de un export ZIP a otra Mealie / tras disaster recovery):
- `/admin/backups` → **Upload Backup** → seleccionar ZIP → **Import**.

**Importar desde otros formatos**:
- Mealie soporta importer de Paprika, Nextcloud Cookbook, Chowdown y MyCookbook (a través de `/admin/migrations`).
- Importer de URL única: `/recipes/create/url` (UI) o `POST /api/recipes/create-url` (§8.5).

### 10.6. Logs y observabilidad

```bash
# Logs últimos 5 min:
docker logs --since 5m mealie

# Filtrar errores:
docker logs mealie 2>&1 | grep -iE 'error|exception|traceback' | tail -50

# Logs de scraper (cuando una URL no se importa bien):
docker logs mealie 2>&1 | grep -i 'recipe-scrapers'

# Espacio ocupado por imágenes de receta:
sudo du -sh /mnt/hd2t/services/mealie/data/recipes/
sudo du -sh /mnt/hd2t/services/mealie/data/

# Estado de WAL de SQLite:
sudo ls -la /mnt/hd2t/services/mealie/data/mealie_v1.0.0b.db*
# Esperado: .db (~MB) + .db-wal (puede ser grande hasta el siguiente checkpoint) + .db-shm (32 KB)
```

### 10.7. Vaciar `recipes/` huérfanos (housekeeping)

A veces tras delete de una receta, sus imágenes quedan en `data/recipes/<slug>/`. Mealie tiene un endpoint admin para purgar:

```bash
TOKEN="<admin token>"
curl -fsS -X POST -H "Authorization: Bearer ${TOKEN}" \
  https://mealie.lan/api/admin/maintenance/clean-images
# Devuelve: { "imagesRemoved": N }
```

---

## 11. Solución de Problemas

| Síntoma | Causa probable | Acción |
|---|---|---|
| Contenedor en `unhealthy` durante >2 min tras start | Migraciones Alembic largas o NLTK descargando corpus por primera vez | `docker logs mealie` — esperar a "Application startup complete." (puede tardar 60-90 s la primera vez) |
| `503 Service Unavailable` en `/api/*` desde el SPA | Uvicorn arrancado pero el Caddy interno no le ha hecho proxy todavía | Esperar 10-30 s extra; si persiste, `docker restart mealie` |
| Login devuelve 401 con la password recién creada | `BASE_URL` mal configurada (frontend envía request a un host distinto) o `JWT_SECRET` cambió entre arranques | Verificar `BASE_URL=https://mealie.lan` literal en el `.env` y que `MEALIE_JWT_SECRET` no varía entre `docker inspect mealie --format '{{json .Config.Env}}'` y el `.env` |
| Receta importada pero sin imagen | `recipe-scrapers` no encontró `image_url` o el dominio bloquea el User-Agent default | Logs: `docker logs mealie 2>&1 \| grep -i scraper` — algunos sitios (NYT) requieren login y no son scrapeables sin ello |
| `allowSignup: true` aunque `ALLOW_SIGNUP=false` | Mealie cachea settings al primer arranque; cambios en `.env` requieren `up -d --force-recreate` | `docker compose --env-file ... up -d --force-recreate` |
| `403` al hacer `POST /api/admin/*` desde un token | El token corresponde a un user no-admin | Generar token desde la sesión del usuario admin (`/user/profile/api-tokens`) |
| Contenedor crashea con "permission denied" en `/app/data` | El `chown` del entrypoint falló porque `/mnt/hd2t/services/mealie/data/` tiene flags `chattr +i` u otros | `lsattr /mnt/hd2t/services/mealie/data/` y limpiar; o forzar `sudo chown -R 1000:1000 /mnt/hd2t/services/mealie/data` |
| `OperationalError: database is locked` | Otro proceso está leyendo el .db (Borgmatic dump concurrente con escritura masiva en Mealie) | Mover el horario de Borgmatic fuera del horario de uso (típicamente 04:00 vs uso humano 18:00-23:00) |
| Tras restore, los API tokens emitidos no funcionan | El `JWT_SECRET` restaurado no coincide con el que firmó los tokens (alguien rotó el secret entre el backup y ahora) | Restaurar también `secrets/jwt_secret-<fecha>` desde `/mnt/hd2t/backups/dumps/mealie/` |
| `recipe-scrapers` falla con DNS NXDOMAIN | Pi-hole bloquea el dominio (rara vez con sitios de recetas, pero ocurre con dominios listados como tracking) | Whitelist en Pi-hole: `pihole -w <dominio>` |
| Tras upgrade mayor el path del .db cambió a `mealie_v2.0.0.db` | Mealie bumpeó el sufijo de versión del .db (sucede en mayores) | Actualizar `sqlite_databases.path` en `borgmatic-config.yaml` |
| Apps móviles no conectan vía Tailscale | Falta cert de Tailscale o la CA interna no está confiada en el móvil | Emitir cert con `tailscale cert mealie.${TS_DOMAIN}` o usar el bloque LAN si es `100.x` interno |

---

## 12. Variantes opt-in

### 12.1. Workers tunneados (modo "low-RAM" para Pi 4 / coexistencia con 20+ servicios)

Si la Pi está saturada y hay >20 contenedores activos, bajar Mealie a 1 worker:

```dotenv
WEB_CONCURRENCY=1
MAX_WORKERS=1
WORKERS_PER_CORE=0.25
MEALIE_MEMORY_LIMIT=384M
```

Trade-off: una sola request pesada (import URL con scraper lento) bloquea la UI durante 5-10 s.

### 12.2. PostgreSQL en lugar de SQLite

Para deploys >10 usuarios concurrentes o >50 k recetas. Añadir al stack un contenedor `postgres-mealie` y cambiar `DB_ENGINE=postgres`:

```yaml
services:
  postgres-mealie:
    image: postgres:16-alpine
    container_name: postgres-mealie
    restart: unless-stopped
    environment:
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: ${POSTGRES_DB}
    volumes:
      - /mnt/hd2t/services/mealie/db/data:/var/lib/postgresql/data:rw
    networks:
      - mealie-internal
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER}"]
      interval: 30s

  mealie:
    # ... (igual que antes pero añadir mealie-internal a networks y depends_on)
    networks:
      - homelab
      - mealie-internal
    depends_on:
      postgres-mealie:
        condition: service_healthy

networks:
  homelab:
    external: true
  mealie-internal:
    driver: bridge
    internal: true
```

Y en Borgmatic mover la entrada de `sqlite_databases` a `postgresql_databases:`.

### 12.3. SSO con Authelia (Mealie como cliente OIDC)

Mealie soporta OIDC (`OIDC_AUTH_ENABLED=true`). Authelia puede actuar como **provider OIDC** ([`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md) §X.X — sección OIDC). Esquema:

1. En Authelia, registrar Mealie como cliente OIDC:
   ```yaml
   identity_providers:
     oidc:
       clients:
         - id: mealie
           description: Mealie
           secret: '<bcrypt-hashed-secret>'
           public: false
           authorization_policy: two_factor
           redirect_uris:
             - https://mealie.lan/login
           scopes: [openid, profile, email, groups]
           grant_types: [authorization_code, refresh_token]
   ```
2. En el `.env` de Mealie:
   ```dotenv
   OIDC_AUTH_ENABLED=true
   OIDC_CONFIGURATION_URL=https://auth.lan/.well-known/openid-configuration
   OIDC_CLIENT_ID=mealie
   OIDC_CLIENT_SECRET=<plaintext-secret>
   OIDC_PROVIDER_NAME=Authelia
   OIDC_AUTO_REDIRECT=false                    # true = login va directo a Authelia, ya no se puede usar password local
   OIDC_USER_GROUP=mealie-users
   OIDC_ADMIN_GROUP=mealie-admins
   OIDC_SIGNUP_ENABLED=true                    # crea automáticamente usuarios Mealie cuando un user de Authelia hace login por primera vez
   ```

Trade-off: añade dependencia entre Mealie y Authelia. Si Authelia cae, los usuarios no pueden loguear (a menos que `OIDC_AUTO_REDIRECT=false` y haya passwords locales como fallback).

### 12.4. SMTP para emails (reset password, invitaciones)

Si el operador tiene un MTA (relay externo tipo Mailgun, SendGrid, o un Postfix interno):

```dotenv
SMTP_HOST=smtp.example.com
SMTP_PORT=587
SMTP_FROM_NAME=Mealie Homelab
SMTP_FROM_EMAIL=mealie@homelab.lan
SMTP_USER=<user>
SMTP_PASSWORD=<password>
SMTP_AUTH_STRATEGY=tls
SMTP_TLS_ENABLED=true
```

Trade-off: añade superficie (credenciales SMTP en `.env`). El homelab por default no tiene MTA y maneja resets vía consola (§10.3).

### 12.5. Fail2ban con jail dedicado para `/api/auth/token`

El jail `caddy-status` cubre `4xx` genéricos. Para detectar específicamente brute-force a Mealie, añadir un jail filtrando `POST /api/auth/token` con `4xx` repetidos:

`/etc/fail2ban/filter.d/mealie-auth.conf`:
```ini
[Definition]
failregex = ^.*"POST /api/auth/token HTTP/.*" 401.*"<HOST>".*$
ignoreregex =
```

`/etc/fail2ban/jail.d/mealie.local`:
```ini
[mealie-auth]
enabled = true
filter = mealie-auth
logpath = /var/log/caddy/access.log
maxretry = 5
findtime = 600
bantime = 3600
action = iptables-multiport[name=mealie-auth, port="80,443", protocol=tcp]
```

Mealie ya tiene su propio rate-limit a nivel app (`SECURITY_USER_LOGIN_ATTEMPTS=5` + `SECURITY_USER_LOCKOUT_TIME=24`); este jail añade ban a nivel red.

### 12.6. LDAP via Authelia (Mealie como cliente LDAP)

Mealie soporta LDAP nativo (`LDAP_AUTH_ENABLED=true`). Si el homelab tiene un servidor LDAP (Authelia con `lldap` o `OpenLDAP` aparte), Mealie puede consultarlo directamente:

```dotenv
LDAP_AUTH_ENABLED=true
LDAP_SERVER_URL=ldap://lldap:3890
LDAP_TLS_INSECURE=false
LDAP_BIND_TEMPLATE=uid={input},ou=people,dc=homelab,dc=lan
LDAP_QUERY_BIND=uid=mealie,ou=services,dc=homelab,dc=lan
LDAP_QUERY_PASSWORD=<bind password>
LDAP_BASE_DN=ou=people,dc=homelab,dc=lan
LDAP_USER_FILTER=(&(memberof=cn=mealie-users,ou=groups,dc=homelab,dc=lan)(uid={input}))
LDAP_ADMIN_FILTER=(memberof=cn=mealie-admins,ou=groups,dc=homelab,dc=lan)
LDAP_ID_ATTRIBUTE=uid
LDAP_NAME_ATTRIBUTE=cn
LDAP_MAIL_ATTRIBUTE=mail
```

Trade-off: requiere LDAP server activo. OIDC (§12.3) es generalmente preferible — más seguro (sin bind passwords) y más estándar.

### 12.7. Acceso solo Tailscale (sin LAN)

Si el operador prefiere que Mealie **no** sea accesible desde la LAN (solo vía VPN Tailscale), comentar el bloque `mealie.{$LAN_DOMAIN}` del Caddyfile y dejar solo `mealie.{$TS_DOMAIN}`. Trade-off: requiere Tailscale activo en cada dispositivo del hogar (incluido invitados).

### 12.8. Tesseract OCR para fotos de recetas en papel

Mealie 1.4+ tiene un endpoint experimental `/api/recipes/create-from-image` que usa Tesseract para extraer texto de fotos de recetas físicas (libros, tarjetas escritas a mano). Requiere instalar el paquete extra `mealie[ocr]` — está disponible solo en algunas variantes de imagen (`ghcr.io/mealie-recipes/mealie:vX.Y.Z-ocr`). Trade-off: la imagen pesa ~150 MB extra y la calidad del OCR es limitada (Tesseract no es bueno con caligrafía).

---

## 13. Referencias

- Documentación oficial Mealie: https://docs.mealie.io/
- Repositorio: https://github.com/mealie-recipes/mealie
- Imagen Docker: https://github.com/mealie-recipes/mealie/pkgs/container/mealie
- Release notes: https://github.com/mealie-recipes/mealie/releases
- API Swagger en runtime: `https://mealie.lan/docs`
- recipe-scrapers (motor de import): https://github.com/hhursev/recipe-scrapers
- Documentación variables de entorno: https://docs.mealie.io/documentation/getting-started/installation/backend-config/
- Backup/restore Mealie: https://docs.mealie.io/documentation/getting-started/usage/backups-and-restoring/
- OIDC config: https://docs.mealie.io/documentation/getting-started/authentication/oidc-v2/
- LDAP config: https://docs.mealie.io/documentation/getting-started/authentication/ldap/

Documentos relacionados del homelab:

- [`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) — árbol `/mnt/hd2t/services/mealie/`.
- [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) — convenciones del stack.
- [`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) — exclusión justificada de Mealie.
- [`../03-red/04-caddy.md`](../03-red/04-caddy.md) — bloque `mealie.{$LAN_DOMAIN}`.
- [`../03-red/02-pihole.md`](../03-red/02-pihole.md) — registro DNS `mealie.lan`.
- [`../03-red/05-tailscale.md`](../03-red/05-tailscale.md) — variante remota.
- [`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md) — variante §12.3 (OIDC).
- [`../04-seguridad/02-fail2ban.md`](../04-seguridad/02-fail2ban.md) — jail `caddy-status` y variante §12.5.
- [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) — `sqlite_databases:` con entrada `mealie`.
- [`../07-backups/03-backup-docker-volumes.md`](../07-backups/03-backup-docker-volumes.md) §4.8 — patrón unificado SQLite.
- [`./01-vaultwarden.md`](./01-vaultwarden.md) — guardado de la password admin y los API tokens.
- [`./03-linkding.md`](./03-linkding.md) — plantilla análoga (SQLite, sin Authelia).
- [`./04-paperless-ngx.md`](./04-paperless-ngx.md) — plantilla análoga (PostgreSQL, con Authelia + bypass `/api/*`).
