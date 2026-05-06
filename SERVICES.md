# Servicios de un Homelab — Raspberry Pi 5

Catálogo de servicios recomendados para un homelab doméstico corriendo sobre **Raspberry Pi 5** (8 GB RAM, ARM64) montada en una **carcasa con soporte NVMe** y un **SSD NVMe de 500 GB como almacenamiento principal** (SO, Docker, datos de servicios), junto con **dos discos duros externos conectados por USB**: **hd2t** (2 TB — contenidos multimedia y backups) y **hd5t** (5 TB — multimedia de Stash). Todos los servicios se despliegan como contenedores Docker gestionados con **Docker Compose**.

---

## 1. Infraestructura y Orquestación

| Servicio | Descripción |
|---|---|
| **Docker + Docker Compose** | Motor de contenedores y orquestador declarativo |
| **Portainer CE** | Panel web para gestionar contenedores, imágenes, volúmenes y redes |
| **Watchtower** | Actualización automática de imágenes Docker en ejecución |

---

## 2. Red y DNS

| Servicio | Descripción |
|---|---|
| **Pi-hole** | Servidor DNS con bloqueo de publicidad y telemetría a nivel de red |
| **Unbound** | Resolver DNS recursivo local (complementa a Pi-hole para no depender de DNS externos) |
| **Tailscale** | VPN mesh basada en WireGuard para acceso remoto seguro sin abrir puertos |
| **Caddy** | Reverse proxy con HTTPS automático (CA interna para LAN), configuración declarativa vía Caddyfile |

---

## 3. Monitorización y Observabilidad

| Servicio | Descripción |
|---|---|
| **Prometheus** | Recolección y almacenamiento de métricas de series temporales |
| **Grafana** | Dashboards y visualización de métricas (CPU, RAM, disco, red, temperatura) |
| **Node Exporter** | Exportador de métricas del sistema operativo hacia Prometheus |
| **cAdvisor** | Métricas de rendimiento de contenedores Docker |
| **Uptime Kuma** | Monitor de disponibilidad de servicios con notificaciones (Telegram, email, etc.) |
| **Dozzle** | Visor de logs de contenedores en tiempo real vía web |

---

## 4. Almacenamiento y Archivos

| Servicio | Descripción |
|---|---|
| **Nextcloud** | Nube privada: sincronización de archivos, calendario, contactos y colaboración |
| **Samba** | Compartición de archivos en red local (protocolo SMB/CIFS) |
| **Syncthing** | Sincronización peer-to-peer de carpetas entre dispositivos |
| **MinIO** | Almacenamiento de objetos compatible con S3 |

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
| **Bookstack** | Wiki interna / base de conocimiento con organización por libros y capítulos |
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
          │     ├─► Watchtower (actualizaciones)
          │     └─► todos los servicios en contenedores
          │
          ├─► Pi-hole + Unbound (DNS)
          │
          ├─► Prometheus + Grafana (monitorización)
          │
          ├─► Caddy ──► Authelia (SSO/2FA)
          │     ├─► Nextcloud
          │     ├─► Vaultwarden
          │     ├─► Jellyfin
          │     └─► ... (otros servicios)
          │
          ├─► SSD NVMe 500 GB (SO + Docker + configs + datos de servicios) — via M.2 en carcasa
          │
          ├─► HDD externo USB 2 TB — hd2t (contenidos multimedia + backups)
          │
          └─► HDD externo USB 5 TB — hd5t (contenidos multimedia de Stash)
