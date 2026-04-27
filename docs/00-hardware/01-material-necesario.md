# Material Necesario

## Descripción

Lista completa de hardware necesario para montar el homelab sobre **Raspberry Pi 5 (8 GB)** con dos discos duros externos (`hd5t` y `hd2t`). El objetivo es un equipo silencioso, de bajo consumo y siempre encendido, capaz de servir el catálogo de aplicaciones definido en `SERVICES.md` mediante contenedores Docker.

> **Nota**: el homelab es de uso doméstico y acceso únicamente local (LAN + Tailscale). No requiere componentes específicos para exposición a internet (UPS opcional, sin appliances de red avanzados).

---

## Componentes obligatorios

| # | Componente | Especificación recomendada | Notas |
|---|------------|----------------------------|-------|
| 1 | **Raspberry Pi 5** | Modelo 8 GB RAM | Imprescindibles los 8 GB para sostener todos los stacks (Jellyfin, Nextcloud, Home Assistant, *arr, Prometheus, etc.) en paralelo. ARM64. |
| 2 | **Fuente de alimentación oficial** | 27 W USB-C PD (5,1 V / 5 A) | La fuente oficial de la Pi 5 es obligatoria para entregar 5 A a los periféricos USB sin throttling. Fuentes genéricas suelen limitar a 3 A y provocar `under-voltage detected`. |
| 3 | **microSD** | 64 GB clase A2 / U3 (SanDisk Extreme, Samsung Pro Endurance) | Sólo aloja Raspberry Pi OS Lite y el bootloader. Los datos persistentes y los volúmenes Docker viven en los discos externos. Se prioriza fiabilidad sobre tamaño. |
| 4 | **Disco duro externo `hd5t`** | 5 TB, 3,5" o 2,5", USB 3.0 / 3.1 (5 Gbps) | Dedicado a la **biblioteca multimedia de Stash**. Se monta en `/mnt/hd5t`. Recomendable carcasa con alimentación externa si es 3,5". |
| 5 | **Disco duro externo `hd2t`** | 2 TB, 2,5" autoalimentado por USB 3.0 | Aloja el resto de servicios: volúmenes Docker, Nextcloud, *arr, multimedia (Jellyfin/Navidrome/Audiobookshelf/Calibre-Web), Paperless, Bookstack, Linkding, FreshRSS, Mealie, Vaultwarden, monitorización, **y la partición de backups** (Borgmatic). |
| 6 | **Carcasa con disipación activa** | Carcasa metálica con ventilador PWM (Argon NEO 5, FLIRC, Pimoroni NVMe Base con fan, etc.) | La Pi 5 calienta notablemente bajo carga sostenida. Sin disipación activa entra en throttling térmico (>85 °C). El ventilador PWM oficial también vale. |
| 7 | **Cable Ethernet** | Cat 5e o Cat 6, 1 Gbps, longitud necesaria al router | Conexión por cable obligatoria para Pi-hole, Samba, Jellyfin y backups. WiFi solo como fallback de emergencia. |
| 8 | **Lector microSD** | USB / integrado en el equipo de flasheo | Necesario una sola vez para grabar la imagen con Raspberry Pi Imager. |

---

## Componentes opcionales

| Componente | Cuándo añadirlo | Notas |
|------------|-----------------|-------|
| **Adaptador Zigbee USB** (Sonoff Zigbee 3.0 Dongle Plus, ConBee II, SkyConnect) | Si se va a desplegar Zigbee2MQTT (Fase 8) | Conectar mediante alargador USB de al menos 1 m para alejarlo de la Pi (evita interferencias 2,4 GHz con WiFi/USB 3.0). |
| **SAI / UPS** (APC Back-UPS 400/650 VA o similar) | Si la red eléctrica tiene cortes frecuentes | Protege la microSD y los discos USB de corrupciones por apagones. Recomendable tener uno también para el router y el ONT. |
| **Disco SSD NVMe + HAT M.2** (Pimoroni NVMe Base, Argon NEO 5 M.2, Geekworm X1001/X1002) | Si se quiere mover el OS desde la microSD a SSD por durabilidad/rendimiento | Cambia la velocidad de I/O del sistema y de los volúmenes Docker. La microSD puede mantenerse como rescate. |
| **Hub USB 3.0 con alimentación externa** | Si los dos discos externos provocan caídas de tensión o desconexiones esporádicas | Aísla la corriente que demandan los discos del bus USB de la Pi. Útil sobre todo con dos discos 2,5" autoalimentados. |
| **Cables USB 3.0 cortos y de calidad** | Reemplazo de los cables de las carcasas si dan problemas | Cables baratos provocan errores `usb 2-1: device descriptor read/64, error -71` y desmontajes aleatorios. |
| **Etiquetas físicas** | Siempre recomendable | Etiquetar los dos discos como `hd5t` y `hd2t` para no confundirlos durante el mantenimiento físico. |

---

## Recomendaciones de compra

- **Raspberry Pi 5 + fuente oficial**: comprar siempre como kit oficial o en distribuidores autorizados (Mouser, RS, OKdo, Tiendatec). Evitar imitaciones.
- **microSD**: priorizar resistencia (`endurance`) sobre velocidad pico. Aunque el SO se moverá poco, el bootloader sufre escrituras.
- **Discos USB**: discos 2,5" autoalimentados son más cómodos pero algo más lentos; los 3,5" con alimentación propia son más rápidos y duraderos pero requieren enchufe adicional. Para `hd5t` (multimedia) un 3,5" es la opción más fiable.
- **Verificar antes de comprar** que las carcasas declaran soporte UASP y SMART pass-through; algunas carcasas baratas bloquean SMART y dificultan la monitorización (ver `docs/00-hardware/03-preparacion-discos.md`).
- **Refrigeración**: la Pi 5 sin fan llega a throttling en pocos minutos bajo carga. No es opcional para un equipo 24/7.

---

## Compatibilidad y limitaciones

- La Raspberry Pi 5 es **ARM64**: comprobar que cada imagen Docker tenga soporte `linux/arm64` antes de incorporar nuevos servicios.
- El bus USB 3.0 de la Pi 5 está compartido entre los dos puertos azules; con dos discos en uso intenso simultáneo (p. ej. backup de `hd2t` mientras Jellyfin lee de `hd5t`) se notará contención. No es bloqueante, pero conviene tenerlo en cuenta.
- La transcodificación por hardware en Jellyfin sobre Pi 5 es limitada; ver `docs/09-multimedia/01-jellyfin.md`.

---

## Referencias

- Raspberry Pi 5 — Especificaciones oficiales: <https://www.raspberrypi.com/products/raspberry-pi-5/>
- Fuente de alimentación oficial 27 W: <https://www.raspberrypi.com/products/27w-power-supply/>
- Raspberry Pi OS (descargas): <https://www.raspberrypi.com/software/operating-systems/>
- Raspberry Pi Imager: <https://www.raspberrypi.com/software/>
- Compatibilidad Zigbee2MQTT (adaptadores soportados): <https://www.zigbee2mqtt.io/guide/adapters/>
- Documentación oficial Pi 5 (refrigeración, USB, alimentación): <https://www.raspberrypi.com/documentation/computers/raspberry-pi-5.html>
