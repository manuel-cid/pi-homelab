# Pi-hole

## Descripción
Pi-hole será el **DNS principal de la LAN** del homelab. En esta fase se despliega en la red Docker `homelab_macvlan` con una **IP propia dentro de la red local** para no ocupar en la IP principal de la Raspberry Pi los puertos `53/tcp`, `53/udp` y `80/tcp`.

En este proyecto Pi-hole cumple cuatro funciones:

- filtrar publicidad, telemetría y dominios no deseados a nivel de red
- centralizar la resolución DNS de los clientes de la LAN
- resolver nombres internos del homelab como `jellyfin.lan`
- quedar preparado para usar **Unbound** como upstream recursivo en `docs/03-red/03-unbound.md`

Siguiendo el contrato de red definido en `docs/03-red/01-macvlan.md`, este documento usa como ejemplo:

- Pi-hole: `192.168.1.241`
- Unbound: `192.168.1.242`
- IP `macvlan-shim` del host: `192.168.1.248`
- IP LAN principal del host: `192.168.1.10`
- router/gateway: `192.168.1.1`

Sustituye esos valores por los reales de tu red si usas otra numeración.

## Requisitos Previos
- Haber completado `docs/03-red/01-macvlan.md`.
- Haber completado `docs/02-docker/01-instalacion-docker.md`.
- Haber completado `docs/02-docker/02-estructura-compose.md`.
- Tener creada la red Docker externa `homelab_macvlan`.
- Tener reservada en el router la IP dedicada que usará Pi-hole.
- Tener operativa la interfaz `macvlan-shim` en el host para poder probar Pi-hole desde la propia Raspberry Pi.
- Tener claro que el DHCP sigue en el router; en esta guía **Pi-hole no actúa como servidor DHCP**.
- Poder cambiar la configuración DHCP/DNS del router.
- Puertos implicados:
  - `53/tcp` y `53/udp` en la IP dedicada de Pi-hole
  - `80/tcp` en la IP dedicada de Pi-hole para la interfaz web
  - no se publica ningún puerto nuevo en la IP principal del host

## Docker Compose
Directorio recomendado:

```text
/home/<usuario>/homelab/compose/pihole/
├── compose.yaml
├── .env
└── etc-pihole/
```

Fichero `.env` de ejemplo:

```dotenv
TZ=Europe/Madrid
PIHOLE_IP=192.168.1.241
PIHOLE_WEBPASSWORD=cambia-esta-clave
PIHOLE_UPSTREAM_DNS=192.168.1.1
HOST_LAN_IP=192.168.1.10
```

Notas sobre estas variables:

- `PIHOLE_UPSTREAM_DNS=192.168.1.1` permite arrancar Pi-hole antes de desplegar Unbound.
- Cuando completes `docs/03-red/03-unbound.md`, cambia ese valor a `192.168.1.242#5335`.
- `HOST_LAN_IP` debe ser la IP principal de la Raspberry Pi en la LAN, no la IP macvlan de Pi-hole.

Fichero `compose.yaml`:

```yaml
name: pihole

services:
  pihole:
    container_name: pihole
    image: pihole/pihole:latest
    hostname: pihole
    restart: unless-stopped
    env_file:
      - .env
    environment:
      TZ: ${TZ}
      FTLCONF_webserver_api_password: ${PIHOLE_WEBPASSWORD}
      FTLCONF_dns_listeningMode: 'LOCAL'
      FTLCONF_dns_upstreams: ${PIHOLE_UPSTREAM_DNS}
      FTLCONF_dns_domain_name: 'lan'
      FTLCONF_dns_domain_local: 'true'
      FTLCONF_dns_blocking_mode: 'NULL'
      FTLCONF_dns_hosts: |-
        ${HOST_LAN_IP} homelab homelab.lan
        ${HOST_LAN_IP} jellyfin jellyfin.lan
        ${HOST_LAN_IP} navidrome navidrome.lan
        ${HOST_LAN_IP} audiobookshelf audiobookshelf.lan
        ${HOST_LAN_IP} calibre calibre.lan
        ${HOST_LAN_IP} stash stash.lan
    volumes:
      - ./etc-pihole:/etc/pihole
    networks:
      homelab_macvlan:
        ipv4_address: ${PIHOLE_IP}

networks:
  homelab_macvlan:
    external: true
    name: homelab_macvlan
```

Notas importantes sobre este stack:

- No hace falta `ports:` porque Pi-hole escucha directamente en su IP macvlan dedicada.
- No hace falta `NET_ADMIN` porque en este diseño Pi-hole **no** va a dar DHCP.
- `FTLCONF_dns_hosts` permite dejar los nombres locales básicos versionados en git junto al stack.
- El estado persistente de Pi-hole queda en `./etc-pihole`, donde se guardan la base de datos de gravedad, allowlists, denylists y configuración.

Despliegue:

```bash
mkdir -p /home/<usuario>/homelab/compose/pihole/etc-pihole
cd /home/<usuario>/homelab/compose/pihole
docker compose config
docker compose pull
docker compose up -d
docker compose ps
```

