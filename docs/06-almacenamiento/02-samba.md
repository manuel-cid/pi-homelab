# Samba (servidor SMB para shares de red)

## Descripción

Despliegue de **Samba** como servidor de **archivos compartidos por red (SMB/CIFS)** del homelab. Cubre tres casos de uso bien diferenciados:

1. **_Sneakernet_ multimedia**: el operador (y la familia) deja películas, música, audiolibros y _ebooks_ desde su portátil/Mac/teléfono en una carpeta de red, y servicios como Jellyfin, Navidrome, Audiobookshelf y Calibre-Web los descubren automáticamente porque comparten _exactamente_ el mismo árbol (`/mnt/hd2t/services/shared/{media,music,audiobooks,ebooks}/`, ya pre-creado en `docs/01-sistema/04-estructura-directorios.md` con bit `setgid` y grupo `homelab-media`).
2. **_Drop folder_ de Paperless-ngx**: la carpeta `/mnt/hd2t/services/paperless/consume/` (también pre-creada) se expone por SMB para que el operador "imprima a fichero" desde cualquier dispositivo de la LAN y Paperless lo OCRe automáticamente cuando llegue (ver `docs/11-productividad/04-paperless-ngx.md`).
3. **Acceso de sólo lectura a la biblioteca de Stash en `hd5t`** (opcional): si el operador quiere examinar el contenido del disco multimedia desde un cliente SMB sin pasar por la UI de Stash.

Este documento **extiende el _stack_ `almacen`** ya estrenado por Nextcloud (`docs/06-almacenamiento/01-nextcloud.md`): el `~/homelab/almacen/docker-compose.yml` recibe un servicio `samba` adicional, y se añade un `~/homelab/almacen/smb/smb.conf` versionado en git con la definición de _shares_ y las opciones globales endurecidas.

> **Alcance**: este documento despliega **un solo servicio Samba** con autenticación local (passdb propio de Samba — `tdbsam`), **dos cuentas** (`homelab` para el operador y `familia` para los miembros del hogar) y los _shares_ listados arriba. **No** integra LDAP/Active Directory (innecesario para 1–5 usuarios), **no** delega autenticación a Authelia (SMB no es HTTP, no se puede `forward_auth`-ear; ver **Decisiones de diseño**) y **no** abre Samba a internet ni a través de Caddy (el protocolo SMB sobre TCP/445 jamás se publica fuera de la LAN; el acceso remoto se hace exclusivamente vía Tailscale).

> **Recordatorio de red**: a diferencia de Nextcloud (que vive detrás de Caddy en el _bridge_ `homelab`), Samba **no se reverse-proxy-ea**: SMB es un protocolo binario propio sobre TCP/445 (más NetBIOS en 137/138/139, sólo si se activa). El servicio se despliega con `network_mode: host` para que `wsdd2` (descubrimiento Windows) y Avahi/mDNS (descubrimiento macOS) puedan emitir _broadcasts_ a la LAN. Esto significa que **el puerto 445 del host queda ocupado por Samba**; comprobar que ningún `smbd` nativo del sistema está corriendo (`systemctl status smbd nmbd 2>/dev/null` debe devolver _unit not found_, ya que `docs/01-sistema/01-instalacion-os.md` parte de Raspberry Pi OS Lite sin Samba).

---

## Requisitos previos

