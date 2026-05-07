# Linkding

## Descripción

**Linkding** es el gestor de marcadores web ligero de este homelab. Encaja bien como servicio personal porque es pequeño, rápido, compatible con **ARM64** y guarda todo su estado en un único directorio persistente sobre el **SSD NVMe**.

En esta Raspberry Pi 5 se despliega como stack Docker propio, con acceso **solo desde la LAN o por Tailscale**, sin abrir puertos en el router y sin depender de servicios externos. La idea operativa es simple:

- la aplicación vive en `/home/<user>/homelab/compose/productivity-linkding/`
- los datos persistentes viven en `/home/<user>/homelab/data/linkding/` sobre el **SSD NVMe**
- el servicio se publica en el puerto `9090/tcp` del host para poder usarlo desde navegador y desde la **extensión oficial**
- se usa la imagen `sissbruecker/linkding:latest`, suficiente para un despliegue estándar sin archivado local de páginas HTML

Para un homelab personal, esta topología suele ser la más práctica: despliegue sencillo, base SQLite local, backup fácil y configuración mínima en clientes.

## Requisitos Previos

- Haber completado [02-estructura-compose.md](/Users/x441425/workspace2/homelab/docs/02-docker/02-estructura-compose.md).
- Haber completado [04-tailscale.md](/Users/x441425/workspace2/homelab/docs/03-red/04-tailscale.md) si quieres acceder también desde fuera de casa a través de la tailnet.
- Revisar [06-puertos-y-firewall.md](/Users/x441425/workspace2/homelab/docs/03-red/06-puertos-y-firewall.md) para documentar el puerto del servicio.
- Revisar [03-backup-docker-volumes.md](/Users/x441425/workspace2/homelab/docs/07-backups/03-backup-docker-volumes.md) si vas a incluir el bind mount de Linkding en el plan de copias.
- Disponer de la raíz operativa del homelab en `/home/<user>/homelab/`.
- Puertos necesarios en esta fase:
  - **`9090/tcp` publicado en el host** para acceso web desde LAN y Tailscale
  - no hace falta exponer ningún puerto a internet ni abrir nada en el router

## Docker Compose

Archivo: `/home/<user>/homelab/compose/productivity-linkding/docker-compose.yml`

```yaml
name: productivity-linkding

services:
  linkding:
    image: sissbruecker/linkding:latest
    restart: unless-stopped
    env_file:
      - .env
    environment:
      TZ: ${TZ}
      LD_SUPERUSER_NAME: ${LINKDING_SUPERUSER_NAME}
      LD_SUPERUSER_PASSWORD: ${LINKDING_SUPERUSER_PASSWORD}
    ports:
      - "${LINKDING_BIND_IP}:${LINKDING_PORT}:9090"
    volumes:
      - ${DATA_ROOT}/linkding:/etc/linkding/data
    labels:
      - com.centurylinklabs.watchtower.enable=true
```

Archivo recomendado: `/home/<user>/homelab/compose/productivity-linkding/.env`

```dotenv
TZ=Europe/Madrid
DATA_ROOT=/home/<user>/homelab/data
LINKDING_BIND_IP=0.0.0.0
LINKDING_PORT=9090
LINKDING_SUPERUSER_NAME=admin
LINKDING_SUPERUSER_PASSWORD=cambiar-esta-clave
```

Notas sobre este Compose:

- Linkding usa **SQLite por defecto**, así que no necesita una base de datos externa para este caso
- el bind mount a `/etc/linkding/data` deja toda la persistencia en el **SSD NVMe**
- `LINKDING_BIND_IP=0.0.0.0` permite acceder al servicio desde la LAN y desde Tailscale
- si prefieres publicarlo solo detrás de un reverse proxy local, cambia `LINKDING_BIND_IP=127.0.0.1`
- `LD_SUPERUSER_NAME` y `LD_SUPERUSER_PASSWORD` permiten crear el primer usuario automáticamente al arrancar
- la etiqueta de Watchtower puede mantenerse activa porque es un servicio pequeño y fácil de recuperar

## Configuración

### 1. Preparar directorios del stack

```bash
mkdir -p /home/<user>/homelab/compose/productivity-linkding
mkdir -p /home/<user>/homelab/data/linkding
chmod 700 /home/<user>/homelab/data/linkding
```

Guarda en el primer directorio el `docker-compose.yml` y el `.env` del apartado anterior.

Como `.env` contiene credenciales iniciales, conviene restringir permisos:

```bash
chmod 600 /home/<user>/homelab/compose/productivity-linkding/.env
```

### 2. Desplegar el stack

```bash
cd /home/<user>/homelab/compose/productivity-linkding
docker compose config
docker compose up -d
docker compose ps
docker compose logs --tail=50 linkding
```

Validaciones rápidas:

```bash
curl -I http://127.0.0.1:9090/
ls -lah /home/<user>/homelab/data/linkding
```

Si el arranque ha ido bien, podrás abrir Linkding en una de estas URLs:

- `http://<ip-lan-de-la-pi>:9090`
- `http://pi-homelab.<tailnet>.ts.net:9090`

### 3. Verificar el usuario inicial

Con las variables `LD_SUPERUSER_*` definidas, el contenedor creará automáticamente el usuario administrador en el primer arranque si todavía no existe.

Flujo recomendado:

1. Abre la UI en el navegador.
2. Inicia sesión con `LINKDING_SUPERUSER_NAME` y `LINKDING_SUPERUSER_PASSWORD`.
3. Cambia la contraseña desde la propia aplicación si has usado una clave temporal.
4. Cuando confirmes que el usuario ya existe, puedes eliminar `LINKDING_SUPERUSER_PASSWORD` del `.env` y recrear el contenedor.

