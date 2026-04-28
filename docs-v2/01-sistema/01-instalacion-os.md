# Instalación del Sistema Operativo

## Descripción

Procedimiento para **instalar Raspberry Pi OS Lite 64-bit** en la microSD de la Raspberry Pi 5 y dejarla operativa en modo **headless** (sin teclado ni monitor), accesible exclusivamente por **SSH** sobre la LAN.

Se utiliza la herramienta oficial **Raspberry Pi Imager**, aprovechando su pantalla de **personalización avanzada** para preconfigurar de una sola vez:

- Hostname de la Pi.
- Usuario administrador y contraseña inicial.
- Habilitación de SSH con **autenticación por clave pública**.
- Locale (`es_ES.UTF-8`), zona horaria (`Europe/Madrid`) y disposición de teclado (`es`).
- WiFi de emergencia (opcional, como **fallback** si el cable Ethernet falla durante el bootstrap).

> **Alcance**: este documento termina cuando se puede entrar por `ssh usuario@<ip-de-la-pi>` desde el PC de administración. La actualización del sistema, el endurecimiento de seguridad y el resto de configuración inicial se hacen en los documentos siguientes de la Fase 1.

> **Recordatorio**: el homelab opera en **LAN + Tailscale**. La Pi se conecta por **Ethernet cableado** al router doméstico (ver [`../00-hardware/02-esquema-conexiones.md`](../00-hardware/02-esquema-conexiones.md)); el WiFi solo se preconfigura como red de emergencia.

---

## Requisitos Previos

- **Material físico** preparado según [`../00-hardware/01-material-necesario.md`](../00-hardware/01-material-necesario.md): Raspberry Pi 5 (8 GB), fuente oficial 27 W, microSD de 64 GB de alta resistencia, cable Ethernet.
- **Cableado** según [`../00-hardware/02-esquema-conexiones.md`](../00-hardware/02-esquema-conexiones.md): la Pi va al router por Ethernet; los discos `hd5t` y `hd2t` **no** se conectan todavía (se conectarán en [`../00-hardware/03-preparacion-discos.md`](../00-hardware/03-preparacion-discos.md), tras el primer arranque del SO).
- **PC de administración** (Linux, macOS o Windows) con:
    - Lector de tarjetas microSD.
    - **Raspberry Pi Imager v1.8 o superior** instalado (incluye la pantalla de personalización avanzada con OS customisation).
    - Cliente SSH (`ssh` nativo en Linux/macOS, o `ssh` integrado en PowerShell/WSL en Windows).
    - Capacidad de generar un par de claves SSH (`ssh-keygen`) si no existe ya `~/.ssh/id_ed25519.pub`.
- **Router doméstico** accesible para:
    - Consultar la IP que se ha asignado a la Pi tras el primer arranque (DHCP).
    - Reservar más adelante una IP estática para la Pi (se documenta en [`../03-red/`](../03-red/) y en `docs/13-operaciones/04-red-y-puertos.md`).

### Decisiones de diseño asumidas

| Decisión | Valor por defecto | Justificación |
|---|---|---|
| Sabor del SO | **Raspberry Pi OS Lite 64-bit** (Debian Bookworm, sin escritorio) | Es el SO oficialmente soportado para Pi 5 en ARM64. El homelab corre todo en Docker; un escritorio gráfico solo añadiría consumo de RAM y superficie de ataque. |
| Arquitectura | **64-bit (ARM64 / `aarch64`)** | Imágenes Docker oficiales priorizan `linux/arm64`. Algunas (Authelia, Vaultwarden, Stash, etc.) no publican `armhf`. Es obligatorio en este homelab. |
| Hostname | `homelab` | Corto, único en la LAN, fácil de recordar (`homelab.lan`, `homelab.local` vía mDNS). |
| Usuario administrador | `homelab` (no `pi`) | El usuario `pi` por defecto está deshabilitado en Pi OS Bookworm y, además, es objetivo conocido de ataques por SSH. Crear un usuario propio. |
| Autenticación SSH | **Clave pública** | El password se preconfigura solo para la primera consola (recovery), pero el acceso SSH real se hace por clave desde el primer arranque. El bloqueo total del login por password se hace en [`03-seguridad-base.md`](./03-seguridad-base.md). |
| Locale | `es_ES.UTF-8`, zona `Europe/Madrid`, teclado `es` | Coherencia con el entorno del operador. |

---

## 1. Preparar la clave SSH en el PC de administración

Si ya existe una clave SSH habitual (típicamente `~/.ssh/id_ed25519.pub` o `~/.ssh/id_rsa.pub`), usarla. Si no, generar una nueva en el **PC de administración**:

```bash
ssh-keygen -t ed25519 -C "homelab-admin@$(hostname)"
```

- Aceptar la ruta por defecto (`~/.ssh/id_ed25519`).
- Asignar una **passphrase** robusta: la clave queda almacenada cifrada en el PC; la passphrase se introduce solo al desbloquearla, normalmente vía `ssh-agent`.

Mostrar la **clave pública** (la que se va a copiar en la Pi); es la que termina en `.pub`:

```bash
cat ~/.ssh/id_ed25519.pub
```

Salida esperada (una sola línea):

```
ssh-ed25519 AAAAC3Nza... homelab-admin@miequipo
```

Esta línea entera (incluido el comentario al final) es la que se pega más adelante en Raspberry Pi Imager.

---

## 2. Descargar Raspberry Pi Imager

Desde el PC de administración, descargar e instalar **Raspberry Pi Imager** desde la web oficial:

- <https://www.raspberrypi.com/software/>

Está disponible para Linux (`.deb`, `.rpm`, AppImage), macOS y Windows. En Linux también suele estar en repositorios:

```bash
# Debian / Ubuntu
sudo apt install rpi-imager
```

Verificar que la versión es **≥ 1.8**:

```bash
rpi-imager --version
```

Versiones anteriores no incluyen la pantalla de personalización avanzada con la opción de **clave pública SSH**, que es indispensable para este flujo.

---

## 3. Insertar y preparar la microSD

1. Insertar la **microSD de 64 GB** en el lector del PC.
2. **Confirmar el dispositivo correcto** antes de cualquier acción para no formatear un disco equivocado:

    ```bash
    lsblk -o NAME,SIZE,TRAN,MODEL,MOUNTPOINT
    ```

    La microSD aparecerá típicamente como `/dev/sdX` o `/dev/mmcblkN` con el tamaño de ~58–60 GiB y `TRAN=usb` o `mmc`.

3. Si el sistema la ha montado automáticamente, desmontarla:

    ```bash
    sudo umount /dev/sdX*  2>/dev/null || true
    ```

> Raspberry Pi Imager se encarga de **borrar y reescribir** la tarjeta entera, así que cualquier contenido previo se perderá. No es necesario formatearla manualmente antes.

---

## 4. Flashear la imagen con Raspberry Pi Imager

Lanzar Raspberry Pi Imager (`rpi-imager` en Linux). El flujo es siempre el mismo:

### 4.1. Elegir dispositivo

- Botón **CHOOSE DEVICE** → seleccionar **Raspberry Pi 5**.

### 4.2. Elegir sistema operativo

- Botón **CHOOSE OS** → **Raspberry Pi OS (other)** → **Raspberry Pi OS Lite (64-bit)**.

Es el "Lite" (sin escritorio) **64-bit**. No usar:

- "Raspberry Pi OS (64-bit)" (con escritorio): innecesario y consume RAM.
- "Raspberry Pi OS Lite (32-bit)" (`armhf`): incompatible con varias imágenes Docker del homelab.

### 4.3. Elegir almacenamiento

- Botón **CHOOSE STORAGE** → seleccionar **la microSD**, no un disco interno del PC. Verificar tamaño y nombre con cuidado.

### 4.4. Personalización avanzada (OS customisation)

Tras pulsar **NEXT**, Imager pregunta si se quiere aplicar **OS customisation** / **EDIT SETTINGS**. Decir **SÍ / EDIT SETTINGS**. En la ventana resultante hay tres pestañas: **General**, **Services** y **Options**.

#### 4.4.1. Pestaña *General*

- **Set hostname**: marcar y poner `homelab` → la Pi se anunciará como `homelab` en la LAN (mDNS publica `homelab.local`).
- **Set username and password**:
    - Username: `homelab` (no `pi`).
    - Password: una contraseña fuerte. **Solo se usa como recovery** (consola física); el acceso normal será por clave SSH.
- **Configure wireless LAN** *(opcional, recomendado como fallback)*:
    - SSID y contraseña del WiFi doméstico.
    - **Wireless LAN country**: `ES` (o el país correspondiente). Si no se indica, el módulo WiFi queda en modo restringido y no asocia.
    - Justificación: la Pi opera por Ethernet, pero si el cable falla durante el bootstrap inicial, tener el WiFi preconfigurado evita tener que sacar la microSD y reflashearla.
- **Set locale settings**:
    - Time zone: `Europe/Madrid`.
    - Keyboard layout: `es`.

#### 4.4.2. Pestaña *Services*

- **Enable SSH**: marcar.
- Dentro, elegir **Allow public-key authentication only**.
- Pegar **íntegra** la clave pública del paso 1 (`ssh-ed25519 AAAAC3Nza... comentario`) en el cuadro de claves autorizadas.

