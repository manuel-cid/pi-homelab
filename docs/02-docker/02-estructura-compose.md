# Estructura y Convenciones de Docker Compose

## Descripción

Tras `01-instalacion-docker.md` la Raspberry Pi 5 tiene Docker Engine + Compose v2 instalados, con `data-root` en `/mnt/hd2t/docker`, logs `json-file` rotados y el usuario `homelab` en el grupo `docker`. Lo que falta antes de desplegar el primer servicio real (Portainer en `03-portainer.md`) es **fijar las reglas del juego** para todos los `docker-compose.yml` del homelab.

Este documento decide y documenta, **una sola vez**, cómo se organizan los stacks del repo:

1. **Monolito vs por stack**: un único `docker-compose.yml` gigante para los ~30 servicios del catálogo, o un `docker-compose.yml` independiente por servicio bajo `stacks/`. Se compara y se elige.
2. **Topología de redes Docker**: una red `homelab` compartida (atributo `external: true`), segmentación de servicios públicos vs privados, y cómo se expone (o no) cada contenedor. Se aterriza el principio que dejó abierto el documento de instalación: "la exposición se gestiona en compose".
3. **Convenciones de nombres**: claves de servicio, `container_name`, redes y bind mounts. Sin estas convenciones, Compose genera nombres impredecibles (`stacks-pihole-1`) y los logs, healthchecks y referencias cruzadas se vuelven inconsistentes.
4. **Variables de entorno**: el `.env` global del repo (`TZ`, `PUID`, `PGID`, `DOMAIN_LAN`…), los `.env` por stack (credenciales, hostnames concretos) y la regla de oro: **nada de secretos en claro al git**.
5. **Plantilla canónica de stack**: un `docker-compose.yml` mínimo y completo que sirve de molde para todos los servicios de las fases siguientes. Cada documento de servicio rellenará huecos sin reabrir estas decisiones.

Cuando este documento se haya aplicado, `tree /home/homelab/homelab/stacks/` muestra la jerarquía vacía pero coherente, `docker network ls` lista la red `homelab` y `docker compose -f stacks/<cualquiera>/docker-compose.yml config` valida sin errores. A partir de ahí, cada stack futuro **es solo un directorio más**.

> **Recordatorio de alcance**: el homelab es solo **LAN + Tailscale**. Nada de los servicios que aquí se planifican publica puertos hacia internet. Caddy hará de puerta delantera para LAN/Tailscale y la propia política de bind (`127.0.0.1`, IP LAN, o solo red Docker interna) sigue las reglas que `01-instalacion-docker.md` ya estableció.

---

## Requisitos Previos

- Fase 1 completa, en particular `04-estructura-directorios.md`:
  - `/home/homelab/homelab/` existe, propietario `homelab:homelab`, modo `0750`.
  - `/home/homelab/homelab/stacks/` y `/home/homelab/homelab/secrets/` creados.
  - Árbol de `/mnt/hd2t/apps/<servicio>/...` poblado por `00-create-homelab-tree.sh`.
  - Grupos `homelab` (GID 1000) y `media` (GID 1100) presentes; `homelab` pertenece a ambos.
- `01-instalacion-docker.md` aplicado:
  - `docker info` muestra `Docker Root Dir: /mnt/hd2t/docker`, `Live Restore Enabled: true`, `Default Address Pools: 172.30.0.0/16`.
  - `docker compose version` ≥ `v2`.
  - `homelab` puede invocar `docker` sin `sudo`.
- Comprobación rápida antes de empezar:

  ```bash
  cd /home/homelab/homelab
  ls -la stacks/                   # vacío o casi
  docker compose version           # v2.x.x
  docker network ls                # bridge, host, none (todavía sin "homelab")
  ```

  Si `stacks/` no existe, volver a `04-estructura-directorios.md` y ejecutar `install -d` antes de seguir.

---

## Decisión: monolito vs `docker-compose.yml` por stack

Hay tres formas razonables de organizar Compose para un catálogo de ~30 servicios. Se comparan y se elige una.

