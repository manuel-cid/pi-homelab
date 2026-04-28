# Samba

## Descripción

Despliegue de **Samba** como servidor de **ficheros en red local** para el homelab: el operador (y, opcionalmente, otros usuarios de la familia) accede a las bibliotecas de `hd2t` y `hd5t` desde Windows, macOS y Linux con el protocolo **SMB3** sin tener que pasar por la UI web de Nextcloud. Es la vía rápida para volcar carpetas grandes (películas, ISOs, fotos del móvil que NO se quieren sincronizar continuamente), recuperar un fichero suelto de `media/`, o inspeccionar `downloads/` desde el portátil sin abrir un terminal.

> **Alcance**: este servicio es **estrictamente LAN**. Los puertos SMB (137/138/139/445) **nunca** se abren al exterior, no salen por Caddy ni por Tailscale (Tailscale puede transportarlos, pero los clientes nativos de SMB sobre Tailscale tienen un soporte irregular y se documenta como variante opt-in en §14.1). El acceso fuera de casa para ficheros se cubre con Nextcloud ([`./01-nextcloud.md`](./01-nextcloud.md)) y, en menor medida, Syncthing ([`./03-syncthing.md`](./03-syncthing.md)).

El stack `samba` ([`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §1.1) contiene **un único contenedor**:

- **`samba`** — la imagen `dockurr/samba` (rama Samba 4.21+). Corre en **`network_mode: host`** porque el descubrimiento NetBIOS (UDP 137/138) y, sobre todo, los clientes Windows que usan `\\nombre-pi\carpeta`, dependen de que el servicio escuche en la interfaz real `eth0` con la IP que tiene la Pi en la LAN. Entrar por bridge con `ports: "445:445"` funciona para SMB puro contra IP, pero rompe el descubrimiento de red (Windows / macOS Finder no listan la Pi en "Red") y obliga a configurar el cliente con la IP a mano.

Por qué exactamente esta arquitectura, y no otra:

1. **Un servicio dedicado, no SMB en el host con `apt install samba`.** Mantener Samba como contenedor uniforma operación: la configuración (`smb.conf`, `users.conf`) vive bajo `/mnt/hd2t/services/samba/` con el resto del homelab, los logs son `docker logs samba`, los upgrades los gestiona Watchtower, y el backup lo cubre Borg con la misma política que cualquier otro servicio. Un `samba.service` del paquete sería igual de funcional pero quedaría fuera de la disciplina "todo en Docker, todo bajo `/mnt/hd2t/services/<svc>/`".
2. **Imagen `dockurr/samba`.** Multi-arch (incluye `linux/arm64`), Samba upstream sin parches (4.21.x), entrypoint claro que respeta dos hooks documentados: `smb.conf` mountable en `/etc/samba/smb.conf` y `users.conf` mountable en `/etc/samba/users.conf` con líneas `usuario:password` para crear cuentas SMB con `smbpasswd`. Mantenido activamente. Alternativas evaluadas: `dperson/samba` (configuración por flags en la línea de comandos — los passwords quedarían visibles en `docker inspect`), `crazymax/samba` (configuración YAML elegante pero exige aprender un esquema propio para cada share), `ghcr.io/servercontainers/samba` (env vars `ACCOUNT_<user>`, no soporta el sufijo `_FILE` para secretos). `dockurr/samba` con `users.conf` montado como secret es la combinación más simple que mantiene los passwords fuera de `docker inspect` y permite editar `smb.conf` con un editor normal.
3. **`network_mode: host`, no `bridge` ni `macvlan`.** Tres razones acumuladas:
   - **NetBIOS broadcast** (UDP 137/138) requiere ver la red L2 real. Bridge la oculta tras NAT; los clientes Windows dejan de ver la Pi en "Red" y los clientes macOS dejan de listarla en Finder → "Red".
   - **No hay nada en el host que escuche en 137/138/139/445.** El homelab no tiene un Samba del paquete activo (Fase 1 instala `fail2ban` y poco más), así que ocupar esos cuatro puertos del host no genera colisiones.
   - **`macvlan` también funcionaría** (igual que para Pi-hole, ver [`../03-red/01-macvlan.md`](../03-red/01-macvlan.md)) y daría a Samba una IP dedicada en la LAN, pero introduce la limitación clásica de macvlan: el host no puede hablar con el contenedor sin un "macvlan-shim" (lo cubre el doc de macvlan). Como el operador rara vez monta `\\pi\homelab` desde la propia Pi, la complejidad de macvlan no se paga aquí. Se mantiene como variante opt-in en §14.2.
4. **Tres shares por defecto: `homelab`, `media`, `downloads`.** Cobertura mínima para los flujos cotidianos:
   - **`homelab`** — espacio personal del operador. RW. Su contenido vive en `/mnt/hd2t/shares/homelab/` (carpeta nueva, creada en este doc — no se reaprovecha `services/`, que mezcla configs y volúmenes con permisos heterogéneos).
   - **`media`** — biblioteca multimedia común (`/mnt/hd2t/media/{movies,tv,music,...}`, creada en [`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) §6). RO para usuarios "consumidor", RW para `homelab`. Permite subir capítulos sueltos a la TV / portátil sin levantar Sonarr.
   - **`downloads`** — directorio de Transmission (`/mnt/hd2t/downloads/`). RW para `homelab`, expuesto por comodidad: facilita inspeccionar torrents en curso y rescatar manualmente lo que Sonarr/Radarr no consigan emparejar.
   La biblioteca de **Stash** (`/mnt/hd5t/stash/library/`) **no** se expone por defecto: se documenta como share opt-in `[stash]` en §14.3, RO, sólo para el usuario `homelab`.
5. **Un único usuario "humano" por defecto: `homelab`.** Mismo nombre que el usuario del SO (UID 1000) para no crear discrepancias mentales, **pero** el password SMB es **independiente** del password Linux: Samba mantiene su propia base de datos (`tdbsam`) en `/var/lib/samba/private/`. Cambiar el password SSH no afecta al de Samba y viceversa. Se documenta cómo añadir un usuario `family` (RO en `media`) en §12.4.
6. **SMB1 deshabilitado por completo** (`server min protocol = SMB2_10`, `client min protocol = SMB2_10`). SMB1 es la versión que hizo posible WannaCry y NotPetya: queda `disabled` en Windows 10/11 y macOS 11+ por defecto. No tiene sentido mantenerlo.
7. **Cifrado SMB3 obligatorio** (`server smb encrypt = required`). En LAN cableada el riesgo de sniffing es bajo, pero la pérdida de WiFi (un invitado curioso, una IoT comprometida) lo eleva. SMB3 cifra con AES-128-GCM por defecto en negociación con Windows 10 1809+, macOS 11+ y `smbclient` ≥ 4.11; la diferencia de CPU en la Pi 5 es despreciable (<2% extra a 100 MB/s).
8. **Acceso restringido a la LAN** (`hosts allow = 192.168.1.0/24 127.0.0.1`, `hosts deny = 0.0.0.0/0`). Defensa en profundidad: aunque el firewall del host (`ufw`, ver [`../01-sistema/03-seguridad-base.md`](../01-sistema/03-seguridad-base.md) §4) ya recortará el acceso a 192.168.1.0/24, la directiva `hosts allow` lo aplica también dentro de Samba. Si el operador accede vía Tailscale (variante §14.1), añade el rango `100.64.0.0/10`.
9. **Sin guest (`map to guest = never`, `guest ok = no`)**. El homelab no tiene escenario "abrir un quiosco para invitados sin password". Cualquiera que necesite acceso recibe un usuario SMB con su propio password — siempre.
10. **Fail2ban con jail `samba` listo desde [`../04-seguridad/02-fail2ban.md`](../04-seguridad/02-fail2ban.md)**. Aún se entrega `enabled = false` en ese doc (igual que Nextcloud y Vaultwarden), porque hasta que este servicio no está corriendo, los logs `/var/log/samba/log.smbd` no existen y el jail entraría en `failed`. Aquí se documenta el paso final: copiar el log a `/mnt/hd2t/services/samba/logs/`, crear el filtro `filter.d/samba.local` y activar el jail.

> **Alcance de red**: Samba no se publica en Caddy ni se proxia a través de Tailscale por defecto. Se accede únicamente con clientes SMB nativos desde la LAN (Windows Explorer, macOS Finder, GNOME Files, `smbclient`, `cifs-utils`/`mount.cifs`) hablando con el host por su IP `192.168.1.10` o por el nombre NetBIOS (`PI`, según `netbios name` configurado).

---

## Requisitos Previos

- **Docker Engine + Compose v2** instalados según [`../02-docker/01-instalacion-docker.md`](../02-docker/01-instalacion-docker.md).
- **Estructura de directorios** aplicada según [`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md):
  - `/mnt/hd2t/services/samba/` ya creado por el bootstrap (paso §6.2 del doc), propietario `homelab:homelab`, modo `750`.
  - `/mnt/hd2t/media/{movies,tv,music,audiobooks,podcasts,books}/` con `homelab:media 2775`.
  - `/mnt/hd2t/downloads/{incomplete,complete,watch}/` con `homelab:media 2775`.
- **Usuario `homelab` (UID 1000) y grupo `media` (GID 1100)** ya creados según [`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) §3 y §4.
- **`ufw` activo** según [`../01-sistema/03-seguridad-base.md`](../01-sistema/03-seguridad-base.md) §4. Aún sin reglas para SMB; se añaden en §8.
- **Fail2ban operativo** según [`../04-seguridad/02-fail2ban.md`](../04-seguridad/02-fail2ban.md), con el jail `sshd` activo. Aquí se preparará el jail `samba`.
- **Pi-hole desplegado** según [`../03-red/02-pihole.md`](../03-red/02-pihole.md). Opcional pero recomendado: añadir un registro DNS local `pi.lan → 192.168.1.10` para que los clientes puedan referirse al host por nombre.
- **Tailscale**: explícitamente **no** es prerequisito — Samba opera fuera de la VPN por defecto.
- **Comprobaciones rápidas**:
  ```bash
  # Directorios existen y con dueño correcto:
  ls -ld /mnt/hd2t/services/samba /mnt/hd2t/media /mnt/hd2t/downloads
  # Esperado: homelab:homelab 750 (samba), homelab:media 2775 (media, downloads).

  # El usuario homelab está en grupo media:
  id homelab | tr ',' '\n' | grep media
  # Esperado: una línea con (1100(media)) — si no, ver 04-estructura-directorios §4.

  # Puertos SMB libres en el host:
  sudo ss -lntu '( sport = :137 or sport = :138 or sport = :139 or sport = :445 )'
  # Esperado: vacío. Si hay algo escuchando, identificar y parar
  # (sudo systemctl stop smbd nmbd samba-ad-dc 2>/dev/null) antes de seguir.

  # IP del host en la LAN (la usarán los clientes):
  ip -4 addr show eth0 | awk '/inet / {print $2}'
  # Esperado: 192.168.1.10/24 (o la asignada estática a la Pi).
  ```

