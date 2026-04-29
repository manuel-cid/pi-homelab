# Vaultwarden

## Descripción

Cerradas las Fases 3 (red + reverse proxy), 4 (SSO + fail2ban), 5 (observabilidad) y 7 (estrategia de backup), el homelab tiene la base lista para alojar **el servicio más sensible** de toda la infraestructura: **el gestor de contraseñas**. La paradoja de los homelabs (y de cualquier infra personal con varios servicios autenticados) es que cada servicio nuevo añade una credencial al gestor del operador; cuando el gestor está mal puesto o no es de confianza, todo lo demás importa menos. Por eso Vaultwarden es **T1 crítico** en `07-backups/01-estrategia-backup.md` y la jail dedicada en `04-seguridad/02-fail2ban.md` lleva su nombre desde antes de existir el contenedor.

Este documento despliega **Vaultwarden** — la reimplementación en Rust del servidor de Bitwarden, ligera (≈40 MiB de RAM en idle, ≈80 MiB con varios clientes activos) y funcionalmente compatible con todos los clientes oficiales de Bitwarden (móvil iOS/Android, extensión de navegador en Firefox/Chrome/Brave, app de escritorio Windows/macOS/Linux, CLI). Su rol concreto:

1. **Servir la web vault** en `https://vaultwarden.${DOMAIN_LAN}/` — UI completa para gestionar items (logins, notas seguras, tarjetas, identidades, sends), organizaciones (familiares, "trabajo personal"), colecciones y settings de cuenta. Detrás de Caddy con TLS de la CA interna (ya preparada en `03-red/04-caddy.md`).
2. **Aceptar las APIs de los clientes oficiales** (`/api/*`, `/identity/connect/token`, `/notifications/hub`, `/attachments/*`, `/icons/*`). Estos endpoints **no** pasan por Authelia: los clientes nativos de Bitwarden no entienden cookies de SSO ni redirecciones de portal de login; hablan OAuth2 directo con el servidor. La defensa de fuerza bruta sobre estos endpoints la cubre la jail `[vaultwarden]` de fail2ban (preparada en `04-seguridad/02-fail2ban.md`, se **activa** en este documento).
3. **Servir el panel `/admin`** detrás de Authelia 2FA + token de admin propio (argon2). Es el panel donde se invita a usuarios, se ven sesiones activas, se purgan tokens y se gestionan organizaciones. La jail `[vaultwarden-admin]` añade banear cualquier intento de tokens incorrectos sobre ese endpoint.
4. **Persistir todo en SQLite** (`/data/db.sqlite3`) sobre `hd2t`, con snapshot consistente vía `VACUUM INTO` antes de cada Borg run (Fase 7).
5. **Loguear a fichero** (`/data/vaultwarden.log`) con `LOG_LEVEL=info`, formato consumible por fail2ban (las jails ya tienen su `failregex` versionado en `02-fail2ban.md`).

Lo que este documento **no** decide:

- **Push notifications nativas** (Bitwarden Push Relay vía Bitwarden Identity Service). Desde 2024, los clientes oficiales requieren credenciales `PUSH_INSTALLATION_ID` + `PUSH_INSTALLATION_KEY` registradas en `https://bitwarden.com/host/` para recibir notificaciones push reales (cambios de items, sincronización en tiempo real). El homelab puede prescindir: los clientes hacen *poll* periódico (cada 30 min por defecto) y la sincronización en tiempo real funciona vía WebSocket cuando el cliente está abierto. Reabrible si el operador necesita push real (sección "Decisiones que no se toman").
- **Notificaciones por email** (recuperación de contraseña, verificación de cambios, hints, invitaciones a organizaciones). Igual que Authelia (`04-seguridad/01-authelia.md`), Vaultwarden se configura con SMTP apuntando a `mailrise:8025` (Fase 11) **pero deshabilitado** en este documento (`SMTP_HOST=` vacío). Cuando llegue Fase 11 y Mailrise exista, se activa con un `up -d --force-recreate` tras dos líneas en `.env`.
- **OIDC SSO contra Authelia** (Authelia 4.38+ como IdP, Vaultwarden 1.32+ como cliente OIDC). Es **reabrible**: hoy se usa `forward_auth` en el panel `/admin` (suficiente y simple) y el login del web vault queda con la auth nativa de Vaultwarden (email + master password + TOTP propio). Migrar a OIDC añade complejidad en ambas piezas y una sola cuenta sólo lo nota cuando es la cuenta admin del homelab. Diferido.
- **Fido2 / WebAuthn como segundo factor del web vault**. Vaultwarden lo soporta nativamente. Se documenta en "Configuración → Activar 2FA propio del web vault" como **paso recomendado fuerte** después de TOTP, pero no es bloqueante.
- **Sincronización con Bitwarden Cloud**: el homelab es la **única** copia canónica del bóveda; no hay sincronización bidireccional con `vault.bitwarden.com`. Si el operador quiere cobertura de fallback ante pérdida total y *antes* de que termine de configurarse Borg/offsite, se documenta en "Plan de migración" un export `JSON` cifrado al gestor externo (KeePassXC offline). Una vez Borg + offsite estén estables, esa medida se descarta.
- **Admin del fichero de configuración por la UI `/admin`**. El panel `/admin` de Vaultwarden permite escribir variables de entorno en `data/config.json` (que **prevalece** sobre el `.env` del compose). Aquí se **deshabilita** ese override (`DISABLE_ADMIN_TOKEN=false` y se documenta el riesgo): toda la configuración vive en git → `.env`, no en una UI editable que escapa al control de versiones.

Cuando este documento se haya aplicado:

- `https://vaultwarden.${DOMAIN_LAN}/` muestra la web vault con cert de la CA interna; el navegador no protesta si tiene el root instalado.
- El operador crea la **primera cuenta** (signup abierto), entra al `/admin`, inmediatamente desactiva los signups (`SIGNUPS_ALLOWED=false`) y pone su master password con TOTP + WebAuthn como 2FA del web vault.
- Las extensiones de navegador (Firefox, Chrome, móvil) configuradas con `Server URL: https://vaultwarden.lan` sincronizan, autocompletan y guardan logins.
- La jail `[vaultwarden]` está `enabled = true` y `fail2ban-client status vaultwarden` lista la jail activa, leyendo `/mnt/hd2t/apps/vaultwarden/data/vaultwarden.log`.
- Borg respalda `/mnt/hd2t/apps/vaultwarden/` con snapshot consistente de la SQLite vía hook `before_backup`.
- Uptime Kuma (`05-monitorizacion/05-uptime-kuma.md`) tiene un monitor HTTPS sobre `https://vaultwarden.lan/alive` (endpoint público de health) con alerta Telegram + email.

> **Recordatorio de alcance**: Vaultwarden escucha **solo** en la red Docker `homelab` (`expose: 80`). **No publica `ports:` al host**. La única vía de acceso es Caddy. El homelab no abre puertos en el router; los clientes Bitwarden del operador llegan vía LAN o vía Tailscale (cuando `05-tailscale.md` esté activo, los clientes apuntan a `https://vaultwarden.lan` también desde fuera de casa, gracias a MagicDNS y al cert tailnet sirviendo `pi.${TAILNET_DOMAIN}`). **No** se publica Vaultwarden a Internet.

---

## Requisitos Previos

- **Fase 2** completa: Docker Engine + Compose v2; red `homelab` en `172.30.10.0/24`; convenciones `stacks/<svc>/`; `.env` global con `TZ`, `PUID`, `PGID`, `DOMAIN_LAN=lan`, `LAN_IP=192.168.1.10`.
- **Fase 3** completa, en particular:
  - Pi-hole con el comodín `address=/lan/192.168.1.10` (cubre automáticamente `vaultwarden.${DOMAIN_LAN}` sin tocar Pi-hole).
  - Caddy desplegado y los snippets `(lan_tls)`, `(security_headers)`, `(healthcheck)` definidos en `Caddyfile`.
- **Fase 4** completa, en particular:
  - Authelia desplegado con el snippet `(authelia_two_factor)` en `stacks/caddy/conf.d/01-authelia.caddy` y la regla en `configuration.yml`:
    ```yaml
    - domain: 'vaultwarden.${DOMAIN_LAN}'
      resources:
        - '^/admin.*$'
      policy: two_factor
    # (la regla por defecto deja el resto del host en bypass — los
    #  clientes Bitwarden hablan directos con la app, no con el portal.)
    ```
  - `fail2ban` configurado con las jails `[vaultwarden]` y `[vaultwarden-admin]` **preparadas pero `enabled = false`** (`02-fail2ban.md`); este documento las activa.
- **Fase 7** completa: Borgmatic operativo con `homelab.backup=true` como discriminador de qué stacks entran. La SQLite se respaldará con un hook `before_backup` definido aquí.
- **Operador** con la **CA interna instalada** en navegador, móvil y extensiones de Bitwarden (los clientes Bitwarden validan TLS estrictamente; sin la CA, no conectan; ver `03-red/04-caddy.md` → "Instalar el root CA en los clientes" para el procedimiento por sistema).
- Disco `hd2t` montado en `/mnt/hd2t` con al menos **1 GiB** libre reservado para Vaultwarden (la SQLite + adjuntos de un usuario individual rondan 50–200 MiB; el margen cubre años de uso intensivo). Los datos viven en `/mnt/hd2t/apps/vaultwarden/`.
- Una contraseña fuerte (≥ 24 caracteres, generada con `openssl rand -base64 30` o con KeePassXC offline) para el **admin token**: el operador la teclea **una vez** al hashear con Argon2id. La pierda en claro tras hashearla; la mantiene en un sobre cerrado o en KeePassXC offline (no en el propio Vaultwarden — autorreferencial: ver `07-backups/01-estrategia-backup.md`, "Anti-patrón explícitamente prohibido").

