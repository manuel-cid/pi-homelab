# Seguridad Base del Sistema

## Descripción

Tras `02-configuracion-inicial.md` la Raspberry Pi 5 está actualizada, con swap en `hd2t`, locale y zona horaria correctos. Está accesible por SSH desde la LAN con una clave pública pegada en el Imager y sigue conservando la contraseña del usuario `homelab` como respaldo. Falta dejar la Pi con un **mínimo defendible** antes de desplegar Tailscale (Fase 2) y Docker (Fase 3):

- Confirmar que la **clave SSH** del equipo de trabajo es la única vía de entrada y endurecer `sshd` para que no acepte contraseñas, root, ni métodos antiguos.
- **Renovar la contraseña** del usuario `homelab` por una larga, única y guardada en el gestor de contraseñas, manteniéndola solo como llave de `sudo` y consola física.
- Cerrar todo lo que no sea necesario con un **firewall declarativo (`ufw` sobre `nftables`)** que solo deja entrar SSH desde la LAN y desde la subred de Tailscale, y permite todo el tráfico saliente.
- Frenar la fuerza bruta residual (escaneos del propio segmento, IoT comprometida) con un **`fail2ban` mínimo, una sola jail, la de SSH**, sin filtros web que en este host no aplican.
- Activar **actualizaciones de seguridad automáticas (`unattended-upgrades`)** con reboots controlados, para no depender de que el operador haga `apt update` cada semana.

Todo este documento sigue siendo aplicable **antes** de instalar Tailscale: la Pi solo es accesible desde la LAN. La integración fina con Tailscale (qué interfaces se aceptan en `sshd`, qué subred autorizar) se cierra en `02-redes/01-tailscale.md` y `02-redes/02-acceso-remoto.md`; aquí se deja **preparado el carril**.

> **Recordatorio de alcance**: no se publica nada a internet. No se abren puertos en el router. No se instalan certificados Let's Encrypt. El "exterior" del homelab son únicamente la LAN doméstica y la mesh de Tailscale.

---

## Requisitos Previos

- `01-instalacion-os.md` aplicado: la Pi responde a `ssh homelab` con la clave pública del equipo de trabajo y el usuario `homelab` tiene `sudo`.
- `02-configuracion-inicial.md` aplicado: sistema actualizado, sin paquetes pendientes (`apt list --upgradable` vacío). Es importante porque parte de este documento (`unattended-upgrades`) **se autocomprueba ejecutando un dry-run de upgrade**, y arrastrar un upgrade pendiente confunde el resultado.
- Acceso paralelo a la Pi por **dos vías** durante el endurecimiento de SSH:
  1. La sesión SSH "principal" desde la que se ejecutan los comandos.
  2. **Una segunda sesión SSH abierta en otra terminal** (`ssh homelab` de nuevo) que se mantiene activa todo el documento. Si una recarga de `sshd` rompe el acceso por error de configuración, esta segunda sesión sigue viva y permite revertir antes de que cualquier reboot la cierre.
- Plan de recuperación física en caso de bloquearse fuera (errores graves en `sshd_config` o reglas de firewall demasiado restrictivas):
  - Apagar la Pi, sacar la microSD y montarla en el equipo de trabajo.
  - Editar el fichero ofensor (`/etc/ssh/sshd_config`, `/etc/ufw/user.rules`...) y volver a montar la SD.
  - Como alternativa, conectar HDMI + teclado USB y entrar en consola con el usuario `homelab` y la contraseña documentada.

Comprobaciones previas:

```bash
ssh homelab
# Ya dentro:
who                          # debe verse al menos la propia sesión
sudo -v                      # confirma que homelab puede elevar
ip -4 -br addr               # anotar la IP de eth0 y la subred LAN
ss -tnlp                     # listar qué hay escuchando: solo sshd en :22
```

Anotar la **subred de la LAN** (por ejemplo `192.168.1.0/24`). Es el dato del que depende la regla de `ufw` para SSH.

---

## Modelo de Amenaza

Antes de tocar nada conviene fijar contra qué se está protegiendo el host. Sin esto, "endurecer" se vuelve un ritual y se acaba copiando configuraciones inadecuadas para este escenario.

