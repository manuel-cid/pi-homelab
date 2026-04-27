# Unbound (resolver DNS recursivo)

## Descripción

Despliegue de **Unbound** como **resolver DNS recursivo y validador DNSSEC** del homelab, sentado por debajo de Pi-hole. Asume las decisiones tomadas en `docs/03-red/01-macvlan.md` y `docs/03-red/02-pihole.md`: Unbound corre en la misma red Docker `lan` (driver `macvlan`, _parent_ `eth0`) con **IP propia `192.168.1.4`** y **MAC fija `02:42:c0:a8:01:04`** ya reservadas en el DHCP del router. Escucha en `5335/udp` y `5335/tcp` sobre esa IP, y Pi-hole lo usa como su único _upstream_ (sustituyendo el `1.1.1.1;1.0.0.1` transitorio que se configuró en `docs/03-red/02-pihole.md`).

Con Pi-hole bloqueando publicidad/telemetría y Unbound resolviendo de forma recursiva contra los _root servers_, el homelab deja de depender de un tercero (Cloudflare, Google, ISP) para la resolución DNS: cada nombre se resuelve preguntando a la cadena oficial **root → TLD → autoritativo**, con DNSSEC validado en el propio Unbound. La privacidad mejora (ningún proveedor único ve el 100 % de las consultas) y la _trust chain_ está bajo control del homelab.

Este documento **se suma al _stack_ `red`** que estrenó `docs/03-red/02-pihole.md`. No se crea un compose nuevo: se añade un servicio `unbound` al `~/homelab/red/docker-compose.yml` ya existente, junto a un subdirectorio `red/unbound/` con la configuración versionable.

> **Alcance**: este documento despliega **únicamente** Unbound y lo cablea como _upstream_ de Pi-hole. **No** define el `Caddyfile` ni la _CA_ local (`docs/03-red/04-caddy.md`), **no** configura Tailscale (`docs/03-red/05-tailscale.md`) y **no** integra con Authelia (`docs/04-seguridad/01-authelia.md`). Unbound vive en LAN; no se publica a internet ni se le pone una UI por delante (no la tiene).

> **Recordatorio de red**: el homelab vive en LAN + Tailscale. Unbound resuelve **saliendo a internet** (puertos 53/udp y 53/tcp salientes contra los _root servers_ y autoritativos), pero **no acepta consultas desde fuera de la LAN**: el puerto `5335` sólo está expuesto sobre la IP macvlan `192.168.1.4`, accesible únicamente para clientes del propio segmento `192.168.1.0/24`.

---

## Requisitos previos

- `docs/03-red/01-macvlan.md` completado: red Docker `lan` (driver `macvlan`, `--ip-range 192.168.1.0/29`) creada, _shim_ `macvlan-shim` activo en el host con ruta a `192.168.1.0/29`, reservas DHCP por MAC en el router para `02:42:c0:a8:01:04 → 192.168.1.4` ya aplicadas.
- `docs/03-red/02-pihole.md` completado: Pi-hole desplegado en `192.168.1.2`, _stack_ `red` (`~/homelab/red/`) creado con `docker-compose.yml`, `.env`, `.env.example` y `etc-dnsmasq.d/02-homelab-local.conf` ya en git. La línea `# - unbound.lan se rellenará en docs/03-red/03-unbound.md.` espera el record que se añade aquí.
- `docs/01-sistema/04-estructura-directorios.md` completado: `/mnt/hd2t/services/unbound/` ya existe como directorio vacío `root:root 0755`. En este servicio el directorio acaba **no usándose** (ver sección **Almacenamiento**); se mantiene por consistencia con el resto del homelab y por si en el futuro se persiste la caché.
- `docs/01-sistema/03-seguridad-base.md` completado: `nftables` con `input drop` por defecto, política `output` permite tráfico saliente arbitrario (Unbound necesita salir por `53/udp` y `53/tcp` a cualquier destino para hablar con los _root servers_ y los autoritativos).
- Conectividad saliente desde el host hacia los _root servers_:

  ```bash
  dig @a.root-servers.net . NS +time=3 +tries=1 +short | head
  ```

  Debe devolver una lista de nombres `*.root-servers.net.`. Si no responde, el operador del homelab está detrás de un _firewall_ que filtra DNS saliente y Unbound no podrá resolver — solucionarlo antes de continuar (típicamente, un router con "DNS interception" activado obligando a usar el del ISP).

- `docker pull --platform linux/arm64 mvance/unbound:1.22.0 >/dev/null && echo OK` debe funcionar.

---

## Decisiones de diseño

### Por qué Unbound recursivo y no un _upstream_ público (DoT/DoH)

`docs/03-red/02-pihole.md` deja Pi-hole apuntando a Cloudflare (`1.1.1.1`) como medida transitoria. Es funcional, pero implica que **Cloudflare ve cada dominio que cualquier dispositivo del hogar visita** (modulado por la caché de Pi-hole, pero el grueso del tráfico sale hacia ellos). Un Unbound recursivo cambia el modelo:

| Modelo                          | Quién ve la consulta                                                  | Privacidad                       | Latencia (cache miss)        |
|---------------------------------|-----------------------------------------------------------------------|----------------------------------|------------------------------|
| Pi-hole → `1.1.1.1`             | Cloudflare ve el 100 % de las consultas no-bloqueadas                | Baja (un solo punto de telemetría) | ~10-30 ms (Cloudflare es rápido) |
| Pi-hole → Unbound recursivo     | El _root server_ ve el TLD, el TLD ve el dominio, el autoritativo ve el subdominio. Ninguno ve la cadena completa. | Alta (consulta repartida)         | ~100-300 ms el primer hit, luego cache |

