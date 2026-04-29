# Watchtower

## Descripción

Tras `03-portainer.md` el homelab tiene un panel para **observar y operar** Docker desde un navegador, pero nada se encarga de **mantener al día** las imágenes que esos contenedores usan. Sin una política explícita pasa una de dos cosas: o el operador hace `docker compose pull && up -d` a mano cada cierto tiempo (y entonces el homelab se ancla en versiones cada vez más viejas hasta que duele algo), o se acumulan vulnerabilidades sin parchear durante meses. Ninguna es aceptable para un homelab de larga vida.

Este documento despliega **Watchtower** como **segundo stack real** del homelab. Hace cuatro cosas:

1. **Justifica la elección**. Watchtower vs alternativas razonables (Diun en modo solo-notificación, Renovate vía PRs sobre git, `apt`-style con un cron que haga `docker compose pull` por stack, o "no instalar nada y vivir solo de actualizaciones manuales"). Se argumenta por qué Watchtower encaja y cuáles son sus límites conscientes.
2. **Fija la política de cobertura**. Decisión clave: **opt-in por label**, no opt-out. Watchtower **solo** toca contenedores etiquetados `com.centurylinklabs.watchtower.enable=true`. Bases de datos, servicios con migraciones complejas y todo lo que un upgrade roto pueda dejar en un estado irrecuperable se quedan **fuera** y se actualizan a mano cuando toque.
3. **Despliega el stack**. Bajo `stacks/watchtower/`, siguiendo las convenciones de `02-estructura-compose.md`: `container_name: watchtower`, conectado a la red `homelab`, bind mount al socket de Docker, schedule cron explícito, política de limpieza, sin puertos publicados (Watchtower no expone UI). Las **notificaciones** se dejan **preparadas pero apagadas**: la URL de Apprise/Gotify/ntfy se rellenará en su fase correspondiente (Fase 4, monitorización), de modo que cuando exista un canal real para escuchar el homelab, basta con editar un `.env`.
4. **Fija la coreografía con el resto del homelab**. Watchtower **no** sustituye al pinning de tags ni al repo como fuente de verdad: el repo sigue siendo el sitio donde se cambia la **versión mayor**; Watchtower sólo se ocupa de **traer parches dentro del mismo tag flotante** (por ejemplo `mariadb:11.4` → último digest publicado para ese tag, sin saltar a `12.0`). Las decisiones que **no** se toman aquí (rollback automático, monitor-only mode global, integración con un canal concreto de notificaciones) quedan listadas al final.

Cuando este documento se haya aplicado, `docker ps` lista un contenedor `watchtower` saludable, sus logs muestran el primer scheduling, hay una ventana diaria definida en la que se pulan los `pull` y se reinician sólo los contenedores marcados, y existe una regla escrita —en este mismo fichero— que cualquier nuevo stack deberá seguir para decidir si entra o no en la lista.

> **Recordatorio de alcance**: el homelab es solo **LAN + Tailscale**. Watchtower **no** publica puertos, **no** expone API y **no** se accede desde fuera; sus notificaciones (cuando se enchufen) viajan por la red `homelab` a un servicio interno o por una API externa concreta vía DNS público (Apprise → ntfy.sh, Telegram bot, etc.), nunca por puertos abiertos hacia internet en la Pi.

---

## Requisitos Previos

- `02-docker/01-instalacion-docker.md` aplicado:
  - Docker Engine ≥ 27 corriendo, Compose v2 disponible.
  - `data-root` en `/mnt/hd2t/docker`, `live-restore: true`.
  - Usuario `homelab` (UID 1000) en el grupo `docker`, `docker ps` funciona sin `sudo`.
- `02-docker/02-estructura-compose.md` aplicado:
  - Red Docker `homelab` creada con subnet `172.30.10.0/24` (`scripts/10-create-docker-network.sh`).
  - Layout `/home/homelab/homelab/{stacks/_template,scripts,secrets}` y `.env` global con `TZ`, `PUID`, `PGID`, `PGID_MEDIA`.
  - Plantilla `stacks/_template/docker-compose.yml` con el label `com.centurylinklabs.watchtower.enable: "true"` ya documentada como convención por defecto.
- `02-docker/03-portainer.md` aplicado:
  - `portainer` corriendo `(healthy)` con su label `com.centurylinklabs.watchtower.enable: "true"` ya puesto.
  - Con esto Watchtower nace con **al menos un objetivo real** que vigilar: él mismo (auto-update) y Portainer.
- Conectividad a internet desde la Pi para descargar `containrrr/watchtower` y, periódicamente, los digests de Docker Hub / GHCR.
- Comprobación rápida antes de empezar:

  ```bash
  cd /home/homelab/homelab
  docker network inspect homelab --format '{{.Name}}'                     # homelab
  docker inspect portainer --format '{{ index .Config.Labels "com.centurylinklabs.watchtower.enable" }}'
  # true
  ls /var/run/docker.sock
  # srw-rw---- 1 root docker ...  /var/run/docker.sock
  date +%Z
  # CET / CEST  (Watchtower lee TZ del entorno; el cron se evalúa en esa zona)
  ```

---

## Decisión: qué herramienta de actualización instalar

