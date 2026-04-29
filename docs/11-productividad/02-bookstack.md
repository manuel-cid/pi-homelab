# Bookstack

## Descripción

Tras Vaultwarden (`01-vaultwarden.md`), el homelab cierra otra pieza estructural de la productividad personal del operador: **dónde vive la documentación del propio homelab**. Hasta este punto, los `docs/*.md` del repositorio (incluida esta página) son la fuente de verdad: están en git, son `grep`-ables, viajan con el commit que cambia la configuración asociada y se restauran junto al resto del repo. Eso cubre la **documentación de diseño** — decisiones, justificaciones, *runbooks* — pero no cubre bien dos casos:

1. **Notas operativas vivas** que cambian a diario sin merecer un commit (incidencias breves, recordatorios, listas, planificación de tareas, anotaciones de la familia).
2. **Documentación visual** con jerarquías (libros → capítulos → páginas), búsqueda full-text en una UI, edición WYSIWYG, adjuntos inline e historial de revisiones consultable desde el navegador o el móvil sin pasar por git.

Para esos casos, este documento despliega **Bookstack** — wiki autohospedada (PHP/Laravel) con modelo organizativo "shelves → books → chapters → pages", editor WYSIWYG y Markdown, búsqueda full-text contra MySQL/MariaDB, control de permisos por rol, historial de revisiones con diff, exportación a HTML/PDF/Markdown y soporte OIDC (que aquí se conectará a Authelia). Su rol concreto:

1. **Servir la wiki** en `https://bookstack.${DOMAIN_LAN}/` con TLS terminado en Caddy (CA interna, igual que el resto). Detrás de Caddy, sin `ports:` al host.
2. **Persistir contenido en MariaDB** (`bookstack-db`, MariaDB 11 LTS) sobre `hd2t`. Adjuntos e imágenes en `/mnt/hd2t/apps/bookstack/uploads/`.
3. **Autenticarse contra Authelia vía OIDC** desde el primer arranque: el operador (y la familia) entran con la misma cuenta que para el resto de servicios SSO. La contraseña local de Bookstack queda como fallback de emergencia (admin local) y se desactiva en cuanto OIDC funciona.
4. **Loguear a stdout** del contenedor (consumible por Promtail/Loki en Fase 5 o, transitoriamente, por `docker logs`). Los logs de auth y de errores quedan en stdout; **no** se enchufan a fail2ban (la auth fuerte la hace Authelia delante; ver `04-seguridad/01-authelia.md`).
5. **Respaldarse vía Borgmatic** con el hook nativo `mariadb_databases` ya preparado (`07-backups/02-borgmatic.md`, sección "Plantilla para futuros servicios"), más los uploads como ficheros.

Lo que este documento **no** decide:

- **SMTP saliente** (notificaciones por email — invitaciones, reset de password, comentarios). Bookstack soporta SMTP nativamente (`MAIL_DRIVER=smtp`), pero hasta que Mailrise (Fase 11) esté desplegado se deja **deshabilitado** (`MAIL_DRIVER=log`, los emails se vuelcan al stdout del contenedor para inspección manual). Cuando Mailrise exista, dos líneas en `.env` y `up -d --force-recreate` lo activan.
- **Editor de Markdown como predeterminado** (Bookstack ofrece WYSIWYG y Markdown; cada usuario elige por preferencia). Se documenta como recomendación pero no se fuerza.
- **Política de visibilidad pública** de algún book (Bookstack permite marcar contenido como público sin login). El homelab **no expone Bookstack a Internet** y el caso de uso doméstico no necesita visibilidad pública; se deja la auth obligatoria globalmente (`AUTH_METHOD=oidc`, sin guest).
- **OAuth contra GitHub/Google/Microsoft**. Reabrible si en algún momento el operador quiere abrir Bookstack a colaboradores externos por OAuth en lugar de invitarlos como usuarios SSO. Hoy: solo Authelia (interno).
- **Tema de marca** (logo, favicon, color primario). Se documenta dónde se cambia (`Settings → Customization`), pero la elección es del operador.
- **Migración de contenido existente** (un repo `docs/` viejo en Markdown a Bookstack vía `bookstack-import`). Se menciona como camino posible si el operador decide migrar la documentación del propio homelab desde git a Bookstack; **no** es la postura por defecto del proyecto: el homelab mantiene `docs/` en git como fuente de verdad de las **decisiones**, y Bookstack se reserva para **notas operativas vivas**.

Cuando este documento se haya aplicado:

- `https://bookstack.${DOMAIN_LAN}/` muestra la home de Bookstack con cert de la CA interna.
- El primer login del operador pasa por Authelia (login + TOTP), Bookstack recibe el id_token vía OIDC y crea automáticamente la cuenta del operador con rol **Admin**.
- La cuenta admin local (`admin@admin.com`) queda inhabilitada (password sobrescrito a un valor aleatorio largo, anotado en KeePassXC offline como contingencia de "Authelia roto").
- La organización inicial está creada: una **shelf** "Homelab" con un **book** vacío "Operación diaria"; queda como semilla.
- MariaDB guarda los datos en `/mnt/hd2t/apps/bookstack/db/`; los adjuntos viven en `/mnt/hd2t/apps/bookstack/uploads/`.
- Borgmatic respalda diariamente la BBDD vía `mariadb_databases` (dump SQL puro) y los `uploads/` como ficheros.
- Uptime Kuma tiene un monitor HTTPS sobre `https://bookstack.${DOMAIN_LAN}/status` (endpoint público de health) con alerta Telegram.

> **Recordatorio de alcance**: Bookstack es **solo LAN + Tailscale**. **No publica `ports:` al host**, **no se expone a Internet**, **no usa Let's Encrypt**. Los miembros de la familia que necesiten anotar algo desde fuera de casa entran por Tailscale y la URL `https://bookstack.lan` resuelve igual gracias a MagicDNS + comodín de Pi-hole.

---

## Requisitos Previos

- **Fase 2** completa: Docker Engine + Compose v2; red `homelab` en `172.30.10.0/24`; convenciones `stacks/<svc>/`; `.env` global con `TZ`, `PUID`, `PGID`, `DOMAIN_LAN=lan`, `LAN_IP=192.168.1.10`.
- **Fase 3** completa, en particular:
  - Pi-hole con el comodín `address=/lan/192.168.1.10` (cubre `bookstack.${DOMAIN_LAN}` sin tocar Pi-hole).
  - Caddy con los snippets `(lan_tls)`, `(security_headers)`, `(healthcheck)` definidos.
- **Fase 4** completa, en particular:
  - Authelia desplegado **con OIDC habilitado** (`identity_providers.oidc` configurado en `04-seguridad/01-authelia.md`). Bookstack consume OIDC (no `forward_auth`): a diferencia de Vaultwarden, Bookstack es una app web con sesión PHP propia y soporta el flujo OIDC nativo, lo que permite SSO real (un solo login Authelia desbloquea Bookstack y los demás clientes OIDC de la tailnet).
  - El **client OIDC** `bookstack` registrado en `configuration.yml` de Authelia (ver "Configuración → 1. Registrar el client OIDC en Authelia").
- **Fase 7** completa: Borgmatic operativo. Se añade un bloque `mariadb_databases` aquí.
- **Disco `hd2t`** montado en `/mnt/hd2t` con al menos **2 GiB** libres. La BBDD ronda 50–200 MiB para uso doméstico (≤ 1000 páginas con texto). Los `uploads/` crecen con las imágenes y ficheros adjuntos: estimar 1 GiB de margen para el primer año.
- Una **`MARIADB_ROOT_PASSWORD`** y una **`MARIADB_BOOKSTACK_PASSWORD`** (≥ 24 caracteres, generadas con `openssl rand -base64 30`), almacenadas en `secrets/db/bookstack-db.env` (modo `0600`, fuera de git por `.gitignore`). Aliasadas en KeePassXC offline para disaster recovery.
- Un **`APP_KEY`** (32 bytes base64) generado **una vez** y nunca cambiado: es la clave de cifrado de las cookies de sesión de Laravel y de los `OIDC_CLIENT_SECRET` que Bookstack guarda cifrados. Cambiarlo invalida todas las sesiones y obliga a los usuarios a relogarse.

Comprobaciones rápidas:

```bash
# La red Docker compartida existe
docker network inspect homelab --format '{{.Name}}' | grep -q '^homelab$' && echo ok

# Caddy y Authelia corriendo
docker ps --filter name=caddy --filter name=authelia --format '{{.Names}} {{.Status}}'

# bookstack.lan resuelve al IP de la Pi (gracias al comodín de Pi-hole)
dig +short bookstack.lan @192.168.1.2
# 192.168.1.10

# Espacio en hd2t
df -h /mnt/hd2t | awk 'NR==2 {print $4 " libres"}'

# Authelia tiene OIDC habilitado
docker exec authelia grep -E '^identity_providers:|^\s+oidc:' /config/configuration.yml | head
```

---

## Decisión: imagen y versión

Bookstack tiene varias imágenes mantenidas:

| Imagen | Mantenida por | Discusión |
|---|---|---|
| `lscr.io/linuxserver/bookstack` | LinuxServer.io | **Aceptada**. Multi-arch nativa (`amd64`, `arm64`, `armv7`); honra `PUID/PGID`; el contenedor incluye Apache + PHP-FPM + composer ya configurados; releases siguen upstream con un retraso típico de 24–48 h. Es la imagen "canónica" de la comunidad para self-hosting. |
| `solidnerd/bookstack` | Comunidad | Activa pero menos pulida; arm64 disponible. Descartada por menos rodaje en Pi 5. |
| `linuxserver/mariadb` | LinuxServer.io | Para el sidecar de BBDD. Aceptada por simetría (mismo ecosistema, mismo PUID/PGID). Alternativa: `mariadb:11-jammy` oficial (peso similar, soporte oficial más largo). **Aceptado el oficial** por LTS explícito (10 años en 11.4 LTS). |
| `mariadb:11.4` (oficial) | MariaDB Foundation | **Aceptada para `bookstack-db`**. Multi-arch incluida arm64; LTS hasta 2034. |

> **Tags exactos en uso**:
> - `lscr.io/linuxserver/bookstack:24.05.4` (versión upstream `v24.05.4`).
> - `mariadb:11.4.4-noble` (LTS).
>
> Si en el momento de aplicar el documento hay una `24.X.X` superior con changelog limpio (sin migración mayor de schema), se actualiza el tag aquí y en el `docker-compose.yml`, anotándolo en el commit. **Nunca `latest`**.

> **Por qué `:24.05.4` y no `:latest`**. Bookstack hace migraciones de schema en cada release menor (Laravel migrations); un `:latest` que avance una versión menor sin que el operador lo sepa puede dejar la BBDD en estado intermedio si el contenedor se cae a medias. Watchtower está **deshabilitado** para este stack (`com.centurylinklabs.watchtower.enable: "false"`); las actualizaciones son deliberadas: `borgmatic create --tag pre-bookstack-upgrade-X.Y.Z`, edición del tag, `up -d`, validación.

> **Por qué MariaDB y no MySQL ni PostgreSQL**. Bookstack soporta oficialmente **MySQL 8** y **MariaDB 10.5+** y **no** soporta PostgreSQL (pendiente upstream desde hace años). Entre MySQL 8 y MariaDB 11.4 LTS:
> - MariaDB consume ~30 % menos RAM en idle (≈70 MiB vs ≈110 MiB en una Pi 5).
> - MariaDB está más rodada en arm64 y en proyectos comunitarios self-hosted.
> - Las herramientas (`mariadb-dump`, integración Borgmatic) son compatibles con MySQL en la práctica.
>
> Decisión: **MariaDB 11.4 LTS**.

---

## Decisión: cómo se expone Bookstack

La imagen LinuxServer.io de Bookstack arranca un Apache que escucha en `:80` dentro del contenedor (HTTP plano; el TLS lo termina Caddy delante).

| Opción | Cómo se ve | Discusión |
|---|---|---|
| `network_mode: host` | Bookstack ata `:80` directamente. | Choca con Caddy (que ya ata `:80`). Descartado. |
| Bridge `homelab` con `ports: ["80:80"]` | Acceso directo desde la LAN sin pasar por Caddy. | HTTP plano sin TLS y sin Authelia delante; rompe la convención del homelab. Descartado. |
| Bridge `homelab` con `expose: 80`, **sin `ports:`** | Bookstack alcanzable solo dentro de la red Docker, vía DNS (`bookstack:80`). Caddy hace `reverse_proxy http://bookstack:80`. | Termina TLS en Caddy con la CA interna. Patrón establecido en Fase 3. **Aceptado**. |

Resultado: `expose: 80` en el compose (no `ports:`), un drop-in `stacks/caddy/conf.d/41-bookstack.caddy` que hace `reverse_proxy http://bookstack:80`, y todo el tráfico externo pasa por `https://bookstack.${DOMAIN_LAN}/` con cert de la CA interna.

> **Sobre WebSocket / actualizaciones en tiempo real**. Bookstack **no** usa WebSocket: la edición colaborativa en tiempo real no existe en la versión OSS (es una feature comercial del propio Bookstack o de wikis competidoras). El reverse proxy es HTTP/HTTPS plano sin Upgrade.

---

## Decisión: autenticación — Authelia OIDC, no `forward_auth`

A diferencia de Vaultwarden (que usa `forward_auth` solo en `/admin` por incompatibilidad con sus clientes nativos), Bookstack es **íntegramente** una aplicación web: no hay clientes que hablen API directa con cookies de sesión externas. Esto abre la puerta al patrón canónico de SSO:

| Patrón | Cómo se ve | Discusión |
|---|---|---|
| Auth local (email + password) | Bookstack pinta su propio login. Cada usuario tiene una password gestionada en la BBDD (Laravel `bcrypt`). | Funciona, pero introduce **otro** vector de auth con su propio reset, su propio rate limit, sus propios usuarios. Multiplica superficie. Descartado salvo como fallback. |
| `forward_auth` Authelia (igual que Vaultwarden `/admin`) | Caddy llama a Authelia antes de cada request; tras autenticarse, Authelia inyecta `Remote-User` y `Remote-Groups` en cabeceras. Bookstack puede recibirlas con `AUTH_METHOD=ldap` con un proxy LDAP, o con `header_auto_register`. | Bookstack soporta `header_auto_register` desde 21.x; aprovisiona automáticamente cuentas leyendo `Remote-User`. Pero pierde info estructurada (no hay claims, los grupos son cadenas opacas) y no permite **logout** unificado: cerrar sesión en Bookstack no cierra Authelia, y viceversa. Aceptable pero subóptimo. |
| **OIDC**: Authelia como **Identity Provider**, Bookstack como **client** | Bookstack redirige a Authelia para autenticar; Authelia devuelve un `id_token` JWT con claims (`sub`, `email`, `name`, `groups`); Bookstack crea/actualiza el usuario y queda con sesión PHP propia. Logout unificado. | Patrón "SSO real". Soporta mapeo de `groups` Authelia → roles Bookstack. **Aceptado**. |

Resultado: `AUTH_METHOD=oidc` en el `.env` de Bookstack, registro de un client `bookstack` en `configuration.yml` de Authelia con `redirect_uris: ["https://bookstack.${DOMAIN_LAN}/oidc/callback"]`, y Caddy hace **bypass** de la auth (no aplica `import authelia_two_factor`): el flujo OIDC ya pasa por Authelia internamente.

> **Sobre la cuenta admin local de Bookstack**. Bookstack arranca con un seed de un admin local (`admin@admin.com` / `password`). Antes de habilitar OIDC se entra con esa cuenta una vez (en modo "auth standard"), se cambia su password a uno aleatorio largo (anotado en KeePassXC offline), y luego se cambia a `AUTH_METHOD=oidc`. La cuenta sigue existiendo en la BBDD, pero solo es accesible vía `php artisan bookstack:create-admin` desde el contenedor — útil como **fallback si Authelia se rompe** (idéntico patrón al fallback `password` de Authelia, `04-seguridad/01-authelia.md`).

> **Sobre el mapeo de roles**. Por defecto Bookstack asigna a los nuevos usuarios el rol "Viewer". El operador, tras su primer login OIDC, se promociona manualmente a "Admin" desde la UI. Para automatizar el mapeo `groups` → rol se usa `OIDC_USER_TO_GROUPS=true` y se crean en Bookstack roles con el **mismo nombre** que los grupos de Authelia (`admins`, `family`). Documentado en "Configuración → 5".

