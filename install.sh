#!/usr/bin/env bash
# herdr-gentle: Gentle AI dentro de herdr, sin Gentle Shell.
#   - skills, persona y MCP (Engram, Context7, CodeGraph) en todos tus agentes
#   - plugin gentle.herdr: modelo/contexto/tokens/costo en la barra lateral,
#     panel de Agentes / Consumo / Cambios
#   - gentle-herdr + skill: subagentes de fondo en paneles de herdr
#
# Uso: ./install.sh [opciones]
#   --agents a,b       Agentes (defecto: los detectados en PATH).
#                      Soportados: claude-code, opencode, codex, gemini-cli, cursor
#   --gentle-install   Ejecuta `gentle-ai install` para esos agentes (si Gentle AI
#                      ya está instalado, por defecto solo se hace `gentle-ai sync`)
#   --skip-gentle      No tocar la configuración de Gentle AI
#   --persona P        gentleman (defecto) | neutral | custom   (con --gentle-install)
#   --no-codegraph     No instalar CodeGraph
#   --no-sidebar       No cambiar la barra lateral de herdr
#   --no-keys          No añadir atajos
#   --dry-run          Solo mostrar lo que se haría
#   -h, --help         Esta ayuda
set -u

HG_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HG_ROOT/lib/common.sh"

MIN_HERDR="0.9.0"
AGENTS=""; PERSONA="gentleman"; GENTLE_MODE="auto"
WITH_CODEGRAPH=1; WITH_SIDEBAR=1; WITH_KEYS=1

usage() { sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --agents|--agent) AGENTS="$2"; shift 2 ;;
    --persona)        PERSONA="$2"; shift 2 ;;
    --gentle-install) GENTLE_MODE="install"; shift ;;
    --skip-gentle)    GENTLE_MODE="skip"; shift ;;
    --no-codegraph)   WITH_CODEGRAPH=0; shift ;;
    --no-sidebar)     WITH_SIDEBAR=0; shift ;;
    --no-keys)        WITH_KEYS=0; shift ;;
    --dry-run)        HG_DRY_RUN=1; export HG_DRY_RUN; shift ;;
    -h|--help)        usage 0 ;;
    *) fail "Opción desconocida: $1"; usage 1 ;;
  esac
done

# ---------------------------------------------------------------------------
step "1/7 Prerrequisitos"
# ---------------------------------------------------------------------------
missing=0
for bin in git node; do
  if have "$bin"; then ok "$bin"; else fail "$bin no está en PATH"; missing=1; fi
done
if have herdr; then
  hv="$(herdr --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  if [ -n "$hv" ] && ! version_ge "$hv" "$MIN_HERDR"; then
    fail "herdr $hv es antiguo; hace falta >= $MIN_HERDR (herdr update / brew upgrade herdr)"; missing=1
  else ok "herdr ${hv:-?}"; fi
else
  fail "herdr no está instalado → curl -fsSL https://herdr.dev/install.sh | sh"; missing=1
fi
if have gentle-ai; then ok "gentle-ai $(gentle-ai version 2>/dev/null | head -1)"
elif [ "$GENTLE_MODE" != skip ]; then
  fail "gentle-ai no está instalado → brew install gentleman-programming/tap/gentle-ai"; missing=1
fi
[ "$missing" = 1 ] && [ "$HG_DRY_RUN" != 1 ] && die "Instala lo que falta y vuelve a ejecutar ./install.sh"

# ---------------------------------------------------------------------------
step "2/7 Agentes"
# ---------------------------------------------------------------------------
if [ -z "$AGENTS" ]; then
  AGENTS="$(detect_agents)"
  [ -n "$AGENTS" ] || die "No encontré agentes en PATH (claude, opencode, codex, gemini, cursor-agent). Usa --agents."
  info "Detectados: $AGENTS"
fi
AGENT_LIST="$(split_list "$AGENTS")"
for a in $AGENT_LIST; do
  [ "$a" = pi ] && die "'pi' es el runtime de Gentle Shell; este kit lo excluye a propósito."
  is_supported_agent "$a" || die "Agente no soportado: $a (soportados: $HG_AGENTS)"
  ok "$a"
done
AGENTS_CSV="$(echo "$AGENT_LIST" | tr ' ' ',')"

# ---------------------------------------------------------------------------
step "3/7 Gentle AI (skills, persona, Engram, Context7)"
# ---------------------------------------------------------------------------
GA_STATE="${GENTLE_AI_HOME:-$HOME/.gentle-ai}/state.json"
if [ "$GENTLE_MODE" = auto ]; then
  if [ -f "$GA_STATE" ]; then GENTLE_MODE=sync; else GENTLE_MODE=install; fi
fi
case "$GENTLE_MODE" in
  skip) info "Omitido (--skip-gentle)" ;;
  sync)
    info "Gentle AI ya está instalado: refresco tu selección actual (usa --gentle-install para añadir agentes)"
    run gentle-ai sync || warn "gentle-ai sync falló; revisa la salida" ;;
  install)
    comps="engram,skills,context7,persona,permissions"
    [ "$PERSONA" = custom ] && comps="engram,skills,context7,permissions"
    ga=(install --agent "$AGENTS_CSV" --component "$comps")
    [ "$PERSONA" != custom ] && ga+=(--persona "$PERSONA")
    [ "$HG_DRY_RUN" = 1 ] && ga+=(--dry-run)
    printf '    %s$ gentle-ai %s%s\n' "$C_BOLD" "${ga[*]}" "$C_RESET"
    if have gentle-ai; then gentle-ai "${ga[@]}" || die "gentle-ai install falló"; fi ;;
