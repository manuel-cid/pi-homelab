# Watchtower

## Descripción

**Despliegue de Watchtower como actualizador automático de imágenes Docker** sobre el endpoint local de la Raspberry Pi 5. Watchtower observa periódicamente los contenedores en marcha, compara la **digest** del tag declarado en `image:` contra la del registro remoto y, si hay una nueva, hace `docker pull` + `docker stop` + `docker run` con la **misma** configuración (env, mounts, red, labels) y **borra** la imagen antigua. El propósito es absorber actualizaciones menores y patches de seguridad sin entrar por SSH a teclear `docker compose pull && up -d` en cada stack.

Este documento cubre, en este orden:

1. **Modelo de actualizaciones adoptado**: `--label-enable` (opt-in explícito por servicio) y por qué este homelab descarta el modo "actualizar todo lo que se mueva".
2. **Imagen, versión y arquitectura**: por qué `containrrr/watchtower` con tag fijo, soporte ARM64 y nota sobre el estado de mantenimiento del proyecto.
3. **Schedule, rolling restart y limpieza**: cron semanal en horario valle, una recreación cada vez, `--cleanup` para no acumular imágenes huérfanas.
4. **Notificaciones con `shoutrrr`**: estrategia (un único informe por ciclo) y plantilla para Telegram, ntfy y SMTP.
5. **Hooks pre/post-update por contenedor**: cómo otros docs (Nextcloud, Vaultwarden) podrán enchufar dumps de BD antes del reinicio.
6. **Política de exclusiones**: qué servicios **nunca** llevan `watchtower.enable=true` y por qué (BD, Pi-hole, Authelia, Home Assistant, Portainer).
7. **Despliegue dentro del stack `infra`** ya creado en [`03-portainer.md`](./03-portainer.md).
8. **Verificación**, **backup** y **solución de problemas**.

> **Alcance**: aquí solo se despliega Watchtower y se valida un primer ciclo. La opt-in por servicio (qué etiqueta lleva cada uno) está documentada en cada doc de servicio individual; la convención general la recoge [`02-estructura-compose.md`](./02-estructura-compose.md) §3.6.

> **Recordatorio**: el homelab opera en **LAN + Tailscale**. Watchtower **no expone ningún puerto** (no se usa la HTTP API): se gobierna solo por cron interno y notificaciones salientes.

---

## Requisitos Previos

- Docker Engine y Docker Compose v2 operativos según [`01-instalacion-docker.md`](./01-instalacion-docker.md).
- Convenciones y red `homelab` creadas según [`02-estructura-compose.md`](./02-estructura-compose.md).
- Stack `infra` ya inicializado en [`03-portainer.md`](./03-portainer.md):
  - `~/homelab/stacks/infra/docker-compose.yml` con el servicio `portainer`.
  - `/mnt/hd2t/services/infra/.env` con permisos `600` y la variable `PORTAINER_ADMIN_PASSWORD_HASH`.
  - `~/homelab/stacks/infra/.env.example` con la sección `# ----- Watchtower -----` (placeholder).
- Un canal de notificaciones disponible (al menos uno):
  - **Telegram**: bot creado con `@BotFather` y `chat_id` del operador (`@userinfobot`).
  - **ntfy**: tópico (público o autenticado) en `https://ntfy.sh/<topic>` o instancia self-hosted.
  - **SMTP**: cuenta de envío con app password (Gmail, Fastmail, Migadu...).
- Salida a internet desde la Pi (HTTPS hacia los registros: `registry-1.docker.io`, `ghcr.io`, `lscr.io`...). Pi-hole/Unbound (Fase 3) no debe filtrar registros públicos.

### Decisiones de diseño asumidas

