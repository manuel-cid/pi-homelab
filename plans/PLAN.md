# Plan de Documentación — Homelab Raspberry Pi 5

Plan maestro para redactar toda la documentación necesaria para montar el homelab definido en `SERVICES.md` sobre una **Raspberry Pi 5 (8 GB)** con **dos discos duros externos**:

- **hd5t** (5 TB) — contenidos multimedia de Stash
- **hd2t** (2 TB) — datos del resto de servicios y copias de seguridad

> **Alcance de red**: el homelab es **solo acceso local (LAN) + Tailscale (VPN mesh)**. No hay exposición a internet, no se abren puertos en el router, no se usan certificados Let's Encrypt ni DDNS.

---

## Fase 0 — Hardware y Preparación Física

| Doc | Contenido |
|-----|-----------|
| `docs/00-hardware/01-material-necesario.md` | Lista de materiales: Raspberry Pi 5 8 GB, fuente 27 W, microSD 64 GB, disco duro externo **hd5t** (5 TB, USB 3.0), disco duro externo **hd2t** (2 TB, USB 3.0), carcasa con ventilador, cable Ethernet, adaptador Zigbee (opcional) |
| `docs/00-hardware/02-esquema-conexiones.md` | Diagrama físico de conexiones: Pi → discos duros, Pi → router, Pi → adaptador Zigbee |
| `docs/00-hardware/03-preparacion-discos.md` | Particionado, formato (ext4), montaje automático (`fstab`), etiquetas (`hd5t`, `hd2t`), pruebas SMART, estrategia de uso (hd5t: multimedia Stash, hd2t: resto de servicios + backups) |

---

## Fase 1 — Sistema Operativo Base

| Doc | Contenido |
|-----|-----------|
| `docs/01-sistema/01-instalacion-os.md` | Flash de Raspberry Pi OS Lite 64-bit con Raspberry Pi Imager, configuración headless (SSH, usuario, WiFi de emergencia) |
| `docs/01-sistema/02-configuracion-inicial.md` | Primer arranque, actualización del sistema, hostname, zona horaria, locale, deshabilitar swap en microSD, configurar swap en hd2t |
| `docs/01-sistema/03-seguridad-base.md` | Cambio de contraseña, claves SSH, deshabilitar login con password, firewall (`ufw`/`nftables`), `fail2ban` básico a nivel de host (solo jail SSH), actualizaciones automáticas (`unattended-upgrades`) |
| `docs/01-sistema/04-estructura-directorios.md` | Estructura de carpetas en los discos externos: `/mnt/hd5t` (multimedia Stash), `/mnt/hd2t` (datos de servicios, volúmenes Docker, backups), permisos, ownership, directorios por servicio |

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
| `docs/03-red/02-pihole.md` | Despliegue de Pi-hole en red macvlan con IP dedicada, configuración del router para usar esa IP como DNS, listas de bloqueo recomendadas, DNS local para servicios internos (ej. `jellyfin.lan`), DNS fallback en el host (`/etc/resolv.conf`) para evitar pérdida de resolución si Pi-hole cae |
| `docs/03-red/03-unbound.md` | Despliegue de Unbound como resolver recursivo en la misma red macvlan, integración con Pi-hole (upstream DNS) |
| `docs/03-red/04-caddy.md` | Despliegue de Caddy como reverse proxy interno, `Caddyfile` con bloques por servicio, HTTPS con CA interna para acceso LAN (ej. `jellyfin.lan`) y `tailscale cert` para acceso remoto vía Tailscale (ej. `pi.tailnet.ts.net`), configuración versionable en git |
| `docs/03-red/05-tailscale.md` | Instalación de Tailscale (host o contenedor), MagicDNS, acceso remoto a servicios vía VPN sin abrir puertos |

---

## Fase 4 — Seguridad

| Doc | Contenido |
|-----|-----------|
| `docs/04-seguridad/01-authelia.md` | Despliegue de Authelia, configuración SSO/2FA, integración como middleware en Caddy (forward_auth) |
| `docs/04-seguridad/02-fail2ban.md` | Configuración avanzada de Fail2ban: jails adicionales para servicios (Nextcloud, Vaultwarden, Authelia), integración con logs de contenedores |

---

## Fase 5 — Monitorización y Observabilidad

