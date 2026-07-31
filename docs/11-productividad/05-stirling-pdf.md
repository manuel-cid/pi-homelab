# Stirling PDF

## Descripción

**Stirling PDF** es la caja de herramientas PDF de este homelab: permite unir, dividir, rotar, comprimir, convertir y reorganizar documentos desde una interfaz web sencilla, sin depender de servicios externos.

En esta Raspberry Pi 5 conviene tratarlo como un servicio **stateless** y de uso puntual:

- la aplicación vive en `/home/<user>/homelab/compose/productivity-stirling-pdf/`
- el servicio se publica en `16004/tcp` para acceso desde **LAN** y **Tailscale**
- no se usan bind mounts ni volúmenes persistentes
- no se guardan trabajos, configuraciones ni base de datos entre recreaciones del contenedor
- `hd2t` y `hd5t` no participan en este servicio

Para este proyecto esa topología es la más coherente: despliegue muy simple, sin estado que respaldar y sin riesgo de mezclar documentación temporal con el almacenamiento persistente del resto del homelab.

Como norma general, los servicios web del homelab deberían entrar por [05-caddy.md](../03-red/05-caddy.md); aquí se documenta `16004/tcp` como una **excepción operativa consciente** para usar Stirling PDF de forma directa y puntual desde **LAN** o **Tailscale**, sin exponerlo a internet.

## Requisitos Previos

- Haber completado [02-estructura-compose.md](../02-docker/02-estructura-compose.md).
- Haber completado [04-tailscale.md](../03-red/04-tailscale.md) si quieres usar Stirling PDF también fuera de casa a través de la tailnet.
- Revisar [06-puertos-y-firewall.md](../03-red/06-puertos-y-firewall.md) para mantener documentado el puerto del servicio.
- Tener claro que este despliegue queda **sin autenticación local persistente** y solo tiene sentido porque el alcance de red del homelab es **LAN + Tailscale**, sin exposición pública a internet.
- Sustituir antes de desplegar los placeholders de esta guía, especialmente `<user>`, `<ip-lan-de-la-pi>`, `<hostname-de-tu-pi>`, `<tailnet>` y `<subred-lan-cidr>`.
- Puertos necesarios en esta fase:
  - **`16004/tcp` publicado en el host** para acceso web desde LAN y Tailscale
  - **`8080/tcp`** es el puerto interno del contenedor

## Docker Compose

Archivo: `/home/<user>/homelab/compose/productivity-stirling-pdf/docker-compose.yml`

```yaml
name: productivity-stirling-pdf

services:
  stirling-pdf:
    image: stirlingtools/stirling-pdf:2.14.2
    restart: unless-stopped
    env_file:
      - .env
    environment:
      TZ: ${TZ}
      LANGS: ${STIRLING_LANGS}
      SECURITY_ENABLELOGIN: ${STIRLING_ENABLE_LOGIN}
      DISABLE_ADDITIONAL_FEATURES: ${STIRLING_DISABLE_ADDITIONAL_FEATURES}
    ports:
      - "${STIRLING_BIND_IP}:${STIRLING_PORT}:8080"
    tmpfs:
      - /tmp
      - /configs
      - /logs
      - /pipeline
    labels:
      - wud.watch=true
```

Archivo recomendado: `/home/<user>/homelab/compose/productivity-stirling-pdf/.env`

```dotenv
TZ=Europe/Madrid
STIRLING_BIND_IP=0.0.0.0
STIRLING_PORT=16004
STIRLING_LANGS=es_ES
STIRLING_ENABLE_LOGIN=false
STIRLING_DISABLE_ADDITIONAL_FEATURES=false
```

Notas sobre este Compose:

- `Stirling PDF` escucha internamente en `8080/tcp`, pero en este homelab se publica en `16004/tcp`
- este acceso directo por `16004/tcp` debe entenderse como una excepción deliberada al patrón preferente con Caddy; si más adelante quieres homogeneizar la exposición web del homelab, publícalo solo en `127.0.0.1` o intégralo detrás del reverse proxy
- `SECURITY_ENABLELOGIN=false` deja la interfaz sin autenticación local ni usuarios persistentes, algo aceptable aquí solo porque el servicio queda limitado a **LAN + Tailscale**
- `DISABLE_ADDITIONAL_FEATURES=false` mantiene disponibles las funciones extra de la imagen estándar aunque el login esté desactivado
- `tmpfs` en `/tmp`, `/configs`, `/logs` y `/pipeline` fuerza el carácter **stateless** del servicio: nada de lo que se genere ahí sobrevive a una recreación o reinicio del contenedor
- no se usan bind mounts sobre el **SSD NVMe** porque este servicio no necesita persistencia
- WUD puede monitorizar este servicio sin riesgo porque es fácil de recrear y no arrastra estado propio
- se fija `stirlingtools/stirling-pdf:2.14.2` para evitar `latest` y mantener las actualizaciones bajo control
- antes de desplegar o actualizar, verifica en las referencias oficiales que la etiqueta elegida sigue disponible para `linux/arm64` y decide conscientemente si quieres mantenerla o moverla
- alternativa razonable si priorizas ahorro de espacio y solo necesitas operaciones PDF básicas: usar una variante `ultra-lite` de la misma versión fijada
- alternativa razonable si necesitas conversiones más completas, tipografías extra y un paquete más autosuficiente: usar una variante `fat` de la misma versión fijada

