# Syncthing

## Descripción

Cerrados `01-nextcloud.md` y `02-samba.md`, el homelab cubre dos casos clásicos de sincronización de ficheros: la **nube personal** (Nextcloud, con cliente de escritorio que sincroniza una carpeta contra un servidor) y el **disco de red** (Samba, con clientes que abren ficheros remotos sin copiar). Hay un tercer caso, distinto a los dos anteriores, que ninguno resuelve bien:

- **Sincronización peer-to-peer entre dispositivos del propio operador**: la carpeta `~/Pictures/` del portátil y la del PC de sobremesa deben ser **bit a bit** la misma, sin que el tránsito pase por un servidor central, sin un cliente que se quede colgado pidiendo *web request* HTTPS por cada chunk, y sin que un fallo del servidor congele a los dos extremos. El uso típico: fotos del móvil → Pi (nodo siempre encendido) → portátil; o un repositorio de notas que se quiere replicar entre dos PCs sin Nextcloud de por medio.
- **Sincronización resilient a desconexiones**: el operador trabaja en un café, hace cambios en una carpeta sincronizada, vuelve a casa y la carpeta se pone al día sin acción manual. Nextcloud lo hace, pero arrastra un pipeline pesado (BD, filecache, chunks). Samba no lo hace en absoluto: si pierdes red, pierdes acceso.
- **Sincronización con cifrado en tránsito por defecto y descubrimiento automático** entre dispositivos sin tener que configurar IPs, puertos o certificados a mano: cada nodo tiene un *device ID* derivado de su clave pública y se anuncia vía servidores de descubrimiento globales (o por mDNS local).

Este documento despliega **Syncthing** como nodo siempre-encendido del homelab. Su rol concreto:

- Ser el **punto de encuentro** de los dispositivos personales del operador (portátil, PC, móviles vía *Foldersync* o *Möbius Sync*) que viven con apagados intermitentes. La Pi mantiene la copia "fuente de verdad" y todos los demás se sincronizan contra ella.
- **Replicar carpetas concretas de `hd2t`** (no `hd5t`): repositorios de notas (Markdown), fotos del móvil con upload automático (`/mnt/hd2t/sync/photos`), un volcado del directorio `Documents/` del PC, etc.
- Ser **independiente de Nextcloud y Samba**: si Nextcloud cae por un upgrade fallido, Syncthing sigue replicando. Los tres servicios ven los mismos datos en disco solo si el operador lo decide explícitamente (por defecto, **no**: cada uno tiene su raíz dedicada en `hd2t`).
- **Estar accesible vía Caddy con TLS interno** desde la LAN para administrar el panel web (`https://syncthing.${DOMAIN_LAN}`), pero **dejar el plano de datos** (puerto `22000`) **publicado directamente** al host, porque Syncthing entre nodos no habla HTTP: usa su propio protocolo BEP (Block Exchange Protocol) sobre TLS mutuo. Caddy no tiene nada que hacer ahí.

Estará compuesto por **un único contenedor**:

- `syncthing` — imagen oficial `syncthing/syncthing:1.30`, ARM64 nativo, gestionada por el equipo de Syncthing.

Lo que este documento **no** decide:

- **Syncthing como motor de backup**. Syncthing **sincroniza**, no respalda: si se borra un fichero en un nodo, el cambio se propaga a los demás. La papelera por carpeta (`versioning: trashcan`) mitiga el riesgo durante un periodo finito, pero la responsabilidad del *backup* recae en Borg/Borgmatic (Fase 7) sobre el lado de la Pi. Se documenta cómo activar la papelera, no cómo sustituir un backup.
- **Syncthing como reemplazo de Nextcloud para 1–3 humanos**. Aunque en teoría Syncthing puede sincronizar carpetas con varios humanos, no tiene UI compartida, ni calendario, ni contactos, ni permisos por usuario. Es una herramienta para **el operador y sus dispositivos**, no para "la familia".
- **Untrusted devices con cifrado lado-receptor** (`folder type = receiveencrypted`). Reabrible si el operador quisiera replicar un subset cifrado a un nodo no-confiable (un VPS rentado, por ejemplo). Hoy todos los dispositivos pareados son del propio operador.
- **Compartir carpetas con terceros** (parientes, amigos). Reabrible si surge el caso; la práctica del homelab es: terceros usan la cuenta de Nextcloud, no Syncthing.
- **Discovery server y relay propios**. Syncthing publica en sus servidores globales (`discovery.syncthing.net`) un anuncio de IP y puerto **ya cifrado** con la clave pública de cada device; es seguro depender de ellos. Montar `stdiscosrv`/`strelaysrv` en la Pi sería sobreingeniería para 1 operador con <10 nodos.
- **GUI accesible sin Authelia**. La UI de Syncthing trae auth básica propia, pero se cubre además con Authelia 2FA porque expone control total del proceso (puede ejecutar comandos arbitrarios vía *external versioning command*). El plano de datos (`:22000`) **no** se protege con Authelia: lo asegura el TLS mutuo del protocolo BEP.
- **Sincronizar `/mnt/hd5t`**. La biblioteca de Stash es enorme (TBs), inmutable y específica de un consumidor (Stash). Replicarla por Syncthing no aporta nada y satura el upstream del operador. Reabrible solo si el caso de uso aparece, lo cual es improbable.

Cuando este documento se haya aplicado, el operador puede:

- Abrir `https://syncthing.${DOMAIN_LAN}/` desde la LAN (con la CA interna instalada), pasar Authelia 2FA, autenticarse contra Syncthing y ver el panel de carpetas y dispositivos.
- Conocer el *device ID* de la Pi (`docker exec syncthing syncthing cli show system | jq .myID`) y pegarlo en el panel del portátil para parearlos.
- Crear carpetas en `/mnt/hd2t/sync/<carpeta>` que se sincronizan automáticamente con los nodos pareados.
- Verificar que el tráfico de sincronización sale por TCP/22000 directamente entre la Pi y los nodos pareados sin pasar por Caddy ni por relays externos cuando los dos están en la misma LAN o en el mismo tailnet.
- Levantar un nodo móvil (Mobius Sync en iOS, Syncthing-Fork o Mobius en Android) y subir las fotos de la cámara automáticamente a `/mnt/hd2t/sync/photos/<dispositivo>/`.

> **Recordatorio de alcance**: Syncthing escucha en TCP/22000 (BEP), UDP/22000 (QUIC), UDP/21027 (descubrimiento local), y la GUI en `:8384` solo dentro de la red Docker `homelab`. La GUI sale al humano **únicamente** vía Caddy + Authelia. El plano de datos sale a la LAN y al tailnet. **No hay port-forwarding en el router**: Syncthing entre nodos remotos pasa por Tailscale o por relays globales (cifrados extremo-a-extremo).

---

## Requisitos Previos

- **Fase 1** completa: usuario `homelab` con `uid=1000, gid=1000`; estructura de directorios creada.
- **Fase 2** completa: Docker Engine + Compose v2; red `homelab` en `172.30.10.0/24`; convenciones `stacks/<svc>/`; `.env` global con `TZ`, `PUID=1000`, `PGID=1000`, `DOMAIN_LAN=lan`, `DOMAIN_TS` opcional.
- **Fase 3** completa, en particular:
  - Pi-hole con el comodín `address=/lan/192.168.1.10` (cubre automáticamente `syncthing.${DOMAIN_LAN}` sin tocar Pi-hole).
  - Caddy desplegado y los snippets `(lan_tls)`, `(security_headers)`, `(healthcheck)`, `(authelia_two_factor)` en `Caddyfile`.
