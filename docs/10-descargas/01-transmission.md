# Transmission

## Descripción

Cerradas las Fases 0–9, el homelab tiene sistema base, Docker, red local resuelta por Pi-hole, reverse proxy con TLS interno (Caddy) más `tailscale cert` para tailnet, VPN mesh (Tailscale), SSO con Authelia, monitorización (Prometheus + Grafana + Uptime Kuma + Dozzle), almacenamiento personal (Nextcloud, Samba, Syncthing, MinIO), copias de seguridad (Borgmatic), domótica (Home Assistant + Mosquitto + Zigbee2MQTT + Node-RED) y los servidores de catalogación multimedia (Jellyfin, Navidrome, Audiobookshelf, Calibre-Web, Stash). Lo que falta es el **flujo de adquisición**: cómo los ficheros llegan a `/mnt/hd2t/media/`. Esa es la motivación de la Fase 10.

Este documento despliega **Transmission** (en adelante, TR), el cliente BitTorrent del homelab. Su rol concreto:

1. **Descargar `.torrent` y `magnet:`** que le envíen Sonarr (`03-sonarr.md`) y Radarr (`04-radarr.md`) vía API RPC, y opcionalmente que el operador deje caer en el directorio *watch* (`/mnt/hd2t/downloads/watch/`).
2. **Mantener seeding** durante un tiempo razonable tras completar (cumplir ratio mínimo del tracker, devolver al swarm) y luego **mover/poner a disposición** los ficheros completos en `/mnt/hd2t/downloads/complete/`, donde Sonarr/Radarr los recogerán y harán **hardlink** a `/mnt/hd2t/media/{tv,movies}/` (sin duplicar bytes; ver "Decisión: hardlinks vs copy" abajo).
3. **Exponer una UI web** (`https://transmission.${DOMAIN_LAN}/`) para diagnóstico humano: ver progreso, pausar, ajustar prioridades, revisar errores de tracker. El uso diario lo lleva el `*arr` stack; la UI es el panel de avería.
4. **Hacer de "transporte" sin opiniones**: no decide qué descargar (eso es Sonarr/Radarr a partir de los indexadores que les sirve Prowlarr en `02-prowlarr.md`), no toca nombres de fichero (eso es Sonarr/Radarr durante el import), no maneja subtítulos. Solo **bytes** entrando y saliendo.

Lo que este documento **no** decide:

- **Qué se descarga**: lo decide el catálogo de Sonarr/Radarr a partir de los `release profiles` y `quality profiles` que se documentan en `03-sonarr.md` y `04-radarr.md`. Aquí solo se pone el motor.
- **Indexadores**: los gestiona Prowlarr (`02-prowlarr.md`) y los inyecta en Sonarr/Radarr; TR los desconoce.
- **Cliente alternativo (qBittorrent, Deluge)**: descartado a favor de Transmission por las razones de "Decisión: cliente" abajo.
- **Usenet (NZBGet, SABnzbd)**: el homelab actual no tiene cuenta de Usenet, así que no se despliega ningún downloader NZB. Reabrible si en algún momento se contrata un proveedor; encajaría como sidecar de la Fase 10 con su propio doc (`05-sabnzbd.md`).
- **Routing del tráfico de torrent por VPN comercial** (Mullvad, ProtonVPN vía `gluetun`): el homelab está pensado para uso doméstico con conexión residencial. Existe una sección "Decisión: tráfico por VPN" más abajo donde se discute la disyuntiva y se documenta el camino de upgrade. **Por defecto no se enruta por VPN comercial**; se aplican mitigaciones a nivel de tracker (privados antes que públicos) y de cifrado de peers.
- **Apertura de puertos en el router (port-forwarding)**: el homelab es estricto en "no abrir puertos" (alcance LAN+tailnet). Transmission opera **sin port-forwarding**, en modo *outbound only*. Eso reduce velocidad de inicio del enjambre y ratio en algunos trackers privados, pero es el coste que se acepta por la política de seguridad. Si un tracker privado exigiera puerto abierto, se trata como excepción y se documenta en la wiki interna (no en este doc).
- **Detección y filtro de IPs maliciosas**: se carga una blocklist mantenida (`level1` de iblocklist) en TR; no se monta `vuze-blocklist`/PeerBlock externo.

Cuando este documento se haya aplicado, el operador puede:

- Abrir `https://transmission.${DOMAIN_LAN}/` desde la LAN (con CA interna instalada, protegida por Authelia 2FA) o `https://transmission.${DOMAIN_TS}/` desde el tailnet, autenticarse con Authelia y ver la UI de Transmission Web.
- Dejar caer un `.torrent` en `/mnt/hd2t/downloads/watch/` y verlo aparecer en la UI con el estado *Downloading*, escribiendo en `/mnt/hd2t/downloads/incomplete/<name>.part`.
- Ver el fichero terminado en `/mnt/hd2t/downloads/complete/<name>/`, accesible para el grupo `media` (1100), listo para que Sonarr o Radarr lo importen.
- Confirmar que la endpoint RPC `http://transmission:9091/transmission/rpc` está accesible **solo** desde la red Docker `homelab`, autenticada con usuario+password generados localmente, lista para que Sonarr y Radarr la consuman en sus respectivos docs.
- Tener los límites de velocidad y peers ajustados al ancho de banda doméstico, con un esquema de *alt-speed* (modo turtle) programado en horario de uso intensivo de la LAN para no saturar streaming en otros dispositivos.
- Tener `/mnt/hd2t/apps/transmission/config/` respaldado por Borgmatic (settings, resume files, blocklist), excluyendo lo regenerable.

> **Recordatorio de alcance**: TR es **solo LAN + tailnet** para su UI/RPC. El tráfico de torrent (TCP/UDP a peers de internet) sí sale al exterior porque BitTorrent es por naturaleza P2P; lo que **no** ocurre es que ningún peer pueda iniciar conexión entrante (no hay port-forwarding). Esto se asume y se vive con ello.

---

## Requisitos Previos