| Decisión | Valor por defecto | Justificación |
|---|---|---|
| Selección de contenedores | **`WATCHTOWER_LABEL_ENABLE=true`** (opt-in) | Modo "todo lo que esté arriba" actualizaría también BD, Pi-hole, Authelia, Home Assistant... cualquiera de las cuales puede romperse en un upgrade menor (migraciones de schema, breaking changes silenciosos). El opt-in por etiqueta hace explícita la decisión por servicio: el doc de cada uno declara `com.centurylinklabs.watchtower.enable: "true"` o lo deja en `false`. |
| Tag de imagen | **`containrrr/watchtower:1.7.1`** (pinned), `arm64` | Pinear la versión del propio Watchtower evita que un fallo del actualizador rompa al actualizador. Las imágenes oficiales publican manifest multi-arch que incluye `linux/arm64`. |
| Self-update de Watchtower | **Sí**, etiqueta `enable: "true"` en él mismo | Watchtower es minúsculo y stateless: en caso de regresión, basta volver al tag pinned desde `docker-compose.yml`. El coste de habilitarlo es bajo y se mantiene la coherencia ("si el resto se actualiza solo, este también"). |
| Estado del proyecto upstream | **Aceptado, con plan B documentado** | El repositorio `containrrr/watchtower` ha tenido periodos de poca actividad. Si el mantenimiento se detiene definitivamente, el plan B es migrar a [`crazy-max/diun`](https://github.com/crazy-max/diun) (solo notificación de imágenes nuevas, actualización manual) o a un cron + `dockcheck.sh`. La etiqueta y la convención del homelab no cambian: ambos usan `com.centurylinklabs.watchtower.enable` por compatibilidad. |
| Frecuencia de chequeo | **Semanal, domingo 04:00**: `WATCHTOWER_SCHEDULE="0 0 4 * * 0"` | El homelab es uso doméstico: no hay SLA que justifique chequeo horario. Una sola pasada semanal en horario valle (madrugada de domingo) reduce I/O sobre los discos externos y minimiza ventanas de servicio degradado. La sintaxis cron de Watchtower es de **6 campos** (incluye segundos al inicio). |
| Modo de reinicio | **`WATCHTOWER_ROLLING_RESTART=true`** | Recreación de un contenedor cada vez. En una Pi con I/O limitada por USB 3.0, paralelizar reinicios (default) puede saturar el disco; rolling-restart serializa y reduce el pico. |
| Limpieza de imágenes antiguas | **`WATCHTOWER_CLEANUP=true`** | Tras una actualización, Watchtower hace `docker rmi` de la imagen previa **si no la usa nadie más**. Sin esto, en pocas semanas la microSD acumula GBs de imágenes huérfanas. Es seguro porque solo borra lo que ya nadie referencia. |
| Eliminación de volúmenes | **`WATCHTOWER_REMOVE_VOLUMES=false`** (default) | Mantener `false` es **innegociable**: borrar volúmenes anónimos al recrear pierde datos en imágenes que los declaran sin bind mount (Postgres oficial, etc.). Convención del homelab: bind mounts a `hd2t`, pero por seguridad se deja la flag explícitamente apagada. |
| Stopped containers | **`WATCHTOWER_INCLUDE_STOPPED=false`** | Si un contenedor está parado tiene una razón (debug, mantenimiento). Despertarlo automáticamente para actualizarlo enmascara estados; el operador volverá a levantarlo cuando toque. |
| Restarting containers | **`WATCHTOWER_INCLUDE_RESTARTING=false`** | Un contenedor en bucle de reinicio (crashloop) está mal: actualizarlo a la siguiente versión es disparar a un blanco móvil. Solo se actualizan contenedores estables. |
| Lifecycle hooks por contenedor | **`WATCHTOWER_LIFECYCLE_HOOKS=true`** | Permite que cada servicio defina `com.centurylinklabs.watchtower.lifecycle.pre-update` (script ejecutado **dentro** del contenedor antes de pararlo) y `.post-update`. Lo usarán Nextcloud, Vaultwarden y Bookstack para volcar la BD antes del upgrade ([`../07-backups/03-backup-docker-volumes.md`](../07-backups/03-backup-docker-volumes.md)). |
| Timeout de parada | **`WATCHTOWER_TIMEOUT=30s`** | 10 s (default) es corto para servicios con estado en RAM (Jellyfin, Nextcloud). 30 s evita `docker kill` prematuros y cierra limpio. |
| Modo monitor-only | **`false`** | Existe `WATCHTOWER_MONITOR_ONLY=true` (solo notifica, no actualiza), útil como **dry-run** durante el primer ciclo (§3.4). En operación normal, modo activo. |
| HTTP API | **Deshabilitada** | `WATCHTOWER_HTTP_API_UPDATE` permite disparar updates por HTTP con un token. No se usa: añade superficie y el cron interno basta. |
| Acceso al socket Docker | **Bind mount directo de `/var/run/docker.sock`** (lectura/escritura) | Al igual que Portainer ([`03-portainer.md`](./03-portainer.md)), Watchtower necesita escribir para hacer `pull/stop/run`. El proxy `docker-socket-proxy` se descarta por la misma razón (un contenedor adicional, un punto más de fallo) y porque Watchtower **no expone UI**: no hay sesiones humanas que hijackear. |
| Volumen de datos | **No tiene** | Watchtower es stateless: configuración por env y `command:`, nada que persistir. Solo `/etc/timezone` y `/etc/localtime` en read-only para que los logs lleven la hora local. |
| Red | **Solo `homelab`** | No es estrictamente necesaria (Watchtower no responde a nadie), pero estar en `homelab` simplifica que Prometheus la scrapee si se decide ([`../05-monitorizacion/01-prometheus.md`](../05-monitorizacion/01-prometheus.md), tema opcional). |
| Notificaciones | **Un único informe por ciclo** (`WATCHTOWER_NOTIFICATION_REPORT=true`) | Sin esto, cada contenedor actualizado dispara un mensaje propio: ruido innecesario. Con `report=true`, llega un solo mensaje por pasada con la lista de updates aplicados, fallidos y omitidos. |
| Read-only rootfs | **`read_only: true`** | Watchtower no escribe a disco. Se le da `tmpfs` para `/tmp` por si una librería interna usa caché efímera. |

---

## 1. Modelo de actualizaciones por etiquetas

### 1.1. Cómo se decide qué se actualiza

Watchtower arranca con `WATCHTOWER_LABEL_ENABLE=true`. A cada ciclo:

1. Lista todos los contenedores (`docker ps`).
2. Filtra por etiqueta `com.centurylinklabs.watchtower.enable=true`.
3. Por cada uno, consulta la digest del tag actual en el registro y la compara con la digest local.
4. Si difiere, hace `pull → stop → run` con la **misma** configuración (env, mounts, ports, networks, labels, command), respetando `--rolling-restart` (uno cada vez).
5. Si `cleanup=true`, elimina la imagen antigua si nadie más la referencia.
6. Tras procesar todos los candidatos del ciclo, envía **un** mensaje de notificación con el resumen.

> Watchtower **no** edita el `docker-compose.yml`. Por eso la operación es transparente para el flujo `editor → git commit → docker compose up -d`: el YAML versionado sigue declarando `image: foo/bar:1.2.3`, y Watchtower mantiene actualizada la digest detrás del **mismo** tag `1.2.3`. Cuando se haga un upgrade mayor (bump de tag), se cambia el YAML manualmente y se aplica con `docker compose up -d`.

### 1.2. La etiqueta canónica

Todo doc de servicio debe declarar **una** de estas dos etiquetas (sin valor por defecto implícito):

```yaml
labels:
  com.centurylinklabs.watchtower.enable: "true"   # opt-in
# o
  com.centurylinklabs.watchtower.enable: "false"  # opt-out explícito
```

Convenciones del homelab para cuándo usar cada una:

| Categoría | Recomendación | Ejemplos |
|---|---|---|
| Servicios stateless o de lectura ligera | `enable: "true"` | Jellyfin, Navidrome, Audiobookshelf, Calibre-Web, FreshRSS, Linkding, Stirling-PDF, Homepage, Caddy, Uptime Kuma, Dozzle, Node Exporter, cAdvisor, Prowlarr, Sonarr, Radarr, Transmission, Mosquitto, Node-RED, Syncthing, Watchtower mismo |
| Bases de datos y stores con esquema | `enable: "false"` | MariaDB, PostgreSQL, Redis (cuando lo usen Nextcloud/Authelia) |
| Aplicaciones con migraciones automáticas críticas | `enable: "false"` y upgrade manual | Nextcloud, Vaultwarden, Bookstack, Authelia, Home Assistant, Paperless-ngx, Mealie |
| Componentes que afectan a la red base | `enable: "false"` | Pi-hole, Unbound, Tailscale (si es contenedor) |
| Panel de gestión | `enable: "false"` | Portainer (justificación en su doc §0) |

> **Regla práctica**: si el upgrade del servicio puede requerir intervención (mensaje "run `occ upgrade`", migración de schema, cambio de `compose.yml` por nuevas variables), va en `false`. Si el upgrade es transparente y el README upstream promete compatibilidad dentro del tag (`1.7`, `2`, `latest-stable`), va en `true`.

### 1.3. Lifecycle hooks por contenedor

Para servicios con BD embebida que **sí** se actualizan automáticamente (no muchos: la práctica del homelab es excluirlos), Watchtower puede ejecutar comandos dentro del contenedor antes/después de la actualización. Se documenta aquí porque la receta vivirá replicada en varios docs:

```yaml
labels:
  com.centurylinklabs.watchtower.enable: "true"
  com.centurylinklabs.watchtower.lifecycle.pre-update: "/usr/local/bin/dump-before-update.sh"
  com.centurylinklabs.watchtower.lifecycle.pre-update-timeout: "120"   # segundos
  com.centurylinklabs.watchtower.lifecycle.post-update: "/usr/local/bin/post-update.sh"
```

`pre-update` se ejecuta **dentro** del contenedor antiguo justo antes del `stop`; un código de salida `≠ 0` cancela la actualización (Watchtower deja el contenedor como estaba). Un `pre-update.sh` típico volca la BD a `/data/backups/pre-update-$(date).sql.gz` que está bind-mounted a `/mnt/hd2t/services/<stack>/<servicio>/backups`.

Para los servicios `enable: "false"` (que no pasan por Watchtower), Borgmatic ([`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md)) cubre el dump previo a cualquier upgrade manual.

---

## 2. Notificaciones con `shoutrrr`

Watchtower 1.7+ usa [`shoutrrr`](https://containrrr.dev/shoutrrr/v0.8/) para notificaciones: una librería que abstrae múltiples destinos detrás de URLs uniformes. El homelab define **una** URL en `WATCHTOWER_NOTIFICATION_URL` (admite varias separadas por espacio para multi-canal).

### 2.1. Telegram (recomendado para el primer canal)

1. Hablar con [`@BotFather`](https://t.me/BotFather), comando `/newbot`, anotar el `token` (formato `123456789:ABC-DEF...`).
2. Hablar con [`@userinfobot`](https://t.me/userinfobot), anotar el `chat_id` (numérico, p. ej. `987654321`).
3. Enviar un mensaje **manual** al bot creado (Telegram requiere que el chat esté inicializado por el usuario).
4. URL `shoutrrr`:
   ```
   telegram://<token>@telegram?chats=<chat_id>
   ```

Ejemplo (con valores ficticios):

```
telegram://123456789:ABC-DEFghiJKL_mnop@telegram?chats=987654321
```

### 2.2. ntfy (alternativa simple, self-hostable más adelante)

Si se usa el servicio público `ntfy.sh` con un tópico secreto:

```
ntfy://ntfy.sh/<tópico-largo-aleatorio>
```

Para una instancia auth-protegida:

```
ntfy://<usuario>:<password>@<host>/<tópico>
```

### 2.3. SMTP (correo)

```
smtp://<usuario>:<app-password>@<host>:<puerto>/?from=<from>&to=<to>&subject=Watchtower%20%7C%20Pi%20Homelab
```

Ejemplo Fastmail:

```
smtp://yo%40dominio.com:abcd-efgh-ijkl-mnop@smtp.fastmail.com:587/?from=yo%40dominio.com&to=yo%40dominio.com&subject=Watchtower
```

> Atención al `url-encoding`: `@` → `%40`, espacios → `%20`.

### 2.4. Multi-canal

Para mandar a Telegram **y** correo simultáneamente, separar URLs con un espacio:

```
WATCHTOWER_NOTIFICATION_URL="telegram://...@telegram?chats=... smtp://...@smtp.fastmail.com:587/?..."
```

### 2.5. Plantilla del informe

Watchtower trae una plantilla por defecto (formato `[ {{Hostname}} ] Updated: ... Failed: ... Skipped: ...`). Para sustituirla, añadir `WATCHTOWER_NOTIFICATION_TEMPLATE` con sintaxis Go template. Para este homelab basta el default; se documenta una variante mínima en §3.3 por si interesa Markdown limpio en Telegram.

---

## 3. Despliegue

### 3.1. Completar `.env.example` y `.env`

Añadir las claves de Watchtower al fichero plantilla del repo:

```bash
# ~/homelab/stacks/infra/.env.example  (versionable)
# Sustituir o añadir tras la sección de Portainer:

cat >> ~/homelab/stacks/infra/.env.example <<'EOF'

# ----- Watchtower -----
# URL shoutrrr (un canal o varios separados por espacio).
# Telegram: telegram://<token>@telegram?chats=<chat_id>
# ntfy:     ntfy://ntfy.sh/<topic>
# smtp:     smtp://user:pass@host:587/?from=...&to=...&subject=...
WATCHTOWER_NOTIFICATION_URL=

# Hostname que Watchtower mostrará en cada mensaje.
WATCHTOWER_HOSTNAME=raspi-homelab
EOF
```

> Antes de añadir, comprobar que las dos claves no estén ya: `grep WATCHTOWER ~/homelab/stacks/infra/.env.example`. Si la línea `WATCHTOWER_NOTIFICATION_URL=` ya existe del esqueleto del doc anterior, sustituir el bloque a mano en lugar de hacer `>>`.

Rellenar el `.env` real en `hd2t` con la URL del canal elegido:

```bash
{
  echo
  echo "# ===== Watchtower ====="
  echo 'WATCHTOWER_NOTIFICATION_URL=telegram://<token>@telegram?chats=<chat_id>'
  echo 'WATCHTOWER_HOSTNAME=raspi-homelab'
} >> /mnt/hd2t/services/infra/.env

# Comprobar que el fichero sigue siendo 600 y propiedad del operador.
ls -l /mnt/hd2t/services/infra/.env
# Esperado: -rw------- 1 homelab homelab ...
```

### 3.2. Probar la URL de notificación

Antes de pasar Watchtower al schedule semanal, validar que la URL emite contra el canal elegido sin tocar la configuración del homelab:

```bash
# Reemplazar <URL> por la URL completa del .env (entre comillas dobles).
docker run --rm \
  containrrr/shoutrrr:0.8.0 \
  send --url "<URL>" --message "Watchtower: ping desde la Pi"
```

> Esperado: en menos de 5 s aparece "Watchtower: ping desde la Pi" en el canal. Si no llega, depurar **aquí** (token incorrecto, chat sin inicializar, SMTP rechazando AUTH) antes de pasar al despliegue. La imagen de `shoutrrr` independiente facilita debug sin tocar el contenedor real.

### 3.3. Editar el `docker-compose.yml` del stack `infra`

Añadir el servicio `watchtower` al `docker-compose.yml` que ya contiene Portainer:

```yaml
# ~/homelab/stacks/infra/docker-compose.yml
name: infra

services:
  portainer:
    # ... (sin cambios respecto a 03-portainer.md §2)

  watchtower:
    image: containrrr/watchtower:1.7.1
    container_name: watchtower
    hostname: watchtower
    restart: unless-stopped
    depends_on:
      - portainer
    env_file:
      - /mnt/hd2t/services/infra/.env
    environment:
      TZ: ${TZ}
      # Selección de contenedores.
      WATCHTOWER_LABEL_ENABLE: "true"
      WATCHTOWER_INCLUDE_STOPPED: "false"
      WATCHTOWER_INCLUDE_RESTARTING: "false"
      # Cadencia y comportamiento de actualización.
      WATCHTOWER_SCHEDULE: "0 0 4 * * 0"        # cron 6 campos: domingo 04:00:00
      WATCHTOWER_ROLLING_RESTART: "true"
      WATCHTOWER_CLEANUP: "true"
      WATCHTOWER_REMOVE_VOLUMES: "false"
      WATCHTOWER_TIMEOUT: "30s"
      WATCHTOWER_LIFECYCLE_HOOKS: "true"
      # Logs.
      WATCHTOWER_DEBUG: "false"
      WATCHTOWER_LOG_LEVEL: "info"
      # Notificaciones (un solo informe por ciclo, vía shoutrrr).
      WATCHTOWER_NOTIFICATION_REPORT: "true"
      WATCHTOWER_NOTIFICATIONS: "shoutrrr"
      WATCHTOWER_NOTIFICATION_URL: ${WATCHTOWER_NOTIFICATION_URL}
      WATCHTOWER_NOTIFICATIONS_HOSTNAME: ${WATCHTOWER_HOSTNAME}
      WATCHTOWER_NOTIFICATIONS_LEVEL: "info"    # info | warn | error
    volumes:
      - type: bind
        source: /var/run/docker.sock
        target: /var/run/docker.sock
        read_only: false
      - type: bind
        source: /etc/timezone
        target: /etc/timezone
        read_only: true
      - type: bind
        source: /etc/localtime
        target: /etc/localtime
        read_only: true
    networks:
      - homelab
    security_opt:
      - no-new-privileges:true
    read_only: true
    tmpfs:
      - /tmp:size=16M,mode=1777
    labels:
      com.centurylinklabs.watchtower.enable: "true"
      homepage.group: "Infraestructura"
      homepage.name: "Watchtower"
      homepage.icon: "watchtower.png"
      homepage.description: "Actualización automática de contenedores"

networks:
  homelab:
    external: true
```

#### 3.3.1. Por qué cada bloque diverge de la plantilla base

| Bloque | Diferencia respecto a [`02-estructura-compose.md`](./02-estructura-compose.md) §6 | Razón |
|---|---|---|
| `user:` ausente | La plantilla pone `user: "${PUID}:${PGID}"` | Watchtower necesita el socket Docker (`/var/run/docker.sock`, `root:docker` en el host) y hacer `docker pull` requiere root dentro del contenedor. La imagen oficial corre como `root:root` por diseño. Mismo razonamiento que Portainer. |
| `cap_drop: ALL` ausente | La plantilla lo recomienda | Equivalente a `root` del host vía socket Docker; las capabilities son cosmética en este contexto. |
| `read_only: true` aplicado | La plantilla pone `false` por defecto | Watchtower no escribe al disco; activarlo reduce el blast radius si una versión futura tuviera una vulnerabilidad. Se da `tmpfs` de 16 MB para `/tmp`. |
| Sin `volumes` para `/config` ni `/data` | La plantilla los pone | Watchtower es stateless: no tiene configuración persistente. |
| `/etc/timezone` y `/etc/localtime` montados | La plantilla solo declara `TZ` | El binario de Watchtower lee el reloj del sistema para los timestamps de los logs y, sobre todo, **para el cron**: sin `localtime` montado, `WATCHTOWER_SCHEDULE` se interpreta en UTC. Coherente con `TZ=Europe/Madrid` del `.env`. |
| `healthcheck:` ausente | La plantilla lo incluye | La imagen oficial **no** define healthcheck propio y no expone endpoint HTTP. Crear uno con `pidof watchtower` daría señal mínima; se prefiere no engañar al operador con un "healthy" superficial. El `restart: unless-stopped` y los logs son suficientes. |
| `ports:` ausente | La plantilla evita `ports:` | No hay HTTP API: nada que publicar. |
| `depends_on: - portainer` | La plantilla no lo usa por defecto | Asegura un orden estable de arranque al levantar el stack `infra`. No es funcionalmente necesario (Watchtower descubre lo que sea por el socket), pero facilita lectura del estado en `docker compose ps`. |
| `labels` Watchtower con `true` | La plantilla pone `true` | Self-update activado. |
| `labels` Homepage sin `homepage.href` | La plantilla incluye `homepage.href` | Watchtower no tiene UI: forzar `href` rompería el badge en Homepage; mejor omitir y dejar que el panel lo muestre como "informativo". |

#### 3.3.2. Plantilla de notificación opcional (Markdown limpio en Telegram)

Si los mensajes de Telegram resultan ruidosos, sustituir el default por una plantilla Markdown:

```yaml
    environment:
      # ... resto igual
      WATCHTOWER_NOTIFICATION_TEMPLATE: |
        {{- if .Report -}}
        *Watchtower @ {{.Host}}*
        Updated: {{len .Report.Updated}} · Failed: {{len .Report.Failed}} · Skipped: {{len .Report.Skipped}}
        {{- if .Report.Updated}}

        *Updated:*
        {{- range .Report.Updated}}
        • `{{.Name}}`  →  `{{.ImageName}}` ({{.CurrentImageID.ShortID}}→{{.LatestImageID.ShortID}})
        {{- end}}
        {{- end}}
        {{- if .Report.Failed}}

        *Failed:*
        {{- range .Report.Failed}}
        • `{{.Name}}`: {{.Error}}
        {{- end}}
        {{- end}}
        {{- end}}
      WATCHTOWER_NOTIFICATION_TEMPLATE_PARSE_MODE: "MarkdownV2"
```

> El parse mode se ignora en SMTP/ntfy: Telegram lo interpreta y emite negritas y `código`. Si se usa multi-canal, mantener un texto plano legible también sin Markdown.

### 3.4. Primera pasada en modo dry-run

Antes de habilitar el cron semanal, comprobar que Watchtower discrimina correctamente y que la notificación llega. Se hace con `--run-once` y `--monitor-only`:

```bash
cd ~/homelab/stacks/infra

# Asegurar que el .env real está accesible (variables interpoladas en YAML).
docker compose --env-file /mnt/hd2t/services/infra/.env config >/dev/null \
  && echo "Compose OK"

# Ejecutar Watchtower en modo "ver y notificar, no actualizar".
docker run --rm \
  --name watchtower-dryrun \
  --env-file /mnt/hd2t/services/infra/.env \
  -e TZ="$(cat /etc/timezone)" \
  -e WATCHTOWER_LABEL_ENABLE=true \
  -e WATCHTOWER_RUN_ONCE=true \
  -e WATCHTOWER_MONITOR_ONLY=true \
  -e WATCHTOWER_NOTIFICATION_REPORT=true \
  -e WATCHTOWER_NOTIFICATIONS=shoutrrr \
  -e WATCHTOWER_NOTIFICATION_URL="${WATCHTOWER_NOTIFICATION_URL}" \
  -e WATCHTOWER_NOTIFICATIONS_HOSTNAME=raspi-homelab-dryrun \
  -e WATCHTOWER_DEBUG=true \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v /etc/timezone:/etc/timezone:ro \
  -v /etc/localtime:/etc/localtime:ro \
  containrrr/watchtower:1.7.1
```

> Esperado: en pocos segundos Watchtower lista los contenedores con `enable=true`, decide quién tendría updates y manda **un** informe al canal con el resumen "Updated: N, Failed: 0, Skipped: M". Como `MONITOR_ONLY=true`, no toca nada. Tras la salida del comando, no queda contenedor `watchtower-dryrun` (`--rm`).

Si todo cuadra, levantar el servicio definitivo:

```bash
cd ~/homelab/stacks/infra
docker compose --env-file /mnt/hd2t/services/infra/.env up -d watchtower

docker compose ps
docker logs --tail=50 watchtower
```

Salida esperada:

```
NAME         IMAGE                              STATUS              PORTS
portainer    portainer/portainer-ce:2.21.5      Up X minutes (healthy)   127.0.0.1:9443->9443/tcp, ...
watchtower   containrrr/watchtower:1.7.1        Up X seconds
```

Y en `docker logs watchtower`, una línea final tipo:

```
time="..." level=info msg="Scheduling first run: <timestamp del próximo domingo 04:00>"
time="..." level=info msg="Note that the first check will be performed in <X> hours, <Y> minutes"
```

### 3.5. Forzar una pasada manual cuando convenga

Para validar la integración tras un cambio de configuración, **sin** esperar al cron:

```bash
# Opción 1: HUP al proceso (Watchtower lo interpreta como "ejecuta una pasada ahora").
docker kill --signal=SIGHUP watchtower

# Opción 2: Recrear con WATCHTOWER_RUN_ONCE=true en una pasada efímera.
docker run --rm --name watchtower-once \
  --env-file /mnt/hd2t/services/infra/.env \
  -e WATCHTOWER_LABEL_ENABLE=true \
  -e WATCHTOWER_RUN_ONCE=true \
  -e WATCHTOWER_CLEANUP=true \
  -e WATCHTOWER_NOTIFICATION_REPORT=true \
  -e WATCHTOWER_NOTIFICATIONS=shoutrrr \
  -e WATCHTOWER_NOTIFICATION_URL="${WATCHTOWER_NOTIFICATION_URL}" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  containrrr/watchtower:1.7.1
```

> `SIGHUP` es la vía oficial documentada por Watchtower para "trigger an update check". El contenedor sigue arriba y vuelve a su `WATCHTOWER_SCHEDULE` después.

---

## 4. Política de exclusiones del homelab

Lista vinculante (la que cada doc de servicio aplicará en su `labels:`). Si un servicio futuro no aparece, por defecto va con `enable: "false"` hasta que su doc lo justifique.

### 4.1. Servicios excluidos (`enable: "false"`)

| Servicio | Doc | Razón |
|---|---|---|
| Portainer | [`03-portainer.md`](./03-portainer.md) | Migraciones de BD interna entre versiones mayores; la UI puede romperse. Upgrade manual con rollback. |
| Pi-hole | [`../03-red/02-pihole.md`](../03-red/02-pihole.md) | Cambios de schema en `pihole-FTL` y migraciones de listas. Si Pi-hole cae a las 04:00, todo el DNS local queda en fallback hasta el próximo arranque. |
| Unbound | [`../03-red/03-unbound.md`](../03-red/03-unbound.md) | Es la dependencia upstream de Pi-hole. Mismo razonamiento. |
| Caddy | [`../03-red/04-caddy.md`](../03-red/04-caddy.md) | **Excepción al "stateless"**: Caddy v2 ha cambiado sintaxis del `Caddyfile` entre minor releases. Update manual tras leer changelog. (Si en futuras versiones se estabiliza, reevaluar). |
| Tailscale | [`../03-red/05-tailscale.md`](../03-red/05-tailscale.md) | El cliente está atado al daemon del host; si se despliega como contenedor, pasa a manual por mismas razones de red. |
| Authelia | [`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md) | Cambios en formato de `configuration.yml` entre versiones; un upgrade silencioso puede dejar a todos los servicios protegidos sin login. |
| MariaDB / PostgreSQL | (en cada doc de la app que la use) | Migraciones de schema mayor (MariaDB 10→11, Postgres 15→16) requieren `mariadb-upgrade` / `pg_upgrade`. Watchtower no las orquesta. |
| Redis | (cuando lo despliegue Authelia/Nextcloud) | Cambios de protocolo entre majors; aunque raros, se prefiere control. |
| Nextcloud | [`../06-almacenamiento/01-nextcloud.md`](../06-almacenamiento/01-nextcloud.md) | `occ upgrade` requiere intervención del operador en majors. |
| Vaultwarden | [`../11-productividad/01-vaultwarden.md`](../11-productividad/01-vaultwarden.md) | BD SQLite con migraciones; se actualiza tras dump explícito. |
| Bookstack | [`../11-productividad/02-bookstack.md`](../11-productividad/02-bookstack.md) | Migraciones de Laravel; mejor con backup previo. |
| Paperless-ngx | [`../11-productividad/04-paperless-ngx.md`](../11-productividad/04-paperless-ngx.md) | Migraciones de Django + reindex. |
| Mealie | [`../11-productividad/05-mealie.md`](../11-productividad/05-mealie.md) | Cambios de schema entre minors (proyecto en evolución activa). |
| Home Assistant | [`../08-domotica/01-home-assistant.md`](../08-domotica/01-home-assistant.md) | Breaking changes documentados cada release; upgrade manual leyendo el blog. |
| Zigbee2MQTT | [`../08-domotica/03-zigbee2mqtt.md`](../08-domotica/03-zigbee2mqtt.md) | Compatibilidad firmware del adaptador USB; upgrade tras revisar cambios. |
| Stash | [`../09-multimedia/05-stash.md`](../09-multimedia/05-stash.md) | Migraciones de la BD de metadatos. |

### 4.2. Servicios incluidos (`enable: "true"`)

Todo lo que no esté en §4.1: Jellyfin, Navidrome, Audiobookshelf, Calibre-Web, Transmission, Prowlarr, Sonarr, Radarr, Mosquitto, Node-RED, Syncthing, MinIO, Samba, FreshRSS, Linkding, Stirling-PDF, Homepage, Prometheus, Grafana, Node Exporter, cAdvisor, Uptime Kuma, Dozzle, Watchtower mismo. Cada doc respectivo confirmará la decisión y, si la cambia, la justificará en su tabla de decisiones.

---

## 5. Almacenamiento

| Ruta dentro del contenedor | Origen en el host | Contenido | Backup |
|---|---|---|---|
| `/var/run/docker.sock` | `/var/run/docker.sock` (bind) | Socket Unix del demonio Docker | No (es runtime) |
| `/etc/timezone` | `/etc/timezone` (bind, ro) | Zona horaria del host | No |
| `/etc/localtime` | `/etc/localtime` (bind, ro) | Reloj local del host | No |
| `/tmp` | `tmpfs` 16 MB | Caché efímera | No |
| (sin volumen de datos) | — | Watchtower es stateless | No |

Watchtower no tiene **ningún** dato persistente. La única configuración que importa fuera del contenedor está en `/mnt/hd2t/services/infra/.env` (compartido con Portainer) y en el `docker-compose.yml` versionado en git. Eso es todo lo que hay que respaldar.

---

## 6. Backup

Estrategia (la implementación concreta vive en [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md)):

1. **`/mnt/hd2t/services/infra/.env`** entra en el set "secrets" de Borg (ya estaba para Portainer; las claves de Watchtower son las mismas filas en el mismo fichero).
2. **`~/homelab/stacks/infra/docker-compose.yml`** y **`.env.example`** ya están en git (set "configs" como red de seguridad en Borg).
3. **No hay nada más que respaldar**: ni base de datos, ni configuración derivada.

### 6.1. Restaurar tras pérdida total

```bash
# 1. Reinstalar OS, Docker y red 'homelab' (Fases 0-2.2).
# 2. Restaurar repo de stacks desde git remote.
git clone <remote> ~/homelab

# 3. Restaurar /mnt/hd2t/services/infra/.env desde Borg.
borg extract <repo>::<archivo> mnt/hd2t/services/infra/.env

# 4. Levantar el stack completo (Portainer + Watchtower).
cd ~/homelab/stacks/infra
docker compose --env-file /mnt/hd2t/services/infra/.env up -d
```

### 6.2. Reset de Watchtower (sin tocar Portainer)

```bash
cd ~/homelab/stacks/infra
docker compose --env-file /mnt/hd2t/services/infra/.env stop watchtower
docker compose --env-file /mnt/hd2t/services/infra/.env rm -f watchtower
docker compose --env-file /mnt/hd2t/services/infra/.env up -d watchtower
```

> No hay datos que perder: el reset es seguro a cualquier hora.

---

## 7. Verificación

### 7.1. Lista de Verificación

Antes de pasar a la Fase 3:

- [ ] `docker compose ps` (en `~/homelab/stacks/infra`) muestra **dos** servicios: `portainer (healthy)` y `watchtower (running)`.
- [ ] `docker inspect watchtower --format '{{.State.Status}}'` devuelve `running`.
- [ ] `docker port watchtower` no muestra ningún puerto publicado.
- [ ] `docker inspect watchtower --format '{{json .Config.Env}}' | tr ',' '\n' | grep WATCHTOWER` lista `WATCHTOWER_LABEL_ENABLE=true`, `WATCHTOWER_SCHEDULE=0 0 4 * * 0`, `WATCHTOWER_CLEANUP=true`, `WATCHTOWER_ROLLING_RESTART=true`, `WATCHTOWER_REMOVE_VOLUMES=false` y `WATCHTOWER_NOTIFICATION_URL` con un valor no vacío.
- [ ] `docker logs watchtower 2>&1 | grep -i "scheduling first run"` muestra una fecha futura coherente (próximo domingo 04:00 en hora local del host).
- [ ] `docker exec watchtower date` devuelve la hora local de Madrid (validación de `localtime` montado).
- [ ] `docker network inspect homelab --format '{{range .Containers}}{{.Name}} {{end}}'` lista `watchtower` entre los conectados.
- [ ] `docker inspect watchtower --format '{{.HostConfig.ReadonlyRootfs}}'` devuelve `true`.
- [ ] `docker inspect watchtower --format '{{json .Config.Labels}}'` muestra `com.centurylinklabs.watchtower.enable: "true"` (self-update activo).
- [ ] El dry-run de §3.4 mandó **un** mensaje al canal de notificaciones con el resumen de updates pendientes, y `docker ps -a | grep dryrun` no devuelve ningún contenedor (`--rm` lo limpió).
- [ ] `docker kill --signal=SIGHUP watchtower` provoca, en menos de 30 s, una nueva entrada `Session done` en `docker logs watchtower` y (si había updates) un mensaje en el canal.
- [ ] `git -C ~/homelab status` no lista ningún `.env` ni la URL de notificación como untracked (solo `docker-compose.yml` y `.env.example` modificados con los placeholders).
- [ ] Buscar accidentes: `git -C ~/homelab grep -nE "telegram://|smtp://[^?]+:|ntfy://[^?]+:" -- '*.yml' '*.example'` debe devolver vacío (ningún token real versionado).

### 7.2. Test de la primera actualización real

Después de una semana, verificar el primer ciclo automático:

```bash
# El domingo siguiente, en cualquier momento posterior a las 04:00:
docker logs watchtower 2>&1 | grep -E "Session done|Found new"
# Esperado: una línea "Session done" del domingo a las 04:00:XX y, si hubo updates,
# una o más líneas "Found new <repo>:<tag> image (...)".
```

Y en el canal de notificaciones, un único mensaje "Watchtower @ raspi-homelab" con el resumen.

### 7.3. Test de exclusión efectiva

Comprobar que un servicio con `enable: "false"` **no** aparece en la lista de actualización:

```bash
docker run --rm \
  --env-file /mnt/hd2t/services/infra/.env \
  -e WATCHTOWER_LABEL_ENABLE=true \
  -e WATCHTOWER_RUN_ONCE=true \
  -e WATCHTOWER_MONITOR_ONLY=true \
  -e WATCHTOWER_DEBUG=true \
  -e WATCHTOWER_NOTIFICATIONS=shoutrrr \
  -e WATCHTOWER_NOTIFICATION_REPORT=true \
  -e WATCHTOWER_NOTIFICATION_URL="${WATCHTOWER_NOTIFICATION_URL}" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  containrrr/watchtower:1.7.1 2>&1 | grep -E "Considering|Skipped"
```

> Esperado: las líneas `Considering ...` listan **solo** los contenedores con `enable: "true"`. `portainer` (que está `false`) no aparece.

---

## 8. Solución de Problemas

| Síntoma | Causa probable | Acción |
|---|---|---|
| `watchtower` arranca pero `docker logs` queda mudo más allá de "Watchtower vX.Y.Z" | Falta `WATCHTOWER_SCHEDULE` o el cron no es válido (Watchtower usa **6 campos**, con segundos al inicio). | Corregir a `0 0 4 * * 0` (no `0 4 * * 0`). Recrear con `docker compose up -d --force-recreate watchtower`. |
| `time="..." level=fatal msg="Failed to parse cron expression"` | Confusión cron 5 vs 6 campos. | Idem; Watchtower no acepta 5 campos. |
| `WATCHTOWER_SCHEDULE` se interpreta en UTC en lugar de Europe/Madrid | Falta el bind `/etc/localtime` o `TZ` no está definida. | Verificar `docker exec watchtower date`; si devuelve UTC, comprobar el bloque `volumes:` con `/etc/timezone` y `/etc/localtime` en `read_only: true`. |
| Mensaje de notificación llega **una vez por contenedor** en lugar de uno por ciclo | `WATCHTOWER_NOTIFICATION_REPORT` no está a `true`. | Añadirlo y `up -d --force-recreate watchtower`. |
| `notification: failed to send: parse "<url>": ...` | URL `shoutrrr` mal formada o caracteres sin url-encoding. | Recodificar `@`, `:`, `/`, `?` y caracteres especiales del password (`%40`, `%3A`, etc.). Validar con la imagen de `shoutrrr` aislada (§3.2). |
| Telegram devuelve `chat not found` | El bot no ha recibido **nunca** un mensaje del usuario. | Abrir el chat, enviar `/start` al bot, reintentar. |
| Watchtower no actualiza un contenedor que sí lleva `enable: "true"` | El tag declarado es `latest` y el registro lo sirve por digest **flotante** que coincide con la local. O el servicio se reinicia (`unhealthy`/`restarting`) durante el ciclo y `WATCHTOWER_INCLUDE_RESTARTING=false` lo descarta. | Comprobar con `docker inspect <c> --format '{{.Image}}'` y `docker pull <repo>:<tag>` manual: si `pull` no trae nada, no hay nueva digest. Si el contenedor está inestable, arreglarlo antes de esperar updates. |
| Watchtower borra demasiadas imágenes (rompe rollback) | `WATCHTOWER_CLEANUP=true` elimina la imagen previa cuando ningún contenedor la referencia. | Para conservar versiones previas durante un tiempo, poner `cleanup: false` y limpiar manualmente con `docker image prune -a --filter "until=720h"` (30 días). |
| Tras un update, un servicio ya no arranca | Imagen nueva con breaking change. | Volver a la imagen anterior: editar `image:` en `docker-compose.yml` al tag previo (visible en `docker logs watchtower`: "Found new ... image" indica también el `ImageID` antiguo) y `docker compose up -d --force-recreate <servicio>`. Anotar el incidente en `AGENTS.md` o doc del servicio para trasladar el `enable` a `false`. |
| `watchtower` no se actualiza a sí mismo | Falta su propia label, o `WATCHTOWER_LABEL_ENABLE` no está activo. | Confirmar `docker inspect watchtower --format '{{.Config.Labels}}'` incluye `com.centurylinklabs.watchtower.enable=true`. |
| `Failed to update container ...: Error response from daemon: pull access denied` | Imagen privada (registry interno o tag eliminado upstream). | Si es registry privado, montar `~/.docker/config.json` en `/config.json` dentro del contenedor (`-v ~/.docker/config.json:/config.json:ro`). Si el tag desapareció, fijar `image:` a la versión disponible más cercana. |
| Watchtower consume RAM de forma sostenida (>200 MB en una Pi) | Cada ciclo crea goroutines que en versiones <1.6 podían filtrar memoria. | Confirmar versión `>=1.7.0`. Reiniciar `docker compose restart watchtower` si la RAM no baja tras un ciclo. |
| `Lifecycle hook failed: exit status 127` | El script declarado en `lifecycle.pre-update` no existe dentro del contenedor objetivo o no es ejecutable. | Verificar con `docker exec <servicio> ls -l /usr/local/bin/dump-before-update.sh`. Recordar que el hook se ejecuta **dentro** del contenedor, no en el host. |
| Notificaciones duplicadas en multi-canal | URLs concatenadas con coma en lugar de espacio. | `WATCHTOWER_NOTIFICATION_URL` separa con **espacio** (no coma). |
| `docker compose pull watchtower` trae tag `latest` aunque el YAML pone `1.7.1` | `image:` mal escrito o `name: infra` colisiona con un proyecto previo en cache. | Verificar `docker compose --env-file /mnt/hd2t/services/infra/.env config | grep image` muestra `containrrr/watchtower:1.7.1`. Si no, corregir el YAML y `up -d --force-recreate`. |
| El proyecto upstream lleva meses sin commits y empiezan a aparecer CVEs en libs internas | Mantenimiento del repo cuestionable. | Plan B: migrar a `crazy-max/diun` (notify-only) + script `dockcheck.sh` cron-eado, manteniendo la convención de etiquetas para no tocar todos los docs. Documentar el cambio en este fichero al final. |

---

## Referencias

- [Watchtower — Documentación oficial](https://containrrr.dev/watchtower/)
- [Watchtower — Container selection (`label-enable`)](https://containrrr.dev/watchtower/container-selection/)
- [Watchtower — Arguments / variables de entorno](https://containrrr.dev/watchtower/arguments/)
- [Watchtower — Lifecycle hooks (`pre-update`, `post-update`)](https://containrrr.dev/watchtower/lifecycle-hooks/)
- [Watchtower — Schedule (cron 6 campos)](https://containrrr.dev/watchtower/arguments/#scheduling)
- [Watchtower — Notifications (shoutrrr)](https://containrrr.dev/watchtower/notifications/)
- [shoutrrr — URL formats por servicio](https://containrrr.dev/shoutrrr/v0.8/services/overview/)
- [Telegram — `@BotFather` para crear bots](https://core.telegram.org/bots/tutorial)
- [ntfy.sh — Publish/subscribe HTTP simple](https://docs.ntfy.sh/)
- [Docker — Bind mount del socket Docker](https://docs.docker.com/engine/security/protect-access/)
- [diun — Alternativa notify-only si Watchtower deja de mantenerse](https://crazymax.dev/diun/)
