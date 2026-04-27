# Tailscale (VPN mesh + acceso remoto seguro)

## Descripción

Despliegue de **Tailscale** como **VPN _mesh_** del homelab para acceder a los servicios desde fuera de la LAN doméstica **sin abrir puertos en el router**, sin DDNS y sin exponer nada a internet. Tailscale construye una red _overlay_ basada en **WireGuard** entre todos los dispositivos del operador (la Pi, su portátil, su móvil, una segunda casa, …) y les asigna IPs estables del rango `100.64.0.0/10` ("CGNAT _tailnet_"); la conectividad es _peer-to-peer_ siempre que la NAT lo permite y, si no, _relay_ por los servidores DERP de la propia Tailscale (cifrado de extremo a extremo en cualquier caso). Asume las decisiones tomadas en `docs/03-red/01-macvlan.md`, `docs/03-red/02-pihole.md`, `docs/03-red/03-unbound.md` y `docs/03-red/04-caddy.md`: la Pi vive en `192.168.1.3`, Caddy ya escucha `:80` y `:443` sobre esa IP con `tls internal`, Pi-hole resuelve `*.lan → 192.168.1.3`. Tailscale añade un segundo plano de acceso (`pi.<TAILNET>.ts.net` y, vía _split DNS_, los mismos `*.lan` desde fuera de casa).

Este documento **no añade un servicio Docker más al _stack_ `red`**: Tailscale se instala como **paquete nativo en la Pi** (`tailscaled` como _systemd unit_). La razón se explica en **Decisiones de diseño**. Lo que sí toca este documento es:

- El _stack_ `red` ya existente: Caddy se actualiza para bindear sus puertos también a la IP del _tailnet_ (`100.x.y.z`) y para servir un nuevo bloque `pi.<TAILNET>.ts.net` con cert público de Tailscale.
- Los ficheros `~/homelab/red/.env` y `~/homelab/red/.env.example`: se rellena `TAILNET` y se añade `TAILSCALE_IPV4`.
- Se añade un par `tailscale-cert.service` + `tailscale-cert.timer` (systemd) para renovar el certificado de `pi.<TAILNET>.ts.net` automáticamente.

> **Alcance**: este documento despliega Tailscale, configura **MagicDNS + _split DNS_** para que los clientes resuelvan tanto `pi.<TAILNET>.ts.net` (cert público) como `*.lan` (cert de la CA local) cuando están fuera de casa, y conecta el _daemon_ con Caddy para HTTPS. **No** publica el _tailnet_ a internet, **no** activa _Tailscale Funnel_, **no** anuncia rutas de subred (`--advertise-routes=192.168.1.0/24`) y **no** sustituye Pi-hole — la Pi sigue resolviendo DNS por Pi-hole. La gestión de ACLs avanzadas (`docs/04-seguridad/`) y la integración con Authelia (`docs/04-seguridad/01-authelia.md`) quedan para sus respectivas fases.

> **Recordatorio de red**: el homelab vive en LAN + Tailscale. Tailscale **no abre puertos en el router**: el _daemon_ inicia una conexión saliente UDP `41641/udp` (NAT _hole punching_) o, si la NAT es estricta, _relay_ TCP `443/tcp` contra los DERP. El operador no toca la configuración del router.

---

## Requisitos previos

- `docs/03-red/01-macvlan.md` completado: red `lan` macvlan creada, IP `192.168.1.3` reservada en el DHCP del router, _shim_ `macvlan-shim` activo.
- `docs/03-red/02-pihole.md` completado: Pi-hole en `192.168.1.2`, _stack_ `red` (`~/homelab/red/`) en marcha, `02-homelab-local.conf` con `address=/lan/192.168.1.3`.
- `docs/03-red/03-unbound.md` completado: Unbound en `192.168.1.4#5335` resolviendo recursivamente para Pi-hole.
- `docs/03-red/04-caddy.md` completado: Caddy escucha en `192.168.1.3:443` con CA local, el bloque `{$TAILSCALE_HOSTNAME}.{$TAILNET}.ts.net` está presente **comentado** y los _snippets_ `security-headers.caddy` y `logging.caddy` ya existen.
- `docs/01-sistema/03-seguridad-base.md` completado: `nftables` con `input drop` por defecto y reglas de _allow_ explícitas para el rango Tailscale (`100.64.0.0/10`) sobre `tcp/80`, `tcp/443` y `udp/443`. Si alguna falta, añadirla **antes** de Tailscale (no es estrictamente necesaria para que el _daemon_ funcione — Tailscale crea su propia interfaz `tailscale0` y la inserta en la cadena `input` de `iptables`/`nftables` automáticamente — pero es lo que abrirá los puertos de Caddy a los _peers_):

  ```bash
  sudo nft add rule inet filter input ip saddr 100.64.0.0/10 tcp dport {80, 443} accept
  sudo nft add rule inet filter input ip saddr 100.64.0.0/10 udp dport 443         accept
  ```

  Persistirlas en `/etc/nftables.conf` (ver `docs/01-sistema/03-seguridad-base.md`).

- Cuenta de **Tailscale** creada (gratuita, plan _Personal_ hasta 100 dispositivos): <https://login.tailscale.com>. El plan _Personal_ basta para todo lo que hace este homelab.
- Conectividad saliente desde la Pi: `curl -fsSL https://pkgs.tailscale.com/stable/raspbian/bookworm.noarmor.gpg >/dev/null && echo OK` debe funcionar (Raspberry Pi OS Lite 64-bit declarado en `docs/01-sistema/01-instalacion-os.md` deriva de Debian Bookworm).
- Hostname de la Pi configurado a `pi` (o el valor que se prefiera) en `docs/01-sistema/02-configuracion-inicial.md`. Tailscale toma ese hostname como nombre del nodo en el _tailnet_; cambiarlo después implica desautorizar y re-autorizar.
- Reloj del sistema sincronizado por NTP (`timedatectl status` con `System clock synchronized: yes`). Tailscale rechaza handshakes con `clock skew > 30 s`.

---

## Decisiones de diseño

### Tailscale en el host, no en un contenedor

Tailscale ofrece imagen oficial Docker (`tailscale/tailscale`) con _userspace networking_. Aquí se descarta a favor del paquete nativo (`tailscaled` por systemd) por cuatro razones concretas:

| Aspecto | Host (elegido) | Contenedor |
|---|---|---|
| **Acceso a `:80`/`:443` de Caddy** | Caddy bindea en el host directamente a `100.x.y.z` (el daemon expone la IP en la interfaz `tailscale0`). Una sola línea en `ports:`. | Habría que enrutar el tráfico desde la _userspace stack_ del contenedor Tailscale al contenedor Caddy con `serve` o un sidecar. Frágil. |
| **`tailscale cert`** | Escribe en `/var/lib/tailscale/certs/pi.<tailnet>.ts.net.{crt,key}` directamente en el _filesystem_ del host. Caddy lo monta _read-only_ con un _bind mount_ trivial. | El cert vive dentro del volumen del contenedor; hay que compartirlo entre dos contenedores con permisos correctos, y el _renewer_ que se monta más abajo necesita `docker exec`. |
| **MagicDNS para el host** | Tailscale modifica `/etc/resolv.conf` (opt-in) para que la propia Pi resuelva `<peer>.<tailnet>.ts.net`. Útil para `ping portatil` desde la Pi. | El host no se beneficia: sólo el contenedor recibe MagicDNS. |
| **Subnet routing** | Si en el futuro se decide anunciar `192.168.1.0/24` por Tailscale (no se hace en este doc), basta `tailscale up --advertise-routes=192.168.1.0/24`. | Requiere `cap_add: NET_ADMIN`, `sysctls: net.ipv4.ip_forward=1`, network mode `host`… acaba siendo más sucio que el host. |

La instalación nativa pesa ~30 MB y arranca en segundos. No hay justificación técnica para meterlo en Docker en este escenario.

> **Excepción**: si el día de mañana el homelab corriera **dos** _tailnets_ a la vez (p. ej. uno personal + uno de trabajo), el contenedor Tailscale por _tailnet_ es la única forma limpia de aislarlos. No es el caso.

### MagicDNS + _split DNS_ (no se reemplaza Pi-hole)

Tailscale tiene su propio resolver embebido (MagicDNS) que asigna nombres `<device>.<tailnet>.ts.net` a cada nodo. Por defecto, cuando un cliente Tailscale se autoriza con `--accept-dns=true`, su `/etc/resolv.conf` (o equivalente) se sobrescribe para apuntar a `100.100.100.100` (el resolver de Tailscale).

La Pi **no** acepta el DNS de Tailscale (`tailscale up --accept-dns=false`):

- El host de la Pi es el **único** dispositivo de la LAN que necesita resolver `*.lan` por sí mismo (cuando el operador hace `ssh` a la Pi y lanza `curl https://pihole.lan/`). Para ese caso ya funciona el `/etc/resolv.conf` de `docs/01-sistema/02-configuracion-inicial.md`, que apunta a `192.168.1.2` (Pi-hole) con _fallback_ a `1.1.1.1`.
- Si la Pi aceptara el DNS de Tailscale, el _bootstrap_ de los contenedores en `~/homelab/red/` rompería: Pi-hole intenta arrancar, pregunta a `100.100.100.100`, el _daemon_ todavía no está corriendo y el _stack_ entra en un bucle de fallos.

Los **clientes remotos** (portátil, móvil) **sí** aceptan el DNS de Tailscale (`--accept-dns=true`, valor por defecto):

- Resuelven `pi.<TAILNET>.ts.net` directamente por MagicDNS (sin tocar nada).
- Para que también resuelvan `pihole.lan`, `portainer.lan`, etc., se configura **_Split DNS_** en el _admin console_ de Tailscale: la zona `lan` se delega al **resolver Pi-hole** (`192.168.1.2#53`). Tailscale enruta esas consultas por el _tailnet_ hasta la Pi y de ahí a Pi-hole. El operador, fuera de casa, escribe `https://portainer.lan/` en el navegador y todo "simplemente funciona".

> **Por qué `lan` y no `homelab.lan`**: el wildcard de Pi-hole (`02-homelab-local.conf`) ya cubre `lan` entera. _Split DNS_ delega zonas, no _wildcards_; delegar la zona padre `lan` cubre todo lo que Pi-hole resuelve.

> **Latencia añadida**: una consulta DNS desde el portátil remoto va `cliente → DERP → Pi → Pi-hole → Unbound`. Son ~80–150 ms en lugar de 1–5 ms. Aceptable porque las cachés de los _stub resolvers_ (sistema operativo + navegador) absorben la mayoría de las consultas repetidas. Si se notara lento, una alternativa es activar `--accept-routes` en los clientes y dejar que Pi-hole se acceda directo por su `192.168.1.2`, pero eso requiere `--advertise-routes=192.168.1.0/24` en la Pi, que es una superficie de ataque mayor.

### `tailscale cert` para `pi.<TAILNET>.ts.net` (Let's Encrypt vía Tailscale)

Tailscale es la _autoridad_ de la zona `<tailnet>.ts.net`. Cuando el operador habilita "HTTPS Certificates" en el _admin console_, el _daemon_ puede pedir certificados **válidos públicamente** a Let's Encrypt usando el _challenge DNS-01_ contra los registros que Tailscale controla. El comando `tailscale cert pi.<TAILNET>.ts.net` produce:

```
/var/lib/tailscale/certs/pi.<TAILNET>.ts.net.crt
/var/lib/tailscale/certs/pi.<TAILNET>.ts.net.key
```

Caddy los monta _read-only_ y los usa con `tls /etc/caddy/tailscale-cert.crt /etc/caddy/tailscale-cert.key`. Un navegador en cualquier dispositivo (incluso uno que **no** tenga la _root CA_ del homelab importada) ve el candado verde sin _warnings_.

**Pero `tailscale cert` sólo emite para el hostname exacto del dispositivo**, no para subdominios arbitrarios. Es decir: `pi.<TAILNET>.ts.net` ✅, `pihole.<TAILNET>.ts.net` ❌, `pihole.pi.<TAILNET>.ts.net` ❌. El bloque preparado en `docs/03-red/04-caddy.md` que usaba `pihole.{$TAILSCALE_HOSTNAME}.{$TAILNET}.ts.net` se **corrige aquí**: el bloque queda como un único `pi.<TAILNET>.ts.net` con un dashboard simple (o, en el futuro, Homepage — `docs/12-dashboards/01-homepage.md`).

Para acceder a los servicios individuales por su `*.lan` desde fuera de casa basta con _split DNS_ (anterior) y tener la **CA local importada en el cliente** (`docs/03-red/04-caddy.md`, sección **Confianza en la CA local**). Combinación elegida:

| Ruta de acceso | DNS resuelve | Cert | Necesita CA local importada |
|---|---|---|---|
| `https://pi.<TAILNET>.ts.net/` | MagicDNS (Tailscale) | Let's Encrypt vía Tailscale | No |
| `https://pihole.lan/` desde casa | Pi-hole (`*.lan → 192.168.1.3`) | CA local (`tls internal`) | Sí |
| `https://pihole.lan/` desde fuera | _Split DNS_ Tailscale → Pi-hole | CA local (`tls internal`) | Sí |

La importación de la CA local sigue siendo de un solo paso por dispositivo (ya documentado en Caddy); a cambio, no hay que pagar un dominio público ni meter en juego Let's Encrypt para más de un nombre.

