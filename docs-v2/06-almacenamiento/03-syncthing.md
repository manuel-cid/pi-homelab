# Syncthing

## Descripción

Despliegue de **Syncthing** como motor de **sincronización peer-to-peer** del homelab. Donde Nextcloud ([`./01-nextcloud.md`](./01-nextcloud.md)) ofrece una nube clásica con UI y apps de oficina, y Samba ([`./02-samba.md`](./02-samba.md)) expone los discos por SMB en LAN, Syncthing cubre un tercer caso muy distinto: **mantener carpetas idénticas en varios dispositivos**, con commit continuo, deduplicación por bloques (rsync interno), versionado y resolución de conflictos. Sin servidor central, sin "cliente vs servidor": cada nodo (Pi, portátil, móvil) es un peer.

Casos de uso típicos del operador del homelab:

- **Backup automático de fotos del móvil** (DCIM, WhatsApp Images, ...) hacia la Pi en modo *receive only* — el nodo Pi nunca empuja borrados al móvil, así que un "borrar y vaciar la papelera" en el teléfono no propaga el borrado a la copia segura.
- **Carpeta personal de notas / dotfiles / proyectos** sincronizada bidireccional entre el portátil principal, el de respaldo y la Pi, con versionado simple para deshacer un *oops*.
- **Mover ficheros entre dispositivos sin pasar por la nube** cuando todos están en LAN o conectados por Tailscale: Syncthing detecta peers locales por broadcast UDP y, si están alcanzables, hace el sync por LAN sin salir a internet (a 1 Gbps en una Pi 5 con I/O de USB 3.0 a hd2t, satura la red).

> **Alcance**: Syncthing es **otro servicio "humano" del operador**, no infraestructura crítica. Aunque su UI viaja por Caddy con HTTPS interno y Authelia (igual que Nextcloud), la sincronización en sí (`tcp/22000`, `udp/22000`, `udp/21027`) es **directa entre peers** y no pasa por Caddy. Acceso desde fuera de casa: vía Tailscale (la Pi es alcanzable como `pi.tailnet.ts.net` y los puertos de sync siguen funcionando). Como con Samba, no se publica nada al WAN.

