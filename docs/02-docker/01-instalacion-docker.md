# Instalación de Docker Engine y Docker Compose

## Descripción

Tras `docs/01-sistema/04-estructura-directorios.md` la Raspberry Pi 5 tiene el sistema endurecido, los discos `/mnt/hd5t` y `/mnt/hd2t` montados, el grupo `media` creado y el árbol de directorios de servicios poblado en `/mnt/hd2t/apps/...`. Lo que falta para empezar a desplegar servicios es instalar **el motor que los ejecuta**: Docker Engine + el plugin Docker Compose v2.

Este documento cubre, **una sola vez** y con justificación:

1. **Qué Docker se instala y por qué**. Repositorio oficial de Docker para Debian (paquetes `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`, `docker-compose-plugin`) y **no** la imagen `docker.io` de los repos de Debian ni el script de conveniencia `get.docker.com`. Razones más abajo.
2. **Cómo se configura para la Raspberry Pi 5**. ARM64 (`aarch64`), kernel reciente con cgroups v2, microSD pequeña pero discos USB grandes. Implica mover el `data-root` de Docker a `/mnt/hd2t/docker`, configurar el driver de logs con rotación, y dejar `containerd` y `docker.service` en autoarranque.
3. **Cómo se integra con la seguridad existente**. El grupo `docker` es **sudo equivalente**: añadir un usuario al grupo `docker` permite escapes triviales a root del host. Se documenta esa propiedad y se acepta conscientemente para `homelab`. Además, Docker manipula `iptables` directamente y **se salta `ufw`** por defecto: esa interacción se documenta y se fija la política de la fase 2 (servicios siempre detrás de Caddy o bindeados a `127.0.0.1`/LAN).

Cuando este documento se haya aplicado, `docker run --rm hello-world` funciona, `docker compose version` devuelve `v2.x` y se puede pasar a `02-estructura-compose.md` para definir cómo se organizan los `docker-compose.yml` del repo.

> **Recordatorio de alcance**: el homelab sigue siendo solo **LAN + Tailscale**. No se publica ningún puerto de Docker hacia internet en este documento. Las decisiones de exposición (Caddy + Tailscale) viven en su fase correspondiente.

---

## Requisitos Previos

- Fase 1 completa (`01-instalacion-os.md` … `04-estructura-directorios.md`):
  - Raspberry Pi OS Lite **64-bit** (Bookworm) instalado y actualizado.
  - Usuario `homelab` con `sudo`, UID/GID `1000`, acceso por SSH con clave.
  - `ufw` activo permitiendo SSH, `fail2ban` y `unattended-upgrades` configurados.
  - `/mnt/hd2t` y `/mnt/hd2t/apps/` creados, propietario `homelab:homelab`, modo `0750`.
- Conectividad a internet desde la Pi (para `apt update` contra `download.docker.com`).
- Hora del sistema correctamente sincronizada (`timedatectl` con `System clock synchronized: yes`); `apt-secure` y la verificación de firmas del repo Docker dependen de ella.
- Comprobación rápida del entorno antes de empezar:

  ```bash
  uname -m                 # esperado: aarch64
  cat /etc/os-release      # ID=debian, VERSION_CODENAME=bookworm
  id homelab               # uid=1000(homelab) gid=1000(homelab) groups=...,1100(media)
  systemctl is-active ufw  # active
  findmnt /mnt/hd2t        # presente, ext4, noatime
  ```

  Si `uname -m` devuelve `armv7l`, se está en una imagen de 32 bits: hay que reflashear con la imagen 64-bit (ver `01-instalacion-os.md`). Docker en `armv7` funciona, pero cierra la puerta a un 30 % largo del catálogo de imágenes (Authelia, algunos Stash, varios LinuxServer.io en builds modernos), así que no es opción para este homelab.

---

## Decisión: qué Docker instalar

