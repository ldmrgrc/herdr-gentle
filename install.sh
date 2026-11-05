#!/usr/bin/env bash
# herdr-gentle: usa las skills, la configuración y los MCP de Gentle AI
# (Engram, Context7, CodeGraph) dentro de herdr, sin Gentle Shell.
#
# Uso: ./install.sh [opciones]
#   --agents a,b       Agentes a configurar (por defecto: los detectados en PATH).
#                      Soportados: claude-code, opencode, codex, gemini-cli, cursor
#   --persona P        gentleman (defecto) | neutral | custom
#   --skills a,b       Skills extra de Gentle AI (ej: branch-pr,issue-creation)
#   --components a,b   Reemplaza la lista de componentes de gentle-ai
#                      (defecto: engram,skills,context7,persona,permissions)
#   --channel C        stable (defecto) | beta
#   --no-codegraph     No instalar CodeGraph
#   --no-herdr-keys    No añadir atajos a ~/.config/herdr/config.toml
#   --dry-run          Solo mostrar lo que se haría
#   -h, --help         Esta ayuda
set -u

HG_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HG_ROOT/lib/common.sh"

AGENTS=""
PERSONA="gentleman"
EXTRA_SKILLS=""
COMPONENTS="engram,skills,context7,persona,permissions"
CHANNEL="stable"
WITH_CODEGRAPH=1
WITH_KEYS=1

usage() { sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --agents|--agent) AGENTS="$2"; shift 2 ;;
    --persona)        PERSONA="$2"; shift 2 ;;
    --skills|--skill) EXTRA_SKILLS="$2"; shift 2 ;;
    --components)     COMPONENTS="$2"; shift 2 ;;
    --channel)        CHANNEL="$2"; shift 2 ;;
    --no-codegraph)   WITH_CODEGRAPH=0; shift ;;
    --no-herdr-keys)  WITH_KEYS=0; shift ;;
    --dry-run)        HG_DRY_RUN=1; export HG_DRY_RUN; shift ;;
    -h|--help)        usage 0 ;;
    *) fail "Opción desconocida: $1"; usage 1 ;;
  esac
done

# --persona custom significa "sin persona gestionada": quitamos el componente.
if [ "$PERSONA" = custom ]; then
  COMPONENTS="$(echo ",$COMPONENTS," | sed 's/,persona,/,/g; s/^,//; s/,$//')"
fi
if [ -n "$EXTRA_SKILLS" ] && ! echo ",$COMPONENTS," | grep -q ',skills,'; then
  die "--skills requiere el componente 'skills' en --components"
fi

# ---------------------------------------------------------------------------
step "1/6 Prerrequisitos"
# ---------------------------------------------------------------------------
missing=0
for bin in git node npm; do
  if have "$bin"; then ok "$bin"; else fail "$bin no está en PATH"; missing=1; fi
done
if have herdr; then
  ok "herdr $(herdr --version 2>/dev/null | head -1)"
else
  fail "herdr no está instalado → curl -fsSL https://herdr.dev/install.sh | sh  (o: brew install herdr)"
  missing=1
fi
if have gentle-ai; then
  ok "gentle-ai $(gentle-ai version 2>/dev/null | head -1)"
else
  fail "gentle-ai no está instalado →"
  info "  macOS/Linux con brew: brew install gentleman-programming/tap/gentle-ai"
  info "  con Go:               go install github.com/gentleman-programming/gentle-ai/v4/cmd/gentle-ai@latest"
  missing=1
fi
if [ "$missing" = 1 ] && [ "$HG_DRY_RUN" != 1 ]; then
  die "Instala lo que falta y vuelve a ejecutar ./install.sh"
fi

# ---------------------------------------------------------------------------
step "2/6 Agentes"
# ---------------------------------------------------------------------------
if [ -z "$AGENTS" ]; then
  AGENTS="$(detect_agents)"
  [ -n "$AGENTS" ] || die "No encontré ningún agente en PATH (claude, opencode, codex, gemini, cursor-agent). Usa --agents."
  info "Detectados: $AGENTS"
fi
AGENT_LIST="$(split_list "$AGENTS")"
for a in $AGENT_LIST; do
  [ "$a" = pi ] && die "'pi' es el runtime de Gentle Shell; este kit lo excluye a propósito."
  is_supported_agent "$a" || die "Agente no soportado: $a (soportados: $HG_AGENTS)"
  if have "$(agent_bin "$a")"; then ok "$a"; else warn "$a: no veo '$(agent_bin "$a")' en PATH; se configurará igualmente"; fi
done
AGENTS_CSV="$(echo "$AGENT_LIST" | tr ' ' ',')"

# ---------------------------------------------------------------------------
step "3/6 Gentle AI: skills, persona, permisos, Engram y Context7"
# ---------------------------------------------------------------------------
# gentle-ai escribe la configuración nativa de cada agente (CLAUDE.md, skills,
# settings.json, ~/.claude.json, opencode.json, ...), con backup previo.
# No se instala Gentle Shell ni Pi.
ga_args=(install --agent "$AGENTS_CSV" --component "$COMPONENTS" --channel "$CHANNEL")
if echo ",$COMPONENTS," | grep -q ',persona,'; then ga_args+=(--persona "$PERSONA"); fi
[ -n "$EXTRA_SKILLS" ] && ga_args+=(--skills "$EXTRA_SKILLS")
[ "$HG_DRY_RUN" = 1 ] && ga_args+=(--dry-run)
# En --dry-run, gentle-ai muestra su propio plan, así que lo ejecutamos de verdad.
if have gentle-ai; then
  printf '    %s$ gentle-ai %s%s\n' "$C_BOLD" "${ga_args[*]}" "$C_RESET"
  gentle-ai "${ga_args[@]}" || die "gentle-ai install falló (revisa la salida de arriba)"