- `docs/00-hardware/03-preparacion-discos.md` completado: `hd2t` montado en `/mnt/hd2t` y `hd5t` en `/mnt/hd5t`. La opción de _mount_ de `hd2t` en `/etc/fstab` incluye `user_xattr` y `acl` (ext4 los soporta por defecto en kernels recientes; verificar con `mount | grep hd2t`). Sin _xattr_, Samba **no** puede emular las _Windows ACLs_ y registra _warnings_ continuamente en el log.
- `docs/01-sistema/04-estructura-directorios.md` completado: existen ya `/mnt/hd2t/services/samba/`, `/mnt/hd2t/services/shared/{media,music,audiobooks,ebooks}/` (con ownership `1000:homelab-media` y modo `2775`), `/mnt/hd2t/services/paperless/consume/` y `/mnt/hd5t/stash/data/`. El grupo `homelab-media` está creado y el usuario `homelab` pertenece a él.
- `docs/01-sistema/03-seguridad-base.md` completado: el firewall `nftables` está activo. El _ruleset_ ya permite tráfico de la LAN al host; este documento añade explícitamente el puerto **445/TCP** (y opcionalmente **5353/UDP** si se publica vía Avahi).
- `docs/02-docker/02-estructura-compose.md` completado: la red `homelab` (externa) existe, el `~/homelab/.env` global expone `TZ`, `PUID=1000`, `PGID=1000` y `HOMELAB_DOMAIN=lan`, y el _Makefile_ ofrece `make up STACK=almacen`.
- `docs/02-docker/04-watchtower.md` completado: la convención `com.centurylinklabs.watchtower.enable` está documentada. Samba será **opt-out** explícito (justificación en **Decisiones de diseño**).
- `docs/06-almacenamiento/01-nextcloud.md` completado: el _stack_ `almacen` está vivo (`~/homelab/almacen/docker-compose.yml`, `.env`, `.env.example`, `.gitignore`). Este documento **añade** servicios y volúmenes al mismo `docker-compose.yml`, no crea uno nuevo.
- Conectividad saliente para descargar la imagen (sólo la primera vez):
  ```bash
  docker pull --platform linux/arm64 \
    ghcr.io/servercontainers/samba:smbd-only-a4.21.4-c3ec1cc-debian-12.10-r0 \
    >/dev/null && echo OK
  ```
  El _tag_ exacto cambia con el tiempo; el operador debe consultar el _README_ del proyecto (<https://github.com/ServerContainers/samba>) y fijarlo en `.env` antes de seguir. La convención del homelab prohíbe `:latest`; ver `docs/02-docker/02-estructura-compose.md`, sección **Imágenes**.
- Que el host **no** tenga ya `smbd` o `nmbd` corriendo:
  ```bash
  ss -tlnp | grep -E ':(139|445)\s' || echo "Puerto 445 libre — OK"
  systemctl status smbd nmbd 2>/dev/null | grep -E 'Active|could not' || echo "No hay Samba nativo — OK"
  ```
  Si por error el operador instaló `samba` con `apt`, `sudo apt purge samba samba-common-bin nmbd smbd && sudo apt autoremove` antes de continuar.

---

## Decisiones de diseño

### Por qué Samba (y no NFS / WebDAV / Syncthing)

El homelab ya tiene **Nextcloud** (`01-nextcloud.md`) para sincronización con _clientes_ explícitos y va a tener **Syncthing** (`03-syncthing.md`) para sincronización P2P. Samba cubre un caso distinto: **_share_ "tonto"** sin necesidad de instalar ningún cliente especial porque el explorador de archivos de Windows, macOS y Linux entiende SMB de fábrica. Cuatro alternativas descartadas y por qué:

| Candidato     | Por qué se descarta                                                                                                                                                                         |
|---------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **NFSv4**     | Excelente entre máquinas Linux, pero macOS Finder maneja mal los permisos POSIX en NFS y Windows requiere "_Services for NFS_" (sólo en ediciones Pro/Enterprise). Inviable para una familia mixta. |
| **WebDAV** (vía Nextcloud o Caddy) | Funciona en cualquier OS, pero su rendimiento al copiar miles de ficheros pequeños (típico al volcar una carpeta de fotos) es 5–10× peor que SMB; macOS Finder lo monta como _read-only_ por defecto. |
| **Syncthing** | Sincronización **automática** P2P. Pero requiere instalar y configurar un cliente en cada dispositivo, y no encaja para "_drop_ ocasional desde el portátil del invitado".                                    |
| **SFTP/SSH**  | Trivial sobre la base SSH ya existente, pero el _UX_ en Windows/macOS es pobre: sólo clientes especializados (WinSCP, Cyberduck) lo manejan bien; Finder/Explorer no lo montan nativamente.                       |

Samba gana porque:

- **Soporte nativo en todas partes**: Windows (Explorador), macOS (Finder → _Connect to Server…_), Linux (Nautilus / Dolphin / `smbclient`), Android (apps de gestor de archivos como _Solid Explorer_, _Total Commander_), iOS (app _Files_ desde iOS 13).
- **Rendimiento**: SMB3 sobre Gigabit alcanza ~110 MB/s en la Pi 5 (saturación de USB 3.0 del disco externo es el cuello de botella, no la red). Mejor que cualquier alternativa salvo NFS, que se descarta por _UX_.
- **Descubrimiento de servicios**: vía `wsdd2` (Windows) y Avahi/mDNS (macOS), las máquinas de la LAN ven el _server_ Samba como vecino de red sin tener que escribir IPs.
- **Permite "compartir" lo que ya está ahí**: las imágenes de Jellyfin, Navidrome, Audiobookshelf y Calibre-Web ya consumen `services/shared/`. Exponer el mismo árbol por SMB no duplica datos: el operador arrastra un MKV, Jellyfin lo escanea automáticamente al ciclo siguiente.

### Imagen: `ghcr.io/servercontainers/samba`

Hay tres familias de imágenes Docker para Samba; se elige la siguiente:

| Imagen                             | Estado                  | Razón                                                                                                                                              |
|------------------------------------|-------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------|
| `dperson/samba`                    | Sin _commits_ desde 2022 | El estándar histórico, pero sin mantenimiento. Acumula CVE de Samba sin parchear.                                                                  |
| `crazymax/samba`                   | Activo                  | Multi-arch, configuración por _CLI args_. Limpia, pero el _CLI_ se queda corto para opciones avanzadas (ACLs, vfs modules).                       |
| **`ghcr.io/servercontainers/samba`** ✅ | Muy activo (releases mensuales siguiendo upstream) | Multi-arch ARM64, configuración vía `smb.conf` montado o variables de entorno, incluye `wsdd2` integrado, _entrypoint_ ejecuta `samba-tool ldb_modify` para inicialización idempotente. **Elección del homelab**. |

_Tag_ pinneado con formato `smbd-only-a<samba_version>-<git_sha>-debian-<base_version>-r<revision>`. La variante `smbd-only-` ahorra el _layer_ de `samba-ad-dc` (Active Directory Domain Controller — innecesario aquí). El operador debe consultar el _README_ del proyecto y elegir un _tag_ reciente: `ghcr.io/servercontainers/samba:smbd-only-a4.21.4-c3ec1cc-debian-12.10-r0` es un ejemplo válido a fecha de redacción de este documento.

### Watchtower opt-out

Razones:

- Samba mantiene un **passdb local** (`/var/lib/samba/private/passdb.tdb`) con los _hashes_ NT/LM de los usuarios. El _entrypoint_ de la imagen `servercontainers/samba` ejecuta `pdbedit` para sembrar usuarios desde variables de entorno, pero **no** hace migración entre versiones del formato `tdbsam`. Un `pull` automático que cruce un cambio de versión mayor (Samba 4.20 → 4.21, por ejemplo) puede dejar el passdb leído pero no escribible hasta `pdbedit -i smbpasswd:... -e tdbsam:...`.
- Las opciones de `smb.conf` evolucionan entre _majors_ (algunas se renombran o pasan a "deprecated"). Una actualización opaca puede dejar Samba arrancando con _warnings_ que el operador no ve hasta que algo se rompe en producción.
- _Smbclient_ y los clientes nativos están en _producción doméstica_: una interrupción de 30 s de Watchtower reiniciando el contenedor puede romper una copia en curso (Finder mostrará un diálogo de error, el portátil del operador se quedará con un fichero a medio copiar).

Etiquetar el contenedor con `com.centurylinklabs.watchtower.enable: "false"`. Las actualizaciones se hacen a mano leyendo el _changelog_ y verificando que `smb.conf` sigue siendo válido (`testparm`).

### `network_mode: host` y por qué no _bridge_ ni _macvlan_

Samba necesita **publicar** servicios en la LAN para descubrimiento (no sólo aceptar conexiones). Dos protocolos auxiliares lo hacen:

- **WSDD** (Web Services Dynamic Discovery): el sucesor de NetBIOS para Windows 10+. Emite _multicast_ a `239.255.255.250:3702/UDP` para que el _Explorer_ pinte el host en _Network Neighborhood_. La imagen `servercontainers/samba` lleva `wsdd2` y lo arranca como sidecar dentro del mismo contenedor.
- **mDNS / Avahi**: el "Bonjour" de macOS. Anuncia el servicio `_smb._tcp` en `224.0.0.251:5353/UDP` para que el Finder lo muestre en la sección _Locations_.

Las tres opciones de red Docker:

| Modo            | 445/TCP | WSDD multicast | mDNS    | Veredicto                                                                                                          |
|-----------------|---------|----------------|---------|---------------------------------------------------------------------------------------------------------------------|
| `bridge`        | OK con `ports:` | **NO** (no atraviesa el _bridge_ en Linux) | **NO** | Funciona si el cliente conoce la IP, pero ningún _Explorer_ lo muestra en "Red". UX pésima.                  |
| `macvlan`       | OK con IP propia | OK     | OK      | Cumple, pero requiere IP fija en LAN, _shim_ host↔contenedor (problema con DHCP), y un IP "extra" del rango.    |
| **`network_mode: host`** ✅ | OK | OK | OK | Mejor _UX_ (los clientes ven al host en _Network_) y mínima fricción operativa. **Elección del homelab**. |

`host` significa que el contenedor comparte la pila de red del Pi: `eth0` (LAN) y `tailscale0` (VPN) son visibles dentro del contenedor sin más. Caddy ya escucha en 80/443 del host (ver `docs/03-red/04-caddy.md`); Samba escucha en 445/139 del mismo host. **No hay colisión** porque los puertos son distintos.

> **Implicación de seguridad**: con `network_mode: host` la red `homelab` (`172.20.10.0/24`) **no** es alcanzable desde dentro del contenedor por DNS interno de Docker. Esto _no_ afecta a Samba (no necesita hablar con Nextcloud/MariaDB), pero impide cualquier futura idea de "que Samba ataque a una BD interna por DNS". Aceptable.

### Sólo SMB3, sin SMB1, con cifrado obligatorio

`smb.conf` global hardening:

```ini
[global]
   server min protocol = SMB3_11
   client min protocol = SMB3_11
   server smb encrypt = required
   smb encrypt = required
   server signing = mandatory
   smb3 unix extensions = yes
   ntlm auth = ntlmv2-only
   restrict anonymous = 2
```

Razones:

- **SMB1 está roto** (EternalBlue, WannaCry). Windows 10/11 ya lo desactivan por defecto. Forzar `SMB3_11` (Samba 4.13+) elimina cualquier negociación insegura.
- **Cifrado obligatorio** (`server smb encrypt = required`): la sesión SMB se cifra con AES-128-GCM. Esto vale incluso dentro de la LAN: protege contra el clásico ataque de _ARP spoofing_ por un dispositivo IoT comprometido en la misma WiFi.
- **`server signing = mandatory`**: cada paquete va firmado, evitando _man-in-the-middle_ que altere comandos sin invalidar la sesión.
- **`ntlm auth = ntlmv2-only`**: rechaza autenticación con _hashes_ NTLMv1 (rompibles por _rainbow tables_).
- **`restrict anonymous = 2`**: bloquea cualquier intento de listar _shares_ sin autenticarse. Importante: con esta opción, el cliente **no** verá _shares_ en `\\pi.lan\` hasta haberse autenticado contra una _share_ concreta. _UX_ ligeramente peor pero seguridad mucho mejor.

> **Coste**: el cifrado SMB3 GCM añade ~5 % de CPU en la Pi 5 a velocidad Gigabit. Despreciable; la Pi 5 hace ~600 MB/s de AES-GCM por _core_.

### Sin _guest access_, dos usuarios locales (`homelab` y `familia`)

Tentación natural: dejar `guest ok = yes` en una _share_ "pública de la LAN" y olvidarse de gestionar _passwords_. **Se descarta**: aunque la LAN es de confianza, una IoT comprometida o un invitado en la WiFi pasaría a leer/escribir. La fricción de escribir un _password_ una vez por dispositivo (Windows lo guarda en _Credential Manager_) es trivial.

Modelo mínimo: **dos usuarios locales** en el passdb de Samba (no se mezclan con `/etc/passwd` del host porque la imagen no lleva `pam_unix`):

| Usuario   | UID inside container | Acceso                                                                                            |
|-----------|----------------------|---------------------------------------------------------------------------------------------------|
| `homelab` | 1000 (= UID del operador en el host) | `rw` a **todo**: `media`, `music`, `audiobooks`, `ebooks`, `paperless-consume`, `stash` (ro). |
| `familia` | 1001                                  | `rw` a `media`, `music`, `audiobooks`, `ebooks`. **Sin acceso** a `paperless-consume` ni `stash`. |

Los UIDs sirven para que los ficheros que escriba `familia` queden con dueño `1001:homelab-media` en el disco. El UID `1001` no existe en el host ni en otros contenedores, por lo que no hay riesgo de cruce de privilegios; lo único que importa es que el GID secundario `homelab-media` (creado en `04-estructura-directorios.md`, GID típicamente `989` o el primero libre por encima de 1000) sí coincida y permita a Jellyfin/Navidrome leer lo escrito.

`force user = homelab` y `force group = homelab-media` por _share_ rescriben en el momento de la escritura; combinado con `setgid` ya activo en `services/shared/` se garantiza que **da igual qué usuario SMB escriba**: el fichero queda como `homelab:homelab-media` `2664`.

### `forward_auth` con Authelia: **NO** aplica

A diferencia de Nextcloud, donde explícitamente se rechaza poner Authelia delante porque rompería _clientes WebDAV_, en Samba **es físicamente imposible** poner Authelia delante:

- SMB no es HTTP. Authelia es un _middleware HTTP_ (recibe `forward_auth` desde Caddy/Nginx/Traefik). Samba habla un protocolo binario propio sobre TCP/445.
- La autenticación de SMB se hace con NTLMv2 (o Kerberos en entornos AD); no hay redirección a un portal _login_ ni _OAuth_.

La autenticación queda al motor de Samba (`tdbsam`). Si en el futuro el homelab se une a un dominio AD/LDAP, se cambia el `passdb backend` y `security` global; el resto del documento no cambia.

### No publicar Samba a internet ni vía Caddy

El homelab es **LAN + Tailscale**. Samba no tiene que estar accesible desde internet, y no se podría aunque se quisiera (Caddy no entiende SMB). Para acceso remoto:

- El cliente **se conecta a Tailscale** (ver `docs/03-red/05-tailscale.md`).
- Una vez en la _tailnet_, accede a `\\pi.tailnet.ts.net\media` (o la IP `100.x.y.z` de la Pi en la _tailnet_).
- El _firewall_ de la Pi (`nftables`) sólo abre 445/TCP a `192.168.0.0/16` (LAN) y `100.64.0.0/10` (CGNAT de Tailscale). Bloquea cualquier otro origen.

### Estructura de _shares_

Mapeo declarativo en `smb.conf`:

| _Share_              | Path en el host                                  | Acceso                                       | _force user:group_         |
|----------------------|--------------------------------------------------|----------------------------------------------|----------------------------|
| `media`              | `/mnt/hd2t/services/shared/media/`               | `rw` para `homelab`, `familia`               | `homelab:homelab-media`    |
| `music`              | `/mnt/hd2t/services/shared/music/`               | `rw` para `homelab`, `familia`               | `homelab:homelab-media`    |
| `audiobooks`         | `/mnt/hd2t/services/shared/audiobooks/`          | `rw` para `homelab`, `familia`               | `homelab:homelab-media`    |
| `ebooks`             | `/mnt/hd2t/services/shared/ebooks/`              | `rw` para `homelab`, `familia`               | `homelab:homelab-media`    |
| `paperless-consume`  | `/mnt/hd2t/services/paperless/consume/`          | `rw` sólo para `homelab` (drop folder)       | `homelab:homelab` (UID/GID que use Paperless al consumir) |
| `stash` *(opcional)* | `/mnt/hd5t/stash/data/`                          | `ro` sólo para `homelab`                     | `homelab:homelab` (heredado del disco) |

Lo que **NO** se exporta y por qué:

- `services/nextcloud/data/` — Nextcloud mantiene _file locks_ y registros de _file scan_ en su BD. Tocarlo desde fuera de Nextcloud rompe la consistencia (los cambios "extraños" no se ven hasta `occ files:scan`).
- `services/syncthing/`, `services/jellyfin/config/`, etc. — datos de _runtime_ de cada servicio: tocarlos por SMB corromperá BDs SQLite y demás. _Hands off_.
- `backups/` — propiedad de `root:root 0700` (ver `04-estructura-directorios.md`). Samba sin acceso _root_ ni siquiera puede listarlo. Y bien que es así: el _backup_ no se navega por SMB; se restaura con Borg.

### Almacenamiento

| Ruta en el host                                           | Contenido                                              | Versionable | Backup                                  |
|-----------------------------------------------------------|--------------------------------------------------------|-------------|-----------------------------------------|
| `~/homelab/almacen/docker-compose.yml`                    | Definición del _stack_ (extendida con `samba`)         | git         | git                                     |
| `~/homelab/almacen/smb/smb.conf`                          | Configuración global y _shares_                        | git         | git                                     |
| `~/homelab/almacen/.env`                                  | _Tag_ de la imagen + _passwords_ Samba (`SMB_PASS_*`)  | **NO** (`.gitignore`) | nota local                  |
| `/mnt/hd2t/services/samba/passdb/`                        | `passdb.tdb`, `secrets.tdb` — _hashes_ NT de usuarios   | **NO**      | **Sí** (Borgmatic)                      |
| `/mnt/hd2t/services/samba/lib/`                           | Estado interno de Samba (`registry.tdb`, leases…)       | **NO**      | **Sí** (Borgmatic, ligero)              |
| `/mnt/hd2t/services/samba/log/`                           | Logs de Samba                                          | **NO**      | No (rotación interna; reproducibles)    |
| `/mnt/hd2t/services/shared/{media,music,audiobooks,ebooks}/` | Contenido compartido (lo expuesto por Samba)        | **NO**      | **Sí** (Borgmatic, _set_ "shared")      |
| `/mnt/hd2t/services/paperless/consume/`                   | Drop folder de Paperless                               | **NO**      | No (transitorio: Paperless lo vacía al ingerir) |
| `/mnt/hd5t/stash/data/`                                   | Biblioteca de Stash (sólo se monta `:ro` en Samba)     | **NO**      | (ver `docs/09-multimedia/05-stash.md`)  |

> **Por qué `passdb/` y `lib/` separados de la imagen**: con un único _bind mount_ `/var/lib/samba` se mezclaría el passdb (crítico, sólo cambia al añadir/quitar usuarios) con `lib/` (cambia constantemente con cada conexión). Separarlos permite a Borgmatic respaldar `passdb/` con frecuencia agresiva (a diario) y `lib/` con frecuencia laxa (semanal o ninguna; es regenerable).

---

## Estructura del _stack_ `almacen` tras este documento

```
~/homelab/almacen/
├── docker-compose.yml        # ← extendido con servicio 'samba'
├── .env                      # ← extendido con SAMBA_*, SMB_PASS_*
├── .env.example              # ← extendido (sin valores reales)
├── .gitignore                # ya existía
└── smb/
    └── smb.conf              # ← nuevo (versionado)
```

Y en el disco externo, sobre lo ya creado por `04-estructura-directorios.md`:

```
/mnt/hd2t/services/samba/
├── passdb/                   # ← nuevo (vacío, lo puebla el entrypoint)
├── lib/                      # ← nuevo (vacío, runtime)
└── log/                      # ← nuevo (vacío, runtime)
```

Crear los subdirectorios de _runtime_ (root es el dueño, igual que el contenedor):

```bash
sudo mkdir -p /mnt/hd2t/services/samba/{passdb,lib,log}
sudo chown root:root /mnt/hd2t/services/samba/{passdb,lib,log}
sudo chmod 0700 /mnt/hd2t/services/samba/passdb       # passdb es sensible
sudo chmod 0755 /mnt/hd2t/services/samba/{lib,log}
```

Y crear el directorio del _stack_ para `smb.conf`:

```bash
mkdir -p ~/homelab/almacen/smb
```

---

## Variables de entorno

Añadir al final de `~/homelab/almacen/.env.example` (versionado, sin valores reales):

```bash
# --- Samba ------------------------------------------------------------------
# Imagen pinneada — consultar el README de servercontainers/samba para el
# tag más reciente: https://github.com/ServerContainers/samba#tags
SAMBA_IMAGE_TAG=smbd-only-a4.21.4-c3ec1cc-debian-12.10-r0

# Identidad del workgroup y nombre NetBIOS del servidor.
# El nombre debe coincidir con el hostname del host (ver
# docs/01-sistema/02-configuracion-inicial.md) para que mDNS y wsdd2
# anuncien la misma identidad.
SAMBA_WORKGROUP=HOMELAB
SAMBA_SERVER_NAME=pi
SAMBA_SERVER_STRING="Homelab Raspberry Pi 5"

# Cuentas SMB. Las passwords se generan con `openssl rand -base64 24` y se
# guardan en Vaultwarden. Si se añade un tercer usuario, replicar la pareja
# SMB_USER_<name>_PASS y editar smb.conf.
SMB_USER_HOMELAB=homelab
SMB_USER_HOMELAB_PASS=
SMB_USER_HOMELAB_UID=1000

SMB_USER_FAMILIA=familia
SMB_USER_FAMILIA_PASS=
SMB_USER_FAMILIA_UID=1001

# Habilitar la share de sólo lectura sobre /mnt/hd5t/stash/data
# 'true' para activarla, 'false' para no exponerla por SMB.
SAMBA_ENABLE_STASH_SHARE=false
```

Generar las _passwords_ y añadirlas al `.env`:

```bash
cd ~/homelab/almacen

homelab_pass=$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)
familia_pass=$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)

