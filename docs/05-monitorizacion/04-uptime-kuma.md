# Uptime Kuma

## Descripción

**Uptime Kuma** es el servicio de monitorización activa del homelab: comprueba si una URL, un puerto TCP o un endpoint concreto siguen respondiendo y envía alertas cuando detecta caídas o degradación. Complementa a [01-prometheus.md](01-prometheus.md) y [02-grafana.md](02-grafana.md): Prometheus guarda métricas y Grafana las visualiza; Uptime Kuma confirma si cada servicio está realmente accesible desde el punto de vista operativo.

En este homelab conviene mantener un criterio simple:

- la UI de Uptime Kuma debe publicarse solo en `127.0.0.1`
- sus datos persistentes deben vivir en el **SSD NVMe**
- para monitorizar servicios Docker, conviene usar nombres internos en la red compartida `homelab_proxy`
- si más adelante quieres acceso remoto, la ruta coherente del proyecto es `https://pi-homelab.<tailnet>.ts.net/uptime/` detrás de **Caddy** y protegida con **Authelia**
- no hace falta montar el socket Docker si el objetivo es vigilar servicios HTTP, TCP o Ping con el menor privilegio posible
- las alertas principales deben salir por **Telegram** y, como canal adicional, por **email SMTP**

## Requisitos Previos

- Haber completado [01-instalacion-docker.md](../02-docker/01-instalacion-docker.md).
- Haber completado [02-estructura-compose.md](../02-docker/02-estructura-compose.md).
- Haber completado [04-estructura-directorios.md](../01-sistema/04-estructura-directorios.md).
- Haber completado [06-puertos-y-firewall.md](../03-red/06-puertos-y-firewall.md).
- Recomendable haber completado [01-prometheus.md](01-prometheus.md), [02-grafana.md](02-grafana.md) y [03-node-exporter.md](03-node-exporter.md) para tener objetivos reales que vigilar desde el primer día.
- Tener creada la red Docker externa `homelab_proxy`.
- Poder crear directorios persistentes en `/home/<user>/homelab/data/`.
- Si se van a usar alertas por Telegram, disponer de un bot y su `chat_id`.
- Si se van a usar alertas por email, disponer de un relay o servidor SMTP accesible desde la Raspberry Pi.
- Sustituir antes de ejecutar comandos o guardar rutas los placeholders de ejemplo, especialmente `<user>` y `<IP-LAN-RASPBERRY>`.
- Puertos necesarios en esta fase:
  - **`11002/tcp`** publicado solo en `127.0.0.1` para la UI de Uptime Kuma

## Docker Compose

Archivo: `/home/<user>/homelab/compose/monitoring-uptime-kuma/docker-compose.yml`

```yaml
name: monitoring-uptime-kuma

services:
  uptime-kuma:
    image: louislam/uptime-kuma:2.4.0
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    env_file:
      - .env
    environment:
      TZ: ${TZ}
    ports:
      - "${UPTIME_KUMA_BIND_IP}:${UPTIME_KUMA_PORT}:${UPTIME_KUMA_PORT}"
    volumes:
      - ${DATA_ROOT}/uptime-kuma:/app/data
    extra_hosts:
      - "host.docker.internal:host-gateway"
    networks:
      - default
      - proxy
    labels:
      - wud.watch=false

networks:
  proxy:
    external: true
    name: ${PROXY_NETWORK}
```

Archivo recomendado: `/home/<user>/homelab/compose/monitoring-uptime-kuma/.env`

```dotenv
TZ=Europe/Madrid
DATA_ROOT=/home/<user>/homelab/data
UPTIME_KUMA_BIND_IP=127.0.0.1
UPTIME_KUMA_PORT=11002
PROXY_NETWORK=homelab_proxy
```

La etiqueta `2.4.0` es la opción recomendada para este homelab: el proyecto documenta `:2` como alias de la rama estable v2, pero esa etiqueta es flotante. Fijar `2.4.0` evita cambios inesperados al recrear el contenedor y mantiene manifiesto multi-arquitectura con variante `linux/arm64`. Si más adelante quieres máxima inmutabilidad, la alternativa razonable es fijar además el digest exacto del manifiesto tras validar la actualización manualmente.

