# Seguridad Base del Sistema

## Descripción

Endurecimiento mínimo del **sistema operativo del host** (la Raspberry Pi 5) antes de instalar Docker y los primeros servicios. Cubre el cambio de contraseña inicial, la consolidación de claves SSH, la desactivación del login por password en SSHD, un firewall **`nftables`** con política por defecto restrictiva, un **`fail2ban` básico con un único jail para SSH** y, por último, **actualizaciones automáticas** vía `unattended-upgrades`.

El objetivo es dejar la Pi en un estado en el que la única superficie de ataque expuesta a la LAN sea **SSH con clave pública** (y, transitoriamente, ICMP), de forma que cualquier despliegue posterior añada superficie sólo cuando el servicio lo justifique.

> **Alcance**: se aplica únicamente a **lo que corre en el host**. Reglas de firewall específicas para Docker, Pi-hole en macvlan, Tailscale, Caddy, Authelia o `fail2ban` con jails para servicios concretos viven en los documentos de sus respectivas fases (`docs/03-red/`, `docs/04-seguridad/`).

> **Recordatorio de red**: este homelab está expuesto **solo a la LAN y a Tailscale**. No hay port forwarding en el router ni servicios accesibles desde internet. Las reglas de firewall y los jails de `fail2ban` se diseñan partiendo de esa premisa: protegen frente a un dispositivo doméstico comprometido en la propia LAN, no frente a un atacante externo escaneando IPs públicas.

---

## Requisitos previos

- `docs/01-sistema/02-configuracion-inicial.md` completado: sistema actualizado, hostname, zona horaria, locale y swap fuera de la microSD.
- Acceso SSH al usuario `homelab` desde el equipo de trabajo, autenticado **con clave pública** (configurado en `docs/01-sistema/01-instalacion-os.md` vía Raspberry Pi Imager).
- Equipo de trabajo con la **clave privada** correspondiente protegida por passphrase. Si se ha perdido el control sobre esa clave, **regenerarla y volver a flashear** la microSD es más limpio que intentar parchear el host con una clave comprometida.
- El primer login por SSH ya verificado, de modo que `~/.ssh/authorized_keys` del usuario `homelab` contiene la clave pública correcta.

> **No** desactivar el login por password (sección "Endurecimiento de SSH") **hasta** haber confirmado que se entra por clave pública desde una sesión SSH de prueba en paralelo. La forma habitual de quedarse fuera de un servidor es endurecer SSH, cerrar la única sesión activa y descubrir entonces que la clave no estaba bien instalada.

---

## Cambio de contraseña

La contraseña fijada en Raspberry Pi Imager es **temporal**: se usa únicamente para `sudo` durante la fase de provisionado. Aunque la Pi no es accesible por SSH con password (porque la sección de SSH la deshabilitará en cuanto se confirme la clave), `sudo` sí la utiliza, y conviene reemplazarla por una contraseña larga, única y guardada en el gestor de contraseñas personal.

```bash
# Como usuario 'homelab'
passwd
```

`passwd` pide la contraseña actual y la nueva dos veces. Recomendaciones:

- **Longitud** antes que complejidad: mínimo 16–20 caracteres aleatorios o una passphrase de 5–6 palabras tipo *diceware*. Es la contraseña que protege `sudo` (y, por tanto, todo el host); cualquier compromiso aquí equivale a `root`.
- **Única** para esta máquina. No reutilizar la del usuario del PC, del router ni del NAS.
- **Almacenada** en el gestor de contraseñas personal (Vaultwarden cuando esté operativo en `docs/11-productividad/01-vaultwarden.md`; mientras tanto, KeePassXC u otro gestor offline).

Verificar que la nueva contraseña funciona con `sudo`:

```bash
sudo -k          # invalida cualquier sesión sudo cacheada
sudo true        # debe pedir la nueva contraseña
```

> **No** se crea un usuario `root` con contraseña ni se habilita `su`. La Raspberry Pi OS deja a `root` sin contraseña y con login deshabilitado por defecto, y conviene mantenerlo así: todo el acceso administrativo va por `sudo`, lo que deja rastro en `journalctl _COMM=sudo`.