# Append a las variables ya existentes (Nextcloud) en .env
{
  echo ""
  echo "# --- Samba ---"
  echo "SAMBA_IMAGE_TAG=smbd-only-a4.21.4-c3ec1cc-debian-12.10-r0"
  echo "SAMBA_WORKGROUP=HOMELAB"
  echo "SAMBA_SERVER_NAME=pi"
  echo "SAMBA_SERVER_STRING=\"Homelab Raspberry Pi 5\""
  echo "SMB_USER_HOMELAB=homelab"
  echo "SMB_USER_HOMELAB_PASS=$homelab_pass"
  echo "SMB_USER_HOMELAB_UID=1000"
  echo "SMB_USER_FAMILIA=familia"
  echo "SMB_USER_FAMILIA_PASS=$familia_pass"
  echo "SMB_USER_FAMILIA_UID=1001"
  echo "SAMBA_ENABLE_STASH_SHARE=false"
} >> .env

# Verificar permisos del .env
chmod 0600 .env

# Mostrar las passwords (copiarlas a Vaultwarden ANTES de cerrar la sesión)
echo "homelab: $homelab_pass"
echo "familia: $familia_pass"
unset homelab_pass familia_pass
```

> **`tr -d '/+='`**: las _passwords_ SMB pueden contener cualquier carácter, pero `/`, `+` y `=` se cuelan en URLs `smb://user:pass@host/share` que el operador puede escribir desde Linux/Mac. Eliminarlos evita problemas de _escaping_ sin reducir significativamente la entropía (24 chars Base64 menos 3 chars sobre alfabeto de 61 ≈ 142 bits).

