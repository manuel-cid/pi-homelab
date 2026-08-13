# Mealie

## Descripción

**Mealie** es el gestor de recetas, planificación de comidas y listas de compra de este homelab. Encaja bien como servicio personal o familiar porque funciona correctamente con **SQLite** para despliegues pequeños, permite importar recetas desde URLs y concentra toda su persistencia en un único directorio sobre el **SSD NVMe**.

En esta Raspberry Pi 5 la topología más simple y coherente es esta:

- la aplicación vive en `/home/<user>/homelab/compose/productivity-mealie/`
- todos los datos persistentes viven en `/home/<user>/homelab/data/mealie/` sobre el **SSD NVMe**
- el servicio se publica en `16003/tcp` para acceso desde **LAN** y **Tailscale**
- no se usan `hd2t` ni `hd5t` para datos activos de Mealie
- se fija una **versión concreta** de la imagen en lugar de `latest`, para poder actualizar conscientemente tras revisar cambios y notas de versión

Para este homelab esa combinación es suficiente: instalación sencilla, backup fácil y soporte cómodo para importar recetas desde navegador o desde listas de URLs.

Cuando en este documento aparezcan `<user>`, `<ip-lan-de-la-pi>`, `<tailnet>` o `<group-slug>`, sustitúyelos por los valores reales de tu entorno antes de ejecutar comandos, fijar `BASE_URL` o guardar bookmarklets.

## Requisitos Previos

- Haber completado [02-estructura-compose.md](../02-docker/02-estructura-compose.md).
- Haber completado [04-tailscale.md](../03-red/04-tailscale.md) si quieres acceder también desde fuera de casa a través de la tailnet.
- Revisar [06-puertos-y-firewall.md](../03-red/06-puertos-y-firewall.md) para mantener documentado el puerto asignado al servicio.
- Revisar [01-estrategia-backup.md](../07-backups/01-estrategia-backup.md) para la política general y [03-backup-docker-volumes.md](../07-backups/03-backup-docker-volumes.md) si vas a incluir el bind mount de Mealie en la estrategia de copias.
- Disponer de `/home/<user>/homelab/` en el **SSD NVMe** con permisos normales para el usuario administrador.
- Tener decidida la **URL canónica** que usarás como `BASE_URL` y sustituir cualquier placeholder antes de desplegar. Para acceso directo sin reverse proxy suele bastar `http://pi-homelab.<tailnet>.ts.net:16003` o `http://<ip-lan-de-la-pi>:16003`, pero conviene escoger **una sola** como referencia operativa y mantenerla en clientes, bookmarklets y pruebas.
- Permitir salida a internet para el contenedor si vas a usar la importación de recetas desde URL; Mealie la necesita para recuperar contenido remoto, aunque el homelab siga sin exponer puertos entrantes.
- Puertos necesarios en esta fase:
  - **`16003/tcp` publicado en el host** para acceso web desde LAN y Tailscale
  - **`9000/tcp`** es el puerto interno del contenedor

## Docker Compose

Archivo: `/home/<user>/homelab/compose/productivity-mealie/docker-compose.yml`

```yaml
name: productivity-mealie

services:
  mealie:
    image: ghcr.io/mealie-recipes/mealie:v3.22.0
    container_name: mealie
    restart: unless-stopped
    env_file:
      - .env
    environment:
      PUID: ${PUID}
      PGID: ${PGID}
      TZ: ${TZ}
      BASE_URL: ${MEALIE_BASE_URL}
      ALLOW_SIGNUP: ${MEALIE_ALLOW_SIGNUP}
      DEFAULT_EMAIL: ${MEALIE_DEFAULT_EMAIL}
      DEFAULT_GROUP: ${MEALIE_DEFAULT_GROUP}
      DEFAULT_HOUSEHOLD: ${MEALIE_DEFAULT_HOUSEHOLD}
      SECURITY_MAX_LOGIN_ATTEMPTS: ${MEALIE_MAX_LOGIN_ATTEMPTS}
      SECURITY_USER_LOCKOUT_TIME: ${MEALIE_LOCKOUT_HOURS}
      LOG_LEVEL: ${MEALIE_LOG_LEVEL}
    ports:
      - "${MEALIE_BIND_IP}:${MEALIE_PORT}:9000"
    volumes:
      - ${DATA_ROOT}/mealie:/app/data
    mem_limit: 1g
    labels:
      - wud.watch=false
```

Archivo recomendado: `/home/<user>/homelab/compose/productivity-mealie/.env`

