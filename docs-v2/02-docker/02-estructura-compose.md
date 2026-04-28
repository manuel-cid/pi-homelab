# Estructura de Docker Compose

## Descripción

Definición de la **estrategia de organización de los `docker-compose.yml`** del homelab: cómo se troncan los servicios en *stacks*, dónde viven los ficheros (versionables en git) frente a los datos (en `hd2t`), qué red Docker comparten, qué convenciones siguen los nombres de contenedores, redes y volúmenes, cómo se gestionan los secretos vía `.env` y qué plantilla mínima debe respetar todo nuevo `docker-compose.yml` que se añada al homelab.

Este documento es **norma**: el resto de fases (3 a 13) ya asume estas convenciones para todo `docker-compose.yml` que escriban. Cuando un servicio diverge (PostgreSQL con UID propio, contenedores en `network_mode: host`, etc.) lo dirá explícitamente en su propio doc.

Cubre, en este orden:

1. **Stacks vs monolito**: por qué se elige un `docker-compose.yml` por stack en lugar de un único fichero para todo el homelab.
2. **Layout en disco**: separación entre el directorio de *stacks* (versionable, en `~/homelab`) y el directorio de *datos* (no versionable, en `/mnt/hd2t/services/`).
3. **Convenciones de nombres** para `name:`, `container_name`, redes y volúmenes.
4. **Red Docker compartida `homelab`**: una bridge `external` que conecta los stacks que tienen que hablarse (Caddy → backends, Authelia → backends, Prometheus → exporters).
5. **Variables de entorno**: `.env` por stack, `.env.example` versionable, secretos fuera de git.
6. **Plantilla base** de un servicio Compose con todas las opciones que se asumen por defecto en el resto de fases (`restart`, `logging`, `security_opt`, `healthcheck`, `labels` para Watchtower y Homepage).
7. **Verificación** y **solución de problemas**.

> **Alcance**: aquí no se despliega ningún servicio. Portainer entra en [`03-portainer.md`](./03-portainer.md) y Watchtower en [`04-watchtower.md`](./04-watchtower.md). El primer servicio que aplica esta estructura "en serio" es la red+DNS de la [Fase 3](../03-red/).

> **Recordatorio**: el homelab opera en **LAN + Tailscale**. Ningún `ports:` debería publicarse a `0.0.0.0` salvo cuando lo justifique el doc del servicio (Caddy en 80/443, Pi-hole en 53). Por defecto, los servicios solo se exponen a través de la red Docker compartida `homelab` y se enrutan por Caddy.

---

## Requisitos Previos

