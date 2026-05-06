# Esquema de Conexiones

## Descripción
Mapa físico de conexiones para montar el homelab sobre una Raspberry Pi 5 con SSD NVMe integrado en la carcasa, dos discos externos USB, red por Ethernet y adaptador Zigbee opcional.

Este documento define cómo debe quedar cableado el conjunto antes de preparar discos, configurar el arranque desde NVMe o desplegar servicios. La lista exacta de componentes está en `docs/00-hardware/01-material-necesario.md`.

El alcance de red sigue siendo el del proyecto: acceso local por LAN y acceso remoto por Tailscale, sin exposición directa a internet ni apertura de puertos en el router.

## Requisitos Previos
- Haber revisado `docs/00-hardware/01-material-necesario.md` y disponer del hardware indicado.
- Tener identificados los dos discos externos que se usarán como `hd2t` y `hd5t`.
- Disponer de un puerto Ethernet libre en el router o switch principal de la LAN.
- Confirmar si los discos externos son autoalimentados por USB o si requieren fuente propia.
- Si se va a usar Zigbee, tener previsto un adaptador USB compatible y, preferiblemente, un alargador USB corto para separarlo del chasis.
- Tener presente que la microSD solo se usa para instalación o migración inicial; no forma parte del esquema final una vez el sistema arranca desde NVMe.
- Puertos y conexiones necesarios:
  - 1 conector PCIe interno de la Raspberry Pi 5, usado por la carcasa con slot M.2 NVMe.
  - 2 puertos USB 3.0 para `hd2t` y `hd5t`.
  - 1 puerto Ethernet Gigabit para red.
  - 1 puerto USB adicional para Zigbee si aplica.
  - 1 puerto USB-C para alimentación.

## Docker Compose
No aplica en esta fase. Aquí solo se define el cableado físico y la distribución de puertos del hardware base.

## Configuración

### Esquema general

```text
     Fuente oficial 27 W
              │
              │ USB-C
              ▼
┌──────────────────────────────────────────────────────────────┐
│                     Raspberry Pi 5 (8 GB)                   │
│                                                              │
│  PCIe interno de la carcasa ───────► SSD NVMe 500 GB        │
│  USB 3.0 azul 1              ───────► hd2t (2 TB)           │
│  USB 3.0 azul 2              ───────► hd5t (5 TB)           │
│  USB 2.0 / USB libre         ───────► Zigbee (opcional)     │
│  Ethernet Gigabit            ───────► Router / Switch LAN   │
└──────────────────────────────────────────────────────────────┘
```

### Topología recomendada

| Origen | Destino | Tipo de conexión | Uso |
|---|---|---|---|
| Raspberry Pi 5 | SSD NVMe M.2 en carcasa | PCIe interno de la carcasa | Sistema operativo, Docker, configuraciones y datos persistentes |
| Raspberry Pi 5 | `hd2t` | USB 3.0 | Multimedia general, descargas y backups |
| Raspberry Pi 5 | `hd5t` | USB 3.0 | Biblioteca multimedia de Stash |
| Raspberry Pi 5 | Router o switch principal | Ethernet Gigabit | Red estable en LAN y acceso por Tailscale |
| Raspberry Pi 5 | Adaptador Zigbee USB | USB 2.0 o USB libre | Integración domótica opcional |
| Fuente oficial 27 W | Raspberry Pi 5 | USB-C | Alimentación principal del conjunto |

### Reparto de puertos recomendado

| Puerto físico | Dispositivo recomendado | Motivo |
|---|---|---|
| USB-C alimentación | Fuente oficial Raspberry Pi 27 W | Mantener estabilidad eléctrica con NVMe y discos USB |
| PCIe interno de la carcasa | SSD NVMe 500 GB | El NVMe debe quedar integrado en la carcasa, no por USB |
| USB 3.0 azul 1 | `hd2t` | Mejor ancho de banda para multimedia y backups |
| USB 3.0 azul 2 | `hd5t` | Mejor ancho de banda para la librería grande de Stash |
| USB 2.0 | Adaptador Zigbee opcional | Evita ocupar los USB 3.0 y reduce interferencias de radiofrecuencia |
| Ethernet RJ45 | Router o switch | Más estable y predecible que Wi-Fi para servicios 24/7 |

### Elementos temporales fuera del esquema final

| Elemento | Cuándo se usa | Estado esperado al finalizar la fase |
|---|---|---|
| MicroSD | Instalación inicial de Raspberry Pi OS o migración previa al NVMe | Retirada del equipo tras validar el arranque desde NVMe |

### Disposición física recomendada