El coste es latencia en el primer _hit_ (y a veces en _cache miss_ tras expirar TTL); el beneficio es la independencia de un tercero y la validación DNSSEC con un validador bajo nuestro control. En un homelab de uso doméstico la latencia añadida (típicamente 100-200 ms una vez por dominio cada pocos minutos) es imperceptible.

> **DoT/DoH como alternativa intermedia**: redirigir Pi-hole a `1.1.1.1` por DNS-over-TLS o DNS-over-HTTPS (vía `cloudflared` o `dnscrypt-proxy`) cifra el _transport_, pero **no quita** a Cloudflare la visibilidad de las consultas. Es complementario a Unbound, no sustituto. Si en el futuro se quiere _fallback_ DoT cuando Unbound esté caído, se añade ahí; por ahora se mantiene la cadena recursiva pura.

### Imagen y _tag_

- **`mvance/unbound:1.22.0`** (Unbound **1.22.0**, multi-arch con `linux/arm64`).
- Se pinnea explícitamente; **no** se usa `:latest` ni `:1.22` (convención del homelab: _tags_ con versión completa, ver `docs/02-docker/04-watchtower.md`).
- `mvance/unbound` (en lugar de `klutchell/unbound` o construir uno propio) por:
  - mantenido activamente y con _multi-arch_ desde **1.16+** (Pi 5 / `linux/arm64` soportado de fábrica),
  - actualiza `root.hints` automáticamente vía cron interno cada 6 meses,
  - incluye `drill` para `healthcheck` y `unbound-control` para diagnóstico,
  - configuración 100 % por fichero (no hay variables de entorno opacas), lo que encaja con la convención de versionar todo en git.
- Unbound entra en _opt-in_ de Watchtower (`docs/02-docker/04-watchtower.md`): el contenedor es _stateless_ (no hay BD que migrar entre versiones), todo el estado vive en el `unbound.conf` versionado. Las regresiones se detectan en minutos por Uptime Kuma.

### Puerto `5335` (no `53`)

Aunque Unbound tiene su propia IP (`192.168.1.4`) y, en principio, podría escuchar en `53` sin colisionar con el `53` de Pi-hole (`192.168.1.2`), se usa **`5335`** por dos razones:

1. **Convención de la documentación oficial de Pi-hole** (`https://docs.pi-hole.net/guides/dns/unbound/`): toda la comunidad publica `setupVars.conf` con `PIHOLE_DNS_1=127.0.0.1#5335` o `PIHOLE_DNS_1=192.168.1.4#5335`. Mantener el mismo puerto facilita pegar guías ajenas sin traducir.
2. **Disuasión de uso accidental**: cualquier dispositivo de la LAN podría usar `192.168.1.4:53` como DNS si fuese válido, _saltándose Pi-hole_. Con `5335` (puerto no estándar), un cliente con DNS automático nunca llegará a Unbound: sólo Pi-hole, configurado a mano para hablarle por ese puerto, lo usa.

`docs/03-red/02-pihole.md` ya anticipó este detalle en su `.env.example` (`PIHOLE_UPSTREAMS=1.1.1.1;1.0.0.1` con la nota "cuando Unbound levante, sustituir por `192.168.1.4#5335`").

### Recursivo puro, sin _forwarder_

`unbound.conf` se configura **sin `forward-zone:`**: las consultas entran y se resuelven recursivamente desde los _root servers_ (`root.hints`). Excepción: el dominio `lan.` se trata como _local zone transparent_ para que las preguntas internas de Unbound (las que se hace a sí mismo cuando Pi-hole le reenvía un nombre `*.lan` que no debería) den `NXDOMAIN` rápido en lugar de salir a internet.

> **Por qué `transparent` y no `static`**: con `transparent` Unbound responde `NXDOMAIN` para nombres no listados en su zona local **pero** permite que registros locales explícitos (si alguna vez se añaden en `local-data:`) tengan precedencia. `static` es más estricto pero también más cerrado para futuros cambios.

### DNSSEC habilitado

`module-config: "validator iterator"` activa la cadena de validación DNSSEC con la _trust anchor_ del root (`/usr/share/dns/root.key` o equivalente, autogestionada por la imagen vía RFC 5011). Con esto, las respuestas que llegan a Pi-hole ya vienen validadas y Pi-hole reenvía el bit `AD` (`Authenticated Data`) al cliente.

> **Si DNSSEC duplicado en Pi-hole rompe algo**: `docs/03-red/02-pihole.md` activó `DNSSEC: "true"` en Pi-hole, lo que implica que Pi-hole también valida. Tener dos validadores en cascada es redundante pero no problemático: Unbound valida primero (y propaga `AD`), Pi-hole vuelve a validar y, si Unbound dijo OK, Pi-hole también. El coste es CPU mínima (~1 ms por consulta). Si en algún momento se ven problemas de SERVFAIL en sitios concretos, **desactivar DNSSEC en Pi-hole** (que confíe en Unbound) en lugar de hacerlo en Unbound (donde aporta más).

### `qname-minimisation` y _privacy_

Activado por defecto en Unbound desde 1.13. Con QNAME minimisation, cuando Unbound pregunta al _root server_ por `something.subdomain.example.com`, sólo le pregunta por `com` (no la cadena entera), reduciendo la información que cada eslabón ve. Conviene declararlo explícito en el `unbound.conf` para que un futuro _downgrade_ de versión no lo desactive sin avisar.

