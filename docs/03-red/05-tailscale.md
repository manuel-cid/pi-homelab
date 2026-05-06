# Tailscale

## Descripción
Tailscale será la **capa de acceso remoto seguro** del homelab. En este proyecto no se abren puertos en el router, no se expone nada a internet y no se usa DDNS: el acceso remoto ocurre únicamente a través de la **tailnet** de Tailscale.

En esta arquitectura Tailscale cumple cuatro funciones:

- dar acceso remoto a la Raspberry Pi y a los servicios internos sin exponer puertos públicos
- proporcionar **MagicDNS** para resolver el nombre del nodo dentro de la tailnet
- permitir emitir certificados para el FQDN `*.ts.net` del nodo con `tailscale cert`
- encajar con `docs/03-red/04-caddy.md`, donde **Caddy** publica los servicios web internos detrás de la IP principal del host

La topología objetivo queda así:

```text
cliente remoto con Tailscale
          |
          v
https://pi.tailnet.ts.net
          |
          v
Tailscale llega al host por la tailnet
          |
          v
Caddy (host: 80/443)
          |
          v
servicio interno del homelab
```

Siguiendo el contrato de red definido en los documentos anteriores, esta guía usa como ejemplo:

- IP LAN principal de la Raspberry Pi: `192.168.1.10`
- nombre corto del nodo Tailscale: `pi`
- FQDN MagicDNS del nodo: `pi.tailnet.ts.net`
- ruta remota de ejemplo detrás de Caddy: `https://pi.tailnet.ts.net/jellyfin/`

Sustituye esos valores por los reales de tu red si usas otro nombre de nodo o una tailnet con otro sufijo `*.ts.net`.

## Requisitos Previos
- Haber completado `docs/03-red/04-caddy.md`.
- Tener la Raspberry Pi con salida a internet para que el cliente Tailscale pueda autenticarse y mantener la conexión con la tailnet.
- Tener acceso a la consola de administración de Tailscale.
- Poder usar `sudo` en el host.
- Tener claro que en este proyecto la opción **recomendada** es instalar Tailscale en el **host**, no delante de cada servicio individual.
- Si quieres usar la alternativa en contenedor:
  - tener Docker Engine operativo
  - disponer de una auth key de Tailscale
  - tener disponible `/dev/net/tun` en el host
- Puertos implicados:
  - **no se abre ningún puerto entrante en el router**
  - el host debe poder iniciar tráfico saliente hacia internet para que Tailscale funcione
  - para el acceso remoto a los servicios web, Caddy seguirá usando `80/tcp` y `443/tcp` en la IP principal del host

## Docker Compose
En este homelab la opción recomendada es **instalar Tailscale en el host** porque encaja mejor con el diseño del documento anterior:

- Caddy sigue escuchando en la IP principal de la Raspberry Pi
- `tailscale cert` se ejecuta directamente en el host
- no hace falta mover servicios a `network_mode: service:tailscale`

Aun así, para cumplir la convención de esta fase, a continuación se deja una **alternativa funcional en contenedor** basada en la topología oficial de Tailscale para Docker Compose. Es útil para pruebas o para servicios que quieras publicar solo dentro de la tailnet, pero **no es la ruta principal recomendada para este proyecto**.

Directorio recomendado para la alternativa en contenedor:

```text
/home/<usuario>/homelab/compose/tailscale/
├── compose.yaml
├── .env
└── state/
```

Fichero `.env` de ejemplo:

```dotenv
TZ=Europe/Madrid
TS_HOSTNAME=pi-docker
TS_AUTHKEY=tskey-client-no-reutilizar
```

Fichero `compose.yaml`:

```yaml
name: tailscale

services:
  tailscale:
    container_name: tailscale
    image: tailscale/tailscale:latest
    hostname: ${TS_HOSTNAME}
    restart: unless-stopped
    env_file:
      - .env
    environment:
      TZ: ${TZ}
      TS_AUTHKEY: ${TS_AUTHKEY}
      TS_STATE_DIR: /var/lib/tailscale
      TS_USERSPACE: "false"
      TS_EXTRA_ARGS: --advertise-tags=tag:container
    volumes:
      - ./state:/var/lib/tailscale
    devices:
      - /dev/net/tun:/dev/net/tun
    cap_add:
      - NET_ADMIN
      - NET_RAW

  whoami:
    container_name: tailscale-whoami
    image: traefik/whoami:latest
    restart: unless-stopped
    depends_on:
      - tailscale
    network_mode: service:tailscale
```

Despliegue de la alternativa en contenedor:

```bash
mkdir -p /home/<usuario>/homelab/compose/tailscale/state
cd /home/<usuario>/homelab/compose/tailscale
docker compose config
docker compose pull
docker compose up -d
docker compose ps
```

Resultado esperado de esta alternativa:

- aparece un nuevo nodo en la tailnet con el nombre `pi-docker` o el que definas en `TS_HOSTNAME`
- desde otro cliente Tailscale puedes abrir `http://pi-docker`
- el estado del cliente queda persistido en `./state`

## Configuración

### Objetivo final de esta guía

| Elemento | Estado esperado |
|---|---|
| Instalación recomendada | Tailscale en el host |
| Resolución remota | MagicDNS activo |
| FQDN remoto del nodo | `pi.tailnet.ts.net` |
| Certificados HTTPS remotos | `tailscale cert` |
| Punto de entrada remoto | Caddy en la IP principal del host |
| Exposición a internet | ninguna |
| Acceso remoto esperado | `https://pi.tailnet.ts.net/<servicio>/` |

### 1. Elegir la topología correcta para este homelab

Para este proyecto la recomendación es clara:

- **host** para la Raspberry Pi principal
- **contenedor** solo como alternativa puntual o para casos de laboratorio

La razón es operativa:

- el reverse proxy ya está definido en `docs/03-red/04-caddy.md`
- Caddy escucha en la IP LAN principal del host
- los certificados `tailscale cert` deben quedar disponibles en el host para montarlos en Caddy
- no hace falta publicar subredes enteras ni meter Pi-hole o Caddy dentro del namespace de red de un contenedor Tailscale

Diseño recomendado para el estado final:

```text
Tailscale en el host
        +
Caddy en Docker sobre la IP LAN principal del host
        +
servicios internos detrás de Caddy
```

### 2. Instalar Tailscale en el host

En Raspberry Pi OS y otras distribuciones Linux principales, la instalación más simple es:

```bash
curl -fsSL https://tailscale.com/install.sh | sh
```

Después, levantar el cliente:

```bash
sudo tailscale up
```

Si quieres mantener el DNS del host bajo tu control local y no dejar que Tailscale cambie la resolución del sistema, puedes usar:

```bash
sudo tailscale up --accept-dns=false
```

En este homelab esa variante suele ser la más cómoda porque:

- Pi-hole sigue siendo el DNS principal de la LAN
- el host ya tiene su propia estrategia de fallback DNS en `docs/03-red/02-pihole.md`
- MagicDNS sigue siendo útil para los **clientes remotos** conectados a Tailscale aunque el host no acepte la configuración DNS de la tailnet

Si más adelante solo quieres ajustar este comportamiento DNS sin reintroducir otros flags de alta, usa:

```bash
sudo tailscale set --accept-dns=false
```

Validación inicial:

```bash
tailscale version
tailscale ip
tailscale status
```

Debes comprobar:

- que el nodo obtiene una IP Tailscale
- que aparece como conectado en `tailscale status`
- que también aparece en la consola web de Tailscale

### 3. Fijar el nombre del nodo pensando en MagicDNS

MagicDNS usa el nombre de la máquina como parte del nombre DNS del nodo. Para este homelab conviene usar un nombre corto y estable, por ejemplo `pi`.

Antes de emitir certificados o documentar URLs remotas:

- evita nombres con información sensible
- evita nombres ambiguos como `raspberrypi` si puedes tener varios nodos en el futuro
- decide un nombre estable antes de integrarlo con Caddy y con tus marcadores del navegador

Objetivo recomendado:

- nombre corto del nodo: `pi`
- FQDN MagicDNS: `pi.tailnet.ts.net`

Si cambias el nombre del nodo después, cambiará también el nombre MagicDNS que usarás para acceso remoto.

### 4. Activar MagicDNS y HTTPS en la consola de Tailscale

En la consola de administración de Tailscale:

1. Abre la sección DNS.
2. Confirma que **MagicDNS** está activado.
3. Activa también **HTTPS certificates**.
4. Acepta la advertencia de publicación en Certificate Transparency.

Puntos importantes de esta decisión:

- en las tailnets modernas MagicDNS suele venir activado por defecto
- los certificados HTTPS dependen de que MagicDNS esté activo
- al usar `tailscale cert`, el FQDN del nodo queda publicado en los logs públicos de Certificate Transparency

Por eso, antes de seguir:

- revisa que el nombre del nodo no incluya datos sensibles
- confirma cuál es el sufijo real de tu tailnet, por ejemplo `tailnet.ts.net` o un nombre aleatorio como `yak-bebop.ts.net`

