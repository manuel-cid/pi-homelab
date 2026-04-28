# Vaultwarden

## Descripción

Despliegue de **Vaultwarden** ([imagen `vaultwarden/server`](https://github.com/dani-garcia/vaultwarden)) como **gestor de contraseñas** del homelab, compatible con los clientes oficiales de **Bitwarden** (extensión web, escritorio, móvil iOS/Android, CLI `bw`). Inaugura la **Fase 11 — Productividad y Herramientas Personales** y es el **primer servicio del cuadro de "secretos circulantes"**: todos los demás docs del homelab anotan passwords y API keys con la coletilla *"guardar en Vaultwarden cuando esté"* ([`../06-almacenamiento/01-nextcloud.md`](../06-almacenamiento/01-nextcloud.md), [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §4.2 sobre la passphrase de Borg, [`../08-domotica/02-mosquitto.md`](../08-domotica/02-mosquitto.md), [`../09-multimedia/`](../09-multimedia/), etc.).

Vaultwarden es una **reimplementación en Rust** del servidor oficial de Bitwarden, **API-compatible** con todos los clientes que Bitwarden distribuye, pero con un footprint operativo radicalmente menor: un único binario, una BD SQLite y ~50 MB de RAM en idle. Para un homelab de 1–4 humanos es la elección obvia frente al stack oficial (`bitwarden_self-host`), que monta ~10 contenedores .NET y exige >2 GB de RAM solo para arrancar.

Por qué exactamente esta arquitectura, y no otra:

1. **Vaultwarden, no Bitwarden self-host oficial.** El servidor oficial Bitwarden (`bitwarden/self-host`) requiere ~2 GB de RAM, MSSQL, y se actualiza con un script propio que rompe pinning de imagen. Vaultwarden corre en ~50 MB con SQLite, multi-arch (incluye `linux/arm64`), y el operador es libre de pinear `<major>.<minor>.<patch>-alpine` y leer release notes antes de subir. No hay diferencia funcional para el cliente: la API que expone Vaultwarden es la API oficial de Bitwarden, byte-a-byte. Las únicas funciones que Vaultwarden **no** implementa son las pagas (Enterprise SSO/SAML, Directory Connector, Distributed Storage), que en un homelab no aplican. Decisiones equivalentes hechas por Mozilla, Servarr y multitud de homelabbers — la elección llevaba años madura cuando este homelab arrancó.
2. **SQLite, no MariaDB ni PostgreSQL.** Vaultwarden soporta los tres motores. Para 1–4 usuarios humanos con 100–1000 entradas cada uno, el volumen es de **kilobytes** (un SQLite cifrado de ~5 MB tras un año de uso intensivo). SQLite (`features=sqlite`, default de la imagen `vaultwarden/server`) elimina un contenedor de BD, su cron de backups, su `mariadb-upgrade` entre majors y su exposición de puerto interno. El backup pasa de "dump + bind mount" a un solo `sqlite3 .backup` ([`../07-backups/03-backup-docker-volumes.md`](../07-backups/03-backup-docker-volumes.md) §4.5, ya documentado anticipadamente). El día que el homelab tuviera >50 usuarios concurrentes (improbable) se conmutaría a MariaDB; este doc deja la migración como variante opt-in en §13.7.
3. **Detrás de Caddy con CA interna**, **sin Authelia** delante por defecto. La razón es de compatibilidad: los clientes oficiales de Bitwarden (móvil, escritorio, extensión) hablan **OAuth2** + WebSocket contra `/identity/*`, `/api/*`, `/notifications/*` y **no** entienden el flujo de redirecciones de `forward_auth` de Authelia (volverían en cada llamada un 401 con redirect a `auth.lan`, que el cliente no sigue). Es el mismo motivo por el que Nextcloud excepciona `/remote.php/*`. Aquí el cálculo es más drástico: **toda** la API de Vaultwarden es "cliente automático", no humana, así que Authelia se queda fuera del bloque entero. La defensa en profundidad la dan: (a) HTTPS con CA interna desde Caddy, (b) la **propia auth de Vaultwarden** (master password + 2FA TOTP/WebAuthn por usuario, gestionado desde la UI), (c) **Fail2ban** ([`../04-seguridad/02-fail2ban.md`](../04-seguridad/02-fail2ban.md) §6.2) leyendo `/data/vaultwarden.log` y baneando IPs que prueben passwords o tokens de admin a fuerza bruta, y (d) `SIGNUPS_ALLOWED=false` para que ningún tercero pueda crear cuentas aunque alcance la URL.
4. **`ADMIN_TOKEN` con hash Argon2id, almacenado en `.env` (chmod 600).** El panel de administración (`/admin`) es el único path "humano" del servicio. Está protegido con un token único, no con la auth de Authelia (otra vez: para no romper la consistencia con `/api/*`). Desde Vaultwarden 1.30, el token se almacena **hasheado** (`vaultwarden hash`, Argon2id; ver §5.3): aunque alguien lea el `.env`, no obtiene el plaintext. Esto incrementa la barrera contra el peor escenario realista: el `.env` filtrado por una mala configuración de Borgmatic (los hooks pre-backup escriben a `dumps/` con `0700 root:root`, ver [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §3.2). Se documenta también la opción de **deshabilitar el panel admin completamente** (§13.1) cuando el operador no lo necesita ya.
5. **Datos en `hd2t`, en `/mnt/hd2t/services/vaultwarden/data/`.** Coherente con [`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) §4 y con la entrada ya prevista en [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §4 (`sqlite_databases.path: /mnt/hd2t/services/vaultwarden/data/db.sqlite3`). El bind mount completo de `data/` cubre los 6 ficheros críticos:
   - `db.sqlite3` (BD principal: usuarios, organizaciones, ítems cifrados),
   - `rsa_key.pem` y `rsa_key.pub.pem` (firmar JWTs de sesión),
   - `attachments/` (adjuntos de los ítems),
   - `sends/` (Bitwarden Send: archivos efímeros),
   - `config.json` (cambios hechos vía panel `/admin`, sobreescriben las env si están).
6. **Imagen `vaultwarden/server:<version>-alpine`, pinned a release puntual.** Igual que el resto del homelab: nunca `latest`, nunca `<major>` rolling. Misma regla que [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §6.1. Watchtower ([`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md)) **no** auto-actualiza Vaultwarden por dos razones: (a) un major de Vaultwarden puede ejecutar migraciones de SQLite irreversibles en el primer arranque y (b) el `vw_admin` opera con el token Argon2id desde 1.30, que cambió la sintaxis del `.env` — un upgrade ciego desde una versión <1.30 lo dejaría inaccesible. Upgrade manual leyendo el [Changelog de Vaultwarden](https://github.com/dani-garcia/vaultwarden/blob/main/SECURITY.md) y haciendo dump previo (§9 + hook `pre-update` de [`../07-backups/03-backup-docker-volumes.md`](../07-backups/03-backup-docker-volumes.md) §5.5).
7. **WebSockets en el mismo puerto 80**, no en `3012/tcp` aparte. Vaultwarden 1.29+ unifica HTTP y WebSocket en `ROCKET_PORT` (80 por defecto en la imagen). El `3012/tcp` legacy queda **sin abrir**. Caddy `reverse_proxy http://vaultwarden:80` ya hace upgrade WS automáticamente, sin directivas extra. Esto simplifica el `Caddyfile` y elimina la coordinación de dos puertos.
8. **Logging a fichero (`LOG_FILE=/data/vaultwarden.log`) además de stdout.** Vaultwarden por defecto escribe solo a stdout (logs Docker). El **jail Fail2ban** documentado en [`../04-seguridad/02-fail2ban.md`](../04-seguridad/02-fail2ban.md) §6.2 necesita un fichero plano (`logpath`) para hacer `tail -F`. Activar `LOG_FILE` (env oficial, sin coste) materializa el log en `/mnt/hd2t/services/vaultwarden/data/vaultwarden.log` y permite que Fail2ban lo monitorice. Se rota con `logrotate` semanal (§3.5).

> **Alcance de red**: la UI web y la API de Vaultwarden **no** publican puertos al host. Se accede únicamente vía `https://vault.${LAN_DOMAIN}` (Caddy + CA interna) y, una vez completada la fase Tailscale, vía `https://vault.${TS_DOMAIN}`. El homelab opera en LAN + Tailscale, sin exposición a internet, sin Let's Encrypt, sin port forwarding. Los **clientes Bitwarden móviles fuera de casa** se conectan vía Tailscale al hostname `tailnet.ts.net`, exactamente igual que Nextcloud y Jellyfin.

> **Alcance de auth**: Vaultwarden gestiona su propia auth (master password + 2FA por usuario). **No** se sirve detrás de Authelia para no romper los clientes oficiales (extensión, móvil, escritorio, CLI). La **única** capa adicional que se aplica delante de Vaultwarden es Caddy (TLS, security headers) y Fail2ban (ban a nivel de IP). Esto es **conscientemente** menos defensa-en-profundidad que Nextcloud o Bookstack — el contrato lo cierra el cliente Bitwarden con su propia crypto end-to-end (la BD `db.sqlite3` contiene únicamente blobs cifrados con la master password del usuario; ni siquiera el operador root puede leerlos).

---

## Requisitos Previos

- **Sistema base operativo** según Fase 1: usuario `homelab` (UID 1000), `/mnt/hd2t/` montado, directorio `/mnt/hd2t/services/vaultwarden/` ya creado por el bootstrap de [`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) §4.1 (loop "Fase 11 — Productividad", línea `for svc in vaultwarden bookstack ...`).
- **Docker + red `homelab`** según Fase 2: red bridge `homelab` creada (`172.20.0.0/24`, `external: true`), convenciones de Compose ([`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §3 y §5).
- **Caddy desplegado** ([`../03-red/04-caddy.md`](../03-red/04-caddy.md)) con `lan_internal_tls` y `security_headers` operativos. El bloque placeholder `vault.{$LAN_DOMAIN}` ya está comentado en el `Caddyfile` (§4.3 de Caddy). Sin Caddy no hay HTTPS — y **sin HTTPS los clientes Bitwarden rechazan conectarse** (la WebCrypto API exige `secure context`).
- **CA interna de Caddy instalada** en al menos un dispositivo (navegador del operador, móvil iOS/Android), procedimiento §6.5 de Caddy. En iOS, además de instalar el `root.crt` hay que **activarlo manualmente** en `Ajustes → General → Información → Ajustes de confianza de certificados` (paso fácil de olvidar; sin él, la app de Bitwarden falla con "Cannot connect to server").
- **Pi-hole desplegado** ([`../03-red/02-pihole.md`](../03-red/02-pihole.md)) con la posibilidad de añadir un registro DNS local: `vault.${LAN_DOMAIN}` → IP del host donde escucha Caddy.
- **Authelia desplegado** ([`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md)) — **no** se usa delante de Vaultwarden (justificado en §0 punto 3), pero se asume operativo porque el snippet `authelia_proxy` que se referencia en otros docs **no** se importa aquí. Mencionado para que el operador lo **omita conscientemente**.
- **Fail2ban host operativo** ([`../04-seguridad/02-fail2ban.md`](../04-seguridad/02-fail2ban.md)) con el jail `vaultwarden.local` ya **preparado** (en `/etc/fail2ban/jail.d/40-vaultwarden.conf` con `enabled = false`). El último paso de este doc (§7.4) lo activa.
- **Borgmatic operativo** ([`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md)) con el hook `sqlite_databases` ya configurado para `vaultwarden` (línea `path: /mnt/hd2t/services/vaultwarden/data/db.sqlite3` ya presente en §4 de Borgmatic). El hook se ejecuta cada noche y produce un dump consistente con `sqlite3 .backup` antes del snapshot Borg.
- **Watchtower desplegado** ([`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md)). Vaultwarden lleva la etiqueta `com.centurylinklabs.watchtower.enable: "false"` por las razones del §0 punto 6.
- **`ufw` activo** según [`../01-sistema/03-seguridad-base.md`](../01-sistema/03-seguridad-base.md). No se añaden reglas: Vaultwarden no publica puertos al host; el tráfico entra por Caddy.
- **Espacio libre en `hd2t`** ≥ 100 MB es más que suficiente. La BD crece muy lento (~kilobytes por entrada, ~megabytes para una biblioteca grande). Los `attachments/` pueden engordar si el operador sube binarios grandes; **se recomienda no usar Vaultwarden como dropbox**: para ficheros >5 MB, Nextcloud.
- **Comprobaciones rápidas**:
  ```bash
  # Red homelab existe:
  docker network inspect homelab --format '{{(index .IPAM.Config 0).Subnet}}'
  # Esperado: 172.20.0.0/24

  # Caddy está sano:
  docker inspect caddy --format '{{.Name}}: {{.State.Health.Status}}'
  # Esperado: caddy: healthy

  # Pi-hole resuelve vault.lan al host (preparar antes en su UI):
  dig +short @192.168.1.241 vault.lan
  # Esperado: 192.168.1.10  (si no, añadir el registro en Pi-hole y volver)

  # Estructura de directorios y propietario:
  ls -ld /mnt/hd2t/services/vaultwarden
  # Esperado: drwxr-x--- homelab homelab ...

  # vaultwarden hash funciona en local (lo necesitamos en §5.3):
  docker run --rm vaultwarden/server:latest /vaultwarden hash --help >/dev/null 2>&1 \
    && echo "vaultwarden hash OK" || echo "FALLA — versión <1.30, leer §13.6"
  ```

### Decisiones de diseño asumidas

| Decisión | Valor por defecto | Justificación |
|---|---|---|
| Servidor Bitwarden-compatible | **Vaultwarden** | Justificado en §0 punto 1. La alternativa "oficial" (`bitwarden/self-host`) es inviable en una Pi 5 con 8 GB compartidos por ~30 contenedores. |
| Imagen Docker | **`vaultwarden/server`** (oficial del proyecto, repo `dani-garcia/vaultwarden`) | Multi-arch incluyendo `linux/arm64`. Mantenida por el autor del proyecto. **No** se usa la fork `vaultwarden/server:alpine-fluentd` ni similares: añaden dependencias innecesarias. |
| Variante de imagen | **`-alpine`** (suffix) | ~30 MB vs ~120 MB de la variante Debian. Sin musl issues conocidas en Vaultwarden (binario Rust estático). El operador que necesite glibc por una librería externa (raro) puede conmutar a la Debian-based en §13.5. |
| Tag de imagen | **`1.32.5-alpine`** (no `latest`, no `1.32` "rolling minor") | Misma regla del homelab. Cada minor de Vaultwarden puede traer migraciones SQLite (raro pero ha pasado: 1.27 → 1.28 introdujo cambios de schema). Pinning fuerza al operador a leer release notes antes de subir. Watchtower respeta el tag exacto. |
| Política de Watchtower | **`watchtower.enable: "false"`** | Justificado en §0 punto 6 y en [`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §6 (lista de servicios excluidos). Upgrade manual, con dump previo del SQLite (§9). |
| Arquitectura | `linux/arm64` (Pi 5) | Manifest multi-arch oficial. La Pi 5 es nativa 64-bit. |
| Red Docker | **`homelab`** (bridge, [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §4.3). **Sin** `80` ni `3012` publicados al host. | Caddy llega por nombre Docker (`http://vaultwarden:80`). No hay otros consumidores: Vaultwarden no expone API a otros stacks (Bookstack y Authelia no le piden nada). Publicar el puerto duplicaría la entrada y permitiría saltarse Caddy. |
| Modelo de almacenamiento | **Bind mount** `/mnt/hd2t/services/vaultwarden/data/:/data/` (RW) | Patrón estándar del homelab. Bind mount, no named volume — facilita backup directo, ruta predecible. |
| Backend de BD | **SQLite** (default de la imagen) | Justificado en §0 punto 2. WAL mode activo desde Vaultwarden 1.27. |
| Reverse proxy | **Caddy** con `lan_internal_tls` + `security_headers`, **sin** `forward_auth`/Authelia | Justificado en §0 punto 3. La auth la lleva el propio Vaultwarden (master password + 2FA). |
| Hostname interno | **`vaultwarden`** (`container_name`) | Coherente con el placeholder ya escrito en el `Caddyfile` (`reverse_proxy http://vaultwarden:80`). |
| Subdominio LAN | **`vault.${LAN_DOMAIN}`** (típicamente `vault.lan`) | Mismo subdominio que el placeholder de Caddy ([`../03-red/04-caddy.md`](../03-red/04-caddy.md) §4.3). El alias "vault" es estándar en la comunidad Bitwarden/Vaultwarden y corto de teclear en móvil. |
| `DOMAIN` env (`https://vault.${LAN_DOMAIN}`) | **Obligatorio**, sin trailing slash | Vaultwarden lo usa para construir las URLs absolutas de los emails de invitación, los enlaces de "Send" y los OAuth callbacks. Si está mal o ausente, los clientes redirigen a `localhost` (visible en la consola del navegador) y los Sends fallan. |
| `SIGNUPS_ALLOWED` | **`false`** | Cualquiera con acceso de red al host (LAN + Tailscale) podría crear una cuenta y empezar a sondear. El operador crea su cuenta y la(s) de la familia desde el panel `/admin` (§7.3.1) y luego cierra signups para siempre. |
| `INVITATIONS_ALLOWED` | **`true`** (con SMTP deshabilitado) | Permite al operador, ya logueado en su cuenta admin de la UI, invitar a otros usuarios desde "Organizations". Como no hay SMTP saliente (homelab sin MTA), el "email de invitación" se materializa como un enlace que el operador comparte por otro canal (Signal/Telegram). Variante con SMTP en §13.3. |
| `ADMIN_TOKEN` | **`Argon2id` hash** del token, en `.env` chmod 600 | Justificado en §0 punto 4. El **plaintext** se custodia en KeePassXC + papel. Tras login en `/admin`, el operador puede deshabilitar el panel completamente (`ADMIN_TOKEN=`) si no lo necesita corriendo. Variante en §13.1. |
| `WEB_VAULT_ENABLED` | **`true`** | La UI web servida en `/` es la principal vía de gestión humana (la extensión es para el día a día). Desactivarla solo tiene sentido si todo el tráfico humano va por extensión/escritorio (variante §13.2). |
| `WEBSOCKET_ENABLED` | **`true`** (default) | Habilita el WebSocket en el mismo puerto (80) para notificaciones en tiempo real entre clientes (cuando el móvil añade un ítem, la extensión lo ve aparecer en segundos sin polling). Sin coste si no se usa. |
| `IP_HEADER` | **`X-Real-IP`** (Caddy ya lo inyecta) | Sin esto, Vaultwarden registra cada login como viniendo de la IP del contenedor Caddy → Fail2ban banea Caddy. Con `X-Real-IP`, Vaultwarden lee la IP real del cliente (LAN o `100.x.y.z` Tailscale) y los bans funcionan donde tienen que funcionar. |
| `LOG_FILE` | **`/data/vaultwarden.log`** | Justificado en §0 punto 8. Coincide con el `logpath` de [`../04-seguridad/02-fail2ban.md`](../04-seguridad/02-fail2ban.md) §6.2 — pendiente solo de **corregir el typo** del fail2ban doc (`/mnt/hd2t/services/vault/...` debe ser `/mnt/hd2t/services/vaultwarden/...`); este doc materializa la ruta correcta y §7.4 hace el ajuste de fail2ban. |
| `LOG_LEVEL` | **`warn`** | Default razonable. `info` y `debug` solo bajo demanda. `trace` filtra hashes y nunca debe activarse en producción. |
| `EXTENDED_LOGGING` | **`true`** | Añade timestamp y módulo a cada línea — formato esperado por el filtro Fail2ban. |
| `PASSWORD_ITERATIONS` | **`600000`** (PBKDF2-SHA256) | Recomendación OWASP 2023 para PBKDF2 con SHA-256. Vaultwarden por defecto trae `600000` desde 1.30; declararlo explícitamente blinda contra futuros bajadas accidentales del default. |
| `SHOW_PASSWORD_HINT` | **`false`** | El "hint" se muestra públicamente al fallar el master password. Para un homelab de personas que se conocen es ruido; mejor recordar la master password con métodos serios (papel en sobre cerrado). |
| `SMTP_*` | **Sin configurar** (todas las env SMTP vacías) | El homelab no tiene MTA. Sin SMTP, Vaultwarden simplemente no envía emails (las invitaciones se aceptan vía link compartido manualmente, los avisos de seguridad se ven en la UI). Variante con SMTP relay en §13.3. |
| `EMERGENCY_ACCESS_ALLOWED` | **`false`** | Función "trusted contacts can access your vault if you're incapacitated" requiere SMTP para coordinarse. Sin SMTP no funciona. Si el operador la quiere, conmutar a SMTP (§13.3) y a `true`. |
| `SENDS_ALLOWED` | **`true`** | Bitwarden Send (compartir password/archivo efímero con un link). No requiere SMTP. Útil para pasar credenciales puntuales sin Telegram/Signal. Los Sends viven en `data/sends/`, se respaldan con el bind mount. |
| `ORG_CREATION_USERS` | **`""`** (vacío = todos pueden crear orgs) | Para 1–4 usuarios humanos no merece la pena restringir. Si el operador quisiera que solo él pueda crear "Organizations" (compartir con familia), pondría aquí su email. |
| Usuario dentro del contenedor | **UID 1000:1000** (`user:` en compose) | El binario Vaultwarden corre como root por default en la imagen, con `dropuser` interno. Forzar `user: "1000:1000"` desde Compose evita que el bind mount quede con `0:0` tras el primer arranque y se rompa la propiedad esperada por Borg/SQLite hooks. **Patrón coherente con [`../07-backups/03-backup-docker-volumes.md`](../07-backups/03-backup-docker-volumes.md) §6 tabla "ownership esperada".** |
| `cap_drop: ALL` + `cap_add` | **`cap_drop: ALL`**, sin `cap_add` | Vaultwarden escucha en `:80` *dentro* del contenedor (no privilegiado, gracias a Rocket bind to high port → port mapping interno). No necesita ninguna capability. |
| `security_opt: no-new-privileges:true` | **Activado** | Plantilla §6 de [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md). |
| `read_only` | **`false`** | Vaultwarden escribe en `/data/` (BD, attachments, logs). Forzar RO obligaría a tmpfs y rompería los logs. Se deja como variante futura cuando se acepte la complejidad. |
| Healthcheck | **`/alive`** vía `wget`/`curl` | Endpoint canónico que responde `200 OK` con un timestamp. Captura "Vaultwarden arrancó pero la BD está bloqueada" como `unhealthy`. |
| Logs Docker | **`json-file` 10 MB × 3** (heredado del demonio) | Plantilla §6.1 de estructura-compose. La rotación del fichero `vaultwarden.log` la hace `logrotate` host (§3.5). |
| Backup | **SQLite vía hook `sqlite_databases` de Borgmatic** + bind mount `data/` snapshot | Patrón [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §4 (entrada `vaultwarden` ya presente) + [`../07-backups/03-backup-docker-volumes.md`](../07-backups/03-backup-docker-volumes.md) §4.5. Smoke test mensual (M1, M5, M9) según §6.2 de backup-docker-volumes. |
| Hook Watchtower | **No aplica** (Watchtower deshabilitado por etiqueta). Al hacer upgrade manual, se ejecuta antes el script de §9.2. | Coherente con [`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §6 (lista de servicios con `enable=false`). |

---

## 1. Resumen de la arquitectura

```
                            Internet (LAN sin entrante; Tailscale opt-in §13.4)
                              ▲
                              │ - sin tráfico saliente (Vaultwarden no llama
                              │   a "icons.bitwarden.com" si ICON_SERVICE=internal)
                              │ - sin telemetría
                              │
                  ┌───────────┴────────────────────┐
                  │   Pi 5 (host)  192.168.1.x     │
                  │   sin puertos publicados       │
                  └────────────────┬───────────────┘
                                   │
                                   ▼ docker network: homelab (172.20.0.0/24)
        ┌────────────────────────────────────────────────────────────┐
        │                                                            │
        │   ┌─── caddy ───────────────────────────────────────────┐  │
        │   │  vault.${LAN_DOMAIN}  (lan_internal_tls)            │  │
        │   │     reverse_proxy http://vaultwarden:80             │  │
        │   │     header_up X-Real-IP {remote_host}               │  │
        │   │     (sin Authelia, sin forward_auth)                │  │
        │   └─────────────────────┬───────────────────────────────┘  │
        │                         │ HTTP + WS (mismo puerto 80)      │
        │                         ▼                                  │
        │   ┌──────── vaultwarden ───────────────────────────────┐  │
        │   │  image: vaultwarden/server:1.32.5-alpine            │  │
        │   │  user: 1000:1000                                    │  │
        │   │  ROCKET_PORT: 80   (interno)                        │  │
        │   │  WEBSOCKET_ENABLED: true                            │  │
        │   │  no `ports:` publicados                             │  │
        │   │                                                     │  │
        │   │  /data (RW) ─► /mnt/hd2t/services/vaultwarden/data/ │  │
        │   │     ├── db.sqlite3        (BD principal)            │  │
        │   │     ├── db.sqlite3-wal    (write-ahead log)         │  │
        │   │     ├── db.sqlite3-shm                              │  │
        │   │     ├── rsa_key.pem       (firma JWTs sesión)       │  │
        │   │     ├── rsa_key.pub.pem                             │  │
        │   │     ├── attachments/      (adjuntos cifrados)       │  │
        │   │     ├── sends/            (Bitwarden Send)          │  │
        │   │     ├── config.json       (cambios via /admin)      │  │
        │   │     └── vaultwarden.log   (LOG_FILE — fail2ban)     │  │
        │   └─────────────────────────────────────────────────────┘  │
        │                                                            │
        └────────────────────────────────────────────────────────────┘

                                   ▲
                                   │ tail -F vaultwarden.log
                                   │ (lectura en host, no en contenedor)
                  ┌────────────────┴───────────────┐
                  │  Fail2ban (host)               │
                  │  jail: vaultwarden             │
                  │  filter: vaultwarden.local     │
                  │  ban: nftables, allports, 1h   │
                  └────────────────────────────────┘

   Clientes Bitwarden:
   - extensión navegador, escritorio, móvil iOS/Android, CLI `bw`
   - apuntan a "Self-hosted server URL" = https://vault.${LAN_DOMAIN}
   - en LAN: directos
   - fuera de casa: a través de Tailscale → https://vault.${TS_DOMAIN}
```

Lectura clave del diagrama: **Caddy es la única puerta** (TLS + headers + log para Fail2ban del lado de Caddy también, vía `caddy-status` jail). Vaultwarden corre como un único contenedor, **sin BD lateral, sin cache lateral, sin SMTP**. Toda la persistencia es un bind mount. La defensa contra fuerza bruta vive **fuera** del contenedor (Fail2ban), leyendo el log fichero que Vaultwarden materializa por la env `LOG_FILE`.

---

## 2. Plan de variables y archivos

### 2.1. Variables del stack (`.env.example` versionable)

`~/homelab/stacks/vaultwarden/.env.example` (en git, sin secretos):

```env
# ============================================================================
#  Stack: vaultwarden  ([../11-productividad/01-vaultwarden.md])
#  Plantilla — el .env real vive en /mnt/hd2t/services/vaultwarden/.env
# ============================================================================

# --- Identidad & dominio ---------------------------------------------------
LAN_DOMAIN=lan
TS_DOMAIN=tailnet.ts.net   # se rellenará cuando 05-tailscale.md esté listo
DOMAIN=https://vault.${LAN_DOMAIN}

# --- Imagen ----------------------------------------------------------------
VAULTWARDEN_IMAGE=vaultwarden/server:1.32.5-alpine

# --- Permisos y rutas ------------------------------------------------------
PUID=1000
PGID=1000
DATA_PATH=/mnt/hd2t/services/vaultwarden/data
TZ=Europe/Madrid

# --- Política de cuentas ---------------------------------------------------
SIGNUPS_ALLOWED=false
INVITATIONS_ALLOWED=true
ORG_CREATION_USERS=
EMERGENCY_ACCESS_ALLOWED=false
SENDS_ALLOWED=true

# --- Crypto cliente --------------------------------------------------------
PASSWORD_ITERATIONS=600000
SHOW_PASSWORD_HINT=false

# --- Web vault & WebSockets -----------------------------------------------
WEB_VAULT_ENABLED=true
WEBSOCKET_ENABLED=true

# --- Reverse proxy headers -------------------------------------------------
IP_HEADER=X-Real-IP
ROCKET_PORT=80

# --- Logging ---------------------------------------------------------------
LOG_FILE=/data/vaultwarden.log
LOG_LEVEL=warn
EXTENDED_LOGGING=true

# --- Admin panel -----------------------------------------------------------
# Hash Argon2id generado con `vaultwarden hash` (ver §5.3 del doc).
# Empieza por "$argon2id$v=19$m=...". Si vacío, el panel /admin se deshabilita.
ADMIN_TOKEN=

# --- SMTP (opcional, vacío por defecto) ------------------------------------
SMTP_HOST=
SMTP_FROM=
SMTP_USERNAME=
SMTP_PASSWORD=
SMTP_PORT=
SMTP_SECURITY=
```

| Bloque | Por qué versionar |
|---|---|
| `LAN_DOMAIN`, `TS_DOMAIN`, `DOMAIN` | Convención del homelab; sin valor secreto. `DOMAIN` debe sincronizarse con el bloque Caddy. |
| `VAULTWARDEN_IMAGE` | Tag pinned. Cambiarlo se hace mediante PR en el repo, con review. |
| `PUID`/`PGID`/`DATA_PATH`/`TZ` | Convenciones del homelab, sin secretos. |
| Política de cuentas | Decisiones públicas (no son credenciales). El día que el operador "abra" un signup temporal, se hace por PR, queda auditado en git. |
| `PASSWORD_ITERATIONS` | Documenta el target de seguridad. |
| `WEB_VAULT_ENABLED`, `WEBSOCKET_ENABLED` | Decisiones de superficie, no secretos. |
| `IP_HEADER`, `ROCKET_PORT` | Acoplamiento con Caddy. Cambiarlos requiere coordinación. |
| `LOG_FILE`, `LOG_LEVEL`, `EXTENDED_LOGGING` | Acoplamiento con Fail2ban. |
| `ADMIN_TOKEN` (vacío en `.env.example`) | El **plaintext** nunca toca git. El **hash** Argon2id sí podría ir en `.env.example` si quisieramos, pero el principio "el `.env.example` no contiene NADA que no esté en otra parte canónica" es más limpio: lo dejamos vacío y el hash real va al `.env`. |
| Credenciales SMTP | Vacías por defecto (homelab sin SMTP). El día que se rellenen, irán al `.env` real, no aquí. |

### 2.2. `.env` real (`/mnt/hd2t/services/vaultwarden/.env`)

Fuera de git, modo `600 homelab:homelab`. Mismo contenido que `.env.example` **pero**:

- `ADMIN_TOKEN` → hash Argon2id real (generado en §5.3).
- Si el operador activa SMTP en el futuro: las 5 variables `SMTP_*` con valores reales.

Nada más cambia entre `.env.example` y `.env` en este stack — Vaultwarden es uno de los servicios del homelab con **el menor número de secretos circulantes** (un único token, contra los 4–6 de Authelia o los 3 de Nextcloud).

### 2.3. Cómo se inyectan al contenedor

El `docker-compose.yml` referencia `env_file: /mnt/hd2t/services/vaultwarden/.env`. Compose carga **todas** las variables del fichero en el environment del contenedor; Vaultwarden lee directamente del environment (Rocket framework convention). No hay paso intermedio de "render template" como en Authelia.

> **`.env.example` y `.env` deben tener las mismas claves**. Si en una iteración futura el operador añade `SMTP_HOST=` al `.env` para habilitar email, debe añadir también `SMTP_HOST=` al `.env.example`. Política coherente con [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §5.4: "el `.env.example` es el contrato — si tienes algo en `.env` que no está documentado allí, otra persona no podrá reconstruir el stack tras un disaster recovery".

---

## 3. Preparar el árbol de datos

### 3.1. Crear el directorio del stack

```bash
mkdir -p ~/homelab/stacks/vaultwarden
cd ~/homelab/stacks/vaultwarden

# Solo el .env.example y el docker-compose.yml viven aquí.
touch .env.example
touch docker-compose.yml
```

### 3.2. Crear el árbol de datos persistentes del servicio

El directorio `/mnt/hd2t/services/vaultwarden/` ya existe (creado por el bootstrap de [`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) §4 con propietario `homelab:homelab` y modo `750`). Solo hace falta crear el subárbol que Vaultwarden poblará al primer arranque:

```bash
sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/services/vaultwarden/data
sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/services/vaultwarden/data/attachments
sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/services/vaultwarden/data/sends

# El fichero log lo crea Vaultwarden al primer arranque, pero pre-creamos
# vacío para que Fail2ban no se queje al hacer su primera comprobación de
# logpath antes de que Vaultwarden haya recibido tráfico.
sudo install -m 640 -o homelab -g homelab /dev/null \
    /mnt/hd2t/services/vaultwarden/data/vaultwarden.log
```

### 3.3. Tabla resumen de permisos

| Path | Owner | Modo | Por qué |
|---|---|---|---|
| `~/homelab/stacks/vaultwarden/` | `homelab:homelab` | `750` | Repo de configuración (git). |
| `~/homelab/stacks/vaultwarden/.env.example` | `homelab:homelab` | `644` | Plantilla pública. |
| `~/homelab/stacks/vaultwarden/docker-compose.yml` | `homelab:homelab` | `644` | YAML versionado. |
| `/mnt/hd2t/services/vaultwarden/` | `homelab:homelab` | `750` | Bind mount root. |
| `/mnt/hd2t/services/vaultwarden/.env` | `homelab:homelab` | `600` | Secretos. |
| `/mnt/hd2t/services/vaultwarden/data/` | `homelab:homelab` | `750` | BD + adjuntos. |
| `/mnt/hd2t/services/vaultwarden/data/db.sqlite3` | `homelab:homelab` | `640` (creado por Vaultwarden) | BD principal. |
| `/mnt/hd2t/services/vaultwarden/data/rsa_key*.pem` | `homelab:homelab` | `640` | Claves de firma JWT. |
| `/mnt/hd2t/services/vaultwarden/data/vaultwarden.log` | `homelab:homelab` | `640` | Fail2ban lo lee como root, no necesita más. |

### 3.4. Permisos para el proceso del contenedor

El contenedor corre con `user: "1000:1000"` (declarado en el `docker-compose.yml` §4). El UID 1000 (`homelab` en el host) coincide con el owner del bind mount: Vaultwarden puede leer y escribir, sin `chown` masivo dentro del contenedor (la imagen no lo hace por defecto, lo cual es **deseable** — un `chown -R` del contenedor sobre 1 GB de adjuntos es un cuello de botella en cada arranque).

### 3.5. `logrotate` del log de Vaultwarden

Vaultwarden no rota su `vaultwarden.log` por sí mismo; crece indefinidamente. Crear `~/homelab/etc/logrotate.d/vaultwarden`:

```text
/mnt/hd2t/services/vaultwarden/data/vaultwarden.log {
    weekly
    rotate 8
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
    su homelab homelab
    create 0640 homelab homelab
}
```

Instalar y verificar:

```bash
sudo install -m 644 -o root -g root \
    ~/homelab/etc/logrotate.d/vaultwarden \
    /etc/logrotate.d/vaultwarden

# Validación dry-run (no rota, solo dice qué haría):
sudo logrotate -d /etc/logrotate.d/vaultwarden
```

| Decisión | Por qué |
|---|---|
| `weekly` + `rotate 8` | 8 semanas de logs comprimidos. ~2 meses de auditoría es suficiente para investigar un incidente; lo demás vive en Borg. |
| `copytruncate` | Vaultwarden mantiene el file descriptor abierto (`tail -F` style desde la app); `copytruncate` evita un reload del contenedor para reabrir el log. Coste: una pequeña ventana de duplicado. |
| `compress + delaycompress` | El log más reciente queda sin comprimir (`vaultwarden.log.1`) por si Fail2ban lo lee en transición. |
| `su homelab homelab` | logrotate corre como root pero los ficheros pertenecen al usuario `homelab`. |

---

## 4. `docker-compose.yml`

`~/homelab/stacks/vaultwarden/docker-compose.yml`:

```yaml
name: vaultwarden

services:
  vaultwarden:
    image: ${VAULTWARDEN_IMAGE}
    container_name: vaultwarden
    hostname: vaultwarden
    restart: unless-stopped
    user: "${PUID}:${PGID}"
    env_file: /mnt/hd2t/services/vaultwarden/.env
    environment:
      # Identidad y dominio
      DOMAIN: ${DOMAIN}
      ROCKET_PORT: ${ROCKET_PORT}
      TZ: ${TZ}

      # Política de cuentas
      SIGNUPS_ALLOWED: ${SIGNUPS_ALLOWED}
      INVITATIONS_ALLOWED: ${INVITATIONS_ALLOWED}
      ORG_CREATION_USERS: ${ORG_CREATION_USERS}
      EMERGENCY_ACCESS_ALLOWED: ${EMERGENCY_ACCESS_ALLOWED}
      SENDS_ALLOWED: ${SENDS_ALLOWED}

      # Crypto y UI
      PASSWORD_ITERATIONS: ${PASSWORD_ITERATIONS}
      SHOW_PASSWORD_HINT: ${SHOW_PASSWORD_HINT}
      WEB_VAULT_ENABLED: ${WEB_VAULT_ENABLED}
      WEBSOCKET_ENABLED: ${WEBSOCKET_ENABLED}

      # Reverse proxy
      IP_HEADER: ${IP_HEADER}

      # Logging
      LOG_FILE: ${LOG_FILE}
      LOG_LEVEL: ${LOG_LEVEL}
      EXTENDED_LOGGING: ${EXTENDED_LOGGING}

      # Admin panel
      ADMIN_TOKEN: ${ADMIN_TOKEN}

      # SMTP (opcional, vacío = deshabilitado)
      SMTP_HOST: ${SMTP_HOST}
      SMTP_FROM: ${SMTP_FROM}
      SMTP_USERNAME: ${SMTP_USERNAME}
      SMTP_PASSWORD: ${SMTP_PASSWORD}
      SMTP_PORT: ${SMTP_PORT}
      SMTP_SECURITY: ${SMTP_SECURITY}
    volumes:
      - ${DATA_PATH}:/data:rw
    networks:
      - homelab
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://127.0.0.1:${ROCKET_PORT}/alive >/dev/null || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s
    labels:
      com.centurylinklabs.watchtower.enable: "false"

networks:
  homelab:
    external: true
```

### 4.1. Por qué cada bloque

| Línea | Por qué |
|---|---|
| `name: vaultwarden` | Hace el `compose project name` explícito en lugar de inferirlo del directorio (que también es `vaultwarden`). El nombre se ve en `docker compose ls`. |
| `image: ${VAULTWARDEN_IMAGE}` | Tag completo desde `.env` para que un cambio sea grep-able y un `git diff` muestre exactamente qué versión cambió. |
| `container_name: vaultwarden` | DNS interno: Caddy llama `http://vaultwarden:80`. Sin `container_name` Compose le pondría `vaultwarden-vaultwarden-1`. |
| `hostname: vaultwarden` | Vaultwarden imprime el hostname en algunos logs y respuestas; mantenerlo idéntico al `container_name` evita confusión al diagnosticar. |
| `restart: unless-stopped` | Auto-arranque tras reboot (la Pi se reinicia tras `unattended-upgrades` periódicamente). `unless-stopped` (no `always`) permite parar manualmente para mantenimiento sin que Docker lo levante a la fuerza. |
| `user: "${PUID}:${PGID}"` | UID 1000 → `homelab` en el host. Garantiza que los ficheros creados (`db.sqlite3`, `attachments/*`) hereden la propiedad esperada por Borg y los hooks de backup. |
| `env_file: /mnt/hd2t/services/vaultwarden/.env` | Path absoluto, fuera del repo. Justificado en [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §5.1. |
| `environment:` (re-declaración explícita) | Aunque `env_file` ya carga las vars, declararlas aquí **explícitamente** sirve de contrato: cualquier nueva env que el operador quiera inyectar sin pasar por `.env` (caso raro: troubleshooting puntual) tiene su sitio aquí, y `docker compose config` muestra siempre la lista efectiva. |
| `volumes: - ${DATA_PATH}:/data:rw` | Único bind mount. `/data` es el path interno que la imagen oficial espera. |
| `networks: [homelab]` | Sin `nextcloud_internal` ni similares — Vaultwarden no tiene BD lateral. |
| `cap_drop: ALL` | Justificado en la tabla de decisiones. |
| `security_opt: no-new-privileges:true` | Plantilla de [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §6. |
| `healthcheck: /alive` | Endpoint canónico de Vaultwarden, disponible sin auth. Devuelve un timestamp Unix con `200`. |
| `start_period: 30s` | Vaultwarden tarda ~5–10 s en abrir SQLite; con la Pi 5 cargada, hasta 20 s. 30 s deja margen sin marcar `unhealthy` falso. |
| `labels: com.centurylinklabs.watchtower.enable: "false"` | Justificado en §0 punto 6. |
| `networks.homelab.external: true` | Convención §4.3 de estructura-compose. |

### 4.2. Validar antes de levantar

```bash
cd ~/homelab/stacks/vaultwarden
docker compose --env-file /mnt/hd2t/services/vaultwarden/.env config
```

La salida debe mostrar:

- `image: vaultwarden/server:1.32.5-alpine`,
- `user: "1000:1000"`,
- el bloque `environment` totalmente interpolado (sin `${...}`),
- `networks: homelab` con `external: true`,
- ningún `ports:` publicado (no habrá línea `ports:`),
- `ADMIN_TOKEN`: `$argon2id$v=19$m=...$...$...$...` (tras §5.3), o vacío si aún no se generó.

Si `ADMIN_TOKEN` aparece como `${ADMIN_TOKEN}` literal, falta `--env-file`. Si aparece como `<empty>` y se quería el panel `/admin` activo, no se ha completado §5.3 todavía.

---

## 5. Despliegue

### 5.1. Levantar el stack (sin ADMIN_TOKEN aún)

Primer arranque: aún no hay `ADMIN_TOKEN`. **Eso es deliberado**: queremos que Vaultwarden cree `db.sqlite3`, las claves RSA y los directorios, comprobamos que arranca, y solo entonces generamos el token Argon2id (§5.3). Hasta entonces, el panel `/admin` está deshabilitado (Vaultwarden lo desactiva si `ADMIN_TOKEN` está vacío).

```bash
cd ~/homelab/stacks/vaultwarden
docker compose --env-file /mnt/hd2t/services/vaultwarden/.env up -d
```

Esperar ~10 s y verificar:

```bash
docker compose --env-file /mnt/hd2t/services/vaultwarden/.env ps
# Esperado:
#   NAME          IMAGE                            STATUS
#   vaultwarden   vaultwarden/server:1.32.5-alpine Up X seconds (health: starting)
```

### 5.2. Estado del contenedor

```bash
# Tras ~30 s, healthy:
docker inspect vaultwarden --format '{{.State.Health.Status}}'
# Esperado: healthy

# Logs del primer arranque:
docker logs vaultwarden 2>&1 | head -40
```

Líneas de interés en los logs (varían entre versiones):

```
[INFO][start] Vaultwarden 1.32.5 starting
[INFO][start] - Web Vault is enabled (1.32.5)
[INFO][start] - Webserver listening on 0.0.0.0:80
[INFO][start] Database created: /data/db.sqlite3
[INFO][start] RSA key pair generated and saved to /data/rsa_key.pem and /data/rsa_key.pub.pem
[WARN][start] No `ADMIN_TOKEN` set: admin panel is disabled
```

El `WARN` sobre el panel admin es **esperado** en este punto. Lo resolvemos a continuación.

Verificar que los ficheros físicos existen y tienen el owner correcto:

```bash
ls -la /mnt/hd2t/services/vaultwarden/data/
# Esperado (modo 0640 para los .pem y .sqlite3, 0750 para los dirs):
# -rw-r-----  1 homelab homelab  ... db.sqlite3
# -rw-r-----  1 homelab homelab  ... db.sqlite3-shm
# -rw-r-----  1 homelab homelab  ... db.sqlite3-wal
# -rw-r-----  1 homelab homelab  ... rsa_key.pem
# -rw-r-----  1 homelab homelab  ... rsa_key.pub.pem
# drwxr-x---  2 homelab homelab  ... attachments
# drwxr-x---  2 homelab homelab  ... sends
# -rw-r-----  1 homelab homelab  ... vaultwarden.log
```

### 5.3. Generar el `ADMIN_TOKEN` con Argon2id

Vaultwarden 1.30+ provee `vaultwarden hash` que genera un token aleatorio fuerte y lo hashea internamente con Argon2id. La salida tiene formato `$argon2id$v=19$m=...$...$...$...`. Procedimiento:

```bash
# 1. Genera un plaintext FUERTE. Lo necesitamos para entrar al panel /admin.
ADMIN_PLAINTEXT="$(openssl rand -base64 48 | tr -d '+/=' | cut -c1-48)"
echo "ADMIN_PLAINTEXT (anotar en KeePassXC + papel): $ADMIN_PLAINTEXT"

# 2. Genera el hash Argon2id desde la propia imagen (sin --rm porque queremos
#    pasar el plaintext por stdin sin que aparezca en `ps`).
ADMIN_HASH="$(echo -n "$ADMIN_PLAINTEXT" | docker run --rm -i \
    "$VAULTWARDEN_IMAGE" /vaultwarden hash --preset paranoid 2>&1 \
    | grep -oE '\$argon2id\$[^[:space:]]+' | tail -1)"
echo "ADMIN_HASH (irá al .env): $ADMIN_HASH"

# 3. Verificar el formato:
echo "$ADMIN_HASH" | grep -qE '^\$argon2id\$v=19\$' && echo "OK" || echo "FALLO — releer §5.3"
```

> **`--preset paranoid`**: usa el preset Argon2id de máxima dificultad de Vaultwarden (m=1 GiB, t=4, p=4). Tarda ~5 s en una Pi 5 — aceptable para un evento que ocurre una vez. El preset `bitwarden` (default) usa parámetros más laxos pensados para verificar passwords de usuario; `paranoid` es lo correcto para un token administrativo.

Inyectar el hash en el `.env`:

```bash
sudo -u homelab sed -i \
    "s|^ADMIN_TOKEN=.*$|ADMIN_TOKEN=${ADMIN_HASH}|" \
    /mnt/hd2t/services/vaultwarden/.env

# Verificar:
sudo -u homelab grep '^ADMIN_TOKEN=' /mnt/hd2t/services/vaultwarden/.env
```

Aplicar el cambio (basta con un `up -d`, Compose detecta el cambio en environment y recrea el contenedor):

```bash
cd ~/homelab/stacks/vaultwarden
docker compose --env-file /mnt/hd2t/services/vaultwarden/.env up -d --force-recreate

# Esperar ~30 s y verificar:
docker logs vaultwarden 2>&1 | tail -20 | grep -i admin
# Esperado:
#   [INFO][start] - Admin panel is enabled
```

### 5.4. Custodiar el plaintext del `ADMIN_TOKEN`

Triple custodia, mismo patrón que la passphrase de Borg ([`../07-backups/01-estrategia-backup.md`](../07-backups/01-estrategia-backup.md) §6.2):

1. **KeePassXC** del operador (entrada "Homelab — Vaultwarden ADMIN_TOKEN plaintext").
2. **Papel impreso** dentro de un sobre cerrado, etiquetado, guardado físicamente fuera de casa.
3. **Vaultwarden** una vez la cuenta del operador esté creada (§7.3.1) — pero **no como única custodia** (loop circular: si pierdes acceso a Vaultwarden, no puedes leer el token con el que entras al panel admin de Vaultwarden).

Tras anotar:

```bash
unset ADMIN_PLAINTEXT ADMIN_HASH
history -d $(history 1)   # bash 5.x: borra la última entrada del history
```

### 5.5. Smoke check de la API antes de la UI

```bash
# Probar /alive desde el host (a través de Docker):
docker exec vaultwarden wget -qO- http://127.0.0.1:80/alive
# Esperado: timestamp Unix tipo 1737000000

# Probar el panel /admin lo redirige al login de admin (sin auth aún):
docker exec vaultwarden wget -qO- -S http://127.0.0.1:80/admin 2>&1 | grep -i 'HTTP/\|location'
# Esperado: HTTP/1.1 200 OK   (la página de login del panel admin)
```

### 5.6. Backup inicial del estado virgen

Antes de exponer Vaultwarden a Caddy y crear la primera cuenta, snapshot manual del estado limpio:

```bash
DEST="/mnt/hd2t/backups/snapshots/vaultwarden-clean-$(date +%F).tar.gz"
sudo install -d -o root -g root -m 700 /mnt/hd2t/backups/snapshots

sudo tar czf "$DEST" \
    -C /mnt/hd2t/services/vaultwarden \
    --exclude='data/db.sqlite3-wal' \
    --exclude='data/db.sqlite3-shm' \
    data/

sudo chmod 600 "$DEST"
ls -la "$DEST"
# Esperado: ~10 KB (BD virgen, sin usuarios).
```

> **Por qué un snapshot manual extra antes de Borg**: Borg no ha llegado todavía al primer cron diario. Si algo va mal en §7 (mala configuración, RSA keys regeneradas por error tras un upgrade...) el operador puede volver al estado virgen sin esperar 24 h.

---

## 6. Integración con Caddy

### 6.1. Activar el bloque `vault.{$LAN_DOMAIN}` en el `Caddyfile`

El placeholder ya existe comentado en `~/homelab/stacks/proxy/Caddyfile` (visto en [`../03-red/04-caddy.md`](../03-red/04-caddy.md) §4.3, líneas 437–442). Descomentarlo:

```caddyfile
# ----- Vaultwarden ([../11-productividad/01-vaultwarden.md]) -----
vault.{$LAN_DOMAIN} {
    import lan_internal_tls
    import security_headers

    # WebSockets se manejan automáticamente por reverse_proxy:
    # Vaultwarden 1.29+ usa el mismo puerto (80) para HTTP y WS.
    reverse_proxy http://vaultwarden:80 {
        # Vaultwarden lee X-Real-IP (configurado por IP_HEADER en el .env)
        # para registrar la IP correcta en el LOG_FILE → Fail2ban.
        header_up X-Real-IP {remote_host}
        # X-Forwarded-Proto/For ya los inyecta Caddy por defecto en
        # `reverse_proxy`, pero los re-declaramos por claridad:
        header_up X-Forwarded-Proto {scheme}
        header_up X-Forwarded-For {remote_host}
    }
}
```

> **NO se importa `authelia_proxy`**. Vaultwarden gestiona su propia auth (master password + 2FA por usuario). Justificado en §0 punto 3. Si en el futuro el operador quisiera proteger **solo** `/admin` con Authelia (variante §13.6), añadiría un `@admin path /admin*` matcher con `forward_auth`, pero el bloque general queda **sin** Authelia.

### 6.2. Recargar Caddy

```bash
cd ~/homelab/stacks/proxy
docker compose exec caddy caddy validate --config /etc/caddy/Caddyfile
docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile

# Verificar que el cert se ha generado:
docker compose exec caddy ls -la /data/caddy/pki/authorities/local/
# Esperado: root.crt, root.key, intermediate.crt, intermediate.key (preexistentes)

docker compose logs caddy --tail 20 2>&1 | grep -i vault
# Esperado: certificate obtained successfully {"identifier": "vault.lan"}
```

### 6.3. Registro DNS local en Pi-hole

En la UI de Pi-hole → "Local DNS" → "DNS Records":

| Dominio | IP |
|---|---|
| `vault.lan` | `192.168.1.10` (IP del host con Caddy) |

Verificar:

```bash
dig +short @192.168.1.241 vault.lan
# Esperado: 192.168.1.10
```

### 6.4. Probar el acceso desde el navegador

```bash
# Desde un cliente con la CA de Caddy ya instalada (§6.5 de Caddy):
curl -v --resolve vault.lan:443:192.168.1.10 https://vault.lan/alive
# Esperado: HTTP/2 200, body: timestamp Unix
```

Desde el navegador: `https://vault.lan` → debería mostrarse la **landing page del Web Vault** (logo Bitwarden, formulario de login con campo "Email"). Si aparece un warning de cert, el `root.crt` de Caddy no está instalado en el navegador — volver a [`../03-red/04-caddy.md`](../03-red/04-caddy.md) §6.5.

### 6.5. Acceso vía Tailscale (preparado)

Cuando [`../03-red/05-tailscale.md`](../03-red/05-tailscale.md) esté completado, descomentar/añadir al `Caddyfile`:

```caddyfile
vault.{$TS_DOMAIN} {
    import tailscale_tls vault
    import security_headers

    reverse_proxy http://vaultwarden:80 {
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-Proto {scheme}
        header_up X-Forwarded-For {remote_host}
    }
}
```

Y actualizar el `.env` de Vaultwarden para que `DOMAIN` sea coherente con **ambos** dominios (LAN canónico + Tailscale alias). En la práctica, Vaultwarden solo soporta **un** `DOMAIN` — se mantiene `https://vault.${LAN_DOMAIN}` como canónico (los emails y URLs absolutas saldrán con ese hostname). Acceder a `https://vault.${TS_DOMAIN}` desde Tailscale **funciona** (la app no comprueba que el `Host:` coincida con `DOMAIN`), pero los enlaces de los emails (cuando el operador active SMTP) y de los Bitwarden Send apuntarán al `lan` — la app del cliente, conectada por Tailscale, los resuelve igual gracias a MagicDNS.

---

## 7. Configuración post-despliegue

### 7.1. Crear la primera cuenta del operador

1. Abrir `https://vault.lan` desde el navegador del operador (con la CA de Caddy instalada).
2. Click en **"Create account"**.
3. Rellenar:
   - **Email**: el del operador (sin necesidad de SMTP funcional — Vaultwarden lo usa solo como identificador único).
   - **Master password**: ≥ 16 caracteres, alta entropía. **Esta master password es el único secreto que el operador NO puede recuperar** (Vaultwarden no tiene "olvidé mi password" sin SMTP). **Anotar en KeePassXC + papel + sobre cerrado**, mismo patrón que la passphrase de Borg.
   - **Master password hint**: dejar vacío (`SHOW_PASSWORD_HINT=false` en el `.env` lo ignoraría igualmente).
4. Crear la cuenta.

> **Si fallan los signups con `SIGNUPS_ALLOWED=false`**: este es el problema del huevo/gallina. Para crear la **primera** cuenta, hay dos opciones:
> - **Opción A (recomendada)**: poner temporalmente `SIGNUPS_ALLOWED=true`, recrear el contenedor, crear la cuenta, y **volver a `false`**. Procedimiento:
>   ```bash
>   sed -i 's/^SIGNUPS_ALLOWED=.*/SIGNUPS_ALLOWED=true/' /mnt/hd2t/services/vaultwarden/.env
>   docker compose --env-file /mnt/hd2t/services/vaultwarden/.env up -d --force-recreate
>   # ... crear la cuenta en la UI ...
>   sed -i 's/^SIGNUPS_ALLOWED=.*/SIGNUPS_ALLOWED=false/' /mnt/hd2t/services/vaultwarden/.env
>   docker compose --env-file /mnt/hd2t/services/vaultwarden/.env up -d --force-recreate
>   ```
> - **Opción B**: usar el panel `/admin` (con el ADMIN_TOKEN del §5.3) para invitar al operador como nuevo usuario. La invitación llega como un link que el operador abre y completa con su master password. Funciona sin SMTP porque el link se muestra **directamente en el panel admin**.

### 7.2. Activar 2FA TOTP en la cuenta del operador

Tras login, en `https://vault.lan/`:

1. Settings → Security → **Two-step Login**.
2. Click en "Authenticator app" → **Manage**.
3. Confirmar la master password.
4. Vaultwarden muestra un QR — escanearlo con Aegis (Android) o Raivo OTP (iOS). **No usar Google Authenticator**: no respalda la seed; un móvil perdido = cuenta inaccesible.
5. Introducir el código de 6 dígitos para confirmar la asociación.
6. **Recovery code**: aparece un código alfanumérico de un solo uso. **Anotarlo en KeePassXC + papel** — es la única vía de recuperar la cuenta si se pierde el segundo factor.

### 7.3. Crear cuentas para familiares (vía panel `/admin`)

#### 7.3.1. Acceder al panel admin

1. `https://vault.lan/admin` desde el navegador del operador.
2. Pantalla "Vaultwarden Admin" con campo **"Admin Token"**.
3. Pegar el **plaintext** del ADMIN_TOKEN (no el hash) generado en §5.3.
4. Click "Login".

#### 7.3.2. Invitar a un usuario nuevo

1. En el panel admin → Tab **"Users"**.
2. Click "Invite User".
3. Email del invitado.
4. Vaultwarden crea la invitación. Como **no** hay SMTP, aparece un **enlace de aceptación** en la propia UI ("Invite link") — copiarlo.
5. Compartir el enlace con el invitado por un canal seguro (Signal, Telegram con E2E, en persona).
6. El invitado abre el enlace, define su master password, activa su 2FA TOTP.

#### 7.3.3. Cerrar el panel admin tras uso

El panel admin permanece abierto en el navegador hasta que se cierra la pestaña. **No** dejarlo abierto:

```text
Settings → Logout
```

O simplemente cerrar la pestaña — las cookies del admin son `httpOnly`, `Secure`, `SameSite=Lax`, sin persistencia tras cerrar sesión.

### 7.4. Activar el jail Fail2ban de Vaultwarden

En [`../04-seguridad/02-fail2ban.md`](../04-seguridad/02-fail2ban.md) §6.2 quedó preparado el jail con `enabled = false`. Ahora se activa:

```bash
# 1. Verificar que el log existe y se está escribiendo:
sudo tail -f /mnt/hd2t/services/vaultwarden/data/vaultwarden.log
# (Hacer un login fallido en https://vault.lan en otra pestaña — debe aparecer)
# Línea esperada (formato):
#   [2025-01-15 14:23:01.234][error][vaultwarden::api::identity]
#       Username or password is incorrect. Try again. IP: 192.168.1.99. Username: ...

# 2. Corregir el typo del logpath en el jail (de 'vault' a 'vaultwarden'):
sudo sed -i \
    's|/mnt/hd2t/services/vault/data/vaultwarden.log|/mnt/hd2t/services/vaultwarden/data/vaultwarden.log|' \
    /etc/fail2ban/jail.d/40-vaultwarden.conf

# 3. Activar el jail:
sudo sed -i 's/^enabled  = false/enabled  = true/' \
    /etc/fail2ban/jail.d/40-vaultwarden.conf

# 4. Recargar fail2ban (mantiene el estado de bans existente):
sudo fail2ban-client reload

# 5. Verificar:
sudo fail2ban-client status
# Esperado: "Number of jail = 4"  (sshd, authelia, caddy-status, vaultwarden)

sudo fail2ban-client status vaultwarden
# Esperado:
#   Filter
#     |- File list:    /mnt/hd2t/services/vaultwarden/data/vaultwarden.log
#     |- Currently failed: 0
#     `- Total failed:    N
#   Actions
#     |- Currently banned: 0
#     `- Total banned:    0
```

> **Coordinación con el doc de Fail2ban**: el path `/mnt/hd2t/services/vault/...` es un typo conocido en [`../04-seguridad/02-fail2ban.md`](../04-seguridad/02-fail2ban.md) §6.2; el path canónico, consistente con el resto del homelab (Borgmatic, backup-docker-volumes, este doc), es `/mnt/hd2t/services/vaultwarden/`. La corrección hecha aquí en el `jail.d/` se reflejará en ese doc en una iteración posterior.

### 7.5. Verificar el flujo end-to-end Fail2ban

```bash
# Desde otra máquina de la LAN (o la misma con un User-Agent distinto):
for i in $(seq 1 6); do
    curl -k -s -o /dev/null -w "%{http_code}\n" \
        --resolve vault.lan:443:192.168.1.10 \
        -d 'username=fake@example.com&password=WRONG' \
        https://vault.lan/identity/connect/token
done
# Esperado: 6 × 400 (la API rechaza el login).

# En el host:
sudo fail2ban-client status vaultwarden
# Esperado: "Currently banned: 1"

sudo nft list set inet f2b-table f2b-vaultwarden
# Esperado: la IP de la máquina de prueba aparece en el set.

# Liberar para el siguiente smoke test:
sudo fail2ban-client unban <IP_de_la_maquina_de_prueba>
```

### 7.6. Configurar la extensión del navegador y los clientes móviles

#### 7.6.1. Extensión del navegador (Firefox/Chromium)

1. Instalar la extensión **Bitwarden Password Manager** desde la store oficial.
2. Click en el icono → **Settings** (engranaje).
3. **Self-hosted environment** → "Server URL": `https://vault.lan`. Dejar todos los demás campos vacíos (no se necesita splittear API/Identity/Web/Notifications/Icons cuando todo va al mismo dominio).
4. Save.
5. Volver a "Log in" → introducir email + master password + TOTP.

#### 7.6.2. Cliente de escritorio (Linux/macOS/Windows)

1. Descargar el cliente oficial Bitwarden desde [bitwarden.com/download](https://bitwarden.com/download/).
2. Pre-login: Settings → "Self-hosted environment" → Server URL: `https://vault.lan`.
3. Login normal.

#### 7.6.3. App móvil (iOS/Android)

1. Instalar **Bitwarden** desde App Store / Play Store.
2. **Antes** de meter las credenciales: tap en el icono de configuración (esquina superior izquierda) → **Self-hosted**.
3. Server URL: `https://vault.lan`.
4. Login.

> **iOS**: la app rechaza certificados de CA no confiados a nivel SO. Repasar [`../03-red/04-caddy.md`](../03-red/04-caddy.md) §6.5 — el `root.crt` debe estar instalado **y activado** en `Ajustes → General → Información → Ajustes de confianza de certificados`.

> **Acceso fuera de casa**: el móvil no puede resolver `vault.lan` desde la red móvil. Conectar Tailscale y apuntar al hostname `vault.${TS_DOMAIN}` (cuando esa fase esté completa).

### 7.7. Lista de verificación post-despliegue

- [ ] `docker inspect vaultwarden --format '{{.State.Health.Status}}'` → `healthy`.
- [ ] `https://vault.lan/alive` responde con un timestamp Unix.
- [ ] La cuenta del operador está creada y tiene 2FA TOTP activo.
- [ ] El recovery code de TOTP está en KeePassXC + papel.
- [ ] La master password está en KeePassXC + papel + sobre cerrado.
- [ ] El plaintext del ADMIN_TOKEN está en KeePassXC + papel + Vaultwarden.
- [ ] `SIGNUPS_ALLOWED=false` en el `.env` final (tras crear la cuenta).
- [ ] Fail2ban jail `vaultwarden` activo, `Currently banned: 0` en estado limpio.
- [ ] La extensión del navegador del operador apunta a `https://vault.lan` y guarda la primera credencial.
- [ ] El cliente móvil del operador hace login y sincroniza ítems.
- [ ] La passphrase de Borg ([`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §4.2) está ya añadida como cuarta custodia en Vaultwarden (entrada "Homelab — Borg passphrase").

---

## 8. Verificación

### 8.1. Contenedor sano y permisos correctos

```bash
docker inspect vaultwarden --format '{{json .State}}' | jq '{Status, Running, Health, Pid}'
# Esperado: Status=running, Running=true, Health.Status=healthy, Pid=...

docker inspect vaultwarden --format '{{.Config.User}}'
# Esperado: 1000:1000

docker inspect vaultwarden --format '{{range .HostConfig.CapAdd}}{{.}}{{end}}'
# Esperado: vacío (cap_add = [])

docker inspect vaultwarden --format '{{json .HostConfig.SecurityOpt}}'
# Esperado: ["no-new-privileges:true", "label=disable", ...]
```

### 8.2. Vaultwarden no escucha al host

```bash
# Listar puertos publicados:
docker port vaultwarden
# Esperado: VACÍO. Si aparece "80/tcp -> 0.0.0.0:80", revisar el compose.

# Confirmar desde fuera del host (cualquier máquina de la LAN):
curl -k --connect-timeout 3 http://192.168.1.10:80
# Esperado: respuesta de Caddy (no de Vaultwarden), o "Connection refused"
# si Caddy no escucha en :80 (depende de auto_https).

curl -k --connect-timeout 3 http://192.168.1.10:3012
# Esperado: "Connection refused" — el puerto WS legacy NO está abierto.
```

### 8.3. UI accesible vía Caddy

```bash
# Headers de seguridad (security_headers de Caddy):
curl -k -sI --resolve vault.lan:443:192.168.1.10 https://vault.lan/ | grep -E '(strict|x-frame|x-content|referrer|permissions)'
# Esperado:
#   strict-transport-security: max-age=...
#   x-frame-options: SAMEORIGIN
#   x-content-type-options: nosniff
#   referrer-policy: strict-origin-when-cross-origin
#   permissions-policy: ...
```

### 8.4. API operativa

```bash
# /alive (sin auth):
curl -k -s --resolve vault.lan:443:192.168.1.10 https://vault.lan/alive
# Esperado: número Unix tipo "1737..."

# /api/version (sin auth):
curl -k -s --resolve vault.lan:443:192.168.1.10 https://vault.lan/api/version
# Esperado: "1.32.5" (entre comillas, es JSON-string)

# /admin redirige al login admin (sin token):
curl -k -sI --resolve vault.lan:443:192.168.1.10 https://vault.lan/admin
# Esperado: HTTP/2 200, content-type: text/html (la página de login admin)
```

### 8.5. WebSocket operativo

```bash
# Probar el handshake WS (requiere wscat o similar; alternativa con curl):
curl -k -i -N --resolve vault.lan:443:192.168.1.10 \
    -H "Connection: Upgrade" \
    -H "Upgrade: websocket" \
    -H "Sec-WebSocket-Version: 13" \
    -H "Sec-WebSocket-Key: $(openssl rand -base64 16)" \
    https://vault.lan/notifications/hub 2>&1 | head -20
# Esperado: HTTP/1.1 101 Switching Protocols
```

Desde la UI: abrir `https://vault.lan/` en dos pestañas con la misma cuenta logueada. Añadir un ítem en una pestaña → **debe aparecer en la otra en ~1 s sin recargar**. Si tarda 30+ s, el WS no está funcionando (caer a polling).

### 8.6. Persistencia tras reboot

```bash
sudo systemctl reboot
# Esperar ~2 min...

# Tras volver:
docker ps --filter name=vaultwarden --format '{{.Status}}'
# Esperado: "Up X seconds (healthy)"

curl -k -s --resolve vault.lan:443:192.168.1.10 https://vault.lan/alive
# Esperado: timestamp Unix
```

### 8.7. Backup hooks Borgmatic ejecutándose

```bash
# Comprobar que el hook sqlite_databases dump-ea Vaultwarden la próxima noche.
# El timestamp del fichero dump aumenta cada noche tras el cron.
sudo ls -la /mnt/hd2t/backups/dumps/sqlite/vaultwarden-*
# Esperado: el más reciente con fecha = última ejecución de borgmatic-daily.

# Forzar manualmente para verificar AHORA (el dump se sobreescribe; ojo si
# se hace en horario de uso):
sudo borgmatic --verbosity 2 --syslog-verbosity 0 --files \
    --override 'create.actions=[]' \
    --override 'check.actions=[]'
# Esperado: log con líneas "Running command for sqlite_databases hook" y
# "Database dump for vaultwarden written to ...".
```

### 8.8. Lista de verificación

- [ ] `docker compose ps` muestra `vaultwarden` `Up` y `healthy`.
- [ ] No hay puertos publicados al host.
- [ ] `https://vault.lan` carga la web vault con cert válido (sin warning).
- [ ] `/admin` exige el ADMIN_TOKEN (sin él, login page aparece pero no permite entrar).
- [ ] El operador tiene cuenta + 2FA TOTP + recovery code custodiado.
- [ ] La extensión y la app móvil sincronizan ítems en tiempo real (WS funcional).
- [ ] Fail2ban jail `vaultwarden` activo y banea tras 5 logins fallidos.
- [ ] Borgmatic incluye `vaultwarden` como `sqlite_databases` y los dumps existen en `/mnt/hd2t/backups/dumps/sqlite/`.
- [ ] El servicio sobrevive a un `reboot` sin intervención.

---

## 9. Backup

### 9.1. Qué se respalda y qué no

| Path (host) | ¿Backup? | Patrón |
|---|---|---|
| `/mnt/hd2t/services/vaultwarden/data/db.sqlite3` | **Sí, con `sqlite3 .backup`** | Hook Borgmatic ya configurado. **Crítico**: la BD contiene los blobs cifrados con la master password — se restaura tal cual. |
| `/mnt/hd2t/services/vaultwarden/data/db.sqlite3-wal` y `-shm` | **No directamente** (los regenera SQLite tras checkpoint). El dump `.backup` los integra. | — |
| `/mnt/hd2t/services/vaultwarden/data/rsa_key.pem` y `rsa_key.pub.pem` | **Sí, vía bind mount** | **Crítico**: si se pierde el par RSA, todos los JWT de sesión emitidos pasan a ser inválidos — los clientes piden re-login (no es desastre, pero los recovery codes de TOTP que dependan del JWT actual se pierden). |
| `/mnt/hd2t/services/vaultwarden/data/attachments/` | **Sí, vía bind mount** | Si hay adjuntos. Patrón "ficheros referenciados por la BD: snapshotear ambos a la vez" — `.backup` del SQLite + tar del directorio en el mismo Borg snapshot. |
| `/mnt/hd2t/services/vaultwarden/data/sends/` | **Sí, vía bind mount** | Bitwarden Send. Efímeros (caducan en horas/días), pero un snapshot diario es trivial y permite recuperar Sends activos en el momento del fallo. |
| `/mnt/hd2t/services/vaultwarden/data/config.json` | **Sí, vía bind mount** | Cambios hechos en el panel `/admin`: si están aquí, sobreescriben las env del `.env`. Sin él, tras restore, los ajustes vuelven a las env. |
| `/mnt/hd2t/services/vaultwarden/data/vaultwarden.log` | **No** (regenerable, ruidoso) | Excluido vía pattern Borg (`exclude_patterns`). Ya rota con logrotate; un mes de logs son 100s de MB; no hace falta versionarlos. |
| `/mnt/hd2t/services/vaultwarden/.env` | **Sí, vía bind mount** | Contiene el `ADMIN_TOKEN` hashed. Sin él, post-restore no se entra al panel admin (aunque el plaintext custodiado a parte permite generar uno nuevo). |
| `~/homelab/stacks/vaultwarden/` | **Sí, vía Borg snapshot de `~/homelab`** | El `docker-compose.yml` y el `.env.example`. Patrón estándar. |

### 9.2. Patrón Borgmatic — respaldo SQLite

Ya configurado en [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §4 (línea visible en el grep del §0 de este doc):

```yaml
sqlite_databases:
  - name: vaultwarden
    path: /mnt/hd2t/services/vaultwarden/data/db.sqlite3
```

Borgmatic ejecuta cada noche, en este orden:

1. **`before_backup`** hook: `sqlite3 /mnt/hd2t/services/vaultwarden/data/db.sqlite3 ".backup /mnt/hd2t/backups/dumps/sqlite/vaultwarden-$(date +%F).sqlite3"` (snapshot consistente con escritores activos).
2. **`borg create`**: snapshot del filesystem incluyendo `/mnt/hd2t/services/vaultwarden/` completo (con el dump generado en el paso 1) y `~/homelab/`.
3. **`after_backup`** hook: opcional `sqlite3 ... "PRAGMA integrity_check;"` sobre el dump para validar.
4. Notificación a Uptime Kuma (cuando Fase 5 esté completa).

Nada que añadir aquí — el patrón es genérico.

### 9.3. Patrón pre-update Watchtower (backup antes de upgrade manual)

Vaultwarden tiene Watchtower **deshabilitado**. El upgrade manual del operador debe ir precedido de un dump consistente. Mismo script que [`../07-backups/03-backup-docker-volumes.md`](../07-backups/03-backup-docker-volumes.md) §5.5.

Crear `~/homelab/stacks/vaultwarden/scripts/pre-update.sh`:

```bash
#!/usr/bin/env bash
# Dump consistente de Vaultwarden antes de un upgrade manual.
# Uso: ~/homelab/stacks/vaultwarden/scripts/pre-update.sh
set -euo pipefail

DEST="/mnt/hd2t/backups/dumps/sqlite/vaultwarden-pre-update-$(date +%F-%H%M).sqlite3"
SOURCE="/mnt/hd2t/services/vaultwarden/data/db.sqlite3"

echo "[pre-update] Dumping $SOURCE -> $DEST"
sudo install -d -o root -g root -m 700 "$(dirname "$DEST")"
sudo sqlite3 "$SOURCE" ".backup '$DEST'"
sudo chmod 600 "$DEST"

echo "[pre-update] Verifying dump integrity"
sudo sqlite3 "$DEST" "PRAGMA integrity_check;" | head -3
# Esperado: "ok"

echo "[pre-update] Snapshot del bind mount completo"
ARCHIVE="/mnt/hd2t/backups/snapshots/vaultwarden-pre-update-$(date +%F-%H%M).tar.gz"
sudo install -d -o root -g root -m 700 "$(dirname "$ARCHIVE")"
sudo tar czf "$ARCHIVE" \
    -C /mnt/hd2t/services/vaultwarden \
    --exclude='data/db.sqlite3-wal' \
    --exclude='data/db.sqlite3-shm' \
    --exclude='data/vaultwarden.log' \
    data/
sudo chmod 600 "$ARCHIVE"

echo "[pre-update] DONE"
echo "  dump:     $DEST"
echo "  snapshot: $ARCHIVE"
```

Ejecutar antes de cualquier `docker compose pull`:

```bash
sudo ~/homelab/stacks/vaultwarden/scripts/pre-update.sh
# Solo si el script termina con "[pre-update] DONE":
cd ~/homelab/stacks/vaultwarden
sudo -u homelab sed -i \
    "s|^VAULTWARDEN_IMAGE=.*$|VAULTWARDEN_IMAGE=vaultwarden/server:NUEVA_VERSION-alpine|" \
    /mnt/hd2t/services/vaultwarden/.env
docker compose --env-file /mnt/hd2t/services/vaultwarden/.env pull
docker compose --env-file /mnt/hd2t/services/vaultwarden/.env up -d
docker logs -f vaultwarden  # vigilar la migración SQLite
```

### 9.4. Restore (resumen)

Procedimiento detallado en [`../07-backups/03-backup-docker-volumes.md`](../07-backups/03-backup-docker-volumes.md) §4.5. Resumen:

```bash
ARCH="homelab-pi5-2026-01-15T03:00:00"
STACK="vaultwarden"

cd ~/homelab/stacks/$STACK
docker compose --env-file /mnt/hd2t/services/$STACK/.env stop vaultwarden

# 1. Reemplazar el SQLite con el dump consistente:
sudo cp /mnt/hd2t/backups/dumps/sqlite/vaultwarden-2026-01-15.sqlite3 \
    /mnt/hd2t/services/$STACK/data/db.sqlite3
sudo chown 1000:1000 /mnt/hd2t/services/$STACK/data/db.sqlite3
sudo chmod 640 /mnt/hd2t/services/$STACK/data/db.sqlite3

# 2. Restaurar attachments/, sends/, rsa_key*.pem, config.json desde Borg
#    (igual que cualquier bind mount):
sudo borgmatic extract --archive "$ARCH" \
    --path "mnt/hd2t/services/$STACK/data/attachments" \
    --path "mnt/hd2t/services/$STACK/data/sends" \
    --path "mnt/hd2t/services/$STACK/data/rsa_key.pem" \
    --path "mnt/hd2t/services/$STACK/data/rsa_key.pub.pem" \
    --path "mnt/hd2t/services/$STACK/data/config.json" \
    --destination /

# 3. Limpiar WAL/SHM (los regenera SQLite al primer arranque):
sudo rm -f /mnt/hd2t/services/$STACK/data/db.sqlite3-wal
sudo rm -f /mnt/hd2t/services/$STACK/data/db.sqlite3-shm

# 4. Levantar:
docker compose --env-file /mnt/hd2t/services/$STACK/.env up -d
docker logs vaultwarden 2>&1 | head -20
# Esperado: Database opened, RSA key pair loaded, Webserver listening.
```

> **El `rsa_key.*` es crítico** ([`../07-backups/03-backup-docker-volumes.md`](../07-backups/03-backup-docker-volumes.md) §4.5 explicita el motivo): Vaultwarden lo usa para firmar JWTs de sesión. Si se pierde, todos los clientes deben re-loguearse (recoverable). Si se *desincroniza* del SQLite (dos snapshots distintos), todos los `auth_request` fallan hasta que se re-genera con un master password (ningún operador querrá llegar a esto).

### 9.5. Smoke test mensual

[`../07-backups/03-backup-docker-volumes.md`](../07-backups/03-backup-docker-volumes.md) §6 fija la rotación: **Vaultwarden en M1, M5, M9** (cada 4 meses). Procedimiento ya documentado allí en §6.3 (con paso a paso completo). Anotar resultado en `~/homelab/operations/restore-tests.log`.

---

## 10. Operaciones cotidianas

### 10.1. Upgrade manual (Watchtower deshabilitado)

```bash
# 1. Leer el changelog:
xdg-open https://github.com/dani-garcia/vaultwarden/releases  # o equivalente

# 2. Pre-update backup:
sudo ~/homelab/stacks/vaultwarden/scripts/pre-update.sh

# 3. Editar el .env:
sudo -u homelab "$EDITOR" /mnt/hd2t/services/vaultwarden/.env
#  → cambiar VAULTWARDEN_IMAGE=vaultwarden/server:1.33.0-alpine

# 4. Pull + up:
cd ~/homelab/stacks/vaultwarden
docker compose --env-file /mnt/hd2t/services/vaultwarden/.env pull
docker compose --env-file /mnt/hd2t/services/vaultwarden/.env up -d --force-recreate

# 5. Verificar la UI y los clientes:
curl -k -s --resolve vault.lan:443:192.168.1.10 https://vault.lan/api/version
# Esperado: "1.33.0"

# 6. Si algo va mal: rollback (raro):
#    cambiar VAULTWARDEN_IMAGE de vuelta a la versión anterior
#    docker compose ... up -d --force-recreate
#    si hubo migración SQLite ya aplicada: restaurar el dump pre-update.
```

### 10.2. Añadir un usuario nuevo (familiar)

Repetir §7.3.1 + §7.3.2.

### 10.3. Quitar un usuario

Panel `/admin` → Tab "Users" → fila del usuario → "Delete user". El usuario y todos sus ítems (cifrados con su master password, ilegibles para el operador) se borran. **No** se puede "transferir" la cuenta: las claves derivadas de la master password de cada usuario son únicas.

### 10.4. Cambiar la master password del operador

Solo el propio usuario puede hacerlo (el ADMIN_TOKEN no puede cambiar la master password de nadie — es by design, garantía de zero-knowledge).

1. Vault → Settings → Account → **Change Master Password**.
2. Introducir la actual + la nueva (×2) + el current TOTP.
3. Vaultwarden re-cifra todas las claves derivadas (~5 s para una bóveda de 1k entradas).
4. **Sesiones existentes** en otros clientes: invalidadas. Re-login en cada uno.

### 10.5. Rotar el `ADMIN_TOKEN`

Si hay sospecha de que el plaintext del token se ha filtrado:

```bash
# 1. Generar nuevo plaintext y nuevo hash (§5.3):
ADMIN_PLAINTEXT_NEW="$(openssl rand -base64 48 | tr -d '+/=' | cut -c1-48)"
ADMIN_HASH_NEW="$(echo -n "$ADMIN_PLAINTEXT_NEW" | docker run --rm -i \
    "$VAULTWARDEN_IMAGE" /vaultwarden hash --preset paranoid 2>&1 \
    | grep -oE '\$argon2id\$[^[:space:]]+' | tail -1)"

# 2. Actualizar .env:
sudo -u homelab sed -i \
    "s|^ADMIN_TOKEN=.*$|ADMIN_TOKEN=${ADMIN_HASH_NEW}|" \
    /mnt/hd2t/services/vaultwarden/.env

# 3. Recrear el contenedor:
cd ~/homelab/stacks/vaultwarden
docker compose --env-file /mnt/hd2t/services/vaultwarden/.env up -d --force-recreate

# 4. Anotar el nuevo plaintext en KeePassXC + papel + Vaultwarden y desechar el antiguo.
unset ADMIN_PLAINTEXT_NEW ADMIN_HASH_NEW
history -d $(history 1)
```

El antiguo token deja de funcionar inmediatamente al recrear el contenedor.

### 10.6. Importar passwords desde KeePassXC

Tras crear la cuenta (§7.1) e instalar la extensión:

1. En KeePassXC: Database → Export → KeePass 1 (KDB) format. (El formato CSV de Bitwarden pierde algunos campos; el KDB import-er de Bitwarden funciona mejor.)
2. En la web vault `https://vault.lan/`: Tools → **Import Data** → Format: "Keepass 1 (KDB)" → seleccionar el `.kdb` exportado → Import.
3. Verificar conteo de ítems.
4. **Borrar el `.kdb` exportado** del disco temporal: `shred -u keepass-export.kdb` (no `rm` — `shred` sobreescribe primero).

### 10.7. Limpieza de attachments huérfanos

Cuando un usuario borra un ítem con adjuntos, Vaultwarden borra también los ficheros del directorio. Pero un fallo en una migración o un restore parcial puede dejar huérfanos. Comprobación:

```bash
# Listar ítems con adjuntos en la BD:
sudo sqlite3 /mnt/hd2t/services/vaultwarden/data/db.sqlite3 \
    "SELECT id FROM attachments;" | sort > /tmp/attachments-db.txt

# Listar ficheros físicos:
sudo find /mnt/hd2t/services/vaultwarden/data/attachments \
    -type f -name '*.data' -printf '%f\n' | sed 's/\..*$//' | sort > /tmp/attachments-fs.txt

# Diff:
diff /tmp/attachments-db.txt /tmp/attachments-fs.txt
# Esperado: idénticos. Si la BD tiene IDs sin fichero, hay corrupción y procede restore.
# Si el FS tiene ficheros sin entrada en BD, son huérfanos: borrar tras backup.
```

### 10.8. Logs y observabilidad

```bash
# Logs del contenedor (json-file rotado a 30 MB):
docker logs -f vaultwarden

# Log de fichero (LOG_FILE) — el que Fail2ban consume:
sudo tail -f /mnt/hd2t/services/vaultwarden/data/vaultwarden.log

# Estadísticas de fail2ban:
sudo fail2ban-client status vaultwarden

# Integraciones futuras (Fase 5+):
#  - Loki / Promtail leyendo /mnt/hd2t/services/vaultwarden/data/vaultwarden.log
#  - Grafana dashboard custom con conteo de logins/min, fails/h, sessions activas.
#  - Uptime Kuma monitor HTTP a https://vault.lan/alive.
```

### 10.9. Comportamiento durante mantenimiento

- **Caddy parado**: el contenedor `vaultwarden` sigue corriendo, pero `https://vault.lan` no responde. Las extensiones/clientes muestran "Unable to reach server". Al levantar Caddy, retoman.
- **Pi-hole parado**: `vault.lan` deja de resolver desde la LAN; los clientes ya logueados con cache local del DNS pueden seguir un rato. Soluciones: arreglar Pi-hole, o usar IP directa `https://192.168.1.10` (con SAN del cert válido — no por defecto, ver Caddy §X).
- **Tailscale parado**: el acceso remoto se cae; LAN sigue.
- **Vaultwarden parado**: clientes muestran "server unreachable". Los datos siguen accesibles **localmente en cada cliente** desde el último sync (Bitwarden tiene cache local cifrado con la master password). Sin cambios destructivos posibles hasta que vuelva.
- **Pi reiniciada**: ~1 min de downtime hasta que `restart: unless-stopped` levante Vaultwarden. Los clientes reconectan automáticamente.

---

## 11. Solución de Problemas

| Síntoma | Diagnóstico | Solución |
|---|---|---|
| Cliente Bitwarden: "Unable to reach server" | DNS / TLS / red. | Probar `curl -k https://vault.lan/alive` desde el host del cliente. Si falla DNS: revisar Pi-hole. Si falla TLS: instalar root.crt de Caddy. Si falla TCP: revisar Caddy y `vaultwarden` containers. |
| Cliente Bitwarden: "Cannot connect to server" en iOS | Cert no confiado a nivel SO en iOS. | Instalar el `root.crt` desde Settings → Profiles & Device Management → activarlo en "Certificate Trust Settings". |
| `https://vault.lan/admin` no acepta el ADMIN_TOKEN | El plaintext custodiado no coincide con el hash en el `.env`, o hay typo. | Regenerar el token (§10.5) y custodiar el nuevo plaintext. |
| Login en la web vault: "Invalid two-step login provider" | Drift de reloj entre el cliente y la Pi (TOTP requiere ±30 s). | Sincronizar reloj de la Pi (`timedatectl status`) y del cliente. |
| WebSocket no funciona (los cambios tardan 30+ s en aparecer en otros clientes) | Caddy bloquea el `Upgrade` o Vaultwarden está en una versión vieja sin WS unificado. | Confirmar `WEBSOCKET_ENABLED=true`. Revisar `docker compose logs caddy` por errores de upgrade. Verificar `curl -i -N -H "Upgrade: websocket" ...` (§8.5) → debe responder 101. |
| Fail2ban no banea pese a 5 logins fallidos en `/identity/connect/token` | El `LOG_FILE` no recibe el formato esperado por el filtro. | Verificar `tail -F /mnt/hd2t/services/vaultwarden/data/vaultwarden.log` mientras se hace un login fallido. Si la línea aparece en formato JSON o sin "IP: <addr>": revisar `EXTENDED_LOGGING=true`. Si sigue: ajustar `failregex` en `/etc/fail2ban/filter.d/vaultwarden.local`. |
| Tras restore, los clientes tienen que re-loguearse | El `rsa_key.pem` recuperado es de un snapshot distinto al `db.sqlite3` (los JWTs ya emitidos no validan). | Esperado y benigno. Cada usuario hace login una vez y se generan nuevos JWTs. |
| `db.sqlite3` corrupto tras un cierre brusco | El `journal_mode=WAL` de SQLite normalmente recupera, pero corrupción real es posible. | `sudo sqlite3 db.sqlite3 "PRAGMA integrity_check;"`. Si reporta errores: stop, restaurar el último dump consistente (§9.4), arrancar. |
| Borgmatic: `sqlite3: command not found` en el hook | Borgmatic corre como `root`; sqlite3 no está en `$PATH` por defecto en algunas distros. | Instalar `sqlite3` en el host: `sudo apt install sqlite3`. Versión 3.34+. |
| Vaultwarden se reinicia en bucle tras un upgrade | Migración SQLite fallida. | Restaurar el dump pre-update (§9.3), re-pinear a la versión anterior, abrir issue en GitHub con el log. |
| El icono de favicons no se carga (apps muestran "Bitwarden" genérico) | `ICON_SERVICE` por defecto pide a `icons.bitwarden.com` (saliente). | Si el operador no quiere tráfico saliente: `ICON_SERVICE=internal` en `.env` (Vaultwarden cachea internamente). Variante en §13.8. |
| `INVITATION_EXPIRATION_HOURS` agota la invitación antes de que el invitado la abra | Default 120 h. | Aumentar `INVITATION_EXPIRATION_HOURS=720` en `.env` (30 días) si las invitaciones se hacen "en frío". |
| Tras un reboot de la Pi, la BD está bloqueada | El SHM/WAL anterior no se limpió. | El primer arranque de Vaultwarden ejecuta el checkpoint y limpia. Si no: parar el contenedor, `rm db.sqlite3-shm db.sqlite3-wal`, levantar — la BD principal se recupera del último checkpoint. |
| El operador olvida la master password | **No hay recovery sin SMTP** (los recovery emails no se generan). | Si hay SMTP: usar el flujo de "Forgot password" que envía un link. Sin SMTP: la cuenta es papel; crear nueva, perder los ítems cifrados con la master perdida. **Por eso la master se anota en papel + sobre cerrado.** |

---

## 12. Variantes opt-in

### 12.1. Deshabilitar el panel `/admin` cuando no se necesita

Tras crear cuentas, configurar políticas y rotar passwords iniciales, el panel admin solo se necesita esporádicamente. Deshabilitarlo elimina la superficie:

```bash
sed -i 's/^ADMIN_TOKEN=.*$/ADMIN_TOKEN=/' /mnt/hd2t/services/vaultwarden/.env
docker compose --env-file /mnt/hd2t/services/vaultwarden/.env up -d --force-recreate
docker logs vaultwarden 2>&1 | grep -i admin
# Esperado: "[WARN][start] No `ADMIN_TOKEN` set: admin panel is disabled"
```

Cuando se vuelva a necesitar: regenerar el token (§5.3), recrear, hacer la operación, **volver a deshabilitarlo**.

### 12.2. Deshabilitar la web vault (solo extensión/escritorio/móvil)

`WEB_VAULT_ENABLED=false`. El `/` responde 404; toda la API sigue funcionando. Reduce la superficie pero pierde la única vía de acceso "desde un PC sin extensión instalada" (laptops invitados, ordenadores prestados). Solo recomendable si el operador es el único usuario y no usa nunca la UI.

### 12.3. SMTP para emails (invitaciones, alertas, reset password)

Si el operador tiene un relay SMTP (cuenta Gmail con app password, Mailgun, Brevo, propio Postfix sidecar), rellenar:

```env
SMTP_HOST=smtp.gmail.com
SMTP_FROM=vaultwarden@example.com
SMTP_USERNAME=user@gmail.com
SMTP_PASSWORD=<app password>
SMTP_PORT=587
SMTP_SECURITY=starttls
```

Activa: invitaciones por email automático, recovery password, alertas de seguridad, exportación de la bóveda con confirmación por email. Coste: añade un secreto más al circulante (la app password de SMTP) y una dependencia externa (el relay).

### 12.4. Tailscale-only (sin LAN)

Para un operador que NO quiere que Vaultwarden sea accesible desde la LAN aunque esté dentro de casa (defensa contra un IoT pirateado en la WiFi):

1. En el `Caddyfile`, comentar el bloque `vault.{$LAN_DOMAIN}` y dejar solo `vault.{$TS_DOMAIN}`.
2. Cambiar `DOMAIN=https://vault.${TS_DOMAIN}` en el `.env` (con cuidado: las URLs de Sends y emails saldrán con `tailnet.ts.net`).
3. Recargar Caddy.
4. Eliminar el registro DNS local en Pi-hole para `vault.lan`.

Ahora Vaultwarden solo es accesible vía Tailscale (incluido el propio operador desde su laptop con Tailscale activo en LAN — Tailscale prefiere LAN cuando disponible, así que sigue siendo rápido).

### 12.5. Imagen Debian-based en lugar de Alpine

Si una librería externa (p.ej. un `LDAP_*` extension custom) requiere glibc:

```env
VAULTWARDEN_IMAGE=vaultwarden/server:1.32.5
```

(Sin sufijo `-alpine`.) Coste: ~120 MB en disco vs ~30 MB. Sin diferencia funcional en el binario.

### 12.6. Authelia delante de `/admin` (defense-in-depth)

Si el operador quiere doble auth para el panel admin (ADMIN_TOKEN + Authelia 2FA):

```caddyfile
vault.{$LAN_DOMAIN} {
    import lan_internal_tls
    import security_headers

    # /admin pasa por Authelia (2FA), el resto NO.
    @admin path /admin*
    handle @admin {
        import authelia_proxy
        reverse_proxy http://vaultwarden:80 {
            header_up X-Real-IP {remote_host}
        }
    }

    handle {
        reverse_proxy http://vaultwarden:80 {
            header_up X-Real-IP {remote_host}
            header_up X-Forwarded-Proto {scheme}
            header_up X-Forwarded-For {remote_host}
        }
    }
}
```

Y añadir a `~/homelab/stacks/auth/configuration.yml` (Authelia):

```yaml
access_control:
  rules:
    - domain: "vault.{{ env "LAN_DOMAIN" }}"
      resources:
        - "^/admin.*"
      policy: two_factor
      subject: "group:admin"
```

Recargar Caddy + Authelia. Ahora `/admin` exige: (a) Authelia + TOTP, (b) ADMIN_TOKEN. El resto de paths (API + UI usuario + WS) sigue sin Authelia, los clientes funcionan.

### 12.7. Migrar a MariaDB (>50 usuarios)

Vaultwarden soporta MariaDB. Si la BD SQLite supera el GB y >50 usuarios concurrentes hacen contención:

1. `sqlite3 db.sqlite3 .dump > vw.sql`.
2. Adaptar `vw.sql` a MariaDB (o usar la herramienta `vaultwarden_migrate` de la comunidad).
3. Levantar un MariaDB en `~/homelab/stacks/vaultwarden/docker-compose.yml` (añadir servicio).
4. `DATABASE_URL=mysql://user:pass@mariadb:3306/vaultwarden` en el `.env`.
5. Re-importar.

Operación delicada — fuera de alcance del homelab "1–4 humanos".

### 12.8. `ICON_SERVICE=internal` (sin tráfico saliente a Bitwarden)

Por defecto Vaultwarden pide los favicons de los sitios a `icons.bitwarden.com`. Para evitar tráfico saliente:

```env
ICON_SERVICE=internal
```

Vaultwarden los descarga directamente desde los sites de cada ítem (cuando se añade) y los cachea en `data/`. Coste: el primer fetch tarda más; bloquea sites que requieran auth previa (raro). Beneficio: nada de telemetría a Bitwarden (Vaultwarden no la hace, pero `icons.bitwarden.com` registra hits).

### 12.9. CLI `bw` para automatizar

Instalar el cliente CLI de Bitwarden:

```bash
# En el laptop del operador (no en la Pi):
npm install -g @bitwarden/cli  # o snap, brew, ...

bw config server https://vault.lan
bw login user@example.com  # pide master password + TOTP
export BW_SESSION="$(bw unlock --raw)"

# Listar entradas:
bw list items | jq '.[].name'

# Crear una entrada desde un script (CI, automatización):
bw get template item | jq '.name="MyService" | .login.username="me" | .login.password="..."' \
    | bw encode | bw create item

bw lock
```

Útil para rotación automatizada de passwords desde un CI o un cron.

---

## Referencias

- [Vaultwarden — Repositorio oficial](https://github.com/dani-garcia/vaultwarden)
- [Vaultwarden — Wiki / Configuration](https://github.com/dani-garcia/vaultwarden/wiki)
- [Vaultwarden — Reverse proxy guides](https://github.com/dani-garcia/vaultwarden/wiki/Proxy-examples)
- [Vaultwarden — Docker Hub](https://hub.docker.com/r/vaultwarden/server)
- [Vaultwarden — Logging configuration (`LOG_FILE`)](https://github.com/dani-garcia/vaultwarden/wiki/Logging)
- [Vaultwarden — Enabling admin page](https://github.com/dani-garcia/vaultwarden/wiki/Enabling-admin-page)
- [Vaultwarden — `vaultwarden hash` (Argon2id token)](https://github.com/dani-garcia/vaultwarden/wiki/Enabling-admin-page#secure-the-admin_token)
- [Vaultwarden — Backing up your installation](https://github.com/dani-garcia/vaultwarden/wiki/Backing-up-your-vault)
- [Bitwarden — Self-hosted client configuration](https://bitwarden.com/help/change-client-environment/)
- [Bitwarden — Compatible third-party server (Vaultwarden)](https://bitwarden.com/help/install-on-premise-linux/)
- [OWASP — Password Storage Cheat Sheet (PBKDF2 600k iterations)](https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html)
- [SQLite — `.backup` command (online backup API)](https://www.sqlite.org/backup.html)
- [Caddy — `reverse_proxy` (WebSocket auto-handling)](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy)