---

## Configuración global y de _shares_: `~/homelab/almacen/smb/smb.conf`

```ini
# Stack: almacen — Samba (servidor SMB)
# Documentación: docs/06-almacenamiento/02-samba.md
#
# IMPORTANTE: cualquier cambio aquí se aplica al recargar Samba con
#   docker exec samba smbcontrol smbd reload-config
# o reiniciando el contenedor. Validar siempre con `testparm -s` antes.

[global]
   # --- Identidad ----------------------------------------------------------
   workgroup = HOMELAB
   netbios name = pi
   server string = Homelab Raspberry Pi 5
   server role = standalone server

   # --- Hardening del protocolo --------------------------------------------
   server min protocol = SMB3_11
   client min protocol = SMB3_11
   server smb encrypt = required
   smb encrypt = required
   server signing = mandatory
   ntlm auth = ntlmv2-only
   restrict anonymous = 2
   disable netbios = yes

   # --- Autenticación local (passdb) ---------------------------------------
   security = user
   passdb backend = tdbsam
   map to guest = never

   # --- Logging ------------------------------------------------------------
   log file = /var/log/samba/log.%m
   max log size = 10000
   log level = 1 auth:3 winbind:0
   logging = file

   # --- Optimización -------------------------------------------------------
   # Saca el máximo del USB 3.0 + Gigabit en la Pi 5
   socket options = TCP_NODELAY IPTOS_LOWDELAY SO_RCVBUF=131072 SO_SNDBUF=131072
   read raw = yes
   write raw = yes
   strict locking = no
   strict allocate = yes
   use sendfile = yes
   aio read size = 16384
   aio write size = 16384
   min receivefile size = 16384

   # --- Compatibilidad macOS Finder (Time Machine va aparte si se quiere) --
   # vfs_fruit emula extensiones SMB que macOS espera ("AAPL", metadata
   # de resource forks). Sin él, copiar carpetas de macOS a Samba pierde
   # tags y comentarios y al volver a copiarlas a un Mac se ven "rotas".
   vfs objects = catia fruit streams_xattr
   fruit:metadata = stream
   fruit:model = MacSamba
   fruit:posix_rename = yes
   fruit:veto_appledouble = no
   fruit:nfs_aces = no
   fruit:wipe_intentionally_left_blank_rfork = yes
   fruit:delete_empty_adfiles = yes

   # --- Permisos POSIX ------------------------------------------------------
   # Los ficheros nuevos heredan permisos de la carpeta padre (con setgid
   # aplicado en /mnt/hd2t/services/shared/, esto cierra el círculo).
   inherit permissions = yes
   inherit acls = yes
   create mask = 0664
   directory mask = 2775
   force create mode = 0664
   force directory mode = 2775

   # --- Descubrimiento (mDNS / wsdd2 los gestiona el entrypoint) -----------
   # Avahi se publica como servicio _smb._tcp en el host vía la imagen
   # servercontainers/samba (ya incluye avahi-daemon).

# ============================================================================
# Shares
# ============================================================================

[media]
   comment = Películas y series (Jellyfin)
   path = /shares/media
   valid users = homelab familia
   read only = no
   browseable = yes
   force user = homelab
   force group = homelab-media

[music]
   comment = Música (Navidrome)
   path = /shares/music
   valid users = homelab familia
   read only = no
   browseable = yes
   force user = homelab
   force group = homelab-media

[audiobooks]
   comment = Audiolibros (Audiobookshelf)
   path = /shares/audiobooks
   valid users = homelab familia
   read only = no
   browseable = yes
   force user = homelab
   force group = homelab-media

[ebooks]
   comment = Libros electrónicos (Calibre-Web)
   path = /shares/ebooks
   valid users = homelab familia
   read only = no
   browseable = yes
   force user = homelab
   force group = homelab-media

[paperless-consume]
   comment = Drop folder de Paperless-ngx
   path = /shares/paperless-consume
   valid users = homelab
   read only = no
   browseable = yes
   force user = homelab
   force group = homelab
   create mask = 0644
   directory mask = 0755

# Share de Stash (sólo lectura). Se mantiene comentada por defecto;
# descomentar si SAMBA_ENABLE_STASH_SHARE=true (el operador la edita
# manualmente: smb.conf no soporta condicionales).
#[stash]
#   comment = Biblioteca multimedia de Stash (sólo lectura)
#   path = /shares/stash
#   valid users = homelab
#   read only = yes
#   browseable = yes
```