| Amenaza | ¿Aplica al homelab? | Mitigación en este doc |
|---|---|---|
| Bots de internet escaneando la IP pública | **No**: no hay puertos abiertos en el router. | Implícita: el firewall del router los para antes. Se confía en él como primera capa. |
| Fuerza bruta SSH desde la LAN (router IoT comprometido, smart TV, otro PC) | **Sí**: cualquier dispositivo de la LAN puede llegar al puerto 22 de la Pi. | `sshd` solo acepta clave pública (no contraseña), `fail2ban` banea IPs con N intentos fallidos. |
| Robo físico de la microSD | Parcial: si se roba la SD, los datos del SO son legibles fuera. | Fuera del alcance (no se cifra el SO con LUKS por coste/beneficio en una Pi headless). Se asume custodia física. |
| Vulnerabilidad reciente en `openssh-server`, `sudo`, `systemd`, kernel | **Sí**: cualquier paquete con CVE crítica. | `unattended-upgrades` aplica seguridad de Debian + Raspberry Pi en automático, con reboot programado. |
| Privesc desde un servicio Docker comprometido al host | **Sí**, futuro (Fase 3+). | Fuera del alcance de este doc; se trata en `03-docker/01-docker-engine.md` (rootless, `no-new-privileges`, redes per-stack…) y en `13-operaciones/02-respuesta-incidentes.md`. |
| Conexión externa no autorizada a un servicio (Jellyfin, Home Assistant, Vaultwarden) desde la propia LAN | **Sí**, futuro. | Fuera del alcance: aquí solo se cubre el **host**. La política de qué puerto se publica en qué interfaz se decide servicio a servicio en sus respectivos `docker-compose.yml`. |

El `ufw` y el `fail2ban` de este documento cubren la **superficie del host**: lo que escucha el sistema operativo en sí (en este momento, solo `sshd`). Cuando entren los servicios Docker se discutirá si se publican en `0.0.0.0`, en `eth0`, en `tailscale0` o en `127.0.0.1` con un proxy local. `ufw` no se usará como reverse proxy.

---

## Cambio de Contraseña del Usuario `homelab`

La contraseña que pusimos en el Imager se ha utilizado durante la instalación y figura en logs del sistema, en el `userconf.txt` que generó el Imager y posiblemente en el portapapeles del equipo de trabajo. No es razonable mantenerla a largo plazo. Se renueva ahora.

```bash
passwd
# Current password:  <contraseña del Imager>
# New password:      <contraseña larga y única, ≥ 24 caracteres>
# Retype new password:
```

Reglas que se aplican implícitamente vía PAM (`/etc/pam.d/common-password` por defecto en Bookworm, sin `libpam-pwquality`): no hay validación fuerte, lo único que comprueba es que coincida la confirmación. La calidad la pone quien la genera; el gestor de contraseñas (`bitwarden`, `keepassxc`, etc.) debe producirla aleatoria con al menos 24 caracteres.

> **Importante**: esta contraseña ya casi nunca se va a teclear. Sus dos usos son:
>
> 1. Ejecutar `sudo` desde la sesión SSH (que entra por clave pública pero pide contraseña al elevar).
> 2. Iniciar sesión por consola física (HDMI + teclado) si la microSD o el SSH se rompen.
>
> Por ello **no** se pone una "fácil de teclear": si fuera fácil, abriría una vía paralela a la clave SSH desde cualquier dispositivo de la LAN.

Confirmar que el cambio surte efecto sin romper nada:

```bash
sudo -K            # invalida la cache de credenciales sudo
sudo -v            # debe pedir la NUEVA contraseña
```

`sudo -K` es necesario porque `sudo` cachea credenciales por terminal durante 15 minutos por defecto y enmascararía un fallo silencioso.

### ¿Y `sudo` sin contraseña (`NOPASSWD`)?

Tentador para automatización, pero **no se aplica**: deja el host expuesto a que cualquier proceso de la sesión del usuario `homelab` (o un script descargado por error) ejecute comandos como root sin fricción. La automatización del homelab (Borg, Watchtower, etc.) corre dentro de Docker o como timer de systemd con sus propias unidades; no hay caso real para `NOPASSWD`. Se mantiene el comportamiento por defecto.

---

## Endurecimiento de SSH

El Imager ya dejó `PasswordAuthentication no` aplicado vía drop-in (`/etc/ssh/sshd_config.d/rpi-imager.conf` o similar). Aquí se consolida en un fichero propio del homelab, explícito y versionable, y se afinan otras opciones.

### Verificar el estado actual

```bash
ls /etc/ssh/sshd_config.d/
sudo sshd -T | grep -E "^(passwordauthentication|pubkeyauthentication|permitrootlogin|kbdinteractiveauthentication|usepam|x11forwarding|allowusers)"
```

`sshd -T` imprime la configuración **efectiva** tras combinar `sshd_config` y todos los drop-ins de `sshd_config.d/`. Es la única fuente fiable: editar `sshd_config` directamente puede ser un no-op si un drop-in lo sobrescribe después.

### Drop-in del homelab

Crear `/etc/ssh/sshd_config.d/10-homelab.conf` con la política completa. Drop-in con prefijo `10-` para que tenga prioridad clara sobre `rpi-imager.conf` (que suele numerarse a `99-`).

