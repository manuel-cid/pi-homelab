# Instalación de Docker

## Descripción

**Instalación de Docker Engine y el plugin de Docker Compose v2** sobre Raspberry Pi OS Lite 64-bit (Debian Bookworm, ARM64), partiendo del host endurecido y con la estructura de directorios ya creada en la [Fase 1](../01-sistema/04-estructura-directorios.md). Al terminar este documento, la Pi tendrá un demonio Docker funcional, configurado con límites de logs sensatos para no desgastar la microSD y con un *address pool* por defecto que **no colisiona con la LAN**, listo para que el resto de fases empiecen a desplegar contenedores.

Este documento cubre, en este orden:

1. **Limpieza** de paquetes Docker antiguos (`docker.io`, `docker-doc`, `podman-docker`...) que vienen como dependencia transitiva en algunos repos.
2. **Repositorio oficial de Docker** para Debian Bookworm ARM64: clave GPG, fichero de sources, `apt update`.
3. **Instalación** de `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin` y `docker-compose-plugin`.
4. **Configuración del demonio** (`/etc/docker/daemon.json`): driver de logs, retención, `live-restore`, *default address pools* fuera del rango de la LAN.
5. **Habilitar y arrancar** `docker.service` y `containerd.service`, y verificar el autoarranque.
6. **Post-install**: añadir `homelab` al grupo `docker` (con su caveat de seguridad).
7. **Verificación** con `hello-world`, `docker compose version` y revisión del filtrado de paquetes con `ufw`.

> **Alcance**: aquí solo se instala y configura el motor; **no** se despliega ningún servicio todavía. La organización de los `docker-compose.yml` y la red Docker compartida se deciden en [`02-estructura-compose.md`](./02-estructura-compose.md). Portainer y Watchtower viven en [`03-portainer.md`](./03-portainer.md) y [`04-watchtower.md`](./04-watchtower.md).

> **Recordatorio**: el homelab opera en **LAN + Tailscale**. No hay puertos abiertos en el router hacia internet. Aun así, el demonio Docker tiene su propia política de `iptables`/`nftables` que **no** está bajo el control de `ufw` por defecto: lo cubrimos en §7 y se reabrirá en [`../03-red/`](../03-red/) (macvlan) y [`../13-operaciones/04-red-y-puertos.md`](../13-operaciones/04-red-y-puertos.md).

---

## Requisitos Previos