- **Fase 4** completa: Authelia operativa con `default_policy: deny` y `forward_auth` integrado en Caddy. Se añadirá una regla `policy: two_factor` para `syncthing.${DOMAIN_LAN}`.
- Disco `hd2t` montado en `/mnt/hd2t`, con espacio suficiente para las carpetas a sincronizar (estimación inicial: 50–200 GiB; los dispositivos del hogar suben fotos del móvil y notas).
- Operador con la **CA interna instalada** en cualquier dispositivo que vaya a abrir el panel web.
- **`ufw` activo con política `deny incoming`**: hay que añadir reglas para `:22000/tcp`, `:22000/udp` y `:21027/udp` antes de levantar el contenedor (sección "Firewall del host").

Comprobaciones rápidas:

```bash
# Red Docker compartida
docker network inspect homelab --format '{{.Name}}' | grep -q '^homelab$' && echo ok

# Caddy y Authelia están healthy
docker ps --filter name=caddy --filter name=authelia --format '{{.Names}} {{.Status}}'

# syncthing.lan resuelve al IP de la Pi
dig +short syncthing.lan @192.168.1.2
# 192.168.1.10

# Espacio disponible en hd2t
df -h /mnt/hd2t | awk 'NR==2 {print $4 " libres"}'

# Nada escucha aún en los puertos de Syncthing
sudo ss -tlnp | grep ':22000' || echo 'TCP 22000 libre'
sudo ss -ulnp | grep -E ':(21027|22000)' || echo 'UDP libres'
```

---

## Decisión: imagen y variante

Hay dos imágenes mantenidas activamente para Syncthing en ARM64:

| Imagen | Mantenedor | Pros | Contras |
|---|---|---|---|
| **`syncthing/syncthing`** | Equipo oficial de Syncthing. | Tags semver, ARM64 first-class, `latest` siempre apunta al release oficial. Dockerfile minimal: el binario en Alpine sin extras. Variables `PUID`/`PGID` aceptadas. | Sin sidecar de discovery o relay (no se necesitan aquí). |
| `linuxserver/syncthing` | linuxserver.io. | Convención uniforme con el resto del catálogo de LinuxServer (fácil si todo el homelab usa LSIO). | Mantenimiento por terceros; ciclo de release tarda ~24 h tras upstream. La imagen incluye s6-overlay y procesos extra que aquí no aportan. |

| Decisión | Justificación |
|---|---|
| **`syncthing/syncthing:1.30`** | Imagen oficial, mantenida por el equipo del producto. Tag semver explícito (no `latest`). Las versiones *minor* de Syncthing introducen cambios en el formato del fichero `config.xml` y migrar de mayor (1.x → 2.x, eventual) requerirá una operación deliberada. Se pinpia para evitar sorpresas. |
| **No `latest`** | Syncthing rompe formato de configuración entre algunas mayores y los cambios de protocolo BEP exigen pareo con el resto de nodos. La política aquí es: el operador decide cuándo subir, lo prueba en frío con los dispositivos pareados y solo entonces actualiza este documento. Watchtower aplica solo *minor patches* en este servicio (digest del tag), no cambios de tag. |

> **Sobre Syncthing 1.30**: trae *ignore patterns* mejorados, sincronización más rápida en carpetas grandes, soporte experimental QUIC sobre UDP/22000, y compatibilidad con receivers cifrados. La versión exacta debe coincidir aproximadamente con la del cliente del portátil; Syncthing tolera diferencias *minor* sin problemas pero entre mayores puede degradar funcionalidades.

---

## Decisión: modo de red del contenedor

Syncthing escucha en cuatro puertos:

| Puerto | Protocolo | Para qué |
|---|---|---|
| `22000/tcp` | TCP | BEP (Block Exchange Protocol) sobre TLS mutuo: el plano de datos. **Obligatorio**. |
| `22000/udp` | QUIC | BEP sobre QUIC: alternativa a TCP, más rápido en redes con pérdida. **Opcional pero recomendado**. |
| `21027/udp` | mDNS-like | Local Discovery: anuncia el device ID por broadcast cada 30 s para que peers en la misma LAN se descubran sin pasar por servidores de discovery globales. |
| `8384/tcp` | HTTP/HTTPS | GUI de administración. |

| Modo | Pros | Contras | Veredicto |
|---|---|---|---|
| `network_mode: host` | Local Discovery (UDP/21027 broadcast) funciona sin trucos. Sin NAT por medio para QUIC. | Rompe el aislamiento Docker; `syncthing` ya no está en la red `homelab` y Caddy no puede hablarle por DNS interno. Conflictos potenciales con cualquier otro servicio que use 8384 en el host. | Aceptable, pero no necesario. |
| **Bridge `homelab` + `ports:` publicados** | GUI accesible vía `caddy → http://syncthing:8384`. Ports `22000/tcp` y `22000/udp` salen al host con NAT, lo cual basta para BEP/QUIC en la LAN y vía Tailscale. UDP/21027 broadcast **no** atraviesa NAT cómodamente, pero la afectación es solo *Local Discovery*: la sincronización se sigue haciendo vía Global Discovery (`*.discovery.syncthing.net`) que sí funciona detrás de NAT. | Pequeño coste de discovery: la primera vez que dos peers en la misma LAN se ven, tardan 30–60 s adicionales mientras se localizan vía servidor global en lugar del broadcast local. Aceptable. | **Aceptado**. |
| Macvlan dedicado | El contenedor tiene su propia IP en la LAN, broadcast nativo. | Consume slot de IP, complica firewall. Reservado en `docs/03-red/01-macvlan.md` para servicios que **necesitan** ser hosts L2 distintos; Syncthing no lo necesita. | Reservado, no aplicado hoy. |

| Decisión | Justificación |
|---|---|
| **Bridge con `ports: 22000:22000/tcp`, `22000:22000/udp`, `21027:21027/udp`** | Mantiene Syncthing en `homelab` para que Caddy sirva la GUI por HTTP interno. Los tres puertos van al host; UFW los expone solo a LAN y tailnet (sección "Firewall"). |
| **GUI no se publica al host (`expose: 8384`)** | El panel solo se sirve a través de Caddy + Authelia. Publicar `:8384` al host saltaría a Authelia y expondría la auth básica nativa de Syncthing al primero que descubra el puerto. |

> **Sobre `21027/udp` broadcast**: si el operador encuentra que dos nodos en la misma LAN tardan en parearse, basta con dejar el descubrimiento global activado (lo está por defecto, `globalAnnounceEnabled: true`). Para forzar discovery local desde un cliente, se puede meter directamente la IP de la Pi en la sección "Addresses" del peer (`tcp://192.168.1.10:22000`), saltándose el broadcast.

> **Sobre QUIC (`22000/udp`)**: opcional pero recomendado. QUIC funciona mejor en enlaces con pérdida (móvil) y reduce la latencia de la primera transferencia. Si UDP/22000 está bloqueado por la red del operador (cafeterías, hoteles), Syncthing cae automáticamente a TCP/22000.

---

## Decisión: autenticación en la GUI

Syncthing trae auth básica propia (`gui.user`/`gui.password`) y, además, tokens de API. La GUI da control total del demonio: añadir/quitar carpetas, ejecutar *external versioning commands* (que son shell scripts), reiniciar el proceso. Cualquier acceso debe estar protegido como una cuenta de admin del homelab.