---

## Decisión: persistencia y BBDD

Bookstack guarda dos tipos de estado:

1. **BBDD relacional** — usuarios, books, chapters, pages, revisiones, permisos, settings. En MariaDB.
2. **Ficheros** — adjuntos (PDFs, ficheros varios) e imágenes inline de las páginas. En filesystem (`/config/www/uploads/` dentro del contenedor → `/mnt/hd2t/apps/bookstack/uploads/` en el host).

| Aspecto | Decisión | Por qué |
|---|---|---|
| BBDD | MariaDB 11.4 en sidecar (`bookstack-db`), red interna `bookstack-internal` (no expuesta a `homelab`). | Aislamiento: solo Bookstack habla con su BBDD. Si en el futuro Paperless-ngx u otro servicio tiene su propio MariaDB, cada uno con su sidecar (no se comparte instancia). |
| Adjuntos | Bind mount a `/mnt/hd2t/apps/bookstack/uploads/`. | Datos versionables (en sentido de backup, no git): Borgmatic los respalda como ficheros. La imagen LSIO crea subdirectorios por tipo (`images/`, `attachments/`). |
| Configuración | En `.env` y BBDD. **No** en ficheros sueltos persistentes. | Reproducible desde git (.env) + restore Borg (BBDD). |
| Snapshot consistente BBDD | `mariadb-dump --single-transaction` vía hook `mariadb_databases` de Borgmatic. **No** copia de `/mnt/hd2t/apps/bookstack/db/` raw. | InnoDB + `--single-transaction` da consistencia sin lock global. Copiar el directorio raw mientras MariaDB escribe puede dar un dump inconsistente; el formato lógico (SQL) es agnostic ante upgrades de versión. |

> **Por qué `--single-transaction` y no `--lock-tables`**. Las tablas de Bookstack son **todas InnoDB** (Laravel migrations), así que `--single-transaction` da un snapshot transaccionalmente consistente sin parar el servicio. `--lock-tables` solo aplica a MyISAM y bloquearía escrituras durante la duración del dump.

> **Por qué excluir `/mnt/hd2t/apps/bookstack/db/` del archivo Borg**. La carpeta `db/` contiene los ficheros binarios de InnoDB (`ibdata1`, `*.ibd`, redo logs). Respaldarlos directamente requiere parar MariaDB (downtime) o usar `mariabackup` (otra herramienta). Es preferible respaldar el dump SQL (consistente, agnostic) y excluir el `db/` del archivo. Pendiente: añadir el patrón de exclusión a `borgmatic.yaml`.

---

## Stack: `stacks/bookstack/`

### Layout en disco

| Ruta | Soporte | Contenido |
|---|---|---|
| `stacks/bookstack/docker-compose.yml` | microSD (git) | Stack (servicios `bookstack` + `bookstack-db`). |
| `stacks/bookstack/.env.example` | microSD (git) | Plantilla con `APP_KEY`, `DB_PASS`, OIDC vars, `MAIL_*`. |
| `stacks/bookstack/.env` | microSD (NO git) | Versión rellena con secretos reales. Modo `0600`. |
| `secrets/db/bookstack-db.env` | microSD (NO git) | `MARIADB_ROOT_PASSWORD` y `MARIADB_PASSWORD`. Modo `0600`. Fuente de verdad para el sidecar de BBDD. |
| `stacks/caddy/conf.d/41-bookstack.caddy` | microSD (git) | Drop-in Caddy para `bookstack.${DOMAIN_LAN}`. |
| `/mnt/hd2t/apps/bookstack/db/` | hd2t | Datos InnoDB de MariaDB. **Excluido del archivo Borg** (se respalda el dump). |
| `/mnt/hd2t/apps/bookstack/uploads/` | hd2t | Adjuntos e imágenes inline. **Sí se respalda**. |
| `/mnt/hd2t/apps/bookstack/config/` | hd2t | Estado de la imagen LSIO (caché de Laravel, claves generadas). Pequeño, recreable; **se respalda** por simplicidad. |

### `stacks/bookstack/docker-compose.yml`

```yaml
# Bookstack — wiki / base de conocimiento autohospedada (PHP + MariaDB).
# Convenciones: ver docs/02-docker/02-estructura-compose.md y docs/11-productividad/02-bookstack.md.

name: bookstack

services:
  bookstack:
    image: lscr.io/linuxserver/bookstack:24.05.4
    container_name: bookstack
    hostname: bookstack
    restart: unless-stopped
    depends_on:
      bookstack-db:
        condition: service_healthy

    environment:
      TZ: ${TZ}
      PUID: ${PUID}
      PGID: ${PGID}

      # URL canónica. Se usa para construir todos los enlaces absolutos
      # (emails, reset password, redirect_uri OIDC). DEBE coincidir con la
      # URL real que ven los navegadores. Cambiarla obliga a rerun migrations
      # con `php artisan cache:clear` dentro del contenedor.
      APP_URL: https://bookstack.${DOMAIN_LAN}

      # Clave de cifrado de Laravel (cookies de sesión, OIDC client secret
      # cifrado en BBDD). Generar UNA VEZ y NUNCA cambiar:
      #   docker run --rm lscr.io/linuxserver/bookstack:24.05.4 \
      #     bash -c 'cd /app/www && php artisan key:generate --show'
      # Formato esperado: `base64:<32-byte-base64>`.
      APP_KEY: ${APP_KEY}

      # BBDD — apunta al sidecar `bookstack-db` por DNS Docker.
      DB_HOST: bookstack-db
      DB_PORT: "3306"
      DB_DATABASE: bookstack
      DB_USER: bookstack
      DB_PASS: ${DB_PASS}

      # Auth: OIDC contra Authelia. AUTH_METHOD=standard durante el bootstrap
      # inicial (crear cuenta admin local), luego cambiar a `oidc`.
      AUTH_METHOD: ${AUTH_METHOD:-standard}

      # OIDC — solo se consume si AUTH_METHOD=oidc. Vacío durante bootstrap.
      OIDC_NAME: Authelia
      OIDC_DISPLAY_NAME_CLAIMS: name
      OIDC_CLIENT_ID: bookstack
      OIDC_CLIENT_SECRET: ${OIDC_CLIENT_SECRET}
      OIDC_ISSUER: https://auth.${DOMAIN_LAN}
      OIDC_ISSUER_DISCOVER: "true"
      OIDC_USER_TO_GROUPS: "true"
      OIDC_GROUPS_CLAIM: groups
      OIDC_REMOVE_FROM_GROUPS: "false"
      # Solo OIDC: oculta el formulario de login local en la home.
      OIDC_DUMP_USER_DETAILS: "false"

      # Sesiones: 7 días para uso doméstico.
      SESSION_LIFETIME: "10080"

      # Email: deshabilitado hasta Mailrise (Fase 11). `log` vuelca emails
      # a stdout del contenedor (`docker logs bookstack`) — útil para ver
      # invitaciones manualmente hasta que Mailrise exista.
      MAIL_DRIVER: log
      MAIL_FROM: bookstack@${DOMAIN_LAN}
      MAIL_FROM_NAME: "Bookstack Homelab"

      # Rendimiento: cachear views compiladas y rutas para reducir CPU.
      APP_DEBUG: "false"
      APP_VIEWS_BOOKS: list
      APP_VIEWS_BOOKSHELVES: grid

    networks:
      - homelab          # Caddy llega por aquí
      - bookstack-internal  # Habla con MariaDB por aquí

    # NO `ports:`. Acceso solo vía Caddy.
    expose:
      - "80"

    volumes:
      - /mnt/hd2t/apps/bookstack/config:/config
      # Los uploads se materializan dentro de /config/www/uploads.
      # Bind explícito para que Borg pueda excluirlos/incluirlos selectivamente.
      - /mnt/hd2t/apps/bookstack/uploads:/config/www/uploads

    healthcheck:
      # /status devuelve 200 con un JSON cuando la app y la BBDD están vivas.
      test: ["CMD-SHELL", "curl -fsS http://127.0.0.1:80/status >/dev/null || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 60s

    labels:
      homelab.role: "wiki"
      homelab.backup: "true"
      # Bookstack hace migraciones de schema en cada release menor; Watchtower
      # OFF, las actualizaciones son deliberadas con backup pre-upgrade.
      com.centurylinklabs.watchtower.enable: "false"

  bookstack-db:
    image: mariadb:11.4.4-noble
    container_name: bookstack-db
    hostname: bookstack-db
    restart: unless-stopped

    env_file:
      # MARIADB_ROOT_PASSWORD y MARIADB_PASSWORD viven aquí (modo 0600).
      - /home/homelab/homelab/secrets/db/bookstack-db.env

    environment:
      TZ: ${TZ}
      MARIADB_DATABASE: bookstack
      MARIADB_USER: bookstack
      # Cifrado en reposo (innodb encryption) NO se activa: añade complejidad
      # de gestión de keyring sin valor real para un homelab con disk full
      # encryption opcional a nivel de filesystem (no aplicado).

    networks:
      - bookstack-internal

    # Sin `ports:` ni `expose`: la BBDD SOLO es alcanzable desde
    # `bookstack-internal` (donde solo está el propio Bookstack y el sidecar
    # de Borgmatic vía red puntual cuando hace falta dump ad-hoc).

    volumes:
      - /mnt/hd2t/apps/bookstack/db:/var/lib/mysql

    healthcheck:
      test:
        - CMD-SHELL
        - >-
          mariadb-admin ping -h 127.0.0.1
          -u root -p"$$MARIADB_ROOT_PASSWORD"
          --silent
      interval: 15s
      timeout: 5s
      retries: 5
      start_period: 30s

    labels:
      homelab.role: "wiki-db"
      homelab.backup: "false"  # backup vía mariadb_databases hook, no FS
      com.centurylinklabs.watchtower.enable: "false"

networks:
  homelab:
    external: true
  bookstack-internal:
    driver: bridge
    internal: true
    # `internal: true` impide salida a Internet desde esta red. La BBDD
    # nunca necesita pulls de fuera; el contenedor `bookstack` SÍ los
    # necesita (composer en arranque de la imagen LSIO), por eso
    # `bookstack` está en AMBAS redes (`homelab` para salida, `bookstack-internal`
    # para hablar con la BBDD).
```

