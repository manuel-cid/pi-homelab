# Tailscale

## Descripción

Cerrado `04-caddy.md`, el reverse proxy del homelab está vivo: `https://pihole.lan/` carga sin advertencias en cualquier dispositivo de la LAN que tenga instalado el root de la **CA interna**, y el `Caddyfile` lleva ya **versionado y comentado** un bloque `pi.{$TAILNET_DOMAIN}` que espera dos cosas concretas: (a) que la Pi pertenezca a un *tailnet* y (b) que existan los ficheros `cert.pem` / `key.pem` en `/mnt/hd2t/apps/caddy/etc/tailscale/`. Este documento cierra ambos puntos y, con ello, abre la **última puerta del homelab**: el acceso remoto.

Este documento despliega **Tailscale** sobre el host de la Pi 5 con cuatro misiones:

1. **Conectar la Pi a un tailnet** del operador (cuenta personal en `https://login.tailscale.com/`). El nodo aparece como `pi` y queda accesible por su dirección CGNAT (`100.x.y.z`) y por su nombre MagicDNS (`pi.${TAILNET_DOMAIN}`) desde **cualquier otro dispositivo del operador** que también esté autenticado en el mismo tailnet (laptop, móvil, tablet).
2. **Habilitar MagicDNS y HTTPS para el tailnet** en el panel de administración, paso obligatorio para que los certificados Let's Encrypt sobre `*.${TAILNET_DOMAIN}` funcionen.
3. **Generar el certificado público del tailnet** vía `tailscale cert`, depositarlo en la ruta que `04-caddy.md` ya tiene bind-mounteada, y **descomentar** el bloque `pi.{$TAILNET_DOMAIN}` del `Caddyfile`. A partir de aquí, `https://pi.${TAILNET_DOMAIN}/pihole/` funciona desde fuera de casa **sin abrir un solo puerto en el router**.
4. **Automatizar la renovación del certificado** con un `systemd` timer mensual que ejecuta el script `refresh-tailscale-cert.sh` (versionado en `04-caddy.md`) y notifica a Caddy con `SIGUSR1`.

Lo que este documento **no** decide:

- **Tailscale en contenedor Docker**: aunque existe `tailscale/tailscale` para correr el demonio dentro de un contenedor, este homelab lo instala en el host. Las razones se discuten abajo en "Decisión: host vs contenedor"; en resumen: `tailscale cert` (consumido por Caddy), la regla `ufw allow in on tailscale0` (preparada en `01-sistema/03-seguridad-base.md`) y la integración con `sshd` exigen que la interfaz `tailscale0` viva en el namespace de red del host.
- **ACL afinadas, etiquetas, grupos**: la cuenta personal de Tailscale en plan gratuito asume *"todos mis nodos pueden hablar entre sí"*. Para un homelab de un operador y unos pocos dispositivos personales, esa política por defecto es la correcta. Si en algún momento se incorpora un familiar al tailnet con acceso solo a Jellyfin, se reabre con un `tailnet-policy.json` versionado. Reabrible.
- **Subnet router (`--advertise-routes`)**: explícitamente **no** se anuncia la subred `192.168.1.0/24` al tailnet. La regla del homelab es *"al tailnet solo se llega a través de Caddy en la Pi"*: el resto de servicios (Pi-hole, Unbound, otros dispositivos LAN) **no** son alcanzables por Tailscale. Hacer subnet router rompería esa frontera y volvería al "todo expuesto" que el plan rechaza. Justificado abajo y reabrible si en algún momento aparece un caso real (ej. SSH directo a un NAS de la LAN).
- **Exit node (`--advertise-exit-node`)**: la Pi **no** se anuncia como salida a internet del tailnet. Caso de uso ortogonal al homelab y con implicaciones de tráfico (ancho de banda subido, reglas de NAT del router) que merecen su propio análisis. Reabrible.
- **Tailscale SSH** (`--ssh`, función nativa que sustituye OpenSSH para conexiones intra-tailnet): se evalúa como alternativa al `sshd` clásico configurado en `01-sistema/03-seguridad-base.md`, pero **no** se activa aquí. Razonado en "Decisión: SSH del homelab vía Tailscale".
- **Funnel** (exposición pública vía dominios `*.ts.net` accesibles desde internet sin abrir puertos): explícitamente **fuera del alcance**. Funnel pone la Pi a un click de ser servidor público; el plan dice "solo LAN + tailnet", y Funnel rompe esa frontera. Si alguna vez hay que exponer Jellyfin a alguien fuera del tailnet, el plan B es invitarlo al tailnet, no abrir Funnel.
- **Bloques específicos del Caddyfile por servicio** (Jellyfin, Nextcloud, Vaultwarden …): los añade cada documento de servicio (Fases 6–11) en su drop-in `conf.d/NN-servicio.caddy`. Aquí solo se descomenta y verifica el bloque `pi.{$TAILNET_DOMAIN}` con el `handle_path /pihole/*` ya escrito en `04-caddy.md`.

Cuando este documento se haya aplicado, `tailscale status` lista la Pi como nodo activo en el tailnet del operador, `ip a show tailscale0` muestra una IP del rango `100.64.0.0/10`, `ufw status` confirma la regla `ALLOW IN on tailscale0`, el `systemd` timer `refresh-tailscale-cert.timer` está activo y el bloque `pi.{$TAILNET_DOMAIN}` del Caddyfile ya **no** está comentado: desde un móvil con datos móviles y el cliente Tailscale conectado, `https://pi.${TAILNET_DOMAIN}/pihole/admin/` carga sin advertencia y sin haber tocado el router doméstico.

> **Recordatorio de alcance**: Tailscale es la **única** vía remota al homelab. No se abren puertos en el router (NAT inalterado), no se usan dominios públicos del operador, no se expone Funnel. La superficie remota del homelab es exactamente "lo que Caddy sirve sobre `tailscale0` cuando un cliente autenticado en el tailnet pregunta".

---

## Requisitos Previos

- Fase 1 completa:
  - `01-sistema/03-seguridad-base.md` aplicado: UFW activo (deny entrante por defecto), `sshd` endurecido, regla `ufw allow in on tailscale0` **preparada** (comentada) y `fail2ban` con `ignoreip` que incluye `100.64.0.0/10`. Este documento **descomenta** y aplica esa regla.
- Fase 2 completa:
  - Docker Engine + Compose v2; red Docker `homelab` activa.
- Fase 3 anterior aplicada:
  - `01-macvlan.md` … `04-caddy.md` desplegados.
  - Pi-hole resolviendo en `192.168.1.2`, Unbound recursivo en `192.168.1.3`.
  - Caddy en `:80`/`:443` con CA interna funcional; `https://pihole.lan/admin/` carga.
  - `Caddyfile` con el bloque `pi.{$TAILNET_DOMAIN}` **comentado** (`grep -c '^# pi\.' /mnt/hd2t/apps/caddy/etc/Caddyfile` ≥ 1).
  - Script `scripts/refresh-tailscale-cert.sh` versionado y materializado en `/home/homelab/homelab/scripts/refresh-tailscale-cert.sh` con permisos `0750 root:root`.
  - Variable `TAILNET_DOMAIN` declarada en `stacks/caddy/.env` con valor placeholder (`EJEMPLO.ts.net`); este documento la sustituye por el valor real.
