# Sonarr

## Descripción
**Sonarr** será el gestor de series del homelab para buscar, enviar descargas a **Transmission**, importar episodios terminados y mantener organizada la biblioteca de TV en `hd2t`.

En esta arquitectura se despliega sobre la **Raspberry Pi 5** con estos criterios:

- la configuración persistente vive en el **SSD NVMe**
- la biblioteca final de series vive en **`/mnt/hd2t/media/series`**
- las descargas se consumen desde **`/mnt/hd2t/downloads/transmission`**
- la interfaz web local se publica detrás de **Caddy** con `https://sonarr.lan`
- el acceso sigue siendo **solo LAN + Tailscale**, sin abrir puertos en el router
- los indexadores se sincronizan desde **Prowlarr**

Sonarr encaja bien en este homelab porque automatiza la búsqueda y la importación de episodios, reduce trabajo manual y mantiene una estructura coherente de nombres, temporadas y archivos para su consumo posterior desde Jellyfin.

## Requisitos Previos
- Haber completado `docs/02-docker/01-instalacion-docker.md`.
- Haber completado `docs/02-docker/02-estructura-compose.md`.
- Haber completado `docs/01-sistema/04-estructura-directorios.md`.
- Haber completado `docs/03-red/04-caddy.md` para publicar `sonarr.lan`.
- Haber completado `docs/03-red/05-tailscale.md` si quieres acceso remoto por VPN mesh.
- Haber completado `docs/10-descargas/01-transmission.md`.
- Haber completado `docs/10-descargas/02-prowlarr.md` si vas a centralizar indexadores como se recomienda en esta fase.
- Tener creada la red Docker externa `homelab_proxy`.
- Tener resuelto en Pi-hole o en tu DNS local el FQDN `sonarr.lan` apuntando a la IP LAN principal de la Raspberry Pi.
- Tener montado `hd2t` en `/mnt/hd2t`.
- Poder usar `sudo` con el usuario administrador del homelab.
- Si Jellyfin va a consumir estas series, conviene reutilizar la misma biblioteca final en `/mnt/hd2t/media/series`.
- Puertos implicados en esta fase:
  - `8989/tcp` solo dentro de Docker entre Caddy, Sonarr, Prowlarr y Transmission
  - `80/tcp` y `443/tcp` ya publicados por Caddy en el host
  - no se abre ningún puerto entrante en el router

## Docker Compose
Directorio recomendado:

```text
/home/<usuario>/homelab/compose/sonarr/
├── compose.yaml
└── .env
```

Preparación inicial de rutas:

```bash
mkdir -p /home/<usuario>/homelab/compose/sonarr
mkdir -p /home/<usuario>/homelab/data/sonarr/config
mkdir -p /mnt/hd2t/media/series
```

Fichero `.env`:

```dotenv
TZ=Europe/Madrid

SONARR_IMAGE=lscr.io/linuxserver/sonarr:latest

PUID=1000
PGID=1000
UMASK=002

SONARR_CONFIG_DIR=/home/<usuario>/homelab/data/sonarr/config
SONARR_SERIES_DIR=/mnt/hd2t/media/series
SONARR_DOWNLOADS_DIR=/mnt/hd2t/downloads/transmission
```

Notas sobre estas variables:

- `PUID` y `PGID` deben corresponder al usuario real que administra el homelab y tiene permisos de escritura sobre `hd2t`.
- `UMASK=002` ayuda a que Sonarr, Transmission y Jellyfin compartan permisos de grupo coherentes.
- `SONARR_DOWNLOADS_DIR` apunta al mismo árbol de descargas que usa Transmission para evitar inconsistencias de rutas.
- `latest` sigue la última release publicada por la imagen. Si prefieres máxima reproducibilidad, fija una etiqueta concreta.

Fichero `compose.yaml`:

```yaml
name: sonarr

services:
  sonarr:
    container_name: sonarr
    image: ${SONARR_IMAGE}
    restart: unless-stopped
    env_file:
      - .env
    environment:
      PUID: ${PUID}
      PGID: ${PGID}
      TZ: ${TZ}
      UMASK: ${UMASK}
    volumes:
      - ${SONARR_CONFIG_DIR}:/config
      - type: bind
        source: ${SONARR_SERIES_DIR}
        target: /tv
      - type: bind
        source: ${SONARR_DOWNLOADS_DIR}
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

- no se publica `8989` en el host porque el punto de entrada recomendado es **Caddy**
- Sonarr ve la biblioteca final como `/tv` y las descargas como `/downloads`
- montar en Sonarr la misma ruta de descargas que usa Transmission simplifica la importación y evita depender de `Remote Path Mapping`
- tanto `/downloads` como `/tv` están sobre `hd2t`, lo que favorece importaciones eficientes y reduce copias innecesarias
- la configuración y la base de datos de Sonarr quedan en el NVMe

Despliegue inicial:

```bash
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/compose/sonarr
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/data/sonarr
sudo chown -R <usuario>:<usuario> /mnt/hd2t/media/series
sudo chown -R <usuario>:<usuario> /mnt/hd2t/downloads/transmission

