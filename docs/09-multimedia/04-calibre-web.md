# Calibre-Web

## Descripción

Con `01-jellyfin.md`, `02-navidrome.md` y `03-audiobookshelf.md` aplicados, el homelab cubre vídeo, música, audiolibros y podcasts. Falta el último gran formato de "consumo sentado": **libros electrónicos**. Ningún servicio anterior los gestiona bien:

- **Jellyfin** tiene un tipo "Books" pensado para PDFs y EPUBs, pero su modelo está orientado a "una pista = un fichero" y trata cada libro como item monolítico: no entiende metadatos enriquecidos (series, autores con seudónimos, ratings, tags personalizados, columnas custom de Calibre), no tiene editor de metadatos en línea, no expone OPDS de forma robusta, y no se integra con lectores externos (KOReader, Kobo, Kindle).
- **Audiobookshelf** desde 2.17 tiene soporte experimental para ebooks dentro de una biblioteca de audiolibros (un libro con audio + epub junto), pero **no es** un gestor de biblioteca de ebooks: no entiende `metadata.db` de Calibre, no convierte formatos, no envía a Kindle, no hace push a Kobo. Su modelo encaja para "el audiolibro de tal libro y, opcionalmente, su versión escrita". No para una biblioteca de cientos de novelas.

**Calibre-Web** (en adelante, CW) es un frontend web para una **biblioteca Calibre existente** — la biblioteca canónica que el operador típicamente ya tiene en su escritorio con la app Calibre. Está escrito en Python (Flask), trabaja sobre el `metadata.db` (SQLite) que Calibre crea, y aporta sobre Calibre puro tres cosas que importan en un homelab:

1. **UI web limpia y rápida**, mucho más ligera que el Content Server que trae Calibre desktop, con búsqueda, filtros por tag/serie/autor/rating/idioma, y un lector EPUB/PDF/CBZ integrado.
2. **OPDS 1.2** estable, consumible por **KOReader**, **Moon+ Reader**, **PocketBook Reader**, **Aldiko**, **Marvin**, **KyBook**, etc., con autenticación por HTTP Basic. Es el cliente principal en este homelab para móvil y eReader Wi-Fi.
3. **Send-to-Kindle / Send-to-Kobo / Kobo Sync** (opcionales): Calibre-Web puede enviar libros por email a una dirección `@kindle.com`, exponer un endpoint **Kobo Sync** para que un Kobo sincronice colecciones y posición de lectura sin pasar por el cloud de Rakuten, y **conversión de formato** bajo demanda (EPUB → MOBI/AZW3 cuando se envía a un Kindle viejo) si los binarios `calibre` están disponibles en el contenedor.

Su rol concreto en el homelab:

1. **Servir y editar la biblioteca Calibre** que vive en `/mnt/hd2t/apps/calibre-web/books/`, con su `metadata.db` (la BBDD canónica del catálogo de libros, formato Calibre), las portadas (`cover.jpg` por libro) y los ficheros (`Autor/Título (id)/título.epub`, `título.pdf`, etc.).
2. **Permitir importar libros nuevos** desde la UI ("Upload"), o desde el "watcher" sobre `/mnt/hd2t/media/ebooks/` que CW puede usar como **drop zone** (el operador deja ficheros ahí, CW los importa al árbol canónico de la biblioteca y los retira de la inbox).
3. **Servir todo** vía:
   - **UI web propia** accesible en `https://calibre-web.${DOMAIN_LAN}/` y `https://calibre-web.${DOMAIN_TS}/`.
   - **OPDS 1.2** en `https://calibre-web.${DOMAIN_LAN}/opds`, consumida por KOReader/Moon+/PocketBook/etc.
   - **Kobo Sync API** (opcional) en `/kobo/<token>/...`, consumida por un Kobo Wi-Fi reflasheado o configurado para apuntar a una URL alternativa.
4. **Enviar libros a un Kindle** (opcional) por SMTP. Convierte EPUB→MOBI/AZW3 si los binarios de Calibre están instalados (decisión: sí, ver "Decisión: conversión de formatos").
5. **Sincronizar progreso de lectura** entre dispositivos para clientes que lo soporten (Kobo Sync, KOReader vía la app `KOSync` que CW no implementa nativamente; KOReader lo hace contra un servidor independiente o contra Calibre-Web vía un patch comunitario — fuera de alcance).

Lo que este documento **no** decide:

- **Qué cliente OPDS instalar en cada dispositivo**: depende del usuario. Se recomiendan KOReader (universal: Android, Linux, eReaders Kobo/Kindle reflasheados) y Moon+ Reader (Android), pero no se entra en su configuración interna.
- **Si se reflashea un Kobo con KOReader/NickelMenu**: fuera de alcance. Si el operador quiere usar Kobo Sync nativo, se cubre la activación en CW; cómo apuntar el Kobo al servidor (DNS spoofing, hosts, etc.) queda fuera.
- **Si Audiobookshelf indexa una segunda biblioteca de ebooks** en `/mnt/hd2t/media/ebooks/`: no. La gestión de ebooks pertenece a CW; mezclarla con ABS rompería las dos. Si en el futuro se quieren audiolibros con su contraparte EPUB en el mismo item ABS, ABS lee su propia carpeta `audiobooks/` y allí cohabitan el M4B y el EPUB del mismo libro. CW seguirá ignorando `audiobooks/`.
- **Sincronización con Calibre desktop**: CW **modifica `metadata.db`** y los ficheros de la biblioteca cuando el operador edita metadatos o sube libros desde la UI. Si el operador también usa Calibre desktop sobre la **misma carpeta** simultáneamente (montada por NFS/Samba), hay riesgo de conflicto en `metadata.db`. La política sana: la biblioteca canónica vive en el servidor; el desktop solo se usa para importar batches grandes, **con CW parado**.
- **Generación de portadas IA, scrapers OCR de PDF, eBook authoring**: fuera de alcance. CW solo cataloga y sirve.
- **Authelia delante de CW**: descartado. OPDS usa HTTP Basic Auth, Kobo Sync usa token-bearing URLs propietarias, Send-to-Kindle es server-side (sin sesión); todas estas APIs se rompen con `forward_auth` cookie-based, igual que en JF/ND/ABS.

Cuando este documento se haya aplicado, el operador puede:

- Abrir `https://calibre-web.${DOMAIN_LAN}/` desde la LAN (con CA interna) o `https://calibre-web.${DOMAIN_TS}/` desde el tailnet, completar el setup inicial (apuntar a la biblioteca y crear admin), y ver el catálogo Calibre indexado.
- Configurar **al menos un cliente OPDS** (KOReader o Moon+) apuntando a `https://calibre-web.${DOMAIN_LAN}/opds` con usuario no-admin, descargar un EPUB y empezar a leer.
- Confirmar que CW lee/escribe `/mnt/hd2t/apps/calibre-web/books/` (biblioteca canónica) y, opcionalmente, lee/escribe `/mnt/hd2t/media/ebooks/` como inbox para imports.
- Confirmar que `docker compose down && up -d` no pierde nada (catálogo, usuarios, shelves, configuración).
- Tener `config/` y `books/` en `hd2t` listos para Borg en T1.

> **Recordatorio de alcance**: CW es **solo LAN + tailnet**. Los clientes OPDS sincronizan vía Tailscale cuando el operador está fuera de casa; no se abre puerto en el router. La caché offline de KOReader/Moon+ permite leer libros descargados aunque el tailnet no esté disponible (avión, túnel, etc.).

---

## Requisitos Previos

- **Fase 1** completa (sistema base, hostname `pi5`, zona horaria `Europe/Madrid`, **grupo `media` con GID 1100** y `homelab` miembro de él, ver `01-sistema/04-estructura-directorios.md`).
- **Fase 2** completa (Docker Engine + Compose v2; red `homelab` en `172.30.10.0/24`; convención `stacks/<svc>/`; `.env` global con `TZ`, `PUID=1000`, `PGID=1000`, `DOMAIN_LAN`, `DOMAIN_TS` si aplica).
- **Fase 3** completa, en particular:
  - Pi-hole con `address=/lan/192.168.1.10` (cubre `calibre-web.${DOMAIN_LAN}` automáticamente).
  - Caddy desplegado y los snippets `(lan_tls)`, `(security_headers)`, `(healthcheck)` en `Caddyfile`.
  - Tailscale operativo y, si se quiere `calibre-web.${DOMAIN_TS}`, `tailscale cert` activo (`03-red/05-tailscale.md`).
- **Fase 4** completa: Authelia desplegado (aunque CW queda en `bypass` por las razones descritas, ver "Decisión: autenticación").
- **Fase 7** opcional pero recomendable: Borgmatic operativo, para incluir `/mnt/hd2t/apps/calibre-web/{config,books}/` en T1.
- **Documentos `01-jellyfin.md`, `02-navidrome.md` y `03-audiobookshelf.md` aplicados**: no son bloqueantes técnicos, pero las decisiones comunes (estructura `apps/`, política de bypass en Authelia, Caddy drop-ins por servicio, watchtower deshabilitado por servicio, healthcheck via `curl`) ya están tomadas allí y aquí se aplican igual.
- Disco `hd2t` montado en `/mnt/hd2t` con `/mnt/hd2t/media/ebooks/` ya creado por `01-sistema/04-estructura-directorios.md` con owner `homelab:media` y modo `2770` (setgid). El árbol `/mnt/hd2t/apps/calibre-web/{config,books}` también ha sido creado (`homelab:homelab`, `0750`).
- **Biblioteca Calibre existente** (recomendado): un directorio con `metadata.db` y la estructura `Author Name/Book Title (id)/book.epub` que Calibre desktop ha venido manteniendo. Si no existe, CW puede partir de una biblioteca vacía y crearla en su primer arranque.
- Operador con la **CA interna instalada** en navegador y, si va a usar OPDS desde un eReader o app móvil, en el dispositivo (Android/iOS/KOReader).