- **Fase 0–1** completas: discos `hd2t` montado en `/mnt/hd2t`, grupo `media` con GID `1100`, usuario `homelab` (UID 1000) miembro del grupo, estructura `/mnt/hd2t/downloads/{incomplete,complete,watch}` con owner `homelab:media` y modo `2770` (setgid). Ver `01-sistema/04-estructura-directorios.md`.
- **Fase 2** completa: Docker Engine + Compose v2; red `homelab` en `172.30.10.0/24`; convenciones `stacks/<svc>/`; `.env` global con `TZ=Europe/Madrid`, `PUID=1000`, `PGID=1000`, `DOMAIN_LAN=lan`, `DOMAIN_TS` si aplica.
- **Fase 3** completa, en particular:
  - Pi-hole con el comodín `address=/lan/192.168.1.10` (cubre `transmission.${DOMAIN_LAN}` automáticamente).
  - Caddy desplegado y los snippets `(lan_tls)`, `(security_headers)`, `(healthcheck)`, `(authelia_two_factor)` en `Caddyfile`.
  - Tailscale operativo y, si se quiere acceso por `transmission.${DOMAIN_TS}`, `tailscale cert` ya emitiendo (`03-red/05-tailscale.md`).
- **Fase 4** completa: Authelia desplegado con 2FA; TR se protege con `forward_auth` (la UI es de uso humano ocasional). El **endpoint RPC** se exonera por path para no romper la integración con Sonarr/Radarr (ver "Decisión: autenticación" abajo).
- **Fase 7** opcional pero recomendable: Borgmatic operativo, para añadir `/mnt/hd2t/apps/transmission/config` al inventario de fuentes. La biblioteca de descargas (`/mnt/hd2t/downloads/`) **se excluye** del backup (regenerable, voluminoso, efímero).
- Ancho de banda doméstico conocido (Mbps de subida y bajada nominales, p. ej. 600/600 simétrico FTTH típico en España). Se usa para fijar límites en "Configuración".
- Operador con la **CA interna instalada** en el navegador del puesto de operación (la UI es de operador, no de cliente final, así que con un navegador basta; no hay app móvil para Transmission que merezca configurar).

Comprobaciones rápidas:

```bash
# La red Docker compartida existe y Caddy/Authelia están sanos
docker network inspect homelab --format '{{.Name}}' | grep -q '^homelab$' && echo ok
docker ps --filter name=caddy --filter name=authelia --format '{{.Names}} {{.Status}}'

# transmission.lan resuelve al IP de la Pi (gracias al comodín de Pi-hole)
dig +short transmission.lan @192.168.1.2
# 192.168.1.10

# Estructura de descargas correcta
getent group media
# media:x:1100:homelab
stat -c '%a %U:%G %n' /mnt/hd2t/downloads /mnt/hd2t/downloads/{incomplete,complete,watch}
# 2770 homelab:media /mnt/hd2t/downloads
# 2770 homelab:media /mnt/hd2t/downloads/incomplete
# 2770 homelab:media /mnt/hd2t/downloads/complete
# 2770 homelab:media /mnt/hd2t/downloads/watch

# downloads/ y media/ están en el MISMO filesystem (requisito para hardlinks)
stat -c '%m' /mnt/hd2t/downloads/complete /mnt/hd2t/media/movies
# /mnt/hd2t
# /mnt/hd2t

# Espacio en hd2t (descargas en curso + media)
df -h /mnt/hd2t | awk 'NR==2 {print $4 " libres"}'
```

---

## Decisión: cliente — Transmission, no qBittorrent ni Deluge

| Cliente | Pros | Contras | Veredicto |
|---|---|---|---|
| **Transmission** | RAM extremadamente baja (~30–80 MiB), demonio estable, RPC JSON simple y maduro (Sonarr/Radarr lo soportan desde hace una década), sin dependencias gráficas, configuración íntegramente vía `settings.json` (versionable). | UI web minimalista, sin gestión de categorías nativa (los `*arr` no la necesitan), blocklist solo `level1`. | **Aceptado**. |
| qBittorrent | UI web rica, categorías, etiquetas, buscador integrado, gestión por contenedor de las versiones recientes mejorada. | Más RAM y CPU (~150–300 MiB en idle), histórico de issues con la API en versiones de transición (v4 → v5 rompió endpoints), licencia es libre pero el proyecto ha tenido cambios de gobernanza. En Pi 5 funciona bien, pero la huella es 3× la de TR. | Descartado por huella. |
| Deluge | RPC `daemon`+`thinclient` muy capaz, plugins, comunidad activa. | Modelo de "thin client + daemon" complica la integración detrás de un reverse proxy con Authelia (dos endpoints). Plugins suelen ser la única vía para funciones cotidianas (auto-remove, label). | Descartado por complejidad operativa. |
| rTorrent + ruTorrent | Ligerísimo, scriptable. | Configuración es un dialecto propio (`.rtorrent.rc`), ruTorrent no se mantiene tan activamente. | Descartado por mantenibilidad. |

**Decisión**: Transmission. Es el "lento y aburrido" del catálogo, justo lo que se quiere de un downloader que solo tiene que mover bytes y no estorbar.

> **Cambiar de opinión**: si en el futuro se decide migrar a qBittorrent (porque, por ejemplo, se quiere `category` para separar torrents de Sonarr y Radarr a nivel de cliente), la migración es relativamente indolora — Sonarr/Radarr soportan ambos como *download client* y se puede correr el nuevo en paralelo durante el cambio.

---

## Decisión: imagen — LinuxServer.io

Transmission tiene varias imágenes públicas relevantes:

| Imagen | Mantenedor | Tag | Pros | Contras |
|---|---|---|---|---|
| `lscr.io/linuxserver/transmission` | LinuxServer.io | `:4.0.6` (multi-arch arm64) | UID/GID configurables, patrón homogéneo con Jellyfin/Audiobookshelf/Calibre-Web/Stash de Fase 9 y con el resto de la Fase 10 (Prowlarr/Sonarr/Radarr también LSIO), variables `USER`/`PASS`/`WHITELIST` para credenciales RPC, scripts s6-overlay para arranque y reset de permisos. | Una capa entre upstream y operador. |
| `linuxserver/transmission` | (mirror) | igual que el anterior | Idéntica. | Misma. |
| Imagen comunitaria de `dperson/transmission` | dperson | varios | Histórico, muy parametrizada por entorno. | Mantenimiento esporádico. |
| Compilar TR desde Debian dentro de un Dockerfile propio | — | — | Control absoluto. | Mantenimiento propio. Innecesario. |

**Decisión**: `lscr.io/linuxserver/transmission:4.0.6`.