| Opción | Cómo se ve | Pros | Contras | Veredicto |
|---|---|---|---|---|
| **Monolito**: un único `docker-compose.yml` con todos los servicios | `services:` con 30+ entradas en un solo fichero | `docker compose up -d` arranca todo en un comando. Una única red implícita. Una única ronda de pull. | Diff de git ilegible al cambiar un servicio. Un fallo de YAML rompe los 30 stacks. Dependencias artificiales: `docker compose up jellyfin` evalúa todo el grafo. Imposible de delegar a Portainer (Portainer mapea bien stack=fichero). | Descartado |
| **Per-stack**: un `docker-compose.yml` por servicio (o por grupo cohesionado) bajo `stacks/<nombre>/` | `stacks/pihole/docker-compose.yml`, `stacks/jellyfin/docker-compose.yml`, … | Cada stack es independiente: arranca, para, actualiza, debugea sin tocar a los demás. Diffs de git limpios. Encaja con Portainer (un stack = un fichero). Permite plantillas y `.env` por servicio. Los servicios se conectan por **red Docker compartida**, no por estar en el mismo fichero. | Requiere disciplina en convenciones (este documento). El operador escribe la ruta `-f stacks/<svc>/docker-compose.yml` o usa un `Makefile`/alias. | **Aceptado** |
| **Híbrido**: un compose "core" (red, Portainer, Watchtower) + un compose por servicio | `docker-compose.yml` raíz pequeño + `stacks/...` | Mejor que monolito, peor que per-stack: la red ya no necesita estar en un fichero, basta declararla `external: true`. | Aporta complejidad sin ventaja real. | Descartado |

Resultado: **un `docker-compose.yml` por stack bajo `stacks/<nombre>/`**, todos conectados a una red Docker compartida `homelab` declarada **externa**, y cada uno con su `.env` local cuando necesita variables específicas. La red se crea **una sola vez** desde fuera de Compose para que la vida de la red no dependa del primer stack que se levante.

> **Cohesión**: "un stack" no significa siempre "un servicio". Cuando un servicio principal arrastra sidecars **inseparables** (p. ej. Nextcloud + MariaDB + Redis, Paperless-ngx + Postgres + Redis, Stash + sus generadores), todos viven en el **mismo** `docker-compose.yml` del stack, con una **red interna privada** del stack además de la `homelab` compartida. La regla concreta se cierra en cada documento de servicio; aquí se establece el principio.

---

## Layout del repo: `/home/homelab/homelab/stacks/`

El árbol se reserva ya en Fase 1 (`04-estructura-directorios.md`). Aquí se fija la convención **dentro** de cada stack:

```
/home/homelab/homelab/
├── .env                                    Variables globales del homelab
├── .env.example                            Plantilla versionada (sin secretos)
├── .gitignore                              Excluye .env reales y secrets/*.unenc
├── docker-compose.yml                      (NO existe en este modelo; ver nota)
├── stacks/
│   ├── _template/                          Plantilla de referencia (versionada)
│   │   ├── docker-compose.yml
│   │   └── .env.example
│   ├── portainer/
│   │   └── docker-compose.yml
│   ├── watchtower/
│   │   ├── docker-compose.yml
│   │   └── .env
│   ├── pihole/
│   │   ├── docker-compose.yml
│   │   └── .env
│   ├── caddy/
│   │   ├── docker-compose.yml
│   │   └── Caddyfile
│   ├── nextcloud/
│   │   ├── docker-compose.yml
│   │   └── .env
│   └── ...                                 (resto de servicios de SERVICES.md)
├── scripts/
│   ├── 00-create-homelab-tree.sh           (Fase 1)
│   └── 10-create-docker-network.sh         (este documento)
└── secrets/                                (cifrados; sops/age, opcional)
```

> **Nota sobre el `docker-compose.yml` raíz**: la Fase 1 lo dejó como "opcional según Fase 2". **Aquí se decide que no existe**. La red `homelab` se crea con `docker network create` (script idempotente, ver más abajo) y no por un compose raíz. Esto evita el patrón "mi compose raíz es la red, si lo borro mato el homelab" y deja los stacks completamente independientes.

### Reglas por stack