### Caché y rendimiento en una Pi 5

Una Pi 5 (8 GB) tiene RAM de sobra para una caché de Unbound generosa. Valores razonables del `unbound.conf`:

- `msg-cache-size: 64m` (mensajes DNS cacheados)
- `rrset-cache-size: 128m` (registros individuales)
- `cache-min-ttl: 300` (mínimo 5 min, evita _hammering_ a autoritativos por dominios con TTL absurdamente bajo)
- `cache-max-ttl: 86400` (máximo 24 h, fuerza refresco diario incluso si el autoritativo da TTLs largos)

Esto da un _hit ratio_ típico del 85-95 % tras unas horas de uso doméstico, con ~50-150 MB residentes. Suficiente.

### Almacenamiento

| Ruta en el host                        | Contenido                                            | Backup |
|----------------------------------------|------------------------------------------------------|--------|
| `~/homelab/red/unbound/unbound.conf`   | Configuración (versionada en git)                    | Sí (vía git) |
| `~/homelab/red/unbound/a-records.conf` | Records A locales (vacío por convención; los gestiona Pi-hole vía `02-homelab-local.conf`) | Sí (vía git) |
| `~/homelab/red/unbound/forward-records.conf` | _Forwarders_ (vacío; Unbound es recursivo puro) | Sí (vía git) |
| `/mnt/hd2t/services/unbound/`          | (vacío en _runtime_, no se monta)                    | N/A    |

A diferencia de Pi-hole, Unbound es **completamente _stateless_**: la caché vive en memoria, `root.hints` y la _trust anchor_ DNSSEC las gestiona la imagen, y no hay BD propia. Por tanto **no se _bind-mounta_ nada de `/mnt/hd2t/`**; toda la configuración está en `~/homelab/red/unbound/` (git) y se monta _read-only_. Restaurar Unbound = `git pull && docker compose up -d unbound`.

---

## Estructura del _stack_ `red` tras este documento

`~/homelab/red/` ya existe (`docs/03-red/02-pihole.md`). Se le añade el subdirectorio `unbound/`:

```
~/homelab/red/
├── docker-compose.yml             # ← se modifica (añade servicio 'unbound')
├── .env                           # ← se modifica (añade vars UNBOUND_*; sustituye PIHOLE_UPSTREAMS)
├── .env.example                   # ← se modifica (idem, sin valores reales)
├── etc-dnsmasq.d/
│   └── 02-homelab-local.conf      # ← se modifica (añade record unbound.lan)
└── unbound/                       # ← nuevo
    ├── unbound.conf
    ├── a-records.conf
    └── forward-records.conf
```

Crear el subdirectorio:

```bash
mkdir -p ~/homelab/red/unbound
chmod 0750 ~/homelab/red/unbound
```

> Permisos `0750`: igual criterio que `red/etc-dnsmasq.d/` — sólo el usuario `homelab` necesita leer/editar.

---

## Variables de entorno

Añadir al final de `~/homelab/red/.env.example` (versionado en git, sin valores reales):

```bash
# --- Unbound (docs/03-red/03-unbound.md) ----------------------------------
UNBOUND_IMAGE_TAG=1.22.0

# IP del propio Unbound en la red 'lan' macvlan. Debe coincidir con
# 'ipv4_address' del docker-compose.yml y con la reserva DHCP del router.
UNBOUND_LAN_IPV4=192.168.1.4

# Puerto de escucha de Unbound. Convención Pi-hole: 5335 (no 53).
UNBOUND_PORT=5335
```

Y **modificar** la variable `PIHOLE_UPSTREAMS` que `docs/03-red/02-pihole.md` dejó en `1.1.1.1;1.0.0.1`:

```bash
# Antes (durante el bootstrap de Pi-hole, sin Unbound):
# PIHOLE_UPSTREAMS=1.1.1.1;1.0.0.1

# Después (con Unbound operativo):
PIHOLE_UPSTREAMS=192.168.1.4#5335
```

> **Por qué un único _upstream_ y no `192.168.1.4#5335;1.1.1.1`**: misma lógica que en `docs/03-red/02-pihole.md` con el "secundario vacío" del DHCP — Pi-hole rotaría entre los dos _upstreams_ "por balanceo" y un porcentaje de las consultas saldría a Cloudflare, perdiendo la propiedad de "ningún tercero ve el grueso del tráfico" que justifica desplegar Unbound. Si Unbound cae, **toda la LAN se queda sin DNS** durante 30 s hasta que Uptime Kuma alerta; trade-off consciente, idéntico al de Pi-hole.

Replicar los cambios en `~/homelab/red/.env` (que **no** se _commitea_):

```bash
cd ~/homelab/red
# Editar .env a mano (no es buena idea regenerarlo desde .env.example y perder
# PIHOLE_WEB_PASSWORD).
$EDITOR .env
chmod 0600 .env
```

---

## Configuración: `unbound.conf`

`~/homelab/red/unbound/unbound.conf`:

```conf
# Unbound — resolver recursivo del homelab.
# Documentación: docs/03-red/03-unbound.md
# Esta configuración la consume mvance/unbound:1.22.0 montada read-only.

server:
    # Identidad y verbosidad
    verbosity: 1                   # 0 = silencio, 1 = errores+operación, 2 = consultas
    log-queries: no                # las consultas ya las registra Pi-hole
    log-replies: no
    log-servfail: yes              # los SERVFAIL sí — son señal de problema
    log-local-actions: no
    log-tag-queryreply: no

    # Interfaces
    # Escucha sobre TODAS las IPs del contenedor (la macvlan 192.168.1.4)
    # y sobre 127.0.0.1 (para healthcheck con drill).
    interface: 0.0.0.0@5335
    interface: 127.0.0.1@5335
    port: 5335

    # Quién puede consultar
    # 'refuse' por defecto, 'allow' explícito para la LAN.
    access-control: 127.0.0.0/8 allow
    access-control: 192.168.1.0/24 allow
    access-control: 0.0.0.0/0 refuse

    # IPv4 / IPv6
    do-ip4: yes
    do-ip6: no                     # el homelab no usa IPv6 (docs/03-red/01-macvlan.md)
    do-udp: yes
    do-tcp: yes
    prefer-ip6: no

    # Hardening / privacidad
    hide-identity: yes             # no responder a id.server / hostname.bind
    hide-version: yes              # no responder a version.server / version.bind
    qname-minimisation: yes        # RFC 7816 — no enviar el nombre completo a cada eslabón
    harden-glue: yes               # ignorar pegamento fuera de la zona delegada
    harden-dnssec-stripped: yes    # rechazar respuestas que parecen tener DNSSEC quitado
    harden-below-nxdomain: yes     # NXDOMAIN propaga a subdominios (RFC 8020)
    harden-referral-path: yes      # validar la cadena de delegación

    # DNSSEC
    module-config: "validator iterator"
    auto-trust-anchor-file: "/opt/unbound/etc/unbound/var/root.key"

    # Root hints (los gestiona la imagen vía cron interno; ruta estándar de mvance/unbound)
    root-hints: "/opt/unbound/etc/unbound/var/root.hints"

    # Caché
    msg-cache-size: 64m
    rrset-cache-size: 128m
    msg-cache-slabs: 4
    rrset-cache-slabs: 4
    infra-cache-slabs: 4
    key-cache-slabs: 4

    # TTL — defensa contra dominios con TTL absurdamente bajo y vs. autoritativos
    # que entregan TTLs eternos (los recortamos a 24h para forzar refresco).
    cache-min-ttl: 300
    cache-max-ttl: 86400
    cache-min-negative-ttl: 60
    cache-max-negative-ttl: 3600

    # Pre-fetch — refrescar entradas populares antes de que expiren (mejor UX)
    prefetch: yes
    prefetch-key: yes

    # Threads — la Pi 5 tiene 4 cores; reservar 2 para Unbound es generoso para uso doméstico
    num-threads: 2
    so-reuseport: yes

    # Privacidad — no caer en typo-squatting de respuestas falsas
    private-address: 10.0.0.0/8
    private-address: 172.16.0.0/12
    private-address: 192.168.0.0/16
    private-address: 169.254.0.0/16
    private-address: fd00::/8
    private-address: fe80::/10

    # Permitir respuestas con IPs privadas para la propia LAN (CNAME a 192.168.1.x
    # devuelto por un autoritativo bajo nuestro control). Sin esto, Unbound filtra
    # cualquier respuesta con IP privada como sospechosa de DNS rebinding.
    private-domain: "lan."

    # Zona local del homelab
    # Pi-hole resuelve *.lan vía 02-homelab-local.conf antes de llegar a Unbound,
    # pero si por error una consulta *.lan llega aquí, devolver NXDOMAIN inmediato
    # en lugar de mandarla a los root servers (que NO conocen el TLD .lan).
    local-zone: "lan." transparent

    # EDNS — tamaño de buffer
    edns-buffer-size: 1232         # recomendación DNS Flag Day 2020

    # Rate-limiting de respuestas a un mismo cliente (defensa anti-amplificación;
    # Unbound no está expuesto a internet pero el coste es nulo).
    ratelimit: 1000

    # Privilegios — la imagen mvance/unbound corre como _unbound:_unbound
    username: "_unbound"
    chroot: ""                     # imagen ya aislada por contenedor
    pidfile: "/opt/unbound/etc/unbound/unbound.pid"

    # Includes — se mantienen como ficheros separados para que un cambio
    # puntual (añadir un A record local) no toque este unbound.conf.
    include: "/opt/unbound/etc/unbound/a-records.conf"
    include: "/opt/unbound/etc/unbound/forward-records.conf"

remote-control:
    # unbound-control con socket UNIX dentro del contenedor (no se expone TCP)
    control-enable: yes
    control-interface: /opt/unbound/etc/unbound/var/unbound.ctl
    control-use-cert: no
```

`~/homelab/red/unbound/a-records.conf` (placeholder, vacío):

```conf
# A-records locales servidos por Unbound.
# Convención del homelab: los records *.lan los gestiona Pi-hole en
# red/etc-dnsmasq.d/02-homelab-local.conf, no aquí.
# Este fichero se mantiene vacío salvo para casos puntuales en los que
# Unbound deba responder por un nombre concreto sin pasar por Pi-hole
# (p. ej. monitorización de Pi-hole desde Prometheus).
#
# Formato:
# local-data: "nombre. IN A 192.168.1.X"
```

`~/homelab/red/unbound/forward-records.conf` (placeholder, vacío):

```conf
# Forwarders — VACÍO POR DISEÑO.
# Unbound del homelab es un resolver recursivo puro: consulta a los root
# servers, no a un upstream. Si en el futuro se quisiera redirigir un
# dominio concreto a un servidor distinto (p. ej. una zona corporativa
# vía VPN), se añadiría aquí:
#
# forward-zone:
#     name: "corp.example."
#     forward-addr: 10.0.0.53
#     forward-tls-upstream: yes
```

