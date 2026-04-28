# Esquema de Conexiones

## Descripción

Diagrama físico del homelab sobre **Raspberry Pi 5 (8 GB)**: cómo se cablea la Pi con sus periféricos (alimentación, red, discos externos USB y adaptador Zigbee opcional) y qué consideraciones eléctricas y de RF hay que tener en cuenta para que el conjunto sea estable durante meses de funcionamiento 24/7.

Este documento es la referencia visual para el montaje inicial y para cualquier mantenimiento posterior (sustitución de un cable, reubicación de la Pi, ampliación con un hub USB alimentado).

> **Recordatorio de alcance**: el homelab opera en **LAN doméstica + Tailscale (VPN mesh)**. No hay cableado adicional hacia el exterior, ni equipos intermedios entre la Pi y el router. La única conexión hacia "fuera" del armario es el cable Ethernet al router.

---

## Requisitos Previos

- Material físico definido en [`01-material-necesario.md`](./01-material-necesario.md) ya disponible (Pi 5, fuente oficial 27 W, microSD, HDDs `hd5t` y `hd2t`, carcasa con Active Cooler, cable Ethernet, dongle Zigbee opcional).
- Router doméstico con al menos **un puerto Ethernet Gigabit libre** y acceso a su panel de administración (será necesario más adelante para reservar IP por DHCP, pero conviene confirmar acceso desde el principio).
- Toma de corriente cercana al lugar de instalación final, idealmente protegida por SAI/UPS.
- microSD **ya flasheada** con Raspberry Pi OS Lite 64-bit y configuración headless (ver Fase 1, `docs/01-sistema/01-instalacion-os.md`). El cableado se prueba con la Pi ya capaz de arrancar.

---

## Vista General del Cableado

```
                ┌────────────────────────────────────────────┐
                │           Router doméstico (LAN)           │
                │           DHCP + DNS upstream              │
                └────────────────────┬───────────────────────┘
                                     │
                                     │ Cable Ethernet Cat5e/Cat6
                                     │ (Gigabit, 1–3 m)
                                     │
                ┌────────────────────┴───────────────────────┐
                │          Raspberry Pi 5 (8 GB)             │
                │      + Active Cooler / carcasa             │
                │                                            │
                │  ┌──────────────────────────────────────┐  │
                │  │  microSD 64 GB  (SO + Docker root)   │  │
                │  └──────────────────────────────────────┘  │
                │                                            │
                │  USB 3.0 (azul) ── HDD 5 TB ──► hd5t       │  (multimedia Stash)
                │  USB 3.0 (azul) ── HDD 2 TB ──► hd2t       │  (servicios + backups)
                │  USB 2.0 (negro) ── alargador 0.5 m ──►    │  Zigbee Dongle (opcional)
                │                                            │
                │  USB-C ◄── Fuente oficial 27 W (5 V / 5 A) │
                │                                            │
                └────────────────────────────────────────────┘
```

---

## Conexiones Detalladas

### 1. Alimentación (USB-C)

| Origen | Destino | Cable |
|---|---|---|
| Toma de corriente (Schuko) | Fuente oficial Raspberry Pi 27 W | Cable de red propio de la fuente |
| Fuente oficial 27 W | Puerto **USB-C de alimentación** de la Pi 5 | Cable USB-C integrado en la fuente oficial |

- La Pi 5 **negocia 5 V / 5 A** únicamente con la fuente oficial (o equivalentes que soporten USB-PD a esa potencia). Con fuentes inferiores la Pi arranca, pero limita la corriente disponible en los puertos USB y eso provoca **caídas y desconexiones de los HDDs externos** bajo carga.
- **No** alimentar la Pi por los pines GPIO en este montaje: se pierde el monitor de undervoltage del firmware y no hay protección.
- Si se usa SAI, conectar a él tanto la **fuente de la Pi** como el **router** (de poco sirve mantener la Pi viva si la red se cae al primer corte).

### 2. Red (Ethernet)