| Opción | Cómo se instala | Por qué se descarta o acepta |
|---|---|---|
| `apt install docker.io` (paquete de Debian) | Inmediato pero la versión queda **rezagada** muchos meses respecto a upstream y el plugin `docker-compose-v2` empaquetado va aún más por detrás. Algunos servicios que dependen de capabilities recientes (BuildKit, healthchecks granulares) se rompen. | **Descartado**. |
| Script `curl -fsSL https://get.docker.com \| sh` | Cómodo, instala desde el repo oficial. Pero **automatiza decisiones que aquí queremos explícitas** (qué repo, qué clave GPG, qué arquitectura) y, si el script cambia, la fase 2 se vuelve no-reproducible. | **Descartado** salvo emergencia. |
| Repo APT oficial de Docker (`download.docker.com`), paquetes `docker-ce` + plugins | Versión estable más reciente, actualizada vía `apt upgrade` (y por tanto vía `unattended-upgrades` cuando se permita), claves GPG verificables, sin sorpresas. Es lo que **recomienda Docker** para producción y lo que homologa este homelab. | **Aceptado**. |
| Rootless Docker | Ejecuta el daemon como `homelab` sin necesidad de `docker` group. Atractivo en lo de seguridad, pero rompe casos importantes para este homelab: bind a puertos privilegiados (53 de Pi-hole, 80/443 de Caddy si se usa), USB passthrough (Zigbee, ZWave en Home Assistant), `/proc` y red avanzada. La complejidad operativa supera al beneficio cuando el host ya está dedicado al homelab y el operador es el dueño físico de la Pi. | **Descartado** para este homelab; reabrible en `04-seguridad/` si el modelo de amenaza cambia. |

Resultado: **Docker Engine + Compose v2 desde el repositorio oficial APT**, paquetes `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`, `docker-compose-plugin`.

---

## Instalación de Docker Engine

Se sigue la guía oficial de Docker para Debian, particularizada a `bookworm` y `arm64`.

### 1) Limpiar instalaciones previas

Por si la microSD viene de un flasheo anterior o si en algún momento se probó `docker.io`:

```bash
for pkg in docker.io docker-doc docker-compose docker-compose-v2 \
           podman-docker containerd runc; do
    sudo apt -y remove "$pkg" 2>/dev/null || true
done
sudo apt -y autoremove
```

`runc` y `containerd` los volverá a instalar Docker como dependencias suyas (`containerd.io`, `docker-ce`).

### 2) Dependencias para repos APT por HTTPS

```bash
sudo apt update
sudo apt install -y ca-certificates curl gnupg
```

`gnupg` es necesario para procesar la clave del repo. `ca-certificates` ya viene con el sistema base, se confirma. `curl` se usará en las siguientes secciones (validación de versión, healthchecks).

### 3) Clave GPG del repositorio oficial de Docker

```bash
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/debian/gpg \
    -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
```

El uso de `/etc/apt/keyrings/` con clave por repo (en lugar del clásico `/etc/apt/trusted.gpg.d/`) es la práctica vigente en Debian Bookworm: cada repo APT firma solo lo suyo. Si en un futuro se elimina el repo de Docker, basta con borrar `docker.asc` y `docker.list`.

Verificación del fingerprint (debe coincidir con el publicado por Docker Inc.):

```bash
sudo gpg --no-default-keyring \
         --keyring /etc/apt/keyrings/docker.asc --list-keys
# pub   rsa4096 ... [SC] [expires: ...]
# 9DC8 5822 9FC7 DD38 854A  E2D8 8D81 803C 0EBF CD88
# uid  Docker Release (CE deb) <docker@docker.com>
```

Si el fingerprint no coincide con `9DC85822 9FC7DD38 854AE2D8 8D81803C 0EBFCD88`, **abortar** y revisar la red (DNS interceptado, MITM): no se sigue.

### 4) Repositorio APT de Docker para `arm64` + Bookworm

```bash
echo "deb [arch=$(dpkg --print-architecture) \
signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/debian \
$(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
    sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

sudo apt update
```

`dpkg --print-architecture` resuelve a `arm64` en la Pi 5. `VERSION_CODENAME` resuelve a `bookworm`. El resultado en `/etc/apt/sources.list.d/docker.list` debe ser exactamente una línea como:

```
deb [arch=arm64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian bookworm stable
```

`apt update` no debe quejarse de claves o repos; si lo hace, se vuelve a la sección 3.

### 5) Instalación de los paquetes

```bash
sudo apt install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin
```

Tras la instalación los binarios y el servicio quedan disponibles:

```bash
docker --version
# Docker version 27.x.x, build ...

docker compose version
# Docker Compose version v2.x.x

systemctl is-enabled docker containerd
# enabled
# enabled

systemctl is-active docker containerd
# active
# active
```

Si `is-enabled` devolviese `disabled` (no debería: el `.deb` lo activa solo), forzarlo:

```bash
sudo systemctl enable --now docker containerd
```

> **`docker-compose-plugin` vs `docker-compose`**: el binario antiguo `docker-compose` (Compose v1, en Python) **no se instala**. Compose v2 se invoca como subcomando: `docker compose up`, `docker compose ps`, etc. Toda la documentación del homelab usa la forma `docker compose` (con espacio). Si algún hábito muscular escribe `docker-compose`, fallará; es deliberado para evitar mezclar v1 y v2.

---

## Configuración del daemon: `data-root`, logs y rotación

Por defecto Docker guarda imágenes, contenedores, volúmenes nominales y capas en `/var/lib/docker`, que en esta Pi vive **en la microSD**. Eso choca con la regla de oro de Fase 1 ("no escribir datos voluminosos en la microSD") por dos motivos:

1. **Capacidad**. La microSD es de 64 GB. Una imagen Jellyfin moderna pesa ~700 MB; Nextcloud + MariaDB ~600 MB; sumando ~30 servicios el espacio se va.
2. **Desgaste**. Las capas writable de los contenedores y los logs `json-file` rotan continuamente. Eso es exactamente el patrón que destruye microSDs en pocos meses.

Solución: mover `data-root` a `/mnt/hd2t/docker/` y configurar logs con rotación estricta. Se hace **antes** de ejecutar el primer contenedor para no tener que migrar datos.

### 1) Crear el destino en `hd2t`

```bash
sudo install -d -o root -g root -m 0710 /mnt/hd2t/docker
```

Modo `0710`: solo `root` (que es quien corre el daemon) entra; `homelab` no entra al árbol crudo de Docker (la interfaz de uso es `docker` cli, no `ls /mnt/hd2t/docker`). Mantener este directorio cerrado evita que un descuido (`tar` total, `rsync` mal pensado) toque internals de containerd.

> Este directorio **no** estaba en el script `00-create-homelab-tree.sh` de la fase 1: aquel script solo creaba directorios de **servicios y bibliotecas**. El árbol de Docker es del daemon, no del usuario, y por eso vive bajo `root:root` en vez de `homelab:homelab`.

### 2) `daemon.json`

```bash
sudo install -d -o root -g root -m 0755 /etc/docker
sudo tee /etc/docker/daemon.json >/dev/null <<'EOF'
{
  "data-root": "/mnt/hd2t/docker",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3",
    "compress": "true"
  },
  "default-address-pools": [
    { "base": "172.30.0.0/16", "size": 24 }
  ],
  "live-restore": true,
  "userland-proxy": false
}
EOF
```

Justificación clave por clave:

| Clave | Valor | Por qué |
|---|---|---|
| `data-root` | `/mnt/hd2t/docker` | Saca el árbol de Docker de la microSD, como se argumentó. |
| `log-driver` | `json-file` | Driver por defecto, simple, suficiente para este homelab. La alternativa `journald` también vale, pero quedaría compitiendo con `journald` del host por el espacio en `/var/log/journal/`, que vive en la microSD. Prefiero ficheros bajo `data-root` (en `hd2t`) y rotados. |
| `log-opts.max-size` | `10m` | Cada log de contenedor no pasa de 10 MB antes de rotar. |
| `log-opts.max-file` | `3` | Tres ficheros: el activo + dos rotados. Total ≤ 30 MB por contenedor. Con ~30 contenedores, techo ≤ 1 GB para logs. Aceptable en `hd2t`. |
| `log-opts.compress` | `"true"` | Logs rotados se comprimen con gzip. Reduce el techo real a unos pocos cientos de MB. |
| `default-address-pools` | `172.30.0.0/16`, `/24` por red | Por defecto Docker usa `172.17.0.0/16` (`bridge`), `172.18..` (`docker_gwbridge`)… que pueden colisionar con la red doméstica si el router asigna `192.168.x.0/24` o algún VPN reusa `172.17.x`. Tailscale, en concreto, usa `100.64/10` y no choca, pero algunas rutas corporativas sí. Reservar `172.30.0.0/16` es conservador y trazable. |
| `live-restore` | `true` | Permite que los contenedores sigan corriendo durante un `systemctl restart docker` (por ejemplo, para aplicar un upgrade). Solo afecta a contenedores ya en marcha; los nuevos esperan a que el daemon reaparezca. |
| `userland-proxy` | `false` | Desactiva el `docker-proxy` de userspace para `port-publishing`. Reduce overhead, evita un proceso por puerto y delega todo a iptables. En ARM64 con kernel reciente no hay contraindicación. |

