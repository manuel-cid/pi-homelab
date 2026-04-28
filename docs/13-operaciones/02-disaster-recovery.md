# Disaster Recovery

## Descripción

`01-mantenimiento-periodico.md` describe el régimen estable: chequeos semanales, mensuales, trimestrales y anuales que mantienen el homelab observable y predecible. Este documento se ocupa del **caso opuesto**: qué hacer cuando una de esas verificaciones revela un fallo grave o cuando el homelab simplemente **deja de existir** (microSD muerta, `hd2t` desmontado para no volver, Pi en llamas, robo). Es la guía que el operador abre **bajo presión**, a menudo en una hora insociable, con datos en juego y la cabeza fría a medias.

La filosofía del homelab para disaster recovery se apoya en tres premisas heredadas de fases anteriores:

1. **El estado del sistema es restaurable**. La Fase 7 cerró las decisiones (3-2-1, GFS, RPO ≤ 24 h, RTO ≤ 4–24 h según escenario), Borgmatic las materializó, y `07-backups/03-backup-docker-volumes.md` documentó **los comandos exactos** para restaurar cada motor de BBDD. Este documento no los duplica: los **orquesta** desde la perspectiva del incidente.
2. **El estado del *código* es trivial**. Todo lo que vive en `/home/homelab/homelab/` (composes, scripts, Caddyfile, Prometheus rules, dashboards JSON, plantillas) está versionado en git remoto privado. Recuperar el código es `git clone`. Lo que cuesta tiempo es recuperar **datos** (`/mnt/hd2t/apps/`) y **secretos** (`secrets/`).
3. **El operador no improvisa**. Un disaster a las 3 AM con una passphrase Borg que hay que adivinar y un orden de arranque que hay que deducir es la receta del fallo cascada. El plan está aquí, escrito, probado al menos una vez al año, y referenciado por `01-estrategia-backup.md` § Verificación.

El documento está estructurado en cuatro bloques operativos:

1. **Catálogo de escenarios**. Qué tipos de fallo se contemplan, con qué probabilidad relativa, qué señales los identifican y a qué procedimiento llevan.
2. **Procedimientos detallados** por escenario, en orden creciente de impacto: corrupción de un servicio único → fallo de microSD → fallo de un HDD → pérdida total.
3. **Verificación post-recuperación**: la lista de smoke tests que el homelab debe pasar antes de declararse "vivo de nuevo". Mientras esa lista no esté toda en verde, el operador asume que sigue en mitad del incidente.
4. **Kit de recuperación**: el inventario físico y digital que el operador necesita tener **antes** del desastre. Si en mitad de un incidente hay que ir a comprar un cable USB-A, el kit no estaba completo.

> **Recordatorio de alcance**: el homelab es solo **LAN + Tailscale**. El offsite Backblaze B2 es una salida HTTPS controlada con credenciales propias y scope limitado a un único bucket; durante un disaster el operador no abre puertos al exterior, no expone servicios provisionales, no monta una "web temporal de mantenimiento". Si los servicios están caídos, **están caídos hasta que vuelvan**. La recuperación se hace en LAN o por Tailscale, según donde esté el operador.

> **No-objetivo**: este documento **no** es un plan de continuidad de negocio. No hay estados de réplica activa, ni failover automático, ni cluster de respaldo. El homelab tiene una sola Pi y dos HDD. Cuando algo grave pasa, hay **downtime**. El objetivo es minimizar la pérdida de datos (RPO) y el tiempo total de retorno (RTO), no eliminarlos.

---

## Requisitos Previos

- **Fases 0–13** desplegadas. Si alguna fase no se completó, este documento asume que el operador la conoce lo suficiente para reaplicarla; no la enseña.
- **Backups operativos y verificados** (`07-backups/`):
  - Repo Borg local en `/mnt/hd2t/backups/borg/` con archives recientes (< 36 h).
  - Sync offsite con Backblaze B2 vía `rclone crypt` operativo (`homelab_backup_offsite_lag_seconds` < 48 h en Grafana).
  - Restore drill trimestral hecho al menos una vez antes de necesitar este documento de verdad (anotado en `BACKUPS_LOG.md`).
- **Custodia fuera de banda** de las passphrase críticas, según `07-backups/01-estrategia-backup.md`:
  - Passphrase Borg.
  - Passphrase rclone-crypt.
  - Credenciales Backblaze B2 (App Key con scope al bucket).
  - URL del repo git privado + clave SSH del operador (o método de auth equivalente).
- **Kit de recuperación** preparado (sección final de este documento).
- **`MAINTENANCE_LOG.md`** y **`BACKUPS_LOG.md`** versionados, accesibles al operador desde otro dispositivo si la Pi está caída.
- **Otro dispositivo con red** (laptop personal, teléfono con tethering) capaz de:
  - Leer este documento desde el repo git remoto.
  - Flashear una microSD (lector USB de tarjetas + Raspberry Pi Imager o `dd`).
  - Acceder al admin web de Backblaze B2 si hay que regenerar App Keys.
  - Acceder al admin de Tailscale para registrar el nodo nuevo.

---

## Catálogo de escenarios

Probabilidad estimada **muy a ojo**, basada en hardware doméstico 24/7. Lo que importa no es el número, sino el orden relativo: la microSD y los cables USB son los componentes más frágiles; la pérdida total del sitio es rara pero catastrófica.

| ID | Escenario | Probabilidad anual | Señales típicas | RTO objetivo | Procedimiento |
|---|---|---|---|---|---|
| **DR-1** | Corrupción de un servicio (BBDD, fichero) | Alta (varias al año) | Servicio en `restarting` perpetuo, errores de integridad en logs, comportamiento errático | 30 min | § DR-1 |
| **DR-2** | Fallo total de la microSD | Media (1 cada 2–3 años) | La Pi no arranca, BIOS UART muestra "no boot device" o errores `mmcblk0` masivos en `dmesg` | 4–6 h | § DR-2 |
| **DR-3** | Fallo total de `hd2t` (datos + repo Borg local) | Media | El disco no monta, `smartctl -H` muestra `FAILED`, `UDMA_CRC_Error_Count` saturado | 6–10 h | § DR-3 |
| **DR-4** | Fallo total de `hd5t` (multimedia) | Media-baja | `/mnt/hd5t` desmontado, Stash sin librería | 1–2 h *operativas* + reimport off-line | § DR-4 |
| **DR-5** | Fallo total de la Pi (placa) | Baja | Pi no arranca con microSD válida en otro hardware, signo de hardware quemado | 8–12 h | § DR-5 |
| **DR-6** | Pérdida del sitio (incendio, robo, inundación) | Muy baja | El operador ya no tiene acceso físico a su hardware | 12–24 h | § DR-6 |
| **DR-7** | Compromiso de credenciales / ransomware | Muy baja | Acceso no autorizado detectado, ficheros cifrados, alerta Authelia con burst de fallos seguido de éxito | depende | § DR-7 |

Cada escenario tiene su procedimiento. La regla cardinal antes de ejecutar **cualquiera** de ellos:

```
1. PARAR. Respirar. No ejecutar nada destructivo en los primeros 5 minutos.
2. CONFIRMAR el escenario. Una microSD que no arranca puede ser un cable HDMI suelto.
3. PROTEGER lo que queda. Si hd2t aún se monta, NO hacer nada que lo escriba
   hasta tener un snapshot de respaldo. Un disaster recovery mal hecho es la
   forma más rápida de convertir un DR-1 en un DR-3.
4. ABRIR este documento por la sección correspondiente y SEGUIR los pasos
   en orden, sin saltar.
5. ANOTAR cada paso en MAINTENANCE_LOG.md con timestamp. Si el incidente
   escala, esa bitácora es el único hilo de Ariadna.
```

> **Decisión "no improvisar"**: el operador con menos riesgo es el operador que no decide en caliente. Si un paso del procedimiento parece subóptimo a las 3 AM, se hace el paso tal cual está y se anota la duda para revisar al día siguiente. Optimizar bajo presión introduce errores con confianza falsa.

---

## DR-1 — Corrupción de un servicio único

**Síntoma típico**: un servicio (Authelia, Nextcloud, Pi-hole) reporta errores que no son red (no es el DNS, no es Caddy, no es Authelia upstream): integridad de BBDD, ficheros corruptos, índices desincronizados.

Este caso **no es un disaster** propiamente dicho — es el más frecuente y `07-backups/03-backup-docker-volumes.md` ya documenta el flujo end-to-end ("Flujo 1 — Restore puntual de un servicio"). Aquí solo se enumera la **decisión** previa.

| Decisión | Acción |
|---|---|
| ¿El error es del propio servicio, o de su upstream (red, Authelia, Caddy)? | Aislar primero con `docker logs` + `curl` directo al puerto interno. Si la red está bien y el servicio sigue mal, sospechar dato. |
| ¿El servicio escribe activamente? | Parar el servicio (`docker compose stop <svc>`) **antes** de tocar nada. Restaurar encima de un fichero abierto es undefined behavior. |
| ¿El fichero corrupto se puede salvar? | Renombrar a `.broken-<fecha>` (no borrar) por si el restore falla y se necesita forensia. |
| ¿Cuál es el archive Borg más reciente que precede al fallo? | El de la noche pasada por defecto (`borg list --short \| tail`). Si la corrupción ocurrió hace más tiempo, retroceder en la lista. |

A partir de aquí, el procedimiento concreto vive en `07-backups/03-backup-docker-volumes.md` § "Procedimientos por motor de base de datos". Este documento añade solo:

- **Anotación obligatoria** en `MAINTENANCE_LOG.md` (no solo en `BACKUPS_LOG.md`): un DR-1 marca un evento operativo que merece auditoría, no solo un drill.
- **Análisis de causa raíz** dentro de las 48 h: ¿fue un upgrade reciente?, ¿un OOM-killer?, ¿un sector pendiente del disco?, ¿una pulga conocida del software? Si la causa no se identifica y se documenta, DR-1 vuelve.

> **Salida del DR-1 hacia DR-3**: si al restaurar se descubre que **el archive Borg también está corrupto** (`borg check --archives-only` falla en el archive elegido), el incidente escala: ya no es solo el servicio, es el repo Borg local. Ir a DR-3.

---

## DR-2 — Fallo total de la microSD

**Síntoma típico**: la Pi no arranca al rearranque, o arranca y muere en *kernel panic*, o `dmesg` muestra cientos de errores `mmcblk0`. La microSD se desgasta linealmente con el tiempo y los HDD USB-mounted siguen vivos.

| # | Paso | Comando / acción | Tiempo |
|---|---|---|---|
| 1 | **Confirmar el diagnóstico**: probar la microSD en un lector USB desde otro PC. Si lectura/escritura da errores, microSD muerta. | (lector USB) | 10 min |
| 2 | **Apagar la Pi limpiamente** si aún está parcialmente viva: `sudo poweroff`. Si no responde, cortar la corriente — no hay BBDD que pueda corromperse aquí porque las BBDD viven en `hd2t`. | — | 1 min |
| 3 | **No tocar `hd2t` ni `hd5t`**. Los HDD se quedan donde están: contienen datos y el repo Borg local. Si por algún motivo hay que desconectarlos, etiquetarlos físicamente con cinta + rotulador para no confundirlos al reconectar. | — | — |
| 4 | **Flashear una microSD nueva** desde otro PC con Raspberry Pi Imager: imagen Raspberry Pi OS 64-bit Lite (la misma versión documentada en `01-sistema/01-instalacion-os.md`). Configurar hostname, usuario `homelab`, SSH key del operador, Wi-Fi (si la Pi se va a montar sin Ethernet temporalmente). | Raspberry Pi Imager | 15–30 min |
| 5 | **Insertar la microSD nueva** y arrancar la Pi **sin los HDD aún conectados**. Validar que arranca sola y SSH responde. | `ssh homelab@<ip>` | 10 min |
| 6 | **Reaplicar Fase 1** (`01-sistema/`): paquetes base, hardening SSH, `unattended-upgrades`, `logrotate`, `journalctl --vacuum-time`, `smartmontools`. La mayor parte está en `01-sistema/02-configuracion-inicial.md` y `03-seguridad-base.md`. | (manual, siguiendo Fase 1) | 30–45 min |
| 7 | **Reconectar `hd2t` y `hd5t`**, verificar que automontan vía `/etc/fstab`. Atención: el `/etc/fstab` lo escribe el operador en este paso (lo restaurará desde el repo git en el paso 9), o lo escribe a mano basado en `00-hardware/03-preparacion-discos.md`. | `lsblk` y montaje manual antes de fstab | 10 min |
| 8 | **Reaplicar Fase 2** (`02-docker/`): instalar Docker Engine, configurar `daemon.json` con log driver, levantar Watchtower y Portainer. | Fase 2 | 20 min |
| 9 | **Restaurar `/home/homelab/homelab/`** desde git: `git clone git@github.com:<usuario>/homelab.git`. Esto trae **el código** (composes, scripts, plantillas) pero **no** los `secrets/` ni los `.env` (están en `.gitignore`). | `git clone` | 5 min |
| 10 | **Restaurar `secrets/` y `.env` por stack** desde el repo Borg local — que sigue intacto en `/mnt/hd2t/backups/borg/` porque `hd2t` no fue afectado: ver § "Restaurar secrets/ desde Borg" más abajo. | (procedimiento dedicado) | 20 min |
| 11 | **Levantar los stacks por capas** en el orden de la fase: red (Pi-hole + Caddy + Authelia) → monitorización → backups → almacenamiento → resto. Ver § "Orden de arranque por capas". | `docker compose up -d` por stack | 30–60 min |
| 12 | **Smoke tests** completos (§ Verificación post-recuperación). Ningún incidente DR-2 se cierra hasta que la lista entera está en verde. | (manual) | 30 min |
| 13 | **Anotar** todo el incidente en `MAINTENANCE_LOG.md` con timestamps reales, problemas encontrados, decisiones tomadas. Commit. | — | 10 min |
| 14 | **Reabrir**: ¿hay que migrar a NVMe (HAT NVMe sobre Pi 5)? Una segunda muerte de microSD en menos de 12 meses lo justifica. Anotar la decisión, no ejecutarla en caliente. | — | — |

