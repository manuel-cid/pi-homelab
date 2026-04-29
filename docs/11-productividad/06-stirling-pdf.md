# Stirling PDF

## Descripción

Vaultwarden (`01-vaultwarden.md`), Bookstack (`02-bookstack.md`), Linkding (`03-linkding.md`), Paperless-ngx (`04-paperless-ngx.md`) y Mealie (`05-mealie.md`) son cinco servicios con BBDD persistente, OIDC y `VACUUM INTO`/dumps en Borg. Stirling PDF es **el opuesto**: una caja de herramientas para PDFs que **no guarda nada**. Cada operación (split, merge, rotate, OCR, reorder, watermark, sign, repair, compress, convert…) consume un fichero subido por el navegador y devuelve otro fichero descargable, sin tocar disco persistente. Es la navaja suiza para los flujos del operador en los que **no quiere subir el PDF a un SaaS** ("ilovepdf", "smallpdf", "Adobe online"):

- Combinar 12 facturas mensuales en un único PDF anual antes de archivarlo en Paperless.
- Rotar páginas escaneadas al revés con el escáner ADF.
- OCR rápido a un PDF de imagen recibido por WhatsApp (cuando *no* se quiere indexarlo en Paperless porque es desechable).
- Recortar márgenes de un libro escaneado para Calibre-Web.
- Quitar metadatos (`/Author`, `/CreationDate`) de un PDF antes de enviarlo a un tercero.
- Firmar (visualmente) un contrato sin abrir Acrobat.
- Convertir DOCX → PDF / PDF → DOCX puntualmente, sin instalar LibreOffice en el portátil.
- Comprimir un PDF de 60 MB de fotos a < 5 MB para que un formulario web acepte la subida.

Este documento despliega **Stirling PDF** — aplicación web Java/Spring Boot que orquesta `pdftk`, `qpdf`, `Ghostscript`, `LibreOffice`, `Tesseract`, `OCRmyPDF` y un puñado de utilerías más detrás de una UI Vue 3 con ~50 endpoints. Su rol concreto en el homelab:

1. **Servir la UI** en `https://stirling.${DOMAIN_LAN}/` con TLS terminado en Caddy (CA interna) y autenticación por **`forward_auth` two_factor contra Authelia**. Detrás de Caddy, sin `ports:` al host.
2. **Operar `stateless`**. No tiene BBDD, no tiene cuenta de usuarios persistente, no se respalda en Borg. Todo el material que el navegador sube se procesa en `/tmp` dentro del contenedor (un `tmpfs` montado por Docker) y se descarta cuando el contenedor reinicia o el cliente cierra la pestaña.
3. **Procesar el upload + descarga sin pasar por hd2t**. La carpeta `/tmp` del contenedor es `tmpfs` (RAM, ~512 MiB tope). Cero IOPS contra la SD ni contra los discos externos. Si el operador sube un PDF de 200 MB, se queda en RAM, se transforma, se descarga, se libera al cerrar la conexión.
4. **No exponer la batería completa de endpoints peligrosos**. Stirling expone por defecto endpoints como `unlock-pdf` (fuerza bruta de passwords) y `repair`/`unlock`/`sanitize` que pueden ser abusivos. El homelab los **filtra** con `ENDPOINTS_GROUPS_TO_REMOVE` (ver "Configuración → 4").
5. **Idiomas de OCR**. Tesseract se invoca por debajo. Por defecto la imagen de Stirling trae paquetes para inglés, español, francés, alemán e italiano. Si el operador necesita un idioma adicional (gallego, catalán, portugués) **sin** exponer un volumen grande, se documenta el procedimiento (sección "Configuración → 2"); sigue siendo "no persistente" porque los `.traineddata` se montan **read-only** desde el repo de homelab (versionados en git, < 5 MiB cada uno) o se reconstruyen por imagen.
6. **Cero datos de usuario**. `SECURITY_ENABLELOGIN=false`: Stirling no gestiona cuentas. Toda la autenticación es perimetral (Caddy + Authelia con `forward_auth`). Si Authelia deja pasar la petición, Stirling sirve la UI; si no, Caddy redirige a `auth.${DOMAIN_LAN}/`.
7. **Sin SMTP, sin webhooks, sin API tokens**. Stirling 0.x tiene una API REST (`/api/v1/...`) que en este despliegue **se cierra detrás del mismo `forward_auth`**: cualquier `curl` que el operador use para *batch processing* desde un script debe traer la cookie de sesión de Authelia (`AUTHELIA_SESSION_*`) o usar el flujo de Authelia Basic Auth.
8. **No participa en backups Borg**. La política de `homelab.backup=true` no se aplica a este stack: no hay nada que respaldar más allá de `docker-compose.yml` y el drop-in de Caddy, ya versionados en git.

Lo que este documento **no** decide:

- **Cuenta de usuario / multi-user**. Stirling 1.x trae `EnterpriseEdition` con login local, OIDC y SAML; añade BBDD H2/Postgres y un módulo de auditoría. Para el homelab, `forward_auth` ya cubre el caso "solo entran los miembros de la familia" sin añadir BBDD. Reabrible si el operador quiere historial por usuario.
- **API tokens persistentes para automatización**. Stirling no genera tokens propios. El homelab usa la cookie de Authelia para CLI puntual; para scripts cron, diferir hasta que se necesite (un token estático bypass de Authelia se documentará en `04-seguridad/01-authelia.md` cuando aparezca el primer caso real).
- **Métricas Prometheus** (`/actuator/prometheus` de Spring Boot). Stirling lo expone si se habilita `METRICS_ENABLED=true` y `actuator.endpoints.web.exposure.include=prometheus`. Es ruido para el caso de uso (tráfico esporádico). Reabrible si se quiere medir uso por endpoint.
- **Compresión avanzada con Ghostscript** (`SCREEN`/`PRINTER`/`EBOOK` profiles). Stirling expone los presets en la UI; no se hardcodea ningún default — el operador elige por subida.
- **Plugins de fuentes adicionales para OCR**. Tesseract sin más fuentes funciona razonablemente bien para latín. Idiomas con scripts no latinos (chino, hebreo, árabe) requieren `.traineddata` específicos y no son caso de uso.
- **Envio a Paperless desde Stirling** (workflow "abrir PDF, modificarlo, mandarlo a Paperless en un click"). Stirling no integra con Paperless API. El operador descarga el PDF transformado y lo deposita manualmente en `consume/` de Paperless (`04-paperless-ngx.md`). Reabrible si se vuelve frecuente.
- **Firmas digitales criptográficas** (no visuales). Stirling tiene un endpoint de "sign" que dibuja una firma escaneada en el PDF; no firma criptográficamente con un certificado X.509. Si se requiere firma legal real, usar `pyhanko` o Adobe.
- **Hardening con seccomp/AppArmor profiles propios**. La imagen oficial corre como UID no-root, pero no trae perfiles seccomp custom. Diferido a `04-seguridad/` si aparece un CVE relevante.

Cuando este documento se haya aplicado:

- `https://stirling.${DOMAIN_LAN}/` carga tras login + TOTP en Authelia (la sesión SSO ya iniciada en otro servicio cubre Stirling sin re-login en la misma ventana de validez).
- El operador sube un PDF, ejecuta una operación y descarga el resultado. Cero ficheros en hd2t.
- `docker exec stirling-pdf ls /tmp` muestra restos de procesado **dentro** del `tmpfs` del contenedor, que se vacía a cada `docker compose restart`.
- `docker stats` muestra el contenedor en ~600 MiB de RAM (Java/Spring Boot + LibreOffice headless al primer uso).
- Borgmatic no toca este stack: no hay `homelab.backup=true`, no hay rutas en `source_directories`.
- Uptime Kuma tiene un monitor HTTPS sobre `https://stirling.lan/api/v1/info/status` con alerta Telegram + email.

> **Recordatorio de alcance**: Stirling PDF es **solo LAN + Tailscale**. **No publica `ports:` al host**, **no se expone a Internet**, **no usa Let's Encrypt**. Vía Tailscale, MagicDNS resuelve `stirling.lan` desde fuera de casa siempre que el cliente tenga la CA interna instalada.

---

## Requisitos Previos

- **Fase 2** completa: Docker Engine + Compose v2; red `homelab` en `172.30.10.0/24`; convenciones `stacks/<svc>/`; `.env` global con `TZ`, `PUID`, `PGID`, `DOMAIN_LAN=lan`, `LAN_IP=192.168.1.10`.
- **Fase 3** completa, en particular:
  - Pi-hole con el comodín `address=/lan/192.168.1.10` (cubre `stirling.${DOMAIN_LAN}` sin tocar Pi-hole).
  - Caddy con los snippets `(lan_tls)`, `(security_headers)`, `(healthcheck)` definidos.
- **Fase 4** completa, en particular:
  - Authelia desplegado y los snippets `(authelia_one_factor)` y `(authelia_two_factor)` registrados en `stacks/caddy/conf.d/01-authelia.caddy` (decisión vivida en `04-seguridad/01-authelia.md`).
  - El operador y la pareja existen en el backend de Authelia (file backend o LDAP) con TOTP enrollado.
- **Operador** con la **CA interna instalada** en navegador (PC + móvil). Sin esto, la primera petición a `stirling.lan` falla con `NET::ERR_CERT_AUTHORITY_INVALID`.
- **RAM disponible**: ~700 MiB de cabeza para el contenedor (Spring Boot ~400 MiB en idle, +200 MiB pico al instanciar LibreOffice headless en el primer DOCX→PDF, +128 MiB para el `tmpfs` de `/tmp`).
- **No requiere espacio en hd2t** más allá del propio del repo del homelab. Sin BBDD, sin assets, sin uploads persistentes.

Comprobaciones rápidas:

```bash
# La red Docker compartida existe
docker network inspect homelab --format '{{.Name}}' | grep -q '^homelab$' && echo ok

# Caddy y Authelia corriendo
docker ps --filter name=caddy --filter name=authelia --format '{{.Names}} {{.Status}}'

# stirling.lan resuelve al IP de la Pi (gracias al comodín de Pi-hole)
dig +short stirling.lan @192.168.1.2
# 192.168.1.10

# Snippets forward_auth registrados en Caddy
docker exec caddy grep -E '^\(authelia_(one|two)_factor\)' /etc/caddy/conf.d/01-authelia.caddy
# (authelia_one_factor) {
# (authelia_two_factor) {

# RAM libre suficiente
free -h | awk '/^Mem:/ {print $7 " disponibles"}'
```

---

## Decisión: imagen y versión

Stirling PDF se publica en Docker Hub como `stirlingtools/stirling-pdf` (alias histórico `frooodle/s-pdf`, todavía mantenido) y en GHCR como `ghcr.io/stirling-tools/stirling-pdf`. Todas las imágenes son multi-arch (`amd64`, `arm64`); en la Pi 5 (aarch64) se usa el manifest `arm64`.

| Tag | Cuándo usar | Decisión aquí |
|---|---|---|
| `latest` | Demos. | Descartado (convención de Fase 2: tags exactos). |
| `latest-fat` | Variante con dependencias completas (LibreOffice + Calibre + OCRmyPDF + python-uno + …). | Aceptado **conceptualmente** pero pin con tag exacto. |
| `latest-ultra-lite` | Variante mínima (sin LibreOffice ni OCRmyPDF), solo operaciones puramente PDF. | Descartado: queremos OCR y conversión Office. |
| `latest-fat-postgres` | Variante "fat" con cliente Postgres para EnterpriseEdition. | Descartado: no usamos EE. |
| `0.45.0-fat` (ejemplo de tag exacto) | Reproducibilidad estricta + dependencias completas. | **Aceptado**. |

> **Tag exacto en uso**: `stirlingtools/stirling-pdf:0.45.0-fat`. Si en el momento de aplicar este documento existe una versión más reciente con changelog limpio (sin breaking changes en endpoints `/api/v1/`), se actualiza el tag aquí y en el `docker-compose.yml`, y se anota en el commit. **Nunca `latest`**, **nunca `latest-fat`**.

> **Por qué la variante `-fat` y no la default**. La imagen "default" (`stirlingtools/stirling-pdf:0.45.0`) **no incluye** LibreOffice ni OCRmyPDF; los descarga al vuelo la primera vez que un endpoint los necesita (vía `INSTALL_BOOK_AND_ADVANCED_HTML_OPS=true` o `LANGS=...`). En la Pi 5 con red residencial esto puede tardar 3–5 minutos al primer uso, y queda almacenado **dentro del filesystem del contenedor** — se pierde al `docker compose down -v` y vuelve a tardar tanto al reiniciar. La variante `-fat` los trae horneados en la imagen (~1.6 GiB en disco vs ~600 MiB de la default), así que el primer arranque ya tiene OCR y conversión Office disponibles. Para una Pi en LAN doméstica, gastar 1 GiB de imagen vale más que 5 minutos de descarga al primer click. **Decidido `-fat`**.

> **Por qué Stirling y no Apryse / pdf-lib / DocuSeal / Gotenberg**.
> - **Apryse / PDFTron WebViewer**: comercial. Descartado.
> - **pdf-lib + librerías propias**: requiere construir UI propia. Sobreingeniería.
> - **DocuSeal**: orientado a *firma de documentos* (workflow), no a *manipular PDFs* puntualmente. Caso de uso distinto.
> - **Gotenberg**: solo conversión a PDF (Office → PDF). No manipula PDFs existentes. Stirling lo usa por debajo en algunos flujos pero como wrapper Stirling es más completo.
> - **Stirling PDF**: punto de equilibrio: ~50 operaciones cubiertas, UI pulida en Vue 3, multi-arch arm64 estable, comunidad activa (>40k stars), licencia MIT (con la EE en su propia licencia). **Decidido**.