### Decisiones de diseño asumidas

| Decisión | Valor por defecto | Justificación |
|---|---|---|
| Imagen Docker | **`dockurr/samba`** (rama Samba 4.21+) | Multi-arch (`linux/arm64`), Samba upstream sin parches, hooks documentados para `smb.conf` y `users.conf`. Justificado en §0 punto 2. |
| Tag de imagen | **Pinned a release puntual**, nunca `latest` | Misma regla de [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §6.1. Watchtower sí actualiza al ver una nueva minor; el upgrade de Samba 4.x a 4.x+1 es retro-compatible para protocolo y formato `tdbsam` (`/var/lib/samba/private/passdb.tdb`). |
| Política de Watchtower | **`watchtower.enable: "true"`** | Coherente con [`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §4.2 (Samba listada en "Servicios incluidos"). Las imágenes de Samba 4.x son retrocompatibles dentro de la rama; un upgrade silencioso a las 04:00 sólo reinicia el demonio y los clientes reconectan automáticamente al volver a montar la carpeta. |
| Modo de red | **`network_mode: host`** | Justificado en §0 punto 3. NetBIOS broadcast + descubrimiento de red. |
| Subnet declarada en el contenedor | N/A (host) | No hay red Docker propia. Si en el futuro se cambia a `macvlan` (variante §14.2), se documenta allí. |
| `ports:` publicados | **No aplica** (host network) | Los puertos `137/udp`, `138/udp`, `139/tcp`, `445/tcp` quedan ocupados directamente en `eth0` del host. |
| Listening interfaces | **`interfaces = lo eth0`** + **`bind interfaces only = yes`** | Si la Pi adquiere otra interfaz (Tailscale, una segunda NIC USB, una tarjeta WiFi de respaldo), Samba **no** escucha allí salvo que se añada explícitamente. Reduce la superficie de ataque y evita que un escaneo desde Tailscale alcance los puertos SMB sin que esté contemplado. |
| Workgroup / NetBIOS name | **`WORKGROUP`** / **`PI`** | `WORKGROUP` es el default histórico de Windows; mantenerlo evita que la Pi quede oculta para cualquier cliente con dominio Windows distinto al estándar. `PI` corto y legible — los clientes verán `\\PI\homelab`. Configurable vía `.env`. |
| Versión mínima de protocolo | **`server min protocol = SMB2_10`** + **`client min protocol = SMB2_10`** | SMB1 deshabilitado. SMB2_10 es la versión Windows 7 / Server 2008 R2; Windows 7 ya fuera de soporte → en la práctica sólo se conecta SMB3 (Win 8/10/11, macOS 11+, Linux ≥ 2014). Si algún cliente raro queda fuera, baja a `SMB2_02` puntual y documenta. |
| Cifrado | **`server smb encrypt = required`** | Justificado en §0 punto 7. Negativa explícita a SMB sin cifrar. |
| Firma | **`server signing = mandatory`** | Defensa contra man-in-the-middle en LAN. Coste despreciable. |
| Autenticación | **`security = user`** + **`map to guest = never`** | El servidor exige usuario+password siempre. Sin guests. |
| Backend de usuarios | **`passdb backend = tdbsam`** (default) | Un fichero `passdb.tdb` simple en `/var/lib/samba/private/`. El homelab no tiene Active Directory ni LDAP. |
| Persistencia de usuarios SMB | **`tdbsam` montado en `/mnt/hd2t/services/samba/private/`** | `passdb.tdb` contiene los hashes de los usuarios SMB. Al persistirse en bind mount, sobrevive a recreaciones del contenedor sin tener que reaplicar `users.conf`. Backup obligatorio (§11). |
| Usuarios SMB | **Solo `homelab`** por defecto | Mínimo viable. Añadir `family`, `invitado`, etc. → §12.4. |
| Mapeo de UID/GID | Todos los procesos SMB corren como `nobody:nogroup` (default) y leen/escriben con `force user = homelab` y `force group = homelab` (o `media` por share) | Independencia entre la cuenta SMB y el UID Linux: `homelab` SMB siempre escribe como UID 1000 en disco (homelab Linux), independientemente de cómo se llamase la cuenta SMB. Para el share `media`, `force group = media` asegura que los ficheros nuevos hereden GID 1100 (visibles para Sonarr/Radarr/Jellyfin sin retoques de permisos). |
| Shares por defecto | **`[homelab]` (RW), `[media]` (RO general / RW homelab), `[downloads]` (RW homelab)** | Justificado en §0 punto 4. |
| Acceso a `[media]` para usuario `homelab` | **`writable = yes`** vía `read list`/`write list` invertido | Jellyfin, Sonarr, Radarr son los **dueños** de `media/`; el operador escribe ahí raras veces. La opción `read list` global + `write list = homelab` evita que un futuro usuario `family` borre por accidente. |
| `hosts allow / deny` | **`hosts allow = 192.168.1.0/24 127.0.0.1`** + **`hosts deny = 0.0.0.0/0`** | Doble barrera con `ufw`. La directiva `hosts allow` es a nivel Samba, *adicional* al firewall. |
| Logging | **`logging = file`** + **`log file = /var/log/samba/log.%m`** + **`max log size = 1000`** (KB) + **`log level = 1 auth_audit:3`** | `log.%m` separa el log por máquina cliente (útil para troubleshoot). `auth_audit:3` registra cada intento de login y resultado, con formato parseable por Fail2ban (§4.3 fail2ban). Resto de subsystems en nivel 1 (sólo errores y avisos): la verbosidad alta llena disco y ralentiza I/O. |
| Volcado de logs al host | **Bind mount** `/mnt/hd2t/services/samba/logs/` ← `/var/log/samba/` | Permite que Fail2ban (en host) los lea con `tail -F`. Sin esto los logs viven dentro del contenedor y son inaccesibles para el demonio Fail2ban del host. |
| Usuario del contenedor | **`root`** dentro del contenedor | `smbd` y `nmbd` arrancan como root para hacer `bind` en puertos privilegiados (139/445) y luego cada conexión se autentica y aplica `force user`. Misma postura que un Samba "tradicional" en un servidor Linux. La defensa real está en `cap_drop`/`security_opt`. |
| `cap_drop: ALL` + `cap_add` | **`cap_add: [NET_BIND_SERVICE, SETUID, SETGID, CHOWN, FOWNER, DAC_OVERRIDE, DAC_READ_SEARCH, SYS_CHROOT]`** | El mínimo set para `smbd` + `nmbd` con todos los features esperados. `SYS_CHROOT` lo necesita `smbd` para implementar el `chroot` por share; sin él, fallan los `wide links` y el aislamiento del share. |
| `security_opt: no-new-privileges:true` | **Activado** | Plantilla §6 de [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md). |
| `read_only: true` | **`false`** | `smbd` escribe en `/var/lib/samba/{lock,cache}/` y en `/var/log/samba/`. Forzar RO obligaría a tmpfs masivo y rompe operaciones legítimas (locks, etc.). El bind mount de `private/` y `logs/` ya cubre lo que importa para persistencia. |
| Persistencia (private DB) | Bind mount `/var/lib/samba/private` ← `/mnt/hd2t/services/samba/private/` | `passdb.tdb`, `secrets.tdb`. Backup crítico (§11). |
| Persistencia (config) | Bind mount `/etc/samba` ← `/mnt/hd2t/services/samba/config/` | `smb.conf` y `users.conf` (este último con permisos `600`). |
| Persistencia (logs) | Bind mount `/var/log/samba` ← `/mnt/hd2t/services/samba/logs/` | Para que Fail2ban del host los lea. Rotación: confiar en `max log size = 1000` (Samba rota internamente). |
| Healthcheck | **`smbclient -N -L localhost`** | Lista los shares anonymously; si responde sin error, el demonio está vivo. Aceptable porque "anonymous list" no expone nada útil — los shares siguen exigiendo credenciales para mount. |
| Logs Docker | **`json-file` 10 MB × 3** (heredado del demonio) | Los logs detallados de SMB van a `logs/` (bind mount). El stdout del contenedor (entrypoint, errores fatales) cabe sobrado. |

---

## 1. Resumen de la arquitectura

```
                      ┌──────────────────── LAN 192.168.1.0/24 ────────────────────┐
                      │                                                             │
   PC Windows  ───────┤  \\PI\homelab           SMB3 over TCP/445, AES-128-GCM     │
   Mac Finder  ───────┤  smb://pi.lan/media     NetBIOS over UDP/137,138 (descubr) │
   Linux mount.cifs   │  smb://192.168.1.10/    NetBIOS over TCP/139 (legacy)      │
                      │                                                             │
                      └────────────────────────────────┬────────────────────────────┘
                                                       │
                       eth0 192.168.1.10 (Pi 5)        │
                                                       ▼
                      ┌──────────────────────────────────────────────────────────────┐
                      │  ufw allow 137,138/udp, 139,445/tcp from 192.168.1.0/24      │
                      │                                                              │
                      │      ┌──── samba (network_mode: host, root) ─────────┐      │
                      │      │  smbd  (TCP 139, 445)                          │      │
                      │      │  nmbd  (UDP 137, 138)                          │      │
                      │      │                                                │      │
                      │      │  /etc/samba/smb.conf      (config + 3 shares) │      │
                      │      │  /etc/samba/users.conf    (homelab:<pass>)    │      │
                      │      │  /var/lib/samba/private/  (passdb.tdb)        │      │
                      │      │  /var/log/samba/          (log.%m → fail2ban) │      │
                      │      │                                                │      │
                      │      │  shares:                                       │      │
                      │      │   [homelab]    /mnt/hd2t/shares/homelab/   RW │      │
                      │      │   [media]      /mnt/hd2t/media/            RW│      │
                      │      │                                            (homelab)│
                      │      │                                            RO  │
                      │      │                                            (otros)│
                      │      │   [downloads]  /mnt/hd2t/downloads/        RW │      │
                      │      └────────────────────────────────────────────────┘      │
                      │                                                              │
                      │  fail2ban (host) → tail -F /mnt/hd2t/services/samba/logs/   │
                      │                       log.smbd → ban nftables 137-445       │
                      └──────────────────────────────────────────────────────────────┘
```

Tres invariantes:

- **Samba sólo escucha en `lo` y `eth0`.** `bind interfaces only = yes` lo restringe; aunque alguien añada Tailscale o una segunda NIC, esos puertos no aparecen ahí salvo que se añada la interfaz explícitamente.
- **Cifrado SMB3 obligatorio.** Cualquier cliente que no negocie SMB2_10+ con `smb encrypt = required` recibe `NT_STATUS_ACCESS_DENIED`. Adiós a sniffing de credenciales.
- **Cuenta SMB ≠ cuenta Linux.** El password SMB del usuario `homelab` se gestiona en `passdb.tdb`. Cambiar el password Linux (con `passwd`) no afecta a la conexión SMB y viceversa. Documentado en §12.

Flujo de un mount típico (caso "Windows 11 monta `\\PI\homelab`"):

```
1. Cliente: NetBIOS Name Query Broadcast UDP 137 ─► resuelve PI = 192.168.1.10.
2. Cliente: TCP SYN → 192.168.1.10:445.
3. ufw ACCEPT (regla LAN); host enruta al netns root → smbd.
4. smbd negocia SMB3.1.1, exige `Negotiate Sign + Encrypt`.
5. Cliente: SessionSetup con NTLMv2 (homelab + password).
6. smbd: smbpasswd_search → passdb.tdb → match → SUCCESS.
7. Cliente: TreeConnect a "homelab" → smbd: chroot a /mnt/hd2t/shares/homelab/.
8. Operaciones de fichero como UID 1000 (`force user = homelab`).
9. Auth log: "/var/log/samba/log.smbd: Auth: ... succeeded for user [homelab]".
   Fail2ban del host parsea esa línea y descarta (login OK).
```

---

## 2. Plan de variables y archivos

El stack `samba` es nuevo. Layout que se va a crear en este doc:

```
~/homelab/stacks/samba/                        # versionado en git
├── docker-compose.yml
├── .env.example
├── smb.conf                                   # plantilla de smb.conf
└── snippets-fail2ban/
    ├── samba.local                            # filtro para fail2ban
    └── 30-samba.conf                          # jail drop-in (enabled = true)

/mnt/hd2t/services/samba/                      # NO versionado
├── .env                                       # workgroup, netbios name, dominios
├── secrets/
│   └── users.conf                             # "homelab:<password>" (chmod 600)
├── config/
│   ├── smb.conf                               # → /etc/samba/smb.conf
│   └── users.conf                             # → /etc/samba/users.conf (link al de secrets/)
├── private/                                   # → /var/lib/samba/private (passdb.tdb)
└── logs/                                      # → /var/log/samba (Fail2ban lee aquí)

/mnt/hd2t/shares/                              # NO versionado, datos de usuarios
└── homelab/                                   # share [homelab] — espacio personal
```

> **Por qué `/mnt/hd2t/shares/homelab/` y no `/mnt/hd2t/services/samba/share/`**: los datos de usuario (lo que entra y sale por SMB) **no son** datos del servicio Samba: son datos del operador. Mezclarlos con la config y el `tdbsam` complicaría la política de backup (privatedb es crítico, share/ es voluminoso) y la herencia de permisos. `shares/` queda al mismo nivel que `media/`, `downloads/`, `services/`.

### 2.1. `.env.example` (`~/homelab/stacks/samba/.env.example`)

```bash
# ~/homelab/stacks/samba/.env.example
# Copiar a /mnt/hd2t/services/samba/.env y rellenar.
# NO contiene secretos: el password SMB va en /mnt/hd2t/services/samba/secrets/users.conf.

# Usuario y zona horaria.
PUID=1000
PGID=1000
TZ=Europe/Madrid

# Subred LAN para hosts allow (debe coincidir con la real, ver 03-seguridad-base §4).
LAN_SUBNET=192.168.1.0/24

# Nombre NetBIOS del servidor (cómo lo verán los clientes Windows en "Red").
SAMBA_SERVER_STRING=Pi 5 Homelab
SAMBA_NETBIOS_NAME=PI
SAMBA_WORKGROUP=WORKGROUP

# --- Imagen ---
# https://hub.docker.com/r/dockurr/samba/tags
SAMBA_IMAGE_TAG=4.21.4
```

### 2.2. `.env` real (`/mnt/hd2t/services/samba/.env`)

```bash
# Crear el .env con permisos correctos.
sudo install -m 600 -o homelab -g homelab /dev/null /mnt/hd2t/services/samba/.env

cat | sudo tee /mnt/hd2t/services/samba/.env >/dev/null <<'EOF'
PUID=1000
PGID=1000
TZ=Europe/Madrid

LAN_SUBNET=192.168.1.0/24

SAMBA_SERVER_STRING=Pi 5 Homelab
SAMBA_NETBIOS_NAME=PI
SAMBA_WORKGROUP=WORKGROUP

SAMBA_IMAGE_TAG=4.21.4
EOF

ls -l /mnt/hd2t/services/samba/.env
# Esperado: -rw------- 1 homelab homelab ... .env
```

### 2.3. Cómo se inyecta el password SMB

`dockurr/samba` lee, al arrancar, el fichero `/etc/samba/users.conf` con líneas `usuario:password` (una por línea) y, por cada una, ejecuta `smbpasswd -a -s` para crear o actualizar la cuenta SMB. El fichero se monta como bind read-only desde `/mnt/hd2t/services/samba/secrets/users.conf` (permisos `600`). Esto mantiene el password fuera de:

- El `.env` (que se versiona como `.env.example` y suele ser menos protegido).
- El `docker-compose.yml` (en git).
- `docker inspect` (no aparece en `Env`).

| Secreto | Fichero en host | Fichero en contenedor |
|---|---|---|
| Password SMB del usuario `homelab` | `/mnt/hd2t/services/samba/secrets/users.conf` | `/etc/samba/users.conf` |

---

## 3. Preparar el árbol de datos

### 3.1. Crear el directorio del stack

```bash
mkdir -p ~/homelab/stacks/samba/snippets-fail2ban
```

### 3.2. Crear el árbol de datos persistentes

```bash
sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/services/samba
sudo install -d -o homelab -g homelab -m 700 /mnt/hd2t/services/samba/secrets
sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/services/samba/config
sudo install -d -o root    -g root    -m 750 /mnt/hd2t/services/samba/private
sudo install -d -o root    -g root    -m 755 /mnt/hd2t/services/samba/logs
```

### 3.3. Crear el directorio raíz del share `[homelab]`

```bash
sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/shares
sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/shares/homelab
```

Notas sobre dueños:

- **`private/` y `logs/` son `root:root`** porque dentro del contenedor el demonio corre como `root` y tanto `passdb.tdb` (sensible) como `log.smbd` se escriben con UID 0. Mantener el dueño `root` en el host evita que un usuario no privilegiado del host pueda leer hashes o logs sin pasar por `sudo`.
- **`config/` es `homelab:homelab` y modo `750`** para que el operador edite `smb.conf` con un editor normal sin `sudo`.
- **`secrets/` es `700`** y los ficheros dentro `600`: ningún proceso ajeno puede leer el password SMB en plano.
- **`/mnt/hd2t/shares/homelab/`** se crea con `homelab:homelab 750` — sólo el usuario `homelab` puede listar/escribir desde el shell local. Cualquier otro usuario humano que se cree en el sistema operativo (improbable: el homelab es uni-usuario) **no** vería su contenido. La cuenta SMB `homelab` accederá como UID 1000 desde dentro del contenedor (vía `force user`).

---

## 4. Generar el password SMB del usuario `homelab`

```bash
umask 077

# Password SMB del usuario homelab. Generar uno largo y guardar en el gestor.
SMB_PASS=$(openssl rand -base64 24 | tr -d '\n')
echo "Password SMB para 'homelab': ${SMB_PASS}"
# Anotar este valor en KeePassXC / gestor del operador (Vaultwarden cuando esté).

# Crear el fichero users.conf con permisos correctos.
echo "homelab:${SMB_PASS}" | sudo tee /mnt/hd2t/services/samba/secrets/users.conf >/dev/null
sudo chmod 600 /mnt/hd2t/services/samba/secrets/users.conf
sudo chown homelab:homelab /mnt/hd2t/services/samba/secrets/users.conf

# Limpiar la variable de la sesión actual:
unset SMB_PASS
history -d $((HISTCMD-2)) 2>/dev/null || true   # borra la línea echo del historial bash

# Verificar.
sudo cat /mnt/hd2t/services/samba/secrets/users.conf
ls -l /mnt/hd2t/services/samba/secrets/users.conf
# Esperado:
#   homelab:<password>
#   -rw------- 1 homelab homelab ... users.conf
```

> **Anotar el password fuera del homelab** (KeePassXC en el equipo administrador, hasta que Vaultwarden esté arriba). Si se pierde, la recuperación es trivial (regenerar y reiniciar el contenedor), pero los clientes ya configurados con `auto-mount` rechazarán reconectar y darán "Acceso denegado".

> **Por qué no `/dev/urandom | base64` directamente**: `openssl rand -base64 24` da 32 caracteres (24 bytes en base64) sin caracteres problemáticos para SMB ni para el shell. Suficiente entropía contra brute-force online (Fail2ban banea tras 5 intentos en 10 min — un atacante necesitaría siglos).

---

## 5. `smb.conf`

`~/homelab/stacks/samba/smb.conf` (versionado en git, plantilla):

```ini
# ~/homelab/stacks/samba/smb.conf
# Versionado en git como plantilla. La copia "viva" vive en
# /mnt/hd2t/services/samba/config/smb.conf y se monta como bind read-only en el contenedor.

#=============================
# [global]
#=============================
[global]
    # --- Identidad ---
    server string = Pi 5 Homelab
    netbios name  = PI
    workgroup     = WORKGROUP

    # --- Interfaces (bind interfaces only es CRÍTICO con network_mode: host) ---
    interfaces = lo eth0
    bind interfaces only = yes

    # --- Protocolo: solo SMB2.10+ (SMB3 con clientes modernos) ---
    server min protocol = SMB2_10
    client min protocol = SMB2_10
    server max protocol = SMB3
    client max protocol = SMB3

    # --- Cifrado y firma obligatorios ---
    server smb encrypt = required
    server signing     = mandatory
    client signing     = mandatory

    # --- Autenticación ---
    security      = user
    map to guest  = never
    passdb backend = tdbsam

    # --- Restricción de acceso (defensa en profundidad junto a ufw) ---
    hosts allow = 192.168.1.0/24 127.0.0.1
    hosts deny  = 0.0.0.0/0

    # --- Logging (Fail2ban lee /var/log/samba/log.smbd) ---
    logging      = file
    log file     = /var/log/samba/log.%m
    max log size = 1000
    log level    = 1 auth_audit:3 auth_json_audit:0

    # --- Mejoras de UX en clientes Windows / macOS ---
    # macOS: extensión "fruit" para ficheros .DS_Store y resource forks.
    vfs objects = catia fruit streams_xattr
    fruit:metadata = stream
    fruit:model    = MacSamba
    fruit:posix_rename = yes
    fruit:veto_appledouble = no
    fruit:wipe_intentionally_left_blank_rfork = yes
    fruit:delete_empty_adfiles = yes

    # Windows: tratar archivos hidden con dot-prefix para coherencia con Linux.
    hide dot files = yes

    # --- Rendimiento ---
    use sendfile  = yes
    aio read size = 1
    aio write size = 1

    # --- Comportamiento de impresión: deshabilitado (la Pi no comparte impresora) ---
    load printers = no
    printing      = bsd
    printcap name = /dev/null
    disable spoolss = yes

    # --- Timeouts ---
    deadtime = 30

#=============================
# [homelab]   espacio personal del operador, RW.
#=============================
[homelab]
    comment       = Espacio personal del operador
    path          = /mnt/hd2t/shares/homelab
    browseable    = yes
    read only     = no
    writable      = yes
    create mask   = 0640
    directory mask = 0750
    force user    = homelab
    force group   = homelab
    valid users   = homelab

#=============================
# [media]   biblioteca multimedia, RO general / RW homelab.
#=============================
[media]
    comment       = Biblioteca multimedia (películas, series, música, libros)
    path          = /mnt/hd2t/media
    browseable    = yes
    read only     = yes
    writable      = no
    write list    = homelab
    create mask   = 0664
    directory mask = 2775
    force user    = homelab
    force group   = media
    valid users   = homelab
    # NOTA: cuando se añadan más usuarios SMB ('family', etc.), añadirlos a 'valid users'
    #       y, si deben escribir, también a 'write list'. Por defecto sólo lee 'homelab'.

#=============================
# [downloads]   directorio de Transmission, RW.
#=============================
[downloads]
    comment       = Descargas en curso y completadas (Transmission)
    path          = /mnt/hd2t/downloads
    browseable    = yes
    read only     = no
    writable      = yes
    create mask   = 0664
    directory mask = 2775
    force user    = homelab
    force group   = media
    valid users   = homelab
```

### 5.1. Por qué cada bloque

| Bloque | Por qué |
|---|---|
| `interfaces = lo eth0` + `bind interfaces only = yes` | Sin esto, Samba escucha en `0.0.0.0`. Con `network_mode: host` eso incluye Tailscale (cuando esté arriba) y cualquier interfaz futura. Restringir a `lo eth0` cierra la superficie. |
| `server min protocol = SMB2_10` | SMB1 fuera por completo. Justificado en §0 punto 6. |
| `server smb encrypt = required` | Cifra todo el tráfico SMB con AES-128-GCM. Necesario para el modelo de amenaza "WiFi LAN compartida con IoT". |
| `server signing = mandatory` | MITM defense. Coste despreciable. |
| `passdb backend = tdbsam` | Backend simple basado en fichero. Sin AD/LDAP. Al persistirlo en bind mount, sobrevive recreaciones. |
| `hosts allow = 192.168.1.0/24 127.0.0.1` | Defensa en profundidad: aunque ufw ya restrinja, Samba reaplica el check. Si en el futuro se quiere abrir vía Tailscale (variante §14.1), añadir `100.64.0.0/10` aquí. |
| `vfs objects = catia fruit streams_xattr` | `fruit` es el módulo que hace que macOS Finder se sienta nativo (Time Machine compatible si se activa, ficheros AppleDouble correctos, sin "._" sucios en el árbol). `streams_xattr` mapea ADS de Windows a xattrs Linux: necesario para no perder metadatos al copiar. `catia` traduce caracteres ilegales en NTFS (`?`, `*`, `:`, ...) a Unicode equivalente. |
| `force user = homelab` (en `[homelab]` y `[downloads]`) | Independiza la cuenta SMB del UID. Si en el futuro se añade `family` con acceso a `[media]`, los ficheros en `media/` siguen siendo escritos como `homelab` UID 1000 — Sonarr/Radarr siguen leyéndolos sin retoques. |
| `force group = media` (en `[media]` y `[downloads]`) | El bit `setgid` del directorio (heredado de [`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) §6) ya hace esto al crear; `force group` lo hace explícito por si una `umask` rara del cliente saliese. |
| `create mask = 0640` (en `[homelab]`) | Por defecto, los ficheros nuevos son `rw- r-- ---` (group puede leer pero no escribir). En `[homelab]` no hay otros usuarios, pero la herencia es coherente. |
| `create mask = 0664` (en `[media]`, `[downloads]`) | `rw- rw- r--`: el grupo `media` puede leer y escribir. Necesario para que Sonarr/Radarr (también en grupo `media` con PGID 1100) modifiquen ficheros llegados por Samba. |
| `directory mask = 2775` (en `[media]`, `[downloads]`) | El `2` (setgid) propaga el grupo al subdirectorio recién creado. Coherente con el patrón establecido en estructura-directorios. |
| `deadtime = 30` | Cierra conexiones inactivas tras 30 min. En la Pi 5 con 8 GB no es crítico, pero ayuda si un cliente Windows queda en standby con la conexión abierta. |
| `disable spoolss = yes` | La Pi no comparte impresora. Apagar el subsistema de impresión reduce superficie. |

