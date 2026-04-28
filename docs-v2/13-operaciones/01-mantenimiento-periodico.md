# Mantenimiento Periódico

## Descripción

Documento operativo de la **Fase 13** del homelab. Define el **calendario de tareas recurrentes** que el operador ejecuta — manualmente o supervisando lo automatizado — para que la Pi 5 siga funcionando con previsibilidad: **verificación de backups**, **revisión de logs**, **actualización de imágenes Docker**, **salud de discos (SMART)**, **limpieza de Docker** y un puñado de gestos menores que, omitidos durante meses, se convierten en incidentes evitables.

Este doc es el **playbook del operador** y el contrato con el yo-del-futuro: lo que hay que tocar y mirar **periódicamente** para no entrar en modo "homelab abandonado". Cubre, en este orden:

1. **Filosofía**: qué automatiza el homelab, qué requiere ojo humano y por qué.
2. **Cadencias**: matriz consolidada **diario / semanal / mensual / trimestral / anual** con quién dispara cada tarea (timer systemd, cron, operador).
3. **Tareas diarias**: lo que el sistema hace solo y lo que el operador escanea en 2-3 minutos (paneles Grafana, Uptime Kuma, bandeja de email/Telegram).
4. **Tareas semanales**: verificación de Borgmatic, revisión de logs en Dozzle, comprobación SMART, repaso de Watchtower.
5. **Tareas mensuales**: `borg check --verify-data`, smoke test de restauración (L3), `docker system prune`, revisión de espacio en `hd2t`/`hd5t`, auditoría de imágenes Docker.
6. **Tareas trimestrales**: rotación de credenciales, revisión de listas de Pi-hole, audit de reglas de Sonarr/Radarr, revisión de dashboards de Grafana.
7. **Tareas anuales**: rotación de claves Borg si procede, refresh de la microSD (clonado), revisión del modelo de amenaza, "spring cleaning" del repo `~/homelab/`.
8. **Convención de logs**: el fichero `~/homelab/operations/maintenance.log` versionado en git como bitácora canónica.
9. **Lista de verificación** y **solución de problemas** para los síntomas habituales.

> **Alcance de este doc**: este documento **lista**, **prioriza** y **explica** las tareas. Los procedimientos detallados (cómo se levanta cada servicio, cómo se ejecuta `borg check`, cómo se hace el smoke test) viven en los docs de servicio. Aquí solo se centraliza la **agenda** y el **protocolo de qué hacer si algo aparece raro**, con punteros a esos otros docs.

> **Alcance de red**: todas las tareas se ejecutan **localmente** sobre la Pi (vía SSH desde LAN o Tailscale). No hay nada en este doc que requiera abrir puertos al exterior. El operador puede ejecutar este playbook desde cualquier sitio mientras tenga su nodo Tailscale conectado.

---

## Requisitos Previos

- **Fases 0-12 desplegadas** (al menos hasta el punto en el que cada servicio del calendario ya existe en el homelab; las fases tempranas funcionan con un subconjunto de este playbook).
- **Notificaciones operativas** funcionando según [`../05-monitorizacion/05-uptime-kuma.md`](../05-monitorizacion/05-uptime-kuma.md) y [`../07-backups/01-estrategia-backup.md`](../07-backups/01-estrategia-backup.md) §9: al menos un canal (Telegram **o** email) recibiendo "heartbeat" diario de Borgmatic y alertas de Uptime Kuma. Sin notificaciones, este playbook es ciego: el operador descubre los problemas **mucho** después.
- **Acceso SSH al host** desde la máquina personal (LAN o Tailscale), con clave del operador según [`../01-sistema/03-seguridad-base.md`](../01-sistema/03-seguridad-base.md). Algunas tareas (mensuales) requieren `sudo`; el usuario `homelab` está en `sudoers`.
- **Repo `~/homelab/` versionado en remoto** (GitHub privado, Gitea propio o similar). El log de mantenimiento es uno de los ficheros que **debe** quedar en el repo.
- **`~/homelab/operations/`** ya existe como directorio versionado (creado en [`../07-backups/03-backup-docker-volumes.md`](../07-backups/03-backup-docker-volumes.md) §0). Si no existe: `mkdir -p ~/homelab/operations && touch ~/homelab/operations/maintenance.log && git -C ~/homelab add operations/maintenance.log`.
- **Reloj sincronizado** ([`../01-sistema/02-configuracion-inicial.md`](../01-sistema/02-configuracion-inicial.md)). Las marcas de tiempo del log y de los timers `systemd` son la única manera de auditar "¿se hizo o no se hizo?".
- **Calendario personal** del operador con recordatorios para tareas mensuales/trimestrales/anuales (Google Calendar, Proton Calendar, ICS importado, lo que sea). Sin recordatorio externo, las tareas trimestrales se pierden invariablemente.

### Decisiones de diseño asumidas

| Decisión | Valor por defecto | Justificación |
|---|---|---|
| Bitácora canónica | **`~/homelab/operations/maintenance.log`** versionado en git | Plain-text, append-only, auditable. Vive en el repo del homelab → entra en backups (Borg) y queda fuera de sitio si se pierde la Pi. Patrón ya aplicado por `restore-tests.log` y `borg-compact.log`. |
| Formato de cada entrada | **`YYYY-MM-DD · cadencia · qué se hizo · resultado · notas`** (una línea por entrada) | `grep`able. Una entrada por sesión de mantenimiento (no una por subtarea — para eso está el detalle en commits). |
| Commit message para entradas de mantenimiento | **`ops: maintenance <YYYY-MM-DD> <cadencia>`** (ej. `ops: maintenance 2026-05-12 weekly`) | Convención uniforme con `ops: smoke test`, `ops: borg compact`. Hace `git log --grep='ops: maintenance'` la "línea del tiempo" del homelab. |
| Periodicidad de tareas semanales | **Domingo por la mañana** (≤ 30 min) | Coincide con que las cadencias automáticas del homelab usan "domingo 03:00–04:00" (Watchtower, Borgmatic semanal). El operador revisa unas horas después, con los resultados ya en pantalla. |
| Periodicidad de tareas mensuales | **Día 1 del mes (o primer fin de semana del mes)**, ≤ 90 min | Coincide con `borg check --verify-data` mensual y smoke test mensual ([`../07-backups/01-estrategia-backup.md`](../07-backups/01-estrategia-backup.md) §8). Una sesión ≈ 1.5 h cubre todo. |
| Periodicidad trimestral | **Equinoccios/solsticios aproximados**: enero, abril, julio, octubre | Calendario natural y memorable. Cuatro pasadas al año bastan para rotar credenciales no críticas y revisar configuraciones que cambian poco. |
| Periodicidad anual | **Aniversario del homelab** (fecha de `git log --reverse \| head -1` del repo) | Marca natural del operador. Una sola sesión "deep clean" al año, ≤ 4 h. |
| Tareas que requieren `sudo` | **Agrupadas y ejecutadas con `sudo -i`** una vez por sesión | Evita teclear `sudo` 30 veces y reduce ventana de error. La sesión root se cierra al terminar la sección "sudo" con `exit`. |
| Servicios "ojo cerrado" (no se tocan en mantenimiento periódico) | **Stash, Jellyfin libraries, Syncthing data, Nextcloud user files** | Datos del usuario; el mantenimiento toca **infra y configs**, no contenido. La excepción es la salud de los discos donde residen (capítulo SMART). |
| Tareas que NO entran en este doc | Disaster recovery, tuning de la Pi 5, mapa de puertos | Cubiertas por [`./02-disaster-recovery.md`](./02-disaster-recovery.md), [`./03-rendimiento-pi5.md`](./03-rendimiento-pi5.md) y [`./04-red-y-puertos.md`](./04-red-y-puertos.md) respectivamente. |

