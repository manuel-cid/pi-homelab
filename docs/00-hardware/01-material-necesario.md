# Material Necesario

## Descripción
Inventario base para montar el homelab sobre una Raspberry Pi 5 con sistema y almacenamiento principal en SSD NVMe, más dos discos externos USB para multimedia y copias de seguridad.

Este documento fija qué hardware hace falta, qué componentes son obligatorios y qué papel cumple cada uno dentro de la arquitectura definida en `SERVICES.md`. El montaje físico, la preparación de discos y la migración del arranque se documentan en `docs/00-hardware/02-esquema-conexiones.md`, `docs/00-hardware/03-preparacion-discos.md`, `docs/00-hardware/04-discos-con-datos.md` y `docs/00-hardware/05-arranque-nvme.md`.

El alcance de red del proyecto es **solo LAN + Tailscale**, así que no se contempla hardware adicional para exponer servicios a internet, abrir puertos en el router o montar una terminación TLS pública.

## Requisitos Previos
- Haber revisado `SERVICES.md` para entender el alcance del homelab y la distribución prevista del almacenamiento.
- Asumir que el acceso será solo por LAN y Tailscale; no hace falta equipamiento para exposición pública.
- Disponer de un puerto Ethernet libre en el router o switch principal.
- Disponer de dos puertos USB 3.0 libres para `hd2t` y `hd5t`.
- Reservar un puerto USB adicional si se va a usar adaptador Zigbee.
- Conexiones necesarias en hardware:
  - 1 puerto USB-C para alimentación.
  - 1 enlace Ethernet Gigabit.
  - 2 puertos USB 3.0 para discos externos.
  - 1 conexión PCIe interna de la carcasa para el SSD NVMe.

## Docker Compose
No aplica en esta fase. Aquí solo se define el hardware base sobre el que después se desplegarán los servicios.

## Configuración

### Material obligatorio

| Componente | Recomendación | Uso en el homelab | Precio aprox. |
|---|---|---|---|
| Raspberry Pi 5 | **8 GB de RAM** | Host principal para Docker, red y servicios | Variable |
| Fuente de alimentación | **Oficial USB-C 27 W (5V/5A)** | Alimentación estable, especialmente importante con NVMe y discos USB | Variable |
| MicroSD | **64 GB** | Solo para instalación y arranque inicial antes de migrar a NVMe | Variable |
| Carcasa con slot M.2 NVMe | **Carcasa cerrada** con soporte NVMe por PCIe | Chasis, refrigeración y conexión limpia del SSD | ~35-65 EUR |
| SSD NVMe M.2 | **500 GB** | Sistema operativo, Docker Engine, configuraciones y datos persistentes de servicios | ~35-40 EUR |
| Disco externo `hd2t` | **2 TB, USB 3.0** | Multimedia general, descargas y backups locales | Variable |
| Disco externo `hd5t` | **5 TB, USB 3.0** | Biblioteca multimedia dedicada a Stash | Variable |
| Cable Ethernet | Cat 5e o superior | Conexión estable al router o switch | Variable |

### Material opcional

| Componente | Cuándo hace falta | Nota |
|---|---|---|
| Adaptador Zigbee USB | Si se desplegarán Home Assistant y Zigbee2MQTT | No es necesario para el resto del homelab |

### Modelos orientativos

#### Carcasas con NVMe

| Modelo | Perfil | Precio aprox. | Comentario |
|---|---|---|---|
| Argon NEO 5 M.2 NVME | Equilibrado | ~35-45 EUR | Opción compacta y suficiente para este homelab |
| Argon ONE V3 M.2 NVME | Premium | ~55-65 EUR | Mejor acabado y ventilación, con mayor coste |

#### SSD NVMe

| Modelo | Formato | Capacidad | Precio aprox. | Comentario |
|---|---|---|---|---|
| Kingston NV2 | M.2 NVMe | 500 GB | ~35-40 EUR | Punto de equilibrio para SO, Docker y datos persistentes |

