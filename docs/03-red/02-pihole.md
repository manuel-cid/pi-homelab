# Pi-hole (DNS + ad-blocking)

## Descripción

Despliegue de **Pi-hole** como servidor DNS de toda la LAN doméstica. Asume las decisiones tomadas en `docs/03-red/01-macvlan.md` y `docs/02-docker/02-estructura-compose.md`: Pi-hole corre en la red Docker `lan` (driver `macvlan`, _parent_ `eth0`) con **IP propia `192.168.1.2`** y **MAC fija `02:42:c0:a8:01:02`** ya reservadas en el DHCP del router. Desde el punto de vista de la LAN aparece como un dispositivo más, escucha en `53/udp`, `53/tcp` y `80/tcp` sobre esa IP, y deja la IP de la Pi (`192.168.1.3`) libre para Caddy y el resto de servicios.

Este documento estrena además el _stack_ **`red`** (`~/homelab/red/`), el contenedor de los servicios "transversales de red" del homelab. Pi-hole es el primero en aterrizar; en las fases siguientes se le suman Unbound (`docs/03-red/03-unbound.md`), Caddy (`docs/03-red/04-caddy.md`) y, opcionalmente, Tailscale (`docs/03-red/05-tailscale.md`) en el mismo `docker-compose.yml`. La red `homelab` (bridge interno) se usa además de la `lan` para que Caddy pueda hacer _reverse proxy_ HTTPS de la propia UI de Pi-hole sin volver a exponer puertos.

> **Alcance**: este documento despliega **únicamente** Pi-hole. **No** instala Unbound (eso llega en `docs/03-red/03-unbound.md`; mientras tanto el _upstream_ es Cloudflare como medida transitoria), **no** define el `Caddyfile` ni la _CA_ local (`docs/03-red/04-caddy.md`), **no** configura Tailscale (`docs/03-red/05-tailscale.md`) y **no** integra con Authelia (`docs/04-seguridad/01-authelia.md`). El acceso a la UI durante esta fase se hace por **HTTP plano** sobre la IP macvlan, lo que es aceptable porque sólo está expuesto a la LAN doméstica; cuando llegue Caddy, el `:80` se atará al _reverse proxy_ y se obligará HTTPS.

> **Recordatorio de red**: el homelab vive en LAN + Tailscale. Pi-hole **no** se publica a internet. Las consultas DNS de la LAN viajan en claro al puerto 53 de la IP macvlan; las consultas que la propia Pi-hole reenvía al _upstream_ van al `1.1.1.1` por TCP/UDP estándar (DoT/DoH se evalúa cuando aparezca Unbound).

---

## Requisitos previos

- `docs/03-red/01-macvlan.md` completado: red Docker `lan` (driver `macvlan`, `--ip-range 192.168.1.0/29`) creada, _shim_ `macvlan-shim` activo en el host con ruta a `192.168.1.0/29`, reservas DHCP por MAC en el router para `02:42:c0:a8:01:02 → 192.168.1.2` ya aplicadas.
- `docs/02-docker/02-estructura-compose.md` completado: red Docker `homelab` (bridge `br-homelab`, `172.20.10.0/24`) creada, `~/homelab/.env` con `TZ=Europe/Madrid` y `HOMELAB_DOMAIN=lan`, repositorio git inicializado, _Makefile_ con `make up STACK=...`.
- `docs/01-sistema/04-estructura-directorios.md` completado: `/mnt/hd2t/services/pihole/etc-pihole/` y `/mnt/hd2t/services/pihole/etc-dnsmasq.d/` ya existen como directorios vacíos `root:root 0755` (los puebla la imagen oficial en su primer arranque, no se hace `chown` previo).
- `docs/01-sistema/03-seguridad-base.md` completado: `nftables` con `input drop` por defecto. **Importante**: el host **no** debe tener un servicio escuchando en `:53` (ni `systemd-resolved` con _stub-listener_ ni `dnsmasq` propio). Confirmar con:

  ```bash
  sudo ss -tulpn | grep ':53 '
  ```

  Salida esperada: vacía. Si aparece `systemd-resolve`, este se desactivó en `docs/01-sistema/02-configuracion-inicial.md`; si reaparece tras un _reboot_, revisar `systemctl is-active systemd-resolved`.

- Conectividad saliente: `docker pull --platform linux/arm64 pihole/pihole:2024.07.0 >/dev/null && echo OK` debe funcionar.

---

## Decisiones de diseño

### Pi-hole en dos redes a la vez (`lan` + `homelab`)

Pi-hole lleva **dos interfaces**:

| Interfaz | Red Docker | IP                | Quién la usa                                                  |
|----------|------------|-------------------|---------------------------------------------------------------|
| `eth0`   | `lan`      | `192.168.1.2`     | Clientes DNS de la LAN (móvil, portátil, _smart TV_, IoT…)    |
| `eth1`   | `homelab`  | `172.20.10.X` (auto) | Caddy (`docs/03-red/04-caddy.md`) para hacer _reverse proxy_ HTTPS de la UI |

Es un patrón soportado por Compose: las dos redes se declaran en `networks:` del servicio y Docker crea una `eth0` y una `eth1` dentro del contenedor. Pi-hole (`lighttpd` en `:80` y `pihole-FTL` en `:53`) bindea a `0.0.0.0` por defecto, así que ambas IPs responden sin tocar nada extra.

> **Por qué no sólo macvlan**: si Pi-hole sólo estuviera en `lan`, Caddy (que vive en la red `homelab`) no podría alcanzarla por DNS interno de Docker (`pihole:80`) y tendría que ir a `192.168.1.2` por la LAN, lo que pasa por el switch en lugar de quedarse dentro del host. Funciona, pero pierde el _DNS embedded_ de Docker y obliga a Caddy a confiar en la IP fija. Con Pi-hole en `homelab` también, Caddy hace `reverse_proxy pihole:80` por nombre y todo el tráfico se queda en `br-homelab`.