- `.env` global con `TZ`, `PUID`, `PGID`, `DOMAIN_LAN`, `LAN_IP`.
- **Cuenta de Tailscale** en `https://login.tailscale.com/` (gratuita, hasta 100 dispositivos / 3 usuarios). El operador conoce el dominio del tailnet asignado a su cuenta (suele ser un sufijo del estilo `tailnet-xxxx.ts.net` o un nombre escogido por el operador en `Settings → Tailnet name`). Si la cuenta es nueva, basta con registrarse: el dominio se autoasigna.
- Resolución DNS funcional desde el host hacia internet (necesaria para `apt`, para el demonio `tailscaled` al contactar con el servidor de coordinación, y para la validación DNS-01 que Tailscale hace internamente al emitir certs):

  ```bash
  dig +short google.com @192.168.1.2 | head -1
  # una IP

  curl -sI https://login.tailscale.com/ | head -1
  # HTTP/2 200
  ```

  Si falla la primera consulta, Pi-hole no resuelve (repasar `02-pihole.md`). Si falla la segunda, la Pi no tiene salida a internet (revisar gateway/router).

- Comprobación rápida del estado pre-Tailscale:

  ```bash
  ip -br -4 addr | awk '{print $1, $3}'
  # lo               127.0.0.1/8
  # eth0             192.168.1.10/24
  # docker0          172.17.0.1/16
  # br-...           172.30.10.1/24      (red `homelab`)
  # NO hay interfaz tailscale0 todavía.

  systemctl is-active tailscaled
  # inactive (correcto: aún no instalado)
  ```

---

## Decisión: host vs contenedor

Tailscale ofrece dos modos de despliegue oficiales:

| Modo | Cómo se ve | Pros | Contras | Veredicto |
|---|---|---|---|---|
| **Host (paquete `tailscale` de APT)** | `tailscaled` corre como `systemd` unit en la Pi; crea `tailscale0` en el namespace de red del host. | `tailscale cert` accesible desde scripts del host (lo necesita Caddy). UFW ve la interfaz y aplica la regla `allow in on tailscale0`. `sshd` puede usar `Match Address 100.64.0.0/10` o el listening en `tailscale0`. Logs van a `journalctl -u tailscaled`, integrado con el resto del sistema. | Una pieza más fuera de Docker; la actualización va por `apt` (cubierta por `unattended-upgrades`). | **Aceptado**. |
| **Contenedor (`tailscale/tailscale`)** | Demonio en Docker; opcionalmente `network_mode: host` o `network_mode: container:<otro>` para "sidecar". | Encaja con el resto del homelab (todo en Compose). | `tailscale cert` solo es invocable **dentro** del contenedor: el script de renovación tendría que entrar con `docker exec`. UFW del host **no** ve `tailscale0` si la red es bridge/macvlan. La regla del firewall ya preparada en `03-seguridad-base.md` no aplica directamente. La integración con `sshd` exige montar `tailscale0` en el host de todas formas. La actualización requiere un tag de imagen fijo más Watchtower; pierde el modelo "se actualiza con el resto del sistema". | Descartado. |
| **Contenedor sidecar de Caddy** (red compartida) | El contenedor Caddy comparte el namespace de red del contenedor Tailscale. | Caddy escucha directamente en `tailscale0` "del" sidecar. | Rompe la simetría con la LAN: hoy Caddy ata `0.0.0.0:443` y atiende en `eth0`+`tailscale0` por igual; con sidecar tendría dos contenedores compartiendo red, complicaría el `docker-compose.yml` de Caddy (que ya cerró), y `tailscale cert` seguiría siendo difícil de invocar desde el host. | Descartado. |

Resultado: **Tailscale en el host, vía paquete APT del repositorio oficial de Tailscale**. Las decisiones siguientes asumen este modo.

---

## Decisión: hostname y dominio del tailnet

Cada nodo del tailnet tiene un *hostname* único dentro del tailnet, y MagicDNS lo expone como `${hostname}.${TAILNET_DOMAIN}`.

