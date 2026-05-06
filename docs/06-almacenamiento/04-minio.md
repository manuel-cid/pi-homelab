# MinIO

## Descripción
**MinIO** aportará almacenamiento de objetos compatible con **S3** dentro del homelab para usarlo como destino de copias de seguridad, exports y archivos de respaldo generados por otros servicios.

En esta arquitectura se despliega sobre la **Raspberry Pi 5** con estas decisiones:

- un único nodo MinIO en Docker
- datos persistentes en el **SSD NVMe**
- acceso solo por **LAN** y **Tailscale**
- sin exposición pública a internet
- uso principal como **destino secundario de backups**, no como única copia

Para este homelab doméstico tiene sentido como endpoint S3 interno para herramientas como **restic**, **Kopia** o scripts propios que suban dumps y archivos `.tar.gz`. No sustituye a un NAS generalista ni añade alta disponibilidad: si el SSD NVMe falla y no has replicado MinIO a otro sitio, perderás también el almacén de backups que vivía ahí.

## Requisitos Previos
- Haber completado `docs/02-docker/01-instalacion-docker.md`.
- Haber completado `docs/02-docker/02-estructura-compose.md`.
- Haber completado `docs/01-sistema/04-estructura-directorios.md`.
- Tener montado y accesible `/mnt/hd2t` si vas a hacer una copia local secundaria del propio MinIO en ese disco.
- Tener libre suficiente espacio en el **SSD NVMe** para:
  - objetos almacenados en MinIO
  - metadatos internos de buckets, políticas y usuarios
  - crecimiento futuro de repositorios de backup
- Poder usar `sudo` con el usuario administrador del homelab.
- Tener claro que este despliegue es **single-node** y no reemplaza una estrategia de backup real a otro disco, otro host o un destino externo.
- Puertos implicados:
  - `9000/tcp` para el endpoint **S3 API**
  - `9001/tcp` para la consola web de administración

## Docker Compose
Directorio recomendado:

```text
/home/<usuario>/homelab/compose/minio/
├── compose.yaml
└── .env
```

Preparación inicial de rutas:

```bash
mkdir -p /home/<usuario>/homelab/compose/minio
mkdir -p /home/<usuario>/homelab/data/minio/data

sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/data/minio
sudo find /home/<usuario>/homelab/data/minio -type d -exec chmod 2775 {} \;
sudo find /home/<usuario>/homelab/data/minio -type f -exec chmod 664 {} \;
```

Fichero `.env`:

```dotenv
TZ=Europe/Madrid

MINIO_IMAGE=minio/minio:latest

PUID=1000
PGID=1000

MINIO_API_PORT=9000
MINIO_CONSOLE_PORT=9001

MINIO_DATA_DIR=/home/<usuario>/homelab/data/minio/data

MINIO_ROOT_USER=<CAMBIA_ESTE_USUARIO_ROOT>
MINIO_ROOT_PASSWORD=<CAMBIA_ESTA_PASSWORD_ROOT_LARGA>
```

Notas sobre `.env`:

- `PUID` y `PGID` deben coincidir con el usuario Linux real que poseerá los datos en el host. Compruébalo con `id <usuario>`.
- `MINIO_ROOT_USER` y `MINIO_ROOT_PASSWORD` son las credenciales administrativas iniciales. No uses `minioadmin:minioadmin`.
- aunque MinIO sea compatible con S3, aquí no se usa para publicar archivos a internet sino como endpoint interno para backups.
- si en el futuro un cliente exige TLS o un FQDN estable, podrás poner MinIO detrás de Caddy, pero en esta fase no es necesario

Fichero `compose.yaml`:

```yaml
name: minio

services:
  minio:
    container_name: minio
    image: ${MINIO_IMAGE}
    user: "${PUID}:${PGID}"
    restart: unless-stopped
    env_file:
      - .env
    environment:
      TZ: ${TZ}
      MINIO_ROOT_USER: ${MINIO_ROOT_USER}
      MINIO_ROOT_PASSWORD: ${MINIO_ROOT_PASSWORD}
    command:
      - server
      - /data
      - --console-address
      - ":9001"
    ports:
      - "${MINIO_API_PORT}:9000"
      - "${MINIO_CONSOLE_PORT}:9001"
    volumes:
      - ${MINIO_DATA_DIR}:/data
    security_opt:
      - no-new-privileges:true
```

Despliegue inicial:

```bash
cd /home/<usuario>/homelab/compose/minio
docker compose config
docker compose pull
docker compose up -d
docker compose ps
docker compose logs -f minio
```

Resultado esperado:

- la consola web queda accesible en `http://<ip-lan-de-la-pi>:9001`
- el endpoint S3 queda accesible en `http://<ip-lan-de-la-pi>:9000`
- los datos persistentes viven en `/home/<usuario>/homelab/data/minio/data/`
- no hace falta Caddy ni publicar un dominio para esta fase

## Configuración

### Objetivo de esta fase

| Elemento | Estado esperado |
|---|---|
| Tipo de acceso | LAN + Tailscale |
| Exposición pública | ninguna |
| Consola web | `http://<ip-lan-de-la-pi>:9001` |
| Endpoint S3 | `http://<ip-lan-de-la-pi>:9000` |
| Datos persistentes | SSD NVMe |
| Reverse proxy | no aplica |

### 1. Verificar el primer acceso

Tras levantar el stack, abre:

- `http://<ip-lan-de-la-pi>:9001` desde un equipo en LAN
- `http://100.x.y.z:9001` o el nombre MagicDNS de la Raspberry Pi si accedes por Tailscale

Usa las credenciales definidas en `.env`.

Comprobaciones rápidas desde terminal:

```bash
curl http://127.0.0.1:9000/minio/health/live
docker compose -f /home/<usuario>/homelab/compose/minio/compose.yaml logs --tail=100 minio
```

Si todo está bien:

- la consola permite iniciar sesión
- el endpoint `9000` responde
- no aparecen errores de permisos sobre `/data`

### 2. Crear buckets base para backups

En la consola de MinIO crea, como mínimo, una separación clara por tipo de copia. Un reparto simple y fácil de mantener es este:

| Bucket | Uso recomendado |
|---|---|
| `backups-restic` | repositorios de restic |
| `backups-kopia` | repositorios de Kopia si decides usarlo |
| `db-dumps` | volcados SQL, exports y snapshots manuales |
| `compose-archives` | copias de `compose/`, `.env` y archivos de configuración |

Buenas prácticas para los buckets:

- usa nombres simples en minúsculas y con guiones
- separa herramientas distintas en buckets distintos siempre que puedas
- evita mezclar repositorios de backup con exports manuales en el mismo bucket
- en este homelab pequeño conviene empezar sin complicar la estructura con demasiadas políticas o jerarquías

Para una primera versión también puedes crear solo uno o dos buckets:

- `backups-homelab`
- `db-dumps`

Y luego separar por prefijos cuando ya tengas más servicios generando copias.

### 3. Separar credenciales administrativas de las credenciales de backup

No uses la cuenta `root` de MinIO en scripts, cronjobs o herramientas de backup.

Modelo recomendado:

- cuenta `root` solo para administración
- un usuario o access key específica para cada herramienta de backup
- permisos limitados al bucket que realmente necesita

Ejemplo práctico:

- `backup-restic` con acceso a `backups-restic`
- `backup-dumps` con acceso a `db-dumps`

Si quieres automatizar la creación por CLI, puedes usar el cliente `mc` desde un contenedor aparte con una política mínima para un bucket concreto.

