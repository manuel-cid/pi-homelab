# Instalación de Docker Engine y Docker Compose

## Descripción

Instalación de **Docker Engine** y del plugin **Docker Compose v2** sobre Raspberry Pi OS Bookworm (ARM64), usando el repositorio APT oficial de Docker. Este documento cubre la instalación del paquete, el _post-install_ (grupo `docker`, autoarranque, _live-restore_), la **reubicación del `data-root` al disco externo `hd2t`** para no consumir microSD ni desgastarla con escrituras de imágenes y capas, la configuración de **rotación de logs** y la verificación de que el motor está sano antes de desplegar el primer stack.

Tras esta fase, el host queda listo para que las siguientes (`docs/02-docker/02-estructura-compose.md`, `docs/03-red/`, ...) se limiten a definir _stacks_ con sus `docker-compose.yml`, asumiendo que `docker compose up -d` funciona desde cualquier directorio del repositorio Compose y que las imágenes y capas viven en `hd2t`.

> **Alcance**: este documento instala **el motor**, configura el demonio y crea el primer contenedor de prueba. **No** define la organización del repositorio Compose (eso es `docs/02-docker/02-estructura-compose.md`), **no** despliega Portainer ni Watchtower (`docs/02-docker/03-portainer.md`, `docs/02-docker/04-watchtower.md`), **no** crea redes macvlan (`docs/03-red/01-macvlan.md`) ni añade reglas extra al firewall del host. La convivencia de Docker con `nftables` ya quedó descrita en `docs/01-sistema/03-seguridad-base.md`, sección "Convivencia con Docker".

> **Recordatorio de red**: el homelab está expuesto **solo a la LAN y a Tailscale**. Docker pulla imágenes desde Docker Hub usando la conectividad saliente del host (cadena `output accept` del firewall), pero ningún servicio se publica al exterior. Cualquier `ports:` que aparezca en compose posteriores se entiende limitado a la LAN.

---

## Requisitos previos

- `docs/01-sistema/02-configuracion-inicial.md` completado: hostname, locale, zona horaria, swap en `/mnt/hd2t/system/swap/swapfile`.
- `docs/01-sistema/03-seguridad-base.md` completado: usuario `homelab` con clave SSH, `nftables` activo con política _default deny_ en `input`/`forward` y `accept` en `output`, `unattended-upgrades` operativo.
- `docs/01-sistema/04-estructura-directorios.md` completado: `hd2t` montado en `/mnt/hd2t` con las ramas `services/`, `backups/`, `system/` ya creadas con `root:root 0755`.
- Conectividad saliente comprobada (la instalación descarga paquetes de `download.docker.com`):

  ```bash
  curl -fsSL https://download.docker.com/linux/debian/gpg | head -c 64
  ```

  Debe devolver el inicio de un bloque PGP. Si falla, revisar DNS (`resolvectl status`) y la cadena `output` del firewall antes de seguir.

- Confirmar arquitectura y versión de Debian:

  ```bash
  dpkg --print-architecture                 # arm64
  . /etc/os-release && echo "$VERSION_CODENAME"  # bookworm
  ```

  Si `dpkg --print-architecture` no responde `arm64`, **detenerse**: el resto del documento asume Raspberry Pi OS Lite 64-bit. Una imagen de 32 bits (`armhf`) es incompatible con la organización de los stacks posteriores y obliga a regenerar la microSD (`docs/01-sistema/01-instalacion-os.md`).

---

## Por qué el repositorio oficial de Docker (y no `docker.io` de Debian)

Debian distribuye un paquete `docker.io` mantenido por el equipo de Debian. Tiene tres problemas para este homelab:

1. **Versión retrasada**: suele ir uno o dos _major_ por detrás de Docker upstream. En Bookworm está en la rama 20.x, mientras que el repositorio oficial mantiene la 24.x/25.x con _live-restore_, mejoras de `containerd`, soporte cgroup v2 mejor afinado y _bug-fixes_ recientes.
2. **Sin `docker compose v2`**: `docker.io` empaqueta `docker-compose` v1 (Python, _legacy_, descatalogado upstream desde 2023). Los `docker-compose.yml` modernos (`compose-spec`) se prueban contra v2.
3. **Sin `containerd.io` reciente**: el paquete viene atado a la versión de `containerd` del archive, que también va por detrás.