> **Por qué tag exacto y no `0.45`**. Stirling 0.x ha movido endpoints entre versiones menores (renombró `/sanitize-pdf` a `/security/sanitize-pdf` en 0.30, removió flags en 0.40). Con tag flotante un `up -d` rutinario podría romper el bookmarklet del navegador del operador o un `curl` de un script. Con tag exacto las actualizaciones son **deliberadas**: el operador lee el changelog, edita el tag, `up -d`, valida. Watchtower **deshabilitado** para este stack.

---

## Decisión: cómo se expone Stirling PDF

Stirling es Spring Boot ejecutando un *embedded Tomcat* en `:8080` dentro del contenedor (HTTP plano; el TLS lo termina Caddy delante).

| Opción | Cómo se ve | Discusión |
|---|---|---|
| `network_mode: host` | Stirling ata `:8080` al host. | Rompe la convención del homelab y choca con cualquier otro servicio que use `:8080` (Bookstack, Portainer, …). Descartado. |
| Bridge `homelab` con `ports: ["8080:8080"]` | Acceso directo desde la LAN sin pasar por Caddy. | HTTP plano sin TLS y, peor, **sin Authelia**: cualquiera en la LAN abre `http://192.168.1.10:8080/` y tiene acceso completo. Descartado. |
| Bridge `homelab` con `expose: 8080`, **sin `ports:`** | Stirling alcanzable solo dentro de la red Docker. Caddy hace `reverse_proxy http://stirling-pdf:8080`. | Termina TLS en Caddy con la CA interna y **fuerza el paso por `forward_auth`**. Patrón establecido. **Aceptado**. |

Resultado: `expose: 8080` en el compose (no `ports:`), un drop-in `stacks/caddy/conf.d/45-stirling-pdf.caddy` que hace `reverse_proxy http://stirling-pdf:8080` y que importa `authelia_two_factor`, y todo el tráfico externo pasa por `https://stirling.${DOMAIN_LAN}/` con cert de la CA interna y sesión Authelia validada.

> **Sobre WebSockets / SSE**. Stirling 0.x no usa WebSockets ni SSE: cada operación es un POST `multipart/form-data` que devuelve directamente el binario procesado. `reverse_proxy` simple basta sin directivas extras.

> **Sobre el tamaño de subida**. Stirling acepta por defecto `multipart.max-file-size=2GB` y `multipart.max-request-size=2GB` (Spring Boot). Caddy aplica un tope por defecto de 10 MiB, que **rompe** subidas de PDFs grandes con 413. El drop-in fija `request_body { max_size 500MB }` (margen amplio para libros escaneados).

> **Sobre `SERVER_SERVLET_CONTEXT_PATH`**. Stirling soporta servirlo bajo un prefijo (`https://lan/stirling`). **No se usa**: convención del homelab es **un subdominio por servicio** (Fase 3), más simple.

---

## Decisión: autenticación — `forward_auth` two_factor vía Authelia

Stirling tiene tres modos de autenticación en 0.x:

| Modo | Cómo |
|---|---|
| **Sin auth** (`SECURITY_ENABLELOGIN=false`, default) | Cualquiera con acceso de red entra. |
| **Login local** (`SECURITY_ENABLELOGIN=true`) | Cuentas en H2 BBDD interna, formulario propio. Aparece en 0.30+. |
| **EnterpriseEdition con OIDC/SAML** | Requiere licencia EE y Postgres. Fuera de scope. |

Para el homelab, la tercera está vetada (no EE, queremos seguir stateless), y entre las dos primeras la elección es **clara**: `SECURITY_ENABLELOGIN=false` + `forward_auth` perimetral en Caddy.

| Capa | Patrón | Justificación |
|---|---|---|
| Caddy → Stirling | `forward_auth authelia:9091` con snippet `authelia_two_factor` | Patrón homogéneo con el resto de servicios sin OIDC nativo (Jellyfin admin, Portainer, Pi-hole admin). Mismas credenciales y mismo TOTP que cualquier otro servicio. |
| Stirling | Sin auth interna (`SECURITY_ENABLELOGIN=false`, **explícito**) | Stateless: cero usuarios, cero passwords, cero BBDD H2. Si Authelia deja pasar, Stirling sirve. |
| API (`/api/v1/...`) | Mismo `forward_auth` | Authelia inyecta las cookies de sesión; los `curl` del operador pasan `--cookie-jar` tras login web previo, o usan Authelia Basic Auth (header `Authorization: Basic ...` que Authelia 4.38 acepta para clientes que no soportan redirects). |

Resultado: el drop-in 45 importa `authelia_two_factor` para **toda la ruta** (`/`, `/api/v1/...`). No se usan rutas públicas: la página de inicio de Stirling muestra ya las herramientas y previewer, así que cualquier acceso anónimo expone funcionalidad — bloquear desde la raíz.

> **Por qué `two_factor` y no `one_factor`**. Stirling procesa **PDFs subidos por el operador** que pueden contener datos sensibles (escrituras notariales, nóminas, recetas médicas). Aunque el procesamiento es efímero (`tmpfs`), el endpoint en sí debe estar tras 2FA por consistencia con el resto de servicios "que tocan documentación personal" (Paperless está en `two_factor`, Bookstack también). Si en algún momento se valora bajarlo a `one_factor` por fricción de uso, se reabre.

> **Sobre la sesión SSO compartida**. Una vez el operador entra a Authelia desde **cualquier** servicio con `two_factor` (Vaultwarden, Paperless, Bookstack…), la cookie `authelia_session` cubre Stirling sin re-login durante `expiration: 1h, inactivity: 5m` (configurado en `04-seguridad/01-authelia.md`). En la práctica: abrir Stirling en una pestaña recién (sin SSO previo) → redirección a Authelia → login + TOTP → vuelta a Stirling. Si en el último 1h ya entraste a otro servicio, **carga directo**.

> **Sobre el bypass de `forward_auth` para la API en local**. Algunos scripts del operador corren **dentro** de la red Docker (un sidecar de un script que invoca `curl http://stirling-pdf:8080/api/v1/general/merge-pdfs`). Esos `curl` **omiten** Caddy completamente y por tanto **no pasan por Authelia**. Eso está bien por dos razones: (a) ya están dentro de la red Docker `homelab`, que no es accesible desde la LAN; (b) no hay datos persistentes que comprometer si un contenedor mal configurado abusa de Stirling. **Aceptado** sin más.

---

## Decisión: sin persistencia (stateless por diseño)

Stirling no necesita estado. Las tres fuentes de datos potenciales:

| Fuente | Decisión | Por qué |
|---|---|---|
| **Uploads de usuario** (`/tmp/<random>.pdf`) | `tmpfs` de 512 MiB en `/tmp` | RAM, cero IOPS contra disco, vacío al restart. |
| **`.traineddata` adicionales de OCR** | Bind mount **read-only** desde el repo del homelab en `/usr/share/tesseract-ocr/5/tessdata/` | Versionado en git si se añaden idiomas. |
| **Logs de aplicación** (`logs/`) | `STDOUT/STDERR` del contenedor | Captura `journald` vía `docker logs`. No persistente; rotación automática del driver. |