El stack `syncthing` ([`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §1.1) contiene **un único contenedor**:

- **`syncthing`** — la imagen oficial `syncthing/syncthing` (multi-arch, mantenida por el proyecto upstream). Corre en la **red bridge `homelab`** para que Caddy alcance el GUI por DNS interno (`http://syncthing:8384`), y publica al host **solo los puertos de sync** (`22000/tcp`, `22000/udp`, `21027/udp`). El GUI **no se publica** al host: solo se sirve a través de Caddy.

Por qué exactamente esta arquitectura, y no otra:

1. **Imagen oficial `syncthing/syncthing`, no `linuxserver/syncthing`.** Las dos son válidas, pero la oficial:
   - Es **upstream del propio proyecto Syncthing**: las release notes y la imagen Docker se publican el mismo día. Sin "delay LinuxServer" entre la salida de `1.27.x` upstream y la imagen `linuxserver/syncthing:1.27.x`.
   - **Multi-arch nativo** (`linux/amd64`, `linux/arm64`, `linux/arm/v7`). Funciona en la Pi 5 sin rebuilds.
   - **Empaquetado mínimo**: el proceso `syncthing` corre como `PID 1`, sin `s6-overlay` ni stack de scripts. Más fácil de debuggear (`docker exec syncthing ps` muestra una sola línea).
   - Acepta `PUID`/`PGID` en variables de entorno (igual que LinuxServer) → no hay diferencia operativa para el homelab que deja todos los servicios "humanos" como UID 1000.
   - Bind por defecto del GUI a `127.0.0.1:8384` dentro del contenedor; si se quiere que escuche en `0.0.0.0` se ajusta con `STGUIADDRESS=0.0.0.0:8384`. En este doc se usa la segunda forma porque Caddy llega desde otra red Docker.
2. **Red `homelab` (bridge), no `host` ni `macvlan`.** Decisión distinta a la de Samba:
   - El GUI (`8384/tcp`) se accede **únicamente** vía `https://syncthing.lan` por Caddy, igual que Nextcloud, Grafana, Portainer, etc. Coherencia: ningún GUI del homelab se publica al host, todos van por Caddy con HTTPS de la CA interna y Authelia delante. Para que Caddy lo alcance, ambos contenedores tienen que compartir red Docker → `homelab` (la bridge compartida creada en [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §4).
   - **Para los puertos de sync (22000 TCP/UDP, 21027 UDP)** sí publicamos en `0.0.0.0` del host para que peers de la LAN y de Tailscale puedan abrir conexiones directas. Esto **no es** lo mismo que `network_mode: host`: sólo se publican esos tres puertos, no se cede al contenedor el namespace de red completo.
   - **Local discovery por broadcast UDP 21027**: con `network_mode: bridge` los broadcasts entrantes (peers de la LAN anunciándose) llegan al puerto publicado y Docker los reenvía al contenedor; los broadcasts **salientes** del contenedor también funcionan porque Syncthing los emite como mensajes UDP unicast a `255.255.255.255:21027` y Docker NAT los traduce. **Lo único que se pierde** respecto a `host` es la velocidad de descubrimiento la primera vez (`~1 minuto` extra hasta que el global discovery server de syncthing.net desempate). Aceptable.
   - Variante `host` documentada en §14.2 para quien necesite el descubrimiento más rápido.
3. **GUI siempre detrás de Authelia + auth nativa de Syncthing.** Defensa en profundidad. Syncthing trae su propio user/password en la UI (almacenado en `config.xml` con bcrypt), pero exponerlo en LAN sin un proxy autenticado iría contra el patrón del homelab. El path `/rest/db/...` (API JSON) **no** se exime del bypass de Authelia: a diferencia de Nextcloud, el cliente de Syncthing es **otro Syncthing**, no un cliente HTTP que hable con el GUI — los peers se conectan directamente al puerto `22000`, no al GUI. Esto significa que el GUI puede ir 100% detrás de Authelia sin romper la sincronización.
4. **`PUID=1000`/`PGID=1000` (`homelab:homelab`).** Los ficheros sincronizados son del operador. Mantenerlos con UID 1000 en disco simplifica:
   - Editarlos desde el shell del host sin `sudo`.
   - Backup con Borg como `homelab` (ver [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md)).
   - Acceso desde Samba (donde el `force user = homelab` mapea SMB → UID 1000) sin retoques de permisos.
5. **Tres carpetas iniciales por defecto, todas bajo `/mnt/hd2t/sync/`**:
   - **`default`** (Send & Receive): equivalente a la carpeta `~/Sync` que Syncthing crea por defecto al instalarse. Bidireccional con el portátil. ~1–10 GB típicos (notas, dotfiles, proyectos).
   - **`phone-photos`** (Receive Only): destino de las fotos del móvil (Syncthing en Android empuja, la Pi nunca borra). 10–100 GB típicos.
   - **`obsidian`** (Send & Receive): vault de Obsidian, sincronizado entre portátil y móvil con la Pi como hub central que siempre está online. Pequeño (<1 GB) pero crítico — versionado activo (§9.4).
   Cada carpeta vive en su propio subdirectorio bajo `/mnt/hd2t/sync/`, con permisos `750 homelab:homelab`. Ningún share Samba la expone por defecto (no tiene sentido cruzar protocolos sobre la misma carpeta — variante §14.4 si se quisiera).
6. **Versionado por carpeta a `simple` con `keep = 5`** por defecto. Syncthing tiene cinco modos de versionado (`none`, `trashcan`, `simple`, `staggered`, `external`). `simple` mueve los ficheros sustituidos a `.stversions/<carpeta>/` con timestamp, manteniendo las últimas N versiones. Cinco copias × tamaño medio del fichero ≈ overhead aceptable y compatible con Borg (las versiones también se respaldan). Para `phone-photos`, `staggered` con `cleanInterval = 3600` mantiene una densidad decreciente (1 copia/hora 1 día, 1 copia/día 30 días, 1 copia/semana 365 días).
7. **Watchtower habilitado (`watchtower.enable: "true"`).** Syncthing es muy retro-compatible entre minor versions; un upgrade automático a `1.27.x → 1.28.0` no rompe el formato `config.xml` ni el protocolo de sync. Las release notes lo confirman versión a versión: cuando hay un cambio incompatible, lo anuncian con varias versiones de antelación. Sí: incidencia operativa: si el operador usa el cliente de móvil/PC y el cliente queda en una versión más vieja que la Pi (porque F-Droid actualiza más despacio), el sync sigue funcionando — el protocolo de sync es estable hace años. Variante §14.3 si se quiere desactivar.
8. **No se desencripta nada en el GUI desde fuera de la LAN sin Authelia.** Aunque Syncthing tiene su propia auth, exponer el GUI requiere **siempre** pasar por Caddy + Authelia. Acceso desde el móvil fuera de casa: vía Tailscale + DNS `syncthing.lan` (que Pi-hole resuelve solo dentro de la red local) **no funciona** porque `*.lan` es DNS local. Para el caso "ver el estado del sync desde fuera", se documenta en §14.5 cómo añadir un bloque `syncthing.tailnet.ts.net` al `Caddyfile`.
9. **Fail2ban opcional.** Syncthing no tiene un patrón de log adecuado para Fail2ban: los intentos de auth en el GUI se loguean pero el rate limit nativo del propio Syncthing (`maxConcurrentScans` y `reconnectIntervalS`) ya bloquea brute-force tras pocos intentos. Si el operador quiere defensa en profundidad, se documenta el filtro en §13.

> **Alcance de red**: el GUI Syncthing se publica en `https://syncthing.lan` (LAN) y opcionalmente `https://syncthing.tailnet.ts.net` (Tailscale). Los puertos de sync (`22000` TCP/UDP, `21027` UDP) están abiertos en `eth0` para LAN; sobre Tailscale funcionan transparentemente porque Syncthing usa global discovery + relays como respaldo cuando NAT lo impide.

---

## Requisitos Previos

- **Docker Engine + Compose v2** instalados según [`../02-docker/01-instalacion-docker.md`](../02-docker/01-instalacion-docker.md), con la red `homelab` creada según [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §4.
- **Estructura de directorios** aplicada según [`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md):
  - `/mnt/hd2t/services/` ya creado, propietario `homelab:homelab`, modo `750`.
  - Usuario `homelab` (UID 1000) y grupo `homelab` (GID 1000) operativos.
- **Caddy desplegado** según [`../03-red/04-caddy.md`](../03-red/04-caddy.md) con los snippets `lan_internal_tls`, `tailscale_tls` y `security_headers`. La CA interna ya está confiada en al menos un cliente para poder probar el GUI.
- **Authelia desplegado** según [`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md) con el snippet `authelia_proxy` y al menos un usuario con 2FA habilitado.
- **Pi-hole desplegado** según [`../03-red/02-pihole.md`](../03-red/02-pihole.md), con DNS local activo. Aquí se añadirá el record `syncthing.lan → 192.168.1.10`.
- **Tailscale operativo** según [`../03-red/05-tailscale.md`](../03-red/05-tailscale.md) (opcional para LAN-only, requerido para acceso desde fuera).
- **`ufw` activo** según [`../01-sistema/03-seguridad-base.md`](../01-sistema/03-seguridad-base.md) §4. Aún sin reglas para los puertos de Syncthing; se añaden en §8.
- **Fail2ban operativo** según [`../04-seguridad/02-fail2ban.md`](../04-seguridad/02-fail2ban.md) (sólo si se quiere el jail opcional de §13).
- **Comprobaciones rápidas**:
  ```bash
  # Red Docker compartida ya existe.
  docker network inspect homelab \
    --format '{{(index .IPAM.Config 0).Subnet}}'
  # Esperado: 172.20.0.0/24

  # Caddy operativo.
  docker ps --filter name=caddy --format 'table {{.Names}}\t{{.Status}}'
  # Esperado: caddy ... Up X (healthy)

  # Puertos de sync libres en el host.
  sudo ss -lntu '( sport = :22000 or sport = :21027 or sport = :8384 )'
  # Esperado: vacío. Si alguno está ocupado, identificar y liberar antes de seguir.

  # IP del host en la LAN (la usarán los peers en LAN).
  ip -4 addr show eth0 | awk '/inet / {print $2}'
  # Esperado: 192.168.1.10/24 (o la IP estática asignada).

  # Espacio libre en hd2t (Syncthing necesita ~10 GB iniciales como holgura
  # para versionado + .stversions; el grueso depende de qué se sincronice).
  df -h /mnt/hd2t | tail -1
  ```

### Decisiones de diseño asumidas

| Decisión | Valor por defecto | Justificación |
|---|---|---|
| Imagen Docker | **`syncthing/syncthing`** (oficial upstream) | Multi-arch (`linux/arm64`), publicada el mismo día que las releases del proyecto. Justificado en §0 punto 1. |
| Tag de imagen | **Pinned a release puntual** (p. ej. `1.27.7`), nunca `latest` | Misma regla de [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §6.1. Watchtower sí pulea actualizaciones del mismo tag o uno superior según política — Syncthing es retro-compatible entre minor releases. |
| Política de Watchtower | **`watchtower.enable: "true"`** | Justificado en §0 punto 7. El upgrade es transparente (reinicio del contenedor, ~3 s downtime, los peers reconectan). |
| Modo de red | **`networks: [homelab]`** (bridge compartida) | Justificado en §0 punto 2. Caddy alcanza `http://syncthing:8384` por DNS Docker. |
| Subred Docker | Heredada de la red `homelab` (`172.20.0.0/24`) | El contenedor recibe una IP del pool `172.20.0.0/24`. No relevante para el operador (todo se accede por nombre). |
| Puertos publicados al host | **`22000:22000/tcp`**, **`22000:22000/udp`**, **`21027:21027/udp`** | Sync directo (TCP), QUIC sync (UDP) y local discovery (UDP). Sin `127.0.0.1:` → bind a `0.0.0.0` para que la LAN y Tailscale los alcancen. `8384/tcp` (GUI) **no se publica**: sólo se sirve a través de Caddy. |
| Listen address del GUI | **`STGUIADDRESS=0.0.0.0:8384`** (escucha en todas las interfaces dentro del contenedor) | Por defecto la imagen lo bindea a `127.0.0.1:8384`, lo que impide que Caddy (en otro contenedor de la misma red) lo alcance. La autenticación se delega a Authelia + a la propia auth de Syncthing. |
| Auth del GUI | **Authelia 2FA delante** + **user/password de Syncthing detrás** | Defensa en profundidad. La auth de Syncthing se configura en el primer arranque (§7.4). |
| API key | **Generada al primer arranque** y persistida en `config.xml`. Se rota manualmente con `--reset-deltas` en operaciones (§12.6). | El API key permite scripting (`curl -H 'X-API-Key: ...'`). Útil para Homepage (status widget) y para cualquier integración futura. |
| Usuario dentro del contenedor | **`PUID=1000`/`PGID=1000`** (`homelab:homelab`) vía variables de entorno | Justificado en §0 punto 4. Coherente con la convención del homelab. |
| Persistencia (config + DB) | Bind mount `/var/syncthing/config` ← `/mnt/hd2t/services/syncthing/config/` | `config.xml` (configuración), `cert.pem`/`key.pem` (identidad del nodo, **NO regenerar a la ligera**), `index-v0.14.0.db/` (LevelDB con el índice de bloques de cada carpeta). |
| Persistencia (datos sincronizados) | Bind mount `/var/syncthing/sync` ← `/mnt/hd2t/sync/` | El path **dentro del contenedor** coincide con `STHOMEDIR/Sync`, que es donde Syncthing crea las carpetas por defecto. Más limpio que cambiar `STHOMEDIR`. |
| Healthcheck | **`curl -f http://127.0.0.1:8384/rest/noauth/health`** | Endpoint público sin auth que devuelve `{"status":"OK"}` cuando el demonio está vivo. Aceptable porque no expone nada sensible. |
| `cap_drop: ALL` + `cap_add` | **`cap_add: []`** (vacío) | Syncthing no necesita capacidades especiales: corre como UID 1000, escucha en puertos altos (8384, 22000, 21027). |
| `security_opt: no-new-privileges:true` | **Activado** | Plantilla §6 de [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md). |
| `read_only: true` | **`false`** | Syncthing escribe el `config.xml`, la DB de índices y los logs en `/var/syncthing/config/`. Forzar RO obligaría a tmpfs masivo y rompe el versionado en `.stversions/`. La defensa real es el bind mount con UID/GID `homelab` y `750`. |
| Logs Docker | Heredados del demonio (`json-file` 10 MB × 3) | El log "rico" de Syncthing va a `/var/syncthing/config/syncthing.log` (rotado por Syncthing internamente, ver `STLOGDIR` y `--log-file-max-mb`). |
| Versionado por defecto | **`simple`** con `keep = 5` para `default` y `obsidian`; **`staggered`** para `phone-photos` | Justificado en §0 punto 6. |
| Folder permissions | `750 homelab:homelab` (en host) → `0644`/`0755` dentro de cada carpeta sincronizada | Permisos de fichero/directorio sincronizados se mantienen tal cual entre peers (Syncthing los preserva si los dos lados son Linux/Mac). En Android los permisos no aplican igual y Syncthing los normaliza. |
| Carpetas creadas en `config.xml` | **3 por defecto**: `default` (S&R), `phone-photos` (RO), `obsidian` (S&R) | Justificado en §0 punto 5. Otras carpetas se añaden vía GUI sin tocar este doc. |
| Encryption at rest | **No** (Syncthing soporta "encrypted folders" para compartir cifrado con un peer no confiable; aquí todos los peers son confiables) | Si en el futuro se quiere subir el sync a un VPS no confiable como peer adicional, se activa `encrypted: true` por carpeta. Documentado en §14.6. |
| Acceso GUI desde Tailscale | **Opt-in** | Documentado en §14.5. Por defecto el GUI vive solo en `syncthing.lan`. |

---

## 1. Resumen de la arquitectura

```
                ┌──────────────────── LAN 192.168.1.0/24 ────────────────────┐
                │                                                             │
   Portátil ────┤  TCP 22000 (sync directo)                                  │
   Móvil    ────┤  UDP 22000 (QUIC sync)                                     │
                │  UDP 21027 (local discovery broadcast)                     │
   Otra Pi  ────┤                                                             │
                │  HTTPS 443 (GUI vía Caddy → syncthing.lan)                 │
                └──────────────────────────┬──────────────────────────────────┘
                                           │
                eth0 192.168.1.10 (Pi 5)   │
                                           ▼
                ┌────────────────────────────────────────────────────────────┐
                │  ufw allow 22000/tcp,udp & 21027/udp from 192.168.1.0/24  │
                │  ufw allow 22000/tcp,udp & 21027/udp from 100.64.0.0/10   │
                │                                                            │
                │  ┌── docker network homelab (172.20.0.0/24) ───────────┐  │
                │  │                                                      │  │
                │  │  caddy ─── 443 ──→ proxy ──→ http://syncthing:8384  │  │
                │  │                                  ↑                   │  │
                │  │                                  │ Authelia 2FA      │  │
                │  │                                  │                   │  │
                │  │  syncthing (PUID=1000)                               │  │
                │  │   GUI :8384  (no publicado al host)                  │  │
                │  │   sync :22000/tcp (publicado)                        │  │
                │  │   sync :22000/udp (publicado)                        │  │
                │  │   disc :21027/udp (publicado)                        │  │
                │  │                                                      │  │
                │  │   /var/syncthing/config  ← /mnt/hd2t/services/...   │  │
                │  │     ├── config.xml                                   │  │
                │  │     ├── cert.pem / key.pem (device ID)              │  │
                │  │     └── index-v0.14.0.db/  (LevelDB)                │  │
                │  │                                                      │  │
                │  │   /var/syncthing/sync   ← /mnt/hd2t/sync/           │  │
                │  │     ├── default/        (S&R)                        │  │
                │  │     ├── phone-photos/   (RO)                         │  │
                │  │     └── obsidian/       (S&R)                        │  │
                │  └──────────────────────────────────────────────────────┘  │
                │                                                            │
                └────────────────────────────────────────────────────────────┘
```

Flujo de sync (caso "el portátil tiene un fichero nuevo en la carpeta `default`"):

```
1. Portátil: el watcher inotify detecta el nuevo fichero.
2. Portátil → broadcast UDP 21027 anunciando "tengo nuevo índice para folderID=default".
3. Pi (eth0:21027 → puerto publicado por Docker → contenedor):
     "le tengo nota; abrir conexión TCP 22000 al portátil".
4. Conexión TLS mutua entre device IDs (cert.pem). Sin servidor de auth central:
     cada Device ID es la huella SHA-256 del cert público.
5. Intercambio de bloques (rsync interno): solo se envían los bloques de fichero
     que difieren. Para un fichero nuevo, se envían todos.
6. Pi: escribe el fichero en /mnt/hd2t/sync/default/ como UID 1000 (PUID=1000).
     Si la carpeta tiene versionado y el fichero existía, la versión anterior se
     mueve a /mnt/hd2t/sync/default/.stversions/<timestamp>/<rel-path>.
7. Pi → broadcast UDP 21027 anunciando "tengo nuevo índice".
     Móvil (Tailscale o LAN) detecta y trae el cambio si está sincronizando esa carpeta.
```

---

## 2. Plan de variables y archivos

El stack `syncthing` es nuevo. Layout que se va a crear en este doc:

```
~/homelab/stacks/syncthing/                     # versionado en git
├── docker-compose.yml
└── .env.example

/mnt/hd2t/services/syncthing/                   # NO versionado
├── .env                                        # API key, dominios, tag
└── config/                                     # → /var/syncthing/config
    ├── config.xml                              # config principal
    ├── cert.pem / key.pem                      # identidad del device (NO regenerar)
    ├── csrftokens.txt
    ├── https-cert.pem / https-key.pem          # cert del GUI (no usado: Caddy hace TLS)
    └── index-v0.14.0.db/                       # LevelDB de índices

/mnt/hd2t/sync/                                 # NO versionado, datos del operador
├── default/                                    # carpeta S&R (notas, dotfiles)
│   └── .stfolder                               # marker que crea Syncthing
├── phone-photos/                               # Receive Only
│   └── .stfolder
└── obsidian/                                   # carpeta S&R (vault)
    └── .stfolder
```

> **Por qué `/mnt/hd2t/sync/` y no `/mnt/hd2t/services/syncthing/data/`**: igual razonamiento que con Samba (`/mnt/hd2t/shares/`). Los datos sincronizados son **del operador**, no del servicio. Mezclarlos con `config/` complica el backup (la DB de índices es regenerable pero pesa GB; los datos no son regenerables y son lo importante) y la herencia de permisos.

### 2.1. `.env.example` (`~/homelab/stacks/syncthing/.env.example`)

```bash
# ~/homelab/stacks/syncthing/.env.example
# Copiar a /mnt/hd2t/services/syncthing/.env y rellenar.

# Usuario y zona horaria.
PUID=1000
PGID=1000
TZ=Europe/Madrid

# Dominio interno (resuelto por Pi-hole) y dominio Tailscale.
LAN_DOMAIN=lan
TS_DOMAIN=tailnet.ts.net

# --- Imagen ---
# https://hub.docker.com/r/syncthing/syncthing/tags
SYNCTHING_IMAGE_TAG=1.27.7

# --- API key del GUI ---
# Generar con: openssl rand -hex 16
# Si se deja vacío, Syncthing genera uno al primer arranque y se lee con:
#   docker exec syncthing cat /var/syncthing/config/config.xml | grep apikey
# Para integración con Homepage (12-dashboards/01-homepage.md) se recomienda fijarlo.
SYNCTHING_API_KEY=
```

### 2.2. `.env` real (`/mnt/hd2t/services/syncthing/.env`)

```bash
# Crear el .env con permisos correctos.
sudo install -m 600 -o homelab -g homelab /dev/null /mnt/hd2t/services/syncthing/.env

# Rellenar (la API key se generará en §4):
cat | sudo tee /mnt/hd2t/services/syncthing/.env >/dev/null <<'EOF'
PUID=1000
PGID=1000
TZ=Europe/Madrid

LAN_DOMAIN=lan
TS_DOMAIN=tailnet.ts.net

SYNCTHING_IMAGE_TAG=1.27.7

# Se rellena tras §4.
SYNCTHING_API_KEY=
EOF

ls -l /mnt/hd2t/services/syncthing/.env
# Esperado: -rw------- 1 homelab homelab ... .env
```

### 2.3. Cómo se inyecta la API key

A diferencia del password SMB (que vive en `users.conf` con permisos `600`), la API key de Syncthing es una variable de entorno de **lectura del propio Syncthing** que se persiste en `config.xml`. Dos vías:

| Vía | Cuándo | Cómo |
|---|---|---|
| **Auto-generada** | Primer despliegue limpio | Dejar `SYNCTHING_API_KEY=` vacío en `.env`. Al arrancar, Syncthing genera una y la escribe en `config.xml`. Se lee después con `docker exec`. |
| **Inyectada** | Despliegue con API key conocida (recovery, migraciones, integración Homepage) | Fijar `SYNCTHING_API_KEY=...` en `.env`. La imagen oficial respeta esta env var y la propaga al `config.xml` al arrancar. |

| Secreto | Fichero en host | Variable / fichero en contenedor |
|---|---|---|
| API key del GUI | `/mnt/hd2t/services/syncthing/.env` (`SYNCTHING_API_KEY=...`) | `/var/syncthing/config/config.xml` (`<apikey>...</apikey>`) |
| User/password GUI | (no se almacena en `.env`) | `/var/syncthing/config/config.xml` (`<gui>` con bcrypt hash) |
| Cert.pem / key.pem | (no se generan a mano) | `/var/syncthing/config/cert.pem`, `key.pem` (auto-generados al primer arranque) |

---

## 3. Preparar el árbol de datos

### 3.1. Crear el directorio del stack

```bash
mkdir -p ~/homelab/stacks/syncthing
```

### 3.2. Crear el árbol de datos persistentes

```bash
sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/services/syncthing
sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/services/syncthing/config
```

### 3.3. Crear las carpetas raíz de sincronización

```bash
sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/sync
sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/sync/default
sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/sync/phone-photos
sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/sync/obsidian
```

Notas sobre dueños y permisos:

- **Todo `homelab:homelab` `750`**: el operador y los procesos que corran como `homelab` (Syncthing dentro del contenedor con `PUID=1000`) ven y escriben. Otros usuarios humanos del host (que no debería haber) no.
- **No se crea `.stfolder`** manualmente: Syncthing lo crea al añadir cada folder en el GUI. Es un marker que Syncthing usa para verificar que la carpeta está montada (su ausencia → "carpeta detenida, error: folder marker missing").
- **No se crea `.stversions/`** manualmente: Syncthing la crea al primer reemplazo de un fichero versionado.

---

## 4. Pre-generar la API key (opcional)

Recomendado fijar la API key antes del primer arranque para no tener que editar `.env` después y reiniciar:

```bash
# Generar una API key estable (32 caracteres hex).
API_KEY=$(openssl rand -hex 16)
echo "API key Syncthing: ${API_KEY}"
# Anotar en KeePassXC / Vaultwarden.

# Volcarla al .env, sustituyendo la línea vacía.
sudo sed -i "s|^SYNCTHING_API_KEY=.*|SYNCTHING_API_KEY=${API_KEY}|" \
  /mnt/hd2t/services/syncthing/.env

grep ^SYNCTHING_API_KEY /mnt/hd2t/services/syncthing/.env
# Esperado: SYNCTHING_API_KEY=<32 hex chars>

unset API_KEY
history -d $((HISTCMD-2)) 2>/dev/null || true
```

> **Si se omite este paso**, Syncthing arrancará igual y generará la suya. Para leerla: `docker exec syncthing sh -c 'grep "<apikey>" /var/syncthing/config/config.xml | sed -E "s|.*<apikey>(.*)</apikey>.*|\1|"'`.

---

## 5. `docker-compose.yml`

`~/homelab/stacks/syncthing/docker-compose.yml`:

```yaml
# ~/homelab/stacks/syncthing/docker-compose.yml
# Stack: syncthing (../02-docker/02-estructura-compose.md §1.1).
# Datos persistentes en /mnt/hd2t/services/syncthing/.
# Carpetas sincronizadas en /mnt/hd2t/sync/.

name: syncthing

services:
  syncthing:
    image: syncthing/syncthing:${SYNCTHING_IMAGE_TAG}
    container_name: syncthing
    hostname: syncthing
    restart: unless-stopped

    env_file:
      - /mnt/hd2t/services/syncthing/.env
    environment:
      PUID: ${PUID}
      PGID: ${PGID}
      TZ: ${TZ}
      # GUI escucha en todas las interfaces dentro del contenedor: Caddy
      # llega desde otra red Docker (homelab) y necesita un bind no-loopback.
      STGUIADDRESS: 0.0.0.0:8384
      # Persistir la API key en config.xml al arranque, si se fijó en .env (§4).
      STAPIKEY: ${SYNCTHING_API_KEY}
      # Deshabilitar el banner de "permissions check" del GUI: en Linux el filesystem
      # ext4 ya soporta los permisos correctamente.
      STNOUPGRADE: "1"
      # Hash type del password GUI (Syncthing 1.27+).
      STHASHING: "bcrypt"

    volumes:
      # Configuración + identidad del nodo + base de datos de índices.
      - type: bind
        source: /mnt/hd2t/services/syncthing/config
        target: /var/syncthing/config
        bind:
          create_host_path: false

      # Datos sincronizados. Path host = path contenedor (/var/syncthing/sync)
      # se mapea al subdirectorio "Sync" que Syncthing crea por defecto, pero
      # aquí lo apuntamos a un path interno explícito para no depender de
      # STHOMEDIR. Las rutas de cada folder en config.xml apuntarán a
      # /var/syncthing/sync/<folder>.
      - type: bind
        source: /mnt/hd2t/sync
        target: /var/syncthing/sync
        bind:
          create_host_path: false

    # GUI (8384) NO se publica al host: solo accesible vía Caddy en homelab.
    # Sync directo + QUIC + local discovery sí se publican.
    ports:
      - "22000:22000/tcp"     # sync directo
      - "22000:22000/udp"     # QUIC sync
      - "21027:21027/udp"     # local discovery broadcast

    networks:
      - homelab               # Caddy llega aquí por DNS interno

    cap_drop:
      - ALL

    security_opt:
      - no-new-privileges:true

    healthcheck:
      test:
        - CMD
        - curl
        - -fsS
        - http://127.0.0.1:8384/rest/noauth/health
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s

    labels:
      com.centurylinklabs.watchtower.enable: "true"
      homepage.group: "Almacenamiento"
      homepage.name: "Syncthing"
      homepage.icon: "syncthing.png"
      homepage.href: "https://syncthing.${LAN_DOMAIN}"
      homepage.description: "Sync P2P de carpetas"
      homepage.widget.type: "syncthing-relay"
      homepage.widget.url: "http://syncthing:8384"
      homepage.widget.key: "${SYNCTHING_API_KEY}"

networks:
  homelab:
    external: true
```

### 5.1. Por qué cada bloque

| Bloque | Por qué |
|---|---|
| `image: syncthing/syncthing:${SYNCTHING_IMAGE_TAG}` | Imagen oficial upstream (§0 punto 1). Tag fijo — Watchtower bumpea cuando hay nueva minor. |
| `restart: unless-stopped` | Plantilla §6 de [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md). |
| `env_file` | Carga `.env` con la ruta absoluta (no junto al `docker-compose.yml`, que sigue la regla de `/mnt/hd2t/services/<stack>/.env`). |
| `STGUIADDRESS=0.0.0.0:8384` | El default de la imagen es `127.0.0.1:8384`, lo que impide que Caddy en otro contenedor llegue. La auth la cubre Authelia + el propio Syncthing. |
| `STAPIKEY` (env) | La imagen lo persiste en `config.xml` al arrancar (con prioridad sobre el valor existente). Útil para que el operador conozca la key sin tener que leer el XML. |
| `STNOUPGRADE=1` | Deshabilita el self-upgrade nativo de Syncthing (descargar el binario y reiniciar). En Docker, los upgrades los gestiona Watchtower con el patrón `pull` → `up -d`. Si Syncthing intenta self-upgrade dentro del contenedor, falla porque el FS donde vive el binario es read-only en muchas imágenes (no en esta, pero la coherencia importa: un solo mecanismo de upgrade). |
| `STHASHING=bcrypt` | Asegura que los passwords del GUI se almacenan con bcrypt (default desde 1.27). Compatibilidad con futuras migraciones. |
| `volumes` (bind `/var/syncthing/config`) | Persiste `config.xml`, certs (device ID) y la DB de índices. **El device ID depende de `cert.pem`/`key.pem`** — si se borran, el nodo aparece como "nuevo" para todos los peers y hay que re-pairing. |
| `volumes` (bind `/var/syncthing/sync`) | Datos del usuario. Path "limpio" dentro del contenedor (`/var/syncthing/sync/default/`) que se replica en `config.xml` al añadir cada folder. |
| `ports: 22000/tcp` | Sync directo entre peers. Sin este puerto la Pi sólo puede ser cliente (iniciar conexiones), no servidor (recibirlas) — peers detrás de NAT no podrían conectarse. |
| `ports: 22000/udp` | QUIC sync (mejor sobre redes con jitter, móviles que cambian de WiFi a 4G). Syncthing prioriza QUIC si funciona, cae a TCP si no. |
| `ports: 21027/udp` | Local discovery: broadcast UDP que peers en LAN envían anunciándose. Sin este puerto, la Pi se descubriría sólo por global discovery (relay servers de syncthing.net), que puede tardar 30-60 s. |
| `networks: [homelab]` | Caddy alcanza `http://syncthing:8384` por DNS interno de Docker. La sub-red interna del stack (`syncthing_internal`) **no aplica** aquí: no hay BD ni cache propias del stack. |
| `cap_drop: ALL` (sin `cap_add`) | Syncthing corre como UID 1000 y usa puertos altos: no necesita capabilities. |
| `healthcheck: curl -fsS .../rest/noauth/health` | Endpoint `/rest/noauth/health` es público (no requiere auth) y devuelve `{"status":"OK"}` con HTTP 200. Si Syncthing está reindexando (no operativo aún), responde 503. La imagen oficial trae `curl` preinstalado. |
| `start_period: 30s` | Syncthing tarda ~5–10 s en abrir la DB y servir el GUI. 30 s es holgura para arranques tras `docker compose up` con varias carpetas grandes (la DB se valida al inicio). |
| `labels: homepage.widget.*` | Integración con Homepage que se desplegará en [`../12-dashboards/01-homepage.md`](../12-dashboards/01-homepage.md). El widget `syncthing-relay` muestra estado de cada folder. |

### 5.2. Validar antes de levantar

```bash
cd ~/homelab/stacks/syncthing
docker compose --env-file /mnt/hd2t/services/syncthing/.env config >/dev/null \
  && echo "Compose OK"
```

Errores típicos:

- `service "syncthing" refers to undefined network homelab` → la red compartida no existe. Crear con [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §4.2.
- `bind source path does not exist: /mnt/hd2t/sync/default` → no se ejecutaron los `install -d` de §3.3.
- `Error response from daemon: driver failed programming external connectivity ... port is already allocated` → algún proceso del host (un Syncthing del paquete `apt syncthing`, otro contenedor) está ocupando 22000 o 21027. Identificar con `sudo ss -lntu sport=:22000` y liberar.

---

## 6. Despliegue

### 6.1. Primer arranque

```bash
cd ~/homelab/stacks/syncthing
docker compose --env-file /mnt/hd2t/services/syncthing/.env up -d
```

Salida esperada:

```
[+] Running 1/1
 ✔ Container syncthing    Started
```

### 6.2. Estado del contenedor

```bash
docker compose ps
# Esperado, tras ~30 s:
# NAME        IMAGE                          STATUS                 PORTS
# syncthing   syncthing/syncthing:1.27.7     Up X (healthy)         0.0.0.0:21027->21027/udp, 0.0.0.0:22000->22000/tcp, 0.0.0.0:22000->22000/udp
```

Si entra en `(unhealthy)`:

```bash
docker logs syncthing | tail -50
```

Eventos esperados al primer arranque:

```
INFO: syncthing v1.27.x ...
INFO: My ID: ABCDEFG-HIJKLMN-...-XYZWABC
INFO: Loading HTTPS certificate: open /var/syncthing/config/https-cert.pem: no such file or directory
INFO: Creating new HTTPS certificate
INFO: GUI and API listening on 0.0.0.0:8384
INFO: Access the GUI via the following URL: http://0.0.0.0:8384/
```

> **Anotar el "My ID"**: es el **Device ID** de la Pi. Cada peer al que se le añada esta Pi necesita ese ID. La forma cómoda de leerlo después es `docker exec syncthing syncthing --device-id`.

### 6.3. Confirmar puertos publicados al host

```bash
sudo ss -lntu '( sport = :22000 or sport = :21027 )'
# Esperado:
#   tcp   LISTEN 0      4096        0.0.0.0:22000      0.0.0.0:*
#   udp   UNCONN 0      0           0.0.0.0:21027      0.0.0.0:*
#   udp   UNCONN 0      0           0.0.0.0:22000      0.0.0.0:*

sudo ss -lntu '( sport = :8384 )'
# Esperado: VACÍO. El GUI no se publica al host.
```

### 6.4. Confirmar accesibilidad interna desde Caddy

```bash
docker exec caddy wget -qO- http://syncthing:8384/rest/noauth/health
# Esperado: {"status":"OK"}
```

Si falla con `wget: bad address 'syncthing'`: ambos contenedores deben estar en `homelab`. Verificar con:

```bash
docker network inspect homelab \
  --format '{{range $k, $v := .Containers}}{{println $v.Name}}{{end}}'
# Esperado: contiene "syncthing" y "caddy".
```

---

## 7. Integración con Caddy

### 7.1. Bloque `syncthing.lan` en el `Caddyfile`

Editar `~/homelab/stacks/proxy/Caddyfile` y añadir (o descomentar el placeholder si se dejó al desplegar Caddy):

```caddy
# Syncthing (../06-almacenamiento/03-syncthing.md)
syncthing.{$LAN_DOMAIN} {
    import lan_internal_tls
    import security_headers

    # Cabeceras requeridas por el GUI de Syncthing.
    header {
        # Anti-clickjacking: Syncthing ya envía X-Frame-Options pero lo reforzamos.
        Content-Security-Policy "frame-ancestors 'none'"
    }

    # WebSocket para el endpoint de eventos del GUI (real-time).
    @websocket {
        header Connection *Upgrade*
        header Upgrade websocket
    }

    handle /rest/* {
        # /rest/* es la API: protegida por la propia Syncthing con X-API-Key
        # o session cookie del GUI. Authelia delante seguiría exigiendo 2FA,
        # rompiendo cualquier integración (Homepage, scripting). Bypass.
        reverse_proxy http://syncthing:8384
    }

    handle {
        import authelia_proxy
        reverse_proxy http://syncthing:8384 {
            # Forzar Host: el GUI rechaza peticiones cuyo Host no coincide con
            # el configurado en `<gui>` de config.xml por defecto. Reescribir
            # con header_up para evitar "Host check error".
            header_up Host {host}
            header_up X-Forwarded-Proto https
            header_up X-Real-IP {remote_host}
        }
    }
}
```

> **Por qué `handle /rest/*` con bypass**: la API REST de Syncthing es la vía por la que Homepage (y cualquier integración futura) lee el estado. La auth del GUI (cookie de sesión vía username/password de Syncthing) no se obtiene si Authelia intercepta la primera petición pidiendo 2FA. Bypassear `/rest/*` no debilita la seguridad porque la API exige `X-API-Key` válida en cada request.

> **Si el GUI se queja de "Host check error"** tras el primer login: editar `config.xml` con `docker exec -it syncthing vi /var/syncthing/config/config.xml` y añadir `<insecureAdminAccess>false</insecureAdminAccess>` no — la solución correcta es añadir el dominio a la lista permitida con `STGUIAUTH=...` o configurarlo desde el GUI (Settings → GUI → "GUI Override Endpoints"). Documentado en §8.4.

Recargar Caddy sin downtime:

```bash
docker exec caddy caddy reload --config /etc/caddy/Caddyfile
```

### 7.2. Confirmar la regla en Authelia

Editar `~/homelab/stacks/auth/configuration.yml` y, en `access_control.rules`, añadir el dominio `syncthing.lan` con `policy: two_factor`:

```yaml
access_control:
  default_policy: deny
  rules:
    # ... reglas previas (auth.lan bypass, nextcloud.lan, ...)

    # Syncthing — GUI con 2FA, API REST sin Authelia (la cubre la X-API-Key).
    - domain: "syncthing.{{ env "LAN_DOMAIN" }}"
      resources:
        - "^/rest(/.*)?$"
      policy: bypass

    - domain: "syncthing.{{ env "LAN_DOMAIN" }}"
      policy: two_factor
```

Reiniciar Authelia (no soporta `watch:` para `configuration.yml`):

```bash
docker compose -f ~/homelab/stacks/auth/docker-compose.yml restart authelia
```

### 7.3. Añadir el registro DNS local en Pi-hole

Pi-hole UI → **Local DNS** → **DNS Records** → añadir:

```
syncthing.lan → 192.168.1.10
```

```bash
docker exec pihole pihole reloaddns
dig +short @192.168.1.241 syncthing.lan
# Esperado: 192.168.1.10
```

### 7.4. Probar el portal

Desde un cliente con `root.crt` de la CA interna instalado:

```bash
curl -fsS -k https://syncthing.lan/rest/noauth/health
# Esperado: {"status":"OK"}

# El navegador (con cert confiado): https://syncthing.lan
# 1. Authelia pide login (usuario homelab, password, 2FA TOTP).
# 2. Tras 2FA, el GUI de Syncthing pide su propio user/password
#    (configurado en §8 al primer login).
```

---

## 8. Configuración post-despliegue

### 8.1. Primera entrada al GUI: crear el usuario admin

Al primer acceso a `https://syncthing.lan`, Syncthing muestra un banner amarillo "**Danger! The GUI on this device is unprotected.**". Configurar credenciales:

1. Top-right → **Actions** → **Settings**.
2. Pestaña **GUI**:
   - **GUI Authentication User**: `homelab`.
   - **GUI Authentication Password**: generado con `openssl rand -base64 24`. Anotarlo en KeePassXC/Vaultwarden.
   - **Use HTTPS for GUI**: **desmarcar** (Caddy ya hace TLS; activarlo aquí provocaría doble cert y warnings de "navegador no confía").
   - **GUI Listen Address**: `0.0.0.0:8384` (ya configurado por `STGUIADDRESS`).
3. **Save**. Syncthing recarga el GUI y vuelve a pedir login (ahora con el password recién creado).

### 8.2. Añadir las tres carpetas iniciales

Desde el GUI → **Add Folder**:

#### `default` — espacio personal del operador

| Campo | Valor |
|---|---|
| Folder Label | `default` |
| Folder ID | `default` (clave globalmente única; Syncthing recomienda algo más entrópico, p. ej. `homelab-default-abc123`, pero `default` es suficiente si no hay colisiones con peers ajenos) |
| Folder Path | `/var/syncthing/sync/default` |
| Folder Type | **Send & Receive** |
| Versioning (pestaña) | **Simple File Versioning**, Keep Versions = `5` |
| Ignore Patterns (pestaña) | (vacío inicialmente; añadir `.DS_Store`, `Thumbs.db`, etc. si vienen de macOS/Windows) |

#### `phone-photos` — fotos del móvil (RO desde la Pi)

| Campo | Valor |
|---|---|
| Folder Label | `phone-photos` |
| Folder ID | `phone-photos` |
| Folder Path | `/var/syncthing/sync/phone-photos` |
| Folder Type | **Receive Only** |
| Versioning | **Staggered File Versioning**, `Maximum Age` = `365`, `Versions Path` = vacío (default `.stversions/`) |
| Ignore Patterns | `*/cache/*`, `*/.thumbnails/*` (Android escribe miniaturas que no merece la pena versionar) |

#### `obsidian` — vault de notas

| Campo | Valor |
|---|---|
| Folder Label | `obsidian` |
| Folder ID | `obsidian-vault` |
| Folder Path | `/var/syncthing/sync/obsidian` |
| Folder Type | **Send & Receive** |
| Versioning | **Simple File Versioning**, Keep Versions = `10` (las notas son cheap, mejor más historial) |
| Ignore Patterns | `.obsidian/workspace.json`, `.obsidian/workspace-mobile.json` (caches de UI por dispositivo, ruidosos sin valor) |

> **Tras añadir cada folder**, Syncthing crea el marker `.stfolder` y comienza a escanear:
> ```bash
> ls -la /mnt/hd2t/sync/default
> # Esperado: ... drwxr-xr-x 3 homelab homelab ... .stfolder
> ```

### 8.3. Pairing: añadir un peer (portátil) y conectar la carpeta

En **el portátil** (con Syncthing instalado, `https://localhost:8384`):

1. Top-right → **Actions** → **Show ID** → copiar el Device ID (ej. `ABCD1-...-XYZ`).

En **el GUI de la Pi** (`https://syncthing.lan`):

2. **Add Remote Device** → pegar Device ID del portátil → **Device Name**: `laptop` → pestaña **Sharing**: marcar `default` y `obsidian` → **Save**.
3. Syncthing pregunta automáticamente al portátil "¿quieres aceptar a la Pi como peer?".

En el **portátil**:

4. Notificación en el GUI: "**This device is unknown. Add new device with ID...**" → **Add Device**.
5. Tras aceptar el device, aparecen "**Folder offered: default**" y "**Folder offered: obsidian**" → **Add Folder** para cada una, configurando el path local (p. ej. `~/Sync/default`).

Tras unos segundos, el sync arranca. Verificar en la Pi:

```bash
ls /mnt/hd2t/sync/default
# Esperado: contenido del portátil (o vacío si arranca limpio).
```

### 8.4. Configurar el GUI Override (opcional, evita "Host check error")

Si tras el login con Authelia el GUI muestra "Host check error" al recargar:

1. **Settings** → **GUI** → **GUI Override Endpoints** → vacío → cambiar a `syncthing.lan`.

Alternativa por config.xml:

```bash
docker exec syncthing sh -c "
  sed -i 's|<insecureAllowFrameLoading>false</insecureAllowFrameLoading>|<insecureAllowFrameLoading>true</insecureAllowFrameLoading>|' \
  /var/syncthing/config/config.xml
"
docker compose -f ~/homelab/stacks/syncthing/docker-compose.yml restart syncthing
```

> En la mayoría de despliegues no hace falta tocar nada: Caddy con `header_up Host {host}` ya alimenta el header correcto.

### 8.5. Configurar la API key persistente (si no se hizo en §4)

Si se omitió pre-generar la API key:

```bash
# Leer la API key auto-generada por Syncthing.
API_KEY=$(docker exec syncthing sh -c \
  'grep "<apikey>" /var/syncthing/config/config.xml \
   | sed -E "s|.*<apikey>(.*)</apikey>.*|\1|"')
echo "API key Syncthing: ${API_KEY}"

# Inyectarla en .env para que próximos arranques la respeten y para integraciones.
sudo sed -i "s|^SYNCTHING_API_KEY=.*|SYNCTHING_API_KEY=${API_KEY}|" \
  /mnt/hd2t/services/syncthing/.env

unset API_KEY
```

### 8.6. Probar la API REST con la key

```bash
API_KEY=$(grep ^SYNCTHING_API_KEY /mnt/hd2t/services/syncthing/.env | cut -d= -f2)

curl -fsS -k -H "X-API-Key: ${API_KEY}" \
  https://syncthing.lan/rest/system/status \
  | jq '.myID, .uptime, .startTime'
# Esperado: device ID, segundos de uptime, timestamp ISO.

curl -fsS -k -H "X-API-Key: ${API_KEY}" \
  https://syncthing.lan/rest/db/status?folder=default \
  | jq '.state, .needFiles, .needBytes'
# Esperado: "idle" si todo sincronizado, o "syncing" con cifras > 0.

unset API_KEY
```

---

## 9. Verificación

### 9.1. Contenedor sano

```bash
docker compose -f ~/homelab/stacks/syncthing/docker-compose.yml ps
# Esperado: STATUS = Up X (healthy)
```

### 9.2. Acceso al GUI vía Caddy con Authelia

Desde un cliente con `root.crt` instalado: `https://syncthing.lan` → Authelia 2FA → password GUI Syncthing → dashboard de Syncthing visible.

### 9.3. Acceso a la API REST con X-API-Key (bypass de Authelia)

```bash
API_KEY=$(grep ^SYNCTHING_API_KEY /mnt/hd2t/services/syncthing/.env | cut -d= -f2)
curl -fsS -k -H "X-API-Key: ${API_KEY}" https://syncthing.lan/rest/system/version | jq .version
# Esperado: "v1.27.7" (o la versión instalada).
unset API_KEY
```

Sin la key:

```bash
curl -k https://syncthing.lan/rest/system/version
# Esperado: HTTP 403 con "Not authorized" (Syncthing rechaza). Authelia NO interviene.
```

### 9.4. Versionado funciona

```bash
echo "v1" > /mnt/hd2t/sync/default/test.txt
sleep 5  # Syncthing escanea cada 60 s por defecto, pero también notifica via inotify.
echo "v2" > /mnt/hd2t/sync/default/test.txt
sleep 10
ls /mnt/hd2t/sync/default/.stversions/
# Esperado (tras varios edits): test~YYYYMMDD-HHMMSS.txt
```

### 9.5. Sync con un peer real (desde el portátil)

Tocar un fichero en `~/Sync/default/` del portátil:

```bash
echo "hola pi" > ~/Sync/default/from-laptop.txt
```

En la Pi (esperar ~10 s):

```bash
ls /mnt/hd2t/sync/default/from-laptop.txt
# Esperado: existe; dueño homelab:homelab, permisos 0644.
cat /mnt/hd2t/sync/default/from-laptop.txt
# Esperado: hola pi
```

Inverso (Pi → portátil):

```bash
echo "hola laptop" > /mnt/hd2t/sync/default/from-pi.txt
sudo chown homelab:homelab /mnt/hd2t/sync/default/from-pi.txt
```

Tras ~10 s, el portátil tiene el fichero.

### 9.6. Local discovery activo

```bash
docker logs syncthing 2>&1 | grep -i 'discover\|broadcast' | tail -5
# Esperado: líneas tipo
#   INFO: Loading ignores from /var/syncthing/sync/default/.stignore
#   INFO: Local discovery: Sending announcement to 255.255.255.255:21027
```

### 9.7. Cert / Device ID estables tras restart

```bash
DEVICE_ID_PRE=$(docker exec syncthing syncthing --device-id)
docker compose -f ~/homelab/stacks/syncthing/docker-compose.yml restart syncthing
sleep 30
DEVICE_ID_POST=$(docker exec syncthing syncthing --device-id)
[ "$DEVICE_ID_PRE" = "$DEVICE_ID_POST" ] && echo "Device ID estable: $DEVICE_ID_POST"
# Esperado: "Device ID estable: ABCDEFG-..."
```

### 9.8. Persistencia tras reboot

```bash
sudo reboot

# (esperar a que vuelva)

docker compose -f ~/homelab/stacks/syncthing/docker-compose.yml ps
# Esperado: Up X (healthy)
ls /mnt/hd2t/sync/default
# Esperado: contenido intacto.
```

### 9.9. Acceso desde Tailscale (si está habilitado)

Desde un cliente con Tailscale (móvil o portátil fuera de casa):

```bash
# Conectar al GUI vía Tailscale (si se configuró el bloque syncthing.tailnet.ts.net en §14.5).
curl -fsS https://syncthing.tailnet.ts.net/rest/noauth/health
# Esperado: {"status":"OK"}.

# Sync de las carpetas: se establece automáticamente vía global discovery + Tailscale.
# Verificar conexión peer:
#   GUI Syncthing → Remote Devices → la Pi debería aparecer como "Connected (LAN)" o "Connected".
```

### 9.10. Lista de Verificación

Antes de pasar a [`04-minio.md`](./04-minio.md):

- [ ] `docker compose ps` en el stack `syncthing` → `Up (healthy)`.
- [ ] `sudo ss -lntu sport=:22000` muestra TCP y UDP en LISTEN; `:21027` UDP también.
- [ ] `sudo ss -lntu sport=:8384` está VACÍO (el GUI no se publica al host).
- [ ] `curl -fsS -k https://syncthing.lan/rest/noauth/health` devuelve `{"status":"OK"}`.
- [ ] El GUI requiere Authelia 2FA + password de Syncthing (dos factores en cascada).
- [ ] La API REST con `X-API-Key` válida funciona; sin la key devuelve 403.
- [ ] El operador ha **anotado fuera del homelab** la API key y el password GUI de Syncthing.
- [ ] `docker exec syncthing syncthing --device-id` devuelve un Device ID, anotado en KeePassXC.
- [ ] Las tres carpetas (`default`, `phone-photos`, `obsidian`) aparecen en el GUI con estado "Up to Date" o "Syncing" (no "Stopped" / "Error").
- [ ] `ls /mnt/hd2t/sync/<folder>/.stfolder` existe en cada carpeta.
- [ ] Round-trip de fichero entre portátil y Pi funciona en menos de 10 s en LAN.
- [ ] Tras editar un fichero, la versión anterior aparece en `/mnt/hd2t/sync/default/.stversions/`.
- [ ] `~/homelab/stacks/syncthing/{docker-compose.yml,.env.example}` versionados en git; `.env` **NO**.
- [ ] `/mnt/hd2t/services/syncthing/config/cert.pem` y `key.pem` existen y son propiedad `homelab:homelab` (NO regenerar).
- [ ] Tras `sudo reboot`, el contenedor arranca y el sync se reanuda sin intervención.

---

## 10. Backup

Estrategia que se concretará en [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md). Lo que **debe respaldarse** del stack `syncthing`:

| Ruta | Qué contiene | Frecuencia | Cómo |
|---|---|---|---|
| `~/homelab/stacks/syncthing/{docker-compose.yml,.env.example}` | Definición del stack. | Versionado en git → `git push`. | Continuo. |
| `/mnt/hd2t/services/syncthing/.env` | API key, tag, dominios. Reconstruible desde `.env.example` excepto la API key. | Cada cambio. | Snapshot Borg. |
| `/mnt/hd2t/services/syncthing/config/config.xml` | **Crítico**. Configuración de carpetas, peers, GUI auth, ignore patterns. La pérdida fuerza re-pairing con todos los peers (UI lenta, requiere coordinación humana). | **Diaria**. | Snapshot Borg. |
| `/mnt/hd2t/services/syncthing/config/cert.pem` + `key.pem` | **Crítico**. Identidad criptográfica del nodo. La pérdida cambia el Device ID → hay que re-pairing en cada peer. | **Diaria**. | Snapshot Borg. |
| `/mnt/hd2t/services/syncthing/config/index-v0.14.0.db/` | Base de datos LevelDB con índices de bloques. **Regenerable**: si se pierde, Syncthing rehashea todo el contenido (puede tardar horas en `phone-photos` con cientos de GB), pero los datos no se pierden. | Opcional. | Excluir de Borg para no pesar (puede llegar a varios GB). |
| `/mnt/hd2t/sync/default/` | Datos del operador (notas, dotfiles, proyectos). **Crítico** según contenido. | **Diaria** diferencial. | Snapshot Borg. |
| `/mnt/hd2t/sync/obsidian/` | Vault de Obsidian. **Crítico** y pequeño (<1 GB). | **Diaria**. | Snapshot Borg. |
| `/mnt/hd2t/sync/phone-photos/` | Fotos del móvil. **Crítico** según política personal. Voluminoso (10–100 GB). | Diaria diferencial. | Snapshot Borg con dedup. |
| `/mnt/hd2t/sync/<folder>/.stversions/` | Histórico de versiones que mantiene Syncthing. Útil pero **redundante** con Borg (que ya conserva snapshots por día). | Opcional. | Excluir si Borg ya cubre el histórico. |

### 10.1. Pre-backup hook (ejemplo Borgmatic)

```yaml
# Pseudo-config; la real va en 07-backups/02-borgmatic.md.
exclude_patterns:
  # Excluir la DB de índices: regenerable, voluminosa.
  - '/mnt/hd2t/services/syncthing/config/index-v0.14.0.db/**'
  # Excluir las versiones internas si Borg cubre el histórico.
  - '/mnt/hd2t/sync/*/.stversions/**'

before_backup:
  # Pausar el sync para snapshot consistente de la DB y los datos.
  # syncthing CLI no tiene "pause global"; usar la API REST.
  - >
    API_KEY=$(grep ^SYNCTHING_API_KEY /mnt/hd2t/services/syncthing/.env | cut -d= -f2);
    curl -s -X POST -H "X-API-Key: $API_KEY" http://syncthing:8384/rest/system/pause

after_backup:
  - >
    API_KEY=$(grep ^SYNCTHING_API_KEY /mnt/hd2t/services/syncthing/.env | cut -d= -f2);
    curl -s -X POST -H "X-API-Key: $API_KEY" http://syncthing:8384/rest/system/resume
```

> **Por qué pausar y no apagar**: pausar mantiene el contenedor vivo, sólo detiene el watcher de cambios. La DB sigue siendo coherente y el backup de los ficheros es atómico desde el punto de vista de Syncthing. Apagar (`docker stop`) sería más conservador pero rompe el GUI durante el backup y los peers ven al nodo como "Disconnected".

### 10.2. Restore (resumen)

Procedimiento completo en [`../07-backups/03-backup-docker-volumes.md`](../07-backups/03-backup-docker-volumes.md). Resumen:

1. `docker compose down` en el stack `syncthing`.
2. Restaurar `/mnt/hd2t/services/syncthing/{config,.env}` desde Borg.
   - **Mantener `cert.pem`/`key.pem` del backup**: regenerarlos cambia el Device ID y obliga a re-pairing.
3. Restaurar `/mnt/hd2t/sync/` desde Borg (todas las carpetas).
4. **No restaurar** `index-v0.14.0.db/`: dejarlo regenerar. Syncthing detecta su ausencia y rehashea (carpetas grandes pueden tardar horas).
5. `docker compose up -d`.
6. Verificar en el GUI que las carpetas vuelven a estado "Idle / Up to Date" tras el rescan inicial.
7. Confirmar con un peer que la conexión se reanuda automáticamente (el Device ID no cambió).

> **Punto crítico**: si por accidente se generaron `cert.pem`/`key.pem` nuevos (porque el restore los eliminó y Syncthing los recreó), el Device ID es **distinto** del anterior. Cada peer mostrará al "antiguo" como Disconnected y al "nuevo" como `Unknown Device`. Hay que re-aceptar el nuevo en cada peer y eliminar el antiguo. Todos los datos se preservan, sólo es coordinación humana de minutos por peer.

---

## 11. Operaciones cotidianas

### 11.1. Editar `config.xml` sin recreate

Algunos ajustes (GUI auth, listen address, etc.) se cambian desde el GUI. Otros sólo desde `config.xml`:

```bash
# Pausar Syncthing para evitar escrituras concurrentes mientras editas.
API_KEY=$(grep ^SYNCTHING_API_KEY /mnt/hd2t/services/syncthing/.env | cut -d= -f2)
curl -s -X POST -H "X-API-Key: $API_KEY" http://localhost:8384/rest/system/pause

# Editar el XML.
sudo nano /mnt/hd2t/services/syncthing/config/config.xml

# Reload sin recreate.
docker compose -f ~/homelab/stacks/syncthing/docker-compose.yml restart syncthing
unset API_KEY
```

> Syncthing **no soporta hot-reload** de `config.xml`: hay que reiniciar el proceso. `restart` es seguro: el state vive en la DB, los peers reconectan en segundos.

### 11.2. Añadir una carpeta nueva por CLI / API

Más rápido que el GUI para automatizaciones:

```bash
API_KEY=$(grep ^SYNCTHING_API_KEY /mnt/hd2t/services/syncthing/.env | cut -d= -f2)

# Crear el directorio en el host primero.
sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/sync/proyectos

# Añadir el folder vía API.
curl -fsS -X POST -H "X-API-Key: $API_KEY" -H 'Content-Type: application/json' \
  http://localhost:8384/rest/config/folders \
  -d '{
    "id": "proyectos",
    "label": "proyectos",
    "path": "/var/syncthing/sync/proyectos",
    "type": "sendreceive",
    "rescanIntervalS": 60,
    "fsWatcherEnabled": true,
    "versioning": {
      "type": "simple",
      "params": {"keep": "5"}
    }
  }'

unset API_KEY
```

Verificar en el GUI: la nueva carpeta aparece como "stopped (folder marker missing)" — Syncthing crea `.stfolder` solo si la carpeta es Send & Receive y la operación se confirma. Para forzar:

```bash
docker exec syncthing touch /var/syncthing/sync/proyectos/.stfolder
```

### 11.3. Comandos útiles vía API REST

```bash
API_KEY=$(grep ^SYNCTHING_API_KEY /mnt/hd2t/services/syncthing/.env | cut -d= -f2)
HDR="X-API-Key: $API_KEY"

# Estado global del sistema.
curl -fsS -H "$HDR" http://localhost:8384/rest/system/status | jq .

# Listar peers conectados.
curl -fsS -H "$HDR" http://localhost:8384/rest/system/connections \
  | jq '.connections | to_entries[] | {device: .key, connected: .value.connected, address: .value.address}'

# Estado de cada folder.
for f in default phone-photos obsidian; do
  echo "=== $f ===";
  curl -fsS -H "$HDR" "http://localhost:8384/rest/db/status?folder=$f" \
    | jq '.state, .globalFiles, .localFiles, .needFiles';
done

# Forzar rescan de un folder concreto.
curl -fsS -X POST -H "$HDR" "http://localhost:8384/rest/db/scan?folder=default"

# Forzar rescan de toda la base de datos.
curl -fsS -X POST -H "$HDR" "http://localhost:8384/rest/db/scan"

# Reiniciar Syncthing (sin tocar el contenedor).
curl -fsS -X POST -H "$HDR" "http://localhost:8384/rest/system/restart"

unset API_KEY
```

### 11.4. Cambiar el password del GUI

Desde el GUI: **Settings** → **GUI** → cambiar **GUI Authentication Password** → **Save**.

Vía CLI (útil en disaster recovery sin GUI accesible):

```bash
# Generar el bcrypt hash con openssl (Syncthing 1.27+ usa bcrypt).
NEW_PASS=$(openssl rand -base64 24 | tr -d '\n')
HASH=$(htpasswd -bnBC 10 "" "$NEW_PASS" | tr -d ':\n')

# Reemplazar el <password> en config.xml.
sudo sed -i "s|<password>.*</password>|<password>${HASH}</password>|" \
  /mnt/hd2t/services/syncthing/config/config.xml

docker compose -f ~/homelab/stacks/syncthing/docker-compose.yml restart syncthing

echo "Nuevo password GUI: ${NEW_PASS}"
unset NEW_PASS HASH
```

> `htpasswd` viene del paquete `apache2-utils` en Debian: `sudo apt install -y apache2-utils`.

### 11.5. Rotar la API key

```bash
NEW_API_KEY=$(openssl rand -hex 16)

# 1. Actualizar el .env del host.
sudo sed -i "s|^SYNCTHING_API_KEY=.*|SYNCTHING_API_KEY=${NEW_API_KEY}|" \
  /mnt/hd2t/services/syncthing/.env

# 2. Reiniciar para que la imagen propague la nueva key a config.xml.
docker compose -f ~/homelab/stacks/syncthing/docker-compose.yml \
  --env-file /mnt/hd2t/services/syncthing/.env up -d --force-recreate

# 3. Verificar.
docker exec syncthing sh -c \
  'grep "<apikey>" /var/syncthing/config/config.xml'
# Esperado: <apikey>NUEVO_VALOR</apikey>

# 4. Actualizar el widget de Homepage (cuando esté desplegado) y cualquier
#    integración (Uptime Kuma, scripts) que use la key vieja.

echo "Nueva API key Syncthing: ${NEW_API_KEY}"
unset NEW_API_KEY
```

### 11.6. Pausar / reanudar todo el sync

```bash
API_KEY=$(grep ^SYNCTHING_API_KEY /mnt/hd2t/services/syncthing/.env | cut -d= -f2)

# Pausar (todos los folders y peers).
curl -fsS -X POST -H "X-API-Key: $API_KEY" http://localhost:8384/rest/system/pause

# Reanudar.
curl -fsS -X POST -H "X-API-Key: $API_KEY" http://localhost:8384/rest/system/resume

unset API_KEY
```

### 11.7. Ignorar ficheros (`.stignore`)

Cada folder soporta un fichero `.stignore` con patrones glob. Editar desde el GUI (folder → **Edit** → pestaña **Ignore Patterns**) o directamente en disco:

```bash
cat > /mnt/hd2t/sync/default/.stignore <<'EOF'
# Ignore patterns para 'default'.
.DS_Store
Thumbs.db
*.tmp
*.swp
.git/
node_modules/
__pycache__/
*.pyc
EOF

# Forzar rescan.
API_KEY=$(grep ^SYNCTHING_API_KEY /mnt/hd2t/services/syncthing/.env | cut -d= -f2)
curl -fsS -X POST -H "X-API-Key: $API_KEY" \
  "http://localhost:8384/rest/db/scan?folder=default"
unset API_KEY
```

> El `.stignore` se sincroniza entre peers como cualquier otro fichero. Si todos los peers comparten patrones, se mantiene coherente automáticamente.

### 11.8. Recuperar un fichero del versionado

```bash
# Ver versiones disponibles de un fichero.
ls -la /mnt/hd2t/sync/default/.stversions/ | grep test
# Esperado:
#   -rw-r--r-- 1 homelab homelab ... test~20251101-143022.txt
#   -rw-r--r-- 1 homelab homelab ... test~20251102-091500.txt

# Restaurar una versión concreta.
sudo cp /mnt/hd2t/sync/default/.stversions/test~20251102-091500.txt \
        /mnt/hd2t/sync/default/test.txt
sudo chown homelab:homelab /mnt/hd2t/sync/default/test.txt

# Syncthing detecta el cambio (inotify) y propaga al resto de peers.
```

### 11.9. Upgrade de imagen (Watchtower lo hace automáticamente)

Watchtower está configurado en [`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §3 para procesar contenedores con `watchtower.enable=true` en su franja horaria. Procedimiento manual:

```bash
cd ~/homelab/stacks/syncthing
docker compose --env-file /mnt/hd2t/services/syncthing/.env pull syncthing
docker compose --env-file /mnt/hd2t/services/syncthing/.env up -d
docker logs syncthing | tail -20
# Esperado: "INFO: syncthing v1.X.Y ..." con la nueva versión.
```

> Tras un upgrade major, revisar release notes en https://github.com/syncthing/syncthing/releases por si hay notas de migración (raramente las hay para minor; los major bumps de protocolo se anuncian con varias minor de antelación).

---

## 12. Solución de Problemas

| Síntoma | Causa probable | Acción |
|---|---|---|
| GUI muestra "**Host check error**" tras login Authelia | Caddy no reescribe `Host:` o Syncthing exige host concreto. | Verificar que el bloque del `Caddyfile` (§7.1) lleva `header_up Host {host}`. Si persiste, configurar `<gui>` → `<insecureAdminAccess>` o añadir `syncthing.lan` a "GUI Override Endpoints" (§8.4). |
| GUI carga pero el dashboard queda en blanco | El JS del GUI hace requests a `/rest/...` que Authelia bloquea. | Confirmar el `handle /rest/*` con bypass en el `Caddyfile` y la regla `policy: bypass` en Authelia (§7.2). Inspector del navegador → Network → ver si `/rest/system/status` responde 401/403. |
| `docker compose up` falla con `port is already allocated` | Algún proceso del host ocupa 22000 / 21027 / 8384. | `sudo ss -lntu sport=:22000`, `sudo systemctl status syncthing` (paquete apt), parar y deshabilitar antes del `up`. |
| Container `(unhealthy)` de forma intermitente | El healthcheck `curl` tarda más de 10 s en reindexaciones grandes. | Subir `start_period` a 60 s y `timeout` a 20 s. Si persiste, descartar I/O de hd2t saturado (`iostat -x 1` durante el escaneo). |
| Peer "Disconnected" en LAN aunque ambos están encendidos | Local discovery (UDP 21027) no alcanza la Pi. | `tcpdump -i eth0 -nn 'udp and port 21027'` durante 60 s: deberían verse paquetes desde el peer. Si no, revisar firewall del cliente (Windows Defender) o `ufw allow 21027/udp` (§8). |
| Peer "Disconnected" sólo cuando está fuera de la LAN | Global discovery falla o el peer no tiene Tailscale. | GUI → **Settings** → **Connections** → comprobar "Global Discovery: Enabled" y "STUN: contacted". Si todo OK, problema de NAT del peer remoto: forzar relay o habilitar Tailscale en el peer. |
| Sync arranca pero queda al 99% para siempre | Permisos: Syncthing como UID 1000 no puede escribir en algún subdirectorio que llegó del peer con UID/GID raros. | `find /mnt/hd2t/sync/<folder> -not -user homelab -ls`: si aparece, `sudo chown -R homelab:homelab /mnt/hd2t/sync/<folder>`. La causa típica es un restore parcial del backup o un `chown` previo erróneo. |
| Versionado consume mucho espacio | Política `staggered` con `maxAge` muy alto, o `simple` con `keep` alto en folder con muchos cambios. | Inspeccionar: `du -sh /mnt/hd2t/sync/*/.stversions/`. Cambiar política en GUI o purgar manualmente con `find /mnt/hd2t/sync/<folder>/.stversions -mtime +180 -delete`. |
| Cambio en `config.xml` editado a mano se revierte tras restart | Syncthing reescribe el XML a su gusto al arrancar (formatting); algunas claves no documentadas no se preservan. | Editar via GUI o API REST (`/rest/config/...`) en lugar de XML directo. Si hay que tocar XML, hacer un `cp` antes y comparar tras el restart. |
| API key cambia tras restart aunque `.env` la fija | La imagen no propaga `STAPIKEY` con `update existing config`: sólo lo hace si `config.xml` no existe o si la key actual es la "auto-generada" del primer arranque. | Para forzar propagación: parar el contenedor, editar `config.xml` reemplazando `<apikey>` a mano, levantar de nuevo. |
| Watchtower actualiza Syncthing y los peers se desconectan permanentemente | Cambio de major version con bump de protocolo (raro pero ocurre cada 1–2 años). | Revisar release notes. Solución: actualizar también los peers a la nueva major. Mientras tanto, fijar `SYNCTHING_IMAGE_TAG` a la última estable y desactivar Watchtower (§14.3). |
| GUI inaccesible tras un cambio en `<gui>` por mistake | `<address>` o `<rawListenAddress>` mal configurados; Syncthing escucha en localhost o en otro puerto. | `docker exec syncthing cat /var/syncthing/config/config.xml | grep -A3 '<gui>'`. Editar a `<address>0.0.0.0:8384</address>` y restart. |
| Borrado masivo en el peer borra todos los ficheros en la Pi | El folder es Send & Receive y el peer empuja deletes. **Comportamiento esperado**, no un bug. | Para que el borrado en el peer NO se propague a la Pi, configurar el folder en la Pi como **Receive Only**. El peer puede borrar libremente y la Pi mantiene la copia. Útil para `phone-photos`. |
| Conflicto: aparecen ficheros `<nombre>.sync-conflict-...` | Edición simultánea del mismo fichero en dos peers antes de que se sincronice el primero. | Resolver manualmente: comparar las dos versiones y borrar la perdedora. Syncthing nunca pierde datos: ambas versiones coexisten hasta que el operador decide. |
| `docker logs syncthing` repite "Failed to listen on tcp://0.0.0.0:22000" | Conflicto de puerto o el contenedor se reinicia muy rápido. | Confirmar que ningún otro contenedor publica 22000. Si Watchtower acaba de actualizar, esperar 30 s a que el viejo libere el puerto. |
| Sync entre Pi y portátil va a 50 KB/s en LAN gigabit | Encryption + I/O de la microSD, o la carpeta está en hd2t saturando el bus USB con escrituras concurrentes (rsync interno hashea + escribe). | Verificar `iotop` en la Pi durante el sync. Si hd2t llega a 100 MB/s sostenidos, está saturado y es esperable. Reducir concurrencia con `<options><maxFolderConcurrency>1</maxFolderConcurrency></options>`. |

---

## 13. Integración con Fail2ban (opcional)

Syncthing no se incluye por defecto en [`../04-seguridad/02-fail2ban.md`](../04-seguridad/02-fail2ban.md) porque su superficie de auth está triplemente protegida (Authelia 2FA + auth nativa + Caddy rate limiting). Si el operador quiere defensa en profundidad para el GUI:

### 13.1. Filtro `filter.d/syncthing.local`

Crear `~/homelab/stacks/syncthing/snippets-fail2ban/syncthing.local`:

```ini
# ~/homelab/stacks/syncthing/snippets-fail2ban/syncthing.local
# Detecta fallos de auth en el GUI (logs json del demonio).

[Definition]
failregex = ^.*Failed login attempt for user .* from <HOST>$

ignoreregex =

datepattern = {^LN-BEG}%%Y-%%m-%%dT%%H:%%M:%%S
              {^LN-BEG}%%b\s+%%d\s+%%H:%%M:%%S
```

### 13.2. Jail `jail.d/40-syncthing.conf`

```ini
# ~/homelab/stacks/syncthing/snippets-fail2ban/40-syncthing.conf
# Drop-in para /etc/fail2ban/jail.d/.

[syncthing]
enabled  = true
filter   = syncthing
backend  = auto
# Syncthing escribe los logs a stdout del contenedor; bind mount no aplica.
# Usar journald del demonio Docker en su lugar:
backend  = systemd
journalmatch = CONTAINER_NAME=syncthing
port     = 80,443
maxretry = 5
findtime = 10m
bantime  = 1h
```

### 13.3. Aplicar al host

```bash
sudo install -m 644 -o root -g root \
  ~/homelab/stacks/syncthing/snippets-fail2ban/syncthing.local \
  /etc/fail2ban/filter.d/syncthing.local

sudo install -m 644 -o root -g root \
  ~/homelab/stacks/syncthing/snippets-fail2ban/40-syncthing.conf \
  /etc/fail2ban/jail.d/40-syncthing.conf

sudo fail2ban-client reload
sudo fail2ban-client status syncthing
```

> **Caveat**: si Authelia ya bloquea por delante (sus propios límites), un atacante apenas pasa de ahí. El jail aquí actúa como red de seguridad ante un fallo de Authelia.

---

## 14. Variantes opt-in

### 14.1. Acceso al GUI sin Authelia (no recomendado)

Si el operador no usa Authelia y quiere el GUI sólo con la auth nativa de Syncthing:

```caddy
syncthing.{$LAN_DOMAIN} {
    import lan_internal_tls
    import security_headers
    reverse_proxy http://syncthing:8384 {
        header_up Host {host}
    }
}
```

Sustituir el `handle` de §7.1 por la versión simple. Riesgo: la auth de Syncthing es user/password sin 2FA — un brute-force agresivo podría romperla con un password débil. Imprescindible password largo + considerar el jail Fail2ban (§13).

### 14.2. `network_mode: host` (descubrimiento más rápido)

Si los broadcasts UDP 21027 no llegan bien al contenedor en bridge:

1. Cambiar el bloque `networks` por `network_mode: host` y eliminar el `ports:`.
2. **Caddy ya no llega por DNS interno**: hay que añadir `extra_hosts: ["host.docker.internal:host-gateway"]` al servicio `caddy` (en `~/homelab/stacks/proxy/docker-compose.yml`) y cambiar el `reverse_proxy` a `http://host.docker.internal:8384`.
3. **Bind a 127.0.0.1 dentro del contenedor**: `STGUIADDRESS=127.0.0.1:8384` para que el GUI no se exponga al host (sólo accesible vía Caddy con la pirueta del paso 2).
4. Reglas `ufw` para 22000/tcp, 22000/udp, 21027/udp pasan a aplicarse igual que cualquier servicio del host.

> Sólo se justifica si el operador comprueba que el local discovery no funciona en bridge. En la mayoría de redes domésticas, bridge + `ports: 21027/udp` es suficiente.

### 14.3. Desactivar Watchtower para Syncthing

Si el operador prefiere upgrades manuales (revisar release notes antes de cada minor):

```yaml
labels:
  com.centurylinklabs.watchtower.enable: "false"
  # ... resto de labels
```

Procedimiento manual: §11.9.

### 14.4. Compartir una carpeta de sync por Samba

Si se quiere abrir `/mnt/hd2t/sync/default/` también por SMB (cuidado con los conflictos: una edición desde Samba dispara un evento de sync que repropaga el cambio):

1. Añadir el bind mount en el `docker-compose.yml` de **Samba** (no aquí):
   ```yaml
   - type: bind
     source: /mnt/hd2t/sync/default
     target: /mnt/hd2t/sync/default
     bind:
       create_host_path: false
   ```
2. Añadir el share en `smb.conf` de Samba:
   ```ini
   [sync-default]
       comment       = Carpeta sincronizada por Syncthing
       path          = /mnt/hd2t/sync/default
       browseable    = yes
       read only     = no
       writable      = yes
       force user    = homelab
       force group   = homelab
       valid users   = homelab
   ```
3. Reload Samba.

> **Riesgo**: si dos clientes editan el mismo fichero (uno por SMB, otro por Syncthing en otro peer), salen `.sync-conflict-...` o, peor, parcialmente fusionados. Documentar al operador que el path es **unidireccional** en su flujo: o bien edita por Syncthing, o bien por Samba, no ambos a la vez.

### 14.5. Acceder al GUI desde Tailscale (`syncthing.tailnet.ts.net`)

Añadir en el `Caddyfile`:

```caddy
syncthing.{$TS_DOMAIN} {
    import tailscale_tls syncthing
    import security_headers

    handle /rest/* {
        reverse_proxy http://syncthing:8384
    }

    handle {
        # Sin Authelia aquí: Tailscale ya es la "auth de transporte" (sólo
        # devices del tailnet llegan). La auth nativa de Syncthing sigue activa.
        reverse_proxy http://syncthing:8384 {
            header_up Host {host}
        }
    }
}
```

Reload Caddy. Desde un dispositivo en el tailnet: `https://syncthing.tailnet.ts.net` → password GUI Syncthing → dashboard.

> Si se quiere doble factor incluso en Tailscale, añadir `import authelia_proxy` al `handle` final igual que en §7.1.

### 14.6. Carpeta cifrada con peer no confiable (encrypted folders)

Caso de uso: un VPS barato como tercer peer que sostenga la copia 24/7 sin tener que confiar el contenido.

1. En el GUI Pi: folder → **Edit** → **Sharing** → marcar el peer "vps" y, junto a él, **Untrusted** + escribir un password de cifrado largo (anotar).
2. En el VPS: aceptar la carpeta, marcarla también como **Encrypted** con el mismo password.
3. El VPS guarda los bloques cifrados (no puede leer el contenido); la Pi y el portátil siguen viendo los ficheros en claro.

> Implica overhead de cifrado y alarga el espacio (los datos cifrados pesan ~5% más por overhead AEAD). Documentación: https://docs.syncthing.net/users/untrusted.html.

---

## Referencias

- [Syncthing — Documentación oficial](https://docs.syncthing.net/)
- [Syncthing — `config.xml` reference](https://docs.syncthing.net/users/config.html)
- [Syncthing — REST API](https://docs.syncthing.net/dev/rest.html)
- [Syncthing — Versioning (modos `simple`, `staggered`, etc.)](https://docs.syncthing.net/users/versioning.html)
- [Syncthing — Untrusted (encrypted) Devices](https://docs.syncthing.net/users/untrusted.html)
- [Syncthing — Firewalls and NAT](https://docs.syncthing.net/users/firewall.html)
- [Syncthing — Tuning (`fsWatcher`, `rescanIntervalS`)](https://docs.syncthing.net/users/tuning.html)
- [`syncthing/syncthing` (Docker Hub)](https://hub.docker.com/r/syncthing/syncthing)
- [`syncthing/syncthing` (GitHub releases)](https://github.com/syncthing/syncthing/releases)
- [Caddy — `header_up` y `reverse_proxy`](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy)
- [Caddy — Common Caddyfile Patterns (`handle` vs `reverse_proxy`)](https://caddyserver.com/docs/caddyfile/patterns)
