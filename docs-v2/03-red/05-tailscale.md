# Tailscale

## Descripción

Despliegue de **Tailscale** como **única vía de acceso remoto** al homelab. La Pi se incorpora a un *tailnet* personal (mesh WireGuard gestionado por el plano de control de Tailscale) y queda accesible desde cualquier dispositivo que también esté autenticado en ese mismo tailnet (móvil, portátil, otro Pi). **No se abre ningún puerto en el router**, no se publica DNS dinámico, no se expone la Pi a internet: el plano de datos viaja directamente peer-to-peer (o a través de los DERP relays de Tailscale como fallback) y siempre cifrado con WireGuard.

Tailscale se instala **como paquete del sistema en el host** (no en contenedor) y se integra con [`04-caddy.md`](./04-caddy.md) suministrando certificados Let's Encrypt válidos para `*.${TS_DOMAIN}` mediante el subcomando `tailscale cert`. Caddy ya dejó preparada en su §4 y §5 la estructura para consumirlos: snippet `tailscale_tls`, bind mount `/mnt/hd2t/services/proxy/tailscale-certs/` (read-only desde el contenedor) y bloques `pi.{$TS_DOMAIN}` / `jellyfin.{$TS_DOMAIN}` comentados a la espera de este documento.

Por qué exactamente esta arquitectura, y no otra:

1. **Host vs. contenedor.** Tailscale es **más útil cuanto más cerca del kernel viva**. En modo host, expone una interfaz `tailscale0` que cualquier proceso (incluido cualquier contenedor publicado al host) atiende automáticamente, sin reglas extra. En contenedor con `network_mode: host` se logra lo mismo pero se añade un paso de empaquetado y se complica la integración con `tailscale cert` (necesita escribir en un volumen compartido con Caddy). En contenedor con su propia red Docker (`tailscale/tailscale` con `userspace-networking`), la interfaz no aparece en el host y se necesita `tailscale serve`/`tailscale funnel` o un sidecar por servicio. **Para un homelab en Pi 5 con todo en el mismo host, el modo paquete es el más simple y robusto** — y es el modo que Tailscale recomienda para servidores fijos.
2. **Sin exposición a internet.** Tailscale crea un *tailnet* privado con identidades verificadas (cuenta Google/Microsoft/GitHub/SSO). Solo los dispositivos invitados al tailnet ven la Pi. No hay ningún DNS público apuntando a una IP residencial, ningún puerto del router abierto, ninguna negociación de NAT vía UPnP. Concuerda con el alcance del homelab definido en [`../../PLAN.md`](../../plans/PLAN.md) (LAN + VPN mesh).
3. **MagicDNS resuelve los nombres por nosotros.** Una vez activado en el panel de administración, el tailnet entrega nombres automáticos `pi.<tailnet>.ts.net` que resuelven a las IPs `100.64.0.0/10` privadas del tailnet. **No** se necesita Pi-hole para que los peers de Tailscale lleguen a la Pi: los clientes Tailscale resuelven `*.<tailnet>.ts.net` directamente contra el daemon `tailscaled`.
4. **HTTPS válido sin Let's Encrypt directo.** Tailscale opera como **sub-CA delegada de Let's Encrypt** para los nombres `*.<tailnet>.ts.net` (vía DNS-01 en infraestructura propia). El comando `tailscale cert <fqdn>` baja un par cert/key firmado por *Let's Encrypt R3*, válido ~90 días, sin que el operador toque DNS ni 80/443 públicos. Caddy los monta en sus bloques `*.${TS_DOMAIN}` con `tls /data/tailscale-certs/<host>.crt /data/tailscale-certs/<host>.key`.
5. **Sin "subnet router" ni "exit node".** La Pi expone **únicamente sus propios servicios** (los que viven en ella). No se anuncia la subred LAN `192.168.1.0/24` con `--advertise-routes`: hacerlo permitiría que los peers Tailscale alcanzaran cualquier dispositivo de casa (impresora, cámaras, otra Pi, dispositivos IoT), lo cual amplía la superficie de exposición sin necesidad real (los servicios homelab ya viven en la Pi). Tampoco se anuncia como `--advertise-exit-node`: el operador no quiere enrutar todo el tráfico de internet de sus dispositivos a través de la conexión doméstica.
6. **Watchtower no aplica.** Tailscale corre como paquete `apt`, no como imagen Docker. Las actualizaciones se gestionan vía `unattended-upgrades` ([`../01-sistema/03-seguridad-base.md`](../01-sistema/03-seguridad-base.md) §5) **excluyendo** el repo de Tailscale (los upgrades de WireGuard/userland deben validarse manualmente para no perder el tailnet). Ver §3.4.
7. **`tailscale ssh` opcional.** La Pi ya tiene SSH endurecido a nivel de host ([`../01-sistema/03-seguridad-base.md`](../01-sistema/03-seguridad-base.md)) con clave pública y `fail2ban`. El subcomando `tailscale ssh` añade autenticación por identidad de tailnet (sin claves), útil pero **redundante** con la SSH endurecida. Se documenta como **opcional** en §11; el flujo principal sigue siendo SSH-clave-pública desde otro nodo Tailscale.

> **Alcance**: este documento (a) instala el paquete Tailscale en el host, (b) autentica la Pi en el tailnet con un *auth key* generado en el panel de administración, (c) habilita MagicDNS y certificados HTTPS en la organización Tailscale, (d) genera el primer cert HTTPS para `pi.${TS_DOMAIN}` y lo coloca en `/mnt/hd2t/services/proxy/tailscale-certs/`, (e) configura un *systemd timer* que renueva los certs cada semana y recarga Caddy, (f) descomenta los bloques Tailscale del `Caddyfile` de Caddy y (g) verifica acceso end-to-end desde un peer remoto. **No** se anuncia subred ni exit node. **No** se configura Tailscale Funnel (exposición pública gestionada por Tailscale): el homelab no necesita ser accesible desde fuera del tailnet.

---

## Requisitos Previos

- **Cuenta Tailscale** ya creada en https://login.tailscale.com/ (plan Personal gratuito basta: hasta 100 dispositivos, 3 usuarios; sobra para un homelab unipersonal). El registro se hace contra un proveedor de identidad existente (Google, Microsoft, GitHub, Apple, OIDC).
- **Hostname `pi`** ya configurado en la Pi según [`../01-sistema/02-configuracion-inicial.md`](../01-sistema/02-configuracion-inicial.md). Tailscale tomará por defecto este hostname para nombrar la máquina en el tailnet (`pi.<tailnet>.ts.net`).
- **Sistema base seguro** según [`../01-sistema/03-seguridad-base.md`](../01-sistema/03-seguridad-base.md): `ufw` con `deny incoming` por defecto, `fail2ban` con jail SSH, `unattended-upgrades` activo. Tailscale **no** requiere abrir puertos en `ufw`: la interfaz `tailscale0` que crea no atraviesa las reglas del firewall del host por defecto en Bookworm (`ufw before.rules` no la cubre, ver §4.5 de seguridad-base).
- **DNS funcional para `apt`** según [`../03-red/02-pihole.md`](./02-pihole.md) §6.6: la Pi resuelve `pkgs.tailscale.com` con fallback a `1.1.1.1` si Pi-hole cae. Se necesita en este doc para `apt update` y para que `tailscaled` contacte con `controlplane.tailscale.com` al arrancar.
- **Caddy desplegado** según [`04-caddy.md`](./04-caddy.md), con:
  - El stack `proxy` corriendo `(healthy)`.
  - El bind mount `/mnt/hd2t/services/proxy/tailscale-certs/` existente (creado en §3.2 de Caddy), vacío, propietario `homelab:homelab`, modo `770`.
  - Snippet `snippets/tailscale_tls` ya escrito (§4.2 de Caddy).
  - Bloques `pi.{$TS_DOMAIN}` y `jellyfin.{$TS_DOMAIN}` **comentados** en el `Caddyfile` (§4.3 de Caddy). Este doc los descomenta tras generar los certs.
  - Variable `TS_HOSTNAME=` vacía en `/mnt/hd2t/services/proxy/.env` (§2.2 de Caddy). Este doc la rellena.
