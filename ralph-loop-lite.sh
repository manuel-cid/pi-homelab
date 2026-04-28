#!/usr/bin/env bash
#
# ralph-loop-lite.sh v1.0 — Versión genérica del Ralph Loop con Devin CLI
#
# Recorre las tareas pendientes (- [ ]) de un documento markdown y para cada
# una ejecuta `devin -p` con un prompt personalizable.
#
# Características:
#   - Prompt configurable via --prompt o --prompt-file con placeholders:
#       {{TASK}}      → texto del checkbox actual
#       {{TASK_FILE}} → ruta del fichero de subtareas (vacío si no aplica)
#       {{PLAN_FILE}} → ruta absoluta del plan principal
#   - Soporte de ficheros de subtareas: si un checkbox referencia un .md
#     existente, se itera sobre sus checkboxes internos. El checkbox padre
#     se marca como completado cuando todas las subtareas estén hechas.
#   - Timeout configurable por tarea (--timeout, defecto 20 min) con reintentos
#     automáticos (--retries, defecto 3).
#   - Todos los logs llevan timestamp (fecha y hora).
#   - Log estructurado a fichero (ralph-loop-lite.log junto al plan).
#   - Métricas por tarea: duración, intentos, estado.
#   - Exit codes: 0 = bucle completado correctamente, 2 = error fatal.
#
# Requisitos:
#   - Devin CLI instalado (https://cli.devin.ai/install.sh)
#
# Uso:
#   ./ralph-loop-lite.sh <plan.md> --prompt 'Haz: {{TASK}}'
#   ./ralph-loop-lite.sh <plan.md> --prompt-file prompt.txt
#   ./ralph-loop-lite.sh <plan.md> --prompt-file prompt.txt --status
#   ./ralph-loop-lite.sh <plan.md> --prompt-file prompt.txt --timeout 25 --retries 5
#
set -euo pipefail

# ── Configuración por defecto ────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TASK_TIMEOUT_MIN=20      # minutos máximos por intento de tarea
MAX_RETRIES=3            # reintentos por tarea antes de saltar
LOG_FILE="/dev/null"     # se sobreescribe tras parsear argumentos
PROMPT_TEMPLATE=""       # prompt inline
PROMPT_FILE=""           # fichero con el prompt

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
info() { echo -e "$(ts) ${CYAN}[ralph-lite]${RESET} $*"; log_file "INFO" "$*"; }
warn() { echo -e "$(ts) ${YELLOW}[ralph-lite]${RESET} $*"; log_file "WARN" "$*"; }
ok()   { echo -e "$(ts) ${GREEN}[ralph-lite]${RESET} $*"; log_file "OK" "$*"; }

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
  --prompt S       Prompt inline con placeholders ({{TASK}}, {{TASK_FILE}}, {{PLAN_FILE}})
  --prompt-file F  Fichero con el prompt (mismos placeholders)
  --timeout N      Minutos máximos por intento de tarea (defecto: ${TASK_TIMEOUT_MIN})
  --retries N      Reintentos por tarea antes de saltarla (defecto: ${MAX_RETRIES})
  --status         Muestra resumen de progreso y sale
  -h, --help       Muestra esta ayuda

Placeholders disponibles en el prompt:
  {{TASK}}       Texto del checkbox actual
  {{TASK_FILE}}  Ruta del fichero de subtareas (vacío si no aplica)
  {{PLAN_FILE}}  Ruta absoluta del plan principal

Subtareas:
  Si un checkbox referencia un fichero .md existente (ej. - [ ] subtasks/fase6.md),
  el script itera sobre los checkboxes internos de ese fichero. El checkbox padre
  se marca como completado cuando todas las subtareas estén hechas.

Requisitos:
  Devin CLI instalado y autenticado (devin --version)

Ejemplo:
  ./$(basename "$0") plan.md --prompt 'Ejecuta la tarea: {{TASK}}'
  ./$(basename "$0") plan.md --prompt-file prompt.txt
  ./$(basename "$0") plan.md --prompt-file prompt.txt --timeout 25 --retries 5
  ./$(basename "$0") plan.md --status
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
  local file="$1"
  local label="${2:-Plan principal}"
  local total done_count pending pct
  total=$(count_tasks "$file")
  done_count=$(count_done "$file")
  pending=$(count_pending "$file")
  pct=0
  (( total > 0 )) && pct=$(( done_count * 100 / total ))

  echo ""
  echo -e "${BOLD}══════════════════════════════════════${RESET}"
  echo -e "${BOLD}   Ralph Loop Lite v1.0 — ${label}${RESET}"
  echo -e "${BOLD}══════════════════════════════════════${RESET}"
  echo ""
  echo -e "  ${GREEN}Completadas${RESET}: ${done_count}/${total}  (${pct}%)"
  echo -e "  ${YELLOW}Pendientes${RESET} : ${pending}"
  echo ""
  progress_bar "$pct"
  echo ""
}

