# Prowlarr

## Descripción
**Prowlarr** será el gestor centralizado de indexadores del homelab para evitar duplicar configuración entre **Sonarr** y **Radarr**.

En esta arquitectura se despliega sobre la **Raspberry Pi 5** con estos criterios:

- la configuración persistente vive en el **SSD NVMe**
- no almacena bibliotecas multimedia ni descargas pesadas en `hd2t` o `hd5t`
- la interfaz web local se publica detrás de **Caddy** con `https://prowlarr.lan`
- el acceso sigue siendo **solo LAN + Tailscale**, sin abrir puertos en el router
- Prowlarr actuará como punto único para dar de alta, probar y sincronizar indexadores hacia Sonarr y Radarr

Prowlarr encaja bien en este homelab porque reduce trabajo administrativo, centraliza credenciales de trackers y permite mantener una política coherente de indexadores para series y películas.

## Requisitos Previos
- Haber completado `docs/02-docker/01-instalacion-docker.md`.
- Haber completado `docs/02-docker/02-estructura-compose.md`.
- Haber completado `docs/01-sistema/04-estructura-directorios.md`.
- Haber completado `docs/03-red/04-caddy.md` para publicar `prowlarr.lan`.
- Haber completado `docs/03-red/05-tailscale.md` si quieres acceso remoto por VPN mesh.
- Tener creada la red Docker externa `homelab_proxy`.
- Tener resuelto en Pi-hole o en tu DNS local el FQDN `prowlarr.lan` apuntando a la IP LAN principal de la Raspberry Pi.
- Poder usar `sudo` con el usuario administrador del homelab.
- Para la integración posterior, Sonarr y Radarr deberán compartir red Docker con Prowlarr.
- Puertos implicados en esta fase:
  - `9696/tcp` solo dentro de Docker entre Caddy, Prowlarr, Sonarr y Radarr
  - `80/tcp` y `443/tcp` ya publicados por Caddy en el host
  - no se abre ningún puerto entrante en el router

## Docker Compose
Directorio recomendado:

```text
/home/<usuario>/homelab/compose/prowlarr/
├── compose.yaml
└── .env
```

Preparación inicial de rutas:

```bash
mkdir -p /home/<usuario>/homelab/compose/prowlarr
mkdir -p /home/<usuario>/homelab/data/prowlarr/config
```

Fichero `.env`:

```dotenv
TZ=Europe/Madrid

PROWLARR_IMAGE=lscr.io/linuxserver/prowlarr:latest

PUID=1000
PGID=1000
UMASK=002

PROWLARR_CONFIG_DIR=/home/<usuario>/homelab/data/prowlarr/config
```

Notas sobre estas variables:

- `PUID` y `PGID` deben corresponder al usuario real que administra el homelab.
- `UMASK=002` ayuda a mantener permisos de grupo coherentes sobre logs, base de datos y ficheros de configuración.
- `latest` sigue la última release publicada por la imagen. Si prefieres máxima reproducibilidad, fija una etiqueta concreta.

Fichero `compose.yaml`:

```yaml
name: prowlarr

services:
  prowlarr:
    container_name: prowlarr
    image: ${PROWLARR_IMAGE}
    restart: unless-stopped
    env_file:
      - .env
    environment:
      PUID: ${PUID}
      PGID: ${PGID}
      TZ: ${TZ}
      UMASK: ${UMASK}
    volumes:
      - ${PROWLARR_CONFIG_DIR}:/config
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

- no se publica `9696` en el host porque el punto de entrada recomendado es **Caddy**
- toda la persistencia queda en el NVMe, que es donde mejor encajan la base de datos SQLite, logs y estado del servicio
- Prowlarr no necesita acceso directo a `hd2t` ni a `hd5t`
- Sonarr y Radarr podrán consumirlo por nombre de servicio si comparten una red Docker común

Despliegue inicial:

```bash
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/compose/prowlarr
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/data/prowlarr

cd /home/<usuario>/homelab/compose/prowlarr
docker compose config
docker compose pull
docker compose up -d
docker compose ps
docker compose logs -f prowlarr
```

Resultado esperado:

- el contenedor `prowlarr` queda levantado
- Prowlarr escucha internamente en `http://prowlarr:9696`
- se crea la estructura persistente dentro de `/home/<usuario>/homelab/data/prowlarr/config/`
- Caddy puede publicar la UI como `https://prowlarr.lan`

## Configuración

### Objetivo de esta fase

| Elemento | Estado esperado |
|---|---|
| UI local | `https://prowlarr.lan` |
| Persistencia | `/home/<usuario>/homelab/data/prowlarr/config/` |
| Endpoint interno | `http://prowlarr:9696` |
| Punto de entrada LAN | Caddy |
| Acceso remoto | Tailscale |
| Rol principal | gestión unificada de indexadores |
| Consumidores futuros | Sonarr y Radarr |

