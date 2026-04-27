# Instalación del Sistema Operativo

## Descripción

Procedimiento para grabar **Raspberry Pi OS Lite 64-bit** (Bookworm) en la microSD que arrancará la Raspberry Pi 5 del homelab y dejarla preparada para un primer arranque **headless** (sin monitor ni teclado), accesible inmediatamente por **SSH** sobre la LAN. Se hace con la herramienta oficial **Raspberry Pi Imager**, configurando en el mismo paso de grabación: hostname, usuario inicial, autorización por clave SSH, zona horaria, locale y, opcionalmente, una red WiFi **de emergencia** para el caso de que el cable Ethernet o el switch fallen durante la puesta en marcha.

> **Alcance**: este documento cubre **únicamente** el flasheo de la microSD y el primer login por SSH. El endurecimiento de SSH, la configuración del firewall, el cambio de password, la instalación de utilidades, etc., se hacen en `docs/01-sistema/02-configuracion-inicial.md` y `docs/01-sistema/03-seguridad-base.md`.

> **Recordatorio**: el homelab vive sólo en **LAN + Tailscale**. La WiFi configurada aquí es estrictamente un *fallback* de emergencia; en operación normal la Pi se conecta por Ethernet (ver `docs/00-hardware/02-esquema-conexiones.md`).

---

## Requisitos previos

- Material físico ya listado y comprobado en `docs/00-hardware/01-material-necesario.md`:
  - Raspberry Pi 5 (8 GB).
  - Fuente oficial 27 W USB-C.
  - **microSD de 64 GB clase A2** (mínimo 32 GB; A1/A2 mejora notablemente el rendimiento aleatorio del OS).
  - Lector de microSD (USB) en el equipo desde el que se va a grabar.
- Equipo de trabajo (PC/Mac/Linux) con acceso a internet para descargar Raspberry Pi Imager y la imagen.
- Acceso al **router doméstico** para localizar la IP que tomará la Pi por DHCP (o reservarla en el propio DHCP del router).
- Un par de claves **SSH** existente en el equipo de trabajo (`~/.ssh/id_ed25519` recomendada). Si no se dispone:

  ```bash
  ssh-keygen -t ed25519 -C "homelab-pi5"
  ```

  Conservar la clave privada protegida por passphrase y subir sólo la pública (`~/.ssh/id_ed25519.pub`) a la Pi.

> Si se reutiliza una microSD ya usada, conviene comprobar antes que no esté degradada (los fallos silenciosos de microSD son una de las causas más habituales de "homelabs raros"). Una verificación rápida con `f3` (Linux/macOS) o `H2testw` (Windows) detecta tarjetas falsificadas o dañadas.

---

## Elección de la imagen

Para esta Raspberry Pi 5 se usa **Raspberry Pi OS Lite (64-bit)**, basado en **Debian Bookworm**:

- **Lite**: sin escritorio gráfico. El homelab es headless y todos los servicios corren en Docker; un escritorio sólo añade superficie de ataque, RAM y desgaste de microSD.
- **64-bit**: la Pi 5 sólo se aprovecha entera con userland de 64 bits (mejor rendimiento, soporte oficial de Docker arm64, imágenes oficiales de la mayoría de servicios).
- **Bookworm**: usa `/boot/firmware/` (no `/boot/`), `NetworkManager` por defecto y systemd-networkd disponible. Estos detalles afectan a varios pasos posteriores (cmdline, WiFi, firewall) y conviene tenerlos presentes desde el principio.

No se utilizan imágenes "custom" (DietPi, Ubuntu Server, etc.) para mantener el soporte oficial y la compatibilidad con la documentación de la Raspberry Pi Foundation.

---

## Instalación de Raspberry Pi Imager

Raspberry Pi Imager es la forma soportada de grabar la microSD: descarga la imagen oficial firmada y, además, expone el panel de **configuración avanzada** (OS customisation) que permite hacer headless setup en el mismo paso de flash, sin necesidad de tocar manualmente `firstrun.sh`, `userconf.txt` o `wpa_supplicant.conf`.

Descargar de la web oficial (no de mirrors no verificados) según el sistema del equipo de trabajo:

- macOS: <https://downloads.raspberrypi.com/imager/imager_latest.dmg>
- Windows: <https://downloads.raspberrypi.com/imager/imager_latest.exe>
- Linux (Debian/Ubuntu):

  ```bash
  sudo apt update
  sudo apt install -y rpi-imager
  ```

  En distribuciones sin paquete oficial, usar el AppImage o `snap install rpi-imager`.

Lanzar Raspberry Pi Imager. Versión recomendada: **1.8 o superior** (las anteriores no exponen el panel de OS customisation con todas las opciones).

