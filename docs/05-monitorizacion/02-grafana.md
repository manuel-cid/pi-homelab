# Grafana

## Descripción
**Grafana** será la interfaz principal de visualización del homelab. Su función es consultar las métricas almacenadas en **Prometheus** y presentarlas en dashboards útiles para vigilar el estado de la **Raspberry Pi 5**, del host Linux y de los contenedores Docker.

En esta fase Grafana se despliega como un stack propio, persistiendo su configuración y base de datos interna en el **SSD NVMe**. La integración recomendada es:

- datasource principal: **Prometheus**
- dashboards base: **Node Exporter Full** y uno de **cAdvisor/Docker**
- paneles específicos para temperatura de la Raspberry Pi

La idea es que Grafana quede accesible solo en **LAN + Tailscale**, igual que el resto del homelab, sin exponerlo a internet.

## Requisitos Previos
- Haber completado `docs/02-docker/01-instalacion-docker.md`.
- Haber completado `docs/02-docker/02-estructura-compose.md`.
- Haber completado `docs/01-sistema/04-estructura-directorios.md`.
- Haber completado `docs/05-monitorizacion/01-prometheus.md`.
- Tener creada la red Docker externa `homelab_shared`.
- Tener claro que este homelab solo se expone en **LAN + Tailscale**, sin publicación a internet.
- Tener previsto almacenar configs y datos persistentes en el SSD NVMe:
  - `/home/<usuario>/homelab/compose`
  - `/home/<usuario>/homelab/data`
- Puertos implicados:
  - `3000/tcp` publicado en el host para la interfaz web de Grafana
  - `9090/tcp` accesible en la red Docker compartida para que Grafana llegue a Prometheus mediante `http://prometheus:9090`

## Docker Compose
Directorio recomendado:

```text
/home/<usuario>/homelab/compose/grafana/
├── compose.yaml
├── .env
└── provisioning/
    └── datasources/
        └── prometheus.yaml
```

Fichero `.env` recomendado:

```dotenv
TZ=Europe/Madrid
GRAFANA_PORT=3000
GRAFANA_ADMIN_USER=admin
GRAFANA_ADMIN_PASSWORD=<cambia-esta-password>
GRAFANA_ROOT_URL=http://<IP-del-host>:3000
```

Notas sobre estas variables:

- `GRAFANA_PORT=3000` publica la UI local de Grafana.
- `GRAFANA_ADMIN_USER` y `GRAFANA_ADMIN_PASSWORD` definen la cuenta inicial.
- `GRAFANA_ROOT_URL` debe reflejar la URL real con la que accederás a Grafana por LAN o Tailscale.
- Si accedes por Tailscale, puedes sustituir el valor por algo como `http://<nombre-o-ip-tailscale>:3000`.

Fichero `provisioning/datasources/prometheus.yaml`:

```yaml
apiVersion: 1

prune: true

datasources:
  - name: Prometheus
    uid: prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    editable: false
    jsonData:
      httpMethod: POST
      prometheusType: Prometheus
      timeInterval: 30s
```

Fichero `compose.yaml`:

```yaml
name: grafana

services:
  grafana:
    image: grafana/grafana:latest
    restart: unless-stopped
    env_file:
      - .env
    environment:
      TZ: ${TZ}
      GF_SERVER_ROOT_URL: ${GRAFANA_ROOT_URL}
      GF_SECURITY_ADMIN_USER: ${GRAFANA_ADMIN_USER}
      GF_SECURITY_ADMIN_PASSWORD: ${GRAFANA_ADMIN_PASSWORD}
      GF_USERS_ALLOW_SIGN_UP: "false"
    ports:
      - "${GRAFANA_PORT}:3000"
    volumes:
      - /home/<usuario>/homelab/data/grafana/data:/var/lib/grafana
      - ./provisioning:/etc/grafana/provisioning:ro
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
mkdir -p /home/<usuario>/homelab/compose/grafana/provisioning/datasources
mkdir -p /home/<usuario>/homelab/data/grafana/data

sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/compose/grafana
sudo chown -R 472:472 /home/<usuario>/homelab/data/grafana/data

cd /home/<usuario>/homelab/compose/grafana
docker compose config
docker compose pull
docker compose up -d
docker compose ps
```

Resultado esperado:

- el contenedor `grafana-grafana-1` queda levantado
- la UI queda accesible en `http://<IP-del-host>:3000`
- el datasource `Prometheus` aparece creado automáticamente
- Grafana puede consultar Prometheus usando `http://prometheus:9090` dentro de `homelab_shared`

## Configuración

### Objetivo de esta fase

| Elemento | Estado esperado |
|---|---|
| UI local | `http://<IP-del-host>:3000` |
| Persistencia de Grafana | `/home/<usuario>/homelab/data/grafana/data/` |
| Provisioning del datasource | `/home/<usuario>/homelab/compose/grafana/provisioning/datasources/prometheus.yaml` |
| Datasource por defecto | `Prometheus` |
| Red entre stacks | `homelab_shared` |
| Dashboards base | sistema, contenedores y temperatura Pi |

