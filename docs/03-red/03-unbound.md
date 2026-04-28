# Unbound

## Descripción

Cerrado `02-pihole.md`, toda la LAN resuelve contra Pi-hole en `192.168.1.2:53` con bloqueo de publicidad y telemetría activo. Pi-hole, sin embargo, sigue **delegando las consultas no resueltas localmente** a `1.1.1.1;9.9.9.9`: dos resolvers públicos. Eso significa que Cloudflare y Quad9 ven, en agregado, **todo el tráfico DNS del hogar** (qué dominios visita cada dispositivo, con qué frecuencia, a qué horas). Para un homelab cuyo principio es "lo que se puede resolver dentro de casa, se resuelve dentro de casa", esa fuga es la siguiente pieza a cerrar.

Este documento despliega **Unbound** como **resolver recursivo** local, con IP propia (`192.168.1.3`) sobre la red `dns_lan` ya creada en `01-macvlan.md`. Unbound hace **un** trabajo en este homelab:

- **Resolver desde los root servers, paso a paso**, sin delegar en ningún resolver externo. Cuando Pi-hole le pregunta `jellyfin.org`, Unbound consulta primero los root (`a.root-servers.net` … `m.root-servers.net`) que conoce por sus *root hints* embebidos, sigue la cadena hacia los TLD (`.org`), de ahí al servidor autoritativo de `jellyfin.org`, y devuelve la respuesta validada con DNSSEC. La caché local sirve las repeticiones.

Lo que este documento **no** decide:

- **El bloqueo de listas**, las estadísticas y la UI: siguen siendo trabajo de Pi-hole. Unbound es **sólo** el upstream recursivo de Pi-hole. No tiene UI, no se publica en la LAN, no atiende a los clientes finales: solo a Pi-hole. La regla mental es *Pi-hole es lo que ven los dispositivos; Unbound es lo que ve Pi-hole*.
- **DNS-over-HTTPS / DNS-over-TLS hacia los root servers o servidores autoritativos**: con Unbound recursivo el contenido de cada consulta se reparte entre múltiples autoritativos distintos por dominio, y el ruido es estructuralmente menor que con un resolver único. Activar DoT autoritativo (`tls-upstream`) anularía la ganancia de privacidad al volver a centralizar en *forwarders*. Reabrible si en algún momento se decide pasar a *forwarding* (ver "Decisiones que no se toman aquí").
- **Cualquier cosa que no sea DNS recursivo**: Unbound puede actuar de *authoritative-lite*, soporta `local-zone` para sobreescribir respuestas, etc. Eso no se usa: el espacio de nombres `*.lan` ya lo gestiona Pi-hole vía `dnsmasq.d/02-homelab-local.conf` (decisión cerrada en `02-pihole.md`). Se mantiene **una** fuente para el DNS local.

Cuando este documento se haya aplicado, `docker ps` lista un contenedor `unbound` saludable con IP propia en la LAN, Pi-hole apunta a `192.168.1.3#53` como **único** upstream, las consultas DNS del hogar se resuelven sin tocar resolvers públicos, y la transición desde `1.1.1.1;9.9.9.9` se ha hecho cambiando **una sola variable** y reiniciando Pi-hole, sin reconfigurar ningún cliente.

> **Recordatorio de alcance**: Unbound vive **solo** en la red `dns_lan`. No se publica en `homelab` (Caddy no lo proxy-a), no se expone a Tailscale, y **no** debe ser alcanzable desde otros dispositivos de la LAN: si por error un móvil empezase a usar `192.168.1.3` como DNS, perdería el bloqueo de Pi-hole. La única ruta legítima a Unbound es Pi-hole → `192.168.1.3:53`, y la última sección documenta cómo verificar que esa propiedad se cumple.

---

## Requisitos Previos

- `docs/03-red/01-macvlan.md` aplicado:
  - Red Docker `dns_lan` activa (`docker network inspect dns_lan` reporta `driver=macvlan`, `parent=eth0`, `--subnet 192.168.1.0/24`, `--ip-range 192.168.1.0/29`, `--aux-address host=192.168.1.9`).
  - Unidad `macvlan-shim.service` activa y habilitada; `ip route show 192.168.1.3` apunta a `dev macvlan-shim` (la ruta `/32` ya la añade `scripts/21-macvlan-shim.sh` para `${UNBOUND_IP}`, no hace falta tocarla).
  - `.env` global incluye `UNBOUND_IP=192.168.1.3`.
- `docs/03-red/02-pihole.md` aplicado:
  - Pi-hole desplegado y resolviendo (`dig @192.168.1.2 example.com +short` desde otro host devuelve una IP).
  - `${PIHOLE_DNS_}` en `stacks/pihole/.env` o en el compose actualmente vale `1.1.1.1;9.9.9.9` (upstream provisional). Es la variable que este documento sustituye.
- Árbol de datos en `hd2t` (Fase 1, `04-estructura-directorios.md`):
  - `/mnt/hd2t/apps/unbound/etc/` y `/mnt/hd2t/apps/unbound/etc/unbound.conf.d/` existirán (los crea este documento).
- Nada está escuchando ya en `192.168.1.3:53` (es la IP virgen reservada en `01-macvlan.md`).
- Comprobación rápida antes de empezar:

  ```bash
  cd /home/homelab/homelab

  # IP libre, ningún dispositivo respondiendo
  ping -c 2 -W 1 192.168.1.3 || true
  # 100% packet loss (correcto)

  # Ruta /32 a través de la shim (el script 21 ya la creó)
  ip route show 192.168.1.3
  # 192.168.1.3 dev macvlan-shim scope link

  # Variables presentes
  grep -E '^(UNBOUND_IP|PIHOLE_IP|TZ)=' .env

  # Pi-hole sigue saludable y resolviendo
  docker ps --filter name=pihole --format '{{.Status}}'
  # Up X minutes (healthy)
  dig @192.168.1.2 example.com +short
  # (una IP)
  ```

  Si `192.168.1.3` ya **responde**, otro dispositivo está ocupando la IP: identificarlo (tabla DHCP del router, `arp -a`, `ip neigh`) y reasignarlo. Si la ruta `/32` no aparece, falta repasar `01-macvlan.md` (sección "La trampa de macvlan"): `scripts/21-macvlan-shim.sh` debe haber metido `${UNBOUND_IP}` en su bucle.

---

## Decisión: imagen y versión

Hay tres opciones razonables en Docker Hub para Unbound multi-arch (Pi 5 = `arm64`):