| Doc | Contenido |
|-----|-----------|
| `docs/05-monitorizacion/01-prometheus.md` | Despliegue de Prometheus, `prometheus.yml`, targets, retención de datos en hd2t |
| `docs/05-monitorizacion/02-grafana.md` | Despliegue de Grafana, datasource Prometheus, dashboards recomendados (Node Exporter Full, Docker, temperatura Pi) |
| `docs/05-monitorizacion/03-node-exporter.md` | Despliegue de Node Exporter, métricas de sistema |
| `docs/05-monitorizacion/04-cadvisor.md` | Despliegue de cAdvisor, métricas de contenedores |
| `docs/05-monitorizacion/05-uptime-kuma.md` | Despliegue de Uptime Kuma, monitores por servicio, notificaciones (Telegram, email) |
| `docs/05-monitorizacion/06-dozzle.md` | Despliegue de Dozzle, visor de logs en tiempo real |

---

## Fase 6 — Almacenamiento y Archivos

| Doc | Contenido |
|-----|-----------|
| `docs/06-almacenamiento/01-nextcloud.md` | Despliegue de Nextcloud (con MariaDB/PostgreSQL + Redis), datos en hd2t, configuración de dominio, apps recomendadas |
| `docs/06-almacenamiento/02-samba.md` | Despliegue de Samba, shares por carpeta en hd2t (y opcionalmente hd5t para multimedia), permisos, acceso desde Windows/Mac/Linux |
| `docs/06-almacenamiento/03-syncthing.md` | Despliegue de Syncthing, carpetas compartidas en hd2t, dispositivos pareados |
| `docs/06-almacenamiento/04-minio.md` | Despliegue de MinIO, buckets, credenciales, uso como destino de backups |

---

## Fase 7 — Copias de Seguridad

| Doc | Contenido |
|-----|-----------|
| `docs/07-backups/01-estrategia-backup.md` | Estrategia 3-2-1: partición de backups en hd2t como destino local, nube como destino offsite, programación, retención, verificación de restauración |
| `docs/07-backups/02-borgmatic.md` | Despliegue de Borgmatic, configuración YAML, repos en hd2t, programación, hooks pre/post-backup (dumps de BD), notificaciones |
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
| `docs/09-multimedia/01-jellyfin.md` | Despliegue de Jellyfin, bibliotecas en hd2t, transcodificación por hardware (limitaciones ARM), acceso vía Caddy/Tailscale |
| `docs/09-multimedia/02-navidrome.md` | Despliegue de Navidrome, biblioteca de música en hd2t, clientes compatibles (DSub, Symfonium) |
| `docs/09-multimedia/03-audiobookshelf.md` | Despliegue de Audiobookshelf, biblioteca de audiolibros/podcasts en hd2t |
| `docs/09-multimedia/04-calibre-web.md` | Despliegue de Calibre-Web, biblioteca de ebooks en hd2t, importación de Calibre |
| `docs/09-multimedia/05-stash.md` | Despliegue de Stash, bibliotecas en **hd5t** (disco dedicado), scrapers de metadatos, configuración de rutas |

---

## Fase 10 — Gestión de Descargas

| Doc | Contenido |
|-----|-----------|
| `docs/10-descargas/01-transmission.md` | Despliegue de Transmission, directorio de descargas en hd2t, configuración de velocidad y peers |
| `docs/10-descargas/02-prowlarr.md` | Despliegue de Prowlarr, indexadores, integración con Sonarr/Radarr |
| `docs/10-descargas/03-sonarr.md` | Despliegue de Sonarr, perfiles de calidad, integración con Transmission |
| `docs/10-descargas/04-radarr.md` | Despliegue de Radarr, perfiles de calidad, integración con Transmission |

---

## Fase 11 — Productividad y Herramientas Personales