| Mecanismo | Pros | Contras | Veredicto |
|---|---|---|---|
| Solo auth básica nativa de Syncthing | Cero dependencia. | El usuario/password viven en `config.xml` (cifrado pero recuperable), y la GUI no tiene 2FA propio. | Insuficiente. |
| **`forward_auth` Authelia + auth básica nativa** | SSO con el resto del homelab (un único portal de login), 2FA TOTP, y la auth nativa de Syncthing como **segunda capa** que protege incluso si Authelia tuviera un bug. | Doble login en la primera visita (Authelia y luego Syncthing) — pero cada uno se persiste por sesión, así que en práctica el navegador recuerda ambos. | **Aceptado**. |
| `forward_auth` Authelia + auth nativa **deshabilitada** | Un solo login. | Si por error se deja Caddy/Authelia desactivado o mal configurado, el panel queda **abierto** a cualquiera que llegue al puerto. Defensa en profundidad rota. | Descartado. |
| OIDC contra Authelia (cuando Authelia exponga OIDC) | SSO real. | Syncthing **no** soporta OIDC en la GUI; añadirlo requeriría un proxy intermedio. | Descartado. |

| Decisión | Justificación |
|---|---|
| **Capa 1: Authelia con `policy: two_factor`** | Igual que el resto de paneles del homelab (`prometheus`, `grafana`, etc.). |
| **Capa 2: GUI auth básica con usuario `homelab` y password fuerte** | Generada con `openssl rand -base64 24`, almacenada en el `.env` del stack y propagada al `config.xml` en el primer arranque vía variables de entorno. **Sin** auth básica el plano de control queda abierto al adjacente; un compromiso de Caddy o Authelia exigiría aún superar a Syncthing. |
| **GUI sobre HTTPS interno (Caddy maneja TLS)** | Syncthing puede servir su propio TLS, pero en este homelab Caddy es el único punto que termina TLS. La conexión Caddy → Syncthing va por HTTP plano dentro de la red `homelab`, idéntico patrón a Nextcloud/Pi-hole/etc. |
| **API key en `.env`** | Útil para automatización futura (scripts que consultan estado del nodo via `/rest/system/status`). Se rota con `pdbedit`-style desde la GUI. |

> **Sobre la *theme login page*** que Syncthing muestra: aparece tras Authelia. El operador hace login en `auth.lan` (Authelia, con TOTP), Caddy le deja pasar, y entonces ve el formulario de Syncthing pidiendo `username`/`password`. Esa duplicación es el coste explícito de la defensa en profundidad. En la práctica, el navegador autocompleta el segundo login y no se nota.

---

## Decisión: dónde viven los datos y permisos

La imagen oficial corre por defecto como UID `1000` cuando se le pasa `PUID=1000`/`PGID=1000`. El homelab ya tiene un usuario `homelab` con esos IDs, así que la coherencia es directa.

| Subsistema | Ruta en hd2t | Owner:Group | Justificación |
|---|---|---|---|
| Configuración (`config.xml`, `cert.pem`, `key.pem`, `index-v0.14.0.db`) | `/mnt/hd2t/apps/syncthing/config` | `1000:1000` | Estado interno de Syncthing: device ID derivado de `cert.pem` (NUNCA borrar — equivale a "borrar el dispositivo"), índice de bloques de las carpetas, configuración. |
| Carpetas a sincronizar (raíz dedicada) | `/mnt/hd2t/sync/<carpeta>` | `1000:1000` | Una raíz `sync/` separada del resto de `apps/`. Permite a Borg respaldarla con un calendario propio, y deja claro qué pertenece al *plano de sincronización* y qué no. |

Nombres concretos de carpetas iniciales (modificables más adelante):

| Carpeta | Ruta | Para qué |
|---|---|---|
| `notes` | `/mnt/hd2t/sync/notes` | Markdown (Obsidian, Logseq, Joplin export). Cambia mucho, ficheros pequeños. |
| `photos` | `/mnt/hd2t/sync/photos` | Subida automática de cámara desde móviles. Crece sin parar; **versioning trashcan** activo. |
| `documents` | `/mnt/hd2t/sync/documents` | Carpeta `~/Documents/` del operador. Tamaño moderado; versioning simple activo. |
| `code-scratch` | `/mnt/hd2t/sync/code-scratch` | Repos pequeños no críticos (los importantes van a Forgejo, Fase 8). Reabrir si se mete `.git/` aquí: hay reglas para excluirlo. |

> **Por qué no reusar `/mnt/hd2t/shares/` ni `/mnt/hd2t/apps/nextcloud/data/`**. Cada servicio del homelab tiene su raíz: Samba lee de `shares/`, Nextcloud de `apps/nextcloud/data/`, Syncthing de `sync/`. Mezclar dos servicios sobre la misma carpeta provoca *write races* y desconciertos en las trashcans/papeleras. Si en algún momento se quiere "ver desde Samba lo que sincroniza Syncthing", se añade un share Samba **read-only** que apunte a `/mnt/hd2t/sync/<carpeta>`; **nunca** rw concurrente.

> **Por qué no microSD**. La base de datos de índices (`index-v0.14.0.db`) crece con el número de ficheros sincronizados; sobre 100k ficheros puede llegar a varios GiB. Y Syncthing reescribe `config.xml` con cada cambio en la GUI. La SD-card no debe absorber esto.

---

## Stack: `stacks/syncthing/`

### Layout en disco

| Ruta | Soporte | Contenido |
|---|---|---|
| `stacks/syncthing/docker-compose.yml` | microSD (git) | Stack (servicio `syncthing`). |
| `stacks/syncthing/.env.example` | microSD (git) | Plantilla con `SYNCTHING_GUI_USER`, `SYNCTHING_GUI_PASSWORD`, `SYNCTHING_API_KEY`. |
| `stacks/caddy/conf.d/08-syncthing.caddy` | microSD (git) | Drop-in del bloque LAN para `syncthing.${DOMAIN_LAN}`. |
| `/mnt/hd2t/apps/syncthing/config/` | hd2t | Estado: `config.xml`, `cert.pem`, `key.pem`, `index-v*.db`. Owner `1000:1000`. |
| `/mnt/hd2t/sync/notes/` | hd2t | Carpeta sincronizada `notes`. Owner `1000:1000`. |
| `/mnt/hd2t/sync/photos/` | hd2t | Carpeta sincronizada `photos`. Owner `1000:1000`. |
| `/mnt/hd2t/sync/documents/` | hd2t | Carpeta sincronizada `documents`. Owner `1000:1000`. |
| `/mnt/hd2t/sync/code-scratch/` | hd2t | Carpeta sincronizada `code-scratch`. Owner `1000:1000`. |

### `stacks/syncthing/docker-compose.yml`

```yaml
# Syncthing — sincronización P2P entre dispositivos del operador.
# Documentado en docs/06-almacenamiento/03-syncthing.md.

name: syncthing

services:
  syncthing:
    image: syncthing/syncthing:1.30
    container_name: syncthing
    hostname: syncthing
    restart: unless-stopped

    # Plano de datos: TCP/22000 (BEP), UDP/22000 (QUIC), UDP/21027 (Local Discovery).
    # Plano de control (GUI :8384) NO se publica al host: se sirve solo vía Caddy.
    ports:
      - "22000:22000/tcp"
      - "22000:22000/udp"
      - "21027:21027/udp"

    expose:
      - "8384"

    environment:
      TZ: ${TZ}
      PUID: ${PUID}
      PGID: ${PGID}

      # --- GUI auth nativa (segunda capa tras Authelia) ---
      # La imagen oficial respeta estas variables solo en el primer arranque
      # (cuando aún no existe config.xml). En arranques posteriores, los
      # cambios de password se hacen vía GUI o editando config.xml a mano.
      STGUIADDRESS: 0.0.0.0:8384
      STGUIAPIKEY: ${SYNCTHING_API_KEY}

      # --- Telemetría y novedad de UI: deshabilitadas ---
      # No enviar usage report al equipo de Syncthing (decisión homelab).
      STNOUPGRADE: "true"             # No se autoactualiza; lo controla el operador.
      STHASHING: "standard"

    volumes:
      # Estado y configuración persistente.
      - /mnt/hd2t/apps/syncthing/config:/var/syncthing/config
      # Carpetas sincronizadas: raíz dedicada `/mnt/hd2t/sync/` montada como
      # `/var/syncthing/sync/` dentro del contenedor. Cada carpeta concreta
      # se da de alta desde la GUI con path `/var/syncthing/sync/<nombre>`.
      - /mnt/hd2t/sync:/var/syncthing/sync

    networks:
      - homelab

    healthcheck:
      # /rest/noauth/health responde sin auth, status 200 cuando syncthing
      # está vivo y la BD de índices accesible.
      test:
        - "CMD-SHELL"
        - "wget -q -O - http://127.0.0.1:8384/rest/noauth/health | grep -q '\"status\":\"OK\"'"
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 30s

    labels:
      homelab.role: "p2p-sync"
      homelab.backup: "true"
      # Syncthing minor upgrades pueden cambiar formato de config.xml;
      # se actualiza solo manualmente con prueba previa en otro nodo.
      com.centurylinklabs.watchtower.enable: "false"

networks:
  homelab:
    external: true
```

