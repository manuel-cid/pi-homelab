#!/usr/bin/env bash
#
# ralph-loop.sh v2.1 — "Ralph Loop" con soporte multi-backend
#
# Recorre las tareas pendientes (- [ ]) de un documento markdown y para cada
# una ejecuta un agente CLI con el contexto mínimo necesario (solo la fase,
# la descripción de la tarea y las convenciones de documentación).
#
# Backends soportados:
#   - codex  (defecto)  — OpenAI Codex CLI (codex --approval-mode full-auto -q)
#   - devin  (--devin)  — Devin CLI (devin --permission-mode dangerous -p)
#
# v2.0 mejoras sobre v1.0:
#   - Contexto mínimo por tarea: extrae solo la sección relevante del plan
#     en lugar de pedir a Devin que lea el plan completo (~285 líneas).
#     Esto evita que Devin lea todos los docs ya creados para "entender el
#     contexto", reduciendo el tamaño de contexto de ~700KB a ~5KB por tarea.
#   - Timeout configurable por tarea (--timeout, defecto 20 min) con reintentos
#     automáticos (--retries, defecto 3). Detecta bloqueos por TLS disconnect
#     o API sin respuesta.
#   - Todos los logs llevan timestamp (fecha y hora).
#   - Log estructurado a fichero (ralph-loop.log junto al plan).
#   - Métricas por tarea: duración, intentos, estado.
#   - Exit codes: 0 = bucle completado correctamente, 2 = error fatal.
#
# Requisitos:
#   - Codex CLI instalado (npm install -g @openai/codex) — o —
#   - Devin CLI instalado (https://cli.devin.ai/install.sh) si se usa --devin
#
# Uso:
#   ./ralph-loop.sh <plan.md>                          # ejecuta el bucle
#   ./ralph-loop.sh <plan.md> --status                 # muestra progreso
#   ./ralph-loop.sh <plan.md> --timeout 25 --retries 5 # personalizar
#
set -euo pipefail

# ── Configuración por defecto ────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TASK_TIMEOUT_MIN=20      # minutos máximos por intento de tarea
MAX_RETRIES=3            # reintentos por tarea antes de saltar
LOG_FILE="/dev/null"     # se sobreescribe tras parsear argumentos
BACKEND="codex"          # backend por defecto (codex | devin)

# ── Colores ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# ── Funciones auxiliares ─────────────────────────────────────────────────────

ts() { date '+%Y-%m-%d %H:%M:%S'; }

die()  { echo -e "$(ts) ${RED}[ERROR]${RESET} $*" >&2; log_file "ERROR" "$*"; exit 2; }
info() { echo -e "$(ts) ${CYAN}[ralph]${RESET} $*"; log_file "INFO" "$*"; }
warn() { echo -e "$(ts) ${YELLOW}[ralph]${RESET} $*"; log_file "WARN" "$*"; }
ok()   { echo -e "$(ts) ${GREEN}[ralph]${RESET} $*"; log_file "OK" "$*"; }

log_file() {
  local level="$1"; shift
  # Eliminar códigos ANSI para el fichero de log
  local clean
  clean=$(echo -e "$*" | sed 's/\x1b\[[0-9;]*m//g')
  echo "$(ts) [${level}] ${clean}" >> "$LOG_FILE" 2>/dev/null || true
}

usage() {
  cat <<EOF
Uso: $(basename "$0") <plan.md> [opciones]

  <plan.md>    Documento markdown con tareas en formato checkbox (- [ ] tarea)

Opciones:
  --timeout N  Minutos máximos por intento de tarea (defecto: ${TASK_TIMEOUT_MIN})
  --retries N  Reintentos por tarea antes de saltarla (defecto: ${MAX_RETRIES})
  --devin      Usar Devin CLI en lugar de Codex (defecto: codex)
  --status     Muestra resumen de progreso y sale
  -h, --help   Muestra esta ayuda

Requisitos:
  Codex CLI (defecto) o Devin CLI (con --devin)

Ejemplo:
  ./$(basename "$0") plans/PLAN.md
  ./$(basename "$0") plans/PLAN.md --timeout 25 --retries 5
  ./$(basename "$0") plans/PLAN.md --status
EOF
  exit 0
}

