# Fail2ban — jails de servicios

## Descripción

En `01-sistema/03-seguridad-base.md` se desplegó `fail2ban` con **una sola jail**: `[sshd]`, leída del journal por `backend = systemd`, baneando IPs con `nftables` en el set `f2b-sshd`. La política `[DEFAULT]` (whitelist `127.0.0.1/8 ::1 192.168.1.0/24 100.64.0.0/10`, `findtime 10m`, `maxretry 5`, `bantime 1h` con `bantime.increment`) ya se justificó allí y se reutiliza tal cual aquí: este documento **no** la duplica ni la sobreescribe.

Cerrada la Fase 3 (Caddy + Pi-hole + Tailscale) y desplegado Authelia (`01-authelia.md`), el homelab tiene tres puntos de entrada con autenticación que **no** son SSH:

1. **Authelia**, recibiendo cada `forward_auth` desde Caddy y respondiendo el portal `auth.${DOMAIN_LAN}`. Es el embudo del SSO: cualquier intento de fuerza bruta contra Pi-hole, Portainer, Vaultwarden, Nextcloud, Paperless o el propio portal **pasa por aquí** y deja rastro en `authelia.log`.
2. **Vaultwarden** (Fase 11), expuesto bajo `vaultwarden.${DOMAIN_LAN}` con TOTP de Authelia delante. Aun con SSO, los clientes nativos de Bitwarden (móvil, navegador) **no atraviesan Authelia**: hablan directo con el endpoint `/identity/connect/token` de Vaultwarden vía Caddy. Esos intentos requieren su **propia jail** porque Authelia no los ve.
3. **Nextcloud** (Fase 6), accesible vía web detrás de Authelia y vía clientes WebDAV/sync que **tampoco** entienden la cookie del SSO (el cliente de escritorio se autentica con app password directo contra Nextcloud). Idéntico razonamiento: jail propia.

A esto se suman **dos refuerzos** sobre piezas ya existentes:

- **Authelia**: aunque Authelia tiene su propia `regulation` interna (3 fallos / 2 min → ban 5 min, definida en `01-authelia.md`), esos baneos viven dentro del proceso Authelia y **no cierran la conexión TCP**. Una IP regulada sigue pudiendo abrir socket, llegar a Caddy, hacer `forward_auth` y comer ciclos. Una jail `fail2ban` baneando con `nftables` el puerto 443 entero **frena el tráfico antes** de tocar Caddy.
- **Caddy / portal Authelia**: una jail "anti-bot" que vigile rutas de inicio de sesión sondeadas masivamente (`/api/firstfactor` con 10 IPs distintas en 1 min) **no se añade hoy**. El doble candado `regulation` de Authelia + jail-Authelia de fail2ban cubre el caso real; meter una tercera capa basada en patrones del access log de Caddy es ruido sin valor mientras el homelab esté solo en LAN+Tailscale. Documentado como "decisión que no se toma".

> **Recordatorio de alcance**: el homelab no expone puertos a Internet. El **único atacante plausible** en la LAN es un dispositivo doméstico comprometido (un IoT con firmware malicioso, un portátil del trabajo con malware). Las jails que se añaden aquí no defienden contra "Internet" — defienden contra **ese vector interno** y contra escaneos de bots en la propia LAN. Por eso las whitelists definidas en `03-seguridad-base.md` (`192.168.1.0/24 100.64.0.0/10`) **se ajustan en este documento**: a diferencia de SSH (donde un fallo "interno" es tolerable), un fallo masivo de login contra Vaultwarden **sí** debe banear aunque venga de la LAN. La whitelist se relaja a `127.0.0.1/8 ::1` solamente para las jails de servicios.

Lo que este documento **no** decide:

- **Filtros para Pi-hole**: Pi-hole tiene rate-limiting propio en su API admin y, ya con Authelia (`policy: one_factor`) delante, todo intento llega a la cookie del SSO antes que al login interno de Pi-hole. La jail-Authelia cubre el camino completo.
- **Filtros para Caddy**: Caddy emite logs JSON de acceso opcionalmente; no se activan en `04-caddy.md` (decisión: solo `errors`). Tener jail aquí supondría activar access logs por todos los servicios y añadir ~20 MB/día de logs operativos por una superficie que ya está cubierta. Se documenta como reabrible.
- **Filtros para Jellyfin / Stash**: ambos en `bypass` de Authelia, con su propia auth. Jellyfin **sí** tiene logs estructurados con el IP del cliente (`Authentication request for "X" has been denied`); preparar la jail aquí sería razonable, pero el riesgo real (clientes locales con PIN guardado) es bajo. Se documenta como reabrible cuando esos servicios se desplieguen.
- **Notificación al operador cuando dispare un ban**: hoy, los bans quedan en el journal de `fail2ban` y en `fail2ban-client status <jail>`. La integración con Prometheus/Alertmanager (Fase 5) o con notifications externas (Fase 11) cierra ese hueco; aquí solo se prepara el log para que sea consumible.

Cuando este documento se haya aplicado, `fail2ban-client status` lista cinco jails (`sshd` + cuatro nuevas), cada filtro tiene su `failregex` versionada en `/etc/fail2ban/filter.d/*.local`, los logs de Authelia/Vaultwarden/Nextcloud son leídos directamente del bind-mount en `hd2t`, y un intento de fuerza bruta contra cualquiera de los tres servicios resulta en una entrada `f2b-<svc>` en `nftables` con la IP atacante baneada.

---

## Requisitos Previos

- `fail2ban` instalado y funcional con la jail SSH activa (`01-sistema/03-seguridad-base.md`). Si `sudo fail2ban-client status` no muestra `Jail list: sshd`, parar y completar primero esa fase.
- Authelia desplegado (`01-authelia.md`) con `format: text` en `log:` y `file_path: /var/log/authelia/authelia.log` montado vía bind a `/mnt/hd2t/apps/authelia/logs/authelia.log`. Si el log está en JSON, las `failregex` de este documento **no matchean**.
- Caddy reenviando los headers `X-Real-IP` y `X-Forwarded-For` hacia Authelia (ya configurado en `01-authelia.md`, sección "Drop-in de Caddy"). Sin esos headers, Authelia logea siempre `remote_ip="172.30.10.1"` (la gateway Docker) y la jail banearía a Docker, no al atacante. Verificar:
  ```bash
  grep -E 'forward_auth|X-Real-IP|X-Forwarded-For' /mnt/hd2t/apps/caddy/etc/conf.d/01-authelia.caddy
  # Debe listar X-Real-IP y X-Forwarded-For en los `header_up`.
  ```