| Imagen | Quién la mantiene | Pros | Contras | Veredicto |
|---|---|---|---|---|
| **`mvance/unbound`** | Matthew Vance, mantenida activamente, tags por versión upstream (`1.20.0`, `1.21.0`…) | Multi-arch (`amd64`, `arm64`, `arm/v7`). Configuración `unbound.conf` estándar bind-mountable. Documentación clara. Es la imagen que usa la mayor parte de la comunidad Pi-hole + Unbound. | Una persona, no fundación. Si la abandona, hay que migrar (es trivial: el `unbound.conf` es portable). | **Aceptado**. |
| `klutchell/unbound` | Otro mantenedor independiente | Similar a la anterior, también multi-arch. | Menor adopción, menos ejemplos de referencia. | Descartado por inercia. |
| Construir imagen propia desde la oficial de NLnet Labs (`unbound`) | Fuente original | Control total. | Mantener una build pipeline para una imagen trivial es ruido para un homelab. | Descartado por sobre-ingeniería. |

| Tag de `mvance/unbound` | Cuándo usar | Decisión aquí |
|---|---|---|
| `latest` | Pruebas. Cambia sin avisar. | Descartado por la convención de Fase 2: tag fijado. |
| `1.20.0` (ejemplo) | Estable, fijado a versión upstream. | **Aceptado**. El tag exacto se anota abajo y se actualiza vía Watchtower (Fase 2.4) o por commit explícito. |

> **Tag exacto en uso**: `mvance/unbound:1.20.0`. Si en el momento de aplicar este documento existe una versión más reciente *estable*, se actualiza el tag aquí y en el `docker-compose.yml`, y se anota en el commit. **Nunca `latest`**.

---

## Decisión: cómo se expone Unbound

Unbound publica **un solo** servicio: DNS recursivo en `53/tcp` y `53/udp`. La discusión es **a quién** se lo expone.

| Opción | Cómo se ve | Discusión |
|---|---|---|
| **Bridge `homelab` + `ports: ["53:53/udp", "53:53/tcp"]`** | Unbound expuesto en la IP de la Pi (`192.168.1.10`). | Choca con todo lo discutido en `01-macvlan.md`: `:53` ya está implícitamente "ocupado" en la concepción del homelab por Pi-hole. Y aun si no chocase, expondría Unbound a toda la LAN, lo que rompe la regla "los clientes hablan con Pi-hole, nunca con Unbound". |
| **Macvlan `dns_lan` con IP propia (`192.168.1.3`)** | Unbound escucha en `192.168.1.3:53`. Pi-hole lo alcanza por la red `dns_lan`. La Pi (host) y otros equipos de la LAN **también** pueden alcanzarlo si tienen ruta — eso se mitiga abajo. | Es la decisión coherente con `01-macvlan.md` y con la simetría que `02-pihole.md` ya pintó. **Aceptado.** |
| **Bridge `homelab` *interno* (`internal: true`) compartido solo con Pi-hole** | Unbound aislado en una sub-red Docker que solo conecta a Pi-hole. | Funcionalmente equivalente a la macvlan. Pero requeriría una **tercera** red Docker (`unbound_internal`) y duplicaría la documentación. La macvlan ya provee aislamiento suficiente: la regla *del lado del cliente* "yo apunto a Pi-hole, no a Unbound" es la que cuenta. | Descartado por simplicidad. |

Resultado: **Unbound en `dns_lan` con IP `192.168.1.3`**, **solo** en esa red (a diferencia de Pi-hole, que vive en dos: `dns_lan` + `homelab`). Unbound no necesita ser proxy-ado por Caddy ni alcanzable por otros stacks: solo Pi-hole lo consulta, y Pi-hole está en `dns_lan` también.

```text
                   LAN 192.168.1.0/24 (macvlan, eth0)
   +------------+
   |  Móvil     |
   |  TV        |  -->  192.168.1.2:53  (Pi-hole, ÚNICO DNS visible para clientes)
   |  Portátil  |               |
   +------------+               |
                                v
                    Pi-hole (dns_lan + homelab)
                                |
                                |  upstream DNS (dentro de dns_lan)
                                v
                    Unbound  192.168.1.3:53  (dns_lan)
                                |
                                v  (53/udp, 53/tcp hacia internet)
                    a.root-servers.net … (root) → TLD → autoritativos
```

Notas:

- **Acceso desde otros clientes de la LAN**: aunque Unbound esté en la misma `dns_lan`, **un dispositivo de la LAN puede técnicamente preguntarle directamente a `192.168.1.3`** (porque está en `192.168.1.0/24` por capa 2). Eso es indeseable: saltaría el bloqueo de Pi-hole. Las dos defensas son:
  1. **Configuración**: ningún dispositivo del hogar tiene `192.168.1.3` como DNS. El router reparte solo `192.168.1.2`, ya cerrado en `02-pihole.md`. La regla operativa es *no escribir nunca `.3` como DNS en ningún cliente*.
  2. **Software**: Unbound se configura con `access-control: 192.168.1.0/24 deny` por defecto y `access-control: 192.168.1.2/32 allow` específico para Pi-hole. Cualquier consulta directa de un móvil de la LAN cae con `REFUSED`. Es la línea final de defensa y se aplica en `unbound.conf` abajo.
- **MAC fija** (`mac_address:` en Compose). Mismo razonamiento que en Pi-hole: trazabilidad. `02:42:c0:a8:01:03` codifica `192.168.1.3`, manteniendo el patrón mnemotécnico.
- **No `ports:`**. Unbound escucha directamente en su IP macvlan, sin NAT. Siguiendo el mismo patrón que Pi-hole.

---

## Decisión: DNSSEC, privacidad y endurecimiento

Unbound trae por defecto opciones razonables, pero algunas decisiones merecen activarse explícitamente:

| Opción de `unbound.conf` | Decisión aquí | Por qué |
|---|---|---|
| `do-ip4: yes` / `do-ip6: no` | IPv4 sí, IPv6 no | El homelab opera solo en IPv4 (decisión de `01-macvlan.md`). Forzar IPv6 a `no` evita que Unbound intente hablar con root servers IPv6 cuando no hay ruta IPv6 en la red, lo que añadiría timeouts. |
| `do-tcp: yes` / `do-udp: yes` | Ambos | DNS estándar usa UDP; TCP se usa cuando una respuesta excede 512 B (DNSSEC casi siempre). Sin TCP, las consultas grandes fallan. |
| `prefetch: yes`, `prefetch-key: yes` | Activado | Unbound refresca proactivamente las entradas con TTL próximo a expirar. Reduce latencia notable para los dominios visitados a menudo. |
| `qname-minimisation: yes` (RFC 7816), `qname-minimisation-strict: no` | Activado relajado | Solo se envía a cada autoritativo la *mínima* parte del FQDN necesaria para encontrar al siguiente paso (por ejemplo, los servidores de `.com` solo ven que se está buscando algo en `example.com`, **no** `subdominio.example.com`). El modo *strict* aborta la consulta si el autoritativo no coopera; relajado degrada al comportamiento clásico. |
| `harden-glue: yes`, `harden-dnssec-stripped: yes`, `harden-below-nxdomain: yes`, `harden-referral-path: yes` | Activado | Defensas estándar contra envenenamiento de caché y respuestas mal formadas. |
| `aggressive-nsec: yes` | Activado | Permite generar `NXDOMAIN` desde la caché para subdominios que comparten *NSEC* probado, ahorrando consultas. |
| `use-caps-for-id: no` | Desactivado | El "0x20" (variar mayúsculas/minúsculas en la pregunta para detectar spoofers) rompe con algunos autoritativos. Se prefiere DNSSEC, que da una garantía más fuerte. |
| `cache-min-ttl: 300`, `cache-max-ttl: 86400`, `cache-max-negative-ttl: 3600` | Activado | TTLs sensatos para un homelab: caché útil sin servir registros estancados. |
| `serve-expired: yes`, `serve-expired-ttl: 3600` | Activado | Si un autoritativo está caído, Unbound sirve la última respuesta conocida hasta una hora más, intentando refrescarla en background. Mantiene Netflix funcionando si Cloudflare-DNS-autoritativo tiene un mal cuarto de hora. |
| `auto-trust-anchor-file` apuntando a `/etc/unbound/var/root.key` | Activado | Trust anchor de DNSSEC. La imagen `mvance/unbound` lo bootstrappea (`unbound-anchor`) en el primer arranque y lo persiste en el bind mount. |
| `root-hints: /etc/unbound/var/root.hints` | Activado | Lista de IPs de los root servers. Se versiona como plantilla y se actualiza ocasionalmente (cambian raramente; un fichero IANA `named.root` cada año o dos). |
| `hide-identity: yes`, `hide-version: yes` | Activado | No revelar a quien escanee `chaos.txt` que esto es Unbound y qué versión. |
| `access-control: 0.0.0.0/0 refuse` (defecto) + `access-control: 127.0.0.0/8 allow` + `access-control: 192.168.1.2/32 allow` + `access-control: 192.168.1.9/32 allow` | Activado | Por defecto rechaza todo. Permite explícitamente Pi-hole (`.2`) y la macvlan-shim del host (`.9`, para diagnóstico). El resto de la LAN recibe `REFUSED`. |
| `private-address: 192.168.0.0/16` (y demás RFC1918) | Activado | Rechaza respuestas que devuelvan IPs privadas para dominios públicos (defensa contra *DNS rebinding*). Como contrapartida, **excluye explícitamente** `192.168.1.0/24` con `private-domain` si en algún momento se delegan zonas internas a Unbound — no es el caso aquí, así que se deja la línea por defecto. |
| `num-threads: 2`, `msg-cache-slabs: 4`, `rrset-cache-slabs: 4`, `infra-cache-slabs: 4`, `key-cache-slabs: 4` | Activado | La Pi 5 tiene 4 cores ARM Cortex-A76. 2 threads es conservador (deja CPU para Pi-hole, Caddy, Jellyfin) y suficiente para una LAN de hogar. |
| `rrset-cache-size: 64m`, `msg-cache-size: 32m` | Activado | Caché razonable. Con 8 GB de RAM la Pi puede asumirla sin problema. |
| `chroot: ""` | Vacío | Dentro del contenedor el chroot añade complicación sin valor (el contenedor **es** el aislamiento). |
| `username: "_unbound"` | El que traiga la imagen | `mvance/unbound` ya corre como `_unbound` no-root tras bootstrap. No se sobreescribe. |
| `verbosity: 1` | Activado | Suficiente para diagnóstico. `0` es silencio; `2+` se pone temporalmente al depurar. |

Estos valores se materializan en `stacks/unbound/etc/unbound.conf.d/00-homelab.conf` más abajo, dentro de "Stack: `stacks/unbound/`".

> **Por qué *recursivo* y no *forwarder a `1.1.1.1` con DoT***. Forwardear a Cloudflare con `tls-upstream` esconde el contenido de la consulta del operador del enlace, pero **no** del propio Cloudflare. La privacidad ganada es marginal frente a un resolver recursivo: con Unbound ningún proveedor único ve el agregado del hogar. La latencia del primer hit es mayor (varias consultas en cadena root → TLD → autoritativo), pero la caché y `prefetch` la difuminan. El homelab elige privacidad sobre latencia.

---

## Decisión: trust anchor de DNSSEC y root hints

Unbound necesita dos ficheros generados/actualizables al margen del `unbound.conf`:

1. **Root hints** (`root.hints`): IPs de los 13 servidores raíz. Cambian poco; se descargan de IANA. Si están desactualizados, Unbound aún arranca (las hints solo bootstrapean; las IPs reales se reverifican vía DNSSEC). Aun así se mantienen actualizados para minimizar el primer timeout.
2. **Trust anchor** (`root.key`): clave pública DNSSEC del root. La imagen `mvance/unbound` ejecuta `unbound-anchor` en el primer arranque, lo escribe en `/opt/unbound/etc/unbound/root.key` (que es un bind mount), y a partir de ahí Unbound lo mantiene actualizado mediante RFC 5011 (rollover automático).

Decisión: **descargar `root.hints` desde IANA en el primer arranque** mediante un script versionado, y **dejar que `unbound-anchor` cree el `root.key`** automáticamente. Ambos ficheros van al bind mount, persisten entre reinicios, y se respaldan con Borg.

```bash
sudo install -d -o homelab -g homelab -m 0750 /mnt/hd2t/apps/unbound/etc
sudo install -d -o homelab -g homelab -m 0750 /mnt/hd2t/apps/unbound/etc/unbound.conf.d

# Descargar root.hints (~3 KB) directamente desde IANA.
sudo curl -fsSL https://www.internic.net/domain/named.root \
    -o /mnt/hd2t/apps/unbound/etc/root.hints
sudo chown homelab:homelab /mnt/hd2t/apps/unbound/etc/root.hints
sudo chmod 0644 /mnt/hd2t/apps/unbound/etc/root.hints

head -3 /mnt/hd2t/apps/unbound/etc/root.hints
# ;       This file holds the information on root name servers needed to
# ;       initialize cache of Internet domain name servers
# ;       (e.g. reference this file in the "cache.dns" configuration file
```

