# Samba

## Descripción

Cerrado `01-nextcloud.md`, los ficheros de los miembros del hogar viven en `hd2t` y se sincronizan vía clientes (escritorio, móvil, WebDAV). Eso resuelve el caso "tener mi carpeta en todos mis dispositivos", pero **no** resuelve dos casos cotidianos:

1. Abrir un fichero remoto **sin sincronizarlo**: editar un PDF directamente en `hd2t` desde un portátil sin instalar Nextcloud Desktop, copiar un vídeo de 12 GiB de un disco USB al *NAS* arrastrándolo en el explorador, montar la carpeta de música como una unidad para que Foobar2000/Audacious lean canciones por red.
2. Que **Windows, macOS y Linux** descubran y monten esos directorios con sus herramientas nativas (`File Explorer → Network`, `Finder → Network`, `Files → Other Locations → Connect to Server`), sin clientes de terceros y con el mismo protocolo de toda la vida (**SMB**).

Este documento despliega **Samba** como servidor de ficheros SMB/CIFS del homelab. Su rol concreto:

- Exponer **carpetas seleccionadas** de `hd2t` y `hd5t` por SMB3 sobre TCP/445, accesibles desde cualquier sistema operativo doméstico.
- Servir como **transporte rápido para ficheros grandes** dentro de la LAN (vídeos, ISOs, backups manuales, transferencias entre PCs), donde Nextcloud queda pesado por la cadena `cliente desktop → BD → filecache → upload chunked`.
- Permitir a otros servicios del homelab (Jellyfin, los `*arr`, Audiobookshelf, Calibre-Web…) **mantener su biblioteca multimedia local en `/mnt/hd2t/media/`** y, a la vez, que el operador la rellene desde otro PC sin SSH ni `scp` ni clientes especiales.
- Ser una superficie **bien acotada**: shares con permisos explícitos, autenticación obligatoria, sin guest, SMB1 deshabilitado, expuesto **solo** a la LAN y al tailnet.

Estará compuesto por **un único contenedor**:

- `samba` — imagen `ghcr.io/crazymax/samba:4.21.2` (Samba upstream sobre Alpine, ARM64 multi-arch, integra `wsdd2` para descubrimiento Windows y `avahi`/mDNS para Bonjour de macOS).

Lo que este documento **no** decide:

- **Active Directory / NT Domain Controller** (`samba-ad-dc`). Una Pi haciendo de DC para 1–3 clientes Windows es radicalmente desproporcionado. Los hogares de este tamaño no tienen Group Policy, ni Kerberos, ni un dominio que mantener.
- **Replicación con un segundo nodo** (`drbd`, `ctdb`). Sin segundo nodo.
- **Cuotas por usuario** (`vfs_default_quota`). Reabrible si en el futuro hay >5 usuarios; hoy se controla con espacio total del disco y vigilancia.
- **ACLs POSIX/NT extendidas** (`vfs_acl_xattr`). El modelo `owner:group:other` del FS Linux es suficiente para los shares planteados; `vfs_acl_xattr` se reabre solo si se necesitan permisos heredados a la Windows.
- **Autenticación contra LDAP/AD** o **vfs_recycle** con papelera por usuario. Reabrible cuando exista una identidad central (`Authelia` con backend LDAP) y haya usuarios que justifiquen el coste.
- **Time Machine** sobre Samba para backups de macOS (`fruit:time machine = yes` + `vfs_fruit`). Reabrible en una iteración futura si algún Mac del hogar lo necesita; añade complicación con `mDNS`/`AFP discovery` y un share dedicado con metadata especial.
- **`smb.conf` generado por la app**. La imagen de `crazymax/samba` permite *o bien* gestión por env vars *o bien* un `smb.conf` montado. Aquí se elige **`smb.conf` versionado en git** porque es más explícito y revisable que un puñado de variables `SAMBA_VOLUME_CONFIG_x` con sintaxis propietaria.

Cuando este documento se haya aplicado, el operador puede:

- Desde Windows 10/11: `Win+R` → `\\nas.lan\documentos`, introducir credenciales del usuario Samba, ver y editar ficheros.
- Desde macOS: Finder → `Cmd+K` → `smb://nas.lan/multimedia`, montar la biblioteca de Stash en modo lectura para inspección rápida.
- Desde Linux (GNOME): `Files` → `Other Locations` → `nas.lan` aparece tras WS-Discovery / mDNS, o teclear directamente `smb://nas.lan/`.
- Desde la consola: `smbclient -L //nas.lan -U homelab` lista los shares disponibles; `mount -t cifs //nas.lan/media /mnt/nas-media -o credentials=/root/.smbcreds,vers=3` los monta permanentemente.
- Verificar que **Samba no se publica por internet**: el puerto 445 solo escucha en la red de la LAN del router.

> **Recordatorio de alcance**: Samba expone **solo** TCP/445 (SMB3 sobre TCP). El antiguo NetBIOS (UDP/137-138, TCP/139) queda **desactivado**. No hay reglas de port-forwarding en el router; SMB sale a internet **es** una superficie de ataque histórica documentada (WannaCry, EternalBlue), aquí solo está disponible en LAN y vía Tailscale.

---

## Requisitos Previos

- **Fase 0** completa: `/mnt/hd2t` y `/mnt/hd5t` montados, `LABEL`s correctas, `noatime,nofail` en `fstab`.
- **Fase 1** completa, en particular:
  - Usuario `homelab` con `uid=1000, gid=1000`.
  - Grupo `media` con `gid=1100` y `homelab` miembro de `media`.
  - Estructura de directorios creada por el script `00-create-homelab-tree.sh` (`/mnt/hd2t/apps/samba/config` ya existe).
  - **`ufw` activo con política `deny incoming`**: hay que añadir la regla para `:445/tcp` antes de levantar el contenedor (sección "Firewall del host").
- **Fase 2** completa: Docker Engine y Compose v2; red `homelab` en `172.30.10.0/24`; convenciones `stacks/<svc>/`; `.env` global con `TZ`, `PUID=1000`, `PGID=1000`, `PGID_MEDIA=1100`, `DOMAIN_LAN=lan`, `DOMAIN_TS` opcional.
- **Fase 3** completa: Pi-hole con el comodín `address=/lan/192.168.1.10` (cubre automáticamente `nas.${DOMAIN_LAN}` sin tocar Pi-hole). Caddy **no interviene aquí**: Samba **no** es HTTP.

Comprobaciones rápidas:

```bash
# El usuario homelab existe y está en `media`
id homelab
# uid=1000(homelab) gid=1000(homelab) groups=1000(homelab),1100(media),...

# Los discos están montados
findmnt /mnt/hd2t /mnt/hd5t

# Espacio en hd2t y hd5t
df -h /mnt/hd2t /mnt/hd5t

# Nada escucha aún en :445
sudo ss -tlnp | grep ':445' || echo 'libre'

# La LAN resuelve nas.lan al IP de la Pi (gracias al comodín de Pi-hole)
dig +short nas.lan @192.168.1.2
# 192.168.1.10
```

---

## Decisión: imagen Samba