- Raspberry Pi 5 con **Raspberry Pi OS Lite 64-bit** (Debian Bookworm) instalado y endurecido según la [Fase 1](../01-sistema/) (instalación, configuración inicial, seguridad base, estructura de directorios).
- Conexión a internet vía Ethernet (necesaria para `apt update` contra `download.docker.com`).
- Discos `hd5t` y `hd2t` montados (`findmnt /mnt/hd5t /mnt/hd2t`) y estructura de directorios aplicada según [`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md).
- Usuario `homelab` (`UID=1000`, `GID=1000`) con `sudo` y, opcionalmente, ya miembro de `media` (`GID=1100`).
- `ufw` activo con SSH permitido desde la LAN según [`../01-sistema/03-seguridad-base.md`](../01-sistema/03-seguridad-base.md). Antes de tocar el firewall, dejar abierta una **segunda sesión SSH** como red de seguridad.

### Decisiones de diseño asumidas

| Decisión | Valor por defecto | Justificación |
|---|---|---|
| Origen de los paquetes | **Repositorio oficial de Docker** (`download.docker.com/linux/debian`) | El paquete `docker.io` de Debian está retrasado varias versiones y no incluye Compose v2 como plugin. La instalación recomendada por Docker para Debian/Ubuntu en producción es su propio APT repo ([Install Docker Engine on Debian](https://docs.docker.com/engine/install/debian/)). |
| Versión de Docker Compose | **Plugin v2** (`docker-compose-plugin` → `docker compose ...`) | Compose v1 (`docker-compose`, en Python) está EOL desde julio de 2023. Compose v2 es un plugin Go que se invoca como subcomando `docker compose` y es el que mantiene Docker Inc. |
| Script de conveniencia (`get.docker.com`) | **No usar** | Útil para pruebas rápidas, pero opaco y desaconsejado por Docker en entornos persistentes; complica diagnóstico cuando falla `apt`. |
| Storage driver | `overlay2` (default en Bookworm con ext4) | Es el driver recomendado y de mayor rendimiento; no se cambia. |
| `cgroups` | **v2 unificado** (default en Bookworm) | El kernel de Bookworm arranca con `systemd.unified_cgroup_hierarchy=1`. Docker 24+ soporta cgroups v2 nativamente. No hay que tocar `cmdline.txt`. |
| `data-root` (almacén de imágenes y capas) | `/var/lib/docker` (en microSD, valor por defecto) | Coherente con [`SERVICES.md`](../../SERVICES.md) (*"microSD 64 GB: sistema operativo, Docker Engine"*). Las imágenes ARM64 del homelab ocupan ~10–25 GB; entran de sobra en una microSD de 64 GB tras el SO. Si en el futuro se queda corta, en §4.4 se documenta cómo reubicarlo a `/mnt/hd2t/docker/`. |
| Driver de logs | `json-file` con `max-size=10m` y `max-file=3` | Sin límites, los logs de algunos contenedores (Caddy, Pi-hole con muchas consultas) llegan a varios GB y desgastan la microSD. 30 MB por contenedor (3 ficheros × 10 MB) es suficiente para diagnóstico con Dozzle ([`../05-monitorizacion/06-dozzle.md`](../05-monitorizacion/06-dozzle.md)) y se rota automáticamente. |
| `live-restore` | **Activado** | Permite reiniciar el demonio Docker (p. ej. tras un upgrade de `docker-ce`) **sin matar los contenedores**. Especialmente útil con `unattended-upgrades` aplicando parches. |
| `default-address-pools` | `base=172.20.0.0/16, size=24` | Sin esto, las redes user-defined que cree Compose se asignan dentro de `172.17.0.0/12`, lo que puede colisionar con redes corporativas/VPN. Reservando `172.20.0.0/16` (rango privado RFC 1918 que **no** se solapa con la LAN típica `192.168.0.0/16` ni con Tailscale `100.64.0.0/10`) cada red Compose ocupa una `/24` (≈250 IPs) y caben 256 redes. |
| Grupo `docker` | `homelab` añadido al grupo `docker` | Permite ejecutar `docker ...` sin `sudo`. **Equivale a root** (el demonio escucha en `/var/run/docker.sock` y monta cualquier path como root); se acepta el riesgo porque `homelab` ya tiene `sudo` ilimitado y nadie más usa la Pi. |
| Autoarranque | `docker.service` y `containerd.service` **`enable --now`** | El homelab debe levantar todos sus contenedores tras un reboot sin intervención manual. |
| Reglas de `iptables` que crea Docker | **Se dejan tal cual** (Docker gestiona `DOCKER-USER` y `DOCKER` en `nftables`) | No se desactiva `iptables=true` en `daemon.json`. Las reglas de `ufw` siguen aplicándose al **tráfico al host**, pero el tráfico **a contenedores** lo decide la cadena `DOCKER-USER`. Se documenta esta sutileza en §7 y se gestiona finamente en [`../13-operaciones/04-red-y-puertos.md`](../13-operaciones/04-red-y-puertos.md). |

---

## 1. Limpiar instalaciones previas

Aunque la imagen base de Raspberry Pi OS Lite no incluye Docker, conviene asegurarse de que ningún paquete equivalente está presente: si se instaló `docker.io` para una prueba previa, su `containerd` y los binarios entran en conflicto con `docker-ce`.

```bash
sudo apt remove -y \
  docker.io \
  docker-doc \
  docker-compose \
  docker-compose-v2 \
  podman-docker \
  containerd \
  runc \
  2>/dev/null || true
sudo apt autoremove -y
```

`apt remove` con paquetes inexistentes devuelve no-cero; el `|| true` mantiene el flujo idempotente. **No** se borra `/var/lib/docker` por si hubiera datos previos: si esto es una instalación limpia el directorio aún no existe; si se está reinstalando, se quiere conservar.

---

## 2. Añadir el repositorio oficial de Docker

### 2.1. Instalar dependencias

```bash
sudo apt update
sudo apt install -y ca-certificates curl gnupg
```

- `ca-certificates`: bundle de CAs raíz necesario para validar el TLS de `download.docker.com`.
- `curl`: para descargar la clave GPG.
- `gnupg`: para `gpg --dearmor` (convertir la clave ASCII en binario).

### 2.2. Importar la clave GPG de Docker

```bash
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg \
  | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
```

Decisiones:

- **`/etc/apt/keyrings/`** (no `/etc/apt/trusted.gpg.d/`): es el directorio recomendado desde Debian 12 para keyrings que pertenecen a un repo concreto, no globales. Coherente con la guía oficial de Docker.
- `gpg --dearmor`: convierte la clave ASCII (`-----BEGIN PGP PUBLIC KEY BLOCK-----`) al formato binario que `apt` espera leer rápido.
- `chmod a+r`: el fichero se crea con `600` por defecto bajo `sudo`; sin `a+r`, `apt update` (que se ejecuta como `_apt`) no podría leer la clave y fallaría con `NO_PUBKEY`.

### 2.3. Añadir el fichero de sources

```bash
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo "${VERSION_CODENAME}") stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
```

- `arch=$(dpkg --print-architecture)` → en Pi 5 con OS Lite 64-bit devuelve `arm64`; Docker publica binarios `arm64` desde hace años, no hace falta hacer nada especial.
- `signed-by=/etc/apt/keyrings/docker.gpg` → ata este repo a la clave del paso 2.2 y solo a esa: ningún otro repo puede inyectar paquetes firmados con esta key.
- `$(. /etc/os-release && echo "${VERSION_CODENAME}")` → en Bookworm devuelve `bookworm`. Si en el futuro se actualiza a Trixie/Forky, el valor cambia y conviene revisar la matriz de soporte de Docker.

### 2.4. Refrescar el índice de `apt`

```bash
sudo apt update
```

Salida esperada (líneas relevantes):

```
Get:5 https://download.docker.com/linux/debian bookworm InRelease ...
Get:6 https://download.docker.com/linux/debian bookworm/stable arm64 Packages ...
```

Si aparece `NO_PUBKEY` o `not signed`, revisar §2.2 (permisos de la keyring).

---

## 3. Instalar Docker Engine y plugins

```bash
sudo apt install -y \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin
```

| Paquete | Para qué sirve |
|---|---|
| `docker-ce` | El demonio (`dockerd`) y la unidad systemd. |
| `docker-ce-cli` | El CLI (`docker`) que habla con el demonio vía socket Unix. |
| `containerd.io` | El runtime de bajo nivel que ejecuta los contenedores; hace de capa entre `dockerd` y `runc`. |
| `docker-buildx-plugin` | Plugin de build multi-arch (`docker buildx`); raramente necesario en el homelab pero pesa poco y simplifica builds locales. |
| `docker-compose-plugin` | Provee `docker compose` (subcomando v2). **Reemplaza** al `docker-compose` clásico. |

> No se instala el paquete `docker-ce-rootless-extras` (modo rootless): añade complejidad de red, no permite usar `iptables` y rompe el modelo de bind mounts a `/mnt/hd2t/...` que usamos. La superficie de ataque adicional de Docker rooted en una Pi sin exposición a internet se considera aceptable.

---

## 4. Configurar `/etc/docker/daemon.json`

Antes de arrancar el demonio por primera vez en serio, se le da una configuración explícita.

### 4.1. Escribir el fichero

```bash
sudo install -d -o root -g root -m 755 /etc/docker
sudo tee /etc/docker/daemon.json >/dev/null <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "live-restore": true,
  "default-address-pools": [
    { "base": "172.20.0.0/16", "size": 24 }
  ]
}
EOF
sudo chmod 644 /etc/docker/daemon.json
```

### 4.2. Validación sintáctica

`dockerd` falla en silencio si el JSON está malformado (rechaza el `daemon.json` y arranca con valores por defecto, sin avisar de forma evidente). Validar antes de reiniciar:

```bash
sudo docker info >/dev/null   # primer arranque: no relevante todavía
python3 -c 'import json,sys; json.load(open("/etc/docker/daemon.json"))' \
  && echo "daemon.json: JSON válido"