progress_bar() {
  local pct=$1 bar_width=40
  local filled=$(( pct * bar_width / 100 ))
  local empty=$(( bar_width - filled ))
  printf "  ["
  for (( j=0; j<filled; j++ )); do printf "${GREEN}█${RESET}"; done
  for (( j=0; j<empty;  j++ )); do printf "${RED}░${RESET}"; done
  printf "]  %d%%\n" "$pct"
}

# ── Funciones de plan ────────────────────────────────────────────────────────

count_tasks() {
  local n
  n=$(grep -cE '^\s*- \[[ x]\]' "$1" 2>/dev/null) || true
  echo "${n:-0}"
}

count_done() {
  local n
  n=$(grep -cE '^\s*- \[x\]' "$1" 2>/dev/null) || true
  echo "${n:-0}"
}

count_pending() {
  local n
  n=$(grep -cE '^\s*- \[ \]' "$1" 2>/dev/null) || true
  echo "${n:-0}"
}

show_status() {
  local total done_count pending pct
  total=$(count_tasks "$PLAN_FILE")
  done_count=$(count_done "$PLAN_FILE")
  pending=$(count_pending "$PLAN_FILE")
  pct=0
  (( total > 0 )) && pct=$(( done_count * 100 / total ))

  echo ""
  echo -e "${BOLD}══════════════════════════════════════${RESET}"
  echo -e "${BOLD}       Ralph Loop v2.0 — Progreso${RESET}"
  echo -e "${BOLD}══════════════════════════════════════${RESET}"
  echo ""
  echo -e "  ${GREEN}Completadas${RESET}: ${done_count}/${total}  (${pct}%)"
  echo -e "  ${YELLOW}Pendientes${RESET} : ${pending}"
  echo ""
  progress_bar "$pct"
  echo ""
}

get_next_pending_task() {
  grep -m1 -E '^\s*- \[ \]' "$PLAN_FILE" | sed 's/^\s*- \[ \] //'
}

get_next_pending_line() {
  grep -n -m1 -E '^\s*- \[ \]' "$PLAN_FILE" | cut -d: -f1
}

mark_done() {
  local line_num="$1"
  if sed --version 2>/dev/null | grep -q GNU; then
    sed -i "${line_num}s/- \[ \]/- [x]/" "$PLAN_FILE"
  else
    sed -i '' "${line_num}s/- \[ \]/- [x]/" "$PLAN_FILE"
  fi
}

# ── Extracción de contexto mínimo ───────────────────────────────────────────
#
# En lugar de decirle a Devin "lee el plan completo", extraemos:
#   1. Cabecera del plan (líneas 1-8: título, hardware, alcance de red)
#   2. La sección de la fase que contiene la tarea (título + tabla con descripciones)
#   3. Las convenciones de documentación
# Esto reduce el contexto de ~285 líneas (+ todos los docs que Devin leía)
# a ~30-50 líneas de texto puro embebido en el prompt.

extract_plan_header() {
  # Líneas desde el inicio hasta el primer "---" (cabecera del plan)
  awk '/^---$/{exit} {print}' "$PLAN_FILE"
}

