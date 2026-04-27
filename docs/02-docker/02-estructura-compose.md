# Estructura del Repositorio Compose

## Descripción

Diseño y formalización del **repositorio Compose** del homelab: cómo se organiza `~/homelab/`, cuántos `docker-compose.yml` hay y por qué (un compose por **dominio funcional**, ni monolito ni uno por servicio), cómo se conectan los stacks entre sí (la red Docker externa `homelab`), qué convenciones de _naming_ siguen contenedores y volúmenes, cómo se reparten las variables de entorno entre el `.env` global y el `.env` de cada stack, y qué se _commitea_ a git y qué se queda fuera.

Tras esta fase, el repositorio está creado, inicializado como git, con su `.gitignore`, `.env.example`, _Makefile_ de operación y la red `homelab` ya disponible. Las fases siguientes (`docs/02-docker/03-portainer.md`, `docs/03-red/`, `docs/04-seguridad/`, …) se limitarán a añadir un subdirectorio por stack con su `docker-compose.yml` y su `.env`, sin tener que decidir caso a caso dónde colocar nada.

> **Alcance**: este documento sólo establece **estructura, convenciones y red compartida**. **No** despliega ningún servicio (Portainer y Watchtower llegan en `docs/02-docker/03-portainer.md` y `04-watchtower.md`), **no** crea la red macvlan de Pi-hole/Unbound (`docs/03-red/01-macvlan.md`), **no** define el `Caddyfile` (`docs/03-red/04-caddy.md`) ni asigna IPs concretas. El `~/homelab/` queda preparado, vacío de stacks, esperando los `docker-compose.yml` de las fases siguientes.

> **Recordatorio de red**: el homelab sólo escucha en LAN y Tailscale. Las redes Docker que se definen aquí son **internas al host**: no se publican puertos al exterior, las únicas exposiciones reales serán las que abran Caddy (en la propia IP de la Pi) y Pi-hole/Unbound (en su IP macvlan).

---

## Requisitos previos

- `docs/01-sistema/04-estructura-directorios.md` completado: `~/homelab/` ya existe con permisos `0700`, las variables base (`PUID`, `PGID`, `MEDIA_GID`, `TZ`) están en `~/homelab/.env`, y el árbol `/mnt/hd2t/services/` está creado con sus esqueletos.
- `docs/02-docker/01-instalacion-docker.md` completado: `docker` y `docker compose` operativos sin `sudo` para el usuario `homelab`, `data-root` apuntando a `/mnt/hd2t/system/docker`, `live-restore` activo, `default-address-pools` fijado en `172.20.0.0/16`.
- `git` instalado (viene en Raspberry Pi OS Lite por defecto). Confirmar:

  ```bash
  git --version
  ```

- Identidad git mínima del usuario `homelab`, que se usará para los _commits_ locales del repositorio. Si no está configurada:

  ```bash
  git config --global user.name  "homelab"
  git config --global user.email "homelab@$(hostname)"
  git config --global init.defaultBranch main
  ```

---

## Estrategia: un compose por dominio funcional

Las dos opciones extremas son ambas malas en este homelab:

- **Monolito** (un único `docker-compose.yml` para los ~30 servicios): comandos triviales (`docker compose up -d` y listo) pero cualquier cambio puntual implica recargar y reevaluar el grafo entero, los conflictos de merge en git son constantes, y no se puede parar un dominio (todo el _stack_ multimedia, por ejemplo) sin afectar al resto.
- **Un compose por servicio** (~30 ficheros, uno por contenedor): aislamiento total pero pérdida absoluta de las relaciones naturales (Nextcloud y su MariaDB, Home Assistant y su Mosquitto, Sonarr/Radarr/Prowlarr/Transmission). Cada relación pasa a depender de la red externa, los _depends_on_ desaparecen y los arranques en frío se vuelven frágiles.

Punto medio: **un `docker-compose.yml` por dominio funcional**, donde "dominio" se corresponde con la **fase del plan** (ver `plans/PLAN.md`). Cada stack agrupa los servicios que comparten propósito, ciclo de vida y dependencias internas:

| Stack          | Subdirectorio          | Servicios                                                 | Doc de fase             |
|----------------|------------------------|-----------------------------------------------------------|-------------------------|
| `infra`        | `~/homelab/infra/`     | Portainer, Watchtower, Dozzle                             | `docs/02-docker/`       |
| `red`          | `~/homelab/red/`       | Pi-hole, Unbound, Caddy, Tailscale (si va contenerizado)  | `docs/03-red/`          |
| `seguridad`    | `~/homelab/seguridad/` | Authelia, Fail2ban (si se centraliza en contenedor)       | `docs/04-seguridad/`    |
| `monitor`      | `~/homelab/monitor/`   | Prometheus, Grafana, Node Exporter, cAdvisor, Uptime Kuma | `docs/05-monitorizacion/` |
| `almacen`      | `~/homelab/almacen/`   | Nextcloud (+ DB), Samba, Syncthing, MinIO                 | `docs/06-almacenamiento/` |
| `domotica`     | `~/homelab/domotica/`  | Home Assistant, Mosquitto, Zigbee2MQTT, Node-RED          | `docs/08-domotica/`     |
| `multimedia`   | `~/homelab/multimedia/`| Jellyfin, Navidrome, Audiobookshelf, Calibre-Web, Stash   | `docs/09-multimedia/`   |
| `descargas`    | `~/homelab/descargas/` | Transmission, Prowlarr, Sonarr, Radarr                    | `docs/10-descargas/`    |
| `productividad`| `~/homelab/productividad/` | Vaultwarden, Bookstack, Linkding, Paperless, Mealie, Stirling-PDF, FreshRSS | `docs/11-productividad/` |
| `dashboards`   | `~/homelab/dashboards/`| Homepage, Homarr                                          | `docs/12-dashboards/`   |

Diez stacks, perfectamente paralelos a las fases del plan. Características que se obtienen "gratis" al organizarlo así:

- `cd ~/homelab/multimedia && docker compose pull && docker compose up -d` actualiza **toda** la rama multimedia sin tocar el resto.
- Un `docker compose down` en `multimedia/` no afecta a `red/`, `seguridad/` ni a la BD de Nextcloud.
- Los _depends_on_ internos del stack (Nextcloud → MariaDB; Home Assistant → Mosquitto; Sonarr → Transmission) se resuelven dentro del propio compose, donde encajan, en lugar de a través de redes Docker externas.
- Los conflictos de merge en git son improbables: cada fase toca sólo su propio fichero.
- `git diff main -- ~/homelab/multimedia/` muestra de un vistazo los cambios de la rama multimedia desde la última versión estable.

> **Excepción asumida — Pi-hole y Unbound** comparten _stack_ (`red/`) pero corren en una red distinta (macvlan, ver `docs/03-red/01-macvlan.md`). El compose se mantiene en el mismo fichero por afinidad de propósito; la red distinta se declara dentro del propio compose como un `network` adicional al `homelab` compartido.

---

## La red Docker compartida `homelab`

Los stacks necesitan **comunicarse entre sí** en algunos puntos:

- Caddy (stack `red`) tiene que llegar a Jellyfin (stack `multimedia`), Nextcloud (stack `almacen`), Authelia (stack `seguridad`)…
- Authelia (stack `seguridad`) tiene que llegar a Caddy (stack `red`) por su _socket_ de _forward_auth_.
- Prometheus (stack `monitor`) tiene que _scrapeear_ métricas de cAdvisor, Node Exporter y de los `*-exporter` que cada stack publique.
- Uptime Kuma (stack `monitor`) hace HTTP _check_ contra los _endpoints_ internos.

Para que esto funcione sin abrir puertos al host, se usa una **red Docker bridge externa**, declarada **una sola vez fuera de los compose** y referenciada desde cada stack que la necesite:

```bash
docker network create \
    --driver bridge \
    --subnet 172.20.10.0/24 \
    --gateway 172.20.10.1 \
    --opt com.docker.network.bridge.name=br-homelab \
    homelab
```