### 5.2. Aplicar la plantilla al directorio "vivo"

```bash
# Copiar la plantilla a la ruta que monta Compose:
sudo install -m 644 -o homelab -g homelab \
  ~/homelab/stacks/samba/smb.conf \
  /mnt/hd2t/services/samba/config/smb.conf

# users.conf "vivo" en config/ es un enlace simbólico al de secrets/ para que
# el contenedor lo encuentre en /etc/samba/users.conf (Compose monta config/ en /etc/samba).
sudo ln -sf /mnt/hd2t/services/samba/secrets/users.conf \
            /mnt/hd2t/services/samba/config/users.conf

ls -l /mnt/hd2t/services/samba/config/
# Esperado:
#   -rw-r--r-- 1 homelab homelab ...     smb.conf
#   lrwxrwxrwx 1 root    root    ...     users.conf -> /mnt/hd2t/services/samba/secrets/users.conf
```

> **Por qué `config/` se monta entero en `/etc/samba/`** y no `smb.conf` y `users.conf` por separado: el entrypoint de `dockurr/samba` escribe ficheros auxiliares en `/etc/samba/` (locks, pid de `nmbd` cuando se inicia). Montar el directorio completo permite que esos ficheros aterricen en el host (legibles por el operador) y, sobre todo, que ediciones futuras de `smb.conf` desde el host (`sudo nano /mnt/hd2t/services/samba/config/smb.conf`) entren en vigor con un simple `docker exec samba smbcontrol all reload-config` (sin recreate).

