# Seguridad Base del Sistema

## Descripción

**Endurecimiento de seguridad** mínimo de la Raspberry Pi 5 una vez que el SO está actualizado, localizado y con la swap configurada según [`02-configuracion-inicial.md`](./02-configuracion-inicial.md). Este documento deja la Pi en un estado defendible **a nivel de host**, antes de empezar a desplegar Docker y los servicios.

Este documento cubre, en este orden:

1. **Cambio de contraseña** del usuario `homelab` y verificación del estado de cuentas (`pi`, `root`).
2. **Claves SSH**: revisión de `authorized_keys`, permisos correctos, opción de añadir claves adicionales.
3. **Endurecimiento del demonio SSH** (`sshd`): deshabilitar login por password, deshabilitar root, opcionalmente restringir el listen a la LAN.
4. **Firewall** con `ufw`: política por defecto, regla para SSH desde la LAN, reservar el resto del tráfico para más adelante.
5. **`fail2ban` básico**: solo el **jail de SSH** a nivel de host. Los jails para servicios (Authelia, Nextcloud, Vaultwarden) se añaden en [`../04-seguridad/02-fail2ban.md`](../04-seguridad/02-fail2ban.md).
6. **Actualizaciones automáticas** vía `unattended-upgrades` (parches de seguridad de Debian Bookworm).

> **Alcance**: este documento se queda en seguridad **del host**. La autenticación de aplicaciones (SSO/2FA con Authelia), el reverse proxy con HTTPS (Caddy), la VPN mesh (Tailscale) y los jails específicos por servicio se documentan en sus respectivas fases. La **estructura de directorios** sobre los discos externos se hace en [`04-estructura-directorios.md`](./04-estructura-directorios.md), después de este documento.

> **Recordatorio**: el homelab opera en **LAN + Tailscale**. No hay puertos abiertos en el router hacia internet, así que el modelo de amenaza relevante aquí es: dispositivos comprometidos dentro de la LAN, errores operativos del propio operador y, más adelante, peers de Tailscale. La superficie de ataque desde internet es **cero** mientras no se exponga ningún puerto.

---

## Requisitos Previos

- Raspberry Pi 5 con **Raspberry Pi OS Lite 64-bit** instalado según [`01-instalacion-os.md`](./01-instalacion-os.md), accesible por `ssh homelab` con autenticación por clave pública.
- Sistema actualizado y con swap configurada en `hd2t` según [`02-configuracion-inicial.md`](./02-configuracion-inicial.md).
- Conexión a internet vía Ethernet (necesaria para `apt install` de `ufw`, `fail2ban` y `unattended-upgrades`).
- Acceso al **PC de administración** desde el que se autoriza la clave SSH (necesario por si hay que recuperar acceso si se rompe SSH durante el endurecimiento).
- Una **segunda sesión SSH abierta y dejada en reposo** mientras se tocan `sshd_config` y `ufw`. Es la red de seguridad clásica: si la nueva configuración deja fuera la sesión actual, la segunda sigue conectada y permite revertir.

### Decisiones de diseño asumidas

| Decisión | Valor por defecto | Justificación |
|---|---|---|
| Login por password vía SSH | **Deshabilitado** (`PasswordAuthentication no`) | El acceso normal es por clave pública desde el primer arranque ([`01-instalacion-os.md`](./01-instalacion-os.md)). Mantener `PasswordAuthentication yes` es la principal vía de fuerza bruta en un homelab. |
| Login `root` vía SSH | **Deshabilitado** (`PermitRootLogin no`) | El usuario `homelab` con `sudo` cubre todas las necesidades. `root` directo no aporta nada y es objetivo conocido. |
| Listen address de SSH | `0.0.0.0` (todas las interfaces) | La Pi está sólo en la LAN; restringir el listen aporta poco frente al firewall, complica Tailscale más adelante y rompe `mdns` por interfaces dinámicas. **El control real se hace con `ufw`**. |
| Firewall | **`ufw`** con política `deny` entrante / `allow` saliente | `ufw` es la frontend recomendada en Debian/Ubuntu para `nftables`/`iptables`, suficientemente expresiva y mucho más legible que `nft` directo. |
| Reglas iniciales del firewall | Solo **SSH (22/tcp) desde la subred LAN** | Es lo único que se usa al final de la Fase 1. El resto de servicios añadirán sus propias reglas en sus fases (DNS desde la macvlan, HTTP/HTTPS de Caddy, Tailscale, etc.). |
| `fail2ban` | **Solo jail SSH** | A nivel de host es lo único expuesto en este punto. Los jails de Authelia/Nextcloud/Vaultwarden necesitan los logs de los contenedores y se hacen en [`../04-seguridad/02-fail2ban.md`](../04-seguridad/02-fail2ban.md). |
| Banaction de `fail2ban` | `nftables-allports` (o `ufw` si se prefiere integrar) | La cadena `nftables` es la nativa en Bookworm. Banear *allports* aísla por completo a la IP atacante mientras dura el bantime. |
| Actualizaciones automáticas | **`unattended-upgrades`** con `security` habilitado, `auto-reboot` a las 04:00 si hace falta | La Pi va a estar siempre encendida y desatendida; aplicar parches de seguridad en automático es no negociable. El reboot nocturno reduce riesgo de inconsistencias por paquetes que requieren reinicio. |