`json-file` con `compress` requiere Docker ≥ 24. Las versiones que llegan por el repo oficial van muy por encima.

### 3) Aplicar la configuración

```bash
sudo systemctl restart docker
```

Sin contenedores creados todavía la operación es trivial: el daemon arranca, ve `data-root` apuntando a `/mnt/hd2t/docker`, lo inicializa (crea `image/`, `containers/`, `volumes/`, `network/`…) y queda listo.

Verificación:

```bash
docker info | grep -E 'Docker Root Dir|Logging Driver|Live Restore'
# Docker Root Dir: /mnt/hd2t/docker
# Logging Driver: json-file
# Live Restore Enabled: true

ls -ld /mnt/hd2t/docker /var/lib/docker 2>/dev/null
# /mnt/hd2t/docker         drwx--x--- root:root
# /var/lib/docker          puede o no existir; estará vacío.
```

Si `/var/lib/docker` está poblado tras el restart, significa que `daemon.json` no se está leyendo (revisar JSON con `python3 -m json.tool /etc/docker/daemon.json`).

---

## Post-instalación: grupo `docker` y autoarranque

### Grupo `docker` para el usuario `homelab`

Ejecutar `docker` como `homelab` requiere o bien `sudo docker ...` (incómodo, contamina `~/.bash_history` con `sudo`) o bien añadir `homelab` al grupo `docker`:

```bash
sudo usermod -aG docker homelab
```

Hay que **cerrar sesión SSH y volver a entrar** (o ejecutar `newgrp docker` en la sesión actual) para que el cambio sea efectivo. Verificación:

```bash
id homelab
# uid=1000(homelab) gid=1000(homelab) groups=...,999(docker),1100(media),...
docker run --rm hello-world
# Hello from Docker!
```

> **Aviso de seguridad ineludible**: pertenecer al grupo `docker` equivale a tener `sudo` sin contraseña. Cualquier miembro de `docker` puede lanzar `docker run -v /:/host --rm -it alpine chroot /host` y obtener una shell root del host. **No es un bug**, es la naturaleza del API de Docker (`/var/run/docker.sock` da acceso al daemon, que corre como root). Para este homelab se acepta porque:
>
> - El usuario `homelab` ya tenía `sudo` (concedido en `02-configuracion-inicial.md`).
> - No hay otros usuarios humanos en el sistema.
> - Las llaves SSH están protegidas (`03-seguridad-base.md`) y `fail2ban` mitiga abuso desde la red.
>
> No se añade ningún otro usuario al grupo `docker`. En caso de necesitarlo (operadores secundarios, automatizaciones), se reabre la decisión documentándolo en `04-seguridad/`.

### Autoarranque (ya cubierto, se confirma)

Los `.deb` oficiales de Docker dejan `docker.service` y `containerd.service` con `enabled` por defecto. Solo se confirma:

```bash
systemctl is-enabled docker.service docker.socket containerd.service
# enabled
# enabled
# enabled
```

`docker.socket` es la unidad que escucha en `/var/run/docker.sock` y arranca `docker.service` bajo demanda. No se desactiva (se rompería el cliente).

Tras un reboot:

```bash
sudo reboot
# ... reentrar por SSH ...
systemctl is-active docker
# active
docker ps -a
# CONTAINER ID   IMAGE         ...   NAMES
# (lista vacía si todavía no se ha hecho 02-estructura-compose.md)
```

Si el daemon no arranca solo, casi siempre es porque `/mnt/hd2t` no estaba montado al iniciar `docker.service`. Eso ya lo cubre la opción `nofail` del `fstab` (`docs/00-hardware/03-preparacion-discos.md`) y un `After=mnt-hd2t.mount` no es necesario porque systemd descubre la dependencia por el `data-root`. En la práctica funciona; si fallara, queda como nota para `13-operaciones/`.