> **`browseable = yes`** sólo significa que la _share_ aparece listada cuando el cliente ya está autenticado. La directiva `restrict anonymous = 2` global garantiza que un anónimo nunca llega a ver el listado.

> **`force user` y `force group`**: cualquier escritura, sea desde `homelab` o desde `familia`, queda en disco como `homelab:homelab-media`. Combinado con `setgid` y la máscara `2775` ya aplicada en `services/shared/` por `04-estructura-directorios.md`, los servicios secundarios (Jellyfin, Navidrome…) leen sin problema.

---

## `~/homelab/almacen/docker-compose.yml`: añadir `samba`

Editar el `docker-compose.yml` ya creado por `01-nextcloud.md` y añadir, **bajo la clave `services:`**, el siguiente bloque (al final, tras `nextcloud-cron`):

```yaml
  # ---------------------------------------------------------------------------
  # Samba — servidor SMB para shares de red.
  # network_mode: host (445/TCP en el host directamente; wsdd2 + Avahi).
  # No participa en 'homelab' (no necesita hablar con Nextcloud/MariaDB/Redis).
  # ---------------------------------------------------------------------------
  samba:
    image: ghcr.io/servercontainers/samba:${SAMBA_IMAGE_TAG}
    container_name: samba
    hostname: ${SAMBA_SERVER_NAME}
    restart: unless-stopped
    network_mode: host
    # cap_add necesario para wsdd2 (multicast) y para que pdbedit pueda
    # escribir el passdb al volumen montado.
    cap_add:
      - CAP_NET_ADMIN
      - CAP_NET_BIND_SERVICE
      - CAP_NET_RAW
    environment:
      TZ: ${TZ}

      # Identidad del servidor
      SAMBA_CONF_WORKGROUP: ${SAMBA_WORKGROUP}
      SAMBA_CONF_SERVER_STRING: ${SAMBA_SERVER_STRING}
      WSDD2_DISABLE: "0"        # publica wsdd2 (descubrimiento Windows)
      AVAHI_DISABLE: "0"        # publica _smb._tcp por mDNS (Finder macOS)

      # Cuentas — el entrypoint lee ACCOUNT_<user>=<password>:<uid>:<gid>
      # y siembra el passdb idempotentemente.
      ACCOUNT_homelab: ${SMB_USER_HOMELAB_PASS}
      UID_homelab: ${SMB_USER_HOMELAB_UID}
      GROUPS_homelab: homelab-media
      ACCOUNT_familia: ${SMB_USER_FAMILIA_PASS}
      UID_familia: ${SMB_USER_FAMILIA_UID}
      GROUPS_familia: homelab-media

    volumes:
      # Configuración: smb.conf versionado en git
      - ./smb/smb.conf:/etc/samba/smb.conf:ro

      # Estado persistente
      - /mnt/hd2t/services/samba/passdb:/var/lib/samba/private
      - /mnt/hd2t/services/samba/lib:/var/lib/samba
      - /mnt/hd2t/services/samba/log:/var/log/samba

      # Shares: bind-mounts a las carpetas reales del host.
      # Lectura/escritura — el ownership lo gestiona Samba con force user.
      - /mnt/hd2t/services/shared/media:/shares/media
      - /mnt/hd2t/services/shared/music:/shares/music
      - /mnt/hd2t/services/shared/audiobooks:/shares/audiobooks
      - /mnt/hd2t/services/shared/ebooks:/shares/ebooks
      - /mnt/hd2t/services/paperless/consume:/shares/paperless-consume

      # Stash en hd5t — sólo lectura. Si SAMBA_ENABLE_STASH_SHARE=false,
      # comentar esta línea y la sección [stash] de smb.conf.
      # - /mnt/hd5t/stash/data:/shares/stash:ro

    labels:
      homelab.stack: "almacen"
      homelab.backup: "true"      # /mnt/hd2t/services/samba/passdb (Borgmatic)
      # Opt-out: bumps cambian formato passdb. Manual.
      com.centurylinklabs.watchtower.enable: "false"
    healthcheck:
      test:
        - CMD-SHELL
        - "smbclient -L localhost -N 2>&1 | grep -q 'Anonymous login successful\\|NT_STATUS_ACCESS_DENIED'"
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 30s
```

Notas de diseño:

- **`network_mode: host` excluye la directiva `networks:`** del propio servicio. Samba no entra ni en `homelab` ni en `almacen-internal`; esto es correcto.
- **`cap_add` mínimo**: `CAP_NET_ADMIN` es necesario para que `avahi-daemon` configure interfaces de _multicast_; `CAP_NET_BIND_SERVICE` para escuchar en 137/138/139/445 (todos < 1024); `CAP_NET_RAW` para `wsdd2`. Se evita `privileged: true` y la _capability_ `SYS_ADMIN`.
- **Healthcheck**: el comando `smbclient -L localhost -N` lista _shares_ sin password. Con `restrict anonymous = 2` el _server_ debe responder `NT_STATUS_ACCESS_DENIED` (rechazo limpio); cualquier otra cosa (`Connection refused`, `timeout`) es síntoma de que `smbd` no arrancó. El _grep_ acepta ambos casos posibles.
- **El healthcheck no necesita `depends_on`**: Samba es independiente del resto del _stack_. Nextcloud, MariaDB y Redis pueden seguir parados y Samba arranca igual. Esto es deseable: `make up STACK=almacen` levanta todo a la vez, pero un `docker compose stop nextcloud nextcloud-db nextcloud-redis` para mantenimiento de Nextcloud no afecta a Samba.

