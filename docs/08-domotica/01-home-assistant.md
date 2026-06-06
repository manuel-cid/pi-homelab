# Home Assistant

## Descripción

Home Assistant es la plataforma central de domótica del homelab. En este entorno se despliega como **Home Assistant Container** sobre Docker, con acceso solo desde la **LAN** y a través de **Tailscale**.

Esta modalidad encaja bien con el resto del homelab porque mantiene el mismo patrón operativo que el resto de servicios, pero tiene una limitación importante: **no incluye Supervisor ni sistema de add-ons**. Los componentes auxiliares como **Mosquitto**, **Zigbee2MQTT** o **Node-RED** se ejecutan como contenedores independientes y se integran desde la propia interfaz de Home Assistant.

## Requisitos Previos

- Haber completado [04-estructura-directorios.md](../01-sistema/04-estructura-directorios.md) para disponer de la estructura base en el SSD NVMe.
- Haber completado [01-instalacion-docker.md](../02-docker/01-instalacion-docker.md) y [02-estructura-compose.md](../02-docker/02-estructura-compose.md).
- Haber completado [04-tailscale.md](../03-red/04-tailscale.md) si se quiere acceso remoto por VPN.
- Haber completado [05-caddy.md](../03-red/05-caddy.md) solo si se va a publicar Home Assistant detrás del reverse proxy interno.
- Revisar [06-puertos-y-firewall.md](../03-red/06-puertos-y-firewall.md) para registrar el puerto del servicio.
- Puerto principal: `8123/tcp`.
- Recomendado usar `network_mode: host` para que Home Assistant detecte correctamente dispositivos y protocolos de descubrimiento en la red local.
- Si se publica con Caddy, el upstream debe apuntar a `host.docker.internal:8123`, porque con `network_mode: host` Home Assistant no queda accesible por nombre de contenedor en `homelab_proxy`.

## Docker Compose

Archivo: `/home/<user>/homelab/compose/automation-homeassistant/docker-compose.yml`

```yaml
name: automation-homeassistant

services:
  homeassistant:
    image: ghcr.io/home-assistant/home-assistant:stable
    container_name: homeassistant
    restart: unless-stopped
    privileged: true
    network_mode: host
    environment:
      TZ: Europe/Madrid
    volumes:
      - /home/<user>/homelab/data/homeassistant/config:/config
      - /etc/localtime:/etc/localtime:ro
      - /run/dbus:/run/dbus:ro
    labels:
      - wud.watch=false
```

### Despliegue

```bash
mkdir -p /home/<user>/homelab/compose/automation-homeassistant
mkdir -p /home/<user>/homelab/data/homeassistant/config
cd /home/<user>/homelab/compose/automation-homeassistant
docker compose config
docker compose up -d
docker compose logs -f
```

Tras arrancar, la interfaz queda disponible en:

- `http://IP_DE_LA_PI:8123`
- `http://pi-homelab.<tailnet>.ts.net:8123` si accedes por la red Tailscale con MagicDNS

## Configuración

### Asistente inicial

1. Abre `http://IP_DE_LA_PI:8123`.
2. Espera a que termine la preparación inicial del contenedor.
3. Crea el usuario administrador.
4. Define nombre de la vivienda, zona horaria y ubicación.
5. Revisa los dispositivos detectados automáticamente y omite lo que no vayas a usar.

### Ajustes recomendados tras el primer arranque

1. Ve a **Settings → System → Network** y confirma que la URL interna coincide con la forma en la que vas a acceder normalmente al servicio.
2. Ve a **Settings → System → General** y verifica la zona horaria.
3. Ve a **Settings → Devices & services** y elimina integraciones descubiertas que no quieras mantener.
4. Crea las primeras **Areas** para organizar habitaciones y dispositivos desde el principio.

### Integraciones básicas recomendadas

#### Companion App

Instala la aplicación oficial de Home Assistant en móvil para obtener:

- presencia por geolocalización
- sensores del teléfono
- notificaciones push

Es una de las integraciones más útiles incluso antes de añadir dispositivos Zigbee o automatizaciones complejas.

#### MQTT

Cuando esté desplegado [02-mosquitto.md](02-mosquitto.md), añade la integración **MQTT** desde **Settings → Devices & services → Add integration**.

Valores típicos:

- Broker: IP de la Raspberry Pi
- Puerto: `1883`
- Usuario y contraseña: los definidos en Mosquitto

Esta integración es la base para enlazar posteriormente **Zigbee2MQTT** y exponer entidades en Home Assistant.

#### Zigbee2MQTT

Cuando esté desplegado [03-zigbee2mqtt.md](03-zigbee2mqtt.md), activa la integración por MQTT. Si Zigbee2MQTT tiene `homeassistant: true`, los dispositivos emparejados aparecerán automáticamente en Home Assistant mediante MQTT Discovery.

#### Node-RED