El repositorio oficial entrega `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin` y `docker-compose-plugin` en versiones coherentes y actualizadas, y `unattended-upgrades` (configurado en `docs/01-sistema/03-seguridad-base.md`) ya instala parches de seguridad de la fuente `docker.com` en cuanto se añada (paso 1.4 abajo).

---

## 1. Añadir el repositorio APT oficial de Docker

### 1.1 Preparar dependencias

```bash
sudo apt update
sudo apt install -y ca-certificates curl gnupg
```

`ca-certificates` y `gnupg` ya están en cualquier Bookworm reciente; el `apt install` es _idempotente_ y se mantiene como red de seguridad.

### 1.2 Importar la clave GPG del repositorio

La clave se guarda en `/etc/apt/keyrings/`, que es la ubicación recomendada desde Debian 12 para las claves "no _system-wide_" (por servicio). Permisos `0644` para que `apt` la pueda leer.

```bash
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/debian/gpg \
    -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
```

### 1.3 Añadir la lista APT

Una sola línea, ya parametrizada por arquitectura y _codename_:

```bash
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/debian $(. /etc/os-release && echo \"$VERSION_CODENAME\") stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
```

> Si en el futuro Raspberry Pi OS adopta un _codename_ que el archivo de Docker aún no soporta (caso típico el primer mes de un nuevo Debian estable), forzar `bookworm` manualmente en el comando anterior. Docker mantiene el sufijo de la última estable hasta que publica el siguiente.

### 1.4 Habilitar la actualización automática del paquete

`unattended-upgrades` ya cubre `Debian:stable-security` y los repos del propio Pi (`docs/01-sistema/03-seguridad-base.md`). Para que también cubra Docker, añadir el origen al fichero `50unattended-upgrades`:

```bash
sudo sed -i \
    '/^Unattended-Upgrade::Origins-Pattern {/a\        "origin=Docker";' \
    /etc/apt/apt.conf.d/50unattended-upgrades
sudo unattended-upgrade --dry-run -d 2>&1 | grep -E 'Allowed origins|Docker'
```

La salida del `--dry-run` debe listar `Docker:bookworm` entre los orígenes permitidos. Si no, abrir `/etc/apt/apt.conf.d/50unattended-upgrades` y comprobar que la línea `"origin=Docker";` está dentro del bloque `Origins-Pattern`.

### 1.5 Refrescar el índice

```bash
sudo apt update
```

No debe haber errores de firma. Si aparece `NO_PUBKEY`, el `chmod a+r` del paso 1.2 se ha quedado por aplicar.

---

## 2. Instalar Docker Engine, CLI, containerd y plugins

```bash
sudo apt install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin
```

Tras la instalación, comprobar versiones (sin tocar permisos todavía: con `sudo`):

```bash
sudo docker version
sudo docker compose version
sudo docker buildx version
```

`docker compose version` debe responder `Docker Compose version v2.x.y`. Si responde "command not found" (y no "no such command compose"), el paquete `docker-compose-plugin` no se ha instalado: repetir el `apt install`.

---

## 3. Reubicar `data-root` a `hd2t`

Por defecto, Docker guarda imágenes, capas, _named volumes_ y metadatos en `/var/lib/docker/`, es decir, en la **microSD**. Esto tiene dos problemas en una Pi 5 con SD de 64 GB:

- **Espacio**: una decena de imágenes medianas (Jellyfin, Nextcloud, Home Assistant) ocupan rápidamente entre 8 y 15 GB. Sumado al sistema base, los logs y el _swap_ desviado a `hd2t`, queda poco margen.
- **Desgaste**: las microSD tienen ciclos de escritura limitados. Pulls de imágenes, _writable layers_ de contenedores efímeros y `docker system prune` repetidos aceleran su muerte.