| Imagen | Pros | Contras |
|---|---|---|
| `dperson/samba` | La más popular en tutoriales antiguos. Configuración 100 % por env vars. | **No publica tags semver**: solo `latest`, lo cual rompe la regla del homelab ("nunca `latest`"). Mantenimiento intermitente. |
| `ghcr.io/servercontainers/samba` | Muy modular, separación `smbd`/`wsdd`/`avahi`, soporta auto-aprovisionamiento por env. | Sintaxis de variables propietaria (`SAMBA_VOLUME_CONFIG_xxx`) que mezcla servicio y orquestación. La imagen requiere `--privileged` para Avahi cuando se usa fuera de `host` networking. |
| **`ghcr.io/crazymax/samba`** | Tags semver pinneables (`4.21.2`, `4.20`, `latest`). ARM64 first-class. **Acepta un `smb.conf` montado** o env vars; aquí elegimos `smb.conf`. Integra `wsdd2` (descubrimiento Windows 10+) y opcionalmente `avahi-daemon`. Mantenida por Crazymax (autor de varias imágenes pin del homelab). | Imagen extra (~70 MiB), pero idéntica a `samba` upstream sobre Alpine. |
| `samba-ad-dc` (controlador de dominio) | Active Directory completo. | Sobreingeniería absoluta para 1–3 dispositivos. Descartado. |

| Decisión | Justificación |
|---|---|
| **`ghcr.io/crazymax/samba:4.21.2`** | Tag semver explícito, soporte ARM64 verificado, configuración por `smb.conf` (auditable en git), integra `wsdd2` para que Windows muestre `\\nas` en la red. **No** `latest`: los upgrades de major de Samba (4.x → 4.y) traen cambios en parámetros (`vfs_objects`, `min protocol`, etc.); decidir cuándo subir es responsabilidad explícita. |
| **`smb.conf` montado, no env vars** | Debugar `[global]` desde un fichero versionado en git es trivial; reproducir la misma config con env propietarias multilínea no. |

> **Sobre Samba 4.21**: incluye SMB3 con cifrado en tránsito (`smb encrypt = desired`), parche definitivo de la familia *Logon*, y mejoras del *async I/O* relevantes para discos USB. El último mayor sin estos parches es 4.18; conviene estar **por encima**.

---

## Decisión: modo de red del contenedor

| Modo | Pros | Contras | Veredicto |
|---|---|---|---|
| `network_mode: host` | Samba ve la NIC `eth0` directamente; broadcast WS-Discovery y mDNS funcionan sin trucos. | Rompe el aislamiento Docker; `samba` ya no está en la red `homelab` y no puede hablar con otros contenedores por DNS interno (no relevante aquí, pero sí limita futuras extensiones). Conflictos de puerto con cualquier otro daemon del host que use 445. | Aceptable, pero no necesario. |
| Macvlan dedicado (IP propia tipo `192.168.1.5`) | El contenedor parece un host más en la LAN, descubrimiento limpio. | Consume un slot de IP del bloque reservado y obliga a configurar la *macvlan-shim* del host. Anunciado en `docs/03-red/01-macvlan.md` como "slot libre", se puede reabrir si SMB exige más. | Reservado, no aplicado hoy. |
| **Bridge `homelab` + `ports: 445:445/tcp`** | Coherente con el resto del homelab. Pi-hole resuelve `nas.lan` → IP de la Pi y SMB conecta directamente. WS-Discovery funciona por separado vía `wsdd2` que el contenedor ejecuta. | Para `wsdd2` y `avahi` la propagación de broadcast a la LAN requiere que el contenedor reenvíe a través del **host network namespace**: `wsdd2` se ejecuta con `--network=host` *en su propio contenedor* o se delega al host. La imagen `crazymax/samba` resuelve esto con un flag `--shareable-host-network=false` por defecto, aceptando que la sección "Discovery" se documenta a parte. | **Aceptado** para SMB; ver "Descubrimiento de red" más abajo para cómo habilitar visibility en Windows/macOS sin caer a host networking. |

| Decisión | Justificación |
|---|---|
| **Bridge con `ports: 445:445/tcp`** | Mantener Samba dentro de la red `homelab` simplifica logs, healthchecks y firewall (basta `ufw allow from 192.168.1.0/24 to any port 445 proto tcp`). El descubrimiento por *Network Neighborhood* es una conveniencia, no un requisito: los clientes pueden y deben usar `\\nas.lan` o `smb://nas.lan/`, que sí está cubierto por DNS de Pi-hole. |
| **`wsdd2` opcional con contenedor lateral en `host` network** | Si el operador exige que Windows muestre el icono `nas` en `Explorer → Network`, se documenta un *sidecar* `jonasped/wsdd:latest` en `network_mode: host` (sección "Descubrimiento de red"). Es opt-in. |

> **`139` y NetBIOS**: **NO** se publica `139/tcp` ni `137-138/udp`. SMB1 lleva desde 2017 oficialmente *deprecated* y Microsoft lo desactiva por defecto en Windows 10+. Servir SMB1 por NetBIOS es una pasarela a *EternalBlue*. La regla aquí es: SMB **solo** sobre TCP/445, SMB **mínimo** versión 2, preferencia 3.

---

## Decisión: autenticación, usuarios y `guest`

Samba soporta varios backends de auth. Para un homelab pequeño:

| Backend | Pros | Contras | Veredicto |
|---|---|---|---|
| **`tdbsam` (default)** — base de datos local Samba con usuarios y password hashes. | Cero infraestructura. Suficiente para 1–10 usuarios. Independiente del PAM del host. | No federa con Authelia; el operador mantiene dos contraseñas (Authelia y Samba). | **Aceptado**. |
| `passdb backend = ldapsam:ldap://...` (LDAP) | SSO real con un IdP externo. | No hay IdP LDAP en el homelab (Authelia no lo expone hoy). | Reabrible. |
| PAM (auth contra `/etc/passwd` del host) | Una sola contraseña con SSH. | Acopla SSH y SMB; un compromiso de uno comprometería el otro. | Descartado. |
| `guest ok = yes` (acceso anónimo) | UX trivial. | Cualquiera dentro de la LAN o en el tailnet entra sin credenciales. SMB sin autenticación en una red familiar es aceptable solo si los datos son irrelevantes; los datos del homelab **no** lo son. | Descartado. |

| Decisión | Justificación |
|---|---|
| **`tdbsam` con usuarios manuales** | Definidos en `smb.conf` (allow list por share) y con su hash en la `tdb` interna. Se crean con `pdbedit -a -u <login>` desde dentro del contenedor. |
| **`map to guest = Never`** | Cualquier intento sin credenciales válidas devuelve `NT_STATUS_LOGON_FAILURE`. Sin `guest`, ni siquiera para un share *público*. |
| **Una cuenta por humano**, no una compartida | `homelab`, `nataly`, `marc` (ejemplos). Permite trazar quién subió qué en logs. **Sin** un usuario `family` compartido con la misma password rotada en cinco dispositivos. |
| **Mismo UID/GID que en el host** | Las cuentas Samba se mapean a `uid=1000:gid=1000` (homelab) o a usuarios POSIX adicionales que se creen en el host (`useradd -u 1001 nataly`). El propietario de los ficheros escritos vía Samba es el UID del usuario Samba, lo cual evita que un fichero subido vía SMB termine como `nobody:nogroup`. |

> **Sobre crear usuarios POSIX adicionales**: para el caso "una cuenta por humano", cada login Samba existe como **usuario Linux del host** (sin shell) **y** como entrada `tdbsam`. La razón: Samba mapea `getpwnam(login)` → UID del FS para los `chown`. Sin usuario POSIX, los ficheros se quedan con `uid=99 nobody`. Comando idiomático:
> ```bash
> sudo useradd --no-create-home --shell /usr/sbin/nologin --uid 1001 --gid 1100 nataly
> sudo useradd --no-create-home --shell /usr/sbin/nologin --uid 1002 --gid 1100 marc
> ```
> El `gid=1100` (`media`) es el del grupo compartido del homelab; cada humano colabora sobre `media/` con permisos de grupo.

---

## Decisión: shares disponibles y permisos