Hooks de actualización ocasional (sin urgencia, sin cron dedicado: una vez al año basta — los root sirven para décadas):

```bash
# Manual cuando se quiera refrescar
sudo curl -fsSL https://www.internic.net/domain/named.root \
    -o /mnt/hd2t/apps/unbound/etc/root.hints
docker compose -f /home/homelab/homelab/stacks/unbound/docker-compose.yml restart
```

---

## Stack: `stacks/unbound/`

### `stacks/unbound/docker-compose.yml`

```yaml
# Unbound — resolver recursivo upstream de Pi-hole.
# Convenciones: ver docs/02-docker/02-estructura-compose.md y docs/03-red/01-macvlan.md.

name: unbound

services:
  unbound:
    image: mvance/unbound:1.20.0
    container_name: unbound
    hostname: unbound
    restart: unless-stopped

    environment:
      TZ: ${TZ}

    networks:
      dns_lan:
        ipv4_address: ${UNBOUND_IP}    # 192.168.1.3

    # MAC estable: trazabilidad y simetría con Pi-hole.
    mac_address: 02:42:c0:a8:01:03

    # No se declaran ports: macvlan publica directamente en LAN.
    # Unbound escucha 53/udp y 53/tcp en 192.168.1.3.
    # access-control en unbound.conf restringe quién puede preguntarle.

    volumes:
      # Configuración drop-in (incluida vía include en unbound.conf base).
      - /mnt/hd2t/apps/unbound/etc/unbound.conf.d:/opt/unbound/etc/unbound/unbound.conf.d
      # root.hints (IANA) y root.key (auto, vía unbound-anchor en primer arranque).
      - /mnt/hd2t/apps/unbound/etc/root.hints:/opt/unbound/etc/unbound/root.hints:ro
      - /mnt/hd2t/apps/unbound/etc/root.key:/opt/unbound/etc/unbound/root.key

    healthcheck:
      # Pregunta canónica: "¿qué es ., NS, IN?" (los root). Si Unbound puede
      # responder esto, está vivo y conectado a su caché.
      test: ["CMD-SHELL", "drill @127.0.0.1 -p 53 . NS >/dev/null || nslookup -type=ns . 127.0.0.1 >/dev/null"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 60s

    labels:
      homelab.role: "dns-recursive"
      homelab.backup: "true"
      # Watchtower opt-in: Unbound se actualiza automáticamente.
      com.centurylinklabs.watchtower.enable: "true"

networks:
  dns_lan:
    external: true
```

> **Por qué solo `dns_lan` y no `homelab`**: Unbound solo es alcanzable por Pi-hole, que vive también en `dns_lan`. Añadir `homelab` aumentaría la superficie expuesta sin beneficio (otros stacks no deben hablar con Unbound directamente; si lo necesitan, hablan con Pi-hole).

### `stacks/unbound/.env.example`

Unbound no tiene secretos que rotar (no hay UI, no hay password). El stack consume **solo** variables del `.env` global (`TZ`, `UNBOUND_IP`). Aun así, se versiona un `.env.example` vacío para coherencia con el resto de stacks y para futuros añadidos:

```bash
# stacks/unbound/.env.example
# Unbound no tiene variables propias en esta versión.
# Las generales (TZ, UNBOUND_IP) viven en el .env GLOBAL del homelab y este
# compose las consume desde ahí. Este fichero existe por convención y para
# permitir extensiones futuras (por ejemplo, control-port con TLS interno).
```

### `stacks/unbound/etc/unbound.conf.d/00-homelab.conf` (versionado)

Este es el cerebro de la configuración. Va versionado en git como `stacks/unbound/etc/unbound.conf.d/00-homelab.conf.example` y se materializa en el bind mount `/mnt/hd2t/apps/unbound/etc/unbound.conf.d/00-homelab.conf`:

```conf
# /mnt/hd2t/apps/unbound/etc/unbound.conf.d/00-homelab.conf
# Configuración del homelab para Unbound recursivo. Ver docs/03-red/03-unbound.md.

server:
    # Identidad y verbosidad
    verbosity: 1
    hide-identity: yes
    hide-version: yes
    use-syslog: no
    log-queries: no
    log-replies: no

    # Interfaces y puertos
    interface: 0.0.0.0
    port: 53
    do-ip4: yes
    do-ip6: no
    do-udp: yes
    do-tcp: yes
    edns-buffer-size: 1472

    # Threading y caches
    num-threads: 2
    msg-cache-slabs: 4
    rrset-cache-slabs: 4
    infra-cache-slabs: 4
    key-cache-slabs: 4
    rrset-cache-size: 64m
    msg-cache-size: 32m
    so-rcvbuf: 1m

    # TTLs y prefetch
    cache-min-ttl: 300
    cache-max-ttl: 86400
    cache-max-negative-ttl: 3600
    prefetch: yes
    prefetch-key: yes
    serve-expired: yes
    serve-expired-ttl: 3600

    # Privacidad
    qname-minimisation: yes
    qname-minimisation-strict: no
    use-caps-for-id: no

    # Endurecimiento
    harden-glue: yes
    harden-dnssec-stripped: yes
    harden-below-nxdomain: yes
    harden-referral-path: yes
    aggressive-nsec: yes
    unwanted-reply-threshold: 10000

    # DNSSEC
    auto-trust-anchor-file: "/opt/unbound/etc/unbound/root.key"
    root-hints: "/opt/unbound/etc/unbound/root.hints"

    # Defensa contra DNS rebinding (rechaza respuestas con IPs privadas
    # para dominios públicos). NO se hace excepción para 192.168.1.0/24
    # porque el homelab no delega zonas internas a Unbound: las maneja
    # Pi-hole vía dnsmasq.d/02-homelab-local.conf.
    private-address: 10.0.0.0/8
    private-address: 172.16.0.0/12
    private-address: 192.168.0.0/16
    private-address: 169.254.0.0/16
    private-address: fd00::/8
    private-address: fe80::/10

    # ACLs: por defecto rechaza todo, y permite solo a Pi-hole y al host.
    access-control: 0.0.0.0/0 refuse
    access-control: 127.0.0.0/8 allow
    access-control: 192.168.1.2/32 allow      # Pi-hole
    access-control: 192.168.1.9/32 allow      # macvlan-shim del host (diagnóstico)
```

