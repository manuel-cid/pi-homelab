# Radarr

## Descripción
**Radarr** será el gestor de películas del homelab para buscar, enviar descargas a **Transmission**, importar películas terminadas y mantener organizada la biblioteca de cine en `hd2t`.

En esta arquitectura se despliega sobre la **Raspberry Pi 5** con estos criterios:

- la configuración persistente vive en el **SSD NVMe**
- la biblioteca final de películas vive en **`/mnt/hd2t/media/movies`**
- las descargas se consumen desde **`/mnt/hd2t/downloads/transmission`**
- la interfaz web local se publica detrás de **Caddy** con `https://radarr.lan`
- el acceso sigue siendo **solo LAN + Tailscale**, sin abrir puertos en el router
- los indexadores se sincronizan desde **Prowlarr**

Radarr encaja bien en este homelab porque automatiza la búsqueda y la importación de películas, reduce trabajo manual y mantiene una estructura coherente de nombres, carpetas y archivos para su consumo posterior desde Jellyfin.

## Requisitos Previos
- Haber completado `docs/02-docker/01-instalacion-docker.md`.
- Haber completado `docs/02-docker/02-estructura-compose.md`.
- Haber completado `docs/01-sistema/04-estructura-directorios.md`.
- Haber completado `docs/03-red/04-caddy.md` para publicar `radarr.lan`.
- Haber completado `docs/03-red/05-tailscale.md` si quieres acceso remoto por VPN mesh.
- Haber completado `docs/10-descargas/01-transmission.md`.
- Haber completado `docs/10-descargas/02-prowlarr.md` si vas a centralizar indexadores como se recomienda en esta fase.
- Tener creada la red Docker externa `homelab_proxy`.
- Tener resuelto en Pi-hole o en tu DNS local el FQDN `radarr.lan` apuntando a la IP LAN principal de la Raspberry Pi.
- Tener montado `hd2t` en `/mnt/hd2t`.
- Poder usar `sudo` con el usuario administrador del homelab.
- Si Jellyfin va a consumir estas películas, conviene reutilizar la misma biblioteca final en `/mnt/hd2t/media/movies`.
- Puertos implicados en esta fase:
  - `7878/tcp` solo dentro de Docker entre Caddy, Radarr, Prowlarr y Transmission
  - `80/tcp` y `443/tcp` ya publicados por Caddy en el host
  - no se abre ningún puerto entrante en el router

## Docker Compose
Directorio recomendado:

```text
/home/<usuario>/homelab/compose/radarr/
├── compose.yaml
└── .env
```

Preparación inicial de rutas:

```bash
mkdir -p /home/<usuario>/homelab/compose/radarr
mkdir -p /home/<usuario>/homelab/data/radarr/config
mkdir -p /mnt/hd2t/media/movies
```

Fichero `.env`:

```dotenv
TZ=Europe/Madrid

RADARR_IMAGE=lscr.io/linuxserver/radarr:latest

PUID=1000
PGID=1000
UMASK=002

RADARR_CONFIG_DIR=/home/<usuario>/homelab/data/radarr/config
RADARR_MOVIES_DIR=/mnt/hd2t/media/movies
RADARR_DOWNLOADS_DIR=/mnt/hd2t/downloads/transmission
```

Notas sobre estas variables:

- `PUID` y `PGID` deben corresponder al usuario real que administra el homelab y tiene permisos de escritura sobre `hd2t`.
- `UMASK=002` ayuda a que Radarr, Transmission y Jellyfin compartan permisos de grupo coherentes.
- `RADARR_DOWNLOADS_DIR` apunta al mismo árbol de descargas que usa Transmission para evitar inconsistencias de rutas.
- `latest` sigue la última release publicada por la imagen. Si prefieres máxima reproducibilidad, fija una etiqueta concreta.

Fichero `compose.yaml`:

```yaml
name: radarr

services:
  radarr:
    container_name: radarr
    image: ${RADARR_IMAGE}
    restart: unless-stopped
    env_file:
      - .env
    environment:
      PUID: ${PUID}
      PGID: ${PGID}
      TZ: ${TZ}
      UMASK: ${UMASK}
    volumes:
      - ${RADARR_CONFIG_DIR}:/config
      - type: bind
        source: ${RADARR_MOVIES_DIR}
        target: /movies
      - type: bind
        source: ${RADARR_DOWNLOADS_DIR}
        target: /downloads
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

- no se publica `7878` en el host porque el punto de entrada recomendado es **Caddy**
- Radarr ve la biblioteca final como `/movies` y las descargas como `/downloads`
- montar en Radarr la misma ruta de descargas que usa Transmission simplifica la importación y evita depender de `Remote Path Mapping`
- tanto `/downloads` como `/movies` están sobre `hd2t`, lo que favorece importaciones eficientes y reduce copias innecesarias
- la configuración y la base de datos de Radarr quedan en el NVMe

Despliegue inicial:

```bash
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/compose/radarr
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/data/radarr
sudo chown -R <usuario>:<usuario> /mnt/hd2t/media/movies
sudo chown -R <usuario>:<usuario> /mnt/hd2t/downloads/transmission

cd /home/<usuario>/homelab/compose/radarr
docker compose config
docker compose pull
docker compose up -d
docker compose ps
docker compose logs -f radarr
```

Resultado esperado:

- el contenedor `radarr` queda levantado
- Radarr escucha internamente en `http://radarr:7878`
- se crea la estructura persistente dentro de `/home/<usuario>/homelab/data/radarr/config/`
- Radarr puede ver la biblioteca final en `/movies`
- Radarr puede ver las descargas de Transmission en `/downloads`
- Caddy puede publicar la UI como `https://radarr.lan`

## Configuración

### Objetivo de esta fase

| Elemento | Estado esperado |
|---|---|
| UI local | `https://radarr.lan` |
| Persistencia | `/home/<usuario>/homelab/data/radarr/config/` |
| Endpoint interno | `http://radarr:7878` |
| Biblioteca de películas | `/mnt/hd2t/media/movies/` |
| Descargas visibles en Radarr | `/mnt/hd2t/downloads/transmission/` |
| Punto de entrada LAN | Caddy |
| Acceso remoto | Tailscale |
| Indexadores | sincronizados desde Prowlarr |
| Cliente de descarga | Transmission |

### 1. Preparar rutas y permisos

Crear la estructura base:

```bash
mkdir -p /home/<usuario>/homelab/compose/radarr
mkdir -p /home/<usuario>/homelab/data/radarr/config
mkdir -p /mnt/hd2t/media/movies
```

Permisos recomendados:

```bash
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/compose/radarr
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/data/radarr
sudo chown -R <usuario>:<usuario> /mnt/hd2t/media/movies
sudo chown -R <usuario>:<usuario> /mnt/hd2t/downloads/transmission

chmod 755 /home/<usuario>/homelab/data/radarr
chmod 750 /home/<usuario>/homelab/data/radarr/config
chmod -R 775 /mnt/hd2t/media/movies
chmod -R 775 /mnt/hd2t/downloads/transmission
```

Radarr depende mucho menos del contenedor que de la coherencia de permisos entre servicios. Si Transmission descarga con un UID o una máscara incompatibles, Radarr podrá detectar películas pero fallará al moverlas o enlazarlas al destino final.

### 2. Arrancar el servicio y completar el primer acceso

Levantar el stack:

```bash
cd /home/<usuario>/homelab/compose/radarr
docker compose up -d
```

Comprobaciones útiles:

```bash
docker compose ps
docker compose logs -f radarr
docker exec radarr id
docker exec radarr ls -lah /config
docker exec radarr ls -lah /movies
docker exec radarr ls -lah /downloads
```

Después, abrir:

```text
https://radarr.lan
```

En el primer arranque:

1. Comprueba que la UI carga correctamente detrás de Caddy.
2. Verifica que la carpeta `/config` contiene base de datos, logs y configuración persistente.
3. Revisa la zona horaria y el formato regional para alinearlos con `Europe/Madrid`.
4. Decide si vas a exigir autenticación en la propia aplicación además del aislamiento por LAN y Tailscale.

Si necesitas revisar el estado interno del servicio:

```bash
cd /home/<usuario>/homelab/compose/radarr
docker compose logs --tail=200 radarr
```

### 3. Ajustes básicos recomendados

Antes de automatizar descargas, deja clara la política operativa:

- usa Radarr solo para **películas**
- mantén el acceso por `radarr.lan` y por Tailscale, sin publicar el puerto en el host
- usa Prowlarr como fuente de verdad de indexadores en vez de crear indexadores manuales en Radarr
- mantén el destino final de películas en `/movies`
- evita mezclar series u otros contenidos en esa misma biblioteca

Comprobaciones posteriores al primer acceso:

| Área | Qué revisar |
|---|---|
| General | zona horaria, idioma y comportamiento general de la UI |
| Seguridad | si vas a requerir login en la interfaz |
| Logs | ausencia de errores de permisos o escritura |
| Root folder | visibilidad correcta de `/movies` |
| Descargas | visibilidad correcta de `/downloads` |

### 4. Configurar la biblioteca y la gestión de medios

Dentro de Radarr, la carpeta raíz recomendada para películas es:

```text
/movies
```

Esto corresponde en el host a:

```text
/mnt/hd2t/media/movies
```

Ajustes recomendados en **Media Management**:

- habilita el renombrado de películas importadas
- mantén activado **Completed Download Handling** para que Radarr importe automáticamente lo que termina en Transmission
- usa una carpeta por película para mantener mejor orden, extras y metadatos
- mantén una convención de nombres consistente para que Jellyfin indexe bien el contenido
- habilita hardlinks si tu estrategia de importación lo permite, ya que descargas y biblioteca están en el mismo disco `hd2t`
- no uses carpetas raíz distintas para películas del mismo tipo salvo que exista un motivo claro de organización

Objetivo práctico:

- Transmission descarga en `/downloads/complete/...`
- Radarr detecta la película terminada
- Radarr la importa hacia `/movies/...`
- Jellyfin termina viendo la película en su biblioteca final

Si cambias las rutas del contenedor y dejas de montar en Radarr la misma vista de descargas que usa Transmission, probablemente necesitarás `Remote Path Mapping`. Con el esquema de este documento no debería hacer falta.

### 5. Crear perfiles de calidad

Los perfiles exactos dependen de tus preferencias, pero para este homelab doméstico conviene empezar con pocos perfiles y bien definidos.

Propuesta inicial:

| Perfil | Uso recomendado |
|---|---|
| `Movies HD 1080p` | perfil por defecto para la mayoría del catálogo |
| `Movies HD 720p` | fallback para cine antiguo o menos disponible |
| `Movies UHD 4K` | opcional, solo si tu biblioteca y clientes realmente lo justifican |

Recomendaciones prácticas:

- define un perfil principal y evita crear demasiadas variantes desde el primer día
- coloca `1080p` por encima de `720p` si tu prioridad es calidad general y ahorro de espacio razonable
- usa `720p` como alternativa realista cuando ciertas películas no existan en mejor calidad
- deja `4K` para bibliotecas muy concretas porque incrementa espacio, ancho de banda y tiempos de procesamiento
- revisa el `cutoff` para que Radarr deje de buscar upgrades una vez alcanzada la calidad objetivo
- documenta fuera de Radarr cualquier excepción relevante para no convertir la UI en una colección de reglas difíciles de mantener

Criterio razonable para empezar:

- catálogo general: prioriza WEB y Bluray en `1080p`
- catálogo antiguo o con disponibilidad irregular: permite `720p`
- no añadas perfiles especiales de remux o 4K si todavía no tienes una necesidad real

### 6. Integración con Transmission

La integración recomendada es usar **Transmission** como cliente de descarga interno por Docker.

Endpoint interno esperado:

| Aplicación | URL interna esperada |
|---|---|
| Radarr | `http://radarr:7878` |
| Transmission | `http://transmission:9091` |

Preparación necesaria:

- Transmission debe estar desplegado y funcionando según `docs/10-descargas/01-transmission.md`
- Radarr y Transmission deben compartir una red Docker
- las credenciales de Transmission deben estar a mano
- Radarr debe ver el árbol de descargas en `/downloads`

Flujo recomendado dentro de Radarr:

1. Añade un nuevo **Download Client** de tipo Transmission.
2. Usa `transmission` como host y `9091` como puerto.
3. Deja el `URL Base` vacío salvo que hayas cambiado la ruta base por defecto en Transmission.
4. Introduce usuario y contraseña de la UI de Transmission.
5. Ejecuta la prueba de conexión antes de guardar.
6. Comprueba que Radarr puede listar la cola y recoger descargas terminadas.

Validaciones:

- Radarr conecta correctamente con Transmission por nombre de servicio
- no necesitas exponer `9091` en el host para esta integración
- la descarga completada se ve desde Radarr en `/downloads/complete/...`
- no aparecen errores de permisos al importar películas

### 7. Integración con Prowlarr

La integración recomendada es que **Prowlarr empuje indexadores hacia Radarr** usando la API interna del servicio.

Endpoint interno esperado:

| Aplicación | URL interna esperada |
|---|---|
| Prowlarr | `http://prowlarr:9696` |
| Radarr | `http://radarr:7878` |