---

## Interacción con UFW e `iptables`

Docker manipula `iptables` directamente para implementar publicación de puertos (`-p 80:80`) y aislamiento entre redes (`bridge`, `none`, `host`). Eso ocurre **a un nivel inferior** al que `ufw` mira: el reglero de UFW no ve el tráfico de Docker, y un `ufw deny 80/tcp` **no** impide que un contenedor con `-p 80:80` reciba tráfico de la LAN. Es un comportamiento conocido y documentado por Docker.

Implicaciones para este homelab:

1. **No se modifica UFW para "tapar" Docker** (las soluciones tipo `ufw-docker` añaden una mantenibilidad cuestionable y, mal aplicadas, dejan agujeros peores). UFW en este homelab protege exclusivamente lo que **no es Docker**: SSH (22), respuestas ICMP, posibles servicios systemd futuros.
2. **La política de exposición de servicios se controla en el `docker-compose.yml` de cada servicio**, mediante una de estas tres formas:
   - **Bind a `127.0.0.1`** (no a `0.0.0.0`). Ej.: `ports: ["127.0.0.1:8080:8080"]`. Solo accesible desde el host. Caddy hace de puerta delantera.
   - **Sin `ports:`, solo en una red Docker compartida**. Otros contenedores se comunican por nombre DNS interno. Caddy se encarga de publicar al exterior.
   - **Bind a la IP LAN** (caso de Pi-hole, que necesita escuchar a toda la LAN en el 53). Aceptado como excepción documentada en su servicio.
3. **Ningún servicio, sin excepción**, hace `network_mode: host` para "ahorrarse" la red Docker, salvo que su documento lo justifique técnicamente (Home Assistant con descubrimiento mDNS, por ejemplo). Las excepciones se inventarían en sus respectivos servicios.

La política completa de redes Docker se cierra en `02-estructura-compose.md`. Aquí se establece **el principio**: UFW sigue, Docker no se le añade artificialmente, y la exposición se gestiona en compose.

> **Tailscale y Docker**: Tailscale corre como demonio del host (no en contenedor). Las IPs `100.64/10` no chocan con `default-address-pools` (`172.30/16`). Un contenedor con `network_mode: host` podría ser alcanzado por Tailscale; uno con red bridge solo si se publica el puerto. Eso se diseña por servicio.

---

## Pruebas de verificación

Tras instalar y configurar:

| Comprobación | Comando | Resultado esperado |
|---|---|---|
| Docker engine en marcha | `systemctl is-active docker` | `active` |
| Versión coherente | `docker --version` | `Docker version 27.x` o superior |
| Compose v2 disponible | `docker compose version` | `Docker Compose version v2.x.x` |
| `data-root` desplazado | `docker info \| grep 'Docker Root Dir'` | `/mnt/hd2t/docker` |
| Driver de logs | `docker info \| grep 'Logging Driver'` | `json-file` |
| Live-restore activo | `docker info \| grep 'Live Restore'` | `Live Restore Enabled: true` |
| Storage driver válido | `docker info \| grep 'Storage Driver'` | `overlay2` (sobre ext4 sin sorpresas) |
| Cgroup v2 | `docker info \| grep 'Cgroup Version'` | `2` |
| `homelab` en grupo `docker` | `id homelab` | contiene `docker` |
| `hello-world` ARM64 | `docker run --rm hello-world` | mensaje de bienvenida |
| Imagen Alpine ARM64 | `docker run --rm alpine uname -m` | `aarch64` |
| Compose mínimo | ver bloque inferior | contenedor `nginx-test` levanta y se elimina |
| Limpieza tras pruebas | `docker system prune -af --volumes` | borra imágenes y caches del test, deja `data-root` vacío de objetos |
| Persistencia tras reboot | `sudo reboot` y reverificar `docker info` | sin cambios |

Compose mínimo de prueba (no se versiona en el repo, es un *smoke test*):

```bash
mkdir -p ~/_smoke-docker && cd ~/_smoke-docker
cat > docker-compose.yml <<'EOF'
services:
  hello:
    image: nginx:alpine
    container_name: nginx-test
    restart: "no"
    ports: ["127.0.0.1:18080:80"]
EOF
docker compose up -d
curl -fsS http://127.0.0.1:18080/ >/dev/null && echo OK
docker compose down --rmi all --volumes
cd && rm -rf ~/_smoke-docker
```