Detalles relevantes:

- **Driver `bridge`**: el clásico. Suficiente para tráfico unidireccional `caddy` → `<servicio>` dentro del host. No usamos `overlay` (eso es para Swarm/multi-host).
- **Subnet `172.20.10.0/24`**: dentro del rango `172.20.0.0/16` reservado en `daemon.json` (`docs/02-docker/01-instalacion-docker.md`, paso 3.3) para no chocar con la LAN ni con CGNAT de Tailscale. El bloque `/24` da 254 direcciones, sobrado para los ~30 contenedores del homelab.
- **`com.docker.network.bridge.name=br-homelab`**: nombra la interfaz del _kernel_ con un nombre legible (`br-homelab`) en lugar del autogenerado tipo `br-3f4a8b2…`. Aparece así en `ip a`, `nft list ruleset`, `tcpdump`, lo que facilita los diagnósticos.
- **Etiqueta `homelab` (sin prefijo)**: nombre corto y memorable. Compose suele anteponer el nombre del proyecto a las redes que él crea (ej. `multimedia_default`); al ser **externa** y declarada manualmente, conserva el nombre exacto.

> **Resolución DNS dentro de la red**: Docker provee un _DNS embedded_ por defecto (`127.0.0.11` dentro de cada contenedor). Cualquier servicio en la red `homelab` puede llamar a otro por su `container_name` o por el alias que se le asigne. Esto evita tener que conocer IPs internas.

### Cómo la usa cada stack

En cada `docker-compose.yml`, los servicios que necesiten ser alcanzables desde otros stacks se enganchan a `homelab` en su sección `networks:`. Los servicios **internos** del stack (la BD de Nextcloud, por ejemplo) se quedan en una red privada del propio stack, **sin** acceso a `homelab`:

```yaml
# Plantilla — extracto del compose de un stack
services:
  nextcloud:
    image: nextcloud:31-apache
    networks:
      - homelab           # alcanzable desde Caddy (stack red)
      - nextcloud-internal  # llega a su BD
  nextcloud-db:
    image: mariadb:11
    networks:
      - nextcloud-internal  # NO en homelab — la BD no se expone

networks:
  homelab:
    external: true        # creada fuera de Compose, aquí sólo se referencia
  nextcloud-internal:
    driver: bridge        # red privada de este stack, Compose la crea/destruye
```

Esta separación garantiza que **sólo Caddy** llegue al puerto HTTP de Nextcloud, y que la BD de Nextcloud no esté en el mismo segmento donde está Sonarr/Radarr o Vaultwarden. Es el patrón mínimo de aislamiento por defecto.

> Las imágenes oficiales (`nextcloud`, `mariadb`, `postgres`…) **resuelven** otros contenedores por DNS desde dentro de su red. No hay que poner IPs estáticas en `.env` ni en el compose: `nextcloud` conecta a `nextcloud-db:3306` y Docker se encarga.

---

## Estructura final de `~/homelab/`

```
~/homelab/
├── .env                           # variables globales (PUID, PGID, TZ, MEDIA_GID, …) — NO en git
├── .env.example                   # plantilla versionada con los nombres de las variables
├── .gitignore
├── README.md                      # mapa del repositorio para humanos
├── Makefile                       # atajos: make up, make pull, make logs ...
├── docker-compose.shared.yml      # red 'homelab' como recordatorio (no aplica nada por sí sola)
├── infra/
│   ├── docker-compose.yml
│   ├── .env
│   └── .env.example
├── red/
│   ├── docker-compose.yml
│   ├── Caddyfile                  # configuración de Caddy versionable
│   ├── .env
│   └── .env.example
├── seguridad/
│   └── ...
├── monitor/
│   └── ...
├── almacen/
│   └── ...
├── domotica/
│   └── ...
├── multimedia/
│   └── ...
├── descargas/
│   └── ...
├── productividad/
│   └── ...
└── dashboards/
    └── ...
```