> **Por qué `access-control` y no firewall**: el contenedor está en macvlan; UFW del host no lo cubre (la macvlan no atraviesa `iptables` del host para tráfico LAN→contenedor). La defensa **debe** vivir en el propio Unbound. Si en algún momento se necesita una segunda capa, se podría añadir un `iptables` en el namespace del contenedor, pero `access-control` es la respuesta canónica del proyecto Unbound y suficiente.

### Crear los directorios persistentes y desplegar

```bash
# Directorios de datos (idempotente)
sudo install -d -o homelab -g homelab -m 0750 /mnt/hd2t/apps/unbound
sudo install -d -o homelab -g homelab -m 0750 /mnt/hd2t/apps/unbound/etc
sudo install -d -o homelab -g homelab -m 0750 /mnt/hd2t/apps/unbound/etc/unbound.conf.d

# root.hints (idempotente: -f sobreescribe; curl -f falla si HTTP no 2xx)
sudo curl -fsSL https://www.internic.net/domain/named.root \
    -o /mnt/hd2t/apps/unbound/etc/root.hints
sudo chown homelab:homelab /mnt/hd2t/apps/unbound/etc/root.hints
sudo chmod 0644 /mnt/hd2t/apps/unbound/etc/root.hints

# root.key inicial vacío para que el bind mount lo cree como fichero
# (no como directorio): unbound-anchor lo poblará en el primer arranque.
sudo touch /mnt/hd2t/apps/unbound/etc/root.key
sudo chown homelab:homelab /mnt/hd2t/apps/unbound/etc/root.key
sudo chmod 0644 /mnt/hd2t/apps/unbound/etc/root.key

# Materializar la conf desde la plantilla versionada
cd /home/homelab/homelab
install -o homelab -g homelab -m 0644 \
    stacks/unbound/etc/unbound.conf.d/00-homelab.conf.example \
    /mnt/hd2t/apps/unbound/etc/unbound.conf.d/00-homelab.conf

# Verificar la red externa
docker network inspect dns_lan >/dev/null

# Validar el compose con interpolación
docker compose \
    -f stacks/unbound/docker-compose.yml \
    --env-file .env --env-file stacks/unbound/.env \
    config >/dev/null && echo "compose OK"

# Levantar
docker compose \
    -f stacks/unbound/docker-compose.yml \
    --env-file .env --env-file stacks/unbound/.env \
    up -d
```

Tras `up -d`:

```bash
docker ps --filter name=unbound
# CONTAINER ID  IMAGE                     STATUS                  PORTS  NAMES
# ...           mvance/unbound:1.20.0     Up 60 seconds (healthy)        unbound

docker compose -f stacks/unbound/docker-compose.yml logs --tail 30
# [unbound] start of service
# unbound-anchor: success: the anchor is ok
# unbound: server: start of service (unbound 1.20.0).
# unbound: server: service stopped/started ...
```

`STATUS` debe pasar a `(healthy)` en ~90 s. Si se queda `(starting)`:
- El primer `unbound-anchor` puede tardar si `eth0` aún no tiene resolución DNS hacia IANA (paradoja del huevo y la gallina: Unbound se está montando, Pi-hole está vivo, pero el contenedor de Unbound usa el DNS por defecto del daemon Docker, que es el del host). En la práctica funciona porque el host tiene fallback `1.1.1.1` desde `02-pihole.md`. Si no, `docker exec unbound nslookup data.iana.org` lo evidencia.
- `root.key` con permisos incorrectos: el contenedor (UID `_unbound`, ~999) necesita poder reescribir el fichero para el rollover RFC 5011. `0644` propiedad de `homelab:homelab` funciona porque el contenedor escribe con su UID y el bind mount respeta los permisos del host.

---

## Configuración

### 1) Probar Unbound aislado, **antes** de cambiar Pi-hole

Si algo está mal en Unbound, mejor descubrirlo **sin** romper el DNS del hogar. La macvlan-shim permite consultar a Unbound desde la propia Pi sin pasar por Pi-hole:

```bash
# Resolución directa contra Unbound desde el host
dig @192.168.1.3 example.com +short
# (una IP)

dig @192.168.1.3 example.com +dnssec +multi | head -20
# Debe contener una sección "RRSIG" — DNSSEC está validando.

# Comprobación de DNSSEC (zona deliberadamente rota)
dig @192.168.1.3 dnssec-failed.org +dnssec
# status: SERVFAIL  → CORRECTO: Unbound rechaza la respuesta firmada inválidamente.

# Una zona DNSSEC sana
dig @192.168.1.3 cloudflare.com +dnssec
# status: NOERROR + sección RRSIG presente.

# qname-minimisation activo (debería verse a nivel de tcpdump si se quiere
# verificar: las consultas a los TLD no llevan el FQDN completo).
```

Si `dnssec-failed.org` devuelve una IP en vez de SERVFAIL, DNSSEC **no** está validando: revisar `auto-trust-anchor-file` en `00-homelab.conf` y el contenido de `root.key`.

### 2) Comprobar el `access-control`

Desde otro host de la LAN (un móvil, un portátil), preguntar **directamente** a Unbound:

```bash
# Desde un equipo que NO sea ni la Pi ni Pi-hole:
dig @192.168.1.3 example.com +short
# ;; communications error to 192.168.1.3#53: timed out
# o
# status: REFUSED
```

Si **resuelve**, el `access-control` no está aplicando: revisar el orden de las reglas (`refuse` por defecto + `allow` específicos) y reiniciar Unbound (`docker compose ... restart`).

### 3) Cambiar el upstream de Pi-hole a Unbound

Esta es **la** transición. Se hace cambiando una variable y reiniciando Pi-hole. La operación es reversible (basta volver a poner `1.1.1.1;9.9.9.9` y reiniciar) y no toca a ningún cliente de la LAN.

#### Opción A — Cambio vía variable de entorno (recomendado)

Editar `stacks/pihole/.env` (o el bloque `environment:` del compose si así se gestionó):

```bash
# stacks/pihole/.env  (fragmento)
PIHOLE_DNS_=192.168.1.3#53
```

Y aplicar:

```bash
cd /home/homelab/homelab
docker compose \
    -f stacks/pihole/docker-compose.yml \
    --env-file .env --env-file stacks/pihole/.env \
    up -d --force-recreate
```

> **Importante**: `PIHOLE_DNS_` se aplica solo **en el primer arranque** del contenedor (escribe `setupVars.conf` y termina). En recreaciones posteriores, Pi-hole respeta lo que ya esté en `setupVars.conf`. Por eso el cambio se hace con `--force-recreate` la primera vez **o** complementariamente desde la UI.

#### Opción B — Cambio vía UI de Pi-hole