---

## Despliegue

### Primer arranque

```bash
cd ~/homelab/almacen

# Validar smb.conf antes de levantar
docker run --rm \
  -v ./smb/smb.conf:/etc/samba/smb.conf:ro \
  ghcr.io/servercontainers/samba:${SAMBA_IMAGE_TAG} \
  testparm -s 2>&1 | head -40
# Debe mostrar la lista de shares y NO debe haber líneas 'WARNING' graves.

# Levantar el servicio (el resto del stack ya está en marcha; Compose
# reconcilia y crea sólo el contenedor 'samba').
docker compose --env-file ../.env --env-file .env up -d samba
```

O, equivalente, con el _Makefile_ (ver `docs/02-docker/02-estructura-compose.md`):

```bash
cd ~/homelab
make up STACK=almacen
```

Comprobar el primer arranque:

```bash
docker logs samba --tail 50
# samba         | [INFO] Starting Samba (smbd-only)...
# samba         | [INFO] User 'homelab' created (UID 1000, groups: homelab-media)
# samba         | [INFO] User 'familia' created (UID 1001, groups: homelab-media)
# samba         | smbd version 4.21.4 started.
# samba         | [INFO] avahi-daemon: Server startup complete.
# samba         | [INFO] wsdd2: Listening on 0.0.0.0:5357
docker compose -f ~/homelab/almacen/docker-compose.yml ps samba
# NAME    STATUS                   PORTS
# samba   Up X seconds (healthy)
```

### Abrir 445/TCP en el firewall

Si `nftables` está activo (recomendado por `docs/01-sistema/03-seguridad-base.md`), añadir la regla:

```bash
sudo nft add rule inet filter input \
  ip saddr { 192.168.0.0/16, 100.64.0.0/10 } \
  tcp dport 445 \
  accept comment '"SMB desde LAN + Tailscale"'

# Persistir
sudo nft list ruleset > /etc/nftables.conf
```

Si el operador prefiere `ufw`, equivalente:

```bash
sudo ufw allow from 192.168.0.0/16 to any port 445 proto tcp comment 'SMB LAN'
sudo ufw allow from 100.64.0.0/10 to any port 445 proto tcp comment 'SMB Tailscale'
```

> **No** hace falta abrir 137/138/139 (NetBIOS legacy): `disable netbios = yes` en `smb.conf` global ya los apaga. Sólo SMB3 puro.

> **wsdd2 / Avahi en multicast**: usan UDP `5357` (wsdd) y `5353` (mDNS). El _multicast_ entrante no requiere reglas especiales en `nftables` para una política _drop-by-default_ con _allow established_; los _replies_ a las consultas wsdd las gestiona la propia conexión. Si el operador no ve el _server_ en _Network Neighborhood_ tras 60 s, ver **Troubleshooting**.

---

## Configuración tras primer arranque

### Verificar que los usuarios están en el passdb

El _entrypoint_ los siembra al primer arranque a partir de las _env_ `ACCOUNT_*`. Confirmar:

```bash
docker exec samba pdbedit -L
# homelab:1000:Samba User
# familia:1001:Samba User
```

Si la lista está vacía, ver **Troubleshooting** → _Usuarios no aparecen en pdbedit_.

### Sembrar el grupo `homelab-media` en el passdb

El _entrypoint_ del contenedor crea los usuarios pero **no** garantiza que el grupo `homelab-media` exista dentro del contenedor (es un grupo del host). Forzarlo en el _entrypoint_ vía la _env_ `GROUPS_<user>=homelab-media`, que ya está en el `docker-compose.yml`. Verificar con:

```bash
docker exec samba getent group homelab-media
# homelab-media:x:989:homelab,familia
```

Si el GID dentro del contenedor (`989` en este ejemplo) **no** coincide con el del host, hay que sincronizarlo. El GID del host se obtiene con:

```bash
getent group homelab-media | cut -d: -f3
```

Si difiere, añadir al _docker-compose.yml_ del servicio `samba` la _env_:

```yaml
GROUPS_homelab: homelab-media:GID=989
GROUPS_familia: homelab-media:GID=989
```

(sustituyendo `989` por el GID real del host) y hacer `docker compose up -d samba`.

> **Por qué importa**: si Samba escribe un fichero como `1000:989` pero el host tiene `homelab-media` como GID `1001`, Jellyfin (que corre como `PUID=1000 PGID=1001`) **no** podrá leer el fichero (GID `989` ≠ GID `1001`). Mantenerlos alineados es esencial.

### Cambiar la _password_ de un usuario

```bash
docker exec -it samba smbpasswd -a homelab
# New SMB password: ****
# Retype new SMB password: ****
```

Esto es operación interactiva; el `.env` queda **desactualizado** respecto al passdb. Recomendación: editar también `.env` para que `SMB_USER_HOMELAB_PASS=<nueva>` quede coherente y guardar la nueva _password_ en Vaultwarden.

### Añadir un tercer usuario a posteriori

1. Editar `~/homelab/almacen/.env`:
   ```bash
   SMB_USER_INVITADO=invitado
   SMB_USER_INVITADO_PASS=$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)
   SMB_USER_INVITADO_UID=1002
   ```
2. Editar `~/homelab/almacen/docker-compose.yml`, añadir bajo `environment:` del servicio `samba`:
   ```yaml
   ACCOUNT_invitado: ${SMB_USER_INVITADO_PASS}
   UID_invitado: ${SMB_USER_INVITADO_UID}
   GROUPS_invitado: homelab-media
   ```
3. Editar `~/homelab/almacen/smb/smb.conf` para añadir `invitado` al `valid users` de las _shares_ a las que tenga acceso.
4. `docker compose up -d samba` (Compose reinicia el contenedor, el _entrypoint_ siembra al nuevo usuario).
5. Verificar con `docker exec samba pdbedit -L`.

---

## Verificación final

Antes de pasar a `docs/06-almacenamiento/03-syncthing.md`, comprobar:

- [ ] `docker compose -f ~/homelab/almacen/docker-compose.yml ps samba` muestra `samba` en `(healthy)`.
- [ ] `docker exec samba testparm -s 2>&1 | head -20` no devuelve _warnings_ relevantes ni errores.
- [ ] `docker exec samba pdbedit -L` lista `homelab` y `familia` con los UIDs esperados.
- [ ] `ss -tlnp | grep ':445\s'` desde el host muestra que `smbd` (PID dentro del contenedor) está escuchando en 445/TCP en todas las interfaces.
- [ ] `nft list ruleset | grep 'tcp dport 445'` muestra la regla de _allow_ desde LAN + Tailscale.
- [ ] Listado anónimo rechazado (debe ser):
  ```bash
  smbclient -L //localhost -N 2>&1 | head
  # do_connect: Connection to localhost failed (Error NT_STATUS_ACCESS_DENIED)
  ```
- [ ] Listado autenticado funciona:
  ```bash
  smbclient -L //localhost -U homelab%"$(grep ^SMB_USER_HOMELAB_PASS= ~/homelab/almacen/.env | cut -d= -f2-)"
  # Sharename       Type      Comment
  # ---------       ----      -------
  # media           Disk      Películas y series (Jellyfin)
  # music           Disk      Música (Navidrome)
  # audiobooks      Disk      Audiolibros (Audiobookshelf)
  # ebooks          Disk      Libros electrónicos (Calibre-Web)
  # paperless-consume  Disk   Drop folder de Paperless-ngx
  # IPC$            IPC       IPC Service (Homelab Raspberry Pi 5)
  ```