| Regla | Justificación |
|---|---|
| Cada stack vive en `stacks/<nombre>/`. | Un directorio = un stack. Casa con Portainer (stack=fichero). |
| El nombre del stack en kebab-case y **coincide** con la clave de servicio principal. | Predecible: `stacks/jellyfin/` ↔ `services: jellyfin:`. |
| Dentro hay siempre un `docker-compose.yml`. **Solo eso**. Nada de `compose.yml`, `docker-compose.yaml` u otras variantes. | Convención fija para que `docker compose -f stacks/<x>/docker-compose.yml ...` funcione siempre. |
| Si el stack necesita variables o secretos, va un `.env` **adyacente**. | Compose v2 lo carga automáticamente si está junto al fichero. |
| Si necesita configuración estática (Caddyfile, mosquitto.conf, prometheus.yml), va junto al compose y se monta como bind mount. | Versionable en git, restaurable tras reflasheo. |
| `docker-compose.override.yml` **prohibido** salvo justificación explícita. | Hace ilegibles los diffs y los efectos del comando: lo que dice el fichero no es lo que corre. |

---

## Red Docker compartida: `homelab`

Todos los stacks que necesitan hablar entre sí lo hacen por **una red Docker compartida** llamada `homelab`. Se crea **una vez**, fuera de Compose, y cada stack la referencia como `external: true`.

### Por qué `external: true` y no que la cree el primer stack

| Opción | Problema |
|---|---|
| Que un stack "core" cree la red sin `external` | Borrar/recrear ese stack borra la red y el resto pierde DNS interno. |
| Que cada stack la cree con `external: false` | Compose tira error: dos stacks no pueden crear la misma red con el mismo nombre. |
| **Crearla una vez con `docker network create`, todos `external: true`** | La red sobrevive a `docker compose down` de cualquier stack. Su ciclo de vida es del **homelab**, no de un servicio. |

### Crear la red (idempotente)

```bash
sudo install -d -o homelab -g homelab -m 0750 /home/homelab/homelab/scripts
sudo tee /home/homelab/homelab/scripts/10-create-docker-network.sh >/dev/null <<'EOF'
#!/usr/bin/env bash
# Crea (idempotente) la red Docker compartida del homelab.
set -euo pipefail

NET="homelab"
SUBNET="172.30.10.0/24"

if docker network inspect "$NET" >/dev/null 2>&1; then
    echo "Red '$NET' ya existe. OK."
    exit 0
fi

docker network create \
    --driver bridge \
    --subnet "$SUBNET" \
    --opt com.docker.network.bridge.name="br-homelab" \
    "$NET"

echo "Red '$NET' creada en $SUBNET."
EOF
sudo chown homelab:homelab /home/homelab/homelab/scripts/10-create-docker-network.sh
sudo chmod 0750 /home/homelab/homelab/scripts/10-create-docker-network.sh

bash /home/homelab/homelab/scripts/10-create-docker-network.sh
```

Decisiones clave:

| Clave | Valor | Por qué |
|---|---|---|
| Nombre | `homelab` | Corto, reconocible en `docker network ls`. No usar `default`/`bridge` (reservados). |
| Driver | `bridge` | El driver por defecto de Docker. Suficiente para un único host. `overlay` solo aplica con Swarm/multi-host. |
| Subred | `172.30.10.0/24` | Cae dentro de `default-address-pools` (`172.30.0.0/16` con `size: 24`) que `daemon.json` ya reservó. Evita que Docker la asigne a otra red por accidente y la deja **trazable** en `ip a`. |
| Bridge name del kernel | `br-homelab` | Por defecto Docker genera nombres `br-xxxxxxxx` aleatorios; nombrarlo facilita reglas de iptables, `tcpdump -i br-homelab`, troubleshooting. |
| `internal` | **No** | La red puede salir a internet (necesario para que los contenedores hagan `apt update`, `pull`, llamadas API externas). Las redes **dentro** de un stack (BBDD privadas) sí serán `internal: true`. |

Verificación:

```bash
docker network ls | grep homelab
# bridge   homelab   ...   bridge   local

docker network inspect homelab --format '{{.IPAM.Config}}'
# [{172.30.10.0/24  172.30.10.1 map[]}]

ip -br link show br-homelab
# br-homelab UNKNOWN ...
```

### Topología por stack

Cada stack se conecta a `homelab` para hablar con los demás (Caddy ↔ servicios, Prometheus ↔ exporters, Uptime Kuma ↔ todo). Cuando un stack tiene **sidecars inseparables** (BBDD, Redis), declara también una red interna privada:

```yaml
networks:
  homelab:
    external: true
  internal:
    driver: bridge
    internal: true                # sin salida a internet
```