get_next_pending_task() {
  grep -m1 -E '^\s*- \[ \]' "$1" | sed 's/^\s*- \[ \] //'
}

get_next_pending_line() {
  grep -n -m1 -E '^\s*- \[ \]' "$1" | cut -d: -f1
}

mark_done() {
  local file="$1"
  local line_num="$2"
  if sed --version 2>/dev/null | grep -q GNU; then
    sed -i "${line_num}s/- \[ \]/- [x]/" "$file"
  else
    sed -i '' "${line_num}s/- \[ \]/- [x]/" "$file"
  fi
}

# ── Detección de ficheros de subtareas ───────────────────────────────────────
#
# Si el texto de un checkbox es una ruta a un fichero .md existente,
# se considera que contiene subtareas.

extract_md_reference() {
  # Extrae la ruta .md de un texto de tarea. Soporta rutas con o sin backticks.
  local task="$1"
  local ref
  # Intentar extraer ruta entre backticks
  ref=$(echo "$task" | grep -oE '`[^`]+\.md`' | head -1 | sed 's/`//g')
  if [[ -z "$ref" ]]; then
    # Intentar extraer ruta .md directa (sin backticks)
    ref=$(echo "$task" | grep -oE '[^ ]+\.md' | head -1)
  fi
  echo "$ref"
}

