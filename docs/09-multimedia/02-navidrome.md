# Navidrome

## Descripción
**Navidrome** será el servidor de música del homelab, compatible con la **API OpenSubsonic / Subsonic**, para servir la biblioteca musical almacenada en `hd2t` a navegadores web y clientes móviles como **DSub** y **Symfonium** dentro de la LAN o a través de Tailscale.

En esta arquitectura se despliega sobre la **Raspberry Pi 5** con estas reglas:

- el servicio y su estado persistente viven en el **SSD NVMe**
- la biblioteca musical vive en **`/mnt/hd2t/navidrome/music`**
- el acceso web local se publica detrás de **Caddy** con `https://navidrome.lan`
- el acceso remoto sigue siendo **solo Tailscale**, sin abrir puertos en el router
- la base de datos integrada de Navidrome es suficiente para este homelab y queda alojada en el NVMe

Navidrome encaja muy bien en este diseño porque consume pocos recursos, funciona correctamente en ARM64, indexa colecciones grandes sin depender de una base de datos externa y expone una API compatible con muchos clientes Subsonic ya maduros.

## Requisitos Previos
- Haber completado `docs/02-docker/01-instalacion-docker.md`.
- Haber completado `docs/02-docker/02-estructura-compose.md`.
- Haber completado `docs/01-sistema/04-estructura-directorios.md`.
- Haber completado `docs/03-red/04-caddy.md` para publicar `navidrome.lan`.
- Haber completado `docs/03-red/05-tailscale.md` si quieres acceso remoto por VPN mesh.
- Tener creada la red Docker externa `homelab_proxy`.
- Tener resuelto en Pi-hole o en tu DNS local el FQDN `navidrome.lan` apuntando a la IP LAN principal de la Raspberry Pi.
- Tener montado `hd2t` en `/mnt/hd2t`.
- Tener espacio suficiente en el SSD NVMe para:
  - base de datos interna
  - caché y carátulas
  - configuración persistente del servicio
- Poder usar `sudo` con el usuario administrador del homelab.
- Puertos implicados en esta fase:
  - `4533/tcp` solo dentro de Docker entre Caddy y el contenedor `navidrome`
  - `80/tcp` y `443/tcp` ya publicados por Caddy en el host
  - no se abre ningún puerto entrante en el router

## Docker Compose
Directorio recomendado:

```text
/home/<usuario>/homelab/compose/navidrome/
├── compose.yaml
└── .env
```

Preparación inicial de rutas:

```bash
mkdir -p /home/<usuario>/homelab/compose/navidrome
mkdir -p /home/<usuario>/homelab/data/navidrome/data
mkdir -p /mnt/hd2t/navidrome/music
```

Fichero `.env`:

```dotenv
TZ=Europe/Madrid

NAVIDROME_IMAGE=deluan/navidrome:latest

PUID=1000
PGID=1000

NAVIDROME_LOGLEVEL=info

NAVIDROME_DATA_DIR=/home/<usuario>/homelab/data/navidrome/data
NAVIDROME_MUSIC_DIR=/mnt/hd2t/navidrome/music
```

Notas sobre estas variables:

- `PUID` y `PGID` deben corresponder al usuario real que administra el homelab y tiene acceso a la música montada en `hd2t`.
- `latest` sigue la última release estable publicada por el proyecto. Si quieres máxima reproducibilidad, fija una etiqueta concreta.
- `NAVIDROME_LOGLEVEL=info` es una base razonable para producción doméstica; súbelo a `debug` solo cuando estés diagnosticando incidencias.
- `NAVIDROME_DATA_DIR` se guarda en el NVMe porque contiene la base de datos y la caché del servicio.

Fichero `compose.yaml`:

```yaml
name: navidrome

services:
  navidrome:
    container_name: navidrome
    image: ${NAVIDROME_IMAGE}
    user: "${PUID}:${PGID}"
    restart: unless-stopped
    env_file:
      - .env
    environment:
      TZ: ${TZ}
      ND_LOGLEVEL: ${NAVIDROME_LOGLEVEL}
    volumes:
      - ${NAVIDROME_DATA_DIR}:/data
      - type: bind
        source: ${NAVIDROME_MUSIC_DIR}
        target: /music
        read_only: true
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

- no se publica `4533` en el host porque el punto de entrada recomendado es **Caddy**
- la biblioteca se monta en solo lectura para proteger los archivos musicales originales
- la base de datos integrada de Navidrome queda dentro de `/data`, en el NVMe
- no hace falta una base de datos externa para este caso de uso

Despliegue inicial:

```bash
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/compose/navidrome
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/data/navidrome
sudo chown -R <usuario>:<usuario> /mnt/hd2t/navidrome