---

## 1. Cambio de contraseña y revisión de cuentas

Aunque el acceso normal es por clave SSH, el usuario `homelab` sigue teniendo password (lo pidió Imager en [`01-instalacion-os.md`](./01-instalacion-os.md)). Ese password se usa como recovery local y para `sudo`, así que conviene asegurarse de que es robusto.

### 1.1. Cambiar la contraseña del usuario `homelab`

Desde la sesión SSH:

```bash
passwd
```

Introducir la contraseña actual y luego dos veces la nueva. Recomendaciones:

- Mínimo **20 caracteres**, idealmente generada por un gestor de contraseñas (Bitwarden/Vaultwarden cuando esté disponible más adelante, o `KeePassXC` mientras tanto).
- No reutilizar contraseñas de otras cuentas.
- Guardarla en el gestor antes de cerrar el shell — sin esta contraseña no se puede hacer `sudo` ni acceder por consola física.

### 1.2. Verificar el estado del usuario `pi`

En Bookworm, el usuario `pi` ya **no existe** por defecto si Imager se ha usado correctamente con un usuario propio. Confirmarlo:

```bash
id pi 2>&1 || echo "Usuario 'pi' no existe (correcto)."
```

Si por cualquier motivo existe, deshabilitar su login:

```bash
sudo passwd -l pi              # bloquea el password
sudo usermod -s /usr/sbin/nologin pi
```

### 1.3. Verificar que `root` no tiene login interactivo

```bash
sudo passwd -S root
```

Salida esperada:

```
root L ...
```

La `L` indica que la cuenta `root` está **bloqueada** (sin password válido, no se puede hacer `su -` ni login local). Es el estado normal en Raspberry Pi OS / Debian; toda elevación se hace por `sudo` con la contraseña de `homelab`.

Si por accidente apareciera con `P` (password set), bloquearla:

```bash
sudo passwd -l root
```

---

## 2. Claves SSH y `authorized_keys`

La clave pública del PC de administración ya quedó instalada por Imager. Conviene revisar permisos y dejar el directorio en estado conocido por si más adelante se añaden más claves (otro PC, una clave de backup en papel, etc.).

### 2.1. Estado actual

```bash
ls -ld ~/.ssh
ls -l ~/.ssh
cat ~/.ssh/authorized_keys
```

Salida esperada:

```
drwx------ 2 homelab homelab ... .ssh
-rw------- 1 homelab homelab ... authorized_keys
ssh-ed25519 AAAAC3Nza... homelab-admin@miequipo
```

### 2.2. Forzar permisos correctos

Aunque ya estén bien, dejarlo idempotente:

```bash
chmod 700 ~/.ssh
chmod 600 ~/.ssh/authorized_keys
chown -R homelab:homelab ~/.ssh
```

Permisos demasiado abiertos en `~/.ssh` son una de las causas típicas de `Permission denied (publickey)` aunque la clave esté correcta.

### 2.3. (Opcional) Añadir una segunda clave de respaldo

Es buena práctica autorizar una **segunda clave** en otro dispositivo (portátil, llave hardware tipo YubiKey, o una clave guardada cifrada en un USB). Si el dispositivo principal falla, sigue habiendo acceso a la Pi sin tener que conectar monitor y teclado.

