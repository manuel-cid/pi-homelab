# Servicios de un Homelab — Raspberry Pi 5

Catálogo de servicios recomendados para un homelab doméstico corriendo sobre **Raspberry Pi 5** (8 GB RAM, ARM64). Todos los servicios se despliegan como contenedores Docker gestionados con **Docker Compose**.

---

## 1. Infraestructura y Orquestación

| Servicio | Descripción | Puerto(s) |
|---|---|---|
| **Docker + Docker Compose** | Motor de contenedores y orquestador declarativo | — |
| **Portainer CE** | Panel web para gestionar contenedores, imágenes, volúmenes y redes | `9443` |
| **Watchtower** | Actualización automática de imágenes Docker en ejecución | — |

---

## 2. Red y DNS

| Servicio | Descripción | Puerto(s) |
|---|---|---|
| **Pi-hole** | Servidor DNS con bloqueo de publicidad y telemetría a nivel de red | `53`, `80` |
| **Unbound** | Resolver DNS recursivo local (complementa a Pi-hole para no depender de DNS externos) | `5335` |
| **Tailscale** | VPN mesh basada en WireGuard para acceso remoto seguro sin abrir puertos | `41641/udp` |
| **Nginx Proxy Manager** | Reverse proxy con gestión de certificados SSL (Let's Encrypt) y UI web | `80`, `443`, `81` |
| **DuckDNS / Cloudflare DDNS** | Actualización dinámica de DNS para IP pública residencial | — |

---

## 3. Monitorización y Observabilidad

| Servicio | Descripción | Puerto(s) |
|---|---|---|
| **Prometheus** | Recolección y almacenamiento de métricas de series temporales | `9090` |
| **Grafana** | Dashboards y visualización de métricas (CPU, RAM, disco, red, temperatura) | `3000` |
| **Node Exporter** | Exportador de métricas del sistema operativo hacia Prometheus | `9100` |
| **cAdvisor** | Métricas de rendimiento de contenedores Docker | `8080` |
| **Uptime Kuma** | Monitor de disponibilidad de servicios con notificaciones (Telegram, email, etc.) | `3001` |
| **Dozzle** | Visor de logs de contenedores en tiempo real vía web | `9999` |

---

## 4. Almacenamiento y Archivos

| Servicio | Descripción | Puerto(s) |
|---|---|---|
| **Nextcloud** | Nube privada: sincronización de archivos, calendario, contactos y colaboración | `8443` |
| **Samba** | Compartición de archivos en red local (protocolo SMB/CIFS) | `445` |
| **Syncthing** | Sincronización peer-to-peer de carpetas entre dispositivos | `8384`, `22000` |
| **MinIO** | Almacenamiento de objetos compatible con S3 | `9000`, `9001` |

---

## 5. Copias de Seguridad

| Servicio | Descripción | Puerto(s) |
|---|---|---|
| **Duplicati** | Backups incrementales cifrados a destinos locales o en la nube (S3, B2, SFTP) | `8200` |
| **Restic** | Backup rápido, cifrado y deduplicado por línea de comandos | — |
| **Borgmatic** | Wrapper automatizado para BorgBackup con programación y notificaciones | — |

---

## 6. Domótica y IoT

| Servicio | Descripción | Puerto(s) |
|---|---|---|
| **Home Assistant** | Plataforma de automatización del hogar con integraciones para Zigbee, Z-Wave, MQTT, etc. | `8123` |
| **Mosquitto** | Broker MQTT ligero para comunicación entre dispositivos IoT | `1883`, `9001` |
| **Zigbee2MQTT** | Puente entre dispositivos Zigbee y MQTT (requiere adaptador USB Zigbee) | `8081` |
| **Node-RED** | Flujos de automatización visuales con soporte para MQTT, HTTP, Home Assistant, etc. | `1880` |


---

## 7. Multimedia y Entretenimiento

| Servicio | Descripción | Puerto(s) |
|---|---|---|
| **Jellyfin** | Servidor multimedia (vídeo, música, fotos) — alternativa libre a Plex | `8096` |
| **Navidrome** | Servidor de música compatible con la API de Subsonic | `4533` |
| **Audiobookshelf** | Servidor de audiolibros y podcasts con seguimiento de progreso | `13378` |
| **Calibre-Web** | Biblioteca de ebooks con interfaz web | `8083` |
| **Stash** | Organizador y reproductor de contenido multimedia para adultos con etiquetado, scraping de metadatos y filtros | `9998` |

---

## 8. Gestión de Descargas

| Servicio | Descripción | Puerto(s) |
|---|---|---|
| **Transmission** | Cliente BitTorrent ligero con interfaz web | `9091` |
| **Prowlarr** | Gestor unificado de indexadores para Sonarr/Radarr | `9696` |
| **Sonarr** | Gestión y descarga automatizada de series de TV | `8989` |
| **Radarr** | Gestión y descarga automatizada de películas | `7878` |

---

## 9. Productividad y Herramientas Personales

| Servicio | Descripción | Puerto(s) |
|---|---|---|
| **Vaultwarden** | Gestor de contraseñas compatible con Bitwarden (servidor ligero en Rust) | `8443` |
| **Bookstack** | Wiki interna / base de conocimiento con organización por libros y capítulos | `6875` |
| **Linkding** | Gestor de marcadores web ligero | `9090` |
| **Paperless-ngx** | Gestión documental: escaneo, OCR, etiquetado y búsqueda de documentos | `8000` |
| **Mealie** | Gestor de recetas de cocina con planificación de comidas y lista de compras | `9925` |
| **Stirling PDF** | Herramienta web todo-en-uno para manipular PDFs | `8080` |
| **FreshRSS** | Lector de feeds RSS autoalojado | `8082` |

---

## 10. Dashboards y Páginas de Inicio

| Servicio | Descripción | Puerto(s) |
|---|---|---|
| **Homepage** | Dashboard configurable con integraciones de servicios y widgets | `3000` |
| **Homarr** | Panel de inicio con widgets, integraciones y drag-and-drop | `7575` |

---

## 11. Seguridad

| Servicio | Descripción | Puerto(s) |
|---|---|---|
| **CrowdSec** | IDS/IPS colaborativo que bloquea IPs maliciosas basado en comportamiento comunitario | `8080`, `6060` |
| **Fail2ban** | Protección contra fuerza bruta: banea IPs tras intentos fallidos de login | — |
| **Authelia** | Autenticación SSO y 2FA como middleware para el reverse proxy | `9091` |

---

## Notas de Arquitectura

```
Internet
  │
  ├─► DuckDNS / Cloudflare (DDNS)
  │
  ├─► Router (port forward 80/443)
  │       │
  │       ▼
  │   Nginx Proxy Manager ──► Authelia (SSO/2FA)
  │       │
  │       ├─► Nextcloud
  │       ├─► Vaultwarden
  │       ├─► Jellyfin
  │       └─► ... (otros servicios)
  │
  └─► Tailscale (VPN mesh) ──► acceso directo a cualquier servicio
          │
     Raspberry Pi 5
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
          └─► microSD 64 GB (almacenamiento)
```

### Recomendaciones de Hardware

- **Almacenamiento**: microSD de 64 GB (considerar migrar a SSD USB 3.0 o NVMe via HAT en el futuro para mejor rendimiento y durabilidad)
- **RAM**: Modelo de 8 GB imprescindible para correr múltiples servicios
- **Refrigeración**: Disipador activo o carcasa con ventilador (la Pi 5 se calienta bajo carga)
- **Alimentación**: Fuente oficial USB-C de 27 W (5V/5A)
- **Red**: Ethernet Gigabit (preferir cable sobre WiFi para servicios de red)
- **Adaptador Zigbee**: SONOFF Zigbee 3.0 USB Dongle Plus (si se usa domótica)

### Orden de Despliegue Recomendado

1. **Docker + Portainer** — base de toda la infraestructura
2. **Pi-hole + Unbound** — DNS y bloqueo de anuncios
3. **Nginx Proxy Manager + Authelia** — acceso seguro a servicios
4. **Tailscale** — acceso remoto
5. **Watchtower** — actualizaciones automáticas
6. **Prometheus + Grafana + Uptime Kuma** — monitorización
7. **Vaultwarden** — contraseñas
8. **Nextcloud / Syncthing** — almacenamiento
9. **Home Assistant + Mosquitto** — domótica (si aplica)
10. **Resto de servicios** — según necesidad
