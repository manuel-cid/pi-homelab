# Mantenimiento periódico

## Descripción
Este documento define la rutina operativa del homelab para mantener estable una Raspberry Pi 5 con Docker, almacenamiento en **SSD NVMe** y dos discos USB (`hd2t` y `hd5t`).

La meta no es "tocar cosas por costumbre", sino comprobar con una cadencia fija los puntos que más suelen degradar un homelab con el tiempo:

- estado de los **backups**
- errores recientes en **logs**
- actualización controlada de **imágenes Docker**
- salud de discos mediante **SMART**
- limpieza segura de recursos no usados en Docker

La política de este documento asume el diseño global del proyecto:

- el **SSD NVMe** aloja sistema, Compose, configs, bases de datos y datos persistentes
- `hd2t` aloja multimedia general, descargas y backups
- `hd5t` aloja la biblioteca multimedia de Stash
- el acceso es solo **LAN + Tailscale**

## Requisitos Previos
- Haber completado `docs/01-sistema/04-estructura-directorios.md`.
- Haber completado `docs/02-docker/01-instalacion-docker.md`.
- Haber completado `docs/02-docker/02-estructura-compose.md`.
- Haber completado `docs/02-docker/04-watchtower.md` si usas auto-actualización parcial de contenedores.
- Haber completado `docs/05-monitorizacion/06-dozzle.md` si quieres revisar logs desde interfaz web además de CLI.
- Haber completado `docs/07-backups/01-estrategia-backup.md`.
- Haber completado `docs/07-backups/02-borgmatic.md`.
- Haber completado `docs/07-backups/03-backup-docker-volumes.md`.
- Tener disponibles y montadas estas rutas:
  - `/home/<usuario>/homelab`
  - `/mnt/hd2t`
  - `/mnt/hd5t`
  - `/mnt/hd2t/backups`
- Poder ejecutar `docker`, `docker compose`, `sudo`, `journalctl`, `lsblk`, `findmnt` y `df`.
- Tener instalado `smartmontools` para usar `smartctl`:

```bash
sudo apt update
sudo apt install -y smartmontools
```

- Puertos implicados:
  - no hace falta abrir puertos nuevos para esta fase
  - se reutilizan los accesos administrativos ya desplegados en LAN o Tailscale
  - si consultas Dozzle desde navegador, se usa el puerto publicado en su stack, por ejemplo `8088/tcp`

## Docker Compose
No aplica directamente en este documento.

Aquí no se despliega un servicio nuevo. Se documenta la rutina para operar los stacks ya existentes y revisar su estado con una cadencia predecible.

Si quieres automatizar parte de estas tareas, guarda scripts auxiliares en una ruta estable del NVMe, por ejemplo:

```text
/home/<usuario>/homelab/scripts/operaciones/
```

## Configuración

### Objetivo de esta fase

| Elemento | Estado esperado |
|---|---|
| Frecuencia semanal | comprobar backups, logs, espacio y estado general |
| Frecuencia mensual | aplicar mantenimiento más invasivo y revisar salud SMART |
| Fuente principal de backup | Borgmatic hacia `hd2t` y, si aplica, destino offsite |
| Visión rápida de logs | Dozzle o `docker logs` |
| Actualizaciones Docker | conservadoras, primero revisión y luego recreación |
| Limpieza de Docker | segura y controlada, sin borrar volúmenes por defecto |
| Registro operativo | informes y notas guardados en `hd2t` |

### 1. Cadencia recomendada

Usa esta tabla como contrato operativo mínimo:

| Frecuencia | Tareas |
|---|---|
| Semanal | verificar montajes, espacio libre, estado de backups, logs de error, contenedores reiniciando y resultados recientes de Watchtower |
| Mensual | aplicar actualizaciones manuales pendientes, revisar SMART de NVMe y discos USB, limpiar recursos Docker no usados, validar crecimiento de datos |
| Trimestral | restauración de prueba y revisión más profunda de capacidad, aunque el detalle de disaster recovery se documenta aparte |