> **Sobre `STGUIADDRESS=0.0.0.0:8384`**: por defecto la imagen oficial escucha en `0.0.0.0:8384` ya, pero hacerlo explícito es defensa contra un upgrade que cambiase el default a `127.0.0.1` (lo cual rompería la conexión desde Caddy). Como el puerto solo está en `expose:` (no `ports:`), no se publica al host: solo Caddy en la red `homelab` puede llegar.

> **Sobre `STNOUPGRADE=true`**: Syncthing trae un auto-updater nativo que descarga el binario más reciente y lo aplica al reiniciar. Combinado con un tag fijo (`1.30`), el auto-updater haría que el binario en el contenedor difiera del declarado en la imagen — lo cual es confuso y rompe la reproducibilidad. Se desactiva.

> **Sobre `STHASHING=standard`**: la opción `weak` ahorra CPU pero introduce más riesgo de colisiones falsas. En una Pi 5 con ARMv8 hay AES nativo y SHA acelerado; `standard` no es coste medible.

> **Sobre Watchtower deshabilitado**: idéntica regla que para Nextcloud y PostgreSQL. Las migraciones de `config.xml` entre majors se aplican solas pero el operador debe estar consciente cuando suceden (por si hay un fallback). Se sube a mano.

> **Sobre `PUID`/`PGID` en la imagen oficial**: a diferencia de las imágenes LSIO, la oficial respeta estas variables y *re-chowna* el directorio `/var/syncthing` al iniciar. Como ya creamos los directorios con owner `1000:1000`, el chown es no-op rápido.

### `stacks/syncthing/.env.example`

```bash
# stacks/syncthing/.env.example
# Plantilla para el stack Syncthing. Copiar a `.env` y rellenar.
# Las generales (TZ, PUID, PGID, DOMAIN_LAN, DOMAIN_TS) vienen del .env GLOBAL.

# --- API key para automatización (consultas REST) ---
# Generar con: openssl rand -hex 32
SYNCTHING_API_KEY=CAMBIAR_API_KEY

# Las credenciales de la GUI (usuario/password de auth básica nativa) NO viven
# en este fichero: se configuran desde la propia GUI tras el primer arranque
# (Settings → GUI → Set GUI Authentication User/Password) y se persisten
# cifradas en /mnt/hd2t/apps/syncthing/config/config.xml.
#
# La razón: la imagen oficial no expone STGUIUSER/STGUIPASSWORD como variables
# de bootstrap; la auth básica solo se establece desde la GUI o editando el XML.
# La capa primaria de protección es Authelia (`policy: two_factor`).
```

> **`.env` real, no `.env.example`**: idéntica regla que en el resto del homelab. `stacks/syncthing/.env` no se versiona; `stacks/syncthing/.env.example` sí.

### Drop-in de Caddy: `stacks/caddy/conf.d/08-syncthing.caddy`

```caddy
# /etc/caddy/conf.d/08-syncthing.caddy — bloque LAN para la GUI de Syncthing.
# Documentado en docs/06-almacenamiento/03-syncthing.md.
#
# Solo el plano de control (GUI HTTP) pasa por Caddy. El plano de datos
# (TCP/22000, UDP/22000, UDP/21027) sale directamente al host vía ports:
# del docker-compose.yml. Caddy no interviene ahí.

syncthing.{$DOMAIN_LAN} {
    import lan_tls
    import security_headers
    import healthcheck

    # Authelia 2FA: defensa primaria.
    import authelia_two_factor

    # Syncthing GUI envía CSRF tokens en la cabecera X-CSRF-Token-<ID>;
    # Caddy debe pasarla intacta (lo hace por defecto). El reverse_proxy
    # debe propagar también X-API-Key si el cliente la envía
    # (el dashboard local Syncthing la usa para llamadas internas).

    reverse_proxy http://syncthing:8384 {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
        # Subida y descarga de payloads pequeños; sin tunear timeouts especiales.
    }
}
```

> **Sobre `import authelia_two_factor`**: idéntico patrón que para Prometheus, Grafana, Dozzle (Fase 5). La política se materializa también en `configuration.yml` de Authelia añadiendo:
>
> ```yaml
> access_control:
>   rules:
>     - domain: syncthing.${DOMAIN_LAN}
>       policy: two_factor
>       subject:
>         - "group:admins"
> ```

> **Sobre `host: {host}`**: la GUI de Syncthing valida la cabecera `Host:` y rechaza peticiones con un Host distinto del configurado en `config.xml` (`gui.insecureAllowFrameLoading: false` por defecto). Pasar `Host: syncthing.lan` desde Caddy hace coincidir lo que la GUI espera.

> **Sobre `request_body max_size`**: la GUI no maneja uploads grandes (todo el tráfico real va por TCP/22000). No hace falta `request_body`.

### Crear los directorios persistentes y desplegar

```bash
# 1) Directorios de datos.
sudo install -d -o homelab -g homelab -m 0750 /mnt/hd2t/apps/syncthing
sudo install -d -o homelab -g homelab -m 0750 /mnt/hd2t/apps/syncthing/config
sudo install -d -o homelab -g homelab -m 0750 /mnt/hd2t/sync
sudo install -d -o homelab -g homelab -m 0750 /mnt/hd2t/sync/notes
sudo install -d -o homelab -g homelab -m 0750 /mnt/hd2t/sync/photos
sudo install -d -o homelab -g homelab -m 0750 /mnt/hd2t/sync/documents
sudo install -d -o homelab -g homelab -m 0750 /mnt/hd2t/sync/code-scratch

# 2) Drop-in de Caddy.
install -o homelab -g homelab -m 0644 \
    stacks/caddy/conf.d/08-syncthing.caddy \
    /mnt/hd2t/apps/caddy/etc/conf.d/08-syncthing.caddy

# 3) .env del stack.
cd /home/homelab/homelab
set -a; source .env; set +a

cp stacks/syncthing/.env.example stacks/syncthing/.env
chmod 0600 stacks/syncthing/.env
$EDITOR stacks/syncthing/.env   # generar SYNCTHING_API_KEY con `openssl rand -hex 32`

# 4) Añadir syncthing.${DOMAIN_LAN} con `policy: two_factor` en Authelia
sudo $EDITOR /mnt/hd2t/apps/authelia/config/configuration.yml
docker logs authelia --tail 20 | grep -i 'reloaded'

# 5) Validar el Caddyfile antes de recargarlo.
docker exec caddy caddy validate --config /etc/caddy/Caddyfile

# 6) Levantar el stack.
docker compose \
    -f stacks/syncthing/docker-compose.yml \
    --env-file stacks/syncthing/.env \
    up -d

# 7) Recargar Caddy para tomar el nuevo drop-in.
docker kill --signal=SIGUSR1 caddy

# 8) Esperar a que el contenedor esté healthy.
docker compose -f stacks/syncthing/docker-compose.yml ps
# syncthing   Up 30s (healthy)
```

