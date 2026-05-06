# Fail2ban

## Descripción
**Fail2ban** añade una capa de defensa activa frente a intentos repetidos de autenticación fallida en servicios del homelab. En esta fase se usa para vigilar **Nextcloud**, **Vaultwarden** y **Authelia**, y para insertar bloqueos temporales en la cadena **`DOCKER-USER`** del host, de forma que el tráfico quede cortado antes de llegar al proxy o al backend.

En este proyecto el homelab solo se expone por **LAN** y **Tailscale**, sin publicar servicios a internet. Aun así, sigue teniendo sentido aplicar baneo automático:

- un equipo comprometido de la LAN podría intentar fuerza bruta contra credenciales internas
- un nodo remoto de Tailscale con acceso permitido al homelab podría generar ruido o ataques de contraseña
- Authelia y los servicios protegidos siguen agradeciendo una capa adicional por IP además de sus límites internos

Esta fase **no sustituye** al `fail2ban` básico del host para SSH descrito en `docs/01-sistema/03-seguridad-base.md`. La idea es separar responsabilidades:

- `fail2ban` del host protege **SSH**
- `fail2ban` en este documento protege **servicios web en contenedores Docker**

Decisión importante para esta guía:

- no se dependerá de `/var/lib/docker/containers/*/*-json.log` como fuente principal
- esos logs dependen del ID efímero de cada contenedor y complican el mantenimiento tras recreaciones
- en su lugar, cada servicio escribirá su log en un **fichero persistente montado desde el host**
- Fail2ban leerá esos ficheros montados en modo solo lectura, lo que sigue siendo integración con logs de contenedores pero con rutas estables

Flujo recomendado de extremo a extremo:

- Caddy debe reenviar la IP original del cliente mediante `X-Forwarded-For` o la cabecera equivalente que espere cada aplicación
- Nextcloud, Vaultwarden y Authelia deben escribir los eventos de autenticación en un fichero persistente del **SSD NVMe**
- el contenedor de Fail2ban monta esos directorios en modo `:ro`, analiza los logs y publica el bloqueo en la cadena `DOCKER-USER`
- así el baneo ocurre en el host antes de que el tráfico vuelva a alcanzar el proxy o el backend

## Requisitos Previos
- Haber completado `docs/02-docker/01-instalacion-docker.md`.
- Haber completado `docs/02-docker/02-estructura-compose.md`.
- Haber completado `docs/03-red/04-caddy.md`.
- Haber completado `docs/04-seguridad/01-authelia.md`.
- Tener ya operativo el `fail2ban` básico para SSH en el host, si sigues el endurecimiento recomendado de `docs/01-sistema/03-seguridad-base.md`.
- Tener Caddy publicando los servicios por `80/tcp` y `443/tcp`.
- Tener disponibles rutas persistentes en el **SSD NVMe** para los logs de:
  - `Nextcloud`
  - `Vaultwarden`
  - `Authelia`
- Verificar en el host que existe la cadena `DOCKER-USER`:

```bash
sudo iptables -L DOCKER-USER -n
```

- Asegurarte de que los servicios registran la **IP real del cliente** y no solo la IP interna de Caddy.
- Puertos implicados en esta fase:
  - `80/tcp` y `443/tcp` siguen siendo los puertos de entrada hacia los servicios web
  - Fail2ban **no publica puertos**

## Docker Compose
Directorio recomendado:

```text
/home/<usuario>/homelab/compose/fail2ban/
├── compose.yaml
├── .env
└── config/
    ├── fail2ban/
    │   ├── jail.d/
    │   │   └── homelab.conf
    │   └── filter.d/
    │       ├── authelia.conf
    │       ├── nextcloud.conf
    │       └── vaultwarden.conf
    └── log/
        └── fail2ban.log
```

Fichero `.env`:

```dotenv
TZ=Europe/Madrid
PUID=1000
PGID=1000
FAIL2BAN_IMAGE=lscr.io/linuxserver/fail2ban:latest
```

Fichero `compose.yaml`:

```yaml
name: fail2ban

services:
  fail2ban:
    container_name: fail2ban
    image: ${FAIL2BAN_IMAGE}
    network_mode: host
    restart: unless-stopped
    env_file:
      - .env
    environment:
      PUID: ${PUID}
      PGID: ${PGID}
      TZ: ${TZ}
    cap_add:
      - NET_ADMIN
      - NET_RAW
    volumes:
      - ./config:/config
      - /home/<usuario>/homelab/data/nextcloud/html/data:/remotelogs/nextcloud:ro
      - /home/<usuario>/homelab/data/vaultwarden:/remotelogs/vaultwarden:ro
      - /home/<usuario>/homelab/compose/authelia/config:/remotelogs/authelia:ro
    security_opt:
      - no-new-privileges:true
```

Fichero `config/fail2ban/jail.d/homelab.conf`:

```ini
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1 <IP_LAN_PI> <IP_TAILSCALE_PI>
usedns = no
backend = auto
bantime = 12h
findtime = 10m
maxretry = 5
dbfile = /config/fail2ban/fail2ban.sqlite3
logtarget = /config/log/fail2ban.log

[nextcloud]
enabled = true
filter = nextcloud
port = http,https
logpath = /remotelogs/nextcloud/nextcloud.log
maxretry = 5
findtime = 10m
bantime = 12h
action = iptables-allports[name=nextcloud, chain=DOCKER-USER]

[vaultwarden]
enabled = true
filter = vaultwarden
port = http,https
logpath = /remotelogs/vaultwarden/vaultwarden.log
maxretry = 5
findtime = 15m
bantime = 12h
action = iptables-allports[name=vaultwarden, chain=DOCKER-USER]

[authelia]
enabled = true
filter = authelia
port = http,https
logpath = /remotelogs/authelia/authelia.log
maxretry = 5
findtime = 10m
bantime = 12h
action = iptables-allports[name=authelia, chain=DOCKER-USER]

[recidive]
enabled = true
logpath = /config/log/fail2ban.log
findtime = 7d
bantime = 30d
maxretry = 3
action = iptables-allports[name=recidive, chain=DOCKER-USER]
```

Fichero `config/fail2ban/filter.d/nextcloud.conf`:

```ini
[Definition]
_groupsre = (?:(?:,?\s*"\w+":(?:"[^"]+"|\w+))*)
failregex = ^\{%(_groupsre)s,?\s*"remoteAddr":"<HOST>"%(_groupsre)s,?\s*"message":"Login failed:
            ^\{%(_groupsre)s,?\s*"remoteAddr":"<HOST>"%(_groupsre)s,?\s*"message":"Two-factor challenge failed:
            ^\{%(_groupsre)s,?\s*"remoteAddr":"<HOST>"%(_groupsre)s,?\s*"message":"Trusted domain error.
datepattern = ,?\s*"time"\s*:\s*"%%Y-%%m-%%d[T ]%%H:%%M:%%S(%%z)?"
```

Fichero `config/fail2ban/filter.d/vaultwarden.conf`:

```ini
[Definition]
failregex = ^.*Username or password is incorrect\. Try again.*IP: <HOST>\. Username:.*$
            ^.*Invalid admin token\. IP: <HOST>\.?$
            ^.*Invalid or expired admin JWT\. IP: <HOST>\.?$
ignoreregex =
```

Fichero `config/fail2ban/filter.d/authelia.conf`:

```ini
[Definition]
failregex = ^.*remote_ip=<HOST>.*Authentication failed\. Check your credentials\..*$
            ^.*remote_ip=<HOST>.*Authentication failed, please retry later\..*$
            ^.*remote_ip=<HOST>.*user not found.*$
            ^.*remote_ip=<HOST>.*incorrect password.*$
ignoreregex =
```

Preparación inicial del stack:

```bash
mkdir -p /home/<usuario>/homelab/compose/fail2ban/config/fail2ban/{jail.d,filter.d}
mkdir -p /home/<usuario>/homelab/compose/fail2ban/config/log
touch /home/<usuario>/homelab/compose/fail2ban/config/log/fail2ban.log

cd /home/<usuario>/homelab/compose/fail2ban
docker compose pull
docker compose up -d
docker compose ps
docker compose logs -f fail2ban
```