---

## 6. `docker-compose.yml`

`~/homelab/stacks/samba/docker-compose.yml`:

```yaml
# ~/homelab/stacks/samba/docker-compose.yml
# Stack: samba (../02-docker/02-estructura-compose.md §1.1).
# Datos en /mnt/hd2t/services/samba/. Usuarios SMB en .../secrets/users.conf.

name: samba

services:
  samba:
    image: dockurr/samba:${SAMBA_IMAGE_TAG}
    container_name: samba
    hostname: samba
    restart: unless-stopped

    # --- network_mode: host ---
    # Necesario para descubrimiento NetBIOS (UDP 137/138). Ver §0 punto 3.
    network_mode: host

    env_file:
      - /mnt/hd2t/services/samba/.env
    environment:
      TZ: ${TZ}
      # La imagen dockurr/samba acepta variables NAME / WORKGROUP para customizar
      # el smb.conf que ella genera, PERO al montar nuestro propio smb.conf en
      # /etc/samba/smb.conf esas vars se ignoran. Las dejamos por simetría con su doc.
      NAME: ${SAMBA_NETBIOS_NAME}
      WORKGROUP: ${SAMBA_WORKGROUP}

    volumes:
      # Configuración (smb.conf, users.conf via symlink): el directorio entero, RW
      # para que el entrypoint pueda escribir locks/pidfile junto al smb.conf.
      - type: bind
        source: /mnt/hd2t/services/samba/config
        target: /etc/samba
        bind:
          create_host_path: false

      # Secrets (users.conf, lectura): RO para que el contenedor no pueda
      # mutar el password.
      - type: bind
        source: /mnt/hd2t/services/samba/secrets
        target: /etc/samba/secrets
        read_only: true
        bind:
          create_host_path: false

      # passdb.tdb / secrets.tdb (base de datos de usuarios SMB).
      - type: bind
        source: /mnt/hd2t/services/samba/private
        target: /var/lib/samba/private
        bind:
          create_host_path: false

      # Logs (Fail2ban del host los lee desde aquí).
      - type: bind
        source: /mnt/hd2t/services/samba/logs
        target: /var/log/samba
        bind:
          create_host_path: false

      # --- Datos compartidos por SMB ---
      - type: bind
        source: /mnt/hd2t/shares/homelab
        target: /mnt/hd2t/shares/homelab
        bind:
          create_host_path: false

      - type: bind
        source: /mnt/hd2t/media
        target: /mnt/hd2t/media
        bind:
          create_host_path: false

      - type: bind
        source: /mnt/hd2t/downloads
        target: /mnt/hd2t/downloads
        bind:
          create_host_path: false

    cap_drop:
      - ALL
    cap_add:
      - NET_BIND_SERVICE
      - SETUID
      - SETGID
      - CHOWN
      - FOWNER
      - DAC_OVERRIDE
      - DAC_READ_SEARCH
      - SYS_CHROOT

    security_opt:
      - no-new-privileges:true

    healthcheck:
      test:
        - CMD-SHELL
        - 'smbclient -N -L //127.0.0.1 --option="client min protocol=SMB2_10" 2>&1 | grep -q homelab'
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 30s

    labels:
      com.centurylinklabs.watchtower.enable: "true"
      homepage.group: "Almacenamiento"
      homepage.name: "Samba"
      homepage.icon: "samba.png"
      homepage.description: "Compartición SMB en LAN"

    # network_mode: host implica que NO hay 'networks:' aquí.
```

