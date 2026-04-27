# Mantenimiento periódico del homelab

## Descripción

Define el **calendario operativo** del homelab una vez en marcha: qué tareas corren solas, qué tareas exigen al operador sentarse delante de la Pi (o de un terminal vía Tailscale), con qué cadencia, en qué orden y con qué criterio de "todo verde" antes de cerrar la sesión. Es el documento que convierte el homelab de "una colección de servicios desplegados" en "una colección de servicios **mantenidos**" — la diferencia entre las dos cosas se mide en meses, no en horas.

A diferencia de los docs de fase (que despliegan servicios con un compose nuevo), este documento **no instala nada**: vive entero como una **lista de checklists** + **plantillas de bitácora** + **mapeo de comprobaciones a docs concretos**. Cada item del calendario delega en otro doc del homelab para los detalles (`docs/07-backups/` para los _drills_ de restauración, `docs/00-hardware/03-preparacion-discos.md` para los chequeos SMART, `docs/02-docker/04-watchtower.md` para la disciplina de _opt-in_, etc.). Aquí se decide únicamente **cuándo** se ejecuta cada cosa, **quién** la dispara, y **qué se considera éxito**.

> **Filosofía del homelab**: el _stack_ entero está diseñado para minimizar el trabajo recurrente. Watchtower parchea CVEs solo, Borgmatic respalda solo, `unattended-upgrades` parchea el host solo, `smartd` vigila los discos solo, Uptime Kuma avisa solo, Prometheus alerta solo. Lo que el operador hace **periódicamente** son sobre todo dos cosas: **comprobar que esa automatización sigue funcionando** (¿hubo backup esta noche? ¿se aplicaron parches el domingo?) y **decidir conscientemente lo que ninguna automatización debe decidir** (¿paso Nextcloud de la 30 a la 31? ¿restauro este drill o paso?). Si el calendario aquí descrito acaba pareciendo "demasiado trabajo", probablemente algo de la automatización se ha roto o se ha bypaseado.

> **Alcance**: este documento cubre **mantenimiento ordinario**. La recuperación tras desastre (Pi en llamas, disco perdido, repo Borg corrupto) vive en `docs/13-operaciones/02-disaster-recovery.md`. La auditoría de rendimiento (CPU al 90 %, _throttling_ térmico, latencias raras) vive en `docs/13-operaciones/03-rendimiento-pi5.md`. El mapa de puertos y firewall vive en `docs/13-operaciones/04-red-y-puertos.md`. Las cuatro piezas son de la misma fase y se cruzan, pero cada una tiene su propio enfoque.

> **Recordatorio de red**: todo el mantenimiento se hace **desde la LAN** o **vía Tailscale** (`docs/03-red/05-tailscale.md`). No hay puertos abiertos al exterior; un `ssh homelab@pi.tailnet.ts.net` desde cualquier dispositivo del _tailnet_ es la sesión típica de mantenimiento. Si el operador está en casa, `ssh homelab@192.168.1.3` (la IP de la Pi en la LAN) sirve igual.

---

## Requisitos previos

Este doc cierra la **fase 13** y por tanto asume que **todo el resto del homelab está en marcha**. Las dependencias concretas son:

- `docs/00-hardware/03-preparacion-discos.md` completado: ambos discos (`hd5t`, `hd2t`) montados, etiquetados y con `smartd` activo. Sin SMART, el bloque mensual de salud de discos pierde sentido.
- `docs/01-sistema/02-configuracion-inicial.md` completado: hora correcta vía NTP, zona horaria `Europe/Madrid`, journald rotando con límite de tamaño. Las marcas temporales de los _logs_ y de los _archives_ Borg son el eje del calendario; un reloj a la deriva lo convierte en ficción.
- `docs/01-sistema/03-seguridad-base.md` completado: `unattended-upgrades` activo, `fail2ban` con _jail_ SSH operativo, `nftables` cargado. La revisión semanal de _bans_ y el log mensual de parches de seguridad dependen de esto.
- `docs/02-docker/02-estructura-compose.md` completado: el repositorio `~/homelab/` existe en git, el _Makefile_ está disponible (`make up`, `make pull`, `make ps`, `make logs`), todos los _stacks_ de las fases 2-12 viven en sus subdirectorios. El operador hace `make ps STACK=<nombre>` sin pensar.
- `docs/02-docker/04-watchtower.md` completado: Watchtower corre los domingos a las 04:00 con _opt-in_ por _label_; los servicios "auto-actualizables" llevan `com.centurylinklabs.watchtower.enable: "true"` y los "actualización manual" no. La revisión post-Watchtower del lunes presupone que ese mecanismo está en marcha.
- `docs/05-monitorizacion/05-uptime-kuma.md` completado: cada servicio crítico tiene un monitor en Uptime Kuma con notificación a ntfy/Telegram/email. El primer chequeo semanal es "abrir Uptime Kuma y ver que todo está verde" — sin esa pieza, el operador acaba haciendo la ronda con `curl` a mano.
- `docs/05-monitorizacion/01-prometheus.md` y `docs/05-monitorizacion/02-grafana.md` completados: las _alerting rules_ críticas (CPU sostenida > 80 %, RAM disponible < 500 MB, disco > 85 %, temperatura CPU > 80 °C, `borg_last_run_timestamp_seconds > 26h`, `up == 0` en cualquier exporter) ya disparan notificación. La revisión mensual de "qué alertó este mes" se apoya en el _Alertmanager_ o en los dashboards de Grafana.
- `docs/07-backups/01-estrategia-backup.md`, `docs/07-backups/02-borgmatic.md` y `docs/07-backups/03-backup-docker-volumes.md` completados: el calendario de backups (daily 03:30, weekly check, monthly verify-data) ya existe. Aquí sólo se **revisa que cumple**, no se redefine.
- Todos los _stacks_ de las fases 3-12 desplegados, con sus respectivas secciones **Backup** y **Verificación final** ejecutadas. Esto importa porque la primera ronda mensual del operador tras cerrar la fase 12 va a tocar **todo** el homelab — si quedaron fases a medias, las comprobaciones detectarán _gaps_ que pertenecen a esas fases, no al mantenimiento.
- Acceso a `~/homelab/` desde la sesión SSH del operador con permiso de _commit_ a git (clave SSH del repositorio remoto cargada en `ssh-agent` o equivalente). Una buena parte de las tareas mensuales acaban con un _commit_ a `~/homelab/` (cambio de _tag_ pinneado, ajuste del Caddyfile, edición de un `.env.example`, anotación en la bitácora).
- Una **bitácora** donde anotar las rondas. El homelab escoge un fichero por mes en `~/homelab/docs/journal/YYYY-MM.md` (ver más abajo). Si el operador prefiere su propio sistema (Bookstack, Linkding, papel), la regla mínima es que las anotaciones existan y sean recuperables. Sin bitácora se pierde la memoria de "ya he tenido este problema antes" y cada ronda se vive como la primera.

---

## Decisiones de diseño

### Cadencia: cinco escalones, no un único calendario