| Elemento | Ubicación recomendada | Objetivo |
|---|---|---|
| Raspberry Pi 5 en carcasa | Cerca del router o switch principal | Minimizar longitud del cable Ethernet y mantener una instalación fija |
| SSD NVMe | Dentro de la carcasa M.2 | Evitar adaptadores externos y mantener el almacenamiento del sistema integrado |
| `hd2t` y `hd5t` | A ambos lados o detrás de la Raspberry Pi, con cables diferenciables | Reducir confusiones al identificar discos y facilitar mantenimiento |
| Adaptador Zigbee | Separado del chasis con alargador USB corto si es posible | Reducir interferencias por metal, USB 3.0 y proximidad a discos |
| Fuente de alimentación | Con ventilación y sin tensión mecánica en el conector USB-C | Mejor estabilidad eléctrica a largo plazo |

### Orden físico de montaje

1. Montar el SSD NVMe dentro de la carcasa M.2 según el fabricante.
2. Cerrar la carcasa y conectar correctamente el enlace PCIe interno a la Raspberry Pi 5.
3. Conectar `hd2t` y `hd5t` a los puertos USB 3.0.
4. Conectar el cable Ethernet al router o al switch principal.
5. Conectar el adaptador Zigbee a un USB 2.0 si se va a usar.
6. Conectar la fuente oficial USB-C de 27 W en último lugar.

### Recomendaciones prácticas de cableado

- Mantener el **SSD NVMe dentro de la carcasa** como almacenamiento principal; no usarlo como unidad USB externa.
- Reservar los **USB 3.0** exclusivamente para `hd2t` y `hd5t`.
- Si el adaptador Zigbee se usa de forma permanente, colocarlo en un **USB 2.0** y, si es posible, con un pequeño alargador USB para alejarlo del chasis, del NVMe y de los discos.
- Evitar hubs USB no alimentados para discos mecánicos. Si un disco externo requiere más potencia o es de 3.5", debe usar su propia fuente.
- Usar **Ethernet** como conexión principal del host. Wi-Fi puede quedar solo como recurso temporal o de emergencia, no como enlace base del homelab.
- Dejar accesible el cableado suficiente para poder retirar la microSD después de migrar el arranque al NVMe.

### Validación visual rápida

Antes de encender por primera vez, comprobar lo siguiente:

- El SSD NVMe está montado dentro de la carcasa y enlazado por PCIe.
- `hd2t` y `hd5t` están conectados a puertos USB 3.0.
- El cable Ethernet está conectado al router o switch de la LAN.
- El adaptador Zigbee, si existe, no está ocupando un puerto crítico ni demasiado pegado al metal de la carcasa.
- La fuente conectada es la oficial de 27 W o una equivalente real de 5V/5A estable.

Después del primer arranque, validar también:

- El NVMe aparece en `lsblk` como dispositivo independiente, normalmente `nvme0n1`.
- Los discos USB aparecen por separado y con la capacidad esperada de 2 TB y 5 TB.
- La interfaz Ethernet tiene enlace activo hacia la LAN.
- Si hay adaptador Zigbee, el sistema lo detecta por USB aunque todavía no esté configurado a nivel de software.

## Almacenamiento

### Distribución física y lógica

| Dispositivo | Conexión física | Rol |
|---|---|---|
| SSD NVMe 500 GB | PCIe interno de la carcasa | SO, Docker Engine, configuraciones, bases de datos, volúmenes, uploads y logs |
| `hd2t` | USB 3.0 | Multimedia general, descargas y backups locales |
| `hd5t` | USB 3.0 | Contenido multimedia dedicado a Stash |

### Criterios de cableado ligados al almacenamiento

- El **almacenamiento persistente crítico** debe permanecer en el SSD NVMe, no en los discos USB.
- `hd2t` y `hd5t` deben quedar físicamente diferenciados desde el principio para evitar errores posteriores al montar etiquetas y `fstab`.
- La preparación de particiones, formatos, etiquetas y montaje automático se documenta en `docs/00-hardware/03-preparacion-discos.md`.
- Si alguno de los discos ya contiene información, seguir `docs/00-hardware/04-discos-con-datos.md` antes de modificar nada.

## Backup
- Este documento solo cubre el esquema físico, pero condiciona la estrategia de copias.
- `hd2t` debe permanecer conectado de forma estable porque alojará backups locales además de multimedia general.
- El diseño evita depender de la microSD como almacenamiento permanente; eso simplifica la recuperación y reduce puntos de fallo.

## Referencias
- `docs/00-hardware/01-material-necesario.md`
- `docs/00-hardware/03-preparacion-discos.md`
- `docs/00-hardware/04-discos-con-datos.md`
- `docs/00-hardware/05-arranque-nvme.md`
- `SERVICES.md`