Comprobaciones rápidas:

```bash
# La red Docker compartida y Caddy
docker network inspect homelab --format '{{.Name}}' | grep -q '^homelab$' && echo ok
docker ps --filter name=caddy --format '{{.Names}} {{.Status}}'

# DNS interno resuelve calibre-web.lan
dig +short calibre-web.lan @192.168.1.2
# 192.168.1.10

# Estructura books/ y ebooks/ correcta
getent group media
# media:x:1100:homelab
stat -c '%a %U:%G' /mnt/hd2t/apps/calibre-web/books
# 750 homelab:homelab
stat -c '%a %U:%G' /mnt/hd2t/media/ebooks
# 2770 homelab:media

# (Opcional) la biblioteca Calibre origen accesible para copiar
ls /ruta/a/calibre/library/metadata.db 2>/dev/null && echo "biblioteca Calibre detectada"
```

---

## Decisión: imagen — `lscr.io/linuxserver/calibre-web` (LSIO)

Existen dos imágenes principales para Calibre-Web:

| Imagen | Mantenedor | Tag de referencia | Pros | Contras |
|---|---|---|---|---|
| `technosoft2000/calibre-web` | Comunidad (legacy) | `:latest` | Imagen histórica, muy referenciada en tutoriales antiguos. | Mantenimiento errático, sin multi-arch arm64 estable, no rompe nada pero ya no recibe parches con frecuencia. |
| `lscr.io/linuxserver/calibre-web` | LinuxServer.io | `:0.6.24` (multi-arch incluyendo arm64) | UID/GID configurables (`PUID`/`PGID`), patrón homogéneo con Jellyfin/Audiobookshelf/Stash. Healthcheck script integrado. **Soporta `DOCKER_MODS=linuxserver/mods:universal-calibre`** que añade los binarios `ebook-convert`/`calibredb` necesarios para conversión de formato. Releases coordinadas con upstream `janeczku/calibre-web`. | Una capa más entre upstream y el operador (s6-overlay, scripts LSIO). Las versiones llegan con 1–3 días de desfase respecto a upstream. |

**Decisión**: `lscr.io/linuxserver/calibre-web:0.6.24`.

Razones:

- **Coherencia con Fase 9**: Jellyfin, Audiobookshelf y Stash usan LSIO. Mismas variables (`PUID`, `PGID`, `TZ`, `UMASK`), mismo modelo de timezone, mismo arranque s6 → operativa idéntica.
- **`group_add: ["1100"]`** funciona limpio: el grupo `media` se inyecta sin tocar la imagen. Necesario para que CW pueda leer/escribir `/mnt/hd2t/media/ebooks/` (inbox).
- Pin a versión completa (`0.6.24`), no a `latest` ni a `0.6`. CW publica patches con relativa frecuencia (4–8 al año aprox.); algunas migraciones tocan la BBDD interna de CW (`app.db`) y conviene aplicarlas deliberadamente.
- **`DOCKER_MODS=linuxserver/mods:universal-calibre`** disponible: el mod añade los binarios `calibre` (~500 MiB) habilitando conversión de formato bajo demanda. Decisión: activado (ver "Decisión: conversión de formatos").

Actualizaciones: `docker compose pull && up -d` después de leer release notes en `https://github.com/janeczku/calibre-web/releases`. Watchtower etiqueta el contenedor con `homelab.role: "ebook-server"` y, **dado que el tag es completo**, no hace pull automático.

> **Sobre `:latest`**: CW está en serie 0.6.x desde hace años con bumps de patch. Pin estricto evita sorpresas (en 2023 una migración 0.6.20 → 0.6.21 cambió el esquema de `app.db` para soportar Kobo Sync; arrancar con `:latest` sin advertirlo dejó a varios homelabs con la BBDD a medio migrar y los shelves del usuario perdidos). Conservador siempre.

---

## Decisión: networking — bridge `homelab` (sin `ports:`)

Igual que Jellyfin (`01-jellyfin.md`), Navidrome (`02-navidrome.md`) y Audiobookshelf (`03-audiobookshelf.md`):

- CW escucha en `:8083/tcp` dentro del contenedor (puerto por defecto de la imagen LSIO; cambiable con la env `APPLICATION_PORT`, pero no se altera).
- **Sin `ports:`** publicados al host: Caddy hace `reverse_proxy http://calibre-web:8083` resolviendo el nombre por DNS interno del bridge.
- UI web, OPDS, Kobo Sync API y Send-to-Kindle (todo HTTP) comparten puerto, así que una sola entrada de Caddy cubre todo. OPDS responde en `/opds`, Kobo en `/kobo/<token>/`, la UI en `/`.
- **Streaming/descarga de libros** (`/cover/<id>`, `/get/<id>/<format>`) viaja por el mismo puerto; los clientes OPDS descargan el EPUB completo (no hay range requests específicos, pero Caddy soporta el header `Range:` transparentemente si el cliente lo usa).
- **No hay WebSockets** en CW (a diferencia de ABS): la UI usa peticiones AJAX/REST puras, sin socket.io ni SSE. El reverse proxy es el más simple de la fase.
- **mDNS / discovery**: CW no implementa discovery automático; los clientes piden la URL OPDS a mano. No se intenta `network_mode: host`.

---

## Decisión: dónde viven los datos y permisos

Tres tipos de datos:

| Tipo | Dónde | Owner:Group | Modo | Observaciones |
|---|---|---|---|---|
| **Configuración + BBDD interna** (`config/`): SQLite `app.db` con usuarios, shelves, sesiones, ajustes; `gdrive.db`, `gdrive_credentials`. | `/mnt/hd2t/apps/calibre-web/config/` | `homelab:homelab` (`1000:1000`) | `0750` | El "alma" de CW: usuarios, shelves, configuración de SMTP/Kobo. Crítico para backup. Pérdida = recreación manual de usuarios y shelves; el catálogo (que vive en `metadata.db` dentro de `books/`) no se ve afectado. |
| **Biblioteca Calibre** (`books/`): `metadata.db` (la BBDD canónica del catálogo de libros, formato Calibre), portadas, ficheros EPUB/PDF/MOBI/CBZ organizados como `Autor/Título (id)/`. | `/mnt/hd2t/apps/calibre-web/books/` | `homelab:homelab` (`1000:1000`) | `0750` | **El catálogo real**. CW lo monta **read-write**: edita metadatos, importa libros nuevos, mueve carpetas cuando se renombra un autor. **Sí se respalda** (T1: `metadata.db`; T2: ficheros). |
| **Inbox de imports** (`/mnt/hd2t/media/ebooks/`): drop zone para libros nuevos. El operador deja un `nuevo.epub` aquí; CW lo importa (mueve a `books/Autor/Título (id)/`) y lo elimina de la inbox (o lo deja, según política). | `/mnt/hd2t/media/ebooks/` | `homelab:media` (`1000:1100`) | `2770` (setgid) | Bind mount **read-write**. Compartido vía grupo `media` para que el operador lo pueble desde Samba (`06-almacenamiento/02-samba.md`) o desde otros servicios. CW escribe aquí solo cuando borra el origen tras importar. |

| Opción | Pros | Contras | Veredicto |
|---|---|---|---|
| Volumen Docker nombrado para `config/` y `books/` | Menos pelea con permisos. | Datos en `/var/lib/docker/volumes/...` (microSD). `books/` puede crecer 5–50 GiB; rompe la convención del homelab. La biblioteca queda inaccesible para Calibre desktop si se quisiera un import puntual. | Descartado. |
| `books/` en `/mnt/hd2t/media/ebooks/` (mismo dir como inbox y biblioteca) | Una ruta menos. | CW renombra carpetas y mueve ficheros constantemente cuando el operador edita metadatos; si esa carpeta también es la inbox compartida vía Samba, hay riesgo de conflictos (un usuario subiendo un fichero a la vez que CW reorganiza). Además, **`metadata.db` no debe estar en una carpeta con ACLs `2770` que el grupo escribe**: cualquier servicio del grupo `media` podría corromperlo. | Descartado. |
| **Bind mount `homelab:homelab` con `PUID=1000`, `PGID=1000`, `group_add: [1100]`, `books/` en `apps/`, inbox en `media/ebooks/`** | Biblioteca canónica protegida (solo CW escribe). Inbox compartible con Samba. UI legible, ACLs simples. | Ninguno relevante. | **Aceptado**. |

Resultado: bind mounts a `/mnt/hd2t/apps/calibre-web/{config,books}` con `PUID=1000:PGID=1000` (sin grupo `media`), y bind mount adicional a `/mnt/hd2t/media/ebooks` con `group_add: [1100]` para acceso a la inbox.

> **Por qué `books/` en `apps/` y no en `media/`**: la biblioteca Calibre **es propiedad exclusiva** de Calibre-Web. CW edita `metadata.db` con cada cambio de tag, mueve carpetas con cada renombrado de autor, regenera portadas. Tenerla en `media/` (compartida vía grupo) abriría la puerta a que Samba o un script externo escribiera durante una operación de CW y dejara `metadata.db` corrupto. En `apps/` con `0750` solo el owner (`homelab`, vía CW) escribe. Si el operador necesita acceso desde Calibre desktop, abre Samba sobre `apps/calibre-web/books/` con CW **parado**, edita, cierra Samba, y arranca CW.

