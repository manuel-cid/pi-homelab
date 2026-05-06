# Linkding

## Descripción
**Linkding** será el gestor de marcadores del homelab para guardar enlaces técnicos, documentación útil, dashboards, recursos de aprendizaje y lecturas pendientes en una instancia privada y ligera.

En esta arquitectura se despliega con estas reglas:

- la aplicación y todos sus datos persistentes viven en el **SSD NVMe**
- el acceso web local se publica detrás de **Caddy** con `https://linkding.lan`
- la conexión va siempre por **HTTPS** con la **CA interna de Caddy**
- el acceso remoto sigue siendo **solo LAN + Tailscale**, sin abrir puertos en el router
- la persistencia usa la base de datos **SQLite** integrada, suficiente para un uso personal o familiar pequeño
- la captura rápida de enlaces se hace desde la **extensión oficial del navegador**

Linkding encaja bien en este homelab porque resuelve una necesidad cotidiana con un stack mínimo, mantiene todo el estado en un único directorio fácil de respaldar y permite añadir enlaces desde navegador sin depender de servicios externos.

## Requisitos Previos
- Haber completado `docs/02-docker/01-instalacion-docker.md`.
- Haber completado `docs/02-docker/02-estructura-compose.md`.
- Haber completado `docs/01-sistema/04-estructura-directorios.md`.
- Haber completado `docs/03-red/04-caddy.md`.
- Haber completado `docs/03-red/05-tailscale.md` si quieres usar Linkding también desde fuera de la LAN mediante VPN.
- Haber completado `docs/07-backups/01-estrategia-backup.md`.
- Haber completado `docs/07-backups/03-backup-docker-volumes.md`.
- Tener creada la red Docker externa `homelab_proxy`.
- Tener resuelto en Pi-hole o en tu DNS local el FQDN `linkding.lan` apuntando a la IP LAN principal de la Raspberry Pi.
- Tener importada en los navegadores y dispositivos cliente la CA local de Caddy desde:
  - `/home/<usuario>/homelab/compose/caddy/data/caddy/pki/authorities/local/root.crt`
- Poder usar `sudo` con el usuario administrador del homelab.
- Puertos implicados en esta fase:
  - `9090/tcp` solo dentro de Docker entre Caddy y el contenedor `linkding`
  - `443/tcp` ya publicado por Caddy en el host
  - no se abre ningún puerto entrante en el router

## Docker Compose
Directorio recomendado:

```text
/home/<usuario>/homelab/compose/linkding/
├── compose.yaml
└── .env
```

Preparación inicial:

```bash
mkdir -p /home/<usuario>/homelab/compose/linkding
mkdir -p /home/<usuario>/homelab/data/linkding
```

Fichero `.env`:

```dotenv
TZ=Europe/Madrid

LD_CONTAINER_NAME=linkding
LINKDING_IMAGE=sissbruecker/linkding:latest

LD_CSRF_TRUSTED_ORIGINS=https://linkding.lan
LD_LOG_X_FORWARDED_FOR=true

LINKDING_DATA_DIR=/home/<usuario>/homelab/data/linkding
```

Notas sobre estas variables:

- `LINKDING_IMAGE` usa la variante estándar, suficiente para gestionar marcadores sin añadir el sobrecoste de las imágenes `plus`.
- `LD_CSRF_TRUSTED_ORIGINS` deja explícita la URL publicada por Caddy para evitar problemas de `403 CSRF verification failed` si cambias o endureces la capa de proxy.
- `LD_LOG_X_FORWARDED_FOR=true` conserva la IP real del cliente en logs cuando Linkding está detrás de Caddy.
- `LINKDING_DATA_DIR` vive en el NVMe porque ahí estarán la base SQLite, favicons, previsualizaciones y cualquier snapshot HTML futuro.
- En este despliegue no se usa `LD_SUPERUSER_PASSWORD` en el `.env`; el usuario inicial se crea manualmente tras el arranque para no dejar una contraseña en claro dentro del stack.

Fichero `compose.yaml`:

```yaml
name: linkding

services:
  linkding:
    container_name: ${LD_CONTAINER_NAME}
    image: ${LINKDING_IMAGE}
    restart: unless-stopped
    env_file:
      - .env
    volumes:
      - ${LINKDING_DATA_DIR}:/etc/linkding/data
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

- no se publica ningún puerto en el host porque el acceso recomendado es solo a través de **Caddy**
- Linkding escucha internamente en el puerto `9090`
- toda la persistencia queda concentrada en `/etc/linkding/data`
- la base de datos por defecto es **SQLite**, adecuada para este caso de uso y fácil de respaldar
- el contenedor se puede recrear sin perder estado mientras el bind mount del NVMe se conserve

Despliegue inicial:

```bash
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/compose/linkding
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/data/linkding

cd /home/<usuario>/homelab/compose/linkding
docker compose config
docker compose pull
docker compose up -d
docker compose ps
docker compose logs -f linkding
```

Resultado esperado:

- el contenedor `linkding` queda levantado
- Linkding escucha internamente en `http://linkding:9090`
- se crea la estructura persistente en `/home/<usuario>/homelab/data/linkding/`
- Caddy puede publicar el servicio como `https://linkding.lan`