| Share | Ruta en disco | Acceso por defecto | Justificación |
|---|---|---|---|
| `documentos` | `/mnt/hd2t/shares/documentos` | rw para `homelab` y miembros del grupo `users-samba`. | "Carpeta del NAS clásico": adjuntos, PDFs, papeles, exportaciones. Crece poco; backup diario. |
| `escritorio-compartido` | `/mnt/hd2t/shares/escritorio` | rw para todos los usuarios Samba autenticados. | Buzón compartido; nada crítico. Rotación automática (no documentada aquí, opcional). |
| `media` | `/mnt/hd2t/media/` | **ro** por defecto; rw activable por usuario en `smb.conf`. | Biblioteca multimedia compartida (películas, series, música, libros, podcasts). Los `*arr` y Sonarr/Radarr (Fase 10) escriben aquí. Permitir rw a humanos genera *race conditions* de renombrado entre Sonarr y un explorador de Windows. **Por defecto ro** desde Samba; rw solo para el usuario `homelab` (operador) cuando hay que arreglar algo a mano. |
| `multimedia-stash` | `/mnt/hd5t/stash/library/` | **ro** estricto. | La biblioteca de Stash está en `hd5t` y la gestiona el propio Stash. Que Samba la sirva read-only es útil para inspección puntual; rw está prohibido. Reabrible solo si el operador documenta cómo se rotará/renombra sin romper el catálogo. |
| `home-<user>` | `/mnt/hd2t/shares/home/<user>` | rw exclusivo para `<user>`. | Carpeta privada por humano del hogar. **No confundir con Nextcloud**: Samba sirve "el escritorio remoto", Nextcloud "la nube sincronizada". Son superficies distintas para el mismo dato si se quiere; aquí están **separadas** a propósito. |
| `backups-restore` | `/mnt/hd2t/backups/exports` | **ro** para grupo `homelab`. | Para restaurar un fichero suelto desde un dump de Borg sin rebuscar por SSH. La carpeta la rellena Borgmatic en Fase 7 cuando se pide un restore puntual. |

| Decisión | Justificación |
|---|---|
| **Nuevo prefijo `/mnt/hd2t/shares/`** | El árbol del homelab actual no tiene shares Samba dedicados (`apps/`, `media/`, `downloads/`, `backups/`). Crear `/mnt/hd2t/shares/` separa "datos servidos por SMB" de "datos servidos por una app concreta". |
| **`media/` se reusa, no se duplica** | Samba apunta a la misma carpeta que Jellyfin/Sonarr/Radarr leen y escriben. Como Samba es **read-only por defecto** sobre `media/`, no introduce nuevas escrituras concurrentes. El operador (usuario `homelab` con UID 1000) queda como **único** humano con permiso de escritura SMB sobre `media/`, restringido a tareas de mantenimiento (renombrar manualmente una colección, etc.). |
| **`hd5t/stash/library/` *solo* read-only** | Es un dataset administrado por Stash. Modificar nombres por SMB rompe el catálogo. Read-only exclusivo. |
| **No share global a `/mnt/hd2t`** | Tentación: un share `nas` que apunte a la raíz. **Descartado**: expone `apps/` (BBDD, configs, secretos), `backups/borg/` (repos cifrados pero metadatos legibles), `swap/` (huellas RAM). Granularidad share-a-share es la diferencia entre "una mala password en Windows = pérdida total" y "una mala password = un usuario pierde su carpeta". |

---

## Decisión: descubrimiento de red (WS-Discovery / mDNS)

Sin descubrimiento, las URIs `\\nas.lan` y `smb://nas.lan/` siguen funcionando: el cliente solo necesita el hostname y Pi-hole lo resuelve. Pero los usuarios del hogar no leen documentación; abren `Explorer → Network` y esperan ver un icono "NAS".

| Mecanismo | Para qué cliente | Cómo se habilita |
|---|---|---|
| **WS-Discovery** (`ws-discovery`, `wsdd`) | Windows 10/11 (sustituyó a NetBIOS Browser). | Daemon `wsdd2`; en Linux el paquete homónimo o el contenedor `jonasped/wsdd`. **Necesita `network_mode: host`** o multicast routing para que los anuncios `urn:Microsoft Windows Peer Name Resolution Protocol` lleguen al broadcast LAN. |
| **mDNS / Bonjour** (`_smb._tcp.local`) | macOS Finder, GNOME Files. | `avahi-daemon`. Igual problema con multicast → mejor un sidecar en `network_mode: host` o el `avahi` del propio host. |
| **NetBIOS Name Service** (UDP/137) | Windows 7 y anteriores; clientes legacy. | **Descartado** por estar atado a SMB1 y al pasado. |

| Decisión | Justificación |
|---|---|
| **Sidecar `wsdd2` en `network_mode: host`** | Contenedor minúsculo (~10 MiB) que solo emite anuncios WS-Discovery. Aislado de Samba: si falla, SMB sigue funcionando. Imagen `ghcr.io/crazymax/samba:4.21.2` ya incluye `wsdd2` corriendo dentro del propio contenedor; cuando el contenedor está en bridge, los anuncios **no** salen al LAN segment. La opción operativa es **lanzar un segundo contenedor (`wsdd`)** específicamente en host network. |
| **Avahi: aprovechar el del host** | Raspberry Pi OS Lite trae `avahi-daemon` desactivado pero instalable (`apt install avahi-daemon`). Activar el del host y publicar un `_smb._tcp` a través de un fichero `/etc/avahi/services/samba.service` evita un sidecar más y permite que Mac y Linux "vean" el NAS. |

> **Compromiso elegido**: Samba en bridge + `wsdd` sidecar en host + Avahi del host con un `samba.service` declarativo. Es la combinación que da SMB **funcional** en Windows, macOS y Linux con dos pequeñas concesiones a `host` networking que se aíslan en componentes pequeños y separados del propio Samba.

---

## Decisión: cifrado en tránsito y firma SMB

| Parámetro | Valor | Justificación |
|---|---|---|
| `client min protocol = SMB2_10`, `server min protocol = SMB2_10` | Bloquea SMB1. SMB2_10 es el mínimo de Windows 7 SP1 (2011). | |
| `client max protocol = SMB3_11`, `server max protocol = SMB3_11` | Permite SMB 3.1.1 (Windows 10+, kernel ≥ 4.11). | |
| `smb encrypt = desired` | Habla cifrado SMB3 (AES-128-CCM/GCM) cuando el cliente lo soporta; no rompe a Linux antiguo o macOS Time Machine. | El upgrade a `required` rompería clientes Linux con `cifs-utils` antiguo. |
| `server signing = mandatory` | Firma todos los paquetes (anti-MitM en LAN). Ralentiza ~5 % en SMB2; SMB3 firma con AES-CMAC, sin coste medible en una Pi 5. | |
| `restrict anonymous = 2` | Niega listing anónimo de shares. Junto con `map to guest = Never` cierra la enumeración. | |
| `disable netbios = yes` | Apaga el subsistema NetBIOS al completo: `nmbd` no arranca. SMB sirve **solo** sobre TCP/445. | |

---

## Stack: `stacks/samba/`

### Layout en disco

