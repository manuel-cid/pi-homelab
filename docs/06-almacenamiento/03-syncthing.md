# Syncthing (sincronización P2P de carpetas entre dispositivos)

## Descripción

Despliegue de **Syncthing** como motor de **sincronización peer-to-peer** del homelab. Cubre el caso de uso "una carpeta replicada en N dispositivos, sin servidor central, en tiempo casi-real": el operador edita un fichero en su portátil, Syncthing lo propaga al móvil, a la Pi y al ordenador de casa, sin pasar por la _cloud_ y sin que ninguno de los nodos sea "el maestro". Cada dispositivo se identifica por un **Device ID** (huella ed25519 de su certificado) y los cambios viajan **cifrados extremo a extremo** entre _peers_, incluso aunque pasen por relays públicos del propio proyecto.

En este homelab, la Pi se usa como **nodo siempre encendido** del enjambre Syncthing del operador: actúa como "espejo permanente" para que dos dispositivos que rara vez coinciden encendidos (móvil + portátil de fin de semana, por ejemplo) acaben sincronizándose **a través de la Pi** aunque nunca se vean directamente. Las carpetas viven en **hd2t** (`/mnt/hd2t/services/syncthing/data/`); el _config_ con identidad e índice en `/mnt/hd2t/services/syncthing/config/`. Nada en la microSD.

Este documento **extiende el _stack_ `almacen`** ya estrenado por Nextcloud (`docs/06-almacenamiento/01-nextcloud.md`) y ampliado por Samba (`docs/06-almacenamiento/02-samba.md`): el `~/homelab/almacen/docker-compose.yml` recibe un servicio `syncthing` adicional, conectado a la red `homelab` para que Caddy alcance la GUI por nombre y publicado al host con dos puertos (`22000/tcp+udp` para sincronización con _peers_, `21027/udp` para descubrimiento local en la LAN).

> **Alcance**: este documento despliega **un solo Syncthing** con la GUI protegida detrás de **Caddy + Authelia** (`forward_auth`) y la sincronización entre _peers_ saliendo por los puertos del propio Syncthing publicados en el host. **No** crea carpetas concretas: documenta el procedimiento para emparejar el primer dispositivo y crear la primera carpeta compartida desde la UI, y deja referencias a casos típicos (auto-upload de fotos del móvil, sincronización del _vault_ de Obsidian, _vault_ de KeePass…). **No** activa el _untrusted folder encryption_ de Syncthing (sólo necesario si la Pi reenvía datos a un peer "no confiable", cosa que no es el caso aquí). **No** instala el _front_ web alternativo de terceros (la GUI nativa cubre todo).

> **Recordatorio de red**: la GUI HTTP de Syncthing **no se publica al host** (sólo es accesible vía Caddy: `https://syncthing.lan/`). Pi-hole resuelve `syncthing.lan → 192.168.1.3` por el _wildcard_ de `02-homelab-local.conf` (`docs/03-red/02-pihole.md`). En cambio, los puertos de **sincronización** entre _peers_ (`22000/tcp` + `22000/udp` QUIC) y el de **descubrimiento local** (`21027/udp`) **sí** se publican al host porque los dispositivos hablan directamente con Syncthing por su protocolo binario, no por HTTP. El acceso desde fuera de la LAN (móvil del operador en datos móviles, portátil en otra red) se hace **por Tailscale**: Syncthing escucha también en `tailscale0` gracias a que se publica con `0.0.0.0:22000`, y los _peers_ remotos se configuran con la IP `100.x.y.z` de la Pi.

---

## Requisitos previos

- `docs/00-hardware/03-preparacion-discos.md` completado: `hd2t` montado en `/mnt/hd2t` y formateado en ext4 con _xattr_ habilitado (Syncthing usa `xattr` para marcar ficheros como "ignorar" en algunos casos; ext4 los soporta de fábrica).
- `docs/01-sistema/04-estructura-directorios.md` completado: existe `/mnt/hd2t/services/syncthing/` vacío con ownership `1000:1000` (la imagen es de la familia LinuxServer.io y se reasignó como tal en el paso 7 de ese documento). En este documento se crean los subdirectorios `config/` y `data/`.
- `docs/01-sistema/03-seguridad-base.md` completado: el firewall `nftables` está activo con _input drop_ por defecto. Este documento añade explícitamente reglas para `22000/tcp`, `22000/udp` y `21027/udp` desde la LAN y el rango Tailscale.
- `docs/02-docker/02-estructura-compose.md` completado: la red `homelab` (`br-homelab`, `172.20.10.0/24`) externa existe, el `~/homelab/.env` global expone `TZ`, `PUID=1000`, `PGID=1000`, `MEDIA_GID=<gid de homelab-media>` y `HOMELAB_DOMAIN=lan`, y el _Makefile_ ofrece `make up STACK=almacen`.
- `docs/02-docker/04-watchtower.md` completado: la convención `com.centurylinklabs.watchtower.enable` está documentada. Syncthing será **opt-out** explícito (justificación en **Decisiones de diseño**).
- `docs/03-red/02-pihole.md` completado: Pi-hole resuelve `*.lan → 192.168.1.3`. **No hay que añadir nada** para `syncthing.lan` — el _wildcard_ ya lo cubre.
- `docs/03-red/04-caddy.md` completado: Caddy escucha en `192.168.1.3:443` con `tls internal`, los _snippets_ `security-headers.caddy`, `logging.caddy` y `authelia.caddy` existen, y la directiva `import /etc/caddy/snippets/*.caddy` está activa en el `Caddyfile`. La CA local ya firma `*.lan`.
- `docs/03-red/05-tailscale.md` completado: la Pi tiene IP `100.x.y.z` en la _tailnet_ y `tailscale0` está activa. El acceso remoto a Syncthing se hará por esa IP, sin abrir puertos en el router.
- `docs/04-seguridad/01-authelia.md` completado: el _snippet_ `authelia.caddy` ya está rellenado, el portal `https://auth.lan/` funciona y los usuarios del `users_database.yml` pueden autenticarse con TOTP.
- `docs/06-almacenamiento/01-nextcloud.md` completado: el _stack_ `almacen` está vivo (`~/homelab/almacen/docker-compose.yml`, `.env`, `.env.example`, `.gitignore`). Este documento **añade** un servicio al mismo `docker-compose.yml`, no crea uno nuevo.
- Conectividad saliente para descargar la imagen (sólo la primera vez):

  ```bash
  docker pull --platform linux/arm64 \
    lscr.io/linuxserver/syncthing:1.30.0 \
    >/dev/null && echo OK
  ```

  El _tag_ exacto se consulta en <https://github.com/linuxserver/docker-syncthing/pkgs/container/syncthing>; la convención del homelab prohíbe `:latest` (ver `docs/02-docker/02-estructura-compose.md`, sección **Imágenes**). Pinear a un _minor_ concreto (`1.30.0`, no `1.30`) para que un _bump_ de Syncthing sea siempre una decisión humana documentada.
- Que ningún proceso del host esté usando los puertos `22000` ni `21027`:

  ```bash
  ss -tlnp 'sport = :22000' && ss -ulnp 'sport = :22000' && ss -ulnp 'sport = :21027'
  # Las tres consultas deben devolver sólo el header sin filas — puertos libres.
  ```

  En particular, si en algún momento se probó un Syncthing nativo del host (`apt install syncthing`), pararlo y desinstalarlo:

  ```bash
  systemctl --user status syncthing 2>/dev/null
  systemctl status syncthing@homelab 2>/dev/null
  sudo apt purge syncthing syncthing-discosrv syncthing-relaysrv 2>/dev/null
  ```

---

## Decisiones de diseño

### Por qué Syncthing (y no Nextcloud / rsync / Unison / Resilio)

