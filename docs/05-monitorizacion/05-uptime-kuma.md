# Uptime Kuma

## Descripción
**Uptime Kuma** será el servicio de comprobación activa de disponibilidad del homelab. Su función no es sustituir a **Prometheus** o **Grafana**, sino complementar la monitorización con una vista clara de si cada servicio responde o no desde el punto de vista de red y aplicación.

En este proyecto se usará para:

- comprobar disponibilidad de servicios HTTP, HTTPS, TCP y ping
- detectar caídas visibles desde la LAN o desde la red Docker compartida
- centralizar alertas operativas por **Telegram** y **email**
- mantener un panel sencillo de estado para los servicios más importantes del homelab

Uptime Kuma debe persistir su configuración y su base interna en el **SSD NVMe**, igual que el resto de servicios operativos. No necesita usar `hd2t` ni `hd5t` salvo como destino de backup.

## Requisitos Previos
- Haber completado `docs/02-docker/01-instalacion-docker.md`.
- Haber completado `docs/02-docker/02-estructura-compose.md`.
- Haber completado `docs/01-sistema/04-estructura-directorios.md`.
- Haber completado `docs/05-monitorizacion/01-prometheus.md`, `docs/05-monitorizacion/02-grafana.md`, `docs/05-monitorizacion/03-node-exporter.md` y `docs/05-monitorizacion/04-cadvisor.md` si quieres monitorizar desde el primer día todo el stack base de observabilidad.
- Tener creada la red Docker externa `homelab_shared`.
- Tener claro que este homelab solo se expone en **LAN + Tailscale**, sin publicación a internet.
- Tener previstas las rutas persistentes en el SSD NVMe:
  - `/home/<usuario>/homelab/compose`
  - `/home/<usuario>/homelab/data`
- Puertos implicados:
  - `3001/tcp` publicado en el host para la interfaz web de Uptime Kuma
  - tráfico saliente HTTPS para notificaciones a Telegram
  - tráfico saliente SMTP/SMTPS o submission hacia el servidor de correo que vayas a usar para email

## Docker Compose
Directorio recomendado:

```text
/home/<usuario>/homelab/compose/uptime-kuma/
├── compose.yaml
└── .env
```

Fichero `.env` recomendado:

```dotenv
TZ=Europe/Madrid
UPTIME_KUMA_PORT=3001
```

Notas sobre estas variables:

- `UPTIME_KUMA_PORT=3001` publica la interfaz web local de Uptime Kuma.
- No hace falta exponer puertos adicionales para monitores normales: el contenedor iniciará conexiones salientes hacia los servicios que deba comprobar.

Fichero `compose.yaml`:

```yaml
name: uptime-kuma

services:
  uptime-kuma:
    image: louislam/uptime-kuma:1
    restart: unless-stopped
    env_file:
      - .env
    environment:
      TZ: ${TZ}
    ports:
      - "${UPTIME_KUMA_PORT}:3001"
    volumes:
      - /home/<usuario>/homelab/data/uptime-kuma/data:/app/data
    networks:
      - default
      - shared
    security_opt:
      - no-new-privileges:true

networks:
  shared:
    external: true
    name: homelab_shared
```

Despliegue inicial:

```bash
mkdir -p /home/<usuario>/homelab/compose/uptime-kuma
mkdir -p /home/<usuario>/homelab/data/uptime-kuma/data

sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/compose/uptime-kuma
sudo chown -R 1000:1000 /home/<usuario>/homelab/data/uptime-kuma/data

cd /home/<usuario>/homelab/compose/uptime-kuma
docker compose config
docker compose pull
docker compose up -d
docker compose ps
```

Resultado esperado:

- el contenedor `uptime-kuma-uptime-kuma-1` queda levantado
- la UI queda accesible en `http://<IP-del-host>:3001`
- la persistencia queda en `/home/<usuario>/homelab/data/uptime-kuma/data/`
- Uptime Kuma puede alcanzar otros stacks por nombre interno si comparten `homelab_shared`

## Configuración

### Objetivo de esta fase

| Elemento | Estado esperado |
|---|---|
| UI local | `http://<IP-del-host>:3001` |
| Persistencia de Uptime Kuma | `/home/<usuario>/homelab/data/uptime-kuma/data/` |
| Stack Compose | `/home/<usuario>/homelab/compose/uptime-kuma/` |
| Red entre stacks | `homelab_shared` |
| Canales de alerta | Telegram y email |
| Monitores iniciales | servicios críticos del homelab |

