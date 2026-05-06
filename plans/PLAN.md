# Plan de Documentación — Homelab Raspberry Pi 5

Plan maestro para redactar toda la documentación necesaria para montar el homelab definido en `SERVICES.md` sobre una **Raspberry Pi 5 (8 GB)** montada en una **carcasa con soporte NVMe** y un **SSD NVMe como almacenamiento principal del sistema**, junto con **dos discos duros externos conectados por USB**:

- **SSD NVMe** (500 GB, M.2 vía PCIe en carcasa) — sistema operativo, Docker Engine, configs, **datos persistentes de todos los servicios** (BD, volúmenes, uploads, logs)
- **hd2t** (2 TB, USB 3.0) — contenidos multimedia (Jellyfin, Navidrome, Audiobookshelf, Calibre-Web, descargas) y **backups**
- **hd5t** (5 TB, USB 3.0) — contenidos multimedia de Stash

> **Alcance de red**: el homelab es **solo acceso local (LAN) + Tailscale (VPN mesh)**. No hay exposición a internet, no se abren puertos en el router, no se usan certificados Let's Encrypt ni DDNS.

---

## Fase 0 — Hardware y Preparación Física

| Doc | Contenido |
|-----|-----------|
| `docs/00-hardware/01-material-necesario.md` | Lista de materiales: Raspberry Pi 5 8 GB, fuente oficial USB-C 27 W (5V/5A — imprescindible con NVMe), microSD 64 GB (solo arranque inicial), **carcasa cerrada con slot M.2 NVMe** (ej. Argon NEO 5 M.2 NVME ~35–45 €, Argon ONE V3 ~55–65 €), **SSD NVMe M.2 500 GB** (ej. Kingston NV2 ~35–40 €), disco duro externo **hd2t** (2 TB, USB 3.0), disco duro externo **hd5t** (5 TB, USB 3.0), cable Ethernet, adaptador Zigbee (opcional). Presupuesto upgrade NVMe: ~70–105 € |
| `docs/00-hardware/02-esquema-conexiones.md` | Diagrama físico de conexiones: Pi → SSD NVMe (M.2 en carcasa vía PCIe), Pi → discos duros USB, Pi → router (Ethernet Gigabit), Pi → adaptador Zigbee |
| `docs/00-hardware/03-preparacion-discos.md` | Particionado, formato (ext4), montaje automático (`fstab`), etiquetas (`hd5t`, `hd2t`), pruebas SMART, estrategia de uso (SSD NVMe: SO + Docker + datos de servicios, hd2t: multimedia + backups, hd5t: multimedia Stash) |
| `docs/00-hardware/04-discos-con-datos.md` | Instalación de discos externos **sin formatear** (con datos existentes): identificación, SMART, comprobación de integridad, montaje automático (`fstab`), soporte para ext4/NTFS/exFAT, ajuste de permisos |
| `docs/00-hardware/05-arranque-nvme.md` | Configuración del arranque desde NVMe: actualización de firmware (`rpi-eeprom-update`), cambio de boot order (`raspi-config`), clonación de microSD al SSD NVMe (`rpi-imager` / `dd` / `rsync`), retirada de microSD, verificación |

---

## Fase 1 — Sistema Operativo Base

| Doc | Contenido |
|-----|-----------|
| `docs/01-sistema/01-instalacion-os.md` | Flash de Raspberry Pi OS Lite 64-bit con Raspberry Pi Imager en microSD, configuración headless (SSH, usuario, WiFi de emergencia), migración posterior a SSD NVMe (→ ver `docs/00-hardware/05-arranque-nvme.md`). Estructura de discos según → ver `docs/00-hardware/03-preparacion-discos.md` |
| `docs/01-sistema/02-configuracion-inicial.md` | Primer arranque (desde NVMe tras migración), actualización del sistema, hostname, zona horaria, locale, configurar swap: **zram** como swap primario (compresión en RAM, prioridad alta) + **swapfile de 2 GB en SSD NVMe** como red de seguridad (prioridad baja, `swappiness=10`) — no usar swap en HDD USB (latencia alta, riesgo de desconexión, compite con I/O multimedia) |
| `docs/01-sistema/03-seguridad-base.md` | Cambio de contraseña, claves SSH, deshabilitar login con password, firewall (`ufw`/`nftables`), `fail2ban` básico a nivel de host (solo jail SSH — → ver `docs/04-seguridad/02-fail2ban.md` para jails de servicios), actualizaciones automáticas (`unattended-upgrades`). Reglas de firewall complementan → ver `docs/03-red/06-puertos-y-firewall.md` |
| `docs/01-sistema/04-estructura-directorios.md` | Estructura de carpetas: **SSD NVMe** (`/home/<user>/homelab/` — configs, composes, `.env`, `data/` con volúmenes de servicios), `/mnt/hd2t` (multimedia de Jellyfin/Navidrome/Audiobookshelf/Calibre-Web, descargas, backups), `/mnt/hd5t` (multimedia Stash). Política: el SSD almacena todo lo operativo, los HDDs solo multimedia y backups. Montaje permanente en `/etc/fstab` |

