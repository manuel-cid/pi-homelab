# Estrategia de backup

## Descripción
Este documento define la estrategia de copias de seguridad del homelab sobre la Raspberry Pi 5 siguiendo el principio **3-2-1**:

- **3 copias** de los datos importantes
- **2 soportes o ubicaciones distintas**
- **1 copia fuera del equipo y fuera de casa**

En este proyecto la prioridad no es guardar todo indiscriminadamente, sino proteger primero lo que sería más costoso reconstruir:

- configuraciones del homelab
- ficheros `.env` y secretos locales
- bases de datos
- volúmenes persistentes de los servicios
- documentos y contenido personal irremplazable

La copia **local** se guarda en `hd2t` bajo una ruta dedicada de backups y la copia **offsite** se replica a un destino cloud cifrado. El despliegue concreto de Borgmatic se documenta en `docs/07-backups/02-borgmatic.md` y los procedimientos de dump, backup puntual y restore en `docs/07-backups/03-backup-docker-volumes.md`.

## Requisitos Previos
- Haber completado `docs/01-sistema/04-estructura-directorios.md`.
- Haber completado `docs/02-docker/01-instalacion-docker.md`.
- Haber completado `docs/02-docker/02-estructura-compose.md`.
- Tener montados y accesibles:
  - `/mnt/hd2t`
  - `/mnt/hd5t`
- Tener espacio libre suficiente en `hd2t` para varias generaciones del backup crítico del NVMe.
- Tener decidido el proveedor del destino offsite cifrado.
- Poder usar `sudo` con el usuario administrador del homelab.
- Tener clara esta limitación física:
  - una copia dentro del propio `hd2t` no protege los datos cuyo origen ya está en `hd2t`
  - una copia dentro del propio `hd2t` no protege los datos cuyo origen ya está en `hd5t`
- Puertos implicados:
  - no hace falta abrir puertos entrantes nuevos
  - `443/tcp` saliente si usas un proveedor offsite por HTTPS
  - `22/tcp` saliente si el destino offsite usa SSH
  - acceso local a Docker para ejecutar dumps y restauraciones de prueba

## Docker Compose
No aplica directamente en este documento.

Aquí se define la **política de backup**, no el despliegue del software. El `compose.yaml`, la configuración YAML y la programación real se documentan en `docs/07-backups/02-borgmatic.md`.

## Configuración

### 1. Objetivo de la fase

| Elemento | Estado esperado |
|---|---|
| Estrategia global | 3-2-1 |
| Destino local | `/mnt/hd2t/backups/` |
| Destino offsite | repositorio cifrado en la nube |
| Datos prioritarios | configs, `.env`, dumps de BD, volúmenes persistentes del NVMe |
| Programación | backup local diario + réplica offsite diaria + verificaciones periódicas |
| Retención | diaria, semanal y mensual |
| Verificación | restauraciones de prueba programadas |
| Cobertura real de `hd2t` | solo si el dato se replica fuera de `hd2t` |
| Cobertura real de `hd5t` | requiere un segundo destino independiente |

### 2. Principios de diseño

En este homelab conviene separar muy bien **backup**, **sincronización** y **almacenamiento principal**:

- el **SSD NVMe** contiene sistema, Docker, Compose, configuraciones, bases de datos y datos persistentes de servicios
- `hd2t` contiene multimedia general, descargas y además el área de backups locales
- `hd5t` contiene la biblioteca multimedia de Stash
- el backup local en `hd2t` protege principalmente frente a pérdida o corrupción del **NVMe**
- el destino offsite protege frente a robo, incendio, fallo múltiple o error humano grave

Principios operativos:

- el backup debe ser **automático**
- el backup debe ser **versionado**
- el backup offsite debe ir **cifrado**
- los dumps de bases de datos deben generarse **antes** del snapshot
- la restauración debe probarse con una cadencia definida
- una copia en el mismo disco físico no cuenta como backup real