esac

# ---------------------------------------------------------------------------
step "4/7 CodeGraph"
# ---------------------------------------------------------------------------
if [ "$WITH_CODEGRAPH" = 1 ]; then
  targets=""
  for a in $AGENT_LIST; do t="$(agent_codegraph_target "$a")"; [ -n "$t" ] && targets="$targets${targets:+,}$t"; done
  if have codegraph; then ok "codegraph ya instalado"
  elif have npm; then run npm install -g @colbymchenry/codegraph@latest || die "No pude instalar CodeGraph"
  elif have pnpm; then run pnpm add -g @colbymchenry/codegraph@latest || die "No pude instalar CodeGraph"
  else die "CodeGraph necesita npm o pnpm"; fi
  run codegraph install --target "$targets" --location global --yes || die "codegraph install falló ($targets)"
else info "Omitido (--no-codegraph)"; fi

# ---------------------------------------------------------------------------
step "5/7 Skills para todos los agentes: herdr + gentle-herdr"
# ---------------------------------------------------------------------------
for a in $AGENT_LIST; do
  dir="$(agent_skills_dir "$a")"
  [ -n "$dir" ] || continue
  run mkdir -p "$dir/herdr"
  # Enlace: un `git pull` de este repo actualiza la skill en todos los agentes.
  run ln -sfn "$HG_ROOT/skills/gentle-herdr" "$dir/gentle-herdr"
  # Copia de la skill oficial de herdr que corresponde al binario instalado.
  if [ "$HG_DRY_RUN" != 1 ] && have herdr; then herdr --skill > "$dir/herdr/SKILL.md"; fi
  ok "$a → $dir/{herdr,gentle-herdr}"
done
for a in $AGENT_LIST; do
  integ="$(agent_herdr_integration "$a")"
  [ -n "$integ" ] && { run herdr integration install "$integ" || warn "integración herdr '$integ' falló"; }
done

# ---------------------------------------------------------------------------
step "6/7 Plugin gentle.herdr y comandos"
# ---------------------------------------------------------------------------
if [ "$HG_DRY_RUN" = 1 ] || ! herdr plugin list 2>/dev/null | grep -q 'gentle.herdr'; then
  run herdr plugin link "$HG_ROOT/plugin" || die "herdr plugin link falló"
else ok "plugin gentle.herdr ya enlazado"; fi
if [ "$HG_DRY_RUN" != 1 ]; then
  pcfg="$(herdr plugin config-dir gentle.herdr 2>/dev/null | tail -1)"
  if [ -n "$pcfg" ] && [ ! -f "$pcfg/prices.json" ]; then
    mkdir -p "$pcfg" && cp "$HG_ROOT/plugin/prices.json" "$pcfg/prices.json" && ok "precios editables en $pcfg/prices.json"
  fi
fi
bin_dir="$HOME/.local/bin"
run mkdir -p "$bin_dir"
run ln -sf "$HG_ROOT/plugin/bin/gentle-herdr.mjs" "$bin_dir/gentle-herdr"
run ln -sf "$HG_ROOT/scripts/doctor.sh" "$bin_dir/herdr-gentle-doctor"
run ln -sf "$HG_ROOT/scripts/project-init.sh" "$bin_dir/herdr-gentle-init"
case ":$PATH:" in *":$bin_dir:"*) ;; *) warn "Añade $bin_dir a tu PATH (los agentes necesitan ver gentle-herdr)";; esac

# ---------------------------------------------------------------------------
step "7/7 Configuración de herdr"
# ---------------------------------------------------------------------------
cfg="${XDG_CONFIG_HOME:-$HOME/.config}/herdr/config.toml"
begin="# >>> herdr-gentle >>>"; end="# <<< herdr-gentle <<<"
if [ "$HG_DRY_RUN" = 1 ]; then
  info "Insertaría atajos y barra lateral en $cfg"
elif [ "$WITH_KEYS" = 1 ] || [ "$WITH_SIDEBAR" = 1 ]; then
  mkdir -p "$(dirname "$cfg")"; touch "$cfg"
  cp "$cfg" "$cfg.bak.$(date +%Y%m%d%H%M%S)"
  awk -v b="$begin" -v e="$end" '$0==b{skip=1} !skip{print} $0==e{skip=0}' "$cfg" > "$cfg.tmp" && mv "$cfg.tmp" "$cfg"
  block=""
  [ "$WITH_KEYS" = 1 ] && block="$(cat "$HG_ROOT/config/keys.toml")"
  if [ "$WITH_SIDEBAR" = 1 ]; then
    if grep -q '^\[ui\.sidebar\.agents\]' "$cfg"; then
      warn "Ya tienes [ui.sidebar.agents]; no la piso. Copia las filas de config/sidebar.toml a mano."
    else block="$block"$'\n\n'"$(cat "$HG_ROOT/config/sidebar.toml")"; fi
  fi
  printf '\n%s\n%s\n%s\n' "$begin" "$block" "$end" >> "$cfg"
  ok "$cfg actualizado (backup creado)"
fi

step "Listo"
info "1. Reinicia herdr (o recarga config) y tus agentes."
info "2. prefix+a  agentes · prefix+u consumo · prefix+alt+c cambios · prefix+alt+m memoria"
info "3. Pide a cualquier agente: \"delega la exploración en un subagente codex\" (skill gentle-herdr)"
info "4. herdr-gentle-init .   indexa el proyecto · herdr-gentle-doctor   verifica todo"