Solución: mover `data-root` a `/mnt/hd2t/system/docker/`. Esa rama encaja en la convención de `docs/01-sistema/04-estructura-directorios.md`, que reserva `system/` para "uso interno del host" (no datos de servicios).

> Esto **sólo se hace ahora**, antes de tener nada desplegado. Mover `data-root` con contenedores corriendo o con datos críticos requiere parar Docker, hacer un `cp -a`, ajustar `daemon.json` y rezar. Hacerlo en limpio es trivial.

### 3.1 Crear el directorio destino

```bash
sudo mkdir -p /mnt/hd2t/system/docker
sudo chown root:root /mnt/hd2t/system/docker
sudo chmod 0710 /mnt/hd2t/system/docker
```

`0710` deja el directorio sólo accesible a `root`, igual que el `/var/lib/docker` original. Docker no exige permisos concretos en el `data-root`, pero los suyos son `0710 root:root`; se replica para no levantar avisos en auditorías.

### 3.2 Garantizar que Docker arranca **después** de montar `hd2t`

`/mnt/hd2t` se monta vía `fstab` durante `local-fs.target`. `docker.service` ya depende de `local-fs.target` por defecto, pero si el disco USB tarda en aparecer (típico en Pi: el _udev_ del USB 3 puede tardar 5-10 s tras `local-fs.target`), Docker arrancaría con el bind-mount aún no listo y crearía `/mnt/hd2t/system/docker/` como directorio en el _root filesystem_, no en `hd2t`. Con la SD llena tras unas semanas, esto sería difícil de diagnosticar.

`RequiresMountsFor=` resuelve la dependencia explícita: systemd retrasa el arranque de Docker hasta que la unidad de montaje correspondiente está activa.

```bash
sudo mkdir -p /etc/systemd/system/docker.service.d
sudo tee /etc/systemd/system/docker.service.d/10-wait-hd2t.conf > /dev/null <<'EOF'
[Unit]
RequiresMountsFor=/mnt/hd2t/system/docker
EOF
sudo systemctl daemon-reload
```

### 3.3 Configurar `daemon.json`

`/etc/docker/daemon.json` es el fichero de configuración del demonio. Al instalar el paquete no existe; se crea desde cero con todas las opciones que se quieren fijar de una vez:

```bash
sudo install -d -m 0755 /etc/docker
sudo tee /etc/docker/daemon.json > /dev/null <<'EOF'
{
  "data-root": "/mnt/hd2t/system/docker",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "5",
    "compress": "true"
  },
  "live-restore": true,
  "default-address-pools": [
    { "base": "172.20.0.0/16", "size": 24 }
  ]
}
EOF
```

Desglose de cada opción:

- **`data-root`** — el motivo de toda esta sección.
- **`log-driver: json-file`** — el driver por defecto. Se mantiene explícito para fijarlo (algunas distros lo cambian a `journald`, lo que no encaja con `docker logs` tal cual lo usan los stacks).
- **`log-opts.max-size: 10m` / `max-file: 5` / `compress: true`** — rotación automática a 5 ficheros de 10 MB por contenedor (50 MB efectivos antes de comprimir, ~10-15 MB tras gzip). Sin esto, un servicio _verbose_ como Jellyfin puede dejar `5+ GB` en el log de un solo contenedor antes de que nadie lo note.
- **`live-restore: true`** — los contenedores siguen vivos durante un reinicio de `dockerd` (parche del demonio, _upgrade_ de paquete). En una Pi con sólo dos discos USB, perder Pi-hole o Home Assistant durante 30 s por un `apt upgrade` del paquete `docker-ce` no es aceptable; con _live-restore_ ese tiempo cae a 0.
- **`default-address-pools`** — fija el rango que Docker usará para crear redes _bridge_ por defecto. Se elige `172.20.0.0/16` con bloques `/24` para no chocar con:
  - `172.17.0.0/16` (la `bridge` _builtin_, no se toca).
  - `100.64.0.0/10` (CGNAT, lo usa Tailscale).
  - `192.168.0.0/16` (LAN doméstica).
  - `10.0.0.0/8` (a menudo en uso por VPNs corporativas o por el propio router).

  Ajustar el rango si la LAN del usuario ya usa `172.20.0.0/16` (poco común). El detalle está en la documentación oficial de Docker (ver Referencias).