| Opción | Cómo se ve | Pros | Contras | Veredicto |
|---|---|---|---|---|
| **Solo manual** (cron del operador) | El operador entra por SSH cada cierto tiempo y ejecuta `docker compose -f stacks/<x>/docker-compose.yml pull && up -d` por stack. | Cero superficie nueva, control total. | No escala con ~30 stacks. La cadencia real es "cuando me acuerde", que se traduce en meses de retraso. Vulnerabilidades parcheadas en upstream tardan semanas en bajar. | Descartado **como única opción**. Sigue siendo el camino para versiones mayores. |
| **Cron + script per-stack** | Un script que recorre `stacks/*/docker-compose.yml` y ejecuta `pull && up -d` con `--no-recreate`/`--quiet-pull`. | Sin daemon nuevo. Compose ya está. | Hay que escribir y mantener el script (opt-in/opt-out, exclusiones, paralelismo, errores). Reinventar un Watchtower peor. | Descartado: no aporta sobre Watchtower y es código propio que mantener. |
| **Watchtower** (`containrrr/watchtower`) | Daemon que poll-ea Docker Hub/GHCR, compara digests del tag actual y, si cambia, hace `pull` + `stop` + `rm` + `run` con la misma config. | Maduro, multi-arch (`arm64` oficial), ~15 MB RAM, opt-in/opt-out por label, schedule cron de 6 campos, modo `--monitor-only`, integración nativa con Apprise/SMTP/Slack/MS Teams/Gotify, soporta `--cleanup` para purgar imágenes viejas. | Reemplaza el contenedor (`stop`+`rm`+`run`) en lugar de hacer `compose up -d`: pierde la genealogía de Compose para ese contenedor, aunque lo recrea con la misma config. **Necesita el socket de Docker** (root del host). | **Aceptado**. |
| **Diun** (Docker Image Update Notifier) | Daemon que solo **avisa** cuando hay nuevos digests; no actualiza. | Cero riesgo de update roto. | Convierte cada notificación en trabajo manual del operador. Para un homelab con servicios "estables" (Portainer, Caddy, Pi-hole) eso es ruido y deuda. | Descartado **como mecanismo principal**, reabrible como complemento si se quiere monitor-only sobre un subconjunto crítico. |
| **Renovate** (Mend) sobre el repo de git | Renovate abre PRs cambiando los tags en los `docker-compose.yml`, el operador hace merge y `up -d`. | El repo sigue siendo fuente de verdad: la actualización **es un commit**. Trazabilidad perfecta. | Requiere infra de PRs (GitHub privado o Gitea local) y un runner. Sobredimensionado para un único operador. Las actualizaciones de **patch** sin cambio de tag (digest puro) **no las ve** Renovate. | Descartado para este homelab; reabrible si en algún momento se introduce CI sobre el repo. |
| **Podman auto-update** | Equivalente nativo de Podman para `systemd` units. | Nativo y sin daemon extra. | El homelab no usa Podman; el coste de migrar es altísimo y rompería 10 documentos previos. | Descartado por mismatch de stack. |

Resultado: **Watchtower**, imagen oficial `containrrr/watchtower`, desplegado como stack `stacks/watchtower/` siguiendo la plantilla y operando en modo **opt-in** por label.

> **Imagen exacta**: se usa `containrrr/watchtower:1.7.1` (tag inmovilizado en `mayor.menor.parche`, no `latest`). El propio Watchtower se incluye en su lista de objetivos (auto-update), de modo que cuando salga un patch dentro del tag `1.7` lo recogerá; saltar a `1.8.x` exige editar este compose y commitearlo.

---

## Decisión: opt-in por label, no opt-out

Watchtower acepta dos modos de cobertura:

| Modo | Cómo se invoca | Comportamiento |
|---|---|---|
| **Opt-out** (default upstream) | sin `--label-enable` | Toca **todos** los contenedores menos los que llevan `com.centurylinklabs.watchtower.enable=false`. |
| **Opt-in** | con `--label-enable` | Toca **solo** los contenedores que llevan `com.centurylinklabs.watchtower.enable=true`. |

Este homelab adopta **opt-in**. Razones:

| Motivo | Explicación |
|---|---|
| Bases de datos | Postgres, MariaDB, Redis: una actualización dentro del mismo tag mayor casi nunca rompe, pero un salto puntual a un binario incompatible (raro, pero posible si upstream republica el tag) deja la BBDD en un estado que requiere intervención. Mejor que esos contenedores **nunca** se actualicen automáticamente. En opt-out habría que acordarse de etiquetarlos `=false` cada vez. |
| Servicios con migraciones | Nextcloud requiere `occ upgrade` y a veces pasos manuales. Paperless-ngx aplica migraciones automáticas pero exige backup previo. Aquí Watchtower **se queda fuera por defecto** y la actualización es manual y orquestada. |
| Apps todavía no probadas | Cuando se añade un stack nuevo, lo razonable es que **arranque sin Watchtower** durante unos días, se vea que está estable y entonces se le ponga el label. Opt-in lo hace por defecto. |
| Servicios efímeros/one-shot | Borgmatic, scripts de migración: no tienen sentido como objetivos de Watchtower. En opt-in ni los mira. |
| Auditoría trivial | `docker ps --filter "label=com.centurylinklabs.watchtower.enable=true" --format '{{.Names}}'` lista exactamente qué contenedores están bajo cobertura. En opt-out la pregunta inversa ("¿qué hay sin actualizar?") es difícil. |