Razones:

- **Coherencia con todo el catálogo Fase 9 + Fase 10**: misma forma (`PUID`/`PGID`/`UMASK`/`TZ`), misma idea de bind mounts, misma s6-overlay debajo.
- **Pin de versión completa** (no `latest`, no `4.0`): Transmission 4 introdujo cambios de protocolo y formato de resume; pin estricto evita sorpresas. Watchtower NO actualiza automáticamente este contenedor.

Actualizaciones: `docker compose pull && up -d` tras leer el changelog de Transmission. La etiqueta de Watchtower deja explícito el opt-out:

```yaml
labels:
  com.centurylinklabs.watchtower.enable: "false"
```

---

## Decisión: networking — bridge `homelab` (sin host, sin VPN egress)

| Modo | Pros | Contras | Veredicto |
|---|---|---|---|
| **Bridge `homelab`** (sin `ports:`) | TR en `172.30.10.X`. Caddy hace `reverse_proxy http://transmission:9091`. RPC interno entre `transmission`, `sonarr`, `radarr` por DNS de Docker. | Sin port-forwarding desde el router al contenedor; los peers entrantes no pueden iniciar conexión. *Outbound-only* funciona pero con menor velocidad de arranque y ratio. | **Aceptado**. |
| `network_mode: host` | TR comparte la pila de red de la Pi: `:9091/tcp` (UI), `:51413/tcp+udp` (peers) en `192.168.1.10`. uPnP/NAT-PMP del router puede abrir puerto si está habilitado. | Rompe el patrón del bridge, complica `Caddyfile`, expone `:9091` y `:51413` al host (firewall debe cubrirlos). | Descartado. |
| Egress por VPN (`gluetun` sidecar) con `network_mode: service:gluetun` | TR sale por VPN comercial (Mullvad/Proton), kill-switch automático, port-forwarding del proveedor para peers entrantes. | Suscripción mensual al proveedor VPN, mantenimiento de un stack más, latencia añadida, integración con `*arr` exige que también pasen el HTTP a través de la red del sidecar o que TR exponga `:9091` al bridge `homelab` de otra forma. **Sobrecoste y sobreingeniería para el alcance del homelab actual**. | Descartado por defecto. Reabrible (ver más abajo). |

Resultado: **bridge `homelab`**, sin port-forwarding. Implicaciones:

1. **Sin `ports:`** publicados al host: ni `:9091/tcp` ni `:51413/tcp/udp`. La UI se accede por Caddy (`https://transmission.lan`); Sonarr/Radarr le hablan al RPC vía DNS interna (`http://transmission:9091`).
2. **Peer port** (`51413` por defecto en `settings.json`): se expone solo dentro del bridge. **No se publica al host** y por tanto no llega tráfico entrante desde internet. TR funciona en modo *outbound only*: inicia conexiones a peers que sí están abiertos. La práctica totalidad de los swarms públicos tienen suficiente diversidad de peers conectables; el coste práctico es velocidad de arranque más lenta y un ratio teóricamente menor en trackers privados que penalicen no-seedability.
3. **uPnP/NAT-PMP**: se **deshabilita** explícitamente en `settings.json` (`port-forwarding-enabled: false`) por las dos razones: (a) el contenedor está en bridge, no podría abrir puerto en el router aunque éste lo soportara, y (b) el homelab no abre puertos al exterior por política.
4. **Sonarr/Radarr** se comunican con TR usando `Host: transmission, Port: 9091` (nombres del bridge), sin necesidad de credenciales de red distintas a las RPC.

### Decisión: tráfico por VPN — postergado

La discusión completa, archivada para retomar:

- En España (jurisdicción del homelab) la mensajería ISP por copyright es esporádica pero existe; algunos trackers públicos están vigilados por agencias antipiratería.
- La forma "limpia" de aislar el tráfico es **`gluetun` como sidecar** y meter TR en `network_mode: service:gluetun`, con kill-switch (sin VPN, sin tráfico).
- Coste: una suscripción VPN (~5 €/mes) y un stack más que mantener. Beneficio: anonimato del tráfico y, en proveedores que lo permiten (Mullvad, AirVPN, ProtonVPN Plus), port-forwarding desde el lado VPN.
- **Política actual**: dado que la Fase 10 no exige inicialmente trackers privados restrictivos, se acepta el modo *outbound-only* sin VPN. Si se observa que el ratio en swarms es deficiente o si aparece preocupación legal concreta, se documenta como ampliación: `docs/10-descargas/05-vpn-egress.md` con `gluetun` y se reconfigura este compose para depender de él.

---

## Decisión: hardlinks vs copy — atomic moves dentro de hd2t

Sonarr/Radarr trabajan así con un torrent finalizado:

1. TR pasa el torrent a `/downloads/complete/<name>/`.
2. Sonarr/Radarr (Fase 10) detectan el evento por su API hablando con TR.
3. Sonarr/Radarr quieren **mover** el fichero a `/media/{tv,movies}/<rename>/` aplicando su esquema de nombres y dejar TR siguiendo seedeando el original durante el ratio mínimo.

Hay tres estrategias:

| Estrategia | Cómo | Pros | Contras |
|---|---|---|---|
| **Copy** | Sonarr copia y luego borra del origen tras el ratio. | Simple. | Duplica bytes durante el seeding, IOPS doble en hd2t. |
| **Move** | Sonarr mueve, TR pierde la referencia y empieza a re-descargar para seguir seedeando o lo abandona. | Cero duplicación. | Rompe seeding. Tracker privado puede penalizar. |
| **Hardlink** | Sonarr crea un hardlink (mismo inodo, dos nombres) en `/media/...`. TR sigue seedeando del original; el reproductor lee del hardlink. Cuando TR borra el fichero original tras el ratio, el inodo persiste por la otra referencia (el hardlink). Cuando se borre el hardlink, libera espacio. | Cero duplicación, seeding intacto, atómico. | **Solo funciona si origen y destino están en el MISMO filesystem** y ambos son accesibles para el mismo UID/GID. |

**Decisión**: **hardlink**. Implicaciones:

1. **`/mnt/hd2t/downloads/` y `/mnt/hd2t/media/` deben estar en el mismo filesystem** (lo están: ambos en hd2t, ext4). Comprobación: `stat -c '%m' /mnt/hd2t/downloads/complete /mnt/hd2t/media/movies` debe devolver la misma raíz.
2. **Permisos compartidos**: ambos directorios viven con grupo `media` (1100) y modo `2770` (setgid). Sonarr y Radarr correrán con `PUID=1000, PGID=1000, group_add: [1100]` (igual que TR), por lo que pueden leer en `complete/` y escribir en `media/`.
3. **El bind mount dentro del contenedor de TR es `/downloads`** (no `/downloads/complete` y `/downloads/incomplete` por separado). De lo contrario, TR vería los dos paths como puntos de montaje distintos *dentro del contenedor* y no podría hacer el move atómico de `incomplete → complete` (lo haría como copy + delete y rompería ratio en algunos clientes). En Sonarr/Radarr el mismo razonamiento: deben montar `/downloads` igual y `/media`. Ver `03-sonarr.md` y `04-radarr.md` cuando se escriban.
4. **Política de retención de TR**: completar → mover a `complete/` → seguir seedeando hasta cumplir `seedRatioLimit` (1.0 por defecto) o `idle-seeding-limit` (30 min sin actividad de peers, lo que ocurra primero) → borrar fichero. El hardlink en `/media/` sobrevive al borrado.

> **Si en el futuro se quiere dividir descargas entre hd2t (operación) y hd5t (almacén)**: rompería los hardlinks. Hay que mantener la regla de oro: **descargas y biblioteca en el mismo filesystem**. Stash en `/mnt/hd5t/` es un mundo aparte y no comparte downloader con TR.

---

## Decisión: autenticación — Authelia delante de la UI, RPC con bypass por path

Transmission tiene autenticación HTTP Basic nativa (`USER`/`PASS`). Es suficiente para la integración con Sonarr/Radarr, pero la UI web detrás del Caddy debería aprovechar 2FA del homelab.

| Path | Quién accede | Estrategia |
|---|---|---|
| `/transmission/web/...` (UI) | Operador humano desde navegador | **Authelia 2FA** (`forward_auth`). Tras superar Authelia, Caddy reenvía con HTTP Basic ya resuelto vía `header_up Authorization "Basic ..."` (credenciales TR fijas y rotables, ver `.env`). |
| `/transmission/rpc` (API JSON) | Sonarr y Radarr (otros contenedores en el bridge `homelab`) | **Bypass de Authelia**: el `forward_auth` no se aplica a este path porque Sonarr/Radarr no soportan el flujo cookie de Authelia. La autenticación es la **HTTP Basic nativa** de TR (`USER`/`PASS`), comprobada por TR mismo. |
| `/transmission/upload` (subida `.torrent` desde la UI) | Operador desde la UI ya autenticado por Authelia | Sigue la misma regla que la UI (cubierto por la regex de la UI). |

En la práctica, **Sonarr y Radarr no pasan por Caddy en absoluto**: hablan directamente al bridge `homelab` con `http://transmission:9091`. Por tanto Authelia ni siquiera entra en la ruta. La razón de mantener el bypass por path en el `Caddyfile` es por si algún día se quiere que un cliente externo (en el tailnet, p. ej.) llame al RPC sin pasar por Authelia. Reabrible.

> **Credenciales TR fijas y rotables**: aunque la red `homelab` ya es interna, se exige `RPC-AUTH-REQUIRED=true` para defensa en profundidad. Las credenciales viven en `stacks/transmission/.env` (chmod `0600`, no commit) y se inyectan al contenedor por env. Sonarr/Radarr leen las mismas en sus respectivos `.env` cuando se desplieguen (Fase 10).

---

## Decisión: dónde viven los datos y permisos

Tres tipos de datos:

| Tipo | Dónde | Owner:Group | Modo | Observaciones |
|---|---|---|---|---|
| **Configuración + estado** (`config/`): `settings.json`, `resume/*.resume`, `torrents/*.torrent` (cache de metainfo), `blocklists/`, `stats.json`. | `/mnt/hd2t/apps/transmission/config/` | `homelab:homelab` (`1000:1000`) | `0750` | LSIO escribe como `PUID:PGID`. Crítico para backup (sin esto se pierde el estado del swarm: torrents en curso, ratio, prioridades). |
| **Descargas en curso y completas** | `/mnt/hd2t/downloads/{incomplete,complete}/` | `homelab:media` (`1000:1100`) | `2770` (setgid) | TR escribe como `homelab:media` gracias a `group_add: [1100]` y `UMASK=002` (ver más abajo). |
| **Watch directory** | `/mnt/hd2t/downloads/watch/` | `homelab:media` | `2770` | TR lee `.torrent`/`.magnet` y los borra tras encolar. |

Bind mounts elegidos:

```yaml
volumes:
  - /mnt/hd2t/apps/transmission/config:/config
  - /mnt/hd2t/downloads:/downloads          # punto único: incomplete + complete + watch
```

Razones:

- Volumen Docker nombrado para `config/` queda descartado: 1–5 GiB en microSD (raíz Docker) es absurdo cuando hd2t está disponible.
- **Un solo bind mount `/downloads`** (en lugar de tres separados): garantiza que `mv` interno entre `incomplete/` y `complete/` sea atómico (mismo inodo, mismo punto de montaje desde el punto de vista del kernel del contenedor).
- **`UMASK=002`** (en lugar del `022` global): ficheros nuevos en `complete/` salen con grupo escribible (`0664` ficheros, `0775` directorios). Necesario para que Sonarr/Radarr (mismo UID 1000, mismo grupo 1100) puedan luego operar (renombrar, hardlink) sin pelearse con permisos. Si se dejara `022`, los `.mkv` recién bajados serían `0644` y Sonarr no podría modificarlos en place ni borrarlos al limpiar.

---

## Stack: `stacks/transmission/`

### Layout en disco

| Ruta | Soporte | Contenido |
|---|---|---|
| `stacks/transmission/docker-compose.yml` | microSD (git) | Stack (servicio `transmission`). |
| `stacks/transmission/.env.example` | microSD (git) | Plantilla de credenciales RPC. |
| `stacks/caddy/conf.d/10-transmission.caddy` | microSD (git) | Drop-in del bloque LAN+tailnet para `transmission.${DOMAIN_LAN}` y `transmission.${DOMAIN_TS}`. |
| `/mnt/hd2t/apps/transmission/config/` | hd2t | `settings.json`, `resume/`, `torrents/`, `blocklists/`. Owner `homelab:homelab`, modo `0750`. |
| `/mnt/hd2t/downloads/incomplete/` | hd2t | Descargas en curso. Owner `homelab:media`, modo `2770`. |
| `/mnt/hd2t/downloads/complete/` | hd2t | Descargas terminadas. Owner `homelab:media`, modo `2770`. |
| `/mnt/hd2t/downloads/watch/` | hd2t | Drop folder para `.torrent`. Owner `homelab:media`, modo `2770`. |

