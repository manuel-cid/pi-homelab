# Dozzle

## Descripción
**Dozzle** será el visor ligero de logs en tiempo real del homelab. Su función es ofrecer una interfaz web simple para consultar la salida de los contenedores Docker sin tener que entrar por terminal ni ejecutar `docker logs` manualmente para cada servicio.

En este proyecto se usará para:

- revisar logs en vivo de los stacks desplegados en la Raspberry Pi 5
- filtrar rápidamente por contenedor cuando un servicio falle o reinicie
- facilitar diagnóstico operativo básico desde navegador en LAN o Tailscale
- centralizar una vista rápida de logs sin montar una plataforma pesada de agregación

Dozzle **no** es un sistema de retención histórica ni un stack de observabilidad completo. No sustituye a Prometheus, Grafana ni a una solución tipo Loki/ELK. Su papel aquí es estrictamente operativo: **ver logs recientes y en directo**. La persistencia que necesita es mínima y debe quedarse en el **SSD NVMe**, igual que el resto de servicios del homelab.

## Requisitos Previos
- Haber completado `docs/02-docker/01-instalacion-docker.md`.
- Haber completado `docs/02-docker/02-estructura-compose.md`.
- Haber completado `docs/01-sistema/04-estructura-directorios.md`.
- Haber completado `docs/05-monitorizacion/05-uptime-kuma.md` si quieres vigilar la propia UI de Dozzle desde el primer día con un monitor HTTP.
- Tener creada la red Docker externa `homelab_shared`.
- Tener claro que este homelab solo se expone en **LAN + Tailscale**, sin publicación a internet.
- Tener previstas las rutas persistentes en el SSD NVMe:
  - `/home/<usuario>/homelab/compose`
  - `/home/<usuario>/homelab/data`
- Entender que montar `/var/run/docker.sock` da a Dozzle acceso equivalente a Docker sobre el host, por lo que conviene mantener autenticación y no exponerlo fuera de redes de confianza.
- Puertos implicados:
  - `8088/tcp` publicado en el host para la interfaz web de Dozzle
  - `8080/tcp` expuesto internamente por el contenedor

## Docker Compose
Directorio recomendado:

```text
/home/<usuario>/homelab/compose/dozzle/
├── compose.yaml
└── .env
```

Fichero `.env` recomendado:

```dotenv
TZ=Europe/Madrid
DOZZLE_PORT=8088
DOZZLE_HOSTNAME=rpi5-homelab
DOZZLE_LEVEL=info
DOZZLE_AUTH_TTL=168h
```

Notas sobre estas variables:

- `DOZZLE_PORT=8088` publica la UI web de Dozzle en el host.
- `DOZZLE_HOSTNAME=rpi5-homelab` cambia el nombre mostrado en la cabecera y ayuda a identificar la instancia.
- `DOZZLE_LEVEL=info` deja un nivel de log razonable para operación normal.
- `DOZZLE_AUTH_TTL=168h` mantiene la cookie de sesión durante 7 días, útil en un homelab privado.

Fichero `compose.yaml`:

```yaml
name: dozzle

services:
  dozzle:
    image: amir20/dozzle:latest
    restart: unless-stopped
    env_file:
      - .env
    environment:
      TZ: ${TZ}
      DOZZLE_HOSTNAME: ${DOZZLE_HOSTNAME}
      DOZZLE_LEVEL: ${DOZZLE_LEVEL}
      DOZZLE_AUTH_PROVIDER: simple
      DOZZLE_AUTH_TTL: ${DOZZLE_AUTH_TTL}
      DOZZLE_NO_ANALYTICS: "true"
    ports:
      - "${DOZZLE_PORT}:8080"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /home/<usuario>/homelab/data/dozzle/data:/data
    networks:
      - default
      - shared
    healthcheck:
      test: ["CMD", "/dozzle", "healthcheck"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 20s
    security_opt:
      - no-new-privileges:true

networks:
  shared:
    external: true
    name: homelab_shared
```

Despliegue inicial:

```bash
mkdir -p /home/<usuario>/homelab/compose/dozzle
mkdir -p /home/<usuario>/homelab/data/dozzle/data

sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/compose/dozzle
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/data/dozzle

docker run --rm amir20/dozzle:latest generate admin \
  --password '<cambia-esta-password>' \
  --email '<tu-email>' \
  --name 'Administrador' \
  > /home/<usuario>/homelab/data/dozzle/data/users.yml

chmod 700 /home/<usuario>/homelab/data/dozzle/data
chmod 600 /home/<usuario>/homelab/data/dozzle/data/users.yml

cd /home/<usuario>/homelab/compose/dozzle
docker compose config
docker compose pull
docker compose up -d
docker compose ps
```