La plantilla `stacks/_template/docker-compose.yml` ya trae `com.centurylinklabs.watchtower.enable: "true"` por defecto: **lo normal** es que un stack nuevo entre en cobertura. La excepción se documenta **en cada documento de servicio**: el doc de Postgres pondrá `=false` y explicará por qué; el doc de Nextcloud pondrá `=false` y explicará el procedimiento manual.

---

## Decisión: schedule, limpieza y reinicio

Cinco parámetros que hay que fijar antes de escribir el compose. Cada uno con su trade-off.

### Cadencia

| Opción | Pros | Contras |
|---|---|---|
| **Cada 6 h** (`0 0 */6 * * *`) | Parches cerca de upstream. | Cuatro ventanas al día de "el servicio se reinicia". Demasiado para Pi-hole, Caddy, Jellyfin durante una sesión. |
| **Diaria** (`0 0 4 * * *`, 04:00) | Ventana única predecible, fuera del uso doméstico. Suficiente cercanía a upstream para parches de seguridad. | Hasta 24 h de retraso sobre un parche urgente (mitigable haciendo `docker compose pull && up -d` manualmente cuando se sepa). |
| **Semanal** (`0 0 4 * * 1`, lunes 04:00) | Mínimo ruido. | Demasiado retraso para un homelab que aspira a estar al día sin esfuerzo. |
| **`--run-once`** invocado por cron del host | Cero daemon residente. | Mata el modelo: hay que crear y mantener un timer de systemd, y se pierde la integración nativa de Apprise/notificaciones. |

Se elige **diaria a las 04:00 hora local de la Pi**. Watchtower usa cron de 6 campos (segundo, minuto, hora, día-mes, mes, día-semana). El valor exacto:

```
WATCHTOWER_SCHEDULE=0 0 4 * * *
```

> **Zona horaria**: Watchtower interpreta el cron en la TZ del propio contenedor. Por eso el stack hereda `TZ=${TZ}` del `.env` global (`Europe/Madrid`). Si en algún momento se cambia la TZ del host hay que comprobar que el contenedor también lo refleja.

### Limpieza (`--cleanup`)

Sin `--cleanup`, cada actualización **deja la imagen anterior** en el host. En un homelab que rota docenas de imágenes mensualmente (`portainer/portainer-ce`, `caddy`, `jellyfin/jellyfin`, ...) se acumulan gigabytes de basura en `/mnt/hd2t/docker`.

Se activa **`--cleanup=true`** (variable `WATCHTOWER_CLEANUP=true`). Watchtower elimina la imagen vieja **solo** si ya no la usa ningún contenedor. Si en algún momento se quiere conservarlas para rollback rápido, se desactiva (y se acepta el coste en disco). El rollback en este homelab se hace cambiando el tag en el `docker-compose.yml` y `up -d`, no recuperando una imagen huérfana.

### Reinicio rolling (`--rolling-restart`)

Sólo aplica si hay **réplicas** del mismo servicio. En single-host con un contenedor por servicio no hay nada que rotar; se deja **desactivado**.

### Reanimar contenedores parados (`--include-stopped` / `--revive-stopped`)

Watchtower puede **arrancar** contenedores que están `Exited` si su imagen tiene update. Esto es indeseable: si el operador paró Pi-hole para depurar, no se quiere que Watchtower lo arranque por su cuenta a las 04:00. Se deja **desactivado** (`WATCHTOWER_INCLUDE_STOPPED=false` y por tanto `WATCHTOWER_REVIVE_STOPPED` no aplica).

### Modo solo-monitor (`--monitor-only`) por contenedor

Watchtower 1.7+ permite marcar un contenedor con `com.centurylinklabs.watchtower.monitor-only=true`: detecta updates **y notifica**, pero **no** los aplica. Útil para servicios que entran en cobertura pero el operador prefiere "saber, no actualizar". No se activa de forma global; se ofrece como herramienta opcional por servicio:

```yaml
labels:
  com.centurylinklabs.watchtower.enable: "true"
  com.centurylinklabs.watchtower.monitor-only: "true"
```

Cuando el canal de notificaciones esté enchufado (Fase 4), esta combinación se vuelve la "tercera vía" útil para servicios sensibles: ni completamente fuera (`enable=false`) ni con auto-update (`enable=true` solo).

---

## Decisión: notificaciones — preparadas pero apagadas

Watchtower puede notificar por varios canales (Apprise, SMTP, Slack, MS Teams, Gotify, ntfy, ...). En este homelab:

- **Hoy** no hay aún canal interno de notificaciones (Gotify/ntfy/Apprise se planifican en Fase 4: monitorización y alertas).
- **Hoy** tampoco se quiere acoplar el homelab a un proveedor externo (Slack/Telegram) en la fase 2.