Resultado esperado:

- el contenedor arranca con acceso a `NET_ADMIN` y `NET_RAW`
- no publica puertos
- se crea la base `fail2ban.sqlite3` en `./config/fail2ban/`
- la cadena `DOCKER-USER` empieza a recibir reglas cuando se detectan IPs a bloquear

## Configuración

### 1. Asegurar que cada servicio escribe un log persistente

Antes de activar los jails, revisa que los tres servicios escriban en rutas estables del NVMe.

#### Nextcloud

Nextcloud ya puede funcionar con fichero de log propio. Comprueba en `config.php` que al menos tengas algo equivalente a esto:

```php
'log_type' => 'file',
'logfile' => '/var/www/html/data/nextcloud.log',
'loglevel' => 2,
'trusted_proxies' => ['172.20.0.0/16'],
'forwarded_for_headers' => ['HTTP_X_FORWARDED_FOR'],
```

Notas prácticas:

- ajusta `trusted_proxies` a la subred real donde vive tu contenedor de Caddy
- si Nextcloud no confía en el proxy, el log reflejará la IP de Caddy y Fail2ban baneará al proxy en lugar del cliente
- el nivel `2` es importante porque los intentos fallidos de login se registran a ese nivel

#### Vaultwarden

En el stack de Vaultwarden añade o revisa estas variables:

```dotenv
LOG_FILE=/data/vaultwarden.log
LOG_LEVEL=warn
EXTENDED_LOGGING=true
IP_HEADER=X-Forwarded-For
```

Notas prácticas:

- `LOG_FILE` deja el log en el volumen persistente de Vaultwarden
- `IP_HEADER=X-Forwarded-For` ayuda a registrar la IP real cuando el tráfico entra por Caddy
- `EXTENDED_LOGGING=true` aporta más contexto en los eventos que luego leerá Fail2ban

#### Authelia

En `config/configuration.yml` de Authelia, amplía la sección `log`:

```yaml
log:
  level: 'info'
  format: 'text'
  file_path: '/config/authelia.log'
  keep_stdout: true
```

Notas prácticas:

- `file_path` genera el fichero estable que montará Fail2ban
- `keep_stdout: true` mantiene también el flujo habitual en `docker compose logs`
- el formato `text` simplifica el filtro y hace más legible la depuración manual

### 2. Ajustar las rutas montadas en el compose de Fail2ban

Las tres rutas de `volumes:` del contenedor `fail2ban` deben apuntar a los **bind mounts reales** de tus servicios. Si en tu proyecto las rutas cambian, adapta solo esas líneas:

- `/remotelogs/nextcloud/nextcloud.log` debe existir dentro del contenedor
- `/remotelogs/vaultwarden/vaultwarden.log` debe existir dentro del contenedor
- `/remotelogs/authelia/authelia.log` debe existir dentro del contenedor

Puedes comprobarlo así:

```bash
docker exec -it fail2ban ls -l /remotelogs/nextcloud
docker exec -it fail2ban ls -l /remotelogs/vaultwarden
docker exec -it fail2ban ls -l /remotelogs/authelia
```

Si alguno de esos directorios está vacío, el problema no está en Fail2ban sino en la ruta montada o en la configuración de logs del servicio correspondiente.

### 3. Ajustar la política de exclusiones

En `ignoreip` solo conviene incluir:

- loopback
- la IP LAN principal de la Raspberry Pi
- la IP Tailscale de la Raspberry Pi

No conviene meter rangos completos como:

- toda tu LAN
- `100.64.0.0/10`

Si lo haces, perderás capacidad de baneo precisamente contra clientes internos o remotos que sí deberían ser limitados.

### 4. Validar los filtros antes de confiar en ellos

Haz pruebas de sintaxis y de coincidencia con `fail2ban-regex`:

```bash
docker exec -it fail2ban fail2ban-regex /remotelogs/nextcloud/nextcloud.log /config/fail2ban/filter.d/nextcloud.conf
docker exec -it fail2ban fail2ban-regex /remotelogs/vaultwarden/vaultwarden.log /config/fail2ban/filter.d/vaultwarden.conf
docker exec -it fail2ban fail2ban-regex /remotelogs/authelia/authelia.log /config/fail2ban/filter.d/authelia.conf
```

Objetivo de esta comprobación:

- confirmar que cada filtro detecta líneas reales del servicio
- evitar falsos positivos
- verificar que la IP extraída es la del cliente y no la del proxy

En especial con Authelia, el patrón puede requerir pequeños ajustes si cambias el formato o el nivel del log en futuras versiones. Por eso conviene probarlo siempre tras una actualización mayor.

### 5. Arranque y comprobación de los jails

Tras validar los logs y filtros:

```bash
cd /home/<usuario>/homelab/compose/fail2ban
docker compose up -d

docker exec -it fail2ban fail2ban-client status
docker exec -it fail2ban fail2ban-client status nextcloud
docker exec -it fail2ban fail2ban-client status vaultwarden
docker exec -it fail2ban fail2ban-client status authelia
docker exec -it fail2ban fail2ban-client status recidive
```

Y en el host:

```bash
sudo iptables -L DOCKER-USER -n --line-numbers
```

Resultado esperado:

- aparecen los cuatro jails activos
- el contador de líneas procesadas aumenta
- tras varios fallos de login, la IP entra en la lista de baneadas
- `DOCKER-USER` contiene reglas añadidas por Fail2ban

### 6. Cómo probar cada servicio

Pruebas controladas recomendadas:

#### Nextcloud

1. Realiza varios intentos fallidos en la pantalla de login.
2. Comprueba que aparecen entradas `Login failed` en `nextcloud.log`.
3. Verifica el baneo en `fail2ban-client status nextcloud`.

#### Vaultwarden

1. Fuerza varios logins inválidos contra la bóveda web.
2. Opcionalmente prueba también accesos erróneos al panel admin.
3. Verifica que el baneo aparece en `status vaultwarden`.

#### Authelia

1. Intenta varias autenticaciones fallidas en el portal.
2. Comprueba que `authelia.log` refleja el `remote_ip` correcto.
3. Verifica el baneo en `status authelia`.

### 7. Desbaneo manual y operación diaria

Para desbanear una IP concreta:

```bash
docker exec -it fail2ban fail2ban-client set nextcloud unbanip 192.168.1.50
docker exec -it fail2ban fail2ban-client set vaultwarden unbanip 192.168.1.50
docker exec -it fail2ban fail2ban-client set authelia unbanip 192.168.1.50
```

Logs útiles:

```bash
cd /home/<usuario>/homelab/compose/fail2ban
docker compose logs -f fail2ban
tail -f /home/<usuario>/homelab/compose/fail2ban/config/log/fail2ban.log
```

### 8. Relación con Authelia y con los límites internos de las aplicaciones

Una política razonable en este homelab es combinar varias capas:

| Capa | Función |
|---|---|
| Authelia `regulation` | Limitar reintentos y retrasar ataques de login |
| Fail2ban | Banear IPs reincidentes en `DOCKER-USER` |
| Vaultwarden y Nextcloud | Mantener sus propios registros y controles internos |
| Tailscale + LAN local | Reducir superficie de exposición |

La clave es no elegir una sola capa, sino hacer que todas colaboren:

- Authelia frena
- Fail2ban corta
- los logs permiten auditar

## Almacenamiento

