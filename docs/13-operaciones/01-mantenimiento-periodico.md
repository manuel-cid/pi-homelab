# Mantenimiento Periódico

## Descripción

Las fases 0–12 dejaron el homelab funcionando y observable: hardware preparado, sistema base, Docker, red con Pi-hole + Caddy + Authelia, monitorización (Prometheus / Grafana / Node Exporter / cAdvisor / Uptime Kuma / Dozzle), backups (Borgmatic + offsite B2), domótica, multimedia, descargas, productividad y un dashboard único en Homepage. Todo eso convive sobre **una sola Raspberry Pi 5** con dos discos USB externos (`hd2t` 2 TB para datos y backups, `hd5t` 5 TB para multimedia), accedido únicamente desde la LAN y la mesh Tailscale.

Un homelab así no se mantiene solo. Sin un calendario explícito de tareas:

- Las **imágenes Docker** quedan congeladas en versiones con CVEs sin parchear si Watchtower falla en silencio.
- Los **discos USB externos** acumulan reasignaciones SMART y nadie se entera hasta que `hd2t` deja de montar.
- Los **logs json-file** crecen hasta llenar la microSD aun con `max-size=10m` (basta con un contenedor en bucle de error).
- El **repo Borg** acumula chunks corruptos detectables solo con `borg check --archives-only`.
- La **microSD** del sistema operativo sufre desgaste sin que nadie monitorice los `Reallocated_Sector_Ct` o el ritmo de escritura.
- Los **certificados internos** de la CA local emitida en Fase 4 caducan sin avisar.
- El **firmware del Pi 5** queda atrás: bootloader EEPROM y rpi-eeprom no se actualizan solos.
- La **temperatura** sube sin control en verano y la Pi entra en throttling silencioso (no es una caída visible, es una degradación lenta).

Este documento **no despliega ningún servicio nuevo**. Lo que hace es **fijar el calendario operativo** del homelab: qué se revisa, con qué cadencia, en qué orden, durante cuánto tiempo, y dónde se deja constancia. La filosofía es:

1. **Automatizar todo lo que se pueda**, monitorizar el resto. Borgmatic, Watchtower, `logrotate`, `apt-listchanges`, `smartmontools` ya hacen el trabajo bruto cada día. El operador **no toca** lo que las máquinas hacen bien solas.
2. **Capturar todo en métricas** observables vía Prometheus / Grafana / Uptime Kuma. Si una alerta no salta, la suposición es "todo está bien". El mantenimiento manual existe **solo** para lo que no se puede convertir en alerta automática.
3. **Cadencias predecibles y cortas**: un check semanal de < 15 min los lunes, un mantenimiento mensual de < 45 min el día 1, un drill trimestral de ~2 h, una revisión anual de ~3 h. Si una tarea crece más allá, se escinde.
4. **Bitácora versionada**: `MAINTENANCE_LOG.md` en el repo recoge cada sesión de mantenimiento con fecha, duración, hallazgos y acciones. Se commitea como auditoría futura, sin secretos.
5. **Principio de "nada se prueba en producción sin red"**: cualquier acción potencialmente destructiva (`docker system prune --volumes`, `apt full-upgrade`, formateo de un disco) se ejecuta **después** de validar que el último backup es reciente y verificado.

> **Recordatorio de alcance**: el homelab sigue siendo solo **LAN + Tailscale**. Ninguna tarea de mantenimiento implica abrir puertos al exterior, instalar agentes propietarios ni mandar telemetría a terceros. Las únicas conexiones salientes son las ya establecidas en fases anteriores: pull de imágenes Docker (Docker Hub, GHCR, lscr.io), pull de actualizaciones APT (mirrors Debian/RPi), sync de Borg con Backblaze B2, NTP, y Tailscale Coordination Server. El operador trabaja **dentro** del perímetro local o vía Tailscale.

---

## Requisitos Previos

Para que este calendario pueda ejecutarse se necesita el homelab **completo** — todas las fases 0–12 desplegadas:

- **Fase 0** (`00-hardware/`): Pi 5 con disipación pasiva/activa adecuada, ambos HDD montados en `/etc/fstab` con UUID y opciones `nofail,x-systemd.device-timeout=10s`.
- **Fase 1** (`01-sistema/`): usuario `homelab`, SSH por clave, `unattended-upgrades` activado para parches de seguridad, `logrotate` y `journalctl --vacuum-time=14d` configurados.
- **Fase 2** (`02-docker/`): Docker Engine + Compose v2, log driver `json-file` con `max-size=10m max-file=3`, **Watchtower** desplegado con la cadencia decidida en `02-docker/04-watchtower.md`.
- **Fase 3** (`03-red/`): Pi-hole + Caddy + Authelia operativos con su CA interna; el operador puede acceder a cualquier UI por hostname `.lan`.
- **Fase 5** (`05-monitorizacion/`): Prometheus con retención mínima de 30 días, Grafana con dashboards Pi-hole / Node Exporter / cAdvisor, **Uptime Kuma** con monitores para todos los servicios web, **Dozzle** accesible para revisar logs.
- **Fase 7** (`07-backups/`): Borgmatic ejecutándose cada noche, métricas `homelab_backup_*` exportadas a Prometheus vía textfile collector, `BACKUPS_LOG.md` versionado.
- **Fase 12** (`12-dashboards/`): Homepage con widgets de salud (uptime, espacio en disco, temperatura).
- **Herramientas del host** instaladas explícitamente para este documento:
  - `smartmontools` (`apt install smartmontools`) para los chequeos SMART.
  - `rpi-eeprom` (preinstalado en Raspberry Pi OS) para el firmware del bootloader.
  - `vcgencmd` (preinstalado) para temperatura, frecuencia y throttling.
  - `iotop`, `htop`, `ncdu`, `dust` (`apt install iotop htop ncdu`) para diagnóstico ad-hoc.
- `MAINTENANCE_LOG.md` inicializado en la raíz del repo (`/home/homelab/homelab/`), versionado, sin secretos.

---

## Filosofía: lo automatizado y lo manual

Antes del calendario, una tabla que separa **qué corre solo** de **qué requiere ojo humano**. Si algo aparece en la columna de la izquierda, el operador **no lo ejecuta**: revisa que la automatización lo haya ejecutado.

| Tarea | Automatizada por | Frecuencia | Métrica/log que el operador revisa |
|---|---|---|---|
| Backup nocturno + offsite | Borgmatic + `rclone` (`07-backups/02-borgmatic.md`) | Diaria 03:30 | `homelab_backup_last_success_timestamp` en Grafana |
| Actualización de imágenes Docker | Watchtower (`02-docker/04-watchtower.md`) | Semanal mié 04:00 | Notificación shoutrrr + dashboard "Watchtower last update" |
| Parches de seguridad APT | `unattended-upgrades` | Diaria | `/var/log/unattended-upgrades/unattended-upgrades.log` |
| Rotación de logs Docker | `json-file max-size=10m max-file=3` | Continua | `du -sh /var/lib/docker/containers/*/` |
| Rotación de logs systemd | `journalctl --vacuum-time=14d` (timer) | Diaria | `journalctl --disk-usage` |
| SMART self-test corto | `smartd` (`/etc/smartd.conf`) | Semanal | `smartctl -a` muestra el último `Short_Offline` |
| Sync de listas Pi-hole | `pihole updateGravity` (cron interno) | Semanal | UI Pi-hole → Tools → Update Gravity |
| Limpieza de imágenes dangling | Watchtower con `--cleanup` | Semanal | `docker images -f dangling=true` debe estar vacío |
| Renovación de cert CA interna | **No automatizada** (CA es interna y dura años) | Anual manual | Caducidad consultable con `openssl x509 -enddate` |
| Verificación SMART larga | **No automatizada** | Mensual manual | `smartctl -t long` + revisión del operador |
| `borg check --archives-only` | **No automatizada** (costosa: rehash) | Mensual manual | Salida del comando |
| Restore drill | **No automatizada** (requiere juicio) | Trimestral manual | `BACKUPS_LOG.md` |
| Revisión arquitectónica | **No automatizada** | Anual manual | Commit en docs |

> **Decisión de no-automatizar**: las cuatro últimas filas son tareas con efectos potencialmente destructivos o que requieren validación cualitativa ("¿el restore drill devolvió datos creíbles?"). Automatizarlas sin un humano detrás genera falsos positivos o, peor, falsos negativos silenciosos.