Así que se hace lo conservador: el stack **define** las variables `WATCHTOWER_NOTIFICATION_URL` y `WATCHTOWER_NOTIFICATIONS` en el `.env` con valor **vacío** o `shoutrrr` con un destino dummy, y queda **un único punto** donde rellenar la URL real cuando el canal exista. Mientras tanto, Watchtower escribe a sus logs (`docker logs watchtower`) con `--debug` opcional, y el operador los consume desde Portainer o por SSH.

Patrón final:

```bash
# stacks/watchtower/.env (NO se sube a git)
WATCHTOWER_NOTIFICATIONS=
WATCHTOWER_NOTIFICATION_URL=
WATCHTOWER_NOTIFICATION_REPORT=true   # cuando se rellene la URL, manda informe agregado
```

Cuando se enchufe Gotify (Fase 4), el operador editará este `.env` y hará:

```bash
docker compose -f stacks/watchtower/docker-compose.yml up -d
```

para recargar las variables. **Ni una línea** del compose cambia.

---

## Decisión: cómo se expone Watchtower

**No se expone**. Watchtower no tiene UI ni API HTTP por defecto (existe un endpoint de "HTTP API mode" para disparar updates manualmente, pero requiere token y aquí no aporta). Se elimina la variable `WATCHTOWER_HTTP_API_*` del compose y se confirma que **no hay `ports:`**.

- Sin puerto publicado → ninguna superficie de ataque añadida en LAN.
- Sin UI → menos credenciales que rotar.
- Sin API HTTP → un actualizar fuera de schedule se hace con `docker compose -f stacks/watchtower/docker-compose.yml run --rm watchtower --run-once <contenedor>` (ver más abajo).

---

## Stack: `stacks/watchtower/`

### `stacks/watchtower/docker-compose.yml`

```yaml
# Watchtower — actualización automática de imágenes Docker.
# Convenciones: ver docs/02-docker/02-estructura-compose.md.
# Política: ver docs/02-docker/04-watchtower.md.

name: watchtower

services:
  watchtower:
    image: containrrr/watchtower:1.7.1
    container_name: watchtower
    hostname: watchtower
    restart: unless-stopped

    environment:
      TZ: ${TZ}

      # Cobertura: opt-in por label (--label-enable). Solo toca contenedores
      # con com.centurylinklabs.watchtower.enable=true.
      WATCHTOWER_LABEL_ENABLE: "true"

      # Schedule: cron de 6 campos. 04:00 hora local de la Pi.
      WATCHTOWER_SCHEDULE: "0 0 4 * * *"

      # Limpia imágenes viejas cuando ya no las usa nadie.
      WATCHTOWER_CLEANUP: "true"

      # Sin reinicio rolling (single-host, una réplica por servicio).
      WATCHTOWER_ROLLING_RESTART: "false"

      # No tocar contenedores parados.
      WATCHTOWER_INCLUDE_STOPPED: "false"
      WATCHTOWER_REVIVE_STOPPED: "false"

      # Logs: formato legible, nivel info por defecto. Subir a "debug" en
      # troubleshooting puntual.
      WATCHTOWER_LOG_LEVEL: "info"
      WATCHTOWER_LOG_FORMAT: "Pretty"

      # Notificaciones: preparadas pero apagadas. Se enchufan en Fase 4.
      WATCHTOWER_NOTIFICATIONS: ${WATCHTOWER_NOTIFICATIONS:-}
      WATCHTOWER_NOTIFICATION_URL: ${WATCHTOWER_NOTIFICATION_URL:-}
      WATCHTOWER_NOTIFICATION_REPORT: ${WATCHTOWER_NOTIFICATION_REPORT:-true}
      WATCHTOWER_NOTIFICATION_TEMPLATE: |
        {{- if .Report -}}
          {{- with .Report -}}
            Watchtower {{len .Updated}} updated, {{len .Failed}} failed, {{len .Scanned}} scanned, {{len .Skipped}} skipped.
            {{- range .Updated}}
            - UPDATED: {{.Name}} ({{.ImageName}}) {{.CurrentImageID.ShortID}} → {{.LatestImageID.ShortID}}
            {{- end -}}
            {{- range .Failed}}
            - FAILED:  {{.Name}} ({{.ImageName}}): {{.Error}}
            {{- end -}}
          {{- end -}}
        {{- else -}}
          {{range .Entries -}}{{.Message}}{{"\n"}}{{end -}}
        {{- end -}}

    networks:
      - homelab

    # El socket de Docker es la API que Watchtower opera (pull/stop/rm/run).
    # Equivale a root del host: misma propiedad que el grupo docker, ya
    # asumida en 01-instalacion-docker.md.
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      # Solo si se usa registry privado autenticado: bind mount al
      # ~/.docker/config.json del usuario homelab. Hoy no aplica.
      # - /home/homelab/.docker/config.json:/config.json:ro

    # Sin `ports:` — Watchtower no expone UI ni API HTTP.

    healthcheck:
      # Watchtower no trae endpoint /health. Como prueba de vida usamos su
      # propio binario: si responde --help, el proceso está vivo.
      test: ["CMD", "/watchtower", "--help"]
      interval: 1m
      timeout: 5s
      retries: 3
      start_period: 15s

    labels:
      homelab.role: "management"
      # Watchtower NO se respalda: es stateless.
      homelab.backup: "false"
      # Watchtower se actualiza a sí mismo (auto-update dentro de tag 1.7.x).
      com.centurylinklabs.watchtower.enable: "true"

networks:
  homelab:
    external: true
```