> **Por qué `metadata.db` separado de `app.db`**: son dos bases de datos distintas. `metadata.db` es de Calibre (catálogo de libros) y vive en la biblioteca; `app.db` es de Calibre-Web (usuarios, shelves) y vive en `config/`. Tenerlas en bind mounts distintos permite políticas de backup distintas y restaurar una sin tocar la otra.

> **Sobre la inbox**: `/mnt/hd2t/media/ebooks/` cumple doble función: (1) drop zone donde el operador suelta libros para importar (Samba, `scp`, descargas de OverDrive/Project Gutenberg), y (2) directorio compartido legible por otros servicios futuros (Jellyfin podría servir PDFs como "Books" desde aquí, sin pisar la biblioteca canónica). En CW, su uso primario es como "Auto Upload Path" — Settings → Basic Configuration → "Upload": habilitar y apuntar a `/inbox` (el bind mount interno).

---

## Decisión: autenticación — CW nativa, **no** Authelia

Calibre-Web tiene autenticación nativa (usuarios locales con bcrypt) y soporta múltiples mecanismos de auth para sus distintos endpoints:

| Endpoint | Mecanismo de auth | Uso |
|---|---|---|
| UI web (`/`, `/admin`, `/book/<id>`) | Cookie de sesión (Flask-Login) | Navegador. |
| OPDS (`/opds`, `/opds/...`) | **HTTP Basic Auth** | KOReader, Moon+ Reader, PocketBook, Marvin, Aldiko, KyBook. |
| Kobo Sync (`/kobo/<token>/...`) | **Token en URL** (generado por usuario) | Reader Kobo configurado para apuntar al servidor. |
| Send-to-Kindle (server-side) | N/A (cron interno; SMTP) | Email a `@kindle.com`. |
| Magic-link / Remote login (`/me`) | Token de un solo uso | Login asistido sin teclear contraseña. **Desactivado** por defecto. |

Meterlo detrás del `forward_auth` de Authelia es contraindicado por razones gemelas a JF/ND/ABS:

| Razón | Impacto |
|---|---|
| **OPDS con HTTP Basic** | Los clientes OPDS envían `Authorization: Basic <base64>` y **no mantienen cookies**. Authelia, cookie-based, las ve "no autenticadas" y redirige al portal HTML. **Resultado**: ninguna app OPDS funciona. |
| **Kobo Sync con token en URL** | El Kobo no entiende redirects a Authelia; espera respuestas binarias específicas en `/kobo/<token>/v1/library/sync`. |
| **Descarga de libros** (`/get/<id>/<format>`) | Las URLs OPDS son `https://calibre-web.lan/get/123/epub`, sin cookie. Authelia las cortaría. |
| **Send-to-Kindle (SMTP server-side)** | No es un endpoint HTTP en absoluto, pero el job se dispara desde la UI; si el usuario está autenticado por Authelia y CW lo ve "no autenticado" (porque el flujo de cookies no se propaga), el botón no funciona. |
| **App móvil con caché offline + reconexión** | KOReader y Moon+ reintentan con sus credenciales Basic cacheadas; Authelia las descarta y los clientes no saben re-loguear sin intervención. |

La política sana: **CW gestiona su propia autenticación**. Compensaciones:

- CW **no** sale de la LAN/tailnet. Quien quiera atacar el endpoint OPDS necesita ya estar dentro.
- CW **no** tiene rate limiting nativo robusto sobre `/login`. **`fail2ban` (Fase 4) puede añadir un jail para `Calibre-Web`** parseando el log Python (líneas `Failed login attempt for username '<x>'`). Reabrible.
- **Contraseñas fuertes obligatorias**: CW no fuerza política de complejidad por defecto (sí en `0.6.24+` con la opción `Force minimum password complexity`); el operador es responsable. Mínimo 16 caracteres por usuario, gestionado en gestor de contraseñas.
- **Cuenta admin separada** del uso diario.
- **Tokens Kobo revocables**: si un dispositivo se pierde, en `Admin → Edit User → Reset Kobo Token` se invalida sin tocar la contraseña ni el usuario.
- **Magic link desactivado** (`Settings → Feature Configuration → Allow Magic Link`: OFF). Es un vector adicional sin aporte en este homelab.

Reflejo en Caddy: el `Caddyfile` para CW importa **solo** `lan_tls`, `security_headers`, `healthcheck`; **no** `authelia_two_factor`. En Authelia, `calibre-web.${DOMAIN_LAN}` queda en `bypass`:

```yaml
# stacks/authelia/conf.d/09-calibre-web-bypass.yml
- domain: "calibre-web.{$DOMAIN_LAN}"
  policy: bypass
- domain: "calibre-web.{$DOMAIN_TS}"
  policy: bypass
```

> **Si un día se quiere SSO**: CW soporta **LDAP** y **Google OAuth** nativamente, y desde 0.6.20 hay un PR experimental para OIDC genérico. Permitiría delegar el login en Authelia LDAP/OIDC para la UI web; OPDS y Kobo Sync seguirían usando contraseña/token nativo (no se puede unificar). Reabrible cuando Authelia OIDC esté maduro en este homelab.

---

## Decisión: conversión de formatos — `DOCKER_MODS=universal-calibre`

CW por sí mismo **no convierte formatos**: si el operador quiere enviar un EPUB a un Kindle viejo (que solo entiende MOBI/AZW3), CW necesita los binarios `ebook-convert` / `calibredb` que vienen con la suite Calibre desktop. Hay tres opciones:

| Opción | Pros | Contras | Veredicto |
|---|---|---|---|
| Sin conversión: solo servir formatos tal cual | Imagen ligera (~150 MiB). | No se puede enviar a Kindle desde UI. No se puede convertir EPUB→PDF para imprimir. La opción "Convert" en la UI aparece grisada. | Descartado: el operador típico envía libros a Kindle ocasionalmente. |
| `lscr.io/linuxserver/calibre` (suite completa) además de `calibre-web` | Conversión enterprise, jobs server-side. | Otro contenedor más, otro stack, otra UI. Sobreingeniería para "convertir un EPUB a MOBI cada dos meses". | Descartado: el operador no necesita una suite Calibre headless completa. |
| **`DOCKER_MODS=linuxserver/mods:universal-calibre`** sobre la imagen `calibre-web` | Un solo contenedor; los binarios `calibre` se inyectan en el runtime via mod oficial LSIO. CW los detecta y habilita la conversión en la UI. Send-to-Kindle convierte automáticamente. | La imagen efectiva crece ~500 MiB. Primer arranque tras añadir el mod tarda 2–3 min en la Pi 5 mientras descarga e instala los binarios en `/config`. | **Aceptado**. |

Resultado: `environment: DOCKER_MODS: linuxserver/mods:universal-calibre`. Tras el primer arranque, en `Admin → Configuration → External Binaries` aparece la ruta detectada (`/usr/bin/ebook-convert`) y la conversión queda habilitada.

> **Coste de RAM/CPU al convertir**: una conversión EPUB → MOBI en una Pi 5 con un libro de 500 KB tarda 5–15 s y consume picos de ~300 MiB de RAM. Cargas concurrentes (10 conversiones en paralelo) pueden tirar la Pi: CW serializa internamente las conversiones, así que en la práctica solo se procesa una a la vez. No se imponen límites adicionales.

> **Sobre el mod `universal-calibre`**: es mantenido por LSIO, multi-arch (incluye arm64), y se actualiza junto a la imagen base. La instalación del mod se ejecuta en `/etc/cont-init.d/...` durante el arranque s6 y deja los binarios en `/usr/bin/`. Si en el futuro deja de mantenerse, alternativa: instalar `calibre` con `apt-get` en un `Dockerfile` derivado, o pasar a la suite headless completa.

---

## Stack: `stacks/calibre-web/`

### Layout en disco

| Ruta | Soporte | Contenido |
|---|---|---|
| `stacks/calibre-web/docker-compose.yml` | microSD (git) | Stack (servicio `calibre-web`). |
| `stacks/calibre-web/.env.example` | microSD (git) | Plantilla con variables específicas (vacía por defecto; CW no necesita secretos en env). |
| `stacks/caddy/conf.d/09-calibre-web.caddy` | microSD (git) | Drop-in del bloque LAN+tailnet para `calibre-web.${DOMAIN_LAN}` y `calibre-web.${DOMAIN_TS}`. |
| `stacks/authelia/conf.d/09-calibre-web-bypass.yml` | microSD (git) | Fragmento de access_control para añadir bypass de `calibre-web.*`. |
| `/mnt/hd2t/apps/calibre-web/config/` | hd2t | `app.db` SQLite, settings, sesiones. Owner `homelab:homelab`, modo `0750`. |
| `/mnt/hd2t/apps/calibre-web/books/` | hd2t | Biblioteca Calibre canónica (`metadata.db` + ficheros). Owner `homelab:homelab`, modo `0750`. |
| `/mnt/hd2t/media/ebooks/` | hd2t | Inbox compartida. Owner `homelab:media`, modo `2770`. |

### `stacks/calibre-web/docker-compose.yml`

