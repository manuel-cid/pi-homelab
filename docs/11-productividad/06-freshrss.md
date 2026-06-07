# FreshRSS

## Descripción

**FreshRSS** es el lector de feeds RSS autoalojado de este homelab. Encaja especialmente bien en una Raspberry Pi 5 porque funciona correctamente con **SQLite**, consume pocos recursos y concentra toda su persistencia en un árbol sencillo sobre el **SSD NVMe**.

En este proyecto conviene mantener una topología simple y fácil de operar:

- en todo el documento, sustituye los marcadores `<user>` y `<tailnet>` por tus valores reales antes de ejecutar comandos, definir rutas o publicar la URL final
- la aplicación vive en `/home/<user>/homelab/compose/productivity-freshrss/`
- los datos persistentes viven en `/home/<user>/homelab/data/freshrss/` sobre el **SSD NVMe**
- el servicio se publica en `127.0.0.1:16005/tcp` para bootstrap local y para que **Caddy** lo publique de forma coherente con la política de red del proyecto
- se usa la base de datos **SQLite** integrada, suficiente para un uso personal o familiar
- la actualización automática de feeds se hace con el **cron interno** del contenedor
- `hd2t` y `hd5t` no se usan para datos activos de FreshRSS

Para este homelab, esa combinación suele ser la más razonable: despliegue corto, backup fácil y migración sencilla si en el futuro cambias de hardware.

## Requisitos Previos

- Haber completado [02-estructura-compose.md](../02-docker/02-estructura-compose.md).
- Haber completado [05-caddy.md](../03-red/05-caddy.md) si quieres publicar FreshRSS de forma coherente con la política general de exposición web del homelab.
- Haber completado [04-tailscale.md](../03-red/04-tailscale.md) si quieres acceder también desde fuera de casa por la tailnet.
- Revisar [06-puertos-y-firewall.md](../03-red/06-puertos-y-firewall.md) para mantener documentado el puerto `16005/tcp`.
- Revisar [02-borgmatic.md](../07-backups/02-borgmatic.md) y [03-backup-docker-volumes.md](../07-backups/03-backup-docker-volumes.md) si vas a incluir el bind mount del servicio en la estrategia de copias.
- Disponer de `/home/<user>/homelab/` en el **SSD NVMe** con espacio suficiente para configuración, base de datos, favicon cache y extensiones.
- Tener exportado a `.opml` el catálogo de feeds si vienes de otro lector RSS.
- Puertos necesarios en esta fase:
  - **`16005/tcp` publicado solo en `127.0.0.1`** para bootstrap local y upstream de Caddy
  - **`80/tcp`** es el puerto interno del contenedor

## Docker Compose

Archivo: `/home/<user>/homelab/compose/productivity-freshrss/docker-compose.yml`

```yaml
name: productivity-freshrss

services:
  freshrss:
    image: freshrss/freshrss:1.29.1
    restart: unless-stopped
    env_file:
      - .env
    environment:
      TZ: ${TZ}
      CRON_MIN: ${FRESHRSS_CRON_MIN}
      FRESHRSS_ENV: ${FRESHRSS_ENV}
    ports:
      - "${FRESHRSS_BIND_IP}:${FRESHRSS_PORT}:80"
    volumes:
      - ${DATA_ROOT}/freshrss/data:/var/www/FreshRSS/data
      - ${DATA_ROOT}/freshrss/extensions:/var/www/FreshRSS/extensions
    healthcheck:
      test: ["CMD", "php", "cli/health.php"]
      interval: 75s
      timeout: 10s
      retries: 3
      start_period: 60s
    labels:
      - wud.watch=false
```

Archivo recomendado: `/home/<user>/homelab/compose/productivity-freshrss/.env`

```dotenv
TZ=Europe/Madrid
DATA_ROOT=/home/<user>/homelab/data
FRESHRSS_BIND_IP=127.0.0.1
FRESHRSS_PORT=16005
FRESHRSS_CRON_MIN=13,43
FRESHRSS_ENV=production
```

Notas sobre este Compose:

- `FreshRSS` escucha internamente en `80/tcp`, pero en este homelab se publica solo en `127.0.0.1:16005`
- la persistencia completa queda en bind mounts sobre el **SSD NVMe**
- `SQLite` es suficiente aquí y evita añadir PostgreSQL o MariaDB para un servicio pequeño
- `FRESHRSS_CRON_MIN=13,43` refresca feeds aproximadamente dos veces por hora sin depender de cron en el host
- `extensions/` queda separado para poder probar extensiones sin mezclarlo con la base de datos y la configuración
- se excluye de WUD para evitar actualizaciones automáticas ciegas sobre una aplicación con migraciones y cambios de esquema posibles
- este servicio debería entrar por **Caddy** para acceso HTTP en LAN y, si lo decides, por la entrada HTTPS asociada a Tailscale; el bind en loopback evita exponerlo en `0.0.0.0` por comodidad, tal como fija [06-puertos-y-firewall.md](../03-red/06-puertos-y-firewall.md)
- se fija `freshrss/freshrss:1.29.1` porque la documentación oficial reserva `:x.y.z` para releases concretas y la imagen oficial publica soporte multi-arquitectura incluyendo `linux/arm64`; así el despliegue queda reproducible sin depender de `latest`
- `:latest` y `:1` apuntan hoy a la misma release estable, pero aquí conviene fijar la etiqueta exacta para que las actualizaciones sean deliberadas y no implícitas
- alternativa razonable si quieres seguir recibiendo nuevas releases estables de la rama `1.x` con menos mantenimiento manual: `freshrss/freshrss:1`
- alternativa razonable si priorizas una imagen algo más pequeña y aceptas la variante Alpine: `freshrss/freshrss:1.29.1-alpine`; en ese caso recuerda que varios comandos del documento tendrían que ejecutarse con el usuario `apache` en vez de `www-data`

## Configuración

### 1. Preparar directorios del stack

```bash
mkdir -p /home/<user>/homelab/compose/productivity-freshrss
mkdir -p /home/<user>/homelab/data/freshrss/{data,extensions}
sudo chown -R 33:33 /home/<user>/homelab/data/freshrss
chmod 750 /home/<user>/homelab/data/freshrss
chmod 750 /home/<user>/homelab/data/freshrss/data
chmod 750 /home/<user>/homelab/data/freshrss/extensions
```

Guarda en el primer directorio el `docker-compose.yml` y el `.env` del apartado anterior.

Como `.env` define parámetros operativos, conviene limitar permisos:

```bash
chmod 600 /home/<user>/homelab/compose/productivity-freshrss/.env
```

### 2. Desplegar el stack

```bash
cd /home/<user>/homelab/compose/productivity-freshrss
docker compose config
docker compose up -d
docker compose ps
docker compose logs --tail=100 freshrss
```

Validaciones rápidas:

```bash
curl -I http://127.0.0.1:16005/
docker compose exec -u www-data freshrss php cli/health.php
ls -lah /home/<user>/homelab/data/freshrss
```

Si todo ha arrancado bien, la interfaz quedará accesible en una de estas URLs:

- `http://127.0.0.1:16005` desde la propia Raspberry Pi o mediante un túnel SSH
- la URL que publiques después en **Caddy** para HTTP en LAN o, si aplica, para acceso remoto por Tailscale

### 3. Publicar FreshRSS con Caddy

Para este servicio, la opción más coherente con el resto del homelab es usar **una única URL canónica** y dejar que **Caddy** proxye al upstream local `127.0.0.1:16005`.

Recomendación para este proyecto:

- si quieres acceso también fuera de casa, usa como URL canónica `https://pi-homelab.<tailnet>.ts.net/freshrss/`
- si FreshRSS va a ser solo LAN, la alternativa razonable es `http://freshrss.lan`
- evita mantener `freshrss.lan` y `/freshrss/` como URLs equivalentes para uso diario; FreshRSS espera que `base_url` coincida con la URL real de publicación
- si ya tienes otros `handle`, `handle_path`, `redir` o el bloque `@health` dentro de `https://{$TAILSCALE_DOMAIN}`, integra solo las directivas de FreshRSS sin duplicar bloques ya definidos en [05-caddy.md](../03-red/05-caddy.md)

#### Opción recomendada: subruta HTTPS sobre el hostname Tailscale

Edita `/home/<user>/homelab/config/caddy/Caddyfile` e integra este bloque dentro del `https://{$TAILSCALE_DOMAIN}` que ya existe en [05-caddy.md](../03-red/05-caddy.md):

```caddyfile
https://{$TAILSCALE_DOMAIN} {
	import common_proxy
	tls /certs/{$TAILSCALE_DOMAIN}.crt /certs/{$TAILSCALE_DOMAIN}.key

	@health path /healthz
	handle @health {
		respond "ok" 200
	}

	redir /freshrss /freshrss/ 308

	handle_path /freshrss/* {
		reverse_proxy 127.0.0.1:16005 {
			header_up X-Forwarded-Prefix "/freshrss"
		}
	}

	handle {
		respond "Caddy activo." 200
	}
}
```

Este patrón encaja bien aquí por tres motivos:

- FreshRSS documenta explícitamente en Caddy el uso en **subruta** con `handle_path`, redirección a la barra final y cabecera `X-Forwarded-Prefix`
- el stack actual publica FreshRSS solo en `127.0.0.1:16005`, y en este proyecto **Caddy** usa `network_mode: host`, así que el upstream correcto sigue siendo `127.0.0.1:16005`
- reutiliza el certificado Tailscale ya emitido para el hostname principal y evita abrir otro frente de DNS o TLS
- si tu bloque `https://{$TAILSCALE_DOMAIN}` ya contiene `@health` o el `handle` final por defecto, inserta solo `redir /freshrss /freshrss/ 308` y `handle_path /freshrss/*` respetando el orden actual
- esta opción remota por subruta debe considerarse la URL canónica solo si confirmas que te interesa acceso por Tailscale; si no, mantén `http://freshrss.lan` como URL principal y omite la subruta HTTPS

#### Alternativa razonable: hostname LAN dedicado

Si no quieres acceso remoto por Tailscale y prefieres la opción más simple para la red local, añade además o en su lugar este bloque:

```caddyfile
http://freshrss.lan {
	import common_proxy
	reverse_proxy 127.0.0.1:16005
}
```

Para esta variante, la URL canónica pasa a ser `http://freshrss.lan` y no hace falta `X-Forwarded-Prefix` porque FreshRSS queda servido en la raíz del sitio.

#### Ajuste obligatorio de `base_url`

Después de completar el asistente inicial y generar `/home/<user>/homelab/data/freshrss/data/config.php`, confirma que `base_url` coincide con la opción elegida:

```php
'base_url' => 'https://pi-homelab.<tailnet>.ts.net/freshrss',
```

o, si eliges solo LAN:

```php
'base_url' => 'http://freshrss.lan/',
```

Sin esa coherencia entre proxy y aplicación pueden aparecer redirecciones raras, cookies de login incorrectas o URLs absolutas mal formadas.

Aplica cambios:

```bash
cd /home/<user>/homelab/compose/infra-caddy
docker compose exec caddy caddy validate --config /etc/caddy/Caddyfile
docker compose up -d
```

Validaciones rápidas según la opción elegida:

```bash
curl -I -H 'Host: freshrss.lan' http://127.0.0.1
curl -kI https://pi-homelab.<tailnet>.ts.net/freshrss/
```

### 4. Completar la instalación inicial

En un despliegue nuevo, FreshRSS puede terminar de configurarse desde la interfaz web.

Flujo recomendado:

1. Abre `http://127.0.0.1:16005` desde la Raspberry Pi, usando un túnel SSH, o la URL final que hayas definido en Caddy.
2. Elige el idioma de la interfaz.
3. Usa **SQLite** como base de datos.
4. Crea el usuario administrador principal.
5. Finaliza el asistente y vuelve a iniciar sesión con esa cuenta.
6. Si vas a publicar FreshRSS detrás de **Caddy**, ajusta después `base_url` para que coincida exactamente con la URL canónica elegida.

Para este homelab no hace falta complicarlo con una base externa salvo que más adelante quieras una topología distinta o varios usuarios con carga muy alta.

### 5. Ajustes iniciales en la UI

Después del primer login, revisa como mínimo:

- zona horaria, idioma y formato de fechas
- política de refresco de feeds si quieres afinarla respecto al cron interno
- categorías iniciales para separar noticias, blogs técnicos, medios locales o fuentes personales
- política de retención y limpieza de artículos antiguos
- contraseña específica de API si vas a usar aplicaciones cliente compatibles

En un homelab personal suele funcionar bien empezar con pocas categorías y refinar después, una vez veas qué volumen real de feeds mantienes.

### 6. Importación de feeds OPML

La forma más limpia de migrar desde otro lector RSS es importar un fichero `.opml`.

Flujo recomendado:

1. Exporta tus suscripciones desde el lector anterior en formato OPML.
2. En FreshRSS abre **Subscription management**.
3. Entra en **Import / export**.
4. Selecciona el fichero `.opml`.
5. Lanza la importación y espera a que se creen categorías y feeds.

Comprobaciones posteriores a la importación:

- revisar que las categorías se han mapeado como esperabas
- eliminar feeds rotos o duplicados
- forzar una primera actualización manual para poblar artículos recientes
- observar los logs durante unos minutos si has importado un lote grande

Si el archivo OPML viene muy cargado, conviene hacer la primera importación y actualización en un momento tranquilo para no mezclar ese pico de CPU con otras tareas pesadas de la Raspberry Pi.

### 7. Operación básica y comprobaciones

Comandos útiles de mantenimiento:

```bash
cd /home/<user>/homelab/compose/productivity-freshrss
docker compose logs --tail=100 freshrss
docker compose exec -u www-data freshrss php cli/actualize-user.php --user <usuario>
docker compose exec -u www-data freshrss php cli/list-users.php
```

Señales de que el servicio está sano:

- la UI carga sin errores en `127.0.0.1:16005` o en la URL final servida por Caddy
- puedes iniciar sesión con el usuario creado
- los feeds importados se actualizan y aparecen artículos nuevos
- el `healthcheck` del contenedor aparece como `healthy`
- tras reiniciar el contenedor se conservan usuarios, categorías, feeds y estado de lectura

## Almacenamiento

Rutas persistentes de este servicio:

- `/home/<user>/homelab/data/freshrss/data/` en el **SSD NVMe**
- `/home/<user>/homelab/data/freshrss/extensions/` en el **SSD NVMe**

Qué suele vivir en cada ruta:

- `data/` con la configuración global, bases SQLite, cachés, favicons y estado general de la aplicación
- `extensions/` con extensiones de terceros que quieras mantener entre recreaciones del contenedor

Política recomendada:

- todo el estado activo de FreshRSS vive en el **SSD NVMe**
- no guardar datos de FreshRSS en `hd2t` ni en `hd5t`
- dejar `extensions/` vacío mientras no necesites nada adicional; el directorio puede existir igualmente para mantener el Compose estable

## Backup

Qué respaldar como mínimo:

- `/home/<user>/homelab/compose/productivity-freshrss/docker-compose.yml`
- `/home/<user>/homelab/compose/productivity-freshrss/.env`
- `/home/<user>/homelab/data/freshrss/data/`
- `/home/<user>/homelab/data/freshrss/extensions/` si usas extensiones

Estrategia recomendada en este homelab:

1. incluir el árbol completo de FreshRSS en el backup de filesystem del **SSD NVMe**
2. exportar además un `.opml` de forma periódica como copia portable de las suscripciones
3. para una copia manual consistente, parar el contenedor antes de copiar el directorio de datos

Copia fría simple del árbol persistente:

```bash
cd /home/<user>/homelab/compose/productivity-freshrss
docker compose stop freshrss
rsync -a /home/<user>/homelab/data/freshrss/ /ruta/de/backup/freshrss/
docker compose start freshrss
```

Ejemplo de copia hacia la zona de backups de `hd2t`:

```bash
mkdir -p /media/hd2t/backups/exports/volumes/freshrss
rsync -a /home/<user>/homelab/data/freshrss/ \
  /media/hd2t/backups/exports/volumes/freshrss/
```

Ejemplo de exportación OPML por CLI:

```bash
mkdir -p /media/hd2t/backups/exports/freshrss
cd /home/<user>/homelab/compose/productivity-freshrss
docker compose exec -T -u www-data freshrss php cli/export-opml-for-user.php --user <usuario> \
  > /media/hd2t/backups/exports/freshrss/<usuario>-feeds-$(date +%F).opml
ls -lh /media/hd2t/backups/exports/freshrss/<usuario>-feeds-$(date +%F).opml
```

Buenas prácticas de restore:

- restaurar siempre el directorio `data/` completo, no solo archivos sueltos de SQLite
- si usabas extensiones, restaurar también `extensions/` para evitar diferencias de comportamiento
- validar después del restore que el login funciona y que los feeds vuelven a actualizarse con normalidad

## Referencias

- [FreshRSS - Sitio oficial](https://freshrss.org/)
- [FreshRSS - Documentación](https://freshrss.github.io/FreshRSS/)
- [FreshRSS - Uso de Caddy como reverse proxy](https://freshrss.github.io/FreshRSS/en/admins/Caddy.html)
- [FreshRSS - Docker README oficial](https://github.com/FreshRSS/FreshRSS/blob/edge/Docker/README.md)
- [FreshRSS - Gestión de suscripciones e importación OPML](https://github.com/FreshRSS/FreshRSS/blob/edge/docs/en/users/04_Subscriptions.md)
- [FreshRSS - Repositorio oficial](https://github.com/FreshRSS/FreshRSS)
- [Imagen Docker `freshrss/freshrss`](https://hub.docker.com/r/freshrss/freshrss)
- [02-estructura-compose.md](../02-docker/02-estructura-compose.md)
- [05-caddy.md](../03-red/05-caddy.md)
- [06-puertos-y-firewall.md](../03-red/06-puertos-y-firewall.md)
- [02-borgmatic.md](../07-backups/02-borgmatic.md)
- [03-backup-docker-volumes.md](../07-backups/03-backup-docker-volumes.md)
