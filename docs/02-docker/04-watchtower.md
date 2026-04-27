# Watchtower

## Descripción

Despliegue de **Watchtower** como _daemon_ encargado de mantener al día las imágenes Docker del homelab: cada cierto tiempo consulta los _registries_ de los contenedores en marcha, detecta si hay una _digest_ más reciente para el _tag_ que se está usando, descarga la imagen, recrea el contenedor con la nueva y elimina la antigua. Watchtower no toca la fuente de verdad (los `docker-compose.yml` de `~/homelab/`): trabaja a nivel de motor y, mientras los _tags_ pinneados (`nextcloud:31`, `mariadb:11`, …) sigan siendo los mismos en el compose, lo que actualiza son sólo los _patch releases_ dentro de ese _tag_.

Watchtower es la pieza que cierra el _stack_ **`infra`**: junto a Portainer (UI) y al `docker-socket-proxy` (acceso controlado al motor), aporta la **automatización**. A partir de aquí, los contenedores marcados como _opt-in_ se actualizan solos durante la ventana de mantenimiento; los que no, se quedan exactamente con el _digest_ que tenían hasta que un humano cambie el `docker-compose.yml`.

> **Alcance**: este documento despliega Watchtower **dentro del _stack_ `infra` ya creado en `docs/02-docker/03-portainer.md`** y **amplía** los _endpoints_ habilitados en el `docker-socket-proxy` para concederle lo que necesita (`DELETE` ya pendiente desde la fase anterior). **No** instala _backends_ de notificación (Telegram, email, Apprise…): el _slot_ queda preparado en `infra/.env` y, mientras no se rellene, las novedades sólo se ven en los _logs_ del propio Watchtower. **No** activa el _opt-in_ en ningún servicio existente todavía: el _flag_ `com.centurylinklabs.watchtower.enable=true` se irá poniendo a `true` servicio a servicio cuando cada doc de fase confirme que es seguro auto-actualizarlo.

> **Recordatorio de red**: Watchtower **no** publica puertos. Habla con el motor a través del _proxy_ (`docker-socket-proxy:2375`) por la red interna `infra-internal`. No necesita la red `homelab`.

---

## Requisitos previos

- `docs/02-docker/03-portainer.md` completado: el _stack_ `infra` existe en `~/homelab/infra/`, `docker-socket-proxy` está en marcha en la red `infra-internal` con sus _endpoints_ actuales, Portainer es operativo y `infra/.env` lleva las variables del _stack_ (`PORTAINER_IMAGE_TAG`, `SOCKET_PROXY_IMAGE_TAG`, `PORTAINER_ADMIN_PASSWORD_HASH`).
- `docs/02-docker/02-estructura-compose.md` completado: la convención `com.centurylinklabs.watchtower.enable` como _label_ de _opt-in_ está documentada y por defecto **no** se activa hasta que el doc de cada servicio lo confirme.
- Conectividad saliente: el _pull_ de la imagen `containrrr/watchtower` desde Docker Hub debe funcionar. Comprobar:

  ```bash
  docker pull --platform linux/arm64 containrrr/watchtower:1.7.1 >/dev/null && echo OK
  ```

  Si el _pull_ falla, revisar DNS y la cadena `output` del firewall antes de seguir.

- Reloj del sistema correcto: Watchtower programa los _checks_ por _cron_ y un reloj desfasado provoca ventanas de mantenimiento a horas inesperadas. Comprobar:

  ```bash
  timedatectl status | grep -E 'Time zone|System clock synchronized'
  # debe leerse: Time zone: Europe/Madrid ... ; System clock synchronized: yes
  ```

  Si `synchronized: no`, revisar `chrony`/`systemd-timesyncd` (ver `docs/01-sistema/02-configuracion-inicial.md`).

---

## Por qué Watchtower (y no `apt`-style "actualízalo todo")

Las opciones realistas en este homelab son tres:

1. **Actualización manual periódica** — un sábado al mes, `cd ~/homelab/<stack> && docker compose pull && docker compose up -d` para cada _stack_. Es lo más controlado, pero termina siendo lo que **no se hace**: a las pocas semanas, los CVEs se acumulan.
2. **Diff-Pull-Apply** orquestado externamente (Renovate/Dependabot a nivel de los `docker-compose.yml` o un cron propio que haga `docker compose pull` y reinicie). Requiere infraestructura extra y, sobre todo, asumir _outage_ controlados.
3. **Watchtower** — un _daemon_ que vigila el _registry_ y aplica las actualizaciones disponibles para el _tag_ ya elegido. Sin tocar `docker-compose.yml`, sin pipelines, sin _outage_ humanos.