> **Renovación**: `tailscale cert` renueva _on demand_ a partir de los 14 días previos a la caducidad (cert de 90 días). No hay un _hook_ automático: hay que llamarlo periódicamente. Este doc añade un `tailscale-cert.timer` (systemd) que lo ejecuta cada 24 h. El comando es idempotente: si el cert tiene >14 días de vida, no hace nada; si tiene ≤14 días, lo renueva.

### `tag:homelab` y _auth keys_ pre-autorizadas

Por defecto, los nodos Tailscale **caducan a los 180 días** y exigen volver a autorizarlos (re-login interactivo). En un homelab _headless_ eso es inaceptable: la Pi se queda sin acceso remoto sin previo aviso.

Solución oficial de Tailscale: **etiquetar el nodo** (`tag:homelab`). Los nodos etiquetados:

- **No caducan** (sin re-autorización periódica).
- Se autorizan con una _auth key_ pre-generada (sin browser, sin OAuth interactivo) — perfecto para arranque _headless_.
- Quedan asociados a una _identidad de máquina_, no al usuario. Los logs de auditoría reflejan "tag:homelab" en lugar del email personal.

Configurar el `tag:homelab` en el _admin console_ requiere editar el ACL (que se introduce en este mismo doc, sección **Preparación del _admin console_**).

### Sin _subnet routes_, sin _exit node_, sin _Funnel_

Decisiones por omisión, pero conviene explicitarlas:

- **`--advertise-routes`** (publicar `192.168.1.0/24` por Tailscale): **NO**. Si se activara, un cliente Tailscale comprometido tendría acceso a toda la LAN doméstica, incluido el router y los IoT que no deberían estar expuestos. La Pi como único punto de entrada vía Caddy es una _attack surface_ mucho más estrecha. Si el día de mañana hace falta acceder al router por SSH desde fuera, se reabre el debate.
- **`--advertise-exit-node`** (usar la Pi como salida a internet de los clientes Tailscale): **NO**. La Pi tiene una conexión doméstica residencial; no es un buen _exit node_ y no aporta privacidad (el ISP lo ve igual). Tailscale ya ofrece su propia función _exit node_ vía nodos de pago si se necesita.
- **Tailscale Funnel** (publicar un servicio del _tailnet_ a internet abierto): **NO**. El homelab no debe ser accesible desde internet. _Funnel_ es la antítesis de lo que se está construyendo.

### Almacenamiento

| Ruta en el host | Contenido | Backup |
|---|---|---|
| `/var/lib/tailscale/tailscaled.state` | Clave WireGuard del nodo, ACLs cacheadas, _peers_ conocidos | Sí (Borgmatic, ver `docs/07-backups/02-borgmatic.md`) |
| `/var/lib/tailscale/certs/` | `pi.<TAILNET>.ts.net.crt` + `.key` | No (regenerable con `tailscale cert`) |
| `/etc/systemd/system/tailscaled.service.d/override.conf` | _Drop-in_ con flags persistentes (si los hubiera) | Sí (vía git en el dotfile-repo del operador, fuera de este repo) |
| `/etc/systemd/system/tailscale-cert.{service,timer}` | Renovación del cert | Sí (vía git) |

`/var/lib/tailscale/tailscaled.state` es lo importante. Si se pierde, la Pi se da de baja del _tailnet_ sin _grace period_ y hay que volver a autenticar; los demás dispositivos también la verán como "nuevo nodo" hasta refrescar. Backup obligatorio. La clave privada está cifrada en reposo desde Tailscale 1.62; aun así, en Borgmatic se respalda dentro del _archive_ cifrado por _passphrase_ (defensa en profundidad).

---

## Preparación del _admin console_ de Tailscale

Pasos a hacer **antes** de tocar la Pi, en <https://login.tailscale.com/admin/>.

### 1. Habilitar MagicDNS y HTTPS Certificates

- **DNS** → **Nameservers**: dejar el _default_ "Magic DNS" en `ON`.
- **DNS** → **HTTPS Certificates**: pulsar **Enable HTTPS**. Tailscale crea automáticamente los registros DNS necesarios para que Let's Encrypt valide `*.<TAILNET>.ts.net` por DNS-01. Esta opción es _one-way_ (no se desactiva sin contactar soporte); es segura.

### 2. Definir el `tag:homelab` en el ACL

**Access Controls** → editar el _policy file_ (HuJSON). Añadir o ampliar:

```hujson
{
  // Tags disponibles en este tailnet. El owner es el usuario admin del tailnet
  // (sustituir 'usuario@ejemplo.com' por el email real del propietario).
  "tagOwners": {
    "tag:homelab": ["usuario@ejemplo.com"],
  },

  // ACL por defecto: el usuario propietario puede llegar a todo lo suyo
  // (incluidos nodos tag:homelab). Se puede endurecer en docs/04-seguridad/.
  "acls": [
    { "action": "accept", "src": ["usuario@ejemplo.com"], "dst": ["*:*"] },
  ],

  // Deshabilitar Tailscale SSH globalmente (la Pi ya tiene OpenSSH endurecido
  // en docs/01-sistema/03-seguridad-base.md; no queremos un segundo plano de
  // login sin auditoría de fail2ban).
  "ssh": [],
}
```

> **Sintaxis HuJSON**: el _admin console_ permite comentarios y trailing commas. El validador integrado avisa antes de guardar.

### 3. Generar una _auth key_ pre-autorizada para la Pi

**Settings** → **Keys** → **Generate auth key**. Configuración:

| Campo | Valor |
|---|---|
| Description | `pi-homelab` |
| Reusable | **OFF** (un solo uso) |
| Ephemeral | **OFF** (la Pi es un nodo permanente) |
| Pre-approved | **ON** |
| Tags | `tag:homelab` |
| Expiration | 90 días (recomendado) |

Pulsar **Generate key**. Tailscale muestra una clave `tskey-auth-...` **una sola vez**. Copiarla a un sitio seguro (gestor de contraseñas) — se usará en el siguiente paso y luego se descarta. Si se pierde, se puede generar otra; las claves antiguas se revocan desde la misma pantalla.

> **No** _commitear_ la _auth key_ a git **ni siquiera al repo privado**. La _auth key_ vale para autorizar nodos en el _tailnet_; un atacante con acceso al repo podría dar de alta una máquina suya etiquetada como `tag:homelab`.

### 4. Configurar _Split DNS_ para la zona `lan`

**DNS** → **Search Domains / Restricted nameservers** → **Add nameserver** → **Restrict to domain**:

- **Domain**: `lan`
- **Nameserver**: `192.168.1.2` (la IP macvlan de Pi-hole — `docs/03-red/02-pihole.md`)