cd /home/<usuario>/homelab/compose/sonarr
docker compose config
docker compose pull
docker compose up -d
docker compose ps
docker compose logs -f sonarr
```

Resultado esperado:

- el contenedor `sonarr` queda levantado
- Sonarr escucha internamente en `http://sonarr:8989`
- se crea la estructura persistente dentro de `/home/<usuario>/homelab/data/sonarr/config/`
- Sonarr puede ver la biblioteca final en `/tv`
- Sonarr puede ver las descargas de Transmission en `/downloads`
- Caddy puede publicar la UI como `https://sonarr.lan`

## Configuración

### Objetivo de esta fase

| Elemento | Estado esperado |
|---|---|
| UI local | `https://sonarr.lan` |
| Persistencia | `/home/<usuario>/homelab/data/sonarr/config/` |
| Endpoint interno | `http://sonarr:8989` |
| Biblioteca de series | `/mnt/hd2t/media/series/` |
| Descargas visibles en Sonarr | `/mnt/hd2t/downloads/transmission/` |
| Punto de entrada LAN | Caddy |
| Acceso remoto | Tailscale |
| Indexadores | sincronizados desde Prowlarr |
| Cliente de descarga | Transmission |

### 1. Preparar rutas y permisos

Crear la estructura base:

```bash
mkdir -p /home/<usuario>/homelab/compose/sonarr
mkdir -p /home/<usuario>/homelab/data/sonarr/config
mkdir -p /mnt/hd2t/media/series
```

Permisos recomendados:

```bash
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/compose/sonarr
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/data/sonarr
sudo chown -R <usuario>:<usuario> /mnt/hd2t/media/series
sudo chown -R <usuario>:<usuario> /mnt/hd2t/downloads/transmission

chmod 755 /home/<usuario>/homelab/data/sonarr
chmod 750 /home/<usuario>/homelab/data/sonarr/config
chmod -R 775 /mnt/hd2t/media/series
chmod -R 775 /mnt/hd2t/downloads/transmission
```

Sonarr depende mucho menos del contenedor que de la coherencia de permisos entre servicios. Si Transmission descarga con un UID o una máscara incompatibles, Sonarr podrá detectar episodios pero fallará al moverlos o enlazarlos al destino final.

### 2. Arrancar el servicio y completar el primer acceso

Levantar el stack:

```bash
cd /home/<usuario>/homelab/compose/sonarr
docker compose up -d
```

Comprobaciones útiles:

```bash
docker compose ps
docker compose logs -f sonarr
docker exec sonarr id
docker exec sonarr ls -lah /config
docker exec sonarr ls -lah /tv
docker exec sonarr ls -lah /downloads
```

Después, abrir:

```text
https://sonarr.lan
```

En el primer arranque:

1. Comprueba que la UI carga correctamente detrás de Caddy.
2. Verifica que la carpeta `/config` contiene base de datos, logs y configuración persistente.
3. Revisa la zona horaria y el formato regional para alinearlos con `Europe/Madrid`.
4. Decide si vas a exigir autenticación en la propia aplicación además del aislamiento por LAN y Tailscale.

Si necesitas revisar el estado interno del servicio:

```bash
cd /home/<usuario>/homelab/compose/sonarr
docker compose logs --tail=200 sonarr
```

### 3. Ajustes básicos recomendados

Antes de automatizar descargas, deja clara la política operativa:

- usa Sonarr solo para **series**
- mantén el acceso por `sonarr.lan` y por Tailscale, sin publicar el puerto en el host
- usa Prowlarr como fuente de verdad de indexadores en vez de crear indexadores manuales en Sonarr
- mantén el destino final de series en `/tv`
- evita mezclar películas u otros contenidos en esa misma biblioteca

Comprobaciones posteriores al primer acceso:

| Área | Qué revisar |
|---|---|
| General | zona horaria, idioma y comportamiento general de la UI |
| Seguridad | si vas a requerir login en la interfaz |
| Logs | ausencia de errores de permisos o escritura |
| Root folder | visibilidad correcta de `/tv` |
| Descargas | visibilidad correcta de `/downloads` |

### 4. Configurar la biblioteca y la gestión de medios

Dentro de Sonarr, la carpeta raíz recomendada para series es:

```text
/tv
```

Esto corresponde en el host a:

```text
/mnt/hd2t/media/series
```

Ajustes recomendados en **Media Management**:

- habilita el renombrado de episodios importados
- mantén activado **Completed Download Handling** para que Sonarr importe automáticamente lo que termina en Transmission
- usa carpetas por serie y por temporada para mantener orden estable
- mantén una convención de nombres consistente para que Jellyfin indexe bien el contenido
- habilita hardlinks si tu estrategia de importación lo permite, ya que descargas y biblioteca están en el mismo disco `hd2t`
- no uses carpetas raíz distintas para series del mismo tipo salvo que exista un motivo claro de organización

Objetivo práctico:

- Transmission descarga en `/downloads/complete/...`
- Sonarr detecta el episodio terminado
- Sonarr lo importa hacia `/tv/...`
- Jellyfin termina viendo la serie en su biblioteca final

Si cambias las rutas del contenedor y dejas de montar en Sonarr la misma vista de descargas que usa Transmission, probablemente necesitarás `Remote Path Mapping`. Con el esquema de este documento no debería hacer falta.

### 5. Crear perfiles de calidad

Los perfiles exactos dependen de tus preferencias, pero para este homelab doméstico conviene empezar con pocos perfiles y bien definidos.

Propuesta inicial:

| Perfil | Uso recomendado |
|---|---|
| `Series HD 1080p` | perfil por defecto para series actuales |
| `Series HD 720p` | fallback para series antiguas o menos disponibles |
| `Anime 1080p` | opcional, solo si consumes anime y quieres criterios propios |

Recomendaciones prácticas:

- define un perfil principal y evita crear demasiadas variantes desde el primer día
- coloca `1080p` por encima de `720p` si tu prioridad es calidad general
- usa `720p` como alternativa realista cuando ciertos episodios o temporadas no existan en mejor calidad
- revisa el `cutoff` para que Sonarr deje de buscar upgrades una vez alcanzada la calidad objetivo
- documenta fuera de Sonarr cualquier excepción relevante para no convertir la UI en una colección de reglas difíciles de mantener

Criterio razonable para empezar:

- series generales: prioriza WEB y Bluray en `1080p`
- series antiguas o con disponibilidad irregular: permite `720p`
- no añadas perfiles especiales de remux, 4K o anime si todavía no tienes una necesidad real

### 6. Integración con Transmission

La integración recomendada es usar **Transmission** como cliente de descarga interno por Docker.

Endpoint interno esperado:

| Aplicación | URL interna esperada |
|---|---|
| Sonarr | `http://sonarr:8989` |
| Transmission | `http://transmission:9091` |

Preparación necesaria:

- Transmission debe estar desplegado y funcionando según `docs/10-descargas/01-transmission.md`
- Sonarr y Transmission deben compartir una red Docker
- las credenciales de Transmission deben estar a mano
- Sonarr debe ver el árbol de descargas en `/downloads`

Flujo recomendado dentro de Sonarr:

1. Añade un nuevo **Download Client** de tipo Transmission.
2. Usa `transmission` como host y `9091` como puerto.
3. Deja el `URL Base` vacío salvo que hayas cambiado la ruta base por defecto en Transmission.
4. Introduce usuario y contraseña de la UI de Transmission.
5. Ejecuta la prueba de conexión antes de guardar.
6. Comprueba que Sonarr puede listar la cola y recoger descargas terminadas.

Validaciones:

- Sonarr conecta correctamente con Transmission por nombre de servicio
- no necesitas exponer `9091` en el host para esta integración
- la descarga completada se ve desde Sonarr en `/downloads/complete/...`
- no aparecen errores de permisos al importar episodios

### 7. Integración con Prowlarr

La integración recomendada es que **Prowlarr empuje indexadores hacia Sonarr** usando la API interna del servicio.

Endpoint interno esperado:

| Aplicación | URL interna esperada |
|---|---|
| Prowlarr | `http://prowlarr:9696` |
| Sonarr | `http://sonarr:8989` |

Preparación necesaria:

- Prowlarr debe estar desplegado y funcionando según `docs/10-descargas/02-prowlarr.md`
- debes obtener la API key de Sonarr desde su interfaz
- Sonarr y Prowlarr deben compartir una red Docker

Flujo recomendado:

1. En Sonarr, localiza y copia la API key.
2. En Prowlarr, añade Sonarr como aplicación externa usando `http://sonarr:8989`.
3. Ejecuta la prueba de conexión desde Prowlarr.
4. Sincroniza indexadores.
5. Verifica en Sonarr que los indexadores aparecen importados.

Criterio práctico:

- gestiona indexadores en Prowlarr
- gestiona perfiles, series y automatización en Sonarr
- evita configurar el mismo indexador a mano en ambos lados

### 8. Importar una serie de prueba y validar el flujo completo

Antes de cargar toda tu biblioteca, valida el circuito con una sola serie:

1. Añade una serie de prueba en Sonarr.
2. Asigna el perfil de calidad principal.
3. Confirma que la carpeta raíz seleccionada es `/tv`.
4. Lanza una búsqueda manual o automática.
5. Comprueba que Sonarr envía la descarga a Transmission.
6. Espera a que el archivo termine en `/downloads/complete/`.
7. Verifica que Sonarr importa el episodio hacia `/tv/<Serie>/...`.

Resultado esperado:

- la solicitud nace en Sonarr
- el indexador llega desde Prowlarr
- la descarga se ejecuta en Transmission
- el episodio acaba en la biblioteca final de `hd2t`

### 9. Publicación detrás de Caddy

Este documento asume que **Caddy** publica Sonarr en la LAN con:

```text
https://sonarr.lan
```

Validaciones:

- `sonarr` y `caddy` deben estar en `homelab_proxy`
- `https://sonarr.lan` debe responder con la UI de Sonarr
- el certificado será el de la CA interna de Caddy para la LAN
- si la página no carga, revisa DNS local, red compartida y logs de ambos contenedores

## Almacenamiento

Distribución de datos recomendada:

| Tipo de dato | Ruta |
|---|---|
| Compose del servicio | `/home/<usuario>/homelab/compose/sonarr/` |
| Configuración persistente | `/home/<usuario>/homelab/data/sonarr/config/` |
| Biblioteca final de series | `/mnt/hd2t/media/series/` |
| Descargas visibles para importación | `/mnt/hd2t/downloads/transmission/` |

Criterios de esta distribución:

- el **NVMe** absorbe base de datos, configuración, logs y estado de la aplicación
- `hd2t` absorbe la biblioteca final y el trabajo pesado de importación
- usar el mismo disco para descargas e importación simplifica operaciones y reduce fricción con permisos
- separar configuración y biblioteca facilita backups y recuperación

Qué guarda Sonarr en `/config` habitualmente:

- base de datos interna
- configuración de la aplicación
- logs
- cachés y metadatos del servicio

Qué guarda `hd2t` para este flujo:

- la biblioteca final en `/mnt/hd2t/media/series/`
- las descargas temporales o recién completadas en `/mnt/hd2t/downloads/transmission/`

## Backup

Respaldar como mínimo:

- `/home/<usuario>/homelab/compose/sonarr/`
- `/home/<usuario>/homelab/data/sonarr/config/`

Respaldar de forma opcional según tu estrategia:

- `/mnt/hd2t/media/series/` si no forma parte ya del backup global multimedia
- `/mnt/hd2t/downloads/transmission/complete/` si hay episodios aún no importados

Recomendación práctica:

- trata `config/` como **obligatorio**
- trata la biblioteca final como parte del backup multimedia del homelab
- evita respaldar descargas incompletas salvo que tengas un motivo operativo claro
- antes de un backup coherente, para brevemente el contenedor para evitar copiar la base de datos en mitad de una escritura

Parada breve antes del backup:

```bash
cd /home/<usuario>/homelab/compose/sonarr
docker compose stop sonarr
```

Después del backup:

```bash
docker compose up -d
```

## Referencias
- Documentación de Sonarr: `https://wiki.servarr.com/sonarr`
- Guía Docker de Servarr: `https://wiki.servarr.com/docker-guide`
- Repositorio oficial de Sonarr: `https://github.com/Sonarr/Sonarr`
- Imagen LinuxServer para Sonarr: `https://docs.linuxserver.io/images/docker-sonarr/`
- Imagen Docker: `https://hub.docker.com/r/linuxserver/sonarr`