## Configuración

### Objetivo de esta fase

| Elemento | Estado esperado |
|---|---|
| UI local | `https://linkding.lan` |
| Persistencia | `/home/<usuario>/homelab/data/linkding/` |
| Base de datos | SQLite en el NVMe |
| Punto de entrada | Caddy |
| TLS | `tls internal` con CA local de Caddy |
| Cliente principal | extensión oficial del navegador |
| Alta inicial | superusuario creado manualmente |

### 1. Preparar rutas y permisos

Crear la estructura base:

```bash
mkdir -p /home/<usuario>/homelab/compose/linkding
mkdir -p /home/<usuario>/homelab/data/linkding
```

Permisos recomendados:

```bash
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/compose/linkding
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/data/linkding

chmod 755 /home/<usuario>/homelab/data/linkding
```

Toda la información operativa de Linkding debe quedarse en el **SSD NVMe**. `hd2t` se reserva para backups y `hd5t` no interviene en este servicio.

### 2. Publicar Linkding en Caddy con HTTPS interno

Añade este bloque al `Caddyfile` del stack de Caddy:

```caddyfile
linkding.lan {
  import common
  tls internal
  reverse_proxy linkding:9090
}
```

Después valida y recarga Caddy:

```bash
cd /home/<usuario>/homelab/compose/caddy
docker compose exec caddy caddy validate --config /etc/caddy/Caddyfile
docker compose up -d
docker compose logs --tail=100 caddy
```

Notas prácticas:

- usa un hostname dedicado en la raíz y no un subpath
- si en tu homelab ya has estandarizado `*.homelab.lan`, sustituye `linkding.lan` por `linkding.homelab.lan` en **DNS**, `.env` y `Caddyfile`
- aunque Caddy normalmente preserva la cabecera `Host`, mantener `LD_CSRF_TRUSTED_ORIGINS` alineado con la URL publicada simplifica el troubleshooting

### 3. Importar la CA local de Caddy en los clientes

Ruta del certificado raíz en el host:

```text
/home/<usuario>/homelab/compose/caddy/data/caddy/pki/authorities/local/root.crt
```

Importa ese certificado en:

- tu navegador principal
- cualquier otro navegador donde vayas a instalar la extensión de Linkding
- cualquier portátil o equipo adicional desde Tailscale que deba confiar en `https://linkding.lan`

Sin esa CA instalada el acceso seguirá cifrado, pero el navegador y la extensión no confiarán en el certificado y la experiencia será inestable o directamente fallará.

### 4. Primer arranque y creación del usuario administrador

Abrir después:

```text
https://linkding.lan
```

Crear el superusuario inicial:

```bash
cd /home/<usuario>/homelab/compose/linkding
docker compose exec linkding python manage.py createsuperuser --username=<usuario> --email=<correo>
```

El comando pedirá la contraseña de forma interactiva. Después:

1. Abrir `https://linkding.lan`.
2. Iniciar sesión con el usuario recién creado.
3. Crear un marcador de prueba.
4. Comprobar que aparecen ficheros nuevos en `/home/<usuario>/homelab/data/linkding/`.

Se usa este método en lugar de `LD_SUPERUSER_NAME` y `LD_SUPERUSER_PASSWORD` para no dejar credenciales iniciales en texto claro dentro del `.env`.

### 5. Ajustes recomendados tras el primer login

Revisión práctica inicial:

- confirmar que la URL real es `https://linkding.lan`
- probar el guardado de un enlace normal y otro con varias etiquetas
- comprobar que las miniaturas o favicons se descargan correctamente
- revisar que la búsqueda encuentra el marcador recién creado
- si más adelante integras **Authelia** u otro proveedor OIDC, consulta `docs/04-seguridad/01-authelia.md`

Organización recomendada para un homelab personal:

- usar etiquetas funcionales como `homelab`, `docker`, `red`, `seguridad`, `backup`, `leer-despues`
- reservar notas cortas para contexto operativo o motivos por los que un enlace es importante
- evitar usar Linkding como repositorio documental principal: para documentación larga, seguir usando **BookStack**

### 6. Configurar la extensión oficial del navegador

Instala la extensión oficial en el navegador que uses normalmente:

- Firefox: complemento oficial de Linkding
- Chromium o Chrome: extensión oficial de Linkding

Configuración recomendada:

1. Abrir la extensión.
2. Configurar como servidor `https://linkding.lan`.
3. Autenticarse con la cuenta creada en el paso anterior.
4. Guardar una página desde una pestaña normal.
5. Comprobar desde la interfaz web que el marcador llega con título y URL correctos.

Notas prácticas con la extensión:

- si vas a usarla desde fuera de la LAN mediante **Tailscale**, el dispositivo remoto debe resolver el mismo FQDN y confiar en la misma CA
- prueba primero la URL en el navegador antes de depurar la extensión
- si cambias el FQDN más adelante, actualiza también la configuración del cliente