| Elemento | Ruta recomendada | Disco |
|---|---|---|
| Stack Compose | `/home/<usuario>/homelab/compose/fail2ban/` | SSD NVMe |
| Configuración principal | `/home/<usuario>/homelab/compose/fail2ban/config/fail2ban/` | SSD NVMe |
| Filtros personalizados | `/home/<usuario>/homelab/compose/fail2ban/config/fail2ban/filter.d/` | SSD NVMe |
| Jails personalizados | `/home/<usuario>/homelab/compose/fail2ban/config/fail2ban/jail.d/` | SSD NVMe |
| Base de estado | `/home/<usuario>/homelab/compose/fail2ban/config/fail2ban/fail2ban.sqlite3` | SSD NVMe |
| Log interno de Fail2ban | `/home/<usuario>/homelab/compose/fail2ban/config/log/fail2ban.log` | SSD NVMe |
| Log de Nextcloud | `/home/<usuario>/homelab/data/nextcloud/html/data/nextcloud.log` | SSD NVMe |
| Log de Vaultwarden | `/home/<usuario>/homelab/data/vaultwarden/vaultwarden.log` | SSD NVMe |
| Log de Authelia | `/home/<usuario>/homelab/compose/authelia/config/authelia.log` | SSD NVMe |

Notas de almacenamiento:

- todo el estado de Fail2ban debe permanecer en el **NVMe**
- no tiene sentido guardar la base de estado o los filtros en `hd2t` o `hd5t`
- los logs que alimentan los jails también deben vivir en almacenamiento persistente y estable
- si recreas un contenedor pero mantienes el mismo bind mount, la ruta seguirá siendo válida para Fail2ban

Permisos recomendados:

```bash
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/compose/fail2ban
chmod 755 /home/<usuario>/homelab/compose/fail2ban/config
chmod 755 /home/<usuario>/homelab/compose/fail2ban/config/fail2ban
chmod 644 /home/<usuario>/homelab/compose/fail2ban/config/fail2ban/jail.d/homelab.conf
chmod 644 /home/<usuario>/homelab/compose/fail2ban/config/fail2ban/filter.d/*.conf
chmod 640 /home/<usuario>/homelab/compose/fail2ban/config/log/fail2ban.log
```

## Backup
Conviene respaldar como mínimo:

- `/home/<usuario>/homelab/compose/fail2ban/compose.yaml`
- `/home/<usuario>/homelab/compose/fail2ban/.env`
- `/home/<usuario>/homelab/compose/fail2ban/config/fail2ban/jail.d/homelab.conf`
- `/home/<usuario>/homelab/compose/fail2ban/config/fail2ban/filter.d/`
- `/home/<usuario>/homelab/compose/fail2ban/config/fail2ban/fail2ban.sqlite3`
- `/home/<usuario>/homelab/compose/fail2ban/config/log/fail2ban.log`

Conviene respaldar también, porque de ellos depende la detección:

- `/home/<usuario>/homelab/data/nextcloud/html/data/nextcloud.log`
- `/home/<usuario>/homelab/data/vaultwarden/vaultwarden.log`
- `/home/<usuario>/homelab/compose/authelia/config/authelia.log`

No es necesario respaldar:

- la imagen `lscr.io/linuxserver/fail2ban`
- el contenedor recreable
- reglas activas de iptables en memoria

Estrategia práctica de restauración:

1. Restaurar el directorio completo del stack en el NVMe.
2. Restaurar los logs persistentes de los servicios si quieres conservar trazabilidad histórica.
3. Levantar Fail2ban con `docker compose up -d`.
4. Verificar con `fail2ban-client status` que los jails vuelven a cargar.
5. Confirmar en `iptables -L DOCKER-USER -n` que los baneos nuevos se insertan correctamente.

## Referencias
- Fail2ban  
  https://www.fail2ban.org/wiki/index.php/Main_Page
- LinuxServer image: `lscr.io/linuxserver/fail2ban`  
  https://github.com/linuxserver/docker-fail2ban
- Nextcloud Admin Manual: Setup fail2ban  
  https://docs.nextcloud.com/server/stable/admin_manual/installation/harden_server.html
- Authelia Docs: Log configuration  
  https://www.authelia.com/configuration/miscellaneous/logging/
- Authelia Docs: Regulation  
  https://www.authelia.com/configuration/security/regulation/
- Vaultwarden repository  
  https://github.com/dani-garcia/vaultwarden
- Docker Hub / registry reference for LinuxServer images  
  https://fleet.linuxserver.io/image?name=linuxserver/fail2ban