cd /home/<usuario>/homelab/compose/navidrome
docker compose config
docker compose pull
docker compose up -d
docker compose ps
docker compose logs -f navidrome
```

Resultado esperado:

- el contenedor `navidrome` queda levantado
- Navidrome escucha internamente en `http://navidrome:4533`
- se crea la estructura persistente en `/home/<usuario>/homelab/data/navidrome/`
- la biblioteca musical de `hd2t` queda visible desde el contenedor en `/music`
- Caddy puede publicar el servicio como `https://navidrome.lan`

## Configuración

### Objetivo de esta fase

| Elemento | Estado esperado |
|---|---|
| UI local | `https://navidrome.lan` |
| Persistencia | `/home/<usuario>/homelab/data/navidrome/` |
| Biblioteca musical | `/mnt/hd2t/navidrome/music/` |
| Punto de entrada LAN | Caddy |
| Acceso remoto | Tailscale |
| API de clientes | OpenSubsonic / Subsonic |
| Clientes recomendados | DSub, Symfonium |

### 1. Preparar rutas y permisos

Crear la estructura base:

```bash
mkdir -p /home/<usuario>/homelab/compose/navidrome
mkdir -p /home/<usuario>/homelab/data/navidrome/data
mkdir -p /mnt/hd2t/navidrome/music
```

Permisos recomendados:

```bash
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/compose/navidrome
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/data/navidrome
sudo chown -R <usuario>:<usuario> /mnt/hd2t/navidrome

chmod 755 /home/<usuario>/homelab/data/navidrome
chmod 750 /home/<usuario>/homelab/data/navidrome/data
```

Si `hd2t` viene de otro sistema de ficheros o se monta con un propietario distinto, corrige antes permisos y ACL. El problema más habitual en Navidrome no suele ser Docker, sino que el contenedor no pueda leer correctamente la jerarquía musical o las carátulas embebidas.

### 2. Arrancar el servicio y completar el asistente inicial

Levantar el stack:

```bash
cd /home/<usuario>/homelab/compose/navidrome
docker compose up -d
```

Comprobaciones útiles:

```bash
docker compose ps
docker compose logs -f navidrome
docker exec navidrome id
docker exec navidrome ls -lah /music
docker exec navidrome ls -lah /data
```

Después, abrir:

```text
https://navidrome.lan
```

En el primer arranque:

1. Crear el usuario administrador.
2. Confirmar que la biblioteca se detecta correctamente.
3. Esperar al primer escaneo si la colección es grande.
4. Revisar artistas, álbumes, carátulas y metadatos.
5. Confirmar que la reproducción web funciona antes de configurar clientes externos.

### 3. Estructura recomendada de la biblioteca musical

Ruta recomendada en el host:

```text
/mnt/hd2t/navidrome/music/
```

Estructura sugerida:

```text
/mnt/hd2t/navidrome/music/
├── Artista 1/
│   ├── Álbum 1/
│   │   ├── 01 - Tema 1.flac
│   │   └── 02 - Tema 2.flac
│   └── Álbum 2/
└── Varios/
```

Buenas prácticas para que Navidrome indexe bien:

- usa una jerarquía estable por artista y álbum
- mantén etiquetas ID3/Vorbis limpias y consistentes
- evita mezclar música definitiva con descargas temporales
- conserva nombres de archivo legibles aunque los metadatos sean la referencia principal
- recuerda que Navidrome se apoya principalmente en metadatos, no en navegación real por carpetas
- deja la biblioteca en solo lectura desde el contenedor salvo que tengas una razón operativa clara para lo contrario

### 4. Ajustes recomendados en la UI

Nada más terminar el asistente, revisa:

1. **Settings > Transcoding** solo si necesitas convertir formatos concretos para algún cliente antiguo.
2. **Settings > Players** o ajustes equivalentes para revisar el comportamiento de reproducción.
3. **Users** para crear cuentas separadas si habrá varios usuarios.
4. **Scanning** y refresco de biblioteca para validar el ritmo de reindexado que te conviene.
5. **Activity** y logs para detectar errores de permisos o metadatos.

Buenas prácticas específicas para este homelab:

- prioriza reproducción directa y evita transcodificación innecesaria
- deja la música en formatos bien soportados por tus clientes habituales
- si la colección es grande, lanza el primer escaneo en un momento de baja actividad
- si usas audio sin pérdida, comprueba el consumo de red y batería en clientes móviles

### 5. Integración con Caddy

La integración esperada con `docs/03-red/04-caddy.md` es el bloque:

```caddyfile
navidrome.lan {
  import common
  tls internal
  reverse_proxy navidrome:4533
}
```

Después de levantar ambos stacks:

```bash
docker network inspect homelab_proxy
docker compose -f /home/<usuario>/homelab/compose/caddy/compose.yaml ps
docker compose -f /home/<usuario>/homelab/compose/navidrome/compose.yaml ps
```

Validaciones:

- `navidrome` y `caddy` deben estar en `homelab_proxy`
- `https://navidrome.lan` debe responder con la pantalla inicial o el login
- el certificado será el de la CA interna de Caddy para la LAN

### 6. Clientes compatibles: DSub y Symfonium

Navidrome expone la **API OpenSubsonic / Subsonic**, por lo que funciona con muchos clientes existentes. Para este homelab, dos opciones prácticas son:

- **DSub** si quieres un cliente Subsonic clásico y ligero
- **Symfonium** si prefieres una experiencia más pulida y flexible en Android

Configuración base en ambos clientes:

1. URL del servidor: `https://navidrome.lan`
2. Usuario y contraseña creados en Navidrome
3. Activar reproducción por streaming o caché local según tu preferencia
4. Probar primero en la LAN antes de usarlo sobre Tailscale

Si el cliente no confía en la CA interna de Caddy, tienes tres opciones:

- instalar la CA interna en el dispositivo cliente
- usar un acceso Tailscale alternativo que ya tengas resuelto y en el que confíe el cliente
- publicar Navidrome en una subruta bajo el endpoint de Caddy usado para Tailscale

Si eliges una subruta, por ejemplo `/navidrome`, alinea proxy y aplicación:

```caddyfile
handle_path /navidrome/* {
  reverse_proxy navidrome:4533
}
```

Y añade en el `compose.yaml`:

```yaml
environment:
  TZ: ${TZ}
  ND_BASEURL: /navidrome
```

Después recrea el contenedor:

```bash
cd /home/<usuario>/homelab/compose/navidrome
docker compose up -d --force-recreate
```

### 7. Tailscale y acceso remoto

El patrón recomendado para simplicidad operativa es:

- usar `https://navidrome.lan` dentro de la LAN
- entrar por Tailscale cuando estés fuera de casa
- consumir Navidrome usando el hostname o la ruta remota que hayas estandarizado en Caddy

Antes de darlo por válido, prueba:

- login desde navegador en LAN
- reproducción desde DSub o Symfonium en LAN
- login y reproducción desde un dispositivo conectado por Tailscale

## Almacenamiento

Distribución de datos recomendada:

| Tipo de dato | Ruta |
|---|---|
| Compose del servicio | `/home/<usuario>/homelab/compose/navidrome/` |
| Datos persistentes de Navidrome | `/home/<usuario>/homelab/data/navidrome/data/` |
| Biblioteca de música | `/mnt/hd2t/navidrome/music/` |

Criterios de esta distribución:

- el **NVMe** absorbe la parte sensible a latencia y escritura frecuente
- `hd2t` almacena únicamente la biblioteca musical grande y relativamente fría
- la biblioteca se monta como `read_only` para proteger los archivos originales
- el servicio queda desacoplado de la música: puedes restaurar la base de datos o reindexar sin mover los ficheros del disco USB

Qué guarda Navidrome en `/data` habitualmente:

- base de datos interna
- carátulas y caché
- preferencias persistentes del servicio
- estado de usuarios y reproducción

## Backup

Respaldar como mínimo:

- `/home/<usuario>/homelab/compose/navidrome/`
- `/home/<usuario>/homelab/data/navidrome/data/`

Respaldar de forma opcional según tu estrategia:

- `/mnt/hd2t/navidrome/music/` si `hd2t` no es ya la copia maestra de tu colección musical

Recomendación práctica:

- trata `data/` como **obligatorio**
- trata la biblioteca musical según la realidad de tus ficheros: si `hd2t` es el único origen, entonces debe entrar también en la estrategia 3-2-1
- no confundas el backup integrado de Navidrome con un backup completo del servicio: el mecanismo interno solo exporta la base de datos, no la música ni la configuración del contenedor

Antes de un backup importante o una actualización mayor:

```bash
cd /home/<usuario>/homelab/compose/navidrome
docker compose stop navidrome
```

Después de copiar `data/`, volver a arrancar:

```bash
docker compose up -d
```

Navidrome usa una base de datos integrada, así que una parada breve antes del backup reduce el riesgo de copiar un estado inconsistente.

Si quieres aprovechar además el sistema de backup interno de Navidrome, úsalo como complemento para recuperar usuarios, favoritos, play counts y playlists, pero no como sustituto de las copias del NVMe y de `hd2t`.

## Referencias
- Documentación oficial de Navidrome: `https://www.navidrome.org/docs/`
- Instalación con Docker: `https://www.navidrome.org/docs/installation/docker/`
- Configuración y variables: `https://www.navidrome.org/docs/usage/configuration/options/`
- Getting Started: `https://www.navidrome.org/docs/getting-started/`
- Backups automáticos: `https://www.navidrome.org/docs/usage/admin/backup/`
- Catálogo oficial de apps: `https://www.navidrome.org/apps/`
- Imagen oficial Docker Hub: `https://hub.docker.com/r/deluan/navidrome`
