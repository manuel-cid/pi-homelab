# Instalación de Docker Engine y Docker Compose

## Descripción
Procedimiento para instalar **Docker Engine** y el plugin de **Docker Compose v2** en la **Raspberry Pi 5** con **Raspberry Pi OS Lite 64-bit** ejecutándose desde el **SSD NVMe**.

El objetivo de este documento es dejar el host listo para ejecutar contenedores de forma estable en arquitectura **ARM64**, con arranque automático de Docker, uso administrativo mediante el grupo `docker` y una verificación básica antes de continuar con la organización de stacks, Portainer y Watchtower.

En este homelab se asume una instalación **rootful** de Docker, sencilla de operar y alineada con los documentos posteriores de la fase 2. No se usa Docker Desktop, no se instala el binario legado `docker-compose` y no se trabaja en modo rootless.

## Requisitos Previos
- Haber completado `docs/01-sistema/01-instalacion-os.md`.
- Haber completado `docs/01-sistema/02-configuracion-inicial.md`.
- Haber completado `docs/01-sistema/03-seguridad-base.md`.
- Haber completado `docs/01-sistema/04-estructura-directorios.md`.
- Tener el sistema arrancando desde el **SSD NVMe**, no desde la microSD.
- Tener acceso SSH al host con el usuario administrador y privilegios `sudo`.
- Tener conectividad de red saliente para descargar paquetes desde los repositorios oficiales.
- Confirmar que la arquitectura del sistema es `arm64` o `aarch64`.
- Puertos implicados en esta fase:
  - no es necesario abrir puertos nuevos del host para instalar Docker
  - el socket Unix `/var/run/docker.sock` se usará para administración local
  - los puertos de aplicaciones se publicarán más adelante, servicio por servicio

## Docker Compose
En esta fase no se despliega todavía ningún servicio del homelab, pero sí conviene dejar un `compose.yaml` mínimo para verificar que el plugin `docker compose` funciona correctamente en ARM64.

Guárdalo, por ejemplo, en `/home/<usuario>/homelab/compose/_verify-docker/compose.yaml`:

```yaml
name: verify-docker

services:
  hello:
    image: hello-world:latest
    restart: "no"
```

Este compose no abre puertos ni crea almacenamiento persistente. Su única función es validar que:

- el motor Docker arranca correctamente
- el plugin `docker compose` está disponible
- la Raspberry Pi puede descargar y ejecutar imágenes multi-arquitectura para `arm64`

La ruta `_verify-docker` se usa solo como comprobación inicial. Más adelante, el resto de stacks del homelab seguirán la estructura definitiva documentada en `docs/02-docker/02-estructura-compose.md`.

## Configuración

### Objetivo de esta fase

| Elemento | Estado esperado al terminar este documento |
|---|---|
| Motor de contenedores | Docker Engine instalado |
| Orquestación local | `docker compose` disponible |
| Arquitectura | `arm64` validada |
| Servicio `docker` | habilitado al arranque |
| Servicio `containerd` | habilitado al arranque |
| Administración sin `sudo` | disponible para el usuario del homelab |
| Validación básica | `hello-world` ejecutado correctamente |

### Estrategia recomendada

El flujo recomendado es este:

1. Verificar sistema operativo y arquitectura.
2. Eliminar paquetes conflictivos si existen.
3. Configurar el repositorio oficial de Docker para Debian en ARM64.
4. Instalar Docker Engine, `containerd`, Buildx y Docker Compose plugin.
5. Habilitar los servicios para el arranque automático.
6. Añadir el usuario administrador al grupo `docker`.
7. Verificar instalación, versión y ejecución básica de contenedores.

Decisiones operativas de esta fase:

- Se instala Docker desde el **repositorio oficial de Docker**, no desde los paquetes genéricos de Debian.
- Se usa **Docker Compose v2** como plugin, invocado con `docker compose`, no el binario legado `docker-compose`.
- El almacenamiento de imágenes y capas queda en el disco del sistema, es decir, el **SSD NVMe**, mediante `/var/lib/docker`.
- Los datos persistentes de los servicios del homelab seguirán yendo en rutas bajo `/home/<usuario>/homelab/data` mediante bind mounts, como se documentará en los stacks posteriores.
- No se instala el paquete legado `docker-compose`, porque este proyecto estandariza Compose v2 y la sintaxis `docker compose`.

### 1. Verificar arquitectura y base del sistema

Antes de instalar nada, confirmar que el host está en la arquitectura esperada y arrancando desde el NVMe:

```bash
uname -m
dpkg --print-architecture
findmnt /
cat /etc/os-release
```

Resultado esperado:

- `uname -m` debe devolver normalmente `aarch64`
- `dpkg --print-architecture` debe devolver `arm64`
- `/` debe residir en el **SSD NVMe**
- el sistema debe ser una base Debian compatible, normalmente **Bookworm** en Raspberry Pi OS actual