### `stacks/transmission/docker-compose.yml`

```yaml
# Transmission — cliente BitTorrent del homelab.
# Documentado en docs/10-descargas/01-transmission.md.
#
# Networking: bridge homelab. Caddy hace reverse proxy hacia transmission:9091.
# Peer port (51413) NO se publica al host: outbound-only, sin port-forwarding.

name: transmission

networks:
  homelab:
    external: true

services:
  transmission:
    image: lscr.io/linuxserver/transmission:4.0.6
    container_name: transmission
    hostname: transmission
    restart: unless-stopped

    networks:
      - homelab

    # NO se publican puertos al host. La UI va por Caddy (https://transmission.lan)
    # y el RPC lo consumen Sonarr/Radarr dentro del bridge homelab.
    # ports:
    #   - "9091:9091"   # NO: comprometería el patrón de Caddy + Authelia.
    #   - "51413:51413" # NO: sin port-forwarding por política del homelab.

    environment:
      TZ: ${TZ}
      PUID: ${PUID}              # 1000 (homelab)
      PGID: ${PGID}              # 1000 (homelab)
      UMASK: "002"               # ficheros 0664, dirs 0775 → grupo media escribe
      USER: ${TRANSMISSION_RPC_USER}
      PASS: ${TRANSMISSION_RPC_PASS}
      # WHITELIST: la red Docker homelab. TR la valida ANTES que la auth Basic.
      # Si Sonarr/Radarr u otros clientes legítimos se mueven a otra red,
      # añadirlos aquí (separados por coma, soporta wildcards).
      WHITELIST: "127.0.0.1,172.30.10.*"

    # group_add para que el contenedor escriba en /downloads como grupo media.
    group_add:
      - "1100"   # media (creado en 01-sistema/04-estructura-directorios.md)

    volumes:
      - /mnt/hd2t/apps/transmission/config:/config
      # Punto único de montaje de descargas (incomplete + complete + watch).
      # CRÍTICO: NO desglosar en tres mounts, rompe el move atómico interno
      # incomplete → complete. Ver "Decisión: hardlinks vs copy" en el doc.
      - /mnt/hd2t/downloads:/downloads
      - /etc/localtime:/etc/localtime:ro

    healthcheck:
      # /transmission/web responde 401 sin auth: lo importante es que TR esté
      # escuchando. 401 cuenta como "alive" usando -o /dev/null y --fail-with-body
      # no aplicado: comprobamos con código != 000.
      test:
        - CMD-SHELL
        - >
          curl -fsS -o /dev/null -w '%{http_code}' http://127.0.0.1:9091/transmission/web/ |
          grep -E '^(200|401)$' >/dev/null
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 30s

    labels:
      homelab.role: "downloader"
      homelab.backup: "true"
      # Watchtower NO actualiza automáticamente: el tag es completo (4.0.6)
      # y los bumps de Transmission requieren leer release notes (cambios
      # de protocolo en 4.x).
      com.centurylinklabs.watchtower.enable: "false"
```

> **Sobre `WHITELIST`**: la imagen LSIO la traduce a `rpc-whitelist` y `rpc-whitelist-enabled: true` en `settings.json` al primer arranque. Es defensa en profundidad: incluso si la auth Basic fallara, solo IPs del bridge `homelab` (`172.30.10.0/24`) o `127.0.0.1` son aceptadas. El operador desde el navegador entra **vía Caddy**, así que la IP de origen vista por TR es la del contenedor `caddy` en el bridge — cubierta por la wildcard.

> **Sobre el peer port**: queda en `51413` por defecto (lo establece `settings.json`). Como no se publica al host, no es accesible desde fuera de la Pi. Se mantiene como un detalle interno; cambiarlo no aporta valor.

### `stacks/transmission/.env.example`

```bash
# stacks/transmission/.env.example
# Copiar a stacks/transmission/.env (chmod 0600) y rellenar.
#
# Las generales (TZ, PUID, PGID, DOMAIN_LAN, DOMAIN_TS) vienen del .env GLOBAL.

# Credenciales del RPC. Sonarr y Radarr usarán LAS MISMAS en sus .env
# cuando se desplieguen (Fase 10).
#
# Generación recomendada:
#   TRANSMISSION_RPC_USER=transmission
#   TRANSMISSION_RPC_PASS="$(openssl rand -base64 24)"
TRANSMISSION_RPC_USER=
TRANSMISSION_RPC_PASS=
```

### Drop-in de Caddy: `stacks/caddy/conf.d/10-transmission.caddy`

```caddy
# /etc/caddy/conf.d/10-transmission.caddy — bloques de Transmission.
# Documentado en docs/10-descargas/01-transmission.md.
#
# UI protegida por Authelia 2FA. Endpoint /transmission/rpc en bypass para
# permitir que clientes legítimos (Sonarr/Radarr) sigan funcionando si en
# algún momento se accediera vía Caddy en lugar de directamente al bridge.

# ---- Acceso LAN -----------------------------------------------------------
transmission.{$DOMAIN_LAN} {
    import lan_tls
    import security_headers
    import healthcheck

    # Bypass para el RPC: la integración con Sonarr/Radarr usa HTTP Basic
    # nativa de Transmission, no el flujo de Authelia.
    @rpc path /transmission/rpc /transmission/rpc/*
    handle @rpc {
        reverse_proxy http://transmission:9091
    }

    # UI humana: Authelia 2FA delante.
    handle {
        import authelia_two_factor
        reverse_proxy http://transmission:9091
    }
}

# ---- Acceso Tailscale -----------------------------------------------------
# Solo se materializa si DOMAIN_TS está definido (tailnet con tailscale cert).
transmission.{$DOMAIN_TS} {
    tls {
        get_certificate tailscale
    }
    import security_headers
    import healthcheck

    @rpc path /transmission/rpc /transmission/rpc/*
    handle @rpc {
        reverse_proxy http://transmission:9091
    }

    handle {
        import authelia_two_factor
        reverse_proxy http://transmission:9091
    }
}
```

