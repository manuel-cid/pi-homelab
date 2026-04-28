# Instalación del Sistema Operativo

## Descripción

Procedimiento para dejar la Raspberry Pi 5 con un sistema operativo base **listo para administrar por SSH desde la LAN**, sin necesidad de conectar nunca un monitor, un teclado ni un ratón. Se hace mediante **Raspberry Pi Imager** desde el equipo de trabajo (no desde la Pi), usando la imagen oficial **Raspberry Pi OS Lite (64-bit)** y aprovechando las **opciones avanzadas** del propio Imager para preconfigurar todo lo necesario:

- Hostname estable.
- Usuario administrador (no `pi`) con contraseña.
- **SSH habilitado con autenticación por clave pública** (no con contraseña).
- **Locale, teclado y zona horaria** correctos desde el primer arranque.
- **WiFi de emergencia** como red de respaldo (ruta principal: Ethernet).

Tras este documento la Pi arranca, sale a la red por cable, es accesible por SSH desde el equipo de trabajo y queda preparada para `02-configuracion-inicial.md` (actualizaciones, hostname definitivo, swap…) y `03-preparacion-discos.md` ya tratado en Fase 0 para dejar `/mnt/hd5t` y `/mnt/hd2t` montados.

> **Recordatorio de alcance**: la Pi se administra **solo desde la LAN o desde Tailscale**. No se publica nada en internet, no se abren puertos en el router. El SSH habilitado en este documento se restringe en `03-seguridad-base.md` (firewall y deshabilitación del login con contraseña).

---

## Requisitos Previos