### 6.1. Por qué cada bloque

| Bloque | Por qué |
|---|---|
| `network_mode: host` | Justificado en §0 punto 3 y §0 fila correspondiente. Implica que `ports:` no aplica y que la sección `networks:` debe estar **ausente**. |
| `env_file + environment NAME/WORKGROUP` | Aunque la imagen ignora `NAME`/`WORKGROUP` cuando hay un `smb.conf` propio, dejarlas explícitas documenta intención y simplifica la transición a un eventual modo "sin smb.conf custom". |
| `bind /etc/samba` (RW) | El entrypoint escribe ficheros auxiliares (`smb.conf.bak` cuando arranca, `printers.conf`, etc.). Con `read_only: true` el contenedor entra en restart loop. La defensa real es que el operador es el único usuario humano del host y `umask 027` aplica. |
| `bind /etc/samba/secrets` (RO) | Aislamiento del fichero `users.conf`: aunque el contenedor pudiera escribir en `/etc/samba/`, no puede tocar el password. |
| `bind /var/lib/samba/private` | `passdb.tdb` debe persistir. Si se montara como volumen Docker named, el reset implicaría perder usuarios SMB. |
| `bind /var/log/samba` | Para que Fail2ban del host (paquete `apt`, no contenedor) los pueda leer. |
| `bind` de `/mnt/hd2t/{shares/homelab,media,downloads}` con **el mismo path dentro del contenedor** | Coincidir el path host = path contenedor permite que `smb.conf` use rutas absolutas idénticas en ambos lados. Sin esto habría que reescribir cada `path =` en el `.conf` cada vez que se cambia algo y dificulta debugging (`docker exec samba ls /mnt/hd2t/media` debería devolver lo mismo que el host). |
| `cap_drop: ALL` + lista de `cap_add` | Todas las caps necesarias están justificadas en §0 fila correspondiente. **`SYS_CHROOT`** es el que sorprende: `smbd` hace `chroot()` por share para implementar `path = /...`. Sin esa cap, los shares quedan accesibles pero sin aislamiento real (un cliente con `wide links` podría salir del path). |
| `healthcheck smbclient -N -L //127.0.0.1` | Lista los shares sin auth (cualquier servidor responde a esta query con la lista anonymous). El `grep -q homelab` confirma que al menos el share `[homelab]` aparece — descarta casos donde el demonio responde pero `smb.conf` está vacío. |
| `start_period: 30s` | El entrypoint de la imagen tarda ~5–10 s en (re)crear los usuarios desde `users.conf` y arrancar `smbd` + `nmbd`. 30 s es holgura. |

### 6.2. Validar antes de levantar

```bash
cd ~/homelab/stacks/samba
docker compose --env-file /mnt/hd2t/services/samba/.env config >/dev/null \
  && echo "Compose OK"
```

Errores típicos en este punto:

- `service "samba" with network_mode "host" cannot also declare networks` → eliminar cualquier sección `networks:` que se haya colado.
- `bind source path does not exist: /mnt/hd2t/services/samba/secrets` → revisar §3.2 (no se ejecutaron los `install -d`).

---

## 7. Despliegue

### 7.1. Primer arranque

```bash
cd ~/homelab/stacks/samba
docker compose --env-file /mnt/hd2t/services/samba/.env up -d
```

Salida esperada:

```
[+] Running 1/1
 ✔ Container samba    Started
```

### 7.2. Estado del contenedor

```bash
docker compose ps
# Esperado, tras ~30 s:
# NAME    IMAGE                  STATUS                 PORTS
# samba   dockurr/samba:4.21.4   Up X (healthy)
```

Si entra en `(unhealthy)`:

```bash
docker logs samba | tail -50
```

Eventos esperados al primer arranque:

```
Configuring Samba...
Adding user homelab from /etc/samba/users.conf...
Added user homelab.
Starting nmbd...
Starting smbd...
[YYYY/MM/DD HH:MM:SS.NNN] smbd/server.c: smbd version 4.21.x started.
```

### 7.3. Confirmar puertos en escucha

```bash
sudo ss -lntu '( sport = :137 or sport = :138 or sport = :139 or sport = :445 )'
# Esperado: cuatro líneas (137/udp, 138/udp, 139/tcp, 445/tcp), todas LISTEN
# en la IP 192.168.1.10 (o en *) — NO debería aparecer ::* salvo que se quiera IPv6 explícito.
```

### 7.4. Confirmar interfaces declaradas

```bash
docker exec samba testparm -s 2>/dev/null | grep -E 'interfaces|bind interfaces'
# Esperado:
#   interfaces = lo eth0
#   bind interfaces only = Yes
```

### 7.5. Confirmar usuario SMB creado

```bash
sudo docker exec samba pdbedit -L
# Esperado:
#   homelab:1000:Homelab
```

(El UID 1000 viene heredado del propio Linux a través del entrypoint de la imagen, que crea la cuenta SMB y la asocia al usuario UNIX correspondiente.)

---

## 8. Reglas de firewall (`ufw`)

`ufw` (definido en [`../01-sistema/03-seguridad-base.md`](../01-sistema/03-seguridad-base.md) §4) por defecto deniega entradas. Con `network_mode: host`, los puertos de Samba están en el host real, así que las reglas se aplican igual que para cualquier servicio de paquete.

```bash
# SMB / NetBIOS, sólo desde la LAN. Comentarios explícitos para auditar luego.
sudo ufw allow from 192.168.1.0/24 to any port 445 proto tcp comment 'SMB direct (Samba)'
sudo ufw allow from 192.168.1.0/24 to any port 139 proto tcp comment 'NetBIOS Session (Samba legacy)'
sudo ufw allow from 192.168.1.0/24 to any port 137 proto udp comment 'NetBIOS Name Service'
sudo ufw allow from 192.168.1.0/24 to any port 138 proto udp comment 'NetBIOS Datagram'

sudo ufw status numbered | grep -i 'samba\|netbios\|137\|138\|139\|445'
```

Esperado: cuatro reglas con `ALLOW IN` desde `192.168.1.0/24` (sustituir por la subred real si difiere).

> **No se abre 137-138 a `0.0.0.0/0`** ni siquiera "para que NetBIOS funcione mejor". Si un cliente externo pasa por Tailscale, llegará por la interfaz `tailscale0`, que **no** está en `interfaces = lo eth0` del `smb.conf`: Samba no responderá. La variante §14.1 documenta cómo abrirlo bajo Tailscale.

> Si el operador trabaja con `nftables` directamente (sin `ufw`), las reglas equivalentes en `/etc/nftables.conf` son `tcp dport {139,445} ip saddr 192.168.1.0/24 accept` y `udp dport {137,138} ip saddr 192.168.1.0/24 accept`. Mantenerlo coherente con el resto del homelab → `ufw`.

---

## 9. Acceso desde clientes

### 9.1. Windows 10 / 11

**Opción A — Explorador**:

1. Abrir el Explorador de archivos.
2. En la barra de direcciones: `\\192.168.1.10` (o `\\PI` si el cliente resuelve por NetBIOS).
3. Doble clic en el share `homelab`.
4. Credenciales: usuario `homelab`, password el generado en §4. Marcar "Recordar credenciales".

**Opción B — Conectar a unidad de red** (Z: persistente):

1. Click derecho sobre "Este equipo" → "Conectar a unidad de red".
2. Carpeta: `\\192.168.1.10\homelab`.
3. Marcar "Conectar con otras credenciales" → introducir `homelab` + password.

> Si Windows da `0x80004005 — Error no especificado` al pegar `\\PI\homelab`, **probar con la IP**: el descubrimiento NetBIOS lo entierra Windows 10 1709+ por defecto en redes "privadas". Activar "Detección de redes" (Centro de Redes y Recursos Compartidos → Cambiar configuración de uso compartido avanzado → Activar la detección de redes) o, mejor, usar la IP / `pi.lan` (si Pi-hole resuelve).

### 9.2. macOS

1. Finder → menú "Ir" → "Conectar al servidor…" (`Cmd-K`).
2. Dirección: `smb://192.168.1.10` (o `smb://pi.lan` si Pi-hole tiene el record).
3. Credenciales: `homelab` + password. Marcar "Recordar esta contraseña en mi llavero".
4. Selección de share: `homelab`, `media` o `downloads`.

### 9.3. Linux (GNOME Files / Nautilus)

1. Files → "Otros lugares" → en la barra inferior: `smb://192.168.1.10/homelab` (o `media`, `downloads`).
2. Credenciales en el diálogo. Marcar "Recordar siempre".

### 9.4. Linux (montaje permanente con `mount.cifs`)

```bash
sudo apt install -y cifs-utils

# Credentials file (chmod 600).
sudo install -m 600 /dev/null /etc/samba/credentials-homelab
sudo tee /etc/samba/credentials-homelab >/dev/null <<EOF
username=homelab
password=PASSWORD_AQUI
EOF

# Punto de montaje.
sudo mkdir -p /mnt/pi-homelab

# Línea en /etc/fstab (la subred del cliente, por supuesto, debe estar en la LAN o en Tailscale).
sudo tee -a /etc/fstab >/dev/null <<'EOF'
//192.168.1.10/homelab  /mnt/pi-homelab  cifs  credentials=/etc/samba/credentials-homelab,uid=1000,gid=1000,vers=3.1.1,seal,noperm,_netdev  0  0
EOF

sudo mount -a
df -h /mnt/pi-homelab
```

Notas:

- **`vers=3.1.1`**: fuerza SMB3.1.1 (el más reciente). Compatible con Samba 4.21+.
- **`seal`**: pide cifrado SMB3 obligatorio (cliente). Coherente con `server smb encrypt = required`.
- **`uid=1000,gid=1000`**: hace que los ficheros remotos aparezcan como dueño local 1000 en el cliente, transparente para el editor que use el operador.
- **`noperm`**: el cliente no aplica chequeos POSIX adicionales (los reales los aplica el servidor por `force user`).
- **`_netdev`**: systemd no monta hasta que la red está arriba; evita errores en el boot del cliente.

### 9.5. Smartphones

- **Android**: cualquier explorador con SMB (Solid Explorer, CX File Explorer). Servidor `192.168.1.10`, usuario `homelab`, password.
- **iOS**: Files (app nativa) → "Conectar al servidor" → `smb://192.168.1.10` → credenciales.