El homelab divide el mantenimiento en **cinco escalones temporales** distintos, cada uno con un actor distinto y un objetivo distinto. La razón de no fusionarlos en "un cron grande" es que cada escalón tiene un coste cognitivo diferente y un riesgo distinto si se salta:

| Escalón     | Quién lo dispara                                                  | Coste de tiempo (operador) | Coste de saltarse uno                                                           |
|-------------|-------------------------------------------------------------------|----------------------------|---------------------------------------------------------------------------------|
| **Diario**  | _crons_, _systemd timers_, _daemons_ (`borgmatic.timer`, `unattended-upgrades`, `smartd`, Watchtower como _watcher_, Uptime Kuma) | 0 min (todo automático)    | Backup perdido, parche perdido, sector defectuoso no detectado.                 |
| **Semanal** | Operador, ~10-15 min, lunes por la mañana (después del Watchtower del domingo) | 10-15 min/semana           | Drift acumulado: alguna actualización rompió algo y nadie se enteró 3 semanas.  |
| **Mensual** | Operador, ~30-45 min, primer sábado del mes                        | 30-45 min/mes              | SMART degradado pasa desapercibido; espacio en disco se cuela hasta el 95 %; un drill de restore que falla en 6 meses se descubre cuando hace falta restaurar de verdad. |
| **Trimestral** | Operador, ~1-2 h, primer sábado de enero/abril/julio/octubre   | 1-2 h/trimestre            | _Major bumps_ de servicios se acumulan; pasar de Nextcloud 30 → 33 sin escalas es mucho peor que 30 → 31 → 32 → 33. |
| **Anual**   | Operador, ~medio día, en una fecha fija (cumpleaños del homelab)   | ~4-6 h/año                 | Passphrase de Borg sin rotar en años, CA local de Caddy caducada, proveedor offsite no auditado, tokens stale en Vaultwarden. |

> **Por qué lunes para el semanal**: Watchtower corre los domingos a las 04:00. Si algún _bump_ rompe un servicio, las primeras horas del lunes son cuando el operador descubrirá el daño con los _logs_ todavía calientes. Esperar al sábado siguiente significaría 6 días con un servicio caído (o peor: con un servicio "casi caído" que sólo falla en algunos endpoints). Lunes minimiza el _time-to-detection_.

> **Por qué primer sábado para el mensual**: el sábado es operativo (no laboral, hay tiempo) y el primer sábado del mes da una referencia anclada al calendario que es más fácil de recordar que "el día 5". Los `borgmatic.timer` ya disparan el drill mensual el día 1; el operador llega el primer sábado siguiente con un dump fresco que verificar.

> **Por qué primer sábado del trimestre**: añade carga sobre el primer sábado del mes en cuestión (enero/abril/julio/octubre), pero combina dos rondas en una sola sesión larga. Si esto resulta excesivo, basta con desplazar el trimestral al segundo sábado para no solapar.

### Automatizar lo automatizable, decidir lo decidible

El homelab pone una línea muy clara entre dos categorías:

- **Cosas que ninguna persona tiene que tocar mensualmente**: parches de seguridad de Debian (`unattended-upgrades`), parches semánticamente _patch_ de los contenedores _opt-in_ (Watchtower), backups Borg locales y offsite (Borgmatic), monitorización de SMART (`smartd`), monitorización de servicios (Uptime Kuma + Prometheus). Si se descubre que el operador está haciendo manualmente algo de esta lista, **el bug está en la automatización**, no en el calendario.
- **Cosas que requieren juicio humano**: pasar de un _major_ a otro (Nextcloud 30 → 31, MariaDB 11 → 12, Home Assistant breaking change), evaluar si un drill de restauración salió "limpio" o sólo "no rompió", decidir si una alerta de Uptime Kuma (`Sonarr down 5 min`) es un fallo de Sonarr o de la red, decidir si una métrica anómala (RAM al 80 % sostenido) es un servicio que se ha empezado a usar más o un _memory leak_. Esto **nunca** se automatiza; el calendario aquí lo programa para que el operador no lo evite.

### Listas de comprobación, no _runbooks_ enciclopédicos

Cada bloque de este documento es una **lista de comprobación corta**, no un _runbook_ detallado. La razón: los _runbooks_ enciclopédicos no se siguen al pie de la letra después del segundo mes. Una checklist de 6-10 items se cumple; un _runbook_ de 40 pasos se "leen los primeros 5 y se asume el resto".

Cuando un item de la checklist necesita más detalle (ej. "verificar SMART"), se delega al doc de fase correspondiente (`docs/00-hardware/03-preparacion-discos.md`). El operador hace `man -k smartctl` o consulta el doc enlazado si necesita el comando exacto; la checklist sólo recuerda **que toca hacerlo**.

### Bitácora: el eslabón que falta entre "lo hice" y "lo recuerdo"

Sin registro escrito, una ronda mensual no se distingue de la del mes pasado. Con registro, **cada ronda construye memoria operativa**:

- "Hace 4 meses que el _free space_ de `hd2t` viene bajando 1.5 GB/mes — toca planificar limpieza o expansión".
- "El drill de restauración de Vaultwarden ha tardado 3 minutos los últimos seis meses; este mes ha tardado 12 — algo cambió".
- "El _Pi-hole gravity update_ falla de vez en cuando con una _blocklist_ concreta — es la tercera vez, toca quitarla".

La bitácora vive en `~/homelab/docs/journal/YYYY-MM.md` (un fichero por mes), versionado en git, con un formato libre pero con **secciones fijas por ronda** (semanal, mensual, trimestral). Plantilla más abajo. Si el operador prefiere otra herramienta (Bookstack es ideal para este uso una vez desplegado en `docs/11-productividad/02-bookstack.md`), basta con replicar la plantilla allí.

### Cero alarmismo: lo verde es lo aburrido

El indicador de salud del homelab no son los _logs_ verdes — son los _logs_ **aburridos**. Un mes sin nada notable en la bitácora es un mes bueno. La tentación natural del operador es "buscar problemas para sentirse útil"; el calendario está deliberadamente diseñado para que la mayor parte del tiempo no haya problemas que buscar y para que las acciones sean **comprobaciones**, no _troubleshooting_.

Cuando aparece algo rojo (alerta sostenida, drill que falla, métrica fuera de rango), el item de la checklist **se cierra con una entrada explícita** ("Alerta `disk_pct_used > 85` desde 2026-04-12; mitigada con `docker image prune -af` el 2026-04-15. Pendiente: revisar retención del repo Borg local"). Si no se anota, la siguiente ronda no sabe que se mitigó.

---

## Calendario consolidado

Vista global. Cada celda referencia el bloque del documento donde se detalla.

