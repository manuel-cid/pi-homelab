# Portainer CE

## Descripción

Tras `02-estructura-compose.md` el repo del homelab tiene fijadas las reglas del juego: un `docker-compose.yml` por stack bajo `stacks/<nombre>/`, una red Docker compartida `homelab` (`172.30.10.0/24`) creada **fuera** de Compose, convenciones de nombres (`container_name`, `hostname`, kebab-case), `.env` global + `.env` por stack, y una plantilla canónica en `stacks/_template/`. Lo que falta antes de seguir poblando stacks reales (Watchtower en `04-watchtower.md`, y a partir de ahí toda la fase 3 en adelante) es decidir **qué interfaz de operación visual** se monta sobre Docker.

Este documento despliega **Portainer Community Edition** como **primer stack real** del homelab. Hace tres cosas:

1. **Justifica la elección**. Portainer CE vs Portainer Business Edition (BE) vs alternativas livianas (Dockge, Yacht), vs "no instalar nada y vivir solo de la CLI". Se argumenta por qué CE encaja en este homelab y cuáles son sus límites conscientes (5 nodos máximos, sin RBAC granular, sin webhooks de actualización avanzados — todos irrelevantes en single-host).
2. **Despliega el stack**. Bajo `stacks/portainer/` siguiendo la plantilla `_template/`: `container_name: portainer`, conectado a la red `homelab`, con bind mount al socket de Docker, datos persistentes en `/mnt/hd2t/apps/portainer/data/`, healthcheck, política de exposición conscientemente elegida.
3. **Fija la política de uso**. Esta es la decisión más importante y la más fácil de pifiar: **el repo de git es la fuente de verdad**, no Portainer. Portainer se usa para **observar, depurar y operar puntualmente** (logs, exec, restart, stats); los stacks **no** se editan en "Stacks → Add stack" desde la UI. El documento argumenta por qué y cómo se aplica.

Cuando este documento se haya aplicado, `docker ps` lista un contenedor `portainer` saludable, la UI responde, hay un usuario admin con contraseña fuerte y el endpoint `local` aparece con todos los stacks ya existentes (de momento, ninguno: este es el primero). A partir de ahí cualquier nuevo stack se ve y se opera desde Portainer **además de** desde la CLI, sin que la CLI deje nunca de ser el camino canónico.

> **Recordatorio de alcance**: el homelab es solo **LAN + Tailscale**. Portainer **no** se publica en internet. La exposición se cierra en este documento dentro de las tres opciones del patrón fijado en `02-estructura-compose.md` (solo red interna / `127.0.0.1` / IP LAN).

---

## Requisitos Previos

- `02-docker/01-instalacion-docker.md` aplicado:
  - Docker Engine ≥ 27 corriendo, Compose v2 disponible.
  - `data-root` en `/mnt/hd2t/docker`, `live-restore: true`.
  - Usuario `homelab` (UID 1000) en el grupo `docker`, `docker ps` funciona sin `sudo`.
- `02-docker/02-estructura-compose.md` aplicado:
  - Red Docker `homelab` creada con subnet `172.30.10.0/24` (`scripts/10-create-docker-network.sh`).
  - Layout `/home/homelab/homelab/{stacks/_template,scripts,secrets}` y `.env` global con `TZ`, `PUID`, `PGID`, `PGID_MEDIA`.
  - Plantilla `stacks/_template/docker-compose.yml` validada con `docker compose config`.
- Árbol de datos en `hd2t` (Fase 1, `04-estructura-directorios.md`):
  - `/mnt/hd2t/apps/portainer/` ya existe, propietario `homelab:homelab`, modo `0750`. Si no, crear:

    ```bash
    sudo install -d -o homelab -g homelab -m 0750 /mnt/hd2t/apps/portainer
    sudo install -d -o homelab -g homelab -m 0750 /mnt/hd2t/apps/portainer/data
    ```