| Aspecto | Decisión | Por qué |
|---|---|---|
| BBDD | **Ninguna** (`SECURITY_ENABLELOGIN=false`) | No hay usuarios. |
| Configuración persistente | **Solo `.env` del compose**, versionable (`.env.example`) | Reproducible desde git. |
| Volúmenes Docker named | **Ninguno** | Nada que persistir. |
| Bind mounts a hd2t | **Ninguno** | Sin estado. |
| Bind mounts read-only | Solo CA interna y `.traineddata` opcionales | Configuración inmutable. |
| `tmpfs` para `/tmp` | **Sí**, `size=512m` | Aísla el procesado y limita el blast radius si alguien sube algo inesperado. |
| `read_only: true` para el rootfs | **Sí**, con `tmpfs` para `/tmp`, `/run`, `/var/log` | Defensa en profundidad: sin `tmpfs` de `/tmp`, Spring Boot fallaría al escribir el log de instalación en su primer arranque. |
| Backup Borg | **Excluido** (no `homelab.backup=true`) | Nada que respaldar más allá del repo. |

> **Por qué `tmpfs size=512m` y no más**. La RAM de la Pi 5 es 8 GiB. Reservar 512 MiB para `/tmp` está bien para PDFs de hasta ~200 MB simultáneos (los uploads se mantienen en disco mientras el endpoint los procesa). Subir más implicaría reducir el margen para Jellyfin/transcoding y otros stacks. Si el operador se topa con un "Out of disk space" al subir un libro escaneado de 600 MB, el síntoma es claro y se sube `size=1g` puntualmente.

> **Por qué `read_only: true` para el rootfs**. Stirling carga código Java al arrancar y escribe sólo en `/tmp`, `/var/cache`, `/var/log` y `/run`. Marcando el rootfs read-only se previene que un endpoint con LFI (poco probable pero documentado en CVEs de Spring Boot del pasado) pueda escribir un webshell en `/app`. Con `tmpfs` adicional para los directorios escribibles, Stirling arranca sin queja. **Aceptado**.

---

## Stack: `stacks/stirling-pdf/`

### Layout en disco

| Ruta | Soporte | Contenido |
|---|---|---|
| `stacks/stirling-pdf/docker-compose.yml` | microSD (git) | Stack (un único contenedor). |
| `stacks/stirling-pdf/.env.example` | microSD (git) | Plantilla con `STIRLING_*`. Sin secretos (no hay). |
| `stacks/stirling-pdf/.env` | microSD (NO git, idempotente) | Versión rellena. Como **no hay secretos**, en este stack `.env` puede ser idéntica a `.env.example` y queda versionable; aun así se mantiene fuera de git por consistencia. |
| `stacks/stirling-pdf/tessdata/` | microSD (git) | `.traineddata` adicionales (gallego, catalán, …) si el operador los añade. **Read-only** dentro del contenedor. |
| `stacks/caddy/conf.d/45-stirling-pdf.caddy` | microSD (git) | Drop-in Caddy para `stirling.${DOMAIN_LAN}`. |

> **Sobre la ausencia de rutas en `/mnt/hd2t/apps/stirling-pdf/`**. La Fase 1 (`01-sistema/04-estructura-directorios.md`) reservó `/mnt/hd2t/apps/stirling-pdf/data/` por homogeneidad con el resto de servicios. **No se usa** en este stack. Queda como directorio vacío `0750 homelab:homelab` por si en una iteración futura se activa EE u otra feature persistente — sin coste mientras no haya ficheros.

### `stacks/stirling-pdf/docker-compose.yml`

```yaml
# Stirling PDF — caja de herramientas para PDFs (stateless).
# Convenciones: ver docs/02-docker/02-estructura-compose.md y
# docs/11-productividad/06-stirling-pdf.md.

name: stirling-pdf

x-restart: &default-restart
  restart: unless-stopped

services:

  stirling-pdf:
    image: stirlingtools/stirling-pdf:0.45.0-fat
    container_name: stirling-pdf
    hostname: stirling-pdf
    <<: *default-restart

    environment:
      # Usuario del proceso (la imagen acepta PUID/PGID estilo LSIO).
      PUID: ${PUID}
      PGID: ${PGID}
      TZ: ${TZ}

      # Auth interna DESACTIVADA: el control vive en Caddy → Authelia.
      SECURITY_ENABLELOGIN: "false"
      # Banner UI (informativo) — no es funcional, pero deja claro el origen.
      UI_APPNAME: "Stirling PDF (homelab.lan)"
      UI_HOMEDESCRIPTION: "Tras autenticación SSO (Authelia)"

      # Idiomas de la UI y de OCR. La imagen -fat trae los .traineddata para
      # estos idiomas. Para añadir más, montar en /usr/share/tesseract-ocr/.
      SYSTEM_DEFAULTLOCALE: "es_ES"
      LANGS: "en_US,es_ES,fr_FR,de_DE,it_IT"

      # Endpoints peligrosos: filtrarlos. Lista versionada en este compose,
      # documentada en "Configuración → 4".
      ENDPOINTS_GROUPS_TO_REMOVE: "Python"   # quitar grupo "Python" (scripting)
      # Endpoints específicos a desactivar (si se quisiera, p.ej. cracking PDFs):
      # ENDPOINTS_TO_REMOVE: "remove-password,unlock-pdf"

      # Telemetría/analytics OFF (Stirling no manda nada por defecto, pero explícito).
      SYSTEM_ENABLEANALYTICS: "false"
      SYSTEM_GOOGLEVISIBILITY: "false"

      # Métricas Prometheus DESACTIVADAS por ahora.
      METRICS_ENABLED: "false"

      # Confiar en X-Forwarded-* de Caddy (Caddy es el único upstream).
      SERVER_FORWARDHEADERSSTRATEGY: "FRAMEWORK"

      # JVM tuning: la Pi 5 tiene 8 GiB; 512 MiB para Stirling es más que
      # suficiente para ~3 operaciones concurrentes.
      JAVA_TOOL_OPTIONS: "-Xms256m -Xmx512m -XX:+UseG1GC"

    networks:
      - homelab               # Caddy llega por aquí

    expose:
      - "8080"
    # NO `ports:`. Acceso solo vía Caddy.

    # Sin volúmenes persistentes. Sólo:
    # - tmpfs para /tmp (uploads efímeros).
    # - tmpfs adicionales para que `read_only: true` no rompa.
    # - Bind mount RO de tessdata/ del repo (idiomas de OCR adicionales).
    volumes:
      # Tessdata adicional (gallego, catalán, ...). Vacío por defecto.
      - /home/homelab/homelab/stacks/stirling-pdf/tessdata:/usr/share/tesseract-ocr/5/tessdata-extra:ro

    tmpfs:
      - /tmp:size=512m,mode=1777
      - /run:size=64m,mode=0755
      - /var/log:size=64m,mode=0755
      - /var/cache:size=128m,mode=0755

    read_only: true

    healthcheck:
      test: ["CMD-SHELL", "wget -q -O - http://127.0.0.1:8080/api/v1/info/status >/dev/null || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 90s

    security_opt:
      - "no-new-privileges:true"
    cap_drop:
      - ALL

    labels:
      homelab.role: "pdf-tools"
      # NO homelab.backup: nada que respaldar.
      com.centurylinklabs.watchtower.enable: "false"

networks:
  homelab:
    external: true
```