### 1. Preparar rutas y permisos

Crear la estructura base:

```bash
mkdir -p /home/<usuario>/homelab/compose/prowlarr
mkdir -p /home/<usuario>/homelab/data/prowlarr/config
```

Permisos recomendados:

```bash
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/compose/prowlarr
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/data/prowlarr

chmod 755 /home/<usuario>/homelab/data/prowlarr
chmod 750 /home/<usuario>/homelab/data/prowlarr/config
```

Prowlarr es menos exigente en almacenamiento que un gestor multimedia, pero conviene mantener permisos claros desde el principio porque su base de datos, los logs y las definiciones del servicio deben permanecer consistentes entre reinicios y actualizaciones.

### 2. Arrancar el servicio y completar el primer acceso

Levantar el stack:

```bash
cd /home/<usuario>/homelab/compose/prowlarr
docker compose up -d
```

Comprobaciones útiles:

```bash
docker compose ps
docker compose logs -f prowlarr
docker exec prowlarr id
docker exec prowlarr ls -lah /config
```

Después, abrir:

```text
https://prowlarr.lan
```

En el primer arranque:

1. Comprueba que la UI carga correctamente detrás de Caddy.
2. Verifica que la carpeta `/config` contiene base de datos, logs y configuración persistente.
3. Revisa la zona horaria y el formato regional para alinearlos con `Europe/Madrid`.
4. Decide si vas a activar autenticación en la propia aplicación además del aislamiento por LAN y Tailscale.

Si necesitas revisar el estado interno del servicio:

```bash
cd /home/<usuario>/homelab/compose/prowlarr
docker compose logs --tail=200 prowlarr
```

### 3. Ajustes básicos recomendados

Antes de añadir indexadores, deja clara la política operativa:

- usa Prowlarr como punto único de administración y evita crear indexadores manuales por separado en Sonarr o Radarr
- mantén el servicio accesible solo por `prowlarr.lan` y por Tailscale
- documenta fuera de la aplicación qué indexadores son públicos, cuáles son privados y qué credenciales o passkeys usa cada uno
- si varias personas usan el homelab, activa autenticación en la UI en vez de dejar acceso anónimo dentro de la red local

Comprobaciones posteriores al primer acceso:

| Área | Qué revisar |
|---|---|
| General | zona horaria y comportamiento general de la UI |
| Seguridad | si vas a requerir login en la interfaz |
| Logs | ausencia de errores de permisos o escritura |
| Conectividad | resolución correcta de `prowlarr.lan` y acceso por Caddy |

### 4. Añadir indexadores

Prowlarr no descarga contenido por sí mismo. Su función aquí es centralizar indexadores y distribuirlos a las aplicaciones consumidoras.

Recomendaciones de operación:

- empieza con pocos indexadores fiables y evita importar una lista masiva desde el primer día
- separa conceptualmente indexadores de **series** y de **películas**, aunque después los centralices en la misma UI
- etiqueta o agrupa indexadores según su uso real si manejas distintos tipos de contenido
- prueba cada indexador inmediatamente después de añadirlo
- si un tracker es privado, guarda su passkey o credenciales de forma ordenada y evita exponer capturas o exportaciones sin sanitizar

Flujo recomendado dentro de la UI:

1. Añade el indexador.
2. Completa URL, credenciales y parámetros requeridos por ese tracker.
3. Ejecuta la prueba de conexión.
4. Revisa categorías, capacidades y límites.
5. Guarda solo cuando el test sea correcto.

Criterio práctico para este homelab:

- Prowlarr debe ser la fuente de verdad de indexadores
- Sonarr y Radarr deben limitarse a consumir los indexadores sincronizados desde Prowlarr
- si un indexador falla, depúralo primero en Prowlarr y no dentro de cada aplicación por separado

### 5. Organizar categorías y Sync Profiles

Para que la integración con Sonarr y Radarr sea predecible, conviene ordenar los indexadores antes de sincronizarlos.

Qué revisar en cada indexador:

- categorías asignadas a **TV** y **Movies**
- soporte real para búsquedas interactivas, RSS y búsqueda histórica
- límites o restricciones del tracker
- idioma, prioridades o etiquetas si quieres discriminar mejor ciertos orígenes

Recomendación operativa:

- deja que **Sonarr** reciba solo categorías relacionadas con series
- deja que **Radarr** reciba solo categorías relacionadas con películas
- evita enviar indiscriminadamente todos los indexadores a todas las aplicaciones

Si usas **Sync Profiles** o filtros equivalentes en Prowlarr:

- crea un perfil claro para TV y otro para cine
- asigna cada aplicación al perfil que realmente necesita
- revisa después de cada cambio que la sincronización no haya introducido indexadores innecesarios

### 6. Integración con Sonarr y Radarr

La integración recomendada es que **Prowlarr empuje indexadores hacia Sonarr y Radarr** usando conectividad interna por Docker.