`internal: true` es exactamente lo que se quiere para una BBDD: ni el contenedor de Postgres ni Redis necesitan salir a internet, y reducir su superficie es gratis.

---

## Convenciones de nombres

Compose, sin convenciones explícitas, deriva los nombres del directorio que contiene el fichero y prefija con un guion: un servicio `web` en `stacks/jellyfin/` queda como `stacks-web-1`. Eso confunde logs, dashboards y comandos. Para evitarlo:

| Elemento | Convención | Ejemplo |
|---|---|---|
| **Project name** | Nombre del stack en kebab-case. Se fija con `name:` en el propio compose o vía `COMPOSE_PROJECT_NAME` en `.env`. | `name: jellyfin` |
| **Clave de servicio** (`services: <key>:`) | kebab-case, semántica del rol dentro del stack. Para el servicio principal, **igual al nombre del stack**. | `jellyfin`, `db`, `redis`, `worker` |
| **`container_name`** | Igual al nombre del stack para el principal; `<stack>-<rol>` para los sidecars. **Siempre** se fija. | `jellyfin`, `nextcloud-db`, `paperless-redis` |
| **`hostname`** | Igual a `container_name`. Lo que ven los demás contenedores en la red `homelab` por DNS interno. | `hostname: jellyfin` |
| **Imagen** | Tag **explícito** y razonablemente fijado (mayor + menor cuando sea posible, no `latest`). | `jellyfin/jellyfin:10.9`, `mariadb:11.4`, `postgres:16-alpine` |
| **Redes externas** referenciadas | `homelab` (la red compartida). | `networks: { homelab: {}, internal: {} }` |
| **Bind mounts** | Rutas absolutas a `/mnt/hd2t/apps/<stack>/...` o `/mnt/hd5t/...`. **Nunca** rutas relativas al compose para datos. | `/mnt/hd2t/apps/jellyfin/config:/config` |
| **Volúmenes nominales** (`volumes:` top-level) | **No se usan** en este homelab. Regla heredada de `01-instalacion-docker.md`. Excepción documentada por servicio si la justifica. | — |
| **Variables de entorno** | `MAYUSCULAS_CON_GUION_BAJO`. Las cargadas desde `.env` no se duplican en `environment:`; se interpolan con `${VAR}`. | `TZ=${TZ}` |
| **Labels propios del homelab** | Prefijadas con `homelab.`. Útil para Watchtower (incluir/excluir), Portainer, scripts de inventario. | `labels: ["homelab.role=media"]` |

### Política de `restart`

| Caso | Valor | Por qué |
|---|---|---|
| Servicios persistentes (Pi-hole, Caddy, Jellyfin, Nextcloud, …) | `restart: unless-stopped` | Reaparecen tras un reboot pero respetan que el operador los pare manualmente. |
| Jobs one-shot (migraciones, `borgmatic` cron-driven en ciertos diseños) | `restart: "no"` | No tiene sentido reintentar un job hasta el fin de los tiempos. |
| `restart: always` | **No se usa** | Es agresivo: tras `docker stop` arranca otra vez al rebootear. `unless-stopped` es lo correcto para servicios. |

### Política de healthchecks

Todo servicio principal **lleva healthcheck**, aunque sea trivial:

```yaml
healthcheck:
  test: ["CMD", "curl", "-fsS", "http://localhost:8096/health"]
  interval: 30s
  timeout: 5s
  retries: 3
  start_period: 30s
```

Si la imagen no incluye `curl`/`wget`, se usa lo que sí trae (`pg_isready` para Postgres, `mysqladmin ping` para MariaDB, `redis-cli ping` para Redis…). El healthcheck no es estética: Watchtower (Fase 2.4) y Uptime Kuma (Fase 4) lo consumen, y `depends_on` con `condition: service_healthy` solo funciona si está definido.

---

## Variables de entorno

Compose v2 carga variables desde tres sitios, en orden de precedencia descendente: `environment:` del servicio > `env_file:` declarado > `.env` adyacente al compose. Se aprovecha esa cadena de la siguiente forma.

### `.env` global del repo

Vive en `/home/homelab/homelab/.env`. Lo leen los stacks que se invocan **desde la raíz del repo** con `--project-directory`, y se replica como referencia en cada stack. Contiene **solo** valores compartidos por todo el homelab, **sin** secretos:

```bash
# /home/homelab/homelab/.env  (NO se sube a git: cubierto por .gitignore)

# Identidad del operador y zona horaria (la usan ~todos los servicios)
TZ=Europe/Madrid
PUID=1000
PGID=1000
PGID_MEDIA=1100

# Dominio interno del homelab (LAN + Tailscale, no público)
DOMAIN_LAN=home.lan
DOMAIN_TAILSCALE=  # se rellena en Fase 3 (Tailscale magicDNS)

# Versión de Docker Compose esperada (informativo, no se interpola)
COMPOSE_PROJECT_VERSION=1.0.0
```

`/home/homelab/homelab/.env.example` se versiona en git con los mismos nombres de variable y valores **inocuos** o vacíos, para que tras un reflasheo el operador `cp .env.example .env` y rellene.

### `.env` por stack

Cuando un stack necesita credenciales o hostnames específicos, lleva su propio `.env` adyacente al compose. Por ejemplo, `stacks/nextcloud/.env`:

```bash
COMPOSE_PROJECT_NAME=nextcloud
NEXTCLOUD_ADMIN_USER=homelab
NEXTCLOUD_ADMIN_PASSWORD=  # generar con `openssl rand -base64 24`
MYSQL_ROOT_PASSWORD=
MYSQL_PASSWORD=
NEXTCLOUD_TRUSTED_DOMAINS=nextcloud.home.lan
```

Reglas:

| Regla | Justificación |
|---|---|
| `.env` está en `.gitignore`. Solo `.env.example` se versiona. | Secretos en claro fuera del repo público. |
| Permisos: `chmod 0600 .env` por stack. | Cualquier proceso del UID `homelab` puede leerlo, nadie más. Aunque `0640` también vale, `0600` es lo conservador. |
| Las claves del `.env` por stack **no chocan** con las del `.env` global (si chocan, gana el del stack). | Predecible: lo más cercano gana. |
| Variables sensibles no se interpolan en `command:` ni `labels:`. | Esos campos quedan visibles en `docker inspect` y en los logs de Compose; un secreto inyectado por `command: foo --pass=${PASS}` es un secreto regalado. Se inyectan vía `environment:` o secretos cifrados (Fase 4 de seguridad). |
| Para rotación de credenciales: editar `.env`, `docker compose up -d` recrea el contenedor con la nueva variable. | Compose detecta el cambio en `env_file:` y marca el contenedor como "re-create". |

### `.gitignore` actualizado

El `04-estructura-directorios.md` ya proponía un esqueleto. Aquí se cierra el contrato:

```
# Secretos y entornos
.env
*.env
!.env.example
!**/.env.example

# Bloqueos de Compose
docker-compose.override.yml
docker-compose.override.yaml

# Volúmenes/datos por error
/data/
/mnt/

# Locales del editor
.vscode/
.idea/
*.swp
```

`!**/.env.example` permite versionar plantillas tanto en la raíz como en cada `stacks/<svc>/`.

---

## Plantilla canónica de stack: `stacks/_template/`

Se versiona en el repo como referencia. Cualquier nuevo servicio parte de esta plantilla y solo cambia lo específico.

### `stacks/_template/docker-compose.yml`

```yaml
# Plantilla de referencia para un stack del homelab.
# Copiar a stacks/<servicio>/docker-compose.yml y particularizar.

name: example                          # ← cambiar al nombre del stack

services:
  example:                             # ← clave = nombre del stack
    image: nginx:1.27-alpine           # ← imagen + tag explícito (no :latest)
    container_name: example
    hostname: example
    restart: unless-stopped

    environment:
      TZ: ${TZ}
      PUID: ${PUID}
      PGID: ${PGID}

    # env_file: .env                   # descomentar si el stack tiene .env propio

    networks:
      - homelab

    # Bind mounts: rutas absolutas a /mnt/hd2t/apps/<stack>/...
    volumes:
      - /mnt/hd2t/apps/example/config:/config
      - /mnt/hd2t/apps/example/data:/data

    # Sin `ports:` por defecto: la exposición la hace Caddy via red `homelab`.
    # Si el servicio tiene que escuchar directo en la Pi, bind a 127.0.0.1:
    # ports:
    #   - "127.0.0.1:18080:80"

    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://localhost/"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s

    labels:
      homelab.role: "example"          # categoría libre: dns, media, monitoring…
      homelab.backup: "true"           # consumida por scripts de Borgmatic (Fase 7)
      com.centurylinklabs.watchtower.enable: "true"   # Watchtower (Fase 2.4)

networks:
  homelab:
    external: true
```