- Hardware verificado según [`docs/00-hardware/01-material-necesario.md`](../00-hardware/01-material-necesario.md): Raspberry Pi 5 8 GB, fuente USB-C 27 W, microSD de **64 GB** (mínimo 32 GB; clase **A2 / U3** recomendada para latencia decente del SO) y cable Ethernet hasta el router.
- Esquema físico armado según [`docs/00-hardware/02-esquema-conexiones.md`](../00-hardware/02-esquema-conexiones.md). En este punto los discos USB **pueden estar desconectados**: se prepararán después en Fase 0/1, no son necesarios para instalar el SO.
- Equipo de trabajo (portátil, sobremesa…) con **Raspberry Pi Imager** instalado:
  - Linux: `sudo apt install rpi-imager` (o paquete equivalente).
  - macOS: `brew install --cask raspberry-pi-imager` o instalador `.dmg` oficial.
  - Windows: instalador `.exe` desde [raspberrypi.com/software](https://www.raspberrypi.com/software/).
  - Versión mínima recomendada: **1.8.x** (es la que incorpora el asistente moderno de "OS customisation"; versiones anteriores ofrecían un menú oculto con `Ctrl+Shift+X` con menos opciones).
- Lector de tarjetas microSD en el equipo de trabajo.
- **Par de claves SSH** disponible en el equipo de trabajo. Si todavía no existe:
  ```bash
  ls -l ~/.ssh/id_ed25519.pub 2>/dev/null \
    || ssh-keygen -t ed25519 -C "homelab-admin@$(hostname)" -f ~/.ssh/id_ed25519
  ```
  La clave **pública** (`~/.ssh/id_ed25519.pub`) se pegará en el Imager. La privada **nunca sale** del equipo de trabajo.
- Decisión tomada de antemano sobre estos parámetros, para no improvisar mientras se rellena el wizard:

  | Parámetro | Valor sugerido | Notas |
  |---|---|---|
  | **Hostname** | `homelab` | Nombre corto, sin guiones bajos, en minúsculas. Se publica vía mDNS como `homelab.local`. |
  | **Usuario** | `homelab` (o el que se prefiera, **nunca `pi`**) | El usuario `pi` es bien conocido y los bots de scanners lo prueban antes que cualquier otro. |
  | **Contraseña del usuario** | Larga (≥ 20 caracteres) y única | Solo se usará como respaldo: el acceso habitual será por clave SSH. Guardar en el gestor de contraseñas. |
  | **Locale** | `es_ES.UTF-8` | Mensajes y formatos en español. |
  | **Teclado** | `es` | Solo importa si alguna vez se conecta un teclado físico (recuperación). |
  | **Zona horaria** | `Europe/Madrid` | Cron, logs y timestamps de Borg dependen de esto. |
  | **País WiFi** | `ES` | Obligatorio para que el regulador WiFi habilite los canales correctos. |
  | **SSID + clave WiFi** | Red doméstica | Solo como respaldo; la conexión normal será por cable. |

---

## Descarga e Inicio de Raspberry Pi Imager

No se descarga manualmente la imagen `.img.xz`: el Imager la baja, verifica su `SHA-256` y la escribe directamente en la microSD. Es el flujo soportado oficialmente y evita errores de descompresión y de checksum.

```bash
# Linux: lanzar el Imager
rpi-imager
```

Comprobaciones antes de continuar:

- El Imager detecta la microSD insertada (aparece como dispositivo en "Storage").
- Hay conexión a internet en el equipo de trabajo (la imagen se descarga durante el flasheo).
- La microSD **no contiene datos importantes**: el flasheo borra todo su contenido sin avisar dos veces.

---

## Selección del Sistema Operativo

En el Imager:

1. **Choose device** → `Raspberry Pi 5`.

   Restringe la lista de imágenes a las compatibles con la Pi 5. Filtra automáticamente firmware antiguo y variantes de 32-bit.

2. **Choose OS** → `Raspberry Pi OS (other)` → `Raspberry Pi OS Lite (64-bit)`.

   Justificación de cada elección:

   | Decisión | Por qué |
   |---|---|
   | **Lite** (sin escritorio) | El homelab no necesita interfaz gráfica. Ahorra ~1.5 GB de la microSD, RAM, ciclos de CPU y superficie de ataque (no hay X11/Wayland, ni navegadores, ni gestor de sesiones). |
   | **64-bit** | La Pi 5 (BCM2712, ARM Cortex-A76) es de 64 bits. Imágenes Docker oficiales de servicios como Jellyfin, Nextcloud o Home Assistant tienen builds `arm64` mucho más mantenidas que las `armhf`. La 32-bit limita además a 4 GB de RAM por proceso, inaceptable cuando hay 8 GB instalados. |
   | Raspberry Pi OS (Debian) | Base Debian estable, kernel y firmware mantenidos por la Foundation con drivers específicos de la Pi 5 (PCIe, RP1). Alternativas como Ubuntu Server arm64 funcionan, pero arrastran cambios (snap, netplan…) que no aportan nada en este escenario. |

3. **Choose storage** → seleccionar la microSD por su tamaño y modelo.

   > **Aviso crítico**: confirmar dos veces que la unidad seleccionada es la microSD y **no un disco USB del equipo**. El Imager borra el destino completo sin recuperación posible.

---

## Configuración Headless ("OS customisation")

Tras pulsar **Next**, el Imager pregunta:

> *Would you like to apply OS customisation settings?*

Elegir **Edit Settings**. Es el paso clave del documento: aquí se preconfigura todo lo necesario para que la Pi sea utilizable por SSH desde el primer arranque, sin pantalla.

### Pestaña **General**

| Campo | Valor | Comentario |
|---|---|---|
| **Set hostname** | `homelab` | Activar la casilla. La Pi se anunciará por mDNS como `homelab.local` y será resoluble desde el equipo de trabajo si tiene Avahi/Bonjour (Linux con `avahi-daemon`, macOS y Windows 10+ ya lo soportan de serie). |
| **Set username and password** | Usuario `homelab` (no `pi`), contraseña larga y única | La contraseña queda almacenada en el `userconf` del primer boot. **No es** la clave SSH; es el `sudo` y el respaldo si la clave fallase. Hash con yescrypt aplicado por el Imager, no en texto plano. |
| **Configure wireless LAN** | Activar **solo como respaldo** | Ver sección dedicada más abajo. |
| **Set locale settings** | Time zone `Europe/Madrid`, Keyboard layout `es` | Evita el típico arranque con `en_GB` y teclado británico. |

### Pestaña **Services** — SSH

| Campo | Valor |
|---|---|
| **Enable SSH** | Activar. |
| Modo de autenticación | **Allow public-key authentication only** (no "Use password authentication"). |
| **Set authorized_keys for `<usuario>`** | Pegar el contenido completo de `~/.ssh/id_ed25519.pub` (una sola línea, empieza por `ssh-ed25519` y termina en el comentario). |

Justificación de habilitar SSH **solo por clave pública** desde el primer minuto:

- El primer arranque con SSH abierto a contraseña es una ventana en la que cualquier dispositivo de la LAN podría intentar fuerza bruta. Con clave pública desde el origen esa ventana **no existe**.
- En `03-seguridad-base.md` se reforzará deshabilitando explícitamente `PasswordAuthentication` en `sshd_config`, pero el Imager ya deja la configuración correcta de partida; es defensa en profundidad, no redundancia inútil.
- La contraseña del usuario sigue activa para `sudo` (necesaria) y para login local en consola (recuperación).

### Pestaña **Options**

| Campo | Valor recomendado |
|---|---|
| **Eject media when finished** | Activar. |
| **Enable telemetry** | Desactivar. |
| **Play sound when finished** | A gusto. |

---

## WiFi de Emergencia

La conexión normal del homelab es **Ethernet a un puerto del router**. Es más estable, más rápida (1 Gbps full duplex sin contención de medio compartido) y no se ve afectada por cambios de SSID/clave del WiFi doméstico.

Aun así, configurar la WiFi en el Imager como **red de respaldo** tiene un coste cero y un valor real:

- Si el cable Ethernet falla, la Pi sigue accesible vía WiFi sin necesidad de conectar pantalla y teclado para reconfigurarla.
- Si la Pi se mueve temporalmente (mantenimiento físico, mudanza), arranca y se ve en la red sin más.
- El SSID y la clave quedan en `/etc/NetworkManager/system-connections/<SSID>.nmconnection` con permisos `600`. No es texto plano accesible para usuarios sin sudo.

Configuración en el Imager:

| Campo | Valor |
|---|---|
| **SSID** | El SSID de la red doméstica. |
| **Hidden SSID** | Solo si la red está oculta. |
| **Password** | La clave WPA2/WPA3. |
| **Wireless LAN country** | `ES` (obligatorio para que el regulador habilite los canales 1–13 y 5 GHz correctos en España). |

> Si se prefiere no almacenar credenciales WiFi en la microSD, dejar la casilla desactivada y **no** marcar "Configure wireless LAN". En ese caso, el respaldo en caso de pérdida de Ethernet es montar la microSD en otro equipo y editar `/etc/NetworkManager/system-connections/` o conectar pantalla y teclado físicamente.

---

## Flasheo y Primer Arranque

### 1. Aplicar y escribir

1. Pulsar **Save** en el cuadro de "OS customisation".
2. Pulsar **Yes** ante la pregunta *Would you like to apply OS customisation settings?* y luego **Yes** ante *All existing data on the microSD will be erased*.
3. Esperar al ciclo completo de **Writing → Verifying**. La verificación lee la tarjeta tras escribir y compara checksums; cualquier microSD que falle aquí debe **descartarse**, no usarse "a ver si va".

Tiempo aproximado en una microSD A2 sobre USB 3.0: 5–10 minutos para una imagen Lite.

### 2. Insertar la microSD en la Pi

Con la Pi **sin alimentación** (cable USB-C desconectado):

- Insertar la microSD en su zócalo (al fondo, contactos hacia arriba).
- Verificar que el cable Ethernet está conectado al router/switch y que su LED de enlace está encendido.
- Confirmar que el cable USB-C **no** está aún en la Pi (mejor enchufar la fuente al final, con todo lo demás conectado).

### 3. Encender

Conectar la fuente al puerto USB-C **PD 27 W oficial**. La Pi 5 con fuentes inferiores entra en modo limitado (los puertos USB se capan a 600 mA combinados) y el SSD/HDDs USB pueden no enumerarse correctamente; con la fuente correcta esto no ocurre.

LEDs esperados:

- **PWR** (rojo): fijo desde que hay corriente.
- **ACT** (verde): parpadea durante el arranque a medida que se lee la microSD; pasa a destellos esporádicos en idle.
- **LEDs del puerto Ethernet**: enlace fijo + actividad parpadeante en cuanto el `dhclient` levante la interfaz.

El primer arranque tarda más que los siguientes: el `firstboot` regenera claves SSH del host, expande el filesystem de la microSD a la capacidad real de la tarjeta y aplica la configuración del Imager. Esperar **al menos 60–90 segundos** antes de intentar conectarse.

---

## Conexión por SSH desde el Equipo de Trabajo

### Resolución por mDNS

```bash
ping -c 2 homelab.local
ssh homelab@homelab.local
```

Si Avahi/Bonjour funciona en la red, esto basta.

### Resolución por IP (cuando mDNS no funciona)

Si `homelab.local` no resuelve (algunos routers ISP rompen mDNS, redes WiFi con aislamiento de clientes, etc.), localizar la IP por DHCP:

- Desde la interfaz web del router: buscar la entrada DHCP con hostname `homelab`.
- Desde la línea de comandos:
  ```bash
  # Ajustar la subred a la real:
  nmap -sn 192.168.1.0/24 | grep -B 2 -i "raspberry\|homelab"
  ```
- Como red de seguridad: `arp -a | grep -i b8:27:eb\\\|dc:a6:32\\\|d8:3a:dd\\\|2c:cf:67` (rangos de OUI de la Raspberry Pi Foundation).

Ya con la IP (ejemplo `192.168.1.50`):

```bash
ssh homelab@192.168.1.50
# La primera vez aceptar la fingerprint del host:
# The authenticity of host '192.168.1.50' can't be established.
# ED25519 key fingerprint is SHA256:xxxxx...
# Are you sure you want to continue connecting (yes/no)?
```

> **Buena práctica**: la fingerprint que aparece se anota una vez y se compara aquí. Si en el futuro vuelve a aparecer ese mensaje sin haber reinstalado la Pi, **no aceptar**: la host key ha cambiado y eso indica suplantación o reflasheo no planificado.

### Entrada de conveniencia en `~/.ssh/config`

En el equipo de trabajo:

```bash
cat >> ~/.ssh/config <<'EOF'
Host homelab
    HostName 192.168.1.50      # o homelab.local si mDNS funciona
    User homelab
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
EOF
chmod 600 ~/.ssh/config
```

A partir de aquí: `ssh homelab` basta. Esta entrada se reaprovecha en todos los documentos posteriores y se actualizará en `05-tailscale.md` para añadir un alias por la IP de Tailscale.

---

## Verificación Final

Lista de comprobaciones antes de pasar a `02-configuracion-inicial.md`:

| Comprobación | Comando (en la Pi por SSH) | Resultado esperado |
|---|---|---|
| Modelo correcto | `cat /proc/device-tree/model` | `Raspberry Pi 5 Model B Rev 1.0` (o similar). |
| Arquitectura 64-bit | `dpkg --print-architecture && uname -m` | `arm64` y `aarch64`. |
| SO Lite (sin escritorio) | `dpkg -l \| grep -E "xserver-xorg\|raspberrypi-ui-mods" \|\| echo "Lite OK"` | `Lite OK` (no aparecen paquetes de escritorio). |
| Hostname aplicado | `hostname` | `homelab`. |
| Usuario correcto | `id` | `uid=1000(homelab) gid=1000(homelab) ...`, **no** `pi`. |
| Locale y zona horaria | `localectl && timedatectl` | `LANG=es_ES.UTF-8`, `Time zone: Europe/Madrid`. |
| Ethernet activa | `ip -4 addr show eth0` | IP en la subred LAN. |
| WiFi de respaldo configurada | `nmcli -t -f NAME,DEVICE connection show` | Aparece la conexión WiFi (no necesariamente activa: la prioritaria es `eth0`). |
| SSH solo por clave | `sudo grep -E "^(PasswordAuthentication\|PubkeyAuthentication)" /etc/ssh/sshd_config* 2>/dev/null` | Documento Imager fija `PasswordAuthentication no`. Si no aparece, se reforzará en `03-seguridad-base.md`. |
| Sin errores en boot | `sudo dmesg --level=err,warn \| head -n 30` | Sin errores de hardware ni de la microSD. |

Si todo sale verde, la Pi tiene un SO base operativo y se puede continuar con la configuración inicial.

---

## Backup

En esta fase aún no hay datos de servicios que respaldar, pero sí información de instalación que conviene **persistir fuera de la microSD** (perderla obliga a repetir el wizard del Imager y a regenerar la host key):

- **Clave pública SSH** (`~/.ssh/id_ed25519.pub`) usada en el Imager: ya está en el equipo de trabajo, asegurarse de que el equipo a su vez tiene backup. La clave **privada** (`id_ed25519`) **nunca** se copia a la Pi ni se sube a ningún sitio; en caso de pérdida, regenerar el par y reescribir `authorized_keys` en la Pi.
- **Fingerprint del host SSH** (`ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` en la Pi): anotarla en el gestor de contraseñas para detectar suplantaciones futuras.
- **Configuración del wizard del Imager**: hostname, usuario, locale y zona horaria. Quedan documentados en este propio fichero, no hace falta exportarlos del Imager.
- **SSID y clave WiFi**: ya en el gestor de contraseñas doméstico, no almacenar copia adicional en el repositorio.
- Una vez aplicado `02-configuracion-inicial.md` y `03-seguridad-base.md`, el contenido de `/etc/ssh/`, `/etc/NetworkManager/system-connections/` y `/home/homelab/.ssh/` entrará en el ámbito de Borgmatic (Fase 7) como parte de la salvaguarda del SO. Mientras tanto, la microSD es regenerable: si falla, se reflashea siguiendo este mismo documento.

---

## Referencias

- [Documento anterior: `docs/00-hardware/03-preparacion-discos.md`](../00-hardware/03-preparacion-discos.md)
- [`SERVICES.md`](../../SERVICES.md) — Alcance de red (LAN + Tailscale, sin internet) y catálogo de servicios.
- [Raspberry Pi Imager — descarga oficial](https://www.raspberrypi.com/software/)
- [Raspberry Pi OS — guía oficial de instalación](https://www.raspberrypi.com/documentation/computers/getting-started.html)
- [Raspberry Pi OS — versiones disponibles](https://www.raspberrypi.com/software/operating-systems/)
- [Raspberry Pi — configuración headless](https://www.raspberrypi.com/documentation/computers/configuration.html#configuring-a-headless-raspberry-pi)
- [`ssh_config(5)` — manpage Debian](https://manpages.debian.org/bookworm/openssh-client/ssh_config.5.en.html)
- [`sshd_config(5)` — manpage Debian](https://manpages.debian.org/bookworm/openssh-server/sshd_config.5.en.html)
- [Avahi (mDNS) — Arch Wiki](https://wiki.archlinux.org/title/Avahi)
- [Documento siguiente: `02-configuracion-inicial.md`](./02-configuracion-inicial.md)