> **Sobre el `start_period: 90s`**. Spring Boot en Java 21 sobre Pi 5 (aarch64) tarda 30–60 s en levantar el embedded Tomcat, escanear los beans y registrar los endpoints. La variante `-fat` además inicializa LibreOffice headless en background al primer hit. 90 s da margen sin bucles `restart` espurios.

> **Sobre `ENDPOINTS_GROUPS_TO_REMOVE: "Python"`**. Stirling expone un grupo "Python" con endpoints que ejecutan scripts Python (transformaciones avanzadas). En un homelab familiar este vector no se usa y aporta superficie de ataque. **Filtrado por defecto**. Si se quiere rehabilitar, eliminar la variable. Otros grupos disponibles: `convert`, `general`, `images`, `pageOps`, `security`, `misc`.

> **Sobre `tessdata-extra` y no `tessdata`**. Stirling busca los `.traineddata` en `/usr/share/tesseract-ocr/5/tessdata/` (path por defecto de la imagen). Montar el bind mount **encima** (`tessdata:`) ocultaría los idiomas que la propia imagen `-fat` trae horneados (eng, spa, fra, deu, ita). Por eso se monta en un directorio sidecar (`tessdata-extra`) y se configura el comportamiento de Tesseract con `TESSDATA_PREFIX` o se ajusta a futuro. Para los idiomas estándar **basta** la imagen sin tocar nada.

> **Sobre `cap_drop: [ALL]`**. Spring Boot no necesita ninguna capability Linux (no hace `bind` < 1024, no hace `mknod`, no toca el reloj). Soltarlas todas reduce drásticamente el blast radius.

### `stacks/stirling-pdf/.env.example`

```bash
# stacks/stirling-pdf/.env.example
# Variables específicas del stack Stirling PDF. Las generales (TZ, PUID, PGID,
# DOMAIN_LAN) viven en el .env GLOBAL.
#
# Stirling PDF es STATELESS: NO HAY SECRETOS. Este fichero queda casi vacío,
# se mantiene por consistencia con la convención de Fase 2 (un .env por stack).
#
# Si en una iteración futura se habilita EE u OIDC, las variables específicas
# (STIRLING_OIDC_*, STIRLING_DB_*) se añadirán aquí.
```

### `stacks/caddy/conf.d/45-stirling-pdf.caddy`

```caddy
# /etc/caddy/conf.d/45-stirling-pdf.caddy — bloque LAN para Stirling PDF.
# UI + API en http://stirling-pdf:8080 dentro de `homelab`.
# Auth: forward_auth two_factor contra Authelia (no auth interna en Stirling).
# Documentado en docs/11-productividad/06-stirling-pdf.md.

stirling.{$DOMAIN_LAN} {
    import lan_tls
    import security_headers
    import healthcheck

    # Forzar 2FA Authelia para TODA la ruta (UI + /api/v1/*).
    import authelia_two_factor

    # Subida de PDFs grandes (libros escaneados, presentaciones con imágenes).
    # Stirling internamente acepta hasta 2 GB; Caddy con margen razonable.
    request_body {
        max_size 500MB
    }

    # Stirling responde con `Content-Disposition: attachment` en los endpoints
    # de descarga. Caddy no toca esa cabecera (se preserva en `reverse_proxy`).

    reverse_proxy http://stirling-pdf:8080 {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
        header_up X-Forwarded-Host {host}
    }
}
```

> **Sobre `request_body max_size 500MB`**. Sin esta directiva, Caddy aplica el límite por defecto (10 MiB) y subir un PDF escaneado de un libro de 80 MB falla con `413 Request Entity Too Large`. 500 MiB cubre el caso de uso doméstico con margen. El cuello de botella práctico se traslada al `tmpfs` de `/tmp` (512 MiB) — para subidas mayores, levantar el `tmpfs` o usar otra herramienta.

> **Sobre `import authelia_two_factor` único, sin `route` con bypass**. Stirling no tiene endpoints públicos legítimos (ni `health` para Caddy, que ya cubre `import healthcheck` en el mismo bloque vía la propia conexión interna). Toda la API se cierra. **Aceptado**.

### Crear los directorios y desplegar

```bash
# 0) Crear el directorio tessdata/ para idiomas de OCR adicionales (vacío)
sudo install -d -o homelab -g homelab -m 0755 \
    /home/homelab/homelab/stacks/stirling-pdf/tessdata

# 1) Materializar stacks/stirling-pdf/.env (idéntico a .env.example, sin secretos)
cd /home/homelab/homelab
set -a; source .env; set +a

cp stacks/stirling-pdf/.env.example stacks/stirling-pdf/.env
chmod 0600 stacks/stirling-pdf/.env

# 2) Drop-in de Caddy
install -o homelab -g homelab -m 0644 \
    stacks/caddy/conf.d/45-stirling-pdf.caddy \
    /mnt/hd2t/apps/caddy/etc/conf.d/45-stirling-pdf.caddy

# 3) Validar el Caddyfile
docker exec caddy caddy validate --config /etc/caddy/Caddyfile
# Successful

# 4) Validar el compose
docker compose \
    -f stacks/stirling-pdf/docker-compose.yml \
    --env-file stacks/stirling-pdf/.env \
    config >/dev/null && echo "compose OK"

# 5) Levantar el stack
docker compose \
    -f stacks/stirling-pdf/docker-compose.yml \
    --env-file stacks/stirling-pdf/.env \
    up -d

# 6) Recargar Caddy
docker kill --signal=SIGUSR1 caddy
```

Tras `up -d`:

```bash
docker ps --filter name=stirling-pdf --format 'table {{.Names}}\t{{.Status}}'
# stirling-pdf         Up 1 minute (healthy)

# Logs de arranque (Spring Boot)
docker logs stirling-pdf 2>&1 | grep -E 'Started|Tomcat started' | head
# o.s.b.w.embedded.tomcat.TomcatWebServer  : Tomcat started on port(s): 8080
# i.s.s.SPDFApplication                    : Started SPDFApplication in 38.4 seconds
```

Si el contenedor `stirling-pdf` no llega a `(healthy)` en 2 minutos, lo más probable es:
- RAM insuficiente — el OOMKiller de Linux mata la JVM. Comprobar `dmesg | grep -i 'killed process'`.
- `tmpfs` de `/tmp` lleno por una corrupción anterior. Resolver con `docker compose restart stirling-pdf`.
- La imagen no está cacheada y se está descargando aún (~1.6 GiB en `-fat`). `docker logs` muestra `Pulling fs layer`. Esperar.

