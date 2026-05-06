# Audiobookshelf

## Descripción
**Audiobookshelf** será el servidor de audiolibros y podcasts del homelab, con seguimiento de progreso por usuario, metadatos enriquecidos y reproducción desde navegador o apps móviles dentro de la LAN o a través de Tailscale.

En esta arquitectura se despliega sobre la **Raspberry Pi 5** con estas reglas:

- el servicio y su estado persistente viven en el **SSD NVMe**
- la biblioteca de audiolibros vive en **`/mnt/hd2t/audiobookshelf/audiobooks`**
- la biblioteca de podcasts vive en **`/mnt/hd2t/audiobookshelf/podcasts`**
- el acceso web local se publica detrás de **Caddy** con `https://audiobookshelf.lan`
- el acceso remoto sigue siendo **solo Tailscale**, sin abrir puertos en el router
- la aplicación usa **WebSocket**, así que el proxy inverso debe respetarlo

Audiobookshelf encaja bien en este homelab porque funciona correctamente en ARM64, no necesita una base de datos externa y separa con claridad el contenido frío de `hd2t` de la configuración, base de datos y metadatos persistentes que conviene mantener en el NVMe.

## Requisitos Previos
- Haber completado `docs/02-docker/01-instalacion-docker.md`.
- Haber completado `docs/02-docker/02-estructura-compose.md`.
- Haber completado `docs/01-sistema/04-estructura-directorios.md`.
- Haber completado `docs/03-red/04-caddy.md` para publicar `audiobookshelf.lan`.
- Haber completado `docs/03-red/05-tailscale.md` si quieres acceso remoto por VPN mesh.
- Tener creada la red Docker externa `homelab_proxy`.
- Tener resuelto en Pi-hole o en tu DNS local el FQDN `audiobookshelf.lan` apuntando a la IP LAN principal de la Raspberry Pi.
- Tener montado `hd2t` en `/mnt/hd2t`.
- Tener espacio suficiente en el SSD NVMe para:
  - configuración persistente del servicio
  - base de datos interna
  - metadatos, carátulas y miniaturas
  - caché operativa y backups internos del servicio
- Poder usar `sudo` con el usuario administrador del homelab.
- Puertos implicados en esta fase:
  - `80/tcp` solo dentro de Docker entre Caddy y el contenedor `audiobookshelf`
  - `80/tcp` y `443/tcp` ya publicados por Caddy en el host
  - no se abre ningún puerto entrante en el router

## Docker Compose
Directorio recomendado:

```text
/home/<usuario>/homelab/compose/audiobookshelf/
├── compose.yaml
└── .env
```

Preparación inicial de rutas:

```bash
mkdir -p /home/<usuario>/homelab/compose/audiobookshelf
mkdir -p /home/<usuario>/homelab/data/audiobookshelf/{config,metadata}
mkdir -p /mnt/hd2t/audiobookshelf/{audiobooks,podcasts}
```

Fichero `.env`:

```dotenv
TZ=Europe/Madrid

AUDIOBOOKSHELF_IMAGE=ghcr.io/advplyr/audiobookshelf:latest

PUID=1000
PGID=1000

AUDIOBOOKSHELF_CONFIG_DIR=/home/<usuario>/homelab/data/audiobookshelf/config
AUDIOBOOKSHELF_METADATA_DIR=/home/<usuario>/homelab/data/audiobookshelf/metadata

AUDIOBOOKS_DIR=/mnt/hd2t/audiobookshelf/audiobooks
PODCASTS_DIR=/mnt/hd2t/audiobookshelf/podcasts
```

Notas sobre estas variables:

- `PUID` y `PGID` deben corresponder al usuario real que administra el homelab y tiene acceso a las bibliotecas montadas en `hd2t`.
- `latest` sigue la última release estable publicada por el proyecto. Si quieres máxima reproducibilidad, fija una etiqueta concreta.
- `AUDIOBOOKSHELF_CONFIG_DIR` y `AUDIOBOOKSHELF_METADATA_DIR` se guardan en el NVMe porque contienen el estado del servicio y conviene que no dependan del disco USB.