Recrear el stack después de editar `.env`:

```bash
cd /home/<user>/homelab/compose/productivity-linkding
docker compose up -d
```

Si prefieres no usar creación automática, también puedes crear el superusuario manualmente:

```bash
cd /home/<user>/homelab/compose/productivity-linkding
docker compose exec linkding \
  python manage.py createsuperuser --username=admin --email=tu-correo@example.com
```

### 4. Ajustes iniciales en la UI

Tras el primer login, revisa como mínimo:

- tu zona horaria y preferencias personales
- la importación de marcadores si vienes de otro navegador o servicio
- el comportamiento de tags y notas para unificar criterio desde el principio
- si quieres permitir archivado o no; con la imagen `latest` no se usa archivado HTML local avanzado

Para un uso personal suele ser suficiente mantener una sola cuenta administrativa.

### 5. Configurar la extensión del navegador

La extensión oficial de Linkding permite dos flujos especialmente útiles:

- guardar rápidamente la pestaña actual
- buscar marcadores desde la barra de direcciones del navegador

Recomendación operativa:

1. Instala la extensión oficial en Firefox o Chrome/Chromium.
2. Abre la configuración de la extensión.
3. Define como servidor **la misma URL canónica** que uses normalmente en ese dispositivo.
4. Autentícate contra tu instancia de Linkding.
5. Haz una prueba guardando una página y otra buscándola desde la barra del navegador.

Ejemplos de URL razonables:

- `http://pi-homelab.<tailnet>.ts.net:9090` si el equipo cliente usa Tailscale
- `http://<ip-lan-de-la-pi>:9090` si el equipo solo accede por red local

Conviene no mezclar muchas URLs distintas para la misma instancia. Elige una como referencia y úsala también en la extensión.

### 6. Operación básica y comprobaciones

Comandos útiles de mantenimiento:

```bash
cd /home/<user>/homelab/compose/productivity-linkding
docker compose logs --tail=100 linkding
docker compose exec linkding python manage.py check
docker compose exec linkding python manage.py shell -c "from django.contrib.auth import get_user_model; print(get_user_model().objects.count())"
```

Señales de que el servicio está sano:

- la UI carga sin errores al abrir `:9090`
- puedes iniciar sesión y crear un marcador
- la extensión del navegador añade enlaces correctamente
- aparecen ficheros como `db.sqlite3` en el directorio persistente

## Almacenamiento

Rutas persistentes de este servicio:

- `/home/<user>/homelab/data/linkding/` en el **SSD NVMe**

Contenido habitual dentro de esa ruta:

- `db.sqlite3` como base de datos principal
- `assets/` para instantáneas HTML si más adelante usas funciones de archivado
- `favicons/` para iconos descargados
- `previews/` para imágenes de previsualización
- ficheros auxiliares de backup generados temporalmente por la propia aplicación

Política recomendada:

- todo el estado del servicio vive en el **SSD NVMe**
- no guardes datos de Linkding en `hd2t` ni en `hd5t`
- no uses named volumes aquí; el bind mount documentado es más simple de inspeccionar y respaldar

## Backup

Qué respaldar como mínimo:

- todo `/home/<user>/homelab/data/linkding/`
- en particular `db.sqlite3`, `assets/`, `favicons/` y `previews/`

Estrategia recomendada en este homelab:

- incluir el directorio completo en el backup de filesystem
- generar además un backup lógico periódico con la utilidad propia de Linkding
- evitar confiar solo en copiar `db.sqlite3` en caliente como método principal

Ejemplo de backup lógico completo:

```bash
cd /home/<user>/homelab/compose/productivity-linkding
docker compose exec linkding \
  python manage.py full_backup /etc/linkding/data/backup-$(date +%F).zip
ls -lh /home/<user>/homelab/data/linkding/backup-$(date +%F).zip
```

Después puedes mover ese ZIP a tu ubicación de copias, por ejemplo:

```bash
mkdir -p /mnt/hd2t/backups/exports/volumes/linkding
cp /home/<user>/homelab/data/linkding/backup-$(date +%F).zip \
  /mnt/hd2t/backups/exports/volumes/linkding/
```

Antes de una copia manual consistente o de una restauración:

```bash
cd /home/<user>/homelab/compose/productivity-linkding
docker compose stop linkding
rsync -a /home/<user>/homelab/data/linkding/ /ruta/de/backup/linkding/
docker compose start linkding
```

Buenas prácticas de restore:

- restaura siempre el directorio completo si quieres recuperar también iconos, previews y snapshots
- si usas el ZIP generado por `full_backup`, descomprímelo en el directorio de datos de la nueva instalación
- prueba el restore en una copia temporal antes de dar la estrategia por válida

## Referencias

- [Linkding - Sitio oficial](https://linkding.link/)
- [Linkding - Installation](https://linkding.link/installation/)
- [Linkding - Options](https://linkding.link/options/)
- [Linkding - Backups](https://linkding.link/backups/)
- [Linkding - Browser Extension](https://linkding.link/browser-extension/)
- [Linkding - Repositorio oficial](https://github.com/sissbruecker/linkding)
- [Extensión oficial de Linkding](https://github.com/sissbruecker/linkding-extension)
- [Imagen Docker `sissbruecker/linkding`](https://hub.docker.com/r/sissbruecker/linkding)
- [02-estructura-compose.md](/Users/x441425/workspace2/homelab/docs/02-docker/02-estructura-compose.md)
- [03-backup-docker-volumes.md](/Users/x441425/workspace2/homelab/docs/07-backups/03-backup-docker-volumes.md)