---

## Consolidación de claves SSH

La clave pública configurada en Imager debería estar ya en `/home/homelab/.ssh/authorized_keys`. Esta sección verifica el estado, deja los permisos correctos y prepara el terreno para añadir más claves (ej. equipo secundario, móvil con cliente SSH) sin tener que regenerar nada más adelante.

### 1. Verificar el estado actual

```bash
ls -la ~/.ssh
cat ~/.ssh/authorized_keys
```

Estado esperado:

```
drwx------ 2 homelab homelab .
-rw------- 1 homelab homelab authorized_keys
```

- `~/.ssh` con permisos `0700` y propietario `homelab:homelab`.
- `authorized_keys` con permisos `0600`.

Cualquier permiso más laxo provoca que `sshd` ignore el fichero por seguridad y rechace el login con clave (revisar logs en `journalctl -u ssh -n 50 -e` con mensajes tipo `Authentication refused: bad ownership or modes`).

Si los permisos no son los correctos, restaurarlos:

```bash
chmod 700 ~/.ssh
chmod 600 ~/.ssh/authorized_keys
chown -R homelab:homelab ~/.ssh
```

### 2. Añadir claves adicionales (opcional)

Para autorizar otro equipo o un cliente móvil, **añadir** la clave pública (no sobrescribir):

```bash
# Desde el equipo de trabajo, copiar al portapapeles el contenido de la nueva clave pública
cat ~/.ssh/id_ed25519_movil.pub | pbcopy   # macOS
# o   xclip -selection clipboard            (Linux)

# En la Pi, anexar al final
echo 'ssh-ed25519 AAAA... usuario@dispositivo' >> ~/.ssh/authorized_keys
```

Una clave por línea. Conviene **comentar cada clave** con un identificador (`usuario@dispositivo`, fecha de alta) para poder revocarla luego sin dudas:

```
# 2025-04 portátil principal
ssh-ed25519 AAAA... homelab-pc
# 2025-04 móvil (Termius)
ssh-ed25519 AAAA... homelab-movil
```

### 3. Algoritmos aceptados

Sólo se aceptan claves **ED25519** (rápidas, cortas y consideradas seguras a 2025+). Las claves **RSA legacy** (`ssh-rsa` con SHA-1) están deprecadas en OpenSSH 8.x y se rechazan por defecto en Bookworm. Si una herramienta antigua sólo soporta RSA, **regenerar** una nueva clave RSA de **4096 bits con SHA-256** (`-t rsa -b 4096`) en lugar de relajar los algoritmos del servidor.

### 4. Probar el login antes de continuar

Desde el equipo de trabajo, **abrir una segunda sesión SSH** sin cerrar la primera:

```bash
ssh -v homelab@<IP_de_la_Pi>
```

Confirmar en el log que se autentica con `Authenticated to ... using "publickey"` y **no** con `Authenticated to ... using "password"`. Mantener esa segunda sesión abierta como red de seguridad mientras se aplican los cambios de la siguiente sección.

---

## Endurecimiento de `sshd`

La configuración por defecto de SSH en Raspberry Pi OS Bookworm acepta password authentication para que la primera conexión funcione incluso si Imager no inyectó claves. En cuanto se ha confirmado que la clave pública funciona, conviene **deshabilitar password** y otros vectores poco útiles.

### 1. Crear un drop-in en `/etc/ssh/sshd_config.d/`

Bookworm ya separa la configuración en `/etc/ssh/sshd_config` con un `Include /etc/ssh/sshd_config.d/*.conf`. **No** se edita `sshd_config` directamente: cualquier upgrade del paquete `openssh-server` puede sobreescribirlo o pedir merge interactivo. En su lugar, se crea un fichero propio que tiene precedencia sobre la primera ocurrencia (el primer `Include` se carga antes que las directivas globales del fichero principal).