Comprobación de extremo a extremo:

```bash
# La UI redirige a Authelia (302) sin sesión activa
curl -skI https://stirling.lan/ | head -1
# HTTP/2 302
# Location: https://auth.lan/?rd=...

# El endpoint health responde 200 (lo cubre forward_auth tras login)
# Tras login Authelia y export de la cookie:
curl -sk -b /tmp/authelia.jar https://stirling.lan/api/v1/info/status
# UP
```

---

## Configuración

### 1) Verificar el flujo `forward_auth` de extremo a extremo

Tras `up -d`:

1. Abrir `https://stirling.lan/` en el navegador del operador (sin sesión Authelia previa).
2. Caddy → Authelia: redirección a `https://auth.lan/?rd=https%3A%2F%2Fstirling.lan%2F`.
3. Authelia pide login + TOTP.
4. Tras autenticar, Authelia redirige de vuelta a `https://stirling.lan/`.
5. Caddy hace `forward_auth` interno a `authelia:9091/api/verify` con la cookie; Authelia responde 200; Caddy deja pasar la petición original.
6. Stirling sirve la home con todos los grupos de herramientas.

Si la home aparece sin pedir Authelia, **algo está mal**: probable que el snippet `authelia_two_factor` no se esté importando, o que ya hubiera sesión SSO de otro servicio (esperado y **correcto**).

```bash
# Inspeccionar la primera respuesta sin cookie de sesión
curl -skI https://stirling.lan/
# Debe ser 302 hacia auth.lan
```

### 2) Habilitar idiomas de OCR adicionales (opcional)

La imagen `-fat` trae `.traineddata` para inglés, español, francés, alemán e italiano. Para añadir gallego (`glg.traineddata`), catalán (`cat.traineddata`) o portugués (`por.traineddata`):

```bash
cd /home/homelab/homelab/stacks/stirling-pdf/tessdata

# Descargar de tessdata_best (mejor calidad, modelo LSTM completo)
sudo -u homelab curl -fSL \
    -O https://github.com/tesseract-ocr/tessdata_best/raw/main/cat.traineddata
sudo -u homelab curl -fSL \
    -O https://github.com/tesseract-ocr/tessdata_best/raw/main/glg.traineddata
sudo -u homelab curl -fSL \
    -O https://github.com/tesseract-ocr/tessdata_best/raw/main/por.traineddata

# Versionarlos en git (~10–20 MiB cada uno, aceptable)
cd /home/homelab/homelab
git add stacks/stirling-pdf/tessdata/*.traineddata
git commit -m "stirling-pdf: añadir traineddata cat/glg/por"
```

Activarlos en Stirling:

1. Editar `stacks/stirling-pdf/docker-compose.yml` y ajustar `LANGS`:

   ```yaml
   LANGS: "en_US,es_ES,fr_FR,de_DE,it_IT,ca_ES,gl_ES,pt_PT"
   ```

2. Hacer que Tesseract los descubra. La forma más limpia es montar `tessdata/` directamente en el path estándar **junto** con los originales. Cambiar el bind mount a:

   ```yaml
   volumes:
     - /home/homelab/homelab/stacks/stirling-pdf/tessdata:/extra-tessdata:ro
     # Y añadir hook de arranque (ver nota abajo).
   ```

3. Recrear:

   ```bash
   docker compose \
       -f /home/homelab/homelab/stacks/stirling-pdf/docker-compose.yml \
       --env-file /home/homelab/homelab/.env \
       --env-file /home/homelab/homelab/stacks/stirling-pdf/.env \
       up -d --force-recreate
   ```

> **Nota técnica**: Tesseract resuelve el directorio de `traineddata` con la variable `TESSDATA_PREFIX`. Si una versión futura de Stirling cambia el path, se ajusta aquí. Hasta entonces, la opción más simple es **construir una imagen propia** que extienda la oficial:
>
> ```dockerfile
> FROM stirlingtools/stirling-pdf:0.45.0-fat
> COPY tessdata/*.traineddata /usr/share/tesseract-ocr/5/tessdata/
> ```
>
> y publicarla en un registry interno o construirla en el host con `docker build`. Reabrible si la familia escala el uso de OCR a idiomas no estándar.

### 3) Endurecer endpoints (`ENDPOINTS_GROUPS_TO_REMOVE`)

Stirling agrupa endpoints en categorías. La default activa **todas**. El homelab filtra `Python` (scripting que pocas familias usan). Otros grupos plausibles para deshabilitar según el caso:

| Grupo | Qué incluye | ¿Quitar? |
|---|---|---|
| `general` | Merge, split, rotate, reorder. | **Mantener** (caso de uso principal). |
| `convert` | DOCX↔PDF, HTML→PDF, PDF→imagen. | **Mantener**. |
| `images` | PDF↔imagen, OCR. | **Mantener**. |
| `pageOps` | Crop, scale, blank-page detection. | **Mantener**. |
| `security` | Add password, remove password, sign, redact. | **Mantener** (uso ocasional pero real). |
| `misc` | Compress, repair, sanitize, metadata. | **Mantener**. |
| `Python` | Endpoints que ejecutan scripts Python adjuntos. | **Quitar** por defecto (sin uso doméstico, vector). |

```yaml
ENDPOINTS_GROUPS_TO_REMOVE: "Python"
# Para deshabilitar también `repair` (que algunos consideran abusable):
# ENDPOINTS_TO_REMOVE: "repair"
```

Tras editar el compose, `docker compose up -d --force-recreate stirling-pdf`. Verificar:

```bash
# Tras login Authelia (cookie en /tmp/authelia.jar):
curl -sk -b /tmp/authelia.jar https://stirling.lan/api/v1/general/merge-pdfs -X OPTIONS
# 200 (mantenido)

curl -sk -b /tmp/authelia.jar -o /dev/null -w "%{http_code}\n" \
    https://stirling.lan/api/v1/external/python -X OPTIONS
# 404 (eliminado)
```

### 4) Idioma por defecto de la UI

`SYSTEM_DEFAULTLOCALE` controla el idioma del `<html lang="...">` y los textos de la UI cuando el navegador no manda `Accept-Language` legible. Para una familia castellanohablante:

```yaml
SYSTEM_DEFAULTLOCALE: "es_ES"
```

Con `es_ES`, los nombres de los endpoints en la UI ("Combinar PDFs", "Rotar páginas") aparecen traducidos. El navegador del operador puede pedir `en-US;q=0.9, es;q=0.8` y aún así Stirling respeta el default si lo prefiere — el toggle de idioma en la esquina superior derecha lo cambia per-sesión.

### 5) Banner UI (opcional)

`UI_APPNAME` y `UI_HOMEDESCRIPTION` permiten personalizar el header. Se aprovecha para dejar claro de qué instancia se trata (útil si el operador algún día corre un Stirling adicional en un VPS):

```yaml
UI_APPNAME: "Stirling PDF (homelab.lan)"
UI_HOMEDESCRIPTION: "Tras autenticación SSO (Authelia)"
```