| Cuándo                           | Disparador                                | Acción                                                                                       | Sección                       |
|----------------------------------|-------------------------------------------|----------------------------------------------------------------------------------------------|-------------------------------|
| **Continuo**                     | `smartd` (host)                           | Vigila atributos SMART, dispara `mail` o `ntfy` en degradación                                | _Tareas diarias automatizadas_ |
| **Continuo**                     | Uptime Kuma                               | Pinguea cada servicio cada 60 s; notifica si `up == 0`                                        | _Tareas diarias automatizadas_ |
| **Continuo**                     | Prometheus + Alertmanager                 | Evalúa _alerting rules_ cada 15 s; notifica si _firing_                                       | _Tareas diarias automatizadas_ |
| **Diario 03:30**                 | `borgmatic.timer`                         | Dump SQL + `borg create` local & offsite + prune                                              | _Tareas diarias automatizadas_ |
| **Diario 06:00**                 | `apt-daily.timer` + `apt-daily-upgrade.timer` | `apt update` + `unattended-upgrades` aplica seguridad                                     | _Tareas diarias automatizadas_ |
| **Domingo 04:00**                | Watchtower _cron_                         | Pull de _patch releases_ en servicios _opt-in_ + recreate                                     | _Tareas diarias automatizadas_ |
| **Domingo 04:30**                | `borgmatic` weekly                        | `borg check --verify-data` repo local                                                         | _Tareas diarias automatizadas_ |
| **Lunes mañana**                 | Operador (10-15 min)                      | Revisar Watchtower del domingo, Uptime Kuma, alertas, espacio                                 | _Ronda semanal_               |
| **Día 1 del mes 05:00**          | `borgmatic` monthly                       | `borg check --verify-data` repo offsite + drill mensual auto                                  | _Tareas diarias automatizadas_ |
| **Primer sábado del mes**        | Operador (30-45 min)                      | SMART completo, espacio detallado, Docker prune, drill de restore Vaultwarden, parches review | _Ronda mensual_               |
| **Primer sábado de trimestre**   | Operador (1-2 h, suma sobre el mensual)   | Drill restore complejo, _major bumps_ revisados, audit Authelia, audit Tailscale ACLs         | _Ronda trimestral_            |
| **Cumpleaños del homelab**       | Operador (medio día)                      | Rotación passphrase Borg, audit completo de `.env`, DR drill completo, revisión proveedor offsite, decisión "¿sigue justificado cada servicio?" | _Ronda anual_                 |

---

## Tareas diarias automatizadas (cero intervención)

El operador **no toca** ninguna de estas. Lo que se documenta aquí es **dónde mirar si una falla** (la ronda semanal verificará que han corrido).

### Borgmatic (03:30 local)

- Disparador: `borgmatic.timer` (`docs/07-backups/02-borgmatic.md`).
- Salida esperada: dos _archives_ nuevos (uno por repo local, uno por repo offsite) + notificación `after_backup` a ntfy.
- Verificación rápida si se sospecha que no corrió:
  ```bash
  systemctl list-timers borgmatic.timer
  journalctl -u borgmatic.service --since "yesterday" -n 100 --no-pager
  sudo borg list /mnt/hd2t/backups/borg/homelab/ | tail -3
  ```

### `unattended-upgrades` (06:00 local aprox.)

- Disparador: `apt-daily.timer` + `apt-daily-upgrade.timer` (`docs/01-sistema/03-seguridad-base.md`).
- Salida esperada: log diario en `/var/log/unattended-upgrades/unattended-upgrades.log`. Si ese día había parches de seguridad, se aplican; si no, el log lo dice.
- Verificación rápida:
  ```bash
  systemctl list-timers apt-daily*
  sudo tail -50 /var/log/unattended-upgrades/unattended-upgrades.log
  ```

### `smartd` (continuo)

- Disparador: `smartmontools` arrancado al boot (`docs/00-hardware/03-preparacion-discos.md`).
- Salida esperada: silencio. `smartd` sólo manda mail/ntfy si detecta degradación (atributos SMART en zona crítica, _self-test_ fallido).
- Verificación rápida:
  ```bash
  systemctl status smartd --no-pager
  sudo smartctl -H /dev/disk/by-label/hd5t
  sudo smartctl -H /dev/disk/by-label/hd2t
  ```

### Watchtower (domingos 04:00 local)

- Disparador: `WATCHTOWER_SCHEDULE=0 0 4 * * 0` dentro del contenedor (`docs/02-docker/04-watchtower.md`).
- Salida esperada: pase semanal con _N_ contenedores escaneados, _M_ actualizados (siempre M ≪ N porque la mayoría no tienen _patch_ nuevo cada semana). _Logs_ en `docker logs watchtower`.
- Verificación rápida (lunes mañana):
  ```bash
  docker logs watchtower --since 36h | tail -100
  ```

### Uptime Kuma + Prometheus + Alertmanager (continuo)

- Disparadores: contenedores en marcha (`docs/05-monitorizacion/`).
- Salida esperada: notificación inmediata si `up == 0`, alerta Prometheus si una _rule_ entra en `firing`. Sin notificaciones, todo OK.
- Verificación rápida:
  - Abrir Uptime Kuma: `https://uptime.lan/`. Todos los monitores en verde.
  - Abrir Grafana → dashboard "Homelab Overview": ninguna alerta activa.

---

## Ronda semanal (lunes, 10-15 min)

**Objetivo**: confirmar que el _Watchtower run_ del domingo no rompió nada, que los backups han corrido cada noche y que ninguna alerta ha quedado abierta sin atender. Es la ronda más corta y la que **nunca** se salta.

### Checklist semanal

