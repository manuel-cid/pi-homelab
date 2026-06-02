# Red y Puertos

## Descripción

Este documento consolida el **mapa operativo final de puertos** del homelab y sirve como referencia de mantenimiento para revisar qué está realmente expuesto en el host, qué vive solo en `loopback`, qué usa IP propia en `macvlan` y qué puertos son solo internos de Docker.

Su objetivo en esta fase no es rediseñar la arquitectura, sino dejar clara una regla práctica:

- para operación diaria, este documento y los documentos específicos de cada servicio mandan sobre reservas antiguas
- [06-puertos-y-firewall.md](../03-red/06-puertos-y-firewall.md) sigue siendo la política base y el registro de convenciones
- cualquier puerto publicado en el host debe seguir teniendo una razón explícita
- cualquier deriva entre la política base y el despliegue real debe quedar auditada

En este homelab, la exposición sigue limitada a **LAN + Tailscale**. No hay publicación WAN, no hay `port forwarding` en el router y no se abre ningún puerto hacia internet.

## Requisitos Previos

- Haber completado [03-seguridad-base.md](../01-sistema/03-seguridad-base.md).
- Haber completado [06-puertos-y-firewall.md](../03-red/06-puertos-y-firewall.md).
- Haber completado [01-mantenimiento-periodico.md](01-mantenimiento-periodico.md).
- Tener acceso administrativo por **SSH** al host.
- Tener disponibles en el host estas herramientas:
  - `ss`
  - `ip`
  - `docker`
  - `docker compose`
  - `ufw` o `nft`
  - `grep`, `awk`, `sort`
- Tener identificadas las superficies de red del proyecto:
  - IP LAN del host
  - interfaz `tailscale0`
  - IP macvlan de **Pi-hole**
  - IP macvlan de **Unbound**

Puertos necesarios en esta fase:

- ninguno adicional a los ya documentados en el proyecto

## Docker Compose

No aplica en este documento. Aquí se consolida el estado de puertos, la auditoría de conflictos y el procedimiento periódico de revisión del firewall.

## Configuración

### 1. Orden de precedencia para operar

Para evitar confusión entre reservas antiguas y puertos reales, usa este orden:

1. este documento como **mapa operativo consolidado**
2. el documento específico del servicio cuando detalle el `bind` y el puerto publicado
3. [06-puertos-y-firewall.md](../03-red/06-puertos-y-firewall.md) como política base, convención de rangos y referencia histórica

Interpretación práctica:

- si un servicio ya tiene documento propio con un puerto concreto, ese es el puerto operativo real
- si [06-puertos-y-firewall.md](../03-red/06-puertos-y-firewall.md) reservó otro puerto distinto, eso se trata como **deriva documental**, no como orden de cambiar el servicio sin revisión
- si un puerto aparece escuchando en el host y no aparece ni aquí ni en el documento del servicio, se trata como incidencia de revisión

### 2. Mapa consolidado final de superficies y puertos

#### 2.1 Infraestructura base fija

| Ámbito | Superficie / IP | Puerto | Servicio | Exposición prevista |
|-------|------------------|--------|----------|---------------------|
| Host | IP LAN del host | `22/tcp` | SSH | LAN |
| Host | IP Tailscale del host | `22/tcp` | SSH | Tailscale |
| Host | IP LAN del host | `80/tcp` | Caddy | LAN |
| Host | IP Tailscale del host | `443/tcp` | Caddy | Tailscale |
| Macvlan | IP de Pi-hole | `53/tcp` | Pi-hole | LAN |
| Macvlan | IP de Pi-hole | `53/udp` | Pi-hole | LAN |
| Macvlan | IP de Pi-hole | `80/tcp` | Pi-hole | LAN |
| Macvlan | IP de Unbound | `5335/tcp` | Unbound | interno DNS |
| Macvlan | IP de Unbound | `5335/udp` | Unbound | interno DNS |

Estas entradas siguen siendo la base del diseño de red del proyecto y coinciden con [06-puertos-y-firewall.md](../03-red/06-puertos-y-firewall.md).

#### 2.2 Puertos publicados actualmente en el host

