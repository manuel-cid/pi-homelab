# Instalación de Raspberry Pi OS

## Descripción

Procedimiento para instalar **Raspberry Pi OS Lite 64-bit** en una **microSD** usando **Raspberry Pi Imager**, dejando preparada una instalación inicial y totalmente headless para una **Raspberry Pi 5 (8 GB)**. El objetivo de este documento es cubrir el primer despliegue del sistema base con acceso por **SSH**, usuario administrativo definido desde el inicio y una red **WiFi de emergencia** como respaldo temporal si el enlace Ethernet no estuviera disponible.

Esta instalación en microSD es **provisional**. El estado final del homelab debe migrarse al **SSD NVMe** siguiendo [05-arranque-nvme.md](../00-hardware/05-arranque-nvme.md). La distribución prevista del almacenamiento se define en [03-preparacion-discos.md](../00-hardware/03-preparacion-discos.md).

Los valores escritos entre `<...>` en comandos y ejemplos son **placeholders** y deben sustituirse por los datos reales de tu entorno.

## Requisitos Previos

- Haber validado el hardware base descrito en [01-material-necesario.md](../00-hardware/01-material-necesario.md).
- Tener montada la Raspberry Pi 5 con su carcasa y el SSD NVMe según [02-esquema-conexiones.md](../00-hardware/02-esquema-conexiones.md), aunque el primer arranque todavía se haga desde microSD.
- Disponer de una **microSD** funcional, preferiblemente de **64 GB**.
- Tener un equipo adicional desde el que ejecutar **Raspberry Pi Imager**.
- Contar con conexión **Ethernet** disponible en el lugar de instalación. El WiFi configurado en este documento se considera solo una vía de emergencia.
- Haber decidido de antemano:
  - `hostname` del equipo
  - nombre del usuario administrador local
  - contraseña inicial
  - clave pública SSH, si se va a usar desde el primer arranque
  - SSID y contraseña del WiFi de respaldo

## Objetivo de esta Fase

Al terminar este documento, el estado esperado es este:

- La **microSD** contiene una instalación limpia de **Raspberry Pi OS Lite 64-bit**.
- La Raspberry Pi puede arrancar sin monitor ni teclado.
- El acceso remoto básico queda disponible por **SSH**.
- El usuario administrativo ya existe desde el primer arranque.
- El sistema tiene configurado **Ethernet** como vía principal y **WiFi** como respaldo temporal.
- La migración definitiva al **SSD NVMe** queda pendiente para [05-arranque-nvme.md](../00-hardware/05-arranque-nvme.md).

## Docker Compose

No aplica en esta fase. Aquí todavía no se instala Docker ni se despliegan servicios.

## Configuración

### 1. Instalar Raspberry Pi Imager

Descarga e instala **Raspberry Pi Imager** en tu equipo de trabajo. Esta herramienta permite escribir la imagen del sistema y dejar preparada la configuración headless antes del primer arranque real.

### 2. Insertar la microSD y validar el dispositivo correcto

Conecta la microSD al equipo desde el que vas a grabar la imagen y asegúrate de identificar correctamente la unidad antes de escribir nada sobre ella.

Si el sistema monta automáticamente la tarjeta o muestra contenido previo, no importa: Raspberry Pi Imager la sobrescribirá por completo.

### 3. Seleccionar dispositivo, sistema operativo y almacenamiento

En Raspberry Pi Imager selecciona:

1. `Raspberry Pi Device` → **Raspberry Pi 5**
2. `Operating System` → **Raspberry Pi OS Lite (64-bit)**
3. `Storage` → la **microSD** que acabas de insertar

Usa siempre la edición **Lite** para el homelab. Evita imágenes con entorno gráfico porque añaden paquetes, consumo de RAM y superficie de mantenimiento que aquí no aportan valor.

### 4. Abrir la configuración avanzada de Imager

Antes de pulsar `Write`, entra en el menú de personalización de Raspberry Pi Imager y deja definidos estos parámetros.

### Identidad del sistema

- `Set hostname`: usa el nombre definitivo que quieras para la Raspberry Pi en la red local.
- `Set username and password`: crea aquí el usuario administrativo inicial.

Ejemplo orientativo:

- `hostname`: `homelab-pi5`
- `username`: `<user>`

No es obligatorio usar esos nombres; son solo una referencia de formato.

### Acceso remoto

Activa `Enable SSH`.

Opciones recomendadas:

- Si ya tienes clave pública: habilita SSH con **public-key authentication**.
- Si todavía no la tienes preparada: habilita SSH con contraseña para el arranque inicial y sustitúyelo por claves en [03-seguridad-base.md](03-seguridad-base.md).

Si usas claves, pega la **clave pública** correcta en el campo correspondiente de Imager.

### Localización

Configura desde Imager:

- `Time zone`: la zona horaria real del homelab
- `Keyboard layout`: distribución de teclado que vayas a usar si en algún momento conectas teclado
- `Locale settings`: locale principal del sistema

Aunque más adelante se revisará la configuración inicial del sistema, conviene dejar estos valores bien puestos desde el principio para evitar primeras sesiones con hora o idioma inconsistentes.

### WiFi de emergencia

Activa la configuración inalámbrica solo como respaldo:

- `SSID`: red WiFi disponible en la ubicación del homelab
- `Password`: contraseña correspondiente
- `Wireless LAN country`: país correcto

### Criterio operativo

- La red principal del homelab debe ser **Ethernet**.
- El **WiFi** se deja configurado solo para contingencias, instalación inicial o recuperación rápida.
- Si el equipo va a estar siempre por cable y no quieres exponer una segunda vía de conectividad, el WiFi puede deshabilitarse más adelante.

### 5. Escribir la imagen en la microSD

Cuando la configuración esté lista, pulsa `Write` y espera a que termine el proceso completo de grabación y verificación.

Al finalizar, extrae la microSD de forma segura.

### 6. Primer arranque headless en la Raspberry Pi 5

Con la Raspberry Pi apagada:

1. Inserta la microSD recién preparada.
2. Conecta el cable Ethernet.
3. Deja conectado el SSD NVMe en la carcasa, pero sin intentar arrancar todavía desde él.
4. Conecta alimentación estable con la fuente oficial.
5. Espera entre uno y varios minutos para el primer arranque.

En este punto, la Raspberry Pi debería obtener IP por DHCP en la red local y aceptar conexiones SSH.

### 7. Descubrir la IP del equipo

Puedes localizar la Raspberry Pi por hostname o por DHCP desde el router. Si el nombre se resuelve por mDNS o DNS local, prueba:

```bash
ping <hostname>.local
ssh <user>@<hostname>.local
```

Si no resuelve por nombre, localiza la IP asignada y conecta por dirección:

```bash
ssh <user>@<ip-del-equipo>
```

La primera vez que conectes, acepta la huella del host si coincide con el equipo esperado.

### 8. Verificación mínima tras el primer acceso

Una vez dentro por SSH, valida lo básico:

```bash
hostnamectl
ip a
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE,LABEL
```

Comprueba especialmente:

- que el `hostname` sea el esperado
- que la interfaz de red principal tenga conectividad
- que la microSD sea el medio desde el que ha arrancado el sistema
- que el **SSD NVMe** aparezca detectado por el sistema

En esta fase todavía no hace falta migrar al NVMe ni preparar montajes definitivos. Eso se cubre más adelante.

### 9. Qué hacer justo después

El siguiente documento a ejecutar es [02-configuracion-inicial.md](02-configuracion-inicial.md), donde se realiza la actualización del sistema, ajustes regionales y configuración de memoria swap. La migración del arranque al SSD queda para [05-arranque-nvme.md](../00-hardware/05-arranque-nvme.md).

## Almacenamiento

Durante este documento, el reparto de discos debe entenderse así:

- **microSD**: solo medio temporal para el arranque inicial y la configuración base.
- **SSD NVMe**: destino definitivo del sistema operativo, Docker, configuraciones y datos persistentes tras la migración. La estructura operativa final vivirá bajo `/home/<user>/homelab/`.
- **`hd2t`**: multimedia general, descargas y backups, montado en `/media/hd2t`, según [03-preparacion-discos.md](../00-hardware/03-preparacion-discos.md).
- **`hd5t`**: biblioteca multimedia dedicada, montada en `/media/hd5t`, según [03-preparacion-discos.md](../00-hardware/03-preparacion-discos.md).

Consideraciones prácticas:

- No guardes datos definitivos del homelab en la microSD.
- No crees todavía la estructura final de trabajo en `/home/<user>/homelab/`; se documenta en [04-estructura-directorios.md](04-estructura-directorios.md).
- No despliegues todavía volúmenes persistentes de servicios en discos USB.
- No reformatees el NVMe en esta fase salvo que estés rehaciendo deliberadamente la instalación desde cero.

## Backup

En esta fase inicial todavía no existe un conjunto relevante de datos de aplicación que respaldar, pero sí conviene conservar:

- el `hostname`, usuario y red usados en Raspberry Pi Imager
- la clave pública SSH configurada
- cualquier contraseña inicial almacenada en tu gestor de secretos

Si necesitas rehacer la instalación, tener esos valores anotados permite reconstruir la microSD sin improvisar.

## Referencias

- Raspberry Pi Imager
- Raspberry Pi OS Lite (64-bit)
- [03-preparacion-discos.md](../00-hardware/03-preparacion-discos.md)
- [05-arranque-nvme.md](../00-hardware/05-arranque-nvme.md)