```bash
sudo tee /etc/ssh/sshd_config.d/10-homelab.conf >/dev/null <<'EOF'
# Homelab — política de SSH
# Solo clave pública, sin password ni keyboard-interactive,
# sin login de root y limitando explícitamente qué usuarios pueden entrar.

PermitRootLogin            no
PasswordAuthentication     no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication       yes
UsePAM                     yes

# Solo el usuario administrador del homelab.
AllowUsers                 homelab

# Sesiones interactivas: cortar las inactivas y limitar autenticaciones fallidas.
ClientAliveInterval        300
ClientAliveCountMax        2
LoginGraceTime             20
MaxAuthTries               3
MaxSessions                5

# Sin reenvíos innecesarios. El homelab no es un bastion host.
X11Forwarding              no
AllowAgentForwarding       no
AllowTcpForwarding         no
GatewayPorts               no
PermitTunnel               no
EOF
```

Significado de las opciones que merecen comentario:

| Opción | Por qué este valor |
|---|---|
| `PermitRootLogin no` | Bookworm ya viene con `prohibit-password`, pero `no` es estricto y deja constancia en el sistema de que **nunca** se entra como root. Para administrar se usa `homelab` + `sudo`. |
| `KbdInteractiveAuthentication no` | Cierra el método "interactivo por teclado" que en algunas configuraciones PAM equivale a contraseña encubierta. |
| `AllowUsers homelab` | Whitelist explícita: si en el futuro se crea un usuario para automatización (`borg`, `prometheus_exporter`...), o se reactiva `pi`, **no podrá entrar por SSH** hasta añadirlo aquí explícitamente. Defensa contra contraseñas reseteadas por error. |
| `ClientAliveInterval 300` + `ClientAliveCountMax 2` | El servidor manda keepalive cada 5 min y desconecta tras 2 fallos seguidos (~10 min). Evita sesiones zombi acumuladas tras pérdidas de red. |
| `MaxAuthTries 3` | Tres intentos por conexión antes de cortar. Combinado con `fail2ban` baja el ratio de intentos por IP. |
| `AllowTcpForwarding no` + `AllowAgentForwarding no` + `PermitTunnel no` | El homelab no es bastion ni jump-host. Apagar túneles reduce superficie por si una clave se filtrase. Si en el futuro se necesitase tunelizar (debugging puntual), se reactiva temporalmente. |
| `X11Forwarding no` | Lite no tiene Xorg; reenvío X11 es ruido. |
| `LoginGraceTime 20` | Tiempo máximo para autenticar tras conectar. Por defecto son 120s, una eternidad para clave pública. |

### Validar y recargar

`sshd` admite chequeo sintáctico antes de aplicar. **Esto debe hacerse siempre** antes del `restart`:

```bash
sudo sshd -t && echo "sshd config OK"
sudo sshd -T | grep -E "^(passwordauthentication|pubkeyauthentication|permitrootlogin|allowusers|maxauthtries)"
```

Si `sshd -t` no imprime nada y devuelve código 0, la config es válida. Recargar:

```bash
sudo systemctl reload ssh   # nombre de la unit en Debian Bookworm
# Equivalente a HUP del demonio. Mantiene las sesiones existentes;
# solo afecta a las nuevas conexiones.
```

> **Nunca usar `restart` aquí**: cierra todas las sesiones SSH activas, incluida la propia. Si la nueva config es inválida y `sshd` no levanta, queda fuera. `reload` aplica la config nueva pero no toca conexiones abiertas, dejando margen para revertir.

### Verificar el endurecimiento desde la otra sesión (y desde fuera)

Desde el equipo de trabajo, en una **tercera** terminal:

```bash
ssh homelab                                  # debe seguir entrando con clave
ssh -o PubkeyAuthentication=no homelab       # debe rechazarse: 'Permission denied (publickey)'
```

El segundo comando fuerza al cliente a no usar la clave pública. Si la respuesta es `Permission denied (publickey)` (y no `(publickey,password)` o un prompt), el endurecimiento está aplicado.

### Claves SSH del lado del cliente

La clave del equipo de trabajo (`~/.ssh/id_ed25519`) ya está en `authorized_keys` desde el Imager. Reglas que conviene fijar:

- La clave privada **nunca** sale del equipo de trabajo.
- Si se usa más de un equipo (portátil + sobremesa), cada uno genera **su propio par** y se añade su pública a `~/.ssh/authorized_keys` del usuario `homelab`. **No** se copia la misma clave privada entre equipos.
- Para añadir una clave nueva desde otro equipo:

  ```bash
  # Desde el equipo nuevo (con acceso temporal a la Pi por algún medio):
  ssh-copy-id -i ~/.ssh/id_ed25519.pub homelab@<ip-de-la-pi>
  # ssh-copy-id no funcionará si PasswordAuthentication=no y todavía no
  # tienes ninguna clave válida. En ese caso, se añade manualmente:
  cat ~/.ssh/id_ed25519.pub | ssh homelab "cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
  ```