### 3. Qué datos deben cumplir 3-2-1

No todos los datos del homelab tienen el mismo valor ni el mismo coste de protección. La estrategia recomendada es esta:

| Tipo de dato | Ejemplos | Ubicación origen | Copia local en `hd2t` | Copia offsite | Prioridad |
|---|---|---|---|---|---|
| Configuración crítica | `compose/`, `env/`, scripts, configs de servicios | SSD NVMe | sí | sí | muy alta |
| Secretos locales | `.env`, claves, tokens, secretos Docker | SSD NVMe | sí | sí | muy alta |
| Bases de datos | MariaDB, PostgreSQL, SQLite persistente | SSD NVMe | sí | sí | muy alta |
| Datos persistentes de aplicaciones | volúmenes de Nextcloud, Paperless-ngx, Vaultwarden, BookStack, MinIO, etc. | SSD NVMe | sí | sí | muy alta |
| Documentos personales | uploads, notas, escaneos, bibliotecas propias | SSD NVMe o `hd2t` | sí si el origen está en NVMe | sí | alta |
| Multimedia general reemplazable | películas, series, música redescargable | `hd2t` | no válida en el mismo `hd2t` | opcional | media |
| Biblioteca de Stash | contenido de `hd5t` | `hd5t` | no en esta estrategia base | normalmente no | baja o específica |
| Descargas temporales | torrents incompletos, cachés, transcodes | `hd2t` o SSD NVMe | no | no | baja |

Lectura correcta de la tabla:

- si el dato **nace y vive en el NVMe**, la copia local en `hd2t` sí aporta una segunda copia útil
- si el dato **ya vive en `hd2t`**, copiarlo a otra carpeta del mismo disco no añade protección real
- si el dato **vive en `hd5t`**, necesitas otro disco, otro equipo o un offsite para considerarlo backup real

### 4. Política recomendada por categorías

#### Datos críticos del NVMe

Deben tener siempre:

- una copia primaria en el NVMe
- una copia local versionada en `hd2t`
- una copia cifrada offsite

Aquí entran, por defecto:

- `/home/<usuario>/homelab/compose/`
- `/home/<usuario>/homelab/env/`
- `/home/<usuario>/homelab/scripts/`
- `/home/<usuario>/homelab/data/` de servicios con estado relevante
- dumps de MariaDB y PostgreSQL previos a cada backup

#### Contenido de `hd2t`

Debe separarse en dos grupos:

- **irremplazable**: documentos propios, audio personal, ebooks propios, material difícil de recuperar
- **reemplazable**: descargas, copias de medios recuperables, bibliotecas que puedes volver a obtener

Recomendación:

- lo irremplazable debe replicarse también al destino offsite
- lo reemplazable puede quedarse fuera del offsite para controlar coste y ventana de backup
- no intentes "respaldar `hd2t` en `hd2t`"

#### Contenido de `hd5t`

La biblioteca grande de Stash no entra en la estrategia base 3-2-1 completa porque:

- ocupa mucho espacio
- encarece el destino cloud
- amplía mucho las ventanas de backup
- puede incluir contenido sensible

La recomendación mínima razonable es:

- respaldar la **configuración** y la **base de datos** de Stash si viven en el NVMe
- excluir la biblioteca pesada de `hd5t` salvo que exista un requisito explícito de conservación

Si necesitas proteger `hd5t`, añade un **segundo disco externo dedicado**, un **NAS** o un **segundo destino offsite** independiente.

### 5. Preparar el área local de backups en `hd2t`

La convención del proyecto es reservar una zona dedicada bajo:

```text
/mnt/hd2t/backups/
```

Estructura recomendada:

```text
/mnt/hd2t/backups/
├── borgmatic/
│   ├── local/
│   └── offsite-cache/
├── exports/
│   ├── mariadb/
│   ├── postgresql/
│   ├── inventories/
│   └── volumes/
├── reports/
└── restore-test/
```