```yaml
# Calibre-Web — frontend web para una biblioteca Calibre.
# Documentado en docs/09-multimedia/04-calibre-web.md.
#
# Networking: bridge homelab. Caddy hace reverse proxy hacia calibre-web:8083.
# La biblioteca canónica /mnt/hd2t/apps/calibre-web/books/ se monta read-write.
# La inbox /mnt/hd2t/media/ebooks/ se monta read-write (drop zone de imports).

name: calibre-web

networks:
  homelab:
    external: true

services:
  calibre-web:
    image: lscr.io/linuxserver/calibre-web:0.6.24
    container_name: calibre-web
    hostname: calibre-web
    restart: unless-stopped

    networks:
      - homelab

    # NO se publican puertos al host: el acceso humano va por Caddy
    # (https://calibre-web.lan). OPDS y Kobo Sync comparten puerto 8083.

    # El grupo media (1100) habilita lectura/escritura de /inbox
    # (drop zone compartida). PUID/PGID los inyecta LSIO desde el .env global.
    group_add:
      - "1100"   # media (creado en 01-sistema/04-estructura-directorios.md)

    environment:
      TZ: ${TZ}
      PUID: ${PUID:-1000}
      PGID: ${PGID:-1000}
      UMASK: "002"          # ficheros nuevos (libros importados) legibles por grupo media

      # DOCKER_MODS añade los binarios calibre (ebook-convert, calibredb)
      # necesarios para conversión de formato y Send-to-Kindle.
      # Documentado en "Decisión: conversión de formatos".
      DOCKER_MODS: "linuxserver/mods:universal-calibre"

      # APPLICATION_PORT: "8083"  # default LSIO; no se altera

    volumes:
      - /mnt/hd2t/apps/calibre-web/config:/config
      # Biblioteca canónica: read-write (CW reorganiza al editar metadatos).
      - /mnt/hd2t/apps/calibre-web/books:/books
      # Inbox compartida: read-write (CW importa libros nuevos desde aquí).
      - /mnt/hd2t/media/ebooks:/inbox
      - /etc/localtime:/etc/localtime:ro

    healthcheck:
      # CW expone /opds (siempre 200 con WWW-Authenticate) cuando la app está viva.
      # /robots.txt también funciona y no requiere auth ni tira logs.
      test: ["CMD", "curl", "-fsSL", "http://127.0.0.1:8083/robots.txt"]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 180s   # primer arranque con DOCKER_MODS tarda ~2-3 min

    labels:
      homelab.role: "ebook-server"
      homelab.backup: "true"
      # Watchtower NO actualiza automáticamente: el tag es completo y los
      # bumps de patch de CW a veces requieren atención (migraciones app.db).
      com.centurylinklabs.watchtower.enable: "false"
```

> **Sobre `UMASK: "002"`**: aunque CW solo escribe en `/config` y `/books` como `homelab:homelab` (donde el grupo no juega), si el operador llega a usar la inbox (`/inbox`) para escribir desde la UI (Auto Upload), conviene UMASK 002 para que los ficheros queden legibles por el grupo `media`. Coherente con el resto de la fase.

> **Sobre el healthcheck**: la imagen LSIO incluye `curl`. CW expone `/robots.txt` (200 sin auth) que no genera logs ni dispara handlers. Alternativa: `/opds` devuelve 401 (con WWW-Authenticate) si no hay credenciales, lo que también es válido para un healthcheck pero ensucia los logs con intentos fallidos.

> **Sobre `start_period: 180s`**: el primer arranque con `DOCKER_MODS=universal-calibre` descarga e instala los binarios Calibre (~500 MiB) durante el arranque s6. En la Pi 5 con USB 3.0 tarda 2–3 min. Tras ese primer arranque, los binarios quedan cacheados en `/config/.modcache/` y los reinicios siguientes son rápidos (~10 s).

### `stacks/calibre-web/.env.example`

```bash
# stacks/calibre-web/.env.example
# Calibre-Web no requiere variables propias por defecto. Las generales
# (TZ, PUID, PGID, DOMAIN_LAN, DOMAIN_TS) vienen del .env GLOBAL del homelab.
#
# Si en el futuro se activan integraciones (LDAP, OAuth, OIDC con Authelia,
# métricas prometheus vía exporter terciario), añadir aquí. Nada por ahora.
```

### Drop-in de Caddy: `stacks/caddy/conf.d/09-calibre-web.caddy`

```caddy
# /etc/caddy/conf.d/09-calibre-web.caddy — bloques de Calibre-Web.
# Documentado en docs/09-multimedia/04-calibre-web.md.
#
# IMPORTANTE: NO se importa authelia_two_factor (decisión documentada en
# "Decisión: autenticación"). CW gestiona su propio login y el OPDS y
# Kobo Sync usan sus propios mecanismos (Basic Auth y token en URL).

# ---- Acceso LAN ------------------------------------------------------------
calibre-web.{$DOMAIN_LAN} {
    import lan_tls
    import security_headers
    import healthcheck

    reverse_proxy http://calibre-web:8083 {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}

        # Conversión de formato puede tardar 30-60 s para libros grandes;
        # subir read/write timeouts. La descarga de un EPUB de 50 MiB
        # también necesita margen.
        transport http {
            read_timeout 5m
            write_timeout 5m
            read_buffer 64KB
        }
    }

    # Subir el límite de body para uploads desde la UI (subida manual
    # de libros vía "Upload"). EPUB típico <10 MiB, PDF puede llegar
    # a 200 MiB en libros técnicos con escaneos.
    request_body {
        max_size 250MB
    }
}

# ---- Acceso Tailscale ------------------------------------------------------
# Solo se materializa si DOMAIN_TS está definido (tailnet con tailscale cert).
calibre-web.{$DOMAIN_TS} {
    tls {
        get_certificate tailscale
    }
    import security_headers
    import healthcheck

    reverse_proxy http://calibre-web:8083 {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}

        transport http {
            read_timeout 5m
            write_timeout 5m
            read_buffer 64KB
        }
    }

    request_body {
        max_size 250MB
    }
}
```

> **Sobre `read_timeout 5m`**: la conversión EPUB → MOBI de un libro grande puede tardar 30–60 s; 5 min cubre con holgura el caso patológico (libro de 50 MiB con OCR pesado) sin acumular sockets zombi. La descarga de un PDF científico de 200 MiB también encaja.

> **Sin upgrade WebSocket**: CW no usa WebSocket en absoluto. No hace falta tocar nada en Caddy v2 al respecto. La UI usa AJAX puro.

> **Sobre `request_body max_size 250MB`**: PDFs científicos con escaneos de alta resolución pueden superar los 100 MiB. 250 MiB es un techo razonable; si el operador maneja libros aún más grandes, subir aquí (y revisar `MAX_CONTENT_LENGTH` interno de CW en su settings).

### Fragmento de Authelia: `stacks/authelia/conf.d/09-calibre-web-bypass.yml`

```yaml
# stacks/authelia/conf.d/09-calibre-web-bypass.yml
# Excluir Calibre-Web del control de acceso de Authelia.
# Se incluye desde stacks/authelia/configuration.yml mediante el mecanismo
# de merge documentado en 04-seguridad/01-authelia.md.

- domain: "calibre-web.{$DOMAIN_LAN}"
  policy: bypass
- domain: "calibre-web.{$DOMAIN_TS}"
  policy: bypass
```

### Crear directorios y desplegar

```bash
# 1) Verificar prerequisitos de estructura (Fase 1).
getent group media | grep -q '^media:x:1100:' || {
    echo "ERROR: grupo media (GID 1100) no existe. Aplicar 01-sistema/04-estructura-directorios.md."
    exit 1
}
[ -d /mnt/hd2t/media/ebooks ] || {
    echo "ERROR: /mnt/hd2t/media/ebooks no existe. Aplicar 01-sistema/04-estructura-directorios.md."
    exit 1
}

# 2) Crear directorios persistentes del servicio (idempotente).
sudo install -d -o homelab -g homelab -m 0750 /mnt/hd2t/apps/calibre-web
sudo install -d -o homelab -g homelab -m 0750 /mnt/hd2t/apps/calibre-web/config
sudo install -d -o homelab -g homelab -m 0750 /mnt/hd2t/apps/calibre-web/books

# 3) (Opcional pero recomendado) Importar una biblioteca Calibre existente
#    desde el escritorio del operador. Ver "Configuración → Importación
#    desde una biblioteca Calibre existente" más abajo. Si se omite, CW
#    creará una biblioteca vacía durante el setup inicial.

# 4) Materializar Caddy drop-in y fragmento de Authelia.
install -o homelab -g homelab -m 0644 \
    stacks/caddy/conf.d/09-calibre-web.caddy \
    /mnt/hd2t/apps/caddy/etc/conf.d/09-calibre-web.caddy

install -o homelab -g homelab -m 0644 \
    stacks/authelia/conf.d/09-calibre-web-bypass.yml \
    /mnt/hd2t/apps/authelia/etc/conf.d/09-calibre-web-bypass.yml

# 5) .env del stack: copiar la plantilla (vacía) por consistencia.
cp stacks/calibre-web/.env.example stacks/calibre-web/.env
chmod 0600 stacks/calibre-web/.env

# 6) Levantar el stack. Primer arranque tarda 2-3 min (DOCKER_MODS
#    descarga binarios Calibre).
docker compose \
    -f stacks/calibre-web/docker-compose.yml \
    --env-file .env --env-file stacks/calibre-web/.env \
    up -d

# 7) Recargar Caddy y Authelia para tomar drop-ins.
docker exec caddy caddy validate --config /etc/caddy/Caddyfile && \
    docker kill --signal=SIGUSR1 caddy
docker exec authelia kill -HUP 1 || \
    docker compose -f stacks/authelia/docker-compose.yml restart authelia

# 8) Esperar a que el primer arranque termine (descarga del mod).
docker logs -f calibre-web | grep -m1 'Starting Calibre-Web'
# ... [cont-init.d] universal-calibre: installing binaries...
# ... [cont-init.d] universal-calibre: done.
# Starting Calibre-Web...
```