Comprobaciones rápidas:

```bash
# La red Docker compartida existe
docker network inspect homelab --format '{{.Name}}' | grep -q '^homelab$' && echo ok

# Caddy y Authelia están corriendo y sanos
docker ps --filter name=caddy --filter name=authelia --format '{{.Names}} {{.Status}}'

# vaultwarden.lan resuelve al IP de la Pi (gracias al comodín de Pi-hole)
dig +short vaultwarden.lan @192.168.1.2
# 192.168.1.10

# Espacio en hd2t
df -h /mnt/hd2t | awk 'NR==2 {print $4 " libres"}'

# fail2ban presente y las jails preparadas
sudo fail2ban-client status | grep -E 'Number of jail|jail list'
sudo grep -E '^\[vaultwarden' /etc/fail2ban/jail.d/20-vaultwarden.local
# [vaultwarden]
# [vaultwarden-admin]
```

---

## Decisión: imagen y versión

Vaultwarden se distribuye desde Docker Hub (`vaultwarden/server`) con builds multi-arch (`amd64`, `arm64`, `armv7`, `armv6`). En la Pi 5 (aarch64) se usa el manifest `arm64`.

| Tag | Cuándo usar | Decisión aquí |
|---|---|---|
| `latest` | Demos. | Descartado (convención de Fase 2). |
| `alpine` | Variante con base `alpine`, ~25 % más pequeña. | Descartable: la imagen Debian-slim por defecto pesa ~50 MiB y Vaultwarden compila estáticamente; la diferencia de tamaño no compensa el menor rodaje de la variante alpine en arm64. |
| `1.32.x-alpine` / `1.32.x` | Última `1.32.x` estable. | Aceptable. |
| `1.32.5` (ejemplo) | Versión exacta `MAYOR.MENOR.PARCHE`. | **Aceptado** como compromiso entre reproducibilidad y mantenimiento. |
| `testing` | Builds nightly contra la rama `main` upstream. | Descartado: rompe sin previo aviso schemas de SQLite. |

> **Tag exacto en uso**: `vaultwarden/server:1.32.5`. Si en el momento de aplicar este documento existe una `1.32.x` superior con changelog limpio (sin migraciones de schema en SQLite), se actualiza el tag aquí y en el `docker-compose.yml`, y se anota en el commit. **Nunca `latest`**, **nunca `testing`**.

> **Por qué Vaultwarden y no `bitwardenrs/server` ni el servidor oficial de Bitwarden**. `bitwardenrs/server` fue el nombre original del proyecto antes del rebranding (mediados de 2021); la imagen ya no recibe builds, los pulls deben hacerse contra `vaultwarden/server`. El **servidor oficial de Bitwarden** (`bitwarden/server`, basado en .NET y MSSQL) está pensado para empresa: requiere ~1–2 GiB de RAM solo para arrancar la stack (Identity + API + Admin + Notifications + MSSQL), tiene una matriz de servicios docker-compose con 8+ contenedores y no compila en arm64 sin parches (la imagen oficial sigue x86-only en gran parte). En una Pi 5 con 8 GB y 1–5 usuarios humanos, Vaultwarden cubre el 100 % del caso de uso de los clientes oficiales con un binario único de Rust que se levanta en 2 segundos.

> **Por qué `:1.32.5` y no `:1.32` (una rama "última estable")**. Vaultwarden es un servicio **T1 crítico** del homelab: el operador depende de él para entrar a cualquier otro servicio, incluido el propio panel de admin del router doméstico. Un tag flotante (`:1.32`) que de repente promociona una versión con migración SQLite ascendente puede dejar la SQLite en un estado intermedio si el contenedor se cae a medias. Con un tag exacto (`:1.32.5`) las actualizaciones son **deliberadas**: el operador lee el changelog, hace `borgmatic create --tag pre-vaultwarden-upgrade`, edita el tag, `up -d`, valida que la SQLite no migra incompatible. Watchtower está **deshabilitado** (`com.centurylinklabs.watchtower.enable: "false"`) para este stack en concreto.

---

## Decisión: cómo se expone Vaultwarden

Vaultwarden corre un servidor Rocket (Rust) que escucha por defecto en `:80` dentro del contenedor (HTTP, sin TLS — el TLS lo termina Caddy delante). Desde 1.29.x, el endpoint WebSocket (`/notifications/hub`) ya no requiere un puerto separado (`:3012`): comparte el mismo `:80` y Rocket multiplexa.

| Opción | Cómo se ve | Discusión |
|---|---|---|
| `network_mode: host` | Vaultwarden ata `:80` directamente. | Choca con Caddy (que ya ata `:80`). Descartado. |
| Bridge `homelab` con `ports: ["80:80"]` | Acceso directo desde la LAN sin pasar por Caddy. | Vaultwarden quedaría sirviendo HTTP plano (sin TLS) en `192.168.1.10:80`. Los clientes Bitwarden **rechazan** servidores sin HTTPS. Descartado. |
| Bridge `homelab` con `expose: 80`, **sin `ports:`** | Vaultwarden alcanzable solo dentro de la red Docker, vía DNS (`vaultwarden:80`). Caddy hace `reverse_proxy http://vaultwarden:80`. | Termina TLS en Caddy con la CA interna. Es el patrón establecido en Fase 3 para todos los servicios web del homelab. **Aceptado**. |

Resultado: `expose: 80` en el compose (no `ports:`), un drop-in en `stacks/caddy/conf.d/40-vaultwarden.caddy` que hace `reverse_proxy http://vaultwarden:80`, y todo el tráfico externo pasa por `https://vaultwarden.${DOMAIN_LAN}/` con cert de la CA interna.

> **Sobre el nombre `vaultwarden` vs `bitwarden`**. Caddy resuelve por nombre de contenedor en la red Docker; el `container_name` del compose se llama `vaultwarden` y, por simetría, el host LAN también es `vaultwarden.lan` (no `bitwarden.lan`). Eso evita confusión cuando el operador documenta o hace troubleshooting. Los **clientes** se llaman Bitwarden (la marca de las apps oficiales), pero el **servidor** se llama Vaultwarden — la documentación lo respeta.

> **Sobre WebSocket**. Vaultwarden 1.29+ multiplexa el WebSocket en `:80`. Caddy lo proxea sin directiva extra (`reverse_proxy` detecta el `Upgrade` automáticamente). Si en el futuro el operador degrada a una versión < 1.29, el drop-in necesita un bloque adicional `handle_path /notifications/hub { reverse_proxy http://vaultwarden:3012 }` y el compose `expose: [80, 3012]`. Documentado en "Errores frecuentes".

---

## Decisión: usuario, capabilities y hardening

La imagen oficial de Vaultwarden corre **como root** (UID 0) por dos motivos:

1. El binario `vaultwarden` ata `:80` (puerto privilegiado) — y el setuid se hace en el `entrypoint` de la imagen.
2. La imagen no expone `PUID`/`PGID` y, a diferencia de imágenes de LinuxServer.io, no se reasigna a UID arbitrario en runtime.

Este hecho está documentado en `01-sistema/04-estructura-directorios.md` (tabla "Vaultwarden corre como root. Se mitiga con `read_only`, `cap_drop` y `no-new-privileges` en su compose"). Las mitigaciones que aplica este documento:

| Hardening | Qué aporta | Implementación en compose |
|---|---|---|
| `read_only: true` en el FS raíz | Cualquier escritura en directorios distintos de los volúmenes montados (`/data`) falla. Un binario malicioso que se descargue en `/tmp` no puede ejecutarse desde un FS no escribible. | `read_only: true` + `tmpfs: ["/tmp:size=64m,mode=1777"]` (Rocket vuelca uploads temporales a `/tmp`). |
| `cap_drop: [ALL]` y `cap_add: [NET_BIND_SERVICE, CHOWN, SETUID, SETGID, FOWNER, DAC_OVERRIDE]` | Quita las 30+ capabilities por defecto, mantiene solo lo mínimo para atar `:80` y para que el entrypoint pueda chownear `/data` si fuera necesario. | Sección `cap_drop` + `cap_add` del compose. |
| `security_opt: ["no-new-privileges:true"]` | Si un proceso del contenedor intenta ejecutar un binario setuid (escalada vía `/usr/bin/passwd`, `mount`, etc.), el kernel lo bloquea. | Sección `security_opt` del compose. |
| Sin `ports:` al host | El contenedor solo es alcanzable desde la red Docker `homelab`. La superficie expuesta a la LAN es **Caddy**, no Vaultwarden. | `expose: 80`, sin `ports:`. |
| Imagen fija `:1.32.5`, sin Watchtower | Las actualizaciones son deliberadas tras `borgmatic create --tag pre-vw-upgrade`. | `com.centurylinklabs.watchtower.enable: "false"`. |
| `homelab.role: "secrets-store"` y `homelab.backup: "true"` | Borgmatic incluye este stack como **prioridad alta** (T1) y Prometheus puede filtrar el rol para alertas específicas. | Sección `labels` del compose. |

> **¿Por qué no `user: 65534:65534` (nobody:nogroup)?**. Vaultwarden necesita atar `:80` (puerto privilegiado) y aunque `cap_add: [NET_BIND_SERVICE]` sería suficiente teóricamente, el entrypoint hace varios `chown` en arranque que requieren UID 0 efectivo. Forzar `user:` rompe el arranque en la primera ejecución (el operador ve `Permission denied` en los logs). Se acepta el patrón "root con cap_drop ALL + capabilities mínimas" que es el estándar para imágenes que no soportan UID arbitrario.

> **¿Por qué no `userns_remap` a nivel de Docker daemon?**. Reasignar UIDs del contenedor a un rango no privilegiado del host (`/etc/subuid`) sería ideal pero rompe **todos** los bind mounts del homelab (cada UID tendría que renumerarse). Es una decisión global del daemon, no por contenedor. Diferida a Fase 12+ si el homelab evoluciona hacia rootless Docker.

