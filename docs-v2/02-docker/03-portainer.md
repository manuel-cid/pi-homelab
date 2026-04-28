# Portainer CE

## Descripción

**Despliegue de Portainer CE como panel web de inspección y operación** sobre el endpoint Docker local de la Raspberry Pi. Portainer no se usa como **fuente de la verdad** del homelab (esa sigue siendo el repo de stacks en `~/homelab/stacks/` versionado en git, según [`02-estructura-compose.md`](./02-estructura-compose.md) §2.2): se despliega como **herramienta complementaria** para visualizar contenedores, redes y volúmenes, leer logs sin SSH, ejecutar `exec` puntuales en un contenedor desde el navegador y dar visibilidad rápida del estado del runtime. Cualquier *stack* nuevo se sigue añadiendo como YAML versionado y se aplica con `docker compose up -d`; Portainer puede importarlo en modo "limited control" para que aparezca en el panel, pero no se pierde el versionado.

Este documento cubre, en este orden:

1. **Modo de uso adoptado**: Portainer como inspector y panel, no como editor primario de stacks.
2. **Imagen, versión y arquitectura**: por qué `portainer/portainer-ce` con tag fijo y por qué CE en lugar de Business.
3. **Acceso al socket Docker**: bind mount directo de `/var/run/docker.sock` con discusión de la alternativa con `docker-socket-proxy` y por qué no se adopta por defecto en este homelab.
4. **Estrategia de exposición de la UI** mientras [`../03-red/04-caddy.md`](../03-red/04-caddy.md) (Caddy) **aún no existe**: bind exclusivo a `127.0.0.1:9443` + túnel SSH desde el operador. Cuando Caddy esté en marcha (Fase 3), `ports:` desaparece y la UI se sirve por `https://portainer.${LAN_DOMAIN}` detrás de Caddy y, opcionalmente, Authelia.
5. **Despliegue del stack `infra`** (Portainer en este doc; Watchtower entra en [`04-watchtower.md`](./04-watchtower.md)).
6. **Inicialización del admin** y **conexión al endpoint local**.
7. **Convivencia con `docker compose`**: stacks "limited control" vs nativos.
8. **Verificación**, **backup** y **solución de problemas**.