Guardar. Tailscale entregará a cualquier cliente Tailscale conectado al _tailnet_ una entrada de _split DNS_ que delega `lan` a Pi-hole. Las consultas de `pihole.lan`, `portainer.lan`, etc., desde el portátil remoto irán por el _overlay_ Tailscale hasta la Pi.

> **Verificación posterior** (cuando la Pi ya esté conectada): desde el portátil remoto, `tailscale status` muestra `pi` con su IP `100.x.y.z`, y `dig portainer.lan +short` devuelve `192.168.1.3`.

---

## Instalación en la Pi

### Repositorio APT oficial

Tailscale publica un repo APT con clave GPG firmada para Debian Bookworm (la base de Raspberry Pi OS Lite 64-bit, `docs/01-sistema/01-instalacion-os.md`). Se añade el _keyring_ y el _source_ a la Pi:

```bash
# Añadir clave GPG (formato dearmored, recomendado por Debian moderna)
curl -fsSL https://pkgs.tailscale.com/stable/raspbian/bookworm.noarmor.gpg | \
    sudo tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
sudo chmod 0644 /usr/share/keyrings/tailscale-archive-keyring.gpg

# Añadir source
curl -fsSL https://pkgs.tailscale.com/stable/raspbian/bookworm.tailscale-keyring.list | \
    sudo tee /etc/apt/sources.list.d/tailscale.list >/dev/null

sudo apt update
sudo apt install -y tailscale
```

Verificar versión y arquitectura:

```bash
tailscale version
# 1.78.x o superior
#   tailscale commit: ...
#   other commit: ...
#   xcode: gomod, redo, ...
dpkg --print-architecture   # arm64
```

> **Por qué APT y no `curl ... | sh`**: el _installer_ universal de Tailscale (`curl -fsSL https://tailscale.com/install.sh | sh`) hace _exactamente_ lo de arriba (añadir el repo APT y `apt install`), pero opaco. Hacerlo a mano deja huella reproducible y compatible con `unattended-upgrades` (`docs/01-sistema/03-seguridad-base.md`), que actualizará Tailscale como un paquete más.

### Habilitar el _daemon_

```bash
sudo systemctl enable --now tailscaled
sudo systemctl status tailscaled --no-pager
# Active: active (running)
```

`tailscaled` está corriendo pero el nodo aún **no** está autorizado en el _tailnet_. La interfaz `tailscale0` no tiene IP todavía:

```bash
ip -br addr show tailscale0
# tailscale0       UNKNOWN
```

### Autorizar la Pi con la _auth key_

```bash
sudo tailscale up \
    --authkey="tskey-auth-XXXXXXXXXX" \
    --hostname="pi" \
    --advertise-tags=tag:homelab \
    --accept-dns=false \
    --accept-routes=false \
    --ssh=false \
    --shields-up=false
```

Significado de cada flag:

| Flag | Por qué |
|---|---|
| `--authkey=` | _Auth key_ del paso anterior. Si se omite, `tailscale up` abre una URL de auth interactiva — inviable _headless_. |
| `--hostname=pi` | Nombre del nodo en el _tailnet_. Coincide con el hostname del SO (`docs/01-sistema/02-configuracion-inicial.md`). MagicDNS publica `pi.<TAILNET>.ts.net`. |
| `--advertise-tags=tag:homelab` | Etiqueta del nodo. Combinada con `tagOwners` del ACL, evita la caducidad a 180 días. |
| `--accept-dns=false` | La Pi **no** usa MagicDNS como su resolver — sigue resolviendo por Pi-hole + _fallback_. Ver **Decisiones de diseño**. |
| `--accept-routes=false` | La Pi **no** acepta _subnet routes_ anunciadas por otros nodos. Ningún _peer_ debería estar anunciando subredes que se solapen con `192.168.1.0/24`; aceptarlas rompería _routing_ local. |
| `--ssh=false` | No abrir Tailscale SSH (`docs/01-sistema/03-seguridad-base.md` ya cubre SSH con OpenSSH + fail2ban). Coherente con el ACL `"ssh": []`. |
| `--shields-up=false` | Permitir conexiones entrantes desde otros nodos del _tailnet_ (lo que necesitamos para que el portátil hable con `:443` de la Pi). `--shields-up=true` sería el equivalente a un firewall que sólo permite tráfico saliente. |

Salida esperada:

```
Success.
```

Y la interfaz ahora tiene IP:

```bash
ip -br addr show tailscale0
# tailscale0       UNKNOWN        100.x.y.z/32 fd7a:...

tailscale ip --4
# 100.x.y.z

tailscale status
# 100.x.y.z       pi                   usuario@ linux   -
# (otros peers)
```

> **Anota la IPv4 del _tailnet_**: se necesita para `TAILSCALE_IPV4` en el `.env` de Caddy y para los comandos de verificación.

### Persistir las flags en `tailscaled` (drop-in)

`tailscale up` guarda las opciones en `/var/lib/tailscale/tailscaled.state` y las re-aplica en cada arranque. **No** hace falta un `Drop-in` de systemd con flags. Si en el futuro hace falta cambiar alguna opción (p. ej. anunciar una _route_), basta con repetir `sudo tailscale up --...` con las flags nuevas.

> **Importante**: cada `tailscale up` **sustituye** todas las flags. Si un día se ejecuta `sudo tailscale up --advertise-tags=tag:homelab` sin repetir `--ssh=false`, Tailscale SSH se reactiva por defecto. Mantener el comando completo en una nota interna o en un script versionable.

### Eliminar la _auth key_ del histórico de shell

```bash
history -d "$(history | grep -n 'tskey-auth' | tail -1 | cut -d: -f1)"  # zsh/bash
unset HISTFILE && exit  # alternativa: cerrar la sesión sin escribir history
```

Y **revocar la _auth key_** desde el _admin console_ (era de un solo uso, ya consumida — Tailscale la marca como _used_; revocarla por higiene).

---

## Generar el certificado de Let's Encrypt vía Tailscale

Con MagicDNS y HTTPS habilitados en el _admin console_, el _daemon_ puede pedir el cert. El primer despliegue se hace a mano para detectar problemas en caliente:

```bash
# Sustituir <TAILNET> por el nombre real (visible en 'tailscale status' o en
# el admin console; típicamente 'tail1234.ts.net' si no se renombró).
sudo tailscale cert pi.<TAILNET>.ts.net
# Wrote /var/lib/tailscale/certs/pi.<TAILNET>.ts.net.crt
# Wrote /var/lib/tailscale/certs/pi.<TAILNET>.ts.net.key
```

Permisos del directorio:

```bash
sudo ls -la /var/lib/tailscale/certs/
# drwx------ 2 root root  ...  ./
# -rw------- 1 root root  ...  pi.<TAILNET>.ts.net.crt
# -rw------- 1 root root  ...  pi.<TAILNET>.ts.net.key
```

