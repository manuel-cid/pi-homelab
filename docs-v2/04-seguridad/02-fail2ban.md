# Fail2ban — Jails para servicios

## Descripción

Configuración **avanzada** de [Fail2ban](https://github.com/fail2ban/fail2ban) en el host de la Pi 5: añade jails específicos para los servicios web del homelab encima del jail base de SSH que ya quedó en marcha en [`../01-sistema/03-seguridad-base.md`](../01-sistema/03-seguridad-base.md) §5.

El objetivo de este documento es **ban a nivel de red (nftables)** complementario a las protecciones que cada aplicación trae de fábrica:

- **Authelia** ya hace *regulation* a nivel de aplicación (3 fallos en 2 min → ban del usuario por 5 min, ver [`./01-authelia.md`](./01-authelia.md) §5 `regulation:`). Eso bloquea **al usuario**, no a la **IP**: el atacante puede probar otros usernames sin penalización. Fail2ban cierra ese hueco baneando la IP entera.
- **Nextcloud** trae *brute-force protection* nativa (retardo exponencial). Fail2ban refuerza el corte cuando un atacante mantiene el ritmo aceptable para Nextcloud pero claramente abusivo (decenas de IPs vs un solo recurso).
- **Vaultwarden** no trae nada; depende **íntegramente** de la capa Authelia/Caddy + este Fail2ban.
- **Caddy** registra todo el tráfico HTTP en `access.log` JSON ([`../03-red/04-caddy.md`](../03-red/04-caddy.md) §4.4); Fail2ban lo aprovecha para banear escáneres de URLs y peticiones malformadas que ni siquiera llegan a Authelia.

> **Alcance de red**: este homelab **no está expuesto a internet** (ver [`../../PLAN.md`](../../PLAN.md) cabecera). Lo único que se ofrece fuera del propio host es:
>
> - SSH a la LAN (jail `sshd`, ya configurado en Fase 1).
> - Servicios web por Caddy (puertos 80/443) sólo a la LAN y a Tailscale.
>
> Por eso el modelo de amenaza primario es **un nodo de la LAN comprometido** (un PC con malware, una IoT pirateada en la WiFi, un invitado curioso) y **un par Tailscale comprometido** (un dispositivo del operador con sus llaves robadas). En ambos casos Fail2ban actúa como segunda barrera tras Authelia.

> **Alcance del documento**: configura Fail2ban en el **host** (no en contenedor). Añade los jails para Authelia y Caddy, deja **preparados pero deshabilitados** los jails para Nextcloud y Vaultwarden (que se activarán cuando esos servicios se desplieguen en sus respectivas fases). **No** sustituye al jail `sshd` de Fase 1 — convive con él. **No** modifica `/etc/fail2ban/jail.local` (que se quedó cerrado en Fase 1); todos los cambios viven en *drop-ins* dentro de `/etc/fail2ban/jail.d/` y filtros nuevos en `/etc/fail2ban/filter.d/`.

---

## Requisitos Previos

- **Fase 1 completa**: `fail2ban` instalado y con el jail `sshd` activo según [`../01-sistema/03-seguridad-base.md`](../01-sistema/03-seguridad-base.md) §5. `sudo fail2ban-client status` lista al menos `sshd`.
- **Caddy desplegado** según [`../03-red/04-caddy.md`](../03-red/04-caddy.md), con `access.log` JSON rotando en `/mnt/hd2t/services/proxy/logs/access.log`. Verificar:
  ```bash
  sudo tail -1 /mnt/hd2t/services/proxy/logs/access.log | python3 -m json.tool
  # Esperado: objeto JSON con request.host, request.remote_ip, status...
  ```
- **Authelia desplegado** según [`./01-authelia.md`](./01-authelia.md), accesible vía `https://auth.${LAN_DOMAIN}` y registrando eventos en stdout.
- **`nftables` activo** como backend de Fail2ban (`banaction = nftables-allports` heredado de Fase 1, ver [`../01-sistema/03-seguridad-base.md`](../01-sistema/03-seguridad-base.md) §5.2).
- **Acceso a `sudo`** en el host. Fail2ban se administra como root.
- **Comprobaciones rápidas**:
  ```bash
  # Fail2ban responde:
  sudo fail2ban-client ping
  # Esperado: Server replied: pong

  # nftables disponible:
  sudo nft --version
  # Esperado: nftables v1.0.x

  # Backend de logs de Authelia accesible (Authelia 4.38 escribe a stdout y, tras §3 de este doc, también a fichero):
  docker logs --tail 5 authelia
  # Esperado: líneas time="..." level=...
  ```

### Decisiones de diseño asumidas

| Decisión | Valor por defecto | Justificación |
|---|---|---|
| Fail2ban **en el host**, no en un contenedor | Host (paquete `apt`) | Fail2ban necesita escribir reglas `nftables` en el namespace de red **del host** para banear IPs antes de que el tráfico llegue a Docker. Un Fail2ban dentro de un contenedor sólo puede tocar su propio netns: o se le da `--net=host` + `--cap-add NET_ADMIN` (riesgoso) o no banea nada. La instalación del paquete del host también permite reutilizar el demonio que ya gestiona el jail SSH y comparte el resolver de logs (`systemd-journal`). |
| Backend de banning | **`nftables-allports`** (heredado de Fase 1) | Misma justificación que `sshd`: aísla por completo a la IP atacante, no sólo el puerto del servicio comprometido. Si la IP intenta `https`, `ssh` y luego `samba`, queda fuera de los tres mientras dure el ban. |
| Ubicación de los jails nuevos | **`/etc/fail2ban/jail.d/*.conf`** (uno por servicio) | `jail.local` quedó cerrado en Fase 1 con sólo SSH + defaults. Los drop-ins en `jail.d/` se cargan en orden alfabético tras `jail.local`, **heredan** el `[DEFAULT]` (incluido `ignoreip`, `bantime.increment`, `banaction`, `backend`) y son fáciles de habilitar/deshabilitar con un solo `enabled = true/false`. Versionables uno a uno. |
| Ubicación de los filtros nuevos | **`/etc/fail2ban/filter.d/*.local`** | Misma convención que el paquete: los filtros del propio paquete viven en `filter.d/*.conf`; los del operador viven con sufijo `.local` para que un upgrade de `apt` no los pise. |
| Tiempos por defecto en jails de aplicación | `findtime = 10m` / `maxretry = 5` / `bantime = 1h`, con `bantime.increment = true` | Heredado de `[DEFAULT]` de Fase 1 ([`../01-sistema/03-seguridad-base.md`](../01-sistema/03-seguridad-base.md) §5.2). No hace falta repetirlo en cada jail; sólo se sobreescribe cuando un servicio lo necesita (Authelia bajará a 3/2m, Caddy subirá a 20/5m). |
| `ignoreip` | **Heredado del `[DEFAULT]` de Fase 1**: `127.0.0.1/8 ::1 192.168.1.0/24` | Mismo razonamiento: el operador opera desde la propia LAN; un baneo accidental cortaría el acceso a todos los servicios. **Tailscale** (CGNAT `100.64.0.0/10`) **no** se añade aquí: cualquier nodo Tailscale comprometido sí debe poder ser baneado. Si en el futuro el operador trabaja habitualmente desde un nodo Tailscale fijo, se añade su IP `100.64.x.y/32` puntualmente, no el rango entero. |
| Fuente de logs de Authelia | **Fichero `/mnt/hd2t/services/auth/authelia/config/authelia.log`** (configurado en §3 de este doc) | Authelia 4.38 puede escribir su log a un fichero además de stdout (`log.file_path` + `log.keep_stdout`). Leer un fichero plano vía `logpath` es la integración más estable: independiente del driver de logs de Docker (que en este homelab es `json-file`, [`../02-docker/01-instalacion-docker.md`](../02-docker/01-instalacion-docker.md) §4.3) y resistente a reinicios del contenedor (el path persiste en `hd2t`). Alternativa con `backend = systemd` exigiría conmutar el driver de Docker a `journald` por contenedor, mayor superficie de cambios. |
| Fuente de logs de Caddy | **Fichero `/mnt/hd2t/services/proxy/logs/access.log`** (JSON, ya existente) | Generado por Caddy según [`../03-red/04-caddy.md`](../03-red/04-caddy.md) §4.3 (`log default { output file ... format json }`). No se cambia nada en Caddy; sólo se añade un filtro Fail2ban que parsea la línea JSON. |
| Filtro Caddy | **Regex sobre la línea JSON** (`failregex` con `<HOST>` casado contra `request.client_ip`) | El `client_ip` del JSON ya está resuelto por Caddy y respeta cabeceras `X-Forwarded-For` desde Tailscale. `remote_ip` casaría con la IP TCP del par directo, que en el caso de un nodo Tailscale sería la IP de la red `100.64.0.0/10` (deseable: queremos banear ese nodo, no a un cliente detrás de él). |
| Estados de los servicios futuros | **`enabled = false`** en `jail.d/nextcloud.conf` y `jail.d/vaultwarden.conf` | Los servicios aún no están desplegados; un `enabled = true` con `logpath` inexistente provoca que Fail2ban entre en `failed` y rompa los jails que **sí** funcionan. Se entregan listos para `enabled = true` en cuanto el doc del servicio se complete. Cada doc de servicio referenciará a esta sección. |
| Notificaciones de Fail2ban | **Solo journald** (sin email) | Coherente con el homelab (sin SMTP saliente, ver [`./01-authelia.md`](./01-authelia.md) §0 punto 7). Las notificaciones de bans se ven con `journalctl -u fail2ban -f` y, una vez desplegado Loki/Grafana en Fase 5+, se pueden enrutar como alertas. |
| Recarga de Fail2ban tras edición | **`fail2ban-client reload`** (no `restart`) | `reload` aplica los cambios manteniendo el estado de bans existente. `restart` pierde el estado de bans en RAM (los persistentes siguen, ver `dbfile` por defecto, pero hay corte). Sólo se reinicia tras tocar `/etc/fail2ban/fail2ban.conf` (no es el caso aquí). |

---

## 1. Resumen de la arquitectura

```
                ┌────────────────── LAN 192.168.1.0/24 ───────────────────────┐
                │                                                             │
   atacante ────┤   (forma 1)  https://nextcloud.lan ──┐                      │
   ext. (en LAN)│                                       │                     │
                │                                       │                     │
   atacante ────┤   (forma 2)  https://auth.lan ───────┼──► Caddy :443        │
   Tailscale    │   (login form, 401 si falla)         │   (en homelab)       │
                │                                       │                     │
                └───────────────────────────────────────┼─────────────────────┘
                                                        │
                              ┌─────────────────────────▼────────────────┐
                              │  Pi 5 (host)                             │
                              │                                          │
                              │   ┌──── Caddy contenedor ──────────┐    │
                              │   │ /var/log/caddy/access.log JSON │    │
                              │   │  bind ──────────────────────────┼──► /mnt/hd2t/services/proxy/logs/access.log
                              │   └────────────────────────────────┘    │
                              │                                          │
                              │   ┌──── Authelia contenedor ───────┐    │
                              │   │ /config/authelia.log (text)    │    │
                              │   │  bind ──────────────────────────┼──► /mnt/hd2t/services/auth/authelia/config/authelia.log
                              │   └────────────────────────────────┘    │
                              │                                          │
                              │   ┌──── fail2ban (host, root) ─────┐    │
                              │   │  watchers:                     │    │
                              │   │   - jail.d/sshd (Fase 1)       │    │
                              │   │   - jail.d/authelia.conf       │◄───┤  tail -F authelia.log
                              │   │   - jail.d/caddy-status.conf   │◄───┤  tail -F access.log
                              │   │   - jail.d/nextcloud.conf  ⏸   │    │
                              │   │   - jail.d/vaultwarden.conf ⏸  │    │
                              │   │                                │    │
                              │   │  ban → nftables tabla `f2b-*`  │    │
                              │   │       drop-all desde ip mala   │    │
                              │   └────────────────────────────────┘    │
                              └──────────────────────────────────────────┘
```

Tres invariantes del modelo:

- **Fail2ban actúa antes de que el tráfico llegue a Docker.** La regla `nft drop` se inserta en la cadena de input/forward del host; el atacante recibe `connection refused` o timeout, no entra ni siquiera a Caddy.
- **Cada jail mira un fichero distinto, ningún acoplamiento entre ellos.** Si Authelia se cae, su jail deja de banear (no hay logs nuevos), pero `caddy-status` sigue funcionando, y viceversa.
- **El estado de bans persiste en `/var/lib/fail2ban/fail2ban.sqlite3`.** Reinicios del demonio o del host no resetean la lista de IPs ya baneadas (excepto las que ya hubieran cumplido `bantime`).

Flujo de un ban (caso real "atacante intenta credstuffing en `auth.lan` desde 192.168.1.99"):

```
1. Atacante → POST /api/firstfactor (Caddy:443) con user='admin' password='123456'
2. Caddy → forward a authelia:9091 → Authelia comprueba hash → falla
3. Authelia → log: level=error msg="Unsuccessful 1FA authentication attempt by user 'admin'" remote_ip=192.168.1.99
4. Authelia → log: line append a /config/authelia.log (path nuevo, §3)
5. Atacante repite (3 veces más, 3 fallos en 2 min)
6. Authelia regulation → user 'admin' baneado 5 min (afecta a admin, NO a la IP)
7. Atacante prueba user 'root' → pasos 2-5 de nuevo
8. Fail2ban (jail authelia, maxretry=3, findtime=2m) → cuenta 6 fallos desde 192.168.1.99
9. Fail2ban → nft add element inet f2b-authelia addr-set { 192.168.1.99 }
10. Atacante → siguiente conexión 192.168.1.99 → DROP en nftables
11. (1 hora después) bantime expira → Fail2ban → nft delete element ...
    Si la IP reincide, bantime.increment duplica: 2h, 4h, ... hasta 1 semana.
```

---

## 2. Plan de variables y archivos

```
~/homelab/etc/fail2ban/                       # versionable en git (copia espejo)
├── filter.d/
│   ├── authelia.local
│   ├── caddy-status.local
│   ├── nextcloud.local                       # listo, no activado
│   └── vaultwarden.local                     # listo, no activado
└── jail.d/
    ├── 10-authelia.conf
    ├── 20-caddy-status.conf
    ├── 30-nextcloud.conf                     # listo, no activado (enabled=false)
    └── 40-vaultwarden.conf                   # listo, no activado (enabled=false)

/etc/fail2ban/                                # ruta REAL en el host
├── jail.conf                                 # paquete (no se toca)
├── jail.local                                # creado en Fase 1, sólo SSH + DEFAULT
├── jail.d/                                   # drop-ins versionables, este doc
└── filter.d/
    ├── *.conf                                # paquete (no se toca)
    └── *.local                               # filtros nuevos del operador
```

Los ficheros del repo (`~/homelab/etc/fail2ban/`) son la **fuente de verdad versionable**. Se copian a `/etc/fail2ban/` con `sudo install` para que el demonio los lea. Razones:

- Mantener `/etc/fail2ban/` editado con un editor a pelo dificulta el rollback. Tener una copia en el repo permite `git diff` antes de aplicar.
- Si la microSD muere, el restore es: reinstalar Fail2ban + Fase 1 + `cp ~/homelab/etc/fail2ban/* /etc/fail2ban/`.
- El prefijo numérico (`10-`, `20-`, ...) fija el orden de carga: Authelia primero, Caddy después, futuros más adelante. No es estrictamente necesario (los jails son independientes) pero es legible.

### 2.1. Crear el árbol en el repo

```bash
mkdir -p ~/homelab/etc/fail2ban/filter.d
mkdir -p ~/homelab/etc/fail2ban/jail.d
```

> **Nota**: este directorio es **paralelo** a `~/homelab/stacks/`. Los ficheros bajo `~/homelab/etc/` representan configuración del *host* (no de Docker). La estructura está prevista en [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §1 como repositorio de configuraciones del homelab; aquí se materializa por primera vez.

---

## 3. Habilitar log a fichero en Authelia

Authelia 4.38 escribe por defecto a stdout (recogido por `docker logs authelia` y rotado por el driver `json-file` de Docker). Para que Fail2ban lea esos eventos sin tener que tocar el driver de Docker ni montar `journald`, se añade un *log path* en disco.

### 3.1. Editar `configuration.yml`

Editar `~/homelab/stacks/auth/configuration.yml` y modificar el bloque `log:` que dejó §5 de [`./01-authelia.md`](./01-authelia.md):

```yaml
log:
  level: info
  format: text
  # NUEVO — fichero plano para que fail2ban lo tail-ee.
  # Path dentro del contenedor; el bind /config/ apunta a
  # /mnt/hd2t/services/auth/authelia/config/ en el host.
  file_path: /config/authelia.log
  # Mantener stdout activo: docker logs sigue funcionando para troubleshooting.
  keep_stdout: true
```

### 3.2. Aplicar y verificar

```bash
cd ~/homelab/stacks/auth
docker compose restart authelia

# El fichero debe aparecer en el host:
ls -l /mnt/hd2t/services/auth/authelia/config/authelia.log
# Esperado: -rw-r--r--  1 1000 1000  ... authelia.log

# Forzar una entrada (intento de login fallido desde el navegador) y verificar:
sudo tail -F /mnt/hd2t/services/auth/authelia/config/authelia.log
# Pulsar "Sign in" con un user vacío en https://auth.lan; deberían aparecer líneas:
# time="..." level=error msg="Unsuccessful 1FA authentication attempt by user '...'" ...
```

> **Permisos**: Authelia corre como `1000:1000` (`PUID:PGID`, ver [`./01-authelia.md`](./01-authelia.md) §7). El fichero queda con esos UID/GID. Fail2ban corre como `root` y lee sin problema. **No** se cambian permisos del fichero.

> **Rotación**: Authelia no rota `authelia.log`. La rotación se delega a `logrotate` del host en §10 de este doc.

---

## 4. Filtro y jail: Authelia

### 4.1. Filtro `authelia.local`

`~/homelab/etc/fail2ban/filter.d/authelia.local`:

```ini
# Fail2ban filter — Authelia 4.38 (formato text)
#
# Caza eventos de autenticación fallida en el portal Authelia, ya sea en la
# fase 1FA (password), 2FA (TOTP/Webauthn/Duo) o resets de contraseña con
# token expirado.
#
# Documentación oficial: https://www.authelia.com/integration/fail2ban/

[INCLUDES]
before = common.conf

[Definition]
_daemon = authelia

# Líneas tipo:
#   time="2025-01-01T12:00:00+01:00" level=error msg="Unsuccessful 1FA authentication attempt by user 'admin': bla" method=POST path=/api/firstfactor remote_ip=192.168.1.99 stack=...
#   time="..." level=error msg="Unsuccessful TOTP authentication attempt by user 'admin'" remote_ip=192.168.1.99 ...
#   time="..." level=error msg="Unsuccessful Webauthn authentication attempt by user 'admin'" remote_ip=192.168.1.99 ...
#   time="..." level=error msg="user 'admin' has been banned" remote_ip=192.168.1.99 ...   (regulation in-app)
failregex = ^.*level=error.*msg="Unsuccessful (1FA|TOTP|Webauthn|Duo) authentication attempt by user '[^']+'.*remote_ip=<HOST>.*$
            ^.*level=error.*msg="user '[^']+' has been banned".*remote_ip=<HOST>.*$
            ^.*level=error.*msg="Sign in failed".*remote_ip=<HOST>.*$

ignoreregex =

datepattern = ^time="%%Y-%%m-%%dT%%H:%%M:%%S(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})"
```

Comentarios:

- Las tres `failregex` cubren (a) los fallos directos de cualquier factor, (b) la *regulation* in-app de Authelia (cuando ella misma decide banear al usuario, la IP también es sospechosa) y (c) errores genéricos de "Sign in failed" que incluyan `remote_ip` (versiones recientes los emiten en algunos flujos OIDC y password-reset).
- `<HOST>` es el placeholder estándar de Fail2ban para una IP (resuelto a `addr` en `nftables`). No usar `<ADDR>`: ese sólo casa con literales IP, no con DNS, y aquí `remote_ip=` siempre es IP pero el `<HOST>` también funciona y es la convención del proyecto.
- `datepattern` declara el formato ISO-8601 que usa Authelia. Sin esto Fail2ban cae al detector automático y a veces falla con la zona horaria.

### 4.2. Jail `10-authelia.conf`

`~/homelab/etc/fail2ban/jail.d/10-authelia.conf`:

```ini
# Fail2ban jail — Authelia portal
#
# Hereda backend, banaction, ignoreip y bantime.* del [DEFAULT] que
# fijó docs/01-sistema/03-seguridad-base.md §5.2.
#
# Sólo se sobreescriben los parámetros específicos del servicio.

[authelia]
enabled  = true
filter   = authelia
# Fichero generado por Authelia (ver docs/04-seguridad/02-fail2ban.md §3).
logpath  = /mnt/hd2t/services/auth/authelia/config/authelia.log
backend  = polling

# 3 fallos en 2 minutos → ban inicial de 1 hora (heredado).
# Reincidente: 2h, 4h, ... hasta 1 semana (bantime.increment de DEFAULT).
findtime = 2m
maxretry = 3
```

Notas:

- `backend = polling` para este jail: el `[DEFAULT]` de Fase 1 fija `backend = systemd` (que sólo aplica al jail `sshd`). Aquí leemos un fichero plano, así que se sobreescribe explícitamente.
- `findtime` y `maxretry` quedan más agresivos que el default (5/10m): Authelia ya hace su propia *regulation* a 3/2m; alinearlo evita escenarios "user baneado por Authelia sin que la IP se haya baneado todavía".
- `bantime` no se declara: hereda 1h + increment.

### 4.3. Aplicar

```bash
sudo install -m 644 -o root -g root \
    ~/homelab/etc/fail2ban/filter.d/authelia.local \
    /etc/fail2ban/filter.d/authelia.local

sudo install -m 644 -o root -g root \
    ~/homelab/etc/fail2ban/jail.d/10-authelia.conf \
    /etc/fail2ban/jail.d/10-authelia.conf

# Probar el filtro contra el log REAL antes de recargar:
sudo fail2ban-regex \
    /mnt/hd2t/services/auth/authelia/config/authelia.log \
    /etc/fail2ban/filter.d/authelia.local

# Si el log aún está vacío, generar 2-3 logins fallidos en https://auth.lan
# desde un equipo de pruebas, repetir fail2ban-regex.

# Recargar el demonio:
sudo fail2ban-client reload

# Verificar que el jail está activo:
sudo fail2ban-client status authelia
```

Salida esperada de `status authelia`:

```
Status for the jail: authelia
|- Filter
|  |- Currently failed: 0
|  |- Total failed:     0
|  `- File list:        /mnt/hd2t/services/auth/authelia/config/authelia.log
`- Actions
   |- Currently banned: 0
   |- Total banned:     0
   `- Banned IP list:
```

---

## 5. Filtro y jail: Caddy (status 4xx abusivos)

### 5.1. Por qué un jail sobre Caddy

Caddy ve **toda** la petición HTTP antes de que llegue al backend. Su `access.log` JSON es la mejor fuente para detectar:

- **Escáneres de URLs** (404 masivos contra paths como `/wp-admin`, `/.env`, `/phpmyadmin`).
- **Fuerza bruta a APIs sin formulario** que no tocan Authelia (peticiones directas con cabeceras `Authorization` falsas → 401/403 sin redirección).
- **Clientes que ignoran cabeceras de seguridad** y reintenten contra Caddy aun cuando éste devuelve 403 (intento de evasión).

> **Cuidado con los falsos positivos**: el flujo normal de Authelia genera 401/403 legítimos en `auth.lan` durante el login. Por eso el jail **excluye explícitamente el host `auth.lan`** y se centra en el resto de hosts del homelab.

### 5.2. Filtro `caddy-status.local`

`~/homelab/etc/fail2ban/filter.d/caddy-status.local`:

```ini
# Fail2ban filter — Caddy access.log JSON
#
# Cuenta como fallo cualquier petición con status >=400 dirigida a un host
# distinto de auth.lan (donde 401/403 son normales durante el login).
#
# Formato esperado: una línea JSON por petición, generada por
#   log default { output file ... format json }
# en docs/03-red/04-caddy.md §4.3.

[INCLUDES]
before = common.conf

[Definition]
_daemon = caddy

# La línea JSON tiene:
#   "request":{"remote_ip":"X","client_ip":"X","host":"H","method":"M","uri":"U", ...}
#   "status":NNN
#
# Caddy emite los campos en este orden, así que esta regex es estable.
# client_ip > remote_ip: client_ip respeta X-Forwarded-For desde el shim
# de Tailscale; en LAN pura ambos coinciden.
failregex = ^\{.*"client_ip":"<HOST>".*"host":"(?!auth\.).*".*"status":(4\d\d|5\d\d).*\}$

ignoreregex = ^\{.*"host":"auth\..*".*$

datepattern = ^\{.*"ts":(\d+)
```

Comentarios:

- El *negative lookahead* `"host":"(?!auth\.)"` excluye cualquier `host` que empiece por `auth.` (cubre `auth.lan`, `auth.tailnet.ts.net`, etc.).
- `4\d\d|5\d\d` cubre 4xx y 5xx; los 5xx no son culpa del cliente, pero sí señalan abuso (intentos de exploit que disparan errores).
- `datepattern` toma el campo `ts` (epoch float) que emite zap. Fail2ban acepta epoch como timestamp.
- El `ignoreregex` está duplicado (también en `failregex`) por seguridad: si la versión de Fail2ban del paquete evalúa los lookaheads de forma poco fiable, el `ignoreregex` actúa como segundo filtro.

### 5.3. Jail `20-caddy-status.conf`

`~/homelab/etc/fail2ban/jail.d/20-caddy-status.conf`:

```ini
# Fail2ban jail — Caddy 4xx/5xx (excluyendo auth.lan).

[caddy-status]
enabled  = true
filter   = caddy-status
logpath  = /mnt/hd2t/services/proxy/logs/access.log
backend  = polling

# Más permisivo que Authelia: un usuario legítimo puede generar varios 404
# sin querer (favicon, sourcemaps de DevTools, bots benignos). 20 fallos
# en 5 min indican abuso real.
findtime = 5m
maxretry = 20
```

### 5.4. Aplicar

```bash
sudo install -m 644 -o root -g root \
    ~/homelab/etc/fail2ban/filter.d/caddy-status.local \
    /etc/fail2ban/filter.d/caddy-status.local

sudo install -m 644 -o root -g root \
    ~/homelab/etc/fail2ban/jail.d/20-caddy-status.conf \
    /etc/fail2ban/jail.d/20-caddy-status.conf

# Probar el filtro contra el log real:
sudo fail2ban-regex \
    /mnt/hd2t/services/proxy/logs/access.log \
    /etc/fail2ban/filter.d/caddy-status.local

# Si actualmente no hay tráfico de error, generar uno:
curl -sk -o /dev/null -w '%{http_code}\n' https://pihole.lan/no-existe-este-path
# Esperado: 404. Repetir 21 veces para ver el ban en pruebas (con una IP
# que no esté en ignoreip; usar un nodo Tailscale o un móvil con datos).

sudo fail2ban-client reload
sudo fail2ban-client status caddy-status
```

---

## 6. Jails preparados (no activados): Nextcloud y Vaultwarden

Los siguientes jails están listos para entrar en servicio cuando los servicios correspondientes se desplieguen. **Mientras tanto, `enabled = false`**: si se activaran sin que el `logpath` exista, Fail2ban entra en estado degradado y los jails buenos siguen funcionando, pero la salud general del demonio queda en `failed` y dispara avisos en `journalctl`.

Cada doc de servicio (`docs/06-almacenamiento/01-nextcloud.md` y `docs/11-productividad/01-vaultwarden.md`) referenciará a esta sección y, como último paso de su despliegue, cambiará `enabled = true`.

### 6.1. Nextcloud

`~/homelab/etc/fail2ban/filter.d/nextcloud.local`:

```ini
# Fail2ban filter — Nextcloud
#
# Caza intentos de login fallido en el log JSON de Nextcloud
# (data/nextcloud.log). Nextcloud >=20 emite líneas tipo:
#   {"reqId":"...","level":2,"app":"core","method":"POST","url":"/login",
#    "message":"Login failed: 'admin' (Remote IP: '1.2.3.4')",...}

[INCLUDES]
before = common.conf

[Definition]
_daemon = nextcloud

failregex = ^\{.*"remoteAddr":"<HOST>".*"message":"Login failed:.*$
            ^\{.*"message":"Login failed:.*\(Remote IP: ['\"]<HOST>['\"]\).*$
            ^\{.*"remoteAddr":"<HOST>".*"message":"Trusted domain error.*$

ignoreregex =

datepattern = ^\{.*"time":"%%Y-%%m-%%dT%%H:%%M:%%S(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})"
```

`~/homelab/etc/fail2ban/jail.d/30-nextcloud.conf`:

```ini
# Fail2ban jail — Nextcloud (PREPARADO, NO ACTIVADO).
#
# Activar tras desplegar Nextcloud según
# docs/06-almacenamiento/01-nextcloud.md cambiando enabled=true.

[nextcloud]
enabled  = false
filter   = nextcloud
logpath  = /mnt/hd2t/services/cloud/nextcloud/data/nextcloud.log
backend  = polling

findtime = 10m
maxretry = 5
```

### 6.2. Vaultwarden

`~/homelab/etc/fail2ban/filter.d/vaultwarden.local`:

```ini
# Fail2ban filter — Vaultwarden
#
# Vaultwarden emite logs de fallo de login con la IP en el mensaje:
#   [2025-01-01 12:00:00.000][error][vaultwarden::api::identity]
#       Username or password is incorrect. Try again. IP: 192.168.1.99. Username: admin@example.com.
#
# Si Vaultwarden corre con admin token, también:
#   [...][error][vaultwarden::api::admin] Invalid admin token. IP: 192.168.1.99.

[INCLUDES]
before = common.conf

[Definition]
_daemon = vaultwarden

failregex = ^.*Username or password is incorrect\. Try again\. IP: <HOST>(\.|,| ).*$
            ^.*Invalid admin token\. IP: <HOST>(\.|,| ).*$
            ^.*Authentication failure with provided login token\. IP: <HOST>.*$

ignoreregex =

datepattern = ^\[%%Y-%%m-%%d %%H:%%M:%%S(?:\.\d+)?\]
```

`~/homelab/etc/fail2ban/jail.d/40-vaultwarden.conf`:

```ini
# Fail2ban jail — Vaultwarden (PREPARADO, NO ACTIVADO).
#
# Activar tras desplegar Vaultwarden según
# docs/11-productividad/01-vaultwarden.md cambiando enabled=true.

[vaultwarden]
enabled  = false
filter   = vaultwarden
# Vaultwarden escribe a stdout por defecto; al desplegarlo se le configura
# LOG_FILE=/data/vaultwarden.log para que este logpath apunte al fichero.
logpath  = /mnt/hd2t/services/vault/data/vaultwarden.log
backend  = polling

findtime = 10m
maxretry = 5
```

> **Razón del prefijo `LOG_FILE`**: Vaultwarden, como Authelia, escribe por defecto a stdout. La integración con Fail2ban exige un fichero plano. El doc de Vaultwarden añadirá `LOG_FILE=/data/vaultwarden.log` (variable de entorno oficial) en su `.env` y declarará el path equivalente en el host. Aquí queda anotado para que ese doc sepa qué ruta esperar.

### 6.3. Aplicar (sin activar)

```bash
sudo install -m 644 -o root -g root \
    ~/homelab/etc/fail2ban/filter.d/nextcloud.local \
    /etc/fail2ban/filter.d/nextcloud.local

sudo install -m 644 -o root -g root \
    ~/homelab/etc/fail2ban/filter.d/vaultwarden.local \
    /etc/fail2ban/filter.d/vaultwarden.local

sudo install -m 644 -o root -g root \
    ~/homelab/etc/fail2ban/jail.d/30-nextcloud.conf \
    /etc/fail2ban/jail.d/30-nextcloud.conf

sudo install -m 644 -o root -g root \
    ~/homelab/etc/fail2ban/jail.d/40-vaultwarden.conf \
    /etc/fail2ban/jail.d/40-vaultwarden.conf

sudo fail2ban-client reload
sudo fail2ban-client status
# Esperado: Number of jail = 3   (sshd, authelia, caddy-status)
# Los jails nextcloud y vaultwarden NO aparecen porque enabled=false.
```

---

## 7. Verificación

### 7.1. Servicio sano

```bash
sudo systemctl status fail2ban --no-pager
sudo fail2ban-client ping
# Esperado: Server replied: pong

sudo fail2ban-client status
# Esperado:
# Status
# |- Number of jail:      3
# `- Jail list:   sshd, authelia, caddy-status
```

### 7.2. Jail Authelia funciona

Desde un equipo **fuera de `ignoreip`** (un nodo Tailscale, por ejemplo), pulsar 4 veces "Sign in" en `https://auth.lan` con password incorrecto:

```bash
sudo fail2ban-client status authelia
# Currently failed: > 0 mientras se hacen los intentos
# Currently banned: 1 tras el 3.º fallo
# Banned IP list:   <IP del equipo de pruebas>

sudo nft list set inet f2b-authelia addr-set 2>/dev/null
# Esperado: la IP en el set

# Desde el equipo baneado:
ssh -o ConnectTimeout=3 homelab@<pi-ip>
# Esperado: timeout (la IP está dropeada para todos los puertos).
```

Tras la prueba, desbanear:

```bash
sudo fail2ban-client unban <IP>
```

### 7.3. Jail Caddy funciona

```bash
# Desde un nodo de pruebas (fuera de ignoreip):
for i in $(seq 1 21); do
    curl -sk -o /dev/null https://pihole.lan/scanner-$i.php
done

sudo fail2ban-client status caddy-status
# Currently banned: 1
```

### 7.4. Hosts `auth.lan` no se banean por 401

```bash
# Generar 30 fallos contra auth.lan:
for i in $(seq 1 30); do
    curl -sk -o /dev/null -X POST https://auth.lan/api/firstfactor \
        -H 'Content-Type: application/json' \
        -d '{"username":"x","password":"x"}'
done

sudo fail2ban-client status caddy-status
# Currently failed: 0   (auth.lan está excluido por el ignoreregex)
sudo fail2ban-client status authelia
# Currently failed: > 0 (Authelia sí cuenta sus fallos, banea a los 3)
```

### 7.5. Persistencia tras reboot

```bash
sudo systemctl reboot
# Tras el reboot:
sudo fail2ban-client status
# Esperado: 3 jails activos.
sudo fail2ban-client status authelia | grep -i banned
# Si había bans en curso, deben seguir (sqlite3 en /var/lib/fail2ban/).
```

### 7.6. Lista de Verificación

Antes de pasar a la siguiente fase:

- [ ] `sudo fail2ban-client ping` responde `pong`.
- [ ] `sudo fail2ban-client status` lista los jails `sshd`, `authelia`, `caddy-status`.
- [ ] `sudo fail2ban-client status authelia` lista `File list: /mnt/hd2t/services/auth/authelia/config/authelia.log` y `Currently failed: 0`.
- [ ] `sudo fail2ban-client status caddy-status` lista `File list: /mnt/hd2t/services/proxy/logs/access.log` y `Currently failed: 0`.
- [ ] `sudo fail2ban-regex /mnt/hd2t/services/auth/authelia/config/authelia.log /etc/fail2ban/filter.d/authelia.local` muestra al menos un *match* (tras provocar 1 login fallido).
- [ ] `sudo fail2ban-regex /mnt/hd2t/services/proxy/logs/access.log /etc/fail2ban/filter.d/caddy-status.local` no marca como *match* las líneas con `"host":"auth.lan"`.
- [ ] Una IP de pruebas (fuera de `ignoreip`) generando 3 fallos en `auth.lan` aparece en `sudo nft list set inet f2b-authelia addr-set`.
- [ ] La misma IP, baneada, no puede `ssh` a la Pi (la regla `nftables-allports` aísla todos los puertos).
- [ ] `sudo fail2ban-client unban <ip>` la libera y desaparece del set de nftables.
- [ ] `ls /etc/fail2ban/jail.d/` lista `10-authelia.conf`, `20-caddy-status.conf`, `30-nextcloud.conf`, `40-vaultwarden.conf`.
- [ ] `grep enabled /etc/fail2ban/jail.d/30-nextcloud.conf` y `40-vaultwarden.conf` muestran `enabled = false`.
- [ ] Tras un `sudo systemctl reboot`, `fail2ban-client status` lista los 3 jails activos.

---

## 8. Backup

| Ruta | Contenido | Reconstruible | ¿Backup? |
|---|---|---|---|
| `~/homelab/etc/fail2ban/` | Filtros y jails versionables | Sí (en git) | Cubierto por backup del repo. |
| `/etc/fail2ban/jail.local` | Defaults + jail SSH (Fase 1) | Sí (regenerable desde el doc) | Sí, en `borgmatic` ([`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md)) bajo `/etc`. |
| `/etc/fail2ban/jail.d/*.conf` | Drop-ins instalados desde el repo | Sí | Sí, en `borgmatic` bajo `/etc`. |
| `/etc/fail2ban/filter.d/*.local` | Filtros instalados desde el repo | Sí | Sí, en `borgmatic` bajo `/etc`. |
| `/var/lib/fail2ban/fail2ban.sqlite3` | Estado de bans en curso | **Reconstruible**: si se pierde, los atacantes activos vuelven a fallar y se baneen de nuevo. | Opcional. No crítico. |

`borgmatic` ya respalda `/etc` (ver [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) cuando esté), así que los ficheros instalados están cubiertos. Los del repo se cubren con el remoto git/MinIO.

---

## 9. Operaciones cotidianas

### 9.1. Listar IPs baneadas en un jail

```bash
sudo fail2ban-client status authelia
sudo fail2ban-client status caddy-status

# Con detalle de tiempos:
sudo fail2ban-client get authelia banip --with-time
```

### 9.2. Desbanear una IP

```bash
sudo fail2ban-client unban 192.168.1.99
# Todas las jails:
sudo fail2ban-client unban --all
```

### 9.3. Probar un filtro contra el log real

```bash
# Match count:
sudo fail2ban-regex \
    /mnt/hd2t/services/auth/authelia/config/authelia.log \
    /etc/fail2ban/filter.d/authelia.local

# Con verbosidad para depurar regex:
sudo fail2ban-regex --print-all-matched \
    /mnt/hd2t/services/auth/authelia/config/authelia.log \
    /etc/fail2ban/filter.d/authelia.local | head -50
```

### 9.4. Activar/desactivar un jail temporalmente

```bash
# Sin tocar fichero — sólo runtime, se pierde tras reboot:
sudo fail2ban-client stop authelia
sudo fail2ban-client start authelia

# Persistente: editar /etc/fail2ban/jail.d/<name>.conf, cambiar enabled,
# y recargar:
sudo fail2ban-client reload
```

### 9.5. Inspeccionar nftables

Las reglas de Fail2ban viven en tablas con prefijo `f2b-`:

```bash
sudo nft list tables | grep f2b
# Esperado:
# table inet f2b-sshd
# table inet f2b-authelia
# table inet f2b-caddy-status

# Set de IPs baneadas:
sudo nft list set inet f2b-authelia addr-set
```

### 9.6. Rotación de los logs leídos por Fail2ban

Authelia no rota `authelia.log`. Sin rotación, el fichero crece indefinidamente y `fail2ban-regex` se vuelve lento. Configurar `logrotate`:

```bash
sudo tee /etc/logrotate.d/authelia >/dev/null <<'EOF'
/mnt/hd2t/services/auth/authelia/config/authelia.log {
    weekly
    rotate 8
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF
```

`copytruncate` evita reiniciar Authelia (haría falta `kill -USR1` y Authelia 4.38 no responde a esa señal). El log de Caddy ya rota por sí mismo (`roll_size 10MiB roll_keep 5`, [`../03-red/04-caddy.md`](../03-red/04-caddy.md) §4.3); no requiere `logrotate`.

### 9.7. Añadir un jail nuevo (plantilla)

Para un servicio nuevo X que escribe logs en `/mnt/hd2t/services/.../X.log`:

1. Crear `~/homelab/etc/fail2ban/filter.d/X.local` con `failregex` que usen `<HOST>`.
2. Crear `~/homelab/etc/fail2ban/jail.d/NN-X.conf` con `enabled=false` mientras se prueba.
3. `sudo install ...` ambos a `/etc/fail2ban/`.
4. `sudo fail2ban-regex <log> /etc/fail2ban/filter.d/X.local` hasta que case.
5. Cambiar `enabled = true` y `sudo fail2ban-client reload`.
6. Probar provocando fallos desde un equipo fuera de `ignoreip`.

---

## 10. Solución de Problemas

| Síntoma | Causa probable | Acción |
|---|---|---|
| `fail2ban-client status authelia` da `Sorry but the jail 'authelia' does not exist` | El drop-in no se ha cargado: typo en el nombre `[authelia]`, fichero no copiado a `/etc/fail2ban/jail.d/`, o sintaxis errónea que aborta el parser. | `sudo fail2ban-client reload` y `sudo journalctl -u fail2ban -n 100`. Verificar `ls /etc/fail2ban/jail.d/` y `sudo fail2ban-client -t` (test). |
| Tras `reload`, todos los jails desaparecen | Error de sintaxis en uno de los drop-ins detiene la carga global. | `sudo fail2ban-client -t` muestra la línea con el error. Corregir y recargar. |
| `fail2ban-regex <log> <filter>` devuelve `0 matches` aunque el log tiene entradas que parecen casar | El `datepattern` no encaja con el formato real del log → Fail2ban descarta las líneas como "fuera de ventana". | Probar sin `datepattern` (comentar la línea); si entonces sí casa, ajustar el patrón. Para Authelia, comprobar que la línea empieza por `time="..."` (no por un prefijo de Docker). |
| `caddy-status` cuenta como fallos las peticiones a `auth.lan` | `ignoreregex` no se aplica (regex mal escrito) o `failregex` casa antes que el `ignoreregex` se evalúe. | Probar con `fail2ban-regex --print-all-matched`. Reforzar `failregex` añadiendo `(?!auth\.)` directamente. |
| Una IP de la LAN se banea por error | Generó >maxretry fallos en `findtime` y **no** está en `ignoreip` (subred mal configurada en Fase 1). | `sudo fail2ban-client unban <ip>`. Verificar `grep ignoreip /etc/fail2ban/jail.local`; añadir la subred correcta y `reload`. |
| El operador desde Tailscale se banea | Tailscale no está en `ignoreip` (decisión consciente, ver §0). | `sudo fail2ban-client unban <ip>`. Si pasa repetidamente, añadir la IP `100.64.x.y/32` del nodo de trabajo a un drop-in propio; **no** ampliar a `100.64.0.0/10`. |
| `nft list set inet f2b-authelia addr-set` devuelve `Error: No such file or directory` | El jail está vacío (sin bans aún) y la tabla `f2b-authelia` se crea perezosa al primer ban. | Esperar a que haya un ban; o forzar uno: `sudo fail2ban-client set authelia banip 203.0.113.99`. |
| Tras un upgrade del paquete `fail2ban`, los filtros del operador desaparecen | El paquete sólo respeta los `*.local`. Un `*.conf` en `filter.d/` se sobrescribe. | Renombrar el filtro propio a `<name>.local`; recargar. |
| `journalctl -u fail2ban` repite `Failed during configuration: ... [authelia] no such filter` | El filtro `authelia.local` no se copió a `/etc/fail2ban/filter.d/`, o tiene typo en el nombre. | `ls /etc/fail2ban/filter.d/authelia*`; reaplicar el `install`. |
| `fail2ban-regex` muestra muchos matches pero `Currently failed: 0` en runtime | El log se está leyendo con `backend = systemd` (heredado del DEFAULT) cuando debería ser `polling`. | Verificar que el drop-in declara `backend = polling` en cada jail nuevo. |
| Caddy escribe líneas que no son JSON (acceso directo durante errores muy graves) | Caddy usa `format console` para errores de bootstrap; `format json` sólo aplica al logger nombrado `default`. | Es esperado. El filtro JSON no casa esas líneas (no contienen `client_ip`); no bloquean Fail2ban. |
| `enabled=true` accidental en `nextcloud.conf` antes de tener Nextcloud | Fail2ban intenta abrir `/mnt/hd2t/services/cloud/nextcloud/data/nextcloud.log` y falla; el jail entra en `failed`. | `enabled=false`, `reload`. |

---

## Referencias

- [Fail2ban — Wiki: HOWTO Use Fail2ban](https://github.com/fail2ban/fail2ban/wiki)
- [Fail2ban — Manual: jail.conf options](https://github.com/fail2ban/fail2ban/blob/master/man/jail.conf.5)
- [Fail2ban — Manual: filter.conf options](https://github.com/fail2ban/fail2ban/blob/master/man/jail.conf.5)
- [Fail2ban — `nftables-allports` action](https://github.com/fail2ban/fail2ban/blob/master/config/action.d/nftables-allports.conf)
- [Authelia — Integration: Fail2ban](https://www.authelia.com/integration/fail2ban/)
- [Authelia — Logging configuration (`log.file_path`, `log.keep_stdout`)](https://www.authelia.com/configuration/miscellaneous/logging/)
- [Caddy — Log encoding (`format json`)](https://caddyserver.com/docs/caddyfile/directives/log#encoder)
- [Nextcloud — Brute-force protection and `nextcloud.log` format](https://docs.nextcloud.com/server/latest/admin_manual/configuration_server/logging_configuration.html)
- [Vaultwarden — Logging configuration (`LOG_FILE`)](https://github.com/dani-garcia/vaultwarden/wiki/Logging)
- [Debian — `nftables` y Fail2ban en Bookworm](https://wiki.debian.org/nftables)