Tras `up -d`:

```bash
docker ps --filter name=calibre-web
# CONTAINER ID  IMAGE                                       STATUS
# ...           lscr.io/linuxserver/calibre-web:0.6.24      Up 3 minutes (healthy)

docker logs calibre-web --tail 30
# ... [cont-init.d] universal-calibre: done.
# ... Starting Calibre-Web...
# ... [INFO] *Running on http://0.0.0.0:8083 (Press CTRL+C to quit)*

# Confirmar puertos NO publicados al host
ss -tlnp | grep ':8083 ' | grep -v 'caddy' || echo "OK: calibre-web NO publica al host"

# Probar el endpoint vía Caddy
curl -ksI https://calibre-web.lan/robots.txt
# HTTP/2 200

# Confirmar que los binarios Calibre están instalados
docker exec calibre-web ebook-convert --version
# ebook-convert (calibre 7.x.x)
```

---

## Configuración

### 1) Importación desde una biblioteca Calibre existente

Si el operador ya tiene una biblioteca Calibre creada con la app desktop, lo idiomático es **copiar la biblioteca completa** a `/mnt/hd2t/apps/calibre-web/books/` antes del primer arranque (o con CW parado). La biblioteca incluye `metadata.db` + carpetas `Autor/Título (id)/`.

```bash
# 1) Parar CW si ya está corriendo.
docker compose -f stacks/calibre-web/docker-compose.yml stop calibre-web

# 2) Copiar la biblioteca origen. Se asume que el operador trae el árbol
#    desde su escritorio por SSH/SCP/SMB; aquí ejemplo con rsync sobre SSH.
rsync -av --info=progress2 \
    user@desktop:/path/to/calibre/library/ \
    /tmp/calibre-import/

# 3) Verificar que metadata.db existe en la raíz copiada.
ls /tmp/calibre-import/metadata.db
# /tmp/calibre-import/metadata.db

# 4) Mover al destino canónico y arreglar permisos.
sudo rsync -a /tmp/calibre-import/ /mnt/hd2t/apps/calibre-web/books/
sudo chown -R homelab:homelab /mnt/hd2t/apps/calibre-web/books
sudo find /mnt/hd2t/apps/calibre-web/books -type d -exec chmod 0750 {} \;
sudo find /mnt/hd2t/apps/calibre-web/books -type f -exec chmod 0640 {} \;

# 5) Limpiar staging.
rm -rf /tmp/calibre-import

# 6) Arrancar CW.
docker compose -f stacks/calibre-web/docker-compose.yml start calibre-web
```

> **No mezclar con uploads previos**: si se importa una biblioteca existente, **no** subir libros desde la UI hasta verificar que el catálogo se ve correctamente. El primer arranque de CW lee `metadata.db` y crea su `app.db` interno; si el `metadata.db` está corrupto o incompleto, la BBDD interna de CW reflejará ese estado y luego es difícil revertir.

> **Alternativa: empezar de cero**: si no hay biblioteca previa, `/mnt/hd2t/apps/calibre-web/books/` queda vacío, y en el setup inicial (paso 2) CW propondrá "Create new database" — escogerá esa opción y creará un `metadata.db` mínimo. El operador irá subiendo libros desde la UI (`Upload` button) o vía la inbox.

### 2) Setup inicial

Desde un cliente de la LAN con la CA interna instalada:

```text
1. Abrir https://calibre-web.lan/
2. CW muestra "Database location":
   - Library path: /books
   - (si la biblioteca importada en paso 1 está bien, CW detecta metadata.db
     y muestra el contador de libros; si está vacío, escoge "Create new")
3. Submit → CW se reinicia internamente y muestra el login.
4. Primer login con credenciales por defecto:
   - Username: admin
   - Password: admin123
5. Inmediatamente: Admin → Users → admin → cambiar password
   (gestor de contraseñas; mínimo 16 caracteres).
6. (Recomendado) Crear un usuario admin alternativo con un nombre no obvio
   y desactivar el usuario "admin" original tras confirmar acceso con el
   nuevo (Admin → Users → admin → "Delete" o "Deny Access").
```

> **Si el formulario de "Database location" no aparece**: ya hay configuración previa (`/mnt/hd2t/apps/calibre-web/config/app.db` existe). Si no es la deseada, parar el contenedor, **borrar el contenido de `config/`** (perderás usuarios, shelves y settings; la biblioteca en `books/` no se toca) y volver a levantar.

### 3) Configuración básica

`Admin → Configuration → Basic Configuration`:

```text
- Server URL:           https://calibre-web.lan
- Reverse Proxy header: X-Forwarded-For
- Anonymous browsing:   OFF (login obligatorio)
- Public Registration:  OFF (no auto-registro de usuarios)
- Magic Link:           OFF
- Force minimum password complexity: ON (>= 12 chars)
- Login number tries before lockout: 5
```

`Admin → Configuration → Feature Configuration`:

```text
- Enable Uploads:           ON  (uploads desde la UI o desde /inbox)
- Allowed Upload Filetypes: epub,pdf,mobi,azw3,cbz,cbr,fb2,djvu,txt
- Edit Metadata:            ON
- Edit shelfs:              ON  (per-user shelves)
- Public shelves:           ON  (compartibles entre usuarios)
- Anonymous downloads:      OFF
- Calibre database directory: /books   (la biblioteca canónica)
- Use Goodreads:            ON  (scrape de metadatos)
- Use LibraryThing:         OFF (queremos evitar scrapers extra)
- Use Comic Vine:           ON  (si hay tebeos)
- Cover image quality:      80
```

`Admin → Configuration → External Binaries`:

```text
- Calibre's converter tool path: /usr/bin/ebook-convert
  (auto-detectado por DOCKER_MODS=universal-calibre)
- Path to Kepubify-binary:       /usr/bin/kepubify  (si presente)
- Path to UnRar:                 /usr/bin/unrar    (si presente)
```

> **Si `ebook-convert` aparece como "no encontrado"**: el mod `universal-calibre` no se instaló o falló. Revisar `docker logs calibre-web | grep -i universal-calibre`. Reinstalación: parar el contenedor, borrar `/mnt/hd2t/apps/calibre-web/config/.modcache/`, arrancar de nuevo (descarga limpia).

### 4) Crear usuarios

`Admin → Users → New User`:

```text
- Username: <nombre del miembro>
- Password: gestor de contraseñas
- Email:    <correo_real>   (necesario solo si se va a usar Send-to-Kindle)
- Kindle Email: <prefix>@kindle.com   (vacío hasta configurar SMTP)
- Locale:   es
- Default Visibilities: Authors, Series, Categories, Languages
- Permissions:
  - Admin user:    NO
  - Download:      SÍ (necesario para OPDS)
  - Upload:        NO (limitar a admin)
  - Edit:          NO (no editar metadatos)
  - Delete:        NO
  - Change password: SÍ
  - View books:    SÍ
  - Switch language: NO
  - Edit shelves:  SÍ (per-user)
- Visibility: todas las categorías visibles (o restringidas por columna
  custom si se segmenta perfil infantil)
```

> **Sobre la cuenta admin**: usar `admin` solo para administración. Para leer día a día, crear un usuario propio sin permisos de admin. Las shelves y favoritos son **por usuario**: si dos miembros del hogar usan la misma cuenta, comparten shelves y "leídos", lo que es indeseable.

### 5) Configurar OPDS (lectura desde móvil/eReader)

OPDS está disponible automáticamente en `https://calibre-web.lan/opds` con HTTP Basic Auth. Cliente recomendado: **KOReader**.

#### KOReader (Android, Kobo flasheado, Kindle jailbreak, Linux)

```text
1. Instalar KOReader desde F-Droid o GitHub Releases (es gratis y open source).
2. Open menu (top bar) → Search → OPDS catalog → "+" (añadir).
3. Datos:
   - Catalog name: Homelab
   - Catalog URL:  https://calibre-web.lan/opds
                   (o https://calibre-web.<ts-tailnet>.ts.net si fuera de casa)
   - Username:     <usuario no-admin>
   - Password:     <password>
4. Save → tap en "Homelab" → navegar autores/series/tags, descargar libro.
```

> **CA interna en KOReader**: KOReader confía en certificados del sistema Android. La CA interna debe estar instalada como "user CA" (Android 7+ exige aceptar la CA explícitamente para apps que no añadan `network_security_config`). Si KOReader marca "self-signed certificate", alternativas: (a) usar Tailscale, que trae cert legítimo en `calibre-web.<ts-tailnet>.ts.net`; (b) en KOReader → Settings → Network → "Allow insecure SSL" (solo aceptable en LAN).

#### Moon+ Reader (Android)

```text
1. Instalar Moon+ Reader (Play Store).
2. Net Library → "+" (añadir) → OPDS Catalog.
3. Datos:
   - Title:    Homelab
   - URL:      https://calibre-web.lan/opds
   - Username/Password: como arriba
4. Save → navegar y descargar.
```

#### iOS: KyBook 3 / Marvin / PocketBook Reader