```
http://192.168.1.2/admin/  →  Settings  →  DNS
    Upstream DNS Servers
        Custom 1 (IPv4): 192.168.1.3#53
        Desmarcar todos los upstream públicos (Cloudflare, Quad9, etc.)
    [Save]
```

Esta vía persiste el cambio en `/mnt/hd2t/apps/pihole/etc/setupVars.conf` (`PIHOLE_DNS_1=192.168.1.3#53`), que es lo que Pi-hole realmente lee tras el primer arranque. Conviene **además** dejar `PIHOLE_DNS_=192.168.1.3#53` en `stacks/pihole/.env` para que el día de un reflasheo sin restore de la base de Pi-hole, el primer arranque ya nazca apuntando bien.

### 4) Verificar que Pi-hole usa Unbound

```bash
# Desde un cliente de la LAN: una consulta nueva.
dig @192.168.1.2 ietf.org +short
# (una IP)

# En Pi-hole UI → Query Log: la consulta aparece marcada como
# "Forwarded to 192.168.1.3#53". NO debe aparecer "1.1.1.1" ni "9.9.9.9"
# para ninguna consulta posterior al cambio.

# En logs de Unbound: la consulta entra y se resuelve.
docker compose -f stacks/unbound/docker-compose.yml logs --tail 20
# (con verbosity 1 las consultas individuales no se loguean; subir
# temporalmente a 2 para depurar)
```

Pi-hole también imprime el upstream activo en `Settings → DNS` y en `pihole status`:

```bash
docker exec pihole pihole status
# [✓] FTL is listening on port 53
# [✓] Pi-hole blocking is enabled
docker exec pihole grep -E '^PIHOLE_DNS_' /etc/pihole/setupVars.conf
# PIHOLE_DNS_1=192.168.1.3#53
```

### 5) Activar la entrada DNS local `unbound.lan` (diagnóstico)

En `02-pihole.md` se dejó preparada (comentada) una línea para que `unbound.lan` resuelva a `${UNBOUND_IP}`. Activarla facilita el diagnóstico (poder usar `dig @unbound.lan`):

```bash
# Editar /mnt/hd2t/apps/pihole/dnsmasq.d/02-homelab-local.conf
# Descomentar:
address=/unbound.lan/192.168.1.3

docker exec pihole pihole restartdns
# [✓] Restarting DNS server

dig @192.168.1.2 unbound.lan +short
# 192.168.1.3
```

> **Por qué `unbound.lan` resuelve vía Pi-hole y no se publica en otra parte**: la regla "una sola fuente para `*.lan`" se mantiene. Que `unbound.lan` exista como nombre **no** habilita a la LAN a hablar con Unbound: el `access-control` sigue rechazando. Es solo azúcar para tipear menos al diagnosticar.

---

## Almacenamiento

| Ruta | Soporte | Owner:Group | Modo | Contenido |
|---|---|---|---|---|
| `/home/homelab/homelab/stacks/unbound/docker-compose.yml` | microSD | `homelab:homelab` | `0640` | Stack versionado en git. |
| `/home/homelab/homelab/stacks/unbound/.env.example` | microSD | `homelab:homelab` | `0644` | Plantilla versionada. |
| `/home/homelab/homelab/stacks/unbound/.env` | microSD | `homelab:homelab` | `0600` | Sin secretos en esta versión; existe por convención. **No** versionado. |
| `/home/homelab/homelab/stacks/unbound/etc/unbound.conf.d/00-homelab.conf.example` | microSD | `homelab:homelab` | `0644` | Plantilla del fichero de configuración. **Sí** versionada. |
| `/mnt/hd2t/apps/unbound/etc/unbound.conf.d/00-homelab.conf` | hd2t | `homelab:homelab` | `0644` | Configuración real, materializada desde la plantilla. |
| `/mnt/hd2t/apps/unbound/etc/root.hints` | hd2t | `homelab:homelab` | `0644` | Lista de root servers descargada de IANA. |
| `/mnt/hd2t/apps/unbound/etc/root.key` | hd2t | `homelab:homelab` | `0644` | Trust anchor DNSSEC, gestionado por `unbound-anchor` (RFC 5011). |

> **Caché en RAM**: la caché de Unbound (`rrset-cache`, `msg-cache`) vive en memoria del contenedor: tras un `restart` se pierde y se rellena en minutos. No se persiste a disco; no merece la pena para 96 MB en un homelab con SSD/HDD lentos.

---

## Backup

A nivel del repositorio del homelab:

| Artefacto | Estrategia |
|---|---|
| `stacks/unbound/docker-compose.yml`, `.env.example`, `etc/unbound.conf.d/00-homelab.conf.example` | Versionados en git. Reproducibles tras un reflasheo. |
| `stacks/unbound/.env` | **No** versionado (convención). Sin secretos en esta versión, pero respaldado por Borg como parte de `/home/homelab/homelab/`. |
| Decisiones (recursivo vs forwarder, DNSSEC, ACLs, `qname-minimisation`) | Documentadas en este fichero. Reproducibles en el primer arranque tras un reflasheo. |

A nivel de datos (Borgmatic, Fase 7):

| Ruta | ¿Se respalda? | Por qué |
|---|---|---|
| `/mnt/hd2t/apps/unbound/etc/unbound.conf.d/` | **Sí**, `homelab.backup=true`. | Reproducible desde la plantilla, pero respaldarlo evita reaplicar la materialización tras un restore. |
| `/mnt/hd2t/apps/unbound/etc/root.hints` | **Sí**. | Reproducible (un `curl` a IANA), pero tan pequeño que da igual. |
| `/mnt/hd2t/apps/unbound/etc/root.key` | **Sí**. | Estado RFC 5011: la clave actual y los rollovers en marcha. Si se pierde, `unbound-anchor` lo regenera; respaldarlo ahorra un primer arranque con WARNING en logs. |

Procedimiento de restore tras pérdida del contenedor (datos intactos en `hd2t`):

```bash
docker compose -f /home/homelab/homelab/stacks/unbound/docker-compose.yml up -d --force-recreate
# Unbound reusa /mnt/hd2t/apps/unbound/etc; root.key y root.hints se reaprovechan.
```

Procedimiento de restore tras pérdida total (reflasheo + restauración Borg):

1. Recrear sistema base (Fase 1), Docker (Fase 2.1), red `homelab` y red `dns_lan` (`01-macvlan.md`), Pi-hole (`02-pihole.md`).
2. Restaurar `/mnt/hd2t/apps/unbound/etc/` desde Borg.
3. `docker compose -f stacks/unbound/docker-compose.yml up -d`.
4. Verificar `dig @192.168.1.3 example.com +short` y `dig @192.168.1.3 dnssec-failed.org +dnssec` (SERVFAIL esperado).
5. Confirmar que Pi-hole sigue apuntando a `192.168.1.3#53` (`docker exec pihole grep PIHOLE_DNS_ /etc/pihole/setupVars.conf`).