> **Alcance**: aquí solo se despliega Portainer y se hace su primer login. La integración con Caddy + Authelia se cierra en [`../03-red/04-caddy.md`](../03-red/04-caddy.md) y [`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md), donde se elimina la exposición de `127.0.0.1:9443` y se añade el `forward_auth`.

> **Recordatorio**: el homelab opera en **LAN + Tailscale**. Portainer **no se publica a `0.0.0.0`**. Hasta que exista Caddy, se accede vía túnel SSH (o, si se prefiere, vía Tailscale al `127.0.0.1` del host pasando por la dirección del nodo `tailscale serve`). No se abre 9000/9443 en el firewall.

---

## Requisitos Previos

- Docker Engine y Docker Compose v2 operativos según [`01-instalacion-docker.md`](./01-instalacion-docker.md), con `daemon.json` aplicado y `docker run --rm hello-world` exitoso.
- Convenciones y red Docker compartida `homelab` creadas según [`02-estructura-compose.md`](./02-estructura-compose.md): `docker network ls` debe listar `homelab` con subred `172.20.0.0/24` y bridge `br-homelab`.
- Repo de stacks inicializado en `~/homelab/stacks/` y `.gitignore` excluyendo `.env*`, `*.key`, `*.pem`, `*.crt`.
- Estructura de directorios de la [Fase 1](../01-sistema/04-estructura-directorios.md) aplicada. La carpeta de datos del stack se crea en §1.3 más abajo (sustituye al `/mnt/hd2t/services/portainer/` que la receta de Fase 1 dejó preparado: pasamos a la convención **por stack** del doc anterior, `/mnt/hd2t/services/infra/portainer/`).
- Cliente SSH en la máquina del operador (laptop/escritorio) para tunelizar `9443` durante el primer login. La sesión SSH a la Pi se asume autenticada por clave (sin password) según [`../01-sistema/03-seguridad-base.md`](../01-sistema/03-seguridad-base.md).

### Decisiones de diseño asumidas

| Decisión | Valor por defecto | Justificación |
|---|---|---|
| Edición | **Portainer CE** (`portainer/portainer-ce`) | CE es libre y cubre todo lo que un homelab necesita: gestión de contenedores, stacks, volúmenes, redes, registries, plantillas, logs y `exec`. Las funciones que añade Business Edition (RBAC granular, soporte, "edge groups" multi-host avanzado) no aportan a un único host. |
| Tag de imagen | **`portainer/portainer-ce:2.21.5`** (pinned), `arm64` | Pinear la versión hace los upgrades **deliberados**; `latest` rompería rollback y quedaría en manos de Watchtower cualquier salto mayor. Las imágenes oficiales de Portainer publican manifest multi-arch que incluye `linux/arm64`, así que no hay que tocar nada en la Pi 5. |
| Cómo accede al socket Docker | **Bind mount directo de `/var/run/docker.sock`** (lectura/escritura) | Portainer necesita escribir (start/stop, recreate, exec) para ser útil. El bind directo es la receta oficial y la que está mejor probada. El coste es claro y se asume: quien tenga admin de Portainer **es root del host**. Por eso (a) la UI no se expone a la LAN, (b) Authelia añade 2FA en Fase 4, (c) la cuenta admin tiene contraseña fuerte y única generada con `openssl rand -base64 32`. |
| Alternativa con `docker-socket-proxy` | **No por defecto**; documentada como variante | `tecnativa/docker-socket-proxy` u otro proxy permite conceder solo verbos concretos (`CONTAINERS=1`, `IMAGES=1`, `NETWORKS=1`...). Reduce superficie de ataque pero añade un contenedor adicional, dependencia explícita y debug más complicado. Tras evaluar coste/beneficio para un único operador con 2FA y sin acceso desde internet, **no se adopta** por defecto; se deja la receta como excepción documentada por si se reendurece la postura. |
| Volumen de datos | Bind mount `/mnt/hd2t/services/infra/portainer/data` → `/data` | Coherente con la convención del homelab: bind mounts en `hd2t`, ruta predecible, backup directo con Borg ([`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md)). |
| Exposición de la UI | **`127.0.0.1:9443:9443/tcp`** mientras Caddy no exista; **sin `ports:`** una vez Caddy esté delante | Con `127.0.0.1:9443` la UI **no** es alcanzable desde otra máquina de la LAN: solo desde la propia Pi. El operador llega vía `ssh -L 9443:127.0.0.1:9443 ...`. Cuando se despliegue Caddy se elimina `ports:` y se enruta `https://portainer.${LAN_DOMAIN}` por la red `homelab`. |
| Puerto 8000 (Edge agent) | **Sin `ports:`** y sin variable `EDGE` | Solo aplica si la Pi gestionara nodos remotos vía Edge. No es el caso: el endpoint es `local` (el propio Docker socket). |
| Puerto 9000 (HTTP) | **Sin publicar** | Portainer ofrece HTTP en 9000 además de HTTPS en 9443 con su CA autogenerada. Forzar 9443 evita ofrecer una variante sin TLS. La advertencia del navegador por la CA "self-signed" del propio Portainer se mitiga al pasar por Caddy, que ya termina TLS con la CA interna del homelab (Fase 3). |
| Cuenta admin inicial | **`--admin-password-file /run/secrets/portainer_admin`** dentro del contenedor | Permite bootstrapping no interactivo y reproducible. Sin esto, Portainer abre la UI en modo "configurar admin"; si nadie entra antes de **5 minutos** desde el primer arranque, Portainer **se bloquea por seguridad** y exige reinicio. El bootstrap por fichero elimina ese tiempo crítico y se ata al `.env` real en `hd2t`. |
| Watchtower auto-update | **Excluido** (`com.centurylinklabs.watchtower.enable=false`) | Un update mayor de Portainer puede romper la UI o forzar migraciones de DB internas. La actualización se hace **manualmente** y solo después de releer el changelog. La etiqueta es coherente con [`04-watchtower.md`](./04-watchtower.md). |
| Healthcheck | `wget --no-check-certificate -q -O- https://127.0.0.1:9443` | Portainer no expone un endpoint HTTP simple en 9443 hasta que está listo; un `200` o `302` desde `localhost` confirma que el servidor TLS está sirviendo. Healthcheck propio de la imagen no es estándar suficiente. |
| Red | Solo `homelab` | Portainer **no** tiene servicios internos que aislar (no usa BD externa); con una sola red basta y está alcanzable por Caddy desde el primer momento. |
| Stacks importados desde Portainer | **"Limited control"** | La UI permite, opcionalmente, "tomar control" de stacks creados con `docker compose` en el host. Se usa el modo limited para **conservar el `docker-compose.yml` en git** como fuente única; Portainer solo lee y muestra. |

---

## 1. Preparar el stack `infra`

### 1.1. Layout en disco

Siguiendo la convención de [`02-estructura-compose.md`](./02-estructura-compose.md) §2.1 y §2.4, el stack `infra` agrupa Portainer (este doc) y Watchtower ([`04-watchtower.md`](./04-watchtower.md)).

```
~/homelab/stacks/infra/                        # microSD, en git
├── docker-compose.yml                         # Portainer ahora; Watchtower en el siguiente doc
└── .env.example

/mnt/hd2t/services/infra/                      # HDD, fuera de git
├── .env                                       # secretos (chmod 600)
└── portainer/
    └── data/                                  # /data dentro del contenedor
```