---

## Decisión: persistencia y base de datos

Vaultwarden 1.x soporta tres backends de base de datos: **SQLite** (default), **MySQL/MariaDB** y **PostgreSQL**. Para 1–5 usuarios humanos:

| Opción | Pros | Contras | Veredicto |
|---|---|---|---|
| SQLite (`/data/db.sqlite3`) | Cero piezas adicionales, snapshot consistente con `VACUUM INTO`, archivo único portable, ya soportado por Borg vía hook. | Worse para >100 usuarios concurrentes; no escala horizontalmente. | **Aceptado**: el homelab no llega ni cerca del límite. |
| MariaDB/MySQL | Mejor concurrencia, replicación, dump con `mysqldump`. | Otro contenedor a mantener, otra contraseña, otro consumo de RAM (~150–200 MiB). | Sobreingeniería para 1–5 usuarios. Descartado. |
| PostgreSQL | Igual que MariaDB, plus excelente recovery point. | Idem; además, Vaultwarden con Postgres es menos rodado que con MariaDB en producción Vaultwarden. | Descartado. |

Resultado: SQLite en `/mnt/hd2t/apps/vaultwarden/data/db.sqlite3`. Vaultwarden usa `journal_mode=WAL` por defecto, lo que mantiene la base consistente durante un `cp` simple, pero el **patrón canónico** para snapshot de SQLite con escrituras concurrentes es `VACUUM INTO 'fichero.sqlite3'` (atómico, no requiere parar el contenedor). El hook `before_backup` de Borgmatic ejecuta ese `VACUUM INTO` antes de cada run.

> **Por qué **no** parar el contenedor para hacer backup**. Vaultwarden con SQLite + WAL + `VACUUM INTO` permite snapshots online consistentes; parar el contenedor cada noche para Borg implica `down`time del servicio durante 5–10 min. Para un servicio donde un cliente Bitwarden puede pedir login en cualquier momento (familia, trabajo desde casa), ese downtime es innecesario. El hook hace `docker exec vaultwarden sqlite3 /data/db.sqlite3 'VACUUM INTO ...'` y Borg respalda el snapshot en lugar del fichero vivo.

---

## Stack: `stacks/vaultwarden/`

### Layout en disco

| Ruta | Soporte | Contenido |
|---|---|---|
| `stacks/vaultwarden/docker-compose.yml` | microSD (git) | Stack. |
| `stacks/vaultwarden/.env.example` | microSD (git) | Plantilla con `ADMIN_TOKEN`, `DOMAIN`, `SMTP_*`, etc. |
| `stacks/vaultwarden/.env` | microSD (NO git) | Versión rellena con el `ADMIN_TOKEN` real (hash argon2id). Modo `0600`. |
| `stacks/caddy/conf.d/40-vaultwarden.caddy` | microSD (git) | Drop-in del bloque LAN para `vaultwarden.${DOMAIN_LAN}`. |
| `stacks/vaultwarden/scripts/borg-pre-backup.sh` | microSD (git) | Hook `before_backup`: snapshot consistente de SQLite con `VACUUM INTO`. |
| `/mnt/hd2t/apps/vaultwarden/data/` | hd2t | SQLite (`db.sqlite3` + WAL/SHM), adjuntos (`attachments/`), sends (`sends/`), iconos cacheados (`icon_cache/`), claves RSA del JWT (`rsa_key.*`), `vaultwarden.log`. |
| `/mnt/hd2t/apps/vaultwarden/snapshots/` | hd2t | Salida de `VACUUM INTO`; entrada de Borg. **No** se versiona, **no** se guarda fuera del backup. |

### `stacks/vaultwarden/docker-compose.yml`

```yaml
# Vaultwarden — gestor de contraseñas autohospedado.
# Convenciones: ver docs/02-docker/02-estructura-compose.md y docs/11-productividad/01-vaultwarden.md.

name: vaultwarden

services:
  vaultwarden:
    image: vaultwarden/server:1.32.5
    container_name: vaultwarden
    hostname: vaultwarden
    restart: unless-stopped

    environment:
      TZ: ${TZ}

      # URL canónica del servicio. Vaultwarden la usa para construir enlaces
      # absolutos (emails, recuperación de password, URIs OIDC). DEBE incluir
      # el esquema https:// y el path raíz vacío.
      DOMAIN: https://vaultwarden.${DOMAIN_LAN}

      # SQLite por defecto. No se define DATABASE_URL: Vaultwarden lo crea
      # solo en /data/db.sqlite3 si no existe.

      # Hash argon2id del admin token. Generado en host con:
      #   docker run --rm -it vaultwarden/server:1.32.5 /vaultwarden hash
      # Se introduce el password en claro y la imagen devuelve el hash.
      # ATENCIÓN: el hash contiene `$` que YAML interpola; se escapan como `$$`.
      ADMIN_TOKEN: ${ADMIN_TOKEN}

      # Cierra signups tras crear la primera cuenta admin.
      # Inicialmente debe ser `true` para crear la cuenta del operador, y
      # se cambia a `false` antes de invitar a familiares (sección "Configuración").
      SIGNUPS_ALLOWED: ${SIGNUPS_ALLOWED:-false}
      SIGNUPS_VERIFY: "false"
      INVITATIONS_ALLOWED: "true"

      # Web vault habilitada (UI completa servida por el binario).
      WEB_VAULT_ENABLED: "true"

      # WebSocket multiplexado en :80 (1.29+). No se necesita puerto separado.
      WEBSOCKET_ENABLED: "true"

      # Logging a fichero para fail2ban (`02-fail2ban.md`).
      LOG_FILE: /data/vaultwarden.log
      LOG_LEVEL: info
      EXTENDED_LOGGING: "true"
      LOG_TIMESTAMP_FORMAT: "%Y-%m-%d %H:%M:%S.%3f"

      # IP del cliente vista por Vaultwarden. Tras Caddy, los clientes llegan
      # con la IP del contenedor de Caddy; Vaultwarden honra X-Real-IP.
      IP_HEADER: X-Real-IP

      # SMTP: deshabilitado hasta Mailrise (Fase 11). Vaultwarden tolera estas
      # variables sin SMTP definido; las invitaciones a usuarios se generan
      # como URL que el operador comparte fuera de banda.
      SMTP_HOST: ""
      SMTP_FROM: "vaultwarden@${DOMAIN_LAN}"
      SMTP_FROM_NAME: "Vaultwarden Homelab"

      # Push notifications nativas: deshabilitado (decisión documentada).
      PUSH_ENABLED: "false"

      # Hardening del panel /admin: el panel SIEMPRE requiere ADMIN_TOKEN; este
      # flag bloquea ADEMÁS escrituras a config.json desde la UI.
      DISABLE_ADMIN_TOKEN: "false"
      DISABLE_ICON_DOWNLOAD: "false"

      # Sesiones largas para que el operador no teclee master password cada vez.
      # 30 días con master password validation cada 30 min en el cliente.
      EMAIL_TOKEN_SIZE: "8"

      # Yubikey / Duo / Fido2: WebAuthn nativo está siempre activo; no se fuerza
      # aquí, lo activa cada usuario en su perfil.

    networks:
      - homelab

    # NO `ports:`. Acceso solo vía Caddy en la red `homelab`.
    expose:
      - "80"

    volumes:
      # Estado: SQLite, adjuntos, sends, icon cache, claves RSA, logs.
      - /mnt/hd2t/apps/vaultwarden/data:/data

    # Hardening (sección "Decisión: usuario, capabilities y hardening").
    read_only: true
    tmpfs:
      - /tmp:size=64m,mode=1777
      - /var/run:size=8m,mode=0755

    cap_drop:
      - ALL
    cap_add:
      - NET_BIND_SERVICE
      - CHOWN
      - SETUID
      - SETGID
      - FOWNER
      - DAC_OVERRIDE

    security_opt:
      - no-new-privileges:true

    healthcheck:
      # /alive es público (200 OK) cuando Rocket está sirviendo.
      test: ["CMD-SHELL", "wget -q --spider http://127.0.0.1:80/alive || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s

    labels:
      homelab.role: "secrets-store"
      homelab.backup: "true"
      # Vaultwarden NO se actualiza por Watchtower: las actualizaciones son
      # deliberadas (justificación en "Decisión: imagen y versión").
      com.centurylinklabs.watchtower.enable: "false"

networks:
  homelab:
    external: true
```

### `stacks/vaultwarden/.env.example`

```bash
# stacks/vaultwarden/.env.example
# Variables específicas del stack Vaultwarden.
# Las generales (TZ, DOMAIN_LAN) viven en el .env GLOBAL.
#
# Para generar el ADMIN_TOKEN (Argon2id):
#   docker run --rm -it vaultwarden/server:1.32.5 /vaultwarden hash
#   # Pega aquí la salida COMPLETA, escapando `$` como `$$` (YAML/Compose).
ADMIN_TOKEN=PEGA_AQUI_EL_HASH_ARGON2ID_CON_DOLARES_ESCAPADOS

# Signups: `true` SOLO para crear la primera cuenta del operador. Cambiar a
# `false` inmediatamente después (ver "Configuración" en el doc).
SIGNUPS_ALLOWED=false
```

### `stacks/caddy/conf.d/40-vaultwarden.caddy`