---

## 10. Verificación

### 10.1. Lista de shares anonymous

```bash
smbclient -N -L //192.168.1.10 --option='client min protocol=SMB2_10'
# Esperado: secciones "Sharename" listando homelab, media, downloads, IPC$.
# Si responde "NT_STATUS_ACCESS_DENIED": cliente min protocol no encaja con server min;
# el cliente está intentando SMB1 (clientes antiguos en Debian 10).
```

### 10.2. Auth funciona

```bash
smbclient //192.168.1.10/homelab -U homelab%PASSWORD --option='client min protocol=SMB2_10'
# Prompt: smb: \>
# Probar 'ls' y 'pwd', luego 'exit'.
```

### 10.3. Cifrado SMB3 efectivo

```bash
smbclient //192.168.1.10/homelab -U homelab%PASSWORD -e -c 'showconnect' \
  --option='client min protocol=SMB2_10'
# Esperado: línea "AES-128-GCM" (o AES-256 según el cliente). Si el server permitiese
# texto plano, aquí no aparecería 'GCM'.
```

### 10.4. Subir y bajar un fichero (round-trip)

```bash
echo "hola homelab" > /tmp/test.txt
smbclient //192.168.1.10/homelab -U homelab%PASSWORD \
  -c 'put /tmp/test.txt; ls; get test.txt /tmp/test-back.txt'
diff /tmp/test.txt /tmp/test-back.txt && echo "Round-trip OK"
rm -f /tmp/test.txt /tmp/test-back.txt
```

### 10.5. Permisos UID 1000 en disco

Tras subir un fichero por SMB:

```bash
ls -l /mnt/hd2t/shares/homelab/test.txt
# Esperado:
#   -rw-r----- 1 homelab homelab ... test.txt
# (force user = homelab; create mask = 0640.)
```

Ahora desde el share `media`:

```bash
smbclient //192.168.1.10/media -U homelab%PASSWORD -c 'mkdir test_smb_dir'
ls -ld /mnt/hd2t/media/test_smb_dir
# Esperado: drwxrwsr-x homelab media — directory mask = 2775, force group = media.

smbclient //192.168.1.10/media -U homelab%PASSWORD -c 'rmdir test_smb_dir'
```

### 10.6. Read-only desde otro usuario

(Sólo si se ha creado `family` siguiendo §12.4. Si no, saltar.)

```bash
# Intentar escribir en [media] como 'family' (debe fallar).
smbclient //192.168.1.10/media -U family%PASSWORD_FAMILY -c 'put /tmp/foo.txt' 2>&1 \
  | grep -i 'NT_STATUS\|ACCESS_DENIED'
# Esperado: NT_STATUS_ACCESS_DENIED (write list = homelab, no incluye family).
```

### 10.7. Acceso desde fuera de la LAN está cerrado

```bash
# Desde un cliente Tailscale (móvil con la app, IP 100.64.x.y):
nmap -p 445 192.168.1.10
# Esperado: 'filtered' (ufw lo descarta). Si pone 'open', revisar §8: la regla
# debe tener 'from 192.168.1.0/24', no '0.0.0.0/0'.
```

### 10.8. Persistencia tras reboot

```bash
sudo reboot

# (esperar a que vuelva)

docker compose -f ~/homelab/stacks/samba/docker-compose.yml ps
# Esperado: Up X (healthy).

# Cliente reconecta sin reintroducir password (Windows credenciales recordadas;
# Linux con fstab).
ls /mnt/pi-homelab/   # desde el cliente Linux con fstab.
```

### 10.9. Lista de Verificación

Antes de pasar a [`03-syncthing.md`](./03-syncthing.md):

- [ ] `docker compose ps` en el stack `samba` → `Up (healthy)`.
- [ ] `sudo ss -lntu '( sport = :137 or sport = :138 or sport = :139 or sport = :445 )'` muestra los cuatro puertos en LISTEN.
- [ ] `sudo ufw status` lista las cuatro reglas SMB/NetBIOS desde `192.168.1.0/24`, ninguna abierta a `0.0.0.0/0`.
- [ ] `docker exec samba testparm -s` no reporta errores de sintaxis (`Loaded services file OK.`).
- [ ] `smbclient -N -L //192.168.1.10` lista los tres shares + IPC$.
- [ ] `smbclient //192.168.1.10/homelab -U homelab%pass -c 'ls'` autentica y entra.
- [ ] Round-trip de fichero (§10.4) `Round-trip OK`.
- [ ] Un fichero subido por SMB queda en disco con dueño `homelab:homelab` y permisos `0640`.
- [ ] Un fichero subido al share `[media]` queda con dueño `homelab:media` y permisos `2775` en directorios.
- [ ] El operador ha **anotado fuera del homelab** el password SMB del usuario `homelab`.
- [ ] Cliente Windows / macOS / Linux ha completado al menos un mount manual y un round-trip de fichero.
- [ ] Tras `sudo reboot`, el contenedor arranca y los clientes reconectan sin intervención.
- [ ] `~/homelab/stacks/samba/{docker-compose.yml,.env.example,smb.conf,snippets-fail2ban/*}` versionados en git; `.env` y `secrets/users.conf` **NO**.
- [ ] `/mnt/hd2t/services/samba/secrets/users.conf` con permisos `600 homelab:homelab` y el directorio padre `700 homelab:homelab`.
- [ ] `/mnt/hd2t/services/samba/private/` con dueño `root:root` y permisos `750`.
- [ ] Fail2ban: jail `samba` activo (§13) — opcional, ya que el deploy del filtro es el último paso.

---

## 11. Backup

Estrategia que se concretará en [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md). Lo que **debe respaldarse** del stack `samba`:

| Ruta | Qué contiene | Frecuencia | Cómo |
|---|---|---|---|
| `~/homelab/stacks/samba/{docker-compose.yml,.env.example,smb.conf,snippets-fail2ban/*}` | Definición del stack, plantilla de `smb.conf`, jails Fail2ban. | Versionado en git → `git push`. | Continuo. |
| `/mnt/hd2t/services/samba/.env` | Workgroup, NetBIOS name, tag de imagen. Reconstruible desde `.env.example`. | Opcional. | Snapshot Borg. |
| `/mnt/hd2t/services/samba/secrets/users.conf` | **Crítico**. Password SMB del usuario `homelab`. La pérdida obliga a regenerar y reconfigurar todos los clientes. | **Diaria**, dentro del backup de Borg con cifrado fuerte. | Snapshot Borg. |
| `/mnt/hd2t/services/samba/config/smb.conf` | Configuración de shares. Normalmente igual a la plantilla en git, pero puede tener cambios manuales. | Cada cambio. | Snapshot Borg + `cp` antes de editar. |
| `/mnt/hd2t/services/samba/private/passdb.tdb` + `secrets.tdb` | Base de datos de usuarios SMB con hashes. La pérdida fuerza recrear cada usuario con `users.conf` (recuperable, pero romperá clientes con sesiones cacheadas). | **Diaria**. | Snapshot Borg. |
| `/mnt/hd2t/services/samba/logs/` | Logs `log.smbd`, `log.nmbd`, `log.<cliente>`. Útiles para forense, **no críticos**. | Sin backup explícito; rotación interna de Samba (`max log size = 1000`) basta. | — |
| `/mnt/hd2t/shares/homelab/` | Datos del operador subidos por SMB. **Crítico** según contenido. | **Diaria** diferencial. | Snapshot Borg. |
| `/mnt/hd2t/media/` | Bibliotecas multimedia. Cubierto por la política de [`./01-nextcloud.md`](./01-nextcloud.md) §10 / Borgmatic general. | Igual que el resto de `/mnt/hd2t/media`. | — |
| `/mnt/hd2t/downloads/` | Torrents en curso. **No crítico** (re-descargable). | No backup. | — |

### 11.1. Pre-backup hook (ejemplo Borgmatic)

```yaml
# Pseudo-config; la real va en 07-backups/02-borgmatic.md.
before_backup:
  # 1. Snapshot consistente de las TDBs de Samba.
  #    Las TDBs son seguras de copiar "en caliente" si no hay escritura activa,
  #    pero un backup "the perfect way" usa tdbbackup para vacuum + checksum.
  - >
    docker exec samba sh -c
    'tdbbackup /var/lib/samba/private/passdb.tdb &&
     tdbbackup /var/lib/samba/private/secrets.tdb'

after_backup:
  # 2. Limpiar los .bak (tdbbackup deja un fichero .bak junto a cada .tdb).
  - find /mnt/hd2t/services/samba/private/ -name '*.bak' -mtime +14 -delete
```

### 11.2. Restore (resumen)

Procedimiento completo en [`../07-backups/03-backup-docker-volumes.md`](../07-backups/03-backup-docker-volumes.md). Resumen:

1. `docker compose down`.
2. Restaurar `/mnt/hd2t/services/samba/{config,private,secrets,.env}` desde Borg.
3. Restaurar `/mnt/hd2t/shares/homelab/` desde Borg.
4. `docker compose up -d`.
5. Probar login con un cliente conocido.

> **Punto crítico**: si se restaura `private/passdb.tdb` de un día y `secrets/users.conf` de otro distintos, los hashes no cuadran. El operador puede regenerar `passdb.tdb` reemplazando `users.conf` y reiniciando el contenedor (el entrypoint reaplica `smbpasswd -a` sobre el `tdbsam` actual). Pero los **client-side** keychains seguirán teniendo el password viejo: si el operador regeneró el password, hay que actualizar cada cliente.

---

## 12. Operaciones cotidianas

### 12.1. Editar `smb.conf` sin recreate

```bash
sudo nano /mnt/hd2t/services/samba/config/smb.conf
# Validar antes de aplicar:
sudo docker exec samba testparm -s 2>&1 | tail -20
# Esperado: "Loaded services file OK." al final. Si hay errores, NO recargar.

# Aplicar sin reinicio (sólo cambios re-readibles, p.ej. nuevos shares):
sudo docker exec samba smbcontrol all reload-config
# Para cambios profundos (interfaces, protocol min/max, encryption):
docker compose -f ~/homelab/stacks/samba/docker-compose.yml restart samba
```

### 12.2. Cambiar el password SMB del usuario `homelab`