### `stacks/_template/.env.example`

```bash
# Variables específicas del stack. Copiar a .env y rellenar.
# COMPOSE_PROJECT_NAME=example
# EXAMPLE_API_KEY=
# EXAMPLE_DB_PASSWORD=
```

### Validación previa al commit

```bash
cd /home/homelab/homelab/stacks/_template
docker compose --env-file ../../.env config >/dev/null
echo $?    # 0 = sintaxis y referencias OK
```

`docker compose config` evalúa interpolaciones, valida el esquema YAML y muestra el compose **expandido**. Si una variable no está definida en `.env`, lo dice con el nombre exacto.

---

## Reglas de exposición (resumen aplicado a Compose)

`01-instalacion-docker.md` estableció el principio: UFW protege el host, Docker se gestiona en compose. Aquí se concreta en tres patrones, **uno y solo uno** por servicio:

| Patrón | Cuándo | `ports:` | Acceso |
|---|---|---|---|
| **A. Solo red interna** | Servicios web detrás de Caddy (la mayoría: Jellyfin, Nextcloud, Stash, *arr, Grafana…). | (no se declara) | Otros contenedores de la red `homelab` por DNS interno. Caddy publica al exterior. |
| **B. Bind a `127.0.0.1`** | Servicios web que **no** pasan por Caddy (rara excepción) o herramientas que el operador toca por `ssh -L`. | `["127.0.0.1:PORT:PORT"]` | Solo desde la propia Pi. La LAN no llega. |
| **C. Bind a IP LAN** | Servicios que necesitan escuchar a toda la LAN: Pi-hole en `:53`, Samba, eventualmente Home Assistant para descubrimiento. | `["${LAN_IP}:PORT:PORT"]` | LAN completa (y Tailscale si la Pi expone su tailnet). Documentado y justificado en cada servicio. |

`network_mode: host` está prohibido por defecto. Excepciones (Home Assistant con mDNS, casos USB-passthrough especiales) se argumentan en su documento, no aquí.

---

## Ciclo de vida operativo

Comandos que el operador ejecuta a diario sobre un stack `<svc>`:

```bash
cd /home/homelab/homelab

# Validar antes de aplicar
docker compose -f stacks/<svc>/docker-compose.yml --env-file .env config >/dev/null

# Levantar
docker compose -f stacks/<svc>/docker-compose.yml --env-file .env up -d

# Estado
docker compose -f stacks/<svc>/docker-compose.yml ps
docker compose -f stacks/<svc>/docker-compose.yml logs --tail 200 -f

# Actualizar imágenes (manual; Watchtower lo automatiza en 04-watchtower.md)
docker compose -f stacks/<svc>/docker-compose.yml pull
docker compose -f stacks/<svc>/docker-compose.yml up -d

# Bajar (sin borrar bind mounts)
docker compose -f stacks/<svc>/docker-compose.yml down

# Bajar y purgar imágenes (rara vez)
docker compose -f stacks/<svc>/docker-compose.yml down --rmi all
```

Para no escribir `-f stacks/<svc>/docker-compose.yml --env-file .env` cada vez, se añade un alias mínimo en `~/.bashrc` del usuario `homelab`:

```bash
hl() {
    local svc="$1"; shift
    docker compose \
        --project-directory /home/homelab/homelab \
        -f "/home/homelab/homelab/stacks/${svc}/docker-compose.yml" \
        --env-file /home/homelab/homelab/.env \
        "$@"
}
# Uso:
#   hl pihole up -d
#   hl jellyfin logs -f
#   hl nextcloud pull
```

> Es solo conveniencia. Los scripts del repo (`scripts/`) y la documentación de cada servicio usan **rutas absolutas explícitas** para que sean ejecutables desde cualquier shell, incluyendo cron y systemd timers (Borgmatic, healthchecks…).

---

## Almacenamiento

Rutas que toca este documento, todas en la microSD (versionables) salvo la red Docker (estado del daemon):