Ventana sugerida:

- **semanal**: domingo por la mañana o en una franja de bajo uso
- **mensual**: primer fin de semana del mes
- **tras cambios grandes**: repetir la parte de logs, backup y espacio libre aunque no toque por calendario

### 2. Comprobaciones base antes de cualquier mantenimiento

Antes de tocar imágenes, borrar recursos o revisar SMART, confirma que el host está en el estado esperado.

Inventario rápido:

```bash
hostnamectl
uptime
findmnt / /mnt/hd2t /mnt/hd5t
df -h / /mnt/hd2t /mnt/hd5t
lsblk -o NAME,PATH,SIZE,FSTYPE,LABEL,MOUNTPOINT
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
```

Qué debes validar:

- `/` está realmente sobre el **NVMe**
- `hd2t` y `hd5t` siguen montados donde espera la documentación
- no hay discos montados en rutas accidentales tipo `/media/...`
- no hay contenedores en estado `Restarting`, `Exited` o `unhealthy`
- queda margen razonable de espacio libre en NVMe y en `hd2t`

Regla práctica de capacidad:

- intenta actuar antes de llegar al **80 %** de uso en el NVMe
- revisa con prioridad `hd2t` si los backups, descargas o bibliotecas crecen más rápido de lo esperado
- trata `hd5t` como un disco de capacidad grande pero no infinito; Stash puede crecer muy deprisa

### 3. Rutina semanal

La rutina semanal debe ser corta, repetible y fácil de auditar.

#### 3.1. Verificar backups recientes

La primera tarea semanal es confirmar que la copia local hacia `hd2t` y, si existe, la réplica offsite han corrido sin error.

Revisión rápida de informes:

```bash
ls -lah /mnt/hd2t/backups/reports
find /mnt/hd2t/backups/reports -type f -mtime -7 | sort
```

Revisión de logs del contenedor `borgmatic`:

```bash
docker logs --since 7d borgmatic
```

Listado del repositorio local:

```bash
docker exec borgmatic \
  borgmatic list \
  --config /etc/borgmatic.d/local.yaml \
  --last 7
```

Si tienes repositorio offsite, revisa también:

```bash
docker exec borgmatic \
  borgmatic list \
  --config /etc/borgmatic.d/offsite.yaml \
  --last 7
```

Señales de estado correcto:

- existe al menos un backup reciente en la última ventana esperada
- el job termina con estado satisfactorio
- no aparecen errores de autenticación, permisos, espacio o repositorio bloqueado
- los dumps en `exports/` tienen fechas coherentes con la ejecución

Si detectas fallo:

1. No sigas con actualizaciones ni limpieza agresiva.
2. Revisa primero `docker logs borgmatic`.
3. Comprueba espacio libre en `hd2t`.
4. Verifica que el repositorio no esté montado en una ruta equivocada o ausente.
5. Repite el job manualmente solo cuando entiendas la causa.

Ejemplo de ejecución manual del backup local:

```bash
docker exec borgmatic \
  borgmatic create \
  --verbosity 1 \
  --stats \
  --config /etc/borgmatic.d/local.yaml
```

#### 3.2. Revisar logs y reinicios anómalos

Busca señales de degradación antes de que se conviertan en caída real.

Contenedores con restart reciente o estado extraño:

```bash
docker ps -a --format 'table {{.Names}}\t{{.Status}}' | sed -n '1,40p'
docker ps --filter health=unhealthy
```

Logs recientes del host:

```bash
sudo journalctl -p warning --since "7 days ago"
```

Logs recientes de un stack concreto:

```bash
cd /home/<usuario>/homelab/compose/<categoria>/<servicio>
docker compose logs --since 7d --tail 200
```

Si usas Dozzle, utilízalo como vista rápida para:

- contenedores que reinician
- errores repetidos de permisos
- timeouts hacia base de datos
- fallos de montaje en rutas de `hd2t` o `hd5t`

Qué conviene vigilar cada semana:

- errores I/O o mensajes de sistema de archivos en `journalctl`
- contenedores recreados varias veces sin motivo claro
- errores de expiración de sesión, permisos o credenciales
- advertencias persistentes de memoria o falta de espacio

#### 3.3. Revisar actualizaciones de imágenes

La comprobación semanal no implica actualizar todo a ciegas. La idea es saber qué ha cambiado y decidir con criterio.

Si usas Watchtower en modo automático parcial:

```bash
docker logs --since 7d watchtower
```

Qué revisar en esos logs:

- qué contenedores fueron actualizados
- si hubo fallos descargando imágenes
- si algún servicio quedó excluido correctamente
- si después del update hubo reinicios continuos o errores funcionales

Si un stack se actualiza manualmente, la comprobación semanal puede limitarse a identificar pendientes:

```bash
cd /home/<usuario>/homelab/compose/<categoria>/<servicio>
docker compose pull
docker compose images
```

No recrees en la misma rutina semanal un servicio crítico salvo que:

- ya tengas backup reciente verificado
- hayas revisado el changelog o el riesgo de migración
- puedas validar el servicio después del cambio

#### 3.4. Comprobar crecimiento de espacio

La semana es una buena cadencia para detectar crecimiento anómalo antes de que el NVMe se llene.

```bash
df -h / /mnt/hd2t /mnt/hd5t
du -sh /home/<usuario>/homelab/data/* 2>/dev/null | sort -h | tail -n 20
du -sh /mnt/hd2t/* 2>/dev/null | sort -h | tail -n 20
du -sh /mnt/hd5t/* 2>/dev/null | sort -h | tail -n 20
docker system df
```

Patrones típicos a detectar:

- cachés o transcodes creciendo fuera de control
- carpetas de descargas incompletas ocupando demasiado
- imágenes antiguas acumuladas
- logs de aplicaciones creciendo de forma anormal

### 4. Rutina mensual

La rutina mensual sí puede incluir cambios en producción, pero siempre en una ventana de mantenimiento y con rollback razonable.

#### 4.1. Actualizar imágenes Docker de forma controlada

Orden recomendado:

1. confirmar backup reciente
2. elegir primero los servicios de menor riesgo
3. dejar bases de datos, proxy, autenticación y servicios críticos para el final
4. validar cada stack antes de pasar al siguiente

Secuencia recomendada para un stack manual:

```bash
cd /home/<usuario>/homelab/compose/<categoria>/<servicio>
docker compose config
docker compose pull
docker compose up -d
docker compose ps
docker compose logs --tail 100
```

Qué validar tras cada actualización:

- el contenedor arranca en estado estable
- no hay migraciones fallidas
- el servicio responde en LAN o Tailscale
- no se ha perdido acceso a datos persistentes ni bibliotecas montadas

Servicios que conviene tratar con más cuidado:

- MariaDB y PostgreSQL
- Caddy
- Authelia
- Nextcloud
- Paperless-ngx
- Home Assistant
- cualquier contenedor con cambios frecuentes de esquema o dependencias

Si Watchtower ya actualiza algunos contenedores, la tarea mensual no es duplicar trabajo sino:

- revisar si la política de etiquetas sigue siendo correcta
- sacar de auto-actualización los servicios que hayan demostrado ser delicados
- comprobar que `WATCHTOWER_CLEANUP=true` no está ocultando un problema funcional

#### 4.2. Revisar salud SMART de los discos

Primero identifica los dispositivos reales:

```bash
lsblk -o NAME,PATH,SIZE,MODEL,TRAN,SERIAL,MOUNTPOINT
```

Comprobación del NVMe:

```bash
sudo smartctl -a /dev/nvme0
```