| Ruta | Soporte | Contenido |
|---|---|---|
| `stacks/samba/docker-compose.yml` | microSD (git) | Stack (servicios `samba` y `wsdd`). |
| `stacks/samba/.env.example` | microSD (git) | Plantilla con `SAMBA_LOG_LEVEL`, etc. |
| `stacks/samba/conf/smb.conf` | microSD (git) | Configuración versionada de Samba (sin credenciales). |
| `/mnt/hd2t/apps/samba/config/users.tdb`, `secrets.tdb` | hd2t | Base de datos `tdbsam` con usuarios y hashes. **Persistente**, no versionable. |
| `/mnt/hd2t/apps/samba/config/private/` | hd2t | Otros TDBs internos (`gencache.tdb`, `account_policy.tdb`, …). |
| `/mnt/hd2t/apps/samba/log/` | hd2t | `log.smbd`, `log.<cliente>`. Rotados por Samba a 50 MB. |
| `/mnt/hd2t/shares/documentos/` | hd2t | Share `documentos`. `homelab:users-samba 2770`. |
| `/mnt/hd2t/shares/escritorio/` | hd2t | Share `escritorio-compartido`. `homelab:users-samba 2770`. |
| `/mnt/hd2t/shares/home/<user>/` | hd2t | Share `home-<user>`. `<user>:<user> 0700`. |
| `/mnt/hd2t/media/` (existente) | hd2t | Share `media`. `homelab:media 2770` (modificado por Samba a `2750` para `force readonly` desde clientes no-homelab). |
| `/mnt/hd5t/stash/library/` (existente) | hd5t | Share `multimedia-stash`. `homelab:homelab 0750`, ro. |
| `/mnt/hd2t/backups/exports/` | hd2t | Share `backups-restore`. Rellenado por Borgmatic (Fase 7). |

### `stacks/samba/conf/smb.conf`

```ini
# /etc/samba/smb.conf — Samba del homelab.
# Documentado en docs/06-almacenamiento/02-samba.md.
#
# Cambios aquí requieren `docker compose -f stacks/samba/docker-compose.yml restart samba`
# o un SIGHUP al smbd (Samba recarga `smb.conf` cada `change notify time` segundos
# automáticamente, pero recargar a mano es más predecible).

[global]
    # --- Identidad y dominio ---
    workgroup = WORKGROUP
    server string = Homelab NAS (Pi 5)
    netbios name = NAS
    server role = standalone server

    # --- Protocolo ---
    server min protocol = SMB2_10
    server max protocol = SMB3_11
    client min protocol = SMB2_10
    client max protocol = SMB3_11
    smb encrypt = desired
    server signing = mandatory
    disable netbios = yes
    smb ports = 445

    # --- Auth ---
    security = user
    passdb backend = tdbsam
    map to guest = Never
    restrict anonymous = 2
    null passwords = no
    obey pam restrictions = no

    # --- Permisos por defecto al escribir ---
    create mask = 0660
    directory mask = 2770
    force create mode = 0660
    force directory mode = 2770

    # --- Charset / portabilidad ---
    unix charset = UTF-8
    dos charset = CP932

    # --- Rendimiento ---
    socket options = TCP_NODELAY IPTOS_LOWDELAY SO_RCVBUF=65536 SO_SNDBUF=65536
    use sendfile = yes
    aio read size = 16384
    aio write size = 16384

    # --- Logging ---
    log file = /var/log/samba/log.%m
    max log size = 51200    # 50 MiB; Samba rota cuando supera.
    log level = 1 auth:2

    # --- Hardening ---
    hosts allow = 127.0.0.1 192.168.1.0/24 100.64.0.0/10 172.30.10.0/24
    hosts deny = ALL
    # 100.64.0.0/10 cubre la subred CGNAT de Tailscale (tailnet).
    # 172.30.10.0/24 es la red Docker interna (innecesaria para SMB,
    # útil si algún día un contenedor del homelab monta el share por loopback).

    # --- VFS módulos ---
    # vfs objects vacío en global; cada share lo activa si lo necesita.

# =====================================================================
# Shares
# =====================================================================

[documentos]
    comment = Documentos del homelab (rw)
    path = /shares/documentos
    valid users = @users-samba
    read only = no
    browseable = yes
    guest ok = no
    create mask = 0660
    directory mask = 2770
    force user = homelab
    force group = users-samba

[escritorio-compartido]
    comment = Escritorio compartido (buzón rw)
    path = /shares/escritorio
    valid users = @users-samba
    read only = no
    browseable = yes
    guest ok = no

# Carpetas privadas por humano. Una entrada por usuario.
# Notar `valid users = %S`: %S se sustituye por el nombre del share,
# que es el del usuario. Solo el dueño accede.
[homelab]
    comment = Carpeta privada de homelab
    path = /shares/home/homelab
    valid users = homelab
    read only = no
    browseable = no
    guest ok = no
    create mask = 0600
    directory mask = 0700
    force user = homelab
    force group = homelab

# Para añadir más usuarios privados duplicar la sección anterior con
# el login correspondiente. La carpeta /shares/home/<user>/ debe existir
# con `chown <user>:<user>` y modo 0700 antes de exportarla.

[media]
    comment = Biblioteca multimedia (ro por defecto)
    path = /media
    valid users = @users-samba
    read list   = @users-samba
    write list  = homelab
    read only = yes
    browseable = yes
    guest ok = no

[multimedia-stash]
    comment = Biblioteca Stash (ro estricto)
    path = /multimedia-stash
    valid users = homelab
    read only = yes
    browseable = yes
    guest ok = no

[backups-restore]
    comment = Restauraciones puntuales de Borg
    path = /backups-restore
    valid users = homelab
    read only = yes
    browseable = no
    guest ok = no
```

> **`force user = homelab`**: cuando alguien escribe vía SMB en `documentos`, Samba ejecuta el `creat()` con UID 1000 (homelab) en vez del UID que `tdbsam` resolvió para el usuario que se autenticó. Útil porque garantiza que **todos** los ficheros del share son propiedad de `homelab` y los puede leer Borg sin ACLs especiales. La trazabilidad de "quién subió" sigue en los logs de Samba (`log level = 1 auth:2`).

> **`@users-samba`**: alias de grupo POSIX que reúne a todos los humanos del homelab. Se crea en el host con `groupadd users-samba` y se añaden los usuarios con `usermod -aG users-samba <login>`. Permite cambiar la *whitelist* de un share editando solo el grupo, no el `smb.conf`.

> **`hosts allow`**: lista permisiva de subredes. La regla del *hosts allow/deny* es: si `hosts deny = ALL` y `hosts allow = ...`, **solo** las IPs en `hosts allow` pueden hablar con `smbd`. Es **defensa en profundidad** sobre `ufw`; si algún día se mueve la Pi de red o se cambia la regla de firewall, Samba sigue rechazando IPs externas a la LAN/tailnet.

### `stacks/samba/docker-compose.yml`