> **Por qué no sólo bridge**: si Pi-hole sólo estuviera en `homelab`, los clientes de la LAN no podrían usarla como DNS sin publicar `ports: 53:53` en la Pi, ocupando el puerto 53 del host (precisamente lo que `docs/03-red/01-macvlan.md` evita).

### Imagen y _tag_

- **`pihole/pihole:2024.07.0`** (Pi-hole **v5.18.4**, última v5).
- Se pinnea explícitamente; **no** se usa `:latest` ni `:2024` (convención del homelab: _tags_ con versión completa, ver `docs/02-docker/04-watchtower.md`).
- Se descarta de momento la rama **v6** (`2025.x`): introduce un _config TOML_ unificado, cambia el _webserver_ a uno embebido en FTL y renombra prácticamente todas las variables de entorno (`WEBPASSWORD` → `FTLCONF_webserver_api_password`, `PIHOLE_DNS_` → `FTLCONF_dns_upstreams`, …). La migración a v6 se trata como cambio mayor y queda fuera de _opt-in_ de Watchtower (ver `docs/02-docker/04-watchtower.md`); se documentará en su día como un _bump_ deliberado.

### _Upstream_ inicial: Cloudflare

Hasta que Unbound esté operativo (`docs/03-red/03-unbound.md`), el _upstream_ de Pi-hole es **`1.1.1.1;1.0.0.1`** (Cloudflare, IPv4). Es un compromiso transitorio: bloqueamos publicidad y telemetría a nivel de red (función principal de Pi-hole), pero seguimos delegando la resolución recursiva a un tercero. En cuanto Unbound levante en `192.168.1.4#5335`, este valor cambia a `192.168.1.4#5335` y se elimina la dependencia externa.

> **No** se usa el DNS del router como _upstream_: el router resuelve contra el ISP, lo que añade un salto sin _DNSSEC_ y registra todas las consultas en el _telco_. `1.1.1.1` no es perfecto pero es mejor que esa cadena.

### Servidor DHCP

Pi-hole **no** asume el rol de servidor DHCP. El router doméstico sigue siendo el servidor DHCP de la LAN; lo único que cambia es la **opción 6** (DNS) que el router anuncia: pasa de `192.168.1.1` (su propia resolución contra el ISP) a `192.168.1.2` (Pi-hole).

Razones:

- Mantener separados DHCP y DNS reduce la huella de un fallo: si Pi-hole se cae, los _leases_ DHCP siguen renovándose y la LAN sigue navegando con un DNS de _fallback_ que se configura en este mismo doc.
- El router doméstico tiene una UI de DHCP estable; la de Pi-hole funciona, pero migrar la LAN entera a su gestión añade ruido sin beneficio claro.
- Si el día de mañana se quisiera hostnames `nombre.lan` automáticos por DHCP (con `dnsmasq`), se reevalúa: Pi-hole soporta el papel cuando hace falta.

### Listeners DNS y `FTLCONF_LOCAL_IPV4`

Variables que Pi-hole interpreta sobre macvlan (Pi-hole ve `eth0` con `192.168.1.2/24`, `eth1` con `172.20.10.X/24`):

- **`DNSMASQ_LISTENING=all`**: dnsmasq tiene una lógica anti-_DNS amplification_ que, cuando detecta que su IP está en una red privada con _gateway_ extraño, restringe las _interfaces_ a las que responde. Sobre macvlan eso falla con falsos positivos y acaba contestando sólo a `127.0.0.1`, dejando muda la `192.168.1.2`. Forzar `all` evita ese silencio.
- **`FTLCONF_LOCAL_IPV4=192.168.1.2`**: la IP que Pi-hole declara como "su propia IP" para resolver `pi.hole`, `pihole.lan` y para los registros A locales que se creen. Sin esto, Pi-hole adivina y suele coger la `eth1` (la del bridge `homelab`), que es interna y no resuelve para la LAN.

### Almacenamiento

| Ruta en el host                              | Contenido                                                    | Backup                              |
|----------------------------------------------|--------------------------------------------------------------|-------------------------------------|
| `/mnt/hd2t/services/pihole/etc-pihole/`      | `setupVars.conf`, `gravity.db` (listas de bloqueo), `pihole-FTL.db` (registro de consultas), `dhcp.leases` (vacío en nuestro caso) | Sí                                  |
| `/mnt/hd2t/services/pihole/etc-dnsmasq.d/`   | `02-homelab-local.conf` (DNS local versionable), `04-pihole-static.conf`, `05-pihole-custom-cname.conf` (los crea la UI) | Sí (parcial; ver sección **Backup**) |

Volúmenes _bind-mount_, no _named_, por convención (`docs/01-sistema/04-estructura-directorios.md`).

---

## Estructura del _stack_ `red`

`~/homelab/red/` aún no existe. Tras este documento queda así:

```
~/homelab/red/
├── docker-compose.yml
├── .env
├── .env.example
└── etc-dnsmasq.d/
    └── 02-homelab-local.conf      # se monta en el contenedor; versionable
```

> **Por qué `etc-dnsmasq.d/` está dentro del repo**: la lista de records `*.lan` para los servicios del homelab es **configuración**, no datos en _runtime_. Vive en git (`~/homelab/red/etc-dnsmasq.d/02-homelab-local.conf`) y se monta en el contenedor superpuesta a la rama de datos (`/mnt/hd2t/services/pihole/etc-dnsmasq.d/`). Las decisiones que toma la UI de Pi-hole (CNAMEs locales, _whitelist_/_blacklist_ manual) **sí** acaban en `/mnt/hd2t/services/pihole/etc-dnsmasq.d/05-pihole-custom-cname.conf` y entran en el ciclo de Borgmatic, no en el repo.

Crear el subdirectorio:

```bash
mkdir -p ~/homelab/red/etc-dnsmasq.d
chmod 0750 ~/homelab/red
```

> Permisos `0750`: un único usuario (`homelab`) tiene que poder leer y editar; el resto del sistema no necesita leer el `Caddyfile` o el `02-homelab-local.conf` cuando aterricen.

---

## Variables de entorno

`red/.env.example` (versionado en git, sin valores reales):

```bash
# ~/homelab/red/.env.example
# Plantilla — copiar a red/.env y rellenar.

# Tags de imagen pinneados (no usar 'latest' — convención del homelab).
PIHOLE_IMAGE_TAG=2024.07.0

# Contraseña del admin del Pi-hole. Se aplica en el primer arranque y se
# guarda hasheada en setupVars.conf. Para cambiarla más tarde, usar
# `docker exec pihole pihole -a -p` (ignora WEBPASSWORD tras el primer
# arranque).
PIHOLE_WEB_PASSWORD=

# IP del propio Pi-hole en la red 'lan' macvlan. Debe coincidir con
# 'ipv4_address' del docker-compose.yml y con la reserva DHCP del router.
PIHOLE_LAN_IPV4=192.168.1.2

# Upstreams DNS hasta que Unbound esté operativo (docs/03-red/03-unbound.md).
# Cuando Unbound levante, sustituir por '192.168.1.4#5335'.
PIHOLE_UPSTREAMS=1.1.1.1;1.0.0.1
```

`red/.env` (a partir del _example_, **no** se _commitea_):

```bash
cd ~/homelab/red
cp .env.example .env
chmod 0600 .env
```

Generar una contraseña fuerte (24 caracteres alfanuméricos) para `PIHOLE_WEB_PASSWORD`:

```bash
LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24
```

Anotarla en el gestor de contraseñas (será la contraseña de _bootstrap_; cuando Vaultwarden esté operativo, se rota desde la propia UI de Pi-hole).

---

## Configuración: DNS local para servicios `*.lan`

`~/homelab/red/etc-dnsmasq.d/02-homelab-local.conf`:

```conf
# DNS local del homelab — todos los servicios *.lan resuelven a la IP de
# la propia Pi (donde escucha Caddy en :443 / :80).
# Se monta en read-only dentro del contenedor para que la UI de Pi-hole
# no lo edite por error.

# Wildcard: cualquier *.lan apunta a la Pi (Caddy hace el SNI matching).
address=/lan/192.168.1.3

# Excepciones — servicios cuyo backend no está detrás de Caddy:
# - pihole.lan resuelve a la propia IP macvlan (UI directa por si Caddy
#   está caído; cuando Caddy esté operativo, también responde por él).
address=/pihole.lan/192.168.1.2
# - unbound.lan se rellenará en docs/03-red/03-unbound.md.

# No reenviar consultas para *.lan al upstream (es un TLD inventado).
local=/lan/

# Log queries por dominio (Pi-hole ya las recoge en pihole-FTL.db, esto
# es para ver el match del wildcard si algo no resuelve).
log-queries
```

> **Por qué un `address=/lan/192.168.1.3` _wildcard_ y no un record por servicio**: Caddy hace _reverse proxy_ por SNI/host header (`docs/03-red/04-caddy.md`), no por IP. Resolver todo `*.lan` a la IP de la Pi y dejar que Caddy demultiplexe es más limpio: añadir un servicio nuevo (`paperless.lan`, `bookstack.lan`…) sólo requiere un bloque en el `Caddyfile`, sin tocar Pi-hole.

> **`local=/lan/`** evita que, si un cliente pregunta por `whatever.lan` para el que no hay record explícito, Pi-hole reenvíe la consulta a Cloudflare. Cloudflare devolvería `NXDOMAIN` (correcto), pero filtrar nombres internos al exterior es ruido innecesario.

Permisos:

```bash
chmod 0644 ~/homelab/red/etc-dnsmasq.d/02-homelab-local.conf
```

---

## `docker-compose.yml` del _stack_ `red`

