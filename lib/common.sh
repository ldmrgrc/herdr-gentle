# shellcheck shell=bash
# Funciones compartidas por install.sh, scripts/doctor.sh y scripts/project-init.sh.

set -o pipefail

HG_ROOT="${HG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
HG_DRY_RUN="${HG_DRY_RUN:-0}"

if [ -t 1 ]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'
else
  C_RESET=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""
fi

step() { printf '\n%s==> %s%s\n' "$C_BOLD$C_BLUE" "$*" "$C_RESET"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    %s✔%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '    %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
fail() { printf '    %s✘%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die()  { fail "$*"; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

# run CMD ARGS... — ejecuta (o solo muestra en --dry-run) un comando.
run() {
  printf '    %s$ %s%s\n' "$C_BOLD" "$*" "$C_RESET"
  [ "$HG_DRY_RUN" = 1 ] && return 0
  "$@"
}

# ---------------------------------------------------------------------------
# Tabla de agentes soportados.
#   id de gentle-ai | binario | comando hc | target codegraph
# Pi queda fuera a propósito: es el runtime de Gentle Shell.
# ---------------------------------------------------------------------------
HG_AGENTS="claude-code opencode codex gemini-cli cursor"

agent_bin() {
  case "$1" in
    claude-code) echo claude ;;
    opencode)    echo opencode ;;
    codex)       echo codex ;;
    gemini-cli)  echo gemini ;;
    cursor)      echo cursor-agent ;;
  esac
}

# Comando con el que herdr-core arranca cada agente (templates de hc).
agent_hc_command() {
  case "$1" in
    claude-code) echo "claude" ;;
    codex)       echo "codex --no-daemon" ;;   # hc lo exige: sin --no-daemon los comandos corren fuera de hc
    opencode)    echo "opencode" ;;
    gemini-cli)  echo "gemini" ;;
    cursor)      echo "cursor-agent" ;;
  esac
}

# Agentes que reportan su estado con OSC 7501; el resto arranca con ready: quiet.
agent_reports_status() { case "$1" in claude-code|codex) return 0 ;; *) return 1 ;; esac; }

# Nombre corto para los templates gentle-<rol>-<agente>.
agent_short() { case "$1" in claude-code) echo claude ;; gemini-cli) echo gemini ;; *) echo "$1" ;; esac; }

agent_codegraph_target() {
  case "$1" in
    claude-code) echo claude ;;
    opencode)    echo opencode ;;
    codex)       echo codex ;;
    gemini-cli)  echo gemini ;;
    cursor)      echo cursor ;;
  esac
}

# Comando que lista los MCP configurados para el agente (vacío = no hay CLI).
agent_mcp_list_cmd() {
  case "$1" in
    claude-code) echo "claude mcp list" ;;
    opencode)    echo "opencode mcp list" ;;
    codex)       echo "codex mcp list" ;;
    gemini-cli)  echo "gemini mcp list" ;;
    *)           echo "" ;;
  esac
}

# Carpeta global de skills de cada agente (formato SKILL.md).
agent_skills_dir() {
  case "$1" in
    claude-code) echo "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills" ;;
    codex)       echo "${CODEX_HOME:-$HOME/.codex}/skills" ;;
    opencode)    echo "${XDG_CONFIG_HOME:-$HOME/.config}/opencode/skills" ;;
    gemini-cli)  echo "$HOME/.gemini/skills" ;;
    cursor)      echo "$HOME/.cursor/skills" ;;
  esac
}

# Versión "x.y.z" >= "a.b.c"
version_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]; }

is_supported_agent() {
  local a
  for a in $HG_AGENTS; do [ "$a" = "$1" ] && return 0; done
  return 1
}

detect_agents() {
  local a found=""
  for a in $HG_AGENTS; do
    have "$(agent_bin "$a")" && found="$found${found:+,}$a"
  done
  echo "$found"
}

# Convierte "a,b c" en "a b c".
split_list() { echo "$1" | tr ',' ' ' | xargs; }