### 6) Monitor en Uptime Kuma

En `https://uptime.${DOMAIN_LAN}/` añadir un **monitor HTTP(s)**:

| Campo | Valor |
|---|---|
| Friendly Name | `Stirling PDF` |
| URL | `https://stirling.lan/api/v1/info/status` |
| Heartbeat Interval | 120 s |
| Retries | 3 |
| Accepted Status Codes | 200 OR 302 |
| Auth | None (Uptime Kuma no autenticará; lo que se mide es disponibilidad TCP/TLS, el 302 a Authelia ya es señal de que Caddy + Authelia + Stirling están vivos) |
| Notification | Telegram + email (Mailrise cuando exista) |
| Public on status page | Sí |

> **Por qué aceptar 302**. Sin cookie de Authelia, Caddy hará `forward_auth` que devuelve 401 → Authelia redirige con 302 a `auth.lan`. Eso sigue siendo "Stirling vivo" desde el punto de vista de Uptime Kuma. Si fuera 502 o 504, sí indicaría problema (Caddy no llega a Stirling, Stirling caído, etc.).

### 7) Bookmarklet/atajos del operador (opcional)

El operador puede dejar `https://stirling.lan/` como marcador en la barra de favoritos. Los endpoints más frecuentes tienen URL directa:

| Operación | URL directa |
|---|---|
| Merge PDFs | `https://stirling.lan/merge-pdfs` |
| Split | `https://stirling.lan/split-pdfs` |
| Rotate | `https://stirling.lan/rotate-pdf` |
| OCR | `https://stirling.lan/ocr-pdf` |
| Compress | `https://stirling.lan/compress-pdf` |
| Convert (DOCX → PDF) | `https://stirling.lan/file-to-pdf` |

Útil para usar Stirling desde un menú contextual del navegador con extensiones tipo "Open with…".

---

## Almacenamiento

| Ruta | Soporte | Owner:Group | Modo | Contenido |
|---|---|---|---|---|
| `/home/homelab/homelab/stacks/stirling-pdf/docker-compose.yml` | microSD | `homelab:homelab` | `0640` | Stack versionado en git. |
| `/home/homelab/homelab/stacks/stirling-pdf/.env.example` | microSD | `homelab:homelab` | `0644` | Plantilla versionada (sin secretos). |
| `/home/homelab/homelab/stacks/stirling-pdf/.env` | microSD | `homelab:homelab` | `0600` | Idéntico a `.env.example` (no hay secretos). **No** versionado por convención. |
| `/home/homelab/homelab/stacks/stirling-pdf/tessdata/` | microSD | `homelab:homelab` | `0755` | `.traineddata` adicionales si se han añadido. **Versionado**. |
| `/home/homelab/homelab/stacks/caddy/conf.d/45-stirling-pdf.caddy` | microSD | `homelab:homelab` | `0644` | Drop-in Caddy. **Versionado**. |
| `/mnt/hd2t/apps/caddy/etc/conf.d/45-stirling-pdf.caddy` | hd2t | `homelab:homelab` | `0644` | Drop-in materializado. |
| `/mnt/hd2t/apps/stirling-pdf/data/` | hd2t | `homelab:homelab` | `0750` | **Vacío y sin uso**. Reservado por la Fase 1 por homogeneidad. |
| `/tmp` (dentro del contenedor) | RAM (`tmpfs`) | `1000:1000` | `1777` | Uploads temporales. **No persistente** entre restarts. |

> **Tamaño esperado en disco**: **0 KiB** de datos del servicio en hd2t. El stack consume `~1.6 GiB` de imagen Docker (variante `-fat`) y `~700 MiB` de RAM en runtime. Los `.traineddata` adicionales (si se añaden) suman ~10–20 MiB cada uno al repo del homelab.

---

## Backup

A nivel del repositorio del homelab:

| Artefacto | Estrategia |
|---|---|
| `stacks/stirling-pdf/docker-compose.yml`, `.env.example`, `tessdata/*.traineddata` | Versionados en git. Reproducibles tras un reflasheo. |
| `stacks/caddy/conf.d/45-stirling-pdf.caddy` | Versionado en git. |
| `stacks/stirling-pdf/.env` | Sin secretos. Si se respaldara con Borg lo haría como parte de `/home/homelab/homelab/`, pero por ser idéntico a `.env.example` no aporta valor restaurarlo aparte. |
| Decisiones (stateless, `read_only`, `forward_auth two_factor`, endpoints filtrados) | Documentadas en este fichero. |

A nivel de datos (Borgmatic, Fase 7):

| Ruta | Tier | ¿Se respalda? | Por qué |
|---|---|---|---|
| (cualquier ruta de Stirling) | — | **No** | El servicio es stateless. Tras reflasheo, `git clone` + `up -d` devuelven el estado funcional completo. |

> **Sobre la ausencia de `homelab.backup=true`**. Los hooks de Borgmatic (Fase 7) usan la label `homelab.backup` para descubrir contenedores con datos. Stirling **no la lleva** y por tanto Borg lo ignora. Es la forma idiomática del homelab de declarar "este servicio no necesita respaldo".

Procedimiento de "restore" tras pérdida del contenedor:

```bash
docker compose -f /home/homelab/homelab/stacks/stirling-pdf/docker-compose.yml \
    --env-file /home/homelab/homelab/.env \
    --env-file /home/homelab/homelab/stacks/stirling-pdf/.env \
    up -d --force-recreate
# Listo. Sin estado que restaurar.
```

Procedimiento tras pérdida total (reflasheo + restauración Borg):

1. Recrear sistema base (Fase 1), Docker (Fase 2.1), red `homelab` (Fase 2.2), Pi-hole, Caddy, Authelia.
2. Restaurar el repo del homelab:
   ```bash
   sudo borg extract /mnt/hd2t/backups/borg::homelab-LATEST \
       home/homelab/homelab
   sudo chown -R homelab:homelab /home/homelab/homelab
   ```
3. Levantar el stack:
   ```bash
   cd /home/homelab/homelab
   docker compose -f stacks/stirling-pdf/docker-compose.yml \
       --env-file stacks/stirling-pdf/.env \
       up -d
   ```
4. Verificar `https://stirling.lan/` (302 a Authelia sin sesión, 200 con sesión válida).

> **Punto de no retorno**: ninguno. El RPO efectivo es **0** porque no hay datos persistentes que perder. Cualquier upload "en vuelo" en el momento de la pérdida sí desaparece (estaba en RAM), pero eso es responsabilidad del operador (re-subir el PDF original, que sigue en su portátil).

---

## Errores frecuentes y troubleshooting