---

## Fase 2 — Docker y Orquestación

| Doc | Contenido |
|-----|-----------|
| `docs/02-docker/01-instalacion-docker.md` | Instalación de Docker Engine y Docker Compose en ARM64, post-install (grupo docker, autoarranque), verificación |
| `docs/02-docker/02-estructura-compose.md` | Estrategia de organización: un `docker-compose.yml` por stack vs monolito, red Docker compartida, convenciones de nombres, variables de entorno (`.env`) |
| `docs/02-docker/03-portainer.md` | Despliegue de Portainer CE, configuración inicial, gestión de stacks |
| `docs/02-docker/04-watchtower.md` | Despliegue de Watchtower, programación de actualizaciones, exclusiones, notificaciones |

---

## Fase 3 — Red y DNS

> **Estrategia de red**: Pi-hole + Unbound se despliegan en una **red macvlan** con IP propia en la LAN (ej. `192.168.1.2`) para evitar colisiones de puertos (53, 80) con Caddy y otros servicios. La IP de la Pi queda libre para el reverse proxy. No hay acceso desde internet.

| Doc | Contenido |
|-----|-----------|
| `docs/03-red/01-macvlan.md` | Creación de la red Docker macvlan: rango de IPs, subnet, gateway, interfaz padre (`eth0`), reserva de IP en el DHCP del router, interfaz macvlan-shim en el host para comunicación host↔contenedor macvlan |
| `docs/03-red/02-pihole.md` | Despliegue de Pi-hole en red macvlan con IP dedicada (→ ver `docs/03-red/01-macvlan.md`), configuración del router para usar esa IP como DNS, listas de bloqueo recomendadas, DNS local para servicios internos (ej. `jellyfin.lan`), DNS fallback en el host (`/etc/resolv.conf`) para evitar pérdida de resolución si Pi-hole cae. Resolver recursivo → ver `docs/03-red/03-unbound.md` |
| `docs/03-red/03-unbound.md` | Despliegue de Unbound como resolver recursivo en la misma red macvlan (→ ver `docs/03-red/01-macvlan.md`), integración con Pi-hole como upstream DNS (→ ver `docs/03-red/02-pihole.md`) |
| `docs/03-red/04-tailscale.md` | Instalación de Tailscale (host o contenedor), MagicDNS, acceso remoto a servicios vía VPN sin abrir puertos |
| `docs/03-red/05-caddy.md` | Despliegue de Caddy como reverse proxy interno, `Caddyfile` con bloques por servicio, HTTP plano en LAN (red confiable, sin necesidad de CA interna) y HTTPS automático solo para acceso remoto vía Tailscale (`tailscale cert`, ej. `pi.tailnet.ts.net`), configuración versionable en git |
| `docs/03-red/06-puertos-y-firewall.md` | Convención de asignación de puertos (rangos por tipo de servicio), reglas base de firewall (`ufw`/`nftables`), configuración del router (IP estática para la Pi, sin port forwarding). **Documento vivo**: se actualiza cada vez que se despliega un servicio nuevo. Referencia centralizada durante toda la instalación |

---

## Fase 4 — Seguridad

| Doc | Contenido |
|-----|-----------|
| `docs/04-seguridad/01-authelia.md` | Despliegue de Authelia, configuración SSO/2FA, integración como middleware en Caddy (`forward_auth` — → ver `docs/03-red/05-caddy.md` para actualización del `Caddyfile`) |
| `docs/04-seguridad/02-fail2ban.md` | Configuración avanzada de Fail2ban: jails adicionales para servicios (Vaultwarden, Authelia), integración con logs de contenedores (→ ver `docs/01-sistema/03-seguridad-base.md` para la instalación base). Protege → ver `docs/11-productividad/01-vaultwarden.md` y → ver `docs/04-seguridad/01-authelia.md` |

