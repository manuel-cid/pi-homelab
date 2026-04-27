# Stirling-PDF (caja de herramientas web todo-en-uno para PDFs)

## Descripción

Despliegue de **Stirling-PDF** como **navaja suiza local** para manipular ficheros PDF: dividir, fusionar, rotar, recortar, comprimir, convertir desde/hacia imágenes y Office, firmar, redactar, OCR sobre escaneados, eliminar metadatos, eliminar páginas, descifrar (cuando se conoce la contraseña), añadir _watermark_, comparar dos PDFs, extraer texto/imágenes, reorganizar páginas y un largo etcétera. **Sustituye** al ramillete de webs cloud (`ilovepdf.com`, `smallpdf.com`, `pdf24.org`, `pdfescape.com`) a las que el operador subía sus extractos bancarios, contratos firmados o nóminas para "una conversioncita rápida"; aquí, todos esos PDF (con sus datos personales, sensibles o profesionales) **no salen del homelab**. La promesa operativa: el operador entra a `https://stirling.lan/`, sube uno o varios PDFs, ejecuta una operación, descarga el resultado, y los ficheros temporales del servidor se borran tras la respuesta — Stirling-PDF es **completamente _stateless_**.

Este documento **continúa el _stack_ `productividad`** (`~/homelab/productividad/`) que estrenó `docs/11-productividad/01-vaultwarden.md`, amplió `docs/11-productividad/02-bookstack.md` (introduciendo la red privada `productividad-internal` y MariaDB), `docs/11-productividad/03-linkding.md`, `docs/11-productividad/04-paperless-ngx.md` y `docs/11-productividad/05-mealie.md`. **A diferencia de los cinco anteriores**, Stirling-PDF **no tiene base de datos, no tiene volúmenes con datos persistentes del usuario, no necesita _hook_ de Borgmatic, no se respalda y no necesita ampliar la red `productividad-internal`**. Aquí se materializa un único servicio:

- **`stirling-pdf`** — aplicación Spring Boot + Thymeleaf que orquesta una colección de utilidades nativas (Ghostscript, qpdf, OCRmyPDF, Tesseract, LibreOffice _headless_, ImageMagick, OpenCV) detrás de un frontend web. Imagen oficial multi-arch `docker.stirlingpdf.com/stirlingtools/stirling-pdf:1.0.2`. Una sola pieza: el binario Java sirve la web UI, las APIs REST por operación, y maneja los procesos hijos por _tool_ invocada. **Sin** persistencia: los ficheros que el usuario sube viven en `/tmp` del contenedor mientras dura la operación y se borran al terminar (o al reiniciar el contenedor). **Sin** sistema de cuentas activado (la autenticación nativa opcional de Stirling-PDF se mantiene **deshabilitada**: la protege Authelia con `forward_auth` desde Caddy, ver **Decisiones de diseño**).

Caddy (stack `red`, `docs/03-red/04-caddy.md`) expone Stirling-PDF en `https://stirling.lan/` con TLS interno (CA local). Para acceso remoto vía Tailscale (`docs/03-red/05-tailscale.md`), `https://pi.<tailnet>.ts.net/` con MagicDNS sirve la misma caja de herramientas al portátil del operador desde el café.

> **Alcance**: este documento despliega Stirling-PDF **sin autenticación nativa** (`DOCKER_ENABLE_SECURITY=false`), **sin base de datos H2** (la activaría el modo de seguridad), **con Authelia delante por `forward_auth`** (mismo middleware que ya protege Portainer, ver `docs/04-seguridad/01-authelia.md`), **con paquete completo de operaciones avanzadas** (`INSTALL_BOOK_AND_ADVANCED_HTML_OPS=true`, requerido para conversión a/desde HTML/EPUB y operaciones LibreOffice _heavy_), **con OCR multi-idioma** (`es+en+cat`, alineado con Paperless), **con un único bind mount** opcional `configs/` para personalizar branding y `pipeline/` para guardar _pipelines_ predefinidas. **No** activa `forward_auth` por _path_ específico (todo el dominio `stirling.lan` queda detrás de Authelia). **No** se incluye en Borgmatic (Categoría E, ya excluido en `~/homelab/backups/borgmatic/config.d/data.yaml` desde `docs/07-backups/02-borgmatic.md`).

> **Recordatorio de red**: Stirling-PDF **no se publica al host**. Caddy la alcanza por DNS interno de Docker (`stirling-pdf:8080` en la red `homelab`). No hay BD que aislar (no hay BD en absoluto), por lo que **no** hace falta ampliar `productividad-internal` (se queda con `bookstack`, `bookstack-db`, `paperless`, `paperless-db`, `paperless-redis`, `paperless-gotenberg`, `paperless-tika` dentro). Pi-hole resuelve `stirling.lan → 192.168.1.3` por el _wildcard_ de `02-homelab-local.conf` (ver `docs/03-red/02-pihole.md`).

---

## Requisitos previos

- `docs/02-docker/02-estructura-compose.md` completado: la tabla de stacks reserva el _slot_ `productividad`, la red Docker `homelab` (`br-homelab`, `172.20.10.0/24`) externa está creada, `~/homelab/.env` global con `TZ=Europe/Madrid`, `PUID=1000`, `PGID=1000`, `HOMELAB_DOMAIN=lan` está rellenado, y el _Makefile_ de operación expone `make up STACK=<stack>`.
- `docs/01-sistema/04-estructura-directorios.md` completado: `/mnt/hd2t/services/stirling-pdf/` ya existe vacío. En este documento se crean además `/mnt/hd2t/services/stirling-pdf/configs/` y `/mnt/hd2t/services/stirling-pdf/pipeline/` por _populate_ del bind mount.
- `docs/02-docker/04-watchtower.md` completado: la convención `com.centurylinklabs.watchtower.enable` está documentada. Stirling-PDF aparece en la lista de **opt-in** desde el principio (servicio _stateless_ puro, justificación en **Decisiones de diseño**).
- `docs/03-red/02-pihole.md` completado: Pi-hole resuelve `*.lan → 192.168.1.3`. **No hay que añadir nada** para `stirling.lan` — el _wildcard_ ya lo cubre.
- `docs/03-red/04-caddy.md` completado: Caddy escucha en `192.168.1.3:443` con `tls internal`, los _snippets_ `security-headers.caddy` y `logging.caddy` existen, y la directiva `import /etc/caddy/snippets/*.caddy` está activa en el `Caddyfile`. La CA local ya firma `*.lan`.
- `docs/04-seguridad/01-authelia.md` completado: Authelia escucha en `https://auth.lan/`, el _snippet_ `~/homelab/red/caddy/snippets/authelia.caddy` está poblado y operativo, y la regla `*.lan = one_factor` (o `two_factor` si así se decidió) está activa en el `access_control` de Authelia. Esto es **obligatorio** aquí: el bloque `stirling.lan` del `Caddyfile` lleva `import authelia`.
- `docs/07-backups/02-borgmatic.md` completado: el `exclude_patterns:` del `config.d/data.yaml` ya contiene `/mnt/hd2t/services/stirling-pdf` como ruta excluida (Categoría E). **No hay que tocar nada en Borgmatic** desde este documento.
- `docs/11-productividad/01-vaultwarden.md` completado: el _stack_ `productividad` ya existe con `~/homelab/productividad/{docker-compose.yml,.env,.env.example,.gitignore}`. **Este documento amplía** esos ficheros — no los crea desde cero.
- `docs/11-productividad/05-mealie.md` completado: el _stack_ `productividad` está vivo con diez servicios (Vaultwarden, Bookstack, Bookstack-db, Linkding, Paperless, Paperless-db, Paperless-redis, Paperless-gotenberg, Paperless-tika, Mealie) en `(healthy)`. **Este documento sólo añade un undécimo contenedor.**
- Conectividad saliente para descargar la imagen (sólo la primera vez):
  ```bash
  docker pull --platform linux/arm64 docker.stirlingpdf.com/stirlingtools/stirling-pdf:1.0.2 >/dev/null && echo OK
  ```
  > **Atención al tamaño**: la imagen Stirling-PDF "completa" (con `INSTALL_BOOK_AND_ADVANCED_HTML_OPS=true` activado en _runtime_) instala LibreOffice _headless_ y los _language packs_ de Tesseract en el primer arranque, lo que infla el directorio `/usr/lib/libreoffice` del contenedor a unos **2 GB**. La imagen base sin esa expansión ronda los **600-800 MB**. El primer arranque tarda **2-3 minutos** mientras descarga e instala dependencias _apt_ adicionales sobre la marcha (es comportamiento esperado).
- Que el host **no** tenga ya un servicio escuchando en `:8080` por error (`docker ps --format '{{.Names}} {{.Ports}}' | grep ':8080->' || echo OK`). Este _stack_ no publica puertos al host; Caddy es quien recibe el tráfico HTTPS.
- Espacio en `/mnt/hd2t`: Stirling-PDF es **prácticamente sin estado** sobre el bind mount: `configs/settings.yml` es un fichero <10 KB y `pipeline/` raramente supera unos pocos KB de JSON. **Pero la _imagen_ ocupa ~2 GB** en el _overlay store_ de Docker (`/var/lib/docker`, en la microSD si no se ha movido). Verificar holgura mínima en la SD:
  ```bash
  df -h /var/lib/docker
  # Debe quedar holgado. Si la SD anda apretada, considerar mover el daemon de Docker
  # a /mnt/hd2t/docker (procedimiento documentado en docs/02-docker/01-instalacion-docker.md
  # como "data-root opcional" si se siguió esa vía).
  ```

---

## Decisiones de diseño

### Por qué Stirling-PDF (y no PDF24 / Ghostscript a pelo / qpdf+pdftk / online tools / Apache PDFBox)

El homelab necesita **una caja de herramientas web** que cubra a la vez: dividir/fusionar, rotar, comprimir, OCR sobre escaneados, conversión desde/hacia imágenes y Office, firma simple, redacción (`black box`) sobre datos sensibles, eliminación de metadatos, _self-hosting_ ARM64 maduro, UI accesible desde el móvil y un _footprint_ razonable (es la undécima aplicación del homelab). Cuatro candidatos descartados y por qué:

| Candidato                      | Por qué se descarta                                                                                                                                                          |
|--------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **PDF24 self-hosted**          | PDF24 ofrece su _toolbox_ como _desktop app_ propietaria (Windows/Mac) y como servicio web cloud, pero **no** como contenedor _self-hosted_ oficial. Existen _wrappers_ comunitarios envolviendo el binario en un contenedor, pero sin soporte ARM64 estable y con la incomodidad de empaquetar software propietario uno mismo. Descartado por inmadurez del ecosistema _self-hosted_. |
| **Ghostscript / qpdf / pdftk a pelo** | Las herramientas CLI individuales son perfectas para automatizaciones (y de hecho **Stirling-PDF las usa por debajo**), pero la idea aquí es **una UI** para que el operador (y, si llega, alguien menos técnico de la familia) pueda manipular un PDF sin abrir un terminal. Las CLIs siguen disponibles dentro del propio contenedor `stirling-pdf` (en `/usr/bin/{gs,qpdf,ocrmypdf,pdftk}`) si en algún momento se necesitan. |
| **Servicios online (`ilovepdf`, `smallpdf`, ...)** | Funcionalmente excelentes y muy pulidos, pero exigen **enviar el PDF a sus servidores**. Para el caso de uso típico del operador (extractos bancarios, nóminas, contratos, facturas con NIF), eso rompe el principio del homelab — datos personales fuera del control del operador. Descartado por modelo de privacidad. |
| **Apache PDFBox / iText (Java) a pelo** | Librerías muy potentes pero sin UI. Construir la UI uno mismo sería re-implementar Stirling-PDF a peor. Descartado por pereza razonable. |
| **OCRmyPDF como servicio web (`ocrmypdf-web`)** | Excelente para OCR puro, pero **una sola operación**. El homelab quiere una caja de herramientas más amplia. OCRmyPDF ya está dentro de Paperless-ngx (`docs/11-productividad/04-paperless-ngx.md`) para los documentos archivados, y dentro de Stirling-PDF para los _ad-hoc_; no hace falta un tercer punto de presencia. |

Stirling-PDF gana por:

- **Stack mínimo viable**: un único contenedor sin BD, sin Redis, sin sidecar. Todas las dependencias nativas (Ghostscript, qpdf, Tesseract, LibreOffice, OCRmyPDF, ImageMagick, OpenCV) viven dentro de la imagen — no hay que orquestar nada.
- **Cobertura funcional amplia**: ~50 operaciones agrupadas en categorías (_Page Operations_, _Convert from/to PDF_, _Security_, _View & Edit_, _Advanced_, _Filter_). Cubre el 95% de lo que el operador hacía antes en webs cloud.
- **OCR multi-idioma**: Tesseract con _language packs_ instalables en _runtime_ vía la variable `LANGS`. Aquí se activan `es` (español), `en` (inglés) y `cat` (catalán), alineado con Paperless-ngx para coherencia.
- **API REST documentada**: cada operación de la UI tiene un endpoint REST equivalente bajo `/api/v1/...`, con OpenAPI en `https://stirling.lan/swagger-ui/index.html`. Útil para futuros _scripts_ caseros (n8n, automatizaciones de Home Assistant: "cuando llegue un email con un PDF adjunto, OCRízalo y mándamelo a Telegram"). **NB**: con Authelia delante, los endpoints REST también requieren cookie de sesión válida; ver **`forward_auth`**.
- **Soporte ARM64 oficial** vía `docker.stirlingpdf.com/stirlingtools/stirling-pdf` (multi-arch nativo). El proyecto migró de Docker Hub al registro propio (`docker.stirlingpdf.com`) en 2024 para evitar los rate-limits de Docker Hub. Mantenido por **Frooodle** (Anthony Stirling) y comunidad activa.
- **Sin lock-in**: no hay datos persistentes que migrar — el operador entra, manipula PDFs, sale. Si en el futuro se sustituye por otra cosa, basta con apagarlo.
- **Open source GPL-3.0**: a diferencia de PDF24 (propietaria) o servicios cloud (lock-in por definición), el código es auditable y modificable.

### Imagen y _tag_

- **`docker.stirlingpdf.com/stirlingtools/stirling-pdf:1.0.2`** — Stirling-PDF 1.0.x es la rama _stable_ "production" tras la migración de naming (la 0.x.x histórica fue _pre-1.0_; la rama 1.x.x estabilizó la API REST y empaquetó tags semver claros). Pinneada a _tag_ "major.minor.patch" semver siguiendo la convención del homelab (ver `docs/02-docker/02-estructura-compose.md`, sección **Imágenes**: nada de `:latest`). El upstream publica versiones cada 2-4 semanas; los _bumps_ de **patch** (1.0.2 → 1.0.3) traen bug fixes y son seguros (los gestiona Watchtower, ver más abajo). Los _bumps_ de **minor** (1.0.x → 1.1.0) traen funcionalidades nuevas y a veces cambian la estructura de `settings.yml`; se gestionan a mano leyendo el _changelog_.
- **No se usa el _tag_ `:latest`** — al ser una imagen muy grande (≥600 MB base) y con dependencias _runtime_ que pueden cambiar entre _bumps minor_, un `pull` de `:latest` que cruzase un _bump minor_ podría dejar la imagen anterior sin _quick rollback_ (y el `docker pull` de un _bump minor_ tarda largo en ARM64 sobre microSD). El _tag_ pinneado da control de cuándo actualizar.
- **Registro propio (`docker.stirlingpdf.com`)** y no Docker Hub: el upstream eligió mover el _hosting_ a Cloudflare R2 / Garage S3 propio para evitar los _pull rate limits_ anónimos de Docker Hub. Funcional y bien mantenido; **no requiere autenticación** para `pull` (lectura pública). Si en algún momento `docker.stirlingpdf.com` cae temporalmente, hay un mirror en `ghcr.io/stirling-tools/stirling-pdf` con los mismos tags.

#### Watchtower opt-in en este contenedor

Razones, mismo patrón que Linkding/Mealie pero **más fuerte aquí** porque Stirling-PDF es el ejemplo canónico de _stateless puro_:

- El servicio **no tiene estado del usuario**: no hay BD, no hay `mealie.db`, no hay `linkding.sqlite3`, no hay sesiones (Authelia las tiene). Una actualización fallida que dejase el contenedor `unhealthy` _no pierde nada_ del operador — basta con hacer rollback al _tag_ anterior y arrancar.
- Los _bumps patch_ del upstream son retrocompatibles por convención y nunca cambian la estructura del `settings.yml` (que es lo único que el operador podría haber tocado a mano).
- El downtime durante un `restart` post-pull es de ~30-90 s (Java + Spring Boot + carga de dependencias _runtime_): aceptable para una herramienta de uso esporádico que el operador abre cuando necesita manipular un PDF concreto.
- Si una actualización **rompiera** algo (improbable, pero posible — un cambio en la JVM base de la imagen, por ejemplo), el _healthcheck_ de `/api/v1/info/status` lo detecta inmediatamente y el operador se entera al primer intento de uso.

Etiquetar con `com.centurylinklabs.watchtower.enable: "true"`. Para _bumps minor_ (1.0 → 1.1), Watchtower **respeta el _tag_** del compose: no cruza de `:1.0.2` a `:1.1.0` solo porque exista un `:latest` distinto. Lo único que hace es _re-pull_ del mismo _tag_ por si hubo un _rebuild_ con un _digest_ nuevo. En la práctica, para _bumps minor_ habrá que editar `STIRLING_PDF_IMAGE_TAG` a mano.

> **Coherencia con `docs/02-docker/04-watchtower.md`**: ese documento ya lista a "Stirling-PDF" en la lista explícita de servicios **opt-in** desde el principio ("sin estado complejo o stateless puro"). No hace falta justificar nada extra aquí; sólo aplicar la etiqueta.

### Stateless puro (Categoría E del backup)

Stirling-PDF **no genera datos del usuario que sobrevivan al reinicio**:

- Los ficheros que el operador sube viven en `/tmp/stirling-pdf-files/<uuid>/` mientras dura la operación. La imagen los borra automáticamente tras servir la respuesta o al reiniciar el contenedor. El bind mount `/tmp` **no se hace** (queda dentro del _writable layer_ del contenedor, que se descarta en cada `docker rm`).
- **No hay BD** (la única opción de BD del proyecto, H2 embebida, sólo se activa con `DOCKER_ENABLE_SECURITY=true` para guardar usuarios, y aquí ese modo está desactivado).
- **No hay logs persistentes** del operador: los logs de Spring Boot van a `stdout` (los recoge el _logging driver_ de Docker, accesible vía `docker logs` y vía Dozzle, ver `docs/05-monitorizacion/06-dozzle.md`).
- El único contenido persistente es **opcional** y **regenerable**:
  - `/configs/settings.yml`: personalización de UI (nombre de la app, mensajes home), límites (`SYSTEM_MAXFILESIZE`), endpoints habilitados/deshabilitados. Si se pierde, el contenedor regenera el fichero con los valores por defecto al arrancar.
  - `/pipeline/`: _pipelines_ predefinidas (combinaciones guardadas de operaciones que el operador puede ejecutar en lote, p.ej. "Comprimir + OCR + Eliminar metadatos"). Si se pierde, el operador las re-crea desde la UI.
- **Ambos** son **regenerables sin esfuerzo significativo** (5-10 minutos de UI), por lo que Stirling-PDF entra de pleno en la **Categoría E** de la estrategia de backup (`docs/07-backups/01-estrategia-backup.md`).

> **Coherencia con `docs/07-backups/02-borgmatic.md`**: ese documento incluyó `/mnt/hd2t/services/stirling-pdf` en el `exclude_patterns:` del set "data". **No hay que tocar nada en Borgmatic** desde aquí. Tras un DR, Stirling-PDF se reconstruye con un simple `make up STACK=productividad` y, si el operador quiere recuperar su `settings.yml` personalizado, lo regenera desde la UI o desde git (si lo había commiteado por separado, ver **Configuración**).

> **Coherencia con `docs/07-backups/03-backup-docker-volumes.md`**: ese documento ya lista a "Stirling-PDF (Categoría E — ni siquiera se respalda)" como caso paradigmático del patrón. **No hay _hook_ de Borgmatic que activar aquí.**

### `forward_auth` con Authelia: **SÍ** para Stirling-PDF (caso especial dentro del stack)

Decisión **opuesta** a la de Vaultwarden, Bookstack, Linkding, Paperless y Mealie. Razones específicas para Stirling-PDF:

- **No hay autenticación nativa que valga la pena activar**: el modo `DOCKER_ENABLE_SECURITY=true` despliega una BD H2 embebida con usuarios locales gestionados desde `/login` y `/account`. Es **funcional pero menos sofisticado** que Authelia (no tiene 2FA TOTP propio bien integrado en la UI, no tiene SSO, no tiene _password reset_ por email integrado sin SMTP). Activarlo significaría duplicar el sistema de cuentas que ya gestiona Authelia y custodiar una BD adicional (que dejaría de ser _stateless_).
- **No hay API con _Bearer tokens_ de uso humano**: las APIs REST de Stirling-PDF (`/api/v1/...`) están pensadas para automatizaciones, pero en uso normal el operador interactúa **sólo desde el navegador**. No hay _bookmarklets_, no hay PWA con _share intent_, no hay extensiones de navegador que se rompan con un redirect HTML. Las pocas automatizaciones futuras (n8n, scripts) pueden manejar el _flow_ OAuth de Authelia o usar la cookie de sesión, ambas opciones son viables.
- **Es exactamente el escenario para el que existe `forward_auth`**: una _herramienta_ web sin _state_, sin auth nativa decente, expuesta sólo en LAN+Tailscale, que sólo el operador (o miembros autorizados de la familia) deben poder usar. Authelia delante es **la solución limpia**: sin dobles sistemas de cuentas, sin duplicar 2FA, con SSO transparente desde Vaultwarden/Bookstack/etc.
- **Ya hay precedente en el homelab**: el bloque `portainer.lan` lleva `import authelia` desde `docs/04-seguridad/01-authelia.md` ("Proteger el primer servicio: Portainer"). Stirling-PDF sigue ese mismo patrón al pie de la letra.

> **Resumen operativo**: el bloque `stirling.lan` del `Caddyfile` lleva `import security-headers`, `import logging` **e** `import authelia`. Caddy redirige al portal de Authelia cualquier petición sin sesión válida; tras autenticarse en `https://auth.lan/`, el operador ve la UI de Stirling-PDF sin volver a teclear credenciales (la cookie de sesión `lan` cubre todos los `*.lan`). Stirling-PDF arranca con `DOCKER_ENABLE_SECURITY=false` y **no muestra** ninguna pantalla de login propia.

> **Si en el futuro hicieran falta automatizaciones que llamen a la API REST sin pasar por Authelia**: el camino limpio es exponer Stirling-PDF en un _path_ específico (p.ej. `/api/`) **sin** el `import authelia`, y restringir IPs de origen mediante `@apiclients` (Caddy `remote_ip`). Documentado como apartado opcional al final.

### Memoria, JVM y consideraciones de la Pi 5

Stirling-PDF es **una aplicación Java**, lo que en una Pi 5 (8 GB) tiene matices:

- **Heap por defecto**: la JVM en la imagen usa el _ergonomics_ por defecto, que en un contenedor sin `-Xmx` explícito reserva el ~25% de la RAM **del cgroup**. Sin límite, un contenedor en una Pi 5 con 8 GB de RAM puede pedir hasta ~2 GB de heap, lo cual es excesivo para una herramienta de uso esporádico.
- **Política aplicada aquí**: limitar el contenedor a **1 GB de RAM** (`mem_limit: 1g`) y dejar que el _ergonomics_ de la JVM se ajuste al cgroup (~256 MB de heap inicial, expandible hasta ~768 MB). Suficiente para los casos de uso típicos del operador (PDFs <100 MB, OCR de hasta 30-50 páginas). Para PDFs muy grandes (un libro escaneado de 500 páginas), considerar subir temporalmente el límite a 2 GB.
- **CPU**: sin `cpus:` explícito (Stirling-PDF tiene picos de CPU durante OCR y conversiones LibreOffice, pero baja a casi cero en idle). La Pi 5 tiene 4 cores; un OCR sobre un PDF largo puede llegar a saturar 1-2 cores durante varios minutos. Para un homelab familiar con uso esporádico, no es necesario `cpus:` ni `cpu_quota:`.
- **Idle**: con `1g` de límite y _ergonomics_ por defecto, Stirling-PDF idle se queda en torno a **180-220 MB de RSS reales**. Aceptable.
- **Watchdog Java**: la JVM detecta el cgroup y respeta `mem_limit` desde Java 11+. Stirling-PDF usa Java 21 LTS (en la imagen base `eclipse-temurin:21-jre-alpine` o equivalente), así que la heuristica funciona bien y no hace falta forzar `-XX:MaxRAMPercentage`. Si en algún momento se observa que la JVM intenta heap > 75% del cgroup y peta con OOM, añadir `JAVA_OPTS=-XX:MaxRAMPercentage=70.0` al `environment:`.

### Bind mount mínimo para `configs/` y `pipeline/`

Aunque Stirling-PDF es _stateless_, **dos directorios pequeños** se exponen como bind mount para que sobrevivan a `docker rm`:

| Bind mount             | Volumen interno    | Tipo      | Por qué                                                                                                                                              |
|------------------------|---------------------|-----------|------------------------------------------------------------------------------------------------------------------------------------------------------|
| `configs/`             | `/configs`          | RW        | Contiene `settings.yml` (personalización UI, límites, endpoints habilitados). Si se borra, Stirling-PDF lo regenera con los _defaults_ al arrancar. |
| `pipeline/`            | `/pipeline`         | RW        | Contiene los _pipelines_ guardados por el operador (combinaciones de operaciones encadenadas). Si se borra, los _pipelines_ se pierden — pero son fáciles de recrear desde la UI. |
| `customFiles/`         | `/customFiles`      | RW (opt)  | Logos personalizados, plantillas. **No se monta aquí** — se documenta como opcional al final. |
| `logs/`                | `/logs`             | -         | **No se monta**. Los logs van a `stdout` y se ven con `docker logs` o Dozzle. Persistir logs no aporta nada en un servicio _stateless_. |

Ambos bind mounts viven en `/mnt/hd2t/services/stirling-pdf/{configs,pipeline}` aunque, por ser regenerables, podrían vivir igualmente en la microSD. Vivir en `hd2t` mantiene la coherencia "datos de servicios → hd2t", aunque **no entran en Borgmatic** (excluidos en el `exclude_patterns:`).

### `PUID`/`PGID` y permisos del bind mount

Stirling-PDF arranca como UID 0 (`root`) por defecto en la imagen oficial — el `entrypoint` no degrada privilegios sistemáticamente porque algunas operaciones (instalación _runtime_ de _language packs_ de Tesseract, instalación de LibreOffice _on-demand_) requieren `apt-get install` durante el primer arranque. Por compatibilidad con la convención de `PUID`/`PGID` del resto del _stack_, declaramos las variables en el `environment:` aunque la imagen las ignore: deja la puerta abierta a un futuro upstream que las soporte.

**Permisos del bind mount**:
```bash
sudo mkdir -p /mnt/hd2t/services/stirling-pdf/{configs,pipeline}
sudo chown -R root:root /mnt/hd2t/services/stirling-pdf/{configs,pipeline}
sudo chmod 0755 /mnt/hd2t/services/stirling-pdf/{configs,pipeline}
```

Stirling-PDF, al correr como `root` dentro del contenedor, no tiene problema de permisos sobre directorios `root:root`. **No replicar** aquí el patrón `chown 1000:1000` que se aplicó en otros servicios del _stack_ — sería incorrecto.

### Almacenamiento

Persistencia mínima sobre **hd2t**, todo en `/mnt/hd2t/services/stirling-pdf/`:

```
/mnt/hd2t/services/stirling-pdf/
├── configs/                       # ← se crea al primer arranque del contenedor
│   └── settings.yml               # personalización UI, límites, endpoints habilitados
└── pipeline/                      # ← se crea vacío
    └── *.json                     # pipelines guardados (uno por fichero, opcional)
```

Tamaño total típico: **<1 MB**. Crecimiento esperado a lo largo de los años: **<10 MB** (sólo crece si se acumulan muchos _pipelines_).

> **Excluido de Borgmatic** por estar en `exclude_patterns:` del set "data". **Versionar `settings.yml` en git si se han hecho personalizaciones manuales** (ver **Configuración**) — el repo `~/homelab/` puede tener una copia _de referencia_ del settings.yml en `~/homelab/productividad/stirling-pdf/settings.yml.example`, mantenido a mano por el operador.

---

## Estructura del _stack_ `productividad` tras este documento

Antes de este documento (tras `docs/11-productividad/05-mealie.md`):

```
~/homelab/productividad/
├── docker-compose.yml        # contiene vaultwarden + bookstack + bookstack-db + linkding +
│                             #          paperless + paperless-db + paperless-redis +
│                             #          paperless-gotenberg + paperless-tika + mealie
├── .env                      # APP vars de los diez
├── .env.example
└── .gitignore
```

Tras este documento:

```
~/homelab/productividad/
├── docker-compose.yml        # ← MODIFICADO: añade stirling-pdf
├── .env                      # ← MODIFICADO: añade STIRLING_PDF_*
├── .env.example              # ← MODIFICADO: añade plantilla STIRLING_PDF_*
├── .gitignore                # sin cambios
└── stirling-pdf/             # ← NUEVO (opcional)
    └── settings.yml.example  # copia de referencia (opcional, ver Configuración)
```

Y en el disco externo, sobre lo que ya creó `docs/01-sistema/04-estructura-directorios.md`:

```
/mnt/hd2t/services/stirling-pdf/
├── configs/                  # ← se crea al primer arranque del contenedor
│   └── settings.yml
└── pipeline/                 # ← se crea vacío
```

Ningún cambio en `~/homelab/productividad/.gitignore` (ya excluye `.env`). Ningún subdirectorio _stub_ que crear a mano: la imagen hace _populate_ del bind mount en el primer arranque.

> **Confirmar el árbol** antes de seguir:
> ```bash
> ls -la /mnt/hd2t/services/stirling-pdf/
> # vacío, ownership root:root      (creado por 04-estructura-directorios.md)
> ```
> Si por algún intento previo ya existiesen subdirectorios con datos antiguos, **borrarlos** antes del primer arranque limpio:
> ```bash
> sudo rm -rf /mnt/hd2t/services/stirling-pdf/configs /mnt/hd2t/services/stirling-pdf/pipeline
> ```

---

## Variables de entorno

### Ampliar `~/homelab/productividad/.env.example`

Abrir el fichero existente (ampliado en `docs/11-productividad/05-mealie.md`) y **añadir al final** un nuevo bloque (no tocar las líneas de Vaultwarden, Bookstack, Linkding, Paperless ni Mealie):