```yaml
# Samba — servidor de ficheros SMB del homelab.
# Documentado en docs/06-almacenamiento/02-samba.md.

name: samba

services:
  samba:
    image: ghcr.io/crazymax/samba:4.21.2
    container_name: samba
    hostname: nas
    restart: unless-stopped

    # Bridge network + publish 445/tcp en la IP de la Pi.
    # NO se publica 137-138/udp ni 139/tcp (NetBIOS, SMB1).
    ports:
      - "445:445/tcp"

    # Capacidades mínimas: Samba upstream sugiere CAP_SYS_ADMIN en escenarios
    # con vfs_acl_xattr; sin esos vfs basta con las default y el contenedor.
    cap_add:
      - SETUID
      - SETGID
      - CHOWN
      - DAC_OVERRIDE

    environment:
      TZ: ${TZ}

    volumes:
      # smb.conf versionado: read-only para el contenedor.
      - ./conf/smb.conf:/etc/samba/smb.conf:ro
      # Estado persistente de Samba (tdbsam, secrets, gencache).
      - /mnt/hd2t/apps/samba/config:/var/lib/samba
      # Logs.
      - /mnt/hd2t/apps/samba/log:/var/log/samba
      # Shares — bind mounts en lectura/escritura según `smb.conf` decida.
      - /mnt/hd2t/shares:/shares
      - /mnt/hd2t/media:/media
      - /mnt/hd5t/stash/library:/multimedia-stash:ro
      - /mnt/hd2t/backups/exports:/backups-restore:ro

    networks:
      - homelab

    healthcheck:
      # smbclient se conecta a sí mismo y lista shares vacíos (-N = sin auth):
      # con map_to_guest=Never devuelve LOGON_FAILURE, lo cual es OK porque
      # demuestra que smbd está vivo y rechaza el guest.
      test:
        - "CMD-SHELL"
        - "smbclient -N -L //127.0.0.1 2>&1 | grep -qE 'NT_STATUS|Sharename'"
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 30s

    labels:
      homelab.role: "file-share"
      homelab.backup: "true"
      # Samba *minor* upgrades son seguros; Watchtower puede aplicarlos,
      # pero la regla del homelab es: solo se actualiza el digest del tag
      # pinneado (no el tag), así que Watchtower no debería rotar de 4.21
      # a 4.22 automáticamente.
      com.centurylinklabs.watchtower.enable: "true"

  # Sidecar para WS-Discovery: hace que Windows 10/11 muestre `nas` en
  # `Explorer → Network`. Aislado en network_mode: host porque el protocolo
  # WS-Discovery requiere multicast hacia la LAN.
  # Si no se necesita (todos los humanos teclean \\nas.lan), se puede
  # comentar este bloque entero.
  wsdd:
    image: ghcr.io/jonasped/wsdd:latest
    container_name: wsdd
    hostname: nas
    restart: unless-stopped
    network_mode: host
    environment:
      TZ: ${TZ}
      HOSTNAME: nas
      WORKGROUP: WORKGROUP
    labels:
      homelab.role: "file-share-discovery"
      homelab.backup: "false"
      com.centurylinklabs.watchtower.enable: "true"

networks:
  homelab:
    external: true
```

> **¿Por qué `hostname: nas` y no `samba`?** El nombre "NetBIOS" que ven los clientes Windows es el `netbios name` del `smb.conf` (`NAS`). Que el contenedor también se llame `nas` evita confusión cuando se inspeccionan logs y mDNS. Para hablar con el contenedor desde otros stacks por DNS interno, sigue valiendo el `container_name: samba`.

> **`stacks/samba/.env.example`** se reduce a casi nada (la mayoría de la config está en `smb.conf`):
> ```bash
> # stacks/samba/.env.example
> # TZ, PUID, PGID vienen del .env GLOBAL.
> # No hay credenciales en este fichero: las contraseñas Samba viven en
> # /mnt/hd2t/apps/samba/config/passdb.tdb (creadas con `pdbedit`).
> ```

### Crear directorios persistentes y desplegar

```bash
# 1) Crear el grupo POSIX para usuarios de Samba.
sudo groupadd --gid 1110 users-samba
sudo usermod -aG users-samba homelab

# 2) Crear los usuarios POSIX adicionales del hogar (ejemplos).
sudo useradd --no-create-home --shell /usr/sbin/nologin --uid 1001 --gid 1110 nataly
sudo useradd --no-create-home --shell /usr/sbin/nologin --uid 1002 --gid 1110 marc
sudo usermod -aG media nataly marc    # acceso al grupo media para `media/` ro

# 3) Directorios de shares (los de apps/samba ya los creó el script de Fase 1).
sudo install -d -o homelab -g users-samba -m 2770 /mnt/hd2t/shares
sudo install -d -o homelab -g users-samba -m 2770 /mnt/hd2t/shares/documentos
sudo install -d -o homelab -g users-samba -m 2770 /mnt/hd2t/shares/escritorio
sudo install -d -o homelab -g homelab     -m 0750 /mnt/hd2t/shares/home
sudo install -d -o homelab -g homelab     -m 0700 /mnt/hd2t/shares/home/homelab
sudo install -d -o nataly  -g nataly      -m 0700 /mnt/hd2t/shares/home/nataly
sudo install -d -o marc    -g marc        -m 0700 /mnt/hd2t/shares/home/marc

# 4) backups/exports (Borgmatic lo rellena en Fase 7; aquí solo se reserva).
sudo install -d -o homelab -g homelab -m 0750 /mnt/hd2t/backups/exports

# 5) Logs y estado de Samba.
sudo install -d -o root -g root -m 0750 /mnt/hd2t/apps/samba/config
sudo install -d -o root -g root -m 0750 /mnt/hd2t/apps/samba/log

# 6) Copiar smb.conf y .env.
cd /home/homelab/homelab
mkdir -p stacks/samba/conf
cp stacks/samba/.env.example stacks/samba/.env   # vacío por ahora
chmod 0644 stacks/samba/conf/smb.conf

# 7) Validar smb.conf antes de arrancar.
docker run --rm \
    -v "$PWD/stacks/samba/conf/smb.conf:/etc/samba/smb.conf:ro" \
    --entrypoint testparm \
    ghcr.io/crazymax/samba:4.21.2 -s
# Loaded services file OK.
# Server role: ROLE_STANDALONE

# 8) Arrancar.
docker compose \
    -f stacks/samba/docker-compose.yml \
    --env-file .env --env-file stacks/samba/.env \
    up -d

# 9) Crear los usuarios Samba (uno por humano).
# La password se pide interactivamente.
docker exec -it samba pdbedit -a -u homelab
docker exec -it samba pdbedit -a -u nataly
docker exec -it samba pdbedit -a -u marc

# 10) Confirmar la lista.
docker exec samba pdbedit -L
# homelab:1000:Homelab Operator
# nataly:1001:
# marc:1002:
```

Tras `up -d`, el log debería mostrar:

```bash
docker logs samba --tail 30
# [2025-04-28 12:00:00.000] daemon started
# [2025-04-28 12:00:00.012] smbd version 4.21.2 started.
# [2025-04-28 12:00:00.013] Listening on TCP port 445
# [2025-04-28 12:00:00.020] WSDD started
```

---

## Configuración

### 1) Firewall del host: abrir 445/tcp en LAN y tailnet

```bash
LAN=192.168.1.0/24
sudo ufw allow from "$LAN" to any port 445 proto tcp comment 'SMB desde LAN'

# Opcional: permitir SMB desde el tailnet (al activar Tailscale en Fase 3).
# La regla idiomática es "allow in on tailscale0", no por subnet,
# porque la 100.64.0.0/10 puede cambiar.
sudo ufw allow in on tailscale0 to any port 445 proto tcp comment 'SMB via Tailscale'

sudo ufw reload
sudo ufw status numbered | grep -E '445|SMB'
```

> **Nada de `0.0.0.0`**: ni desde la WAN ni desde la propia loopback se publica al exterior. El `ufw allow from <LAN>` es taxonómicamente "allow in any iface from LAN", lo cual es exactamente lo que se quiere: la LAN sí, internet no.

### 2) Avahi en el host (mDNS para macOS y Linux)

```bash
sudo apt install -y avahi-daemon avahi-utils

# Publicar el servicio _smb._tcp con el nombre amistoso "Homelab NAS".
sudo tee /etc/avahi/services/samba.service >/dev/null <<'EOF'
<?xml version="1.0" standalone='no'?>
<!DOCTYPE service-group SYSTEM "avahi-service.dtd">
<service-group>
  <name replace-wildcards="yes">Homelab NAS (%h)</name>
  <service>
    <type>_smb._tcp</type>
    <port>445</port>
  </service>
  <service>
    <type>_device-info._tcp</type>
    <port>0</port>
    <txt-record>model=RackMac</txt-record>
  </service>
</service-group>
EOF

sudo systemctl enable --now avahi-daemon

# Verificar la publicación local.
avahi-browse -a -t -r | grep -i smb
# = eth0 IPv4 Homelab NAS                       _smb._tcp            local
#    hostname = [pi.local]
#    address = [192.168.1.10]
#    port = [445]
```

