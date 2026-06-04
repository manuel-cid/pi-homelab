# Homelab — Raspberry Pi 5

Documentación completa para montar y operar un **homelab self-hosted** sobre una **Raspberry Pi 5 (8 GB)** con arranque desde **SSD NVMe**, dos discos USB de datos y gestión de servicios mediante **Docker Compose**.

## Filosofía del proyecto

- **Todo dockerizado**: cada servicio corre en contenedores gestionados por `docker compose`.
- **Stacks funcionales**: un `docker-compose.yml` por grupo lógico de servicios, no un monolito.
- **SSD NVMe para lo operativo**: sistema, configuraciones, bases de datos y volúmenes persistentes.
- **Discos USB para lo masivo**: multimedia, descargas y backups en `hd2t` (2 TB); biblioteca Stash en `hd5t` (5 TB).
- **LAN + Tailscale**: sin puertos abiertos a internet. Acceso remoto seguro vía Tailscale.
- **Backup 3-2-1**: datos en NVMe, copia local en `hd2t`, réplica cifrada offsite.

## Hardware

| Componente | Especificación |
|---|---|
| Raspberry Pi 5 | 8 GB RAM |
| Almacenamiento principal | SSD NVMe M.2 500 GB (PCIe, carcasa integrada) |
| Disco de datos `hd2t` | 2 TB USB 3.0 — multimedia, descargas, backups |
| Disco de datos `hd5t` | 5 TB USB 3.0 — biblioteca Stash |
| Alimentación | Fuente oficial USB-C 27 W |
| Red | Ethernet Gigabit |
| Domótica (opcional) | Adaptador Zigbee USB |

## Arquitectura de almacenamiento

```text
SSD NVMe 500 GB
└── /home/<user>/homelab/
    ├── compose/        # docker-compose.yml por stack
    ├── config/         # configuraciones editables
    ├── data/           # volúmenes persistentes por servicio
    ├── logs/
    ├── scripts/
    └── .env

hd2t (2 TB) → /media/hd2t/
├── media/              # Jellyfin, Navidrome, Audiobookshelf, Calibre-Web
├── downloads/          # descargas
└── backups/            # copias de seguridad del homelab

hd5t (5 TB) → /media/hd5t/
└── stash/              # biblioteca multimedia Stash
```

## Stack de servicios

### Red y DNS
- **Pi-hole** — bloqueo de publicidad y DNS local (`*.lan`)
- **Unbound** — resolver DNS recursivo privado
- **Caddy** — reverse proxy (HTTP en LAN, HTTPS vía Tailscale)
- **Tailscale** — VPN mesh para acceso remoto seguro
- **Macvlan** — red Docker con IP dedicada para Pi-hole/Unbound

### Seguridad
- **Authelia** — SSO y 2FA (TOTP) sobre el punto HTTPS de Tailscale
- **Fail2ban** — protección contra fuerza bruta

### Infraestructura Docker
- **Portainer** — gestión visual de contenedores y stacks
- **Watchtower** — actualización automática de imágenes (selectiva por etiqueta)

### Monitorización
- **Prometheus** — recolección de métricas
- **Grafana** — dashboards y visualización
- **Node Exporter** — métricas del host
- **Uptime Kuma** — monitorización de disponibilidad

### Multimedia
- **Jellyfin** — servidor de vídeo y TV
- **Navidrome** — servidor de música
- **Audiobookshelf** — audiolibros y podcasts
- **Calibre-Web** — biblioteca de ebooks
- **Stash** — biblioteca multimedia dedicada (disco `hd5t`)

### Descargas
- **Transmission** — cliente BitTorrent
- **Prowlarr** — gestor de indexadores
- **Sonarr** — gestión automática de series
- **Radarr** — gestión automática de películas

### Productividad
- **Vaultwarden** — gestor de contraseñas (compatible Bitwarden)
- **Linkding** — gestor de marcadores
- **Paperless-ngx** — gestión documental con OCR
- **Mealie** — recetas y planificación de comidas
- **Stirling-PDF** — herramientas PDF
- **FreshRSS** — lector de feeds RSS

### Almacenamiento y sincronización
- **Samba** — compartición de archivos en LAN
- **Syncthing** — sincronización entre dispositivos

### Domótica
- **Home Assistant** — automatización del hogar
- **Mosquitto** — broker MQTT
- **Zigbee2MQTT** — puente Zigbee
- **Node-RED** — flujos de automatización visual

### Backups
- **Borgmatic** — backups deduplicados y cifrados
- **Backup de volúmenes Docker** — procedimiento específico para datos de contenedores

### Dashboard
- **Homepage** — panel centralizado de acceso a servicios

## Estructura de la documentación

```
docs/
├── 00-hardware/         # Material, conexiones, discos y arranque NVMe
├── 01-sistema/          # Instalación OS, configuración inicial, seguridad base, directorios
├── 02-docker/           # Docker Engine, estructura Compose, Portainer, Watchtower
├── 03-red/              # Macvlan, Pi-hole, Unbound, Tailscale, Caddy, firewall
├── 04-seguridad/        # Authelia, Fail2ban
├── 05-monitorizacion/   # Prometheus, Grafana, Node Exporter, Uptime Kuma
├── 06-almacenamiento/   # Samba, Syncthing
├── 07-backups/          # Estrategia, Borgmatic, backup de volúmenes
├── 08-domotica/         # Home Assistant, Mosquitto, Zigbee2MQTT, Node-RED
├── 09-multimedia/       # Jellyfin, Navidrome, Audiobookshelf, Calibre-Web, Stash
├── 10-descargas/        # Transmission, Prowlarr, Sonarr, Radarr
├── 11-productividad/    # Vaultwarden, Linkding, Paperless-ngx, Mealie, Stirling-PDF, FreshRSS
├── 12-dashboards/       # Homepage
└── 13-operaciones/      # Mantenimiento, disaster recovery, rendimiento, red y puertos
```

Cada documento sigue un formato consistente: descripción, requisitos previos, objetivo, configuración paso a paso, notas de almacenamiento y backup.

## Orden de despliegue recomendado

1. **Hardware** — montar Pi 5, NVMe, discos USB y verificar conexiones
2. **Sistema** — instalar Raspberry Pi OS Lite 64-bit, configurar y migrar a NVMe
3. **Docker** — instalar Docker Engine, definir estructura Compose
4. **Red** — macvlan, Pi-hole + Unbound, Tailscale, Caddy
5. **Seguridad** — Authelia, Fail2ban, firewall
6. **Monitorización** — Prometheus, Grafana, Node Exporter, Uptime Kuma
7. **Almacenamiento** — Samba, Syncthing
8. **Backups** — estrategia 3-2-1, Borgmatic
9. **Servicios** — multimedia, descargas, productividad, domótica, dashboard
10. **Operaciones** — mantenimiento periódico, disaster recovery

## Acceso a servicios

| Vía | Mecanismo |
|---|---|
| **LAN** | HTTP plano mediante nombres `*.lan` resueltos por Pi-hole → Caddy |
| **Remoto** | HTTPS vía Tailscale MagicDNS (`pi-homelab.<tailnet>.ts.net`) → Caddy + Authelia |

## Licencia

Uso personal.