### Prioridad de compra

| Prioridad | Elementos | Motivo |
|---|---|---|
| Imprescindible | Raspberry Pi 5 8 GB, fuente oficial 27 W, carcasa con NVMe, SSD NVMe 500 GB, cable Ethernet | Sin esto no se puede montar el host principal previsto |
| Necesario para el diseño completo | `hd2t` y `hd5t` por USB 3.0 | El proyecto separa operación, multimedia y backups entre NVMe y HDD |
| Temporal | microSD 64 GB | Se usa para la instalación inicial y la migración posterior al NVMe |
| Opcional | Adaptador Zigbee USB | Solo aplica a la parte domótica |

### Criterios de compra

- La **fuente oficial de 27 W** es la opción recomendada de forma práctica si se va a usar NVMe junto con discos USB; reduce el riesgo de inestabilidad por alimentación.
- La **microSD no será el almacenamiento final**. Su función es únicamente servir de soporte de instalación y arranque inicial.
- La **carcasa debe integrar el SSD NVMe por PCIe**. La idea de este homelab no es usar el disco principal como unidad USB externa.
- El **SSD NVMe de 500 GB** debe alojar todo lo operativo: sistema, Docker, bases de datos, volúmenes persistentes, uploads, cachés y logs.
- `hd2t` y `hd5t` deben ir por **USB 3.0** para no penalizar transferencias de bibliotecas multimedia ni tareas de backup.
- La red base debe ser **Ethernet**, no Wi-Fi, para mantener estabilidad y rendimiento sostenido.
- No hace falta comprar hardware orientado a **exposición pública** porque el acceso previsto es local por LAN y remoto por Tailscale.

### Presupuesto orientativo del upgrade NVMe

| Escenario | Componentes | Total aprox. |
|---|---|---|
| Opción ajustada | Argon NEO 5 M.2 NVME + Kingston NV2 500 GB | ~70-85 EUR |
| Opción premium | Argon ONE V3 M.2 NVME + Kingston NV2 500 GB | ~90-105 EUR |

## Almacenamiento

### Distribución prevista

| Dispositivo | Etiqueta | Uso |
|---|---|---|
| SSD NVMe 500 GB | No aplica | Sistema operativo, Docker Engine, configuraciones, bases de datos, volúmenes, uploads y logs |
| HDD externo 2 TB | `hd2t` | Multimedia general, descargas y backups |
| HDD externo 5 TB | `hd5t` | Contenido multimedia de Stash |

### Política de uso

- Todo lo operativo y persistente de los servicios vive en el **SSD NVMe**.
- Los discos USB se reservan para datos grandes y menos sensibles a latencia: bibliotecas multimedia, descargas y copias de seguridad.
- La preparación de particiones, etiquetas, montaje automático y validaciones SMART se cubre en `docs/00-hardware/03-preparacion-discos.md`.
- Si alguno de los discos externos ya contiene datos, usar `docs/00-hardware/04-discos-con-datos.md` en lugar de reformatearlo.

## Backup
- Este documento no define todavía la política completa de copias, pero sí el hardware sobre el que se apoyará.
- `hd2t` debe dimensionarse pensando en almacenar tanto multimedia como backups locales del SSD NVMe.
- La estrategia detallada de copias se documentará más adelante en la fase de backups.

## Referencias
- `SERVICES.md`
- `docs/00-hardware/02-esquema-conexiones.md`
- `docs/00-hardware/03-preparacion-discos.md`
- `docs/00-hardware/04-discos-con-datos.md`
- `docs/00-hardware/05-arranque-nvme.md`
- Raspberry Pi 5
- Fuente oficial Raspberry Pi USB-C 27 W
- Argon NEO 5 M.2 NVME
- Argon ONE V3 M.2 NVME
- Kingston NV2 500 GB