Resultado esperado:

- el contenedor `dozzle-dozzle-1` queda levantado
- la UI queda accesible en `http://<IP-del-host>:8088`
- Dozzle puede leer los logs de los contenedores locales a través de `docker.sock`
- el usuario definido en `users.yml` puede autenticarse en la interfaz web

## Configuración

### Objetivo de esta fase

| Elemento | Estado esperado |
|---|---|
| UI local | `http://<IP-del-host>:8088` |
| Persistencia de Dozzle | `/home/<usuario>/homelab/data/dozzle/data/` |
| Stack Compose | `/home/<usuario>/homelab/compose/dozzle/` |
| Autenticación | `simple` con `users.yml` |
| Red entre stacks | `homelab_shared` |
| Función principal | consulta de logs en tiempo real |

### 1. Preparar directorios y permisos

Crear las rutas del stack y de la persistencia:

```bash
mkdir -p /home/<usuario>/homelab/compose/dozzle
mkdir -p /home/<usuario>/homelab/data/dozzle/data
```

Permisos recomendados:

```bash
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/compose/dozzle
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/data/dozzle
chmod 755 /home/<usuario>/homelab/data/dozzle
chmod 700 /home/<usuario>/homelab/data/dozzle/data
```

Dozzle guarda en `/data` su configuración interna y, si activas autenticación simple, también leerá desde ahí `users.yml`. Aunque la aplicación es muy ligera, conviene persistir esta ruta para no perder usuarios ni ajustes al recrear el contenedor.

### 2. Entender qué monta Dozzle y por qué

Este stack monta dos elementos importantes:

- `/var/run/docker.sock:/var/run/docker.sock` para consultar contenedores y leer sus logs
- `/home/<usuario>/homelab/data/dozzle/data:/data` para persistir configuración y fichero de usuarios

El punto delicado es `docker.sock`. En la práctica, quien puede hablar con el socket de Docker tiene capacidad muy amplia sobre el host. Por eso en este homelab la política recomendada es:

- mantener Dozzle solo en **LAN + Tailscale**
- no abrir puertos en el router
- activar autenticación simple
- dejar desactivadas las acciones y el acceso a shell

Dozzle soporta detener, reiniciar contenedores o abrir shells, pero esas capacidades vienen **deshabilitadas por defecto** y no se habilitan en esta guía.

### 3. Crear `users.yml` para autenticación simple

La opción más razonable para este homelab es `DOZZLE_AUTH_PROVIDER=simple`. Evita dejar la UI abierta a cualquiera que llegue por LAN o Tailscale y no obliga a montar un proxy externo adicional.

Comando recomendado para generar el usuario inicial:

```bash
docker run --rm amir20/dozzle:latest generate admin \
  --password '<cambia-esta-password>' \
  --email '<tu-email>' \
  --name 'Administrador' \
  > /home/<usuario>/homelab/data/dozzle/data/users.yml
```

Revisar el contenido generado:

```bash
sed -n '1,80p' /home/<usuario>/homelab/data/dozzle/data/users.yml
```

Estructura esperada:

```yaml
users:
  admin:
    email: <tu-email>
    name: Administrador
    password: <hash-bcrypt>
    filter:
    roles:
```

Notas prácticas:

- la contraseña queda almacenada como hash bcrypt, no en texto plano
- si dejas `filter` vacío, el usuario verá todos los contenedores del host
- si dejas `roles` vacío, no estás habilitando acciones ni shell mientras el stack no active esas funciones

### 4. Desplegar Dozzle

Una vez guardados `compose.yaml`, `.env` y `users.yml`:

```bash
cd /home/<usuario>/homelab/compose/dozzle
docker compose up -d
```

Comprobaciones útiles:

```bash
docker compose ps
docker compose logs -f
ss -tulpn | grep 8088
curl -I http://127.0.0.1:8088/healthcheck
```

Resultados esperados:

- `ss` muestra el puerto `8088` escuchando en el host
- `curl` devuelve `HTTP/1.1 200 OK`
- el contenedor aparece como `healthy` al cabo de unos segundos

Abrir en navegador:

```text
http://<IP-del-host>:8088
```

En el primer acceso, Dozzle debería pedir autenticación con el usuario definido en `users.yml`.

### 5. Uso básico recomendado en el homelab

Dozzle está pensado para diagnóstico rápido. Los usos más prácticos en este entorno son:

- revisar por qué un contenedor entra en bucle de reinicio
- confirmar errores de permisos sobre volúmenes del NVMe o de discos USB
- inspeccionar fallos de conexión entre stacks en `homelab_shared`
- validar arranques y mensajes de inicialización después de actualizar imágenes

Flujo típico:

1. Abrir Dozzle.
2. Buscar el contenedor afectado.
3. Revisar la cola del log en tiempo real.
4. Corregir el problema.
5. Volver a observar si desaparecen errores tras recrear el stack.

Para análisis histórico o correlación avanzada, Dozzle se queda corto. En ese caso conviene volver a `docker compose logs`, `docker logs` o a una solución específica de agregación si el homelab crece.

### 6. Integración operativa recomendada

Aunque Dozzle no expone métricas como Prometheus, sí encaja bien en la operativa diaria de la fase:

- **Prometheus** y **Grafana** te dicen que algo va mal
- **Uptime Kuma** te avisa de que un servicio ha caído o no responde
- **Dozzle** te enseña rápidamente el log del contenedor que está fallando

Si quieres vigilar que la UI de Dozzle siga viva, puedes añadir en `docs/05-monitorizacion/05-uptime-kuma.md` un monitor HTTP usando:

```text
http://dozzle:8080/healthcheck
```

Eso funciona si ambos stacks comparten `homelab_shared`.

### 7. Endurecimiento mínimo recomendado

Dozzle debe seguir siendo una herramienta auxiliar, no una puerta de administración abierta.

Buenas prácticas para este homelab:

- no eliminar la autenticación simple salvo que la instancia quede totalmente aislada
- no habilitar `DOZZLE_ENABLE_ACTIONS=true`
- no habilitar `DOZZLE_ENABLE_SHELL=true`
- no publicarlo fuera de LAN o Tailscale
- revisar periódicamente qué usuarios existen en `users.yml`
- mantener copia de seguridad del directorio `/data`

Si más adelante necesitas SSO o control de acceso externo, Dozzle también soporta autenticación por forward proxy, pero para este escenario local la autenticación simple es suficiente y mucho más sencilla de operar.

## Almacenamiento

| Elemento | Ruta recomendada | Disco |
|---|---|---|
| Stack Compose de Dozzle | `/home/<usuario>/homelab/compose/dozzle/` | SSD NVMe |
| Variables del stack | `/home/<usuario>/homelab/compose/dozzle/.env` | SSD NVMe |
| Persistencia interna de Dozzle | `/home/<usuario>/homelab/data/dozzle/data/` | SSD NVMe |
| Fichero de usuarios | `/home/<usuario>/homelab/data/dozzle/data/users.yml` | SSD NVMe |
| Backups del stack y persistencia | `/mnt/hd2t/backups/...` | `hd2t` |

Notas de almacenamiento:

- Dozzle no almacena los logs de Docker en `/data`; solo muestra logs en tiempo real
- la persistencia sirve sobre todo para ajustes internos, datos auxiliares y autenticación
- `hd2t` es un destino razonable para copias de seguridad de este stack
- `hd5t` no interviene en Dozzle

## Backup
Respaldar como mínimo:

- `/home/<usuario>/homelab/compose/dozzle/compose.yaml`
- `/home/<usuario>/homelab/compose/dozzle/.env`
- `/home/<usuario>/homelab/data/dozzle/data/users.yml`
- `/home/<usuario>/homelab/data/dozzle/data/`

Lo más importante es conservar:

- `users.yml`
- cualquier ajuste persistido por la aplicación en `/data`

Para una copia más conservadora:

```bash
cd /home/<usuario>/homelab/compose/dozzle
docker compose stop
```

Después del backup o de una restauración:

```bash
cd /home/<usuario>/homelab/compose/dozzle
docker compose up -d
```

No es necesario respaldar:

- la imagen `amir20/dozzle`
- el contenedor recreable
- la red `homelab_shared`
- los logs de contenedores mostrados en pantalla, porque Dozzle no los persiste como histórico propio

Si pierdes solo el directorio `/data`, podrás recrear el stack, pero perderás usuarios y cualquier configuración persistida por la aplicación.

## Referencias
- Documentación oficial de Dozzle: <https://dozzle.dev/guide/getting-started>
- Autenticación oficial: <https://dozzle.dev/guide/authentication>
- Variables de entorno soportadas: <https://dozzle.dev/guide/supported-env-vars>
- Healthcheck oficial: <https://dozzle.dev/guide/healthcheck>
- Repositorio oficial: <https://github.com/amir20/dozzle>
- Imagen Docker oficial: <https://hub.docker.com/r/amir20/dozzle>