> Validación sintáctica del fichero antes de reiniciar:
>
> ```bash
> sudo dockerd --validate --config-file=/etc/docker/daemon.json
> ```
>
> Devuelve `configuration OK` o un error de parsing con la línea ofensiva. **No** reiniciar el servicio si la validación falla: una `daemon.json` inválida deja Docker sin arrancar y el sistema sin contenedores.

### 3.4 Aplicar la nueva configuración

Como aún no hay contenedores, basta con reiniciar el servicio. Si por alguna razón ya se hubieran creado (por una prueba previa), parar antes:

```bash
sudo systemctl restart docker
sudo systemctl status docker --no-pager | head -20
```

`Active: active (running)` confirma el arranque. Comprobar que el `data-root` se ha movido:

```bash
sudo docker info --format '{{.DockerRootDir}}'
# /mnt/hd2t/system/docker
ls -la /mnt/hd2t/system/docker
# debe contener buildkit/ containers/ image/ network/ overlay2/ plugins/ runtimes/ swarm/ tmp/ trust/ volumes/ ...
```

A partir de aquí, `/var/lib/docker/` queda **vacío** o sólo con un par de subdirectorios huérfanos creados por el primer arranque previo a esta config. Se pueden borrar con seguridad sólo si `docker info` ya reporta el _root_ nuevo:

```bash
# Sólo si DockerRootDir es /mnt/hd2t/system/docker
sudo find /var/lib/docker -mindepth 1 -maxdepth 1 -exec sudo rm -rf {} +
```

---

## 4. Post-install: grupo `docker` y autoarranque

### 4.1 Añadir el usuario `homelab` al grupo `docker`

Poder lanzar `docker` sin `sudo` no es sólo comodidad: la integración con el repositorio Compose (`~/homelab/`) y los _hooks_ de Borgmatic (`docs/07-backups/02-borgmatic.md`) asumen que `docker compose` se ejecuta como `homelab`.

```bash
sudo usermod -aG docker homelab
```

> **Aviso de seguridad**: cualquier usuario en el grupo `docker` es **equivalente a root** en la práctica (`docker run -v /:/host --rm alpine chroot /host bash` da una shell de root sin pasar por `sudo`). Esto es por diseño del demonio Docker. La superficie de ataque del homelab es la del propio usuario `homelab` con clave SSH y `sudo NOPASSWD` (heredado del setup), por lo que añadir `docker` al grupo no degrada el modelo.
>
> Si se necesitara un perfil _menos privilegiado_ para tareas concretas (por ejemplo, un script de monitorización que sólo lee `docker ps`), la solución es **rootless mode** o un `socket proxy` (Tecnativa/docker-socket-proxy), no quitar al usuario administrador del grupo. Cualquier servicio que necesite acceso al socket lo recibirá vía proxy en su propio doc de fase.

Refrescar la pertenencia al grupo en la sesión actual sin tener que cerrar SSH:

```bash
exec sg docker -c "$SHELL"
groups
# ... debe listar 'docker' entre los grupos
docker version
# Server / Client deben responder sin sudo
```

> El truco `exec sg docker -c "$SHELL"` evita el _logout/login_ y deja la pertenencia activa **sólo en la shell actual**. La pertenencia persistente (en cualquier sesión nueva) ya está aplicada por el `usermod -aG`.

### 4.2 Habilitar autoarranque

`apt` deja `docker.service` y `containerd.service` en `enable` automáticamente, pero conviene confirmarlo de forma explícita:

```bash
sudo systemctl enable --now docker.service containerd.service
systemctl is-enabled docker
systemctl is-enabled containerd
```

Ambos comandos deben responder `enabled`.