```bash
sudo tee /etc/ssh/sshd_config.d/10-homelab.conf > /dev/null <<'EOF'
# Hardening base del SSHD del homelab.
# Sólo se entra con clave pública desde LAN o Tailscale.

# --- Autenticación ---
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
PubkeyAuthentication yes
PermitEmptyPasswords no

# Sólo el usuario administrador puede entrar por SSH
AllowUsers homelab

# --- Sesión ---
LoginGraceTime 30
MaxAuthTries 3
MaxSessions 5

# Cierre proactivo de sesiones inactivas o muertas (útil cuando se cae la red
# Wi-Fi del cliente y queda una sesión zombi consumiendo un slot)
ClientAliveInterval 300
ClientAliveCountMax 2

# --- Funcionalidad innecesaria ---
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
PermitTunnel no
GatewayPorts no
PrintMotd no
EOF
```

Notas sobre las decisiones:

- `AllowTcpForwarding no` — No se usa SSH como túnel para servicios. Para acceso remoto a servicios desde fuera de la LAN ya está Tailscale (`docs/03-red/05-tailscale.md`), que es más seguro y cómodo. Dejar el forwarding abierto añade riesgo si un día se compromete una clave.
- `MaxAuthTries 3` — Tres intentos por conexión. Combinado con `fail2ban` más abajo, deja una ventana muy estrecha para un ataque por fuerza bruta incluso desde la LAN.
- `AllowUsers homelab` — Lista blanca explícita. Si en el futuro se crea un usuario adicional (`backups`, `monitor`, etc.) y se quiere darle acceso SSH, hay que añadirlo aquí explícitamente; mientras tanto, el alta accidental de un usuario no le concede SSH.

### 2. Validar la sintaxis antes de recargar

```bash
sudo sshd -t
```

Si no imprime nada, la configuración es válida. Cualquier salida indica un error de sintaxis y **no** se debe recargar el demonio: dejaría sshd parado y, sin la sesión actual, no habría forma de entrar.

### 3. Recargar `sshd`

```bash
sudo systemctl reload ssh
```

> **Importante**: usar `reload` (no `restart`). `reload` aplica los cambios **sin** matar la sesión actual; `restart` cortaría la sesión SSH viva. Si la conexión actual sobrevive y la segunda sesión de prueba sigue funcionando, todo está bien.

### 4. Probar desde el equipo de trabajo

Desde **otra terminal**, intentar:

```bash
# Debe FUNCIONAR (clave pública)
ssh homelab@<IP>

# Debe FALLAR con "Permission denied (publickey)"
ssh -o PubkeyAuthentication=no -o PreferredAuthentications=password homelab@<IP>

# Debe FALLAR de inmediato
ssh root@<IP>
```

Sólo cuando los tres comportamientos coinciden con lo esperado se puede cerrar la primera sesión.

> Si `sshd` quedara tumbado por error y **no se puede entrar**, la única vía sin desplazarse a la Pi es reescribir `/etc/ssh/sshd_config.d/10-homelab.conf` desde la microSD montada en otro equipo (o restaurar a través de la WiFi de emergencia configurada en `docs/01-sistema/01-instalacion-os.md`).

---

## Firewall con `nftables`

Debian Bookworm usa **`nftables`** como backend por defecto de `iptables`. Se trabaja directamente con `nftables` (más limpio, una única tabla, ruleset declarativo) en lugar de instalar `ufw`, que añade una capa de abstracción y un servicio extra para muy poca ganancia en este entorno.

Política base:

| Cadena      | Política | Excepciones                                                  |
|-------------|----------|--------------------------------------------------------------|
| `input`     | `drop`   | `lo`, conexiones establecidas, ICMP rate-limited, SSH (22)   |
| `forward`   | `drop`   | Lo gestionará Docker más adelante                            |
| `output`    | `accept` | El host puede salir libremente                               |