El homelab ya tiene **Nextcloud** (`01-nextcloud.md`) para sincronización con servidor central y **Samba** (`02-samba.md`) para _share_ pasivo de red. Syncthing cubre un caso distinto: **sincronización P2P, sin servidor central, en tiempo casi-real, multi-dispositivo, _eventually consistent_ sin que ningún nodo sea autoritativo**. Cuatro alternativas descartadas y por qué:

| Candidato      | Por qué se descarta                                                                                                                                                                                          |
|----------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **Nextcloud sync clients** | Buenos para "ficheros del usuario que llegan a la nube y se descargan en N dispositivos", pero el cliente de escritorio **necesita** que el servidor (Nextcloud) esté disponible para cada cambio. Si la Pi cae, los cambios entre el portátil y el móvil **no fluyen** aunque ambos estén en la misma WiFi. Syncthing sí los propaga _peer-to-peer_. |
| **rsync** + cron | Excelente para "snapshot periódico desde el origen al destino", pero no es bidireccional, no detecta conflictos, no funciona si los dispositivos no están encendidos a la vez, y no tiene cliente móvil decente. Se usa para backups (Borg lo internaliza), no para sincronización viva. |
| **Unison**     | Bidireccional pero requiere ejecución manual sincronizada en ambos extremos; no hay cliente móvil; el binario en ARM64 no está empaquetado en la mayoría de distros. Inviable para un homelab familiar.     |
| **Resilio Sync** (BitTorrent Sync) | Modelo similar a Syncthing pero **propietario**. Cliente Linux/ARM64 vivo, pero las versiones gratuitas tienen límites artificiales (número de carpetas, _device approval_) y la _telemetría_ es opaca. Cuando existe un open-source equivalente, se prefiere. |

Syncthing gana por:

- **100 % open-source** (MPL-2.0), binario Go, _release cycle_ predecible (un _minor_ cada ~6 meses), sin telemetría.
- **Sin servidor central**: cada nodo es _peer_. Un descubrimiento global público (`global.syncthing.net`) y _relays_ públicos (operados por la fundación y voluntarios) cubren el caso de NAT/CGNAT, pero los _peers_ pueden conectar directamente cuando hay ruta. En este homelab, la ruta directa **siempre** existe (LAN o Tailscale), así que los relays casi nunca se usan.
- **Cifrado extremo a extremo**: TLS 1.3 entre _peers_, autenticación por _certificate pinning_ (Device ID = SHA-256 del cert). Los relays públicos ven _bytes_ cifrados, nada más.
- **Clientes maduros en todas las plataformas**: Linux/Windows/macOS (oficiales), Android (`Syncthing-Fork`, mantenido), iOS (`Möbius Sync`, _third-party_ con código abierto). Una buena UI web embebida cubre lo demás.
- **Carpetas con políticas distintas**: cada carpeta puede ser _send-only_, _receive-only_ o _send & receive_, y cada lado puede declarar la suya independientemente. Útil para "el móvil _send-only_ de fotos, la Pi _receive-only_, el portátil _read-only_".
- **Versionado de ficheros**: borrar un fichero en un _peer_ no lo elimina del resto; Syncthing puede mantener N versiones (configurable: _trashcan_, _simple_, _staggered_, _external_). Esto evita el clásico susto de "borré y se sincronizó".

### Imagen: `lscr.io/linuxserver/syncthing`

Hay tres familias de imágenes Docker para Syncthing; se elige la siguiente:

| Imagen                                  | Estado                | Razón                                                                                                                                                |
|-----------------------------------------|-----------------------|------------------------------------------------------------------------------------------------------------------------------------------------------|
| `syncthing/syncthing` (oficial)         | Activa                | Es la del propio proyecto; multi-arch ARM64 OK. Pero corre como `syncthing:syncthing` (UID `1000` _hard-coded_) y no permite ajustar `PUID`/`PGID`, lo que rompe la convención del homelab (ver `04-estructura-directorios.md`). |
| `linuxserver/syncthing` ✅              | Muy activa (releases cada 1–2 semanas siguiendo upstream) | Multi-arch ARM64, soporta `PUID`/`PGID` para mapear el UID del host, `umask` configurable, _entrypoint_ con `s6-overlay` ya endurecido y muy probado. Encaja con todos los demás servicios LSIO del homelab (Jellyfin, Sonarr, Radarr…). **Elección del homelab**. |
| `crazymax/syncthing`                    | Sin _commits_ desde 2023 | Imagen popular antes de que LSIO la tuviera; ya en deuda con _patches_ recientes. No considerar.                                                |

_Tag_ pinneado a la versión _minor_ exacta (ej. `lscr.io/linuxserver/syncthing:1.30.0`). LSIO mantiene también _tags_ con _build_ del wrapper (`1.30.0-ls192`); pinear al _tag_ corto es suficiente — Watchtower (cuando se active el _opt-in_, ver siguiente sección) recoge re-builds del mismo _minor_ sin que cambie el _tag_.

### Watchtower opt-out

Razones:

- Syncthing usa una **base de datos de índice** propia (LevelDB hasta v1.24, `bolt` desde v1.25, mecanismo de migración _on the fly_) bajo `/config/index-v0.14.0.db/` (o el sufijo correspondiente). Una actualización opaca que cruce un cambio de formato puede arrancar con una migración de varias horas en USB HDD si el índice tiene millones de ficheros (típico tras un par de años de uso). Mejor planificar la ventana.
- Las opciones del **protocolo de sincronización** (BEP, _Block Exchange Protocol_) son retro-compatibles, pero entre _majors_ pueden cambiar _defaults_ (compresión, tamaño de bloque, _hashing algorithm_). Un _bump_ silencioso introduce contención si el resto del enjambre del operador (móvil con `Syncthing-Fork`, portátil con la 1.27 _stable_…) está en otra _minor_.
- Mid-sync restart **no corrompe** datos (Syncthing usa _hash_ por bloque y reanuda transferencia), pero sí **interrumpe** la sincronización durante 30–60 s y deja _temp files_ (`.syncthing.<file>.tmp`) que el siguiente arranque limpia. Aceptable, pero merece una ventana intencional, no un sábado a las 4 AM "de Watchtower".
- LSIO publica re-builds del wrapper varias veces por semana (parches de S6, base Alpine, etc.). Aplicarlos automáticamente sin coordinarlos con el _bump_ de Syncthing genera ruido.