**Tiempo total estimado RTO**: **4–6 h** en condiciones favorables (microSD nueva ya en stock, ningún cable USB sospechoso, Backblaze accesible aunque no sea necesario porque el repo local sobrevivió).

> **Por qué los HDD no se conectan en el paso 5**: si la microSD nueva se ha flasheado mal o el `/etc/fstab` cargado tiene rutas erróneas, un automount al arrancar puede confundir nombres `/dev/sdX` o, peor, montar en una ruta que se sobreescriba. Arrancar **sin** los HDD aísla la variable y permite confirmar que la Pi sola está bien antes de cargar variables de almacenamiento.

> **Salida del DR-2 hacia DR-3**: si al reconectar `hd2t` resulta que el disco no monta (no es solo la microSD lo que ha muerto), el incidente escala. Continuar con DR-3.

### Restaurar `secrets/` desde Borg (paso 10)

```bash
# El repo Borg en /mnt/hd2t/backups/borg/ sigue intacto.
# La passphrase Borg viene de la caja fuerte / gestor cloud externo.

# 1. Levantar SOLO el stack borgmatic (sin el resto del homelab).
cd /home/homelab/homelab/stacks/borgmatic
# Crear .env mínimo: BORG_PASSPHRASE_FILE apunta a la passphrase recién escrita.
mkdir -p /home/homelab/homelab/secrets
chmod 0700 /home/homelab/homelab/secrets
# Escribir la passphrase a mano desde la caja fuerte:
vi /home/homelab/homelab/secrets/borg.passphrase
chmod 0600 /home/homelab/homelab/secrets/borg.passphrase

# 2. Levantar el stack borgmatic en modo restore (override de 03-backup-docker-volumes.md)
docker compose -f docker-compose.yml -f restore.compose.yml run --rm -it borgmatic bash

# Dentro del contenedor:
# - Listar archives
borg list /mnt/borg-repo
# - Extraer SOLO el directorio de secretos del archive más reciente
ARCHIVE=$(borg list /mnt/borg-repo --short | tail -1)
mkdir -p /mnt/exports/secrets-restore
borg extract --strip-components=2 \
  /mnt/borg-repo::"${ARCHIVE}" \
  source/home/homelab/homelab/secrets \
  --target /mnt/exports/secrets-restore
exit

# 3. Promover los secretos extraídos al lugar definitivo
cp -a /mnt/hd2t/backups/exports/secrets-restore/secrets/. /home/homelab/homelab/secrets/
chown -R homelab:homelab /home/homelab/homelab/secrets/
chmod 0700 /home/homelab/homelab/secrets/
find /home/homelab/homelab/secrets/ -type f -exec chmod 0600 {} \;

# 4. Limpiar el scratch
rm -rf /mnt/hd2t/backups/exports/secrets-restore
```

> **Bootstrap problem (recordatorio de Fase 7)**: la passphrase Borg vive **dentro** del propio Borg. Hasta que se teclea desde la custodia fuera de banda, no hay forma de leer nada. Una vez tecleada y `secrets/` extraído, el resto del homelab puede arrancar.

---

## DR-3 — Fallo total de `hd2t`

**Síntoma típico**: `hd2t` deja de montar, `dmesg` muestra IO errors masivos, `smartctl -H` da `FAILED`, o `Reallocated_Sector_Ct` salta de cero a centenares en un par de horas. `hd2t` aloja **todo** lo crítico: datos de aplicaciones, dumps SQL, repo Borg local. Su pérdida implica:

- Datos primarios en `/mnt/hd2t/apps/` → recuperables desde **offsite** (Backblaze B2).
- Repo Borg local → recuperable desde **offsite**.
- Backups: la copia "doble" del homelab queda reducida a la copia offsite; durante el incidente no hay redundancia.

### Antes de empezar

| Paso | Acción |
|---|---|
| Confirmar | Disco realmente muerto (probar en otro USB, otro cable, otro PC con `dd if=/dev/sdX of=/dev/null status=progress` para detectar si responde). El cable USB-A es la causa #1 de falsos positivos: cambiar **antes** de declarar muerto el disco. |
| Etiquetar | Si se decide que el disco está muerto, etiquetarlo físicamente con `BAD_HD2T_<fecha>` y dejarlo aparte. No reusarlo aunque "vuelva" — los discos que vuelven después de fallar fallan otra vez en semanas. |
| Comprar | Disco de reemplazo de mismo o mayor tamaño (≥ 2 TB). Idealmente con marca y modelo distintos al fallido (evitar lote defectuoso). El tiempo de compra puede ser dominante en el RTO. |
| Comprobar offsite | Antes de tocar nada: validar desde otro PC que el bucket B2 existe y la App Key funciona: `rclone --config <conf> ls b2crypt:homelab/borg/`. Si esto falla, el incidente escala a algo más que un HDD. |

### Procedimiento

| # | Paso | Comando / acción | Tiempo |
|---|---|---|---|
| 1 | **Apagar la Pi**, desconectar el `hd2t` muerto, conectar el `hd2t` nuevo en el mismo puerto USB. | (físico) | 5 min |
| 2 | **Encender la Pi**, validar que el sistema arranca con `hd5t` (multimedia) y sin `hd2t` (los stacks que dependen de `hd2t` no levantarán). | `lsblk`, `dmesg \| tail` | 5 min |
| 3 | **Particionar y formatear** el disco nuevo siguiendo `00-hardware/03-preparacion-discos.md`: GPT, una partición ext4, etiqueta `hd2t`, UUID nuevo. | `parted`, `mkfs.ext4 -L hd2t`, `tune2fs -m 1` | 15 min |
| 4 | **Actualizar `/etc/fstab`** con el UUID nuevo. La línea de `hd2t` cambia (UUID viejo vs nuevo); la de `hd5t` se queda. | `blkid`, `vi /etc/fstab` | 5 min |
| 5 | **Montar `hd2t`**, recrear estructura de directorios siguiendo `01-sistema/04-estructura-directorios.md`: `apps/`, `backups/borg/`, `backups/dumps/`, `backups/exports/`, `media/`, `downloads/` con permisos `0700`/`0750` según corresponda. | `mount -a`, `mkdir -p`, `chown -R homelab:homelab`, `chmod` | 10 min |
| 6 | **Restaurar el repo Borg desde offsite** a `/mnt/hd2t/backups/borg/`. Es el paso largo: sync completo del bucket B2 cifrado. | `rclone --config secrets/rclone.conf copy b2crypt:homelab/borg/ /mnt/hd2t/backups/borg/ --progress --transfers 8` | 1–6 h según volumen y ancho de banda |
| 7 | **Verificar el repo recuperado**: `borg check --repository-only /mnt/hd2t/backups/borg/`. Si reporta inconsistencias, **parar y diagnosticar**; el repo offsite no debería estar corrupto. | `docker compose run --rm borgmatic borg check --repository-only /mnt/borg-repo` | 5–30 min |
| 8 | **Restaurar `/mnt/hd2t/apps/`** desde el archive más reciente: extracción completa al destino final. | (ver § "Restore masivo desde archive" más abajo) | 30–90 min |
| 9 | **Restaurar `/mnt/hd2t/backups/dumps/`** desde el mismo archive (los dumps SQL son la fuente de verdad para Postgres restore en el siguiente paso). | extract dirigido | 5 min |
| 10 | **Levantar los stacks por capas** y, para servicios con BBDD relacional, ejecutar `pg_restore` / `mariadb < dump.sql` desde los dumps recuperados. Ver `07-backups/03-backup-docker-volumes.md` § PostgreSQL/MariaDB. | `docker compose up -d` + restore SQL por servicio | 1–2 h |
| 11 | **Smoke tests completos** (§ Verificación). | — | 30 min |
| 12 | **Re-establecer la sincronización offsite**: el primer `rclone sync` post-DR puede ser largo (sube todo lo que difiere); programar fuera de hora. | (Borgmatic toma el control en la siguiente noche programada) | — |
| 13 | **Anotar** en `MAINTENANCE_LOG.md` y `BACKUPS_LOG.md`. | — | 10 min |
| 14 | **Reabrir**: análisis post-mortem. ¿Fue el disco?, ¿el cable?, ¿el HUB USB?, ¿la fuente de la Pi (Pi 5 con periferia USB pesada al borde de los 5 V/5 A)? Si la causa es el cable o la fuente, comprar repuestos antes del próximo lunes. | — | — |