| Ruta | Soporte | Owner:Group | Modo | Contenido |
|---|---|---|---|---|
| `/home/homelab/homelab/.env` | microSD | `homelab:homelab` | `0600` | Variables globales del homelab. **No** se versiona. |
| `/home/homelab/homelab/.env.example` | microSD | `homelab:homelab` | `0644` | Plantilla versionada. |
| `/home/homelab/homelab/.gitignore` | microSD | `homelab:homelab` | `0644` | Reglas de exclusión del repo. Versionada. |
| `/home/homelab/homelab/stacks/_template/` | microSD | `homelab:homelab` | `0750` | Plantilla canónica de stack. Versionada. |
| `/home/homelab/homelab/stacks/<svc>/docker-compose.yml` | microSD | `homelab:homelab` | `0640` | Compose por stack. Versionado. |
| `/home/homelab/homelab/stacks/<svc>/.env` | microSD | `homelab:homelab` | `0600` | Secretos del stack. **No** se versiona. |
| `/home/homelab/homelab/scripts/10-create-docker-network.sh` | microSD | `homelab:homelab` | `0750` | Crea la red `homelab`. Versionado. |
| Red Docker `homelab` | runtime | (daemon) | — | Estado del daemon en `/mnt/hd2t/docker/network/`. Reproducible desde el script. |
| `/mnt/hd2t/apps/<svc>/...` | hd2t | (varía por servicio) | (varía) | Bind mounts. Los crea cada documento de servicio sobre lo que ya pobló `00-create-homelab-tree.sh`. |

**No** se crean datos persistentes en este documento: solo plantillas, scripts y la red Docker.

---

## Backup

A nivel del repositorio del homelab:

| Artefacto | Estrategia |
|---|---|
| `stacks/*/docker-compose.yml`, `_template/`, `scripts/` | Versionados en git. Reproducibles tras un reflasheo. |
| `.env` global y por stack | **No** versionados, **sí** respaldados por Borg (Fase 7) como parte de `/home/homelab/homelab/`. Cifrados en el repo Borg. |
| `Caddyfile`, `prometheus.yml`, `mosquitto.conf`, etc. | Versionados (no tienen secretos). |
| Red Docker `homelab` | Reproducible desde `scripts/10-create-docker-network.sh`. No se respalda. |

A nivel de datos: cada servicio define qué se respalda de su `/mnt/hd2t/apps/<svc>/...` en su propio documento. Las labels `homelab.backup=true|false` y la separación de `data/` vs `cache/` que `04-estructura-directorios.md` reservó dan a Borgmatic (Fase 7) lo que necesita para incluir/excluir sin reglas frágiles.

---

## Errores frecuentes y troubleshooting

| Síntoma | Causa probable | Resolución |
|---|---|---|
| `network homelab declared as external, but could not be found` | El script `10-create-docker-network.sh` no se ha ejecutado (o se ha hecho `docker network rm homelab`). | Re-ejecutar el script. Es idempotente. |
| `service "<x>" depends on undefined service "<y>"` | Sidecars referenciados (Postgres, Redis) no están en el mismo compose del stack. | Mover el sidecar al mismo `docker-compose.yml` del stack o quitar el `depends_on` si vive en otro stack. Stacks distintos no comparten DNS por nombre de servicio si no comparten red. |
| `WARN[0000] The "FOO" variable is not set. Defaulting to a blank string.` | Variable referenciada con `${FOO}` que no está en `.env` ni en el entorno. | Definirla en `.env` o usar `${FOO:-default}`. Nunca dejar variables silenciosamente vacías. |
| `Error response from daemon: Conflict. The container name "<x>" is already in use` | Otro stack usa el mismo `container_name`. | Renombrar; los `container_name` son globales al daemon. |
| Tras `docker compose down`, los datos del bind mount **siguen ahí** | Comportamiento esperado. `down` no toca los bind mounts; solo `--volumes` borra **volúmenes nominales**, que aquí no se usan. | Si se quiere limpiar `/mnt/hd2t/apps/<svc>/...`, hacerlo manualmente y conscientemente. |
| `permission denied` al escribir en `/mnt/hd2t/apps/<svc>/...` desde un contenedor | El contenedor corre con un UID distinto al del propietario del bind mount. | Forzar `PUID=1000`, `PGID=1000` (o `1100` si toca `media/`) vía `.env`. Confirmar con `ls -ln /mnt/hd2t/apps/<svc>/`. |
| `compose config` valida pero el contenedor no arranca por hostname duplicado | Dos servicios distintos con el mismo `hostname`. | Cada `container_name`/`hostname` es único en la red `homelab`. Renombrar. |
| Cambios en `.env` no se aplican | `docker compose up` sin `-d` y sin recreación. | `docker compose up -d` detecta el cambio en `env_file:` y recrea el contenedor; si no, `--force-recreate`. |