### Crear directorios y desplegar

```bash
# Cargar variables globales en el shell (ver quirk Compose v2 en 02-estructura-compose.md)
cd /home/homelab/homelab
set -a; source .env; set +a

# 1) Verificar prerequisitos de estructura (Fase 1).
getent group media | grep -q '^media:x:1100:' || {
    echo "ERROR: grupo media (GID 1100) no existe. Aplicar 01-sistema/04-estructura-directorios.md."
    exit 1
}
for d in /mnt/hd2t/downloads/{incomplete,complete,watch}; do
    [ -d "$d" ] || { echo "ERROR: $d no existe."; exit 1; }
done

# 2) Crear directorios persistentes del servicio (idempotente).
sudo install -d -o homelab -g homelab -m 0750 /mnt/hd2t/apps/transmission
sudo install -d -o homelab -g homelab -m 0750 /mnt/hd2t/apps/transmission/config

# 3) Confirmar que downloads/ y media/ comparten filesystem (hardlinks).
[ "$(stat -c '%m' /mnt/hd2t/downloads/complete)" = \
  "$(stat -c '%m' /mnt/hd2t/media/movies)" ] \
  || { echo "ERROR: downloads y media en filesystems distintos."; exit 1; }

# 4) Generar credenciales RPC y crear .env.
cp stacks/transmission/.env.example stacks/transmission/.env
chmod 0600 stacks/transmission/.env
sed -i \
  -e "s|^TRANSMISSION_RPC_USER=$|TRANSMISSION_RPC_USER=transmission|" \
  -e "s|^TRANSMISSION_RPC_PASS=$|TRANSMISSION_RPC_PASS=$(openssl rand -base64 24)|" \
  stacks/transmission/.env

# 5) Materializar Caddy drop-in.
install -o homelab -g homelab -m 0644 \
    stacks/caddy/conf.d/10-transmission.caddy \
    /mnt/hd2t/apps/caddy/etc/conf.d/10-transmission.caddy

# 6) Levantar el stack.
docker compose \
    -f stacks/transmission/docker-compose.yml \
    --env-file stacks/transmission/.env \
    up -d

# 7) Recargar Caddy para que aplique el nuevo drop-in.
docker exec caddy caddy reload --config /etc/caddy/Caddyfile

# 8) Esperar healthy.
docker ps --filter name=transmission --format '{{.Names}} {{.Status}}'
# transmission   Up 30s (healthy)
```

---

## Configuración

Tras el primer arranque, TR genera `/mnt/hd2t/apps/transmission/config/settings.json` con valores por defecto. La imagen LSIO ya inyecta los esenciales (`rpc-username`, `rpc-password`, `rpc-whitelist`) desde las variables. El resto se ajusta **una vez**, deteniendo el contenedor (TR sobrescribe `settings.json` al apagarse limpiamente, así que editar en caliente puede perder cambios).

### Editar `settings.json`

```bash
docker compose -f stacks/transmission/docker-compose.yml stop transmission
sudo -u homelab "$EDITOR" /mnt/hd2t/apps/transmission/config/settings.json
docker compose -f stacks/transmission/docker-compose.yml start transmission
```

### Ajustes recomendados

Aplicar sobre el `settings.json` generado:

```json
{
  "alt-speed-down": 5000,
  "alt-speed-enabled": false,
  "alt-speed-time-begin": 1140,
  "alt-speed-time-day": 127,
  "alt-speed-time-enabled": true,
  "alt-speed-time-end": 1380,
  "alt-speed-up": 1500,
  "blocklist-enabled": true,
  "blocklist-url": "https://list.iblocklist.com/?list=bt_level1&fileformat=p2p&archiveformat=gz",
  "dht-enabled": true,
  "download-dir": "/downloads/complete",
  "download-queue-enabled": true,
  "download-queue-size": 5,
  "encryption": 2,
  "idle-seeding-limit": 30,
  "idle-seeding-limit-enabled": true,
  "incomplete-dir": "/downloads/incomplete",
  "incomplete-dir-enabled": true,
  "lpd-enabled": true,
  "peer-limit-global": 200,
  "peer-limit-per-torrent": 50,
  "peer-port": 51413,
  "peer-port-random-on-start": false,
  "pex-enabled": true,
  "port-forwarding-enabled": false,
  "queue-stalled-enabled": true,
  "queue-stalled-minutes": 30,
  "ratio-limit": 1.5,
  "ratio-limit-enabled": true,
  "rename-partial-files": true,
  "rpc-authentication-required": true,
  "rpc-bind-address": "0.0.0.0",
  "rpc-host-whitelist": "transmission,transmission.lan,transmission.*",
  "rpc-host-whitelist-enabled": true,
  "rpc-whitelist": "127.0.0.1,172.30.10.*",
  "rpc-whitelist-enabled": true,
  "scrape-paused-torrents-enabled": true,
  "script-torrent-done-enabled": false,
  "seed-queue-enabled": false,
  "speed-limit-down": 50000,
  "speed-limit-down-enabled": false,
  "speed-limit-up": 800,
  "speed-limit-up-enabled": true,
  "start-added-torrents": true,
  "trash-original-torrent-files": true,
  "umask": 2,
  "utp-enabled": true,
  "watch-dir": "/downloads/watch",
  "watch-dir-enabled": true
}
```

Justificación de los valores:

| Clave | Valor | Razón |
|---|---|---|
| `download-dir` / `incomplete-dir` | `/downloads/complete` / `/downloads/incomplete` | Ruta dentro del contenedor; en el host es `/mnt/hd2t/downloads/{complete,incomplete}`. |
| `incomplete-dir-enabled` | `true` | Mantiene los `.part` separados; cuando termina, TR los mueve atómicamente a `complete/` (mismo punto de montaje). |
| `watch-dir-enabled` | `true` | Permite encolar dejando un `.torrent` en `/mnt/hd2t/downloads/watch/`. |
| `trash-original-torrent-files` | `true` | Tras encolar desde el watch dir, TR borra el `.torrent` original. Sin esto, el watch se llena. |
| `encryption` | `2` (required) | Fuerza encriptación de protocolo. Algunos ISPs estranglan tráfico BitTorrent en claro; con cifrado obligatorio se evade el shaping. |
| `peer-limit-global` / `peer-limit-per-torrent` | `200` / `50` | Conservador para Pi 5: cada peer es una conexión TCP/UDP y un poco de RAM. 200 globales caben en el ancho de banda doméstico. |
| `dht-enabled`, `pex-enabled`, `lpd-enabled` | `true` | Diversidad de mecanismos de descubrimiento de peers. LPD (Local Peer Discovery) ayuda en LAN (poco probable que sirva, pero gratis). |
| `port-forwarding-enabled` | `false` | El homelab no abre puertos en el router. uPnP del contenedor no llegaría al router de todos modos por la red bridge. |
| `peer-port-random-on-start` | `false` | Reproducible. |
| `utp-enabled` | `true` | µTP (UDP) suaviza el impacto en el resto de tráfico LAN respecto a TCP estándar (algoritmo LEDBAT, cede ante latencia). |
| `speed-limit-up-enabled` + `speed-limit-up` | `true`, `800` (KiB/s) | **Crítico**: limitar la subida para no saturar el uplink doméstico (y dejar Jellyfin remoto, videollamadas, etc.). 800 KiB/s ≈ 6.4 Mbps, ajustar a ~80% del uplink real. |
| `speed-limit-down-enabled` | `false` | Bajada sin tope; si la línea es 600 Mbps no merece la pena. |
| `alt-speed-time-enabled` + `alt-speed-time-begin`/`end` | `true`, 19:00–23:00 (1140 y 1380 son minutos desde medianoche) | Modo "tortuga" automático en horario punta de TV/streaming familiar. `alt-speed-up: 1500` KiB/s ≈ 12 Mbps cap. |
| `ratio-limit` | `1.5` | Detener seeding tras subir 1.5× lo bajado. Suficiente para "devolver al swarm" sin perpetuar. Trackers privados que requieran ratios más altos: ajustar por torrent o subir el global. |
| `idle-seeding-limit` | `30` (min) | Tras 30 min sin peers conectados, parar seeding. Libera slots y ahorra IOPS. |
| `queue-stalled-minutes` | `30` | Si un torrent no progresa en 30 min, marcarlo como *stalled* y dejar paso a la cola. |
| `blocklist-url` | iblocklist `bt_level1` | Lista clásica de IPs antitrackers conocidas. Se actualiza cada vez que TR arranca. |
| `rpc-host-whitelist` | `transmission,transmission.lan,transmission.*` | Defensa contra DNS rebinding al RPC: TR rechaza requests cuyo `Host:` no esté en esta lista. Caddy reescribe `Host` con `header_up Host {host}` (ver Caddyfile), así que llegan `transmission.lan` y `transmission.<DOMAIN_TS>`. |
| `rpc-whitelist` | `127.0.0.1,172.30.10.*` | Solo IPs del bridge `homelab` y loopback. Caddy y Sonarr/Radarr están en la `172.30.10.0/24`. |
| `script-torrent-done-enabled` | `false` | No se ejecuta script post-descarga; Sonarr/Radarr hacen polling al RPC y son ellos quienes orquestan el import. Reabrible si en algún momento se quiere notificar a Telegram al terminar. |

> **Recordatorio**: tras editar `settings.json`, **arrancar** TR antes de tocar la UI. Cambios desde la UI (o por API) sobreescriben `settings.json` en el `stop`.

### Primer arranque y verificación

