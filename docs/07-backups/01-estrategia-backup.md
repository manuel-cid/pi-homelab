# Estrategia de Backup

## Descripción

Este documento define la estrategia de copias de seguridad del homelab siguiendo el criterio **3-2-1**: mantener los datos operativos en el **SSD NVMe**, generar una copia local en **`hd2t`** y replicar una copia cifrada a un destino **offsite**. El objetivo no es respaldar contenedores efímeros, sino poder **reconstruir el homelab** tras un fallo del SSD, un borrado accidental o corrupción de datos.

La política de este proyecto se mantiene:

- el **SSD NVMe** es la fuente principal de verdad para sistema, `compose`, configuraciones, volúmenes persistentes y bases de datos
- el **subdirectorio `/media/hd2t/backups/`** dentro del mismo sistema de ficheros de `hd2t` es el destino local
- **`hd5t`** sigue reservado a la biblioteca multimedia dedicada

Esta fase documenta la **estrategia general**. El despliegue concreto de la herramienta se cubre en [02-borgmatic.md](02-borgmatic.md) y el procedimiento detallado para volúmenes y bases de datos en [03-backup-docker-volumes.md](03-backup-docker-volumes.md).

Cuando este documento usa la ruta **`/home/<user>/homelab/`**, **`<user>`** representa el usuario real de Linux con el que se administra la Raspberry Pi.

## Requisitos Previos

- Haber completado [04-estructura-directorios.md](../01-sistema/04-estructura-directorios.md).
- Tener montado **`hd2t`** en **`/media/hd2t`** y operativo para escritura.
- Tener al menos un servicio con datos persistentes desplegado o, como mínimo, definida la estructura de rutas bajo **`/home/<user>/homelab/data/`**.
- Tener espacio libre suficiente en `hd2t` para almacenar varias versiones deduplicadas de los datos del NVMe.
- Disponer de un destino remoto para la copia offsite accesible mediante conexiones salientes desde la Raspberry Pi, sin abrir puertos entrantes en el router.

## Objetivo de esta Fase

Al terminar este documento, el criterio operativo debe quedar fijado así:

- el homelab respalda **datos operativos y recuperables**, no contenedores efímeros
- existe un destino local en **`/media/hd2t/backups/`**
- existe un segundo destino **offsite** cifrado
- la frecuencia, retención y verificación de restauración quedan definidas antes de automatizar Borgmatic
- cada servicio futuro sabrá si sus datos entran en backup y con qué prioridad

## Docker Compose

No aplica en este documento. Aquí se define la política de backup; el despliegue del stack y la configuración YAML se documentan en [02-borgmatic.md](02-borgmatic.md).

## Configuración

### 1. Adoptar el criterio 3-2-1 para este homelab

La interpretación concreta de **3-2-1** en este proyecto es:

- **3 copias**: datos en producción en el **SSD NVMe**, copia local en **`hd2t`**, copia remota cifrada fuera de casa
- **2 soportes distintos**: NVMe interno y disco USB externo
- **1 copia offsite**: repositorio cifrado en la nube o en un servidor remoto accesible solo mediante conexiones salientes

Este diseño reduce tres riesgos distintos:

- fallo del **SSD NVMe**
- borrado accidental o corrupción lógica detectada a tiempo
- pérdida física del equipo o del disco local de backups

### 2. Delimitar qué entra en backup

La prioridad de backup es recuperar la **capacidad operativa** del homelab, no clonar de forma indiscriminada todos los discos.

#### Datos que sí deben entrar

- `/home/<user>/homelab/compose/`
- `/home/<user>/homelab/config/`
- `/home/<user>/homelab/.env`
- `/home/<user>/homelab/scripts/`
- `/home/<user>/homelab/data/<servicio>/` para todos los servicios con estado
- dumps consistentes de bases de datos generados antes del backup
- ficheros pequeños del host que aceleren una recuperación, por ejemplo `fstab`, configuración de Docker o notas operativas si decides guardarlas fuera de `homelab/`

Servicios y categorías que normalmente generan datos a proteger:

- bases de datos y configuración de **Authelia**, **Vaultwarden**, **Grafana**, **Prometheus**, **Uptime Kuma**, **Pi-hole**, **Syncthing** y otros servicios de infraestructura
- metadatos, bibliotecas, índices, preferencias y credenciales de servicios multimedia
- cualquier secreto o fichero `.env` no reconstruible a partir de Git o documentación

#### Datos que no deben entrar por defecto

- imágenes Docker descargadas
- contenedores recreables
- cachés, transcodes, thumbnails regenerables y ficheros temporales
- descargas incompletas o colas transitorias
- bibliotecas multimedia masivas en `/media/hd2t/media/`
- contenido multimedia en `/media/hd5t/media/`

Excluir estas rutas reduce tiempo de backup, consumo de espacio y riesgo de llenar `hd2t` con datos que no son críticos para recuperar el servicio.

### 3. Diferenciar datos operativos de contenido multimedia

La estrategia base de esta fase **protege ante todo el estado del homelab**, porque ese estado vive en el NVMe. Esto incluye:

- configuraciones
- bases de datos
- metadatos
- credenciales
- uploads y ficheros funcionales pequeños

En cambio, las colecciones multimedia grandes de `hd2t` y `hd5t` tienen otra naturaleza:

- ocupan mucho espacio
- cambian menos a nivel estructural
- no son adecuadas para copiarse en el mismo `hd2t` que hace de destino local

Por tanto, la política recomendada es esta:

- **sí** respaldar el estado de las aplicaciones que indexan o describen ese contenido
- **no** intentar respaldar rutinariamente toda la media grande con el mismo flujo Borg hacia `hd2t`
- si cierta media es irremplazable, definir una política separada de replicación o copia selectiva fuera del alcance base de este documento

### 4. Fijar los destinos de backup

La estructura recomendada queda así dentro del disco **`hd2t`**, usando el árbol definido en `SERVICES.md`:

```text
/media/hd2t/backups/
├── borg/
│   └── <hostname>/
├── exports/
│   └── <servicio>/
└── restore-test/
```

Uso de cada ruta:

- `borg/`: repositorios locales de Borg gestionados por Borgmatic
- `exports/`: dumps temporales o persistidos de bases de datos si decides conservarlos aparte del repositorio
- `restore-test/`: restauraciones de validación para comprobar que las copias realmente sirven

El disco `hd2t` no dispone de una partición exclusiva para backups; se utiliza el subdirectorio `/media/hd2t/backups/` dentro del mismo sistema de ficheros. Es importante no mezclar este árbol con media ni descargas para evitar que un crecimiento inesperado de otra carpeta comprometa el espacio disponible para las copias.

Para la copia offsite, usa un repositorio remoto distinto del local y con credenciales separadas. El detalle técnico del proveedor no se fija aquí; la condición importante es que soporte una **copia cifrada y automatizable** desde la Raspberry Pi usando solo conexiones salientes, sin abrir puertos entrantes y sin exponer servicios del homelab a internet.

### 5. Fijar la programación recomendada

La frecuencia debe ser realista para una Raspberry Pi 5 y suficiente para servicios personales con cambios diarios.

Programación recomendada:

- **cada noche**: snapshot de archivos hacia el repositorio local, precedido por los dumps consistentes que correspondan
- **después del backup local o en una segunda ventana nocturna**: réplica al destino offsite
- **antes de cada backup**: generación de dumps consistentes de MariaDB/PostgreSQL y cualquier export crítico equivalente
- **una vez por semana**: `prune` para aplicar retención
- **una vez al mes**: `check` del repositorio y prueba simple de restauración

Ventana sugerida para la copia local y el mantenimiento:

- `02:30`: hooks previos y backup local
- `domingo 04:30`: `prune`
- `domingo 04:45`: compactación
- `día 1 de cada mes 05:00`: verificación y restore test

La réplica offsite puede ejecutarse justo después del backup local o en una ventana separada mientras siga siendo nocturna y no compita con tareas interactivas. La implementación exacta queda para [02-borgmatic.md](02-borgmatic.md).

No hace falta inventar una política más agresiva salvo que alojes datos con cambios horarios o requisitos más estrictos.

