# Esquema de Conexiones

## Descripción

Mapa físico de conexiones para montar la **Raspberry Pi 5 (8 GB)** con **arranque y operación sobre SSD NVMe**, dos discos USB de datos, red por Ethernet y adaptador Zigbee opcional. El objetivo es dejar claro qué se conecta a cada interfaz antes de pasar al particionado de discos y a la migración de arranque.

Este documento asume el material descrito en [01-material-necesario.md](01-material-necesario.md). La preparación de discos se documenta en [03-preparacion-discos.md](03-preparacion-discos.md), la incorporación de discos con datos previos en [04-discos-con-datos.md](04-discos-con-datos.md) y el arranque desde NVMe en [05-arranque-nvme.md](05-arranque-nvme.md).

## Requisitos Previos

- Disponer de todo el hardware validado en [01-material-necesario.md](01-material-necesario.md).
- Tener claro el reparto de almacenamiento:
  - **SSD NVMe**: sistema operativo, Docker, configuraciones y datos persistentes de servicios.
  - **`hd2t`**: multimedia general, descargas y backups.
  - **`hd5t`**: biblioteca multimedia dedicada.
- Ubicar la Raspberry Pi cerca del router o switch para usar **Ethernet Gigabit**.
- Reservar una toma de corriente estable para la **fuente oficial USB-C de 27 W**.

## Diagrama General

```text
                           ┌─────────────────────┐
                           │ Router / Switch LAN │
                           └──────────┬──────────┘
                                      │ Ethernet
                                      │
                    USB 3.0           │                 USB
   ┌──────────────┐  blue   ┌─────────▼─────────┐   optional
   │ hd2t (2 TB)  ├─────────┤                   ├──────────────┐
   │ multimedia   │         │   Raspberry Pi 5  │              │
   │ + backups    │         │   en carcasa      │              │
   └──────────────┘         │   con M.2 NVMe    │              │
                            │                   │              │
   ┌──────────────┐  USB 3.0│                   │      ┌───────▼────────┐
   │ hd5t (5 TB)  ├─────────┤                   │      │ Adaptador      │
   │ biblioteca   │         └─────────┬─────────┘      │ Zigbee USB      │
   └──────────────┘                   │                └────────────────┘
                                      │ PCIe interno en la carcasa
                             ┌────────▼────────┐
                             │ SSD NVMe 500 GB │
                             │ SO + Docker     │
                             │ + datos         │
                             └─────────────────┘

                         Alimentación:
                         Fuente oficial USB-C 27 W -> Raspberry Pi 5
```

## Mapa de Conexiones

| Componente | Puerto o bus | Conexión física | Función |
|------------|--------------|-----------------|---------|
| SSD NVMe M.2 500 GB | PCIe interno de la carcasa | Montado dentro de la carcasa compatible | Disco principal del sistema, Docker y datos persistentes |
| Disco `hd2t` | USB 3.0 | Cable USB al puerto azul de la Pi | Multimedia general, descargas y backups |
| Disco `hd5t` | USB 3.0 | Cable USB al otro puerto azul de la Pi | Biblioteca multimedia dedicada |
| Router o switch | Ethernet RJ45 Gigabit | Cable Ethernet desde la Pi | Red local estable, acceso LAN y Tailscale |
| Adaptador Zigbee | USB 2.0 o USB con alargador | Directo o mediante extensión corta | Domótica futura con Zigbee2MQTT/Home Assistant |
| Fuente oficial 27 W | USB-C alimentación | Directo a la Pi | Alimentación estable del conjunto |

## Distribución Recomendada de Puertos

### Almacenamiento

- Conecta **`hd2t`** y **`hd5t`** a los **puertos USB 3.0** de la Raspberry Pi 5.
- Mantén el **SSD NVMe** en la interfaz **PCIe interna de la carcasa**, no por USB.
- Evita conectar discos mecánicos a puertos USB 2.0 salvo pruebas puntuales.

### Red

- Usa **Ethernet** como conexión principal del homelab.
- No plantees despliegue principal por Wi-Fi si el equipo va a alojar servicios de forma continua.
- El alcance previsto es **LAN + Tailscale**; no hay puertos abiertos a internet ni dependencia de acceso externo directo desde el router.

### Zigbee

- Si se instala adaptador Zigbee, prioriza un **puerto USB 2.0** si queda disponible o un **alargador USB corto** para separarlo físicamente de discos, carcasa metálica y cables de alimentación.
- Si no se va a desplegar domótica desde el inicio, el adaptador puede dejarse desconectado.