```bash
# ============================================================================
# Stirling-PDF — caja de herramientas web para PDFs (docs/11-productividad/06-stirling-pdf.md)
# ============================================================================

# --- Imagen pinneada --------------------------------------------------------
STIRLING_PDF_IMAGE_TAG=1.0.2

# --- Stirling-PDF — modo de seguridad --------------------------------------
# Stirling-PDF tiene un modo de auth nativa con BD H2 (DOCKER_ENABLE_SECURITY=true)
# que activa /login, /account, etc. AQUÍ se MANTIENE FALSE: la auth la pone
# Authelia delante por forward_auth (ver Decisiones de diseño y bloque Caddyfile).
DOCKER_ENABLE_SECURITY=false

# --- Stirling-PDF — operaciones avanzadas ----------------------------------
# Activa el grupo "advanced HTML/Book ops" (conversión a/desde HTML/EPUB,
# operaciones LibreOffice heavy). Aumenta la imagen ~1.5 GB en runtime.
# Recomendado true: cubre escenarios reales del operador (convertir un EPUB,
# fusionar HTMLs, exportar PDF a Office).
INSTALL_BOOK_AND_ADVANCED_HTML_OPS=true

# --- Stirling-PDF — OCR multi-idioma ---------------------------------------
# Tesseract instala los language packs en el primer arranque (apt-get).
# Alineado con Paperless-ngx (PAPERLESS_OCR_LANGUAGES) por coherencia.
# Códigos: eng, spa, cat, fra, deu, por, ita, ...  (ver lista completa
# en https://tesseract-ocr.github.io/tessdoc/Data-Files-in-different-versions.html)
LANGS=es_ES,en_GB,ca_ES

# --- Stirling-PDF — locale por defecto del frontend ------------------------
SYSTEM_DEFAULTLOCALE=es-ES

# --- Stirling-PDF — branding -----------------------------------------------
# Cadenas de personalización de la UI (rotuladas como "homelab" para que el
# operador no confunda esta instancia con la web pública oficial).
UI_APPNAME=Stirling-PDF (Homelab)
UI_HOMEDESCRIPTION=Caja de herramientas PDF privada del homelab. Sus archivos NO salen de la Pi.
UI_APPNAMENAVBAR=Stirling-PDF · Homelab

# --- Stirling-PDF — límites operativos -------------------------------------
# Tamaño máximo por upload (MB). Default upstream 2000 MB (2 GB), pero la
# Pi 5 con 1 GB de mem_limit no aguanta cargas muy grandes — bajamos a 500 MB
# que cubre el 99% de casos reales (extractos, contratos, libros escaneados).
SYSTEM_MAXFILESIZE=500

# --- Stirling-PDF — privacidad y telemetría --------------------------------
# Stirling-PDF tiene un flag de "Google visibility" (página pública para SEO).
# Aquí, false: la instancia es privada, no se quiere indexación.
SYSTEM_GOOGLEVISIBILITY=false

# Endpoint de métricas Prometheus (no se conecta a Prometheus aquí, pero el
# endpoint queda disponible para el futuro — ver docs/05-monitorizacion/01-prometheus.md).
METRICS_ENABLED=true

# --- Stirling-PDF — log -----------------------------------------------------
# Nivel de log de Spring Boot. INFO es suficiente para uso normal; DEBUG sólo
# para diagnosticar fallos.
LOGGING_LEVEL_ROOT=INFO
LOGGING_LEVEL_STIRLING=INFO

# --- Stirling-PDF — JVM (opcional, raramente necesario) --------------------
# JAVA_OPTS=-XX:MaxRAMPercentage=70.0
```

### Ampliar `~/homelab/productividad/.env`

Copiar las nuevas líneas de la plantilla y rellenar los valores reales. **No hay secrets a generar** (Stirling-PDF sin auth nativa no necesita ningún _secret_ — Authelia se encarga de la sesión):

```bash
# Editar el .env existente (tiene ya los valores de Vaultwarden, Bookstack,
# Linkding, Paperless y Mealie; AÑADIR debajo las nuevas líneas).
$EDITOR ~/homelab/productividad/.env

# Confirmar que las variables nuevas están y tienen los valores deseados:
grep -E '^STIRLING_PDF_|^DOCKER_ENABLE_SECURITY|^INSTALL_BOOK|^LANGS|^SYSTEM_|^UI_|^METRICS_|^LOGGING_' \
    ~/homelab/productividad/.env

# Permisos restrictivos del .env (ya debería estar 0600 desde docs anteriores):
chmod 0600 ~/homelab/productividad/.env
```

> **No commitear `.env` jamás**. El `.gitignore` del _stack_ ya lo excluye explícitamente. Aquí no hay _secrets_, pero la convención se mantiene.

> **Custodia en Vaultwarden**: **no aplica** a Stirling-PDF. No hay _secret_ que custodiar. La sesión humana la gestiona Authelia (cuyas credenciales del operador ya están en Vaultwarden desde `docs/04-seguridad/01-authelia.md`).

---

## Modificar `~/homelab/productividad/docker-compose.yml`

El _docker-compose.yml_ de este _stack_ ya existe con diez servicios (`vaultwarden`, `bookstack`, `bookstack-db`, `linkding`, `paperless`, `paperless-db`, `paperless-redis`, `paperless-gotenberg`, `paperless-tika`, `mealie`). **Editarlo, no recrearlo**: añadir el servicio `stirling-pdf`, dejando intactos los diez bloques previos.

El nuevo servicio se añade al final de la sección `services:`, justo antes de la sección `networks:`:

```yaml
  # ===========================================================================
  # Stirling-PDF — caja de herramientas web para PDFs (Spring Boot, stateless).
  # Único contenedor. Sólo en la red 'homelab' (Caddy lo alcanza por DNS).
  # NO se engancha a productividad-internal (no hay BD que aislar).
  # NO entra en Borgmatic (Categoría E).
  # Authelia delante por forward_auth (ver Caddyfile).
  # ===========================================================================
  stirling-pdf:
    image: docker.stirlingpdf.com/stirlingtools/stirling-pdf:${STIRLING_PDF_IMAGE_TAG}
    container_name: stirling-pdf
    hostname: stirling-pdf
    restart: unless-stopped
    mem_limit: 1g
    environment:
      TZ: ${TZ}
      PUID: ${PUID}                  # ignorado por la imagen, declarado por convención
      PGID: ${PGID}

      # --- Modo de seguridad: SIN auth nativa (la pone Authelia) ---
      DOCKER_ENABLE_SECURITY: ${DOCKER_ENABLE_SECURITY}

      # --- Operaciones avanzadas y OCR ---
      INSTALL_BOOK_AND_ADVANCED_HTML_OPS: ${INSTALL_BOOK_AND_ADVANCED_HTML_OPS}
      LANGS: ${LANGS}

      # --- Locale y branding ---
      SYSTEM_DEFAULTLOCALE: ${SYSTEM_DEFAULTLOCALE}
      UI_APPNAME: ${UI_APPNAME}
      UI_HOMEDESCRIPTION: ${UI_HOMEDESCRIPTION}
      UI_APPNAMENAVBAR: ${UI_APPNAMENAVBAR}

      # --- Límites operativos ---
      SYSTEM_MAXFILESIZE: ${SYSTEM_MAXFILESIZE}

      # --- Privacidad y métricas ---
      SYSTEM_GOOGLEVISIBILITY: ${SYSTEM_GOOGLEVISIBILITY}
      METRICS_ENABLED: ${METRICS_ENABLED}

      # --- Log ---
      LOGGING_LEVEL_ROOT: ${LOGGING_LEVEL_ROOT}
      LOGGING_LEVEL_STIRLING: ${LOGGING_LEVEL_STIRLING}

      # --- JVM (opcional, descomentar sólo si hay problemas de heap) ---
      # JAVA_OPTS: ${JAVA_OPTS}
    volumes:
      - /mnt/hd2t/services/stirling-pdf/configs:/configs
      - /mnt/hd2t/services/stirling-pdf/pipeline:/pipeline
    networks:
      homelab:
        aliases:
          - stirling-pdf    # Caddy resuelve 'stirling-pdf:8080' por este alias
    labels:
      homelab.stack: "productividad"
      homelab.backup: "false"     # Categoría E — no se respalda
      # Opt-in: stateless puro, downtime aceptable, sin riesgo de pérdida.
      com.centurylinklabs.watchtower.enable: "true"
    healthcheck:
      # /api/v1/info/status devuelve 200 cuando el Spring Boot está sirviendo.
      # Endpoint público (no requiere auth) y estable desde 1.0.x.
      test:
        - CMD-SHELL
        - "curl -fsS http://localhost:8080/api/v1/info/status >/dev/null"
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 180s   # primer arranque: apt install LibreOffice + tesseract langs ~2-3 min
```

> **Importante** — `stirling-pdf` se añade **dentro** del bloque `services:` ya existente, NO sustituye nada. Validar después con `docker compose config | grep -E '^\s+(vaultwarden|bookstack|bookstack-db|linkding|paperless|paperless-db|paperless-redis|paperless-gotenberg|paperless-tika|mealie|stirling-pdf):'` que los once siguen estando.

Notas de diseño:

- **Sólo en `homelab`**, no en `productividad-internal`. No hay BD que aislar (no hay BD en absoluto). Stirling-PDF no se beneficia de la red privada del _stack_.
- **Sin `ports:`**. Caddy alcanza Stirling-PDF por DNS interno (`stirling-pdf:8080`). Si el operador, durante troubleshooting, necesita acceder sin pasar por Caddy: `docker exec stirling-pdf curl -fsS http://localhost:8080/api/v1/info/status`.
- **`mem_limit: 1g`**: límite estricto para evitar que la JVM acapare memoria en una Pi 5 con muchos contenedores. La JVM detecta el cgroup y autoajusta el heap. Si en algún momento el operador procesa un PDF muy grande y aparece `OutOfMemoryError` en los logs, subir temporalmente a `2g`.
- **`start_period: 180s`**: el primer arranque tarda 2-3 minutos porque el `entrypoint` instala paquetes _runtime_ (LibreOffice si `INSTALL_BOOK_AND_ADVANCED_HTML_OPS=true`, language packs de Tesseract según `LANGS`). Arranques posteriores tardan 30-60 s (sólo carga la JVM y Spring Boot). Sin este margen, el _healthcheck_ marcaría `unhealthy` injustamente durante la instalación inicial.
- **Watchtower opt-in**: razones explicadas en **Decisiones de diseño** → _Imagen y tag_.
- **Sin `depends_on`**: Stirling-PDF es un único contenedor sin dependencias internas al _stack_. Se levanta y se cae solo.
- **`curl` en el _healthcheck_**: la imagen base de Stirling-PDF (Eclipse Temurin JRE) **sí trae `curl`** por defecto. Confirmable con `docker run --rm docker.stirlingpdf.com/stirlingtools/stirling-pdf:1.0.2 which curl`.
- **`PUID`/`PGID` declarados pero ignorados por la imagen actual**: se mantienen por coherencia con el resto del _stack_ y para preparar el terreno si una versión futura del upstream los empieza a respetar.
- **`homelab.backup: "false"`**: etiqueta informativa que documenta la categoría E. Borgmatic ya excluye la ruta del bind mount en `exclude_patterns:`, así que la etiqueta es redundante operativamente pero útil como _marker_ legible si en el futuro se usa para automatizar reportes (`docker ps --filter "label=homelab.backup=true"`).