```yaml
# ~/homelab/red/docker-compose.yml
# Convenciones: docs/02-docker/02-estructura-compose.md
# Pi-hole en red 'lan' (macvlan, IP propia en LAN) + 'homelab' (bridge,
# para reverse proxy de Caddy). Unbound (docs/03-red/03-unbound.md),
# Caddy (docs/03-red/04-caddy.md) y Tailscale (docs/03-red/05-tailscale.md)
# se añaden a este mismo fichero más adelante.

services:

  # ---------------------------------------------------------------------------
  # Pi-hole — DNS recursivo con bloqueo de publicidad/telemetría a nivel de red.
  # IP fija en la LAN (192.168.1.2) para que el router la anuncie como DNS.
  # MAC fija para que la reserva DHCP del router (docs/03-red/01-macvlan.md, paso 1)
  # encaje aunque el contenedor se recree.
  # ---------------------------------------------------------------------------
  pihole:
    image: pihole/pihole:${PIHOLE_IMAGE_TAG}
    container_name: pihole
    hostname: pihole
    mac_address: "02:42:c0:a8:01:02"
    restart: unless-stopped
    # NET_ADMIN no se concede: Pi-hole no actúa como servidor DHCP en
    # nuestro caso. Si en el futuro asume DHCP, añadir aquí.
    cap_add:
      - SYS_NICE                  # FTL ajusta su prioridad para responder rápido
    environment:
      TZ: ${TZ}
      WEBPASSWORD: ${PIHOLE_WEB_PASSWORD}
      # IP propia (la del macvlan, no la del bridge). Pi-hole la usa para
      # los registros A locales (pi.hole) y para detectar self-loops.
      FTLCONF_LOCAL_IPV4: ${PIHOLE_LAN_IPV4}
      # Forzar dnsmasq a escuchar en TODAS las interfaces. En macvlan, la
      # heurística anti-amplificación de dnsmasq falla en silencio si no
      # se le obliga.
      DNSMASQ_LISTENING: all
      # Upstream transitorio. Cuando Unbound esté operativo, cambiar a
      # PIHOLE_DNS_=192.168.1.4#5335 en red/.env.
      PIHOLE_DNS_: ${PIHOLE_UPSTREAMS}
      # DNSSEC en el propio Pi-hole, antes de delegar al upstream.
      # Cloudflare ya lo hace, pero forzarlo aquí garantiza que las
      # respuestas con AD-bit que llegan al cliente vienen validadas.
      DNSSEC: "true"
      # Mensajes de FTL al log (no al stdout) para que Dozzle no se sature.
      QUERY_LOGGING: "true"
      # Página por defecto del lighttpd cuando se accede a la raíz; Pi-hole
      # acepta 'admin' (redirige a /admin) o 'nothing'.
      VIRTUAL_HOST: pihole.lan
      # Interfaz de la que Pi-hole considera 'el lado LAN'. Sin esto,
      # asume eth0 dentro del contenedor; lo dejamos explícito.
      INTERFACE: eth0
    volumes:
      - /mnt/hd2t/services/pihole/etc-pihole:/etc/pihole
      - /mnt/hd2t/services/pihole/etc-dnsmasq.d:/etc/dnsmasq.d
      # Configuración versionable del DNS local del homelab. Read-only:
      # la UI de Pi-hole NO debe poder reescribir este fichero; los
      # records que se añadan desde la UI van a 05-pihole-custom-cname.conf
      # (en /etc/dnsmasq.d/, gestionado por Pi-hole).
      - ./etc-dnsmasq.d/02-homelab-local.conf:/etc/dnsmasq.d/02-homelab-local.conf:ro
    # DNS del propio contenedor: que se resuelva a sí mismo en localhost,
    # no por el DNS embedded de Docker (que en macvlan no responde igual).
    dns:
      - 127.0.0.1
      - 1.1.1.1                   # fallback durante el bootstrap (antes de
                                  # que pihole-FTL haya levantado dentro)
    networks:
      lan:
        ipv4_address: ${PIHOLE_LAN_IPV4}
      homelab:
        # IP automática del pool 172.20.10.0/24; Caddy la resuelve por nombre.
        aliases:
          - pihole
    labels:
      homelab.stack: "red"
      homelab.backup: "true"      # /etc/pihole y /etc/dnsmasq.d
      # No auto-update: pihole-FTL guarda BD propia, los release notes
      # entre minor versions han metido cambios de schema en el pasado.
      # Las actualizaciones se hacen a mano leyendo el changelog.
      com.centurylinklabs.watchtower.enable: "false"
    healthcheck:
      # Una consulta DNS al propio Pi-hole; si responde con NOERROR, está vivo.
      test: ["CMD", "dig", "+short", "+norecurse", "+retry=0", "@127.0.0.1", "pi.hole"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 60s

networks:
  lan:
    external: true                # creada en docs/03-red/01-macvlan.md
  homelab:
    external: true                # creada en docs/02-docker/02-estructura-compose.md
```

Notas de diseño:

- **`mac_address` explícito**: imprescindible para que la reserva DHCP del router se aplique. Si se omite, Docker genera una MAC aleatoria distinta en cada `up` y el router asigna `192.168.1.2` por reserva pero el contenedor pide otra IP, acabando con dos clientes en conflicto.
- **`hostname: pihole`**: aparece como _hostname_ del contenedor; lo usa Pi-hole en sus propios _logs_ (`pihole gravity update completed`) y se añade automáticamente al `/etc/hosts` interno apuntando a la IP de `eth0` (la de macvlan).
- **`dns: [127.0.0.1, 1.1.1.1]`**: Pi-hole se resuelve a sí mismo (cuando esté arriba). El `1.1.1.1` es _fallback_ para el primerísimo arranque, en el que `pihole-FTL` aún no está escuchando: sin él, el script de _bootstrap_ que hace `apt update` para refrescar listas falla con `Temporary failure in name resolution`.
- **`SYS_NICE`**: lo pide la imagen oficial para que `pihole-FTL` se ponga `nice -10` y responda con prioridad alta. Sin ello, FTL deja un _warning_ en el log pero arranca igual; con ello, las consultas DNS no compiten contra `borg create` o un `apt upgrade`.
- **`com.centurylinklabs.watchtower.enable: "false"`**: Pi-hole **no** entra en _opt-in_ de Watchtower. Las actualizaciones se hacen a mano (`docker compose pull pihole && docker compose up -d pihole`) tras leer las _release notes_, especialmente entre _minor_.
- **`dns_upstreams` por env vs por UI**: el `PIHOLE_DNS_` se aplica únicamente en el primer arranque, cuando `setupVars.conf` no existe. Tras eso, manda lo que diga `setupVars.conf` (lo que se haya configurado por la UI). Para cambiar el _upstream_ después del primer arranque, editar desde la UI o `docker exec pihole pihole -a -d 1` y reaplicar.

---

## Primer despliegue

```bash
cd ~/homelab/red
docker compose --env-file ../.env --env-file .env config | head -60   # validar sintaxis
docker compose --env-file ../.env --env-file .env up -d
```

O, equivalente, con el _Makefile_:

```bash
cd ~/homelab
make up STACK=red
```

El primer arranque tarda 2-3 minutos: pi-hole-FTL inicializa `gravity.db`, descarga la lista por defecto (StevenBlack ~150k entradas) y la compila. Verificar:

```bash
docker compose -f ~/homelab/red/docker-compose.yml ps
# NAME     STATUS                   PORTS
# pihole   Up 2 minutes (healthy)   53/tcp, 53/udp, 67/udp, 80/tcp
```

