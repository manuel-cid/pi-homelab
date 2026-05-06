# Mealie

## Descripción
**Mealie** será el gestor de recetas del homelab para centralizar recetas propias, importar recetas desde la web, planificar comidas y generar listas de la compra desde una interfaz privada.

En esta arquitectura se despliega con estas reglas:

- la aplicación y todos sus datos persistentes viven en el **SSD NVMe**
- el acceso web local se publica detrás de **Caddy** con `https://mealie.lan`
- la conexión va siempre por **HTTPS** con la **CA interna de Caddy**
- el acceso remoto sigue siendo **solo LAN + Tailscale**, sin abrir puertos en el router
- la persistencia usa la base de datos **SQLite** integrada, suficiente para un uso personal o familiar pequeño
- la importación de recetas se hace desde la propia interfaz, priorizando la captura desde URL y las importaciones compatibles del origen que quieras migrar

Mealie encaja bien en este homelab porque resuelve una necesidad cotidiana con un stack muy simple, mantiene todo el estado en un único directorio fácil de respaldar y no necesita una base de datos separada para un uso doméstico.

## Requisitos Previos
- Haber completado `docs/02-docker/01-instalacion-docker.md`.
- Haber completado `docs/02-docker/02-estructura-compose.md`.
- Haber completado `docs/01-sistema/04-estructura-directorios.md`.
- Haber completado `docs/03-red/04-caddy.md`.
- Haber completado `docs/03-red/05-tailscale.md` si quieres consultar recetas también desde fuera de la LAN mediante VPN.
- Haber completado `docs/07-backups/01-estrategia-backup.md`.
- Haber completado `docs/07-backups/03-backup-docker-volumes.md`.
- Tener creada la red Docker externa `homelab_proxy`.
- Tener resuelto en Pi-hole o en tu DNS local el FQDN `mealie.lan` apuntando a la IP LAN principal de la Raspberry Pi.
- Tener importada en los navegadores y dispositivos cliente la CA local de Caddy desde:
  - `/home/<usuario>/homelab/compose/caddy/data/caddy/pki/authorities/local/root.crt`
- Poder usar `sudo` con el usuario administrador del homelab.
- Puertos implicados en esta fase:
  - `9000/tcp` solo dentro de Docker entre Caddy y el contenedor `mealie`
  - `443/tcp` ya publicado por Caddy en el host
  - no se abre ningún puerto entrante en el router

## Docker Compose
Directorio recomendado:

```text
/home/<usuario>/homelab/compose/mealie/
├── compose.yaml
└── .env
```

Preparación inicial:

```bash
mkdir -p /home/<usuario>/homelab/compose/mealie
mkdir -p /home/<usuario>/homelab/data/mealie
```

Fichero `.env`:

```dotenv
TZ=Europe/Madrid

MEALIE_IMAGE=ghcr.io/mealie-recipes/mealie:latest

BASE_URL=https://mealie.lan
ALLOW_SIGNUP=false
DB_ENGINE=sqlite
LOG_LEVEL=INFO

MEALIE_DATA_DIR=/home/<usuario>/homelab/data/mealie
```

Notas sobre estas variables:

- `BASE_URL` debe coincidir exactamente con la URL real publicada por Caddy.
- `ALLOW_SIGNUP=false` evita que queden altas abiertas una vez creada la cuenta administradora inicial.
- `DB_ENGINE=sqlite` simplifica el despliegue y el backup para este homelab.
- `LOG_LEVEL=INFO` ofrece un punto de partida razonable sin generar demasiado ruido en disco.
- `MEALIE_DATA_DIR` vive en el NVMe porque ahí quedarán la base de datos, imágenes, adjuntos y el estado general del servicio.

Fichero `compose.yaml`:

```yaml
name: mealie

services:
  mealie:
    container_name: mealie
    image: ${MEALIE_IMAGE}
    restart: unless-stopped
    env_file:
      - .env
    volumes:
      - ${MEALIE_DATA_DIR}:/app/data
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
- Mealie escucha internamente en el puerto `9000`
- toda la persistencia queda concentrada en `/app/data`
- la base de datos por defecto es **SQLite**, adecuada para este caso de uso y fácil de respaldar
- el contenedor se puede recrear sin perder estado mientras el bind mount del NVMe se conserve

Despliegue inicial:

```bash
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/compose/mealie
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/data/mealie

cd /home/<usuario>/homelab/compose/mealie
docker compose config
docker compose pull
docker compose up -d
docker compose ps
docker compose logs -f mealie
```

Resultado esperado:

- el contenedor `mealie` queda levantado
- Mealie escucha internamente en `http://mealie:9000`
- se crea la estructura persistente en `/home/<usuario>/homelab/data/mealie/`
- Caddy puede publicar el servicio como `https://mealie.lan`

## Configuración

### Objetivo de esta fase

| Elemento | Estado esperado |
|---|---|
| UI local | `https://mealie.lan` |
| Persistencia | `/home/<usuario>/homelab/data/mealie/` |
| Base de datos | SQLite en el NVMe |
| Punto de entrada | Caddy |
| TLS | `tls internal` con CA local de Caddy |
| Uso principal | recetas, planificación y lista de la compra |
| Importación | recetas desde URL y orígenes compatibles |

### 1. Preparar rutas y permisos

Crear la estructura base:

```bash
mkdir -p /home/<usuario>/homelab/compose/mealie
mkdir -p /home/<usuario>/homelab/data/mealie
```

Permisos recomendados:

```bash
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/compose/mealie
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/data/mealie

chmod 755 /home/<usuario>/homelab/data/mealie
```

Toda la información operativa de Mealie debe quedarse en el **SSD NVMe**. `hd2t` se reserva para backups y `hd5t` no interviene en este servicio.

### 2. Publicar Mealie en Caddy con HTTPS interno

Añade este bloque al `Caddyfile` del stack de Caddy:

```caddyfile
mealie.lan {
  import common
  tls internal
  reverse_proxy mealie:9000
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
- si en tu homelab ya has estandarizado `*.homelab.lan`, sustituye `mealie.lan` por `mealie.homelab.lan` en **DNS**, `.env` y `Caddyfile`
- mantener `BASE_URL` alineado con la URL publicada evita redirecciones erróneas y problemas de enlaces absolutos

### 3. Importar la CA local de Caddy en los clientes

Ruta del certificado raíz en el host:

```text
/home/<usuario>/homelab/compose/caddy/data/caddy/pki/authorities/local/root.crt
```

Importa ese certificado en:

- tu navegador principal
- cualquier otro navegador o dispositivo desde el que vayas a abrir `https://mealie.lan`
- cualquier equipo adicional conectado por Tailscale que deba confiar en el certificado interno

Sin esa CA instalada el acceso seguirá cifrado, pero el navegador no confiará en el certificado y la experiencia de uso será peor.

### 4. Primer acceso y endurecimiento básico

Abrir después:

```text
https://mealie.lan
```

En el primer acceso:

- crea la cuenta administradora inicial si la aplicación todavía no tiene usuarios
- verifica que el idioma y la zona horaria de la interfaz queden alineados con tu uso diario
- revisa que el registro público siga desactivado con `ALLOW_SIGNUP=false`

Ajustes recomendados para este homelab:

- definir categorías base como `Desayunos`, `Comidas`, `Cenas`, `Postres` o las que encajen con tu organización
- crear etiquetas para cocina, dieta, dificultad o tiempo de preparación
- revisar que las listas de la compra y la planificación semanal se generen en la unidad familiar esperada

### 5. Importación de recetas

Mealie tiene sentido en esta fase si se usa como repositorio vivo de recetas, no como un simple recetario vacío. La secuencia práctica es:

1. Importar primero unas pocas recetas reales para validar que la extracción de ingredientes y pasos es correcta.
2. Ajustar categorías, etiquetas y unidades antes de una migración grande.
3. Repetir la importación masiva solo cuando la estructura ya esté clara.

Recomendaciones operativas:

- para recetas públicas de la web, usa la función de importación desde URL de la interfaz
- después de cada importación revisa el título, tiempos, ingredientes, unidades y notas, porque la extracción depende de la calidad de la página origen
- si migras desde otro gestor, prioriza los formatos de exportación compatibles que preserve mejor ingredientes, pasos e imágenes
- guarda una receta manualmente creada como plantilla de referencia para mantener un estilo homogéneo en el recetario

## Almacenamiento

Volúmenes utilizados por el stack:

- `/home/<usuario>/homelab/data/mealie` en el host
- `/app/data` dentro del contenedor

Qué queda almacenado en esa ruta:

- la base de datos SQLite del servicio
- imágenes y adjuntos asociados a recetas
- configuración persistente y metadatos internos

Política de almacenamiento para este homelab:

- **SSD NVMe**: aplicación, datos persistentes y estado completo de Mealie
- **hd2t**: destino de backups del directorio de datos y del stack `compose/`
- **hd5t**: no participa en este servicio

Permisos recomendados:

```bash
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/data/mealie
chmod 755 /home/<usuario>/homelab/data/mealie
```

## Backup

Qué conviene respaldar:

- todo `/home/<usuario>/homelab/data/mealie/`
- todo `/home/<usuario>/homelab/compose/mealie/`

Como este despliegue usa **SQLite**, la copia más segura y simple para este homelab es parar unos segundos el contenedor y respaldar el directorio completo.

### Backup manual recomendado

```bash
mkdir -p /mnt/hd2t/backups/mealie
timestamp="$(date +%F-%H%M%S)"

cd /home/<usuario>/homelab/compose/mealie
docker compose stop mealie

sudo tar -C /home/<usuario>/homelab/data \
  -czf "/mnt/hd2t/backups/mealie/mealie-data-${timestamp}.tar.gz" \
  mealie

rsync -a \
  /home/<usuario>/homelab/compose/mealie/ \
  /mnt/hd2t/backups/mealie/compose/

docker compose start mealie

sha256sum "/mnt/hd2t/backups/mealie/mealie-data-${timestamp}.tar.gz" \
  > "/mnt/hd2t/backups/mealie/mealie-data-${timestamp}.tar.gz.sha256"
```

Este enfoque cubre tanto la base SQLite como las imágenes y el resto de estado persistente.

### Qué no conviene hacer

- confiar solo en la imagen Docker
- respaldar únicamente `compose.yaml` y olvidar el directorio de datos
- copiar la base SQLite en caliente como única estrategia si el servicio está recibiendo escrituras

### Restore recomendado

Secuencia práctica:

1. Parar el stack de Mealie.
2. Renombrar el directorio actual como salvaguarda.
3. Restaurar el `tar.gz` del backup en `/home/<usuario>/homelab/data/`.
4. Levantar el stack y validar login, recetas e imágenes.

Ejemplo:

```bash
cd /home/<usuario>/homelab/compose/mealie
docker compose down

sudo mv \
  /home/<usuario>/homelab/data/mealie \
  "/home/<usuario>/homelab/data/mealie.before-restore-$(date +%F-%H%M%S)"

sudo mkdir -p /home/<usuario>/homelab/data
sudo tar -C /home/<usuario>/homelab/data \
  -xzf /mnt/hd2t/backups/mealie/mealie-data-<timestamp>.tar.gz

docker compose up -d
docker compose logs --tail=100 mealie
```

Validación posterior al restore:

- el login funciona con la cuenta existente
- las recetas importadas siguen presentes
- las imágenes de recetas cargan correctamente
- la planificación y las listas de la compra conservan su estado

## Referencias
- Documentación oficial de Mealie: `https://docs.mealie.io/`
- Repositorio oficial de Mealie: `https://github.com/mealie-recipes/mealie`
- Compose oficial de referencia: `https://github.com/mealie-recipes/mealie/blob/mealie-next/docker/docker-compose.yml`
- Imagen Docker oficial de Mealie: `https://github.com/mealie-recipes/mealie/pkgs/container/mealie`