### 1. Preparar directorios y permisos

Crear las rutas del stack y de la persistencia:

```bash
mkdir -p /home/<usuario>/homelab/compose/grafana/provisioning/datasources
mkdir -p /home/<usuario>/homelab/data/grafana/data
```

Permisos recomendados:

```bash
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/compose/grafana
sudo chown -R 472:472 /home/<usuario>/homelab/data/grafana/data
chmod 755 /home/<usuario>/homelab/data/grafana
chmod 700 /home/<usuario>/homelab/data/grafana/data
```

La imagen oficial escribe su estado en `/var/lib/grafana`. En un bind mount resulta más predecible asignar el directorio del host al UID/GID `472:472`, que es el usuario usado por Grafana dentro del contenedor.

### 2. Entender qué guarda Grafana en el NVMe

El directorio `/home/<usuario>/homelab/data/grafana/data/` contendrá:

- la base SQLite interna de Grafana
- usuarios locales y credenciales internas
- dashboards creados o importados desde la UI
- alertas, preferencias y metadatos del sistema

Igual que con Prometheus, esta persistencia activa debe quedarse en el **SSD NVMe**:

- mejora tiempos de carga y respuesta de dashboards
- evita depender de un disco USB externo para la UI de monitorización
- mantiene separadas las métricas y la configuración operativa del almacenamiento multimedia

En este proyecto la norma sigue siendo la misma: **servicios, configuraciones y datos persistentes en NVMe; bibliotecas grandes y backups pesados en HDD**.

### 3. Crear el datasource de Prometheus por provisioning

El enfoque recomendado en este homelab es no crear el datasource a mano desde la UI, sino aprovisionarlo con YAML.

Ventajas:

- el stack queda reproducible
- si recreas el contenedor, el datasource vuelve solo
- evitas errores típicos como usar `localhost:9090` dentro de Grafana

El punto clave es esta URL:

```text
http://prometheus:9090
```

No debe usarse `http://localhost:9090` porque dentro del contenedor `localhost` apunta al propio Grafana, no al stack de Prometheus.

### 4. Desplegar Grafana

Una vez guardados `compose.yaml`, `.env` y `provisioning/datasources/prometheus.yaml`:

```bash
cd /home/<usuario>/homelab/compose/grafana
docker compose up -d
```

Comprobaciones útiles:

```bash
docker compose ps
docker compose logs -f
ss -tulpn | grep 3000
```

Abrir en navegador:

```text
http://<IP-del-host>:3000
```

Primer acceso:

- usuario: valor de `GRAFANA_ADMIN_USER`
- contraseña: valor de `GRAFANA_ADMIN_PASSWORD`

Si Grafana solicita cambio de contraseña en el primer login, puedes hacerlo en ese momento y después actualizar también el `.env` para mantener coherencia documental.

### 5. Verificar el datasource Prometheus

En la UI de Grafana revisa:

- **Connections > Data sources**
- debe aparecer `Prometheus`
- debe figurar como datasource por defecto

Si entras al datasource, el origen debe ser:

```text
http://prometheus:9090
```

Si algo falla, revisa primero:

- que el stack de `prometheus` siga levantado
- que ambos stacks estén unidos a `homelab_shared`
- que el nombre del servicio siga siendo `prometheus`

### 6. Dashboards recomendados para este homelab

Los dashboards mínimos recomendados en esta fase son tres:

#### 6.1 Node Exporter Full

Útil para:

- CPU
- memoria
- uso de disco
- carga del sistema
- red
- sensores del host si Node Exporter los expone

Recomendación:

- importar **Node Exporter Full**
- ID habitual de importación: `1860`

Importación:

1. Ir a **Dashboards > New > Import**
2. Introducir el ID `1860`
3. Seleccionar el datasource `Prometheus`
4. Guardar

Importante para este proyecto:

- el ejemplo de `docs/05-monitorizacion/01-prometheus.md` usa el job `node-exporter`
- algunos dashboards comunitarios esperan `job="node"`

Si el dashboard importa correctamente pero algunos paneles quedan vacíos, revisa sus variables o consultas y ajusta el job al valor real de este homelab:

```text
node-exporter
```

Cuando exista el documento `docs/05-monitorizacion/03-node-exporter.md`, ese valor deberá mantenerse consistente entre exporter, Prometheus y Grafana.

#### 6.2 Dashboard de Docker / cAdvisor

Útil para:

- CPU por contenedor
- memoria por contenedor
- tráfico de red
- actividad general de los servicios Docker

Recomendación:

- importar un dashboard basado en métricas de **cAdvisor**
- una opción sencilla para empezar es **Cadvisor exporter**
- ID habitual de importación: `14282`

Si usas el job definido en el documento de Prometheus de esta fase, el valor esperado es:

```text
cadvisor
```

Cuando exista el documento `docs/05-monitorizacion/04-cadvisor.md`, ese job no debería cambiar para evitar romper dashboards ya importados.