---

## Despliegue

### Primer arranque

```bash
cd ~/homelab/productividad
# Validar la sintaxis sin levantar nada (recomendado tras editar el compose).
docker compose --env-file ../.env --env-file .env config | \
    grep -E '^\s+(vaultwarden|bookstack|bookstack-db|linkding|paperless|paperless-db|paperless-redis|paperless-gotenberg|paperless-tika|mealie|stirling-pdf):'
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
# stirling-pdf:

# Levantar SÓLO el servicio nuevo (los otros diez ya están corriendo y healthy):
docker compose --env-file ../.env --env-file .env up -d stirling-pdf
```

O, equivalente, con el _Makefile_ (ver `docs/02-docker/02-estructura-compose.md`):

```bash
cd ~/homelab
make up STACK=productividad
# El make up no es selectivo: lleva el stack completo al estado deseado.
# Como los diez previos ya están up y nada del compose los cambia,
# Compose los deja tal cual y sólo arranca stirling-pdf.
```

Vigilar el primer arranque (~2-3 min):

```bash
docker compose -f ~/homelab/productividad/docker-compose.yml logs -f stirling-pdf
# stirling-pdf | Installing LibreOffice and dependencies (advanced HTML ops)...
# stirling-pdf | apt-get install ... (~1-2 min en Pi 5)
# stirling-pdf | Installing Tesseract language packs: spa, eng, cat
# stirling-pdf | Setting locale to es-ES
# stirling-pdf | Starting Spring Boot application...
# stirling-pdf |  .   ____          _            __ _ _
# stirling-pdf | (...banner Spring Boot...)
# stirling-pdf | Started StirlingPDFApplication in 28.5 seconds
# stirling-pdf | Tomcat started on port(s): 8080 (http)
```

> **Si tarda más de 5 minutos** sin llegar a "Started StirlingPDFApplication": probablemente `apt-get install` está atascado descargando dependencias de LibreOffice por una conexión lenta. Revisar `docker logs` directamente para ver el progreso de `apt`. Aceptable hasta 8-10 min en una conexión pobre; por encima, abortar (`docker compose stop stirling-pdf`) e investigar la conectividad saliente del host.

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
# mealie                Up X minutes (healthy)
# stirling-pdf          Up X seconds (healthy)
```

> El `(healthy)` lo otorga el _healthcheck_ de `/api/v1/info/status`. Si tras 5 minutos sigue `starting`/`unhealthy`, ir a **Troubleshooting** → primer arranque.

Confirmar que el bind mount se pobló:

```bash
ls -la /mnt/hd2t/services/stirling-pdf/configs/
# -rw-r--r-- 1 root root 8192 Apr 25 12:00 settings.yml
ls -la /mnt/hd2t/services/stirling-pdf/pipeline/
# vacío (se llenará cuando el operador guarde un pipeline)
```

(Los UID/GID `root:root` son lo esperado: Stirling-PDF corre como `root` dentro del contenedor.)

Y confirmar que la API responde con la versión correcta:

```bash
docker exec stirling-pdf curl -fsS http://localhost:8080/api/v1/info/status
# {"status":"OK"}