Cada subdirectorio de stack tiene exactamente:

- **`docker-compose.yml`** — versionado, sin secretos.
- **`.env`** — secretos del stack (contraseñas DB, _tokens_ API…). `0600`, **fuera de git**.
- **`.env.example`** — plantilla con los nombres de las variables del `.env`, sin valores reales. **En git**.
- Configuración estática del stack que merezca versionarse (`Caddyfile`, `prometheus.yml`, `mosquitto.conf`, …) directamente en el subdirectorio. **En git**.

> **No** se commitean ficheros de datos en runtime, _logs_ ni nada que viva en `/mnt/hd2t/services/`. Esa partición es _runtime_; el repositorio es **declarativo**.

---

## Variables de entorno: `.env` global vs `.env` por stack

Compose busca el `.env` en el **mismo directorio** del `docker-compose.yml` que está procesando. Esto plantea cómo manejar variables globales que necesitan **todos** los stacks (`PUID`, `PGID`, `TZ`, `MEDIA_GID`).

Política adoptada:

- **`~/homelab/.env`** — sólo se usa explícitamente con `--env-file ../.env` o cargándolo a mano. **No** lo carga Compose por sí solo cuando se ejecuta desde un subdirectorio.
- **`~/homelab/<stack>/.env`** — se carga automáticamente al hacer `docker compose up -d` desde ese directorio. Aquí van los secretos del stack y las variables específicas.
- **Variables globales** (`PUID`, `PGID`, `TZ`, `MEDIA_GID`) — se **duplican** en cada `.env` de stack importando el global. La duplicación se hace una sola vez con un script (`bin/render-env.sh`) que concatena el global con las plantillas, o con la directiva `--env-file`:

  ```bash
  cd ~/homelab/multimedia
  docker compose --env-file ../.env --env-file .env up -d
  ```

  El _Makefile_ del repositorio (ver más abajo) abstrae esto para no tener que recordarlo.

### `.env` global (`~/homelab/.env`)

Ya existe parcialmente desde `docs/01-sistema/04-estructura-directorios.md`. Se completa aquí con los valores genéricos a todo el homelab:

```bash
# ~/homelab/.env  — modo 0600
# Identidad del usuario que corre los servicios LinuxServer.io
PUID=1000
PGID=1000
MEDIA_GID=981          # GID real de homelab-media (getent group homelab-media | cut -d: -f3)

# Zona horaria, heredada de docs/01-sistema/02-configuracion-inicial.md
TZ=Europe/Madrid

# Dominio interno del homelab, usado por Caddy y Pi-hole
HOMELAB_DOMAIN=lan

# Hostname Tailscale del nodo (sin .ts.net)
TAILSCALE_HOSTNAME=pi
```

Permisos:

```bash
chmod 0600 ~/homelab/.env
```

> El valor real de `MEDIA_GID` se obtiene con `getent group homelab-media | cut -d: -f3` y puede no ser 981. Ajustar al valor concreto del sistema antes de seguir.

### `.env.example` global (`~/homelab/.env.example`)

```bash
# Plantilla del .env global. Copiar a .env y rellenar.
PUID=
PGID=
MEDIA_GID=
TZ=Europe/Madrid
HOMELAB_DOMAIN=lan
TAILSCALE_HOSTNAME=
```

`.env.example` **sí** se commitea: documenta qué hay que rellenar para reproducir el homelab.

---

## Convenciones de _naming_ y formato

Las siguientes convenciones son **vinculantes** en cualquier `docker-compose.yml` que se añada en las fases siguientes. Divergencias deben justificarse en el doc de la fase.

### Servicios y contenedores

- **Nombre del servicio en compose**: minúsculas, palabras separadas por `-`. Coincide con el nombre del binario o la imagen oficial. Ej.: `jellyfin`, `home-assistant`, `nextcloud-db`.
- **`container_name` explícito** sólo cuando hace falta para integraciones externas (Borgmatic _hooks_, _scrapers_ Prometheus que apunten a un nombre fijo). En general se omite y se deja que Compose construya `<stack>-<servicio>-<n>` automáticamente, lo que evita choques al re-desplegar.
- **`hostname`** se omite también por defecto: Docker pone el _short id_ del contenedor, suficiente para los _logs_.

