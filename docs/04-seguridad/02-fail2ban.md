# Fail2ban

## Descripción

En [03-seguridad-base.md](../01-sistema/03-seguridad-base.md) **Fail2ban** quedó instalado y activo solo para el jail `sshd`. En esta guía se amplía esa instalación para cubrir también servicios web del homelab que terminan entrando por **Caddy** en Docker, en particular los flujos de autenticación de **Authelia** y **Vaultwarden**, leyendo sus logs persistidos en el **SSD NVMe** y aplicando bans a nivel de host.

Hay una decisión de diseño importante en esta fase:

- el jail `sshd` del host puede seguir usando `ufw`, tal como se definió en la guía base
- los jails de servicios que entran por **Caddy** no deben reutilizar ciegamente ese mismo mecanismo
- para tráfico que entra por contenedores publicados en el host conviene aplicar el ban en la cadena **`DOCKER-USER`**
- por eso, en esta guía los jails de **Authelia** y **Vaultwarden** usan una acción basada en `iptables-allports` sobre `DOCKER-USER`

El resultado buscado es este:

- mantener el jail `sshd` ya existente sin romperlo
- añadir un jail funcional para **Authelia**
- dejar preparado el jail de **Vaultwarden** para activarlo cuando ese servicio quede desplegado y publique su backend en loopback, en línea con la arquitectura base del proyecto
- consumir logs persistentes y legibles desde el host, sin depender de rutas efímeras dentro de contenedores

En todo el documento, sustituye los marcadores `<user>` y `<tailnet>` por tus valores reales antes de aplicar comandos o rutas.

## Requisitos Previos

- Haber completado [03-seguridad-base.md](../01-sistema/03-seguridad-base.md).
- Haber completado [01-authelia.md](01-authelia.md).
- Haber completado [05-caddy.md](../03-red/05-caddy.md) si Authelia o Vaultwarden se publican detrás de Caddy.
- Tener Docker Engine operativo y con los stacks de infraestructura levantados.
- Tener el servicio `fail2ban` activo en el host.
- Poder usar `sudo` sobre la Raspberry Pi.
- Tener disponible la cadena `DOCKER-USER`, lo habitual cuando Docker está arrancado y Caddy usa `network_mode: host`.
- Tener almacenamiento persistente en el **SSD NVMe** dentro de `/home/<user>/homelab/data/`.
- Puertos relevantes en esta fase:
  - **`22/tcp`** para el jail `sshd` ya existente
  - **`80/tcp`** como entrada HTTP en LAN a través de **Caddy**
  - **`443/tcp`** como entrada HTTPS por **Tailscale** a través de **Caddy**
  - **`9091/tcp`** solo interno entre Caddy y Authelia; no es un puerto publicado en el host ni el punto de entrada del ban

## Docker Compose

No aplica como stack independiente. **Fail2ban** sigue ejecutándose como servicio del **host**.

Lo que sí cambia en esta fase es la configuración de algunos contenedores para que escriban logs persistentes en rutas visibles desde el host. Esos ajustes se detallan en el apartado de configuración.

## Configuración

### 1. Verificar el estado actual de Fail2ban y Docker

Antes de añadir jails nuevos, confirma que la instalación base sigue sana:

```bash
sudo systemctl status fail2ban --no-pager
sudo fail2ban-client status
sudo fail2ban-client status sshd
sudo iptables -L DOCKER-USER -n --line-numbers
```

El estado esperado en este punto es este:

- `fail2ban` está activo
- el jail `sshd` sigue cargado
- Docker ya ha creado la cadena `DOCKER-USER`

Si `DOCKER-USER` no existe, no continúes todavía con los jails de servicios. Arranca Docker primero y vuelve a comprobarlo.

### 2. Mantener separadas las dos familias de jails

En este homelab conviene distinguir claramente dos casos:

- **host**: `sshd`, con bans integrados en `ufw`
- **tráfico web que entra por Caddy ejecutándose en Docker con `network_mode: host`**: Authelia, Vaultwarden y otros servicios web, con bans en `DOCKER-USER`

No sustituyas ni reescribas el fichero `sshd.local` definido en [03-seguridad-base.md](../01-sistema/03-seguridad-base.md). La ampliación de esta guía debe convivir con él.

### 3. Hacer persistente el log de Authelia

Para que **Fail2ban** pueda leer los eventos de autenticación de **Authelia** desde el host, verifica que el bloque `log` en:

- `/home/<user>/homelab/config/authelia/configuration.yml`