> No marcar "Use password authentication" para SSH. El password sigue existiendo para la consola física, pero SSH solo aceptará la clave pública.

#### 4.4.3. Pestaña *Options*

Se pueden dejar los valores por defecto:

- *Play sound when finished*: opcional.
- *Eject media when finished*: marcado.
- *Enable telemetry*: a gusto del operador (no afecta al funcionamiento).

#### 4.4.4. Guardar la personalización

- **SAVE** → vuelta al diálogo principal de Imager → confirmar **YES, APPLY OS CUSTOMISATION SETTINGS**.

### 4.5. Escribir y verificar

- Imager pedirá confirmación final: **YES** para borrar la microSD y empezar.
- El proceso descarga la imagen oficial (si no está en caché), la escribe y luego **verifica** byte a byte. Tarda 5–15 minutos según red y velocidad de la microSD.
- Al terminar, Imager desmonta la microSD automáticamente.

> Si Imager reporta un error durante la verificación, **no** seguir adelante: la microSD puede tener celdas defectuosas. Repetir el flasheo; si sigue fallando, descartar la tarjeta.

---

## 5. Primer arranque de la Raspberry Pi

1. Extraer la microSD del lector e insertarla en el slot de la Pi 5.
2. Conectar el **cable Ethernet** entre la Pi y el router (puerto Gigabit).
3. **No conectar todavía** los discos `hd5t` y `hd2t`: se conectan en [`../00-hardware/03-preparacion-discos.md`](../00-hardware/03-preparacion-discos.md), después de que el sistema arranque limpio.
4. Conectar la **fuente oficial USB-C de 27 W**. La Pi arranca automáticamente.
5. Esperar **2–3 minutos**. El primer arranque hace expansión del filesystem, regenera claves de host SSH y aplica la personalización de Imager. El LED verde de actividad parpadeará durante el proceso y se quedará tranquilo cuando termine.

---

## 6. Localizar la IP de la Pi en la LAN

La Pi pide IP por DHCP al router. Hay varias formas de averiguarla; cualquiera vale.

### 6.1. Vía mDNS (rápido si funciona)

Desde el PC de administración:

```bash
ping -c 3 homelab.local
```

Si responde, esa es la IP. La mayoría de routers domésticos y sistemas operativos modernos soportan mDNS (`avahi`/Bonjour); si no, usar las opciones siguientes.

### 6.2. Vía panel del router

Entrar al panel de administración del router doméstico y buscar la lista de **clientes DHCP**. Aparecerá una entrada con hostname `homelab`. Apuntar la IP.

> Aprovechar este momento para **reservar la IP por DHCP** asociándola a la MAC de la Pi. Esto evita que cambie en el futuro y es prerrequisito para Pi-hole en macvlan (Fase 3) y para Tailscale subnet routing si se llegase a usar.

### 6.3. Vía escaneo de la LAN (fallback)

Si el router no permite ver clientes con detalle, escanear la subred desde el PC:

```bash
# Sustituir 192.168.1.0/24 por la subred local
nmap -sn 192.168.1.0/24
```

La Pi aparecerá con vendor *Raspberry Pi Trading* o similar.

---

## 7. Conectar por SSH

Desde el PC de administración, con la IP descubierta en el paso 6:

```bash
ssh homelab@<ip-de-la-pi>
```

- La primera vez SSH pedirá aceptar la **fingerprint** del servidor. Confirmar con `yes`.
- Si la clave SSH tiene passphrase, el `ssh-agent` (o el agente del sistema operativo) la pedirá una vez.
- **No** debería pedir password: la autenticación es por clave pública. Si pide password, revisar el paso 4.4.2.

Una vez dentro, **verificación rápida** del entorno:

```bash
uname -a                       # debe indicar aarch64
cat /etc/os-release            # debe mostrar Debian Bookworm / Raspberry Pi OS
hostnamectl                    # hostname=homelab, arquitectura arm64
ip -br addr                    # eth0 con IP en la LAN
df -hT /                       # raíz en la microSD, FS ext4
```

> Si `ssh` falla con `Permission denied (publickey)`, posibles causas: la clave pública pegada en Imager no era la correcta, el cliente está usando otra clave (`-i ~/.ssh/id_ed25519` para forzar), o el `ssh-agent` no la tiene cargada (`ssh-add ~/.ssh/id_ed25519`).

### 7.1. (Opcional) Alias en `~/.ssh/config`

Para no tener que recordar IP/usuario en lo sucesivo, añadir en el PC de administración a `~/.ssh/config`:

```sshconfig
Host homelab
    HostName <ip-de-la-pi>
    User homelab
    IdentityFile ~/.ssh/id_ed25519
    ServerAliveInterval 60
```