```

### Recomendaciones de Hardware

- **Carcasa cerrada con NVMe** (presupuesto máx. 100 €):
  - **Argon NEO 5 M.2 NVME** (~35–45 €) — carcasa cerrada de aluminio para Pi 5, slot M.2 2280 (key M) vía PCIe, disipación pasiva por contacto con la carcasa metálica, diseño compacto y discreto
  - **Argon ONE V3 M.2 NVME** (~55–65 €) — carcasa cerrada premium de aluminio con ventilador controlado por software, slot M.2 2280, puertos GPIO accesibles mediante tapa magnética, botón de encendido integrado
  - **Geekworm X1001 (NASPi Lite)** (~40–50 €) — carcasa cerrada metálica con bahía M.2 NVMe, ventilador de 30 mm, indicador LED de actividad del disco
  - **Pineberry Pi HatDrive! Bottom + carcasa Flirc Pi 5** (~30 + 25 = ~55 €) — adaptador M.2 NVMe compacto bajo la Pi + carcasa cerrada de aluminio Flirc con excelente disipación pasiva
  - Precio orientativo de la carcasa cerrada: **~35–65 €**
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
  - **HDD externo USB 2 TB (hd2t)**: contenidos multimedia de Jellyfin, Navidrome, Audiobookshelf, Calibre-Web, descargas de Transmission/Sonarr/Radarr, y **backups** — montado en `/mnt/hd2t`
  - **HDD externo USB 5 TB (hd5t)**: exclusivamente contenidos multimedia de **Stash** — montado en `/mnt/hd5t`
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
| Carcasa cerrada con M.2 NVMe | Argon NEO 5 M.2 NVME (económica) | ~35–45 € |
| | Argon ONE V3 M.2 NVME (premium) | ~55–65 € |
| SSD NVMe 500 GB | Kingston NV2 500 GB (M.2 2280) | ~35–40 € |
| **Total upgrade (económico)** | Argon NEO 5 + Kingston NV2 500 GB | **~70–85 €** |
| **Total upgrade (premium)** | Argon ONE V3 + Kingston NV2 500 GB | **~90–105 €** |

> **Recomendación**: la **Argon NEO 5 M.2 NVME** ofrece la mejor relación calidad-precio para un homelab: carcasa cerrada, aluminio, NVMe integrado y por debajo de 50 €. Si prefieres ventilador activo y botón de encendido, la **Argon ONE V3** merece el extra.

### Configuración del arranque desde NVMe

1. Arrancar la Pi 5 con Raspberry Pi OS desde microSD
2. Actualizar el firmware: `sudo rpi-eeprom-update -a && sudo reboot`
3. Configurar el orden de arranque para priorizar NVMe: `sudo raspi-config` → Advanced Options → Boot Order → NVMe/USB Boot
4. Clonar la microSD al SSD NVMe con `rpi-imager` o `dd` / `rsync`
5. Retirar la microSD y reiniciar — la Pi 5 arrancará directamente desde el SSD NVMe

### Estructura de Directorios y Política de Almacenamiento

```
SSD NVMe (/home/<user>/homelab/)          ← Configs, composes, envs, datos de servicios
├── docker-compose.yml                    ← Compose principal (o por servicio)
├── .env                                  ← Variables globales
├── stash/
│   ├── docker-compose.yml
│   └── .env
├── pihole/
│   └── docker-compose.yml
├── nextcloud/
│   ├── docker-compose.yml
│   └── .env
├── jellyfin/
│   └── docker-compose.yml
├── data/                                ← Datos persistentes de servicios
│   ├── postgres/
│   ├── vaultwarden/
│   ├── paperless/
│   ├── pihole/
│   ├── nextcloud/
│   └── ...
└── ...

/mnt/hd2t/                                ← Contenidos multimedia + backups
├── jellyfin/media/                      ← Películas, series
├── navidrome/music/                     ← Música
├── audiobookshelf/data/                 ← Audiolibros, podcasts
├── calibre/library/                     ← Ebooks
├── transmission/downloads/              ← Descargas
├── backups/                             ← Backups de Borgmatic
└── ...

/mnt/hd5t/                                ← Multimedia de Stash
└── stash/data/
```

> **Política**: el **SSD NVMe** almacena todo lo necesario para que el homelab funcione (SO, Docker, configs, bases de datos, volúmenes de servicios). Los **HDDs externos** almacenan exclusivamente **contenidos multimedia** (hd2t: Jellyfin, Navidrome, Audiobookshelf, Calibre-Web, descargas; hd5t: Stash) y **backups** (hd2t). Los `docker-compose.yml` montan los volúmenes multimedia apuntando a `/mnt/hd2t/...` o `/mnt/hd5t/...`, y los volúmenes de datos de servicios al SSD.
