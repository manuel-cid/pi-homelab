# Vaultwarden (gestor de contraseñas privado, compatible con Bitwarden)

## Descripción

Despliegue de **Vaultwarden** como **gestor de contraseñas** central del homelab y de la "vida digital" del operador: cifrado E2EE compatible 100 % con los _clients_ oficiales de **Bitwarden** (escritorio, navegador, Android, iOS, CLI), bóveda alojada localmente sobre el disco externo **hd2t**, sin enviar credenciales a la nube de Bitwarden, y con _custodia_ explícita de la _master key_ del operador y de las _passphrase_ de Borgmatic, Authelia, MariaDB y demás servicios del propio homelab. Es la pieza que **cierra el círculo de secretos**: hasta ahora `docs/06-almacenamiento/01-nextcloud.md`, `docs/04-seguridad/01-authelia.md` y `docs/07-backups/02-borgmatic.md` mencionaban "guardar la passphrase en Vaultwarden cuando esté disponible"; aquí se materializa ese "Vaultwarden".

Este documento **estrena el _stack_ `productividad`** (`~/homelab/productividad/`) descrito en `docs/02-docker/02-estructura-compose.md` (tabla de stacks, fila `productividad`, fase `docs/11-productividad/`). El _stack_ alojará en fases siguientes a Bookstack (`02-bookstack.md`), Linkding (`03-linkding.md`), Paperless-ngx (`04-paperless-ngx.md`), Mealie (`05-mealie.md`), Stirling-PDF (`06-stirling-pdf.md`) y FreshRSS (`07-freshrss.md`); aquí sólo se materializa un único servicio:

- **`vaultwarden`** — re-implementación en Rust del servidor Bitwarden (imagen oficial `vaultwarden/server:1.32.7-alpine`). Una sola pieza: el binario sirve la API, el _web vault_ y las notificaciones WebSocket por el mismo puerto. Persistencia en SQLite local, sin BD aparte.

Caddy (stack `red`, `docs/03-red/04-caddy.md`) expone Vaultwarden en `https://vaultwarden.lan/` con TLS interno (CA local). Para acceso remoto vía Tailscale (`docs/03-red/05-tailscale.md`), `https://pi.<tailnet>.ts.net/` con MagicDNS sirve la misma bóveda al móvil cuando se está fuera de la LAN.

> **Alcance**: este documento despliega Vaultwarden con su autenticación nativa (email + master password, opcionalmente 2FA TOTP/WebAuthn dentro del propio Vaultwarden — **no** delegada a Authelia: ver **Decisiones de diseño**), crea **un único usuario** (el operador), **cierra el registro abierto** (`SIGNUPS_ALLOWED=false`) tras esa creación, **activa el _jail_ `vaultwarden`** del `fail2ban` contenerizado que dejó preparado `docs/04-seguridad/02-fail2ban.md` y **descomenta el _hook_ de Borgmatic** que dejó preparado `docs/07-backups/02-borgmatic.md` para hacer un dump consistente de la SQLite. **No** despliega `bitwarden_rs` _push relay_ (el _push_ de móvil real requiere registrarse en el servicio de Bitwarden, fuera del alcance del homelab; los _clients_ siguen funcionando perfectamente sin _push_, sólo con _polling_ al desbloquear). **No** activa la sincronización entre organizaciones (es un Vaultwarden personal, no una instalación corporativa). **No** configura SMTP en este documento (queda como **opcional** descrito al final, requiere un MTA o cuenta SMTP externa).

> **Recordatorio de red**: Vaultwarden **no se publica al host**. Caddy la alcanza por DNS interno de Docker (`vaultwarden:80` en la red `homelab`). No hay BD que aislar (SQLite vive dentro del propio contenedor sobre un _bind mount_), por lo que **no** hace falta una `productividad-internal`. Pi-hole resuelve `vaultwarden.lan → 192.168.1.3` por el _wildcard_ de `02-homelab-local.conf` (ver `docs/03-red/02-pihole.md`).

---

## Requisitos previos

- `docs/02-docker/02-estructura-compose.md` completado: la tabla de stacks reserva el _slot_ `productividad` que aquí se estrena, la red Docker `homelab` (`br-homelab`, `172.20.10.0/24`) externa está creada, `~/homelab/.env` global con `TZ=Europe/Madrid`, `PUID=1000`, `PGID=1000`, `HOMELAB_DOMAIN=lan` está rellenado, y el _Makefile_ de operación expone `make up STACK=<stack>`.
- `docs/01-sistema/04-estructura-directorios.md` completado: `/mnt/hd2t/services/vaultwarden/data/` ya existe vacío.
- `docs/02-docker/04-watchtower.md` completado: la convención `com.centurylinklabs.watchtower.enable` está documentada. Vaultwarden será **opt-out** explícito (ver **Decisiones de diseño**).
- `docs/03-red/02-pihole.md` completado: Pi-hole resuelve `*.lan → 192.168.1.3`. **No hay que añadir nada** para `vaultwarden.lan` — el _wildcard_ ya lo cubre.
- `docs/03-red/04-caddy.md` completado: Caddy escucha en `192.168.1.3:443` con `tls internal`, los _snippets_ `security-headers.caddy` y `logging.caddy` existen, y la directiva `import /etc/caddy/snippets/*.caddy` está activa en el `Caddyfile`. La CA local ya firma `*.lan`.
- `docs/04-seguridad/02-fail2ban.md` completado: el `fail2ban` contenerizado ya tiene definidos el _jail_ `vaultwarden` (en `enabled = false`) y el filtro `~/homelab/seguridad/fail2ban/filter.d/vaultwarden.local`. Aquí se cambia a `enabled = true` y se recarga.
- `docs/07-backups/02-borgmatic.md` completado: Borgmatic ya está corriendo con su _hook_ `before_backup`. El bloque comentado del dump de Vaultwarden (`# if docker ps --format '{{.Names}}' | grep -q '^vaultwarden$'; then …`) se descomentará en este documento.
- Conectividad saliente para descargar la imagen (sólo la primera vez):
  ```bash
  docker pull --platform linux/arm64 vaultwarden/server:1.32.7-alpine >/dev/null && echo OK
  ```
- Que el host **no** tenga ya un servicio escuchando en `:80` por error (`docker ps --format '{{.Names}} {{.Ports}}' | grep ':80->' || echo OK`). Este _stack_ no publica puertos al host; Caddy es quien recibe el tráfico HTTPS.
- Espacio en `/mnt/hd2t`: Vaultwarden es **muy ligero**. La instancia idle ocupa ~50 MB; con 1 000 entradas, attachments y _sends_ de un usuario único raramente supera 500 MB. Verificar holgura mínima:
  ```bash
  df -h /mnt/hd2t
  # Debe quedar holgado tras el arranque (~10 MB iniciales).
  ```

---

## Decisiones de diseño

### Por qué Vaultwarden (y no Bitwarden self-hosted, KeePassXC, 1Password, Pass)

El homelab necesita **un gestor de contraseñas** que cumpla a la vez: bóveda cifrada E2EE (la master password nunca sale del cliente), _clients_ multi-plataforma maduros (browser, móvil, escritorio, CLI), sincronización automática entre dispositivos, soporte para 2FA almacenadas (TOTP), _attachments_ para guardar PDFs sensibles (recovery codes, claves SSH cifradas), _Sends_ (compartir un secreto con caducidad y sin cuenta) y, sobre todo, **autohospedaje sin nube**. Cuatro candidatos y por qué se descartan:

| Candidato                         | Por qué se descarta                                                                                                                                         |
|-----------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **Bitwarden _self-hosted_ oficial** | La imagen oficial `bitwarden/self-host` es **una pila Docker pesada**: MSSQL Server, IIS embebido, Identity, Admin, Web, Notifications, Icons, SSO, Events, Portal — 8+ contenedores, ~3 GB de RAM y un _Setup script_ obligatorio. Sobredimensionado y rompe el principio "una Pi 5 con 8 GB tiene que vivir holgada". |
| **KeePassXC + sync por Nextcloud**  | Cero servidor (es un fichero `.kdbx` sincronizado), pero los _clients_ de móvil son más pobres (Keepass2Android, KeePassium) y no hay _Sends_, ni estructura de organización, ni _attachments_ por entrada (dentro del kdbx sí, pero crece sin control). El conflicto de escrituras concurrentes es real: si el escritorio y el móvil escriben a la vez, Nextcloud crea una _conflict copy_ y hay que mergear a mano. **Inviable** para uso diario en familia. |
| **1Password / LastPass / Dashlane** | Todos son _SaaS_ cerrados. No autohospedables. Fuera del modelo de homelab.                                                                                  |
| **`pass` (passwordstore.org)**    | Excelente para un usuario _power_ con CLI y GPG, pero requiere GPG en cada dispositivo y los _clients_ móviles existentes son rudimentarios. No tiene _Sends_, no tiene 2FA TOTP nativo, no tiene web vault. **Inadecuado para uso familiar**. |

Vaultwarden gana por:

- **Compatibilidad 100 % con los _clients_ oficiales de Bitwarden** (cliente móvil F-Droid, app de escritorio, extensiones Chrome/Firefox/Edge, cli `bw`). La API es _drop-in_ — los _clients_ ni siquiera saben que están hablando con Vaultwarden, sólo apuntan al _self-hosted server_ y entran.
- **Re-implementación en Rust**: ~50 MB de RAM idle, multi-arch ARM64, una imagen Docker, una SQLite por defecto. **Ligero como una pluma** comparado con la pila de MSSQL del Bitwarden oficial.
- **Mantenimiento activo**: `dani-garcia/vaultwarden` recibe _releases_ todos los meses, sigue de cerca los cambios de la API de Bitwarden, suele tardar semanas (no meses) en soportar las funcionalidades nuevas (Bitwarden Send, Argon2id KDF, passkeys).
- **Compatibilidad de bóveda**: si en algún momento se decidiese **migrar** a Bitwarden cloud o al Bitwarden self-hosted oficial, los _clients_ exportan la bóveda en JSON cifrado, se importa en el destino y se acabó. **Sin lock-in**.

### Imagen y _tag_

- **`vaultwarden/server:1.32.7-alpine`** — Vaultwarden 1.32.7, variante Alpine (más pequeña que la Debian: 30 MB vs 70 MB descomprimidos). Multi-arch (`linux/arm64`). Pinneada a _tag_ "minor exacto" siguiendo la convención del homelab (ver `docs/02-docker/02-estructura-compose.md`, sección **Imágenes**: nada de `:latest`, "Tag mayor o LTS"). Vaultwarden no tiene _tag_ "mayor" estable (1.x se mueve sólo en el _patch_, no hay 2.0 anunciado), así que se pinea al _patch_ exacto y se controla la actualización a mano.
- Variante **`-alpine`**: el binario de Vaultwarden está construido estáticamente, no necesita la libc de Debian. Alpine ahorra superficie de ataque (menos paquetes) y disco. La variante `-alpine` está oficialmente soportada por el equipo de `vaultwarden/server`.

#### Watchtower opt-out

Razones:

- Vaultwarden almacena un **secreto crítico** (la bóveda del operador y de la familia). Una actualización con un _bug_ que corrompiese la SQLite o cambiase el formato del campo `cipher.attachments` dejaría sin acceso a las contraseñas hasta restaurar de backup. **Manual**, leyendo el _changelog_ y haciendo backup previo.
- Aunque las _releases_ de Vaultwarden son cuidadas, la _community_ del proyecto recomienda explícitamente **no** automatizar las actualizaciones del servidor de contraseñas: una ventana de revisión manual antes de aplicarla es barato y blinda contra _supply chain attacks_ contra el _registry_ Docker.

Etiquetar con `com.centurylinklabs.watchtower.enable: "false"`.

### SQLite, no MariaDB ni PostgreSQL

Vaultwarden soporta SQLite (default), MySQL/MariaDB y PostgreSQL como _backend_ de persistencia. Elección: **SQLite**. Razones:

- **Es un Vaultwarden personal**: 1–4 usuarios (operador y familia), entre 200 y 5 000 entradas en total, decenas de _logins_/sincronizaciones por hora en pico. SQLite es **muy** suficiente: la documentación oficial de Vaultwarden dice explícitamente "SQLite is the default and recommended for almost all deployments".
- **Backup trivial**: un único fichero `db.sqlite3` que se respalda con `sqlite3 db.sqlite3 ".backup db.sqlite3.backup"` (copia consistente sin _stop_). Esto es lo que usa el _hook_ de Borgmatic preparado en `docs/07-backups/02-borgmatic.md` (el bloque comentado de Vaultwarden).
- **Cero contenedores extra**: MariaDB / Postgres añadirían ~200 MB de RAM, otra ventana de mantenimiento, otro punto de fallo y otro _hook_ de dump SQL. Para 4 usuarios es _overkill_.
- **Restauración simple**: si la SQLite se corrompe (escribir en disco lleno, _kill -9_ del contenedor en pleno commit), `sqlite3 db.sqlite3 ".recover" | sqlite3 db.sqlite3.recovered` restaura el 99 % de los casos. Con MariaDB un crash mal sincronizado puede dejar el _data dir_ en un estado que requiera `mariadb-recover` y conocimiento experto.

Si en algún momento futuro el homelab creciera a >50 usuarios o se compartiese con la _extended family_ y SQLite empezase a sufrir _SQLITE_BUSY_ por contención de escritores, la migración a Postgres está documentada por el equipo de Vaultwarden y consiste en exportar/importar (la app `vaultwarden_db_migration` o un dump JSON + reimport). No urge.

### `forward_auth` con Authelia: **NO** para Vaultwarden

Misma decisión que en Nextcloud (`docs/06-almacenamiento/01-nextcloud.md`, sección homónima), por las mismas razones — pero con un matiz extra:

- **Los _clients_ de Bitwarden hablan la API REST con _Bearer tokens_** (login devuelve `access_token` + `refresh_token`). No siguen redirects HTML. Si Caddy intercepta una petición a `/api/sync` o `/identity/connect/token` con un `302` hacia `https://auth.lan/?rd=...`, el cliente falla con `Network error` o `Invalid response` y el operador ve "no se puede conectar al servidor".
- **El cifrado E2EE de Vaultwarden depende de la master password** del usuario (deriva la _stretched key_ con PBKDF2 / Argon2id, descifra la bóveda local). **Authelia no aporta nada al cifrado**: aunque Authelia hiciera de _front gate_, la master password seguiría siendo necesaria para descifrar la bóveda. Una capa de SSO antes del _login_ de Vaultwarden añade fricción sin añadir seguridad real al contenido cifrado.
- **El `/admin` de Vaultwarden** sí acepta password de admin (env var `ADMIN_TOKEN`, hashed con Argon2 desde 1.32). Esto es un panel HTTP simple y **sí** podría ir detrás de Authelia… pero hacerlo bien requiere `forward_auth` sólo para `/admin/*`, lo que no merece el riesgo de un mismatch entre el path-matcher de Caddy y el de Authelia (un `/admin` mal escapado podría dejar todo el `/admin/*` sin protección si Authelia falla _open_). Solución más simple, descrita más abajo: el _admin panel_ se accede **sólo desde Tailscale** y se desactiva (`DISABLE_ADMIN_TOKEN=true`) tras el setup inicial.

> **Resumen operativo**: el bloque `vaultwarden.lan` del `Caddyfile` lleva `import security-headers` y `import logging`, pero **no** `import authelia`. Caddy actúa como _reverse proxy_ "tonto"; Vaultwarden autentica con la master password del usuario y, opcionalmente, 2FA TOTP/WebAuthn de su propio sistema.

### Argon2id como KDF, no PBKDF2

Bitwarden / Vaultwarden usan un **KDF** (Key Derivation Function) para convertir la master password del usuario en la _stretched master key_ que descifra la bóveda. Los _clients_ permiten elegir entre **PBKDF2** (default histórico, 600 000 iteraciones) y **Argon2id** (recomendación moderna, mucho más resistente a GPU).

Decisión: **forzar Argon2id como KDF por defecto** en este Vaultwarden (`PASSWORD_HASHER=argon2id` y guía al operador para que en `Settings → Security → Keys` ponga su propia master a Argon2id). Razones:

- Argon2id 64 MB / 3 iter requiere 64 MB de RAM y ~250 ms en una CPU moderna; en una **GPU de cracking** (NVIDIA RTX 4090) reduce el _throughput_ a unos pocos miles de intentos por segundo. PBKDF2-SHA256 con 600 k iter sigue siendo crackeable a millones de intentos por segundo con la misma GPU. La diferencia es real.
- Coste: el _login_ tarda ~250 ms más en cualquier dispositivo; imperceptible.
- Si una _backup_ de la bóveda cifrada cayese en manos de un atacante (improbable en un homelab privado, pero no inverosímil — el _offsite_ de Borgmatic cruza Internet), Argon2id le compra al operador **órdenes de magnitud** más tiempo para cambiar la master password antes de que la bóveda quede expuesta.

> **Aviso**: cambiar el KDF **re-cifra toda la bóveda** localmente y la sube de nuevo al servidor. Tras cambiar a Argon2id, conviene hacer logout y re-login en todos los _clients_ activos para que recojan la nueva _stretched key_; en algunos _clients_ obsoletos (extensión muy vieja) puede haber un fallo de "Invalid Master Password" que se arregla con _logout/login_.

### Admin panel: token Argon2id + `DISABLE_ADMIN_TOKEN` tras setup, acceso sólo por Tailscale

Vaultwarden expone un _admin panel_ en `/admin` (panel HTML sencillo con configuración, gestión de usuarios, invitaciones, _diagnostics_). Se autentica con un único token (`ADMIN_TOKEN`).

**Cambios desde Vaultwarden 1.32**: el `ADMIN_TOKEN` ahora **debe** estar **hasheado con Argon2id**, no en texto plano (el formato plano sigue funcionando con un _warning_, pero está deprecado). Se hashea con un comando que provee la propia imagen.

**Política aplicada en este homelab**:

1. Generar un `ADMIN_TOKEN` aleatorio fuerte (32+ caracteres) y hashearlo con `vaultwarden hash`.
2. Configurar Caddy para que el _path_ `/admin/*` **sólo** sea alcanzable desde la subnet de Tailscale (`100.64.0.0/10`) y desde la LAN local (`192.168.1.0/24`); peticiones a `/admin/*` desde otras IPs reciben `403`.
3. Tras el setup inicial (crear el usuario operador, configurar SMTP si se quiere, ajustar opciones), **deshabilitar** el panel completamente con `DISABLE_ADMIN_TOKEN=true`. Si más adelante hace falta volver a entrar (cambiar SMTP, expulsar a un usuario), se quita esa env var, se reinicia el contenedor, se hace lo necesario y se vuelve a poner.

