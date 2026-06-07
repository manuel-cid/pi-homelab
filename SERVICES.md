# Servicios de un Homelab — Raspberry Pi 5

Catálogo de servicios recomendados para un homelab doméstico corriendo sobre **Raspberry Pi 5** (8 GB RAM, ARM64) montada en una **carcasa Argon ONE V3 M.2 NVME PCIe** y un **SSD NVMe de 500 GB como almacenamiento principal** (SO, Docker, datos de servicios), junto con **dos discos duros externos conectados por USB**: **hd2t** (2 TB — contenidos multimedia y backups) y **hd5t** (5 TB — biblioteca multimedia dedicada). El acceso es exclusivamente **LAN + Tailscale (VPN mesh)** — sin exposición a internet ni puertos abiertos en el router. Todos los servicios se despliegan como contenedores Docker gestionados con **Docker Compose**.

---

## 1. Infraestructura y Orquestación

| Servicio | Descripción |
|---|---|
| **Docker + Docker Compose** | Motor de contenedores y orquestador declarativo |
| **Portainer CE** | Panel web para gestionar contenedores, imágenes, volúmenes y redes |
| **WUD (What's Up Docker)** | Monitorización y actualización controlada de imágenes Docker |

---

## 2. Red y DNS

| Servicio | Descripción |
|---|---|
| **Pi-hole** | Servidor DNS con bloqueo de publicidad y telemetría a nivel de red |
| **Unbound** | Resolver DNS recursivo local (complementa a Pi-hole para no depender de DNS externos) |
| **Tailscale** | VPN mesh basada en WireGuard para acceso remoto seguro sin abrir puertos |
| **Caddy** | Reverse proxy interno con `network_mode: host`: HTTP en LAN (red confiable) y HTTPS para acceso remoto vía Tailscale, configuración declarativa vía Caddyfile. Usa `network_mode: host` para preservar la IP real de los clientes (necesario para Fail2ban y Authelia); los upstreams apuntan a `127.0.0.1:<puerto>` |

---

## 3. Monitorización y Observabilidad

| Servicio | Descripción |
|---|---|
| **Prometheus** | Recolección y almacenamiento de métricas de series temporales |
| **Grafana** | Dashboards y visualización de métricas (CPU, RAM, disco, red, temperatura) |
| **Node Exporter** | Exportador de métricas del sistema operativo hacia Prometheus |
| **Uptime Kuma** | Monitor de disponibilidad de servicios con notificaciones (Telegram, email, etc.) |

---

## 4. Almacenamiento y Archivos

| Servicio | Descripción |
|---|---|
| **Samba** | Compartición de archivos en red local (protocolo SMB/CIFS) |
| **Syncthing** | Sincronización peer-to-peer de carpetas entre dispositivos |

---

## 5. Copias de Seguridad

| Servicio | Descripción |
|---|---|
| **Borgmatic** | Backups automatizados con BorgBackup: deduplicación, cifrado, compresión, programación y notificaciones (configuración YAML) |

---

## 6. Domótica y IoT

| Servicio | Descripción |
|---|---|
| **Home Assistant** | Plataforma de automatización del hogar con integraciones para Zigbee, Z-Wave, MQTT, etc. |
| **Mosquitto** | Broker MQTT ligero para comunicación entre dispositivos IoT |
| **Zigbee2MQTT** | Puente entre dispositivos Zigbee y MQTT (requiere adaptador USB Zigbee) |
| **Node-RED** | Flujos de automatización visuales con soporte para MQTT, HTTP, Home Assistant, etc. |

---

## 7. Multimedia y Entretenimiento

| Servicio | Descripción |
|---|---|
| **Jellyfin** | Servidor multimedia (vídeo, música, fotos) — alternativa libre a Plex |
| **Navidrome** | Servidor de música compatible con la API de Subsonic |
| **Audiobookshelf** | Servidor de audiolibros y podcasts con seguimiento de progreso |
| **Calibre-Web** | Biblioteca de ebooks con interfaz web |
| **Stash** | Organizador y reproductor de contenido multimedia con etiquetado, scraping de metadatos y filtros |

---

## 8. Gestión de Descargas

| Servicio | Descripción |
|---|---|
| **Transmission** | Cliente BitTorrent ligero con interfaz web |
| **Prowlarr** | Gestor unificado de indexadores para Sonarr/Radarr |
| **Sonarr** | Gestión y descarga automatizada de series de TV |
| **Radarr** | Gestión y descarga automatizada de películas |

---

## 9. Productividad y Herramientas Personales

| Servicio | Descripción |
|---|---|
| **Vaultwarden** | Gestor de contraseñas compatible con Bitwarden (servidor ligero en Rust) |
| **Linkding** | Gestor de marcadores web ligero |
| **Paperless-ngx** | Gestión documental: escaneo, OCR, etiquetado y búsqueda de documentos |
| **Mealie** | Gestor de recetas de cocina con planificación de comidas y lista de compras |
| **Stirling PDF** | Herramienta web todo-en-uno para manipular PDFs |
| **FreshRSS** | Lector de feeds RSS autoalojado |

---

## 10. Dashboards y Páginas de Inicio

| Servicio | Descripción |
|---|---|
| **Homepage** | Dashboard configurable con integraciones de servicios y widgets |

---

## 11. Seguridad

| Servicio | Descripción |
|---|---|
| **Fail2ban** | Protección contra fuerza bruta: banea IPs tras intentos fallidos de login |
| **Authelia** | Autenticación SSO y 2FA como middleware para el reverse proxy |

---

## Notas de Arquitectura

```
LAN / Tailscale (VPN mesh)
  │
  └─► Raspberry Pi 5
          │
          ├─► Docker Engine
          │     ├─► Portainer (gestión)
          │     ├─► WUD (monitorización de actualizaciones)
          │     └─► todos los servicios en contenedores
          │
          ├─► Pi-hole + Unbound (DNS, red macvlan con IP propia)
          │
          ├─► Caddy (network_mode: host, ve IP real del cliente)
          │     ├─► Authelia (SSO/2FA) ─── 127.0.0.1:9091
          │     ├─► Vaultwarden ────────── 127.0.0.1:16006
          │     ├─► Jellyfin ──────────── 127.0.0.1:8096
          │     └─► ... (otros servicios en 127.0.0.1:<puerto>)
          │
          ├─► Prometheus + Grafana (monitorización)
          │
          ├─► SSD NVMe 500 GB (SO + Docker + configs + datos de servicios) — via M.2 en carcasa
          │
          ├─► HDD externo USB 2 TB — hd2t (contenidos multimedia + backups)
          │
          └─► HDD externo USB 5 TB — hd5t (biblioteca multimedia dedicada)
```

### Recomendaciones de Hardware

- **Carcasa seleccionada**: **Argon ONE V3 M.2 NVME PCIe** (~55–65 €) — carcasa cerrada premium de aluminio con ventilador controlado por software, slot M.2 2280 (key M) vía PCIe, puertos GPIO accesibles mediante tapa magnética, botón de encendido integrado
- **SSD NVMe M.2 2230/2242/2280**:
  - **Kingston NV2 500 GB** (NVMe PCIe Gen4, M.2 2280) — ~35–40 € — punto dulce para SO + Docker + datos de servicios con margen amplio — **verificado en la lista oficial de compatibilidad de Argon ONE V3**
  - Alternativas compatibles verificadas (ordenadas por recomendación):
    - **Samsung 980 500 GB** (Gen3, M.2 2280) — ~40 € — el más testeado por la comunidad, muy fiable — verificado por Argon, Pineberry Pi y SunFounder
    - **Kingston NV3 500 GB** (Gen4, M.2 2280) — ~35 € — sucesor del NV2, confirmado funcionando en Argon ONE V3 (foro Argon40)
    - **KIOXIA EXCERIA G2 500 GB** (Gen3, M.2 2280) — ~30–35 € — excelente relación calidad-precio, verificado por SunFounder y Pineberry Pi
    - **Samsung 970 EVO Plus 500 GB** (Gen3, M.2 2280) — ~45 € — controlador Samsung Phoenix, muy estable
    - **Samsung 980 PRO 500 GB** (Gen4, M.2 2280) — ~50 € — gama alta con DRAM cache + TLC, mayor durabilidad para escrituras intensivas
    - **Lexar NM710 500 GB** (Gen4, M.2 2280) — ~35 € — verificado compatible por Pineberry Pi y SunFounder
    - **ADATA Legend 700 512 GB** (Gen3, M.2 2280) — ~30–35 € — verificado por SunFounder
    - **TeamGroup MP33 512 GB** (Gen3, M.2 2280) — ~30 € — opción económica, verificado compatible
    - **PNY CS1030 500 GB** (Gen3, M.2 2280) — ~30 € — opción económica, verificado compatible
    - **Sabrent Rocket 4.0 500 GB** (Gen4, M.2 2280) — ~45 € — verificado por Pineberry Pi
  - Nota: la Raspberry Pi 5 soporta PCIe Gen2 x1 (velocidad máx. ~450 MB/s), pero cualquier SSD NVMe Gen3/Gen4 es compatible hacia atrás
  - **Ventaja sobre microSD**: velocidad de lectura/escritura ×10, mayor durabilidad, sin problemas de corrupción por escrituras intensivas
- **Almacenamiento**:
  - **SSD NVMe 500 GB**: sistema operativo (Raspberry Pi OS), Docker Engine, ficheros de configuración (`docker-compose.yml`, `.env`), y **datos persistentes de todos los servicios** (bases de datos, volúmenes, uploads, logs)
  - **HDD externo USB 2 TB (hd2t)**: contenidos multimedia organizados por tipo (vídeo, música, audiolibros, ebooks), descargas y **backups** — montado en `/media/hd2t`
  - **HDD externo USB 5 TB (hd5t)**: biblioteca multimedia dedicada — montado en `/media/hd5t`
  - Ambos discos HDD conectados vía **USB 3.0** a la Raspberry Pi 5 y montados de forma permanente (`/etc/fstab`)
  - Se mantiene una **microSD** solo para el arranque inicial (el bootloader de la Pi 5 permite arrancar directamente desde NVMe tras configurarlo)
- **RAM**: Modelo de 8 GB imprescindible para correr múltiples servicios
- **Refrigeración**: las carcasas cerradas recomendadas incluyen disipación pasiva (aluminio) y/o ventilador activo integrado — no se necesita refrigeración adicional
- **Alimentación**: Fuente oficial USB-C de 27 W (5V/5A) — **imprescindible** con NVMe ya que el disco consume energía adicional
- **Red**: Ethernet Gigabit (preferir cable sobre WiFi para servicios de red)
- **Adaptador Zigbee**: SONOFF Zigbee 3.0 USB Dongle Plus (si se usa domótica)

### Presupuesto estimado (upgrade NVMe)

| Componente | Modelo recomendado | Precio aprox. |
|---|---|---|
| Carcasa con M.2 NVMe | Argon ONE V3 M.2 NVME PCIe | ~55–65 € |
| SSD NVMe 500 GB | Kingston NV2 500 GB (M.2 2280) | ~35–40 € |
| **Total upgrade** | Argon ONE V3 + Kingston NV2 500 GB | **~90–105 €** |

> **Carcasa seleccionada**: **Argon ONE V3 M.2 NVME PCIe** — carcasa cerrada premium de aluminio con ventilador activo controlado por software, botón de encendido integrado, GPIO accesible y slot M.2 NVMe PCIe. La mejor opción para un homelab que necesita refrigeración fiable y acceso completo al hardware.

### Configuración del arranque desde NVMe

1. Arrancar la Pi 5 con Raspberry Pi OS desde microSD
2. Actualizar el firmware: `sudo rpi-eeprom-update -a && sudo reboot`
3. Configurar el orden de arranque para priorizar NVMe: `sudo raspi-config` → Advanced Options → Boot Order → NVMe/USB Boot
4. Clonar la microSD al SSD NVMe con `rpi-imager` o `dd` / `rsync`
5. Retirar la microSD y reiniciar — la Pi 5 arrancará directamente desde el SSD NVMe

### Estructura de Directorios y Política de Almacenamiento

```
SSD NVMe (/home/<user>/homelab/)          ← Configs, composes, envs, datos de servicios
├── .env                                  ← Variables globales
├── compose/                              ← docker-compose.yml por stack funcional
│   ├── <stack>/
│   │   ├── docker-compose.yml
│   │   └── .env
│   └── ...
├── config/                               ← Configuraciones editables por servicio
│   └── <servicio>/
├── data/                                 ← Datos persistentes de servicios
│   └── <servicio>/
├── logs/
└── scripts/

/media/hd2t/                              ← Contenidos multimedia + backups
├── media/
│   ├── movies/                           ← Películas
│   ├── tv/                               ← Series
│   ├── music/                            ← Biblioteca musical
│   ├── books/                            ← Ebooks y documentos
│   ├── audiobooks/                       ← Audiolibros
│   └── podcasts/                         ← Podcasts
├── downloads/                            ← Descargas temporales o finales
├── backups/                              ← Backups del homelab
└── ...

/media/hd5t/                              ← Biblioteca multimedia dedicada
└── media/
```

> **Política**: el **SSD NVMe** almacena todo lo necesario para que el homelab funcione (SO, Docker, configs, bases de datos, volúmenes de servicios). Los **HDDs externos** almacenan exclusivamente **contenidos multimedia** organizados por tipo de contenido (hd2t: vídeo, música, audiolibros, ebooks, descargas; hd5t: biblioteca dedicada) y **backups** (hd2t). Los `docker-compose.yml` montan las categorías de contenido que correspondan apuntando a `/media/hd2t/media/...` o `/media/hd5t/media/`, y los volúmenes de datos de servicios al SSD.