Si lo que se quiere es **resetear** Unbound (caché, root.key reciclado):

```bash
docker compose -f stacks/unbound/docker-compose.yml down
sudo rm -f /mnt/hd2t/apps/unbound/etc/root.key
sudo touch /mnt/hd2t/apps/unbound/etc/root.key
sudo chown homelab:homelab /mnt/hd2t/apps/unbound/etc/root.key
docker compose -f stacks/unbound/docker-compose.yml up -d
# unbound-anchor regenera root.key en el primer arranque.
```

`00-homelab.conf` y `root.hints` se conservan: solo el trust anchor se ricicla.

---

## Errores frecuentes y troubleshooting

| Síntoma | Causa probable | Resolución |
|---|---|---|
| Pi-hole devuelve `SERVFAIL` para todo tras cambiar el upstream | Unbound no es alcanzable desde Pi-hole, o el `access-control` está bloqueando a Pi-hole. | `docker exec pihole dig @192.168.1.3 example.com +short` desde el contenedor de Pi-hole; si falla, revisar que ambos están en `dns_lan` (`docker network inspect dns_lan`) y que `00-homelab.conf` lleva `access-control: 192.168.1.2/32 allow`. |
| `dig @192.168.1.3 example.com` desde **otro** equipo de la LAN sí responde | El `access-control` no está aplicado: la regla `refuse` por defecto se está ignorando. | Comprobar que `00-homelab.conf` se ha cargado: `docker exec unbound unbound-checkconf` y `docker compose ... logs unbound | grep -i access`. Reiniciar el contenedor. |
| `STATUS=unhealthy` permanente; logs dicen `error: failed to load trust anchor` | `root.key` corrupto o sin permisos de escritura para el contenedor. | `ls -l /mnt/hd2t/apps/unbound/etc/root.key` debe ser `homelab:homelab 0644`. Si no, corregir y reiniciar. Si persiste, regenerar como en "resetear Unbound" arriba. |
| `dnssec-failed.org` resuelve a una IP en lugar de SERVFAIL | DNSSEC no está validando. | Revisar `auto-trust-anchor-file` en `00-homelab.conf`, comprobar `cat /mnt/hd2t/apps/unbound/etc/root.key` (debe contener una `DNSKEY`/`DS`), reiniciar. |
| Latencia muy alta en consultas no cacheadas (varios segundos) | `do-ip6: yes` con LAN sin IPv6 funcional, o `root.hints` desactualizado y los root nuevos rechazados. | Verificar que `do-ip6: no` (es la decisión del documento). Refrescar `root.hints` desde IANA. |
| `Could not parse server` o `error: bad option` al arrancar | Sintaxis errónea en `00-homelab.conf`. | `docker exec unbound unbound-checkconf` apunta a la línea exacta. Corregir, reiniciar. |
| Pi-hole UI sigue mostrando `1.1.1.1` y `9.9.9.9` como upstream tras el cambio | `PIHOLE_DNS_` solo se aplica en **primer** arranque; el cambio vía variable necesitó `--force-recreate`. | `docker compose -f stacks/pihole/docker-compose.yml up -d --force-recreate` o cambiar desde la UI (Opción B), que persiste en `setupVars.conf`. |
| Tras reboot, Unbound arranca pero Pi-hole no resuelve durante 30-60s | Race entre Pi-hole arrancando antes que Unbound. | Pi-hole tolera SERVFAIL temporal y reintenta. Si se quiere ordenar, añadir `depends_on: [unbound]` cruzando stacks no es trivial (Compose v2 no orquesta entre stacks). El comportamiento actual es aceptable: ambos están en `restart: unless-stopped` y la convergencia es de segundos. |
| `unbound-anchor: failed to verify` en el primer arranque | Sin internet (cable desconectado, `eth0` sin IP) o sin DNS para resolver `data.iana.org`. | Verificar `eth0`, fallback en `/etc/resolv.conf` del host (`02-pihole.md` paso 5). Reintentar `docker compose ... up -d --force-recreate`. |
| Caché desproporcionada (`docker stats` muestra 100+ MB de RSS) | Normal: `rrset-cache-size: 64m` + `msg-cache-size: 32m` + estructuras internas. | No es un bug. Bajar a `32m`/`16m` si la Pi va apretada de RAM, pero con 8 GB no merece la pena. |
| Pi-hole reporta `pihole status: unable to determine` | El contenedor de Pi-hole no puede contactar con su FTL local; no es problema de Unbound, pero suele aparecer junto si el reinicio fue agresivo. | `docker compose -f stacks/pihole/docker-compose.yml restart`. |
| `dig @192.168.1.3 jellyfin.lan +short` no resuelve | Correcto: Unbound es **recursivo**, no maneja `*.lan`. Esa zona vive en Pi-hole. | No es un error; preguntar siempre a Pi-hole para nombres locales. La entrada `unbound.lan` (dispositivo, no zona) sí se resuelve porque la pone Pi-hole. |
| Algunas zonas concretas dan SERVFAIL (raro pero ocurre con autoritativos rotos) | La zona en cuestión tiene DNSSEC mal firmado en su autoritativo. | Verificar con un resolver público: `dig @1.1.1.1 zona-rota.com +dnssec`. Si `1.1.1.1` también devuelve SERVFAIL, **no** es Unbound: la zona está rota. Si solo Unbound falla, comprobar `root.key`. |

---

## Decisiones que **no** se toman en este documento