> **`<txt-record>model=RackMac</txt-record>`** hace que Finder muestre un icono de "rack" en vez del genérico "PC" cuando el NAS aparece en la barra lateral. Detalle cosmético, opcional.

### 3) Crear y rotar usuarios Samba

```bash
# Añadir un usuario nuevo.
sudo useradd --no-create-home --shell /usr/sbin/nologin --uid 1003 --gid 1110 amelia
sudo usermod -aG media amelia
sudo install -d -o amelia -g amelia -m 0700 /mnt/hd2t/shares/home/amelia
docker exec -it samba pdbedit -a -u amelia
# Añadir su sección [amelia] en stacks/samba/conf/smb.conf y reiniciar samba:
docker compose -f stacks/samba/docker-compose.yml restart samba

# Cambiar la password de un usuario existente.
docker exec -it samba smbpasswd <login>

# Borrar un usuario.
docker exec -it samba pdbedit -x <login>
sudo userdel <login>
```

### 4) Acceso desde Windows 10/11

```text
# Una vez (la primera).
1. File Explorer → barra de direcciones → \\nas.lan
2. Diálogo de credenciales: usuario `homelab` (no `WORKGROUP\homelab`),
   password de `pdbedit`. Marcar "Recordarme".
3. Aparecen los shares accesibles: `documentos`, `media`, `homelab`, ...

# Mapear como letra de unidad (persistente).
4. Click derecho → Map network drive → Letra Z → Folder \\nas.lan\documentos
   → Reconnect at sign-in.
```

> Si Windows no muestra `\\nas` en `Network`, comprobar que el sidecar `wsdd` está corriendo (`docker ps --filter name=wsdd`). El acceso por nombre completo (`\\nas.lan`) **no** depende de WS-Discovery: depende solo de DNS (Pi-hole).

### 5) Acceso desde macOS

```text
# Una vez.
1. Finder → Cmd+K (Connect to Server) → smb://nas.lan
2. Credenciales `homelab` / pdbedit-password. Marcar el llavero.
3. Seleccionar share a montar.

# Persistir en login.
4. System Settings → Users & Groups → Login Items → +
   → Buscar el share montado en /Volumes y añadirlo.
```

### 6) Acceso desde Linux (cualquier distro con `cifs-utils`)

```bash
# Instalación.
sudo apt install -y cifs-utils

# Montaje ad-hoc.
sudo mkdir -p /mnt/nas-documentos
sudo mount -t cifs //nas.lan/documentos /mnt/nas-documentos \
    -o username=homelab,uid=$(id -u),gid=$(id -g),vers=3.0,seal

# Montaje persistente con credenciales en fichero.
sudo install -m 0600 /dev/stdin /root/.smbcreds-nas <<EOF
username=homelab
password=PUT_PASSWORD_HERE
EOF
echo "//nas.lan/documentos /mnt/nas-documentos cifs credentials=/root/.smbcreds-nas,uid=1000,gid=1000,vers=3.0,seal,_netdev,nofail 0 0" | \
    sudo tee -a /etc/fstab
sudo systemctl daemon-reload
sudo mount /mnt/nas-documentos
```

> **`vers=3.0`**: rechaza SMB1/2 a nivel de cliente. **`seal`**: cifrado en tránsito (equivale a `smb encrypt = required` desde el cliente). **`_netdev,nofail`**: que el FS no rompa el boot si el NAS no está accesible (importante en clientes que pueden estar fuera de casa).

### 7) Operación diaria

| Acción | Comando |
|---|---|
| Listar shares vivos | `docker exec samba smbclient -N -L //127.0.0.1` |
| Listar conexiones activas | `docker exec samba smbstatus` |
| Cerrar una sesión concreta | `docker exec samba smbcontrol smbd close-share <share>` |
| Recargar `smb.conf` sin reinicio | `docker exec samba smbcontrol smbd reload-config` |
| Listar usuarios `tdbsam` | `docker exec samba pdbedit -L` |
| Cambiar password de un usuario | `docker exec -it samba smbpasswd <login>` |
| Tail de logs | `docker exec samba tail -F /var/log/samba/log.smbd` |
| Comprobar `smb.conf` | `docker exec samba testparm -s` |
| Ver versión Samba | `docker exec samba smbd -V` |

---

## Almacenamiento

| Ruta | Soporte | Owner:Group | Modo | Contenido |
|---|---|---|---|---|
| `/home/homelab/homelab/stacks/samba/docker-compose.yml` | microSD | `homelab:homelab` | `0640` | Stack versionado. |
| `/home/homelab/homelab/stacks/samba/conf/smb.conf` | microSD | `homelab:homelab` | `0644` | Configuración Samba en git. |
| `/home/homelab/homelab/stacks/samba/.env.example` | microSD | `homelab:homelab` | `0644` | Plantilla. |
| `/home/homelab/homelab/stacks/samba/.env` | microSD | `homelab:homelab` | `0600` | Vacío por ahora. **No** en git. |
| `/mnt/hd2t/apps/samba/config/` | hd2t | `root:root` | `0750` | `passdb.tdb`, `secrets.tdb`, `account_policy.tdb`. **Crítico**: contiene los hashes de los usuarios. |
| `/mnt/hd2t/apps/samba/log/` | hd2t | `root:root` | `0750` | Logs por cliente; `log.smbd` global. |
| `/mnt/hd2t/shares/documentos/` | hd2t | `homelab:users-samba` | `2770` | Share rw colectivo. Setgid heredado. |
| `/mnt/hd2t/shares/escritorio/` | hd2t | `homelab:users-samba` | `2770` | Buzón rw. |
| `/mnt/hd2t/shares/home/<user>/` | hd2t | `<user>:<user>` | `0700` | Carpeta privada por humano. |
| `/mnt/hd2t/media/` (existente) | hd2t | `homelab:media` | `2770` | Compartido con Jellyfin/`*arr`. Samba lo expone ro por defecto. |
| `/mnt/hd5t/stash/library/` (existente) | hd5t | `homelab:homelab` | `0750` | Read-only desde Samba. |
| `/mnt/hd2t/backups/exports/` | hd2t | `homelab:homelab` | `0750` | Read-only desde Samba; rellenado por Borgmatic. |

> **Por qué `apps/samba/config` es `root:root`**: la imagen `crazymax/samba` corre `smbd` como `root` (Samba lo necesita para `setuid()` por usuario en cada sesión). Los `.tdb` resultantes los crea root. No es un problema: el contenedor es la única vía de lectura/escritura para esos ficheros y los humanos no los abren a mano.

> **Setgid en `2770`**: heredan el grupo del directorio padre (`users-samba`, `media`, `<user>`), de modo que ficheros nuevos quedan accesibles para el grupo sin un `chgrp -R` posterior. Ya documentado en `docs/01-sistema/04-estructura-directorios.md` para `media/`; aquí se replica para `shares/`.

> **`hd5t` montado `:ro` en el contenedor**: doble defensa. `read only = yes` en `smb.conf` ya impide escrituras desde clientes; el `:ro` del bind mount hace que ni siquiera un *bug* en `smbd` pueda crear un fichero en `hd5t/stash/library/`.

---

## Backup

A nivel de repositorio (git):

| Artefacto | Estrategia |
|---|---|
| `stacks/samba/docker-compose.yml`, `conf/smb.conf`, `.env.example` | Versionados. Cualquier cambio en shares se rastrea por commit. |
| `stacks/samba/.env` | Versionable hoy (vacío) pero ignorado por convención (`stacks/*/.env` en `.gitignore`). |
| Decisiones (imagen, modo de red, auth, shares, descubrimiento) | Documentadas en este fichero. |

A nivel de datos (Borgmatic, Fase 7):

