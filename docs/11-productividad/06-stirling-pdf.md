# Stirling PDF

## Descripción
**Stirling PDF** será la caja de herramientas PDF del homelab para unir, dividir, rotar, comprimir, convertir y sanear documentos desde una interfaz web privada.

En esta arquitectura se despliega con estas reglas:

- la aplicación vive en el **SSD NVMe**, pero **sin datos persistentes**
- el acceso web local se publica detrás de **Caddy** con `https://stirling-pdf.lan`
- la conexión va siempre por **HTTPS** con la **CA interna de Caddy**
- el acceso remoto sigue siendo **solo LAN + Tailscale**, sin abrir puertos en el router
- el servicio se ejecuta en modo **stateless**: no se monta `/configs`, no hay base de datos persistente y cualquier ajuste interno se pierde al recrear el contenedor
- la autenticación interna de Stirling PDF queda desactivada, confiando en el alcance de red privado del homelab y en el proxy local

Stirling PDF encaja bien en este homelab porque cubre tareas puntuales sobre PDFs sin depender de servicios externos y, en este caso de uso, no necesita almacenar documentos ni mantener estado entre reinicios.

## Requisitos Previos
- Haber completado `docs/02-docker/01-instalacion-docker.md`.
- Haber completado `docs/02-docker/02-estructura-compose.md`.
- Haber completado `docs/01-sistema/04-estructura-directorios.md`.
- Haber completado `docs/03-red/04-caddy.md`.
- Haber completado `docs/03-red/05-tailscale.md` si quieres usar Stirling PDF también desde fuera de la LAN mediante VPN.
- Haber completado `docs/07-backups/01-estrategia-backup.md`.
- Tener creada la red Docker externa `homelab_proxy`.
- Tener resuelto en Pi-hole o en tu DNS local el FQDN `stirling-pdf.lan` apuntando a la IP LAN principal de la Raspberry Pi.
- Tener importada en los navegadores y dispositivos cliente la CA local de Caddy desde:
  - `/home/<usuario>/homelab/compose/caddy/data/caddy/pki/authorities/local/root.crt`
- Poder usar `sudo` con el usuario administrador del homelab.
- Puertos implicados en esta fase:
  - `8080/tcp` solo dentro de Docker entre Caddy y el contenedor `stirling-pdf`
  - `443/tcp` ya publicado por Caddy en el host
  - no se abre ningún puerto entrante en el router

## Docker Compose
Directorio recomendado:

```text
/home/<usuario>/homelab/compose/stirling-pdf/
├── compose.yaml
└── .env
```

Preparación inicial:

```bash
mkdir -p /home/<usuario>/homelab/compose/stirling-pdf
```

Fichero `.env`:

```dotenv
TZ=Europe/Madrid

STIRLING_PDF_IMAGE=stirlingtools/stirling-pdf:latest

DISABLE_ADDITIONAL_FEATURES=false
SECURITY_ENABLELOGIN=false
SYSTEM_ENABLEANALYTICS=false

SYSTEM_FRONTENDURL=https://stirling-pdf.lan
SYSTEM_CORSALLOWEDORIGINS=https://stirling-pdf.lan
LANGS=es_ES
```

Notas sobre estas variables:

- `STIRLING_PDF_IMAGE` usa la imagen estándar `latest`, suficiente para un uso doméstico general con más funciones que `ultra-lite`.
- `DISABLE_ADDITIONAL_FEATURES=false` mantiene disponibles las funcionalidades ampliadas de la imagen estándar aunque el login quede desactivado.
- `SECURITY_ENABLELOGIN=false` evita tener que gestionar usuarios locales en un servicio que en este homelab solo se expone dentro de la LAN y por Tailscale.
- `SYSTEM_ENABLEANALYTICS=false` elimina el banner de consentimiento y desactiva la telemetría del servicio.
- `SYSTEM_FRONTENDURL` y `SYSTEM_CORSALLOWEDORIGINS` dejan explícita la URL publicada por Caddy.
- `LANGS=es_ES` deja la interfaz en español; si prefieres otra variante, cambia este valor antes del primer arranque.

Fichero `compose.yaml`:

```yaml
name: stirling-pdf

services:
  stirling-pdf:
    container_name: stirling-pdf
    image: ${STIRLING_PDF_IMAGE}
    restart: unless-stopped
    env_file:
      - .env
    environment:
      TZ: ${TZ}
      DISABLE_ADDITIONAL_FEATURES: ${DISABLE_ADDITIONAL_FEATURES}
      SECURITY_ENABLELOGIN: ${SECURITY_ENABLELOGIN}
      SYSTEM_ENABLEANALYTICS: ${SYSTEM_ENABLEANALYTICS}
      SYSTEM_FRONTENDURL: ${SYSTEM_FRONTENDURL}
      SYSTEM_CORSALLOWEDORIGINS: ${SYSTEM_CORSALLOWEDORIGINS}
      LANGS: ${LANGS}
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
- Stirling PDF escucha internamente en el puerto `8080`
- no se monta ningún volumen persistente: el contenedor es completamente **stateless**
- cualquier archivo subido se procesa dentro del contenedor y debe descargarse al cliente; no queda almacenado como biblioteca interna del servicio
- si más adelante necesitas cuentas locales, pipelines persistentes, certificados internos o ajustes duraderos, tendrás que dejar de usar este despliegue stateless y montar al menos `/configs`

Despliegue inicial:

```bash
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/compose/stirling-pdf