```dotenv
PUID=1000
PGID=1000
TZ=Europe/Madrid
DATA_ROOT=/home/<user>/homelab/data
MEALIE_BIND_IP=0.0.0.0
MEALIE_PORT=16003
MEALIE_BASE_URL=http://pi-homelab.<tailnet>.ts.net:16003
MEALIE_ALLOW_SIGNUP=true
MEALIE_DEFAULT_EMAIL=admin@homelab.lan
MEALIE_DEFAULT_GROUP=Home
MEALIE_DEFAULT_HOUSEHOLD=Family
MEALIE_MAX_LOGIN_ATTEMPTS=5
MEALIE_LOCKOUT_HOURS=24
MEALIE_LOG_LEVEL=info
```

Notas sobre este Compose:

- `Mealie` escucha internamente en `9000/tcp`, pero en este homelab se publica en `16003/tcp`
- `SQLite` es una buena opción aquí porque todo el estado vive en almacenamiento local del host, no en un NAS remoto
- `mem_limit: 1g` ayuda a contener el uso de memoria en una Raspberry Pi 5 sin complicar el despliegue
- `MEALIE_DEFAULT_EMAIL` conviene dejarlo definido desde el primer arranque para no depender de valores implícitos durante el bootstrap inicial
- `MEALIE_ALLOW_SIGNUP=true` solo es recomendable para el **bootstrap inicial**; después conviene dejarlo en `false`
- se excluye de WUD porque el propio proyecto recomienda usar una **versión fijada** y actualizar deliberadamente
- antes de una instalación nueva conviene comprobar si existe una versión más reciente de `v3.22.0` y sustituirla conscientemente en el Compose

## Configuración

### 1. Preparar directorios del stack

```bash
mkdir -p /home/<user>/homelab/compose/productivity-mealie
mkdir -p /home/<user>/homelab/data/mealie
chmod 750 /home/<user>/homelab/data/mealie
```

Guarda en el primer directorio el `docker-compose.yml` y el `.env` del apartado anterior.

Como `.env` define la URL base y parámetros operativos, conviene limitar permisos:

```bash
chmod 600 /home/<user>/homelab/compose/productivity-mealie/.env
```

Si no conoces tu UID y GID reales:

```bash
id -u
id -g
```

Úsalos en `PUID` y `PGID` para evitar problemas de permisos sobre `/app/data`.

### 2. Desplegar el stack

```bash
cd /home/<user>/homelab/compose/productivity-mealie
docker compose config
docker compose up -d
docker compose ps
docker compose logs --tail=100 mealie
```

Validaciones rápidas:

```bash
curl -I http://127.0.0.1:16003/
ls -lah /home/<user>/homelab/data/mealie
```

Si todo ha arrancado bien, la UI quedará accesible en una de estas URLs:

- `http://<ip-lan-de-la-pi>:16003`
- `http://pi-homelab.<tailnet>.ts.net:16003`

Para la operación diaria, usa preferentemente la misma URL que hayas fijado en `MEALIE_BASE_URL`.

### 3. Bootstrap inicial y cierre del registro abierto

Con `MEALIE_ALLOW_SIGNUP=true` puedes crear la primera cuenta directamente desde la UI.

Flujo recomendado:

1. Abre Mealie en el navegador.
2. Crea la primera cuenta administrativa del hogar.
3. Inicia sesión y verifica que la aplicación responde con normalidad.
4. Edita `.env` y cambia `MEALIE_ALLOW_SIGNUP=false`.
5. Recrea el contenedor para cerrar el registro abierto.

Aplicar el cierre del registro:

```bash
cd /home/<user>/homelab/compose/productivity-mealie
sed -i 's/^MEALIE_ALLOW_SIGNUP=true$/MEALIE_ALLOW_SIGNUP=false/' .env
docker compose up -d
```

Para un homelab doméstico es preferible mantener el alta abierta solo el tiempo imprescindible.

### 4. Ajustes iniciales en la UI

Después del primer login, revisa como mínimo:

- idioma, zona horaria y formato de unidades
- nombre del hogar y del grupo por defecto si `Home` y `Family` no encajan con tu organización real
- privacidad de grupo, hogar y recetas públicas
- usuarios adicionales si quieres compartir la instancia con más personas de casa

Recomendación operativa para este proyecto:

- mantener **grupo y hogar privados**
- no publicar recetas como públicas salvo necesidad concreta
- reservar cuentas administrativas para muy pocos usuarios

### 5. Importación de recetas

Mealie permite importar recetas de varias formas útiles para este homelab:

- **importación individual por URL** desde la propia interfaz, pegando el enlace de la receta
- **bookmarklet** del navegador para enviar la página actual a Mealie
- **importación masiva** desde una lista de URLs usando la API

Ten en cuenta que estos flujos dependen de que el contenedor pueda resolver DNS y salir por HTTP/HTTPS hacia internet para descargar el contenido original de las recetas.

