# Seguridad base del host

## Descripción
Procedimiento para aplicar el **endurecimiento básico del sistema operativo** en la Raspberry Pi 5 una vez que ya arranca desde el **SSD NVMe** y tiene la configuración inicial completada.

El objetivo de este documento es reducir la superficie de ataque del host antes de instalar Docker y el resto de servicios del homelab. Al terminar, el acceso administrativo debe quedar limitado a **SSH por clave**, el firewall del host debe estar activo, `fail2ban` debe vigilar solo el acceso SSH y las actualizaciones de seguridad deben instalarse automáticamente.

Este homelab sigue siendo un entorno de **solo LAN + Tailscale**, sin exposición directa a internet, sin aperturas de puertos en el router y sin servicios públicos accesibles desde fuera.

## Requisitos Previos
- Haber completado `docs/01-sistema/01-instalacion-os.md`.
- Haber completado `docs/01-sistema/02-configuracion-inicial.md`.
- Poder acceder por SSH al host con el usuario administrador.
- Tener identificada la subred de administración de la LAN, por ejemplo `192.168.1.0/24`.
- Tener preparada una clave pública SSH para el usuario administrador.
- Poder usar `sudo` sin incidencias.
- Puertos implicados en esta fase:
  - `22/tcp` para administración SSH desde la LAN
  - no se abre ningún otro puerto del host en esta fase

## Docker Compose
No aplica en esta fase. Aquí se protege el host base sobre el que después se desplegarán Docker Engine y los servicios del homelab.

## Configuración

### Objetivo de esta fase

| Elemento | Estado esperado al terminar este documento |
|---|---|
| Contraseña del usuario administrador | cambiada y robusta |
| Acceso SSH | por clave pública |
| Login SSH con contraseña | deshabilitado |
| Login SSH de `root` | deshabilitado |
| Firewall del host | activo |
| `fail2ban` | activo, solo protegiendo `sshd` |
| Actualizaciones automáticas | activas para paquetes de seguridad |

### Estrategia recomendada

El flujo recomendado es este:

1. Cambiar la contraseña inicial del usuario administrador.
2. Confirmar que el acceso SSH por clave funciona antes de tocar `sshd`.
3. Endurecer OpenSSH y deshabilitar autenticación por contraseña.
4. Activar el firewall del host. La opción recomendada en este documento es **UFW**.
5. Instalar `fail2ban` con una única jail para SSH.
6. Activar `unattended-upgrades` para reducir el tiempo de exposición a vulnerabilidades corregidas.
7. Validar todo en una segunda sesión SSH antes de cerrar la actual.

Decisiones operativas de esta fase:

- Se endurece solo el **host base**. Las protecciones específicas de servicios se documentarán más adelante, cuando esos servicios existan.
- Se prioriza **simplicidad operativa**: una política clara, pocos puertos abiertos y reglas fáciles de revisar.
- Se recomienda **UFW** como frontend del firewall por ser suficiente para un único host doméstico.
- `nftables` se incluye como alternativa para quien prefiera gestionar el firewall de forma nativa, pero **no debes usar UFW y `nftables` a la vez**.

### 1. Cambiar la contraseña del usuario administrador

Si el usuario fue creado durante la instalación inicial o todavía conserva una contraseña temporal, cámbiala ahora:

```bash
passwd
```

La contraseña debe ser robusta aunque después deshabilites el login SSH por contraseña, porque sigue siendo relevante para:

- uso local eventual con teclado y monitor
- operaciones con `sudo`
- recuperación si todavía no has validado bien el acceso por clave

Recomendaciones mínimas:

- usar una contraseña larga y única
- no reutilizar contraseñas de otros servicios
- no depender solo de la contraseña como mecanismo principal de administración

### 2. Preparar y validar el acceso SSH por clave

Si ya configuraste autenticación por clave en la fase de instalación, valida que sigue funcionando antes de endurecer `sshd`:

```bash
ls -ld ~/.ssh
ls -l ~/.ssh/authorized_keys
```

Permisos recomendados:

```bash
chmod 700 ~/.ssh
chmod 600 ~/.ssh/authorized_keys
```

Si todavía no tienes una clave en tu equipo cliente, genera una. Un ejemplo razonable es **Ed25519**:

```bash
ssh-keygen -t ed25519 -a 100 -C "homelab-admin"
```

Copiar la clave pública al host:

```bash
ssh-copy-id <usuario>@rpi5-homelab.local
```

Si `ssh-copy-id` no está disponible, añade manualmente el contenido de tu clave pública a `~/.ssh/authorized_keys` del usuario administrador.

Antes de continuar, **abre una segunda terminal** y confirma que puedes entrar por clave sin depender de la sesión actual:

```bash
ssh <usuario>@rpi5-homelab.local
```

No deshabilites la autenticación por contraseña hasta que esta prueba funcione.

### 3. Endurecer OpenSSH

En Raspberry Pi OS y Debian es preferible usar un fichero de configuración adicional en lugar de modificar agresivamente el fichero principal.

Crear el directorio si no existe:

```bash
sudo install -d -m 755 /etc/ssh/sshd_config.d
```

Crear `/etc/ssh/sshd_config.d/10-homelab.conf` con este contenido:

```sshconfig
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
UsePAM yes
X11Forwarding no
MaxAuthTries 3
LoginGraceTime 30
AllowUsers <usuario>
```

Notas importantes:

- si administras el host con más de un usuario, añade todos los usuarios permitidos en `AllowUsers` o elimina esa directiva hasta definir una política más cerrada
- no cierres la sesión SSH actual hasta validar que una sesión nueva entra correctamente por clave

Forma práctica de escribirlo desde shell:

```bash
sudo tee /etc/ssh/sshd_config.d/10-homelab.conf >/dev/null <<'EOF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
UsePAM yes
X11Forwarding no
MaxAuthTries 3
LoginGraceTime 30
AllowUsers <usuario>
EOF
```

Validar la configuración antes de recargar el servicio:

```bash
sudo sshd -t
sudo sshd -T | grep -E 'permitrootlogin|passwordauthentication|kbdinteractiveauthentication|pubkeyauthentication|maxauthtries|logingracetime|allowusers'
```

Si no devuelve errores:

```bash
sudo systemctl reload ssh
sudo systemctl status ssh --no-pager
```

Probar inmediatamente desde una **segunda sesión nueva**:

```bash
ssh <usuario>@rpi5-homelab.local
```

Comprobar además que el login por contraseña ya no funciona:

```bash
ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no <usuario>@rpi5-homelab.local
```

Resultado esperado:

- el acceso por clave funciona
- el acceso por contraseña falla
- el usuario `root` no puede entrar por SSH

### 4. Activar firewall con UFW

La opción recomendada para este host es **UFW** por simplicidad y mantenimiento. Permite dejar una política muy clara:

- denegar todo lo entrante por defecto
- permitir todo lo saliente
- abrir únicamente SSH desde la LAN
- añadir acceso por Tailscale cuando se instale más adelante

Instalar UFW:

```bash
sudo apt update
sudo apt install -y ufw
```

Aplicar política base:

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow from 192.168.1.0/24 to any port 22 proto tcp
```

Sustituye `192.168.1.0/24` por la subred real desde la que administras el homelab.

Activar y revisar:

```bash
sudo ufw enable
sudo ufw status verbose
```

Cuando instales Tailscale más adelante, añade también una regla para su interfaz:

```bash
sudo ufw allow in on tailscale0
sudo ufw status numbered
```

Notas operativas:

- si administras desde varias subredes internas, añade una regla por subred
- en esta fase no abras puertos de servicios porque todavía no hay ninguno que deba exponerse en el host
- si usas Docker en fases posteriores, revisa otra vez la política de firewall porque Docker puede gestionar reglas de red propias

### 5. Alternativa: firewall nativo con `nftables`

Si prefieres no usar UFW, puedes dejar el host protegido con `nftables`. Esta es una **alternativa**, no un paso adicional.

Instalar el paquete:

```bash
sudo apt update
sudo apt install -y nftables
```

Ejemplo mínimo de `/etc/nftables.conf`:

```nft
#!/usr/sbin/nft -f