- [ ] Escritura desde un cliente de la LAN funciona y respeta el ownership:
  ```bash
  # Desde el host:
  echo "test" > /tmp/test.txt
  smbclient //localhost/media -U homelab%<password> -c 'put /tmp/test.txt test.txt'
  ls -la /mnt/hd2t/services/shared/media/test.txt
  # -rw-rw-r-- 1 homelab homelab-media 5 ... test.txt   ← clave
  rm /mnt/hd2t/services/shared/media/test.txt
  ```
- [ ] El usuario `familia` **no** puede acceder a `paperless-consume`:
  ```bash
  smbclient //localhost/paperless-consume -U familia%<password> -c 'ls' 2>&1
  # tree connect failed: NT_STATUS_ACCESS_DENIED   ← correcto
  ```
- [ ] Desde un Windows en la LAN, `\\pi.lan\` (o la IP de la Pi) abre un diálogo de _login_, y tras autenticarse muestra los _shares_ esperados. El servidor aparece en _Network Neighborhood_ del Explorer (gracias a `wsdd2`) tras 30–60 s.
- [ ] Desde un macOS en la LAN, `Finder → Cmd+K → smb://pi.lan` abre el _login_; tras autenticarse muestra las _shares_ y se montan en `/Volumes/`. La Pi aparece en _Locations_ del Finder (Avahi/mDNS).
- [ ] Desde Linux:
  ```bash
  gio mount smb://homelab@pi.lan/media
  ls /run/user/$UID/gvfs/smb-share:server=pi.lan,share=media,user=homelab/
  ```
- [ ] Acceso vía Tailscale funciona desde un cliente fuera de la LAN:
  ```bash
  # En el cliente con Tailscale activo:
  smbclient //pi.tailnet.ts.net/media -U homelab%<password> -c 'ls'
  ```
  Debe listar el contenido idénticamente al acceso LAN.
- [ ] Tras un `sudo reboot` de la Pi, el _stack_ vuelve y `samba` queda `(healthy)` sin intervención.
- [ ] `git -C ~/homelab status` muestra como **modificados**: `almacen/docker-compose.yml`, `almacen/.env.example`. Como **nuevos**: `almacen/smb/smb.conf`. **No** muestra `almacen/.env` ni nada bajo `/mnt/hd2t/`. _Commit_:

  ```bash
  cd ~/homelab
  git add almacen/docker-compose.yml almacen/.env.example almacen/smb/smb.conf
  git commit -m "feat(almacen): add Samba server with media + paperless shares"
  ```

---

## Backup

| Qué                                          | Dónde                                                       | Cómo                                            |
|----------------------------------------------|-------------------------------------------------------------|-------------------------------------------------|
| `docker-compose.yml`                         | `~/homelab/almacen/`                                        | git                                             |
| `smb.conf`                                   | `~/homelab/almacen/smb/`                                    | git                                             |
| `.env` (con `SMB_USER_*_PASS`)               | `~/homelab/almacen/.env`                                    | nota local; las passwords replicadas en Vaultwarden |
| `passdb/` (hashes NT)                        | `/mnt/hd2t/services/samba/passdb/`                          | Borgmatic — _set_ "config", retención larga    |
| `lib/` (registry, leases…)                   | `/mnt/hd2t/services/samba/lib/`                             | Borgmatic — _set_ "config" (regenerable, opcional) |
| `log/`                                       | `/mnt/hd2t/services/samba/log/`                             | No (rotación interna; reproducibles)           |
| Contenido de las _shares_                    | `/mnt/hd2t/services/shared/{media,music,audiobooks,ebooks}/` | Borgmatic — _set_ "shared", retención por uso |
| Drop folder de Paperless                     | `/mnt/hd2t/services/paperless/consume/`                     | No (transitorio; lo vacía Paperless al ingerir) |

> **Restauración del passdb**: tras restaurar `/mnt/hd2t/services/samba/passdb/` desde Borg, basta con `docker compose up -d samba`. El _entrypoint_ detecta que el passdb ya existe y **no** sobreescribe los _hashes_ con las _passwords_ del `.env` (sólo los crea si no existen). Si por alguna razón se quiere forzar el _reseed_ desde `.env`, vaciar `/mnt/hd2t/services/samba/passdb/` antes de levantar.

> **Antes de un upgrade mayor de Samba (4.20 → 4.21 etc.)**:
> 1. Backup del _set_ "config" con Borgmatic _on-demand_.
> 2. `docker compose stop samba`.
> 3. Editar `.env`: `SAMBA_IMAGE_TAG=<nuevo tag>`.
> 4. Validar el `smb.conf` con la nueva imagen sin tocar el passdb:
>    ```bash
>    docker run --rm \
>      -v ~/homelab/almacen/smb/smb.conf:/etc/samba/smb.conf:ro \
>      ghcr.io/servercontainers/samba:<nuevo_tag> \
>      testparm -s
>    ```
> 5. Si `testparm` reporta opciones _deprecated_ o renombradas, arreglarlas en `smb.conf`.
> 6. `docker compose up -d samba` y verificar logs + healthcheck.
> 7. Smoke test: `smbclient -L //localhost -U homelab%<pass>` debe listar _shares_.

---

## Troubleshooting

### Usuarios no aparecen en `pdbedit -L`

Síntoma: tras el primer arranque, `docker exec samba pdbedit -L` está vacío. Causa típica: la variable `ACCOUNT_<name>` está vacía (la _password_ no se rellenó en `.env`).

```bash
docker exec samba env | grep -E '^(ACCOUNT|UID|GROUPS)_'
# Confirma que las env vars llegan al contenedor con valores no vacíos.
```

Si las _envs_ están bien pero el passdb sigue vacío, mirar los logs del _entrypoint_:

```bash
docker logs samba 2>&1 | grep -iE '(pdbedit|account|error)'
```

Forzar la creación a mano (en último recurso):

```bash
docker exec -it samba bash -c "echo -e 'mipass\nmipass' | smbpasswd -a -s homelab"
```

### El servidor no aparece en _Network Neighborhood_ de Windows

Causa habitual: `wsdd2` no anuncia. Tres comprobaciones:

1. `docker exec samba ps -ef | grep wsdd2` debe mostrar el proceso.
2. La _env_ `WSDD2_DISABLE=0` está en el `docker-compose.yml`.
3. La interfaz LAN del Pi (`eth0`) recibe `multicast`. Verificar:
   ```bash
   ip -4 maddr show dev eth0 | grep -E '(239\.|224\.)'
   # Debe haber al menos 239.255.255.250 (wsdd) y 224.0.0.251 (mDNS).
   ```

Si todo va bien y aún así no aparece, comprobar que el cliente Windows tiene `Función Reconocimiento de redes` (NLA) activada y que el _firewall_ del Windows permite "Detección de redes". Algunos Windows 11 vienen con _Network discovery_ en `Off` por defecto.

Workaround inmediato: desde el Explorer, escribir `\\pi.lan` o la IP `\\192.168.1.x` en la barra de direcciones. Funciona aunque el _server_ no aparezca en el _Network_.

### El servidor no aparece en _Locations_ del Finder en macOS

Causa habitual: `avahi-daemon` no publica `_smb._tcp`. Verificar desde el Mac:

```bash
dns-sd -B _smb._tcp local.
# Debe listar 'pi' (o el nombre fijado en SAMBA_SERVER_NAME).
```