Creación inicial:

```bash
sudo mkdir -p \
  /mnt/hd2t/backups/borgmatic/local \
  /mnt/hd2t/backups/borgmatic/offsite-cache \
  /mnt/hd2t/backups/exports/mariadb \
  /mnt/hd2t/backups/exports/postgresql \
  /mnt/hd2t/backups/exports/inventories \
  /mnt/hd2t/backups/exports/volumes \
  /mnt/hd2t/backups/reports \
  /mnt/hd2t/backups/restore-test

sudo chown -R <usuario>:<usuario> /mnt/hd2t/backups
sudo find /mnt/hd2t/backups -type d -exec chmod 2775 {} \;
```

Si prefieres una **partición separada** dentro del disco de 2 TB para aislar backups del resto de contenidos, mantén esta misma jerarquía lógica para no romper la documentación posterior.

### 6. Programación recomendada

La programación debe ser simple, predecible y compatible con una Raspberry Pi 5 que también atiende servicios en producción.

Ventana sugerida:

| Hora | Tarea |
|---|---|
| `02:00` | generar dumps de bases de datos |
| `02:15` | backup local del contenido crítico del NVMe hacia `hd2t` |
| `03:00` | réplica offsite del conjunto crítico |
| domingo `04:00` | prune y compactación |
| primer domingo de mes `05:00` | verificación de integridad |
| primer sábado de trimestre `10:00` | prueba real de restauración |

Motivos de esta ventana:

- reduce interferencias con el uso normal del homelab
- deja margen a los dumps antes del backup
- evita coincidir con picos de streaming o descargas
- simplifica la revisión de alertas y fallos

Reglas prácticas:

- primero se escribe la copia **local**
- después se replica al destino **offsite**
- si falla el backup local, el offsite no debe darse por bueno

### 7. Retención recomendada

La retención debe equilibrar espacio, capacidad de volver atrás y tiempo de restauración.

Política sugerida para datos críticos:

| Destino | Diarias | Semanales | Mensuales |
|---|---|---|---|
| Local en `hd2t` | 14 | 8 | 12 |
| Offsite | 7 | 4 | 6 |

Interpretación:

- las **diarias** cubren errores recientes y borrados accidentales
- las **semanales** cubren cambios detectados tarde
- las **mensuales** cubren corrupción silenciosa o recuperación histórica razonable

Para dumps sueltos en `exports/`:

- conservar entre **7 y 14 días**
- no convertir `exports/` en el backup principal
- usarlos como apoyo para restauraciones rápidas y verificaciones

Para multimedia grande:

- si decides incluir una parte en offsite, usa retención más corta o calendario semanal
- no sacrifiques la retención del contenido crítico por intentar meter bibliotecas masivas poco prioritarias

### 8. Verificación de restauración

Un backup no se considera válido hasta que se restaura con éxito.

Comprobaciones mínimas recomendadas:

1. **Diaria**
   - revisar que el job terminó sin error
   - confirmar fecha del último backup local y offsite
2. **Mensual**
   - validar integridad del repositorio
   - restaurar una muestra pequeña de archivos a `restore-test/`
3. **Trimestral**
   - restaurar un servicio completo en una ruta temporal o stack de prueba
   - comprobar permisos, consistencia y arranque correcto
4. **Anual**
   - ejecutar un simulacro más amplio de recuperación del homelab crítico

Qué debes ser capaz de restaurar sin improvisar:

- un fichero de configuración concreto
- un `.env` perdido
- un dump de MariaDB o PostgreSQL
- un volumen de aplicación
- un servicio completo basado en `compose.yaml` + datos + base de datos

Registro recomendado de verificaciones:

```text
/mnt/hd2t/backups/reports/
├── backup-check-2026-05.txt
├── restore-test-nextcloud-2026-07.txt
└── restore-test-vaultwarden-2026-10.txt
```