> Los puertos que `docker ps` reporta son los que **el contenedor declara** en su `EXPOSE`, no los que se publican al host. Sobre `macvlan`, las publicaciones efectivas son sobre la IP `192.168.1.2`, no sobre `0.0.0.0` del host. `ss -tulpn` en el host **no** lista esos puertos: viven en otro _namespace_ de red.

Probar la resolución desde la propia Pi (la ruta del _shim_ permite ese tráfico, ver `docs/03-red/01-macvlan.md`):

```bash
dig @192.168.1.2 google.com +short
# debe responder con IPs de google
dig @192.168.1.2 doubleclick.net +short
# debe responder con 0.0.0.0  (bloqueado por la lista por defecto)
```

Y desde otro dispositivo de la LAN (móvil, portátil), apuntando manualmente al `192.168.1.2`:

```bash
nslookup google.com 192.168.1.2
nslookup doubleclick.net 192.168.1.2
```

---

## Acceso a la UI durante el _bootstrap_

Sin Caddy todavía, la UI se accede directamente por la IP macvlan, **HTTP plano**:

<http://192.168.1.2/admin/>

Login con la contraseña que se generó en `PIHOLE_WEB_PASSWORD`.

> **Acceptable porque la LAN es de confianza** y el homelab no se expone a internet. La contraseña viaja en claro entre el portátil y `192.168.1.2`, pero ambos están en la misma red doméstica conmutada (no WiFi abierto). Cuando Caddy levante (`docs/03-red/04-caddy.md`), este `:80` queda detrás de HTTPS con _CA_ local y el `:80` macvlan se restringe a 'redirect to HTTPS' por el propio Pi-hole (lighttpd) o se acepta como puerta de servicio en LAN.

> **Si la red doméstica no se considera de confianza** (por ejemplo, en un piso compartido con otros usuarios en la misma WiFi), saltar el acceso por LAN y usar SSH _tunnel_ contra `192.168.1.2:80`:
>
> ```bash
> ssh -N -L 8080:192.168.1.2:80 homelab@pi
> # luego en el navegador del portátil: http://localhost:8080/admin/
> ```

---

## Configurar el router para usar Pi-hole como DNS

Abrir la administración del router (`http://192.168.1.1`) y cambiar la **opción DHCP 6** (DNS server) que reparte a los clientes:

| Servidor DNS              | Antes                                        | Después                              |
|---------------------------|----------------------------------------------|--------------------------------------|
| Primario                  | (vacío, equivale al propio router)           | `192.168.1.2` (Pi-hole)              |
| Secundario                | (vacío)                                      | **vacío** — ver nota abajo           |

> **Por qué se deja el secundario vacío**: si se pone un secundario "real" (el router, `1.1.1.1`…), los clientes lo usarán como _fallback_ silencioso cuando Pi-hole tarde en responder, **saltándose el bloqueo**. La especificación dice que el cliente puede preguntar al primario o al secundario en cualquier orden y, en la práctica, sistemas como Windows o iOS rotan entre ambos para "balancear". Resultado típico: el 30 % de la publicidad pasa porque el secundario no la bloquea.

> **Cómo se gestiona la caída de Pi-hole**: con sólo Pi-hole anunciada como DNS, si el contenedor cae **toda la LAN se queda sin resolver**. Trade-off consciente: preferimos detectar el fallo en 30 segundos (Uptime Kuma alertará en `docs/05-monitorizacion/05-uptime-kuma.md`) a una "degradación silenciosa" que enmascare problemas. La Pi propiamente dicha tiene su propia configuración de _fallback_ (siguiente sección) para no quedarse aislada.

Forzar la renovación del _lease_ DHCP en los clientes para que recojan el cambio. Un atajo es reiniciar la WiFi del móvil/portátil; los _wired_ se renuevan al próximo TTL del DHCP (1-24 h dependiendo del router).

Verificar desde un cliente cualquiera:

```bash
# Linux/macOS
scutil --dns 2>/dev/null || resolvectl status || cat /etc/resolv.conf
# Debe listar 192.168.1.2 como nameserver

# Windows (PowerShell)
Get-DnsClientServerAddress -AddressFamily IPv4
```

Y la UI de Pi-hole (Dashboard) debe empezar a mostrar consultas reales en cuanto los clientes naveguen.

---

## DNS de _fallback_ en el host (la propia Pi)

La Pi se queda sin resolver si Pi-hole cae, igual que el resto de la LAN. Pero a diferencia de los demás dispositivos, **la Pi necesita resolver para arrancar Pi-hole de nuevo** (tiene que hacer `docker pull` si la imagen no está cacheada o si hay un `apt upgrade` pendiente). Dependencia circular que se rompe configurando _explícitamente_ DNS de _fallback_ en NetworkManager.

Editar la conexión Ethernet (`docs/01-sistema/01-instalacion-os.md` la deja con nombre `Wired connection 1` por defecto):

```bash
NM_CONN=$(nmcli -g NAME,DEVICE c show --active | awk -F: '$2=="eth0"{print $1}')
sudo nmcli connection modify "$NM_CONN" \
    ipv4.ignore-auto-dns yes \
    ipv4.dns "192.168.1.2 192.168.1.1 1.1.1.1"
sudo nmcli connection up "$NM_CONN"
```

Detalles:

- **`ipv4.ignore-auto-dns yes`**: NetworkManager deja de aceptar la opción 6 que envía el router. Si no, el router puede empezar a anunciar `192.168.1.2` (lo que queremos) pero NM lo combinaría con su propia caché o con el _fallback_ del DHCP, con resultado impredecible.
- **`ipv4.dns "192.168.1.2 192.168.1.1 1.1.1.1"`**: lista explícita, en orden:
  1. **`192.168.1.2`** (Pi-hole) — uso normal.
  2. **`192.168.1.1`** (router) — _fallback_ si Pi-hole no responde. El router resuelve por el ISP. Sólo lo usa la propia Pi.
  3. **`1.1.1.1`** (Cloudflare) — segundo _fallback_ si el router también está caído (corte de luz parcial, _power cycle_…).