```bash
# 1. Generar el nuevo password (anotar en KeePassXC/Vaultwarden).
NEW_PASS=$(openssl rand -base64 24 | tr -d '\n')

# 2. Cambiarlo dentro de la TDB (no toca users.conf):
sudo docker exec samba sh -c \
  "(echo \"$NEW_PASS\"; echo \"$NEW_PASS\") | smbpasswd -s homelab"

# 3. Sincronizar el fichero users.conf por consistencia (próximo restart lo aplicaría
#    igualmente; mantenerlos coherentes evita confusión).
echo "homelab:${NEW_PASS}" | sudo tee /mnt/hd2t/services/samba/secrets/users.conf >/dev/null
sudo chmod 600 /mnt/hd2t/services/samba/secrets/users.conf
sudo chown homelab:homelab /mnt/hd2t/services/samba/secrets/users.conf

# 4. Limpiar la sesión.
unset NEW_PASS
history -d $((HISTCMD-2)) 2>/dev/null || true
```

Tras esto, **actualizar el password en cada cliente** (Windows: Panel de Control → Credenciales; macOS: Acceso a Llaveros; Linux: `/etc/samba/credentials-homelab`).

### 12.3. Listar usuarios SMB y su estado

```bash
sudo docker exec samba pdbedit -L -v
# Muestra cada usuario con su SID, último login, account flags ('U' = user normal, 'D' = disabled).
```

### 12.4. Añadir un usuario nuevo (`family`, RO en `[media]`)

```bash
# 1. Generar password.
FAMILY_PASS=$(openssl rand -base64 18 | tr -d '\n')
echo "Password SMB para 'family': ${FAMILY_PASS}"

# 2. Crear el usuario UNIX correspondiente (necesario para que la cuenta SMB tenga UID).
#    Sólo si no existe ya. NO hace falta darle shell ni home: es sólo "carcasa" UNIX.
if ! id family >/dev/null 2>&1; then
  sudo useradd --no-create-home --shell /usr/sbin/nologin family
fi

# 3. Añadirlo al fichero users.conf.
echo "family:${FAMILY_PASS}" | sudo tee -a /mnt/hd2t/services/samba/secrets/users.conf >/dev/null
sudo chmod 600 /mnt/hd2t/services/samba/secrets/users.conf

# 4. Recrear el contenedor para que el entrypoint procese la nueva línea.
docker compose -f ~/homelab/stacks/samba/docker-compose.yml restart samba

# 5. Permitir el acceso al share [media] editando smb.conf.
sudo sed -i '/^\[media\]/,/^\[/ s/^\(    valid users\s*=\s*\).*/\1homelab family/' \
  /mnt/hd2t/services/samba/config/smb.conf

# 6. Reload sin recreate.
docker exec samba smbcontrol all reload-config

# 7. Verificar.
sudo docker exec samba pdbedit -L | grep -E '^homelab|^family'

# 8. Limpiar.
unset FAMILY_PASS
```

### 12.5. Banear / desbanear una IP por SMB (Fail2ban)

```bash
# Ver IPs baneadas en el jail samba:
sudo fail2ban-client status samba

# Desbanear una IP concreta:
sudo fail2ban-client unban 192.168.1.99

# Banear manualmente (test):
sudo fail2ban-client set samba banip 10.0.0.99
```

### 12.6. Forzar disconnect de todas las sesiones (mantenimiento)

```bash
# Listar sesiones activas:
sudo docker exec samba smbstatus --shares

# Cerrar todas:
sudo docker exec samba smbcontrol smbd close-share homelab
sudo docker exec samba smbcontrol smbd close-share media
sudo docker exec samba smbcontrol smbd close-share downloads

# Los clientes verán "Connection reset" y reconectarán automáticamente al volver a navegar.
```

### 12.7. Auditar accesos (quién, cuándo, qué)

Los logs en `/mnt/hd2t/services/samba/logs/log.<cliente>` registran cada SessionSetup con `auth_audit:3`:

```bash
sudo grep -E 'Auth: \[smb' /mnt/hd2t/services/samba/logs/log.smbd | tail -20
# Líneas como:
#   ... Auth: [smb,(null)] user [WORKGROUP]\[homelab] at [Tue, 15 Apr 2025 ...]
#   with [NTLMSSP] status [NT_STATUS_OK] workstation [LAPTOP] remote host [192.168.1.5]
#   ... mapped to [WORKGROUP]\[homelab].
```

Para querear por cliente:

```bash
ls /mnt/hd2t/services/samba/logs/log.*
# Un fichero por máquina cliente (log.laptop, log.iphone, etc.) — heredado de
# log file = log.%m en smb.conf.
```

### 12.8. Vaciar caches (tras cambiar permisos en disco y queriendo refresco)

```bash
sudo docker exec samba smbcontrol all reload-config
# Si los clientes ven permisos viejos por caching ACL:
sudo docker exec samba smbcontrol all kill-client-ip 192.168.1.5
# (sustituir por la IP del cliente afectado).
```

### 12.9. Upgrade de imagen (Watchtower lo hace automáticamente)

