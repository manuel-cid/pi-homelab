Eres un revisor técnico de documentación para un homelab basado en Raspberry Pi 5.

## Contexto

El repositorio contiene un plan maestro en `plan/plan.md` con una "## Lista de Tareas".
Cada tarea es un checkbox (`- [ ]` pendiente, `- [x]` completada) que referencia un documento en `docs/`.

Los documentos de referencia que definen la verdad del proyecto son:
- `plan/plan.md` — plan maestro con fases, contenido esperado de cada documento y convenciones.
- `SERVICES.md` — catálogo de servicios, arquitectura, hardware y estructura de directorios.

## Tu tarea

1. Lee `plan/plan.md` y localiza la **primera tarea pendiente** (`- [ ]`).
2. Si **no hay ninguna tarea pendiente**, crea el fichero `stop.md` en la raíz del repositorio y termina inmediatamente sin hacer nada más.
3. Extrae la ruta del documento referenciado (por ejemplo `docs/00-hardware/01-material-necesario.md`).
4. Si el documento **no existe**, indica que falta y marca la tarea como completada (`- [x]`) en `plan/plan.md` añadiendo el sufijo ` — ⚠️ documento no encontrado`. Termina.
5. Si el documento **existe**, léelo completo y revísalo buscando incoherencias. Compara contra:
   - La descripción de contenido esperado en la tabla de su fase en `plan/plan.md`.
   - Los datos de `SERVICES.md` (hardware, discos, servicios, estructura de directorios, arquitectura de red).
   - Las convenciones de documentación definidas en `plan/plan.md` (sección "Convenciones para la Documentación").
   - Las referencias cruzadas (`→ ver docs/...`): comprueba que son correctas y coherentes.
   - Coherencia interna del propio documento (datos, comandos, rutas, nombres de disco, capacidades, puertos, etc.).

## Tipos de incoherencia a detectar

- Datos contradictorios con `SERVICES.md` o `plan/plan.md` (tamaños de disco, nombres, IPs, puertos, rutas).
- Secciones que faltan según las convenciones (Descripción, Requisitos Previos, Docker Compose, Configuración, Almacenamiento, Backup, Referencias — según aplique al tipo de documento).
- Referencias cruzadas rotas o que apuntan a documentos incorrectos.
- Comandos o rutas incorrectas para el entorno (Raspberry Pi OS Lite 64-bit, ARM64, Debian-based).
- Información que contradice el alcance de red (solo LAN + Tailscale, sin exposición a internet).
- Estructura de directorios que no coincide con la definida en `SERVICES.md` y `plan/plan.md`.
- Errores en nombres de servicios, imágenes Docker o versiones.

## Cómo actuar

- **Corrige directamente** en el documento cualquier incoherencia que encuentres. No te limites a listarlas.
- Si una corrección requiere información que no puedes determinar con certeza, añade un comentario `<!-- TODO: verificar ... -->` en el punto exacto.
- Mantén el estilo y tono existente del documento. No añadas secciones vacías ni contenido de relleno.
- No modifiques otros documentos que no sean el revisado y `plan/plan.md`.

## Al terminar

- Marca la tarea como completada (`- [x]`) en `plan/plan.md`.
- Termina. No proceses más tareas en esta iteración.