Resultado esperado:

- el contenedor responde en `http://192.168.1.241/admin/`
- Pi-hole resuelve dominios externos usando el upstream configurado
- los nombres definidos en `FTLCONF_dns_hosts` responden dentro de la LAN
- la IP principal del host queda libre para Caddy y otros servicios

## Configuración

### Objetivo final de esta guía

| Elemento | Estado esperado |
|---|---|
| IP de Pi-hole | `192.168.1.241` |
| Red Docker | `homelab_macvlan` |
| DNS anunciado por DHCP | `192.168.1.241` |
| Dominio local | `lan` |
| UI web | `http://192.168.1.241/admin/` |
| Upstream inicial | router o DNS temporal |
| Upstream final recomendado | Unbound en `192.168.1.242#5335` |
| DNS fallback del host | Pi-hole primero, router después |

### 1. Verificar que Pi-hole responde en la LAN

Desde otro equipo de la red:

```bash
nslookup pi.hole 192.168.1.241
nslookup jellyfin.lan 192.168.1.241
```

Desde la Raspberry Pi, si `macvlan-shim` ya está operativa:

```bash
dig @192.168.1.241 pi.hole
dig @192.168.1.241 jellyfin.lan
dig @192.168.1.241 github.com
```

Debe ocurrir lo siguiente:

- `pi.hole` responde con la IP de Pi-hole
- `jellyfin.lan` responde con la IP LAN principal del host
- `github.com` responde usando el upstream configurado

Si esto falla:

- revisa que la red `homelab_macvlan` exista
- revisa que la IP `192.168.1.241` no esté en uso
- confirma que el router no entregue esa IP por DHCP
- comprueba que `macvlan-shim` siga levantada en el host

### 2. Acceder a la interfaz web

Abre:

```text
http://192.168.1.241/admin/
```

Usa la contraseña definida en `PIHOLE_WEBPASSWORD`.

Comprobaciones iniciales recomendadas:

- revisar que el dashboard muestre consultas DNS entrantes
- confirmar que el upstream activo coincide con `FTLCONF_dns_upstreams`
- validar que la zona horaria es correcta
- ejecutar una actualización de gravedad si la interfaz la solicita

### 3. Configurar el router para usar Pi-hole como DNS

El router debe seguir entregando IPs por DHCP, pero debe anunciar **Pi-hole como DNS de la LAN**.

Configuración objetivo:

- DHCP activado en el router
- DNS primario LAN: `192.168.1.241`
- DNS secundario LAN: vacío, o un segundo Pi-hole si algún día montas alta disponibilidad

Recomendaciones prácticas:

- no configures un DNS secundario público en el router
- si el firmware del router obliga a rellenar dos campos, intenta dejar vacío el segundo
- si el router no lo permite, documenta el comportamiento porque muchos clientes consultarán ambos DNS en paralelo y parte del tráfico saltará el filtrado

Después del cambio:

- renueva la concesión DHCP en los clientes
- o reconecta los equipos a la red
- comprueba en cada cliente que el DNS recibido es `192.168.1.241`

### 4. Resolver nombres internos del homelab

En este proyecto los nombres como `jellyfin.lan`, `navidrome.lan` o `audiobookshelf.lan` deben apuntar a la **IP LAN principal del host**, no a las IP privadas de los contenedores.

La razón es:

- Pi-hole solo resuelve el nombre
- Caddy será el punto de entrada HTTPS interno en la IP del host
- el reverse proxy decidirá después a qué contenedor enviar cada petición

Por eso el ejemplo del `compose.yaml` usa:

```text
192.168.1.10 homelab homelab.lan
192.168.1.10 jellyfin jellyfin.lan
192.168.1.10 navidrome navidrome.lan
192.168.1.10 audiobookshelf audiobookshelf.lan
192.168.1.10 calibre calibre.lan
192.168.1.10 stash stash.lan
```

Si prefieres gestionar los registros desde la interfaz web en vez de hacerlo por variable de entorno:

- ve a `Local DNS` en la administración de Pi-hole
- crea un registro por hostname apuntando siempre a la IP LAN principal del host
- evita mezclar durante mucho tiempo configuración por UI y por `FTLCONF_dns_hosts`, porque complica saber cuál es la fuente de verdad

Si cambia la IP LAN principal del host:

```bash
cd /home/<usuario>/homelab/compose/pihole
docker compose up -d
```

Antes de relanzar el stack, actualiza `HOST_LAN_IP` en `.env`.

### 5. Listas de bloqueo recomendadas

Para este homelab conviene empezar con una política conservadora y fácil de mantener.

Conjunto recomendado:

- mantener activada la lista por defecto de Pi-hole como base inicial
- añadir como mucho **una** lista generalista adicional bien mantenida si necesitas más cobertura
- gestionar excepciones mediante la allowlist local de Pi-hole en lugar de desactivar el filtrado global

Estrategia operativa recomendada:

1. Arranca solo con la configuración por defecto.
2. Espera varios días y revisa falsos positivos en navegación, smart TV, móviles y servicios multimedia.
3. Si necesitas endurecer el filtrado, añade una lista adicional cada vez.
4. Después de cada cambio, actualiza la gravedad y prueba las aplicaciones críticas del homelab.

Recomendación práctica:

- si quieres una segunda lista sencilla de mantener, `OISD` suele ser la opción más razonable frente a acumular muchas listas solapadas

Evita al principio:

- importar muchas listas agresivas a la vez
- mezclar listas abandonadas o muy solapadas
- asumir que más dominios bloqueados implica mejor resultado

### 6. Preparar el cambio futuro a Unbound

Cuando completes `docs/03-red/03-unbound.md`, cambia el upstream de Pi-hole para que deje de depender del router o de un DNS temporal.

Valor esperado en `.env`:

```dotenv
PIHOLE_UPSTREAM_DNS=192.168.1.242#5335
```

Aplicar el cambio:

```bash
cd /home/<usuario>/homelab/compose/pihole
docker compose up -d
docker exec pihole pihole-FTL --config dns.upstreams
```

El valor esperado debe apuntar a `192.168.1.242#5335`.

### 7. Configurar un DNS fallback en el host

La Raspberry Pi no debería depender exclusivamente de Pi-hole para resolver nombres. Si Pi-hole cae durante un reinicio, una actualización o una restauración, el propio host puede quedarse sin resolución DNS y complicar el diagnóstico.

Configuración mínima deseada en el host:

```text
nameserver 192.168.1.241
nameserver 192.168.1.1
search lan
options timeout:1 attempts:2
```

Ejemplo directo sobre `/etc/resolv.conf`:

```bash
sudo cp /etc/resolv.conf /etc/resolv.conf.bak
sudo tee /etc/resolv.conf >/dev/null <<'EOF'
nameserver 192.168.1.241
nameserver 192.168.1.1
search lan
options timeout:1 attempts:2
EOF
```

Importante:

- en algunos sistemas `/etc/resolv.conf` está gestionado automáticamente
- si el cambio se pierde tras reiniciar, persístelo en el gestor de red del host
- el objetivo es que **solo el host** tenga una salida de emergencia, no que los clientes salten Pi-hole

### 8. Troubleshooting básico

Comprobar el estado del stack:

```bash
cd /home/<usuario>/homelab/compose/pihole
docker compose config
docker compose ps
docker compose logs --tail=100 pihole
```

Pruebas útiles:

```bash
dig @192.168.1.241 github.com
dig @192.168.1.241 jellyfin.lan
docker exec pihole pihole-FTL --config dns.upstreams
```

Síntomas comunes:

- resuelve nombres locales pero no externos:
  - suele indicar problema con el upstream configurado
- otros equipos de la LAN resuelven pero el host no:
  - suele indicar que `macvlan-shim` o la ruta del host no están bien configuradas
- el dashboard carga pero no hay estadísticas:
  - revisa los logs del contenedor y el estado del volumen `./etc-pihole`
- algunos clientes siguen saltándose Pi-hole:
  - revisa qué DNS han recibido realmente por DHCP
  - comprueba si el router está anunciando un DNS secundario adicional

## Almacenamiento
Pi-hole debe vivir íntegramente en el **SSD NVMe principal**, no en `hd2t` ni en `hd5t`.

Rutas recomendadas:

- stack: `/home/<usuario>/homelab/compose/pihole/`
- datos persistentes: `/home/<usuario>/homelab/compose/pihole/etc-pihole/`

Qué queda almacenado en `etc-pihole`:

- base de datos de gravedad
- allowlists y denylists
- configuración persistente de Pi-hole
- estado histórico y parte de las estadísticas

Permisos:

- el directorio debe ser escribible por Docker
- no hace falta montar discos externos para este servicio
- conviene restringir lectura de `.env` porque contiene la contraseña de la UI

## Backup
Respaldar como mínimo:

- `/home/<usuario>/homelab/compose/pihole/compose.yaml`
- `/home/<usuario>/homelab/compose/pihole/.env`
- `/home/<usuario>/homelab/compose/pihole/etc-pihole/`
- export opcional de listas o ajustes si haces cambios manuales desde la UI

Estrategia recomendada:

- incluir este stack en el backup regular hacia `hd2t`
- hacer una copia antes de cambios grandes de upstream, adlists o restauraciones
- si restauras en otra Raspberry Pi, revisar primero la IP macvlan, la IP LAN del host y la contraseña antes de levantar el stack

## Referencias
- Documentación oficial de Pi-hole: `https://docs.pi-hole.net/`
- Pi-hole en Docker: `https://docs.pi-hole.net/docker/`
- Configuración de FTL y variables `FTLCONF_*`: `https://docs.pi-hole.net/ftldns/configfile/`
- Imagen Docker oficial: `https://hub.docker.com/r/pihole/pihole`
- OISD para Pi-hole: `https://oisd.nl/setup/pihole`