incluya al menos estos valores, en línea con lo documentado en [01-authelia.md](01-authelia.md):

```yaml
log:
  level: info
  format: text
  file_path: /data/authelia.log
  keep_stdout: true
```

Con esto:

- Authelia sigue escribiendo en `docker logs`
- además deja un fichero persistente en `/home/<user>/homelab/data/authelia/authelia.log`
- Fail2ban puede leer ese fichero directamente desde el host

Aplica el cambio:

```bash
cd /home/<user>/homelab/compose/auth-authelia
docker compose up -d
docker compose logs --tail 100 authelia
ls -lh /home/<user>/homelab/data/authelia/authelia.log
```

Haz un intento fallido de login y valida después que el log contiene la IP real del cliente, no una IP interna de Docker.

Si en el log ves una IP del rango `172.x.x.x` en el campo `remote_ip`, la causa más probable es que **Caddy no esté usando `network_mode: host`** en su stack de Docker. Cuando Caddy se publica con `ports:` normales, Docker reenvía las conexiones al contenedor mediante `docker-proxy`, que abre una nueva conexión TCP desde la IP del gateway Docker (`172.x.x.1`). La IP real del cliente se pierde irreversiblemente a nivel TCP y ni Caddy ni Authelia pueden recuperarla.

La corrección es asegurar que Caddy use `network_mode: host` tal como se documenta en [05-caddy.md](../03-red/05-caddy.md). Con esa configuración, Caddy escucha directamente en la pila de red del host y ve la IP real de todos los clientes (LAN y Tailscale). La cabecera `X-Forwarded-For` que Caddy envía a Authelia contendrá la IP correcta.

Después de aplicar o confirmar el cambio, repite la prueba:

```bash
tail -20 /home/<user>/homelab/data/authelia/authelia.log | grep -i "remote_ip"
```

Si ahora ves la IP real del cliente (por ejemplo `100.x.x.x` para Tailscale o `192.168.x.x` para LAN), el tratamiento es correcto y puedes continuar con la activación del jail.

### 4. Preparar Vaultwarden para logging persistente

Cuando despliegues **Vaultwarden** según [01-vaultwarden.md](../11-productividad/01-vaultwarden.md), asegúrate de que su servicio mantenga estos valores de entorno, exactamente igual que en esa guía:

```yaml
environment:
  TZ: ${TZ}
  LOG_FILE: /data/vaultwarden.log
  LOG_LEVEL: warn
  EXTENDED_LOGGING: "true"
```

Con esta decisión:

- los fallos de autenticación quedan registrados en `/data/vaultwarden.log`
- el fichero persistente visible desde el host será `/home/<user>/homelab/data/vaultwarden/vaultwarden.log`
- `warn` sigue siendo suficiente para que los eventos relevantes de Fail2ban aparezcan en el log

Además, para que **Fail2ban** pueda actuar a través de `DOCKER-USER`, Vaultwarden debe quedar alcanzable por **Caddy** mediante `127.0.0.1:<puerto>` o por otro patrón equivalente que siga atravesando la entrada publicada en el host, tal como exige la arquitectura base descrita en [05-caddy.md](../03-red/05-caddy.md) y en `SERVICES.md`.
<!-- TODO: verificar y alinear [01-vaultwarden.md](../11-productividad/01-vaultwarden.md) con la arquitectura base de Caddy en `network_mode: host`, porque ese documento todavía describe `homelab_proxy` como via principal entre Caddy y Vaultwarden. -->

Si **Vaultwarden** va detrás de **Caddy** con esa topología, la IP real del cliente llegará correctamente al backend gracias a que Caddy usa `network_mode: host` según [05-caddy.md](../03-red/05-caddy.md). El patrón documentado para Vaultwarden debe conservar además `header_up X-Real-IP {remote_host}` para que el servicio registre esa IP en su log.

Antes de habilitar el jail de Vaultwarden, comprueba con un login fallido que `vaultwarden.log` refleja la IP del cliente y no `127.0.0.1`.

### 5. Crear el filtro de Authelia

Crea este fichero:

```bash
sudo nano /etc/fail2ban/filter.d/authelia.local
```

Contenido recomendado:

```ini
[Definition]
failregex = ^.*Unsuccessful (1FA|TOTP|Duo|U2F) authentication attempt by user .*remote_ip"?(:|=)"?<HOST>"?.*$
            ^.*user not found.*path=/api/reset-password/identity/start remote_ip"?(:|=)"?<HOST>"?.*$

ignoreregex = ^.*level"?(:|=)"?info.*
              ^.*level"?(:|=)"?warning.*
```