```

### 4.3. Qué hace cada opción

- **`log-driver: json-file` + `max-size`/`max-file`**: rota los logs de cada contenedor a 3 ficheros de 10 MB. Sin esto, un contenedor "habladero" puede llenar la microSD en días. Compatible con `docker logs` y con Dozzle.
- **`live-restore: true`**: si el demonio se reinicia (por upgrade o por `systemctl restart docker`), los contenedores en marcha **no** se detienen. Imprescindible cuando `unattended-upgrades` aplique parches a `docker-ce` de madrugada.
- **`default-address-pools`**: las redes user-defined creadas por Compose (una por stack si así lo decide [`02-estructura-compose.md`](./02-estructura-compose.md)) se asignan desde `172.20.0.0/16`. Esto evita el problema típico de que Docker eligiera `172.17.0.0/16` o `172.18.0.0/16` y colisionara con una VPN corporativa o con la LAN si esta usase rangos `172.x`.

> Lo que **no** está en este `daemon.json` y se discute en otras fases:
> - `data-root` → §4.4 si se decide reubicar.
> - `userns-remap` → no se activa: rompe los bind mounts y los UID/GID que la [Fase 1](../01-sistema/04-estructura-directorios.md) ha pactado (`PUID=1000`, `PGID=1000`/`1100`).
> - `metrics-addr` → se activará cuando se despliegue Prometheus en [`../05-monitorizacion/01-prometheus.md`](../05-monitorizacion/01-prometheus.md).
> - `iptables: false` → **no** se desactiva: necesitamos que Docker gestione las reglas que publican puertos.

### 4.4. (Opcional) Reubicar `data-root` a `hd2t`

Solo si se prevé un volumen grande de imágenes (varias decenas de GB) o se quiere reducir la escritura sobre microSD. **No es necesario por defecto**.

```bash
# 1. Detener Docker.
sudo systemctl stop docker docker.socket

