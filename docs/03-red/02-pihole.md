# Pi-hole en Red Macvlan

## Descripción

Este documento cubre el despliegue de **Pi-hole** como resolvedor DNS con filtrado para toda la LAN usando una **IP propia dentro de la red `dns_lan`** definida en [01-macvlan.md](01-macvlan.md).

El objetivo es que:

- los clientes de la red usen **Pi-hole** como DNS principal mediante DHCP del router
- **Pi-hole** escuche en su propia IP LAN, sin publicar `53` ni `80` en la IP del host
- la Raspberry Pi mantenga un **DNS fallback local en `/etc/resolv.conf`** para no perder resolución si Pi-hole cae o se está actualizando
- el homelab pueda resolver nombres internos como `jellyfin.lan`
- la capa recursiva quede preparada para integrarse después con [03-unbound.md](03-unbound.md)

En este diseño, **Pi-hole no actúa como servidor DHCP**. El DHCP sigue en el router y Pi-hole se limita a filtrar y resolver DNS.

## Requisitos Previos

- Haber completado [01-macvlan.md](01-macvlan.md).
- Haber completado [01-instalacion-docker.md](../02-docker/01-instalacion-docker.md).
- Haber completado [02-estructura-compose.md](../02-docker/02-estructura-compose.md).
- Tener creada la red Docker externa `dns_lan`.
- Tener reservada la IP `192.168.1.194` para Pi-hole y la IP `192.168.1.222` para `macvlan-shim`.
- Mantener el DHCP en el router; no habilitar DHCP en Pi-hole en este escenario.
- Puertos necesarios para Pi-hole en su IP macvlan:
  - `53/tcp`
  - `53/udp`
  - `80/tcp`
- Puertos no publicados en la IP del host:
  - `53/tcp`
  - `53/udp`
  - `80/tcp`
  - `443/tcp`

## Docker Compose

Archivo: `/home/<user>/homelab/compose/infra-pihole-unbound/docker-compose.yml`

```yaml
name: infra-pihole-unbound

services:
  pihole:
    image: pihole/pihole:latest
    hostname: pihole
    restart: unless-stopped
    networks:
      dns_lan:
        ipv4_address: 192.168.1.194
    environment:
      TZ: ${TZ}
      FTLCONF_webserver_api_password: ${PIHOLE_WEBPASSWORD}
      FTLCONF_dns_listeningMode: 'LOCAL'
      FTLCONF_dns_upstreams: |-
        1.1.1.1
        1.0.0.1
      FTLCONF_dns_domain_name: 'lan'
      FTLCONF_dns_domain_local: 'true'
      FTLCONF_dns_revServers: |-
        true,192.168.1.0/24,192.168.1.1,lan
    volumes:
      - /home/<user>/homelab/data/pihole:/etc/pihole

networks:
  dns_lan:
    external: true
    name: dns_lan
```

Notas sobre este Compose:

- no se usa `ports:` porque el contenedor ya tiene su propia IP LAN mediante macvlan
- no se habilita DHCP en Pi-hole, así que no hace falta exponer `67/udp`
- el upstream inicial usa resolutores públicos solo para bootstrap
- cuando completes [03-unbound.md](03-unbound.md), cambia `FTLCONF_dns_upstreams` para apuntar a `192.168.1.195#5335`

Archivo recomendado: `/home/<user>/homelab/compose/infra-pihole-unbound/.env`

```dotenv
TZ=Europe/Madrid
PIHOLE_WEBPASSWORD=<cambia-esta-contraseña>
```

## Configuración

### 1. Preparar directorios del stack

```bash
mkdir -p /home/<user>/homelab/compose/infra-pihole-unbound
mkdir -p /home/<user>/homelab/data/pihole
```

Guarda el `docker-compose.yml` y el `.env` mostrados arriba y valida el stack:

```bash
cd /home/<user>/homelab/compose/infra-pihole-unbound
docker compose config
docker compose up -d
docker compose ps
```

Validaciones iniciales:

```bash
docker logs $(docker compose ps -q pihole) --tail 50
dig @192.168.1.194 pi-hole.net
curl http://192.168.1.194/admin/
```

Si el `dig` responde y la interfaz web carga, Pi-hole ya está operativo en la LAN.

### 2. Ajustar el router para que la LAN use Pi-hole

El router sigue gestionando DHCP, pero debe anunciar **Pi-hole** como DNS para los clientes:

- DNS principal por DHCP: `192.168.1.194`
- si el router permite un único DNS, usa solo `192.168.1.194`
- si obliga a un DNS secundario, intenta repetir la misma IP si el firmware lo permite
- evita poner como secundario un DNS público o el del ISP si quieres que todo el tráfico pase por Pi-hole

Después de cambiarlo:

- renueva la concesión DHCP en los clientes, o reinícialos
- comprueba en un cliente que el DNS recibido por DHCP es `192.168.1.194`
- valida resolución y bloqueo desde un equipo de la LAN, no solo desde la Raspberry Pi

En este punto la arquitectura queda así:

- clientes LAN -> `192.168.1.194` -> Pi-hole
- Pi-hole -> upstream temporal
- host Raspberry Pi -> fallback propio en `/etc/resolv.conf`

### 3. Configuración inicial en la interfaz web

Accede a `http://192.168.1.194/admin/` y revisa:

- contraseña de administración
- zona horaria correcta
- estado del bloqueo
- estadísticas de consultas

Ajustes recomendados para este homelab:

- mantener **desactivado** el DHCP interno de Pi-hole
- dejar el dominio local en `lan`
- mantener la escucha DNS en modo local para aceptar peticiones solo desde subredes locales
- usar el router como servidor de reverse lookups para que Pi-hole muestre nombres de clientes en vez de solo IPs

Si tu router usa otro dominio local distinto de `lan`:

- cambia `FTLCONF_dns_revServers`
- si también quieres usar ese dominio como dominio local principal, cambia `FTLCONF_dns_domain_name`

Ejemplo con el upstream definitivo cuando Unbound esté desplegado:

```yaml
environment:
  FTLCONF_dns_upstreams: '192.168.1.195#5335'
```

Haz este cambio solo después de completar [03-unbound.md](03-unbound.md).

### 4. DNS local para servicios internos

Pi-hole puede resolver nombres internos del homelab sin depender de DNS público. Para este proyecto conviene que los nombres LAN apunten a la IP del host cuando el acceso real vaya por **Caddy**.

Ejemplo recomendado:

| Nombre | Destino |
|--------|---------|
| `jellyfin.lan` | `192.168.1.10` |
| `navidrome.lan` | `192.168.1.10` |
| `audiobookshelf.lan` | `192.168.1.10` |
| `portainer.lan` | `192.168.1.10` |

Razón operativa:

- si el acceso entra por el reverse proxy, todos esos nombres deben resolver a la **IP LAN del host**
- no apuntes estos nombres a IPs de contenedores normales de Docker
- reserva IPs propias en la LAN solo para servicios que realmente lo necesitan, como Pi-hole y Unbound

Formas de gestionarlo:

- desde la interfaz web, añadiendo registros DNS locales
- mediante configuración persistida dentro de `/etc/pihole`

Validación desde el host o desde otro equipo:

```bash
dig @192.168.1.194 jellyfin.lan
dig @192.168.1.194 navidrome.lan
```

### 5. Listas de bloqueo recomendadas

La estrategia correcta aquí no es acumular decenas de listas, sino empezar con pocas listas bien mantenidas y vigilar falsos positivos.

Recomendación práctica:

- deja activas las listas por defecto de Pi-hole en el primer arranque
- añade como máximo **una** lista general adicional y observa el comportamiento durante unos días
- documenta cada alta o baja de listas si afecta a servicios del homelab

Selección inicial razonable:

- listas por defecto de Pi-hole
- `OISD small` como lista general conservadora
- `1Hosts (Lite)` si quieres un filtrado algo más estricto sin entrar todavía en listas agresivas

Evita por defecto:

- importar paquetes masivos de listas duplicadas
- mezclar muchas listas de baja calidad o sin mantenimiento claro
- activar listas orientadas a malware, pornografía, gambling o IoT sin revisar antes su impacto en tus servicios reales

Regla de operación:

- si una app deja de funcionar, revisa primero el Query Log antes de desactivar listas enteras

### 6. Fallback DNS del host en `/etc/resolv.conf`

La Raspberry Pi **no debe depender exclusivamente de Pi-hole** para su propia resolución. Si el contenedor cae, el host debe seguir pudiendo:

- hacer `apt update`
- resolver nombres para `docker pull`
- descargar imágenes o actualizaciones
- ejecutar tareas de mantenimiento