Desde el dispositivo secundario:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/homelab_backup -C "homelab-backup"
cat ~/.ssh/homelab_backup.pub
```

Pegar la línea resultante (una sola línea, completa) al final de `~/.ssh/authorized_keys` en la Pi:

```bash
nano ~/.ssh/authorized_keys
# añadir la nueva línea, guardar
```

Verificar desde el dispositivo secundario que conecta:

```bash
ssh -i ~/.ssh/homelab_backup homelab@<ip-de-la-pi>
```

Solo bloquear el password en SSH (paso siguiente) cuando **al menos una de las claves autorizadas haya entrado correctamente**.

---

## 3. Endurecimiento del demonio SSH (`sshd`)

> **Importante**: dejar **dos sesiones SSH abiertas** durante todo este apartado. Si la primera se cae al reiniciar `sshd`, la segunda permite revertir cambios sin tener que conectar monitor y teclado.

### 3.1. Backup del fichero de configuración

```bash
sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%Y%m%d-%H%M%S)
```

### 3.2. Aplicar el endurecimiento como drop-in

En lugar de tocar `/etc/ssh/sshd_config`, dejar las decisiones del homelab en un fichero aparte dentro de `/etc/ssh/sshd_config.d/`. Bookworm carga estos drop-ins por defecto (la línea `Include /etc/ssh/sshd_config.d/*.conf` está al principio de `sshd_config`).

```bash
sudo tee /etc/ssh/sshd_config.d/10-homelab.conf > /dev/null <<'EOF'
# Homelab — endurecimiento de SSH a nivel de host.
# Documentado en docs/01-sistema/03-seguridad-base.md.

# Solo autenticación por clave pública.
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
UsePAM yes

# Sin login directo de root.
PermitRootLogin no

# Sin reenvíos innecesarios; se pueden re-habilitar puntualmente con -L/-R si hace falta.
AllowAgentForwarding no
AllowTcpForwarding no
X11Forwarding no

# Banner y limites razonables.
LoginGraceTime 30
MaxAuthTries 3
MaxSessions 5

# Solo el usuario homelab puede entrar por SSH.
AllowUsers homelab
EOF
```

### 3.3. Validar la configuración antes de aplicarla

`sshd -t` analiza la configuración y devuelve error si algo está mal **antes** de reiniciar:

```bash
sudo sshd -t && echo "OK"
```

Si imprime `OK`, seguir. Si reporta un error, corregirlo en `/etc/ssh/sshd_config.d/10-homelab.conf` y volver a validar. **No reiniciar `sshd` con una configuración inválida**, porque dejaría el demonio caído y sin acceso remoto.

### 3.4. Recargar el demonio

```bash
sudo systemctl reload ssh
```

Comprobar que sigue activo y escuchando:

```bash
sudo systemctl status ssh --no-pager
sudo ss -ltnp | grep :22
```

### 3.5. Probar una conexión nueva

Desde el PC de administración, **abrir una tercera sesión** sin cerrar las dos anteriores:

```bash
ssh homelab
```

Debe entrar **sin pedir password**. Si por algún motivo SSH pide password o rechaza la clave:

- Verificar `~/.ssh/authorized_keys` en la Pi (paso 2).
- En el PC de administración, depurar con `ssh -v homelab`.
- Si todo falla, desde una de las sesiones que sigan vivas, restaurar el backup:
  ```bash
  sudo rm /etc/ssh/sshd_config.d/10-homelab.conf
  sudo systemctl reload ssh
  ```

Solo cuando la nueva sesión funciona se puede dar por completado este paso.

---

## 4. Firewall con `ufw`

`ufw` (Uncomplicated Firewall) es la frontend estándar en Debian para gestionar `nftables`. Permite expresar la política con reglas legibles y es suficientemente potente para todo lo que va a hacer el homelab.

> **Cuidado**: como con `sshd`, **dejar dos sesiones SSH abiertas** mientras se aplica la política. Una regla mal escrita puede cortar el acceso. Si pasa, una de las sesiones existentes seguirá viva y permitirá revertir.

### 4.1. Instalar `ufw`

```bash
sudo apt install -y ufw
```

### 4.2. Determinar la subred de la LAN

Antes de escribir reglas, anotar la subred local. Por ejemplo, para una LAN típica de `192.168.1.0/24`:

```bash
ip -br addr show eth0
```

Salida típica:

```
eth0  UP  192.168.1.50/24 ...
```

→ La subred es `192.168.1.0/24`. Sustituir este valor en las reglas siguientes por el de la red propia.

### 4.3. Aplicar la política base

```bash
# Empezar limpio (solo si nunca se configuró antes).
sudo ufw --force reset

# Política por defecto: nada entra, todo sale.
sudo ufw default deny incoming
sudo ufw default allow outgoing

# SSH solo desde la LAN, con rate limit (6 intentos en 30 s por IP).
sudo ufw limit from 192.168.1.0/24 to any port 22 proto tcp comment 'SSH desde LAN'

# (Opcional) ICMP entrante desde la LAN, útil para `ping` desde otros equipos.
# ufw permite ICMP por defecto en before.rules; no hace falta una regla extra.

# Habilitar el firewall.
sudo ufw enable
```

`ufw enable` pedirá confirmación porque advierte de que puede cortar conexiones SSH activas. Como SSH está explícitamente permitido en la regla anterior y desde la subred LAN, las sesiones existentes sobreviven. Aun así, el aviso es por algo: confirmar solo con las dos sesiones de seguridad abiertas.

### 4.4. Verificar el estado

```bash
sudo ufw status verbose
sudo ufw status numbered
```

Salida esperada (resumen):

```
Status: active
Logging: on (low)
Default: deny (incoming), allow (outgoing), disabled (routed)

To                         Action      From
--                         ------      ----
22/tcp                     LIMIT       192.168.1.0/24             # SSH desde LAN
```

Y a nivel de `nftables` debe aparecer la cadena de `ufw`:

```bash
sudo nft list ruleset | head
```

### 4.5. Notas sobre futuras fases

- **Tailscale** ([`../03-red/05-tailscale.md`](../03-red/05-tailscale.md)) crea una interfaz `tailscale0` y, si se instala como paquete del sistema, gestiona automáticamente sus propias reglas. No hace falta abrir UDP 41641 en `ufw` mientras la Pi sea solo cliente.
- **Pi-hole en macvlan** ([`../03-red/02-pihole.md`](../03-red/02-pihole.md)) tiene IP propia en la LAN, así que el tráfico DNS no pasa por la pila del host (Pi). El firewall del host no necesita reglas para el puerto 53 mientras Pi-hole viva en macvlan.
- **Caddy, Jellyfin, Nextcloud y demás servicios Docker** publicarán puertos en el host. Cuando llegue el momento se añadirán reglas tipo:
  ```bash
  sudo ufw allow from 192.168.1.0/24 to any port 443 proto tcp comment 'HTTPS Caddy'
  ```
  El mapa completo de puertos del homelab vivirá en [`../13-operaciones/04-red-y-puertos.md`](../13-operaciones/04-red-y-puertos.md).

---

## 5. `fail2ban` (jail SSH)

`fail2ban` lee logs (vía `systemd-journal` en Bookworm), detecta patrones de abuso y banea IPs vía `nftables`/`iptables`/`ufw`. En este documento solo se configura el **jail de SSH**: lo único expuesto a la red en este punto. Los jails para servicios web (Authelia, Nextcloud, Vaultwarden) se añaden en [`../04-seguridad/02-fail2ban.md`](../04-seguridad/02-fail2ban.md), cuando ya existan esos servicios y sus logs.

### 5.1. Instalar

```bash
sudo apt install -y fail2ban
```

El paquete crea `/etc/fail2ban/` con `jail.conf` (no se toca) y arranca el servicio en modo por defecto.

### 5.2. Configurar `jail.local`

`fail2ban` espera que las personalizaciones vivan en `jail.local` (no en `jail.conf`, que se sobrescribe en cada upgrade del paquete):

```bash
sudo tee /etc/fail2ban/jail.local > /dev/null <<'EOF'
# Homelab — configuración base de fail2ban.
# Documentado en docs/01-sistema/03-seguridad-base.md.

[DEFAULT]
# Backend basado en systemd-journal: en Bookworm los logs de sshd no van a /var/log/auth.log.
backend = systemd

# Tiempos por defecto.
findtime = 10m
maxretry = 5
bantime  = 1h
# Aumento progresivo: cada nueva reincidencia multiplica el bantime.
bantime.increment = true
bantime.factor    = 2
bantime.maxtime   = 1w

# Banear con nftables y bloquear todos los puertos para la IP atacante.
banaction = nftables-allports

# No banear nunca a las IPs de la LAN ni al loopback.
# Sustituir 192.168.1.0/24 por la subred propia si es distinta.
ignoreip = 127.0.0.1/8 ::1 192.168.1.0/24

[sshd]
enabled = true
port    = ssh
EOF
```

Sobre las decisiones:

- `backend = systemd`: en Bookworm `sshd` loggea por `journald` y no por defecto a `/var/log/auth.log`. Sin este backend `fail2ban` no encuentra los eventos.
- `bantime.increment`: un atacante que vuelve tras un baneo se gana baneos cada vez más largos. Es la forma estándar de defenderse de fuerza bruta lenta.
- `banaction = nftables-allports`: aísla por completo a la IP mientras dura el baneo, no solo el puerto SSH. La cadena `nftables` es la nativa de Debian Bookworm.
- `ignoreip` con la subred LAN: evita que un error de tecleo del propio operador desde su PC acabe baneando la IP local. **No** es una invitación a confiar ciegamente en la LAN; el rate limit de `ufw` (paso 4.3) sigue actuando sobre esa misma subred.

> **Coherencia con `ufw`**: este homelab usa `nftables-allports` directamente, no `ufw`. Mezclar ambos baneadores complica la depuración. Si en el futuro se prefiere que `fail2ban` baneé vía `ufw`, cambiar a `banaction = ufw`. **No usar las dos a la vez.**

### 5.3. Activar y habilitar

```bash
sudo systemctl enable --now fail2ban
sudo systemctl status fail2ban --no-pager
```

Verificar que el jail SSH está cargado:

```bash
sudo fail2ban-client status
sudo fail2ban-client status sshd
```

Salida esperada de `status sshd`:

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

### 5.4. (Opcional) Smoke test

Desde un equipo **fuera de la LAN** (por ejemplo, otro nodo Tailscale cuando esté disponible, o una máquina puntual con SSH desde la LAN si se prefiere ver el efecto del rate limit/baneo) hacer 6 intentos seguidos con un usuario inexistente. La IP debería aparecer baneada:

```bash
sudo fail2ban-client status sshd
sudo nft list set inet f2b-table addr-set-sshd  # si existe la tabla
```

Para desbanear manualmente (típico durante el bootstrap):

```bash
sudo fail2ban-client unban <ip>
# o
sudo fail2ban-client unban --all
```

---

## 6. Actualizaciones automáticas (`unattended-upgrades`)

La Pi va a estar siempre encendida y desatendida. Aplicar parches de seguridad de Debian Bookworm en automático es la forma más sencilla y eficaz de mantenerla al día.

### 6.1. Instalar

```bash
sudo apt install -y unattended-upgrades apt-listchanges
```

Tras la instalación, Debian preconfigura `/etc/apt/apt.conf.d/20auto-upgrades` con las claves mínimas (`Update-Package-Lists` y `Unattended-Upgrade` activados). Verificarlo:

```bash
cat /etc/apt/apt.conf.d/20auto-upgrades
```

Si por algún motivo el fichero no existe o está vacío, regenerarlo:

```bash
sudo dpkg-reconfigure --priority=low unattended-upgrades
```

### 6.2. Personalizar política

Ajustar el fichero principal de `unattended-upgrades` con los criterios del homelab:

```bash
sudo tee /etc/apt/apt.conf.d/52homelab-unattended-upgrades > /dev/null <<'EOF'
// Homelab — política de actualizaciones automáticas.
// Documentado en docs/01-sistema/03-seguridad-base.md.

// Aplicar parches de seguridad y actualizaciones del repositorio principal.
// El origin/codename para Bookworm es "Debian:bookworm" / "Debian:bookworm-security" / "Raspbian:bookworm".
Unattended-Upgrade::Origins-Pattern {
    "origin=Debian,codename=${distro_codename},label=Debian";
    "origin=Debian,codename=${distro_codename},label=Debian-Security";
    "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
    "origin=Raspbian,codename=${distro_codename},label=Raspbian";
    "origin=Raspberry Pi Foundation,codename=${distro_codename},label=Raspberry Pi Foundation";
};

// Limpieza de paquetes antiguos y dependencias huérfanas.
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";

// Reinicio automático si un paquete lo requiere (kernel, libc).
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-WithUsers "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";

// No tocar paquetes que requieran interacción (no debería pasar en Lite).
Unattended-Upgrade::MinimalSteps "true";
EOF
```

Las claves clave son:

- `Origins-Pattern`: limita las actualizaciones automáticas a los repositorios de Debian/Raspberry Pi. **No** se actualizan automáticamente paquetes de terceros (Docker, Tailscale, etc.) desde sus propios repos: esas se hacen manualmente o se delegan en Watchtower a nivel de imágenes Docker.
- `Automatic-Reboot-Time "04:00"`: si tras instalar parches el sistema necesita reiniciar (por ejemplo, kernel o `libc`), lo hace a las 04:00 CET. Es la franja en la que el homelab tiene menos uso.
- `Remove-Unused-Kernel-Packages "true"`: evita acumular kernels viejos que llenan `/boot` (en Pi 5 con `/boot/firmware`).

### 6.3. Probar en seco

Antes de dejar correr el cron diario, hacer un dry-run para detectar problemas:

```bash
sudo unattended-upgrade --dry-run --debug
```

La salida debería listar paquetes candidatos a actualización (puede ser ninguno si el sistema acaba de hacer `apt full-upgrade` en [`02-configuracion-inicial.md`](./02-configuracion-inicial.md)) y terminar sin errores.

### 6.4. Activar el timer

`unattended-upgrades` corre por systemd timer. Asegurarse de que está activo:

```bash
sudo systemctl status apt-daily.timer apt-daily-upgrade.timer --no-pager
```

Ambos timers deben aparecer como `active (waiting)`. El primero refresca índices, el segundo aplica las actualizaciones.

Para forzar una ejecución inmediata (útil tras tocar la configuración):

```bash
sudo systemctl start apt-daily.service
sudo systemctl start apt-daily-upgrade.service
```

### 6.5. Logs

Los logs viven en `/var/log/unattended-upgrades/`:

```bash
sudo ls -lh /var/log/unattended-upgrades/
sudo tail -n 50 /var/log/unattended-upgrades/unattended-upgrades.log
```

Más adelante, cuando exista Prometheus + Grafana ([`../05-monitorizacion/`](../05-monitorizacion/)), conviene exponer estos logs y el estado del último upgrade. Por ahora basta con que estén accesibles vía SSH.

---

## Lista de Verificación

Antes de pasar a [`04-estructura-directorios.md`](./04-estructura-directorios.md):

- [ ] La contraseña del usuario `homelab` se ha cambiado por una nueva, robusta y guardada en el gestor.
- [ ] `id pi` indica que el usuario no existe (o está bloqueado y con shell `nologin`).
- [ ] `sudo passwd -S root` indica `root L`.
- [ ] `~/.ssh` tiene permisos `700` y `~/.ssh/authorized_keys` tiene permisos `600`, ambos propiedad de `homelab:homelab`.
- [ ] Existe el drop-in `/etc/ssh/sshd_config.d/10-homelab.conf` y `sudo sshd -t` devuelve OK.
- [ ] Una **nueva** sesión `ssh homelab` entra **sin pedir password**.
- [ ] `sudo ufw status verbose` reporta `Status: active`, política `deny (incoming)` / `allow (outgoing)` y la regla `LIMIT 22/tcp from 192.168.1.0/24` (subred ajustada a la red propia).
- [ ] `sudo fail2ban-client status` lista el jail `sshd`; `sudo fail2ban-client status sshd` muestra `Banned IP list: ` vacío y `Currently failed: 0`.
- [ ] `cat /etc/apt/apt.conf.d/20auto-upgrades` muestra `Update-Package-Lists "1"` y `Unattended-Upgrade "1"`.
- [ ] Existe `/etc/apt/apt.conf.d/52homelab-unattended-upgrades` con `Automatic-Reboot "true"` y `Automatic-Reboot-Time "04:00"`.
- [ ] `sudo unattended-upgrade --dry-run --debug` termina sin errores.
- [ ] `sudo systemctl status apt-daily.timer apt-daily-upgrade.timer --no-pager` muestra ambos `active (waiting)`.

---

## Solución de Problemas

| Síntoma | Causa probable | Acción |
|---|---|---|
| Tras editar `sshd_config.d/10-homelab.conf` y `systemctl reload ssh`, una nueva conexión pide password | El servicio no recargó la nueva config (sintaxis errónea ignorada) o `PasswordAuthentication yes` está en otro fichero. | `sudo sshd -t` para validar; `sudo grep -R PasswordAuthentication /etc/ssh/` para encontrar el fichero que lo redefine. |
| Tras `ufw enable`, las dos sesiones SSH se cortan | Subred LAN equivocada en la regla, o la Pi tiene IP fuera de `192.168.1.0/24`. | Conectar por consola física, `sudo ufw disable`, ajustar la regla con la subred correcta y volver a `ufw enable`. |
| `ufw status` muestra `inactive` tras un reboot | El servicio `ufw` no estaba habilitado en systemd. | `sudo systemctl enable ufw`. |
| `fail2ban-client status` falla con `Failed to access socket` | El servicio aún no ha arrancado o se quedó en `failed`. | `sudo systemctl status fail2ban --no-pager`; revisar `journalctl -u fail2ban -n 100`. Suele ser un error de sintaxis en `jail.local`. |
| `fail2ban` arranca pero el jail `sshd` aparece sin `Journal matches` | Falta `backend = systemd` en `[DEFAULT]` o el `sshd` no loggea por journal. | Verificar `journalctl -u ssh -n 50` y, si vacía, ajustar `LogLevel INFO` en `sshd_config`. |
| El operador se autobaneó por error | Probó SSH desde un punto fuera de la LAN sin la clave correcta. | `sudo fail2ban-client unban <ip>` o `sudo fail2ban-client unban --all`. Considerar añadir esa IP/red a `ignoreip`. |
| `unattended-upgrade --dry-run` falla con `E: Could not get lock /var/lib/apt/lists/lock` | Hay un `apt` interactivo en otra sesión o `apt-daily.service` está corriendo. | Esperar (`ps -ef | grep apt`), o `sudo systemctl status apt-daily.service`. |
| Tras un upgrade automático, la Pi se reinicia a media tarde | `Automatic-Reboot-Time` mal configurado o reloj fuera de zona. | Verificar `timedatectl` y la línea `Automatic-Reboot-Time "04:00"`. |
| La fecha de los logs de `unattended-upgrades` no coincide con la zona horaria local | Logs internos en UTC. | Es esperado; correlacionar con `journalctl --since` para vista local. |
| Tras varias semanas, `/boot/firmware` se está llenando | `Remove-Unused-Kernel-Packages` no estaba activo y se acumularon kernels antiguos. | `sudo apt autoremove --purge` y verificar que la directiva está activa en `52homelab-unattended-upgrades`. |

---

## Referencias

- [Debian Wiki — Securing your Debian system](https://wiki.debian.org/SecuringDebian)
- [Raspberry Pi — Configuring SSH](https://www.raspberrypi.com/documentation/computers/remote-access.html#ssh)
- [`sshd_config(5)` — manual page](https://man7.org/linux/man-pages/man5/sshd_config.5.html)
- [`passwd(1)` — manual page](https://man7.org/linux/man-pages/man1/passwd.1.html)
- [`ufw(8)` — manual page](https://manpages.debian.org/bookworm/ufw/ufw.8.en.html)
- [Debian Wiki — `nftables`](https://wiki.debian.org/nftables)
- [`fail2ban` — documentación oficial](https://github.com/fail2ban/fail2ban/wiki)
- [`fail2ban` — `jail.conf(5)` y `filter.conf(5)`](https://manpages.debian.org/bookworm/fail2ban/jail.conf.5.en.html)
- [Debian Wiki — `UnattendedUpgrades`](https://wiki.debian.org/UnattendedUpgrades)
- [`unattended-upgrade(8)` — manual page](https://manpages.debian.org/bookworm/unattended-upgrades/unattended-upgrade.8.en.html)
- [`apt-daily.timer` y `apt-daily-upgrade.timer` — systemd](https://manpages.debian.org/bookworm/apt/apt-daily.8.en.html)