### `stacks/watchtower/.env.example`

Se versiona en git **sin** valores reales:

```bash
# stacks/watchtower/.env.example
# Notificaciones de Watchtower. Se enchufan en Fase 4 (monitorización).
# Mientras tanto, dejar vacío.
#
# Ejemplos cuando se enchufe el canal:
#   shoutrrr → ntfy:
#     WATCHTOWER_NOTIFICATIONS=shoutrrr
#     WATCHTOWER_NOTIFICATION_URL=ntfy://ntfy.home.lan:80/homelab-watchtower
#   shoutrrr → Gotify (interno):
#     WATCHTOWER_NOTIFICATIONS=shoutrrr
#     WATCHTOWER_NOTIFICATION_URL=gotify://gotify.home.lan:80/<token>
#   shoutrrr → Telegram (externo, requiere bot token):
#     WATCHTOWER_NOTIFICATIONS=shoutrrr
#     WATCHTOWER_NOTIFICATION_URL=telegram://<token>@telegram?chats=<chatid>

WATCHTOWER_NOTIFICATIONS=
WATCHTOWER_NOTIFICATION_URL=
WATCHTOWER_NOTIFICATION_REPORT=true
```

> **Nota**: si más adelante se quisiera consumir un registry privado (no aplica hoy: Docker Hub y GHCR son suficientes para todo el catálogo de `SERVICES.md`), se descomenta el bind mount a `/home/homelab/.docker/config.json` y se hace `docker login` en el host. Watchtower lee de allí las credenciales.

### Crear el stack y desplegar

```bash
# El stack es stateless: NO hay /mnt/hd2t/apps/watchtower/.
# Si por error existe (de una iteración previa), se elimina:
sudo rm -rf /mnt/hd2t/apps/watchtower 2>/dev/null || true

# .env por stack (vacío de momento, ver .env.example)
cd /home/homelab/homelab/stacks/watchtower
cp -n .env.example .env
chmod 0600 .env

# Cargar variables globales en el shell (ver quirk Compose v2 en 02-estructura-compose.md)
cd /home/homelab/homelab
set -a; source .env; set +a

# Validar el compose con interpolación de variables
docker compose \
    -f stacks/watchtower/docker-compose.yml \
    --env-file stacks/watchtower/.env \
    config >/dev/null && echo "compose OK"

# Levantar
docker compose \
    -f stacks/watchtower/docker-compose.yml \
    --env-file stacks/watchtower/.env \
    up -d
```

> **`--env-file` del stack**: el `.env` global del repo (cargado con `source`) aporta `TZ`; el `--env-file stacks/watchtower/.env` aporta `WATCHTOWER_NOTIFICATION_*`. Si hay colisión, la variable del entorno del shell gana sobre la del `--env-file`.

Tras `up -d`:

```bash
docker ps --filter name=watchtower
# CONTAINER ID   IMAGE                          ...   STATUS                   PORTS    NAMES
# ...            containrrr/watchtower:1.7.1          Up 30 seconds (healthy)            watchtower

docker compose -f stacks/watchtower/docker-compose.yml logs --tail 30
# time="..." level=info msg="Watchtower 1.7.1"
# time="..." level=info msg="Using no notifications"
# time="..." level=info msg="Only checking containers with enabled label"
# time="..." level=info msg="Scheduling first run: ... 04:00:00 +0200"
# time="..." level=info msg="Note that the first check will be performed in X hours, Y minutes, Z seconds"
```

Las tres líneas en negrita son las **señales de salud** del despliegue. Si falta cualquiera, la configuración no se ha aplicado:

| Señal | Significado | Si falta |
|---|---|---|
| `Watchtower <version>` | El binario arrancó. | Imagen rota, comprobar tag. |
| `Only checking containers with enabled label` | `--label-enable` activo. | Falta `WATCHTOWER_LABEL_ENABLE=true`. Sin esto, **todos los contenedores** entran en cobertura, incluido Postgres. |
| `Scheduling first run: ...` | El cron se interpretó. | `WATCHTOWER_SCHEDULE` mal formado (recordar: 6 campos, no 5). |

---

## Configuración

### 1) Verificar la cobertura: qué contenedores entran

```bash
docker ps \
    --filter "label=com.centurylinklabs.watchtower.enable=true" \
    --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
```

A esta altura del homelab debería listar al menos:

```
NAMES         IMAGE                                  STATUS
portainer     portainer/portainer-ce:2.21.4-alpine   Up X minutes (healthy)
watchtower    containrrr/watchtower:1.7.1            Up X minutes (healthy)
```

Y nada más. Conforme se desplieguen los stacks de fases siguientes, esta lista crece.

### 2) Disparar una pasada manual sin esperar al cron

Útil al primer despliegue para probar que la mecánica funciona, y de vez en cuando si se quiere forzar una actualización antes de las 04:00:

```bash
docker compose \
    -f /home/homelab/homelab/stacks/watchtower/docker-compose.yml \
    run --rm \
    -e WATCHTOWER_SCHEDULE= \
    watchtower \
    --run-once --cleanup --label-enable
```