- Docker Engine y Docker Compose v2 instalados según [`01-instalacion-docker.md`](./01-instalacion-docker.md), con `daemon.json` aplicando `default-address-pools=172.20.0.0/16` y `live-restore=true`.
- Estructura de directorios aplicada según [`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md): `/mnt/hd2t/services/` con `homelab:homelab` `750`.
- Usuario `homelab` (`UID=1000`, `GID=1000`) en el grupo `docker` y con sesión SSH reabierta tras el `usermod` del paso 6 del doc anterior.
- Grupo `media` (`GID=1100`) creado.
- `git` instalado en el host (`sudo apt install -y git`) para versionar el repo de stacks.
- (Opcional) `pass` o un gestor de secretos para los `.env`; en este homelab se acepta tenerlos en texto claro fuera de git, en `/mnt/hd2t/services/<stack>/.env` con `0600`.

### Decisiones de diseño asumidas

| Decisión | Valor por defecto | Justificación |
|---|---|---|
| Granularidad | **Un `docker-compose.yml` por *stack* funcional** (Pi-hole+Unbound, *arr*, monitorización, multimedia, productividad...) | Un monolito de ~50 servicios sería ilegible, frágil ante un `docker compose up -d` accidental y un infierno para diff/PR. La granularidad por stack permite levantar/parar solo lo afectado y mantener `docker-compose.yml` < ~150 líneas. La excepción es agrupar servicios **fuertemente acoplados** que siempre arrancan juntos (p. ej. Nextcloud + MariaDB + Redis, o Pi-hole + Unbound). |
| Ubicación del repo de stacks | `~/homelab/stacks/<stack>/docker-compose.yml` (en el `$HOME` de `homelab`, versionado en git) | Los `docker-compose.yml`, `Caddyfile`, `prometheus.yml`, etc. son **configuración** y deben ir en git. Vivir en `$HOME` (microSD) los hace cargar rápido y mantiene `hd2t` como almacén exclusivo de datos. El backup de `~/homelab` lo cubre [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md). |
| Ubicación de los datos persistentes | `/mnt/hd2t/services/<stack>/` con bind mounts explícitos | Coherente con [`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md). Bind mounts (no named volumes) → backup directo con Borg, ruta predecible y portabilidad si hay que recuperar el servicio en otra máquina. |
| Ubicación del `.env` | `/mnt/hd2t/services/<stack>/.env` (no en `~/homelab/`) | El `.env` contiene secretos. Mantenerlo **fuera de `~/homelab`** elimina el riesgo de hacer `git add .env` por accidente. En el `docker-compose.yml` se referencia con `env_file: /mnt/hd2t/services/<stack>/.env`. |
| Versionar `.env.example` | **Sí**, en `~/homelab/stacks/<stack>/.env.example` | Plantilla con todas las claves esperadas y valores ficticios, para reconstruir el `.env` real tras un disaster recovery. |
| Red Docker compartida | `homelab` (bridge), declarada **una vez** como `external` | Evita N×N redes manuales para que Caddy/Authelia/Prometheus puedan llegar a cualquier backend. Cada stack la declara como `external: true` y añade su servicio a esa red **además** de la red interna del propio stack si la tiene. |
| Subred de la red `homelab` | `172.20.0.0/24` (asignada manualmente) | Subred fija para que Pi-hole pueda definir registros DNS internos contra IPs estables si se quiere. Cabe en el pool definido en `daemon.json` (`172.20.0.0/16`). |
| Política de `restart` | `unless-stopped` | Reinicia tras crash o reboot, pero **respeta** un `docker compose stop` manual del operador. `always` ignoraría el stop manual; `on-failure` no reinicia tras reboot. |
| Política de logging por servicio | Heredada del `daemon.json` (`json-file`, 10 MB × 3) | No se duplica en cada `docker-compose.yml`. Si un servicio necesita más retención (Pi-hole con `pihole-FTL`), se sobreescribe en su propio doc. |
| `security_opt: no-new-privileges:true` | **Activado por defecto** en la plantilla | Impide que un proceso del contenedor escale privilegios vía `setuid`. Sin coste para imágenes oficiales del homelab; las que lo rompan se documentarán como excepción. |
| `container_name` explícito | **Sí** | Sin `container_name`, Compose lo genera como `<projecto>-<servicio>-1`, lo que dificulta `docker logs <nombre>` y la integración con Dozzle/Caddy. Se fija al nombre canónico del servicio (`pihole`, `jellyfin`...). |
| `name:` del proyecto Compose (`name:` top-level) | **Sí**, igual al nombre del directorio del stack | Sin `name:`, Compose toma el nombre del directorio padre, que en este layout sería `<stack>` (lo deseado), pero declararlo explícito blinda el comportamiento ante un `docker compose -f ...` lanzado desde otro directorio. |
| Bind mounts en formato largo (`type: bind`, `source:`, `target:`) | **Sí** en la plantilla | Más explícito, soporta `bind.create_host_path: false` para no crear directorios silenciosos si el operador escribió mal la ruta. |
| `version:` top-level | **Omitido** | Compose v2 lo ignora y emite warning desde 2024. Se confía en el plugin `docker-compose-plugin` instalado en el doc anterior. |
| Usuario dentro del contenedor | `user: "${PUID}:${PGID}"` cuando la imagen lo soporta | Coherente con `PUID=1000`, `PGID=1000` (o `1100` para multimedia) definidos en [`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md). Imágenes que no lo soportan (PostgreSQL, MariaDB) leerán `PUID/PGID` o tendrán su propio UID interno. |
| Comentar bloques disabled con `# DISABLED:` | **Sí** | Para no perder la configuración de un servicio que se desactiva temporalmente. Mejor que borrar y depender del histórico de git. |

---

## 1. Stacks vs monolito

### 1.1. Stacks definidos en este homelab

Cada stack agrupa los servicios que **se levantan/paran juntos**, comparten lifecycle y, normalmente, comparten dependencias. La lista canónica (que cada doc de fase puede afinar) es:

| Stack | Servicios | Doc(s) de origen |
|---|---|---|
| `dns` | Pi-hole, Unbound | [`../03-red/02-pihole.md`](../03-red/02-pihole.md), [`../03-red/03-unbound.md`](../03-red/03-unbound.md) |
| `proxy` | Caddy | [`../03-red/04-caddy.md`](../03-red/04-caddy.md) |
| `tailscale` | Tailscale (si va en contenedor) | [`../03-red/05-tailscale.md`](../03-red/05-tailscale.md) |
| `auth` | Authelia (+ Redis para sesiones) | [`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md) |
| `monitoring` | Prometheus, Grafana, Node Exporter, cAdvisor, Uptime Kuma, Dozzle | [`../05-monitorizacion/`](../05-monitorizacion/) |
| `nextcloud` | Nextcloud + MariaDB + Redis | [`../06-almacenamiento/01-nextcloud.md`](../06-almacenamiento/01-nextcloud.md) |
| `samba` | Samba | [`../06-almacenamiento/02-samba.md`](../06-almacenamiento/02-samba.md) |
| `syncthing` | Syncthing | [`../06-almacenamiento/03-syncthing.md`](../06-almacenamiento/03-syncthing.md) |
| `minio` | MinIO | [`../06-almacenamiento/04-minio.md`](../06-almacenamiento/04-minio.md) |
| `backup` | Borgmatic | [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) |
| `homeassistant` | Home Assistant, Mosquitto, Zigbee2MQTT, Node-RED | [`../08-domotica/`](../08-domotica/) |
| `media` | Jellyfin, Navidrome, Audiobookshelf, Calibre-Web | [`../09-multimedia/`](../09-multimedia/) (excluye Stash) |
| `stash` | Stash | [`../09-multimedia/05-stash.md`](../09-multimedia/05-stash.md) |
| `arr` | Transmission, Prowlarr, Sonarr, Radarr | [`../10-descargas/`](../10-descargas/) |
| `productivity` | Vaultwarden, Bookstack, Linkding, Paperless-ngx, Mealie, Stirling-PDF, FreshRSS | [`../11-productividad/`](../11-productividad/) |
| `dashboard` | Homepage | [`../12-dashboards/01-homepage.md`](../12-dashboards/01-homepage.md) |
| `infra` | Portainer, Watchtower | [`./03-portainer.md`](./03-portainer.md), [`./04-watchtower.md`](./04-watchtower.md) |

> Algunos stacks pueden subdividirse si crecen: por ejemplo `productivity` puede partirse en `productivity-docs` y `productivity-misc` el día que el `docker-compose.yml` supere las ~200 líneas. La regla orientativa: **un stack debe caber en una pantalla mental**.

### 1.2. ¿Por qué no un único `docker-compose.yml` con todo?

| Problema | Cómo lo evita la división por stacks |
|---|---|
| `docker compose up -d` toca todos los servicios y reinicia los que tengan cualquier diff (incluso un `image:` actualizado) | Cada `up -d` afecta solo al stack en cuestión. Watchtower o las actualizaciones manuales se aplican stack a stack. |
| Un fallo de sintaxis YAML rompe el despliegue completo | El stack roto no se levanta, pero el resto del homelab sigue corriendo. |
| Diff en PR/git ilegible (cambias un puerto y `git diff` muestra 2.000 líneas de contexto) | Diffs locales y ricos en señal. |
| Recuperar un servicio puntual requiere localizar su bloque en un fichero de miles de líneas | `cd ~/homelab/stacks/<stack> && docker compose ps` |
| La red interna pasa a ser gigantesca (todos los servicios en la misma red) | Cada stack mantiene su red interna privada y solo se asoma a `homelab` los servicios que necesitan ser alcanzables desde otro stack. |

### 1.3. ¿Por qué no un `docker-compose.yml` por servicio?

| Problema | Cómo lo evita la agrupación por stacks |
|---|---|
| Servicios fuertemente acoplados (Nextcloud + MariaDB + Redis) requieren `depends_on`, healthchecks y orden de arranque coordinado | Si están en el mismo `docker-compose.yml`, `depends_on` con `condition: service_healthy` funciona de forma natural. Entre stacks distintos no hay `depends_on` posible. |
| Multiplicación de redes y volúmenes triviales | Una sola red interna por stack en lugar de N redes externas para conectar pares. |
| Coste cognitivo de tener 50 carpetas con un único servicio | 17 stacks es mucho más llevadero. |

> Resumen: **stack = unidad de despliegue**, servicio = unidad funcional. Compose ya soporta este modelo de forma natural; lo único que hay que añadir es la red `homelab` compartida (§4).

---

## 2. Layout en disco

### 2.1. Esquema completo

```
/home/homelab/                     # microSD, en git
└── homelab/                       # repo principal del homelab
    ├── README.md
    ├── SERVICES.md
    ├── PLAN.md / docs/...         # documentación (este repo)
    └── stacks/
        ├── dns/
        │   ├── docker-compose.yml
        │   └── .env.example
        ├── proxy/
        │   ├── docker-compose.yml
        │   ├── Caddyfile          # configuración del servicio
        │   └── .env.example
        ├── monitoring/
        │   ├── docker-compose.yml
        │   ├── prometheus.yml
        │   └── .env.example
        └── ...

/mnt/hd2t/services/                # HDD, fuera de git
├── dns/
│   ├── .env                       # secretos reales (chmod 600)
│   ├── pihole/
│   │   ├── etc-pihole/            # bind mount
│   │   └── etc-dnsmasq.d/
│   └── unbound/
│       └── etc-unbound/
├── proxy/
│   ├── .env
│   ├── caddy/
│   │   ├── data/
│   │   └── config/
├── monitoring/
│   ├── .env
│   ├── prometheus/
│   │   └── data/
│   ├── grafana/
│   │   └── data/
│   └── ...
└── ...
```

### 2.2. Por qué dos directorios y no uno

| Criterio | `~/homelab/stacks/` (microSD) | `/mnt/hd2t/services/` (HDD) |
|---|---|---|
| Contenido | YAML, JSON, plantillas, `Caddyfile`, `prometheus.yml`, `.env.example` | Datos persistentes, bases de datos, caches, `.env` real |
| Versionado | git (rama `main`, push opcional a remote privado) | **No** versionado (datos cambian a cada segundo) |
| Volumen | KB | GB-TB |
| Backup | Borg + git remote | Borg (Fase 7) |
| Recuperación tras DR | `git clone` + `cp .env.example .env` | Restore Borg |

### 2.3. Inicializar el repo de stacks

```bash
# Como usuario homelab.
cd ~
mkdir -p homelab/stacks
cd homelab
# Si este repo de docs ya está clonado en otro sitio, elegir uno (ver más abajo).
git init -b main
cat > .gitignore <<'EOF'
# Secretos: nunca deben estar en git.
.env
.env.local
*.key
*.pem
*.crt
EOF
git add .gitignore
git commit -m "chore: bootstrap stacks repo"
```

> **Sobre la coexistencia con este repo de documentación**: hay dos patrones válidos.
> 1. **Mismo repo**: `~/homelab/` contiene tanto `docs/` como `stacks/`. Es lo más simple y lo que asume este documento.
> 2. **Repos separados**: `~/homelab-docs/` y `~/homelab-stacks/`. Útil si los stacks contienen información sensible que el repo de docs no debería ver. Si se opta por esto, la única diferencia operativa es que las rutas en los ejemplos pasan a `~/homelab-stacks/<stack>/`.

### 2.4. Crear el árbol de datos para un nuevo stack

Plantilla idempotente que cada doc de servicio referenciará:

```bash
# Variables (sustituir).
STACK="dns"

# Stack file (versionado).
mkdir -p ~/homelab/stacks/${STACK}
touch  ~/homelab/stacks/${STACK}/.env.example

# Datos persistentes (no versionado).
sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/services/${STACK}
sudo install -m 600 -o homelab -g homelab /dev/null /mnt/hd2t/services/${STACK}/.env

# Subdirectorios concretos los crea el doc del servicio (config/, data/, db/, ...).
```

---

## 3. Convenciones de nombres

Estas convenciones son la base sobre la que [`../03-red/04-caddy.md`](../03-red/04-caddy.md) (DNS interno), [`../05-monitorizacion/01-prometheus.md`](../05-monitorizacion/01-prometheus.md) (targets) y [`../12-dashboards/01-homepage.md`](../12-dashboards/01-homepage.md) (etiquetas) construirán sus configuraciones.

### 3.1. Nombre del proyecto Compose (`name:`)

```yaml
name: dns          # = nombre del directorio en ~/homelab/stacks/<stack>/
```

- Solo minúsculas y guiones (Compose normaliza igualmente, pero mejor explícito).
- Se usa como prefijo en redes y volúmenes anónimos. No se usa como prefijo de `container_name` porque este lo fijamos a mano.

### 3.2. `container_name`

```yaml
container_name: pihole
```

- **Coincide con el nombre canónico del servicio** (`pihole`, `unbound`, `caddy`, `jellyfin`, `sonarr`, `prometheus`, `grafana`, `node-exporter`, `cadvisor`...).
- Sin sufijos numéricos (no se replica nada en este homelab).
- Sin prefijo de stack: el container se buscará por su nombre desde Caddy, Pi-hole DNS y Dozzle.
- Excepciones: cuando un mismo stack tiene dos instancias del mismo servicio (raro: `redis` para Authelia y `redis` para Nextcloud son stacks distintos, no hay colisión).

### 3.3. Hostname interno

Compose usa `container_name` como hostname dentro de la red Docker. No hace falta declarar `hostname:` salvo casos especiales (servicios que muestran `hostname` en su UI, p. ej. Vaultwarden).

### 3.4. Redes

| Tipo | Nombre | Driver | Quién la crea |
|---|---|---|---|
| Red interna del stack | `<stack>_internal` (ej. `nextcloud_internal`) | `bridge` | El propio `docker-compose.yml` (no `external`) |
| Red compartida del homelab | `homelab` | `bridge` | Una sola vez, fuera de los stacks (§4); todos los stacks la referencian como `external: true` |
| Red macvlan para servicios con IP propia | `lan_macvlan` | `macvlan` | [`../03-red/01-macvlan.md`](../03-red/01-macvlan.md) |

### 3.5. Volúmenes y bind mounts

- **Bind mounts** son la regla por defecto: rutas absolutas bajo `/mnt/hd2t/services/<stack>/<subdir>/`.
- **Named volumes** solo para datos efímeros que no se respaldan (p. ej. cache de Caddy si así lo decide su doc).
- Subdirectorios típicos por servicio: `config/`, `data/`, `db/`, `cache/`, `logs/`. La estructura fina la decide cada doc de servicio.

### 3.6. Etiquetas (`labels`) reservadas

| Label | Para qué | Origen |
|---|---|---|
| `com.centurylinklabs.watchtower.enable=true` | Marca el contenedor como gestionado por Watchtower | [`./04-watchtower.md`](./04-watchtower.md) |
| `com.centurylinklabs.watchtower.enable=false` | Excluye un contenedor de Watchtower (BD, Pi-hole...) | [`./04-watchtower.md`](./04-watchtower.md) |
| `caddy.*` | Metadatos consumidos por la generación del `Caddyfile` (si se opta por configuración por labels) | [`../03-red/04-caddy.md`](../03-red/04-caddy.md) |
| `homepage.group=...` / `homepage.name=...` / `homepage.icon=...` / `homepage.href=...` | Auto-descubrimiento por Homepage | [`../12-dashboards/01-homepage.md`](../12-dashboards/01-homepage.md) |
| `prometheus.scrape=true` / `prometheus.port=9100` | Targets autodetectables (si se usa SD basado en labels) | [`../05-monitorizacion/01-prometheus.md`](../05-monitorizacion/01-prometheus.md) |

> Las labels `caddy.*`, `homepage.*` y `prometheus.*` son una **convención del homelab**, no estándares; cada doc fijará su forma exacta. Importante: **no chocan** entre sí (namespaces distintos).

---

## 4. Red Docker compartida `homelab`

### 4.1. Por qué hace falta una red compartida

Compose crea por defecto una red por proyecto. Los contenedores del stack `nextcloud` no pueden, por DNS, alcanzar a los del stack `proxy` (Caddy) salvo que:

1. Se publiquen puertos en el host (`ports: 11000:80`) → contamina el firewall, expone el servicio al *bridge* `docker0` y rompe la idea de "todo detrás de Caddy".
2. Se conecten ambos a una misma red declarada **fuera** de cada stack → es lo que hace la red `homelab`.

La red `homelab` cumple:

- **Resolución por nombre** entre stacks: `caddy` puede hacer `proxy_pass http://nextcloud:11000` por DNS interno de Docker.
- **Aislamiento** del host: el tráfico no sale por `docker0` ni por una IP del host, vive dentro de la red bridge.
- **Selectividad**: solo se conectan a `homelab` los servicios que tienen que ser alcanzables externamente (a través de Caddy) o monitorizables (por Prometheus). Las BD y caches **no** se conectan a `homelab` y permanecen aisladas en la red interna del stack.

### 4.2. Crear la red `homelab` (una sola vez)

```bash
docker network create \
  --driver bridge \
  --subnet 172.20.0.0/24 \
  --gateway 172.20.0.1 \
  --opt com.docker.network.bridge.name=br-homelab \
  homelab
```

| Opción | Por qué |
|---|---|
| `--driver bridge` | Igual que la red por defecto de Compose, sin sorpresas. |
| `--subnet 172.20.0.0/24` | IP estable y previsible; cabe en el `default-address-pools` del demonio. 254 IPs son de sobra para los ~50 contenedores del homelab. |
| `--gateway 172.20.0.1` | Explícito; coincide con el primer host de la subred. |
| `--opt com.docker.network.bridge.name=br-homelab` | Nombra la interfaz en `ip link` como `br-homelab` en lugar del autogenerado `br-xxxxxxxx`. Útil para inspeccionar tráfico con `tcpdump -i br-homelab`. |

Verificar:

```bash
docker network inspect homelab \
  --format '{{(index .IPAM.Config 0).Subnet}} | bridge={{index .Options "com.docker.network.bridge.name"}}'
# Esperado: 172.20.0.0/24 | bridge=br-homelab
```

### 4.3. Cómo la usan los stacks

Cada `docker-compose.yml` la declara como `external` y se la asigna a los servicios que la necesitan:

```yaml
services:
  caddy:
    # ...
    networks:
      - homelab            # única red de Caddy: solo enrutador

  nextcloud:
    # ...
    networks:
      - nextcloud_internal # accede a MariaDB y Redis
      - homelab            # alcanzable por Caddy

  nextcloud-db:
    # ...
    networks:
      - nextcloud_internal # NO en homelab: la BD es invisible al resto

networks:
  homelab:
    external: true
  nextcloud_internal:
    driver: bridge
```

**Regla**: una BD/cache nunca se conecta a `homelab` salvo que la consuma un servicio fuera de su stack (p. ej. el Redis de Authelia, que sirve a otros).

### 4.4. Comportamiento de `external: true`

- Si la red **no existe** y el `docker-compose.yml` la declara `external: true`, `docker compose up` falla con `network homelab declared as external, but could not be found`.
- Eso es **deseado**: garantiza que la red se crea conscientemente y no por una pelusa de YAML.
- El paso de creación de la red se ejecuta **una sola vez** durante el bootstrap del homelab y queda documentado en [`../03-red/01-macvlan.md`](../03-red/01-macvlan.md) como dependencia previa al primer `docker compose up`.

---

## 5. Variables de entorno (`.env`)

### 5.1. Modelo de dos ficheros

| Fichero | Ubicación | En git | Contenido |
|---|---|---|---|
| `.env.example` | `~/homelab/stacks/<stack>/.env.example` | **Sí** | Plantilla con todas las claves esperadas y **valores ficticios** o vacíos |
| `.env` | `/mnt/hd2t/services/<stack>/.env` | **No** (`.gitignore` ya lo excluye) | Valores reales: contraseñas, tokens, dominios, UID/GID |

El `docker-compose.yml` apunta al `.env` real con ruta absoluta:

```yaml
services:
  pihole:
    env_file:
      - /mnt/hd2t/services/dns/.env
```

> **Compose y `.env` automático**: Compose **también** carga, sin pedirlo, un fichero `.env` que esté **junto al `docker-compose.yml`**. En este homelab **no** queremos eso (los secretos no deben vivir en el repo de stacks): dejar `~/homelab/stacks/<stack>/` sin `.env` (solo con `.env.example`) y forzar el path absoluto con `env_file:`.

### 5.2. Variables comunes a todos los stacks

Convención mínima que todo `.env` del homelab incluye:

```dotenv
# UID/GID del operador (definidos en Fase 1).
PUID=1000
PGID=1000

# Zona horaria.
TZ=Europe/Madrid

# Dominio interno (resuelto por Pi-hole) y dominio Tailscale.
LAN_DOMAIN=lan
TS_DOMAIN=tailnet.ts.net
```

Servicios multimedia añaden `PGID=1100` (grupo `media`) en lugar de `1000`. Está documentado por servicio en la Fase 9 y 10.

### 5.3. Crear el `.env` real con permisos correctos

```bash
STACK="dns"
sudo install -m 600 -o homelab -g homelab \
  ~/homelab/stacks/${STACK}/.env.example \
  /mnt/hd2t/services/${STACK}/.env
# Editar como homelab (no sudo, para no romper la propiedad).
nano /mnt/hd2t/services/${STACK}/.env
```

`0600 homelab:homelab`: solo el operador lee/escribe. El demonio Docker corre como `root` y siempre puede leer.

### 5.4. Buenas prácticas de `.env`

| Regla | Por qué |
|---|---|
| Sin espacios alrededor del `=` | `KEY=value` (no `KEY = value`) → algunas implementaciones lo trataban como literal con espacios. |
| Comillas solo si el valor lleva espacios o `#` | `MOTD="hello world"`. Comillas innecesarias acaban llegando dentro del contenedor. |
| Nada de variables expandidas (`KEY=$OTHER`) | Compose **no** expande variables de un `env_file`; sí lo hace con las definidas en el shell antes de `up`. Para evitar sorpresas, se ponen valores literales. |
| Una clave por línea | Multilínea no soportada por la mayoría de readers de `.env`. |
| No reutilizar `.env` entre stacks | Cada stack tiene el suyo. Reusar facilita filtraciones cruzadas y "qué stack lee qué clave". |
| Comentar el origen de cada secreto | `# admin password: generado con 'openssl rand -base64 24' el 2026-01-15` → futuro yo lo agradecerá durante un DR. |

### 5.5. Generación de secretos

Estándar para todos los `.env` del homelab:

```bash
# Contraseñas / tokens (32 bytes base64, ~44 chars).
openssl rand -base64 32

# JWT secrets / claves hex (64 chars hex).
openssl rand -hex 32
```

Guardar fuera del homelab (en una bóveda, p. ej. Vaultwarden una vez desplegado en [`../11-productividad/01-vaultwarden.md`](../11-productividad/01-vaultwarden.md)) **antes** de pegarlos en el `.env`.

---

## 6. Plantilla base de `docker-compose.yml`

Plantilla mínima asumida por el resto de fases. Cada doc de servicio la **especializa** (puertos, imagen, healthcheck propio) sin tocar las opciones por defecto.

```yaml
# ~/homelab/stacks/<stack>/docker-compose.yml
name: <stack>

services:
  <servicio>:
    image: <repo>/<imagen>:<tag-fijo>     # nunca 'latest' en producción
    container_name: <servicio>
    hostname: <servicio>
    restart: unless-stopped
    user: "${PUID}:${PGID}"               # solo si la imagen lo soporta
    env_file:
      - /mnt/hd2t/services/<stack>/.env
    environment:
      TZ: ${TZ}
    volumes:
      - type: bind
        source: /mnt/hd2t/services/<stack>/<servicio>/config
        target: /config
        bind:
          create_host_path: false
      - type: bind
        source: /mnt/hd2t/services/<stack>/<servicio>/data
        target: /data
        bind:
          create_host_path: false
    networks:
      - <stack>_internal
      - homelab                           # solo si tiene que ser alcanzable
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL                               # añadir solo lo imprescindible vía cap_add
    read_only: false                      # poner true cuando el doc del servicio lo permita
    tmpfs:
      - /tmp:size=64M,mode=1777            # si read_only:true, tmpfs para /tmp
    healthcheck:
      test: ["CMD", "<comando-de-salud>"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s
    labels:
      com.centurylinklabs.watchtower.enable: "true"
      homepage.group: "<grupo>"
      homepage.name: "<servicio>"
      homepage.icon: "<icono>.png"
      homepage.href: "https://<servicio>.${LAN_DOMAIN}"

networks:
  <stack>_internal:
    driver: bridge
  homelab:
    external: true
```

### 6.1. Por qué cada bloque

- **`image:` con tag fijo** (no `latest`): hace el despliegue determinista y compatible con Watchtower (que actualiza si hay nueva digest del **mismo** tag, p. ej. `2.10`). `latest` rompe rollback y dificulta diagnóstico de cambios.
- **`container_name`**: ya justificado en §3.2.
- **`restart: unless-stopped`**: ya justificado en la tabla de decisiones.
- **`user: "${PUID}:${PGID}"`**: ejecuta el proceso como `homelab:homelab` (o `homelab:media`) en lugar de `root`. Imprescindible para que los bind mounts a `/mnt/hd2t/services/<stack>/...` queden con la propiedad correcta.
- **`env_file` con ruta absoluta**: §5.1.
- **`volumes` en formato largo + `bind.create_host_path: false`**: Compose **no** crea silenciosamente directorios en el host; si la ruta no existe, falla. Esto cazaría el típico error de escribir `dat` en lugar de `data` y acabar con un `dat/` vacío con propietario `root`.
- **`networks`**: §3.4 y §4.
- **`security_opt: no-new-privileges:true`**: bloquea `setuid`/`setgid` de procesos hijos. Sin coste para servicios bien empaquetados.
- **`cap_drop: ALL`**: punto de partida sin capacidades; cada servicio añade las que necesita (`NET_BIND_SERVICE` para procesos en puertos < 1024, `CHOWN`/`SETUID`/`SETGID` para imágenes que cambian de usuario al arrancar).
- **`healthcheck`**: con healthcheck, `docker compose ps` y `docker ps` muestran `(healthy)`/`(unhealthy)`, lo que `depends_on: condition: service_healthy` y Uptime Kuma pueden consumir.
- **`labels`**: integración con Watchtower, Homepage y Prometheus (§3.6).

### 6.2. Lo que **no** está en la plantilla y se sobreescribe en cada doc

| Bloque | Cuándo lo añade el doc del servicio |
|---|---|
| `ports:` | Solo Caddy (80, 443) y Pi-hole (53). El resto se enrutan vía la red `homelab`. |
| `depends_on:` | Cuando hay servicios fuertemente acoplados dentro del mismo stack (Nextcloud → MariaDB). |
| `cap_add:` | Servicios que lo necesitan documentadamente (Pi-hole: `NET_ADMIN`, `SYS_TIME`...). |
| `devices:` | Zigbee2MQTT (`/dev/ttyUSB0`), Jellyfin (transcodificación HW). |
| `network_mode: host` | Tailscale, si se opta por el modo host. |
| `mem_limit:` / `cpus:` | Servicios "habladero" o pesados; estrategia general en [`../13-operaciones/03-rendimiento-pi5.md`](../13-operaciones/03-rendimiento-pi5.md). |

### 6.3. Comandos de operación canónicos

```bash
# Validar el YAML y ver la config interpolada (con .env aplicado).
cd ~/homelab/stacks/<stack>
docker compose --env-file /mnt/hd2t/services/<stack>/.env config

# Levantar (idempotente).
docker compose up -d

# Ver estado del stack.
docker compose ps

# Logs (tail en vivo).
docker compose logs -f --tail=100

# Parar sin borrar (respeta `unless-stopped` hasta el próximo `up -d`).
docker compose stop

# Parar y borrar contenedores (no borra volúmenes named ni bind mounts).
docker compose down

# Forzar recreación tras cambio de imagen/env.
docker compose up -d --force-recreate

# Solo recrear un servicio del stack.
docker compose up -d --force-recreate <servicio>
```

> Nótese el `--env-file /mnt/hd2t/services/<stack>/.env` solo en `docker compose config`: para `up/down` no hace falta porque `env_file:` dentro del YAML ya lo carga al crear cada contenedor. La excepción es si el YAML usa **interpolación de variables** (`${VAR}`) en el propio `docker-compose.yml`: en ese caso, Compose necesita las variables al **parsear**, y para eso sí hay que invocar con `--env-file` o con un `.env` junto al YAML. Como en este homelab evitamos `.env` junto al YAML, **toda interpolación en el YAML se hace pasando `--env-file`**.

---

## 7. Verificación

### 7.1. Comprobaciones tras crear la red `homelab`

```bash
docker network ls --filter name=homelab --format 'table {{.Name}}\t{{.Driver}}\t{{.Scope}}'
# Esperado:
# NAME      DRIVER    SCOPE
# homelab   bridge    local

ip -br addr show br-homelab
# Esperado: br-homelab    UP    172.20.0.1/24

docker network inspect homelab \
  --format '{{(index .IPAM.Config 0).Subnet}}'
# Esperado: 172.20.0.0/24
```

### 7.2. Validar un `docker-compose.yml` antes de `up`

```bash
cd ~/homelab/stacks/<stack>
docker compose --env-file /mnt/hd2t/services/<stack>/.env config >/dev/null \
  && echo "Compose OK"
```

`config` resuelve interpolaciones, valida el esquema y devuelve no-cero si hay error. Si imprime warnings (p. ej. `the attribute 'version' is obsolete`), corregirlos.

### 7.3. Smoke test con un servicio mínimo

Probar la red compartida y la convención de bind mount con un contenedor desechable:

```bash
mkdir -p /tmp/whoami-test
cat > /tmp/whoami-test/docker-compose.yml <<'EOF'
name: whoami-test

services:
  whoami:
    image: traefik/whoami:v1.10
    container_name: whoami
    restart: "no"
    networks:
      - homelab
    security_opt:
      - no-new-privileges:true

networks:
  homelab:
    external: true
EOF

cd /tmp/whoami-test
docker compose up -d
docker run --rm --network homelab curlimages/curl:8.10.1 -s http://whoami:80 \
  | head -3
# Esperado: cabecera "Hostname: whoami" y "IP: 172.20.0.x"
docker compose down
rm -rf /tmp/whoami-test
```

> El stack desechable demuestra: (a) red `homelab` operativa, (b) DNS interno por `container_name`, (c) un contenedor de un stack puede alcanzar a otro por su nombre.

### 7.4. Lista de Verificación

Antes de pasar a [`03-portainer.md`](./03-portainer.md):

- [ ] Existe `~/homelab/stacks/` y es propiedad de `homelab:homelab` con permisos `750`.
- [ ] Existe `~/homelab/.gitignore` que excluye `.env`, `.env.local`, `*.key`, `*.pem`, `*.crt`.
- [ ] `git -C ~/homelab status` no lista ningún `.env` como untracked.
- [ ] Existe `/mnt/hd2t/services/` propiedad de `homelab:homelab` con permisos `750`.
- [ ] `docker network ls` lista la red `homelab` con driver `bridge` y scope `local`.
- [ ] `docker network inspect homelab` muestra subred `172.20.0.0/24` y `bridge=br-homelab`.
- [ ] `ip -br link show br-homelab` la muestra `UP`.
- [ ] `docker compose --version` ≥ `v2.x`.
- [ ] El smoke test de §7.3 imprime el `Hostname: whoami` y se limpia sin dejar contenedores ni redes huérfanas.
- [ ] Plantilla base aceptada y referenciada por todos los docs de servicios pendientes (Fases 3 a 13).

---

## 8. Solución de Problemas

| Síntoma | Causa probable | Acción |
|---|---|---|
| `docker compose up` falla con `network homelab declared as external, but could not be found` | La red compartida no existe todavía. | Crear la red (§4.2). Es un paso **único** en el bootstrap del homelab. |
| `docker compose up` falla con `Pool overlaps with other one on this address space` | Otra red ya ocupa `172.20.0.0/24` (p. ej. una creada manualmente con la misma subred). | `docker network ls` y `docker network inspect <id>` para localizar la colisión; eliminar la red espuria o reasignar la subred de `homelab` (cambiar también §4.2 en este doc). |
| `docker compose config` imprime `WARN: The "X" variable is not set` | Interpolación `${X}` en el YAML pero la variable no está en el shell ni en el `.env` referenciado. | Pasar `--env-file /mnt/hd2t/services/<stack>/.env` al invocar `docker compose`, o añadir la variable al `.env`. |
| Compose imprime `WARN: the attribute 'version' is obsolete` | Hay un `version: "3.x"` heredado de un copy-paste antiguo. | Eliminar la línea `version:`; Compose v2 no la necesita. |
| Bind mount crea un directorio inesperado en el host con propietario `root` | El path no existía y `bind.create_host_path` está implícito en `true`. | Añadir `bind.create_host_path: false` en el bloque `volumes:` para que falle ruidosamente; crear el directorio con `install -d -o homelab -g homelab -m 750 ...` antes de `up`. |
| Servicio escribe ficheros con propietario `root:root` | El contenedor corre como `root` (la imagen no respeta `user:`). | Comprobar la docs de la imagen: si soporta `PUID/PGID` por env, usarlos; si solo soporta `user:` y la imagen es `root`, valorar otra imagen o aceptar el coste. |
| Caddy no resuelve `nextcloud` | Caddy está en la red `homelab` pero `nextcloud` solo está en `nextcloud_internal`. | Añadir `homelab` a las `networks` de `nextcloud` (no de la BD). |
| `homelab` aparece duplicado en `docker network ls` (p. ej. `homelab` y `<stack>_homelab`) | Algún `docker-compose.yml` declara `homelab:` sin `external: true`. | En cada YAML que use la red compartida, asegurarse de tener `homelab: { external: true }` en el bloque `networks:`. |
| Cambios en `.env` no se reflejan tras `docker compose up -d` | Compose ve el contenedor como "sin cambios" (la imagen y el YAML son los mismos). | `docker compose up -d --force-recreate <servicio>`. Si solo cambia una variable interpolada en el YAML, Compose sí lo detecta. |
| `git status` lista un `.env` que no debería estar versionado | El `.gitignore` está mal escrito o el `.env` se añadió antes de crear el ignore. | `git rm --cached <ruta>/.env`, comprobar `.gitignore`, commitear. **Rotar el secreto** que haya quedado en el histórico. |
| Contenedor en `homelab` pierde conectividad tras `docker network prune` | `prune` borra redes no usadas; si todos los stacks estaban parados, `homelab` también. | Recrear la red (§4.2); para evitarlo, añadir un contenedor "long-lived" en `homelab` (Caddy ya lo hará una vez desplegado) o no ejecutar `prune` sin `--filter "label!=...". |
| Logs por contenedor no rotan | El servicio sobreescribe `logging:` con `none` o ilimitado. | Quitar el override; el default de `daemon.json` (10 MB × 3) debe heredarse. |

---

## Referencias

- [Compose Specification — Networks (top-level y per-service)](https://github.com/compose-spec/compose-spec/blob/main/06-networks.md)
- [Compose Specification — `external` networks](https://github.com/compose-spec/compose-spec/blob/main/06-networks.md#external)
- [Docker Compose — Environment variables in Compose](https://docs.docker.com/compose/environment-variables/)
- [Docker Compose — Use a `.env` file](https://docs.docker.com/compose/environment-variables/env-file/)
- [Docker — `docker network create` (`--subnet`, `--opt bridge.name`)](https://docs.docker.com/reference/cli/docker/network/create/)
- [Docker — Bind mounts (`bind.create_host_path`)](https://docs.docker.com/storage/bind-mounts/)
- [Docker — Container restart policies (`unless-stopped`)](https://docs.docker.com/config/containers/start-containers-automatically/)
- [Docker — Healthchecks en Compose](https://docs.docker.com/reference/compose-file/services/#healthcheck)
- [Docker — Runtime security (`no-new-privileges`, capabilities)](https://docs.docker.com/engine/security/)
- [LinuxServer.io — Understanding PUID and PGID](https://docs.linuxserver.io/general/understanding-puid-and-pgid/)
- [Watchtower — Filtering by labels (`com.centurylinklabs.watchtower.enable`)](https://containrrr.dev/watchtower/container-selection/)
