# Jellyfin

## Descripción
**Jellyfin** será el servidor multimedia principal del homelab para películas, series, vídeos personales y conciertos almacenados en `hd2t`, con acceso desde navegador, apps móviles, televisores y clientes compatibles dentro de la LAN o a través de Tailscale.

En esta arquitectura se despliega sobre la **Raspberry Pi 5** con estas reglas:

- el servicio y su estado persistente viven en el **SSD NVMe**
- las bibliotecas multimedia viven en **`/mnt/hd2t/media`**
- el acceso web local se publica detrás de **Caddy** con `https://jellyfin.lan`
- el acceso remoto sigue siendo **solo Tailscale**, sin abrir puertos en el router
- la estrategia de reproducción debe priorizar **direct play** y no la transcodificación pesada

Jellyfin encaja bien en este homelab porque funciona correctamente en ARM64, no necesita servicios externos para operar, permite bibliotecas separadas por tipo de contenido y deja claro qué parte del sistema debe vivir en almacenamiento rápido y qué parte puede quedarse en el disco USB de gran capacidad.

## Requisitos Previos
- Haber completado `docs/02-docker/01-instalacion-docker.md`.
- Haber completado `docs/02-docker/02-estructura-compose.md`.
- Haber completado `docs/01-sistema/04-estructura-directorios.md`.
- Haber completado `docs/03-red/04-caddy.md` para publicar `jellyfin.lan`.
- Haber completado `docs/03-red/05-tailscale.md` si quieres acceso remoto por VPN mesh.
- Tener creada la red Docker externa `homelab_proxy`.
- Tener resuelto en Pi-hole o en tu DNS local el FQDN `jellyfin.lan` apuntando a la IP LAN principal de la Raspberry Pi.
- Tener montado `hd2t` en `/mnt/hd2t`.
- Tener espacio suficiente en el SSD NVMe para:
  - configuración del servidor
  - base de datos interna y metadatos
  - caché y artefactos temporales
  - segmentos temporales de transcodificación
- Poder usar `sudo` con el usuario administrador del homelab.
- Puertos implicados en esta fase:
  - `8096/tcp` solo dentro de Docker entre Caddy y el contenedor `jellyfin`
  - `80/tcp` y `443/tcp` ya publicados por Caddy en el host
  - `7359/udp` solo si decides exponer autodiscovery en LAN publicándolo explícitamente en el host
  - no se abre ningún puerto entrante en el router

## Docker Compose
Directorio recomendado:

```text
/home/<usuario>/homelab/compose/jellyfin/
├── compose.yaml
└── .env
```

Preparación inicial de rutas:

```bash
mkdir -p /home/<usuario>/homelab/compose/jellyfin
mkdir -p /home/<usuario>/homelab/data/jellyfin/{config,cache}
mkdir -p /mnt/hd2t/media/{movies,series,concerts,homevideos}
```

Fichero `.env`:

```dotenv
TZ=Europe/Madrid

JELLYFIN_IMAGE=jellyfin/jellyfin:latest

PUID=1000
PGID=1000

JELLYFIN_CONFIG_DIR=/home/<usuario>/homelab/data/jellyfin/config
JELLYFIN_CACHE_DIR=/home/<usuario>/homelab/data/jellyfin/cache

MEDIA_ROOT=/mnt/hd2t/media

JELLYFIN_PUBLISHED_URL=https://jellyfin.lan
```

Notas sobre estas variables:

- `PUID` y `PGID` deben corresponder al usuario real que administra el homelab y tiene acceso a las bibliotecas montadas en `hd2t`.
- `latest` sigue la última release estable publicada por el proyecto. Si quieres máxima reproducibilidad, fija una etiqueta concreta de la serie estable, por ejemplo `10.11`.
- `JELLYFIN_PUBLISHED_URL` anuncia a los clientes la URL principal del servidor. Mantén una URL canónica y evita mezclar varias si quieres reducir problemas con apps cliente.

Fichero `compose.yaml`:

```yaml
name: jellyfin

services:
  jellyfin:
    container_name: jellyfin
    image: ${JELLYFIN_IMAGE}
    user: "${PUID}:${PGID}"
    restart: unless-stopped
    env_file:
      - .env
    environment:
      TZ: ${TZ}
      JELLYFIN_PublishedServerUrl: ${JELLYFIN_PUBLISHED_URL}
    volumes:
      - ${JELLYFIN_CONFIG_DIR}:/config
      - ${JELLYFIN_CACHE_DIR}:/cache
      - type: bind
        source: ${MEDIA_ROOT}/movies
        target: /media/movies
        read_only: true
      - type: bind
        source: ${MEDIA_ROOT}/series
        target: /media/series
        read_only: true
      - type: bind
        source: ${MEDIA_ROOT}/concerts
        target: /media/concerts
        read_only: true
      - type: bind
        source: ${MEDIA_ROOT}/homevideos
        target: /media/homevideos
        read_only: true
    networks:
      - default
      - homelab_proxy
    security_opt:
      - no-new-privileges:true
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

networks:
  homelab_proxy:
    external: true
    name: homelab_proxy
```