**Tiempo total estimado RTO**: **6–10 h** en condiciones favorables.

### Restore masivo desde archive (paso 8)

```bash
# Pre-condición: repo Borg en /mnt/hd2t/backups/borg/ verificado (paso 7)
# y secrets/ disponibles (extraídos previamente con el procedimiento de DR-2 § "Restaurar secrets/").

cd /home/homelab/homelab/stacks/borgmatic

ARCHIVE=$(docker compose run --rm borgmatic borg list /mnt/borg-repo --short | tail -1)
echo "Restaurando archive: ${ARCHIVE}"

# Extraer todo el árbol /mnt/hd2t/apps/ del archive directamente al destino final.
# El override de restore monta /mnt/hd2t/backups/exports/ como /mnt/exports/.
# Para extraer al destino real /mnt/hd2t/apps/, se monta puntualmente como volumen extra.

docker run --rm -it \
  -v /mnt/hd2t/backups/borg:/mnt/borg-repo:ro \
  -v /mnt/hd2t/apps:/restore-target \
  -v /home/homelab/homelab/secrets/borg.passphrase:/run/borg-passphrase:ro \
  -e BORG_REPO=/mnt/borg-repo \
  -e BORG_PASSCOMMAND='cat /run/borg-passphrase' \
  ghcr.io/borgmatic-collective/borgmatic:latest \
  bash -c "cd /restore-target && borg extract --strip-components=4 \
    \"::${ARCHIVE}\" source/mnt/hd2t/apps"

# Verificar permisos
chown -R homelab:homelab /mnt/hd2t/apps/
find /mnt/hd2t/apps/ -type d -exec chmod 0750 {} \;
# Algunos servicios requieren modos específicos (Authelia 0700 en data/, etc.):
# revisar service-by-service consultando la página de cada servicio.
```

> **Por qué `--strip-components=4`**: Borg almacena los paths con su prefijo absoluto. El archive contiene `source/mnt/hd2t/apps/<svc>/...`. Para que el extract caiga directamente en `/restore-target/<svc>/...`, se eliminan los 4 primeros segmentos (`source/mnt/hd2t/apps`).

> **Cuidado con `cache/`**: el archive incluye `apps/<svc>/data/` y `apps/<svc>/config/` pero **no** `apps/<svc>/cache/` (excluido en Borgmatic por política T4). Tras el restore, los caches se regeneran al primer arranque del servicio. Es esperado.

---

## DR-4 — Fallo total de `hd5t`

**Síntoma típico**: `/mnt/hd5t` desmontado, Stash sin librería visible, errores SMART en el HDD de 5 TB.

`hd5t` aloja **únicamente** la librería multimedia. Por política `01-estrategia-backup.md` § Tier 4, **no entra en backup**: es voluminoso (TB), reconstituible desde la fuente, y la decisión consciente del homelab es no respaldarlo.

| # | Paso | Acción |
|---|---|---|
| 1 | **Confirmar muerte real**: cambiar cable USB, probar en otro puerto. | (físico) |
| 2 | **Comprobar metadatos Stash**: el catálogo, miniaturas y tags **viven en `hd2t`** (`apps/stash/`). Si `hd2t` está sano, los metadatos sobreviven y solo se pierde la librería binaria. | `ls /mnt/hd2t/apps/stash/` |
| 3 | **Reemplazar el disco** (≥ 5 TB, marca/modelo distintos al fallido). Particionar, formatear ext4, label `hd5t`, UUID nuevo, actualizar `/etc/fstab`. | Fase 0 |
| 4 | **Recrear estructura de `/mnt/hd5t/`**: subdirectorios según `06-almacenamiento/` (la estructura exacta vive ahí). | `mkdir -p`, permisos |
| 5 | **Re-importar la librería** desde la fuente externa (no se documenta aquí; depende de cada origen). | (operativa offline, días) |
| 6 | **Stash**: una vez la librería esté en `hd5t` con la misma estructura de paths, Stash detecta los ficheros y los reanuda (los hashes en su BBDD coinciden con los nuevos ficheros si la fuente es la misma). | UI Stash → Settings → Tools → Scan |
| 7 | **Sonarr / Radarr / Prowlarr**: si el operador los usa, también dependen de `hd5t`. Su BBDD de "qué hay en disco" se reconstruye con un re-scan. | UI de cada servicio → Library → Update / Refresh |
| 8 | Anotar en `MAINTENANCE_LOG.md`. | — |

**Tiempo operativo (lo que requiere atención humana)**: 1–2 h (cambiar disco, formatear, montar, reconfigurar). **Tiempo total real**: días-semanas si la librería se reimporta desde la fuente externa por capacidad de bajada.

> **Decisión cerrada**: no se introduce un backup de `hd5t`. La política se reabre solo si la librería deja de ser reconstituible desde la fuente.

---

## DR-5 — Fallo total de la Pi

**Síntoma típico**: la Pi no enciende, no arranca con una microSD válida probada en otra Pi, hay daño físico visible (puerto USB quemado, condensador hinchado), o la Pi tiene fallos intermitentes que persisten después de cambiar microSD y fuente.