- Backend `nftables` en uso (`sudo nft list ruleset | head` debe mostrar tablas `inet filter` con chains `f2b-*`). Si por algún motivo se cambió a `iptables`, las jails de este documento siguen funcionando, pero el set `f2b-<jail>` aparece en otra tabla; ajustar las verificaciones.
- Vaultwarden y Nextcloud **no son requisito**: las jails se preparan con `enabled = false` y se activan cuando llegue la fase correspondiente (Fase 6 Nextcloud, Fase 11 Vaultwarden). Este documento deja **el patrón listo**; activarlo es una línea cuando el servicio exista.
- Comprobaciones:
  ```bash
  # fail2ban operativo
  sudo systemctl is-active fail2ban
  # active

  # Jail SSH viva (no se va a tocar)
  sudo fail2ban-client status sshd | grep -E 'Currently failed|Currently banned'

  # Log de Authelia accesible desde el host (lo lee fail2ban directamente)
  sudo test -r /mnt/hd2t/apps/authelia/logs/authelia.log && echo ok
  # ok

  # IP del cliente real aparece en el log de Authelia tras un login fallido
  # (provocar un fallo en https://auth.lan/ con cualquier contraseña incorrecta)
  sudo grep -E 'remote_ip=' /mnt/hd2t/apps/authelia/logs/authelia.log | tail -3
  # ... remote_ip="192.168.1.20" ...   <-- debe ser un IP de cliente real, no 172.30.10.1
  ```
  Si el `remote_ip` es la gateway de la red Docker, parar y revisar el `forward_auth` de Caddy: las jails serán inútiles hasta que Authelia vea el IP correcto.

---

## Decisión: cómo se accede a los logs de los contenedores

Hay tres formas habituales de que `fail2ban` (que corre en el **host**, no en un contenedor) lea los logs de un servicio que vive **dentro** de Docker:

| Fuente | Cómo se lee desde el host | Pros | Contras | Decisión |
|---|---|---|---|---|
| **Bind mount del fichero de log** a `/mnt/hd2t/apps/<svc>/logs/<svc>.log` | Lectura directa con `logpath = /mnt/hd2t/apps/.../<svc>.log` | Sin sidecar, sin parsing intermedio, *backend polling* nativo de fail2ban; persiste tras reinicios del contenedor; el operador lee con `tail -f` igual que el resto de logs del homelab. | Cada servicio debe configurar su logger para escribir a fichero (no solo a stdout). | **Aceptado**. |
| **Driver `journald`** en el `docker-compose.yml` (`logging.driver: journald`) y `backend = systemd` en la jail | `fail2ban` filtra por `_SYSTEMD_UNIT=docker.service` + `CONTAINER_NAME=authelia` | No requiere bind mount del log; un único log centralizado. | Mezcla logs de todos los contenedores en el journal del host; el regex tiene que filtrar por `CONTAINER_NAME`; rota con la política del journal del host (no la del contenedor); algunas imágenes (Vaultwarden, Nextcloud) loguean a fichero por defecto y vuelcan poco a stdout. | Descartado: el journal del host es para logs de **systemd**; mezclar logs de aplicación contamina el debugging. |
| **Sidecar `socat`/`promtail`** que emite los logs a un socket o exporta a Loki | `fail2ban` consume del socket | Útil si ya hay Loki desplegado. | Sobreingeniería para esta fase; añade un sidecar por servicio. | Descartado. |

Resultado: cada servicio del homelab que tenga jail propia escribe su log de aplicación a un fichero **bajo `/mnt/hd2t/apps/<svc>/logs/`** mediante bind mount. `fail2ban` lo lee con `backend = polling` (default) sin más intermediarios. El log de SSH, que sí es del host, sigue leyéndose del journal por `backend = systemd` (configurado a nivel `[DEFAULT]` en `03-seguridad-base.md`); cada jail nueva sobreescribe `backend` localmente.

> **Nota sobre permisos**: `fail2ban` corre como `root` en el host, lo que le permite leer cualquier fichero. No se cambian permisos de los logs por esta razón.

---

## Decisión: scope de las jails y whitelist relajada

| Jail | Vigila | `enabled` por defecto | `bantime` |
|---|---|---|---|
| `[sshd]` (existente, no se toca) | `ssh` del host | `true` | 1 h con incremento → 24 h |
| `[authelia]` | `auth.${DOMAIN_LAN}` y todo `forward_auth` | `true` | 1 h con incremento → 24 h |
| `[vaultwarden]` | login web + clientes nativos a `vaultwarden.${DOMAIN_LAN}` | `false` (activar en Fase 11) | 1 h con incremento → 24 h |
| `[vaultwarden-admin]` | acceso a `/admin` con token incorrecto | `false` (activar en Fase 11) | 24 h fijo (este vector es ruidoso por diseño) |
| `[nextcloud]` | login web + WebDAV de Nextcloud | `false` (activar en Fase 6) | 1 h con incremento → 24 h |

Sobre **whitelist**:

`03-seguridad-base.md` definió `ignoreip = 127.0.0.1/8 ::1 192.168.1.0/24 100.64.0.0/10` a nivel `[DEFAULT]`. Con esa whitelist, **una jail de Vaultwarden no banearía nunca a un dispositivo de la LAN o del tailnet** — exactamente el vector que se quiere proteger en este documento. Cada jail nueva sobreescribe `ignoreip` con la versión mínima:

```
ignoreip = 127.0.0.1/8 ::1
```

De este modo:

- Un dispositivo doméstico comprometido que pruebe contraseñas contra Vaultwarden **sí** se banea.
- El propio operador, equivocándose tres veces de contraseña en su iPhone, **se banea durante 1 hora** (con `bantime.increment` activo, dos errores en una semana → 2 h, etc.). Es fricción aceptable: el TOTP del SSO es de 6 dígitos y el operador conoce sus contraseñas. Si llega a pasar, `sudo fail2ban-client unban <ip>` resuelve el caso.
- Tailscale (CGNAT `100.64.0.0/10`) tampoco va whitelisted en estas jails: si un dispositivo del tailnet se compromete, debe tratarse como cualquier otro atacante.

La jail `[sshd]` mantiene la whitelist amplia: la lógica de "si te equivocas de contraseña SSH desde tu portátil de trabajo, no quiero que te quedes bloqueado fuera del homelab" sigue vigente. SSH es la puerta de servicio del operador; los servicios web no.

---

## Layout en disco

| Ruta | Soporte | Contenido |
|---|---|---|
| `stacks/_host/fail2ban/jail.d/10-authelia.local` | microSD (git) | Jail `[authelia]`. |
| `stacks/_host/fail2ban/jail.d/20-vaultwarden.local` | microSD (git) | Jails `[vaultwarden]` y `[vaultwarden-admin]`, ambas `enabled = false`. |
| `stacks/_host/fail2ban/jail.d/30-nextcloud.local` | microSD (git) | Jail `[nextcloud]`, `enabled = false`. |
| `stacks/_host/fail2ban/filter.d/authelia.local` | microSD (git) | `failregex` para Authelia 4.38 (`format: text`). |
| `stacks/_host/fail2ban/filter.d/vaultwarden.local` | microSD (git) | `failregex` para Vaultwarden (login fallido). |
| `stacks/_host/fail2ban/filter.d/vaultwarden-admin.local` | microSD (git) | `failregex` para Vaultwarden (`/admin` con token inválido). |
| `stacks/_host/fail2ban/filter.d/nextcloud.local` | microSD (git) | `failregex` para Nextcloud (logs JSON). |
| `/etc/fail2ban/jail.d/10-authelia.local` | host | Versión materializada (copia desde el repo). |
| `/etc/fail2ban/jail.d/20-vaultwarden.local` | host | Idem. |
| `/etc/fail2ban/jail.d/30-nextcloud.local` | host | Idem. |
| `/etc/fail2ban/filter.d/{authelia,vaultwarden,vaultwarden-admin,nextcloud}.local` | host | Idem. |
| `/var/lib/fail2ban/fail2ban.sqlite3` | host | Estado de bans (compartido con la jail de SSH; **no** se respalda, ya documentado en `03-seguridad-base.md`). |
| `/mnt/hd2t/apps/authelia/logs/authelia.log` | hd2t (bind mount) | Producido por Authelia, consumido por la jail. |
| `/mnt/hd2t/apps/vaultwarden/data/vaultwarden.log` | hd2t (bind mount, futuro) | Producido por Vaultwarden cuando se despliegue. |
| `/mnt/hd2t/apps/nextcloud/app/data/nextcloud.log` | hd2t (bind mount, futuro) | Producido por Nextcloud cuando se despliegue. |

> **Sobre `stacks/_host/`**: por convención de Fase 2, los stacks Docker viven en `stacks/<svc>/`. Para configuración del **host** (no Docker) se usa `stacks/_host/<componente>/`. Es coherente con el layout existente y mantiene todo bajo el mismo árbol versionable.

---

## Configuración de los filtros

### `stacks/_host/fail2ban/filter.d/authelia.local`

Authelia 4.38 con `log.format: text` produce líneas estilo:

```
time="2025-04-28T10:00:00+02:00" level=error msg="Unsuccessful 1FA authentication attempt by user 'homelab'" method=POST path=/api/firstfactor remote_ip="192.168.1.42" stack=...
```

El filtro captura los cuatro flujos de autenticación que Authelia distingue en su logger (`1FA`, `TOTP`, `WebAuthn`, `Duo`):

```ini
# /etc/fail2ban/filter.d/authelia.local
# Authelia 4.38+ con log.format: text — documentado en docs/04-seguridad/02-fail2ban.md
#
# Captura intentos fallidos contra:
#   - Primer factor (contraseña)
#   - Segundo factor TOTP
#   - Segundo factor WebAuthn (preparado para futuro)
#   - Segundo factor Duo (no usado en el homelab; se incluye por simetría)

[INCLUDES]
before = common.conf

[Definition]

failregex = ^.*level=error msg="Unsuccessful 1FA authentication attempt by user [^"]+" method=\S+ path=\S+ remote_ip="<HOST>".*$
            ^.*level=error msg="Unsuccessful TOTP authentication attempt by user [^"]+" method=\S+ path=\S+ remote_ip="<HOST>".*$
            ^.*level=error msg="Unsuccessful Webauthn authentication attempt by user [^"]+" method=\S+ path=\S+ remote_ip="<HOST>".*$
            ^.*level=error msg="Unsuccessful Duo authentication attempt by user [^"]+" method=\S+ path=\S+ remote_ip="<HOST>".*$

ignoreregex =

# Authelia escribe RFC3339 con offset; fail2ban detecta el formato auto, pero
# fijarlo evita ambigüedades si el contenedor cambia de TZ.
datepattern = {^LN-BEG}time="?%%Y-%%m-%%dT%%H:%%M:%%S(\.%%f)?(Z|%%z)
```

### `stacks/_host/fail2ban/filter.d/vaultwarden.local`

Vaultwarden imprime intentos fallidos con un patrón estable desde la versión 1.30+:

```
[2025-04-28 10:00:00.000][error][error] Username or password is incorrect. Try again. IP: 192.168.1.42. Username: admin@example.com.
```

```ini
# /etc/fail2ban/filter.d/vaultwarden.local
# Vaultwarden — login fallido normal. Documentado en docs/04-seguridad/02-fail2ban.md.
#
# Vaultwarden ofuscará el username si LOG_LEVEL=warn; mantener LOG_LEVEL=info
# (default) para que aparezca, no es un secreto y ayuda al diagnóstico.

[INCLUDES]
before = common.conf

[Definition]

failregex = ^.*?LOGIN\([^)]*\) Username or password is incorrect\. Try again\. IP: <ADDR>\. Username: .*$
            ^.*?Username or password is incorrect\. Try again\. IP: <ADDR>\. Username: .*$

ignoreregex =

datepattern = {^LN-BEG}\[%%Y-%%m-%%d %%H:%%M:%%S
```

