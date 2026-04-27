# Esquema de Conexiones

## Descripción

Diagrama físico de todas las conexiones del homelab: cómo se cablea la **Raspberry Pi 5** con los dos discos externos (`hd5t` y `hd2t`), el router de la LAN, la fuente de alimentación, el adaptador Zigbee opcional y la refrigeración. El objetivo es disponer de una referencia visual y textual única para montar (o re-montar) el equipo sin ambigüedades sobre qué cable va a qué puerto.

> **Recordatorio**: el homelab solo se expone a la **LAN** y a **Tailscale**. No hay enlaces hacia internet ni puertos abiertos en el router; cualquier acceso remoto pasa por VPN.

---

## Diagrama general

```
                            ┌──────────────────────────┐
                            │   Red eléctrica (230 V)  │
                            └─────────────┬────────────┘
                                          │
                ┌─────────────────────────┼──────────────────────────┐
                │                         │                          │
                ▼                         ▼                          ▼
       ┌─────────────────┐    ┌─────────────────────┐    ┌─────────────────────┐
       │ Fuente Pi 5     │    │ Carcasa hd5t (3,5") │    │ Router / ONT        │
       │ 27 W USB-C PD   │    │ Alimentación propia │    │ (DHCP + LAN)        │
       └────────┬────────┘    └──────────┬──────────┘    └──────────┬──────────┘
                │ USB-C                  │ USB-A 3.0                │ RJ45
                │ (5,1 V / 5 A)          │ (datos)                  │ (1 Gbps)
                ▼                        ▼                          │
       ┌──────────────────────────────────────────────────┐         │
       │                Raspberry Pi 5 (8 GB)             │         │
       │                                                  │         │
       │  [USB-C PWR] [USB3-A1] [USB3-A2] [USB2] [USB2]   │         │
       │       │         │          │       │              │        │
       │       │         │          │       └── Zigbee*    │        │
       │       │         │          │                      │        │
       │       │         │          └──────── hd2t (2,5")  │        │
       │       │         └─────────────────── hd5t (3,5")  │        │
       │       │                                           │        │
       │  [Ethernet RJ45] ───────────────────────────────────────────┘
       │  [microSD]   ── Raspberry Pi OS Lite + bootloader│
       │  [GPIO/PWM]  ── Ventilador de la carcasa         │
       │  [HDMI 0/1]  ── (sólo durante setup inicial)     │
       └──────────────────────────────────────────────────┘
                * Conectado a través de alargador USB de ≥1 m
                  (separa el dongle Zigbee del bus USB 3.0).
```

> El esquema asume la disposición típica de puertos de la Raspberry Pi 5: dos USB 3.0 (azules) y dos USB 2.0 (negros) en el mismo lateral, USB-C de alimentación, Ethernet Gigabit y microSD en la parte inferior.

---

## Tabla de conexiones