Al estar `watchtower.enable: "true"`, el upgrade es automático en la franja horaria de Watchtower (ver [`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §3). El procedimiento manual (en caso de querer adelantar):

```bash
cd ~/homelab/stacks/samba
docker compose --env-file /mnt/hd2t/services/samba/.env pull samba
docker compose --env-file /mnt/hd2t/services/samba/.env up -d
docker compose --env-file /mnt/hd2t/services/samba/.env ps
docker logs samba | tail -20   # Esperado: smbd version 4.21.x → 4.22.x con OK al final.
```

Si tras el upgrade hay clientes con `NT_STATUS_INVALID_PARAMETER`, suele ser que el server max protocol bajó por defecto en la nueva versión: comprobar `testparm -s | grep -i 'max protocol'`.

---

## 13. Integración con Fail2ban

[`../04-seguridad/02-fail2ban.md`](../04-seguridad/02-fail2ban.md) ya prepara el espacio: `/etc/fail2ban/jail.d/30-samba.conf` queda con `enabled = false` por defecto. Ahora que Samba existe y los logs están en `/mnt/hd2t/services/samba/logs/log.smbd`, se activa el jail.

### 13.1. Filtro `filter.d/samba.local`

Crear `~/homelab/stacks/samba/snippets-fail2ban/samba.local`:

```ini
# ~/homelab/stacks/samba/snippets-fail2ban/samba.local
# Detecta intentos de auth fallidos en logs de smbd con auth_audit:3.

[Definition]
failregex = ^.*Auth: \[smb,.*remote host \[<HOST>\].*status \[NT_STATUS_(WRONG_PASSWORD|LOGON_FAILURE|NO_SUCH_USER|ACCESS_DENIED|UNSUCCESSFUL|TRUSTED_RELATIONSHIP_FAILURE)\].*$

ignoreregex =

datepattern = {^LN-BEG}%%Y/%%m/%%d %%H:%%M:%%S\.%%f
              {^LN-BEG}%%a, %%d %%b %%Y %%H:%%M:%%S\.%%f
```

### 13.2. Jail `jail.d/30-samba.conf`

Crear `~/homelab/stacks/samba/snippets-fail2ban/30-samba.conf`:

```ini
# ~/homelab/stacks/samba/snippets-fail2ban/30-samba.conf
# Drop-in para /etc/fail2ban/jail.d/. Ban a nivel nftables ante credstuffing SMB.

[samba]
enabled  = true
filter   = samba
backend  = auto
logpath  = /mnt/hd2t/services/samba/logs/log.smbd
port     = 137,138,139,445
maxretry = 5
findtime = 10m
bantime  = 1h
# bantime.increment, banaction y nftables-allports vienen heredados del [DEFAULT]
# de Fase 1 (../01-sistema/03-seguridad-base §5).
```

### 13.3. Aplicar al host

```bash
sudo install -m 644 -o root -g root \
  ~/homelab/stacks/samba/snippets-fail2ban/samba.local \
  /etc/fail2ban/filter.d/samba.local

sudo install -m 644 -o root -g root \
  ~/homelab/stacks/samba/snippets-fail2ban/30-samba.conf \
  /etc/fail2ban/jail.d/30-samba.conf

sudo fail2ban-client reload
sudo fail2ban-client status samba
# Esperado:
#   Status for the jail: samba
#   |- Filter
#   |  |- Currently failed: 0
#   |  |- Total failed:     0
#   |  `- File list:        /mnt/hd2t/services/samba/logs/log.smbd
#   `- Actions
#      |- Currently banned: 0
#      |- Total banned:     0
#      `- Banned IP list:
```

### 13.4. Test del filtro contra el log real

```bash
sudo fail2ban-regex /mnt/hd2t/services/samba/logs/log.smbd /etc/fail2ban/filter.d/samba.local
# Esperado:
#   ... Lines: <total> lines, 0 ignored, <N> matched, <total - N> missed.
# Donde <N> debería incrementar en cada login fallido. Para forzar uno:
smbclient //192.168.1.10/homelab -U homelab%PASSWORD_INCORRECTA -c 'ls' 2>/dev/null
sudo grep -i 'NT_STATUS_LOGON_FAILURE\|WRONG_PASSWORD' /mnt/hd2t/services/samba/logs/log.smbd | tail
sudo fail2ban-regex --print-no-missed /mnt/hd2t/services/samba/logs/log.smbd /etc/fail2ban/filter.d/samba.local | tail
```

---

## 14. Variantes opt-in

### 14.1. Acceso a Samba sobre Tailscale (móvil fuera de casa)

**No recomendado por defecto** — Tailscale no anuncia NetBIOS broadcast (la red mesh es L3, no L2), así que el descubrimiento "ver la Pi en Red" no funciona. Conexión por IP `100.64.x.y` directa sí.

Pasos:

1. Añadir la subred Tailscale a `interfaces` en `smb.conf`:
   ```ini
   interfaces = lo eth0 tailscale0
   ```
2. Añadir la subred a `hosts allow`:
   ```ini
   hosts allow = 192.168.1.0/24 100.64.0.0/10 127.0.0.1
   ```
3. **NO** abrir 137-138-139-445 al exterior en `ufw`: con `interfaces = ... tailscale0`, Samba ya escucha allí. Las peticiones al puerto 445 desde la red Tailscale entran por `tailscale0`, NO pasan por `ufw eth0`.
   ```bash
   # Si por alguna razón se quiere reglas explícitas:
   sudo ufw allow in on tailscale0 from 100.64.0.0/10 to any port 445 proto tcp
   ```
4. Reload: `docker exec samba smbcontrol all reload-config`.
5. En el cliente Tailscale (móvil con la app), conectar a `smb://<tailscale-IP-de-la-Pi>` o `smb://<hostname>.tailnet.ts.net`.

> **Consideraciones**: aunque SMB3 va cifrado, expone un protocolo "ruidoso" sobre la VPN. Para el caso "necesito un fichero del homelab desde la calle", **Nextcloud** es mejor opción (HTTPS por Caddy, cliente web móvil sin instalar nada).

### 14.2. Samba en `macvlan` (IP dedicada en la LAN)

Da a Samba una IP propia (`192.168.1.30`), separada de la del host. Ventajas: NetBIOS más limpio, los clientes ven dos máquinas distintas en "Red"; puede coexistir con un Samba del host en otra IP. Desventajas: complejidad extra, el host no puede hablar con Samba sin macvlan-shim.

Pasos (resumen — ver [`../03-red/01-macvlan.md`](../03-red/01-macvlan.md) para el patrón completo):

1. Cambiar `network_mode: host` por:
   ```yaml
   networks:
     macvlan_lan:
       ipv4_address: 192.168.1.30
   ```
2. Eliminar la regla `bind interfaces only` o cambiarla a `interfaces = eth0` (ahora `eth0` es interna del netns macvlan, no la del host).
3. Reservar `192.168.1.30` en el DHCP del router.
4. Las reglas `ufw` ya no aplican: el tráfico va a la IP del contenedor, no del host.

### 14.3. Share `[stash]` (read-only, biblioteca de hd5t)

Para acceder ocasionalmente desde el portátil al contenido de Stash (ver [`../09-multimedia/05-stash.md`](../09-multimedia/05-stash.md) cuando esté escrito) sin pasar por la UI web:

1. Añadir al final de `smb.conf`:
   ```ini
   [stash]
       comment       = Biblioteca Stash (RO, hd5t)
       path          = /mnt/hd5t/stash/library
       browseable    = yes
       read only     = yes
       writable      = no
       force user    = homelab
       force group   = media
       valid users   = homelab
   ```
2. Añadir un bind mount en `docker-compose.yml`:
   ```yaml
   - type: bind
     source: /mnt/hd5t/stash/library
     target: /mnt/hd5t/stash/library
     read_only: true
     bind:
       create_host_path: false
   ```
3. `docker compose up -d` (recreate, no sólo reload — hay un volumen nuevo).

### 14.4. Time Machine (Mac) sobre Samba

`fruit` ya está configurado en `[global]`. Para destinar un share como Time Machine:

```ini
[timemachine]
    comment       = Time Machine (Mac)
    path          = /mnt/hd2t/shares/timemachine
    browseable    = yes
    read only     = no
    writable      = yes
    force user    = homelab
    valid users   = homelab
    fruit:time machine = yes
    fruit:time machine max size = 1T
    vfs objects   = catia fruit streams_xattr
```

Crear el directorio: `sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/shares/timemachine`. Reload Samba. Desde macOS, "Preferencias → Time Machine → Seleccionar disco" listará el share.

### 14.5. SMB Multichannel (mejorar throughput con dos NICs)

Sólo aplicable si la Pi tuviera dos interfaces físicas (no es el caso del homelab "stock"). Añadir `server multi channel support = yes` y declarar ambas IPs en `interfaces`. Throughput puede llegar a ~2x si cliente y server tienen 2 NICs en LAN — irrelevante en una Pi 5 con 1 Gbps Ethernet.

---

## 15. Solución de Problemas

| Síntoma | Causa probable | Acción |
|---|---|---|
| Cliente Windows: `\\PI\homelab` falla con "El recurso no se ha podido localizar" | NetBIOS deshabilitado en el cliente o LAN bloquea broadcast UDP 137. | Probar con la IP: `\\192.168.1.10\homelab`. Si funciona, configurar Pi-hole DNS local para `pi.lan → 192.168.1.10` y usar ese nombre. |
| Cliente macOS Finder no lista la Pi en "Red" | Bonjour/mDNS no anunciado por Samba (Samba no es Avahi). | Saltar la sección "Red" y usar `Cmd-K` → `smb://192.168.1.10`. Para anunciado mDNS, instalar `avahi-daemon` en el host o ejecutar un contenedor `avahi`. |
| `NT_STATUS_ACCESS_DENIED` al hacer mount | Password incorrecto, o el cliente está intentando SMB1 (Debian < 9, alguna NAS antigua). | Verificar password con `smbclient //IP/share -U user`. Si client_min_protocol está alto, ese cliente no puede conectar — bajar a `SMB2_02` puntualmente o (mejor) actualizar el cliente. |
| `NT_STATUS_LOGON_FAILURE` aún con password correcto | El usuario UNIX no existe en el contenedor / `force user` apunta a usuario no resoluble. | `docker exec samba id homelab` debe devolver `uid=1000(homelab) gid=1000(homelab)`. La imagen `dockurr/samba` resuelve el UID del fichero `users.conf` con el UNIX `useradd` interno. |
| El cliente conecta pero los ficheros aparecen como dueño `nobody:nogroup` | `force user` mal escrito o el grupo no existe en el contenedor. | `docker exec samba testparm -s | grep -A1 '^\[media\]' ` debe mostrar `force user = homelab`. Reload config. |
| Listing del share funciona pero al copiar grandes (>4 GB) falla con timeout | `aio` desactivado o cifrado SMB3 saturando CPU. | Comprobar `htop` en la Pi durante la copia: si `smbd` toca 100% CPU, considerar relajar `server smb encrypt = desired` (negociado, no obligatorio) — pierdes la garantía de cifrado pero ganas throughput. |
| Tras un upgrade, los clientes Windows obtienen "Acceso denegado" pero el password es correcto | Cambio de cifrado por defecto entre versiones; el cliente Windows 10 antiguo no negocia AES-256. | `server smb encrypt = required` con `server require encryption = yes`: revisar versión exacta de Windows. Para Windows 10 1607, ningún cifrado SMB3 negociado funciona; actualizar el cliente. |
| `docker logs samba` repite "Failed to add user homelab: Password too short" | El password en `users.conf` no tiene los 8 caracteres mínimos exigidos por la imagen. | Regenerar password (§4) con `openssl rand -base64 24` (suficiente). Verificar el contenido del fichero. |
| `passdb.tdb` parece corrupto tras reboot abrupto | TDB en escritura interrumpida. | `docker exec samba tdbtool /var/lib/samba/private/passdb.tdb check`. Si falla: restaurar del último backup Borg o regenerar (`rm passdb.tdb && docker compose restart samba` → entrypoint reaplica `users.conf`). |
| Fail2ban no banea (intentos repetidos no resultan en jail) | El log no llega al filtro (rotación, permisos, ruta), o las líneas no casan el regex. | `sudo fail2ban-regex /mnt/hd2t/services/samba/logs/log.smbd /etc/fail2ban/filter.d/samba.local` debe mostrar matches. Si la ruta del log no existe, revisar §6 (bind mount `/var/log/samba`). |
| Conexión cae periódicamente cada ~30 min | `deadtime = 30` mata sesiones inactivas. | Esperado si el cliente no genera tráfico. Subir a `deadtime = 0` (sin desconexión) si molesta. |
| Sonarr / Radarr no ven los ficheros recién subidos por SMB | `inotify` no se dispara si el fichero llega vía SMB con caching agresivo. | Forzar rescan en Sonarr/Radarr (config → bibliotecas → rescan) o añadir `change notify = no` (último recurso, desactiva la notificación push). |
| `smbclient` desde el propio host funciona pero clientes LAN no | `interfaces = lo eth0` está bien, pero `bind interfaces only` no o `eth0` no es la NIC real (USB Ethernet, etc.). | `ip a` para confirmar nombre de la interfaz, ajustar `interfaces` en `smb.conf`, recreate. |
| Tras añadir `interfaces = lo eth0 tailscale0`, `samba` no arranca | La interfaz `tailscale0` aún no existe al arrancar Docker. | Añadir `depends_on` no funciona con `network_mode: host`. Solución: arrancar `tailscaled` antes (`systemctl enable tailscaled`) y, si persiste, añadir `restart: always` para que el contenedor reintente al levantar `tailscale0`. |
| Mount `/mnt/pi-homelab` con `cifs-utils` falla con `mount error(13): Permission denied` | Permission desencadenada por `seal` cuando el server requiere algo distinto. | Probar `vers=3.0` o quitar `seal`. Verificar logs de Samba: `tail /mnt/hd2t/services/samba/logs/log.<cliente>`. |
| Caracteres acentuados en nombres de fichero salen mal en Windows | `unix charset` o `dos charset` mal alineados. | Añadir `unix charset = UTF-8` y `dos charset = CP850` al `[global]`. Reload. |
| `docker compose down` deja `smbd` zombie en el host (caso `network_mode: host`) | Watchdog mal cerrado por la imagen. | `sudo pkill smbd nmbd ; sudo pkill -9 smbd nmbd`. Revisar logs de la imagen y reportar upstream. |

---

## Referencias

- [Samba — Documentación oficial](https://www.samba.org/samba/docs/)
- [Samba — `smb.conf` man page](https://www.samba.org/samba/docs/current/man-html/smb.conf.5.html)
- [Samba — `smbpasswd` man page](https://www.samba.org/samba/docs/current/man-html/smbpasswd.8.html)
- [Samba — `smbclient` man page](https://www.samba.org/samba/docs/current/man-html/smbclient.1.html)
- [Samba — `testparm` man page](https://www.samba.org/samba/docs/current/man-html/testparm.1.html)
- [Samba — Release notes y CHANGELOG](https://www.samba.org/samba/history/)
- [`dockurr/samba` (imagen Docker)](https://github.com/dockur/samba)
- [`dockurr/samba` (Docker Hub)](https://hub.docker.com/r/dockurr/samba)
- [Samba — `vfs_fruit` (interoperabilidad macOS)](https://www.samba.org/samba/docs/current/man-html/vfs_fruit.8.html)
- [Samba — `vfs_streams_xattr` (NTFS Alternate Data Streams)](https://www.samba.org/samba/docs/current/man-html/vfs_streams_xattr.8.html)
- [Linux `cifs-utils` — `mount.cifs` man page](https://manpages.debian.org/bookworm/cifs-utils/mount.cifs.8.en.html)
- [Microsoft — SMB1 deprecated y desinstalación](https://learn.microsoft.com/en-us/windows-server/storage/file-server/troubleshoot/detect-enable-and-disable-smbv1-v2-v3)
- [Fail2ban — Filtros y `failregex`](https://github.com/fail2ban/fail2ban/wiki/Developing-Filters)