El homelab adopta **Watchtower con _opt-in_ explícito**:

- Lo seguro por defecto es **no actualizar** automáticamente (`WATCHTOWER_LABEL_ENABLE=true` + ningún servicio con la _label_ activa). Esto convierte a Watchtower en un _watcher_ pasivo que sólo se mueve cuando se le da permiso.
- Servicio a servicio, conforme cada doc de fase confirma "esta imagen es estable y los _patch releases_ se pueden aplicar a ciegas", se añade `com.centurylinklabs.watchtower.enable: "true"` al compose y se _commitea_. Lo opuesto a "todos opt-out salvo BD/Nextcloud/...".
- **Ningún servicio con datos persistentes complejos arranca con _opt-in_**: ni Nextcloud, ni MariaDB, ni Postgres, ni Home Assistant, ni Stash. Esos servicios se actualizan **a mano**, leyendo _release notes_, en una ventana planificada. Watchtower nunca toca un _major bump_ de BD por sorpresa, simplemente porque el `docker-compose.yml` lo pinnea a `mariadb:11` y nunca habrá una `12.x` dentro de ese _tag_.

> **Filosofía operativa**: Watchtower es para **mantenerse al día dentro del _major_ ya elegido**, no para subir _major_. Los _major bumps_ son trabajo humano (leer changelog, hacer backup, probar restore). El homelab queda parcheado contra CVEs sin añadir trabajo manual recurrente.

---

## Cómo accede Watchtower al motor — ampliación del `docker-socket-proxy`

Watchtower necesita los siguientes _endpoints_ de la API de Docker:

| _Endpoint_       | Para qué                                                         | Estado actual en el _proxy_ (tras `03-portainer.md`) |
|------------------|------------------------------------------------------------------|------------------------------------------------------|
| `CONTAINERS`     | Listar contenedores en marcha y leer sus _labels_                | `1` (ya habilitado por Portainer)                    |
| `IMAGES`         | Consultar la imagen actual de cada contenedor                    | `1` (ya habilitado por Portainer)                    |
| `INFO`, `VERSION`, `PING` | Diagnóstico inicial de Watchtower                       | `1` (ya habilitados)                                 |
| `DISTRIBUTION`   | Consultar el _digest_ remoto en el _registry_ sin descargar      | `1` (ya habilitado)                                  |
| `POST`           | Crear contenedores nuevos durante la recreación                  | `1` (ya habilitado)                                  |
| `DELETE`         | Borrar el contenedor antiguo y, si `WATCHTOWER_CLEANUP=true`, la imagen vieja | `0` → **`1`** (lo activa este documento)             |

`DELETE` se dejó deshabilitado al desplegar Portainer; ahora se habilita. El compromiso del homelab era _per-endpoint_, no _per-container_: Portainer también podrá borrar contenedores tras este cambio, lo cual es consistente con su rol de UI de operación.

> **Lo que sigue prohibido**: `SWARM`, `NODES`, `SECRETS`, `CONFIGS`, `SESSION`, `AUTH`. Watchtower no toca nada de eso. La auditoría del `environment:` del _proxy_ sigue siendo inequívoca.

---

## Estrategia de programación y notificaciones

### _Schedule_

Watchtower acepta `WATCHTOWER_SCHEDULE` (formato _cron_ de 6 campos, con segundos) **o** `WATCHTOWER_POLL_INTERVAL` (segundos entre _checks_). En este homelab se usa **cron**:

```
WATCHTOWER_SCHEDULE=0 0 4 * * 0
```

Lectura: cada **domingo a las 04:00:00** (segundos minutos hora día-mes mes día-semana). Razones:

- **Domingo** porque es el día con menos consumo del homelab (menos descargas activas, menos tráfico de Jellyfin, menos sincronía de Nextcloud).
- **04:00** porque la mayoría de _registries_ tienen capas frescas a primera hora UTC y el _ratio_ de errores de _pull_ baja respecto a horas pico. Además, la temperatura ambiente es la más baja del día, aliviando los _peaks_ térmicos de los recreates.
- **Una vez por semana** y no a diario: la ventana es suficiente para parchear CVEs en cuestión de días, sin exponer al homelab a la inestabilidad de _patch releases_ recién publicados.