> **Por qué Tailscale + LAN restrict**: el _admin panel_ es un único token compartido (no hay 2FA en él). Una _brute force_ contra el panel desde la LAN doméstica no es probable, pero desde una IP cualquiera del Internet — si en el futuro el homelab se expusiese accidentalmente — sería desastrosa. Restringir por _path_ de Caddy es una **defensa en profundidad** sobre el `DISABLE_ADMIN_TOKEN` (que es la primaria).

### WebSockets en el mismo puerto (sin `:3012` separado)

Hasta Vaultwarden 1.28 las notificaciones de cambio en tiempo real entre _clients_ usaban un _socket_ separado en el puerto `3012` (Bitwarden _notification hub_), lo que obligaba al operador a configurar el _reverse proxy_ con dos _upstreams_ (`/notifications/hub` → `:3012`, todo lo demás → `:80`). **Desde Vaultwarden 1.29 ese puerto se eliminó**: los WebSockets viajan sobre el mismo `:80` que el resto, y Caddy lo soporta nativamente (`reverse_proxy` detecta `Connection: Upgrade` y hace _passthrough_ correcto sin configuración extra).

Consecuencia: el bloque del `Caddyfile` para `vaultwarden.lan` es **trivial** (un único `reverse_proxy vaultwarden:80`), sin _matchers_ por path. La env var `WEBSOCKET_ENABLED=true` (default desde 1.29) confirma que el binario sirve WS en el mismo socket.

### `IP_HEADER` para que el log sea útil para fail2ban

Vaultwarden, al ser proxy-reverseado por Caddy, ve todo el tráfico viniendo de `172.20.10.x` (la IP del contenedor de Caddy en la red `homelab`). Sin más, el log de un _login_ fallido sería:

```
[2026-04-25 12:34:56][warning][vaultwarden::api::identity] Username or password is incorrect. Try again. IP: 172.20.10.4. Username: foo
```

…lo que dejaría al _jail_ de `fail2ban` (`docs/04-seguridad/02-fail2ban.md`) inutilizado: **siempre banearía a Caddy**. Solución:

- En Caddy: `header_up X-Real-IP {remote_host}` ya está en el _snippet_ del proyecto.
- En Vaultwarden: env var `IP_HEADER=X-Real-IP`.

Con esa pareja, Vaultwarden lee la IP real del cliente desde la cabecera y la pone en el log:

```
[...] IP: 192.168.1.50. Username: foo
```

…que es lo que el _filter_ `~/homelab/seguridad/fail2ban/filter.d/vaultwarden.local` (preparado en `docs/04-seguridad/02-fail2ban.md`) sabe parsear con `<HOST>`.

### Almacenamiento

| Ruta en el host                                   | Contenido                                                        | Versionable | Backup |
|---------------------------------------------------|------------------------------------------------------------------|-------------|--------|
| `~/homelab/productividad/docker-compose.yml`      | Definición del _stack_                                            | git         | git    |
| `~/homelab/productividad/.env`                     | Imágenes pinneadas + `ADMIN_TOKEN` hash + secrets                 | **NO** (`.gitignore`) | nota local (custodia separada) |
| `~/homelab/productividad/.env.example`             | Plantilla con nombres de variables, sin valores                   | git         | git    |
| `~/homelab/productividad/.gitignore`               | Excluye `.env`                                                    | git         | git    |
| `/mnt/hd2t/services/vaultwarden/data/db.sqlite3`   | Base de datos SQLite (entradas, usuarios, organizaciones)         | **NO**      | **Sí** (Borgmatic, vía `.backup` consistente) |
| `/mnt/hd2t/services/vaultwarden/data/attachments/` | Adjuntos cifrados de las entradas                                 | **NO**      | **Sí** (Borgmatic, copia raw) |
| `/mnt/hd2t/services/vaultwarden/data/sends/`       | Bitwarden Sends (ficheros temporales con caducidad)               | **NO**      | **Sí** (Borgmatic) |
| `/mnt/hd2t/services/vaultwarden/data/rsa_key.*`    | Par de claves RSA del servidor (firma de _access tokens_)        | **NO**      | **Sí** (Borgmatic — **crítico**) |
| `/mnt/hd2t/services/vaultwarden/data/icon_cache/`  | Caché de favicons de los sitios; regenerable                      | **NO**      | No (excluido del backup) |
| `/mnt/hd2t/services/vaultwarden/data/vaultwarden.log` | Log de la app (consumido por `fail2ban`)                       | **NO**      | No (transitorio) |

> **`rsa_key.*` es crítico**: si se pierden, todos los _clients_ activos verán sus _access tokens_ invalidados y necesitarán hacer _login_ de nuevo (no es catastrófico, pero es molesto si pasa en la familia). Se respalda con Borgmatic igual que el resto del directorio.

> **`icon_cache/` se excluye del backup**: puede llegar a crecer a cientos de MB con uso normal y son favicons descargados de Internet. Borgmatic lo excluirá explícitamente (ver _set_ "data" en `docs/07-backups/02-borgmatic.md`).

> **Permisos de `/mnt/hd2t/services/vaultwarden/data/`**: la imagen `vaultwarden/server:1.32.7-alpine` corre como **root** dentro del contenedor (no hay variable `PUID`/`PGID`; el binario fija sus propios permisos). El _entrypoint_ no hace `chown`; espera que el _bind mount_ sea escribible por root. Como el host monta `/mnt/hd2t` con `nobootwait,errors=remount-ro` (ver `docs/00-hardware/03-preparacion-discos.md`) y el subdirectorio se creó con `root:root 0755` en `docs/01-sistema/04-estructura-directorios.md`, **no hay nada que ajustar**. Se confirma en el primer arranque (sección **Despliegue**).

---

## Estructura del _stack_ `productividad` tras este documento

```
~/homelab/productividad/
├── docker-compose.yml        # ← nuevo
├── .env                      # ← nuevo (NO versionado)
├── .env.example              # ← nuevo (versionado)
└── .gitignore                # ← nuevo (excluye .env)
```

Y en el disco externo, sobre lo que ya creó `docs/01-sistema/04-estructura-directorios.md`:

```
/mnt/hd2t/services/vaultwarden/
└── data/                     # creado en docs/01-sistema/04-estructura-directorios.md
```

Crear el subdirectorio del _stack_ y el _stub_ de gitignore:

```bash
mkdir -p ~/homelab/productividad
chmod 0750 ~/homelab/productividad

cat > ~/homelab/productividad/.gitignore <<'EOF'
# Secretos del stack — NUNCA commitear
.env
EOF
```

> **Ownership de `/mnt/hd2t/services/vaultwarden/data/`**: ya es `root:root 0755`; la imagen corre como `root` dentro del contenedor y escribe sin problema. **No hay que pre-chown-ear**.

---

## Variables de entorno

### `~/homelab/productividad/.env.example`

Crear (versionado en git, sin valores reales):

```bash
# --- Imágenes pinneadas -----------------------------------------------------
VAULTWARDEN_IMAGE_TAG=1.32.7-alpine

# --- Vaultwarden — endpoints y dominio --------------------------------------
# URL pública canónica del servicio. CRÍTICO: WebAuthn / passkeys validan
# que el origin del cliente coincide con esta URL byte a byte. Cambiarla
# después invalida las llaves físicas registradas hasta que se re-registren.
VAULTWARDEN_DOMAIN=https://vaultwarden.lan

# --- Vaultwarden — política de registro -------------------------------------
# La PRIMERA arrancada se hace con SIGNUPS_ALLOWED=true para que el operador
# pueda crear su cuenta. INMEDIATAMENTE DESPUÉS se cambia a 'false' (ver
# 'Configuración tras primer arranque').
SIGNUPS_ALLOWED=true

# Quien tenga cuenta puede invitar (genera un email con link de alta).
# Sólo útil si SMTP está configurado.
INVITATIONS_ALLOWED=true

# Sólo correos de estos dominios pueden registrarse. Vacío = cualquiera
# (siempre que SIGNUPS_ALLOWED=true). Tras cerrar el alta, esto deja de
# importar.
# SIGNUPS_DOMAINS_WHITELIST=tu-dominio.example,homelab.local

# --- Vaultwarden — Admin panel (/admin) -------------------------------------
# Token hasheado con Argon2id. Generación:
#   docker run --rm vaultwarden/server:1.32.7-alpine /vaultwarden hash
# Pegar el hash COMPLETO incluyendo el prefijo $argon2id$v=19$...
# Tras setup inicial, poner DISABLE_ADMIN_TOKEN=true y borrar este valor.
ADMIN_TOKEN=

# Cambiar a 'true' tras la configuración inicial para deshabilitar el panel.
DISABLE_ADMIN_TOKEN=false

# --- Vaultwarden — proxy reverso (Caddy) ------------------------------------
# Cabecera de la que Vaultwarden saca la IP real del cliente. Caddy envía
# X-Real-IP. Sin esto, fail2ban banearía siempre a Caddy.
IP_HEADER=X-Real-IP

# Confiar en proxies que llegan desde la red Docker 'homelab'. Coincide con
# el bloque NEXTCLOUD_TRUSTED_PROXIES de docs/06-almacenamiento/01-nextcloud.md.
TRUSTED_PROXIES=172.20.10.0/24

# --- Vaultwarden — KDF y seguridad ------------------------------------------
# Argon2id en lugar del PBKDF2 default. Aplica a USUARIOS NUEVOS; los
# existentes lo cambian desde Settings → Security → Keys.
PASSWORD_HASHER=argon2id

# --- Vaultwarden — features que NO se usan en este homelab ------------------
# Push notifications oficiales de Bitwarden — requieren registrarse en su
# servicio cloud. En homelab dejamos polling.
PUSH_ENABLED=false

# Emergency Access (delegar acceso a un contacto si fallece el operador).
# Requiere SMTP. Off hasta que SMTP se configure.
EMERGENCY_ACCESS_ALLOWED=false

# Sends (compartir secretos con caducidad). Requieren SMTP para los emails
# de notificación al receptor pero funcionan sin él (sólo se comparte el
# link manualmente). Activado.
SENDS_ALLOWED=true

# --- Vaultwarden — logging --------------------------------------------------
LOG_FILE=/data/vaultwarden.log
LOG_LEVEL=warn
EXTENDED_LOGGING=true

# --- SMTP (opcional, ver sección 'SMTP opcional') ---------------------------
# Vacío = funcionalidad de email deshabilitada. Sin SMTP siguen funcionando
# login y bóveda; sólo se pierden invitaciones y avisos de seguridad por
# email.
# SMTP_HOST=
# SMTP_FROM=
# SMTP_PORT=587
# SMTP_SECURITY=starttls
# SMTP_USERNAME=
# SMTP_PASSWORD=

# --- Limpieza automática ----------------------------------------------------
# Días de retención de la papelera. 30 es razonable; 0 = nunca borrar.
TRASH_AUTO_DELETE_DAYS=30
```