| Puerto | Protocolo | Servicio | Estado documental actual | Exposición prevista |
|-------|-----------|----------|---------------------------|---------------------|
| `9443` | TCP | Portainer | publicado en `0.0.0.0` | LAN + Tailscale |
| `8096` | TCP | Jellyfin | publicado en `0.0.0.0` | LAN + Tailscale |
| `9090` | TCP | Linkding | publicado en `0.0.0.0` | LAN + Tailscale |
| `12000` | TCP | Syncthing GUI | publicado en `0.0.0.0` | LAN + Tailscale |
| `13378` | TCP | Audiobookshelf | publicado en `0.0.0.0` | LAN + Tailscale |
| `137` | UDP | Samba | publicado en `0.0.0.0` | LAN |
| `138` | UDP | Samba | publicado en `0.0.0.0` | LAN |
| `139` | TCP | Samba | publicado en `0.0.0.0` | LAN |
| `445` | TCP | Samba | publicado en `0.0.0.0` | LAN |
| `14001` | TCP | Navidrome | publicado en `0.0.0.0` | LAN + Tailscale |
| `14003` | TCP | Calibre-Web | publicado en `0.0.0.0` | LAN + Tailscale |
| `14004` | TCP | Stash | publicado en `0.0.0.0` | LAN + Tailscale |
| `15000` | TCP | Transmission Web UI | publicado en `0.0.0.0` | LAN + Tailscale |
| `15001` | TCP | Prowlarr | publicado en `0.0.0.0` | LAN + Tailscale |
| `15002` | TCP | Sonarr | publicado en `0.0.0.0` | LAN + Tailscale |
| `15003` | TCP | Radarr | publicado en `0.0.0.0` | LAN + Tailscale |
| `16002` | TCP | Paperless-ngx | publicado en `0.0.0.0` | LAN + Tailscale |
| `16003` | TCP | Mealie | publicado en `0.0.0.0` | LAN + Tailscale |
| `16004` | TCP | Stirling PDF | publicado en `0.0.0.0` | LAN + Tailscale |
| `16005` | TCP | FreshRSS | publicado en `0.0.0.0` | LAN + Tailscale |
| `17000` | TCP | Homepage | publicado en `0.0.0.0` | LAN + Tailscale |
| `22000` | TCP | Syncthing sync | publicado en `0.0.0.0` | LAN + Tailscale |
| `22000` | UDP | Syncthing sync | publicado en `0.0.0.0` | LAN + Tailscale |
| `21027` | UDP | Syncthing discovery | publicado en `0.0.0.0` | LAN |
| `51413` | TCP | Transmission peers | publicado en `0.0.0.0` | LAN + Tailscale |
| `51413` | UDP | Transmission peers | publicado en `0.0.0.0` | LAN + Tailscale |

Lectura operativa:

- todo puerto de esta tabla requiere revisión explícita en el firewall del host
- si un servicio deja de necesitar acceso directo, lo correcto es moverlo a `127.0.0.1` o dejarlo solo detrás de **Caddy**
- en el estado actual de la documentación, varios servicios siguen expuestos directamente además de poder vivir detrás de Caddy

#### 2.3 Puertos publicados solo en loopback

| Bind | Puerto | Servicio | Motivo |
|------|--------|----------|--------|
| `127.0.0.1` | `11000/tcp` | Prometheus | acceso local o vía proxy, no LAN directa |
| `127.0.0.1` | `11002/tcp` | Uptime Kuma | acceso local o vía proxy, no LAN directa |
| `127.0.0.1` | `13000/tcp` | Grafana | acceso local o vía proxy, no LAN directa |
| `127.0.0.1` | `18080/tcp` | `infra-port-policy-test` | validación temporal de política de puertos |

Estos puertos **no** deberían requerir aperturas generales en `ufw` o `nftables` para la LAN. Si aparecen escuchando en `0.0.0.0`, hay deriva real de seguridad.

#### 2.4 Puertos solo internos de Docker o de upstream