### 1. Preparar directorios y permisos

Crear las rutas del stack y de la persistencia:

```bash
mkdir -p /home/<usuario>/homelab/compose/uptime-kuma
mkdir -p /home/<usuario>/homelab/data/uptime-kuma/data
```

Permisos recomendados:

```bash
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/compose/uptime-kuma
sudo chown -R 1000:1000 /home/<usuario>/homelab/data/uptime-kuma/data
chmod 755 /home/<usuario>/homelab/data/uptime-kuma
chmod 700 /home/<usuario>/homelab/data/uptime-kuma/data
```

La imagen suele trabajar con un usuario sin privilegios y escribir en `/app/data`. Mantener ese bind mount en el NVMe simplifica reinicios, recreaciones del contenedor y restauraciones desde backup.

### 2. Desplegar Uptime Kuma y crear la cuenta inicial

Una vez guardados `compose.yaml` y `.env`:

```bash
cd /home/<usuario>/homelab/compose/uptime-kuma
docker compose up -d
```

Comprobaciones útiles:

```bash
docker compose ps
docker compose logs -f
ss -tulpn | grep 3001
```

Abrir en navegador:

```text
http://<IP-del-host>:3001
```

En el primer acceso Uptime Kuma pedirá crear:

- nombre de usuario administrador
- contraseña de administrador

Recomendaciones mínimas:

- usa una contraseña distinta de otras herramientas del homelab
- guarda esa credencial en tu gestor de secretos
- no expongas el puerto `3001` fuera de la LAN ni fuera de Tailscale

### 3. Elegir bien qué URL monitorizar

La regla operativa más útil en este homelab es esta:

- si un servicio tiene una URL final de acceso para usuarios, monitoriza esa URL real
- si un servicio no tiene proxy o interfaz web final, monitoriza el endpoint interno más estable

Ejemplos prácticos:

| Servicio | Tipo de monitor recomendado | Endpoint sugerido |
|---|---|---|
| Prometheus | HTTP(s) | `http://prometheus:9090/-/ready` |
| Grafana | HTTP(s) | `http://grafana:3000/api/health` |
| Node Exporter | TCP | `node-exporter:9100` |
| cAdvisor | TCP | `cadvisor:8080` |
| Servicio publicado por Caddy | HTTP(s) | `https://servicio.lan` o la URL interna equivalente |
| Servicio sin proxy pero con UI propia | HTTP(s) | `http://<IP-del-host>:<puerto>` |

Notas prácticas:

- para servicios accesibles por Caddy, monitorizar la URL final ayuda a detectar fallos de proxy, DNS local o TLS interno
- para exporters como Node Exporter o cAdvisor, un monitor TCP suele ser suficiente y genera menos ruido que consultar `/metrics`
- si un servicio solo debe ser accesible por Tailscale, también puedes crear un monitor dedicado usando su URL de Tailscale

### 4. Monitores mínimos recomendados por servicio

En esta fase conviene empezar con un conjunto corto y útil de monitores:

| Nombre sugerido | Tipo | Intervalo | Timeout | Comentario |
|---|---|---|---|---|
| `prometheus-ui` | HTTP(s) | `60s` | `10s` | Comprueba la disponibilidad de Prometheus |
| `grafana-ui` | HTTP(s) | `60s` | `10s` | Comprueba la UI principal de dashboards |
| `node-exporter` | TCP | `60s` | `10s` | Verifica que el exporter responde en red |
| `cadvisor` | TCP | `60s` | `10s` | Verifica que el exporter de contenedores está vivo |
| `caddy-servicio-critico` | HTTP(s) | `60s` | `10s` | Comprueba la ruta real de acceso de usuarios |
| `tailscale-servicio-critico` | HTTP(s) | `120s` | `15s` | Útil si quieres validar acceso remoto por VPN |

Para evitar fatiga de alertas:

- no conviertas todos los servicios secundarios en monitores críticos desde el primer día
- empieza por infraestructura, paneles y servicios personales importantes
- agrupa después por etiquetas como `infra`, `media`, `seguridad` o `dns`

### 5. Elegir el monitor correcto según el tipo de servicio

La forma más estable de usar Uptime Kuma en este homelab es decidir el monitor según cómo consume realmente cada servicio el usuario o el resto de stacks.