Si no aparece, mirar dentro del contenedor:

```bash
docker exec samba ps -ef | grep avahi
# Debe mostrar avahi-daemon en marcha.
```

Si el proceso está pero no anuncia, suele ser por permisos de _multicast_ — confirmar que el contenedor lleva `cap_add: [CAP_NET_ADMIN]` y que `network_mode: host`.

Workaround: en el Finder, _Cmd+K_ → `smb://pi.lan/` (o la IP). Funciona aunque la Pi no se vea en _Locations_.

### `Permission denied` al copiar a la _share_ desde un cliente

Síntoma: `smbclient` autentica OK, lista _shares_, pero un `put` falla con `NT_STATUS_ACCESS_DENIED`. Causas posibles:

1. **Permisos POSIX de la carpeta del host**. Las carpetas en `/mnt/hd2t/services/shared/*` deben tener modo `2775` y dueño `1000:homelab-media`. Verificar:
   ```bash
   ls -la /mnt/hd2t/services/shared/
   # drwxrwsr-x 4 homelab homelab-media ...   ← clave: 's' minúscula = setgid
   ```
   Si falta el _setgid_ (la `s` del grupo) o el grupo es `homelab` en vez de `homelab-media`, repetir los comandos del paso 5 de `04-estructura-directorios.md`.
2. **El usuario SMB no está en el `valid users`** de la _share_. Comprobar `smb.conf` y `docker exec samba smbcontrol smbd reload-config` tras editarlo.
3. **`force user` o `force group` apuntan a un usuario/grupo que no existe dentro del contenedor**. `docker exec samba id homelab` y `docker exec samba getent group homelab-media` deben tener éxito.

### Logs llenos de `smbd_smb2_request_error: idx[X] status[NT_STATUS_LOGON_FAILURE]`

Algún cliente de la LAN intenta autenticarse con _password_ caducada/cambiada y reintenta en bucle (típico: un Windows con la credencial vieja en _Credential Manager_).

Identificar la IP del culpable:

```bash
docker exec samba grep -r 'NT_STATUS_LOGON_FAILURE' /var/log/samba/ | tail -20
# Cada línea trae la IP origen.
```

En el Windows: _Panel de control → Cuentas de usuario → Administrar credenciales de Windows_ → eliminar la entrada de `pi` o `pi.lan` y volver a conectar (pedirá _password_ nueva).

> **Fail2ban** (`docs/04-seguridad/02-fail2ban.md`) documenta una _jail_ específica para SMB que captura este patrón en `/mnt/hd2t/services/samba/log/log.<máquina>` y banea la IP tras 5 intentos fallidos en 10 min. Hasta que esa fase se complete, la limpieza es manual.

### Velocidad de copia mucho menor de lo esperado

En Pi 5 con USB 3.0 y Gigabit, esperable: ~80–110 MB/s en lectura/escritura secuencial. Si se ve `< 30 MB/s`:

1. **Cifrado SMB en CPU saturada**: con muchos clientes en paralelo, el AES-GCM puede saturar un _core_. Verificar con `htop` durante la copia. Mitigación: aceptar el _trade-off_ (la seguridad vale los 5–10 % de overhead) o, si se está en una LAN cableada estrictamente confiable, bajar a `server smb encrypt = desired` (cifrado opcional). **No** se recomienda en este homelab.
2. **Disco USB lento**: el _hd2t_ es un HDD rotacional 5400 RPM; escritura aleatoria de muchos ficheros pequeños cae a `< 20 MB/s`. Es físico, no SMB. Para test puro de SMB:
   ```bash
   # En el cliente:
   dd if=/dev/zero bs=1M count=1024 | smbclient //pi.lan/media -U homelab%<pass> -c 'put - bigfile.bin'
   # Medir tiempo. ~10 s = 100 MB/s = saturación de Gigabit.
   ```
3. **Cable Ethernet o switch a 100 Mbps**: `ethtool eth0 | grep Speed` desde el host. Si dice `100Mb/s`, hay un cable o puerto malo.

### `vfs_fruit` no funciona / ficheros macOS aparecen "rotos"

Síntoma: copiar carpetas de un Mac a la _share_ y volverlas a copiar a otro Mac pierde _tags_, comentarios y _resource forks_. Causa: `vfs objects = catia fruit streams_xattr` no está en el `[global]` o el sistema de ficheros del host **no** soporta `xattr`.

Verificar:

```bash
# El sistema de ficheros debe ser ext4 con user_xattr
mount | grep hd2t
# /dev/sdb1 on /mnt/hd2t type ext4 (rw,...,user_xattr,...)

# Test de xattr
sudo touch /mnt/hd2t/test
sudo setfattr -n user.test -v "hello" /mnt/hd2t/test
sudo getfattr -n user.test /mnt/hd2t/test
# Debe devolver: user.test="hello"
sudo rm /mnt/hd2t/test
```

Si `setfattr` falla, remontar `hd2t` con `user_xattr` (en `/etc/fstab`) y reiniciar. Esto debería estar ya resuelto por `00-hardware/03-preparacion-discos.md`.

### Usuarios borrados del passdb tras reiniciar el contenedor

Síntoma: `pdbedit -L` listó usuarios, se reinició el _stack_ y la lista vuelve a estar vacía. Causa: el bind-mount `/mnt/hd2t/services/samba/passdb` está mal o no es escribible para el UID con que corre _smbd_.

Verificar:

```bash
ls -la /mnt/hd2t/services/samba/passdb/
# Tras el primer arranque, debe contener passdb.tdb, secrets.tdb, etc.
sudo file /mnt/hd2t/services/samba/passdb/passdb.tdb
# TDB database
```

Si `passdb/` está vacío después de un arranque exitoso, comprobar que `/var/lib/samba/private/` dentro del contenedor está **realmente** _bind-mounted_:

```bash
docker exec samba mount | grep '/var/lib/samba/private'
# /dev/sdb1 on /var/lib/samba/private type ext4 (rw,relatime,...)
```

Si no aparece, hay un error en el `volumes:` del compose. Reescribir y `docker compose up -d samba`.

---

## Referencias

- ServerContainers Samba — Imagen Docker oficial: <https://github.com/ServerContainers/samba>
- ServerContainers Samba — _Tags_ disponibles: <https://github.com/ServerContainers/samba#tags>
- Samba — Documentación oficial: <https://www.samba.org/samba/docs/>
- Samba — `smb.conf` _man page_: <https://www.samba.org/samba/docs/current/man-html/smb.conf.5.html>
- Samba — _Hardening_ recomendado: <https://wiki.samba.org/index.php/Configure_Samba_to_Work_Better_with_Mac_OS_X>
- Samba — `vfs_fruit` (interop con macOS): <https://www.samba.org/samba/docs/current/man-html/vfs_fruit.8.html>
- Samba — `vfs_streams_xattr`: <https://www.samba.org/samba/docs/current/man-html/vfs_streams_xattr.8.html>
- WSDD2 — Web Services Dynamic Discovery: <https://github.com/Netgear/wsdd2>
- Avahi — Anuncio de servicios mDNS: <https://www.avahi.org/>
- Microsoft — _Network Discovery and File Sharing_ en Windows 11: <https://support.microsoft.com/es-es/windows/uso-compartido-en-red-en-windows-b58704b2-f53a-4b39-7e6a-3d408c0f5658>
- Apple — _Connect a Mac to shared computers and servers_: <https://support.apple.com/guide/mac-help/mchlp1140/mac>
