# Transmission

## Descripción

Despliegue de **Transmission** ([imagen `lscr.io/linuxserver/transmission`](https://docs.linuxserver.io/images/docker-transmission/)) como **cliente BitTorrent** del homelab. Es la primera pieza de la **Fase 10 — Gestión de Descargas**: descarga torrents (`.torrent` y `magnet:`) y entrega los ficheros completos a `/mnt/hd2t/downloads/complete/`, donde **Sonarr** ([`./03-sonarr.md`](./03-sonarr.md)) y **Radarr** ([`./04-radarr.md`](./04-radarr.md)) los recogen, los renombran y los importan a `/mnt/hd2t/media/{tv,movies}/`. Los indexadores los aporta **Prowlarr** ([`./02-prowlarr.md`](./02-prowlarr.md)). Transmission **no busca contenido** por sí mismo; es solo el motor de descarga.

Este doc cubre, en orden:

1. **Por qué Transmission** y no qBittorrent / Deluge / rTorrent, qué se asume y qué se descarta.
2. **Plan de variables y archivos**: `.env.example` versionable, `.env` real con credenciales en `/mnt/hd2t/services/transmission/.env` (chmod 600), layout de directorios bajo `/mnt/hd2t/services/transmission/` y `/mnt/hd2t/downloads/`.
3. **Estructura de descargas**: `/mnt/hd2t/downloads/{incomplete,complete,watch}/` ya creada en [`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) §3 y §6, con grupo `media` (GID 1100) y `setgid` para que Sonarr/Radarr puedan moverlas sin `chgrp`.
4. **`docker-compose.yml`** con bind mounts de `/config` (respaldable), `/downloads` (apuntando a `/mnt/hd2t/downloads/`), `/watch` (auto-add de `.torrent`/`magnet:`), publicación **excepcional** del puerto de peers `51413/tcp+udp` (los puertos web 9091 **no** se publican — Caddy los alcanza por la red `homelab`).
5. **Despliegue, onboarding inicial** (RPC user/password, ajustes de velocidad y peers desde la UI o `settings.json`).
6. **Integración con Caddy** ([`../03-red/04-caddy.md`](../03-red/04-caddy.md) §4.3): bloque `transmission.{$LAN_DOMAIN}` con `forward_auth` a Authelia (placeholder ya reservado en [`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md) §4 — política `two_factor`, `group:admin`).
7. **Protección**: la UI de Transmission **lleva Authelia delante por defecto** (a diferencia de Jellyfin/Navidrome). Se justifica en §6.5: Transmission solo lo usa el operador, no clientes nativos; la auth nativa RPC es débil (HTTP Basic, sin 2FA, sin lockout).
8. **Configuración del proceso**: límites de velocidad razonables para una conexión doméstica (4 MB/s up para no saturar la línea), límite global de torrents activos (`peer-limit-global`, `download-queue-size`), **deshabilitar DHT/PEX/LSD** en torrents privados (gestionado por torrent), **port forwarding manual** (`peer-port: 51413`, `peer-port-random-on-start: false`), `rpc-whitelist` y `rpc-host-whitelist` en concordancia con la red `homelab`.
9. **Backup**: solo `config/` (`settings.json`, `dht.dat`, `resume/`, `torrents/`, `blocklists/`); `/mnt/hd2t/downloads/incomplete/` queda **excluido** según [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §13.6.
10. **Operaciones cotidianas**: añadir torrents desde la UI o copiando a `watch/`, ratio limit y seeding policy, blocklists (PeerBlock-style), inspección de estado de cada torrent, `transmission-remote` desde el host, gestión cuando la queue se atasca.
11. **Variantes opt-in**: enrutar **todo** el tráfico de Transmission a través de un túnel Wireguard (gluetun, [`__variantes opt-in__`](#12-variantes-opt-in)) o de Tailscale Exit Node, integración con Telegram para notificaciones, `transmission-rss` para auto-add desde feeds, configurar UPnP/NAT-PMP (no recomendado en homelab con IP única).

> **Alcance de red**: la **UI web** (9091) **solo se accede vía Caddy** sobre `https://transmission.lan` (LAN) o `https://transmission.${TS_DOMAIN}` (Tailscale). El **puerto de peers** (`51413/tcp+udp`) **sí se publica al host** y al router LAN: BitTorrent es P2P y necesita conexiones entrantes para funcionar bien (sin port forwarding entrante el ratio cae y muchos trackers privados penalizan). Eso es legal y consistente con la regla del homelab: el router del operador hace **port forwarding** sólo de `51413/tcp+udp` → Pi:51413 (no hay otros puertos abiertos hacia internet). Si el operador quiere **cero exposición a internet**, ver §12.1 (Wireguard out via gluetun).

---

## Requisitos Previos

- **Sistema base operativo** según Fase 1: usuario `homelab` (UID 1000), grupo `media` (GID 1100) con `homelab` como miembro, `/mnt/hd2t/` montado, estructura `/mnt/hd2t/downloads/{incomplete,complete,watch}/` creada con `homelab:media 2775` ([`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) §3 y §6).
- **Docker + red `homelab`** según Fase 2: red bridge `homelab` creada, convenciones de Compose ([`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §3.5 — bind mounts; §4.3 — red compartida; §5.2 — `PGID=1100` para acceso al grupo `media`).
- **Caddy desplegado** ([`../03-red/04-caddy.md`](../03-red/04-caddy.md)) con `lan_internal_tls` operativo y la red `homelab` accesible. Sin Caddy no hay HTTPS para la UI de Transmission y el `forward_auth` de Authelia no aplica.
- **Pi-hole desplegado** ([`../03-red/02-pihole.md`](../03-red/02-pihole.md)) con la posibilidad de añadir registros A locales (`transmission.lan` → IP de la Pi).
- **Authelia desplegado** ([`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md)) con el dominio `transmission.{$LAN_DOMAIN}` registrado en `access_control.rules` (política `two_factor`, `subject: group:admin`). En el `Caddyfile` el bloque de Transmission usa `forward_auth http://authelia:9091`.
- **Watchtower desplegado** ([`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md)). Transmission lleva la etiqueta `com.centurylinklabs.watchtower.enable: "true"` por política — la imagen LSIO publica `nightly`/`latest` con cambios menores y la BD de Transmission (en `~/.config/transmission-daemon/` ≡ `/config/`) es **forward-compatible** entre versiones (un downgrade desde `4.x` a `3.x` rompe `resume/*`, pero un upgrade siempre funciona).
- **Borgmatic operativo** ([`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md)) para que `/mnt/hd2t/services/transmission/config/` sea archivado y `/mnt/hd2t/downloads/incomplete/` quede **excluido** según las reglas de §13.6 de ese doc.
- **Router con port forwarding configurado** para `51413/tcp` y `51413/udp` → IP fija de la Pi en la LAN (la asignación estática se documenta en [`../13-operaciones/04-red-y-puertos.md`](../13-operaciones/04-red-y-puertos.md)). **Es la única regla de port forwarding** del homelab. Sin ella, Transmission queda en modo "outbound only" y muchos trackers (sobre todo privados) marcarán al peer como mal conectado. Si el operador no puede o no quiere abrir ese puerto en su router, ver §12.1.
- **Disco hd2t libre**: ≥ 100 GB para `/mnt/hd2t/downloads/` (depende del operador y del *seeding ratio* que mantenga; los `.torrent` activos rara vez superan 50 MB). Para `/mnt/hd2t/services/transmission/`: ~10 MB de `settings.json` + ~1–10 MB de `resume/` + `torrents/` por torrent activo + blocklists ~30 MB descomprimidas.

### Decisiones de diseño asumidas

| Decisión | Valor por defecto | Justificación |
|---|---|---|
| Cliente BitTorrent | **Transmission** (FOSS, GPL/MIT mixto) | qBittorrent es excelente pero la UI web (`qbittorrent-nox`) y la API son menos estables entre versiones; Deluge tiene daemon + `deluge-web` separados (más piezas que mantener); rTorrent + ruTorrent es la opción "ninja" con curva de aprendizaje alta. Transmission es el cliente de referencia, con API RPC documentada que Sonarr/Radarr/Prowlarr soportan en su primera categoría de "download client". |
| Imagen | **`lscr.io/linuxserver/transmission`** | LSIO mantiene la imagen mejor que la "oficial" (que es informalmente `linuxserver/transmission` redistribuida). Soporta `PUID/PGID` para que el contenedor escriba en `/mnt/hd2t/downloads/` con `homelab:media` y los ficheros sean accesibles a Sonarr/Radarr sin `chgrp` posterior. Tiene healthcheck integrado y fija `transmission-daemon 4.x`. |
| Tag de imagen | **`4.0.6-r0-ls283`** (no `latest`, no `4.0`) | LSIO publica tags semánticos `<upstream>-<lsio_revision>`. Pinear el patch fuerza al operador a leer https://github.com/linuxserver/docker-transmission/releases antes de actualizar. Watchtower está habilitado pero respeta el tag fijo (compara digest del mismo tag, ver [`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §3). |
| Arquitectura | `linux/arm64` (Pi 5) | Manifest multi-arch oficial. La Pi 5 es nativa 64-bit. |
| Red Docker | **`homelab`** (bridge, [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §4.3). Solo `51413/tcp+udp` publicado al host. **Sin** `9091` publicado. | Caddy llega a la UI por nombre (`http://transmission:9091`). El peer port `51413` se publica con `mode: host` para preservar la IP del peer real (necesario para el ratio y para el log de Transmission). |
| Modelo de almacenamiento | **Bind mount** `/mnt/hd2t/services/transmission/config:/config` + **Bind mount** `/mnt/hd2t/downloads:/downloads` (RW) + Bind mount `/mnt/hd2t/downloads/watch:/watch` (RW) | Patrón estándar del homelab. La separación `config` / `downloads` permite hacer backup solo de `config/` y excluir `incomplete/` del resto en Borgmatic ([`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §13.6). El `watch/` se monta para auto-add: cualquier `.torrent` que el operador deposite ahí (vía Samba — [`../06-almacenamiento/02-samba.md`](../06-almacenamiento/02-samba.md) share `[downloads]`) lo carga Transmission y lo elimina del `watch/` al añadirlo. |
| Bibliotecas finales | **No se montan** | Transmission **no escribe** en `/mnt/hd2t/media/`. Su trabajo termina en `/mnt/hd2t/downloads/complete/`. Sonarr/Radarr son los **únicos** servicios que mueven de `complete/` a `media/`. Esto es coherente con [`../09-multimedia/01-jellyfin.md`](../09-multimedia/01-jellyfin.md) §1 (bibliotecas RO desde la perspectiva de Jellyfin). |
| Usuario dentro del contenedor | **`PUID=1000` (homelab) + `PGID=1100` (media)** vía las variables que respeta LSIO | Coherente con [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §5.2. El proceso `transmission-daemon` corre como `homelab:media`; los ficheros descargados heredan grupo `media` por el bit `setgid` puesto en `/mnt/hd2t/downloads/`. Sonarr/Radarr (también con `PGID=1100`) los pueden mover. |
| Auth de la UI | **Authelia delante** (Caddy `forward_auth`) | Justificación en §6.5. La auth nativa RPC de Transmission es HTTP Basic con MD5+SHA1 (no PBKDF2), sin lockout y sin 2FA. Authelia añade SSO + 2FA TOTP delante de Transmission **sin** romper Sonarr/Radarr/Prowlarr (que entran a `http://transmission:9091/transmission/rpc` por la red interna `homelab`, **no** pasan por Caddy ni por Authelia). |
| `rpc-username` / `rpc-password` | **Activados**, password inicial vía `.env` | Defensa en profundidad: aunque Authelia esté delante, alguien con acceso a la red `homelab` desde otro contenedor también podría hablar con `http://transmission:9091`. Las credenciales RPC obligan a Sonarr/Radarr/Prowlarr a autenticarse (lo soportan nativamente). |
| `rpc-whitelist-enabled` | `true`, `rpc-whitelist: 127.0.0.1,172.20.*.*` | Solo el rango de la red Docker `homelab` y `localhost` pueden hablar con la API RPC. Sin esto, una conexión externa que llegara al puerto 9091 sería rechazada por IP. |
| `rpc-host-whitelist-enabled` | `true`, `rpc-host-whitelist: transmission.lan,transmission` | Bloquea ataques DNS rebinding (un atacante en la LAN podría servir `evil.com` apuntando a la Pi). Solo el `Host:` header `transmission.lan` (proxy externo) o `transmission` (interno por nombre Docker) son aceptados. |
| `peer-port` | **`51413` fijo** (`peer-port-random-on-start: false`) | Port forwarding del router solo redirige un puerto fijo. Random rompería la conectividad externa cada reinicio. |
| `peer-port-random` | `false` | Idem. |
| `port-forwarding-enabled` | `false` | Esta opción es **UPnP/NAT-PMP** del cliente, **no** "abrir el puerto en el router". El homelab abre el puerto manualmente y desactiva UPnP por seguridad (el router puede tener UPnP deshabilitado, lo cual es el default seguro). |
| Velocidades por defecto | **DL: ilimitado, UL: 4096 KB/s (4 MB/s)** | Conexión doméstica simétrica de 600/600 Mbps deja margen para Jellyfin streaming + videollamadas + descarga sin saturar. Ajustar al operador. Los **alt-speeds** se programan 23:00 → 06:00 para no comer ancho de banda nocturno. |
| `peer-limit-global` | `200` | Default LSIO. Sube a `500` si el operador tiene muchos torrents simultáneos. |
| `peer-limit-per-torrent` | `50` | Default LSIO. |
| `download-queue-size` | `5` | Solo 5 torrents activos descargando a la vez; los demás esperan en cola. Evita fragmentar I/O del HDD `hd2t` (ext4 con seek pesado). |
| `seed-queue-enabled` | `true`, `seed-queue-size: 10` | Idem para seeding: limitar el número de torrents seeders activos. |
| `incomplete-dir-enabled` | **`true`**, `incomplete-dir: /downloads/incomplete` | Separa descargas a medias de finalizadas. Sonarr/Radarr **solo importan de `complete/`** (lo configuran en su "Remote Path Mapping"). |
| `download-dir` | `/downloads/complete` | Cuando un torrent llega al 100%, Transmission mueve el fichero atómicamente desde `incomplete/` (mismo filesystem). |
| `watch-dir` | `/watch` (apunta a `/mnt/hd2t/downloads/watch/`), `watch-dir-enabled: true` | Auto-add: `cp foo.torrent /mnt/hd2t/downloads/watch/` desde Samba o `scp` y se añade automáticamente. |
| `trash-original-torrent-files` | `true` | Tras añadir el `.torrent` desde `watch/`, se elimina el fichero. Si está en `false`, hay que limpiarlo a mano cada vez. |
| `umask` | `002` (vía `UMASK=002` en el env de LSIO) | Fichero nuevo `0664`, directorio nuevo `0775`. Combinado con `setgid` en `/mnt/hd2t/downloads/`, los ficheros quedan `homelab:media 0664` — **leíbles y escribibles** por Sonarr/Radarr. |
| Blocklists | **PeerBlock estándar** (Level1) en `https://github.com/Naunter/BT_BlockLists/raw/master/bt_blocklists.gz` | Bloquea IPs de monitorización conocida. No es perfecto pero reduce ruido. Se actualiza solo cada 24h por Transmission. |
| Backup | **Solo `/config`** vía Borgmatic | El resto se regenera o no se respalda. Política en [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §13.6. Los `.torrent` activos viven en `/config/torrents/` y los `resume/` permiten retomar exactamente donde estaba. |
| Watchtower | **`com.centurylinklabs.watchtower.enable: "true"`** | Por política ([`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §4.2): la imagen LSIO de Transmission es de bajo riesgo (Transmission 4.x es estable, schema de `resume/` no cambia). En la práctica el upgrade significa replazar el binario y reiniciar. Si LSIO publicara un nightly defectuoso, el `restart: unless-stopped` lo reiniciaría sin éxito y Uptime Kuma alertaría — el riesgo es asumible. |
| Reverse proxy | **Caddy con `forward_auth` a Authelia** | Doble capa: TLS interno + SSO/2FA. La API RPC para Sonarr/Radarr **no pasa por Caddy** sino por la red interna (`http://transmission:9091/transmission/rpc`); por tanto Authelia no estorba a la integración del *arr stack. |
| Acceso remoto | **Vía Tailscale** ([`../03-red/05-tailscale.md`](../03-red/05-tailscale.md)) — `transmission.${TS_DOMAIN}` con `tls /data/tailscale-certs/transmission.crt /data/tailscale-certs/transmission.key` | Sin port forwarding HTTP ni DDNS para la UI. El único port forward del router es para el **peer port** (no para HTTPS). |

---

## 1. Resumen de la arquitectura

```
                ┌──────────────── Internet ─────────────────┐
                │                                           │
                │  ◄── peers (TCP+UDP) :51413               │
                │                                           │
                └─────────────────┬─────────────────────────┘
                                  │
                          (router: port forward
                           51413/tcp+udp → Pi)
                                  │
                                  ▼
                  ┌─────────────────────────────────┐
                  │   Pi 5 (host)  192.168.1.x      │
                  │   :51413/tcp+udp ─── peers ───► │
                  └────────────────┬────────────────┘
                                   │
                                   ▼ docker network: homelab (172.20.0.0/24)
                  ┌────────────────────────────────────┐
                  │           Transmission             │
                  │   (este doc, :9091 + :51413)       │
                  │                                    │
                  │  /config       (RW)  ─► /mnt/hd2t/services/transmission/config/
                  │  /downloads    (RW)  ─► /mnt/hd2t/downloads/
                  │  /watch        (RW)  ─► /mnt/hd2t/downloads/watch/
                  └────┬───────────────┬───────────────┘
                       │               │
                       │ http://       │ /mnt/hd2t/downloads/
                       │ transmission: │     {incomplete,complete}/
                       │   9091/       │
                       ▼               ▼
              ┌──────────────┐    ┌────────────────────┐
              │    Caddy     │    │  Sonarr / Radarr   │
              │ transmission │    │  importan desde    │
              │     .lan     │    │  complete/ y mueven│
              │      ▲       │    │  a media/{tv,movies}/
              │      │       │    └────────────────────┘
              │  forward_auth│
              │      │       │
              │      ▼       │
              │   Authelia   │   (../04-seguridad/01-authelia.md)
              └──────────────┘

  Operador (web)              Sonarr/Radarr/Prowlarr
  ─► https://transmission.lan  ─► http://transmission:9091/transmission/rpc
     [Authelia OTP]               [HTTP Basic con rpc-username/rpc-password]
```

Lo crítico de este diagrama:

1. **Dos vías de entrada distintas, dos auths distintas.** La **UI humana** entra por Caddy, y Authelia se interpone con cookie SSO + 2FA TOTP. La **API RPC** que usan Sonarr/Radarr/Prowlarr entra por la red interna `homelab` directamente al puerto `9091` del contenedor — Caddy no la ve, Authelia no la ve. Su credencial es la HTTP Basic `rpc-username:rpc-password` definida en `settings.json`. Esto **no** es un atajo: es la única forma de que las apps de back-end se autentiquen sin OTP.
2. **Peer port en `host` mode.** El `51413/tcp+udp` se publica con `mode: host` para que Transmission vea la IP real del peer remoto. Sin `mode: host`, todos los peers aparecen como la IP del bridge Docker (`172.20.0.1`) y el ratio + el log son inútiles. Es la única excepción al patrón "no `ports:`" del homelab.
3. **Port forwarding del router.** Solo `51413/tcp+udp` → IP fija de la Pi. Es el **único** puerto abierto hacia internet en todo el homelab. Lo registra [`../13-operaciones/04-red-y-puertos.md`](../13-operaciones/04-red-y-puertos.md).
4. **Sonarr/Radarr no escriben en `complete/`.** Solo *leen* de `complete/` y *escriben* en `media/`. Transmission mantiene los torrents en `complete/` para hacer seeding hasta que el operador (o una rule de retention) los borre. Por tanto **el mismo fichero coexiste en dos sitios** durante un tiempo: como hardlink no es posible entre `complete/` y `media/` (mismo FS sí, pero Sonarr lo gestiona como copia o move según la regla "Use Hardlinks instead of Copy"). Recomendación: activar hardlinks en Sonarr/Radarr ([`./03-sonarr.md`](./03-sonarr.md), [`./04-radarr.md`](./04-radarr.md)) para no duplicar espacio.
5. **Sin UPnP, sin NAT-PMP.** El `port-forwarding-enabled: false` de Transmission no tiene nada que ver con el firewall del router. Solo dice "no intentes abrir el puerto vía UPnP". El forward del router se hace **a mano** y se documenta. Esto es seguro: UPnP es un vector de ataque conocido (https://en.wikipedia.org/wiki/Universal_Plug_and_Play#Security_concerns).

---

## 2. Plan de variables y archivos

### 2.1. Variables del stack (`.env.example` versionable)

`~/homelab/stacks/transmission/.env.example`:

```env
# ~/homelab/stacks/transmission/.env.example
# Versión control: ~/homelab/stacks/transmission/.env.example
# Valores reales en /mnt/hd2t/services/transmission/.env (chmod 600).
# Las credenciales RPC viven aquí porque las usan Sonarr/Radarr/Prowlarr.

# --- Comunes del homelab ---
HOMELAB_USER=homelab
HOMELAB_UID=1000
HOMELAB_GID=1000
MEDIA_GID=1100
TZ=Europe/Madrid

# --- Dominios internos (consistentes con dns/.env y proxy/.env) ---
LAN_DOMAIN=lan
TS_DOMAIN=tailnet.ts.net

# --- Transmission ---
# https://github.com/linuxserver/docker-transmission/releases
# Lista de cambios upstream: https://github.com/transmission/transmission/releases
TRANSMISSION_IMAGE_TAG=4.0.6-r0-ls283

# Hostname público (sin esquema). Usado en Caddyfile y rpc-host-whitelist.
TRANSMISSION_HOSTNAME=transmission
TRANSMISSION_LAN_HOST=transmission.lan
TRANSMISSION_TS_HOST=transmission.tailnet.ts.net

# Credenciales RPC (HTTP Basic interna). Las consume Sonarr/Radarr/Prowlarr.
# El password se almacena en settings.json en SHA1 — Transmission lo
# rota automáticamente al primer arranque.
TRANSMISSION_RPC_USERNAME=arr
TRANSMISSION_RPC_PASSWORD=__cambiar_por_password_largo__

# Peer port (BitTorrent P2P). Tiene que coincidir con el port forward
# del router. Si se cambia aquí, ajustar también en el router.
TRANSMISSION_PEER_PORT=51413

# Subred de la red `homelab` (../02-docker/02-estructura-compose.md §4.1).
# Se inyecta en rpc-whitelist de settings.json.
HOMELAB_SUBNET=172.20.0.0/24
```

### 2.2. `.env` real (`/mnt/hd2t/services/transmission/.env`)

```bash
# Crear el directorio del servicio si no existe (lo crea el bootstrap
# de ../01-sistema/04-estructura-directorios.md §4.1, paso "Fase 10").
sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/services/transmission

# Generar un password RPC fuerte (32 chars urlsafe).
RPC_PASS=$(openssl rand -base64 32 | tr -d '+/=' | head -c 32)
echo "RPC password: $RPC_PASS"   # apuntarlo en el password manager

# Crear el .env con permisos correctos.
sudo install -o homelab -g homelab -m 600 /dev/null \
  /mnt/hd2t/services/transmission/.env

# Volcar contenido (editar el RPC_PASS si se prefiere otro).
sudo -u homelab tee /mnt/hd2t/services/transmission/.env > /dev/null <<EOF
HOMELAB_USER=homelab
HOMELAB_UID=1000
HOMELAB_GID=1000
MEDIA_GID=1100
TZ=Europe/Madrid
LAN_DOMAIN=lan
TS_DOMAIN=tailnet.ts.net
TRANSMISSION_IMAGE_TAG=4.0.6-r0-ls283
TRANSMISSION_HOSTNAME=transmission
TRANSMISSION_LAN_HOST=transmission.lan
TRANSMISSION_TS_HOST=transmission.tailnet.ts.net
TRANSMISSION_RPC_USERNAME=arr
TRANSMISSION_RPC_PASSWORD=${RPC_PASS}
TRANSMISSION_PEER_PORT=51413
HOMELAB_SUBNET=172.20.0.0/24
EOF

# Verificar.
ls -l /mnt/hd2t/services/transmission/.env
# Esperado: -rw------- 1 homelab homelab ... .env

# Apuntar el password en el password manager bajo "Homelab → Transmission RPC"
# (lo necesitarás al configurar Sonarr/Radarr/Prowlarr).
```

### 2.3. Cómo se inyectan al contenedor

El `docker-compose.yml` (§4) declara `env_file: /mnt/hd2t/services/transmission/.env`. Compose carga el fichero **a la hora de interpolar `${...}` en el YAML** y **además** lo expone al proceso del contenedor. Las variables que la imagen LSIO **lee directamente** son:

- `PUID`, `PGID`, `TZ`, `UMASK_SET` (LSIO universal)
- `USER`, `PASS` (rpc-username y rpc-password — la imagen las pone en `settings.json` en el primer arranque, después puede borrarse del env y persistirá en el config; recomendación: dejarlas para que un `docker compose down -v` accidental no rompa Sonarr/Radarr).
- `WHITELIST` (la imagen la mete en `rpc-whitelist`)
- `HOST_WHITELIST` (la imagen la mete en `rpc-host-whitelist`)
- `PEERPORT` (la imagen la mete en `peer-port`)

El resto (`TRANSMISSION_HOSTNAME`, `TRANSMISSION_LAN_HOST`, `LAN_DOMAIN`, …) solo se usa **fuera** del contenedor: en el `Caddyfile` y en este `docker-compose.yml`.

> **Por qué el password RPC sí va en `.env`** (a diferencia de Jellyfin/Calibre-Web): es **la única credencial** que Sonarr/Radarr/Prowlarr necesitan para hablar con Transmission. Si la imagen LSIO no la propaga al `settings.json` en el primer arranque, hay que metterla a mano y rotarla en cada uno de los tres clientes. El `.env` está en `chmod 600` y solo es leíble por `homelab`/`root`; suficiente para el modelo de amenaza del homelab.

---

## 3. Preparar el árbol de datos

### 3.1. Crear el directorio del stack

```bash
mkdir -p ~/homelab/stacks/transmission
cd ~/homelab/stacks/transmission
```

### 3.2. Crear el árbol de datos persistentes del servicio

```bash
# /mnt/hd2t/services/transmission/  (homelab:homelab 750)
sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/services/transmission
sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/services/transmission/config
```

### 3.3. Verificar el árbol de descargas (creado en Fase 1)

```bash
# ../01-sistema/04-estructura-directorios.md §4.3 ya creó:
#   /mnt/hd2t/downloads/  (homelab:media 2775)
#     ├── incomplete/
#     ├── complete/
#     └── watch/
# Verificar que existen y tienen los permisos correctos:
stat -c '%a %U:%G %n' /mnt/hd2t/downloads /mnt/hd2t/downloads/{incomplete,complete,watch}
```

Esperado:

```
2775 homelab:media /mnt/hd2t/downloads
2775 homelab:media /mnt/hd2t/downloads/incomplete
2775 homelab:media /mnt/hd2t/downloads/complete
2775 homelab:media /mnt/hd2t/downloads/watch
```

Si alguno **no** existe o tiene permisos distintos, re-aplicar:

```bash
sudo install -d -o homelab -g media -m 2775 /mnt/hd2t/downloads
for sub in incomplete complete watch; do
  sudo install -d -o homelab -g media -m 2775 "/mnt/hd2t/downloads/${sub}"
done
```

> **Por qué `2775` y no `2770`**: el bit `0775` permite a "otros" (cualquier usuario) **leer** y **listar**. En el homelab "otros" no existe — solo `homelab` y procesos en grupo `media`. El bit en `0775` simplifica troubleshooting (un `ls` desde la cuenta `root` u otro user del sistema funciona) sin abrir un riesgo real (los discos solo están accesibles por SSH al usuario `homelab`).

### 3.4. Tabla resumen de permisos

| Ruta | Owner:Group | Modo | Notas |
|---|---|---|---|
| `/mnt/hd2t/services/transmission/` | `homelab:homelab` | `750` | Directorio raíz del servicio. Solo `homelab`. |
| `/mnt/hd2t/services/transmission/.env` | `homelab:homelab` | `600` | Contiene el password RPC. Solo legible por `homelab` (y `root`). |
| `/mnt/hd2t/services/transmission/config/` | `homelab:homelab` | `750` | Datos de Transmission: `settings.json`, `resume/`, `torrents/`, `dht.dat`, `blocklists/`. Respaldable. |
| `/mnt/hd2t/downloads/` | `homelab:media` | `2775` | Carpeta compartida con Sonarr/Radarr. `setgid` activo. |
| `/mnt/hd2t/downloads/incomplete/` | `homelab:media` | `2775` | Descargas en curso. **Excluida** del backup. |
| `/mnt/hd2t/downloads/complete/` | `homelab:media` | `2775` | Descargas finalizadas. Sonarr/Radarr leen y mueven (o hardlink) a `media/`. |
| `/mnt/hd2t/downloads/watch/` | `homelab:media` | `2775` | Auto-add: `cp foo.torrent` aquí y Transmission lo carga. |

### 3.5. Permisos para el proceso del contenedor

LSIO ejecuta el entrypoint como `root` y dentro hace `chown -R abc:abc /config /downloads /watch` con `abc` mapeado al `PUID:PGID` del env. Por tanto, **dentro del contenedor** el proceso `transmission-daemon` corre como UID 1000, GID 1100 (y como secundario también 1000 si la imagen añade `abc` al grupo `users` por compat — irrelevante).

El primer arranque hará un `chown -R 1000:1100` sobre `/config`, `/downloads/*` y `/watch`. Si `/mnt/hd2t/downloads/` ya tiene millones de ficheros (poco probable la primera vez, pero relevante en re-deploys), ese `chown -R` puede tardar minutos. El `start_period` del healthcheck (60s) lo cubre en el caso normal — si tarda más, ajustar a `180s`.

---

## 4. `docker-compose.yml`

`~/homelab/stacks/transmission/docker-compose.yml`:

```yaml
# ~/homelab/stacks/transmission/docker-compose.yml
# Stack: transmission (cliente BitTorrent del homelab, Fase 10).
# Datos en /mnt/hd2t/services/transmission/config/.
# Descargas en /mnt/hd2t/downloads/{incomplete,complete,watch}/ (RW).

name: transmission

services:
  transmission:
    image: lscr.io/linuxserver/transmission:${TRANSMISSION_IMAGE_TAG}
    container_name: transmission
    hostname: transmission
    restart: unless-stopped
    env_file: /mnt/hd2t/services/transmission/.env

    environment:
      # PUID 1000 (homelab), PGID 1100 (media). LSIO baja el proceso
      # transmission-daemon a ese UID/GID en el entrypoint.
      PUID: ${HOMELAB_UID}
      PGID: ${MEDIA_GID}
      TZ: ${TZ}
      # umask 002 → ficheros 0664, dirs 0775. Combinado con setgid en
      # /mnt/hd2t/downloads/, los ficheros son leíbles/escribibles por
      # cualquier miembro del grupo `media` (Sonarr/Radarr).
      UMASK_SET: "002"
      # Credenciales HTTP Basic RPC (para Sonarr/Radarr/Prowlarr).
      USER: ${TRANSMISSION_RPC_USERNAME}
      PASS: ${TRANSMISSION_RPC_PASSWORD}
      # rpc-whitelist y rpc-host-whitelist (LSIO los inyecta en settings.json).
      WHITELIST: "127.0.0.1,${HOMELAB_SUBNET//.0\\/24/.*}"
      HOST_WHITELIST: "${TRANSMISSION_LAN_HOST},${TRANSMISSION_TS_HOST},${TRANSMISSION_HOSTNAME}"
      # Puerto de peers fijo (ha de coincidir con el port forward del router).
      PEERPORT: ${TRANSMISSION_PEER_PORT}

    volumes:
      # Config respaldable: settings.json, resume/, torrents/, blocklists/, dht.dat.
      - /mnt/hd2t/services/transmission/config:/config
      # Carpeta de descargas. RW. setgid en el host hereda grupo `media`.
      - /mnt/hd2t/downloads:/downloads
      # Watch dir: auto-add de .torrent. Idéntico bind a un subdir, montado
      # explícitamente para que Transmission lo reconozca como watch-dir.
      - /mnt/hd2t/downloads/watch:/watch
      # TZ y reloj sincronizados con el host (timestamps en logs y resume/).
      - /etc/localtime:/etc/localtime:ro

    ports:
      # Peer port en mode: host para preservar la IP real del peer.
      # NUNCA publicar 9091 — Caddy llega por la red interna.
      - target: ${TRANSMISSION_PEER_PORT}
        published: ${TRANSMISSION_PEER_PORT}
        protocol: tcp
        mode: host
      - target: ${TRANSMISSION_PEER_PORT}
        published: ${TRANSMISSION_PEER_PORT}
        protocol: udp
        mode: host

    networks:
      - homelab

    # Recursos: transmission-daemon arranca con ~50 MB y suele estabilizarse
    # en 100-200 MB. Picos al verificar piezas (sha1 de un torrent grande)
    # pueden subir a 400 MB durante el "Verifying local data".
    mem_limit: 768m
    mem_reservation: 64m

    # Healthcheck: GET / contra la UI devuelve 401 (sin auth) o 200 (con auth
    # nativa habilitada). Ambos sirven como "el listener HTTP está vivo".
    # Si devolviera 5xx, el daemon estaría caído.
    healthcheck:
      test: ["CMD-SHELL", "curl -fsS -o /dev/null -w '%{http_code}\\n' http://localhost:9091/transmission/web/ | grep -E '^(200|401)$$'"]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 60s

    # security_opt: igual que el resto del homelab (../02-docker/02-estructura-compose.md §0).
    security_opt:
      - no-new-privileges:true

    labels:
      # Watchtower: actualizar automáticamente.
      # Política: ../02-docker/04-watchtower.md §4.2.
      com.centurylinklabs.watchtower.enable: "true"
      # Para Dozzle: agrupar logs del *arr stack.
      dev.dozzle.group: "arr"

networks:
  homelab:
    external: true
```

### 4.1. Por qué cada bloque

| Bloque | Por qué |
|---|---|
| `name: transmission` | Nombre del proyecto Compose. Aunque [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §1.1 agrupa Transmission bajo el stack `arr`, en la práctica cada servicio del *arr stack tiene su propio stack folder — un `down` afecta solo a Transmission y no para Sonarr/Radarr/Prowlarr. |
| `image: lscr.io/linuxserver/transmission:${TRANSMISSION_IMAGE_TAG}` | Tag pinned vía `.env`. La imagen LSIO vive en LinuxServer Container Registry. |
| `container_name: transmission` / `hostname: transmission` | Nombre estable para que Caddy llegue por DNS (`reverse_proxy http://transmission:9091`) y para que Sonarr/Radarr/Prowlarr usen `transmission` como host del download client. Sin esto, Compose le pone un nombre tipo `transmission-transmission-1` y rompe el DNS interno. |
| `env_file: /mnt/hd2t/services/transmission/.env` | Carga de variables — patrón estándar del homelab. |
| `environment.PUID` / `PGID` | UID 1000 (escribe en `/config`), GID 1100 (escribe en `/downloads/` con `setgid` heredado). |
| `environment.TZ` | Transmission loguea timestamps en zona local. |
| `environment.UMASK_SET: "002"` | Ficheros nuevos `0664`, directorios `0775`. Sonarr/Radarr (PGID 1100) pueden mover/leer/borrar. |
| `environment.USER` / `PASS` | LSIO los inyecta en `settings.json` (`rpc-username`, `rpc-password`). Si la persona quita `PASS` del env tras el primer arranque, persiste en `settings.json`. |
| `environment.WHITELIST` | LSIO lo mete en `rpc-whitelist` de `settings.json`. La interpolación `${HOMELAB_SUBNET//.0\/24/.*}` convierte `172.20.0.0/24` → `172.20.0.*` (formato glob que Transmission acepta). |
| `environment.HOST_WHITELIST` | LSIO lo mete en `rpc-host-whitelist`. Bloquea ataques DNS rebinding. |
| `environment.PEERPORT` | LSIO lo mete en `peer-port`. Si el operador cambia el puerto en el router, ajustar `TRANSMISSION_PEER_PORT` en `.env` y `docker compose up -d` regenera `settings.json`. |
| `volumes: /mnt/hd2t/services/transmission/config:/config` | Bind mount canónico de la BD. Sin `:Z`/`:z` (no SELinux en Pi OS). |
| `volumes: /mnt/hd2t/downloads:/downloads` | **Read-write**, mismo árbol que verán Sonarr/Radarr (con sus propios bind mounts en sus docs). El path **debe** coincidir entre los servicios para que las "Remote Path Mappings" no sean necesarias. |
| `volumes: /mnt/hd2t/downloads/watch:/watch` | Bind explícito para el watch-dir. Aunque `/watch` es un subdirectorio de `/downloads`, Transmission espera dos paths distintos en `settings.json` (`watch-dir` ≠ `download-dir`); montarlo dos veces no duplica el espacio. |
| `volumes: /etc/localtime:ro` | Sincroniza la zona del host con el contenedor — backup ante un usuario que olvide poner `TZ` en `.env`. |
| `ports: 51413/tcp` y `51413/udp` con `mode: host` | **Excepción** al patrón "no `ports:`". El peer port es P2P y necesita conexiones entrantes. `mode: host` evita que iptables del bridge Docker reescriba la IP origen, así Transmission ve la IP real del peer remoto en `Peers` y en sus logs. |
| `networks: [homelab]` | Solo la red compartida. Caddy ya está ahí; Sonarr/Radarr/Prowlarr también lo estarán al desplegarse. |
| `mem_limit: 768m` | Transmission ronda 100–200 MB; picos al verificar piezas hasta 400 MB. 768 MB de tope deja margen sin pegarse con el resto del homelab. |
| `mem_reservation: 64m` | Garantía mínima en presión de memoria. |
| `healthcheck` con `curl` a `/transmission/web/` | Comprueba que el listener HTTP está vivo. `200` o `401` (si la auth nativa está habilitada) son ambos OK. Cualquier `5xx` o `Connection refused` marca el contenedor `unhealthy`. `start_period: 60s` cubre el `chown -R` del entrypoint LSIO. |
| `security_opt: no-new-privileges:true` | Patrón base ([`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §0). |
| `com.centurylinklabs.watchtower.enable: "true"` | Watchtower opt-in en el homelab ([`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §4.2). Transmission está en la lista de servicios "stateless o de lectura ligera" que se actualizan auto. |
| `dev.dozzle.group: "arr"` | Cuando Dozzle ([`../05-monitorizacion/06-dozzle.md`](../05-monitorizacion/06-dozzle.md)) levante, agrupa Transmission, Prowlarr, Sonarr y Radarr bajo el mismo grupo "arr". |
| `networks.homelab.external: true` | Patrón de [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §4.4: la red se crea **una vez** durante el bootstrap. |

### 4.2. Validar antes de levantar

```bash
cd ~/homelab/stacks/transmission
docker compose --env-file /mnt/hd2t/services/transmission/.env config
```

Esperado: salida YAML resuelta sin warnings. Verificar especialmente:

- `image: lscr.io/linuxserver/transmission:4.0.6-r0-ls283` (el tag interpolado).
- `WHITELIST: "127.0.0.1,172.20.0.*"` (si hay un literal `${...}`, la interpolación falló).
- `PEERPORT: "51413"`.
- Ambos `ports:` con `mode: host`.

Si Compose se queja de `version` en el YAML: la spec moderna no necesita `version: "3.x"`; está omitido a propósito.

---

## 5. Despliegue

### 5.1. Levantar el stack

```bash
cd ~/homelab/stacks/transmission

# Pull explícito antes del up: separa errores de imagen de errores de runtime.
docker compose --env-file /mnt/hd2t/services/transmission/.env pull
docker compose --env-file /mnt/hd2t/services/transmission/.env up -d

docker compose ps
# transmission   running (healthy)   0.0.0.0:51413->51413/tcp,udp
```

### 5.2. Estado del contenedor

```bash
docker inspect transmission \
  --format '{{.State.Status}} | {{.State.Health.Status}} | {{.HostConfig.PortBindings}}'
# running | healthy | map[51413/tcp:[{ 51413}] 51413/udp:[{ 51413}]]

docker logs transmission --tail 50
```

Logs típicos del primer arranque:

```
[migrations] started
[migrations] no migrations found
─────────────────────────────────────
       _         ()
      | |        |||
   _  | | __  __ ||| ___    LinuxServer.io
  | |_| | \  \/  /  / __|   image  by   :
  | __ | / /\  \ / / __ \                
  |  _   /__/  \__\ \___/                
  |_| | \____\____\\____\                
                                         
─────────────────────────────────────
GID/UID
─────────────────────────────────────
User uid:    1000
User gid:    1100
─────────────────────────────────────
[s6-init] making user provided files available at /var/run/s6/etc...exited 0.
[transmission-daemon] Starting (PID 314).
[transmission-daemon] RPC bound to 0.0.0.0:9091
[transmission-daemon] Loaded 0 torrents
```

Si en lugar de `[transmission-daemon] RPC bound to 0.0.0.0:9091` aparece `Address already in use`, hay otro proceso ocupando 9091 dentro del contenedor (poco probable en un container limpio) o el contenedor está en `network: host` por un error en el compose.

### 5.3. Onboarding inicial (RPC operativa)

A partir de aquí la UI está accesible **internamente** en `http://transmission:9091/` desde la red `homelab`. No es accesible desde el host hasta que Caddy esté configurado (§6). Para una smoke-check sin Caddy:

```bash
docker run --rm --network homelab curlimages/curl:latest \
  -u "${TRANSMISSION_RPC_USERNAME}:${TRANSMISSION_RPC_PASSWORD}" \
  http://transmission:9091/transmission/rpc/
# Esperado: 409 Conflict con "X-Transmission-Session-Id: <token>"
# (es como Transmission protege contra CSRF — comportamiento normal)
```

> **Por qué un 409**: Transmission usa el patrón **CSRF** para su API: la primera petición devuelve 409 con un header `X-Transmission-Session-Id`. El cliente debe reenviar la siguiente petición incluyendo ese header. Sonarr/Radarr/Prowlarr lo manejan automáticamente; no es un error.

---

## 6. Integración con Caddy

### 6.1. Añadir el bloque `transmission.{$LAN_DOMAIN}` al `Caddyfile`

`~/homelab/stacks/proxy/Caddyfile`, sección de bloques de host (siguiendo el patrón de §4.3 de [`../03-red/04-caddy.md`](../03-red/04-caddy.md)):

```caddy
# ----- Transmission (../10-descargas/01-transmission.md) -----
transmission.{$LAN_DOMAIN} {
    import lan_internal_tls
    import security_headers

    # Authelia delante: 2FA TOTP obligatorio (group:admin), ../04-seguridad/01-authelia.md §4.
    forward_auth http://authelia:9091 {
        uri /api/authz/forward-auth
        copy_headers Remote-User Remote-Groups Remote-Name Remote-Email
    }

    reverse_proxy http://transmission:9091 {
        # Transmission espera el path /transmission/web/ y /transmission/rpc/.
        # Caddy reenvía tal cual; no hay rewrite necesario.
        header_up X-Forwarded-Proto https
        header_up X-Real-IP {remote_host}
    }
}
```

Recargar Caddy:

```bash
docker exec proxy caddy reload --config /etc/caddy/Caddyfile
```

### 6.2. Trusted proxies en Transmission (no aplica)

Transmission no tiene configuración de "trusted proxies": loguea siempre la IP del cliente que toca su puerto 9091. Como ese cliente es **siempre Caddy** (172.20.0.x), todos los logs de UI mostrarán esa IP, no la IP del navegador real. Si el operador necesita la IP real (por ejemplo, para investigar accesos), la información está en los logs JSON de Caddy (`/var/log/caddy/access.log`, [`../03-red/04-caddy.md`](../03-red/04-caddy.md) §4.3).

### 6.3. Registro DNS local en Pi-hole

`https://pihole.lan/admin/` → **Local DNS → DNS Records**:

| Domain | IP Address |
|---|---|
| `transmission.lan` | `192.168.1.x` (IP fija de la Pi) |

Verificar:

```bash
dig +short transmission.lan @192.168.1.2
# 192.168.1.x   (IP de la Pi)
```

### 6.4. Probar el acceso

Desde un equipo de la LAN con la CA interna confiada (paso 6.5 de [`../03-red/04-caddy.md`](../03-red/04-caddy.md)):

```
https://transmission.lan
```

Flujo esperado:

1. **Authelia** redirige a `https://auth.lan/?rd=https://transmission.lan/`.
2. Login con usuario `homelab` (o el operador con grupo `admin`).
3. **2FA TOTP** (configurado en el primer login a Authelia, [`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md)).
4. Tras OK, Caddy reenvía a `http://transmission:9091/` y Transmission **vuelve a pedir** el HTTP Basic (`USER`/`PASS` del `.env`).

> **Por qué doble auth**: la auth nativa de Transmission **no se puede deshabilitar fácilmente** sin renunciar a la API RPC para Sonarr/Radarr/Prowlarr. Por eso queda activa. El navegador la cachea tras el primer login (`Remember password`), así que en la práctica el operador ve solo el flow de Authelia. El password RPC se rota con un nuevo `docker compose up -d` cambiando `TRANSMISSION_RPC_PASSWORD` y reconfigurando los tres clientes (Sonarr, Radarr, Prowlarr).

### 6.5. Por qué Authelia delante de Transmission por defecto

A diferencia de Jellyfin/Navidrome (donde Authelia rompería las apps móviles y los Smart TV), Transmission solo se usa por **navegador** del operador. No hay apps móviles oficiales que dependan de cookies de sesión vs HTTP Basic. Por tanto:

- **Authelia delante**: el ataque "alguien en mi LAN encontró `transmission.lan`" se queda en la pantalla de login con 2FA.
- **No interfiere con Sonarr/Radarr/Prowlarr**: ellos hablan al puerto interno 9091 directamente, sin pasar por Caddy.
- **No interfiere con `transmission-remote`**: el cliente CLI también va al puerto interno o se ejecuta dentro del contenedor con `docker exec transmission transmission-remote ...`.

Resumen: Transmission es el caso "perfecto" de SSO+2FA por defecto. Los demás servicios donde Authelia se desaconseja son los que tienen apps nativas multiplataforma con auth propia.

### 6.6. Acceso vía Tailscale (preparado)

Cuando Tailscale esté operativo ([`../03-red/05-tailscale.md`](../03-red/05-tailscale.md)), añadir al `Caddyfile`:

```caddy
transmission.{$TS_DOMAIN} {
    import tailscale_tls transmission
    import security_headers

    # Authelia también delante en Tailscale (no es un "remoto de confianza").
    forward_auth http://authelia:9091 {
        uri /api/authz/forward-auth
        copy_headers Remote-User Remote-Groups Remote-Name Remote-Email
    }

    reverse_proxy http://transmission:9091 {
        header_up X-Forwarded-Proto https
        header_up X-Real-IP {remote_host}
    }
}
```

---

## 7. Configuración post-despliegue

La mayoría de la configuración se inyecta vía variables de entorno (§4) en el primer arranque y persiste en `/config/settings.json`. Esta sección cubre los **ajustes recomendados que requieren editar `settings.json` manualmente** (Transmission no los expone como variables LSIO).

### 7.1. Editar `settings.json` con cuidado

Transmission **escribe** `settings.json` al apagarse de forma limpia. Para evitar sobrescribir cambios manuales:

```bash
# 1. Parar el contenedor (sin -v).
docker compose stop transmission

# 2. Editar settings.json.
sudo nano /mnt/hd2t/services/transmission/config/settings.json

# 3. Levantar de nuevo.
docker compose start transmission
```

Si se edita en caliente, Transmission descarta los cambios al apagarse.

### 7.2. Ajustes recomendados en `settings.json`

Los siguientes valores **no** los gestiona LSIO. Son ediciones sobre el `settings.json` ya generado:

```jsonc
{
  // ─── Paths ────────────────────────────────────────────────────────────
  "download-dir":        "/downloads/complete",
  "incomplete-dir":      "/downloads/incomplete",
  "incomplete-dir-enabled": true,
  "watch-dir":           "/watch",
  "watch-dir-enabled":   true,
  "trash-original-torrent-files": true,

  // ─── Velocidades (KB/s) ────────────────────────────────────────────────
  // Conexión típica 600/600 Mbps. Ajustar al operador.
  "speed-limit-down":         0,        // ignorado: speed-limit-down-enabled=false
  "speed-limit-down-enabled": false,
  "speed-limit-up":           4096,     // 4 MB/s — no saturar uplink
  "speed-limit-up-enabled":   true,

  // Alt-speed: 23:00 → 06:00, sube DL ilimitado y UL a tope.
  "alt-speed-down":         0,
  "alt-speed-up":           8192,        // 8 MB/s en horario nocturno
  "alt-speed-enabled":      false,       // se activa por scheduler (siguiente)
  "alt-speed-time-enabled": true,
  "alt-speed-time-begin":   1380,        // minutos desde 00:00 (23:00 = 1380)
  "alt-speed-time-end":     360,         // 06:00 = 360
  "alt-speed-time-day":     127,         // bitmap todos los días

  // ─── Peers ────────────────────────────────────────────────────────────
  "peer-port":                ${TRANSMISSION_PEER_PORT},
  "peer-port-random-on-start": false,
  "port-forwarding-enabled":  false,     // UPnP/NAT-PMP off
  "peer-limit-global":        200,
  "peer-limit-per-torrent":   50,

  // ─── BEP options ──────────────────────────────────────────────────────
  // DHT/PEX/LSD: ON para torrents públicos. Cada torrent privado los
  // desactiva en su propia metadata, no hace falta tocar globalmente.
  "dht-enabled":              true,
  "pex-enabled":              true,
  "lpd-enabled":              true,
  "utp-enabled":              true,

  // ─── Encryption ───────────────────────────────────────────────────────
  // 0=tolerated, 1=preferred, 2=required.
  // 1 es óptimo: prefiere cifrado pero no rompe trackers privados que
  // no ofrecen peers cifrados.
  "encryption":               1,

  // ─── Queue ────────────────────────────────────────────────────────────
  "download-queue-enabled":   true,
  "download-queue-size":      5,
  "seed-queue-enabled":       true,
  "seed-queue-size":          10,
  "queue-stalled-enabled":    true,
  "queue-stalled-minutes":    30,

  // ─── Ratio / Idle ─────────────────────────────────────────────────────
  // Ratio global. Trackers privados anulan esto torrent-por-torrent.
  "ratio-limit":              2.0,
  "ratio-limit-enabled":      false,     // dejar global desactivado; usar por torrent
  "idle-seeding-limit":       30,        // minutos
  "idle-seeding-limit-enabled": false,

  // ─── Blocklists ───────────────────────────────────────────────────────
  "blocklist-enabled":        true,
  "blocklist-url":            "https://github.com/Naunter/BT_BlockLists/raw/master/bt_blocklists.gz",

  // ─── RPC ──────────────────────────────────────────────────────────────
  // Inyectados por LSIO desde USER/PASS/WHITELIST/HOST_WHITELIST.
  "rpc-authentication-required": true,
  "rpc-username":             "arr",
  // "rpc-password" hasheado por Transmission al primer arranque.
  "rpc-whitelist":            "127.0.0.1,172.20.0.*",
  "rpc-whitelist-enabled":    true,
  "rpc-host-whitelist":       "transmission.lan,transmission.tailnet.ts.net,transmission",
  "rpc-host-whitelist-enabled": true,

  // ─── Tracker / DNS ────────────────────────────────────────────────────
  // Sin proxy. Los DNS los resuelve el contenedor → red `homelab` →
  // upstream del Docker daemon → Pi-hole + Unbound.
  // Si Pi-hole está caído, los trackers no resuelven; ver §11.

  // ─── Misc ─────────────────────────────────────────────────────────────
  "umask":                    18,        // 18 decimal = 0o022; redundante con UMASK_SET=002 del env
  "preallocation":            1,         // 0=off, 1=fast, 2=full. 1 evita fragmentación leve.
  "rename-partial-files":     true,      // ficheros incompletos con sufijo .part
  "start-added-torrents":     true,
  "script-torrent-done-enabled": false,  // hooks externos: ver §12.4
  "script-torrent-done-filename": ""
}
```

> **No reescribir variables que LSIO ya inyectó**: `peer-port`, `rpc-*`. Si se editan a mano y luego LSIO se re-arranca, las sobreescribe con los valores del env. **Mantener la fuente de verdad en `.env`** y usar `settings.json` solo para los campos que **no** están en el env.

### 7.3. Aplicar y verificar

```bash
docker compose stop transmission
sudo nano /mnt/hd2t/services/transmission/config/settings.json
docker compose start transmission

# Verificar que Transmission ha cargado los cambios:
docker logs transmission --tail 20 | grep -E '(peer-port|RPC|incomplete-dir|watch-dir)'
```

### 7.4. Programar la blocklist

Transmission actualiza la blocklist al arrancar y luego cada 24h por defecto. Para forzar update manual:

```bash
docker exec transmission transmission-remote -n "${TRANSMISSION_RPC_USERNAME}:${TRANSMISSION_RPC_PASSWORD}" --blocklist-update
# Blocklist updated successfully (314159 entries)
```

### 7.5. Sincronización con Sonarr/Radarr/Prowlarr

Esto se cubre en los docs respectivos ([`./03-sonarr.md`](./03-sonarr.md), [`./04-radarr.md`](./04-radarr.md)). Resumen:

- **Host**: `transmission` (DNS interno de la red `homelab`).
- **Port**: `9091`.
- **URL Base**: `/transmission/`.
- **Username**: `${TRANSMISSION_RPC_USERNAME}`.
- **Password**: `${TRANSMISSION_RPC_PASSWORD}`.
- **Category**: `tv-sonarr`, `movies-radarr` (etiquetas que Transmission permite por torrent y que Sonarr/Radarr usan para filtrar lo suyo).
- **Directory**: dejar en blanco — Sonarr/Radarr usan el `download-dir` que Transmission tiene configurado (`/downloads/complete`).
- **Use SSL**: **no** (la red `homelab` es interna).

---

## 8. Verificación

### 8.1. Contenedor sano

```bash
docker compose ps
# transmission   running (healthy)
docker inspect transmission --format '{{.State.Health.Status}}'
# healthy
```

### 8.2. Transmission escucha solo dentro de la red `homelab` (excepto peer port)

```bash
docker exec transmission netstat -tnlp | grep -E ':(9091|51413)'
# tcp        0      0 0.0.0.0:9091            0.0.0.0:*               LISTEN      transmission-daemon
# tcp        0      0 0.0.0.0:51413           0.0.0.0:*               LISTEN      transmission-daemon

# Desde el host: 9091 NO publicado (solo accesible internamente).
ss -tnlp | grep -E ':9091'   # vacío
ss -tnlp | grep -E ':51413'  # listen 0.0.0.0:51413 (mode: host)
```

### 8.3. Peer port accesible desde fuera del router

Test pasivo (Transmission lo dice en la UI, "Settings > Network > Test Port"):

```bash
docker exec transmission transmission-remote -n "${TRANSMISSION_RPC_USERNAME}:${TRANSMISSION_RPC_PASSWORD}" -pt
# Port is open
```

Si sale `Port is closed`:

1. Verificar el port forwarding del router (`51413/tcp` y `51413/udp`).
2. Verificar `ufw allow 51413/tcp` y `ufw allow 51413/udp` en el host (ver [`../01-sistema/03-seguridad-base.md`](../01-sistema/03-seguridad-base.md) §4).
3. Verificar que `port-forwarding-enabled` está `false` (UPnP off, irrelevante para esto pero ayuda a no confundir).

### 8.4. Bibliotecas montadas y escribibles

```bash
docker exec transmission ls -ld /downloads /downloads/incomplete /downloads/complete /watch
# drwxrwsr-x  ... abc users 0 ... /downloads
# drwxrwsr-x  ... abc users 0 ... /downloads/incomplete
# drwxrwsr-x  ... abc users 0 ... /downloads/complete
# drwxrwsr-x  ... abc users 0 ... /watch

docker exec transmission touch /downloads/.smoke
docker exec transmission ls -l /downloads/.smoke
# -rw-rw-r-- 1 abc users 0 ... .smoke
docker exec transmission rm /downloads/.smoke
```

### 8.5. UI web operativa (vía Caddy)

```bash
curl -ks https://transmission.lan/ | head
# Esperado: redirect a https://auth.lan/?rd=...
```

Desde un navegador con la CA interna confiada:

1. `https://transmission.lan` → redirect a Authelia.
2. Login + TOTP → redirect a Transmission.
3. La UI de Transmission carga.

### 8.6. RPC operativa (autenticada)

Desde otro contenedor de la red `homelab`:

```bash
docker run --rm --network homelab curlimages/curl:latest \
  -u "${TRANSMISSION_RPC_USERNAME}:${TRANSMISSION_RPC_PASSWORD}" \
  -H "X-Transmission-Session-Id: $(docker run --rm --network homelab curlimages/curl:latest \
       -s -u "${TRANSMISSION_RPC_USERNAME}:${TRANSMISSION_RPC_PASSWORD}" \
       http://transmission:9091/transmission/rpc/ -D - -o /dev/null \
       | awk '/X-Transmission-Session-Id/ {print $2}' | tr -d '\r')" \
  -X POST \
  -d '{"method":"session-stats"}' \
  http://transmission:9091/transmission/rpc/
# {"arguments":{...},"result":"success"}
```

(En la práctica Sonarr/Radarr/Prowlarr esconden este baile — solo se documenta como prueba de humo.)

### 8.7. Smoke test: añadir un torrent y verlo descargar

Usando un torrent legal (por ejemplo `https://archive.org/download/...torrent`):

```bash
# Desde Samba (../06-almacenamiento/02-samba.md, share [downloads]):
cp ~/Downloads/example.torrent /mnt/.../downloads/watch/

# Verificar que Transmission lo carga.
docker exec transmission transmission-remote -n "${TRANSMISSION_RPC_USERNAME}:${TRANSMISSION_RPC_PASSWORD}" -l
#   ID   Done  ... Status        Name
#    1    0%   ... Downloading   example
```

Tras unos segundos, el `.torrent` desaparece de `watch/` (porque `trash-original-torrent-files: true`).

### 8.8. Persistencia tras reboot

```bash
sudo reboot
# (esperar)
ssh homelab@pi
docker compose -f ~/homelab/stacks/transmission/docker-compose.yml ps
# transmission   running (healthy)
docker exec transmission transmission-remote -n "${TRANSMISSION_RPC_USERNAME}:${TRANSMISSION_RPC_PASSWORD}" -l
# Los torrents activos siguen en su estado anterior (resume/ los recupera).
```

### 8.9. Lista de verificación

- [ ] Contenedor `transmission` está `running (healthy)`.
- [ ] `9091` solo accesible vía red interna `homelab` (no en `ss -tnlp` del host).
- [ ] `51413/tcp+udp` accesible desde fuera del router (port test OK).
- [ ] `/mnt/hd2t/downloads/{incomplete,complete,watch}/` montados RW dentro del contenedor con `homelab:media 2775`.
- [ ] `https://transmission.lan` redirige a Authelia, login con TOTP funciona, UI de Transmission carga.
- [ ] RPC autenticada responde a `session-stats`.
- [ ] Watch dir auto-add operativo (`cp` de un `.torrent` → aparece en la UI).
- [ ] Tras reboot, los torrents activos retoman su estado.

---

## 9. Backup

### 9.1. Qué se respalda y qué no

| Ruta | Backup | Por qué |
|---|---|---|
| `/mnt/hd2t/services/transmission/config/settings.json` | **Sí** | Configuración completa del daemon; sin esto se pierden ajustes finos. |
| `/mnt/hd2t/services/transmission/config/torrents/*.torrent` | **Sí** | Metadatos de cada torrent activo. Sin esto, los `.torrent` se perderían y habría que re-añadirlos manualmente. Tamaño típico: ~30 KB cada uno. |
| `/mnt/hd2t/services/transmission/config/resume/*.resume` | **Sí** | Estado de cada torrent (porcentaje, peers, ratio acumulado). Restaurarlo permite retomar exactamente donde estaba. |
| `/mnt/hd2t/services/transmission/config/blocklists/` | No (regenerable) | Se descargan al arrancar. Tamaño: ~30 MB. |
| `/mnt/hd2t/services/transmission/config/dht.dat` | No (regenerable) | Tabla de routing DHT; se reconstruye en minutos al arrancar. |
| `/mnt/hd2t/services/transmission/.env` | **Sí** (vía `/mnt/hd2t/backups/configs/`) | Contiene el password RPC. Sin esto, hay que rotarlo y reconfigurar Sonarr/Radarr/Prowlarr al restore. |
| `/mnt/hd2t/downloads/incomplete/` | **No** | Excluido en [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §13.6: descargas a medias se pueden retomar desde el `.torrent` + `resume`. |
| `/mnt/hd2t/downloads/complete/` | Depende | Las películas/series finalizadas que **ya** están en `media/` (Sonarr/Radarr las movieron) **no** se respaldan dos veces. La copia "primaria" vive en `media/{tv,movies}/`, que es lo que Borgmatic incluye (con su propia decisión: ver [`../07-backups/01-estrategia-backup.md`](../07-backups/01-estrategia-backup.md)). |

### 9.2. Política Borgmatic

`~/homelab/stacks/borgmatic/borgmatic.d/transmission.yaml`:

```yaml
# Mixto: incluido en el patrón general /mnt/hd2t/services/, con exclusión
# manual del subdirectorio incomplete (ya está en /mnt/hd2t/downloads/, no aquí).

# Las exclusiones globales viven en ../07-backups/02-borgmatic.md §13.6.
# Aquí solo se documenta el smoke test de restore.
```

> Nota: la exclusión que aparece en [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) líneas ~437 (`/mnt/hd2t/services/transmission/downloads/incomplete`) es un alias defensivo: si en el futuro alguien cambia la convención y mueve `downloads/` dentro de `services/transmission/`, el backup ya estaría protegido. Con la convención actual (`/mnt/hd2t/downloads/`), esa ruta no existe — el `exclude_pattern` no machea nada y no rompe.

### 9.3. Restore (resumen)

```bash
# 1. Parar el contenedor.
docker compose -f ~/homelab/stacks/transmission/docker-compose.yml stop

# 2. Restaurar /mnt/hd2t/services/transmission/config/ desde Borg.
borgmatic extract --archive latest \
  --path /mnt/hd2t/services/transmission/config \
  --destination /

# 3. Restaurar el .env.
borgmatic extract --archive latest \
  --path /mnt/hd2t/services/transmission/.env \
  --destination /

# 4. Levantar de nuevo.
docker compose -f ~/homelab/stacks/transmission/docker-compose.yml up -d

# 5. Verificar.
docker exec transmission transmission-remote -n "${TRANSMISSION_RPC_USERNAME}:${TRANSMISSION_RPC_PASSWORD}" -l
# Los torrents activos aparecen en estado "Verifying local data" durante
# unos minutos (re-hash de las piezas) y luego retoman.
```

### 9.4. Smoke test mensual de restore

Mismo patrón que [`../09-multimedia/04-calibre-web.md`](../09-multimedia/04-calibre-web.md) §9.4:

```bash
# Restaurar a /tmp/restore_test/ y verificar settings.json + un .torrent al azar.
sudo rm -rf /tmp/restore_test
mkdir -p /tmp/restore_test
borgmatic extract --archive latest \
  --path /mnt/hd2t/services/transmission/config \
  --destination /tmp/restore_test

ls /tmp/restore_test/mnt/hd2t/services/transmission/config/torrents | head -5
jq '."download-dir"' /tmp/restore_test/mnt/hd2t/services/transmission/config/settings.json
# "/downloads/complete"

sudo rm -rf /tmp/restore_test
```

---

## 10. Operaciones cotidianas

### 10.1. Upgrade automático (Watchtower)

Política en [`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md): Watchtower revisa `lscr.io/linuxserver/transmission:4.0.6-r0-ls283` cada noche, compara digest de ese tag exacto y actualiza si LSIO ha re-publicado el tag. Si el operador quiere saltar a `4.1.0-r0-ls300`, edita `TRANSMISSION_IMAGE_TAG` en `.env`, hace `docker compose pull && docker compose up -d` y revisa logs por si hubiera migración (Transmission 4.x es compatible hacia delante; el `resume/` no rompe).

```bash
# Lista de upgrades aplicados por Watchtower:
docker logs watchtower 2>&1 | grep -i transmission | tail -20
```

### 10.2. Añadir torrents nuevos

Tres vías:

1. **UI web** (https://transmission.lan): "Open Torrent" → pegar magnet o subir `.torrent`.
2. **Watch dir**: `cp foo.torrent /mnt/hd2t/downloads/watch/` (vía Samba [`downloads`] desde otro PC, o vía `scp` desde el operador).
3. **CLI desde el host**:

   ```bash
   docker exec transmission transmission-remote -n "${TRANSMISSION_RPC_USERNAME}:${TRANSMISSION_RPC_PASSWORD}" \
     -a "magnet:?xt=urn:btih:..."
   ```

4. **Sonarr/Radarr/Prowlarr**: el flujo "normal" del *arr stack — Sonarr/Radarr piden a Prowlarr → Prowlarr busca → Sonarr/Radarr empujan el `.torrent` a Transmission por la API RPC.

### 10.3. Cambiar velocidad temporalmente

```bash
# Activar alt-speed (perfil nocturno) ad-hoc.
docker exec transmission transmission-remote -n "${TRANSMISSION_RPC_USERNAME}:${TRANSMISSION_RPC_PASSWORD}" \
  --alt-speed
# Alt speed mode: ON

# Volver al normal.
docker exec transmission transmission-remote -n "${TRANSMISSION_RPC_USERNAME}:${TRANSMISSION_RPC_PASSWORD}" \
  --no-alt-speed
```

### 10.4. Limpiar torrents finalizados con ratio cumplido

```bash
# Listar torrents con ratio >= 2.0:
docker exec transmission transmission-remote -n "${TRANSMISSION_RPC_USERNAME}:${TRANSMISSION_RPC_PASSWORD}" -l \
  | awk '$8>=2.0 {print $1, $9}'

# Borrar uno por id (sin borrar fichero — Sonarr/Radarr ya lo movieron a media/):
docker exec transmission transmission-remote -n "${TRANSMISSION_RPC_USERNAME}:${TRANSMISSION_RPC_PASSWORD}" -t 5 -r
# Removed torrent 5

# Borrar uno por id Y borrar el fichero (cuidado: rompe el seeding):
docker exec transmission transmission-remote -n "${TRANSMISSION_RPC_USERNAME}:${TRANSMISSION_RPC_PASSWORD}" -t 5 -rad
```

> Sonarr/Radarr tienen "Completed Download Handling" que hace esto automáticamente con regla de ratio + idle time. Recomendación: dejar la limpieza al *arr y mantener Transmission como motor.

### 10.5. Forzar reverificación de un torrent

Cuando un torrent dice "Stalled" o "Verifying local data" eternamente:

```bash
docker exec transmission transmission-remote -n "${TRANSMISSION_RPC_USERNAME}:${TRANSMISSION_RPC_PASSWORD}" -t 7 -v
# Verifying torrent 7
```

### 10.6. Ver estado de la cola

```bash
docker exec transmission transmission-remote -n "${TRANSMISSION_RPC_USERNAME}:${TRANSMISSION_RPC_PASSWORD}" -si
# Connection settings:
#   ...
# Current session:
#   Uploaded:    50.2 GB
#   Downloaded:  120.4 GB
#   Ratio:       0.42
# Cumulative:
#   Uploaded:    1.4 TB
#   Downloaded:  3.5 TB
```

### 10.7. Logs

```bash
# En vivo:
docker logs -f transmission

# Logs persistidos por LSIO en /config/log/...:
docker exec transmission ls -lh /config/log/
```

LSIO redirige los logs internos del daemon al stdout del contenedor, donde Docker los captura y Dozzle los muestra. No hace falta tocar `/config/log/`.

### 10.8. Comportamiento durante mantenimiento

- **Pi-hole caído**: Transmission no resuelve los trackers (DNS interno apunta a Pi-hole), los torrents quedan en "no peers" hasta que Pi-hole vuelva. **No corrompe nada**.
- **Caddy caído**: la UI no es accesible, pero Sonarr/Radarr/Prowlarr siguen funcionando (van por la red interna, no por Caddy).
- **Transmission caído (OOM, error)**: Sonarr/Radarr empezarán a fallar al añadir nuevos torrents. El monitor de Uptime Kuma alerta. `restart: unless-stopped` lo levanta solo. Si LSIO ha publicado un tag roto, hacer `TRANSMISSION_IMAGE_TAG=<anterior>` y `docker compose up -d`.

---

## 11. Solución de Problemas

| Síntoma | Causa probable | Diagnóstico / Fix |
|---|---|---|
| Sonarr/Radarr no pueden conectar a Transmission ("Unable to connect to Transmission") | Credenciales RPC mal configuradas en el cliente, o `WHITELIST` del env no incluye la subred. | `docker exec sonarr curl -u arr:PASS http://transmission:9091/transmission/rpc/`. Si devuelve 409, la auth es OK; si 401, la pwd está mal. Si "connection refused" o "permission denied", la subred del `WHITELIST` no incluye `172.20.0.*`. |
| `https://transmission.lan` muestra "502 Bad Gateway" en Caddy | Contenedor Transmission caído o `unhealthy`. | `docker compose ps`, `docker logs transmission`. |
| Authelia no aparece al ir a `transmission.lan`; va directo al HTTP Basic | El bloque `forward_auth` no está en el `Caddyfile`, o Caddy no se recargó. | Verificar `~/homelab/stacks/proxy/Caddyfile` §6.1, recargar `docker exec proxy caddy reload --config /etc/caddy/Caddyfile`. |
| Tras login Authelia, la UI de Transmission devuelve 401 sin cesar | El password RPC del `.env` no coincide con el `settings.json` (probablemente un edit manual sobrescrito por LSIO). | Re-leer §7.1: parar contenedor → editar → arrancar. O bien reset: `sudo rm /mnt/hd2t/services/transmission/config/settings.json && docker compose up -d` (regenera desde el env). |
| `Port is closed` en el test de puerto, aunque el router tiene forward configurado | UFW del host no abre `51413/tcp+udp`. | `sudo ufw allow 51413/tcp && sudo ufw allow 51413/udp`, ver [`../01-sistema/03-seguridad-base.md`](../01-sistema/03-seguridad-base.md) §4. |
| Transmission descarga muy lento (< 1 MB/s) en un torrent con muchos seeds | DHT/PEX/LSD desactivados, encryption=2 (required) bloquea peers, blocklist demasiado agresiva. | Verificar `dht-enabled: true`, `encryption: 1`, deshabilitar blocklist temporalmente. |
| `Transmission` ratio cae a 0 incluso con 4 MB/s upload limit | El peer port no es accesible (port forward roto). Sin entrante, los peers que **se conectan** son pocos y el ratio desploma. | Reverificar §8.3. |
| Sonarr/Radarr ven "category not found" al empujar a Transmission | Las categorías de Transmission (LSIO 4.x) son **etiquetas** (`labels`) por torrent, no carpetas. Los *arr crean labels al importar; si Sonarr está mal configurado lo intenta como subdirectorio. | En Sonarr/Radarr → Settings → Download Clients → Transmission → Category: dejar el campo "Category" como `tv-sonarr` o `movies-radarr` (label, no path). |
| Un torrent finalizado se queda en "Idle" y no es visto por Sonarr/Radarr | Sonarr/Radarr no escanean automáticamente; lo hacen vía notificación de "Completed Download Handling". El torrent debe estar en estado `seeding` (no `idle`). | Sonarr → System → Tasks → "Check For Finished Download" manual. |
| Tras `docker compose down`, los torrents en `incomplete/` no resumen al volver | Compose `down` mata el contenedor de forma normal; el daemon escribe `resume/`. Si fue `down -v` (con `-v`), no aplica (no hay volúmenes anónimos). Si fue `kill`, los `resume/` pueden quedar inconsistentes y Transmission re-verifica. | Esperar al "Verifying local data" → tras eso retoma. **Nunca usar `docker kill transmission`** salvo emergencia. |
| `docker logs transmission` muestra "lock file in use" al arrancar | Otro contenedor `transmission` antiguo no se borró bien y dejó `/config/lock`. | `docker compose down`, `sudo rm /mnt/hd2t/services/transmission/config/lock`, `docker compose up -d`. |
| Volume `/mnt/hd2t/downloads/` aparece como `root:root` dentro del contenedor | El bind mount perdió permisos del host (chmod accidental). | `sudo chown -R homelab:media /mnt/hd2t/downloads/ && sudo chmod -R 2775 /mnt/hd2t/downloads/`. |

---

## 12. Variantes opt-in

### 12.1. Túnel VPN: Wireguard saliente vía gluetun (cero exposición a internet)

Si el operador no quiere abrir `51413/tcp+udp` en el router (o no puede — IP CGNAT, política del ISP), el patrón habitual es enrutar **todo** el tráfico de Transmission a través de un proveedor VPN (Mullvad, ProtonVPN, AirVPN…) que sí dé port forwarding. El sidecar [`gluetun`](https://github.com/qdm12/gluetun) hace esto sin cambiar Transmission:

```yaml
services:
  vpn:
    image: qmcgaw/gluetun:v3
    container_name: vpn
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    environment:
      VPN_SERVICE_PROVIDER: mullvad
      VPN_TYPE: wireguard
      WIREGUARD_PRIVATE_KEY: ${MULLVAD_PRIVATE_KEY}
      WIREGUARD_ADDRESSES: ${MULLVAD_ADDRESS}
      SERVER_CITIES: madrid
      FIREWALL_VPN_INPUT_PORTS: ${TRANSMISSION_PEER_PORT}
    networks:
      - homelab
    healthcheck:
      test: ["CMD", "wget", "-qO-", "https://am.i.mullvad.net/connected"]
      interval: 30s

  transmission:
    # Igual que en §4, pero:
    # 1. Quitar el bloque `ports:` (los peers entran por gluetun).
    # 2. Quitar `networks:` y poner network_mode:
    network_mode: "service:vpn"
    depends_on:
      vpn:
        condition: service_healthy
```

Con esto:

- Transmission usa la pila TCP/IP de gluetun.
- El peer port se mapea en gluetun, no en el router del operador.
- Caddy ya no puede llegar por DNS (`http://transmission:9091`) porque Transmission no tiene su propia IP en `homelab` — está en la stack de gluetun. Solución: Caddy → `http://vpn:9091` (gluetun expone los puertos del contenedor que comparte stack).

> **No es por defecto** porque (a) requiere un proveedor VPN de pago, (b) añade una dependencia más, (c) el homelab ya restringe acceso al servicio web por Authelia. Pero es la opción correcta para CGNAT o privacidad estricta.

### 12.2. Notificaciones a Telegram al terminar un torrent

Transmission soporta `script-torrent-done-filename`. Crear un script que llame a la Bot API de Telegram:

```bash
sudo tee /mnt/hd2t/services/transmission/config/torrent-done.sh > /dev/null <<'EOF'
#!/bin/sh
TG_BOT="${TELEGRAM_BOT_TOKEN}"
TG_CHAT="${TELEGRAM_CHAT_ID}"
curl -s -X POST "https://api.telegram.org/bot${TG_BOT}/sendMessage" \
  -d chat_id="${TG_CHAT}" \
  -d text="✅ Transmission: ${TR_TORRENT_NAME} ($((TR_TORRENT_BYTES_DOWNLOADED / 1024 / 1024)) MB) terminado."
EOF
sudo chmod +x /mnt/hd2t/services/transmission/config/torrent-done.sh
```

En `settings.json`:

```jsonc
"script-torrent-done-enabled": true,
"script-torrent-done-filename": "/config/torrent-done.sh"
```

Las variables `TELEGRAM_BOT_TOKEN` y `TELEGRAM_CHAT_ID` se añaden al `.env` y al `environment:` del compose.

### 12.3. RSS auto-add con `transmission-rss`

Para feeds que Sonarr/Radarr no cubren (releases puntuales, hilos de un grupo concreto):

```yaml
  transmission-rss:
    image: haugene/transmission-rss
    environment:
      TRANSMISSION_HOST: transmission
      TRANSMISSION_PORT: 9091
      TRANSMISSION_USERNAME: ${TRANSMISSION_RPC_USERNAME}
      TRANSMISSION_PASSWORD: ${TRANSMISSION_RPC_PASSWORD}
    volumes:
      - /mnt/hd2t/services/transmission-rss/config.yml:/etc/transmission-rss.conf:ro
    networks:
      - homelab
    depends_on:
      transmission:
        condition: service_healthy
```

### 12.4. Hooks pre-/post-add para clasificar por categorías más finas

Sonarr/Radarr ya gestionan TV/cine. Para series de anime, podcasts, audiolibros torrenteados o libros, escribir un script en `script-torrent-done-filename` que mueva a la subcarpeta correcta de `/mnt/hd2t/media/` según el nombre:

```sh
case "$TR_TORRENT_NAME" in
  *anime*) dest=/downloads/complete/anime ;;
  *)       dest=/downloads/complete ;;
esac
mv "$TR_TORRENT_DIR/$TR_TORRENT_NAME" "$dest/"
```

Riesgo: rompe el seeding (Transmission ya no encuentra el fichero en `download-dir`). Mejor patrón: dejar a Sonarr/Radarr/Audiobookshelf leer de `complete/` con sus reglas y **no** mover desde un hook.

### 12.5. Acceso solo desde Tailscale (sin LAN)

Si el operador no quiere `transmission.lan` accesible en LAN (modelo "trabajo solo desde Tailscale"), eliminar el bloque `transmission.{$LAN_DOMAIN}` del `Caddyfile` y dejar solo el de Tailscale (§6.6). El stack interno sigue funcionando (Sonarr/Radarr lo ven por nombre).

### 12.6. Quitar Authelia para uso solo en LAN cableada confiada

No recomendado. Si el operador insiste:

```caddy
transmission.{$LAN_DOMAIN} {
    import lan_internal_tls
    import security_headers
    # forward_auth http://authelia:9091 ...   ← comentado
    reverse_proxy http://transmission:9091
}
```

La auth nativa de Transmission queda como única defensa. Es HTTP Basic y carece de lockout — un atacante en la LAN puede hacer brute-force ilimitado al `rpc-password`. Por eso Authelia es el default.

### 12.7. Subir el límite de upload (operador con conexión simétrica de fibra)

Editar `speed-limit-up` en `settings.json` (§7.2). 8192 KB/s (8 MB/s) es lo máximo que el homelab tolera sin notarse en streaming Jellyfin + videollamadas. Por encima de eso, valorar QoS en el router.

### 12.8. Activar IPv6 para los peers

Transmission soporta IPv6 nativo. Requiere:

1. El host tiene `/64` IPv6 ruteado del ISP (Telefónica/Orange/Movistar lo dan; Vodafone variable).
2. El bridge de Docker `homelab` con `enable_ipv6: true` (cambio en [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §4.1).
3. El router permite `51413/tcp+udp` también por IPv6.

Es opt-in porque la mayoría de ISPs domésticos en España todavía dan IPv6 inestable.

---

## Referencias

- Documentación oficial Transmission: https://transmissionbt.com/
- Wiki upstream (settings.json): https://github.com/transmission/transmission/blob/main/docs/Editing-Configuration-Files.md
- Imagen LinuxServer.io: https://docs.linuxserver.io/images/docker-transmission/
- Releases LSIO: https://github.com/linuxserver/docker-transmission/releases
- API RPC (especificación): https://github.com/transmission/transmission/blob/main/docs/rpc-spec.md
- Watchtower (política del homelab): [`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md)
- Caddy (reverse proxy): [`../03-red/04-caddy.md`](../03-red/04-caddy.md)
- Authelia (SSO + 2FA): [`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md)
- Borgmatic (backup): [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md)
- Estructura de directorios: [`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md)
- Prowlarr (indexadores): [`./02-prowlarr.md`](./02-prowlarr.md)
- Sonarr (TV): [`./03-sonarr.md`](./03-sonarr.md)
- Radarr (cine): [`./04-radarr.md`](./04-radarr.md)
- gluetun (VPN saliente): https://github.com/qdm12/gluetun
- Blocklists Naunter: https://github.com/Naunter/BT_BlockLists