resolve_subtask_file() {
  # Dada una referencia .md del plan, intenta resolverla como ruta absoluta
  local ref="$1"
  local plan_dir
  plan_dir="$(dirname "$PLAN_FILE")"

  # Si ya es absoluta y existe
  if [[ "$ref" == /* ]] && [[ -f "$ref" ]]; then
    echo "$ref"
    return
  fi

  # Relativa al directorio del plan
  if [[ -f "${plan_dir}/${ref}" ]]; then
    echo "$(cd "$plan_dir" && realpath "$ref")"
    return
  fi

  # Relativa al directorio del script
  if [[ -f "${SCRIPT_DIR}/${ref}" ]]; then
    echo "$(cd "$SCRIPT_DIR" && realpath "$ref")"
    return
  fi

  # No encontrada
  echo ""
}

is_subtask_file() {
  local task="$1"
  local ref subtask_file
  ref=$(extract_md_reference "$task")
  [[ -z "$ref" ]] && return 1
  subtask_file=$(resolve_subtask_file "$ref")
  [[ -n "$subtask_file" ]] && [[ -f "$subtask_file" ]] && return 0
  return 1
}

get_subtask_file() {
  local task="$1"
  local ref
  ref=$(extract_md_reference "$task")
  resolve_subtask_file "$ref"
}

# ── Construcción del prompt ──────────────────────────────────────────────────

get_prompt_template() {
  if [[ -n "$PROMPT_TEMPLATE" ]]; then
    echo "$PROMPT_TEMPLATE"
  elif [[ -n "$PROMPT_FILE" ]]; then
    cat "$PROMPT_FILE"
  else
    die "No se proporcionó prompt. Usa --prompt o --prompt-file."
  fi
}

build_prompt() {
  local task="$1"
  local task_file="${2:-}"
  local template
  template=$(get_prompt_template)

  # Reemplazar placeholders
  template="${template//\{\{TASK\}\}/$task}"
  template="${template//\{\{TASK_FILE\}\}/$task_file}"
  template="${template//\{\{PLAN_FILE\}\}/$PLAN_FILE}"

  echo "$template"
}

# ── Ejecución con timeout ───────────────────────────────────────────────────

run_devin_with_timeout() {
  local prompt="$1"
  local timeout_secs=$(( TASK_TIMEOUT_MIN * 60 ))
  local devin_pid exit_code=0

  # Lanzar devin en background
  devin --permission-mode dangerous -p "$prompt" &
  devin_pid=$!

  # Esperar con timeout
  local elapsed=0
  while kill -0 "$devin_pid" 2>/dev/null; do
    if (( elapsed >= timeout_secs )); then
      warn "Timeout alcanzado (${TASK_TIMEOUT_MIN} min). Matando proceso Devin (PID ${devin_pid})..."
      kill "$devin_pid" 2>/dev/null || true
      sleep 2
      kill -9 "$devin_pid" 2>/dev/null || true
      wait "$devin_pid" 2>/dev/null || true
      return 124  # código estándar de timeout
    fi
    sleep 5
    (( elapsed += 5 )) || true
  done

  # Recoger el exit code real de devin
  wait "$devin_pid" 2>/dev/null && exit_code=0 || exit_code=$?
  return "$exit_code"
}

# ── Procesamiento de una tarea individual ────────────────────────────────────

process_single_task() {
  local task="$1"
  local task_file="${2:-}"
  local file="$3"
  local line_num="$4"

  local prompt task_start attempt task_done

  prompt=$(build_prompt "$task" "$task_file")
  task_start=$(date +%s)
  attempt=0
  task_done=false

  while (( attempt < MAX_RETRIES )); do
    (( attempt++ )) || true

    if (( attempt > 1 )); then
      warn "Reintento ${attempt}/${MAX_RETRIES} para: ${task}"
      sleep 5  # pausa breve entre reintentos
    fi

    info "Ejecutando Devin CLI (intento ${attempt}/${MAX_RETRIES})..."
    echo ""

    if run_devin_with_timeout "$prompt"; then
      echo ""
      local task_end duration duration_fmt
      task_end=$(date +%s)
      duration=$(( task_end - task_start ))
      duration_fmt=$(printf '%02d:%02d' $((duration/60)) $((duration%60)))

      # Verificar si Devin marcó la tarea; si no, la marcamos nosotros
      if [[ "$(sed -n "${line_num}p" "$file")" == *"- [ ]"* ]]; then
        mark_done "$file" "$line_num"
        ok "Tarea marcada como completada por ralph-loop-lite [${duration_fmt}] (intento ${attempt})"
      else
        ok "Tarea completada (marcada por Devin) [${duration_fmt}] (intento ${attempt})"
      fi
      task_done=true
      break
    else
      local ec=$?
      local task_end duration
      task_end=$(date +%s)
      duration=$(( task_end - task_start ))

      if [[ "$ec" == "124" ]]; then
        warn "Timeout tras ${TASK_TIMEOUT_MIN} min (intento ${attempt}/${MAX_RETRIES})"
      else
        warn "Devin salió con error (exit code: ${ec}, intento ${attempt}/${MAX_RETRIES})"
      fi
    fi
  done

  if [[ "$task_done" == "false" ]]; then
    return 1
  fi
  return 0
}

# ── Procesamiento de subtareas de un fichero ─────────────────────────────────

process_subtask_file() {
  local subtask_file="$1"
  local parent_task="$2"
  local sub_skipped=0
  local sub_failed_tasks=()
  local sub_iteration=0

  info "Procesando subtareas de: ${subtask_file}"
  info "Tarea padre: ${parent_task}"

  local sub_pending
  sub_pending=$(count_pending "$subtask_file")

  if (( sub_pending == 0 )); then
    ok "No hay subtareas pendientes en: ${subtask_file}"
    return 0
  fi

  info "${sub_pending} subtarea(s) pendiente(s) en: $(basename "$subtask_file")"
  echo ""

  while true; do
    local sub_task sub_line_num
    sub_task=$(get_next_pending_task "$subtask_file")
    sub_line_num=$(get_next_pending_line "$subtask_file")

    [[ -n "$sub_task" ]] || break

    (( sub_iteration++ )) || true
    local sub_remaining
    sub_remaining=$(count_pending "$subtask_file")

    echo -e "$(ts) ${BOLD}  ┌──────────────────────────────────────────${RESET}"
    echo -e "$(ts) ${CYAN}  │ [subtarea ${sub_iteration}]${RESET}  ${YELLOW}${sub_remaining} pendientes${RESET}"
    echo -e "$(ts)   │ ${BOLD}${sub_task}${RESET}"
    echo -e "$(ts) ${BOLD}  └──────────────────────────────────────────${RESET}"
    echo ""

    if process_single_task "$sub_task" "$subtask_file" "$subtask_file" "$sub_line_num"; then
      : # ok
    else
      (( sub_skipped++ )) || true
      sub_failed_tasks+=("$sub_task")
      warn "SUBTAREA SALTADA tras ${MAX_RETRIES} intentos: ${sub_task}"
      mark_done "$subtask_file" "$sub_line_num"
      warn "Marcada como [x] para continuar. Revisar manualmente."
    fi

    echo ""
  done

  if (( sub_skipped > 0 )); then
    warn "Subtareas completadas con ${sub_skipped} saltada(s) en: $(basename "$subtask_file")"
    for ft in "${sub_failed_tasks[@]}"; do
      warn "  - ${ft}"
    done
    return 1
  fi

  ok "Todas las subtareas completadas en: $(basename "$subtask_file")"
  return 0
}

# ── Parseo de argumentos ────────────────────────────────────────────────────

PLAN_FILE=""
ACTION="loop"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --status)       ACTION="status"; shift ;;
    --timeout)      TASK_TIMEOUT_MIN="$2"; shift 2 ;;
    --retries)      MAX_RETRIES="$2"; shift 2 ;;
    --prompt)       PROMPT_TEMPLATE="$2"; shift 2 ;;
    --prompt-file)  PROMPT_FILE="$2"; shift 2 ;;
    -h|--help)      usage ;;
    -*)             die "Opción desconocida: $1" ;;
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
LOG_FILE="$(dirname "$PLAN_FILE")/ralph-loop-lite.log"

# ── Validaciones ─────────────────────────────────────────────────────────────

if [[ "$ACTION" == "status" ]]; then
  show_status "$PLAN_FILE"
  exit 0
fi

# Validar que se proporcionó un prompt
if [[ -z "$PROMPT_TEMPLATE" ]] && [[ -z "$PROMPT_FILE" ]]; then
  die "Debes proporcionar un prompt con --prompt o --prompt-file."
fi

if [[ -n "$PROMPT_FILE" ]] && [[ ! -f "$PROMPT_FILE" ]]; then
  die "Fichero de prompt no encontrado: ${PROMPT_FILE}"
fi

command -v devin >/dev/null || die "Devin CLI no encontrado. Instálalo: curl -fsSL https://cli.devin.ai/install.sh | bash"

total=$(count_tasks "$PLAN_FILE")
(( total > 0 )) || die "No se encontraron tareas (- [ ] / - [x]) en ${PLAN_FILE}"

pending=$(count_pending "$PLAN_FILE")

if (( pending == 0 )); then
  ok "¡No hay tareas pendientes! Todo completado."
  show_status "$PLAN_FILE"
  exit 0
fi

# ── Ralph Loop Lite v1.0 ────────────────────────────────────────────────────

info "Inicio del bucle Ralph Lite v1.0"
info "Plan: ${PLAN_FILE}"
info "Log:  ${LOG_FILE}"
info "Timeout por tarea: ${TASK_TIMEOUT_MIN} min | Reintentos: ${MAX_RETRIES}"
if [[ -n "$PROMPT_FILE" ]]; then
  info "Prompt: fichero ${PROMPT_FILE}"
else
  info "Prompt: inline (${#PROMPT_TEMPLATE} chars)"
fi

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║      Ralph Loop Lite v1.0 + Devin CLI        ║${RESET}"
echo -e "${BOLD}╠══════════════════════════════════════════════╣${RESET}"
echo -e "${BOLD}║  ${RESET}${pending}/${total} tareas pendientes${BOLD}                      ║${RESET}"
echo -e "${BOLD}║  ${RESET}Timeout: ${TASK_TIMEOUT_MIN} min | Retries: ${MAX_RETRIES}${BOLD}              ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════╝${RESET}"
echo ""

iteration=0
skipped=0
failed_tasks=()

while true; do
  task=$(get_next_pending_task "$PLAN_FILE")
  line_num=$(get_next_pending_line "$PLAN_FILE")

  [[ -n "$task" ]] || break

  (( iteration++ )) || true
  remaining=$(count_pending "$PLAN_FILE")

  echo -e "$(ts) ${BOLD}──────────────────────────────────────────────${RESET}"
  echo -e "$(ts) ${CYAN}  [iteración ${iteration}]${RESET}  ${YELLOW}${remaining} pendientes${RESET}"
  echo -e "$(ts)   ${BOLD}${task}${RESET}"
  echo -e "$(ts) ${BOLD}──────────────────────────────────────────────${RESET}"
  echo ""

  # Comprobar si la tarea referencia un fichero de subtareas
  if is_subtask_file "$task"; then
    subtask_file=$(get_subtask_file "$task")
    info "Detectado fichero de subtareas: ${subtask_file}"

    if process_subtask_file "$subtask_file" "$task"; then
      # Todas las subtareas completadas → marcar checkbox padre
      if [[ "$(sed -n "${line_num}p" "$PLAN_FILE")" == *"- [ ]"* ]]; then
        mark_done "$PLAN_FILE" "$line_num"
        ok "Tarea padre marcada como completada: ${task}"
      fi
    else
      (( skipped++ )) || true
      failed_tasks+=("$task (subtareas con fallos)")
      warn "Tarea padre con subtareas fallidas: ${task}"
      # Marcar padre para no bloquear el bucle
      mark_done "$PLAN_FILE" "$line_num"
      warn "Marcada como [x] para continuar. Revisar manualmente."
    fi
  else
    # Tarea normal (sin fichero de subtareas)
    if process_single_task "$task" "" "$PLAN_FILE" "$line_num"; then
      : # ok
    else
      (( skipped++ )) || true
      failed_tasks+=("$task")
      warn "SALTADA tras ${MAX_RETRIES} intentos: ${task}"
      mark_done "$PLAN_FILE" "$line_num"
      warn "Marcada como [x] para continuar. Revisar manualmente."
    fi
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
show_status "$PLAN_FILE"
info "Log completo en: ${LOG_FILE}"
exit 0