A partir de aquí basta con `ssh homelab` desde el PC.

---

## Lista de Verificación

Antes de pasar a [`02-configuracion-inicial.md`](./02-configuracion-inicial.md):

- [ ] Raspberry Pi Imager **≥ 1.8** instalado en el PC de administración.
- [ ] Existe `~/.ssh/id_ed25519.pub` (u otra clave) y se ha **pegado íntegra** en la pantalla de personalización de Imager.
- [ ] La microSD se ha flasheado con **Raspberry Pi OS Lite 64-bit** y la verificación de Imager terminó **sin errores**.
- [ ] La Pi arranca con la microSD insertada, los **dos LED** muestran actividad normal y se queda en reposo tras 2–3 minutos.
- [ ] La Pi aparece en el router con hostname `homelab` y se ha **anotado su IP**.
- [ ] (Opcional pero recomendado) La IP de la Pi está **reservada por DHCP** asociada a su MAC.
- [ ] `ssh homelab@<ip>` funciona **sin pedir password**, autenticando por clave pública.
- [ ] `uname -m` devuelve `aarch64` y `cat /etc/os-release` confirma Raspberry Pi OS / Debian Bookworm.
- [ ] El comando `hostnamectl` muestra `Static hostname: homelab` y `Operating System: Debian GNU/Linux 12 (bookworm)` (o versión actual).
- [ ] **No** se han conectado todavía los discos `hd5t` ni `hd2t` (se hace en la fase de preparación de discos, ya con el SO arrancando limpio).

---

## Solución de Problemas

| Síntoma | Causa probable | Acción |
|---|---|---|
| Imager no muestra la opción de personalización avanzada | Versión de Imager < 1.8. | Actualizar a la última versión desde la web oficial. |
| La Pi no arranca: solo LED rojo fijo, sin verde | Microsd mal grabada, mal insertada o defectuosa. | Reinsertar; si persiste, repetir el flasheo. Probar otra microSD si la verificación falla repetidamente. |
| LEDs parpadean en patrón anormal (4 verdes, 7 verdes, etc.) | Patrón de error de bootloader: la imagen no es compatible o falta algún archivo. | Confirmar que la imagen elegida es **Raspberry Pi OS Lite 64-bit** y reflashear. |
| La Pi no aparece en el router tras 5 minutos | Cable Ethernet, puerto del router o personalización no aplicada (DHCP request bloqueado). | Probar otro cable / puerto. Conectar un monitor por micro-HDMI para ver mensajes del kernel y el login local con el usuario y password configurados. |
| `ping homelab.local` no responde, pero la Pi sí está en el router | mDNS no funciona en la red (router con IGMP snooping agresivo, VLANs separadas). | Usar la IP directamente o instalar `avahi-daemon` si más adelante se necesita resolución `.local`. |
| `ssh homelab@<ip>` pide password en vez de aceptar la clave | La clave pública pegada en Imager no se aplicó, o se pegó incompleta. | En la consola local de la Pi, comprobar `~/.ssh/authorized_keys`. Reflashear si falta. |
| `Permission denied (publickey)` aunque la clave parece correcta | El cliente SSH usa otra identidad, o el `authorized_keys` tiene permisos erróneos. | `ssh -v -i ~/.ssh/id_ed25519 homelab@<ip>` para depurar. En la Pi: `chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys`. |
| `Host key verification failed` al reconectar tras un reflasheo | La clave de host cambió y el cliente recuerda la antigua. | `ssh-keygen -R <ip-de-la-pi>` y reintentar. |
| Caídas de red intermitentes durante el primer arranque | Fuente insuficiente o adaptador de red en estado no estable durante el bootstrap. | Confirmar fuente oficial 27 W. Esperar a que el primer arranque termine antes de cargar la red (los discos no deben estar enchufados aún para no consumir 5 V extra). |

---

## Referencias

- [Raspberry Pi OS — Documentation](https://www.raspberrypi.com/documentation/computers/os.html)
- [Raspberry Pi Imager — Página oficial](https://www.raspberrypi.com/software/)
- [Setting up a headless Raspberry Pi](https://www.raspberrypi.com/documentation/computers/getting-started.html#setting-up-your-raspberry-pi)
- [SSH key-based authentication — Raspberry Pi docs](https://www.raspberrypi.com/documentation/computers/remote-access.html#ssh)
- [`ssh-keygen(1)` — manual page](https://man7.org/linux/man-pages/man1/ssh-keygen.1.html)
- [Avahi / mDNS en Raspberry Pi OS](https://www.raspberrypi.com/documentation/computers/remote-access.html#resolving-raspberrypi-local-with-mdns)
