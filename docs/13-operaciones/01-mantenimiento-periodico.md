# Mantenimiento Periódico

## Descripción

Este documento define la rutina de mantenimiento operativo del homelab sobre la **Raspberry Pi 5**. Su objetivo es detectar pronto fallos de backup, degradación de discos, errores recurrentes en logs, acumulación innecesaria de recursos Docker y actualizaciones pendientes antes de que se conviertan en una incidencia real.

La regla principal de esta fase es simple:

- primero se verifica que el homelab **se puede recuperar**
- después se revisa que el estado actual sea **estable**
- solo entonces se aplican **actualizaciones** o limpiezas

En este proyecto, la prioridad operativa es proteger:

- el **SSD NVMe** como soporte del sistema, `compose`, configuración y datos persistentes
- **`hd2t`** como destino local de backups y almacenamiento multimedia general
- **`hd5t`** como biblioteca multimedia dedicada

## Requisitos Previos

- Haber completado [02-borgmatic.md](../07-backups/02-borgmatic.md).
- Haber completado [03-backup-docker-volumes.md](../07-backups/03-backup-docker-volumes.md).
- Haber completado [04-wud.md](../02-docker/04-wud.md) si vas a monitorizar y automatizar parte de las actualizaciones.
- Haber completado [03-seguridad-base.md](../01-sistema/03-seguridad-base.md).
- Haber completado [06-puertos-y-firewall.md](../03-red/06-puertos-y-firewall.md).
- Tener instaladas herramientas de administración base en el host:
  - `smartmontools`
  - `util-linux`
  - `docker`
  - `docker compose`
- Tener acceso administrativo por **SSH** al host.
- Tener montados correctamente:
  - `SSD NVMe` como disco principal del sistema
  - `hd2t` en `/media/hd2t`
  - `hd5t` en `/media/hd5t`

Puertos necesarios en esta fase:

- ninguno adicional a los ya documentados

## Docker Compose

No aplica en este documento. Aquí se define un procedimiento operativo periódico para el host y los stacks ya desplegados.

## Configuración

### 1. Cadencia recomendada

La rutina mínima recomendada para este homelab es esta:

| Frecuencia | Tareas |
|-----------|--------|
| Semanal | verificar backups recientes, revisar logs del host y contenedores críticos, comprobar espacio libre |
| Mensual | actualizar imágenes y recrear stacks revisados, ejecutar comprobación SMART, limpiar recursos Docker no usados, revisar firewall y puertos publicados |
| Trimestral | prueba real de restauración de un servicio, revisión manual de crecimiento de datos y ajuste de retención |
| Antes de cambios grandes | confirmar backup reciente, exportar base de datos afectada y registrar la ventana de mantenimiento |

Regla operativa:

- si el backup más reciente ha fallado, **no** hagas actualizaciones ni limpiezas agresivas hasta resolverlo

### 2. Checklist semanal mínimo

Ejecuta esta revisión al menos una vez por semana:

```bash
date
hostnamectl
uptime
df -h /
df -h /media/hd2t
df -h /media/hd5t
findmnt /media/hd2t
findmnt /media/hd5t
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
systemctl --failed
```

Qué debes confirmar:

- el host sigue estable y sin reinicios inesperados
- el **NVMe** no está cerca de llenarse
- `hd2t` conserva espacio suficiente para backups y exports
- `hd5t` no está al límite por crecimiento de su biblioteca multimedia
- `hd2t` y `hd5t` siguen montados sobre sus dispositivos reales y no están resolviendo contra `/`
- no hay unidades `systemd` fallidas ni contenedores reiniciando en bucle

Umbrales prácticos recomendados:

- investigar si cualquier disco supera **80 %** de ocupación
- actuar con prioridad si el **NVMe** supera **85 %**
- no dejar que `hd2t` se llene, porque afecta tanto a media como a backups

### 3. Verificar backups semanalmente

La comprobación mínima no es solo ver que Borgmatic existe, sino confirmar que ha generado archivos recientes y que no arrastra errores.

Desde el stack de Borgmatic:

```bash
cd /home/<user>/homelab/compose/infra-borgmatic
docker compose ps
docker compose logs --tail=100 borgmatic
docker compose exec borgmatic borgmatic list --short --last 7
docker compose exec borgmatic borgmatic info --repository local
```

Además, revisa el directorio de exports:

```bash
find /media/hd2t/backups/exports -maxdepth 2 -type f -mtime -7 | sort
du -sh /media/hd2t/backups/borg
du -sh /media/hd2t/backups/exports
```

Qué debes validar cada semana:

- existe al menos un backup reciente dentro de la ventana esperada
- no aparecen errores repetidos de hooks, permisos o bloqueos del repositorio
- los dumps de bases de datos se están generando si el homelab los usa
- el tamaño del repositorio crece de forma razonable y no de forma explosiva

Una vez al mes, añade esta comprobación:

```bash
cd /home/<user>/homelab/compose/infra-borgmatic
docker compose exec borgmatic borgmatic check --only repository --only archives
```

Y una vez por trimestre, restaura una muestra en la ruta de prueba:

```bash
SERVICE=<servicio-a-validar>
mkdir -p "/media/hd2t/backups/restore-test/${SERVICE}"
```

La validación trimestral debe incluir una restauración real de al menos un servicio hacia `restore-test/`, no solo la creación del directorio. Para hacerlo sin tocar producción:

1. elige un servicio con datos persistentes reales
2. restaura su copia hacia `/media/hd2t/backups/restore-test/<servicio>/` siguiendo [03-backup-docker-volumes.md](../07-backups/03-backup-docker-volumes.md)
3. comprueba que el contenido restaurado tiene el tamaño, la fecha y la estructura esperados
4. documenta qué servicio has validado y qué archivo o dump has usado

<!-- TODO: verificar y enlazar aquí un ejemplo cerrado de restore trimestral cuando exista un procedimiento de extracción Borg documentado para un servicio concreto del repositorio. -->

### 4. Revisar logs semanalmente

El objetivo no es leer todo el journal, sino detectar patrones de error sostenidos.

Comandos útiles del host:

```bash
journalctl -p err -b --no-pager
journalctl -u docker --since "7 days ago" --no-pager
sudo dmesg -T | grep -Ei 'error|fail|warn|nvme|usb|sd[a-z]|ext4'
```

Comprobaciones de servicios y contenedores:

```bash
for c in $(docker ps --format '{{.Names}}'); do
  echo "### ${c}"
  docker logs --tail=50 "${c}" 2>&1 | grep -Ei 'error|exception|fatal|panic' || true
done
```

Si prefieres revisar solo contenedores críticos, empieza por:

- `borgmatic`
- `wud`
- `caddy`
- bases de datos como `mariadb` o `postgres`
- servicios de acceso como `authelia` o `vaultwarden`
- `tailscale` si lo has desplegado como contenedor; si lo instalaste en el host, revisa `systemctl status tailscaled`

Qué señales deben disparar revisión inmediata:

- errores de E/S, `I/O error`, `EXT4-fs error`, `nvme timeout` o desconexiones USB
- reinicios recurrentes de contenedores
- errores repetidos de autenticación en servicios críticos
- mensajes de falta de espacio o `read-only file system`

### 5. Actualizar imágenes Docker mensualmente

La secuencia correcta es esta:

1. comprobar que el backup reciente es correcto
2. revisar changelogs si el servicio es sensible
3. actualizar primero infraestructura simple y después servicios con datos
4. validar cada stack antes de pasar al siguiente

Para actualización manual por stack:

```bash
cd /home/<user>/homelab/compose/<stack>
docker compose pull
docker compose up -d
docker compose ps
docker compose logs --tail=50
```

Si usas WUD en modo controlado, revisa su ejecución:

```bash
cd /home/<user>/homelab/compose/infra-wud
docker compose logs --tail=100 wud
```

Reglas recomendadas:

- no actualices todas las bases de datos y servicios críticos a la vez
- si una imagen introduce migraciones, haz export adicional antes de recrear
- si un servicio funciona detrás de **Caddy**, valida acceso web y login después de la recreación
- si un contenedor queda en `Restarting`, detén la ronda de mantenimiento y corrige antes de seguir

### 6. Comprobar la salud de discos con SMART mensualmente

Primero identifica los dispositivos reales:

```bash
lsblk -f -o NAME,LABEL,FSTYPE,SIZE,TRAN,MOUNTPOINT
```

No asumas que `hd2t` y `hd5t` serán siempre `/dev/sda` y `/dev/sdb`: tras reinicios o reconexiones USB ese orden puede cambiar. Usa la salida de `lsblk -f` para mapear primero cada etiqueta con su dispositivo real y ejecuta `smartctl` contra ese dispositivo.

Comprobaciones típicas:

```bash
sudo smartctl -a /dev/nvme0n1
sudo smartctl -a -d sat /dev/<dispositivo-hd2t>
sudo smartctl -a -d sat /dev/<dispositivo-hd5t>
```

Si la carcasa USB no expone SMART con `-d sat`, prueba con `-d scsi` según el chipset del adaptador.

Señales que requieren atención:

- aumento de errores de lectura o escritura
- sectores pendientes o reasignados en discos USB
- temperatura alta sostenida
- porcentaje de vida útil bajo en el NVMe

Prueba corta recomendada una vez al mes:

```bash
sudo smartctl -t short /dev/nvme0n1
sudo smartctl -t short -d sat /dev/<dispositivo-hd2t>
sudo smartctl -t short -d sat /dev/<dispositivo-hd5t>
```

Vuelve a consultar el resultado al cabo de unos minutos con `smartctl -a`.

### 7. Limpiar recursos Docker mensualmente

Antes de borrar nada, mide el consumo real:

```bash
docker system df
docker image ls
docker volume ls
```

Limpieza base recomendada:

```bash
docker system prune -f
```

Qué elimina este comando:

- contenedores detenidos
- redes no usadas
- imágenes colgantes y caché de build no usada

Reglas importantes:

- no uses `docker system prune --volumes` como rutina por defecto
- no borres volúmenes si no estás completamente seguro de que son prescindibles
- ejecuta la limpieza **después** de verificar backups y **después** de validar que no hay rollbacks pendientes

Si el consumo de imágenes sigue siendo alto, revisa primero qué stacks conservan imágenes antiguas antes de aplicar limpiezas más agresivas.

### 8. Revisar red y firewall mensualmente

Aunque este documento se centra en mantenimiento, conviene cerrar cada ronda mensual con una revisión rápida de puertos publicados:

```bash
ss -ltnup
docker ps --format 'table {{.Names}}\t{{.Ports}}'
sudo ufw status numbered
```

Si el host usa **`nftables`** en lugar de **`ufw`**, sustituye la última comprobación por:

```bash
sudo nft list ruleset
```

Debes comprobar que:

- no han aparecido puertos nuevos publicados en `0.0.0.0`
- siguen abiertos solo los puertos previstos en [06-puertos-y-firewall.md](../03-red/06-puertos-y-firewall.md)
- los servicios que deberían vivir solo detrás de **Caddy** no se han quedado expuestos directamente

### 9. Plantilla operativa de mantenimiento

Una forma práctica de registrar la ejecución es mantener una nota con este formato:

```text
Fecha:
Operador:

[ ] Backup diario correcto
[ ] Check mensual Borg correcto
[ ] Restore test realizado si tocaba
[ ] Logs del host revisados
[ ] Logs de contenedores críticos revisados
[ ] SMART NVMe correcto
[ ] SMART hd2t correcto
[ ] SMART hd5t correcto
[ ] Imágenes actualizadas o revisión pospuesta
[ ] docker system prune ejecutado
[ ] Revisión de puertos y firewall completada

Incidencias:
Acciones pendientes:
```

Esta disciplina evita depender de memoria informal cuando pasan varias semanas entre revisiones.

## Almacenamiento

Rutas y soportes que deben vigilarse durante el mantenimiento:

- sistema, `compose`, `config`, `data` y logs operativos en el **SSD NVMe**
- repositorio Borg, exports y restore tests en **`/media/hd2t/backups/`**
- media general y descargas en **`/media/hd2t/`**
- biblioteca de **Stash** en **`/media/hd5t/`**

Puntos a vigilar:

- el **NVMe** es el soporte más sensible porque concentra sistema y estado del homelab
- `hd2t` debe conservar espacio libre para backups y exports, no solo para media
- `hd5t` puede crecer mucho por volumen, pero su presión no debe ocultar errores de montaje o desconexiones USB

## Backup

Este documento no genera un backup propio, pero sí fija qué debes conservar para poder repetir la operación habitual:

- la propia documentación bajo [`docs/`](../)
- cualquier checklist o procedimiento local que guardes bajo `/home/<user>/homelab/scripts/`
- logs o notas de incidencias si los guardas dentro del árbol del homelab

La recuperación técnica de datos y servicios depende de:

- [02-borgmatic.md](../07-backups/02-borgmatic.md)
- [03-backup-docker-volumes.md](../07-backups/03-backup-docker-volumes.md)

## Referencias

- [02-borgmatic.md](../07-backups/02-borgmatic.md)
- [03-backup-docker-volumes.md](../07-backups/03-backup-docker-volumes.md)
- [04-wud.md](../02-docker/04-wud.md)
- [03-seguridad-base.md](../01-sistema/03-seguridad-base.md)
- [06-puertos-y-firewall.md](../03-red/06-puertos-y-firewall.md)
- Docker Docs: [docker system prune](https://docs.docker.com/reference/cli/docker/system/prune/)
- Docker Docs: [docker system df](https://docs.docker.com/reference/cli/docker/system/df/)
- smartmontools: [smartctl manual](https://www.smartmontools.org/)