Preparación necesaria:

- Prowlarr debe estar desplegado y funcionando según `docs/10-descargas/02-prowlarr.md`
- debes obtener la API key de Radarr desde su interfaz
- Radarr y Prowlarr deben compartir una red Docker

Flujo recomendado:

1. En Radarr, localiza y copia la API key.
2. En Prowlarr, añade Radarr como aplicación externa usando `http://radarr:7878`.
3. Ejecuta la prueba de conexión desde Prowlarr.
4. Sincroniza indexadores.
5. Verifica en Radarr que los indexadores aparecen importados.

Criterio práctico:

- gestiona indexadores en Prowlarr
- gestiona perfiles, películas y automatización en Radarr
- evita configurar el mismo indexador a mano en ambos lados

### 8. Importar una película de prueba y validar el flujo completo

Antes de cargar toda tu biblioteca, valida el circuito con una sola película:

1. Añade una película de prueba en Radarr.
2. Asigna el perfil de calidad principal.
3. Confirma que la carpeta raíz seleccionada es `/movies`.
4. Lanza una búsqueda manual o automática.
5. Comprueba que Radarr envía la descarga a Transmission.
6. Espera a que el archivo termine en `/downloads/complete/`.
7. Verifica que Radarr importa la película hacia `/movies/<Pelicula>/...`.

Resultado esperado:

- la solicitud nace en Radarr
- el indexador llega desde Prowlarr
- la descarga se ejecuta en Transmission
- la película acaba en la biblioteca final de `hd2t`

### 9. Publicación detrás de Caddy

Este documento asume que **Caddy** publica Radarr en la LAN con:

```text
https://radarr.lan
```

Validaciones:

- `radarr` y `caddy` deben estar en `homelab_proxy`
- `https://radarr.lan` debe responder con la UI de Radarr
- el certificado será el de la CA interna de Caddy para la LAN
- si la página no carga, revisa DNS local, red compartida y logs de ambos contenedores

## Almacenamiento

Distribución de datos recomendada:

| Tipo de dato | Ruta |
|---|---|
| Compose del servicio | `/home/<usuario>/homelab/compose/radarr/` |
| Configuración persistente | `/home/<usuario>/homelab/data/radarr/config/` |
| Biblioteca final de películas | `/mnt/hd2t/media/movies/` |
| Descargas visibles para importación | `/mnt/hd2t/downloads/transmission/` |

Criterios de esta distribución:

- el **NVMe** absorbe base de datos, configuración, logs y estado de la aplicación
- `hd2t` absorbe la biblioteca final y el trabajo pesado de importación
- usar el mismo disco para descargas e importación simplifica operaciones y reduce fricción con permisos
- separar configuración y biblioteca facilita backups y recuperación

Qué guarda Radarr en `/config` habitualmente:

- base de datos interna
- configuración de la aplicación
- logs
- cachés y metadatos del servicio

Qué guarda `hd2t` para este flujo:

- la biblioteca final en `/mnt/hd2t/media/movies/`
- las descargas temporales o recién completadas en `/mnt/hd2t/downloads/transmission/`

## Backup

Respaldar como mínimo:

- `/home/<usuario>/homelab/compose/radarr/`
- `/home/<usuario>/homelab/data/radarr/config/`

Respaldar de forma opcional según tu estrategia:

- `/mnt/hd2t/media/movies/` si no forma parte ya del backup global multimedia
- `/mnt/hd2t/downloads/transmission/complete/` si hay películas aún no importadas

Recomendación práctica:

- trata `config/` como **obligatorio**
- trata la biblioteca final como parte del backup multimedia del homelab
- evita respaldar descargas incompletas salvo que tengas un motivo operativo claro
- antes de un backup coherente, para brevemente el contenedor para evitar copiar la base de datos en mitad de una escritura

Parada breve antes del backup:

```bash
cd /home/<usuario>/homelab/compose/radarr
docker compose stop radarr
```

Después del backup:

```bash
docker compose up -d
```

## Referencias
- Documentación de Radarr: `https://wiki.servarr.com/radarr`
- Guía Docker de Servarr: `https://wiki.servarr.com/docker-guide`
- Repositorio oficial de Radarr: `https://github.com/Radarr/Radarr`
- Imagen LinuxServer para Radarr: `https://docs.linuxserver.io/images/docker-radarr/`
- Imagen Docker: `https://hub.docker.com/r/linuxserver/radarr`