## Secuencia Recomendada de Montaje

1. Montar el **SSD NVMe** dentro de la carcasa compatible con Raspberry Pi 5.
2. Cerrar la carcasa y verificar que el conjunto PCIe/NVMe queda bien fijado.
3. Conectar la Raspberry Pi al **router o switch** mediante Ethernet.
4. Conectar los discos **`hd2t`** y **`hd5t`** a los puertos **USB 3.0**.
5. Conectar el adaptador Zigbee solo si se va a usar en esta fase.
6. Conectar la **fuente oficial USB-C de 27 W** al final.

### Scripts de la carcasa (si aplica)

Si la carcasa es una **Argon ONE V3** (o cualquier modelo Argon con ventilador activo y botón de encendido inteligente), sigue el manual del fabricante para instalar los scripts **antes de pasar a la preparación de discos**. Estos scripts suelen habilitar:

- **Control del ventilador por temperatura**: sin ellos, el ventilador puede quedarse apagado o funcionar a máxima velocidad permanentemente.
- **Botón de power inteligente**: doble pulsación para reiniciar, pulsación larga para apagado limpio.
- Ajustes específicos del fabricante para la carcasa y su placa PCIe.

<!-- TODO: verificar si el fabricante de la carcasa elegida requiere algún ajuste adicional en Raspberry Pi 5 para alimentación USB o gestión del NVMe; no asumir opciones heredadas de modelos anteriores. -->

Si usas una carcasa pasiva como la **Argon NEO 5 M.2 NVME**, este paso no aplica.

## Orden Lógico de Uso de Discos

| Disco | Montaje esperado | Uso previsto |
|-------|------------------|--------------|
| SSD NVMe | Sistema principal | Raspberry Pi OS, Docker Engine, `docker compose`, configuraciones, bases de datos, volúmenes persistentes y logs |
| `hd2t` | Disco de datos secundario | Multimedia general (vídeo, música, audiolibros, ebooks), descargas y backups |
| `hd5t` | Disco de datos dedicado | Biblioteca multimedia dedicada |

Esta separación evita cargar los discos USB con I/O operativo del sistema y reduce el impacto de picos de lectura/escritura multimedia sobre el host.

## Verificación Física Inicial

- La carcasa cierra correctamente y el SSD NVMe queda detectado mecánicamente como instalado.
- Los dos discos USB encienden o vibran de forma normal al alimentar la Pi.
- El enlace Ethernet queda activo en el router o switch.
- La fuente usada es la **oficial de 27 W**, no un cargador USB-C genérico.
- No hay tensión excesiva en conectores, adaptadores o cables USB.

## Errores Comunes a Evitar

- Alimentar la Raspberry Pi 5 con una fuente insuficiente cuando hay **NVMe + dos discos USB** conectados.
- Conectar un disco de datos a USB 2.0 y asumir el mismo rendimiento que en USB 3.0.
- Tratar el SSD NVMe como disco de multimedia masiva en lugar de reservarlo para sistema y datos persistentes de servicios.
- Montar los dos discos USB sin etiquetarlos después; en la siguiente fase deben quedar identificados como **`hd2t`** y **`hd5t`**.
- Dejar el montaje por Wi-Fi como solución permanente cuando el equipo está pensado para servicio continuo.

## Notas de Estabilidad

- Si alguno de los discos USB se desconecta bajo carga, revisa primero la alimentación y el cableado antes de asumir un problema de software.
- Si los discos externos son especialmente exigentes o usan carcasas inestables, conviene que dispongan de alimentación propia o que se use una solución USB estable y bien alimentada.
- Antes de configurar `fstab`, conviene verificar en la siguiente fase qué nombre de dispositivo, UUID y sistema de archivos corresponde a cada unidad.

## Siguiente Paso

Con el esquema físico ya definido, el siguiente documento a completar o seguir es [03-preparacion-discos.md](03-preparacion-discos.md), donde se documentan particionado, formato, etiquetas, montaje automático y estrategia de uso de cada disco.

Si los discos USB ya contienen datos y no deben formatearse, salta a [04-discos-con-datos.md](04-discos-con-datos.md).

## Referencias

- Raspberry Pi 5
- Fuente oficial Raspberry Pi USB-C 27 W
- Carcasa para Raspberry Pi 5 con soporte M.2 NVMe
- SSD NVMe M.2 500 GB