---

## Fase 5 — Monitorización y Observabilidad

| Doc | Contenido |
|-----|-----------|
| `docs/05-monitorizacion/01-prometheus.md` | Despliegue de Prometheus, `prometheus.yml`, targets, retención de datos en SSD NVMe |
| `docs/05-monitorizacion/02-grafana.md` | Despliegue de Grafana, datasource Prometheus (→ ver `docs/05-monitorizacion/01-prometheus.md`), dashboards recomendados (Node Exporter Full — → ver `docs/05-monitorizacion/03-node-exporter.md`, métricas Docker vía endpoint nativo de Docker Engine `/metrics`, temperatura Pi) |
| `docs/05-monitorizacion/03-node-exporter.md` | Despliegue de Node Exporter, métricas de sistema |
| `docs/05-monitorizacion/04-uptime-kuma.md` | Despliegue de Uptime Kuma, monitores por servicio, notificaciones (Telegram, email) |

---

## Fase 6 — Almacenamiento y Archivos

| Doc | Contenido |
|-----|-----------|
| `docs/06-almacenamiento/01-samba.md` | Despliegue de Samba, shares por carpeta en hd2t (multimedia) y opcionalmente hd5t (Stash), permisos, acceso desde Windows/Mac/Linux |
| `docs/06-almacenamiento/02-syncthing.md` | Despliegue de Syncthing, carpetas compartidas (SSD o hd2t según tipo de contenido), dispositivos pareados |

---

## Fase 7 — Copias de Seguridad

> **¿Por qué aquí y no antes?** La infraestructura de backup se documenta después de desplegar servicios con datos porque Borgmatic necesita conocer qué volúmenes y bases de datos respaldar (hooks de dump, rutas de volúmenes). Sin embargo, cada documento de servicio ya incluye su sección **Backup** indicando *qué* datos proteger — la Fase 7 documenta el *cómo* (herramienta, programación, retención, restauración). **Prioridad**: escribir `docs/07-backups/01-estrategia-backup.md` lo antes posible tras desplegar el primer servicio con datos persistentes.

| Doc | Contenido |
|-----|-----------|
| `docs/07-backups/01-estrategia-backup.md` | Estrategia 3-2-1: partición de backups en hd2t como destino local, nube como destino offsite, programación, retención, verificación de restauración |
| `docs/07-backups/02-borgmatic.md` | Despliegue de Borgmatic, configuración YAML, repos en hd2t, programación, hooks pre/post-backup (dumps de BD), notificaciones. Estrategia general → ver `docs/07-backups/01-estrategia-backup.md`. Procedimiento de volúmenes → ver `docs/07-backups/03-backup-docker-volumes.md` |
| `docs/07-backups/03-backup-docker-volumes.md` | Procedimiento para backup/restore de volúmenes Docker y bases de datos (dumps de MariaDB/PostgreSQL) |

---

## Fase 8 — Domótica e IoT

| Doc | Contenido |
|-----|-----------|
| `docs/08-domotica/01-home-assistant.md` | Despliegue de Home Assistant Container, configuración inicial, integraciones básicas |
| `docs/08-domotica/02-mosquitto.md` | Despliegue de Mosquitto MQTT, autenticación, ACLs |
| `docs/08-domotica/03-zigbee2mqtt.md` | Despliegue de Zigbee2MQTT, configuración del adaptador USB, emparejamiento de dispositivos |
| `docs/08-domotica/04-node-red.md` | Despliegue de Node-RED, flujos de ejemplo, integración con MQTT y Home Assistant |

---

## Fase 9 — Multimedia y Entretenimiento

| Doc | Contenido |
|-----|-----------|
| `docs/09-multimedia/01-jellyfin.md` | Despliegue de Jellyfin, datos de servicio en SSD NVMe, bibliotecas multimedia en **hd2t**, transcodificación por hardware (limitaciones ARM), acceso vía Caddy (→ ver `docs/03-red/05-caddy.md`) y Tailscale (→ ver `docs/03-red/04-tailscale.md`) |
| `docs/09-multimedia/02-navidrome.md` | Despliegue de Navidrome, datos de servicio en SSD NVMe, biblioteca de música en **hd2t**, clientes compatibles (DSub, Symfonium) |
| `docs/09-multimedia/03-audiobookshelf.md` | Despliegue de Audiobookshelf, datos de servicio en SSD NVMe, biblioteca de audiolibros/podcasts en **hd2t** |
| `docs/09-multimedia/04-calibre-web.md` | Despliegue de Calibre-Web, datos de servicio en SSD NVMe, biblioteca de ebooks en **hd2t**, importación de Calibre |
| `docs/09-multimedia/05-stash.md` | Despliegue de Stash, bibliotecas en **hd5t** (disco dedicado), scrapers de metadatos, configuración de rutas |