| Puerto interno | Servicio | Nota |
|---------------|----------|------|
| `80/tcp` | Vaultwarden | publicado detrás de Caddy, no directo en host |
| `9091/tcp` | Authelia | backend interno para Caddy |
| `9100/tcp` | Node Exporter | expuesto solo a otras redes Docker |
| `9090/tcp` | Prometheus | puerto interno del contenedor; no confundir con `9090/tcp` del host usado por Linkding |
| `3000/tcp` | Grafana | puerto interno del contenedor; el host usa `13000/tcp` en loopback |
| `3001/tcp` | Uptime Kuma | puerto interno del contenedor; el host usa `11002/tcp` en loopback |
| `9999/tcp` | Stash | puerto interno del contenedor; el host publica `14004/tcp` |

Estos puertos no deben convertirse en reglas de firewall del host salvo que un documento de servicio cambie expresamente su política de publicación.

### 3. Auditoría de conflictos y deriva documental

#### 3.1 Resultado general

No se detectan **colisiones directas de puertos publicados en el host** entre los documentos de servicio revisados. Sí existe **deriva** entre la convención inicial de [06-puertos-y-firewall.md](../03-red/06-puertos-y-firewall.md) y varios documentos posteriores.

Eso significa:

- hoy el homelab puede operar sin conflictos de escucha obvios si se despliega tal como está documentado
- pero una futura ampliación puede reintroducir choques si alguien reutiliza reservas antiguas sin mirar este consolidado

#### 3.2 Derivas concretas detectadas

| Caso | Reserva en Fase 3 | Estado real documentado | Lectura operativa | Acción recomendada |
|------|-------------------|-------------------------|-------------------|--------------------|
| Portainer | `10001/tcp` | `9443/tcp` en host | prevalece el puerto real de Portainer | mantener `9443` como referencia actual |
| Jellyfin | `14000/tcp` | `8096/tcp` en host | se usa el puerto estándar del servicio | no reservar `14000` como si Jellyfin lo usara ya |
| Audiobookshelf | `14002/tcp` | `13378/tcp` en host | se usa el puerto estándar del servicio | documentar `13378` como canon operativo |
| Linkding | `16001/tcp` | `9090/tcp` en host | se usa el puerto estándar del servicio | tratar `16001` como reserva no materializada |
| Grafana | `11001/tcp` | `13000/tcp` en `127.0.0.1` | hay deriva de rango y de clasificación | no asignar `13000` a otro servicio sin revisar |

#### 3.3 Riesgos de conflicto futuros

Los puntos que merecen más atención son estos:

- `13000/tcp` aparece reservado en Fase 3 para **Home Assistant**, pero hoy está asignado a **Grafana** en `127.0.0.1`
- `11001/tcp`, que Fase 3 proponía para **Grafana**, queda libre en la práctica
- `14000/tcp`, `14002/tcp` y `16001/tcp` siguen pareciendo libres si alguien mira solo la tabla antigua, aunque los servicios equivalentes ya usan otros puertos reales
- muchos servicios siguen documentados con `BIND_IP=0.0.0.0`, lo que amplía la superficie de ataque respecto a la política más estricta de “`127.0.0.1` + Caddy”

Conclusión operativa:

- no hay que cambiar puertos a ciegas solo para “hacerlos coincidir” con Fase 3
- sí hay que usar este documento como control previo antes de publicar nuevos servicios o abrir nuevas reglas de firewall

### 4. Checklist periódico de revisión de red y firewall

#### 4.1 Frecuencia recomendada

| Frecuencia | Revisión |
|-----------|----------|
| Mensual | comprobar puertos escuchando, reglas de firewall y puertos Docker publicados |
| Tras desplegar un servicio nuevo | verificar que el puerto coincide con su documento y que no pisa uno existente |
| Tras mover un servicio detrás de Caddy | cerrar el puerto directo si ya no hace falta |
| Tras cambios en Tailscale, Caddy o Samba | validar acceso real desde LAN y desde tailnet |

#### 4.2 Comprobación rápida del estado real

Ejecuta al menos esto:

```bash
date
hostnamectl
ip -brief address
ss -ltnup
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
```

Qué debes validar:

- `22`, `80` y `443` siguen donde toca
- no aparece ningún puerto inesperado publicado por Docker
- los puertos en `127.0.0.1` no han pasado a `0.0.0.0`
- las IPs macvlan siguen separadas del host

