# Pi-hole

## Descripción

Despliegue de **Pi-hole v6** como **DNS resolver de toda la LAN del homelab**, con bloqueo de publicidad/telemetría a nivel de red, registros DNS locales para los servicios internos (`jellyfin.lan`, `nextcloud.lan`...) y una UI web para administrar listas, ver estadísticas y revisar el log de consultas. Pi-hole vive **en la red Docker `lan_macvlan`** ya creada en [`01-macvlan.md`](./01-macvlan.md), con **IP propia en la LAN** (`192.168.1.241`), de modo que cualquier dispositivo (móvil, portátil, smart-TV, IoT) lo ve como un servidor DNS más al apuntar `Servidor DNS` en el DHCP del router.

Por qué exactamente esta arquitectura:

1. **IP propia para evitar colisiones de puertos.** Pi-hole expone `:53/udp`, `:53/tcp` y `:80/tcp`. Si publicara esos puertos en la IP de la Pi (`192.168.1.10`), entrarían en conflicto con `systemd-resolved` (puerto 53) y con Caddy (puerto 80, futuro [`04-caddy.md`](./04-caddy.md)). Con la IP `192.168.1.241` propia, el host queda libre y los puertos 53/80 los toma Pi-hole en su dirección, no en la del host.
2. **Sin reglas de `ufw`.** El tráfico macvlan no atraviesa la pila del host, según se documenta en [`01-macvlan.md`](./01-macvlan.md) §6 y se confirma en [`../01-sistema/03-seguridad-base.md`](../01-sistema/03-seguridad-base.md). El firewall del homelab no necesita abrir el puerto 53.
3. **Stack `dns` compartido con Unbound.** Siguiendo la convención de [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §1.1, Pi-hole y Unbound comparten `docker-compose.yml` (stack `dns`). Este documento despliega **solo Pi-hole** y deja preparada la red privada `dns_internal` por la que después [`03-unbound.md`](./03-unbound.md) añadirá su servicio.
4. **Doble red por contenedor.** Pi-hole se conecta a tres redes Docker simultáneamente:
    - `lan_macvlan` → para que la **LAN** lo alcance como servidor DNS y para servir la UI mientras Caddy no esté.
    - `homelab` (bridge compartido, [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §4) → para que **Caddy** lo proxifique en HTTPS, **Prometheus** scrapee su exporter y **Homepage** muestre su widget, todo por nombre DNS interno (`pihole`) sin pasar por la macvlan.
    - `dns_internal` (bridge privado del stack) → para que **Unbound** sea su upstream (`unbound#5335` por nombre, sin exponer Unbound a la LAN).
5. **DNS fallback en el host.** Pi-hole es un *single point of failure* del DNS de la red. Si Pi-hole cae, todos los servicios de la LAN dejan de resolver. Para que la **propia Pi** no quede bloqueada (no resuelva `apt update`, no pueda hacer `docker pull`, etc.) se documenta un *fallback resiliente* en `/etc/resolv.conf` que prefiere Pi-hole (`192.168.1.241`) y, si no responde, cae a `1.1.1.1` y `9.9.9.9`. Ningún otro equipo de la LAN tiene fallback automático: ese es el coste asumido del modelo "DNS centralizado".

> **Alcance**: este documento despliega Pi-hole, persiste sus datos en `hd2t`, lo apunta a Unbound como upstream (preparado, no funcional hasta [`03-unbound.md`](./03-unbound.md)) y configura el DNS de la LAN. **No** despliega Caddy ni Tailscale: la UI se consulta directamente por `http://192.168.1.241/admin` hasta que [`04-caddy.md`](./04-caddy.md) ofrezca HTTPS con CA interna en `https://pihole.lan`.

---

## Requisitos Previos

- **Red `lan_macvlan` operativa** con la receta de [`01-macvlan.md`](./01-macvlan.md): subred `192.168.1.0/24`, gateway `192.168.1.1`, rango `192.168.1.240/28`, `aux-address` `192.168.1.240`, parent `eth0`.
- **Interfaz `lan-shim` activa** (`systemctl is-active lan-shim.service` → `active`) según §5 de [`01-macvlan.md`](./01-macvlan.md). Es la única vía por la que la propia Pi podrá hablar con `192.168.1.241`.
- **Pool DHCP del router** con el rango `.240`–`.255` excluido (§3 de [`01-macvlan.md`](./01-macvlan.md)).
- **Red `homelab`** creada según [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §4 (`docker network create ... homelab`).
- **Stack tree** creado: `~/homelab/stacks/dns/` versionable, `/mnt/hd2t/services/dns/` para datos. Si el bootstrap del homelab siguió [`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) literalmente, existe `/mnt/hd2t/services/pihole/` (esquema antiguo "un dir por servicio"). Este doc usa el **esquema vigente** "un dir por stack" definido en [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §2.1: `/mnt/hd2t/services/dns/pihole/`. La sección [§3](#3-preparar-el-árbol-de-datos) muestra cómo migrar si se siguió el esquema antiguo.
- **Docker Engine + Compose v2** instalados según [`../02-docker/01-instalacion-docker.md`](../02-docker/01-instalacion-docker.md).
- **Acceso al panel del router** (cuenta admin) para apuntar `192.168.1.241` como servidor DNS principal del DHCP.
- **`dig`, `nslookup` y `curl`** en el host (`sudo apt install -y dnsutils curl`) para validar.
- **Una contraseña de admin** generada con `openssl rand -base64 24` (24 bytes para una contraseña usable a mano si toca pegarla).

### Decisiones de diseño asumidas

| Decisión | Valor por defecto | Justificación |
|---|---|---|
| Versión de Pi-hole | **v6** (imagen `pihole/pihole`, tag fijo, ej. `2026.04.1`) | Pi-hole v6 (release 2025) reemplaza por completo `lighttpd` por un servidor web embebido en `pihole-FTL` y unifica su configuración en `pihole.toml`. Las variables de entorno cambian: `WEBPASSWORD` → `FTLCONF_webserver_api_password`, `PIHOLE_DNS_` → `FTLCONF_dns_upstreams`, etc. v5 está EOL. |
| Tag de imagen | **Pinned a la release**, nunca `latest` | Coherente con la regla de [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §6.1: tags fijos para que el operador decida cuándo subir. Watchtower **no** actualiza Pi-hole automáticamente (ver más abajo). |
| Política de Watchtower | **`watchtower.enable: "false"`** | Pi-hole tiene base de datos `gravity.db` (~100 k entradas), `pihole-FTL.db` (estadísticas) y migraciones de schema entre minor releases. Si Pi-hole se actualiza a las 04:00 sin supervisión y el upgrade rompe el resolver, **toda la LAN pierde DNS** durante horas. Documentado expresamente en [`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §6 línea 448. |
| Modo de red | **`lan_macvlan` + `homelab` + `dns_internal`** (tres `networks` en el contenedor) | Cada red sirve a una clase de cliente: macvlan = LAN, homelab = otros stacks Docker, dns_internal = Unbound upstream. Sin esta separación, o se publican puertos al host (lo que [`01-macvlan.md`](./01-macvlan.md) §1 quiere evitar) o Pi-hole queda incomunicado de Caddy/Prometheus. |
| IP en `lan_macvlan` | **`192.168.1.241`** (estática vía `ipv4_address`) | Reserva del plan de IPs en [`01-macvlan.md`](./01-macvlan.md) §2. Estable: el router puede entregar esa IP como DNS por DHCP sin recalcular nunca. |
| MAC en `lan_macvlan` | **`02:42:c0:a8:01:f1`** (estática vía `mac_address`) | El prefijo `02:42:` es el rango "locally administered" estándar de Docker; el sufijo `c0:a8:01:f1` codifica `192.168.1.241` (`0xc0a801f1` = `192.168.1.241`) → autodescriptivo y único. Fija para que reservas DHCP del router por MAC sigan funcionando aunque Docker recree el contenedor. |
| `ports:` publicados al host | **Ninguno** | El contenedor tiene su propia IP en la LAN; los puertos `53/udp`, `53/tcp` y `80/tcp` se atienden directamente sobre `192.168.1.241`. Publicar `ports:` provocaría que también se publiquen en `192.168.1.10` (la IP de la Pi), reintroduciendo la colisión que [`01-macvlan.md`](./01-macvlan.md) trata de evitar. |
| `FTLCONF_dns_listeningMode` | **`ALL`** | Por defecto Pi-hole solo escucha en la interfaz "primaria" del contenedor. Con tres redes (macvlan, homelab, dns_internal), si solo escuchara en una, los healthchecks por `homelab` o las consultas internas desde `dns_internal` fallarían. `ALL` hace que `pihole-FTL` se enlace a `0.0.0.0:53` y `[::]:53` y atienda por las tres. |
| `FTLCONF_dns_upstreams` | **`192.168.1.242#5335`** (Unbound futuro) | Mantiene la coherencia con [`01-macvlan.md`](./01-macvlan.md) §2 (`192.168.1.242` reservado para Unbound) y con [`03-unbound.md`](./03-unbound.md) que escuchará en `5335`. **Hasta que Unbound exista**, este valor provoca timeouts. La transición fluida la cubre [§6.3](#63-bootstrap-sin-unbound) (arrancar con `1.1.1.1; 9.9.9.9` y migrar a Unbound al desplegarlo). |
| `FTLCONF_dns_domain` | **`${LAN_DOMAIN}`** (`lan` por defecto) | Define el sufijo del DNS interno. `dnsmasq` añade automáticamente `domain=lan` al servir DHCP/DNS, y los clientes pueden resolver `jellyfin.lan` al escribir `jellyfin`. Coherente con la variable global `LAN_DOMAIN` de [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §5.2. |
| `FTLCONF_dns_expandHosts` | **`true`** | Permite que `dnsmasq` añada el dominio configurado a entradas locales sin sufijo. Sin esto, `jellyfin` y `jellyfin.lan` no se considerarían el mismo registro. |
| `FTLCONF_dns_domainNeeded` | **`true`** | Bloquea consultas de nombres "huérfanos" (sin punto, no FQDN) al upstream. Reduce ruido en Unbound y evita filtrado de hostnames internos a internet. |
| `FTLCONF_misc_etc_dnsmasq_d` | **`false`** | El homelab arranca limpio (sin venir de Pi-hole v5). Activar este flag haría que Pi-hole leyese `/etc/dnsmasq.d/*.conf` además de `pihole.toml`, complicando la configuración sin razón. |
| Persistencia | **Bind mount único** `/etc/pihole` ← `/mnt/hd2t/services/dns/pihole/etc-pihole/` | Pi-hole v6 unifica config + DBs en `/etc/pihole`. No hace falta el bind mount adicional `/etc/dnsmasq.d/` que sí pedía v5. |
| Usuario del contenedor | **`root` (default de la imagen, sin `user:` en Compose)** | Excepción explícita a la plantilla §6 de [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md). Pi-hole necesita arrancar como root para `chown` `/etc/pihole`, asignar la MAC al interfaz dentro del contenedor y bindar `:53` y `:80` (puertos privilegiados); luego cae a su propio usuario interno. Sustituirlo por `${PUID}:${PGID}` rompe el entrypoint oficial. |
| `cap_drop: ALL` + `cap_add` mínimo | Como en la plantilla **pero ampliado** con `CHOWN`, `DAC_OVERRIDE`, `FOWNER`, `SETGID`, `SETUID`, `NET_BIND_SERVICE`, `NET_RAW`, `SYS_NICE` | Pi-hole sin `--privileged` necesita: `CHOWN/SETUID/SETGID/DAC_OVERRIDE/FOWNER` (entrypoint hace `chown` recursivo de `/etc/pihole`), `NET_BIND_SERVICE` (bind a `:53` y `:80` como root con caps reducidas), `NET_RAW` (sondas ICMP de Pi-hole para ping de upstream), `SYS_NICE` (FTL ajusta su prioridad). No se añade `NET_ADMIN` ni `SYS_TIME` porque este Pi-hole **no** sirve DHCP ni NTP. |
| `security_opt` | **`no-new-privileges:true`** | Igual que la plantilla; compatible con `cap_add` enumerado. |
| `read_only` | **`false`** | Pi-hole escribe en `/etc/pihole` (DBs vivas), `/var/log/pihole/` (efímero) y `/tmp` (cache de gravity). Hacerlo read-only obligaría a media docena de `tmpfs` que aportan poco al modelo de amenaza del homelab (LAN-only). |
| Healthcheck | **Consulta DNS interna a `pi.hole`** vía `dig @127.0.0.1 pi.hole +short` | `pi.hole` es el FQDN canónico que Pi-hole resuelve a sí mismo desde v5. Si responde con la IP del contenedor en `lan_macvlan`, `pihole-FTL` está vivo y ha cargado `gravity.db`. Más robusto que `curl http://localhost/admin` (el web puede tardar más en arrancar que el resolver). |
| Logs | Defaults del demonio (`json-file`, 10 MB × 3 desde [`../02-docker/01-instalacion-docker.md`](../02-docker/01-instalacion-docker.md)) | Pi-hole tiene su propio log de queries en `/etc/pihole/pihole-FTL.log` (visible desde la UI). El stdout/stderr del contenedor solo emite eventos del entrypoint y warnings de FTL, así que los defaults del daemon sobran. |

---

## 1. Resumen de la arquitectura

```
                 ┌─────────────────┐
   LAN clients ─►│ DHCP del router │── DNS opt. nº 6 ──► 192.168.1.241  (Pi-hole, macvlan)
                 └─────────────────┘
                                              │
                                              │  consultas DNS de toda la LAN
                                              ▼
   ┌──────────────────── Stack `dns` (docker-compose.yml) ────────────────────┐
   │                                                                         │
   │  ┌──────────────────────────── pihole ───────────────────────────────┐  │
   │  │                                                                   │  │
   │  │   listening on 0.0.0.0:53  (FTLCONF_dns_listeningMode=ALL)         │  │
   │  │                                                                   │  │
   │  │   ──[upstream]──► unbound  (vía bridge dns_internal)              │  │
   │  │                                                                   │  │
   │  │   ──[ui http]──►   :80  (proxy futuro: caddy en homelab)          │  │
   │  │                                                                   │  │
   │  │   ──[metrics]──►   pihole-exporter (vía bridge homelab) [futuro]  │  │
   │  │                                                                   │  │
   │  │   networks:                                                       │  │
   │  │     - lan_macvlan   192.168.1.241    (LAN)                        │  │
   │  │     - homelab       172.20.0.x       (Caddy / Prometheus)         │  │
   │  │     - dns_internal  10.x.x.x         (Unbound upstream)           │  │
   │  └───────────────────────────────────────────────────────────────────┘  │
   │                                                                         │
   │  ┌──────────────── unbound (lo añade 03-unbound.md) ──────────────────┐ │
   │  │   listening on 0.0.0.0:5335                                        │ │
   │  │   networks: dns_internal, homelab                                  │ │
   │  └────────────────────────────────────────────────────────────────────┘ │
   └─────────────────────────────────────────────────────────────────────────┘

   Pi (host)   ─── lan-shim (192.168.1.240) ─── tráfico al rango macvlan
       │
       └──/etc/resolv.conf:  primary 192.168.1.241, fallback 1.1.1.1 / 9.9.9.9
```

Tres invariantes derivados:

- La **LAN** habla con Pi-hole **solo** por `192.168.1.241` (macvlan). Nunca por la IP del host.
- **Caddy y Prometheus** hablan con Pi-hole **solo** por `homelab` (`http://pihole`), nunca por la macvlan. Esto evita rutas asimétricas y reduce la superficie de exposición de la UI.
- **Unbound** habla con Pi-hole **solo** por `dns_internal`, **una red privada del stack**, no expuesta a la LAN ni a otros stacks.

---

## 2. Plan de variables y secretos

### 2.1. `~/homelab/stacks/dns/.env.example` (versionado en git)

Plantilla con valores ficticios. **Nunca** se versionan los valores reales.

```dotenv
# ===== Stack `dns` (Pi-hole + Unbound) =====
# Versión control: ~/homelab/stacks/dns/.env.example
# Valores reales en /mnt/hd2t/services/dns/.env (chmod 600).

# --- Identidad y zona horaria (heredados, mismo contenido en todos los stacks) ---
PUID=1000
PGID=1000
TZ=Europe/Madrid

# --- Dominios internos (consistentes en todo el homelab) ---
LAN_DOMAIN=lan
TS_DOMAIN=tailnet.ts.net

# --- Pi-hole ---
# Contraseña de la UI/API. Generar con: openssl rand -base64 24
PIHOLE_ADMIN_PASSWORD=changeme-please-base64-24bytes

# Upstream DNS que Pi-hole consultará para nombres no cacheados.
# Bootstrap (sin Unbound aún):  1.1.1.1;9.9.9.9
# Producción (tras 03-unbound.md): 192.168.1.242#5335
PIHOLE_UPSTREAMS=1.1.1.1;9.9.9.9
```

### 2.2. `/mnt/hd2t/services/dns/.env` (real, fuera de git)

Mismo formato, valores reales. La generación se documenta en [§3.2](#32-crear-el-env-real).

### 2.3. Cómo se inyectan al contenedor

Compose usa `env_file:` con ruta absoluta al `.env` real, y `environment:` para mapear cada variable a la `FTLCONF_*` correspondiente. Mantener separados `env_file` y `environment` permite:

- Cambiar el upstream solo editando el `.env` y `docker compose up -d --force-recreate pihole`, sin tocar el YAML versionado.
- Que `docker compose config --env-file /mnt/hd2t/services/dns/.env` muestre la configuración interpolada para revisión sin filtrar el `.env` a stdout (Compose redacta automáticamente en `config` los valores que detecta como secretos por nombre, pero no los tomados de `env_file`; revisar a mano antes de pegar la salida en cualquier sitio).

---

## 3. Preparar el árbol de datos

### 3.1. Crear el directorio del stack

```bash
# Como usuario homelab (no sudo).
mkdir -p ~/homelab/stacks/dns
```

Y los datos persistentes en `hd2t`:

```bash
sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/services/dns
sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/services/dns/pihole
sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/services/dns/pihole/etc-pihole
```

> **Migración desde el esquema antiguo `/mnt/hd2t/services/pihole/`** (creado por el script de [`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) §5 antes de fijar la convención por stack). Si el directorio existe vacío:
> ```bash
> sudo rmdir /mnt/hd2t/services/pihole 2>/dev/null || true
> ```
> Si tiene datos de un Pi-hole anterior, moverlos antes de eliminar el directorio:
> ```bash
> sudo mv /mnt/hd2t/services/pihole/etc-pihole /mnt/hd2t/services/dns/pihole/etc-pihole
> sudo rmdir /mnt/hd2t/services/pihole
> ```
> Lo mismo con el de Unbound al desplegar [`03-unbound.md`](./03-unbound.md).

### 3.2. Crear el `.env` real

```bash
# Generar contraseña.
PIHOLE_PASS="$(openssl rand -base64 24)"
echo "Apunta y guarda en Vaultwarden: ${PIHOLE_PASS}"

# Crear el .env con permisos correctos.
sudo install -m 600 -o homelab -g homelab /dev/null /mnt/hd2t/services/dns/.env

# Rellenarlo (sin sudo, propietario homelab).
cat > /mnt/hd2t/services/dns/.env <<EOF
PUID=1000
PGID=1000
TZ=Europe/Madrid
LAN_DOMAIN=lan
TS_DOMAIN=tailnet.ts.net
PIHOLE_ADMIN_PASSWORD=${PIHOLE_PASS}
# Bootstrap antes de Unbound. Cambiar a 192.168.1.242#5335 al desplegar 03-unbound.md.
PIHOLE_UPSTREAMS=1.1.1.1;9.9.9.9
EOF

# Validar permisos.
ls -l /mnt/hd2t/services/dns/.env
# Esperado: -rw------- 1 homelab homelab ... .env
```

> **No** se ejecuta `sudo cat > .env`: la redirección la hace el shell **antes** del `sudo`, así que el fichero acabaría como `root:root` y rompería los permisos. La forma correcta es la mostrada (el `install -m 600` previo ya fija propiedad y modo, y luego `cat > ...` se ejecuta como `homelab`).

### 3.3. Versionar el `.env.example` y el `docker-compose.yml`

```bash
cd ~/homelab
cp -i .gitignore .gitignore  # asegurarse de que .env está ignorado (ya lo está según §2.3 de 02-estructura-compose.md)

# Crear los ficheros versionables (los rellenamos en §4 y §2.1).
touch ~/homelab/stacks/dns/docker-compose.yml
touch ~/homelab/stacks/dns/.env.example

git add stacks/dns/
git status
# Debe listar:
#   new file:   stacks/dns/.env.example
#   new file:   stacks/dns/docker-compose.yml
# y NO debe listar nada que apunte a /mnt/hd2t/services/dns/.env.
```

---

## 4. `docker-compose.yml` del stack `dns`

Fichero `~/homelab/stacks/dns/docker-compose.yml`:

```yaml
# ~/homelab/stacks/dns/docker-compose.yml
# Stack `dns`: Pi-hole (este doc) + Unbound (../03-unbound.md, pendiente).
# Datos en /mnt/hd2t/services/dns/. Secretos en /mnt/hd2t/services/dns/.env.

name: dns

services:
  pihole:
    image: pihole/pihole:2026.04.1
    container_name: pihole
    hostname: pihole
    restart: unless-stopped

    env_file:
      - /mnt/hd2t/services/dns/.env
    environment:
      TZ: ${TZ}
      # --- API/UI ---
      FTLCONF_webserver_api_password: ${PIHOLE_ADMIN_PASSWORD}
      # --- DNS ---
      FTLCONF_dns_listeningMode: 'ALL'
      FTLCONF_dns_upstreams: ${PIHOLE_UPSTREAMS}
      FTLCONF_dns_domain: ${LAN_DOMAIN}
      FTLCONF_dns_domainNeeded: 'true'
      FTLCONF_dns_expandHosts: 'true'
      # --- Compatibilidad ---
      FTLCONF_misc_etc_dnsmasq_d: 'false'

    volumes:
      - type: bind
        source: /mnt/hd2t/services/dns/pihole/etc-pihole
        target: /etc/pihole
        bind:
          create_host_path: false

    networks:
      lan_macvlan:
        ipv4_address: 192.168.1.241
        mac_address: '02:42:c0:a8:01:f1'
      homelab:
      dns_internal:

    cap_drop:
      - ALL
    cap_add:
      - CHOWN
      - DAC_OVERRIDE
      - FOWNER
      - SETGID
      - SETUID
      - NET_BIND_SERVICE
      - NET_RAW
      - SYS_NICE

    security_opt:
      - no-new-privileges:true

    healthcheck:
      test: ["CMD-SHELL", "dig +short +tries=1 +time=2 @127.0.0.1 pi.hole | grep -q ."]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 60s

    labels:
      com.centurylinklabs.watchtower.enable: "false"
      homepage.group: "Red"
      homepage.name: "Pi-hole"
      homepage.icon: "pi-hole.png"
      homepage.href: "https://pihole.${LAN_DOMAIN}"
      homepage.description: "DNS con bloqueo de publicidad y telemetría"

networks:
  lan_macvlan:
    external: true
  homelab:
    external: true
  dns_internal:
    driver: bridge
    # Subred autoasignada por Docker (el doc no la fija para no consumir un /24
    # del default-address-pool sin necesidad). Si en el futuro se quiere fijar,
    # añadir `ipam: { config: [{ subnet: 172.20.10.0/24 }] }` y documentarlo.
```

### 4.1. Por qué cada bloque

| Bloque | Por qué |
|---|---|
| `name: dns` | Coincide con el directorio del stack y con la fila §1.1 de [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md). |
| `image: pihole/pihole:2026.04.1` | Tag fijo (no `latest`); release de Pi-hole v6. Si en el momento de aplicar este doc hay una versión más reciente, sustituir por la última *date-based* y dejar comentado el motivo del cambio. |
| `container_name: pihole` / `hostname: pihole` | Compatibilidad con Caddy (`reverse_proxy http://pihole`) y con la propia resolución interna de Pi-hole (`pi.hole` es alias canónico). |
| `restart: unless-stopped` | Plantilla §6. Si el operador hace `docker compose stop pihole`, Pi-hole **no** se reinicia solo. Si la Pi reboota, sí. |
| `env_file: /mnt/hd2t/services/dns/.env` | Ruta absoluta para no depender del directorio desde donde se invoca `docker compose`. Coherente con [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §5.1. |
| `FTLCONF_webserver_api_password` | Pi-hole v6 introduce *API password* (no "WEBPASSWORD"); la UI usa la API por debajo. Mantenerla en `.env` permite cambiarla sin tocar git. |
| `FTLCONF_dns_listeningMode: ALL` | Sin esto, Pi-hole solo atiende en su interfaz "primary" elegida por FTL al arrancar (suele ser `eth0` del contenedor, que en macvlan es la interfaz LAN). Las consultas vía bridge `homelab` o `dns_internal` no responderían y el healthcheck fallaría desde el bridge si decidiéramos cambiarlo a `dig @pihole` desde otro contenedor. |
| `FTLCONF_dns_upstreams` | Acepta lista separada por `;`. Notación `IP#port` para puertos no estándar. Ejemplo: `192.168.1.242#5335;1.1.1.1` (Unbound primario, Cloudflare como red de seguridad). El `;` es de Pi-hole; el `#` es de dnsmasq. |
| `FTLCONF_dns_domain: lan` | Para que `dnsmasq` añada `.lan` al servir DHCP/DNS y para que los registros locales funcionen sin fqdn. |
| `FTLCONF_dns_domainNeeded: 'true'` | Bloquea que consultas tipo `myhost` (sin punto) salgan al upstream. Reduce ruido en Unbound y evita filtrar nombres internos. |
| `FTLCONF_dns_expandHosts: 'true'` | `dnsmasq` añade `${LAN_DOMAIN}` automáticamente a entradas de `/etc/pihole/local.list` y a la API. Sin esto, el cliente debe escribir el FQDN exacto. |
| `FTLCONF_misc_etc_dnsmasq_d: 'false'` | Solo poner `true` si se migra desde una v5 con configs personalizadas en `/etc/dnsmasq.d/`. Este homelab arranca limpio. |
| `volumes: bind /etc/pihole` con `create_host_path: false` | Plantilla §6. Si la ruta no existe, Compose **falla en `up`** en lugar de crear silenciosamente un directorio `root:root`. |
| `networks` con tres entradas | Justificado en §1. La sintaxis larga (`networks: { lan_macvlan: { ipv4_address, mac_address } }`) es la única que soporta IP estática y MAC estática. |
| `cap_drop: ALL` + `cap_add: [CHOWN, DAC_OVERRIDE, FOWNER, SETGID, SETUID, NET_BIND_SERVICE, NET_RAW, SYS_NICE]` | Mínimo verificado para Pi-hole v6 sin DHCP/NTP. `NET_RAW` se requiere porque `pihole-FTL` envía pings ICMP (estadísticas de upstream). Si en el futuro se activa Pi-hole DHCP, **añadir** `NET_ADMIN`; si se activa NTP, **añadir** `SYS_TIME`. Documentado por la propia [Pi-hole — note on capabilities](https://docs.pi-hole.net/docker/configuration/#note-on-capabilities). |
| `security_opt: no-new-privileges:true` | Plantilla §6. Compatible con `cap_add` enumerado. |
| `healthcheck: dig @127.0.0.1 pi.hole` | El healthcheck se ejecuta dentro del contenedor con `127.0.0.1`: Pi-hole escucha en `0.0.0.0` (FTLCONF_dns_listeningMode=ALL), así que `127.0.0.1:53` siempre debería responder. `pi.hole` es FQDN reservado por Pi-hole para auto-referencia. `+tries=1 +time=2` evita que un upstream lento haga timeout el healthcheck (esto solo prueba el resolver local). `grep -q .` falla si no hay output (Pi-hole devolvería NXDOMAIN o la IP del contenedor). |
| `start_period: 60s` | Pi-hole v6 carga `gravity.db` (decenas de MB) antes de aceptar consultas. 60 s es seguro para una Pi 5 con almacenamiento en `hd2t` (USB 3.0). En el primer arranque, *gravity update* puede tardar más; ver [§7](#7-verificación). |
| `labels: watchtower.enable=false` | Excluye explícitamente Pi-hole del ciclo de Watchtower. |
| `labels: homepage.*` | Auto-descubrimiento por Homepage cuando se despliegue ([`../12-dashboards/01-homepage.md`](../12-dashboards/01-homepage.md)). El icono `pi-hole.png` es el slug correcto en el [icon set de Homepage](https://github.com/walkxcode/dashboard-icons). |
| `networks.lan_macvlan.external: true` | La crea [`01-macvlan.md`](./01-macvlan.md), no este stack. |
| `networks.homelab.external: true` | La crea [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §4. |
| `networks.dns_internal.driver: bridge` | La gestiona este propio stack. Cuando se borre el stack (`docker compose down`), `dns_internal` se borra con él. |

### 4.2. `.env.example` versionable

Copiar el bloque mostrado en [§2.1](#21-homelabstacksdnsenvexample-versionado-en-git) en `~/homelab/stacks/dns/.env.example`:

```bash
cat > ~/homelab/stacks/dns/.env.example <<'EOF'
# ===== Stack `dns` (Pi-hole + Unbound) =====

PUID=1000
PGID=1000
TZ=Europe/Madrid

LAN_DOMAIN=lan
TS_DOMAIN=tailnet.ts.net

# Pi-hole
PIHOLE_ADMIN_PASSWORD=changeme-please-base64-24bytes
# Bootstrap antes de Unbound: 1.1.1.1;9.9.9.9
# Producción tras 03-unbound.md:    192.168.1.242#5335
PIHOLE_UPSTREAMS=1.1.1.1;9.9.9.9
EOF
```

### 4.3. Validar antes de levantar

```bash
cd ~/homelab/stacks/dns
docker compose --env-file /mnt/hd2t/services/dns/.env config >/dev/null \
  && echo "Compose OK"
```

Si imprime errores de YAML, indentación o de variable sin definir, corregir antes de continuar.

---

## 5. Despliegue

### 5.1. Levantar el stack

```bash
cd ~/homelab/stacks/dns
docker compose --env-file /mnt/hd2t/services/dns/.env up -d
```

`docker compose` también lee el YAML solo (sin `--env-file`), pero al usar interpolación `${LAN_DOMAIN}` en `labels`, Compose **necesita** el `.env` durante el parseo. Por eso se pasa `--env-file` (regla §6.3 de [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md)).

Salida esperada (resumen):

```
[+] Creating 1/1
 ✔ Network dns_dns_internal  Created
 ✔ Container pihole          Started
```

> Si el primer `up -d` se queda en `Creating` un par de minutos: Pi-hole inicial descarga `gravity` (listas de bloqueo) tras arrancar, y el healthcheck no devolverá `(healthy)` hasta que ese proceso termine. Es esperable. Vigilar con `docker compose logs -f`.

### 5.2. Estado del contenedor

```bash
docker compose ps
# Esperado:
# NAME    IMAGE                       STATUS                   PORTS
# pihole  pihole/pihole:2026.04.1     Up 2 minutes (healthy)
```

`PORTS` aparece **vacío** (no hay `ports:` publicados). Es lo correcto: la accesibilidad la da la IP `192.168.1.241` de la macvlan, no un mapeo de puerto del host.

### 5.3. Probar que la lan-shim sigue activa y comunica con el contenedor

```bash
# Desde la propia Pi.
ping -c 3 192.168.1.241                # debe responder (vía lan-shim)
curl -s -o /dev/null -w "%{http_code}\n" http://192.168.1.241/admin
# Esperado: 200 (UI servida)

dig +short @192.168.1.241 pi-hole.net
# Esperado: una IP pública (Pi-hole resuelve mediante upstream).
```

Si `ping` falla pero la UI responde desde otro equipo de la LAN, revisar `lan-shim.service` ([`01-macvlan.md`](./01-macvlan.md) §8).

### 5.4. Probar desde otro equipo de la LAN

Desde un portátil/móvil conectado al router doméstico:

```bash
nslookup google.com 192.168.1.241
# Esperado: respuesta no autoritativa con varias IPs (Google).

nslookup ads.example 192.168.1.241
# Esperado: 0.0.0.0 (bloqueado por la primera lista que entró en gravity).

curl -I http://192.168.1.241/admin
# Esperado: HTTP/1.1 200 OK
```

---

## 6. Configuración post-despliegue

### 6.1. Acceder a la UI por primera vez

```
http://192.168.1.241/admin
```

Login con `PIHOLE_ADMIN_PASSWORD` (el generado en §3.2). Pi-hole v6 usa autenticación por *API password*: la UI guarda el token en una cookie de sesión.

> **HTTPS**: Pi-hole v6 también escucha en `:443` con un certificado auto-firmado generado por FTL al primer arranque. Visitar `https://192.168.1.241/admin` muestra el aviso de certificado del navegador. Esto es **temporal**: cuando se despliegue [`04-caddy.md`](./04-caddy.md), Caddy proxificará Pi-hole en `https://pihole.lan` con CA interna y se podrá deshabilitar el `:443` del propio Pi-hole.

### 6.2. Listas de bloqueo recomendadas

Pi-hole v6 trae **una sola lista** por defecto (StevenBlack). Sustituir / ampliar al gusto. Listas razonables, ordenadas por agresividad:

| Lista | URL | Comentario |
|---|---|---|
| StevenBlack `hosts` (incluida) | `https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts` | Tronco principal. ~150 k entradas. |
| OISD Big | `https://big.oisd.nl/dnsmasq2` | Curada manualmente, baja tasa de falsos positivos. ~2 M entradas. **Sustituye** a varias listas tradicionales. |
| HaGeZi Pro | `https://raw.githubusercontent.com/hagezi/dns-blocklists/main/dnsmasq/pro.txt` | Equilibrio entre cobertura y compatibilidad. |

Añadirlas en **Adlists → Add a new adlist** y luego **Tools → Update Gravity**. Cada `Update Gravity` tarda 1-3 min en una Pi 5 con HD2T USB 3.0; ocurre automáticamente cada domingo según el cron interno de la imagen.

> **Cómo NO acabar bloqueando servicios reales**: las "ultimate filter lists" (>5 M entradas, lista nuclear) suelen romper push notifications, mapas, reCAPTCHA, etc. Empezar por OISD Big y añadir más solo si hay dominio concreto en mente. Cualquier dominio puede *whitelistarse* en `Domains → Allow`, pero diagnosticar de qué lista vino el bloqueo es tedioso.

### 6.3. Bootstrap sin Unbound

Mientras [`03-unbound.md`](./03-unbound.md) no esté desplegado, `PIHOLE_UPSTREAMS` debe apuntar a resolvers públicos:

```dotenv
# /mnt/hd2t/services/dns/.env  (durante el bootstrap)
PIHOLE_UPSTREAMS=1.1.1.1;9.9.9.9
```

Cuando se levante Unbound, **cambiar** a:

```dotenv
PIHOLE_UPSTREAMS=192.168.1.242#5335
```

y ejecutar:

```bash
cd ~/homelab/stacks/dns
docker compose --env-file /mnt/hd2t/services/dns/.env up -d --force-recreate pihole
```

`--force-recreate pihole` solo recrea el contenedor de Pi-hole; el de Unbound (cuando exista) no se toca.

> Mantener `1.1.1.1;9.9.9.9` como segundo upstream "de emergencia" en producción es un anti-patrón: los clientes acabarían recibiendo respuestas no auditadas por Unbound de forma intermitente. La forma correcta de tener resiliencia es **monitorizar Unbound** (Uptime Kuma, [`../05-monitorizacion/05-uptime-kuma.md`](../05-monitorizacion/05-uptime-kuma.md)) y reaccionar.

### 6.4. Registros DNS locales para servicios del homelab

En la UI: **Local DNS → DNS Records**. Mapear cada `*.lan` a la IP de la Pi (donde Caddy escuchará) y los servicios macvlan a su IP propia:

| Nombre | IP | Razón |
|---|---|---|
| `pihole.lan` | `192.168.1.10` | (futuro) Caddy proxifica `https://pihole.lan` → `http://pihole:80`. |
| `unbound.lan` | `192.168.1.10` | (futuro) Caddy proxifica `https://unbound.lan` → `http://unbound:8080` si Unbound expusiera UI; si no, no crear. |
| `caddy.lan` | `192.168.1.10` | Apunta al propio Caddy. |
| `jellyfin.lan` | `192.168.1.10` | Caddy proxy. |
| `nextcloud.lan` | `192.168.1.10` | Caddy proxy. |
| ...y así con cada `<servicio>.lan` que aparezca en la Fase 5–11 | `192.168.1.10` | Todos detrás de Caddy. |
| `homelab.lan` (alias) | `192.168.1.10` | Comodín opcional para llegar al dashboard. |

> **Por qué no se hace todo con `*.lan` wildcard**: `dnsmasq` (que es lo que Pi-hole usa por debajo) soporta wildcard solo a nivel de zona (`address=/lan/192.168.1.10`). Esto se configura desde la UI v6 en **Settings → All settings → DNS records → Wildcard records**, o directamente en `/etc/pihole/pihole.toml`. El homelab usa **registros explícitos** porque permite documentar a posteriori qué subdominio existe (revisable desde la UI), y porque servicios en macvlan (Pi-hole en `192.168.1.241`) no apuntan a `192.168.1.10`. Un wildcard rompería esos casos.

> Cuando llegue [`04-caddy.md`](./04-caddy.md), este bloque se trasladará a un registro wildcard para `*.lan → 192.168.1.10` y se mantendrán como excepciones explícitas los servicios con IP propia (Pi-hole y Unbound en macvlan).

### 6.5. Apuntar el router a Pi-hole

En el panel del router doméstico, sección **DHCP** o **LAN setup**:

| Campo | Valor |
|---|---|
| DNS primario | `192.168.1.241` |
| DNS secundario | (vacío o `1.1.1.1`) — ver discusión más abajo |

Tras guardar, los clientes recogerán el nuevo DNS al **renovar el lease DHCP** (apagar/encender Wi-Fi, `dhclient -r && dhclient` en Linux, `ipconfig /release && /renew` en Windows). Validar con `nslookup pi-hole.net` desde un cliente cualquiera: debe aparecer `Server: 192.168.1.241`.

> **Sobre el DNS secundario**: hay dos escuelas:
> 1. **Vacío**: si Pi-hole cae, los clientes no resuelven nada. Notas inmediatamente que algo va mal y arreglas Pi-hole.
> 2. **`1.1.1.1` o el del router**: si Pi-hole cae, los clientes siguen resolviendo (sin filtro). Notas el fallo más tarde, pero la familia/operador no se queja a las 21:00 un domingo.
>
> Este homelab elige **(1) vacío**: el modelo "DNS centralizado" se asume conscientemente y Pi-hole se monitoriza con Uptime Kuma para detectar caídas en segundos. Quien no quiera ese trade-off puede poner el DNS del router como secundario y aceptar que algunas consultas no pasarán por Pi-hole cuando esté bajo presión.

### 6.6. Fallback DNS en el host (Pi)

La propia Pi necesita poder resolver nombres aunque Pi-hole esté caído (instalación de actualizaciones, `docker pull` de Watchtower, healthchecks de Tailscale...). Configurar **dos** servidores con el primero apuntando a Pi-hole y un segundo público externo.

#### Si la Pi usa **systemd-resolved** (Bookworm con NetworkManager por defecto)

```bash
sudo mkdir -p /etc/systemd/resolved.conf.d
sudo tee /etc/systemd/resolved.conf.d/homelab.conf > /dev/null <<'EOF'
[Resolve]
# Pi-hole primario, Cloudflare/Quad9 fallback.
DNS=192.168.1.241
FallbackDNS=1.1.1.1 9.9.9.9
# DNSSEC opcional; Pi-hole no firma respuestas, así que se desactiva.
DNSSEC=no
# Cache local (resolved ya cachea por defecto, pero explícito mejor).
Cache=yes
EOF

sudo systemctl restart systemd-resolved
resolvectl status | head -20
# Esperado:
#   Global
#       DNS Servers 192.168.1.241
#  Fallback DNS Servers 1.1.1.1 9.9.9.9
```

> `FallbackDNS` solo se usa cuando el `DNS` principal **no responde** en absoluto (timeouts continuos). Si Pi-hole responde con `NXDOMAIN`, `resolved` lo respeta y **no** consulta el fallback (es decir, los bloqueos siguen funcionando).

#### Si la Pi usa **resolvconf clásico** (`/etc/resolv.conf` editable)

NetworkManager y `dhcpcd` regeneran `/etc/resolv.conf` al renovar el lease. Para forzar Pi-hole, definirlo en el **propio router** (§6.5) y dejar que llegue por DHCP. Como fallback resiliente:

```bash
# /etc/dhcp/dhclient.conf (sustituir por la ruta del propio gestor)
prepend domain-name-servers 192.168.1.241;
```

o, en NetworkManager:

```bash
sudo nmcli con mod "Wired connection 1" ipv4.dns "192.168.1.241 1.1.1.1"
sudo nmcli con mod "Wired connection 1" ipv4.ignore-auto-dns yes
sudo nmcli con up "Wired connection 1"
```

Validar:

```bash
cat /etc/resolv.conf | grep nameserver
# Esperado:
# nameserver 192.168.1.241
# nameserver 1.1.1.1   (fallback)
```

> **Importante para el primer despliegue**: hasta que Pi-hole responda, el `nameserver 192.168.1.241` provoca timeouts. Mantener el nameserver público mientras se hace el primer `docker compose up` y trasladarlo a fallback solo cuando la UI responda.

---

## 7. Verificación

### 7.1. El contenedor está sano

```bash
docker compose -f ~/homelab/stacks/dns/docker-compose.yml ps
# Esperado: pihole  ...  Up X minutes (healthy)

docker inspect --format '{{.State.Health.Status}}' pihole
# Esperado: healthy
```

### 7.2. Resolución desde el host

```bash
# Pi-hole resuelve directamente.
dig +short @192.168.1.241 pi.hole
# Esperado: 192.168.1.241

# Resolución externa.
dig +short @192.168.1.241 pi-hole.net
# Esperado: una IP (4.x.x.x o similar).

# Bloqueo.
dig +short @192.168.1.241 doubleclick.net
# Esperado: 0.0.0.0   (gracias a las listas; vacío también es válido si la lista usa NXDOMAIN).
```

### 7.3. Resolución desde otro contenedor (red `homelab`)

```bash
docker run --rm --network homelab alpine:3.20 sh -c '
  apk add --no-cache bind-tools >/dev/null
  dig +short @pihole pi-hole.net
  dig +short @pihole doubleclick.net
'
# Esperado: una IP / 0.0.0.0
```

Esta prueba demuestra que **otros contenedores Docker** (Caddy, Prometheus, ...) podrán hablar con Pi-hole por su nombre `pihole` sobre la red `homelab`, sin pasar por la macvlan.

### 7.4. Resolución desde la LAN

Desde un cliente de la LAN (no la Pi):

```bash
nslookup google.com 192.168.1.241
# Server: 192.168.1.241
# ... respuestas no autoritativas
```

### 7.5. UI accesible

```bash
curl -sI http://192.168.1.241/admin/ | head -1
# Esperado: HTTP/1.1 200 OK  (o HTTP/1.1 302 Found, hacia /admin/login)
```

### 7.6. Persistencia tras reboot

```bash
sudo reboot
# (esperar a que vuelva)

docker compose -f ~/homelab/stacks/dns/docker-compose.yml ps
# pihole  ...  Up 1 minute (healthy)

dig +short @192.168.1.241 pi.hole
# 192.168.1.241
```

Pi-hole debe arrancar **sin intervención manual**. Si no, revisar:

- `lan-shim.service` (§8 de [`01-macvlan.md`](./01-macvlan.md)).
- `docker.service` (`systemctl is-enabled docker.service`).
- `restart: unless-stopped` no se reaplica si el contenedor fue parado a mano (`docker compose stop`); usar `docker compose up -d` tras arrancar manualmente.

### 7.7. Lista de Verificación

Antes de pasar a [`03-unbound.md`](./03-unbound.md):

- [ ] `docker compose -f ~/homelab/stacks/dns/docker-compose.yml ps` muestra `pihole` con estado `(healthy)`.
- [ ] `docker inspect pihole --format '{{.NetworkSettings.Networks.lan_macvlan.IPAddress}}'` devuelve `192.168.1.241`.
- [ ] `docker inspect pihole --format '{{.NetworkSettings.Networks.lan_macvlan.MacAddress}}'` devuelve `02:42:c0:a8:01:f1`.
- [ ] Desde la Pi: `ping -c 3 192.168.1.241` responde (vía `lan-shim`).
- [ ] Desde otro equipo de la LAN: `nslookup google.com 192.168.1.241` responde con IPs reales.
- [ ] Desde la Pi: `dig +short @192.168.1.241 doubleclick.net` devuelve `0.0.0.0` (o vacío) — confirma que `gravity` cargó listas.
- [ ] Desde un contenedor en red `homelab`: `dig +short @pihole pi-hole.net` responde.
- [ ] La UI responde en `http://192.168.1.241/admin/` y se entra con `PIHOLE_ADMIN_PASSWORD`.
- [ ] El router doméstico tiene `192.168.1.241` como DNS primario en su DHCP (verificable lanzando `ipconfig /all` o `nmcli dev show` desde un cliente).
- [ ] `/etc/systemd/resolved.conf.d/homelab.conf` (o equivalente) define `192.168.1.241` como DNS y un fallback público; `resolvectl status` lo refleja.
- [ ] `~/homelab/stacks/dns/.env.example` está versionado en git, `/mnt/hd2t/services/dns/.env` **no**.
- [ ] Tras un `sudo reboot`, todo lo anterior sigue cierto sin intervención.

---

## 8. Backup

Estrategia que se concretará en [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md). Lo que **debe respaldarse** del Pi-hole:

| Ruta | Qué contiene | Frecuencia recomendada |
|---|---|---|
| `/mnt/hd2t/services/dns/pihole/etc-pihole/pihole.toml` | Configuración principal (en v6 sustituye a `setupVars.conf` de v5). | Cada cambio (versionable a mano fuera del backup automático). |
| `/mnt/hd2t/services/dns/pihole/etc-pihole/gravity.db` | Listas combinadas de bloqueo. Reconstruible con `Update Gravity` en 1-3 min, pero respaldar evita el delta de adlists añadidas a mano. | Diaria. |
| `/mnt/hd2t/services/dns/pihole/etc-pihole/pihole-FTL.db` | Estadísticas y log de queries. **No es crítico** (recuperable significa "perder gráficas históricas"). | Semanal o excluir si pesa demasiado. |
| `/mnt/hd2t/services/dns/pihole/etc-pihole/dhcp.leases` | Solo si se activa Pi-hole DHCP (no es el caso de este homelab). | N/A. |
| `~/homelab/stacks/dns/docker-compose.yml` y `.env.example` | Configuración del stack. | Versionado en git → cubierto por `git push`. |
| `/mnt/hd2t/services/dns/.env` | Secretos (contraseña admin). | Cifrar y respaldar fuera del Borg principal: vivirá en Vaultwarden ([`../11-productividad/01-vaultwarden.md`](../11-productividad/01-vaultwarden.md)) cuando esté disponible. |

Pre-backup hook recomendado (Borgmatic):

```yaml
# Pseudo-config, la real va en 07-backups/02-borgmatic.md.
before_backup:
  - docker exec pihole pihole -a -t  # genera teleporter zip con backup completo
  - cp /mnt/hd2t/services/dns/pihole/etc-pihole/pi-hole_*.zip /mnt/hd2t/backups/dumps/pihole/
```

`pihole -a -t` crea un *teleporter export* (zip con todo: listas, config, registros locales, sesiones API). Restaurarlo es **una sola acción** desde la UI: **Settings → Teleporter → Restore**.

---

## 9. Solución de Problemas

| Síntoma | Causa probable | Acción |
|---|---|---|
| `docker compose up` falla con `network lan_macvlan declared as external, but could not be found` | La red macvlan no se creó o se borró. | Volver a [`01-macvlan.md`](./01-macvlan.md) §4.2 y recrearla. Verificar después con `docker network inspect lan_macvlan`. |
| `docker compose up` falla con `Address already in use 192.168.1.241` | Otro contenedor o un dispositivo físico de la LAN está usando la IP. | `docker network inspect lan_macvlan` para ver qué contenedor; en la LAN, `arp -a 192.168.1.241` desde otro equipo. Resolver el conflicto antes de relanzar. |
| El contenedor arranca pero queda `unhealthy` y `docker logs pihole` muestra `Failed to bind to 0.0.0.0:53` | Ya hay algo escuchando `:53` **dentro del contenedor** (raro), o las capabilities recortaron la posibilidad de bindar puertos privilegiados. | Asegurarse de que `cap_add` incluye `NET_BIND_SERVICE`. Si se eliminó `cap_drop ALL` por experimento, restaurarlo + el `cap_add` enumerado. |
| Desde la propia Pi `dig @192.168.1.241 ...` da timeout, pero **otros equipos de la LAN** sí resuelven | Es el síntoma típico de "lan-shim caída". | `systemctl status lan-shim.service`; revisar §5.2 y §8 de [`01-macvlan.md`](./01-macvlan.md). |
| Desde la LAN no resuelve nada y `docker logs pihole` muestra `FTL is starting up` indefinidamente | Pi-hole está reconstruyendo `gravity.db` por primera vez (puede tardar 1–3 min con HD2T USB 3.0). | Esperar; si pasados 5 min sigue sin servir, revisar permisos de `/mnt/hd2t/services/dns/pihole/etc-pihole/` (debe ser `homelab:homelab`, `750`). |
| La UI da `403 / Unauthorized` aunque la contraseña es correcta | En v6, las sesiones se guardan en `pihole.toml`. Si el password se cambió por env y luego por UI, ambos quedan desincronizados. | Editar `/mnt/hd2t/services/dns/.env` con la contraseña deseada y `docker compose up -d --force-recreate pihole`; el env tiene precedencia. |
| Pi-hole resuelve nombres internos (`pihole`, `pi.hole`) pero falla en externos | El upstream (`PIHOLE_UPSTREAMS`) no responde. | Si está en bootstrap y aún se usa `1.1.1.1;9.9.9.9`: probar `dig @1.1.1.1 pi-hole.net` desde la Pi; si falla, hay un problema de salida a internet (ufw, ruta por defecto, ISP). Si está en producción con `192.168.1.242#5335`: revisar que Unbound esté `(healthy)`. |
| `/etc/resolv.conf` del **host** queda en `192.168.1.127` (loopback de systemd-resolved) y nunca pregunta a Pi-hole | systemd-resolved usa el stub local; las consultas SÍ van a Pi-hole pero por DBus. Mirar `resolvectl query pi-hole.net` en lugar de `dig @127.0.0.53`. | Es comportamiento normal. Para auditar el DNS efectivo: `resolvectl status` (apartado `Current DNS Server`). |
| Tras reboot, Pi-hole arranca **antes** que `lan-shim` y queda sin red | `Requires=docker.service` está en el unit del shim, pero Docker tarda en levantar la red. | El `restart: unless-stopped` reintenta el contenedor: a la segunda iteración, la red ya existe. Si el patrón se repite, añadir `After=lan-shim.service` al `docker.service` editando un drop-in en `/etc/systemd/system/docker.service.d/` (no recomendado: invasivo). |
| `docker compose up -d --force-recreate pihole` recrea **también** `dns_internal` y borra a Unbound (cuando exista) | `--force-recreate` por defecto solo afecta al servicio nombrado, **no** a las redes. | Confirmar que se está usando `docker compose ... up -d --force-recreate pihole` (servicio) y no `--force-recreate` solo (sin servicio), que sí recrea todo el stack. |
| La UI muestra `0` queries por segundo aunque hay tráfico DNS desde la LAN | El contenedor está en `lan_macvlan` con `FTLCONF_dns_listeningMode=local`, no `ALL`. | Cambiar a `ALL` en el `.env` (mismo nombre interno) o directamente en la UI: **Settings → DNS → Interface settings**. Reiniciar Pi-hole. |
| `gravity update` falla con `cannot allocate memory` | La Pi 5 con 8 GB tiene swap en hd2t (ver [`../01-sistema/02-configuracion-inicial.md`](../01-sistema/02-configuracion-inicial.md) §7), pero `swappiness=10` puede no ser suficiente al combinar con Jellyfin transcoding o similar. | Para una `gravity update` puntual, parar contenedores pesados antes (`docker compose stop jellyfin transmission ...`), ejecutar `docker exec pihole pihole -g`, y reanudar. |
| Pi-hole bloquea dominios "que no debería" (Discord, Microsoft, etc.) | Listas demasiado agresivas. | Añadir el dominio en **Domains → Allow exact / Allow regex**. Documentar la excepción en este propio doc o en una nota lateral. |
| Tras `docker compose down`, `docker network ls` muestra `dns_dns_internal` huérfana | `down` por defecto borra contenedores y la red **autogestionada** del stack, pero no elimina el bridge si quedan refs. | `docker compose down --remove-orphans` o, en último caso, `docker network rm dns_dns_internal`. La red se recreará al siguiente `up`. |
| La MAC del contenedor cambia tras un upgrade y la reserva DHCP del router deja de funcionar | El operador olvidó incluir `mac_address: '02:42:c0:a8:01:f1'` al recrear. | Revisar el `docker-compose.yml`: la línea `mac_address:` **debe** estar dentro del bloque de la red `lan_macvlan`. |

---

## Referencias

- [Pi-hole — Documentación oficial Docker (v6)](https://docs.pi-hole.net/docker/)
- [Pi-hole — Configuración (FTLCONF, capabilities)](https://docs.pi-hole.net/docker/configuration/)
- [Pi-hole — Note on Watchtower](https://docs.pi-hole.net/docker/tips-and-tricks/#note-on-watchtower)
- [Pi-hole — Network-wide setup (apuntar el router a Pi-hole)](https://docs.pi-hole.net/main/post-install/#network-wide-protection)
- [Pi-hole — Migración v5 → v6 (`pihole.toml`, FTLCONF_*)](https://docs.pi-hole.net/v6/)
- [pi-hole/docker-pi-hole — README oficial](https://github.com/pi-hole/docker-pi-hole)
- [Docker — Macvlan + IPv4 estática (`ipv4_address`, `mac_address`)](https://docs.docker.com/reference/compose-file/services/#networks)
- [Docker Compose — Healthchecks](https://docs.docker.com/reference/compose-file/services/#healthcheck)
- [systemd-resolved — `DNS=`, `FallbackDNS=`, `DNSSEC=`](https://www.freedesktop.org/software/systemd/man/resolved.conf.html)
- [StevenBlack — Hosts file](https://github.com/StevenBlack/hosts)
- [OISD — Block lists](https://oisd.nl/)
- [HaGeZi — DNS blocklists](https://github.com/hagezi/dns-blocklists)