> **Modo `0700` y `0600`**: por defecto Tailscale crea el directorio sólo legible por root. Caddy corre como root dentro del contenedor (ver `docs/03-red/04-caddy.md`, **Almacenamiento**), así que un _bind mount_ `:ro` lo lee sin tocar permisos. **No** cambiar permisos a `0644` o similares: la clave privada del cert es sensible.

Verificar el cert con OpenSSL:

```bash
sudo openssl x509 -in /var/lib/tailscale/certs/pi.<TAILNET>.ts.net.crt -noout \
                  -subject -issuer -dates -ext subjectAltName
# subject = CN = pi.<TAILNET>.ts.net
# issuer  = C = US, O = Let's Encrypt, CN = E5
# notBefore=...
# notAfter=...   ← 90 días desde notBefore
# X509v3 Subject Alternative Name:
#   DNS:pi.<TAILNET>.ts.net
```

> **Sólo un SAN**: confirma lo dicho en **Decisiones de diseño** — Tailscale no emite certs para subdominios. Los `*.lan` siguen yendo por la CA interna de Caddy.

---

## Renovación automática del cert (systemd timer)

`tailscale cert` no tiene daemon de renovación. El doc añade dos units mínimas:

### `/etc/systemd/system/tailscale-cert.service`

```ini
[Unit]
Description=Renovar certificado pi.<TAILNET>.ts.net (Tailscale + Let's Encrypt)
Documentation=docs/03-red/05-tailscale.md
Wants=tailscaled.service
After=tailscaled.service network-online.target
Requires=network-online.target

[Service]
Type=oneshot
# Sustituir <TAILNET> por el real (o leerlo de un EnvironmentFile).
ExecStart=/usr/bin/tailscale cert pi.<TAILNET>.ts.net
# Tras renovar, recargar Caddy in-place para que lea el nuevo cert sin downtime.
ExecStartPost=/usr/bin/docker exec caddy caddy reload --config /etc/caddy/Caddyfile
# El comando es idempotente: Tailscale renueva sólo si quedan <14 días de vida.
SuccessExitStatus=0
# Endurecimiento mínimo
ProtectSystem=strict
ReadWritePaths=/var/lib/tailscale/certs
PrivateTmp=true
NoNewPrivileges=true
```

> **Substituir `<TAILNET>`**: editar el fichero antes de habilitarlo. Para evitarlo, se puede cargar `TAILNET` desde `/etc/default/tailscale-cert` con `EnvironmentFile=` y usar `${TAILNET}`; queda así por simplicidad. Si el _tailnet_ cambia (renombrado en el _admin console_), tocar el fichero.

### `/etc/systemd/system/tailscale-cert.timer`

```ini
[Unit]
Description=Renovar cert de Tailscale cada día (idempotente)
Documentation=docs/03-red/05-tailscale.md

[Timer]
# Una vez al día a las 04:30 (offset aleatorio de hasta 30 min para evitar
# tormentas en la API de Tailscale si todos los homelabs corrieran a la vez).
OnCalendar=*-*-* 04:30:00
RandomizedDelaySec=1800
Persistent=true
Unit=tailscale-cert.service

[Install]
WantedBy=timers.target
```

Habilitar:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now tailscale-cert.timer
sudo systemctl list-timers --all | grep tailscale-cert
# tailscale-cert.timer  ...  active
sudo systemctl start tailscale-cert.service   # disparar una primera vez para verificar
sudo journalctl -u tailscale-cert.service --no-pager | tail -20
# 'Already have a valid cert' (si <14 días desde la creación) o 'Wrote ...'
```

> **Por qué diaria y no semanal**: la renovación cuesta ~2 s y es _no-op_ el 99% de los días. Hacerla diaria deja al timer un margen de 14 días para reaccionar si algo falla — alarma visible en _journalctl_.

---

## Integración con Caddy

Caddy ya escucha `:80`/`:443` en `192.168.1.3`. Hay que:

1. Bindear también a la IP del _tailnet_ (`100.x.y.z`).
2. Montar el directorio de certs Tailscale _read-only_.
3. Activar (descomentar y simplificar) el bloque `pi.<TAILNET>.ts.net` del `Caddyfile`.

### Variables de entorno

Editar `~/homelab/red/.env.example` (versionado, sin valores reales) — sustituir las dos líneas que `docs/03-red/04-caddy.md` dejó vacías y añadir `TAILSCALE_IPV4`:

```diff
 # --- Caddy / Tailscale (docs/03-red/04-caddy.md, docs/03-red/05-tailscale.md) ---
 CADDY_IMAGE_TAG=2.8.4-alpine
 HOMELAB_PI_IPV4=192.168.1.3
 CADDY_ADMIN_EMAIL=

-TAILSCALE_HOSTNAME=
-TAILNET=
+# Hostname de la Pi en el tailnet (== `tailscale status` columna 'host')
+TAILSCALE_HOSTNAME=pi
+# Nombre del tailnet, sin el sufijo .ts.net. P. ej. 'tail1234' para 'tail1234.ts.net'.
+TAILNET=
+# IPv4 del tailnet de la Pi (`tailscale ip --4`). Usado por Caddy para bindear :443.
+TAILSCALE_IPV4=
```

Replicar en `~/homelab/red/.env` (no _commiteado_) con los valores reales:

```bash
cd ~/homelab/red
$EDITOR .env
# rellenar TAILSCALE_HOSTNAME=pi
# rellenar TAILNET=tail1234       (sustituir por el real)
# rellenar TAILSCALE_IPV4=100.x.y.z
chmod 0600 .env
```

> **Por qué `TAILSCALE_IPV4` también en `.env`**: aunque sea redundante con `tailscale ip --4`, mantenerla como variable explícita evita _shell substitution_ dentro de `docker-compose.yml` (que no soporta `$(...)`) y deja la IP visible en `docker compose config` para auditar.

### Modificar `docker-compose.yml` (servicio `caddy`)

Añadir un segundo bind de puertos y un volumen _read-only_ para el directorio de certs. Diff sobre el bloque `caddy:` que dejó `docs/03-red/04-caddy.md`:

```diff
   caddy:
     image: caddy:${CADDY_IMAGE_TAG}
     container_name: caddy
     hostname: caddy
     restart: unless-stopped
     cap_add:
       - NET_BIND_SERVICE
     environment:
       TZ: ${TZ}
       CADDY_ADMIN_EMAIL: ${CADDY_ADMIN_EMAIL}
       TAILSCALE_HOSTNAME: ${TAILSCALE_HOSTNAME}