Si `dpkg --print-architecture` no devuelve `arm64`, no continúes con este documento tal como está escrito.

### 2. Eliminar paquetes conflictivos si existen

Si el sistema trae restos de instalaciones anteriores, conviene retirarlos antes de añadir el repositorio oficial de Docker:

```bash
for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do
  sudo apt remove -y "$pkg"
done
```

No pasa nada si alguno de esos paquetes no estaba instalado.

Actualizar el índice de paquetes antes de seguir:

```bash
sudo apt update
```

### 3. Configurar el repositorio oficial de Docker

Raspberry Pi OS 64-bit es compatible con el procedimiento oficial de instalación de Docker para Debian. Primero instala las dependencias mínimas para gestionar claves y repositorios HTTPS:

```bash
sudo apt install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
```

Crear el repositorio APT oficial usando el formato actual `deb822`:

```bash
sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $(. /etc/os-release && echo "${VERSION_CODENAME}")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
```

Actualizar de nuevo el índice de paquetes:

```bash
sudo apt update
```

Validación útil:

```bash
apt-cache policy docker-ce
```

Debe aparecer una versión candidata procedente de `download.docker.com`.

Notas prácticas para Raspberry Pi OS:

- si por algún motivo `VERSION_CODENAME` no devuelve el codename correcto, usa explícitamente `bookworm`
- evita mezclar paquetes oficiales de Docker con tutoriales antiguos o paquetes de repositorios no oficiales
- para este homelab no hace falta usar el script de conveniencia `get.docker.com`

### 4. Instalar Docker Engine y el plugin de Compose

Instalar el conjunto base recomendado:

```bash
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

Paquetes instalados:

- `docker-ce`: motor principal de Docker
- `docker-ce-cli`: cliente de línea de comandos
- `containerd.io`: runtime subyacente usado por Docker
- `docker-buildx-plugin`: builds modernos y multi-platform
- `docker-compose-plugin`: Compose v2 integrado como `docker compose`

Tras esta instalación, el comando esperado para Compose es:

```bash
docker compose version
```

No debería ser necesario instalar ni usar:

```bash
docker-compose
```

### 5. Habilitar el arranque automático de Docker

Aunque normalmente el servicio queda arrancado tras la instalación, conviene dejar explícito su comportamiento al reiniciar:

```bash
sudo systemctl enable --now docker.service
sudo systemctl enable --now containerd.service
```

Comprobar estado:

```bash
sudo systemctl status docker --no-pager
sudo systemctl status containerd --no-pager
```

Resultado esperado:

- `docker.service` activo
- `containerd.service` activo
- ambos servicios habilitados para el arranque

### 6. Añadir el usuario administrador al grupo `docker`

Por defecto, el socket de Docker pertenece a `root`. Para evitar usar `sudo` en cada comando:

```bash
getent group docker || sudo groupadd docker
sudo usermod -aG docker <usuario>
```

Después debes **cerrar sesión y volver a entrar** para que el cambio de grupo se aplique correctamente.

Opciones prácticas para aplicar el cambio:

- salir y volver a entrar por SSH
- reiniciar la sesión del terminal
- usar `newgrp docker` solo como prueba temporal de la sesión actual

Validar el grupo efectivo tras reconectar:

```bash
id
groups
```

Si ejecutaste antes comandos Docker con `sudo`, puede que el cliente haya dejado archivos con propietario `root` en tu home. Si ocurre, corrígelo así:

```bash
sudo chown "$USER":"$USER" /home/$USER/.docker -R
sudo chmod g+rwx /home/$USER/.docker -R
```

Importante:

- pertenecer al grupo `docker` equivale en la práctica a tener privilegios elevados sobre el host
- no añadas usuarios no administrativos a este grupo

### 7. Verificar versiones e instalación básica

Comprobar cliente, motor y plugin Compose:

```bash
docker version
docker info
docker compose version
docker buildx version
```

La salida debe reflejar:

- cliente y servidor Docker disponibles
- arquitectura `aarch64` o `arm64`
- Compose v2 accesible con `docker compose`

Prueba mínima del motor:

```bash
docker run --rm hello-world
```

Si esta orden termina correctamente, el motor ha podido:

- contactar con el daemon
- descargar una imagen compatible con ARM64
- crear y ejecutar un contenedor

### 8. Verificar Docker Compose con un stack mínimo

Crear el directorio de prueba:

```bash
mkdir -p /home/<usuario>/homelab/compose/_verify-docker
```

Guardar ahí el `compose.yaml` mostrado al principio del documento y ejecutarlo:

```bash
cd /home/<usuario>/homelab/compose/_verify-docker
docker compose config
docker compose up
```

Resultado esperado:

- Compose resuelve correctamente el fichero
- se descarga la imagen `hello-world`
- el contenedor imprime el mensaje de prueba y termina sin error

Después puedes limpiar el contenedor:

```bash
docker compose down --remove-orphans
```

### 9. Comprobaciones operativas recomendadas

Antes de dar por cerrada la fase, revisa también estos puntos:

```bash
docker ps -a
docker images
systemctl is-enabled docker
systemctl is-enabled containerd
```

Estado deseado:

- Docker responde sin `sudo`
- ambos servicios quedan habilitados al reiniciar
- la instalación no ha creado errores visibles en `journalctl -u docker`

Consulta rápida del log si quieres una validación adicional:

```bash
sudo journalctl -u docker -n 50 --no-pager
```

### 10. Nota importante sobre firewall y puertos publicados

Este punto es especialmente relevante porque en la fase anterior se activó **UFW** en el host.

Cuando publiques puertos con Docker, por ejemplo usando `ports:` en Compose, el tráfico puede no comportarse exactamente igual que un servicio nativo protegido solo por UFW. Por eso, en este homelab conviene mantener estas reglas:

- no publicar puertos por inercia
- exponer solo los servicios que realmente deban escucharse en la LAN o por Tailscale
- documentar cada puerto publicado en su documento correspondiente
- revisar más adelante la política de red y puertos junto con Portainer y el mapa de puertos del homelab

En esta fase de instalación base no hace falta abrir ningún puerto nuevo.

### 11. Qué queda pendiente tras este documento

Este documento deja listo el runtime de contenedores, pero todavía faltan las piezas de operación de la fase 2:

1. Definir la estrategia de organización de stacks en `docs/02-docker/02-estructura-compose.md`.
2. Desplegar Portainer CE en `docs/02-docker/03-portainer.md`.
3. Desplegar Watchtower en `docs/02-docker/04-watchtower.md`.

Orden recomendado:

- primero cerrar la convención de directorios, nombres y redes de Compose
- después desplegar Portainer
- por último automatizar actualizaciones de imágenes con Watchtower

## Almacenamiento

### Rutas relevantes tras instalar Docker

| Ruta | Ubicación esperada | Uso |
|---|---|---|
| `/var/lib/docker` | SSD NVMe | imágenes, capas, redes, metadatos internos |
| `/var/run/docker.sock` | sistema | socket Unix del daemon |
| `/etc/docker` | SSD NVMe | configuración del daemon si se personaliza |
| `/home/<usuario>/homelab/compose` | SSD NVMe | stacks y composes del homelab |
| `/home/<usuario>/homelab/data` | SSD NVMe | datos persistentes de servicios vía bind mount |

Decisiones de almacenamiento para este homelab:

- no se mueve `data-root` de Docker a los discos USB
- `hd2t` y `hd5t` se reservan para multimedia y backups, no para el runtime interno de Docker
- los volúmenes críticos de servicios deben seguir montándose desde el **NVMe**

Razón práctica:

- si `hd2t` o `hd5t` no están presentes al arrancar, Docker debe seguir pudiendo iniciar normalmente
- separar el runtime del motor de los discos USB reduce acoplamientos innecesarios

## Backup
Para esta fase no interesa respaldar ciegamente todo `/var/lib/docker` como estrategia principal. Lo importante es poder reconstruir el runtime y restaurar después los datos persistentes reales de los servicios.

Conviene incluir en backup:

- `/home/<usuario>/homelab/compose/`
- `/home/<usuario>/homelab/.env` y/o `/home/<usuario>/homelab/env/` cuando existan
- `/etc/docker/daemon.json` si más adelante se crea o personaliza
- scripts operativos relacionados con Docker bajo `/home/<usuario>/homelab/scripts/`
- la propia documentación del homelab si se mantiene junto al proyecto

No conviene usar como estrategia principal:

- copiar `/var/lib/docker` en caliente como si fuera una copia fiable de aplicaciones completas

La política correcta para los servicios será:

- respaldar sus bind mounts y datos persistentes en `/home/<usuario>/homelab/data`
- respaldar bibliotecas y backups grandes en `hd2t`
- reinstalar Docker si hiciera falta y volver a levantar los stacks desde Compose

## Referencias
- Docker Docs: Install Docker Engine on Debian
  https://docs.docker.com/engine/install/debian/
- Docker Docs: Linux post-installation steps for Docker Engine
  https://docs.docker.com/engine/install/linux-postinstall/
- Docker Docs: Install the Docker Compose plugin on Linux
  https://docs.docker.com/compose/install/linux/
- Docker Docs: Docker with iptables and UFW
  https://docs.docker.com/engine/network/packet-filtering-firewalls/#docker-and-ufw
- Docker Hub: `hello-world`
  https://hub.docker.com/_/hello-world