cd /home/<usuario>/homelab/compose/stirling-pdf
docker compose config
docker compose pull
docker compose up -d
docker compose ps
docker compose logs -f stirling-pdf
```

Resultado esperado:

- el contenedor `stirling-pdf` queda levantado
- Stirling PDF escucha internamente en `http://stirling-pdf:8080`
- no se crea ningún directorio de datos persistentes en `/home/<usuario>/homelab/data/`
- Caddy puede publicar el servicio como `https://stirling-pdf.lan`

## Configuración

### Objetivo de esta fase

| Elemento | Estado esperado |
|---|---|
| UI local | `https://stirling-pdf.lan` |
| Persistencia | ninguna |
| Punto de entrada | Caddy |
| TLS | `tls internal` con CA local de Caddy |
| Autenticación local | desactivada |
| Analítica | desactivada |
| Uso principal | manipulación puntual de PDFs |

### 1. Preparar rutas y permisos

Crear la estructura base:

```bash
mkdir -p /home/<usuario>/homelab/compose/stirling-pdf
```

Permisos recomendados:

```bash
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/compose/stirling-pdf
chmod 755 /home/<usuario>/homelab/compose/stirling-pdf
```

En este servicio no se crea `/home/<usuario>/homelab/data/stirling-pdf/` porque el objetivo es mantenerlo **sin persistencia**. El **SSD NVMe** solo almacena el stack `compose/`. `hd2t` se reserva para backups de configuración y `hd5t` no interviene en este servicio.

### 2. Publicar Stirling PDF en Caddy con HTTPS interno

Añade este bloque al `Caddyfile` del stack de Caddy:

```caddyfile
stirling-pdf.lan {
  import common
  tls internal
  reverse_proxy stirling-pdf:8080
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

- usa un hostname dedicado en la raíz y no un subpath
- si en tu homelab ya has estandarizado `*.homelab.lan`, sustituye `stirling-pdf.lan` por `stirling-pdf.homelab.lan` en **DNS**, `.env` y `Caddyfile`
- mantener `SYSTEM_FRONTENDURL` y `SYSTEM_CORSALLOWEDORIGINS` alineados con la URL real evita problemas con cabeceras y llamadas desde la propia interfaz

### 3. Importar la CA local de Caddy en los clientes

Ruta del certificado raíz en el host:

```text
/home/<usuario>/homelab/compose/caddy/data/caddy/pki/authorities/local/root.crt
```

Importa ese certificado en:

- tu navegador principal
- cualquier otro navegador o equipo desde el que vayas a abrir `https://stirling-pdf.lan`
- cualquier equipo adicional conectado por Tailscale que deba confiar en el certificado interno

Sin esa CA instalada el acceso seguirá cifrado, pero el navegador no confiará en el certificado y el uso diario será incómodo.

### 4. Primer acceso y validación funcional

Abrir después:

```text
https://stirling-pdf.lan
```

Prueba mínima recomendada tras el arranque:

1. Abrir la interfaz y confirmar que no aparece pantalla de login.
2. Verificar que la UI carga en español si has dejado `LANGS=es_ES`.
3. Subir un PDF pequeño a una operación simple, por ejemplo rotación o extracción de páginas.
4. Descargar el resultado y comprobar que el fichero generado se abre correctamente en el cliente.
5. Reiniciar el contenedor y confirmar que la aplicación vuelve a estar limpia, sin configuración persistida:

```bash
cd /home/<usuario>/homelab/compose/stirling-pdf
docker compose restart stirling-pdf
docker compose logs --tail=100 stirling-pdf
```

### 5. Límites operativos del modo stateless

Este despliegue es deliberadamente simple, pero tiene implicaciones importantes:

- no hay usuarios locales ni credenciales persistentes porque `SECURITY_ENABLELOGIN=false`
- no se conservan preferencias internas ni base de datos porque no existe volumen `/configs`
- no se guardan logs persistentes del servicio
- cualquier pipeline, certificado interno de firma o personalización de la UI se perdería al recrear el contenedor

Para un homelab de uso personal esto es razonable si Stirling PDF se usa como utilidad puntual y no como plataforma documental. Si más adelante quieres automatizaciones, historial persistente o autenticación local, conviene migrar a un despliegue con `/configs`, `/logs` y, si aplica, `/pipeline`.