### Imágenes y _tags_

- **Tag mayor o LTS, nunca `latest`**: `nextcloud:31-apache`, `mariadb:11`, `jellyfin/jellyfin:10.10`. `latest` rompe rebuilds en cualquier momento sin aviso.
- **Imágenes oficiales** preferidas a forks comunitarios. Excepciones:
  - Familia LinuxServer.io (`lscr.io/linuxserver/...`) cuando ofrecen mejor soporte ARM o `PUID`/`PGID`.
  - Imágenes de la propia Cognition/proyecto (raro en este homelab).
- **Pinning a digest** (`image: nextcloud@sha256:...`) sólo para servicios críticos cuyo cambio de _tag_ podría romper datos (BD principal). Por defecto, _tag_ legible.
- **Watchtower** (`docs/02-docker/04-watchtower.md`) actualizará automáticamente sólo aquellos contenedores marcados con la etiqueta `com.centurylinklabs.watchtower.enable=true`. Por defecto se deja **en blanco** (no se actualiza solo) para imágenes con BD; en blanco para todo lo demás durante el periodo de _bootstrap_, y se activa servicio a servicio cuando se confirma que la imagen es estable.

### Restart policy

Política unificada:

```yaml
restart: unless-stopped
```

- **`unless-stopped`** y **no** `always`: si paro el servicio manualmente (`docker compose stop nextcloud`), no quiero que vuelva al reiniciar la Pi.
- **No** se usa `on-failure[:N]` para servicios de larga vida: salen a un _liveness_ silencioso y dejan al servicio caído sin alerta.

### Volúmenes

Bind mounts (no _named volumes_, ver `docs/01-sistema/04-estructura-directorios.md` § Convenciones a respetar):

```yaml
volumes:
  - /mnt/hd2t/services/jellyfin/config:/config
  - /mnt/hd2t/services/jellyfin/cache:/cache
  - /mnt/hd2t/services/shared/media:/media:ro
```

- **Rutas absolutas siempre**, nunca `./data` o `${HOME}/...`. Esto evita que `docker compose up -d` desde un directorio incorrecto cree volúmenes en sitios inesperados.
- **`:ro`** explícito siempre que el contenedor sólo necesite lectura. La biblioteca multimedia compartida (`services/shared/media`) **se monta `:ro` en Jellyfin** (sólo lee) y **`rw` en Sonarr/Radarr** (mueven y renombran ficheros).

### Variables de entorno

```yaml
environment:
  PUID: ${PUID}
  PGID: ${PGID}
  TZ: ${TZ}
  WEBUI_PORT: 8112
```

- Las heredadas del `.env` se referencian con `${VAR}`. **No** se ponen valores literales si la variable existe en el `.env`: una sola fuente de verdad.
- Variables _booleanas_: cadenas `"true"`/`"false"` entre comillas (algunos parsers son sensibles).

### Etiquetas (`labels`)

Tres etiquetas útiles en este homelab:

```yaml
labels:
  com.centurylinklabs.watchtower.enable: "false"   # opt-in a Watchtower
  homelab.backup: "true"                            # marca para hooks de Borgmatic
  homelab.stack: "multimedia"                       # mismo nombre que el subdirectorio
```

`homelab.backup` y `homelab.stack` son **convención propia** (sin efecto técnico per se). Borgmatic (`docs/07-backups/02-borgmatic.md`) las consultará para construir la lista de volúmenes a respaldar; los _dashboards_ Homepage/Homarr (`docs/12-dashboards/`) las usan para agrupar.

### Recursos

```yaml
mem_limit: 2g       # límite duro
cpus: "1.5"         # 1,5 cores
```