### `~/homelab/productividad/.env`

Copiar la plantilla y rellenar los valores. El paso clave es generar el `ADMIN_TOKEN` hasheado:

```bash
cp ~/homelab/productividad/.env.example ~/homelab/productividad/.env
chmod 0600 ~/homelab/productividad/.env

# 1. Generar un ADMIN_TOKEN aleatorio fuerte (32 chars, base64 sin slashes)
admin_plain=$(openssl rand -base64 48 | tr -d '/+=' | head -c 32)
echo "ADMIN_TOKEN (texto plano, GUARDAR EN PAPEL TEMPORALMENTE): $admin_plain"

# 2. Hashearlo con la propia imagen (Argon2id, parámetros recomendados por
#    Vaultwarden upstream). El comando lee del stdin y escribe el hash completo.
admin_hash=$(docker run --rm -i vaultwarden/server:1.32.7-alpine \
    /vaultwarden hash --preset bitwarden <<<"$admin_plain")
echo "ADMIN_TOKEN (hash, va al .env): $admin_hash"

# 3. Inyectarlo en .env (escapando el $ para que sed no lo interprete)
admin_hash_esc=$(printf '%s\n' "$admin_hash" | sed 's/[\/&]/\\&/g')
sed -i "s|^ADMIN_TOKEN=$|ADMIN_TOKEN=$admin_hash_esc|" ~/homelab/productividad/.env

# 4. Confirmar
grep '^ADMIN_TOKEN=' ~/homelab/productividad/.env
# ADMIN_TOKEN=$argon2id$v=19$m=65540,t=3,p=4$<base64>$<base64>

# 5. Limpiar las variables de la sesión
unset admin_plain admin_hash admin_hash_esc
```

> **Custodia del `admin_plain`**: anotarlo en **papel** (sobre cerrado) y, **una vez Vaultwarden esté operativo**, crear una nota "Homelab — Vaultwarden admin token" dentro del propio Vaultwarden con ese valor. Tras `DISABLE_ADMIN_TOKEN=true` el token deja de ser útil para acceder al panel; lo guardamos por si en el futuro hay que reactivarlo. **No** dejarlo en el shell history (`history -c` o usar un `read -s admin_plain` en lugar del `openssl` directo si la paranoia exige más).

> **No commitear `.env` jamás**. El `.gitignore` del _stack_ ya lo excluye explícitamente.

---

## `~/homelab/productividad/docker-compose.yml`

```yaml
---
# Stack: productividad — Vaultwarden (gestor de contraseñas privado)
# Documentación: docs/11-productividad/01-vaultwarden.md

services:

  # ---------------------------------------------------------------------------
  # Vaultwarden — servidor Bitwarden-compatible en Rust.
  # Sirve API + web vault + WebSockets en el mismo puerto :80 desde 1.29.
  # ---------------------------------------------------------------------------
  vaultwarden:
    image: vaultwarden/server:${VAULTWARDEN_IMAGE_TAG}
    container_name: vaultwarden
    hostname: vaultwarden
    restart: unless-stopped
    environment:
      TZ: ${TZ}

      # --- Dominio / endpoints ---
      DOMAIN: ${VAULTWARDEN_DOMAIN}

      # --- Política de registro ---
      SIGNUPS_ALLOWED: ${SIGNUPS_ALLOWED}
      INVITATIONS_ALLOWED: ${INVITATIONS_ALLOWED}
      # SIGNUPS_DOMAINS_WHITELIST: ${SIGNUPS_DOMAINS_WHITELIST:-}

      # --- Admin panel ---
      ADMIN_TOKEN: ${ADMIN_TOKEN}
      DISABLE_ADMIN_TOKEN: ${DISABLE_ADMIN_TOKEN}

      # --- Reverse proxy ---
      IP_HEADER: ${IP_HEADER}
      TRUSTED_PROXIES: ${TRUSTED_PROXIES}

      # --- KDF ---
      PASSWORD_HASHER: ${PASSWORD_HASHER}

      # --- Features off/on ---
      PUSH_ENABLED: ${PUSH_ENABLED}
      EMERGENCY_ACCESS_ALLOWED: ${EMERGENCY_ACCESS_ALLOWED}
      SENDS_ALLOWED: ${SENDS_ALLOWED}

      # --- Logging ---
      LOG_FILE: ${LOG_FILE}
      LOG_LEVEL: ${LOG_LEVEL}
      EXTENDED_LOGGING: ${EXTENDED_LOGGING}

      # --- Limpieza ---
      TRASH_AUTO_DELETE_DAYS: ${TRASH_AUTO_DELETE_DAYS}

      # --- SMTP (opcional, descomentar cuando se configure) ---
      # SMTP_HOST: ${SMTP_HOST}
      # SMTP_FROM: ${SMTP_FROM}
      # SMTP_PORT: ${SMTP_PORT}
      # SMTP_SECURITY: ${SMTP_SECURITY}
      # SMTP_USERNAME: ${SMTP_USERNAME}
      # SMTP_PASSWORD: ${SMTP_PASSWORD}

      # --- Tuning interno ---
      # No publicar puertos; sólo Caddy llega aquí.
      ROCKET_PORT: 80
      # WebSockets en el mismo socket que el resto (default desde 1.29).
      WEBSOCKET_ENABLED: "true"
    volumes:
      - /mnt/hd2t/services/vaultwarden/data:/data
    networks:
      homelab:
        aliases:
          - vaultwarden       # Caddy resuelve 'vaultwarden:80' por este alias
    labels:
      homelab.stack: "productividad"
      homelab.backup: "true"      # /mnt/hd2t/services/vaultwarden (vía .backup SQLite)
      # Opt-out: bóveda crítica. Las upgrades se hacen a mano con backup previo.
      com.centurylinklabs.watchtower.enable: "false"
    healthcheck:
      # /alive es el endpoint público de healthcheck de Vaultwarden ≥1.28.
      # Devuelve un JSON con el timestamp y la versión.
      test:
        - CMD-SHELL
        - "wget -qO- http://localhost:80/alive >/dev/null"
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 30s

# ---------------------------------------------------------------------------
# Redes
# ---------------------------------------------------------------------------
networks:
  homelab:
    external: true               # creada en docs/02-docker/02-estructura-compose.md
```

Notas de diseño:

- **Sin red `productividad-internal`**: Vaultwarden no tiene BD aparte (SQLite intra-contenedor) ni dependencia de otro servicio en este _stack_. El _stack_ tiene **un único contenedor**. Si en `docs/11-productividad/02-bookstack.md` aparece una MariaDB, ese documento creará `productividad-internal` con sólo `bookstack` y `bookstack-db` dentro, sin afectar a Vaultwarden.
- **Sin `ports:`**: Caddy alcanza `vaultwarden:80` por DNS interno de la red `homelab`. Si el operador quiere _curlear_ a Vaultwarden sin pasar por Caddy: `docker exec vaultwarden wget -qO- http://localhost/alive`.
- **`healthcheck`**: `/alive` es el endpoint canónico de Vaultwarden ≥1.28 para _healthchecks_. Respuesta esperada: `{"now":"2026-04-25T12:34:56Z","version":"1.32.7"}`. La imagen Alpine **trae `wget`** preinstalado (no `curl`), por eso se usa `wget`.
- **`start_period: 30s`**: Vaultwarden arranca rápido. La primera vez crea `db.sqlite3` y `rsa_key.*`; ~3 s en una Pi 5. 30 s da margen sobrado.
- **Watchtower opt-out**: razones explicadas en **Decisiones de diseño** → _Imagen y tag_.
- **Sin `user:` explícito**: la imagen oficial corre como root dentro del contenedor por diseño (el binario fija sus permisos en `/data`). No se intenta forzar `user: ${PUID}:${PGID}` aquí, porque se ha visto romper el _entrypoint_ en algunas releases (el binario crea `db.sqlite3` con dueño 0:0 antes de que el `user:` aplique al runtime).