| Ruta | ¿Se respalda? | Estrategia | Por qué |
|---|---|---|---|
| `/mnt/hd2t/apps/samba/config/passdb.tdb` y `secrets.tdb` | **Sí**. | Diaria. | Los hashes de password Samba. Sin ellos, todos los usuarios tienen que volver a generar password. Pequeño (<1 MiB), barato. |
| `/mnt/hd2t/apps/samba/log/` | No. | Excluido. | Regenerable; Samba rotará los nuevos. |
| `/mnt/hd2t/shares/documentos/`, `escritorio/`, `home/*/` | **Sí**. | Diaria, **incremental** (Borg deduplica). | Datos de los usuarios. Cualquier pérdida es irreversible. |
| `/mnt/hd2t/media/` | Decisión en `07-backups/01-estrategia-backup.md`. | Mediático, prob. semanal o excluido. | Recuperable de la fuente original (descargas, ripeo) según la política. No es responsabilidad de Samba decidirlo. |
| `/mnt/hd5t/stash/library/` | **No** (decisión heredada de `00-hardware/03-preparacion-discos.md`). | Excluido. | El catálogo (metadatos) viaja en `hd2t/apps/stash/` y sí se respalda; la biblioteca multimedia en sí se considera reproducible. |
| `/mnt/hd2t/backups/exports/` | **No**. | Excluido. | Es la *salida* de un restore puntual, no datos primarios. |

> **Procedimiento de backup**: Samba **no** requiere `maintenance:mode` ni dump previo. Las `tdb` se respaldan en caliente sin riesgo: son ficheros pequeños y los abre `smbd` con `O_RDWR` pero las modificaciones (cambio de password, añadir usuario) son operaciones puntuales y atómicas; Borg congela el snapshot del fichero en el momento de la copia, lo cual es suficiente. Si en el futuro se introducen *roaming profiles* o `vfs_recycle` con metadata extensa, replantear.

Procedimiento de restore (pérdida del contenedor, datos intactos en `hd2t`):

```bash
docker compose -f stacks/samba/docker-compose.yml up -d --force-recreate
# Tras ~10 s de healthcheck, smbd vuelve. Conexiones que estaban activas
# se reconectan solas (los clientes Windows reintentan; macOS y Linux con
# `_netdev,nofail` también).
```

Procedimiento de restore tras pérdida total (reflasheo + restore Borg):

1. Recrear Fase 1 y Fase 2.
2. Restaurar `/mnt/hd2t/apps/samba/config/{passdb.tdb,secrets.tdb}` y `/mnt/hd2t/shares/` desde Borg.
3. Recrear los **usuarios POSIX** del paso "Crear y rotar usuarios" (los UIDs deben coincidir con los del backup).
4. Levantar el stack: `docker compose -f stacks/samba/docker-compose.yml up -d`.
5. Verificar `pdbedit -L`: lista esperada de usuarios.
6. Verificar `testparm` y conexión desde un cliente.

---

## Errores frecuentes y troubleshooting

| Síntoma | Causa probable | Resolución |
|---|---|---|
| Windows: "Windows cannot access \\nas.lan" tras instalar | DNS aún no resuelve `nas.lan`. | `nslookup nas.lan` desde Windows; verificar que el cliente usa Pi-hole (`192.168.1.2`). |
| Windows: "The user name or password is incorrect" con credenciales correctas | El usuario Samba existe en `tdbsam` pero no como usuario POSIX en el host. | `id <login>` en la Pi → si no existe, `useradd ...` y volver a crear con `pdbedit`. |
| Windows: el icono `\\nas` no aparece en *Network* | El sidecar `wsdd` no está corriendo, o Windows ha apagado *Network Discovery*. | `docker ps --filter name=wsdd`; en Windows `Settings → Network → Advanced sharing` activar "Network discovery". |
| macOS: `Finder` muestra el NAS pero al conectar pide "Guest" | Bonjour publica el servicio pero `restrict anonymous = 2` rechaza el guest. | Es el comportamiento esperado. Click en "Connect As" → introducir credenciales reales. |
| Linux: `mount: //nas.lan/documentos: cannot mount; permission denied` | `vers=` no incluye SMB3 o el cliente intenta SMB1. | Forzar `vers=3.0` en las opciones de `mount`. |
| `NT_STATUS_LOGON_FAILURE` repetido en `log.smbd` desde una IP concreta | Cliente con password antigua (típico tras rotación) o un fail2ban-style intento. | Si es un cliente legítimo: rotar su password (`smbpasswd <login>`). Si es ataque: `fail2ban` con jail `samba` (Fase `04-seguridad/02-fail2ban.md`). |
| Velocidad de transferencia <30 MiB/s sobre Gigabit | `aio` no activado, `socket options` por defecto, o el HDD USB satura. | El `smb.conf` ya activa `aio`/`sendfile`. Probar con `iperf3` Pi↔cliente para descartar red; `dd if=/dev/zero of=/mnt/hd2t/test.bin bs=1M count=1024 oflag=direct` para descartar disco. |
| `force user = homelab` no aplica y los ficheros quedan con `nobody:nogroup` | El usuario que se autenticó no tiene entrada POSIX en el host. | `getent passwd <login>`; si vacío, `useradd ...` + `pdbedit -a -u <login>`. |
| `smb.conf` cambiado y los cambios no se aplican | El parámetro está en `[global]` pero requiere reinicio total (`server min protocol`, `disable netbios`). | `docker compose -f stacks/samba/docker-compose.yml restart samba`. |
| Pi-hole no resuelve `nas.lan` | El comodín `address=/lan/192.168.1.10` no está activo. | Editar `/etc/dnsmasq.d/02-lan.conf` (Fase 3) y reiniciar Pi-hole. |
| `testparm -s` advierte "WARNING: pdbedit ..." | El passdb backend aún no está inicializado. | Crear el primer usuario con `pdbedit -a`. Es esperable en arranque limpio. |
| `wsdd` arranca y muere | Conflicto con un `wsdd` del propio host (`apt install wsd` previo). | `sudo apt remove --purge wsdd`. |
| `mount.cifs` falla con `Host is down` desde un Mac/Linux | Algunos clientes no soportan `seal` con SMB3 firmado obligatorio en kernels viejos. | Bajar a `seal=0` para ese cliente puntual; o actualizar `cifs-utils`. **No** bajar `server signing = mandatory` por un cliente: subir el cliente. |
| El share `media` aparece como rw para todos en lugar de ro | Falta `read only = yes` en la sección `[media]` o `write list` incluye al usuario que tendría que ser ro. | Revisar `[media]` en `smb.conf` y `testparm -s`. |
| La biblioteca de Stash aparece rw desde un cliente | El bind mount no está montado con `:ro`. | Verificar el `docker-compose.yml`. |
| `apps/samba/config/passdb.tdb` corrupto tras un kill duro | TDB sin commit. | `tdbtool /mnt/hd2t/apps/samba/config/passdb.tdb check`; en el peor caso, restaurar desde el último Borg. |

---

## Decisiones que **no** se toman en este documento