> **No** se añaden reglas para los servicios (Pi-hole, Caddy, Jellyfin...). Cuando Docker arranque empezará a inyectar sus propias reglas (cadena `DOCKER-USER` y `nat`), y la documentación de cada servicio gestionará sus puertos. La excepción es Pi-hole en macvlan: hablará de un `macvlan-shim` y de exposición DNS sólo a la LAN en `docs/03-red/02-pihole.md`.

### 1. Instalar y habilitar `nftables`

```bash
sudo apt install -y nftables
sudo systemctl enable --now nftables
```

Verificar que el servicio está activo y carga `/etc/nftables.conf`:

```bash
systemctl status nftables --no-pager
sudo nft list ruleset
```

Por defecto el ruleset estará prácticamente vacío (`flush ruleset`).

### 2. Definir el ruleset base

Sustituir el contenido de `/etc/nftables.conf` por el siguiente. Antes, un backup por si hubiera que rehacer el camino:

```bash
sudo cp -a /etc/nftables.conf /etc/nftables.conf.bak
```

```bash
sudo tee /etc/nftables.conf > /dev/null <<'EOF'
#!/usr/sbin/nft -f
# Ruleset base del homelab — host Raspberry Pi 5.
# - Política por defecto: drop en input/forward, accept en output.
# - Sólo se permite SSH desde la LAN/Tailscale.
# - Docker añadirá sus propias reglas en otras tablas/cadenas (no se tocan).

flush ruleset

table inet filter {
    chain input {
        type filter hook input priority filter; policy drop;

        # Tráfico ya conocido / relacionado
        ct state established,related accept
        ct state invalid drop

        # Loopback siempre abierto (servicios locales del host)
        iif "lo" accept

        # ICMP/ICMPv6 — imprescindible para Path MTU Discovery, ping y NDP.
        # Limitado para evitar floods desde un dispositivo de la LAN comprometido.
        ip protocol icmp limit rate 10/second accept
        ip6 nexthdr icmpv6 limit rate 10/second accept

        # SSH — entrada controlada (fail2ban se encarga del rate-limit por IP)
        tcp dport 22 accept

        # Todo lo demás: drop silencioso (ni rechazar ni notificar al cliente)
    }

    chain forward {
        type filter hook forward priority filter; policy drop;
        # Docker gestionará su propio reenvío en sus tablas.
    }

    chain output {
        type filter hook output priority filter; policy accept;
    }
}
EOF
```

### 3. Validar y aplicar

```bash
# Validación sintáctica sin tocar el ruleset vivo
sudo nft -c -f /etc/nftables.conf

# Aplicación efectiva
sudo systemctl reload nftables

# Mostrar el ruleset cargado
sudo nft list ruleset
```

`-c` (check) compila las reglas sin instalarlas. Si imprime errores, **no** seguir: una recarga con un fichero erróneo deja el firewall en estado indeterminado.

### 4. Persistencia tras reinicio

El servicio `nftables.service` carga automáticamente `/etc/nftables.conf` en cada arranque, por lo que con `systemctl enable --now nftables` ya queda persistente. Confirmar:

```bash
systemctl is-enabled nftables    # debe responder 'enabled'
```

### 5. Convivencia con Docker

Docker, cuando se instale en `docs/02-docker/01-instalacion-docker.md`, creará sus propias tablas (`nat`, `filter` con cadenas `DOCKER`, `DOCKER-USER`, `DOCKER-ISOLATION-STAGE-1/2`). Estas cadenas viven en paralelo a la tabla `inet filter` de este documento y **no** se ven afectadas por el `flush ruleset` inicial **siempre que Docker arranque después** de que `nftables.service` haya cargado el fichero.

Cualquier regla extra orientada a contenedores (limitar exposición de puertos a la LAN, bloquear tráfico saliente desde un contenedor concreto, etc.) se añadirá en la cadena `DOCKER-USER` desde los documentos de la fase de Docker.

> Si más adelante se añaden reglas extra al host fuera de Docker (por ejemplo Wireguard nativo en lugar de Tailscale), se editarán **siempre** en `/etc/nftables.conf` y se recargará el servicio. Nunca con `nft add rule` directo, que se pierden al reiniciar.