Fichero `compose.yaml`:

```yaml
name: audiobookshelf

services:
  audiobookshelf:
    container_name: audiobookshelf
    image: ${AUDIOBOOKSHELF_IMAGE}
    user: "${PUID}:${PGID}"
    restart: unless-stopped
    env_file:
      - .env
    environment:
      TZ: ${TZ}
    volumes:
      - ${AUDIOBOOKSHELF_CONFIG_DIR}:/config
      - ${AUDIOBOOKSHELF_METADATA_DIR}:/metadata
      - type: bind
        source: ${AUDIOBOOKS_DIR}
        target: /audiobooks
        read_only: true
      - type: bind
        source: ${PODCASTS_DIR}
        target: /podcasts
    networks:
      - default
      - homelab_proxy
    security_opt:
      - no-new-privileges:true

networks:
  homelab_proxy:
    external: true
    name: homelab_proxy
```

Notas operativas sobre este stack:

- no se publica el puerto en el host porque el punto de entrada recomendado es **Caddy**
- la biblioteca de audiolibros se monta en solo lectura para proteger el contenido original
- la carpeta de podcasts se deja con escritura para permitir descargas automáticas de episodios
- si no vas a usar descargas automáticas de podcasts, puedes montar también `/podcasts` en solo lectura
- `/config` y `/metadata` viven en el NVMe para mantener rápida la base de datos y las operaciones de metadatos

Despliegue inicial:

```bash
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/compose/audiobookshelf
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/data/audiobookshelf
sudo chown -R <usuario>:<usuario> /mnt/hd2t/audiobookshelf

cd /home/<usuario>/homelab/compose/audiobookshelf
docker compose config
docker compose pull
docker compose up -d
docker compose ps
docker compose logs -f audiobookshelf
```

Resultado esperado:

- el contenedor `audiobookshelf` queda levantado
- Audiobookshelf escucha internamente en `http://audiobookshelf:80`
- se crea la estructura persistente en `/home/<usuario>/homelab/data/audiobookshelf/`
- las bibliotecas de `hd2t` quedan visibles desde el contenedor en `/audiobooks` y `/podcasts`
- Caddy puede publicar el servicio como `https://audiobookshelf.lan`

## Configuración

### Objetivo de esta fase

| Elemento | Estado esperado |
|---|---|
| UI local | `https://audiobookshelf.lan` |
| Persistencia | `/home/<usuario>/homelab/data/audiobookshelf/` |
| Biblioteca de audiolibros | `/mnt/hd2t/audiobookshelf/audiobooks/` |
| Biblioteca de podcasts | `/mnt/hd2t/audiobookshelf/podcasts/` |
| Punto de entrada LAN | Caddy |
| Acceso remoto | Tailscale |
| Proxy | WebSocket funcional |
| Base de datos | integrada en el servicio |

### 1. Preparar rutas y permisos

Crear la estructura base:

```bash
mkdir -p /home/<usuario>/homelab/compose/audiobookshelf
mkdir -p /home/<usuario>/homelab/data/audiobookshelf/{config,metadata}
mkdir -p /mnt/hd2t/audiobookshelf/{audiobooks,podcasts}
```

Permisos recomendados:

```bash
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/compose/audiobookshelf
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/data/audiobookshelf
sudo chown -R <usuario>:<usuario> /mnt/hd2t/audiobookshelf

chmod 755 /home/<usuario>/homelab/data/audiobookshelf
chmod 750 /home/<usuario>/homelab/data/audiobookshelf/config
chmod 750 /home/<usuario>/homelab/data/audiobookshelf/metadata
chmod 755 /mnt/hd2t/audiobookshelf
chmod 755 /mnt/hd2t/audiobookshelf/audiobooks
chmod 755 /mnt/hd2t/audiobookshelf/podcasts
```

Si `hd2t` viene de otro sistema de ficheros o se monta con un propietario distinto, corrige antes permisos y ACL. El problema más habitual en Audiobookshelf no suele ser Docker, sino que el contenedor no pueda leer bien la jerarquía de audiolibros o escribir en la carpeta de podcasts.