extract_phase_section() {
  local task_line="$1"
  # Los checkboxes están bajo "### Fase N" pero las descripciones bajo "## Fase N".
  # Extraemos el número de fase del header ### más cercano por encima de la tarea,
  # y luego buscamos la sección ## Fase N correspondiente (con la tabla de descripciones).
  local phase_num phase_start phase_end

  # 1. Encontrar "### Fase N" más cercano por encima de la tarea
  local phase_header
  phase_header=$(head -n "$task_line" "$PLAN_FILE" | grep -n '^### Fase' | tail -1)
  phase_num=$(echo "$phase_header" | sed 's/.*Fase \([0-9]*\).*/\1/')

  if [[ -z "$phase_num" ]]; then
    # Fallback: extraer de la ruta del doc (docs/NN-xxx/)
    local doc_line
    doc_line=$(sed -n "${task_line}p" "$PLAN_FILE")
    phase_num=$(echo "$doc_line" | grep -oE 'docs/[0-9]+' | sed 's/docs//' | sed 's/\///')
  fi

  # 2. Buscar "## Fase <N>" (sección con la tabla de descripciones, no la de checkboxes)
  phase_start=$(grep -n "^## Fase ${phase_num} " "$PLAN_FILE" | head -1 | cut -d: -f1)

  if [[ -z "$phase_start" ]]; then
    echo "(No se encontró la sección de la Fase ${phase_num})"
    return
  fi

  # 3. Desde phase_start, hasta el siguiente "---"
  phase_end=$(tail -n +"$phase_start" "$PLAN_FILE" | grep -n '^---$' | head -1 | cut -d: -f1)
  if [[ -n "$phase_end" ]]; then
    phase_end=$(( phase_start + phase_end - 2 ))
  else
    phase_end=$(wc -l < "$PLAN_FILE")
  fi

  sed -n "${phase_start},${phase_end}p" "$PLAN_FILE"
}

extract_task_description() {
  # Busca la fila de la tabla que contiene el path del doc de la tarea
  local task="$1"
  # El task viene como `docs/xx-foo/yy-bar.md` (con backticks)
  local doc_path
  doc_path=$(echo "$task" | sed 's/`//g')
  grep -F "$doc_path" "$PLAN_FILE" | head -1
}

extract_conventions() {
  # Sección "Convenciones para la Documentación"
  local start end
  start=$(grep -n '## Convenciones' "$PLAN_FILE" | head -1 | cut -d: -f1)
  if [[ -n "$start" ]]; then
    end=$(tail -n +"$start" "$PLAN_FILE" | grep -n '^---$' | head -1 | cut -d: -f1)
    if [[ -n "$end" ]]; then
      end=$(( start + end - 2 ))
    else
      # Hasta "## Lista de Tareas"
      end=$(grep -n '## Lista de Tareas' "$PLAN_FILE" | head -1 | cut -d: -f1)
      [[ -n "$end" ]] && end=$(( end - 1 ))
    fi
    [[ -n "$end" ]] && sed -n "${start},${end}p" "$PLAN_FILE"
  fi
}

# ── Prompt para Devin (v2.0: contexto mínimo) ───────────────────────────────

build_prompt() {
  local task="$1"
  local task_line="$2"
  local plan_header phase_section task_desc conventions

  plan_header=$(extract_plan_header)
  phase_section=$(extract_phase_section "$task_line")
  task_desc=$(extract_task_description "$task")
  conventions=$(extract_conventions)

  cat <<PROMPT
Eres un redactor técnico. Tu trabajo es crear UN ÚNICO documento de documentación para un homelab.

══ CONTEXTO DEL PROYECTO ══

${plan_header}

══ FASE ACTUAL ══

${phase_section}

══ TAREA A EJECUTAR ══

Crea el documento: ${task}

Descripción de la tabla del plan:
${task_desc}

══ CONVENCIONES DE DOCUMENTACIÓN ══

${conventions}

══ INSTRUCCIONES ══

1. Crea el documento indicado arriba siguiendo las convenciones.
2. Si existen documentos hermanos en la misma fase (misma carpeta), léelos para mantener coherencia de estilo y referencias cruzadas.
3. NO leas documentos de otras fases a menos que necesites referenciarlos específicamente.
4. Una vez completado, marca la tarea como hecha en ${PLAN_FILE} cambiando - [ ] por - [x] SOLO en la línea de esta tarea.
5. NO modifiques ninguna otra línea de ${PLAN_FILE}.
PROMPT
}