Objetivo operativo: el archivo `/etc/resolv.conf` del host debe apuntar a un resolvedor alternativo, por ejemplo el router y un DNS externo de respaldo.

Ejemplo mínimo:

```conf
nameserver 192.168.1.1
nameserver 1.1.1.1
options timeout:1 attempts:1
```

Si tu sistema no gestiona automáticamente `resolv.conf`, puedes escribirlo así:

```bash
sudo cp /etc/resolv.conf /etc/resolv.conf.bak
sudo tee /etc/resolv.conf >/dev/null <<'EOF'
nameserver 192.168.1.1
nameserver 1.1.1.1
options timeout:1 attempts:1
EOF
```

Si `/etc/resolv.conf` se regenera al reiniciar:

- persiste los mismos DNS en `dhcpcd`, NetworkManager o el gestor de red que uses
- verifica después que `/etc/resolv.conf` no haya quedado apuntando solo a `192.168.1.194`

La idea no es que el host ignore Pi-hole, sino que **no dependa de él para sobrevivir a una caída del propio stack DNS**.

### 7. Validaciones que conviene dejar hechas

Desde la Raspberry Pi:

```bash
dig @192.168.1.194 pi-hole.net
dig @192.168.1.194 jellyfin.lan
ping -c 3 192.168.1.194
```

Desde otro cliente de la LAN:

- abrir `http://192.168.1.194/admin/`
- comprobar que recibe `192.168.1.194` como DNS por DHCP
- verificar que `jellyfin.lan` resuelve a la IP del host
- comprobar que dominios de publicidad conocidos aparecen bloqueados en el panel

Si estas pruebas pasan, Pi-hole queda listo para integrarse con **Unbound** en el siguiente documento.

## Almacenamiento

En este despliegue, todo el estado persistente de Pi-hole vive en el **SSD NVMe**:

- Compose: `/home/<user>/homelab/compose/infra-pihole-unbound/docker-compose.yml`
- variables del stack: `/home/<user>/homelab/compose/infra-pihole-unbound/.env`
- datos persistentes: `/home/<user>/homelab/data/pihole/`

Qué queda dentro de `/home/<user>/homelab/data/pihole/`:

- configuración de Pi-hole
- base de datos de listas y gravedad
- ajustes del panel web
- registros y estado persistente
- registros DNS locales creados desde la interfaz

Notas operativas:

- Pi-hole no almacena multimedia ni datos de usuario en `hd2t` o `hd5t`
- mantener estos datos en el SSD reduce latencia y simplifica el backup
- si más adelante añades ficheros auxiliares manuales, guárdalos bajo este mismo árbol

## Backup

Para poder reconstruir Pi-hole sin perder filtrado ni DNS local, respalda como mínimo:

- `/home/<user>/homelab/data/pihole/`
- `/home/<user>/homelab/compose/infra-pihole-unbound/docker-compose.yml`
- `/home/<user>/homelab/compose/infra-pihole-unbound/.env`
- cualquier export manual de listas o notas operativas sobre cambios en el router

Motivos:

- el volumen persistente contiene el estado real del servicio
- el Compose define la IP fija, la red y la política de arranque
- el `.env` guarda la contraseña y otras variables críticas del stack
- la configuración del router determina si los clientes realmente usan Pi-hole

En restauración:

- recupera primero `dns_lan` y `macvlan-shim` según [01-macvlan.md](01-macvlan.md)
- levanta Pi-hole
- verifica resolución desde host y clientes
- solo después reconfigura el router si fuese necesario

## Referencias

- [01-macvlan.md](01-macvlan.md)
- [03-unbound.md](03-unbound.md)
- [05-caddy.md](05-caddy.md)
- [06-puertos-y-firewall.md](06-puertos-y-firewall.md)
- [02-estructura-compose.md](../02-docker/02-estructura-compose.md)
- Pi-hole Docs: [Docker](https://docs.pi-hole.net/docker/)
- Pi-hole Docs: [Docker Configuration](https://docs.pi-hole.net/docker/configuration/)
- Pi-hole Docs: [FTL Configuration](https://docs.pi-hole.net/ftldns/configfile/)
- Pi-hole Docs: [Unbound guide](https://docs.pi-hole.net/guides/dns/unbound/)
- Docker Hub: [pihole/pihole](https://hub.docker.com/r/pihole/pihole)