Verificar:

```bash
resolvectl status   # si systemd-resolved está activo en stub-only mode
# o
cat /etc/resolv.conf
# Debe listar 192.168.1.2 como primer nameserver y los otros dos a continuación.

# Probar el fallback parando Pi-hole:
docker compose -f ~/homelab/red/docker-compose.yml stop pihole
dig +time=2 google.com   # tarda ~2s pero responde (el router contesta)
docker compose -f ~/homelab/red/docker-compose.yml start pihole
```

> Esta configuración de _fallback_ **sólo aplica al host**. Los demás dispositivos de la LAN siguen recibiendo `192.168.1.2` como único DNS desde el router (sección anterior). El razonamiento de "no _fallback_ silencioso" sigue valiendo para los clientes finales; para la Pi se relaja porque su rol es _restaurar_ Pi-hole, no _consumirla_.

> **Si la Pi corre `systemd-resolved`** (no es nuestro caso por defecto, pero puede activarse en alguna receta de monitorización), comprobar que `Domain` y `DNS=` en `/etc/systemd/resolved.conf` estén alineados con esta misma lista, y reiniciar `systemd-resolved`.

---

## Listas de bloqueo recomendadas

Pi-hole arranca con la lista por defecto **StevenBlack/hosts** (~150k dominios). Es suficiente para un 80 % de los casos. Para cobertura adicional, añadir desde la UI (Group Management → Adlists):

| Lista                                                                                          | Cobertura adicional                                              | Tipo  | Cuándo añadir |
|------------------------------------------------------------------------------------------------|-----------------------------------------------------------------|-------|---------------|
| `https://big.oisd.nl/`                                                                         | Súper-lista mantenida (incluye StevenBlack, AdGuard, etc.)       | Hosts | Recomendada por defecto si se usa OISD en lugar de StevenBlack |
| `https://raw.githubusercontent.com/hagezi/dns-blocklists/main/hosts/multi.txt`                 | HaGeZi multi (publicidad + tracking + malware + amenazas)        | Hosts | Recomendada — buen ratio bloqueo/falsos positivos             |
| `https://raw.githubusercontent.com/hagezi/dns-blocklists/main/hosts/tif.txt`                   | HaGeZi Threat Intelligence Feeds (sólo malware/phishing)         | Hosts | Recomendada — bajo ruido                                      |
| `https://raw.githubusercontent.com/hagezi/dns-blocklists/main/hosts/native.amazon.txt`         | Amazon telemetry (Echo, Fire TV…)                                | Hosts | Sólo si hay dispositivos Amazon en casa                       |
| `https://raw.githubusercontent.com/hagezi/dns-blocklists/main/hosts/native.apple.txt`          | Apple telemetry (iOS/macOS)                                      | Hosts | Cuidado: rompe iCloud, AirDrop, Find My                       |
| `https://raw.githubusercontent.com/hagezi/dns-blocklists/main/hosts/native.microsoft.txt`      | Microsoft telemetry (Windows 10/11, Office)                      | Hosts | Sólo si hay Windows en casa                                   |

Después de añadir, **forzar la actualización**:

```bash
docker exec pihole pihole -g
```

> **Apilar listas tiene rendimientos decrecientes**. Cuatro listas bien curadas suelen bloquear más (con menos falsos positivos) que veinte listas redundantes. La UI de Pi-hole muestra "Total queries blocked" por dominio: si una lista no aporta dominios únicos, se quita.

> **Falsos positivos**: cuando un servicio legítimo deja de funcionar (típico: tienda online que carga el _checkout_ desde un CDN trackeado), añadir el dominio a **Group Management → Allow** (no a Whitelist directamente — es lo mismo en v5 pero la UI cambió de nombre). El _allow_ tiene precedencia sobre cualquier lista.

---

## Verificación final

Antes de pasar a `docs/03-red/03-unbound.md`, comprobar:

- [ ] `docker compose -f ~/homelab/red/docker-compose.yml ps` muestra `pihole` en estado `Up` y `(healthy)` tras ~60 s.
- [ ] `dig @192.168.1.2 google.com +short` responde con IPs reales en menos de 200 ms.
- [ ] `dig @192.168.1.2 doubleclick.net +short` responde con `0.0.0.0` (bloqueado).
- [ ] `dig @192.168.1.2 pi.hole +short` responde con `192.168.1.2` (FTLCONF_LOCAL_IPV4 aplicó).
- [ ] `dig @192.168.1.2 jellyfin.lan +short` responde con `192.168.1.3` (wildcard `*.lan` del `02-homelab-local.conf`).
- [ ] `dig @192.168.1.2 nonexistent.lan +short` responde con `192.168.1.3` (mismo wildcard).
- [ ] Otro dispositivo de la LAN, **tras renovar DHCP**, usa `192.168.1.2` como DNS y bloquea publicidad.
- [ ] Desde la propia Pi, `cat /etc/resolv.conf` lista `192.168.1.2` como primer nameserver y `192.168.1.1`/`1.1.1.1` como secundarios.
- [ ] `docker compose -f ~/homelab/red/docker-compose.yml stop pihole && dig +time=2 +tries=1 google.com && docker compose -f ~/homelab/red/docker-compose.yml start pihole` confirma que el _fallback_ del host funciona (resuelve por el router).
- [ ] La UI en <http://192.168.1.2/admin/> carga y permite login con la contraseña configurada.
- [ ] **Dashboard** de la UI muestra consultas reales pasados unos minutos (clientes ya configurados con DNS = `192.168.1.2`).
- [ ] **Settings → DNS** lista `1.1.1.1`, `1.0.0.1` como _Custom upstream_; **DNSSEC** activado.
- [ ] El contenedor sobrevive un `sudo reboot` de la Pi: `restart: unless-stopped` lo levanta tras el _macvlan-shim_ y la red `lan`.
- [ ] `git -C ~/homelab status` muestra como **nuevos**: `red/docker-compose.yml`, `red/.env.example`, `red/etc-dnsmasq.d/02-homelab-local.conf`. **No** muestra `red/.env`. _Commit_:

  ```bash
  cd ~/homelab
  git add red/docker-compose.yml red/.env.example red/etc-dnsmasq.d/02-homelab-local.conf
  git commit -m "feat(red): add Pi-hole on macvlan + homelab bridge"
  ```