### 2. Arrancar el servicio y completar el asistente inicial

Levantar el stack:

```bash
cd /home/<usuario>/homelab/compose/audiobookshelf
docker compose up -d
```

Comprobaciones útiles:

```bash
docker compose ps
docker compose logs -f audiobookshelf
docker exec audiobookshelf id
docker exec audiobookshelf ls -lah /audiobooks
docker exec audiobookshelf ls -lah /podcasts
docker exec audiobookshelf ls -lah /metadata
docker exec audiobookshelf ls -lah /config
```

Después, abrir:

```text
https://audiobookshelf.lan
```

En el primer arranque:

1. Crear el usuario administrador.
2. Confirmar idioma, zona horaria y comportamiento general del servidor.
3. Añadir la biblioteca de audiolibros.
4. Añadir la biblioteca de podcasts.
5. Esperar al primer escaneo y comprobar que aparecen portadas, autores y progreso.

### 3. Crear las bibliotecas recomendadas

Bibliotecas sugeridas para este homelab:

| Biblioteca Audiobookshelf | Ruta dentro del contenedor | Tipo sugerido |
|---|---|---|
| Audiolibros | `/audiobooks` | Books |
| Podcasts | `/podcasts` | Podcasts |

Estructura recomendada de audiolibros:

```text
/mnt/hd2t/audiobookshelf/audiobooks/
├── Autor 1/
│   ├── Saga/
│   │   └── Libro 01/
│   │       ├── 01 - Capítulo 01.mp3
│   │       └── cover.jpg
│   └── Libro suelto/
│       └── Libro.m4b
└── Autor 2/
```

Estructura recomendada de podcasts:

```text
/mnt/hd2t/audiobookshelf/podcasts/
├── Podcast 1/
│   ├── episodio-001.mp3
│   └── episodio-002.mp3
└── Podcast 2/
```

Buenas prácticas para que Audiobookshelf detecte bien el contenido:

- usa una jerarquía estable por autor, serie y libro cuando sea posible
- evita mezclar audiolibros definitivos con importaciones temporales o archivos incompletos
- conserva carátulas y metadatos cuando ya estén bien preparados
- deja los audiolibros en solo lectura si la ingestión principal se hace desde Samba o desde el host
- reserva escritura en `podcasts/` si quieres que Audiobookshelf gestione descargas automáticas

### 4. Ajustes recomendados en la UI

Nada más terminar el asistente, revisa:

1. **Settings > Libraries** para validar el tipo correcto de cada biblioteca y el comportamiento del escaneo.
2. **Settings > Users** para crear cuentas separadas si habrá más de un usuario.
3. **Settings > Backups** para revisar la política de copias internas del servicio.
4. **Settings > Metadata Providers** para confirmar cómo quieres enriquecer autores, series y portadas.
5. **Settings > Notifications** o logs para detectar errores de permisos, escaneo o descargas de podcasts.

Buenas prácticas específicas para este homelab:

- lanza el primer escaneo grande en un momento de baja actividad
- no dependas de escritura sobre la biblioteca principal de audiolibros salvo que lo necesites
- si vas a usar podcasts con descarga automática, vigila espacio y crecimiento de `hd2t`
- valida primero la reproducción web antes de añadir clientes móviles

### 5. Integración con Caddy

La integración esperada con `docs/03-red/04-caddy.md` es el bloque:

```caddyfile
audiobookshelf.lan {
  import common
  tls internal
  reverse_proxy audiobookshelf:80
}
```

Después de levantar ambos stacks:

```bash
docker network inspect homelab_proxy
docker compose -f /home/<usuario>/homelab/compose/caddy/compose.yaml ps
docker compose -f /home/<usuario>/homelab/compose/audiobookshelf/compose.yaml ps
```

Validaciones:

- `audiobookshelf` y `caddy` deben estar en `homelab_proxy`
- `https://audiobookshelf.lan` debe responder con el asistente inicial o el login
- el certificado será el de la CA interna de Caddy para la LAN
- la sesión web debe funcionar correctamente, lo que confirma que el proxy respeta WebSocket

