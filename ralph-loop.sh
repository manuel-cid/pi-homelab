#!/usr/bin/env bash
#
# ralph-loop.sh — "Ralph Loop" con Devin CLI
#
# Recorre las tareas pendientes (- [ ]) de un documento markdown y para cada
# una ejecuta `devin -p` pidiéndole que lea el plan, ejecute esa única tarea
# y la marque como completada. Devin trabaja sobre los ficheros locales.
#
# Requisitos:
#   - Devin CLI instalado (https://cli.devin.ai/install.sh)
#
# Uso:
#   ./ralph-loop.sh <plan.md>             # ejecuta el bucle sobre tareas pendientes
#   ./ralph-loop.sh <plan.md> --status    # muestra resumen de progreso
#
set -euo pipefail

# ── Configuración ────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Colores ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# ── Funciones auxiliares ─────────────────────────────────────────────────────

die()  { echo -e "${RED}ERROR: $*${RESET}" >&2; exit 1; }
info() { echo -e "${CYAN}[ralph]${RESET} $*"; }
warn() { echo -e "${YELLOW}[ralph]${RESET} $*"; }
ok()   { echo -e "${GREEN}[ralph]${RESET} $*"; }

usage() {
  cat <<EOF
Uso: $(basename "$0") <plan.md> [opciones]

  <plan.md>    Documento markdown con tareas en formato checkbox (- [ ] tarea)

Opciones:
  --status     Muestra resumen de progreso y sale
  -h, --help   Muestra esta ayuda

Requisitos:
  Devin CLI instalado y autenticado (devin --version)

Ejemplo:
  ./$(basename "$0") plans/PLAN.md
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
  grep -cE '^\s*- \[[ x]\]' "$1" || echo 0
}

count_done() {
  grep -cE '^\s*- \[x\]' "$1" 2>/dev/null || echo 0
}

count_pending() {
  grep -cE '^\s*- \[ \]' "$1" 2>/dev/null || echo 0
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
  echo -e "${BOLD}       Ralph Loop — Progreso${RESET}"
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

# ── Prompt para Devin ────────────────────────────────────────────────────────

build_prompt() {
  local task="$1"

  cat <<PROMPT
Lee el archivo ${PLAN_FILE} que contiene un plan con tareas en formato checkbox.

Tu trabajo es ejecutar ÚNICAMENTE la siguiente tarea:

${task}

Instrucciones:
1. Lee el plan completo en ${PLAN_FILE} para entender el contexto del proyecto.
2. Ejecuta SOLO la tarea indicada arriba. No toques ninguna otra tarea.
3. Sigue las convenciones de documentación definidas en el plan.
4. Una vez completada, marca esa tarea como hecha en ${PLAN_FILE} cambiando - [ ] por - [x].
5. NO renombres ni modifiques el nombre/ruta de NINGUNA otra tarea en ${PLAN_FILE}. Solo cambia el checkbox de la tarea actual.
6. NO cambies la estructura, orden ni formato del resto del archivo ${PLAN_FILE}.
PROMPT
}

# ── Parseo de argumentos ────────────────────────────────────────────────────

PLAN_FILE=""
ACTION="loop"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --status)   ACTION="status"; shift ;;
    -h|--help)  usage ;;
    -*)         die "Opción desconocida: $1" ;;
    *)
      [[ -z "$PLAN_FILE" ]] || die "Solo se acepta un archivo de plan"
      PLAN_FILE="$1"; shift
      ;;
  esac
done

[[ -n "$PLAN_FILE" ]] || die "Falta el archivo del plan. Usa -h para ver la ayuda."
[[ -f "$PLAN_FILE" ]] || die "No se encontró: ${PLAN_FILE}"
PLAN_FILE="$(cd "$(dirname "$PLAN_FILE")" && pwd)/$(basename "$PLAN_FILE")"

# ── Validaciones ─────────────────────────────────────────────────────────────

if [[ "$ACTION" == "status" ]]; then
  show_status
  exit 0
fi

command -v devin >/dev/null || die "Devin CLI no encontrado. Instálalo: curl -fsSL https://cli.devin.ai/install.sh | bash"

total=$(count_tasks "$PLAN_FILE")
(( total > 0 )) || die "No se encontraron tareas (- [ ] / - [x]) en ${PLAN_FILE}"

pending=$(count_pending "$PLAN_FILE")

if (( pending == 0 )); then
  ok "¡No hay tareas pendientes! Todo completado."
  show_status
  exit 0
fi

# ── Ralph Loop ───────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║        Ralph Loop + Devin CLI                ║${RESET}"
echo -e "${BOLD}╠══════════════════════════════════════════════╣${RESET}"
echo -e "${BOLD}║  ${RESET}${pending}/${total} tareas pendientes${BOLD}                      ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════╝${RESET}"
echo ""

iteration=0

while true; do
  task=$(get_next_pending_task)
  line_num=$(get_next_pending_line)

  [[ -n "$task" ]] || break

  (( iteration++ )) || true
  remaining=$(count_pending "$PLAN_FILE")

  echo -e "${BOLD}──────────────────────────────────────────────${RESET}"
  echo -e "${CYAN}  [iteración ${iteration}]${RESET}  ${YELLOW}${remaining} pendientes${RESET}"
  echo -e "  ${BOLD}${task}${RESET}"
  echo -e "${BOLD}──────────────────────────────────────────────${RESET}"
  echo ""

  prompt=$(build_prompt "$task")

  info "Ejecutando Devin CLI..."
  echo ""

  # Ejecutar devin en modo single-turn (-p) con permisos de escritura
  if devin --permission-mode dangerous -p "$prompt"; then
    echo ""
    # Verificar si Devin marcó la tarea; si no, la marcamos nosotros
    if grep -qE '^\s*- \[ \]' "$PLAN_FILE" && \
       [[ "$(sed -n "${line_num}p" "$PLAN_FILE")" == *"- [ ]"* ]]; then
      mark_done "$line_num"
      ok "Tarea marcada como completada por ralph-loop"
    else
      ok "Tarea completada (marcada por Devin)"
    fi
  else
    echo ""
    warn "Devin salió con error (exit code: $?)"
    echo ""
    show_status
    exit 1
  fi

  echo ""
done

# ── Fin ──────────────────────────────────────────────────────────────────────

echo ""
ok "¡Todas las tareas han sido procesadas!"
show_status
