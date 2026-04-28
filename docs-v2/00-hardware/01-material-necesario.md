# Material Necesario

## Descripción

Lista completa del material físico necesario para montar el homelab sobre **Raspberry Pi 5 (8 GB)** con dos discos duros externos. Cubre el equipo imprescindible (CPU, almacenamiento, alimentación, red, refrigeración) y el opcional (domótica Zigbee, accesorios).

> **Recordatorio**: el homelab opera en **LAN + Tailscale** (sin exposición a internet), por lo que no se necesita hardware adicional para apertura de puertos ni equipamiento de red más allá del router doméstico existente.

---

## Material Imprescindible

### Cómputo y memoria

| Componente | Especificación recomendada | Notas |
|---|---|---|
| **Raspberry Pi 5** | Modelo de **8 GB** RAM (ARM64, BCM2712) | Imprescindible la versión de 8 GB para correr varios servicios Docker simultáneamente. La de 4 GB se queda corta con stacks como Nextcloud + Jellyfin + monitorización. |
| **microSD** | 64 GB clase A2 / V30 (ej. SanDisk Extreme, Samsung Pro Endurance) | Solo aloja SO, Docker Engine y configs (`docker-compose.yml`, `.env`). Los datos persistentes irán en los discos externos para evitar desgaste. Se recomienda tarjeta **High Endurance** o **Pro Endurance**. |

### Alimentación

| Componente | Especificación recomendada | Notas |
|---|---|---|
| **Fuente de alimentación** | Fuente **oficial Raspberry Pi USB-C 27 W (5 V / 5 A)** | La Pi 5 requiere 5 A para habilitar la corriente completa en los puertos USB (necesario para alimentar dos HDDs externos sin caídas). Fuentes de menor amperaje provocan throttling y desconexiones de los discos. |

### Almacenamiento externo

| Componente | Especificación recomendada | Notas |
|---|---|---|
| **HDD externo `hd5t`** | Disco duro externo **5 TB, USB 3.0** (ej. WD Elements, Seagate Expansion 5 TB) | Dedicado en exclusiva a los **contenidos multimedia de Stash**. Montado de forma permanente en `/mnt/hd5t`. |
| **HDD externo `hd2t`** | Disco duro externo **2 TB, USB 3.0** (ej. WD Elements, Seagate Expansion 2 TB) | Datos persistentes del resto de servicios (bases de datos, uploads, configs, logs) + partición/carpeta de backups. Montado en `/mnt/hd2t`. |

> **Importante**: ambos discos deben conectarse a los **puertos USB 3.0 (azules)** de la Pi 5, **no** a los USB 2.0 (negros). Si los discos no traen alimentación propia, conviene revisar que la fuente de 27 W sea capaz de alimentarlos a través de la Pi; en caso de inestabilidad, usar un **hub USB 3.0 con alimentación externa**.

### Refrigeración

| Componente | Especificación recomendada | Notas |
|---|---|---|
| **Carcasa con ventilador** | Carcasa oficial Raspberry Pi 5 con ventilador integrado, o **Active Cooler** oficial + carcasa pasiva | La Pi 5 se calienta notablemente bajo carga sostenida (compilaciones, transcodificación, indexado). Sin disipación activa hay throttling térmico. El **Active Cooler oficial** ya incluye disipador + ventilador PWM controlado por el firmware. |

### Red

| Componente | Especificación recomendada | Notas |
|---|---|---|
| **Cable Ethernet** | Cable Cat5e o Cat6, longitud según ubicación física (1–3 m típico) | **Conexión cableada obligatoria** para servicios de red (Pi-hole, Caddy, Nextcloud). El WiFi añade latencia y jitter inaceptables para DNS y reverse proxy. La Pi 5 trae Gigabit Ethernet. |
| **Puerto libre en el router** | 1 puerto Ethernet Gigabit en el router doméstico | También se necesita acceso a la administración del router para reservar IP estática vía DHCP y configurar Pi-hole como DNS. |

---

## Material Opcional

### Domótica e IoT

| Componente | Especificación recomendada | Notas |
|---|---|---|
| **Adaptador Zigbee USB** | **SONOFF Zigbee 3.0 USB Dongle Plus** (CC2652P) o **ConBee II** | Necesario únicamente si se va a desplegar **Zigbee2MQTT** (Fase 8). Se recomienda usar un **alargador USB** corto (~0.5 m) para alejarlo de la Pi y evitar interferencias de RF con el WiFi/Bluetooth interno. |

### Accesorios útiles

| Componente | Notas |
|---|---|
| **Lector de tarjetas microSD** | Para flashear la microSD desde el PC con Raspberry Pi Imager. |
| **Teclado + monitor HDMI (micro-HDMI)** | Solo necesario si se va a configurar la Pi en modo no-headless. La instalación recomendada en este homelab es **headless vía SSH** (configurada desde Raspberry Pi Imager), por lo que normalmente no hace falta. |
| **SAI / UPS pequeño** | Recomendable para proteger los HDDs externos frente a cortes eléctricos (corrupción de FS). Cualquier SAI de 300–500 VA con tomas tipo Schuko es suficiente. |
| **Hub USB 3.0 con alimentación externa** | Necesario si los discos externos provocan inestabilidad por consumo eléctrico, o si se prevé conectar más periféricos USB. |

---

## Resumen de la Configuración Objetivo

```
Raspberry Pi 5 (8 GB) + Active Cooler
  ├── microSD 64 GB ............ SO + Docker + configs
  ├── USB 3.0 ── HDD 5 TB (hd5t) ... /mnt/hd5t  → Stash (multimedia)
  ├── USB 3.0 ── HDD 2 TB (hd2t) ... /mnt/hd2t  → datos servicios + backups
  ├── USB 2.0 ── Zigbee Dongle (opcional) ... Zigbee2MQTT
  ├── Ethernet ── Router doméstico ........... LAN + Tailscale
  └── USB-C ── Fuente oficial 27 W (5 V / 5 A)
```

---

## Referencias

- [Raspberry Pi 5 — Especificaciones oficiales](https://www.raspberrypi.com/products/raspberry-pi-5/)
- [Raspberry Pi 27 W USB-C Power Supply](https://www.raspberrypi.com/products/27w-power-supply/)
- [Raspberry Pi 5 Active Cooler](https://www.raspberrypi.com/products/active-cooler/)
- [Raspberry Pi Imager](https://www.raspberrypi.com/software/)
- [SONOFF Zigbee 3.0 USB Dongle Plus](https://sonoff.tech/product/gateway-and-sensors/sonoff-zigbee-3-0-usb-dongle-plus/)