Configuración análoga: añadir un OPDS feed con URL `https://calibre-web.lan/opds` y credenciales. KyBook 3 es la opción más completa de iOS para OPDS+lectura; Marvin (legacy) sigue funcionando para EPUB.

### 6) Configurar Kobo Sync (opcional)

Si el operador tiene un Kobo Wi-Fi y quiere sincronizar **biblioteca, posición de lectura y colecciones** sin pasar por la cuenta de Rakuten/Kobo:

```text
Admin → Configuration → Feature Configuration → Kobo Sync:
- Enable Kobo sync:               ON
- Proxy unknown requests to Kobo store: ON  (deja pasar al cloud Kobo
                                              lo no soportado: store, social)

Admin → Users → <usuario> → "Generate Kobo Auth Token":
- CW genera un token único por usuario; la URL queda:
  https://calibre-web.lan/kobo/<token>/
- Copiar esa URL para el siguiente paso.

En el Kobo:
1. Reflashear con NickelMenu/KoboPatch para apuntar a una URL alternativa
   (fuera de alcance de este doc; ver el thread MobileRead "Kobo Calibre-Web
   Sync"). El método estándar requiere editar `Kobo/Kobo eReader.conf` y
   apuntar `api_endpoint` a la URL generada.
2. Reiniciar el Kobo. La primera sincronización tarda 1-5 min según
   tamaño de biblioteca.
```

> **Aviso**: Kobo Sync en CW es **experimental**. Funciona razonablemente para sincronizar la biblioteca y la posición; algunas features (anotaciones, highlights) tienen reportes de fallos intermitentes. Si el operador no usa Kobo, dejar la opción `Enable Kobo sync` en OFF reduce superficie de ataque.

> **Revocar acceso a un Kobo**: si se pierde el dispositivo, `Admin → Users → <usuario> → Reset Kobo Token`. La URL antigua queda invalidada; el dispositivo perdido no podrá seguir descargando ni sincronizando.

### 7) Configurar Send-to-Kindle (opcional)

Para enviar un libro al Kindle del operador por email. Requiere SMTP saliente; el homelab no tiene MTA propio, así que se usa SMTP de un proveedor externo (Gmail con app password, Fastmail, Migadu, etc.).

```text
Admin → Configuration → Email server settings:
- SMTP server name:          smtp.gmail.com   (ejemplo)
- SMTP server port:          587
- Encryption:                STARTTLS
- SMTP login:                <user>@gmail.com
- SMTP password:             <app password>
- From email address:        <user>@gmail.com
- Convert to format for Kindle: AZW3   (más moderno que MOBI)

Admin → Users → <usuario> → Kindle Email:
- p.ej. <prefix>@kindle.com
- Importante: añadir el "From email address" anterior a la whitelist
  de Amazon (Manage Your Content and Devices → Preferences →
  Approved Personal Document E-mail List).
```

Tras configurar:

```text
Catálogo → libro → "Send to Kindle" → CW convierte EPUB → AZW3
(usando ebook-convert) → envía por SMTP. Tarda 30-60 s para libros
medianos. El log de envíos vive en Admin → Tasks (job history).
```

> **Sin SMTP propio**: por simplicidad, el homelab no levanta un MTA (postfix/maddy). Usa SMTP relay externo. Si en el futuro se quiere un servidor de correo propio (más allá de avisos internos), reabrible como un servicio aparte fuera de Fase 9.

> **Si el envío falla con "550 from not authorized"**: el remitente no está en la whitelist de Amazon. Añadir la dirección y reintentar.

### 8) Operación diaria

| Acción | Comando |
|---|---|
| Ver el log activo | `docker logs calibre-web -f` |
| Reescaneo de la biblioteca (tras añadir libros vía Samba a `books/`) | UI: Admin → "Update metadata cover and language", o reiniciar el contenedor |
| Importar libros desde inbox | UI: Tasks → Auto Upload (cron interno cada hora si "Allow Uploads" está ON; o disparar manual con `docker exec calibre-web cps`) |
| Reiniciar CW | `docker compose -f stacks/calibre-web/docker-compose.yml restart calibre-web` |
| Backup manual del config + biblioteca | `sudo tar czf /mnt/hd2t/backups/cw-snapshot-$(date +%F).tgz -C /mnt/hd2t/apps calibre-web` |
| Tamaño actual de la BBDD interna | `du -sh /mnt/hd2t/apps/calibre-web/config/app.db` |
| Tamaño actual de la BBDD Calibre | `du -sh /mnt/hd2t/apps/calibre-web/books/metadata.db` |
| Listar usuarios | UI: Admin → Users; o `sqlite3 /mnt/hd2t/apps/calibre-web/config/app.db "SELECT name,email,role FROM user;"` |
| Cambiar password de admin desde la CLI | `sqlite3 /mnt/hd2t/apps/calibre-web/config/app.db` (CW no expone CLI nativa; documentar password reset desde la UI o vía SQL para casos de emergencia con bcrypt manual) |
| Convertir un libro a otro formato | UI: book → Convert → escoger formato (requiere `ebook-convert` ya disponible) |
| Forzar refresco de portadas | UI: Admin → Configuration → "Reset cover folder" (regenera de las imágenes embebidas en EPUB) |
| Verificar integridad de `metadata.db` | `docker exec calibre-web sqlite3 /books/metadata.db "PRAGMA integrity_check;"` |

---

## Almacenamiento

| Ruta | Soporte | Owner:Group | Modo | Contenido |
|---|---|---|---|---|
| `/home/homelab/homelab/stacks/calibre-web/docker-compose.yml` | microSD | `homelab:homelab` | `0640` | Stack versionado en git. |
| `/home/homelab/homelab/stacks/calibre-web/.env.example` | microSD | `homelab:homelab` | `0644` | Plantilla. |
| `/home/homelab/homelab/stacks/calibre-web/.env` | microSD | `homelab:homelab` | `0600` | Vacío en este servicio (consistencia con resto de stacks). |
| `/home/homelab/homelab/stacks/caddy/conf.d/09-calibre-web.caddy` | microSD | `homelab:homelab` | `0644` | Drop-in de Caddy. |
| `/home/homelab/homelab/stacks/authelia/conf.d/09-calibre-web-bypass.yml` | microSD | `homelab:homelab` | `0644` | Fragmento de bypass. |
| `/mnt/hd2t/apps/calibre-web/config/` | hd2t | `homelab:homelab` | `0750` | Datos del servicio. **Crítico**, se respalda. |
| `/mnt/hd2t/apps/calibre-web/config/app.db` | hd2t | `homelab:homelab` | `0640` | BBDD interna de CW (usuarios, shelves, settings, tokens Kobo). |
| `/mnt/hd2t/apps/calibre-web/config/.modcache/` | hd2t | `homelab:homelab` | `0750` | Caché de `DOCKER_MODS=universal-calibre`. **No se respalda** (regenerable; ~500 MiB). |
| `/mnt/hd2t/apps/calibre-web/books/` | hd2t | `homelab:homelab` | `0750` | **Biblioteca Calibre canónica**. `metadata.db` + `Autor/Título (id)/*.epub`. **Sí se respalda** (T1: `metadata.db`; T2: ficheros). |
| `/mnt/hd2t/apps/calibre-web/books/metadata.db` | hd2t | `homelab:homelab` | `0640` | BBDD Calibre (catálogo). |
| `/mnt/hd2t/media/ebooks/` | hd2t | `homelab:media` | `2770` | Inbox compartida. **No se respalda**: contenido transitorio (libros pendientes de import). |

> **Tamaño esperado**. `app.db` se estabiliza en torno a **5–20 MiB**. `metadata.db` para una biblioteca de ~3.000 libros pesa **30–80 MiB**. La biblioteca `books/` depende totalmente del catálogo: 3.000 EPUBs medios (~1.5 MiB cada uno) ocupan ~5 GiB; con PDFs grandes y CBZ puede multiplicarse por 10. Reservar **20 GiB** para `apps/calibre-web/` cubre catálogos pequeños/medianos; más allá, dimensionar con el catálogo real.

> **Tamaño del mod `universal-calibre`**. Tras el primer arranque, `/config/.modcache/` ocupa **~500 MiB** (binarios Calibre extraídos). Es regenerable (vuelve a descargarse si se borra y se reinicia el contenedor) y queda excluido del backup.

> **Por qué no microSD**. Como en JF/ND/ABS: SQLite + escrituras frecuentes (cada edición de metadatos, cada upload, cada renombrado masivo) en microSD = cuenta atrás para corrupción. Además, los EPUBs en `books/` son cientos de miles de ficheros pequeños; las microSD se atragantan con ese patrón.

---

## Backup

A nivel de repositorio (git):

| Artefacto | Estrategia |
|---|---|
| `stacks/calibre-web/docker-compose.yml`, `.env.example` | Versionados. |
| `stacks/calibre-web/.env` | **NO** versionado (consistencia; aunque hoy esté vacío). En `.gitignore`. |
| `stacks/caddy/conf.d/09-calibre-web.caddy` | Versionado. |
| `stacks/authelia/conf.d/09-calibre-web-bypass.yml` | Versionado. |
| Decisiones (LSIO, bridge, sin Authelia, books `:rw` en apps/, inbox `:rw` en media/, `DOCKER_MODS=universal-calibre`) | Documentadas en este fichero. |

A nivel de datos (Borgmatic, Fase 7):