Cuando esté desplegado [04-node-red.md](04-node-red.md), integra Node-RED con Home Assistant usando:

- el servidor de Home Assistant en `http://IP_DE_LA_PI:8123`
- un **Long-Lived Access Token** generado desde el perfil del usuario administrador

Esto permite crear automatizaciones complejas fuera del editor nativo de Home Assistant.

### Publicación detrás de Caddy

Si vas a acceder a Home Assistant mediante [05-caddy.md](../03-red/05-caddy.md), añade en `/home/<user>/homelab/data/homeassistant/config/configuration.yaml` una sección `http` con los proxies de confianza reales de tu despliegue.

En este caso, como Home Assistant usa `network_mode: host`, el bloque de Caddy debe usar `host.docker.internal:8123` como upstream, siguiendo la opción de transición documentada en [05-caddy.md](../03-red/05-caddy.md). Ejemplo mínimo dentro del `Caddyfile`:

```caddyfile
http://homeassistant.lan {
	import common_proxy
	reverse_proxy host.docker.internal:8123
}
```

Ejemplo:

```yaml
http:
  use_x_forwarded_for: true
  trusted_proxies:
    - 172.18.0.0/16
```

Ajusta la subred al rango real de la red Docker desde la que llegue Caddy. Usa `172.18.0.0/16` como ejemplo inicial si aún no has verificado tu red, porque es un rango habitual en redes bridge de Docker, pero no lo trates como un valor fijo del proyecto.

Antes de darlo por bueno, comprueba la subred real de la red compartida del proxy:

```bash
docker network inspect homelab_proxy | grep Subnet
```

Si la salida muestra otro rango, sustituye `172.18.0.0/16` por el valor real. La recomendación práctica es mantener la subred completa de esa red en formato `/16` o con la máscara que Docker haya asignado, en lugar de intentar listar IPs sueltas, para evitar roturas si cambian las direcciones internas de los contenedores al recrear la red. Si no se configura correctamente, Home Assistant rechazará la cabecera `X-Forwarded-For`.

### Reinicio tras cambios de configuración

Después de editar `configuration.yaml`, valida la sintaxis desde **Developer Tools → YAML** o reinicia el contenedor:

```bash
cd /home/<user>/homelab/compose/automation-homeassistant
docker compose restart
```

## Almacenamiento

- `docker-compose.yml` en `/home/<user>/homelab/compose/automation-homeassistant/docker-compose.yml`.
- Datos persistentes en `/home/<user>/homelab/data/homeassistant/config` sobre el **SSD NVMe**.
- No guardar datos de Home Assistant en `hd2t` ni `hd5t`; esos discos quedan reservados para multimedia y backups.
- Aunque la ruta dentro del contenedor se llame `/config`, en el host se guarda bajo `data/` porque Home Assistant mezcla configuración editable, base de datos SQLite, cachés y estado interno en el mismo árbol.
- Dentro de `config/` quedarán, entre otros:
  - `configuration.yaml`
  - `automations.yaml`
  - `scripts.yaml`
  - `scenes.yaml`
  - `secrets.yaml`
  - `.storage/`
  - `home-assistant_v2.db`
  - `www/`, `themes/` y `custom_components/` si se usan

### Permisos

- El contenedor oficial trabaja sin problema con el directorio creado por `root` o por tu usuario del sistema.
- Mantén permisos simples y evita mezclar ACLs innecesarias en esta ruta.
- Si restauras datos desde backup, verifica que el contenedor sigue pudiendo leer y escribir en `config/`.

## Backup

En Home Assistant Container no existe el sistema de snapshots gestionado por Supervisor, así que el backup se hace a nivel de archivos.

Respaldar:

- `/home/<user>/homelab/compose/automation-homeassistant/docker-compose.yml`
- `/home/<user>/homelab/data/homeassistant/config`
- especialmente `configuration.yaml`, `automations.yaml`, `secrets.yaml`, `.storage/` y `home-assistant_v2.db`

Recomendaciones:

- Para una copia consistente de la base de datos SQLite, detener brevemente el contenedor durante el backup:

```bash
cd /home/<user>/homelab/compose/automation-homeassistant
docker compose stop homeassistant
# ejecutar backup
docker compose start homeassistant
```

- Integrar esta ruta más adelante en [02-borgmatic.md](../07-backups/02-borgmatic.md).
- Probar restauraciones periódicas en una copia del directorio antes de depender del backup en producción.

## Referencias

- Documentación oficial de instalación de Home Assistant Container: https://www.home-assistant.io/installation/linux
- Guía oficial para Raspberry Pi: https://www.home-assistant.io/installation/raspberrypi
- Imagen oficial Docker: https://github.com/home-assistant/core/pkgs/container/home-assistant
- Documentación oficial de la Companion App: https://companion.home-assistant.io/
- Documentación oficial de la integración MQTT: https://www.home-assistant.io/integrations/mqtt/