| # | Paso | Acción |
|---|---|---|
| 1 | **Diagnóstico cruzado**: probar la microSD actual en una Pi de prueba si se dispone (o pedir prestada); probar la fuente; probar otra microSD. Si el problema persiste solo en *esta* Pi, la placa está rota. | — |
| 2 | **Comprar Pi 5 nueva** (8 GB para mantener compatibilidad con perfiles de memoria de los stacks). El RTO depende del tiempo de compra. | — |
| 3 | **Trasladar al nuevo hardware** la microSD existente (si está sana) y los HDD. La microSD trae el sistema operativo y, si está sana, el homelab arranca casi sin tocar nada. | — |
| 4 | **Validar booteo**: la Pi nueva con la misma microSD debe arrancar y reconocer los HDD. | `lsblk`, `docker ps` |
| 5 | **Reaplicar firmware**: `sudo rpi-eeprom-update -a` por si la Pi nueva viene con bootloader antiguo, reboot. | `rpi-eeprom-update` |
| 6 | **Re-registrar Tailscale**: el nodo Pi tiene un identidad asociada; según política Tailscale, puede que la nueva Pi necesite re-autorización en el admin web. | `tailscale up` desde la nueva Pi |
| 7 | **Smoke tests** completos (§ Verificación). | — |
| 8 | **Si la microSD también está rota**: el caso degenera en DR-2 (microSD) sobre hardware nuevo. Aplicar DR-2 a partir del paso 4 (flashear nueva). | — |

**Tiempo total estimado RTO**: **8–12 h** dominados por la compra; el trabajo técnico es ~30 min si la microSD sobrevive.

> **Por qué Pi 5 8 GB y no Pi 4**: el homelab está dimensionado para 8 GB en `13-operaciones/03-rendimiento-pi5.md`. Volver a Pi 4 (4 GB max) implica reducir servicios o aceptar swap; no es un "downgrade neutro".

---

## DR-6 — Pérdida total del sitio

**Síntoma típico**: incendio, robo, inundación. El operador no tiene acceso físico a la Pi ni a los HDD. Solo tiene la custodia fuera de banda y el repo git remoto.

Este es el escenario que `07-backups/01-estrategia-backup.md` § RPO/RTO lista como "RTO ≤ 24 h" y `07-backups/03-backup-docker-volumes.md` § Flujo 3 ya documentó paso a paso. Aquí solo se enumera la **secuencia de alto nivel** y los puntos donde este documento añade matiz operativo:

| Fase | Procedimiento | Documento canónico |
|---|---|---|
| **Hardware** | Comprar Pi 5 nueva, microSD nueva, dos HDD nuevos. | DR-5 + DR-3 |
| **OS y sustrato** | Reaplicar Fases 0, 1, 2 del homelab desde cero. | `00-hardware/`, `01-sistema/`, `02-docker/` |
| **Repo de código** | `git clone` del repo privado a `/home/homelab/homelab/`. | — |
| **Secretos** | Escribir a mano `secrets/borg.passphrase` y `secrets/rclone-crypt.passphrase` desde la custodia fuera de banda. Crear `secrets/rclone.conf` con credenciales B2 (también de la custodia). | `07-backups/01-estrategia-backup.md` § Custodia |
| **Repo Borg** | `rclone copy` desde B2 a `/mnt/hd2t/backups/borg/`. Verificar con `borg check --repository-only`. | `07-backups/03-backup-docker-volumes.md` § Flujo 3 |
| **Datos** | Restore masivo desde archive a `/mnt/hd2t/apps/`. | DR-3 § "Restore masivo desde archive" |
| **Servicios** | Levantar stacks por capas, restaurar BBDD desde dumps. | § "Orden de arranque por capas" más abajo |
| **Multimedia** | `hd5t` se asume perdido. La librería se reimporta off-line desde la fuente. | DR-4 |
| **Re-registro Tailscale** | Borrar el nodo viejo del admin web; re-registrar el nodo nuevo. | — |
| **Verificación** | Smoke tests completos. | § Verificación post-recuperación |

**Tiempo total estimado RTO**: **12–24 h** en condiciones favorables, dominado por:

1. Tiempo de compra de hardware (variable; dependiendo de stock local puede ser 0 h o 3 días).
2. Tiempo de bajada del repo Borg desde B2 (1–6 h según el tamaño y la fibra).
3. Tiempo de aplicar Fases 0–2 sobre hardware nuevo (3–5 h).

> **Lo que no se recupera**: la librería multimedia de `hd5t` y los datos T3/T4 explícitamente excluidos. Es la decisión cerrada en `01-estrategia-backup.md`. Aceptar conscientemente.

> **Coste de "comprar antes de necesitar"**: el operador puede decidir tener ya un cable USB-A de repuesto, una microSD de calidad sin abrir y la passphrase Borg en dos ubicaciones físicas (kit de recuperación). No es paranoia: es la diferencia entre 6 h y 24 h de RTO.

---

## DR-7 — Compromiso de credenciales / ransomware

Escenario muy improbable dado el alcance LAN + Tailscale (sin exposición a internet salvo el cliente saliente B2), pero contemplado por completitud.

| Indicador | Acción inmediata |
|---|---|
| Burst de fallos Authelia desde una IP **interna** seguido de un éxito | Suspender la cuenta Authelia (UI admin), forzar logout de todas las sesiones, rotar passwords. Investigar el dispositivo origen. |
| Ficheros `.encrypted` o renombrados masivamente en `/mnt/hd2t/apps/` | **Desconectar la Pi de la red** (Ethernet fuera, Wi-Fi off). Aislar antes de diagnosticar. |
| Repo Borg local cifrado/borrado | Lo que queda es el offsite. Tratar como DR-3 partiendo de B2. **Antes** de restaurar, validar que B2 no ha sido tocado (versionado del bucket, App Key con permiso solo de upload/download, no de delete sobre archives ya creados — política Borgmatic en `02-borgmatic.md`). |
| Sospecha de compromiso pero nada borrado todavía | **Snapshot defensivo**: forzar un `borgmatic create --stats` extra antes de cualquier acción remediadora. Ese archive es la línea base del estado pre-incidente. |

Acciones de remediación post-confirmación de compromiso:

1. **Rotar todas las passphrase** del homelab: Borg, rclone-crypt, B2 App Key. Esto implica:
   - Crear un repo Borg **nuevo** con passphrase nueva (no reusar el comprometido).
   - Subir el repo nuevo a un bucket B2 nuevo (no reusar el viejo, que puede tener permisos manipulados).
   - Hacer un primer backup completo y verificarlo.
2. **Rotar credenciales Authelia + tokens TOTP**: forzar re-enrolment de TOTP en todos los usuarios.
3. **Rotar tokens Tailscale**: invalidar y re-emitir.
4. **Auditar logs Pi-hole, Authelia, Caddy** desde el momento del primer indicio: ¿qué entró?, ¿qué llegó a tocar?
5. **Reabrir** este documento para anotar el patrón del incidente y, si aplica, añadir reglas de detección en `05-monitorizacion/01-prometheus.md`.

> **Anti-patrón**: pagar el rescate. El homelab tiene backups offsite cifrados; lo correcto es restaurar y, en paralelo, hacer un análisis forense del compromiso.