| Ruta | ¿Se respalda? | Tier (`07-backups/01-estrategia-backup.md`) | Por qué |
|---|---|---|---|
| `/mnt/hd2t/apps/calibre-web/config/app.db` | Sí. | T1 | Usuarios, contraseñas hashed (bcrypt), shelves, tokens Kobo, settings. **Pérdida = re-creación manual de usuarios y shelves**, pero el catálogo (`metadata.db`) sobrevive en `books/`. |
| `/mnt/hd2t/apps/calibre-web/config/` (resto) | Sí. | T1 | `gdrive_credentials`, ficheros de configuración auxiliares. |
| `/mnt/hd2t/apps/calibre-web/config/.modcache/` | **No.** | T4 | Caché del mod `universal-calibre`; se regenera al arrancar. |
| `/mnt/hd2t/apps/calibre-web/books/metadata.db` | Sí. | T1 | **El catálogo entero**: tags, ratings, series, columnas custom, descripciones, identificadores ISBN/Amazon. **Pérdida = catálogo a reconstruir manualmente desde tags ID3 de los EPUBs (laborioso, pierde decoraciones)**. |
| `/mnt/hd2t/apps/calibre-web/books/` (ficheros EPUB/PDF/etc.) | Sí. | T2 | Los libros en sí. Reposicionables desde la fuente (compras digitales, Project Gutenberg, rips propios), pero el conjunto curado del operador es valioso y no fácilmente reconstituible. |
| `/mnt/hd2t/media/ebooks/` | **No.** | T5 | Inbox transitoria: lo que está aquí está pendiente de importar. Tras import, vive en `books/` y se respalda allí. |

Entrada en `borgmatic.yaml` (parche relativo al patrón de `07-backups/02-borgmatic.md`):

```yaml
source_directories:
  # ...
  - /mnt/hd2t/apps/calibre-web/config
  - /mnt/hd2t/apps/calibre-web/books

# Excluir lo regenerable.
patterns:
  # ...
  - '!/mnt/hd2t/apps/calibre-web/config/.modcache'

# Hooks: snapshot consistente de las dos SQLite antes del backup.
before_backup:
  - 'docker exec calibre-web sqlite3 /config/app.db ".backup ''/config/app.db.borg''"'
  - 'docker exec calibre-web sqlite3 /books/metadata.db ".backup ''/books/metadata.db.borg''"'
after_backup:
  - 'docker exec calibre-web rm -f /config/app.db.borg /books/metadata.db.borg'
```

> **Política sobre ambas SQLite**. Snapshot consistente con `.backup` (atómico) para `app.db` y `metadata.db`. CW no abre `metadata.db` con WAL agresivo; `.backup` es seguro con CW corriendo. Para una BBDD de ~50 MiB, el snapshot tarda <2 s.

> **Política sobre `/mnt/hd2t/apps/calibre-web/books/` (ficheros)**. Sí se respalda en T2 (a diferencia de `/mnt/hd2t/media/audiobooks/` y `/music/`, que no se respaldan). La razón: la biblioteca Calibre **no es media en bruto**, es **un trabajo curado** (carpetas renombradas, IDs únicos, portadas regeneradas, ficheros en formato EPUB tras conversión desde EPUB original). Aunque cada libro individual sea reconstituible, el conjunto representa horas de organización del operador.

> **Política sobre `/mnt/hd2t/media/ebooks/`**. Excluida del backup. Si hay libros aquí cuando ocurre la pérdida, se han perdido (estaban pendientes de importar). El operador puede volver a descargarlos.

Procedimiento de restore tras pérdida del contenedor (datos intactos en `hd2t`):

```bash
docker compose -f /home/homelab/homelab/stacks/calibre-web/docker-compose.yml up -d --force-recreate
# CW reusa /mnt/hd2t/apps/calibre-web/{config,books}: arranque normal
# en ~20 s (el mod ya está cacheado), todos los usuarios, shelves y
# catálogo siguen ahí.
```

Procedimiento de restore tras pérdida total (reflasheo + restauración Borg):

1. Recrear Fases 1 → 7.
2. `borgmatic extract --archive latest --path mnt/hd2t/apps/calibre-web`.
3. Verificar permisos: `sudo chown -R homelab:homelab /mnt/hd2t/apps/calibre-web && sudo chmod -R u=rwX,g=rX,o= /mnt/hd2t/apps/calibre-web`.
4. Confirmar/recrear `/mnt/hd2t/media/ebooks` (inbox vacía).
5. `docker compose -f stacks/calibre-web/docker-compose.yml up -d`.
6. Primer arranque tras restore: 2-3 min para reinstalar el mod `universal-calibre` (cache borrada por exclusión Borg).
7. `https://calibre-web.lan` → login con credenciales pre-existentes; el catálogo entero aparece. Re-emitir tokens Kobo si los dispositivos los habían perdido.

---

## Errores frecuentes y troubleshooting

| Síntoma | Causa probable | Resolución |
|---|---|---|
| `https://calibre-web.lan` da `502 Bad Gateway` | Caddy no resuelve `calibre-web` (contenedor caído o no en la red `homelab`). | `docker ps --filter name=calibre-web`. Si está caído, `docker logs calibre-web --tail 100`. Si está vivo: `docker network inspect homelab` debe listarlo. |
| Primer arranque tarda >5 min y nunca pasa a `healthy` | El mod `universal-calibre` está descargándose con conexión lenta o falló. | `docker logs calibre-web 2>&1 \| grep -i universal-calibre`. Reintentar: `docker compose restart calibre-web`. Si persiste, borrar `/mnt/hd2t/apps/calibre-web/config/.modcache/` y reiniciar. |
| UI: "Database location" loop infinito tras submit | El path `/books` no contiene `metadata.db` legible y CW no puede crear uno (permisos). | `docker exec calibre-web ls -la /books`. Owner debe ser `1000:1000` con permisos rw. Si vacío: dejar que CW cree la BBDD; si tenía contenido: revisar permisos. |
| Logs CW: `sqlite3.OperationalError: unable to open database file` | Permisos incorrectos en `/books/metadata.db` o `/config/app.db`. | `docker exec calibre-web id` debe ser `uid=1000 gid=1000`. `stat -c '%u:%g %a' /mnt/hd2t/apps/calibre-web/{config,books}` debe ser `1000:1000 750`. |
| OPDS: KOReader/Moon+ recibe 401 con credenciales correctas | "Anonymous browsing" desactivado pero el cliente envía Basic Auth con caracteres especiales (UTF-8 mal codificados). | Probar con un usuario nuevo de password ASCII puro. Si funciona: el cliente OPDS tiene bug con el password original; cambiar password. |
| `ebook-convert` no aparece en "External Binaries" | El mod `universal-calibre` no se instaló correctamente. | `docker exec calibre-web which ebook-convert` debe devolver `/usr/bin/ebook-convert`. Si no: revisar logs del cont-init.d, reinstalar borrando `.modcache/`. |
| Send-to-Kindle: "Connection refused" o "Authentication failed" | SMTP server settings incorrectos o app password de Gmail revocada. | Probar el login SMTP desde la propia Pi: `docker exec calibre-web python3 -c "import smtplib; s=smtplib.SMTP('smtp.gmail.com', 587); s.starttls(); s.login('USER', 'PASS')"`. |
| Send-to-Kindle: email enviado pero no aparece en el Kindle | Dirección "From" no está en la whitelist de Amazon. | Manage Your Content and Devices → Preferences → Approved Personal Document E-mail List → añadir el "From email address". |
| Kobo Sync: el Kobo se conecta pero no descarga libros | Token de usuario inválido o el Kobo no está apuntando a la URL correcta. | Admin → Users → Reset Kobo Token; reconfigurar el Kobo con la URL nueva. |
| "Convert" en la UI aparece grisado | `ebook-convert` no detectado. | Ver fila anterior: instalación del mod o ruta del binario incorrecta. |
| Conversión EPUB → MOBI tarda 5+ min y se corta | Caddy `read_timeout` insuficiente, o ebook gigante. | Ya cubierto con `read_timeout 5m`; si insuficiente, subir a `15m` para libros patológicos. La conversión sigue corriendo en CW aunque el cliente HTTP se desconecte; el resultado queda en Tasks. |
| Catálogo aparece vacío tras importar una biblioteca Calibre existente | Los permisos del rsync dejaron los ficheros como `root:root`. | `sudo chown -R homelab:homelab /mnt/hd2t/apps/calibre-web/books && docker compose restart calibre-web`. |
| `metadata.db` corrupta tras un corte de luz | Escritura interrumpida por kernel panic / power off. | `sqlite3 /books/metadata.db "PRAGMA integrity_check;"` desde el contenedor. Si reporta errores: restore del último snapshot Borg. |
| App móvil: "Unable to connect" en LAN | El móvil usa DNS distinto (CGNAT del operador) que no resuelve `calibre-web.lan`. | Forzar el móvil a usar Pi-hole (DHCP del router → Primary DNS = 192.168.1.2) o añadir `calibre-web.lan -> 192.168.1.10` al DNS del dispositivo. |
| App OPDS: "Server certificate is invalid" | El móvil no tiene la CA interna instalada. | Instalar la CA en el sistema; o usar tailnet (`calibre-web.<ts-tailnet>.ts.net` con cert legítimo); o "Allow self-signed" en el cliente (solo en LAN). |
| Inbox `/inbox` vista como vacía desde CW pese a haber libros ahí | Permisos: ficheros sin grupo `media`, o no legibles. | `stat -c '%u:%g %a' /mnt/hd2t/media/ebooks/*`. Owner debe ser `homelab:media` con `0664`/`0775`. Si desde Samba hubo problemas: `sudo chgrp -R media /mnt/hd2t/media/ebooks && sudo chmod -R g+rw /mnt/hd2t/media/ebooks`. |
| Tras `docker compose pull`, CW no arranca: "alembic migration failed" | Bump de patch con migración fallida (raro). | Restore `config/app.db` desde el snapshot Borg de la noche anterior. Reportar issue upstream. |
| `Authelia` interfiere a pesar del bypass | El fragmento `09-calibre-web-bypass.yml` no se cargó en `configuration.yml`. | `docker logs authelia \| grep calibre-web`; revisar la inclusión del fragmento; reiniciar Authelia. |
| `https://calibre-web.lan` muestra cert "no confiable" tras instalar la CA | Caddy no recargó el `Caddyfile` (drop-in nuevo). | `docker exec caddy caddy validate --config /etc/caddy/Caddyfile && docker kill --signal=SIGUSR1 caddy`. |
| Edición masiva de metadatos cuelga la UI | CW serializa edits en `metadata.db`; con 1000+ libros editados a la vez, el bloqueo SQLite se hace patente. | Hacer edits en lotes <100. Para reorganización masiva, parar CW, abrir la biblioteca con Calibre desktop sobre el bind mount (con CW abajo), editar, cerrar y arrancar CW. |