### `stacks/bookstack/.env.example`

```bash
# stacks/bookstack/.env.example
# Variables específicas del stack Bookstack.
# Las generales (TZ, PUID, PGID, DOMAIN_LAN) viven en el .env GLOBAL.

# Clave de cifrado de Laravel. Generar UNA VEZ:
#   docker run --rm lscr.io/linuxserver/bookstack:24.05.4 \
#     bash -c 'cd /app/www && php artisan key:generate --show'
# Pegar la salida COMPLETA (incluido el prefijo `base64:`).
# CAMBIARLA INVALIDA TODAS LAS SESIONES Y EL OIDC_CLIENT_SECRET CIFRADO.
APP_KEY=base64:CHANGEME_GENERATE_WITH_ARTISAN

# Password del usuario `bookstack` de la BBDD. DEBE coincidir con
# MARIADB_PASSWORD en secrets/db/bookstack-db.env.
DB_PASS=CHANGEME_MISMA_QUE_MARIADB_PASSWORD

# Auth method: durante el primer arranque dejar `standard` para crear
# la cuenta admin local; tras configurar OIDC y promoverse a Admin,
# cambiar a `oidc`.
AUTH_METHOD=standard

# OIDC client secret. Lo registra Authelia en su configuration.yml
# (sección identity_providers.oidc.clients). Aquí va EN CLARO (lo cifra
# Bookstack al persistirlo en BBDD usando APP_KEY).
OIDC_CLIENT_SECRET=CHANGEME_DEL_CLIENT_REGISTRADO_EN_AUTHELIA
```

### `secrets/db/bookstack-db.env`

```bash
# secrets/db/bookstack-db.env
# NO versionado en git (.gitignore: secrets/**). Modo 0600, owner homelab:homelab.
# Generar passwords:
#   openssl rand -base64 30 | tr -d '/=+' | head -c 32
MARIADB_ROOT_PASSWORD=CHANGEME_ROOT_PASSWORD_LARGO
MARIADB_PASSWORD=CHANGEME_BOOKSTACK_PASSWORD_LARGO
```

### `stacks/caddy/conf.d/41-bookstack.caddy`

```caddy
# /etc/caddy/conf.d/41-bookstack.caddy — bloque LAN para Bookstack.
# Bookstack expone su UI + endpoints OIDC en http://bookstack:80 dentro
# de `homelab`. La auth la hace OIDC contra Authelia (no forward_auth);
# Caddy no aplica `authelia_two_factor` aquí.
# Documentado en docs/11-productividad/02-bookstack.md.

bookstack.{$DOMAIN_LAN} {
    import lan_tls
    import security_headers
    import healthcheck

    # Cabeceras estándar para que Bookstack vea la IP real y el esquema
    # original al construir URLs absolutas (importante para OIDC redirect_uri).
    reverse_proxy http://bookstack:80 {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
    }
}
```

> **Sobre `X-Forwarded-Proto`**. Sin esta cabecera, Bookstack construye `redirect_uri` con `http://` (porque internamente Apache habla HTTP) y Authelia rechaza el flujo OIDC con `redirect_uri_mismatch`. La cabecera fuerza a Laravel a generar `https://bookstack.lan/oidc/callback`, que coincide con lo registrado en Authelia.

### Crear los directorios persistentes y desplegar

```bash
# 0) Asegurar el árbol de datos en hd2t (idempotente)
sudo install -d -o homelab -g homelab -m 0750 /mnt/hd2t/apps/bookstack
sudo install -d -o homelab -g homelab -m 0750 /mnt/hd2t/apps/bookstack/config
sudo install -d -o homelab -g homelab -m 0750 /mnt/hd2t/apps/bookstack/uploads
# El directorio db/ lo creará MariaDB con los uids del contenedor (999 por
# defecto). Solo asegurar la carpeta padre con permisos restrictivos.
sudo install -d -o root -g root -m 0750 /mnt/hd2t/apps/bookstack/db

# 1) Generar APP_KEY (UNA SOLA VEZ)
docker run --rm lscr.io/linuxserver/bookstack:24.05.4 \
    bash -c 'cd /app/www && php artisan key:generate --show'
# base64:<32-byte-base64>

# 2) Materializar secrets/db/bookstack-db.env
cd /home/homelab/homelab
set -a; source .env; set +a

mkdir -p secrets/db && chmod 0700 secrets/db
cat > secrets/db/bookstack-db.env <<'EOF'
MARIADB_ROOT_PASSWORD=PEGA_AQUI_ROOT_PASSWORD
MARIADB_PASSWORD=PEGA_AQUI_BOOKSTACK_PASSWORD
EOF
chmod 0600 secrets/db/bookstack-db.env

# 3) Materializar stacks/bookstack/.env
cp stacks/bookstack/.env.example stacks/bookstack/.env
chmod 0600 stacks/bookstack/.env
# Editar: pegar APP_KEY, DB_PASS (= MARIADB_PASSWORD del paso 2),
# dejar AUTH_METHOD=standard, OIDC_CLIENT_SECRET vacío de momento.

# 4) Drop-in de Caddy
install -o homelab -g homelab -m 0644 \
    stacks/caddy/conf.d/41-bookstack.caddy \
    /mnt/hd2t/apps/caddy/etc/conf.d/41-bookstack.caddy

# 5) Validar el Caddyfile
docker exec caddy caddy validate --config /etc/caddy/Caddyfile
# Successful

# 6) Validar el compose
docker compose \
    -f stacks/bookstack/docker-compose.yml \
    --env-file stacks/bookstack/.env \
    config >/dev/null && echo "compose OK"

# 7) Levantar el stack (BBDD primero por depends_on)
docker compose \
    -f stacks/bookstack/docker-compose.yml \
    --env-file stacks/bookstack/.env \
    up -d

# 8) Recargar Caddy
docker kill --signal=SIGUSR1 caddy
```

Tras `up -d`:

```bash
docker ps --filter name=bookstack --format 'table {{.Names}}\t{{.Status}}'
# bookstack-db   Up 30 seconds (healthy)
# bookstack      Up 25 seconds (healthy)

# Logs de migraciones de Laravel (primer arranque)
docker logs bookstack 2>&1 | grep -E 'Migrating|Migrated' | head
# Migrating: 2014_10_12_000000_create_users_table
# Migrated:  2014_10_12_000000_create_users_table (Xms)
# ... (decenas de migrations en orden)
```

`STATUS=(healthy)` debe llegar en ~60 s (primer arranque incluye migrations + composer install). Si se queda `(starting)` > 2 min, lo más probable es:
- `APP_KEY` mal formateado (sin prefijo `base64:`).
- `DB_PASS` ≠ `MARIADB_PASSWORD` (Bookstack no puede conectar; logs: `SQLSTATE[HY000] [1045] Access denied`).
- Permisos de `/mnt/hd2t/apps/bookstack/uploads` mal (PUID/PGID no coincide).

Comprobación de extremo a extremo:

```bash
# /status responde JSON con `database` y `cache` en true cuando todo va bien
curl -sk https://bookstack.lan/status | jq
# {
#   "database": true,
#   "cache": true,
#   "session": true
# }

# La home carga (HTML)
curl -sI https://bookstack.lan/
# HTTP/2 200
```

---

## Configuración

### 1) Bootstrap: cuenta admin local

Con `AUTH_METHOD=standard` (paso 3 del despliegue), abrir desde un navegador con la CA interna instalada:

```
https://bookstack.lan/login
```

- Email: `admin@admin.com`
- Password: `password`

Inmediatamente tras el login, cambiar la cuenta admin:

1. **My Account** (avatar arriba a la derecha) → **Edit Profile**.
2. Cambiar email a algo descriptivo (ej. `admin-local@homelab.lan`) y nombre a `Admin local (fallback)`.
3. Cambiar password a un valor aleatorio largo (`openssl rand -base64 30`); anotarlo **solo** en KeePassXC offline. Esta cuenta es contingencia, no se usa día a día.

### 2) Registrar el client OIDC `bookstack` en Authelia

En `/mnt/hd2t/apps/authelia/config/configuration.yml`, dentro de `identity_providers.oidc.clients`, añadir el bloque:

```yaml
identity_providers:
  oidc:
    # ... hmac_secret, issuer_private_key (ya definidos en 04-seguridad/01-authelia.md)
    clients:
      # ... otros clients existentes
      - client_id: bookstack
        client_name: Bookstack
        # Generar:
        #   docker run --rm authelia/authelia:4.38.10 \
        #     authelia crypto hash generate pbkdf2 --variant sha512 \
        #     --random --random.length 64 --random.charset rfc3986
        # Apuntar el password "Random" en `secrets/authelia/oidc-bookstack.env`
        # y el hash "Digest" aquí.
        client_secret: '$pbkdf2-sha512$310000$<hash-del-secret>'
        public: false
        authorization_policy: two_factor
        redirect_uris:
          - https://bookstack.lan/oidc/callback
        scopes:
          - openid
          - profile
          - email
          - groups
        userinfo_signed_response_alg: none
        token_endpoint_auth_method: client_secret_basic
        consent_mode: implicit
```

Recargar Authelia:

```bash
docker compose -f /home/homelab/homelab/stacks/authelia/docker-compose.yml \
    up -d --force-recreate
docker logs authelia 2>&1 | grep -E 'oidc|client_id=bookstack' | tail
# expected: "Provider: registered client" client_id=bookstack
```

### 3) Activar OIDC en Bookstack

Editar `stacks/bookstack/.env`:

```bash
sed -i 's/^AUTH_METHOD=.*/AUTH_METHOD=oidc/' stacks/bookstack/.env
sed -i 's/^OIDC_CLIENT_SECRET=.*/OIDC_CLIENT_SECRET=PEGA_EL_PASSWORD_RANDOM_DEL_PASO_2/' \
    stacks/bookstack/.env

docker compose -f stacks/bookstack/docker-compose.yml \
    --env-file stacks/bookstack/.env \
    up -d --force-recreate bookstack
```

Tras el restart, la página de login de Bookstack muestra **un único botón** "Authelia" (gracias a `OIDC_DUMP_USER_DETAILS=false`) en lugar del formulario email/password. Pulsarlo redirige a `https://auth.lan/?rd=...`, Authelia pide TOTP (política `two_factor`) y devuelve el `id_token`. Bookstack provisiona automáticamente la cuenta del operador con rol "Viewer" por defecto.

### 4) Promover al operador a rol "Admin"

Como la cuenta del operador OIDC se creó con rol "Viewer", hace falta usar la cuenta admin local **una vez** para promoverlo:

1. Logout (esquina superior derecha → "Log out").
2. En el login OIDC, pulsar el enlace "Use a Local Account" (visible solo si Bookstack detecta cuentas locales con password).
3. Login con `admin-local@homelab.lan` + password aleatorio (KeePassXC).
4. **Settings → Users**, click en el email del operador OIDC.
5. **Roles**: marcar "Admin", desmarcar "Public".
6. Save.
7. Logout, volver a entrar con OIDC. Ahora el operador es admin.

> **Para mantenimiento futuro**: si se quiere automatizar el mapeo "grupo Authelia `admins` → rol Bookstack `Admin`", crear en Bookstack un rol con el nombre exacto `admins` (`Settings → Roles → Create New Role`) y dar a ese rol los permisos de Admin. Authelia ya manda `groups: ["admins", "family"]` en el `id_token`; Bookstack, con `OIDC_USER_TO_GROUPS=true`, asigna automáticamente. Documentado en la sección 5.

### 5) Mapeo automático de grupos Authelia → roles Bookstack (recomendado)

En Authelia, los grupos del operador están definidos en `users_database.yml` (`04-seguridad/01-authelia.md`). El operador típicamente está en `["admins", "family"]`.

En Bookstack:

1. **Settings → Roles → Create New Role**:
   - Display Name: `admins`
   - Description: `Sincronizado desde Authelia (claim groups)`.
   - Permissions: `[Manage app settings, Manage users, Manage roles, ...]` (todos los Admin).
   - System Permissions: marcar todo lo necesario.
2. Repetir para `family`:
   - Display Name: `family`
   - Permissions: `[Create / Edit / Delete books / chapters / pages]` (sin "Manage app settings").

Con esto, el siguiente login OIDC del operador (cuyo `groups` claim contiene `admins`) le asigna automáticamente ese rol; los miembros de la familia obtienen `family`. Si un usuario sale de `admins` en Authelia, **Bookstack no le quita el rol automáticamente** porque `OIDC_REMOVE_FROM_GROUPS=false` (lo dejamos así para evitar que un fallo transitorio de claims degrade permisos al instante; el operador hace la limpieza manual cuando toca).

### 6) Crear la primera shelf y el primer book

Para que Bookstack arranque "no vacío":

1. **Shelves** (menú superior) → **Create New Shelf**.
   - Name: `Homelab`.
   - Description: `Notas operativas vivas del homelab. Para decisiones de fondo, ver el repo en git: docs/.`.
2. Dentro de la shelf, **Create New Book** → `Operación diaria` (con descripción: `Cosas que hago cada cierto tiempo: actualizar Pi-hole listas, revisar UPS, limpiar cache de Stash...`).
3. Dentro del book, primer chapter: `Mantenimiento mensual`. Primera página: `Checklist mensual` (placeholder a rellenar).

Es solo un seed: la convención del homelab queda como **complemento** al `docs/` de git, no como sustituto. La nota "Para decisiones de fondo, ver el repo" en la descripción de la shelf evita que el operador (o la familia) confunda Bookstack con la fuente canónica de las decisiones de arquitectura.

### 7) Integrar el dump SQL en Borgmatic

En `07-backups/02-borgmatic.md` (sección "Plantilla para futuros servicios") quedaba comentado un bloque para Bookstack. Descomentarlo en `/etc/borgmatic.d/borgmatic.yaml`:

```yaml
mariadb_databases:
  - name: bookstack
    hostname: bookstack-db
    port: 3306
    username: bookstack
    password: "${MARIADB_BOOKSTACK_PASSWORD}"
    format: sql
    options: "--single-transaction --routines --triggers --events --default-character-set=utf8mb4"
```

`${MARIADB_BOOKSTACK_PASSWORD}` se exporta a Borgmatic vía systemd drop-in (mismo patrón que `${BORG_PASSPHRASE}`):