- **Discos `hd2t` montados** según [`../00-hardware/03-preparacion-discos.md`](../00-hardware/03-preparacion-discos.md). Los certs generados se persisten en `hd2t`, así que un `hd2t` no montado al arrancar = certs no accesibles a Caddy.
- **Acceso al panel de administración Tailscale** (https://login.tailscale.com/admin) desde cualquier navegador (no necesariamente desde la Pi). Se usa para:
  - Generar el *auth key* de §4.2.
  - Activar MagicDNS y HTTPS Certificates (§3.1).
  - Definir los *tags* de ACL (§9).
- **Comprobaciones rápidas**:
  ```bash
  # Hostname correcto:
  hostnamectl --static
  # Esperado: pi

  # Conectividad a controlplane.tailscale.com (no se necesita autenticación todavía):
  curl -fsSI https://controlplane.tailscale.com/ -o /dev/null -w '%{http_code}\n'
  # Esperado: 404 (el host responde, pero no atiende a GET / sin auth: 404 es OK).

  # Caddy ya levantado:
  docker compose -f ~/homelab/stacks/proxy/docker-compose.yml ps caddy
  # Esperado: Up X (healthy)

  # Bind mount de tailscale-certs accesible:
  ls -ld /mnt/hd2t/services/proxy/tailscale-certs
  # Esperado: drwxrwx--- ... homelab homelab ... tailscale-certs
  ```

### Decisiones de diseño asumidas

| Decisión | Valor por defecto | Justificación |
|---|---|---|
| Modo de instalación | **Paquete `apt` en el host** (`tailscale` + `tailscale-archive-keyring`) | Más simple, kernel module nativo, `tailscale0` visible al host y a cualquier contenedor con `network_mode: host`. El modo contenedor (`tailscale/tailscale`) añade complejidad para `tailscale cert` (compartir un volumen con Caddy) sin beneficio real. |
| Repositorio | **Oficial: `pkgs.tailscale.com/stable/debian bookworm main`** | Repo estable, firmado con la clave oficial. Frecuencia de releases: ~1 cada 2-3 semanas. La rama `unstable` se descarta para un homelab "set & forget". |
| Versión inicial | **Última stable** al desplegar | El paquete `apt` siempre instala la latest del canal `stable`. Los upgrades futuros se gestionan en §10.4 de forma controlada (no automática). |
| Autenticación | **Auth key (no expira durante 90 días, single-use, pre-aprobado, taggeado `tag:homelab`)** | Más reproducible que `tailscale up` interactivo (que abre un navegador). Permite scriptear el primer `up`. *Single-use*: tras consumirlo, el key queda revocado, evitando reuso si se filtra. |
| Hostname en el tailnet | **`pi`** (heredado de `hostnamectl`) | Coincide con el nombre del host. Resultado: `pi.<tailnet>.ts.net`. |
| MagicDNS | **Activado** en el panel de administración | Necesario para que `tailscale cert pi.<tailnet>.ts.net` funcione; el panel verifica el FQDN contra MagicDNS antes de emitir. También permite que los peers resuelvan nombres del tailnet sin DNS interno. |
| HTTPS Certificates | **Activado** en el panel de administración | Lo activa una vez el operador en el panel; a partir de ahí cualquier nodo del tailnet puede pedir certs Let's Encrypt para su FQDN. |
| `--advertise-routes` | **NO usado** | La Pi expone solo sus propios servicios. Anunciar `192.168.1.0/24` ampliaría el alcance del tailnet a todos los dispositivos de casa, sin necesidad. |
| `--advertise-exit-node` | **NO usado** | No se quiere enrutar tráfico de internet de los peers por la conexión doméstica. |
| `--ssh` | **NO usado en el `up` principal** | SSH del host ya está endurecido con clave pública + `fail2ban`. Activar `tailscale ssh` añade un sistema paralelo de auth (basado en identidad de tailnet) sin retirar el primero. Documentado como opcional en §11. |
| `--accept-routes` | **`false`** | La Pi no necesita aceptar rutas anunciadas por otros peers. Si en el futuro se añade un segundo *subnet router* en el tailnet, se podrá habilitar puntualmente. |
| `--accept-dns` | **`true`** (default) | La Pi acepta el resolver DNS del tailnet (MagicDNS). **Pero**: Pi-hole sigue siendo el resolver primario del host (vía `/etc/resolv.conf` o `systemd-resolved`, [`02-pihole.md`](./02-pihole.md) §6.6). MagicDNS solo se usa para resolver `*.<tailnet>.ts.net` desde la Pi (ver §6.4 sobre cómo conviven). |
| Tags ACL | **`tag:homelab`** | Identifica este nodo como "servidor del homelab" en futuras políticas ACL. Se asigna en el auth key (§4.2) y en la sección Tags del panel. |
| Cert renewal | **Systemd timer semanal** (`OnCalendar=Sun *-*-* 03:30:00`) | Tailscale recomienda renovar antes de los 60 días de vida (los certs expiran a los 90). Una vez por semana es holgura sobrada. La franja de las 03:30 evita solapar con `unattended-upgrades` (04:00) y con backups de Borg (Fase 7). |
| Cert post-renewal hook | **`docker exec caddy caddy reload`** | Caddy v2 carga los certs desde disco en cada handshake TLS, pero **mantiene** la cadena anterior en cache hasta el próximo reload. Forzar `caddy reload` tras renovar garantiza que la nueva cadena es la que se sirve, sin interrupción de conexiones activas. |
| Persistencia de certs | **`/mnt/hd2t/services/proxy/tailscale-certs/`** (en hd2t) | Bind mount ya existente desde Caddy. Los certs **no son** secretos críticos (son cadenas Let's Encrypt públicamente verificables) pero su pérdida obliga a regenerar; mejor en hd2t (con backup) que en microSD. |
| Tailscale state | **`/var/lib/tailscale/`** (default, en microSD) | Contiene la node key (privada) y la state DB. Pequeño (<1 MB), backupeable; si se pierde, basta `tailscale up` con un nuevo auth key para reincorporar la Pi al tailnet (con un nombre nuevo o tras "remove device" en el panel). No se mueve a hd2t para no acoplar el arranque de `tailscaled` al montaje de hd2t. |
| Backup de la node key | **Sí, vía Borg** (snapshot semanal de `/var/lib/tailscale/`) | Permite recuperar la identidad exacta del nodo (mismo nombre, mismas ACLs) sin pasar por el panel. Documentado en §10. |
| Logs | **Journald** del servicio `tailscaled.service` | El daemon ya integra con journald. Para análisis histórico (si interesa) se reenvía a Loki en Fase 5+. |
| `ufw` | **Sin reglas adicionales** | La interfaz `tailscale0` no atraviesa `ufw` por defecto en Bookworm; el tráfico VPN llega directamente a los listeners de los servicios. Si el operador endureciera `ufw before.rules` para incluir `tailscale0`, se documentaría aquí — pero por defecto, no hace falta. Caddy ya autoriza `192.168.1.0/24` en 80/443; el tráfico Tailscale entra por la IP `100.x.y.z` del nodo y llega a Caddy directamente. |
| Funnel (exposición pública) | **NO activado** | Funnel publicaría servicios del tailnet a internet pasando por los nodos de Tailscale. El homelab **no** quiere exposición pública: contradiría el alcance LAN+VPN. |

---

## 1. Resumen de la arquitectura

```
                   Internet
                       │
                       │ (control plane: HTTPS 443)
                       ▼
              login.tailscale.com
                       │
                       │ (key exchange, ACLs, DNS)
                       ▼
        ┌──────────────────────────────┐
        │       Tailnet privado        │
        │   100.64.0.0/10 (CGNAT)      │
        │                              │
        │   pi.tailnet.ts.net          │
        │   100.64.x.y                 │
        │                              │
        │   movil.tailnet.ts.net       │
        │   100.64.a.b                 │
        │                              │
        │   portatil.tailnet.ts.net    │
        │   100.64.c.d                 │
        └─────────────┬────────────────┘
                      │
        (WireGuard p2p directo, o DERP relay si NAT)
                      │
                      ▼
   ┌──────────────────────────────────────────┐
   │        Pi 5 (eth0 = 192.168.1.10)        │
   │                                          │
   │   tailscale0 = 100.64.x.y                │
   │   ↑ creada por tailscaled (kernel)       │
   │                                          │
   │   ┌──────────  caddy  ──────────┐        │
   │   │ ports: 80, 443 (en 0.0.0.0) │        │
   │   │ atiende:                    │        │
   │   │  - LAN 192.168.1.10:443     │        │
   │   │  - VPN 100.64.x.y:443       │        │
   │   │ tls: cert Let's Encrypt     │        │
   │   │   firmado por R3, vía       │        │
   │   │   `tailscale cert`          │        │
   │   └─────────────────────────────┘        │
   │                                          │
   │   (resto de servicios homelab)           │
   └──────────────────────────────────────────┘
```

Tres invariantes:

- **Sin puertos abiertos hacia internet.** Toda llegada externa pasa por el plano de control de Tailscale, que negocia un peer-to-peer cifrado con WireGuard. El router doméstico no se toca.
- **Caddy es el único punto de terminación TLS.** Tanto en LAN (`*.lan` con CA interna) como en Tailscale (`*.${TS_DOMAIN}` con cert Let's Encrypt). Mismo `Caddyfile`, distintos snippets.
- **MagicDNS para los peers, Pi-hole para la Pi.** Los peers Tailscale resuelven `pi.${TS_DOMAIN}` vía MagicDNS embebido en el cliente Tailscale. La Pi sigue resolviendo todo lo demás vía Pi-hole (con MagicDNS como split-DNS de respaldo solo para `*.${TS_DOMAIN}`, ver §6.4).

---

## 2. Plan de variables y archivos

Tailscale **no** tiene un stack Docker en este modo, así que no hay `docker-compose.yml`. Los artefactos versionables viven en `~/homelab/scripts/tailscale/` (scripts y unidades systemd) y los datos persistentes en `hd2t`.

```
~/homelab/scripts/tailscale/                  # versionable en git
├── tailscale-cert-renew.sh                   # script de renovación (§7)
├── tailscale-cert-renew.service              # systemd service unit
└── tailscale-cert-renew.timer                # systemd timer unit (semanal)
```

```
/var/lib/tailscale/                           # state del daemon (microSD)
├── tailscaled.state                          # node key (privada)
└── ...

/mnt/hd2t/services/proxy/tailscale-certs/     # certs Let's Encrypt (creado en 04-caddy.md)
├── pi.tailnet.ts.net.crt
└── pi.tailnet.ts.net.key

/mnt/hd2t/services/tailscale/                 # creado en 04-estructura-directorios.md
└── (vacío de momento; reservado para snapshots manuales o backups locales)
```

### 2.1. Variables consumidas

Este doc **no introduce nuevas variables de entorno globales**. Reutiliza las ya definidas en stacks anteriores:

- `TS_DOMAIN` (en `proxy/.env`, p. ej. `tailnet.ts.net`) — se sustituye por el nombre real del tailnet del operador, p. ej. `tailfb12cd.ts.net` (lo asigna Tailscale al crear la cuenta; visible en https://login.tailscale.com/admin/dns).
- `TS_HOSTNAME` (en `proxy/.env`, vacío hasta este doc) — se rellena con el FQDN final, p. ej. `pi.tailfb12cd.ts.net`.

> **Nota sobre `TS_DOMAIN`**: Tailscale asigna a cada tailnet un dominio del tipo `<tag>.ts.net` (Personal) o `<dominio>` (Business con dominio propio verificado). Para un homelab Personal, ir a https://login.tailscale.com/admin/dns/ y leer el dominio asignado. La cadena de ejemplo `tailnet.ts.net` que se ha venido usando en los docs anteriores es un **placeholder**: se reemplaza por el real en este punto.

### 2.2. Actualizar `proxy/.env` con el `TS_DOMAIN` y `TS_HOSTNAME` reales

Tras leer el tailnet en https://login.tailscale.com/admin/dns/ (campo "Tailnet name", por ejemplo `tailfb12cd.ts.net`):

```bash
# Ajustar TS_DOMAIN al valor real del tailnet (sin "https://").
sudo sed -i 's|^TS_DOMAIN=.*|TS_DOMAIN=tailfb12cd.ts.net|' \
  /mnt/hd2t/services/proxy/.env

# Rellenar TS_HOSTNAME con el FQDN de la Pi.
sudo sed -i 's|^TS_HOSTNAME=.*|TS_HOSTNAME=pi.tailfb12cd.ts.net|' \
  /mnt/hd2t/services/proxy/.env

# Verificar:
grep -E '^(TS_DOMAIN|TS_HOSTNAME)=' /mnt/hd2t/services/proxy/.env
# Esperado:
# TS_DOMAIN=tailfb12cd.ts.net
# TS_HOSTNAME=pi.tailfb12cd.ts.net
```

> Si el operador usa un tailnet "Business" con dominio propio verificado (p. ej. `homelab.example.com`), `TS_DOMAIN=homelab.example.com` y los certs se emiten para `pi.homelab.example.com`. Las instrucciones siguen siendo idénticas.

### 2.3. Por qué no se mueve `/var/lib/tailscale/` a hd2t

El estado del daemon (`tailscaled.state`) contiene la **node key** privada. Es:

- Pequeño (<1 MB).
- Crítico para no tener que re-autenticar tras un reboot.
- Necesario **antes** de que `/mnt/hd2t/` esté montado, porque `tailscaled.service` arranca pronto en el boot.

Acoplar `/var/lib/tailscale/` a hd2t (vía symlink o `BindPaths=`) introduce un riesgo de orden de boot que no compensa: si hd2t no se monta, Tailscale no arranca, la VPN cae justo cuando el operador la necesita para diagnosticar. Se queda en microSD y se respalda vía Borg (§10).

---

## 3. Configuración del panel de administración Tailscale

Antes de tocar la Pi, **dejar listas tres cosas en el panel** (https://login.tailscale.com/admin).

### 3.1. Activar MagicDNS y HTTPS Certificates

1. Navegar a `DNS` (https://login.tailscale.com/admin/dns/).
2. Bajar a **MagicDNS** → activar (botón `Enable MagicDNS`). Confirmar el dominio asignado al tailnet (`tailfb12cd.ts.net` en el ejemplo). Apuntar este valor: es el `TS_DOMAIN` real.
3. Bajar a **HTTPS Certificates** → activar (botón `Enable HTTPS`). Aparece un mensaje de confirmación recordando que los certs son emitidos por Let's Encrypt vía DNS-01.

> Si MagicDNS está desactivado, `tailscale cert` falla con `MagicDNS not enabled`. Si HTTPS Certificates está desactivado, `tailscale cert` falla con `HTTPS not enabled for tailnet`.

### 3.2. Definir el tag `tag:homelab` en las ACLs

1. Navegar a `Access Controls` (https://login.tailscale.com/admin/acls/).
2. En la pestaña *Tags*, añadir bajo `"tagOwners"`:
   ```jsonc
   {
       "tagOwners": {
           // ...lo que ya hubiera...
           "tag:homelab": ["autogroup:admin"],
       },
   }
   ```
   Esto autoriza a cualquier admin del tailnet a asignar el tag `tag:homelab` a un nodo. Sin este paso, el auth key (§4.2) que pide `--advertise-tags=tag:homelab` será rechazado con `tag not allowed`.
3. Guardar (`Save`). Tailscale valida la sintaxis HuJSON.

### 3.3. (Opcional) Política ACL mínima

Por defecto, todos los nodos del tailnet pueden hablarse entre sí. Si se quisiera restringir (p. ej. solo permitir a los dispositivos personales acceder a `tag:homelab`):

```jsonc
{
    "acls": [
        // Admin → todo
        {"action": "accept", "src": ["autogroup:admin"], "dst": ["*:*"]},
        // Tag homelab solo recibe tráfico de admin
        // (los nodos taggeados no inician conexiones a otros nodos)
        {"action": "accept", "src": ["autogroup:admin"], "dst": ["tag:homelab:*"]},
    ],
}
```

> Para un homelab unipersonal con todos los dispositivos en la misma cuenta, **no es estrictamente necesario** definir ACLs específicas: la política por defecto (`accept all`) es suficiente y simplifica la operativa. Documentado por completitud.

### 3.4. Excluir el repo de Tailscale de `unattended-upgrades`

Las actualizaciones de Tailscale a veces requieren un reinicio del servicio (rotación de relés, cambios en MagicDNS). Aplicarlas a las 04:00 sin supervisión puede dejar la VPN caída. La política de [`../01-sistema/03-seguridad-base.md`](../01-sistema/03-seguridad-base.md) §5 ya limita `unattended-upgrades` a repositorios Debian (`Origins-Pattern`); este doc añade Tailscale **explícitamente** a la lista de exclusiones para que sea evidente:

Editar `/etc/apt/apt.conf.d/51unattended-upgrades-tailscale` (nuevo fichero):

```bash
sudo tee /etc/apt/apt.conf.d/51unattended-upgrades-tailscale > /dev/null <<'EOF'
// Excluye Tailscale de unattended-upgrades.
// Razonado en docs/03-red/05-tailscale.md §3.4.
Unattended-Upgrade::Package-Blacklist {
    "tailscale";
    "tailscale-archive-keyring";
};
EOF
```

Validar la sintaxis:

```bash
sudo unattended-upgrades --dry-run --debug 2>&1 | grep -i tailscale
# Esperado: 'tailscale' está en la lista de bloqueados (al menos una mención).
```

---

## 4. Instalación de Tailscale en el host

### 4.1. Añadir el repositorio oficial

Tailscale provee un script oficial que añade el repo y la clave GPG. Para auditarlo antes de ejecutar, descargarlo a un fichero y revisarlo:

```bash
curl -fsSL https://tailscale.com/install.sh -o /tmp/tailscale-install.sh
less /tmp/tailscale-install.sh
# Verificar que solo añade el keyring y el repo, e instala 'tailscale'.
```

Alternativa **manual** (recomendada, no depende del script):

```bash
# 1. Clave GPG oficial (Bookworm).
curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.noarmor.gpg \
  | sudo tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null

# 2. Lista del repo.
sudo tee /etc/apt/sources.list.d/tailscale.list > /dev/null <<'EOF'
deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/debian bookworm main
EOF

# 3. Update.
sudo apt update
```

Verificar que el repo es visible y firmado:

```bash
apt-cache policy tailscale | head -10
# Esperado: 'Candidate' apuntando a una versión 1.x.y, '500 https://pkgs.tailscale.com/stable/debian bookworm/main arm64 Packages'.
```

### 4.2. Generar el auth key en el panel

1. Navegar a `Settings → Keys` (https://login.tailscale.com/admin/settings/keys).
2. Click `Generate auth key…`.
3. Configurar:
   - **Reusable**: `No` (single-use, mejor seguridad).
   - **Ephemeral**: `No` (la Pi es un nodo persistente, no quiere que se borre al desconectarse).
   - **Pre-approved**: `Yes` (no requiere aprobación manual del admin tras el join, dado que el admin ES el operador).
   - **Tags**: marcar `tag:homelab`.
   - **Expiration**: 90 días (default; el key se quema al primer uso, así que el TTL solo importa por si se filtra antes de usarse).
4. Generar. Copiar el key (formato `tskey-auth-...`) a un buffer seguro (gestor de contraseñas, no a un fichero en la Pi).

> **El auth key se queda visible en el panel solo una vez.** Si se cierra la ventana, hay que generar otro.

### 4.3. Instalar el paquete

```bash
sudo apt install -y tailscale

# Verificar versión instalada:
tailscale version
# Esperado: 1.x.y
#           tailscale commit: ...
#           other commit: ...
#           go version: ...

# El servicio queda enabled pero aún sin autenticar:
sudo systemctl status tailscaled.service --no-pager | head -5
# Esperado: Active: active (running)
```

### 4.4. Autenticar la Pi en el tailnet

Usar el auth key generado en §4.2:

```bash
# Sustituir <TSKEY> por el auth key real (tskey-auth-xxxxxxxxxxxxx).
# Variables de entorno se usan para no dejar el key en la history del shell:
read -srp 'Auth key: ' TSKEY; echo
sudo tailscale up \
  --authkey "$TSKEY" \
  --hostname pi \
  --advertise-tags tag:homelab \
  --accept-routes=false \
  --accept-dns=true \
  --shields-up=false
unset TSKEY
```

Salida esperada (silenciosa si todo va bien). Verificar inmediatamente:

```bash
tailscale status
# Esperado:
# 100.x.y.z   pi                  user@      linux   -
# 100.x.y.a   movil               user@      android offline
# 100.x.y.b   portatil            user@      macOS   active

tailscale ip -4
# Esperado: una sola IP, 100.x.y.z (la asignada a la Pi).
```

> **Por qué `--shields-up=false`**: con `shields-up`, el nodo *acepta conexiones salientes* pero **rechaza** las entrantes. Para un homelab que **expone** servicios al tailnet, hay que dejarlo en `false` (default). Si se quisiera modo cliente puro (la Pi solo accede a otros peers, no recibe), se pondría `=true`.

### 4.5. Verificar la interfaz `tailscale0`

```bash
ip -4 addr show tailscale0
# Esperado: inet 100.x.y.z/32 scope global tailscale0

ip -6 addr show tailscale0 | grep inet6
# Esperado: una IPv6 ULA del tailnet (fd7a:115c:a1e0::...).

# Estado del routing:
ip route show table 52 2>/dev/null | head
# Esperado: vacío (no se han aceptado rutas con --accept-routes=false).
```

### 4.6. Verificar resolución MagicDNS desde la Pi

```bash
# `tailscale dns status` muestra cómo MagicDNS interactúa con resolved.
tailscale dns status
# Esperado: un bloque "MagicDNS: enabled" y los upstreams del tailnet.

# Resolver el propio FQDN de la Pi:
getent hosts pi.${TS_DOMAIN:-tailfb12cd.ts.net}
# (Reemplazar TS_DOMAIN si no está exportado en el shell.)
# Esperado: 100.x.y.z   pi.tailfb12cd.ts.net
```

> Si MagicDNS no funciona desde la Pi pero sí desde otros peers: revisar `/etc/resolv.conf`. Tailscale modifica el resolver a través de `systemd-resolved` o `NetworkManager` si están activos; con `resolv.conf` estático, `tailscaled` no puede inyectar su resolver y MagicDNS solo aplica fuera de la Pi. La Pi puede vivir con eso (Pi-hole resuelve `*.${TS_DOMAIN}` solo si tiene un upstream que lo haga, lo cual no es el caso por defecto), pero la generación de certs (§5) sigue funcionando porque `tailscale cert` consulta directamente al control plane, no al DNS local.

---

## 5. Generar el primer certificado HTTPS

### 5.1. Pre-flight check

```bash
# Confirmar que MagicDNS y HTTPS Certificates están activos:
tailscale cert --help 2>&1 | head -3
# Esperado: el subcomando existe.

# Comprobar el FQDN que Tailscale conoce para esta máquina:
tailscale status --json | jq -r '.Self.DNSName'
# Esperado: pi.tailfb12cd.ts.net.   (con punto final, FQDN absoluto)
```

> Si la salida es `pi.<otro-tailnet>.ts.net.`, ajustar `TS_DOMAIN` en `/mnt/hd2t/services/proxy/.env` para que coincida (§2.2).

### 5.2. Cargar las variables del entorno

Para que los siguientes comandos no necesiten teclear el FQDN:

```bash
set -a
source /mnt/hd2t/services/proxy/.env
set +a
echo "TS_DOMAIN=$TS_DOMAIN"
echo "TS_HOSTNAME=$TS_HOSTNAME"
# Esperado:
# TS_DOMAIN=tailfb12cd.ts.net
# TS_HOSTNAME=pi.tailfb12cd.ts.net
```

### 5.3. Emitir el cert

`tailscale cert` deja los ficheros en el directorio actual con nombres `<fqdn>.crt` y `<fqdn>.key`. Apuntar `cd` al destino para que aparezcan directamente donde Caddy los espera:

```bash
sudo -i  # tailscale cert necesita acceder al socket /var/run/tailscale/tailscaled.sock como root
cd /mnt/hd2t/services/proxy/tailscale-certs
tailscale cert "$TS_HOSTNAME"
# Esperado:
# Wrote public cert to /mnt/hd2t/services/proxy/tailscale-certs/pi.tailfb12cd.ts.net.crt
# Wrote private key to /mnt/hd2t/services/proxy/tailscale-certs/pi.tailfb12cd.ts.net.key
exit  # salir de la sesión root
```

> El primer `tailscale cert` puede tardar 10-30 s la primera vez (negocia DNS-01 con Let's Encrypt vía la infraestructura de Tailscale). En ejecuciones sucesivas (renovación), si el cert vigente tiene >30 días de validez restante, Tailscale lo devuelve cacheado en milisegundos.

### 5.4. Permisos correctos

Tailscale escribe los ficheros como `root:root` con modo `0600` (key) y `0644` (crt). Caddy corre como root dentro del contenedor (§5 de Caddy) y puede leerlos directamente. Sin embargo, para que el script de renovación (§7) y los backups (§10) los manipulen sin sudo, ajustar:

```bash
sudo chown root:homelab /mnt/hd2t/services/proxy/tailscale-certs/${TS_HOSTNAME}.{crt,key}
sudo chmod 640 /mnt/hd2t/services/proxy/tailscale-certs/${TS_HOSTNAME}.crt
sudo chmod 640 /mnt/hd2t/services/proxy/tailscale-certs/${TS_HOSTNAME}.key

ls -l /mnt/hd2t/services/proxy/tailscale-certs/
# Esperado:
# -rw-r----- 1 root homelab ... pi.tailfb12cd.ts.net.crt
# -rw-r----- 1 root homelab ... pi.tailfb12cd.ts.net.key
```

> **Por qué `640` y no `644`/`600`**: el grupo `homelab` (donde está el usuario operador y los servicios) puede leer; nadie más. Caddy lo lee como root. Borgmatic lo respalda con `homelab` (tras `cap_dac_read_search`, [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md)).

### 5.5. Verificar el cert

```bash
openssl x509 -in /mnt/hd2t/services/proxy/tailscale-certs/${TS_HOSTNAME}.crt \
  -noout -subject -issuer -dates -ext subjectAltName
# Esperado:
# subject= CN = pi.tailfb12cd.ts.net
# issuer=  C = US, O = Let's Encrypt, CN = R3   (o R10/R11 según rotación de Let's Encrypt)
# notBefore=...
# notAfter=...   (+90 días)
# X509v3 Subject Alternative Name:
#     DNS:pi.tailfb12cd.ts.net
```

---

## 6. Activar los bloques Tailscale en Caddy

Hasta este punto, el `Caddyfile` tiene los bloques `*.${TS_DOMAIN}` comentados (§4.3 de Caddy). Ahora se descomentan, **al menos para `pi.${TS_DOMAIN}`**.

### 6.1. Editar el `Caddyfile`

Editar `~/homelab/stacks/proxy/Caddyfile` y descomentar el bloque base:

```caddy
# ============================================================================
#  Bloques Tailscale — activos a partir de 05-tailscale.md
# ============================================================================

pi.{$TS_DOMAIN} {
    import tailscale_tls pi
    import security_headers
    # Página de bienvenida igual que caddy.lan, o redir a Homepage.
    respond "Hola desde Tailscale" 200
}

# Jellyfin se descomentará al desplegar 09-multimedia/01-jellyfin.md
# y tras tener su cert con `tailscale cert jellyfin.${TS_DOMAIN}`.
# jellyfin.{$TS_DOMAIN} {
#     import tailscale_tls jellyfin
#     import security_headers
#     reverse_proxy http://jellyfin:8096
# }
```

> **`import tailscale_tls pi`**: el snippet `tailscale_tls` toma `{args[0]}` como nombre base de los ficheros, por lo que con `pi` se monta `/data/tailscale-certs/pi.crt` + `/data/tailscale-certs/pi.key`. **Esto NO coincide** con los nombres reales (`pi.tailfb12cd.ts.net.crt`). Hay dos opciones equivalentes, ambas correctas:

#### Opción A (recomendada): renombrar los certs a la forma corta

```bash
cd /mnt/hd2t/services/proxy/tailscale-certs
sudo cp -p ${TS_HOSTNAME}.crt pi.crt
sudo cp -p ${TS_HOSTNAME}.key pi.key
ls -l
# Esperado: 4 ficheros: pi.{crt,key} y pi.tailfb12cd.ts.net.{crt,key}
```

> Se mantiene **ambas copias** porque el script de renovación (§7) escribe siempre con el nombre completo (`tailscale cert <fqdn>` no acepta otro), y Caddy consume la copia corta. La copia se hace con `cp -p` (preserva mtime/permisos) y se actualiza desde el script.

#### Opción B: pasar el FQDN completo al snippet

Modificar el snippet `snippets/tailscale_tls` para no concatenar:

```caddy
(tailscale_tls) {
    tls /data/tailscale-certs/{args[0]}.crt /data/tailscale-certs/{args[0]}.key
}
```

…ya está así, así que con la Opción B basta con escribir en el `Caddyfile`:

```caddy
pi.{$TS_DOMAIN} {
    import tailscale_tls pi.{$TS_DOMAIN}
    ...
}
```

> Ambas opciones son válidas. **Elegir A** mantiene los bloques del `Caddyfile` cortos y legibles; la copia adicional es trivial (4 KB). El resto del documento asume Opción A.

### 6.2. Validar antes de recargar

```bash
docker exec caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
# Esperado: "Valid configuration"
```

### 6.3. Recargar Caddy

```bash
docker exec caddy caddy reload --config /etc/caddy/Caddyfile
# Esperado: "successfully reloaded" en los logs (ningún output stdout).
```

Comprobar logs por si hay error de carga del cert:

```bash
docker compose -f ~/homelab/stacks/proxy/docker-compose.yml logs --tail=20 caddy \
  | grep -iE 'tailscale|tls|reload|error|warn'
# Esperado: ninguna línea con 'error'/'warn' relacionada a tailscale-certs.
```

### 6.4. MagicDNS de la Pi y conviviendo con Pi-hole

El host Pi ya usa Pi-hole como DNS primario ([`02-pihole.md`](./02-pihole.md) §6.6). Tras `tailscale up --accept-dns=true`, Tailscale añade un **resolver split-DNS** que solo se aplica a `*.${TS_DOMAIN}`: el resto del tráfico DNS sigue yendo a Pi-hole. La operación es transparente y reversible:

```bash
# Verificar el resolver split-DNS:
resolvectl domain
# Esperado: una entrada del tipo 'tailscale0: ~tailfb12cd.ts.net'
#           (~ indica routing-only, solo para ese sufijo).

# La Pi resuelve nombres LAN por Pi-hole:
dig +short pihole.lan
# Esperado: 192.168.1.10

# Y nombres del tailnet por MagicDNS:
dig +short pi.${TS_DOMAIN:-tailfb12cd.ts.net}
# Esperado: 100.x.y.z
```

> Si Pi-hole **estuviera caído** y la Pi se hubiera quedado sin upstream para `*.lan`, **MagicDNS seguiría resolviendo** los nombres del tailnet. Eso permite diagnóstico remoto vía Tailscale incluso con Pi-hole caído.

---

## 7. Renovación automática de certificados

Los certs Let's Encrypt emitidos por Tailscale duran **90 días**. Tailscale recomienda renovar a partir del día 30. Un timer semanal cubre la ventana sin estrés.

### 7.1. Script de renovación

`~/homelab/scripts/tailscale/tailscale-cert-renew.sh`:

```bash
#!/usr/bin/env bash
# ~/homelab/scripts/tailscale/tailscale-cert-renew.sh
# Renueva el cert HTTPS del nodo Tailscale y recarga Caddy.
# Llamado por tailscale-cert-renew.timer (semanal).
# Documentado en docs/03-red/05-tailscale.md §7.

set -euo pipefail

# --- Cargar variables del homelab.
ENV_FILE=/mnt/hd2t/services/proxy/.env
if [[ ! -r "$ENV_FILE" ]]; then
    echo "FATAL: $ENV_FILE no es legible" >&2
    exit 1
fi
# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

if [[ -z "${TS_HOSTNAME:-}" || "$TS_HOSTNAME" == "pi.tailnet.ts.net" ]]; then
    echo "FATAL: TS_HOSTNAME no configurado en $ENV_FILE" >&2
    exit 1
fi

CERT_DIR=/mnt/hd2t/services/proxy/tailscale-certs
SHORT_NAME=pi  # nombre corto consumido por el snippet tailscale_tls del Caddyfile

# --- Renovar.
# `tailscale cert` es idempotente: si el cert vigente todavía tiene >30 días
# de validez restante, lo devuelve cacheado en milisegundos.
cd "$CERT_DIR"
echo "[$(date -Is)] tailscale cert $TS_HOSTNAME"
tailscale cert "$TS_HOSTNAME"

# --- Re-permisos (tailscale cert los crea root:root 600/644).
chown root:homelab "${TS_HOSTNAME}.crt" "${TS_HOSTNAME}.key"
chmod 640 "${TS_HOSTNAME}.crt" "${TS_HOSTNAME}.key"

# --- Sincronizar la copia corta consumida por Caddy (opción A de §6.1).
install -m 640 -o root -g homelab "${TS_HOSTNAME}.crt" "${SHORT_NAME}.crt"
install -m 640 -o root -g homelab "${TS_HOSTNAME}.key" "${SHORT_NAME}.key"

# --- Recargar Caddy para que sirva el nuevo cert sin romper conexiones.
if docker ps --format '{{.Names}}' | grep -qx caddy; then
    echo "[$(date -Is)] reloading caddy"
    docker exec caddy caddy reload --config /etc/caddy/Caddyfile
else
    echo "[$(date -Is)] caddy no está corriendo; el cert se persistió pero no se recargó." >&2
fi

echo "[$(date -Is)] OK"
```

Crear y dar permisos:

```bash
mkdir -p ~/homelab/scripts/tailscale
# Pegar el script anterior con un editor (o `cat > ... <<'EOF'`).
chmod +x ~/homelab/scripts/tailscale/tailscale-cert-renew.sh

# Test manual (debe terminar con OK):
sudo ~/homelab/scripts/tailscale/tailscale-cert-renew.sh
```

### 7.2. Unit systemd (oneshot)

`~/homelab/scripts/tailscale/tailscale-cert-renew.service`:

```ini
[Unit]
Description=Renovar el cert HTTPS Tailscale del homelab y recargar Caddy
After=tailscaled.service docker.service
Requires=tailscaled.service
ConditionPathIsMountPoint=/mnt/hd2t

[Service]
Type=oneshot
ExecStart=/home/homelab/homelab/scripts/tailscale/tailscale-cert-renew.sh
# Logging a journald (default).
StandardOutput=journal
StandardError=journal
# Endurecimiento mínimo:
ProtectSystem=strict
ReadWritePaths=/mnt/hd2t/services/proxy/tailscale-certs
NoNewPrivileges=true
ProtectHome=read-only
PrivateTmp=true
```

> `ConditionPathIsMountPoint=/mnt/hd2t` asegura que el job no corre si hd2t no está montado (failsafe para post-reboot con disco no detectado).

### 7.3. Unit systemd (timer)

`~/homelab/scripts/tailscale/tailscale-cert-renew.timer`:

```ini
[Unit]
Description=Trigger semanal para renovar el cert HTTPS Tailscale
Requires=tailscale-cert-renew.service

[Timer]
# Domingos a las 03:30. Antes de unattended-upgrades (04:00) para no
# pisar reload de Caddy con un eventual reboot del kernel.
OnCalendar=Sun *-*-* 03:30:00
# Si la Pi estaba apagada al disparo, ejecutar al arrancar.
Persistent=true
RandomizedDelaySec=300
Unit=tailscale-cert-renew.service

[Install]
WantedBy=timers.target
```

### 7.4. Instalar y activar las units

```bash
# Symlinks desde ~/homelab/scripts/tailscale/ a /etc/systemd/system/
# (para que el sistema las cargue, pero permanezcan versionadas en el repo).
sudo ln -sf /home/homelab/homelab/scripts/tailscale/tailscale-cert-renew.service \
    /etc/systemd/system/tailscale-cert-renew.service
sudo ln -sf /home/homelab/homelab/scripts/tailscale/tailscale-cert-renew.timer \
    /etc/systemd/system/tailscale-cert-renew.timer

sudo systemctl daemon-reload
sudo systemctl enable --now tailscale-cert-renew.timer

# Verificar:
systemctl list-timers tailscale-cert-renew.timer --no-pager
# Esperado: una entrada con 'Sun 03:30' como next trigger.

# Test manual del oneshot a través de systemd (no del script directo):
sudo systemctl start tailscale-cert-renew.service
journalctl -u tailscale-cert-renew.service --no-pager | tail -20
# Esperado: líneas '[<fecha>] tailscale cert ...' y '[<fecha>] OK'.
```

> **Por qué symlinks**: el repo `~/homelab/` se versiona en git. Si el operador `git pull` o cambia el script, systemd ve el nuevo contenido sin más (los symlinks resuelven en runtime). Si se copiaran los ficheros a `/etc/systemd/system/`, cada cambio exigiría `cp` + `daemon-reload`, fácil de olvidar.

---

## 8. Verificación

### 8.1. Tailscale up y healthy

```bash
tailscale status --self
# Esperado: una línea con la Pi, hostname=pi, status=online (no idle/offline).

systemctl is-active tailscaled.service
# Esperado: active

journalctl -u tailscaled.service --since '5 minutes ago' --no-pager | grep -iE 'error|fail' || echo "Sin errores recientes"
```

### 8.2. Cert válido y montado en Caddy

```bash
# Hash del cert en disco vs el que Caddy sirve:
sha256sum /mnt/hd2t/services/proxy/tailscale-certs/pi.crt

echo | openssl s_client -connect 100.x.y.z:443 -servername "${TS_HOSTNAME}" 2>/dev/null \
  | openssl x509 -outform PEM \
  | sha256sum
# Sustituir 100.x.y.z por la IP de tailscale del host:
#   tailscale ip -4
# Los dos hashes deben coincidir.
```

### 8.3. Smoke test desde la Pi (loopback Tailscale)

```bash
# Resolver y conectar al propio FQDN tailnet:
TS_HOSTNAME=$(grep ^TS_HOSTNAME= /mnt/hd2t/services/proxy/.env | cut -d= -f2)

curl -fsS "https://${TS_HOSTNAME}/" -o /dev/null -w 'http=%{http_code} cert_subject="%{ssl_subject}" issuer="%{ssl_issuer}"\n'
# Esperado:
# http=200 cert_subject="CN = pi.tailfb12cd.ts.net" issuer="C = US, O = Let's Encrypt, CN = R3"
```

> Importante: **sin `-k`**. El cert es Let's Encrypt válido, así que el sistema lo verifica contra los CA roots de Debian sin pasos adicionales.

### 8.4. Smoke test desde otro peer del tailnet

Desde un portátil/móvil ya en el tailnet:

```bash
# Resolución MagicDNS:
ping -c 1 pi.tailfb12cd.ts.net
# Esperado: una línea de respuesta. La IP es la 100.x.y.z del tailnet, no la 192.168.1.10 de la LAN.

# HTTPS:
curl -fsS https://pi.tailfb12cd.ts.net/ -o /dev/null -w '%{http_code}\n'
# Esperado: 200

# Pi-hole (descomentar también pihole.${TS_DOMAIN} en el Caddyfile y `tailscale cert pihole.${TS_DOMAIN}` antes):
# curl -fsS https://pihole.tailfb12cd.ts.net/admin/ -o /dev/null -w '%{http_code}\n'
```

### 8.5. La VPN no expone puertos a internet

```bash
# Desde fuera del tailnet (p. ej. móvil con datos celulares y WiFi apagado, sin Tailscale activo):
curl -m 5 -fsSI https://pi.tailfb12cd.ts.net/ -o /dev/null -w '%{http_code}\n' || echo "no-route"
# Esperado: la conexión falla. El nombre tampoco resuelve a una IP pública (MagicDNS solo opera dentro del tailnet).

# Sondeo de puertos contra la IP pública del operador:
nmap -Pn -p 22,80,443 -T4 <ip-publica-del-router>
# Esperado: todos closed/filtered. El homelab no expone NADA a internet.
```

### 8.6. Pi-hole sigue resolviendo nombres LAN

```bash
# Desde la Pi, comprobar que MagicDNS no se ha "comido" el resolver:
dig +short pihole.lan
# Esperado: 192.168.1.10

dig +short pi.tailfb12cd.ts.net
# Esperado: 100.x.y.z

# Misma comprobación desde otro equipo de la LAN (que NO está en el tailnet):
# - 'pihole.lan' debe resolver a 192.168.1.10.
# - 'pi.tailfb12cd.ts.net' NO debe resolver (DNS público no conoce el tailnet).
```

### 8.7. Timer activo

```bash
systemctl list-timers tailscale-cert-renew.timer --no-pager
# Esperado: NEXT en próximo domingo 03:30; LAST corresponde al test manual de §7.4.

systemctl status tailscale-cert-renew.timer --no-pager
# Esperado: Active: active (waiting)
```

### 8.8. Persistencia tras reboot

```bash
sudo reboot
# (esperar a que vuelva)

# Tailscale arranca solo:
tailscale status --self | head -1
# Esperado: la Pi online en el tailnet.

# Cert sigue ahí:
ls -l /mnt/hd2t/services/proxy/tailscale-certs/
# Esperado: los 4 ficheros (pi.{crt,key} + pi.<TS_DOMAIN>.{crt,key}).

# Caddy sirviendo HTTPS por Tailscale:
TS_HOSTNAME=$(grep ^TS_HOSTNAME= /mnt/hd2t/services/proxy/.env | cut -d= -f2)
curl -fsS "https://${TS_HOSTNAME}/" -o /dev/null -w '%{http_code}\n'
# Esperado: 200
```

### 8.9. Lista de Verificación

Antes de pasar a [Fase 4 — Seguridad](../04-seguridad/):

- [ ] `tailscale status` muestra la Pi como `online` con tag `tag:homelab`.
- [ ] MagicDNS y HTTPS Certificates están activos en https://login.tailscale.com/admin/dns/.
- [ ] `/mnt/hd2t/services/proxy/.env` tiene `TS_DOMAIN` y `TS_HOSTNAME` con valores reales (no el placeholder `tailnet.ts.net`).
- [ ] `tailscale cert ${TS_HOSTNAME}` ha emitido `pi.<TS_DOMAIN>.crt` y `.key` en `/mnt/hd2t/services/proxy/tailscale-certs/`.
- [ ] Existen también las copias cortas `pi.crt` / `pi.key` con permisos `640 root:homelab` (Opción A de §6.1).
- [ ] El bloque `pi.{$TS_DOMAIN}` del `Caddyfile` está descomentado y `caddy validate` no se queja.
- [ ] `curl -fsS https://${TS_HOSTNAME}/` desde la Pi devuelve **200** con cert firmado por Let's Encrypt.
- [ ] El mismo `curl` desde otro peer del tailnet devuelve **200**.
- [ ] El mismo nombre **no** resuelve fuera del tailnet (móvil con datos celulares sin Tailscale → `NXDOMAIN`).
- [ ] `nmap -Pn -p 22,80,443 <ip-pública-router>` sigue mostrando todo `closed/filtered`. El router **no** expone nada.
- [ ] `systemctl list-timers tailscale-cert-renew.timer` muestra próxima ejecución el domingo 03:30.
- [ ] Tras `sudo reboot`, `tailscaled.service` arranca solo, MagicDNS funciona, y Caddy sigue sirviendo HTTPS Tailscale.
- [ ] El repo de Tailscale está en la *blacklist* de `unattended-upgrades` (§3.4).

---

## 9. ACLs y tags básicos

Para un homelab unipersonal con todos los dispositivos del operador en la misma cuenta Tailscale, **la política por defecto basta**: cualquier nodo del tailnet puede contactar con cualquier otro. Las ACLs documentadas aquí son **opcionales** pero recomendables si:

- El tailnet incluye dispositivos de invitados (familiares, amigos) que no necesitan ver el homelab.
- Se quieren *limitar* los puertos accesibles desde un dispositivo móvil potencialmente comprometido.

### 9.1. Estructura de tags

En el panel de admin, `Access Controls` (https://login.tailscale.com/admin/acls/), bajo `tagOwners`:

```jsonc
{
    "tagOwners": {
        "tag:homelab": ["autogroup:admin"],
        // (futuro) servicios expuestos a invitados con scope reducido:
        "tag:guest": ["autogroup:admin"],
    },
}
```

### 9.2. Política sugerida

```jsonc
{
    "acls": [
        // Admin → todo (operador con privilegios completos).
        {"action": "accept", "src": ["autogroup:admin"], "dst": ["*:*"]},

        // tag:homelab no inicia conexiones a otros peers
        // (es solo destino, no origen). Útil para que un compromiso del homelab
        // no se propague al portátil del operador.
        // No hace falta una regla 'deny': ACLs son default-deny.

        // Si se quiere permitir solo puertos web a invitados:
        // {"action": "accept",
        //  "src": ["tag:guest"],
        //  "dst": ["tag:homelab:443"]},
    ],
    "tagOwners": {
        "tag:homelab": ["autogroup:admin"],
    },
}
```

### 9.3. Aplicar y testear

`Save` en el panel; Tailscale despliega la nueva política a todos los nodos en segundos. Verificar:

```bash
# La regla "homelab no inicia": desde la Pi, intentar SSH al portátil del operador.
# Si la regla está activa, debería fallar (timeout):
ssh -o ConnectTimeout=5 100.x.y.<ip-portatil> echo ok
# Esperado: 'Operation timed out' (denied por la ACL).
```

> Para un homelab que *sí* necesita iniciar conexiones salientes (p. ej. hacia un nodo de backup remoto), se añade explícitamente una regla `{"action": "accept", "src": ["tag:homelab"], "dst": ["tag:backup:*"]}` o similar.

---

## 10. Backup

Estrategia que se concretará en [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md). Lo que **debe respaldarse** de Tailscale:

| Ruta | Qué contiene | Frecuencia |
|---|---|---|
| `/var/lib/tailscale/tailscaled.state` | **Node key privada** + state DB. Si se pierde, la Pi se reincorpora al tailnet con un nuevo key (cambia de IP `100.x.y.z`, se "olvida" en el panel). Tamaño <1 MB. | **Semanal**, dentro del backup de Borg. |
| `/var/lib/tailscale/files/` | Ficheros recibidos por `tailscale file get` (si se usa). Reemplazables. | Opcional. |
| `~/homelab/scripts/tailscale/*` | Script de renovación + units systemd. | Versionado en git → `git push`. |
| `/mnt/hd2t/services/proxy/tailscale-certs/*.crt` | Certs Let's Encrypt. **Reconstruibles** con `tailscale cert <fqdn>` en cualquier momento. | Opcional (cabe sin coste; Borg los compresa a casi nada). |
| `/mnt/hd2t/services/proxy/tailscale-certs/*.key` | Keys de los certs. **Reconstruibles** con cada `tailscale cert`. | Opcional, mismo razonamiento. |
| `/etc/apt/sources.list.d/tailscale.list` + `/usr/share/keyrings/tailscale-archive-keyring.gpg` | Repo y clave GPG de Tailscale. Reproducibles desde `https://pkgs.tailscale.com`. | Opcional (los reinstala el doc en una recuperación). |
| `/etc/apt/apt.conf.d/51unattended-upgrades-tailscale` | Blacklist de upgrades. Reproducible desde §3.4. | Opcional. |

Pre-backup hook (Borgmatic), opcional:

```yaml
# Pseudo-config; la real va en 07-backups/02-borgmatic.md.
before_backup:
  - tailscale status --json > /mnt/hd2t/backups/dumps/tailscale/status.json
```

> `tailscale status --json` es un snapshot del estado actual del tailnet (peers, IPs, online status, ACLs efectivas). Útil tras un disaster-recovery para identificar qué nodos hay que aprobar manualmente en el panel.

> **Lo crucial es la node key.** Pérdida del cert → 30 s de regeneración con `tailscale cert`. Pérdida de `/var/lib/tailscale/tailscaled.state` → 5 min: ir al panel, *Remove device* la Pi vieja, `tailscale up --authkey ...` con un key nuevo. Mismo resultado funcional, pero con un cambio de IP en el tailnet (cualquier ACL que referenciara la IP en lugar del tag se rompe). Por eso se respalda la state.

---

## 11. Operaciones cotidianas

### 11.1. Ver el estado del tailnet

```bash
# Resumen de todos los peers conocidos:
tailscale status

# Solo el propio nodo:
tailscale status --self

# JSON detallado (peers, ACLs aplicables, latencias DERP):
tailscale status --json | jq '.Peer | to_entries[].value | {Hostname, OS, Active}'

# Latencias y ruta (¿directo o por DERP relay?):
tailscale netcheck
```

### 11.2. Re-emitir el cert manualmente

En cualquier momento (p. ej. tras cambiar el FQDN):

```bash
sudo systemctl start tailscale-cert-renew.service
journalctl -u tailscale-cert-renew.service --no-pager | tail -10
# Esperado: 'OK' final.
```

### 11.3. Añadir un nuevo nodo al tailnet

Desde el equipo nuevo (no desde la Pi), instalar el cliente Tailscale (apt, App Store, Google Play, descarga de https://tailscale.com/download) y autenticar:

```bash
sudo tailscale up
# Abre un navegador para login. Aprobar en https://login.tailscale.com/admin/.
```

Verificar desde la Pi que el nuevo nodo aparece:

```bash
tailscale status | grep <nuevo-hostname>
```

### 11.4. Añadir un nuevo cert para otro servicio (p. ej. Jellyfin)

Cuando se despliegue Jellyfin ([`../09-multimedia/01-jellyfin.md`](../09-multimedia/01-jellyfin.md)):

```bash
# 1. Generar el cert.
TS_DOMAIN=$(grep ^TS_DOMAIN= /mnt/hd2t/services/proxy/.env | cut -d= -f2)
sudo -i
cd /mnt/hd2t/services/proxy/tailscale-certs
tailscale cert "jellyfin.${TS_DOMAIN}"
chown root:homelab "jellyfin.${TS_DOMAIN}".{crt,key}
chmod 640 "jellyfin.${TS_DOMAIN}".{crt,key}
# Copia corta (Opción A):
install -m 640 -o root -g homelab "jellyfin.${TS_DOMAIN}.crt" jellyfin.crt
install -m 640 -o root -g homelab "jellyfin.${TS_DOMAIN}.key" jellyfin.key
exit

# 2. Descomentar el bloque jellyfin.{$TS_DOMAIN} en el Caddyfile.
# 3. Recargar Caddy:
docker exec caddy caddy reload --config /etc/caddy/Caddyfile

# 4. Añadir 'jellyfin' a SHORT_NAMES en el script de renovación
#    (siguiente sección) para que el timer lo cubra.
```

### 11.5. Extender el script de renovación a múltiples servicios

Cuando ya hay varios certs (`pi`, `jellyfin`, `pihole`...), generalizar el script:

```bash
# Reemplazar el bloque de SHORT_NAME único por un array:
SHORT_NAMES=(pi)  # añadir 'jellyfin', 'pihole', etc. aquí
TS_DOMAIN_VAL="${TS_DOMAIN}"

for short in "${SHORT_NAMES[@]}"; do
    fqdn="${short}.${TS_DOMAIN_VAL}"
    cd "$CERT_DIR"
    echo "[$(date -Is)] tailscale cert $fqdn"
    tailscale cert "$fqdn"
    chown root:homelab "${fqdn}.crt" "${fqdn}.key"
    chmod 640 "${fqdn}.crt" "${fqdn}.key"
    install -m 640 -o root -g homelab "${fqdn}.crt" "${short}.crt"
    install -m 640 -o root -g homelab "${fqdn}.key" "${short}.key"
done
```

> Cada `tailscale cert` que se renueva si tiene <30 días de validez restante; los que no, devuelven el cached. Coste de la iteración: <1 s por cert si están todos vigentes.

### 11.6. Activar `tailscale ssh` (opcional)

Si se quiere usar SSH del tailnet sin claves (autenticado por identidad):

```bash
sudo tailscale up \
  --ssh \
  --hostname pi \
  --advertise-tags tag:homelab \
  --accept-routes=false \
  --accept-dns=true
```

Desde un peer:

```bash
ssh homelab@pi
# Tailscale autentica al usuario contra el tailnet, sin pedir clave.
```

> Compatible con la SSH de OpenSSH (puerto 22) endurecida en [`../01-sistema/03-seguridad-base.md`](../01-sistema/03-seguridad-base.md). Tailscale SSH usa puerto distinto y resuelve por sí solo. Si se prefiere desactivar el OpenSSH del host y dejar **solo** Tailscale SSH, hay que tener en cuenta que un `tailscale logout` deja la Pi inaccesible — **no recomendado** salvo que se mantenga acceso físico.

### 11.7. Salir del tailnet

```bash
sudo tailscale logout
# El daemon sigue corriendo, la Pi pierde la IP del tailnet, los peers la ven offline.
# Para volver: `sudo tailscale up --authkey <NEW>`.
```

> **No** ejecutar `tailscale logout` sin tener acceso alternativo (LAN o consola física): pierde la VPN inmediatamente. El comando `down` (sin `logout`) es menos destructivo: detiene la conexión pero conserva la node key.

### 11.8. Upgrade controlado de Tailscale

```bash
# Leer el changelog antes:
# https://github.com/tailscale/tailscale/blob/main/CHANGELOG.md

sudo apt update
apt list --upgradable 2>/dev/null | grep ^tailscale
# Si hay upgrade:
sudo apt install --only-upgrade tailscale tailscale-archive-keyring

# tailscaled se reinicia solo. La VPN puede caer ~5 s.
tailscale status --self
# Verificar que vuelve online.
```

---

## 12. Solución de Problemas

| Síntoma | Causa probable | Acción |
|---|---|---|
| `tailscale up` falla con `Could not contact login server` | Sin DNS o sin acceso a `controlplane.tailscale.com`. | `dig controlplane.tailscale.com`, `curl -I https://controlplane.tailscale.com/`. Verificar `/etc/resolv.conf` y `ufw status` (debe permitir saliente). |
| `tailscale up --authkey ...` falla con `tag tag:homelab not allowed` | El tag no está en `tagOwners` del panel. | Añadir `"tag:homelab": ["autogroup:admin"]` en https://login.tailscale.com/admin/acls/ y reintentar. |
| `tailscale cert` falla con `MagicDNS not enabled` | MagicDNS desactivado en el panel. | Activar en https://login.tailscale.com/admin/dns/ → MagicDNS. |
| `tailscale cert` falla con `HTTPS not enabled for tailnet` | HTTPS Certificates desactivado. | Activar en el mismo panel, sección HTTPS Certificates. |
| `tailscale cert` falla con `404 not found by control plane` | El FQDN no coincide con el del tailnet. | `tailscale status --json | jq '.Self.DNSName'` para ver el FQDN exacto y usarlo. |
| `tailscale cert` cuelga >60 s y termina con timeout | Let's Encrypt está validando DNS-01 vía Tailscale. Suele resolver solo en 30 s; si supera 2 min, hay un problema de control plane. | Reintentar pasados 5 min. Si persiste, abrir issue en https://github.com/tailscale/tailscale o consultar https://status.tailscale.com/. |
| Curl a `https://${TS_HOSTNAME}/` desde otro peer falla con `unable to verify the first certificate` | El servidor está sirviendo el cert de la CA interna de Caddy (`*.lan`), no el de Tailscale. | El bloque `pi.{$TS_DOMAIN}` no está descomentado en el `Caddyfile`, o el `import tailscale_tls pi` apunta a un nombre de fichero inexistente. Verificar que `/mnt/hd2t/services/proxy/tailscale-certs/pi.crt` existe. |
| `docker exec caddy caddy reload` falla con `loading certs: open /data/tailscale-certs/pi.crt: no such file` | El bind mount `tailscale-certs` está vacío (`tailscale cert` aún no se ejecutó), o el cert se llama `pi.<TS_DOMAIN>.crt` y no `pi.crt`. | Ejecutar `sudo systemctl start tailscale-cert-renew.service` o renombrar a la copia corta (§6.1, Opción A). |
| `tailscale status` muestra `pi   100.x.y.z   user@   linux   idle` permanente | El daemon corre pero no negoció rutas a peers. | `sudo tailscale netcheck`. Ver si hay UDP bloqueado (intermediate router); si es así, Tailscale usa DERP relays (más latencia, sigue funcionando). |
| Conexión Tailscale → Caddy lentísima (segundos por respuesta) | El tráfico va por DERP en vez de p2p directo. | `tailscale netcheck`. Suele resolver con un router doméstico que no bloquee UPnP/STUN. Si no hay forma, aceptar la latencia o cambiar a DERP cercano (`Settings → Networking`). |
| `pi.${TS_DOMAIN}` no resuelve desde el peer | MagicDNS desactivado en el peer (no aceptó `--accept-dns=true`) o cliente Tailscale no instalado. | En el peer: `tailscale up --accept-dns=true` o instalar Tailscale. Como fallback: `tailscale ip -4 pi` da la IP `100.x.y.z` directamente. |
| Tras un reboot, `tailscaled.service` arranca pero el cert no se sirve | El timer no había llegado a correr; el cert sigue válido pero Caddy se levantó antes que el bind mount. | `docker compose restart caddy` o `docker exec caddy caddy reload`. Si pasa habitualmente, añadir `depends_on: hd2t.mount` o similar (raro en Bookworm con `restart: unless-stopped`). |
| `journalctl -u tailscale-cert-renew.service` muestra `Permission denied` al hacer `chmod` | El script no se ejecuta como root (la unit es correcta, pero algún `ExecStart` directo no). | Verificar que se llama con `sudo systemctl start tailscale-cert-renew.service`, no `bash tailscale-cert-renew.sh`. La unit no especifica `User=`, así que corre como root. |
| Tras un upgrade de Tailscale (`apt install --only-upgrade`), MagicDNS deja de funcionar | El daemon se ha reiniciado y no ha re-establecido el resolver DNS del sistema. | `sudo systemctl restart tailscaled.service`; `tailscale dns status`. Si persiste, `sudo tailscale up` reaplicando los flags (idempotente). |
| Borgmatic se queja al respaldar `/var/lib/tailscale/` (`permission denied`) | Borg corre como `homelab`, el directorio es `root:root` con `0700`. | Documentado en [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md): Borg con `cap_dac_read_search` lee directorios *root-only* sin sudo. |
| El panel marca la Pi como `Expired Key` | La node key se generó hace >180 días sin re-autenticarse y el tailnet tiene "Key expiry" obligatorio. | `sudo tailscale up` (sin `--authkey`) reabre el flujo del navegador para refrescar el key. O en el panel: `... → Disable key expiry` para este nodo (no recomendado en general, válido para servidores fijos). |
| `tailscale cert` devuelve un cert con `notAfter` lejano (~90 días) pero el navegador del peer dice `cert expired` | El reloj del peer está mal sincronizado. | `timedatectl` en el peer; activar NTP. |

---

## Referencias

- [Tailscale — Documentación oficial](https://tailscale.com/kb/)
- [Tailscale — How Tailscale works](https://tailscale.com/kb/1151/what-is-tailscale/)
- [Tailscale — Linux installation](https://tailscale.com/kb/1031/install-linux/)
- [Tailscale — `tailscale up` flags](https://tailscale.com/kb/1241/tailscale-up/)
- [Tailscale — Auth keys](https://tailscale.com/kb/1085/auth-keys/)
- [Tailscale — MagicDNS](https://tailscale.com/kb/1081/magicdns/)
- [Tailscale — HTTPS para máquinas del tailnet (`tailscale cert`)](https://tailscale.com/kb/1153/enabling-https/)
- [Tailscale — Tags y ACL templates](https://tailscale.com/kb/1068/acl-tags/)
- [Tailscale — ACL syntax (HuJSON)](https://tailscale.com/kb/1018/acls/)
- [Tailscale — Subnet routers (no usado en este doc)](https://tailscale.com/kb/1019/subnets/)
- [Tailscale — Exit nodes (no usado en este doc)](https://tailscale.com/kb/1103/exit-nodes/)
- [Tailscale — `tailscale ssh`](https://tailscale.com/kb/1193/tailscale-ssh/)
- [Tailscale — Funnel (no usado en este doc)](https://tailscale.com/kb/1223/funnel/)
- [Tailscale — Status page](https://status.tailscale.com/)
- [Tailscale — Source code y CHANGELOG (GitHub)](https://github.com/tailscale/tailscale)
- [Caddy — `tls` directive](https://caddyserver.com/docs/caddyfile/directives/tls)
- [Let's Encrypt — Production Certificate Authorities](https://letsencrypt.org/certificates/)