## Almacenamiento
Volúmenes y rutas persistentes de este servicio:

| Elemento | Ruta en host | Ubicación física |
|---|---|---|
| Datos de Linkding | `/home/<usuario>/homelab/data/linkding/` | SSD NVMe |
| Compose del stack | `/home/<usuario>/homelab/compose/linkding/` | SSD NVMe |
| Backups exportados | `/mnt/hd2t/backups/linkding/` | `hd2t` |

Contenido típico tras el despliegue:

```text
/home/<usuario>/homelab/data/linkding/
├── db.sqlite3
├── assets/
├── favicons/
└── previews/
```

Qué guarda cada zona:

- `db.sqlite3`: base de datos SQLite con usuarios, marcadores, etiquetas y metadatos
- `assets/`: snapshots HTML si en el futuro habilitas funciones de archivado local
- `favicons/`: iconos descargados de los sitios guardados
- `previews/`: imágenes de previsualización asociadas a marcadores

Recomendaciones de almacenamiento:

- no pongas esta ruta en `hd2t` ni en `hd5t`
- no mezcles aquí otros servicios
- mantén el directorio completo dentro de los backups del NVMe
- si más adelante activas archivado o guardas muchos enlaces con previsualización, revisa periódicamente el crecimiento del directorio

## Backup
Qué respaldar en este servicio:

- el directorio `/home/<usuario>/homelab/data/linkding/`
- el directorio `/home/<usuario>/homelab/compose/linkding/`
- preferiblemente una exportación generada con `full_backup`, porque incluye la base SQLite y los datos auxiliares en un único fichero

Preparar el destino local de backup:

```bash
mkdir -p /mnt/hd2t/backups/linkding
```

### Backup manual recomendado con `full_backup`

```bash
mkdir -p /mnt/hd2t/backups/linkding
timestamp="$(date +%F-%H%M%S)"

cd /home/<usuario>/homelab/compose/linkding
docker compose exec -T linkding \
  python manage.py full_backup /etc/linkding/data/backup.zip

sudo cp \
  /home/<usuario>/homelab/data/linkding/backup.zip \
  "/mnt/hd2t/backups/linkding/linkding-full-${timestamp}.zip"

sha256sum "/mnt/hd2t/backups/linkding/linkding-full-${timestamp}.zip" \
  > "/mnt/hd2t/backups/linkding/linkding-full-${timestamp}.zip.sha256"

sudo rm -f /home/<usuario>/homelab/data/linkding/backup.zip
rsync -a /home/<usuario>/homelab/compose/linkding/ /mnt/hd2t/backups/linkding/compose/
```

Este método es el más cómodo para este homelab porque empaqueta en un único ZIP la base SQLite y los directorios `assets/`, `favicons/` y `previews`.

### Exportación adicional de marcadores

Como copia complementaria, conviene exportar periódicamente los marcadores desde la interfaz web en formato Netscape HTML. Esa exportación:

- es portable a otros gestores
- sirve para migraciones o contingencias
- no sustituye el backup completo, porque no conserva toda la configuración interna ni los activos descargados

### Qué no conviene hacer

- copiar `db.sqlite3` en caliente como única estrategia de backup
- confiar solo en la imagen Docker o en el `compose.yaml`
- olvidar el directorio `compose/`, que contiene la configuración exacta del despliegue

### Restore recomendado

Secuencia práctica:

1. Parar el stack de Linkding.
2. Renombrar el directorio actual como salvaguarda.
3. Extraer el ZIP del backup en una ruta temporal.
4. Restaurar el contenido extraído en `/home/<usuario>/homelab/data/linkding/`.
5. Levantar el stack y validar login, búsqueda y marcadores.

Ejemplo:

```bash
cd /home/<usuario>/homelab/compose/linkding
docker compose down

sudo mv \
  /home/<usuario>/homelab/data/linkding \
  "/home/<usuario>/homelab/data/linkding.before-restore-$(date +%F-%H%M%S)"

sudo mkdir -p /home/<usuario>/homelab/data/linkding
sudo mkdir -p /tmp/linkding-restore
sudo unzip /mnt/hd2t/backups/linkding/linkding-full-<timestamp>.zip -d /tmp/linkding-restore

sudo cp -a /tmp/linkding-restore/. /home/<usuario>/homelab/data/linkding/

docker compose up -d
docker compose logs --tail=100 linkding
```

Validación posterior al restore:

- el login funciona con la cuenta existente
- la búsqueda devuelve marcadores antiguos
- las etiquetas siguen presentes
- los favicons y las previsualizaciones se cargan correctamente

## Referencias
- Documentación oficial de Linkding: `https://linkding.link/`
- Instalación de Linkding: `https://linkding.link/installation/`
- Opciones de configuración: `https://linkding.link/options/`
- Backup y restore: `https://linkding.link/backups/`
- Extensión oficial del navegador: `https://linkding.link/browser-extension/`
- Repositorio oficial de Linkding: `https://github.com/sissbruecker/linkding`
- Imagen Docker `sissbruecker/linkding`: `https://hub.docker.com/r/sissbruecker/linkding`