Endpoints internos recomendados:

| Aplicación | URL interna esperada |
|---|---|
| Prowlarr | `http://prowlarr:9696` |
| Sonarr | `http://sonarr:8989` |
| Radarr | `http://radarr:7878` |

Preparación necesaria cuando Sonarr y Radarr estén desplegados:

- ambos contenedores deben compartir al menos una red Docker con Prowlarr
- debes obtener la API key de Sonarr y la API key de Radarr desde sus respectivas interfaces
- conviene que sus relojes, zona horaria y resolución DNS estén alineados

Flujo recomendado de integración:

1. Despliega Sonarr y Radarr en la misma red Docker.
2. Comprueba conectividad entre contenedores por nombre de servicio.
3. En Prowlarr, añade Sonarr y Radarr como aplicaciones externas usando sus URLs internas y sus API keys.
4. Ejecuta la prueba de conexión para cada una.
5. Asocia el perfil de sincronización o el conjunto de indexadores adecuado a cada aplicación.
6. Lanza una primera sincronización.
7. Verifica en Sonarr y Radarr que los indexadores aparecen importados desde Prowlarr.

Comprobaciones útiles desde terminal:

```bash
docker network inspect homelab_proxy
docker exec prowlarr getent hosts sonarr
docker exec prowlarr getent hosts radarr
```

Qué validar después de sincronizar:

- los indexadores aparecen en Sonarr y Radarr sin tener que recrearlos manualmente
- las pruebas de conexión desde cada aplicación son correctas
- las categorías asociadas a series y películas son coherentes con el uso esperado
- si haces cambios de indexadores en Prowlarr, la sincronización los replica donde corresponde

### 7. Cuándo no usar Prowlarr como cliente de descargas

En este diseño, **Transmission** se integra con Sonarr y Radarr, no con Prowlarr.

Consejo operativo:

- usa Prowlarr para **indexadores**
- usa Sonarr y Radarr para **automatización y búsquedas**
- usa Transmission para **descargar**

Eso mantiene cada servicio en su rol y evita configuraciones duplicadas. Solo tendría sentido configurar un cliente de descarga dentro de Prowlarr si quieres usar búsquedas manuales desde la propia UI de Prowlarr y enviar resultados directamente a un downloader.

### 8. Integración con Caddy

La integración esperada con `docs/03-red/04-caddy.md` es el bloque:

```caddyfile
prowlarr.lan {
  import common
  tls internal
  reverse_proxy prowlarr:9696
}
```

Después de levantar ambos stacks:

```bash
docker network inspect homelab_proxy
docker compose -f /home/<usuario>/homelab/compose/caddy/compose.yaml ps
docker compose -f /home/<usuario>/homelab/compose/prowlarr/compose.yaml ps
```

Validaciones:

- `prowlarr` y `caddy` deben estar en `homelab_proxy`
- `https://prowlarr.lan` debe responder con la UI de Prowlarr
- el certificado será el de la CA interna de Caddy para la LAN
- si la página no carga, revisa DNS local, red compartida y logs de ambos contenedores

## Almacenamiento

Distribución de datos recomendada:

| Tipo de dato | Ruta |
|---|---|
| Compose del servicio | `/home/<usuario>/homelab/compose/prowlarr/` |
| Configuración persistente | `/home/<usuario>/homelab/data/prowlarr/config/` |

Criterios de esta distribución:

- el **NVMe** absorbe toda la persistencia de Prowlarr
- `hd2t` y `hd5t` no participan directamente en este servicio
- mantener la aplicación fuera de los discos multimedia simplifica backups y recuperación

Qué guarda Prowlarr en `/config` habitualmente:

- base de datos interna
- configuración de la aplicación
- logs
- cachés y metadatos del servicio

## Backup

Respaldar como mínimo:

- `/home/<usuario>/homelab/compose/prowlarr/`
- `/home/<usuario>/homelab/data/prowlarr/config/`

Recomendación práctica:

- trata `config/` como **obligatorio**
- antes de un backup coherente, para brevemente el contenedor para evitar copiar la base de datos en mitad de una escritura
- no necesitas incluir `hd2t` ni `hd5t` en la estrategia específica de backup de Prowlarr

Parada breve antes del backup:

```bash
cd /home/<usuario>/homelab/compose/prowlarr
docker compose stop prowlarr
```

Después del backup:

```bash
docker compose up -d
```

## Referencias
- Documentación de Prowlarr: `https://wiki.servarr.com/prowlarr`
- Guía rápida de Prowlarr: `https://wiki.servarr.com/prowlarr/quick-start-guide`
- Repositorio oficial de Prowlarr: `https://github.com/Prowlarr/Prowlarr`
- Imagen LinuxServer para Prowlarr: `https://docs.linuxserver.io/images/docker-prowlarr/`
- Imagen Docker: `https://hub.docker.com/r/linuxserver/prowlarr`