Comprobación de discos USB. Sustituye el dispositivo real y, si tu caja USB no expone SAT, prueba con `-d scsi`:

```bash
sudo smartctl -a -d sat /dev/sda
sudo smartctl -a -d sat /dev/sdb
```

Si quieres lanzar un test corto:

```bash
sudo smartctl -t short /dev/nvme0
sudo smartctl -t short -d sat /dev/sda
sudo smartctl -t short -d sat /dev/sdb
```

Después consulta resultados:

```bash
sudo smartctl -a /dev/nvme0
sudo smartctl -a -d sat /dev/sda
sudo smartctl -a -d sat /dev/sdb
```

Qué debes buscar:

- fallos SMART globales
- sectores reasignados o pendientes en discos mecánicos
- errores de lectura o escritura
- temperatura sostenida demasiado alta
- incremento rápido de errores entre una revisión y la siguiente

Interpretación operativa:

- un único aviso aislado no siempre implica sustitución inmediata
- una tendencia clara de errores sí exige plan de reemplazo
- si el problema afecta a `hd2t`, revisa de inmediato la capacidad real de restaurar backups
- si el problema afecta al NVMe, prepara sustitución y recuperación antes de que falle por completo

#### 4.3. Limpiar Docker sin borrar datos útiles

Antes de limpiar, mira qué ocupa espacio:

```bash
docker system df
```

Limpieza segura por defecto:

```bash
docker image prune -f
docker builder prune -f
docker system prune -f
```

Reglas importantes:

- no uses `--volumes` como rutina normal
- no ejecutes `docker system prune -a` si no entiendes qué imágenes vas a perder
- si dependes de una ventana con conectividad limitada, recuerda que borrar imágenes fuerza redescarga después

Cuándo ampliar la limpieza:

- cuando `docker system df` muestre acumulación clara de capas o cachés
- cuando el NVMe esté cerca del límite
- después de varias tandas de actualizaciones o pruebas fallidas

Si necesitas una limpieza más agresiva, hazlo solo tras revisar el inventario y fuera de una situación de incidente:

```bash
docker system prune -a -f
```

Usa `--volumes` únicamente si has auditado que no dependes de `named volumes` huérfanos todavía necesarios.

#### 4.4. Revisar capacidad y reparto de datos

Una vez al mes conviene confirmar que el diseño original sigue cumpliéndose:

- el NVMe guarda datos operativos y persistentes, no bibliotecas pesadas
- `hd2t` sigue absorbiendo descargas, multimedia general y backups
- `hd5t` sigue reservado para la biblioteca de Stash

Comprobación orientativa:

```bash
du -sh /home/<usuario>/homelab/data/* 2>/dev/null | sort -h | tail -n 25
du -sh /mnt/hd2t/* 2>/dev/null | sort -h | tail -n 25
du -sh /mnt/hd5t/* 2>/dev/null | sort -h | tail -n 25
```

Si detectas datos pesados donde no deberían estar:

- corrige el `bind mount` del stack afectado
- mueve datos solo con el servicio parado o en ventana controlada
- documenta el cambio para no romper futuros backups o restores

### 5. Registro operativo recomendado

Conviene dejar rastro simple de cada mantenimiento, aunque sea breve.

Ruta sugerida:

```text
/mnt/hd2t/backups/reports/operations/
```

Creación inicial:

```bash
mkdir -p /mnt/hd2t/backups/reports/operations
```

Formato recomendado del registro:

```text
AAAA-MM-DD
- backups: OK / ERROR
- logs: sin incidencias / revisar servicio X
- updates: servicios tocados
- smart: sin cambios / alerta en disco Y
- prune: ejecutado / no ejecutado
- acciones pendientes
```

Este registro ayuda a:

- detectar cuándo apareció por primera vez una degradación
- correlacionar cambios con fallos posteriores
- saber qué mantenimiento ya se ejecutó realmente y cuál no