Permisos:

```bash
chmod 0644 ~/homelab/red/unbound/unbound.conf
chmod 0644 ~/homelab/red/unbound/a-records.conf
chmod 0644 ~/homelab/red/unbound/forward-records.conf
```

---

## Actualizar `etc-dnsmasq.d/02-homelab-local.conf`

`docs/03-red/02-pihole.md` dejó este fichero con un comentario `# - unbound.lan se rellenará en docs/03-red/03-unbound.md.`. Sustituirlo por el record real, justo después del de `pihole.lan`:

```diff
 # Excepciones — servicios cuyo backend no está detrás de Caddy:
 # - pihole.lan resuelve a la propia IP macvlan (UI directa por si Caddy
 #   está caído; cuando Caddy esté operativo, también responde por él).
 address=/pihole.lan/192.168.1.2
-# - unbound.lan se rellenará en docs/03-red/03-unbound.md.
+# - unbound.lan resuelve a la IP macvlan de Unbound. No tiene UI HTTP
+#   (Unbound no la trae); el record sirve para diagnóstico:
+#       dig @192.168.1.2 unbound.lan
+#       drill @unbound.lan -p 5335 cloudflare.com   (desde otra máquina LAN)
+address=/unbound.lan/192.168.1.4
```

Pi-hole recoge el cambio al recargar dnsmasq (ver sección **Despliegue**).

---

## Modificar `docker-compose.yml` del _stack_ `red`

Añadir el bloque `unbound:` dentro de `services:`, después del bloque `pihole:` que dejó `docs/03-red/02-pihole.md`:

```yaml
  # ---------------------------------------------------------------------------
  # Unbound — resolver DNS recursivo y validador DNSSEC.
  # Sólo lo consulta Pi-hole (192.168.1.2) por el puerto 5335. No tiene UI;
  # diagnóstico vía 'docker exec unbound unbound-control' o drill desde la LAN.
  # ---------------------------------------------------------------------------
  unbound:
    image: mvance/unbound:${UNBOUND_IMAGE_TAG}
    container_name: unbound
    hostname: unbound
    mac_address: "02:42:c0:a8:01:04"
    restart: unless-stopped
    # Sin cap_add: Unbound no necesita SYS_NICE ni NET_ADMIN; la imagen ya
    # baja privilegios a _unbound:_unbound al arrancar.
    environment:
      TZ: ${TZ}
    volumes:
      # Configuración versionable, read-only — la UI no existe y nada dentro
      # del contenedor debería reescribir estos ficheros.
      - ./unbound/unbound.conf:/opt/unbound/etc/unbound/unbound.conf:ro
      - ./unbound/a-records.conf:/opt/unbound/etc/unbound/a-records.conf:ro
      - ./unbound/forward-records.conf:/opt/unbound/etc/unbound/forward-records.conf:ro
    networks:
      lan:
        ipv4_address: ${UNBOUND_LAN_IPV4}
      # NO se conecta a 'homelab' (bridge): el único cliente legítimo
      # de Unbound es Pi-hole, que vive también en 'lan' macvlan y lo
      # alcanza por IP fija. Mantenerlo fuera del bridge reduce la
      # superficie expuesta accidentalmente a otros stacks.
    labels:
      homelab.stack: "red"
      homelab.backup: "false"     # config en git, sin estado persistente
      # Stateless + sin BD que migrar: Unbound entra en opt-in de Watchtower.
      com.centurylinklabs.watchtower.enable: "true"
    healthcheck:
      # Resolución recursiva real: si la cadena root → TLD → autoritativo
      # falla, drill devuelve no-answer y el healthcheck marca unhealthy.
      # Se elige cloudflare.com (autoritativo robusto, DNSSEC firmado).
      test: ["CMD-SHELL", "drill @127.0.0.1 -p ${UNBOUND_PORT} cloudflare.com | grep -q 'rcode: NOERROR' || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s
```

Notas de diseño:

- **`mac_address: "02:42:c0:a8:01:04"`**: imprescindible para que la reserva DHCP del router (`docs/03-red/01-macvlan.md`, paso 1) entregue siempre `192.168.1.4`.
- **`hostname: unbound`**: aparece en logs propios y en `/etc/hosts` interno apuntando a la `eth0` macvlan.
- **Sin `dns:` explícito**: Unbound **no necesita resolver nada por DNS** durante el _bootstrap_ (los _root hints_ son IPs literales). La heurística por defecto de Docker (que para macvlan usa `127.0.0.11` del DNS embedded) no le afecta.
- **Sin red `homelab`**: a diferencia de Pi-hole, Unbound **no** entra en el bridge interno. Pi-hole habla con él por la IP macvlan `192.168.1.4` directamente, dentro del mismo segmento. Esto deja Unbound oculto al resto de _stacks_ (Caddy, Authelia, Prometheus…) que viven en `homelab`. Si en el futuro Prometheus quisiera _scrape_ de métricas Unbound, se añade aquí la red `homelab` también.
- **`com.centurylinklabs.watchtower.enable: "true"`**: opt-in. Unbound es _stateless_ y sus _bumps_ entre _patch_ versions (1.22.0 → 1.22.1) son seguros. Entre _minor_ (1.22 → 1.23) Watchtower también lo cubre, pero conviene leer las _release notes_ por si hay un cambio de _config syntax_; si llegase, se desactiva el _opt-in_ ese día.
- **Healthcheck con `drill`**: la imagen `mvance/unbound` trae `drill` (de `ldns`). El test consulta `cloudflare.com` que está **DNSSEC-firmado**, así que si la validación falla, el healthcheck también — buen indicador de que la cadena entera está sana.
- **No hay `ports:`**: macvlan no necesita publicación de puertos. Unbound es accesible directamente sobre `192.168.1.4:5335` desde cualquier dispositivo de la LAN (con `access-control` filtrando en el propio Unbound a la subred `192.168.1.0/24`).

