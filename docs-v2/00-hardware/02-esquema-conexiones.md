# Esquema de Conexiones

## Descripción

Diagrama físico y lógico de conexiones del homelab sobre **Raspberry Pi 5 (8 GB)**. Este documento describe **cómo se cablea** la Pi con sus periféricos (discos externos, router, adaptador Zigbee, alimentación) y **qué consideraciones eléctricas y de RF** hay que tener en cuenta para que el conjunto funcione de forma estable.

El objetivo es servir de referencia visual para el montaje inicial y para cualquier mantenimiento posterior (sustitución de cables, reubicación física, ampliación con un hub USB).

> **Recordatorio**: el homelab opera en **LAN + Tailscale**. No hay cableado adicional hacia el exterior ni equipos intermedios entre la Pi y el router doméstico.

---

## Requisitos Previos

- Material físico definido en [`01-material-necesario.md`](./01-material-necesario.md) ya disponible.
- Router doméstico con al menos un puerto Ethernet Gigabit libre y acceso a su panel de administración (para reservar IP estática vía DHCP en una fase posterior).
- Toma de corriente cercana a la ubicación final de la Pi. Idealmente protegida por SAI/UPS.

---

## Vista General del Cableado

```
                    ┌──────────────────────────────────────┐
                    │        Router doméstico (LAN)        │
                    │        (DHCP + DNS upstream)         │
                    └──────────────┬───────────────────────┘
                                   │
                                   │ Cable Ethernet Cat5e/Cat6
                                   │ (Gigabit)
                                   │
                ┌──────────────────┴──────────────────┐
                │     Raspberry Pi 5 (8 GB)           │
                │     + Active Cooler / carcasa       │
                │                                     │
                │   ┌─────────────────────────────┐   │
                │   │  microSD 64 GB (SO+Docker)  │   │
                │   └─────────────────────────────┘   │
                │                                     │
                │   USB 3.0 (azul) ── HDD 5 TB ──► hd5t (multimedia Stash)
                │   USB 3.0 (azul) ── HDD 2 TB ──► hd2t (servicios + backups)
                │   USB 2.0 (negro) ── alargador ── Zigbee Dongle (opcional)
                │                                     │
                │   USB-C ◄── Fuente oficial 27 W (5 V / 5 A)
                │                                     │
                └─────────────────────────────────────┘
```

---

## Conexiones Detalladas

### 1. Alimentación (USB-C)

| Origen | Destino | Cable |
|---|---|---|
| Toma de corriente (Schuko) | Fuente oficial Raspberry Pi 27 W | Cable de red propio de la fuente |
| Fuente oficial 27 W | Puerto **USB-C de alimentación** de la Pi 5 | Cable USB-C integrado en la fuente oficial |

- La Pi 5 **negocia 5 V / 5 A** únicamente con la fuente oficial (o equivalentes que soporten USB-PD a esa potencia). Con fuentes inferiores arranca, pero limita la corriente disponible en los puertos USB, lo que provoca **caídas y desconexiones de los HDDs externos**.
- **No** alimentar la Pi por los pines GPIO en este montaje (no hay control fino de corriente y se pierde el monitor de undervoltage del firmware).
- Si se usa SAI, conectar a él tanto la **fuente de la Pi** como el **router** (de poco sirve mantener la Pi viva si la red se cae).

### 2. Red (Ethernet)

| Origen | Destino | Cable |
|---|---|---|
| Puerto Gigabit Ethernet de la Pi 5 | Cualquier puerto LAN libre del router | Cable **Cat5e o Cat6**, longitud 1–3 m típica |

- **Conexión cableada obligatoria**. El WiFi de la Pi 5 introduce jitter y latencias inaceptables para Pi-hole (DNS) y Caddy (reverse proxy).
- El **WiFi y el Bluetooth de la Pi se dejan deshabilitados** una vez confirmado que la red cableada funciona (se documenta en Fase 1).
- La asignación de **IP estática** de la Pi se hace **por reserva DHCP en el router** (no por configuración estática en `/etc/dhcpcd.conf`), de modo que se gestiona desde un único sitio. Se documenta en `docs/13-operaciones/04-red-y-puertos.md`.

### 3. Almacenamiento externo (USB 3.0)

| Etiqueta | Disco | Puerto Pi 5 | Punto de montaje |
|---|---|---|---|
| `hd5t` | HDD externo 5 TB, USB 3.0 | **USB 3.0 (azul)** — preferentemente el más cercano al puerto Ethernet | `/mnt/hd5t` |
| `hd2t` | HDD externo 2 TB, USB 3.0 | **USB 3.0 (azul)** — el otro de los dos disponibles | `/mnt/hd2t` |