- Conectividad a internet desde la Pi para descargar `portainer/portainer-ce`.
- Comprobación rápida antes de empezar:

  ```bash
  cd /home/homelab/homelab
  docker network inspect homelab --format '{{.Name}} {{.IPAM.Config}}'
  # homelab [{172.30.10.0/24 ...}]
  ls -ld /mnt/hd2t/apps/portainer
  # drwxr-x--- 2 homelab homelab ...  /mnt/hd2t/apps/portainer
  ls /var/run/docker.sock
  # srw-rw---- 1 root docker ...  /var/run/docker.sock
  ```

---

## Decisión: qué herramienta de gestión instalar

| Opción | Cómo se ve | Pros | Contras | Veredicto |
|---|---|---|---|---|
| **Solo CLI**, sin UI | `docker`, `docker compose`, `docker logs`, `docker stats` desde SSH. | Cero superficie de ataque añadida, cero RAM extra (~0 MB), cero secretos nuevos. | Para acciones rápidas (ver logs en vivo de un contenedor concreto, hacer `exec` a una shell, reiniciar un servicio sin recordar el path al compose) la CLI es lenta. La operación "ad-hoc" desde el móvil o desde otro equipo de la LAN no escala bien. | Descartado **como única opción** — sigue siendo el camino canónico para todo lo que es estado declarado. |
| **Portainer CE** | UI web, agente local conectado al socket de Docker, vista de contenedores/imágenes/redes/volúmenes, edición de stacks. | Maduro (≥ 9 años), comunidad amplia, multi-arch (imagen `arm64` oficial), ~70 MB RAM, healthcheck nativo. Permite operar el daemon **sin abrir una shell**: logs en streaming, `exec`, `inspect`, `top`, `stats`. Encaja con la convención "stack = directorio = fichero". | Requiere acceso al socket de Docker → equivalente a root del host (mismo razonamiento que el grupo `docker`). UI con sus propios usuarios/contraseñas → una credencial más que rotar. | **Aceptado**. |
| **Portainer Business Edition** (licencia gratuita ≤ 3 nodos) | Igual que CE más RBAC granular, edge agents, OAuth, registry mirroring, etc. | Funciones de empresa. | El homelab tiene **un** nodo, **un** operador y **un** modelo de amenaza simple. Nada de lo que añade BE aporta aquí; sí añade un EULA y un flujo de licencia que reabrir cada año. | Descartado. |
| **Dockge** | UI web minimalista, escribe `compose.yaml` reales en disco que el operador puede `git`-versionar. | Filosofía "compose-as-code" muy alineada con este homelab. ARM64 oficial. | Catálogo de funcionalidades más estrecho que Portainer (no logs avanzados, no terminal embebida, no inspect detallado de redes/volúmenes). Comunidad y madurez por debajo. | Descartado: para single-host Portainer da más con una huella similar; reabrible si Portainer molesta. |
| **Yacht** / **dockerui** / **lazydocker** | UIs alternativas (Yacht y dockerui web; lazydocker es TUI). | Ligereza. | Yacht y dockerui llevan tiempo con poca actividad; lazydocker es excelente pero para shell, no resuelve el "operar desde el móvil". | Descartado. |
| **Komodo** / **Coolify** | Plataformas más completas (CI/CD, despliegues git-driven, certificados, etc.). | Funcionalidad amplia. | Sobredimensionadas para este homelab; entran en territorio PaaS y pisan a Caddy + Watchtower que ya están planeados como piezas separadas y simples. | Descartado. |

Resultado: **Portainer Community Edition**, imagen oficial `portainer/portainer-ce`, desplegado como stack `stacks/portainer/` siguiendo la plantilla.

> **Imagen exacta**: se usa `portainer/portainer-ce:2.21.4-alpine` (tag inmovilizado en `mayor.menor.parche`, no `latest`). El stack se actualiza vía Watchtower con la regla **opt-in** que se establecerá en `04-watchtower.md` y que aquí solo se prepara con el label correspondiente.

---

## Decisión: cómo se expone Portainer

Las tres puertas del patrón fijado en `02-estructura-compose.md`:

| Patrón | Cómo se vería para Portainer | Discusión |
|---|---|---|
| **A. Solo red interna** (`networks: [homelab]`, sin `ports:`) | Caddy hace proxy en `https://portainer.home.lan/`. | Es lo correcto **a partir de Fase 3** (`docs/03-red-dns/04-caddy.md`). Pero ahora mismo Caddy todavía no existe: si se elige A, no hay forma de abrir la UI desde un navegador hasta entonces. |
| **B. Bind a `127.0.0.1`** (`ports: ["127.0.0.1:9000:9000"]`) | La UI solo escucha en la propia Pi. Acceso desde otro equipo solo por `ssh -L 9000:127.0.0.1:9000 homelab@<pi>`. | Seguro y mínimo, pero pesado para el día a día (cada vez que el operador quiere abrir Portainer desde otro equipo de la LAN, túnel SSH). |
| **C. Bind a IP LAN** (`ports: ["${LAN_IP}:9443:9443"]`) | UI accesible en `https://<ip-lan-de-la-pi>:9443/`. Portainer sirve **HTTPS con certificado self-signed**. | El navegador se queja una vez (cert TOFU), se acepta y queda recordado. La LAN ya es de confianza por la política del homelab. |

Se elige el **patrón C**, con el siguiente matiz importante:

- Se publica **solo el puerto HTTPS** (`9443`), **no** el puerto HTTP (`9000`). Portainer ofrece ambos: el HTTP queda **cerrado** explícitamente para evitar credenciales en claro por la LAN si alguien las teclea por error.
- Se hace **bind a la IP LAN concreta** (`${LAN_IP}:9443:9443`), **no** a `0.0.0.0:9443`. Si en algún momento aparece otra interfaz (Tailscale, una VPN distinta, un USB-Ethernet de pruebas), la regla **no se filtra automáticamente** a esas interfaces. Tailscale se documenta en su fase: si el operador quiere ver Portainer desde fuera de la LAN, lo hará por la tailnet (cuyo manejo a nivel de bind se cierra en Fase 3).
- En cuanto **Caddy** esté desplegado (Fase 3), este compose se **revisa** para retirar `ports:` y publicar Portainer solo a través de `https://portainer.home.lan/`. La transición se documenta allí; aquí se deja anotada como decisión consciente y temporal.

`LAN_IP` es la IP fija de la Pi en la LAN doméstica (definida ya, idealmente, vía reserva DHCP o IP estática en `01-sistema/`). Se añade al `.env` global del homelab si todavía no estaba:

```bash
# /home/homelab/homelab/.env (extracto)
LAN_IP=192.168.1.10                 # IP LAN reservada para la Pi 5
```

---

## Decisión: el repo es la fuente de verdad, Portainer es el panel de mando

Portainer permite **dos** flujos para gestionar stacks:

1. **"Stacks" desde la UI**: pegar/escribir un `docker-compose.yml` en el editor web. Portainer lo guarda en su volumen interno (`/data`) y lo aplica.
2. **Inspección y operación de stacks externos**: contenedores arrancados con `docker compose -f stacks/<svc>/docker-compose.yml up -d` aparecen automáticamente en Portainer (porque Portainer lee del propio daemon vía socket). El operador puede ver logs, abrir terminal, parar/arrancar, pero los **edita en el repo** y los **despliega con la CLI**.

Este homelab adopta **únicamente** el flujo (2). Razones:

| Motivo | Explicación |
|---|---|
| Versionado y diff | El `docker-compose.yml` vive en git (`stacks/<svc>/`). Cualquier cambio queda con autor, mensaje y trazabilidad. La UI de Portainer solo guardaría el último estado, sin historial. |
| Reflasheo | Tras un reflasheo de la microSD el operador clona el repo, crea la red, copia los `.env`, y `docker compose up -d`. Si los stacks vivieran "dentro de Portainer", habría que restaurar el volumen de Portainer **antes** de tener Portainer. Bootstrap circular. |
| Diffs de operación | "Cambia X parámetro" en un fichero de git ↔ pull request ↔ aplicación. "Cambia X parámetro" desde la UI ↔ se aplica y nadie se entera. |
| Multi-herramienta | Watchtower (Fase 2.4) y Borgmatic (Fase 7) leen labels y bind mounts del compose, no de Portainer. Que la fuente sea git unifica la metainformación. |

Esto **no** prohíbe usar la UI de Portainer. La UI sigue siendo válida (y muy útil) para:

- Ver logs en streaming con filtro y resaltado.
- Abrir una terminal en un contenedor (`/exec`).
- Reiniciar/parar un contenedor puntualmente para troubleshooting.
- Inspeccionar redes, volúmenes, imágenes.
- Stats de CPU/memoria por contenedor.

Lo que se prohíbe es **crear o editar stacks en la UI**. Si alguna vez se cae en la tentación, el primer reboot/reflasheo lo recuerda con dolor.

---

## Stack: `stacks/portainer/`

### `stacks/portainer/docker-compose.yml`

```yaml
# Portainer CE — panel web de gestión Docker.
# Convenciones: ver docs/02-docker/02-estructura-compose.md.

name: portainer

services:
  portainer:
    image: portainer/portainer-ce:2.21.4-alpine
    container_name: portainer
    hostname: portainer
    restart: unless-stopped

    # Argumentos del servidor:
    #   --http-disabled  cierra el puerto 9000 (HTTP). Solo HTTPS expuesto.
    #   --tlscert/--tlskey omitidos: Portainer genera un cert self-signed
    #                                en /data al primer arranque.
    command:
      - "--http-disabled"

    environment:
      TZ: ${TZ}

    networks:
      - homelab

    # El socket de Docker es la "API real" que opera Portainer.
    # :ro NO es suficiente para todas las operaciones (start/stop/exec),
    # pero limita escrituras directas; no se usa aquí porque rompería
    # la utilidad principal del panel. Asumido y documentado.
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /mnt/hd2t/apps/portainer/data:/data

    # Solo HTTPS, bind a la IP LAN concreta (no 0.0.0.0).
    # Cuando Caddy esté desplegado (Fase 3), retirar `ports:` y dejar
    # Portainer accesible solo a través de la red `homelab`.
    ports:
      - "${LAN_IP}:9443:9443"

    healthcheck:
      # Imagen alpine: incluye `wget`. Portainer responde 200 en /.
      # --no-check-certificate porque el cert es self-signed.
      test: ["CMD", "wget", "-qO-", "--no-check-certificate", "https://localhost:9443/"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s

    labels:
      homelab.role: "management"
      homelab.backup: "true"
      # Se deja preparado para Fase 2.4: Watchtower opt-in. Si en algún
      # momento se quiere actualizar Portainer manualmente y solo cuando
      # toque, basta con cambiar este label a "false".
      com.centurylinklabs.watchtower.enable: "true"

networks:
  homelab:
    external: true
```

### `stacks/portainer/.env.example`

Portainer no necesita variables sensibles propias (la primera contraseña se fija desde la UI al primer arranque). Aun así se versiona el `.env.example` para que el patrón "un `.env` por stack" sea uniforme:

```bash
# stacks/portainer/.env.example
# Portainer CE no requiere variables propias.
# Se mantiene este fichero como marcador de la convención.
# El stack consume LAN_IP, TZ y demás del .env global del repo.
```

> **Nota**: si en el futuro se quisiera **inicializar la contraseña admin sin pasar por la UI** (`--admin-password`), iría en un `.env` propio con `chmod 0600`. No se hace ahora porque la UI fuerza una contraseña fuerte de forma interactiva en el primer arranque y eso es preferible a tener un hash bcrypt en un fichero.

### Crear los directorios persistentes y desplegar

```bash
# Directorios de datos (idempotente)
sudo install -d -o homelab -g homelab -m 0750 /mnt/hd2t/apps/portainer
sudo install -d -o homelab -g homelab -m 0750 /mnt/hd2t/apps/portainer/data

# Verificar la red
docker network inspect homelab >/dev/null

# Validar el compose con interpolación de variables
cd /home/homelab/homelab
docker compose \
    -f stacks/portainer/docker-compose.yml \
    --env-file .env \
    config >/dev/null && echo "compose OK"

# Levantar
docker compose \
    -f stacks/portainer/docker-compose.yml \
    --env-file .env \
    up -d
```

Tras `up -d`:

```bash
docker ps --filter name=portainer
# CONTAINER ID   IMAGE                                 ...   STATUS                    PORTS                          NAMES
# ...            portainer/portainer-ce:2.21.4-alpine        Up 30 seconds (healthy)   192.168.1.10:9443->9443/tcp    portainer

docker compose -f stacks/portainer/docker-compose.yml logs --tail 30
# 2025/.../... starting Portainer ...
# 2025/.../... server listening on :9443 (TLS)
```

`STATUS` debe pasar a `(healthy)` en ~60 s. Si se queda `(starting)` más allá de los 30 s del `start_period`, revisar logs (probablemente no resuelve el bind del puerto: `LAN_IP` mal puesto).

---

## Configuración inicial

### 1) Primera conexión

Desde un equipo de la LAN abrir:

```
https://<LAN_IP>:9443/
```

El navegador advertirá del **certificado self-signed** (esperable: lo genera el propio Portainer en `/data/certs/` al primer arranque). Aceptar la excepción para esa IP. **No se importa el cert al sistema** ni se confía globalmente: en cuanto Caddy esté en marcha (Fase 3), Portainer pasará a estar tras `https://portainer.home.lan/` con cert de la CA interna y la excepción dejará de hacer falta.

### 2) Crear usuario admin

La primera pantalla pide:

| Campo | Valor recomendado |
|---|---|
| Username | `admin` (o un alias propio del operador; **no** reutilizar el del SSH para no acoplar credenciales). |
| Password | ≥ 16 caracteres, generada con `openssl rand -base64 24` en la propia Pi y guardada en el gestor de contraseñas del operador. **Cumple el políticamente correcto**: Portainer rechaza contraseñas débiles. |
| Notificaciones de uso | Desactivar (opcional). |

Esta pantalla solo aparece **una vez**. Si caduca por inactividad antes de rellenarla, Portainer lo bloquea por seguridad y hay que reiniciar el contenedor (`docker compose -f stacks/portainer/docker-compose.yml restart`).

### 3) Endpoint local

En "Get Started" o "Environments", elegir **Get Started → Local environment**. Portainer detecta el daemon local vía el socket bindeado y crea un endpoint `local`. No se añade ningún endpoint remoto.

| Endpoint | Tipo | Uso |
|---|---|---|
| `local` | Docker (socket) | Único endpoint del homelab. |

> No se habilita el agente Portainer (`portainer-agent`). El agente tiene sentido para nodos remotos donde no se quiere bindear el socket directamente; aquí Portainer corre **en** el host que gestiona, así que el socket bindeado es la vía natural y el agente solo añadiría una pieza más sin beneficio.

### 4) Ajustes de la UI

En "Settings → General":

| Ajuste | Valor | Por qué |
|---|---|---|
| Logo personalizado | (vacío) | No aporta. |
| Snapshot interval | `15m` | Cada 15 minutos Portainer cachea el estado del endpoint para que la UI cargue rápido. Bajarlo presiona el daemon innecesariamente. |
| Edge agent default poll frequency | (no aplica) | Solo single-host. |
| Helm repos | (vacío) | No hay Kubernetes. |
| **Allow self-signed certificates** | habilitado | Necesario si en algún momento se conecta un endpoint remoto vía TLS con CA interna. |
| **Disable telemetry** | habilitado | Telemetría externa: se desactiva por defecto en este homelab. |
| **App templates** | desactivar (vista) | El homelab no usa la galería de plantillas de Portainer; los stacks vienen del repo. Mantener la vista activa solo invita a saltarse la regla de oro. |

En "Settings → Authentication":

- Internal authentication (por defecto): **OK**. No se integra OAuth/LDAP en esta fase. Si en algún momento se incorpora Authelia, se reabre.
- **Sessions**: idle timeout `1h` (la UI cierra sesión tras una hora de inactividad). Razonable para una herramienta administrativa.

### 5) Política sobre "Stacks" en la UI

En la sección "Stacks" Portainer mostrará **uno** de momento (`portainer`, autodescubierto del propio daemon) y, conforme se añadan más, los irá listando.

Reglas internas:

| Acción en UI | Permitida | Comentario |
|---|---|---|
| Ver detalles, logs, terminal, stats | Sí | Es para lo que está. |
| Pulsar **"Stop"**, **"Start"**, **"Restart"**, **"Kill"** | Sí, con criterio | Operación puntual; no sustituye a `docker compose ... up -d` para cambios persistentes. |
| Pulsar **"Recreate"** con la opción "Re-pull image" | Sí | Equivale a `pull && up -d`. Útil si Watchtower está apagado para ese stack. |
| Pulsar **"Update the stack"** y editar YAML | **No** | Lo que se aplique aquí no estará en git → fuente de verdad rota. |
| **"Add stack"** | **No** | Crear stacks **siempre** desde el repo + CLI. |
| **"Add volume"**, **"Add network"** desde la UI | **No** | El estado declarativo (volúmenes, redes) vive en compose o en `scripts/`. |

Si por accidente se hace una de las acciones prohibidas: deshacer manualmente y dejarlo anotado en el commit que sincronice el estado.

---

## Almacenamiento

| Ruta | Soporte | Owner:Group | Modo | Contenido |
|---|---|---|---|---|
| `/home/homelab/homelab/stacks/portainer/docker-compose.yml` | microSD | `homelab:homelab` | `0640` | Stack versionado en git. |
| `/home/homelab/homelab/stacks/portainer/.env.example` | microSD | `homelab:homelab` | `0644` | Plantilla versionada. |
| `/mnt/hd2t/apps/portainer/data/` | hd2t | UID/GID interno (root del contenedor) | `0700` (lo fija el contenedor) | Base de datos interna de Portainer (BoltDB), certificados self-signed, sesiones, snapshots cacheados. |
| `/var/run/docker.sock` | runtime | `root:docker` | `0660` | Socket de la API. Bindeado de solo-pasarela; no es escritura del homelab. |

> **Owner del directorio `data/` después del primer arranque**: el contenedor de Portainer corre como `root` interno y reescribe permisos a `0700 root:root` dentro del bind mount. Esto **no** es problema para el homelab: el contenedor es propietario de su árbol de datos, y el host (`homelab` UID 1000) no necesita leer ese árbol manualmente. Si se quiere inspeccionar contenido (`/data/portainer.db`), se hace **vía contenedor** (`docker exec ... ls /data`) o **con sudo** desde el host. No se cambian permisos a mano: rompería el contenedor.

> **Volumen nominal vs bind mount**: `02-estructura-compose.md` fijó "todo bind mount, nada de volúmenes nominales". Portainer respeta la regla: `/mnt/hd2t/apps/portainer/data` es bind mount, no `portainer_data` nominal. La documentación oficial sugiere a menudo el volumen nominal; aquí se descarta para uniformidad y para que Borgmatic lo recoja sin reglas especiales.

---

## Backup

A nivel del repositorio del homelab:

| Artefacto | Estrategia |
|---|---|
| `stacks/portainer/docker-compose.yml`, `.env.example` | Versionados en git. Reproducibles tras un reflasheo. |
| Decisiones de configuración inicial (admin user, snapshot interval, etc.) | Documentadas en este fichero. Se reproducen en el primer arranque tras un reflasheo en cuestión de minutos. |

A nivel de datos (Borgmatic, Fase 7):

| Ruta | ¿Se respalda? | Por qué |
|---|---|---|
| `/mnt/hd2t/apps/portainer/data/` | **Sí**, etiquetado `homelab.backup=true`. | Contiene la BBDD de Portainer (BoltDB): usuarios, sesiones, ajustes, registros de actividad. Su pérdida obliga a re-crear el admin manualmente y reconfigurar la UI; no es catastrófico, pero se respalda porque pesa muy poco (decenas de MB). |
| Cert self-signed en `data/certs/` | **Sí**, indirectamente al respaldar `data/`. | Es regenerable, pero respaldarlo evita que cambie el fingerprint y todos los navegadores de la LAN tengan que volver a aceptar la excepción TOFU. |
| Snapshots cacheados de endpoints | Irrelevante. | Se regeneran solos en el siguiente snapshot interval. |

Procedimiento de restore:

1. Recrear el sistema base (Fase 1), reinstalar Docker (Fase 2.1), aplicar convenciones (Fase 2.2).
2. Restaurar `/mnt/hd2t/apps/portainer/data/` desde Borg.
3. `docker compose -f stacks/portainer/docker-compose.yml up -d`. Portainer arranca y reconoce su BBDD.
4. Iniciar sesión con el admin existente. No reaparece el wizard de primera vez.

Si lo que se quiere es **resetear** Portainer (olvidar admin password, p. ej.), basta con `docker compose down`, mover `/mnt/hd2t/apps/portainer/data/` a un lado y volver a `up -d`. La UI vuelve a pedir la creación del admin.

---

## Errores frecuentes y troubleshooting

| Síntoma | Causa probable | Resolución |
|---|---|---|
| `Error response from daemon: cannot mount volume over existing file` al arrancar | `/mnt/hd2t/apps/portainer/data` no existe o es un fichero. | `install -d` el directorio antes de `up -d`. |
| Healthcheck atascado en `(starting)` indefinidamente | `LAN_IP` apunta a una IP que no es de la Pi, o hay otro servicio en `:9443`. | `ss -tnlp \| grep 9443` y revisar `${LAN_IP}` en `.env`. |
| Navegador rechaza el cert sin botón "Aceptar el riesgo" | Algunos navegadores corporativos / móviles bloquean los self-signed sin opción de excepción para IP. | Acceder desde otro navegador hasta que Caddy entre en escena (Fase 3). Alternativamente, importar el cert una sola vez. |
| "Login token expired" al primer arranque | El wizard inicial caduca tras unos minutos por seguridad. | `docker compose -f stacks/portainer/docker-compose.yml restart` y completar el wizard inmediatamente. |
| La UI muestra "Connection lost" intermitente | Snapshot interval demasiado bajo o el daemon respondiendo lento durante un `pull` masivo. | Esperar; subir snapshot interval a `30m` si es persistente. |
| `permission denied` al hacer "Open Console" sobre un contenedor | El contenedor objetivo no tiene `bash` (es Alpine). | En la UI, cambiar el shell a `/bin/sh`. |
| Portainer aparece como `unhealthy` tras parar y arrancar el host | La red `homelab` no estaba creada en el reboot. | Re-ejecutar `bash scripts/10-create-docker-network.sh`. La red es persistente vía `data-root` en `hd2t`, así que esto **no** debería ocurrir; si se da, indica que `data-root` no se montó a tiempo. |
| Tras `docker compose down`, la UI ya no responde pero `/mnt/hd2t/apps/portainer/data/` sigue ahí | Comportamiento esperado. `down` para el contenedor; los datos persisten. | `up -d` lo devuelve al estado anterior. |
| Se cambió `${LAN_IP}` en `.env` y la UI sigue en la IP antigua | Compose detectó el cambio en `.env` pero no en `ports:` mapeados (no recreó). | `docker compose -f stacks/portainer/docker-compose.yml up -d --force-recreate`. |
| Login admin perdido | No hay reset password directo desde CLI en CE moderno. | Procedimiento oficial: parar el contenedor, arrancarlo con la imagen `portainer/helper-reset-password` apuntando al mismo volumen `data`, anota el admin temporal, vuelve a arrancar el stack. Documentado en upstream; aquí solo se referencia. |

---

## Decisiones que **no** se toman en este documento

- **Despliegue de Watchtower y política de actualizaciones**: va en `04-watchtower.md`. Aquí solo se deja Portainer **etiquetado** como opt-in (`com.centurylinklabs.watchtower.enable: "true"`).
- **Reverse proxy de Portainer detrás de Caddy** (`https://portainer.home.lan/`): va en `docs/03-red-dns/04-caddy.md`. Cuando exista, este compose se editará para retirar `ports:` y dejar Portainer accesible solo vía red `homelab`.
- **Autenticación externa (OAuth, LDAP, Authelia)**: solo si llega Authelia al homelab. Hasta entonces, autenticación interna de Portainer con contraseña fuerte basta.
- **Activación del Portainer Agent / Edge**: descartado mientras el homelab sea single-host. Si entra un segundo host (NAS, mini-PC), se reabre.
- **Plantillas / App Templates / Stacks-as-a-Service**: explícitamente desactivado por la regla de "el repo es la fuente de verdad".
- **Política de actualización del propio Portainer**: el label `com.centurylinklabs.watchtower.enable: "true"` lo deja preparado, pero **es Watchtower** quien decide la cadencia, en su propio documento. Si en algún momento se quiere fijar Portainer a una versión concreta y no auto-actualizarlo, se cambia el label a `"false"` aquí y se documenta el porqué.