```markdown
## Ronda semanal — YYYY-MM-DD

- [ ] **Watchtower run del domingo**
      `docker logs watchtower --since 36h | grep -E 'Found [0-9]|Session done|updated|error'`
      → ¿cuántos escaneados, cuántos actualizados, errores? Anotar lista de servicios actualizados.
- [ ] **Estado de todos los stacks**
      `for s in $(ls -d ~/homelab/*/ 2>/dev/null | xargs -n1 basename); do
         echo "=== $s ==="
         make ps STACK=$s 2>/dev/null
       done`
      → todos los servicios en `Up` o `Up (healthy)`. Cualquier `Restarting`, `unhealthy`, `Exited` se anota.
- [ ] **Backups de los últimos 7 días**
      `sudo borg list /mnt/hd2t/backups/borg/homelab/ --last 10`
      → 7 _archives_ nuevos, uno por noche. Cualquier hueco (un día sin archive) se investiga: `journalctl -u borgmatic.service --since "7 days ago"`.
- [ ] **Notificaciones acumuladas en ntfy/email**
      Revisar el canal de notificaciones. Cero notificaciones rojas (`on_error`, `firing`). Las verdes (`after_backup`, info) sólo se cuentan.
- [ ] **Uptime Kuma**
      Abrir `https://uptime.lan/` → todo verde. Si algún monitor tiene incidentes en los últimos 7 días, abrirlos y comprobar si están resueltos. Anotar si quedó alguno sin investigar.
- [ ] **fail2ban**
      `sudo fail2ban-client status sshd`
      → Mirar `Currently failed`/`Currently banned`. Anotar si hay un pico inusual (decenas de IPs distintas en una semana). Si hay IPs banadas activas, se aceptan; sólo es ruido raro lo que importa.
- [ ] **Espacio en disco — _quick check_**
      `df -h /mnt/hd2t /mnt/hd5t /`
      → ningún sistema de ficheros por encima de 80 %. Si lo está, abrir item para la ronda mensual o resolverlo en el momento.
- [ ] **Anotar en la bitácora**
      `~/homelab/docs/journal/YYYY-MM.md` → entrada bajo "Semana NN" con resumen (cualquier item rojo, cualquier servicio actualizado por Watchtower, cualquier acción adicional).
- [ ] **Commit de la bitácora**
      `cd ~/homelab && git add docs/journal/ && git commit -m "ops: ronda semanal YYYY-WNN" && git push` (si el remote existe).
```

### Tiempo objetivo y _trade-offs_

- **5 minutos** si todo está en verde. Es lo normal el ~80 % de las semanas.
- **10-15 minutos** si hay algún item rojo que investigar (un servicio en `Restarting`, una IP curiosa en fail2ban, un _archive_ Borg que faltó porque la Pi se apagó por una tormenta).
- **> 30 minutos** = algo está mal y la ronda semanal se ha convertido en _troubleshooting_. Anotar exactamente qué se está investigando, parar a las 30 min, abrir un _ticket_ en la bitácora ("Pendiente: investigar `Restarting` de Sonarr"), continuar otro día con cabeza fría.

> **Regla**: la ronda semanal **no es** el momento de "arreglar lo que no estaba previsto". Es el momento de **detectar** que hay algo que arreglar y dejarlo apuntado. La reparación entra en la cola del operador como tarea aparte, posiblemente desplazada al mensual o a un día concreto.

---

## Ronda mensual (primer sábado, 30-45 min)

**Objetivo**: profundizar más allá de "está corriendo": comprobar salud física de los discos, verificar que los _drills_ automatizados pasaron, hacer una restauración de prueba de Vaultwarden, revisar logs no obvios, planificar parches manuales pendientes y dejar el _stack_ Docker limpio.

### Checklist mensual

```markdown
## Ronda mensual — YYYY-MM

### 1. Hardware y discos
- [ ] **SMART manual**
      `sudo smartctl -H /dev/disk/by-label/hd5t`
      `sudo smartctl -H /dev/disk/by-label/hd2t`
      → ambos `PASSED`. Si alguno marca `FAILING_NOW` o `FAILED_PAST`, prioridad máxima — leer atributos: `sudo smartctl -A /dev/disk/by-label/hdXt`.
- [ ] **Atributos SMART clave**
      `sudo smartctl -A /dev/disk/by-label/hd5t | grep -E 'Reallocated_Sector_Ct|Current_Pending_Sector|Offline_Uncorrectable|UDMA_CRC_Error_Count|Power_On_Hours|Temperature'`
      `sudo smartctl -A /dev/disk/by-label/hd2t | grep -E 'Reallocated_Sector_Ct|Current_Pending_Sector|Offline_Uncorrectable|UDMA_CRC_Error_Count|Power_On_Hours|Temperature'`
      → comparar con la entrada del mes pasado. Cualquier crecimiento de `Reallocated_Sector_Ct`, `Current_Pending_Sector` o `Offline_Uncorrectable` desde 0 a > 0 es **alerta seria** (planificar reemplazo).
- [ ] **Self-test largo (programado, no inmediato)**
      Lanzar antes de la ronda y comprobar el resultado al terminar:
      `sudo smartctl -t long /dev/disk/by-label/hd2t` (~3-6 h, en background)
      → al final del día: `sudo smartctl -l selftest /dev/disk/by-label/hd2t | head` debe acabar en `Completed without error`.
      Alternar mes a mes entre `hd5t` y `hd2t` para no saturar la Pi con dos _self-tests_ simultáneos.
- [ ] **Temperatura CPU media del mes**
      Grafana → dashboard "Pi 5 Temperatura" → ¿hubo picos > 80 °C? Si sí, anotar y cruzar con `docs/13-operaciones/03-rendimiento-pi5.md` (¿toca limpiar disipador, revisar carcasa, ajustar overclock?).

### 2. Backups
- [ ] **`borg check --verify-data` del repo offsite (mensual auto)**
      Confirmar que el _systemd timer_ mensual del día 1 corrió:
      `journalctl -u borgmatic.service --since "first of month" | grep -E 'verify-data|error'`
      → debe haber un mensaje de éxito sin errores en el repo offsite.
- [ ] **Drill de restauración de Vaultwarden**
      ```bash
      ARCHIVE=$(sudo borg list /mnt/hd2t/backups/borg/homelab/ --last 1 --short)
      sudo borg extract --target /tmp/restore-test \
        /mnt/hd2t/backups/borg/homelab/::$ARCHIVE \
        mnt/hd2t/services/vaultwarden
      ls -la /tmp/restore-test/mnt/hd2t/services/vaultwarden/data/
      file /tmp/restore-test/mnt/hd2t/services/vaultwarden/data/db.sqlite3
      sudo rm -rf /tmp/restore-test
      ```
      → debe haber `db.sqlite3` íntegro (`SQLite 3.x database`). Anotar tiempo total. Si el drill falla, es **prioridad cero**: el backup no sirve si no se restaura.
- [ ] **Drill alternativo (un servicio distinto cada mes)**
      Rotar entre Nextcloud BD, Paperless, Bookstack, Mealie. Procedimiento detallado en `docs/07-backups/03-backup-docker-volumes.md`.
- [ ] **Tamaño del repo Borg (local + offsite)**
      `sudo borg info /mnt/hd2t/backups/borg/homelab/ | grep -E 'Original size|Deduplicated size|Number of files|This archive|All archives'`
      → comparar el "All archives" con el del mes pasado. Crecimiento esperado: < 5 % mensual con un homelab estable. Si crece > 20 % en un mes, algo nuevo está entrando al backup que quizá no debería (¿cache que no se excluye? ¿fichero gigante temporal?).

### 3. Espacio en disco y Docker
- [ ] **Espacio detallado por carpeta**
      `sudo du -sh /mnt/hd2t/services/* | sort -h`
      `sudo du -sh /mnt/hd2t/backups/* | sort -h`
      `sudo du -sh /mnt/hd5t/* | sort -h`
      → identificar qué servicios crecen más rápido. Anotar el _top 3_ y comparar con el mes pasado.
- [ ] **Limpieza Docker**
      `docker system df`
      → ver el _reclaimable_. Si > 5 GB:
      `docker image prune -af --filter "until=168h"`
      `docker container prune -f --filter "until=72h"`
      `docker volume prune -f`  (cuidado: revisa lo que va a borrar, son _named volumes_ no asociados a ningún contenedor; ningún servicio del homelab usa _named volumes_ relevantes — todo está en bind mounts en `/mnt/hd2t/services/`)
      `docker builder prune -af` (caché de _buildx_, sólo si se hubieran hecho `docker build` locales)
      → anotar GB liberados.
      > **Aviso**: Watchtower con `WATCHTOWER_CLEANUP=true` ya borra imágenes obsoletas tras cada actualización. La limpieza manual mensual sólo recoge lo que Watchtower no toca: imágenes de servicios sin _opt-in_ que se actualizaron a mano, capas huérfanas de _builds_ antiguos, contenedores parados que se olvidaron.
- [ ] **`/var/log` y journald**
      `sudo journalctl --disk-usage`
      → si > 500 MB, considerar `sudo journalctl --vacuum-time=30d`. La rotación está ajustada en `docs/01-sistema/02-configuracion-inicial.md` pero conviene verificar.
      `sudo du -sh /var/log/*` → identificar logs gigantes (rsyslog, journal, samba…).

### 4. Logs y eventos
- [ ] **`unattended-upgrades` del mes**
      `sudo cat /var/log/unattended-upgrades/unattended-upgrades.log | grep -E 'Packages that will be upgraded|Allowed origins|ERROR'`
      → resumen de qué se parcheó. Anotar si hubo `ERROR`. Si no se aplicó nada en todo el mes (raro), revisar `Allowed-Origins`.
- [ ] **fail2ban — bans del mes**
      `sudo zgrep -h 'Ban\|Unban' /var/log/fail2ban.log* | wc -l`
      `sudo zgrep -h 'Ban' /var/log/fail2ban.log* | awk '{print $NF}' | sort | uniq -c | sort -rn | head`
      → top de IPs bloqueadas. Si una IP repite con persistencia desde semanas, considerar `nftables` `drop` permanente.
- [ ] **Logs de errores por _stack_**
      `for s in $(ls -d ~/homelab/*/ 2>/dev/null | xargs -n1 basename); do
         echo "=== $s ==="
         make logs STACK=$s 2>/dev/null | tail -5000 | grep -iE 'ERROR|FATAL|panic' | tail -10
       done`
      → ojear los _ERROR_ frecuentes. Es habitual que cada servicio tenga su _ruido_ propio (Jellyfin avisa de _codecs_ no soportados, Sonarr avisa de indexadores caídos transitoriamente). Lo que se busca es **lo nuevo o lo que se acumula**.
- [ ] **Pi-hole — listas de bloqueo**
      Abrir UI Pi-hole → "Tools → Update Gravity". Si algún _adlist_ falla (404, _SSL error_), retirarlo.
- [ ] **Caddy — CA local**
      `docker exec caddy ls /data/caddy/pki/authorities/local/`
      → confirmar que el certificado de la CA no está cerca de caducar (válida ~10 años por defecto, no es prioritario, pero conviene anotar la fecha de caducidad la primera vez).

### 5. Parches manuales pendientes
- [ ] **Inventario de _tags_ pinneados**
      Revisar los `_IMAGE_TAG` de cada `.env` y comparar con el _release_ más reciente del proyecto. Lista mínima a comprobar (los que **no** están bajo Watchtower):
      - Nextcloud, MariaDB, PostgreSQL, Redis (`docs/06-almacenamiento/01-nextcloud.md`).
      - Vaultwarden (`docs/11-productividad/01-vaultwarden.md`).
      - Home Assistant, Mosquitto, Zigbee2MQTT (`docs/08-domotica/`).
      - Authelia (`docs/04-seguridad/01-authelia.md`).
      - Stash, Paperless-ngx, Bookstack (sus respectivos docs).
      Para cada uno, abrir el repo de _releases_ y leer el changelog del intervalo "tag actual → último". Si hay un _patch release_ trivial (`30.0.5 → 30.0.6`), agendar el bump para el sábado siguiente. Si hay un _major_ (`30 → 31`), esperar al trimestral.
- [ ] **Anotar en la bitácora**
      Lista clara: "para el sábado próximo: bump Vaultwarden a 1.32.5, bump Mealie a 2.7.1". Sin lista, los bumps se posponen indefinidamente.

### 6. Cierre
- [ ] **Bitácora del mes cerrada**
      `~/homelab/docs/journal/YYYY-MM.md` → entrada "Ronda mensual" con todo lo anotado.
- [ ] **Commit**
      `cd ~/homelab && git add docs/journal/ && git commit -m "ops: ronda mensual YYYY-MM" && git push`
- [ ] **Cualquier configuración tocada en la ronda**
      Si la ronda tocó `~/homelab/<stack>/` (cambio de tag, exclusión nueva en borgmatic, regla nft, …), commit aparte con mensaje específico (no mezclar con la bitácora).
```