`OK` confirma:

- Resolución de imagen (`nginx:alpine` se descarga de Docker Hub, builds multi-arch).
- Asignación de puertos contra `127.0.0.1` (UFW no estorba; un `curl` desde otro host de la LAN al `:18080` debe **fallar**, lo cual se puede comprobar opcionalmente).
- `docker compose down --rmi all --volumes` deja el sistema sin restos.

---

## Almacenamiento

Volúmenes y rutas que toca este documento:

| Ruta | Soporte | Owner:Group | Modo | Contenido |
|---|---|---|---|---|
| `/etc/docker/daemon.json` | microSD | `root:root` | `0644` | Configuración del daemon (data-root, logs, redes). |
| `/etc/apt/keyrings/docker.asc` | microSD | `root:root` | `0644` | Clave GPG del repo APT de Docker. |
| `/etc/apt/sources.list.d/docker.list` | microSD | `root:root` | `0644` | Repo APT de Docker. |
| `/mnt/hd2t/docker/` | hd2t | `root:root` | `0710` | Árbol completo de Docker (imágenes, volúmenes, layers, logs por contenedor). |
| `/var/lib/docker/` | microSD | (no se usa) | — | Vacío tras configurar `data-root`. |
| `/var/run/docker.sock` | runtime | `root:docker` | `0660` | Socket de la API. Acceso vía pertenencia al grupo `docker`. |

**No** se crea en este documento ningún directorio dentro de `/mnt/hd2t/apps/...`: cada servicio creará / reusará los suyos en su propio documento, según el árbol fijado en `01-sistema/04-estructura-directorios.md`.

---

## Backup

A nivel del repositorio del homelab:

| Artefacto | Estrategia |
|---|---|
| `/etc/docker/daemon.json` | Versionado: el contenido exacto está en este documento. Reproducible en minutos tras un reflasheo. |
| `/etc/apt/sources.list.d/docker.list` y clave GPG | Reproducibles desde este documento, no se respaldan. |
| Pertenencia de `homelab` al grupo `docker` | Reproducible con `usermod -aG docker homelab`. Documentada aquí. |

A nivel de datos (Borg, fase 7):

- **`/mnt/hd2t/docker/`**: **se excluye** del backup. Imágenes y capas son **regenerables** desde Docker Hub / GHCR; volverlas a guardar duplica espacio y rompe la deduplicación de Borg con cada `docker pull`. Los datos persistentes de los servicios viven en `/mnt/hd2t/apps/...`, **fuera** de `data-root`, mediante `bind mounts`.
- **`/var/lib/docker/`**: irrelevante, está vacío.
- **Volúmenes nominales de Docker (`docker volume create`)**: en este homelab **no se usan**. Todos los servicios usan `bind mounts` a `/mnt/hd2t/apps/<servicio>/...`. La regla la fija `02-estructura-compose.md`.

Si en algún momento se introduce un volumen nominal (decisión a justificar en su servicio), su backup pasa por `docker run --rm -v vol:/from -v /tmp/dump:/to alpine tar cf /to/vol.tar -C /from .` o similar. Borg lo recogerá como fichero.

---

## Errores frecuentes y troubleshooting

| Síntoma | Causa probable | Resolución |
|---|---|---|
| `Got permission denied while trying to connect to the Docker daemon socket` | Sesión SSH abierta antes de `usermod -aG docker`. | Cerrar y reabrir la sesión, o `newgrp docker`. |
| `docker compose: 'compose' is not a docker command.` | Falta `docker-compose-plugin`. | `sudo apt install docker-compose-plugin`. |
| `failed to start daemon: error initializing graphdriver` | `data-root` apunta a un FS no soportado o no montado al arrancar Docker. | Confirmar `findmnt /mnt/hd2t` antes de `systemctl start docker`. La opción `nofail` del fstab puede dejar el disco fuera tras un reboot con USB lento; reintentar con `systemctl restart docker`. |
| `iptables: No chain/target/match by that name` en `docker compose up` | Kernel sin módulo `iptable_nat` cargado. | En la Pi 5 con kernel oficial no ocurre; si se diera, `sudo modprobe iptable_nat` y persistirlo en `/etc/modules`. |
| `Error response from daemon: pull access denied` | Imagen privada o tag inexistente; o falta de internet. | Confirmar conexión y revisar el tag. |
| `OCI runtime exec failed: exec format error` | Se está ejecutando una imagen `amd64` en `arm64`. | Buscar la imagen multi-arch o forzar `--platform=linux/arm64`. La mayoría de imágenes del catálogo del homelab (LinuxServer.io, Bitnami, oficiales) son multi-arch. |
| Logs de un contenedor no rotan | Versión muy antigua de Docker. | El repo oficial garantiza ≥ 24, no debe ocurrir; si pasara, reinstalar `docker-ce`. |