docker exec stirling-pdf curl -fsS http://localhost:8080/api/v1/info/version
# {"version":"1.0.2"}
```

### Caddy: bloque `stirling.lan` (con `import authelia`)

Editar `~/homelab/red/Caddyfile` y añadir el bloque:

```caddy
stirling.lan {
    tls internal
    import security-headers
    import logging

    # Stirling-PDF queda detrás de Authelia (ver docs/04-seguridad/01-authelia.md).
    # Sin sesión válida, redirige al portal https://auth.lan/?rd=...
    import authelia

    # Subidas de PDF grandes. Coincide con SYSTEM_MAXFILESIZE=500 del .env;
    # añadir margen porque multipart/form-data añade ~1-2% de overhead.
    request_body {
        max_size 520MB
    }

    # Pasar a Stirling-PDF tal cual. Caddy reescribe Host por defecto;
    # Stirling-PDF no construye URLs absolutas (no tiene BASE_URL ni similar),
    # así que basta con los X-Forwarded-* estándar.
    reverse_proxy stirling-pdf:8080 {
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
# Sin cookie de Authelia: redirige al portal
curl -k --resolve stirling.lan:443:192.168.1.3 -I https://stirling.lan/
# HTTP/2 302
# location: https://auth.lan/?rd=https%3A%2F%2Fstirling.lan%2F&rm=GET

# Con cookie válida (no se prueba aquí desde curl; se prueba desde el navegador)
```

Y desde el navegador:

1. Visitar `https://stirling.lan/` por primera vez.
2. Caddy redirige a `https://auth.lan/?rd=...`.
3. Login con las credenciales del operador (las del `users_database.yml` de Authelia, custodiadas en Vaultwarden).
4. Tras el TOTP, redirección automática a `https://stirling.lan/` con la home de Stirling-PDF: bienvenida personalizada (`UI_APPNAME=Stirling-PDF (Homelab)`), navbar con el menú de operaciones (_Page Operations_, _Convert from/to PDF_, _Security_, _View & Edit_, _Advanced_, _Filter_, _Pipeline_), y el mensaje custom (`UI_HOMEDESCRIPTION=Caja de herramientas PDF privada del homelab. Sus archivos NO salen de la Pi.`).

> **Si el navegador queda en bucle de redirección** entre `stirling.lan` y `auth.lan`: la cookie de Authelia para el dominio `lan` no se está enviando. Causas habituales: (a) `auth.lan` y `stirling.lan` resuelven a IPs distintas (no es el caso aquí — ambos son `192.168.1.3` por _wildcard_ de Pi-hole), (b) la cookie se invalida cada vez por discrepancia en los `domain` o `path`. Revisar `~/homelab/seguridad/configuration.yml` → `session.domain: lan`. Detalles en `docs/04-seguridad/01-authelia.md` → Troubleshooting.

---

## Configuración tras primer arranque

### 1. Probar el primer flujo (split + merge)

Para validar que la cadena completa (Authelia → Caddy → Stirling-PDF → operación → respuesta) funciona _end-to-end_:

1. Tomar un PDF de prueba cualquiera (extracto bancario, cualquier factura). **Idealmente uno que no sea sensible**: el _flow_ funciona, pero como sanity check inicial es mejor probar con algo que no importe.
2. Ir a `Page Operations → Split PDF by N pages`.
3. Subirlo, indicar "split cada 1 página", `Submit`. Se descarga un ZIP con N PDFs (uno por página).
4. Volver al menú principal → `General → Merge PDFs`. Subir esos N PDFs en orden, `Submit`. Se descarga el PDF reconstruido.
5. Comparar tamaño y contenido del original vs reconstruido. Deben ser visualmente idénticos (las operaciones son lossless en este flujo).

Esto valida: subida (multipart/form-data hasta `SYSTEM_MAXFILESIZE`), procesamiento (qpdf detrás), descarga, y **que `/tmp` interno se está limpiando** (los ficheros temporales no quedan acumulados).

```bash
# Verificar que /tmp del contenedor está limpio tras la operación:
docker exec stirling-pdf ls /tmp/stirling-pdf-files/ 2>/dev/null || echo "limpio (esperado)"
# Debe estar vacío o no existir.
```

### 2. Probar OCR en español

Verifica que los _language packs_ de Tesseract se instalaron correctamente:

1. Tomar una imagen escaneada en PDF (un escaneo cualquiera con texto en español; si no hay a mano, escanear una factura del cajón con el móvil y exportar a PDF).
2. `Security → OCR (Optical Character Recognition)`.
3. Subir el PDF, seleccionar idioma "Spanish" en el dropdown, `Submit`.
4. Descargar el PDF resultado y abrirlo en cualquier visor: el texto ahora **es seleccionable** y _searchable_ (Ctrl+F encuentra palabras dentro del PDF).

```bash
# Si quieres confirmar que tesseract reconoce los idiomas instalados:
docker exec stirling-pdf tesseract --list-langs
# List of available languages (3):
# cat
# eng
# spa
```

> **Si OCR falla con "Tesseract: language not found"**: el `LANGS` del `.env` no se procesó correctamente en el primer arranque. Forzar reinstalación con `docker compose restart stirling-pdf` o, en último caso, con `docker compose down stirling-pdf && docker compose up -d stirling-pdf` (re-ejecuta el `entrypoint` completo).

### 3. (Opcional) Personalizar `settings.yml`

Stirling-PDF generó `/mnt/hd2t/services/stirling-pdf/configs/settings.yml` con los _defaults_ del upstream. La mayoría de las cosas se pueden controlar desde las variables de entorno del `.env` (que es la vía recomendada para mantener la configuración versionable), pero algunas opciones avanzadas sólo se exponen vía `settings.yml`:

```bash
sudo $EDITOR /mnt/hd2t/services/stirling-pdf/configs/settings.yml
```

Opciones útiles a inspeccionar:

```yaml
endpoints:
  toRemove: []                # listar aquí endpoints a deshabilitar (p.ej. ['/api/v1/security/...'] si se quiere ocultar)
  groupsToRemove: []          # deshabilitar grupos enteros de la UI

ui:
  appName: 'Stirling-PDF (Homelab)'        # ya viene del .env
  homeDescription: '...'                    # ya viene del .env
  appNameNavbar: '...'                      # ya viene del .env

system:
  defaultLocale: 'es-ES'                    # ya viene del .env
  googlevisibility: false                   # ya viene del .env
  maxFileSize: 500                          # ya viene del .env
  enableAlphaFunctionality: false           # NO activar (features inestables)
  showUpdate: false                         # ocultar el banner "new version available"
  showUpdateOnlyAdmin: true                 # si security activo, sólo admin lo ve
  customStaticFilePath: ''                  # ruta a directorio con estáticos custom

security:
  enableLogin: false                        # ya viene del .env (DOCKER_ENABLE_SECURITY)
  initialLogin: {}
  csrfDisabled: false                       # NO desactivar
```

Tras editar, reiniciar:

```bash
docker compose -f ~/homelab/productividad/docker-compose.yml restart stirling-pdf
# Esperar a (healthy)
```

> **Versionar `settings.yml` (opcional)**: si se han hecho cambios significativos a mano, copiar el fichero a `~/homelab/productividad/stirling-pdf/settings.yml.example` y commitearlo en git. Esto **no** es un backup operativo (que ya está descartado por categoría E), pero sí es **memoria histórica**: si un día Stirling-PDF se rompe y hay que reinstalar de cero, el operador recuerda qué tocó.
> ```bash
> mkdir -p ~/homelab/productividad/stirling-pdf
> sudo cp /mnt/hd2t/services/stirling-pdf/configs/settings.yml \
>     ~/homelab/productividad/stirling-pdf/settings.yml.example
> sudo chown $USER:$USER ~/homelab/productividad/stirling-pdf/settings.yml.example
> # Eliminar líneas con secrets (no debería haberlos en este fichero, pero por si acaso)
> # y commitear:
> git -C ~/homelab add productividad/stirling-pdf/settings.yml.example
> git -C ~/homelab commit -m "docs(productividad): snapshot Stirling-PDF settings.yml.example"
> ```

### 4. (Opcional) Crear un primer _pipeline_ del operador

Los _pipelines_ son combinaciones guardadas de operaciones encadenadas. Útiles para flujos que el operador repite:

1. Ir a `Pipeline → Create New Pipeline`.
2. Nombre: `OCR + Comprimir + Eliminar metadatos`.
3. Añadir pasos:
   - Step 1: `OCR` con idioma `spa+eng`, `clean: true`.
   - Step 2: `Compress PDF` con calidad `medium`.
   - Step 3: `Sanitize PDF` (elimina JavaScript, formularios, etc).
   - Step 4: `Remove Metadata` (autor, fecha de creación, etc).
4. `Save`.

El _pipeline_ queda guardado como JSON en `/mnt/hd2t/services/stirling-pdf/pipeline/<nombre>.json`. A partir de aquí, `Pipeline → Run` permite seleccionar el _pipeline_ y subir uno o varios PDFs en lote.

> **Caso de uso típico**: el operador escanea facturas con el móvil, las recibe en `/mnt/hd2t/services/syncthing/inbox/facturas/`, las arrastra al _pipeline_ "OCR + Comprimir + Sanitizar", descarga el ZIP resultado y lo sube a Paperless-ngx (`docs/11-productividad/04-paperless-ngx.md`) con metadatos limpios y texto _searchable_. Stirling-PDF como **pre-procesador** de Paperless es uno de los flujos más útiles del homelab.

### 5. (Opcional) `customFiles/` para logos personalizados

Si se quiere reemplazar el favicon, el logo del navbar o las plantillas de _watermark_:

1. Añadir un bind mount al `docker-compose.yml`:
   ```yaml
       volumes:
         - /mnt/hd2t/services/stirling-pdf/configs:/configs
         - /mnt/hd2t/services/stirling-pdf/pipeline:/pipeline
         - /mnt/hd2t/services/stirling-pdf/customFiles:/customFiles  # ← añadir
   ```
2. Crear el directorio en el host:
   ```bash
   sudo mkdir -p /mnt/hd2t/services/stirling-pdf/customFiles/static/images
   ```
3. Colocar el logo personalizado:
   ```bash
   sudo cp ~/Downloads/mi-logo-homelab.png \
       /mnt/hd2t/services/stirling-pdf/customFiles/static/images/logo.png
   ```
4. `docker compose -f ~/homelab/productividad/docker-compose.yml restart stirling-pdf` y refrescar la web (`Ctrl+Shift+R`).

> **No se hace por defecto**: la mayoría del operador no necesita logos custom y `customFiles/` queda como apartado puramente cosmético.

### 6. (No aplica) Activar el bloque del _hook_ de Borgmatic

A diferencia de Vaultwarden, Bookstack, Linkding, Paperless y Mealie, **Stirling-PDF NO entra en Borgmatic** (Categoría E). En `docs/07-backups/03-backup-docker-volumes.md` no se preparó ningún bloque comentado para Stirling-PDF (porque no había nada que dumpear). En `docs/07-backups/02-borgmatic.md` se añadió `/mnt/hd2t/services/stirling-pdf` al `exclude_patterns:` desde el primer momento.

**No tocar nada de Borgmatic desde este documento**.

### 7. (No aplica) Activar un _jail_ de fail2ban

Stirling-PDF, al estar detrás de Authelia, no expone formularios de login propios. Los intentos de fuerza bruta los recibe Authelia (que ya tiene su propio _rate limiting_ y, si `docs/04-seguridad/02-fail2ban.md` lo configuró, su _jail_ correspondiente). **No hace falta** un _jail_ específico para `stirling-pdf` — sería redundante.

---

## Verificación final

Antes de pasar a `docs/11-productividad/07-freshrss.md`, comprobar:

- [ ] `docker compose -f ~/homelab/productividad/docker-compose.yml ps` muestra los **once** contenedores (`vaultwarden`, `bookstack-db`, `bookstack`, `linkding`, `paperless-db`, `paperless-redis`, `paperless-gotenberg`, `paperless-tika`, `paperless`, `mealie`, `stirling-pdf`) en `(healthy)`.
- [ ] `docker exec stirling-pdf curl -fsS http://localhost:8080/api/v1/info/status` devuelve `{"status":"OK"}`.
- [ ] `docker exec stirling-pdf curl -fsS http://localhost:8080/api/v1/info/version` devuelve `{"version":"1.0.2"}` (o el _tag_ que se haya pinneado).
- [ ] **Sin sesión** Authelia: `curl -k --resolve stirling.lan:443:192.168.1.3 -I https://stirling.lan/` devuelve `HTTP/2 302` con `location: https://auth.lan/?rd=...`.
- [ ] **Con sesión** válida (desde el navegador): `https://stirling.lan/` carga la home de Stirling-PDF con el branding personalizado (`UI_APPNAME=Stirling-PDF (Homelab)` en navbar y `UI_HOMEDESCRIPTION=...` en la home).
- [ ] **Test de upload + operación**: el _flow_ "Split → Merge" descrito en **Configuración → 1** funciona _end-to-end_.
- [ ] **Test de OCR**: el _flow_ "OCR sobre PDF escaneado en español" descrito en **Configuración → 2** produce un PDF con texto seleccionable.
- [ ] **Tesseract instaló los idiomas**: `docker exec stirling-pdf tesseract --list-langs` lista al menos `spa`, `eng`, `cat` (o los que se hayan declarado en `LANGS`).
- [ ] **LibreOffice instaló las dependencias avanzadas** (si `INSTALL_BOOK_AND_ADVANCED_HTML_OPS=true`): `docker exec stirling-pdf which libreoffice` devuelve `/usr/bin/libreoffice` o ruta similar (no error). Confirmable también con un test funcional: `Convert to PDF → DOCX → PDF` con un `.docx` cualquiera.
- [ ] **`/tmp` interno se limpia tras operaciones**: tras procesar 2-3 PDFs, `docker exec stirling-pdf du -sh /tmp/stirling-pdf-files 2>/dev/null` debe ser `<1 MB` o el directorio no existir. Si crece monotónicamente, hay una fuga (ver Troubleshooting).
- [ ] `docker network inspect homelab --format '{{range .Containers}}{{.Name}} {{end}}'` lista a `stirling-pdf` (entre los demás del homelab); **NO** lista a `stirling-pdf` en `productividad-internal`:
  ```bash
  docker network inspect productividad-internal --format '{{range .Containers}}{{.Name}} {{end}}'
  # Debe listar bookstack bookstack-db paperless paperless-db paperless-redis
  # paperless-gotenberg paperless-tika  (stirling-pdf NO debe estar).
  ```
- [ ] **Memoria controlada**: `docker stats stirling-pdf --no-stream --format '{{.MemUsage}}'` reporta uso de RAM <1 GiB tras varias operaciones (idle típico ~200 MiB; pico durante OCR de un PDF mediano ~500-800 MiB).
- [ ] Permisos del bind mount:
  ```bash
  stat -c '%U:%G' /mnt/hd2t/services/stirling-pdf/configs
  # root:root (esperado — Stirling-PDF corre como root dentro del contenedor)
  ```
- [ ] **No hay datos en Borgmatic**: `borg list ~/homelab/backups/borg-repo --pattern '*/stirling-pdf/*' --short` no devuelve nada (la ruta está excluida por `exclude_patterns:`).
- [ ] Tras un `docker compose -f ~/homelab/productividad/docker-compose.yml restart stirling-pdf`, el contenedor vuelve a `(healthy)` en <60 s (tras el primer arranque, los apt-installs ya están cacheados en la imagen y los reinicios son rápidos) y el operador puede seguir trabajando (la sesión Authelia sobrevive porque su Redis no se reinició).
- [ ] Tras un `sudo reboot` de la Pi, los once contenedores vuelven a estar `(healthy)` sin intervención manual y `https://stirling.lan/` responde (tras login en Authelia).
- [ ] `git -C ~/homelab status` muestra como **modificados**: `productividad/docker-compose.yml`, `productividad/.env.example`, `red/Caddyfile`. **No** muestra `productividad/.env` ni nada bajo `/mnt/hd2t/`. Y, opcionalmente si se siguió **Configuración → 3**: `productividad/stirling-pdf/settings.yml.example` como **nuevo**. _Commit_:

  ```bash
  cd ~/homelab
  git add productividad/docker-compose.yml productividad/.env.example \
          red/Caddyfile
  # Sólo si se versionó el settings.yml.example:
  git add productividad/stirling-pdf/settings.yml.example 2>/dev/null || true
  git commit -m "feat(productividad): add Stirling-PDF (stateless, Authelia forward_auth)"
  ```

---

## Backup

| Qué                                       | Dónde                                                                          | Cómo                                                       |
|-------------------------------------------|--------------------------------------------------------------------------------|------------------------------------------------------------|
| `docker-compose.yml`, `.env.example`      | `~/homelab/productividad/`                                                     | git                                                        |
| `settings.yml.example` (opcional)         | `~/homelab/productividad/stirling-pdf/`                                        | git (memoria histórica de personalizaciones)               |
| `configs/` y `pipeline/` (runtime)        | `/mnt/hd2t/services/stirling-pdf/`                                             | **NO se respaldan** (Categoría E). Excluidos en `exclude_patterns:` de `data.yaml` desde `docs/07-backups/02-borgmatic.md`. |
| Bloque del `Caddyfile`                    | `~/homelab/red/Caddyfile`                                                      | git (parte del repo de configuración)                      |

**No hay BD que dumpear. No hay datos del operador que se pierdan en un DR. No hay _hook_ de Borgmatic.** Esto es un caso paradigmático de Categoría E.

> **Restauración tras desastre**:
>
> 1. Restaurar el repo `~/homelab/` desde git remoto (Codeberg/GitHub privado).
> 2. Restaurar `~/homelab/productividad/.env` desde Vaultwarden (las _passphrase_ y secrets de los **otros** servicios del stack están allí; Stirling-PDF en sí no aporta secrets).
> 3. `make up STACK=productividad` — Stirling-PDF arranca, regenera `configs/settings.yml` con _defaults_, y queda listo. El operador ha **perdido**:
>    - sus _pipelines_ guardados (5-10 minutos de UI para recrear los que use habitualmente),
>    - sus personalizaciones de `settings.yml` que no estuvieran en el `.env` ni en `settings.yml.example` versionado.
> 4. **Aceptable**: el coste de pérdida es ~10 minutos de UI; el coste de respaldarlo en Borg sería un volumen extra de retención de un fichero <10 KB que cambia rara vez. La asimetría justifica la categoría E.

> **Antes de cualquier upgrade _minor_ de Stirling-PDF** (1.0 → 1.1 → 1.2):
> 1. Editar `.env`: `STIRLING_PDF_IMAGE_TAG=1.1.0` (leer el _changelog_ upstream — algunos _bumps minor_ cambian el formato de `settings.yml`, que el operador querrá inspeccionar manualmente).
> 2. `docker compose pull stirling-pdf && docker compose up -d stirling-pdf`.
> 3. `docker logs -f stirling-pdf` — esperar a `Started StirlingPDFApplication` y `(healthy)`.
> 4. `curl -k --resolve stirling.lan:443:192.168.1.3 -I https://stirling.lan/` (con sesión Authelia válida) — confirmar 200.
> 5. Verificación final completa de la sección anterior.
> 6. Si algo va mal: `docker compose down stirling-pdf`, restaurar `STIRLING_PDF_IMAGE_TAG=1.0.2`, `up -d stirling-pdf`. **Sin riesgo de pérdida de datos** (no hay datos).
>
> Los _bumps_ de **patch** (1.0.2 → 1.0.3) los gestiona Watchtower automáticamente; el operador no necesita intervenir, pero **debería revisar el `docker logs stirling-pdf` el día siguiente al pull** para confirmar que arrancó bien.

---

## Troubleshooting

### `stirling-pdf` arranca y queda en `unhealthy`

El `start_period: 180s` da margen para `apt-get install` de LibreOffice y _language packs_. Si tras 5 minutos sigue `starting`/`unhealthy`, mirar los logs:

```bash
docker logs stirling-pdf --tail 100
```

Causas frecuentes:

1. **`apt-get install` falló por DNS o conectividad**: aparece como `Unable to fetch some archives` o `Could not resolve 'deb.debian.org'`. Causa: el contenedor no tiene salida DNS (Pi-hole filtró algo, Unbound caído, etc). Solución: confirmar con
   ```bash
   docker exec stirling-pdf nslookup deb.debian.org
   docker exec stirling-pdf curl -fsSI https://deb.debian.org/
   ```
   Si falla, revisar Pi-hole (`docs/03-red/02-pihole.md`) y el resolver del host. Una vez restaurada la conectividad: `docker compose down stirling-pdf && docker compose up -d stirling-pdf` para reintentar.

2. **`apt-get install` está descargando muy lento**: paciencia. En una conexión doméstica regular, los paquetes de LibreOffice pesan ~600 MB y pueden tardar 3-5 minutos. Si la espera es excesiva (>10 min sin progreso), abortar y reintentar.

3. **Espacio en `/var/lib/docker`**: si la microSD está casi llena, `apt-get install` falla con `No space left on device`. Verificar con `df -h /var/lib/docker`. Solución: liberar espacio (`docker system prune -af`) o mover el _data root_ de Docker a hd2t (procedimiento en `docs/02-docker/01-instalacion-docker.md`).

4. **`OutOfMemoryError` de la JVM**: `docker logs` muestra `java.lang.OutOfMemoryError: Java heap space`. Causa: `mem_limit: 1g` se quedó corto para la operación que estaba intentando. Solución temporal: subir `mem_limit` a `2g` en el compose y reiniciar. Solución permanente: si el operador procesa habitualmente PDFs muy grandes, dejar `mem_limit: 2g` permanente (a costa de menos margen para los otros 10 contenedores del stack).

5. **`Tomcat started on port(s)` no aparece** tras 4-5 minutos: el _entrypoint_ se quedó atrapado en algún paso. Reiniciar (`docker compose restart stirling-pdf`); si persiste, eliminar el contenedor y la imagen (`docker compose down stirling-pdf && docker rmi docker.stirlingpdf.com/stirlingtools/stirling-pdf:1.0.2`) y volver a `up -d` para forzar un re-pull limpio.

6. **`Could not bind to port 8080`**: improbable porque no hay `ports:` publicado al host, pero podría suceder si se editó el compose por error. Confirmar con `docker compose -f ~/homelab/productividad/docker-compose.yml config | grep -A2 stirling-pdf` que no hay `ports:` ni `network_mode: host`.

### `502 Bad Gateway` desde Caddy hacia `stirling-pdf`

Caddy responde 502 si no puede alcanzar `stirling-pdf:8080` desde la red `homelab`. Probar:

```bash
docker exec caddy curl -fsS http://stirling-pdf:8080/api/v1/info/status
# {"status":"OK"}  — si devuelve esto, Caddy está bien y el problema es otro.
# "Connection refused": Stirling-PDF no está sirviendo. Pasar al caso anterior.

docker exec caddy nslookup stirling-pdf
# Debe resolver a una IP del 172.20.10.0/24.
```

Causas:

1. Stirling-PDF en `unhealthy` — ver caso anterior.
2. `stirling-pdf` no está enganchado a `homelab` (mira con `docker network inspect homelab`). Si no está, revisar la sección `networks:` del compose y `up -d stirling-pdf` de nuevo.
3. `stirling-pdf` está en `homelab` pero el alias DNS no está propagado (raro). Reinicio del contenedor lo arregla.

### Bucle de redirección `stirling.lan ⇄ auth.lan`

El navegador queda atrapado redirigiendo entre los dos dominios sin completar el login.

Causa típica: la cookie de sesión de Authelia no se considera válida para `stirling.lan` por discrepancia en el `domain` de la cookie.

Diagnóstico:

```bash
# Confirmar el dominio configurado en Authelia:
docker exec authelia grep -A2 'session:' /config/configuration.yml
# Debe contener:
#   domain: lan
#   secret: <…>
```

Si `domain: lan` está bien:

1. Borrar todas las cookies del dominio `lan` en el navegador (`Settings → Privacy → Cookies → Search "lan" → Remove`).
2. Volver a `https://stirling.lan/`. Esta vez debería mostrar el portal de Authelia limpio.
3. Hacer login y comprobar que la cookie se setea correctamente en Network tab del DevTools (`Set-Cookie: authelia_session=...; Domain=.lan; Path=/`).

Si tras eso sigue sin funcionar: revisar si `auth.lan` y `stirling.lan` resuelven a la misma IP (`192.168.1.3`).

```bash
nslookup auth.lan 192.168.1.2     # Pi-hole
nslookup stirling.lan 192.168.1.2
# Ambos a 192.168.1.3
```

Si resuelven a IPs distintas (improbable), el _wildcard_ de Pi-hole se rompió — revisar `docs/03-red/02-pihole.md`.

### `413 Request Entity Too Large` al subir un PDF grande

Síntomas: la subida de un PDF >500 MB (o el límite que se haya configurado) falla con `413` o se trunca a medias.

Causas y soluciones:

1. **Caddy `request_body max_size`** demasiado bajo. Verificar el bloque `stirling.lan` del `Caddyfile`: `request_body { max_size 520MB }`. Si fuese menor, ajustar y `caddy reload`.
2. **Stirling-PDF `SYSTEM_MAXFILESIZE`** demasiado bajo. Si `SYSTEM_MAXFILESIZE=500` y el PDF es de 600 MB, Spring Boot lo rechaza. Solución: subir el valor en el `.env` y `restart stirling-pdf`.
3. **Memory pressure**: si `mem_limit: 1g` se queda corto al cargar un PDF grande en memoria, el contenedor cae con `OutOfMemoryError`. La JVM no devuelve un 413 limpio en ese caso, sino un 500 o un timeout. Solución: subir `mem_limit` puntualmente.

> **Estrategia para PDFs muy grandes** (>500 MB, p.ej. un libro escaneado): partir el PDF en trozos antes de subirlo (con `pdftk` o un Stirling-PDF más pequeño en otra Pi) y procesarlos por separado. Tiene sentido también porque la latencia de OCR sobre un PDF de 500 páginas en una Pi 5 es de varios minutos por trozo.

### El OCR funciona pero da resultado pésimo en español

Síntomas: el texto OCR'd está plagado de errores tipográficos, especialmente con tildes y caracteres especiales (`ñ`, `¿`, `¡`).

Causas:

1. **Idioma incorrecto seleccionado**: si se seleccionó `English` para un PDF en español, el resultado es esperable. Volver a hacer OCR seleccionando `Spanish` o `spa+eng` (multi-idioma) en el dropdown.
2. **Calidad del escaneo es mala**: Tesseract necesita ≥150 DPI y buena nitidez para precisión razonable. Si el PDF se escaneó a 72 DPI o tiene mucha compresión JPEG, el OCR será malo independientemente del motor. Solución: re-escanear a 300 DPI sin compresión agresiva.
3. **Idioma instalado pero versión vieja del traineddata**: Tesseract usa el `traineddata` de Debian/Ubuntu, que puede ser una versión anterior con peor precisión. Verificar versión:
   ```bash
   docker exec stirling-pdf tesseract --version
   # tesseract 5.3.x
   ```
   Si es <5.0, considerar actualizar el _tag_ de Stirling-PDF a una versión que use Tesseract 5.x (1.0.x ya lo trae).

### `/tmp` del contenedor crece monotónicamente (memory leak / file leak)

Síntomas: tras varias semanas de uso, `docker exec stirling-pdf du -sh /tmp` reporta `>1 GB` y sigue creciendo sin que el operador esté haciendo nada.

Causa: una operación falló a medio camino y dejó ficheros temporales sin limpiar. Es un bug conocido del upstream que ha mejorado en versiones recientes pero ocasionalmente reaparece.

Solución temporal:

```bash
docker exec stirling-pdf find /tmp/stirling-pdf-files -type f -mtime +1 -delete
docker exec stirling-pdf find /tmp -type d -empty -delete
```

Solución permanente (si el problema persiste): cron diario _en el host_ que reinicie el contenedor:

```cron
# /etc/cron.d/stirling-pdf-tmp-cleanup
30 4 * * * root docker compose -f /home/operador/homelab/productividad/docker-compose.yml restart stirling-pdf >/dev/null 2>&1
```

(Aceptable porque el reinicio es rápido — 30-60 s — y a las 04:30 nadie estará usando el servicio.)

> **Si esto sucede con frecuencia**, abrir un issue al upstream con el rango de tags afectados.

### Stirling-PDF no respeta el `mem_limit` (la Pi se queda sin RAM)

Síntomas: durante un OCR pesado, `htop` muestra que la Pi entra en _swap_ o se queda casi sin RAM disponible.

Causa: la JVM no ha detectado bien el cgroup y está pidiendo más heap del esperado.

Solución: forzar el _ergonomics_ con `JAVA_OPTS`:

```bash
# En ~/homelab/productividad/.env, descomentar y rellenar:
JAVA_OPTS=-XX:MaxRAMPercentage=70.0 -XX:InitialRAMPercentage=25.0

# En el compose, descomentar la línea correspondiente del bloque stirling-pdf:
#       JAVA_OPTS: ${JAVA_OPTS}

# Reiniciar:
docker compose -f ~/homelab/productividad/docker-compose.yml up -d stirling-pdf
```

Esto fuerza a la JVM a usar como máximo el 70% del cgroup (700 MB de un `mem_limit: 1g`), dejando margen para Spring Boot, GC y _native code_ de las librerías PDF.

### El _pipeline_ guardado se ejecuta con error "Pipeline step X failed"

Síntomas: tras crear un _pipeline_ y ejecutarlo, falla en uno de los pasos con un mensaje genérico.

Causas:

1. **Operación incompatible con el formato de entrada**: p.ej. `Convert PDF to PDF/A` sobre un PDF que ya es PDF/A puede fallar. Cada _step_ asume que el _input_ es del tipo esperado.
2. **`SYSTEM_MAXFILESIZE` se aplica también dentro del pipeline**: si un paso intermedio genera un fichero más grande que el límite, el siguiente paso falla. Solución: subir el límite si los PDFs intermedios son grandes.
3. **Tesseract no instalado correctamente**: el paso OCR del _pipeline_ falla con `Tesseract: language not found`. Solución: ver caso "El OCR funciona pero..." de arriba.

Diagnóstico genérico: ejecutar el _pipeline_ con `LOGGING_LEVEL_STIRLING=DEBUG` (en el `.env` y `restart`), reproducir el fallo, y leer `docker logs stirling-pdf` para identificar el paso problemático.

### Mover el _stack_ a otra Pi (DR scenario)

1. En la Pi nueva: instalar Pi OS, Docker, montar hd2t, restaurar `~/homelab/` (git clone + `.env` desde Vaultwarden).
2. **No hay nada que restaurar de `/mnt/hd2t/services/stirling-pdf/`** (Categoría E — no está en Borgmatic).
3. Levantar el _stack_ con `make up STACK=productividad`.
4. Esperar a `stirling-pdf (healthy)` (~3 min en el primer arranque por las dependencias _runtime_), después abrir `https://stirling.lan/` desde el navegador (con sesión Authelia válida).
5. **Recrear los _pipelines_ habituales** del operador (5-10 min de UI). Si se versionó `settings.yml.example` en git, copiarlo de vuelta a `/mnt/hd2t/services/stirling-pdf/configs/settings.yml` y `restart stirling-pdf`.
6. Listo. La caja de herramientas está disponible.

> **Nota**: este es el _DR scenario_ más rápido del homelab por ser stateless. Compárese con Mealie (que requiere restaurar `data/mealie.db` del dump) o Paperless (que requiere restaurar `data/`, `media/`, **y** los dumps de Postgres).

---

## Restringir la API REST a IPs internas (opcional)

Si en el futuro hay automatizaciones que llaman a `/api/v1/...` desde, p.ej., n8n o Home Assistant, y se quiere **bypassear Authelia** sólo para esas llamadas (porque no es razonable obligar a un script a manejar el _flow_ OAuth), una solución limpia es añadir un _matcher_ en Caddy:

```caddy
stirling.lan {
    tls internal
    import security-headers
    import logging

    # APIs llamadas por automatizaciones internas: no Authelia, pero sí restricción de IP.
    @apiclients {
        path /api/v1/*
        remote_ip 172.20.0.0/16 192.168.1.0/24
    }
    handle @apiclients {
        reverse_proxy stirling-pdf:8080 {
            header_up Host {host}
            header_up X-Real-IP {remote_host}
            header_up X-Forwarded-For {remote_host}
            header_up X-Forwarded-Proto {scheme}
        }
    }

    # Resto del tráfico (UI humana): protegido por Authelia.
    handle {
        import authelia
        request_body {
            max_size 520MB
        }
        reverse_proxy stirling-pdf:8080 {
            header_up Host {host}
            header_up X-Real-IP {remote_host}
            header_up X-Forwarded-For {remote_host}
            header_up X-Forwarded-Proto {scheme}
        }
    }
}
```

Con esto: las llamadas a `/api/v1/...` desde la LAN o desde la red Docker `homelab` pasan sin Authelia; las llamadas humanas a `/`, `/general/...`, `/page-operations/...` siguen pidiendo login.

> **No se aplica por defecto**: hasta que haya una automatización real que justifique la complejidad, mantener el bloque simple con `import authelia` global. La excepción se documenta aquí para cuando llegue el caso.

---

## Activar la BD H2 + auth nativa de Stirling-PDF (opcional, NO recomendado)

Stirling-PDF soporta `DOCKER_ENABLE_SECURITY=true` que activa una BD H2 embebida con sistema de cuentas locales (`/login`, `/account`, _initial admin_ por env vars). Esto **dejaría de ser stateless** y entraría en categoría B (los usuarios y sus configuraciones serían pérdida si no se respaldase).

**Por qué NO se hace aquí**:

- Duplica la auth con Authelia (pantalla de login extra dentro de la propia herramienta + 2FA potencialmente conflictivo).
- Convierte un servicio Categoría E en Categoría B con _hook_ de Borgmatic (dump de H2), añadiendo operaciones a la rutina nocturna.
- No aporta nada que Authelia ya no haga mejor.

**Cuándo sí tendría sentido**: si el homelab decidiera **abandonar Authelia** y volver a "cada servicio gestiona su auth", o si Stirling-PDF se quisiera exponer a varios usuarios con permisos diferenciados (admin vs read-only) — pero esa diferenciación dentro de Stirling-PDF es muy básica y el caso de uso del homelab no lo justifica.

Si en algún momento el operador quiere experimentar:

1. `~/homelab/productividad/.env`: `DOCKER_ENABLE_SECURITY=true`.
2. Añadir variables `SECURITY_INITIALLOGIN_USERNAME=admin` y `SECURITY_INITIALLOGIN_PASSWORD=<password>`.
3. **Quitar** `import authelia` del bloque `stirling.lan` del `Caddyfile`.
4. `restart stirling-pdf` y `caddy reload`.
5. Visitar `https://stirling.lan/login`, hacer login, cambiar la password.
6. **Añadir** `/mnt/hd2t/services/stirling-pdf` al backup como categoría B y crear un _hook_ que copie la BD H2 a `/mnt/hd2t/backups/dumps/stirling-pdf-h2.db`.

> **Reversible**: si después se decide volver a Authelia, basta con `DOCKER_ENABLE_SECURITY=false` + `import authelia` + remover el _hook_ de Borgmatic.

---

## Referencias

- **Stirling-PDF — repositorio oficial**: https://github.com/Stirling-Tools/Stirling-PDF
- **Stirling-PDF — documentación**: https://docs.stirlingpdf.com/
- **Stirling-PDF — registro de imágenes Docker**: https://docker.stirlingpdf.com/v2/stirlingtools/stirling-pdf/tags/list (mirror en `ghcr.io/stirling-tools/stirling-pdf`)
- **Stirling-PDF — variables de entorno**: https://docs.stirlingpdf.com/Installation/Docker
- **Stirling-PDF — API reference (Swagger)**: en cada instancia, `https://stirling.lan/swagger-ui/index.html`
- **Tesseract — language data files**: https://tesseract-ocr.github.io/tessdoc/Data-Files-in-different-versions.html
- **OCRmyPDF — documentación** (motor de OCR usado por Stirling-PDF): https://ocrmypdf.readthedocs.io/
- **Documentación interna**:
  - `docs/02-docker/02-estructura-compose.md` — definición del _stack_ `productividad`.
  - `docs/02-docker/04-watchtower.md` — convención `com.centurylinklabs.watchtower.enable` y lista de servicios opt-in (incluye Stirling-PDF).
  - `docs/03-red/04-caddy.md` — _snippets_ `security-headers`, `logging` y CA local.
  - `docs/04-seguridad/01-authelia.md` — Authelia, _snippet_ `authelia.caddy` y patrón `forward_auth`.
  - `docs/07-backups/01-estrategia-backup.md` — clasificación A/B/C/D/E (Stirling-PDF es Categoría E).
  - `docs/07-backups/02-borgmatic.md` — `exclude_patterns:` ya excluye `/mnt/hd2t/services/stirling-pdf`.
  - `docs/07-backups/03-backup-docker-volumes.md` — Stirling-PDF como ejemplo paradigmático de Categoría E ("ni siquiera se respalda").
  - `docs/11-productividad/01-vaultwarden.md` — _stack_ `productividad` y `~/homelab/productividad/.env`.
  - `docs/11-productividad/04-paperless-ngx.md` — Stirling-PDF citado como pre-procesador (desbloqueo de PDFs cifrados antes del archivado).
  - `docs/11-productividad/05-mealie.md` — documento previo del _stack_.
  - `docs/11-productividad/07-freshrss.md` — siguiente documento del _stack_.