## Configuración

### 1. Preparar directorios del stack

```bash
mkdir -p /home/<user>/homelab/compose/productivity-stirling-pdf
```

Guarda en ese directorio el `docker-compose.yml` y el `.env` del apartado anterior.

Como `.env` controla el modo de autenticación y la política de exposición, conviene limitar permisos:

```bash
chmod 600 /home/<user>/homelab/compose/productivity-stirling-pdf/.env
```

### 2. Desplegar el stack

```bash
cd /home/<user>/homelab/compose/productivity-stirling-pdf
docker compose config
docker compose up -d
docker compose ps
docker compose logs --tail=100 stirling-pdf
```

Validaciones rápidas:

```bash
curl -I http://127.0.0.1:16004/
docker compose exec stirling-pdf sh -c 'mount | grep -E "/configs|/logs|/tmp|/pipeline"'
```

Si todo ha arrancado bien, la UI quedará accesible en una de estas URLs:

- `http://<ip-lan-de-la-pi>:16004`
- `http://<hostname-de-tu-pi>.<tailnet>.ts.net:16004`

### 3. Alinear el firewall con esta excepción

Si mantienes el puerto publicado en `0.0.0.0`, el servicio **no** quedará realmente accesible hasta permitirlo en el firewall del host como excepción documentada en [06-puertos-y-firewall.md](../03-red/06-puertos-y-firewall.md).

Con `ufw`, la apertura mínima coherente con este documento es:

```bash
sudo ufw allow in on eth0 proto tcp from <subred-lan-cidr> to any port 16004 comment 'Stirling PDF desde LAN'
sudo ufw allow in on tailscale0 to any port 16004 proto tcp comment 'Stirling PDF desde Tailscale'
sudo ufw status numbered
```

Si usas `nftables`, añade reglas equivalentes restringiendo `16004/tcp` a la LAN y a `tailscale0`.

### 4. Ajustes iniciales en la UI

Con este despliegue no hay bootstrap de usuarios ni base de datos que preparar. Lo razonable es revisar solo lo siguiente:

- que la interfaz abre correctamente y muestra los menús en el idioma esperado
- que puedes subir un PDF de prueba, procesarlo y descargar el resultado
- que al cerrar o recrear el contenedor no dependes de ninguna configuración guardada dentro de la aplicación

Pruebas rápidas recomendadas:

1. unir dos PDFs pequeños
2. extraer una página de un documento
3. comprimir un PDF grande para medir tiempos en la Raspberry Pi 5

### 5. Límites operativos del modo stateless

Este documento describe un despliegue deliberadamente simple. Conviene asumir estas consecuencias desde el principio:

- cualquier ajuste hecho dentro del contenedor se perderá al recrearlo
- no hay autenticación local ni gestión de usuarios persistente en este modo
- no se conservan logs de aplicación ni pipelines personalizados
- si más adelante quieres SSO, usuarios, settings persistentes o automatizaciones, tendrás que pasar a un despliegue con volumen en `/configs`

Para un homelab personal, el criterio práctico es usar Stirling PDF como **herramienta temporal de transformación** y no como repositorio documental.

## Almacenamiento

En este diseño **no hay almacenamiento persistente** del servicio.

Rutas usadas por el contenedor:

- `/tmp` como almacenamiento temporal de trabajo
- `/configs` como configuración efímera en memoria
- `/logs` como logs efímeros en memoria
- `/pipeline` como configuración efímera en memoria para automatizaciones

Política recomendada:

- no crear bind mounts para Stirling PDF mientras quieras mantenerlo como servicio stateless
- no guardar datos de Stirling PDF ni en el **SSD NVMe** ni en `hd2t` ni en `hd5t`
- descargar los PDFs procesados al equipo cliente o moverlos manualmente al servicio de destino si quieres conservarlos

## Backup

Qué respaldar como mínimo:

- el propio `docker-compose.yml`
- el fichero `.env`

Qué **no** hace falta respaldar en este diseño:

- no hay volúmenes persistentes del servicio
- no hay base de datos que exportar
- no hay logs ni configuración interna que conservar

En la práctica, si pierdes el contenedor solo necesitas volver a levantar el stack y seguir usando la herramienta.

## Referencias

- Documentación oficial de Docker para Stirling PDF: https://docs.stirlingpdf.com/Installation/Docker%20Install/
- Versiones oficiales de la imagen Docker: https://docs.stirlingpdf.com/Installation/Versions/
- Documentación oficial de configuración y seguridad: https://docs.stirlingpdf.com/Configuration/System%20and%20Security/
- Imagen Docker oficial: https://hub.docker.com/r/stirlingtools/stirling-pdf
- Releases oficiales del proyecto: https://github.com/Stirling-Tools/Stirling-PDF/releases