> **`docker.socket` opcional**: el _socket_ de activación bajo demanda (`docker.socket`) sólo es útil cuando se quiere arrancar `dockerd` la primera vez que alguien hace `docker ps`. En una Pi que sirve una decena de servicios con `restart: unless-stopped`, **siempre** queremos `dockerd` corriendo desde el _boot_, así que se usa `docker.service` directamente. La unidad `docker.socket` ya viene incluida y se enlaza automáticamente; no hay que tocarla.

---

## 5. Verificación funcional

### 5.1 `docker run hello-world`

La prueba canónica. Lanza un contenedor de 4 KB que imprime un mensaje y termina:

```bash
docker run --rm hello-world
```

Salida esperada:

```
Hello from Docker!
This message shows that your installation appears to be working correctly.
...
```

Si falla con `permission denied while trying to connect to the Docker daemon socket`, el grupo `docker` no se ha aplicado en la sesión: repetir el `exec sg docker -c "$SHELL"` o cerrar y reabrir la conexión SSH.

### 5.2 `docker compose` con un fichero mínimo

Crear un compose temporal para confirmar que el plugin v2 está operativo y que la red por defecto sale del rango configurado:

```bash
mkdir -p /tmp/docker-smoke && cd /tmp/docker-smoke
cat > docker-compose.yml <<'EOF'
services:
  whoami:
    image: traefik/whoami:latest
    restart: "no"
    ports:
      - "127.0.0.1:18080:80"
EOF

docker compose up -d
sleep 2
curl -s http://127.0.0.1:18080/ | head -5
docker compose down
cd ~ && rm -rf /tmp/docker-smoke
```

`curl` debe devolver el _payload_ típico de `whoami` (Hostname, IP, RemoteAddr...). Si la red Docker creada es del rango `172.20.x.0/24`, la configuración `default-address-pools` está activa.

### 5.3 Comprobaciones del demonio

```bash
docker info | grep -E 'Server Version|Cgroup Version|Live Restore|Logging Driver|Docker Root Dir'
```

Debe listar:

- `Server Version: 24.x.y` (o superior).
- `Cgroup Version: 2` — Bookworm usa cgroup v2 por defecto, requerido por imágenes recientes (Home Assistant 2024+, por ejemplo).
- `Live Restore Enabled: true`.
- `Logging Driver: json-file`.
- `Docker Root Dir: /mnt/hd2t/system/docker`.

Si `Cgroup Version` reporta `1`, hay un `/boot/firmware/cmdline.txt` con `systemd.unified_cgroup_hierarchy=0` o un kernel custom. **No** seguir hasta tener cgroup v2: varios servicios fallarán de formas no obvias más adelante.

---

## Verificación final

Antes de pasar a `docs/02-docker/02-estructura-compose.md`, comprobar:

- [ ] `docker version` responde Cliente y Servidor sin `sudo`, ambos en la rama 24.x o superior.
- [ ] `docker compose version` devuelve `Docker Compose version v2.x.y`.
- [ ] `docker info --format '{{.DockerRootDir}}'` devuelve `/mnt/hd2t/system/docker`.
- [ ] `docker info | grep "Live Restore"` devuelve `Live Restore Enabled: true`.
- [ ] `docker info | grep "Logging Driver"` devuelve `Logging Driver: json-file`.
- [ ] `docker info | grep "Cgroup Version"` devuelve `Cgroup Version: 2`.
- [ ] `systemctl is-enabled docker containerd` devuelve `enabled` para ambos.
- [ ] `groups homelab` incluye `docker`.
- [ ] `ls /mnt/hd2t/system/docker` lista los subdirectorios estándar (`overlay2/`, `image/`, `containers/`, `volumes/`, ...).
- [ ] `find /var/lib/docker -mindepth 1 -maxdepth 1 2>/dev/null` está vacío (todo lo persistente está en `hd2t`).
- [ ] `docker network ls` muestra las redes _builtin_ `bridge`, `host`, `none`. Las nuevas redes que se creen (a partir de la fase 3) saldrán del rango `172.20.0.0/16`.
- [ ] `docker run --rm hello-world` imprime el mensaje de bienvenida y termina con código 0.
- [ ] Tras un `sudo reboot`, `docker ps` (sin `sudo`) responde antes de 30 s desde el _login_ y `docker info` sigue reportando el `data-root` en `hd2t`.
- [ ] `sudo nft list ruleset` sigue mostrando la tabla `inet filter` original **y** ahora también las tablas `nat` y `filter` que crea Docker (cadenas `DOCKER`, `DOCKER-USER`, `DOCKER-ISOLATION-STAGE-1/2`). Ambas conviven sin conflicto.