Ejemplo de política JSON para escritura y lectura sobre `backups-restic`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket",
        "s3:GetBucketLocation"
      ],
      "Resource": [
        "arn:aws:s3:::backups-restic"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:AbortMultipartUpload",
        "s3:ListBucketMultipartUploads",
        "s3:ListMultipartUploadParts"
      ],
      "Resource": [
        "arn:aws:s3:::backups-restic/*"
      ]
    }
  ]
}
```

Con ese fichero guardado como `/tmp/minio-backup-restic-policy.json`, un flujo posible sería:

```bash
docker run --rm --network host \
  -v /tmp/minio-backup-restic-policy.json:/tmp/policy.json:ro \
  minio/mc sh -c '
    mc alias set local http://127.0.0.1:9000 <MINIO_ROOT_USER> <MINIO_ROOT_PASSWORD> &&
    mc mb --ignore-existing local/backups-restic &&
    mc admin policy create local backup-restic /tmp/policy.json &&
    mc admin user add local backup-restic <SECRET_KEY_MUY_LARGA> &&
    mc admin policy attach local backup-restic --user backup-restic
  '
```

Notas importantes:

- guarda las secret keys creadas fuera de MinIO, por ejemplo en tu gestor de contraseñas
- la cuenta `backup-restic` se convierte en la credencial que usarán tus jobs
- si prefieres hacerlo por la UI, aplica el mismo criterio: una identidad dedicada y permisos mínimos

### 4. Usar MinIO como destino S3 de backups

Parámetros típicos que necesitarán otras herramientas:

| Dato | Valor típico |
|---|---|
| Endpoint S3 | `http://<ip-lan-de-la-pi>:9000` |
| Access key | usuario o access key dedicada |
| Secret key | contraseña o secret key dedicada |
| Bucket | por ejemplo `backups-restic` |
| Región | `us-east-1` si la herramienta exige indicar una |

Ejemplo con **restic**:

```bash
export AWS_ACCESS_KEY_ID=backup-restic
export AWS_SECRET_ACCESS_KEY=<SECRET_KEY_MUY_LARGA>
export AWS_DEFAULT_REGION=us-east-1
export RESTIC_REPOSITORY=s3:http://<ip-lan-de-la-pi>:9000/backups-restic

restic snapshots
```

Qué encaja bien en MinIO dentro de este homelab:

- repositorios de backup de configs y volúmenes pequeños
- dumps periódicos de bases de datos
- exports manuales antes de actualizaciones delicadas
- archivos comprimidos que luego quieras replicar a otro disco o a otro destino

Qué no conviene hacer:

- usar MinIO como única copia de seguridad de datos importantes
- guardar dentro de MinIO backups que nunca salen del mismo SSD NVMe
- asumir que este despliegue single-node te da tolerancia a fallos

### 5. Comprobaciones rápidas

Desde la Raspberry Pi:

```bash
docker compose -f /home/<usuario>/homelab/compose/minio/compose.yaml logs --tail=100 minio
ss -tulpn | rg ':(9000|9001)\\b'
curl http://127.0.0.1:9000/minio/health/live
```

Validaciones útiles:

- el puerto `9001` carga la consola web
- el puerto `9000` responde como endpoint S3
- los buckets aparecen en la consola
- las credenciales dedicadas pueden operar sobre su bucket y no sobre todos

Si algo falla, revisa en este orden:

1. permisos reales sobre `/home/<usuario>/homelab/data/minio/data`
2. que `PUID` y `PGID` coincidan con el usuario propietario
3. que el host no tenga ocupado `9000` o `9001`
4. que estés usando el endpoint correcto en la herramienta cliente
5. que la política del usuario de backup incluya realmente las acciones necesarias

## Almacenamiento

| Elemento | Ruta recomendada | Disco |
|---|---|---|
| Stack Compose de MinIO | `/home/<usuario>/homelab/compose/minio/` | SSD NVMe |
| Variables del stack | `/home/<usuario>/homelab/compose/minio/.env` | SSD NVMe |
| Datos persistentes de MinIO | `/home/<usuario>/homelab/data/minio/data/` | SSD NVMe |
| Copia local secundaria de MinIO | `/mnt/hd2t/backups/minio/` | `hd2t` |