# 2. Crear el destino y mover lo existente preservando atributos.
sudo install -d -o root -g root -m 711 /mnt/hd2t/docker
sudo rsync -aHAX --numeric-ids /var/lib/docker/ /mnt/hd2t/docker/

# 3. Añadir "data-root" al daemon.json antes del último cierre } y reiniciar.
#    El JSON resultante debe tener: "data-root": "/mnt/hd2t/docker"
sudo systemctl start docker

# 4. Si todo va bien, archivar (no borrar) el directorio antiguo.
sudo mv /var/lib/docker /var/lib/docker.bak
```

> Implicaciones: `/mnt/hd2t/docker` debe estar **siempre montado al arranque** (la opción `nofail` en `fstab` puede arrancar sin él, dejando Docker sin imágenes). Por eso la decisión por defecto es **no reubicar**: la microSD siempre está disponible.

---

## 5. Habilitar y arrancar el servicio

La instalación de `docker-ce` ya enable+start ambos servicios. Forzarlo es idempotente y deja constancia explícita:

```bash
sudo systemctl enable --now containerd.service
sudo systemctl enable --now docker.service
```

> No hace falta tocar `docker.socket`: viene en estado `enabled` y se activa bajo demanda cuando algo abre `/var/run/docker.sock`.

### 5.1. Verificar que el demonio leyó `daemon.json`

```bash
sudo systemctl status docker --no-pager
sudo journalctl -u docker --since "5 min ago" --no-pager | tail -30
```

Buscar líneas como:

```
level=info msg="Loading containers: start."
level=info msg="Default bridge (docker0) is assigned with an IP address ..."
level=info msg="Daemon has completed initialization"
```

Si en `journalctl` aparece `unable to configure the Docker daemon with file /etc/docker/daemon.json`, el JSON está mal: revertir al snapshot del paso 4.1.

---

## 6. Post-install: grupo `docker`

```bash
sudo usermod -aG docker homelab
```

`-a` (append) **no** saca a `homelab` de los grupos a los que ya pertenece (`homelab`, `media`, `sudo`...).

Cerrar y reabrir la sesión SSH (los grupos efectivos no se actualizan en sesiones ya abiertas) y comprobar:

```bash
id homelab
docker version
```

`id homelab` debe listar `docker` en `groups=`. `docker version` debe imprimir tanto `Client` como `Server` sin errores de "permission denied while trying to connect to the Docker daemon socket".

> **Nota de seguridad**: pertenecer al grupo `docker` equivale a ser `root`, porque el demonio puede montar cualquier path del sistema dentro de un contenedor. Lo aceptamos porque `homelab` ya tiene `sudo` plano. Si en el futuro se añadieran usuarios humanos secundarios, **no** añadirlos al grupo `docker`: que usen `sudo docker` o desplieguen vía Portainer.

---

## 7. Verificación

### 7.1. `hello-world` (smoke test del runtime)

```bash
docker run --rm hello-world
```

Salida esperada (resumen):

```
Unable to find image 'hello-world:latest' locally
latest: Pulling from library/hello-world
...
Hello from Docker!
This message shows that your installation appears to be working correctly.
```

`--rm` borra el contenedor al terminar, manteniendo limpio `docker ps -a`.

### 7.2. Compose v2

```bash
docker compose version
```

Debe imprimir algo como `Docker Compose version v2.30.x` (o superior, según la fecha). **No usar** `docker-compose` (con guion): si está, es el binario v1 deprecado.

### 7.3. Buildx

```bash
docker buildx version
```

Confirma que el plugin de buildx está cargado (no se usará en operación normal del homelab, pero es la sanidad del paquete).

### 7.4. Configuración efectiva del demonio

```bash
docker info --format '{{json .}}' | python3 -m json.tool | grep -E '"LiveRestoreEnabled"|"LoggingDriver"|"DefaultAddressPools"'
```

Debe devolver:

```
"LoggingDriver": "json-file",
"LiveRestoreEnabled": true,
"DefaultAddressPools": [
    {
        "Base": "172.20.0.0/16",
        "Size": 24
    }
],
```

### 7.5. Comprobación de red (`docker0` y `nftables`)

```bash
ip -4 addr show docker0
sudo nft list table ip filter | grep -i docker | head
```

`docker0` debe tener una IP en `172.17.0.1/16` (el bridge por defecto, que **no** se ve afectado por `default-address-pools` → eso solo aplica a redes user-defined).

`nft list` debe mostrar las cadenas `DOCKER`, `DOCKER-ISOLATION-STAGE-1/2`, `DOCKER-USER`, lo que confirma que Docker ha registrado sus reglas. Si más adelante hace falta filtrar tráfico **a contenedores**, las reglas se ponen en la cadena `DOCKER-USER` (no en `ufw`).

### 7.6. Convivencia con `ufw`

`ufw` filtra el tráfico que **termina en el host**. El tráfico a contenedores que publican puertos con `-p` (o `ports:` en Compose) lo **bypasea** porque Docker inserta sus reglas en `PREROUTING`/`FORWARD` antes de que `ufw` lo vea. Esto es un comportamiento conocido y documentado por Docker. Implicaciones para este homelab:

- Mientras no haya contenedores con `ports:` publicados al exterior, `ufw` sigue siendo la verdad para SSH y para todo lo que hable directamente con el host.
- En cuanto se publique un puerto (Caddy en 80/443, Pi-hole en 53...), ese puerto será accesible desde **cualquier** interfaz que el bridge `docker0` o macvlan vea, **independientemente** de las reglas de `ufw`.
- La estrategia del homelab para mitigar esto:
  1. **Pi-hole en macvlan** ([`../03-red/01-macvlan.md`](../03-red/01-macvlan.md)) → su tráfico DNS no pasa por el bridge, sino por su propia IP en la LAN: filtrarlo es responsabilidad del switch/router.
  2. **Caddy publica solo en la IP del host** (no en `0.0.0.0`) → se documenta en [`../03-red/04-caddy.md`](../03-red/04-caddy.md) cómo bindar a `192.168.x.x:443` para que el listener no quede en interfaces inesperadas.
  3. **Resto de servicios sin `ports:`** y solo accesibles vía la red Compose interna o vía Caddy → es la regla por defecto que se establece en [`02-estructura-compose.md`](./02-estructura-compose.md).
- Cualquier auditoría posterior de puertos abiertos vivirá en [`../13-operaciones/04-red-y-puertos.md`](../13-operaciones/04-red-y-puertos.md).

### 7.7. Lista de Verificación

Antes de pasar a [`02-estructura-compose.md`](./02-estructura-compose.md):

- [ ] `apt-cache policy docker-ce` muestra como origen `https://download.docker.com/linux/debian bookworm/stable arm64 Packages`.
- [ ] `dpkg -l | grep -E 'docker-ce|docker-ce-cli|containerd.io|docker-buildx-plugin|docker-compose-plugin'` lista los 5 paquetes en estado `ii`.
- [ ] `systemctl is-enabled docker containerd` devuelve `enabled` para ambos.
- [ ] `systemctl is-active docker containerd` devuelve `active` para ambos.
- [ ] `docker version` muestra `Client` y `Server` con la misma versión mayor.
- [ ] `docker compose version` muestra `Docker Compose version v2.x`.
- [ ] `docker info --format '{{.LoggingDriver}}'` devuelve `json-file`.
- [ ] `docker info --format '{{.LiveRestoreEnabled}}'` devuelve `true`.
- [ ] `docker info --format '{{json .DefaultAddressPools}}'` lista `172.20.0.0/16` con `Size 24`.
- [ ] `docker run --rm hello-world` termina con `Hello from Docker!` y código de salida `0`.
- [ ] `id homelab` lista `docker` entre los grupos.
- [ ] **Test sin `sudo`**: `docker ps` (como `homelab`) devuelve la cabecera `CONTAINER ID ...` sin error.
- [ ] **Test de logs rotados**: `docker run --rm alpine sh -c 'for i in $(seq 1 10); do echo line $i; done'` y luego `docker info --format '{{.LoggingDriver}}'` confirma el driver activo (los ficheros se crean en `/var/lib/docker/containers/<cid>/`).
- [ ] **Test de address pool**: `docker network create probe && docker network inspect probe --format '{{(index .IPAM.Config 0).Subnet}}'` devuelve una subred dentro de `172.20.0.0/16`. Limpiar con `docker network rm probe`.
- [ ] `sudo ufw status verbose` sigue mostrando las reglas de SSH de la [Fase 1](../01-sistema/03-seguridad-base.md), no se han alterado.