| Doc | Contenido |
|-----|-----------|
| `docs/11-productividad/01-vaultwarden.md` | Despliegue de Vaultwarden, HTTPS vía Caddy (CA local), backup de la base de datos, clientes Bitwarden |
| `docs/11-productividad/02-bookstack.md` | Despliegue de Bookstack, base de datos en hd2t, organización de documentación del propio homelab |
| `docs/11-productividad/03-linkding.md` | Despliegue de Linkding, datos en hd2t, extensión de navegador |
| `docs/11-productividad/04-paperless-ngx.md` | Despliegue de Paperless-ngx, OCR, carpeta de consumo en hd2t, etiquetado |
| `docs/11-productividad/05-mealie.md` | Despliegue de Mealie, datos en hd2t, importación de recetas |
| `docs/11-productividad/06-stirling-pdf.md` | Despliegue de Stirling PDF (stateless, sin datos persistentes) |
| `docs/11-productividad/07-freshrss.md` | Despliegue de FreshRSS, datos en hd2t, importación de feeds OPML |

---

## Fase 12 — Dashboards

| Doc | Contenido |
|-----|-----------|
| `docs/12-dashboards/01-homepage.md` | Despliegue de Homepage, configuración de servicios, widgets, personalización |
| `docs/12-dashboards/02-homarr.md` | Despliegue de Homarr, integraciones, layout |

---

## Fase 13 — Operaciones y Mantenimiento

| Doc | Contenido |
|-----|-----------|
| `docs/13-operaciones/01-mantenimiento-periodico.md` | Tareas semanales/mensuales: verificar backups, revisar logs, actualizar imágenes, comprobar salud de discos (SMART), limpieza de Docker (`docker system prune`) |
| `docs/13-operaciones/02-disaster-recovery.md` | Procedimiento de recuperación ante fallo: restaurar OS, reinstalar Docker, restaurar volúmenes desde hd2t (backups), verificación de servicios |
| `docs/13-operaciones/03-rendimiento-pi5.md` | Tuning de la Pi 5: overclocking conservador, gestión de temperatura, priorización de servicios, límites de memoria por contenedor |
| `docs/13-operaciones/04-red-y-puertos.md` | Mapa completo de puertos usados, reglas de firewall, configuración del router (IP estática para la Pi, sin port forwarding) |

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

## Troubleshooting
Problemas comunes y soluciones.

## Referencias
Enlaces a documentación oficial e imágenes Docker.
```

---

## Lista de Tareas

### Fase 0 — Hardware y Preparación Física
- [ ] `docs/00-hardware/01-material-necesario.md`
- [ ] `docs/00-hardware/02-esquema-conexiones.md`
- [ ] `docs/00-hardware/03-preparacion-discos.md`

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
- [ ] `docs/03-red/04-caddy.md`
- [ ] `docs/03-red/05-tailscale.md`

### Fase 4 — Seguridad
- [ ] `docs/04-seguridad/01-authelia.md`
- [ ] `docs/04-seguridad/02-fail2ban.md`

### Fase 5 — Monitorización y Observabilidad
- [ ] `docs/05-monitorizacion/01-prometheus.md`
- [ ] `docs/05-monitorizacion/02-grafana.md`
- [ ] `docs/05-monitorizacion/03-node-exporter.md`
- [ ] `docs/05-monitorizacion/04-cadvisor.md`
- [ ] `docs/05-monitorizacion/05-uptime-kuma.md`
- [ ] `docs/05-monitorizacion/06-dozzle.md`

### Fase 6 — Almacenamiento y Archivos
- [ ] `docs/06-almacenamiento/01-nextcloud.md`
- [ ] `docs/06-almacenamiento/02-samba.md`
- [ ] `docs/06-almacenamiento/03-syncthing.md`
- [ ] `docs/06-almacenamiento/04-minio.md`

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
- [ ] `docs/11-productividad/02-bookstack.md`
- [ ] `docs/11-productividad/03-linkding.md`
- [ ] `docs/11-productividad/04-paperless-ngx.md`
- [ ] `docs/11-productividad/05-mealie.md`
- [ ] `docs/11-productividad/06-stirling-pdf.md`
- [ ] `docs/11-productividad/07-freshrss.md`

### Fase 12 — Dashboards
- [ ] `docs/12-dashboards/01-homepage.md`
- [ ] `docs/12-dashboards/02-homarr.md`

### Fase 13 — Operaciones y Mantenimiento
- [ ] `docs/13-operaciones/01-mantenimiento-periodico.md`
- [ ] `docs/13-operaciones/02-disaster-recovery.md`
- [ ] `docs/13-operaciones/03-rendimiento-pi5.md`
- [ ] `docs/13-operaciones/04-red-y-puertos.md`