Notas de almacenamiento:

- en MinIO, el contenido de objetos y buena parte del estado interno viven juntos en el directorio de datos
- si pierdes `/home/<usuario>/homelab/data/minio/data/`, pierdes buckets, objetos y parte relevante de la configuración persistida
- `hd2t` es un buen destino para una copia secundaria del propio MinIO
- `hd5t` no participa en este servicio y conviene reservarlo para Stash

Permisos recomendados:

```bash
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/data/minio
sudo find /home/<usuario>/homelab/data/minio -type d -exec chmod 2775 {} \;
sudo find /home/<usuario>/homelab/data/minio -type f -exec chmod 664 {} \;
```

Sobre el diseño de almacenamiento:

- el **SSD NVMe** es el backend vivo de MinIO porque da mejor latencia para operaciones S3 y metadatos
- `hd2t` debe usarse para respaldar MinIO, no como ruta activa del servicio en este diseño
- si tu volumen de backups crece mucho, tendrás que decidir entre mover MinIO a otro backend o usarlo solo como staging temporal

## Backup
Respaldar como mínimo:

- `/home/<usuario>/homelab/compose/minio/compose.yaml`
- `/home/<usuario>/homelab/compose/minio/.env`
- `/home/<usuario>/homelab/data/minio/data/`
- el inventario de buckets, usuarios y políticas que realmente estés usando

Punto importante:

- si MinIO almacena backups de otros servicios, también debes respaldar **el propio MinIO**
- un backup que vive solo dentro del mismo SSD NVMe sigue compartiendo el mismo punto de fallo

Estrategia práctica de copia local a `hd2t`:

```bash
mkdir -p /mnt/hd2t/backups/minio
docker compose -f /home/<usuario>/homelab/compose/minio/compose.yaml stop minio
rsync -a /home/<usuario>/homelab/compose/minio/ /mnt/hd2t/backups/minio/compose/
rsync -a /home/<usuario>/homelab/data/minio/ /mnt/hd2t/backups/minio/data/
docker compose -f /home/<usuario>/homelab/compose/minio/compose.yaml up -d
```

Ese enfoque hace una **copia en frío** sencilla. Si más adelante quieres reducir parada, puedes pasar a snapshots del filesystem o a una estrategia de replicación externa, pero para un homelab pequeño esta opción es fácil de entender y recuperar.

Inventario útil de buckets, usuarios y políticas:

```bash
mkdir -p /mnt/hd2t/backups/minio
docker run --rm --network host minio/mc sh -c '
  mc alias set local http://127.0.0.1:9000 <MINIO_ROOT_USER> <MINIO_ROOT_PASSWORD> &&
  {
    date &&
    echo &&
    mc ls local &&
    echo &&
    mc admin user list local &&
    echo &&
    mc admin policy list local
  }
' > /mnt/hd2t/backups/minio/inventario-$(date +%F).txt
```

No es necesario respaldar:

- la imagen Docker descargable de nuevo
- el contenedor recreable
- caches o estado transitorio de sesiones web

Recuerda:

- MinIO puede ser un buen **destino** de backup
- MinIO no debe ser el **único lugar** donde exista ese backup
- si el contenido es importante, replica también fuera del SSD NVMe

## Referencias
- Documentación oficial de MinIO  
  https://min.io/docs/minio/container/index.html
- Despliegue container single-node  
  https://min.io/docs/minio/container/operations/install-deploy-manage/deploy-minio-single-node-single-drive.html
- Credenciales root de MinIO  
  https://min.io/docs/minio/linux/reference/minio-server/settings/root-credentials.html
- Referencia del cliente `mc`  
  https://min.io/docs/minio/linux/reference/minio-mc.html
- Imagen Docker `minio/minio`  
  https://hub.docker.com/r/minio/minio
- Imagen Docker `minio/mc`  
  https://hub.docker.com/r/minio/mc
