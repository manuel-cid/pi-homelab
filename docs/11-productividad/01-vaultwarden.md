# Vaultwarden

## Descripción
**Vaultwarden** será el gestor de contraseñas del homelab, compatible con los clientes oficiales de **Bitwarden** y suficientemente ligero para ejecutarse sin problemas en la **Raspberry Pi 5**.

En esta arquitectura se despliega con estas reglas:

- el servicio y todos sus datos persistentes viven en el **SSD NVMe**
- el acceso web local se publica detrás de **Caddy** con `https://vaultwarden.lan`
- la conexión va siempre por **HTTPS** con la **CA interna de Caddy**
- el acceso remoto sigue siendo **solo LAN + Tailscale**, sin abrir puertos en el router
- el almacenamiento usa la base de datos **SQLite** integrada, suficiente para un uso personal o familiar pequeño

Vaultwarden encaja bien en este homelab porque reduce complejidad frente al stack oficial de Bitwarden, mantiene el estado en un único directorio fácil de respaldar y permite usar navegador, móvil, escritorio y CLI con el mismo servidor privado.

## Requisitos Previos
- Haber completado `docs/02-docker/01-instalacion-docker.md`.
- Haber completado `docs/02-docker/02-estructura-compose.md`.
- Haber completado `docs/01-sistema/04-estructura-directorios.md`.
- Haber completado `docs/03-red/04-caddy.md`.
- Haber completado `docs/03-red/05-tailscale.md` si quieres sincronizar también desde fuera de la LAN mediante VPN.
- Haber completado `docs/07-backups/01-estrategia-backup.md`.
- Tener creada la red Docker externa `homelab_proxy`.
- Tener resuelto en Pi-hole o en tu DNS local el FQDN `vaultwarden.lan` apuntando a la IP LAN principal de la Raspberry Pi.
- Tener importada en los dispositivos cliente la CA local de Caddy desde:
  - `/home/<usuario>/homelab/compose/caddy/data/caddy/pki/authorities/local/root.crt`
- Poder usar `sudo` con el usuario administrador del homelab.
- Puertos implicados en esta fase:
  - `80/tcp` solo dentro de Docker entre Caddy y el contenedor `vaultwarden`
  - `443/tcp` ya publicado por Caddy en el host
  - no se abre ningún puerto entrante en el router

## Docker Compose
Directorio recomendado:

```text
/home/<usuario>/homelab/compose/vaultwarden/
├── compose.yaml
└── .env
```

Preparación inicial:

```bash
mkdir -p /home/<usuario>/homelab/compose/vaultwarden
mkdir -p /home/<usuario>/homelab/data/vaultwarden
```

Fichero `.env`:

```dotenv
TZ=Europe/Madrid

VAULTWARDEN_IMAGE=vaultwarden/server:latest

DOMAIN=https://vaultwarden.lan
SIGNUPS_ALLOWED=true
INVITATIONS_ALLOWED=false
SHOW_PASSWORD_HINT=false

ADMIN_TOKEN=<token-o-password-de-admin>

LOG_FILE=/data/vaultwarden.log
LOG_LEVEL=warn
EXTENDED_LOGGING=true
IP_HEADER=X-Forwarded-For

ICON_SERVICE=internal
DISABLE_ICON_DOWNLOAD=true
ICON_CACHE_TTL=0

DATA_DIR=/home/<usuario>/homelab/data/vaultwarden
```

Notas sobre estas variables:

- `DOMAIN` debe coincidir exactamente con la URL real que usarán los clientes Bitwarden.
- `SIGNUPS_ALLOWED=true` se usa solo para el arranque inicial. Después de crear la cuenta principal conviene cambiarlo a `false`.
- `ADMIN_TOKEN` habilita `/admin`. Lo recomendable es usar una contraseña larga o, mejor aún, un hash Argon2.
- `LOG_FILE`, `LOG_LEVEL`, `EXTENDED_LOGGING` e `IP_HEADER` dejan la configuración alineada con `docs/04-seguridad/02-fail2ban.md`.
- `ICON_SERVICE=internal`, `DISABLE_ICON_DOWNLOAD=true` e `ICON_CACHE_TTL=0` evitan depender de descargas externas de iconos.
- `DATA_DIR` vive en el NVMe porque ahí estarán la base de datos, adjuntos, claves y logs.

Generar un `ADMIN_TOKEN` seguro con el binario embebido en la imagen:

```bash
docker run --rm --entrypoint /vaultwarden vaultwarden/server:latest hash
```

Si pegas un hash Argon2 en el `.env` de este stack y lo cargas mediante `env_file`, no hace falta interpolarlo en el YAML. Evita referenciarlo como `${ADMIN_TOKEN}` dentro de `compose.yaml`.

