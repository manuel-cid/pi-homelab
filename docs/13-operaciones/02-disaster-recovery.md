# Disaster recovery del homelab

## Descripción

Define el **procedimiento de recuperación ante desastre**: qué se hace cuando algo deja al homelab parcial o totalmente fuera de servicio y la solución no es "reiniciar el contenedor" sino "reconstruir desde un backup". Cubre desde el escenario más leve (un servicio corrupto que hay que rebobinar a un _archive_ Borg de hace dos días) hasta el más severo (la Pi 5 desaparece físicamente, microSD y `hd2t` con ella, y todo lo que queda en pie es el repo Borg offsite y la _passphrase_ guardada fuera del homelab).

A diferencia de `docs/13-operaciones/01-mantenimiento-periodico.md` (mantenimiento ordinario, calendario y bitácora), este documento es un **runbook**: una secuencia ordenada de pasos, escenario a escenario, con _RTO_ (_recovery time objective_) realista, criterios de éxito explícitos y puntos de decisión claros. No instala nada nuevo: presupone que todas las fases 0-12 están desplegadas y documentadas, y se limita a **explicar cómo volver a tenerlas en marcha** cuando algo se ha roto.

> **Filosofía del DR**: el homelab está diseñado bajo el supuesto de que **la única fuente de verdad sobreviviente puede ser el repo Borg offsite**. Cualquier procedimiento que dependa de tener `hd2t` físicamente delante, o el repo local intacto, o la microSD original, es un atajo: existe (y se documenta), pero no se asume. La regla 3-2-1 de `docs/07-backups/01-estrategia-backup.md` se cumple precisamente para que el DR completo sea viable con **un único activo**: la _passphrase_ del repo Borg, custodiada según `docs/07-backups/02-borgmatic.md` (Vaultwarden + gestor externo + copia papel). Sin ese activo, no hay DR — sólo hay reinstalación desde cero.

> **Alcance**: este documento cubre fallos **del homelab**: software, hardware local y datos. **No** cubre fallos de servicios externos al homelab (no se restaura un proveedor offsite caído; se cambia de proveedor y se rehace el _seeding_). **No** cubre incidentes de seguridad (compromiso de credenciales, _ransomware_): para eso hay que combinar DR con auditoría, pero la respuesta forense vive fuera de este doc. **No** cubre _migration_ planificada (cambiar la Pi 5 por una Pi 6 en frío sin haber roto nada): la migración es un caso particular del DR completo donde no hay urgencia y se puede preparar todo, pero el procedimiento de fondo es el mismo y se reutiliza.

> **Alcance de red**: como en el resto del homelab, todo es **LAN + Tailscale** (`docs/03-red/05-tailscale.md`). Cuando el DR exige acceder al repo Borg offsite (vía SSH a un VPS o a `rsync.net`) la salida hacia internet se hace desde la propia Pi de recuperación con sus credenciales, no se exponen puertos del homelab al exterior en ningún momento del procedimiento.

---

## Requisitos previos

Para que este documento sea útil cuando haga falta, las siguientes piezas deben **existir y estar accesibles desde fuera del homelab** antes de cualquier desastre:

- **_Passphrase_ del repo Borg**, custodiada en al menos dos lugares **fuera de la Pi**: gestor de contraseñas externo (Bitwarden cloud, 1Password) y copia papel en sobre cerrado o caja fuerte. Política y rotación en `docs/07-backups/02-borgmatic.md` → _Custodia de la passphrase y secretos_.
- **Clave SSH del operador para el destino offsite**, también fuera de la Pi. La clave que usa el _stack_ Borgmatic (`/etc/borgmatic.d/secrets.env`) **no** se asume sobreviviente; se sustituye por una clave del operador en el momento del DR.
- **Credenciales del proveedor offsite**: usuario, contraseña, acceso al panel de control, datos de contacto. Sin acceso al panel no hay forma de recuperar acceso si el SSH se pierde.
- **Repositorio git remoto** (GitHub, Gitea, Codeberg) con el repo `~/homelab/` actualizado. Si el _push_ no se ha hecho recientemente, la última semana de cambios de configuración (Caddyfile, `.env.example`, _compose_ ajustados) puede no estar en el remoto. Verificar en cada ronda mensual (`docs/13-operaciones/01-mantenimiento-periodico.md`).
- **Documentación versionada en el mismo repo git**: `docs/00-hardware/`, `docs/01-sistema/`, `docs/02-docker/`, `docs/07-backups/`. El DR se ejecuta **leyendo estos docs**, no de memoria. Si el repo git remoto está fuera de servicio, vale tener el repo clonado en un portátil o en el móvil (Termux + git).
- **Hardware mínimo de repuesto, o accesible a corto plazo**: una microSD nueva (64 GB, A2 si es posible), un cable Ethernet, un cargador 27 W, un teclado y una pantalla HDMI por si SSH no responde tras el primer arranque. La Pi 5 en sí puede comprarse en horas en cualquier tienda online, pero si el desastre coincide con un fin de semana largo es bueno haberlo previsto.
- **Acceso a la red doméstica**: contraseña WiFi (rara vez necesaria — el homelab va por Ethernet — pero útil si la Pi de DR provisional tiene que ir por WiFi), credenciales del router (para ver qué IP coge la nueva Pi), y conocer las IPs reservadas en DHCP (ver `docs/03-red/01-macvlan.md` y `docs/13-operaciones/04-red-y-puertos.md`).
- **Tiempo y cabeza fría**: ningún DR se hace bien en mitad de la noche. Si el desastre puede esperar a la mañana siguiente (ej. el operador descubre el viernes a las 23:00 que el repo local está corrupto pero el offsite está sano y el homelab sigue funcionando), espera. Si no puede esperar (`hd2t` se ha desmontado y los servicios están caídos), al menos comer algo y hacer la primera fase de _triage_ antes de empezar a teclear.

---

## Decisiones de diseño

### Una sola fuente de verdad: el repo Borg offsite

El homelab tiene cuatro lugares donde "vive" información persistente:

1. La **microSD** del sistema (sólo SO + configuración mínima).
2. El **repo `~/homelab/`** en git (todo lo que es configuración: `docker-compose.yml`, `.env.example`, Caddyfile, _hooks_ de Borgmatic, …).
3. **`hd2t`**, con `services/` (datos de servicios), `backups/` (repo Borg local + dumps), `system/` (swap, logs).
4. **`hd5t`**, con la biblioteca multimedia de Stash.

El DR está diseñado bajo la regla de que **(2)** vive en un git remoto, **(3)** vive replicado en el offsite vía Borg, **(1)** se reconstruye en 30 minutos siguiendo `docs/01-sistema/01-instalacion-os.md` y **(4)** **no se respalda**: la biblioteca de Stash es voluminosa y reconstruible, según la categoría D de `docs/07-backups/01-estrategia-backup.md`.

> **Consecuencia operativa**: el DR completo "desde cero" no requiere ni `hd2t` físico ni microSD original — basta con el repo git remoto, el repo Borg offsite, la _passphrase_ y la clave SSH del offsite. Es el caso peor; cualquier escenario menos severo es más rápido.

### Restauración por capas (cebolla), no en paralelo

La tentación al hacer DR es "arrancar todo a la vez para ver qué se rompe". Es un error: si Pi-hole y Caddy intentan levantar al mismo tiempo y Caddy quiere resolver `pi-hole.lan` que aún no existe, el _stack_ entero entra en _restart loop_ y los _logs_ se vuelven irrelevantes. La restauración va en **capas** y cada capa se valida antes de pasar a la siguiente:

| Capa | Contenido                                      | Por qué primero                                                                                        |
|------|------------------------------------------------|--------------------------------------------------------------------------------------------------------|
| 0    | Host (OS, usuario, SSH, fstab, swap, paquetes) | Sin esto no hay shell estable para nada.                                                               |
| 1    | Docker + redes                                 | Sin Docker ningún servicio arranca. La red `homelab_net` y la macvlan deben existir antes que Pi-hole. |
| 2    | DNS interno (Pi-hole + Unbound)                | Sin DNS local los demás servicios no resuelven `*.lan` y todo el _stack_ falla.                       |
| 3    | Reverse proxy (Caddy) + Tailscale              | Sin Caddy nada es accesible por nombre; sin Tailscale el operador puede perder acceso remoto durante el DR. |
| 4    | Identidad (Authelia)                           | Sin Authelia los servicios protegidos rechazan el _login_.                                             |
| 5    | Backups (Borgmatic + smartd)                   | Antes de seguir restaurando, asegurar que **el sistema vuelve a respaldar**. Un DR a medio hacer puede sufrir un segundo desastre. |
| 6    | Datos críticos (Vaultwarden, Nextcloud BD, Home Assistant) | Servicios cuya falta de servicio o pérdida de datos es operativa para el operador y la familia.       |
| 7    | Datos secundarios (multimedia, productividad, descargas) | El resto. Pueden esperar horas/días si hace falta.                                                     |

> **Por qué Borgmatic en capa 5 y no antes**: hasta tener al menos las capas 0-3 estables, el repo restaurado se considera "sólo lectura". Re-conectar Borgmatic antes de tiempo provoca un _archive_ vacío o incompleto que ensucia el historial. Mejor: mantener Borgmatic deshabilitado durante el DR y reactivarlo cuando la capa 5 se valida.

### RTO realista: < 4 h para DR completo, < 30 min para DR de servicio único

El _RTO_ que se asume es el que aparece en la ronda anual de `docs/13-operaciones/01-mantenimiento-periodico.md`:

- **DR completo** (Pi nueva, microSD nueva, `hd2t` nuevo, `hd5t` nuevo): objetivo **< 4 h** desde "tarjeta vacía" hasta "Vaultwarden + Nextcloud + Home Assistant operativos en LAN". Multimedia y servicios secundarios pueden tardar más.
- **DR parcial** (microSD muerta, `hd2t` intacto): **< 90 min**.
- **DR parcial inverso** (microSD intacta, `hd2t` perdido): **< 3 h** (más lento que el caso anterior porque hay que descargar del offsite).
- **DR de servicio único** (rebobinar Vaultwarden a un _archive_ de hace 2 días por corrupción de la BD): **< 30 min**.
- **DR de Stash** (`hd5t` perdido): no se mide en horas: la biblioteca se recoloca, se vuelven a montar las fuentes y se relanzan los _scrapers_; puede llevar días, pero el resto del homelab no se ve afectado.

Si en un drill anual estos tiempos se exceden por más del 50 %, el procedimiento tiene un _gap_ que debe corregirse antes del siguiente trimestre.

### Si el DR no se prueba, no existe

El DR completo se ejecuta **una vez al año** en la ronda anual ("cumpleaños del homelab", `docs/13-operaciones/01-mantenimiento-periodico.md`). Sin esa ejecución periódica, el procedimiento aquí escrito acumula _drift_: una variable de entorno renombrada, una imagen Docker retirada, un volumen movido, una dependencia rota. La diferencia entre un homelab que sobrevive un desastre y uno que no es **haber drillado al menos una vez**.

> **Drill seguro**: el DR completo anual se hace **en una Pi auxiliar** (otra Pi 5 o una Pi 4 que sirve para el drill), o en una microSD limpia con el `hd2t` físico **desconectado del original**. Nunca se hace tocando el homelab vivo: un error en la fase 0 puede inutilizar la Pi en producción.

---

## Matriz de escenarios

Cada escenario se clasifica por **severidad** (qué se ha perdido), **probabilidad relativa** (en orden de mayor a menor en un homelab típico), **RTO** y **procedimiento aplicable**.

| # | Escenario                                                          | Probabilidad | Severidad | RTO     | Procedimiento                                |
|---|--------------------------------------------------------------------|--------------|-----------|---------|----------------------------------------------|
| 1 | Servicio único corrupto (volver a un _archive_ Borg previo)        | Alta         | Baja      | < 30 min | _Procedimiento E_                            |
| 2 | Volumen Docker / BD corruptos por _bug_ tras update                | Alta         | Baja-Media | < 1 h   | _Procedimiento E_ + _rollback_ de imagen     |
| 3 | microSD muerta, `hd2t` intacto                                     | Media        | Media     | < 90 min | _Procedimiento A_ (DR microSD)               |
| 4 | `hd2t` perdido (corrupción ext4, fallo USB), microSD intacta       | Media-Baja   | Alta      | < 3 h   | _Procedimiento B_ (DR `hd2t`)                |
| 5 | Pi 5 muerta (electrónica, robo, pérdida); `hd2t` puede sobrevivir  | Baja         | Alta      | < 3 h   | _Procedimiento A_ con Pi nueva + `hd2t` antiguo |
| 6 | DR completo: Pi + microSD + `hd2t` perdidos, sólo offsite y git    | Muy baja     | Crítica   | < 4 h   | _Procedimiento C_ (DR completo desde offsite) |
| 7 | `hd5t` perdido (multimedia Stash, biblioteca propia)               | Media        | Baja-Media | Días    | _Procedimiento D_ (recuperación de `hd5t`)   |
| 8 | Repo Borg local corrupto, offsite OK                               | Baja         | Baja      | < 1 h   | _Procedimiento F_ (rebuild local desde offsite) |
| 9 | Repo Borg offsite corrupto, local OK                               | Muy baja     | Media     | Horas   | _Procedimiento G_ (re-_seed_ del offsite)    |

> **Nota sobre la probabilidad**: las microSD del homelab corren un OS Lite con _swap_ desplazado a `hd2t` (`docs/01-sistema/02-configuracion-inicial.md`), `journald` rotado y sin escrituras intensivas. Con esa higiene, la mortalidad de la microSD es baja, pero sigue siendo el componente con mayor probabilidad relativa de fallo en un horizonte de 2-3 años.

---

## Procedimiento maestro: DR completo (escenario 6)

Es el procedimiento más largo y el que se drilla cada año. Cualquier escenario menos severo es un subconjunto de éste, así que entender este procedimiento entero es lo que da control sobre los demás. La división por **fases** es la misma que la "cebolla" de capas pero con los pasos ejecutables.

### Fase A — Triage (15-30 min, sin tocar nada)

Antes de teclear, **decidir el alcance**. Es el paso que más DRs se saltan, y el que más tiempo ahorra a la larga.