| Tipo de servicio | Ejemplos del homelab | Monitor recomendado | Qué validar |
|---|---|---|---|
| Panel web principal | Grafana, Portainer, Homepage, BookStack, Linkding, Mealie | HTTP(s) | que la UI responde y devuelve un código correcto |
| Servicio publicado por proxy | Nextcloud, Vaultwarden, Jellyfin, Paperless-ngx, FreshRSS | HTTP(s) sobre la URL final | que funciona el acceso real que usarás por LAN o Tailscale |
| Servicio con endpoint de salud oficial | Prometheus, Nextcloud, MinIO | HTTP(s) al endpoint de health | que la aplicación está operativa, no solo escuchando |
| Exporter o servicio auxiliar sin UI relevante | Node Exporter, cAdvisor | TCP | que el puerto está escuchando y accesible |
| Servicio de red no HTTP | Mosquitto, Samba, Unbound | TCP | que el socket del servicio responde |
| Acceso remoto por VPN | cualquier servicio crítico accesible por Tailscale | HTTP(s) adicional | que el servicio también funciona desde la ruta remota prevista |

Reglas prácticas:

- si existe endpoint de salud oficial, priorízalo frente a la raíz `/`
- si el servicio se usa normalmente detrás de Caddy o de otro proxy, monitoriza primero la URL final y no solo el contenedor interno
- para servicios muy ligeros o puramente auxiliares, TCP suele ser suficiente y reduce ruido
- evita crear dos o tres monitores equivalentes para el mismo servicio salvo que quieras cubrir rutas de acceso distintas, por ejemplo `LAN` y `Tailscale`

### 6. Crear monitores HTTP y TCP desde la UI

Ruta general:

1. Pulsar **Add New Monitor**
2. Elegir tipo de monitor
3. Indicar nombre, URL o host/puerto
4. Ajustar intervalo y timeout
5. Guardar

Ajustes recomendados para HTTP:

- marcar seguimiento de redirecciones si monitorizas una URL final tras proxy
- usar método `GET` salvo que el endpoint requiera otra cosa
- si el servicio devuelve un endpoint de salud específico, usarlo en vez de la raíz

Ajustes recomendados para TCP:

- usarlo para exporters, puertos de administración o servicios donde solo te importe que el socket responda
- reservar los monitores HTTP para donde sí quieras validar lógica básica de aplicación

### 7. Configurar notificaciones por Telegram

Telegram es útil para alertas inmediatas y funciona bien en un homelab pequeño.

Pasos recomendados:

1. Crear un bot con **BotFather**
2. Obtener el **bot token**
3. Enviar al menos un mensaje al bot o al grupo donde vayan a llegar las alertas
4. Obtener el **chat ID** correspondiente
5. En Uptime Kuma ir a **Settings > Notifications**
6. Añadir una notificación de tipo **Telegram**
7. Introducir token y chat ID
8. Ejecutar **Test**

Buenas prácticas:

- usar un chat o grupo dedicado para no mezclar alertas con conversaciones personales
- activar notificaciones solo para monitores importantes al principio
- revisar el texto de prueba antes de asociar la notificación a todos los monitores

Cuándo usarlo en este homelab:

- como canal primario para servicios críticos de infraestructura
- para alertas que quieras ver rápido también desde móvil
- para estados `DOWN` y recuperaciones `UP`, no necesariamente para cada evento menor

### 8. Configurar notificaciones por email

El correo sigue siendo útil para histórico, filtros y recepción redundante frente a Telegram.

Pasos recomendados:

1. Ir a **Settings > Notifications**
2. Añadir una notificación de tipo **SMTP / Email**
3. Configurar como mínimo:
   - host SMTP
   - puerto SMTP
   - seguridad TLS/STARTTLS según tu proveedor
   - usuario y contraseña si aplica
   - remitente
   - destinatario
4. Ejecutar **Test**

Recomendaciones prácticas:

- si usas un relay local o una cuenta específica para el homelab, mejor que reutilizar tu correo principal
- documenta fuera de Uptime Kuma el servidor, puerto y remitente utilizados
- si el envío falla, revisa primero conectividad saliente, credenciales y cifrado SMTP

Cuándo usarlo en este homelab:

- como canal secundario o redundante frente a Telegram
- para conservar un rastro fácil de buscar y filtrar
- para alertas de mantenimiento, resúmenes o servicios no tan urgentes

### 9. Asociar notificaciones y afinar ruido operativo

Una vez creados los canales:

- asigna Telegram a los monitores más críticos
- usa email como canal secundario o redundante
- define un número de reintentos razonable antes de alertar
- evita tiempos de chequeo demasiado agresivos en la Raspberry Pi 5