Logs esperables del primer arranque:

```bash
docker compose -f stacks/syncthing/docker-compose.yml logs --tail 30 syncthing
# ... INFO: My ID: ABCDEF1-...-XYZ7890
# ... INFO: GUI/API listening on 0.0.0.0:8384
# ... INFO: TLS listener (BEP) listening on [::]:22000
# ... INFO: QUIC listener (BEP) listening on [::]:22000
# ... INFO: Local discovery listening on [::]:21027
# ... INFO: Anonymous usage reporting is now disabled
# ... INFO: Loading ignores: ...
```

> **El primer "My ID"**: imprescindible apuntarlo. Es la huella SHA-256 de `cert.pem` y se usa para parear con otros nodos. Se obtiene siempre con:
> ```bash
> docker exec syncthing syncthing cli show system | jq -r .myID
> # ABCDEF1-XXXXXXX-YYYYYYY-ZZZZZZZ-ABCDEFG-HIJKLMN-OPQRSTU-VWXYZ12
> ```

---

## Configuración

### 1) Acceso al portal e inicio de sesión inicial

Desde un cliente de la LAN con la CA interna ya instalada:

```text
1. Abrir https://syncthing.lan/
2. Authelia intercepta: form login → 2FA TOTP. Tras OK, redirige a syncthing.lan.
3. Syncthing GUI pide auth básica nativa.
   - Primera vez: usuario "admin" sin password (default). Establecerlo de inmediato:
     Actions → Settings → GUI → "GUI Authentication User" + "GUI Authentication Password"
     → Save & Restart.
4. Al reiniciar, login con las nuevas credenciales (también pasa Authelia).
```

### 2) Configurar la identidad del nodo y la GUI

| Ajuste | Ubicación en GUI | Valor |
|---|---|---|
| Device name | Actions → Settings → General → Device Name | `homelab-pi` (o el nombre amistoso que se prefiera) |
| Listen Addresses | Actions → Settings → Connections → Sync Protocol Listen Addresses | `default` (Syncthing decide). Si se quiere forzar IPv4: `tcp4://0.0.0.0:22000, quic4://0.0.0.0:22000` |
| Local Discovery | Actions → Settings → Connections | enabled |
| Global Discovery | Actions → Settings → Connections | enabled |
| Enable NAT traversal | Actions → Settings → Connections | enabled (relays globales como fallback) |
| Use HTTPS in GUI | Actions → Settings → GUI | **DISABLED** — Caddy ya termina TLS; doble TLS rompe el reverse proxy. |
| Anonymous usage reporting | Actions → Settings → General | OFF (decisión homelab). |
| Theme | Actions → Settings → GUI | preferencia. |

> **Sobre "Use HTTPS in GUI"**: si se activa por error, Syncthing genera un certificado autofirmado y Caddy se queja con `tls handshake error` al hablarle. Mantener **OFF** para que Caddy → Syncthing vaya por HTTP plano dentro de la red Docker.

### 3) Reglas de exclusión globales

Hay ficheros que **nunca** deben sincronizarse: `.DS_Store`, `Thumbs.db`, `.git/`, `node_modules/`, ficheros temporales. Syncthing tiene reglas globales y por carpeta.

Edición global vía `Actions → Settings → Advanced → Folder defaults → Ignore patterns` (afecta a carpetas nuevas):

```text
// Plantilla por defecto del homelab para carpetas nuevas.
// Cada `.stignore` por carpeta puede heredar esta plantilla con #include defaults.

(?d).DS_Store
(?d).Trashes
(?d)Thumbs.db
(?d)Desktop.ini
(?d).~lock.*
(?d)~$*
.git
.gitignore
.svn
.hg
node_modules
__pycache__
*.tmp
*.swp
*.pyc
```

> **`(?d)` prefix**: indica a Syncthing que el patrón es *deletable* — si lo encuentra puede borrarlo durante una *cleanup*. Sin él, los `.DS_Store` se quedan replicados pero ignorados a futuro.

### 4) Crear la primera carpeta sincronizada

Desde el panel de Syncthing:

```text
1. Add Folder → Folder ID: notes (auto)  Folder Label: Notes
2. Folder Path: /var/syncthing/sync/notes
3. Sharing: (vacío todavía; se añadirán dispositivos al parearlos)
4. File Versioning: Trash Can File Versioning, 14 días
5. Ignore Patterns: heredar defaults + reglas específicas si aplica.
6. Save.
```

| Carpeta | File Versioning recomendado | Justificación |
|---|---|---|
| `notes` | Trash Can, 30 días | Cambios pequeños y frecuentes; recuperación de notas borradas accidentalmente. |
| `photos` | Trash Can, 30 días | Recuperación de fotos borradas en móvil que se replicaron. **No** sustituye a Borg. |
| `documents` | Simple File Versioning, mantener 5 versiones | Se conservan versiones consecutivas tras cambios; útil para Word/Excel. |
| `code-scratch` | None (o Staggered, 1 día / 7 días / 30 días) | Si tiene `.git`, el versioning lo confunde; mejor None. |

> **File Versioning Trashcan**: cuando un nodo borra un fichero, los demás nodos no lo borran del FS, lo mueven a `.stversions/<carpeta>/`. Tras el plazo configurado, Syncthing barre `.stversions/`. Es la mitigación principal del riesgo "Syncthing replica una operación destructiva".

### 5) Parear el primer dispositivo (portátil)

En el portátil:

```bash
# Linux
sudo apt install syncthing
systemctl --user enable --now syncthing
# La GUI escucha en http://127.0.0.1:8384/ por defecto.
# Ir a Actions → Show ID → copiar el Device ID del portátil.
```

En la Pi (panel `syncthing.lan`):

```text
1. Add Remote Device → pegar Device ID del portátil → Name: laptop-XX
2. Sharing: marcar `notes`, `documents`, etc.
3. Save.
```

En el portátil aparecerá un *banner* "New Device" tras unos segundos:

```text
1. Aceptar pareo del nuevo device "homelab-pi".
2. Configurar Folder Path local para `notes` (ej. ~/sync/notes/).
3. Save.
```

A los 30–60 s, los índices se intercambian y la primera sincronización empieza. Si la primera vez tarda mucho en *Discovering*: comprobar que ambos nodos están en la misma LAN o tailnet, o introducir manualmente la dirección de la Pi en el dispositivo remoto:

```text
Edit Device → Addresses → tcp://192.168.1.10:22000, dynamic
```

### 6) Parear un móvil (subida automática de cámara)

Apps recomendadas:

| Plataforma | App | Notas |
|---|---|---|
| Android | **Syncthing** (oficial, F-Droid) o **Syncthing-Fork** (con más opciones de scheduler). | F-Droid garantiza la app sin Google Play Services si se prefiere. |
| iOS | **Möbius Sync** (de pago) | El proyecto Syncthing oficial no tiene app iOS por restricciones de App Store. Möbius implementa el protocolo de forma nativa. |

Procedimiento (Android, ejemplo):