- **Samba como Active Directory Domain Controller** (`samba-ad-dc`). Sobreingeniería absoluta para 1–10 dispositivos.
- **Time Machine** sobre Samba (`vfs_fruit`, share dedicado con metadata Mac). Reabrible si algún Mac del hogar lo demanda; añade un share `[timemachine-<host>]` con cuotas y `fruit:time machine = yes`.
- **`vfs_recycle`** (papelera por share). Útil si se documenta el ciclo de purga; reabrible.
- **Cuotas por usuario** (`vfs_default_quota`). Hoy, espacio total y vigilancia.
- **Auditoría avanzada** (`vfs_full_audit` con destino syslog). Reabrible si hay requisitos de cumplimiento.
- **Auth contra LDAP/AD/Authelia OIDC**. Reabrible cuando exista un IdP central que sirva LDAP o cuando Samba soporte OIDC nativo (lejano).
- **Shadow Copies / VSS** (`vfs_shadow_copy2` con snapshots de ZFS o Btrfs). El FS de partida es ext4 sin snapshots; la "snapshot" del homelab es Borg. Reabrible si el FS migra a Btrfs/ZFS.
- **macvlan dedicado para Samba** (`192.168.1.5`). Reservado en `docs/03-red/01-macvlan.md` como slot libre; reabrible si en algún momento `host networking` deja de ser una opción para `wsdd`.
- **`fail2ban` jail para Samba**. Se documenta en `docs/04-seguridad/02-fail2ban.md` (Fase 4 ya cerrada) como **no incluida** por defecto; aquí se confirma que los logs `/mnt/hd2t/apps/samba/log/log.smbd` son el path a observar si se decide reactivarlo.
- **Compresión SMB3** (`vfs_compression`). Coste CPU significativo en Pi 5; los ficheros típicos del homelab (vídeo, fotos, ZIPs) ya están comprimidos.
- **Apple Bonjour completo desde el contenedor** (avahi-daemon dentro del contenedor `samba`). Se delega al `avahi-daemon` del host por simplicidad y por evitar `--privileged`.

---

## Verificación Final

Antes de pasar a `03-syncthing.md`:

| Comprobación | Comando | Resultado esperado |
|---|---|---|
| Stack desplegado y saludable | `docker compose -f stacks/samba/docker-compose.yml ps` | `samba Up (healthy)`; `wsdd Up`. |
| Imagen correcta y pinneada | `docker inspect samba --format '{{.Config.Image}}'` | `ghcr.io/crazymax/samba:4.21.2` |
| Solo TCP/445 publicado en el host | `sudo ss -tlnp \| grep -E ':(139\|445)\s'` | una línea con `:445`, ninguna con `:139`. |
| Sin SMB1/NetBIOS escuchando | `sudo ss -ulnp \| grep -E ':(137\|138)\s'` | salida vacía. |
| Conectado a `homelab` | `docker network inspect homelab --format '{{range .Containers}}{{.Name}} {{end}}'` | incluye `samba` (el sidecar `wsdd` está en `host`). |
| `testparm` valida `smb.conf` sin errores | `docker exec samba testparm -s 2>&1 \| grep -i 'Loaded services'` | `Loaded services file OK.` |
| `nas.lan` resuelve al IP de la Pi | `dig +short nas.lan @192.168.1.2` | `192.168.1.10` |
| `smbclient` lista shares con auth válido | `smbclient -U homelab -L //nas.lan` (introducir password) | tabla con `documentos`, `escritorio-compartido`, `media`, `multimedia-stash`, `homelab`, … |
| `smbclient` rechaza guest | `smbclient -N -L //nas.lan` | `NT_STATUS_LOGON_FAILURE` o vacío. |
| `smb encrypt = desired` activo | `docker exec samba testparm -s --parameter-name='smb encrypt'` | `desired` |
| `server min protocol = SMB2_10` | `docker exec samba testparm -s --parameter-name='server min protocol'` | `SMB2_10` |
| `disable netbios = yes` | `docker exec samba testparm -s --parameter-name='disable netbios'` | `Yes` |
| Conexión desde Windows | `Win+R` → `\\nas.lan` → credenciales → ver shares | ventana con los iconos de los shares accesibles. |
| Conexión desde macOS | Finder → Cmd+K → `smb://nas.lan` | diálogo de credenciales y montaje. |
| Conexión desde Linux | `mount -t cifs //nas.lan/documentos /tmp/test -o username=homelab,vers=3.0` | montaje OK. |
| Avahi anuncia el servicio | `avahi-browse -a -t -r \| grep -i smb` | una entrada `Homelab NAS` con port 445. |
| WS-Discovery responde | desde Windows: `nas` aparece en `Explorer → Network` | icono "NAS" presente. |
| Owner correcto de los shares | `stat -c '%u:%g %a' /mnt/hd2t/shares/documentos` | `1000:1110 2770` (`homelab:users-samba`). |
| `pdbedit` con el listado esperado | `docker exec samba pdbedit -L` | una línea por humano del hogar. |
| `force user` aplica al escribir | desde Windows con `nataly`, crear `documentos/test.txt`; en la Pi: `stat -c '%u:%g' /mnt/hd2t/shares/documentos/test.txt` | `1000:1110` (homelab:users-samba), no `1001:1110`. |
| `multimedia-stash` es ro desde Windows | borrar un fichero | error "Access denied". |
| `media` ro para `nataly`, rw para `homelab` | login `nataly`: error al crear; login `homelab`: éxito al crear | comportamiento diferenciado según `valid users`/`write list`. |
| `ufw` permite 445 solo desde LAN | `sudo ufw status \| grep 445` | `192.168.1.0/24 ... ALLOW IN` y, si Tailscale, `Anywhere on tailscale0`. |
| Persistencia tras reboot | `sudo reboot`; al volver: `docker ps --filter name=samba` | `Up ... (healthy)` sin acción manual; clientes con `_netdev,nofail` se remontan. |
| Stack en git | `git ls-files stacks/samba` | `docker-compose.yml`, `conf/smb.conf`, `.env.example` tracked; `.env` no tracked. |

Cumplido el último punto, el homelab tiene su servidor de ficheros SMB operativo: Windows, macOS y Linux montan shares de `hd2t` con autenticación obligatoria, SMB3 cifrado, sin SMB1/NetBIOS y sin guest. La biblioteca de Stash en `hd5t` se sirve en read-only para inspección. La siguiente puerta es **sincronizar carpetas peer-to-peer** entre dispositivos del operador (un caso que ni Nextcloud ni Samba cubren bien): `03-syncthing.md`.

---

## Referencias

- [Documento previo: `docs/06-almacenamiento/01-nextcloud.md`](./01-nextcloud.md)
- [Documento siguiente: `docs/06-almacenamiento/03-syncthing.md`](./03-syncthing.md)
- [Documento relacionado: `docs/06-almacenamiento/04-minio.md`](./04-minio.md)
- [Documento relacionado: `docs/01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md)
- [Documento relacionado: `docs/01-sistema/03-seguridad-base.md`](../01-sistema/03-seguridad-base.md)
- [Documento relacionado: `docs/02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md)
- [Documento relacionado: `docs/03-red/01-macvlan.md`](../03-red/01-macvlan.md)
- [Documento relacionado: `docs/03-red/02-pihole.md`](../03-red/02-pihole.md)
- [Documento relacionado: `docs/04-seguridad/02-fail2ban.md`](../04-seguridad/02-fail2ban.md)
- [Documento relacionado: `docs/07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md)
- [Samba — Documentación oficial](https://www.samba.org/samba/docs/)
- [Samba — `smb.conf` man page](https://www.samba.org/samba/docs/current/man-html/smb.conf.5.html)
- [Samba — `testparm`, `pdbedit`, `smbpasswd`](https://www.samba.org/samba/docs/current/man-html/)
- [Imagen Docker `crazymax/samba`](https://github.com/crazy-max/docker-samba)
- [WSDD2 — WS-Discovery server para Linux](https://github.com/Andy2244/wsdd2)
- [Imagen Docker `jonasped/wsdd`](https://github.com/jonasped/docker-wsdd)
- [Avahi — Documentación oficial](https://avahi.org/)
- [`cifs-utils` — Cliente Linux para SMB](https://wiki.samba.org/index.php/LinuxCIFS_utils)
- [Microsoft — SMB security best practices](https://learn.microsoft.com/en-us/windows-server/storage/file-server/smb-security)