---

## Decisiones que **no** se toman en este documento

- **Authelia delante de CW**: descartado por compatibilidad con OPDS (HTTP Basic) y Kobo Sync (token en URL). Reabrible solo cuando se explore OIDC nativo (parcheado en CW desde 0.6.20+ experimental).
- **OIDC con Authelia**: posible para la UI web; OPDS y Kobo Sync seguirán necesitando auth nativa. La UI de admin podría delegar login a Authelia OIDC, pero el ahorro es marginal y rompe el flujo simple actual.
- **LDAP / Google OAuth**: soportados nativamente por CW; descartados por simplicidad y porque no hay servidor LDAP en el homelab.
- **Migración a Calibre Content Server, Komga, Kavita, Ubooquity**: CW es el más maduro para biblioteca Calibre genérica. Komga/Kavita están orientados a comics/manga (pueden coexistir si en el futuro se separa el catálogo de tebeos). Ubooquity está abandonado.
- **Indexación de comics/manga**: CW soporta CBZ/CBR pero no es su fuerte. Si crece un catálogo de comics, **Komga** sería el servicio dedicado en una hipotética Fase 9 ampliada. Por ahora, los CBZ caben en CW como un libro más.
- **Indexación de audiolibros**: CW **no** los gestiona. La biblioteca de audiolibros pertenece a Audiobookshelf (`03-audiobookshelf.md`).
- **Sincronización de progreso de lectura entre dispositivos** más allá de Kobo Sync: CW no implementa un protocolo genérico (KOSync de KOReader vive aparte; CW podría parchearse para hablarlo, pero está fuera de alcance). Reabrible si KOReader gana presencia masiva en el hogar.
- **Generación de portadas IA / OCR de PDFs viejos**: fuera de alcance. CW solo cataloga.
- **Carga automática desde tiendas (Amazon, Kobo Store, Project Gutenberg)**: CW tiene scrapers de metadatos pero no descarga libros automáticamente. El operador alimenta `/inbox` o `books/` por su cuenta.
- **TTS (texto a voz para audiolibros sintéticos)**: fuera de alcance.
- **Backups del catálogo de ebooks**: política deliberada de **respaldar `books/` en T2** (a diferencia de los catálogos de música, audiolibros y vídeo, que no se respaldan): el conjunto curado de la biblioteca Calibre es trabajo manual del operador y no fácilmente reconstituible.
- **Métricas Prometheus**: CW **no** expone métricas Prometheus nativas. Hay un exporter terciario (`calibre-web-prometheus-exporter`) que consume la API. Reabrible en Fase 5.
- **Streaming a un altavoz externo o Chromecast**: no aplica (CW es lectura, no audio).
- **Anotaciones / highlights compartidos**: KOReader las gestiona localmente; CW no las almacena. Migración a un modelo unificado es trabajo a futuro.

---

## Verificación Final

Antes de pasar a `05-stash.md`:

| Comprobación | Comando | Resultado esperado |
|---|---|---|
| Stack desplegado y saludable | `docker compose -f stacks/calibre-web/docker-compose.yml ps` | `calibre-web ... Up (healthy)` |
| Imagen correcta y fija | `docker inspect calibre-web --format '{{.Config.Image}}'` | `lscr.io/linuxserver/calibre-web:0.6.24` |
| Conectado a la red homelab y NO a host | `docker inspect calibre-web --format '{{.HostConfig.NetworkMode}}'` | `default` o `homelab` (no `host`) |
| Sin puertos publicados al host | `docker port calibre-web` | salida vacía |
| `calibre-web.lan` resuelve al IP de la Pi | `dig +short calibre-web.lan @192.168.1.2` | `192.168.1.10` |
| Caddy sirve `calibre-web.lan` con cert de la CA interna | `echo \| openssl s_client -connect calibre-web.lan:443 -servername calibre-web.lan 2>/dev/null \| openssl x509 -noout -issuer` | `issuer=CN=Homelab Internal CA` |
| Health endpoint responde | `curl -ksS https://calibre-web.lan/robots.txt` | `HTTP 200` (cuerpo: `User-agent: *...`) |
| Usuario interno con grupos correctos | `docker exec calibre-web id` | `uid=1000 gid=1000 groups=1000,1100` |
| `/books` montado read-write | `docker exec calibre-web sh -c 'touch /books/.write_test && rm /books/.write_test && echo OK'` | `OK` |
| `/inbox` montado read-write | `docker exec calibre-web sh -c 'touch /inbox/.write_test && rm /inbox/.write_test && echo OK'` | `OK` |
| Binarios Calibre instalados | `docker exec calibre-web which ebook-convert` | `/usr/bin/ebook-convert` |
| OPDS responde con 401 sin auth | `curl -ksS -o /dev/null -w '%{http_code}\n' https://calibre-web.lan/opds` | `401` |
| OPDS responde con 200 con auth válida | `curl -ksS -o /dev/null -w '%{http_code}\n' -u <user>:<pass> https://calibre-web.lan/opds` | `200` |
| Catálogo poblado tras setup | UI: dashboard con libros listados; o `sqlite3 /mnt/hd2t/apps/calibre-web/books/metadata.db "SELECT COUNT(*) FROM books;"` | número >0 (o 0 si se empezó vacío) |
| Login funciona desde navegador | navegador con CA instalada | UI carga el dashboard tras login |
| Cliente OPDS real funciona | KOReader/Moon+ con URL `/opds` | navegación de catálogo y descarga de un libro |
| Owner correcto del config | `stat -c '%u:%g %a' /mnt/hd2t/apps/calibre-web/config` | `1000:1000 750` |
| Owner correcto de la biblioteca | `stat -c '%u:%g %a' /mnt/hd2t/apps/calibre-web/books` | `1000:1000 750` |
| Owner correcto de la inbox | `stat -c '%u:%g %a' /mnt/hd2t/media/ebooks` | `1000:1100 2770` |
| Authelia bypass para `calibre-web.lan` | `curl -ksI https://calibre-web.lan/` | sin `Location` apuntando a `auth.lan` |
| `metadata.db` íntegra | `docker exec calibre-web sqlite3 /books/metadata.db "PRAGMA integrity_check;"` | `ok` |
| `app.db` íntegra | `docker exec calibre-web sqlite3 /config/app.db "PRAGMA integrity_check;"` | `ok` |
| Sin warnings críticos en logs | `docker logs calibre-web 2>&1 \| grep -iE 'error\|fail' \| head` | salida razonable (no errores recurrentes de permisos o BBDD) |

---

## Referencias

- Documentación oficial Calibre-Web (wiki) — https://github.com/janeczku/calibre-web/wiki
- Repo del proyecto — https://github.com/janeczku/calibre-web
- Imagen LinuxServer.io — https://docs.linuxserver.io/images/docker-calibre-web/
- Imagen Docker LSIO — https://lscr.io/linuxserver/calibre-web
- DOCKER_MODS `universal-calibre` — https://github.com/linuxserver/docker-mods/tree/universal-calibre
- Calibre desktop (formato de la biblioteca) — https://manual.calibre-ebook.com/
- OPDS 1.2 spec (catálogo expuesto por CW) — https://specs.opds.io/opds-1.2.html
- KOReader (cliente OPDS multiplataforma) — https://github.com/koreader/koreader
- Moon+ Reader (cliente Android) — https://www.moondownload.com/
- KyBook 3 (cliente iOS) — https://kybook-reader.com/
- Kobo Sync con CW (thread MobileRead) — https://www.mobileread.com/forums/showthread.php?t=329037
- Send-to-Kindle (Amazon Personal Document Service) — https://www.amazon.com/sendtokindle
- Documentos hermanos: `01-jellyfin.md`, `02-navidrome.md`, `03-audiobookshelf.md`, `05-stash.md`.
- Documentos referenciados: `01-sistema/04-estructura-directorios.md`, `02-docker/02-estructura-compose.md`, `03-red/02-pihole.md`, `03-red/04-caddy.md`, `03-red/05-tailscale.md`, `04-seguridad/01-authelia.md`, `06-almacenamiento/02-samba.md`, `07-backups/01-estrategia-backup.md`, `07-backups/02-borgmatic.md`.