### 6. Tailscale y acceso remoto

El patrón recomendado para simplicidad operativa es:

- usar `https://audiobookshelf.lan` dentro de la LAN
- entrar por Tailscale cuando estés fuera de casa
- consumir Audiobookshelf bajo la ruta remota que ya hayas estandarizado en Caddy

La subruta soportada por Audiobookshelf es:

```text
/audiobookshelf
```

Por tanto, la integración remota con el bloque de `docs/03-red/04-caddy.md` es:

```caddyfile
handle_path /audiobookshelf/* {
  reverse_proxy audiobookshelf:80
}
```

Antes de darlo por válido, prueba:

- login desde navegador en LAN
- reproducción de un audiolibro en LAN
- apertura de un podcast y descarga de un episodio si usas esa función
- login y reproducción desde un dispositivo conectado por Tailscale usando `https://pi.tailnet.ts.net/audiobookshelf/`

## Almacenamiento

Distribución de datos recomendada:

| Tipo de dato | Ruta |
|---|---|
| Compose del servicio | `/home/<usuario>/homelab/compose/audiobookshelf/` |
| Configuración y base de datos | `/home/<usuario>/homelab/data/audiobookshelf/config/` |
| Metadatos y carátulas | `/home/<usuario>/homelab/data/audiobookshelf/metadata/` |
| Biblioteca de audiolibros | `/mnt/hd2t/audiobookshelf/audiobooks/` |
| Biblioteca de podcasts | `/mnt/hd2t/audiobookshelf/podcasts/` |

Criterios de esta distribución:

- el **NVMe** absorbe la parte sensible a latencia y escritura frecuente
- `hd2t` almacena únicamente el contenido multimedia grande y relativamente frío
- los audiolibros se montan como `read_only` para proteger el contenido original
- la biblioteca de podcasts puede crecer con descargas automáticas, así que conviene vigilar espacio en `hd2t`

Qué guarda Audiobookshelf en `/config` habitualmente:

- base de datos interna
- usuarios
- configuración del servidor
- estado de progreso y sesiones

Qué guarda en `/metadata` habitualmente:

- carátulas y arte asociado
- metadatos enriquecidos de libros y autores
- caché, streams temporales y descargas gestionadas por la aplicación
- backups internos y logs del servicio
- ficheros auxiliares generados por la aplicación

## Backup

Respaldar como mínimo:

- `/home/<usuario>/homelab/compose/audiobookshelf/`
- `/home/<usuario>/homelab/data/audiobookshelf/config/`
- `/home/<usuario>/homelab/data/audiobookshelf/metadata/`

Respaldar de forma opcional según tu estrategia:

- `/mnt/hd2t/audiobookshelf/audiobooks/` si `hd2t` no es ya la copia maestra de tu biblioteca
- `/mnt/hd2t/audiobookshelf/podcasts/` si quieres conservar episodios descargados y no reobtenerlos

Recomendación práctica:

- trata `config/` como **obligatorio**
- trata `metadata/` como **muy recomendable** para evitar reidentificación y reconstrucción de carátulas
- trata las bibliotecas de `hd2t` según la realidad de tus ficheros: si son el único origen, deben entrar también en la estrategia 3-2-1

Antes de un backup importante o una actualización mayor:

```bash
cd /home/<usuario>/homelab/compose/audiobookshelf
docker compose stop audiobookshelf
```

Después de copiar `config/` y `metadata/`, volver a arrancar:

```bash
docker compose up -d
```

Audiobookshelf mantiene estado interno relevante, así que una parada breve antes del backup reduce el riesgo de copiar una base de datos o metadatos en un estado inconsistente.

## Referencias
- Documentación oficial de Audiobookshelf: `https://www.audiobookshelf.org/`
- Guía de instalación: `https://www.audiobookshelf.org/docs`
- Organización de bibliotecas y metadatos: `https://www.audiobookshelf.org/guides`
- Repositorio oficial: `https://github.com/advplyr/audiobookshelf`
- Imagen oficial en GHCR: `https://ghcr.io/advplyr/audiobookshelf`