Contenido mínimo de cada informe:

- fecha y hora
- qué se intentó restaurar
- desde qué snapshot o archivo
- cuánto tardó
- resultado
- incidencias encontradas

### 9. Exclusiones recomendadas

Excluir reduce tiempo, ruido y consumo de almacenamiento. En general no conviene respaldar:

- cachés recreables
- transcodes temporales de Jellyfin
- miniaturas regenerables si el servicio puede reconstruirlas
- descargas incompletas o temporales
- logs rotados sin valor operativo
- imágenes Docker
- contenedores recreables
- datos duplicados que ya estén protegidos por otra vía mejor

Regla útil:

- respalda **estado difícil de reconstruir**
- no respaldes **artefactos fáciles de regenerar**

## Almacenamiento

| Elemento | Ruta recomendada | Disco |
|---|---|---|
| Configuración del homelab | `/home/<usuario>/homelab/compose/` | SSD NVMe |
| Variables y secretos locales | `/home/<usuario>/homelab/env/` y `.env` por stack | SSD NVMe |
| Datos persistentes de servicios | `/home/<usuario>/homelab/data/` | SSD NVMe |
| Repositorio local Borg | `/mnt/hd2t/backups/borgmatic/local/` | `hd2t` |
| Cache/estado auxiliar de backup | `/mnt/hd2t/backups/borgmatic/offsite-cache/` | `hd2t` |
| Exportaciones de BD y volúmenes | `/mnt/hd2t/backups/exports/` | `hd2t` |
| Informes de verificación | `/mnt/hd2t/backups/reports/` | `hd2t` |
| Restauraciones de prueba | `/mnt/hd2t/backups/restore-test/` | `hd2t` |
| Multimedia general | `/mnt/hd2t/...` | `hd2t` |
| Biblioteca de Stash | `/mnt/hd5t/stash/data/` | `hd5t` |
| Réplica offsite | proveedor cloud cifrado | fuera del homelab |

Notas de almacenamiento:

- el repositorio local en `hd2t` está pensado para proteger el **NVMe**, no para autorespaldar `hd2t`
- `hd5t` queda fuera del backup local base salvo que añadas otro destino independiente
- el destino offsite debe almacenar solo lo que compensa proteger por coste, sensibilidad y tiempo de subida
- no mezcles el área de backups con bibliotecas multimedia o descargas

## Backup

Resumen operativo de lo que sí debe respaldarse:

- `compose.yaml`, `.env`, scripts y configuraciones del homelab
- dumps consistentes de MariaDB y PostgreSQL antes de cada ejecución
- volúmenes persistentes de servicios desplegados sobre el NVMe
- documentos y contenido personal irremplazable
- metadatos y configuraciones de servicios multimedia cuya reconstrucción sea costosa

Resumen de lo que normalmente no compensa respaldar:

- imágenes Docker
- contenedores efímeros
- cachés y temporales
- descargas incompletas
- bibliotecas masivas reemplazables si no aceptas el coste de protegerlas correctamente

Checklist mínimo antes de dar la estrategia por válida:

1. Existe un área local dedicada en `/mnt/hd2t/backups/`.
2. El conjunto crítico del NVMe se copia diariamente al destino local.
3. Ese mismo conjunto crítico se replica cifrado a un destino offsite.
4. Las bases de datos se exportan antes del backup.
5. Hay política de retención definida.
6. Hay revisiones y restauraciones de prueba calendarizadas.

## Referencias
- Borgmatic documentation: https://torsion.org/borgmatic/docs/
- BorgBackup documentation: https://borgbackup.readthedocs.io/
- Docker Engine documentation: Volumes: https://docs.docker.com/engine/storage/volumes/
- PostgreSQL documentation: `pg_dump`: https://www.postgresql.org/docs/current/app-pgdump.html
- MariaDB documentation: Backup and restore overview: https://mariadb.com/kb/en/backup-and-restore-overview/