### 1.2. Crear el directorio del stack en el repo

```bash
# Como usuario homelab.
mkdir -p ~/homelab/stacks/infra
touch    ~/homelab/stacks/infra/.env.example
```

### 1.3. Crear el árbol de datos en `hd2t`

```bash
sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/services/infra
sudo install -m 600 -o homelab -g homelab /dev/null /mnt/hd2t/services/infra/.env

sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/services/infra/portainer
sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/services/infra/portainer/data
```

> Si en la Fase 1 se ejecutó la receta de [`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) §4.1 y existe un `/mnt/hd2t/services/portainer/` plano, se puede borrar **vacío** (no contiene datos todavía): `sudo rmdir /mnt/hd2t/services/portainer 2>/dev/null || true`. La convención por stack del doc anterior sustituye a la convención plana de Fase 1 para cualquier servicio que pertenezca a un stack con más de un servicio.

### 1.4. Generar la contraseña del admin

El bootstrap de Portainer requiere el **bcrypt hash** de la contraseña, no la contraseña en claro.

```bash
# Generar la contraseña en claro (guardarla en Vaultwarden cuando esté en marcha).
PORTAINER_ADMIN_PASS=$(openssl rand -base64 32)
echo "Apunta esta contraseña en un sitio seguro:"
echo "$PORTAINER_ADMIN_PASS"

# Calcular el bcrypt hash usando la misma imagen oficial (sin instalar htpasswd local).
docker run --rm httpd:2.4-alpine \
  htpasswd -nbB -C 12 admin "$PORTAINER_ADMIN_PASS" \
  | cut -d ':' -f 2 \
  | tr -d '\n' \
  > /tmp/portainer_admin.hash
chmod 600 /tmp/portainer_admin.hash
echo
echo "Hash bcrypt generado en /tmp/portainer_admin.hash"
```

Mover el hash al `.env` del stack (`/mnt/hd2t/services/infra/.env`):

```bash
HASH=$(cat /tmp/portainer_admin.hash)
{
  echo "# Portainer admin (bcrypt hash de la contraseña, --admin-password)."
  echo "PORTAINER_ADMIN_PASSWORD_HASH=${HASH}"
} >> /mnt/hd2t/services/infra/.env

shred -u /tmp/portainer_admin.hash
unset PORTAINER_ADMIN_PASS HASH
```

> **Coste de regenerarla**: si se pierde la contraseña en claro **antes** del primer login, basta repetir esta receta y reiniciar Portainer; tomará el nuevo hash en el siguiente arranque. Si se pierde **después** del primer login, hay que parar Portainer, borrar `/mnt/hd2t/services/infra/portainer/data/portainer.db` y volver a bootstrapping. Por eso conviene guardar la pass en claro en una bóveda desde el primer momento.

> El flag `-C 12` fija el coste bcrypt en 12 (estándar 2024-2026 para servicios web internos): equilibrio entre fuerza y latencia de login en una Pi 5 (~120 ms).

### 1.5. Plantilla `.env.example` en el repo de stacks

```bash
cat > ~/homelab/stacks/infra/.env.example <<'EOF'
# ===== Stack infra (Portainer + Watchtower) =====

# UID/GID del operador (Portainer corre como root porque necesita docker.sock,
# pero estas variables se reservan para servicios futuros del stack).
PUID=1000
PGID=1000

# Zona horaria.
TZ=Europe/Madrid

# Dominios (resueltos por Pi-hole en Fase 3).
LAN_DOMAIN=lan
TS_DOMAIN=tailnet.ts.net

# ----- Portainer -----
# Hash bcrypt de la contraseña del admin. Generar con:
#   docker run --rm httpd:2.4-alpine htpasswd -nbB -C 12 admin "<password>" | cut -d ':' -f 2
PORTAINER_ADMIN_PASSWORD_HASH=

# ----- Watchtower (se rellena en 04-watchtower.md) -----
# WATCHTOWER_NOTIFICATION_URL=
EOF

# Confirmar que NO se acaba de crear un .env junto al docker-compose.yml.
ls -la ~/homelab/stacks/infra/
# Esperado: solo docker-compose.yml (en el siguiente paso) y .env.example
```

---

## 2. Docker Compose

```yaml
# ~/homelab/stacks/infra/docker-compose.yml
name: infra

services:
  portainer:
    image: portainer/portainer-ce:2.21.5
    container_name: portainer
    hostname: portainer
    restart: unless-stopped
    command:
      - --admin-password=${PORTAINER_ADMIN_PASSWORD_HASH}
      - --hide-label=com.centurylinklabs.watchtower.enable
    env_file:
      - /mnt/hd2t/services/infra/.env
    environment:
      TZ: ${TZ}
    volumes:
      - type: bind
        source: /var/run/docker.sock
        target: /var/run/docker.sock
        read_only: false
      - type: bind
        source: /mnt/hd2t/services/infra/portainer/data
        target: /data
        bind:
          create_host_path: false
    ports:
      # Solo localhost del host; el operador llega por túnel SSH hasta que
      # Caddy esté en marcha (Fase 3). Eliminar este bloque tras desplegar Caddy.
      - "127.0.0.1:9443:9443/tcp"
    networks:
      - homelab
    security_opt:
      - no-new-privileges:true
    healthcheck:
      test: ["CMD", "wget", "--no-check-certificate", "-q", "--spider", "https://127.0.0.1:9443"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s
    labels:
      com.centurylinklabs.watchtower.enable: "false"
      homepage.group: "Infraestructura"
      homepage.name: "Portainer"
      homepage.icon: "portainer.png"
      homepage.href: "https://portainer.${LAN_DOMAIN}"
      homepage.description: "Gestión de contenedores Docker"

networks:
  homelab:
    external: true
```

### 2.1. Por qué cada bloque diverge de la plantilla base

La plantilla de [`02-estructura-compose.md`](./02-estructura-compose.md) §6 fija los defaults; aquí se justifica cada **excepción**:

| Bloque | Diferencia respecto a la plantilla | Razón |
|---|---|---|
| `user:` ausente | La plantilla pone `user: "${PUID}:${PGID}"` | La imagen de Portainer corre como `root` por dentro y necesita acceder al socket Docker (que es `root:docker` en el host). Forzar UID `1000` haría que Portainer no pudiera escribir en el socket sin añadir `homelab` al grupo `docker` **dentro del contenedor**, lo que complica el modelo. Se acepta `root` dentro del contenedor; el bind mount de `/data` mantiene los ficheros con propiedad `root:root` y solo Portainer los toca. |
| `cap_drop: ALL` ausente | La plantilla lo recomienda | El acceso al socket Docker ya hace al contenedor equivalente a `root` del host: `cap_drop` es cosmético en este caso. Si se adopta el `docker-socket-proxy` (variante en §3) **sí** se puede aplicar `cap_drop: ALL`. |
| `read_only: true` no aplicado | La plantilla lo permite cuando es viable | Portainer escribe en `/data`, en `/tmp` y, durante actualizaciones de la UI estática, en otros directorios; activarlo requiere mapear varios `tmpfs` y no compensa para una imagen mantenida. |
| `command:` con `--admin-password=...` y `--hide-label` | La plantilla no usa `command:` | Bootstrap no interactivo del admin (§1.4) y oculta la etiqueta de Watchtower de la UI (limpia visualmente: la etiqueta es metadata, no estado). |
| `ports:` con bind a `127.0.0.1` | La plantilla evita `ports:` salvo en Caddy/Pi-hole | Excepción **transitoria** hasta que Caddy esté delante; en ese momento se elimina (ver §5). |
| `env_file` con ruta absoluta | Igual que la plantilla | Sin cambios. Mantiene los secretos fuera del repo. |
| `labels` de Homepage | Igual que la plantilla | Pre-rellena los metadatos para que [`../12-dashboards/01-homepage.md`](../12-dashboards/01-homepage.md) pueda autodescubrirlo cuando llegue. |
| `labels` de Watchtower con `false` | La plantilla pone `true` | Excluye Portainer de updates automáticos (justificación en la tabla de decisiones). |

### 2.2. Aplicar el stack

```bash
cd ~/homelab/stacks/infra

# Validar el YAML con las variables de .env reales.
docker compose --env-file /mnt/hd2t/services/infra/.env config >/dev/null \
  && echo "Compose OK"

# Levantar.
docker compose --env-file /mnt/hd2t/services/infra/.env up -d

# Estado.
docker compose ps
docker logs --tail=50 portainer
```

> Nota sobre `--env-file` en `up`: la plantilla del doc anterior lo evita en `up` porque solo el `env_file:` interno de cada servicio basta. **Aquí sí lo pasamos** porque el `command:` interpola `${PORTAINER_ADMIN_PASSWORD_HASH}` en el YAML, lo que ocurre en el momento de **parseo** y necesita la variable cargada en el shell de Compose. Esto es coherente con la nota de [`02-estructura-compose.md`](./02-estructura-compose.md) §6.3.

Salida esperada de `docker compose ps`:

```
NAME        IMAGE                              STATUS              PORTS
portainer   portainer/portainer-ce:2.21.5      Up X seconds (healthy)   127.0.0.1:9443->9443/tcp, 8000/tcp, 9000/tcp
```

`8000/tcp` y `9000/tcp` aparecen como expuestos en el contenedor (la imagen los declara) pero **no están publicados**: solo `9443` está mapeado al host, y solo a `127.0.0.1`.

### 2.3. (Variante endurecida) `docker-socket-proxy`

Si en algún momento se decide reducir la superficie de ataque del bind directo, se sustituye el bind del socket por un proxy. **No** se aplica por defecto. La forma se documenta aquí para no perder la receta:

```yaml
# Variante: añadir un servicio docker-socket-proxy y apuntar Portainer a él.
services:
  socket-proxy:
    image: tecnativa/docker-socket-proxy:0.2
    container_name: socket-proxy
    restart: unless-stopped
    environment:
      CONTAINERS: 1
      IMAGES: 1
      VOLUMES: 1
      NETWORKS: 1
      SERVICES: 1
      TASKS: 1
      INFO: 1
      VERSION: 1
      EXEC: 1          # imprescindible para "Console" en Portainer
      POST: 1          # permitir verbos modificadores (start/stop/recreate)
      ALLOW_RESTARTS: 1
    volumes:
      - type: bind
        source: /var/run/docker.sock
        target: /var/run/docker.sock
        read_only: true
    networks:
      - infra_internal
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    cap_add:
      - DAC_READ_SEARCH

  portainer:
    # ... resto igual, pero:
    volumes:
      - type: bind
        source: /mnt/hd2t/services/infra/portainer/data
        target: /data
        bind:
          create_host_path: false
    environment:
      TZ: ${TZ}
      DOCKER_HOST: tcp://socket-proxy:2375
    networks:
      - infra_internal
      - homelab

networks:
  homelab:
    external: true
  infra_internal:
    driver: bridge
```

Cuesta un contenedor adicional (`socket-proxy`) y debug más sutil cuando algo no funciona en Portainer (la causa puede ser una variable del proxy desactivada). **No se considera necesario** mientras la superficie sea: una Pi sin internet, Authelia/2FA delante, operador único con sudo.

---

## 3. Primer login

Mientras Caddy no exista, no hay manera de llegar a `https://portainer.lan` por DNS. El acceso se hace por **túnel SSH** desde la máquina del operador.

### 3.1. Levantar el túnel SSH

Desde la máquina del operador (laptop/escritorio), abrir **otra** sesión SSH con port forwarding:

```bash
ssh -N -L 9443:127.0.0.1:9443 homelab@<ip-de-la-pi-en-lan>
```

- `-N` no abre shell; solo el túnel.
- `-L 9443:127.0.0.1:9443` ata el `9443` local al `127.0.0.1:9443` del host remoto, que es donde Portainer escucha.

### 3.2. Login en el navegador

Abrir <https://localhost:9443> en el navegador del operador.

- El navegador advierte de certificado no fiable: **es esperado**. Portainer ha autogenerado un cert TLS válido solo internamente. Aceptar la excepción **solo en este host** (`localhost`).
- Login: usuario `admin`, contraseña la generada en §1.4 (la **versión en claro**, no el hash).
- Saltará el wizard inicial: **omitir** crear endpoints adicionales, dejar el endpoint local.

### 3.3. Conexión al endpoint local (Docker socket)

Portainer detecta automáticamente `/var/run/docker.sock` cuando el contenedor lo tiene montado. Comprobar:

- **Environments → local**: estado **`up`**, snapshot reciente, contadores de contenedores y volúmenes coherentes con `docker ps -a`.
- **Stacks**: vacío de momento (los stacks creados con `docker compose` aparecen como **"limited control"**: visibles para inspección, pero no editables desde la UI por diseño).
- **Containers**: aparece **`portainer`** y los del whoami-test si quedaron (no deberían tras §7.3 del doc anterior).

### 3.4. Endurecer la sesión inicial

Antes de bajar el túnel y reanudar trabajo:

1. **Settings → Authentication**: activar **OAuth/forward auth** queda para la Fase 4 (Authelia). De momento, dejar autenticación interna.
2. **Settings → Application settings**: bajar `Snapshot interval` a 5 min (default suficiente para un homelab; reduce I/O sobre el socket).
3. **Settings → Edge Compute**: dejar **deshabilitado**. No se usa Edge.
4. **Account → Change password**: opcional si se quiere reemplazar el password de `openssl rand` por algo memorable; mantener fuerte.

---

## 4. Convivencia con `docker compose` en el host

La fuente única de la verdad es `~/homelab/stacks/<stack>/docker-compose.yml` versionado en git. Portainer **no** edita esos ficheros: cualquier cambio sigue el flujo `editor → git commit → docker compose up -d`.

### 4.1. Cómo aparecen los stacks lanzados desde CLI

Stacks creados con `docker compose` fuera de la UI son visibles en Portainer como **"Limited control"**. El operador puede:

- Inspeccionar contenedores, redes y volúmenes.
- Leer logs (replica `docker logs`).
- `Console`: abrir un `exec` (replica `docker exec -it ... sh`) sobre cualquier contenedor.
- Iniciar / parar / reiniciar / recrear contenedores individuales.

Lo que **no** debe hacerse desde la UI:

- Editar el YAML del stack desde Portainer (rompería la fuente git).
- Crear nuevos stacks con su editor "limitado" (lo correcto es `~/homelab/stacks/<nuevo>/docker-compose.yml` + git).
- Subir `.env` por la UI (los secretos viven en `hd2t`, no en la BD de Portainer).

### 4.2. Si en algún momento se necesita editar desde Portainer

Caso excepcional (p. ej. una prueba puntual). El flujo correcto es:

1. Hacer la edición en `~/homelab/stacks/<stack>/docker-compose.yml`.
2. `git diff` para revisar.
3. `docker compose --env-file /mnt/hd2t/services/<stack>/.env up -d`.
4. `git commit -am "..."`.

Portainer detecta el nuevo estado tras el siguiente snapshot y refleja los cambios.

### 4.3. Templates

Portainer trae plantillas predefinidas que **no se usan** en este homelab: cada servicio tiene su propio doc en `docs/` y su `docker-compose.yml` versionado. El menú **App Templates** queda como referencia de inspiración, no como flujo de despliegue.

---

## 5. Migración a Caddy (Fase 3)

Cuando se complete [`../03-red/04-caddy.md`](../03-red/04-caddy.md), Portainer pasa a estar **detrás** de Caddy. Cambios:

1. Editar `~/homelab/stacks/infra/docker-compose.yml`:
   - Eliminar el bloque `ports:` por completo.
2. Re-aplicar:
   ```bash
   cd ~/homelab/stacks/infra
   docker compose --env-file /mnt/hd2t/services/infra/.env up -d --force-recreate portainer
   ```
3. En el `Caddyfile` añadir:
   ```caddy
   portainer.{$LAN_DOMAIN} {
       tls /data/caddy-ca/portainer.crt /data/caddy-ca/portainer.key
       reverse_proxy https://portainer:9443 {
           transport http {
               tls
               tls_insecure_skip_verify
           }
       }
   }
   ```
   `tls_insecure_skip_verify` es **necesario aquí** porque Portainer sigue presentando su cert autogenerado dentro de la red `homelab`; el cert "público" lo emite Caddy con la CA interna.
4. (Fase 4) Añadir `forward_auth` con Authelia para 2FA: ver [`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md).

A partir de ese momento, el túnel SSH ya no se necesita en operación normal y el bind a `127.0.0.1` queda como recurso solo de troubleshooting.

---

## 6. Almacenamiento

| Ruta dentro del contenedor | Origen en el host | Contenido | Backup |
|---|---|---|---|
| `/data` | `/mnt/hd2t/services/infra/portainer/data/` (bind) | Base de datos `portainer.db` (BoltDB), endpoints, ajustes, plantillas guardadas, sesiones | Sí (Borg) |
| `/var/run/docker.sock` | `/var/run/docker.sock` (bind) | Socket Unix del demonio Docker | No (es runtime) |
| (memoria efímera del contenedor) | `tmpfs` por defecto | Logs en stdout (rotados por `daemon.json`) | No |

`portainer.db` pesa típicamente 1-3 MB en un homelab pequeño y crece poco: contiene la configuración de Portainer, no los datos de los contenedores gestionados. Es **el único** fichero crítico a respaldar de este servicio.

---

## 7. Backup

Estrategia (la implementación concreta vive en [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) y [`../07-backups/03-backup-docker-volumes.md`](../07-backups/03-backup-docker-volumes.md)):

1. **`/mnt/hd2t/services/infra/portainer/data/`** entra en el set "services" de Borg sin tratamiento especial: `portainer.db` es un fichero BoltDB que tolera bien la copia en caliente para un homelab; un riesgo residual de inconsistencia se mitiga porque el daño máximo de una BD corrupta es **rehacer la configuración de Portainer**, no perder datos de servicios.
2. **`/mnt/hd2t/services/infra/.env`** entra en el set "secrets" de Borg, con cifrado por passphrase distinto del set general.
3. **`~/homelab/stacks/infra/docker-compose.yml`** y **`.env.example`** ya están respaldados como parte del repo git (se replican al remote y entran en el set "configs" de Borg como red de seguridad).
4. **No es necesario** parar Portainer para hacer backup: BoltDB hace fsync regularmente.

### 7.1. Restaurar tras pérdida total

```bash
# 1. Reinstalar OS, Docker y red 'homelab' (Fases 0-2.2).
# 2. Restaurar el repo de stacks desde git remote o desde Borg.
git clone <remote> ~/homelab

# 3. Restaurar /mnt/hd2t/services/infra/ desde Borg (incluye data/ y .env).
borg extract <repo>::<archivo> mnt/hd2t/services/infra

# 4. Levantar el stack.
cd ~/homelab/stacks/infra
docker compose --env-file /mnt/hd2t/services/infra/.env up -d
```

Login con la contraseña original (la del `.env` restaurado).

### 7.2. Restaurar solo Portainer (corrupción de la BD)

```bash
docker compose --env-file /mnt/hd2t/services/infra/.env stop portainer
sudo mv /mnt/hd2t/services/infra/portainer/data /mnt/hd2t/services/infra/portainer/data.broken-$(date +%F)
sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/services/infra/portainer/data
borg extract <repo>::<archivo> mnt/hd2t/services/infra/portainer/data
docker compose --env-file /mnt/hd2t/services/infra/.env up -d portainer
```

---

## 8. Verificación

### 8.1. Lista de Verificación

Antes de pasar a [`04-watchtower.md`](./04-watchtower.md):

- [ ] `docker compose ps` (en `~/homelab/stacks/infra`) muestra `portainer` con estado `Up X (healthy)`.
- [ ] `docker inspect portainer --format '{{.State.Health.Status}}'` devuelve `healthy`.
- [ ] `docker port portainer` muestra **solo** `9443/tcp -> 127.0.0.1:9443`.
- [ ] `ss -ltn 'sport = :9443'` en el host muestra `LISTEN 0 ... 127.0.0.1:9443` (no `0.0.0.0:9443`).
- [ ] Desde otra máquina de la LAN, `curl -k https://<ip-pi>:9443` falla con `Connection refused` (es lo deseado: Portainer no está expuesto a la LAN todavía).
- [ ] Tras `ssh -L 9443:127.0.0.1:9443 ...`, `https://localhost:9443` carga la UI y permite login con `admin` + la pass de §1.4.
- [ ] En la UI, **Environments → local** está `up` y muestra contenedores activos.
- [ ] `docker network inspect homelab --format '{{range .Containers}}{{.Name}} {{end}}'` lista `portainer` entre los conectados.
- [ ] `id -u` dentro del contenedor (`docker exec portainer id -u`) devuelve `0` (es esperado: Portainer corre como root).
- [ ] `cat /mnt/hd2t/services/infra/portainer/data/portainer.db` existe y es propiedad de `root:root` (escrito por el contenedor).
- [ ] `docker logs --tail=200 portainer` no muestra errores de "permission denied" sobre `/var/run/docker.sock`.
- [ ] El `.env.example` versionado **no contiene** ningún hash bcrypt real ni contraseñas en claro; solo claves vacías.
- [ ] `git -C ~/homelab status` no lista ningún `.env` ni ningún hash como untracked.
- [ ] `docker inspect portainer --format '{{json .Config.Labels}}'` muestra `com.centurylinklabs.watchtower.enable: "false"`.

### 8.2. Test de funcionalidad básica

Desde la UI con sesión iniciada:

1. **Containers → portainer → Logs**: stream en vivo de `docker logs` sin error.
2. **Containers → portainer → Console** (`/bin/sh`): se abre un shell interactivo dentro del contenedor.
3. **Networks**: aparece `homelab` con la subred `172.20.0.0/24` y `portainer` listado entre los miembros.
4. **Volumes**: aparecen los bind mounts del contenedor.
5. **Stacks**: aparece `infra` (limited control) si Portainer reconoció el `name: infra` del `docker-compose.yml`. Si todavía no aparece, hacer **Sync** manual desde la UI; tras el siguiente snapshot debería listarse.

---

## 9. Solución de Problemas

| Síntoma | Causa probable | Acción |
|---|---|---|
| `portainer` arranca pero los logs muestran `cannot read initial data file` | El bind mount apunta a un directorio inexistente o sin permisos. | `ls -ld /mnt/hd2t/services/infra/portainer/data` debe devolver `drwxr-x--- homelab homelab`. Si está mal, recrear con `install -d -o homelab -g homelab -m 750 ...`. |
| Login pide configurar admin (no acepta `admin` + pass) y a los 5 min responde `Server error: please restart the Portainer instance` | Portainer arrancó **sin** `--admin-password` y nadie completó el wizard antes del timeout. | Parar el contenedor (`docker compose stop portainer`), añadir `command: --admin-password=${PORTAINER_ADMIN_PASSWORD_HASH}` y volver a `up -d`. La BD recuerda el bloqueo; si persiste, borrar `portainer.db` (perdiendo configuración) y reiniciar. |
| `--admin-password` devuelve `password verification failed` al iniciar | El hash en `.env` lleva caracteres `$` que el shell del host está expandiendo al pasar por `docker compose`. | Asegurar que el `.env` tiene el hash **sin** comillas y el `docker-compose.yml` interpola con `${VAR}` (no `$VAR`). Si se pega el hash a mano en YAML, escapar `$` como `$$`. |
| El navegador no carga `https://localhost:9443` tras el túnel SSH | El túnel se cerró (sesión SSH caída) o `9443` ya está ocupado en local. | Reabrir el túnel; si `9443` está en uso (`lsof -i :9443`), cambiar el lado local: `ssh -L 19443:127.0.0.1:9443 ...` y abrir `https://localhost:19443`. |
| Desde la LAN se accede a `https://<ip-pi>:9443` | El `ports:` se publicó a `0.0.0.0` por error. | Comprobar `docker port portainer`; debe leer `127.0.0.1:9443->9443/tcp`. Reescribir el `ports:` y `up -d --force-recreate portainer`. |
| Portainer muestra los contenedores pero **Console** falla con `connection closed` | El runtime usado (containerd) no permite `exec` con la imagen sin `tty`. | Casi siempre es un timeout del navegador o un proxy sin upgrade WebSocket. Confirmar que la conexión es directa por túnel SSH (no por un proxy intermedio); con Caddy delante, asegurar `reverse_proxy ... { header_up Connection {>Connection} }` y soporte de WebSocket. |
| `docker compose up` falla con `network homelab declared as external, but could not be found` | Falta crear la red compartida del homelab. | Crearla según [`02-estructura-compose.md`](./02-estructura-compose.md) §4.2: `docker network create --driver bridge --subnet 172.20.0.0/24 --gateway 172.20.0.1 --opt com.docker.network.bridge.name=br-homelab homelab`. |
| Tras un upgrade manual de Portainer (`image: ...:2.22.x`) la UI no abre y los logs hablan de migración de DB | Portainer aplica migraciones de schema entre versiones mayores; pueden tardar varios segundos en una Pi. | Esperar 30–60 s y mirar `docker logs -f portainer`; si el upgrade falla, **rollback**: cambiar la imagen a la versión previa, restaurar `portainer.db` desde Borg y `up -d --force-recreate portainer`. Por eso Watchtower **no** gestiona Portainer. |
| Healthcheck queda `unhealthy` aunque la UI funciona | `wget` dentro de la imagen no soporta el flag concreto, o el chequeo se ejecuta antes del `start_period`. | Reemplazar el `test:` por `["CMD", "wget", "-q", "--spider", "--no-check-certificate", "https://127.0.0.1:9443"]` o ampliar `start_period` a `60s` si el primer arranque es lento. |
| Portainer reclama una "license" o muestra banner de Business | Se descargó por error la imagen `portainer/portainer-ee` (Business Edition). | Cambiar a `portainer/portainer-ce:2.21.5` y `up -d --force-recreate`. |
| `docker logs portainer` repite `permission denied while trying to connect to the Docker daemon socket` | El socket está montado pero el contenedor no es `root` o el SELinux/AppArmor del host está bloqueando. | Confirmar que el bloque `volumes:` monta `/var/run/docker.sock` y que **no** se ha aplicado un `user: 1000:1000` (Portainer debe ser `root` dentro). En Bookworm con AppArmor por defecto no debería interferir; si interfiere, comprobar `dmesg | grep -i apparmor`. |
| Cambios en `/mnt/hd2t/services/infra/.env` no se reflejan tras editar | Compose no recrea contenedores por cambios solo en `env_file`. | `docker compose --env-file /mnt/hd2t/services/infra/.env up -d --force-recreate portainer`. |

---

## Referencias

- [Portainer — Install Portainer CE with Docker on Linux](https://docs.portainer.io/start/install-ce/server/docker/linux)
- [Portainer — Initial admin password / `--admin-password`](https://docs.portainer.io/start/install-ce/server/docker/linux#deployment)
- [Portainer — CLI options for the server (`--hide-label`, `--admin-password`, `--admin-password-file`)](https://docs.portainer.io/admin/configuration/cli)
- [Portainer — Limited stacks (control level)](https://docs.portainer.io/user/docker/stacks)
- [Portainer — Backup and restore the Portainer database](https://docs.portainer.io/admin/settings/backup)
- [Docker — Bind mount the Docker socket (`/var/run/docker.sock`)](https://docs.docker.com/engine/security/protect-access/)
- [Tecnativa — `docker-socket-proxy` (variante endurecida)](https://github.com/Tecnativa/docker-socket-proxy)
- [OWASP — Docker Security Cheat Sheet (socket exposure)](https://cheatsheetseries.owasp.org/cheatsheets/Docker_Security_Cheat_Sheet.html)
- [Apache `htpasswd` — bcrypt cost recommendations (`-C 12`)](https://httpd.apache.org/docs/2.4/programs/htpasswd.html)