Flujo práctico recomendado:

1. Empieza probando la importación de una receta concreta desde la UI.
2. Si el resultado te convence, crea un bookmarklet para guardar recetas mientras navegas.
3. Usa importación masiva solo cuando migres un lote grande desde otro sistema o una lista ya preparada.

Para el bookmarklet oficial de la comunidad solo necesitas adaptar dos valores:

- la URL base de tu instancia, por ejemplo `http://pi-homelab.<tailnet>.ts.net:16003`
- el `group slug` de tu grupo principal

Sustituye siempre `<tailnet>` por tu dominio MagicDNS real antes de guardar el bookmarklet.

El bookmarklet abrirá una URL con este patrón:

```text
http://pi-homelab.<tailnet>.ts.net:16003/g/<group-slug>/r/create/url?recipe_import_url=<url-actual>
```

Si vas a migrar muchas recetas de golpe, sigue la guía oficial de **Bulk URL Import** y usa una lista con **una URL por línea**.

### 6. Operación básica y comprobaciones

Comandos útiles de mantenimiento:

```bash
cd /home/<user>/homelab/compose/productivity-mealie
docker compose logs --tail=100 mealie
docker compose exec mealie ls -lah /app/data
docker inspect mealie --format '{{json .HostConfig.Memory}}'
```

Señales de que el servicio está sano:

- la UI carga sin errores en `:16003`
- puedes iniciar sesión y crear o importar una receta
- aparecen datos persistentes dentro de `/home/<user>/homelab/data/mealie/`
- al reiniciar el contenedor siguen presentes usuarios, recetas e imágenes

## Almacenamiento

Rutas persistentes de este servicio:

- `/home/<user>/homelab/data/mealie/` en el **SSD NVMe**

Qué vive dentro de esa ruta:

- la base de datos **SQLite**
- imágenes, activos y ficheros subidos por la aplicación
- backups generados desde la interfaz de administración
- otros datos internos necesarios para usuarios, recetas, listas y planificación

Política recomendada:

- toda la persistencia de Mealie debe quedarse en el **SSD NVMe**
- no guardes sus datos activos en `hd2t` ni `hd5t`
- si en el futuro movieras la base de datos a almacenamiento remoto tipo NAS, deja de usar SQLite y migra a PostgreSQL

## Backup

Qué respaldar como mínimo:

- todo `/home/<user>/homelab/data/mealie/`

Estrategia recomendada en este homelab:

- usar como base el backup de filesystem del directorio completo
- complementar con los backups integrados de la UI para exportaciones puntuales
- evitar copiar la base SQLite en caliente como único método de protección
- no tratar los backups generados dentro de `/app/data` como copia independiente hasta haberlos copiado también fuera del **SSD NVMe**

Para la implementación recurrente de estas copias, usa como referencia [02-borgmatic.md](../07-backups/02-borgmatic.md) junto con [03-backup-docker-volumes.md](../07-backups/03-backup-docker-volumes.md).

Procedimiento manual consistente para copia de filesystem:

```bash
cd /home/<user>/homelab/compose/productivity-mealie
docker compose stop mealie
rsync -a /home/<user>/homelab/data/mealie/ /media/hd2t/backups/exports/volumes/mealie/
docker compose start mealie
```

Backup lógico desde la interfaz:

1. Entra en `Settings > Admin Settings > Backups`.
2. Crea un backup nuevo.
3. Descárgalo o deja el fichero almacenado dentro de `/app/data`.

Buenas prácticas de restore:

- usa preferentemente una copia completa del directorio si quieres restaurar toda la instancia SQLite
- si restauras desde la UI, asume que la operación es **destructiva**
- procura restaurar backups creados con una versión compatible de Mealie

## Referencias

- [Mealie - SQLite Installation](https://docs.mealie.io/documentation/getting-started/installation/sqlite/)
- [Mealie - Backend Configuration](https://docs.mealie.io/documentation/getting-started/installation/backend-config/)
- [Mealie - Permissions and Public Access](https://docs.mealie.io/documentation/getting-started/usage/permissions-and-public-access/)
- [Mealie - Backups and Restoring](https://docs.mealie.io/documentation/getting-started/usage/backups-and-restoring/)
- [Mealie - Bulk URL Import](https://docs.mealie.io/documentation/community-guide/bulk-url-import/)
- [Mealie - Import Bookmarklet](https://docs.mealie.io/documentation/community-guide/import-recipe-bookmarklet/)
- [GitHub Container Registry - ghcr.io/mealie-recipes/mealie](https://github.com/mealie-recipes/mealie/pkgs/container/mealie)