```ini
# /etc/systemd/system/borgmatic.service.d/secrets.conf
[Service]
EnvironmentFile=/home/homelab/homelab/secrets/borg/passphrase.env
EnvironmentFile=/home/homelab/homelab/secrets/db/bookstack-db.env
```

Mapeo: `MARIADB_PASSWORD` (del `bookstack-db.env`) lo lee Borgmatic como `MARIADB_BOOKSTACK_PASSWORD`. Para evitar el rename, en `bookstack-db.env` se duplica:

```bash
# secrets/db/bookstack-db.env
MARIADB_ROOT_PASSWORD=...
MARIADB_PASSWORD=...
# Alias para Borgmatic (consume el mismo valor con nombre explícito):
MARIADB_BOOKSTACK_PASSWORD=...   # MISMO valor que MARIADB_PASSWORD
```

Verificar:

```bash
sudo borgmatic config validate
# All configs valid

# Test manual del dump (Borgmatic mete el dump en /root/.borgmatic/...
# por defecto; con la config `format: sql` el fichero queda en
# /root/.borgmatic/mariadb_databases/bookstack-db/bookstack)
sudo borgmatic create --dry-run --list 2>&1 | grep -i bookstack
```

> **Patrón de exclusión**: añadir a `borgmatic.yaml → exclude_patterns`:
> ```yaml
> - '/mnt/hd2t/apps/bookstack/db'  # raw InnoDB; el dump SQL es la copia canónica
> ```

### 8) Monitor en Uptime Kuma

En `https://uptime.${DOMAIN_LAN}/` añadir un **monitor HTTP(s)**:

| Campo | Valor |
|---|---|
| Friendly Name | `Bookstack` |
| URL | `https://bookstack.lan/status` |
| Heartbeat Interval | 60 s |
| Retries | 3 |
| Accepted Status Codes | 200 |
| Notification | Telegram + email (Mailrise cuando exista) |
| Public on status page | Sí |

`/status` es un endpoint público de Bookstack que valida database + cache + session y responde JSON. **No** requiere auth, **no** revela info sensible. Equivalente a `/alive` de Vaultwarden.

---

## Almacenamiento

| Ruta | Soporte | Owner:Group | Modo | Contenido |
|---|---|---|---|---|
| `/home/homelab/homelab/stacks/bookstack/docker-compose.yml` | microSD | `homelab:homelab` | `0640` | Stack versionado en git. |
| `/home/homelab/homelab/stacks/bookstack/.env.example` | microSD | `homelab:homelab` | `0644` | Plantilla versionada. |
| `/home/homelab/homelab/stacks/bookstack/.env` | microSD | `homelab:homelab` | `0600` | `APP_KEY`, `DB_PASS`, `OIDC_CLIENT_SECRET`. **No** versionado. |
| `/home/homelab/homelab/secrets/db/bookstack-db.env` | microSD | `homelab:homelab` | `0600` | `MARIADB_*_PASSWORD`. **No** versionado. |
| `/home/homelab/homelab/stacks/caddy/conf.d/41-bookstack.caddy` | microSD | `homelab:homelab` | `0644` | Drop-in de Caddy. **Versionado**. |
| `/mnt/hd2t/apps/caddy/etc/conf.d/41-bookstack.caddy` | hd2t | `homelab:homelab` | `0644` | Drop-in materializado. |
| `/mnt/hd2t/apps/bookstack/config/` | hd2t | `${PUID}:${PGID}` (homelab) | `0750` | Estado interno de la imagen LSIO (caché Laravel, claves runtime). |
| `/mnt/hd2t/apps/bookstack/uploads/` | hd2t | `${PUID}:${PGID}` | `0750` | **Adjuntos e imágenes inline**. CRÍTICO: sin esto, las páginas con imágenes muestran 404. |
| `/mnt/hd2t/apps/bookstack/uploads/files/` | hd2t | `${PUID}:${PGID}` | `0750` | Adjuntos arbitrarios (PDFs, ZIPs). |
| `/mnt/hd2t/apps/bookstack/uploads/images/` | hd2t | `${PUID}:${PGID}` | `0750` | Imágenes embebidas en páginas (galleries, diagrams, fotos). |
| `/mnt/hd2t/apps/bookstack/db/` | hd2t | `999:999` (UID interno de MariaDB) | `0700` | InnoDB raw. **NO** se respalda raw — se respalda el dump SQL. |

> **Tamaño esperado**:
> - BBDD con 200 páginas + 50 adjuntos + revisiones: ~30–80 MiB.
> - `uploads/`: depende del uso. Una página con un PDF de 2 MiB ya pesa más que la BBDD entera. Estimar 1–5 GiB tras un par de años de uso doméstico.
> - `config/`: ~100 MiB (caché de Laravel, vendor de composer).

> **Sobre los UIDs `999:999` en `db/`**. La imagen oficial `mariadb:11.4.4-noble` corre como UID 999 (mariadb). Es **distinto** del UID del operador (`PUID=1000`). Por eso `db/` queda en `root:root` desde la perspectiva del host hasta que MariaDB arranca y crea ficheros con `999:999`. No hay conflicto: solo MariaDB lee/escribe en `db/`. Borg corre como root y puede leer todo (pero, como ya se decidió, **no respalda raw**).

---

## Backup

A nivel del repositorio del homelab:

| Artefacto | Estrategia |
|---|---|
| `stacks/bookstack/docker-compose.yml`, `.env.example` | Versionados en git. Reproducibles tras un reflasheo. |
| `stacks/caddy/conf.d/41-bookstack.caddy` | Versionado en git (se materializa en `/mnt/hd2t/apps/caddy/etc/conf.d/`). |
| `stacks/bookstack/.env` (con `APP_KEY` y `OIDC_CLIENT_SECRET` reales) | **No** versionado. Respaldado por Borg como parte de `/home/homelab/homelab/`. |
| `secrets/db/bookstack-db.env` | **No** versionado. Respaldado por Borg como parte de `/home/homelab/homelab/`. |
| Decisiones (Authelia OIDC, MariaDB, dump SQL como canónico) | Documentadas en este fichero. |

A nivel de datos (Borgmatic, Fase 7):

| Ruta | ¿Se respalda? | Por qué |
|---|---|---|
| Dump SQL de la BBDD `bookstack` (vía hook `mariadb_databases`) | **Sí**, T1. | Snapshot consistente vía `--single-transaction`. Es la fuente de verdad para restore. |
| `/mnt/hd2t/apps/bookstack/uploads/` | **Sí**, T1. | Sin estos ficheros, las páginas con imágenes/adjuntos muestran 404. |
| `/mnt/hd2t/apps/bookstack/config/` | **Sí**, T2. | Recreable por la imagen LSIO en arranque (`composer install`, caché Laravel), pero respaldarlo evita un primer arranque lento (~3 min) tras restore. |
| `/mnt/hd2t/apps/bookstack/db/` | **Excluido** explícitamente. | InnoDB raw; se respalda el dump SQL en su lugar. |

Patrón de exclusión en `borgmatic.yaml`:

```yaml
exclude_patterns:
  - '/mnt/hd2t/apps/bookstack/db'
```

Verificación trimestral de restore (Fase 7, calendario Q1 → Bookstack, ver `07-backups/03-backup-docker-volumes.md`):

```bash
# 1) Levantar un MariaDB temporal aislado
docker run -d --rm --name drill-mariadb \
    -e MARIADB_ROOT_PASSWORD=drill \
    -e MARIADB_DATABASE=bookstack \
    -e MARIADB_USER=bookstack \
    -e MARIADB_PASSWORD=drill \
    mariadb:11.4.4-noble

# 2) Restaurar el último dump del archive Borg
sudo borg extract --list \
    /mnt/hd2t/backups/borg::homelab-LATEST \
    root/.borgmatic/mariadb_databases/bookstack-db/bookstack \
    -o /tmp/restore-test

# 3) Aplicar el dump
docker exec -i drill-mariadb \
    mariadb -u root -pdrill bookstack \
    < /tmp/restore-test/root/.borgmatic/mariadb_databases/bookstack-db/bookstack

# 4) Validar count de tablas y de páginas
docker exec drill-mariadb \
    mariadb -u root -pdrill bookstack -e \
    "SELECT COUNT(*) FROM users; SELECT COUNT(*) FROM pages;"

# 5) Cleanup
docker stop drill-mariadb
sudo rm -rf /tmp/restore-test
```