### 6. Definir la retención

La retención debe equilibrar historial útil y espacio disponible en `hd2t`.

Retención recomendada:

| Destino | Diarias | Semanales | Mensuales |
|---------|---------|-----------|-----------|
| Local en `hd2t` | 14 | 8 | 6 |
| Offsite | 7 | 4 | 6 |

Criterio práctico:

- el repositorio local conserva más historial para recuperaciones rápidas
- el repositorio offsite prioriza cobertura ante desastre, no histórico largo
- si el crecimiento real del repositorio se dispara, reduce primero las diarias antes que eliminar las mensuales

### 7. Exigir verificaciones de restauración

Un backup no se considera válido solo porque termine sin errores. Debe poder **restaurarse**.

Verificación mínima obligatoria:

- revisar el código de salida y las notificaciones tras cada ejecución
- restaurar **mensualmente** uno o varios ficheros a `/media/hd2t/backups/restore-test/`
- restaurar **trimestralmente** el estado completo de un servicio con datos, incluyendo dump de base de datos y volumen asociado
- documentar incidencias de permisos, usuarios, `UID/GID`, rutas rotas o secretos faltantes

El objetivo de la prueba trimestral no es solo extraer archivos, sino comprobar que un servicio puede volver a arrancar con datos restaurados.

### 8. Aplicar reglas operativas claras

Estas reglas deben mantenerse en todas las fases posteriores:

- el backup debe leer los datos desde el **SSD NVMe**, no desde los contenedores efímeros
- las bases de datos deben respaldarse mediante **dump consistente** además del volumen cuando aplique
- la restauración debe poder hacerse sin depender de que el contenedor original siga vivo
- cualquier nuevo servicio con estado debe declarar su apartado **Backup** en su documento y quedar incorporado a Borgmatic
- el destino local de backup no debe compartir ruta con media general ni con descargas

## Almacenamiento

Distribución operativa de la estrategia:

- **Origen principal**
  - `/home/<user>/homelab/compose/`
  - `/home/<user>/homelab/config/`
  - `/home/<user>/homelab/.env`
  - `/home/<user>/homelab/scripts/`
  - `/home/<user>/homelab/data/<servicio>/`
- **Destino local**
  - `/media/hd2t/backups/borg/`
  - `/media/hd2t/backups/exports/`
  - `/media/hd2t/backups/restore-test/`
- **Fuera de alcance de la rutina base**
  - `/media/hd2t/media/`
  - `/media/hd2t/downloads/`
  - `/media/hd5t/media/`

Regla importante:

- el **estado recuperable del homelab** vive en el **NVMe**
- el **repositorio local de backup** vive en `hd2t`
- el **contenido multimedia grande** no debe mezclarse con la política base de recuperación del sistema

## Backup

Resumen de prioridades a proteger:

### Prioridad 1

- configuraciones del homelab
- archivos `compose`
- ficheros `.env`
- secretos y credenciales
- bases de datos y volúmenes persistentes de servicios críticos

### Prioridad 2

- exports administrativos
- scripts operativos
- configuraciones puntuales del host que no estén ya en `/home/<user>/homelab/`

### Prioridad 3

- metadatos o catálogos reconstruibles pero costosos de regenerar

Elementos excluidos por defecto:

- media grande
- descargas temporales
- cachés
- artefactos regenerables

Implementación siguiente:

- estrategia y política general: este documento
- automatización con Borgmatic: [02-borgmatic.md](02-borgmatic.md)
- procedimiento de dumps y restore de volúmenes: [03-backup-docker-volumes.md](03-backup-docker-volumes.md)

## Referencias

- [04-estructura-directorios.md](../01-sistema/04-estructura-directorios.md)
- [01-samba.md](../06-almacenamiento/01-samba.md)
- [02-borgmatic.md](02-borgmatic.md)
- [03-backup-docker-volumes.md](03-backup-docker-volumes.md)
- Documentación oficial de BorgBackup: https://www.borgbackup.org/
- Documentación oficial de Borgmatic: https://torsion.org/borgmatic/