Notas:

- `run --rm`: arranca un contenedor **efímero** con la misma imagen y env. **No** detiene al daemon ya corriendo.
- `WATCHTOWER_SCHEDULE=` se anula porque `--run-once` y `--schedule` son mutuamente excluyentes.
- El comando termina por sí mismo cuando ha procesado todos los contenedores enabled.

Salida esperada cuando no hay updates:

```
time="..." level=info msg="Found new ... image: NO"
time="..." level=info msg="Session done: 0 scanned, 0 updated, 0 failed (containers/images)"
```

Cuando sí los hay, la línea `Updated container ...` aparece por cada contenedor recreado.

### 3) Excluir un contenedor sin pararlo

Tres formas, en orden de preferencia:

| Forma | Cómo | Cuándo |
|---|---|---|
| **Quitar el label en el compose y hacer `up -d`** | Editar el `docker-compose.yml` del stack y poner `com.centurylinklabs.watchtower.enable: "false"` (o eliminar el label). Commitear. | Decisión **permanente**. Es la vía que respeta "el repo es la fuente de verdad". |
| **Marcar monitor-only en el compose** | Añadir `com.centurylinklabs.watchtower.monitor-only: "true"` además del `enable=true`. | Decisión **permanente** y queremos seguir oyendo notificaciones. |
| **Pausarlo desde fuera, temporal** | `docker stop <name>` antes de las 04:00 y `docker start <name>` después. | Casos extremos (mantenimiento puntual). No queda en git → se anota en el commit que toque. |

### 4) Recetas operativas frecuentes

| Necesidad | Comando |
|---|---|
| Listar lo que Watchtower **vería** ahora mismo (dry run con logs verbosos) | `docker compose ... run --rm -e WATCHTOWER_SCHEDULE= watchtower --run-once --monitor-only --label-enable --debug` |
| Forzar actualizar **un** contenedor concreto, ignorando schedule | `docker compose ... run --rm -e WATCHTOWER_SCHEDULE= watchtower --run-once --cleanup <nombre-contenedor>` |
| Saltar la siguiente ventana sin parar Watchtower | `docker stop watchtower; <maintenance>; docker start watchtower` (Watchtower reprograma desde el siguiente tick) |
| Cambiar la cadencia | Editar `WATCHTOWER_SCHEDULE` en `docker-compose.yml` y `docker compose ... up -d` (recrea con nueva env) |
| Cambiar el canal de notificación | Editar `stacks/watchtower/.env`, `docker compose ... up -d` |

---

## Almacenamiento

| Ruta | Soporte | Owner:Group | Modo | Contenido |
|---|---|---|---|---|
| `/home/homelab/homelab/stacks/watchtower/docker-compose.yml` | microSD | `homelab:homelab` | `0640` | Stack versionado en git. |
| `/home/homelab/homelab/stacks/watchtower/.env.example` | microSD | `homelab:homelab` | `0644` | Plantilla versionada. |
| `/home/homelab/homelab/stacks/watchtower/.env` | microSD | `homelab:homelab` | `0600` | Variables de notificación (cuando se rellenen, pueden contener tokens). **No** versionado (cubierto por `.gitignore`). |
| `/var/run/docker.sock` | runtime | `root:docker` | `0660` | Socket de la API. Bindeado de solo-pasarela. |

**Sin** bind mounts a `/mnt/hd2t/apps/watchtower/`. Watchtower es **stateless**:

- No tiene base de datos.
- No cachea snapshots.
- El historial de actualizaciones vive en `docker logs watchtower` (rotación `json-file` definida en `daemon.json` por `01-instalacion-docker.md`).
- El estado de "qué digest tenía la imagen X la última vez" se reconstruye de Docker mismo en cada pasada.

> **Por qué no crear `/mnt/hd2t/apps/watchtower/` "por uniformidad"**: la convención del homelab es `/mnt/hd2t/apps/<svc>/` **cuando hay datos persistentes**. Crear un directorio vacío sólo invita a que algún script lo encuentre, lo respalde con Borg sin contenido y deje un artefacto sin sentido en los snapshots. No se crea.

---

## Backup

A nivel del repositorio del homelab:

| Artefacto | Estrategia |
|---|---|
| `stacks/watchtower/docker-compose.yml` | Versionado en git. Reproducible tras un reflasheo. |
| `stacks/watchtower/.env.example` | Versionado en git. |
| `stacks/watchtower/.env` real (con tokens de notificación, cuando los haya) | **No** versionado. Se mantiene una copia cifrada en el gestor de contraseñas del operador, junto al resto de credenciales del homelab. Tras un reflasheo se reescribe a mano: son ~3 líneas. |

A nivel de datos (Borgmatic, Fase 7):

| Ruta | ¿Se respalda? | Por qué |
|---|---|---|
| `/mnt/hd2t/apps/watchtower/` | **No** (no existe). | Stateless. |
| Logs `json-file` de `watchtower` (`/mnt/hd2t/docker/containers/<id>/...`) | **No**. | Información operativa, no datos. La rotación los purga. |

Procedimiento de restore:

1. Recrear el sistema base (Fase 1), reinstalar Docker (Fase 2.1), aplicar convenciones (Fase 2.2), desplegar Portainer (Fase 2.3).
2. Clonar el repo, copiar `stacks/watchtower/.env` desde el gestor de contraseñas (o dejarlo vacío y enchufar Gotify después).
3. `docker compose -f stacks/watchtower/docker-compose.yml up -d`.
4. Watchtower reaparece, lee la lista de contenedores enabled del daemon, programa la siguiente ventana. **Sin paso intermedio**.

---

## Errores frecuentes y troubleshooting

| Síntoma | Causa probable | Resolución |
|---|---|---|
| Watchtower arranca pero los logs dicen `Watching all containers` (sin `Only checking containers with enabled label`) | `WATCHTOWER_LABEL_ENABLE` ausente o con valor `"false"`. | Comprobar `.env` y env del compose; corregir y `up -d`. |
| Watchtower no actualiza nunca un contenedor que sí debería | Tag inmovilizado a parche concreto (p. ej. `portainer/portainer-ce:2.21.4-alpine`): el digest no cambia hasta que upstream republica esa versión exacta. | Comportamiento correcto. Para actualizar el patch se cambia el tag en el compose y se hace `up -d`. |
| Watchtower actualiza un servicio y queda **roto** | Upstream publicó una imagen con regresión dentro del mismo tag mayor. Riesgo asumido del modelo. | Editar el compose, fijar el tag al **digest** anterior (`@sha256:...` que aparece en `docker image ls --digests`) y `up -d`. Reportar/abrir issue en upstream. |
| `Permission denied while trying to connect to the Docker daemon socket` en los logs de Watchtower | Bind mount al socket roto o el socket cambió de permisos. | `ls -l /var/run/docker.sock` debe mostrar `srw-rw---- root docker`. Si no, revisar `01-instalacion-docker.md`. |
| `Skipping image refresh: account is not authenticated` | Watchtower intenta tirar de un registro privado sin credenciales. | Hoy no aplica (solo Docker Hub/GHCR públicos). Si en el futuro: `docker login` en el host **como `homelab`** y descomentar el bind mount al `~/.docker/config.json`. |
| `Error response from daemon: ... toomanyrequests` durante un `--run-once` | Docker Hub rate limit (anonymous: 100 pulls/6 h por IP). | Esperar la ventana del rate limit. Mitigación a futuro: `docker login` con cuenta gratuita (sube a 200), o usar GHCR para imágenes que estén allí. |
| Watchtower **sí** actualiza, pero **siempre** en seco (`0 scanned`) | El selector falla: o no hay contenedores con label, o el label está mal escrito (`com.centurylinklabs.watchtower.enabled` con `d` final, error típico). | El nombre exacto es `com.centurylinklabs.watchtower.enable`, sin `d`. Verificar con `docker inspect <name> --format '{{ json .Config.Labels }}'`. |
| Watchtower entra en bucle (actualiza, falla healthcheck, recrea, …) | El healthcheck del servicio es demasiado estricto y el contenedor recién recreado no llega a `(healthy)` antes del siguiente intento. | Subir `start_period` del servicio. Watchtower **no** reintenta agresivamente; el bucle suele venir de otro factor. Ver logs combinados. |
| `Notification template parse error` al primer arranque | El template multi-línea del compose se parseó mal por un copy-paste con tabs. | Reescribir el bloque `WATCHTOWER_NOTIFICATION_TEMPLATE` con espacios. Watchtower acepta el template embebido en YAML literal `|`. |
| El cron parece **una hora desfasado** (actualiza a las 03:00 en lugar de 04:00) | TZ del contenedor distinta de la del host (típicamente porque `TZ` no se propagó). | `docker exec watchtower date` debe mostrar la hora local correcta. Si no: comprobar `${TZ}` en el `.env` global y recrear. |
| Tras `up -d` el contenedor se queda `unhealthy` | El healthcheck `--help` falla porque la imagen `1.7.x` cambió flags. | Cambiar el `test` a `["CMD", "ls", "/watchtower"]`. La intención (proceso vivo) se mantiene. |
| Watchtower se actualizó a sí mismo y desapareció | El proceso de auto-update **se mata** durante el `stop+rm+run`; en algunas builds el contenedor sucesor no llega a quedar `Up`. | `docker compose -f stacks/watchtower/docker-compose.yml up -d --force-recreate`. Documentado en upstream como caso de borde, raro pero posible. |

---

## Decisiones que **no** se toman en este documento