### _Stop timeout_ y _rolling restart_

`WATCHTOWER_TIMEOUT=120s` da margen a servicios lentos (Nextcloud, Jellyfin tras una transcodificación) para hacer un _shutdown_ limpio antes de matar el contenedor. El _default_ son 10 s; para una Pi con discos USB es insuficiente.

Watchtower recrea contenedores **uno detrás de otro**, no en paralelo. Esto evita que el _stack_ entero parpadee a la vez.

### _Cleanup_ de imágenes obsoletas

`WATCHTOWER_CLEANUP=true` borra las imágenes antiguas tras un _pull_+recreate exitoso. Sin esto, la partición `/mnt/hd2t/system/docker` acaba llena de capas que nadie usa. Con `live-restore` activo (`docs/02-docker/01-instalacion-docker.md`), el _cleanup_ es seguro porque ningún contenedor en marcha sigue referenciando la imagen vieja una vez terminada la recreación.

### _Rolling restart_ controlado

`WATCHTOWER_ROLLING_RESTART=true` recrea los contenedores **uno a uno** (no detiene el _set_ entero antes de empezar). En la Pi 5 con 8 GB esto importa para servicios sin sentido a la vez (Caddy + Authelia + Pi-hole no deberían caer simultáneamente, aunque ninguno tenga _opt-in_ por ahora).

### _Include stopped_

`WATCHTOWER_INCLUDE_STOPPED=false` (el _default_) — Watchtower **ignora** contenedores parados. Es lo correcto: si un servicio está parado adrede (p. ej. un Sonarr en pausa), Watchtower no debe re-arrancarlo cuando llegue una imagen nueva.

### _Label precedence_

`WATCHTOWER_LABEL_ENABLE=true` (modo _opt-in_): sólo entran en el ciclo los contenedores con `com.centurylinklabs.watchtower.enable: "true"`. Todos los demás se ignoran, incluido el propio Watchtower y `docker-socket-proxy` (ambos llevan `com.centurylinklabs.watchtower.enable: "false"` ya en `03-portainer.md`).

> **Nota explícita**: Watchtower **se autoexcluye** poniéndose `com.centurylinklabs.watchtower.enable: "false"`. La autoactualización de Watchtower (modificar el contenedor del que pende el proceso en marcha) es una operación frágil; preferimos hacerla a mano con `docker compose pull watchtower && docker compose up -d watchtower` cuando haya una nueva versión.

### Notificaciones

Watchtower puede emitir un mensaje cada vez que se actualiza un contenedor. Para esta fase se prepara el _slot_ pero **no** se conecta a ningún _backend_ todavía:

- `WATCHTOWER_NOTIFICATIONS_LEVEL=info` para que se reporten actualizaciones (no cada _check_ vacío).
- Variable `WATCHTOWER_NOTIFICATION_URL` en `infra/.env`, **vacía por defecto** — sin URL, Watchtower simplemente no notifica.
- Cuando llegue `docs/05-monitorizacion/05-uptime-kuma.md` o un _bot_ Telegram en `docs/13-operaciones/`, se rellena la URL con un `shoutrrr`-compatible y Watchtower empieza a notificar sin recrear el contenedor (la variable se relee al reiniciar).

Mientras tanto, las actualizaciones quedan en los _logs_ del contenedor:

```bash
docker logs watchtower --since 24h | grep -i 'update\|pulling\|stopping'
```

---

## Variables a añadir a `infra/.env` e `infra/.env.example`

Editar **`~/homelab/infra/.env.example`** (versionado) y añadir al final:

```bash
# Watchtower (docs/02-docker/04-watchtower.md)
# Tag pinneado del propio Watchtower.
WATCHTOWER_IMAGE_TAG=1.7.1

# URL de notificaciones (formato shoutrrr).
# Vacía = sin notificaciones (sólo logs). Ejemplos cuando se conecte:
#   telegram://<token>@telegram?chats=<chat-id>
#   smtp://<user>:<pass>@smtp.example.com:587/?from=watchtower@homelab&to=admin@example.com
#   generic+https://example.com/webhook
WATCHTOWER_NOTIFICATION_URL=
```

Replicar las dos variables en **`~/homelab/infra/.env`** con valores reales:

```bash
WATCHTOWER_IMAGE_TAG=1.7.1
WATCHTOWER_NOTIFICATION_URL=
```

> El `_TAG` se pinnea a una versión concreta (no `latest`), siguiendo la convención de `docs/02-docker/02-estructura-compose.md`. Watchtower autoexcluido + _tag_ pinneado significa que la actualización del propio Watchtower es **siempre** un cambio explícito en `.env`/git.

---

## Modificaciones al `docker-compose.yml` del _stack_ `infra`

Editar **`~/homelab/infra/docker-compose.yml`** y aplicar dos cambios.

### 1) Habilitar `DELETE=1` en `docker-socket-proxy`

En el bloque `environment:` de `docker-socket-proxy`, cambiar:

```yaml
      # DELETE deshabilitado de momento; lo activará 04-watchtower.md
      # (necesita borrar imágenes obsoletas tras actualizar).
      DELETE: 0
```

por:

```yaml
      # Habilitado para Watchtower (docs/02-docker/04-watchtower.md):
      # borrar contenedores antiguos durante la recreación e imágenes
      # obsoletas con WATCHTOWER_CLEANUP=true. También lo aprovecha
      # Portainer para acciones "Remove" desde la UI.
      DELETE: 1
```

### 2) Añadir el servicio `watchtower`

Inmediatamente después del bloque de `portainer`, dentro de `services:`, añadir:

```yaml
  # ---------------------------------------------------------------------------
  # Watchtower — actualización automática de contenedores con opt-in por label.
  # Sólo procesa contenedores con com.centurylinklabs.watchtower.enable=true.
  # Habla con el motor a través de docker-socket-proxy (TCP), nunca monta
  # /var/run/docker.sock directamente.
  # ---------------------------------------------------------------------------
  watchtower:
    image: containrrr/watchtower:${WATCHTOWER_IMAGE_TAG}
    container_name: watchtower
    restart: unless-stopped
    depends_on:
      docker-socket-proxy:
        condition: service_started
    environment:
      # Conexión al motor a través del proxy.
      DOCKER_HOST: tcp://docker-socket-proxy:2375
      # Modo opt-in: sólo contenedores con la label activa.
      WATCHTOWER_LABEL_ENABLE: "true"
      # Ventana de mantenimiento: domingos 04:00 (segundos minutos hora dom mes dow).
      WATCHTOWER_SCHEDULE: "0 0 4 * * 0"
      # Borra imágenes obsoletas tras un update exitoso.
      WATCHTOWER_CLEANUP: "true"
      # Recrea contenedores uno a uno, no en bloque.
      WATCHTOWER_ROLLING_RESTART: "true"
      # Margen para shutdown limpio de servicios lentos (Nextcloud, Jellyfin).
      WATCHTOWER_TIMEOUT: "120s"
      # Ignora contenedores parados adrede.
      WATCHTOWER_INCLUDE_STOPPED: "false"
      # Sólo reporta novedades, no cada poll vacío.
      WATCHTOWER_NOTIFICATIONS_LEVEL: "info"
      # Backend de notificaciones (shoutrrr). Vacío = sólo logs.
      WATCHTOWER_NOTIFICATION_URL: ${WATCHTOWER_NOTIFICATION_URL}
      # Zona horaria coherente con el host para que el cron caiga a las 04:00 locales.
      TZ: ${TZ}
      # Sin timestamp duplicado en logs (Docker ya añade uno).
      WATCHTOWER_LOG_FORMAT: "Auto"
    networks:
      - infra-internal
    labels:
      homelab.stack: "infra"
      homelab.backup: "false"            # sin estado persistente
      # Watchtower NO se actualiza a sí mismo (frágil).
      com.centurylinklabs.watchtower.enable: "false"
```

Notas de diseño:

- **Sin `volumes:`**: Watchtower es _stateless_. Toda su "memoria" entre _checks_ es la de los _registries_ remotos.
- **Sin `ports:`**: no expone UI ni HTTP. La observación se hace por `docker logs watchtower` o por Dozzle (`docs/05-monitorizacion/06-dozzle.md`).
- **Sólo en `infra-internal`** (no en `homelab`): Watchtower no necesita ser alcanzable desde otros _stacks_, sólo necesita salida hacia el _proxy_ y resolución DNS hacia los _registries_. La red `infra-internal` está marcada `internal: true` (sin _gateway_) en `03-portainer.md`, lo que **bloquearía** el acceso al exterior. Esta es la trampa: Watchtower **necesita salida a internet** para hacer `pull`.

  La solución correcta es **delegar el _pull_ al motor**: Watchtower no descarga imágenes él mismo, le pide al motor (vía `docker-socket-proxy`) que lo haga. El _pull_ lo dispara el _daemon_ del host, que sí tiene salida. Por eso `infra-internal` puede seguir siendo `internal: true` y Watchtower funciona perfectamente.

  Si Watchtower necesitara salida directa al _registry_ (caso de _registry_ privado autenticado), habría que añadir el servicio a la red `homelab` (no `internal`). No es el caso por ahora.