# ── Ejecución con timeout ───────────────────────────────────────────────────

run_agent_with_timeout() {
  local prompt="$1"
  local timeout_secs=$(( TASK_TIMEOUT_MIN * 60 ))
  local agent_pid exit_code=0

  # Lanzar el agente en background según el backend elegido
  if [[ "$BACKEND" == "devin" ]]; then
    devin --permission-mode dangerous -p "$prompt" &
  else
    codex --approval-mode full-auto -q "$prompt" &
  fi
  agent_pid=$!

  # Esperar con timeout
  local elapsed=0
  while kill -0 "$agent_pid" 2>/dev/null; do
    if (( elapsed >= timeout_secs )); then
      warn "Timeout alcanzado (${TASK_TIMEOUT_MIN} min). Matando proceso ${BACKEND} (PID ${agent_pid})..."
      kill "$agent_pid" 2>/dev/null || true
      sleep 2
      kill -9 "$agent_pid" 2>/dev/null || true
      wait "$agent_pid" 2>/dev/null || true
      return 124  # código estándar de timeout
    fi
    sleep 5
    (( elapsed += 5 )) || true
  done

  # Recoger el exit code real del agente
  wait "$agent_pid" 2>/dev/null && exit_code=0 || exit_code=$?
  return "$exit_code"
}

# ── Parseo de argumentos ────────────────────────────────────────────────────

PLAN_FILE=""
ACTION="loop"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --status)    ACTION="status"; shift ;;
    --timeout)   TASK_TIMEOUT_MIN="$2"; shift 2 ;;
    --retries)   MAX_RETRIES="$2"; shift 2 ;;
    --devin)     BACKEND="devin"; shift ;;
    -h|--help)   usage ;;
    -*)          die "Opción desconocida: $1" ;;
    *)
      [[ -z "$PLAN_FILE" ]] || die "Solo se acepta un archivo de plan"
      PLAN_FILE="$1"; shift
      ;;
  esac
done

[[ -n "$PLAN_FILE" ]] || die "Falta el archivo del plan. Usa -h para ver la ayuda."
[[ -f "$PLAN_FILE" ]] || die "No se encontró: ${PLAN_FILE}"
PLAN_FILE="$(cd "$(dirname "$PLAN_FILE")" && pwd)/$(basename "$PLAN_FILE")"

# Log file junto al plan
LOG_FILE="$(dirname "$PLAN_FILE")/ralph-loop.log"

# ── Validaciones ─────────────────────────────────────────────────────────────

if [[ "$ACTION" == "status" ]]; then
  show_status
  exit 0
fi

if [[ "$BACKEND" == "devin" ]]; then
  command -v devin >/dev/null || die "Devin CLI no encontrado. Instálalo: curl -fsSL https://cli.devin.ai/install.sh | bash"
else
  command -v codex >/dev/null || die "Codex CLI no encontrado. Instálalo: npm install -g @openai/codex"
fi

total=$(count_tasks "$PLAN_FILE")
(( total > 0 )) || die "No se encontraron tareas (- [ ] / - [x]) en ${PLAN_FILE}"

pending=$(count_pending "$PLAN_FILE")

if (( pending == 0 )); then
  ok "¡No hay tareas pendientes! Todo completado."
  show_status
  exit 0
fi

# ── Ralph Loop v2.0 ─────────────────────────────────────────────────────────