```markdown
## Triage de DR — YYYY-MM-DD HH:MM

- [ ] **¿Qué se sabe que está roto?**
      Lista concreta. "El homelab no funciona" no es una respuesta.
- [ ] **¿Qué se sabe que está intacto?**
      ¿Sigue arrancando la Pi? ¿`ssh` responde? ¿`df` ve los discos? ¿Otros servicios responden?
- [ ] **¿Qué se sospecha pero no se ha verificado?**
      "El offsite seguramente está bien" → comprobar antes de empezar a depender de él.
- [ ] **¿Qué activos están disponibles fuera del homelab?**
      Passphrase Borg accesible (sí/no), clave SSH offsite accesible (sí/no), repo git remoto al día (verificar `git log` del último commit), credenciales del proveedor offsite (sí/no).
- [ ] **¿Cuál es el escenario más cercano de la matriz?**
      Anotar el número (1-9) y leer el procedimiento aplicable **completo** antes de empezar.
- [ ] **¿Hay riesgo de empeorar la situación si se actúa rápido?**
      Ej. si el `hd2t` está medio corrupto, lanzarle un `fsck -y` puede rematarlo. Antes de eso, `dd` a otro disco si es posible.
- [ ] **¿Hay tiempo para hacerlo bien o hay que hacer algo provisional ya?**
      Si la familia está sin Vaultwarden y son las 22:00, restaurar **sólo Vaultwarden** en una Pi auxiliar como _solución puente_ y posponer el DR completo a la mañana puede ser la mejor opción.
- [ ] **Anotar timestamp de inicio en la bitácora** (`~/homelab/docs/journal/YYYY-MM.md` o equivalente) para medir el RTO real.
```

> **Regla de oro del triage**: si el homelab vivo tiene algún riesgo de seguir degradándose mientras se prepara el DR (un disco emitiendo errores SMART críticos, una BD que no para de corromperse), el primer paso es **detener lo que se está degradando** (`docker compose down`, desmontar el disco) para que no se llegue al DR con datos peores que los del último _archive_ Borg.

### Fase B — Bootstrap del host (60-90 min)

Esta fase reproduce las fases 0 y 1 del homelab en una Pi limpia.

#### B.1 — Hardware

- Conectar Pi 5, fuente 27 W, cable Ethernet, microSD nueva.
- Si los discos antiguos sobreviven y van a reusarse: **no conectarlos todavía**. Se conectan después de validar el SO base. Conectarlos antes corre el riesgo de que `udev` o `mount -a` fallen por una entrada vieja en `/etc/fstab` que ya no aplica.

#### B.2 — Grabar Raspberry Pi OS Lite 64-bit

Seguir `docs/01-sistema/01-instalacion-os.md` exactamente:

- Imager → "Raspberry Pi OS Lite (64-bit)".
- _Customisation_: hostname (`homelab` o el que fuera), usuario `homelab`, **clave SSH pública** del operador (la del portátil de DR), zona horaria `Europe/Madrid`, locale `es_ES.UTF-8`, deshabilitar contraseña.
- Grabar y arrancar.

#### B.3 — Primer SSH y red

- Localizar la IP en el router DHCP. Si la reserva DHCP de la Pi original sigue puesta para la MAC vieja, configurarla para la MAC nueva (la de la nueva Pi).
- `ssh homelab@<ip>` y verificación rápida (`uname -a`, `free -h`, `ip a`).

#### B.4 — Tailscale en el host (instalar pronto)

A diferencia del orden de las fases originales (Tailscale en fase 3), durante un DR **se instala Tailscale lo antes posible** porque permite seguir trabajando desde fuera de casa si hace falta y porque el repo offsite suele estar accesible vía Tailscale o vía SSH directo, pero abrir el _tailnet_ en la Pi nueva es trivial:

```bash
curl -fsSL https://tailscale.com/install.sh | sudo sh
sudo tailscale up --ssh --hostname=homelab-dr
# Aprobar el dispositivo en la consola Tailscale.
# Si Magic DNS está activo y existe un nombre 'homelab' fijado al host antiguo,
# hay dos opciones:
#   a) usar 'homelab-dr' temporalmente y renombrar al final
#   b) eliminar el dispositivo viejo en la consola y reusar el nombre
# La opción (a) es más segura durante el DR; la (b) más limpia al final.
```

> **Después del DR**: si se usó `homelab-dr` durante el procedimiento, al cerrar el DR el dispositivo se renombra a `homelab` (panel Tailscale → _Edit machine name_) o se relanza con `--hostname=homelab`. Las ACLs de `docs/03-red/05-tailscale.md` deben volver a aplicar al nombre canónico.

#### B.5 — Endurecimiento mínimo (no completo)

- Aplicar lo crítico de `docs/01-sistema/03-seguridad-base.md` (cambiar contraseña de `homelab`, deshabilitar login con password, `nftables` con la regla mínima de "permitir loopback + permitir _established/related_ + permitir SSH"). El resto (fail2ban, _unattended-upgrades_) se aplica al final, en la capa 5.
- Aplicar `docs/01-sistema/02-configuracion-inicial.md` para: hostname, zona horaria, NTP. **No** crear todavía la swap en `hd2t` (no hay `hd2t` aún).

#### B.6 — Conectar y montar discos

Tres sub-casos:

- **Discos antiguos sobreviven y se reusan**: conectar `hd5t` y `hd2t` a los puertos USB 3.0 azules. `lsblk -f` debe mostrarlos con sus etiquetas. Restaurar `/etc/fstab` desde `docs/00-hardware/03-preparacion-discos.md` (entradas por LABEL). `sudo mount -a`. Verificar `df -h /mnt/hd2t /mnt/hd5t`.
- **Discos nuevos** (DR completo real): seguir `docs/00-hardware/03-preparacion-discos.md` desde cero (particionar GPT, `mkfs.ext4 -L hd5t/-L hd2t`, fstab, montaje, SMART). Tiempo: 20-30 min, dominado por el tiempo de creación del FS.
- **Disco mixto** (`hd2t` muere, `hd5t` sobrevive o viceversa): hacer la operación correspondiente sólo en el disco perdido y reusar el otro tal cual.

Tras esto, los discos están listos para **recibir datos**, pero todavía vacíos (excepto el `hd2t` viejo si sobrevive).

#### B.7 — Estructura de directorios y swap

Si `hd2t` es nuevo, ejecutar `docs/01-sistema/04-estructura-directorios.md` (crear `/mnt/hd2t/{services,backups,system}` con `0755`, `0700` y _setgid_ en `services/shared/`) y luego `docs/01-sistema/02-configuracion-inicial.md` para crear el _swapfile_ en `/mnt/hd2t/system/swap/swapfile`.

Si `hd2t` sobrevive: la estructura ya existe, sólo hay que verificar (`ls -la /mnt/hd2t/`) y reactivar el swap (`sudo swapon /mnt/hd2t/system/swap/swapfile`).

#### B.8 — Paquetes mínimos para Borg

Para descargar del offsite hace falta `borg` y `borgmatic` instalados ya. Seguir `docs/07-backups/02-borgmatic.md` → _Instalación de los paquetes_:

```bash
sudo apt update
sudo apt install -y borgbackup borgmatic openssh-client
borg --version
borgmatic --version
```

> **Justificación del orden**: instalar Docker antes de Borg sería más natural, pero Borg lo necesitamos antes para restaurar el repo `~/homelab/` que contiene los compose. Docker irá en la fase D.

### Fase C — Recuperación del repo Borg (30-90 min)

#### C.1 — Recuperar la _passphrase_ y la clave SSH

- Abrir Vaultwarden en el portátil/móvil → entrada "Homelab — Borg passphrase". Copiar al clipboard sólo lo necesario.
- Abrir Vaultwarden → entrada "Homelab — Borgmatic SSH key (offsite)". Si la clave privada está adjunta, descargarla. Si no está en Vaultwarden, recuperarla del gestor externo o regenerarla:

```bash
mkdir -p ~/.ssh
chmod 0700 ~/.ssh
# Si la clave está adjunta al gestor:
cp /tmp/borgmatic_ed25519 ~/.ssh/
chmod 0600 ~/.ssh/borgmatic_ed25519
# Si hay que regenerar (la pública nueva tiene que añadirse al destino offsite vía panel):
ssh-keygen -t ed25519 -f ~/.ssh/borgmatic_ed25519 -C "borgmatic-DR-YYYY-MM-DD"
```

> Si la clave SSH del offsite se pierde y hay que regenerarla, depende del proveedor cómo se hace: en `rsync.net` hay un panel web para gestionar `authorized_keys` del usuario; en un VPS propio se necesita acceso SSH al VPS desde otro lado para añadir la clave. Tener documentado este paso (en Vaultwarden o en `docs/07-backups/01-estrategia-backup.md` → _Destino offsite_) es clave.

#### C.2 — Validar que el offsite responde

```bash
ssh -i ~/.ssh/borgmatic_ed25519 -o BatchMode=yes <user>@<offsite> "true"
echo $?
```

`0` significa que la conexión funciona. Cualquier otra cosa: revisar el host, la clave, el firewall del proveedor.

#### C.3 — Inspeccionar el repo offsite antes de tocarlo

```bash
export BORG_PASSPHRASE='<passphrase recuperada>'
export BORG_RSH='ssh -i ~/.ssh/borgmatic_ed25519'
borg list ssh://<user>@<offsite>:<ruta-repo>/ | tail -20
borg info ssh://<user>@<offsite>:<ruta-repo>/
```

Anotar: número de _archives_, fecha del último, _All archives original size_. Si el último _archive_ es de **hoy** o **ayer**, el RPO (_recovery point objective_) está bien. Si es de hace varias semanas, hay un problema previo no detectado: el operador estará restaurando un homelab antiguo.

#### C.4 — Decidir el _archive_ a restaurar

Por defecto, el más reciente:

```bash
ARCHIVE=$(borg list ssh://<user>@<offsite>:<ruta-repo>/ --last 1 --short)
echo "$ARCHIVE"
```

Excepción: si el desastre fue causado por **corrupción reciente** (ej. una BD se corrompió hace 3 días por un _bug_ y el operador tardó en darse cuenta), restaurar el _archive_ inmediatamente anterior al inicio del problema. La política de retención de Borgmatic (`docs/07-backups/01-estrategia-backup.md` → _Retención_) garantiza que hay _archives_ diarios de las últimas semanas.

#### C.5 — Restaurar `/mnt/hd2t/services/` desde el _archive_

```bash
cd /mnt/hd2t  # nos colocamos donde queremos restaurar la jerarquía
sudo BORG_PASSPHRASE='...' BORG_RSH='ssh -i /home/homelab/.ssh/borgmatic_ed25519' \
     borg extract --progress \
     ssh://<user>@<offsite>:<ruta-repo>/::"$ARCHIVE" \
     mnt/hd2t/services
```

> **Detalle importante**: Borg restaura conservando la **ruta absoluta** que se respaldó (`mnt/hd2t/services/...`), por eso el `cd /` o el `cd /mnt/hd2t` y la ruta sin barra inicial. Si se ejecuta desde otro `cwd` la jerarquía se desplaza y `docker compose` no encontrará los _bind mounts_ esperados.

Tiempo: depende del tamaño del repo y del ancho de banda del offsite. Para 200-400 GB de datos comprimidos a una conexión doméstica típica (50-100 Mbps de bajada), 4-12 h en _bruto_; pero los servicios **críticos** (Vaultwarden, Authelia, Caddy, Pi-hole) son < 1 GB y están listos en minutos. Por eso conviene restaurar **selectivamente** primero lo crítico y empezar a arrancar mientras lo demás sigue bajando.

#### C.6 — Restaurar selectivamente lo crítico primero

```bash
cd /mnt/hd2t
sudo BORG_PASSPHRASE='...' BORG_RSH='ssh -i /home/homelab/.ssh/borgmatic_ed25519' \
     borg extract --progress \
     ssh://<user>@<offsite>:<ruta-repo>/::"$ARCHIVE" \
     mnt/hd2t/services/vaultwarden \
     mnt/hd2t/services/authelia \
     mnt/hd2t/services/caddy \
     mnt/hd2t/services/pihole \
     mnt/hd2t/services/unbound \
     mnt/hd2t/services/homeassistant \
     mnt/hd2t/services/nextcloud \
     mnt/hd2t/backups/dumps
```

Y dejar el resto (`mnt/hd2t/services/{jellyfin,navidrome,sonarr,radarr,...}`) para una segunda extracción en paralelo (`tmux` o `screen`) mientras se siguen ejecutando las fases siguientes.

> **`mnt/hd2t/backups/dumps`**: incluye los dumps SQL más recientes generados por los `before_backup` hooks de Borgmatic (`docs/07-backups/03-backup-docker-volumes.md`). Son los que se usarán en la fase F para restaurar las BDs (Nextcloud MariaDB, Paperless Postgres, Bookstack MariaDB, Mealie Postgres, …) sobre las imágenes recién levantadas. **Sin estos dumps no hay servicios con BD funcionales**.

#### C.7 — Restaurar `~/homelab/`

Lo más rápido es clonarlo desde git:

```bash
cd ~
git clone git@<remote>:<user>/homelab.git
cd homelab
ls
```

Si el remoto está caído o inaccesible, extraerlo del propio _archive_ Borg (Borgmatic respalda `~/homelab/` como categoría A según `docs/07-backups/01-estrategia-backup.md`):

```bash
cd ~
sudo BORG_PASSPHRASE='...' BORG_RSH='ssh -i /home/homelab/.ssh/borgmatic_ed25519' \
     borg extract --progress \
     ssh://<user>@<offsite>:<ruta-repo>/::"$ARCHIVE" \
     home/homelab/homelab
sudo chown -R homelab:homelab ~/homelab
```

#### C.8 — Restaurar los `.env` con secretos

Los `.env` **no** están en el git remoto (sólo `.env.example`). Están en el _archive_ Borg (la rama `~/homelab/` se respalda completa). Tras restaurar `~/homelab/` el operador encontrará los `.env` en su sitio. Verificación rápida:

```bash
find ~/homelab -name '.env' -type f -exec ls -l {} \;
# Cada uno debe tener permisos 0600 y propietario homelab.
chmod 0600 ~/homelab/**/.env 2>/dev/null || true
```

> **Si los `.env` no están en el _archive_** (caso patológico: alguien los excluyó por error en un cambio reciente de Borgmatic), reconstruirlos a partir de `.env.example` y de Vaultwarden, que custodia las contraseñas críticas (Postgres root, MariaDB root, Authelia JWT_SECRET, etc.). Es el peor de los caminos: documentado pero raro.

### Fase D — Docker y orquestación (15-30 min)

#### D.1 — Instalar Docker Engine

Seguir `docs/02-docker/01-instalacion-docker.md`:

```bash
# Repositorio oficial Docker para Debian Bookworm ARM64
sudo apt install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/debian/gpg \
     -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) \
      signed-by=/etc/apt/keyrings/docker.asc] \
      https://download.docker.com/linux/debian $(lsb_release -cs) stable" \
     | sudo tee /etc/apt/sources.list.d/docker.list
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io \
                    docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker homelab
newgrp docker  # o relogin
docker version
docker compose version
```

#### D.2 — Reconstruir las redes Docker

Antes de levantar ningún _stack_, las redes deben existir. La macvlan (`docs/03-red/01-macvlan.md`) y la `homelab_net` interna (`docs/02-docker/02-estructura-compose.md`):

```bash
docker network create homelab_net  # bridge interno, defaults
# Macvlan: leer parámetros del .env del stack pihole y replicar.
docker network create -d macvlan \
  --subnet=192.168.1.0/24 \
  --gateway=192.168.1.1 \
  --ip-range=192.168.1.16/29 \
  -o parent=eth0 \
  homelab_macvlan
docker network ls | grep homelab
```

> **Si `eth0` no se llama así en la Pi nueva** (en Bookworm puede aparecer como `end0` o `enp0sN`), ajustar `parent=`. Verificación: `ip -br link`.

#### D.3 — Verificación

```bash
docker run --rm hello-world  # tira de Internet, prueba que Docker funciona
docker network ls
docker info | grep -E 'Server Version|Storage Driver|Cgroup'
```

### Fase E — Capas 2-4 (DNS → Reverse proxy → Identidad, 30-60 min)

A partir de aquí, cada `make up` se hace **stack a stack**, con verificación entre cada uno.

#### E.1 — Pi-hole + Unbound (capa 2)

```bash
cd ~/homelab/pihole
make up
# Esperar a 'healthy' (~30 s)
make ps
# Test de resolución desde el host:
dig @192.168.1.X google.com +short  # X = IP macvlan de Pi-hole
dig @192.168.1.X portainer.lan +short  # debe resolver al Caddy
```

Si `dig` no resuelve `*.lan`, revisar `local-records` o `local-cnames` de Pi-hole. Es habitual que tras un DR estos registros locales necesiten un re-import desde la UI o desde `pihole-FTL` config.

#### E.2 — Tailscale como contenedor o seguir con el host

Si el plan es Tailscale en host (instalado en B.4), la conexión ya está. Si era plan de stack, levantar el _stack_ ahora; pero durante un DR es mejor mantener Tailscale en host por simplicidad.

#### E.3 — Caddy (capa 3)

```bash
cd ~/homelab/caddy
make up
# Caddy va a regenerar los certificados de la CA local en su primer arranque.
# Verificación:
docker logs caddy 2>&1 | tail -50
# Tests:
curl -k https://portainer.lan/    # debe responder con Portainer (404 si stack aún no levantado)
curl -k https://uptime.lan/       # idem
```

> **Detalle importante**: la CA local de Caddy se regenera si `/data/caddy/pki/authorities/local/` está vacío. Esto invalida los certificados aceptados previamente por los clientes (navegador del operador, móviles de la familia). Si la rama `services/caddy/data/caddy/` se restauró desde el _archive_ Borg (capa que **se respalda**), la CA es la antigua y los clientes no notan diferencia. Si no se restauró (porque el directorio era nuevo), tras el DR habrá que volver a aceptar la CA en cada cliente. La política de Borg debe respaldar `services/caddy/` completo.

#### E.4 — Authelia (capa 4)

```bash
cd ~/homelab/authelia
make up
docker logs authelia 2>&1 | tail -30
# Tests:
curl -k https://auth.lan/  # debe servir el portal de login
```

Si Authelia se queja de _users database_ ausente, restaurar manualmente desde el _archive_ Borg (`services/authelia/users_database.yml`). Si se queja de `JWT_SECRET` ausente, está en el `.env` que ya restauramos.

### Fase F — Capas 5-7 (datos críticos, 60-120 min)

#### F.1 — Borgmatic + smartmontools (capa 5)

Antes de seguir con servicios pesados, dejar el sistema **respaldando otra vez**. La razón: si el DR aún se complica (otro fallo, mala restauración), tener al menos un Borgmatic sano permite repetir el DR sin haber perdido el avance.

- Restaurar `/etc/borgmatic.d/` y `/etc/borgmatic.d/secrets.env` (están en el _archive_ Borg como categoría A; ver `docs/07-backups/02-borgmatic.md` → _Layout en disco_).
- Restaurar el `borgmatic.timer` y el `borgmatic.service` de `/etc/systemd/system/`.
- `sudo systemctl daemon-reload && sudo systemctl enable --now borgmatic.timer`.
- Verificar: `systemctl list-timers borgmatic.timer`.
- Lanzar un dry-run: `sudo borgmatic --dry-run --verbosity 1`.
- **Importante**: en la primera corrida tras DR, el _archive_ generado se va a deduplicar contra los anteriores; el _delta_ es pequeño y se completa en minutos.
- Activar `smartd`: `sudo systemctl enable --now smartd`. Verificación según `docs/00-hardware/03-preparacion-discos.md`.

#### F.2 — Vaultwarden (capa 6.1)

```bash
cd ~/homelab/vaultwarden
make up
docker logs vaultwarden 2>&1 | tail -30
# Test desde el navegador: https://vault.lan/ → login del operador.
# Si la BD SQLite restaurada está sana, las credenciales son las de antes del desastre.
```

> **Verificación crítica**: hacer login con la cuenta del operador y abrir al menos 3 entradas distintas (ej. la de "Homelab — Borg passphrase"). Si las entradas no descifran, los _vault keys_ no coinciden — algo va mal con la BD restaurada. Esta es la verificación que confirma que el DR es real, no aparente.

#### F.3 — Nextcloud (capa 6.2)

Nextcloud necesita restaurar **dos cosas**: la BD MariaDB (desde el dump SQL más reciente en `mnt/hd2t/backups/dumps/`) y los datos de usuario (`services/nextcloud/data/` ya restaurado desde Borg).

Procedimiento detallado en `docs/07-backups/03-backup-docker-volumes.md` → _Patrón M — MariaDB / MySQL_:

```bash
cd ~/homelab/nextcloud
# 1. Levantar sólo el contenedor de la BD (con datadir vacío)
docker compose up -d nextcloud-db
docker exec nextcloud-db mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e 'SHOW DATABASES'
# 2. Importar el dump más reciente
DUMP=$(ls -t /mnt/hd2t/backups/dumps/nextcloud-*.sql.gz | head -1)
zcat "$DUMP" | docker exec -i nextcloud-db mysql -uroot -p"$MYSQL_ROOT_PASSWORD" nextcloud
# 3. Levantar el resto del stack
docker compose up -d
# 4. Comprobaciones desde dentro del contenedor de aplicación
docker exec -u www-data nextcloud-app php occ status
docker exec -u www-data nextcloud-app php occ maintenance:repair
docker exec -u www-data nextcloud-app php occ files:scan --all
```

> **`files:scan` es lento**: con 50-100 GB de ficheros tarda ~30-60 min. Lanzarlo y pasar al siguiente servicio mientras corre.

#### F.4 — Home Assistant (capa 6.3)

```bash
cd ~/homelab/homeassistant
make up
docker logs homeassistant 2>&1 | tail -50
# Test: https://hass.lan → frontend, login con la cuenta del operador.
# Verificación: que las automatizaciones aparezcan, que el dashboard cargue,
# que secrets.yaml esté descifrado correctamente.
```