- El fichero `~/.ssh/authorized_keys` debe tener permisos `600` y `~/.ssh/` permisos `700`. `sshd` rechaza claves con permisos demasiado abiertos (mensaje "Authentication refused: bad ownership or modes").

  ```bash
  ls -ld ~/.ssh ~/.ssh/authorized_keys
  # drwx------  ...  /home/homelab/.ssh
  # -rw-------  ...  /home/homelab/.ssh/authorized_keys
  ```

- Conviene anotar la **fingerprint del host** (la parte servidora) tras este punto para detectar suplantaciones futuras:

  ```bash
  for f in /etc/ssh/ssh_host_*_key.pub; do ssh-keygen -lf "$f"; done
  ```

  Pegar el resultado en el gestor de contraseñas junto con la entrada del homelab.

---

## Firewall: `ufw` sobre `nftables`

### Por qué `ufw` y no `nftables` puro

Debian Bookworm ya usa `nftables` como backend; `iptables` es solo un wrapper de compatibilidad. Hay tres opciones razonables:

1. **Reglas `nftables` a mano** en `/etc/nftables.conf`. Máxima expresividad, mínima ergonomía. Cambios cotidianos ("permitir Tailscale, permitir 8123 desde tal subred…") obligan a reescribir el set de reglas y reload completo.
2. **`firewalld`**. Pensado para escritorio y servidores con muchas zonas. Aporta `cockpit`, `nm-connection-editor`, etc., que aquí no se usan. Sobreingenierizado para una Pi headless.
3. **`ufw`**. Frontend simple, declarativo en el sentido "un comando por regla", **persistente por defecto** en `/etc/ufw/`, que internamente compila a `nftables`. Suficiente para la política del homelab, fácil de auditar (`ufw status numbered`).

Se elige **`ufw`** por simplicidad operativa. La política del homelab es deliberadamente sencilla: deny-all entrante salvo SSH desde LAN/Tailscale, allow-all saliente. No hay caso para reglas más complejas a nivel de host; cuando entren servicios Docker, las reglas de exposición las gestiona Docker en su propia chain de `nftables` (`DOCKER-USER`).

### Instalación y política por defecto

```bash
sudo apt update
sudo apt install -y ufw

# Política por defecto: bloquear entrante, permitir saliente, dejar forward bloqueado
# (Docker lo destrabará por sí mismo cuando se instale en Fase 3).
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw default deny forward
```

Nota crítica: **no activar `ufw` todavía**. Antes hay que añadir la regla de SSH; si se enable sin ella, la sesión SSH actual cae con la primera regla y la Pi queda inaccesible (fuera del posible plan de recuperación física).

### Permitir SSH desde la LAN

Sustituir `192.168.1.0/24` por la subred real anotada al principio:

```bash
LAN=192.168.1.0/24
sudo ufw allow from "$LAN" to any port 22 proto tcp comment 'SSH desde LAN'
```

El comentario lo guarda `ufw` y aparece en `ufw status verbose`, útil cuando el set de reglas crezca.

### Hueco para Tailscale (preparado, no activo)

Tailscale (Fase 2) crea la interfaz `tailscale0` con direcciones del rango **CGNAT `100.64.0.0/10`**. La política coherente con "todo lo que entre por Tailscale es de confianza" es permitir cualquier puerto **a través de esa interfaz** una vez instalada:

```bash
# DEJAR PREPARADA la regla pero comentada hasta que tailscale0 exista.
# Cuando se aplique 02-redes/01-tailscale.md, descomentar la siguiente línea
# (o ejecutarla allí, donde se documentará explícitamente):
#
# sudo ufw allow in on tailscale0 comment 'Tailscale: confiar en mesh'
```

**No** se permite tráfico SSH del CGNAT `100.64.0.0/10` por IP de origen sin filtrar por interfaz: cualquier dispositivo en una red doméstica que reutilice ese rango (ISPs con CGNAT, algunas redes corporativas) podría acabar coincidiendo. Filtrar por **interfaz** (`tailscale0`) es lo correcto: solo el tráfico que llega cifrado por la VPN cumple la regla.

Hasta llegar a Fase 2 esta línea queda como comentario en este documento. Se documentará y aplicará explícitamente en `02-redes/01-tailscale.md`.

### Logging

```bash
sudo ufw logging low
```

`low` registra denegaciones en `/var/log/ufw.log` (vía `kern.log`/`journal`) sin generar el ruido masivo de `medium`/`high`. Es suficiente para revisar a posteriori qué intentó conectar y desde dónde, sin desgastar la microSD con megas de logs por minuto. La rotación la cubre `journald` y `logrotate` con sus configuraciones por defecto.

### Activar `ufw`