- **Canal concreto de notificaciones (Gotify/ntfy/Apprise/Telegram)**: va en Fase 4 (monitorización). Aquí el stack queda **listo** con dos variables vacías.
- **Modo `--monitor-only` global**: descartado en este homelab (vaciaría de utilidad a Watchtower). Lo activable es **por contenedor** (`com.centurylinklabs.watchtower.monitor-only=true`).
- **Rollback automático ante fallo**: Watchtower no lo hace, y no se intenta replicar con scripts. El rollback en este homelab es **manual y trazable** (cambio de tag en git → `up -d`).
- **Pinning a digest (`image@sha256:...`)** por defecto: descartado para este homelab. Endurece demasiado las actualizaciones para el beneficio en seguridad de un entorno LAN+Tailscale. Se reabre puntualmente si un servicio sufre regresiones repetidas.
- **HTTP API mode** de Watchtower (disparar updates por webhook): descartado. No hay caso de uso en LAN; abriría un endpoint que no aporta sobre `docker compose run --rm`.
- **Política de exclusión de bases de datos por defecto**: la regla "BBDD fuera" se aplica **en cada documento de servicio** que despliegue una BBDD, poniendo el label a `"false"` y anotándolo. **No** se hace una blacklist centralizada en Watchtower porque Watchtower no soporta blacklists nativas más allá del label.
- **Integración con Portainer "Stacks" para mostrar el historial de actualizaciones**: descartado por la regla del 03 (el repo es la fuente de verdad). El historial real está en `git log` y en `docker logs watchtower`.

---

## Verificación Final

Antes de pasar a la Fase 3:

| Comprobación | Comando | Resultado esperado |
|---|---|---|
| Stack desplegado | `docker compose -f stacks/watchtower/docker-compose.yml ps` | `watchtower  ...  Up (healthy)` |
| Imagen correcta y fija | `docker inspect watchtower --format '{{.Config.Image}}'` | `containrrr/watchtower:1.7.1` |
| Bind del socket presente y único volumen | `docker inspect watchtower --format '{{range .Mounts}}{{.Source}}->{{.Destination}}{{"\n"}}{{end}}'` | una sola línea: `/var/run/docker.sock->/var/run/docker.sock` |
| Sin puertos publicados | `docker port watchtower` | (vacío) |
| Conectado a la red `homelab` | `docker network inspect homelab --format '{{range .Containers}}{{.Name}} {{end}}'` | incluye `watchtower` y `portainer` |
| Healthcheck verde | `docker inspect watchtower --format '{{.State.Health.Status}}'` | `healthy` |
| Modo opt-in activo | `docker logs watchtower 2>&1 \| grep -i "Only checking containers with enabled label"` | una línea coincidente |
| Schedule programado | `docker logs watchtower 2>&1 \| grep -i "Scheduling first run"` | una línea con la próxima ejecución a las 04:00 |
| Cobertura inicial correcta | `docker ps --filter "label=com.centurylinklabs.watchtower.enable=true" --format '{{.Names}}'` | `portainer`, `watchtower` (y nada más a esta altura) |
| Contenedores **no** cubiertos no aparecen | `docker ps --filter "label=com.centurylinklabs.watchtower.enable=false" --format '{{.Names}}'` | (vacío hoy; en fases siguientes listará BBDDs y servicios sensibles) |
| Pasada manual exitosa | `docker compose -f stacks/watchtower/docker-compose.yml run --rm -e WATCHTOWER_SCHEDULE= watchtower --run-once --label-enable` | termina con `Session done: N scanned, ...` y exit code `0` |
| TZ correcta dentro del contenedor | `docker exec watchtower date` | hora local de Madrid |
| Sin `/mnt/hd2t/apps/watchtower/` huérfano | `ls /mnt/hd2t/apps/watchtower 2>&1` | `No such file or directory` |
| Persistencia tras reboot | `sudo reboot`; tras reconectar: `docker ps --filter name=watchtower` | `Up ... (healthy)` sin acción manual |
| Stack en git | `git status` | `stacks/watchtower/docker-compose.yml` y `stacks/watchtower/.env.example` aparecen tracked; **ningún** `.env` filtrado |

Cumplido el último punto, la Fase 2 está cerrada: el motor de contenedores está instalado y configurado (2.1), las reglas para escribir stacks están fijadas (2.2), hay un panel para operar (2.3) y hay un mecanismo automatizado para mantener al día las imágenes (2.4). La siguiente puerta es decidir **cómo se da nombre y cómo se enruta** todo lo que va a vivir en este homelab: Pi-hole + Unbound, Tailscale, CA interna y Caddy. Eso es la Fase 3.

---

## Referencias

- [Documento anterior: `docs/02-docker/03-portainer.md`](./03-portainer.md)
- [Documento siguiente: `docs/03-red-dns/01-pihole.md`](../03-red-dns/01-pihole.md)
- [Documento relacionado: `docs/02-docker/02-estructura-compose.md`](./02-estructura-compose.md)
- [Watchtower — Documentación oficial](https://containrrr.dev/watchtower/)
- [Watchtower — Argumentos y variables de entorno](https://containrrr.dev/watchtower/arguments/)
- [Watchtower — Notificaciones (Apprise/shoutrrr)](https://containrrr.dev/watchtower/notifications/)
- [Watchtower — Selección por label (`--label-enable`)](https://containrrr.dev/watchtower/container-selection/)
- [Watchtower — Imagen oficial en Docker Hub](https://hub.docker.com/r/containrrr/watchtower)
- [shoutrrr — URLs de servicio (ntfy, Gotify, Telegram, …)](https://containrrr.dev/shoutrrr/services/overview/)
- [Diun — Alternativa solo-notificación](https://crazymax.dev/diun/)
- [Docker — Política de tags y digests inmutables](https://docs.docker.com/engine/reference/commandline/pull/#pull-an-image-by-digest-immutable-identifier)
