# Stirling-PDF

## Descripción

Despliegue de **Stirling-PDF** ([imagen `docker.stirlingpdf.com/stirlingtools/stirling-pdf`](https://github.com/Stirling-Tools/Stirling-PDF)) como **suite web de manipulación de PDF** del homelab. Stirling-PDF es una aplicación Spring Boot (Java 21) + frontend Thymeleaf + sidecars Python (OCRmyPDF) y LibreOffice headless empaquetados en una sola imagen. Su valor: **>50 herramientas PDF** (split, merge, compress, rotate, watermark, OCR, sign, redact, convert PDF↔Word/Excel/PowerPoint/PNG/HTML, comparar, repair, encrypt/decrypt, extract images/text, edit metadata, multi-page imposition…) servidas por una UI web autocontenida, sin telemetría, sin envío de ficheros a terceros, sin cuenta SaaS. Las piezas mecánicas: backend Spring Boot con Tomcat embebido en `:8080`, motor `pdfbox` 3.x para manipulación PDF nativa, **`qpdf`** + **Ghostscript** para repair/encrypt/linearize, **Poppler** (`pdftoppm`, `pdftotext`) para conversión PDF↔imagen y extracción, **OCRmyPDF** + **Tesseract 5** para OCR, **LibreOffice headless** (Soffice) para conversiones a/desde formatos office, **Pillow/ImageMagick** para imágenes, **uno** (Python+UNO) como puente con LibreOffice. Es la pieza canónica del homelab para "tengo este PDF de la administración escaneado, lo quiero comprimir, OCR-izar, partir por capítulos, firmar y reenviar" — sin subirlo a `ilovepdf.com`/`smallpdf.com`/Adobe Cloud, donde el contenido (datos personales, facturas, contratos) saldría del homelab y caería bajo una política de privacidad de un tercero.

Por qué exactamente esta arquitectura, y no otra:

1. **Stirling-PDF, no PDF24, no PdfArranger, no Sejda CE, no LibreOffice solo, no scripts ad-hoc.** El espacio de "suite PDF self-hosted" tiene varios contendientes con perfiles distintos: (a) **PDF24** es freeware Windows + un servicio web propietario (no self-hosted); (b) **PdfArranger** (GTK desktop) y **Stirling-CLI** son útiles pero **desktop-only**, sin UI web — el operador acabaría haciendo SSH+SCP a la Pi para procesar PDFs; (c) **Sejda CE** está disponible self-hosted **pero con feature gating agresivo** (la versión libre limita el número de PDFs/hora y oculta tools como compresión avanzada); (d) **LibreOffice solo** cubre conversión Word→PDF pero no OCR, ni split, ni merge, ni firma; (e) **scripts ad-hoc** con `pdftk`, `qpdf`, `ocrmypdf`, `gs`, `mutool`, `pdfunite`… funcionan pero requieren recordar la sintaxis exacta de cada uno y el operador acaba escribiendo su propio frontend. Stirling-PDF es la suma de todos esos binarios con un frontend HTML coherente, batch operations, drag&drop, y >50 tools en una sola URL. Comunidad muy activa (>40 k estrellas en GitHub a finales de 2024, releases mensuales, mantenido por Stirling-Tools como org dedicada tras el fork del autor original `Frooodle`), licencia MIT, multi-arch oficial (`linux/amd64` + `linux/arm64`).
2. **Imagen `docker.stirlingpdf.com/stirlingtools/stirling-pdf:<version>` upstream, no LinuxServer.io, no `frooodle/s-pdf` legacy.** A diferencia de Bookstack ([`./02-bookstack.md`](./02-bookstack.md) §0 punto 2, donde LSIO bundlea Apache + PHP-FPM + nginx) o Calibre-Web ([`../09-multimedia/04-calibre-web.md`](../09-multimedia/04-calibre-web.md)), la imagen **upstream** de Stirling-PDF **es por sí sola** monolítica para todo lo que es la app: bundlea OpenJDK 21 + Spring Boot fat-jar + LibreOffice headless + Python 3.11 + OCRmyPDF + Tesseract 5 + Ghostscript + qpdf + Poppler + ImageMagick + ExifTool + unpaper. LSIO no publica `stirling-pdf`. El nombre viejo `frooodle/s-pdf` (Docker Hub) es un alias del autor original que sigue activo pero **no** es la fuente recomendada desde 2024 — el equipo migró a la org `Stirling-Tools` y publica en tres registries con la **misma manifest list**: `docker.stirlingpdf.com/stirlingtools/stirling-pdf` (canónico, sin rate-limit), `docker.io/stirlingtools/stirling-pdf` (Docker Hub, con rate-limit de pull anónimo) y `ghcr.io/stirling-tools/stirling-pdf` (GHCR). El homelab elige el registry canónico (`docker.stirlingpdf.com`) porque es el **único** sin límite de pulls anónimos, lo cual importa cuando Watchtower hace `pull` cada noche y, en una semana cualquiera, varios servicios coinciden refrescando a la vez. La etiqueta usada en este doc es `<version>` puntual (no `latest`, no `latest-fat`, no `latest-ultra-lite`).
3. **Variante `<version>` "full" (no `latest-ultra-lite`).** Stirling-PDF publica **dos** variantes principales por release: (a) **`<version>`** (full) — incluye OCR + LibreOffice + Python, ~2.4 GB de imagen comprimida, RAM en idle ~400-700 MB y picos de 1.5-2 GB durante OCR de un PDF de 100 páginas; (b) **`<version>-ultra-lite`** — sin OCR, sin LibreOffice, sin Python; ~150 MB de imagen, ~150 MB RAM en idle, **pero pierde** OCR (la tool más diferenciadora frente a `qpdf`/`pdftk` por scripts), conversiones office (PDF→Word, Word→PDF), HTML→PDF y compresión avanzada. La etiqueta antigua `latest-fat` (bundleaba además Calibre y plugins de OCR adicionales) está **deprecada** desde 2024-Q4 y el equipo recomienda usar la full + montar `/usr/share/tessdata` con paquetes Tesseract adicionales si hace falta más cobertura de idiomas. El homelab elige **full** porque OCR + conversión a Word son exactamente las tools que el operador quiere para PDFs escaneados de la administración pública española (DNI, facturas, contratos, partidos médicos). Variante `ultra-lite` queda como opt-in en §12.5 para el operador con presión de RAM o disco.
4. **Detrás de Caddy con CA interna **+ Authelia delante** con `forward_auth`.** Diferente de Linkding ([`./03-linkding.md`](./03-linkding.md) §0 punto 4) y Mealie ([`./05-mealie.md`](./05-mealie.md) §0 punto 4): Stirling-PDF **no tiene clientes API externos** que necesiten bypass — la app es **UI-only** (no hay extensión de navegador, no hay app móvil oficial, no hay integraciones con Home Assistant). Toda la auth la consume un humano frente al navegador. Y los PDFs que se suben pueden contener datos personales sensibles (facturas con NIF, contratos firmados, partes médicos, justificantes bancarios) — exponer la UI sin auth incluso dentro de la LAN es asimétrico con el coste de tener Authelia ya desplegado. El homelab activa Authelia en `forward_auth` con `policy: two_factor` (mismo perfil que Bookstack y Paperless-ngx, justificado en sus docs §0 punto 4). La regla `stirling-pdf.{{ env "LAN_DOMAIN" }}` se **añade** a `access_control.rules` de Authelia ([`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md) §5, líneas 413-427); el bloque actual lista `paperless`, `bookstack`, etc., pero **no** lista todavía `stirling-pdf` — este doc deja constancia y añade la línea como parte del despliegue (§6.1.2). Variante con **login nativo de Stirling** (`SECURITY_ENABLELOGIN=true`, base de datos H2 interna) en §12.4, útil sólo si el operador no quiere desplegar Authelia o si necesita tokens API para automatización (raro).
5. **Stateless: sin volúmenes persistentes para datos de aplicación.** El plan del homelab es explícito ([`../../plans/PLAN.md`](../../plans/PLAN.md), línea 144: *"Despliegue de Stirling PDF (stateless, sin datos persistentes)"*). Stirling-PDF **no necesita** persistir estado para funcionar: cada operación (split, merge, OCR…) es un ciclo cerrado *upload → process → download*, todos los ficheros temporales viven en `/tmp` dentro del contenedor durante la operación y se borran al terminar (o, en su defecto, al reiniciarse el contenedor). Las únicas piezas que **podrían** persistirse y deliberadamente **no** se persisten son: (a) `/configs/settings.yml` — fichero opcional con overrides de la UI (nombre de la app, idioma por defecto, tools deshabilitadas, branding…); el homelab lo materializa **solo** vía variables de entorno, no como fichero, así el operador puede cambiar branding editando el `.env` y `docker compose up -d` recreará el contenedor con el nuevo settings; (b) `/customFiles` — para overrides de logo/CSS personalizados; el homelab no lo usa; (c) `/usr/share/tessdata` — paquetes Tesseract adicionales para OCR multi-idioma; el homelab usa los baked-in en la imagen (inglés + español + lo que la imagen oficial incluye) y deja como opt-in (§12.6) la persistencia de tessdata para añadir más idiomas; (d) `/logs` — logs de aplicación; el homelab los captura por `docker logs` (driver `json-file` + rotación nativa Docker, [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §6); (e) `/pipeline` — definiciones declarativas de pipelines automatizadas (variante avanzada, §12.7). El árbol que se materializa en §3 es **mínimo**:
   - `/mnt/hd2t/services/stirling-pdf/.env` — configuración del stack (chmod 600).
   - **Nada más en disco persistente del servicio.** El directorio `/mnt/hd2t/services/stirling-pdf/` queda creado por el bootstrap de [`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) §4.1 (loop "Fase 11 — Productividad", línea 241: `for svc in vaultwarden bookstack linkding paperless-ngx mealie stirling-pdf freshrss`) pero solo aloja el `.env` de bootstrap.
6. **`tmpfs` para `/tmp` dentro del contenedor.** Como contrapartida del statelessness: Stirling-PDF escribe **todos** los ficheros intermedios (PDFs subidos por el navegador, salidas de cada paso de OCR, splits, conversiones de LibreOffice…) bajo `/tmp/stirling-pdf-files/`. Para un PDF típico de 30 MB con OCR completo, los temporales pueden ser ~200 MB durante el procesamiento. Sin `tmpfs`, esos 200 MB tocan el filesystem del contenedor — que en la Pi 5 **es la microSD** (overlay2 sobre `/var/lib/docker/`), generando **escritura intensiva en microSD** que es exactamente lo que la Fase 0 ([`../00-hardware/03-preparacion-discos.md`](../00-hardware/03-preparacion-discos.md)) intenta evitar. Solución: montar `/tmp` como `tmpfs` (RAM) con `size=512m`. Esto: (a) protege la microSD de I/O de PDFs efímeros; (b) acelera el OCR (RAM > microSD random write); (c) garantiza limpieza al recrear el contenedor (cero residuos en disco). Coste: 512 MB de RAM "ocupados" potencialmente — la Pi 5 (8 GB) lo absorbe sin sudar, especialmente porque `tmpfs` es lazy (solo consume RAM cuando hay ficheros realmente escritos). Variante con `/tmp` en `hd2t` (para PDFs gigantes >500 MB) en §12.2.
7. **Imagen pinned a release puntual; Watchtower HABILITADO.** Misma regla del homelab: nunca `latest`, nunca `<version>-rc`, nunca `nightly`. **Stirling-PDF está en el grupo de auto-update** ([`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §4.1 línea 94 y §4.2 línea 466 — "Stirling-PDF" listado explícitamente como `enable: "true"`). Justificación: (a) statelessness implica **rollback trivial** — `docker compose pull` con el tag anterior + `up -d` y todo vuelve, sin BD que migrar; (b) Stirling-PDF **no tiene migraciones de schema** (no hay BD; las settings se inyectan por env, son idempotentes); (c) las release notes históricas muestran que las breaking changes de la app son sobre **nombres de variables de entorno** (renombrar `INSTALL_BOOK_AND_ADVANCED_HTML_OPS` a `STIRLING_INSTALL_BOOK_AND_ADVANCED_HTML_OPS` entre versiones, p. ej.) — un upgrade defectuoso da error claro al arrancar (`Unknown property: ...`) y el operador detecta el problema en el siguiente health-check. El default de Watchtower aplica; **no** se añade `com.centurylinklabs.watchtower.enable: "false"`.
8. **UID `1000:1000` para el proceso del contenedor, vía `user:` directo en Compose.** La imagen oficial de Stirling-PDF crea internamente un usuario `stirlingpdfuser` con UID/GID configurables vía `PUID`/`PGID` (estilo LSIO-like, soportado en versiones >= 0.30). Pero al ser **stateless**, no hay bind mount cuyo ownership reconciliar — la única razón histórica para usar `PUID/PGID` (que el bind mount externo coincida con el UID interno) **desaparece** aquí. El homelab simplifica: `user: "1000:1000"` directo en el Compose (homelab UID), sin pasar por `PUID/PGID` env vars. El proceso Java arranca como UID 1000 desde el primer instante, sin ciclo de `chown` interno. La excepción es la variante con `/usr/share/tessdata` montado (§12.6): allí sí se usa PUID/PGID porque hay que reconciliar ownership con los ficheros de Tesseract en hd2t.
9. **`SECURITY_ENABLELOGIN=false` (la auth la lleva Authelia).** Stirling-PDF tiene **dos modos** de auth: (a) **sin login** (`DOCKER_ENABLE_SECURITY=false` en build-time + `SECURITY_ENABLELOGIN=false` en runtime) — la app sirve la UI sin autenticar; (b) **con login** — añade Spring Security, base de datos H2 embebida en `/configs/stirling-pdf-DB.h2.db`, usuarios con bcrypt, formulario `/login`, soporte SSO OAuth2/SAML/LDAP. La imagen oficial **viene buildeada por defecto sin security** (`DOCKER_ENABLE_SECURITY=false` se evaluó en CI/CD del proyecto y está horneado en la imagen `latest`); para activar login, hay que: (1) usar la imagen variante `<version>-security` o (2) buildear localmente con `DOCKER_ENABLE_SECURITY=true`. El homelab **no** activa el login interno: justificación coherente con §0 punto 4 — Authelia hace `forward_auth` delante, los PDFs ya están detrás de 2FA antes de tocar Stirling-PDF, añadir login nativo solo duplica formularios sin aportar seguridad. Variante con login nativo (sin Authelia delante) en §12.4.
10. **`METRICS_ENABLED=false` por defecto.** Stirling-PDF expone métricas Prometheus en `/actuator/prometheus` (Spring Boot Actuator) si `METRICS_ENABLED=true`. El homelab tiene Prometheus desplegado ([`../05-monitorizacion/01-prometheus.md`](../05-monitorizacion/01-prometheus.md)) pero deja la integración como **opt-in** (§12.3) por dos motivos: (a) Stirling-PDF es **uso intermitente** (el operador procesa 0-5 PDFs por semana), las métricas son ruido más que señal en un dashboard de homelab; (b) `/actuator/prometheus` queda **detrás de Authelia** por nuestra configuración — Prometheus tendría que llamar al endpoint vía la red Docker `http://stirling-pdf:8080/actuator/prometheus` (sin pasar por Caddy, sin Authelia) y eso obliga a configurar Spring Security para permitir `/actuator/*` sin auth aun cuando se active login. La vista del homelab: para uptime monitoring usar **Uptime Kuma** ([`../05-monitorizacion/05-uptime-kuma.md`](../05-monitorizacion/05-uptime-kuma.md)) con un check HTTP en `https://stirling-pdf.lan/api/v1/info/status` (y la cabecera `Authorization: Basic`/cookie si Authelia bloquea la sonda — ver §6.4 para el path bypassed). Las métricas Spring quedan disponibles si en algún momento el operador investiga rendimiento.
11. **Sin SMTP, sin almacenamiento de operaciones, sin "historial" de PDFs procesados.** Stirling-PDF **no envía emails** y, fuera del modo login, **no recuerda** quién subió qué. Consistente con el homelab sin MTA ([`./01-vaultwarden.md`](./01-vaultwarden.md) §0 punto 4). Cada operación es atómica y olvidable: subir, procesar, descargar, cerrar pestaña. Esto es **una feature, no un bug**: el operador no quiere que el homelab acumule logs de "qué PDFs procesé el martes pasado" sobre datos sensibles.
12. **Sin backup explícito (porque no hay nada que respaldar).** Coherente con §0 punto 5: el `.env` se anota en KeePassXC + Vaultwarden y se reproduce desde el `.env.example` versionado en git. La imagen Docker es reproducible (tag pinned). El estado en disco es **cero** ficheros del servicio. Stirling-PDF **no añade entradas** ni a `sqlite_databases:`, ni a `postgresql_databases:`, ni a `source_directories:` de Borgmatic ([`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md)). El doc explicita esto en §9 para evitar la inercia de "todo servicio del homelab tiene su línea de Borgmatic" — Stirling-PDF es la excepción declarada.

> **Alcance de red**: la UI de Stirling-PDF **no** publica puertos al host. Se accede únicamente vía `https://stirling-pdf.${LAN_DOMAIN}` (Caddy + CA interna + Authelia delante con 2FA) y, una vez completada la fase Tailscale, vía `https://stirling-pdf.${TS_DOMAIN}`. El homelab opera en LAN + Tailscale, sin exposición a internet, sin Let's Encrypt público, sin port forwarding.

> **Alcance de auth**: una sola capa, **Authelia** ([`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md)). 2FA obligatorio para `group:admin`. Stirling-PDF interno corre **sin** login (`SECURITY_ENABLELOGIN=false`); cualquier petición que llegue al backend ya pasó por Authelia. Fail2ban ([`../04-seguridad/02-fail2ban.md`](../04-seguridad/02-fail2ban.md)) cubre intentos de fuerza bruta vía los logs de Caddy y los logs de Authelia (no hay jail dedicado para Stirling-PDF — el frente lo hace Authelia).

---

## Requisitos Previos

- **Sistema base operativo** según Fase 1: usuario `homelab` (UID 1000), `/mnt/hd2t/` montado, directorio `/mnt/hd2t/services/stirling-pdf/` ya creado por el bootstrap de [`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) §4.1 (loop "Fase 11 — Productividad", línea 241: `for svc in vaultwarden bookstack linkding paperless-ngx mealie stirling-pdf freshrss`).
- **Docker + red `homelab`** según Fase 2: red bridge `homelab` creada (`172.20.0.0/24`, `external: true`), convenciones de Compose ([`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §3 y §5).
- **Caddy desplegado** ([`../03-red/04-caddy.md`](../03-red/04-caddy.md)) con `lan_internal_tls`, `security_headers` y `authelia_proxy` operativos.
- **CA interna de Caddy** instalada en al menos un dispositivo del operador (navegador). Procedimiento §6.5 de Caddy. Sin la CA confiada, el navegador rechaza la conexión a `stirling-pdf.lan`.
- **Pi-hole desplegado** ([`../03-red/02-pihole.md`](../03-red/02-pihole.md)) con la posibilidad de añadir un registro DNS local: `stirling-pdf.${LAN_DOMAIN}` → IP del host donde escucha Caddy.
- **Authelia desplegado y operativo** ([`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md)) con `forward_auth` configurado y al menos un usuario en el `group:admin` con TOTP enrolado. Este doc **añade** una entrada nueva a `access_control.rules` (§6.1.2): `stirling-pdf.${LAN_DOMAIN}` con `policy: two_factor`.
- **Watchtower desplegado** ([`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md)). Stirling-PDF **no** lleva la etiqueta `com.centurylinklabs.watchtower.enable: "false"` (justificado en §0 punto 7 y consistente con Watchtower §4.2 línea 466, lista de servicios `enable: "true"`).
- **Fail2ban desplegado** ([`../04-seguridad/02-fail2ban.md`](../04-seguridad/02-fail2ban.md)) con los jails `caddy-status` y `authelia` ya activos. Cualquier intento de fuerza bruta hacia `stirling-pdf.lan` queda cubierto por el jail de Authelia.
- **`ufw` activo** según [`../01-sistema/03-seguridad-base.md`](../01-sistema/03-seguridad-base.md). No se añaden reglas: Stirling-PDF no publica puertos al host; el tráfico entra por Caddy.
- **Vaultwarden desplegado** ([`./01-vaultwarden.md`](./01-vaultwarden.md)). No es bloqueante (no hay credenciales propias del servicio que custodiar más allá del `.env`), pero la convención del homelab es que Vaultwarden ya esté arriba en la Fase 11.
- **Espacio libre en `hd2t`** ≥ 100 KB es **suficiente** (literalmente). El servicio no persiste nada salvo el `.env` (~2 KB). Lo que sí come espacio es la imagen Docker en la microSD: ~2.4 GB para la variante full (no `hd2t`, sino `/var/lib/docker/`). Verificar con `df -h /var/lib/docker` antes de hacer pull.
- **RAM disponible** ≥ 1 GB libre. Stirling-PDF en idle consume ~400-700 MB; durante OCR de un PDF mediano, picos hasta 1.5-2 GB. La Pi 5 (8 GB) tiene margen aunque coexista con todos los servicios del homelab. Si ya hay presión de RAM, cambiar a la variante `ultra-lite` (§12.5).
- **Comprobaciones rápidas**:
  ```bash
  # Red homelab existe:
  docker network inspect homelab --format '{{(index .IPAM.Config 0).Subnet}}'
  # Esperado: 172.20.0.0/24

  # Caddy está sano:
  docker inspect caddy --format '{{.Name}}: {{.State.Health.Status}}'
  # Esperado: caddy: healthy

  # Authelia está sano:
  docker inspect authelia --format '{{.Name}}: {{.State.Health.Status}}'
  # Esperado: authelia: healthy

  # Path base existe y es del usuario homelab:
  stat -c '%U:%G %a %n' /mnt/hd2t/services/stirling-pdf
  # Esperado: homelab:homelab 750 /mnt/hd2t/services/stirling-pdf

  # Espacio en /var/lib/docker (donde aterriza la imagen):
  df -h /var/lib/docker | tail -1
  # Esperado: ≥ 5 GB libres.

  # Memoria libre:
  free -h | awk '/^Mem:/ {print $7}'
  # Esperado: ≥ 1 GB available.
  ```

### Decisiones de diseño asumidas

| # | Decisión | Justificación breve | Variante en §12 |
|---|---|---|---|
| 1 | Imagen `docker.stirlingpdf.com/stirlingtools/stirling-pdf:<version>` | Upstream oficial canónica, sin rate-limit. Justificada en §0 punto 2. | — |
| 2 | Variante **full** (no `ultra-lite`) | Incluye OCR + LibreOffice + Python — las tools que justifican el servicio. Justificada en §0 punto 3. | §12.5 (`ultra-lite`) |
| 3 | Tag pinned a release puntual | Misma regla del homelab. Watchtower habilitado actualiza a la siguiente release puntual cuando aparece. | — |
| 4 | Política de Watchtower **`enable: "true"`** | Stateless → rollback trivial. Justificado en §0 punto 7. | — |
| 5 | Arquitectura `linux/arm64` (Pi 5) | Manifest multi-arch oficial. | — |
| 6 | Redes Docker **`homelab`** (bridge externa) | Una sola red. No hay BD ni sidecar. | — |
| 7 | Modelo de almacenamiento **stateless** | Sin volúmenes persistentes. Justificado en §0 punto 5. | §12.6 (tessdata persistente), §12.7 (pipeline persistente) |
| 8 | `/tmp` montado como **`tmpfs` 512 MB** | Protege la microSD del I/O de PDFs efímeros. Justificado en §0 punto 6. | §12.2 (tmp en hd2t) |
| 9 | Reverse proxy **Caddy** con `lan_internal_tls` + `security_headers` + `authelia_proxy` | Stirling-PDF es UI-only, sin clientes API. Authelia delante. Justificado en §0 punto 4. | §12.4 (sin Authelia, login nativo) |
| 10 | Hostname interno **`stirling-pdf`** (`container_name`) | Caddy llama `http://stirling-pdf:8080`. | — |
| 11 | Puerto interno **`8080`** (default Spring Boot) | Tomcat embebido escucha en 8080. **No** se publica al host. | — |
| 12 | Subdominio LAN **`stirling-pdf.${LAN_DOMAIN}`** (típicamente `stirling-pdf.lan`) | Convención del homelab. Subdominio dedicado. Hyphen para no confundir con `stirling.lan` que un día podría ser otro servicio (`stirling-engine`, etc.). | — |
| 13 | Subdominio Tailscale **`stirling-pdf.${TS_DOMAIN}`** (preparado, descomentar tras [`../03-red/05-tailscale.md`](../03-red/05-tailscale.md)) | Mismo patrón que el resto del homelab. | — |
| 14 | UID/GID del proceso **`1000:1000`** vía `user:` | Sin bind mount, sin necesidad de `PUID/PGID` reconciliable. Justificado en §0 punto 8. | §12.6 (PUID/PGID si se monta tessdata) |
| 15 | `DOCKER_ENABLE_SECURITY=false` (build-time, ya en la imagen) y `SECURITY_ENABLELOGIN=false` (runtime) | La auth la lleva Authelia, no la app. Justificado en §0 punto 9. | §12.4 |
| 16 | `METRICS_ENABLED=false` | Uso intermitente; las métricas son ruido. Uptime Kuma cubre lo necesario. Justificado en §0 punto 10. | §12.3 |
| 17 | `LANGS=es_ES,en_US` (UI multilingüe) | UI en español (operador) con fallback inglés. Las traineddata de Tesseract para OCR no se controlan aquí (van en `/usr/share/tessdata`, ver §12.6). | — |
| 18 | `SYSTEM_DEFAULTLOCALE=es-ES` | Locale del sistema interno (formato de fechas, separadores numéricos). | — |
| 19 | `UI_APP_NAME=Stirling-PDF (homelab)` | Branding del header. Diferencia visual frente a una instancia pública. | — |
| 20 | Healthcheck `wget -qO- http://127.0.0.1:8080/api/v1/info/status` | Endpoint canónico Spring Actuator-like. Devuelve JSON con la versión. Sin auth (no hay auth interna). | — |
| 21 | `cap_drop: ALL` + `no-new-privileges` | Patrón estándar del homelab ([`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §6). Stirling-PDF no necesita capabilities. | — |
| 22 | Memory limit **`2g`**, CPU limit **`2.0`** | OCR puede picar 1.5-2 GB. 2g es el techo; 2 CPUs cubre el paralelismo de Tesseract sin monopolizar la Pi. | — |
| 23 | Stack name (Compose) **`stirling-pdf`** | Coherente con `~/homelab/stacks/stirling-pdf/`. Aparece como project name en `docker compose ls`. | — |

---

## 1. Resumen de la arquitectura

Resumen visual (la flecha indica la dirección del tráfico):

```
                 ┌──────────────────────────────────────────────────┐
                 │  Cliente (navegador del operador)                │
                 │  https://stirling-pdf.lan/  (ó .ts/ vía VPN)     │
                 └──────────────────────────────────────────────────┘
                                       │  HTTPS (TLS interno Caddy)
                                       ▼
                 ┌──────────────────────────────────────────────────┐
                 │  Caddy  (stack proxy, host)                      │
                 │  - lan_internal_tls + security_headers           │
                 │  - authelia_proxy (forward_auth → Authelia)      │
                 │  - reverse_proxy http://stirling-pdf:8080        │
                 │  - X-Forwarded-* automáticos                     │
                 └──────────────────────────────────────────────────┘
                          │                          ▲
                          │ forward_auth subrequest  │ 200 OK + Remote-User
                          ▼                          │
                 ┌──────────────────────────────────────────────────┐
                 │  Authelia  (stack auth)                          │
                 │  - 2FA obligatorio (group:admin)                 │
                 │  - cookie de sesión sobre *.${LAN_DOMAIN}        │
                 └──────────────────────────────────────────────────┘
                          │  HTTP plano (red Docker, ya autenticado)
                          ▼
   red Docker  ┌──────────────────────────────────────────────────┐
   `homelab`   │  stirling-pdf (stirling-pdf:<version>)           │
   (bridge)    │  - Spring Boot 3 (Tomcat embebido :8080)         │
               │  - LibreOffice headless (sidecar interno)        │
               │  - OCRmyPDF + Tesseract 5                        │
               │  - qpdf, Ghostscript, Poppler, ImageMagick       │
               │  - user 1000:1000 (sin PUID/PGID)                │
               │  - cap_drop: ALL, no-new-privileges              │
               └──────────────────────────────────────────────────┘
                          │                          │
                          ▼                          ▼
                 ┌────────────────┐     ┌────────────────────────┐
                 │  tmpfs 512 MB  │     │  Imagen Docker         │
                 │  /tmp          │     │  /var/lib/docker/...   │
                 │  (RAM, no HD)  │     │  (microSD del host)    │
                 │  - stirling-   │     │  - Solo lectura para   │
                 │    pdf-files/  │     │    el contenedor       │
                 └────────────────┘     └────────────────────────┘
```

Lo único que vive en disco persistente del homelab para este servicio:

```
                 ┌──────────────────────────────────────────────────┐
                 │  /mnt/hd2t/services/stirling-pdf/                │
                 │    ├── .env             (chmod 600 root:homelab) │
                 │    └── (nada más)                                │
                 └──────────────────────────────────────────────────┘
```

Ciclo de vida de un PDF (OCR de ejemplo):

```
1. El navegador del operador sube example.pdf (30 MB) por POST multipart.
2. Caddy → Authelia subrequest → cookie OK → forward_auth pasa.
3. Caddy → reverse_proxy → stirling-pdf:8080 (HTTP plano, body completo).
4. Spring Boot escribe /tmp/stirling-pdf-files/<uuid>/input.pdf  (tmpfs RAM).
5. OCRmyPDF (subprocess Python) lee input.pdf, llama a Tesseract por página
   (paralelo), produce /tmp/stirling-pdf-files/<uuid>/output.pdf.
6. Spring Boot devuelve output.pdf como descarga (Content-Disposition).
7. La sesión cierra el endpoint; un cron interno limpia /tmp tras N minutos.
8. Si el operador refresca la página o reinicia el contenedor: cero residuos.
```

> **El "cron interno" de limpieza** (`spring.cache.session.timeout`) borra ficheros temporales >30 min de antigüedad. En la práctica, con `tmpfs`, un reinicio del contenedor (`docker compose restart stirling-pdf`) limpia el 100% sin esperar al cron. Es deliberado: el homelab puede dejar el contenedor parado durante días sin generar acumulación.

---

## 2. Plan de variables y archivos

### 2.1. Variables del stack (`.env.example` versionable)

`~/homelab/stacks/stirling-pdf/.env.example`:

```dotenv
# ─── Imagen ─────────────────────────────────────────────────────────────────
# Variante "full" (incluye OCR + LibreOffice + Python). Para variante
# `ultra-lite` ver §12.5. La etiqueta debe ser una release puntual.
STIRLING_PDF_IMAGE=docker.stirlingpdf.com/stirlingtools/stirling-pdf:0.46.0

# ─── Identidad / TZ ─────────────────────────────────────────────────────────
TZ=Europe/Madrid

# ─── Dominios (deben coincidir con el bloque de Caddy) ─────────────────────
LAN_DOMAIN=lan
TS_DOMAIN=tail-XXXXX.ts.net

# ─── Stirling-PDF: idiomas y locale ────────────────────────────────────────
# UI: idiomas seleccionables en el desplegable de la esquina superior derecha.
# Coma-separados, formato locale (xx_XX). El primero es el default.
LANGS=es_ES,en_US

# Locale del sistema interno (formato fechas, separador decimal).
SYSTEM_DEFAULTLOCALE=es-ES

# ─── Stirling-PDF: branding ────────────────────────────────────────────────
UI_APP_NAME=Stirling-PDF (homelab)
UI_APP_NAVBAR_NAME=Stirling-PDF (homelab)
UI_HOME_DESCRIPTION=Suite PDF self-hosted del homelab. Sin telemetría. Sin terceros.

# ─── Stirling-PDF: seguridad ───────────────────────────────────────────────
# La auth la hace Authelia delante (ver §0 punto 9). El login nativo de la
# app se DESACTIVA. La imagen "full" oficial viene buildeada con
# DOCKER_ENABLE_SECURITY=false; este flag es informativo.
DOCKER_ENABLE_SECURITY=false
SECURITY_ENABLELOGIN=false

# ─── Stirling-PDF: features opcionales ─────────────────────────────────────
# Habilita tools que dependen de Calibre (PDF↔ebook) y operaciones HTML
# avanzadas. Coste: extra ~200 MB de RAM al arrancar. 'false' por defecto en
# el homelab; actívalo solo si vas a usar las herramientas de eBook.
INSTALL_BOOK_AND_ADVANCED_HTML_OPS=false

# Pipeline declarativa (variante avanzada, ver §12.7). Off por default.
SHOW_SURVEY=false

# ─── Stirling-PDF: métricas ────────────────────────────────────────────────
# Spring Boot Actuator (/actuator/prometheus). Off en el homelab por
# defecto (uso intermitente, ver §0 punto 10). Para activar: §12.3.
METRICS_ENABLED=false

# ─── Resource limits ───────────────────────────────────────────────────────
# OCR de un PDF mediano puede picar 1.5-2 GB de RAM. 2g es el techo cómodo.
STIRLING_PDF_MEMORY_LIMIT=2g
STIRLING_PDF_CPU_LIMIT=2.0

# Tamaño del tmpfs para /tmp (PDFs en proceso). 512m cubre PDFs hasta ~150 MB
# con OCR completo. Para PDFs gigantes ver §12.2.
STIRLING_PDF_TMPFS_SIZE=512m
```

> **No hay placeholders `__GENERATE_AND_REPLACE__`.** Stirling-PDF no genera secrets ni usuarios admin: la autenticación la lleva Authelia. El `.env` es 100% determinístico desde el `.env.example`. Esto simplifica §3 (no hace falta `openssl rand`).

### 2.2. `.env` real (`/mnt/hd2t/services/stirling-pdf/.env`)

El `.env` real es **una copia** del `.env.example` con los valores rellenos:

- `TS_DOMAIN`: el alias asignado por Tailscale (`tail-XXXXX.ts.net`) — el operador ya lo conoce de [`../03-red/05-tailscale.md`](../03-red/05-tailscale.md) §3 (preparación), aunque el bloque del Caddyfile siga comentado.
- `STIRLING_PDF_IMAGE`: tag puntual deseado (la versión `0.46.0` del template es un placeholder; el operador consulta [releases](https://github.com/Stirling-Tools/Stirling-PDF/releases) y elige la última estable antes de desplegar).
- `UI_APP_NAME` / `UI_HOME_DESCRIPTION`: branding al gusto del operador.
- Resto: valores por defecto del template.

`chmod 600 root:homelab` para que solo `root` y el usuario `homelab` puedan leerlo (Docker corre como root y consume el `env_file` antes del arranque del contenedor).

### 2.3. Cómo se inyectan al contenedor

El `docker-compose.yml` (§4) usa **dos** mecanismos:

1. **`env_file: /mnt/hd2t/services/stirling-pdf/.env`** — Compose carga el `.env` y todas las variables se exportan al entorno del contenedor automáticamente. La imagen oficial las lee al arrancar y las inyecta a Spring Boot vía `application.properties` generado por el entrypoint.
2. **`environment:`** — re-declara variables clave (`TZ`, `LANGS`, `UI_APP_NAME`, etc.) **explícitamente**, por dos motivos: (a) `docker compose config` muestra siempre la lista efectiva interpolada, útil para debugging; (b) el contrato del stack queda visible en el YAML sin abrir el `.env`.

---

## 3. Preparar el árbol de datos

### 3.1. Crear el directorio del stack

```bash
mkdir -p ~/homelab/stacks/stirling-pdf
cd ~/homelab/stacks/stirling-pdf
# Aquí vivirá: docker-compose.yml, .env.example, README.md.
# Versionable en git. NO commitear el .env real.
```

### 3.2. Verificar el árbol de datos del servicio (mínimo posible)

```bash
# El path /mnt/hd2t/services/stirling-pdf/ ya existe (creado por bootstrap §4.1
# de 01-sistema/04-estructura-directorios.md, loop "Fase 11 — Productividad",
# línea 241). Verificar:
ls -ld /mnt/hd2t/services/stirling-pdf
# Esperado: drwxr-x--- 2 homelab homelab ... stirling-pdf

# NO se crean subdirectorios: Stirling-PDF es stateless (§0 punto 5).
# El único fichero que vivirá ahí es el .env (§3.3).
```

> **A diferencia del resto de servicios de Fase 11 (Vaultwarden, Bookstack, Linkding, Paperless-ngx, Mealie, FreshRSS), Stirling-PDF NO crea**:
> - `data/` — no hay BD, no hay assets generados.
> - `secrets/` — no hay password admin (Authelia hace la auth).
> - `backups/` — no hay nada que respaldar (§9).
> - `configs/` — settings.yml se inyecta por env vars.
> - `customFiles/` — sin overrides de logo/CSS.
> - `tessdata/` — los traineddata Tesseract van baked-in en la imagen full.
>
> Esto es **deliberado** y consistente con el plan ([`../../plans/PLAN.md`](../../plans/PLAN.md) línea 144). Si en el futuro se necesita persistencia (multi-idioma OCR, pipeline, branding con logo custom), aplicar las variantes opt-in §12.6/§12.7/§12.8.

### 3.3. Materializar el `.env` real

```bash
# Copiar plantilla:
sudo install -m 600 -o root -g homelab \
  ~/homelab/stacks/stirling-pdf/.env.example \
  /mnt/hd2t/services/stirling-pdf/.env

# Editar valores específicos del homelab (TS_DOMAIN, posiblemente
# UI_APP_NAME y UI_HOME_DESCRIPTION al gusto del operador):
sudo $EDITOR /mnt/hd2t/services/stirling-pdf/.env

# Verificar:
sudo head -1 /mnt/hd2t/services/stirling-pdf/.env
# Esperado: línea con la imagen ya pinned a una versión real, no XXX.
```

### 3.4. Tabla resumen de permisos

| Path | Owner | Modo | Quién escribe | Quién lee |
|---|---|---|---|---|
| `/mnt/hd2t/services/stirling-pdf/` | `homelab:homelab` | `0750` | bootstrap (Fase 1) | operador, Compose (root) |
| `/mnt/hd2t/services/stirling-pdf/.env` | `root:homelab` | `0600` | operador (vía `sudo`) | Docker daemon (root) al arrancar el stack |
| `~/homelab/stacks/stirling-pdf/.env.example` | `homelab:homelab` | `0644` | operador | git (público) |
| `~/homelab/stacks/stirling-pdf/docker-compose.yml` | `homelab:homelab` | `0644` | operador | git (público), Compose |

Nada más. La simplicidad de la tabla es **el indicador** de que el servicio es genuinamente stateless.

### 3.5. Permisos para el proceso del contenedor

El proceso Java de Stirling-PDF arranca como **UID 1000** (forzado por `user:` en el Compose, §4). Como **no hay bind mounts** del servicio, no hay ownership en disco que reconciliar. El único filesystem en el que el proceso escribe es `/tmp` (tmpfs, dentro del namespace del contenedor) y los caminos efímeros en `/var/lib/docker/overlay2/...` (capa writable de la imagen) — ambos quedan dentro del propio contenedor y se reciclan al recrearlo.

Si en algún momento el operador habilita la variante `tessdata` (§12.6) — el único caso que añade un bind mount —, allí sí se reconcilia ownership con `chown 1000:1000` sobre el directorio en `hd2t`.

---

## 4. `docker-compose.yml`

`~/homelab/stacks/stirling-pdf/docker-compose.yml`:

```yaml
# ~/homelab/stacks/stirling-pdf/docker-compose.yml
# Stack: productivity (../02-docker/02-estructura-compose.md §1.1, fila
# 'productivity' línea 79). Stateless: sin volúmenes persistentes
# (PLAN.md línea 144). El único fichero en disco es el .env del stack
# en /mnt/hd2t/services/stirling-pdf/.env (chmod 600).

name: stirling-pdf

services:
  stirling-pdf:
    image: ${STIRLING_PDF_IMAGE}
    container_name: stirling-pdf
    hostname: stirling-pdf
    restart: unless-stopped

    # UID/GID del proceso. Sin PUID/PGID porque no hay bind mount cuyo
    # ownership reconciliar (§0 punto 8).
    user: "1000:1000"

    env_file:
      - /mnt/hd2t/services/stirling-pdf/.env
    environment:
      TZ: ${TZ}
      LANGS: ${LANGS}
      SYSTEM_DEFAULTLOCALE: ${SYSTEM_DEFAULTLOCALE}
      UI_APP_NAME: ${UI_APP_NAME}
      UI_APP_NAVBAR_NAME: ${UI_APP_NAVBAR_NAME}
      UI_HOME_DESCRIPTION: ${UI_HOME_DESCRIPTION}
      DOCKER_ENABLE_SECURITY: ${DOCKER_ENABLE_SECURITY}
      SECURITY_ENABLELOGIN: ${SECURITY_ENABLELOGIN}
      INSTALL_BOOK_AND_ADVANCED_HTML_OPS: ${INSTALL_BOOK_AND_ADVANCED_HTML_OPS}
      SHOW_SURVEY: ${SHOW_SURVEY}
      METRICS_ENABLED: ${METRICS_ENABLED}

    # NO hay volumes: bind mounts del servicio (stateless por diseño,
    # ver §0 punto 5 y §3.2). El único filesystem writable que necesita
    # el proceso es /tmp, que va a tmpfs (RAM):
    tmpfs:
      - /tmp:rw,nosuid,nodev,size=${STIRLING_PDF_TMPFS_SIZE}

    networks:
      - homelab

    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true

    # /api/v1/info/status devuelve JSON con la versión y status. Sin auth
    # (el contenedor interno corre sin SECURITY_ENABLELOGIN). 200 OK = sano.
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://127.0.0.1:8080/api/v1/info/status >/dev/null || exit 1"]
      interval: 60s
      timeout: 10s
      retries: 3
      # Spring Boot tarda ~30-60s en arrancar la primera vez (Java + carga
      # de módulos LibreOffice + warm-up de Tesseract). 90s deja margen.
      start_period: 90s

    deploy:
      resources:
        limits:
          memory: ${STIRLING_PDF_MEMORY_LIMIT}
          cpus: '${STIRLING_PDF_CPU_LIMIT}'

    # Watchtower habilitado por default (ver ../02-docker/04-watchtower.md
    # §4.2 línea 466 — Stirling-PDF está en la lista de servicios con
    # auto-update). NO se pone enable: "false" (justificado en §0 punto 7).

networks:
  homelab:
    external: true
```

### 4.1. Por qué cada bloque

| Línea | Por qué |
|---|---|
| `name: stirling-pdf` | Hace el `compose project name` explícito en lugar de inferirlo del directorio. Aparece en `docker compose ls`. |
| `image: ${STIRLING_PDF_IMAGE}` | Tag completo desde `.env` (registry canónico + variante full + versión puntual). Cualquier upgrade es grep-able y `git diff`-able. |
| `container_name: stirling-pdf` | DNS interno: Caddy llama `http://stirling-pdf:8080`. Sin `container_name` Compose le pondría `stirling-pdf-stirling-pdf-1`. |
| `hostname: stirling-pdf` | Alineado con `container_name`. Spring Boot imprime el hostname en logs; mantenerlos iguales evita confusión. |
| `restart: unless-stopped` | Auto-arranque tras reboot. `unless-stopped` (no `always`) permite parar manualmente para mantenimiento sin que Docker lo levante a la fuerza. |
| `user: "1000:1000"` | Justificado en §0 punto 8. Sin reconciliación PUID/PGID porque no hay bind mount. UID 1000 es el `homelab` user (consistencia con el resto del homelab). |
| `env_file:` | Path absoluto, fuera del repo. Justificado en [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §5.1. |
| `environment:` (re-declaración explícita) | Aunque `env_file` ya carga las vars, declararlas aquí **explícitamente** sirve de contrato: `docker compose config` muestra siempre la lista efectiva interpolada. |
| `tmpfs: /tmp:rw,nosuid,nodev,size=...` | Justificado en §0 punto 6. `nosuid,nodev` son defensas básicas (sin necesidad de SUID ni archivos de dispositivo dentro de `/tmp`). El `size` viene de `.env`. |
| **No** `volumes:` | Justificado en §0 punto 5. La ausencia es intencional y el comentario inline lo señala. |
| `networks: [homelab]` | Sin red interna lateral — Stirling-PDF no tiene BD ni sidecar. |
| `cap_drop: ALL` | Patrón estándar del homelab. Stirling-PDF no necesita ningún capability (Java en userland, sin raw sockets, sin bind a puertos privilegiados). |
| `security_opt: no-new-privileges:true` | Bloquea `setuid`/`setgid` dentro del contenedor. La imagen oficial no lo necesita; es defensa en profundidad. |
| `healthcheck: /api/v1/info/status` | Endpoint canónico de Stirling-PDF. Devuelve JSON `{"app":...,"version":...}`. Sin auth (no hay login interno). |
| `start_period: 90s` | Spring Boot + LibreOffice tardan ~30-60s en arrancar; 90s deja margen para no marcar `unhealthy` falso, especialmente tras un upgrade que añada módulos nuevos. |
| `deploy.resources.limits` | 2 GB de RAM y 2.0 CPUs. Justificado en §0 punto 22. |
| Sin `labels: watchtower.enable: "false"` | Stirling-PDF **sí** está en el grupo de auto-update (justificado en §0 punto 7). El default global de Watchtower aplica. |
| `networks.homelab.external: true` | Convención §4.3 de estructura-compose. |

### 4.2. Validar antes de levantar

```bash
cd ~/homelab/stacks/stirling-pdf
docker compose --env-file /mnt/hd2t/services/stirling-pdf/.env config
```

La salida debe mostrar:

- `image: docker.stirlingpdf.com/stirlingtools/stirling-pdf:0.46.0` (o la versión que el operador haya pinned),
- el bloque `environment` totalmente interpolado (sin `${...}`),
- `LANGS: es_ES,en_US`,
- `UI_APP_NAME: 'Stirling-PDF (homelab)'`,
- `tmpfs: ['/tmp:rw,nosuid,nodev,size=512m']` (o el tamaño elegido),
- `user: '1000:1000'`,
- `networks: homelab` con `external: true`,
- ningún `ports:` publicado (no habrá línea `ports:`),
- ningún `volumes:` declarado (no debe aparecer la sección).

Si alguna variable aparece como `${...}` literal, falta `--env-file`. Si aparece la sección `volumes:` con algún path, el operador ha modificado el Compose por error — volver a §4 al texto canónico.

---

## 5. Despliegue

### 5.1. Levantar el stack

```bash
cd ~/homelab/stacks/stirling-pdf
docker compose --env-file /mnt/hd2t/services/stirling-pdf/.env up -d
```

El primer `pull` descargará ~2.4 GB. En una conexión doméstica de 100 Mbps son ~3-4 minutos. En la microSD de la Pi 5, la descomprensión y commit añade ~1-2 minutos extra (Java + LibreOffice son muchas capas pequeñas).

Esperar ~90 s tras el `up -d` y verificar:

```bash
docker compose --env-file /mnt/hd2t/services/stirling-pdf/.env ps
# Esperado:
#   NAME           IMAGE                                                          STATUS
#   stirling-pdf   docker.stirlingpdf.com/stirlingtools/stirling-pdf:0.46.0       Up X seconds (health: starting)
```

### 5.2. Estado del contenedor

```bash
# Tras ~90 s, healthy:
docker inspect stirling-pdf --format '{{.State.Health.Status}}'
# Esperado: healthy

# Logs del primer arranque:
docker logs stirling-pdf 2>&1 | head -80
```

Líneas de interés en los logs (varían entre versiones):

```
  .   ____          _            __ _ _
 /\\ / ___'_ __ _ _(_)_ __  __ _ \ \ \ \
( ( )\___ | '_ | '_| | '_ \/ _` | \ \ \ \
 \\/  ___)| |_)| | | | | || (_| |  ) ) ) )
  '  |____| .__|_| |_|_| |_\__, | / / / /
 =========|_|==============|___/=/_/_/_/
 :: Spring Boot ::                (vX.X.X)

INFO ... Starting StirlingPdfApplication v<version> using Java 21 ...
INFO ... The following 1 profile is active: "default"
INFO ... Tomcat initialized with port 8080 (http)
INFO ... Tesseract version: 5.x.x detected
INFO ... LibreOffice version: 7.x.x detected
INFO ... Started StirlingPdfApplication in 47.23 seconds (process running for 49.81)
```

> **Si en los logs aparece `WARN ... LibreOffice not found`** o `Tesseract not found`: el operador ha usado por accidente la variante `<version>-ultra-lite` en lugar de `<version>` full. Verificar con `docker inspect stirling-pdf --format '{{.Config.Image}}'` y, si procede, parar el stack, corregir `STIRLING_PDF_IMAGE` en el `.env` y volver a levantar.

### 5.3. Verificar que NO hay ficheros físicos del servicio

```bash
sudo ls -la /mnt/hd2t/services/stirling-pdf/
# Esperado:
#   drwxr-x---  ... homelab homelab ...  .
#   drwxr-x---  ... homelab homelab ...  ..
#   -rw-------  ... root    homelab ...  .env
# (y NADA más)

# Confirmación de tamaño:
sudo du -sh /mnt/hd2t/services/stirling-pdf/
# Esperado: ≤ 8 KB (solo el .env).
```

> **Si ves cualquier directorio adicional** (`data/`, `configs/`, `customFiles/`, `logs/`, `tessdata/`): el Compose ha sido modificado y se han añadido bind mounts. Volver al `docker-compose.yml` canónico (§4) o documentar la desviación como variante opt-in.

### 5.4. Smoke check antes de publicar por Caddy

```bash
# Health endpoint accesible desde la red Docker:
docker exec caddy wget -qO- http://stirling-pdf:8080/api/v1/info/status
# Esperado: JSON con {"app":"Stirling-PDF","version":"0.46.0", ...}

# Página principal HTML:
docker exec caddy wget -qO- http://stirling-pdf:8080/ | head -20
# Esperado: <!DOCTYPE html>...<title>Stirling-PDF (homelab)</title>...

# La app responde con HTML válido (status 200):
docker exec caddy wget -S -qO /dev/null http://stirling-pdf:8080/ 2>&1 \
  | grep 'HTTP/'
# Esperado: HTTP/1.1 200 OK

# Confirmar que NO hay login nativo (Stirling-PDF responde directamente,
# sin redirigir a /login):
docker exec caddy wget -S -qO /dev/null http://stirling-pdf:8080/login 2>&1 \
  | grep 'HTTP/'
# Esperado: HTTP/1.1 404 Not Found  (no existe la ruta porque
# SECURITY_ENABLELOGIN=false).
```

### 5.5. (Sin) backup inicial

Coherente con §0 punto 12: el servicio es stateless y **no tiene** backup. Tras §5.4 el despliegue está completo a nivel de contenedor; el siguiente paso es exponerlo por Caddy con Authelia delante (§6).

> **Lo que sí se versiona en git** desde el primer momento:
> - `~/homelab/stacks/stirling-pdf/docker-compose.yml`
> - `~/homelab/stacks/stirling-pdf/.env.example`
>
> Eso es **todo** lo necesario para reconstruir el servicio en un homelab vacío.

---

## 6. Integración con Caddy y Authelia

### 6.1. Añadir el bloque `stirling-pdf.{$LAN_DOMAIN}` al `Caddyfile`

#### 6.1.1. Bloque Caddy

Editar `~/homelab/stacks/proxy/Caddyfile` y añadir (después de los bloques ya existentes, antes del `# Tailscale` comentado):

```caddy
# Stirling-PDF (../11-productividad/06-stirling-pdf.md)
stirling-pdf.{$LAN_DOMAIN} {
    import lan_internal_tls
    import security_headers
    import authelia_proxy
    reverse_proxy http://stirling-pdf:8080 {
        # Stirling-PDF acepta uploads grandes (PDFs); Caddy buffering
        # con timeouts laxos para no cortar OCR de PDFs largos.
        transport http {
            read_timeout 300s
            write_timeout 300s
        }
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-Proto {scheme}
        header_up X-Forwarded-For {remote_host}
        header_up Host {host}
    }
    # Subida máxima ~200 MB (PDFs típicos del homelab).
    request_body {
        max_size 200MB
    }
}
```

| Línea | Por qué |
|---|---|
| `import lan_internal_tls` | TLS con CA interna ([`../03-red/04-caddy.md`](../03-red/04-caddy.md) §4.2). |
| `import security_headers` | HSTS + X-Frame-Options + X-Content-Type-Options + Referrer-Policy. Stirling-PDF sirve sus propias páginas en HTML; ningún iframe externo legítimo. |
| `import authelia_proxy` | `forward_auth` hacia Authelia ([`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md) §10.5 de Caddy). Justificado en §0 punto 4. |
| `reverse_proxy http://stirling-pdf:8080` | Caddy llega por la red `homelab` al contenedor `stirling-pdf`. HTTP plano dentro de Docker (Caddy ya hace TLS terminator hacia el navegador). |
| `transport.read_timeout/write_timeout 300s` | OCR de un PDF grande puede tardar 1-5 minutos. Defaults de Caddy (1-3 min) cortarían la conexión a mitad. 300 s cubre el percentil 95 sin bloquear indefinidamente. |
| `header_up Host {host}` | Stirling-PDF construye URLs absolutas (descargas, redirects post-OCR) usando el `Host:`. Forzarlo evita que Caddy lo reescriba. |
| `request_body max_size 200MB` | Default de Caddy es 10 MB, demasiado restrictivo para PDFs de la administración (escaneos de 80-150 MB son comunes). 200 MB cubre el percentil 99 sin abrir abuse. |

#### 6.1.2. Añadir la regla a `access_control.rules` de Authelia

Editar `/mnt/hd2t/services/authelia/configuration.yml` y añadir `stirling-pdf.{{ env "LAN_DOMAIN" }}` al bloque de servicios `two_factor` (`access_control.rules`, sección 5 — **Servicios protegidos por 2FA**, alrededor de la línea 422 en el config de [`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md) §5):

```yaml
access_control:
  default_policy: deny
  rules:
    - domain: "auth.{{ env "LAN_DOMAIN" }}"
      policy: bypass

    - domain:
        - "portainer.{{ env "LAN_DOMAIN" }}"
        - "vault.{{ env "LAN_DOMAIN" }}"
        - "nextcloud.{{ env "LAN_DOMAIN" }}"
        - "sonarr.{{ env "LAN_DOMAIN" }}"
        - "radarr.{{ env "LAN_DOMAIN" }}"
        - "prowlarr.{{ env "LAN_DOMAIN" }}"
        - "transmission.{{ env "LAN_DOMAIN" }}"
        - "bookstack.{{ env "LAN_DOMAIN" }}"
        - "paperless.{{ env "LAN_DOMAIN" }}"
        - "stirling-pdf.{{ env "LAN_DOMAIN" }}"   # <— línea nueva
        - "homepage.{{ env "LAN_DOMAIN" }}"
        - "ha.{{ env "LAN_DOMAIN" }}"
      policy: two_factor
      subject:
        - "group:admin"
```

Validar la sintaxis YAML antes de recargar:

```bash
docker compose -f ~/homelab/stacks/authelia/docker-compose.yml \
  exec authelia authelia validate-config --config /config/configuration.yml
# Esperado: "Configuration parsed and loaded successfully without errors."
```

### 6.2. Recargar Caddy y Authelia

```bash
# Caddy:
cd ~/homelab/stacks/proxy
docker compose exec caddy caddy validate --config /etc/caddy/Caddyfile
# Esperado: "Valid configuration".

docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile
# Esperado: sin output (éxito).

# Authelia (recarga vía SIGHUP, sin reinicio del contenedor):
docker compose -f ~/homelab/stacks/authelia/docker-compose.yml \
  kill -s SIGHUP authelia
sleep 2
docker logs --tail 30 authelia 2>&1 | grep -iE 'reload|access.control'
# Esperado: línea con "configuration successfully reloaded" o similar.
```

Verificación en logs de Caddy:

```bash
docker logs --tail 50 caddy 2>&1 | grep -E 'stirling-pdf|reload'
# Esperado: la nueva ruta aparece y un log "reloaded successfully" o
# "certificate obtained successfully" para stirling-pdf.lan.
```

### 6.3. Registro DNS local en Pi-hole

En la UI de Pi-hole (`https://pihole.${LAN_DOMAIN}/admin`):
- **Local DNS Records** → **Add a new domain/IP combination**.
- Domain: `stirling-pdf.lan`
- IP: la IP del host donde escucha Caddy (`192.168.1.10` por convención del homelab; ver [`../03-red/02-pihole.md`](../03-red/02-pihole.md)).
- **Add**.

Validación:

```bash
dig +short @192.168.1.241 stirling-pdf.lan
# Esperado: 192.168.1.10  (la IP de Caddy/Pi).
```

### 6.4. Probar el acceso desde el navegador

Desde un cliente con la CA de Caddy ya instalada (§6.5 de Caddy) y con cookie de sesión Authelia ya válida:

```bash
# Health (NO pasa por Authelia porque /api/v1/info/status va a la app
# entera; Authelia bloquea CUALQUIER path sin cookie):
curl -sI --resolve stirling-pdf.lan:443:192.168.1.10 \
  https://stirling-pdf.lan/api/v1/info/status
# Esperado SIN cookie: HTTP/2 302  (redirige a auth.lan)
# Esperado CON cookie Authelia válida: HTTP/2 200 OK + body JSON
```

Desde el navegador: `https://stirling-pdf.lan` debería:

1. Redirigir a `https://auth.lan/?rd=https%3A%2F%2Fstirling-pdf.lan%2F` (Authelia login).
2. Tras login + 2FA TOTP, redirigir a `https://stirling-pdf.lan/`.
3. Mostrar la **home de Stirling-PDF** con el grid de tools (split, merge, OCR, compress…) y el branding del homelab (`Stirling-PDF (homelab)`).

Si aparece un warning de cert, el `root.crt` de Caddy no está instalado en el navegador — volver a [`../03-red/04-caddy.md`](../03-red/04-caddy.md) §6.5.

> **Sobre uptime monitoring (Uptime Kuma)**: como Authelia bloquea hasta `/api/v1/info/status`, una sonda HTTP plana sin cookie devuelve 302. El check correcto en Uptime Kuma es: HTTP keyword **"Found"** (texto del 302) en `https://stirling-pdf.lan/`. Eso confirma que **Caddy + Authelia + DNS** están operativos. Para un health más profundo (que el contenedor de stirling-pdf esté sano), Uptime Kuma puede checkear la red Docker directamente con `http://stirling-pdf:8080/api/v1/info/status` si el operador decide montar el contenedor de Uptime Kuma en la misma red `homelab` ([`../05-monitorizacion/05-uptime-kuma.md`](../05-monitorizacion/05-uptime-kuma.md)).

### 6.5. Acceso vía Tailscale (preparado, no activo)

Mismo patrón que el resto del homelab: cuando Tailscale esté desplegado ([`../03-red/05-tailscale.md`](../03-red/05-tailscale.md)) se añade un segundo bloque en el `Caddyfile`:

```caddy
# Stirling-PDF vía Tailscale (descomentar tras 03-red/05-tailscale.md).
# stirling-pdf.{$TS_DOMAIN} {
#     import tailscale_tls stirling-pdf
#     import security_headers
#     import authelia_proxy
#     reverse_proxy http://stirling-pdf:8080 {
#         transport http {
#             read_timeout 300s
#             write_timeout 300s
#         }
#         header_up X-Real-IP {remote_host}
#         header_up X-Forwarded-Proto {scheme}
#         header_up X-Forwarded-For {remote_host}
#         header_up Host {host}
#     }
#     request_body {
#         max_size 200MB
#     }
# }
```

Y se añade `stirling-pdf.{{ env "TS_DOMAIN" }}` al bloque correspondiente en `access_control.rules` de Authelia (cuando exista la regla para servicios `*.${TS_DOMAIN}`; ver [`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md) §0 punto 5 sobre cookie multi-domain). Hasta entonces, el acceso fuera de casa pasa por Tailscale al hostname `pi.${TS_DOMAIN}` y desde ahí a `stirling-pdf.lan` vía el resolver DNS local de Tailscale.

---

## 7. Configuración post-despliegue

### 7.1. Primer login y validación E2E del flujo Authelia → Stirling-PDF

1. Abrir `https://stirling-pdf.lan/` desde el navegador del operador (con la CA de Caddy instalada).
2. Authelia muestra su formulario de login: usuario + password + TOTP de 6 dígitos.
3. Tras `Authenticate`, redirección automática a la home de Stirling-PDF.
4. Validar visualmente:
   - Header con `Stirling-PDF (homelab)` (el `UI_APP_NAME` del `.env`).
   - Idioma de la UI: español (el primero de `LANGS=es_ES,en_US`).
   - Grid de tools agrupado en categorías (View & Edit, Convert, Page operations, Sign & Security, etc.).
5. **Cambio rápido de idioma**: esquina superior derecha → desplegable de idiomas → English. Si aparecen ambos `Español` y `English`, la variable `LANGS` se interpretó correctamente.

### 7.2. Probar una operación end-to-end (split de un PDF)

Smoke test funcional para confirmar que toda la cadena (auth + reverse proxy + body upload + procesado + descarga) funciona:

1. Tener a mano un PDF cualquiera de ≥ 3 páginas (cualquier PDF público sirve — un manual de usuario, un boletín oficial). El homelab puede tener uno en `/mnt/hd2t/nextcloud/...` o el operador puede coger uno de su Mac.
2. Stirling-PDF home → **Page operations** → **Split PDF**.
3. Drag&drop o **Select files** del PDF.
4. **Pages**: `1,2-3` (split en dos partes: página 1 sola + páginas 2 a 3).
5. **Submit** → tras unos segundos, el navegador descarga un ZIP con los dos PDFs separados.
6. Abrir el ZIP, verificar visualmente que los PDFs están bien.

Si el smoke test pasa, el servicio es operativo end-to-end. Esperar idealmente <30 s para un PDF pequeño (la latencia adicional en la primera operación se debe al warm-up de las JVMs internas de LibreOffice y Tesseract).

### 7.3. Probar OCR sobre un PDF escaneado

Test diferenciador (lo que justifica la variante full sobre `ultra-lite`):

1. Buscar un PDF escaneado (sin capa de texto): un boletín oficial, un manual antiguo, una factura escaneada propia.
2. **Other tools** → **Add OCR (Tesseract)**.
3. Seleccionar el fichero, idioma `Spanish` (o el del documento), modo `Skip text already on page`.
4. **Submit** → procesado puede tardar 30 s – 5 min según número de páginas.
5. El PDF descargado tiene capa de texto: comprobarlo abriendo en un visor PDF y haciendo `Ctrl+F` + buscar una palabra que aparezca en el documento — debe iluminarla.

> Si OCR falla con `Language 'spa' not found`: la imagen oficial **incluye** español en la traineddata baked-in (verificar con `docker exec stirling-pdf ls /usr/share/tessdata/ | grep spa`). Si efectivamente falta (variante distinta de la imagen, build personalizada), aplicar §12.6 para montar un `tessdata/` con `spa.traineddata` añadido manualmente.

### 7.4. Personalizar branding (opcional)

Para cambiar el nombre, la descripción de la home, o el logo:

- **Texto** (nombre + descripción): editar `UI_APP_NAME`, `UI_APP_NAVBAR_NAME`, `UI_HOME_DESCRIPTION` en `/mnt/hd2t/services/stirling-pdf/.env` y `docker compose up -d` (recreará el contenedor).
- **Logo / CSS**: requiere bind mount de `/customFiles/` — ver variante §12.8.

### 7.5. Verificación post-despliegue

- [ ] `https://stirling-pdf.lan` redirige a Authelia (formulario de login + TOTP).
- [ ] Tras autenticar, la home de Stirling-PDF carga con el branding del homelab.
- [ ] El idioma por defecto de la UI es español.
- [ ] El smoke test de **Split PDF** completa correctamente.
- [ ] El smoke test de **OCR** completa correctamente.
- [ ] No hay ficheros nuevos en `/mnt/hd2t/services/stirling-pdf/` (solo el `.env`).
- [ ] Logs limpios (sin `WARN ... not found` para LibreOffice/Tesseract).
- [ ] `docker stats stirling-pdf` muestra RAM en idle ~400-700 MB.

---

## 8. Verificación

### 8.1. Contenedor sano y permisos correctos

```bash
docker inspect stirling-pdf --format '{{.State.Health.Status}}'
# Esperado: healthy

docker inspect stirling-pdf --format '{{.State.StartedAt}}'
# Esperado: timestamp reciente.

# UID/GID del proceso interno:
docker inspect stirling-pdf --format '{{.Config.User}}'
# Esperado: 1000:1000

# Comprobar que el proceso Java efectivamente corre como UID 1000:
docker exec stirling-pdf ps -o user=,uid=,pid=,comm= 2>/dev/null | head -3
# Esperado: una línea con uid=1000 y comm=java (o similar).
```

### 8.2. Stirling-PDF no escucha al host

```bash
sudo ss -tlnp | grep ':8080'
# Esperado: vacío (el contenedor escucha en 8080 pero solo dentro de la red Docker).

# Confirmación: el puerto sí lo abre el proceso java DENTRO del contenedor:
docker exec stirling-pdf ss -tlnp 2>/dev/null | grep ':8080' || \
  docker exec stirling-pdf netstat -tlnp 2>/dev/null | grep ':8080'
# Esperado: 0.0.0.0:8080 LISTEN PID/java
```

### 8.3. tmpfs montado en /tmp

```bash
docker exec stirling-pdf mount | grep ' /tmp '
# Esperado:
#   tmpfs on /tmp type tmpfs (rw,nosuid,nodev,size=...)
```

Si en lugar de `tmpfs` aparece `overlay` u otra cosa, el `tmpfs:` del Compose no surtió efecto — revisar §4.

```bash
docker exec stirling-pdf df -h /tmp
# Esperado:
#   Filesystem      Size  Used Avail Use% Mounted on
#   tmpfs           512M   xx  xxxM  xx% /tmp
```

### 8.4. Statelessness del filesystem persistente

```bash
# Antes de procesar nada:
sudo find /mnt/hd2t/services/stirling-pdf/ -type f
# Esperado: una sola línea con el .env

# Procesar un PDF de prueba (ver §7.2) y volver a comprobar:
sudo find /mnt/hd2t/services/stirling-pdf/ -type f
# Esperado: aún una sola línea con el .env (el procesado vivió en tmpfs).
```

### 8.5. UI accesible vía Caddy + Authelia

```bash
# Sin cookie Authelia: 302 hacia auth.lan.
curl -sI --resolve stirling-pdf.lan:443:192.168.1.10 \
  https://stirling-pdf.lan/ \
  | head -5
# Esperado:
#   HTTP/2 302
#   location: https://auth.lan/?rd=...

# Con cookie Authelia válida (capturar la cookie tras login en navegador):
COOKIE='authelia_session=<la-cookie-completa>'
curl -sI --resolve stirling-pdf.lan:443:192.168.1.10 \
  -H "Cookie: $COOKIE" \
  https://stirling-pdf.lan/ \
  | head -5
# Esperado:
#   HTTP/2 200
#   content-type: text/html; ...
```

### 8.6. Health endpoint interno (sin Authelia)

```bash
# Desde dentro de la red Docker (saltando Authelia):
docker exec caddy wget -qO- http://stirling-pdf:8080/api/v1/info/status
# Esperado: JSON con app, version, ...
```

### 8.7. Persistencia tras reboot

```bash
# Reiniciar la Pi (o el contenedor):
docker compose -f ~/homelab/stacks/stirling-pdf/docker-compose.yml \
  --env-file /mnt/hd2t/services/stirling-pdf/.env restart

sleep 90
docker inspect stirling-pdf --format '{{.State.Health.Status}}'
# Esperado: healthy

# El servicio sigue funcionando idéntico (la UI y las tools no han
# cambiado porque NO HAY estado: el "antes" y el "después" son iguales).
```

### 8.8. Lista de verificación

- [ ] `docker inspect stirling-pdf --format '{{.State.Health.Status}}'` → `healthy`.
- [ ] No hay `ports:` publicados al host (ni 8080, ni similares).
- [ ] `/tmp` está montado como `tmpfs` con el tamaño esperado.
- [ ] `/mnt/hd2t/services/stirling-pdf/` solo contiene `.env`.
- [ ] La UI carga vía `https://stirling-pdf.lan` tras pasar por Authelia.
- [ ] Las tools básicas (split, merge) funcionan.
- [ ] La tool OCR funciona.
- [ ] El branding del homelab aparece en el header.

---

## 9. Backup

### 9.1. Qué se respalda y qué no

| Categoría | Path | ¿Se respalda? | Cómo |
|---|---|---|---|
| Base de datos | (no hay) | **N/A** | Stirling-PDF no usa BD. |
| Settings de la UI | (no hay fichero — todo por env vars) | **No** (reproducible desde `.env.example`) | Las variables están en `.env` y `.env.example`. El `.env.example` se versiona en git. |
| `.env` | `/mnt/hd2t/services/stirling-pdf/.env` | **No** (custodiado en KeePassXC + Vaultwarden + git como `.env.example`) | El `.env` real es 99% idéntico al template (sin secrets reales — la única var sensible podría ser `TS_DOMAIN` que se anota en KeePassXC junto con las credenciales Tailscale). |
| Imagen Docker | (en `/var/lib/docker/`) | **No** (reproducible desde el registry) | El tag pinned en `STIRLING_PDF_IMAGE` permite reconstruir exactamente la misma imagen. |
| `tmp/` durante procesado | tmpfs RAM | **No** (efímero por diseño) | La RAM se vacía al recrear el contenedor. Es la propiedad que justifica el uso de tmpfs. |
| Logs | stdout (driver `json-file` Docker) | **No** | Rotación gestionada por Docker (default config en `daemon.json`). Para retención larga, configurar un sink centralizado (Loki/Promtail en Fase 5+). |
| PDFs procesados | (no se persisten) | **N/A** | El operador descarga el resultado y se queda en su Mac/PC. El homelab no archiva. |

### 9.2. Patrón Borgmatic — ninguno

A diferencia del resto de servicios de Fase 11, **Stirling-PDF no aporta líneas a Borgmatic**:

- `sqlite_databases:` — vacío para Stirling-PDF.
- `postgresql_databases:` — vacío para Stirling-PDF.
- `source_directories:` — `/mnt/hd2t/services/stirling-pdf/` queda implícitamente cubierto por la regla genérica de `source_directories` que respalda `/mnt/hd2t/services/*` (si el operador la tiene activa); el resultado es que el `.env` sí se respalda como cualquier otro fichero del directorio. Sin acción específica.

> **Esta ausencia es intencional.** Si en algún momento se activa una variante (§12.6 con tessdata persistente, §12.7 con pipelines, §12.8 con customFiles), añadir el path correspondiente al `source_directories` de Borgmatic ([`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §6).

### 9.3. Restore (resumen)

Si el contenedor o la imagen se corrompen, "restaurar" Stirling-PDF es trivial porque no hay estado:

```bash
# 1. Parar el stack:
cd ~/homelab/stacks/stirling-pdf
docker compose --env-file /mnt/hd2t/services/stirling-pdf/.env down

# 2. (Opcional) Eliminar la imagen vieja para forzar pull limpio:
docker image rm $(grep ^STIRLING_PDF_IMAGE \
  /mnt/hd2t/services/stirling-pdf/.env | cut -d= -f2-)

# 3. Levantar de nuevo:
docker compose --env-file /mnt/hd2t/services/stirling-pdf/.env pull
docker compose --env-file /mnt/hd2t/services/stirling-pdf/.env up -d

# 4. Esperar healthy:
sleep 90
docker inspect stirling-pdf --format '{{.State.Health.Status}}'
# Esperado: healthy
```

Si se ha perdido **el host entero**, basta con: (a) reinstalar el OS según Fase 1; (b) clonar el repo de Compose en `~/homelab/`; (c) copiar el `.env.example` a `/mnt/hd2t/services/stirling-pdf/.env` (si los discos sobreviven, o regenerarlo desde KeePassXC/Vaultwarden); (d) `docker compose up -d`. Tiempo total: ~10 minutos descontando el `pull` de la imagen.

### 9.4. Smoke test mensual

Ya cubierto por el smoke check de upgrade (§10). No hay BD que verificar mensualmente.

---

## 10. Operaciones cotidianas

### 10.1. Upgrade (Watchtower habilitado)

Stirling-PDF está en el grupo de auto-update de Watchtower ([`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §4.2 línea 466). Watchtower hace `docker pull` cada noche a las 04:00 (la franja típica del homelab) y, si hay imagen nueva, hace `down` + `up -d` automáticamente. El servicio queda fuera ~90 s durante el ciclo.

Si el operador prefiere un ritmo manual, el procedimiento es:

```bash
# 1. Leer release notes:
# https://github.com/Stirling-Tools/Stirling-PDF/releases

# 2. (No hace falta backup — stateless.)

# 3. Actualizar el tag en el .env y .env.example:
sudo $EDITOR ~/homelab/stacks/stirling-pdf/.env.example  # actualizar y commit
sudo $EDITOR /mnt/hd2t/services/stirling-pdf/.env

# 4. Pull + up:
cd ~/homelab/stacks/stirling-pdf
docker compose --env-file /mnt/hd2t/services/stirling-pdf/.env pull
docker compose --env-file /mnt/hd2t/services/stirling-pdf/.env up -d

# 5. Verificar health:
sleep 90
docker logs --tail 50 stirling-pdf
docker inspect stirling-pdf --format '{{.State.Health.Status}}'
# Esperado: healthy

# 6. Smoke test UI: login + ver lista de tools + split de un PDF de prueba.
```

> **Rollback** (si el upgrade rompe algo):
> 1. Volver el tag al anterior en el `.env`.
> 2. `docker compose pull && docker compose up -d`.
> 3. Como no hay BD ni schema, el rollback es **siempre seguro** (no puede haber estado nuevo incompatible con la imagen vieja). Esta es la propiedad que justifica `enable: "true"` para Watchtower (§0 punto 7).

### 10.2. Cambiar idioma o branding

```bash
# Editar .env:
sudo $EDITOR /mnt/hd2t/services/stirling-pdf/.env
# Cambiar p.ej. UI_APP_NAME, LANGS, SYSTEM_DEFAULTLOCALE.

# Recrear el contenedor para que coja las nuevas vars:
cd ~/homelab/stacks/stirling-pdf
docker compose --env-file /mnt/hd2t/services/stirling-pdf/.env up -d
# (Compose detecta el cambio en env y recrea automáticamente.)

# Verificar:
sleep 90
curl -s --resolve stirling-pdf.lan:443:192.168.1.10 \
  -H "Cookie: <authelia_session=...>" \
  https://stirling-pdf.lan/ | grep -o '<title>[^<]*</title>'
# Esperado: el nuevo UI_APP_NAME en el title.
```

### 10.3. Forzar limpieza de `/tmp` (si la RAM va apretada)

Como `/tmp` es tmpfs, basta con reiniciar el contenedor:

```bash
docker compose -f ~/homelab/stacks/stirling-pdf/docker-compose.yml \
  --env-file /mnt/hd2t/services/stirling-pdf/.env restart
```

Esto libera la RAM ocupada por residuos de procesado en ~5 s. Caso típico: el operador procesa un PDF gigante, descarga el resultado, pero el cron interno tarda 30 min en limpiar; restart fuerza limpieza inmediata.

### 10.4. Cambiar el tamaño del tmpfs

```bash
# Editar STIRLING_PDF_TMPFS_SIZE en el .env:
sudo $EDITOR /mnt/hd2t/services/stirling-pdf/.env
# Por ejemplo: STIRLING_PDF_TMPFS_SIZE=1g

# Recrear (no basta con restart — los tmpfs args se aplican en create):
cd ~/homelab/stacks/stirling-pdf
docker compose --env-file /mnt/hd2t/services/stirling-pdf/.env up -d --force-recreate
```

### 10.5. Desactivar temporalmente

Operación cómoda (no destructiva, sin estado):

```bash
# Parar:
cd ~/homelab/stacks/stirling-pdf
docker compose --env-file /mnt/hd2t/services/stirling-pdf/.env stop

# Reactivar:
docker compose --env-file /mnt/hd2t/services/stirling-pdf/.env start
```

Mientras está parado, `https://stirling-pdf.lan` devuelve `502 Bad Gateway` desde Caddy. El operador puede prolongar la pausa indefinidamente sin riesgo (no hay BD que se quede inconsistente).

### 10.6. Logs y observabilidad

```bash
# Logs en vivo:
docker logs -f stirling-pdf

# Últimas 200 líneas:
docker logs --tail 200 stirling-pdf

# Filtrar errores:
docker logs stirling-pdf 2>&1 | grep -iE 'error|exception|fatal'

# Ver invocaciones de OCR (interesante para auditar uso):
docker logs stirling-pdf 2>&1 | grep -i 'ocrmypdf\|tesseract'

# Ver invocaciones de LibreOffice (conversiones office):
docker logs stirling-pdf 2>&1 | grep -i 'soffice\|libreoffice'
```

Stirling-PDF no tiene una "admin UI" propia: como no hay BD ni usuarios internos, todo lo gestionable está en el `.env`.

### 10.7. Eliminación completa del servicio

Si el operador decide retirar Stirling-PDF del homelab:

```bash
# 1. Parar y eliminar:
cd ~/homelab/stacks/stirling-pdf
docker compose --env-file /mnt/hd2t/services/stirling-pdf/.env down

# 2. Eliminar la imagen (libera ~2.4 GB en /var/lib/docker):
docker image rm $(grep ^STIRLING_PDF_IMAGE \
  /mnt/hd2t/services/stirling-pdf/.env | cut -d= -f2-)

# 3. Eliminar el .env y el directorio (vacíos sin él):
sudo rm /mnt/hd2t/services/stirling-pdf/.env
# (El directorio en sí lo deja el bootstrap; opcionalmente:
#  sudo rmdir /mnt/hd2t/services/stirling-pdf )

# 4. Eliminar del Caddyfile el bloque stirling-pdf.{$LAN_DOMAIN}.
# 5. Eliminar de access_control.rules de Authelia la línea stirling-pdf.{...}.
# 6. Recargar Caddy y Authelia (§6.2).
# 7. Eliminar el registro DNS local de Pi-hole.
# 8. Eliminar el dir del stack:
rm -rf ~/homelab/stacks/stirling-pdf  # (si ya no se va a versionar)
```

Nada más queda residual: ni BD huérfana, ni volumen Docker sin namespace, ni cron jobs colgados.

---

## 11. Solución de Problemas

| Síntoma | Causa probable | Solución |
|---|---|---|
| Tras `docker compose up -d`, el contenedor entra en `unhealthy` y los logs muestran `OutOfMemoryError: Java heap space` | La memoria límite (`STIRLING_PDF_MEMORY_LIMIT`) es demasiado baja para la JVM. | Aumentar `STIRLING_PDF_MEMORY_LIMIT=3g` y `up -d --force-recreate`. Si persiste con 3 GB, considerar la variante `ultra-lite` (§12.5). |
| Logs muestran `WARN ... LibreOffice not found` o tools de conversión a Word fallan con `500 Internal Server Error` | Variante `<version>-ultra-lite` por error en `STIRLING_PDF_IMAGE`. | Cambiar a la variante full (`<version>` sin sufijo) en el `.env`. |
| OCR falla con `Language 'spa' not found` o `'fra' not found` | La imagen no incluye esa traineddata. | Variante full incluye `eng`, `spa` y otras comunes baked-in. Si falta una específica, aplicar variante §12.6 (montar `/usr/share/tessdata` con `<lang>.traineddata` añadido manualmente). |
| Subir un PDF de >10 MB devuelve `413 Payload Too Large` | Falta `request_body max_size` en el bloque Caddy o Stirling-PDF lo rechaza. | Verificar que `request_body { max_size 200MB }` está en el bloque Caddy (§6.1). Si el límite hace falta más alto, ajustar también en Caddy (Stirling-PDF en sí no impone límite por encima de Spring Boot multipart, que es 10 MB por default — para subir >10 MB añadir al `.env`: `SPRING_SERVLET_MULTIPART_MAX_FILE_SIZE=200MB` y `SPRING_SERVLET_MULTIPART_MAX_REQUEST_SIZE=200MB`, recrear). |
| El navegador muestra "Connection timed out" durante OCR de un PDF largo (>5 min) | `transport.read_timeout` / `write_timeout` insuficiente en el bloque Caddy. | Subir a `600s` o `1200s` en el bloque Caddy. Reload Caddy (§6.2). |
| `502 Bad Gateway` desde Caddy | El contenedor `stirling-pdf` está parado, en `unhealthy`, o no está en la red `homelab`. | `docker inspect stirling-pdf --format '{{.State.Status}} {{json .NetworkSettings.Networks}}'`. Si la red no es `homelab`, releer §4 (`networks: [homelab]` con `external: true`). |
| Tras login en Authelia, redirección a `https://stirling-pdf.lan` y el navegador muestra "Connection refused" / "Stirling-PDF unreachable" | Pi-hole no resuelve `stirling-pdf.lan`. | UI de Pi-hole → "Local DNS Records" → añadir `stirling-pdf.lan → 192.168.1.10` (§6.3). |
| Tras `docker compose up -d --force-recreate`, el contenedor reinicia en bucle con `ERROR ... Permission denied: '/tmp/...'` | El `tmpfs` en `/tmp` se montó con permisos restrictivos y el UID 1000 no puede escribir. | Por default tmpfs hereda los permisos de `/tmp` original (1777, mundo-escribible). Si por alguna razón aparecen `0700` (Docker bug ocasional), añadir `mode=1777` al string del `tmpfs:` en el Compose: `tmpfs: ['/tmp:rw,nosuid,nodev,size=512m,mode=1777']`. |
| La UI carga pero el desplegable de idiomas solo muestra inglés | `LANGS` no se interpretó. | Verificar con `docker exec stirling-pdf env \| grep LANGS`. Si está vacío, releer §2 y recrear el contenedor. |
| Watchtower acaba de actualizar y Stirling-PDF entra en `unhealthy` | La nueva versión tarda más en arrancar o cambió el endpoint de healthcheck. | Esperar 2-3 minutos. Si persiste, `docker logs stirling-pdf` para ver los errores de Spring Boot. Si el endpoint `/api/v1/info/status` ya no existe en la nueva versión, actualizar el `healthcheck.test` del Compose con el endpoint canónico documentado en las release notes. |
| La home de Stirling-PDF muestra "Survey" pop-up al cargar | `SHOW_SURVEY=true` en el `.env`. | Cambiar a `SHOW_SURVEY=false` y recrear (§10.2). |
| Procesado de PDF deja la Pi a 100% CPU durante minutos | OCR multi-thread con `OMP_THREAD_LIMIT` no acotado. | Tesseract usa todos los cores por default. Si interfiere con otros servicios, añadir al `.env`: `OMP_THREAD_LIMIT=2` (limita a 2 threads de OpenMP). Recrear. |
| Authelia bloquea el acceso aun con cookie válida (`401 Unauthorized` en el subrequest) | El usuario operador no está en `group:admin`. | Verificar en `users_database.yml` de Authelia ([`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md) §4) que el operador tiene `groups: [admin]`. Si no, añadirlo y recargar Authelia. |

---

## 12. Variantes opt-in

### 12.1. Login nativo de Stirling-PDF (sin Authelia)

Si el operador prefiere no exponer Stirling-PDF detrás de Authelia (o si Authelia no está desplegado todavía y el servicio se quiere arrancar antes), Stirling-PDF puede activar su propio login (Spring Security + base de datos H2 embebida + bcrypt):

1. Cambiar la imagen a la variante con security pre-built. La imagen oficial estándar `stirling-pdf:<version>` viene buildeada con `DOCKER_ENABLE_SECURITY=false` para minimizar dependencias. Para activar login hay que **buildearse la imagen** con `--build-arg VERSION_TAG=...` y `--build-arg DOCKER_ENABLE_SECURITY=true`, o usar las imágenes alternativas de la comunidad que distribuyen el binario con security activado.
2. Variables en el `.env`:
   ```dotenv
   DOCKER_ENABLE_SECURITY=true
   SECURITY_ENABLELOGIN=true
   SECURITY_INITIALLOGIN_USERNAME=admin
   SECURITY_INITIALLOGIN_PASSWORD=__GENERATE_AND_REPLACE__
   ```
3. Esto añade un volumen necesario (`/configs`) para persistir la BD H2 con usuarios — **rompe el statelessness** y debe gestionarse como Linkding/Mealie con su `data/` y su entrada en `sqlite_databases:` de Borgmatic.
4. Eliminar `import authelia_proxy` del bloque Caddy (§6.1.1).
5. Eliminar la línea `stirling-pdf.{...}` de `access_control.rules` de Authelia (§6.1.2).

> **No es la variante por defecto del homelab** porque (a) duplica un mecanismo de auth que ya existe en Authelia con 2FA, (b) introduce una BD que hay que respaldar, (c) no añade seguridad sustancial sobre Authelia (es una capa más lateral, no en serie). Solo tiene sentido si Authelia está caído de forma permanente o si el operador quiere generar API tokens de Stirling-PDF para integraciones (raro).

### 12.2. `tmp/` en hd2t (PDFs gigantes)

Si el operador procesa habitualmente PDFs >150 MB con OCR (escaneos en color de tomos, libros antiguos enteros), la `tmpfs` de 512 MB se queda pequeña. Mover `/tmp` a `hd2t`:

1. Crear directorio en hd2t:
   ```bash
   sudo install -d -o 1000 -g 1000 -m 0700 /mnt/hd2t/services/stirling-pdf/tmp
   ```
2. En el Compose, sustituir el bloque `tmpfs:` por:
   ```yaml
   volumes:
     - /mnt/hd2t/services/stirling-pdf/tmp:/tmp:rw
   ```
3. Recrear: `docker compose up -d --force-recreate`.

> **Coste**: I/O sostenido a `hd2t` durante OCR (rotational, no SSD). Latencia mayor. Pero permite PDFs de 1-2 GB sin tocar la RAM. Importante: **el directorio sigue siendo efímero por convención** — el cron interno de Stirling-PDF limpia los archivos viejos. Sigue siendo "stateless" en el sentido funcional aunque haya bytes en `hd2t` durante minutos. **Sí** se puede excluir explícitamente del `source_directories` de Borgmatic con un patrón `! /mnt/hd2t/services/stirling-pdf/tmp/`.

### 12.3. Métricas Prometheus

Si el operador quiere graficar uso de Stirling-PDF (CPU, memoria, número de operaciones por tool):

1. En el `.env`:
   ```dotenv
   METRICS_ENABLED=true
   ```
2. Spring Boot Actuator expone `/actuator/prometheus` automáticamente. Pero **Authelia** lo bloquea. Solución: añadir un bypass de path en `access_control.rules`:
   ```yaml
   - domain: "stirling-pdf.{{ env "LAN_DOMAIN" }}"
     resources:
       - "^/actuator(/.*)?$"
     policy: bypass
   ```
   Esta regla debe ir **antes** de la regla general de `stirling-pdf` con `policy: two_factor`.
3. Añadir target a Prometheus ([`../05-monitorizacion/01-prometheus.md`](../05-monitorizacion/01-prometheus.md)):
   ```yaml
   - job_name: stirling-pdf
     static_configs:
       - targets: ['stirling-pdf:8080']
     metrics_path: /actuator/prometheus
   ```
4. Recargar Authelia, Prometheus, Caddy.
5. (Opcional) Importar dashboard genérico Spring Boot en Grafana ([`../05-monitorizacion/02-grafana.md`](../05-monitorizacion/02-grafana.md), p.ej. dashboard ID `4701` de Grafana.com).

> **Trade-off**: el endpoint queda accesible sin auth desde la LAN. Como no expone datos sensibles (solo contadores y gauges JVM), el riesgo es bajo, pero el operador asume que cualquier dispositivo de la LAN puede leer el throughput del servicio.

### 12.4. Custom CA / certificados internos en Stirling-PDF

Si el homelab tiene una CA interna además de la de Caddy (caso raro: alguna integración necesita Stirling-PDF llamando a otro servicio LAN con `https://`), Spring Boot necesita confiar en esa CA. Variante:

1. Crear `/mnt/hd2t/services/stirling-pdf/certs/ca.crt` con el certificado público.
2. Bind mount al contenedor:
   ```yaml
   volumes:
     - /mnt/hd2t/services/stirling-pdf/certs/ca.crt:/usr/local/share/ca-certificates/homelab.crt:ro
   ```
3. Añadir al `.env`:
   ```dotenv
   JAVA_TOOL_OPTIONS=-Djavax.net.ssl.trustStore=/etc/ssl/certs/java/cacerts
   ```
   (Spring Boot pickea las CAs en `/usr/local/share/ca-certificates/` automáticamente si el entrypoint las recompila en el truststore — algunas imágenes lo hacen, otras no.)
4. Recrear.

> **Caso de uso real raro** en el homelab actual. Documentado por completitud.

### 12.5. Variante `ultra-lite` (sin OCR ni LibreOffice)

Si la Pi 5 tiene presión de RAM (otros servicios pesados arrancando) y el operador acepta perder OCR + conversiones office a cambio de ~150 MB en lugar de ~700 MB de footprint:

1. En el `.env`:
   ```dotenv
   STIRLING_PDF_IMAGE=docker.stirlingpdf.com/stirlingtools/stirling-pdf:0.46.0-ultra-lite
   STIRLING_PDF_MEMORY_LIMIT=512m
   ```
2. Recrear: `docker compose pull && docker compose up -d`.
3. La UI desactiva las tools que dependen de OCR / LibreOffice — siguen apareciendo pero al pulsar muestran un mensaje "Tool unavailable in this build".

> **Cuándo usarlo**: Pi presionada de RAM o microSD pequeña. **Cuándo NO**: si OCR es la razón principal de tener Stirling-PDF (la mayoría de operadores). El homelab por defecto usa **full**.

### 12.6. Persistencia de `tessdata` para idiomas OCR adicionales

Por defecto la imagen full incluye `eng.traineddata`, `spa.traineddata` y unos cuantos más. Si el operador necesita más idiomas (catalán `cat`, francés `fra`, alemán `deu`, vasco `eus`, gallego `glg`, etc.):

1. Crear directorio:
   ```bash
   sudo install -d -o 1000 -g 1000 -m 0750 /mnt/hd2t/services/stirling-pdf/tessdata
   ```
2. Descargar traineddata desde [tessdata_fast](https://github.com/tesseract-ocr/tessdata_fast) (versión "fast" = balance precisión/velocidad — recomendada para Pi 5 ARM):
   ```bash
   cd /mnt/hd2t/services/stirling-pdf/tessdata
   for lang in cat fra deu eus glg; do
     sudo curl -fsSL -o "${lang}.traineddata" \
       "https://raw.githubusercontent.com/tesseract-ocr/tessdata_fast/main/${lang}.traineddata"
   done
   sudo chown -R 1000:1000 /mnt/hd2t/services/stirling-pdf/tessdata
   ```
3. Bind mount en el Compose:
   ```yaml
   volumes:
     - /mnt/hd2t/services/stirling-pdf/tessdata:/usr/share/tessdata:rw
   ```
   El `:rw` (no `:ro`) es necesario porque Stirling-PDF puede descargar idiomas adicionales bajo demanda (vía `INSTALL_OCR_LANGUAGES=cat,fra` si el operador prefiere automatizar).
4. Recrear.
5. **Romper statelessness por este path**: añadir `/mnt/hd2t/services/stirling-pdf/tessdata/` al `source_directories` de Borgmatic ([`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §6) — los traineddata pesan ~10-30 MB cada uno y son costosos de redescargar tras un disaster recovery.

### 12.7. Pipelines declarativas

Stirling-PDF soporta "pipelines": secuencias YAML de tools encadenadas (ej.: "split → OCR → compress → email"). Útil para automatizaciones repetidas (procesar siempre los escaneos de la administración con la misma cadena).

1. Crear `/mnt/hd2t/services/stirling-pdf/pipeline/`:
   ```bash
   sudo install -d -o 1000 -g 1000 -m 0750 /mnt/hd2t/services/stirling-pdf/pipeline
   ```
2. Bind mount:
   ```yaml
   volumes:
     - /mnt/hd2t/services/stirling-pdf/pipeline:/pipeline:rw
   ```
3. Definir pipelines vía la UI (**Pipeline Tools**) — Stirling-PDF persiste la definición YAML en `/pipeline`.
4. Añadir el path al `source_directories` de Borgmatic.

### 12.8. Branding personalizado (logo + CSS)

Para sustituir el logo de Stirling-PDF por uno propio del homelab, o aplicar CSS custom:

1. Crear `/mnt/hd2t/services/stirling-pdf/customFiles/static/`:
   ```bash
   sudo install -d -o 1000 -g 1000 -m 0750 \
     /mnt/hd2t/services/stirling-pdf/customFiles/static/images
   sudo install -d -o 1000 -g 1000 -m 0750 \
     /mnt/hd2t/services/stirling-pdf/customFiles/static/css
   ```
2. Colocar `images/logo.svg` y/o `css/custom.css`.
3. Bind mount:
   ```yaml
   volumes:
     - /mnt/hd2t/services/stirling-pdf/customFiles:/customFiles:ro
   ```
4. Recrear. Stirling-PDF aplica los overrides automáticamente al arrancar.
5. Añadir el path al `source_directories` de Borgmatic.

### 12.9. Acceso solo Tailscale (sin LAN)

Si el operador quiere que `stirling-pdf.lan` **no** funcione fuera de Tailscale:

1. **Eliminar** el bloque `stirling-pdf.{$LAN_DOMAIN}` del `Caddyfile`.
2. **Activar** solo el bloque `stirling-pdf.{$TS_DOMAIN}` (descomentar de §6.5).
3. **Eliminar** el registro DNS local `stirling-pdf.lan` de Pi-hole.
4. **Eliminar** la línea `stirling-pdf.{{ env "LAN_DOMAIN" }}` de `access_control.rules` de Authelia y, si aún no existe, añadir `stirling-pdf.{{ env "TS_DOMAIN" }}` a la regla equivalente para `*.${TS_DOMAIN}`.

Tras esto, el acceso solo funciona desde dispositivos en la tailnet.

---

## 13. Referencias

- [Stirling-PDF — repositorio oficial (GitHub)](https://github.com/Stirling-Tools/Stirling-PDF)
- [Stirling-PDF — releases (release notes para upgrades)](https://github.com/Stirling-Tools/Stirling-PDF/releases)
- [Stirling-PDF — README con variables de entorno y deployment](https://github.com/Stirling-Tools/Stirling-PDF/blob/main/README.md)
- [Stirling-PDF — registry canónico](https://docker.stirlingpdf.com/stirlingtools/stirling-pdf)
- [Stirling-PDF — Docker Hub mirror](https://hub.docker.com/r/stirlingtools/stirling-pdf)
- [Stirling-PDF — GHCR mirror](https://github.com/Stirling-Tools/Stirling-PDF/pkgs/container/stirling-pdf)
- [Tesseract — `tessdata_fast` (traineddata recomendada)](https://github.com/tesseract-ocr/tessdata_fast)
- [OCRmyPDF — documentación](https://ocrmypdf.readthedocs.io/)
- [Spring Boot Actuator — `/actuator/prometheus`](https://docs.spring.io/spring-boot/docs/current/reference/html/actuator.html#actuator.metrics.export.prometheus)
- Documentos relacionados del homelab:
  - [`./04-paperless-ngx.md`](./04-paperless-ngx.md) — Servicio "vecino": gestor de documentos con OCR; complementa a Stirling-PDF (Stirling-PDF es la herramienta puntual; Paperless es el archivo).
  - [`./03-linkding.md`](./03-linkding.md) — Patrón de servicio simple sin BD ni Authelia (contraste con Stirling-PDF, que sí lleva Authelia).
  - [`../03-red/04-caddy.md`](../03-red/04-caddy.md) — Reverse proxy y CA interna.
  - [`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md) — `forward_auth` y la regla `stirling-pdf.{{ env "LAN_DOMAIN" }}` en `access_control.rules`.
  - [`../04-seguridad/02-fail2ban.md`](../04-seguridad/02-fail2ban.md) — Jails de Caddy y Authelia que cubren intentos de fuerza bruta hacia Stirling-PDF.
  - [`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §4.2 (línea 466) — Stirling-PDF en el grupo de auto-update.
  - [`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) §4.1 (línea 241) — Bootstrap del directorio `/mnt/hd2t/services/stirling-pdf/`.
  - [`../../plans/PLAN.md`](../../plans/PLAN.md) (línea 144) — Definición original como "stateless, sin datos persistentes".