Fichero `compose.yaml`:

```yaml
name: vaultwarden

services:
  vaultwarden:
    container_name: vaultwarden
    image: ${VAULTWARDEN_IMAGE}
    restart: unless-stopped
    env_file:
      - .env
    environment:
      TZ: ${TZ}
    volumes:
      - ${DATA_DIR}:/data
    networks:
      - default
      - homelab_proxy
    security_opt:
      - no-new-privileges:true

networks:
  homelab_proxy:
    external: true
    name: homelab_proxy
```

Notas operativas sobre este stack:

- no se publica ningún puerto en el host porque el acceso recomendado es solo a través de **Caddy**
- para un homelab personal no hace falta una base de datos externa: **SQLite** simplifica despliegue y backup
- todos los datos persistentes quedan concentrados en `/data`
- el contenedor se puede recrear sin perder estado mientras el bind mount del NVMe se conserve

Despliegue inicial:

```bash
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/compose/vaultwarden
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/data/vaultwarden

cd /home/<usuario>/homelab/compose/vaultwarden
docker compose config
docker compose pull
docker compose up -d
docker compose ps
docker compose logs -f vaultwarden
```

Resultado esperado:

- el contenedor `vaultwarden` queda levantado
- Vaultwarden escucha internamente en `http://vaultwarden:80`
- se crea la estructura persistente en `/home/<usuario>/homelab/data/vaultwarden/`
- Caddy puede publicar el servicio como `https://vaultwarden.lan`

## Configuración

### Objetivo de esta fase

| Elemento | Estado esperado |
|---|---|
| UI local | `https://vaultwarden.lan` |
| Persistencia | `/home/<usuario>/homelab/data/vaultwarden/` |
| Base de datos | SQLite en el NVMe |
| Punto de entrada | Caddy |
| TLS | `tls internal` con CA local de Caddy |
| Clientes | navegador, móvil, escritorio y CLI de Bitwarden |
| Registro público | desactivado tras el alta inicial |

### 1. Preparar rutas y permisos

Crear la estructura base:

```bash
mkdir -p /home/<usuario>/homelab/compose/vaultwarden
mkdir -p /home/<usuario>/homelab/data/vaultwarden
```

Permisos recomendados:

```bash
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/compose/vaultwarden
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/data/vaultwarden

chmod 755 /home/<usuario>/homelab/data/vaultwarden
```

Vaultwarden escribe con frecuencia en la base SQLite, en los adjuntos y en el log persistente. Por eso conviene mantener todo su estado en el **SSD NVMe** y no en un disco USB mecánico.

### 2. Publicar Vaultwarden en Caddy con HTTPS interno

Añade este bloque al `Caddyfile` del stack de Caddy:

```caddyfile
vaultwarden.lan {
  import common
  tls internal
  reverse_proxy vaultwarden:80
}
```

Después valida y recarga Caddy:

```bash
cd /home/<usuario>/homelab/compose/caddy
docker compose exec caddy caddy validate --config /etc/caddy/Caddyfile
docker compose up -d
docker compose logs --tail=100 caddy
```

Notas prácticas:

- usa siempre un hostname propio en la raíz, no un subpath como `/vaultwarden/`, para evitar problemas en clientes Bitwarden
- si en tu homelab ya has estandarizado `*.homelab.lan`, sustituye `vaultwarden.lan` por `vaultwarden.homelab.lan` en **DNS**, `DOMAIN` y `Caddyfile`
- no intentes acceder por `http://` desde los clientes Bitwarden: usa siempre `https://`

### 3. Importar la CA local de Caddy en los dispositivos cliente

Ruta del certificado raíz en el host:

```text
/home/<usuario>/homelab/compose/caddy/data/caddy/pki/authorities/local/root.crt
```

Importa ese certificado en:

- tu navegador principal
- el sistema operativo del portátil o sobremesa donde uses la app de Bitwarden
- el móvil o tablet donde vayas a usar la app oficial

Sin esa CA instalada:

- la conexión seguirá cifrada
- pero los clientes no confiarán en el certificado y el alta del servidor fallará o mostrará advertencias

### 4. Arranque inicial y endurecimiento básico

Arranca primero Vaultwarden con `SIGNUPS_ALLOWED=true` para crear la cuenta principal:

```bash
cd /home/<usuario>/homelab/compose/vaultwarden
docker compose up -d
```

Abrir después:

```text
https://vaultwarden.lan
```

Secuencia recomendada:

1. Crear la cuenta principal desde la pantalla pública de registro.
2. Iniciar sesión y comprobar que el web vault carga correctamente.
3. Abrir `https://vaultwarden.lan/admin` y entrar con el `ADMIN_TOKEN`.
4. Revisar que el servicio guarda datos en `/data` y que el log persistente existe.
5. Volver al fichero `.env`, cambiar `SIGNUPS_ALLOWED=false` y recrear el stack.

Aplicar el endurecimiento:

```bash
cd /home/<usuario>/homelab/compose/vaultwarden
sed -i 's/^SIGNUPS_ALLOWED=true$/SIGNUPS_ALLOWED=false/' .env
docker compose up -d
```

Ajustes recomendados después del primer login:

- activar **2FA** en la cuenta principal
- revisar la política de creación de organizaciones si el servicio va a ser solo personal
- mantener el `ADMIN_TOKEN` fuera de gestores inseguros o notas en claro
- si cambias opciones desde `https://vaultwarden.lan/admin`, revisa después `/home/<usuario>/homelab/data/vaultwarden/config.json`; Vaultwarden puede persistir ahí ajustes que después prevalezcan sobre parte de la configuración gestionada en `.env`
- si más adelante integras **Authelia**, consulta `docs/04-seguridad/01-authelia.md`
- si quieres protección contra fuerza bruta, consulta `docs/04-seguridad/02-fail2ban.md`

### 5. Configurar clientes Bitwarden

Para extensión de navegador, app móvil o app de escritorio:

1. En la pantalla de login, elegir la opción de entorno **Self-hosted**.
2. Introducir como servidor:
   - `https://vaultwarden.lan`
3. Guardar y autenticarse normalmente.

Para la CLI:

```bash
bw logout
bw config server https://vaultwarden.lan
bw login
```

Recomendaciones prácticas con clientes:

- mantén siempre la misma URL base; no alternes entre varios dominios para el mismo vault
- si vas a usar Tailscale fuera de casa, procura que el dispositivo remoto también resuelva el mismo FQDN interno y confíe en la misma CA
- prueba primero desde navegador antes de configurar las apps móviles, porque el navegador ayuda a aislar errores de DNS o de certificados

## Almacenamiento
Volúmenes y rutas persistentes de este servicio:

| Elemento | Ruta en host | Ubicación física |
|---|---|---|
| Datos de Vaultwarden | `/home/<usuario>/homelab/data/vaultwarden/` | SSD NVMe |
| Compose del stack | `/home/<usuario>/homelab/compose/vaultwarden/` | SSD NVMe |
| Backups exportados | `/mnt/hd2t/backups/exports/vaultwarden/` | `hd2t` |

Ruta persistente principal:

```text
/home/<usuario>/homelab/data/vaultwarden/
```

Contenido típico tras el despliegue:

```text
/home/<usuario>/homelab/data/vaultwarden/
├── db.sqlite3
├── attachments/
├── sends/
├── icon_cache/
├── rsa_key.der
├── rsa_key.pem
├── rsa_key.pub.der
├── rsa_key.pub.pem
└── vaultwarden.log
```

Qué guarda cada zona:

- `db.sqlite3`: vault principal, usuarios, organizaciones, colecciones y metadatos
- `attachments/`: ficheros adjuntos asociados a entradas
- `sends/`: contenido de Bitwarden Send
- `icon_cache/`: caché local de iconos si se usa el servicio interno
- `rsa_key*`: claves usadas por el servicio para cifrado y firma
- `vaultwarden.log`: log persistente útil para troubleshooting y Fail2ban

Recomendaciones de almacenamiento:

- no pongas esta ruta en `hd2t` ni en `hd5t`
- no mezcles aquí otros servicios
- mantén el directorio completo dentro de los backups del NVMe
- si restauras solo `db.sqlite3` pero olvidas `attachments/` o `rsa_key*`, la aplicación puede arrancar pero quedar incompleta

## Backup
Para Vaultwarden el backup correcto no es solo la base SQLite. Debes considerar como conjunto mínimo:

- `/home/<usuario>/homelab/data/vaultwarden/db.sqlite3`
- `/home/<usuario>/homelab/data/vaultwarden/attachments/`
- `/home/<usuario>/homelab/data/vaultwarden/sends/`
- `/home/<usuario>/homelab/data/vaultwarden/rsa_key*`
- `/home/<usuario>/homelab/data/vaultwarden/vaultwarden.log` si quieres conservar trazabilidad
- `/home/<usuario>/homelab/compose/vaultwarden/` para poder recrear el stack con el mismo `compose.yaml` y el mismo `.env`

En este homelab, la estrategia recomendada es:

- **backup automático** del directorio de datos y del directorio `compose/` mediante Borgmatic, porque ambos viven en el NVMe
- **export manual** antes de cambios delicados como actualizaciones mayores, cambios de URL o migraciones

### Backup manual consistente del directorio completo

El método más simple y robusto para un homelab pequeño es parar unos segundos el servicio y respaldar el directorio entero:

```bash
mkdir -p /mnt/hd2t/backups/exports/vaultwarden
timestamp="$(date +%F-%H%M%S)"

cd /home/<usuario>/homelab/compose/vaultwarden
docker compose stop vaultwarden

sudo tar \
  --xattrs \
  --acls \
  --numeric-owner \
  -czf "/mnt/hd2t/backups/exports/vaultwarden/vaultwarden-data-${timestamp}.tar.gz" \
  -C /home/<usuario>/homelab/data/vaultwarden .

sha256sum "/mnt/hd2t/backups/exports/vaultwarden/vaultwarden-data-${timestamp}.tar.gz" \
  > "/mnt/hd2t/backups/exports/vaultwarden/vaultwarden-data-${timestamp}.tar.gz.sha256"

docker compose start vaultwarden

rsync -a \
  /home/<usuario>/homelab/compose/vaultwarden/ \
  /mnt/hd2t/backups/exports/vaultwarden/compose/
```

### Copia puntual solo de la base de datos SQLite

Si quieres una copia separada de la base para inspección o restore rápido:

```bash
mkdir -p /mnt/hd2t/backups/exports/databases
timestamp="$(date +%F-%H%M%S)"

cd /home/<usuario>/homelab/compose/vaultwarden
docker compose stop vaultwarden

sudo cp \
  /home/<usuario>/homelab/data/vaultwarden/db.sqlite3 \
  "/mnt/hd2t/backups/exports/databases/vaultwarden-db-${timestamp}.sqlite3"

sha256sum "/mnt/hd2t/backups/exports/databases/vaultwarden-db-${timestamp}.sqlite3" \
  > "/mnt/hd2t/backups/exports/databases/vaultwarden-db-${timestamp}.sqlite3.sha256"

docker compose start vaultwarden
```

Qué no debes hacer como única copia:

- respaldar solo `db.sqlite3` e ignorar adjuntos y claves
- confiar solo en el contenedor o en la imagen descargada
- olvidar el directorio `compose/`, que contiene la configuración exacta del despliegue
- hacer un `tar` de `/data` mientras el servicio escribe intensamente sin aceptar el riesgo de incoherencia

### Restore recomendado

Secuencia práctica:

1. Parar el stack de Vaultwarden.
2. Renombrar el directorio actual como salvaguarda.
3. Restaurar el directorio completo desde el backup.
4. Levantar el stack.
5. Verificar login, sincronización y acceso a adjuntos.

Ejemplo:

```bash
cd /home/<usuario>/homelab/compose/vaultwarden
docker compose down

sudo mv \
  /home/<usuario>/homelab/data/vaultwarden \
  "/home/<usuario>/homelab/data/vaultwarden.before-restore-$(date +%F-%H%M%S)"

sudo mkdir -p /home/<usuario>/homelab/data/vaultwarden

sudo tar \
  --xattrs \
  --acls \
  --numeric-owner \
  -xzf /mnt/hd2t/backups/exports/vaultwarden/vaultwarden-data-<timestamp>.tar.gz \
  -C /home/<usuario>/homelab/data/vaultwarden

docker compose up -d
docker compose logs --tail=100 vaultwarden
```

Validación posterior al restore:

- el login funciona con la cuenta existente
- los clientes sincronizan sin crear un vault vacío
- los adjuntos se descargan correctamente
- `https://vaultwarden.lan/admin` sigue respondiendo

## Referencias
- Repositorio oficial de Vaultwarden: `https://github.com/dani-garcia/vaultwarden`
- Plantilla oficial de configuración `.env`: `https://github.com/dani-garcia/vaultwarden/blob/main/.env.template`
- Wiki oficial de Vaultwarden: `https://github.com/dani-garcia/vaultwarden/wiki`
- Vaultwarden Wiki: Enabling HTTPS: `https://github.com/dani-garcia/vaultwarden/wiki/Enabling-HTTPS`
- Vaultwarden Wiki: Proxy examples: `https://github.com/dani-garcia/vaultwarden/wiki/Proxy-examples`
- Vaultwarden Wiki: Enabling admin page: `https://github.com/dani-garcia/vaultwarden/wiki/Enabling-admin-page`
- Imagen Docker `vaultwarden/server`: `https://hub.docker.com/r/vaultwarden/server`
- Bitwarden Help: Connect individual clients: `https://bitwarden.com/help/change-client-environment/`