| # | Origen | Puerto origen | Cable | Destino | Puerto destino | Notas |
|---|--------|---------------|-------|---------|----------------|-------|
| 1 | Fuente oficial 27 W | Salida USB-C PD | Cable USB-C incluido (corto, AWG bajo) | Raspberry Pi 5 | **USB-C PWR** | Alimentación principal. No usar cargadores genéricos: la Pi 5 exige 5 A reales para habilitar los 1,6 A por puerto USB. |
| 2 | Carcasa **hd5t** (5 TB) | USB-A 3.0 (back de la carcasa) | USB-A → USB-A 3.0 corto y de calidad | Raspberry Pi 5 | **USB 3.0 #1** (azul) | Disco multimedia de Stash. La carcasa de 3,5" lleva su propia fuente; la Pi solo aporta datos. |
| 3 | Carcasa **hd2t** (2 TB, 2,5" autoalimentado) | USB-A 3.0 / USB-C (carcasa) | USB-A → USB-A 3.0 (o adaptador a USB-C según carcasa) | Raspberry Pi 5 | **USB 3.0 #2** (azul) | Volúmenes Docker, bases de datos, multimedia secundario y particiones de backup. La Pi entrega la corriente; usar fuente oficial obligatoriamente. |
| 4 | Router doméstico | Puerto LAN libre | Cable Ethernet Cat 5e/6 | Raspberry Pi 5 | **RJ45 Gigabit** | Enlace fijo a la red. Reservar IP estática por DHCP (`mac` de la Pi) en el router. Sin port forwarding. |
| 5 | Adaptador Zigbee USB (opcional) | USB-A | Alargador USB 2.0 de ≥1 m | Raspberry Pi 5 | **USB 2.0** (puerto negro) | Mantenerlo conectado a USB 2.0 (Zigbee2MQTT no requiere ancho de banda) y físicamente alejado de los puertos USB 3.0 para evitar interferencias en 2,4 GHz. |
| 6 | Ventilador de la carcasa (Argon NEO 5, fan oficial, etc.) | Conector PWM 4 pin / pines GPIO | Cable suministrado con la carcasa | Raspberry Pi 5 | **GPIO PWM** (header de 40 pines) o conector dedicado de la carcasa | Imprescindible para uso 24/7. La Pi 5 controla la velocidad por PWM en función de la temperatura. |
| 7 | microSD con Raspberry Pi OS | — | — | Raspberry Pi 5 | **Slot microSD** (cara inferior) | Sólo OS y bootloader. Datos persistentes nunca se almacenan aquí. |
| 8 | Monitor / TV (sólo setup inicial) | HDMI / micro-HDMI | Cable micro-HDMI → HDMI | Raspberry Pi 5 | **HDMI 0** | Sólo para depuración del primer arranque o recuperación. En operación normal la Pi va headless. |
| 9 | Teclado USB (sólo setup inicial) | USB-A | — | Raspberry Pi 5 | **USB 2.0** libre | Igual que el HDMI: opcional, sólo durante el provisionado o ante fallos de red. |

---

## Detalle por subsistema

### Alimentación

- **Fuente oficial 27 W USB-C PD** únicamente en el conector de alimentación. Cualquier otro cargador (incluso 65 W de portátil) debe negociar 5,1 V / 5 A; si no, la Pi limita la corriente USB y los discos pueden desconectarse.
- La carcasa de **hd5t** (3,5") usa **su propia fuente externa**: no tira de la Pi salvo para datos. Conectar primero la fuente del disco y, sólo después, el cable USB a la Pi (evita picos al detectar el dispositivo con el bus arrancando).
- **hd2t** (2,5" autoalimentado) sí depende de los 5 V del puerto USB 3.0 de la Pi. Si aparece `usb X-1: device descriptor read/64, error -71` o desmontajes aleatorios, intercalar un **hub USB 3.0 con alimentación externa** entre la Pi y el disco.

### Almacenamiento USB

- Los **dos discos van siempre a los puertos USB 3.0 (azules)**, nunca a los USB 2.0. Los azules comparten controlador, así que en operaciones simultáneas intensas (backup de `hd2t` mientras Jellyfin lee de `hd5t`) habrá contención: es esperable, no un fallo.
- No alternar los discos entre puertos durante el rodaje: el orden de detección puede cambiar el `/dev/sdX`. El montaje se hará por **etiqueta** (`hd5t`, `hd2t`) o por UUID en `fstab`, ver `docs/00-hardware/03-preparacion-discos.md`.
- **Etiquetar físicamente** los cables USB de cada disco con su nombre (`hd5t` / `hd2t`) usando bridas o etiquetas adhesivas. Evita confusiones al desconectar uno para sustituirlo.

### Red

- Conexión **siempre por cable** Ethernet a un puerto LAN del router. La WiFi se configurará sólo como fallback de emergencia (ver `docs/01-sistema/01-instalacion-os.md`).
- El router debe **reservar la IP de la Pi por DHCP** según su MAC, no fijarla por configuración estática en la Pi: facilita reemplazar el equipo sin tocar la red.
- La Pi-hole en macvlan (Fase 3) toma una IP **diferente** de la del host (p. ej. `192.168.1.2` para Pi-hole, `192.168.1.3` para la Pi). Reservar **ambas** en el DHCP del router antes de desplegar la macvlan.

### Refrigeración

- El ventilador va al conector que indique la carcasa elegida (PWM oficial → header dedicado de 4 pines en la Pi 5; carcasas como Argon NEO 5 ya traen su propio cableado al GPIO).
- Comprobar después del primer arranque que el ventilador modula su velocidad con la temperatura (`vcgencmd measure_temp`) y no está siempre al 100 %: si gira al máximo de forma constante, el cable PWM no está bien conectado.

### Periféricos opcionales

- **Adaptador Zigbee USB** (Sonoff Dongle Plus, ConBee II, SkyConnect): conectar **siempre** a USB 2.0 mediante un alargador de al menos 1 m. Pegado a la Pi y a USB 3.0 sufre interferencias en 2,4 GHz que se traducen en pérdida de paquetes Zigbee y emparejamientos fallidos.
- **HDMI y teclado**: sólo durante el setup inicial o un disaster recovery. En operación normal el equipo es headless y se administra por SSH (Fase 1).

---

## Orden recomendado de montaje

1. Insertar la **microSD** ya flasheada con Raspberry Pi OS Lite (ver `docs/01-sistema/01-instalacion-os.md`).
2. Atornillar la Pi en su **carcasa con ventilador** y conectar el cable PWM antes de cerrar.
3. Conectar el cable **Ethernet** al router.
4. Conectar **primero la fuente externa** del disco `hd5t` (3,5") y, una vez arrancado, su **cable USB** a un puerto USB 3.0 de la Pi.
5. Conectar el disco `hd2t` (2,5") al **otro puerto USB 3.0** de la Pi.
6. (Opcional) Conectar el **adaptador Zigbee** mediante alargador a un puerto USB 2.0.
7. Conectar la **fuente oficial 27 W** al USB-C de la Pi *en último lugar*. La Pi arrancará al recibir corriente.
8. Esperar 60–90 segundos y comprobar que el router muestra la Pi conectada con la IP reservada antes de proceder a la configuración por SSH.

> Si en el primer arranque aparecen mensajes de **under-voltage** (relámpago amarillo en pantalla o en `dmesg`), lo más habitual es: cable USB-C de mala calidad, fuente no oficial, o carcasa de `hd2t` tirando demasiada corriente del bus → introducir un hub USB alimentado.

---

## Mantenimiento de cableado

- Revisar trimestralmente que los conectores USB **no estén holgados**: una carcasa con peso (3,5") puede aflojar la conexión con el tiempo.
- **No intercambiar** los discos entre puertos USB 3.0 sin haber desmontado antes los `mountpoints` (`umount /mnt/hd5t /mnt/hd2t`). Aunque el `fstab` use UUID, evita corrupciones por escrituras pendientes.
- Si se sustituye uno de los discos, mantener el mismo etiquetado (`hd5t` o `hd2t`) y reusar la misma estrategia: simplifica los `docker-compose.yml` que apuntan a `/mnt/hd5t` y `/mnt/hd2t`.

---

## Referencias

- Raspberry Pi 5 — Documentación oficial (puertos, alimentación, GPIO): <https://www.raspberrypi.com/documentation/computers/raspberry-pi-5.html>
- Raspberry Pi 5 — Especificaciones de hardware: <https://www.raspberrypi.com/products/raspberry-pi-5/specifications/>
- Configuración del ventilador PWM oficial: <https://www.raspberrypi.com/documentation/computers/raspberry-pi.html#cooling-the-raspberry-pi-5>
- Notas sobre interferencias USB 3.0 ↔ 2,4 GHz (whitepaper Intel): <https://www.intel.com/content/www/us/en/products/docs/io/universal-serial-bus/usb3-frequency-interference-paper.html>
- Adaptadores Zigbee compatibles (Zigbee2MQTT): <https://www.zigbee2mqtt.io/guide/adapters/>
- Diagrama de pinout GPIO de la Pi 5: <https://pinout.xyz/>