info "Inicio del bucle Ralph v2.0"
info "Plan: ${PLAN_FILE}"
info "Log:  ${LOG_FILE}"
info "Backend: ${BACKEND} | Timeout por tarea: ${TASK_TIMEOUT_MIN} min | Reintentos: ${MAX_RETRIES}"

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║     Ralph Loop v2.1 + ${BACKEND^^} CLI             ║${RESET}"
echo -e "${BOLD}╠══════════════════════════════════════════════╣${RESET}"
echo -e "${BOLD}║  ${RESET}${pending}/${total} tareas pendientes${BOLD}                      ║${RESET}"
echo -e "${BOLD}║  ${RESET}Timeout: ${TASK_TIMEOUT_MIN} min | Retries: ${MAX_RETRIES}${BOLD}              ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════╝${RESET}"
echo ""

iteration=0
skipped=0
failed_tasks=()

while true; do
  task=$(get_next_pending_task)
  line_num=$(get_next_pending_line)

  [[ -n "$task" ]] || break

  (( iteration++ )) || true
  remaining=$(count_pending "$PLAN_FILE")

  echo -e "$(ts) ${BOLD}──────────────────────────────────────────────${RESET}"
  echo -e "$(ts) ${CYAN}  [iteración ${iteration}]${RESET}  ${YELLOW}${remaining} pendientes${RESET}"
  echo -e "$(ts)   ${BOLD}${task}${RESET}"
  echo -e "$(ts) ${BOLD}──────────────────────────────────────────────${RESET}"
  echo ""

  prompt=$(build_prompt "$task" "$line_num")
  task_start=$(date +%s)
  attempt=0
  task_done=false

  while (( attempt < MAX_RETRIES )); do
    (( attempt++ )) || true

    if (( attempt > 1 )); then
      warn "Reintento ${attempt}/${MAX_RETRIES} para: ${task}"
      sleep 5  # pausa breve entre reintentos
    fi

    info "Ejecutando ${BACKEND} CLI (intento ${attempt}/${MAX_RETRIES})..."
    echo ""

    if run_agent_with_timeout "$prompt"; then
      echo ""
      task_end=$(date +%s)
      duration=$(( task_end - task_start ))
      duration_fmt=$(printf '%02d:%02d' $((duration/60)) $((duration%60)))

      # Verificar si el agente marcó la tarea; si no, la marcamos nosotros
      if grep -qE '^\s*- \[ \]' "$PLAN_FILE" && \
         [[ "$(sed -n "${line_num}p" "$PLAN_FILE")" == *"- [ ]"* ]]; then
        mark_done "$line_num"
        ok "Tarea marcada como completada por ralph-loop [${duration_fmt}] (intento ${attempt})"
      else
        ok "Tarea completada (marcada por ${BACKEND}) [${duration_fmt}] (intento ${attempt})"
      fi
      task_done=true
      break
    else
      ec=$?
      task_end=$(date +%s)
      duration=$(( task_end - task_start ))

      if [[ "$ec" == "124" ]]; then
        warn "Timeout tras ${TASK_TIMEOUT_MIN} min (intento ${attempt}/${MAX_RETRIES})"
      else
        warn "${BACKEND} salió con error (exit code: ${ec}, intento ${attempt}/${MAX_RETRIES})"
      fi
    fi
  done

  if [[ "$task_done" == "false" ]]; then
    (( skipped++ )) || true
    failed_tasks+=("$task")
    warn "SALTADA tras ${MAX_RETRIES} intentos: ${task}"
    # Marcar como hecha para no bloquear el bucle, pero registrar el fallo
    mark_done "$line_num"
    warn "Marcada como [x] para continuar. Revisar manualmente."
  fi

  echo ""
done

# ── Resumen final ────────────────────────────────────────────────────────────

echo ""
if (( skipped > 0 )); then
  warn "¡Bucle completado con ${skipped} tarea(s) saltada(s)!"
  warn "Tareas que requieren revisión manual:"
  for ft in "${failed_tasks[@]}"; do
    warn "  - ${ft}"
  done
else
  ok "¡Todas las tareas han sido procesadas correctamente!"
fi
show_status
info "Log completo en: ${LOG_FILE}"
exit 0