### `stacks/_host/fail2ban/filter.d/vaultwarden-admin.local`

El panel de admin de Vaultwarden (`/admin`) acepta un token único; cada intento fallido produce:

```
[2025-04-28 10:00:00.000][error][error] Invalid admin token. IP: 192.168.1.42.
```

```ini
# /etc/fail2ban/filter.d/vaultwarden-admin.local
# Vaultwarden — token de admin incorrecto. Más estricto que el login normal:
# este endpoint NO se usa en operación cotidiana; cualquier fallo aquí es
# sospechoso. Documentado en docs/04-seguridad/02-fail2ban.md.

[INCLUDES]
before = common.conf

[Definition]

failregex = ^.*?Invalid admin token\. IP: <ADDR>.*$

ignoreregex =

datepattern = {^LN-BEG}\[%%Y-%%m-%%d %%H:%%M:%%S
```

### `stacks/_host/fail2ban/filter.d/nextcloud.local`

Nextcloud loguea en JSON una línea por evento. El filtro captura "login fallido" y "trusted domain error" (este último indica un escaneo HTTP con `Host:` arbitrario, típico de bots):

```json
{"reqId":"...","level":2,"time":"2025-04-28T10:00:00+02:00","remoteAddr":"192.168.1.42","user":"--","app":"core","method":"POST","url":"/login","message":"Login failed: 'admin' (Remote IP: '192.168.1.42')"}
```

```ini
# /etc/fail2ban/filter.d/nextcloud.local
# Nextcloud — logs JSON. Documentado en docs/04-seguridad/02-fail2ban.md.

[INCLUDES]
before = common.conf

[Definition]

failregex = ^\{.*"remoteAddr":"<HOST>".*"message":"Login failed:.*\}$
            ^\{.*"remoteAddr":"<HOST>".*"message":"Trusted domain error.*\}$

ignoreregex =

datepattern = ,?\s*"time"\s*:\s*"%%Y-%%m-%%dT%%H:%%M:%%S(?:\.%%f)?(?:Z|%%z)?"
```

> **Nota sobre `<HOST>` vs `<ADDR>`**: en fail2ban, `<HOST>` matchea IPv4, IPv6 y nombres DNS (con resolución posterior); `<ADDR>` solo IPs literales. Vaultwarden imprime IPs literales (no DNS), así que `<ADDR>` es más estricto y correcto. Authelia y Nextcloud pueden recibir un IP encabezado por `X-Forwarded-For`; usar `<HOST>` por simetría con la jail oficial publicada por ambos proyectos.

---

## Configuración de las jails

### `stacks/_host/fail2ban/jail.d/10-authelia.local`

```ini
# /etc/fail2ban/jail.d/10-authelia.local
# Documentado en docs/04-seguridad/02-fail2ban.md.

[authelia]
enabled  = true

# Sobreescribe el ignoreip global: aquí SÍ se banea a la LAN/tailnet.
ignoreip = 127.0.0.1/8 ::1

# Sobreescribe backend a polling: el log es un fichero, no el journal.
backend  = polling

# Lee directamente el bind-mount del contenedor.
logpath  = /mnt/hd2t/apps/authelia/logs/authelia.log

filter   = authelia

# 5 fallos en 10 min disparan ban. Authelia regula a los 3 fallos en 2 min
# internamente; al 5º (= 2 ciclos de regulation) escalamos a fail2ban
# para cerrar la conexión TCP completa.
findtime = 10m
maxretry = 5

bantime           = 1h
bantime.increment = true
bantime.factor    = 2
bantime.maxtime   = 1d

# Banear todos los puertos (ya no solo 443): si la IP es maliciosa, también
# se le cierra el SSH "por si acaso". `nftables[type=allports]` ya está
# definido como `banaction_allports` global en `03-seguridad-base.md`.
banaction = %(banaction_allports)s
```

### `stacks/_host/fail2ban/jail.d/20-vaultwarden.local`

```ini
# /etc/fail2ban/jail.d/20-vaultwarden.local
# Documentado en docs/04-seguridad/02-fail2ban.md.
# Activar (`enabled = true`) cuando Vaultwarden se despliegue (Fase 11).

[vaultwarden]
enabled  = false

ignoreip = 127.0.0.1/8 ::1
backend  = polling
logpath  = /mnt/hd2t/apps/vaultwarden/data/vaultwarden.log
filter   = vaultwarden

findtime = 10m
maxretry = 5

bantime           = 1h
bantime.increment = true
bantime.factor    = 2
bantime.maxtime   = 1d

banaction = %(banaction_allports)s

[vaultwarden-admin]
enabled  = false

ignoreip = 127.0.0.1/8 ::1
backend  = polling
logpath  = /mnt/hd2t/apps/vaultwarden/data/vaultwarden.log
filter   = vaultwarden-admin

# Más estricto: este endpoint no se usa en operación normal.
findtime = 1d
maxretry = 3

# Ban fijo de 24 h sin incremento: cualquier intento contra /admin es
# de suficiente gravedad como para no requerir progresión.
bantime  = 1d

banaction = %(banaction_allports)s
```

### `stacks/_host/fail2ban/jail.d/30-nextcloud.local`

```ini
# /etc/fail2ban/jail.d/30-nextcloud.local
# Documentado en docs/04-seguridad/02-fail2ban.md.
# Activar (`enabled = true`) cuando Nextcloud se despliegue (Fase 6).

[nextcloud]
enabled  = false

ignoreip = 127.0.0.1/8 ::1
backend  = polling

# Ruta dentro del bind mount de Nextcloud. La fase 6 confirmará el path
# exacto; Nextcloud (imagen oficial) escribe en /var/www/html/data/nextcloud.log
# que en el homelab se monta como /mnt/hd2t/apps/nextcloud/app/data/.
logpath  = /mnt/hd2t/apps/nextcloud/app/data/nextcloud.log

filter   = nextcloud

findtime = 10m
maxretry = 5

bantime           = 1h
bantime.increment = true
bantime.factor    = 2
bantime.maxtime   = 1d

banaction = %(banaction_allports)s
```