- **`TZ: ${TZ}`**: el `WATCHTOWER_SCHEDULE` se interpreta en la zona horaria del contenedor. Sin `TZ`, Watchtower usaría UTC y el cron caería 1-2 h antes/después de lo esperado.

- **`com.centurylinklabs.watchtower.enable: "false"`** en el propio Watchtower y consistente con `docker-socket-proxy` y `portainer`, que ya lo llevan a `false`. La superficie de "auto-update" empieza vacía.

---

## Despliegue

Una vez editado el compose y rellenado el `.env`:

```bash
cd ~/homelab/infra
docker compose --env-file ../.env --env-file .env config | grep -A2 -E 'watchtower:|DELETE:|WATCHTOWER_'
docker compose --env-file ../.env --env-file .env up -d
```

O, equivalente, con el _Makefile_:

```bash
cd ~/homelab
make up STACK=infra
```

Compose detectará dos cambios:

1. `docker-socket-proxy` cambia su `environment` (`DELETE` pasa de `0` a `1`) → recreación.
2. `watchtower` es servicio nuevo → creación.

Ambas operaciones son seguras: el _proxy_ no tiene estado persistente, y Watchtower tampoco.

> **Orden de _restart_ del _proxy_**: cuando Compose recrea `docker-socket-proxy`, Portainer **pierde momentáneamente** la conexión con el motor (el _socket_ TCP del _proxy_ desaparece unos segundos). La UI muestra un _spinner_ y vuelve sola en cuanto el _proxy_ está arriba otra vez. Si en ese momento hay alguien _logueado_ haciendo algo en Portainer, lo verá como un error transitorio.

Verificar:

```bash
docker compose -f ~/homelab/infra/docker-compose.yml ps
# NAME                   STATUS                   PORTS
# docker-socket-proxy    Up X seconds             2375/tcp
# portainer              Up X seconds (healthy)   8000/tcp, 9000/tcp, 127.0.0.1:9000->9000/tcp, 9443/tcp
# watchtower             Up X seconds
```

Confirmar el _schedule_ activo en los _logs_ del primer arranque:

```bash
docker logs watchtower --tail 50
# Esperado:
# Watchtower 1.7.1
# Using no notifications
# Checking all containers (except explicitly disabled with label)
# Scheduling first run: 2026-04-26 04:00:00 +0200 CEST  (← domingo más cercano a las 04:00)
# Note that the first check will be performed in <X> hours, <Y> minutes
```

Si la línea `Scheduling first run` cae a una hora que **no** son las 04:00 locales, revisar `TZ` (probablemente está en UTC porque la variable no se ha interpolado).

---

## Forzar un _check_ manual sin esperar al cron

Para validar que Watchtower puede hablar con el motor a través del _proxy_, lanzar un único _check_ ya:

```bash
docker exec watchtower /watchtower --run-once --label-enable --debug
```

`--run-once` ejecuta un único pase y termina. `--label-enable` mantiene el _opt-in_ (si no se pasa, el _flag_ del comando ad hoc no hereda el `WATCHTOWER_LABEL_ENABLE` del entorno; explícito mejor). `--debug` imprime cada decisión.

Salida esperada (en ausencia de cualquier servicio con _opt-in_ activo):

```
Checking all containers (except explicitly disabled with label)
Found 0 containers to scan
Session done: 0 scanned, 0 updated, 0 failed
```

Cero contenedores escaneados es **lo correcto**: ningún servicio del homelab lleva todavía `com.centurylinklabs.watchtower.enable: "true"`. La salida confirma que Watchtower:

- Conectó con éxito al _proxy_ (si fallara, saldría `error pinging Docker server`).
- Aplicó el modo _opt-in_ (`Found 0 containers to scan` en vez de `Found 3 containers to scan`).