### Tiempo objetivo y _trade-offs_

- **30 minutos** si nada destacable + el _self-test_ SMART corriendo al fondo.
- **45 minutos** si hay 1-2 items rojos sin investigar (típico).
- **> 60 minutos** = algo serio. Anotar y reservar otro día para resolver. La ronda mensual no es la sesión de _patch fest_.

---

## Ronda trimestral (primer sábado de enero/abril/julio/octubre, +1-2 h sobre el mensual)

**Objetivo**: lo que el mensual no alcanza por tiempo o profundidad. _Major bumps_ planificados, _drills_ de servicios complejos, auditoría de _surface area_ (Authelia, Tailscale, Caddy, Pi-hole), revisión de la documentación versionada vs. estado real.

### Checklist trimestral

```markdown
## Ronda trimestral — YYYY-Qn

### 1. Drills profundos
- [ ] **Restauración completa de Home Assistant**
      Procedimiento en `docs/07-backups/03-backup-docker-volumes.md`. Restaurar a `/tmp/restore-ha/` y arrancar un Home Assistant temporal en otro puerto. Verificar que el _frontend_ carga, que las automatizaciones aparecen, que `secrets.yaml` está descifrado correctamente.
      → tiempo objetivo: 30-45 min. Si > 1 h, hay un fallo en el procedimiento de backup.
- [ ] **Restauración de Paperless-ngx**
      Dump Postgres + extracción de `media/documents/`. Abrir un documento aleatorio escaneado y verificar que el OCR sigue siendo legible.
- [ ] **Restauración Nextcloud BD + un usuario**
      Dump MariaDB + chunk de `data/<usuario>/files/`. Importar dump a un MariaDB temporal y `SELECT COUNT(*) FROM oc_users`. El conteo debe coincidir con el del homelab vivo.

### 2. Major bumps planificados
- [ ] **Lista de _major bumps_ pendientes**
      Recoger los que aparecieron en las 3 rondas mensuales del trimestre. Para cada uno:
      1. Leer **toda** la _release notes_ del _major_ (no sólo del último _minor_).
      2. Hacer un dump fresco antes (`borgmatic --override 'archive_name_format=...pre-bump-<servicio>'`).
      3. Editar el `_IMAGE_TAG` en el `.env` correspondiente.
      4. `make pull STACK=<stack> && make up STACK=<stack>`.
      5. Validación funcional (login, abrir un dashboard, ejecutar una acción típica).
      6. Si todo OK, _commit_ del cambio. Si algo se rompe: _rollback_ al tag previo (no se borró por `WATCHTOWER_CLEANUP` porque este servicio no estaba en _opt-in_; la imagen vieja está aún), reportar problema en la bitácora.
- [ ] **Versión de Docker Engine**
      `docker version` → comparar con el _release_ más reciente. Si hay un _minor bump_ del engine (24.0 → 24.1), planificar bump para el siguiente sábado fuera de la ronda. El engine no se actualiza con Watchtower.
- [ ] **Versión del kernel y de Raspberry Pi OS**
      `uname -r` y `cat /etc/os-release`. Si hay un _release_ mayor de Raspberry Pi OS (cambio de _stable_ Debian), planificar migración separada (no en esta ronda).

### 3. Audit de seguridad
- [ ] **Authelia — usuarios y 2FA**
      Revisar `users_database.yml`. Confirmar que cada usuario sigue justificándose y que todos tienen 2FA activo (TOTP enrolado). Quitar usuarios obsoletos.
- [ ] **Tailscale — dispositivos del _tailnet_**
      `tailscale status` o admin web → listar dispositivos. Cada dispositivo desconocido o inactivo > 90 días se elimina.
- [ ] **Tailscale — ACLs**
      Revisar el JSON de ACLs. Si se han añadido dispositivos nuevos al _tailnet_, validar que las reglas siguen siendo coherentes.
- [ ] **Caddy — endpoints expuestos**
      Listar todos los `*.lan` en el `Caddyfile`. Para cada uno, confirmar que el servicio sigue activo y que la auth (Authelia o nativa) es correcta. Eliminar bloques de servicios retirados.
- [ ] **Pi-hole — clientes activos vs. dispositivos reales**
      UI Pi-hole → "Network". Si aparece un cliente con IP sin reverse DNS conocido (`unknown`) y tráfico significativo, investigar.
- [ ] **fail2ban — IPs banadas permanentes**
      Si una IP ha sido banada > 5 veces en el trimestre, agregar `nftables drop` permanente:
      ```nft
      table inet filter {
          set bad_ips_perm { type ipv4_addr; flags interval; elements = { 1.2.3.0/24 } }
          chain input { ip saddr @bad_ips_perm drop }
      }
      ```
- [ ] **Tokens y API keys**
      Revisar Vaultwarden. Para cada token de servicio (Sonarr → Prowlarr, Homepage → Pi-hole, Homarr → Jellyfin…), confirmar que sigue activo y que el servicio sigue accesible. Rotar el que parezca _stale_.

### 4. Documentación
- [ ] **Diff entre `~/homelab/` real y la doc**
      Para cada servicio del trimestre, leer su doc (`docs/<fase>/<servicio>.md`) y comparar con el compose y `.env` real. Si hay drift (variables nuevas que no se documentaron, _ports_ cambiados, _labels_ añadidas), actualizar la doc en el mismo _commit_.
- [ ] **`SERVICES.md` y `PLAN.md`**
      Revisar la lista canónica. Si hay servicios desplegados que no están en `SERVICES.md` (raro, pero posible si un trimestre se añadió uno experimental), añadirlos. Si hay servicios listados que se desplegaron y luego se retiraron, marcarlos.

### 5. Cierre
- [ ] **Resumen del trimestre en la bitácora**
      `~/homelab/docs/journal/YYYY-Qn.md` (fichero aparte, formato libre, con foco en lo aprendido).
- [ ] **Commit y push**
      `cd ~/homelab && git add . && git commit -m "ops: ronda trimestral YYYY-Qn" && git push`
```

