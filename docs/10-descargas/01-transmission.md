# Transmission (cliente BitTorrent)

## Descripción

Despliegue de **Transmission** como cliente BitTorrent del homelab: gestiona los _torrents_ activos, descarga ficheros a `/mnt/hd2t/services/transmission/downloads/`, ofrece una **web UI** (`https://transmission.lan/`) y una **API JSON-RPC** que en fases posteriores consumirán **Sonarr** (`docs/10-descargas/03-sonarr.md`) y **Radarr** (`docs/10-descargas/04-radarr.md`) para gestionar descargas de series y películas. Toda la configuración persistente (`/config/settings.json`, `resume/`, `torrents/`, `blocklists/`) y el catálogo de descargas en curso viven en el disco externo **hd2t** (`/mnt/hd2t/services/transmission/`), pre-creado y reasignado a `1000:1000` en `docs/01-sistema/04-estructura-directorios.md` (paso 7, "Reasignar ownership de los servicios LinuxServer.io").

Este documento **estrena el _stack_ `descargas`** (`~/homelab/descargas/`) reservado en la tabla de _stacks_ de `docs/02-docker/02-estructura-compose.md` (fila `descargas`, fase `docs/10-descargas/`). El _stack_ alojará en fases siguientes a Prowlarr (`02-prowlarr.md`), Sonarr (`03-sonarr.md`) y Radarr (`04-radarr.md`); aquí se materializa **únicamente** el contenedor `transmission` y las _piezas_ que necesita para arrancar limpio (_bind mounts_, regla `nftables` para el puerto de _peers_, bloque del `Caddyfile`, entrada en `dump-databases.sh` aunque Transmission **no tenga BD** — se respalda como Categoría F filesystem-only).

Caddy (stack `red`, `docs/03-red/04-caddy.md`) expone Transmission en `https://transmission.lan/` con TLS interno (CA local). Para acceso remoto vía Tailscale (`docs/03-red/05-tailscale.md`), MagicDNS resuelve `pi.<tailnet>.ts.net` y desde ahí el operador llega al mismo backend; los clientes _native_ de Transmission (Transmission Remote GUI, Transdrone Android, Tremotesf desktop) se configuran apuntando a `https://transmission.lan/transmission/rpc` con la _basic auth_ propia de Transmission. Sonarr/Radarr, cuando lleguen, hablarán con Transmission **por DNS interno de Docker** (`transmission:9091`), saltándose Caddy.

> **Alcance**: este documento despliega Transmission con su autenticación RPC nativa (usuario + contraseña, _basic auth_), abre el puerto de _peers_ (`51413/tcp+udp`) en `nftables` para que las conexiones entrantes funcionen cuando se acceda al homelab vía Tailscale (que sí publica el host hacia los _exit nodes_ del _tailnet_), configura los directorios `downloads/`, `incomplete/` y `watch/`, deja activadas las extensiones DHT, PEX y LPD por defecto y entrega el _runbook_ de respaldo Patrón F sobre `config/`. **No** delega autenticación a Authelia vía `forward_auth` (rompería los clientes _native_ de Transmission y los _arr_ que hablan por API; ver **Decisiones de diseño**). **No** despliega Prowlarr (`docs/10-descargas/02-prowlarr.md`), **no** despliega Sonarr (`docs/10-descargas/03-sonarr.md`), **no** despliega Radarr (`docs/10-descargas/04-radarr.md`). **No** integra con un VPN comercial (gluetun, openvpn, wireguard side-car): el homelab opera sobre LAN+Tailscale exclusivamente y la decisión técnica es tratar el tráfico BitTorrent como cualquier otro tráfico saliente del operador (ver **Decisiones de diseño** → _Sin VPN container_). **No** abre `:51413` al **internet público**: el router doméstico no enruta puertos entrantes (decisión global del homelab — `docs/13-operaciones/04-red-y-puertos.md`); la consecuencia operativa de descargar en modo "_passive only_" se documenta también en **Decisiones de diseño**.

> **Recordatorio de red**: Transmission **no se publica al host** salvo el puerto de _peers_ (`51413/tcp` y `51413/udp`) — la web UI (`:9091`) la alcanza Caddy por DNS interno de Docker (`transmission:9091` en la red `homelab`). Pi-hole resuelve `transmission.lan → 192.168.1.3` por el _wildcard_ de `02-homelab-local.conf` (ver `docs/03-red/02-pihole.md`). El operador entra siempre por `https://transmission.lan/` (LAN) o por el nombre _MagicDNS_ del nodo Tailscale.

---

## Requisitos previos

- `docs/02-docker/02-estructura-compose.md` completado: la tabla de _stacks_ reserva el _slot_ `descargas` que aquí se estrena, la red Docker `homelab` (`br-homelab`, `172.20.10.0/24`) externa está creada, `~/homelab/.env` global con `TZ=Europe/Madrid`, `PUID=1000`, `PGID=1000`, `MEDIA_GID=<gid real>`, `HOMELAB_DOMAIN=lan` está rellenado, y el _Makefile_ de operación expone `make up STACK=<stack>`.
- `docs/01-sistema/04-estructura-directorios.md` completado: `/mnt/hd2t/services/transmission/{config,downloads,watch}` ya existen con ownership `1000:1000` (paso 7 de aquel doc, "Reasignar ownership de los servicios LinuxServer.io" — Transmission, Sonarr, Radarr, Prowlarr quedan reasignados a `1000:1000` aunque la imagen sea LSIO precisamente porque el _entrypoint_ de LSIO sólo ajusta el nivel superior del _bind mount_, no el árbol entero).
- `docs/01-sistema/03-seguridad-base.md` completado: `nftables` con `input drop` por defecto. Este documento **añade** la regla para `tcp dport {51413}` y `udp dport {51413}` desde cualquier origen — la única excepción al patrón "sólo LAN+Tailscale" del homelab, justificada en **Decisiones de diseño** → _Puerto de peers_.
- `docs/02-docker/04-watchtower.md` completado: la convención `com.centurylinklabs.watchtower.enable` está documentada y por defecto desactivada. Transmission será **opt-in** explícito (ver **Decisiones de diseño**), coherente con la lista de "candidatos a _opt-in_ desde el principio" de aquel doc, donde Transmission/Sonarr/Radarr/Prowlarr aparecen nominalmente.
- `docs/03-red/02-pihole.md` completado: Pi-hole resuelve `*.lan → 192.168.1.3`. **No hay que añadir nada** para `transmission.lan` — el _wildcard_ ya lo cubre.
- `docs/03-red/04-caddy.md` completado: Caddy escucha en `192.168.1.3:443` con `tls internal`, los _snippets_ `security-headers.caddy` y `logging.caddy` existen, la directiva `import /etc/caddy/snippets/*.caddy` está activa en el `Caddyfile` y la CA local firma `*.lan`.
- `docs/04-seguridad/01-authelia.md` completado **opcionalmente**: si Authelia ya está montado, en este documento se decide explícitamente **no** poner Transmission detrás de `forward_auth`. La lista `two_factor` del `access_control.rules` de Authelia **no incluye** `transmission.lan` (ni siquiera comentado).
- `docs/07-backups/02-borgmatic.md` y `docs/07-backups/03-backup-docker-volumes.md` completados (recomendado): el `source_directories: /mnt/hd2t/services` ya engloba `transmission/config/` y la entrada `exclude_patterns: - /mnt/hd2t/services/transmission/downloads` está en el `config.yaml` de Borgmatic (`docs/07-backups/01-estrategia-backup.md` → Categoría C). El bloque comentado de Transmission en `dump-databases.sh` no tiene nada que descomentar — Transmission **no usa BD** (ver **Almacenamiento** y **Backup**).
- Conectividad saliente para descargar la imagen (sólo la primera vez):

  ```bash
  docker pull --platform linux/arm64 lscr.io/linuxserver/transmission:4.0.6 >/dev/null && echo OK
  ```

  El _tag_ exacto se consulta en <https://github.com/linuxserver/docker-transmission/pkgs/container/transmission>; la convención del homelab prohíbe `:latest` (ver `docs/02-docker/02-estructura-compose.md`, sección **Imágenes**).

- Que el host **no** tenga ya un servicio escuchando en `:9091`, `:51413/tcp` ni `:51413/udp`:

  ```bash
  sudo ss -tulpn '( sport = :9091 or sport = :51413 )'
  ```

  Salida esperada: vacía. Transmission no publica `:9091` al host (Caddy lo alcanza por DNS interno), pero conviene confirmar que ningún binario residual lo ocupa por si más adelante el operador, durante un _troubleshoot_, añadiese un `ports: ["9091:9091"]` improvisado. `:51413` **sí** lo publicará este documento (puerto de _peers_).

- Espacio en `/mnt/hd2t`: como mínimo **1 GB libre** para `config/` (`settings.json` + `resume/` + `torrents/` + `blocklists/` rondan **50–200 MB** en estado estable, donde el grueso lo ocupan los `.torrent` archivados en `torrents/`). El espacio para `downloads/` lo dimensiona el operador según el _backlog_ habitual: con un par de docenas de torrents activos en torno a **20–50 GB** simultáneos es razonable; el _tope duro_ lo marca el espacio libre del disco y los _watermarks_ que se configuran en `settings.json` (`download-dir-free-space-bytes`).

  ```bash
  df -h /mnt/hd2t
  ```

---

## Decisiones de diseño

### Por qué Transmission (y no qBittorrent / Deluge / rTorrent)

El homelab necesita un **cliente BitTorrent** que sirva de _backend_ a Sonarr/Radarr (vía API), tenga una web UI usable desde el navegador y desde clientes _native_ móviles, y consuma poca RAM/CPU en una Pi 5 que tiene que mantener Jellyfin, Nextcloud y compañía corriendo en paralelo. Tres alternativas descartadas y por qué:

| Candidato     | Por qué se descarta                                                                                                                                                                                                                                                                                                                                                       |
|---------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **qBittorrent** | UI web más rica (búsquedas, tracker stats, RSS auto-download), pero el _binario_ es más pesado (~250 MB RAM idle frente a los ~80 MB de Transmission con la misma carga) y la web UI v4.5+ ha tenido CVEs de _path traversal_ y _credential leak_ con cierta regularidad. La API es Web v2; Sonarr/Radarr la soportan, pero la integración con Transmission es más antigua y mejor probada. |
| **Deluge**    | Arquitectura `daemon + thin client + web UI` es más flexible pero también más superficie de ataque y más procesos que vigilar. La web UI v2 sigue siendo experimental tras años; v1 está en mantenimiento. Plugins prácticamente abandonados.                                                                                                                                  |
| **rTorrent**  | Excelente para _power users_ con TUI; sin web UI nativa razonable (ruTorrent es un _frontend_ separado en PHP, mantenimiento errático). Demasiada fricción para un homelab donde el operador entra por web y los _arr_ por API.                                                                                                                                              |

Transmission gana por:

- **Footprint mínimo**: ~80 MB RAM idle, ~120 MB con 50 _torrents_ activos. Imagen ARM64 oficial de LSIO en torno a 130 MB descomprimidos. Sin sub-procesos accesorios.
- **API JSON-RPC estable**: documentada en `docs/specs/rpc-spec.md` del propio repo upstream y soportada de primera clase por Sonarr/Radarr/Prowlarr (`docs/10-descargas/03-sonarr.md` y siguientes la consumen sin _quirks_ específicos).
- **Sin BD**: el estado vive en `settings.json` + ficheros sueltos por _torrent_ en `resume/` y `torrents/`. Backup Patrón F (filesystem-only). Cero riesgo de "BD corrupta tras corte de luz" — el peor caso es un `settings.json` inconsistente que se restaura del archive del día anterior.
- **Configuración 100 % en JSON**: `settings.json` se versiona perfectamente en git si se quiere (no es el caso aquí — los secretos como el hash de la _password_ no deben viajar a un repo, ver **Variables de entorno**).
- **Web UI minimalista pero suficiente**: los _arr_ aportan la "inteligencia" (búsquedas, _quality profiles_, post-procesado). Transmission es el músculo que descarga.
- **Imagen LSIO `linuxserver/transmission`** activa, multi-arch ARM64, _PUID_/_PGID_ configurables, _entrypoint_ con `s6-overlay`. Encaja con todos los demás servicios LSIO del homelab (Syncthing, Sonarr, Radarr, Prowlarr, Calibre-Web, Audiobookshelf con la salvedad de éste último que usa la oficial).

### Imagen y _tag_

- **`lscr.io/linuxserver/transmission:4.0.6`** — imagen LSIO (LinuxServer.io) sobre upstream Transmission `4.0.6`. _Tag_ "major.minor.patch" pinneado a la versión exacta. Multi-arch (`linux/arm64`).
- **Por qué LSIO en lugar de la oficial `linuxserver/transmission` upstream**: la imagen "oficial" del proyecto Transmission es realmente la que mantiene LSIO (no hay otra en Docker Hub publicada por el `Transmission Project`). `lscr.io/linuxserver/transmission` es la fuente canónica para Docker. Encaja con la convención del homelab: imágenes LSIO para servicios que se benefician de `PUID`/`PGID` y `s6-overlay` (Syncthing, Sonarr, Radarr, Prowlarr, Calibre-Web…).
- **Por qué `4.0.6` y no `:4.0` o `:latest`**: el _tag_ corto `:4.0` recibe re-builds del wrapper LSIO varias veces por semana (parches de S6, base Alpine, etc.); pinear al patch concreto convierte cada re-build en una decisión humana. Watchtower (cuando se active el _opt-in_) recoge re-builds del **mismo `4.0.6`** sin cambiar el _tag_; los _bumps_ de patch (`4.0.6 → 4.0.7`) son cambios explícitos en el `.env`.
- **Por qué no la rama `4.1.x` o el _master_**: la línea `4.0.x` es la _stable_ vigente. La `4.1` aún no está oficialmente _release_; la `5.0` en pre-release introduce cambios en el _libtransmission_ que no han sido validados por Sonarr/Radarr. Mantenerse en `4.0.x` es la postura conservadora.

> **Cómo consultar el _tag_ vigente**: <https://github.com/linuxserver/docker-transmission/pkgs/container/transmission>. Los `release notes` de upstream Transmission se siguen en <https://github.com/transmission/transmission/releases>; los re-builds del wrapper LSIO en <https://github.com/linuxserver/docker-transmission/releases>.

#### Watchtower **opt-in**

Razones:

- **Patches frecuentes sin _breaking changes_**: la línea `4.0.x` recibe _patch releases_ con _bug fixes_ del propio Transmission y _security updates_ de la base Alpine. Mantenerse al día sin tocar a mano es deseable.
- **Estado estable dentro de la `4.0`**: el formato de `settings.json`, `resume/*.resume` y `torrents/*.torrent` está congelado en la línea `4.0.x`. Watchtower puede reciclar el contenedor con seguridad.
- **Sin estado en RAM crítico**: Transmission persiste el estado de cada _torrent_ en `resume/` cada **5–60 segundos** (ajustable). Reciclar el contenedor durante la madrugada (la ventana de Watchtower es domingo a las 04:00 UTC, ver `docs/02-docker/04-watchtower.md`) cuesta como máximo unos segundos de _re-hash_ al rearrancar el _torrent_, sin pérdida de estado real.
- **_arr_ tolerantes a reinicios**: Sonarr/Radarr llevan retry exponencial sobre la API de Transmission; un reinicio puntual por update no rompe ninguna descarga en curso.

Etiquetar el contenedor con `com.centurylinklabs.watchtower.enable: "true"`.

> **Bumps de _minor_** (`4.0 → 4.1`, `4.x → 5.x`): se hacen **a mano**, fuera de Watchtower. Cambiar `TRANSMISSION_IMAGE_TAG=4.1.0` en `~/homelab/descargas/.env`, leer las _release notes_ del proyecto y de LSIO, hacer backup del `/config` previo (Borgmatic), y aplicar `make pull STACK=descargas && make up STACK=descargas`. Watchtower con _tag_ `4.0.6` no salta a `4.1.0` automáticamente porque mira el _digest_ del _tag_ exacto pinneado.

### Modo de red: `bridge` (red `homelab`) con `ports:` para el peer

Decisión opinada. Las dos opciones razonables:

| Opción                              | Ventajas                                                                                                                                                           | Inconvenientes                                                                                                                                                                                                                                                          |
|-------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **`network_mode: host`**            | El puerto de _peers_ `:51413` queda directamente en la IP del host; cero NAT; el `External IP` que reportan los trackers es trivialmente correcto. Útil si el operador hubiera abierto el puerto en el router (no es el caso del homelab).  | Rompe el patrón "Caddy delante de cada servicio" — Transmission escucharía en `192.168.1.3:9091` directamente. Caddy puede _reverse-proxy_ a esa IP, pero hay que abrir un agujero en `nftables` para `:9091`. Además, expone la web UI al host: cualquier proceso local pinchea la API sin Caddy. |
| **`bridge` en red `homelab` con `ports: ["51413:51413/tcp", "51413:51413/udp"]`** ✅ | Coherente con todos los demás servicios del homelab: Transmission se alcanza por DNS interno (`transmission:9091`), no expone la web UI al host, Caddy es el _único_ camino al servicio para humanos y Sonarr/Radarr lo alcanzan por nombre. Aislamiento limpio. El puerto de _peers_ se publica al host **explícitamente** sólo en lo que necesita (51413/tcp+udp). | Las conexiones entrantes de _peers_ pasan por DNAT del bridge: el _External IP_ que Transmission reporta es la IP interna del contenedor (`172.20.10.x`), pero los _peers_ que se conectan ven la IP del host. Hay que confirmar que Transmission detecta correctamente su _public IP_ (vía `port-forwarding-enabled=false` y consulta a `ipinfo.io` desde el _bind-address-ipv4`). |

Se elige `bridge` con `ports:` para `:51413/tcp` y `:51413/udp`. La detección de _public IP_ funciona correctamente en este modo: Transmission no necesita _bind_ a la IP pública directamente; le basta con que las conexiones entrantes lleguen al socket interno gracias al DNAT que `dockerd` hace a través de `iptables`/`nftables`. Las pruebas se documentan en **Verificación**.

> **`net.ipv4.ip_forward=1`** debe estar habilitado en el host para que el DNAT del bridge funcione (Docker lo activa por sí mismo al arrancar). Comprobar:
>
> ```bash
> sysctl net.ipv4.ip_forward
> # net.ipv4.ip_forward = 1
> ```

### Puerto de _peers_: `51413/tcp+udp`, sin port-forwarding al router

BitTorrent funciona "_passively_" cuando un cliente no acepta conexiones entrantes: sólo se conecta hacia _peers_ con puertos abiertos. Esto reduce el _swarm_ alcanzable y por tanto la velocidad de descarga, pero **no la rompe**. Para muchos torrents bien _seedeados_ (releases populares, distros Linux, contenido educativo) la velocidad obtenida en modo _passive_ es indistinguible de la activa.

El homelab toma esta decisión:

- **`51413/tcp+udp` se publica al host** vía `ports:` — esto permite que conexiones entrantes desde **dentro de la LAN doméstica** (raro: otro cliente BT en la misma red) y **desde el _tailnet_ Tailscale** lleguen hasta Transmission. Tailscale no abre puertos en el router (es VPN _outgoing_), pero sí permite a otros _nodos_ del _tailnet_ conectarse al puerto del homelab — aprovechable si en algún momento se monta otro cliente BT en otro nodo Tailscale para intercambiar torrents privados.
- **No se abre `:51413` en el router doméstico hacia internet**: política global del homelab, ver `docs/13-operaciones/04-red-y-puertos.md`. Esto significa que **los _peers_ públicos de internet no pueden abrir conexiones hacia el homelab**. Transmission opera en modo "_passive only_" para esos _peers_.
- **`port-forwarding-enabled` se desactiva** en `settings.json` (UPnP/NAT-PMP). El router del operador no soporta UPnP por convicción de seguridad (`docs/13-operaciones/04-red-y-puertos.md`); intentar negociarlo sólo añade _logs_ de error y no consigue nada.

Consecuencia operativa:

- En la web UI, el indicador "**Port is closed**" aparece en _Settings → Network → Port_. **Esto es esperado**. La velocidad efectiva de cada torrent dependerá del _swarm_; los torrents con muchos _seeders_ con puertos abiertos llegarán al límite de la conexión doméstica sin problema.
- Si en un momento dado se decidiese revertir esta política y abrir `:51413` en el router, no hay cambios necesarios en el homelab — sólo el _port forwarding_ del router. Documentar en `docs/13-operaciones/04-red-y-puertos.md` y aquí actualizar **Decisiones de diseño** consecuentemente.

#### Reglas `nftables` para `:51413`

Aunque por defecto el homelab tiene `input drop` con _allow_ explícito desde la LAN y desde Tailscale (ver `docs/01-sistema/03-seguridad-base.md`), Docker añade automáticamente reglas en la cadena `DOCKER` de `nftables` para los `ports:` publicados — son **independientes** de la cadena `input` del firewall del host. La regla que `dockerd` añade vía `iptables-nft` es del tipo:

```
table ip nat {
    chain DOCKER {
        ip saddr 0.0.0.0/0 tcp dport 51413 dnat to 172.20.10.X:51413
    }
}
```

Esto _bypass_ea la cadena `input` del firewall del homelab y permite que cualquier _peer_ que llegue al host pueda alcanzar `172.20.10.X:51413`. **Esto está bien para BitTorrent**: precisamente queremos que los _peers_ del _tailnet_ y los _peers_ de la LAN puedan conectar.

> **Si el operador prefiere endurecer aún más** y restringir `:51413` sólo a un origen concreto (p. ej. sólo desde Tailscale `100.64.0.0/10` y la LAN `192.168.1.0/24`), se puede añadir una regla `drop` en la cadena `DOCKER-USER` (que `dockerd` respeta y se evalúa antes de `DOCKER`):
>
> ```bash
> sudo nft add rule ip filter DOCKER-USER \
>     ip saddr != { 192.168.1.0/24, 100.64.0.0/10 } \
>     tcp dport 51413 drop
> sudo nft add rule ip filter DOCKER-USER \
>     ip saddr != { 192.168.1.0/24, 100.64.0.0/10 } \
>     udp dport 51413 drop
> ```
>
> Esta restricción **no se activa por defecto** en este documento porque, sin _port forwarding_ del router, no hay tráfico entrante de internet en absoluto, así que la regla sería redundante. Se documenta como _opt-in_.

### Volumen de descargas: `/mnt/hd2t/services/transmission/downloads/`

Transmission escribe a `/downloads/` dentro del contenedor (mapeado a `/mnt/hd2t/services/transmission/downloads/` en el host). Ese directorio es:

- **Propiedad de Transmission** — no se monta `:ro` (Transmission necesita escribir).
- **No es la biblioteca multimedia final** — la biblioteca vive en `/mnt/hd2t/services/shared/media/` (montada por Jellyfin `:ro` y por Sonarr/Radarr `:rw` en sus respectivas fases). Transmission no monta `services/shared/`. La separación es clave: Transmission descarga, los _arr_ post-procesan (renombrar, organizar, mover/_hardlink_ a `shared/media`), Jellyfin escanea.
- **Co-residente en el mismo filesystem que `services/shared/media/`** — ambos viven en `/mnt/hd2t`, lo que **permite _hardlinks_** entre `transmission/downloads/` y `services/shared/media/`. Sonarr/Radarr explotan esta propiedad: en lugar de _copiar_ un fichero descargado de 10 GB a la biblioteca, hacen un _hardlink_ que aparece en ambos sitios sin duplicar bytes. Esto es **fundamental** para la economía de espacio del homelab. Si Transmission escribiese a `/mnt/hd5t` o a otro disco, los _hardlinks_ fallarían silenciosamente y los _arr_ caerían a copia (con duplicación de espacio).

Convención `/incomplete/`:

- Transmission soporta una _incomplete dir_ separada que recibe los `.part` mientras la descarga está en curso, y mueve el fichero finalizado a `/downloads/` cuando termina. Reduce la fragmentación del disco y separa "trabajo en curso" de "trabajo terminado".
- En este homelab se activa: `/mnt/hd2t/services/transmission/incomplete/` (subdirectorio nuevo, creado por este documento). Aún en el mismo filesystem para preservar _hardlinks_ con `services/shared/media/` cuando Sonarr/Radarr lo recojan.

Convención `/watch/`:

- Transmission monitoriza esta carpeta y arranca cualquier `.torrent` que aparezca. Útil cuando el operador suelta un `.torrent` desde el navegador / Samba sin entrar a la web UI.
- Se mantiene aunque Sonarr/Radarr no la usan (prefieren la API). Sin coste si no se usa.

### Sin VPN container (gluetun / openvpn / wireguard side-car)

Patrón muy popular en homelabs: un contenedor side-car de tipo `gluetun` que enruta todo el tráfico de Transmission a través de un VPN comercial (Mullvad, ProtonVPN, etc.), con `network_mode: "service:gluetun"` en el compose. Beneficios típicos: ocultar la IP del operador a los _peers_ y a los trackers, eludir _throttling_ del ISP, capa de _privacy_.

**Este homelab no lo adopta**, por estas razones:

- **Premisa global del homelab**: red LAN + Tailscale, nada de tunelizar tráfico saliente a un proveedor comercial. La filosofía es "todo local, nada en la nube". Añadir un VPN comercial reintroduce la dependencia (cuenta, _account credentials_, _kill switch_, monitoring de la conexión) que el resto del homelab evita.
- **Complejidad operativa**: gluetun + Transmission requiere coordinar la red entre dos contenedores (`network_mode: "service:..."`), reconfigurar el _bind_ del puerto de _peers_, gestionar el _kill switch_ (sin VPN no se descarga), monitorizar que el _provider_ no caiga, y debugar los fallos de DNS dentro del túnel. Cada uno de estos puntos es un fallo en producción esperando a ocurrir.
- **Coste**: un VPN razonable cuesta 5-10 €/mes. Multiplicado por el tiempo del operador, no es trivial.
- **Caso de uso real**: el operador usa el homelab para descargas legítimas (releases Linux, ROMs de juegos en dominio público, audiolibros liberados, etc.). El _privacy_ que aporta el VPN es marginal frente a las molestias.

> **Si la situación cambia** (un proveedor de servicios envía un aviso al ISP, _throttling_ severo, viaje a un país con regulación distinta), se documenta en este apartado como _migration_ a `gluetun`. Mientras tanto, postura limpia: tráfico BitTorrent saliendo por la conexión doméstica como cualquier otro tráfico.

### `forward_auth` con Authelia: **NO** para Transmission

Tentación natural una vez Authelia está montada: añadir `import authelia` al bloque `transmission.lan` del `Caddyfile`. **No se hace**, por estas razones técnicas:

- **Sonarr/Radarr/Prowlarr hablan con Transmission por DNS interno** (`transmission:9091`), saltándose Caddy. Ahí Authelia no influye en absoluto. Sería sólo una protección extra para la web UI.
- **Clientes _native_ de Transmission** (Transmission Remote GUI desktop, Transdrone Android, Tremotesf KDE) no son navegadores: no siguen redirects HTTP a `auth.lan`, no rellenan formularios HTML, no procesan _cookies_ OIDC. Hablan **JSON-RPC con _Basic Auth_** sobre el endpoint `/transmission/rpc`. Si Caddy interpone Authelia, el cliente recibe un `302 Location: https://auth.lan/?rd=...` y rompe.
- **La web UI nativa de Transmission** sí se podría proteger con Authelia para humanos, pero la _basic auth_ propia de Transmission ya cubre ese caso con un nivel razonable. La superficie de ataque interesante (la API `/transmission/rpc`) ya está autenticada.

Solución correcta: **Transmission autentica con su sistema nativo** (usuario + contraseña _basic auth_ fija en `settings.json`, hashable con `transmission-create` o vía la variable `USER`/`PASS` de la imagen LSIO). El operador puede añadir reglas `nftables` que limiten el acceso a `:443` desde IPs de la LAN+Tailscale (ya las hay desde `docs/03-red/04-caddy.md`); ningún acceso externo es posible.

> **Resumen operativo**: el bloque `transmission.lan` del `Caddyfile` lleva `import security-headers` y `import logging`, pero **no** `import authelia`. Caddy actúa como _reverse proxy_ "tonto" que termina TLS y propaga las cabeceras. La _basic auth_ de Transmission viaja cifrada por TLS gracias al propio Caddy.

### `host-whitelist` de Transmission: incluir `transmission.lan` y `<TAILSCALE_HOSTNAME>.<TAILNET>.ts.net`

Transmission 4.x tiene un mecanismo defensivo conocido como `rpc-host-whitelist`: rechaza peticiones cuyo `Host:` header no coincide con un valor permitido, para evitar ataques DNS rebinding. Por defecto sólo acepta `localhost` y `127.0.0.1`. Cuando Caddy hace _reverse proxy_ con `header_up Host {host}`, le llega `Host: transmission.lan` (o el nombre Tailscale) y Transmission lo rechaza con un `403 Forbidden`.

Solución:

```json
"rpc-host-whitelist": "transmission.lan,*.ts.net,transmission",
"rpc-host-whitelist-enabled": true
```

- `transmission.lan` cubre acceso vía Caddy desde LAN.
- `*.ts.net` cubre acceso desde el _tailnet_ (los _MagicDNS hostnames_ de Tailscale terminan en `ts.net`). Wildcard explícito; Transmission lo soporta desde 3.0.
- `transmission` cubre acceso por DNS interno de Docker (Sonarr/Radarr → `http://transmission:9091/`).

Alternativa: poner `"rpc-host-whitelist-enabled": false`. **No se recomienda**: la lista blanca es una defensa barata y bien probada. Mejor mantenerla activa con la lista correcta.

### Almacenamiento

| Ruta en el host                                            | Contenido                                                            | Versionable           | Backup                              |
|------------------------------------------------------------|----------------------------------------------------------------------|-----------------------|-------------------------------------|
| `~/homelab/descargas/docker-compose.yml`                   | Definición del _stack_                                               | git                   | git                                 |
| `~/homelab/descargas/.env`                                 | Imágenes pinneadas + variables del _stack_ + secret de RPC password  | **NO** (`.gitignore`) | git aparte (nota local)             |
| `~/homelab/descargas/.env.example`                         | Plantilla con nombres de variables, sin valores                      | git                   | git                                 |
| `/mnt/hd2t/services/transmission/config/settings.json`     | Configuración principal (puertos, paths, RPC user/pass hash)         | **NO** (contiene hash)| **Sí** (Borgmatic — Categoría F)    |
| `/mnt/hd2t/services/transmission/config/resume/`           | Estado de cada _torrent_ (paused/running, prioridades, …)            | **NO**                | **Sí** (Borgmatic — Categoría F)    |
| `/mnt/hd2t/services/transmission/config/torrents/`         | Copias de los `.torrent` añadidos                                    | **NO**                | **Sí** (Borgmatic — Categoría F)    |
| `/mnt/hd2t/services/transmission/config/blocklists/`       | Listas de IPs filtradas                                              | **NO**                | **Sí** (Borgmatic — Categoría F)    |
| `/mnt/hd2t/services/transmission/config/stats.json`        | Estadísticas de ratio acumulado                                      | **NO**                | **Sí** (Borgmatic — Categoría F)    |
| `/mnt/hd2t/services/transmission/downloads/`               | Ficheros descargados completos                                       | **NO**                | **NO** — Categoría C, regenerable (re-descarga) |
| `/mnt/hd2t/services/transmission/incomplete/`              | `.part` de descargas en curso                                        | **NO**                | **NO** — Categoría E, efímero        |
| `/mnt/hd2t/services/transmission/watch/`                   | Carpeta de drop-in de `.torrent` por el operador                     | **NO**                | **NO** — Categoría E, efímero        |

> **`downloads/` y `incomplete/` excluidos**: ya cubierto por la entrada `exclude_patterns: - /mnt/hd2t/services/transmission/downloads` del `config.yaml` global de Borgmatic (`docs/07-backups/01-estrategia-backup.md`). Este documento añade además `incomplete/` al `exclude_patterns` (es nuevo en este doc; los `.part` no aportan nada al respaldarse).

> **`config/` enterito sí entra**: Patrón F filesystem-only. No hay BD que dumpear. Si se pierde y se restaura del archive del día anterior, los _torrents_ activos pierden a lo sumo unas horas de progreso (Transmission re-_hashea_ los ficheros para validar la parte ya descargada — operación pesada pero correcta).

---

## Estructura del _stack_ `descargas` tras este documento

```
~/homelab/descargas/
├── docker-compose.yml        # ← nuevo
├── .env                      # ← nuevo (NO versionado)
├── .env.example              # ← nuevo (versionado)
└── .gitignore                # ← nuevo (excluye .env)
```

Y en los discos externos, sobre lo que ya creó `docs/01-sistema/04-estructura-directorios.md`:

```
/mnt/hd2t/services/transmission/
├── config/        (vacío al empezar; el primer arranque lo puebla)
├── downloads/     (vacío al empezar; aquí caen los .torrent finalizados)
├── incomplete/    (NUEVO — lo crea este documento)
└── watch/         (vacío; el operador deja .torrent aquí cuando quiera)
```

Crear el subdirectorio del _stack_, los _stubs_ de gitignore y la nueva carpeta `incomplete/`:

```bash
mkdir -p ~/homelab/descargas
chmod 0750 ~/homelab/descargas

cat > ~/homelab/descargas/.gitignore <<'EOF'
# Secretos del stack — NUNCA commitear
.env
EOF

# Crear incomplete/ con ownership 1000:1000 (consistente con el resto de subdirs)
sudo mkdir -p /mnt/hd2t/services/transmission/incomplete
sudo chown 1000:1000 /mnt/hd2t/services/transmission/incomplete
sudo chmod 0755 /mnt/hd2t/services/transmission/incomplete
```

> **Ownership de `/mnt/hd2t/services/transmission/`**: ya está fijado por `docs/01-sistema/04-estructura-directorios.md` paso 7 a `1000:1000`. El contenedor LSIO corre como `${PUID}:${PGID}` (= `1000:1000`), así que escribe sin fricciones. **No** hay que pre-`chown`-ear nada de nuevo salvo el recién creado `incomplete/`.

> **Co-residencia con `services/shared/media/`**: ambos viven en `/mnt/hd2t`. Confirmar con `stat -c '%m' /mnt/hd2t/services/transmission/downloads /mnt/hd2t/services/shared/media`: ambos deben devolver `/mnt/hd2t`. Sin esta co-residencia los _hardlinks_ de Sonarr/Radarr fallan silenciosamente (caen a copia).

---

## Variables de entorno

Crear `~/homelab/descargas/.env.example` (versionado en git, sin valores reales ni secretos):

```bash
# --- Imágenes pinneadas -----------------------------------------------------
# Patches automáticos vía Watchtower. Bumps de minor/major a mano leyendo
# https://github.com/transmission/transmission/releases y
# https://github.com/linuxserver/docker-transmission/releases.
TRANSMISSION_IMAGE_TAG=4.0.6

# --- Transmission ----------------------------------------------------------
# Credenciales RPC (basic auth de la web UI y de la API JSON-RPC).
# La imagen LSIO usa USER/PASS para inyectarlas en settings.json en el
# primer arranque. Si settings.json ya existe, USER/PASS NO se aplican
# (LSIO no sobreescribe configuración existente). Usar contraseñas fuertes:
# hashes/aleatorias del gestor (cuando llegue Vaultwarden).
TRANSMISSION_USER=
TRANSMISSION_PASS=

# Puerto de peers (TCP+UDP). Estándar de Transmission: 51413. Cambiar sólo
# si hay un conflicto local (raro).
TRANSMISSION_PEER_PORT=51413
```

Copiar a `.env` y rellenar valores reales:

```bash
cp ~/homelab/descargas/.env.example ~/homelab/descargas/.env
$EDITOR ~/homelab/descargas/.env
chmod 0600 ~/homelab/descargas/.env
```

> **Generar `TRANSMISSION_PASS` con criterio**: contraseña aleatoria larga generada por el gestor del operador o por `openssl rand -base64 24`. Esta es la contraseña con la que Sonarr/Radarr se autenticarán en futuras fases — apuntarla en una nota del gestor (Vaultwarden cuando llegue) para reusarla.

> **Sobre el _hash_ de la contraseña en `settings.json`**: la imagen LSIO toma `TRANSMISSION_PASS` en _plain text_ y la inyecta en `settings.json` como `rpc-password`. Transmission, en el primer arranque, **convierte automáticamente** el _plain text_ a un _hash MD5_ con _salt_ del propio Transmission (cadena que empieza por `{`). Tras ese primer arranque, `settings.json` ya no contiene la contraseña en claro — la `.env` queda como única fuente de verdad para el _plain text_, pero ya no se vuelve a leer salvo que se borre `settings.json`. Por eso la `.env` debe ir en Borgmatic (Categoría A — `docs/07-backups/01-estrategia-backup.md`).

> **No commitear `.env` jamás**. El `.gitignore` del _stack_ ya lo excluye explícitamente.

---

## `~/homelab/descargas/docker-compose.yml`

```yaml
---
# Stack: descargas — Transmission
# Documentación: docs/10-descargas/01-transmission.md
# (Prowlarr, Sonarr y Radarr se añaden en docs siguientes.)

services:

  # ---------------------------------------------------------------------------
  # Transmission — cliente BitTorrent.
  # En 'homelab' (Caddy la alcanza por nombre, Sonarr/Radarr también).
  # Sin red privada de stack porque por ahora es el único servicio.
  # Se añadirá una red privada 'descargas-internal' si Sonarr/Radarr
  # quisieran tener su propio canal aislado de Caddy.
  # ---------------------------------------------------------------------------
  transmission:
    image: lscr.io/linuxserver/transmission:${TRANSMISSION_IMAGE_TAG}
    container_name: transmission
    hostname: transmission
    restart: unless-stopped
    environment:
      PUID: ${PUID}
      PGID: ${PGID}
      TZ: ${TZ}
      # USER/PASS: inyectados por el entrypoint LSIO en settings.json en el
      # PRIMER arranque (cuando settings.json no existe). En arranques
      # posteriores, LSIO los ignora — la fuente de verdad pasa a ser
      # settings.json. Para cambiar la contraseña tras el primer arranque:
      #   1. docker compose stop transmission
      #   2. editar settings.json -> rpc-password (en plain text; Transmission
      #      la rehashea al arrancar)
      #   3. docker compose start transmission
      USER: ${TRANSMISSION_USER}
      PASS: ${TRANSMISSION_PASS}
      # WHITELIST de Transmission para la red local (no es la rpc-host-whitelist
      # contra DNS rebinding, sino la rpc-whitelist contra IPs de origen del
      # cliente). LSIO la inyecta en settings.json. Vacía -> deshabilitada
      # (rpc-whitelist-enabled=false). Mantenemos deshabilitada porque Caddy
      # llega desde la subnet 'homelab' (172.20.10.0/24) y mantenerla activa
      # complicaría el bootstrap; la defensa real es la basic auth.
      TRANSMISSION_WEB_HOME: /transmission-web-home/
    volumes:
      - /mnt/hd2t/services/transmission/config:/config
      - /mnt/hd2t/services/transmission/downloads:/downloads
      - /mnt/hd2t/services/transmission/incomplete:/incomplete
      - /mnt/hd2t/services/transmission/watch:/watch
      # Hora del host (timestamps de logs, tiempos de seed alineados con el host).
      - /etc/localtime:/etc/localtime:ro
    ports:
      # Puerto de peers (TCP + UDP). Bind a todas las interfaces; el firewall
      # del host (nftables) y la cadena DOCKER-USER pueden restringir más
      # si se quisiera (ver "Reglas nftables para :51413" en el doc).
      - "${TRANSMISSION_PEER_PORT}:51413/tcp"
      - "${TRANSMISSION_PEER_PORT}:51413/udp"
      # Puerto :9091 NO se publica al host. Caddy lo alcanza por DNS interno.
    networks:
      homelab:
        aliases:
          - transmission     # Caddy y Sonarr/Radarr resuelven 'transmission:9091'
    labels:
      homelab.stack: "descargas"
      homelab.backup: "true"   # /mnt/hd2t/services/transmission/config entra en Borgmatic (Cat. F)
      # Opt-in: patches dentro de 4.0.x son seguros (sin breaking changes en
      # settings.json ni en resume/).
      com.centurylinklabs.watchtower.enable: "true"
    healthcheck:
      # /transmission/web/ devuelve 401 sin auth o 200 si la basic auth está
      # presente. Aquí basta con confirmar que el socket responde HTTP — un
      # 401 indica que Transmission está vivo y la API enchufada. Por eso
      # buscamos 'Transmission' en la respuesta (header Server o cuerpo del
      # error 401, ambos contienen la cadena).
      test:
        - CMD-SHELL
        - "wget -qO- --tries=1 --timeout=5 --header='Authorization: Basic ZHVtbXk6ZHVtbXk=' http://localhost:9091/transmission/web/ 2>&1 | grep -q -i transmission || exit 1"
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 30s

# ---------------------------------------------------------------------------
# Redes
# ---------------------------------------------------------------------------
networks:
  homelab:
    external: true               # creada en docs/02-docker/02-estructura-compose.md
```

Notas de diseño:

- **`PUID/PGID` vía `environment:`**: la imagen LSIO espera estos en el _entrypoint_ (no es la convención `user:` que usa Jellyfin). Equivalente funcionalmente.
- **`USER`/`PASS` sólo en el primer arranque**: característica documentada por LSIO: el _entrypoint_ comprueba si `settings.json` ya existe y, si existe, **no** sobreescribe `rpc-username`/`rpc-password`. Esto es el comportamiento correcto: el _plain text_ se convierte a hash MD5+salt al arrancar Transmission, y a partir de ahí `settings.json` ya no debe re-modificarse desde la `.env`. Para cambiar la contraseña ver el comentario en el compose y la sección **Configuración tras primer arranque**.
- **Sin `user:` explícito**: LSIO maneja el UID/GID con su propio _entrypoint_ s6-overlay; usar `user:` en paralelo confunde al `s6-overlay` y rompe el `chown` automático del nivel superior.
- **`/incomplete:/incomplete`**: nuevo volumen creado en este doc. Coexiste con `/downloads` para separar `.part` de descargas terminadas.
- **`ports:` sólo `:51413/tcp+udp`**: Caddy alcanza Transmission por DNS interno (`transmission:9091`). Si el operador necesita acceder sin pasar por Caddy durante un _troubleshooting_, puede `docker exec -it transmission wget -qO- http://localhost:9091/transmission/web/` desde dentro del propio contenedor.
- **`/etc/localtime:/etc/localtime:ro`**: además de `TZ`, montar `/etc/localtime` cubre los timestamps que Transmission imprime en `transmission-daemon` y en los logs de `add-time` y `done-time` de cada _torrent_.
- **`start_period: 30s`**: el primer arranque de Transmission es rápido (~10 s) — apenas tiene que crear `settings.json`. `start_period: 30s` deja margen suficiente sin bloqueos espurios del _healthcheck_ durante el _bootstrap_.
- **Healthcheck con _basic auth_ falso**: la cabecera `Authorization: Basic ZHVtbXk6ZHVtbXk=` (que es `dummy:dummy`) garantiza que la respuesta sea siempre HTTP, no un cierre de socket. Tanto `200` (improbable, no es la real) como `401 Unauthorized` (esperado) confirman que el _daemon_ está sirviendo HTTP — ambos casos contienen la cadena `Transmission`. Si se cae el daemon, `wget` falla por _connection refused_ y el _healthcheck_ marca `unhealthy`.
- **Watchtower opt-in**: razones explicadas en **Decisiones de diseño** → _Imagen y tag_.
- **No `mem_limit` ni `cpus`**: Transmission consume poco (~80–150 MB RAM con 50 _torrents_, <2 % CPU idle, <10 % CPU durante _hashing_ de un fichero recién terminado). La política por defecto (sin límite) está bien.

---

## Despliegue

### Primer arranque

```bash
cd ~/homelab/descargas
docker compose --env-file ../.env --env-file .env config | head -40   # validar sintaxis
docker compose --env-file ../.env --env-file .env up -d
```

O, equivalente, con el _Makefile_ (ver `docs/02-docker/02-estructura-compose.md`):

```bash
cd ~/homelab
make up STACK=descargas
```

Vigilar el primer arranque (tarda ~15 s):

```bash
docker compose -f ~/homelab/descargas/docker-compose.yml logs -f transmission
# ...
# transmission | [migrations] started
# transmission | [migrations] no migrations found
# transmission | [custom-init] No custom files found, skipping...
# transmission | [ls.io-init] done.
# transmission | Default username and password set in /config/settings.json
# transmission | [Service] Started transmission-daemon (4.0.6)
# transmission | [s6-init] ready.
```

Verificar que el contenedor está `(healthy)`:

```bash
docker compose -f ~/homelab/descargas/docker-compose.yml ps
# NAME          STATUS                   PORTS
# transmission  Up X seconds (healthy)   0.0.0.0:51413->51413/tcp, 0.0.0.0:51413->51413/udp
```

> El `(healthy)` lo otorga el _healthcheck_ que confirma que `/transmission/web/` responde HTTP (con `401` o `200`). Si tras 90 s sigue `starting`, ir a **Troubleshooting** → primer arranque.

### Caddy: bloque `transmission.lan`

Editar `~/homelab/red/Caddyfile` y añadir el bloque:

```caddy
transmission.lan {
    tls internal
    import security-headers
    import logging

    # Transmission rechaza peticiones cuyo Host header no esté en la
    # rpc-host-whitelist (defensa contra DNS rebinding). Le mandamos
    # 'transmission.lan' tal cual; en settings.json más abajo se incluye
    # 'transmission.lan' en rpc-host-whitelist.
    reverse_proxy transmission:9091 {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
    }

    # Redirigir / a /transmission/web/ (Transmission no tiene landing
    # propia en la raíz; su web UI vive bajo /transmission/web/).
    redir / /transmission/web/ 302
}
```

Validar y recargar Caddy:

```bash
docker exec caddy caddy validate --config /etc/caddy/Caddyfile
docker exec caddy caddy reload --config /etc/caddy/Caddyfile
```

Probar (la CA local debe estar importada en el navegador, ver `docs/03-red/04-caddy.md`):

```bash
# Sin auth: 401 esperado
curl -k --resolve transmission.lan:443:192.168.1.3 \
     -I https://transmission.lan/transmission/web/
# HTTP/2 401
# www-authenticate: Basic realm="Transmission"

# Con auth: 200
curl -k --resolve transmission.lan:443:192.168.1.3 \
     -u "${TRANSMISSION_USER}:${TRANSMISSION_PASS}" \
     -I https://transmission.lan/transmission/web/
# HTTP/2 200
```

Y desde el navegador: `https://transmission.lan/` → redirección a `/transmission/web/` → diálogo de _basic auth_ → web UI de Transmission.

---

## Configuración tras primer arranque

> **Atención**: Transmission **reescribe `settings.json` al apagarse limpiamente**. Si se edita `settings.json` con el contenedor en marcha y luego se apaga, los cambios manuales **se pierden**. La regla operativa es:
>
> 1. `docker compose -f ~/homelab/descargas/docker-compose.yml stop transmission`
> 2. Editar `/mnt/hd2t/services/transmission/config/settings.json`
> 3. `docker compose -f ~/homelab/descargas/docker-compose.yml start transmission`
>
> Esto no aplica a cambios hechos desde la web UI o la API: ahí Transmission persiste en caliente.

### `settings.json` recomendado

Tras el primer arranque, parar Transmission y editar `settings.json` con los siguientes valores. Las claves marcadas con `(*)` son las que cambian respecto a los _defaults_ del LSIO; el resto se mantiene tal cual.

```bash
docker compose -f ~/homelab/descargas/docker-compose.yml stop transmission
sudoedit /mnt/hd2t/services/transmission/config/settings.json
```

Bloque relevante (con comentarios para claridad — JSON real **no** los soporta, recordar quitarlos):

```jsonc
{
    // --- Identidad y RPC --------------------------------------------------
    "rpc-username": "<TRANSMISSION_USER>",
    "rpc-password": "{<HASH-MD5-CON-SALT>}",     // generado por Transmission al arrancar
    "rpc-port": 9091,
    "rpc-bind-address": "0.0.0.0",
    "rpc-enabled": true,
    "rpc-authentication-required": true,

    // (*) host-whitelist: defensa contra DNS rebinding.
    "rpc-host-whitelist": "transmission.lan,*.ts.net,transmission",
    "rpc-host-whitelist-enabled": true,

    // (*) whitelist de IPs de origen — deshabilitada porque Caddy llega
    // desde 172.20.10.x (red 'homelab') y la basic auth ya cubre.
    "rpc-whitelist": "127.0.0.1,172.20.10.0/24",
    "rpc-whitelist-enabled": false,

    // --- Paths ------------------------------------------------------------
    "download-dir": "/downloads",
    "incomplete-dir": "/incomplete",
    "incomplete-dir-enabled": true,
    "watch-dir": "/watch",
    "watch-dir-enabled": true,
    "watch-dir-force-generic": false,           // detecta inotify si está disponible

    // (*) crear ficheros con permisos 0664 y dirs 0775 para que Sonarr/Radarr
    // (PGID=1000, mismo grupo) puedan leerlos y movernoslos.
    "umask": 2,                                  // 022 → ficheros 0644 / dirs 0755
                                                 // (Transmission usa 0666 - umask para ficheros)

    // --- Peers y red ------------------------------------------------------
    "peer-port": 51413,
    "peer-port-random-on-start": false,         // puerto fijo (igual que el ports: del compose)
    "port-forwarding-enabled": false,           // sin UPnP; el router no abre puertos

    "encryption": 1,                             // 0=tolerated, 1=preferred, 2=required
                                                 // 'preferred' = pide cifrado, acepta peers
                                                 // sin cifrado si no hay otra opción.
    "dht-enabled": true,
    "pex-enabled": true,
    "lpd-enabled": true,                         // local peer discovery; útil en LAN
    "utp-enabled": true,                         // µTP además de TCP

    "peer-limit-global": 200,
    "peer-limit-per-torrent": 50,

    // --- Velocidad y queue ------------------------------------------------
    "speed-limit-down-enabled": false,
    "speed-limit-up-enabled": true,
    "speed-limit-up": 4096,                      // 4 MB/s — no saturar la subida del operador

    "alt-speed-enabled": false,                  // alt-speed scheduling, off por defecto

    "queue-stalled-enabled": true,
    "queue-stalled-minutes": 30,
    "download-queue-enabled": true,
    "download-queue-size": 5,
    "seed-queue-enabled": false,                 // sin tope de seeds simultáneos

    // --- Ratio y seeding --------------------------------------------------
    "ratio-limit": 2.0,
    "ratio-limit-enabled": true,                 // pausar el seed automático al ratio 2.0
    "idle-seeding-limit": 4320,                  // 3 días en minutos
    "idle-seeding-limit-enabled": true,

    // --- Filesystem -------------------------------------------------------
    "preallocation": 1,                           // 0=off, 1=fast, 2=full
    "rename-partial-files": true,                 // .part durante descarga, sin .part al terminar
    "trash-original-torrent-files": false,       // mantiene los .torrent en /watch (re-añadir)

    // --- Logs y diagnóstico -----------------------------------------------
    "message-level": 2,                           // 0=none, 1=error, 2=info, 3=debug

    // --- Blocklists -------------------------------------------------------
    "blocklist-enabled": true,
    "blocklist-url": "https://github.com/Naunter/BT_BlockLists/raw/master/bt_blocklists.gz"
}
```

Aplicar y arrancar:

```bash
docker compose -f ~/homelab/descargas/docker-compose.yml start transmission
docker logs transmission --tail 20
```

Esperar al `(healthy)` y comprobar que la web UI responde con la nueva configuración:

```bash
docker exec transmission transmission-remote -n "${TRANSMISSION_USER}:${TRANSMISSION_PASS}" -si
# Listo: stats del daemon — confirma que rpc-username y rpc-password siguen funcionando.
```

### Cambiar la contraseña RPC más adelante

```bash
docker compose -f ~/homelab/descargas/docker-compose.yml stop transmission
sudoedit /mnt/hd2t/services/transmission/config/settings.json
# Localizar "rpc-password" y reemplazar el hash {<...>} por la NUEVA password EN CLARO.
# Transmission la rehasheará al arrancar (cadena que vuelve a empezar por '{').
docker compose -f ~/homelab/descargas/docker-compose.yml start transmission
# Actualizar también ~/homelab/descargas/.env con TRANSMISSION_PASS=<nueva>
# para coherencia (la .env es la fuente humana de verdad; settings.json es el hash derivado).
```

> **No** intentar cambiarla con el contenedor en marcha — Transmission persiste el hash al apagar y machacaría el cambio. Tampoco intentar cambiar `rpc-username` desde la UI (Transmission no lo permite); editar `settings.json` con el contenedor parado.

### Cuotas de espacio: `download-dir-free-space-bytes`

Añadir al `settings.json` (con el contenedor parado, al editar):

```jsonc
"download-dir-free-space-bytes": 21474836480,   // 20 GB libres mínimos
```

Cuando `/mnt/hd2t` baje de 20 GB libres, Transmission **deja de añadir nuevos torrents** automáticamente. Más liviano que `df -h` por cron y se integra en la web UI.

### Suscribirse a una `blocklist`

`blocklist-enabled: true` y `blocklist-url` están en el bloque arriba. Para forzar un refresco manual desde la web UI: _Settings → Peers → Blocklist → Update_. La lista descargada vive en `config/blocklists/` y se re-aplica al arrancar el daemon.

### Notificaciones por _torrent done_ (opcional)

Transmission soporta `script-torrent-done-enabled` + `script-torrent-done-filename`. Útil para invocar un webhook o copiar el fichero a un sitio extra. **Fuera de alcance** de este documento; cuando lleguen Sonarr/Radarr, el "_post-processing_" lo orquestan ellos vía API y el script de done queda sin uso. Si en algún momento se quiere notificar al operador (Telegram, etc.), añadir aquí el script y volver al doc.

---

## Almacenamiento

Tras el primer arranque, el árbol `/mnt/hd2t/services/transmission/` queda con los siguientes ficheros relevantes:

```
/mnt/hd2t/services/transmission/
├── config/
│   ├── settings.json               # configuración principal (editado a mano arriba)
│   ├── stats.json                  # estadísticas acumuladas (uploaded, downloaded, ratio)
│   ├── dht.dat                     # estado del DHT (peers conocidos)
│   ├── resume/
│   │   ├── *.resume                # estado de cada torrent (paused/running, prioridades)
│   │   └── *.magnet                # metadata de magnet links pendientes
│   ├── torrents/
│   │   └── *.torrent               # copias canónicas de los torrents añadidos
│   ├── blocklists/
│   │   ├── bt_blocklists.bin       # binario compilado de la blocklist activa
│   │   └── bt_blocklists.bin.tmp   # transitorio durante refresco
│   └── log/
│       └── transmission.log        # log del daemon (rota internamente)
├── downloads/                      # ficheros descargados completos
│   ├── ubuntu-25.04-desktop-amd64.iso
│   └── ...
├── incomplete/                     # .part de descargas en curso (desaparecen al terminar)
│   └── *.part
└── watch/                          # drop-in: cualquier .torrent aquí lo arranca el daemon
    └── (vacío salvo durante drag-and-drop manual)
```

| Ruta                                                          | Permisos        | Contenido                                                       |
|---------------------------------------------------------------|-----------------|------------------------------------------------------------------|
| `/mnt/hd2t/services/transmission/`                            | `1000:1000 0755` | Raíz del bind mount                                              |
| `/mnt/hd2t/services/transmission/config/`                     | `1000:1000 0755` | Configuración persistente                                        |
| `/mnt/hd2t/services/transmission/config/settings.json`        | `1000:1000 0600` | Configuración (incluye hash MD5 de la password — `0600`)          |
| `/mnt/hd2t/services/transmission/config/resume/`              | `1000:1000 0755` | Estado por _torrent_                                             |
| `/mnt/hd2t/services/transmission/config/torrents/`            | `1000:1000 0755` | Copias de los `.torrent` añadidos                                |
| `/mnt/hd2t/services/transmission/downloads/`                  | `1000:1000 0755` | Ficheros descargados completos (lectura para _arr_, mismo grupo) |
| `/mnt/hd2t/services/transmission/incomplete/`                 | `1000:1000 0755` | `.part` de descargas en curso                                    |
| `/mnt/hd2t/services/transmission/watch/`                      | `1000:1000 0755` | Drop-in de `.torrent`                                            |

> **Sobre `umask: 2`**: con `umask 022`, los ficheros descargados acaban con `0644` y los directorios con `0755`. Esto permite a Sonarr/Radarr (corriendo también como `1000:1000`) leerlos y, **gracias a estar en el mismo filesystem `/mnt/hd2t`**, _hardlink_-arlos a `services/shared/media/` sin copiar bytes.

> **Sobre `settings.json` con `0600`**: contiene el hash MD5+salt de la password RPC. Aunque el hash sea más caro de invertir que un _plain text_, mejor mantenerlo legible sólo por `1000:1000`. La imagen LSIO crea el fichero con `0640` por defecto; este documento lo endurece a `0600`:
>
> ```bash
> sudo chmod 0600 /mnt/hd2t/services/transmission/config/settings.json
> ```

---

## Backup

Patrón **F** (filesystem-only). Transmission no tiene BD que dumpear; respaldar el árbol `/mnt/hd2t/services/transmission/config/` es suficiente para una restauración limpia.

### 1. Confirmar que `source_directories:` ya cubre Transmission

El `config.yaml` de Borgmatic (`docs/07-backups/02-borgmatic.md`) ya incluye `/mnt/hd2t/services/transmission/config` en `source_directories:` (ver `docs/07-backups/01-estrategia-backup.md` → **Inventario consolidado de fuentes**, línea `- /mnt/hd2t/services/transmission/config        # solo config, no descargas`). **No hay que añadir nada**.

### 2. Confirmar la exclusión de `downloads/` y añadir `incomplete/`

`exclude_patterns:` ya tiene `- /mnt/hd2t/services/transmission/downloads`. Añadir además `incomplete/` que es nuevo en este doc:

```bash
$EDITOR ~/homelab/backups/borgmatic/config.yaml
```

```yaml
exclude_patterns:
  # ... entradas existentes ...

  # Transmission — descargas regenerables (Categoría C) y .part transitorios.
  - /mnt/hd2t/services/transmission/downloads
  - /mnt/hd2t/services/transmission/incomplete
  - /mnt/hd2t/services/transmission/watch    # transitorio: el operador lo vacía con cada drop-in
```

Aplicar:

```bash
~/homelab/backups/borgmatic/install.sh
sudo /usr/bin/borgmatic --dry-run --verbosity 2 \
  | grep -E 'transmission|exclude' | head -20
```

Salida esperada: aparecen líneas para `transmission/config/`, `transmission/config/resume/`, `transmission/config/torrents/`, etc., pero **no** `transmission/downloads/` ni `transmission/incomplete/`.

### 3. `dump-databases.sh`: nada que descomentar

El bloque comentado en `~/homelab/backups/borgmatic/hooks/dump-databases.sh` para Transmission dice:

```bash
# --- Transmission (settings.json + resume — Categoría F) — docs/10-descargas/01-transmission.md
# /mnt/hd2t/services/transmission/config/ entra como source_directory.
```

No hay `dump_*` que descomentar — Transmission no tiene BD. La fila Patrón F en `docs/07-backups/03-backup-docker-volumes.md` lo confirma: "Transmission | _ninguna_ | F".

### 4. Confirmar que el archive incluye Transmission tras el siguiente run

Tras el siguiente _run_ programado (madrugada), Transmission aparece en la lista de archives:

```bash
sudo bash -c '
  set -a; . /etc/borgmatic.d/secrets.env; set +a
  borg list --short "$BORG_REPO_LOCAL" | tail -1
'
# pi-2026-04-26T03:30:30

sudo bash -c '
  set -a; . /etc/borgmatic.d/secrets.env; set +a
  borg list "$BORG_REPO_LOCAL::pi-2026-04-26T03:30:30" \
    | grep transmission | head -10
'
# -rw------- 1000   1000   8.2K Apr 26 02:00 mnt/hd2t/services/transmission/config/settings.json
# -rw-r--r-- 1000   1000   1.2K Apr 26 02:00 mnt/hd2t/services/transmission/config/stats.json
# drwxr-xr-x 1000   1000      - Apr 26 02:00 mnt/hd2t/services/transmission/config/resume
# -rw-r--r-- 1000   1000   3.4K Apr 26 02:00 mnt/hd2t/services/transmission/config/resume/<hash>.resume
# ...
```

Confirmar que **NO** aparece `mnt/hd2t/services/transmission/downloads/` (Categoría C, regenerable):

```bash
sudo bash -c '
  set -a; . /etc/borgmatic.d/secrets.env; set +a
  borg list "$BORG_REPO_LOCAL::pi-2026-04-26T03:30:30" \
    | grep "transmission/downloads" | head -3
'
# (vacío)
```

### Restauración

Procedimiento idéntico al **Patrón de restauración común** documentado en `docs/07-backups/03-backup-docker-volumes.md`. En resumen:

1. `docker compose -f ~/homelab/descargas/docker-compose.yml stop transmission`.
2. Mover `/mnt/hd2t/services/transmission/config/` a `config.broken-<ts>` (no borrar — preservar 24-48 h).
3. `borg extract` del archive elegido a `/tmp/restore-$$/`, mover en sitio.
4. Restaurar ownership:

   ```bash
   sudo chown -R 1000:1000 /mnt/hd2t/services/transmission/config
   sudo chmod 0600 /mnt/hd2t/services/transmission/config/settings.json
   ```

5. `docker compose -f ~/homelab/descargas/docker-compose.yml up -d transmission`.
6. Esperar al `(healthy)`. Transmission re-_hashea_ los _torrents_ activos contra los ficheros físicos en `/downloads/` (puede tardar minutos por _torrent_ grande); el progreso recuperado depende de cuánto haya cambiado el filesystem desde el archive.
7. Comprobar la web UI y que los _torrents_ siguen activos. Los `.part` de `/incomplete/` se habrán perdido (excluidos del backup) — Transmission los volverá a descargar desde cero o desde el último _piece_ contiguamente verificable en `/downloads/`.

> **Caso especial — pérdida del disco**: si se pierde `/mnt/hd2t` entero, los ficheros físicos de `/downloads/` también desaparecen. Tras restaurar `config/`, Transmission reportará todos los _torrents_ como "missing files"; el operador puede borrarlos en bloque (ya no aporta nada conservar el `.resume`). Los _torrents_ con seeders activos se re-añaden desde cero.

---

## Verificación

Antes de dar por cerrado este documento:

- [ ] `~/homelab/descargas/docker-compose.yml` y `~/homelab/descargas/.env.example` versionados en git; `~/homelab/descargas/.env` **no** versionado (`.gitignore` activo).
- [ ] `docker compose -f ~/homelab/descargas/docker-compose.yml ps` muestra `transmission` como `(healthy)`.
- [ ] `docker exec transmission wget -qO- --header='Authorization: Basic ZHVtbXk6ZHVtbXk=' http://localhost:9091/transmission/web/ 2>&1 | head -1` devuelve una respuesta HTTP (típicamente `401`).
- [ ] `docker exec transmission transmission-remote -n "${TRANSMISSION_USER}:${TRANSMISSION_PASS}" -si` devuelve estadísticas válidas (uptime, version, ratio).
- [ ] `docker exec caddy caddy validate --config /etc/caddy/Caddyfile` acepta el bloque `transmission.lan` añadido.
- [ ] `curl -k --resolve transmission.lan:443:192.168.1.3 -I https://transmission.lan/transmission/web/` devuelve `401` con `www-authenticate: Basic realm="Transmission"` (sin auth).
- [ ] `curl -k --resolve transmission.lan:443:192.168.1.3 -u "${TRANSMISSION_USER}:${TRANSMISSION_PASS}" -I https://transmission.lan/transmission/web/` devuelve `200`.
- [ ] Login interactivo desde el navegador con _basic auth_ funciona; tras login se ve la web UI con la lista (vacía la primera vez) de _torrents_.
- [ ] `ss -tulpn '( sport = :51413 )'` en el host muestra a Docker bindeando `0.0.0.0:51413` sobre tcp y udp.
- [ ] `docker port transmission` lista `51413/tcp -> 0.0.0.0:51413` y `51413/udp -> 0.0.0.0:51413`. La web UI (`9091/tcp`) **no** debe aparecer.
- [ ] Añadir un _torrent_ pequeño de prueba (p. ej. una distro Linux: <https://www.archlinux.org/releng/releases/>) y verificar que descarga: aparece en la web UI y los ficheros llegan a `/mnt/hd2t/services/transmission/downloads/`.
- [ ] Mientras descarga, el `.part` aparece en `/mnt/hd2t/services/transmission/incomplete/`. Al terminar, el fichero final aparece en `downloads/` y desaparece de `incomplete/`.
- [ ] `stat -c '%U:%G %a' /mnt/hd2t/services/transmission/downloads/<fichero>.iso` devuelve `1000:1000 644`.
- [ ] Verificar co-residencia con `services/shared/media/`:

  ```bash
  stat -c '%m' /mnt/hd2t/services/transmission/downloads /mnt/hd2t/services/shared/media
  # /mnt/hd2t
  # /mnt/hd2t
  ```

  Ambos deben devolver `/mnt/hd2t`. Si difieren, los _hardlinks_ futuros de Sonarr/Radarr fallarán — revisar `fstab` y montajes.

- [ ] _Settings → Network → Port_ en la web UI muestra el puerto `51413`. _Status_ del puerto: **Closed** (esperado, sin port-forwarding del router).
- [ ] El bloque `transmission.lan` del `Caddyfile` lleva `import security-headers`, `import logging` y la directiva `redir / /transmission/web/ 302`; **no** lleva `import authelia`.
- [ ] La lista `two_factor` del `access_control.rules` de Authelia **no** menciona `transmission.lan` (ni siquiera comentado).
- [ ] Watchtower vigila el contenedor: `docker logs watchtower --tail 50 | grep transmission` muestra al menos un check (label `enable: "true"` activo).
- [ ] `stat -c '%U:%G' /mnt/hd2t/services/transmission /mnt/hd2t/services/transmission/{config,downloads,incomplete,watch}` devuelve `1000:1000` en los cinco.
- [ ] `docker exec transmission id` muestra `uid=1000 gid=1000`.
- [ ] El siguiente run de Borgmatic incluye `mnt/hd2t/services/transmission/config/` y **excluye** `mnt/hd2t/services/transmission/{downloads,incomplete,watch}/`.

---

## Troubleshooting

### Primer arranque: el contenedor se queda en `starting` indefinidamente

```bash
docker logs transmission --tail 50
```

Causas comunes:

- **Permisos del bind mount**: si por error se hizo un `chown -R root:root /mnt/hd2t/services/transmission`, el _entrypoint_ de LSIO falla al hacer `chown` del nivel superior. Restaurar:

  ```bash
  sudo chown -R 1000:1000 /mnt/hd2t/services/transmission
  docker compose -f ~/homelab/descargas/docker-compose.yml restart transmission
  ```

- **`/etc/localtime` ausente**: aunque Transmission tolera su ausencia, sin el _zoneinfo_ los timestamps de la web UI aparecen en UTC. Crear el symlink:

  ```bash
  sudo ln -sf /usr/share/zoneinfo/Europe/Madrid /etc/localtime
  ```

- **Puerto `:51413` ocupado por otro proceso**: el contenedor falla con `bind: address already in use`. Localizar el culpable y resolver:

  ```bash
  sudo ss -tulpn 'sport = :51413'
  # Identificar el PID, parar el proceso o cambiar TRANSMISSION_PEER_PORT en .env.
  ```

### `401 Unauthorized` desde el navegador a pesar de tener la contraseña correcta

El _basic auth_ de Transmission usa un hash MD5+salt; si después de cambiar `TRANSMISSION_PASS` en `.env` el contenedor ya tenía un `settings.json` previo, **el cambio NO se aplicó** (LSIO no sobreescribe `settings.json` existente). Soluciones:

1. **Vía settings.json** (recomendado): parar el contenedor, editar `settings.json`, reemplazar el hash `{...}` por la nueva password en _plain text_, arrancar. Transmission la rehasheará al arrancar.

2. **Vía reset completo**: borrar `settings.json` y dejar que LSIO lo regenere desde la `.env` (se pierde el resto de configuración manual):

   ```bash
   docker compose -f ~/homelab/descargas/docker-compose.yml stop transmission
   sudo cp /mnt/hd2t/services/transmission/config/settings.json{,.bak}
   sudo rm /mnt/hd2t/services/transmission/config/settings.json
   docker compose -f ~/homelab/descargas/docker-compose.yml start transmission
   ```

3. **Volver a aplicar la configuración manual** (host-whitelist, peer-port-random-on-start=false, etc.) desde la sección **`settings.json` recomendado** de este doc.

### `409: <h1>Conflict</h1>` al hacer `curl` o navegar a `transmission.lan`

Causa típica: la _CSRF_ de Transmission devuelve un `X-Transmission-Session-Id` cabecera que el cliente debe re-enviar en peticiones subsiguientes. Es comportamiento normal de la API JSON-RPC. La web UI lo gestiona automáticamente; los clientes _native_ también. Desde `curl`, hay que extraer la cabecera y reenviarla:

```bash
SID=$(curl -k -s -u "${TRANSMISSION_USER}:${TRANSMISSION_PASS}" \
  --resolve transmission.lan:443:192.168.1.3 \
  https://transmission.lan/transmission/rpc \
  -i | grep -i x-transmission-session-id | awk '{print $2}' | tr -d '\r')

curl -k -s -u "${TRANSMISSION_USER}:${TRANSMISSION_PASS}" \
  --resolve transmission.lan:443:192.168.1.3 \
  -H "X-Transmission-Session-Id: $SID" \
  -d '{"method":"session-stats"}' \
  https://transmission.lan/transmission/rpc | python3 -m json.tool
```

> **No** es el mismo `409` que el de "host-whitelist mismatch" — si fuese de host-whitelist, la respuesta diría `<h1>Forbidden</h1>` (no `Conflict`). Si aparece `Forbidden`, ir al siguiente apartado.

### `403 Forbidden` con `<h1>Forbidden</h1>` en el cuerpo

Transmission rechaza el _Host header_. Causas:

1. **`rpc-host-whitelist` no incluye `transmission.lan`**: parar el contenedor, editar `settings.json`, asegurarse de:

   ```jsonc
   "rpc-host-whitelist": "transmission.lan,*.ts.net,transmission",
   "rpc-host-whitelist-enabled": true
   ```

2. **Caddy no propaga el `Host` header**: revisar el bloque `transmission.lan` del `Caddyfile`, debe llevar `header_up Host {host}`. Sin esa línea, Caddy reescribe el `Host` a `transmission:9091` (el _backend_), y aunque eso _está_ en la whitelist, la _CSRF_ de Transmission falla por otras razones.

3. **Petición desde un cliente que pone un `Host` raro** (p. ej. una IP en vez de un nombre): añadir esa IP/nombre a `rpc-host-whitelist` o desactivar la whitelist (`rpc-host-whitelist-enabled: false`) — esto último sólo si el operador está seguro de que no expone Transmission a internet (no es el caso aquí).

### `External IP` que reporta Transmission no es la IP pública del router

Comportamiento normal con `network_mode: bridge`. Transmission ve su propia IP del bridge (`172.20.10.x`) y, al consultar a un servicio externo (`http://ipinfo.io/ip` por defecto), aprende la IP saliente real de la conexión doméstica. La IP saliente real del NAT del operador es la que se anuncia a los trackers — correcto.

Si el reporte sigue mostrando la IP interna, comprobar:

```bash
# Desde dentro del contenedor:
docker exec transmission wget -qO- http://ipinfo.io/ip
# Debe devolver la IP pública del operador.
```

Si **no** devuelve nada, el contenedor no tiene salida a internet (revisar la red `homelab` y, en última instancia, `nft list ruleset | grep -i drop`).

### Las descargas son "extremadamente lentas" o "se quedan a 0 KB/s con N peers"

En **modo passive only** (sin port-forwarding del router), la velocidad depende del _swarm_:

- _Torrents_ con muchos seeders con puertos abiertos: velocidad cercana al _cap_ de la conexión doméstica.
- _Torrents_ con pocos seeders, todos en modo passive como nosotros: muy lento o nulo, porque nadie acepta conexiones entrantes y todos esperan que el otro las inicie. Es la limitación esperada del homelab; no es un bug.

Mitigaciones técnicas (sin cambiar la política):

1. **Habilitar UPnP en el router** (si lo permite el modelo y la configuración): poner `port-forwarding-enabled: true` en `settings.json`. Si el router responde, el puerto se abre temporalmente. Política del homelab: **no se hace**, ver `docs/13-operaciones/04-red-y-puertos.md`.
2. **Forzar TCP en lugar de µTP**: `utp-enabled: false`. Útil si el ISP filtra µTP en algún tramo. Reduce el _swarm_ alcanzable; sólo aplica como último recurso.
3. **Cambiar a _trackers_ con _IPv6_** (si la conexión doméstica tiene IPv6 nativo y el router enruta IPv6 sin NAT): IPv6 no requiere port-forwarding. `bind-address-ipv6: "::"` y comprobar que el contenedor recibe IPv6.

### Sonarr/Radarr (futuras fases) reportan `401 Unauthorized` al conectar a Transmission

Cuando lleguen `docs/10-descargas/03-sonarr.md` y `docs/10-descargas/04-radarr.md`, ahí se configurará la conexión _arr_ → Transmission por DNS interno (`http://transmission:9091/transmission/rpc`). Si aparece `401`, las posibilidades son:

1. La _basic auth_ está mal configurada en _Sonarr/Radarr → Settings → Download Clients → Transmission_. Verificar `Username` y `Password` (los mismos que `TRANSMISSION_USER`/`TRANSMISSION_PASS` del `.env` del homelab).
2. La whitelist de IPs (`rpc-whitelist`) **está activada** y no incluye la subnet `172.20.10.0/24`. Como en `settings.json` ya se incluye `172.20.10.0/24` y `rpc-whitelist-enabled` está en `false`, **no debería pasar**, pero si en algún momento se activase, asegurarse de incluir la subnet.

### El _torrent_ se completa pero Sonarr/Radarr no lo recogen (futuras fases)

Foreshadow para `docs/10-descargas/03-sonarr.md` / `04-radarr.md`: el _arr_ pollea la API de Transmission cada cierto tiempo. Si después de "Mark as completed" en Transmission, Sonarr/Radarr no lo recogen, comprobar:

1. _Sonarr/Radarr → Activity → Queue_: ¿aparece el _torrent_ ahí? Si no, el _arr_ no lo conoce — el operador lo añadió a Transmission a mano sin pasar por Sonarr/Radarr. Eso lo mueve el operador manualmente, fuera del flujo automatizado.
2. _Sonarr/Radarr → System → Logs_: errores del tipo `Failed to import` con `Permission denied`. Causa: el _arr_ corre como `1000:1000` igual que Transmission, pero el _hardlink_ a `services/shared/media/` falla porque el directorio destino tiene permisos `2775` con _setgid_ y el _arr_ no tiene `MEDIA_GID` como _supplementary group_. Solución: añadir `group_add: ["${MEDIA_GID}"]` al servicio _arr_ correspondiente. Ese detalle se documentará en su fase.

---

## Actualización

### Patches de la línea `4.0.x` (vía Watchtower, automático)

Watchtower opt-in está activo. Cada domingo a las 04:00 UTC, Watchtower comprueba el _digest_ del _tag_ `4.0.6`; si LSIO publica un re-build (mismo _tag_, distinto _digest_), Watchtower hace `pull` + `recreate` del contenedor. Sin acción del operador.

Verificar tras un domingo:

```bash
docker logs watchtower --tail 50 | grep transmission
# time=... msg="Found new lscr.io/linuxserver/transmission:4.0.6 image"
# time=... msg="Stopping /transmission"
# time=... msg="Creating /transmission"
```

Si tras la recreación el `(healthy)` no llega en 90 s, ir a **Troubleshooting**.

### Bumps de patch (`4.0.6 → 4.0.7`, manual)

```bash
# 1. Leer las release notes
xdg-open https://github.com/transmission/transmission/releases/tag/4.0.7
# Y la release notes de LSIO:
xdg-open https://github.com/linuxserver/docker-transmission/releases

# 2. Backup completo previo
sudo /usr/bin/borgmatic --verbosity 1
# Verificar que el último archive tiene fecha de hoy.

# 3. Cambiar el tag y aplicar
$EDITOR ~/homelab/descargas/.env
# TRANSMISSION_IMAGE_TAG=4.0.7
cd ~/homelab
make pull STACK=descargas
make up STACK=descargas

# 4. Vigilar el log durante el reinicio
docker compose -f ~/homelab/descargas/docker-compose.yml logs -f transmission
# Buscar:
#   transmission | [Service] Started transmission-daemon (4.0.7)
# Si el log muestra ERROR o el contenedor entra en restart loop, ir a Troubleshooting.

# 5. Validar la web UI y que los torrents activos siguen donde estaban.
```

### Bumps de _minor_ (`4.0 → 4.1`)

- Suelen incluir cambios en `settings.json` (claves nuevas con _defaults_; raro que rompan claves existentes).
- Planificar la actualización en una ventana de mantenimiento.
- Considerar saltar a `4.1.1` o similar (la versión `.0` a menudo tiene bugs que se arreglan en el primer _patch_).
- Tras el upgrade, comprobar que los _torrents_ activos no han perdido progreso (re-_hashing_ rápido al arrancar es esperado; pérdida de progreso real, no).

### Bumps de _major_ (`4.x → 5.x`)

- Cambios estructurales relevantes; planificar con cuidado y leer la guía de migración del proyecto.
- Verificar compatibilidad con Sonarr/Radarr/Prowlarr antes de aplicarlo (pueden requerir actualizar el cliente _arr_ a una versión que entienda la nueva API JSON-RPC).
- Backup previo + plan de _rollback_ (`TRANSMISSION_IMAGE_TAG=4.0.6` y `make up STACK=descargas` para volver atrás).

---

## Referencias

- Documentación oficial — Transmission: <https://github.com/transmission/transmission/blob/main/docs/Editing-Configuration-Files.md>
- API JSON-RPC — especificación: <https://github.com/transmission/transmission/blob/main/docs/rpc-spec.md>
- Imagen Docker — LinuxServer.io `transmission`: <https://github.com/linuxserver/docker-transmission>
- LSIO `transmission` — Docker Hub: <https://hub.docker.com/r/linuxserver/transmission>
- Releases de Transmission: <https://github.com/transmission/transmission/releases>
- Reverse proxy con Caddy — Transmission sample: <https://docs.linuxserver.io/general/swag/#caddy>
- DNS rebinding y `rpc-host-whitelist`: <https://github.com/transmission/transmission/issues/1107>
- Trackers para distros Linux (uso legítimo de prueba): <https://www.archlinux.org/releng/releases/>, <https://ubuntu.com/download/alternative-downloads>
- Documentos relacionados del homelab:
  - `docs/01-sistema/04-estructura-directorios.md` — `/mnt/hd2t/services/transmission/{config,downloads,watch}` con ownership `1000:1000`.
  - `docs/02-docker/02-estructura-compose.md` — convenciones de stacks, red `homelab`, regla `:ro` (no aplica aquí: Transmission escribe).
  - `docs/02-docker/04-watchtower.md` — opt-in para `4.0.x`, ventana dominical.
  - `docs/03-red/02-pihole.md` — DNS local `*.lan` (cubre `transmission.lan` por wildcard).
  - `docs/03-red/04-caddy.md` — Caddy, CA local, _snippets_ `security-headers` y `logging`.
  - `docs/03-red/05-tailscale.md` — acceso remoto vía VPN sin abrir puertos en el router.
  - `docs/04-seguridad/01-authelia.md` — por qué Transmission **no** entra en `forward_auth`.
  - `docs/07-backups/01-estrategia-backup.md` — Categoría F para `config/`, Categoría C para `downloads/`.
  - `docs/07-backups/02-borgmatic.md` — `source_directories`, `exclude_patterns`.
  - `docs/07-backups/03-backup-docker-volumes.md` — Patrón F (filesystem-only).
  - `docs/10-descargas/02-prowlarr.md` (siguiente fase) — gestor unificado de indexadores.
  - `docs/10-descargas/03-sonarr.md` (siguiente fase) — series; integra con Transmission por DNS interno.
  - `docs/10-descargas/04-radarr.md` (siguiente fase) — películas; integra con Transmission por DNS interno.
  - `docs/13-operaciones/04-red-y-puertos.md` — política de puertos del homelab (sin port-forwarding del router).