-      TAILNET: ${TAILNET:-}
+      TAILNET: ${TAILNET}
     volumes:
       - ./Caddyfile:/etc/caddy/Caddyfile:ro
       - ./caddy/snippets:/etc/caddy/snippets:ro
       - /mnt/hd2t/services/caddy/data:/data
       - /mnt/hd2t/services/caddy/config:/config
       - /mnt/hd2t/services/caddy/log:/var/log/caddy
+      # Cert Tailscale (Let's Encrypt) emitido por 'tailscale cert' y renovado
+      # por tailscale-cert.timer (docs/03-red/05-tailscale.md). Read-only:
+      # Caddy NO escribe aquí, sólo lo lee en cada reload.
+      - /var/lib/tailscale/certs:/etc/caddy/tailscale-certs:ro
     ports:
       - "${HOMELAB_PI_IPV4}:80:80"
       - "${HOMELAB_PI_IPV4}:443:443"
       - "${HOMELAB_PI_IPV4}:443:443/udp"
+      # Bind también a la IP del tailnet — clientes remotos vía Tailscale
+      # alcanzan Caddy por 100.x.y.z sin abrir puertos en el router.
+      - "${TAILSCALE_IPV4}:80:80"
+      - "${TAILSCALE_IPV4}:443:443"
+      - "${TAILSCALE_IPV4}:443:443/udp"
     networks:
       homelab:
         aliases:
           - caddy
     labels:
       homelab.stack: "red"
       homelab.backup: "true"
       com.centurylinklabs.watchtower.enable: "true"
```

Notas:

- **Doble bind explícito** en lugar de `0.0.0.0`: la Pi tiene varias interfaces (`eth0`, `lo`, `tailscale0`, `macvlan-shim`, `docker0`, `br-homelab`); abrir Caddy en `0.0.0.0` lo expondría también en `docker0`/`br-homelab`, donde no debe escuchar — el _embedded DNS_ y los servicios internos resuelven `caddy` por nombre dentro de la red `homelab` sin necesidad de puertos publicados. Bind explícito = mínimo necesario.
- **Sin `network_mode: host`**: a pesar de que Tailscale corre en el host, Docker bindea sin problema a IPs de interfaces no-Docker. Sólo hay que asegurar que `tailscale0` exista **antes** de levantar Caddy (lo cubre el orden `tailscaled.service` antes de `docker.service`, que es el _default_ de Debian Bookworm).
- **`com.centurylinklabs.watchtower.enable`**: sin cambios. Caddy sigue en _opt-in_.

### Aplicar y verificar el bind

```bash
cd ~/homelab/red
docker compose --env-file ../.env --env-file .env up -d caddy
# Recreating caddy ... done

sudo ss -tulpn | grep -E ':80|:443'
# tcp ... 192.168.1.3:80    ...  docker-proxy
# tcp ... 192.168.1.3:443   ...  docker-proxy
# udp ... 192.168.1.3:443   ...  docker-proxy
# tcp ... 100.x.y.z:80      ...  docker-proxy
# tcp ... 100.x.y.z:443     ...  docker-proxy
# udp ... 100.x.y.z:443     ...  docker-proxy
```

### Sustituir el bloque del Caddyfile

`docs/03-red/04-caddy.md` dejó esto comentado al final del `Caddyfile`:

```caddyfile
# {$TAILSCALE_HOSTNAME}.{$TAILNET}.ts.net {
#     tls /etc/caddy/tailscale-cert.crt /etc/caddy/tailscale-cert.key
#     import security-headers
#     import logging
#     @pihole host pihole.{$TAILSCALE_HOSTNAME}.{$TAILNET}.ts.net
#     handle @pihole {
#         reverse_proxy pihole:80
#     }
#     # ... un handle por servicio
# }
```

**Sustituir** ese bloque por la versión definitiva de este doc — sin `@host` matchers (Tailscale no emite certs para subdominios) y con la ruta de cert correcta:

```caddyfile
# ---------------------------------------------------------------------------
# Tailscale — entrada vía VPN mesh.
# Cert: pi.<TAILNET>.ts.net firmado por Let's Encrypt vía Tailscale (DNS-01).
# Renovado por tailscale-cert.timer (docs/03-red/05-tailscale.md).
# Acceso a servicios individuales: por sus *.lan via split DNS Tailscale +
# CA local importada en el cliente (más simple que multi-cert).
# ---------------------------------------------------------------------------
{$TAILSCALE_HOSTNAME}.{$TAILNET}.ts.net {
    tls /etc/caddy/tailscale-certs/{$TAILSCALE_HOSTNAME}.{$TAILNET}.ts.net.crt \
        /etc/caddy/tailscale-certs/{$TAILSCALE_HOSTNAME}.{$TAILNET}.ts.net.key

    import security-headers
    import logging

    # Página de aterrizaje. Mientras no exista Homepage (docs/12-dashboards/01-homepage.md)
    # devolvemos un texto plano con el mapa mental de los servicios.
    handle / {
        respond <<HOMELAB
Homelab — acceso vía Tailscale.

Servicios disponibles (importa la CA local: docs/03-red/04-caddy.md):

  https://pihole.lan/admin/
  https://portainer.lan/
  https://uptime.lan/        (cuando exista)
  https://homepage.lan/      (cuando exista)

Status (este endpoint): pi.{$TAILNET}.ts.net
HOMELAB 200
    }

    # /healthz — endpoint para Uptime Kuma desde el propio tailnet
    # (docs/05-monitorizacion/05-uptime-kuma.md).
    handle /healthz {
        respond "OK" 200
    }

    # Cualquier otra ruta -> redirigir al cliente a la URL .lan equivalente
    # cuando la importación de la CA local esté hecha. Por ahora 404 simple.
    handle {
        respond "Not found. Use https://<servicio>.lan/" 404
    }
}
```

> **Por qué `respond` en lugar de un `reverse_proxy` a Homepage**: Homepage aún no existe (`docs/12-dashboards/01-homepage.md` está en Fase 12). Hasta entonces, este endpoint sirve como **prueba de vida** del bind Tailscale + cert público. Cuando llegue Homepage, el `handle /` se sustituye por `reverse_proxy homepage:3000` (`homepage` resolverá por _embedded DNS_ en `homelab`). Sin tocar nada más.

> **`<<HOMELAB ... HOMELAB`**: _heredoc_ de Caddy. Acepta multi-línea sin escapar comillas.

Validar la sintaxis sin levantar el servicio:

```bash
docker run --rm \
    -v ~/homelab/red/Caddyfile:/etc/caddy/Caddyfile:ro \
    -v ~/homelab/red/caddy/snippets:/etc/caddy/snippets:ro \
    -e TAILSCALE_HOSTNAME=pi \
    -e TAILNET=tail1234 \
    caddy:2.8.4-alpine \
    caddy validate --config /etc/caddy/Caddyfile