---

## Grabación de la microSD

### 1. Insertar la microSD en el lector USB del equipo de trabajo

Comprobar que aparece como dispositivo extraíble. **Cualquier dato previo se perderá**: si la tarjeta contenía un sistema anterior (incluido cualquier otro Raspberry Pi OS), respaldar antes lo que interese.

### 2. Seleccionar el dispositivo y la imagen

En la pantalla principal de Imager:

- **CHOOSE DEVICE** → `Raspberry Pi 5`. Esto filtra las imágenes compatibles y evita ofrecer arquitecturas que no encajan.
- **CHOOSE OS** → `Raspberry Pi OS (other)` → `Raspberry Pi OS Lite (64-bit)`.
- **CHOOSE STORAGE** → la microSD insertada. Verificar **dos veces** el tamaño y la letra/dispositivo: seleccionar el SSD principal del PC por error es una pérdida de datos garantizada.

### 3. Configurar el sistema operativo (OS customisation)

Pulsar **NEXT** y, cuando aparezca el aviso *"Would you like to apply OS customisation settings?"*, elegir **EDIT SETTINGS**.

Pestaña **GENERAL**:

- **Set hostname**: `homelab` (o el que se prefiera; coherente con el resto de docs). Este será el `hostname` por defecto y aparecerá en el shell, en MagicDNS de Tailscale, etc.
- **Set username and password**:
  - **Username**: `homelab` (evitar el histórico `pi`, que está en cualquier diccionario de fuerza bruta).
  - **Password**: temporal, sólo para el primer arranque y para `sudo`. Se cambiará y se desactivará el login por password en `docs/01-sistema/03-seguridad-base.md`.
- **Configure wireless LAN** *(opcional, sólo como red de emergencia)*:
  - **SSID** y **Password** de la red WiFi doméstica.
  - **Wireless LAN country**: el código ISO correspondiente (`ES`, `DE`, etc.). Sin esto la radio puede quedar deshabilitada por restricciones regulatorias.
  - Esta WiFi **no se usa** en operación normal; sirve únicamente para que la Pi siga siendo accesible si el switch o el cable Ethernet fallan durante la puesta en marcha. En `docs/01-sistema/02-configuracion-inicial.md` se describe cómo desactivarla más adelante si se desea.
- **Set locale settings**:
  - **Time zone**: `Europe/Madrid` (o la del usuario; debe ser la misma que se usará después en logs, cron, backups y certificados).
  - **Keyboard layout**: irrelevante en headless, pero conviene poner `es` (o el que corresponda) por si en algún momento se conecta un teclado físico.

Pestaña **SERVICES**:

- **Enable SSH**: activado.
- Modo **Allow public-key authentication only**: activado.
- En **Set authorized_keys for 'homelab'** pegar el contenido **íntegro** de la clave pública del equipo de trabajo (`~/.ssh/id_ed25519.pub`). Imager creará `/home/homelab/.ssh/authorized_keys` con permisos correctos en el primer arranque.

  > Aunque Imager también permite "Use password authentication", se elige **clave pública desde el primer minuto**: la Pi quedará en la LAN antes de poder endurecerla y un par de horas con SSH abierto a password es suficiente para que un dispositivo comprometido en la red empiece a probar contraseñas.

Pestaña **OPTIONS**:

- Marcar **Eject media when finished** para evitar tirar de la microSD con escrituras pendientes.
- Marcar **Enable telemetry** según preferencia (no afecta a la Pi, sólo envía estadísticas anónimas al fabricante de Imager).

Pulsar **SAVE**.

### 4. Aplicar la configuración y grabar

De vuelta en el diálogo *"Would you like to apply OS customisation settings?"*, elegir **YES** y luego **YES** al aviso de borrado.

Imager:

1. Descarga (si no está en caché) y verifica la imagen oficial.
2. Escribe la imagen en la microSD.
3. **Verifica** byte a byte la escritura (paso crítico: detecta microSD defectuosas antes de meterlas en producción).
4. Inyecta los ajustes de **OS customisation** en la partición `/boot/firmware/` (`firstrun.sh`, `cmdline.txt`, claves WiFi, hostname, usuario, claves SSH).

Al terminar, el lector se desmonta y la microSD ya es booteable.

> Si Imager devuelve error de verificación, la microSD probablemente esté degradada o sea falsificada. **No** reutilizarla: provocará corrupciones intermitentes en la Pi semanas después.

---

## Primer arranque y acceso por SSH

### 1. Insertar la microSD en la Pi

Con la Pi **desconectada de la corriente**:

- Insertar la microSD en el slot inferior.
- Conectar el cable Ethernet al router (ver `docs/00-hardware/02-esquema-conexiones.md`, conexión #4).
- *No* conectar todavía los discos `hd5t` y `hd2t`. Se añadirán tras la fase 0 de preparación de discos para evitar que un error humano formatee la microSD por confundir dispositivos.
- Conectar la fuente oficial 27 W.

El LED verde de actividad parpadeará durante varios minutos: en el primer boot Imager ejecuta `firstrun.sh`, que aplica usuario, hostname, WiFi y claves SSH, y luego reinicia. Esperar **2–3 minutos** antes de intentar conectarse.

### 2. Localizar la IP de la Pi

La Pi solicita IP por DHCP. Para encontrarla, en orden de preferencia:

1. **Panel del router** → tabla DHCP → buscar el cliente con hostname `homelab`. Aprovechar para **reservar** esa IP en el DHCP (asignar siempre la misma a la MAC de la Pi). Esto evita romper certificados, montajes y configuraciones de Caddy/Pi-hole cuando el lease expira.
2. **mDNS** (Avahi, activo por defecto en Raspberry Pi OS):

   ```bash
   ping -c 3 homelab.local
   ssh homelab@homelab.local
   ```

   Funciona en macOS y Linux con Avahi/mDNS. En Windows requiere Bonjour. **No** se usará `homelab.local` como nombre definitivo en producción (ese papel es para Pi-hole + DNS local en `docs/03-red/02-pihole.md`); aquí sólo es una conveniencia para el primer login.
3. **Escaneo de la LAN** (último recurso):

   ```bash
   nmap -sn 192.168.1.0/24 | grep -B 2 -i raspberry
   ```

### 3. Primer login por SSH

Desde el equipo de trabajo:

```bash
ssh homelab@<IP_de_la_Pi>
# o
ssh homelab@homelab.local
```

En la primera conexión, `ssh` mostrará la *fingerprint* del host. **Anotarla**: si en una conexión futura cambia sin haber reinstalado la Pi, debe sospecharse MITM. Aceptar y entrar.

Si todo está bien:

```bash
homelab@homelab:~ $ uname -a
Linux homelab 6.6.x ... aarch64 GNU/Linux

homelab@homelab:~ $ cat /etc/os-release
PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"
...
```

> Si SSH **rechaza** la conexión con `Permission denied (publickey)` y se había configurado clave pública: la clave pegada en Imager probablemente tenía un salto de línea o caracteres extra. Saltar a "Troubleshooting" más abajo.

### 4. Comprobaciones rápidas

Antes de seguir, verificar el estado mínimo del sistema:

```bash
# Identidad y kernel
hostnamectl

# Memoria (debe rondar los 8 GB en Pi 5 8 GB)
free -h

# Almacenamiento (de momento sólo la microSD)
lsblk
df -hT /

# Red
ip -br addr
ip route

# Temperatura y voltaje (sanity check de alimentación)
vcgencmd measure_temp
vcgencmd get_throttled
```

`vcgencmd get_throttled` debe devolver `throttled=0x0`. Cualquier otro valor en el primer arranque casi siempre significa **fuente o cable USB-C insuficientes**: revisar `docs/00-hardware/02-esquema-conexiones.md`.

---

## WiFi de emergencia: comprobación

Si se configuró WiFi en Imager, conviene validar que **funciona** en cuanto la Pi está accesible por Ethernet, para tenerla como red de respaldo real (no descubrir en una caída del switch que la WiFi nunca llegó a asociarse).

```bash
# Estado de NetworkManager (Bookworm)
nmcli device status
nmcli connection show

# Forzar listado de redes WiFi para confirmar que la radio está activa
nmcli device wifi list
```

Salida esperada:

```
DEVICE   TYPE      STATE                   CONNECTION
eth0     ethernet  connected               Wired connection 1
wlan0    wifi      connected               preconfigured
lo       loopback  unmanaged               --
```

Tanto `eth0` como `wlan0` deben aparecer **conectados** (la Pi tendrá dos IPs simultáneamente, pero Ethernet tiene prioridad). Si `wlan0` aparece como `disconnected` o `unavailable`, revisar país WiFi:

```bash
sudo raspi-config nonint do_wifi_country ES
```

> En operación normal todos los servicios se anuncian sólo por la IP de Ethernet. La WiFi se mantiene como red secundaria pasiva: si Ethernet cae, sigue siendo posible entrar por SSH a través de WiFi para diagnosticar.

---

## Verificación final

Antes de pasar a `docs/01-sistema/02-configuracion-inicial.md`:

- [ ] La Pi arranca con `Raspberry Pi OS Lite 64-bit (Bookworm)` (`cat /etc/os-release`).
- [ ] Hostname configurado correctamente (`hostnamectl` muestra `homelab` o el elegido).
- [ ] SSH accesible **por clave pública** desde el equipo de trabajo (`ssh homelab@<IP>` entra sin pedir password).
- [ ] La IP de la Pi está **reservada** en el DHCP del router por MAC.
- [ ] `vcgencmd get_throttled` devuelve `0x0`.
- [ ] WiFi de emergencia, si se configuró, asociada correctamente (`nmcli device status`).
- [ ] Discos `hd5t` y `hd2t` **aún no conectados** (se añadirán en `docs/00-hardware/03-preparacion-discos.md` con la Pi ya endurecida).

---

## Troubleshooting

### La Pi no aparece en el router tras 5 minutos

- Comprobar el LED verde: si parpadea con patrón irregular durante el primer arranque es normal (Imager está aplicando `firstrun.sh`). Si está apagado o fijo desde el principio, la microSD no es booteable: **regrabarla**.
- Comprobar el LED de actividad del puerto del router (link Ethernet). Si no enciende, probar otro cable y otro puerto del router.
- Conectar HDMI + teclado para ver el log de boot. Errores frecuentes: `firstrun.sh` falla por hostname con caracteres no válidos, password con comillas mal escapadas, o clave SSH cortada por un copy-paste defectuoso.

### `Permission denied (publickey)` al hacer SSH

La clave pública pegada en Imager se ha guardado mal. Soluciones:

1. **Regrabar** la microSD desde Imager con la clave correcta (la opción más limpia y rápida).
2. O bien, montar temporalmente la partición `bootfs` de la microSD en otro equipo y editar `firstrun.sh` para corregir el `authorized_keys`.

Verificar siempre que la clave pegada **no contiene saltos de línea** ni espacios extra y que es la **pública** (`.pub`), no la privada.

### `ssh: Host key verification failed`

La fingerprint del host SSH ha cambiado (típico al regrabar la Pi). Eliminar la entrada anterior y reconectar:

```bash
ssh-keygen -R <IP_de_la_Pi>
ssh-keygen -R homelab.local
ssh homelab@<IP_de_la_Pi>
```

### `vcgencmd get_throttled` distinto de `0x0`

Cualquier bit a 1 indica problemas de **alimentación o temperatura**:

- `0x50000` / `0x50005` (under-voltage actual o pasado) → fuente o cable USB-C insuficientes. Cambiar a la fuente oficial 27 W de la Raspberry Pi y un cable USB-C de calidad.
- Bits de *throttling* térmico → ventilador desconectado o mal pegado al SoC. Revisar `docs/00-hardware/02-esquema-conexiones.md`.

### `homelab.local` no resuelve desde Windows

Windows no resuelve mDNS por defecto fuera de impresoras. Soluciones:

- Instalar **Bonjour Print Services** (Apple) o **iTunes**, que registran el resolver mDNS.
- Conectarse directamente por IP localizada en el router.

### La microSD se corrompe al cabo de unos días

Síntoma: errores `EXT4-fs error` en `dmesg`, sistema que entra en modo *read-only*, o re-arranques aleatorios. Causas:

- microSD falsificada o de baja calidad → reemplazar por una clase A2 de fabricante reconocido (SanDisk High Endurance, Samsung Pro Endurance).
- Apagones bruscos por desconexión del cable de alimentación → siempre apagar con `sudo poweroff` antes de tirar del cable.
- Escritura intensiva (logs, bases de datos) en la microSD → mover toda esa carga a `hd2t` (este es precisamente el motivo de los pasos siguientes en la fase 1).

---

## Referencias

- Raspberry Pi OS — Documentación oficial: <https://www.raspberrypi.com/documentation/computers/os.html>
- Raspberry Pi Imager — Repositorio y guía: <https://github.com/raspberrypi/rpi-imager>
- Raspberry Pi OS — Configuración headless con Imager: <https://www.raspberrypi.com/documentation/computers/getting-started.html#advanced-options>
- Configuración SSH en Raspberry Pi OS: <https://www.raspberrypi.com/documentation/computers/remote-access.html#ssh>
- NetworkManager en Raspberry Pi OS Bookworm: <https://www.raspberrypi.com/documentation/computers/configuration.html#configuring-networking>
- Imágenes Raspberry Pi OS (descargas y *checksums*): <https://www.raspberrypi.com/software/operating-systems/>
- Raspberry Pi 5 — Datos eléctricos y `vcgencmd`: <https://www.raspberrypi.com/documentation/computers/raspberry-pi-5.html>