#### 6.3 Temperatura de la Raspberry Pi

Para la Raspberry Pi 5 conviene tener al menos un panel dedicado a temperatura. La forma más simple es crear un dashboard propio en vez de depender de uno comunitario.

Consulta recomendada si Node Exporter expone el collector `thermal_zone`:

```promql
node_thermal_zone_temp{job="node-exporter"} 
```

El collector devuelve la temperatura en grados Celsius, así que en Grafana basta con:

- elegir unidad `celsius (°C)`
- mostrar la serie por `zone` o filtrar la zona principal de CPU

Si quieres centrarte en una única zona térmica, primero abre **Explore** y comprueba qué etiquetas devuelve la métrica en tu Raspberry Pi.

Una variante típica es:

```promql
node_thermal_zone_temp{job="node-exporter", zone="thermal_zone0"}
```

Resultado esperado:

- un panel sencillo tipo `Stat` o `Time series`
- umbral visual, por ejemplo:
  - verde hasta `65`
  - amarillo entre `65` y `75`
  - rojo por encima de `75`

### 7. Consultas rápidas de validación en Explore

Antes de dar por buena la integración, abre **Explore** y lanza algunas consultas simples:

```promql
up
```

```promql
up{job="prometheus"}
```

```promql
up{job="node-exporter"}
```

```promql
up{job="cadvisor"}
```

Interpretación rápida:

- `prometheus` debería devolver `1`
- `node-exporter` y `cadvisor` pueden devolver `0` o no devolver datos hasta que despliegues esos stacks

Ese comportamiento es coherente con esta fase si todavía no has redactado o desplegado:

- `docs/05-monitorizacion/03-node-exporter.md`
- `docs/05-monitorizacion/04-cadvisor.md`

### 8. Endurecimiento mínimo recomendado

Para este homelab local no hace falta complicar el despliegue con un proxy inverso público, pero sí conviene aplicar estas medidas mínimas:

- cambiar la contraseña inicial de administrador
- desactivar el registro abierto de usuarios, como ya hace `GF_USERS_ALLOW_SIGN_UP=false`
- no publicar Grafana fuera de la LAN ni fuera de Tailscale
- respaldar la base de datos y la configuración antes de cambios mayores

## Almacenamiento

| Elemento | Ruta recomendada | Disco |
|---|---|---|
| Stack Compose de Grafana | `/home/<usuario>/homelab/compose/grafana/` | SSD NVMe |
| Variables del stack | `/home/<usuario>/homelab/compose/grafana/.env` | SSD NVMe |
| Provisioning del datasource | `/home/<usuario>/homelab/compose/grafana/provisioning/datasources/prometheus.yaml` | SSD NVMe |
| Base de datos y estado de Grafana | `/home/<usuario>/homelab/data/grafana/data/` | SSD NVMe |
| Backups del stack y de la base | `/mnt/hd2t/backups/...` | `hd2t` |

Notas de almacenamiento:

- toda la persistencia activa de Grafana debe quedarse en el **NVMe**
- `hd2t` es un buen destino para backups del stack y del directorio de datos
- `hd5t` no interviene en Grafana
- los dashboards importados desde la UI se guardan dentro de la persistencia de Grafana, no en `hd2t`

## Backup
Respaldar como mínimo:

- `/home/<usuario>/homelab/compose/grafana/compose.yaml`
- `/home/<usuario>/homelab/compose/grafana/.env`
- `/home/<usuario>/homelab/compose/grafana/provisioning/datasources/prometheus.yaml`
- `/home/<usuario>/homelab/data/grafana/data/`

Ese último directorio es el más importante porque contiene:

- la base SQLite de Grafana
- dashboards importados
- usuarios y preferencias
- alertas y configuración interna

Para una copia más conservadora:

```bash
cd /home/<usuario>/homelab/compose/grafana
docker compose stop
```

Después del backup o de una restauración:

```bash
cd /home/<usuario>/homelab/compose/grafana
docker compose up -d
```

No es necesario respaldar:

- la imagen `grafana/grafana`
- el contenedor recreable
- la red `homelab_shared`

Si pierdes solo la persistencia de Grafana, podrás reconstruir el stack, pero perderás dashboards creados en la UI, usuarios locales, preferencias y alertas.

## Referencias
- Documentación oficial de Grafana en Docker: <https://grafana.com/docs/grafana/latest/setup-grafana/installation/docker/>
- Provisioning de Grafana: <https://grafana.com/docs/grafana/latest/administration/provisioning/>
- Configuración del datasource Prometheus en Grafana: <https://grafana.com/docs/grafana/latest/datasources/prometheus/configure/>
- Dashboard `Node Exporter Full`: <https://grafana.com/grafana/dashboards/1860-node-exporter-full/>
- Dashboard `Cadvisor exporter`: <https://grafana.com/grafana/dashboards/14282-cadvisor-exporter/>
- Imagen Docker oficial: <https://hub.docker.com/r/grafana/grafana>
- Repositorio oficial: <https://github.com/grafana/grafana>