flush ruleset

table inet filter {
  chain input {
    type filter hook input priority 0;
    policy drop;

    ct state established,related accept
    iif "lo" accept
    ip protocol icmp accept
    ip6 nexthdr icmpv6 accept
    tcp dport 22 ip saddr 192.168.1.0/24 accept
    iifname "tailscale0" accept
  }

  chain forward {
    type filter hook forward priority 0;
    policy drop;
  }

  chain output {
    type filter hook output priority 0;
    policy accept;
  }
}
```

Validar y activar:

```bash
sudo nft -c -f /etc/nftables.conf
sudo systemctl enable --now nftables
sudo nft list ruleset
```

Sustituye también aquí `192.168.1.0/24` por la subred real. Si eliges esta vía, no actives UFW.

### 6. Instalar y configurar `fail2ban` solo para SSH

`fail2ban` no sustituye al firewall. Su función aquí es reaccionar a intentos repetidos de acceso SSH fallido y bloquear temporalmente el origen.

Instalar:

```bash
sudo apt update
sudo apt install -y fail2ban
```

Crear `/etc/fail2ban/jail.d/sshd.local`:

```ini
[sshd]
enabled = true
backend = systemd
port = 22
maxretry = 5
findtime = 10m
bantime = 1h
bantime.increment = true
ignoreip = 127.0.0.1/8 ::1
```

Forma práctica de escribirlo:

```bash
sudo tee /etc/fail2ban/jail.d/sshd.local >/dev/null <<'EOF'
[sshd]
enabled = true
backend = systemd
port = 22
maxretry = 5
findtime = 10m
bantime = 1h
bantime.increment = true
ignoreip = 127.0.0.1/8 ::1
EOF
```

Reiniciar y validar:

```bash
sudo systemctl enable --now fail2ban
sudo systemctl restart fail2ban
sudo systemctl status fail2ban --no-pager
sudo fail2ban-client status
sudo fail2ban-client status sshd
```

Decisiones de esta jail:

- solo se protege `sshd`
- no se añaden jails de aplicaciones todavía
- no se excluye toda la LAN para que los intentos erróneos repetidos desde dentro de casa también puedan bloquearse

### 7. Activar actualizaciones automáticas

Para un homelab doméstico conviene automatizar al menos la instalación de actualizaciones de seguridad del sistema base.

Instalar los paquetes necesarios:

```bash
sudo apt update
sudo apt install -y unattended-upgrades apt-listchanges
```

Activar la periodicidad básica en `/etc/apt/apt.conf.d/20auto-upgrades`:

```conf
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
```

Forma práctica de dejarlo escrito:

```bash
sudo tee /etc/apt/apt.conf.d/20auto-upgrades >/dev/null <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
```

Crear un fichero local para ajustar comportamiento sin tocar el paquete base:

```conf
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
```

Ejemplo:

```bash
sudo tee /etc/apt/apt.conf.d/52unattended-upgrades-local >/dev/null <<'EOF'
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF
```

Validar en modo simulación:

```bash
sudo unattended-upgrade --dry-run --debug
systemctl status unattended-upgrades --no-pager
```

Decisión recomendada:

- permitir instalación automática de actualizaciones
- **no** reiniciar automáticamente el host
- hacer los reinicios manualmente cuando tú decidas, especialmente cuando el host ya tenga servicios en uso

### 8. Validación final del endurecimiento

Antes de cerrar la sesión actual, valida todo desde una segunda terminal o desde otro equipo de la LAN:

```bash
sudo sshd -t
sudo sshd -T | grep -E 'permitrootlogin|passwordauthentication|kbdinteractiveauthentication|pubkeyauthentication|allowusers'
sudo systemctl status ssh --no-pager
sudo ufw status verbose
sudo systemctl status fail2ban --no-pager
sudo fail2ban-client status sshd
sudo unattended-upgrade --dry-run
```

Si has elegido `nftables` en lugar de UFW, sustituye la comprobación del firewall por:

```bash
sudo nft list ruleset
```

Comprobaciones funcionales:

```bash
ssh <usuario>@rpi5-homelab.local
ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no <usuario>@rpi5-homelab.local
```

Estado esperado:

- el acceso administrativo por clave funciona
- el login SSH por contraseña falla
- el firewall está activo
- `fail2ban` muestra la jail `sshd`
- `unattended-upgrades` queda configurado sin reinicio automático

### 9. Qué queda pendiente tras este documento

Tras completar esta fase, el siguiente orden razonable es:

1. Definir la estructura permanente de directorios y montajes en `docs/01-sistema/04-estructura-directorios.md`.
2. Instalar Docker y continuar con `docs/02-docker/01-instalacion-docker.md`.
3. Añadir reglas de firewall adicionales cuando aparezcan nuevos servicios o la interfaz `tailscale0`.

## Almacenamiento

### Estado esperado tras completar este documento

| Ruta o fichero | Ubicación esperada | Uso |
|---|---|---|
| `/etc/ssh/sshd_config.d/10-homelab.conf` | SSD NVMe | endurecimiento de OpenSSH |
| `/etc/ufw/` | SSD NVMe | reglas del firewall si usas UFW |
| `/etc/nftables.conf` | SSD NVMe | reglas del firewall si usas `nftables` |
| `/etc/fail2ban/jail.d/sshd.local` | SSD NVMe | jail básica de SSH |
| `/etc/apt/apt.conf.d/20auto-upgrades` | SSD NVMe | periodicidad de actualización |
| `/etc/apt/apt.conf.d/52unattended-upgrades-local` | SSD NVMe | política local de `unattended-upgrades` |
| `~/.ssh/authorized_keys` | SSD NVMe | claves públicas autorizadas del usuario administrador |

### Decisiones de diseño

- Toda la configuración de seguridad del host reside en el **SSD NVMe** junto con el sistema operativo.
- No se almacena información operativa de seguridad en `hd2t` ni en `hd5t`.
- La clave privada SSH **no** debe vivir en la Raspberry Pi, sino en el equipo cliente desde el que administras el homelab.

## Backup
- Guardar copia de estos ficheros del host:
  - `/etc/ssh/sshd_config.d/10-homelab.conf`
  - `/etc/ufw/` o `/etc/nftables.conf`, según la opción elegida
  - `/etc/fail2ban/jail.d/sshd.local`
  - `/etc/apt/apt.conf.d/20auto-upgrades`
  - `/etc/apt/apt.conf.d/52unattended-upgrades-local`
- Mantener inventario de claves públicas autorizadas en `~/.ssh/authorized_keys`.
- Guardar también la salida de estos comandos para recuperación rápida:
  - `sudo ufw status verbose` o `sudo nft list ruleset`
  - `sudo fail2ban-client status sshd`
  - `sudo sshd -T | grep -E 'permitrootlogin|passwordauthentication|kbdinteractiveauthentication|pubkeyauthentication|allowusers'`
- No incluyas en backups del host la clave privada SSH del equipo cliente.

## Referencias
- `SERVICES.md`
- `docs/01-sistema/01-instalacion-os.md`
- `docs/01-sistema/02-configuracion-inicial.md`
- `docs/01-sistema/04-estructura-directorios.md`
- `docs/02-docker/01-instalacion-docker.md`
- OpenSSH
- UFW
- `nftables`
- `fail2ban`
- `unattended-upgrades`