Sólo se aplican **cuando hace falta**: Jellyfin transcodificando, Nextcloud bajo carga, Home Assistant tras importar muchas integraciones. La política por defecto (sin límite) ya es suficiente en una Pi 5 con 8 GB; los límites se añaden cuando el servicio empieza a competir con otros (`docs/13-operaciones/03-rendimiento-pi5.md`).

### `healthcheck`

Lo más útil para detectar servicios "vivos pero rotos":

```yaml
healthcheck:
  test: ["CMD", "curl", "-fsS", "http://localhost:8096/health"]
  interval: 30s
  timeout: 5s
  retries: 3
  start_period: 30s
```

Cada doc de fase añade el `healthcheck` adecuado a su servicio (HTTP _ping_, conexión a BD, _query_ de salud). Cuando exista, los `depends_on` con `condition: service_healthy` evitan arranques racing.

---

## Versionado en git

### Inicialización

```bash
cd ~/homelab
git init
git branch -M main
```

### `.gitignore`

```bash
cat > ~/homelab/.gitignore <<'EOF'
# Secretos: nunca a git
.env
**/.env
!.env.example
!**/.env.example

# Datos de runtime — no deberían existir en este repo, pero por si acaso
data/
volumes/
*.db
*.sqlite
*.sqlite3

# Logs y artefactos de Compose
docker-compose.override.yml
.compose-cache/

# Editor / SO
.DS_Store
.idea/
.vscode/
*.swp
EOF
```

> La doble regla `**/.env` y `!**/.env.example` es necesaria porque el patrón general ignora todos los `.env` recursivamente, y el `!` reactiva los ejemplos.

### Primer _commit_

Sólo se _commitean_ los esqueletos: `.env.example`, `.gitignore`, `README.md`, `Makefile`. Los `docker-compose.yml` se irán añadiendo a medida que cada fase los redacte.

```bash
cd ~/homelab
git add .gitignore .env.example README.md Makefile
git commit -m "chore: bootstrap del repositorio Compose (estructura y convenciones)"
```

> Este repositorio se mantiene **local en la Pi** por defecto. Si se quiere espejarlo en GitHub/Gitea, hacerlo en un repo **privado**: aunque los secretos están en `.gitignore`, la topología completa del homelab también es información sensible.

---

## Plantilla mínima de `docker-compose.yml`

Toda fase posterior parte de esta plantilla y la rellena. Los comentarios marcan los puntos a editar.

```yaml
# ~/homelab/<stack>/docker-compose.yml
# Convenciones: docs/02-docker/02-estructura-compose.md

services:
  ejemplo:
    image: imagen/oficial:tag-mayor
    restart: unless-stopped
    environment:
      PUID: ${PUID}
      PGID: ${PGID}
      TZ: ${TZ}
    volumes:
      - /mnt/hd2t/services/ejemplo/config:/config
    networks:
      - homelab           # acceso desde Caddy y otros stacks
      - ejemplo-internal  # red privada del stack si tiene dependencias internas
    labels:
      homelab.stack: "<nombre-del-stack>"
      homelab.backup: "true"
      com.centurylinklabs.watchtower.enable: "false"
    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://localhost:8080/health"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s

networks:
  homelab:
    external: true
  ejemplo-internal:
    driver: bridge
```

---

## Workflow operativo — `Makefile`

Para no tener que recordar la combinación de `--env-file` y los comandos repetitivos, se centraliza el _workflow_ en un `Makefile` en la raíz del repositorio. Crearlo ahora aunque aún no haya stacks:

```makefile
# ~/homelab/Makefile
# Uso: make <target> STACK=<nombre>
# Ej:  make up STACK=multimedia
#      make logs STACK=red SERVICE=caddy

STACK   ?=
SERVICE ?=

DC = docker compose --env-file $(CURDIR)/.env --env-file $(STACK)/.env -f $(STACK)/docker-compose.yml

# Verifica que se pasó STACK
check-stack:
	@if [ -z "$(STACK)" ]; then echo "ERROR: pasa STACK=<nombre>"; exit 1; fi
	@if [ ! -f "$(STACK)/docker-compose.yml" ]; then echo "ERROR: $(STACK)/docker-compose.yml no existe"; exit 1; fi

up: check-stack
	$(DC) up -d

down: check-stack
	$(DC) down

restart: check-stack
	$(DC) restart $(SERVICE)

pull: check-stack
	$(DC) pull

logs: check-stack
	$(DC) logs -f $(SERVICE)

ps: check-stack
	$(DC) ps

config: check-stack
	$(DC) config

# Aplica un pull + up -d sólo si hay imagen nueva
update: check-stack
	$(DC) pull
	$(DC) up -d

# Atajos globales (todos los stacks)
STACKS = $(shell find . -mindepth 2 -maxdepth 2 -name docker-compose.yml -exec dirname {} \; | sed 's|^\./||')

up-all:
	@for s in $(STACKS); do echo ">> up $$s"; $(MAKE) up STACK=$$s; done

ps-all:
	@for s in $(STACKS); do echo ">> ps $$s"; $(MAKE) ps STACK=$$s; echo; done

.PHONY: check-stack up down restart pull logs ps config update up-all ps-all
```

Comprobar que `make` está disponible (viene en Pi OS Lite vía `build-essential`, si no se instala con `sudo apt install -y make`).

> El _Makefile_ es deliberadamente simple: no oculta `docker compose`, sólo automatiza el doble `--env-file`. Se sigue pudiendo (y debiendo) usar `docker compose` directamente cuando se quiera.

---

## Crear la red `homelab` ahora

Tiene que existir antes de que cualquier stack la referencie como `external: true`. Se crea aquí:

```bash
docker network create \
    --driver bridge \
    --subnet 172.20.10.0/24 \
    --gateway 172.20.10.1 \
    --opt com.docker.network.bridge.name=br-homelab \
    homelab
```

Comprobar:

```bash
docker network inspect homelab --format '{{.IPAM.Config}} {{.Driver}} {{.Options}}'
ip -br addr show br-homelab
```

La interfaz `br-homelab` debe aparecer con la IP `.1/24` del rango. Si no aparece, revisar si Docker la crea sólo bajo demanda (al primer contenedor): en ese caso, el `inspect` confirma la subnet aunque la interfaz esté inactiva.

---

## Verificación final

Antes de pasar a `docs/02-docker/03-portainer.md`, comprobar:

- [ ] `ls -la ~/homelab` lista `.gitignore`, `.env`, `.env.example`, `README.md`, `Makefile`. `.env` con permisos `0600`, el resto `0644`.
- [ ] `cat ~/homelab/.env` contiene `PUID`, `PGID`, `MEDIA_GID`, `TZ`, `HOMELAB_DOMAIN`, `TAILSCALE_HOSTNAME` con valores reales.
- [ ] `git -C ~/homelab status` está limpio salvo por los subdirectorios futuros (que aún no existen).
- [ ] `git -C ~/homelab log --oneline` muestra al menos un _commit_ inicial.
- [ ] `git -C ~/homelab check-ignore -v .env` confirma que `.env` está ignorado por la regla `.gitignore`.
- [ ] `docker network ls --filter name=homelab --format '{{.Name}} {{.Driver}} {{.Scope}}'` lista exactamente `homelab bridge local`.
- [ ] `docker network inspect homelab --format '{{(index .IPAM.Config 0).Subnet}}'` devuelve `172.20.10.0/24`.
- [ ] Crear un contenedor _ad hoc_ engancharlo a la red y borrarlo:

  ```bash
  docker run --rm --network homelab alpine ip -4 addr show eth0 | grep 'inet '
  ```

  Debe imprimir una IP del rango `172.20.10.0/24`.

- [ ] `make` (sin _target_) en `~/homelab` no falla con error de sintaxis (saca el _target_ por defecto que sea `help` o el primero declarado, pero no _Makefile_ broken).
- [ ] `make up STACK=infra` falla con `infra/docker-compose.yml no existe` (esperado: ningún stack desplegado todavía).

---