### 6. Umbrales de intervención rápida

No todo requiere una respuesta inmediata, pero estos síntomas sí justifican actuar sin esperar al siguiente ciclo:

| Síntoma | Acción recomendada |
|---|---|
| backup local sin éxito en más de 24 horas | revisar Borgmatic antes de cualquier update |
| `unhealthy` o `Restarting` en un contenedor crítico | revisar logs y revertir cambio reciente si aplica |
| NVMe por encima del 85 % | limpiar, mover cargas grandes y revisar cachés ese mismo día |
| errores SMART crecientes | preparar reemplazo y validar restauración |
| `hd2t` no montado donde toca | no ejecutar backups ni descargas hasta corregir el montaje |
| errores I/O en `journalctl` | tratarlo como riesgo de disco o cableado, no como simple fallo de app |

### 7. Orden recomendado cuando coinciden varias tareas

Si en la misma sesión vas a revisar, actualizar y limpiar, sigue este orden:

1. verificar montajes y espacio libre
2. confirmar backup reciente y consistente
3. revisar logs y contenedores inestables
4. aplicar actualizaciones seleccionadas
5. validar servicios
6. ejecutar limpieza Docker
7. guardar registro operativo

Ese orden reduce el riesgo de:

- actualizar sin copia recuperable
- limpiar recursos antes de entender un fallo
- confundir un error previo con un problema introducido por la propia sesión de mantenimiento

## Almacenamiento
Rutas relevantes para esta rutina:

- configuraciones y stacks: `/home/<usuario>/homelab/compose/`
- datos persistentes de servicios: `/home/<usuario>/homelab/data/`
- scripts operativos: `/home/<usuario>/homelab/scripts/operaciones/`
- backup local e informes: `/mnt/hd2t/backups/`
- registros de mantenimiento: `/mnt/hd2t/backups/reports/operations/`
- biblioteca pesada de Stash: `/mnt/hd5t/`

Principios de almacenamiento:

- no guardes los informes operativos solo en el NVMe si precisamente quieres poder revisar el historial tras un fallo del disco del sistema
- no conviertas `hd5t` en destino de backups solo por tener más capacidad
- mantén en el NVMe solo los datos que deben ser rápidos, consistentes y cercanos a los contenedores

## Backup
Este documento no define una estrategia nueva de backup, pero sí forma parte de la operativa que la mantiene fiable.

Qué conviene respaldar relacionado con esta fase:

- scripts en `/home/<usuario>/homelab/scripts/operaciones/`
- cualquier inventario o informe persistente que uses para operar
- el propio registro de mantenimiento en `/mnt/hd2t/backups/reports/operations/` si lo replicas offsite

Qué debe comprobarse durante la rutina:

- existencia de archives recientes en Borgmatic
- presencia de dumps recientes en `exports/`
- legibilidad de informes y ausencia de errores de repositorio
- capacidad real de restauración, al menos de forma trimestral

Para estrategia, despliegue de Borgmatic y restore puntual, consulta:

- `docs/07-backups/01-estrategia-backup.md`
- `docs/07-backups/02-borgmatic.md`
- `docs/07-backups/03-backup-docker-volumes.md`

## Referencias
- Documentación interna:
  - `docs/01-sistema/04-estructura-directorios.md`
  - `docs/02-docker/04-watchtower.md`
  - `docs/05-monitorizacion/06-dozzle.md`
  - `docs/07-backups/01-estrategia-backup.md`
  - `docs/07-backups/02-borgmatic.md`
  - `docs/07-backups/03-backup-docker-volumes.md`
- Documentación oficial:
  - Docker prune: `https://docs.docker.com/engine/manage-resources/pruning/`
  - Docker Compose CLI: `https://docs.docker.com/compose/reference/`
  - Borgmatic: `https://torsion.org/borgmatic/`
  - smartmontools: `https://www.smartmontools.org/`