---

## Decisiones que **no** se toman en este documento

- **Despliegue de Portainer y Watchtower**: van en `03-portainer.md` y `04-watchtower.md`. Sus stacks **siguen** las convenciones de aquí.
- **Reverse proxy y certificados**: Caddy (con CA interna para LAN) vive en `docs/03-red-dns/04-caddy.md`. Aquí solo se establece que Caddy es el patrón A de exposición.
- **Cifrado de `.env` (sops/age, Vault, Bitwarden CLI)**: se evalúa en `docs/05-seguridad/` o cuando aparezca el primer servicio que lo justifique (Vaultwarden, Authelia). Hasta entonces, `chmod 0600` y backup cifrado por Borg.
- **Profiles y entornos** (`COMPOSE_PROFILES`, dev/prod, …): no aplican en un homelab single-host. Si en algún momento se introduce un nodo de pruebas, se reabre.
- **Compose v2 specification (`x-foo:` anchors, `extends:`)**: tentador para deduplicar bloques `environment:` y `healthcheck:`. **No se adoptan en esta fase**. Una plantilla bien comentada (`_template/`) es más legible para el operador del homelab que un grafo de anchors. Reabrible si se aburre el documento de algún servicio.

---

## Verificación Final

Antes de pasar a `03-portainer.md`:

| Comprobación | Comando | Resultado esperado |
|---|---|---|
| Layout del repo correcto | `tree -L 2 /home/homelab/homelab` | Ramas `stacks/`, `scripts/`, `secrets/`, ficheros `.env`, `.env.example`, `.gitignore` |
| Plantilla disponible | `ls /home/homelab/homelab/stacks/_template/` | `docker-compose.yml`, `.env.example` |
| `.env` global presente y cerrado | `stat -c '%a %U:%G' /home/homelab/homelab/.env` | `600 homelab:homelab` |
| `.env.example` versionable | `git status` | `.env.example` aparece como tracked, `.env` ignorado |
| Red Docker creada | `docker network inspect homelab --format '{{.IPAM.Config}}'` | `[{172.30.10.0/24 ...}]` |
| Bridge nombrado | `ip -br link show br-homelab` | `br-homelab UNKNOWN ...` |
| Plantilla valida | `docker compose -f stacks/_template/docker-compose.yml --env-file .env config >/dev/null` | exit 0 |
| Sin colisiones de pool | `docker network ls --format '{{.Name}} {{.Driver}}'` | `homelab` presente, no hay otra red en `172.30.10.0/24` |
| Idempotencia del script | `bash scripts/10-create-docker-network.sh` (segunda vez) | `Red 'homelab' ya existe. OK.` |
| `.gitignore` aplica | `git check-ignore -v .env` | reporta la regla activa |

Cumplido el último punto, la Fase 2 puede continuar: el siguiente paso es desplegar **Portainer CE** como primer stack real del homelab, ya bajo todas estas convenciones (`03-portainer.md`).

---

## Referencias

- [Documento anterior: `docs/02-docker/01-instalacion-docker.md`](./01-instalacion-docker.md)
- [Documento siguiente: `docs/02-docker/03-portainer.md`](./03-portainer.md)
- [Documento relacionado: `docs/01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md)
- [Docker — Compose file specification](https://docs.docker.com/compose/compose-file/)
- [Docker — Compose v2 networking](https://docs.docker.com/compose/networking/)
- [Docker — `docker network create`](https://docs.docker.com/reference/cli/docker/network/create/)
- [Docker — Compose environment variables](https://docs.docker.com/compose/environment-variables/)
- [Docker — Compose project name and `name:`](https://docs.docker.com/compose/project-name/)
- [Docker — Healthchecks in Compose](https://docs.docker.com/reference/compose-file/services/#healthcheck)
- [Docker — Bind mounts vs named volumes](https://docs.docker.com/storage/bind-mounts/)
