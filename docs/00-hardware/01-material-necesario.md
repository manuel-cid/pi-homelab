# Material Necesario

## Descripción

Inventario base para montar el homelab sobre una **Raspberry Pi 5 (8 GB)** con **SSD NVMe como almacenamiento principal** y dos discos duros externos conectados por USB. El objetivo de esta fase es comprar o validar todo el hardware antes de pasar a conexiones, preparación de discos y arranque desde NVMe.

Este documento cubre solo materiales y criterios de compra. La conexión física se documenta en [02-esquema-conexiones.md](02-esquema-conexiones.md), la preparación de discos en [03-preparacion-discos.md](03-preparacion-discos.md) y la migración de arranque al SSD en [05-arranque-nvme.md](05-arranque-nvme.md).

## Requisitos Previos

- Haber definido que el homelab funcionará en **LAN + Tailscale**, sin exposición directa a internet.
- Tener claro el reparto de almacenamiento:
  - **SSD NVMe 500 GB**: sistema operativo, Docker, configuraciones y datos persistentes de servicios.
  - **hd2t 2 TB**: multimedia general, descargas y backups.
  - **hd5t 5 TB**: biblioteca multimedia dedicada.
- Disponer de una toma de corriente estable y un punto de red Ethernet cerca del lugar de instalación.

## Lista de Materiales

| Elemento | Obligatorio | Especificación recomendada | Uso en el homelab | Precio orientativo |
|----------|-------------|----------------------------|-------------------|--------------------|
| Raspberry Pi 5 | Sí | **8 GB RAM** | Nodo principal del homelab | Variable según tienda y disponibilidad |
| Fuente de alimentación | Sí | **Oficial USB-C 27 W (5V/5A)** | Alimentación estable de la Pi 5 y periféricos | Variable según tienda y disponibilidad |
| microSD | Sí | **64 GB** | Arranque inicial e instalación base antes de migrar a NVMe | Variable según tienda y disponibilidad |
| Carcasa con M.2 NVMe | Sí | **Argon ONE V3 M.2 NVME PCIe** | Montaje físico, refrigeración y conexión PCIe al SSD | **55-65 EUR** |
| SSD NVMe M.2 | Sí | **500 GB, formato 2280, por ejemplo Kingston NV2** | Disco principal del sistema y datos persistentes de los servicios | **35-40 EUR** |
| Disco externo `hd2t` | Sí | **2 TB, USB 3.0** | Multimedia general, descargas y backups | Reutilizable o según tienda |
| Disco externo `hd5t` | Sí | **5 TB, USB 3.0** | Biblioteca multimedia dedicada | Reutilizable o según tienda |
| Cable de red | Sí | Ethernet Cat 5e o superior | Conexión estable al router/switch | Bajo coste |
| Adaptador Zigbee | Opcional | USB compatible con Zigbee2MQTT/Home Assistant, por ejemplo **SONOFF Zigbee 3.0 USB Dongle Plus** | Integración domótica futura | Según modelo |

## Selección Recomendada

### Componentes principales

- **Raspberry Pi 5 de 8 GB**: margen suficiente para Docker, monitorización, reverse proxy y varios servicios concurrentes.
- **Fuente oficial de 27 W**: no es un accesorio opcional cuando se usa NVMe. Es la opción segura para evitar inestabilidad, reinicios o problemas de alimentación bajo carga.
- **microSD de 64 GB**: se usa para el arranque inicial y como soporte temporal durante la instalación. No debe ser el almacenamiento operativo final del homelab.
- El acceso previsto es **solo LAN + Tailscale**, sin exposición directa a internet ni apertura de puertos en el router.

### Carcasa y almacenamiento NVMe

- La carcasa de referencia del proyecto es la **Argon ONE V3 M.2 NVME PCIe**, que integra refrigeración y el adaptador PCIe a NVMe en el mismo chasis.
- Evita confundir **NVMe** con **M.2 SATA**: el formato físico puede parecer similar, pero no son equivalentes.
- Si se evalúa una alternativa, debe ofrecer soporte explícito para **Raspberry Pi 5 + NVMe por PCIe** y no cambiar la arquitectura descrita en `SERVICES.md`.
- Para el SSD, un **NVMe M.2 de 500 GB en formato 2280** es suficiente para Raspberry Pi OS, Docker, volúmenes, bases de datos, logs y crecimiento razonable de servicios.
- Ejemplo válido: **Kingston NV2 500 GB**, aproximadamente **35-40 EUR**.

### Discos USB de datos

- **`hd2t` (2 TB)**: destinado a contenidos multimedia organizados por tipo, descargas y copias de seguridad locales.
- **`hd5t` (5 TB)**: reservado para una biblioteca multimedia dedicada, separando ese disco del resto del contenido.
- Si estos discos ya existen y contienen datos, no hace falta sustituirlos. Su incorporación sin formatear se documenta en [04-discos-con-datos.md](04-discos-con-datos.md).

## Presupuesto del Upgrade a NVMe

Si ya se dispone de Raspberry Pi 5, discos USB y cableado, el coste incremental típico para pasar a un arranque y operación sobre NVMe es:

| Concepto | Rango orientativo |
|----------|-------------------|
| Argon ONE V3 M.2 NVME PCIe | **55-65 EUR** |
| SSD NVMe M.2 500 GB | **35-40 EUR** |
| Total upgrade NVMe | **90-105 EUR** |

Los importes son orientativos y pueden variar según tienda, disponibilidad y modelo exacto del SSD.

## Criterios de Compra

- Prioriza **estabilidad eléctrica** antes que accesorios estéticos.
- Compra una carcasa que combine **disipación térmica** y soporte NVMe específico para Pi 5.
- Usa el **SSD NVMe** para todo lo operativo: sistema, Docker, configuraciones, bases de datos y volúmenes persistentes.
- Reserva los discos USB para **multimedia, descargas y backups**, manteniendo en el SSD todo lo operativo del homelab.
- Si el adaptador Zigbee no se va a usar al inicio, puede posponerse sin impacto en el resto de la instalación.

## Checklist de Compra

- [ ] Raspberry Pi 5 de 8 GB
- [ ] Fuente oficial USB-C de 27 W
- [ ] microSD de 64 GB
- [ ] Argon ONE V3 M.2 NVME PCIe
- [ ] SSD NVMe M.2 de 500 GB
- [ ] Disco USB `hd2t` de 2 TB
- [ ] Disco USB `hd5t` de 5 TB
- [ ] Cable Ethernet
- [ ] Adaptador Zigbee (solo si se va a desplegar domótica)

## Siguiente Paso

Con el material validado, el siguiente documento a completar o seguir es [02-esquema-conexiones.md](02-esquema-conexiones.md), donde se define cómo conectar físicamente la Pi, el NVMe, los discos USB, la red y el adaptador Zigbee.

## Referencias

- `plan/plan.md` → Fase 0 — Hardware y Preparación Física
- `SERVICES.md` → Recomendaciones de Hardware
- [02-esquema-conexiones.md](02-esquema-conexiones.md)
- [03-preparacion-discos.md](03-preparacion-discos.md)
- [04-discos-con-datos.md](04-discos-con-datos.md)
- [05-arranque-nvme.md](05-arranque-nvme.md)