> **Adaptador Zigbee USB**: si el adaptador Zigbee estaba pasado al contenedor por su `/dev/serial/by-id/...`, en la Pi nueva el _path_ puede cambiar. Verificar con `ls -l /dev/serial/by-id/` y ajustar el `devices:` del `docker-compose.yml` si hace falta. Es un _gap_ típico que sólo se descubre en el primer DR.

#### F.5 — Resto de servicios (capa 7)

Levantar el resto en lotes, en paralelo (cada `make up` corre en pocos segundos), validando con `make ps STACK=<stack>` que todo queda `Up (healthy)`:

```bash
for s in monitorizacion samba syncthing minio mosquitto zigbee2mqtt node-red \
         jellyfin navidrome audiobookshelf calibre-web stash \
         transmission prowlarr sonarr radarr \
         bookstack linkding paperless mealie stirling-pdf freshrss \
         homepage homarr; do
  cd ~/homelab/$s 2>/dev/null && make up && cd ~
done
```

Cualquier _stack_ que no esté en el repo o no tenga compose se ignora con el `&& cd ~` final.

> **Servicios con BD propia**: Paperless (Postgres), Bookstack (MariaDB), Mealie (Postgres) y BookStack tienen BDs que **necesitan import del dump** (no basta con copiar el datadir si el dump es la fuente de verdad de Borgmatic). Aplicar el patrón de F.3 (P/M/S según `docs/07-backups/03-backup-docker-volumes.md`).

### Fase G — Verificación post-recovery (30 min)

```markdown
## Verificación post-DR — YYYY-MM-DD HH:MM

- [ ] **Checklist de servicios críticos**
      Para cada uno: navegador → URL `*.lan` → login → acción típica.
      - Vaultwarden: leer una entrada cifrada.
      - Nextcloud: descargar un fichero antiguo.
      - Home Assistant: ver una entidad de un dispositivo conocido.
      - Pi-hole: dashboard → bloqueo de queries reciente > 0.
- [ ] **Sondas Uptime Kuma**
      Levantar Uptime Kuma y comprobar que las sondas pasan a verde una a una. Sondas en rojo > 5 min se investigan.
- [ ] **Borgmatic**
      `sudo systemctl list-timers borgmatic.timer` → próxima ejecución programada.
      `sudo borgmatic --dry-run --verbosity 1 2>&1 | tail -20` → fuente y destinos OK.
- [ ] **smartd y discos**
      `sudo smartctl -H /dev/disk/by-label/hd5t` → PASSED.
      `sudo smartctl -H /dev/disk/by-label/hd2t` → PASSED.
- [ ] **Tailscale**
      `tailscale status` → _tailnet_ visible, dispositivo aprobado.
      Probar acceso a `https://vault.lan/` desde un dispositivo del _tailnet_ que no esté en LAN.
- [ ] **Caddy CA local en clientes**
      Si la CA es nueva (Caddy regeneró), reaceptar en cada cliente. Si es la vieja restaurada, los clientes ya la aceptan.
- [ ] **fail2ban + nftables**
      `sudo fail2ban-client status sshd` → activo.
      `sudo nft list ruleset | head` → reglas aplicadas.
- [ ] **Tiempo total del DR**
      Timestamp final menos timestamp de Triage en bitácora.
- [ ] **Bitácora de DR**
      `~/homelab/docs/journal/YYYY-MM-DD-DR.md` con narrativa cronológica, _gaps_ encontrados, decisiones tomadas y mejoras propuestas.
- [ ] **Commit y push**
      `cd ~/homelab && git add . && git commit -m "ops: DR completo YYYY-MM-DD" && git push`
- [ ] **Si fue un drill (no un DR real)**: destruir limpiamente el entorno auxiliar (microSD usada para drill se reformatea, Pi auxiliar vuelve a su estado previo).
```

---

## Procedimientos por escenario

Cada uno es un subconjunto del procedimiento maestro; aquí sólo se enumeran las fases que **no** se aplican o que cambian.

### Procedimiento A — DR microSD (escenario 3 / 5)

`hd2t` y `hd5t` están intactos. Se sustituye sólo la microSD y, opcionalmente, la Pi.

- **Fase A**: triage, anotar timestamp.
- **Fase B**: B.1, B.2, B.3, B.4, B.5. **B.6 simplificado**: conectar los discos antiguos, restaurar `/etc/fstab` desde el doc de hardware, `mount -a`, verificar que `/mnt/hd2t/services/` está poblado. **B.7 simplificado**: estructura ya existe; sólo `swapon`. **B.8**: instalar borg/borgmatic.
- **Fase C — sólo C.7 y C.8**: clonar `~/homelab/` desde git remoto, restaurar `.env` desde el repo Borg local (porque el offsite no es necesario: `hd2t` con `backups/borg/homelab/` está disponible localmente). Comando equivalente:
  ```bash
  cd ~
  ARCHIVE=$(sudo borg list /mnt/hd2t/backups/borg/homelab/ --last 1 --short)
  sudo BORG_PASSPHRASE='...' borg extract \
       /mnt/hd2t/backups/borg/homelab/::"$ARCHIVE" \
       home/homelab/homelab
  sudo chown -R homelab:homelab ~/homelab
  ```
- **Fases D, E, F, G**: idénticas al procedimiento maestro.

RTO objetivo: **< 90 min** porque el grueso de los datos (`/mnt/hd2t/services/`) ya está en disco y no hay que descargarlo del offsite.

### Procedimiento B — DR de `hd2t` (escenario 4)

microSD intacta, Pi viva. `hd2t` se ha perdido (corrupción ext4 irrecuperable, fallo USB, robo del disco solo).

- **Fase A**: triage. **Importante**: si el `hd2t` aún se ve por USB pero da errores SMART o de I/O, primero `dd` a un disco de _spare_ para preservar lo que se pueda antes de reconstruir.
- **Fase B — sólo B.6 y B.7**: conectar el `hd2t` nuevo, particionar, formatear con etiqueta `hd2t`, ajustar `/etc/fstab`, montar, ejecutar `docs/01-sistema/04-estructura-directorios.md` y volver a crear el _swapfile_.
- **Fase C entera**: restaurar `/mnt/hd2t/services/` y `/mnt/hd2t/backups/dumps/` desde el offsite. **`/mnt/hd2t/backups/borg/homelab/` no se restaura**: se rebuildeará por Borgmatic en su próxima corrida (categoría especial: el repo local es _replica_ del offsite, no se respalda a sí mismo).
- **Fase D, E, F, G**: igual que el maestro pero ya con Docker preinstalado (no hace falta D.1).

RTO objetivo: **< 3 h**, dominado por la descarga del offsite.

### Procedimiento C — DR completo (escenario 6)

Es el procedimiento maestro al pie de la letra. RTO: **< 4 h**.

### Procedimiento D — Recuperación de `hd5t` (escenario 7)

`hd5t` perdido. La biblioteca de Stash es **categoría D** (`docs/07-backups/01-estrategia-backup.md`): voluminosa y reconstruible desde fuentes externas.

- Conectar el `hd5t` nuevo, particionar, formatear con etiqueta `hd5t`, ajustar `/etc/fstab`, montar (`docs/00-hardware/03-preparacion-discos.md`).
- Crear la rama `/mnt/hd5t/stash/{data,metadata,...}` con ownership `1000:1000` (`docs/01-sistema/04-estructura-directorios.md` → _hd5t_).
- Restaurar **únicamente** `services/stash/config/` y la BD de Stash desde el repo Borg (estaban en `hd2t`, son < 100 MB). Esto restaura el catálogo, las _scenes_ marcadas, los _tags_, los _performers_.
- Volver a colocar el contenido multimedia en `/mnt/hd5t/stash/data/` desde sus fuentes externas. Stash, al arrancar, cruzará el catálogo (que tiene los _hashes_ de archivo) con los ficheros recolocados y volverá a casar lo que sigue siendo el mismo fichero. Lo que no se case se reescanea.
- Lanzar un _full scan_ desde la UI de Stash para reindexar.

RTO: **horas a días**, dependiendo del tamaño y de la velocidad de la fuente externa. El resto del homelab sigue operativo durante todo este tiempo: la pérdida de `hd5t` no afecta a Vaultwarden, Nextcloud, Home Assistant, etc.

### Procedimiento E — DR de servicio único (escenarios 1, 2)

Un servicio se ha corrupto (BD ilegible, fichero borrado por error, _bug_ tras un update destruye el datadir). Se rebobina **ese servicio** a un _archive_ Borg previo, sin tocar el resto.

```bash
# 1. Parar el servicio.
cd ~/homelab/<stack>
docker compose down