## Troubleshooting

### `docker compose up` falla con `network homelab declared as external, but could not be found`

La red `homelab` no se ha creado (o se borró). Recrearla con el comando del paso anterior. **No** dejar que Compose la cree implícitamente: si lo hace, la subnet y el _bridge name_ no se controlan, y el siguiente compose que la pida fallará por inconsistencia.

### `docker compose up` falla con `pool overlaps with other one on this address space`

Otra red Docker ya ocupa `172.20.10.0/24`. Causas posibles:

1. Una red _bridge_ creada por defecto por algún `compose up` previo, antes de fijar `default-address-pools` en `daemon.json`. Listar y borrar las que sobren:

   ```bash
   docker network ls
   docker network prune
   ```

2. La LAN doméstica está usando ese rango (poco común). Cambiar `--subnet` a `172.20.20.0/24` y actualizar este documento.

### Los contenedores no se ven entre sí aunque están en `homelab`

Lo más probable es que **un servicio** se haya enganchado a una red privada del stack y **otro** sólo a `homelab`, sin punto de contacto. Comprobar:

```bash
docker inspect <contenedor> --format '{{json .NetworkSettings.Networks}}' | jq
```

El servicio que tiene que ser alcanzable desde varios stacks (Caddy, Authelia, Mosquitto en su caso) **debe** estar en `homelab`. Los servicios que sólo se hablan dentro del propio stack pueden quedarse en la red privada del stack.

### `docker compose --env-file ../.env --env-file .env up` no sustituye una variable

El orden importa: el último `--env-file` **gana** en caso de colisión. Si una variable está en ambos ficheros y se quiere que dome el global, invertir el orden. En la práctica:

- Variables específicas del stack → sólo en `<stack>/.env`.
- Variables globales (PUID, PGID, TZ…) → sólo en `~/homelab/.env`.
- **No** repetir la misma variable en ambos ficheros: confunde y depende del orden.

### Un `docker compose pull` desde el _Makefile_ no actualiza una imagen pinneada por digest

Compose con _digest_ (`image: foo@sha256:...`) **no resuelve _tags_ flotantes**: descarga exactamente ese digest y para. Para "actualizar", hay que cambiar el digest en el `docker-compose.yml`, _commitearlo_ y hacer `make update`. Es el comportamiento querido para servicios críticos: ningún cambio ocurre sin un _commit_ explícito.

### `git status` muestra `.env` como modificado tras un `make up`

Algún script o el propio Compose lo ha tocado. Confirmar con `git diff ~/homelab/.env`. Si los cambios son los correctos (nuevo _token_ generado por un servicio que escribió en `.env` por error, por ejemplo), **no** _commitearlos_: `.env` no debería contener variables generadas por contenedores. Mover esa salida a un fichero específico bajo `services/<servicio>/` y revertir el `.env`:

```bash
git -C ~/homelab checkout -- .env
chmod 0600 ~/homelab/.env
```

---

## Referencias

- Docker Compose — Especificación: <https://docs.docker.com/compose/compose-file/>
- Docker Compose — Variables de entorno: <https://docs.docker.com/compose/environment-variables/set-environment-variables/>
- Docker Compose — Múltiples `--env-file`: <https://docs.docker.com/compose/environment-variables/envvars-precedence/>
- Docker — Redes _bridge_: <https://docs.docker.com/network/bridge/>
- Docker — Redes externas en Compose: <https://docs.docker.com/compose/compose-file/06-networks/#external>
- Docker — DNS embebido en redes _user-defined_: <https://docs.docker.com/network/network-tutorial-standalone/>
- Watchtower — Etiquetas y _opt-in_: <https://containrrr.dev/watchtower/container-selection/>
- LinuxServer.io — `PUID`/`PGID` y volúmenes: <https://docs.linuxserver.io/general/understanding-puid-and-pgid>
- GNU Make — Manual: <https://www.gnu.org/software/make/manual/make.html>
- Pro Git — `.gitignore` patterns: <https://git-scm.com/docs/gitignore>