else
  info "\$ gentle-ai ${ga_args[*]}"
fi

# ---------------------------------------------------------------------------
step "4/6 CodeGraph (MCP de grafo de símbolos)"
# ---------------------------------------------------------------------------
# gentle-ai solo ofrece CodeGraph desde su TUI ("Community Tools"); aquí
# hacemos los mismos pasos que su instalador, sin TUI.
if [ "$WITH_CODEGRAPH" = 1 ]; then
  targets=""
  for a in $AGENT_LIST; do
    t="$(agent_codegraph_target "$a")"
    [ -n "$t" ] && targets="$targets${targets:+,}$t"
  done
  if have codegraph; then
    ok "codegraph ya instalado ($(codegraph --version 2>/dev/null | head -1))"
  elif have npm; then
    run npm install -g @colbymchenry/codegraph@latest || die "No pude instalar CodeGraph con npm"
  elif have pnpm; then
    run pnpm add -g @colbymchenry/codegraph@latest || die "No pude instalar CodeGraph con pnpm"
  else
    die "CodeGraph necesita npm o pnpm"
  fi
  run codegraph install --target "$targets" --location global --yes \
    || die "codegraph install falló para: $targets"
  info "Indexa cada proyecto con: ./scripts/project-init.sh <ruta>  (o prefix+alt+g en herdr)"
else
  info "Omitido (--no-codegraph)"
fi

# ---------------------------------------------------------------------------
step "5/6 herdr: integraciones de agente y skill 'herdr'"
# ---------------------------------------------------------------------------
for a in $AGENT_LIST; do
  integ="$(agent_herdr_integration "$a")"
  if [ -n "$integ" ]; then
    run herdr integration install "$integ" || warn "No pude instalar la integración herdr '$integ'"
  else
    info "$a: herdr lo detecta por pantalla (sin integración nativa)"
  fi
done
# Skill oficial de herdr: permite al agente manejar paneles/agentes vecinos.
if have npx; then
  run npx -y skills add herdrdev/herdr --skill herdr -g -y \
    || warn "npx skills falló; instala la skill a mano con: herdr --skill"
fi
# Respaldo para Claude Code: copia la versión que trae el binario de herdr.
if echo " $AGENT_LIST " | grep -q ' claude-code ' && have herdr; then
  claude_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  if [ ! -f "$claude_dir/skills/herdr/SKILL.md" ]; then
    run mkdir -p "$claude_dir/skills/herdr"
    [ "$HG_DRY_RUN" = 1 ] || herdr --skill > "$claude_dir/skills/herdr/SKILL.md"
    ok "skill herdr → $claude_dir/skills/herdr/SKILL.md"
  fi
fi

# ---------------------------------------------------------------------------
step "6/6 Atajos de herdr y comando herdr-gentle-doctor"
# ---------------------------------------------------------------------------
bin_dir="$HOME/.local/bin"
run mkdir -p "$bin_dir"
run ln -sf "$HG_ROOT/scripts/doctor.sh" "$bin_dir/herdr-gentle-doctor"
run ln -sf "$HG_ROOT/scripts/project-init.sh" "$bin_dir/herdr-gentle-init"
case ":$PATH:" in *":$bin_dir:"*) ;; *) warn "Añade $bin_dir a tu PATH para usar herdr-gentle-doctor";; esac

if [ "$WITH_KEYS" = 1 ]; then
  cfg="${XDG_CONFIG_HOME:-$HOME/.config}/herdr/config.toml"
  begin="# >>> herdr-gentle >>>"; end="# <<< herdr-gentle <<<"
  if [ "$HG_DRY_RUN" = 1 ]; then
    info "Insertaría config/herdr-gentle.toml en $cfg"
  else
    mkdir -p "$(dirname "$cfg")"
    if [ -f "$cfg" ]; then
      cp "$cfg" "$cfg.bak.$(date +%Y%m%d%H%M%S)"
      # Quita un bloque anterior para que la instalación sea idempotente.
      awk -v b="$begin" -v e="$end" '$0==b{skip=1} !skip{print} $0==e{skip=0}' "$cfg" > "$cfg.tmp" && mv "$cfg.tmp" "$cfg"
    fi
    { printf '\n%s\n' "$begin"; cat "$HG_ROOT/config/herdr-gentle.toml"; printf '%s\n' "$end"; } >> "$cfg"
    ok "Atajos añadidos a $cfg (backup creado). Recarga herdr o reinícialo."
  fi
fi

step "Listo"
info "1. Reinicia tus agentes para que carguen la nueva configuración."
info "2. Abre herdr en tu proyecto:  cd mi-proyecto && herdr"
info "3. Indexa el proyecto:          herdr-gentle-init .   (o prefix+alt+g)"
info "4. Verifica todo:               herdr-gentle-doctor   (o prefix+alt+d)"