### 5. Integrar Tailscale con el diseño remoto de Caddy

Con Tailscale operativo en el host, el acceso remoto de este homelab no necesita rutas de subred ni acceso directo a las IP privadas de la LAN. El flujo recomendado es:

1. el cliente remoto se conecta a Tailscale
2. abre `https://pi.tailnet.ts.net`
3. Caddy recibe la petición en el host
4. Caddy reenvía la petición al servicio interno correspondiente

Ejemplos de rutas remotas alineadas con `docs/03-red/04-caddy.md`:

- `https://pi.tailnet.ts.net/jellyfin/`
- `https://pi.tailnet.ts.net/navidrome/`
- `https://pi.tailnet.ts.net/audiobookshelf/`
- `https://pi.tailnet.ts.net/calibre/`
- `https://pi.tailnet.ts.net/stash/`

Ventajas de este enfoque:

- una sola entrada remota para todo el homelab
- no hace falta abrir puertos en el router
- no dependes de reachability directa a `192.168.1.0/24` desde cada cliente remoto
- la topología sigue siendo coherente con Pi-hole, Unbound y Caddy

### 6. Emitir el certificado para el FQDN del nodo

Crear primero el directorio persistente para los certificados:

```bash
sudo mkdir -p /home/<usuario>/homelab/secrets/tailscale-certs
sudo chown root:root /home/<usuario>/homelab/secrets/tailscale-certs
sudo chmod 700 /home/<usuario>/homelab/secrets/tailscale-certs
```

Emitir el certificado y la clave:

```bash
sudo tailscale cert \
  --cert-file /home/<usuario>/homelab/secrets/tailscale-certs/pi.tailnet.ts.net.crt \
  --key-file /home/<usuario>/homelab/secrets/tailscale-certs/pi.tailnet.ts.net.key \
  pi.tailnet.ts.net
```

Después:

- confirma que el nombre usado coincide exactamente con el FQDN MagicDNS del nodo
- revisa que los ficheros existen en la ruta esperada
- recrea o recarga Caddy para que tome el certificado

Validación rápida:

```bash
sudo ls -l /home/<usuario>/homelab/secrets/tailscale-certs
```

### 7. Automatizar la renovación del certificado

Los certificados emitidos con `tailscale cert` no se renuevan solos cuando los guardas como ficheros en disco. En este homelab conviene automatizar la renovación y recargar Caddy después.

Crear `/usr/local/sbin/renew-tailscale-cert.sh`:

```bash
#!/bin/sh
set -eu

FQDN="pi.tailnet.ts.net"
CERT_DIR="/home/<usuario>/homelab/secrets/tailscale-certs"

/usr/bin/tailscale cert \
  --cert-file "${CERT_DIR}/${FQDN}.crt" \
  --key-file "${CERT_DIR}/${FQDN}.key" \
  "${FQDN}"

/usr/bin/docker exec caddy caddy reload --config /etc/caddy/Caddyfile
```

Permisos:

```bash
sudo chown root:root /usr/local/sbin/renew-tailscale-cert.sh
sudo chmod 0750 /usr/local/sbin/renew-tailscale-cert.sh
```

Crear `/etc/systemd/system/tailscale-cert-renew.service`:

```ini
[Unit]
Description=Renovar certificado HTTPS de Tailscale para Caddy
After=network-online.target docker.service tailscaled.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/renew-tailscale-cert.sh
```

Crear `/etc/systemd/system/tailscale-cert-renew.timer`:

```ini
[Unit]
Description=Temporizador de renovación del certificado HTTPS de Tailscale

[Timer]
OnCalendar=weekly
Persistent=true
RandomizedDelaySec=1h

[Install]
WantedBy=timers.target
```

Activar el temporizador:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now tailscale-cert-renew.timer
sudo systemctl list-timers tailscale-cert-renew.timer
```

Recomendación práctica:

- ejecuta también el servicio manualmente tras el primer despliegue
- usa un nombre de FQDN estable
- recuerda que `tailscale cert` solo funciona con el cliente Tailscale del host; si eliges la alternativa en contenedor para laboratorio, no sustituye esta parte del diseño recomendado
- si cambias el nombre del nodo en Tailscale, actualiza este script y el `Caddyfile`

Prueba manual inicial:

```bash
sudo systemctl start tailscale-cert-renew.service
sudo systemctl status tailscale-cert-renew.service
```

### 8. Probar el acceso remoto real

Desde un portátil o móvil conectado a la misma tailnet:

```text
https://pi.tailnet.ts.net/
https://pi.tailnet.ts.net/jellyfin/
https://pi.tailnet.ts.net/navidrome/
```

Comprobaciones mínimas:

- la conexión debe funcionar sin abrir puertos en el router
- el certificado debe ser válido para `pi.tailnet.ts.net`
- la petición debe terminar en Caddy y después en el backend correcto

Comandos útiles de diagnóstico en la Raspberry Pi:

```bash
tailscale status
tailscale ip
docker compose -f /home/<usuario>/homelab/compose/caddy/compose.yaml logs --tail=100 caddy
```

Síntomas comunes:

- `tailscale status` muestra el nodo sin conexión:
  - revisa autenticación, salida a internet y reloj del sistema
- `https://pi.tailnet.ts.net` no responde pero la LAN sí:
  - suele indicar problema de Tailscale, MagicDNS o certificado, no de Pi-hole