```text
1. Instalar Syncthing-Fork.
2. Abrir → conceder permisos de almacenamiento y ejecución en background.
3. Folders → + → "Camera" → Folder Path: /storage/emulated/0/DCIM/Camera
   → Folder Type: SEND ONLY (el móvil no necesita recibir).
4. Devices → + → escanear QR del Device ID de la Pi (Actions → Show ID en la GUI).
5. Compartir la carpeta "Camera" con el device "homelab-pi".
6. En la Pi: aceptar la nueva carpeta entrante; Folder Path = /var/syncthing/sync/photos/<modelo-móvil>/
   Folder Type: RECEIVE ONLY (la Pi solo recibe; cualquier modificación local se descarta).
7. Trash can 30 días, ignore patterns por defecto.
```

> **Send-only / receive-only**: clave para fotos de cámara. El móvil envía y nunca recibe; la Pi recibe y nunca envía. Si el operador retoca una foto en la Pi por accidente, Syncthing rechaza la modificación local (no la replica al móvil **ni** la deshace localmente; la GUI muestra un *warning* "out of sync" hasta que se reconcilie). Esto evita borrar fotos del móvil desde la Pi por error.

### 7) Operación diaria

| Acción | Comando / Ubicación |
|---|---|
| Estado general | `https://syncthing.lan/` (panel) |
| Ver Device ID de la Pi | `docker exec syncthing syncthing cli show system \| jq -r .myID` |
| Reiniciar el demonio sin perder estado | desde la GUI: Actions → Restart; o `docker compose -f stacks/syncthing/docker-compose.yml restart` |
| Pausar la sincronización temporalmente | GUI → Folder/Device → Pause |
| Listar carpetas | `docker exec syncthing syncthing cli show folders` |
| Ver tráfico actual | GUI → ver gráficas; o `docker exec syncthing syncthing cli show system \| jq .connectionServiceStatus` |
| Inspeccionar `config.xml` | `cat /mnt/hd2t/apps/syncthing/config/config.xml \| less` |
| Buscar conflictos en una carpeta | `find /mnt/hd2t/sync/<folder> -name '*.sync-conflict-*'` |
| Forzar full rescan | GUI → Folder → Rescan; o `docker exec syncthing syncthing cli operations rescan-folder <folderID>` |
| Tail de logs | `docker logs -f syncthing` |
| Tamaño actual de las carpetas | `du -sh /mnt/hd2t/sync/*` |

### 8) Tuning para hardware modesto (Pi 5)

| Parámetro | Default | Recomendado | Por qué |
|---|---|---|---|
| Max Folder Concurrency | 0 (ilimitado) | `2` | Con 2 carpetas escaneando a la vez basta; más sólo satura I/O del USB de hd2t. |
| Folder Rescan Interval | 3600 s (1 h) | `3600` (notes/documents); `21600` (code-scratch); `0` con fsnotify enabled (photos) | Notify es eficiente; rescans periódicos solo son seguridad. |
| Hashers per folder | 0 (auto) | 2 | Pi 5 tiene 4 cores; 2 es buen balance, deja CPU libre para otros stacks. |
| Send-only / Receive-only para `photos` | depende | configurar bien | Ya cubierto; evita borrados accidentales. |

Aplicación: GUI → Folder → Edit → Advanced.

---

## Almacenamiento

| Ruta | Soporte | Owner:Group | Modo | Contenido |
|---|---|---|---|---|
| `/home/homelab/homelab/stacks/syncthing/docker-compose.yml` | microSD | `homelab:homelab` | `0640` | Stack en git. |
| `/home/homelab/homelab/stacks/syncthing/.env.example` | microSD | `homelab:homelab` | `0644` | Plantilla. |
| `/home/homelab/homelab/stacks/syncthing/.env` | microSD | `homelab:homelab` | `0600` | Secretos (`SYNCTHING_API_KEY`). **No** en git. |
| `/home/homelab/homelab/stacks/caddy/conf.d/08-syncthing.caddy` | microSD | `homelab:homelab` | `0644` | Drop-in de Caddy. |
| `/mnt/hd2t/apps/syncthing/config/` | hd2t | `homelab:homelab` | `0750` | Estado interno de Syncthing. |
| `/mnt/hd2t/apps/syncthing/config/cert.pem` | hd2t | `homelab:homelab` | `0600` | **Identidad criptográfica del nodo.** Sin esto, el Device ID cambia y todos los pares hay que repararlos. |
| `/mnt/hd2t/apps/syncthing/config/key.pem` | hd2t | `homelab:homelab` | `0600` | Clave privada del cert. |
| `/mnt/hd2t/apps/syncthing/config/config.xml` | hd2t | `homelab:homelab` | `0600` | Configuración (carpetas, devices, GUI auth, API key). |
| `/mnt/hd2t/apps/syncthing/config/index-v0.14.0.db/` | hd2t | `homelab:homelab` | `0700` | LevelDB con el índice de bloques. Regenerable a alto coste (rescan completo). |
| `/mnt/hd2t/sync/<carpeta>/` | hd2t | `homelab:homelab` | `0750` | Datos sincronizados. |
| `/mnt/hd2t/sync/<carpeta>/.stversions/` | hd2t | `homelab:homelab` | `0750` | Papelera (versioning) de la carpeta. |
| `/mnt/hd2t/sync/<carpeta>/.stignore` | hd2t | `homelab:homelab` | `0640` | Patrones de exclusión específicos por carpeta. |

> **`cert.pem`/`key.pem` son la identidad del nodo**. Si se borran, la Pi pasa a tener un Device ID nuevo y los demás nodos lo verán como un dispositivo desconocido. **Respaldarlos** es prioridad 1 en el plan de backup.

> **`.stversions/` crece**. La papelera retiene los ficheros borrados durante el plazo configurado (14–30 días). Para una carpeta `photos` con 1000 fotos/mes y 30 días de retención puede ocupar 5–20 GiB de overhead. Vigilar con `du -sh /mnt/hd2t/sync/*/.stversions/`.

> **Tamaño esperado del estado**: tras instalación: `config/` ≈ 5 MiB; tras semanas con 4 carpetas y 100k ficheros: `index-v0.14.0.db/` puede crecer a 1–3 GiB. El crecimiento real lo marcan las carpetas de datos.

---

## Backup

A nivel de repositorio (git):

| Artefacto | Estrategia |
|---|---|
| `stacks/syncthing/docker-compose.yml`, `.env.example` | Versionados. |
| `stacks/syncthing/.env` | **NO** versionado (`SYNCTHING_API_KEY`); en `.gitignore`. |
| `stacks/caddy/conf.d/08-syncthing.caddy` | Versionado. |
| Decisiones (imagen oficial, bridge networking, doble auth, raíz `sync/` separada) | Documentadas en este fichero. |

A nivel de datos (Borgmatic, Fase 7):

| Ruta | ¿Se respalda? | Estrategia | Por qué |
|---|---|---|---|
| `/mnt/hd2t/apps/syncthing/config/cert.pem`, `key.pem` | **Sí**. | Diaria, prioridad alta. | Identidad criptográfica del nodo. Si se pierde, todos los pares deben repararse a mano. |
| `/mnt/hd2t/apps/syncthing/config/config.xml` | **Sí**. | Diaria. | Configuración de carpetas y devices. Pequeño y crítico. |
| `/mnt/hd2t/apps/syncthing/config/index-v0.14.0.db/` | **Opcional, semanal**. | Semanal o excluido. | Regenerable con un rescan completo (lento: minutos a horas según volumen). Respaldarlo acelera el restore evitando el rescan. |
| `/mnt/hd2t/sync/<carpeta>/` | **Sí**. | Diaria, **incremental**. | Datos primarios. Una carpeta sincronizada con N nodos también está en los N nodos, pero **un borrado se propaga**: el backup en Borg es el único histórico off-line. |
| `/mnt/hd2t/sync/<carpeta>/.stversions/` | **No** o estrategia separada. | Excluido por defecto. | Si las retenciones de Syncthing y Borg solapan, se duplica historia. La política simple: confiar en Borg como histórico, `.stversions/` como mitigación corta de errores recientes. Excluir reduce el tamaño del repo Borg. |
| `/mnt/hd2t/sync/<carpeta>/*.sync-conflict-*` | **Sí** (vienen incluidos en la carpeta padre). | Diaria. | Los conflictos son resoluciones manuales pendientes; respaldarlos hasta que se resuelvan. |