---

## Ronda anual ("cumpleaños del homelab", medio día)

**Objetivo**: rotar todo lo que tiene que rotarse anualmente (passphrases, claves), volver a tomar las grandes decisiones (¿el proveedor offsite sigue siendo el adecuado? ¿este servicio sigue justificándose?), ejecutar un disaster recovery completo en una Pi auxiliar, dejar la documentación al día.

### Checklist anual

```markdown
## Ronda anual — YYYY

### 1. Rotación de credenciales y claves
- [ ] **Passphrase del repo Borg**
      `BORG_PASSPHRASE=<vieja> borg key change-passphrase /mnt/hd2t/backups/borg/homelab/`
      `BORG_PASSPHRASE=<vieja> borg key change-passphrase ssh://<user>@<offsite>:repo`
      Generar la nueva con `pwgen -s 30 1`. Actualizar:
      - `~/homelab/<stack-borgmatic>/.env` (variable `BORG_PASSPHRASE`).
      - Vaultwarden (entrada "Homelab — Borg passphrase").
      - Gestor externo (Bitwarden cloud o equivalente).
      - Copia papel en caja fuerte / sobre cerrado.
      → confirmar que `borgmatic --dry-run` sigue abriendo los repos con la nueva.
- [ ] **Clave SSH de backups offsite**
      Generar nueva clave dedicada (`ssh-keygen -t ed25519 -C "borgmatic-YYYY"`), añadir al destino, retirar la vieja. Validar con `borgmatic --dry-run`.
- [ ] **Claves SSH del operador**
      Auditar `~/.ssh/authorized_keys` en la Pi. Si hay claves antiguas de portátiles retirados, quitarlas.
- [ ] **Tokens de Tailscale**
      Si se usan _auth keys_ (no _OAuth_), regenerar las que tengan > 1 año.
- [ ] **Contraseñas y secretos en `.env`**
      Auditar todos los `.env` de los _stacks_ y rotar lo que sea sensato (Authelia `JWT_SECRET`, MariaDB `root password` con cuidado de actualizar el cliente al mismo tiempo, Mosquitto `auth_password` para clientes IoT, Vaultwarden `ADMIN_TOKEN` si está activo). Cualquier rotación se documenta en la bitácora con la fecha y el motivo.

### 2. Disaster recovery completo
- [ ] **DR drill end-to-end**
      Siguiendo `docs/13-operaciones/02-disaster-recovery.md`: con la Pi de producción intacta, restaurar todo el homelab en una Pi auxiliar (o en una microSD limpia + el `hd2t` desconectado del original). Tiempo objetivo: **< 4 h** desde "tarjeta vacía" a "Vaultwarden + Nextcloud + Home Assistant operativos". Si > 6 h, hay procedimientos que mejorar.
- [ ] **Confirmar que el repo offsite es suficiente**
      El DR debe poder hacerse **sólo con el repo offsite** (no con `hd2t` físico). Si en algún paso el procedimiento exige acceder a `hd2t`, anotar el _gap_ y migrar ese dato al backup que va al offsite.

### 3. Revisión estratégica
- [ ] **Proveedor offsite**
      Comparar coste y rendimiento real del año con la sección "Destino offsite" de `docs/07-backups/01-estrategia-backup.md`. Si rsync.net subió de precio o Hetzner mejoró, evaluar migración. Migración no se hace en esta ronda; sólo se decide si entra a la cola del Q1 siguiente.
- [ ] **Hardware**
      `sudo smartctl -A /dev/disk/by-label/hd5t | grep Power_On_Hours`
      `sudo smartctl -A /dev/disk/by-label/hd2t | grep Power_On_Hours`
      → si un disco supera ~30.000 horas (≈ 3.5 años) y es de servicio crítico (`hd2t`), planificar reemplazo en el siguiente Q1 aunque SMART siga diciendo `PASSED`. La probabilidad de fallo crece exponencialmente a partir de los 4-5 años.
      Pi 5 — temperatura sostenida en el año vía Grafana. Si hubo > 30 días con _throttling_ térmico, planificar mejora de disipación (ventilador más grande, carcasa, …) para el siguiente trimestre.