---

## Fase 10 — Gestión de Descargas

| Doc | Contenido |
|-----|-----------|
| `docs/10-descargas/01-transmission.md` | Despliegue de Transmission, directorio de descargas en **hd2t**, configuración de velocidad y peers |
| `docs/10-descargas/02-prowlarr.md` | Despliegue de Prowlarr, indexadores, integración con Sonarr/Radarr |
| `docs/10-descargas/03-sonarr.md` | Despliegue de Sonarr, perfiles de calidad, integración con Transmission |
| `docs/10-descargas/04-radarr.md` | Despliegue de Radarr, perfiles de calidad, integración con Transmission |

---

## Fase 11 — Productividad y Herramientas Personales

| Doc | Contenido |
|-----|-----------|
| `docs/11-productividad/01-vaultwarden.md` | Despliegue de Vaultwarden, HTTPS vía Caddy (→ ver `docs/03-red/05-caddy.md`), backup de la base de datos (→ ver `docs/07-backups/02-borgmatic.md`), protección con Fail2ban (→ ver `docs/04-seguridad/02-fail2ban.md`), clientes Bitwarden |
| `docs/11-productividad/02-linkding.md` | Despliegue de Linkding, datos en SSD NVMe, extensión de navegador |
| `docs/11-productividad/03-paperless-ngx.md` | Despliegue de Paperless-ngx, OCR, datos y carpeta de consumo en SSD NVMe, etiquetado |
| `docs/11-productividad/04-mealie.md` | Despliegue de Mealie, datos en SSD NVMe, importación de recetas |
| `docs/11-productividad/05-stirling-pdf.md` | Despliegue de Stirling PDF (stateless, sin datos persistentes) |
| `docs/11-productividad/06-freshrss.md` | Despliegue de FreshRSS, datos en SSD NVMe, importación de feeds OPML |

---

## Fase 12 — Dashboards

| Doc | Contenido |
|-----|-----------|
| `docs/12-dashboards/01-homepage.md` | Despliegue de Homepage, configuración de servicios, widgets, personalización |

---

## Fase 13 — Operaciones y Mantenimiento

| Doc | Contenido |
|-----|-----------|
| `docs/13-operaciones/01-mantenimiento-periodico.md` | Tareas semanales/mensuales: verificar backups, revisar logs, actualizar imágenes, comprobar salud de discos (SMART), limpieza de Docker (`docker system prune`) |
| `docs/13-operaciones/02-disaster-recovery.md` | Procedimiento de recuperación ante fallo: restaurar OS en SSD NVMe (→ ver `docs/00-hardware/05-arranque-nvme.md`), reinstalar Docker (→ ver `docs/02-docker/01-instalacion-docker.md`), restaurar datos de servicios y configs desde backups en hd2t (→ ver `docs/07-backups/02-borgmatic.md` y `docs/07-backups/03-backup-docker-volumes.md`), verificación de servicios |
| `docs/13-operaciones/03-rendimiento-pi5.md` | Tuning de la Pi 5: overclocking conservador, gestión de temperatura, priorización de servicios, límites de memoria por contenedor |
| `docs/13-operaciones/04-red-y-puertos.md` | Mapa consolidado final de puertos (verificación contra → ver `docs/03-red/06-puertos-y-firewall.md`), auditoría de conflictos, checklist de revisión periódica de reglas de firewall (→ ver `docs/01-sistema/03-seguridad-base.md`) |

---

## Convenciones para la Documentación

Cada documento de servicio debe seguir esta estructura estándar:

```markdown
# Nombre del Servicio

## Descripción
Breve descripción y propósito en el homelab.

## Requisitos Previos
- Dependencias de otros servicios/docs
- Puertos necesarios

## Docker Compose
Bloque `docker-compose.yml` completo y funcional.

## Configuración
Pasos post-despliegue, ajustes de la UI, integraciones.

## Almacenamiento
Volúmenes utilizados, rutas en disco externo, permisos.

## Backup
Qué respaldar (volúmenes, bases de datos, configuración).

## Referencias
Enlaces a documentación oficial e imágenes Docker.
```