---

## Calendario operativo

### Vista de cadencia única

```
Diaria        03:30  Borgmatic + rclone offsite      (auto)
Diaria        04:00  unattended-upgrades             (auto)
Diaria        04:15  journalctl vacuum               (auto)
Semanal mié   04:00  Watchtower scan + cleanup       (auto)
Semanal dom   04:30  borgmatic compact + check repo  (auto)
Semanal dom   05:00  smartctl -t short hd2t/hd5t     (auto)

Semanal lun   09:00  Operador: revisión rápida       (~15 min)
Mensual día 1 09:00  Operador: mantenimiento medio   (~45 min)
Trimestral    09:00  Operador: drill + auditoría     (~2 h)
Anual         09:00  Operador: revisión arquitect.   (~3 h)
```

### Lista de chequeo semanal — Lunes ~15 min

El operador abre **Homepage** (dashboard único, ver `12-dashboards/01-homepage.md`) y baja por la lista en orden. Cualquier hallazgo se anota en `MAINTENANCE_LOG.md` al final de la sesión.

| # | Comprobación | Dónde | Verde si | Acción si rojo |
|---|---|---|---|---|
| 1 | **Backups OK** | Grafana → "Backups" | `homelab_backup_last_success_timestamp` < 36 h y `homelab_backup_offsite_lag_seconds` < 48 h | Ir a `07-backups/02-borgmatic.md` § troubleshooting; revisar `on-error.sh` log |
| 2 | **Servicios arriba** | Uptime Kuma → resumen | Todos los monitores en verde, sin "Down" ni "Pending" en los últimos 7 días | Investigar el servicio caído; revisar Dozzle |
| 3 | **Espacio en discos** | Grafana → "Storage" o `df -h /mnt/hd2t /mnt/hd5t /` | hd2t > 20 % libre, hd5t > 10 % libre, `/` > 30 % libre | Ver § "Diagnóstico de espacio" más abajo |
| 4 | **Temperatura Pi 5** | Grafana → "Pi 5 health" panel `node_thermal_zone_temp` | < 70 °C en steady state | Ver `13-operaciones/03-rendimiento-pi5.md` |
| 5 | **Throttling** | `vcgencmd get_throttled` desde SSH | `throttled=0x0` | Mismo doc que el punto 4 |
| 6 | **Watchtower** | Notificación shoutrrr del miércoles previo | Recibida con resumen "X imágenes actualizadas" | Revisar logs del contenedor `watchtower` con `docker logs --tail 200 watchtower` |
| 7 | **SMART semanal** | `sudo smartctl -a /dev/disk/by-uuid/<hd2t>` y lo mismo para hd5t | `SMART overall-health: PASSED` y `Reallocated_Sector_Ct` estable | Ver § "Diagnóstico SMART" |
| 8 | **Logs anómalos** | Dozzle → filtrar por `level:error` últimos 7 días | < 100 errores y ningún contenedor en bucle de reinicio (`docker ps --filter status=restarting`) | Aislar el contenedor; ver Dozzle stack-trace |
| 9 | **Pi-hole queries** | Pi-hole UI → Long-term Statistics | Sin caídas extrañas en queries; bloqueo > 10 % | Revisar `pihole status`, `pihole -g` log |
| 10 | **Authelia logins** | Dozzle → `authelia` → buscar `failed_authentication` | Ningún burst de fallos desde una IP de la LAN | Revisar `/mnt/hd2t/apps/authelia/data/db.sqlite3` con `sqlite3` si sospecha |

Si ninguna luz se enciende, la sesión termina con un commit:

```bash
cd /home/homelab/homelab
echo -e "\n## $(date -I) — Semanal\n- Sin hallazgos. Backups OK, SMART PASSED, T < 65°C." \
  >> MAINTENANCE_LOG.md
git add MAINTENANCE_LOG.md && git commit -m "ops: maintenance log $(date -I)"
```

### Lista de chequeo mensual — Día 1 ~45 min

Hereda los 10 puntos semanales y añade tareas que no compensa hacer cada lunes:

| # | Tarea | Comando / dónde | Notas |
|---|---|---|---|
| M1 | **SMART long test** en `hd2t` y `hd5t` (en paralelo) | `sudo smartctl -t long /dev/disk/by-uuid/<UUID>` | Tarda ~6–10 h por disco; se lanza por la mañana y el resultado se mira al día siguiente con `smartctl -l selftest`. |
| M2 | **`borgmatic check --only archives`** | `docker compose exec borgmatic borgmatic check --only archives` | Costoso (rehash). Se programa en horario laboral del día 1, no a las 4:00. Si falla, escala a CRIT y se va a `07-backups/`. |
| M3 | **Actualización APT del host** | `sudo apt update && sudo apt -y full-upgrade && sudo apt -y autoremove` | Reiniciar **solo** si `/var/run/reboot-required` existe. La Pi tarda ~90 s en arrancar; ventana de mantenimiento avisada en `MAINTENANCE_LOG.md`. |
| M4 | **Firmware Pi 5** | `sudo rpi-eeprom-update` y `sudo rpi-eeprom-update -a` si hay actualización | Reinicio requerido tras `-a`. Anotar la versión nueva. |
| M5 | **`docker system prune`** controlado | Ver § "Limpieza de Docker" más abajo | **Sin `--volumes`** por defecto. |
| M6 | **Imágenes huérfanas** | `docker images -f "dangling=false" --format '{{.Repository}}:{{.Tag}}\t{{.Size}}'` y comparar con compose | Si una imagen aparece pero ningún `docker-compose.yml` la referencia, considerar `docker image rm`. |
| M7 | **Métricas de uso** por contenedor | Grafana → "cAdvisor" → top-10 RAM y top-10 CPU últimos 30 días | Detectar memory leaks (curva monotónica creciente sin caídas). Ver `13-operaciones/03-rendimiento-pi5.md` para límites. |
| M8 | **Tamaño de logs Docker** | `sudo du -sh /var/lib/docker/containers/* \| sort -rh \| head -20` | Si algún contenedor pasa de 30 MB con `max-size=10m max-file=3`, hay algo raro (rotación rota o log driver mal aplicado). |
| M9 | **Espacio del repo Borg** | `borgmatic info` (vía contenedor) campos `Original/Compressed/Deduplicated` | Comparar deduplicated frente al mes anterior; crecimiento anormal indica un servicio que generó datos no esperados. |
| M10 | **Listas Pi-hole** | UI → Tools → Update Gravity (manual extra) | Confirma que las suscripciones siguen vivas; si una blocklist da 404 hace semanas, retirarla. |
| M11 | **Revisar `unattended-upgrades` log** | `sudo less /var/log/unattended-upgrades/unattended-upgrades.log` | Buscar líneas `ERROR` o `package held back`. |
| M12 | **Caducidad de la CA interna** | `openssl x509 -in /home/homelab/homelab/secrets/ca/ca.crt -noout -enddate` | Si quedan < 6 meses, planificar rotación (manual; ver `04-seguridad/`). |
| M13 | **Tailscale** | `tailscale status` y revisar nodos conectados | Borrar dispositivos antiguos desde el admin web. |
| M14 | **Bitácora** | Editar `MAINTENANCE_LOG.md` y commit | Sección "Hallazgos del mes" + "Acciones planificadas para el mes siguiente". |

### Lista trimestral — ~2 h

| # | Tarea | Referencia |
|---|---|---|
| Q1 | **Restore drill** completo de un servicio T1 al azar | `07-backups/01-estrategia-backup.md` § Verificación manual y `07-backups/03-backup-docker-volumes.md` |
| Q2 | **Restore drill desde offsite** una vez al año (en uno de los 4 trimestrales) | Misma referencia |
| Q3 | **Auditoría de usuarios Authelia** y dispositivos TOTP | UI Authelia + admin → eliminar dispositivos no usados > 90 días |
| Q4 | **Revisar reglas Caddy** drop por drop (`stacks/caddy/conf.d/`) | Buscar drops obsoletos de servicios retirados |
| Q5 | **Auditoría de superficie** de Tailscale ACLs | admin web Tailscale → revisar ACLs y tags |
| Q6 | **Dashboard sweep**: cada dashboard de Grafana, ¿muestra datos actuales? | Grafana → home; descartar dashboards muertos |
| Q7 | **Limpieza profunda** de Docker | `docker volume prune` (manual, con dry-run primero); `docker network prune`; `docker buildx prune` si se usó build local |
| Q8 | **Repaso del `.env` global** y `.env` por stack | Revisar variables nunca usadas; rotar `*_SECRET` si pertinente |
| Q9 | **Inventario de servicios** vs `SERVICES.md` | ¿Hay un servicio corriendo no documentado? ¿Documentado pero parado? |
| Q10 | **Pruebas de Tailscale exit-node / subnet-router** | Si la Pi actúa como subnet router, validar desde un nodo remoto |