---

## Despliegue

### Primer arranque

```bash
cd ~/homelab/productividad
docker compose --env-file ../.env --env-file .env config | head -40   # validar sintaxis
docker compose --env-file ../.env --env-file .env up -d
```

O, equivalente, con el _Makefile_ (ver `docs/02-docker/02-estructura-compose.md`):

```bash
cd ~/homelab
make up STACK=productividad
```

Vigilar el primer arranque (es muy rápido, ~5 s):

```bash
docker compose -f ~/homelab/productividad/docker-compose.yml logs -f vaultwarden
# ...
# vaultwarden | [INFO][start] Rocket has launched from http://0.0.0.0:80
# vaultwarden | [INFO][server] Web vault (...) loaded
```

Verificar que el contenedor está `(healthy)`:

```bash
docker compose -f ~/homelab/productividad/docker-compose.yml ps
# NAME           STATUS                   PORTS
# vaultwarden    Up X seconds (healthy)
```

> El `(healthy)` lo otorga el _healthcheck_ de `/alive`. Si tras 1 minuto sigue `starting`, ir a **Troubleshooting** → primer arranque.

Confirmar que `db.sqlite3` y `rsa_key.*` se han creado bien:

```bash
ls -la /mnt/hd2t/services/vaultwarden/data/
# -rw------- 1 root root  20480 Apr 25 12:00 db.sqlite3
# -rw------- 1 root root      0 Apr 25 12:00 db.sqlite3-shm
# -rw------- 1 root root      0 Apr 25 12:00 db.sqlite3-wal
# -rw------- 1 root root   1704 Apr 25 12:00 rsa_key.pem
# -rw------- 1 root root    459 Apr 25 12:00 rsa_key.pub.pem
# drwxr-xr-x 2 root root   4096 Apr 25 12:00 attachments/
# drwxr-xr-x 2 root root   4096 Apr 25 12:00 sends/
# drwxr-xr-x 2 root root   4096 Apr 25 12:00 icon_cache/
# -rw------- 1 root root      0 Apr 25 12:00 vaultwarden.log
```

### Caddy: bloque `vaultwarden.lan`

Editar `~/homelab/red/Caddyfile` y añadir el bloque:

```caddy
vaultwarden.lan {
    tls internal
    import security-headers
    import logging

    # Restringir /admin/* a la LAN local + Tailscale.
    # Defensa en profundidad sobre DISABLE_ADMIN_TOKEN=true (que se aplicará
    # tras el setup inicial). Cualquier IP fuera de estas subnets que pegue
    # a /admin recibe un 403 antes de tocar a Vaultwarden.
    @admin {
        path /admin /admin/*
        not remote_ip 192.168.1.0/24 100.64.0.0/10 172.20.10.0/24 127.0.0.1/32
    }
    handle @admin {
        respond "Forbidden" 403 {
            close
        }
    }

    # Resto: pasar a Vaultwarden tal cual. Caddy detecta el upgrade a
    # WebSocket en /notifications/hub y hace passthrough automático
    # (Connection: Upgrade + Upgrade: websocket).
    reverse_proxy vaultwarden:80 {
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
curl -k --resolve vaultwarden.lan:443:192.168.1.3 https://vaultwarden.lan/alive
# {"now":"2026-04-25T12:34:56.789Z","version":"1.32.7"}

# Probar el matcher anti-/admin desde una IP NO en las subnets permitidas
# (truco: forzar X-Forwarded-For; sólo confiamos en remote_host real, así
# que esto no engañará al matcher pero ayuda a verificar que respond 403):
curl -k --resolve vaultwarden.lan:443:192.168.1.3 \
    -o /dev/null -s -w "%{http_code}\n" \
    https://vaultwarden.lan/admin
# 200 si curl viene de la LAN (192.168.1.x), 403 si viene desde otra subnet.
```

Y desde el navegador: `https://vaultwarden.lan/` → pantalla de bienvenida del web vault, con "Log in" y "Create account".

---

## Configuración tras primer arranque

### 1. Crear la cuenta del operador

`SIGNUPS_ALLOWED=true` está activo **sólo** durante este paso. En el web vault:

1. `Create account` → email del operador (puede ser cualquier email, real o no; sin SMTP no se envía nada de validación) → master password (≥ 14 caracteres, anotada en papel hasta que la propia bóveda exista para guardarla).
2. Login con la cuenta recién creada.
3. `Settings → Security → Keys → KDF`:
   - Cambiar `KDF Algorithm` a **Argon2id**.
   - Iterations: `3`, Memory: `64 MB`, Parallelism: `4` (defaults razonables).
   - Introducir master password para confirmar el _re-cipher_ de la bóveda.

> **El KDF se aplica al usuario actual**, no globalmente. Cada usuario que se cree después tendrá que cambiarlo a Argon2id en sus propios _Settings_, **a menos** que se ponga la env var `PASSWORD_HASHER=argon2id` en el `.env` (ya está): así, los usuarios nuevos arrancan con Argon2id por defecto y no necesitan tocar nada.

### 2. Activar 2FA TOTP (recomendado) o WebAuthn (si hay llave física)

En `Settings → Security → Two-step Login`:

- **Authenticator app (TOTP)** — escanear el QR con Aegis / Authy / 1Password / `oath-tool`. Apuntar el _secret_ en papel también; si se pierde el dispositivo TOTP, ese papel salva la cuenta.
- **(Opcional) FIDO2 WebAuthn** — registrar una llave YubiKey / Solokey. Sólo funciona si el navegador alcanza Vaultwarden por **HTTPS con certificado válido** (la CA local del homelab debe estar importada — `docs/03-red/04-caddy.md`).
- **Recovery code**: descargar y guardar en papel + en una nota dentro del propio Vaultwarden (cuando ya esté la bóveda viva). Sin recovery code y con el TOTP perdido, el único camino es `vaultwarden user:reset-2fa` desde el _admin panel_.

> **Por qué TOTP _antes_ de cerrar el alta**: si por algún motivo la cuenta queda inaccesible y `SIGNUPS_ALLOWED=false`, no hay forma de recrearla sin entrar al _admin panel_ con el `ADMIN_TOKEN`. Tener TOTP + recovery code en papel es la red de seguridad.

### 3. Cerrar el alta abierta

```bash
sed -i 's|^SIGNUPS_ALLOWED=true$|SIGNUPS_ALLOWED=false|' ~/homelab/productividad/.env

# Verificar
grep '^SIGNUPS_ALLOWED=' ~/homelab/productividad/.env
# SIGNUPS_ALLOWED=false

# Recargar el contenedor (no recreate; sólo recoge env)
docker compose -f ~/homelab/productividad/docker-compose.yml up -d vaultwarden
```

A partir de aquí, intentar `Create account` en el web vault devuelve "Registration not allowed". Para añadir más usuarios (familia), se hace desde el _admin panel_:

1. Acceder a `https://vaultwarden.lan/admin` desde la LAN o Tailscale (Caddy ya restringe el resto).
2. Introducir el **`admin_plain`** (NO el hash) que se anotó en papel al generar el `ADMIN_TOKEN`.
3. `Users → Invite User` → email del nuevo usuario. Si **SMTP no está configurado**, Vaultwarden mostrará el _link de invitación_ directamente en el panel; copiarlo y pasárselo al usuario por canal seguro (SMS, Signal). Si SMTP **está** configurado, Vaultwarden envía el email automáticamente.
4. El nuevo usuario abre el link, crea su master password, hace login. Repetir hasta cubrir a todos los miembros.

### 4. Deshabilitar el admin panel

Cuando ya están todos los usuarios creados y la configuración está estable:

```bash
sed -i 's|^DISABLE_ADMIN_TOKEN=false$|DISABLE_ADMIN_TOKEN=true|' ~/homelab/productividad/.env
docker compose -f ~/homelab/productividad/docker-compose.yml up -d vaultwarden
```

A partir de aquí, `https://vaultwarden.lan/admin` devuelve 404 directamente desde Vaultwarden (independiente del 403 que ya da Caddy fuera de las subnets permitidas). Si más adelante hay que volver a usarlo (cambiar SMTP, expulsar a un usuario), invertir el cambio, hacer la operación, y volver a deshabilitar.

> **No borrar el `ADMIN_TOKEN` del `.env`** aunque esté `DISABLE_ADMIN_TOKEN=true`. El hash sigue siendo necesario para que el panel funcione si en el futuro se reactiva. La nota en papel + la nota dentro de Vaultwarden con el `admin_plain` siguen siendo la única forma de recuperarlo.

### 5. Activar el _jail_ `vaultwarden` de fail2ban

`docs/04-seguridad/02-fail2ban.md` dejó preparado el _jail_ y el filtro, ambos versionados, ambos con `enabled = false`. Aquí se pasa a `enabled = true` y se recarga el `fail2ban` contenerizado:

```bash
# 1. Cambiar el flag en jail.local
sed -i '/^\[vaultwarden\]$/,/^\[/ s|^enabled  = false|enabled  = true|' \
    ~/homelab/seguridad/fail2ban/jail.local

# 2. Verificar
sed -n '/^\[vaultwarden\]$/,/^\[/p' ~/homelab/seguridad/fail2ban/jail.local
# [vaultwarden]
# enabled  = true
# port     = http,https
# filter   = vaultwarden
# logpath  = /var/log/vaultwarden/vaultwarden.log
# ...

# 3. Verificar que el bind-mount del log de Vaultwarden coincide con
#    el logpath del jail. El jail espera /var/log/vaultwarden/vaultwarden.log
#    DENTRO del contenedor de fail2ban, mapeado al log REAL del host.
#    Editar ~/homelab/seguridad/docker-compose.yml en el servicio fail2ban:
#    añadir el bind-mount si no estaba (ver docs/04-seguridad/02-fail2ban.md).
grep -A1 'fail2ban:' ~/homelab/seguridad/docker-compose.yml | grep volumes -A20
# Debe aparecer una línea:
#   - /mnt/hd2t/services/vaultwarden/data/vaultwarden.log:/var/log/vaultwarden/vaultwarden.log:ro
# Si NO aparece, añadirla a la lista 'volumes:' del servicio fail2ban
# y recrear el contenedor:
#   docker compose -f ~/homelab/seguridad/docker-compose.yml up -d fail2ban

# 4. Recargar fail2ban (no recreate; sólo reload)
docker exec fail2ban fail2ban-client reload vaultwarden
docker exec fail2ban fail2ban-client status vaultwarden
# Status for the jail: vaultwarden
# |- Filter
# |  |- Currently failed: 0
# |  |- Total failed:     0
# |  `- File list:        /var/log/vaultwarden/vaultwarden.log
# `- Actions
#    |- Currently banned: 0
#    |- Total banned:     0
#    `- Banned IP list:
```

> **Por qué un bind-mount del log y no el _socket_ de Docker**: el `fail2ban` contenerizado lee logs **del filesystem del host** (decisión arquitectural de `docs/04-seguridad/02-fail2ban.md`). Vaultwarden escribe su log a `/data/vaultwarden.log` dentro del contenedor, que es `/mnt/hd2t/services/vaultwarden/data/vaultwarden.log` en el host. El `fail2ban` lo monta `:ro` en `/var/log/vaultwarden/vaultwarden.log` (su _logpath_) para tener una vista coherente.

### 6. Activar el _hook_ de Borgmatic

`docs/07-backups/02-borgmatic.md` dejó preparado el bloque comentado del dump de Vaultwarden en el _hook_ `before_backup`. Descomentarlo:

```bash
# Localizar el script del hook
hook=~/homelab/backups/borgmatic/hooks/before_backup.sh
ls -la "$hook"

# Descomentar las líneas del bloque Vaultwarden (las que comienzan por
# '# Vaultwarden (SQLite, copia consistente con .backup)' hasta la próxima
# línea en blanco). Edición a mano con $EDITOR es preferible a un sed largo:
$EDITOR "$hook"

# Tras editar, validar la sintaxis bash:
bash -n "$hook" && echo OK
```

El bloque debe quedar **sin comentar** así (extraído de `docs/07-backups/02-borgmatic.md`):

```bash
# Vaultwarden (SQLite, copia consistente con .backup) — docs/11-productividad/01-vaultwarden.md
if docker ps --format '{{.Names}}' | grep -q '^vaultwarden$'; then
  docker exec vaultwarden sh -c '
    sqlite3 /data/db.sqlite3 ".backup /data/db.sqlite3.backup" &&
    gzip -c /data/db.sqlite3.backup
  ' > "$DUMPS/vaultwarden-${DATE}.sql.gz" && \
    chmod 0600 "$DUMPS/vaultwarden-${DATE}.sql.gz"
fi
```

> **Por qué `.backup` y no `cp` ni `sqlite3 .dump`**: `cp db.sqlite3` durante una escritura activa puede coger un fichero a medio _commit_ (el WAL aún no fusionado). `sqlite3 .dump` produce SQL textual válido pero gigante y costoso de re-importar (Borg deduplica peor sobre texto que sobre binario). `.backup` usa la _Online Backup API_ de SQLite: produce un fichero binario **consistente con el último _commit_**, sin bloquear a Vaultwarden, y dura ~50 ms en una BD de 50 MB.

> **`gzip -c` antes del redirect**: ahorra ~70 % de espacio en `$DUMPS/`. Borg deduplica gzipped binarios igual de bien que sin gzippear.

> **Probar el _hook_ ad hoc** sin esperar a las 03:30 AM:
> ```bash
> sudo BORG_PASSPHRASE_FILE=/etc/borgmatic.d/secrets.env \
>     bash ~/homelab/backups/borgmatic/hooks/before_backup.sh
> ls -la /mnt/hd2t/backups/dumps/ | grep vaultwarden
> # vaultwarden-2026-04-25.sql.gz   ~10 KB para una BD recién creada
> ```

### 7. Conectar los _clients_

Configurar cada _client_ oficial de Bitwarden apuntando a `https://vaultwarden.lan/`:

#### Extensión de navegador (Chrome / Firefox / Edge)

1. Instalar Bitwarden desde la _store_ del navegador.
2. Antes de hacer login, ir al icono de la extensión → **Settings (engranaje) → Self-hosted Environment**.
3. **Server URL**: `https://vaultwarden.lan` (deja vacíos los campos avanzados de Identity, API, Web Vault — Vaultwarden los sirve todos en el mismo origin).
4. Save → volver a la pantalla principal → login con email + master password + TOTP.

#### Cliente de escritorio (Windows / macOS / Linux)

Mismo procedimiento que la extensión: **Settings (icono ⚙️) → Self-hosted environment → Server URL = `https://vaultwarden.lan`**.

> **Cert de la CA local**: si el escritorio no tiene la CA importada, el cliente devuelve `Connection refused` o `SSL handshake failed`. Importar `caddy_root.crt` en el _trust store_ del sistema (`docs/03-red/04-caddy.md`, sección _Confianza en la CA local_). En Linux, copiar a `/usr/local/share/ca-certificates/` y `sudo update-ca-certificates`. **Reiniciar el cliente Bitwarden** después de importar.

#### Móvil (Android / iOS)

1. Instalar Bitwarden desde Play Store / App Store (o **Bitwarden** de F-Droid en Android — recomendado por privacidad).
2. Antes de login, en el icono de _Region_ → **Self-hosted** → Server URL = `https://vaultwarden.lan`.
3. **CA local**: el móvil necesita confiar en la CA local del homelab.
   - **Android**: importar `caddy_root.crt` desde Ajustes → Seguridad → Cifrado y credenciales → Instalar certificado de CA. Algunos Android (≥7) marcan "CA de usuario" como insuficiente para apps que pinean — el cliente Bitwarden _no_ pinea, así que funciona.
   - **iOS**: importar el `.crt` desde Ajustes → General → Perfiles. Después, **Ajustes → General → Acerca de → Ajustes de confianza de certificado** y activar la CA.
   - **Alternativa más cómoda**: conectar el móvil al **Tailscale** del operador y apuntar a `https://pi.<tailnet>.ts.net/`. Tailscale provee certs firmados por LetsEncrypt, confiados de fábrica en cualquier dispositivo. Ver `docs/03-red/05-tailscale.md`.
4. Login con email + master password + TOTP.

#### CLI (`bw`)

```bash
# Instalar bw
npm install -g @bitwarden/cli   # o: brew install bitwarden-cli

# Apuntar al server
bw config server https://vaultwarden.lan

# Login (devuelve un session token)
export BW_SESSION=$(bw login operador@homelab --raw)

# Listar entradas
bw list items | jq '.[].name'
```

> **Si `bw` falla con `Could not contact server`**: el sistema donde corre `bw` no confía en la CA local. Solución temporal: `NODE_TLS_REJECT_UNAUTHORIZED=0 bw login ...` (sólo para pruebas; nunca en scripts persistentes).

---

## Verificación final

Antes de pasar a `docs/11-productividad/02-bookstack.md`, comprobar:

- [ ] `docker compose -f ~/homelab/productividad/docker-compose.yml ps` muestra `vaultwarden` en `(healthy)`.
- [ ] `curl -k --resolve vaultwarden.lan:443:192.168.1.3 https://vaultwarden.lan/alive` devuelve un JSON con `"version":"1.32.7"` y un `"now"` actual.
- [ ] `https://vaultwarden.lan/` carga el _web vault_ en el navegador con candado verde (CA local importada).
- [ ] El usuario operador puede hacer login con su master password y su TOTP.
- [ ] `Settings → Security → Keys` muestra **Argon2id** como KDF activo en el usuario operador.
- [ ] `SIGNUPS_ALLOWED=false` en `.env` y, en el web vault, `Create account` devuelve "Registration not allowed".
- [ ] `DISABLE_ADMIN_TOKEN=true` en `.env` y `https://vaultwarden.lan/admin` devuelve **404** (Vaultwarden lo niega) cuando se accede desde una subnet permitida; **403** (Caddy lo niega) cuando se accede desde fuera de las subnets de la LAN/Tailscale.
- [ ] La extensión del navegador, el escritorio y el móvil están conectados, sincronizan al desbloquear y muestran al menos una entrada de prueba.
- [ ] Crear una entrada con un _attachment_ (PDF de prueba ≤ 5 MB), sincronizar a otro dispositivo, descargar el PDF, verificar que se descifra y abre.
- [ ] `docker exec fail2ban fail2ban-client status vaultwarden` muestra el _jail_ activo, `File list: /var/log/vaultwarden/vaultwarden.log`. Forzar un par de _logins_ fallidos desde un dispositivo de prueba y verificar que el contador `Currently failed` sube.
- [ ] El _hook_ de Borgmatic genera `dumps/vaultwarden-YYYY-MM-DD.sql.gz`. Verificar que el dump es válido:
  ```bash
  gunzip -c /mnt/hd2t/backups/dumps/vaultwarden-$(date +%F).sql.gz | \
      sqlite3 :memory: ".tables"
  # users  ciphers  attachments  sends  ...
  ```