---

## Troubleshooting

### `permission denied while trying to connect to the Docker daemon socket`

El usuario actual no está en el grupo `docker` **en esta sesión**. Comprobar:

```bash
groups                       # ¿incluye 'docker'?
id -Gn homelab               # ¿incluye 'docker'?
```

Si `id -Gn` lo incluye pero `groups` (de la sesión actual) no, basta con cerrar SSH y volver a entrar. Si tampoco lo incluye `id -Gn`, repetir `sudo usermod -aG docker homelab` y comprobar `/etc/group`:

```bash
getent group docker
# docker:x:998:homelab
```

### `docker.service` falla con `failed to start daemon: error initializing graphdriver`

Suele ocurrir si `daemon.json` apunta a un `data-root` en un filesystem que no soporta `overlay2` (por ejemplo, NTFS o exFAT). En este homelab ambos discos son ext4, así que el síntoma indica otra cosa: que `/mnt/hd2t/` **no estaba montado** cuando Docker arrancó, y ha creado `/mnt/hd2t/system/docker` en el _root filesystem_ encima del punto de montaje.

Recuperación:

1. Parar Docker: `sudo systemctl stop docker docker.socket`.
2. Comprobar el montaje: `mount | grep hd2t` debe listar `/mnt/hd2t` con tipo `ext4`. Si **no** aparece, montar con `sudo mount /mnt/hd2t` y revisar `dmesg` por errores de USB.
3. Verificar que el _drop-in_ `RequiresMountsFor` está aplicado:

   ```bash
   systemctl cat docker.service | grep RequiresMountsFor
   ```

4. Si encima del punto de montaje hay datos huérfanos del primer arranque (raro, pero posible), eliminarlos **con el filesystem `hd2t` desmontado**:

   ```bash
   sudo systemctl stop docker docker.socket
   sudo umount /mnt/hd2t
   sudo rm -rf /mnt/hd2t/system/docker
   sudo mount /mnt/hd2t
   sudo systemctl start docker
   ```

### `apt install docker-ce` falla con `404 Not Found` en `download.docker.com`

El sufijo del repositorio (`bookworm`, `trixie`, ...) no existe aún en Docker para esa versión de Debian. Forzar a `bookworm` mientras se actualiza:

```bash
sudo sed -i 's| [a-z]\+ stable| bookworm stable|' /etc/apt/sources.list.d/docker.list
sudo apt update
```

Cuando Docker publique el sufijo nuevo, revertir con un `apt-cache policy docker-ce` para confirmar que toma del repo correcto.

### `docker compose up` falla con `Cannot connect to the Docker daemon at unix:///var/run/docker.sock`

Variantes:

- **`dockerd` no está corriendo**: `sudo systemctl status docker` y mirar el log (`journalctl -u docker -n 100`). Causas habituales: `daemon.json` malformado (validar con `sudo dockerd --validate`), `data-root` sin permisos, `containerd.service` caído.
- **Versión vieja de Compose** (v1) instalada por separado: `pip3 list | grep -i compose` y `which docker-compose`. Si existe un `docker-compose` v1 _shadow_ del PATH del usuario, desinstalarlo (`pip3 uninstall docker-compose` o eliminar el binario). Usar siempre `docker compose` (con espacio), nunca `docker-compose` (con guión).

### Tras la reinstalación, los contenedores antiguos no aparecen en `docker ps -a`

Si se reinstala Docker o se cambia el `data-root` con datos previos, los contenedores se quedan referenciados al `data-root` viejo. Recuperación mínima:

1. Confirmar el `data-root` activo: `docker info --format '{{.DockerRootDir}}'`.
2. Localizar el viejo: típicamente `/var/lib/docker` o un montaje anterior.
3. Si el usuario quiere recuperar ese estado, parar Docker, hacer `sudo cp -a /var/lib/docker/. /mnt/hd2t/system/docker/` (con el destino vacío) y reiniciar. Si no, simplemente borrar el viejo.

En este homelab esto **no debería pasar nunca** porque el `data-root` se fija antes del primer despliegue. Si ocurre tras una reinstalación de OS, es preferible volver a desplegar los stacks desde el repositorio Compose en `~/homelab/` y los volúmenes en `/mnt/hd2t/services/`, en lugar de _resucitar_ contenedores de un `data-root` antiguo.

### `docker info` reporta `Cgroup Version: 1`

Bookworm usa cgroup v2 por defecto desde el _kernel_ del propio Pi. Si aparece v1:

1. Revisar `/boot/firmware/cmdline.txt`. Si contiene `systemd.unified_cgroup_hierarchy=0`, eliminarlo.
2. Reiniciar (`sudo reboot`).
3. Confirmar con `mount | grep cgroup2` (debe haber un montaje `cgroup2` en `/sys/fs/cgroup`).

Algunos tutoriales antiguos de Pi recomiendan v1 para soportar imágenes que aún no migraron. Para este homelab no aplica: las imágenes de la fase 8 (Home Assistant) y posteriores **requieren** cgroup v2.

### Logs de un contenedor que no rotan o crecen sin límite

`max-size`/`max-file` de `daemon.json` se aplican **a contenedores nuevos**. Los que ya existían cuando se cambió la config siguen con la rotación previa hasta que se recreen:

```bash
docker compose up -d --force-recreate <servicio>
```

Para confirmar la rotación efectiva en un contenedor concreto:

```bash
docker inspect --format '{{json .HostConfig.LogConfig}}' <contenedor>
```

Debe responder `{"Type":"json-file","Config":{"compress":"true","max-file":"5","max-size":"10m"}}`.

### `docker pull` muy lento o falla con _timeout_ en una Pi por WiFi

Aunque `docs/00-hardware/02-esquema-conexiones.md` recomienda Ethernet, si la Pi está temporalmente por WiFi:

- Comprobar la latencia: `ping -c 4 download.docker.com` y `ping -c 4 registry-1.docker.io`.
- _Pulls_ paralelos saturan el router doméstico. Limitar la concurrencia:

  ```bash
  sudo tee -a /etc/docker/daemon.json.tmp > /dev/null <<'EOF'
  ,"max-concurrent-downloads": 2
  EOF
  ```

  (Editar con cuidado para mantener JSON válido; `dockerd --validate` antes de reiniciar.)

La solución estable es pasar a Ethernet en cuanto sea posible: USB 3.0 + Gigabit es ~10× más rápido para _pulls_ que el WiFi 2.4/5 GHz típico de la Pi 5.

---

## Referencias

- Docker Engine — Instalación en Debian: <https://docs.docker.com/engine/install/debian/>
- Docker Engine — Post-install para Linux: <https://docs.docker.com/engine/install/linux-postinstall/>
- Docker Engine — `dockerd` y `daemon.json`: <https://docs.docker.com/reference/cli/dockerd/>
- Docker Engine — `default-address-pools`: <https://docs.docker.com/reference/cli/dockerd/#daemon-configuration-file>
- Docker Engine — Live Restore: <https://docs.docker.com/config/containers/live-restore/>
- Docker Engine — Logging driver `json-file`: <https://docs.docker.com/config/containers/logging/json-file/>
- Docker Compose v2 — Especificación: <https://docs.docker.com/compose/compose-file/>
- systemd — `RequiresMountsFor=`: <https://www.freedesktop.org/software/systemd/man/systemd.unit.html#RequiresMountsFor=>
- Debian — Apt _signed-by_ en `/etc/apt/keyrings/`: <https://wiki.debian.org/DebianRepository/UseThirdParty>
- Raspberry Pi OS — cgroup v2: <https://www.raspberrypi.com/documentation/computers/configuration.html>