---

## Activar el _opt-in_ en un servicio (procedimiento)

A partir de cada doc de fase, cuando una imagen se considere "auto-actualizable", se modifica su compose:

```yaml
labels:
  homelab.stack: "<stack>"
  homelab.backup: "true"
  com.centurylinklabs.watchtower.enable: "true"   # ← cambio
```

Aplicar:

```bash
cd ~/homelab
make up STACK=<stack>
git add <stack>/docker-compose.yml
git commit -m "chore(<stack>): habilitar Watchtower en <servicio>"
```

Servicios candidatos a _opt-in_ desde el principio (sin estado complejo o stateless puro): Caddy, Pi-hole, Unbound, Jellyfin, Sonarr/Radarr/Prowlarr, Linkding, FreshRSS, Stirling-PDF, Homepage, Homarr, cAdvisor, Node Exporter, Uptime Kuma, Dozzle.

Servicios **que se mantienen en _opt-out_** (actualización manual con _release notes_): Nextcloud, MariaDB, PostgreSQL, Redis, Home Assistant, Mosquitto, Zigbee2MQTT, Vaultwarden, Bookstack, Paperless-ngx, Stash, Authelia.

> Estas listas son orientativas y cada doc de fase decide explícitamente cuál es el caso para su servicio. La regla mnemotécnica: **"si una migración de _schema_ falla, ¿es trivial revertir?"**. Si la respuesta es no, _opt-out_.

---

## Almacenamiento

Watchtower **no usa almacenamiento persistente**. Su único estado es el `WATCHTOWER_SCHEDULE`, que es una variable de entorno y se reaplica cuando el contenedor arranca. No hay `bind mount`, no hay _named volume_.

El _stack_ `infra` después de este documento sigue teniendo en disco:

| Ruta en el _host_                        | Contenido                                                  | Permisos             | Backup |
|------------------------------------------|------------------------------------------------------------|----------------------|--------|
| `/mnt/hd2t/services/portainer/data/`     | `portainer.db` (BoltDB), TLS internas, _settings_, _users_ | `0750 homelab:homelab` | Sí     |

Watchtower no añade ninguna entrada a esta tabla.

---

## Backup

Nada que respaldar. El comportamiento de Watchtower es 100 % derivable de:

- `~/homelab/infra/docker-compose.yml` (versionado en git)
- `~/homelab/infra/.env` (en disco, fuera de git)

Restaurar Watchtower tras una catástrofe es exactamente `make up STACK=infra`.

> **Cuidado con la idempotencia**: si en una restauración se levanta Watchtower antes de tener el `infra/.env` correcto, arranca con `WATCHTOWER_NOTIFICATION_URL` vacío y otras variables a su _default_ — comportamiento aceptable (sólo _logs_ y _schedule_ por defecto del _flag_ explícito), no destructivo. No ocurrirá una actualización en cadena por accidente porque `WATCHTOWER_LABEL_ENABLE=true` es _opt-in_.

---

## Verificación final

Antes de cerrar la fase 2 y pasar a `docs/03-red/01-macvlan.md`, comprobar:

- [ ] `docker compose -f ~/homelab/infra/docker-compose.yml ps` muestra `watchtower` en estado `Up` y los otros dos (`docker-socket-proxy`, `portainer`) siguen como antes.
- [ ] `docker exec docker-socket-proxy env | grep -E '^(DELETE|CONTAINERS|IMAGES|DISTRIBUTION)='` lista las cuatro a `1`. La auditoría del _proxy_ refleja exactamente lo que está habilitado.
- [ ] `docker logs watchtower --tail 30 | grep -i 'scheduling first run'` muestra la siguiente ventana en **domingo, 04:00, hora local Europe/Madrid**. Si sale `+0000 UTC` en vez de `+0200`/`+0100`, `TZ` no se interpoló — revisar `infra/.env` y `infra/.env.example`.
- [ ] `docker exec watchtower /watchtower --run-once --label-enable --debug 2>&1 | tail -5` termina con `Session done: 0 scanned, 0 updated, 0 failed`. Cero escaneos confirma que el _opt-in_ está activo y que ningún contenedor lleva `enable=true` aún.
- [ ] Marcar **temporalmente** un contenedor inocuo con la _label_ y verificar que entra al pase:

  ```bash
  docker run -d --name watchtower-test \
      --label com.centurylinklabs.watchtower.enable=true \
      --label homelab.stack=test \
      alpine:3.20 sleep 600
  docker exec watchtower /watchtower --run-once --label-enable --debug 2>&1 | grep -i 'watchtower-test'
  # Esperado: 'Trying to load authentication credentials' / 'No new images found for watchtower-test'
  docker rm -f watchtower-test
  ```

  Esto confirma que la cadena Watchtower → _proxy_ → motor → _registry_ funciona _end to end_. Si en lugar de "no new images" sale `403 Forbidden` o `permission denied`, falta algún _endpoint_ en el _proxy_.