| Síntoma | Causa probable | Resolución |
|---|---|---|
| `stirling-pdf` queda en `(starting)` 2+ minutos y luego cae a `unhealthy` | OOM por `JAVA_TOOL_OPTIONS=-Xmx512m` insuficiente para una operación grande. | Subir `-Xmx` a `768m` o `1024m`. Verificar `dmesg \| grep -i killed`. |
| Imagen no descargada — `docker logs` muestra `Pulling fs layer` durante 5+ minutos | Variante `-fat` pesa ~1.6 GiB y la red residencial es limitada. | Esperar. Ejecutar `docker pull stirlingtools/stirling-pdf:0.45.0-fat` por adelantado antes del `up -d`. |
| `https://stirling.lan/` muestra la home **sin** pedir Authelia | El drop-in 45 no importa `authelia_two_factor`, **o** ya hay sesión SSO de otro servicio (esperado). | Verificar `grep authelia_two_factor /mnt/hd2t/apps/caddy/etc/conf.d/45-stirling-pdf.caddy`. Probar en pestaña incógnita. |
| `https://stirling.lan/` redirige a Authelia pero tras login devuelve 502 | Stirling no terminó de arrancar (Spring Boot lento). | `docker logs stirling-pdf 2>&1 \| grep Started`. Esperar 60–90 s tras `up -d`. |
| Subida de PDF de 80 MB falla con `413 Request Entity Too Large` | Caddy con `request_body max_size` por defecto (10 MiB). | El drop-in 45 ya fija `500MB`. Verificar `caddy validate` y reload. |
| Subida de PDF de 600 MB devuelve 500 | El `tmpfs` de `/tmp` (512 MiB) se llena. | Subir `tmpfs: size=1g` puntualmente, o usar otra herramienta para ese PDF concreto. |
| OCR en español funciona pero en gallego devuelve "No data found" | Falta `glg.traineddata` en `tessdata-extra/` o no está en path | Sección "Configuración → 2". Reconsiderar si es viable construir imagen custom. |
| Endpoint `/api/v1/external/python/...` devuelve 404 con cookie válida | `ENDPOINTS_GROUPS_TO_REMOVE: "Python"` activo (esperado). | Para rehabilitarlo, eliminar la variable y `up -d --force-recreate`. |
| Endpoint `convert` falla con "LibreOffice failed to start" | La imagen `-fat` lo trae, pero la primera invocación arranca el demonio (lento, ~10 s). | Reintentar tras unos segundos. Si persiste, `docker logs stirling-pdf \| grep -i libre`. |
| Logs de Stirling crecen sin parar y consumen `tmpfs` de `/var/log` | El driver de logs de Docker (`json-file`) por defecto no rota. | Configurar el driver en `docker-compose.yml` con `logging.options.max-size: 10m, max-file: 3`. |
| Tras subir versión (`0.45.0` → `0.46.0`) algún endpoint devuelve 404 | Cambio de path entre menores (Stirling 0.x no garantiza estabilidad de URLs). | Leer changelog antes del upgrade. Ajustar bookmarks/scripts. **Antes de cualquier upgrade** asegurar que no se rompen flujos críticos (manual, sin tests automatizados). |
| `docker compose down` deja huérfano un proceso `soffice.bin` (LibreOffice) en el host | El demonio LibreOffice quedó zombie por terminación abrupta. | `docker compose down --remove-orphans`. Si persiste, `docker rm -f stirling-pdf`. |
| `read_only: true` rompe alguna operación nueva en versión futura | Una nueva feature requiere escribir fuera de `/tmp`, `/run`, `/var/log`, `/var/cache`. | Añadir el path como `tmpfs` al compose, o quitar `read_only` puntualmente. Documentar en commit. |
| `curl https://stirling.lan/api/v1/info/status` desde la LAN devuelve 401 sin redirigir | El cliente no sigue redirects (`-L`) o no manda cookie. | `curl -L -b /tmp/authelia.jar ...` tras `curl -c /tmp/authelia.jar https://auth.lan/...` con flujo de login. |

---

## Decisiones que **no** se toman en este documento

- **Stirling EnterpriseEdition con login propio + OIDC + auditoría**: requiere licencia EE y BBDD H2/Postgres, rompe el principio "stateless". Reabrible si la familia ampliada quiere historial por usuario.
- **API tokens persistentes para automatización por scripts cron**: hoy no hay caso de uso. Se difiere; se añadirá una sección a `04-seguridad/01-authelia.md` con un patrón de "service account" en Authelia cuando aparezca el primer cliente real.
- **Métricas Prometheus** (`METRICS_ENABLED=true`): Stirling expone `/actuator/prometheus` de Spring Boot. Para un servicio de uso esporádico, las métricas aportan ruido. Reabrible si se quiere medir uso por endpoint.
- **Construcción de imagen custom con `.traineddata` adicionales**: hoy se opta por bind mount del directorio del repo. Si el operador empieza a usar OCR en idiomas no latinos con frecuencia, se documenta `Dockerfile` propio en `stacks/stirling-pdf/Dockerfile`.
- **Integración con Paperless-ngx** ("transformar y mandar a Paperless en un click"): Stirling no tiene plugin para ello. El flujo manual (descargar → arrastrar a `consume/`) cubre el caso. Reabrible si se vuelve frecuente.
- **Firmas digitales criptográficas con certificado X.509**: Stirling solo dibuja firma visual. Para firma legal, herramientas dedicadas (`pyhanko`, Adobe Sign).
- **Conversión a formatos exóticos** (Postscript a PDF, EPUB a PDF): la imagen `-fat` cubre lo común. Para casos puntuales, `pandoc` desde la línea de comandos del host es más controlable.
- **Compartir Stirling con usuarios externos** vía un *guest token* o un share temporal: cualquier acceso requiere cuenta en Authelia. No hay plan de exponer Stirling fuera del círculo familiar.
- **Backups Borg**: el servicio es stateless. Sin `homelab.backup=true`, sin entradas en `borgmatic.yaml`.

---

## Referencias

- Documentación oficial Stirling PDF: <https://docs.stirlingpdf.com/>
- Configuración (variables de entorno): <https://docs.stirlingpdf.com/Advanced%20Configuration/System%20and%20Security>
- Lista de endpoints / API: <https://docs.stirlingpdf.com/API>
- Imagen Docker (Docker Hub): <https://hub.docker.com/r/stirlingtools/stirling-pdf>
- Imagen Docker (alias histórico): <https://hub.docker.com/r/frooodle/s-pdf>
- Repositorio: <https://github.com/Stirling-Tools/Stirling-PDF>
- `tessdata_best` (idiomas adicionales de OCR): <https://github.com/tesseract-ocr/tessdata_best>
- API REST en vivo (Swagger UI tras login): `https://stirling.lan/swagger-ui/index.html`
- Documentos del homelab relacionados:
  - `02-docker/02-estructura-compose.md` — convenciones del compose y de las redes Docker.
  - `03-red/04-caddy.md` — TLS interno con CA, `(lan_tls)` y patrón de drop-ins.
  - `04-seguridad/01-authelia.md` — snippets `(authelia_one_factor)` y `(authelia_two_factor)`.
  - `07-backups/02-borgmatic.md` — convención de la label `homelab.backup` y por qué este stack no la lleva.
  - `11-productividad/04-paperless-ngx.md` — flujo de archivado tras transformar el PDF en Stirling.