Puntos importantes de este Compose:

- Uptime Kuma se publica solo en `127.0.0.1:11002`, no en toda la LAN
- los datos persistentes viven en `/home/<user>/homelab/data/uptime-kuma/` sobre el **SSD NVMe**
- `extra_hosts` permite resolver `host.docker.internal`, útil para comprobar endpoints del host como métricas nativas de Docker Engine
- el stack se une a `homelab_proxy` para poder monitorizar otros servicios Docker por nombre interno
- no se monta `/var/run/docker.sock`, porque en este escenario no es necesario y añade privilegios innecesarios
- la imagen queda fijada a `louislam/uptime-kuma:2.4.0` para evitar cambios inesperados al recrear el contenedor
- se recomienda **no** configurar triggers de actualización automática de WUD para Uptime Kuma

## Configuración

### 1. Preparar directorios del stack

```bash
mkdir -p /home/<user>/homelab/compose/monitoring-uptime-kuma
mkdir -p /home/<user>/homelab/data/uptime-kuma
```

Uptime Kuma guarda aquí toda su persistencia:

- usuarios y credenciales locales
- monitores
- notificaciones
- páginas de estado
- histórico y base de datos interna

Si la red externa compartida aún no existe, créala:

```bash
docker network inspect homelab_proxy >/dev/null 2>&1 || docker network create homelab_proxy
```

### 2. Guardar el `.env` y desplegar el stack

Guarda el `.env` del apartado Compose y despliega:

```bash
cd /home/<user>/homelab/compose/monitoring-uptime-kuma
docker compose config
docker compose up -d
docker compose ps
```

Validaciones mínimas tras el arranque:

```bash
docker compose logs --tail=100 uptime-kuma
curl -I http://127.0.0.1:11002
```

El resultado esperado es este:

- el contenedor queda en estado `Up`
- la UI responde en `http://127.0.0.1:11002`
- no aparecen errores de permisos sobre `/app/data`

### 3. Configuración inicial y endurecimiento básico

Abre la UI desde el host o mediante un túnel SSH local:

- `http://127.0.0.1:11002`

Pasos recomendados nada más entrar:

1. Crear el usuario administrador inicial.
2. Asignar una contraseña robusta y guardarla fuera del contenedor.
3. Revisar la zona horaria efectiva y confirmar que coincide con `Europe/Madrid`.
4. Activar **2FA** para la cuenta administrativa si más adelante vas a publicar esta UI detrás de Caddy o hacerla accesible también por Tailscale.
5. Crear al menos dos grupos lógicos de alertas:
   - un canal principal para incidencias críticas
   - un canal secundario para avisos menos urgentes o pruebas

### 4. Criterio recomendado para crear monitores

En este homelab conviene seguir estas reglas:

- si el servicio está en Docker y comparte `homelab_proxy`, monitorízalo por nombre interno, por ejemplo `http://grafana:3000`
- si el servicio está en Docker pero **no** comparte `homelab_proxy`, no asumas que `uptime-kuma` podrá resolverlo por nombre: usa su ruta real de acceso, por ejemplo la IP LAN del host, la IP macvlan o la URL publicada por Caddy/Tailscale
- no uses como objetivo el puerto publicado en `127.0.0.1` desde dentro del contenedor, porque ese loopback pertenece al host, no a Uptime Kuma
- usa **HTTP(s)** para UIs y APIs web, **TCP Port** para servicios sin endpoint HTTP y **Ping** solo como señal de reachability básica
- en una Raspberry Pi 5 tiene más sentido empezar con intervalos de **30s** o **60s** que con chequeos masivos cada 20 segundos
- configura `Retries` o reintentos antes de marcar un servicio como caído para evitar falsos positivos por reinicios breves

### 5. Monitores recomendados por servicio

Configuración inicial recomendada para esta fase:

| Servicio | Tipo de monitor | Objetivo recomendado | Criterio práctico |
|---------|------------------|----------------------|-------------------|
| Prometheus | HTTP(s) | `http://prometheus:9090/-/healthy` | Debe devolver `200 OK`; complementa los targets internos de [01-prometheus.md](01-prometheus.md) |
| Grafana | HTTP(s) | `http://grafana:3000/api/health` | Debe devolver `200 OK`; si quieres más precisión, usa `HTTP(s) Keyword` con `ok` |
| Node Exporter | HTTP(s) Keyword | `http://node-exporter:9100/metrics` | Comprueba que existe `node_exporter_build_info` en el cuerpo |
| Docker Engine `/metrics` | HTTP(s) Keyword | `http://host.docker.internal:9323/metrics` | Opcional; útil si ya habilitaste el endpoint en [01-prometheus.md](01-prometheus.md) |
| SSH del host | TCP Port | `<IP-LAN-RASPBERRY>:22` | Confirma acceso administrativo básico al host |

Para el resto del homelab, la plantilla práctica es esta:

- servicios web detrás de Docker: monitor `HTTP(s)` contra `http://<nombre-servicio>:<puerto-interno>`
- servicios publicados solo en host: monitor `HTTP(s)` o `TCP Port` contra `<IP-LAN-RASPBERRY>:<puerto>`
- servicios accesibles también por Tailscale: añade, si te interesa, un monitor adicional contra la URL o IP del tailnet para validar ese camino de acceso

Evita duplicar sin criterio tres monitores para la misma cosa. Lo útil es distinguir:

- salud interna del servicio
- accesibilidad desde la ruta de usuario que realmente te importa
- dependencias críticas del host, como SSH o DNS

### 6. Notificaciones por Telegram

Para Telegram, el flujo recomendado es este:

Esto no contradice el alcance del proyecto: el homelab sigue sin exposición entrante a internet, pero Uptime Kuma sí puede necesitar salida a servicios externos para enviar notificaciones.

1. Crear un bot con **BotFather**.
2. Guardar el token del bot.
3. Enviar al bot al menos un mensaje desde la cuenta o grupo que recibirá las alertas.
4. Obtener el `chat_id`.
5. En Uptime Kuma, crear una notificación de tipo `Telegram` y lanzar un envío de prueba.

Forma simple de obtener el `chat_id` tras enviar un mensaje al bot:

```bash
curl "https://api.telegram.org/bot<TELEGRAM_BOT_TOKEN>/getUpdates"
```

En la respuesta aparecerá el identificador del chat. Después, en Uptime Kuma:

1. Ir a `Notifications`.
2. Crear una notificación nueva de tipo `Telegram`.
3. Rellenar `Bot Token` y `Chat ID`.
4. Enviar un `Test`.
5. Asociar esa notificación a los monitores críticos.

Recomendación práctica:

- usa Telegram para avisos inmediatos de Prometheus, Grafana, DNS, Caddy, Pi-hole, Home Assistant o cualquier servicio cuya caída quieras ver en el móvil al instante

### 7. Notificaciones por email SMTP

Para email, crea otra notificación independiente y úsala como canal secundario o de respaldo.

Igual que con Telegram, esto implica tráfico saliente hacia tu relay o proveedor SMTP, no publicación de puertos entrantes en el router.

Campos típicos a completar en Uptime Kuma:

- servidor SMTP
- puerto SMTP
- cifrado `STARTTLS` o `SSL/TLS`, según el relay
- usuario y contraseña o app password
- remitente
- destinatario

Criterios prácticos:

- si usas un proveedor externo, emplea **app passwords** si el servicio las soporta
- usa una dirección remitente dedicada al homelab
- lanza siempre un `Test` antes de asignar la notificación a monitores reales

Política simple recomendada:

- Telegram para alertas inmediatas
- email para respaldo, avisos menos urgentes o histórico en bandeja de entrada

### 8. Operación diaria

Comandos útiles para operación diaria:

```bash
cd /home/<user>/homelab/compose/monitoring-uptime-kuma
docker compose logs -f uptime-kuma
docker compose restart uptime-kuma
docker compose ps
du -sh /home/<user>/homelab/data/uptime-kuma
```

### 9. Publicación remota opcional detrás de Caddy y Authelia

