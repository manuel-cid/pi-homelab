# Seguridad Base del Host

## Descripción

Procedimiento para aplicar el **endurecimiento inicial del sistema operativo** sobre la **Raspberry Pi 5** una vez que ya arranca desde el **SSD NVMe** y tiene completada su configuración básica. El objetivo es dejar el host con una postura de seguridad razonable para un homelab de **solo acceso local (LAN) + Tailscale**, sin exposición directa a internet y sin depender todavía de medidas específicas de cada servicio.

Este documento cubre cinco bloques: cambio de contraseña inicial, acceso por **claves SSH**, desactivación del login por contraseña, firewall a nivel de host y protección básica con **Fail2ban** solo para **SSH**. También deja activadas las **actualizaciones automáticas** del sistema. Las reglas de puertos más detalladas y la política final de acceso se complementarán más adelante en [06-puertos-y-firewall.md](/Users/x441425/workspace2/homelab/docs/03-red/06-puertos-y-firewall.md).

La configuración avanzada de **Fail2ban** para servicios concretos no se hace aquí. Esa parte se documenta más adelante en [02-fail2ban.md](/Users/x441425/workspace2/homelab/docs/04-seguridad/02-fail2ban.md).

## Requisitos Previos

- Haber completado [01-instalacion-os.md](/Users/x441425/workspace2/homelab/docs/01-sistema/01-instalacion-os.md).
- Haber completado [02-configuracion-inicial.md](/Users/x441425/workspace2/homelab/docs/01-sistema/02-configuracion-inicial.md).
- Poder abrir una sesión por **SSH** con el usuario administrativo local.
- Tener preparada al menos una **clave pública SSH** del equipo desde el que vas a administrar el homelab.
- Disponer de conectividad de red funcional, preferiblemente por **Ethernet**.
- Tener decidido de antemano:
  - si vas a permitir acceso administrativo desde **LAN**, desde **Tailscale** o desde ambas
  - qué usuario local será el administrador principal del host

## Objetivo de esta Fase

Al terminar este documento, el estado esperado es este:

- El usuario administrativo ya no depende de la contraseña inicial definida durante la instalación.
- El acceso remoto al host usa **claves SSH**.
- El login por contraseña en **SSH** queda deshabilitado.
- El login remoto del usuario `root` queda deshabilitado.
- El firewall del host queda activo con política restrictiva y una base mínima coherente con esta fase.
- **Fail2ban** protege el servicio **SSH** a nivel de host.
- Las **actualizaciones automáticas** de seguridad y mantenimiento base quedan habilitadas.

## Docker Compose

No aplica en esta fase. Aquí todavía no se instala Docker ni se despliegan servicios.

## Configuración

### 1. Verificar el estado actual del acceso SSH

Antes de endurecer nada, comprueba que el servicio SSH está levantado y qué usuario estás usando:

```bash
whoami
hostnamectl
systemctl status ssh --no-pager
ss -tulpn | grep ':22'
```

El objetivo de esta comprobación es simple: confirmar que el acceso remoto está funcionando antes de tocar autenticación, firewall o bans automáticos.

### 2. Cambiar la contraseña inicial del usuario administrador

Aunque vayas a operar principalmente con claves SSH, cambia primero la contraseña del usuario administrativo para no conservar la credencial inicial definida durante la instalación:

```bash
passwd
```

Si necesitas cambiar la contraseña de otro usuario explícitamente:

```bash
sudo passwd <user>
```

Usa una contraseña larga y única, guardada en tu gestor de secretos. No habilites ni uses una contraseña separada para `root`.

### 3. Instalar la clave pública SSH del equipo administrador

Si todavía no lo hiciste durante la instalación inicial, copia tu clave pública al host. Desde tu equipo cliente, la forma más cómoda suele ser:

```bash
ssh-copy-id <user>@<ip-o-hostname>
```

Si prefieres hacerlo manualmente en la Raspberry Pi:

```bash
mkdir -p ~/.ssh
chmod 700 ~/.ssh
nano ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

Pega dentro la clave pública correcta en una sola línea.

Antes de seguir, abre **una segunda sesión SSH** y verifica que puedes entrar con la clave. No cierres la sesión original hasta validar este punto.

### 4. Endurecer la configuración de SSH

En Raspberry Pi OS es preferible usar un fichero de configuración adicional en vez de editar directamente el fichero principal. Crea este drop-in:

```bash
sudo nano /etc/ssh/sshd_config.d/10-homelab-hardening.conf
```

Contenido recomendado:

```conf
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
ChallengeResponseAuthentication no
UsePAM yes
X11Forwarding no
```

Con esta configuración:

- `root` no puede iniciar sesión por SSH.
- el acceso por contraseña queda deshabilitado
- la autenticación esperada pasa a ser por clave pública
- se reduce superficie innecesaria como `X11Forwarding`

Valida la sintaxis antes de reiniciar el servicio:

```bash
sudo sshd -t
```

Si no devuelve errores, aplica el cambio:

```bash
sudo systemctl restart ssh
```

Comprueba otra vez desde una segunda sesión que el acceso por clave sigue funcionando.

### 5. Instalar las herramientas base de seguridad

Instala el conjunto mínimo que se usará en esta fase:

```bash
sudo apt update
sudo apt install -y ufw fail2ban unattended-upgrades apt-listchanges
```

Se usa **`ufw`** como capa operativa de firewall por simplicidad. En sistemas modernos puede apoyarse en backend basado en `nftables`, pero para este homelab interesa una gestión clara y fácil de mantener. Si más adelante decides operar con reglas `nftables` puras, mantén la misma política lógica documentada aquí y compárala con [06-puertos-y-firewall.md](/Users/x441425/workspace2/homelab/docs/03-red/06-puertos-y-firewall.md).

### 6. Activar una política mínima de firewall

En esta fase todavía no hay servicios de aplicación expuestos, así que la política base debe ser muy conservadora:

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow OpenSSH
sudo ufw enable
```