> **Política específica para Syncthing**: a diferencia de Nextcloud, **no requiere modo mantenimiento ni dump previo**. Los ficheros sincronizados son ficheros normales en el FS y la BD de índices se respalda como un directorio cualquiera (LevelDB tolera *snapshot inconsistencies* aceptablemente; en el peor caso, restore + rescan recompone el índice).
>
> Aún así, para **respaldar `index-v0.14.0.db/` consistente**, el procedimiento canónico es:
>
> ```bash
> # Hook pre-backup (opcional, solo si se respalda el índice).
> docker compose -f stacks/syncthing/docker-compose.yml stop syncthing
> # Borg corre y respalda /mnt/hd2t/apps/syncthing/config/ + /mnt/hd2t/sync/
> # Hook post-backup
> docker compose -f stacks/syncthing/docker-compose.yml start syncthing
> ```
>
> El downtime es <30 s. **Si se decide no respaldar el índice** (recomendación por defecto: regenerable), no hace falta parar el contenedor: las carpetas `sync/` se respaldan en caliente sin riesgo.

> **Política de retención**: la decisión vive en `07-backups/01-estrategia-backup.md`. Recomendación de partida para Syncthing: 7 daily, 4 weekly, 6 monthly.

Procedimiento de restore (pérdida del contenedor, datos intactos en `hd2t`):

```bash
docker compose -f stacks/syncthing/docker-compose.yml up -d --force-recreate
# Syncthing reusa /mnt/hd2t/apps/syncthing/config; Device ID se mantiene.
# Tras ~30 s de healthcheck, los pares se reconectan automáticamente.
```

Procedimiento de restore tras pérdida total (reflasheo + restauración Borg):

1. Recrear Fases 1, 2, 3 y 4.
2. Restaurar `/mnt/hd2t/apps/syncthing/config/` (imprescindible: `cert.pem`, `key.pem`, `config.xml`) y `/mnt/hd2t/sync/` desde Borg.
3. Verificar permisos: `chown -R 1000:1000 /mnt/hd2t/apps/syncthing /mnt/hd2t/sync`.
4. Levantar el stack: `docker compose -f stacks/syncthing/docker-compose.yml up -d`.
5. Confirmar Device ID inalterado: `docker exec syncthing syncthing cli show system | jq -r .myID` → mismo que antes.
6. Si no se restauró `index-v0.14.0.db/`: cada carpeta hace un *initial scan* (puede tardar minutos a horas según tamaño). No es un error.
7. Los pares remotos se reconectan automáticamente al reconocer el Device ID.

Si por error se pierde `cert.pem`/`key.pem`:

```text
1. El nodo arranca con un Device ID NUEVO (reportado en logs).
2. En cada par remoto: Edit Device del antiguo → cambiar el ID por el nuevo, o
   Remove + Add con el nuevo ID. Reaceptar las carpetas.
3. Las carpetas SE REVALIDAN BIT A BIT contra el nuevo nodo: tráfico equivalente a
   una primera sincronización completa por carpeta. Coste alto en datos móviles.
   Es el incentivo principal para tener `cert.pem` en el plan de backup.
```

---

## Errores frecuentes y troubleshooting

| Síntoma | Causa probable | Resolución |
|---|---|---|
| GUI no carga (error 502 desde Caddy) | Syncthing aún arrancando, o `STGUIADDRESS` no apunta a `0.0.0.0`. | `docker logs syncthing`; esperar healthy; comprobar la variable. |
| GUI carga pero pide login básico antes de Authelia | Authelia no tiene la regla `policy: two_factor` para `syncthing.lan`. | Editar `configuration.yml`, recargar Authelia, reintentar. |
| Tras Authelia, la GUI dice "Forbidden" | El header `Host:` no llega como `syncthing.lan`. | Comprobar `header_up Host {host}` en el bloque Caddy. |
| Dispositivo remoto no se conecta nunca | Discovery global bloqueado o NAT muy restrictivo. | Forzar dirección directa: en el dispositivo remoto, `Edit Device → Addresses → tcp://<IP-pi>:22000, dynamic`. Verificar UFW permite TCP/22000 desde la red del cliente. |
| Sincroniza muy lento entre dos nodos en LAN | Está pasando por relay global en lugar de directo. | GUI → Connections → ver "Relayed via ..."; si aparece, el firewall del cliente bloquea el directo. Abrir TCP/22000 en el cliente. |
| Local Discovery no funciona | UDP/21027 no llega por el bridge Docker. | Pegar manualmente la IP de la Pi en el peer (`tcp://192.168.1.10:22000`); o cambiar a `network_mode: host` (no recomendado). |
| Conflictos `.sync-conflict-XXXXXXXX-XXXXXX-NODEID.ext` proliferando | Dos nodos modificaron el mismo fichero antes de sincronizar. | Resolver a mano: comparar con `diff`, decidir cuál se queda; borrar el otro `.sync-conflict-*`. |
| Carpeta `photos` rechaza cambios locales y queda "out of sync" | La carpeta es `Receive Only` y algo modificó ficheros en la Pi. | GUI → Folder → Override Changes (descarta cambios locales y vuelve a la versión del send-only) o, si los cambios eran intencionales, cambiar el tipo de carpeta. |
| `index-v0.14.0.db/` corrupto tras `kill -9` | LevelDB sin commit. | Parar contenedor, borrar `index-v0.14.0.db/`, arrancar; Syncthing regenera el índice (rescan completo). Las carpetas `sync/` no se ven afectadas. |
| Subida desde móvil tarda en arrancar | El móvil entró en *doze mode* / *battery optimization*. | En Android: dar a Syncthing-Fork "ignorar optimización de batería"; conectar a corriente. |
| Telemetría reaparece tras un reinicio | El operador clicó "Yes" en el banner de "send anonymous usage data". | GUI → Settings → "Send anonymous usage data" → No. La variable `STNOUPGRADE` no afecta al usage report; es otra opción. |
| `403 Forbidden` al consumir la API REST con la API key | El *header* `X-API-Key` no se está enviando, o la key cambió. | `curl -H "X-API-Key: $SYNCTHING_API_KEY" https://syncthing.lan/rest/system/ping` (con la CA instalada y tras Authelia mediante token). |
| Cert.pem corrupto (binario reportando "tls: bad certificate") | Edición manual o copia incompleta. | Restaurar desde Borg el último `cert.pem`/`key.pem`; el Device ID permanece. |
| Los puertos `22000`/`21027` no escuchan en el host | `ufw` los bloquea o `ports:` mal escrito. | `sudo ss -tlnp \| grep 22000`; revisar `docker compose ps` y `ufw status`. |
| `STNOUPGRADE` no impide upgrade | La variable se respeta solo si `config.xml` no fija `autoUpgradeIntervalH`. | Editar `config.xml` (`<options><autoUpgradeIntervalH>0</autoUpgradeIntervalH></options>`) o Settings → Auto Upgrades = Off. |
| La carpeta `notes` aparece "stopped" | Un peer marcó la carpeta como *paused* o `.stignore` con error de sintaxis. | GUI → Folder → Edit → Ignore Patterns → comprobar líneas; si todo correcto: Resume. |

---

## Decisiones que **no** se toman en este documento