---

## Despliegue

```bash
cd ~/homelab/red
docker compose --env-file ../.env --env-file .env config | grep -A30 'unbound:' | head -40   # validar sintaxis
docker compose --env-file ../.env --env-file .env up -d unbound
```

O, equivalente, con el _Makefile_:

```bash
cd ~/homelab
make up STACK=red
```

> `make up STACK=red` levantará Pi-hole (ya en marcha, _no-op_) y Unbound (nuevo). El `up -d` de Compose es idempotente sobre servicios que no han cambiado.

Verificar:

```bash
docker compose -f ~/homelab/red/docker-compose.yml ps
# NAME      STATUS                   PORTS
# pihole    Up X minutes (healthy)   53/tcp, 53/udp, 67/udp, 80/tcp
# unbound   Up X seconds (healthy)   5335/tcp, 5335/udp
```

> El `(healthy)` de Unbound tarda ~30 s desde el arranque (el `start_period: 30s` da margen para que descargue/lea `root.hints` la primera vez).

Probar resolución recursiva desde la propia Pi (la ruta del _shim_, ver `docs/03-red/01-macvlan.md`, permite el tráfico):

```bash
dig @192.168.1.4 -p 5335 cloudflare.com +short
# debe responder con IPs reales de Cloudflare
dig @192.168.1.4 -p 5335 dnssec-failed.org +short
# debe NO responder (SERVFAIL) — el dominio está intencionadamente roto en DNSSEC,
# y un validador correcto lo rechaza.
dig @192.168.1.4 -p 5335 dnssec-failed.org +short +cd
# con +cd (checking-disabled) sí debe responder — confirma que el SERVFAIL anterior
# era cosa de la validación, no de un problema de conectividad.
```

---

## Cambiar el _upstream_ de Pi-hole a Unbound

`docs/03-red/02-pihole.md` advirtió que `PIHOLE_DNS_` sólo se aplica en el primer arranque de Pi-hole; tras eso, manda lo que diga `setupVars.conf`. Por tanto, cambiar la variable en `red/.env` **no es suficiente** — Pi-hole ya tiene `1.1.1.1;1.0.0.1` cacheado.

Dos opciones:

### Opción A — vía UI (recomendada para uso normal)

1. Abrir `http://192.168.1.2/admin/` (o `https://pihole.lan/` si Caddy ya está, en `docs/03-red/04-caddy.md`).
2. **Settings → DNS → Upstream DNS Servers**.
3. **Desmarcar** Cloudflare (`1.1.1.1`, `1.0.0.1`) y cualquier otro _upstream_ público.
4. En **Custom 1 (IPv4)**, escribir: `192.168.1.4#5335`.
5. Marcar la casilla **Custom 1**.
6. **Save**. Pi-hole recarga `dnsmasq` y empieza a usar Unbound inmediatamente.

### Opción B — vía CLI (idempotente, _scriptable_)

```bash
docker exec pihole pihole -a -d "192.168.1.4#5335"  # set custom upstream
# El comando deja setupVars.conf con PIHOLE_DNS_1=192.168.1.4#5335 y borra cualquier otro PIHOLE_DNS_N.
docker exec pihole pihole restartdns reload
```

Y en cualquiera de los dos casos, **además**, recargar dnsmasq de Pi-hole para que coja el nuevo `02-homelab-local.conf` con `unbound.lan`:

```bash
docker exec pihole pihole restartdns reload
```

Verificar que Pi-hole ahora pregunta a Unbound:

```bash
# 1) En una terminal, mirar el log de queries de Unbound (verbosity=1 no las loguea
#    por defecto; subir temporalmente con unbound-control):
docker exec unbound unbound-control verbosity 2
docker logs -f unbound &
LOGS=$!

# 2) En otra, hacer una consulta a Pi-hole por un dominio "fresco":
dig @192.168.1.2 example-test-$(date +%s).com +short

# 3) En el log de Unbound debe aparecer una línea con el dominio consultado.
kill $LOGS
docker exec unbound unbound-control verbosity 1
```

Y desde la UI de Pi-hole: **Settings → DNS** debe listar `192.168.1.4#5335` como único custom y nada más; **Tools → Query Log** debe mostrar consultas con _Forwarded to_ → `192.168.1.4#5335`.

---

## Verificación final

Antes de pasar a `docs/03-red/04-caddy.md`, comprobar:

- [ ] `docker compose -f ~/homelab/red/docker-compose.yml ps` muestra `unbound` en estado `Up` y `(healthy)` tras ~60 s.
- [ ] `dig @192.168.1.4 -p 5335 cloudflare.com +short` responde con IPs reales en menos de 500 ms (primer hit recursivo) y en menos de 5 ms en consultas siguientes (cache hit).
- [ ] `dig @192.168.1.4 -p 5335 dnssec-failed.org +short` **no** responde (devuelve SERVFAIL): la validación DNSSEC funciona.
- [ ] `dig @192.168.1.4 -p 5335 dnssec-failed.org +short +cd` sí responde: confirma que el SERVFAIL era validación, no conectividad.
- [ ] `dig @192.168.1.4 -p 5335 . NS +short | head` lista los _root servers_ (`a.root-servers.net.` … `m.root-servers.net.`): `root.hints` está cargado.
- [ ] `dig @192.168.1.4 -p 5335 anything.lan +short` devuelve respuesta vacía con _NXDOMAIN_ (la `local-zone: "lan." transparent` actuó): no se filtran nombres internos a los _root servers_.
- [ ] `dig @192.168.1.4 -p 5335 id.server CHAOS TXT +short` devuelve vacío (`hide-identity: yes` aplicó).
- [ ] `dig @192.168.1.2 unbound.lan +short` responde con `192.168.1.4` (el record nuevo de `02-homelab-local.conf` está en vigor).
- [ ] La UI de Pi-hole (`http://192.168.1.2/admin/`, **Settings → DNS**) muestra `192.168.1.4#5335` como único _Custom upstream_; Cloudflare desmarcado.
- [ ] **Tools → Query Log** de Pi-hole muestra entradas con _Status_ `OK (forwarded)` y _Reply_ con el TTL recibido de Unbound.
- [ ] `docker exec unbound unbound-control stats_noreset | grep -E '^(total\.num\.queries|total\.num\.cachehits|num\.query\.dnscrypt)'` muestra contadores creciendo a medida que la LAN consulta.
- [ ] El contenedor sobrevive un `sudo reboot` de la Pi: `restart: unless-stopped` lo levanta tras el _macvlan-shim_ y la red `lan`. Pi-hole sigue resolviendo sin intervención manual.
- [ ] **Falla controlado**: `docker compose -f ~/homelab/red/docker-compose.yml stop unbound` y, en otra terminal, `dig @192.168.1.2 google.com +time=5 +tries=1` debe fallar con _timeout_ tras 5 s (Pi-hole sin _upstream_); `docker compose -f ~/homelab/red/docker-compose.yml start unbound` y reintentar — debe volver a responder. Confirma que la cadena Pi-hole → Unbound es la única ruta y que no hay _fallback_ silencioso a Cloudflare.
- [ ] `git -C ~/homelab status` muestra como **modificados**: `red/docker-compose.yml`, `red/.env.example`, `red/etc-dnsmasq.d/02-homelab-local.conf`. Y como **nuevos**: `red/unbound/unbound.conf`, `red/unbound/a-records.conf`, `red/unbound/forward-records.conf`. **No** muestra `red/.env`. _Commit_:

  ```bash
  cd ~/homelab
  git add red/docker-compose.yml red/.env.example \
          red/etc-dnsmasq.d/02-homelab-local.conf \
          red/unbound/
  git commit -m "feat(red): add Unbound recursive resolver as Pi-hole upstream"
  ```

---

## Backup

Unbound es _stateless_: la única información persistente es la **configuración**, que vive en git (`~/homelab/red/unbound/`). Por tanto:

- **No se añade nada al perfil de Borgmatic** para Unbound. La etiqueta `homelab.backup: "false"` del compose lo refleja explícitamente.
- **El `gitignore` del repo** (definido en `docs/02-docker/02-estructura-compose.md`) ya cubre los `.env`. El resto del directorio `red/unbound/` se _commitea_ tal cual.
- **Restauración**: clonar el repo en un OS recién instalado, `cp red/.env.example red/.env`, rellenar la _password_ de Pi-hole desde Vaultwarden, `make up STACK=red`. Unbound arranca sin caché (la pierde) y la rellena en minutos durante el uso normal.

> **Si en algún momento se decidiese persistir la caché** (no es habitual; Unbound prefiere caché caliente en RAM), se añadiría un `volume:` con `/opt/unbound/etc/unbound/var/` _bind-mounteado_ a `/mnt/hd2t/services/unbound/var/` y se incluiría en Borgmatic. Por ahora **no**.

---

## Troubleshooting

### `docker compose up unbound` falla con `network lan declared as external, but could not be found`

`docs/03-red/01-macvlan.md` no se completó o la red `lan` se borró. Recrearla con el comando del paso 2 de aquel doc.

### El contenedor arranca pero `dig @192.168.1.4 -p 5335 cloudflare.com` da _timeout_

Posibles causas:

1. **Reserva DHCP sin aplicar**: el router asignó `192.168.1.4` a otro dispositivo. Verificar:

   ```bash
   arping -c 2 -I eth0 192.168.1.4
   docker inspect unbound --format '{{(index .NetworkSettings.Networks "lan").IPAddress}}'
   ```

   Ambos deben coincidir y la primera tiene que responder con la MAC `02:42:c0:a8:01:04`.

2. **Unbound no escucha en la IP correcta**: la `interface: 0.0.0.0@5335` debe cubrir todas las interfaces. Comprobar dentro del contenedor:

   ```bash
   docker exec unbound netstat -tulpn | grep 5335
   # debe listar 0.0.0.0:5335 (UDP y TCP)
   ```

3. **`access-control` mal**: si la subred LAN no es `192.168.1.0/24`, las consultas de la propia Pi (que llegan desde `192.168.1.250` del _shim_) las rechaza Unbound. Comprobar:

   ```bash
   docker logs unbound | grep -i 'refused query'
   ```

   Si aparecen, ajustar `access-control:` en `unbound.conf` y `docker compose restart unbound`.

### `dig @192.168.1.4 -p 5335 dnssec-failed.org` **sí** responde (debería fallar)

DNSSEC no está validando. Causas:

1. **`module-config` mal**: debe ser **exactamente** `"validator iterator"`, en ese orden y entre comillas. Si dice `"iterator"` solo, no valida.
2. **`auto-trust-anchor-file` apuntando a una ruta inexistente**: la imagen `mvance/unbound` la genera la primera vez en `/opt/unbound/etc/unbound/var/root.key`. Comprobar:

   ```bash
   docker exec unbound ls -la /opt/unbound/etc/unbound/var/root.key
   docker exec unbound cat /opt/unbound/etc/unbound/var/root.key | head -3
   ```

   Debe existir y empezar por `; autotrust trust anchor file`.

3. **El reloj del host está desfasado**: DNSSEC valida firmas con _timestamps_; un reloj mal sincronizado (>1 día de _drift_) hace que toda firma parezca expirada. `timedatectl status` debe reportar `System clock synchronized: yes`.

### `dig @192.168.1.2 google.com` da _timeout_ tras configurar Unbound como _upstream_ de Pi-hole

Pi-hole no está pudiendo hablar con Unbound. Causas:

1. **El _custom upstream_ no se aplicó**: `docker exec pihole grep PIHOLE_DNS /etc/pihole/setupVars.conf`. Debe listar `PIHOLE_DNS_1=192.168.1.4#5335` y **nada más** (`PIHOLE_DNS_2`, `PIHOLE_DNS_3`… ausentes o vacías).
2. **Unbound no acepta a Pi-hole**: Pi-hole consulta a Unbound desde `192.168.1.2` (su IP macvlan). Comprobar `access-control:` en `unbound.conf` — la subred `192.168.1.0/24` debe estar `allow`. Comprobar también:

   ```bash
   docker logs unbound | tail -50 | grep refused
   ```

3. **Latencia excesiva**: Pi-hole tiene un _timeout_ por defecto de 5 s. Si Unbound tarda más en arrancar la primera consulta recursiva (raro, suele ser <500 ms), reintentar tras unos segundos.

### Unbound consume mucha memoria (>500 MB)

La caché lleva tiempo creciendo. Ajustar a la baja:

```conf
# En unbound.conf:
msg-cache-size: 32m         # de 64m a 32m
rrset-cache-size: 64m       # de 128m a 64m
```

Recargar:

```bash
docker exec unbound unbound-control reload
```

> **Mejor revisar antes**: una caché de 200 MB en una Pi 5 con 8 GB es perfectamente sana. Unbound prefiere RAM a CPU/disco. Sólo recortar si hay competencia real con otros servicios (Stash, Jellyfin transcodificando, …).

### `unbound-control: error: connect: Connection refused`

`remote-control` no está habilitado o el socket no se ve. La config usa socket UNIX dentro del contenedor:

```bash
docker exec unbound unbound-control -c /opt/unbound/etc/unbound/unbound.conf status
```

Si falla, revisar la sección `remote-control:` del `unbound.conf` y reiniciar el contenedor.

### Tras un `sudo reboot`, Pi-hole arranca antes que Unbound y la LAN tarda en resolver

Misma causa que el _gap_ de Pi-hole respecto al _shim_ (`docs/03-red/02-pihole.md`, sección **Troubleshooting**). El orden de arranque de Compose en `restart: unless-stopped` no es determinista entre _stacks_ ni dentro del mismo _stack_. Si esto se vuelve molesto:

1. Definir `depends_on: [unbound]` en el bloque `pihole:` del compose. Esto sólo influye en el `docker compose up`, **no** en el _restart_ del _daemon_ de Docker tras un _reboot_.
2. Para el _reboot_, añadir un `After=` cruzado entre los servicios systemd que Docker genera. Es un _hack_ documentado en el _troubleshooting_ de Pi-hole; se aplica el mismo patrón aquí.

En la práctica, el _gap_ es de 2-5 segundos y se nota sólo si un cliente DNS pregunta justo durante esa ventana. La Pi (con su `ipv4.dns "192.168.1.2 192.168.1.1 1.1.1.1"`, `docs/03-red/02-pihole.md`) tiene _fallback_; el resto de la LAN, no — pero se recupera tan pronto como Pi-hole responde.

### Cómo medir el _hit ratio_ de la caché

```bash
docker exec unbound unbound-control stats_noreset | grep -E 'total\.num\.(queries|cachehits)'
# total.num.queries=12345
# total.num.cachehits=10234   → ratio 82.9%
```

Por debajo del 70 % tras 24 h de uso normal, hay algo raro: revisar `cache-min-ttl` (no debe estar en 0), TTLs que el autoritativo manda y el tamaño de caché.

### `verbosity: 2` ahoga la Pi de logs

Cambiarlo de vuelta sin reiniciar:

```bash
docker exec unbound unbound-control verbosity 1
```

(Sí cambia `unbound.conf` en disco para próximos reinicios — eso requiere editar el fichero y `docker compose restart unbound`.)

---

## Referencias

- Unbound — Documentación oficial: <https://nlnetlabs.nl/documentation/unbound/>
- Unbound — `unbound.conf(5)` man page: <https://nlnetlabs.nl/documentation/unbound/unbound.conf/>
- Pi-hole — Guía oficial Pi-hole + Unbound: <https://docs.pi-hole.net/guides/dns/unbound/>
- mvance/unbound — Imagen Docker: <https://hub.docker.com/r/mvance/unbound>
- mvance/unbound — Repo y _release notes_: <https://github.com/MatthewVance/unbound-docker>
- RFC 7816 — DNS Query Name Minimisation: <https://datatracker.ietf.org/doc/html/rfc7816>
- DNS Flag Day 2020 (EDNS buffer 1232): <https://dnsflagday.net/2020/>