1. `https://transmission.${DOMAIN_LAN}/` → Authelia pide 2FA → al pasar, aparece la UI de Transmission Web (login Basic ya resuelto por Caddy).
2. Verificar en *Preferences → Network* que **Port forwarding está OFF** y *Listening port* es `51413`. El "Test Port" reportará "Closed" (esperado: no hay forwarding).
3. *Preferences → Bandwidth*: confirmar límite de subida (`800 KiB/s`) y horario alt-speed (`19:00–23:00`).
4. *Preferences → Peers*: blocklist activa, mostrando recuento de IPs (~150k–250k entradas en `level1`).
5. **Test funcional**: descargar un torrent legal (p. ej. el [`debian-XX.X.0-amd64-netinst.iso.torrent`](https://www.debian.org/CD/torrent-cd/) reciente). Comprobar que aparece en `/mnt/hd2t/downloads/incomplete/debian-...iso.part`, baja, y al terminar se mueve atómicamente a `/mnt/hd2t/downloads/complete/debian-...iso`. Borrar tras la prueba (clic derecho → *Delete with files*).
6. **Test del watch dir**: copiar un `.torrent` a `/mnt/hd2t/downloads/watch/` y verificar que TR lo recoge en <5 s y borra el original.
7. **Test del RPC desde otro contenedor**:
   ```bash
   docker run --rm --network homelab curlimages/curl \
     -u "$(grep ^TRANSMISSION_RPC_USER stacks/transmission/.env | cut -d= -f2):$(grep ^TRANSMISSION_RPC_PASS stacks/transmission/.env | cut -d= -f2)" \
     -H "X-Transmission-Session-Id: x" \
     http://transmission:9091/transmission/rpc
   # 409 + nuevo X-Transmission-Session-Id en respuesta = OK (es el handshake CSRF de TR).
   ```

### Integración con Sonarr/Radarr

**No se hace en este doc**. Es responsabilidad de `03-sonarr.md` y `04-radarr.md`, que añadirán Transmission como *download client* con:

- Host: `transmission`
- Port: `9091`
- URL Base: `/transmission/`
- Username/Password: las del `.env` de este stack (idénticas)
- Category: vacía (TR no las usa; los `*arr` separan por *root folder* de destino)
- Use SSL: **No** (es comunicación interna en el bridge `homelab`)
- Directory: `/downloads/complete` (compartido entre los tres contenedores como `/downloads`)

---

## Almacenamiento

Volúmenes y bind mounts:

| Mount en contenedor | Bind en host | Contenido | Tamaño esperado |
|---|---|---|---|
| `/config` | `/mnt/hd2t/apps/transmission/config` | `settings.json`, `resume/*.resume`, `torrents/*.torrent`, `blocklists/*.bin`, `stats.json` | 10–500 MiB (según número de torrents activos; cada `.resume` ronda KiB, las blocklists ~10 MiB cada una). |
| `/downloads` | `/mnt/hd2t/downloads` | `incomplete/*.part`, `complete/<name>/...`, `watch/*.torrent` | Variable. Pico: el tamaño del catálogo "en vuelo" antes de que Sonarr/Radarr lo importen y los hardlinks queden en `media/`. Reservar ≥50 GiB de margen. |
| `/etc/localtime` | `/etc/localtime:ro` | Zona horaria del host | KiB. Mantiene logs y horarios de alt-speed coherentes con el reloj del operador. |

Permisos:

- `/mnt/hd2t/apps/transmission/config/`: `homelab:homelab` `0750`. TR escribe como UID 1000.
- `/mnt/hd2t/downloads/{incomplete,complete,watch}/`: `homelab:media` `2770` (setgid). TR escribe ficheros como `homelab:media` `0664` (gracias a `UMASK=002`) y directorios como `0775`. Sonarr/Radarr (mismo UID:GID y mismo grupo) podrán mover, renombrar, hardlinkar y borrar.

Comprobación en cualquier momento:

```bash
# Ficheros recientes en complete/ deben ser legibles y borrables por homelab y por el grupo media
sudo -u homelab find /mnt/hd2t/downloads/complete -type f -newer /tmp -exec stat -c '%a %U:%G %n' {} \; | head
# 664 homelab:media /mnt/hd2t/downloads/complete/<name>/file.mkv

# El blocklist se ha cargado
ls -lh /mnt/hd2t/apps/transmission/config/blocklists/
```

---

## Backup

Política para Borgmatic (Fase 7) — fragmento a integrar en su `config.yaml`:

```yaml
# borgmatic — fragmento para Transmission
source_directories:
  - /mnt/hd2t/apps/transmission/config

exclude_patterns:
  # Blocklists son regenerables (TR las refresca al arrancar).
  - /mnt/hd2t/apps/transmission/config/blocklists
  # stats.json es estado de runtime; no merece la pena versionar.
  - /mnt/hd2t/apps/transmission/config/stats.json

# /mnt/hd2t/downloads/ NO se respalda nunca (regenerable, voluminoso).
```

Qué se respalda:

| Fichero | Por qué se incluye |
|---|---|
| `settings.json` | Estado completo de la configuración: límites, horarios, RPC, paths, blocklist URL, etc. Restaurarlo basta para reanudar TR como estaba. |
| `resume/*.resume` | Estado por torrent (piezas descargadas, prioridades, ratio acumulado). Sin esto, restaurar reabre los torrents desde cero. |
| `torrents/*.torrent` | Cache de metainfo. TR los recrea si se pierden, pero solo si la URL del tracker sigue viva. |
| `dht.dat`, `bandwidth-groups.json` | Estado del DHT y grupos de banda. Pequeños y útiles. |

Qué **no** se respalda:

| Fichero / dir | Por qué se excluye |
|---|---|
| `blocklists/*.bin` | Se regeneran al arrancar (TR descarga la URL en `blocklist-url`). 10–30 MiB que no aportan al backup. |
| `stats.json` | Métrica acumulada (bytes subidos/bajados de toda la vida). No es esencial. Si se pierde, vuelve a empezar desde cero. |
| `/mnt/hd2t/downloads/` | **Nunca**. La biblioteca multimedia se respalda como fuente externa (no es backup del homelab); las descargas en curso son por definición efímeras. |

Procedimiento de restauración (si se cae el config):

```bash
# 1) Detener TR y mover el config corrupto a un lado
docker compose -f stacks/transmission/docker-compose.yml stop transmission
sudo mv /mnt/hd2t/apps/transmission/config{,.broken-$(date +%F)}

# 2) Restaurar desde Borg
sudo borg extract /mnt/hd2t/backups/borg::ARCHIVO mnt/hd2t/apps/transmission/config

# 3) Reajustar permisos por si el extract los movió
sudo chown -R homelab:homelab /mnt/hd2t/apps/transmission/config
sudo chmod 0750 /mnt/hd2t/apps/transmission/config

# 4) Arrancar TR
docker compose -f stacks/transmission/docker-compose.yml start transmission
docker logs -f transmission
# Esperar "Loaded N torrents from disk".
```

Frecuencia recomendada en Borgmatic: la ya documentada en `07-backups/02-borgmatic.md` (diaria). El `config/` de TR es pequeño (decenas de MiB) y muy comprimible/deduplicable: el coste marginal en cada snapshot es cercano a cero.

---

## Referencias

- **Documentación oficial**: <https://github.com/transmission/transmission/wiki>
- **`settings.json` reference (todas las claves)**: <https://github.com/transmission/transmission/blob/main/docs/Editing-Configuration-Files.md>
- **RPC spec** (usada por Sonarr/Radarr): <https://github.com/transmission/transmission/blob/main/docs/rpc-spec.md>
- **Imagen Docker LinuxServer.io**: <https://docs.linuxserver.io/images/docker-transmission/>
- **Repositorio LSIO**: <https://github.com/linuxserver/docker-transmission>
- **Cambios de Transmission 4.x** (lectura obligada antes de subir versión): <https://github.com/transmission/transmission/releases>
- **Blocklist iblocklist `bt_level1`**: <https://www.iblocklist.com/list?list=bt_level1>
- **Hardlinks y `*arr` (TRaSH guides)**: <https://trash-guides.info/Hardlinks/Hardlinks-and-Instant-Moves/> — la referencia comunitaria sobre por qué importa el filesystem único; aplicable también aquí, aunque el homelab adopta una decisión simplificada (un solo bind `/downloads`).
- **Documentos hermanos en este repo**:
  - `01-sistema/04-estructura-directorios.md` (estructura `/mnt/hd2t/downloads/{incomplete,complete,watch}` y grupo `media`).
  - `03-red/04-caddy.md` (snippets `lan_tls`, `security_headers`, `healthcheck`, `authelia_two_factor`).
  - `04-seguridad/01-authelia.md` (regla `forward_auth` y mecanismo de bypass por path).
  - `07-backups/02-borgmatic.md` (políticas y rotación; aquí solo aporta el fragmento de fuentes/exclusiones).
  - `10-descargas/02-prowlarr.md`, `03-sonarr.md`, `04-radarr.md` (siguientes en la Fase 10; consumen el RPC de TR).