# 2. Mover el datadir actual a un nombre `_broken` (no borrar — diagnóstico posterior).
sudo mv /mnt/hd2t/services/<stack> /mnt/hd2t/services/<stack>_broken_$(date +%Y%m%d-%H%M)

# 3. Elegir archive previo al daño.
ARCHIVE=$(sudo borg list /mnt/hd2t/backups/borg/homelab/ \
            --filter "endswith=ok" \
            --last 5 --short)
echo "$ARCHIVE"
# Si el daño se introdujo hace 2 días, escoger uno de hace 3.

# 4. Restaurar sólo ese subárbol.
cd /
sudo BORG_PASSPHRASE='...' borg extract --progress \
     /mnt/hd2t/backups/borg/homelab/::<archive-elegido> \
     mnt/hd2t/services/<stack>

# 5. Si el servicio tiene BD: importar el dump correspondiente del mismo timestamp.
# Para SQLite (Vaultwarden) el datadir contiene la BD: nada más que hacer.
# Para Postgres/MariaDB (Nextcloud, Bookstack, Paperless, Mealie):
zcat /mnt/hd2t/backups/dumps/<stack>-<fecha>.sql.gz | \
  docker exec -i <db-container> mysql -uroot -p"$ROOT_PASS" <database>
# (o psql según el motor; ver docs/07-backups/03-backup-docker-volumes.md)

# 6. Levantar.
cd ~/homelab/<stack>
docker compose up -d

# 7. Verificar funcionalidad básica antes de borrar el _broken_.
# Si todo OK, conservar _broken_ unos días (espacio permitido) y luego eliminarlo.
sudo rm -rf /mnt/hd2t/services/<stack>_broken_*  # cuando se confirme.
```

RTO: **< 30 min** para servicios pequeños (Vaultwarden, Linkding, FreshRSS); **< 60 min** para BDs grandes (Nextcloud).

### Procedimiento F — Repo Borg local corrupto, offsite OK (escenario 8)

El `borg check --verify-data` semanal del repo local ha fallado. El offsite es válido.

```bash
# 1. Renombrar el repo local roto (no borrarlo aún).
sudo mv /mnt/hd2t/backups/borg/homelab \
        /mnt/hd2t/backups/borg/homelab_corrupt_$(date +%Y%m%d)

# 2. Re-inicializar el repo local.
sudo BORG_PASSPHRASE='...' borg init --encryption=repokey-blake2 \
     /mnt/hd2t/backups/borg/homelab

# 3. Forzar una corrida de Borgmatic.
sudo borgmatic create --verbosity 1
# Tomará ~30-60 min porque vuelve a subir todo (no hay deduplicación con un repo nuevo).

# 4. Verificar.
sudo borg list /mnt/hd2t/backups/borg/homelab/
sudo borg check --verify-data /mnt/hd2t/backups/borg/homelab/

# 5. Borrar el repo corrupto.
sudo rm -rf /mnt/hd2t/backups/borg/homelab_corrupt_*
```

> **Por qué no `borg recreate` o intentar reparar el corrupto**: Borg permite "reparar" repositorios pero la fiabilidad después de eso es discutible. Es más seguro reconstruir desde cero. El offsite garantiza que no se pierde RPO durante este procedimiento (cualquier nuevo daño durante la reconstrucción se detecta en el siguiente `verify-data`).

### Procedimiento G — Repo Borg offsite corrupto, local OK (escenario 9)

Mismo procedimiento que F pero al revés: re-inicializar el repo offsite vía SSH al destino, dejar que Borgmatic vuelva a subirlo todo. Tarda más por el ancho de banda subida (asimétrico en conexiones domésticas), 6-24 h. Durante ese tiempo el homelab está sin offsite — riesgo asumido y temporal.

---

## Plantilla de bitácora de DR

Fichero `~/homelab/docs/journal/YYYY-MM-DD-DR.md`. **No** se mezcla con la bitácora mensual: un DR merece su propia entrada.

```markdown
# DR — YYYY-MM-DD

## Resumen
- Escenario: <#> (microSD muerta / hd2t perdido / DR completo / servicio X corrupto / ...).
- Inicio del triage: HH:MM.
- Fin del DR (servicios críticos en verde): HH:MM.
- Tiempo total: <duración>.
- Servicios afectados durante el DR: <lista>.
- Datos perdidos respecto al último backup: <ninguno / N horas / N días>.

## Causa raíz (lo mejor que se sepa al cierre)
<descripción narrativa: qué falló, cuándo, por qué se cree que pasó>

## Cronología
- HH:MM — descubrí el problema (alerta X / observación Y).
- HH:MM — fase de triage cerrada, decisión: <procedimiento aplicado>.
- HH:MM — fase B completada.
- HH:MM — fase C completada (Borg conectado al offsite).
- HH:MM — Vaultwarden de vuelta.
- HH:MM — Nextcloud de vuelta tras files:scan (40 min).
- HH:MM — todos los servicios en verde en Uptime Kuma.

## Decisiones tomadas
- Decidí restaurar el archive de hace 2 días, no el de ayer, porque ...
- No restauré X servicio de momento porque ...

## Gaps detectados (mejoras para el próximo DR / ronda mensual)
- [ ] El path del adaptador Zigbee cambió; documentar `udev rule` por id estable.
- [ ] La passphrase de Borg estaba en Bitwarden cloud pero la clave SSH no; añadirla.
- [ ] El dump de Bookstack faltaba del 2026-04-15 al 17 — investigar Borgmatic logs.

## Servicios que se han añadido a la ronda mensual siguiente
- [ ] Drill de restauración de Bookstack (no se hizo en este DR por tiempo).
- [ ] Validar que el `files:scan` de Nextcloud sigue tardando lo previsible.

## Estado al cierre
- Repo Borg local: ok (último archive: HH:MM tras DR).
- Repo Borg offsite: ok.
- SMART hd5t/hd2t: PASSED.
- Tailscale: dispositivo `homelab` re-aprobado.
- Caddy CA: la antigua se restauró → clientes no necesitan reaceptar.
```

---

## Troubleshooting

### `borg extract` falla con `Failed to authenticate`

La passphrase introducida no coincide con la del repo. Confirmar con `borg info ssh://...:repo/`. Si persiste: revisar Vaultwarden, gestor externo y copia papel — alguna de las tres tiene la passphrase correcta. Si las tres dan distintas, hay un fallo de custodia anterior al desastre que ahora bloquea el DR — única solución es reintentar con todas las que se hayan usado en el pasado y, si sigue fallando, asumir pérdida del repo (escenario peor).

