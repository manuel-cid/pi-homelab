# Unbound

## Descripción

Despliegue de **Unbound 1.21** como **resolver DNS recursivo y validador DNSSEC** del homelab, integrado como **único upstream** de Pi-hole ([`02-pihole.md`](./02-pihole.md)). Cuando Pi-hole no encuentra un dominio en su caché ni en sus listas locales, no consulta a `1.1.1.1` o `9.9.9.9`: pregunta a Unbound, que **resuelve por sí mismo** desde los servidores raíz (`a.root-servers.net`, `b.root-servers.net`...) hasta el TLD y, finalmente, el servidor autoritativo del dominio. Resultado: el homelab no depende de un proveedor concreto para sus consultas DNS, valida DNSSEC y mantiene una caché propia.

Unbound se añade al stack `dns` ya creado en [`02-pihole.md`](./02-pihole.md) (no es un stack nuevo: ambos servicios comparten lifecycle y `docker-compose.yml`). Vive simultáneamente en dos redes:

1. **`lan_macvlan`** — con la IP estática **`192.168.1.242`** reservada en [`01-macvlan.md`](./01-macvlan.md) §2. Esta es la dirección que Pi-hole usa como upstream (`PIHOLE_UPSTREAMS=192.168.1.242#5335`, fila §6.3 de [`02-pihole.md`](./02-pihole.md)). Tener IP propia en la LAN evita que Unbound dependa del Docker DNS embebido (chicken-and-egg: Pi-hole querría resolver `unbound` por nombre, pero el resolver de Pi-hole **es** Unbound).
2. **`dns_internal`** — la red bridge privada del stack `dns` que [`02-pihole.md`](./02-pihole.md) §4 ya declara. Permite a Pi-hole alcanzar a Unbound como `unbound:5335` sin atravesar la macvlan, lo cual es útil para los healthchecks internos y para el día en que se añada un `unbound-exporter` en la red `homelab`.

Por qué esta arquitectura, no otra:

1. **Resolver recursivo, no forwarder.** Un *forwarder* (Pi-hole apuntando a `1.1.1.1` directamente) entrega el control del DNS a un tercero: Cloudflare ve cada dominio que cualquier dispositivo de la LAN consulta. Unbound recursivo elimina ese intermediario: las consultas salen **directamente** a los autoritativos de cada dominio (Google va a `ns1.google.com`, GitHub a `ns-1283.awsdns-32.org`...), distribuyendo el "rastro" entre cientos de operadores en lugar de concentrarlo en uno.
2. **DNSSEC validation.** Unbound valida la cadena DNSSEC desde la raíz hasta cada respuesta: si un MITM intentase devolver una IP falsa para `bank.example.com`, Unbound rechazaría la respuesta. Pi-hole **no** valida DNSSEC por sí mismo (FTL solo lo *re-emite* a clientes); apoyándose en Unbound, toda la LAN obtiene validación DNSSEC end-to-end.
3. **Caché en RAM, persistencia en disco.** Unbound mantiene su caché en RAM (rápida, sin escrituras a SD/USB) y la *vuelca* a disco al apagar (`unbound-control dump_cache`). En un homelab que reinicia rara vez, esto significa que tras unas horas la caché responde a >70 % de consultas en <1 ms, descargando consultas reales a internet a un goteo.
4. **Privacidad reforzada (`qname-minimisation`).** Unbound implementa **QNAME minimisation** (RFC 9156): al consultar `mail.bank.example.com`, no envía la consulta entera al servidor de la raíz, sino solo `com`; al servidor `.com` solo `example.com`; etc. Cada autoritativo recibe **solo la información que necesita**. Cloudflare y Google también lo hacen, pero con Unbound recursivo lo controlas tú.
5. **Defensa en profundidad para la LAN.** Aunque Unbound vive en `lan_macvlan` (alcanzable por toda la LAN en `192.168.1.242:5335`), su `access-control` solo permite consultas desde la IP de Pi-hole (`192.168.1.241`) y desde la `lan-shim` del host (`192.168.1.240`). Cualquier otro cliente recibe `REFUSED`. El uso del puerto **5335** (no estándar) reduce además la probabilidad de descubrimiento accidental.
6. **Sin Watchtower.** Unbound es la dependencia upstream de Pi-hole. Si se actualiza a las 04:00 con un cambio incompatible y Pi-hole pierde upstream, **toda la LAN pierde resolución externa**. Documentado en [`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §6 línea 449.

> **Alcance**: este documento añade Unbound al stack `dns` (no toca `01-macvlan.md` ni recrea Pi-hole), persiste su configuración en `hd2t` y reconfigura Pi-hole para usarlo como upstream. **No** despliega ningún exporter ni dashboard de Grafana: eso entra en [`../05-monitorizacion/`](../05-monitorizacion/).

---

## Requisitos Previos

- **Pi-hole desplegado y operativo** según [`02-pihole.md`](./02-pihole.md), con `PIHOLE_UPSTREAMS=1.1.1.1;9.9.9.9` (modo bootstrap). Este doc cambiará el upstream a Unbound al final.
- **Stack `dns` existente** en `~/homelab/stacks/dns/` con `docker-compose.yml` y `.env` (real en `/mnt/hd2t/services/dns/.env`, plantilla en `~/homelab/stacks/dns/.env.example`). Este doc **modifica** ambos ficheros.
- **Red `dns_internal`** creada por el stack `dns` en su primer `up -d` (Compose la trae automáticamente al haberla declarado en [`02-pihole.md`](./02-pihole.md) §4).
- **Red `lan_macvlan`** activa con el rango `192.168.1.240/28`, MAC del host (`lan-shim`) en `192.168.1.240` y Pi-hole consumiendo `192.168.1.241` ([`01-macvlan.md`](./01-macvlan.md) §4 y §5).
- **IP `192.168.1.242` libre** (no asignada por DHCP del router ni a otro contenedor). Comprobar:
  ```bash
  arp -a 192.168.1.242 2>/dev/null
  docker network inspect lan_macvlan --format '{{range .Containers}}{{.IPv4Address}} {{.Name}}{{println}}{{end}}'
  ```
  Ambos comandos deben **no** mostrar `192.168.1.242`.
- **Salida a internet desde la Pi en UDP/53 y TCP/53** hacia el mundo exterior (los servidores raíz responden por ambos). `ufw` con la política por defecto `allow outgoing` ya lo permite ([`../01-sistema/03-seguridad-base.md`](../01-sistema/03-seguridad-base.md)).
- **`dig`, `delv` y `unbound-host`** (opcionales, para verificación) en el host: `sudo apt install -y dnsutils`. `delv` viene en `bind9-dnsutils`.

### Decisiones de diseño asumidas

| Decisión | Valor por defecto | Justificación |
|---|---|---|
| Imagen Docker | **`mvance/unbound:1.21.0`** | Imagen multi-arch (incluye `linux/arm64/v8`) mantenida activamente. Es el estándar *de facto* del ecosistema Pi-hole + Unbound homelab desde hace años. La basada en Alpine de `klutchell/unbound` también es válida; se elige `mvance` por documentación más extensa y mejor compatibilidad con `unbound-control`. |
| Tag de imagen | **Pinned a la release**, nunca `latest` | Misma regla que Pi-hole y que [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §6.1: tag fijo y upgrade manual decidido por el operador. |
| Política de Watchtower | **`watchtower.enable: "false"`** | Unbound es upstream crítico de Pi-hole. Un upgrade silencioso a las 04:00 puede dejar la LAN sin DNS externo. Documentado en [`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §6 línea 449. |
| Modo de red | **`lan_macvlan` + `dns_internal`** (dos `networks`) | `lan_macvlan` para que Pi-hole le hable por IP estable (`192.168.1.242#5335`); `dns_internal` para resolución por nombre (`unbound:5335`) y para que se mantenga aislada del resto de stacks. **No** se añade a `homelab`: nada fuera del stack `dns` debería consultar Unbound directamente. Cuando llegue [`../05-monitorizacion/`](../05-monitorizacion/) y se quiera un `unbound-exporter`, se planteará añadir `homelab` como tercera red. |
| IP en `lan_macvlan` | **`192.168.1.242`** (estática vía `ipv4_address`) | Reserva del plan de IPs en [`01-macvlan.md`](./01-macvlan.md) §2 y referencia explícita de [`02-pihole.md`](./02-pihole.md) §6.3. |
| MAC en `lan_macvlan` | **`02:42:c0:a8:01:f2`** (estática vía `mac_address`) | Mismo esquema que Pi-hole: prefijo `02:42:` (locally administered, rango Docker estándar) + sufijo `c0:a8:01:f2` que codifica `192.168.1.242` (`0xc0a801f2`). Autodescriptivo, único, estable a través de recreaciones. |
| Puerto de escucha | **`5335`** (no privilegiado, no estándar DNS) | Pi-hole ya está pre-configurado con `192.168.1.242#5335` ([`02-pihole.md`](./02-pihole.md) §6.3). Usar el puerto `53` chocaría visualmente con Pi-hole y abriría más superficie a clientes accidentales de la LAN. `5335` es **convención del ecosistema Pi-hole + Unbound** desde la guía oficial de Pi-hole y elimina cualquier confusión sobre quién es el "DNS público" de la LAN. |
| `ports:` publicados al host | **Ninguno** | El contenedor tiene IP propia en `lan_macvlan`. Publicar puertos los expondría también en `192.168.1.10` (la IP de la Pi), filtrando Unbound al stack `homelab` cuando no debe consultarlo. |
| `access-control` | **Solo `192.168.1.241/32` (Pi-hole) y `192.168.1.240/32` (`lan-shim`) `allow`; el resto `refuse`** | Defensa en profundidad: aunque Unbound vive en la LAN con IP propia, **solo** Pi-hole y el host (para diagnóstico) pueden consultarle. Otros equipos de la LAN recibirán `REFUSED`. Un atacante que comprometa una smart-TV no puede usar Unbound como amplificador de DNS. |
| `interface` | **`0.0.0.0`** (con `port: 5335`) | Unbound enlaza en todas las interfaces del contenedor (`lan_macvlan` y `dns_internal`). Restringir a una sola IP exigiría conocer la IP que `dns_internal` asigna en cada `up`, que es dinámica (subred autoasignada por Docker, ver [`02-pihole.md`](./02-pihole.md) §4). |
| DNSSEC | **`auto-trust-anchor-file: /opt/unbound/etc/unbound/root.key`** | El *root trust anchor* (la firma de la raíz DNS) se actualiza automáticamente con el procedimiento RFC 5011. Persistido en `hd2t` para que sobreviva a `docker compose down`. |
| Root hints | **Embebidos en el conf, no fichero externo** | Unbound trae los root servers compilados en el binario; el fichero `root.hints` solo se necesita en escenarios *air-gapped* o de cumplimiento. En un homelab doméstico con salida a internet, omitirlo simplifica la operación. |
| QNAME minimisation | **`qname-minimisation: yes`** | Privacidad por diseño (RFC 9156). Coste despreciable; algunos servidores autoritativos mal configurados lo rechazan, en cuyo caso la opción `qname-minimisation-strict: no` (default) hace fallback automático. |
| Caché | **`msg-cache-size: 64m`, `rrset-cache-size: 128m`** | La Pi 5 tiene 8 GB; reservar ~200 MB para caché DNS es trivial y reduce consultas externas drásticamente. La regla "RRset = 2× msg-cache" es la recomendación oficial del manual de Unbound. |
| Prefetch | **`prefetch: yes`, `prefetch-key: yes`** | Unbound revalida entradas populares **antes** de que expiren. Coste: ~5 % más consultas externas; beneficio: respuestas siempre cacheadas para los dominios más usados. |
| Hardening | **`harden-glue: yes`, `harden-dnssec-stripped: yes`, `harden-below-nxdomain: yes`, `harden-referral-path: yes`, `harden-algo-downgrade: yes`** | Conjunto recomendado por el [DNS Privacy Project](https://dnsprivacy.org/wiki/) para resolvers recursivos. Sin coste en escenarios bien configurados. |
| Anti DNS rebinding | **`private-address` para todos los rangos RFC1918, RFC4193, RFC3927** + `192.168.1.0/24` excluido como `private-domain` interno | Un autoritativo malicioso no puede devolver `10.0.0.x` o `192.168.x.x` para un dominio público (ataque de DNS rebinding). Las direcciones internas se sirven exclusivamente desde el `local-data` de Pi-hole (no desde Unbound). |
| Edns Client Subnet | **`hide-identity: yes`, `hide-version: yes`** + ECS no enviado | No se envía la subred del cliente al autoritativo (privacidad), y la versión de Unbound no se filtra en `version.bind`. |
| Logging | **`verbosity: 1`, `log-queries: no`, `use-syslog: no`** | Suficiente para diagnóstico (errores, validación DNSSEC fallida). Las queries individuales **ya** las registra Pi-hole en `pihole-FTL.log`; loguearlas también en Unbound es ruidoso y consume `hd2t`. |
| Persistencia | **Bind mount `/opt/unbound/etc/unbound/`** ← `/mnt/hd2t/services/dns/unbound/etc-unbound/` | Contiene `unbound.conf`, `root.key` (que se reescribe vía RFC 5011) y los certificados de `unbound-control` (regenerables). |
| Usuario del contenedor | **`_unbound` (default de la imagen)** | La imagen `mvance/unbound` arranca como root, hace `setcap` a `unbound`, dropa al usuario `_unbound` y bindea el puerto. **No** se sobreescribe `user:` en Compose: rompería el entrypoint. |
| `cap_drop: ALL` + `cap_add` mínimo | `SETUID`, `SETGID`, `CHOWN`, `DAC_OVERRIDE`, `NET_BIND_SERVICE` | `SETUID/SETGID/DAC_OVERRIDE` para el drop a `_unbound`; `CHOWN` para `chown` inicial de `/opt/unbound/etc/unbound/root.key` cuando se crea por primera vez; `NET_BIND_SERVICE` por simetría con Pi-hole (5335 no es privilegiado, pero la imagen lo usa para preparar el bind). **No** se añade `NET_RAW` (Unbound no hace ICMP) ni `SYS_NICE` (no ajusta prioridad). |
| `security_opt` | **`no-new-privileges:true`** | Plantilla §6 de [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md). Compatible con `cap_add` enumerado y con el drop de privilegios interno. |
| `read_only` | **`false`** | Unbound escribe en `/opt/unbound/etc/unbound/root.key` (RFC 5011) y en `/var/lib/unbound/` si se usa caché persistente. Hacerlo `read_only` exigiría tres `tmpfs` y un `volume` adicional, sin beneficio relevante para el modelo de amenaza. |
| Healthcheck | **Consulta DNS recursiva a `dnssec.works`** vía `drill -p 5335 @127.0.0.1 dnssec.works` (o `dig` si la imagen no trae `drill`) | Verifica que el resolver responde **y** que DNSSEC funciona: `dnssec.works` es un dominio firmado correctamente, `dnssec-failed.org` es un señuelo que **debe** fallar. La imagen `mvance/unbound` incluye `drill` en su `/opt/unbound/sbin/`. |
| Logs | Defaults del demonio (`json-file`, 10 MB × 3 desde [`../02-docker/01-instalacion-docker.md`](../02-docker/01-instalacion-docker.md)) | Con `verbosity: 1`, los logs son escasos. El daemon-defaults sobra. |

---

## 1. Resumen de la arquitectura

```
   ┌─────────── Stack `dns` (docker-compose.yml ampliado) ─────────────┐
   │                                                                   │
   │  ┌─────── pihole ────────┐        ┌─────── unbound ────────┐      │
   │  │ networks:             │        │ networks:              │      │
   │  │   lan_macvlan         │  ─┐    │   lan_macvlan          │      │
   │  │     192.168.1.241     │   │    │     192.168.1.242      │      │
   │  │   homelab             │   │    │   dns_internal         │      │
   │  │   dns_internal        │   ▼    │     10.x.x.y           │      │
   │  │                       │  upstream                       │      │
   │  │ FTLCONF_dns_upstreams │  ───►  192.168.1.242#5335        │      │
   │  │ = 192.168.1.242#5335  │   o    unbound:5335 (alt.)      │      │
   │  └───────────────────────┘  ──┘   └─────────────────────────┘     │
   │                                                                   │
   │  La LAN solo habla con pihole (192.168.1.241).                    │
   │  Unbound (192.168.1.242) responde solo a pihole y al host.        │
   └───────────────────────────────────────────────────────────────────┘
                                            │
                                            │ raíces DNS (UDP/TCP 53)
                                            ▼
                  ┌──────────────────────────────────────┐
                  │  internet pública                    │
                  │   ├─ a.root-servers.net …            │
                  │   ├─ ns-tld.iana.org …               │
                  │   └─ autoritativos por dominio       │
                  └──────────────────────────────────────┘
```

Tres invariantes:

- **Solo Pi-hole** consulta a Unbound. Otros clientes de la LAN reciben `REFUSED` por `access-control`.
- Unbound **no usa forwarders**: resuelve recursivamente desde la raíz. La salida UDP/53 y TCP/53 al exterior es imprescindible.
- **Sin Watchtower**, sin `latest`. Upgrade manual leyendo `CHANGES.txt` de Unbound.

---

## 2. Plan de variables y archivos

El stack `dns` ya tiene un `.env` (creado en [`02-pihole.md`](./02-pihole.md) §3.2). Este doc **añade** una clave nueva y mantiene el resto. La configuración de Unbound (mucho más extensa que un puñado de variables de entorno) vive en un fichero **`unbound.conf`** versionado en el directorio del stack y montado dentro del contenedor.

### 2.1. Ampliación del `.env.example` (versionado)

Añadir al final de `~/homelab/stacks/dns/.env.example`:

```dotenv
# --- Unbound ---
# Versión de la imagen Docker. Buscar releases en https://hub.docker.com/r/mvance/unbound/tags
UNBOUND_IMAGE_TAG=1.21.0
```

> No se añaden secretos: Unbound no tiene contraseña de admin ni API que requiera credenciales (la `unbound-control` interna usa certificados autoinicializados). Si en el futuro se expone su métrica via `unbound_exporter`, ese sí podrá necesitar un token y entrará al `.env`.

### 2.2. Ampliación del `.env` real (`/mnt/hd2t/services/dns/.env`)

```bash
# Añadir la nueva variable manteniendo las existentes.
sudo -u homelab tee -a /mnt/hd2t/services/dns/.env > /dev/null <<'EOF'
UNBOUND_IMAGE_TAG=1.21.0
EOF
```

> Se usa `sudo -u homelab tee -a` para mantener el fichero como `homelab:homelab` `0600` (regla §3.2 de [`02-pihole.md`](./02-pihole.md): el `.env` real lo posee `homelab`, no `root`). Si el `.env` se reescribe entero, repetir la receta de `install -m 600` y volcar todas las variables, no solo la nueva.

### 2.3. Fichero de configuración versionable

`unbound.conf` se versiona en el repo de stacks (igual que cualquier otro fichero de configuración: `Caddyfile`, `prometheus.yml`...), junto al `docker-compose.yml`:

```
~/homelab/stacks/dns/
├── docker-compose.yml
├── .env.example
└── unbound/
    └── unbound.conf
```

Y al levantarlo, Compose lo monta dentro del contenedor sobre `/opt/unbound/etc/unbound/unbound.conf`.

---

## 3. Preparar el árbol de datos

### 3.1. Directorio versionable del stack

```bash
mkdir -p ~/homelab/stacks/dns/unbound
```

### 3.2. Directorio persistente en `hd2t`

```bash
sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/services/dns/unbound
sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/services/dns/unbound/etc-unbound
```

> **Migración desde el esquema antiguo `/mnt/hd2t/services/unbound/`**: si el script de [`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) §5 creó el directorio `/mnt/hd2t/services/unbound/` (esquema "un dir por servicio" antes de fijar la convención por stack):
> ```bash
> sudo rmdir /mnt/hd2t/services/unbound 2>/dev/null || true
> ```
> No debería existir `etc-unbound/` con datos previos: Unbound es un servicio sin estado relevante (caché en RAM, `root.key` autoreinicializable). En caso de tenerlo:
> ```bash
> sudo mv /mnt/hd2t/services/unbound/etc-unbound /mnt/hd2t/services/dns/unbound/etc-unbound
> sudo rmdir /mnt/hd2t/services/unbound
> ```

### 3.3. Permisos para el usuario `_unbound` del contenedor

La imagen `mvance/unbound` usa internamente el UID `103` (usuario `_unbound` de Debian). Como el bind mount entra como `homelab:homelab` (UID 1000), el entrypoint de la imagen hará `chown -R _unbound:_unbound /opt/unbound/etc/unbound/` al primer arranque. Para evitar que ese `chown` rompa la propiedad esperada por el host:

```bash
# Asegurar permisos compatibles: directorio writable por el grupo, y _unbound (UID 103
# del contenedor) podrá escribir gracias al CHOWN del cap_add.
sudo chmod 770 /mnt/hd2t/services/dns/unbound/etc-unbound
```

> El `chmod 770` permite al UID 103 del contenedor escribir en el directorio gracias a las capabilities (`CHOWN`, `DAC_OVERRIDE`). Tras el primer arranque, los ficheros internos (`root.key`, `unbound_control.{pem,key}`) aparecerán con propietario raro al hacer `ls` desde el host (el UID 103 del contenedor no tiene mapeo en el host, así que `ls` muestra `103 103`); es esperable y **no** afecta al backup ni al funcionamiento.

---

## 4. `unbound.conf`

Fichero `~/homelab/stacks/dns/unbound/unbound.conf`:

```conf
# ~/homelab/stacks/dns/unbound/unbound.conf
# Resolver recursivo + validador DNSSEC del homelab.
# Solo Pi-hole (192.168.1.241) y la lan-shim del host (192.168.1.240) pueden consultar.

server:
    # ----- Identidad y proceso -----
    verbosity: 1
    use-syslog: no
    log-queries: no
    log-replies: no
    log-servfail: yes
    hide-identity: yes
    hide-version: yes
    identity: "unbound"
    username: "_unbound"
    directory: "/opt/unbound/etc/unbound"
    chroot: ""
    pidfile: "/opt/unbound/etc/unbound/unbound.pid"

    # ----- Interfaces y puerto -----
    # 0.0.0.0 = todas las interfaces del contenedor (lan_macvlan y dns_internal).
    # El access-control de abajo es la barrera real.
    interface: 0.0.0.0
    port: 5335
    do-ip4: yes
    do-ip6: no            # IPv6 deshabilitado: la LAN no sirve IPv6 a clientes.
    do-udp: yes
    do-tcp: yes

    # ----- Quién puede consultar -----
    # Por defecto: refuse all.
    access-control: 0.0.0.0/0 refuse
    # Allow: Pi-hole (macvlan) + lan-shim del host (para diagnóstico).
    access-control: 192.168.1.241/32 allow
    access-control: 192.168.1.240/32 allow
    # Allow: la subred dns_internal (Docker la asigna dinámicamente; aquí se permite
    # cualquier IP privada del rango 172.16/12 que es donde Docker hace defaults).
    access-control: 172.16.0.0/12 allow
    access-control: 127.0.0.0/8 allow      # localhost (healthcheck dentro del contenedor)

    # ----- Caché -----
    msg-cache-size: 64m
    rrset-cache-size: 128m
    msg-cache-slabs: 4
    rrset-cache-slabs: 4
    infra-cache-slabs: 4
    key-cache-slabs: 4
    cache-min-ttl: 60          # No cachear menos de 60 s aunque el dominio diga TTL=1.
    cache-max-ttl: 86400       # Tope a 24 h aunque el dominio diga TTL=7 días.
    cache-max-negative-ttl: 3600
    serve-expired: yes         # Si el upstream cae, sirve la última respuesta conocida.
    serve-expired-ttl: 86400
    prefetch: yes
    prefetch-key: yes

    # ----- Privacidad -----
    qname-minimisation: yes
    qname-minimisation-strict: no   # Fallback si el autoritativo no soporta QM.
    aggressive-nsec: yes            # Usa NSEC/NSEC3 para responder NXDOMAIN sin consulta.

    # ----- Hardening -----
    harden-glue: yes
    harden-dnssec-stripped: yes
    harden-below-nxdomain: yes
    harden-referral-path: yes
    harden-algo-downgrade: yes
    use-caps-for-id: no           # 0x20 — útil pero rompe algunos autoritativos.

    # ----- DNSSEC (validación) -----
    # root.key se autoinicializa con el procedimiento RFC 5011.
    auto-trust-anchor-file: "/opt/unbound/etc/unbound/root.key"
    val-clean-additional: yes
    val-permissive-mode: no        # Rechaza respuestas que fallan DNSSEC.

    # ----- Anti DNS rebinding -----
    # Un autoritativo público no puede devolver una IP privada para un dominio público.
    private-address: 10.0.0.0/8
    private-address: 172.16.0.0/12
    private-address: 192.168.0.0/16
    private-address: 169.254.0.0/16
    private-address: fd00::/8
    private-address: fe80::/10

    # ----- Rendimiento en Pi 5 -----
    num-threads: 2                 # 2 cores dedicados a Unbound; el resto sigue libre.
    so-rcvbuf: 1m
    so-sndbuf: 1m
    so-reuseport: yes
    edns-buffer-size: 1232         # Recomendación post-DNSflagday2020.
    max-udp-size: 1232

    # ----- Misceláneo -----
    do-not-query-localhost: yes
    deny-any: yes                  # Rechaza queries ANY (mitiga amplification).
    rrset-roundrobin: yes
    minimal-responses: yes

# unbound-control habilitado por loopback dentro del contenedor (para diagnóstico).
remote-control:
    control-enable: yes
    control-interface: 127.0.0.1
    control-port: 8953
    server-key-file:    "/opt/unbound/etc/unbound/unbound_server.key"
    server-cert-file:   "/opt/unbound/etc/unbound/unbound_server.pem"
    control-key-file:   "/opt/unbound/etc/unbound/unbound_control.key"
    control-cert-file:  "/opt/unbound/etc/unbound/unbound_control.pem"
```

### 4.1. Por qué cada bloque

| Bloque | Por qué |
|---|---|
| `verbosity: 1` | Loggea errores y eventos relevantes (validación DNSSEC fallida, NXDOMAIN del root, fallos de glue), pero no cada query. Subir a `2` solo durante depuración. |
| `username: "_unbound"` | Usuario interno con UID 103 al que el entrypoint de la imagen dropa privilegios tras el bind del puerto. **No** se cambia a `homelab:homelab` ni a `root`. |
| `chroot: ""` | El `chroot` interno de Unbound conflictúa con el bind mount + el sistema de ficheros del contenedor; deshabilitarlo es práctica común en imágenes Docker. La aislación la da el propio contenedor. |
| `interface: 0.0.0.0` + `port: 5335` | Enlaza en todas las interfaces del contenedor (macvlan y dns_internal). La barrera real es `access-control`. |
| `do-ip6: no` | La LAN del homelab no sirve IPv6 a sus clientes; activarlo provocaría que Unbound intente resolver vía IPv6 hacia los root servers (que sí tienen IPv6) y los timeouts subirían si la salida IPv6 del operador es inestable. |
| `access-control: 0.0.0.0/0 refuse` (default) + `192.168.1.241/32 allow` + `192.168.1.240/32 allow` + `172.16/12 allow` | Política de denegar por defecto, permitir solo a Pi-hole, al host (vía lan-shim) y a la subred bridge interna. Una smart-TV en `192.168.1.150` que intentase consultar a `192.168.1.242:5335` recibe `REFUSED`. |
| `cache-min-ttl: 60` | Algunos CDNs anuncian TTL=1 (literal) para forzar regeneración en cada query. Eso destrozaría el caché. Imponer un mínimo de 60 s es un trade-off estándar: las respuestas son "ligeramente desactualizadas" pero el resolver no muere a peticiones. |
| `serve-expired: yes` + `serve-expired-ttl: 86400` | Si el autoritativo de un dominio cae temporalmente, Unbound sirve la última respuesta conocida durante hasta 24 h, manteniendo la LAN funcional. Estándar en resolvers públicos modernos (Cloudflare 1.1.1.1 lo hace por defecto). |
| `prefetch: yes` + `prefetch-key: yes` | Refresca registros populares **antes** de que expiren, así los clientes nunca esperan por el upstream. Más tráfico de red de fondo, latencia *p99* mucho mejor. |
| `qname-minimisation: yes` (RFC 9156) | Al resolver `mail.bank.example.com`, Unbound consulta solo `com` al servidor raíz, no `mail.bank.example.com`. Ningún tercero ve la consulta completa. |
| `aggressive-nsec: yes` | Usa pruebas NSEC/NSEC3 firmadas para responder NXDOMAIN inmediatamente sin volver a consultar. Reduce ataques de NXDOMAIN-flooding y mejora la velocidad. |
| `harden-*: yes` (varios) | Conjunto recomendado por la doc oficial de Unbound y por el Internet Society: rechazar glue records inconsistentes, respuestas con DNSSEC removido, referrals incorrectos, downgrade de algoritmos crípticos. |
| `auto-trust-anchor-file: root.key` | El *trust anchor* de la raíz DNS (KSK firmada por IANA). Unbound lo actualiza solo via RFC 5011 cuando IANA haga rollover. Persistido en `hd2t` para no reiniciar el aprendizaje del anchor cada `up`. |
| `private-address: ...` | Defensa contra DNS rebinding: ningún autoritativo público puede devolver una IP privada para un dominio público. Si lo hace, Unbound descarta la respuesta. La resolución de nombres internos (`*.lan`) la hace **Pi-hole** vía sus `Local DNS records`, no Unbound. |
| `num-threads: 2` | La Pi 5 tiene 4 cores. Dedicar 2 a Unbound deja 2 para Pi-hole, Caddy, Jellyfin, etc. Subirlo a 4 no aporta para una LAN doméstica (probablemente nunca se llegue al límite de un solo thread). |
| `edns-buffer-size: 1232` | Tras [DNS flag day 2020](https://dnsflagday.net/), 1232 bytes es el tamaño UDP recomendado para evitar fragmentación PMTU sobre IPv4/IPv6 con cabeceras "típicas". Valores más altos (4096) provocan PMTU drop en routers domésticos antiguos. |
| `deny-any: yes` | Las queries ANY (`dig ANY example.com`) se usan principalmente para amplificación DDoS. Rechazarlas no afecta a clientes normales. |
| `remote-control: ...` con `127.0.0.1` | `unbound-control` solo accesible desde dentro del contenedor (loopback). Útil para `unbound-control stats`, `dump_cache`, `flush`. Nunca expuesto a la red. |

---

## 5. `docker-compose.yml` ampliado

Editar `~/homelab/stacks/dns/docker-compose.yml` para **añadir** el servicio `unbound` (manteniendo el bloque `pihole` intacto). Asegurarse de que la sección `networks:` final ya tiene `dns_internal` declarada (lo está desde [`02-pihole.md`](./02-pihole.md) §4).

Bloque a insertar **después** del servicio `pihole` y **antes** del bloque `networks:`:

```yaml
  unbound:
    image: mvance/unbound:${UNBOUND_IMAGE_TAG}
    container_name: unbound
    hostname: unbound
    restart: unless-stopped

    env_file:
      - /mnt/hd2t/services/dns/.env
    environment:
      TZ: ${TZ}

    volumes:
      - type: bind
        source: /mnt/hd2t/services/dns/unbound/etc-unbound
        target: /opt/unbound/etc/unbound
        bind:
          create_host_path: false
      - type: bind
        source: ./unbound/unbound.conf
        target: /opt/unbound/etc/unbound/unbound.conf
        read_only: true
        bind:
          create_host_path: false

    networks:
      lan_macvlan:
        ipv4_address: 192.168.1.242
        mac_address: '02:42:c0:a8:01:f2'
      dns_internal:

    cap_drop:
      - ALL
    cap_add:
      - CHOWN
      - DAC_OVERRIDE
      - SETGID
      - SETUID
      - NET_BIND_SERVICE

    security_opt:
      - no-new-privileges:true

    healthcheck:
      test: ["CMD-SHELL", "drill -p 5335 @127.0.0.1 dnssec.works | grep -qE '^[^;].*A\\s'"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s

    labels:
      com.centurylinklabs.watchtower.enable: "false"
      # Sin labels homepage.*: Unbound no tiene UI ni se expone a la LAN, y el dashboard
      # de Homepage de la sección "Red" lo cubre Pi-hole. Su salud se monitoriza con
      # Uptime Kuma vía un check TCP a 192.168.1.242:5335.
```

> **`./unbound/unbound.conf`** es ruta **relativa** al `docker-compose.yml`. Compose la resuelve a `~/homelab/stacks/dns/unbound/unbound.conf`. Si en el futuro se invoca Compose desde otro directorio, la ruta sigue resolviéndose porque Compose la calcula respecto a la ubicación del `docker-compose.yml`, no del CWD.

### 5.1. Por qué cada bloque

| Bloque | Por qué |
|---|---|
| `image: mvance/unbound:${UNBOUND_IMAGE_TAG}` | Tag del `.env` (versionable cambiar versión sin tocar el YAML). Multi-arch. |
| `container_name: unbound` / `hostname: unbound` | Permite que Pi-hole alcance el servicio como `unbound:5335` desde `dns_internal` (alternativa al IP `192.168.1.242#5335`). |
| `env_file` | Hereda `TZ` del `.env` del stack. Igual que Pi-hole. |
| `volumes` (dos bind mounts) | El primero, `etc-unbound/`, persiste `root.key` y los certificados de `unbound-control`. El segundo monta el `unbound.conf` versionable en el path donde la imagen lo busca. **El segundo es read-only**: Unbound no debe modificarlo, solo leerlo. |
| `bind.create_host_path: false` (en ambos) | Si la ruta del host no existe, Compose **falla en `up`** en lugar de crear silenciosamente directorios `root:root`. |
| `networks: lan_macvlan + dns_internal` | Plan §1. `lan_macvlan` con IP/MAC estáticas siguiendo el plan de [`01-macvlan.md`](./01-macvlan.md). `dns_internal` sin parámetros (Docker asigna IP del rango bridge automáticamente). |
| `cap_drop: ALL` + `cap_add: [CHOWN, DAC_OVERRIDE, SETGID, SETUID, NET_BIND_SERVICE]` | Mínimo verificado para `mvance/unbound`: `CHOWN/DAC_OVERRIDE` para que el entrypoint pueda hacer `chown` inicial sobre `root.key` y los certs; `SETUID/SETGID` para dropar a `_unbound`; `NET_BIND_SERVICE` por consistencia con Pi-hole y por si alguna versión de la imagen hace bind antes del drop. |
| `security_opt: no-new-privileges:true` | Plantilla §6. Compatible con el drop a `_unbound`. |
| `healthcheck: drill -p 5335 @127.0.0.1 dnssec.works` | Verifica que **el resolver responde Y DNSSEC funciona**. `dnssec.works` es un dominio DNSSEC-firmado correctamente. `grep -qE '^[^;].*A\s'` filtra comentarios de `drill` y exige al menos un registro A. Más estricto que `dig +short`: `+short` da exit-0 incluso ante NXDOMAIN, que no es lo que queremos detectar. |
| `start_period: 30s` | Unbound arranca rápido (sin gravity como Pi-hole). 30 s sobran para que el entrypoint genere certificados al primer arranque. |
| `labels: watchtower.enable=false` | Excluye Unbound de Watchtower. Razonado en §0 y en [`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md). |
| Sin `labels: homepage.*` | Unbound no tiene UI. Su estado lo refleja Pi-hole (si Pi-hole responde, Unbound responde). Cuando llegue Uptime Kuma, se añadirá un monitor TCP a `192.168.1.242:5335`. |

### 5.2. Diff completo del `docker-compose.yml`

Tras el cambio, el `docker-compose.yml` del stack `dns` queda con esta estructura (mostrando solo el esqueleto):

```yaml
name: dns

services:
  pihole:
    # ... bloque íntegro de 02-pihole.md ...

  unbound:
    # ... bloque añadido en §5 ...

networks:
  lan_macvlan:
    external: true
  homelab:
    external: true
  dns_internal:
    driver: bridge
```

> El bloque `networks:` **no cambia**: `dns_internal` ya estaba declarada en [`02-pihole.md`](./02-pihole.md) §4 y `lan_macvlan`/`homelab` siguen siendo `external: true`. Pi-hole no necesita ningún ajuste todavía.

### 5.3. Validar antes de levantar

```bash
cd ~/homelab/stacks/dns
docker compose --env-file /mnt/hd2t/services/dns/.env config >/dev/null \
  && echo "Compose OK"
```

Si imprime errores, revisar:

- Indentación del bloque `unbound` (mismo nivel que `pihole`).
- `UNBOUND_IMAGE_TAG` definida en el `.env`.
- Que `~/homelab/stacks/dns/unbound/unbound.conf` exista (la ruta relativa la valida Compose con `create_host_path: false`).

---

## 6. Despliegue

### 6.1. Levantar Unbound (sin tocar Pi-hole todavía)

```bash
cd ~/homelab/stacks/dns
docker compose --env-file /mnt/hd2t/services/dns/.env up -d unbound
```

Salida esperada:

```
[+] Running 2/2
 ✔ Network dns_dns_internal  Running
 ✔ Container unbound          Started
```

> `up -d unbound` solo arranca el servicio nombrado, no recrea Pi-hole. La red `dns_internal` ya existía desde el primer `up` de Pi-hole.

### 6.2. Estado del contenedor

```bash
docker compose ps
# Esperado:
# NAME      IMAGE                   STATUS                   PORTS
# pihole    pihole/pihole:...       Up X minutes (healthy)
# unbound   mvance/unbound:1.21.0   Up 30 seconds (healthy)
```

`PORTS` aparece **vacío** (no hay `ports:` publicados): Unbound está accesible solo por sus IPs en `lan_macvlan` (`192.168.1.242:5335`) y `dns_internal` (asignada por Docker).

Si tarda más de 60 s en `(healthy)`, mirar logs:

```bash
docker compose logs unbound | head -50
```

En el primer arranque, Unbound:

1. Genera `unbound_server.{pem,key}` y `unbound_control.{pem,key}` (firma `unbound-control-setup` interno).
2. Inicializa `root.key` con el trust anchor de IANA (descarga via `unbound-anchor`).
3. Bindea `0.0.0.0:5335` y dropa privilegios a `_unbound`.

Eventos esperados en logs (verbosity 1):

```
unbound[1:0] notice: init module 0: validator
unbound[1:0] notice: init module 1: iterator
unbound[1:0] info: start of service (unbound 1.21.0).
```

### 6.3. Verificación local: el resolver responde

Desde la propia Pi:

```bash
# Vía macvlan (la lan-shim del host enruta al contenedor).
dig +short @192.168.1.242 -p 5335 dnssec.works
# Esperado: una IP (5.45.x.x)

dig +dnssec @192.168.1.242 -p 5335 dnssec.works | grep -E 'flags|status'
# Esperado:
#   ;; flags: qr rd ra ad; ...   ← el flag `ad` confirma DNSSEC validado.
#   status: NOERROR

# Validación DNSSEC negativa: dominio mal firmado.
dig @192.168.1.242 -p 5335 dnssec-failed.org | grep status
# Esperado: status: SERVFAIL
#   (Unbound rechaza la respuesta porque DNSSEC falla. Esto es lo correcto.)
```

> **Si `dig @192.168.1.242 -p 5335 ...` da timeout** desde la Pi pero funciona desde otro equipo de la LAN: la `lan-shim` no está enrutando. Revisar `systemctl status lan-shim.service` (§5 y §8 de [`01-macvlan.md`](./01-macvlan.md)).

### 6.4. Verificación de access-control: el firewall lógico de Unbound

Desde un equipo cualquiera de la LAN que **no** sea la Pi (móvil, portátil con `dig`):

```bash
dig @192.168.1.242 -p 5335 example.com
# Esperado: status: REFUSED
#   (porque la IP del cliente no está en `access-control: ... allow`)
```

Si responde con `NOERROR` y datos, **el `access-control` está mal**: revisar §4 (rangos `allow`/`refuse`) y `docker compose restart unbound`.

### 6.5. Verificación desde Pi-hole por nombre Docker (alternativa de upstream)

```bash
docker exec pihole getent hosts unbound
# Esperado: 10.x.x.x  unbound  (la IP de unbound en dns_internal)

# Resolución desde dentro de pihole:
docker exec pihole dig +short @unbound -p 5335 example.com
# Esperado: una IP de Akamai/IANA.
```

Esto demuestra que **Pi-hole puede usar `unbound#5335` (por nombre)** como upstream, no solo `192.168.1.242#5335`. Ambas formas funcionan; la siguiente sección elige una.

---

## 7. Cambiar el upstream de Pi-hole

Hasta ahora Pi-hole sigue con `PIHOLE_UPSTREAMS=1.1.1.1;9.9.9.9` (bootstrap). Toca migrar.

### 7.1. Editar el `.env` real

```bash
sudo -u homelab sed -i \
  's|^PIHOLE_UPSTREAMS=.*|PIHOLE_UPSTREAMS=192.168.1.242#5335|' \
  /mnt/hd2t/services/dns/.env

grep '^PIHOLE_UPSTREAMS=' /mnt/hd2t/services/dns/.env
# Esperado: PIHOLE_UPSTREAMS=192.168.1.242#5335
```

### 7.2. Recrear Pi-hole (no Unbound)

```bash
cd ~/homelab/stacks/dns
docker compose --env-file /mnt/hd2t/services/dns/.env up -d --force-recreate pihole
```

`--force-recreate pihole` **solo** recrea Pi-hole; Unbound sigue corriendo intacto.

### 7.3. Verificar la cadena Pi-hole → Unbound

```bash
# Consulta a Pi-hole. Debe responder y, por debajo, haber preguntado a Unbound.
dig +short @192.168.1.241 example.com
# Esperado: una IP

# Bloqueo (la respuesta no consume Unbound; lo gestiona Pi-hole con sus listas).
dig +short @192.168.1.241 doubleclick.net
# Esperado: 0.0.0.0
```

En la UI de Pi-hole (`http://192.168.1.241/admin`), **Settings → DNS → Upstream DNS Servers**: debe aparecer `192.168.1.242#5335`. La pestaña **Tools → Top Domains / Top Clients** debe mostrar tráfico fluyendo, y **Query Log** marcará el `Upstream` como `192.168.1.242#5335`.

### 7.4. Por qué `192.168.1.242#5335` y no `unbound#5335`

Ambas opciones funcionan. Razones para preferir la IP estática:

1. **No depende de Docker DNS.** El resolver embebido de Docker (`127.0.0.11`) lo consume Pi-hole solo para su propio entrypoint; cambiar el upstream a un nombre Docker introduce una dependencia más en la cadena de arranque.
2. **Coherente con [`02-pihole.md`](./02-pihole.md) §6.3 y con el plan de IPs de [`01-macvlan.md`](./01-macvlan.md) §2** (donde `192.168.1.242` está reservada para Unbound desde el primer minuto del homelab).
3. **Diagnosticable desde fuera del stack `dns`.** `dig @192.168.1.242 -p 5335 ...` funciona desde la Pi sin necesidad de `docker exec`.

> Si por la razón que sea Unbound cambia de IP en `lan_macvlan` (improbable, está estática), el cambio en Pi-hole es trivial: editar `.env` y `up -d --force-recreate pihole`.

---

## 8. Verificación

### 8.1. Contenedor sano

```bash
docker compose -f ~/homelab/stacks/dns/docker-compose.yml ps unbound
# Esperado: unbound  ...  Up X minutes (healthy)

docker inspect --format '{{.State.Health.Status}}' unbound
# Esperado: healthy
```

### 8.2. Resolución recursiva real (no forwarder)

```bash
# Pedir un dominio que NO está cacheado (TLD reciente o subdominio inventado).
dig +short @192.168.1.242 -p 5335 "$(date +%s).example.com"
# Esperado: una respuesta (NXDOMAIN o IP, dependiendo del dominio).
# El punto es: Unbound habrá ido a la raíz, a .com y a example.com de forma recursiva.

# Stats internas:
docker exec unbound unbound-control stats_noreset | grep -E '^total|num.queries|num.cachehits'
# Esperado: contadores aumentando.
```

### 8.3. DNSSEC funcional

```bash
# Dominio firmado correctamente — debe validar.
dig +dnssec +multi @192.168.1.242 -p 5335 dnssec.works | grep -E 'flags|status'
# Esperado:
#   flags: qr rd ra ad ;
#   status: NOERROR

# Dominio mal firmado — debe fallar.
dig +dnssec @192.168.1.242 -p 5335 dnssec-failed.org | grep status
# Esperado: status: SERVFAIL

# Comprobación end-to-end vía Pi-hole:
dig @192.168.1.241 dnssec-failed.org | grep status
# Esperado: status: SERVFAIL
#   (Pi-hole reenvía a Unbound, Unbound rechaza, Pi-hole devuelve SERVFAIL.)
```

### 8.4. QNAME minimisation activa

```bash
# Habilitar `verbosity: 2` temporalmente NO es necesario: la prueba más simple es
# asegurarse de que el flag está en la conf cargada.
docker exec unbound unbound-control get_option qname-minimisation
# Esperado: yes
```

### 8.5. Caché operando

```bash
# Primera consulta (cold).
time dig +short @192.168.1.242 -p 5335 wikipedia.org
# Esperado: ~150-400 ms

# Segunda consulta (cached).
time dig +short @192.168.1.242 -p 5335 wikipedia.org
# Esperado: ~1-10 ms

# Stats:
docker exec unbound unbound-control stats | grep -E 'cachemiss|cachehits|num.queries'
```

### 8.6. Access-control efectivo

```bash
# Desde un dispositivo de la LAN que NO sea la Pi:
dig @192.168.1.242 -p 5335 example.com
# Esperado: status: REFUSED

# Desde la Pi (lan-shim 192.168.1.240):
dig @192.168.1.242 -p 5335 example.com
# Esperado: status: NOERROR + IP

# Desde Pi-hole (192.168.1.241 vía macvlan):
docker exec pihole dig @192.168.1.242 -p 5335 example.com
# Esperado: status: NOERROR + IP
```

### 8.7. Cadena Pi-hole → Unbound → internet, end-to-end

```bash
# Limpiar caché de Pi-hole y Unbound para forzar resolución real.
docker exec unbound unbound-control flush_zone .
docker exec pihole pihole restartdns

# Consulta nueva.
dig +short @192.168.1.241 "rand-$(date +%s).example.com"
# Lo importante no es la respuesta sino que llegue *algo* (NXDOMAIN cuenta).

# En la UI de Pi-hole > Query Log > último query: el campo "Upstream"
# debe mostrar 192.168.1.242#5335.
```

### 8.8. Persistencia tras reboot

```bash
sudo reboot
# (esperar a que vuelva)

docker compose -f ~/homelab/stacks/dns/docker-compose.yml ps
# Esperado: pihole + unbound, ambos (healthy).

dig +short @192.168.1.242 -p 5335 example.com
# Responde.

dig +short @192.168.1.241 example.com
# Responde (vía Pi-hole → Unbound).
```

`root.key` debe haberse preservado (no se reinicializa en cada arranque): `ls -l /mnt/hd2t/services/dns/unbound/etc-unbound/root.key` debe mostrar la fecha del primer despliegue, no la del último reboot.

### 8.9. Lista de Verificación

Antes de pasar a [`04-caddy.md`](./04-caddy.md):

- [ ] `docker compose -f ~/homelab/stacks/dns/docker-compose.yml ps unbound` → `(healthy)`.
- [ ] `docker inspect unbound --format '{{.NetworkSettings.Networks.lan_macvlan.IPAddress}}'` → `192.168.1.242`.
- [ ] `docker inspect unbound --format '{{.NetworkSettings.Networks.lan_macvlan.MacAddress}}'` → `02:42:c0:a8:01:f2`.
- [ ] Desde la Pi: `dig @192.168.1.242 -p 5335 dnssec.works | grep ad` → flag `ad` presente.
- [ ] Desde la Pi: `dig @192.168.1.242 -p 5335 dnssec-failed.org | grep status` → `SERVFAIL`.
- [ ] Desde un cliente cualquiera de la LAN: `dig @192.168.1.242 -p 5335 example.com` → `REFUSED`.
- [ ] Pi-hole `.env` con `PIHOLE_UPSTREAMS=192.168.1.242#5335`; Pi-hole recreado.
- [ ] En la UI de Pi-hole, **Query Log** muestra `192.168.1.242#5335` como Upstream para consultas externas.
- [ ] `~/homelab/stacks/dns/unbound/unbound.conf` versionado en git; `/mnt/hd2t/services/dns/unbound/etc-unbound/root.key` **no** versionado.
- [ ] Tras un `sudo reboot`, todo lo anterior sigue cierto sin intervención.

---

## 9. Backup

Estrategia que se concretará en [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md). Lo que **debe respaldarse** de Unbound:

| Ruta | Qué contiene | Frecuencia |
|---|---|---|
| `~/homelab/stacks/dns/unbound/unbound.conf` | Configuración íntegra de Unbound. | Versionado en git → cubierto por `git push`. |
| `~/homelab/stacks/dns/docker-compose.yml` | Bloque `unbound` del stack. | Idem. |
| `~/homelab/stacks/dns/.env.example` | Variable `UNBOUND_IMAGE_TAG`. | Idem. |
| `/mnt/hd2t/services/dns/unbound/etc-unbound/root.key` | Trust anchor RFC 5011. **Reconstruible** desde IANA en cualquier momento (`unbound-anchor` lo regenera al primer arranque), pero respaldarlo evita una ventana de unas horas en la que Unbound no validaría DNSSEC mientras descarga el anchor. | Mensual o tras rollover IANA. |
| `/mnt/hd2t/services/dns/unbound/etc-unbound/unbound_*.{pem,key}` | Certificados de `unbound-control`. **Reconstruibles** vía `unbound-control-setup`. Si se pierden, el primer `up -d` los regenera automáticamente. | No críticos. Excluibles del backup. |

Pre-backup hook (Borgmatic), opcional:

```yaml
# Pseudo-config; la real va en 07-backups/02-borgmatic.md.
before_backup:
  - docker exec unbound unbound-control dump_cache > /mnt/hd2t/backups/dumps/unbound/cache.dump
```

`unbound-control dump_cache` permite restaurar la caché tras un disaster recovery con `unbound-control load_cache < cache.dump`. **No es crítico**: la caché se reconstruye en horas con tráfico normal.

> **Lo crucial es la `unbound.conf`.** Pérdida de `root.key` y certificados → 5 min de regeneración automática. Pérdida de `unbound.conf` → tienes que reconstruir desde memoria/Internet la afinación del resolver. Por eso vive en git.

---

## 10. Operaciones cotidianas

### 10.1. Ver estadísticas

```bash
docker exec unbound unbound-control stats_noreset | head -30
# total.num.queries          12345
# total.num.cachehits        9876
# total.num.cachemiss        2469
# num.query.tcp              42
# ...

# Reset de stats (útil para periodos):
docker exec unbound unbound-control stats        # imprime y resetea
```

### 10.2. Forzar limpieza de caché

```bash
# Limpieza global.
docker exec unbound unbound-control flush_zone .

# Limpieza puntual de un dominio.
docker exec unbound unbound-control flush example.com

# Limpieza de respuestas SERVFAIL (útil tras un fallo transitorio del autoritativo).
docker exec unbound unbound-control flush_bogus
```

### 10.3. Recargar configuración sin reiniciar

```bash
# Tras editar ~/homelab/stacks/dns/unbound/unbound.conf:
docker exec unbound unbound-control reload
```

> `unbound-control reload` aplica cambios **sin perder la caché**. Ideal para ajustes finos. Para cambios que afecten al binario o al entrypoint (versión nueva, capabilities), hay que `docker compose up -d --force-recreate unbound`.

### 10.4. Upgrade manual

```bash
# Editar UNBOUND_IMAGE_TAG en /mnt/hd2t/services/dns/.env (y .env.example).
sudo -u homelab sed -i 's|^UNBOUND_IMAGE_TAG=.*|UNBOUND_IMAGE_TAG=1.22.0|' \
  /mnt/hd2t/services/dns/.env

# Leer CHANGES.txt de Unbound antes de aplicar.
# https://github.com/NLnetLabs/unbound/blob/master/doc/Changelog

cd ~/homelab/stacks/dns
docker compose --env-file /mnt/hd2t/services/dns/.env pull unbound
docker compose --env-file /mnt/hd2t/services/dns/.env up -d --force-recreate unbound

# Verificar.
docker exec unbound unbound -V | head -3
```

> Watchtower **no** hace este upgrade automáticamente (`watchtower.enable: "false"`). Es decisión consciente del operador.

---

## 11. Solución de Problemas

| Síntoma | Causa probable | Acción |
|---|---|---|
| `docker compose up unbound` falla con `network lan_macvlan declared as external, but could not be found` | La red macvlan no se creó o se borró tras reiniciar Docker. | `docker network ls`; si no aparece, recrearla con [`01-macvlan.md`](./01-macvlan.md) §4.2. |
| `docker compose up unbound` falla con `Address already in use 192.168.1.242` | Otro contenedor o un dispositivo físico de la LAN está usando esa IP. | `docker network inspect lan_macvlan` para ver contenedores; desde otro equipo, `arp -a 192.168.1.242`. Ajustar la reserva DHCP del router (§3 de [`01-macvlan.md`](./01-macvlan.md)) o desconectar el dispositivo en conflicto. |
| Contenedor arranca pero queda `unhealthy`; `docker logs unbound` muestra `error: cannot read /opt/unbound/etc/unbound/unbound.conf` | El bind mount del `.conf` falla porque la ruta del host no existe (gracias a `create_host_path: false`). | Verificar `ls -l ~/homelab/stacks/dns/unbound/unbound.conf`. Si no existe, crearlo con el contenido de §4. |
| Contenedor arranca pero `dig @192.168.1.242 -p 5335 ...` desde la Pi da timeout | (a) `lan-shim` caída; (b) `access-control` no incluye la IP del lan-shim. | (a) `systemctl status lan-shim.service`; (b) revisar §4 que `access-control: 192.168.1.240/32 allow` está y que la IP de la lan-shim coincide. |
| Desde la LAN (no la Pi) `dig @192.168.1.242 ...` devuelve **respuesta válida** en lugar de `REFUSED` | El `access-control` está mal configurado o falta la línea `0.0.0.0/0 refuse` por defecto. | Revisar §4. El orden importa: la regla más específica gana, así que `0.0.0.0/0 refuse` puede ir al principio o al final, pero `192.168.1.241/32 allow` debe existir explícitamente. |
| `dig +dnssec @192.168.1.242 -p 5335 dnssec-failed.org` devuelve `NOERROR` (debería ser `SERVFAIL`) | DNSSEC no está activo: bien `auto-trust-anchor-file` no apunta a un fichero accesible, bien `val-permissive-mode: yes`. | Comprobar permisos de `/mnt/hd2t/services/dns/unbound/etc-unbound/root.key` (debe ser legible por UID 103). En la conf, `val-permissive-mode: no`. Reload: `docker exec unbound unbound-control reload`. |
| Pi-hole queda en SERVFAIL **siempre** tras cambiar a `192.168.1.242#5335` | Pi-hole no llega a Unbound (red rota, IP equivocada, puerto cerrado). | `docker exec pihole dig @192.168.1.242 -p 5335 example.com`. Si timeout: revisar que Pi-hole está en `lan_macvlan` con su IP estática. Si funciona desde Pi-hole pero la UI sigue marcando SERVFAIL: borrar la caché de Pi-hole con `pihole restartdns`. |
| Latencia altísima (>1 s) en consultas nuevas | Salida UDP/53 al exterior bloqueada o muy lenta. La Pi recurre a TCP/53 (más lento). | `dig @8.8.8.8 example.com` desde el host: si tarda >1 s, el problema es del operador/firewall. Comprobar `ufw status` (default `allow outgoing`). |
| `unbound-control` falla con `error: connection failed: SSL handshake failed` | Los certificados internos de `unbound-control` no se generaron o están corruptos. | Borrar `etc-unbound/unbound_server.{pem,key}` y `unbound_control.{pem,key}` del bind mount; reiniciar el contenedor. El entrypoint los regenera. |
| `root.key` no se actualiza tras un rollover de IANA | El proceso `unbound` no tiene permisos de escritura sobre el fichero. | `ls -l /mnt/hd2t/services/dns/unbound/etc-unbound/root.key`; asegurar que es modificable por UID 103 (capabilities `CHOWN`+`DAC_OVERRIDE` lo permiten). Si está como `root:root` con `chmod 600`, el contenedor no puede actualizarlo. |
| Unbound reporta `notice: ratelimit ... exceeded` y descarta consultas | Pi-hole envía picos de queries (cliente con bug, IoT en bucle). | `docker exec unbound unbound-control stats | grep ratelimited`. Si es alto, identificar el cliente en la Query Log de Pi-hole y bloquearlo. Subir `ratelimit:` solo como último recurso (defaults son razonables). |
| Tras reboot, Unbound arranca **antes** de tener red lista y queda en bucle de reinicio | `restart: unless-stopped` recrea el contenedor; al segundo o tercer intento, la red ya está. | El bucle es transparente. Si pasa más de 1 min: revisar `lan-shim.service` y `docker.service` (`systemctl status`). |
| `docker compose down` borra `dns_internal` y al volver a `up` Pi-hole queda con upstream "viejo" | `dns_internal` se recrea con subred posiblemente distinta; los nombres `unbound`/`pihole` siguen resolviendo. La caché de Pi-hole conserva la IP antigua de `unbound`. | `docker compose up -d` reinicia ambos contenedores; Pi-hole revuelve `unbound` o usa la IP `192.168.1.242` (que es estática y no depende de `dns_internal`). |
| `docker exec unbound drill -p 5335 ...` falla con `command not found` | La imagen no es `mvance/unbound` (tiene `drill`); puede ser una variante. | Ajustar el healthcheck a usar `dig` (instalando `dnsutils` con un layer adicional, o cambiando la imagen). Como alternativa rápida en el healthcheck: `nc -zu 127.0.0.1 5335` (solo verifica que el puerto escucha, no DNSSEC). |
| Consumo de RAM creciente sin estabilizar | Caché muy grande para el patrón de consultas, o leak en una versión específica. | `docker stats unbound`. Si supera 300 MB de forma estable: bajar `msg-cache-size` y `rrset-cache-size` y `unbound-control reload`. Si sigue creciendo, revisar versión: a veces hay regresiones en builds recientes. |

---

## Referencias

- [Unbound — Documentación oficial (NLnet Labs)](https://www.nlnetlabs.nl/documentation/unbound/)
- [Unbound — `unbound.conf(5)` (todas las opciones)](https://www.nlnetlabs.nl/documentation/unbound/unbound.conf/)
- [Unbound — Howto: anchor (RFC 5011)](https://www.nlnetlabs.nl/documentation/unbound/howto-anchor/)
- [Pi-hole — Configurar Unbound como upstream recursivo](https://docs.pi-hole.net/guides/dns/unbound/)
- [mvance/unbound — Imagen Docker (GitHub)](https://github.com/MatthewVance/unbound-docker)
- [mvance/unbound — Tags en Docker Hub](https://hub.docker.com/r/mvance/unbound/tags)
- [RFC 9156 — DNS Query Name Minimisation](https://datatracker.ietf.org/doc/html/rfc9156)
- [RFC 5011 — Automated Updates of DNS Security (DNSSEC) Trust Anchors](https://datatracker.ietf.org/doc/html/rfc5011)
- [DNS flag day 2020 — `edns-buffer-size: 1232`](https://dnsflagday.net/2020/)
- [DNS Privacy Project — Recursive resolver hardening](https://dnsprivacy.org/wiki/display/DP/Recursive+Resolvers)
- [`dnssec.works` — Test domain firmado correctamente](https://dnssec.works/)
- [`dnssec-failed.org` — Test domain mal firmado](https://www.dnssec-failed.org/)
