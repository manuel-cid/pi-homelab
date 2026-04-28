# Disaster Recovery

## Descripción

Documento operativo de la **Fase 13** del homelab. Define el **procedimiento end-to-end** de recuperación tras un fallo grave: desde el síntoma ("la Pi no arranca", "el `hd2t` ha desaparecido", "el repo Borg está corrupto", "la casa se ha incendiado") hasta el estado final ("Uptime Kuma vuelve a estar en verde, los smoke tests pasan").

A diferencia de [`./01-mantenimiento-periodico.md`](./01-mantenimiento-periodico.md), que cataloga las tareas **periódicas** que mantienen el homelab vivo, este doc es el **playbook excepcional**: el que se abre cuando algo se ha roto de verdad y hay que reconstruir. Está pensado para que el operador pueda seguirlo bajo presión, con ansiedad o con sueño, sin tener que improvisar comandos.

Cubre, en este orden:

1. **Filosofía**: qué entendemos por "desastre", RPO/RTO objetivo, principios que vertebran el DR del homelab.
2. **Inventario crítico**: las tres piezas que **deben** sobrevivir fuera del homelab para que la recuperación sea posible (passphrase de Borg, repo `~/homelab/` en remoto, copia offsite).
3. **Taxonomía de escenarios**: qué se ha roto, qué sigue vivo, ruta de recuperación recomendada. Un cuadro decisorio del estilo "elija su aventura".
4. **Procedimiento de referencia (escenario maestro)**: pérdida total — Pi destruida, discos perdidos, solo offsite + custodias humanas sobreviven. Cubre desde "pedir hardware" hasta "homelab operativo". Todos los demás escenarios son sub-rutas más cortas de éste.
5. **Procedimientos por escenario**: micro-DRs específicos para fallos parciales (solo microSD, solo `hd2t`, solo `hd5t`, solo repo Borg, compromiso de seguridad, fallo de red).
6. **Clonado periódico de la microSD**: cómo y cuándo crear `backup-YYYY-MM.img` para acelerar drásticamente el escenario "microSD muere".
7. **RPO/RTO**: objetivos concretos del homelab (cuánto dato se pierde, cuánto tiempo se tarda) y bajo qué supuestos.
8. **Validación post-DR**: cómo confirmar que la recuperación está realmente completa y no queda ningún servicio "medio levantado".
9. **Lista de Verificación** y **Solución de Problemas**.

> **Alcance de este doc**: este documento **describe el procedimiento end-to-end**. El detalle granular (cómo se inicia un repo Borg, cómo se cargan dumps de MariaDB, cómo se renueva una clave Caddy) vive en los docs de fase. Aquí se centraliza el **orden**, las **decisiones bajo presión** y los **comandos de pegamento** que conectan unas fases con otras durante una recuperación.

> **Alcance de red**: la recuperación se ejecuta **localmente** sobre la Pi nueva, accediéndola por consola serie / monitor HDMI durante el bootstrap, y por SSH (LAN o Tailscale) una vez está en red. No se requiere abrir puertos al exterior en ninguna fase. La conectividad con el offsite (Backblaze B2 / Storj) es saliente HTTPS, igual que en operación normal.

> **Asunción importante**: este doc asume que el operador **ha preparado** las custodias descritas en §2 **antes** del incidente. Un DR planeado *después* del desastre, sin custodias, no tiene rescate posible para los datos cifrados con Borg ([`../07-backups/01-estrategia-backup.md`](../07-backups/01-estrategia-backup.md) §6.2). El §2 de este doc es por eso "pre-flight" más que "checklist".

---

## Requisitos Previos

- **Fases 0-7 desplegadas y operativas** durante al menos un mes antes de que ocurra el desastre. Sin Borg corriendo y sin offsite sembrado, el DR es teórico.
- **Custodias completas y verificadas** según §2 de este doc: passphrase Borg en triple custodia, repo `~/homelab/` empujado a un remoto privado (GitHub privado, Gitea propio), credenciales offsite (B2/Storj) accesibles desde fuera de la Pi.
- **Operador con acceso desde otra máquina**: un portátil o equipo de escritorio con cliente SSH, KeePassXC y suficiente espacio (≥ 1 TB libre temporal) para descargar el repo Borg desde el offsite si los discos no sobreviven.
- **Hardware de reposición pre-pensado**: el operador sabe **dónde y cómo** comprar otra Raspberry Pi 5 + microSD + fuente + (si procede) discos. La cadena de suministro tarda entre 3 y 14 días según el momento; pretender resolver eso en plena emergencia es la mayor fuente de retraso de un DR.
- **Acceso al router** (o la red doméstica de respaldo si la red original también se ha perdido). Si el router también se quemó, el DR incluye levantar una red mínima primero (línea movil con tethering, router de prestamo, etc.).
- **Calendario de DR drills**: este doc se debe **ensayar** parcialmente al menos una vez al año (sesión anual del playbook periódico, [`./01-mantenimiento-periodico.md`](./01-mantenimiento-periodico.md) §7.1, microSD clonada). El smoke test L3 mensual ([`../07-backups/03-backup-docker-volumes.md`](../07-backups/03-backup-docker-volumes.md) §6) ensaya la parte de datos.

### Decisiones de diseño asumidas

| Decisión | Valor por defecto | Justificación |
|---|---|---|
| RPO objetivo (recovery point) | **≤ 24 h** de pérdida máxima de datos en el peor caso | Borgmatic corre diario a las 03:00. Si el desastre ocurre a las 22:00, se pierden los cambios desde las 03:00 (~19 h). En la práctica, los servicios críticos (Vaultwarden, Bookstack) cambian poco entre backups. Detalle en [`../07-backups/01-estrategia-backup.md`](../07-backups/01-estrategia-backup.md) §1. |
| RTO objetivo (recovery time) | **6-12 h efectivas** + esperas de hardware/banda ancha | "Efectivas" = tiempo del operador frente al teclado. La descarga del repo Borg desde B2 (~50-200 GB) y la espera del envío del Pi nuevo dominan el wall-clock real. Ver §7. |
| Modelo de "lo que sobrevive fuera del homelab" | **Pi5 + microSD + ambos discos pueden perderse simultáneamente**; lo que NO puede perderse: passphrase Borg + repo `~/homelab/` en remoto + credenciales offsite | Estos tres elementos son los **invariantes** que reconstruyen todo lo demás. Ver §2. |
| Cifrado del offsite | **`repokey-blake2`**: la clave está en el propio repo, protegida por passphrase | Si se pierden Pi y discos pero la passphrase está custodiada, descargar de B2 + introducir passphrase basta para abrir el repo desde otra máquina. Detalle en [`../07-backups/01-estrategia-backup.md`](../07-backups/01-estrategia-backup.md) §6.1. |
| Punto de partida del DR | **Pi 5 8 GB + microSD nueva + fuente 27 W + ambos discos (nuevos o supervivientes)** | Mismo hardware que la fase 0. Si la Pi 5 está descatalogada cuando ocurra el desastre, una Pi 4 8 GB sirve con perfil `linux/arm64` (los compose son los mismos). Si solo hay disponible un Pi en la nube provisional, se puede levantar un subset (Vaultwarden + Bookstack) hasta que llegue el hardware. |
| Servicios que **deben** levantar primero en un DR | **Pi-hole + Caddy + Authelia + Vaultwarden + Borgmatic** | Núcleo: DNS interno + reverse proxy + identidad + acceso a passwords del operador + backups. Con esto el operador recupera autonomía para todo lo demás. Resto en orden de [`../07-backups/03-backup-docker-volumes.md`](../07-backups/03-backup-docker-volumes.md) §7. |
| Quién decide "es un desastre" vs "es un fallo periódico" | **El operador, con criterio simple**: si la solución cabe en una sesión de mantenimiento ([`./01-mantenimiento-periodico.md`](./01-mantenimiento-periodico.md)) → no es DR. Si requiere reconstrucción de hardware o restauración masiva de datos → es DR | No hay una métrica binaria; el corte funcional es "¿hay que abrir este doc o el de mantenimiento?". |
| Bitácora de DR | **`~/homelab/operations/dr-incidents.log`** versionado en git, una entrada por incidente | Mismo patrón plain-text que `maintenance.log` y `restore-tests.log`. Cada incidente real (no drill) merece auditoría histórica. Drills: anotación en `restore-tests.log` con cadencia `dr-drill`. |
| Tareas que NO entran en este doc | Mantenimiento periódico, tuning de rendimiento, mapa de puertos | Cubiertas por [`./01-mantenimiento-periodico.md`](./01-mantenimiento-periodico.md), [`./03-rendimiento-pi5.md`](./03-rendimiento-pi5.md) y [`./04-red-y-puertos.md`](./04-red-y-puertos.md) respectivamente. |

---

## 1. Filosofía: qué es un desastre y qué no

### 1.1. Definición operativa

"Desastre" en este homelab significa **al menos uno** de los siguientes:

- La **Pi 5** no arranca y no recupera con un reflasheo simple (HW muerto o microSD destruida con clónica también perdida).
- **Uno o ambos discos externos** (`hd2t`, `hd5t`) son ilegibles (controladora muerta, partición destruida, robados).
- El **repo Borg** local en `/mnt/hd2t/backups/borg/` está corrupto o desaparecido **y** se requiere tirar del offsite.
- **Compromiso de seguridad** confirmado: ransomware, exfiltración, acceso no autorizado con sospecha de manipulación de configs.
- **Pérdida total**: incendio, inundación, robo del armario / sala donde vive la Pi.

Lo que **no** es un desastre (se resuelve con [`./01-mantenimiento-periodico.md`](./01-mantenimiento-periodico.md) o el doc de servicio):

- Un servicio cae con `docker compose ps` mostrando `Exited (1)`. Es un bug; reiniciar y leer logs.
- Watchtower rompió un servicio en su update semanal. Es un rollback al tag anterior, no un DR.
- `borg check --verify-data` mensual reporta corrupción puntual. Está protocolizado en [`../07-backups/01-estrategia-backup.md`](../07-backups/01-estrategia-backup.md) §12 — solo escala a DR si la copia offsite **también** está corrupta.
- Un disco reporta `Reallocated_Sector_Ct` creciente. Es **mantenimiento predictivo**: planificar reemplazo, no reaccionar.

### 1.2. Principios de diseño del DR

El DR del homelab está vertebrado por **cinco principios** que el operador debe interiorizar **antes** de que ocurra un incidente:

1. **Las tres piezas mínimas viven fuera del homelab**: passphrase Borg en custodia humana (papel + KeePassXC), repo `~/homelab/` en un remoto Git público o privado externo, credenciales offsite (B2/Storj). **Si las tres sobreviven, todo lo demás se reconstruye**. La consecuencia operativa: si alguna de las tres falta, el DR es imposible aunque el resto del backup esté perfecto.

2. **Idempotencia obligatoria**: cada doc de fase 0-12 está diseñado para que sus comandos se puedan **re-ejecutar sin romper el estado** ([`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) §4 lo declara explícito). Un DR es exactamente "ejecutar de nuevo todo el homelab sobre hardware nuevo". Si alguna fase no es idempotente, el DR se rompe al pasar por ella.

3. **Definición vs datos**: el homelab separa estrictamente **definición** (`~/homelab/`: docker-compose.yml, Caddyfile, configs, scripts — versionado en git) de **datos** (`/mnt/hd2t/services/`, `/mnt/hd5t/`, BD, secrets — respaldados por Borg). En un DR, la definición se restaura con `git clone`; los datos con `borgmatic extract`. Mezclar ambos en backups sería redundante y haría el repo Borg un orden de magnitud más grande sin beneficio.

4. **Orden estricto de restauración**: red → identidad → BD → almacenamiento → resto. Un servicio que depende de Pi-hole para resolver `caddy.lan` no levanta sin Pi-hole vivo. La tabla canónica es [`../07-backups/03-backup-docker-volumes.md`](../07-backups/03-backup-docker-volumes.md) §7.1 y este doc la reproduce en §4.7.

5. **Verificar antes de reactivar timers**: el primer `docker compose up -d` post-DR **no** debe arrastrar de inmediato Borgmatic ni Watchtower. Borgmatic activo durante una restauración parcial podría sobreescribir el snapshot de "el día que ardió todo" con uno nuevo "el día post-DR vacío" que rotaría el bueno. Watchtower podría intentar pull de una imagen que rompe la versión que se está restaurando. Se reactivan **al final**, en una pasada explícita (§4.10).

### 1.3. La trampa del "DR sobre el papel"

Un DR documentado pero **nunca ensayado** se descubre roto en el peor momento. Síntomas típicos:

- La passphrase de Borg está apuntada en KeePassXC, pero el operador **nunca** abrió el offsite con ella desde otra máquina → resulta que confundió `1` con `l` al transcribirla.
- Los `docker-compose.yml` están en GitHub privado, pero **algún `.env` con secrets está solo localmente** y nunca se incluyó en el repo Borg → el servicio levanta vacío.
- El offsite de B2 lleva semanas sin recibir blobs por una credencial caducada y nadie miró la métrica.

Por eso el playbook periódico ([`./01-mantenimiento-periodico.md`](./01-mantenimiento-periodico.md)) incluye:

- **Smoke test L3 mensual** que ensaya el extract real desde el repo (§5.2 del playbook).
- **Drill anual de microSD clonada** (§7.1 del playbook).
- **Verificación trimestral** de que las credenciales offsite siguen vivas (§6.1 del playbook).

Este doc complementa lo anterior con un **drill anual de "Pi muerta"** opcional pero fuertemente recomendado (§5 de este doc, "drill mode").

---

## 2. Inventario crítico: las tres piezas que deben sobrevivir

Si el desastre destruye la Pi y ambos discos simultáneamente (fuego, robo, inundación), **solo** estas tres piezas hacen posible la reconstrucción. Si alguna falta, partes del homelab se pierden de forma irreversible.

### 2.1. Pieza 1: Passphrase de Borg

**Qué es**: la cadena de 6-8 palabras (diceware) o caracteres aleatorios que protege el repo Borg cifrado. Detalle en [`../07-backups/01-estrategia-backup.md`](../07-backups/01-estrategia-backup.md) §6.2.

**Dónde vive (triple custodia obligatoria)**:

| Custodia | Soporte | Localización |
|---|---|---|
| 1. Digital primaria | **KeePassXC** del operador | Laptop personal sincronizado con el operador (NO en la Pi). |
| 2. Física | **Papel impreso o manuscrito** en sobre cerrado | Caja fuerte / carpeta segura **fuera** de la habitación de la Pi (idealmente fuera de la casa: caja de seguridad bancaria, casa familiar, etc.). |
| 3. Digital secundaria | **Vaultwarden externo** o gestor cloud independiente del homelab | Si Vaultwarden vive **dentro** del homelab — caso por defecto en fase 11 — esta custodia es **redundante con (1)**. Recomendado: registrar la passphrase también en una cuenta Bitwarden gratuita (sincroniza fuera) o equivalente. |

**Verificación periódica** (trimestral, §6 del playbook periódico): leer la passphrase de cada custodia y compararla. Las cadenas largas escritas a mano se transcriben mal con frecuencia: detectar la discrepancia **antes** del DR.

**Si se pierde**: el repo Borg, tanto local como offsite, queda **ilegible para siempre**. No hay backdoor. Reconstrucción posible solo desde fuentes no Borg (ficheros sueltos en Syncthing/Nextcloud, exports manuales que el operador haya guardado fuera, definiciones en `~/homelab/`).

### 2.2. Pieza 2: Repo `~/homelab/` en remoto privado

**Qué es**: el repositorio git con toda la **definición** del homelab — docker-compose.yml de cada stack, Caddyfile, configuration.yml de Authelia, prometheus.yml, plantillas de `.env` (sin secrets reales), scripts operativos y los logs `maintenance.log`, `restore-tests.log`, `borg-compact.log`.

**Dónde vive**: GitHub privado (recomendado por simplicidad), Gitea propio en otro servidor / VPS, GitLab privado, o Codeberg. El criterio es **"sigue accesible si la Pi se esfuma"**.

**Qué NO contiene** (por diseño):
- Datos de servicios (`/mnt/hd2t/services/`).
- Secrets reales (`.env` con passwords, claves API). Solo `.env.example` con la estructura.
- BD ni dumps.

**Verificación periódica** (mensual, §5.6 del playbook): `git -C ~/homelab status` limpio, `git push origin main` exitoso. Si el operador edita configs en producción y olvida commitear, el remoto queda **desactualizado** y el DR partirá de un estado incompleto.

**Si se pierde**: la definición se reconstruye a mano (docker-compose por servicio, Caddyfile entero) — días de trabajo en lugar de horas. Tener este repo en remoto es la diferencia entre un DR de 8 h y un DR de 80 h.

> **Nota sobre secrets**: el patrón canónico del homelab es que los secrets reales viven en `/mnt/hd2t/services/<svc>/secrets/` (cifrados al estar dentro del repo Borg). Plantillas `.env.example` en `~/homelab/`. Detalle en [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md). En DR: tras restaurar Borg, copiar `secrets/` a su sitio antes del primer `docker compose up -d`.

### 2.3. Pieza 3: Credenciales del offsite

**Qué es**: Application Key de Backblaze B2 (o equivalente Storj), bucket name, KeyID. Permiten descargar el repo Borg desde fuera del homelab.

**Dónde vive**:

| Custodia | Soporte |
|---|---|
| Primaria | KeePassXC del operador (mismo entry que la passphrase Borg, etiquetado "borg-offsite-credentials"). |
| Secundaria | Vaultwarden externo / Bitwarden cloud, mismo patrón que la passphrase. |

**Verificación periódica** (trimestral, §6.1 del playbook): rotar la app key (regenerar en B2/Storj console), actualizar `rclone.conf` en la Pi, confirmar que el siguiente `rclone sync` funciona. Una credencial caducada que falla solo durante el DR es la peor sorpresa posible.

**Si se pierde**: si la Pi sigue viva, el operador puede generar una credencial nueva desde la propia consola de B2 (con su login web) y seguir adelante. Si la Pi **no** existe ya y el login web del proveedor offsite tampoco está disponible (ej. el email asociado se perdió), entonces el repo offsite es inaccesible aunque exista físicamente. El único antídoto: 2FA del proveedor cloud bien custodiado (TOTP en KeePassXC, código de recuperación en sobre).

### 2.4. Diagrama mental: las tres piezas y lo que reconstruyen

```
   ┌───────────────────────────────┐         ┌───────────────────────────────┐
   │   1. Passphrase Borg          │         │   2. Repo ~/homelab/ remoto    │
   │   (papel + KeePassXC + cloud) │         │   (GitHub privado / Gitea)     │
   └───────────────┬───────────────┘         └───────────────┬───────────────┘
                   │                                          │
                   │  desbloquea                              │  define la
                   │                                          │  arquitectura
                   ▼                                          ▼
   ┌────────────────────────────────────────────────────────────────────────┐
   │   3. Credenciales offsite (B2/Storj)                                   │
   │              │                                                          │
   │              │  permiten descargar                                      │
   │              ▼                                                          │
   │       ┌────────────────────────┐                                        │
   │       │ Repo Borg en B2/Storj  │ ◀── rclone sync diario desde la Pi    │
   │       │ (cifrado, replicado)   │                                        │
   │       └───────────┬────────────┘                                        │
   │                   │                                                      │
   │                   │   borgmatic extract                                  │
   │                   ▼                                                      │
   │       ┌────────────────────────┐                                        │
   │       │ Datos de los servicios │                                        │
   │       │ (BD, configs, secrets) │                                        │
   │       └────────────────────────┘                                        │
   └────────────────────────────────────────────────────────────────────────┘
```

Si las tres piezas existen y son accesibles, el DR es viable. Si falta cualquiera, hay que asumir pérdida parcial documentada en §3.

---

## 3. Taxonomía de escenarios

No todo desastre exige el procedimiento maestro. La mayoría son fallos parciales con una ruta más corta. La tabla que sigue es el **árbol de decisión** del operador frente a un incidente:

| Escenario | Síntoma típico | Qué sigue vivo | Procedimiento | RTO típico |
|---|---|---|---|---|
| **A. microSD muere, Pi viva** | LEDs anómalos, no bootea, `dd if=...` lee bloques rotos. Hardware Pi5 OK. Discos OK. | Pi5, hd2t, hd5t, red doméstica | §6 — clonado microSD recientemente preparado, o reflasheo limpio + replay fases 1-2 + restore borg parcial de `/etc/`. | 1-3 h con clónica; 4-8 h sin ella. |
| **B. Pi5 muere (HW), microSD intacta** | La Pi no enciende (LEDs muertos), pero la microSD lee bien en otro lector. Discos OK. | microSD, hd2t, hd5t, red | Comprar Pi5 nueva → insertar microSD → arrancar. **No es DR pleno**, es swap de hardware. | 0.5 h efectivos + plazo de envío del Pi (3-7 días). |
| **C. `hd2t` falla** | `dmesg` reporta I/O errors; `mount` falla; SMART en estado WARN/FAIL. hd5t y Pi OK. | Pi5, microSD, hd5t. **Datos críticos PERDIDOS hasta restore**. | §6 — disco nuevo, particionar/etiquetar, restaurar `/mnt/hd2t/services/` y BD desde Borg (idealmente desde el propio hd2t si solo está degradado, si no, desde offsite). | 4-12 h según volumen y velocidad de I/O. |
| **D. `hd5t` falla** | Idéntico a C pero en hd5t. Stash inaccesible. | Pi5, microSD, hd2t (con Borg intacto). | §6 — disco nuevo. **Stash multimedia se pierde** salvo que el operador tenga origen externo (otros NAS, descargas re-obtenibles). El homelab sigue funcionando sin Stash. | 1-2 h para remontar; rehidratación de contenido es separada y no entra en RTO. |
| **E. Repo Borg local corrupto** | `borg check --verify-data` mensual reporta corrupción ([`../07-backups/01-estrategia-backup.md`](../07-backups/01-estrategia-backup.md) §12). hd2t en general OK. | Todo lo demás, incluyendo hd2t y servicios. | §6 — parar timers Borgmatic, `rclone sync` desde B2 a `/mnt/hd2t/backups/borg-restored/`, validar `borg check`, swap, reactivar timers. | 2-6 h según tamaño del repo y banda ancha. |
| **F. Compromiso de seguridad** | Auditoría detecta acceso no autorizado, ransomware, exfil. Indeterminado qué se ha tocado. | Indeterminado: hardware OK pero ningún dato es de fiar. | §6 — **wipe total** (incluido microSD), restore desde el snapshot Borg **anterior** al compromiso (puede ser de hace días/semanas), rotación completa de credenciales (§6.6). | 12-24 h + análisis forense. |
| **G. Pérdida total** | Incendio, inundación, robo. Pi y discos perdidos físicamente. | Solo: passphrase Borg + repo `~/homelab/` remoto + credenciales offsite (las tres piezas §2). | §4 — procedimiento maestro completo. | 1-3 días (envío hardware + descarga offsite) + 6-12 h efectivas. |
| **H. Borrado accidental de un volumen** | El operador `docker volume rm` o `rm -rf` algo que no debía. Solo afecta a un servicio. | Todo: hardware, repo, otros servicios. | §6 — `borgmatic restore --database` o `borgmatic extract --path`. **No es DR pleno**. | 0.5-2 h. |

> **Decisión rápida**: si el operador tiene dudas sobre qué escenario aplica, ir a §4 (procedimiento maestro). El maestro es un **superconjunto** de los demás: incluye comprobaciones que en escenarios parciales se saltan, pero no daña el sistema. La pérdida es de tiempo, no de datos.

---

## 4. Procedimiento maestro: pérdida total (escenario G)

Este es el procedimiento de referencia. Asume: la Pi fue destruida, ambos discos se perdieron, el operador solo conserva las tres piezas críticas (§2). Es el **escenario más estricto**; los demás son recortes de éste.

### 4.1. Triage inicial (primeros 30 min, sin tocar hardware todavía)

Antes de abrir un solo terminal:

1. **Confirmar el diagnóstico**: ¿realmente la Pi es irrecuperable? Foto, intentar arranque, escuchar fuente. Documentar el síntoma: si es seguridad (compromiso), el procedimiento cambia (§6.6).
2. **Verificar las tres piezas críticas (§2)**: passphrase legible, repo `~/homelab/` accesible desde otro equipo, credenciales offsite válidas (login web a B2 / Storj, listar el bucket).
3. **Crear bitácora del incidente**: archivo nuevo `~/homelab/operations/dr-incidents/<YYYY-MM-DD>-<corto>.md` con la siguiente plantilla:

   ```markdown
   # DR Incident — YYYY-MM-DD — <título corto>

   ## Síntoma
   <qué pasó>

   ## Escenario aplicable
   <A-H según §3 de disaster-recovery.md>

   ## Inventario superviviente
   - Pi: <sí/no>
   - hd2t: <sí/no/degradado>
   - hd5t: <sí/no/degradado>
   - microSD: <sí/no>
   - Red doméstica: <sí/no/parcial>
   - Tres piezas (§2): passphrase <sí/no>, repo `~/homelab/` <sí/no>, offsite <sí/no>

   ## Timeline
   YYYY-MM-DD HH:MM — <evento>
   ...
   ```

4. **Pedir hardware** si procede (Pi 5 + microSD + accesorios; en el peor caso también discos nuevos). Mientras llega, el operador se concentra en preparar las piezas digitales.
5. **Si hay servicios críticos que el operador necesita ya** (Vaultwarden para passwords, Bookstack para algún manual urgente): considerar levantar un **subset mínimo** en una máquina de tránsito (laptop con Docker). Procedimiento en §4.11 ("recovery acelerada parcial").

### 4.2. Preparación de la máquina de tránsito (mientras llega el hardware nuevo)

Una vez confirmado que el offsite es accesible, **adelantar trabajo** desde un portátil potente:

```bash
# En el portátil (Linux/Mac/WSL2), no en la Pi (no existe todavía).
mkdir -p ~/dr-recovery
cd ~/dr-recovery

# 1. Clonar el repo de definición.
git clone git@github.com:<operador>/homelab-private.git homelab/
ls homelab/   # debe contener stacks/, docs/, operations/, etc.

# 2. Instalar herramientas mínimas localmente.
sudo apt install -y borgbackup rclone   # o equivalente Mac/Win.

# 3. Configurar rclone con las credenciales de B2 (de KeePassXC).
mkdir -p ~/.config/rclone
cat > ~/.config/rclone/rclone.conf <<EOF
[b2-homelab]
type = b2
account = <KeyID-de-KeePassXC>
key = <ApplicationKey-de-KeePassXC>
EOF
chmod 600 ~/.config/rclone/rclone.conf

# 4. Verificar acceso al bucket sin descargar nada todavía.
rclone ls b2-homelab:homelab-borg/ | head -20
# Debe listar blobs Borg (data/, index.<n>, hints.<n>, README, config).

# 5. Iniciar la descarga (puede tardar horas; en background si se puede).
mkdir -p ~/dr-recovery/borg-repo/
rclone sync b2-homelab:homelab-borg/ ~/dr-recovery/borg-repo/ \
       --progress --transfers 8 --checkers 16
```

> **Por qué adelantar la descarga**: el cuello de botella suele ser la conexión doméstica (50-200 GB ÷ 100 Mbps simétricos ≈ 1-4 h). Hacerlo en paralelo a la espera del Pi reduce el wall-clock total a la mitad. Cuando llegue la Pi, el repo ya estará en el portátil y se transfiere por LAN gigabit a la nueva `hd2t`.

```bash
# 6. (Opcional pero recomendado) Validar el repo descargado ANTES de tocar hardware.
export BORG_PASSPHRASE='<la-passphrase-de-las-custodias>'
borg check --verbose ~/dr-recovery/borg-repo/
borg list ~/dr-recovery/borg-repo/   # debe listar archivos por fecha.
borg info ~/dr-recovery/borg-repo/
unset BORG_PASSPHRASE
```

Si `borg check` falla en la copia descargada → escenario E también (corrupción del offsite); ver §6.5. Si pasa → seguir.

### 4.3. Hardware nuevo: bootstrap básico

Cuando llega la Pi 5 nueva (y discos nuevos si aplica):

1. **Conexiones físicas**: seguir [`../00-hardware/02-esquema-conexiones.md`](../00-hardware/02-esquema-conexiones.md) — Pi → router por Ethernet, fuente 27 W. **NO** conectar todavía los discos hasta haberlos preparado en el siguiente paso.
2. **Preparar discos**: si son nuevos, particionar y etiquetar siguiendo [`../00-hardware/03-preparacion-discos.md`](../00-hardware/03-preparacion-discos.md) **desde otra máquina** (más rápido y seguro que en la Pi). Etiquetas exactas: `hd5t` y `hd2t` (case-sensitive). Saltarse este paso = `fstab` no monta y la Pi se queda colgada.
3. **Flashear microSD** con Raspberry Pi OS Lite 64-bit, siguiendo [`../01-sistema/01-instalacion-os.md`](../01-sistema/01-instalacion-os.md). Personalización idéntica al despliegue original: hostname (`homelab` o el que el operador eligió), usuario `homelab`, claves SSH del operador.
4. **Primer arranque sin discos**: insertar microSD, conectar fuente. Esperar 1-2 min. Localizar IP en el router. SSH con `ssh homelab@<ip>` debe funcionar.

Llegados aquí, hay un **homelab vacío**: Pi viva, OS limpio, sin discos. El operador se autentica con sus claves SSH originales (recuperadas del portátil donde se generaron).

### 4.4. Re-aplicar fases 0-2 (sistema, discos, Docker)

Cada doc de fase es idempotente. Con el repo `~/homelab/` clonado en el portátil, el operador tiene los pasos exactos:

```bash
# En la Pi, vía SSH desde el portátil.

# 1. Fase 1 — configuración inicial.
#    Seguir docs/01-sistema/02-configuracion-inicial.md íntegro.
#    Hostname, timezone, swap en hd2t (todavía no enchufado: dejarlo y volver),
#    actualización del sistema.
sudo apt update && sudo apt full-upgrade -y
sudo timedatectl set-timezone Europe/Madrid

# 2. Fase 1 — seguridad base.
#    docs/01-sistema/03-seguridad-base.md íntegro.
#    UFW, fail2ban, deshabilitar login con password, unattended-upgrades.

# 3. Conectar AHORA los discos (preparados en §4.3.2).
#    Verificar que se montan automáticamente.
sudo blkid                          # confirma LABEL=hd5t y LABEL=hd2t.
sudo cp ~/homelab/system/fstab-hd5t-hd2t.fragment >> /etc/fstab   # ya commiteado en el repo.
sudo systemctl daemon-reload
sudo mount -a
mount | grep -E '/mnt/hd[25]t'      # ambos montados.

# 4. Fase 1 — estructura de directorios.
#    docs/01-sistema/04-estructura-directorios.md íntegro.
#    Crea /mnt/hd2t/services/, /mnt/hd2t/backups/, /mnt/hd2t/sync/, etc.
sudo bash ~/homelab/scripts/setup-directories.sh   # idempotente.

# 5. Fase 2 — Docker.
#    docs/02-docker/01-instalacion-docker.md íntegro.
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker homelab
newgrp docker

# 6. Crear la red Docker compartida (compose.yml de cada stack la reutilizará).
docker network create homelab || true
```

Estado al final: la Pi está en el mismo punto que tras un despliegue greenfield de las fases 0-2. Sin servicios todavía.

### 4.5. Restaurar el repo Borg en `/mnt/hd2t/backups/borg/`

Hay dos rutas:

**Ruta A — desde el portátil (rápido, LAN gigabit)**:

```bash
# Desde el portátil:
sudo install -d -m 700 /tmp/borg-staging
sudo rsync -aHAX --info=progress2 \
     ~/dr-recovery/borg-repo/ \
     homelab@<ip-pi>:/tmp/borg-staging/

# En la Pi:
sudo install -d -m 700 -o root -g root /mnt/hd2t/backups/borg
sudo mv /tmp/borg-staging/* /mnt/hd2t/backups/borg/
sudo chown -R root:root /mnt/hd2t/backups/borg
sudo find /mnt/hd2t/backups/borg -type d -exec chmod 700 {} +
sudo find /mnt/hd2t/backups/borg -type f -exec chmod 600 {} +
```

**Ruta B — directamente desde B2 a la Pi**:

```bash
# En la Pi:
sudo apt install -y rclone
sudo install -d -m 700 -o root -g root /etc/rclone
sudo install -m 600 ~/homelab/secrets-templates/rclone.conf /etc/rclone/rclone.conf
# Editar /etc/rclone/rclone.conf con las credenciales de KeePassXC.

sudo install -d -m 700 -o root -g root /mnt/hd2t/backups/borg
sudo rclone --config /etc/rclone/rclone.conf sync \
     b2-homelab:homelab-borg/ /mnt/hd2t/backups/borg/ \
     --progress --transfers 8
```

Validar:

```bash
sudo apt install -y borgbackup borgmatic
sudo install -d -m 700 -o root -g root /etc/borgmatic
echo '<passphrase>' | sudo tee /etc/borgmatic/.passphrase >/dev/null
sudo chmod 600 /etc/borgmatic/.passphrase
export BORG_PASSCOMMAND='cat /etc/borgmatic/.passphrase'
sudo -E borg check --verbose /mnt/hd2t/backups/borg
sudo -E borg list /mnt/hd2t/backups/borg | tail -5
```

Si `borg check` falla aquí pero pasó en §4.2 → I/O error en `hd2t` durante la copia; reintentar con `rsync -c` para verificar checksums, o rebuscar en el portátil.

### 4.6. Restaurar config de Borgmatic y planificar timers (sin activarlos todavía)

```bash
sudo install -m 600 ~/homelab/operations/borgmatic.config.yaml /etc/borgmatic/config.yaml
sudo borgmatic config validate
# OK — pero NO activar timers aún.

# Confirmar listado:
sudo borgmatic list --last 3
# Debe mostrar el último archivo "homelab-pi5-YYYY-MM-DDTHH:MM:SS-...".
ARCH=$(sudo borgmatic list --short | tail -1)
echo "Archivo más reciente: $ARCH"
```

Anotar `$ARCH` en la bitácora del incidente. Es el snapshot que se usará para extraer en §4.7.

### 4.7. Restauración por fases (orden estricto)

El orden canónico es el de [`../07-backups/03-backup-docker-volumes.md`](../07-backups/03-backup-docker-volumes.md) §7.1. Resumen aplicado:

#### 4.7.1. Secrets, configs base, `/etc` selectivo

```bash
# Restaurar SOLO partes seguras de /etc (NO /etc completo: sustituye lo recién instalado).
sudo borgmatic extract --archive "$ARCH" \
     --path 'etc/ssh' 'etc/fstab' 'etc/ufw' 'etc/fail2ban' 'etc/borgmatic' 'etc/rclone' \
     --destination /

# Restaurar todos los /mnt/hd2t/services/<svc>/ con sus secrets/, configs/, volúmenes.
sudo borgmatic extract --archive "$ARCH" \
     --path 'mnt/hd2t/services' --destination /

# Restaurar /mnt/hd2t/sync (datos de Syncthing y similares).
sudo borgmatic extract --archive "$ARCH" \
     --path 'mnt/hd2t/sync' --destination /
```

> **Nota sobre `/etc/ssh`**: si las claves de host se restauran, los clientes que ya conocían la huella SSH del homelab original siguen funcionando sin warning. Si se prefiere generar nuevas (más limpio), saltar `etc/ssh` aquí y dejar que el OS genere claves nuevas; el operador tendrá que `ssh-keygen -R <ip>` en sus clientes.

#### 4.7.2. Red y DNS (Pi-hole, Unbound, Caddy)

```bash
cd ~/homelab/stacks/dns
docker compose --env-file /mnt/hd2t/services/dns/.env up -d
docker compose --env-file /mnt/hd2t/services/dns/.env ps
# pi-hole, unbound deben estar 'Up'.

# Validar resolución desde el host:
nslookup jellyfin.lan 192.168.1.2   # IP macvlan de Pi-hole.

cd ~/homelab/stacks/proxy
docker compose --env-file /mnt/hd2t/services/proxy/.env up -d
docker logs caddy --tail 50  # debe arrancar sin errores de cert.
```

> **Si Pi-hole no resuelve**: revisar que la red `macvlan` se ha creado de nuevo (el host se reinstaló). Reaplicar [`../03-red/01-macvlan.md`](../03-red/01-macvlan.md). Es el primer punto de fallo típico en un DR.

#### 4.7.3. Identidad (Authelia)

```bash
cd ~/homelab/stacks/auth
docker compose --env-file /mnt/hd2t/services/auth/.env up -d
docker logs authelia --tail 50
# Validar acceso a https://auth.lan (cert vía Caddy CA local).
```

Authelia usa SQLite por defecto; sus secrets están en `/mnt/hd2t/services/auth/secrets/` ya restaurados en §4.7.1.

#### 4.7.4. Bases de datos (MariaDB, PostgreSQL)

```bash
# Levantar contenedores de BD para que acepten dumps.
cd ~/homelab/stacks/databases
docker compose --env-file /mnt/hd2t/services/databases/.env up -d
sleep 30   # esperar a que MariaDB y Postgres acepten conexiones.

# Restaurar dumps con borgmatic (declarative restore):
sudo borgmatic restore --archive "$ARCH" --database nextcloud_db
sudo borgmatic restore --archive "$ARCH" --database bookstack_db
sudo borgmatic restore --archive "$ARCH" --database paperless_db
sudo borgmatic restore --archive "$ARCH" --database mealie_db
# El procedimiento exacto, dump por dump, está en
# docs/07-backups/03-backup-docker-volumes.md §4.
```

> **Patrón canónico**: `borgmatic restore --database <name>` reproduce el dump al servicio destino correctamente. **No** usar `borg extract` + `psql` a mano salvo que el dump no fuera declarativo (raro en este homelab).

#### 4.7.5. Almacenamiento (Nextcloud, Samba, Syncthing, MinIO)

```bash
cd ~/homelab/stacks/storage
docker compose --env-file /mnt/hd2t/services/storage/.env up -d nextcloud
docker logs nextcloud --tail 100   # busca 'Initialization done' o equivalente.

# Reparar permisos de www-data dentro de Nextcloud si los UIDs de host cambiaron:
docker exec -u www-data nextcloud php occ maintenance:repair --include-expensive
docker exec -u www-data nextcloud php occ files:scan --all

# Resto de servicios del stack:
docker compose --env-file /mnt/hd2t/services/storage/.env up -d
```

#### 4.7.6. Verificación intermedia: el "núcleo" funciona

Antes de levantar el resto, **confirmar** que con esto solo el operador tiene:

```bash
# DNS interno:
nslookup vaultwarden.lan 192.168.1.2

# Caddy responde con cert local:
curl -k https://vaultwarden.lan/alive

# Authelia portal accesible:
curl -k -I https://auth.lan

# Nextcloud levanta y conoce a su BD:
docker exec -u www-data nextcloud php occ status
```

Si todo OK → el operador ya puede acceder a Vaultwarden, Authelia, Nextcloud desde su navegador (importando la CA de Caddy si no estaba). Lo crítico está restaurado.

#### 4.7.7. Resto de servicios

Stack por stack, `docker compose up -d`, validar logs y, si aplica, UI:

```bash
for STACK in vaultwarden multimedia descargas productividad domotica dashboards monitorizacion; do
  cd ~/homelab/stacks/$STACK
  docker compose --env-file /mnt/hd2t/services/$STACK/.env up -d
  echo "=== $STACK ==="
  docker compose --env-file /mnt/hd2t/services/$STACK/.env ps
  sleep 10
done
```

#### 4.7.8. Validación post-stack

```bash
# Inventario de todo lo que está corriendo:
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'

# Cualquier contenedor en Restarting o Exited → revisar:
docker ps -a --filter 'status=restarting' --filter 'status=exited'
docker logs <name> --tail 100
```

### 4.8. Restaurar Tailscale (red mesh externa)

```bash
# Reinstalar el cliente y volver a autenticarse.
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --hostname=homelab --ssh
# Confirma con un código en la consola web Tailscale.

# Verificar:
tailscale status --json | jq .Self.Online
# true.
```

Si la Pi original tenía un nodo viejo registrado, **darlo de baja** desde el panel admin de Tailscale (`tailscale status --json` documenta los nodos antiguos según la nota en [`../03-red/05-tailscale.md`](../03-red/05-tailscale.md) §N).

### 4.9. Recuperar `~/homelab/` operativo en la propia Pi

```bash
git clone git@github.com:<operador>/homelab-private.git ~/homelab
cd ~/homelab
git status   # debería estar limpio.
git log --oneline -5
```

A partir de aquí, los logs operativos (`maintenance.log`, `restore-tests.log`, `dr-incidents/`) ya forman parte del repo y son consultables.

### 4.10. Reactivar timers de mantenimiento (último paso antes de declarar OK)

```bash
# Borgmatic (los tres):
sudo systemctl enable --now borgmatic-daily.timer borgmatic-weekly.timer borgmatic-monthly.timer

# Watchtower y otros se activaron implícitamente al levantar sus stacks.
# Verificar:
systemctl list-timers borgmatic-* --all
docker ps --filter name=watchtower
```

> **No reactivar antes**: si Borgmatic hubiera arrancado en mitad de la restauración, podría haber rotado el snapshot bueno. Reactivar solo cuando el resto está OK.

### 4.11. (Opcional) Recovery acelerada parcial — solo Vaultwarden y Bookstack

Si en §4.1 el operador necesita Vaultwarden urgente (no puede esperar 12 h), se puede levantar **solo** Vaultwarden + dependencias mínimas en el portátil de tránsito:

```bash
# En el portátil con Docker:
mkdir -p ~/dr-tmp/vaultwarden && cd ~/dr-tmp/vaultwarden

# Extraer solo el volumen de Vaultwarden del Borg local descargado.
export BORG_PASSPHRASE='<passphrase>'
borg extract --strip-components 5 \
  ~/dr-recovery/borg-repo::"$ARCH" \
  mnt/hd2t/services/vaultwarden/data
unset BORG_PASSPHRASE

# Compose mínimo (sin Caddy/Authelia, solo Vaultwarden expuesto en localhost):
cat > docker-compose.yml <<'EOF'
services:
  vaultwarden:
    image: vaultwarden/server:latest
    volumes:
      - ./data:/data
    ports:
      - "127.0.0.1:8080:80"
    environment:
      SIGNUPS_ALLOWED: "false"
      ROCKET_ADDRESS: "0.0.0.0"
EOF

docker compose up -d
# Acceder en http://127.0.0.1:8080 con las credenciales del operador.
# Suficiente para recuperar passwords mientras se restaura el homelab.
```

> **Importante**: este modo es **read-only de facto** por convención. Cualquier cambio aquí no se replica al homelab final. Detener el contenedor (`docker compose down`) en cuanto el homelab principal esté de vuelta. **No** dejarlo activo en paralelo: divergerían las BD.

### 4.12. Cierre del incidente

1. Smoke test L3 ad-hoc del servicio que se restauró ([`../07-backups/03-backup-docker-volumes.md`](../07-backups/03-backup-docker-volumes.md) §6.5 con MariaDB de Nextcloud o equivalente). Confirma que los dumps cargados son funcionalmente correctos, no solo consultables.
2. Cerrar `~/homelab/operations/dr-incidents/<YYYY-MM-DD>-<corto>.md` con timeline completa, **lecciones aprendidas** y eventuales mejoras al playbook.
3. Anotar en `maintenance.log`:
   ```text
   2026-MM-DD · ad-hoc · DR completo escenario G — Pi+discos perdidos, restaurado desde offsite. RTO 9h efectivas. Detalle en operations/dr-incidents/2026-MM-DD-fuego-armario.md · resuelto, monitor 30d
   ```
4. **Drill mode opcional**: si fue un drill (no un desastre real), el operador anota en `restore-tests.log` con cadencia `dr-drill` y NO entra en `dr-incidents/`.
5. Commit y push:
   ```bash
   git -C ~/homelab add operations/
   git -C ~/homelab commit -m "ops: dr <YYYY-MM-DD> <escenario>"
   git -C ~/homelab push
   ```

---

## 5. Drill anual de "Pi muerta"

Una vez al año, idealmente coincidiendo con la sesión anual del playbook periódico ([`./01-mantenimiento-periodico.md`](./01-mantenimiento-periodico.md) §7), el operador ejecuta una versión **simulada y no destructiva** del procedimiento maestro. Objetivo: confirmar que las tres piezas (§2) son realmente recuperables y que el procedimiento sigue siendo correcto.

### 5.1. Modalidad sin tocar producción

Recomendada — el homelab sigue corriendo durante el drill:

1. Verificar **acceso a las tres piezas** desde el portátil (passphrase, repo `~/homelab/`, credenciales B2). Cronómetro: ¿se tarda < 5 min? Si sí → custodias bien organizadas; si tarda más → revisar §2.
2. Descargar el repo Borg al portátil con `rclone copy` (no `sync`: copy no borra nada en destino) a un directorio temporal.
3. Ejecutar `borg check --verify-data` sobre la copia local. Esperado: `Archive consistency check complete, no problems found.`
4. Hacer `borg extract --dry-run` del último archive sobre un directorio temporal: confirma que la passphrase abre el repo y que los blobs son legibles.
5. Borrar el directorio temporal y la copia local.
6. Anotar en `~/homelab/operations/restore-tests.log`:
   ```text
   2026-12-15 | dr-drill | offsite-only | OK | passphrase OK, rclone OK, borg check OK, extract dry-run OK | tiempo wall-clock 4h (descarga) + 25min trabajo
   ```

### 5.2. Modalidad con hardware secundario (recomendada cada 2-3 años)

Más exhaustiva, requiere una segunda Pi (o SBC equivalente, o VM ARM) que se pueda dedicar al drill durante 1-2 días:

1. Repetir §4.3-§4.7 sobre el hardware de drill, **sin** tocar la Pi de producción.
2. Confirmar que al final del drill se obtiene un homelab funcional paralelo (con secrets propios para no chocar con producción si comparten LAN).
3. **Apagar y limpiar** el hardware de drill al terminar: `sudo wipe /dev/mmcblk0` o equivalente, devolver la Pi de drill a estante.

> **Por qué ensayar con hardware separado**: el drill no destructivo (§5.1) confirma que **los datos** son recuperables. El drill con hardware (§5.2) confirma además que **el procedimiento entero** funciona, incluyendo pasos manuales fáciles de olvidar (etiquetas de discos, network macvlan, certificados Caddy). Las dos primeras veces que se hace, el operador descubre invariablemente al menos un paso mal documentado.

---

## 6. Procedimientos por escenario

Cada apartado siguiente es un sub-procedimiento del maestro (§4) recortado para escenarios parciales.

### 6.1. Escenario A — microSD muere, Pi y discos vivos

**Síntoma**: Pi no bootea, LEDs anormales, microSD ilegible en otro lector. Discos OK.

**Procedimiento**:

1. **Si hay clónica reciente** (§7 de este doc): insertar la microSD clonada, arrancar. La Pi queda en el estado del clonado (probablemente días/semanas viejo). Aplicar `apt update && apt full-upgrade -y` para alcanzar parches recientes. Verificar servicios: `docker ps`. **Tiempo total: ~1 h**.
2. **Sin clónica**:
   - Reflashear microSD nueva siguiendo [`../01-sistema/01-instalacion-os.md`](../01-sistema/01-instalacion-os.md).
   - Bootear, configurar SSH, replay [`../01-sistema/02-configuracion-inicial.md`](../01-sistema/02-configuracion-inicial.md), [`../01-sistema/03-seguridad-base.md`](../01-sistema/03-seguridad-base.md).
   - Editar `/etc/fstab` con las entradas de `hd2t` y `hd5t` (recuperadas de `~/homelab/system/fstab-hd5t-hd2t.fragment`). Reboot. `mount -a`.
   - Reinstalar Docker ([`../02-docker/01-instalacion-docker.md`](../02-docker/01-instalacion-docker.md)).
   - Restaurar `/etc` selectivo desde el repo Borg local (que sigue intacto en `hd2t`):
     ```bash
     sudo borgmatic extract --archive "$(sudo borgmatic list --short | tail -1)" \
          --path 'etc/ssh' 'etc/fstab' 'etc/ufw' 'etc/fail2ban' --destination /
     ```
   - Levantar stacks en orden de §4.7. Como los volúmenes en `hd2t` están intactos, el levantado es directo: solo `docker compose up -d`. **Tiempo total: 4-8 h**.

### 6.2. Escenario B — Pi5 muere (HW), microSD intacta

**Síntoma**: Pi5 no enciende. Test con fuente alternativa confirma que es la propia Pi. microSD lee bien en otro lector.

**Procedimiento**:

1. Comprar Pi 5 nueva.
2. Cuando llegue: insertar la microSD original. Conectar discos, fuente, red. Encender.
3. La Pi nueva arranca con la identidad y configuración de la antigua. SSH sigue funcionando con las claves del operador.
4. Validar:
   ```bash
   docker ps                       # todos los stacks Up.
   sudo borgmatic list --last 3   # último backup reciente.
   ```
5. **Si el backup más reciente** es de antes del fallo (algunas horas antes), ejecutar uno manual: `sudo borgmatic --verbosity 1 create`.
6. Anotar en `dr-incidents/`: incidente de hardware, sin pérdida de datos.

> **Tiempo total**: 30 min de operación efectiva + plazo de envío del Pi nuevo (3-7 días). Es el escenario más benigno.

### 6.3. Escenario C — `hd2t` falla

**Síntoma**: I/O errors en `dmesg` apuntando a `/dev/sd<X>` de hd2t, `mount` falla, SMART en WARN/FAIL.

**Procedimiento**:

1. **Primer paso defensivo**: detener Borgmatic para que **no** sobreescriba el snapshot bueno con un `dumps/` vacío:
   ```bash
   sudo systemctl stop borgmatic-daily.timer borgmatic-weekly.timer borgmatic-monthly.timer
   sudo systemctl stop borgmatic.service 2>/dev/null
   ```
2. **Comprar disco nuevo** equivalente o mejor (≥ 2 TB).
3. Si el disco viejo aún está parcialmente legible: hacer `dd_rescue` o `ddrescue` a un fichero imagen en otro disco temporal, **antes** de descartarlo:
   ```bash
   sudo apt install -y gddrescue
   sudo ddrescue /dev/sd<X> /mnt/<otro-disco>/hd2t-rescue.img /mnt/<otro-disco>/hd2t-rescue.log
   ```
   Esto puede recuperar particiones aunque el disco esté degradado, sin estresarlo más.
4. Reemplazar disco físico, particionar y etiquetar como `hd2t` siguiendo [`../00-hardware/03-preparacion-discos.md`](../00-hardware/03-preparacion-discos.md). El `fstab` no cambia (LABEL es estable).
5. Reaplicar [`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) (idempotente) sobre el disco nuevo.
6. **Restaurar el repo Borg desde offsite** (el local ya no existe, vivía en hd2t):
   ```bash
   sudo rclone --config /etc/rclone/rclone.conf sync \
        b2-homelab:homelab-borg/ /mnt/hd2t/backups/borg/ --progress
   ```
7. Continuar con §4.7 (restauración por fases). Los servicios estaban definidos en `~/homelab/` y restaurarán sus datos al `/mnt/hd2t/services/<svc>/` ya recreado.
8. Reactivar timers Borgmatic al final.

> **Tiempo total**: 4-12 h según volumen y velocidad I/O. La descarga de B2 domina si la conexión es < 100 Mbps.

### 6.4. Escenario D — `hd5t` falla

**Síntoma**: idéntico a C pero en hd5t. Stash inaccesible.

**Procedimiento**:

1. Detener Stash:
   ```bash
   cd ~/homelab/stacks/multimedia
   docker compose --env-file /mnt/hd2t/services/multimedia/.env stop stash
   ```
2. Reemplazar disco físico, particionar y etiquetar como `hd5t`.
3. Reaplicar la sección correspondiente de [`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) sobre hd5t.
4. **Stash multimedia no está en Borg** por diseño (volumen demasiado grande, no cabe en offsite). Hay tres rutas:
   - **Re-importar contenido** desde origen externo si lo hay (otros NAS, descargas re-obtenibles, copia local en otro disco grande).
   - **Aceptar la pérdida** y empezar Stash con biblioteca vacía. Los metadatos (scrapers) están en `/mnt/hd2t/services/stash/` y sí estaban en Borg → al levantar Stash, conoce las bibliotecas pero no los ficheros. Stash mostrará "missing files" hasta que se re-importen.
   - **Restaurar desde un offsite alternativo** específico de hd5t si el operador eligió pagar por replicar también el contenido (no recomendado por defecto: caro y poco frecuente; ver [`../09-multimedia/05-stash.md`](../09-multimedia/05-stash.md)).
5. Levantar Stash:
   ```bash
   docker compose --env-file /mnt/hd2t/services/multimedia/.env up -d stash
   ```
6. El homelab funciona; Stash queda en estado "biblioteca degradada" hasta rehidratarse.

### 6.5. Escenario E — repo Borg corrupto

**Síntoma**: `borg check --verify-data` (mensual o ad-hoc) reporta `Archive metadata checksum mismatch` o similar. El resto del homelab está OK.

**Procedimiento**:

1. **Detener Borgmatic** (igual que en escenario C, primer paso): timers + servicio. Crítico: no permitir que se sobreescriba el repo o que la nueva noche rote el snapshot bueno.
2. **Diagnóstico**:
   ```bash
   sudo borg check --verify-data --verbose /mnt/hd2t/backups/borg 2>&1 | tee /tmp/borg-check.log
   ```
   Identificar qué archivo concreto falla.
3. **Comparar con el offsite**:
   ```bash
   sudo install -d -m 700 /mnt/hd2t/backups/borg-restored
   sudo rclone --config /etc/rclone/rclone.conf sync \
        b2-homelab:homelab-borg/ /mnt/hd2t/backups/borg-restored/ --progress
   sudo borg check --verify-data /mnt/hd2t/backups/borg-restored
   ```
4. **Si el offsite está OK**: swap.
   ```bash
   sudo systemctl stop borgmatic-daily.timer borgmatic-weekly.timer borgmatic-monthly.timer
   sudo mv /mnt/hd2t/backups/borg /mnt/hd2t/backups/borg-corrupted-$(date +%F)
   sudo mv /mnt/hd2t/backups/borg-restored /mnt/hd2t/backups/borg
   # Validar uno final:
   sudo borg list /mnt/hd2t/backups/borg | tail -3
   sudo systemctl start borgmatic-daily.timer borgmatic-weekly.timer borgmatic-monthly.timer
   ```
5. **Investigar la causa raíz**: bit-rot en `hd2t` (revisar SMART, especialmente `Reallocated_Sector_Ct` y `Current_Pending_Sector`), write error silencioso, sistema de ficheros corrupto. Detalle en [`../07-backups/01-estrategia-backup.md`](../07-backups/01-estrategia-backup.md) §12.
6. **Si el offsite también está corrupto**: escenario crítico. Última línea de defensa: snapshots históricos del proveedor cloud (Backblaze B2 con Object Lock o Storj con versionado tienen historiales recuperables). Ver §6.5.1.
7. Conservar el `borg-corrupted-YYYY-MM-DD/` ≥ 30 días por si hay archivos legibles que rescatar manualmente con `borg extract --no-cache-sync`.

#### 6.5.1. Si el offsite también falló

Sin offsite limpio, opciones:

- **Object Lock de B2**: si está activado (recomendado en [`../07-backups/01-estrategia-backup.md`](../07-backups/01-estrategia-backup.md) §6.3), permite recuperar versiones anteriores de blobs durante el periodo de retención (típicamente 30 días). Listar versiones:
  ```bash
  rclone --config <conf> backend versions b2:homelab-borg/data/0/000001
  rclone --config <conf> backend listVersions b2:homelab-borg/
  ```
- **Snapshots de Storj**: análogos pero con sintaxis distinta.
- **Recuperación parcial desde fuentes no-Borg**: ficheros sueltos en Syncthing del cliente del operador (los que se sincronizan a su laptop), Nextcloud sincronizado a desktop, exports manuales. Es subóptimo pero limita la pérdida.

Anotar en `dr-incidents/` con detalle: este escenario debe motivar revisión completa del modelo de amenaza y posiblemente añadir una **tercera copia** (otro proveedor cloud).

### 6.6. Escenario F — compromiso de seguridad

**Síntoma**: indicadores de intrusión: `last` muestra logins desconocidos, `sudo grep -r 'authorized_keys' /` revela claves no del operador, ransomware (ficheros cifrados con extensión rara), comportamiento anómalo persistente.

**Procedimiento defensivo (orden estricto)**:

1. **Aislamiento físico inmediato**: desconectar Ethernet de la Pi. **No** apagar todavía: el operador podría querer dump de memoria forense. Si no hay capacidades forenses, sí apagar.
2. **Comunicación**: dar de baja temporal de Tailscale el nodo `homelab` desde el panel admin. Cambiar passwords de cualquier servicio con login web exterior (B2, GitHub) **desde otro equipo confiable**.
3. **Definir el "punto previo al compromiso"**: cuando se detecta el ataque, los snapshots Borg de **antes** son confiables. El operador debe estimar la fecha del compromiso (por logs `auth.log`, `journalctl`, monitoreo Prometheus). Identificar el último snapshot **anterior** a esa fecha:
   ```bash
   sudo borgmatic list   # listar todos
   # Elegir uno claramente anterior al compromiso, no necesariamente el más reciente.
   ```
4. **Wipe total**:
   - microSD: `sudo wipe /dev/mmcblk0` o reflasheo sin reuse.
   - hd2t: `sudo wipe -k /dev/sd<X>` (mantener etiquetas/particiones requiere recrearlas; si hay duda, formatear de cero).
   - hd5t: idem.
5. Aplicar §4.3-§4.4 (bootstrap + fases 0-2) sobre hardware limpio.
6. Restaurar Borg **del snapshot pre-compromiso**, no el más reciente. Esto puede implicar pérdida de N días de datos.
7. **Rotación obligatoria de TODAS las credenciales**:
   - Todas las passwords de servicios (Pi-hole, Authelia, Vaultwarden internos, Nextcloud, Sonarr/Radarr, etc.).
   - Claves SSH del operador → regenerar y rotar `authorized_keys`.
   - **Passphrase de Borg**: cambiar con `borg key change-passphrase` y re-distribuir custodias. Crítico si se sospecha que el atacante pudo dumpear `/etc/borgmatic/.passphrase`.
   - **Application keys del offsite**: revocar e crear nuevas.
   - **Tokens de Tailscale**: rotar.
   - JWT/secrets de Authelia (`storage_encryption`, `jwt_secret`, `session_secret`): regenerar — implica logout global; documentar para los usuarios.
8. Continuar con §4.5-§4.10.
9. Análisis post-mortem en `dr-incidents/`: vector de entrada, IOCs, qué cambios al modelo de amenaza ([`../07-backups/01-estrategia-backup.md`](../07-backups/01-estrategia-backup.md) §6.4).

> **Si se detecta compromiso pero no se está seguro de la fecha**: por defecto, retroceder al snapshot **mensual** anterior (el `monthly` GFS), no a un `daily` próximo a la detección. La fecha real del compromiso puede ser anterior a lo que parece.

### 6.7. Escenario H — borrado accidental de un volumen / dato puntual

**Síntoma**: el operador hizo `docker volume rm`, `rm -rf` o equivalente sobre un volumen de servicio. Solo afecta a ese servicio.

**Procedimiento**:

1. **Detener el servicio inmediatamente** (si aún corre con datos parciales, sigue escribiendo y el daño se extiende):
   ```bash
   docker compose --env-file /mnt/hd2t/services/<stack>/.env stop <servicio>
   ```
2. Identificar el último snapshot bueno:
   ```bash
   sudo borgmatic list --last 5
   ```
3. Restaurar **solo el path afectado**:
   ```bash
   sudo borgmatic extract --archive "<archivo>" \
        --path "mnt/hd2t/services/<servicio>" \
        --destination /
   ```
4. Si era una BD, además cargar el dump:
   ```bash
   sudo borgmatic restore --archive "<archivo>" --database <nombre>
   ```
5. Levantar el servicio:
   ```bash
   docker compose --env-file /mnt/hd2t/services/<stack>/.env up -d <servicio>
   ```
6. Smoke test rápido (login, dato representativo).
7. Anotación en `maintenance.log` con cadencia `ad-hoc`.

> **Tiempo típico**: 30 min - 2 h. No requiere bitácora `dr-incidents/`; basta con `maintenance.log` y mención del path afectado.

---

## 7. Clonado periódico de la microSD

El desgaste de la microSD es inevitable y a veces falla súbitamente sin preaviso ([`../00-hardware/01-material-necesario.md`](../00-hardware/01-material-necesario.md) recomienda microSD A2 V30 de marca por esta razón). Tener una **clónica reciente** acelera el escenario A (microSD muere) de 4-8 h a ~1 h.

### 7.1. Cuándo crear la clónica

- **Anual** (sesión §7.1 del playbook periódico, [`./01-mantenimiento-periodico.md`](./01-mantenimiento-periodico.md) §7.1).
- **Tras cambios estructurales** en el OS (upgrade de Debian a la siguiente versión major, cambio mayor en `/etc/fstab`, instalación de drivers nuevos) — eventos raros, pero conviene refrescar.
- **Antes de experimentos arriesgados** (probar overclocking nuevo, reinstalar Docker, etc.): clonar primero, experimentar después. Es la mejor red de seguridad para "deshacer" cambios al sistema base.

### 7.2. Procedimiento de clonado

**Modalidad A — clonado en caliente (sin apagar la Pi)**:

```bash
# Desde otro equipo (laptop), por SSH al homelab. Asume la Pi viva y los discos disponibles.
# Crear la imagen en hd2t/backups/microsd/.
ssh homelab@<pi> 'sudo install -d -m 700 -o root -g root /mnt/hd2t/backups/microsd'

# Copiar bit a bit la microSD a una imagen en hd2t. La Pi sigue corriendo;
# el filesystem en uso puede generar inconsistencias menores (lo aceptamos).
ssh homelab@<pi> 'sudo dd if=/dev/mmcblk0 of=/mnt/hd2t/backups/microsd/backup-2026-12.img bs=4M status=progress conv=fsync'

# Comprimir para ahorrar espacio (microSD de 64 GB → ~4-8 GB tras compresión):
ssh homelab@<pi> 'sudo zstd --rm -19 -T0 /mnt/hd2t/backups/microsd/backup-2026-12.img'
ls -lh /mnt/hd2t/backups/microsd/
```

> **Inconsistencias del clonado en caliente**: el OS está escribiendo a la microSD durante el `dd` (logs, journals, sqlite de Docker). El resultado es **booteable** en >99% de los casos pero puede pedir `fsck` al primer arranque y ese arranque puede tardar varios minutos. Aceptable para DR.

**Modalidad B — clonado en frío (parando la Pi)**:

Más limpio pero requiere downtime. Procedimiento:

1. Apagar la Pi (`sudo shutdown -h now`).
2. Sacar la microSD, conectarla al portátil con un lector USB.
3. Desde el portátil:
   ```bash
   sudo dd if=/dev/sd<X> of=~/dr-recovery/microsd-backup-2026-12.img bs=4M status=progress conv=fsync
   sudo zstd --rm -19 -T0 ~/dr-recovery/microsd-backup-2026-12.img
   ```
4. Subir la imagen comprimida a `/mnt/hd2t/backups/microsd/` (vía rsync cuando se restaure servicio).
5. Re-insertar microSD, encender Pi.
6. Verificar arranque normal y `docker ps` antes de declarar OK.

> **Recomendación**: usar modalidad B una vez al año (sesión anual del playbook), modalidad A para snapshots intermedios entre sesiones anuales si se hacen cambios significativos.

### 7.3. Validación de la clónica

Una clónica que no se prueba puede no bootear cuando hace falta. **Antes de archivarla**:

```bash
# Desde otro lector (no la microSD viva), flashear una microSD de pruebas con la imagen:
sudo zstdcat /mnt/hd2t/backups/microsd/backup-2026-12.img.zst | \
     sudo dd of=/dev/sd<X> bs=4M status=progress conv=fsync

# Insertar esa microSD en otra Pi 5 de pruebas (o la misma con la original temporalmente fuera).
# Esperado: bootea, login SSH funciona, los discos no están conectados pero el OS sí.
# No tocar nada en disco; solo confirmar que arranca.
```

Si arranca → la clónica es válida; archivar y eliminar la microSD de pruebas. Si no arranca → repetir el `dd` o probar modalidad B si se usó A.

### 7.4. Almacenamiento y rotación

```text
/mnt/hd2t/backups/microsd/
├── backup-2025-12.img.zst      # anual previa
├── backup-2026-12.img.zst      # anual actual
└── backup-2026-06-pre-debian-13-upgrade.img.zst   # ad-hoc significativo
```

Política de retención: conservar las **dos** clónicas anuales más recientes y cualquier ad-hoc significativa de los últimos 12 meses. Borrar el resto. La carpeta `microsd/` está dentro de `hd2t/backups/`, por lo que **entra en el repo Borg** y por tanto en el offsite — la clónica también está fuera de la Pi gracias a la replicación.

> **Coste en offsite**: ~5-10 GB por clónica × 2 anuales ≈ 10-20 GB extra en B2/Storj. Negligible respecto al volumen total del repo.

### 7.5. Restauración desde clónica (escenario A optimizado)

```bash
# microSD nueva, lector USB en el portátil, imagen recuperada del offsite si hd2t también murió:
sudo zstdcat backup-2026-12.img.zst | \
     sudo dd of=/dev/sd<X> bs=4M status=progress conv=fsync

# Insertar en la Pi nueva, arrancar.
# Si la imagen es de hace meses, aplicar tras el primer SSH:
sudo apt update && sudo apt full-upgrade -y
sudo reboot

# Verificar:
docker ps
sudo borgmatic list --last 3
```

> **Tiempo total escenario A con clónica**: 30 min `dd` + 30 min upgrade + 15 min validación ≈ 1.5 h. Sin clónica: 4-8 h.

---

## 8. RPO y RTO: objetivos del homelab

### 8.1. RPO (Recovery Point Objective)

Cuánto dato se pierde como máximo. Depende de la frecuencia del backup y de cuándo ocurre el desastre relativo al último backup.

| Pieza | RPO peor caso | Notas |
|---|---|---|
| BD relacionales (Nextcloud, Bookstack, Paperless, Mealie, Authelia) | **24 h** | Dump diario en `before_backup`. Pérdida máxima: cambios entre 03:00 del día anterior y el momento del incidente. |
| Vaultwarden (SQLite) | **24 h** | Backup diario via Borgmatic. Ver [`../11-productividad/01-vaultwarden.md`](../11-productividad/01-vaultwarden.md). |
| Configs y secrets en `/mnt/hd2t/services/` | **24 h** | Cambios manuales raros; en operación normal son días sin tocar. |
| Definiciones (`~/homelab/`) | **0** (idealmente) | Versionado en git con push tras cada cambio. Si el operador olvida un push, pasa a "lo que tarde el próximo push". Por eso la verificación mensual §5.6 del playbook periódico. |
| Stash multimedia (`hd5t`) | **N/A** | No backupeado. RPO = no aplica. Pérdida total si hd5t muere sin origen externo. |
| Métricas Prometheus | **24 h-7 d** | Datos de telemetría: pérdida tolerable. Borgmatic los incluye en el snapshot diario, pero la primera reconstrucción tras DR puede tener huecos visibles en los dashboards. Aceptable. |
| Logs de aplicación | **0** (en el log corriente) hasta **24 h** (en el snapshot Borg) | Los logs vivos en `docker logs` se pierden con el contenedor; los persistidos en `/mnt/hd2t/services/<svc>/logs/` siguen el RPO general. |

### 8.2. RTO (Recovery Time Objective)

Cuánto tiempo desde el incidente hasta el homelab funcional.

| Escenario | RTO efectivo (operador frente al teclado) | RTO wall-clock (incluyendo esperas) |
|---|---|---|
| A — microSD muere, con clónica | 1 h | 1.5 h |
| A — microSD muere, sin clónica | 4-6 h | 4-6 h |
| B — Pi5 HW muere | 0.5 h | 3-7 días (envío Pi nueva) |
| C — hd2t falla | 4-8 h | 4-8 h + envío disco si no hay repuesto (1-3 días) |
| D — hd5t falla | 1-2 h | + tiempo de rehidratación de contenido (variable) |
| E — Borg corrupto, offsite OK | 2-4 h | 2-4 h |
| F — compromiso de seguridad | 12-24 h (incluye análisis y rotación de credenciales) | + envío hardware si se decide reemplazo físico |
| G — pérdida total | 6-12 h | 1-3 días (envío hardware + descarga offsite) |
| H — borrado accidental | 0.5-2 h | igual |

> **El homelab está dimensionado** para RTO de 6-12 h efectivas y ≤ 3 días wall-clock en el peor caso. Si el operador necesita servicios con RTO < 1 h (no admite 1 día de caída), el patrón "single Pi" no basta — pasar a "dos Pi calientes con replicación", fuera del scope de este homelab personal.

### 8.3. Limitaciones reconocidas

- **No hay alta disponibilidad**: la Pi es punto único de fallo. Tolerable porque el homelab es uso personal.
- **Stash sin offsite**: decisión consciente (volumen de datos hace prohibitivo el storage cloud). Pérdida aceptable porque es contenido re-obtenible o no crítico.
- **Single egress al offsite**: B2 (o Storj) es un solo proveedor. Si su servicio cae, la siembra del backup nocturno falla y el RPO de offsite crece. Aceptable mientras la sesión semanal del playbook (§4.4) detecta la rotura.

---

## 9. Validación post-DR

El DR no termina cuando el último `docker compose up -d` regresa OK. Termina cuando el operador puede afirmar **con evidencia** que todo está bien.

### 9.1. Checks técnicos

```bash
# 1. Todos los contenedores Up.
docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.RunningFor}}' | grep -v 'Up'
# Esperado: solo el header. Cualquier línea = revisar.

# 2. Uptime Kuma con todos los monitores en verde tras 30 min de propagación.
# Acceder a https://kuma.lan y verificar la lista.

# 3. Caddy responde con cert local y reverse-proxy llega a backends.
for svc in auth caddy nextcloud vaultwarden bookstack jellyfin; do
  echo -n "$svc.lan: "
  curl -ks -o /dev/null -w '%{http_code}\n' "https://$svc.lan/"
done
# Esperado: 200, 401 (Authelia auth required), 302 (redirect a login). 5xx = revisar.

# 4. DNS interno funciona vía Pi-hole.
nslookup nextcloud.lan 192.168.1.2

# 5. Tailscale online.
tailscale status

# 6. Borgmatic timers activos y próximos triggers correctos.
systemctl list-timers borgmatic-* --all

# 7. Métrica clave: borg list muestra el último snapshot del día.
sudo borgmatic list --last 3

# 8. SMART de ambos discos en PASSED.
sudo smartctl -H /dev/disk/by-id/usb-<modelo-hd5t>-<serial>
sudo smartctl -H /dev/disk/by-id/usb-<modelo-hd2t>-<serial>
```

### 9.2. Checks funcionales (uno por servicio crítico)

- **Vaultwarden**: login con la cuenta del operador, ver al menos un password.
- **Nextcloud**: login con la cuenta del operador, ver ficheros, ver usuarios admin.
- **Bookstack**: login, navegar al menos un libro.
- **Jellyfin**: login, ver la biblioteca, reproducir 10 segundos de un vídeo.
- **Home Assistant**: login, ver dashboard principal, ver estado de al menos un dispositivo Zigbee.
- **Pi-hole**: UI accesible, gravity DB poblada, query log con tráfico real.

### 9.3. Smoke test L3 ad-hoc

Independientemente del calendario mensual, ejecutar uno **inmediatamente** después del DR:

```bash
# Procedimiento detallado en docs/07-backups/03-backup-docker-volumes.md §6.5.
# Servicio sugerido: el más complejo (Nextcloud, MariaDB de Bookstack).
# Confirma que los dumps cargados son funcionalmente correctos, no solo consultables.
```

### 9.4. Ventana de observación

Tras un DR, mantener **monitor reforzado** durante 7 días:

- **Diario**: revisar Uptime Kuma, alertas, heartbeat de Borgmatic. Cualquier desviación → investigar (no esperar a la sesión semanal).
- **+1, +3, +7 días**: comparar Grafana dashboards con la línea base previa al desastre. Métricas con tendencia anómala (CPU sostenido > previo, errores HTTP nuevos) suelen indicar configuración degradada que sobrevivió al DR.

Cerrar el incidente solo cuando los 7 días pasen sin sobresaltos. Anotar cierre en `dr-incidents/`:

```markdown
## Cierre — YYYY-MM-DD
Incidente cerrado tras 7 días de monitor reforzado sin anomalías.
Aprendizajes aplicados al playbook:
- ...
```

---

## 10. Lista de Verificación

### 10.1. Pre-DR (siempre, todo el tiempo)

Estos puntos **no** se verifican durante un DR — se verifican periódicamente para que el DR sea posible:

- [ ] Las tres piezas (§2) custodiadas y verificadas trimestralmente.
- [ ] Repo `~/homelab/` con `git status` limpio y `git push` reciente (verificación mensual §5.6 playbook).
- [ ] Smoke test L3 mensual ejecutándose y resultando OK ([`../07-backups/03-backup-docker-volumes.md`](../07-backups/03-backup-docker-volumes.md) §6).
- [ ] Drill anual de DR ejecutado (§5 de este doc).
- [ ] Clónica de microSD de los últimos 12 meses presente en `/mnt/hd2t/backups/microsd/`.
- [ ] Credenciales offsite testadas (`rclone ls b2-homelab:` desde fuera de la Pi).

### 10.2. Durante el DR (procedimiento maestro §4)

- [ ] Triage inicial completado, escenario identificado (§3), bitácora `dr-incidents/<incidente>.md` abierta.
- [ ] Tres piezas confirmadas accesibles (§2).
- [ ] Hardware nuevo en camino (si aplica).
- [ ] Repo Borg descargado al portátil de tránsito y `borg check` OK.
- [ ] Pi nueva booteando, OS limpio, SSH OK con claves del operador.
- [ ] Discos preparados con etiquetas `hd5t`/`hd2t` y montados.
- [ ] Fases 0-2 reaplicadas (sistema, discos, Docker, red `homelab`).
- [ ] Repo Borg restaurado en `/mnt/hd2t/backups/borg/`, `borg check` OK.
- [ ] Borgmatic config en `/etc/borgmatic/`, validación OK, **timers no activos todavía**.
- [ ] Stack DNS levantado, resolución `*.lan` funcionando.
- [ ] Stack proxy + auth + identidad levantados.
- [ ] BD restauradas con `borgmatic restore --database`.
- [ ] Stacks de almacenamiento, multimedia, productividad, dashboards levantados.
- [ ] Tailscale online.
- [ ] Smoke test L3 ad-hoc ejecutado y OK (§9.3).
- [ ] Validación post-DR (§9.1, §9.2) completada.
- [ ] **Por fin**: timers Borgmatic activados.

### 10.3. Post-DR

- [ ] Bitácora `dr-incidents/<incidente>.md` cerrada con timeline, RTO/RPO real, lecciones aprendidas.
- [ ] Anotación en `maintenance.log` (cadencia `ad-hoc`).
- [ ] Commit y push del repo `~/homelab/`.
- [ ] Monitor reforzado de 7 días.
- [ ] Si hubo lecciones aprendidas: PR al propio playbook (`docs/13-operaciones/02-disaster-recovery.md`) con los cambios.
- [ ] Si fue un compromiso (escenario F): rotación completa de credenciales completada y documentada.

---

## 11. Solución de Problemas

| Síntoma | Causa probable | Acción |
|---|---|---|
| `borg check` sobre el repo descargado de B2 reporta corrupción | El repo offsite también se corrompió, o la descarga fue parcial. | Reintentar `rclone sync --checksum` para forzar revalidación. Si persiste, ir a §6.5.1 (snapshots históricos B2 o pérdida parcial). |
| `borgmatic extract` falla con "Repository does not exist" | Path mal escrito o permisos rotos. Borg requiere `BORG_REPO` apuntando exactamente al directorio del repo. | `sudo BORG_REPO=/mnt/hd2t/backups/borg borg list`. Si funciona sin `borgmatic`, el problema está en `config.yaml`. |
| `borgmatic restore --database` no encuentra la BD destino | El contenedor de la BD no está corriendo o el hostname no resuelve dentro del contexto de Borgmatic. | `docker ps \| grep mariadb`. Si está, probar `docker exec mariadb mariadb -u root -p<pwd> -e 'SHOW DATABASES'`. Si todo OK, revisar `mariadb_databases.<name>.hostname` en `/etc/borgmatic/config.yaml`. |
| Pi-hole no resuelve nada tras DR | La red `macvlan` no se recreó (es manual, no parte de docker-compose). | Reaplicar [`../03-red/01-macvlan.md`](../03-red/01-macvlan.md). Reiniciar el contenedor de Pi-hole después. |
| Caddy responde con `502 Bad Gateway` para todos los servicios | Los hostnames internos no se resuelven desde el contenedor de Caddy (DNS Docker). | Confirmar que Caddy está conectado a la red `homelab`: `docker network inspect homelab \| grep caddy`. Si no, `docker network connect homelab caddy`. |
| Authelia loguea "permission denied" en su BD/storage | Permisos del volumen `/mnt/hd2t/services/auth/` cambiaron tras el extract (Borg respeta UID/GID; si el host tiene UIDs distintos, no coinciden). | `sudo chown -R <uid>:<gid> /mnt/hd2t/services/auth/` con los UIDs documentados en [`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md). |
| Vaultwarden arranca pero el operador no puede loguear | La BD SQLite está, pero los argon2 hashes no coinciden por algún problema de codificación. **Improbable**, pero diagnóstico: ¿se restauró el archivo correcto? | Confirmar `sha256sum` del fichero `db.sqlite3` antes y después del extract. Si coincide, probar con cliente Bitwarden por móvil (descarta problema de extension web). |
| `docker compose up -d` falla con "network homelab not found" | La red Docker compartida no se creó tras el bootstrap. | `docker network create homelab`. Es el primer comando post-Docker en el playbook (§4.4 paso 6); fácil de saltarse en pánico. |
| `tailscale up` no encuentra el nodo previo | Es esperado: la Pi nueva tiene huella distinta. El nodo viejo sigue en el panel admin. | Dar de baja el nodo viejo en `https://login.tailscale.com/admin/machines`. Reaplicar [`../03-red/05-tailscale.md`](../03-red/05-tailscale.md). |
| Tras `borgmatic extract`, los logs muestran "tar: Cannot change ownership... Operation not permitted" | El operador ejecutó el extract sin `sudo`. Borg respeta UID/GID solo si el proceso tiene privilegios. | Repetir con `sudo`. Si ya se hizo así y los warnings persisten, revisar capabilities del filesystem (¿el destino es FAT32 o un FS sin xattrs?). |
| Smoke test post-DR falla aunque la app levanta | El extract trajo solo los volúmenes de datos pero no los secrets, o trajo secrets desincronizados con los hashes en BD. | Confirmar que `mnt/hd2t/services/<svc>/secrets/` se restauró completo (§4.7.1). Comparar `ls -la` con la línea base si está documentada. |
| El operador descubre a mitad del DR que el offsite lleva semanas roto | La verificación trimestral (§6.1 playbook) no se hizo, o el alert de Uptime Kuma del backup heartbeat se ignoró. | **Pausar**. Buscar el último snapshot Borg local válido (que en este escenario es de antes del fallo del offsite, conservado en `hd2t` si aún sobrevive). Si hd2t también está perdido, ir a §6.5.1. **Documentar** este hallazgo en `dr-incidents/` como lección crítica. |
| El RTO real superó las 24 h en un escenario que el playbook estimaba en 6-12 h | Probable causa: paso manual no documentado, alguna pieza crítica no estaba en custodia, o el operador improvisó por desconocimiento. | Análisis post-mortem. **Mejorar el playbook** con los pasos que faltaban. Es la causa principal por la que el playbook anual se revisa cada año (§7.5 del playbook periódico). |
| Tras el DR, Watchtower hace pull de imágenes nuevas y rompe servicios recién restaurados | Las versiones del repo Borg son anteriores; Watchtower siempre apunta a `latest`. | Considerar pin de versión por servicio mientras dura la ventana de observación post-DR (§9.4). Editar `image:` con tag exacto, `docker compose up -d`. Quitar pin a las 4-6 semanas si no hay incidentes. |
| El operador ejecutó wipe accidental sobre la microSD original durante un drill | Drill destructivo cuando se debió hacer el no destructivo (§5.1). | Continuar el drill como si fuera el escenario A real (§6.1) — convertir el accidente en aprendizaje. La clónica anual debería estar disponible para acelerar la recuperación. |

---

## Referencias

- [BorgBackup — `borg check`](https://borgbackup.readthedocs.io/en/stable/usage/check.html)
- [BorgBackup — `borg extract`](https://borgbackup.readthedocs.io/en/stable/usage/extract.html)
- [BorgBackup — `borg key change-passphrase`](https://borgbackup.readthedocs.io/en/stable/usage/key.html)
- [Borgmatic — `restore` action](https://torsion.org/borgmatic/docs/reference/command-line/#restore)
- [Borgmatic — `extract` action](https://torsion.org/borgmatic/docs/reference/command-line/#extract)
- [Backblaze B2 — Object Lock and versioning](https://www.backblaze.com/cloud-storage/file-lock)
- [rclone — `sync` y `copy`](https://rclone.org/commands/rclone_sync/)
- [GNU `ddrescue` — recuperación de discos degradados](https://www.gnu.org/software/ddrescue/manual/ddrescue_manual.html)
- [Raspberry Pi — Documentation: SD card cloning](https://www.raspberrypi.com/documentation/computers/getting-started.html)
- [zstd — algoritmo de compresión](https://github.com/facebook/zstd)
- [Tailscale — admin console](https://login.tailscale.com/admin/machines)
- [NIST SP 800-34 — Contingency Planning Guide for Federal Information Systems](https://csrc.nist.gov/publications/detail/sp/800-34/rev-1/final) (referencia general sobre RPO/RTO)
- [Veeam — "3-2-1 backup rule"](https://www.veeam.com/blog/321-backup-rule.html)