- el navegador da error de nombre:
  - el certificado se emitió para un FQDN distinto del que estás usando
- `docker exec caddy ...` falla en el script de renovación:
  - revisa que el contenedor realmente se llame `caddy`

### 9. Ajustes operativos recomendados

Buenas prácticas para este homelab:

- instalar Tailscale en el host principal y no dispersarlo por cada contenedor
- no anunciar subredes LAN si solo necesitas acceso remoto a servicios publicados detrás de Caddy
- desactivar el cambio automático de DNS en el host si quieres mantener el control local con Pi-hole
- desactivar la expiración de clave del nodo solo si entiendes la implicación y el equipo es de confianza
- mantener documentados el nombre corto del nodo, el FQDN MagicDNS y la ruta real de los certificados

## Almacenamiento
En la ruta recomendada de este proyecto, Tailscale instalado en el host apenas necesita almacenamiento de datos de aplicación, pero sí conviene persistir los elementos operativos asociados a su integración con el homelab.

Rutas recomendadas reales en el NVMe:

```text
/home/<usuario>/homelab/secrets/tailscale-certs/
/home/<usuario>/homelab/compose/tailscale/            # solo si usas la alternativa en contenedor
```

Qué queda guardado ahí:

- certificados y clave privada emitidos con `tailscale cert`
- estado persistente del contenedor Tailscale si usas la alternativa Docker
- configuración declarativa del stack Compose alternativo

En este proyecto Tailscale debe apoyarse en el **SSD NVMe**, no en los discos USB:

- forma parte de la infraestructura base de acceso remoto
- los certificados y el estado del cliente deben estar siempre disponibles
- no depende del almacenamiento multimedia de `hd2t` ni de `hd5t`

## Backup
Respaldar como mínimo:

- la ruta `/home/<usuario>/homelab/secrets/tailscale-certs/`
- el script `/usr/local/sbin/renew-tailscale-cert.sh`
- los ficheros `tailscale-cert-renew.service` y `tailscale-cert-renew.timer`
- el directorio `/home/<usuario>/homelab/compose/tailscale/` si usas la alternativa en contenedor

Elementos críticos del backup:

- certificado y clave privada del FQDN `*.ts.net`
- automatización de renovación
- nombre del nodo y FQDN documentados
- estado persistente del contenedor Tailscale si esa es tu opción

Antes de una restauración importante conviene:

- confirmar que el nodo sigue autorizado en la consola de Tailscale
- verificar si el nombre MagicDNS del nodo ha cambiado
- reemitir el certificado si hay dudas sobre su vigencia o su correspondencia con el FQDN actual

Si restauras desde cero el host principal, el orden lógico es:

1. reinstalar y autenticar Tailscale
2. confirmar el nombre MagicDNS del nodo
3. restaurar o reemitir el certificado en `/home/<usuario>/homelab/secrets/tailscale-certs/`
4. restaurar el script y el temporizador de renovación
5. levantar o recargar Caddy
6. probar `https://pi.tailnet.ts.net`

## Referencias
- Documentación oficial de instalación en Linux: <https://tailscale.com/docs/install/linux>
- Descarga oficial de Tailscale para Linux: <https://tailscale.com/download/linux>
- MagicDNS: <https://tailscale.com/docs/features/magicdns>
- Certificados HTTPS y `tailscale cert`: <https://tailscale.com/docs/how-to/set-up-https-certificates>
- Puertos y conectividad de red de Tailscale: <https://tailscale.com/docs/reference/faq/firewall-ports>
- Docker en Tailscale: <https://tailscale.com/docs/features/containers/docker>
- Ejemplo oficial con Docker Compose: <https://tailscale.com/docs/features/containers/docker/how-to/connect-docker-container>
- Parámetros de configuración del contenedor Docker: <https://tailscale.com/docs/features/containers/docker/docker-params>