---

## Decisiones que **no** se toman en este documento

- **Diseño de redes Docker** (`compose.yaml` con `networks: { homelab: external: true }`, segmentación de servicios públicos/privados). Va en `02-estructura-compose.md`.
- **Despliegue de Portainer y Watchtower** (gestión web y actualizaciones). Van en `03-portainer.md` y `04-watchtower.md`.
- **Política de actualizaciones**: hoy no se delega a `unattended-upgrades` para Docker (el daemon se reinicia y eso afecta al runtime). Se documenta en `04-watchtower.md` cómo se gestionan actualizaciones de imágenes y, separadamente, del propio engine.
- **Registro privado de imágenes**: no aplica al homelab por ahora. Si en algún momento hace falta (builds locales reutilizables), se evalúa en `04-seguridad/` o en `13-operaciones/`.
- **Configuración de runtimes alternativos** (`nvidia`, `gvisor`). No aplica.

---

## Verificación Final

Antes de pasar a `02-estructura-compose.md`:

| Comprobación | Comando | Resultado esperado |
|---|---|---|
| Docker engine instalado y vivo | `systemctl is-active docker containerd` | `active` x2 |
| Compose v2 disponible | `docker compose version` | `v2.x.x` |
| `daemon.json` sano | `python3 -m json.tool /etc/docker/daemon.json` | imprime el JSON sin errores |
| `data-root` apunta a `hd2t` | `docker info \| grep 'Docker Root Dir'` | `/mnt/hd2t/docker` |
| Logs con rotación configurada | `docker info \| grep -A2 'Default Logging Driver'` | `json-file`, `max-size=10m`, `max-file=3`, `compress=true` |
| `homelab` puede `docker` sin sudo | `docker ps` desde `homelab` | sin error de permisos |
| `hello-world` ARM64 funciona | `docker run --rm hello-world` | mensaje de bienvenida |
| Sin restos en microSD tras pruebas | `du -sh /var/lib/docker 2>/dev/null` | `0` o no existe |
| UFW sigue activo | `sudo ufw status` | `Status: active`, regla SSH presente |
| Reboot conservador | `sudo reboot` y reverificar | Docker arranca solo, contenedores (cuando los haya) reaparecen por `restart: unless-stopped`. |

Cumplido el último punto, la Fase 2 está abierta: la siguiente puerta es decidir **cómo se organizan los `docker-compose.yml` del repo** (`02-estructura-compose.md`).

---

## Referencias

- [Documento anterior: `docs/01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md)
- [Documento siguiente: `docs/02-docker/02-estructura-compose.md`](./02-estructura-compose.md)
- [Docker — Install Docker Engine on Debian](https://docs.docker.com/engine/install/debian/)
- [Docker — Post-installation steps for Linux](https://docs.docker.com/engine/install/linux-postinstall/)
- [Docker — `daemon.json` reference](https://docs.docker.com/reference/cli/dockerd/#daemon-configuration-file)
- [Docker — Configure logging drivers (`json-file`)](https://docs.docker.com/config/containers/logging/json-file/)
- [Docker — Compose v2](https://docs.docker.com/compose/)
- [Docker and UFW — known interaction](https://docs.docker.com/network/packet-filtering-firewalls/)
- [Docker — Rootless mode (alternativa descartada)](https://docs.docker.com/engine/security/rootless/)
- [Raspberry Pi OS — releases](https://www.raspberrypi.com/documentation/computers/os.html)