---

## 1. Filosofía: qué automatiza el homelab y qué necesita ojo humano

### 1.1. Lo que está automatizado

Antes de listar el playbook, conviene fijar qué **no** está en él (porque lo hace el sistema solo):

| Tarea | Mecanismo | Documento que lo configura |
|---|---|---|
| Aplicar parches de seguridad de Debian Bookworm | `unattended-upgrades` con `Automatic-Reboot "true"` a las 04:00 | [`../01-sistema/03-seguridad-base.md`](../01-sistema/03-seguridad-base.md) §6 |
| Backup diario (`hd2t/backups/borg/`) + offsite (B2/Storj) | systemd timer + Borgmatic + `rclone sync` en `after_everything` | [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) |
| Verificación L1 del repo Borg (`borg check --repository-only`) | Hook `after_backup` de Borgmatic, diaria | [`../07-backups/01-estrategia-backup.md`](../07-backups/01-estrategia-backup.md) §8 |
| Actualización de imágenes Docker (servicios opt-in) | Watchtower, domingo 04:00, `WATCHTOWER_LABEL_ENABLE=true` | [`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) |
| Autotest SMART corto semanal y largo mensual | `smartd` con `/etc/smartd.conf` | [`../00-hardware/03-preparacion-discos.md`](../00-hardware/03-preparacion-discos.md) §7 |
| Limpieza de imágenes Docker huérfanas tras cada update | `WATCHTOWER_CLEANUP=true` | [`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §0 |
| Lifecycle hook BD antes del upgrade del contenedor | `WATCHTOWER_LIFECYCLE_HOOKS=true` + label `pre-update` por servicio | [`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) y docs de Nextcloud, Vaultwarden, Bookstack |
| Heartbeat hacia Uptime Kuma desde Borgmatic | `after_everything` hook con `curl https://kuma.lan/api/push/...` | [`../05-monitorizacion/05-uptime-kuma.md`](../05-monitorizacion/05-uptime-kuma.md) §9 |
| Rotación de certificados internos (Caddy CA local) | Caddy renueva automáticamente | [`../03-red/04-caddy.md`](../03-red/04-caddy.md) |
| Limpieza de `dumps/`, `configs/`, `system/` antiguos | `find -mtime +N -delete` en `after_backup` de Borgmatic | [`../07-backups/01-estrategia-backup.md`](../07-backups/01-estrategia-backup.md) §4.4 |

### 1.2. Lo que necesita ojo humano (este playbook)

A la inversa, hay tareas que la automatización **no** cubre — o las cubre solo parcialmente y exigen confirmación humana:

- **Confirmar que el backup terminó OK** (no basta con que no haya alerta: la ausencia de alerta puede ser fallo del canal de notificación, **el watchdog inverso** de Uptime Kuma cubre esto, pero hay que confirmar que está vivo).
- **Smoke test de restauración (L3)**: Borgmatic puede reportar "L1 OK" mientras un servicio concreto tiene un dump vacío por un bug del hook. Solo restaurar y arrancar de verdad lo descubre.
- **`borg check --verify-data` mensual**: lee y valida HMAC de **todos** los blobs. Detecta bit-rot que el L1 diario no ve. No se programa diario porque tarda horas y desgasta el disco.
- **Limpieza de Docker manual** más allá de lo que hace Watchtower: `system prune` agresivo, revisión de volúmenes huérfanos, limpieza de buildkit cache si se ha usado `docker buildx`.
- **Salud de discos**: smartd lanza autotests, pero **leer los resultados** y decidir "este disco tiene 30 sectores reasignados, voy a empezar a planear su reemplazo" es humano.
- **Decisiones de upgrade no triviales**: bumping de major version de Nextcloud, MariaDB, Home Assistant — Watchtower está en `enable: false` para esos por diseño ([`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §1.2).
- **Rotación de credenciales**: passwords de admin Pi-hole, master password de Vaultwarden, claves API de Tailscale, credenciales B2 offsite. Nada de esto rota solo.
- **Auditoría de "qué corre y por qué"**: con el tiempo se acumulan stacks que se levantaron "para probar" y nadie volvió a tocar. La sesión trimestral los detecta.
- **Revisión de tendencias en Grafana**: temperatura subiendo gradualmente, espacio creciendo más rápido de lo previsto, tasa de errores de un servicio en aumento. Las **alertas** disparan en valores absolutos; las **tendencias** las ve el humano.

### 1.3. La trampa del "todo verde"

Un homelab que reporta "todo verde" durante semanas suele estar en uno de estos dos estados:

1. **Realmente todo va bien** (deseable).
2. **La monitorización está rota y nadie se entera** (frecuente y peligroso).

El playbook periódico distingue ambos casos. Cada sesión semanal incluye una verificación cruzada explícita ("¿llega el heartbeat de Borgmatic? ¿están los exporters subiendo métricas? ¿hay alertas silenciadas que olvidé re-armar?"). Sin esto, el "todo verde" se vuelve un sesgo de confirmación.

---

## 2. Cadencias consolidadas

Matriz de tareas por frecuencia. Cada celda apunta al apartado de este doc (§3-§7) o al doc externo donde está el procedimiento.

| Cadencia | Tarea | Quién la dispara | Tiempo humano estimado |
|---|---|---|---|
| **Continua** | Push de cambios al repo `~/homelab/` cuando el operador edita | Operador (`git push`) | — |
| **Diaria 03:00** | Backup Borgmatic + offsite + verify L1 | systemd timer | 0 min (auto) |
| **Diaria 04:00** | `unattended-upgrades` aplicado, reboot si procede | systemd timer | 0 min (auto) |
| **Diaria** (en cualquier momento, ≤ 5 min) | Vistazo a Uptime Kuma + bandeja Telegram/email | Operador | ~3 min |
| **Semanal Dom 03:30** | `smartctl -t short` (autotest corto) en `hd5t` y `hd2t` | `smartd` | 0 min (auto) |
| **Semanal Dom 04:00** | Watchtower: pull + restart de servicios opt-in | Watchtower | 0 min (auto) |
| **Semanal** (Dom mañana, ≤ 30 min) | Sesión de mantenimiento semanal (§4) | Operador | ~30 min |
| **Mensual día 1, 03:00** | `borg check --verify-data` (verificación L2) | systemd timer dedicado | 0 min (auto), revisar log |
| **Mensual primer Dom mes, 02:00** | `smartctl -t long` (autotest largo) | `smartd` | 0 min (auto) |
| **Mensual** (≤ 90 min) | Sesión de mantenimiento mensual (§5): smoke test L3, prune, audit | Operador | ~90 min |
| **Trimestral** (Ene/Abr/Jul/Oct, ≤ 2 h) | Sesión de mantenimiento trimestral (§6): credenciales, listas, dashboards | Operador | ~2 h |
| **Anual** (aniversario, ≤ 4 h) | Sesión de mantenimiento anual (§7): rotación claves, microSD, modelo amenaza | Operador | ~4 h |

> **Nota sobre solapamientos en la madrugada**: la ventana 03:00–04:30 acumula `unattended-upgrades`, Borgmatic, `borgmatic` mensual L2 (día 1), `smartd` short (Dom 03:30) y Watchtower (Dom 04:00). Eso **no** es coincidencia: es horario valle del homelab, ningún humano lo usa. Si en algún momento hay contención de I/O (Grafana muestra el disco saturado), la primera palanca es desplazar L2 mensual a las **05:00** (cuando ya terminó Borgmatic). Detalle del orden en [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md).

---

## 3. Tareas diarias

### 3.1. Lo que el sistema hace solo

Antes de las tareas humanas, un recordatorio de qué se ha disparado en automático en las últimas 24 h:

```
00:00 ─ logs rotando (logrotate: /var/log/, contenedores con json-file driver)
03:00 ─ Borgmatic empieza ciclo: dumps DB → snapshot Borg local → rclone sync offsite
03:30 ─ (Si fue domingo) smartd lanza short test en hd5t y hd2t
03:45 ─ Borgmatic envía heartbeat a Uptime Kuma push, Apprise → Telegram "OK / X archivos / Y MB"
04:00 ─ unattended-upgrades aplica parches de seguridad. Reboot si procede.
04:00 ─ (Si fue domingo) Watchtower despierta, hace pull de imágenes opt-in y restart serializado
04:30 ─ Watchtower envía notificación con resumen del ciclo
```

Si **algún paso de los anteriores no llegó a notificar** dos noches seguidas, el watchdog inverso de Uptime Kuma dispara alerta por canal alternativo. Ver §3.3.

### 3.2. Vistazo del operador (≤ 5 min, en cualquier momento del día)

Recorrido mínimo, idealmente con un café por la mañana o antes de cerrar el portátil por la noche:

1. **Uptime Kuma** ([`https://kuma.lan/`](https://kuma.lan/) o vía Tailscale): toda la lista de monitores en verde. Si hay rojo persistente (>15 min) → ver §3.4.
2. **Bandeja Telegram/email** del canal de Apprise: heartbeat de Borgmatic de la noche presente. Si **no llegó** → revisar `journalctl -u borgmatic.service --since '24 hours ago'` (§3.3).
3. **Homepage** ([`https://lab.lan/`](https://lab.lan/) o el dominio elegido en [`../12-dashboards/01-homepage.md`](../12-dashboards/01-homepage.md)): widgets de los servicios principales (Jellyfin, Nextcloud, Pi-hole) reportando estado.
4. **Grafana — dashboard "Homelab Overview"**: ojo a tres gráficas:
   - **Temperatura CPU Pi 5** (`node_thermal_zone_temp`): por debajo de 75 °C en idle, ≤ 80 °C bajo carga. Spike persistente > 80 °C → tuning en [`./03-rendimiento-pi5.md`](./03-rendimiento-pi5.md).
   - **Espacio libre en `hd2t` y `hd5t`**: trazabilidad mensual. Pendiente abrupta = algo escribiendo de más.
   - **`up{}` por job**: ningún job en 0 (exporter caído).

> **Si no hay café y prisa**: con (1) y (2) basta. El resto se cubre en la sesión semanal.

### 3.3. Cómo confirmar que Borgmatic funcionó esta noche

Tres niveles de evidencia, de más rápido a más lento:

```bash
# (a) Notificación Apprise: ya llegó al móvil/email. Si llegó "OK" → done.

# (b) Estado del último ciclo systemd:
systemctl status borgmatic.service --no-pager | head -20

# (c) Log directo:
sudo journalctl -u borgmatic.service --since "yesterday 02:00" --until "today 06:00" | tail -50
sudo tail -n 50 /mnt/hd2t/services/borgmatic/logs/borgmatic.log

# (d) Snapshot existente del día:
sudo borgmatic list --last 3
# debe mostrar el archivo del día con el formato 'host-YYYY-MM-DDTHH-MM-SS-...'
```

Si los cuatro muestran "OK" → backup correcto.
Si el log muestra `ERROR` o el `borgmatic list` no incluye el snapshot del día → ir a la sección §3.4 de troubleshooting.

### 3.4. Qué hacer si algo aparece rojo

| Síntoma | Acción inmediata | Documento referencia |
|---|---|---|
| Un monitor de Uptime Kuma en rojo > 15 min | Abrir Dozzle ([`../05-monitorizacion/06-dozzle.md`](../05-monitorizacion/06-dozzle.md)) → ver logs del contenedor. ¿Crash loop? `docker compose -p <stack> restart <service>`. Si persiste, parar y rebajar a versión previa fijando `image:` y `docker compose up -d`. | Doc del servicio concreto. |
| No llegó notificación de Borgmatic | (1) Verificar que el contenedor del SMTP/Telegram está vivo. (2) `systemctl status borgmatic.service`. (3) Probar envío manual: `apprise -vv -t "test" -b "test" tgram://<token>/<chat_id>`. | [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §N (notificaciones). |
| Reboot inesperado por `unattended-upgrades` | Confirmar `last reboot \| head -3` y leer `/var/log/unattended-upgrades/unattended-upgrades.log`. Verificar que todos los stacks se levantaron solos: `docker ps --format 'table {{.Names}}\t{{.Status}}'`. | [`../01-sistema/03-seguridad-base.md`](../01-sistema/03-seguridad-base.md) §6. |
| Temperatura Pi 5 > 85 °C sostenida | Pausar carga pesada (transcoding Jellyfin, escaneo Stash). Comprobar ventilador (en `i2c`/`gpio` si la carcasa lo expone) y limpieza de polvo. | [`./03-rendimiento-pi5.md`](./03-rendimiento-pi5.md). |
| Disco `hd5t` o `hd2t` no monta tras reboot | `dmesg \| tail -100` y `lsblk`. Cable USB suelto / disco en spin-down agresivo / partición con error. Antes de tocar: NO escribir en él hasta saber qué pasa. | [`../00-hardware/03-preparacion-discos.md`](../00-hardware/03-preparacion-discos.md). |

> **Regla de oro**: ante una alerta inesperada, el primer paso **siempre** es leer logs (Dozzle/journald) **antes** de reiniciar. Reiniciar a ciegas oculta la causa raíz y la próxima vez el síntoma vuelve sin pistas.

### 3.5. Lo que NO se hace en una pasada diaria

- No se actualizan imágenes manualmente (eso lo hace Watchtower el domingo).
- No se aplica `apt full-upgrade` manual (lo hace `unattended-upgrades`; intervención manual solo en `apt list --upgradable` con paquetes "kept back" detectados en la sesión semanal — §4).
- No se ejecutan `borg check --verify-data`, `docker system prune`, ni reinicios de stacks completos.

---

## 4. Tareas semanales (Domingo mañana, ≤ 30 min)

Sesión corta. El operador llega después de que Watchtower y Borgmatic semanal hayan terminado (típicamente domingo > 06:00). Objetivo: **confirmar** que la semana pasó sin sobresaltos y **detectar** lo que el daily no detectó.

### 4.1. Confirmar el ciclo Watchtower del domingo

```bash
# Logs del último ciclo de Watchtower:
docker logs watchtower --since 24h | tail -100
```

Buscar:
- **`Session done`** con "Scanned: N, Updated: M, Failed: 0".
- **Lista de imágenes actualizadas**: anotar mentalmente cuáles. Si Jellyfin acaba de saltar a una versión major, abrir el changelog antes de cerrar la sesión semanal.
- **`Failed: > 0`**: revisar el contenedor que falló. Causa habitual: imagen retirada del registry, manifest sin `linux/arm64`. Doc concreto del servicio + considerar pin manual del tag.

> **Ver también** la notificación que envió Watchtower a Telegram/email con el resumen ([`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §0). Si falta, alguno de los canales `shoutrrr` está mal configurado.

### 4.2. Revisar logs de la semana en Dozzle

Abrir Dozzle ([`https://dozzle.lan/`](https://dozzle.lan/)) y filtrar por **`level=error`** en los últimos 7 días para todos los contenedores ([`../05-monitorizacion/06-dozzle.md`](../05-monitorizacion/06-dozzle.md) §N).

| Lo que se busca | Cómo actuar |
|---|---|
| Errores nuevos que no aparecían la semana pasada | Anotar en `maintenance.log`, decidir si es síntoma o ruido. Crear issue en `~/homelab/issues/` (un .md por problema, opcional). |
| Patrones de "connection refused" entre contenedores | Suele indicar que un servicio cayó y otro lo intentó usar. Cruzar con Uptime Kuma para ver cuándo pasó. |
| Logs de Authelia con login fallidos repetidos desde una IP | Confirmar que es el operador (probablemente lo es) y no terceros. Revisar `fail2ban` ([`../04-seguridad/02-fail2ban.md`](../04-seguridad/02-fail2ban.md)) si el patrón es sospechoso. |
| Pi-hole bloqueando dominios necesarios para algún servicio | Pi-hole → Tools → Tail (`pihole-FTL.log`). Whitelist puntual si hace falta. |
| Volumen de logs gigante para un contenedor | Servicio en bucle de error o demasiado verboso. Ajustar log level del contenedor o aplicar `logging:` con `max-size` en `docker-compose.yml`. |

### 4.3. Verificación SMART semanal

`smartd` lanzó el **autotest corto** la madrugada del domingo. Confirmar resultado:

```bash
# Ambos discos por su id estable (ver hd5t/hd2t.env definidos en preparacion-discos):
sudo smartctl -l selftest /dev/disk/by-id/usb-<modelo-hd5t>-<serial>
sudo smartctl -l selftest /dev/disk/by-id/usb-<modelo-hd2t>-<serial>

# Lo mismo en formato salud rápida:
sudo smartctl -H /dev/disk/by-id/usb-<modelo-hd5t>-<serial>
sudo smartctl -H /dev/disk/by-id/usb-<modelo-hd2t>-<serial>
```

Salida esperada:
- `SMART overall-health self-assessment test result: PASSED`.
- En `selftest log`: la última línea con `Short offline ... Completed without error`.

Atributos críticos a vigilar (en `smartctl -A`):

| Atributo | Lectura aceptable | Acción si crece |
|---|---|---|
| `Reallocated_Sector_Ct` | 0 (mejor) o estable trimestre a trimestre | > 10 nuevos en una semana → planear reemplazo. |
| `Current_Pending_Sector` | 0 | > 0 sostenido → reemplazo urgente. |
| `Offline_Uncorrectable` | 0 | > 0 → reemplazo. |
| `UDMA_CRC_Error_Count` (cable) | 0 o muy bajo | Crece → cable USB malo o conector flojo. Cambiar cable antes que disco. |
| `Power_On_Hours` | (informativo) | Solo para sentido del tiempo: 5 años ≈ 43.800 h. |

Detalle ampliado en [`../00-hardware/03-preparacion-discos.md`](../00-hardware/03-preparacion-discos.md) §2 y §7.

### 4.4. Repaso de Borgmatic semanal

```bash
# Lista de los snapshots conservados según la política GFS:
sudo borgmatic list --last 12

# Tamaño y ratio de dedup acumulado:
sudo borgmatic info
```

Lo que se confirma:
- **Hay snapshot con etiqueta de domingo** (`weekly`) reciente, además de los `daily` de los últimos 7 días.
- **Tamaño del repo `Deduplicated size`** crece a ritmo razonable (típico homelab: pocos GB/semana). Salto súbito de decenas de GB → revisar qué se añadió (Stash importó 50 GB de nuevo material y entró en backup; ver §5.4 política offsite).
- **Tasa de dedup `Total size / Deduplicated size`** alta (≥ 5x para datos típicos).

### 4.5. Comprobar que no quedaron paquetes "kept back"

`unattended-upgrades` aplica solo lo que entra dentro de su política (`security` por defecto). Algunas actualizaciones quedan **retenidas** y requieren intervención manual. Confirmar:

```bash
sudo apt update -qq
apt list --upgradable 2>/dev/null
```

Si la lista incluye paquetes:
- **Críticos** (`linux-image-*`, `firmware-*`, `openssh-server`): aplicar manualmente con `sudo apt full-upgrade -y` y reboot si lo pide. Anotar en `maintenance.log`.
- **Servicios menores** (`htop`, `tmux`, etc.): aplicar al gusto.
- **Bibliotecas con dependencias colgantes**: leer el changelog antes; algunas piden reconfiguración.

### 4.6. Revisión rápida de Grafana — tendencias

Abrir el dashboard "Homelab Overview" ([`../05-monitorizacion/02-grafana.md`](../05-monitorizacion/02-grafana.md)) en rango "últimos 7 días" y mirar:

- **Disco**: pendiente de uso de `hd2t` y `hd5t`. Estimar "a este ritmo, ¿cuándo se llena?". Si < 6 meses, planear acción mensual (§5.4).
- **CPU/RAM**: media sostenida. Pi 5 con 8 GB tolera 6-7 GB sostenidos; > 7.5 GB persistentes → revisar contenedor culpable y aplicar `mem_limit` en compose.
- **Red**: tráfico saliente. Pico recurrente coincidiendo con `rclone sync` offsite (esperado). Pico fuera de ese horario y persistente → un servicio está exfiltrando o un sync mal configurado.
- **Errores HTTP en Caddy**: `caddy_http_request_errors_total` > 0 nuevo por host → algún servicio está respondiendo 5xx.

### 4.7. Anotación en bitácora

Cerrar la sesión con una entrada en `~/homelab/operations/maintenance.log`:

```text
2026-05-10 · weekly · Watchtower OK (3 svcs upd: jellyfin, sonarr, prowlarr); SMART OK ambos discos; borgmatic 7 dailies + 1 weekly; sin paquetes upgradable críticos · sin incidencias
```

Y `git -C ~/homelab commit operations/maintenance.log -m "ops: maintenance 2026-05-10 weekly"`.

---

## 5. Tareas mensuales (Día 1 del mes o primer fin de semana, ≤ 90 min)

Sesión más profunda. Cubre verificaciones que **degradan** o **estresan** disco y CPU y por eso no se hacen más a menudo, y la rotación del smoke test L3.

### 5.1. Confirmar `borg check --verify-data` (verificación L2)

El timer mensual lanzó la verificación intensiva la madrugada del día 1 ([`../07-backups/01-estrategia-backup.md`](../07-backups/01-estrategia-backup.md) §8.2). Tarda 1-3 h según volumen del repo. Confirmar resultado:

```bash
sudo journalctl -u borgmatic-monthly-check.service --since "yesterday" --until "now" | tail -50
sudo tail -n 100 /mnt/hd2t/services/borgmatic/logs/borgmatic-monthly-check.log
```

Esperado: `Archive consistency check complete, no problems found.`

Si reporta corrupción → **parar inmediatamente** la escritura al repo (parar el timer Borgmatic), restaurar desde offsite, investigar SMART y `dmesg` ([`../07-backups/01-estrategia-backup.md`](../07-backups/01-estrategia-backup.md) §12).

### 5.2. Smoke test L3 (rotación mensual)

Restaurar **un** servicio del calendario rotatorio y verificar que arranca con sus datos. Procedimiento detallado en [`../07-backups/03-backup-docker-volumes.md`](../07-backups/03-backup-docker-volumes.md) §6.3. Calendario sugerido:

| Mes | Servicio probado | Justificación |
|---|---|---|
| M1, M5, M9 | **Vaultwarden** | Cada 4 meses, dato más crítico (passwords). |
| M2 | Authelia | Test de SSO + secrets. |
| M3, M7, M11 | Bookstack | BD MariaDB con dump real. |
| M4, M8, M12 | Nextcloud (mini: solo metadata + 5-10 ficheros) | Probar PostgreSQL + ficheros. |
| M6 | Home Assistant | Test del flujo de snapshot HA. |
| M10 | Mosquitto + Zigbee2MQTT | Test del re-pairing del coordinator (sin re-emparejar de verdad — solo levantar). |

Tras el test, anotar en `~/homelab/operations/restore-tests.log` (no en `maintenance.log`; el operations-log canónico para smoke tests es ese, ya creado en [`../07-backups/03-backup-docker-volumes.md`](../07-backups/03-backup-docker-volumes.md) §0). Mensaje del commit: `ops: smoke test <servicio> <YYYY-MM>`.

> **Truco para no procrastinar el smoke test**: si en un mes no hay tiempo, hacer al menos el `borg extract` a un directorio temporal y verificar que los ficheros existen y tamaños son razonables. Es un "L2.5" — no garantiza que el servicio levanta, pero garantiza que el blob es legible.

### 5.3. Limpieza de Docker

Acumulación natural tras un mes de Watchtower + experimentos. Limpieza secuencial **de menos a más agresivo**:

```bash
# Ver el estado actual:
docker system df -v

# (a) Imágenes dangling (capas sin tag tras pulls). Seguro.
docker image prune -f

# (b) Imágenes no usadas por ningún contenedor activo. Watchtower hace algo similar
#     con WATCHTOWER_CLEANUP, pero de imágenes inmediatas; este barre lo viejo.
#     Filtro 30 días para no borrar imágenes "de la versión anterior" útiles para rollback rápido.
docker image prune -a --filter "until=720h" -f

# (c) Builder cache (solo si el operador ha usado `docker buildx`):
docker builder prune --filter "until=720h" -f

# (d) Networks no usados:
docker network prune -f

# (e) Volúmenes no referenciados. PELIGROSO si algún servicio se paró
#     temporalmente (su volumen "anónimo" se considera no usado).
#     Convención del homelab: bind mounts a hd2t/hd5t, volúmenes anónimos solo para datos efímeros.
#     Confirmar antes:
docker volume ls -f dangling=true
# Solo si la lista está limpia (efímeros conocidos):
docker volume prune -f

# (f) Atajo nuclear (NUNCA por defecto, solo en sesión consciente):
# docker system prune -af --volumes
# Equivale a (a)+(b)+(d)+(e). NO incluye builder cache.
```

Tras la limpieza:

```bash
docker system df
df -h /var/lib/docker /mnt/hd2t /mnt/hd5t
```

Ganancia esperada: 1-5 GB en `/var/lib/docker` (microSD), según volumen de updates del mes. Si la microSD pasa de 80% libre a 90% libre, todo correcto.

> **¿Por qué no se programa esto en cron?** Porque la línea (e) (volúmenes huérfanos) requiere ojo humano: un contenedor parado por debug puede tener su volumen aún válido. Automatizar `prune -af --volumes` es la receta del próximo "perdí los datos de X". El operador hace `prune` selectivo confirmando cada paso.

### 5.4. Auditoría de espacio en `hd2t` y `hd5t`

```bash
# Visión por servicio en hd2t:
sudo du -h --max-depth=2 /mnt/hd2t/services/ 2>/dev/null | sort -h | tail -30
sudo du -h --max-depth=2 /mnt/hd2t/media/ 2>/dev/null | sort -h | tail -20
sudo du -sh /mnt/hd2t/backups/* 2>/dev/null

# hd5t (Stash):
sudo du -h --max-depth=2 /mnt/hd5t/ 2>/dev/null | sort -h | tail -20

# Espacio libre actual:
df -h /mnt/hd2t /mnt/hd5t /
```

Comparar con el mes anterior (entrada de `maintenance.log` previa). Crecimiento esperado:
- **`/mnt/hd2t/services/`**: 1-3 GB/mes (configs, índices, caches).
- **`/mnt/hd2t/media/`**: variable, según consumo.
- **`/mnt/hd2t/backups/borg/`**: 1-5 GB/mes (con dedup).
- **`/mnt/hd5t/stash/`**: el operador conoce su patrón.

Si algo crece anormalmente:
- **`appdata_*/preview/` (Nextcloud)**: thumbnails. Limpieza con `occ files:cleanup` ([`../06-almacenamiento/01-nextcloud.md`](../06-almacenamiento/01-nextcloud.md)).
- **`prometheus/data/`**: ajustar `--storage.tsdb.retention.time` si la retención es excesiva ([`../05-monitorizacion/01-prometheus.md`](../05-monitorizacion/01-prometheus.md)).
- **`transmission/incomplete/`**: descargas atascadas. Limpiar con `transmission-remote -t all -r` (con cuidado).
- **Logs `json-file` de un contenedor**: aplicar `logging.options.max-size: 10m` y `max-file: 3` en su compose.
- **`/var/lib/docker/`**: ya cubierto en §5.3.

### 5.5. Revisión de imágenes Docker

```bash
# Ver todas las imágenes presentes en el host con su tamaño y fecha:
docker images --format "table {{.Repository}}:{{.Tag}}\t{{.Size}}\t{{.CreatedSince}}" | sort

# Imágenes que NO está usando ningún contenedor ahora mismo:
docker image ls --filter "dangling=false" --format '{{.Repository}}:{{.Tag}}' \
  | while read img; do
      docker ps -a --filter "ancestor=$img" --format '{{.Names}}' | head -1 \
        | grep -q . || echo "Unused: $img"
    done
```

Acción típica: pin manual de versiones que se sospecha "saltaron a major sin avisar". Editar el `docker-compose.yml` correspondiente: `image: foo/bar:1.2.3` (versión confirmada estable) y `docker compose up -d`.

### 5.6. Verificar que `~/homelab/` está sincronizado en remoto

```bash
git -C ~/homelab status
git -C ~/homelab log --oneline -5
git -C ~/homelab fetch origin
git -C ~/homelab log HEAD..origin/main --oneline   # nada que tirar
git -C ~/homelab log origin/main..HEAD --oneline   # nada que empujar
```

Si hay commits locales sin push → `git push`. Si hay commits remotos sin pull (improbable salvo que el operador edite también desde otro sitio) → `git pull --rebase`.

Esto es backup de la **definición** del homelab independiente del Borg. Si Borg ardiera y el offsite también, el repo `~/homelab/` (en GitHub privado / Gitea propio) permite reconstruir en cualquier hardware.

### 5.7. Anotación en bitácora

```text
2026-05-01 · monthly · L2 borg check OK (1h 47m); smoke test Authelia OK; system prune liberó 3.2 GB; hd2t 78% libre, hd5t 41% libre; ningún paquete kept back; ~/homelab sincronizado · sin incidencias
```

`git -C ~/homelab commit operations/maintenance.log -m "ops: maintenance 2026-05-01 monthly"`.

---

## 6. Tareas trimestrales (Ene/Abr/Jul/Oct, ≤ 2 h)

Cosas que cambian poco y solo se revisan cuatro veces al año.

### 6.1. Rotación de credenciales no críticas

| Credencial | Frecuencia recomendada | Procedimiento |
|---|---|---|
| Password admin de Pi-hole | Trimestral | UI → Settings → API/Web interface → Change password. Anotar en KeePassXC y Vaultwarden. |
| API tokens de Sonarr/Radarr/Prowlarr | Trimestral | UI de cada uno → Settings → General → Regenerate. Actualizar en consumidores (Homepage widget, scripts). |
| App-passwords / API tokens de Nextcloud | Trimestral | Settings → Security → Devices & sessions → revoke + new. |
| API key de Tailscale (auth keys reutilizables) | Trimestral | Tailscale admin console → Keys → revoke + new. Solo afecta si se usa "auth key reutilizable" en lugar de identidad de cuenta — ver [`../03-red/05-tailscale.md`](../03-red/05-tailscale.md). |
| Claves de aplicación Backblaze B2 (`writeFiles`) | Trimestral | B2 console → App Keys → revoke + new. Actualizar `rclone.conf`. |

### 6.2. Lo que NO se rota trimestralmente

- **Passphrase de Borg**: se cambia con `borg key change-passphrase` y exige re-distribuir todas las custodias. Operación delicada, **anual o nunca** ([`../07-backups/01-estrategia-backup.md`](../07-backups/01-estrategia-backup.md) §6.2).
- **Master password de Vaultwarden**: la cambia el operador en su cliente Bitwarden, ningún calendario manda más que la propia política del operador (recomendado: anual + tras evento sospechoso).
- **Claves SSH** (`~/.ssh/id_ed25519`): solo si hay sospecha de compromiso.
- **Secrets internos generados** (Authelia `jwt`, `session`, `storage_encryption`): cambiarlos exige re-encrypt / re-login global; solo en respuesta a incidente.

### 6.3. Revisión de Pi-hole

```bash
# Estadísticas del trimestre:
docker exec pihole pihole -c -j   # JSON con totales y top-N

# Listas activas:
docker exec pihole pihole -g    # actualiza gravity (hace falta tras añadir listas)
```

Acciones típicas:
- **Whitelist**: revisar entradas añadidas "en caliente" durante el trimestre. ¿Siguen siendo necesarias?
- **Blocklists**: actualizar la selección. Listas recomendadas en [`../03-red/02-pihole.md`](../03-red/02-pihole.md). Después de tocar listas: `pihole -g` para regenerar `gravity.db`.
- **Top blocked clients**: si un dispositivo bloquea anómalamente alto (telemetría agresiva), considerar bloqueo más estricto en su MAC/IP.

### 6.4. Auditoría de Sonarr / Radarr / Prowlarr

- **Indexers** (Prowlarr → Indexers → Test All): probar todos. Los indexers caen y a veces nadie se entera durante meses.
- **Quality Profiles**: revisar si las preferencias siguen vigentes (códecs, resoluciones).
- **Blocklist global** (Sonarr → System → Blocklist): purgar entradas viejas (> 90 días) de releases que se han re-publicado con otro hash y son válidos ahora.
- **Sonarr/Radarr → System → Disk Space**: confirmar que ven `hd2t` correctamente (a veces tras un reboot pierden el mount path si no está marcado `nofail` — caso ya prevenido en [`../00-hardware/03-preparacion-discos.md`](../00-hardware/03-preparacion-discos.md)).

### 6.5. Revisión de dashboards Grafana

- **Provisioning** (`provisioning/` versionado en `~/homelab/`): comparar lo versionado con lo que está en `grafana.db`. Si hay dashboards "creados desde la UI" no exportados a YAML → exportarlos y commitearlos. Procedimiento en [`../05-monitorizacion/02-grafana.md`](../05-monitorizacion/02-grafana.md).
- **Alertas silenciadas**: Settings → Silences. Cualquier silenciamiento "temporal" que lleva > 30 días → o se vuelve permanente (modificar la regla) o se quita el silencio (volver a alertar).
- **Datasources**: confirmar que Prometheus sigue siendo el datasource por defecto y que su URL interna (`http://prometheus:9090`) responde desde Grafana.

### 6.6. Anotación en bitácora

```text
2026-04-01 · quarterly · Rotated: pihole admin pwd, sonarr+radarr API, B2 app key. Pi-hole listas actualizadas (gravity rebuilt). Indexers Prowlarr OK 4/5 (1337x caído conocido). Grafana dashboards alineados con git. · sin incidencias
```

---

## 7. Tareas anuales (aniversario del homelab, ≤ 4 h)

Sesión deep-clean. Una vez al año.

### 7.1. Refresh físico

- **Limpieza de polvo**: abrir la carcasa, soplar con aire comprimido el ventilador y disipador. Polvo acumulado dispara temperaturas 3-5 °C ([`./03-rendimiento-pi5.md`](./03-rendimiento-pi5.md)).
- **Cables USB**: revisar que los conectores de `hd5t` y `hd2t` no estén flojos. `UDMA_CRC_Error_Count` (§4.3) detectaría problemas, pero la inspección física es complementaria.
- **Fuente de alimentación**: si se nota throttling persistente bajo carga (`vcgencmd get_throttled` con bits != 0x0), considerar cambio a fuente oficial 27 W si se está usando una genérica ([`../00-hardware/01-material-necesario.md`](../00-hardware/01-material-necesario.md)).
- **Clonado de la microSD**: el desgaste de la microSD es lineal con el tiempo. Tras 1 año, conviene **clonar** la microSD a una nueva (con el sistema en marcha desde la antigua) y guardarla como backup físico. Procedimiento detallado en [`./02-disaster-recovery.md`](./02-disaster-recovery.md) (sección "microSD clonada"). La idea: si la microSD muere súbitamente, la clónica reciente arranca tal cual.

### 7.2. Revisión del modelo de amenaza

Pregunta anual: **¿ha cambiado quién intenta acceder al homelab y desde dónde?**

- ¿Sigue siendo solo LAN + Tailscale, o se ha empezado a exponer algo a internet "para una cosa"? Si sí → revisar reglas de firewall ([`./04-red-y-puertos.md`](./04-red-y-puertos.md)) y consider Caddy + Authelia más estricto.
- ¿Sigue habiendo solo el operador como usuario, o se han añadido familiares? Si sí → permisos en Nextcloud, política de passwords en Authelia, listas de Pi-hole por dispositivo.
- ¿Sigue siendo aceptable el riesgo de "robo físico oportunista" sin LUKS sobre `hd2t`? ([`../07-backups/01-estrategia-backup.md`](../07-backups/01-estrategia-backup.md) §6.4). Si la respuesta cambia → planear migración a disco cifrado.

Anotar conclusiones en `~/homelab/threat-model.md` (crear si no existe; un .md corto con el modelo vigente).

### 7.3. Auditoría de servicios desplegados

```bash
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.RunningFor}}'
ls ~/homelab/stacks/
```

Para cada stack:
- ¿Sigue usándose? Si lleva > 6 meses sin que el operador lo haya tocado **y** no es infra base (Caddy/Pi-hole/Watchtower/etc.) → considerar parar y eliminar. Datos a `/mnt/hd2t/services/<svc>-archive-YYYY/` por seguridad antes de borrar.
- ¿Tiene la última major estable upstream? Revisar GitHub releases del proyecto. Si la versión local va dos majors atrás, planear el upgrade manual (no Watchtower — porque `enable: false` para apps con migraciones).
- ¿La documentación en `docs/<fase>/<servicio>.md` sigue siendo precisa? Discrepancias entre lo desplegado y lo documentado **siempre aparecen**. Reconciliar (preferentemente: mover lo desplegado al estado documentado, no al revés).

### 7.4. Rotación de claves y passphrases (opcional)

- **Passphrase de Borg**: si se sospecha exposición o han pasado 2-3 años, ejecutar `borg key change-passphrase`. Procedimiento en [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) (sección "rotación de passphrase"). Re-distribuir custodias (KeePassXC + sobre cerrado + Vaultwarden).
- **Claves SSH del operador**: si las claves siguen siendo las del primer día (≥ 2 años), regenerar (`ssh-keygen -t ed25519 -f ~/.ssh/homelab_2026`) y rotar `authorized_keys` en la Pi.
- **Certificados internos de Caddy**: Caddy CA renueva automáticamente (cert hojas 30-90 días, root CA 10 años). Si la root CA se acerca a expiración → planificar `caddy reload` con root nueva y re-importar en clientes (raro en homelab pequeño).

### 7.5. Revisión del propio playbook

Lo más importante de la sesión anual: **revisar que este documento sigue describiendo lo que hace el operador**.

- ¿Ha empezado a ejecutar tareas que **no** están en el doc? → añadirlas.
- ¿Hay tareas en el doc que **nunca** se hacen? → quitarlas o automatizarlas.
- ¿Las cadencias siguen siendo razonables, o algo claramente debería ser más/menos frecuente?

Pull request al doc, commit `docs(13-operaciones): refresh playbook from <YYYY> retrospective`.

### 7.6. Anotación en bitácora

```text
2026-12-15 · annual · Polvo limpio, ventilador OK; microSD clonada a backup-2026-12.img; threat-model sin cambios; rotada SSH key del operador; auditados 14 stacks, ninguno retirado; playbook revisado (3 cambios aplicados) · sin incidencias
```

---

## 8. Convención de la bitácora `maintenance.log`

### 8.1. Formato

Una entrada por sesión. Una sola línea (sin saltos), pipe-friendly:

```
YYYY-MM-DD · <cadencia> · <resumen acciones> · <incidencias o "sin incidencias">
```

Ejemplos:
```
2026-05-10 · weekly · Watchtower OK 3 svcs upd; SMART OK; borgmatic 7d+1w OK · sin incidencias
2026-05-01 · monthly · L2 borg check OK; smoke test authelia OK; prune 3.2GB; hd2t 78% libre · sin incidencias
2026-05-15 · ad-hoc · debug latencia jellyfin: descubrí que prowlarr saturaba CPU, mem_limit aplicado · resuelto, monitor 7d
```

### 8.2. Por qué plain-text en git y no una herramienta dedicada

- **Resistencia a fallos**: si Grafana, Bookstack o Vaultwarden caen, la bitácora sigue legible con `cat`.
- **Fácil de buscar**: `grep -i "smart" ~/homelab/operations/maintenance.log`.
- **Trazabilidad histórica**: `git log -p operations/maintenance.log` enseña la evolución.
- **Entra en backups**: `~/homelab/` está versionado en remoto y dentro del repo Borg.
- **No requiere mantenimiento propio**: una herramienta de "bitácora" sería un servicio más que monitorizar.

### 8.3. Ad-hoc entries

Cuando el operador hace una intervención fuera del calendario (un servicio se rompió un martes, un upgrade manual de Nextcloud, un experimento), también merece línea en `maintenance.log` con cadencia **`ad-hoc`**. La convención es la misma; el commit message es `ops: maintenance ad-hoc <YYYY-MM-DD> <resumen breve>`.

---

## 9. Lista de Verificación

Esta sección es la **forma corta** del playbook semanal/mensual: si se imprimiera y pegara al lado del monitor, debería bastar para una sesión sin abrir el doc completo.

### 9.1. Diaria (≤ 5 min)

- [ ] Uptime Kuma verde para todos los monitores (≤ 1 monitor en rojo persistente).
- [ ] Heartbeat de Borgmatic recibido en Telegram/email en las últimas 24 h.
- [ ] Homepage muestra los servicios principales OK.
- [ ] Grafana — temperatura CPU < 80 °C, espacio `hd2t`/`hd5t` con tendencia razonable, ningún `up{} == 0`.

### 9.2. Semanal (Domingo, ≤ 30 min)

- [ ] `docker logs watchtower --since 24h \| tail -100` → "Session done" sin "Failed: > 0".
- [ ] Dozzle filtrado por `level=error` últimos 7 días → sin patrones nuevos preocupantes.
- [ ] `sudo smartctl -H` y `-l selftest` para `hd5t` y `hd2t` → `PASSED` y `Completed without error`.
- [ ] `sudo borgmatic list --last 12` → 7 dailies + ≥ 1 weekly recientes.
- [ ] `apt list --upgradable` → sin paquetes críticos kept back.
- [ ] Grafana "últimos 7 días" → ningún spike anómalo no explicado.
- [ ] Entrada en `~/homelab/operations/maintenance.log` + commit `ops: maintenance YYYY-MM-DD weekly`.

### 9.3. Mensual (día 1 o primer fin de semana, ≤ 90 min)

- [ ] Log de `borgmatic-monthly-check.service` → `Archive consistency check complete, no problems found.`
- [ ] Smoke test L3 del servicio rotatorio del mes → arranca + verifica login/dato.
- [ ] `docker image prune -a --filter "until=720h" -f` aplicado.
- [ ] `docker volume ls -f dangling=true` revisado y purgado solo si seguro.
- [ ] `sudo du -h --max-depth=2 /mnt/hd{2,5}t/...` revisado y comparado con mes anterior.
- [ ] `docker images` revisado, ningún tag inesperadamente saltó a major.
- [ ] `git -C ~/homelab status` limpio o `push` aplicado.
- [ ] Entrada en `maintenance.log` + smoke test en `restore-tests.log` con sus commits.

### 9.4. Trimestral (Ene/Abr/Jul/Oct, ≤ 2 h)

- [ ] Pi-hole password rotado; gravity reconstruida.
- [ ] Sonarr/Radarr/Prowlarr API tokens regenerados.
- [ ] B2 app key regenerada y `rclone.conf` actualizado.
- [ ] Pi-hole listas revisadas; whitelist purgada.
- [ ] Indexers Prowlarr "Test All" → ≥ 80% OK.
- [ ] Grafana provisioning sincronizado con git; alertas silenciadas > 30 días resueltas.
- [ ] Entrada en `maintenance.log`.

### 9.5. Anual (aniversario, ≤ 4 h)

- [ ] Limpieza física (polvo, cables).
- [ ] microSD clonada a imagen `backup-YYYY.img` (guardada en `hd2t/backups/microsd/`).
- [ ] Threat model revisado y `~/homelab/threat-model.md` actualizado.
- [ ] Auditoría de stacks: ningún servicio "olvidado" sigue corriendo.
- [ ] (Opcional) SSH key, Borg passphrase rotadas si procede.
- [ ] Playbook (`docs/13-operaciones/01-mantenimiento-periodico.md`) revisado y commit con cambios.
- [ ] Entrada en `maintenance.log` + commit del aniversario.

---

## 10. Solución de Problemas

| Síntoma | Causa probable | Acción |
|---|---|---|
| El log `maintenance.log` lleva 6 semanas sin entrada nueva | Operador no está siguiendo el playbook semanal. | Sin acción técnica. Reconfigurar recordatorios del calendario; si la causa es burnout, considerar reducir el alcance del homelab antes que dejar de hacer mantenimiento. |
| Heartbeat de Borgmatic no llegó pero `journalctl -u borgmatic.service` dice "OK" | Canal de notificación (SMTP / Telegram bot) caído. | Probar `apprise -t test -b test` manualmente. Revisar credenciales `secrets/`. Watchdog inverso de Uptime Kuma debería haberlo detectado tras 48 h. |
| `borg check --verify-data` mensual reporta corrupción | Bit-rot en `hd2t` o write-error silencioso. | Detener el timer Borgmatic. Comparar con offsite (`rclone copy b2:homelab-borg/ /mnt/hd2t/backups/borg-restored/`). Investigar `dmesg` y `smartctl -A` de `hd2t`. Detalle en [`../07-backups/01-estrategia-backup.md`](../07-backups/01-estrategia-backup.md) §12. |
| Smoke test L3 falla por dump vacío | Hook `before_backup` del servicio se ejecutó pero no validó tamaño post-dump. | Añadir `[ -s file ]` post-dump en `borgmatic.yml`. Re-ejecutar smoke test. Documentar fix en `restore-tests.log`. |
| `docker system prune` apenas libera espacio | Las imágenes "viejas" siguen siendo referenciadas (Watchtower no rota tan rápido como se cree, o hay contenedores parados que las retienen). | `docker container prune` primero; luego `docker image prune -a`. Si sigue alto, revisar `docker buildx` cache y `/var/lib/docker/overlay2/` con `du -h --max-depth=1`. |
| `apt list --upgradable` siempre tiene los mismos 3 paquetes "kept back" semana tras semana | Esos paquetes tienen dependencias rotas o cambian dependencia (típico con `linux-image-rpi-*`). | `sudo apt full-upgrade -y`. Si pide reboot, hacerlo. Si rompe algo, log + `sudo apt -t bookworm-backports install ...` o pin de versión. |
| Espacio en `hd2t` cae 5% en una sola semana sin razón obvia | Servicio con bug de logs o cache (típico: Nextcloud `appdata_*/preview/`, Paperless OCR cache). | `du --max-depth=3 /mnt/hd2t/services/ \| sort -h \| tail -20`. Aplicar limpieza específica del servicio. |
| Pi-hole bloquea un dominio que un servicio recién añadido necesita | Dominio en una blocklist. | Pi-hole UI → Tools → Tail → confirmar el dominio bloqueado. Whitelist puntual en Pi-hole. Anotar en `maintenance.log`. |
| Watchtower deja servicios "olvidados sin actualizar" en cada ciclo | Falta la label `com.centurylinklabs.watchtower.enable: "true"` en su compose. | Decisión consciente: ¿debe entrar en update automático? Si sí, añadir la label y `docker compose up -d`. Si no, **es correcto** que esté excluido (caso de BD, Pi-hole, Authelia, HA). |
| Smoke test del mes da OK pero la app real falla en producción | El smoke test arrancó solo el contenedor sin validar funcionalidad real. | Mejorar el smoke test del servicio: añadir `curl` a un endpoint que dependa de la BD, no solo `/alive`. Patrón recomendado en [`../07-backups/03-backup-docker-volumes.md`](../07-backups/03-backup-docker-volumes.md) §6.4. |
| `smartctl` empieza a reportar `Reallocated_Sector_Ct` creciendo en `hd5t` o `hd2t` | Disco degradándose. | Empezar a planear reemplazo: pedir disco nuevo, programar fin de semana de migración. **Hasta entonces**: redoblar verificación de backups (offsite especialmente), no esperar a "ya veré". |
| El operador olvida la sesión semanal 3 fines de semana seguidos | Calendario inadecuado o el playbook es demasiado largo. | Reducir la sesión semanal a su versión mínima: §4.1 + §4.3 (≤ 10 min). Volver al playbook completo cuando vuelva el ritmo. **No** dar por bueno "ya recupero el mes que viene": las verificaciones semanales tienen valor temporal. |
| `git -C ~/homelab status` muestra cambios no commitea­dos durante semanas | Operador edita configs en producción y olvida commitear. | Disciplina: tras cada `docker compose up -d` exitoso, `git commit -am "feat(<svc>): <cambio>"`. Considerar un pre-commit hook que avise si `~/homelab/` lleva > 7 días dirty. |
| El playbook anual no se ejecutó porque "no es buen momento" | Aniversario coincidió con una semana ocupada. | Mover la sesión anual al **siguiente** fin de semana libre, **no** al "siguiente aniversario". Anotar fecha real en `maintenance.log` (cadencia `annual`). |

---

## Referencias

- [Borgmatic — `check` action](https://torsion.org/borgmatic/docs/reference/command-line/#check)
- [Borg — `borg check --verify-data`](https://borgbackup.readthedocs.io/en/stable/usage/check.html)
- [Docker — `docker system prune`](https://docs.docker.com/engine/reference/commandline/system_prune/)
- [Docker — `docker image prune`](https://docs.docker.com/engine/reference/commandline/image_prune/)
- [smartmontools — `smartctl(8)` man page](https://www.smartmontools.org/browser/trunk/smartmontools/smartctl.8.in)
- [smartmontools — `smartd.conf(5)` man page](https://www.smartmontools.org/browser/trunk/smartmontools/smartd.conf.5.in)
- [Debian — `unattended-upgrades` Wiki](https://wiki.debian.org/UnattendedUpgrades)
- [Watchtower — Documentation](https://containrrr.dev/watchtower/)
- [Uptime Kuma — Push Monitor](https://github.com/louislam/uptime-kuma/wiki/Monitor)
- [Apprise — Notification services](https://github.com/caronc/apprise/wiki)
- [Raspberry Pi — `vcgencmd` reference](https://www.raspberrypi.com/documentation/computers/os.html#vcgencmd)
- Convención del log de operaciones del homelab: ver [`../07-backups/03-backup-docker-volumes.md`](../07-backups/03-backup-docker-volumes.md) §0 y [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md).
