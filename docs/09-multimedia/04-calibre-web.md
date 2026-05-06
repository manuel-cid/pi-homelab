# Calibre-Web

## Descripción
**Calibre-Web** será la interfaz web de la biblioteca de ebooks del homelab, pensada para explorar, buscar, descargar y leer libros almacenados en `hd2t` a partir de una biblioteca de **Calibre** ya existente o mantenida externamente.

En esta arquitectura se despliega sobre la **Raspberry Pi 5** con estas reglas:

- el servicio y su estado persistente viven en el **SSD NVMe**
- la biblioteca de ebooks vive en **`/mnt/hd2t/calibre/library`**
- el acceso web local se publica detrás de **Caddy** con `https://calibre-web.lan`
- el acceso remoto sigue siendo **solo Tailscale**, sin abrir puertos en el router
- la biblioteca se trata como origen documental de largo plazo y conviene mantenerla separada de la configuración del servicio

Calibre-Web encaja bien en este homelab porque funciona correctamente en contenedor, no necesita una base de datos externa y permite reutilizar directamente la biblioteca de **Calibre** mediante su fichero `metadata.db`, manteniendo en el NVMe solo la configuración, la base de usuarios y el estado operativo del servicio.

## Requisitos Previos
- Haber completado `docs/02-docker/01-instalacion-docker.md`.
- Haber completado `docs/02-docker/02-estructura-compose.md`.
- Haber completado `docs/01-sistema/04-estructura-directorios.md`.
- Haber completado `docs/03-red/04-caddy.md` para publicar `calibre-web.lan`.
- Haber completado `docs/03-red/05-tailscale.md` si quieres acceso remoto por VPN mesh.
- Tener creada la red Docker externa `homelab_proxy`.
- Tener resuelto en Pi-hole o en tu DNS local el FQDN `calibre-web.lan` apuntando a la IP LAN principal de la Raspberry Pi.
- Tener montado `hd2t` en `/mnt/hd2t`.
- Disponer de una biblioteca de **Calibre** válida en `hd2t`, con su fichero `metadata.db`.
- Tener espacio suficiente en el SSD NVMe para:
  - configuración persistente del servicio
  - base de datos interna de usuarios y preferencias
  - caché, miniaturas y estado operativo
- Poder usar `sudo` con el usuario administrador del homelab.
- Puertos implicados en esta fase:
  - `8083/tcp` solo dentro de Docker entre Caddy y el contenedor `calibre-web`
  - `80/tcp` y `443/tcp` ya publicados por Caddy en el host
  - no se abre ningún puerto entrante en el router

## Docker Compose
Directorio recomendado:

```text
/home/<usuario>/homelab/compose/calibre-web/
├── compose.yaml
└── .env
```

Preparación inicial de rutas:

```bash
mkdir -p /home/<usuario>/homelab/compose/calibre-web
mkdir -p /home/<usuario>/homelab/data/calibre-web/config
mkdir -p /mnt/hd2t/calibre/library
```

Fichero `.env`:

```dotenv
TZ=Europe/Madrid

CALIBRE_WEB_IMAGE=lscr.io/linuxserver/calibre-web:latest

PUID=1000
PGID=1000

CALIBRE_WEB_CONFIG_DIR=/home/<usuario>/homelab/data/calibre-web/config
CALIBRE_LIBRARY_DIR=/mnt/hd2t/calibre/library
```

Notas sobre estas variables:

- `PUID` y `PGID` deben corresponder al usuario real que administra el homelab y tiene acceso a la biblioteca montada en `hd2t`.
- `latest` sigue la última release estable publicada para la imagen. Si quieres máxima reproducibilidad, fija una etiqueta concreta.
- `CALIBRE_WEB_CONFIG_DIR` se guarda en el NVMe porque contiene configuración persistente, usuarios y estado del servicio.

Fichero `compose.yaml`:

```yaml
name: calibre-web

services:
  calibre-web:
    container_name: calibre-web
    image: ${CALIBRE_WEB_IMAGE}
    user: "${PUID}:${PGID}"
    restart: unless-stopped
    env_file:
      - .env
    environment:
      TZ: ${TZ}
    volumes:
      - ${CALIBRE_WEB_CONFIG_DIR}:/config
      - type: bind
        source: ${CALIBRE_LIBRARY_DIR}
        target: /books
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

- no se publica `8083` en el host porque el punto de entrada recomendado es **Caddy**
- la biblioteca se monta en solo lectura para proteger la colección principal y su `metadata.db`
- `/config` vive en el NVMe para mantener rápida la parte sensible a escritura y simplificar backups
- en **Raspberry Pi 5 / ARM64** no conviene documentar el `docker mod` opcional de conversión de LinuxServer porque esa capa está pensada para `x86-64`
- si más adelante despliegas este mismo servicio en `x86-64`, puedes evaluar añadir el mod de Calibre para conversiones bajo demanda

Despliegue inicial:

```bash
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/compose/calibre-web
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/data/calibre-web
sudo chown -R <usuario>:<usuario> /mnt/hd2t/calibre

cd /home/<usuario>/homelab/compose/calibre-web
docker compose config
docker compose pull
docker compose up -d
docker compose ps
docker compose logs -f calibre-web
```

Resultado esperado:

- el contenedor `calibre-web` queda levantado
- Calibre-Web escucha internamente en `http://calibre-web:8083`
- se crea la estructura persistente en `/home/<usuario>/homelab/data/calibre-web/`
- la biblioteca de `hd2t` queda visible desde el contenedor en `/books`
- Caddy puede publicar el servicio como `https://calibre-web.lan`

## Configuración

### Objetivo de esta fase

| Elemento | Estado esperado |
|---|---|
| UI local | `https://calibre-web.lan` |
| Persistencia | `/home/<usuario>/homelab/data/calibre-web/` |
| Biblioteca de ebooks | `/mnt/hd2t/calibre/library/` |
| Punto de entrada LAN | Caddy |
| Acceso remoto | Tailscale |
| Origen de metadatos | biblioteca Calibre existente |
| Base de datos de aplicación | integrada en el servicio |

### 1. Preparar rutas y permisos

Crear la estructura base:

```bash
mkdir -p /home/<usuario>/homelab/compose/calibre-web
mkdir -p /home/<usuario>/homelab/data/calibre-web/config
mkdir -p /mnt/hd2t/calibre/library
```

Permisos recomendados:

```bash
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/compose/calibre-web
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/data/calibre-web
sudo chown -R <usuario>:<usuario> /mnt/hd2t/calibre

chmod 755 /home/<usuario>/homelab/data/calibre-web
chmod 750 /home/<usuario>/homelab/data/calibre-web/config
chmod 755 /mnt/hd2t/calibre
chmod 755 /mnt/hd2t/calibre/library
```

La clave para que Calibre-Web funcione bien es que el contenedor pueda **leer** toda la biblioteca y, en particular, el fichero `metadata.db`. Si `hd2t` viene de otro sistema o se monta con un propietario distinto, corrige antes permisos y ACL.

### 2. Arrancar el servicio y completar el asistente inicial

Levantar el stack:

```bash
cd /home/<usuario>/homelab/compose/calibre-web
docker compose up -d
```

Comprobaciones útiles:

```bash
docker compose ps
docker compose logs -f calibre-web
docker exec calibre-web id
docker exec calibre-web ls -lah /books
docker exec calibre-web ls -lah /books/metadata.db
docker exec calibre-web ls -lah /config
```

Después, abrir:

```text
https://calibre-web.lan
```

En el primer arranque:

1. Iniciar sesión con las credenciales iniciales `admin` / `admin123` si todavía no se han cambiado.
2. Ir a la pantalla de configuración inicial.
3. Indicar como ruta de la biblioteca: `/books`.
4. Confirmar que Calibre-Web detecta el fichero `metadata.db`.
5. Cambiar inmediatamente la contraseña del usuario administrador.