Antes de pulsar el "interruptor", repasar la regla con `--dry-run`:

```bash
sudo ufw show added
# Should show only: ufw allow from 192.168.1.0/24 to any port 22 proto tcp
```

Activar:

```bash
sudo ufw --force enable
sudo ufw status verbose
```

Salida esperada (con la subred y el comentario):

```
Status: active
Logging: on (low)
Default: deny (incoming), allow (outgoing), deny (routed)
New profiles: skip

To                         Action      From
--                         ------      ----
22/tcp                     ALLOW IN    192.168.1.0/24             # SSH desde LAN
```

Verificar **inmediatamente** desde la otra sesión SSH (la que se dejó abierta al empezar) que sigue funcionando:

```bash
who           # debe seguir apareciendo la sesión paralela
ssh homelab   # desde el equipo de trabajo, en una terminal adicional
```

Si la conexión nueva falla:

- Comprobar que el equipo de trabajo está en la misma subred que `$LAN`.
- `sudo ufw status numbered` y, si la regla no aparece, recrearla con la subred correcta.
- En el peor caso, desde la sesión que sigue viva: `sudo ufw disable` para volver al estado pre-firewall y diagnosticar.

### Persistencia y arranque

`ufw` se arranca solo en boot vía `systemctl enable ufw.service`, que `--force enable` ya activa. Validar:

```bash
systemctl is-enabled ufw    # enabled
systemctl is-active ufw     # active
```

### Interacción con Docker

Aviso para cuando llegue la Fase 3: **Docker sobrescribe reglas de `iptables`/`nftables` para sus redes propias** y, en su modo por defecto (`iptables=true`), publica los puertos `-p` saltándose las reglas de `ufw`. No es bug de `ufw`: es así por diseño en Docker. La estrategia que se va a usar y se documenta en `03-docker/01-docker-engine.md`:

- Publicar los servicios solo en interfaces concretas (`-p 192.168.1.50:8123:8123/tcp` o `-p 127.0.0.1:8123:8123`), no en `0.0.0.0`.
- Servicios "internos" entre contenedores van por redes Docker bridge sin publicar.
- Para servicios accesibles desde el equipo de trabajo, exposición por LAN o por Tailscale según política.

`ufw` se queda gobernando el tráfico al **host** (puerto 22 de SSH ahora; en el futuro métricas o agentes que escuchen en el SO directamente). No se intenta usar `ufw` como filtro entre LAN y contenedores Docker.

---

## `fail2ban`: jail de SSH

`fail2ban` lee `/var/log/auth.log` (o el journal en Bookworm) en busca de patrones de intentos fallidos y, cuando una IP supera un umbral, la añade a una chain de `nftables` que rechaza nuevos paquetes durante un tiempo. En el homelab la **única jail necesaria** es la de SSH: no hay ningún otro servicio en el host que escuche autenticación.

### Instalación

```bash
sudo apt install -y fail2ban
```

### Configuración local

`fail2ban` distingue `*.conf` (paquete, sobrescribible en upgrades) y `*.local` (operador, persistente). Crear `/etc/fail2ban/jail.local` con la política del homelab:

```bash
sudo tee /etc/fail2ban/jail.local >/dev/null <<'EOF'
[DEFAULT]
# Sólo se utiliza la jail [sshd]; las demás permanecen disabled (default upstream).
backend       = systemd
banaction     = nftables[type=multiport]
banaction_allports = nftables[type=allports]

# Reloj y umbrales razonables para una LAN doméstica.
findtime  = 10m
maxretry  = 5
bantime   = 1h
bantime.increment = true
bantime.factor    = 2
bantime.maxtime   = 1d

# No banear nunca a la propia LAN ni al rango Tailscale CGNAT.
# Ajustar la subred si la LAN no es 192.168.1.0/24.
ignoreip = 127.0.0.1/8 ::1 192.168.1.0/24 100.64.0.0/10

[sshd]
enabled = true
port    = ssh
mode    = aggressive
EOF
```

Razonamiento de cada bloque:

| Opción | Por qué |
|---|---|
| `backend = systemd` | En Bookworm, `auth.log` puede no existir como fichero plano si `rsyslog` no está instalado por defecto; el journal sí existe siempre. Leer del journal evita depender de `rsyslog`. |
| `banaction = nftables[type=multiport]` | El sistema usa `nftables`, no `iptables`. La acción `nftables` añade IPs a un set propio (`f2b-sshd`) en lugar de pelear con `ufw` por la chain principal. Conviven sin colisionar. |
| `findtime 10m`, `maxretry 5` | Cinco fallos en 10 minutos para banear. Más estricto que el default (5/10m vs 5/10m, ok, igual) pero combinado con `MaxAuthTries 3` de `sshd` significa que cada IP tiene como mucho 5 conexiones × 3 intentos = 15 contraseñas antes del ban. Es de sobra para una LAN doméstica. |
| `bantime 1h` + `bantime.increment` | Primer ban: 1 hora. Reincidente: 2 h, 4 h… hasta 24 h. Castiga IPs que insistan tras un primer ban sin bloquear permanentemente IPs domésticas que un día se equivocaron. |
| `ignoreip` LAN + `100.64.0.0/10` | El equipo de trabajo no puede ser banearse a sí mismo si un día cambia de clave SSH y prueba contraseña varias veces "para ver". El rango Tailscale se whitelistea por la misma razón que en el firewall: tráfico ya autenticado por la VPN. **Nota**: esto significa que `fail2ban` no banearía un dispositivo de la LAN comprometido. Es un compromiso consciente: protege contra Internet hipotético + escaneos accidentales, no contra atacante interno persistente (que tendría problemas mayores que esta jail). |
| `[sshd] mode = aggressive` | Detecta no solo `Failed password` sino también intentos de auth con método inválido, baneando antes a bots que prueban usuarios inexistentes o protocolos viejos. |

### Activar y verificar

```bash
sudo systemctl enable --now fail2ban
sudo systemctl status fail2ban --no-pager
sudo fail2ban-client status
sudo fail2ban-client status sshd
```

`fail2ban-client status sshd` debe mostrar:

```
Status for the jail: sshd
|- Filter
|  |- Currently failed: 0
|  |- Total failed:     0
|  `- Journal matches:  _SYSTEMD_UNIT=ssh.service + _COMM=sshd
`- Actions
   |- Currently banned: 0
   |- Total banned:     0
   `- Banned IP list:
```

### Probar en seco que la jail dispara

Desde el equipo de trabajo, sin cifrarse fuera (es solo prueba), forzar fallos rápidos contra la propia Pi **desde una IP que no esté en `ignoreip`** no es trivial sin otra máquina; en una red doméstica probablemente no hay forma limpia. La verificación honesta del homelab es:

```bash
# Provocar un único fallo deliberado para ver la entrada en el journal:
ssh -o PubkeyAuthentication=no -o PreferredAuthentications=password homelab@<ip>
# (responder con cualquier cosa, sale 'Permission denied').

sudo fail2ban-client status sshd
# 'Total failed' debería incrementarse en 1.
```

Como la IP es la del equipo de trabajo en la LAN está en `ignoreip` y `fail2ban` la **registra como fallo pero no la banea**, que es exactamente lo deseado.

Para desbanear manualmente cuando proceda en el futuro:

```bash
sudo fail2ban-client unban <ip>
```

---

## `unattended-upgrades`: actualizaciones de seguridad automáticas

Mantener el homelab parcheado **sin depender de que el operador entre cada semana** es la única forma realista de no acumular CVEs. `unattended-upgrades` lo hace al estilo Debian: solo aplica el origen `Debian-Security` por defecto, deja el resto al criterio del operador.

### Instalación y activación

```bash
sudo apt install -y unattended-upgrades apt-listchanges

# Activa los timers /etc/apt/apt.conf.d/20auto-upgrades con valores estándar
# (update y unattended-upgrade diarios). El TUI no es interactivo si usamos el flag:
sudo dpkg-reconfigure --priority=low --frontend=noninteractive unattended-upgrades
```

Validar que `apt-daily.timer` y `apt-daily-upgrade.timer` están habilitados:

```bash
systemctl list-timers apt-daily.timer apt-daily-upgrade.timer
```

### Política del homelab

Sobrescribir lo que `dpkg-reconfigure` haya dejado con un drop-in propio, para que sea explícito y sobreviva a un upgrade del paquete:

```bash
sudo tee /etc/apt/apt.conf.d/52unattended-upgrades-homelab >/dev/null <<'EOF'
// Homelab — política de unattended-upgrades

// Orígenes desde los que aplicar parches automáticos.
// Solo seguridad de Debian + Raspberry Pi. Updates "normales" (versiones
// nuevas de paquetes) se aplican manualmente con apt full-upgrade tras
// revisar el changelog (cfr. 02-configuracion-inicial.md).
Unattended-Upgrade::Origins-Pattern {
    "origin=Debian,codename=${distro_codename},label=Debian";
    "origin=Debian,codename=${distro_codename},label=Debian-Security";
    "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
    "origin=Raspberry Pi Foundation";
};

// Paquetes que NO se tocan automáticamente (cambios suelen requerir reinicio
// orquestado a mano o tienen riesgo extra en Pi).
Unattended-Upgrade::Package-Blacklist {
    "linux-image-.*";
    "linux-headers-.*";
    "raspi-firmware";
    "rpi-eeprom";
};