# Valid configuration
```

Aplicar el cambio en caliente (sin _restart_ del contenedor):

```bash
docker exec caddy caddy reload --config /etc/caddy/Caddyfile
# INF reload happened
```

---

## Verificación final

Antes de pasar a `docs/04-seguridad/01-authelia.md`, comprobar todo lo siguiente:

- [ ] `tailscale status` desde la Pi muestra el nodo `pi` activo, etiquetado `tag:homelab`, y al menos un _peer_ del operador (móvil o portátil) si ya están en el _tailnet_.
- [ ] `tailscale ip --4` devuelve la misma IPv4 que está en `~/homelab/red/.env` como `TAILSCALE_IPV4`.
- [ ] `sudo systemctl is-active tailscaled` devuelve `active`. `sudo systemctl is-enabled tailscaled` devuelve `enabled`.
- [ ] `sudo systemctl list-timers tailscale-cert.timer --no-pager` muestra el _timer_ activo y la próxima ejecución dentro de las próximas 24 h.
- [ ] `sudo openssl x509 -in /var/lib/tailscale/certs/pi.<TAILNET>.ts.net.crt -noout -dates -issuer` muestra `Let's Encrypt` como _issuer_ y `notAfter` ~90 días en el futuro.
- [ ] `sudo ss -tulpn | grep -E '100\.[0-9]+\.[0-9]+\.[0-9]+:(80|443)'` muestra Caddy bindeando en la IP del _tailnet_ (`tcp` en `:80` y `:443`, `udp` en `:443`).
- [ ] Desde la propia Pi, `curl -I https://pi.<TAILNET>.ts.net/` (**sin** `-k`) responde `HTTP/2 200` y `openssl s_client -connect pi.<TAILNET>.ts.net:443 -servername pi.<TAILNET>.ts.net < /dev/null 2>&1 | grep 'Verify return code'` devuelve `Verify return code: 0 (ok)` (Let's Encrypt es de confianza por defecto).
- [ ] Desde un cliente Tailscale remoto (portátil/móvil con la app Tailscale activada), `curl -I https://pi.<TAILNET>.ts.net/` responde `HTTP/2 200` con cuerpo del _heredoc_ "Homelab — acceso vía Tailscale".
- [ ] Desde un cliente Tailscale remoto, `dig pihole.lan +short` devuelve `192.168.1.3` (resuelto vía _split DNS_ → Pi-hole).
- [ ] Desde un cliente Tailscale remoto **con la CA local del homelab importada**, `curl -I https://pihole.lan/admin/` responde `HTTP/2 200` o `302` sin errores de cert (el cert de `pihole.lan` lo firma la CA local; el tráfico va por el _tailnet_ hasta `192.168.1.3`).
- [ ] Desde un cliente Tailscale remoto **sin** la CA local importada, `curl -k https://pihole.lan/admin/ -I` también responde `200`/`302` (el `-k` salta la validación; sirve para confirmar que la _routing_ funciona aunque la confianza falte).
- [ ] `docker exec caddy caddy validate --config /etc/caddy/Caddyfile` devuelve `Valid configuration`.
- [ ] `docker exec caddy ls /etc/caddy/tailscale-certs/` muestra el `.crt` y `.key` (el _bind mount_ funciona).
- [ ] El cert se renueva sin _downtime_ — disparar manualmente y comprobar que Caddy hace _reload_ y los clientes no pierden conexión:

  ```bash
  sudo systemctl start tailscale-cert.service
  sudo journalctl -u tailscale-cert.service -n 30 --no-pager
  # 'caddy reload happened' al final, sin errores.
  ```

- [ ] Tras `sudo reboot` de la Pi, `tailscaled` arranca solo, la Pi vuelve al _tailnet_ con la misma IP `100.x.y.z` y Caddy bindea a `tailscale0` sin intervención manual. Esperar ~30 s tras el _login_ en SSH para que Docker complete el _start_ del _stack_.
- [ ] La _auth key_ usada para autorizar la Pi aparece como **revocada** en el _admin console_ → **Settings** → **Keys**.
- [ ] `git -C ~/homelab status` muestra como **modificados**: `red/.env.example`, `red/docker-compose.yml`, `red/Caddyfile`. **No** muestra `red/.env`. _Commit_:

  ```bash
  cd ~/homelab
  git add red/.env.example red/docker-compose.yml red/Caddyfile
  git commit -m "feat(red): expose homelab via Tailscale with public cert"
  ```

  Las units `tailscale-cert.{service,timer}` viven en `/etc/systemd/system/` y no entran en este repo. Quedan documentadas aquí.

---

## Backup

| Qué | Dónde | Cómo |
|---|---|---|
| Estado del nodo (clave WG, peers cacheados) | `/var/lib/tailscale/tailscaled.state` | Borgmatic (`docs/07-backups/02-borgmatic.md`) |
| Certificado público + clave (Let's Encrypt) | `/var/lib/tailscale/certs/` | No (regenerable con `tailscale cert`) |
| Units systemd de renovación | `/etc/systemd/system/tailscale-cert.{service,timer}` | git (dotfile-repo del operador) o copia a `~/homelab/etc/systemd/` |
| Configuración del _tailnet_ (ACL, _split DNS_, MagicDNS) | _Admin console_ de Tailscale | Exportar el ACL JSON manualmente cada cambio (`docs/04-seguridad/`) |

> **Restauración tras pérdida de la SD**: reinstalar `tailscale`, restaurar `/var/lib/tailscale/tailscaled.state` desde Borgmatic, `systemctl start tailscaled` — el nodo vuelve al _tailnet_ con la misma IP `100.x.y.z` (Tailscale guarda el _node key_ en _state_; sin él, hay que volver a `tailscale up` con _auth key_ y la IP cambia).

> **Si no se restaura `tailscaled.state`**: la Pi entra al _tailnet_ como un nodo nuevo (otra IP `100.x.y.z`). Hay que actualizar `TAILSCALE_IPV4` en `~/homelab/red/.env` y `make up STACK=red`. El cert hay que regenerarlo (`sudo tailscale cert pi.<TAILNET>.ts.net`).

---

## Troubleshooting

### `tailscale up` se queda colgado en "Waiting for login"

La _auth key_ no está siendo aceptada (caducada, ya usada, o sin permisos para `tag:homelab`). Diagnóstico:

```bash
sudo journalctl -u tailscaled -n 50 --no-pager | tail -30
# Buscar 'auth key invalid' o 'tag not allowed'
```

Soluciones por orden:

1. **_Auth key_ caducada**: generar una nueva en el _admin console_ y reintentar.
2. **`tag:homelab` no está en `tagOwners` del ACL**: editar el ACL para añadirlo.
3. **El usuario que crea la _auth key_ no es _owner_ del tag**: asegurarse de que es el mismo usuario que figura en `tagOwners`.

### `tailscale status` muestra `pi` con un _Last Seen_ de hace horas

El _daemon_ está corriendo pero el handshake con DERP/peers ha caído. Lo más común: NTP fuera de sincronía o `nftables` bloqueando UDP `41641` saliente. Verificar:

```bash
timedatectl status | grep 'System clock'
# System clock synchronized: yes

sudo nft list ruleset | grep -E 'output|41641'
# La política output debería ser 'accept' (default en docs/01-sistema/03-seguridad-base.md);
# si se cambió a 'drop', añadir 'udp dport 41641 accept'.
```

Tras corregir, reiniciar:

```bash
sudo systemctl restart tailscaled
tailscale status
```

### `tailscale cert` falla con `failed to fetch certificate: MagicDNS not enabled`

MagicDNS o HTTPS Certificates no están activos en el _admin console_. Volver al paso **Preparación del _admin console_ → Habilitar MagicDNS y HTTPS Certificates**.

### `tailscale cert` falla con `failed: 429 Too Many Requests`

Let's Encrypt tiene _rate limits_ (50 certs/dominio/semana). En el homelab no se llega salvo bucle accidental (si el `tailscale-cert.timer` se disparara cada minuto por error, p. ej.). Esperar 1 h y reintentar; revisar el `OnCalendar` del timer.

### Caddy responde 200 en `:443` pero el cert de `pi.<TAILNET>.ts.net` está autofirmado por Caddy

El `tls /etc/caddy/tailscale-certs/...` no encuentra el fichero (ruta mal escrita en el `Caddyfile`, o el _bind mount_ no funcionó), y Caddy ha caído al _fallback_ `tls internal`. Verificar:

```bash
docker exec caddy ls -la /etc/caddy/tailscale-certs/
# Debe listar pi.<TAILNET>.ts.net.{crt,key}
```

Si está vacío, comprobar el `volumes:` del `docker-compose.yml` (debe apuntar a `/var/lib/tailscale/certs:/etc/caddy/tailscale-certs:ro`) y `docker compose up -d caddy` para recrear.

Si está poblado pero Caddy sigue cayendo a `tls internal`, revisar la sustitución de `${TAILSCALE_HOSTNAME}` y `${TAILNET}` (un valor vacío deja la ruta como `/etc/caddy/tailscale-certs/...ts.net.crt`, _file not found_). `docker exec caddy env | grep TAIL` debe mostrar valores reales, no vacíos.

### Desde un cliente remoto, `pihole.lan` no resuelve

_Split DNS_ no está aplicado. Comprobar primero en el cliente:

```bash
# En el portátil con Tailscale activo:
tailscale dns status
# 'split DNS routes:'
#   lan -> 192.168.1.2:53
```

Si `lan` no aparece:

1. Confirmar en _admin console_ → **DNS** → **Restricted nameservers** que la zona `lan` está delegada a `192.168.1.2`.
2. Reiniciar la app Tailscale del cliente (los `dns settings` se aplican en cada handshake; un cliente que estaba conectado antes del cambio puede tardar minutos en refrescar).

Si aparece pero la consulta sigue fallando (`dig pihole.lan` devuelve `NXDOMAIN` o `SERVFAIL`):

1. La Pi (`192.168.1.3`) tiene que poder enrutar el tráfico DNS desde el cliente Tailscale (`100.x.y.z`) hasta Pi-hole (`192.168.1.2`). El _split DNS_ de Tailscale hace `100.x.y.z → tailscale0 (Pi) → eth0 (Pi) → 192.168.1.2`. Verificar desde la Pi:

   ```bash
   sudo tcpdump -ni any 'port 53 and host 192.168.1.2' &
   # Desde el cliente remoto: dig @100.100.100.100 portainer.lan
   # Debería verse el tráfico llegar a Pi-hole.
   ```

2. Si el _allow rule_ de `nftables` para tráfico saliente desde `tailscale0` hacia `192.168.1.0/24` no existe, añadirla (`docs/01-sistema/03-seguridad-base.md`).

### El portátil pierde el _tailnet_ tras suspender / hibernar

Comportamiento del cliente Tailscale, no de la Pi. Soluciones:

- macOS / Linux: el _daemon_ vuelve solo en cuestión de segundos. Si tarda más, `tailscale up` (sin args) refresca.
- Windows: la app GUI a veces necesita "Disconnect" + "Connect".
- Móvil: la app tiene un toggle "Always-on VPN" en Android / "Connect On Demand" en iOS que evita la desconexión.

### El _admin console_ marca la Pi como "expired" pese al `tag:homelab`

Confirmar que `tailscale status` muestra `tagged-devices` después del nombre del nodo:

```bash
tailscale status --json | jq '.Self.Tags'
# ["tag:homelab"]
```

Si `Tags` viene `null` o vacío, el nodo no quedó etiquetado correctamente (típicamente porque el ACL no tenía `tag:homelab` en `tagOwners` cuando se ejecutó `tailscale up`). Re-autorizar:

```bash
sudo tailscale up \
    --authkey="tskey-auth-NUEVA" \
    --hostname=pi \
    --advertise-tags=tag:homelab \
    --accept-dns=false --accept-routes=false --ssh=false
```

Y revocar la _auth key_ tras usarla.

### Cómo dar de baja la Pi del _tailnet_ (procedimiento limpio)

Por si el día de mañana se quiere reinstalar la Pi y empezar de cero:

```bash
sudo tailscale logout
sudo systemctl stop tailscaled
sudo apt purge tailscale
sudo rm -rf /var/lib/tailscale
```

Y en el _admin console_ → **Machines** → seleccionar `pi` → **Remove**.

---

## Referencias

- Tailscale — Documentación oficial: <https://tailscale.com/kb/>
- Tailscale — Instalación en Debian/Raspberry Pi: <https://tailscale.com/kb/1174/install-debian-bookworm/>
- Tailscale — `tailscale up` reference: <https://tailscale.com/kb/1080/cli/#up>
- Tailscale — MagicDNS: <https://tailscale.com/kb/1081/magicdns/>
- Tailscale — _Split DNS_ / Restricted nameservers: <https://tailscale.com/kb/1054/dns/>
- Tailscale — HTTPS Certificates (`tailscale cert`): <https://tailscale.com/kb/1153/enabling-https/>
- Tailscale — ACLs y _tags_ (HuJSON): <https://tailscale.com/kb/1018/acls/> y <https://tailscale.com/kb/1068/tags/>
- Tailscale — _Auth keys_: <https://tailscale.com/kb/1085/auth-keys/>
- Tailscale — _Subnet routers_ (no usados aquí): <https://tailscale.com/kb/1019/subnets/>
- Tailscale — Repo y _release notes_: <https://github.com/tailscale/tailscale>