### Materializar y recargar

```bash
# Repo del homelab
cd /home/homelab/homelab

# Crear el árbol de configuración del host (versionado en git)
sudo install -d -o homelab -g homelab -m 0755 stacks/_host/fail2ban/jail.d
sudo install -d -o homelab -g homelab -m 0755 stacks/_host/fail2ban/filter.d

# Materializar filtros y jails al sistema
sudo install -m 0644 -o root -g root \
    stacks/_host/fail2ban/filter.d/authelia.local \
    /etc/fail2ban/filter.d/authelia.local
sudo install -m 0644 -o root -g root \
    stacks/_host/fail2ban/filter.d/vaultwarden.local \
    /etc/fail2ban/filter.d/vaultwarden.local
sudo install -m 0644 -o root -g root \
    stacks/_host/fail2ban/filter.d/vaultwarden-admin.local \
    /etc/fail2ban/filter.d/vaultwarden-admin.local
sudo install -m 0644 -o root -g root \
    stacks/_host/fail2ban/filter.d/nextcloud.local \
    /etc/fail2ban/filter.d/nextcloud.local

sudo install -m 0644 -o root -g root \
    stacks/_host/fail2ban/jail.d/10-authelia.local \
    /etc/fail2ban/jail.d/10-authelia.local
sudo install -m 0644 -o root -g root \
    stacks/_host/fail2ban/jail.d/20-vaultwarden.local \
    /etc/fail2ban/jail.d/20-vaultwarden.local
sudo install -m 0644 -o root -g root \
    stacks/_host/fail2ban/jail.d/30-nextcloud.local \
    /etc/fail2ban/jail.d/30-nextcloud.local

# Validar la sintaxis ANTES de recargar (un error en filter.d/ tira fail2ban
# entero y cierra la jail SSH; no se quiere descubrir esto tras `restart`).
sudo fail2ban-client -t

# Recargar fail2ban para tomar las nuevas jails sin tirar el servicio
sudo fail2ban-client reload

# Verificar que las jails están listadas (las disabled no aparecen)
sudo fail2ban-client status
# |- Number of jail:      2
# `- Jail list:    authelia, sshd
```

> **Sobre `fail2ban-client -t`**: el flag `-t` pide al cliente cargar la configuración como lo haría el daemon, sin aplicarla. Captura el 95 % de errores tipográficos (`failregex` mal cerrada, `logpath` inexistente, jail con sintaxis rota). Es el equivalente a `caddy validate` y debe ejecutarse antes de cada `reload`.

---

## Configuración

### 1) Probar la jail de Authelia con un fallo controlado

Desde un cliente de la LAN con la CA interna instalada:

```text
1. Abrir https://auth.lan/ en navegador privado.
2. Login con `homelab` y una contraseña incorrecta — repetir 5 veces.
3. Al sexto intento, Authelia responde "user is banned" (su regulation interna).
   Continuar provocando fallos: a la 5ª línea de error en authelia.log,
   fail2ban dispara el ban.
```

Desde la Pi:

```bash
# Ver los fallos contabilizados
sudo fail2ban-client status authelia
# Status for the jail: authelia
# |- Filter
# |  |- Currently failed: 5
# |  |- Total failed:     5
# |  `- File list:        /mnt/hd2t/apps/authelia/logs/authelia.log
# `- Actions
#    |- Currently banned: 1
#    |- Total banned:     1
#    `- Banned IP list:   192.168.1.42

# Confirmar que el set de nftables tiene la IP
sudo nft list set inet f2b-table f2b-authelia
# table inet f2b-table {
#   set f2b-authelia {
#     type ipv4_addr
#     elements = { 192.168.1.42 }
#   }
# }

# Mientras la IP está baneada, https://auth.lan/ desde ese cliente
# da timeout (no "Connection refused"): el paquete se descarta sin RST.

# Desbanear cuando convenga
sudo fail2ban-client unban 192.168.1.42
```

### 2) Activar la jail de Vaultwarden cuando se despliegue (Fase 11)

Tras `01-vaultwarden.md`, antes de "Verificación Final":

```bash
# Confirmar que el log existe y que Vaultwarden está logueando con IP real
# (LOG_FILE=/data/vaultwarden.log y LOG_LEVEL=info en su .env)
sudo tail -3 /mnt/hd2t/apps/vaultwarden/data/vaultwarden.log
# [2025-XX-XX ...][info][...] Starting Vaultwarden ...

# Habilitar la jail
sudo sed -i 's/^enabled  = false$/enabled  = true/' \
    /etc/fail2ban/jail.d/20-vaultwarden.local

# Validar y recargar
sudo fail2ban-client -t && sudo fail2ban-client reload

# Verificar
sudo fail2ban-client status vaultwarden
sudo fail2ban-client status vaultwarden-admin
```

Provocar un login fallido con un cliente Bitwarden (móvil o navegador) confirma que la jail captura el evento. Como `IP del cliente` Vaultwarden imprime el `X-Real-IP` que le pasa Caddy: el mismo principio que con Authelia, requiere que el drop-in de Caddy para Vaultwarden incluya `header_up X-Real-IP {remote_host}` (lo hará el doc de Vaultwarden).

> **Importante para Vaultwarden**: el `.env` de Vaultwarden debe tener `IP_HEADER=X-Real-IP` (o `X-Forwarded-For`) para que confíe en el header del proxy. Si no, Vaultwarden imprime siempre la IP de Caddy en sus logs y la jail banea a Caddy. Documentar esto en el doc de Vaultwarden (Fase 11).

### 3) Activar la jail de Nextcloud cuando se despliegue (Fase 6)

Tras `06-almacenamiento/01-nextcloud.md`, idéntico procedimiento:

```bash
# Confirmar que el log existe y está en JSON (default)
sudo tail -1 /mnt/hd2t/apps/nextcloud/app/data/nextcloud.log | jq .
# {
#   "reqId": "...",
#   "level": 0,
#   ...
# }

# Habilitar
sudo sed -i 's/^enabled  = false$/enabled  = true/' \
    /etc/fail2ban/jail.d/30-nextcloud.local