// Limpieza tras la actualización.
Unattended-Upgrade::Remove-Unused-Kernel-Packages    "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies   "true";
Unattended-Upgrade::Remove-Unused-Dependencies       "true";

// Notificaciones: por journal, no por email (no hay MTA en el homelab).
Unattended-Upgrade::Mail "";
Unattended-Upgrade::SyslogEnable "true";

// Reinicio automático si el paquete instalado lo requiere
// (kernel aquí no, pero sí systemd, sudo, etc).
Unattended-Upgrade::Automatic-Reboot           "true";
Unattended-Upgrade::Automatic-Reboot-WithUsers "false";
Unattended-Upgrade::Automatic-Reboot-Time      "04:30";
EOF
```

Justificación de los puntos no obvios:

| Bloque | Por qué |
|---|---|
| `Origins-Pattern` con `Debian-Security` y `Raspberry Pi Foundation` | Aplica parches de seguridad de Debian y los específicos de la Pi (firmware userspace, librerías). Excluye `bookworm-updates` y similares, que mezclan cambios funcionales. |
| `Package-Blacklist` con kernels y firmware | Un upgrade automático de kernel + reboot a las 04:30 puede sorprender si un cable USB hace mal contacto y la Pi no remonta `hd2t`. Estos paquetes se actualizan **en mantenimiento manual** (Fase 13: operaciones) confirmando antes que los discos están sanos. |
| `Automatic-Reboot true` + `WithUsers false` | Si hay sesión SSH activa, **no reinicia**; espera. Evita matar una operación en marcha del operador. Si no hay nadie conectado y un paquete pide reboot, la Pi se reinicia a las 04:30. |
| `Automatic-Reboot-Time "04:30"` | Hora local (zona `Europe/Madrid` aplicada en Fase 02). Lejos de cualquier uso humano y de la ventana habitual de Borg (06:00 en Fase 7). |
| `Mail ""` + `SyslogEnable true` | El homelab no tiene MTA y no se quiere instalar uno solo para esto. Las notificaciones van al journal: `journalctl -u unattended-upgrades`. Cuando entre Prometheus/Alertmanager (Fase 5) se podrá enviar alerta si `unattended-upgrades` falla. |

Comprobar la sintaxis del fichero:

```bash
sudo unattended-upgrades --dry-run --debug 2>&1 | tail -n 40
```

Salida esperada: lista de paquetes candidatos (puede ser vacía si todo está al día) y al final `No packages found that can be upgraded unattended` o el set de paquetes que se aplicarán en la próxima ventana.

### Frecuencia de los timers

Los timers que disparan los `apt update` y `unattended-upgrade` los gestiona el paquete `apt`:

```bash
cat /etc/apt/apt.conf.d/20auto-upgrades
# APT::Periodic::Update-Package-Lists "1";
# APT::Periodic::Unattended-Upgrade "1";
```

`1` significa "todos los días". Es lo deseado en un homelab; bajarlo a `0` lo apaga, subirlo no aporta. El intervalo de limpieza de caché se fijó en `02-configuracion-inicial.md` (`AutocleanInterval 7`, `CleanInterval 30`); aquí no se duplica.

### Detectar reboots pendientes desde la línea de comandos

Algunos upgrades (sudo, libc, kernels cuando se aplique manualmente) marcan `/var/run/reboot-required`. Comprobación útil al hacer login:

```bash
test -f /var/run/reboot-required && cat /var/run/reboot-required
```

Más adelante (Fase 5: monitorización) se exportará esta señal a Prometheus para alertar si lleva > X días pendiente.

---

## Verificación Final

Antes de pasar a `04-estructura-directorios.md`:

| Comprobación | Comando | Resultado esperado |
|---|---|---|
| Contraseña renovada | `sudo -K && sudo -v` | Pide la nueva contraseña; `sudo -l` muestra que `homelab` sigue con permisos. |
| `sshd` rechaza contraseñas | `ssh -o PubkeyAuthentication=no homelab` (desde el equipo de trabajo) | `Permission denied (publickey).` |
| `sshd` no permite root | `sudo sshd -T \| grep ^permitrootlogin` | `permitrootlogin no` |
| `sshd` AllowUsers explícito | `sudo sshd -T \| grep ^allowusers` | `allowusers homelab` |
| `ufw` activo y con la regla | `sudo ufw status verbose` | `Status: active`, regla SSH desde la subred LAN. |
| `ufw` arranca solo | `systemctl is-enabled ufw` | `enabled` |
| Backend `nftables` real | `sudo nft list ruleset \| head -n 20` | Tablas `inet filter` con chains `ufw-*` y, tras instalar `fail2ban`, también `f2b-sshd`. |
| `fail2ban` corriendo | `sudo fail2ban-client status` | Lista con `Jail list: sshd`. |
| Jail SSH operativa | `sudo fail2ban-client status sshd` | Filter activo, `Currently banned: 0`. |
| `unattended-upgrades` configurado | `sudo unattended-upgrades --dry-run --debug 2>&1 \| tail -n 5` | Sin errores; resumen de candidatos o "No packages...". |
| Timers de apt | `systemctl list-timers \| grep apt-daily` | `apt-daily.timer` y `apt-daily-upgrade.timer` con `Next:` futuro. |
| Logs limpios | `journalctl -u ssh -u ufw -u fail2ban -u unattended-upgrades --since today --priority=err` | Sin entradas de error. |
| Reboot sin sorpresas | `sudo reboot` y luego de volver: las 6 comprobaciones anteriores siguen verdes | Todo persistente. |

El último punto es crítico: el endurecimiento de SSH + el firewall + el `fail2ban` deben aplicarse **automáticamente en el siguiente arranque** sin tocar nada. Si tras un reboot `ssh homelab` no funciona, el orden de diagnóstico es: ¿la Pi ha booteado? (router DHCP), ¿`sshd` arranca? (consola física → `journalctl -u ssh`), ¿`ufw` está pasando paquetes? (`sudo ufw status`).

---

## Backup

Igual que en los documentos anteriores, en esta fase aún no hay datos de servicios; lo que sí hay es **configuración crítica del host** que define cómo se entra al sistema. Su pérdida no destruye los datos, pero obliga a rehacer este documento entero a mano.

| Ruta | Contenido | Estrategia |
|---|---|---|
| `/etc/ssh/sshd_config.d/10-homelab.conf` | Política de SSH del homelab | Repo del homelab (este árbol `docs/` como referencia) + Borgmatic en Fase 7. |
| `/etc/ssh/ssh_host_*_key*` | Claves del servidor SSH | Borgmatic en Fase 7 con permisos preservados. **No** se versionan en git: son secretos. Si se pierden, se regeneran (`ssh-keygen -A`) y los clientes verán fingerprint nueva — fricción aceptable. |
| `/home/homelab/.ssh/authorized_keys` | Claves públicas de los equipos de trabajo autorizados | Versionadas como referencia (no son secretas) + Borgmatic. |
| `/etc/ufw/`, `/etc/default/ufw` | Reglas y política | Borgmatic. La regla concreta se reproduce con dos `ufw allow ...` desde este documento. |
| `/etc/fail2ban/jail.local` | Política de baneo | Borgmatic + referencia en este doc. |
| `/etc/apt/apt.conf.d/52unattended-upgrades-homelab` | Política de upgrades automáticos | Borgmatic + referencia en este doc. |
| `/etc/apt/apt.conf.d/20auto-upgrades` | Activación de los timers | Idem. |
| `/var/lib/fail2ban/fail2ban.sqlite3` | Estado de baneos en curso | **No se respalda**: estado efímero. Tras un restore, la jail empieza de cero, que es seguro. |
| Contraseña del usuario `homelab` | Hash en `/etc/shadow` | Solo en gestor de contraseñas del operador. Fuera de Borg como precaución, pero `/etc/shadow` entrará en el ámbito Borg (Fase 7) con permisos preservados. |

Cualquier secret material adicional que aparezca al integrar Tailscale (clave de máquina, auth-keys de un solo uso) se trata en su propio documento.

---

## Referencias

- [Documento anterior: `02-configuracion-inicial.md`](./02-configuracion-inicial.md)
- [Documento siguiente: `04-estructura-directorios.md`](./04-estructura-directorios.md)
- [`SERVICES.md`](../../SERVICES.md) — Alcance del homelab (LAN + Tailscale, sin internet).
- [`sshd_config(5)` — manpage Debian](https://manpages.debian.org/bookworm/openssh-server/sshd_config.5.en.html)
- [`ssh_config(5)` — manpage Debian](https://manpages.debian.org/bookworm/openssh-client/ssh_config.5.en.html)
- [Debian Wiki — `Uncomplicated Firewall (ufw)`](https://wiki.debian.org/Uncomplicated%20Firewall%20%28ufw%29)
- [`ufw(8)` — manpage Ubuntu (mismo binario que Debian)](https://manpages.ubuntu.com/manpages/jammy/man8/ufw.8.html)
- [`nftables` — Wiki oficial](https://wiki.nftables.org/wiki-nftables/index.php/Main_Page)
- [`fail2ban` — Documentación oficial](https://github.com/fail2ban/fail2ban/wiki)
- [Debian Handbook — Automatic Security Updates](https://www.debian.org/doc/manuals/securing-debian-manual/automatic-updates.en.html)
- [Debian Wiki — `UnattendedUpgrades`](https://wiki.debian.org/UnattendedUpgrades)
- [Tailscale — CGNAT range `100.64.0.0/10`](https://tailscale.com/kb/1015/100.x-addresses)