Este filtro captura sobre todo:

- intentos fallidos de primer factor
- intentos fallidos de segundo factor
- peticiones inválidas al flujo de inicio de reseteo de contraseña

### 6. Crear el filtro de Vaultwarden

Crea este fichero:

```bash
sudo nano /etc/fail2ban/filter.d/vaultwarden.local
```

Contenido recomendado:

```ini
[INCLUDES]
before = common.conf

[Definition]
failregex = ^.*Username or password is incorrect\. Try again\. IP: <HOST>\. Username:.*$
ignoreregex =
```

Si también expones el panel administrativo de Vaultwarden mediante `ADMIN_TOKEN`, crea además un filtro específico:

```bash
sudo nano /etc/fail2ban/filter.d/vaultwarden-admin.local
```

```ini
[INCLUDES]
before = common.conf

[Definition]
failregex = ^.*Invalid admin token\. IP: <HOST>.*$
ignoreregex =
```

### 7. Crear los jails de servicios

Crea un fichero dedicado:

```bash
sudo nano /etc/fail2ban/jail.d/20-homelab-services.local
```

Contenido recomendado:

```ini
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1

[authelia]
enabled = true
backend = auto
filter = authelia
logpath = /home/<user>/homelab/data/authelia/authelia.log
port = 443
findtime = 15m
maxretry = 5
bantime = 4h
action = iptables-allports[name=authelia, chain=DOCKER-USER]

[vaultwarden]
enabled = false
backend = auto
filter = vaultwarden
logpath = /home/<user>/homelab/data/vaultwarden/vaultwarden.log
port = 443
findtime = 1h
maxretry = 3
bantime = 12h
action = iptables-allports[name=vaultwarden, chain=DOCKER-USER]

[vaultwarden-admin]
enabled = false
backend = auto
filter = vaultwarden-admin
logpath = /home/<user>/homelab/data/vaultwarden/vaultwarden.log
port = 443
findtime = 1h
maxretry = 3
bantime = 24h
action = iptables-allports[name=vaultwarden-admin, chain=DOCKER-USER]
```

Notas sobre este diseño:

- **Authelia** queda habilitado ya en esta fase
- **Vaultwarden** y `vaultwarden-admin` quedan preparados pero deshabilitados hasta que el servicio exista y el log esté realmente disponible
- cuando despliegues Vaultwarden, cambia `enabled = false` por `enabled = true` en el jail correspondiente
- los bans afectan a todo el tráfico del origen contra el host a través de `DOCKER-USER`, no solo al backend concreto que generó el log
- el jail `sshd` sigue usando `ufw` como en [03-seguridad-base.md](../01-sistema/03-seguridad-base.md); estos jails web usan `DOCKER-USER` porque el punto de entrada real es **Caddy** ejecutándose en Docker con `network_mode: host`
- aunque aquí se documente `port = 443`, el ban se aplica igualmente sobre cualquier tráfico Dockerizado que atraviese `DOCKER-USER`; ese campo queda como referencia operativa del punto de entrada HTTPS canónico del proyecto y el mismo origen quedará bloqueado también si intenta entrar por `80/tcp`

### 8. Validar filtros antes de reiniciar

Valida primero el filtro de Authelia contra su log:

```bash
sudo fail2ban-regex /home/<user>/homelab/data/authelia/authelia.log /etc/fail2ban/filter.d/authelia.local
```

Cuando Vaultwarden exista, valida también estos:

```bash
sudo fail2ban-regex /home/<user>/homelab/data/vaultwarden/vaultwarden.log /etc/fail2ban/filter.d/vaultwarden.local
sudo fail2ban-regex /home/<user>/homelab/data/vaultwarden/vaultwarden.log /etc/fail2ban/filter.d/vaultwarden-admin.local
```

No avances si `fail2ban-regex` no detecta coincidencias reales en logs de prueba.

### 9. Reiniciar Fail2ban y comprobar los jails

```bash
sudo systemctl restart fail2ban
sudo systemctl status fail2ban --no-pager
sudo fail2ban-client status
sudo fail2ban-client status authelia
```

Cuando actives Vaultwarden:

```bash
sudo fail2ban-client status vaultwarden
sudo fail2ban-client status vaultwarden-admin
```

El estado correcto para `authelia` es este:

- el jail aparece cargado
- `Currently failed` puede variar
- el `File list` apunta al log persistente del servicio

### 10. Probar un ban real y revertirlo