Notas operativas sobre este stack:

- no se publica `8096` en el host porque el punto de entrada recomendado es **Caddy**
- las bibliotecas se montan en solo lectura para reducir riesgo sobre el contenido original
- `/config` y `/cache` viven en el NVMe porque Jellyfin realiza muchas escrituras pequeñas sobre base de datos, miniaturas, índices y caché
- `bridge` es suficiente para este diseño; no hace falta `network_mode: host` salvo que quieras DLNA o autodiscovery expuestos en la LAN como objetivo explícito
- no se configura aceleración hardware en el `compose` base porque en **Raspberry Pi 5** no debe ser un supuesto operativo del diseño

Despliegue inicial:

```bash
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/compose/jellyfin
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/data/jellyfin
sudo chown -R <usuario>:<usuario> /mnt/hd2t/media

cd /home/<usuario>/homelab/compose/jellyfin
docker compose config
docker compose pull
docker compose up -d
docker compose ps
docker compose logs -f jellyfin
```

Resultado esperado:

- el contenedor `jellyfin` queda levantado
- Jellyfin escucha internamente en `http://jellyfin:8096`
- se crea la estructura persistente en `/home/<usuario>/homelab/data/jellyfin/`
- las bibliotecas de `hd2t` quedan visibles desde el contenedor en `/media/...`
- Caddy puede publicar el servicio como `https://jellyfin.lan`

## Configuración

### Objetivo de esta fase

| Elemento | Estado esperado |
|---|---|
| UI local | `https://jellyfin.lan` |
| Persistencia | `/home/<usuario>/homelab/data/jellyfin/` |
| Bibliotecas multimedia | `/mnt/hd2t/media/...` |
| Punto de entrada LAN | Caddy |
| Acceso remoto | Tailscale |
| Estrategia de reproducción | priorizar direct play |
| Proxy | WebSocket funcional y cabeceras reenviadas correctamente |
| Transcodificación hardware en Pi 5 | no forma parte del diseño base |

### 1. Preparar rutas y permisos

Crear la estructura base:

```bash
mkdir -p /home/<usuario>/homelab/compose/jellyfin
mkdir -p /home/<usuario>/homelab/data/jellyfin/{config,cache}
mkdir -p /mnt/hd2t/media/{movies,series,concerts,homevideos}
```

Permisos recomendados:

```bash
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/compose/jellyfin
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/data/jellyfin
sudo chown -R <usuario>:<usuario> /mnt/hd2t/media

chmod 755 /home/<usuario>/homelab/data/jellyfin
chmod 750 /home/<usuario>/homelab/data/jellyfin/config
chmod 750 /home/<usuario>/homelab/data/jellyfin/cache
chmod 755 /mnt/hd2t/media
```

Si `hd2t` viene de otro sistema de ficheros o se monta con un propietario distinto, corrige antes permisos y ACL. El problema más habitual en Jellyfin no suele estar en Docker, sino en bibliotecas legibles desde el host pero no desde el UID/GID que ejecuta el contenedor.

### 2. Arrancar el servicio y completar el asistente inicial

Levantar el stack:

```bash
cd /home/<usuario>/homelab/compose/jellyfin
docker compose up -d
```

Comprobaciones útiles:

```bash
docker compose ps
docker compose logs -f jellyfin
docker exec jellyfin id
docker exec jellyfin ls -lah /media
docker exec jellyfin ls -lah /config
docker exec jellyfin ls -lah /cache
```

Después, abrir:

```text
https://jellyfin.lan
```

En el primer arranque:

1. Crear el usuario administrador.
2. Elegir idioma de interfaz y metadatos.
3. Añadir las bibliotecas una a una.
4. Confirmar que la detección automática de metadatos funciona.
5. Revisar el consumo inicial del NVMe durante indexación y descarga de imágenes.

### 3. Crear las bibliotecas recomendadas

Bibliotecas sugeridas para este homelab:

| Biblioteca Jellyfin | Ruta dentro del contenedor | Tipo sugerido |
|---|---|---|
| Películas | `/media/movies` | Movies |
| Series | `/media/series` | Shows |
| Conciertos | `/media/concerts` | Music Videos o Movies |
| Vídeos personales | `/media/homevideos` | Home Videos & Photos |

Ruta base esperada en el host:

```text
/mnt/hd2t/media/
```

Estructura sugerida:

```text
/mnt/hd2t/media/
├── movies/
│   ├── Blade Runner (1982)/
│   │   ├── Blade Runner (1982).mkv
│   │   └── poster.jpg
│   └── Arrival (2016)/
├── series/
│   ├── Chernobyl/
│   │   └── Season 01/
│   └── The Expanse/
├── concerts/
└── homevideos/
```

Buenas prácticas para que Jellyfin indexe bien:

- usa nombres limpios y consistentes en disco
- separa películas, series y vídeos personales en carpetas distintas
- evita mezclar descargas temporales con bibliotecas definitivas
- deja `Jellyfin` sin permisos de escritura sobre el contenido si no necesitas `.nfo`, imágenes laterales o cambios en la propia biblioteca
- si importas mucho contenido de golpe, hazlo fuera de horas de uso y deja terminar el primer escaneo antes de juzgar rendimiento

### 4. Ajustes recomendados en la UI

Nada más terminar el asistente, revisa:

1. **Dashboard > Users** para crear cuentas separadas si habrá más de un usuario.
2. **Dashboard > Libraries** para confirmar idioma de metadatos, refresco automático y proveedores.
3. **Dashboard > Playback** para limitar transcodificación agresiva y reducir carga en la Pi.
4. **Dashboard > Scheduled Tasks** para revisar la frecuencia de escaneo e indexación.
5. **Dashboard > Networking** para confirmar la URL publicada, revisar proxies conocidos y desactivar lo que no uses.

Buenas prácticas específicas para Raspberry Pi 5:

- prioriza clientes capaces de **direct play**
- evita depender de conversión en tiempo real de 4K o HEVC pesados
- si usas subtítulos complejos, prueba el peor caso real porque el burn-in puede disparar CPU
- desactiva DLNA si no lo necesitas
- si varias personas van a reproducir a la vez, valida primero uno o dos escenarios reales de uso

### 5. Integración con Caddy

La integración esperada con `docs/03-red/04-caddy.md` es el bloque:

```caddyfile
jellyfin.lan {
  import common
  tls internal
  reverse_proxy jellyfin:8096
}
```

Después de levantar ambos stacks:

```bash
docker network inspect homelab_proxy
docker compose -f /home/<usuario>/homelab/compose/caddy/compose.yaml ps
docker compose -f /home/<usuario>/homelab/compose/jellyfin/compose.yaml ps
```

Validaciones:

- `jellyfin` y `caddy` deben estar en `homelab_proxy`
- `https://jellyfin.lan` debe responder con el asistente inicial o el login
- la reproducción web básica debe funcionar detrás del proxy
- el certificado será el de la CA interna de Caddy para la LAN

Configuración adicional importante en Jellyfin:

1. Ir a **Dashboard > Networking**.
2. Añadir como **Known Proxies** la IP o subred desde la que Caddy llega a Jellyfin.
3. Guardar cambios y, si hace falta, reiniciar el contenedor.

Esto es relevante para que Jellyfin confíe en cabeceras como `X-Forwarded-For`, `X-Forwarded-Proto` y `X-Forwarded-Host`, y para que pueda distinguir correctamente entre cliente real y proxy.

### 6. Tailscale y acceso remoto

Para este homelab hay dos patrones razonables.

**Patrón recomendado**

- usar `https://jellyfin.lan` dentro de la LAN
- acceder por Tailscale a la red doméstica
- usar Jellyfin con una URL directa y estable, evitando subrutas cuando vayas a conectar apps nativas

Este patrón suele ser el más robusto para clientes de TV, móvil o escritorio porque evita depender de `Base URL`.

**Patrón alternativo detrás del endpoint Tailscale de Caddy**

- publicar Jellyfin bajo `/jellyfin/`
- configurar en Jellyfin **Dashboard > Networking > Base URL** con `/jellyfin`
- asumir que algunos clientes o integraciones pueden requerir la URL completa con esa base

El bloque esperado en Caddy para ese patrón es:

```caddyfile
redir /jellyfin /jellyfin/

handle_path /jellyfin/* {
  reverse_proxy jellyfin:8096
}
```

Antes de darlo por válido, prueba:

- login desde navegador en LAN
- reproducción de un archivo que haga **direct play**
- reproducción de un caso más exigente con subtítulos o bitrate alto
- acceso desde un dispositivo conectado por Tailscale

Si usas subruta y observas problemas en apps cliente, vuelve a un acceso directo por hostname o URL dedicada.

### 7. Transcodificación por hardware en Raspberry Pi 5

La recomendación base para este homelab es clara:

- **no diseñes Jellyfin alrededor de la transcodificación hardware en Raspberry Pi 5**
- diseña el uso pensando en **direct play** y en muy pocos transcodes simultáneos

Razones prácticas:

- Jellyfin ya no considera Raspberry Pi una ruta madura de aceleración hardware
- la **Raspberry Pi 5** carece de codificadores hardware, así que no es una base sólida para transcodificación completa
- incluso cuando alguna parte del pipeline acelera, otras etapas pueden seguir cayendo en CPU
- subtítulos burn-in, escalado, tone-mapping HDR y conversiones complejas pueden degradar rápido la experiencia

Qué hacer en este proyecto:

1. Arrancar primero sin ninguna configuración de aceleración hardware.
2. Medir CPU, temperatura y experiencia real con tus clientes habituales.
3. Priorizar formatos compatibles con reproducción directa.
4. Reducir al mínimo la necesidad de subtítulos quemados o conversiones on-the-fly.
5. Tratar cualquier experimento de aceleración en Pi 5 como opcional y fuera del baseline documentado.

Qué suele funcionar mejor en una Raspberry Pi 5:

- clientes que reproduzcan **H.264** o **HEVC** sin conversión
- contenedores y bitrates razonables para la red local
- audio y subtítulos compatibles con el cliente final
- caché de transcodificación en el NVMe, no en `hd2t`

Señales de que conviene volver a un enfoque de solo reproducción directa:

- CPU alta durante reproducciones aparentemente simples
- throttling térmico
- errores frecuentes de `ffmpeg` en logs
- tiempos largos al iniciar reproducción
- mala experiencia al usar subtítulos burn-in o archivos 4K

## Almacenamiento

Distribución de datos recomendada:

| Tipo de dato | Ruta |
|---|---|
| Compose del servicio | `/home/<usuario>/homelab/compose/jellyfin/` |
| Configuración y base de datos | `/home/<usuario>/homelab/data/jellyfin/config/` |
| Caché y transcodes temporales | `/home/<usuario>/homelab/data/jellyfin/cache/` |
| Películas | `/mnt/hd2t/media/movies/` |
| Series | `/mnt/hd2t/media/series/` |
| Conciertos | `/mnt/hd2t/media/concerts/` |
| Vídeos personales | `/mnt/hd2t/media/homevideos/` |

Criterios de esta distribución:

- el **NVMe** absorbe la parte sensible a latencia y escritura frecuente
- `hd2t` almacena únicamente contenido multimedia grande y relativamente frío
- la caché de transcodificación no debe ir a `hd2t`
- las bibliotecas se montan como `read_only` para proteger el contenido original
- el servicio queda desacoplado de la colección: puedes restaurar `config/` y reconstruir metadatos sin mover todo el disco multimedia

Qué guarda Jellyfin en `/config` habitualmente:

- base de datos interna
- usuarios
- configuración del servidor
- metadatos descargados
- imágenes y estado general de la biblioteca

Qué guarda Jellyfin en `/cache` habitualmente:

- artefactos temporales
- segmentos de transcodificación
- miniaturas y caché regenerable
- ficheros operativos efímeros

## Backup

Respaldar como mínimo:

- `/home/<usuario>/homelab/compose/jellyfin/`
- `/home/<usuario>/homelab/data/jellyfin/config/`

Respaldar de forma opcional según tu estrategia:

- `/home/<usuario>/homelab/data/jellyfin/cache/` si quieres restauraciones más rápidas
- `/mnt/hd2t/media/` si `hd2t` no es ya la copia maestra de tus contenidos

Recomendación práctica:

- trata `config/` como **obligatorio**
- trata `cache/` como **prescindible**
- trata `hd2t` según la realidad de tus ficheros: si es el único origen, también debe entrar en la estrategia 3-2-1

Antes de un backup importante o una actualización mayor:

```bash
cd /home/<usuario>/homelab/compose/jellyfin
docker compose stop jellyfin
```

Después de copiar `config/`, volver a arrancar:

```bash
docker compose up -d
```

Jellyfin mantiene una base de datos interna y bastante estado persistente, así que una parada breve antes del backup reduce el riesgo de copiar ficheros en un estado inconsistente.

## Referencias
- Documentación oficial de Jellyfin: `https://jellyfin.org/docs/`
- Instalación en contenedor: `https://jellyfin.org/docs/general/installation/container/`
- Networking y puertos: `https://jellyfin.org/docs/general/post-install/networking/`
- Reverse proxy con Caddy: `https://jellyfin.org/docs/general/post-install/networking/reverse-proxy/caddy/`
- Tailscale en Jellyfin: `https://jellyfin.org/docs/general/post-install/networking/tailscale/`
- Aceleración hardware y deprecación en Raspberry Pi: `https://jellyfin.org/docs/general/post-install/transcoding/hardware-acceleration/`
- Imagen oficial Docker Hub: `https://hub.docker.com/r/jellyfin/jellyfin`