```caddy
# /etc/caddy/conf.d/40-vaultwarden.caddy — bloque LAN para Vaultwarden.
# Vaultwarden expone su UI + API en http://vaultwarden:80 dentro de `homelab`.
# Documentado en docs/11-productividad/01-vaultwarden.md.
#
# La política de Authelia (`04-seguridad/01-authelia.md` → configuration.yml):
#   - vaultwarden.${DOMAIN_LAN}/admin/*  -> two_factor (snippet authelia_two_factor)
#   - vaultwarden.${DOMAIN_LAN}/         -> bypass (auth nativa de Vaultwarden)
#
# Caddy aplica `import authelia_two_factor` SOLO en `handle /admin*` para no
# romper a los clientes nativos (extensiones, móvil) que no entienden cookies.

vaultwarden.{$DOMAIN_LAN} {
    import lan_tls
    import security_headers
    import healthcheck

    # Cabeceras que Vaultwarden necesita para construir URLs y respetar IP.
    # Definidas como bloque común para reverse_proxy de abajo.
    @websockets {
        header Connection *Upgrade*
        header Upgrade websocket
    }

    # /admin: Authelia 2FA delante. El forward_auth NO interfiere con los
    # endpoints de API porque sólo se importa dentro de este `handle`.
    handle /admin* {
        import authelia_two_factor
        reverse_proxy http://vaultwarden:80 {
            header_up Host {host}
            header_up X-Real-IP {remote_host}
            header_up X-Forwarded-For {remote_host}
            header_up X-Forwarded-Proto {scheme}
        }
    }

    # Resto del host (web vault, /api/*, /identity/*, /notifications/hub,
    # /attachments/*, /icons/*, /alive, /events): reverse_proxy directo,
    # SIN Authelia. La auth la hace Vaultwarden + fail2ban + el TOTP nativo
    # del web vault (que el operador habilita en su perfil).
    handle {
        reverse_proxy http://vaultwarden:80 {
            header_up Host {host}
            header_up X-Real-IP {remote_host}
            header_up X-Forwarded-For {remote_host}
            header_up X-Forwarded-Proto {scheme}
        }
    }
}
```

> **Sobre el orden `handle /admin*` antes de `handle`**. Caddy evalúa los `handle` en orden de aparición; el primero que matchea gana. Poner `/admin*` antes que el `handle` genérico garantiza que ese subpath pasa por Authelia y todo lo demás cae al bypass.

> **Sobre WebSocket**. La directiva `reverse_proxy` de Caddy detecta el `Upgrade: websocket` y proxea el túnel sin configuración extra. El matcher `@websockets` queda definido por si algún día hace falta un `handle @websockets` específico (por ejemplo, para forzar timeouts más altos).

### `stacks/vaultwarden/scripts/borg-pre-backup.sh`

Hook `before_backup` para Borgmatic (`07-backups/02-borgmatic.md`). Toma un snapshot consistente de la SQLite con `VACUUM INTO`, lo deja en `/mnt/hd2t/apps/vaultwarden/snapshots/db.sqlite3` y Borg respalda ese fichero (no la SQLite viva).

```bash
#!/usr/bin/env bash
# Snapshot consistente de la SQLite de Vaultwarden para Borg.
# Idempotente: si Vaultwarden está parado, crea snapshot a partir del fichero
# (consistente porque WAL ya hizo flush en el shutdown). Si está corriendo,
# usa `sqlite3 .. 'VACUUM INTO'` (atómico, sin downtime).
set -euo pipefail

DATA_DIR="/mnt/hd2t/apps/vaultwarden/data"
SNAP_DIR="/mnt/hd2t/apps/vaultwarden/snapshots"
DB_LIVE="${DATA_DIR}/db.sqlite3"
DB_SNAP="${SNAP_DIR}/db.sqlite3"

mkdir -p "$SNAP_DIR"
chmod 0750 "$SNAP_DIR"

if [[ ! -f "$DB_LIVE" ]]; then
    echo "vaultwarden: no hay db.sqlite3 todavía (primer arranque?), skip."
    exit 0
fi

# Limpia snapshot anterior (Borg ya lo respaldó si existía).
rm -f "$DB_SNAP" "${DB_SNAP}-wal" "${DB_SNAP}-shm"

if docker ps --filter name=vaultwarden --filter status=running --format '{{.Names}}' | grep -q '^vaultwarden$'; then
    # Vaultwarden corriendo: snapshot online vía VACUUM INTO.
    docker exec vaultwarden \
        sqlite3 /data/db.sqlite3 \
        ".timeout 30000" \
        "VACUUM INTO '/data/../snapshots/db.sqlite3'"
    # Permisos coherentes (Borg corre como root, no necesita ajuste).
    echo "vaultwarden: snapshot online creado en $DB_SNAP."
else
    # Vaultwarden parado: cp simple es suficiente (WAL ya quedó cerrado).
    cp -a "$DB_LIVE" "$DB_SNAP"
    echo "vaultwarden: snapshot offline (cp) en $DB_SNAP."
fi
```

> **Por qué `/data/../snapshots/db.sqlite3` desde dentro del contenedor**. Vaultwarden monta `/mnt/hd2t/apps/vaultwarden/data` como `/data`. El path `/data/../snapshots/` resuelve a `/mnt/hd2t/apps/vaultwarden/snapshots/`, que **no** está montado en el contenedor por defecto. Para que el `VACUUM INTO` pueda escribir ahí, hay que montar **también** `snapshots/` en el compose. Alternativa más limpia: añadir `- /mnt/hd2t/apps/vaultwarden/snapshots:/snapshots` al volumen y referenciar `/snapshots/db.sqlite3`.

Versión mejorada del compose (un volumen extra) y del script:

```yaml
# (Añadir al bloque `volumes:` del compose:)
- /mnt/hd2t/apps/vaultwarden/snapshots:/snapshots
```

```bash
# (En borg-pre-backup.sh, sustituir la línea del VACUUM INTO por:)
docker exec vaultwarden \
    sqlite3 /data/db.sqlite3 \
    "VACUUM INTO '/snapshots/db.sqlite3'"
```

> Esta versión del script es la **canónica** y la que se materializa en `git`. La versión "vía `..`" es un fallback documentado por si el operador olvida añadir el volumen.

### Crear los directorios persistentes y desplegar

```bash
# Directorios de datos (idempotente)
sudo install -d -o root -g root -m 0750 /mnt/hd2t/apps/vaultwarden
sudo install -d -o root -g root -m 0750 /mnt/hd2t/apps/vaultwarden/data
sudo install -d -o root -g root -m 0750 /mnt/hd2t/apps/vaultwarden/snapshots

# Vaultwarden corre como root: el chown se queda en root:root. El operador
# inspecciona con `sudo` cuando hace falta (ver `04-estructura-directorios.md`).

# 1) Generar el ADMIN_TOKEN (Argon2id). El comando pide el password en stdin.
docker run --rm -it vaultwarden/server:1.32.5 /vaultwarden hash
# ENTER PASSWORD: <pega un password fuerte, p.ej. `openssl rand -base64 30`>
# CONFIRM PASSWORD: <repite>
# ARGON2ID|m=...|t=...|p=4$<salt>$<hash>
# Copiar la línea COMPLETA (empieza por `$argon2id$...`).

# 2) Editar stacks/vaultwarden/.env y pegar el hash escapando `$` como `$$`:
cd /home/homelab/homelab
set -a; source .env; set +a

cp stacks/vaultwarden/.env.example stacks/vaultwarden/.env
chmod 0600 stacks/vaultwarden/.env
# El hash original es `$argon2id$v=19$m=65540,t=3,p=4$<...>` y debe quedar
# en el .env como `$$argon2id$$v=19$$m=65540,t=3,p=4$$<...>`.
# Editar con vim/nano y aplicar el escape (Compose lo des-escapa al parsear).

# 3) Para la PRIMERA cuenta del operador, dejar SIGNUPS_ALLOWED=true en .env.
# Tras crear la cuenta, cambiar a `false` y `up -d --force-recreate`.
sed -i 's/^SIGNUPS_ALLOWED=.*/SIGNUPS_ALLOWED=true/' stacks/vaultwarden/.env

# 4) Materializar el drop-in de Caddy
install -o homelab -g homelab -m 0644 \
    stacks/caddy/conf.d/40-vaultwarden.caddy \
    /mnt/hd2t/apps/caddy/etc/conf.d/40-vaultwarden.caddy

# 5) Materializar el script de pre-backup
sudo install -d -o root -g root -m 0750 \
    /home/homelab/homelab/scripts
sudo install -o root -g root -m 0750 \
    stacks/vaultwarden/scripts/borg-pre-backup.sh \
    /home/homelab/homelab/scripts/vaultwarden-borg-pre-backup.sh

# 6) Validar el Caddyfile (tras añadir el drop-in)
docker exec caddy caddy validate --config /etc/caddy/Caddyfile
# Successful

# 7) Validar el compose con interpolación
docker compose \
    -f stacks/vaultwarden/docker-compose.yml \
    --env-file stacks/vaultwarden/.env \
    config >/dev/null && echo "compose OK"

# 8) Levantar Vaultwarden
docker compose \
    -f stacks/vaultwarden/docker-compose.yml \
    --env-file stacks/vaultwarden/.env \
    up -d

# 9) Recargar Caddy para que aplique el drop-in
docker kill --signal=SIGUSR1 caddy
```

Tras `up -d`:

```bash
docker ps --filter name=vaultwarden
# CONTAINER ID  IMAGE                          STATUS                  PORTS    NAMES
# ...           vaultwarden/server:1.32.5      Up 30 seconds (healthy)          vaultwarden

docker compose -f stacks/vaultwarden/docker-compose.yml logs --tail 30 vaultwarden
# [INFO] vaultwarden::api::core::two_factor: ...
# [INFO] vaultwarden::api::admin: ...
# [INFO] Rocket has launched from http://0.0.0.0:80
```

Comprobación de extremo a extremo desde un cliente con la CA instalada:

```bash
# /alive es público y no requiere auth — sirve para health checks.
curl -sI https://vaultwarden.lan/alive
# HTTP/2 200

# El web vault carga (HTML)
curl -sI https://vaultwarden.lan/
# HTTP/2 200

# /admin redirige a Authelia (302 al portal)
curl -sI https://vaultwarden.lan/admin
# HTTP/2 302
# location: https://auth.lan/?rd=https%3A%2F%2Fvaultwarden.lan%2Fadmin
```

`STATUS=(healthy)` debe llegar en ~30 s. Si se queda `(starting)` o `(unhealthy)`, lo más probable son permisos sobre `/mnt/hd2t/apps/vaultwarden/data` o un `ADMIN_TOKEN` mal escapado (el contenedor entra en un loop de "ADMIN_TOKEN parsing failed"; ver "Errores frecuentes").

---

## Configuración

### 1) Crear la primera cuenta del operador

Con `SIGNUPS_ALLOWED=true` (paso 3 del despliegue), abrir desde un navegador con la CA interna instalada:

```
https://vaultwarden.lan/#/register
```

- Nombre: el del operador (ej. `Pi5 Admin`).
- Email: real (cualquier dominio); Vaultwarden no envía emails de verificación con `SIGNUPS_VERIFY=false`.
- Master password: **muy fuerte** (≥ 20 caracteres). Esta contraseña es **la única** clave de cifrado del bóveda; si se pierde, los datos son irrecuperables (ni siquiera con el `ADMIN_TOKEN` se recupera). Se anota en KeePassXC offline o sobre papel en la caja fuerte ignífuga (idéntico patrón a la passphrase de Borg, `07-backups/01-estrategia-backup.md`).
- Hint: **vacío** (cualquier hint reduce la entropía efectiva).

Tras la creación, **cerrar signups inmediatamente**:

```bash
cd /home/homelab/homelab
sed -i 's/^SIGNUPS_ALLOWED=.*/SIGNUPS_ALLOWED=false/' stacks/vaultwarden/.env

docker compose \
    -f stacks/vaultwarden/docker-compose.yml \
    --env-file stacks/vaultwarden/.env \
    up -d --force-recreate
```

Verificación:

```bash
docker exec vaultwarden printenv SIGNUPS_ALLOWED
# false
```

A partir de aquí, los nuevos usuarios entran **solo por invitación** desde `/admin` o desde una organización.

### 2) Activar 2FA propio del web vault

Aunque el `/admin` esté detrás de Authelia 2FA, el **web vault** (`https://vaultwarden.lan/#/`) usa la auth nativa de Vaultwarden — sin Authelia, por la misma razón que los clientes nativos: las apps Bitwarden no entienden la cookie. Por tanto el operador debe activar 2FA dentro de Vaultwarden:

1. Login en `https://vaultwarden.lan/`.
2. **Account Settings → Security → Two-step Login**.
3. Activar **Authenticator app (TOTP)**:
   - Pulsar "Manage", introducir master password.
   - Vaultwarden muestra un QR + clave en base32.
   - Escanear con Aegis / 2FAS / Bitwarden mismo (en otro dispositivo).
   - Introducir el código de 6 dígitos generado.
   - **Anotar los 5 códigos de recuperación** que muestra Vaultwarden tras activar TOTP. Sin ellos, perder el dispositivo TOTP **bloquea** la cuenta (excepto vía `/admin` → "Disable Two-step Login"; pero eso requiere Authelia, que requiere... pasar por TOTP). Anotar en papel + KeePassXC offline.
4. *Recomendado:* activar **Fido2 WebAuthn** con una llave física (Yubikey, SoloKey) o el WebAuthn integrado del sistema (Touch ID, Windows Hello). Misma sección, "WebAuthn → Manage". Defensa en profundidad real: aunque alguien obtenga master password + TOTP secret offline (escenario de evil-maid muy improbable), no entra sin la llave física.

### 3) Conectar el panel `/admin` con Authelia

El paso ya está cubierto en este documento (drop-in `40-vaultwarden.caddy` + regla en `configuration.yml` de Authelia). Para verificar:

1. En modo incógnito (sin sesión Authelia ni Vaultwarden): `https://vaultwarden.lan/admin`.
2. Caddy redirige al portal Authelia (`https://auth.lan/?rd=...`).
3. Authelia pide email + master password + TOTP.
4. Tras autenticar, Caddy deja pasar al panel; Vaultwarden pide **además** el `ADMIN_TOKEN` (campo input en la primera carga).
5. El operador pega el password en claro (no el hash); Vaultwarden lo verifica contra el hash de `ADMIN_TOKEN` y crea una cookie `VW_ADMIN`.

**Doble candado**: SSO Authelia (algo que sabes + algo que tienes/eres) + `ADMIN_TOKEN` (algo que sabes, distinto de master password). Es deliberadamente paranoico: el panel `/admin` permite invitar usuarios, ver sesiones activas, eliminar cuentas, restablecer passwords. Cualquier acceso indebido aquí es un *blast radius* enorme.

### 4) Configurar los clientes Bitwarden

| Cliente | Configuración |
|---|---|
| **Extensión de navegador (Firefox/Chrome/Brave/Safari)** | Antes de login: pulsar el icono de engranaje arriba a la derecha → **Server URL: `https://vaultwarden.lan`**. Aceptar. Luego login con email + master password + TOTP. |
| **App móvil iOS / Android** | En el splash screen, pulsar el icono de engranaje (arriba a la izquierda en iOS, arriba a la derecha en Android) → **Self-hosted environment** → **Server URL: `https://vaultwarden.lan`**. Dejar el resto vacío. Save. Luego login normal. |
| **App de escritorio (Windows/macOS/Linux)** | Idéntico flujo: engranaje en la pantalla de login → Self-hosted environment → Server URL. |
| **CLI `bw`** | `bw config server https://vaultwarden.lan` antes de cualquier `bw login`. La sesión queda persistida en `~/.config/Bitwarden CLI/`. |

**Importante**: los clientes Bitwarden **validan TLS estrictamente**. Sin la CA interna instalada en el almacén de certificados del sistema (no del navegador), los clientes nativos rechazan la conexión con `Self-signed certificate` o `Unable to connect`. Procedimiento por SO en `03-red/04-caddy.md` → "Instalar el root CA en los clientes". Para iOS y Android, además, hay que activar la confianza en la app Bitwarden:

- **iOS**: `Settings → General → About → Certificate Trust Settings` y habilitar la confianza para "Homelab Internal CA". La app Bitwarden honra esa confianza global.
- **Android 7+**: las apps **no** confían en CAs instaladas por el usuario por defecto. Bitwarden Android es una excepción razonable: instalar el cert vía `Settings → Security → Encryption & credentials → Install a certificate → CA certificate`, y aún así puede requerir reinstalar la app. Si falla, alternativa documentada: usar **Tailscale + cert tailnet**, donde el cert es Let's Encrypt (válido sin instalar nada).

### 5) Activar las jails de fail2ban

Las jails están preparadas en `02-fail2ban.md` con `enabled = false`. Activarlas:

```bash
sudo sed -i '/^\[vaultwarden\]/,/^\[/{s/^enabled\s*=\s*false/enabled  = true/}' \
    /etc/fail2ban/jail.d/20-vaultwarden.local
sudo sed -i '/^\[vaultwarden-admin\]/,/^\[/{s/^enabled\s*=\s*false/enabled  = true/}' \
    /etc/fail2ban/jail.d/20-vaultwarden.local

sudo fail2ban-client reload
sudo fail2ban-client status vaultwarden
# Status for the jail: vaultwarden
# |- Filter
# |  |- Currently failed: 0
# |  |- Total failed:     0
# |  `- File list:        /mnt/hd2t/apps/vaultwarden/data/vaultwarden.log
# `- Actions
#    |- Currently banned: 0
#    |- Total banned:     0
#    `- Banned IP list:

sudo fail2ban-client status vaultwarden-admin
# Status for the jail: vaultwarden-admin (...)
```

Test del filtro contra el log real:

```bash
sudo fail2ban-regex /mnt/hd2t/apps/vaultwarden/data/vaultwarden.log /etc/fail2ban/filter.d/vaultwarden.local
# Lines: N lines, 0 ignored, M matched, K missed
```

Si `M=0` tras varios intentos fallidos reales (test desde un cliente ajeno: 5 logins erróneos en 10 min), revisar:

- `LOG_FILE=/data/vaultwarden.log` está en el `.env` y el fichero existe (`ls -la /mnt/hd2t/apps/vaultwarden/data/vaultwarden.log`).
- `LOG_LEVEL=info` (con `warn` Vaultwarden ofusca usernames y la regex no matchea — ver `02-fail2ban.md`).
- Fechas/horas coinciden (`TZ` en el `.env` global, `LOG_TIMESTAMP_FORMAT` consistente).

### 6) Integrar el snapshot SQLite en Borgmatic

En `07-backups/02-borgmatic.md` se definió `before_backup` como lista de scripts a ejecutar antes del archivo Borg. Añadir:

```yaml
# /etc/borgmatic.d/borgmatic.yaml (sección hooks → before_backup)
before_backup:
  - /home/homelab/homelab/scripts/vaultwarden-borg-pre-backup.sh
  # ... otros hooks (Authelia, Pi-hole, etc.)
```

Verificar:

```bash
sudo borgmatic config validate
# All configs valid

# Test manual del hook
sudo bash /home/homelab/homelab/scripts/vaultwarden-borg-pre-backup.sh
# vaultwarden: snapshot online creado en /mnt/hd2t/apps/vaultwarden/snapshots/db.sqlite3.

ls -lah /mnt/hd2t/apps/vaultwarden/snapshots/
# -rw-------  1 root  root  120K  ...  db.sqlite3
```

El snapshot pasa a Borg en el siguiente run programado (`borgmatic.timer`) y queda incluido en cada archivo.

### 7) Monitor en Uptime Kuma

En `https://uptime.${DOMAIN_LAN}/` añadir un **monitor HTTP(s)**:

| Campo | Valor |
|---|---|
| Friendly Name | `Vaultwarden` |
| URL | `https://vaultwarden.lan/alive` |
| Heartbeat Interval | 60 s |
| Retries | 3 |
| Accepted Status Codes | 200 |
| Notification | Telegram + email (Mailrise cuando exista) |
| Public on status page | Sí (es un servicio de uso humano) |

`/alive` es un endpoint público de Vaultwarden que responde `200 OK` con timestamp; **no** requiere auth, **no** revela información sensible. Es el endpoint canónico para monitorización externa.

### 8) Invitar al primer usuario adicional (familia)

Con `SIGNUPS_ALLOWED=false` y `INVITATIONS_ALLOWED=true`:

1. `https://vaultwarden.lan/admin` → autenticarse con Authelia + ADMIN_TOKEN.
2. **Users → Invite User**.
3. Email del invitado.
4. Vaultwarden genera una URL única `https://vaultwarden.lan/#/accept-emergency?...`.
5. Sin SMTP configurado, Vaultwarden **no** manda email; muestra la URL en pantalla y la guarda en el log. El operador la copia y la envía **por canal seguro** (Signal, AirDrop, etc.).
6. El invitado abre la URL → registra master password → cuenta creada.

Cuando Mailrise (Fase 11) esté activo y `SMTP_HOST=mailrise` se descomente, el flujo se vuelve "Invite User → email automático".

### 9) Crear una organización familiar (opcional)

Para compartir items entre miembros (Wi-Fi de casa, cuentas de streaming compartidas, etc.):

1. Web vault → **Organizations → New Organization**.
2. Nombre: `Familia` (o el que el operador prefiera).
3. Plan: `Free` (Vaultwarden no aplica las limitaciones del plan Free de Bitwarden Cloud; en el self-hosted todo es ilimitado).
4. Tras crearla, **Manage → Collections** y crear colecciones (ej. `Compartido`, `Streaming`, `Banca conjunta`).
5. **Manage → People → Invite User**: invitar a los miembros (ya registrados en el paso 8) y asignarles colecciones.

---

## Almacenamiento

| Ruta | Soporte | Owner:Group | Modo | Contenido |
|---|---|---|---|---|
| `/home/homelab/homelab/stacks/vaultwarden/docker-compose.yml` | microSD | `homelab:homelab` | `0640` | Stack versionado en git. |
| `/home/homelab/homelab/stacks/vaultwarden/.env.example` | microSD | `homelab:homelab` | `0644` | Plantilla versionada. |
| `/home/homelab/homelab/stacks/vaultwarden/.env` | microSD | `homelab:homelab` | `0600` | Contiene `ADMIN_TOKEN` (hash argon2id). **No** versionado. |
| `/home/homelab/homelab/stacks/caddy/conf.d/40-vaultwarden.caddy` | microSD | `homelab:homelab` | `0644` | Drop-in de Caddy. **Versionado**. |
| `/home/homelab/homelab/stacks/vaultwarden/scripts/borg-pre-backup.sh` | microSD | `root:root` | `0750` | Hook de snapshot SQLite. **Versionado**. |
| `/home/homelab/homelab/scripts/vaultwarden-borg-pre-backup.sh` | microSD | `root:root` | `0750` | Versión materializada en `scripts/` (la llama Borgmatic). |
| `/mnt/hd2t/apps/caddy/etc/conf.d/40-vaultwarden.caddy` | hd2t | `homelab:homelab` | `0644` | Drop-in materializado (bind mount, reload por SIGUSR1). |
| `/mnt/hd2t/apps/vaultwarden/data/db.sqlite3` | hd2t | `root:root` | `0600` | **CRÍTICO**: BBDD principal. Cifrado de aplicación (AES-256 con master password de cada usuario), no del fichero. |
| `/mnt/hd2t/apps/vaultwarden/data/db.sqlite3-wal` | hd2t | `root:root` | `0600` | WAL de SQLite. Se respalda junto con `db.sqlite3` (pero `VACUUM INTO` produce un fichero ya consolidado). |
| `/mnt/hd2t/apps/vaultwarden/data/attachments/<user-uuid>/<item-uuid>` | hd2t | `root:root` | `0600` | Adjuntos de items (PDFs, imágenes). Cifrados con la clave del usuario (no de la organización), opacos para el servidor. |
| `/mnt/hd2t/apps/vaultwarden/data/sends/<send-uuid>` | hd2t | `root:root` | `0600` | "Bitwarden Send" — envío seguro de texto/fichero con expiración. Cifrados. |
| `/mnt/hd2t/apps/vaultwarden/data/icon_cache/` | hd2t | `root:root` | `0600` | Iconos de los logins (favicons). **Recreable**: se descargan de los sitios reales bajo demanda. **No se respalda**. |
| `/mnt/hd2t/apps/vaultwarden/data/rsa_key.pem` y `rsa_key.pub.pem` | hd2t | `root:root` | `0600` / `0644` | Claves RSA del JWT de sesiones. Si se pierden, todas las sesiones activas de los clientes se invalidan; los usuarios vuelven a hacer login. **CRÍTICO** para no forzar relogin masivo tras restore. |
| `/mnt/hd2t/apps/vaultwarden/data/vaultwarden.log` | hd2t | `root:root` | `0640` | Log de aplicación. Consumido por fail2ban. **Rota** vía `logrotate.d` (ver "Errores frecuentes"). |
| `/mnt/hd2t/apps/vaultwarden/snapshots/db.sqlite3` | hd2t | `root:root` | `0600` | Snapshot consistente generado por el hook pre-backup. **Sí se respalda** (es la copia que Borg ingiere). |

> **Tamaño**: la SQLite con 1 usuario y ~200 items pesa ~120 KiB; con 5 usuarios y 1000 items combinados, ~2–5 MiB. Los adjuntos pueden crecer libremente (un usuario que guarde scans de DNI, contratos PDF, etc.). El homelab reserva `1 GiB` mínimo en el plan; si se acerca, se sube en el `.env` global con `borgmatic check --repository ...` para validar antes/después.

> **Sobre los permisos `root:root`**. Vaultwarden corre como root dentro del contenedor; al crear ficheros en `/data` (bind mount) los crea como `root:root` desde la perspectiva del host. Coherente con la nota de `04-estructura-directorios.md`: para que Borg lea (corre como root vía systemd) no hace falta cambio. Para que el operador inspeccione (ej. `cat vaultwarden.log`), `sudo`.

---

## Backup

A nivel del repositorio del homelab:

| Artefacto | Estrategia |
|---|---|
| `stacks/vaultwarden/docker-compose.yml`, `.env.example`, `scripts/borg-pre-backup.sh` | Versionados en git. Reproducibles tras un reflasheo. |
| `stacks/caddy/conf.d/40-vaultwarden.caddy` | Versionado en git (se materializa en `/mnt/hd2t/apps/caddy/etc/conf.d/`). |
| `stacks/vaultwarden/.env` (con `ADMIN_TOKEN` real) | **No** versionado. Respaldado por Borg como parte de `/home/homelab/homelab/`. Contiene un hash argon2id; aun así el secreto raíz está fuera (lo recuerda el operador en KeePassXC offline). |
| Decisiones (auth dual web/admin, hardening, snapshot SQLite, política T1) | Documentadas en este fichero. |

A nivel de datos (Borgmatic, Fase 7):

| Ruta | ¿Se respalda? | Por qué |
|---|---|---|
| `/mnt/hd2t/apps/vaultwarden/snapshots/db.sqlite3` | **Sí**, **CRÍTICO** (T1). | Producido por el hook pre-backup (`VACUUM INTO`). Es el fichero consistente que Borg ingiere. |
| `/mnt/hd2t/apps/vaultwarden/data/db.sqlite3` y `*-wal` y `*-shm` | **Excluido** explícitamente del archivo Borg. | Se prefiere el snapshot (consistente). Incluir el `db.sqlite3` "vivo" duplicaría datos y, peor, podría dar un backup inconsistente si Borg lee a mitad de una transacción. |
| `/mnt/hd2t/apps/vaultwarden/data/attachments/` | **Sí**, T1. | Ficheros adjuntos cifrados; sin ellos, los items con adjuntos quedan rotos. |
| `/mnt/hd2t/apps/vaultwarden/data/sends/` | **Sí**, T1. | Bitwarden Sends activos (con expiración). Tamaño marginal. |
| `/mnt/hd2t/apps/vaultwarden/data/rsa_key.pem` y `rsa_key.pub.pem` | **Sí**, T1. | Sin estas claves, todas las sesiones activas tras un restore quedan inválidas y los clientes hacen relogin obligatorio. Recuperarlas evita ese ruido operativo. |
| `/mnt/hd2t/apps/vaultwarden/data/vaultwarden.log` | **Excluido**. | Log operativo; rota localmente, no aporta a disaster recovery. |
| `/mnt/hd2t/apps/vaultwarden/data/icon_cache/` | **Excluido**. | Recreable: Vaultwarden re-descarga iconos bajo demanda. |
| `/mnt/hd2t/apps/vaultwarden/data/config.json` (si existiera) | **Sí**, T1. | Vaultwarden lo crea solo si el operador escribe overrides desde `/admin`. Aquí está deshabilitado por convención (`.env` es la fuente de verdad), pero se respalda por si en algún momento se rehabilita. |

Patrón de exclusión en `borgmatic.yaml` (sección `exclude_patterns`):