### 3. Importación de una biblioteca de Calibre existente

Calibre-Web **no sustituye** a Calibre como herramienta principal de organización avanzada. En este homelab, el patrón recomendado es:

- mantener la biblioteca maestra en `hd2t`
- usar **Calibre** desde un equipo de escritorio cuando necesites reorganizar metadatos masivamente, convertir libros o editar la biblioteca
- usar **Calibre-Web** como interfaz web para consulta, descarga y lectura

Ruta esperada en el host:

```text
/mnt/hd2t/calibre/library/
```

Estructura típica:

```text
/mnt/hd2t/calibre/library/
├── metadata.db
├── Autor 1/
│   └── Titulo del libro (123)/
│       ├── metadata.opf
│       ├── cover.jpg
│       ├── Titulo del libro - Autor 1.epub
│       └── Titulo del libro - Autor 1.azw3
└── Autor 2/
```

Si ya tienes una biblioteca creada con Calibre:

1. Copia o mueve la carpeta completa a `/mnt/hd2t/calibre/library/`.
2. Verifica desde el host que existe `/mnt/hd2t/calibre/library/metadata.db`.
3. Arranca Calibre-Web y apunta la biblioteca a `/books`.
4. Espera a que termine el primer escaneo y valida autores, series, idiomas y formatos.

Si todavía no tienes una biblioteca de Calibre:

1. Crea la biblioteca primero con Calibre en un equipo de escritorio.
2. Cierra Calibre antes de copiar la biblioteca a `hd2t`.
3. Copia toda la estructura, no solo los `.epub`.
4. Luego configura Calibre-Web apuntando a `/books`.

Buenas prácticas para evitar corrupción o inconsistencias:

- no abras simultáneamente la misma biblioteca con **Calibre** y **Calibre-Web** en modo escritura
- si la biblioteca maestra se gestiona con Calibre Desktop, deja el montaje en `read_only` como en este documento
- realiza importaciones o reorganizaciones grandes desde Calibre con el servicio parado o, como mínimo, sin uso concurrente desde la UI web
- verifica siempre que `metadata.db` y las carpetas de autores/libros se han copiado juntos

### 4. Ajustes recomendados en la UI

Nada más terminar el asistente, revisa:

1. **Admin > Basic Configuration** para confirmar la ruta `/books`, el idioma y el comportamiento general del servidor.
2. **Admin > Edit Basic Configuration > Feature Configuration** para decidir si permites subida de libros, envío por correo o lectura en navegador.
3. **Admin > Users** para crear cuentas separadas si habrá más de un usuario.
4. **Admin > UI Configuration** para ajustar columnas, portada, ordenaciones y experiencia de catálogo.
5. **Admin > External Binaries** para revisar al menos `unrar` en `/usr/bin/unrar` y, solo si migras a `x86-64`, los binarios adicionales de Calibre para conversión.

Buenas prácticas específicas para este homelab:

- mantén la biblioteca principal en solo lectura salvo que tengas una razón clara para permitir escrituras desde la web
- si montas `/books` como `read_only`, desactiva subida, edición y borrado desde la UI para que la política del servicio y la experiencia de usuario no entren en conflicto
- usa Calibre Desktop para operaciones masivas sobre metadatos, series, plugins o conversiones complejas
- valida primero descarga y lectura web antes de habilitar funciones adicionales como email o edición desde navegador
- si la colección es grande, lanza el primer escaneo en un momento de baja actividad

### 5. Integración con Caddy

La integración esperada con `docs/03-red/04-caddy.md` es el bloque:

```caddyfile
calibre-web.lan {
  import common
  tls internal
  reverse_proxy calibre-web:8083 {
    header_up X-Scheme https
  }
}
```

Después de levantar ambos stacks:

```bash
docker network inspect homelab_proxy
docker compose -f /home/<usuario>/homelab/compose/caddy/compose.yaml ps
docker compose -f /home/<usuario>/homelab/compose/calibre-web/compose.yaml ps
```

Validaciones:

- `calibre-web` y `caddy` deben estar en `homelab_proxy`
- `https://calibre-web.lan` debe responder con la pantalla inicial o el login
- el certificado será el de la CA interna de Caddy para la LAN

### 6. Tailscale y acceso remoto

El patrón recomendado para simplicidad operativa es:

- usar `https://calibre-web.lan` dentro de la LAN
- entrar por Tailscale cuando estés fuera de casa
- consumir Calibre-Web bajo la ruta remota que ya hayas estandarizado en Caddy

La subruta razonable para este servicio es:

```text
/calibre-web
```

Por tanto, la integración remota con el bloque de `docs/03-red/04-caddy.md` es:

```caddyfile
handle_path /calibre-web/* {
  reverse_proxy calibre-web:8083 {
    header_up X-Scheme https
    header_up X-Script-Name /calibre-web
  }
}
```

Antes de darlo por válido, prueba:

- login desde navegador en LAN
- descarga de un ebook en LAN
- lectura web de un formato compatible si decides habilitarla
- login y acceso al catálogo desde un dispositivo conectado por Tailscale usando `https://pi.tailnet.ts.net/calibre-web/`

## Almacenamiento

Distribución de datos recomendada:

| Tipo de dato | Ruta |
|---|---|
| Compose del servicio | `/home/<usuario>/homelab/compose/calibre-web/` |
| Configuración y estado del servicio | `/home/<usuario>/homelab/data/calibre-web/config/` |
| Biblioteca de ebooks | `/mnt/hd2t/calibre/library/` |

Criterios de esta distribución:

- el **NVMe** absorbe la parte sensible a latencia y escritura frecuente
- `hd2t` almacena únicamente la biblioteca de ebooks y sus formatos asociados
- la biblioteca se monta como `read_only` para proteger `metadata.db` y el contenido original
- el servicio queda desacoplado de la colección: puedes restaurar `config/` sin mover toda la biblioteca

Qué guarda Calibre-Web en `/config` habitualmente:

- base de datos interna de la aplicación
- usuarios y credenciales
- configuración persistente del servicio
- miniaturas, caché y estado operativo
- ficheros auxiliares propios del contenedor

Qué guarda la biblioteca en `/mnt/hd2t/calibre/library/`:

- `metadata.db`
- estructura de autores, series y títulos generada por Calibre
- portadas, `metadata.opf` y formatos como `epub`, `azw3`, `pdf` o `mobi`

## Backup

Respaldar como mínimo:

- `/home/<usuario>/homelab/compose/calibre-web/`
- `/home/<usuario>/homelab/data/calibre-web/config/`

Respaldar de forma opcional según tu estrategia:

- `/mnt/hd2t/calibre/library/` si `hd2t` no es ya la copia maestra de tu biblioteca de ebooks

Recomendación práctica:

- trata `config/` como **obligatorio**
- trata la biblioteca de `hd2t` según la realidad de tus ficheros: si `hd2t` es el único origen, debe entrar también en la estrategia 3-2-1
- si vas a copiar la biblioteca, evita hacerlo mientras otra instancia de Calibre la esté modificando

Antes de un backup importante o una actualización mayor:

```bash
cd /home/<usuario>/homelab/compose/calibre-web
docker compose stop calibre-web
```

Después de copiar `config/`, volver a arrancar:

```bash
docker compose up -d
```

Si además vas a respaldar la biblioteca completa, asegúrate de que **Calibre Desktop** no la está usando en otro equipo para reducir el riesgo de copiar un `metadata.db` inconsistente.

## Referencias
- Documentación oficial de Calibre-Web: `https://github.com/janeczku/calibre-web/wiki`
- Repositorio oficial: `https://github.com/janeczku/calibre-web`
- Imagen Docker de LinuxServer.io: `https://docs.linuxserver.io/images/docker-calibre-web/`
- Reverse proxy de LinuxServer.io: `https://github.com/linuxserver/reverse-proxy-confs`
- Proyecto Calibre: `https://calibre-ebook.com/`