---

## Verificación Final

Antes de pasar a `04-watchtower.md`:

| Comprobación | Comando | Resultado esperado |
|---|---|---|
| Stack desplegado | `docker compose -f stacks/portainer/docker-compose.yml ps` | `portainer  ...  Up (healthy)` |
| Imagen correcta y fija | `docker inspect portainer --format '{{.Config.Image}}'` | `portainer/portainer-ce:2.21.4-alpine` |
| Bind del socket | `docker inspect portainer --format '{{range .Mounts}}{{.Source}}->{{.Destination}}{{"\n"}}{{end}}'` | incluye `/var/run/docker.sock->/var/run/docker.sock` y `/mnt/hd2t/apps/portainer/data->/data` |
| Bind del puerto solo a IP LAN | `ss -tnlp \| grep 9443` | `LISTEN ... ${LAN_IP}:9443 ...` (no `0.0.0.0:9443`) |
| Puerto HTTP cerrado | `ss -tnlp \| grep 9000` | (sin coincidencias) |
| Conectado a la red `homelab` | `docker network inspect homelab --format '{{range .Containers}}{{.Name}} {{end}}'` | incluye `portainer` |
| Healthcheck verde | `docker inspect portainer --format '{{.State.Health.Status}}'` | `healthy` |
| UI responde HTTPS | `curl -k -fsS https://${LAN_IP}:9443/ -o /dev/null -w '%{http_code}\n'` | `200` o `307` (redirect a `/#!/init/admin` el primer arranque) |
| Wizard de admin completado | Login en `https://${LAN_IP}:9443/` | acceso correcto, no aparece la pantalla de "Create the initial administrator user" |
| Endpoint `local` operativo | UI → Environments | `local` listado, conectado, lista contenedores y redes (al menos `portainer` y `homelab`). |
| Persistencia tras reboot | `sudo reboot`; tras reconectar: `docker ps --filter name=portainer` | `Up ... (healthy)` sin acción manual |
| Sin restos en microSD | `du -sh /var/lib/docker/containers/$(docker inspect -f '{{.Id}}' portainer) 2>/dev/null` | reportado bajo `/mnt/hd2t/docker/...`, no en `/var/lib/docker/...` |
| Stack en git | `git status` | `stacks/portainer/docker-compose.yml` y `stacks/portainer/.env.example` aparecen tracked; ningún `.env` filtrado |

Cumplido el último punto, el panel de mando del homelab está vivo. La siguiente puerta es decidir **cómo se mantienen actualizadas las imágenes** sin convertir el host en un blanco móvil ni romper servicios silenciosamente: `04-watchtower.md`.

---

## Referencias

- [Documento anterior: `docs/02-docker/02-estructura-compose.md`](./02-estructura-compose.md)
- [Documento siguiente: `docs/02-docker/04-watchtower.md`](./04-watchtower.md)
- [Documento relacionado: `docs/02-docker/01-instalacion-docker.md`](./01-instalacion-docker.md)
- [Portainer — Install Portainer CE with Docker on Linux](https://docs.portainer.io/start/install-ce/server/docker/linux)
- [Portainer — Reset admin password](https://docs.portainer.io/advanced/reset-admin)
- [Portainer — CE vs BE feature comparison](https://www.portainer.io/take-the-tour-business-edition)
- [Portainer — Server image (`portainer/portainer-ce`) on Docker Hub](https://hub.docker.com/r/portainer/portainer-ce)
- [Portainer — Server CLI flags](https://docs.portainer.io/advanced/cli)
- [Docker — Bind mounts (rationale)](https://docs.docker.com/storage/bind-mounts/)
- [Docker — Security best practices: Docker socket](https://docs.docker.com/engine/security/#docker-daemon-attack-surface)