---

## Orden de arranque por capas

Tras un DR-2/3/5/6, los stacks no se levantan al azar. Hay un **orden de capas** porque cada capa depende de la anterior. Si se rompe el orden, el operador acaba diagnosticando "Authelia no arranca" cuando el problema real es que Pi-hole aún no resuelve el FQDN del IdP.

| Capa | Stacks | Razón del orden | Comprobación de capa |
|---|---|---|---|
| **0. Sustrato** | Docker engine + Watchtower + Portainer | Sin Docker no hay stacks. | `docker ps` muestra los del nivel `infra`. |
| **1. Red** | Pi-hole, Caddy, Authelia | Sin DNS interno (Pi-hole) los stacks no se ven entre sí por hostname. Sin Caddy no hay TLS interno. Sin Authelia las UIs piden credenciales que nadie firma. | `dig @<pi-ip> homepage.lan +short`, `curl -kI https://homepage.lan/`. |
| **2. Backups** | Borgmatic | Antes de levantar nada con datos, garantizar que el primer backup nocturno post-DR captura el estado restaurado. | `docker logs borgmatic` muestra cron activo. |
| **3. Monitorización** | Prometheus, Grafana, node_exporter, cAdvisor, Uptime Kuma, Dozzle | Para que el operador **vea** lo que está levantando en las siguientes capas. | Grafana muestra el target `node_exporter` en up. |
| **4. Almacenamiento** | Nextcloud (+ db, redis), Samba, Syncthing, MinIO | Servicios con datos pesados; restauran su BBDD desde dumps en este punto. | Login en Nextcloud, `mc ls minio/`. |
| **5. Domótica** | Home Assistant, Node-RED | Independientes de la capa 4 pero pueden depender de MQTT broker si está en otro stack. | UI Home Assistant accesible. |
| **6. Multimedia** | Stash, *arr suite, qBittorrent | Dependen de `hd5t` (si DR-4 pendiente, esta capa se levanta sin librería; aceptable). | UI Stash accesible aunque la librería esté vacía. |
| **7. Productividad** | FreshRSS, Linkding, Mealie, Calibre-Web, BookStack, Paperless-ngx, Vaultwarden | Servicios "personales" del operador. Capa final. | Smoke test de cada UI. |
| **8. Dashboard** | Homepage | Última pieza: agrega todo lo anterior. Si Homepage muestra rojos, los detecta automáticamente. | Homepage carga, todos los widgets en verde. |

> **Decisión**: Borgmatic se levanta **antes** de la capa de almacenamiento, no después. Razón: si tras restaurar Nextcloud DB resulta que el archive tenía un dump corrupto y hay que retroceder, queremos haber capturado el estado *intermedio* en un nuevo archive (el "estado tras DR-3") antes de tocar nada más. Es paranoia, pero el coste es minutos y el beneficio es la red de seguridad de tener un punto de retorno.

> **Si una capa falla**: parar y diagnosticar antes de pasar a la siguiente. Avanzar con la capa 1 rota (Authelia caído) para llegar a la capa 7 garantiza que el incidente se transformará en cuatro incidentes superpuestos.

---

## Procedimientos detallados

### Validación del repo Borg recuperado

Antes de restaurar **un solo byte** de datos, el repo Borg recuperado (sea local intacto, sea bajado de B2) debe pasar tres comprobaciones:

```bash
cd /home/homelab/homelab/stacks/borgmatic

# 1. Repository check (estructura del repo)
docker compose run --rm borgmatic borg check --repository-only /mnt/borg-repo

# 2. List de archives (no se ha perdido el manifest)
docker compose run --rm borgmatic borg list /mnt/borg-repo

# 3. Archives check del último archive (rehash; costoso, opcional pero recomendado en DR-3/6)
LATEST=$(docker compose run --rm borgmatic borg list /mnt/borg-repo --short | tail -1)
docker compose run --rm borgmatic borg check --archives-only \
  /mnt/borg-repo --last 1
```

Si **alguno** de los tres falla, **parar**: el repo bajado tiene problemas, y restaurar encima es perder tiempo. Las opciones son:

- Probar con un archive anterior (`borg list --short | tail -3`).
- Re-bajar el repo desde B2 (puede haber sido un fallo de transferencia).
- Validar que las passphrase son las correctas (un fallo de descifrado se reporta como corrupto).

### Resincronización offsite tras DR-3/6

Tras restaurar el repo Borg local desde B2, el siguiente backup nocturno de Borgmatic + rclone va a hacer un sync largo: el repo local y el offsite están bit-a-bit iguales en este momento, pero en cuanto Borgmatic cree un archive nuevo, rclone se da cuenta del delta y lo sube.

```bash
# Verificación post-DR de que el sync converge:
cd /home/homelab/homelab/stacks/borgmatic
docker compose exec borgmatic rclone --config /run/secrets/rclone.conf \
  check /mnt/borg-repo b2crypt:homelab/borg/ \
  --one-way --combined /tmp/rclone-check.txt | head
```

Mientras `homelab_backup_offsite_lag_seconds` no vuelva a < 24 h, el homelab está "operativo pero con una sola copia". No declarar el DR cerrado hasta que el offsite esté al día.

### Datos que **no** se restauran

Por política `01-estrategia-backup.md`:

| No restaurado | Por qué |
|---|---|
| `/mnt/hd2t/media/`, `/mnt/hd2t/downloads/` | T4: voluminoso, regenerable. |
| `/mnt/hd2t/apps/*/cache/` | T4: caches; los servicios los regeneran. |
| `/mnt/hd2t/apps/*/redis/dump.rdb`, `appendonly.aof` | T4: derivados; la BBDD primaria es la fuente de verdad. |
| `/mnt/hd2t/apps/prometheus/data/` | T4: TSDB; las métricas históricas se asumen perdidas. |
| `/mnt/hd5t/` | Excluido. Reimport desde fuente. |
| `/var/lib/docker/` | Re-creable desde compose. |

Tras el restore, los servicios pueden comportarse "raros" durante minutos:

- **Nextcloud** vuelve a hacer scan de ficheros. Aceptable.
- **Stash** muestra librería vacía (si DR-4) o reanuda hashes (si solo DR-2/3 con `hd5t` intacto).
- **Prometheus** arranca con TSDB vacío → 30 días sin histórico de métricas. Aceptable.
- **Watchtower** detecta imágenes "viejas" (las del archive) y puede actualizar todas el primer miércoles post-DR. Aceptable salvo que se quiera congelar versiones temporalmente: en ese caso, comentar el cron de Watchtower hasta validación.

---

## Verificación post-recuperación

Ningún DR se declara cerrado hasta que **todos** estos puntos están verdes. Si alguno falla, el incidente sigue abierto y el operador no se va a la cama.