- [ ] Tras un `docker compose -f ~/homelab/productividad/docker-compose.yml restart vaultwarden`, la página vuelve a `(healthy)` en <30 s y los _clients_ siguen sincronizando sin pedir nuevo login.
- [ ] Tras un `sudo reboot` de la Pi, el _stack_ vuelve a estar `(healthy)` sin intervención manual y `https://vaultwarden.lan/` responde.
- [ ] La master password, el `admin_plain` token y el _recovery code_ TOTP están **anotados en papel** y, una vez Vaultwarden está operativo, **dentro del propio Vaultwarden** como notas seguras.
- [ ] `git -C ~/homelab status` muestra como **modificados**: `red/Caddyfile`, `seguridad/fail2ban/jail.local`, `backups/borgmatic/hooks/before_backup.sh`. Y como **nuevos**: `productividad/docker-compose.yml`, `productividad/.env.example`, `productividad/.gitignore`. **No** muestra `productividad/.env` ni nada bajo `/mnt/hd2t/`. _Commit_:

  ```bash
  cd ~/homelab
  git add productividad/docker-compose.yml productividad/.env.example productividad/.gitignore \
          red/Caddyfile seguridad/fail2ban/jail.local backups/borgmatic/hooks/before_backup.sh
  git commit -m "feat(productividad): add Vaultwarden, activate fail2ban jail and borgmatic hook"
  ```

---

## Backup

| Qué                                     | Dónde                                                 | Cómo                                                       |
|-----------------------------------------|-------------------------------------------------------|------------------------------------------------------------|
| `docker-compose.yml`                    | `~/homelab/productividad/`                             | git                                                        |
| `db.sqlite3`                            | `/mnt/hd2t/services/vaultwarden/data/db.sqlite3`       | **Dump consistente** vía `sqlite3 .backup` en el _hook_ de Borgmatic; el fichero binario _raw_ se incluye también porque entra como _source dir_ en Borgmatic. |
| `attachments/`, `sends/`, `rsa_key.*`   | `/mnt/hd2t/services/vaultwarden/data/{attachments,sends,rsa_key.*}` | Borgmatic — copia raw, retención larga (mismas políticas que `nextcloud/data` del _set_ "data") |
| `icon_cache/`                           | `/mnt/hd2t/services/vaultwarden/data/icon_cache/`      | **Excluido** del backup (regenerable, ruido).               |
| `vaultwarden.log`                       | `/mnt/hd2t/services/vaultwarden/data/vaultwarden.log`  | **Excluido** del backup (transitorio; lo consume `fail2ban`). |
| `ADMIN_TOKEN` (hash + plain)            | Papel + nota dentro de Vaultwarden                    | Custodia humana. NUNCA en git, NUNCA en backups con la misma passphrase que el repo. |

> **Por qué dump SQL _y_ copia raw del directorio**: el dump (`.backup`) es el **canónico para restauración** (consistente con el último _commit_), pero la copia raw del directorio es lo que permite **restaurar en menos de 1 minuto** si la Pi se cae: `restic` o `borg extract` el directorio, levantar el contenedor, y la SQLite raw funciona el 99 % de las veces (sólo falla si la caída fue justo en pleno _checkpoint_, en cuyo caso se cae de vuelta al dump). Cinturón y tirantes.

> **Restauración desde backup**:
> 1. Restaurar `/mnt/hd2t/services/vaultwarden/data/` desde Borgmatic. Si el directorio raw está limpio, **listo**: `make up STACK=productividad` y la SQLite arranca.
> 2. Si la SQLite raw está corrupta (la app arranca pero `vaultwarden | Database is locked` o `disk image is malformed`):
>    ```bash
>    docker compose stop vaultwarden
>    cp /mnt/hd2t/backups/dumps/vaultwarden-YYYY-MM-DD.sql.gz /tmp/
>    gunzip /tmp/vaultwarden-YYYY-MM-DD.sql.gz
>    sudo mv /mnt/hd2t/services/vaultwarden/data/db.sqlite3 \
>            /mnt/hd2t/services/vaultwarden/data/db.sqlite3.broken
>    sudo cp /tmp/vaultwarden-YYYY-MM-DD.sql /mnt/hd2t/services/vaultwarden/data/db.sqlite3
>    docker compose up -d vaultwarden
>    ```
> 3. Si `rsa_key.*` se perdió: se regenera al arrancar; **todos los _clients_ activos se desconectan y deben hacer login de nuevo**, pero la bóveda (cifrada con la master password de cada usuario) sobrevive intacta.

> **Antes de cualquier upgrade de Vaultwarden** (1.32.7 → 1.33.x → 2.0):
> 1. `docker compose stop vaultwarden`.
> 2. Backup completo `data/` + dump SQL (Borgmatic _on-demand_).
> 3. Editar `.env`: `VAULTWARDEN_IMAGE_TAG=1.33.x-alpine` (leer el _changelog_).
> 4. `docker compose pull && docker compose up -d vaultwarden`.
> 5. `docker logs -f vaultwarden` — esperar a `Rocket has launched` y `(healthy)`.
> 6. `curl -k https://vaultwarden.lan/alive` — confirmar la versión nueva.
> 7. Verificación final completa de la sección anterior.
> 8. Si algo va mal: `docker compose down`, restaurar backup, `VAULTWARDEN_IMAGE_TAG=1.32.7-alpine`, `up -d`.

---

## Troubleshooting

### `vaultwarden` arranca y queda en `unhealthy`

El `start_period: 30s` da margen para la inicialización. Si tras 1 minuto sigue `starting`/`unhealthy`, mirar los logs:

```bash
docker logs vaultwarden --tail 80
```

Causas frecuentes:

1. **`ADMIN_TOKEN` malformado**: Vaultwarden ≥1.32 espera un hash Argon2id (prefijo `$argon2id$v=19$...`). Si el `.env` tiene texto plano, en logs aparece `WARNING: ADMIN_TOKEN is set in plaintext format. This is deprecated.` (sigue funcionando, pero idealmente regenerar con `vaultwarden hash`). Si tiene un hash malformado, `[ERROR] Invalid ADMIN_TOKEN format` y el contenedor reinicia. Solución: regenerar siguiendo la sección **Variables de entorno**.
2. **`DOMAIN` con `http://` o sin `https://`**: Vaultwarden valida el _origin_ de los _clients_ contra `DOMAIN`; si la URL del `.env` y la URL real del _reverse proxy_ no coinciden, _login_ funciona pero WebAuthn/passkeys no, y los clientes loggean `CSRF token error`. Solución: confirmar `VAULTWARDEN_DOMAIN=https://vaultwarden.lan` (con `https://` y sin trailing slash).
3. **Permisos de `/data`**: si `/mnt/hd2t/services/vaultwarden/data/` no es escribible por root del contenedor, el log muestra `Could not create file db.sqlite3: Permission denied`. Solución:
   ```bash
   sudo chown -R root:root /mnt/hd2t/services/vaultwarden/data
   sudo chmod 0750 /mnt/hd2t/services/vaultwarden/data
   docker compose -f ~/homelab/productividad/docker-compose.yml restart vaultwarden
   ```

### `Origin mismatch` o `CSRF` en los clientes

Los _clients_ comparan su `Server URL` con el campo `iss` (issuer) del JWT que devuelve `/identity/connect/token`, que se construye desde `DOMAIN`. Si no coincide, devuelve `400 Bad Request — Origin not allowed`. Causas:

- **Cliente apunta a `https://192.168.1.3/`** (IP) en lugar de a `https://vaultwarden.lan/` (FQDN). Vaultwarden firma `iss=https://vaultwarden.lan`, el cliente espera `iss=https://192.168.1.3`. Solución: usar siempre el FQDN.
- **Cliente apunta a `http://`** en una red donde Caddy fuerza HTTPS y redirige. El cliente no sigue el redirect y falla. Solución: `https://`.

### El log de Vaultwarden no aparece en `/data/vaultwarden.log`

`LOG_FILE=/data/vaultwarden.log` debe estar en el `.env` y propagado al contenedor:

```bash
docker exec vaultwarden env | grep LOG_FILE
# LOG_FILE=/data/vaultwarden.log
```

Si está, el fichero debería existir y crecer:

```bash
ls -la /mnt/hd2t/services/vaultwarden/data/vaultwarden.log
docker exec vaultwarden ls -la /data/vaultwarden.log
```

Si no crece después de un _login_ de prueba, la ruta dentro del contenedor puede haber sido reasignada. Confirmar:

```bash
docker exec vaultwarden cat /proc/1/cmdline | tr '\0' ' '; echo
# /vaultwarden
docker exec vaultwarden ls -la /proc/1/fd/ | grep -i log
# l-wx------ 1 root root 64 Apr 25 12:00 N -> /data/vaultwarden.log
```

### `fail2ban` no banea aunque hay _logins_ fallidos

```bash
docker exec fail2ban fail2ban-client status vaultwarden
```

Si `Currently failed: 0` tras varios fallos:

1. **Confirmar que el log llega al contenedor de fail2ban**:
   ```bash
   docker exec fail2ban tail -5 /var/log/vaultwarden/vaultwarden.log
   ```
   Si "No such file or directory": falta el bind-mount en `~/homelab/seguridad/docker-compose.yml`. Añadir y `up -d` el _stack_ `seguridad`.
2. **Confirmar que la cabecera `IP_HEADER` está en el log**: el log debe mostrar la IP **real** del cliente (`192.168.1.50`), no la del contenedor de Caddy (`172.20.10.x`):
   ```bash
   docker exec vaultwarden tail -5 /data/vaultwarden.log | grep -oE 'IP: [^.]+\.[^.]+\.[^.]+\.[^.]+'
   ```
   Si muestra `IP: 172.20.10.x`: falta `IP_HEADER=X-Real-IP` en el `.env` (o Caddy no envía `X-Real-IP`). Solución: confirmar la línea `header_up X-Real-IP {remote_host}` del bloque del `Caddyfile`.
3. **Probar el regex contra el log real**:
   ```bash
   docker exec fail2ban fail2ban-regex /var/log/vaultwarden/vaultwarden.log /etc/fail2ban/filter.d/vaultwarden.local
   # Lines: N matched: M
   ```
   Si `matched: 0` con líneas que claramente son fallos, el _filter_ regex no casa con el formato actual de Vaultwarden (puede haber cambiado en una _release_). Comparar con `docs/04-seguridad/02-fail2ban.md` y ajustar `~/homelab/seguridad/fail2ban/filter.d/vaultwarden.local`.

### El `/admin` panel devuelve `Unauthorized` con el token correcto

Causa típica: se está intentando entrar con el **hash** Argon2id en lugar del **plain** (`admin_plain`). El campo del panel pide la contraseña que se hashea automáticamente y se compara contra el hash del `.env`. Solución: introducir el `admin_plain` que se anotó en papel.

### Las llaves WebAuthn / passkeys no funcionan tras cambiar el dominio

WebAuthn ata las credenciales registradas a un _Relying Party ID_ que es el dominio del _origin_ del cliente. Si se cambia `DOMAIN` (`vaultwarden.lan` → `vault.miHogar.local`, por ejemplo), las llaves registradas con el dominio antiguo dejan de validar. Solución: **no** cambiar `DOMAIN` después del setup. Si hay que hacerlo, los usuarios deben re-registrar sus llaves desde 0 desde `Settings → Security → Two-step Login → FIDO2 WebAuthn`.

### `Database is locked` en logs durante un sync masivo

SQLite tiene un único escritor concurrente; si dos procesos escriben a la vez (cliente desktop + cliente móvil + extensión + cron interno) puede aparecer un `SQLITE_BUSY` esporádico. El propio Vaultwarden reintenta. Si el error es **constante**:

```bash
# Modo WAL (Write-Ahead Logging) reduce la contención. Vaultwarden lo
# activa por defecto desde 1.20, pero si la SQLite viene de una migración
# antigua puede estar en modo 'rollback journal'. Verificar:
docker exec vaultwarden sqlite3 /data/db.sqlite3 'PRAGMA journal_mode;'
# wal
# (si no es 'wal':)
docker exec vaultwarden sqlite3 /data/db.sqlite3 'PRAGMA journal_mode=WAL;'
```

### Recuperar acceso si se pierde la master password (catastrófico)

**No es recuperable**. La master password deriva la _stretched key_ que descifra la bóveda; sin ella, el cifrado AES-256 de la bóveda es indescifrable, ni siquiera con acceso completo al servidor. Esto es **por diseño** (el modelo E2EE de Bitwarden).

Soluciones disponibles **antes** de perderla:

1. **Recovery code TOTP**: si la pérdida es del segundo factor (TOTP), no de la master password, el recovery code que se descargó en el setup permite re-entrar y reconfigurar el 2FA.
2. **Emergency Access**: si está activado (`EMERGENCY_ACCESS_ALLOWED=true` y SMTP configurado), un contacto designado puede solicitar acceso a la bóveda; tras un timeout configurable (días), el servidor le da una copia de la _encrypted vault_ y la _stretched key_ del contacto descifra. Útil si el operador fallece o queda incapacitado.

Si ya se perdió y nada de lo anterior estaba activo: **borrar al usuario desde el _admin panel_** (reactivando temporalmente `DISABLE_ADMIN_TOKEN=false`), crear cuenta nueva, importar las contraseñas desde la copia en papel / desde el navegador. **Toda la bóveda anterior se pierde**.

---

## SMTP opcional

Vaultwarden funciona sin SMTP, pero algunas funcionalidades quedan limitadas:

- **Invitar a un usuario nuevo**: sin SMTP, el _admin panel_ muestra el _link de invitación_ en la propia UI; sin SMTP, no se puede automatizar el envío.
- **Avisos de _login_ desde dispositivo nuevo**, **cambio de master password**, **Emergency Access**, **avisos de _hibp_** (Have I Been Pwned), **Sends con email del receptor**: todos requieren SMTP.

Para activar, añadir al `.env`:

```bash
SMTP_HOST=smtp.tu-proveedor.com
SMTP_FROM=vaultwarden@tu-dominio.example
SMTP_PORT=587
SMTP_SECURITY=starttls
SMTP_USERNAME=tu-cuenta-smtp
SMTP_PASSWORD=tu-password-de-aplicacion
```

…y descomentar el bloque correspondiente del `docker-compose.yml`. Reiniciar:

```bash
docker compose -f ~/homelab/productividad/docker-compose.yml up -d vaultwarden
```

Probar desde el _admin panel_ → `SMTP → Send test email`.

> **Por qué `STARTTLS` y no `tls`**: la mayoría de proveedores (Gmail, Outlook, Mailgun, ProtonMail Bridge, Postmark) ofrecen STARTTLS en `:587`. `tls` directo sólo en `:465`, soportado pero menos común. Si el proveedor exige `:465`, cambiar `SMTP_PORT=465` y `SMTP_SECURITY=tls`.

> **App passwords de Gmail / iCloud**: ambos requieren generar una "app password" específica para Vaultwarden (las credenciales normales de la cuenta no funcionan con SMTP desde 2022). Crear desde el portal del proveedor.

---

## Migrar a OIDC con Authelia (opcional, futuro)

Vaultwarden **soporta SSO vía OIDC desde 1.32** (con la flag de _build_ `enable_sso`, que la imagen oficial _no_ trae por defecto). La imagen `dani-garcia/vaultwarden:sso-experimental` tiene el SSO compilado. **No** se aplica en este documento porque:

- El SSO de Vaultwarden está en estado **experimental** y rompe regularmente la compatibilidad con _clients_ móviles (los que usan la API legacy de Bitwarden no soportan el flujo de _device authorization_).
- La master password seguiría siendo necesaria para descifrar la bóveda **incluso con SSO**: SSO sólo sustituye al _login_ inicial (email + password), no al cifrado E2EE.
- El operador único del homelab no gana lo suficiente del SSO como para justificar la inestabilidad.

Si en el futuro la imagen oficial estabiliza el SSO y se quiere unificar el _login_ con Authelia: la migración consistirá en cambiar el _tag_ a la imagen con SSO, registrar un cliente OIDC en Authelia (`docs/04-seguridad/01-authelia.md`), añadir las env vars `SSO_*` al `.env` y reiniciar. **No** se hace ahora.

---

## Referencias

- Documentación oficial de Vaultwarden: <https://github.com/dani-garcia/vaultwarden/wiki>
  - Variables de entorno: <https://github.com/dani-garcia/vaultwarden/wiki/Configuration-overview>
  - Reverse proxy (Caddy): <https://github.com/dani-garcia/vaultwarden/wiki/Proxy-examples#caddy-2x>
  - Admin panel y `ADMIN_TOKEN` Argon2: <https://github.com/dani-garcia/vaultwarden/wiki/Enabling-admin-page>
  - SMTP: <https://github.com/dani-garcia/vaultwarden/wiki/SMTP-Configuration>
  - WebSockets en 1.29+: <https://github.com/dani-garcia/vaultwarden/wiki/Enabling-WebSocket-notifications>
- Imagen Docker: <https://hub.docker.com/r/vaultwarden/server>
- Bitwarden _clients_ oficiales (compatibles con Vaultwarden): <https://bitwarden.com/download/>
- Bitwarden CLI (`bw`): <https://bitwarden.com/help/cli/>
- Documentación de Argon2id como KDF de Bitwarden: <https://bitwarden.com/help/kdf-algorithms/>
- Filter de fail2ban (preparado en `docs/04-seguridad/02-fail2ban.md`): <https://github.com/dani-garcia/vaultwarden/wiki/Fail2Ban-Setup>
- Backup de SQLite con `.backup` (Online Backup API): <https://www.sqlite.org/backup.html>