- [ ] **Servicios — revisión "¿sigue justificado?"**
      Para cada servicio en `SERVICES.md`, contestar honestamente:
      1. ¿Lo he usado en los últimos 3 meses?
      2. ¿Si lo apago hoy, alguien (yo, familia) lo nota mañana?
      3. ¿El coste de mantenimiento (tiempo, parches, complejidad) supera el beneficio?
      Si las tres respuestas tienden al "no", el servicio entra en la lista de "retirar el siguiente trimestre". Es **el** filtro contra el _service sprawl_ típico del homelab maduro.
- [ ] **CA local de Caddy**
      Verificar caducidad. Si quedan < 2 años, planificar regeneración (no urgente — Caddy permite regenerar la CA sin perder datos, pero los clientes con cert pinneado necesitarán reaceptar la nueva).
- [ ] **Documentación — diff anual**
      `git log --since "1 year ago" --stat docs/` → revisar qué docs se han modificado y cuáles llevan un año sin tocarse. Los que no se han tocado se releen ahora: a menudo se descubre que la realidad ha derivado y la doc no.

### 4. Cierre
- [ ] **Bitácora anual**
      `~/homelab/docs/journal/YYYY.md` → resumen del año (los 3-5 hechos más relevantes, los aprendizajes, las decisiones pendientes para el año siguiente).
- [ ] **Commit y push**
      `cd ~/homelab && git add . && git commit -m "ops: ronda anual YYYY" && git push`
- [ ] **Tag**
      `git tag -a "ops-YYYY" -m "Ronda anual YYYY cerrada"` → permite identificar fácilmente los hitos en `git log`.
```

---

## Plantilla de bitácora

Fichero `~/homelab/docs/journal/YYYY-MM.md`. Formato libre pero con secciones fijas para que el _diff_ entre meses sea legible.

```markdown
# Bitácora YYYY-MM

## Semana 1 (YYYY-MM-DD)
- Watchtower: 0 errores. Actualizó: `linkding 1.32.5 → 1.32.6`, `freshrss 1.24.1 → 1.24.2`.
- Stacks: todos `Up`.
- Borg: 7 archives ok.
- Uptime Kuma: incidente 5 min en Sonarr el martes 03:14, autoresuelto. Posible coincidencia con backup pesado de Transmission. Sin acción.
- fail2ban: 3 IPs banadas, todas chinas, ruido habitual.
- df: hd2t 47 %, hd5t 62 %, / 12 %.
- Notas: nada destacable.

## Semana 2 (YYYY-MM-DD)
...

## Ronda mensual YYYY-MM
### Hardware
- SMART hd5t: PASSED, 18.250 power-on hours (+730 vs mes pasado, normal).
- SMART hd2t: PASSED, 18.150 power-on hours.
- Reallocated_Sector_Ct: 0 / 0. Sin cambios.
- Self-test largo: hd2t este mes, completed without error en 4h17m.
- Temp CPU: max 76 °C el día 2026-04-13 (transcoding pesado de Jellyfin), media 58 °C.

### Backups
- borgmatic verify-data offsite: ok, 47 min.
- Drill Vaultwarden: 1m 12s. Restaurado, db.sqlite3 abierto con `sqlite3` y `SELECT count(*) FROM users` = 4.
- Drill alternativo: Bookstack BD. Importado en MariaDB temporal, `SELECT count(*) FROM books` = 12 (ok).
- Repo Borg local: 142 GB / All archives 1.4 TB original (dedup 10x). +3 GB vs mes pasado.

### Espacio y Docker
- Top servicios: nextcloud 38 GB, paperless 18 GB, jellyfin (sólo config, sin biblioteca) 1.2 GB.
- docker system df: 4.1 GB reclaimable. `docker image prune -af --filter "until=168h"` → 3.8 GB liberados.
- /var/log: 312 MB, ok.

### Logs y eventos
- unattended-upgrades: 14 paquetes en el mes, sin errores. Destacable: openssl, libc6, sudo.
- fail2ban: 47 bans en el mes, 38 desde la misma /16 china. Decisión: pasar a drop permanente en nft (anotar para próxima semana).
- Pi-hole: gravity update ok. Una blocklist (StevenBlack/hosts) cambió formato y dio warning, sin impacto.

### Parches manuales pendientes
- [ ] Vaultwarden 1.32.5 → 1.33.0 (nuevo minor, leer changelog).
- [ ] Mealie 2.6.0 → 2.7.1.
- [ ] Home Assistant 2025.10 → 2025.11 (esperar al trimestral).

### Cosas que decidí
- No actualizar Home Assistant esta ronda; se hará en trimestral con backup previo.
- Pasar la /16 china a nft drop permanente la próxima semana.

## Ronda trimestral YYYY-Qn
... (sólo si el mes coincide)
```

> **Por qué Markdown plano y no Bookstack desde el día uno**: el repo `~/homelab/` se respalda con Borg (`docs/07-backups/01-estrategia-backup.md` → categoría A). Bookstack también, pero su BD MariaDB es más frágil para una restauración de emergencia. Tener la bitácora en Markdown plano garantiza que está siempre accesible incluso si el homelab está en fase de DR. Cuando Bookstack lleve un par de meses estable, el operador puede _migrar_ las bitácoras antiguas allí (mejor búsqueda, mejor formato), pero la **fuente de verdad operativa** sigue en `~/homelab/docs/journal/`.

---

## Estructura del directorio de bitácoras

Crear desde el momento en que se empieza la primera ronda semanal:

```
~/homelab/docs/
├── journal/
│   ├── README.md           # explicación breve y enlace a este doc
│   ├── 2026-04.md          # un fichero por mes
│   ├── 2026-05.md
│   ├── 2026-06.md
│   ├── 2026-Q2.md          # uno por trimestre cuando aplique
│   └── 2026.md             # uno anual cuando aplique
```

Permisos:

```bash
mkdir -p ~/homelab/docs/journal
cat > ~/homelab/docs/journal/README.md <<'EOF'
# Bitácora de operaciones

Una entrada por ronda. Plantilla y calendario en `docs/13-operaciones/01-mantenimiento-periodico.md`.