| # | Comprobación | Comando / dónde | Verde si |
|---|---|---|---|
| V1 | Pi arranca limpia | `uptime`, `dmesg --level=err,warn \| tail -50` | Sin errores recurrentes. |
| V2 | Ambos HDD montados | `df -h /mnt/hd2t /mnt/hd5t` | Ambos con porcentajes esperados. |
| V3 | Docker engine vivo | `docker info`, `docker ps -a` | Engine OK; todos los stacks esperados arriba. |
| V4 | DNS interno funciona | `dig @<pi-ip> homepage.lan +short` | Respuesta válida. |
| V5 | TLS interno funciona | `curl -kI https://homepage.lan/` | `200 OK` o `302`. |
| V6 | Authelia operativo | Login al portal | Login OK con credenciales restauradas. |
| V7 | Pi-hole bloquea | UI Pi-hole → Top Blocked Domains | Tráfico DNS reciente, listas activas. |
| V8 | Nextcloud operativo | Login + navegación de ficheros | Lista de ficheros restaurada. |
| V9 | Nextcloud DB consistente | `docker exec nextcloud-db psql -U nextcloud -d nextcloud -c "SELECT count(*) FROM oc_users;"` | Count razonable (≥ usuarios esperados). |
| V10 | Stash metadatos | UI Stash → Library | Catálogo presente (librería binaria puede faltar si DR-4). |
| V11 | Borgmatic vivo | `docker logs borgmatic --tail 50` | Cron activo, sin errores. |
| V12 | Próximo backup programado | `docker compose exec borgmatic crontab -l` | Línea cron presente. |
| V13 | Métricas llegan a Prometheus | Grafana → "Pi 5 health" | `node_exporter` up, datos recientes. |
| V14 | Uptime Kuma reactivo | UI Uptime Kuma | Todos los monitores en verde tras unos minutos de re-check. |
| V15 | Watchtower vivo | `docker logs watchtower --tail 50` | Sin errores. |
| V16 | Tailscale vivo | `tailscale status` | Pi visible en la mesh. |
| V17 | Backup offsite alineado | Grafana → `homelab_backup_offsite_lag_seconds` | < 48 h. Puede tomar 1 noche en converger. |
| V18 | Bitácora actualizada | `git log MAINTENANCE_LOG.md \| head -3` | Commit del incidente presente. |
| V19 | `BACKUPS_LOG.md` actualizado | `git log BACKUPS_LOG.md \| head -3` | Si hubo restore, entrada con tiempos reales. |
| V20 | Smoke test ad-hoc del operador | "abrir Homepage, hacer click en cada widget, comprobar que cada servicio carga" | Sin sorpresas. |

> **Decisión "todos verdes o nada"**: tener 18 de 20 verdes y los otros dos "casi" no es aceptable. Cada rojo es un fallo latente que va a salir en el siguiente checklist semanal y va a confundir al operador del futuro (que será el mismo, dos meses después, sin recordar el DR).

---

## Kit de recuperación

El kit de recuperación es lo que el operador necesita tener **antes** de un disaster, no durante. Un DR sin kit es un DR con shopping list — y el shopping domina el RTO.

### Kit físico (en una caja etiquetada, en casa)

| Elemento | Cantidad | Notas |
|---|---|---|
| microSD de calidad sin abrir | 2 | Mismo modelo que la productiva (típicamente Industrial / High Endurance ≥ 32 GB). |
| Cable USB-A → USB-C de calidad | 2 | Para recablear los HDD si el actual da `UDMA_CRC_Error`. |
| Cable HDMI Micro→Standard | 1 | Por si la Pi necesita debug visual y el operador no puede SSH. |
| Fuente Pi 5 oficial 27 W | 1 de repuesto | Las fuentes USB-PD baratas sí causan throttling. |
| Pendrive USB ≥ 16 GB | 1 | Para llevar imágenes flasheadas si el flasheo se hace fuera de casa. |
| Lector de microSD USB | 1 | Para flashear desde otro PC. |
| Cinta + rotulador permanente | — | Etiquetar discos y cables durante el incidente. |

### Kit digital (en un dispositivo distinto al homelab)

| Elemento | Dónde |
|---|---|
| Passphrase Borg | Caja fuerte ignífuga + gestor cloud externo (NO Vaultwarden del propio homelab). |
| Passphrase rclone-crypt | Misma custodia. |
| Credenciales B2 (App Key) | Misma custodia. La App Key tiene scope solo al bucket homelab. |
| URL del repo git privado + clave SSH | Backup en pendrive cifrado + gestor cloud externo. |
| Este documento (`02-disaster-recovery.md`) | Versionado en git → accesible desde el repo remoto desde cualquier dispositivo. |
| `01-estrategia-backup.md` y `03-backup-docker-volumes.md` | Idem. |
| `MAINTENANCE_LOG.md` y `BACKUPS_LOG.md` | Idem; aportan contexto histórico durante el DR. |
| Lista de hostnames `.lan` y servicios esperados | Implícita en `SERVICES.md`. |

### Verificación anual del kit

| # | Verificación | Cuándo |
|---|---|---|
| K1 | Probar que la microSD del kit arranca una Pi (flashear, bootear, login SSH). | Anual (Y2 en `01-mantenimiento-periodico.md`). |
| K2 | Confirmar que la passphrase Borg de la caja fuerte descifra el repo (sin restaurar nada, solo `borg list`). | Anual. |
| K3 | Validar que las credenciales B2 funcionan (`rclone ls`). | Anual. |
| K4 | Comprobar que la fuente de repuesto da los 27 W reales (medir con USB tester). | Anual. |
| K5 | Repasar este documento: cualquier comando obsoleto, version-sensitive, se actualiza. | Anual. |

> **Lección de los DR drills**: el RTO del primer DR siempre supera al objetivo. El RTO del segundo lo cumple. Por eso hay un drill anual desde offsite (`07-backups/01-estrategia-backup.md`): la primera vez que el operador hace el procedimiento real es la peor versión del operador.

---

## Almacenamiento

Este documento es **operativo**: no crea servicios ni ficheros persistentes nuevos. Los artefactos que sí utiliza:

| Ruta | Soporte | Owner:Group | Modo | Contenido |
|---|---|---|---|---|
| `/home/homelab/homelab/MAINTENANCE_LOG.md` | microSD | `homelab:homelab` | `0644` | Recibe entradas tras cada DR con timestamps y decisiones. |
| `/home/homelab/homelab/BACKUPS_LOG.md` | microSD | `homelab:homelab` | `0644` | Recibe entradas si el DR implicó restore desde Borg. |
| `/home/homelab/homelab/secrets/` | microSD | `homelab:homelab` | `0700` | Receptor de las passphrase tecleadas a mano durante DR-2/3/6. |
| `/mnt/hd2t/backups/borg/` | hd2t | `homelab:homelab` | `0700` | Repo Borg local; intacto en DR-1/2/4/5, restaurado desde offsite en DR-3/6. |
| `/mnt/hd2t/backups/exports/` | hd2t | `homelab:homelab` | `0750` | Scratch durante restores selectivos. Se limpia post-DR. |
| `/mnt/hd2t/apps/` | hd2t | varía | varía | Destino final de los datos restaurados. |
| (kit físico) | externo a la Pi | n/a | n/a | Caja con microSD, cables, fuente. |
| (custodia) | externo a la Pi y al hogar | n/a | n/a | Passphrase Borg + rclone-crypt + credenciales B2. |

