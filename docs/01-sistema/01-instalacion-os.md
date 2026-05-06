# Instalación de Raspberry Pi OS

## Descripción
Procedimiento para grabar **Raspberry Pi OS Lite 64-bit** en una **microSD** con **Raspberry Pi Imager**, dejar preparada una configuración **headless** desde el primer arranque y validar el sistema base antes de migrarlo más adelante al **SSD NVMe**.

En este homelab la microSD se usa solo como medio de arranque inicial. El objetivo final no es operar permanentemente desde ella, sino arrancar una vez, completar la configuración mínima y después mover el sistema al NVMe siguiendo `docs/00-hardware/05-arranque-nvme.md`.

## Requisitos Previos
- Haber revisado `docs/00-hardware/01-material-necesario.md`.
- Tener montada la Raspberry Pi 5 con su carcasa, fuente y SSD NVMe según `docs/00-hardware/02-esquema-conexiones.md`.
- Disponer de una microSD funcional, preferiblemente de al menos 16 GB, que se usará solo para la instalación inicial.
- Tener un ordenador desde el que ejecutar Raspberry Pi Imager.
- Tener a mano:
  - nombre de host deseado, por ejemplo `rpi5-homelab`
  - nombre del usuario administrador que se usará en todo el homelab
  - contraseña inicial robusta
  - clave pública SSH, si ya existe
  - datos de una red WiFi de emergencia, solo como respaldo si no hay Ethernet
- Conexión por Ethernet recomendada para el primer arranque y la administración inicial.
- Puertos implicados:
  - `22/tcp` para administración SSH dentro de la LAN o por Tailscale cuando se configure más adelante
  - no se expone ningún puerto a internet en esta fase

## Docker Compose
No aplica en esta fase. Aquí solo se prepara el sistema operativo base sobre el que después se instalarán Docker y el resto de servicios.

## Configuración

### Objetivo de esta fase

| Elemento | Estado esperado al terminar este documento |
|---|---|
| Medio de arranque activo | microSD |
| Sistema instalado | Raspberry Pi OS Lite 64-bit |
| Acceso remoto | SSH habilitado |
| Usuario administrador | creado desde Raspberry Pi Imager |
| Red principal | Ethernet |
| Red secundaria | WiFi de emergencia configurada pero no imprescindible |
| SSD NVMe | conectado y reservado para la migración posterior |

### Estrategia recomendada

El flujo recomendado es este:

1. Grabar Raspberry Pi OS Lite 64-bit en la microSD con Raspberry Pi Imager.
2. Preconfigurar desde Imager el acceso headless: usuario, contraseña, SSH, hostname y WiFi de emergencia.
3. Arrancar la Raspberry Pi por primera vez desde microSD.
4. Confirmar conectividad, acceso por SSH y visibilidad del SSD NVMe.
5. Dejar la microSD como arranque temporal hasta ejecutar `docs/00-hardware/05-arranque-nvme.md`.

Decisiones prácticas para esta instalación:

- Mantener el sistema lo más limpio posible. No instalar todavía Docker ni servicios de aplicación.
- Preferir Ethernet como conectividad principal aunque el WiFi quede configurado.
- No usar la microSD como almacenamiento definitivo del homelab.
- Si `hd2t` y `hd5t` ya están conectados, no montarlos ni prepararlos todavía en esta fase.

### 1. Grabar Raspberry Pi OS Lite 64-bit en la microSD

Abrir **Raspberry Pi Imager** en el ordenador desde el que vayas a preparar la tarjeta.

Selección recomendada:

1. `Raspberry Pi Device` → `Raspberry Pi 5`
2. `Operating System` → `Raspberry Pi OS (other)` → `Raspberry Pi OS Lite (64-bit)`
3. `Storage` → seleccionar la microSD correcta

Antes de grabar, abrir la personalización del sistema con el icono del engranaje o el diálogo de opciones avanzadas que muestra Imager.

### 2. Configurar las opciones avanzadas de Raspberry Pi Imager

Ajustes recomendados dentro de Imager:

- Establecer hostname, por ejemplo `rpi5-homelab`
- Habilitar SSH
- Elegir autenticación por clave pública SSH si ya dispones de ella
- Crear el usuario administrador que usarás después en `/home/<usuario>/homelab`
- Definir una contraseña inicial robusta
- Configurar zona horaria y distribución de teclado correctas
- Configurar una WiFi de emergencia solo como acceso alternativo
- Mantener deshabilitadas opciones innecesarias de telemetría o configuración experimental

Recomendación operativa:

- Si tienes clave pública SSH, úsala ya en esta fase y evita depender de contraseña más tiempo del necesario.
- Si no tienes clave todavía, puedes habilitar SSH con contraseña para el primer acceso y endurecerlo más adelante en `docs/01-sistema/03-seguridad-base.md`.
- La WiFi de emergencia debe tratarse como respaldo operativo. Si el host va a vivir siempre por cable, no la uses como vía principal de administración.

Ejemplo de valores que conviene decidir antes de grabar:

| Campo | Ejemplo |
|---|---|
| Hostname | `rpi5-homelab` |
| Usuario | `<usuario>` |
| Método SSH preferido | clave pública |
| WiFi de emergencia | `<SSID_EMERGENCIA>` |
| País WiFi | `ES` |
| Zona horaria | `Europe/Madrid` |

Una vez revisadas las opciones, grabar la imagen en la microSD y esperar a que Imager verifique la escritura.

### 3. Preparar el primer arranque

Con la microSD ya grabada:

1. Insertar la microSD en la Raspberry Pi 5.
2. Conectar el SSD NVMe en la carcasa M.2.
3. Conectar monitor y teclado solo si quieres una validación local; para un flujo headless no son necesarios.
4. Conectar Ethernet si está disponible.
5. Conectar alimentación y esperar unos minutos al primer arranque.

Notas:

- Aunque el NVMe ya esté conectado, en esta fase el sistema sigue arrancando desde la microSD.
- Es normal que el primer arranque tarde algo más mientras se completa la configuración inicial.

### 4. Localizar la Raspberry Pi en la red

Si usas Ethernet con DHCP, localizar la IP desde el router o con alguna de estas opciones desde otro equipo de la LAN:

```bash
ping rpi5-homelab.local
ssh <usuario>@rpi5-homelab.local
```

Si mDNS no resuelve correctamente, buscar la IP asignada por DHCP y conectar por dirección directa:

```bash
ssh <usuario>@192.168.1.50
```

Si Ethernet no está disponible y la WiFi de emergencia quedó bien configurada en Imager, la Pi debería asociarse a esa red durante el arranque.

### 5. Validar el acceso headless

Tras entrar por SSH, comprobar identidad básica del sistema:

```bash
hostnamectl
cat /etc/os-release
whoami
ip -brief address
```

Comprobar también los discos detectados:

```bash
lsblk -o NAME,PATH,SIZE,FSTYPE,LABEL,MOUNTPOINT
```

Resultado esperado en esta fase:

- el sistema responde por SSH
- el hostname coincide con el configurado en Imager
- el usuario administrador existe y puede usar `sudo`
- la raíz del sistema sigue estando en la microSD
- el SSD NVMe aparece detectado, normalmente como `/dev/nvme0n1`

Verificación rápida del medio de arranque actual:

```bash
findmnt /
findmnt /boot/firmware
```

En este momento ambas rutas deben corresponder al sistema instalado en la microSD. Eso es correcto y esperado.

### 6. Comprobar privilegios y estado mínimo del host

Validar que el usuario creado en Imager puede elevar privilegios:

```bash
sudo -v
```

Confirmar fecha y zona horaria aproximadas:

```bash
timedatectl
```

Recomendación práctica:

- Si algo falla en esta validación inicial, corrígelo ahora antes de migrar al NVMe.
- No avances a instalación de Docker ni a montaje de discos externos hasta tener un primer arranque limpio y estable.

### 7. Qué queda pendiente tras este documento

Este documento deja el sistema base instalado y accesible, pero todavía faltan varias tareas de la Fase 1:

1. Migrar el arranque del host al SSD NVMe según `docs/00-hardware/05-arranque-nvme.md`.
2. Hacer la configuración inicial del sistema en `docs/01-sistema/02-configuracion-inicial.md`.
3. Aplicar el endurecimiento básico del host en `docs/01-sistema/03-seguridad-base.md`.
4. Definir la estructura final de directorios y montajes persistentes en `docs/01-sistema/04-estructura-directorios.md`.

Orden recomendado:

- primero instalar y validar en microSD
- después migrar al NVMe
- luego continuar con configuración inicial, seguridad y estructura de almacenamiento

## Almacenamiento

### Estado esperado tras completar este documento

| Ruta o medio | Dispositivo esperado | Uso |
|---|---|---|
| `/` | microSD | arranque temporal del sistema |
| `/boot/firmware` | microSD partición de arranque | archivos de arranque iniciales |
| SSD NVMe | visible pero todavía no usado como raíz | destino de migración posterior |
| `/home/<usuario>` | microSD | home temporal hasta migrar a NVMe |
| `hd2t` | no configurado aún | se documentará en fases posteriores |
| `hd5t` | no configurado aún | se documentará en fases posteriores |

### Decisiones de diseño

- La microSD existe solo para simplificar la instalación inicial y disponer de una vía de recuperación.
- El SSD NVMe será el almacenamiento principal del sistema operativo, Docker, configuraciones y datos persistentes, pero todavía no se usa como disco raíz en este documento.
- Los discos `hd2t` y `hd5t` no forman parte del arranque del host y no deben interferir en esta fase inicial.
- Ningún dato persistente del homelab debe diseñarse pensando en quedarse en la microSD más allá de esta fase.

## Backup
- Conservar una copia de los valores elegidos en Raspberry Pi Imager:
  - hostname
  - usuario administrador
  - método de autenticación SSH
  - SSID y país de la WiFi de emergencia
- Si preparas varias tarjetas o repites la instalación, documentar qué microSD corresponde a cada intento evita confusiones durante la migración al NVMe.
- Mantener la microSD intacta hasta completar `docs/00-hardware/05-arranque-nvme.md` y verificar que la Raspberry Pi arranca sin ella.
- Guardar como inventario inicial la salida de:
  - `hostnamectl`
  - `ip -brief address`
  - `lsblk -o NAME,PATH,SIZE,FSTYPE,LABEL,MOUNTPOINT`
  - `findmnt /`
  - `findmnt /boot/firmware`

## Referencias
- `SERVICES.md`
- `docs/00-hardware/01-material-necesario.md`
- `docs/00-hardware/02-esquema-conexiones.md`
- `docs/00-hardware/05-arranque-nvme.md`
- `docs/01-sistema/02-configuracion-inicial.md`
- `docs/01-sistema/03-seguridad-base.md`
- `docs/01-sistema/04-estructura-directorios.md`
- Raspberry Pi OS Lite 64-bit
- Raspberry Pi Imager
- SSH
- `hostnamectl`
- `lsblk`
- `findmnt`