---

## Lista de Tareas

### Fase 0 — Hardware y Preparación Física
- [ ] `docs/00-hardware/01-material-necesario.md`
- [ ] `docs/00-hardware/02-esquema-conexiones.md`
- [ ] `docs/00-hardware/03-preparacion-discos.md`
- [ ] `docs/00-hardware/04-discos-con-datos.md`
- [ ] `docs/00-hardware/05-arranque-nvme.md`

### Fase 1 — Sistema Operativo Base
- [ ] `docs/01-sistema/01-instalacion-os.md`
- [ ] `docs/01-sistema/02-configuracion-inicial.md`
- [ ] `docs/01-sistema/03-seguridad-base.md`
- [ ] `docs/01-sistema/04-estructura-directorios.md`

### Fase 2 — Docker y Orquestación
- [ ] `docs/02-docker/01-instalacion-docker.md`
- [ ] `docs/02-docker/02-estructura-compose.md`
- [ ] `docs/02-docker/03-portainer.md`
- [ ] `docs/02-docker/04-watchtower.md`

### Fase 3 — Red y DNS
- [ ] `docs/03-red/01-macvlan.md`
- [ ] `docs/03-red/02-pihole.md`
- [ ] `docs/03-red/03-unbound.md`
- [ ] `docs/03-red/04-tailscale.md`
- [ ] `docs/03-red/05-caddy.md`
- [ ] `docs/03-red/06-puertos-y-firewall.md`

### Fase 4 — Seguridad
- [ ] `docs/04-seguridad/01-authelia.md`
- [ ] `docs/04-seguridad/02-fail2ban.md`

### Fase 5 — Monitorización y Observabilidad
- [ ] `docs/05-monitorizacion/01-prometheus.md`
- [ ] `docs/05-monitorizacion/02-grafana.md`
- [ ] `docs/05-monitorizacion/03-node-exporter.md`
- [ ] `docs/05-monitorizacion/04-uptime-kuma.md`

### Fase 6 — Almacenamiento y Archivos
- [ ] `docs/06-almacenamiento/01-samba.md`
- [ ] `docs/06-almacenamiento/02-syncthing.md`

### Fase 7 — Copias de Seguridad
- [ ] `docs/07-backups/01-estrategia-backup.md`
- [ ] `docs/07-backups/02-borgmatic.md`
- [ ] `docs/07-backups/03-backup-docker-volumes.md`

### Fase 8 — Domótica e IoT
- [ ] `docs/08-domotica/01-home-assistant.md`
- [ ] `docs/08-domotica/02-mosquitto.md`
- [ ] `docs/08-domotica/03-zigbee2mqtt.md`
- [ ] `docs/08-domotica/04-node-red.md`

### Fase 9 — Multimedia y Entretenimiento
- [ ] `docs/09-multimedia/01-jellyfin.md`
- [ ] `docs/09-multimedia/02-navidrome.md`
- [ ] `docs/09-multimedia/03-audiobookshelf.md`
- [ ] `docs/09-multimedia/04-calibre-web.md`
- [ ] `docs/09-multimedia/05-stash.md`

### Fase 10 — Gestión de Descargas
- [ ] `docs/10-descargas/01-transmission.md`
- [ ] `docs/10-descargas/02-prowlarr.md`
- [ ] `docs/10-descargas/03-sonarr.md`
- [ ] `docs/10-descargas/04-radarr.md`

### Fase 11 — Productividad y Herramientas Personales
- [ ] `docs/11-productividad/01-vaultwarden.md`
- [ ] `docs/11-productividad/02-linkding.md`
- [ ] `docs/11-productividad/03-paperless-ngx.md`
- [ ] `docs/11-productividad/04-mealie.md`
- [ ] `docs/11-productividad/05-stirling-pdf.md`
- [ ] `docs/11-productividad/06-freshrss.md`

### Fase 12 — Dashboards
- [ ] `docs/12-dashboards/01-homepage.md`

### Fase 13 — Operaciones y Mantenimiento
- [ ] `docs/13-operaciones/01-mantenimiento-periodico.md`
- [ ] `docs/13-operaciones/02-disaster-recovery.md`
- [ ] `docs/13-operaciones/03-rendimiento-pi5.md`
- [ ] `docs/13-operaciones/04-red-y-puertos.md`