```yaml
exclude_patterns:
  - '/mnt/hd2t/apps/vaultwarden/data/db.sqlite3'
  - '/mnt/hd2t/apps/vaultwarden/data/db.sqlite3-wal'
  - '/mnt/hd2t/apps/vaultwarden/data/db.sqlite3-shm'
  - '/mnt/hd2t/apps/vaultwarden/data/icon_cache'
  - '/mnt/hd2t/apps/vaultwarden/data/vaultwarden.log'
  - '/mnt/hd2t/apps/vaultwarden/data/vaultwarden.log.*'
```

Verificación trimestral de restore (Fase 7, calendario Q4 → Vaultwarden, ver `07-backups/03-backup-docker-volumes.md`):

```bash
# 1) Restaurar el último snapshot a un path temporal
sudo borg extract --list \
    /mnt/hd2t/backups/borg::homelab-LATEST \
    mnt/hd2t/apps/vaultwarden/snapshots/db.sqlite3 \
    -o /tmp/restore-test

# 2) Validar la integridad de la SQLite restaurada
sqlite3 /tmp/restore-test/mnt/hd2t/apps/vaultwarden/snapshots/db.sqlite3 \
    "PRAGMA integrity_check;"
# ok

# 3) (Opcional) Levantar un Vaultwarden temporal contra esa SQLite y abrir
#    el web vault en otro puerto para verificar que los items aparecen.
#    Procedimiento detallado en `07-backups/03-backup-docker-volumes.md`.

sudo rm -rf /tmp/restore-test
```

Procedimiento de restore tras pérdida del contenedor (datos intactos en `hd2t`):

```bash
docker compose -f /home/homelab/homelab/stacks/vaultwarden/docker-compose.yml \
    up -d --force-recreate
# Vaultwarden reusa /mnt/hd2t/apps/vaultwarden/data: SQLite + adjuntos + RSA keys
# se preservan. Las sesiones activas de los clientes siguen válidas; ningún
# usuario ha de relogarse.
```

Procedimiento de restore tras pérdida total (reflasheo + restauración Borg):

1. Recrear sistema base (Fase 1), Docker (Fase 2.1), red `homelab` (Fase 2.2), Pi-hole (`02-pihole.md`), Caddy (`04-caddy.md`), Authelia (`01-authelia.md`).
2. Restaurar `/mnt/hd2t/apps/vaultwarden/` desde Borg:
   ```bash
   sudo borg extract /mnt/hd2t/backups/borg::homelab-LATEST \
       mnt/hd2t/apps/vaultwarden
   ```
3. **Renombrar el snapshot** como SQLite viva (porque la viva fue excluida del archivo):
   ```bash
   sudo cp /mnt/hd2t/apps/vaultwarden/snapshots/db.sqlite3 \
           /mnt/hd2t/apps/vaultwarden/data/db.sqlite3
   sudo chown root:root /mnt/hd2t/apps/vaultwarden/data/db.sqlite3
   sudo chmod 0600 /mnt/hd2t/apps/vaultwarden/data/db.sqlite3
   ```
4. Restaurar el repo del homelab y `up -d`:
   ```bash
   docker compose -f stacks/vaultwarden/docker-compose.yml up -d
   ```
5. Verificar `https://vaultwarden.lan/alive` (200), login con master password (los items se descifran client-side; si se ven, el restore es correcto).
6. Reactivar las jails de fail2ban (paso 5 de "Configuración").

> **Punto de no retorno**: si los **clientes** del operador han hecho cambios offline entre el último Borg run y la pérdida de la Pi, esos cambios **se pierden** al restaurar al estado del archivo. Mitigación: `borgmatic.timer` en frecuencia diaria (default Fase 7); RPO máximo = 24 h. Si el operador necesita RPO menor para Vaultwarden específicamente, se puede añadir un timer `vaultwarden-borg-only.timer` cada 6 h que solo respalde este stack (reabrible).

---

## Errores frecuentes y troubleshooting