Procedimiento de restore tras pérdida del contenedor (datos intactos en `hd2t`):

```bash
docker compose -f /home/homelab/homelab/stacks/bookstack/docker-compose.yml \
    --env-file /home/homelab/homelab/.env \
    --env-file /home/homelab/homelab/stacks/bookstack/.env \
    up -d --force-recreate
# Bookstack reusa /mnt/hd2t/apps/bookstack/{db,uploads,config}.
# Las sesiones activas siguen válidas (cookies cifradas con APP_KEY).
```

Procedimiento de restore tras pérdida total (reflasheo + restauración Borg):

1. Recrear sistema base (Fase 1), Docker (Fase 2.1), red `homelab` (Fase 2.2), Pi-hole (`02-pihole.md`), Caddy (`04-caddy.md`), Authelia (`01-authelia.md`).
2. Restaurar el repo del homelab y los secrets:
   ```bash
   sudo borg extract /mnt/hd2t/backups/borg::homelab-LATEST \
       home/homelab/homelab
   sudo chown -R homelab:homelab /home/homelab/homelab
   sudo chmod 0600 /home/homelab/homelab/stacks/bookstack/.env
   sudo chmod 0600 /home/homelab/homelab/secrets/db/bookstack-db.env
   ```
3. Restaurar `/mnt/hd2t/apps/bookstack/{uploads,config}` desde Borg:
   ```bash
   sudo borg extract /mnt/hd2t/backups/borg::homelab-LATEST \
       mnt/hd2t/apps/bookstack/uploads \
       mnt/hd2t/apps/bookstack/config
   ```
4. Levantar **solo** el sidecar de BBDD (vacío, `db/` no se restauró):
   ```bash
   cd /home/homelab/homelab
   docker compose -f stacks/bookstack/docker-compose.yml \
       --env-file stacks/bookstack/.env \
       up -d bookstack-db
   ```
5. Restaurar el dump SQL al sidecar:
   ```bash
   sudo borg extract /mnt/hd2t/backups/borg::homelab-LATEST \
       root/.borgmatic/mariadb_databases/bookstack-db/bookstack \
       -o /tmp/restore

   docker exec -i bookstack-db \
       mariadb -u root -p"$(grep MARIADB_ROOT_PASSWORD secrets/db/bookstack-db.env | cut -d= -f2)" \
       bookstack < /tmp/restore/root/.borgmatic/mariadb_databases/bookstack-db/bookstack

   sudo rm -rf /tmp/restore
   ```
6. Levantar Bookstack:
   ```bash
   docker compose -f stacks/bookstack/docker-compose.yml \
       --env-file stacks/bookstack/.env \
       up -d
   ```
7. Verificar `https://bookstack.lan/status` (200 con `database: true`), login OIDC.

> **Punto de no retorno**: el RPO máximo es **24 h** (frecuencia diaria de Borgmatic). Cambios entre el último backup y la pérdida se pierden. Para Bookstack es **aceptable** (el contenido es notas operativas, no transaccional como Vaultwarden); si el operador quiere RPO menor, añadir un timer `bookstack-borg-only.timer` cada 6 h (reabrible).

---

## Errores frecuentes y troubleshooting

| Síntoma | Causa probable | Resolución |
|---|---|---|
| `STATUS=(starting)` indefinidamente, logs muestran `SQLSTATE[HY000] [1045] Access denied` | `DB_PASS` (en `.env` de Bookstack) ≠ `MARIADB_PASSWORD` (en `secrets/db/bookstack-db.env`). | Hacerlos iguales. `up -d --force-recreate bookstack`. |
| Login OIDC redirige a Authelia y vuelve con `redirect_uri_mismatch` | Caddy no está mandando `X-Forwarded-Proto: https` y Bookstack construye `redirect_uri` con `http://`. | Verificar que el drop-in `41-bookstack.caddy` tiene `header_up X-Forwarded-Proto {scheme}`. Reload Caddy. |
| Login OIDC redirige y vuelve con `invalid_client` | El `OIDC_CLIENT_SECRET` en `.env` de Bookstack no es la versión "Random" (claro) sino el "Digest" (hash) de Authelia. | Volver a generar con `authelia crypto hash generate pbkdf2`. La salida tiene `Random:` (= claro, va a Bookstack) y `Digest:` (= hash, va a `configuration.yml` de Authelia). |
| Tras login OIDC, el usuario aparece como "Viewer" sin permisos para crear páginas | Comportamiento por defecto: nuevos usuarios entran como Viewer. | Promoverlo manualmente la primera vez (sección "Configuración → 4") o crear roles `admins`/`family` en Bookstack para mapeo automático (sección 5). |
| Las imágenes embebidas en páginas se rompen tras un restore | `uploads/` no se restauró completamente, o los UIDs cambiaron y la imagen LSIO no puede leer los ficheros. | `chown -R ${PUID}:${PGID} /mnt/hd2t/apps/bookstack/uploads`. Verificar `ls -la /mnt/hd2t/apps/bookstack/uploads/images/`. |
| `borgmatic check` se queja de "MySQL/MariaDB connection refused" | El sidecar `bookstack-db` está parado, o Borgmatic no está en la red `bookstack-internal`. | Borgmatic corre fuera de Docker (en el host); accede vía `localhost:3306` solo si el sidecar tuviera `ports:` mapeados (no es el caso). Solución canónica: ejecutar el dump **dentro** del sidecar con `docker exec` y un script `before_backup` (similar al `borg-pre-backup.sh` de Vaultwarden), volcar a `/mnt/hd2t/backups/dumps/bookstack/` y hacer que Borgmatic respalde el fichero. **Esta sustitución se activa en `07-backups/03-backup-docker-volumes.md` cuando MariaDB aparece en el homelab**. |
| `APP_KEY` cambió accidentalmente y nadie puede entrar | Las cookies de sesión cifradas con la clave anterior son ilegibles. El `OIDC_CLIENT_SECRET` cifrado en BBDD también. | Restaurar el `APP_KEY` original desde el git log o desde un backup del `.env`. Si no hay copia: aceptar que todos los usuarios deben relogarse (las cookies caducan al instante; el OIDC se vuelve a negociar). |
| Bookstack consume mucha CPU en idle | Modo debug accidentalmente activo (`APP_DEBUG=true`) o cron interno de Bookstack ejecutando `php artisan queue:work` en bucle. | Verificar `APP_DEBUG: "false"` en compose. Para el queue: la imagen LSIO ya gestiona; si arde, `docker exec bookstack ps -ef \| grep php`. |
| Búsqueda full-text no encuentra páginas recién creadas | El índice de búsqueda de Bookstack es incremental pero a veces queda obsoleto tras imports masivos. | `docker exec -u abc bookstack php /app/www/artisan bookstack:regenerate-search`. Tarda ~30 s con < 1000 páginas. |
| Tras subir versión (`24.05.4` → `24.10.0`) la BBDD no migra y Bookstack arranca con HTTP 500 | Migración de schema que requiere `php artisan migrate --force`. La imagen LSIO suele ejecutarlo automáticamente, pero si falla queda manual. | `docker exec -u abc bookstack php /app/www/artisan migrate --force`. **Antes de cualquier upgrade**: `borgmatic create --tag pre-bookstack-upgrade-X.Y.Z`. |
| Tras invitar a un usuario, el email no llega | `MAIL_DRIVER=log` (Mailrise no desplegado todavía, Fase 11). | Comportamiento esperado. La invitación se vuelca a `docker logs bookstack`; copiar la URL de "Setup your account" y enviarla por canal seguro. Cuando Mailrise exista, `MAIL_DRIVER=smtp`, `MAIL_HOST=mailrise`, `MAIL_PORT=8025`, `up -d --force-recreate`. |
| `Sessions are not working` (todos los usuarios ven la home como deslogueados pese a haber entrado) | Cookie de sesión no se persiste: `session.same_site` o `secure` mal con HTTPS detrás de Caddy. | Verificar que Caddy pasa `X-Forwarded-Proto: https`. Bookstack usa `secure` cookies cuando detecta `https`. |