| Origen | Destino | Cable |
|---|---|---|
| Puerto Gigabit Ethernet de la Pi 5 | Cualquier puerto LAN libre del router | Cable **Cat5e o Cat6**, longitud típica 1–3 m |

- **Conexión cableada obligatoria**. El WiFi de la Pi 5 introduce jitter y latencias inaceptables para Pi-hole (DNS) y Caddy (reverse proxy), que son servicios sincrónicos que atienden a toda la LAN.
- **WiFi y Bluetooth** del SoC se dejan **deshabilitados** una vez confirmado que la red cableada funciona, para liberar RF en 2.4 GHz (ver Fase 1, `docs/01-sistema/02-configuracion-inicial.md`).
- La asignación de **IP estática** de la Pi se gestiona **por reserva DHCP en el router**, no por configuración estática en la Pi. Mantiene el control de IPs en un único sitio. Se documenta en `docs/13-operaciones/04-red-y-puertos.md`.
- En esta fase basta con que la Pi obtenga IP por DHCP normal y tenga conectividad; la reserva se hace antes de desplegar Pi-hole en la Fase 3.

### 3. Almacenamiento externo (USB 3.0)

| Etiqueta | Disco | Puerto Pi 5 | Punto de montaje |
|---|---|---|---|
| `hd5t` | HDD externo 5 TB, USB 3.0 | **USB 3.0 (azul)** | `/mnt/hd5t` |
| `hd2t` | HDD externo 2 TB, USB 3.0 | **USB 3.0 (azul)** | `/mnt/hd2t` |