| Aspecto | Decisión | Justificación |
|---|---|---|
| **Hostname del nodo** | `pi` | Coincide con el `hostname` del sistema (definido en `01-sistema/02-configuracion-inicial.md`). MagicDNS asignará `pi.${TAILNET_DOMAIN}`. Caddy ya está preparado para servir ese FQDN (`pi.{$TAILNET_DOMAIN}` en el Caddyfile). |
| **`TAILNET_DOMAIN`** | El que asigne Tailscale (panel de admin → `DNS`). Suele ser de la forma `tailnet-NOMBRE.ts.net`. | Al ser parte de `*.ts.net`, los certificados emitidos por Tailscale son **válidos públicamente** (Let's Encrypt firma sobre el dominio raíz `ts.net`), y cualquier navegador los acepta sin instalar nada. |
| **MagicDNS** | **Activado**. | Sin él, los nodos se referencian por IP CGNAT (`100.x.y.z`), que cambia entre nodos. Con MagicDNS, `pi.${TAILNET_DOMAIN}` es estable y el cert puede emitirse para ese nombre. |
| **HTTPS Certificates** | **Activado** (panel `DNS → HTTPS Certificates`). | Es el botón que habilita `tailscale cert` para emitir certs Let's Encrypt sobre nombres `${TAILNET_DOMAIN}`. Sin esto, el comando falla con `HTTPS not enabled on tailnet`. |
| **Renombrar el tailnet** | No es necesario. | El sufijo aleatorio sirve igual; renombrarlo a `casa.ts.net` (si está disponible) es estético y se hace en cualquier momento desde el panel sin afectar a los nodos. Si se hace después de generar el primer cert, hay que regenerar el cert con el nombre nuevo. |

> **`TAILNET_DOMAIN` en uso (placeholder en este documento)**: `tailnet.ts.net`. El operador sustituye por el real en su `.env` antes de ejecutar los comandos. El `Caddyfile` y los scripts ya leen la variable; no se hardcodea en ningún sitio.

---

## Decisión: subnet router y exit node

Tailscale soporta dos modos para que un nodo "preste" conectividad:

| Modo | Qué hace | ¿Se activa aquí? | Razón |
|---|---|---|---|
| **Subnet router** (`--advertise-routes=192.168.1.0/24`) | El nodo anuncia al tailnet "yo sé llegar a esta subred"; los clientes del tailnet pueden alcanzar **cualquier IP** de esa subred a través del nodo. | **No.** | La regla del homelab es "al tailnet solo se llega a través de Caddy". Activar subnet router pondría todos los servicios LAN (router admin, NAS, otros dispositivos personales) un *click* dentro del tailnet, multiplicando la superficie remota sin beneficio claro. Si en algún momento aparece un caso concreto (SSH a un NAS, acceso al admin del router desde fuera), se reabre la decisión y se activa **selectivamente** con `--advertise-routes` apuntando a una IP única, no a `/24`. |
| **Exit node** (`--advertise-exit-node`) | El nodo se ofrece como salida a internet del tailnet (los clientes pueden enrutar **todo su tráfico** por la Pi). | **No.** | Caso de uso ortogonal al homelab: convierte la Pi en VPN-de-salida (ej. para ver contenido geo-restringido o navegar desde una red pública). El tráfico de salida pasa a depender del ancho de banda de subida del operador (asimétrico en la mayoría de conexiones domésticas) y de la NAT del router. Reabrible si surge la necesidad. |

Ambas se podrían activar con un solo `tailscale up --reset --advertise-routes=… --advertise-exit-node`; la decisión queda explícita aquí para no caer en activaciones por inercia.

---

## Decisión: SSH del homelab vía Tailscale

Hay dos formas de exponer SSH a través del tailnet:

| Opción | Cómo se ve | Discusión | Veredicto |
|---|---|---|---|
| **OpenSSH clásico + filtrar por interfaz `tailscale0`** | El `sshd` ya endurecido en `03-seguridad-base.md` escucha en `0.0.0.0:22`. La autenticación sigue siendo por clave pública. La regla `ufw allow in on tailscale0` (que aplica este documento) acepta el tráfico SSH **también** por la VPN. | Cero piezas nuevas. La política existente (claves SSH, `fail2ban` con `ignoreip 100.64.0.0/10`) sigue válida. El operador hace `ssh homelab@pi.tailnet.ts.net` (MagicDNS) o `ssh homelab@100.x.y.z` desde cualquier dispositivo del tailnet. | **Aceptado**. |
| **Tailscale SSH (`tailscale up --ssh`)** | Tailscale **suplanta** SSH para conexiones intra-tailnet: se autentica con la identidad del usuario en el tailnet (Google/GitHub/email + 2FA), no con clave pública. La conexión llega como un proceso `tailscale ssh` que se redirige a un PAM-session local. | Ergonomía superior (el cliente no necesita gestionar `~/.ssh/known_hosts` ni claves), pero **introduce una segunda fuente de verdad** para autenticar SSH. La política mínima del homelab es "una sola entrada y conocida". Además, romper Tailscale (caída del coordination server, expiración de máquina) podría dejar a la Pi sin acceso SSH si el clásico está deshabilitado. | Descartado por ahora; **reabrible**. |

Resultado: **`sshd` clásico**, con `tailscale0` aceptado por UFW. La sección "Configuración → Activar UFW para `tailscale0`" recoge el comando.

> **Nota sobre `sshd_config`**: el `Match Address 192.168.1.0/24` que `03-seguridad-base.md` deja como ejemplo se podría extender a `Match Address 192.168.1.0/24,100.64.0.0/10` para exigir clave pública también desde el tailnet. Como la política global ya es `PasswordAuthentication no`, la extensión es estética: aporta documentación, no seguridad adicional. No se aplica aquí.

---

## Instalación

### 1) Repositorio APT y paquete

Tailscale publica un repositorio APT firmado para Debian Bookworm (la base de Raspberry Pi OS Lite). Se sigue el procedimiento oficial:

```bash
# Clave del repositorio (binario, no ASCII armored)
curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.noarmor.gpg | \
    sudo tee /usr/share/keyrings/tailscale-archive-keyring.gpg > /dev/null

# Lista de paquetes
curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.tailscale-keyring.list | \
    sudo tee /etc/apt/sources.list.d/tailscale.list

# Verificar permisos (el sources.list debe ser root:root, 0644)
ls -l /etc/apt/sources.list.d/tailscale.list

# Instalar
sudo apt update
sudo apt install -y tailscale

# Versión instalada (informativo)
tailscale version
# 1.74.x
#   tailscale commit: ...
```

`unattended-upgrades` (configurado en `03-seguridad-base.md`) recoge actualizaciones de seguridad de los repos `Debian:bookworm-security`. Para que cubra también el repo de Tailscale, se añade el origen a `/etc/apt/apt.conf.d/50unattended-upgrades`:

```bash
sudo sed -i '/^Unattended-Upgrade::Allowed-Origins {/a\        "Tailscale:any";' \
    /etc/apt/apt.conf.d/50unattended-upgrades
```

> Si `unattended-upgrades` ya tiene su bloque `Allowed-Origins` con sintaxis distinta, editar manualmente y añadir `"Tailscale:any";` dentro del bloque. La directiva `Tailscale:any` casa con el `Origin: tailscale.com` que firma el repo.

Verificar que `tailscaled` está activo y habilitado:

```bash
systemctl is-active tailscaled
# active

systemctl is-enabled tailscaled
# enabled
```

### 2) Autenticar el nodo

`tailscale up` lanza un flujo de auth interactivo: imprime una URL `https://login.tailscale.com/a/...` que el operador abre en un navegador (puede ser otro dispositivo) y aprueba el nodo con la cuenta del tailnet.

```bash
sudo tailscale up \
    --hostname=pi \
    --accept-dns=false \
    --accept-routes=false \
    --ssh=false \
    --advertise-tags=
```

Bandera por bandera:

| Bandera | Valor | Razón |
|---|---|---|
| `--hostname=pi` | `pi` | Hostname dentro del tailnet (independiente del hostname del SO; aquí coinciden por convención). MagicDNS expondrá `pi.${TAILNET_DOMAIN}`. |
| `--accept-dns=false` | `false` | El DNS del homelab es Pi-hole (`192.168.1.2`). Si Tailscale toma control de `/etc/resolv.conf`, las consultas dejan de pasar por Pi-hole y se pierde el bloqueo de listas en la propia Pi. La Pi no necesita resolver nombres del tailnet (es **servidor**, no cliente del tailnet); MagicDNS funciona en los **otros** dispositivos del operador. |
| `--accept-routes=false` | `false` | No se aceptan subnet routers anunciados por otros nodos. Coherente con "no se activa subnet router aquí". |
| `--ssh=false` | `false` | No se activa Tailscale SSH (decisión arriba). |
| `--advertise-tags=` | vacío | Sin tags por ahora (las tags exigen una `tailnet-policy.json` con `tagOwners`, que este homelab no usa). |

Tras la URL de auth y la aprobación en el navegador, el comando vuelve y la Pi queda autenticada:

```bash
tailscale status
# 100.x.y.z   pi                  homelab@      linux   -
# 100.a.b.c   laptop-operador     homelab@      macos   active

ip -br addr show tailscale0
# tailscale0  UNKNOWN  100.x.y.z/32 fd7a:115c:a1e0::xxxx/128

tailscale ip -4
# 100.x.y.z

tailscale ip -6
# fd7a:115c:a1e0:xxxx:xxxx:xxxx:xxxx:xxxx
```

Anotar la IP CGNAT en `~/.notes` o en el gestor de contraseñas: aunque MagicDNS la resuelve, el dato es útil para troubleshooting y para entradas DNS internas si en algún momento el homelab quisiera resolver `pi.tailnet` localmente sin depender de MagicDNS.

> **`--reset` vs no**: `tailscale up` sin `--reset` **mantiene** las banderas previas y solo cambia las que se pasan; **con** `--reset`, descarta todo lo previo y aplica solo lo del comando. La primera vez no hay diferencia (no hay estado previo). En reaplicaciones, usar `--reset` para evitar que sobrevivan banderas obsoletas.

### 3) Activar MagicDNS y HTTPS Certificates en el panel

Las dos opciones se activan **una sola vez** por tailnet desde la web de admin (no por CLI). El operador entra a:

- `https://login.tailscale.com/admin/dns/` → activar **MagicDNS** (botón "Enable MagicDNS").
- `https://login.tailscale.com/admin/dns/https` → activar **HTTPS Certificates** (botón "Enable HTTPS").

La página de DNS muestra el dominio del tailnet (`tailnet-NOMBRE.ts.net`); el operador lo copia y lo pone en su `stacks/caddy/.env`:

```bash
# Editar stacks/caddy/.env
sed -i 's/^TAILNET_DOMAIN=.*$/TAILNET_DOMAIN=tailnet-NOMBRE.ts.net/' \
    /home/homelab/homelab/stacks/caddy/.env

# Verificar
grep TAILNET_DOMAIN /home/homelab/homelab/stacks/caddy/.env
# TAILNET_DOMAIN=tailnet-NOMBRE.ts.net
```

> El `.env` está en `.gitignore` (Fase 2). El **placeholder** sigue en `.env.example` versionado.

Verificar que MagicDNS responde desde otro nodo del tailnet (un portátil del operador autenticado):

```bash
# Desde el portátil
tailscale status
# Pi aparece con su FQDN: pi.tailnet-NOMBRE.ts.net

dig +short pi.tailnet-NOMBRE.ts.net
# 100.x.y.z

# Conectividad
ping -c 2 pi.tailnet-NOMBRE.ts.net
# 64 bytes from pi.tailnet-NOMBRE.ts.net (100.x.y.z): icmp_seq=1 ttl=64 time=10.x ms
```

Si el `dig` no devuelve nada, MagicDNS no está activo en el panel, o el cliente del tailnet no tiene `--accept-dns=true` (que es el default en clientes; **no** es el default en la Pi por la decisión anterior).

---

## Configuración

### 1) Aplicar la regla UFW para `tailscale0`

`01-sistema/03-seguridad-base.md` deja preparada la regla en comentario. Ahora que la interfaz existe, se aplica:

```bash
# Confirmar que la interfaz existe
ip -br link show tailscale0
# tailscale0  UNKNOWN  ...

# Aplicar la regla
sudo ufw allow in on tailscale0 comment 'Tailscale: confiar en mesh'

# Verificar
sudo ufw status verbose | grep tailscale0
# Anywhere on tailscale0     ALLOW IN    Anywhere                   # Tailscale: confiar en mesh
# Anywhere (v6) on tailscale0 ALLOW IN   Anywhere (v6)              # Tailscale: confiar en mesh
```

> La regla es **deliberadamente permisiva en la interfaz**: cualquier puerto abierto en la Pi es alcanzable desde cualquier nodo del tailnet. Eso es coherente con la regla "todo tráfico del tailnet es de confianza" del homelab. La granularidad fina (bloquear `:53` desde el tailnet para que clientes ajenos no descubran Pi-hole, p. ej.) se puede añadir más adelante sin tocar esta línea.

### 2) Generar el primer certificado del tailnet (consumido por Caddy)

El script `refresh-tailscale-cert.sh` (versionado en `04-caddy.md`) está ya en `/home/homelab/homelab/scripts/refresh-tailscale-cert.sh` con permisos `0750 root:root`. Se ejecuta una primera vez para crear `cert.pem` y `key.pem` en `/mnt/hd2t/apps/caddy/etc/tailscale/`:

```bash
sudo /home/homelab/homelab/scripts/refresh-tailscale-cert.sh
# Cert renovado para pi.tailnet-NOMBRE.ts.net; Caddy recargado.
```

Si Caddy aún no estaba arrancado (no debería ser el caso, `04-caddy.md` lo dejó en `Up (healthy)`), el script imprime "Caddy no está corriendo (skip reload)" y termina con éxito; el cert queda en disco a la espera del próximo arranque.

Validar:

```bash
sudo ls -l /mnt/hd2t/apps/caddy/etc/tailscale/
# -rw-r--r-- 1 root root 1729 ... cert.pem
# -rw-r----- 1 root root 1675 ... key.pem

sudo openssl x509 -in /mnt/hd2t/apps/caddy/etc/tailscale/cert.pem -noout -subject -issuer -dates
# subject=CN = pi.tailnet-NOMBRE.ts.net
# issuer=C = US, O = Let's Encrypt, CN = R3
# notBefore=...
# notAfter=...     (+90 días desde notBefore)
```

> **Permisos del directorio `tailscale/`**: el script lo crea con `chmod 0750`. El usuario interno de Caddy lee los ficheros porque el directorio es legible por `o+x` (`0750` da `o=---`, ojo: en realidad **no** lo es). Caddy en `caddy:2.8.4-alpine` corre como UID `0` o `1000` según versión: se valida abajo en "Verificación final" con `docker exec caddy ls /etc/caddy/tailscale/`. Si Caddy se queja de "permission denied", relajar el directorio a `0755` o cambiar el grupo a uno compartido.

### 3) `systemd` timer mensual de renovación

`tailscale cert` reemite si quedan menos de 14 días al cert; con un timer mensual hay margen de sobra. Las dos unidades se instalan en `/etc/systemd/system/`:

```bash
# Service unit
sudo tee /etc/systemd/system/refresh-tailscale-cert.service > /dev/null <<'UNIT'
[Unit]
Description=Renueva el certificado de Tailscale para Caddy
Documentation=file:///home/homelab/homelab/docs/03-red/05-tailscale.md
After=network-online.target tailscaled.service docker.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/home/homelab/homelab/scripts/refresh-tailscale-cert.sh
User=root
Group=root
StandardOutput=journal
StandardError=journal
UNIT

# Timer unit (mensual con margen de 1 día)
sudo tee /etc/systemd/system/refresh-tailscale-cert.timer > /dev/null <<'UNIT'
[Unit]
Description=Renovacion mensual del cert de Tailscale para Caddy
Documentation=file:///home/homelab/homelab/docs/03-red/05-tailscale.md

[Timer]
OnCalendar=monthly
RandomizedDelaySec=1d
Persistent=true
Unit=refresh-tailscale-cert.service

[Install]
WantedBy=timers.target
UNIT

# Recargar systemd, habilitar y arrancar el timer
sudo systemctl daemon-reload
sudo systemctl enable --now refresh-tailscale-cert.timer

# Verificar
systemctl status refresh-tailscale-cert.timer --no-pager
# Active: active (waiting)

systemctl list-timers refresh-tailscale-cert.timer --all
# NEXT                            LEFT      LAST   ...   UNIT
# 2026-05-01 ...                  ...                   refresh-tailscale-cert.timer
```

> **`Persistent=true`**: si la Pi está apagada en el momento del disparo, `systemd` ejecuta el `service` al siguiente arranque. Es importante para una Pi que pueda haber estado apagada durante un viaje largo.

> **No se usa cron**: `systemd` timer queda **versionado en este documento** (no en `/etc/crontab` o un fichero suelto), encaja con la observabilidad por `journalctl -u refresh-tailscale-cert.service`, y respeta el patrón "ningún cron oculto" del plan.

Forzar una primera ejecución para confirmar que el flujo `timer → service → script` funciona:

```bash
sudo systemctl start refresh-tailscale-cert.service

journalctl -u refresh-tailscale-cert.service -n 20 --no-pager
# refresh-tailscale-cert.service: Deactivated successfully.
# Cert renovado para pi.tailnet-NOMBRE.ts.net; Caddy recargado.
```

Como `tailscale cert` es idempotente (no reemite si quedan más de 14 días), una segunda ejecución a los pocos minutos no genera tráfico real contra Let's Encrypt; solo lee el cert existente.

### 4) Activar el bloque `pi.{$TAILNET_DOMAIN}` en el Caddyfile

`04-caddy.md` dejó el bloque versionado en `stacks/caddy/Caddyfile` y materializado en `/mnt/hd2t/apps/caddy/etc/Caddyfile`, **comentado** (líneas con `#` al inicio). Ahora se descomenta. La forma más cómoda es editar la **plantilla** (en git) y re-materializar:

```bash
cd /home/homelab/homelab

# Eliminar el comentario de las líneas del bloque pi.{$TAILNET_DOMAIN}.
# El bloque vive entre la cabecera "# Bloque del tailnet" y la cabecera
# "# Drop-ins por servicio". Se reescribe con un sed acotado:
sed -i '/^# pi\.{\$TAILNET_DOMAIN}/,/^# }$/{s/^# //; s/^#$//;}' \
    stacks/caddy/Caddyfile

# Verificar la edición
grep -n -E '^pi\.' stacks/caddy/Caddyfile
# 348:pi.{$TAILNET_DOMAIN} {
```

Re-materializar y validar:

```bash
install -o homelab -g homelab -m 0644 \
    stacks/caddy/Caddyfile  /mnt/hd2t/apps/caddy/etc/Caddyfile

# Validar dentro del contenedor (ahora con TAILNET_DOMAIN real ya en el .env)
docker compose -f stacks/caddy/docker-compose.yml \
    exec caddy caddy validate --config /etc/caddy/Caddyfile
# Valid configuration

# Reload sin downtime
docker kill --signal=SIGUSR1 caddy
# (sin output; el reload se ve en logs)

docker compose -f stacks/caddy/docker-compose.yml logs --tail 10 caddy
# {"level":"info","msg":"using config from file"...}
# {"level":"info","msg":"reloaded"}
```

Versionar el cambio:

```bash
git add stacks/caddy/Caddyfile stacks/caddy/.env.example
git -c commit.gpgsign=false status
git -c commit.gpgsign=false diff --cached --stat
git -c commit.gpgsign=false commit -m "feat(caddy): activar bloque pi.\${TAILNET_DOMAIN} para Tailscale"
```

> El `.env` real (con `TAILNET_DOMAIN=tailnet-NOMBRE.ts.net`) **no** se versiona; sí el `.env.example` con `EJEMPLO.ts.net`.

### 5) Verificar el flujo HTTPS del tailnet

Desde un dispositivo del operador conectado al tailnet (laptop, móvil con cliente Tailscale activo):

```bash
# Resolución MagicDNS
dig +short pi.tailnet-NOMBRE.ts.net
# 100.x.y.z

# HTTP -> HTTPS (308 de Caddy)
curl -sI http://pi.tailnet-NOMBRE.ts.net/ | head -1
# HTTP/1.1 308 Permanent Redirect

# HTTPS raíz (mensaje placeholder del bloque pi.*)
curl -s https://pi.tailnet-NOMBRE.ts.net/ -o /dev/null -w '%{http_code}\n'
# 200

# Path-routing a Pi-hole
curl -sI https://pi.tailnet-NOMBRE.ts.net/pihole/ | head -1
# HTTP/2 308   (redirección a /pihole/admin/)

# Cert público (sin -k)
curl -sI https://pi.tailnet-NOMBRE.ts.net/pihole/ -o /dev/null
# (sin error de cert: el navegador y curl confían sin instalar nada)
```

Probar **desde fuera de la red doméstica** (móvil con datos celulares + cliente Tailscale): exactamente las mismas URLs. Si el router doméstico está intacto (sin port-forward de `:80`/`:443`), confirmar que la respuesta no llega por la WAN sino por la mesh:

```bash
# Desde el móvil (root o app de tracing)
tracepath pi.tailnet-NOMBRE.ts.net
# Tras 1-2 saltos llega; el tráfico va por DERP de Tailscale o P2P, no por el router doméstico.
```

### 6) Patrón para añadir un servicio al bloque del tailnet

Cada Fase posterior, al añadir un servicio web al `Caddyfile`, decide si publicarlo **también** vía tailnet. El patrón:

```caddy
# /etc/caddy/conf.d/NN-servicio.caddy   (o ediciones al bloque pi.*)

pi.{$TAILNET_DOMAIN} {
    # ... resto del bloque ...

    handle_path /servicio/* {
        reverse_proxy http://servicio:PUERTO_INTERNO {
            header_up Host {host}
            header_up X-Real-IP {remote_host}
            header_up X-Forwarded-For {remote_host}
            header_up X-Forwarded-Proto {scheme}
        }
    }
}
```

Atención a aplicaciones web que **no** aceptan ser servidas bajo un *path* (asumen rutas absolutas en su HTML/JS): Jellyfin lo soporta con `Networking → Base URL`; Nextcloud **no** lo soporta cómodamente. Para esas, las opciones son:

- Servir solo en LAN (`servicio.{$DOMAIN_LAN}`) y aceptar que el acceso remoto requiere el laptop del operador, no un móvil de un familiar.
- Renombrar el nodo del tailnet a algo más corto y publicar el servicio como `servicio.${TAILNET_DOMAIN}` con un cert dedicado (Tailscale soporta múltiples nombres por nodo; cada uno requiere su `tailscale cert` separado y su entrada en MagicDNS o un alias).
- `tailscale serve` (modo nuevo, fuera del alcance de este documento): expone un puerto dentro del tailnet sin pasar por Caddy. Reabrible si el path-routing se vuelve doloroso.

### 7) DNS del tailnet sobre los clientes (no sobre la Pi)

La decisión `--accept-dns=false` de la Pi se reitera aquí: la Pi **no** consume MagicDNS. Sus consultas siguen yendo a Pi-hole (`192.168.1.2`), que delega a Unbound (`192.168.1.3`). El DNS del tailnet (resolver `100.100.100.100` que sirve los `*.ts.net`) lo usan **los otros dispositivos del operador** cuando están conectados al tailnet, gracias a su `--accept-dns=true` por defecto.

Esto resuelve también el detalle de que los clientes del tailnet, **al estar dentro de casa con el cliente Tailscale activo**, sigan resolviendo `pihole.lan` correctamente: MagicDNS solo se aplica a `*.ts.net`; el resto se delega al DNS de la red local del cliente, que en el caso del operador en casa será Pi-hole (porque su DHCP entrega `192.168.1.2` como DNS).

> **Posible ambigüedad**: si el operador con su laptop está **fuera de casa** y conectado al tailnet, ¿`pihole.lan` resuelve? **No**, porque no hay ruta a `192.168.1.2` desde fuera (subnet router está deshabilitado). El acceso fuera de casa va por `pi.${TAILNET_DOMAIN}/pihole/`. Esa es exactamente la separación que el plan quiere.

---

## Almacenamiento

| Ruta | Soporte | Owner:Group | Modo | Contenido |
|---|---|---|---|---|
| `/var/lib/tailscale/` | microSD | `root:root` | `0700` | Estado del demonio: clave de máquina (`tailscaled.state`), llave privada del nodo, cache de derp/peers. **No** copiar a otro host: cada nodo tiene su clave única. |
| `/etc/default/tailscaled` | microSD | `root:root` | `0644` | Flags arranque del demonio (`PORT`, `TS_DEBUG_FIREWALL_MODE`, …). En este homelab se queda con valores por defecto. |
| `/etc/apt/sources.list.d/tailscale.list` | microSD | `root:root` | `0644` | Repositorio APT. **Versionado** indirectamente: lo recrea el bloque "Instalación" del documento. |
| `/usr/share/keyrings/tailscale-archive-keyring.gpg` | microSD | `root:root` | `0644` | Llave del repo. Idem. |
| `/etc/systemd/system/refresh-tailscale-cert.service` | microSD | `root:root` | `0644` | Service unit del timer. Reproducible desde este documento. |
| `/etc/systemd/system/refresh-tailscale-cert.timer` | microSD | `root:root` | `0644` | Timer unit. Idem. |
| `/home/homelab/homelab/scripts/refresh-tailscale-cert.sh` | microSD | `root:root` | `0750` | Script de renovación. **Versionado** en el repo (`stacks/caddy/scripts/`, materializado por `04-caddy.md`). |
| `/mnt/hd2t/apps/caddy/etc/tailscale/cert.pem` | hd2t | `root:root` | `0644` | Cert público del tailnet. Reproducible (`tailscale cert ...`) si se pierde, siempre que el demonio esté autenticado. |
| `/mnt/hd2t/apps/caddy/etc/tailscale/key.pem` | hd2t | `root:root` | `0640` | Llave privada del cert. Idem. |

> **Tamaño**: `/var/lib/tailscale/` queda en pocas decenas de KB. El demonio no almacena tráfico; solo metadatos.

---

## Backup

A nivel del repositorio del homelab (Fase 7 — Borgmatic):

| Artefacto | Estrategia |
|---|---|
| Este documento (`docs/03-red/05-tailscale.md`) | Versionado en git. Reproducible. |
| Service y timer unit | El propio documento los recrea con `tee`. **No** se versionan en el repo (viven en `/etc/systemd/system/`); si la convención del homelab evoluciona a versionar también unidades systemd, se mueven a `system/` en el repo. Reabrible. |
| `stacks/caddy/.env` con `TAILNET_DOMAIN` real | **No** versionado (en `.gitignore`). Respaldo de fichero al respaldar `/home/homelab/homelab/` con Borg. |

A nivel de datos (Borgmatic, Fase 7):

| Ruta | ¿Se respalda? | Por qué |
|---|---|---|
| `/var/lib/tailscale/` | **Sí**. | La clave de máquina es lo que identifica el nodo en el tailnet. Sin respaldo, tras un reflasheo el operador tiene que **autenticar de nuevo** desde el navegador (no es destructivo, pero sí manual) y el nodo aparece como **nuevo** en el panel de admin (la entrada vieja queda como "expired" hasta que se borre manualmente). Con respaldo, restaurar a `/var/lib/tailscale/`, arrancar `tailscaled`, y la Pi vuelve al tailnet con su misma identidad y misma IP CGNAT. **Excluir el contenido de `/var/lib/tailscale/derpkey/` si el respaldo se almacena en un volumen al que pueda acceder otro host**: contiene secretos de transporte. La cifra Borg ya cubre esa preocupación si el repositorio Borg está cifrado con passphrase. |
| `/etc/systemd/system/refresh-tailscale-cert.{service,timer}` | **Sí** (entra en `/etc/`). | Reproducibles desde este documento, pero el respaldo evita reescribir manualmente. |
| `/mnt/hd2t/apps/caddy/etc/tailscale/{cert.pem,key.pem}` | **Sí** (lo cubre `04-caddy.md`). | Cert reproducible, pero respaldarlo evita la regeneración tras restore. |
| `/etc/apt/sources.list.d/tailscale.list` y la llave en `/usr/share/keyrings/` | **Sí** (entra en `/etc/`). | Idem. |

Procedimiento de **restore** tras pérdida total (reflasheo + Borg):

1. Recrear sistema base (Fase 1), Docker (Fase 2.1), red `homelab` (Fase 2.2), Pi-hole (`02-pihole.md`), Unbound (`03-unbound.md`), Caddy (`04-caddy.md`).
2. Reinstalar Tailscale (`apt install tailscale`).
3. Restaurar `/var/lib/tailscale/` desde Borg con permisos `0700 root:root`. **No** ejecutar `tailscale up` aún.
4. `sudo systemctl restart tailscaled`. El demonio detecta su estado, vuelve al tailnet con la misma identidad. `tailscale status` confirma.
5. Restaurar las dos unidades systemd y `systemctl daemon-reload && systemctl enable --now refresh-tailscale-cert.timer`.
6. Restaurar `/mnt/hd2t/apps/caddy/etc/tailscale/{cert.pem,key.pem}`. Si Borg solo tiene una versión vieja del cert (ya caducada), ejecutar `sudo /home/homelab/homelab/scripts/refresh-tailscale-cert.sh` para emitir uno nuevo.
7. Verificar el flujo HTTPS desde un dispositivo del tailnet (sección "Verificar el flujo HTTPS del tailnet" arriba).

Si se decide **no** restaurar `/var/lib/tailscale/` (operación más limpia, p. ej. tras una sospecha de filtración):

```bash
sudo systemctl stop tailscaled
sudo rm -rf /var/lib/tailscale/*
sudo systemctl start tailscaled
sudo tailscale up --hostname=pi --accept-dns=false --accept-routes=false --ssh=false
# Abrir la URL de auth en el navegador
```

La Pi entra al tailnet con identidad **nueva** (otra IP CGNAT, otro `node-key`). En el panel de admin, eliminar la entrada vieja (si existe) para liberar el cupo. MagicDNS reasigna `pi.${TAILNET_DOMAIN}` al nodo nuevo en cuestión de segundos. El cert del tailnet se regenera en el siguiente disparo del timer (o manualmente con el script).

---

## Errores frecuentes y troubleshooting

| Síntoma | Causa probable | Resolución |
|---|---|---|
| `tailscale up` se queda esperando indefinidamente | El navegador del operador no abrió la URL de auth, o la conexión al servidor de coordinación falla. | Copiar la URL impresa por `tailscale up` a un dispositivo con navegador. Si el coordinador es inalcanzable, comprobar `curl -sI https://login.tailscale.com/`. |
| `tailscale status` muestra `pi` como `expired` | El nodo lleva mucho tiempo offline o la cuenta del tailnet expiró las máquinas (config "key expiry"). | En el panel `Machines → pi → Disable key expiry` para evitarlo, o reautenticar con `sudo tailscale up`. |
| `tailscale cert` falla con `HTTPS not enabled on tailnet` | El botón "Enable HTTPS" del panel no se pulsó. | Activarlo en `https://login.tailscale.com/admin/dns/https`. |
| `tailscale cert` falla con `MagicDNS not enabled` | MagicDNS está apagado en el panel. | Activarlo en `https://login.tailscale.com/admin/dns/`. |
| `tailscale cert` falla con `rate limited` | Let's Encrypt limita ~5 emisiones por dominio por semana. | Esperar; el cert vigente sigue siendo válido. Si hubo un bucle de regeneración (script ejecutado en loop por error), usar el cert vigente y desactivar el timer hasta investigar. |
| Caddy responde 502 en `https://pi.${TAILNET_DOMAIN}/pihole/` | El bloque `pi.*` no descomentó del todo (algunas líneas con `#` residual), o el `Caddyfile` del bind mount no se actualizó. | `grep -nE '^# *pi\.' /mnt/hd2t/apps/caddy/etc/Caddyfile` debe no devolver nada. Re-`install` desde `stacks/caddy/Caddyfile`. |
| `https://pi.${TAILNET_DOMAIN}/` muestra cert válido pero nunca termina de cargar | Caddy escucha en `tailscale0` pero el firewall del host (UFW) lo bloquea en esa interfaz. | Verificar `sudo ufw status verbose | grep tailscale0`. Si falta, aplicar la regla de la sección "Activar UFW para `tailscale0`". |
| `tailscale ping <otro nodo>` funciona pero `https://pi.*/pihole/` no | Caddy está parado, o el cert del tailnet no existe y el bloque `pi.*` falla al cargarse. | `docker ps --filter name=caddy` y `ls /mnt/hd2t/apps/caddy/etc/tailscale/`. Renovar con el script. |
| Cliente Tailscale en Android/iOS no resuelve `pi.${TAILNET_DOMAIN}` | MagicDNS no está activo en el cliente (en algunos dispositivos hay que toggle "Use Tailscale DNS" en la app). | Activar la opción en la app del cliente. |
| Tras renovar el cert, Caddy sigue sirviendo el cert antiguo | El `SIGUSR1` no llegó (`docker kill` falló porque el contenedor se reinició entre medias). | `docker compose -f stacks/caddy/docker-compose.yml restart caddy`. |
| `apt update` falla en el repo de Tailscale tras un reboot prolongado | La llave del repo se rotó (raro pero documentado). | Re-descargar `bookworm.noarmor.gpg` con el `curl` de la sección de instalación. |
| `tailscale up --reset --hostname=pi-replica` (intento de cambiar hostname) deja al tailnet con dos entradas | Cambiar el hostname crea un nodo **nuevo** desde la perspectiva del coordinator. | En el panel, eliminar la entrada con el hostname viejo. |
| Otro nodo del tailnet (móvil) usa más datos de los esperados | El móvil tiene `--accept-routes=true` por defecto; si en algún momento se activa subnet router en la Pi, el móvil enrutaría tráfico LAN a través de la mesh. | No activar subnet router (decisión de este documento). Si se activa con cuidado, considerar `--accept-routes=false` en clientes móviles. |
| `journalctl -u refresh-tailscale-cert.service` muestra `permission denied` al escribir el cert | Permisos del directorio `/mnt/hd2t/apps/caddy/etc/tailscale/` cambiados. | Restaurar con `sudo install -d -o root -g root -m 0750 /mnt/hd2t/apps/caddy/etc/tailscale`. |
| El `RandomizedDelaySec=1d` del timer dispara la renovación a una hora inconveniente | Es cosmético: el script es idempotente y dura segundos. | Si molesta, bajar a `RandomizedDelaySec=1h`. |

---

## Decisiones que **no** se toman en este documento

- **Subnet router selectivo** (`--advertise-routes=192.168.1.50/32` para un IP concreto): se queda como reabrible si aparece un caso real. El argumento "cualquier subred" se rechaza explícitamente arriba.
- **Exit node**: idem; reabrible.
- **Tailscale SSH** (`--ssh`): queda como alternativa al `sshd` clásico. Razonado arriba; reabrible si el operador prefiere autenticación por identidad del tailnet.
- **Funnel** (`tailscale funnel`): explícitamente rechazado por incompatibilidad con el alcance del homelab.
- **Tailscale serve por servicio** (`tailscale serve --tcp ...`): alternativa a Caddy para exponer servicios al tailnet sin reverse proxy. Hoy se prefiere centralizar en Caddy (CA interna en LAN + cert tailnet único + Caddyfile versionable). Reabrible si algún servicio web no tolera path-routing.
- **Multi-tenant ACLs** (`tagOwners`, `acls`): el plan `Personal` (gratis) lo soporta, pero la política por defecto es suficiente para un único operador. Se reabrirá si entra un familiar al tailnet con accesos parciales.
- **Subdominios `*.pi.tailnet.ts.net`**: Tailscale en algunas configuraciones soporta wildcards/subdominios MagicDNS; en plan `Personal` la regla por defecto es un nombre por nodo. Path-routing en Caddy es la solución sin depender del plan; reabrible si Tailscale generaliza el wildcard.
- **IPv6 dentro del tailnet**: el tailnet asigna también una `fd7a:115c:a1e0::/48`. Caddy con `0.0.0.0:443` no escucha v6; en este homelab no se necesita (todos los clientes del operador son dual-stack y prefieren v4 en CGNAT). Se reabre si se documenta un caso v6-only.
- **Métricas / Observabilidad de Tailscale**: `tailscaled` expone métricas en `localhost:5252/debug/metrics` (con flag); se integra con Prometheus en Fase 6, no aquí.
- **Backups del estado del tailnet a otra ubicación**: el `/var/lib/tailscale/` ya entra en Borg (Fase 7). No se hace nada adicional.

---

## Verificación Final

Para considerar el homelab "Fase 3 completa" y pasar a Fase 4 (seguridad), todas estas comprobaciones deben pasar:

| Comprobación | Comando | Resultado esperado |
|---|---|---|
| Demonio activo | `systemctl is-active tailscaled` | `active` |
| Demonio habilitado | `systemctl is-enabled tailscaled` | `enabled` |
| Nodo autenticado en el tailnet | `tailscale status \| grep '^100\\.' \| grep -E '\\bpi\\b'` | una línea con la IP CGNAT y `pi` |
| Interfaz `tailscale0` | `ip -br -4 addr show tailscale0` | `tailscale0 UNKNOWN 100.x.y.z/32` |
| MagicDNS resolviendo desde otro nodo | en otro nodo: `dig +short pi.${TAILNET_DOMAIN}` | una IP `100.x.y.z` |
| Pi NO acepta DNS del tailnet | `cat /etc/resolv.conf \| grep -E '^nameserver'` | `nameserver 192.168.1.2` (Pi-hole), **no** `100.100.100.100` |
| UFW permite tráfico en `tailscale0` | `sudo ufw status verbose \| grep -E 'tailscale0.*ALLOW'` | dos líneas (v4 y v6) |
| Cert del tailnet existe | `sudo ls /mnt/hd2t/apps/caddy/etc/tailscale/{cert,key}.pem` | ambos ficheros |
| Cert del tailnet vigente | `sudo openssl x509 -in /mnt/hd2t/apps/caddy/etc/tailscale/cert.pem -noout -enddate` | `notAfter=...` con fecha futura > 14 días |
| Bloque `pi.{$TAILNET_DOMAIN}` activo en Caddyfile | `grep -E '^pi\\.\\{\\$TAILNET_DOMAIN\\}' /mnt/hd2t/apps/caddy/etc/Caddyfile` | una línea coincidente |
| Caddy validó el Caddyfile tras descomentar | `docker exec caddy caddy validate --config /etc/caddy/Caddyfile` | `Valid configuration` |
| Caddy lee el cert (sin permission denied) | `docker exec caddy ls /etc/caddy/tailscale/` | `cert.pem`, `key.pem` |
| Timer de renovación activo | `systemctl is-active refresh-tailscale-cert.timer` | `active` |
| Timer habilitado en boot | `systemctl is-enabled refresh-tailscale-cert.timer` | `enabled` |
| Próximo disparo del timer | `systemctl list-timers refresh-tailscale-cert.timer` | una fecha futura coherente |
| Service unit ejecutó correctamente al menos una vez | `journalctl -u refresh-tailscale-cert.service \| tail -2` | `Cert renovado para ...` |
| Repo APT de Tailscale configurado | `apt-cache policy tailscale \| grep 'pkgs.tailscale.com'` | una línea coincidente |
| `unattended-upgrades` cubre Tailscale | `grep Tailscale /etc/apt/apt.conf.d/50unattended-upgrades` | `"Tailscale:any";` |
| HTTPS LAN sigue funcionando | desde la LAN: `curl -ksI https://pihole.lan/admin/ \| head -1` | `HTTP/2 200` o `HTTP/2 302` |
| HTTPS tailnet desde otro nodo | desde un nodo del tailnet: `curl -sI https://pi.${TAILNET_DOMAIN}/pihole/ \| head -1` | `HTTP/2 308` |
| HTTPS tailnet con cert público (sin `-k`) | desde un nodo del tailnet: `curl -sI https://pi.${TAILNET_DOMAIN}/pihole/ -o /dev/null` | sin error de cert |
| Subnet router NO anunciado | `tailscale status --json \| grep -i AdvertisedRoutes` | vacío o `null` |
| Exit node NO anunciado | `tailscale status --json \| grep -i ExitNodeOption` | `false` |
| Sin port-forward en el router doméstico | en el panel del router: tabla NAT/Port Forwarding | sin entradas para `:80`/`:443` apuntando a la Pi |
| Persistencia tras reboot | `sudo reboot`; tras reconectar: `tailscale status` | nodo activo, IP igual, MagicDNS igual |

Cumplido el último punto, el homelab tiene **DNS con bloqueo** (Pi-hole), **resolución recursiva sin terceros** (Unbound), **reverse proxy interno con HTTPS válido** (Caddy con CA interna), y **acceso remoto sin abrir puertos** (Tailscale con cert público sobre `*.ts.net`). La Fase 3 queda cerrada y la siguiente puerta es la Fase 4: **seguridad de aplicación** (Authelia/SSO, gestión de secretos), donde Caddy ya tiene la estructura del Caddyfile preparada para introducir `forward_auth` sin reabrir nada de lo decidido aquí.

---

## Referencias

- [Documento anterior: `docs/03-red/04-caddy.md`](./04-caddy.md)
- [Documento siguiente: `docs/04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md)
- [Documento relacionado: `docs/01-sistema/03-seguridad-base.md`](../01-sistema/03-seguridad-base.md) — UFW y `fail2ban` con regla preparada para `tailscale0`.
- [Documento relacionado: `docs/03-red/02-pihole.md`](./02-pihole.md) — DNS LAN, no se mezcla con MagicDNS del tailnet.
- [Documento relacionado: `docs/03-red/04-caddy.md`](./04-caddy.md) — bloque `pi.{$TAILNET_DOMAIN}` y script `refresh-tailscale-cert.sh`.
- [Tailscale — Quickstart en Linux](https://tailscale.com/kb/1031/install-linux)
- [Tailscale — Repositorio APT para Debian Bookworm](https://pkgs.tailscale.com/stable/#debian-bookworm)
- [Tailscale — `tailscale up` y banderas](https://tailscale.com/kb/1080/cli)
- [Tailscale — MagicDNS](https://tailscale.com/kb/1081/magicdns)
- [Tailscale — HTTPS Certificates (`tailscale cert`)](https://tailscale.com/kb/1153/enabling-https)
- [Tailscale — Subnet routers](https://tailscale.com/kb/1019/subnets)
- [Tailscale — Exit nodes](https://tailscale.com/kb/1103/exit-nodes)
- [Tailscale — Tailscale SSH](https://tailscale.com/kb/1193/tailscale-ssh)
- [Tailscale — CGNAT range `100.64.0.0/10`](https://tailscale.com/kb/1015/100.x-addresses)
- [`systemd.timer(5)` — manpage Debian](https://manpages.debian.org/bookworm/systemd/systemd.timer.5.en.html)
- [`systemd.service(5)` — manpage Debian](https://manpages.debian.org/bookworm/systemd/systemd.service.5.en.html)
