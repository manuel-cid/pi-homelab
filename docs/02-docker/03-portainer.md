# Portainer CE

## Descripción

Despliegue de **Portainer Community Edition** como panel web para **inspeccionar** el motor Docker del homelab: ver contenedores, imágenes, redes, volúmenes y _logs_ desde el navegador, lanzar `exec` puntuales, parar/arrancar servicios sin SSH y revisar los _stacks_ que ya están definidos en `~/homelab/`. Portainer es la primera _UI_ de operación que se monta — todo lo posterior (Caddy, Pi-hole, Authelia…) gana mucha legibilidad cuando ya hay un sitio donde "ver lo que está pasando".

Este documento estrena además el _stack_ **`infra`** (`~/homelab/infra/`), el contenedor de los servicios "transversales" del homelab. Junto a Portainer se despliega un **`docker-socket-proxy`** (Tecnativa) por el que pasarán **todos** los servicios que necesiten hablar con el _socket_ de Docker (Portainer ahora; Watchtower, Dozzle… en fases siguientes). El _socket_ no se vuelve a montar directamente en ningún contenedor a partir de este punto.

> **Alcance**: este documento despliega Portainer **y** el _socket-proxy_ que comparte el _stack_ `infra`. **No** instala Watchtower (`docs/02-docker/04-watchtower.md`), **no** define `Caddyfile` (`docs/03-red/04-caddy.md`) ni TLS, **no** integra con Authelia (`docs/04-seguridad/01-authelia.md`) y **no** publica nada en la LAN. Durante la fase 2, Portainer se accede vía **túnel SSH** desde el equipo del usuario; el _bind_ al _front_ HTTP queda restringido a `127.0.0.1` en la Pi.

> **Recordatorio de red**: el _stack_ `infra` se engancha a la red Docker `homelab` (creada en `docs/02-docker/02-estructura-compose.md`) para que servicios externos al _stack_ puedan invocar la API de Portainer si fuera necesario (Homepage, _scrapers_ Prometheus). El único puerto publicado al host es `127.0.0.1:9000` para el _bootstrap_; cuando Caddy esté operativo, ese `ports:` se elimina y el acceso se hace por nombre DNS (`portainer.lan`, `portainer.<tailnet>.ts.net`).

---

## Requisitos previos

- `docs/02-docker/01-instalacion-docker.md` completado: `docker` y `docker compose v2` operativos sin `sudo` para el usuario `homelab`, `data-root` en `/mnt/hd2t/system/docker`, `live-restore` activo.
- `docs/02-docker/02-estructura-compose.md` completado: `~/homelab/` con `.env`, `.env.example`, `.gitignore`, `Makefile`, repo git inicializado y red `homelab` (`172.20.10.0/24`, _bridge_ `br-homelab`) creada.
- `docs/01-sistema/04-estructura-directorios.md` completado: la rama `/mnt/hd2t/services/` existe con `root:root 0755`. La sub-rama `portainer/` está prevista pero puede no estar aún creada (este documento la termina de poblar).
- Acceso SSH al usuario `homelab` desde el portátil del usuario, **con _client config_ que permita _local port forwarding_** (`AllowTcpForwarding yes` por defecto en OpenSSH, no se ha tocado en `docs/01-sistema/03-seguridad-base.md`).
- Conectividad saliente: el _pull_ de la imagen `portainer/portainer-ce` desde Docker Hub debe funcionar. Comprobar:

  ```bash
  docker pull --platform linux/arm64 portainer/portainer-ce:2.21.5 >/dev/null && echo OK
  ```

  Si el _pull_ falla, revisar DNS (`resolvectl status`) y la cadena `output` del firewall antes de seguir.

---

## Por qué Portainer y no `docker` a secas

`docker ps`, `docker logs`, `docker exec`… cubren el 95 % de la operación diaria desde una _shell_. Tres cosas que sí aporta Portainer en este homelab y que justifican el contenedor extra:

1. **Vista agregada**. Permite ver de un golpe los ~30 contenedores con su estado, los _logs_ del último arranque, las redes a las que están enganchados y los _volumes_ montados. Diagnosticar por qué Sonarr no ve los _media files_ es trivial cuando se ven los _binds_ uno al lado del otro.
2. **Acceso desde el móvil/tablet**. Cuando algo falla y no hay un portátil a mano, una UI web por Tailscale es mucho más cómoda que SSH desde el _phone_. El homelab vive en casa, pero la operación no siempre es desde casa.
3. **Onboarding**. En el momento en el que otra persona (pareja, _housemate_) tenga que reiniciar Jellyfin porque "no se ve la película", una UI con un botón "Restart" es una garantía de que no se borra accidentalmente el _stack_ entero.

Lo que **no** se delega a Portainer:

- **No** se editan ni se crean _stacks_ desde su UI. La fuente de verdad son los `docker-compose.yml` versionados en `~/homelab/`. Portainer detecta los _stacks_ creados con `docker compose` y los muestra como "limited control" — ese modo de sólo lectura es exactamente el que se quiere: parar, arrancar, ver _logs_, pero no modificar.
- **No** se gestionan secretos a través de Portainer. Los `.env` siguen viviendo en disco con permisos `0600`.
- **No** se añaden _endpoints_ remotos. Sólo se administra el _socket_ del propio host (un único _endpoint_ "local").

---

## Cómo accede Portainer al _socket_ de Docker — `docker-socket-proxy`

El compromiso técnico de `docs/02-docker/01-instalacion-docker.md` (sección 4.1) dice: _"Cualquier servicio que necesite acceso al socket lo recibirá vía proxy en su propio doc de fase"_. Toca cumplirlo aquí.

Portainer necesita un _socket_ Docker para casi todo lo que hace (listar contenedores, leer _logs_, lanzar `exec`, hacer `pull` de imágenes…). Las dos opciones reales son:

- **Montar `/var/run/docker.sock` directamente en el contenedor** (el patrón "tradicional"). Sencillo, pero da al contenedor **control total** sobre el _daemon_: cualquier RCE en Portainer equivale a `root` en la Pi.
- **Interponer un proxy** ([Tecnativa/docker-socket-proxy](https://github.com/Tecnativa/docker-socket-proxy)) que sólo expone los _endpoints_ HTTP de la API que cada servicio necesita. Portainer habla TCP a `docker-socket-proxy:2375`; el _socket_ Unix sólo se monta en el _proxy_, no en Portainer ni en los servicios subsiguientes.

El homelab adopta la segunda. Beneficios concretos:

- Un futuro CVE en Portainer **no** otorga acceso a `docker swarm join`, `docker rm`, ni a _endpoints_ administrativos que no se han habilitado explícitamente.
- Watchtower y Dozzle, en las fases siguientes, reusarán el **mismo** _proxy_ y se les concederán sus propios _endpoints_ por separado (Watchtower: `IMAGES`, `CONTAINERS`, `POST`, `DELETE`; Dozzle: `CONTAINERS`, `EVENTS`). El permiso es _per-endpoint_, no _per-container_.
- El `docker-compose.yml` del _stack_ `infra` deja totalmente claro qué tiene permiso para qué — auditable de un vistazo.

> **Permisos definidos aquí**: este documento habilita en el _proxy_ los _endpoints_ que necesita Portainer (suficientes para administrar contenedores, imágenes, redes, volúmenes y ejecutar `exec`). Las fases `04-watchtower.md` y `05-monitorizacion/06-dozzle.md` añadirán los _endpoints_ que les falten editando el `environment:` del _proxy_ y reiniciándolo.

---

## Estructura del _stack_ `infra`

Tal como se acordó en `docs/02-docker/02-estructura-compose.md` (tabla de _stacks_), `~/homelab/infra/` agrupa Portainer, el _socket-proxy_, Watchtower y Dozzle. Tras este documento queda así:

```
~/homelab/infra/
├── docker-compose.yml
├── .env
└── .env.example
```

Crear el subdirectorio (la rama `infra/` aún no existía):

```bash
mkdir -p ~/homelab/infra
chmod 0750 ~/homelab/infra
```

Y el _bind_ en el disco para los datos de Portainer:

```bash
sudo install -d -o homelab -g homelab -m 0750 /mnt/hd2t/services/portainer/data
```

> Permisos `0750 homelab:homelab`: Portainer corre como `root` dentro del contenedor (es el comportamiento por defecto de la imagen oficial), pero sólo escribe en `/data`. Restringir el _host_ a `homelab:homelab 0750` evita que otros usuarios del sistema (si los hubiera) lean el fichero `portainer.db`, que contiene el _hash_ de la contraseña del admin y los _tokens_ de la API.

---

## Variables de entorno (`infra/.env` e `infra/.env.example`)

`infra/.env.example` (versionado en git, sin valores reales):

```bash
# ~/homelab/infra/.env.example
# Plantilla — copiar a infra/.env y rellenar.

# Tags de imagen pinneados (no usar 'latest' — convención del homelab).
PORTAINER_IMAGE_TAG=2.21.5
SOCKET_PROXY_IMAGE_TAG=0.3.0

# Hash bcrypt de la contraseña del admin de Portainer.
# Generar con:  docker run --rm httpd:2.4-alpine htpasswd -nbB admin 'CONTRASEÑA' | cut -d ':' -f2
# Importante: las dos signos $$ del hash bcrypt deben escaparse a $$$$ en el .env (Compose interpreta $).
PORTAINER_ADMIN_PASSWORD_HASH=
```

`infra/.env` (a partir del _example_; **no** se _commitea**):

```bash
cd ~/homelab/infra
cp .env.example .env
chmod 0600 .env
```

Generar el _hash_ del admin antes del primer `up` (la imagen `httpd` se descarta tras imprimir el _hash_):

```bash
docker run --rm httpd:2.4-alpine \
    htpasswd -nbB admin 'CAMBIAR_ESTA_CLAVE' \
    | cut -d ':' -f2
# Salida ejemplo:
# $2y$05$Xq...mhJ6zH1Zv0w8t.4eVO2zI6m
```

Copiar la cadena a `PORTAINER_ADMIN_PASSWORD_HASH` **escapando los `$`** a `$$` (Compose hace expansión de variables: si se deja un solo `$`, se intentará resolver `$2y$...` como variable y se quedará vacío). Ejemplo:

```bash
# original (httpd lo imprime así):
$2y$05$Xq...mhJ6zH1Zv0w8t.4eVO2zI6m
# en infra/.env tiene que quedar:
PORTAINER_ADMIN_PASSWORD_HASH=$$2y$$05$$Xq...mhJ6zH1Zv0w8t.4eVO2zI6m
```

> **Por qué se pre-fija la contraseña**: por defecto, Portainer lanza un asistente de creación de admin la primera vez que se accede a la UI y **bloquea** el contenedor pasados 5 minutos sin completar el _setup_ (medida anti-_drive-by_). Pasar el _hash_ por _flag_ (`--admin-password-file`) evita la ventana de carrera y permite re-crear el contenedor desde cero (perdiendo `portainer.db`) sin tener que correr antes a la UI.

> **Por qué `bcrypt`**: es el formato que admite Portainer en `--admin-password-file`. El comando `htpasswd -B` lo genera con coste 5 por defecto; suficiente para una clave fuerte.

---

## `docker-compose.yml` del _stack_ `infra`

Plantilla mínima del _stack_, partiendo de la ya descrita en `docs/02-docker/02-estructura-compose.md`:

```yaml
# ~/homelab/infra/docker-compose.yml
# Convenciones: docs/02-docker/02-estructura-compose.md
# Este stack alberga Portainer + socket-proxy. Watchtower (docs/02-docker/04-watchtower.md)
# y Dozzle (docs/05-monitorizacion/06-dozzle.md) se añaden a este mismo fichero más adelante.

services:

  # ---------------------------------------------------------------------------
  # docker-socket-proxy: única vía de acceso al socket de Docker para los
  # contenedores del homelab. Cada servicio que lo necesite habilita su
  # subconjunto de endpoints en el environment de aquí abajo.
  # ---------------------------------------------------------------------------
  docker-socket-proxy:
    image: tecnativa/docker-socket-proxy:${SOCKET_PROXY_IMAGE_TAG}
    container_name: docker-socket-proxy
    restart: unless-stopped
    privileged: false
    read_only: true
    tmpfs:
      - /run
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    environment:
      # Endpoints habilitados — se añaden flags conforme se incorporen
      # consumidores (Watchtower, Dozzle...). Default de cada uno = 0.
      # Portainer (este doc) necesita:
      CONTAINERS: 1
      IMAGES: 1
      VOLUMES: 1
      NETWORKS: 1
      INFO: 1
      VERSION: 1
      PING: 1
      EVENTS: 1
      EXEC: 1
      SYSTEM: 1
      DISTRIBUTION: 1
      BUILD: 1
      COMMIT: 1
      PLUGINS: 1
      # Métodos HTTP. Portainer es read+write, requiere POST.
      POST: 1
      # DELETE deshabilitado de momento; lo activará 04-watchtower.md
      # (necesita borrar imágenes obsoletas tras actualizar).
      DELETE: 0
      # Endpoints expresamente NO concedidos (Swarm, secrets, configs).
      # Listados en explicit-0 para que la auditoría sea inequívoca:
      AUTH: 0
      SWARM: 0
      NODES: 0
      SERVICES: 0
      TASKS: 0
      SECRETS: 0
      CONFIGS: 0
      SESSION: 0
      # Logging de operaciones bloqueadas para diagnosticar.
      LOG_LEVEL: info
    networks:
      infra-internal:
        aliases:
          - docker-socket-proxy
    labels:
      homelab.stack: "infra"
      homelab.backup: "false"           # sin estado persistente
      com.centurylinklabs.watchtower.enable: "false"

  # ---------------------------------------------------------------------------
  # Portainer CE — UI de administración del motor Docker.
  # Habla con el daemon vía docker-socket-proxy (TCP), no monta el .sock.
  # Acceso de bootstrap por SSH tunnel a 127.0.0.1:9000;
  # cuando Caddy esté operativo (docs/03-red/04-caddy.md), el bloque
  # `ports:` se elimina y queda accesible por https://portainer.lan.
  # ---------------------------------------------------------------------------
  portainer:
    image: portainer/portainer-ce:${PORTAINER_IMAGE_TAG}
    container_name: portainer
    restart: unless-stopped
    depends_on:
      docker-socket-proxy:
        condition: service_started
    command:
      - --host=tcp://docker-socket-proxy:2375
      - --admin-password=${PORTAINER_ADMIN_PASSWORD_HASH}
      - --hide-label=com.docker.compose.project.config_files
    volumes:
      - /mnt/hd2t/services/portainer/data:/data
    ports:
      # Bind sólo a localhost durante el bootstrap (sin TLS aún).
      # Eliminar este bloque cuando Caddy proxye por HTTPS.
      - "127.0.0.1:9000:9000"
    networks:
      - homelab
      - infra-internal
    labels:
      homelab.stack: "infra"
      homelab.backup: "true"            # /data contiene la BD bolt
      com.centurylinklabs.watchtower.enable: "false"
    healthcheck:
      # Portainer expone /api/system/status sin auth desde 2.16+.
      test: ["CMD", "wget", "--quiet", "--tries=1", "--spider", "http://127.0.0.1:9000/api/system/status"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s

networks:
  homelab:
    external: true
  infra-internal:
    driver: bridge
    internal: true                       # sin gateway al exterior, sólo intra-stack
```

Notas de diseño:

- **`infra-internal` con `internal: true`**: el _proxy_ y Portainer hablan por una red **sin _gateway_**. Eso impide que el _proxy_ haga DNS al exterior (no lo necesita) y que un servicio comprometido use esa red para _exfiltrate_. Portainer sí está además en `homelab`, donde tiene salida normal porque necesita poder hacer `pull` de imágenes y consultar registries (todo eso lo hace a través del _proxy_, pero la red `homelab` le da resolución DNS al _gateway_ del bridge de Docker).
- **`read_only: true` + `tmpfs: /run`** en el _proxy_: el contenedor no necesita escribir en su FS salvo a `/run`, donde HAProxy escribe su _pidfile_. Restringirlo cierra una clase entera de _exploits_.
- **`--hide-label=com.docker.compose.project.config_files`**: oculta del UI las _labels_ que Compose añade a los contenedores con la ruta absoluta del `docker-compose.yml`. No es información sensible pero es ruido que ensucia la vista de cada contenedor.
- **`depends_on` con `service_started`** (no `service_healthy`): el _proxy_ no expone _healthcheck_ propio en la imagen oficial; Portainer reintenta solo si la conexión inicial falla.

---

## Primer despliegue

Asumiendo que la red `homelab` ya existe (verificación de `docs/02-docker/02-estructura-compose.md`):

```bash
cd ~/homelab/infra
docker compose --env-file ../.env --env-file .env config | head -40   # validar sintaxis
docker compose --env-file ../.env --env-file .env up -d
```

O, equivalente, con el _Makefile_ del repositorio:

```bash
cd ~/homelab
make up STACK=infra
```

El _pull_ de Portainer (~250 MB descomprimido) puede tardar 1-2 min en una conexión doméstica; el _proxy_ es ~10 MB. Verificar:

```bash
docker compose -f ~/homelab/infra/docker-compose.yml ps
# NAME                  STATUS                   PORTS
# docker-socket-proxy   Up X seconds             2375/tcp
# portainer             Up X seconds (healthy)   8000/tcp, 9000/tcp, 127.0.0.1:9000->9000/tcp, 9443/tcp
```

> Portainer expone tres puertos internos: `8000` (Edge agent, no usado aquí), `9000` (HTTP, usado), `9443` (HTTPS con cert autofirmado, no usado — preferimos que el TLS lo termine Caddy en su momento). Sólo el `9000` se mapea al _host_, y sólo en `127.0.0.1`.

---

## Acceso de _bootstrap_ vía túnel SSH

Caddy aún no existe, no hay TLS y no se quiere exponer `9000` en la LAN sin cifrar (la contraseña del admin viajaría en claro). Hasta `docs/03-red/04-caddy.md`, el acceso se hace **abriendo un túnel SSH** desde el portátil a la Pi:

```bash
# desde el portátil del usuario
ssh -N -L 9000:127.0.0.1:9000 homelab@pi
```

- `-N`: no ejecuta comando remoto, sólo abre el _forward_.
- `-L 9000:127.0.0.1:9000`: el `localhost:9000` del portátil va a `127.0.0.1:9000` de la Pi (donde escucha Portainer).

Con el túnel abierto, en el navegador del portátil: <http://localhost:9000>. La primera carga muestra la pantalla de _login_ (no la pantalla de creación de admin: ya se pasó la contraseña por _flag_). Acceder con `admin` y la clave que se _hasheó_ en `PORTAINER_ADMIN_PASSWORD_HASH`.

> **No** abrir `https://localhost:9443/`: ese _front_ usa un certificado autofirmado distinto en cada despliegue, no aporta seguridad real (el túnel SSH ya está cifrando) y el navegador se queja a perpetuidad. HTTP por túnel SSH es lo correcto en este punto.

> **Cuando Caddy esté operativo**, eliminar el bloque `ports:` del servicio `portainer` y dejar el acceso únicamente vía `https://portainer.lan` o `https://portainer.<tailnet>.ts.net`. El cambio se documentará en `docs/03-red/04-caddy.md`.

---

## Configuración inicial en la UI

Tras el primer login, los pasos a completar (todos en la propia UI de Portainer):

1. **Settings → General**:
   - **App templates URL**: vaciar el campo. No vamos a desplegar nada desde plantillas externas; la fuente de verdad es el repositorio Compose.
   - **Logo**: opcional, dejar el de Portainer.
   - **Hide containers with the following labels**: añadir una entrada con _label_ `homelab.hide` y valor `true`. No se usa todavía pero queda preparado para esconder _sidecars_ ruidosos en el futuro.
   - **Anonymous statistics**: desactivar.

2. **Settings → Authentication**:
   - **Method**: Internal por ahora. La integración con Authelia llega en `docs/04-seguridad/01-authelia.md` (cuando Authelia esté detrás de Caddy).
   - **Sessions**: forzar logout a las **8 h** (vs el _default_ de 24 h). Es una operación administrativa, no se debería estar logueado de fondo.

3. **Environments → local**:
   - Confirmar que aparece **un único** _environment_ llamado `local`, conectado al _proxy_ (`tcp://docker-socket-proxy:2375`), con estado `up`.
   - Click → **Add tag**: añadir tag `pi` (futura discriminación si hubiera más nodos, no la habrá).
   - **NO** añadir _endpoints_ remotos. Si en el futuro se quieren administrar otras Pis, será desde otro Portainer o vía Edge Agent en _doc_ propio.

4. **User-related**:
   - Settings → Users → **Add team**: opcional. En este homelab hay un único admin; se omite hasta tener un segundo usuario real.
   - Settings → Users → admin → **Generate access token**: generar un _token_ con _description_ `homepage-readonly` y guardarlo en `~/homelab/dashboards/.env` (cuando llegue `docs/12-dashboards/01-homepage.md`). De momento se puede saltar.

5. **Stacks**:
   - Aparecerá un único _stack_ "external" llamado `infra` (el que acabamos de desplegar). Portainer lo etiqueta como **"Limited control"** — no se puede editar desde la UI porque fue creado por `docker compose` desde fuera. **Es exactamente el comportamiento que se quiere**: la fuente de verdad es `~/homelab/infra/docker-compose.yml`.

6. **Registries**:
   - Dejar el _default_ `Docker Hub (anonymous)`. No autenticarse contra Docker Hub salvo que se golpeen los _rate limits_ (poco probable en un homelab; si ocurre, se documentará en su día con un _Personal Access Token_, **no** la contraseña de la cuenta).

> **Lo que no se hace en la UI**: crear, modificar o borrar _stacks_ ni contenedores. Toda la edición se hace por git en `~/homelab/<stack>/`. Portainer queda en modo "lectura asistida + acciones reversibles" (start/stop/restart, _exec_ puntual, _logs_).

---

## Almacenamiento

| Ruta en el _host_                        | Contenido                                                  | Permisos             | Backup |
|------------------------------------------|------------------------------------------------------------|----------------------|--------|
| `/mnt/hd2t/services/portainer/data/`     | `portainer.db` (BoltDB), TLS internas, _settings_, _users_ | `0750 homelab:homelab` | Sí     |
| `/mnt/hd2t/services/portainer/data/tls/` | Certificados auto-generados que Portainer usa para 9443    | (gestionado por el contenedor) | No (autogenerado) |

El _socket-proxy_ no tiene almacenamiento persistente (estado en _tmpfs_).

---

## Backup

- **Volumen `data/`** — entra en el ciclo de Borgmatic (`docs/07-backups/02-borgmatic.md`) por la _label_ `homelab.backup: "true"`.
- **Antes de un _upgrade mayor_** de Portainer (por ejemplo, 2.21 → 2.22), copiar `portainer.db`:

  ```bash
  cp /mnt/hd2t/services/portainer/data/portainer.db \
     /mnt/hd2t/backups/portainer/portainer.db.$(date +%Y%m%d-%H%M%S)
  ```

  Portainer **no** tiene migraciones reversibles. Si la nueva versión migra el _schema_ y algo falla, la única vía rápida es restaurar el `.db` previo y volver al _tag_ anterior.
- **Lo que NO se respalda**: `tls/`, regenerable.

---

## Verificación final

Antes de pasar a `docs/02-docker/04-watchtower.md`, comprobar:

- [ ] `docker compose -f ~/homelab/infra/docker-compose.yml ps` muestra `portainer` y `docker-socket-proxy` en estado `Up`. Portainer aparece como `(healthy)` tras ~30 s.
- [ ] `ss -ltn | grep ':9000'` lista exactamente `127.0.0.1:9000` (no `0.0.0.0:9000`). El bind a localhost es la garantía de que nadie en la LAN ve la UI sin pasar por túnel SSH.
- [ ] `docker exec docker-socket-proxy nc -z -v localhost 2375` o `docker exec portainer wget -qO- http://docker-socket-proxy:2375/_ping` devuelve `OK`. La cadena Portainer → proxy → _socket_ funciona.
- [ ] `docker exec docker-socket-proxy nc -z -v localhost 2376 2>&1 | grep -q refused` (`2376` no escucha; sólo el `2375`).
- [ ] Desde el portátil con `ssh -L 9000:127.0.0.1:9000 homelab@pi` activo, <http://localhost:9000> carga la pantalla de _login_, **no** la de creación de admin (eso confirma que el _flag_ `--admin-password` se aplicó).
- [ ] Login con la contraseña original (no el _hash_) funciona. Si pide crear un admin nuevo, el _escape_ de `$$` en el `.env` falló: comprobar `docker exec portainer cat /proc/1/cmdline | tr '\0' '\n' | grep admin-password`.
- [ ] Tras el login, **Environments → local → Containers** lista los dos contenedores (`portainer` y `docker-socket-proxy`).
- [ ] **Stacks** lista exactamente un _stack_ llamado `infra` con etiqueta "Limited control".
- [ ] **Logs** del contenedor `portainer` desde la UI muestra el _stream_ en tiempo real. Esto confirma que Portainer puede leer `/containers/<id>/logs` a través del proxy.
- [ ] Probar **Exec console** sobre `portainer` (consola interactiva): debe abrir un `sh` dentro del contenedor. Esto valida que el _endpoint_ `EXEC` está habilitado.
- [ ] Intentar **Add an environment** desde la UI con un _endpoint_ swarm: debe **fallar** ("403 Forbidden"). Confirma que `SWARM=0` y `NODES=0` en el _proxy_ bloquean lo que tienen que bloquear.
- [ ] `git -C ~/homelab status` muestra como **nuevos**: `infra/docker-compose.yml`, `infra/.env.example`. **No** muestra `infra/.env` (ignorado por la regla del `.gitignore`). _Commit_:

  ```bash
  cd ~/homelab
  git add infra/docker-compose.yml infra/.env.example
  git commit -m "feat(infra): add Portainer CE + docker-socket-proxy"
  ```

- [ ] Tras `sudo reboot`, el contenedor vuelve solo (gracias a `restart: unless-stopped`) y el túnel SSH puede reabrirse sin tocar nada en la Pi.

---

## Troubleshooting

### Portainer arranca y la UI muestra "Creating admin user"

El _flag_ `--admin-password` no se ha aplicado. Causa más común: el `$` del _hash_ bcrypt no estaba duplicado en `infra/.env`. Compose ha sustituido `$2y` por la variable `$2y` (vacía) y la línea de comando del contenedor lleva `--admin-password=$05$...` (truncada). Comprobar:

```bash
docker exec portainer cat /proc/1/cmdline | tr '\0' '\n' | grep -i password
```

Si la cadena no es el _hash_ completo (empieza por `$2y$05$...`), corregir el `.env` (cada `$` → `$$`) y recrear el contenedor:

```bash
docker compose -f ~/homelab/infra/docker-compose.yml up -d --force-recreate portainer
```

> Si ya se completó el asistente con un admin "rogue", parar Portainer, **borrar** `/mnt/hd2t/services/portainer/data/portainer.db` (todavía no hay nada importante dentro) y arrancar de nuevo: el _flag_ se aplicará en el _bootstrap_ de la BD limpia.

### `Error: connection refused` al hablar con `docker-socket-proxy:2375`

El _proxy_ no está enganchado a la misma red que Portainer. Comprobar:

```bash
docker network inspect infra-internal --format '{{range .Containers}}{{.Name}} {{end}}'
# debe listar: docker-socket-proxy portainer
```

Si sólo aparece uno de los dos, revisar la sección `networks:` de cada servicio en el compose. Ambos tienen que pertenecer a `infra-internal`.

### La UI carga pero todo aparece vacío ("No containers")

Permiso del _endpoint_ denegado. Mirar los _logs_ del _proxy_:

```bash
docker logs docker-socket-proxy --tail 50 | grep -i deny
```

Si aparece `403 GET /v1.X/containers/json`, falta `CONTAINERS=1` (o falta `POST=1` si el error es en una acción de escritura). Ajustar el `environment:` y reiniciar el _stack_:

```bash
docker compose -f ~/homelab/infra/docker-compose.yml up -d --force-recreate docker-socket-proxy
```

### `Exec console` se cuelga al abrir

Falta el _endpoint_ `EXEC=1` en el _proxy_, o falta el _flag_ `POST=1` (la API de Docker requiere POST para crear un _exec_). Comprobar ambos. La salida típica del _proxy_ es `403 POST /containers/<id>/exec`.

### Portainer no aparece como `healthy` después de 5 min

El `healthcheck` golpea `http://127.0.0.1:9000/api/system/status`. Causas posibles:

1. La imagen ARM64 está usando un puerto distinto. Confirmar: `docker exec portainer wget -qO- http://127.0.0.1:9000/api/system/status` debe devolver JSON con `Version` y `Edition`.
2. `wget` no está en la imagen (poco probable, _alpine-based_ lo trae). Sustituir por `curl -fsS http://127.0.0.1:9000/api/system/status`.

### El navegador del portátil dice "connection reset" al abrir <http://localhost:9000>

El túnel SSH se ha cerrado. Suele pasar tras una suspensión del portátil. Reabrir el túnel y, si la suspensión es frecuente, añadir `ServerAliveInterval 60` al `~/.ssh/config` para que la conexión se mantenga activa.

### Cómo "desproxyar" temporalmente para diagnosticar

Si se sospecha que el _socket-proxy_ está bloqueando algo legítimo y se quiere descartar, **temporalmente** reemplazar en el _command_ de Portainer:

```yaml
command:
  - --host=unix:///var/run/docker.sock
  - --admin-password=${PORTAINER_ADMIN_PASSWORD_HASH}
```

y montar el _socket_ directamente:

```yaml
volumes:
  - /mnt/hd2t/services/portainer/data:/data
  - /var/run/docker.sock:/var/run/docker.sock:ro
```

Si así funciona, el problema es de _endpoints_ del _proxy_. **Revertir inmediatamente** y ajustar las _flags_; **no** dejar el _socket_ montado directamente como solución permanente.

---

## Referencias

- Portainer CE — Documentación oficial: <https://docs.portainer.io/start/install-ce/server/docker/linux>
- Portainer CE — _Flags_ del binario (`--host`, `--admin-password`, `--hide-label`): <https://docs.portainer.io/admin/environments/add/docker/cli>
- Portainer CE — Imagen `portainer/portainer-ce`: <https://hub.docker.com/r/portainer/portainer-ce>
- Tecnativa — `docker-socket-proxy`: <https://github.com/Tecnativa/docker-socket-proxy>
- Tecnativa — _Endpoints_ y _flags_ disponibles: <https://github.com/Tecnativa/docker-socket-proxy#access-control>
- Docker Engine API — Referencia: <https://docs.docker.com/engine/api/latest/>
- Apache `htpasswd` — Generación de _hash_ bcrypt: <https://httpd.apache.org/docs/2.4/programs/htpasswd.html>
- OpenSSH — _Local port forwarding_ (`-L`): <https://man.openbsd.org/ssh#L>