#### 4.3 Revisión de firewall en el host

Si usas `ufw`:

```bash
sudo ufw status numbered
sudo ufw status verbose
```

Si usas `nftables`:

```bash
sudo nft list ruleset
```

Qué debes confirmar:

- la política por defecto sigue siendo restrictiva
- `22/tcp` y `80/tcp` están permitidos solo donde corresponde
- `443/tcp` sigue limitado a `tailscale0` si mantienes el diseño actual
- los puertos directos de servicios adicionales existen solo si su exposición sigue siendo intencional
- no quedan reglas antiguas de pruebas, bootstrap o migraciones

#### 4.4 Revisión de deriva entre Docker y firewall

Los puertos de Docker y las reglas del firewall deben compararse juntos, no por separado.

Comprobación mínima:

```bash
docker ps --format '{{.Names}}\t{{.Ports}}' | sort
ss -ltnup | sort
```

Señales de alerta:

- un contenedor publica un puerto nuevo y no existe decisión explícita sobre su exposición
- un puerto sigue permitido en el firewall aunque ya no haya ningún servicio escuchando
- un servicio pasó a Caddy o a `127.0.0.1`, pero el firewall sigue conservando reglas de acceso directo

#### 4.5 Revisión específica de LAN, Tailscale y router

Checklist operativo:

- comprobar que **LAN** accede a `http://<servicio>.lan` o al puerto directo esperado
- comprobar que **Tailscale** accede a `https://pi-homelab.<tailnet>.ts.net/` y a los servicios remotos previstos
- confirmar que el router sigue sin `port forwarding` hacia la Raspberry Pi
- confirmar que `UPnP` sigue deshabilitado si esa es la política elegida

Validaciones útiles:

```bash
tailscale status
curl -I http://127.0.0.1
curl -I https://pi-homelab.<tailnet>.ts.net/healthz
```

#### 4.6 Regla de cierre tras cambios

Cada vez que añadas, cambies o elimines un puerto:

1. actualiza el documento del servicio
2. revisa este consolidado
3. ajusta `ufw` o `nftables`
4. valida `ss -ltnup` y `docker ps`
5. confirma acceso real desde la superficie prevista

Si uno de esos pasos no se hace, el inventario de puertos deja de ser fiable.

## Almacenamiento

Los archivos y rutas que forman parte del estado operativo de red y puertos son estos:

- este documento: `/Users/x441425/workspace2/homelab/docs/13-operaciones/04-red-y-puertos.md`
- la política base: `/Users/x441425/workspace2/homelab/docs/03-red/06-puertos-y-firewall.md`
- hardening base del host: `/Users/x441425/workspace2/homelab/docs/01-sistema/03-seguridad-base.md`
- ficheros `.env` de cada stack que definan `BIND_IP` y puertos publicados
- configuración de **Caddy**
- configuración de **Tailscale**
- configuración del firewall del host:
  - `/etc/ufw/` si usas `ufw`
  - `/etc/nftables.conf` si usas `nftables`
  - `/etc/fail2ban/` si alguna jail depende de rutas o exposición concreta

## Backup

En esta fase no hay una base de datos propia que respaldar, pero sí conviene proteger:

- este documento y la política base de puertos
- los `docker-compose.yml` y `.env` donde se define cada publicación `ports:`
- la configuración activa de `ufw` o `nftables`
- el `Caddyfile` y cualquier configuración que cambie la superficie expuesta

En una recuperación del host, restaurar datos sin restaurar la política de puertos y firewall deja el homelab funcional pero no necesariamente seguro ni coherente.

## Referencias

- [03-seguridad-base.md](../01-sistema/03-seguridad-base.md)
- [06-puertos-y-firewall.md](../03-red/06-puertos-y-firewall.md)
- [01-mantenimiento-periodico.md](01-mantenimiento-periodico.md)
- Docker Docs: [Publishing and exposing ports](https://docs.docker.com/get-started/docker-concepts/running-containers/publishing-ports/)
- Docker Docs: [Packet filtering and firewalls](https://docs.docker.com/engine/network/packet-filtering-firewalls/)
- Tailscale Docs: [MagicDNS](https://tailscale.com/kb/1081/magicdns)
