# Instalación de Docker Engine y Docker Compose

## Descripción

Procedimiento para instalar **Docker Engine** y el plugin **Docker Compose** en la **Raspberry Pi 5** del homelab, usando paquetes oficiales para **ARM64** y dejando el motor listo para las siguientes fases de orquestación. El objetivo es disponer de una base estable y mantenible: instalación desde repositorio oficial, servicios gestionados por `systemd`, uso operativo sin `sudo` para el usuario administrador y verificación completa del runtime.

Este proyecto asume una instalación de **Raspberry Pi OS Lite 64-bit** o sistema equivalente basado en **Debian Bookworm** arrancando desde el **SSD NVMe**. En este contexto, Docker debe vivir en el almacenamiento principal del sistema y no en los discos USB dedicados a multimedia y backups.

## Requisitos Previos

- Haber completado [01-instalacion-os.md](../01-sistema/01-instalacion-os.md).
- Haber completado [02-configuracion-inicial.md](../01-sistema/02-configuracion-inicial.md).
- Haber completado [03-seguridad-base.md](../01-sistema/03-seguridad-base.md).
- Haber completado [04-estructura-directorios.md](../01-sistema/04-estructura-directorios.md).
- Poder acceder por terminal con el usuario administrativo y permisos de `sudo`.
- Disponer de conectividad de red saliente funcional para descargar paquetes desde el repositorio oficial de Docker.
- Puertos necesarios en esta fase:
  - ninguno publicado para aplicaciones
  - **no** habilitar la API TCP de Docker (`2375`/`2376`)

## Objetivo de esta Fase

Al terminar este documento, el estado esperado es este:

- Docker Engine queda instalado desde el repositorio oficial de Docker.
- El plugin **Docker Compose** queda disponible mediante `docker compose`.
- Los servicios `docker` y `containerd` quedan activos y habilitados al arranque.
- El usuario administrador puede ejecutar comandos Docker sin `sudo`.
- La base del runtime queda lista para desplegar stacks en las siguientes fases.

## Docker Compose

No aplica todavía como despliegue de servicios. En esta fase no se levanta ningún stack propio del homelab, pero sí se instala el plugin oficial que se usará más adelante con la sintaxis **`docker compose`**.

## Configuración

### 1. Verificar arquitectura y base del sistema

Antes de instalar Docker, confirma que la Raspberry Pi está corriendo una base **ARM64** compatible y que el sistema realmente vive sobre el **SSD NVMe**:

```bash
uname -m
dpkg --print-architecture
. /etc/os-release && echo "$PRETTY_NAME - $VERSION_CODENAME"
findmnt -no SOURCE /
```

Resultado esperado:

- `uname -m` debe devolver normalmente `aarch64`.
- `dpkg --print-architecture` debe devolver `arm64`.
- La distribución debe ser una base compatible con **Debian Bookworm**.
- `/` debe estar montado sobre el **SSD NVMe**, no sobre la microSD.

Si estuvieras usando **Raspberry Pi OS de 32 bits**, no sigas este procedimiento: esta guía está escrita para el escenario ARM64 definido por el proyecto.

### 2. Eliminar paquetes conflictivos si existen

Antes de instalar los paquetes oficiales, retira posibles paquetes previos o alternativos que puedan entrar en conflicto:

```bash
for pkg in docker.io docker-compose docker-doc podman-docker containerd runc; do
  dpkg -s "$pkg" >/dev/null 2>&1 && sudo apt remove -y "$pkg"
done
```

Si ninguno de esos paquetes estaba presente, este paso no hará cambios.

### 3. Preparar el repositorio oficial de Docker

Actualiza el índice de paquetes, instala dependencias básicas y añade la clave y el repositorio oficial:

```bash
sudo apt update
sudo apt install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
sudo tee /etc/apt/sources.list.d/docker.sources > /dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $(. /etc/os-release && echo "$VERSION_CODENAME")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
sudo apt update
```

En este homelab interesa usar el repositorio oficial porque simplifica actualizaciones futuras y evita mezclar paquetes mantenidos por la distribución con paquetes mantenidos por Docker.

### 4. Instalar Docker Engine y el plugin Compose

Instala el motor, la CLI, `containerd`, `buildx` y el plugin oficial de Compose:

```bash
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

Con esto queda instalada la base operativa que se usará en los siguientes documentos:

- `docker-ce`: motor Docker
- `docker-ce-cli`: cliente de línea de comandos
- `containerd.io`: runtime de contenedores
- `docker-buildx-plugin`: builds modernos
- `docker-compose-plugin`: Compose integrado como `docker compose`

### 5. Confirmar el estado del servicio y el autoarranque

En sistemas Debian modernos, Docker suele arrancar automáticamente tras la instalación. Aun así, conviene validarlo y dejar el autoarranque explícito:

```bash
sudo systemctl status docker --no-pager
sudo systemctl status containerd --no-pager
sudo systemctl enable docker.service
sudo systemctl enable containerd.service
```

Si alguno no estuviera arrancado, inícialo manualmente:

```bash
sudo systemctl start docker
sudo systemctl start containerd
```

Comprueba otra vez:

```bash
sudo systemctl is-active docker
sudo systemctl is-enabled docker
sudo systemctl is-active containerd
sudo systemctl is-enabled containerd
```

El resultado esperado para ambos servicios es `active` y `enabled`.

### 6. Permitir uso de Docker sin `sudo`

Para operar con comodidad desde el usuario administrador del homelab, añade ese usuario al grupo `docker`:

```bash
getent group docker || sudo groupadd docker
sudo usermod -aG docker $USER
newgrp docker
```

Después de esto, la membresía del grupo debe quedar activa en la sesión actual o, si prefieres, tras cerrar y abrir sesión otra vez por SSH.

Importante: pertenecer al grupo `docker` equivale en la práctica a tener privilegios de nivel `root` sobre el host. En este homelab se acepta ese modelo por simplicidad operativa, pero conviene tratarlo como un permiso administrativo real.

Verifica que tu usuario ya pertenece al grupo:

```bash
id
groups
```

### 7. Corregir permisos de `~/.docker` si antes usaste `sudo`

Si ejecutaste comandos `docker` con `sudo` antes de añadir tu usuario al grupo `docker`, puede quedar un problema de permisos en el directorio de configuración local. Si ves errores relacionados con `~/.docker/config.json`, corrígelo así:

```bash
sudo chown "$USER":"$USER" /home/"$USER"/.docker -R
sudo chmod g+rwx "$HOME/.docker" -R
```

Si ese directorio no existe todavía, puedes ignorar este paso.

### 8. Verificación operativa

Valida que todo el stack base responde correctamente:

```bash
docker version
docker info
docker compose version
docker run --rm hello-world
docker ps
```

Resultados esperados:

- `docker version` devuelve versión de cliente y servidor.
- `docker info` muestra el runtime activo sin errores.
- `docker compose version` confirma que el plugin Compose está instalado.
- `docker run --rm hello-world` descarga la imagen de prueba, ejecuta el contenedor y termina correctamente.
- `docker ps` no requiere `sudo`.

### 9. Criterio operativo para este homelab

Deja fijadas estas reglas desde el principio:

- usa siempre **`docker compose`**, no el binario legado `docker-compose`
- no expongas la API remota de Docker por TCP
- no muevas `Docker Engine` ni `containerd` a los discos USB `hd2t` o `hd5t`
- no uses el script `get.docker.com` en este proyecto: interesa una instalación gestionable por `apt`

### 10. Nota importante sobre firewall

Aunque en esta fase todavía no se publican puertos de aplicaciones, conviene dejar clara una limitación importante: cuando más adelante publiques puertos de contenedores, Docker no se comporta igual que un servicio normal del host frente a `ufw`.

Para este proyecto, la regla práctica es esta:

- no asumas que `ufw` por sí solo controla correctamente los puertos publicados por Docker
- cuando llegue el momento de abrir o restringir servicios, sigue el documento de red y firewall del proyecto y aplica las reglas con criterio compatible con Docker

Esto será especialmente relevante en [06-puertos-y-firewall.md](../03-red/06-puertos-y-firewall.md).

## Almacenamiento

En esta fase, Docker usa almacenamiento local del host:

- **runtime e imágenes**: `/var/lib/docker/`
- **estado de `containerd`**: `/var/lib/containerd/`
- **socket local**: `/var/run/docker.sock`

Para este homelab, esas rutas deben permanecer en el disco del sistema, es decir, en el **SSD NVMe**. No conviene moverlas a `hd2t` ni a `hd5t`, porque esos discos están reservados para multimedia, descargas y backups según [04-estructura-directorios.md](../01-sistema/04-estructura-directorios.md).

Además, el criterio operativo futuro queda así:

- los archivos `compose` vivirán en `/home/<user>/homelab/compose/`
- los `.env` y configuraciones auxiliares vivirán en `/home/<user>/homelab/`
- los datos persistentes de servicios vivirán en `/home/<user>/homelab/data/<servicio>/`

## Backup

En este punto todavía no hay servicios del homelab desplegados, así que el backup relevante es pequeño:

- `/etc/apt/sources.list.d/docker.sources`
- `/etc/apt/keyrings/docker.asc`
- cualquier fichero adicional bajo `/etc/docker/` si más adelante personalizas el daemon

No tiene sentido respaldar imágenes de prueba ni contenedores efímeros como `hello-world`. El contenido de `/var/lib/docker/` se puede reconstruir más adelante a partir de los `compose`, imágenes descargadas y datos persistentes versionados o respaldados por servicio.

## Referencias

- Docker Docs: [Install Docker Engine on Debian](https://docs.docker.com/engine/install/debian/)
- Docker Docs: [Linux post-installation steps for Docker Engine](https://docs.docker.com/engine/install/linux-postinstall/)
- Docker Docs: [Install the Docker Compose plugin](https://docs.docker.com/compose/install/linux/)
- Docker Docs: [Packet filtering and firewalls](https://docs.docker.com/engine/network/packet-filtering-firewalls/)