| Síntoma | Causa probable | Resolución |
|---|---|---|
| Vaultwarden no arranca, log dice `ADMIN_TOKEN parsing failed` o entra en loop | Hash argon2id sin escapar `$` como `$$` en el `.env`. | Editar `stacks/vaultwarden/.env` y duplicar todos los `$` del hash. `up -d --force-recreate`. |
| Cliente Bitwarden (móvil) muestra `Self-signed certificate` y no conecta | La CA interna no está confiada en el sistema operativo (no en el navegador). | Instalar `homelab-internal-ca.crt` por SO (`03-red/04-caddy.md`). En iOS, además, habilitar la confianza en `Certificate Trust Settings`. |
| Cliente Bitwarden (móvil Android) sigue rechazando el cert tras instalar la CA | Android 7+ no confía en CAs de usuario para apps por defecto. | Usar Tailscale (`pi.${TAILNET_DOMAIN}`, cert Let's Encrypt) o aceptar la fricción y reinstalar la app Bitwarden tras instalar el cert. |
| `https://vaultwarden.lan/alive` responde 502 desde Caddy | Caddy y Vaultwarden no comparten la red `homelab` (el contenedor de Vaultwarden no se conectó). | `docker network inspect homelab --format '{{range .Containers}}{{.Name}} {{end}}'` debe listar `vaultwarden`. Si no, comprobar `networks: [homelab]` en el compose y `up -d --force-recreate`. |
| `https://vaultwarden.lan/admin` no redirige a Authelia, o redirige y vuelve loop | El drop-in `40-vaultwarden.caddy` tiene `import authelia_two_factor` fuera del `handle /admin*` (cubre todo el host) o el orden de los `handle` está invertido. | Releer la sección "Stack → drop-in de Caddy". `handle /admin*` debe ir **antes** que el `handle` genérico, y el `import authelia_two_factor` solo dentro del primero. Validar con `caddy validate` y `caddy adapt`. |
| Tras invitar a un usuario, la URL de invitación no llega a su email | `SMTP_HOST` está vacío (Mailrise no desplegado todavía, Fase 11). | Comportamiento esperado. Copiar la URL desde la salida del log o de la UI de admin y enviarla por canal seguro (Signal, etc.). Cuando Mailrise exista, `up -d --force-recreate` con `SMTP_HOST=mailrise`. |
| Login al web vault falla con `Invalid email or password` (siendo correctos) | `LOG_LEVEL=warn` y `EXTENDED_LOGGING=false` ofuscan el motivo real (puede ser TOTP incorrecto, cuenta deshabilitada, etc.). | Subir temporalmente a `LOG_LEVEL=debug` y mirar el log: `docker logs vaultwarden -f`. Volver a `info` tras diagnosticar. |
| `fail2ban` no banea aunque el log tiene "Username or password is incorrect" | `LOG_LEVEL=warn` activa *username obfuscation*; el regex de la jail (`02-fail2ban.md`) deja de matchear. | Mantener `LOG_LEVEL=info`. Validar con `fail2ban-regex` (sección "Configuración → 5"). |
| El log `vaultwarden.log` crece sin parar y llena `hd2t` | No hay logrotate configurado para este fichero. | Crear `/etc/logrotate.d/vaultwarden`:<br>`/mnt/hd2t/apps/vaultwarden/data/vaultwarden.log {`<br>` weekly`<br>` rotate 4`<br>` compress`<br>` missingok`<br>` notifempty`<br>` copytruncate`<br>`}` |
| WebSocket no conecta (sincronización en tiempo real no funciona) | Cliente con cert no aceptado, o versión de Vaultwarden < 1.29 sin volumen `:3012` expuesto. | Verificar versión (`docker inspect vaultwarden --format '{{.Config.Image}}'`). Para 1.29+, basta `expose: 80`. Para versiones antiguas, añadir `expose: [80, 3012]` y `handle_path /notifications/hub { reverse_proxy http://vaultwarden:3012 }` en el drop-in de Caddy. |
| `borgmatic check` se queja de SQLite "no es una base de datos válida" | El snapshot quedó corrupto (proceso interrumpido durante `VACUUM INTO`). | Borrar `/mnt/hd2t/apps/vaultwarden/snapshots/db.sqlite3` y forzar nuevo snapshot: `sudo bash /home/homelab/homelab/scripts/vaultwarden-borg-pre-backup.sh`. Inspeccionar con `sqlite3 ... 'PRAGMA integrity_check;'`. |
| Master password olvidada | No hay recuperación. La master password es la clave de cifrado. | El operador puede crear una cuenta nueva en `/admin` (deshabilitar la antigua) y restaurar items desde un export `JSON` cifrado anterior, **si lo hizo**. Si no hay export, los items son irrecuperables. **Lección operativa**: hacer un export `JSON` cifrado a un USB encriptado tras cada cambio importante; documentar en KeePassXC el passphrase del export. |
| `/admin` pide ADMIN_TOKEN incluso tras autenticarse en Authelia | Comportamiento por diseño (doble candado). | El operador pega la **contraseña en claro** que generó el hash (no el hash). Vaultwarden la verifica contra el hash de `ADMIN_TOKEN` y persiste cookie `VW_ADMIN`. Si la perdió, regenerar `ADMIN_TOKEN` con un password nuevo y `up -d --force-recreate`. |
| `docker logs vaultwarden` muestra `error parsing X-Forwarded-For` | Caddy manda `X-Forwarded-For` con la IP correcta, pero `IP_HEADER=X-Real-IP` espera la directiva `X-Real-IP`. | Verificar que el drop-in de Caddy incluye `header_up X-Real-IP {remote_host}`. |
| Tras subir a una versión nueva (`1.32.5` → `1.33.0`), la SQLite migra y no hay vuelta atrás | Migración de schema upstream irreversible. | Por eso Vaultwarden **no** se actualiza por Watchtower. Antes de cualquier upgrade: `borgmatic create --tag pre-vw-upgrade-X.Y.Z`. Si el upgrade falla, restaurar la SQLite desde el archivo etiquetado. |
| El panel `/admin` muestra "Configuration is currently being managed externally" y los campos están en gris | Es el comportamiento esperado: las variables vienen del `.env`, no de `config.json`. | Para cambiar configuración: editar `.env` + `up -d --force-recreate`, **no** intentar editar desde `/admin`. Es la convención del homelab. |

---

## Decisiones que **no** se toman en este documento

- **Push notifications nativas (Bitwarden Push Relay)**: requiere registrar el self-host en `https://bitwarden.com/host/` y obtener `PUSH_INSTALLATION_ID` + `PUSH_INSTALLATION_KEY`. Vaultwarden lo soporta (`PUSH_ENABLED=true`, `PUSH_RELAY_URI=...`). Hoy no se activa: el caso de uso del homelab (1–5 usuarios humanos) tolera *poll* + WebSocket. Reabrible si llega a haber 10+ usuarios o si el operador depende de updates instantáneas en otro dispositivo.
- **OIDC SSO contra Authelia para el web vault**: documentado como reabrible. Activarlo eliminaría el TOTP nativo de Vaultwarden (lo absorbería Authelia) y unificaría el segundo factor. Pero introduce dependencia dura: si Authelia se rompe, **nadie** puede entrar al web vault — incluido el operador para arreglar Authelia. Hoy se prefiere la auth nativa (independiente y autónoma) precisamente por ese aislamiento.
- **MariaDB / PostgreSQL como backend**: descartados por sobreingeniería. Se reabre si el homelab evoluciona a multi-instancia (improbable) o si SQLite empieza a mostrar contención (improbable < 100 usuarios).
- **WebAuthn obligatorio (Fido2 forzado)**: se documenta como recomendación fuerte pero no se fuerza. Cada usuario decide. La política `enforce_webauthn` no existe en Vaultwarden 1.x; en Vaultwarden 2.x (cuando estable) podría reabrirse.
- **Bitwarden Send con expiración por política**: Vaultwarden permite limitar `SENDS_ALLOWED=false` globalmente. Hoy se deja `true` (caso de uso útil para compartir credenciales temporales con familia/amigos). Reabrible.
- **Export `JSON` cifrado periódico fuera de Borg**: como segunda red de seguridad, el operador podría programar un cron que haga export del web vault a un fichero cifrado en `hd2t/exports/`. Vaultwarden no expone API REST para export del bóveda completo (solo cliente CLI con sesión); automatizarlo requiere `bw` en un contenedor sidecar con sesión persistente. Sobreingeniería para esta versión; si Borg + offsite cubren, no hace falta.
- **Mecanismo de "emergency access" entre miembros**: Vaultwarden lo soporta nativamente (un usuario delega acceso a otro tras X días de inactividad). Se documenta en la UI; configurar políticas concretas es decisión del operador, no del homelab.
- **Limit de tasa (rate limit) propio en Caddy para Vaultwarden**: fail2ban cubre el caso real de fuerza bruta. Un rate limit fino (ej. 10 req/s por IP) podría añadir defensa, pero fragmenta clientes legítimos (sincronización masiva tras un viaje). Diferido a Fase 12+.
- **Métricas Prometheus de Vaultwarden**: el binario no expone `/metrics` nativo. Se podría usar un sidecar `vaultwarden-exporter` (proyectos comunitarios) que parsea la SQLite y publica métricas. Hoy basta con monitor Uptime Kuma + cAdvisor (RAM/CPU del contenedor) + Authelia logs (intentos de login al `/admin`).

---

## Verificación Final

Antes de pasar a `02-bookstack.md`:

| Comprobación | Comando | Resultado esperado |
|---|---|---|
| Stack desplegado y saludable | `docker compose -f stacks/vaultwarden/docker-compose.yml ps` | `vaultwarden ... Up (healthy)` |
| Imagen correcta y fija | `docker inspect vaultwarden --format '{{.Config.Image}}'` | `vaultwarden/server:1.32.5` |
| Conectado a `homelab`, sin `ports:` | `docker port vaultwarden` | (vacío) |
| Caddy lo alcanza por DNS Docker | `docker exec caddy wget -qO- http://vaultwarden:80/alive \| head -1` | `{"...","date":"..."}` |
| `/alive` responde desde la LAN | desde un cliente: `curl -sI https://vaultwarden.lan/alive` | `HTTP/2 200` |
| Web vault carga (HTML) | `curl -sI https://vaultwarden.lan/` | `HTTP/2 200` |
| `/admin` redirige a Authelia | `curl -sI https://vaultwarden.lan/admin` | `HTTP/2 302` con `location: https://auth.lan/?rd=...` |
| Cert hoja firmado por la CA local | `echo \| openssl s_client -connect vaultwarden.lan:443 -servername vaultwarden.lan 2>/dev/null \| openssl x509 -noout -issuer` | `issuer=CN=Homelab Internal CA` |
| Hardening activo | `docker inspect vaultwarden --format '{{.HostConfig.ReadonlyRootfs}} {{.HostConfig.SecurityOpt}}'` | `true [no-new-privileges:true]` |
| Capabilities mínimas | `docker inspect vaultwarden --format '{{.HostConfig.CapDrop}} {{.HostConfig.CapAdd}}'` | `[ALL] [NET_BIND_SERVICE CHOWN SETUID SETGID FOWNER DAC_OVERRIDE]` |
| `SIGNUPS_ALLOWED` cerrado tras crear primera cuenta | `docker exec vaultwarden printenv SIGNUPS_ALLOWED` | `false` |
| 2FA propio del web vault activo | UI: Account Settings → Security → Two-step Login | `Authenticator (TOTP)` activado, opcionalmente WebAuthn |
| Jail `[vaultwarden]` activa | `sudo fail2ban-client status vaultwarden` | `Status for the jail: vaultwarden`, `File list: /mnt/hd2t/apps/vaultwarden/data/vaultwarden.log` |
| Jail `[vaultwarden-admin]` activa | `sudo fail2ban-client status vaultwarden-admin` | idem |
| Filtro de `vaultwarden.local` matchea log real | `sudo fail2ban-regex /mnt/hd2t/apps/vaultwarden/data/vaultwarden.log /etc/fail2ban/filter.d/vaultwarden.local` | `Lines: ... matched: M (M ≥ 1 tras al menos un login fallido de prueba)` |
| Hook pre-backup produce snapshot consistente | `sudo bash /home/homelab/homelab/scripts/vaultwarden-borg-pre-backup.sh; sqlite3 /mnt/hd2t/apps/vaultwarden/snapshots/db.sqlite3 'PRAGMA integrity_check;'` | `vaultwarden: snapshot online creado ...` y `ok` |
| Hook integrado en Borgmatic | `sudo borgmatic config validate; grep vaultwarden-borg-pre-backup /etc/borgmatic.d/borgmatic.yaml` | `All configs valid` y la línea presente |
| Monitor Uptime Kuma activo | UI Uptime Kuma, monitor `Vaultwarden` | verde con latencia < 200 ms |
| Cliente Bitwarden (extensión) sincroniza | abrir extensión, login → "Last sync: just now" | sin errores TLS, items aparecen |
| Datos persistidos tras reboot | `sudo reboot`; tras reconectar: `docker ps --filter name=vaultwarden` | `Up ... (healthy)` sin acción manual; los items siguen ahí |
| Stack en git (sin secretos) | `git status; git ls-files stacks/vaultwarden stacks/caddy/conf.d/40-vaultwarden.caddy` | `docker-compose.yml`, `.env.example`, `scripts/borg-pre-backup.sh`, `40-vaultwarden.caddy` tracked; `stacks/vaultwarden/.env` ignorado |

Cumplido el último punto, el homelab tiene gestor de contraseñas autohospedado con TLS interno, doble candado en `/admin` (Authelia + ADMIN_TOKEN), 2FA nativo en el web vault, fail2ban activo en ambos vectores (login normal y `/admin`), snapshots consistentes de SQLite integrados en Borg, monitor Uptime Kuma con alerta en Telegram + email, y los clientes Bitwarden del operador apuntando a `https://vaultwarden.lan` desde LAN y desde Tailscale. La siguiente puerta es **organizar la documentación del propio homelab** dentro del homelab: Bookstack en `02-bookstack.md`.

---

## Referencias

- [Documento siguiente: `docs/11-productividad/02-bookstack.md`](./02-bookstack.md)
- [Documento relacionado: `docs/03-red/04-caddy.md`](../03-red/04-caddy.md)
- [Documento relacionado: `docs/04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md)
- [Documento relacionado: `docs/04-seguridad/02-fail2ban.md`](../04-seguridad/02-fail2ban.md)
- [Documento relacionado: `docs/05-monitorizacion/05-uptime-kuma.md`](../05-monitorizacion/05-uptime-kuma.md)
- [Documento relacionado: `docs/07-backups/01-estrategia-backup.md`](../07-backups/01-estrategia-backup.md)
- [Documento relacionado: `docs/07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md)
- [Documento relacionado: `docs/01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md)
- [Vaultwarden — Wiki oficial](https://github.com/dani-garcia/vaultwarden/wiki)
- [Vaultwarden — Variables de entorno](https://github.com/dani-garcia/vaultwarden/blob/main/.env.template)
- [Vaultwarden — Imagen Docker oficial (`vaultwarden/server`) en Docker Hub](https://hub.docker.com/r/vaultwarden/server)
- [Vaultwarden — Reverse proxy con Caddy](https://github.com/dani-garcia/vaultwarden/wiki/Proxy-examples)
- [Vaultwarden — Hardening (read_only, cap_drop)](https://github.com/dani-garcia/vaultwarden/wiki/Hardening-Guide)
- [Bitwarden — Self-hosted server URL en clientes](https://bitwarden.com/help/change-client-environment/)
- [SQLite — `VACUUM INTO` para snapshots online](https://www.sqlite.org/lang_vacuum.html#vacuuminto)