---

## Decisiones que **no** se toman en este documento

- **SMTP saliente real** (Mailrise / relay externo): a la espera de Fase 11 (`mailrise.md`). Hoy `MAIL_DRIVER=log` cubre el caso "ver la URL de invitación en `docker logs`".
- **Edición colaborativa en tiempo real** (Etherpad-style): no existe en Bookstack OSS; existe parcialmente en alternativas (Outline, BookStack Plus comercial). Diferido. Si se requiere, considerar migración a Outline (más complejo, requiere Postgres + Redis).
- **WYSIWYG vs Markdown como predeterminado**: cada usuario lo elige en `My Account → Preferences`. Recomendación documentada: Markdown para el operador (consistencia con git/Hugo), WYSIWYG para la familia.
- **Personalización de marca** (logo, color primario, favicon): se documenta dónde se cambia (`Settings → Customization`) pero la elección estética es del operador.
- **Páginas/books públicos** (sin login): Bookstack permite marcar contenido como público. **Deshabilitado** por convención del homelab (todo requiere login Authelia). Si en algún momento se quiere publicar (ej. una guía de "Wi-Fi para invitados"), reabrir.
- **OAuth social** (GitHub, Google, MS Entra ID): Bookstack soporta múltiples providers OAuth además de OIDC. Hoy: solo Authelia. Reabrible si se quiere abrir colaboración a externos sin crear cuenta Authelia.
- **LDAP backend**: Authelia + LDAP detrás es un patrón común en empresa. En el homelab Authelia usa `users_database.yml` (file-based, sin LDAP) — `04-seguridad/01-authelia.md`. Bookstack no se conecta a LDAP directamente; la auth la centraliza Authelia.
- **Política `OIDC_REMOVE_FROM_GROUPS=true`**: hoy `false` por seguridad operativa (un blip de claims no degrada permisos al instante). Reabrible si en el futuro la familia rota grupos con frecuencia y la sincronía manual se vuelve fricción.
- **Limit de tasa (rate limit) en Caddy delante de Bookstack**: Authelia ya rate-limitea el flujo OIDC y, dentro de Bookstack, no hay endpoints de auth público (todo pasa por OIDC). No hace falta capa extra.
- **Métricas Prometheus**: Bookstack/Laravel no exponen `/metrics` nativamente. Existen exporters comunitarios (`laravel/horizon`-style); diferidos. cAdvisor cubre RAM/CPU, Uptime Kuma cubre disponibilidad, los logs vía Loki (cuando esté) cubren auditoría.
- **Replicación de la BBDD**: descartada. Para el caso de uso (1–5 usuarios, ≤ 1000 páginas) un mariadb único + dump diario es suficiente. Si el homelab evoluciona a multi-Pi, reabrir.

---

## Verificación Final

Antes de pasar a `03-linkding.md`:

| Comprobación | Comando | Resultado esperado |
|---|---|---|
| Stack desplegado y saludable | `docker compose -f stacks/bookstack/docker-compose.yml ps` | `bookstack ... Up (healthy)`, `bookstack-db ... Up (healthy)` |
| Imágenes correctas y fijas | `docker inspect bookstack bookstack-db --format '{{.Config.Image}}'` | `lscr.io/linuxserver/bookstack:24.05.4`, `mariadb:11.4.4-noble` |
| Bookstack en redes correctas, sin `ports:` | `docker inspect bookstack --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}'`<br>`docker port bookstack` | `bookstack_bookstack-internal homelab` y `(vacío)` |
| BBDD aislada (sin `homelab`) | `docker inspect bookstack-db --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}'` | `bookstack_bookstack-internal` (NO debe aparecer `homelab`) |
| Caddy alcanza Bookstack | `docker exec caddy curl -fsS http://bookstack:80/status \| jq -r .database` | `true` |
| `/status` responde desde la LAN | `curl -sk https://bookstack.lan/status \| jq -r .database` | `true` |
| Home carga (HTML) | `curl -sI https://bookstack.lan/` | `HTTP/2 200` |
| Cert hoja firmado por la CA local | `echo \| openssl s_client -connect bookstack.lan:443 -servername bookstack.lan 2>/dev/null \| openssl x509 -noout -issuer` | `issuer=CN=Homelab Internal CA` |
| OIDC negociado correctamente | clic en "Login with Authelia" → completar 2FA → vuelve a `https://bookstack.lan/` con sesión | sin errores en la URL, avatar del operador visible arriba a la derecha |
| `AUTH_METHOD=oidc` aplicado | `docker exec bookstack printenv AUTH_METHOD` | `oidc` |
| Cuenta admin local existe pero con password aleatorio (fallback) | `docker exec bookstack-db mariadb -u bookstack -p"..." bookstack -e "SELECT email FROM users WHERE id=1;"` | `admin-local@homelab.lan` (no `admin@admin.com`) |
| Operador OIDC promovido a Admin | UI → `Settings → Users` → email del operador | rol `Admin` (o `admins` con permisos plenos si se hizo el mapeo del paso 5) |
| Hook `mariadb_databases` integrado | `sudo borgmatic config validate; grep -A4 mariadb_databases /etc/borgmatic.d/borgmatic.yaml` | `All configs valid` y bloque presente |
| Dry-run de Borgmatic incluye Bookstack | `sudo borgmatic create --dry-run --list 2>&1 \| grep -i bookstack` | rutas `mariadb_databases/bookstack-db/bookstack` y `/mnt/hd2t/apps/bookstack/uploads` |
| Patrón de exclusión activo | `grep '/mnt/hd2t/apps/bookstack/db' /etc/borgmatic.d/borgmatic.yaml` | línea presente en `exclude_patterns` |
| Monitor Uptime Kuma activo | UI Uptime Kuma, monitor `Bookstack` | verde con latencia < 500 ms |
| Datos persistidos tras reboot | `sudo reboot`; tras reconectar: `docker ps --filter name=bookstack` | `Up (healthy)` sin acción manual; las páginas siguen ahí |
| Stack en git (sin secretos) | `git status; git ls-files stacks/bookstack stacks/caddy/conf.d/41-bookstack.caddy` | `docker-compose.yml`, `.env.example`, `41-bookstack.caddy` tracked; `stacks/bookstack/.env` y `secrets/db/bookstack-db.env` ignorados |

Cumplido el último punto, el homelab tiene su **wiki interna** con TLS de la CA local, SSO real contra Authelia, BBDD MariaDB aislada en su propia red interna, dump consistente diario en Borg, restore drill documentado y monitor Uptime Kuma con alerta. La siguiente puerta es **gestión de marcadores web**: Linkding en `03-linkding.md`.

---

## Referencias

- [Documento anterior: `docs/11-productividad/01-vaultwarden.md`](./01-vaultwarden.md)
- [Documento siguiente: `docs/11-productividad/03-linkding.md`](./03-linkding.md)
- [Documento relacionado: `docs/03-red/04-caddy.md`](../03-red/04-caddy.md)
- [Documento relacionado: `docs/04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md)
- [Documento relacionado: `docs/05-monitorizacion/05-uptime-kuma.md`](../05-monitorizacion/05-uptime-kuma.md)
- [Documento relacionado: `docs/07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md)
- [Documento relacionado: `docs/07-backups/03-backup-docker-volumes.md`](../07-backups/03-backup-docker-volumes.md)
- [Documento relacionado: `docs/01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md)
- [Bookstack — Documentación oficial](https://www.bookstackapp.com/docs/)
- [Bookstack — Variables de entorno (`.env` de Laravel)](https://www.bookstackapp.com/docs/admin/configuration/)
- [Bookstack — OIDC](https://www.bookstackapp.com/docs/admin/oidc-auth/)
- [Bookstack — LinuxServer.io image](https://docs.linuxserver.io/images/docker-bookstack)
- [Bookstack — Backup & restore](https://www.bookstackapp.com/docs/admin/backup-restore/)
- [Authelia — OpenID Connect 1.0 Provider](https://www.authelia.com/configuration/identity-providers/openid-connect/provider/)
- [MariaDB — `mariadb-dump --single-transaction`](https://mariadb.com/kb/en/mariadb-dump/)
- [Imagen Docker oficial MariaDB](https://hub.docker.com/_/mariadb)