---

## `fail2ban` (jail SSH)

`fail2ban` lee `journald` (o ficheros de log), detecta intentos de autenticación fallidos por una IP y, transcurrido un umbral, la banea durante un tiempo añadiendo una regla al firewall. En este documento se configura **un único jail para SSH** a nivel de host. Los jails para servicios (Nextcloud, Vaultwarden, Authelia...) se tratan en `docs/04-seguridad/02-fail2ban.md`.

> En una LAN doméstica + Tailscale los intentos de fuerza bruta son raros, pero **no nulos**: un dispositivo IoT comprometido en la red, un invitado con un portátil contaminado o un script lanzado desde Tailscale por un peer mal configurado pueden empezar a probar combinaciones. `fail2ban` cierra esa ventana en cuanto detecta el patrón.

### 1. Instalación

```bash
sudo apt install -y fail2ban
```

El paquete deja `fail2ban.service` activo, sin jails configurados (sólo el ejemplo `sshd` deshabilitado).

### 2. Configuración local

Toda la configuración propia va en `/etc/fail2ban/jail.local` (que tiene precedencia sobre `/etc/fail2ban/jail.conf`, gestionado por el paquete y reescrito en cada actualización).

```bash
sudo tee /etc/fail2ban/jail.local > /dev/null <<'EOF'
[DEFAULT]
# Tiempo durante el cual una IP queda baneada (en segundos)
bantime  = 1h

# Ventana de tiempo en la que se cuentan los intentos fallidos
findtime = 10m

# Número de fallos en 'findtime' que activan el ban
maxretry = 5

# Backend para leer logs: en Bookworm los logs de SSHD viven en journald
backend  = systemd

# IPs ignoradas: localhost, LAN doméstica y la red de Tailscale.
# Ajustar la subred LAN a la real (192.168.X.0/24, 10.0.X.0/24, etc.).
ignoreip = 127.0.0.1/8 ::1 192.168.1.0/24 100.64.0.0/10

# Acción de baneo: usar nftables para encajar con el firewall del host
banaction = nftables-multiport
banaction_allports = nftables-allports

[sshd]
enabled  = true
port     = ssh
mode     = aggressive
EOF
```

Notas:

- **`backend = systemd`** — En Bookworm el log de `sshd` ya no se escribe en `/var/log/auth.log` sino en el journal. `fail2ban` se conecta a `systemd-journal` directamente, sin depender de que un `rsyslog` opcional esté escribiendo a fichero.
- **`banaction = nftables-multiport`** — Coherente con el firewall configurado arriba. `fail2ban` añade y elimina reglas en su propia tabla (`inet f2b-*`), independiente de `/etc/nftables.conf`.
- **`ignoreip`** — Aquí se listan los rangos en los que `fail2ban` **no** banea aunque haya fallos:
  - `127.0.0.1/8 ::1` — el propio host.
  - `192.168.1.0/24` — la LAN doméstica (ajustar al rango real del router; se confirma con `ip -br addr show eth0`).
  - `100.64.0.0/10` — el rango CGNAT que Tailscale usa para todos los nodos de un tailnet. Cualquier dispositivo propio entrando vía Tailscale entra en este rango.
  - **No** ignorar la IP del propio cliente "principal": si se compromete, no hay defensa. Confiar en la clave SSH es suficiente.
- **`mode = aggressive`** — Detecta también escaneos previos al login (sondas de versión, *handshake* fallido), no sólo passwords incorrectas. Útil aunque las passwords estén deshabilitadas porque corta antes los scripts automáticos.

### 3. Activar y verificar

```bash
sudo systemctl enable --now fail2ban
sudo systemctl status fail2ban --no-pager
sudo fail2ban-client status
sudo fail2ban-client status sshd
```

Salida esperada de `fail2ban-client status sshd` recién arrancado:

```
Status for the jail: sshd
|- Filter
|  |- Currently failed: 0
|  |- Total failed:     0
|  `- Journal matches:  _SYSTEMD_UNIT=sshd.service + _COMM=sshd
`- Actions
   |- Currently banned: 0
   |- Total banned:     0
   `- Banned IP list:
```

### 4. Probar el banner (opcional)

Desde una IP **no incluida en `ignoreip`** (por ejemplo, otra red móvil), provocar 5 intentos fallidos:

```bash
for i in $(seq 1 6); do
  ssh -o PubkeyAuthentication=no -o PreferredAuthentications=password \
      malo@<IP_de_la_Pi> 2>/dev/null
done
```

A partir del sexto intento la conexión cierra de inmediato (TCP RST o timeout). En la Pi:

```bash
sudo fail2ban-client status sshd
```

Debe listar la IP atacante en `Banned IP list`. El ban dura `bantime` (1 h por defecto). Para desbanear manualmente:

```bash
sudo fail2ban-client set sshd unbanip <IP>
```

### 5. Persistencia entre reinicios

`fail2ban` recrea sus reglas en `nftables` al arrancar y vuelve a leer el journal desde el último punto, por lo que no se pierde el estado tras un reboot. La lista de IPs baneadas **sí** se reinicia, lo cual es razonable: un atacante que vuelva a probar tras el reboot será baneado otra vez en cuanto cumpla el umbral.

---

## Actualizaciones automáticas (`unattended-upgrades`)

Para que la Pi reciba **parches de seguridad** sin depender de que alguien recuerde correr `apt full-upgrade`. La configuración por defecto en Debian aplica únicamente actualizaciones de la rama `Debian-Security`, no del resto, lo que es justo lo deseable para un homelab: parchear vulnerabilidades sin meter cambios funcionales que puedan romper algún contenedor.

### 1. Instalar paquetes

```bash
sudo apt install -y unattended-upgrades apt-listchanges
```

- `unattended-upgrades` — el demonio que aplica las actualizaciones de seguridad.
- `apt-listchanges` — muestra changelogs de paquetes que cambian, útil al revisar los logs después.

### 2. Habilitar la actualización periódica

```bash
sudo dpkg-reconfigure -plow unattended-upgrades
```

En el diálogo, contestar **"Yes"** a *"Automatically download and install stable updates?"*. Esto crea `/etc/apt/apt.conf.d/20auto-upgrades` con:

```
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
```

Es decir: una vez al día se ejecuta `apt update` y se aplican las actualizaciones que `unattended-upgrades` considere elegibles.

### 3. Ajustar el conjunto de orígenes y el reinicio

Editar `/etc/apt/apt.conf.d/50unattended-upgrades`. Las opciones relevantes:

```bash
sudoedit /etc/apt/apt.conf.d/50unattended-upgrades
```

Asegurarse de que el bloque `Allowed-Origins` tiene activos al menos:

```
Unattended-Upgrade::Origins-Pattern {
    "origin=Debian,codename=${distro_codename},label=Debian";
    "origin=Debian,codename=${distro_codename},label=Debian-Security";
    "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
    "origin=Raspbian,codename=${distro_codename},label=Raspbian";
    "origin=Raspberry Pi Foundation,codename=${distro_codename},label=Raspberry Pi Foundation";
};
```

- Las dos últimas líneas son específicas de Raspberry Pi OS (repos `archive.raspberrypi.com` y derivados).
- **No** se añaden orígenes externos (Docker, Tailscale...). Esos repos sí se actualizarán manualmente desde sus respectivas docs cuando se quiera saltar versión.

Activar el reinicio automático **sólo** si la actualización lo requiere (por ejemplo, un kernel nuevo) y **fuera** de las horas de uso del homelab:

```
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-WithUsers "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:30";
```

> En un homelab "siempre encendido" el reinicio nocturno es preferible a posponerlo: aplicar parches de kernel y dejarlos sin reiniciar deja la Pi en un estado en el que `uname -r` no coincide con el binario instalado, y bibliotecas críticas (libc, openssl) cargadas en memoria pueden seguir vulnerables hasta el siguiente reboot. 04:30 es un momento sin uso típico (multimedia, backups planificados antes y/o después).

Activar también el correo o notificación local de errores (opcional, hasta que se monten notificaciones reales en `docs/05-monitorizacion/05-uptime-kuma.md`):

```
Unattended-Upgrade::Mail "root";
Unattended-Upgrade::MailReport "on-change";
```

Sin un MTA configurado el correo se queda en el spool local (`/var/mail/root`), pero al menos se puede revisar manualmente con `mail` (paquete `bsd-mailx` si se quiere leerlo formateado).

### 4. Probar en seco

```bash
# Ejecuta el ciclo completo en modo dry-run, mostrando lo que haría
sudo unattended-upgrade --dry-run -d 2>&1 | tail -30
```

Verifica que reconoce los orígenes correctos (`Allowed origins are: ...`) y no se queja de configuraciones incoherentes.

### 5. Verificar el log tras una ejecución real

Los timers de systemd `apt-daily.timer` y `apt-daily-upgrade.timer` disparan las ejecuciones reales:

```bash
systemctl list-timers apt-daily*
```

Tras la primera ejecución (puede tardar hasta 24 h en condiciones normales), revisar:

```bash
ls /var/log/unattended-upgrades/
sudo cat /var/log/unattended-upgrades/unattended-upgrades.log
```

---

## Verificación final

Antes de pasar a `docs/01-sistema/04-estructura-directorios.md`:

- [ ] La nueva contraseña del usuario `homelab` está guardada en el gestor de contraseñas y `sudo true` la pide correctamente tras `sudo -k`.
- [ ] `~/.ssh/authorized_keys` contiene **todas** las claves autorizadas, una por línea, con comentario identificador, y permisos `0600`.
- [ ] Login SSH **funciona** con clave pública desde el equipo de trabajo.
- [ ] Login SSH **falla** con password (`PreferredAuthentications=password` da `Permission denied`) y como `root`.
- [ ] `sudo sshd -t` no devuelve errores y `sudo systemctl status ssh` está `active (running)`.
- [ ] `sudo nft list ruleset` muestra la tabla `inet filter` con `policy drop` en `input`/`forward` y la regla de SSH presente.
- [ ] `systemctl is-enabled nftables` devuelve `enabled` y un reinicio (`sudo reboot`) deja el ruleset cargado.
- [ ] `sudo fail2ban-client status sshd` muestra el jail `sshd` activo, con `Currently failed: 0`.
- [ ] `systemctl list-timers apt-daily*` lista los timers programados y `unattended-upgrade --dry-run -d` no reporta errores.

---

## Troubleshooting

### "Permission denied (publickey)" tras recargar `sshd`

Probable error en el drop-in `/etc/ssh/sshd_config.d/10-homelab.conf`. Pasos de diagnóstico, **sin cerrar la sesión actual**:

```bash
sudo sshd -T | grep -E '^(passwordauthentication|pubkeyauthentication|allowusers|permitrootlogin)'
sudo journalctl -u ssh -n 100 --no-pager
```

`sshd -T` imprime la configuración efectiva tras todos los includes. Errores típicos:

- `AllowUsers homelab` puesto, pero el cliente intenta entrar como otro usuario → revisar `ssh -v` del cliente.
- `authorized_keys` con permisos demasiado abiertos → `chmod 600 ~/.ssh/authorized_keys`.
- Clave pública mal pegada (saltos de línea o `==` partido) → comparar con `cat ~/.ssh/authorized_keys` y reescribirla.

### `nft -c -f /etc/nftables.conf` falla con "Operation not supported"

Suele indicar que el paquete `nftables` no está instalado o que `nft` no encuentra el módulo del kernel:

```bash
sudo apt install --reinstall nftables
sudo modprobe nf_tables
```

Si persiste, comprobar `uname -r` y que el kernel actual tenga soporte de `nf_tables` (todos los kernels de Raspberry Pi OS Bookworm lo tienen; el síntoma sólo aparece en kernels custom).

### Tras el firewall pierdo conectividad con un servicio local

El firewall sólo afecta a `input`. Servicios locales (loopback) no pasan por `input` desde fuera y siguen funcionando. Si lo que falla es:

- **Acceder desde la Pi** a un servicio externo (DNS, repos APT) → la cadena `output` sigue en `accept`. El problema está en otro sitio (DNS, Docker más adelante, etc.).
- **Acceder desde otro host de la LAN** a un servicio que aún no se ha desplegado → es lo correcto, no hay todavía servicio que escuchar (Docker no instalado).
- **Acceder desde otro host a SSH** → confirmar que la regla `tcp dport 22 accept` está en el ruleset (`sudo nft list chain inet filter input`) y que `fail2ban` no haya baneado la IP por error (`sudo fail2ban-client status sshd`).

### `fail2ban` se queja de "Failed to access socket path"

```bash
sudo systemctl status fail2ban --no-pager
sudo journalctl -u fail2ban -n 50 --no-pager
```

Causas habituales:

- `backend = systemd` configurado pero el paquete `python3-systemd` no está instalado. Solución: `sudo apt install -y python3-systemd && sudo systemctl restart fail2ban`.
- Conflicto con `iptables-legacy` heredado. Confirmar que el sistema usa `iptables-nft` (default en Bookworm): `sudo update-alternatives --display iptables` debe apuntar a `iptables-nft`.

### `fail2ban-client status sshd` muestra `Banned IP list:` con mi propia IP

Auto-baneo durante una sesión de pruebas o por un script SSH defectuoso. Desbanear y añadir la IP a `ignoreip` si corresponde:

```bash
sudo fail2ban-client set sshd unbanip <IP>
sudoedit /etc/fail2ban/jail.local   # ampliar 'ignoreip' si toca
sudo systemctl reload fail2ban
```

### `unattended-upgrades` no aplica nada nunca

Los timers se ejecutan con condiciones (no batería baja, no AC desconectada en portátiles, etc.) que en una Raspberry Pi 5 alimentada por la fuente oficial no suelen activarse. Verificación:

```bash
systemctl list-timers apt-daily* --all
sudo systemctl start apt-daily.service
sudo systemctl start apt-daily-upgrade.service
sudo cat /var/log/unattended-upgrades/unattended-upgrades.log
```

Si tras forzar manualmente sigue sin actualizar nada, comprobar que `Allowed-Origins` incluye `Debian-Security` y que `apt update` no tiene errores (`sudo apt update`).

### Tras un `apt full-upgrade` el `sshd_config.d/10-homelab.conf` ha desaparecido

No debería ocurrir (es un fichero local), pero si pasa por culpa de un `purge` accidental: el contenido está versionado en este documento y se puede recrear copiando el bloque de la sección "Endurecimiento de `sshd`". Conviene **versionar** todos los ficheros de configuración propios (`/etc/ssh/sshd_config.d/`, `/etc/nftables.conf`, `/etc/fail2ban/jail.local`, `/etc/apt/apt.conf.d/50unattended-upgrades`) en un repositorio git privado en cuanto se monte Nextcloud o Forgejo en fases posteriores.

---

## Referencias

- OpenSSH — Configuración del servidor: <https://man.openbsd.org/sshd_config>
- Debian Wiki — Hardening de OpenSSH: <https://wiki.debian.org/SSH>
- `nftables` — Wiki oficial: <https://wiki.nftables.org/wiki-nftables/index.php/Main_Page>
- Debian Wiki — `nftables`: <https://wiki.debian.org/nftables>
- `fail2ban` — Documentación oficial: <https://github.com/fail2ban/fail2ban/wiki>
- `fail2ban` con backend `systemd`: <https://github.com/fail2ban/fail2ban/blob/master/MANUAL>
- Debian Wiki — `unattended-upgrades`: <https://wiki.debian.org/UnattendedUpgrades>
- Tailscale — Rangos CGNAT (`100.64.0.0/10`): <https://tailscale.com/kb/1015/100.x-addresses>