- [ ] Forzar un fallo deliberado para validar la categoría de _logs_:

  ```bash
  docker run -d --name watchtower-test-bad \
      --label com.centurylinklabs.watchtower.enable=true \
      gcr.io/this-image/does-not-exist:tag sleep 600 || true
  docker exec watchtower /watchtower --run-once --label-enable --debug 2>&1 | grep -i 'watchtower-test-bad'
  docker rm -f watchtower-test-bad 2>/dev/null
  ```

  Aparece `error="manifest unknown"` o similar. Es el comportamiento esperado: Watchtower lo loggea y sigue con el siguiente.

- [ ] Reiniciar la Pi (`sudo reboot`) y, tras el arranque, confirmar:
  - `docker ps --filter name=watchtower --format '{{.Status}}'` lista `Up` automáticamente (gracias a `restart: unless-stopped`).
  - Los _logs_ vuelven a mostrar `Scheduling first run: ...`.
- [ ] `git -C ~/homelab status` muestra como modificados: `infra/docker-compose.yml`, `infra/.env.example`. **No** muestra `infra/.env` (ignorado). _Commit_:

  ```bash
  cd ~/homelab
  git add infra/docker-compose.yml infra/.env.example
  git commit -m "feat(infra): add Watchtower (opt-in, weekly, no auto-updates yet)"
  ```

- [ ] La fase 2 queda completa: `~/homelab/infra/` contiene Portainer, `docker-socket-proxy` y Watchtower; ningún servicio del homelab tiene aún _opt-in_ activo; los siguientes _stacks_ pueden arrancar sabiendo que la infraestructura de UI + automatización está disponible.

---

## Troubleshooting

### Watchtower arranca y los _logs_ dicen `error pinging Docker server: ... permission denied`

El _proxy_ está respondiendo pero alguno de los _endpoints_ que pide Watchtower está a `0`. Revisar:

```bash
docker exec docker-socket-proxy env | grep -E '^(CONTAINERS|IMAGES|INFO|VERSION|PING|DISTRIBUTION|POST|DELETE)='
```

Las ocho deben ser `1`. Si alguna está a `0`, ajustar el `environment` del _proxy_ y recrearlo:

```bash
docker compose -f ~/homelab/infra/docker-compose.yml up -d --force-recreate docker-socket-proxy
```

Luego reiniciar Watchtower (no se recrea solo si su definición no ha cambiado):

```bash
docker compose -f ~/homelab/infra/docker-compose.yml restart watchtower
```

### Watchtower arranca y los _logs_ dicen `error pinging Docker server: ... connection refused`

Watchtower no encuentra al _proxy_ en la red `infra-internal`. Confirmar:

```bash
docker network inspect infra-internal --format '{{range .Containers}}{{.Name}} {{end}}'
# debe listar: docker-socket-proxy portainer watchtower
```

Si Watchtower no aparece, revisar la sección `networks:` de su servicio en el compose.

### El cron parece ejecutarse a una hora distinta de las 04:00

Casi siempre es `TZ` mal pasada. Verificar:

```bash
docker exec watchtower date
docker exec watchtower env | grep -E '^TZ='
```

`date` debe mostrar la hora local de la Pi y `TZ=Europe/Madrid`. Si `TZ` está vacío o sale `UTC`, revisar la interpolación: el compose tiene `TZ: ${TZ}` y en `~/homelab/.env` debe haber `TZ=Europe/Madrid`. Recordar el doble `--env-file` al desplegar (`make up STACK=infra` ya lo hace).

### Una actualización falló y dejó un contenedor parado

Watchtower hace _pull_ → _stop_ → _create_ → _start_. Si el _start_ falla (variable de entorno faltante en la nueva versión, _flag_ deprecado, _schema migration_ rota), el contenedor queda parado y Watchtower escribe el error en los _logs_. La recuperación es manual:

1. Leer los _logs_ del contenedor parado para entender el _error_:

   ```bash
   docker logs <servicio> --tail 100
   ```

2. Decidir: o se ajusta el `docker-compose.yml` a la nueva versión y se vuelve a arrancar, o se hace _rollback_ a la imagen anterior. Para el _rollback_, mirar las imágenes locales que aún no se hayan limpiado:

   ```bash
   docker images <repo>/<imagen> --format '{{.Tag}} {{.ID}} {{.CreatedSince}}'
   ```

   Y, si la previa sigue ahí (puede haberse limpiado por `WATCHTOWER_CLEANUP=true`), retag manual:

   ```bash
   docker tag <imagen>@sha256:<digest-anterior> <imagen>:<tag>
   docker compose -f ~/homelab/<stack>/docker-compose.yml up -d <servicio>
   ```

3. Quitar `com.centurylinklabs.watchtower.enable=true` de ese servicio hasta entender el _release_ que rompió.

> **Lección operativa**: si un servicio se rompe en una actualización automática, **se desactiva su _opt-in_** y vuelve a la lista de "actualizar a mano". No se recupera el _opt-in_ hasta que se entiende **por qué** rompió y se confirma que ya está mitigado en _upstream_.

### Watchtower no actualiza un contenedor que sí tiene `enable=true`

Posibilidades:

1. La _label_ está en el _stack_ del compose pero el contenedor no se ha recreado. Las _labels_ se aplican en el momento de la creación. Forzar:

   ```bash
   docker compose -f ~/homelab/<stack>/docker-compose.yml up -d --force-recreate <servicio>
   docker inspect <servicio> --format '{{index .Config.Labels "com.centurylinklabs.watchtower.enable"}}'
   # debe imprimir: true
   ```

2. El _tag_ en el compose es `latest` o un _major_ que no se actualiza con _patches_. Watchtower respeta el _tag_; sólo trae nuevos _digests_ del **mismo** _tag_. Si la imagen oficial sólo publica _patches_ bajo `2.21.5` (sin _tag_ flotante `2.21`), no habrá nada que traer.

3. El _registry_ está caído o respondiendo 5xx. Mirar los _logs_ con `--debug` activo (`docker exec watchtower /watchtower --run-once --label-enable --debug`).

### `cleanup` no está limpiando imágenes viejas

Confirmar que `DELETE=1` en el _proxy_ y que `WATCHTOWER_CLEANUP=true` está en el _environment_ de Watchtower. Sin alguno de los dos, el _cleanup_ falla silenciosamente (en los _logs_ aparece `error removing image: 403`).

Para la limpieza manual puntual (mientras se diagnostica):

```bash
docker image prune -af --filter "until=168h"   # imágenes >7 días sin usar
```

### `docker logs watchtower` muestra `Notifier failed to send`

El `WATCHTOWER_NOTIFICATION_URL` está rellenado pero la URL no es válida o el _backend_ no responde. Si aún no hay un _backend_ real, dejar la variable vacía. Cuando se conecte (Telegram, Apprise…), validar primero con `shoutrrr` standalone:

```bash
docker run --rm containrrr/shoutrrr send -u "$WATCHTOWER_NOTIFICATION_URL" -m "test desde la Pi"
```

Si ese envío de prueba falla, el problema está en el _backend_, no en Watchtower.

---

## Referencias

- Watchtower — Documentación oficial: <https://containrrr.dev/watchtower/>
- Watchtower — Selección de contenedores y _labels_: <https://containrrr.dev/watchtower/container-selection/>
- Watchtower — Argumentos y variables de entorno: <https://containrrr.dev/watchtower/arguments/>
- Watchtower — Notificaciones (shoutrrr): <https://containrrr.dev/watchtower/notifications/>
- Watchtower — Imagen Docker: <https://hub.docker.com/r/containrrr/watchtower>
- Shoutrrr — Servicios soportados (Telegram, SMTP, Discord, Apprise…): <https://containrrr.dev/shoutrrr/services/overview/>
- Tecnativa — `docker-socket-proxy` _endpoints_: <https://github.com/Tecnativa/docker-socket-proxy#access-control>
- Cron de 6 campos (Quartz-style) — Sintaxis: <https://pkg.go.dev/github.com/robfig/cron#hdr-CRON_Expression_Format>