- Ambos discos **deben** conectarse a los puertos **USB 3.0 (azules)**. Los puertos USB 2.0 (negros) limitan a ~35 MB/s, lo que haría inviable el rendimiento de Jellyfin (escaneos de biblioteca), Nextcloud y los backups con Borgmatic.
- En el primer arranque, conectar los HDDs **directamente** a la Pi (sin hub) para descartar problemas de chipset o de alimentación del hub durante las pruebas SMART, formateo y montaje (`03-preparacion-discos.md`).
- Si los HDDs **no traen alimentación propia** (mayoría de los 2.5"), pueden requerir más corriente sostenida de la que la Pi puede entregar de forma simultánea por los dos puertos USB 3.0. Síntomas típicos: errores `usb 2-1: device descriptor read/64, error -71` en `dmesg`, desconexiones esporádicas o reinicios del HDD. Solución: intercalar un **hub USB 3.0 con alimentación externa** entre la Pi y los discos.
- Mantener los **cables USB cortos y de calidad** (idealmente los que vienen con el propio HDD). Cables baratos largos provocan caídas de tensión que se manifiestan como errores intermitentes muy difíciles de diagnosticar.
- **Etiquetar físicamente** cada disco con su nombre lógico (`hd5t`, `hd2t`) para evitar confusiones al desconectar/reconectar; las etiquetas internas (`LABEL`) se aplican en `03-preparacion-discos.md`.

### 4. Adaptador Zigbee (opcional, USB 2.0)

| Origen | Destino | Cable |
|---|---|---|
| Adaptador Zigbee (SONOFF Dongle Plus / ConBee II / Sky-Connect) | Puerto **USB 2.0 (negro)** de la Pi 5 | **Alargador USB 2.0 de ~0.5 m** |

- El adaptador Zigbee se conecta a un **USB 2.0**, **nunca** a un USB 3.0. Los puertos USB 3.0 emiten **interferencias de RF en la banda de 2.4 GHz** que degradan tanto Zigbee como WiFi/Bluetooth (efecto documentado por Intel y por la propia Raspberry Pi Foundation).
- **Siempre** mediante un **alargador corto (~0.5 m)** para alejar el dongle del cuerpo de la Pi y de los HDDs: reduce drásticamente la pérdida de paquetes Zigbee y mejora el alcance al resto de la casa.
- Si el dongle queda en línea con los HDDs externos también puede sufrir interferencias; orientarlo hacia el lado opuesto.
- Si finalmente no se va a desplegar Zigbee2MQTT, este punto puede omitirse sin afectar al resto del homelab.

---

## Distribución Física Recomendada de los Puertos

Vista de la Pi 5 con los puertos hacia el usuario:

```
              ┌─────────────────────────────────┐
              │ [USB-C PWR]        [HDMI 0/1]   │   ← parte trasera
              │                                 │
              │ [Ethernet]    [USB 3.0 azul]    │ ← hd5t
              │               [USB 3.0 azul]    │ ← hd2t
              │               [USB 2.0 negro]   │ ← Zigbee (alargador)
              │               [USB 2.0 negro]   │ ← libre / accesorios
              └─────────────────────────────────┘
```

- Los HDDs grandes y pesados (sobre todo el de 5 TB en formato 3.5") deben quedar **apoyados sobre una superficie estable**, nunca colgando del cable USB. Un cable tirante acaba dañando el conector USB de la Pi (que no está pensado para soportar peso).
- Dejar **espacio libre alrededor de la carcasa** para el flujo de aire del Active Cooler: mínimo ~3 cm por cada lado y por encima.
- Evitar colocar la Pi sobre los propios HDDs (transmiten vibración y calor) o dentro de armarios cerrados sin ventilación.

---

## Lista de Verificación Post-Cableado

Antes de pasar a `docs/00-hardware/03-preparacion-discos.md`, comprobar visualmente con la Pi **apagada**:

- [ ] Fuente oficial 27 W conectada al puerto USB-C de alimentación de la Pi.
- [ ] Cable Ethernet conectado entre la Pi y el router. Al alimentar la Pi, los LEDs del puerto del router se encienden.
- [ ] Disco `hd5t` (5 TB) en un puerto **USB 3.0 azul**.
- [ ] Disco `hd2t` (2 TB) en el otro puerto **USB 3.0 azul**.
- [ ] (Opcional) Dongle Zigbee en un puerto **USB 2.0 negro**, a través de alargador de ~0.5 m.
- [ ] Carcasa cerrada con el Active Cooler o ventilador conectado a su pinout (4 pines).
- [ ] microSD insertada con Raspberry Pi OS Lite ya flasheado y configurado en headless.

Tras el primer arranque, con acceso por SSH, validar desde la propia Pi:

| Comando | Resultado esperado |
|---|---|
| `dmesg \| grep -iE "usb\|sd[a-z]"` | Sin errores `device descriptor read/64`, sin resets repetidos. |
| `lsblk -o NAME,SIZE,TRAN,MODEL` | Ambos discos aparecen como `usb` con sus tamaños (~5 TB y ~2 TB). |
| `ip a show eth0` | Estado `UP` y una IPv4 asignada por DHCP. |
| `vcgencmd get_throttled` | Devuelve `throttled=0x0` tras varios minutos de uso (sin undervoltage ni throttling térmico). |
| `vcgencmd measure_temp` | Por debajo de ~70 °C en reposo con Active Cooler. |

Si alguna comprobación falla, revisar la sección correspondiente de este documento (alimentación, red, USB) **antes** de continuar con el formateo y montaje en `03-preparacion-discos.md`. Un cableado deficiente arrastra problemas a todas las fases siguientes y son los más difíciles de diagnosticar una vez el sistema está en producción.

---

## Referencias

- [Raspberry Pi 5 — Product Brief (puertos y consumo)](https://datasheets.raspberrypi.com/rpi5/raspberry-pi-5-product-brief.pdf)
- [Raspberry Pi 5 — Power Supply requirements](https://www.raspberrypi.com/documentation/computers/raspberry-pi-5.html#power-supply)
- [Raspberry Pi Active Cooler — Datasheet](https://datasheets.raspberrypi.com/cooling/raspberry-pi-active-cooler-product-brief.pdf)
- [Intel — USB 3.0 Radio Frequency Interference Impact on 2.4 GHz Wireless Devices (white paper)](https://www.intel.com/content/dam/support/us/en/documents/wireless/wireless-products/RFI-USB3-Wireless.pdf)
- [Documento siguiente: `03-preparacion-discos.md`](./03-preparacion-discos.md)