No se crean directorios nuevos en `/mnt/hd2t/` ni `/mnt/hd5t/` que no existieran en Fase 1.

---

## Backup

| Artefacto | Estrategia |
|---|---|
| `docs/13-operaciones/02-disaster-recovery.md` (este fichero) | Versionado en git. Es **el** documento que el operador abre durante un DR; cualquier ambigüedad cuesta minutos en el peor momento, así que se reescribe en cuanto se detecta. |
| `MAINTENANCE_LOG.md` y `BACKUPS_LOG.md` | Versionados en git + respaldados por Borg (parte de `/home/homelab/homelab/`). Son el registro humano del DR. |
| Kit físico | No tiene "backup" digital. Su redundancia es ser **kit**: dos microSD, dos cables, fuente extra. |
| Passphrase Borg / rclone-crypt / credenciales B2 | Custodia en **dos** ubicaciones físicas/digitales independientes (caja fuerte + gestor cloud externo). Decisión cerrada en `07-backups/01-estrategia-backup.md`. |
| Repo Borg | Triple: local en `hd2t`, offsite en B2, y la propia documentación de cómo restaurarlo (este doc). |

> **Anti-patrón explícitamente prohibido**: dejar la passphrase Borg solo dentro de Vaultwarden del propio homelab. Si la Pi muere y el operador necesita recuperar, no puede acceder a Vaultwarden sin antes recuperar… que requiere la passphrase. Bloqueo circular. Misma decisión que en Fase 7.

---

## Verificación Final

Antes de cerrar este documento (no de cerrar un DR, sino de declarar que la Fase 13.2 está aplicada):

| Comprobación | Comando | Resultado esperado |
|---|---|---|
| El operador conoce y tiene a mano los 7 escenarios DR-1…DR-7 | revisión visual de la sección "Catálogo de escenarios" | OK |
| Kit físico montado y etiquetado | revisión visual del operador | Caja con microSD, cables, fuente y rotulador presente |
| Custodia fuera de banda completada | (manual) | Passphrase Borg + rclone-crypt + B2 anotadas en dos ubicaciones |
| Repo git remoto incluye este doc | `git log docs/13-operaciones/02-disaster-recovery.md` | Al menos un commit |
| Drill **al menos uno** ejecutado | `git log BACKUPS_LOG.md \| grep drill` | Presente |
| Drill **anual desde offsite** programado | entrada en `MAINTENANCE_LOG.md` o calendario externo | Próxima fecha < 12 meses |
| Pi-hole, Caddy, Authelia identificados como capa 1 (red) | revisión visual de la sección "Orden de arranque por capas" | OK |
| Borgmatic identificado como capa 2 (anterior a almacenamiento) | revisión visual | OK |
| Lista de smoke tests V1…V20 conocida | revisión visual de "Verificación post-recuperación" | OK |

Cumplido todo lo anterior, el homelab tiene un **plan de recuperación aplicable**. El siguiente documento (`03-rendimiento-pi5.md`) describe cómo evitar que la Pi entre en throttling silencioso o se quede sin memoria, lo que es a su vez una **forma de prevenir DR-1** (servicios cayéndose por OOM-kill).

---

## Decisiones que **no** se toman en este documento

- **Política de retención y verificación periódica de backups**: cerrada en `07-backups/01-estrategia-backup.md` y `02-borgmatic.md`. Aquí solo se asume que el repo está sano cuando se intenta restaurar.
- **Comandos exactos por motor de BBDD** (`pg_restore`, `mariadb < dump`, `sqlite3 .restore`): cerrados en `07-backups/03-backup-docker-volumes.md`. Aquí se invocan, no se duplican.
- **Tuning de la Pi 5 para evitar OOM-kills**: cubierto en `13-operaciones/03-rendimiento-pi5.md`. Aquí se asume que los `mem_limit` están bien dimensionados.
- **Mapa de puertos y reglas firewall**: cubierto en `13-operaciones/04-red-y-puertos.md`. Aquí no se abren puertos durante un DR.
- **Continuidad activa con failover automático** (cluster, réplica): explícitamente fuera de alcance del homelab.
- **Migración a NVMe o a otro SBC** post-DR: no es disaster recovery, es proyecto de hardware. Se anota en el post-mortem si la causa raíz lo justifica.
- **Plan de comunicación durante incidentes**: el homelab tiene un solo operador; la "comunicación" es `MAINTENANCE_LOG.md` para el yo del futuro. No hay stakeholders externos.
- **Renovación de la CA interna tras DR**: si la CA se restaura desde Borg, sigue válida con su caducidad original; la rotación vive en Fase 4 (seguridad).

---

## Referencias

- [Documento anterior: `docs/13-operaciones/01-mantenimiento-periodico.md`](./01-mantenimiento-periodico.md)
- [Documento siguiente: `docs/13-operaciones/03-rendimiento-pi5.md`](./03-rendimiento-pi5.md)
- [Documento siguiente: `docs/13-operaciones/04-red-y-puertos.md`](./04-red-y-puertos.md)
- [Documento relacionado: `docs/00-hardware/03-preparacion-discos.md`](../00-hardware/03-preparacion-discos.md)
- [Documento relacionado: `docs/01-sistema/01-instalacion-os.md`](../01-sistema/01-instalacion-os.md)
- [Documento relacionado: `docs/01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md)
- [Documento relacionado: `docs/02-docker/01-instalacion-docker.md`](../02-docker/01-instalacion-docker.md)
- [Documento relacionado: `docs/07-backups/01-estrategia-backup.md`](../07-backups/01-estrategia-backup.md)
- [Documento relacionado: `docs/07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md)
- [Documento relacionado: `docs/07-backups/03-backup-docker-volumes.md`](../07-backups/03-backup-docker-volumes.md)
- [Documento relacionado: `docs/12-dashboards/01-homepage.md`](../12-dashboards/01-homepage.md)
- [BorgBackup — `borg check`](https://borgbackup.readthedocs.io/en/stable/usage/check.html)
- [BorgBackup — `borg extract`](https://borgbackup.readthedocs.io/en/stable/usage/extract.html)
- [Borgmatic — Restore de bases de datos](https://torsion.org/borgmatic/docs/how-to/restore-a-database/)
- [rclone — `copy` y `sync`](https://rclone.org/commands/rclone_copy/)
- [Raspberry Pi — Imager y bootloader](https://www.raspberrypi.com/software/)
- [Raspberry Pi — `rpi-eeprom-update`](https://www.raspberrypi.com/documentation/computers/raspberry-pi.html#raspberry-pi-bootloader)
- [Tailscale — Re-registro de nodos](https://tailscale.com/kb/1098/machine-resets/)
- [Backblaze B2 — Application Keys](https://www.backblaze.com/b2/docs/application_keys.html)