- **Forwarding a `1.1.1.1` con DNS-over-TLS**: descartado por privacidad (centralizar en un único proveedor). Reabrible si en algún momento la latencia recursiva resulta intolerable; sería cambiar `00-homelab.conf` para añadir un bloque `forward-zone: "."` con `forward-tls-upstream: yes`. La decisión es cerrada en este homelab pero la técnica está documentada por si cambia el contexto.
- **`local-zone` en Unbound para `*.lan`**: rechazado por simplicidad — el espacio de nombres local lo gestiona Pi-hole. Si en algún momento se quiere mover (porque Pi-hole se elimine, por ejemplo), se reabre.
- **Reverse proxy de Unbound con Caddy**: Unbound no tiene UI ni HTTP. No procede. La excepción serían las métricas Prometheus vía `unbound-exporter`, que se evaluará en Fase 6 (monitorización).
- **Acceso desde Tailscale**: los clientes Tailscale resuelven vía Pi-hole (declarado en MagicDNS, ver `05-tailscale.md`). Unbound no se anuncia al tailnet.
- **IPv6**: `do-ip6: no`. Si la LAN del operador adquiere IPv6 funcional, se reabre la decisión.
- **Métricas Prometheus**: existe `unbound-exporter` y Unbound expone `remote-control` (control TLS sobre `:8953`). Se integra en Fase 6, no aquí.
- **`view` y políticas por cliente**: Unbound puede dar respuestas distintas según la IP del consultor. No se usa porque el único consultor es Pi-hole.
- **`unbound-control` desde el host**: requeriría exponer `:8953` con TLS interno y certificado. Descartado por innecesario en operación normal; se reabre si el operador necesita inyectar entradas en caché o forzar `flush_zone` desde el host. En el día a día, `docker compose restart` es suficiente.

---

## Verificación Final

Antes de pasar a `04-caddy.md`:

| Comprobación | Comando | Resultado esperado |
|---|---|---|
| Stack desplegado y saludable | `docker compose -f stacks/unbound/docker-compose.yml ps` | `unbound  ...  Up (healthy)` |
| Imagen correcta y fija | `docker inspect unbound --format '{{.Config.Image}}'` | `mvance/unbound:1.20.0` |
| Conectado a `dns_lan` con IP correcta | `docker network inspect dns_lan --format '{{range .Containers}}{{.Name}} {{.IPv4Address}}{{"\n"}}{{end}}'` | incluye `unbound 192.168.1.3/24` |
| **No** está en `homelab` | `docker network inspect homelab --format '{{range .Containers}}{{.Name}} {{end}}'` | **no** incluye `unbound` |
| MAC fija | `docker inspect unbound --format '{{range .NetworkSettings.Networks}}{{.MacAddress}} {{end}}'` | incluye `02:42:c0:a8:01:03` |
| Configuración válida | `docker exec unbound unbound-checkconf` | `unbound-checkconf: no errors in /opt/unbound/etc/unbound/unbound.conf` |
| `root.key` poblado por `unbound-anchor` | `head -1 /mnt/hd2t/apps/unbound/etc/root.key` | empieza por `. <num> IN DS` o `. <num> IN DNSKEY` (no vacío) |
| `root.hints` presente y válido | `wc -l /mnt/hd2t/apps/unbound/etc/root.hints` | aprox. 20-40 líneas |
| Unbound resuelve recursivamente desde el host (vía shim) | `dig @192.168.1.3 example.com +short` | una IP |
| DNSSEC validando (zona buena) | `dig @192.168.1.3 cloudflare.com +dnssec +multi \| grep -c RRSIG` | ≥ 1 |
| DNSSEC validando (zona rota) | `dig @192.168.1.3 dnssec-failed.org +dnssec` | `status: SERVFAIL` |
| ACL bloquea consultas no autorizadas | desde otro host de la LAN: `dig @192.168.1.3 example.com +short` | timeout o `REFUSED` |
| Pi-hole apunta a Unbound, **solo** | `docker exec pihole grep -E '^PIHOLE_DNS_' /etc/pihole/setupVars.conf` | `PIHOLE_DNS_1=192.168.1.3#53`, no aparecen `PIHOLE_DNS_2`/`3`/`4` con públicos |
| Una consulta nueva por la LAN aparece reenviada a `192.168.1.3` en Pi-hole | UI → Query Log → última fila | columna *Reply From* / *Forwarded to* muestra `192.168.1.3#53` |
| `unbound.lan` resuelve a `192.168.1.3` (azúcar de diagnóstico) | `dig @192.168.1.2 unbound.lan +short` | `192.168.1.3` |
| Persistencia tras reboot | `sudo reboot`; tras reconectar: `docker ps --filter name=unbound` | `Up ... (healthy)` sin acción manual |
| Datos persistidos en hd2t, no en microSD | `ls /mnt/hd2t/apps/unbound/etc/` | `root.hints`, `root.key`, `unbound.conf.d/` presentes |
| Stack en git (sin secretos) | `git status; git diff --cached --stat` | `stacks/unbound/docker-compose.yml`, `.env.example`, `etc/unbound.conf.d/00-homelab.conf.example` tracked |
| Caída controlada de Unbound no rompe la LAN inmediatamente | `docker compose -f stacks/unbound/docker-compose.yml stop`; en otro equipo `dig @192.168.1.2 example.com +short` | la primera consulta puede dar SERVFAIL; al volver a levantar Unbound (`up -d`) se restablece. Documentar es importante: la dependencia es real y por eso el siguiente paso es el reverse proxy, no más capas DNS. |

Cumplido el último punto, **toda la cadena DNS del homelab vive dentro de la Pi**: dispositivos → Pi-hole (filtrado) → Unbound (recursivo, DNSSEC, sin terceros) → root servers. El siguiente eslabón ya no es DNS sino HTTPS interno: `04-caddy.md` despliega Caddy como reverse proxy en `homelab`, atendiendo `:80` y `:443` sobre la IP libre de la Pi (`192.168.1.10`) y poblando con servicios el comodín `*.lan` que Pi-hole ya está apuntando a esa IP.

---

## Referencias

- [Documento anterior: `docs/03-red/02-pihole.md`](./02-pihole.md)
- [Documento siguiente: `docs/03-red/04-caddy.md`](./04-caddy.md)
- [Documento relacionado: `docs/03-red/01-macvlan.md`](./01-macvlan.md)
- [Documento relacionado: `docs/02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md)
- [Unbound — Documentación oficial (NLnet Labs)](https://nlnetlabs.nl/documentation/unbound/)
- [Unbound — `unbound.conf(5)` reference](https://nlnetlabs.nl/documentation/unbound/unbound.conf/)
- [`mvance/unbound` — Imagen Docker en Docker Hub](https://hub.docker.com/r/mvance/unbound)
- [Pi-hole — Guide: How to add Unbound to your Pi-hole](https://docs.pi-hole.net/guides/dns/unbound/)
- [IANA — Root server hints (`named.root`)](https://www.internic.net/domain/named.root)
- [RFC 7816 — DNS Query Name Minimisation to Improve Privacy](https://datatracker.ietf.org/doc/html/rfc7816)
- [RFC 5011 — Automated Updates of DNS Security (DNSSEC) Trust Anchors](https://datatracker.ietf.org/doc/html/rfc5011)
- [RFC 8767 — Serving Stale Data to Improve DNS Resiliency](https://datatracker.ietf.org/doc/html/rfc8767)