Haz varias autenticaciones fallidas en Authelia hasta superar `maxretry` y luego revisa:

```bash
sudo fail2ban-client status authelia
sudo iptables -L DOCKER-USER -n --line-numbers
```

Si necesitas levantar manualmente un ban durante pruebas:

```bash
sudo fail2ban-client set authelia unbanip <ip>
```

Y cuando Vaultwarden esté operativo:

```bash
sudo fail2ban-client set vaultwarden unbanip <ip>
sudo fail2ban-client set vaultwarden-admin unbanip <ip>
```

### 11. Rotación mínima de logs

Como en esta guía los logs quedan persistidos en el **SSD NVMe**, conviene rotarlos para no acumular ficheros indefinidamente.

Crea este fichero:

```bash
sudo nano /etc/logrotate.d/homelab-service-logs
```

Contenido recomendado:

```conf
/home/<user>/homelab/data/authelia/authelia.log
/home/<user>/homelab/data/vaultwarden/vaultwarden.log {
    weekly
    rotate 8
    compress
    missingok
    notifempty
    copytruncate
}
```

Comprueba la sintaxis:

```bash
sudo logrotate -d /etc/logrotate.d/homelab-service-logs
```

### 12. Qué revisar si algo no funciona

Los fallos más habituales en esta fase suelen ser estos:

- el log del servicio no existe porque el contenedor sigue escribiendo solo a `stdout`
- la IP registrada en el log es `127.0.0.1` o una IP de Docker, así que Fail2ban termina baneando la dirección equivocada
- el jail apunta a una ruta distinta de la ruta real del log
- `DOCKER-USER` no existe todavía porque Docker no estaba arrancado al validar
- Caddy está atendiendo `80/443`, pero el backend no recibe la IP real del cliente por falta de cabeceras como `X-Real-IP` o por una topología distinta de la arquitectura base del proyecto
- el filtro regex no coincide con el formato real del log en tu versión del servicio

Regla práctica: primero valida el **log**, luego el **filtro**, después el **jail** y solo al final el **ban**.

## Almacenamiento

Esta fase usa dos zonas de almacenamiento, ambas en el **SSD NVMe**:

- configuración de Fail2ban en el host:
  - `/etc/fail2ban/filter.d/authelia.local`
  - `/etc/fail2ban/filter.d/vaultwarden.local`
  - `/etc/fail2ban/filter.d/vaultwarden-admin.local`
  - `/etc/fail2ban/jail.d/20-homelab-services.local`
  - `/var/lib/fail2ban/`
- logs persistentes de servicios:
  - `/home/<user>/homelab/data/authelia/authelia.log`
  - `/home/<user>/homelab/data/vaultwarden/vaultwarden.log`
- rotación de logs:
  - `/etc/logrotate.d/homelab-service-logs`

No guardes ni estos filtros ni los logs activos en `hd2t` o `hd5t`. Esos discos no son el lugar correcto para el estado operativo de seguridad.

## Backup

Para reconstruir esta capa sin improvisar, respalda como mínimo:

- `/etc/fail2ban/filter.d/authelia.local`
- `/etc/fail2ban/filter.d/vaultwarden.local`
- `/etc/fail2ban/filter.d/vaultwarden-admin.local`
- `/etc/fail2ban/jail.d/20-homelab-services.local`
- `/etc/logrotate.d/homelab-service-logs`
- `/home/<user>/homelab/config/authelia/configuration.yml`
- el `docker-compose.yml` o `.env` donde definas `LOG_FILE` para Vaultwarden

No es necesario respaldar el estado temporal de bans ni los logs completos para poder restaurar el sistema. Lo importante es conservar la configuración reproducible.

## Referencias

- [03-seguridad-base.md](../01-sistema/03-seguridad-base.md)
- [05-caddy.md](../03-red/05-caddy.md)
- [01-authelia.md](01-authelia.md)
- [01-vaultwarden.md](../11-productividad/01-vaultwarden.md)
- [Fail2ban](https://www.fail2ban.org/wiki/index.php/Main_Page)
- [Authelia Docs: Security Measures](https://www.authelia.com/configuration/security/regulation/)
- [Authelia Docs: Log Configuration](https://www.authelia.com/configuration/miscellaneous/logging/)
- [Vaultwarden Wiki: Logging](https://github.com/dani-garcia/vaultwarden/wiki/Enabling-logging)
- [Vaultwarden Wiki: Fail2Ban Setup](https://github.com/dani-garcia/vaultwarden/wiki/Fail2Ban-Setup)