---

## Backup

- **`/etc/pihole/`** (volumen `etc-pihole`):
  - `gravity.db` (~80-200 MB): listas de bloqueo compiladas. **Regenerable** desde los _adlists_ con `pihole -g`. Se respalda **igualmente**: una restauración rápida (5 min con `borg extract`) es preferible a esperar `pihole -g` (puede tardar 5-15 min en Pi 5 con listas grandes).
  - `setupVars.conf`: configuración (upstreams, DNSSEC, password hash, IP). **Imprescindible**.
  - `pihole-FTL.db`: histórico de consultas (~50 MB/semana). **Optativo**: las métricas se respaldan en Prometheus si interesan; este fichero engorda los backups y, si se descarta, Pi-hole sigue funcionando.
  - `dhcp.leases`, `gravity_old.db`: descartables.

- **`/etc/dnsmasq.d/`** (volumen `etc-dnsmasq.d`):
  - `01-pihole.conf`: regenerado por Pi-hole en cada `pihole -r`. **Descartable**.
  - `04-pihole-static.conf`, `05-pihole-custom-cname.conf`: records y CNAMEs creados desde la UI. **Imprescindibles** (no son regenerables sin acceso a la UI).
  - `02-homelab-local.conf` (montado read-only): vive en git, no entra en el backup de Borg.

Configuración para Borgmatic (se documenta plenamente en `docs/07-backups/02-borgmatic.md`, aquí queda como _heads-up_):

```yaml
# en source_directories:
- /mnt/hd2t/services/pihole/etc-pihole
- /mnt/hd2t/services/pihole/etc-dnsmasq.d

# en exclude_patterns:
- /mnt/hd2t/services/pihole/etc-pihole/pihole-FTL.db
- /mnt/hd2t/services/pihole/etc-pihole/gravity_old.db
- /mnt/hd2t/services/pihole/etc-pihole/dhcp.leases

# Pre-hook recomendado: detener FTL para que gravity.db no esté en
# escritura (es SQLite — un backup en caliente puede corromperse):
before_actions:
  - docker exec pihole sh -c "pihole-FTL --stop || true"
after_actions:
  - docker exec pihole sh -c "pihole-FTL --start"
```

Restauración:

```bash
docker compose -f ~/homelab/red/docker-compose.yml down pihole
borg extract --strip-components 4 /mnt/hd2t/backups/borg::archive_id \
    mnt/hd2t/services/pihole
docker compose -f ~/homelab/red/docker-compose.yml up -d pihole
```

---

## Troubleshooting

### `docker compose up` falla con `network lan declared as external, but could not be found`

`docs/03-red/01-macvlan.md` no se completó o la red `lan` se borró. Recrearla con el comando del paso 2 de aquel doc — **no** dejar que Compose la cree implícitamente, el _driver_ `macvlan` requiere parámetros que Compose no infiere.

### El contenedor arranca pero `dig @192.168.1.2 google.com` da _timeout_

Posibles causas:

1. **Reserva DHCP sin aplicar**: el router asignó la IP a otro dispositivo. Verificar:

   ```bash
   arping -c 2 -I eth0 192.168.1.2
   docker inspect pihole --format '{{(index .NetworkSettings.Networks "lan").IPAddress}}'
   ```

   Ambos deben coincidir y la primera tiene que responder con la MAC `02:42:c0:a8:01:02`.

2. **`DNSMASQ_LISTENING` ausente o distinto de `all`**: dnsmasq filtra y sólo responde a `127.0.0.1`. Probar:

   ```bash
   docker exec pihole grep -i listen /etc/pihole/setupVars.conf
   # debe contener DNSMASQ_LISTENING=all
   ```

   Si no, editar `setupVars.conf`, o reiniciar el contenedor con la env var bien.

3. **`nftables` del host bloqueando**: no debería (la regla `ct state established,related accept` cubre las respuestas), pero si `dig` desde la propia Pi falla y desde otro dispositivo de la LAN funciona, mirar:

   ```bash
   sudo nft list ruleset | grep -A2 'iifname "macvlan-shim"'
   ```

   Si hay una regla `drop` específica añadida después de `docs/03-red/01-macvlan.md`, retirarla.

### Desde otros dispositivos no resuelve, pero desde la Pi sí

Lo opuesto al caso anterior: el _shim_ permite la consulta desde la Pi pero los clientes externos no llegan al `192.168.1.2`. Habitualmente:

1. **El router no anuncia el cambio de DNS**: revisar la sección de DHCP de la UI del router. Algunos routers requieren reiniciar el servicio DHCP para que la opción 6 nueva se reparta.
2. **El cliente cachea**: forzar `ipconfig /flushdns` (Windows), `sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder` (macOS), `sudo resolvectl flush-caches` (Linux).
3. **El cliente tiene DNS hardcodeado**: smart TVs, _set-top boxes_ y algunos dispositivos IoT ignoran el DHCP y usan `8.8.8.8` directamente. Solución corta: bloquear UDP/53 saliente en el router salvo desde `192.168.1.2`. Solución larga: documentar como _quirk_.

### La UI carga pero el dashboard está vacío y `pihole status` dice "DNS service not running"

`pihole-FTL` no arrancó. Mirar los _logs_:

```bash
docker logs pihole --tail 50 | grep -iE 'FTL|error|fatal'
```

Causas habituales:

- `gravity.db` corrupto (típico tras un corte eléctrico durante un `pihole -g`). Regenerar:

  ```bash
  docker exec pihole rm /etc/pihole/gravity.db
  docker exec pihole pihole -g
  ```

- Permisos del volumen rotos (un `chown -R` por error a `homelab:homelab`). Revertir:

  ```bash
  docker exec pihole chown -R pihole:pihole /etc/pihole /etc/dnsmasq.d
  ```

### `pihole -g` falla con "Unable to download list"

Pi-hole resuelve los _adlists_ por DNS. Si el _upstream_ está mal o no hay conectividad saliente, falla en cadena. Como _bootstrap_ se incluyó `dns: [127.0.0.1, 1.1.1.1]` en el compose: si pi-hole-FTL aún no levantó, usa `1.1.1.1`. Si tampoco así funciona, la Pi no tiene conectividad saliente — revisar `nft list ruleset` y la cadena `output`.

### Tras reiniciar la Pi, Pi-hole arranca antes que el _shim_ y el host no resuelve durante 30 s

Comportamiento conocido: `restart: unless-stopped` arranca el contenedor en cuanto Docker está listo, pero el _shim_ depende de `network-online.target` y NetworkManager. Si esto se vuelve molesto (Prometheus alertando con falsos positivos), añadir al `pihole.service` (creado por Docker) un `After=macvlan-shim.service`. Es _hack_, no se ha hecho de serie porque el _gap_ es pequeño.

### Pi-hole pierde su contraseña y la UI exige crear una nueva

Pasa cuando se borra `/mnt/hd2t/services/pihole/etc-pihole/setupVars.conf` (típico: restauración manual mal hecha). Reaplicar:

```bash
docker exec pihole pihole -a -p 'NUEVA_CONTRASEÑA'
```

> **Nunca** poner el `WEBPASSWORD` en el compose para "forzarla en cada arranque": Pi-hole lo aplica sólo en el primer _bootstrap_ del volumen. La práctica correcta es rotar con `pihole -a -p`.

### `Resolution time` en el dashboard es alto (>50 ms)

Las consultas tardan más de lo esperado. Causas:

- **Pi bajo carga**: `top` muestra >70 % CPU sostenida. Bajar la prioridad de servicios CPU-hambrientos (Stash, transcodificación de Jellyfin) o subir la de Pi-hole con `cpus`/`cpu_shares` en el compose.
- **Listas demasiado grandes**: `gravity.db` >300 MB. Revisar **Group Management → Adlists** y purgar redundantes. La métrica `Domains on Adlists` en el dashboard es una buena señal: si supera 1.5 M es probable redundancia.
- **`DNSSEC` con _upstream_ que no lo soporta bien**: suele afectar a DNS de ISP. Cloudflare lo hace bien.

### Cómo probar el bloqueo manualmente

Lista de dominios "trampa" para validar que las listas están activas:

```bash
for d in doubleclick.net googletagmanager.com facebook.com/ads adservice.google.com googlesyndication.com; do
    printf '%-30s ' "$d"
    dig @192.168.1.2 +short "$d" | head -1
done
```

Todos deben responder `0.0.0.0` o `NXDOMAIN`. Si alguno devuelve una IP real, esa lista no lo cubre (raro: estos cinco son canónicos).

### Migración futura a Pi-hole v6

La rama 2025.x de la imagen oficial (Pi-hole v6) introduce un único _config_ TOML y renombra prácticamente todas las variables de entorno. Cuando llegue el momento de migrar, los pasos serán:

1. _Backup_ explícito de `/mnt/hd2t/services/pihole/etc-pihole/setupVars.conf` (Pi-hole v6 lo migra automáticamente la primera vez, pero conviene poder revertir).
2. Actualizar `PIHOLE_IMAGE_TAG` al _tag_ de v6 elegido.
3. Renombrar variables en `red/.env` y `red/.env.example`:
   - `WEBPASSWORD` → `FTLCONF_webserver_api_password`
   - `PIHOLE_DNS_` → `FTLCONF_dns_upstreams`
   - `DNSMASQ_LISTENING` → `FTLCONF_dns_listeningMode`
   - `FTLCONF_LOCAL_IPV4` → `FTLCONF_dns_replyAddr_v4` (revisar nombre exacto en _release notes_).
4. La estructura de `etc-dnsmasq.d/` cambia a `etc-pihole/dnsmasq.d/` en v6; revisar el bind del compose.
5. Probar contra un Pi-hole de _staging_ antes de tocar el de producción.

Hasta que ese cambio esté hecho y validado, **mantener el _tag_ pinneado a `2024.07.0`** y dejar `com.centurylinklabs.watchtower.enable: "false"` (que ya está).

---

## Referencias

- Pi-hole — Documentación oficial: <https://docs.pi-hole.net/>
- Pi-hole — Imagen Docker oficial: <https://hub.docker.com/r/pihole/pihole>
- Pi-hole — Variables de entorno (v5): <https://github.com/pi-hole/docker-pi-hole/blob/master/README.md>
- Pi-hole — `pihole -a` (administración por CLI): <https://docs.pi-hole.net/main/pihole-command/>
- Pi-hole — Custom DNS y CNAMEs locales: <https://docs.pi-hole.net/guides/dns/dnsmasq/>
- Docker — Compose `mac_address`, `networks.<name>.ipv4_address`: <https://docs.docker.com/reference/compose-file/services/#mac_address>
- Docker — Multi-network containers (macvlan + bridge): <https://docs.docker.com/network/#network-drivers>
- HaGeZi DNS Blocklists: <https://github.com/hagezi/dns-blocklists>
- OISD: <https://oisd.nl/>
- StevenBlack/hosts: <https://github.com/StevenBlack/hosts>
- NetworkManager — `ipv4.dns`, `ipv4.ignore-auto-dns`: <https://networkmanager.dev/docs/api/latest/nm-settings-nmcli.html>