El acceso base recomendado sigue siendo local en `127.0.0.1:11002`. Si además quieres acceso remoto por Tailscale, la ruta coherente con la arquitectura del repositorio es publicar Uptime Kuma bajo la subruta:

- `https://pi-homelab.<tailnet>.ts.net/uptime/`

Esto debe mantenerse alineado con [05-caddy.md](../03-red/05-caddy.md) y [01-authelia.md](../04-seguridad/01-authelia.md):

- **Caddy** termina HTTPS sobre el hostname MagicDNS del nodo
- **Authelia** protege la ruta remota con política `two_factor`
- Uptime Kuma sigue escuchando en `127.0.0.1:11002` en el host; Caddy hace de proxy hacia ese upstream

Bloque orientativo para `Caddyfile`:

```caddyfile
https://{$TAILSCALE_DOMAIN} {
	import common_proxy
	tls /certs/{$TAILSCALE_DOMAIN}.crt /certs/{$TAILSCALE_DOMAIN}.key

	handle_path /uptime/* {
		import authelia_forward_auth
		reverse_proxy 127.0.0.1:11002
	}
}
```

Regla orientativa en `access_control` de Authelia:

```yaml
access_control:
  rules:
    - domain: 'pi-homelab.<tailnet>.ts.net'
      resources:
        - '^/uptime(/.*)?$'
      policy: two_factor
```

<!-- TODO: verificar el ajuste exacto de Uptime Kuma para servir correctamente bajo la subruta `/uptime/` antes de dar por cerrada la publicación remota; confirmar si basta con `UPTIME_KUMA_WS_ORIGIN`, `UPTIME_KUMA_HOST`, una opción de `webpath` en la UI o una variable equivalente soportada por la versión fijada. -->
<!-- TODO: verificar en una prueba real si `handle_path /uptime/*` recorta el prefijo de forma compatible con la versión desplegada o si hace falta conservar `/uptime` completo con otro bloque de Caddy. -->

Hasta verificar esos dos puntos, trata esta publicación remota como **opcional** y deja la operación normal del servicio en `127.0.0.1:11002` o detrás de un túnel SSH local.

## Almacenamiento

Rutas relevantes de este despliegue:

- `docker-compose.yml`: `/home/<user>/homelab/compose/monitoring-uptime-kuma/docker-compose.yml`
- `.env`: `/home/<user>/homelab/compose/monitoring-uptime-kuma/.env`
- datos persistentes: `/home/<user>/homelab/data/uptime-kuma/`

Notas importantes:

- Uptime Kuma debe guardar su persistencia en el **SSD NVMe**
- no hace falta crear `/home/<user>/homelab/config/uptime-kuma/` en este despliegue base
- no guardes la base de datos ni el histórico en `hd2t` ni `hd5t`
- si el número de monitores crece mucho o habilitas muchas páginas de estado, vigila el tamaño del directorio de datos periódicamente

## Backup

Lo que conviene respaldar en este servicio es esto:

- `/home/<user>/homelab/compose/monitoring-uptime-kuma/docker-compose.yml`
- `/home/<user>/homelab/compose/monitoring-uptime-kuma/.env`
- `/home/<user>/homelab/data/uptime-kuma/`

Matiz importante:

- aquí sí está el estado crítico del servicio: usuarios, monitores, notificaciones e histórico
- para una copia consistente, es preferible parar el contenedor antes de copiar el directorio de datos o usar un snapshot del sistema de ficheros
- si pierdes `/home/<user>/homelab/data/uptime-kuma/`, tendrás que recrear la configuración desde cero

## Referencias

- GitHub: [louislam/uptime-kuma](https://github.com/louislam/uptime-kuma)
- GitHub: [README](https://github.com/louislam/uptime-kuma/blob/master/README.md)
- GitHub: [How to Install](https://github.com/louislam/uptime-kuma/wiki/%F0%9F%94%A7-How-to-Install)
- GitHub: [Notification providers](https://github.com/louislam/uptime-kuma/tree/master/src/components/notifications)
- Docker Hub: [louislam/uptime-kuma](https://hub.docker.com/r/louislam/uptime-kuma)