- Ambos discos **deben** conectarse a los puertos **USB 3.0 (azules)**. Los puertos USB 2.0 (negros) limitan a ~35 MB/s y harían inviable el rendimiento de Jellyfin, Nextcloud o backups.
- Conectar los discos **directamente** a la Pi (sin hub) en el primer arranque, para descartar problemas de alimentación o de chipset del hub al hacer las pruebas iniciales (SMART, formato, montaje).
- Si los HDDs **no traen alimentación propia** (la mayoría de los 2.5"), pueden requerir más corriente de la que la Pi puede entregar de forma sostenida en los dos puertos USB 3.0 a la vez. Si se observan **desconexiones, errores `usb 2-1: device descriptor read/64, error -71` en `dmesg` o reinicios espontáneos del HDD**, intercalar un **hub USB 3.0 con alimentación externa** entre la Pi y los discos.
- Mantener los **cables USB cortos y de calidad** (idealmente los que vienen con el propio HDD). Los cables baratos largos provocan caídas de tensión que se manifiestan como errores intermitentes muy difíciles de diagnosticar.
- Etiquetar físicamente cada disco con su nombre (`hd5t`, `hd2t`) para evitar confusiones al desconectar/reconectar.

### 4. Adaptador Zigbee (opcional, USB 2.0)

| Origen | Destino | Cable |
|---|---|---|
| Adaptador Zigbee (SONOFF Dongle Plus / ConBee II) | Puerto **USB 2.0 (negro)** de la Pi 5 | **Alargador USB 2.0 de ~0.5 m** |

- El adaptador Zigbee se conecta a un **USB 2.0**, no a un USB 3.0. Los puertos USB 3.0 emiten **interferencias de RF en la banda de 2.4 GHz** que degradan tanto Zigbee como WiFi/Bluetooth (problema documentado por Intel y por la propia Raspberry Pi Foundation).
- **Siempre** usar un alargador corto (~0.5 m) para alejar el dongle del cuerpo de la Pi: reduce significativamente las pérdidas de paquetes Zigbee y mejora el alcance.
- Si el adaptador queda muy cerca de los HDDs externos también puede sufrir interferencias; orientarlo hacia el lado opuesto.

---

## Distribución Física Recomendada de los Puertos

Vista de la Pi 5 con los puertos hacia el usuario:

```
              ┌──────────────────────────────┐
              │  [USB-C PWR]      [HDMI 0/1] │   ← parte trasera
              │                              │
              │  [Ethernet]   [USB 3.0 azul] │ ← hd5t
              │               [USB 3.0 azul] │ ← hd2t
              │               [USB 2.0 negro]│ ← Zigbee (alargador)
              │               [USB 2.0 negro]│ ← libre / accesorios
              └──────────────────────────────┘
```

- Los HDDs grandes y pesados (sobre todo el de 5 TB) deben quedar **apoyados en una superficie estable**, no colgando del cable USB. Un cable tirante acaba dañando el conector USB de la Pi.
- Dejar **espacio libre alrededor de la carcasa** para el flujo de aire del Active Cooler (mínimo ~3 cm por cada lado).

---

## Listas de Verificación Post-Cableado

Antes de pasar a `docs/00-hardware/03-preparacion-discos.md`, comprobar visualmente y con la Pi apagada:

- [ ] Fuente oficial 27 W conectada al puerto USB-C de alimentación.
- [ ] Cable Ethernet conectado entre la Pi y el router; LEDs del puerto del router encendidos al alimentar la Pi.
- [ ] Disco `hd5t` (5 TB) en un puerto **USB 3.0 azul**.
- [ ] Disco `hd2t` (2 TB) en el otro puerto **USB 3.0 azul**.
- [ ] (Opcional) Dongle Zigbee en un puerto **USB 2.0 negro**, mediante alargador de ~0.5 m.
- [ ] Carcasa cerrada con el Active Cooler o ventilador conectado a su pinout.
- [ ] microSD insertada con la imagen de Raspberry Pi OS Lite ya flasheada (ver Fase 1).

Tras el primer arranque, con la Pi accesible vía SSH, validar:

- `dmesg | grep -iE "usb|sd[a-z]"` no muestra errores de descriptor ni resets repetidos.
- `lsblk -o NAME,SIZE,TRAN,MODEL` lista ambos discos como `usb` con sus tamaños esperados (~5 TB y ~2 TB).
- `ip a show eth0` muestra `state UP` y una IPv4 asignada por DHCP.
- `vcgencmd get_throttled` devuelve `throttled=0x0` (sin undervoltage ni throttling térmico tras varios minutos en marcha).

Si alguna de estas comprobaciones falla, revisar la sección correspondiente de este documento antes de continuar con el formateo y montaje en `03-preparacion-discos.md`.

---

## Referencias

- [Raspberry Pi 5 — Datasheet (puertos y consumo)](https://datasheets.raspberrypi.com/rpi5/raspberry-pi-5-product-brief.pdf)
- [USB 3.0 Radio Frequency Interference on 2.4 GHz devices (Intel white paper)](https://www.intel.com/content/dam/support/us/en/documents/wireless/wireless-products/RFI-USB3-Wireless.pdf)
- [Raspberry Pi 5 Power Supply requirements](https://www.raspberrypi.com/documentation/computers/raspberry-pi.html#power-supply)
- [Active Cooler — Datasheet](https://datasheets.raspberrypi.com/cooling/raspberry-pi-active-cooler-product-brief.pdf)