---

## 8. Solución de Problemas

| Síntoma | Causa probable | Acción |
|---|---|---|
| `apt update` falla con `NO_PUBKEY` para `download.docker.com` | La keyring no es legible por `_apt` o no se importó. | `ls -l /etc/apt/keyrings/docker.gpg` (debe ser `-rw-r--r--`); reejecutar §2.2 con `chmod a+r`. |
| `apt install docker-ce` no encuentra el paquete | El fichero `sources.list.d/docker.list` apunta a un codename inexistente. | `cat /etc/apt/sources.list.d/docker.list` y comprobar que dice `bookworm`. |
| `docker run` falla con `permission denied while trying to connect to the Docker daemon socket` | La sesión actual no refleja la pertenencia al grupo `docker` aunque `id` la liste, **o** `homelab` no se añadió al grupo. | Cerrar y reabrir SSH; `id homelab \| grep docker`. Si `docker` no aparece, reejecutar `sudo usermod -aG docker homelab`. |
| `docker info` muestra `WARNING: bridge-nf-call-iptables is disabled` | Es informativo en kernels recientes y no afecta a `iptables` legacy/`nftables`. | Ignorar; en Bookworm con cgroups v2 es esperado. |
| `journalctl -u docker` repite `unable to configure the Docker daemon with file /etc/docker/daemon.json` | JSON malformado. | Validar con `python3 -m json.tool < /etc/docker/daemon.json`; reescribir desde §4.1. |
| `live-restore` no se aplica tras editar `daemon.json` | `live-restore` solo entra en vigor con `systemctl restart docker`. Antes del primer restart, su valor "previo" era `false`. | `sudo systemctl restart docker` una vez, y a partir de ahí los siguientes restarts respetan el flag. |
| Compose creado en el host queda con UID `0` (`root`) cuando se ejecutó como `homelab` | El editor (`sudo nano`) creó el fichero como `root`. | Editar como `homelab` (`nano docker-compose.yml`) **sin** `sudo`. La estrategia general se define en [`02-estructura-compose.md`](./02-estructura-compose.md). |
| `docker network create` devuelve `Pool overlaps with other one on this address space` | Otra red ya ocupa `172.20.0.0/16`. | `docker network ls && docker network inspect <id>` para localizarla; si es transitoria, `docker network rm`. Si es por una VPN del host, ajustar `default-address-pools` a `172.21.0.0/16`. |
| `/var/lib/docker` crece sin control y la microSD se llena | Imágenes huérfanas y capas dangling. | `docker system df` para auditar; `docker system prune -af --volumes` (con cuidado: borra imágenes no usadas y volúmenes no referenciados). Programar limpieza periódica en [`../13-operaciones/01-mantenimiento-periodico.md`](../13-operaciones/01-mantenimiento-periodico.md). |
| Tras `unattended-upgrades` con upgrade de `docker-ce`, los contenedores siguen vivos pero `docker ps` falla unos segundos | Comportamiento esperado de `live-restore` durante el reinicio del demonio. | Esperar 5–10 s; reintentar. Si persiste >1 min, `journalctl -u docker --since "10 min ago"`. |
| `docker run hello-world` cuelga descargando | DNS roto en el host (Pi-hole aún no desplegado). | `getent hosts download.docker.com`; si falla, comprobar `/etc/resolv.conf` (en este punto del plan debería apuntar al DNS del router, no a Pi-hole, que se despliega en [Fase 3](../03-red/02-pihole.md)). |

---

## Referencias

- [Docker — Install Docker Engine on Debian](https://docs.docker.com/engine/install/debian/)
- [Docker — Linux post-installation steps](https://docs.docker.com/engine/install/linux-postinstall/)
- [Docker — Configure the daemon (`daemon.json`)](https://docs.docker.com/reference/cli/dockerd/#daemon-configuration-file)
- [Docker — Logging drivers (`json-file`, `max-size`, `max-file`)](https://docs.docker.com/config/containers/logging/json-file/)
- [Docker — `live-restore`](https://docs.docker.com/config/containers/live-restore/)
- [Docker — Default address pools](https://docs.docker.com/reference/cli/dockerd/#default-address-pools)
- [Docker — Compose v2 (plugin)](https://docs.docker.com/compose/install/linux/)
- [Docker — Packet filtering and firewalls (interacción con `ufw`)](https://docs.docker.com/engine/network/packet-filtering-firewalls/)
- [Debian Wiki — Bookworm release notes (cgroups v2)](https://www.debian.org/releases/bookworm/release-notes/)
- [Raspberry Pi Documentation — OS overview (Bookworm)](https://www.raspberrypi.com/documentation/computers/os.html)