Comprueba el estado:

```bash
sudo ufw status verbose
```

Resultado esperado en esta fase:

- política por defecto `deny` para tráfico entrante
- política `allow` para tráfico saliente
- **SSH** permitido
- ningún otro puerto abierto manualmente todavía

`ufw allow OpenSSH` abre el acceso SSH en el host sin entrar todavía en reglas finas por subred, interfaz o servicio. Ese refinamiento vendrá más adelante, cuando el mapa completo de puertos del homelab esté definido en [06-puertos-y-firewall.md](/Users/x441425/workspace2/homelab/docs/03-red/06-puertos-y-firewall.md).

### 7. Configurar Fail2ban solo para SSH

En esta fase **Fail2ban** solo debe proteger el acceso al host por SSH. No añadas aquí jails de aplicaciones, reverse proxies o contenedores.

Crea un fichero específico:

```bash
sudo nano /etc/fail2ban/jail.d/sshd.local
```

Contenido recomendado:

```ini
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5
banaction = ufw

[sshd]
enabled = true
backend = systemd
port = ssh
```

Con esta política:

- una fuente que falle repetidamente autenticación SSH quedará bloqueada temporalmente
- el ban se aplicará integrándose con **`ufw`**
- se usará el journal de `systemd`, evitando depender de rutas de log más frágiles

Activa y arranca el servicio:

```bash
sudo systemctl enable --now fail2ban
```

Valida el estado:

```bash
sudo fail2ban-client status
sudo fail2ban-client status sshd
```

Si el jail `sshd` aparece activo, la parte base queda correcta.

### 8. Habilitar actualizaciones automáticas

El homelab no debe depender de que recuerdes ejecutar actualizaciones de seguridad a mano todas las semanas. Activa **`unattended-upgrades`**:

```bash
sudo dpkg-reconfigure -plow unattended-upgrades
```

Cuando el asistente lo pregunte, responde que **sí**.

Después, revisa que el automatismo periódico quede activo:

```bash
sudo nano /etc/apt/apt.conf.d/20auto-upgrades
```

Contenido mínimo esperado:

```conf
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
```

Opcionalmente, añade también limpieza automática:

```conf
APT::Periodic::AutocleanInterval "7";
```

Para este homelab es razonable **no forzar reinicios automáticos** tras una actualización. Si más adelante ajustas ese comportamiento, documenta la decisión en la fase de operaciones y mantenimientos.

### 9. Verificación final de seguridad base

Antes de pasar a la siguiente guía, ejecuta una comprobación rápida:

```bash
sudo sshd -t
sudo ufw status verbose
sudo fail2ban-client status sshd
sudo systemctl status unattended-upgrades --no-pager
sudo systemctl status fail2ban --no-pager
```

Además, valida operativamente estos puntos:

- puedes abrir una sesión SSH con tu **clave pública**
- no puedes autenticarte por contraseña en SSH
- `root` no puede iniciar sesión remotamente
- el firewall está activo
- Fail2ban tiene cargado el jail `sshd`

### 10. Qué hacer justo después

Con el host ya endurecido, el siguiente paso natural es definir la estructura persistente de carpetas y montajes en [04-estructura-directorios.md](/Users/x441425/workspace2/homelab/docs/01-sistema/04-estructura-directorios.md). Más adelante, cuando se incorporen servicios y reglas más granulares, completa la parte de red con [06-puertos-y-firewall.md](/Users/x441425/workspace2/homelab/docs/03-red/06-puertos-y-firewall.md) y amplía Fail2ban con [02-fail2ban.md](/Users/x441425/workspace2/homelab/docs/04-seguridad/02-fail2ban.md).

## Almacenamiento

Esta fase no introduce volúmenes de aplicación, pero sí añade ficheros de configuración relevantes del host, todos ellos en el **SSD NVMe** dentro del sistema operativo:

- `/etc/ssh/sshd_config.d/10-homelab-hardening.conf`
- `/etc/ufw/`
- `/etc/fail2ban/jail.d/sshd.local`
- `/etc/apt/apt.conf.d/20auto-upgrades`
- `/etc/apt/apt.conf.d/50unattended-upgrades`

No guardes configuraciones de seguridad del host en `hd2t` ni en `hd5t`. Esos discos están reservados para multimedia y backups, no para el estado operativo del sistema.

## Backup

Conviene respaldar o al menos poder reconstruir sin improvisar estos elementos:

- la clave pública autorizada en `~/.ssh/authorized_keys`
- la política SSH aplicada en `/etc/ssh/sshd_config.d/10-homelab-hardening.conf`
- la configuración de **`ufw`**
- la configuración base de **Fail2ban** en `/etc/fail2ban/jail.d/sshd.local`
- los ajustes de **`unattended-upgrades`**

Además, conserva en tu gestor de secretos:

- la contraseña administrativa vigente
- la huella o identificación de las claves SSH usadas para administrar el host

## Referencias

- OpenSSH
- UFW
- Fail2ban
- unattended-upgrades
- `man sshd_config`
- `man ufw`
- [01-instalacion-os.md](/Users/x441425/workspace2/homelab/docs/01-sistema/01-instalacion-os.md)
- [02-configuracion-inicial.md](/Users/x441425/workspace2/homelab/docs/01-sistema/02-configuracion-inicial.md)
- [06-puertos-y-firewall.md](/Users/x441425/workspace2/homelab/docs/03-red/06-puertos-y-firewall.md)
- [02-fail2ban.md](/Users/x441425/workspace2/homelab/docs/04-seguridad/02-fail2ban.md)