### Lista anual — ~3 h

| # | Tarea | Notas |
|---|---|---|
| Y1 | **Revisión arquitectónica** | ¿Sigue tiendo sentido el split hd2t/hd5t? ¿Algún servicio del `SERVICES.md` ya no se usa? Commit con un *postmortem* del año. |
| Y2 | **Limpieza física** | Apagar la Pi, desconectar, soplar polvo del disipador y ventilador, revisar cables USB de los HDD (un cable USB-A degradado es la causa #1 de errores SMART falsos). |
| Y3 | **Salud de la microSD** | `sudo dmesg \| grep -i mmcblk` buscando errores. Si la microSD lleva > 3 años, plan de migración a NVMe (Pi 5 con HAT NVMe) o reemplazo proactivo. |
| Y4 | **Renovación de la CA interna** si la caducidad cae este año | Procedimiento en `04-seguridad/` (re-emitir CA, re-emitir cert wildcard, distribuir CA nueva a navegadores y móviles del operador). |
| Y5 | **Re-keying de Borg** opcional | `borg key export` + `borg key change-passphrase` si la passphrase actual se ha mostrado o copiado en una ubicación incierta durante el año. |
| Y6 | **Revisión de `docs/` completa** | Cada doc debe seguir vivo; los obsoletos se marcan o se retiran. |

---

## Procedimientos detallados

### Limpieza de Docker

`docker system prune` puede borrar más de la cuenta si se aplica sin pensar. La regla del homelab es **conservadora por defecto** y **explícita por excepción**.

| Comando | Borra | Cuándo se usa |
|---|---|---|
| `docker image prune` | Imágenes "dangling" (sin tag y sin contenedor) | Mensual. Watchtower con `--cleanup` ya lo hace, esto es el cinturón. |
| `docker container prune` | Contenedores parados | Mensual si `docker ps -a --filter status=exited` muestra residuos. |
| `docker network prune` | Redes no usadas por ningún contenedor | Trimestral. |
| `docker system prune` | Lo anterior + build cache | Trimestral. |
| `docker system prune -a` | **Además** imágenes sin contenedor (aunque tengan tag) | **Excepcional**. Tras un servicio retirado del homelab. |
| `docker system prune --volumes` | **Además** volúmenes nominales no referenciados | **Prohibido por convención**: el homelab no usa volúmenes nominales (`02-docker/02-estructura-compose.md`). Si por error se ejecuta y existe un volumen nominal residual, queda destruido. |
| `docker buildx prune` | Cache de buildx | Si se construyeron imágenes locales. No es el caso del homelab por defecto. |

Receta mensual recomendada (M5):

```bash
# Ver qué se borraría sin borrar
docker system df
docker image prune -f --filter "until=720h"  # imágenes dangling > 30 días
docker container prune -f --filter "until=168h"  # contenedores parados > 7 días
# Confirmar el efecto
docker system df
```

> **Decisión**: nunca ejecutar `docker system prune --volumes` como tarea recurrente. Si en algún momento hace falta, va siempre **precedido** de un backup verificado y de un `docker volume ls` revisado a mano.

### Diagnóstico de espacio

Cuando un disco baja del umbral (hd2t < 20 %, hd5t < 10 %, `/` < 30 %):

```bash
# Top consumidores en cada raíz
sudo ncdu /                  # microSD (root)
sudo ncdu /mnt/hd2t          # datos + backups
sudo ncdu /mnt/hd5t          # multimedia
# Repo Borg
docker compose -f /home/homelab/homelab/stacks/borgmatic/docker-compose.yml \
  exec borgmatic borgmatic info | head -40
# Logs Docker
sudo du -sh /var/lib/docker/containers/* | sort -rh | head -20
```

Acciones típicas según hallazgo:

| Hallazgo | Acción |
|---|---|
| `/var/lib/docker/containers/<id>/<id>-json.log` > 50 MB | Contenedor en bucle de error: reiniciar / arreglar; rotación está bien. |
| `/mnt/hd2t/apps/<svc>/cache/` desproporcionado | Truncar el cache (excluido de backup) tras parar el servicio si la app lo soporta. |
| `/mnt/hd5t/media/` casi lleno | Decisión de capacidad: ampliar disco (no entra en mantenimiento; replantea Fase 0). |
| `/mnt/hd2t/backups/borg/` crece más rápido de lo esperado | Revisar T3 que se haya colado por error en el include. `borgmatic info` muestra archives anormalmente grandes. |
| `journalctl --disk-usage` > 1 GB | Ajustar `SystemMaxUse` en `/etc/systemd/journald.conf`; ya debe estar limitado en Fase 1. |

### Diagnóstico SMART

`smartmontools` está instalado y `smartd` corre desde Fase 0. Cada lunes se mira la salida agregada; cada mes se lanza un `long test`.

```bash
# Resumen
sudo smartctl -H /dev/disk/by-uuid/<hd2t-uuid>   # PASSED esperado
sudo smartctl -H /dev/disk/by-uuid/<hd5t-uuid>

# Detalle relevante
sudo smartctl -A /dev/disk/by-uuid/<hd2t-uuid> | \
  grep -E 'Reallocated_Sector_Ct|Current_Pending_Sector|Offline_Uncorrectable|UDMA_CRC_Error_Count|Power_On_Hours|Temperature_Celsius'

# Historial de tests
sudo smartctl -l selftest /dev/disk/by-uuid/<hd2t-uuid>

# Lanzar el test largo (mensual)
sudo smartctl -t long /dev/disk/by-uuid/<hd2t-uuid>
sudo smartctl -t long /dev/disk/by-uuid/<hd5t-uuid>   # se puede en paralelo
```

| Atributo | Verde | Acción si rojo |
|---|---|---|
| `SMART overall-health` | `PASSED` | `FAILED` → planificar reemplazo en < 7 días, reforzar backups antes. |
| `Reallocated_Sector_Ct` | Estable o crecimiento muy lento | Si crece > 10 sectores/mes: vigilar; > 100/mes: reemplazar. |
| `Current_Pending_Sector` | 0 | Cualquier valor sostenido: el disco está marcando sectores; reemplazar. |
| `UDMA_CRC_Error_Count` | 0 o estable | Crecimiento: **es el cable USB**, no el disco. Cambiar el cable antes de culpar al HDD. |
| `Temperature_Celsius` | < 50 °C | Mejorar ventilación de la caja del HDD; alejar de fuentes de calor. |
| `Power_On_Hours` | Informativo | A partir de ~30 000 h (≈ 3.5 años 24/7) considerar reemplazo proactivo. |

> **Decisión cable USB**: los HDD externos USB de la Pi sufren más por cableado que por el disco mismo. Si SMART muestra `UDMA_CRC_Error_Count` creciente, **cambiar primero el cable USB**, después el HUB si lo hay, y solo entonces dudar del disco.

### Revisión de logs

El operador no lee logs línea a línea; los **filtra** desde Dozzle.

```
Dozzle → seleccionar contenedor → filter level=error → ventana 7d
```

Patrones que merecen acción:

- **Contenedor en `restarting` perpetuo** (`docker ps --filter status=restarting`): ir al log y aislar la causa.
- **`OOMKilled`** en `docker inspect <container> --format '{{.State.OOMKilled}}'`: ajustar `mem_limit` en el compose; ver `13-operaciones/03-rendimiento-pi5.md`.
- **`failed_authentication`** en Authelia desde la misma IP > 5 veces: bloquear vía Pi-hole o Tailscale ACL.
- **`level=error`** repetidos en Watchtower: notificación shoutrrr habrá fallado; revisar el endpoint.

Para auditorías más finas se usa `journalctl`:

```bash
sudo journalctl --since "7 days ago" --priority=err --no-pager | tail -100
sudo journalctl -u docker --since "7 days ago" --priority=warning --no-pager
sudo journalctl -k --since "7 days ago" --priority=warning --no-pager   # kernel
```

### Actualización del host (M3)

```bash
# Antes: confirmar backup reciente
grep "$(date -I)" /home/homelab/homelab/BACKUPS_LOG.md || \
  echo "ATENCIÓN: ningún backup logueado hoy. Forzar borgmatic antes."

# Update
sudo apt update
apt list --upgradable 2>/dev/null | tail -n +2 | tee /tmp/apt-pending.txt
sudo apt -y full-upgrade
sudo apt -y autoremove --purge

# Reinicio condicional
if [ -f /var/run/reboot-required ]; then
  echo "Reinicio requerido. Avisando al operador antes de reboot."
  cat /var/run/reboot-required.pkgs
  # Reboot manual tras confirmar
fi
```

> **Decisión**: nunca encadenar `apt full-upgrade` con `reboot` automático sin un humano verificando. La Pi 5 tarda ~90 s en arrancar y los HDD USB pueden tardar hasta 30 s extra en ser detectados; si algo se rompe, se prefiere descubrirlo con SSH abierto que con la Pi reiniciándose ciega.

---

## Almacenamiento

Este documento es operativo, no despliega artefactos persistentes nuevos. Los ficheros que **sí** crea son:

| Ruta | Soporte | Owner:Group | Modo | Contenido |
|---|---|---|---|---|
| `/home/homelab/homelab/MAINTENANCE_LOG.md` | microSD | `homelab:homelab` | `0644` | Bitácora versionada de sesiones de mantenimiento. **Sin secretos.** Versionada en git. |
| `/home/homelab/homelab/scripts/maintenance/weekly.sh` *(opcional)* | microSD | `homelab:homelab` | `0750` | Wrapper que ejecuta los chequeos no-interactivos del lunes y prepara un borrador del log. |
| `/home/homelab/homelab/scripts/maintenance/monthly.sh` *(opcional)* | microSD | `homelab:homelab` | `0750` | Idem para el día 1. |
| `/var/log/unattended-upgrades/` | microSD | `root:adm` | `0640` | Log de parches automáticos (creado por `unattended-upgrades`, ya en Fase 1). |
| Salida de `smartctl -t long` | RAM/disco del propio HDD | n/a | n/a | Persiste en el firmware del HDD. Se consulta con `smartctl -l selftest`. |

No se crean directorios nuevos en `/mnt/hd2t/` ni en `/mnt/hd5t/`. Todo el "estado" del mantenimiento es **el commit en git**.

---

## Backup

| Artefacto | Estrategia |
|---|---|
| `docs/13-operaciones/01-mantenimiento-periodico.md` | Versionado en git. |
| `MAINTENANCE_LOG.md` | Versionado en git. **No** entra en Borg como dato adicional: ya vive en `/home/homelab/homelab/` que sí entra en el repo Borg como parte de configs. |
| `scripts/maintenance/*.sh` | Versionados en git. |
| Resultados de `smartctl` | No se respaldan: se consultan en vivo desde el HDD. Si el HDD muere, el log SMART deja de tener sentido. |

> **Bitácora como activo de auditoría**: `MAINTENANCE_LOG.md` se respalda dos veces (en git remoto y en el repo Borg local + offsite vía `/home/homelab/homelab/`). Es deliberado: la bitácora es el único registro humano de qué se hizo cuándo y por qué.

---

## Verificación Final

| Comprobación | Comando | Resultado esperado |
|---|---|---|
| `MAINTENANCE_LOG.md` existe y tiene al menos una entrada | `head -30 /home/homelab/homelab/MAINTENANCE_LOG.md` | Cabecera + entrada inicial fechada |
| `smartmontools` instalado y `smartd` activo | `systemctl is-active smartd` | `active` |
| `unattended-upgrades` activo | `systemctl is-active unattended-upgrades` && `dpkg -l unattended-upgrades` | `active`, paquete instalado |
| El operador conoce y tiene a mano la lista semanal | revisión visual de la sección "Lista de chequeo semanal" | OK |
| Métricas de backup llegan a Prometheus | Grafana → panel `homelab_backup_last_success_timestamp` | valor < 36 h |
| Watchtower notificó la última pasada del miércoles | Buzón shoutrrr (Telegram/ntfy/Gotify) | Mensaje recibido |
| `vcgencmd get_throttled` y temperatura accesibles | comandos en SSH | `0x0` y < 70 °C |
| Cron / systemd timers de smartd y borgmatic activos | `systemctl list-timers --all` | Ambos en la lista, próxima ejecución < 24 h |
| Primer commit de bitácora hecho | `git log MAINTENANCE_LOG.md` | Al menos un commit |

Cumplido todo lo anterior, el homelab tiene un **calendario operativo aplicado**. El siguiente documento (`02-disaster-recovery.md`) describe qué hacer cuando una de estas verificaciones revela un fallo grave.

---

## Decisiones que **no** se toman en este documento

- **Procedimiento de recuperación tras fallo total**: cubierto en `13-operaciones/02-disaster-recovery.md`.
- **Tuning de la Pi 5** (overclock, perfiles térmicos, límites por contenedor): cubierto en `13-operaciones/03-rendimiento-pi5.md`.
- **Mapa completo de puertos y reglas de firewall**: cubierto en `13-operaciones/04-red-y-puertos.md`.
- **Política de actualización por servicio** (qué se autoupdate, qué se pinea): vive en cada doc de servicio + `02-docker/04-watchtower.md`.
- **Retención y verificación de backups**: cerradas en `07-backups/`. Aquí solo se *revisan* las métricas que esos docs producen.
- **Reglas de alerta Prometheus / Grafana**: detalladas en `05-monitorizacion/01-prometheus.md`. Aquí se asume que existen.
- **Rotación de la CA interna**: vive en la fase 4 (seguridad), no aquí. Este doc solo recuerda cuándo mirar la caducidad.
- **Migración a NVMe** (HAT NVMe sobre Pi 5): no es mantenimiento periódico; es un proyecto de hardware.

---

## Referencias

- [Documento siguiente: `docs/13-operaciones/02-disaster-recovery.md`](./02-disaster-recovery.md)
- [Documento siguiente: `docs/13-operaciones/03-rendimiento-pi5.md`](./03-rendimiento-pi5.md)
- [Documento siguiente: `docs/13-operaciones/04-red-y-puertos.md`](./04-red-y-puertos.md)
- [Documento relacionado: `docs/02-docker/04-watchtower.md`](../02-docker/04-watchtower.md)
- [Documento relacionado: `docs/05-monitorizacion/01-prometheus.md`](../05-monitorizacion/01-prometheus.md)
- [Documento relacionado: `docs/05-monitorizacion/05-uptime-kuma.md`](../05-monitorizacion/05-uptime-kuma.md)
- [Documento relacionado: `docs/05-monitorizacion/06-dozzle.md`](../05-monitorizacion/06-dozzle.md)
- [Documento relacionado: `docs/07-backups/01-estrategia-backup.md`](../07-backups/01-estrategia-backup.md)
- [Documento relacionado: `docs/07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md)
- [Documento relacionado: `docs/12-dashboards/01-homepage.md`](../12-dashboards/01-homepage.md)
- [Docker — `system prune`](https://docs.docker.com/reference/cli/docker/system/prune/)
- [Docker — `image prune`](https://docs.docker.com/reference/cli/docker/image/prune/)
- [smartmontools — `smartctl`](https://www.smartmontools.org/browser/trunk/smartmontools/smartctl.8.in)
- [Raspberry Pi — `rpi-eeprom-update`](https://www.raspberrypi.com/documentation/computers/raspberry-pi.html#raspberry-pi-bootloader)
- [Raspberry Pi — `vcgencmd` y `get_throttled`](https://www.raspberrypi.com/documentation/computers/os.html#vcgencmd)
- [Debian — `unattended-upgrades`](https://wiki.debian.org/UnattendedUpgrades)
- [systemd — `journalctl`](https://www.freedesktop.org/software/systemd/man/journalctl.html)
- [Backblaze HDD reliability reports](https://www.backblaze.com/cloud-storage/resources/hard-drive-test-data)