Convención:
- `YYYY-MM.md` para semanal y mensual.
- `YYYY-Qn.md` para trimestral.
- `YYYY.md` para anual.
EOF
git -C ~/homelab add docs/journal/
git -C ~/homelab commit -m "docs(ops): bootstrap directorio de bitácora"
```

---

## Cuando algo aparece en rojo (orden de respuesta)

Las rondas detectan problemas; este bloque define **el orden de prioridad** para responderlos. Es la guía rápida; cada caso individual se resuelve en su doc específico.

| Síntoma                                                            | Prioridad | Primera acción                                                                                            | Doc de referencia                                                                |
|--------------------------------------------------------------------|-----------|-----------------------------------------------------------------------------------------------------------|----------------------------------------------------------------------------------|
| `smartctl -H` devuelve `FAILING_NOW`                               | **0**     | Asumir que el disco va a morir en horas/días. Forzar `borgmatic` _ahora_, comprar reemplazo.              | `docs/00-hardware/03-preparacion-discos.md`                                       |
| Drill de restauración falla                                        | **0**     | Investigar **ya** si el backup está sano (`borg check --verify-data`) o si el procedimiento de restore tiene un gap. Sin backup útil, el homelab está sin red. | `docs/07-backups/01-estrategia-backup.md` y `docs/07-backups/03-backup-docker-volumes.md` |
| `borgmatic` no ha corrido en > 26 h (alerta Prometheus)            | **0**     | `journalctl -u borgmatic.service` para ver el último intento. Suele ser un disco lleno, una clave SSH movida o un timer parado. | `docs/07-backups/02-borgmatic.md`                                                 |
| Servicio crítico (Vaultwarden, Nextcloud, Home Assistant) `unhealthy` | **0**     | `make logs STACK=<stack> SERVICE=<servicio>` y `docker inspect <servicio>` para entender el _restart loop_. | doc de servicio                                                                  |
| Espacio en `hd2t` o `/` > 90 %                                     | **1**     | Identificar el crecimiento (`sudo du -sh /mnt/hd2t/services/* | sort -h`); decidir si limpiar (Docker, logs, caches) o expandir. | _Ronda mensual_ → _Espacio en disco y Docker_                                     |
| `Reallocated_Sector_Ct` o `Current_Pending_Sector` crecieron       | **1**     | Disco aún PASSED pero degradado. Forzar `borgmatic`, planificar reemplazo en el siguiente trimestre.       | `docs/00-hardware/03-preparacion-discos.md`                                       |
| Servicio _opt-in_ a Watchtower roto tras update                    | **1**     | _Rollback_ (si la imagen vieja sigue ahí) y `enable=false` en su _label_. Investigar _release notes_ para entender la causa antes de reactivar. | `docs/02-docker/04-watchtower.md` → _Troubleshooting_                              |
| Alerta Prometheus _firing_ ininterrumpida > 24 h                   | **1**     | Si la alerta es válida, mitigar. Si es ruido, ajustar el _threshold_ de la rule (no silenciar la alerta tal cual). | `docs/05-monitorizacion/01-prometheus.md`                                         |
| fail2ban con un pico de bans inusual                               | **2**     | Si la fuente es una _net_ específica, considerar `nft drop` permanente. Si es distribuida, sólo es ruido habitual de internet. | `docs/01-sistema/03-seguridad-base.md` y `docs/13-operaciones/04-red-y-puertos.md` |
| Métrica anómala (RAM al 80 % sostenido, CPU > 70 % constante)      | **2**     | Identificar el contenedor culpable con `docker stats` o cAdvisor. Decidir: ¿es un _memory leak_? ¿uso legítimo creciente? | `docs/05-monitorizacion/04-cadvisor.md` y `docs/13-operaciones/03-rendimiento-pi5.md` |
| `unattended-upgrades` no aplicó nada en todo el mes                | **3**     | Verificar `Allowed-Origins` y que `apt update` funciona. Forzar `sudo unattended-upgrade --dry-run -d`.    | `docs/01-sistema/03-seguridad-base.md` → _Troubleshooting_                        |
| Drift entre doc y realidad detectado en trimestral                 | **3**     | Actualizar la doc en el _commit_ del trimestral. Sin urgencia.                                            | el doc afectado                                                                  |

> **Regla de prioridad 0**: cualquier item de prioridad 0 detiene la ronda en curso. No se sigue rellenando la checklist; se responde al fuego primero, se anota lo hecho y se vuelve a la ronda otro día.

---

## Verificación final (cierre de la fase 13 — primera ronda)

Antes de dar la fase 13.1 por cerrada, ejecutar **una vez** la ronda mensual entera, registrarla en bitácora y commitear. Es el _smoke test_ del propio mantenimiento.

- [ ] El directorio `~/homelab/docs/journal/` existe, tiene `README.md` y un fichero `YYYY-MM.md` con al menos una entrada de "Semana 1" y la "Ronda mensual" inicial.
- [ ] La ronda mensual ha pasado **completa** sin items rojos sin investigar (es esperable que la primera ronda revele 1-2 _gaps_ que no se vieron al desplegar; se anotan, se asignan a su doc de fase y se cierra el _gap_).
- [ ] Todos los _drills_ de restauración listados en la sección "Drills profundos" del trimestral han corrido al menos una vez (aunque no sea el trimestre, conviene hacerlos al cerrar la fase para confirmar el procedimiento _end-to-end_).
- [ ] El operador ha programado en su calendario personal (Google Calendar, Nextcloud Calendar, recordatorio en el móvil…) los _eventos recurrentes_:
  - **Lunes mañana** → "Homelab: ronda semanal" (10 min).
  - **Primer sábado del mes** → "Homelab: ronda mensual" (45 min).
  - **Primer sábado de Q1/Q2/Q3/Q4** → "Homelab: ronda trimestral" (2 h, suma sobre el mensual).
  - **Cumpleaños del homelab** (fecha del primer arranque definitivo de la Pi 5) → "Homelab: ronda anual" (medio día).
  Sin recordatorios, las rondas se saltan. La automatización del homelab vigila la Pi; la del operador la vigila el calendario.
- [ ] La fase 13.1 se cierra con commit:
  ```bash
  cd ~/homelab
  git add docs/journal/
  git commit -m "feat(ops): bootstrap mantenimiento periódico (primera ronda)"
  git push
  ```

A partir de aquí, las siguientes secciones de la fase 13 (`02-disaster-recovery.md`, `03-rendimiento-pi5.md`, `04-red-y-puertos.md`) cubrirán los _runbooks_ que este documento referencia pero no detalla.

---

## Referencias

- BorgBackup — _Operations_: <https://borgbackup.readthedocs.io/en/stable/usage/check.html>
- Borgmatic — _Verifying backups_: <https://torsion.org/borgmatic/docs/how-to/inspect-your-backups/>
- `smartmontools` — _Self-tests_ y atributos: <https://www.smartmontools.org/wiki/Smartctl>
- Watchtower — _Container selection_: <https://containrrr.dev/watchtower/container-selection/>
- Docker — `docker system prune` y _disk usage_: <https://docs.docker.com/engine/reference/commandline/system_prune/>
- Debian Wiki — `unattended-upgrades`: <https://wiki.debian.org/UnattendedUpgrades>
- Fail2ban — _Manual_: <https://github.com/fail2ban/fail2ban/blob/master/MANUAL>
- Prometheus — _Alerting rules_: <https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/>
- Uptime Kuma — _Monitor types_: <https://github.com/louislam/uptime-kuma/wiki>
- SRE Workbook — _Postmortem culture_ (lectura recomendada para la bitácora): <https://sre.google/workbook/postmortem-culture/>