Valores prudentes para empezar:

- intervalo: `60s`
- reintentos máximos: `2` o `3`
- timeout: `10s`

Eso suele equilibrar detección rápida y bajo ruido en un homelab doméstico.

Una estrategia sencilla para empezar:

- `Telegram` para `prometheus-ui`, `grafana-ui` y el servicio crítico que más uses
- `Email` para todos los monitores de infraestructura y como respaldo silencioso
- etiquetas como `infra`, `apps`, `media` y `vpn` para decidir después a qué grupos aplicar cada notificación

### 10. Verificar funcionamiento real

Pruebas recomendadas:

- detener temporalmente un stack no crítico y confirmar que Uptime Kuma lo marca como `DOWN`
- restaurar el stack y comprobar que vuelve a `UP`
- lanzar el botón **Test** en Telegram y email
- revisar que los monitores usan los nombres y etiquetas correctos

Comprobaciones desde el host:

```bash
cd /home/<usuario>/homelab/compose/uptime-kuma
docker compose logs --tail=100
```

Si un monitor falla pero el servicio parece levantado, revisa en este orden:

- URL exacta o host/puerto configurados
- resolución de nombres en `homelab_shared`
- endpoint de salud elegido
- timeouts demasiado agresivos
- problemas de proxy, DNS local o certificado interno si monitorizas por HTTPS

### 11. Endurecimiento mínimo recomendado

Uptime Kuma no debe convertirse en una superficie innecesaria de exposición.

En esta guía se sigue una política conservadora:

- publicar `3001` solo para uso en LAN o Tailscale
- no exponerlo a internet ni abrir puertos en el router
- usar una contraseña fuerte para la cuenta inicial
- respaldar la persistencia antes de cambios mayores
- no sobrecargar la Pi con decenas de chequeos cada pocos segundos

## Almacenamiento

| Elemento | Ruta recomendada | Disco |
|---|---|---|
| Stack Compose de Uptime Kuma | `/home/<usuario>/homelab/compose/uptime-kuma/` | SSD NVMe |
| Variables del stack | `/home/<usuario>/homelab/compose/uptime-kuma/.env` | SSD NVMe |
| Base de datos y estado de Uptime Kuma | `/home/<usuario>/homelab/data/uptime-kuma/data/` | SSD NVMe |
| Backups del stack y de la persistencia | `/mnt/hd2t/backups/...` | `hd2t` |

Notas de almacenamiento:

- toda la persistencia activa de Uptime Kuma debe quedarse en el **NVMe**
- `hd2t` es un buen destino para copias de seguridad del directorio de datos
- `hd5t` no interviene en este stack
- en `/app/data` se guardan configuración, monitores, credenciales internas y estado histórico básico
- las credenciales de Telegram y SMTP quedan dentro de la persistencia, así que esa ruta debe tratarse como sensible

## Backup
Respaldar como mínimo:

- `/home/<usuario>/homelab/compose/uptime-kuma/compose.yaml`
- `/home/<usuario>/homelab/compose/uptime-kuma/.env`
- `/home/<usuario>/homelab/data/uptime-kuma/data/`

Ese último directorio es el más importante porque contiene:

- la base de datos interna
- monitores y etiquetas
- configuración de notificaciones
- credenciales locales y preferencias de la UI

Para una copia más conservadora:

```bash
cd /home/<usuario>/homelab/compose/uptime-kuma
docker compose stop
```

Después del backup o de una restauración:

```bash
cd /home/<usuario>/homelab/compose/uptime-kuma
docker compose up -d
```

No es necesario respaldar:

- la imagen `louislam/uptime-kuma`
- el contenedor recreable
- la red `homelab_shared`

Destino recomendado en este proyecto:

- copiar el backup resultante a `/mnt/hd2t/backups/uptime-kuma/`

Si pierdes solo la persistencia de Uptime Kuma, podrás recrear el stack, pero perderás monitores, etiquetas, histórico y notificaciones configuradas desde la UI.

## Referencias
- Documentación oficial de Uptime Kuma: <https://uptime.kuma.pet/>
- Repositorio oficial: <https://github.com/louislam/uptime-kuma>
- Guía oficial de Docker Compose: <https://github.com/louislam/uptime-kuma/wiki/%F0%9F%90%B3-Docker-Compose>
- Configuración de notificaciones: <https://github.com/louislam/uptime-kuma/wiki/Notifications>
- Imagen Docker oficial: <https://hub.docker.com/r/louislam/uptime-kuma>