sudo fail2ban-client -t && sudo fail2ban-client reload
sudo fail2ban-client status nextcloud
```

> **Importante para Nextcloud**: en `config/config.php` debe estar `'log_type' => 'file'` (default), `'logfile' => '/var/www/html/data/nextcloud.log'` (default) y `'trusted_proxies' => ['172.30.10.0/24']` (la red Docker, para que Nextcloud confíe en `X-Forwarded-For` enviado por Caddy). Sin `trusted_proxies`, `remoteAddr` en el log es siempre la IP de Caddy. Documentar en Fase 6.

### 4) Diagnóstico cuando una jail no banea

`fail2ban` ofrece un comando de prueba que aplica un filtro a un log y muestra qué líneas matchea:

```bash
# Probar el filtro de Authelia contra el log real
sudo fail2ban-regex \
    /mnt/hd2t/apps/authelia/logs/authelia.log \
    /etc/fail2ban/filter.d/authelia.local
# Lines: 12345 lines, 0 ignored, 7 matched, 12338 missed
# [processed in 0.42 sec]

# Probar contra una línea concreta (útil para depurar regex)
sudo fail2ban-regex \
    'time="2025-04-28T10:00:00+02:00" level=error msg="Unsuccessful 1FA authentication attempt by user '\''homelab'\''" method=POST path=/api/firstfactor remote_ip="192.168.1.42" stack=...' \
    /etc/fail2ban/filter.d/authelia.local
