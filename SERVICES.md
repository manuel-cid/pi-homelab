# Servicios de un Homelab — Raspberry Pi 5

Catálogo de servicios recomendados para un homelab doméstico corriendo sobre **Raspberry Pi 5** (8 GB RAM, ARM64) con **dos discos duros externos conectados por USB** (2 TB y 5 TB). Todos los servicios se despliegan como contenedores Docker gestionados con **Docker Compose**.

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
          ├─► microSD 64 GB (SO + Docker)
          │
          ├─► HDD externo USB 2 TB — hd2t (datos de servicios, backups)
          │
          └─► HDD externo USB 5 TB — hd5t (contenidos multimedia de Stash)
```

### Recomendaciones de Hardware

- **Almacenamiento**:
  - **microSD 64 GB**: sistema operativo, Docker Engine, y ficheros de configuración del homelab (`docker-compose.yml`, `.env`, configs de cada servicio)
  - **HDD externo USB 2 TB (hd2t)**: volúmenes de datos persistentes de los servicios (bases de datos, uploads, logs) y backups — montado en `/mnt/hd2t`
  - **HDD externo USB 5 TB (hd5t)**: exclusivamente contenidos multimedia de **Stash** — montado en `/mnt/hd5t`
  - Ambos discos conectados vía **USB 3.0** a la Raspberry Pi 5 y montados de forma permanente (`/etc/fstab`)
- **RAM**: Modelo de 8 GB imprescindible para correr múltiples servicios
- **Refrigeración**: Disipador activo o carcasa con ventilador (la Pi 5 se calienta bajo carga)
- **Alimentación**: Fuente oficial USB-C de 27 W (5V/5A)
- **Red**: Ethernet Gigabit (preferir cable sobre WiFi para servicios de red)
- **Adaptador Zigbee**: SONOFF Zigbee 3.0 USB Dongle Plus (si se usa domótica)

### Estructura de Directorios y Política de Almacenamiento

```
microSD (/home/<user>/homelab/)          ← Configs, composes, envs
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
└── ...

/mnt/hd2t/                                ← Datos persistentes y backups
├── nextcloud/data/
├── postgres/data/
├── jellyfin/data/
├── paperless/data/
├── vaultwarden/data/
├── pihole/etc/
├── backups/
└── ...

/mnt/hd5t/                                ← Multimedia de Stash
└── stash/data/
```

> **Política**: los `docker-compose.yml` montan los volúmenes de datos apuntando a `/mnt/hd2t/...` o `/mnt/hd5t/...` según corresponda. Nunca almacenar datos persistentes con escritura intensiva (bases de datos, logs) en la microSD para evitar desgaste y corrupción.