### `borg list` cuelga sin errores

Conexión SSH lenta o saturada. Probar con `BORG_RSH='ssh -v -i ...'` para ver el handshake. Confirmar que la cuenta del proveedor offsite no ha sido suspendida (ej. impago, abuso detectado). Si es lentitud genuina, paciencia: `borg list` puede tardar varios minutos en repos con miles de archives.

### `docker compose up` falla con `network homelab_macvlan not found`

La macvlan no se recreó en la fase D.2. Volver a crearla con los parámetros del doc `docs/03-red/01-macvlan.md`.

### Pi-hole macvlan no responde a peticiones DNS

El _shim_ macvlan en el host (necesario para que el host pueda hablar con el contenedor macvlan) no está creado. Ver `docs/03-red/01-macvlan.md` → _interfaz macvlan-shim_. Crear:

```bash
sudo ip link add homelab_shim link eth0 type macvlan mode bridge
sudo ip addr add 192.168.1.X/32 dev homelab_shim   # X = IP libre dedicada
sudo ip link set homelab_shim up
sudo ip route add 192.168.1.Y dev homelab_shim     # Y = IP del Pi-hole
```

Y persistirlo en `/etc/network/interfaces.d/` o systemd-networkd según corresponda.

### Nextcloud `php occ` da `An exception occurred while executing a query`

La BD MariaDB no se importó correctamente o el `.env` apunta a contraseñas distintas de las del dump. Verificar:

```bash
docker exec nextcloud-db mysql -uroot -p"$MYSQL_ROOT_PASSWORD" \
  -e 'SHOW DATABASES; SELECT count(*) FROM nextcloud.oc_users;'
```

Si la BD existe pero está vacía, el `zcat ... | mysql nextcloud` se lanzó contra una DB equivocada o la BD nextcloud se creó con `CREATE DATABASE` por la imagen y aplastó la importación. Truncar y reimportar:

```bash
docker exec nextcloud-db mysql -uroot -p"$MYSQL_ROOT_PASSWORD" \
  -e 'DROP DATABASE nextcloud; CREATE DATABASE nextcloud;'
zcat /mnt/hd2t/backups/dumps/nextcloud-LATEST.sql.gz | \
  docker exec -i nextcloud-db mysql -uroot -p"$MYSQL_ROOT_PASSWORD" nextcloud
```

### Home Assistant `secrets.yaml` aparece encriptado o con basura

Si Home Assistant usa `secrets.yaml` cifrado vía `keyring`, tras el DR el _keyring_ del sistema es nuevo y no descifra. Verificar `docs/08-domotica/01-home-assistant.md` para la política de secretos: en el homelab los secretos van por **variables de entorno del compose** (no `secrets.yaml` cifrado), precisamente para evitar este caso. Si por alguna razón hay un `secrets.yaml` cifrado, el operador lo descifra a mano con la clave que custodia en Vaultwarden.

### Tailscale rechaza el dispositivo nuevo con `tailnet lock`

Si el _tailnet lock_ está activo (firma de dispositivos), un dispositivo nuevo necesita ser firmado por uno existente. Si la Pi original era el _signing node_, hay que recuperar la firma desde el panel Tailscale o usar otro dispositivo del _tailnet_ (un portátil, un móvil) para firmar. Documentar esta dependencia en `docs/03-red/05-tailscale.md`.

### Caddy regenera la CA y todos los clientes ven `NET::ERR_CERT_AUTHORITY_INVALID`

La rama `services/caddy/data/caddy/pki/authorities/local/` no se restauró del _archive_. O bien volver a aceptar la CA en cada cliente (es la solución pragmática), o restaurar selectivamente esa rama desde un _archive_ Borg previo y reiniciar Caddy.

---

## Verificación final (cierre de la fase 13.2)

Antes de dar la fase 13.2 por cerrada, ejecutar **una vez** un drill del procedimiento maestro o, como mínimo, un drill del procedimiento E sobre dos servicios distintos. La razón: redactar el doc no es lo mismo que haber recorrido los pasos al menos una vez.

- [ ] Existe en Vaultwarden la entrada "Homelab — Borg passphrase" y la entrada "Homelab — Borgmatic SSH key (offsite)" con la clave privada adjunta.
- [ ] Existe una **copia papel** de la passphrase de Borg en sobre cerrado / caja fuerte. Anotada la fecha de generación.
- [ ] El repo `~/homelab/` está pusheado a un git remoto y el último _commit_ es de hace < 7 días. Si no, hacer `git push` antes de cerrar esta fase.
- [ ] Se ha ejecutado al menos un **drill de procedimiento E** (rebobinar un servicio único a un _archive_ previo) sobre dos servicios distintos: uno con SQLite (Vaultwarden) y uno con BD relacional (Bookstack o Paperless o Mealie). Tiempos anotados en bitácora.
- [ ] Se ha ejecutado al menos un **drill parcial de procedimiento C** (DR completo) en una Pi auxiliar o en una microSD limpia, tocando como mínimo las fases B y C hasta tener `~/homelab/` y `/mnt/hd2t/services/` poblados desde el offsite. No es necesario llegar a "todo en verde" en este primer drill, basta con confirmar que el offsite responde y que la passphrase descifra. Anotar cualquier _gap_ encontrado.
- [ ] El operador tiene en su calendario personal el evento anual "Homelab — DR drill completo" (medio día), conectado al "cumpleaños del homelab" definido en `docs/13-operaciones/01-mantenimiento-periodico.md`.
- [ ] Esta fase se cierra con commit:
  ```bash
  cd ~/homelab
  git add docs/13-operaciones/02-disaster-recovery.md docs/journal/
  git commit -m "feat(ops): bootstrap procedimiento de disaster recovery"
  git push
  ```

A partir de aquí, las siguientes secciones de la fase 13 (`03-rendimiento-pi5.md`, `04-red-y-puertos.md`) cubrirán la auditoría de rendimiento de la Pi y el mapa de puertos/firewall del homelab.

---

## Referencias

- BorgBackup — _Restoring archives_: <https://borgbackup.readthedocs.io/en/stable/usage/extract.html>
- BorgBackup — _Repository check_: <https://borgbackup.readthedocs.io/en/stable/usage/check.html>
- Borgmatic — _Restore_: <https://torsion.org/borgmatic/docs/how-to/extract-a-backup/>
- Docker — _Restore data from backups_: <https://docs.docker.com/engine/storage/volumes/#back-up-restore-or-migrate-data-volumes>
- Nextcloud — _Restoring backup_: <https://docs.nextcloud.com/server/latest/admin_manual/maintenance/restore.html>
- Home Assistant — _Backup and restore_: <https://www.home-assistant.io/common-tasks/general/#backups>
- Tailscale — _Add a device to your tailnet_: <https://tailscale.com/kb/1017/install>
- Caddy — _Trust the local CA_: <https://caddyserver.com/docs/automatic-https#local-https>
- Raspberry Pi OS — _Imager_ y configuración headless: <https://www.raspberrypi.com/documentation/computers/getting-started.html>