# 1 lines, 0 ignored, 1 matched
# IP found: 192.168.1.42
```

Si `Lines matched: 0` cuando hay fallos visibles en el log: revisar el regex contra la **línea exacta** con `fail2ban-regex` interactivo. Causas habituales:

| Síntoma | Causa | Resolución |
|---|---|---|
| `Lines matched: 0` con log claramente con errores | Authelia logueando en `format: json` (no `text`). | Editar `configuration.yml` y volver a `text`; recargar Authelia. |
| `IP found: 172.30.10.1` (gateway Docker) | Caddy no envía `X-Real-IP` o Authelia no confía en él. | Revisar drop-in de Caddy en `01-authelia.caddy`; confirmar `header_up X-Real-IP {remote_host}`. |
| `Got SIGUSR1 ... but no journal entries found` | Jail con `backend = systemd` sobre un servicio Docker. | Cambiar a `backend = polling` con `logpath`. |
| Bans efímeros: la IP aparece y desaparece en segundos | El log está rotando con `copytruncate` y `fail2ban` ve la rotación como "fichero nuevo, contadores a cero". | Usar logrotate con `create 0640 ...` (renombrar, no truncar) o aumentar el `monitor failures` con `inotify`. Para Authelia bajo polling con un log que aún no rota (Fase 1.3 no configura logrotate del log de Authelia), no aplica. |

---

## Almacenamiento

| Ruta | Soporte | Owner:Group | Modo | Contenido |
|---|---|---|---|---|
| `/home/homelab/homelab/stacks/_host/fail2ban/jail.d/*.local` | microSD | `homelab:homelab` | `0644` | Jails versionadas. |
| `/home/homelab/homelab/stacks/_host/fail2ban/filter.d/*.local` | microSD | `homelab:homelab` | `0644` | Filtros versionados. |
| `/etc/fail2ban/jail.d/{10-authelia,20-vaultwarden,30-nextcloud}.local` | host | `root:root` | `0644` | Materializadas. |
| `/etc/fail2ban/filter.d/{authelia,vaultwarden,vaultwarden-admin,nextcloud}.local` | host | `root:root` | `0644` | Materializadas. |
| `/etc/fail2ban/jail.local` | host | `root:root` | `0644` | Política `[DEFAULT]` + `[sshd]` (definido en `01-sistema/03-seguridad-base.md`, **no se toca aquí**). |
| `/var/lib/fail2ban/fail2ban.sqlite3` | host | `root:root` | `0640` | Estado de bans en curso (compartido con la jail SSH). |
| `/mnt/hd2t/apps/authelia/logs/authelia.log` | hd2t | UID/GID interno (Authelia) | `0640` | Producido por el contenedor de Authelia. |
| `/mnt/hd2t/apps/vaultwarden/data/vaultwarden.log` | hd2t | UID/GID interno (Vaultwarden) | `0640` | Producido por el contenedor de Vaultwarden (Fase 11). |
| `/mnt/hd2t/apps/nextcloud/app/data/nextcloud.log` | hd2t | UID/GID interno (Nextcloud) | `0640` | Producido por el contenedor de Nextcloud (Fase 6). |

> **Tamaño**: las jails añaden ~5 KB de configuración. La SQLite de fail2ban no crece notablemente con bans humanos (cada ban son <100 bytes). Los logs de aplicación crecen con el uso normal del servicio (Authelia: ~5 MB/día con 10 logins; Vaultwarden: ~10 MB/día activo; Nextcloud: ~50 MB/día activo). La rotación de esos logs **no** la define este documento: cada servicio configura su propia rotación interna o se delega al logrotate del host (Fase 1.3 menciona logrotate genérico). Si un día logrotate cambia los logs con `copytruncate`, revisar el modo de detección de fail2ban (sección Diagnóstico).

---

## Backup

A nivel de repositorio (git):

| Artefacto | Estrategia |
|---|---|
| `stacks/_host/fail2ban/jail.d/*.local` | Versionados. |
| `stacks/_host/fail2ban/filter.d/*.local` | Versionados. |
| Decisiones (whitelist relajada, polling vs systemd, banaction allports, Vaultwarden y Nextcloud disabled hasta despliegue) | Documentadas en este fichero. |

A nivel de datos (Borgmatic, Fase 7):

| Ruta | ¿Se respalda? | Por qué |
|---|---|---|
| `/etc/fail2ban/jail.d/` | Sí. | Reproducible desde el repo, pero respaldarlo evita pérdida de cambios manuales en el host. |
| `/etc/fail2ban/filter.d/*.local` | Sí. | Idem. |
| `/etc/fail2ban/jail.local` | Sí (ya cubierto en `03-seguridad-base.md`). | Política `[DEFAULT]` + jail SSH. |
| `/var/lib/fail2ban/fail2ban.sqlite3` | **No**. | Estado efímero; tras un restore, las jails empiezan vacías y eso es seguro. |
| Logs de aplicación (`authelia.log`, `vaultwarden.log`, `nextcloud.log`) | **No** desde la perspectiva de fail2ban. | Cada servicio decide qué hacer con su log. Borgmatic puede respaldarlos como parte del directorio `apps/<svc>/`, pero no son críticos: sirven para diagnóstico, no para reconstruir el estado. |

Procedimiento de restore tras pérdida total (reflasheo):

1. Recrear Fase 1.3 (fail2ban + jail SSH).
2. Restaurar `/etc/fail2ban/jail.d/` y `/etc/fail2ban/filter.d/*.local` desde Borg, **o** redespegarlos desde el repo con el `install -m 0644 ...` de la sección "Materializar y recargar".
3. `sudo fail2ban-client -t && sudo fail2ban-client reload`.
4. `sudo fail2ban-client status` debe listar `sshd, authelia` (`vaultwarden`/`nextcloud` solo si los servicios estaban desplegados antes del restore).

Si lo que se quiere es **vaciar** la lista de bans actuales (operación de mantenimiento, p. ej. tras reset del router doméstico que asigna nuevas IPs DHCP):

```bash
sudo fail2ban-client unban --all
# O por jail:
sudo fail2ban-client set authelia unbanip --all
```

Esto **no** afecta la SQLite de bans históricos: el contador `Total banned` sigue creciendo monotónicamente.

---

## Errores frecuentes y troubleshooting

| Síntoma | Causa probable | Resolución |
|---|---|---|
| `fail2ban-client reload` falla con "Failed during configuration" tras añadir las jails | `failregex` mal cerrada o `logpath` inexistente. | `sudo fail2ban-client -t` antes de `reload` lo dice exactamente; arreglar el fichero `.local` señalado. |
| `[authelia]` aparece en `status` pero `Total failed: 0` tras decenas de fallos visibles en el log | El log está en JSON (no `text`), el `failregex` no matchea. | Editar `01-authelia.md` configuration.yml `log.format: text`; reiniciar Authelia. Verificar con `fail2ban-regex /mnt/hd2t/apps/authelia/logs/authelia.log /etc/fail2ban/filter.d/authelia.local`. |
| Banean a `172.30.10.1` (gateway Docker) | Authelia/Vaultwarden/Nextcloud no reciben/no confían en `X-Real-IP`. | Confirmar `header_up X-Real-IP {remote_host}` en el drop-in de Caddy del servicio. En Vaultwarden: `IP_HEADER=X-Real-IP` en `.env`. En Nextcloud: `'trusted_proxies' => ['172.30.10.0/24']` en `config.php`. |
| El operador se autobanea por equivocarse 5 veces de TOTP | Funcionando como diseñado: la whitelist relajada (`127.0.0.1/8 ::1`) excluye la LAN. | `sudo fail2ban-client unban <ip-del-operador>`. Revisar TOTP del móvil; reloj desincronizado del móvil causa rechazos repetidos. |
| Tras `sudo reboot`, `fail2ban-client status` solo lista `sshd` | Las jails con `enabled = true` no se cargan por error en `jail.d/`. Algunas distribuciones cachean en `/var/lib/fail2ban` y un `reload` aceptó configuración rota. | `sudo fail2ban-client -t` muestra el error; arreglar el fichero ofensor; `sudo systemctl restart fail2ban`. |
| `nftables` no muestra el set `f2b-authelia` | Otra herramienta (`ufw` con drop-in agresivo, otro daemon) reescribe el ruleset y pisa los sets de fail2ban. | `sudo nft list ruleset > /tmp/nft.dump`; revisar qué tabla contiene `f2b-*`. Como medida, fijar `banaction = nftables[type=allports,table=inet f2b-table]` con tabla explícita. |
| El log de Authelia rota y la jail "olvida" los fallos antiguos | Comportamiento normal: `fail2ban` reabre el fichero al detectar el cambio de inode; los fallos en el log antiguo siguen contabilizados durante `findtime`. | No es un error; si se quiere que el ban persista entre rotaciones, `findtime` corto + `bantime.increment` ya cubre el caso. |
| `fail2ban` consume %CPU notable en la Pi | El log de Authelia/Vaultwarden está creciendo a >1 MB/min (raro, indica escaneo masivo) y el polling re-lee desde el inicio. | Activar `inotify` con `backend = inotify` en la jail (Linux only, sí en Pi). Es una optimización, no un fix. |
| Una IP banearda sigue conectándose al portal | El ban es del firewall: si la conexión TCP YA estaba establecida, `nftables` no la corta hasta que expira el cliente. | `nft add rule inet filter ...` puede forzar drop de conexiones existentes; en la práctica los timeouts del cliente cierran en <60 s. No vale la pena complicar. |
| Un servicio desplegado nuevo (p. ej. Paperless) no tiene jail | Funcionando como diseñado: solo Authelia/Vaultwarden/Nextcloud tienen jail explícita; Paperless va detrás de Authelia (`policy: two_factor`) y la jail-Authelia banea fuerza bruta contra cualquier subdominio del SSO. | Si Paperless expone un endpoint que no pasa por SSO (API tokens), añadir filtro/jail en una iteración futura siguiendo el patrón de este documento. |

---

## Decisiones que **no** se toman en este documento

- **Jail para Caddy access log**: requiere activar logs JSON globales en Caddy (decisión inversa a `04-caddy.md` que solo activa `errors`). Cuando llegue Fase 5 (monitorización con Loki/Promtail) se reabre: si los logs de acceso ya van a Loki, una jail extra que polling el mismo fichero es trivial.
- **Jail para Pi-hole**: la cookie de admin de Pi-hole está detrás de Authelia (`policy: one_factor`), y el escaneo masivo dispararía la jail-Authelia antes que cualquier intento llegue a Pi-hole. Reabrible si en el futuro se decide quitar Authelia de delante de Pi-hole.
- **Jail para Jellyfin / Stash**: ambos en `bypass` con auth nativa. Jellyfin tiene logs estructurados con IP de cliente; cuando Fase 9/10 se cierre, se evalúa si la fuerza bruta contra esos servicios es un riesgo real (no lo es para clientes locales con PIN). Reabrible.
- **Recidive jail** (banear durante 1 semana a IPs que aparezcan en N jails distintas): útil en hosts expuestos a Internet con miles de bots; sobrecoste innecesario en un homelab cerrado a LAN+Tailscale. Reabrible si llegan a darse falsos positivos repetidos.
- **`actionban` que envíe webhook/notificación**: depende de Fase 5 (Alertmanager) o Fase 11 (Mailrise). Hoy se loguea al journal: `journalctl -u fail2ban -f`.
- **`actionban` que reporte a `abuseipdb.com` o similar**: el homelab no expone a Internet; reportar IPs que ni siquiera son atacantes externos sería incorrecto. Descartado en este alcance.
- **Reemplazar polling por `inotify`**: optimización válida en Linux; evita re-lecturas. Se deja en polling por simplicidad y porque la carga es despreciable. Reabrible si la Pi muestra %CPU elevado por fail2ban.
- **Centralizar logs de Docker en el journal del host con driver `journald`**: evaluado en "Decisión: cómo se accede a los logs". Descartado por contaminación del journal y por incompatibilidad con servicios que loguean a fichero.

---

## Verificación Final

Antes de pasar a la Fase 5 (`05-monitorizacion/`):

| Comprobación | Comando | Resultado esperado |
|---|---|---|
| `fail2ban` operativo tras los cambios | `sudo systemctl is-active fail2ban` | `active` |
| Sintaxis de jails y filters válida | `sudo fail2ban-client -t` | sin errores; salida vacía o "OK" |
| Jails activas listadas | `sudo fail2ban-client status` | `Jail list: authelia, sshd` (sin `vaultwarden`/`nextcloud` mientras estén `enabled = false`) |
| Filtro de Authelia matchea | `sudo fail2ban-regex /mnt/hd2t/apps/authelia/logs/authelia.log /etc/fail2ban/filter.d/authelia.local` | `Lines matched: > 0` tras provocar fallos |
| Authelia recibe el IP real del cliente | `grep -E 'remote_ip=' /mnt/hd2t/apps/authelia/logs/authelia.log \| tail -3` | IPs de la LAN (`192.168.1.x`), nunca `172.30.10.1` |
| Ban funcional contra Authelia | provocar 5 fallos de login, luego `sudo fail2ban-client status authelia` | `Currently banned: 1`, `Banned IP list:` con la IP atacante |
| Set de nftables creado | `sudo nft list set inet f2b-table f2b-authelia` (o `nft list ruleset \| grep f2b-authelia`) | set existe y contiene la IP |
| Ban se libera tras `bantime` | esperar 1 h o `sudo fail2ban-client set authelia unbanip <ip>` | `Currently banned: 0` |
| Whitelist mínima en jails de servicio | `sudo fail2ban-client get authelia ignoreip` | `127.0.0.1/8 ::1` (no la LAN) |
| Whitelist amplia en jail SSH (no se ha tocado) | `sudo fail2ban-client get sshd ignoreip` | `127.0.0.1/8 ::1 192.168.1.0/24 100.64.0.0/10` |
| Persistencia tras reboot | `sudo reboot`; tras volver: `sudo fail2ban-client status` | `Jail list: authelia, sshd`; sin acción manual |
| Stack en git | `git status; git ls-files stacks/_host/fail2ban/` | siete ficheros tracked (3 jails + 4 filters); `/etc/fail2ban/` no es git, está documentado el flujo de materialización |
| Vaultwarden y Nextcloud preparados (deshabilitados) | `grep -E '^enabled' /etc/fail2ban/jail.d/{20-vaultwarden,30-nextcloud}.local` | `enabled  = false` en los tres bloques |

Cumplido el último punto, el homelab tiene **el doble candado** sobre los puntos de entrada con autenticación: el `regulation` interno de Authelia frenando el bucle de login a nivel de aplicación, y `fail2ban` cerrando el TCP a nivel de host. Las jails de Vaultwarden y Nextcloud quedan listas para activarse con un `sed` cuando esos servicios se desplieguen en Fases 6 y 11. La siguiente puerta abre la Fase 5: **monitorización**, que entre otras cosas convertirá el `journalctl -u fail2ban` actual en alertas por servicio cuando una IP sea baneada.

---

## Referencias

- [Documento anterior: `docs/04-seguridad/01-authelia.md`](./01-authelia.md)
- [Documento relacionado: `docs/01-sistema/03-seguridad-base.md`](../01-sistema/03-seguridad-base.md)
- [Documento relacionado: `docs/03-red/04-caddy.md`](../03-red/04-caddy.md)
- [Documento relacionado: `docs/03-red/05-tailscale.md`](../03-red/05-tailscale.md)
- [Documento futuro: `docs/06-almacenamiento/01-nextcloud.md`](../06-almacenamiento/01-nextcloud.md)
- [Documento futuro: `docs/11-productividad/01-vaultwarden.md`](../11-productividad/01-vaultwarden.md)
- [`fail2ban` — Wiki oficial](https://github.com/fail2ban/fail2ban/wiki)
- [`fail2ban` — Manpages: `jail.conf(5)`, `fail2ban-client(1)`, `fail2ban-regex(1)`](https://manpages.debian.org/bookworm/fail2ban/fail2ban.1.en.html)
- [Authelia — Integración con `fail2ban`](https://www.authelia.com/integration/deployment/docker/#fail2ban)
- [Vaultwarden — `Fail2Ban Setup` (wiki oficial)](https://github.com/dani-garcia/vaultwarden/wiki/Fail2Ban-Setup)
- [Nextcloud — `Use fail2ban` (admin manual)](https://docs.nextcloud.com/server/latest/admin_manual/installation/harden_server.html#use-fail2ban)
- [`nftables` — Wiki oficial](https://wiki.nftables.org/wiki-nftables/index.php/Main_Page)
- [`fail2ban` — Banaction `nftables`](https://github.com/fail2ban/fail2ban/blob/master/config/action.d/nftables.conf)