- **Syncthing como Active Backup**. Se documenta el versioning como mitigación de cortos plazos; el backup real lo hace Borg/Borgmatic en Fase 7.
- **Discovery server (`stdiscosrv`) y Relay server (`strelaysrv`) propios**. Sobreingeniería para 1 operador con <10 nodos.
- **`type = receiveencrypted`** para nodos no-confiables. Reabrible si en el futuro se replica a un VPS rentado o un disco enviado a casa de un familiar.
- **OIDC para la GUI**. Syncthing no lo soporta nativamente; reabrible si el upstream lo añade.
- **Compartir carpetas con familiares**. Vía Nextcloud, no aquí.
- **Sincronizar `hd5t/stash/library`**. Inviable por tamaño y porque la biblioteca la gestiona Stash.
- **`fsnotify` para todas las carpetas con `Folder Watcher`**. Activado por defecto en versiones modernas de Syncthing; en carpetas enormes (>100k ficheros) puede saturar inotify del kernel. Reabrible si aparece el síntoma `inotify watches exhausted`: subir `fs.inotify.max_user_watches` en sysctl.
- **`fail2ban` para la GUI**. Authelia ya rate-limitea logins; doblar con fail2ban es redundante.
- **GUI publicada vía Tailscale Funnel a internet**. Fuera del alcance del homelab (no exposición a internet).
- **`autoAcceptFolders` en devices**. Discutido: simplifica pareo pero **acepta cualquier carpeta** que el peer empuje. Si un peer comprometido empuja una carpeta gigante, llena el disco. Política aquí: aceptar carpetas siempre **manualmente**.
- **API key compartida con scripts externos**. Reabrible cuando se documente un job de monitorización en Fase 5b o 9 que consulte el estado vía API.

---

## Verificación Final

Antes de pasar a `04-minio.md`:

| Comprobación | Comando | Resultado esperado |
|---|---|---|
| Stack desplegado y saludable | `docker compose -f stacks/syncthing/docker-compose.yml ps` | `syncthing Up (healthy)` |
| Imagen correcta y pinneada | `docker inspect syncthing --format '{{.Config.Image}}'` | `syncthing/syncthing:1.30` |
| Conectado a `homelab` | `docker network inspect homelab --format '{{range .Containers}}{{.Name}} {{end}}'` | incluye `syncthing` y `caddy` |
| Solo `:22000/tcp+udp` y `:21027/udp` publicados al host | `sudo ss -tlnp \| grep ':22000'; sudo ss -ulnp \| grep -E ':(22000\|21027)'` | tres líneas; la GUI (`:8384`) NO aparece |
| `syncthing.lan` resuelve al IP de la Pi | `dig +short syncthing.lan @192.168.1.2` | `192.168.1.10` |
| Caddy sirve `syncthing.lan` con cert de la CA interna | `echo \| openssl s_client -connect syncthing.lan:443 -servername syncthing.lan 2>/dev/null \| openssl x509 -noout -issuer` | `issuer=CN=Homelab Internal CA` |
| Authelia exige 2FA en `syncthing.lan` | `curl -ksI https://syncthing.lan/` | `HTTP/2 302` con `Location: https://auth.lan/?rd=...` |
| `/rest/noauth/health` responde OK desde el contenedor | `docker exec syncthing wget -qO- http://127.0.0.1:8384/rest/noauth/health` | JSON `{"status":"OK"}` |
| Device ID estable entre reinicios | `docker exec syncthing syncthing cli show system \| jq -r .myID` antes y después de `restart` | mismo string |
| `cert.pem` con permisos `0600` y owner `homelab` | `stat -c '%a %u:%g' /mnt/hd2t/apps/syncthing/config/cert.pem` | `600 1000:1000` |
| `STNOUPGRADE=true` activo | `docker exec syncthing env \| grep STNOUPGRADE` | `STNOUPGRADE=true` |
| Anonymous usage reporting OFF | `docker exec syncthing grep -i urAccepted /var/syncthing/config/config.xml` | `urAccepted="-1"` |
| Local Discovery escuchando | `docker logs syncthing 2>&1 \| grep -i 'Local discovery'` | línea `Local discovery listening on [::]:21027` |
| TLS listener BEP escuchando | `docker logs syncthing 2>&1 \| grep -iE 'TLS listener|QUIC listener'` | dos líneas en `[::]:22000` |
| Carpetas iniciales creadas y owner correcto | `stat -c '%u:%g' /mnt/hd2t/sync/notes /mnt/hd2t/sync/photos /mnt/hd2t/sync/documents /mnt/hd2t/sync/code-scratch` | `1000:1000` para todas |
| Auth básica nativa configurada | `grep -E 'user\|password' /mnt/hd2t/apps/syncthing/config/config.xml` | usuario y hash bcrypt presentes |
| `.gitignore` ignora `stacks/syncthing/.env` | `git check-ignore stacks/syncthing/.env` | imprime el path (excluido) |
| `ufw` permite `:22000/tcp+udp` y `:21027/udp` desde LAN | `sudo ufw status \| grep -E '22000\|21027'` | reglas con `192.168.1.0/24 ... ALLOW IN` |
| Pareo con un nodo de prueba sincroniza una carpeta | desde portátil: `Add Device` con el ID de la Pi → aceptar `notes` → ficheros aparecen en `/mnt/hd2t/sync/notes/` | `du -sh /mnt/hd2t/sync/notes` cambia |
| Persistencia tras reboot | `sudo reboot`; al volver: `docker ps --filter name=syncthing` | `Up ... (healthy)`; el Device ID **no** ha cambiado |
| Stack en git | `git ls-files stacks/syncthing` | `docker-compose.yml`, `.env.example` tracked; `.env` **no** tracked |

Cumplido el último punto, el homelab tiene su servicio de sincronización P2P operativo: el operador puede mantener carpetas idénticas entre la Pi (siempre encendida), portátil, sobremesa y móviles, con cifrado en tránsito por defecto, papelera por carpeta y un punto de control web protegido con doble auth. La siguiente puerta es **almacenamiento de objetos S3-compatible** para que servicios futuros (MinIO como destino de Borgmatic, exportaciones de aplicaciones, snapshots de configuraciones) tengan un backend nativo: `04-minio.md`.

---

## Referencias

- [Documento previo: `docs/06-almacenamiento/02-samba.md`](./02-samba.md)
- [Documento siguiente: `docs/06-almacenamiento/04-minio.md`](./04-minio.md)
- [Documento relacionado: `docs/06-almacenamiento/01-nextcloud.md`](./01-nextcloud.md)
- [Documento relacionado: `docs/03-red/04-caddy.md`](../03-red/04-caddy.md)
- [Documento relacionado: `docs/04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md)
- [Documento relacionado: `docs/02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md)
- [Documento relacionado: `docs/07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md)
- [Syncthing — Documentación oficial](https://docs.syncthing.net/)
- [Syncthing — Imagen Docker oficial](https://hub.docker.com/r/syncthing/syncthing)
- [Syncthing — Configuración y opciones avanzadas](https://docs.syncthing.net/users/config.html)
- [Syncthing — Block Exchange Protocol (BEP) v1](https://docs.syncthing.net/specs/bep-v1.html)
- [Syncthing — File Versioning](https://docs.syncthing.net/users/versioning.html)
- [Syncthing — Ignore Patterns](https://docs.syncthing.net/users/ignoring.html)
- [Syncthing — REST API](https://docs.syncthing.net/dev/rest.html)
- [Syncthing — FAQ sobre seguridad y privacidad](https://docs.syncthing.net/users/security.html)
- [Syncthing-Fork — App Android (F-Droid)](https://f-droid.org/packages/com.github.catfriend1.syncthingandroid/)
- [Möbius Sync — Cliente iOS](https://mobiussync.com/)