Etiquetar el contenedor con `com.centurylinklabs.watchtower.enable: "false"`. Las actualizaciones se hacen leyendo el _changelog_ de Syncthing (<https://github.com/syncthing/syncthing/releases>) y los _release notes_ de LSIO (<https://github.com/linuxserver/docker-syncthing/releases>), parando primero el contenedor para evitar que arranque a medio _pull_.

### Modo de red: `bridge` en `homelab` con `ports:` para sync, **no** `host`

Samba se desplegó con `network_mode: host` porque _wsdd2_ y Avahi exigen poder emitir _multicasts_ a la LAN desde la pila de red del host. Syncthing **no** tiene esa restricción dura: su descubrimiento local (`21027/udp` _multicast_) **es deseable** pero no esencial — los _peers_ se pueden añadir explícitamente por Device ID + dirección estática. Por tanto, se elige **bridge** y se publica sólo lo imprescindible:

| Modo                 | GUI accesible vía Caddy            | Sync con peers (22000)        | Local discovery (21027 multicast) | Veredicto                                                                       |
|----------------------|------------------------------------|-------------------------------|-----------------------------------|---------------------------------------------------------------------------------|
| `bridge` + `homelab` ✅ | Sí (`reverse_proxy syncthing:8384`) | Sí (puerto publicado al host) | **Limitado** (multicast no atraviesa el bridge en Linux por defecto) | **Elección del homelab**. Coherente con Nextcloud, Authelia, Pi-hole. La pérdida de _multicast_ se mitiga añadiendo cada _peer_ por Device ID, lo que ya es la práctica recomendada por seguridad. |
| `host`               | Necesitaría `host.docker.internal` o IP del bridge gateway en el `reverse_proxy` | Sí | Sí | Funciona pero rompe la convención "el _front_ se alcanza por nombre en `homelab`". |
| `macvlan` con IP propia | Sí (vía Caddy)                  | Sí                            | Sí                                | Cumple, pero pide otra IP de la LAN para un servicio que no la necesita; ya hay tres IPs reservadas (Pi-hole `.2`, Pi `.3`, Unbound `.4`). No se justifica. |

Consecuencias prácticas del modo bridge:

- **GUI**: Caddy hace `reverse_proxy syncthing:8384` por DNS interno de Docker. La GUI nunca se expone al host directamente (`8384` no aparece en `ports:`).
- **Sync**: se publica `22000:22000/tcp` y `22000:22000/udp` (QUIC) al host. Cualquier _peer_ del operador (movile en LAN, portátil por Tailscale) llega a `192.168.1.3:22000` o `100.x.y.z:22000`.
- **Local discovery**: el _multicast_ saliente (Syncthing → LAN) tampoco atraviesa el bridge por defecto. Como _workaround_ documentado, se publica `21027:21027/udp` para que la _broadcast_ entrante sí llegue, y los anuncios salientes se sustituyen por **anuncios estáticos** vía la propia configuración de Syncthing (campo "Address" del peer, ya que _Global Discovery_ está activo por defecto y resuelve a través de los servidores públicos del proyecto la dirección del peer si el operador la registra).
- **Global discovery** (servidores públicos `global.syncthing.net`): activo, no necesita puertos extra, sale por la conexión normal del contenedor.
- **Relays públicos** (NAT punching cuando una conexión directa no es posible): activo por defecto. En este homelab casi nunca se usa, pero queda activo como _fallback_.

> **Por qué publicar también `21027/udp` aunque no haga _multicast_ saliente correctamente**: porque los _peers_ que estén en la LAN **sí** anuncian con _multicast_ y Syncthing los recibe a través del puerto publicado. Es asimétrico pero útil: la Pi descubre, no se anuncia.

### `forward_auth` con Authelia: **SÍ** aplica para la GUI

A diferencia de Nextcloud (donde Authelia rompería los _clients_ WebDAV) y Samba (donde Authelia es físicamente imposible porque SMB no es HTTP), en Syncthing **sí** tiene sentido poner Authelia delante. Razones:

- La GUI/API de Syncthing **es HTTP puro** y la utilizan **sólo humanos** desde un navegador. Los _peers_ que sincronizan datos hablan el protocolo BEP por TCP/22000 y QUIC/22000, **sin pasar por la GUI**.
- Por tanto, ningún cliente automatizado (móvil, portátil, otra Pi) verá la GUI: protegerla con SSO no rompe nada.
- La capa de Authelia añade **TOTP de fábrica** sobre la GUI, complementando el _basic auth_ propio de Syncthing.

Configuración:

- En el `Caddyfile`, el bloque `syncthing.lan` lleva `import authelia`.
- El _basic auth_ propio de Syncthing **se mantiene activo** (no se desactiva): el operador completa Authelia → llega a la pantalla de login de Syncthing → introduce el usuario/contraseña que se fijan en este documento. La doble autenticación es deliberada (defensa en profundidad: si alguien _bypassea_ Caddy llegando al contenedor por DNS interno desde otro contenedor del _stack_, la GUI sigue requiriendo credenciales). En la práctica el navegador guarda ambas credenciales y el operador entra con dos clics en sesiones siguientes.

### Identidad del nodo: el `cert.pem`/`key.pem` de `/config` es la **clave maestra**

Syncthing genera al primer arranque dos ficheros bajo `/config/`:

- `cert.pem` — certificado X.509 _self-signed_ que identifica al nodo.
- `key.pem` — clave privada ed25519 asociada.

El **Device ID** del nodo es el _hash_ SHA-256 del certificado (codificado en _base32_ con _check digit_). **Si se pierde** `cert.pem`/`key.pem`, el nodo arranca con un nuevo Device ID distinto, y todos los _peers_ del operador tienen que volver a aprobarlo (cada uno: pop-up _"Add device?"_ en su GUI). En un enjambre de 5–10 dispositivos, eso es un trabajo manual considerable.

Consecuencias:

- `/config/` **se respalda con Borgmatic** con frecuencia agresiva (a diario; ocupa MB, no GB).
- En `Decisiones de diseño → Almacenamiento`, `/mnt/hd2t/services/syncthing/config/` queda en el _set_ "config" del _backup_, prioritario sobre `data/`.
- Tras una catástrofe (microSD muerta, hd2t formateado), restaurar `config/` desde Borg recupera la identidad del nodo y el resto del enjambre lo reconoce sin pop-ups.

> **Variante "rotar Device ID a propósito"**: si el operador alguna vez quiere "renacer" el nodo (por ejemplo, descomisionar la Pi vieja y montarla limpia), basta con **no** restaurar `config/`. El nuevo nodo arranca con Device ID nuevo y el enjambre lo aprueba como si fuera la primera vez.

### Ownership de `/data/`: `1000:1000` por defecto, opción de `1000:homelab-media` para fotos

Syncthing escribe los ficheros recibidos con el UID/GID del proceso (`PUID`/`PGID` de la imagen LSIO). Caso por caso:

| Carpeta sincronizada                                 | Quién más la lee                       | `PGID` recomendado                          |
|------------------------------------------------------|----------------------------------------|---------------------------------------------|
| `/data/personal/` (notas, documentos, _vaults_…)     | Sólo el operador en su navegador / SFTP | `1000` (por defecto, igual a `PUID`)        |
| `/data/photos-from-mobile/` (auto-upload del móvil)  | Jellyfin, Photos app de Nextcloud, …   | `${MEDIA_GID}` (= GID del grupo `homelab-media`) |
| `/data/family-shared/` (contenido entre miembros)    | Eventualmente Samba o Nextcloud        | `${MEDIA_GID}` si pasa a `services/shared/`   |

Por **simplicidad**, este documento despliega Syncthing con `PUID=${PUID}` y `PGID=${PGID}` (= `1000:1000`). Las carpetas que necesiten ser leídas por Jellyfin u otros servicios LSIO se montan **en sus propias rutas** dentro de `services/shared/` y se accede a ellas desde Syncthing via _bind mount_ explícito (ver **Configuración tras primer arranque → Crear una carpeta para fotos del móvil**).

### Almacenamiento

| Ruta en el host                                          | Contenido                                              | Versionable | Backup                                  |
|----------------------------------------------------------|--------------------------------------------------------|-------------|-----------------------------------------|
| `~/homelab/almacen/docker-compose.yml`                   | Definición del _stack_ (extendida con `syncthing`)     | git         | git                                     |
| `~/homelab/almacen/.env`                                 | _Tag_ de la imagen + _password_ de la GUI Syncthing    | **NO** (`.gitignore`) | nota local                  |
| `/mnt/hd2t/services/syncthing/config/`                   | `cert.pem`, `key.pem`, `config.xml`, índice LevelDB     | **NO**      | **Sí** (Borgmatic — _set_ "config", retención larga) |
| `/mnt/hd2t/services/syncthing/data/`                     | Carpetas sincronizadas (puede crecer mucho)            | **NO**      | **Sí** (Borgmatic — _set_ "shared", retención por uso) |
| `/mnt/hd2t/services/shared/<nombre>/` (carpeta dedicada) | Contenido sincronizado **y** leído por otros servicios | **NO**      | **Sí** (Borgmatic — _set_ "shared")     |

> **Por qué `config/` separado de `data/`**: `config/` ocupa MB y es **crítico** (la identidad del nodo está ahí). `data/` puede ocupar cientos de GB y es **regenerable** desde otros _peers_ (si la Pi pierde `data/` pero conserva `config/`, los demás dispositivos rellenan a la Pi en el siguiente sync). Por tanto las políticas de _backup_ son distintas: `config/` se respalda a diario y con retención larga; `data/` se respalda menos frecuentemente y con retención por uso, asumiendo que en muchos casos los datos viven en al menos 2 dispositivos del operador y la Pi es uno más, no la única copia.

> **Aviso sobre _trashcan/staggered versioning_**: si el operador activa _versionado de ficheros_ en una carpeta, Syncthing crea `.stversions/` dentro de la carpeta. Esto puede crecer mucho. Configurar políticas de retención por carpeta (Syncthing: _Folder → Edit → File Versioning_) y excluirla del _backup_ con Borgmatic si ya cumple ese rol.

---

## Estructura del _stack_ `almacen` tras este documento

```
~/homelab/almacen/
├── docker-compose.yml        # ← extendido con servicio 'syncthing'
├── .env                      # ← extendido con SYNCTHING_*, STGUI_*
├── .env.example              # ← extendido (sin valores reales)
├── .gitignore                # ya existía
└── smb/
    └── smb.conf              # creado en 02-samba.md
```

Y en el disco externo, sobre lo ya creado por `04-estructura-directorios.md`:

```
/mnt/hd2t/services/syncthing/
├── config/                   # ← nuevo (vacío, lo puebla el entrypoint)
└── data/                     # ← nuevo (vacío, el operador lo puebla con carpetas)
```

Crear los subdirectorios con ownership LSIO:

```bash
sudo mkdir -p /mnt/hd2t/services/syncthing/{config,data}
sudo chown -R 1000:1000 /mnt/hd2t/services/syncthing
sudo chmod 0755 /mnt/hd2t/services/syncthing/{config,data}
```

> **Nota**: el directorio `/mnt/hd2t/services/syncthing/` ya tenía ownership `1000:1000` aplicada por el paso 7 de `docs/01-sistema/04-estructura-directorios.md` (la regla "imágenes LSIO"). El `chown -R` aquí es idempotente y cubre los subdirectorios recién creados.

---

## Variables de entorno

Añadir al final de `~/homelab/almacen/.env.example` (versionado, sin valores reales):

```bash
# --- Syncthing -------------------------------------------------------------
# Imagen pinneada — consultar el repo LSIO para el tag más reciente:
# https://github.com/linuxserver/docker-syncthing/pkgs/container/syncthing
SYNCTHING_IMAGE_TAG=1.30.0

# Credenciales de la GUI HTTP (basic auth interno de Syncthing).
# Authelia ya protege syncthing.lan delante; este es el segundo factor de
# defensa en profundidad. La password se genera con:
#   openssl rand -base64 24 | tr -d '/+=' | head -c 24
# Guardarla en Vaultwarden cuando llegue su fase.
STGUI_USER=homelab
STGUI_PASS=
```

Generar la _password_ de la GUI y añadirla al `.env`:

```bash
cd ~/homelab/almacen

st_pass=$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)

{
  echo ""
  echo "# --- Syncthing ---"
  echo "SYNCTHING_IMAGE_TAG=1.30.0"
  echo "STGUI_USER=homelab"
  echo "STGUI_PASS=$st_pass"
} >> .env

chmod 0600 .env

echo "Syncthing GUI password: $st_pass"
unset st_pass
```

> **`tr -d '/+='`**: el _basic auth_ de Syncthing se introduce en un formulario HTML, así que técnicamente cualquier carácter vale, pero `/`, `+` y `=` se cuelan en URLs `https://user:pass@syncthing.lan/` que el operador puede escribir en una _bookmark_. Eliminarlos evita problemas de _escaping_ sin reducir la entropía significativamente (24 chars Base64 menos 3 chars sobre alfabeto de 61 ≈ 142 bits).

> **`STGUI_USER`/`STGUI_PASS` no son variables que la imagen LSIO consuma directamente**: son sólo _placeholders_ del homelab para que la _password_ esté en `.env` y sea reutilizable por el operador al escribir en la UI. Syncthing **no** soporta inyectar credenciales por _env_ al primer arranque (es una decisión del proyecto: prefieren que el operador las fije en la UI). El _flujo_ documentado en **Despliegue** explica cómo Syncthing pide que se fijen en el primer acceso a la GUI.

---

## `~/homelab/almacen/docker-compose.yml`: añadir `syncthing`

Editar el `docker-compose.yml` ya creado por `01-nextcloud.md` (extendido por `02-samba.md`) y añadir, **bajo la clave `services:`**, el siguiente bloque al final (tras `samba`):

```yaml
  # ---------------------------------------------------------------------------
  # Syncthing — sincronización P2P entre dispositivos del operador.
  # GUI HTTP en 'homelab' (Caddy la alcanza por nombre 'syncthing:8384').
  # Sync de peers en puertos 22000 (TCP+UDP/QUIC) publicados al host.
  # Local discovery en 21027/UDP publicado al host.
  # No participa en 'almacen-internal' (no necesita hablar con MariaDB/Redis).
  # ---------------------------------------------------------------------------
  syncthing:
    image: lscr.io/linuxserver/syncthing:${SYNCTHING_IMAGE_TAG}
    container_name: syncthing
    hostname: syncthing
    restart: unless-stopped
    environment:
      TZ: ${TZ}
      PUID: ${PUID}              # 1000 (homelab)
      PGID: ${PGID}              # 1000 (homelab)
      UMASK: "022"               # ficheros 0644, dirs 0755
    volumes:
      - /mnt/hd2t/services/syncthing/config:/config
      - /mnt/hd2t/services/syncthing/data:/data
      # Bind-mount adicional para sincronizar fotos hacia services/shared/.
      # Comentado por defecto: el operador lo descomenta cuando quiera
      # auto-upload del móvil legible por Jellyfin/Nextcloud Photos.
      # Activarlo requiere también añadir PGID=${MEDIA_GID} arriba (o un
      # 'group_add' explícito) para que los ficheros queden con el grupo
      # correcto. Ver 'Crear una carpeta para fotos del móvil' más abajo.
      # - /mnt/hd2t/services/shared/media/photos:/data/shared-photos
    ports:
      # Sync de peers — TCP + QUIC en 22000 (mismo puerto, dos protocolos)
      - "22000:22000/tcp"
      - "22000:22000/udp"
      # Local discovery (multicast entrante) — sin esto la Pi no detecta
      # peers nuevos que aparezcan en la LAN. NO se publica si el homelab
      # nunca tendrá peers en la misma WiFi (improbable: el caso típico
      # es móvil + portátil del operador en casa).
      - "21027:21027/udp"
    networks:
      homelab:
        aliases:
          - syncthing            # Caddy resuelve 'syncthing:8384' por este alias
    labels:
      homelab.stack: "almacen"
      homelab.backup: "true"     # /mnt/hd2t/services/syncthing/{config,data} (Borgmatic)
      # Opt-out: bumps cambian formato del índice. Manual.
      com.centurylinklabs.watchtower.enable: "false"
    healthcheck:
      # La GUI responde 401 (basic auth) si está sana. Cualquier otra cosa
      # (Connection refused, timeout, 500) indica que smbd no arrancó.
      test:
        - CMD-SHELL
        - "curl -fsS -o /dev/null -w '%{http_code}' http://localhost:8384/ | grep -qE '^(200|401)$'"
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 30s
```

Notas de diseño:

- **Sólo `homelab`, no `almacen-internal`**: Syncthing es el _front_ que Caddy alcanza por nombre, pero **no** habla con la BD ni con Redis. Mantenerlo fuera de `almacen-internal` reduce la superficie de ataque (un Syncthing comprometido no llega a MariaDB).
- **`ports:` deliberadamente cortos**: sólo `22000` (TCP+UDP) y `21027` (UDP). Nunca `8384` (la GUI sólo se accede por Caddy). El _design_ es coherente con "los servicios web no exponen su puerto al host; los servicios de protocolo binario sí".
- **Sin `cap_add`**: Syncthing no necesita _capabilities_ Linux extra. Las imágenes LSIO arrancan como _root_ (el _entrypoint_ de S6) y _drop_ a `abc:abc` (= `PUID:PGID` mapeados) tras configurar permisos. Sin _privileged_, sin _net_admin_.
- **Sin `depends_on`**: Syncthing es independiente del resto del _stack_. Si Nextcloud está parado por mantenimiento, Syncthing sigue sincronizando sus carpetas con peers.
- **Healthcheck sin _basic auth_**: la GUI responde `401 Unauthorized` cuando el _basic auth_ está activado pero responde igualmente "estoy viva". El `grep -qE '^(200|401)$'` cubre el primer arranque (todavía sin _basic auth_, código 200) y el régimen normal (con _basic auth_, código 401). Cualquier otro código (`000` por timeout, `502` por crash interno) marca _unhealthy_.

---

## Despliegue

### Primer arranque

```bash
cd ~/homelab/almacen

# Validar que la sintaxis del compose extendido sigue OK
docker compose --env-file ../.env --env-file .env config syncthing | head -40

# Levantar el servicio (el resto del stack ya está en marcha; Compose
# reconcilia y crea sólo el contenedor 'syncthing').
docker compose --env-file ../.env --env-file .env up -d syncthing
```

O, equivalente, con el _Makefile_ (ver `docs/02-docker/02-estructura-compose.md`):

```bash
cd ~/homelab
make up STACK=almacen
```

Comprobar el primer arranque:

```bash
docker logs syncthing --tail 50
# syncthing | [INFO] Starting syncthing s6-overlay v3...
# syncthing | [INFO] User uid:    1000
# syncthing | [INFO] User gid:    1000
# syncthing | INFO: My ID: AAAAAAA-BBBBBBB-CCCCCCC-DDDDDDD-EEEEEEE-FFFFFFF-GGGGGGG-HHHHHHH
# syncthing | INFO: GUI and API listening on [::]:8384
# syncthing | INFO: Access the GUI via the following URL: http://0.0.0.0:8384/
docker compose -f ~/homelab/almacen/docker-compose.yml ps syncthing
# NAME        STATUS                   PORTS
# syncthing   Up X seconds (healthy)   0.0.0.0:21027->21027/udp, 0.0.0.0:22000->22000/tcp, 0.0.0.0:22000->22000/udp
```

Apuntar el **Device ID** del log (`My ID: ...`); se usa para emparejar al primer _peer_.

### Abrir 22000/TCP+UDP y 21027/UDP en el firewall

Si `nftables` está activo (recomendado por `docs/01-sistema/03-seguridad-base.md`), añadir las reglas:

```bash
# Sync de peers — TCP + QUIC desde LAN y Tailscale
sudo nft add rule inet filter input \
  ip saddr { 192.168.0.0/16, 100.64.0.0/10 } \
  tcp dport 22000 \
  accept comment '"Syncthing peer sync TCP"'

sudo nft add rule inet filter input \
  ip saddr { 192.168.0.0/16, 100.64.0.0/10 } \
  udp dport 22000 \
  accept comment '"Syncthing peer sync QUIC"'

# Local discovery — sólo desde LAN (no tiene sentido vía Tailscale)
sudo nft add rule inet filter input \
  ip saddr 192.168.0.0/16 \
  udp dport 21027 \
  accept comment '"Syncthing local discovery"'

# Persistir
sudo nft list ruleset > /etc/nftables.conf
```

Si el operador prefiere `ufw`, equivalente:

```bash
sudo ufw allow from 192.168.0.0/16 to any port 22000 proto tcp comment 'Syncthing LAN'
sudo ufw allow from 192.168.0.0/16 to any port 22000 proto udp comment 'Syncthing LAN QUIC'
sudo ufw allow from 100.64.0.0/10  to any port 22000 proto tcp comment 'Syncthing Tailscale'
sudo ufw allow from 100.64.0.0/10  to any port 22000 proto udp comment 'Syncthing Tailscale QUIC'
sudo ufw allow from 192.168.0.0/16 to any port 21027 proto udp comment 'Syncthing local discovery'
```

> **Por qué no abrir 21027 a Tailscale**: el descubrimiento local Syncthing usa _multicast_ a `[ff12::8384]` y `239.21.0.27`, restringido a la subred. En Tailscale (CGNAT) el _multicast_ no existe; los _peers_ remotos se localizan vía _global discovery_ o por dirección estática. Abrirlo sería ruido sin función.

### Caddy: bloque `syncthing.lan`

Editar `~/homelab/red/Caddyfile` y añadir el bloque (tras los bloques ya existentes — ver `docs/03-red/04-caddy.md` y `docs/04-seguridad/01-authelia.md`):

```caddyfile
syncthing.lan {
    tls internal
    import security-headers
    import logging
    import authelia

    # GUI de Syncthing — bind interno 0.0.0.0:8384 (LSIO default).
    # Caddy termina TLS y reenvía HTTP plano dentro de 'homelab'.
    reverse_proxy syncthing:8384 {
        # Syncthing aplica un check de Host header contra su 'gui.address'
        # para mitigar DNS rebinding. Pasarle el Host original deja que
        # Syncthing vea 'syncthing.lan'. La primera vez que se acceda,
        # Syncthing puede mostrar un aviso 'Host check' pidiendo confirmar
        # que es un host legítimo; aceptarlo con el botón 'Trust this host'.
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}

        # Syncthing usa SSE (Server-Sent Events) para la pestaña 'Recent
        # changes'. Caddy 2 los maneja transparentemente, pero subir el
        # timeout de read evita desconexiones espurias en pestañas abiertas
        # mucho tiempo.
        transport http {
            read_timeout 10m
        }
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
curl -k --resolve syncthing.lan:443:192.168.1.3 -I https://syncthing.lan/
# HTTP/2 302 (redir a auth.lan/?rd=...) ← Authelia activo
# o
# HTTP/2 401 (basic auth de Syncthing)  ← si ya hay sesión Authelia válida
```

Y desde el navegador: `https://syncthing.lan/` → portal Authelia → tras autenticarse, la GUI de Syncthing pide _basic auth_ (la primera vez, está abierta sin _basic auth_; ver siguiente sección).

---

## Configuración tras primer arranque

### Fijar el _basic auth_ de la GUI

En el primer acceso a `https://syncthing.lan/` (tras pasar Authelia), Syncthing muestra un aviso "**Danger! The GUI is not protected!**" con un botón "**Settings**". Pulsarlo, ir a la pestaña **GUI**, y:

- **GUI Authentication User**: `homelab` (= `STGUI_USER` del `.env`).
- **GUI Authentication Password**: pegar la _password_ generada (= `STGUI_PASS` del `.env`).
- **GUI Listen Address**: dejar `0.0.0.0:8384` (es el default LSIO).
- **Use HTTPS for GUI**: **desactivado** (Caddy ya termina TLS; Syncthing en HTTPS internamente complicaría el _reverse proxy_).
- **Anonymous Usage Reporting**: a discreción del operador. Por defecto desactivado.

Guardar. Syncthing recarga la GUI y pide login → `homelab` + password.

> **Verificar `config.xml`** (opcional, para `git diff`-ear lo que cambió):
> ```bash
> docker exec syncthing cat /config/config.xml | grep -A4 '<gui'
> # <gui enabled="true" tls="false" debugging="false" ...>
> #     <address>0.0.0.0:8384</address>
> #     <user>homelab</user>
> #     <password>$2a$10$...</password>   ← bcrypt, no la password en claro
> # </gui>
> ```

### Verificar que el host check no bloquea `syncthing.lan`

Syncthing implementa _DNS rebinding protection_: si recibe una petición HTTP con `Host: syncthing.lan` pero el `gui.address` está en `0.0.0.0:8384`, evalúa si el host es de confianza. La regla es:

- Si `gui.address` está bound a una IP específica (no `0.0.0.0`): rechaza cualquier `Host` distinto.
- Si `gui.address` está en `0.0.0.0:8384`: permite cualquier `Host` por defecto, pero presenta el aviso "**Host check error**" la primera vez que llega un `Host` no privado (`syncthing.lan` cuenta como público).

Si aparece el aviso "_Host check error_", añadir `syncthing.lan` a la lista de hosts confiables. Dos formas:

1. **UI**: _Settings → GUI → Allowed Hosts_ → añadir `syncthing.lan`. Guardar.
2. **`config.xml`** (manual): editar `/config/config.xml` dentro del contenedor:
   ```bash
   docker exec -it syncthing sh -c "sed -i 's|<address>0.0.0.0:8384</address>|<address>0.0.0.0:8384</address>\n        <insecureSkipHostcheck>true</insecureSkipHostcheck>|' /config/config.xml"
   docker compose -f ~/homelab/almacen/docker-compose.yml restart syncthing
   ```

   `insecureSkipHostcheck=true` desactiva la protección DNS-rebinding completa. Es **aceptable aquí** porque Authelia ya hace gatekeeping y ningún cliente automatizado llega a la GUI; no se gana nada con la protección extra.

### Confirmar el Device ID de la Pi

```bash
docker exec syncthing cat /config/config.xml | grep -E 'myID|<device id=' | head
# <device id="AAAAAAA-BBBBBBB-...-HHHHHHH" name="syncthing" ...>
```

O desde la propia GUI: _Actions → Show ID_ (esquina superior derecha). Anotarlo: es lo que se introduce en cada _peer_ del operador para emparejar con la Pi.

### Crear la primera carpeta compartida (caso "personal docs")

1. En la GUI: **Add Folder**.
2. **Folder Path**: `/data/personal-docs` (Syncthing crea el subdirectorio dentro del _bind mount_).
3. **Folder ID**: dejar el aleatorio que Syncthing propone (o nombrarlo manualmente, ej. `personal-docs-aaaa`).
4. **Folder Type**: _Send & Receive_ (default, para sincronización bidireccional).
5. **File Versioning**: _Staggered_ (mantiene 1 versión por hora, día, semana hasta cierta antigüedad). Opcional pero recomendado.
6. **Sharing**: dejar vacío de momento; se añaden _peers_ tras emparejar el primer dispositivo.

Verificar desde el host:

```bash
ls -la /mnt/hd2t/services/syncthing/data/personal-docs/
# total 4
# drwxr-xr-x 2 homelab homelab 4096 ... .
# drwxr-xr-x 3 homelab homelab 4096 ... ..
# -rw-r--r-- 1 homelab homelab    0 ... .stfolder    ← marker que Syncthing crea
```

### Emparejar el primer dispositivo

En el dispositivo del operador (portátil con Syncthing instalado, móvil con `Syncthing-Fork`, etc.):

1. Abrir Syncthing en el dispositivo y copiar **su** Device ID.
2. En la GUI de la Pi: **Add Remote Device** → pegar el Device ID del dispositivo, ponerle un _Name_ ("portátil-x", "móvil-X").
3. **Addresses**: dejar `dynamic` (Global Discovery se encarga). Si el dispositivo está en la LAN, Syncthing lo detecta vía multicast (si está abierto el `21027/udp`) y populará la dirección automáticamente.
4. **Sharing**: marcar la carpeta `personal-docs` para compartirla con este device.
5. _Save_.
6. En el dispositivo del operador, Syncthing muestra un pop-up "**New device wants to connect**" con el Device ID de la Pi → _Add device_.
7. Tras añadir, otro pop-up "**This device wants to share folder ...**" → _Add folder_, elegir _Folder Path_ local en el dispositivo (ej. `~/Sync/personal-docs/`), _Save_.

En unos segundos, la sincronización inicial empieza. Verificar desde la GUI: barra de progreso en _Out of Sync Items_ y, al terminar, ambos lados con `Up to date 100%`.

### Crear una carpeta para fotos del móvil (caso "auto-upload" hacia `services/shared/`)

Si el operador quiere que las fotos del móvil acaben en `services/shared/media/photos/` para que Jellyfin/Nextcloud Photos las indexen, los pasos son:

1. **Activar el bind mount adicional** en `docker-compose.yml`. Editar el bloque `syncthing` y descomentar la línea:
   ```yaml
       - /mnt/hd2t/services/shared/media/photos:/data/shared-photos
   ```
2. **Cambiar el GID** del proceso para que los ficheros nuevos queden como `1000:homelab-media`. Dos formas equivalentes:

   - **Más limpia**: cambiar `PGID: ${PGID}` por `PGID: ${MEDIA_GID}` en `environment:` (pero esto afecta a todas las carpetas de Syncthing, no sólo a `shared-photos`).

   - **Mixta**: dejar `PGID: ${PGID}` y añadir un `group_add:` para que el proceso pertenezca también a `homelab-media`:
     ```yaml
         group_add:
           - "${MEDIA_GID}"
     ```
     Y configurar `umask 002` en lugar de `022` para que los ficheros sean `0664` (rw para grupo). El bit `setgid` ya activo en `/mnt/hd2t/services/shared/media/photos/` por `04-estructura-directorios.md` se encarga de que la carpeta de destino propague el GID correcto a los ficheros nuevos.

3. **Pre-crear el directorio en el host** con permisos correctos:
   ```bash
   sudo mkdir -p /mnt/hd2t/services/shared/media/photos
   sudo chown 1000:homelab-media /mnt/hd2t/services/shared/media/photos
   sudo chmod 2775 /mnt/hd2t/services/shared/media/photos
   ```

4. `docker compose up -d syncthing` para recargar el contenedor con el nuevo _bind mount_.

5. En la GUI de Syncthing: _Add Folder_ con **Folder Path** `/data/shared-photos`. Compartir con el device móvil.

6. En el móvil (Syncthing-Fork u otra app), configurar la carpeta de la cámara como **Send Only** (el móvil sólo envía, la Pi sólo recibe — evita que un borrado en el móvil borre fotos en la Pi).

> **Caveat**: la carpeta de fotos del móvil a menudo crece **muy rápido** (4 GB/mes en operadores activos). Considerar excluir `.stversions/` del backup de Borg para esta carpeta concreta (las "versiones" de fotos son redundantes con las copias en el móvil).

### Acceso desde un dispositivo remoto vía Tailscale

El device remoto (portátil del operador en otra red) accede a la Pi por su IP de Tailscale (`100.x.y.z`). En el _peer_ remoto, en _Add Remote Device_, en **Addresses** poner:

```
tcp://100.x.y.z:22000
```

Esto fuerza la conexión directa por Tailscale (no relay). Verificar que `tailscale status` muestra a la Pi como _peer_ activo.

> **Sin Tailscale**: el _global discovery_ de Syncthing (`global.syncthing.net`) registraría la dirección pública de la Pi (que en CGNAT puede ni existir) y la conexión iría por _relay_ públicos, lento y con tráfico cifrado pero pasando por terceros. Tailscale evita esto y da latencia LAN-like.

---

## Verificación final

Antes de pasar a `docs/06-almacenamiento/04-minio.md`, comprobar:

- [ ] `docker compose -f ~/homelab/almacen/docker-compose.yml ps syncthing` muestra `syncthing` en `(healthy)`.
- [ ] `docker logs syncthing --tail 20` muestra `INFO: GUI and API listening on [::]:8384` y `INFO: Detected NAT type: ...` (si aparece `Static`, el puerto 22000 está bien publicado).
- [ ] `ss -tlnp 'sport = :22000'` y `ss -ulnp 'sport = :22000'` muestran que `docker-proxy` (o el contenedor) está escuchando.
- [ ] `nft list ruleset | grep -E '(22000|21027)'` muestra las reglas de _allow_ desde LAN + Tailscale (o sólo LAN para 21027).
- [ ] `curl -k --resolve syncthing.lan:443:192.168.1.3 -I https://syncthing.lan/` devuelve `HTTP/2 302` con `Location: https://auth.lan/?rd=...` (Authelia activo) **o** `HTTP/2 401` si la sesión Authelia ya está activa (basic auth de Syncthing). En ningún caso `HTTP/2 200` directo, porque eso significaría que Authelia no se aplicó.
- [ ] Login interactivo desde el navegador funciona: portal Authelia → basic auth Syncthing (`STGUI_USER` + `STGUI_PASS` del `.env`) → GUI de Syncthing visible.
- [ ] El _Device ID_ de la Pi visible en _Actions → Show ID_ coincide con el que aparece en `docker exec syncthing cat /config/config.xml | grep -E 'myID|<device id='`.
- [ ] `cert.pem` y `key.pem` existen en `/mnt/hd2t/services/syncthing/config/`:
  ```bash
  ls -la /mnt/hd2t/services/syncthing/config/cert.pem /mnt/hd2t/services/syncthing/config/key.pem
  # -rw------- 1 homelab homelab 821 ... cert.pem
  # -rw------- 1 homelab homelab 244 ... key.pem
  ```
- [ ] El directorio `/mnt/hd2t/services/syncthing/data/` es accesible al UID `1000`:
  ```bash
  sudo -u homelab touch /mnt/hd2t/services/syncthing/data/.test && \
    sudo -u homelab rm /mnt/hd2t/services/syncthing/data/.test && \
    echo OK
  ```
- [ ] Tras crear la primera carpeta y emparejar el primer device, ambos lados muestran `Up to date 100%` en la GUI tras la sincronización inicial.
- [ ] Probar la sincronización: crear `prueba.txt` desde el _peer_ remoto, esperar 10–30 s, y verificar:
  ```bash
  ls -la /mnt/hd2t/services/syncthing/data/personal-docs/prueba.txt
  # -rw-r--r-- 1 homelab homelab N ... prueba.txt
  ```
- [ ] Borrar `prueba.txt` desde el _peer_ remoto, verificar que desaparece de la Pi (y, si _Staggered Versioning_ está activo, queda en `/mnt/hd2t/services/syncthing/data/personal-docs/.stversions/`).
- [ ] Tras un `sudo reboot` de la Pi, el _stack_ vuelve y `syncthing` queda `(healthy)` sin intervención. Los _peers_ se reconectan en <60 s.
- [ ] `git -C ~/homelab status` muestra como **modificados**: `almacen/docker-compose.yml`, `almacen/.env.example`, `red/Caddyfile`. **No** muestra `almacen/.env` ni nada bajo `/mnt/hd2t/`. _Commit_:

  ```bash
  cd ~/homelab
  git add almacen/docker-compose.yml almacen/.env.example red/Caddyfile
  git commit -m "feat(almacen): add Syncthing P2P with Authelia-protected GUI"
  ```

---

## Backup

| Qué                                          | Dónde                                                  | Cómo                                            |
|----------------------------------------------|--------------------------------------------------------|-------------------------------------------------|
| `docker-compose.yml`                         | `~/homelab/almacen/`                                   | git                                             |
| `.env` (con `STGUI_PASS`)                    | `~/homelab/almacen/.env`                               | nota local; password replicada en Vaultwarden   |
| `Caddyfile`                                  | `~/homelab/red/`                                       | git                                             |
| `config/` (cert, key, config.xml, índice)    | `/mnt/hd2t/services/syncthing/config/`                 | Borgmatic — _set_ "config", retención larga (90 días). **Crítico** (identidad del nodo). |
| `data/` (carpetas sincronizadas)             | `/mnt/hd2t/services/syncthing/data/`                   | Borgmatic — _set_ "shared", retención por uso. Excluir `**/.stversions/` (versionado interno) y `**/.stfolder` (markers vacíos). |
| Carpetas en `services/shared/`               | `/mnt/hd2t/services/shared/<carpeta>/`                 | Borgmatic — _set_ "shared", según la política de su servicio destino. |

> **Restauración del nodo Syncthing**: tras restaurar `/mnt/hd2t/services/syncthing/config/` desde Borg, un `docker compose up -d syncthing` arranca con el **mismo Device ID** que antes y los _peers_ del operador lo reconocen sin pop-ups. Si se restaura sólo `data/` pero no `config/`, el nodo arranca con Device ID nuevo y los _peers_ piden re-aprobación; los datos en `data/` quedan "huérfanos" hasta que el operador re-empareje y configure las carpetas de nuevo. **Restaurar siempre los dos juntos** salvo decisión deliberada de "renacer" el nodo.

> **Antes de un upgrade mayor de Syncthing (1.x → 2.x cuando llegue)**:
> 1. Backup _on-demand_ del _set_ "config" con Borgmatic.
> 2. Leer el _changelog_ de Syncthing y buscar "database migration" / "format change".
> 3. `docker compose stop syncthing`.
> 4. Editar `.env`: `SYNCTHING_IMAGE_TAG=<nuevo tag>`.
> 5. `docker compose up -d syncthing`.
> 6. Vigilar `docker logs -f syncthing` durante el primer arranque post-upgrade: si hay migración de índice, puede tardar **horas** en USB HDD para enjambres grandes. Hasta que termine, las carpetas aparecen como _Scanning..._ en la GUI.
> 7. Smoke test: la GUI vuelve a responder, los _peers_ se reconectan, una carpeta de prueba sincroniza correctamente un fichero nuevo.

---

## Troubleshooting

### El _peer_ no se descubre automáticamente en la LAN

Síntoma: el portátil del operador con Syncthing en la misma WiFi que la Pi no aparece como "_discoverable_". Causa típica: el _multicast_ Syncthing (`239.21.0.27` y `[ff12::8384]:21027`) no atraviesa el bridge Docker → contenedor en sentido saliente.

Workaround: configurar el _peer_ por Device ID + dirección estática (`tcp://192.168.1.3:22000`). Se hace una vez y queda persistido en el `config.xml` del _peer_.

Diagnóstico (desde el host):

```bash
# Multicast saliente desde la Pi: improbable que llegue
sudo tcpdump -i eth0 -n udp port 21027
# Sólo se verán paquetes ENTRANTES (desde otros peers de la LAN), no SALIENTES.
```

Solución alternativa (más invasiva, **no recomendada**): cambiar Syncthing a `network_mode: host`. Esto requiere también ajustar Caddy para alcanzarlo vía `host.docker.internal:8384` (con `extra_hosts: ["host.docker.internal:host-gateway"]`). Documento aquí pero no se aplica por defecto.

### `Host check error` en la GUI tras configurar Caddy

Síntoma: tras pasar Authelia, la GUI muestra una página "**Host check error**" en lugar del dashboard. Causa: Syncthing recibe `Host: syncthing.lan` y no lo tiene como host de confianza.

Solución (UI, si la página de error tiene un link "_Trust this host_"): pulsar el link.

Solución (manual, si no hay link):

```bash
# Editar config.xml: insertar <insecureSkipHostcheck>true</insecureSkipHostcheck>
# dentro del bloque <gui>.
docker exec syncthing sh -c "
  if ! grep -q insecureSkipHostcheck /config/config.xml; then
    sed -i 's|<address>0.0.0.0:8384</address>|<address>0.0.0.0:8384</address>\n        <insecureSkipHostcheck>true</insecureSkipHostcheck>|' /config/config.xml
  fi
"
docker compose -f ~/homelab/almacen/docker-compose.yml restart syncthing
```

> **Aceptable aquí porque** Authelia ya hace gatekeeping y la GUI nunca se expone al host directamente. Sin Authelia delante, mantener el _host check_ activo y añadir `syncthing.lan` a la lista blanca es preferible.

### Sync lento entre la Pi y un peer remoto

En Pi 5 con USB 3.0, esperable: ~50–80 MB/s sostenido sobre Tailscale (cuello de botella: cifrado WireGuard de Tailscale + AES-GCM de Syncthing en CPU; la Pi 5 hace ~600 MB/s de AES-GCM por _core_, pero con WireGuard encima la _throughput_ baja). Si se ve `< 5 MB/s`:

1. **Conexión vía relay público en lugar de directa**: Syncthing usa _relays_ cuando no logra ruta directa. Verificar:
   ```bash
   docker exec syncthing wget -qO- 'http://localhost:8384/rest/system/connections' \
     -H "X-API-Key: $(docker exec syncthing sh -c 'grep apiKey /config/config.xml | head -1 | sed -E \"s|.*<apikey>([^<]*)</apikey>.*|\1|\"')"
   ```
   En la respuesta JSON, cada device tiene `"type": "tcp-server"` (directa), `"type": "tcp-client"` (directa) o `"type": "relay-client"` (relay). Si es relay, revisar:
   - `tailscale status` desde el peer remoto: ¿la Pi aparece como peer? ¿hay un `*` que indica DERP relay?
   - Las direcciones estáticas en _Add Remote Device_ → _Addresses_ apuntan a `tcp://100.x.y.z:22000` (Tailscale), no a `dynamic`.
2. **CPU saturada**: `docker stats syncthing` durante una transferencia. Si > 90 % de un _core_, es la barrera de cifrado: no hay mucho que hacer salvo aceptar.
3. **Disco USB lento**: `iostat -x 5` durante la transferencia. `%util > 90` y `await > 50ms` indican el disco. Esperar a que termine; en transferencias grandes en USB HDD es normal.

### `Out of Sync Items: -1` y el contador no avanza

Síntoma: la carpeta muestra "Out of Sync" con un número negativo o `0` que no avanza tras horas. Causa: el índice de la base de datos de Syncthing está corrupto (típico tras un kernel panic o un OOM kill).

Solución:

```bash
docker compose -f ~/homelab/almacen/docker-compose.yml stop syncthing
sudo rm -rf /mnt/hd2t/services/syncthing/config/index-v0.14.0.db.*
docker compose -f ~/homelab/almacen/docker-compose.yml up -d syncthing
```

Syncthing reconstruye el índice escaneando todas las carpetas. En USB HDD puede tardar **horas** para enjambres grandes; durante ese tiempo, las carpetas aparecen como _Scanning_. **No** se pierden datos: el índice es derivable de los ficheros del disco.

> **Importante**: NO borrar `cert.pem` ni `key.pem` ni `config.xml` — sólo el directorio del índice (`index-v0.14.0.db.*`).

### El bind-mount `/data/shared-photos` no escribe con `1000:homelab-media`

Síntoma: tras activar el bind-mount adicional para fotos del móvil, los ficheros nuevos quedan como `1000:1000` en vez de `1000:homelab-media`, y Jellyfin no los lee.

Causa típica: Syncthing corre con `PGID=1000` (= `homelab`) y la carpeta destino tiene bit `setgid` apagado.

Solución:

1. Verificar el `setgid` en la carpeta:
   ```bash
   stat -c '%a %U:%G' /mnt/hd2t/services/shared/media/photos
   # 2775 root:homelab-media   ← el "2" del principio es el setgid
   ```
   Si es `0755` o `0775`, reaplicar:
   ```bash
   sudo chown 1000:homelab-media /mnt/hd2t/services/shared/media/photos
   sudo chmod 2775 /mnt/hd2t/services/shared/media/photos
   ```

2. Verificar que Syncthing pertenece al grupo `homelab-media`:
   ```bash
   docker exec syncthing id
   # uid=1000(abc) gid=1000(abc) groups=1000(abc)   ← falta homelab-media
   ```
   Si falta, añadir `group_add: ["${MEDIA_GID}"]` al servicio `syncthing` en el compose y `docker compose up -d syncthing`.

3. Verificar `umask`. Si está en `022` (default), los ficheros son `0644` (sin escritura para grupo). Para que Jellyfin pueda **borrar** desde fuera de Syncthing (raro pero posible), `umask 002` da `0664`. Cambiar `UMASK: "022"` por `UMASK: "002"` en el `environment`.

### `failed to listen on quic://: bind: address already in use` en logs

Síntoma: en los logs aparece el error y el _peer_ remoto se conecta sólo por TCP/22000 (no por QUIC/22000), con sync más lento.

Causa: otro proceso del host ya está usando UDP/22000.

Diagnóstico:

```bash
ss -ulnp 'sport = :22000'
# Si aparece otra entrada distinta de docker-proxy, es el conflicto.
```

Soluciones:

- Si es otro contenedor: parar ese contenedor o cambiar el puerto publicado de Syncthing (cambiando ambos lados: `22000:22000/tcp` → `22001:22001/tcp` y "Sync Protocol Listen Addresses" en la GUI a `tcp://0.0.0.0:22001, quic://0.0.0.0:22001`, y abrir el nuevo puerto en `nftables`).
- Si es un Syncthing nativo del host: pararlo y desinstalarlo (ver **Requisitos previos**).

### El Watchtower del _stack_ `infra` _logueó_ un intento de actualización de `syncthing`

Síntoma: en `docker logs watchtower` aparece `Found new linuxserver/syncthing image (sha256:...)`, pero el contenedor no fue actualizado.

Comportamiento correcto: el _label_ `com.centurylinklabs.watchtower.enable: "false"` en el bloque `syncthing` del compose hace que Watchtower lo **excluya** explícitamente del ciclo (`WATCHTOWER_LABEL_ENABLE=true` en `infra/.env`, ver `docs/02-docker/04-watchtower.md`). Si ves la actualización aplicada, revisar:

```bash
docker inspect syncthing --format '{{ index .Config.Labels "com.centurylinklabs.watchtower.enable" }}'
# Debe devolver: false
```

Si devuelve `true`, alguien lo cambió por error: corregir en el compose y `docker compose up -d syncthing`.

---

## Referencias

- Syncthing — Documentación oficial: <https://docs.syncthing.net/>
- Syncthing — _Block Exchange Protocol_ (BEP): <https://docs.syncthing.net/specs/bep-v1.html>
- Syncthing — Configuración de _GUI auth_ y _DNS rebinding protection_: <https://docs.syncthing.net/users/config.html#gui-element>
- Syncthing — Versionado de ficheros: <https://docs.syncthing.net/users/versioning.html>
- Syncthing — _Releases_ y _changelog_: <https://github.com/syncthing/syncthing/releases>
- LinuxServer.io — Imagen Docker `syncthing`: <https://github.com/linuxserver/docker-syncthing>
- LinuxServer.io — Imagen Docker `syncthing` (releases): <https://github.com/linuxserver/docker-syncthing/releases>
- LinuxServer.io — Convención `PUID`/`PGID`: <https://docs.linuxserver.io/general/understanding-puid-and-pgid/>
- Syncthing-Fork (Android) — Cliente recomendado: <https://github.com/Catfriend1/syncthing-android>
- Möbius Sync (iOS) — Cliente recomendado: <https://www.mobiussync.com/>