### 6. Buenas prácticas de uso

Recomendaciones prácticas para este homelab:

- tratar Stirling PDF como herramienta de paso, no como almacén de documentos
- descargar siempre el resultado final al equipo cliente o moverlo manualmente a otro servicio del homelab si debe conservarse
- no subir documentos sensibles desde equipos que no confíen en la CA local de Caddy
- si necesitas OCR o conversiones pesadas de forma frecuente, vigila el uso de CPU y memoria de la Raspberry Pi 5 durante lotes grandes

## Almacenamiento

Volúmenes utilizados por el stack:

- no hay volúmenes persistentes montados en este despliegue
- `/home/<usuario>/homelab/compose/stirling-pdf/` en el host

Qué queda almacenado realmente:

- `compose.yaml` y `.env` del stack
- ficheros temporales internos del contenedor mientras procesa PDFs

Política de almacenamiento para este homelab:

- **SSD NVMe**: solo el stack `compose/`
- **hd2t**: destino de backup del directorio `compose/`
- **hd5t**: no participa en este servicio

Consecuencias prácticas del modelo sin persistencia:

- reiniciar o recrear el contenedor no debe afectar a documentos ya descargados por el usuario
- cualquier documento que no se haya descargado se considera perdido tras el fin del procesamiento o tras reiniciar el contenedor
- no hay base de datos, biblioteca documental ni directorio de uploads que respaldar

## Backup

Qué conviene respaldar:

- todo `/home/<usuario>/homelab/compose/stirling-pdf/`

En este despliegue no hay volúmenes de aplicación, no hay base de datos y no hay uploads persistentes. El backup consiste únicamente en conservar la definición exacta del stack y sus variables.

### Backup manual recomendado

```bash
mkdir -p /mnt/hd2t/backups/stirling-pdf
timestamp="$(date +%F-%H%M%S)"

rsync -a \
  /home/<usuario>/homelab/compose/stirling-pdf/ \
  "/mnt/hd2t/backups/stirling-pdf/compose-${timestamp}/"

tar -C /mnt/hd2t/backups/stirling-pdf \
  -czf "/mnt/hd2t/backups/stirling-pdf/stirling-pdf-compose-${timestamp}.tar.gz" \
  "compose-${timestamp}"

sha256sum "/mnt/hd2t/backups/stirling-pdf/stirling-pdf-compose-${timestamp}.tar.gz" \
  > "/mnt/hd2t/backups/stirling-pdf/stirling-pdf-compose-${timestamp}.tar.gz.sha256"
```

### Qué no conviene hacer

- asumir que hay datos internos del servicio que restaurar, porque este despliegue no los tiene
- usar Stirling PDF como ubicación temporal única para documentos importantes
- olvidar que un cambio futuro a modo persistente obligará a rediseñar también la estrategia de backup

### Restore recomendado

Secuencia práctica:

1. Restaurar el directorio `compose/` del backup.
2. Revisar `.env` y `compose.yaml`.
3. Levantar el stack de nuevo.
4. Validar acceso web y ejecución de una operación simple sobre un PDF de prueba.

Ejemplo:

```bash
sudo mv \
  /home/<usuario>/homelab/compose/stirling-pdf \
  "/home/<usuario>/homelab/compose/stirling-pdf.before-restore-$(date +%F-%H%M%S)"

sudo mkdir -p /home/<usuario>/homelab/compose

sudo tar -C /home/<usuario>/homelab/compose \
  -xzf /mnt/hd2t/backups/stirling-pdf/stirling-pdf-compose-<timestamp>.tar.gz

sudo mv \
  /home/<usuario>/homelab/compose/compose-<timestamp> \
  /home/<usuario>/homelab/compose/stirling-pdf

cd /home/<usuario>/homelab/compose/stirling-pdf
docker compose up -d
docker compose logs --tail=100 stirling-pdf
```

Validación posterior al restore:

- la interfaz abre en `https://stirling-pdf.lan`
- no aparece login local
- se puede completar una operación simple con un PDF de prueba

## Referencias
- Documentación oficial de Stirling PDF: `https://docs.stirlingpdf.com/`
- Guía Docker oficial: `https://docs.stirlingpdf.com/Installation/Docker%20Install/`
- Configuración de login, sistema y seguridad: `https://docs.stirlingpdf.com/Configuration/System%20and%20Security/`
- Analítica y telemetría: `https://docs.stirlingpdf.com/analytics-telemetry/`
- Versiones e imágenes Docker: `https://docs.stirlingpdf.com/Installation/Versions/`
- Repositorio oficial de Stirling PDF: `https://github.com/Stirling-Tools/Stirling-PDF`
- Imagen Docker oficial `stirlingtools/stirling-pdf`: `https://hub.docker.com/r/stirlingtools/stirling-pdf`
