#!/usr/bin/env bash
# herdr-gentle: Gentle AI dentro de la app de escritorio Herdr (herdr-app +
# herdr-core), sin Gentle Shell y sin tocar la TUI `herdr`.
#   - skills, persona y MCP (Engram, Context7, CodeGraph) en todos tus agentes
#   - mod "Gentle" para la app: agentes y subagentes con modelo, contexto,
#     tokens y costo; consumo del día; tema Gentleman
#   - roles de Gentle como templates de herdr-core: gentle-<rol>-<agente>
#   - skills herdr-core + gentle-herdr: delegar en subagentes de fondo con hc
#
# Uso: ./install.sh [opciones]
#   --agents a,b       Agentes (defecto: los detectados en PATH).
#                      Soportados: claude-code, opencode, codex, gemini-cli, cursor
#   --gentle-install   Ejecuta `gentle-ai install` para esos agentes (si Gentle AI
#                      ya está instalado, por defecto solo se hace `gentle-ai sync`)
#   --skip-gentle      No tocar la configuración de Gentle AI
#   --persona P        gentleman (defecto) | neutral | custom   (con --gentle-install)
#   --theme            Activa el tema Gentleman en la app
#   --no-codegraph     No instalar CodeGraph
#   --dry-run          Solo mostrar lo que se haría
#   -h, --help         Esta ayuda
set -u

HG_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HG_ROOT/lib/common.sh"

AGENTS=""; PERSONA="gentleman"; GENTLE_MODE="auto"; WITH_CODEGRAPH=1; APPLY_THEME=0
APP_HOME="${HERDR_APP_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr-app}"
HC_TEMPLATES="${XDG_CONFIG_HOME:-$HOME/.config}/herdr-core/templates"

usage() { sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --agents|--agent) AGENTS="$2"; shift 2 ;;
    --persona)        PERSONA="$2"; shift 2 ;;
    --gentle-install) GENTLE_MODE="install"; shift ;;
    --skip-gentle)    GENTLE_MODE="skip"; shift ;;
    --theme)          APPLY_THEME=1; shift ;;
    --no-codegraph)   WITH_CODEGRAPH=0; shift ;;
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
if have herdr-app; then ok "herdr-app (la app de escritorio)"
else fail "herdr-app no está instalado → curl -fsSL https://releases.herdr.dev/app/install.sh | sh  (o brew install --cask herdr-app)"; missing=1; fi
if have hc; then ok "herdr-core (hc)"
else fail "herdr-core (hc) no está → lo instala el instalador de la app, o: curl -fsSL https://releases.herdr.dev/core/install.sh | sh"; missing=1; fi
if have gentle-ai; then ok "gentle-ai"
elif [ "$GENTLE_MODE" != skip ]; then fail "gentle-ai no está → brew install gentleman-programming/tap/gentle-ai"; missing=1; fi
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
    info "Gentle AI ya está instalado: refresco tu selección (usa --gentle-install para añadir agentes)"
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
step "5/7 Skills herdr-core + gentle-herdr en cada agente"
# ---------------------------------------------------------------------------
for a in $AGENT_LIST; do
  dir="$(agent_skills_dir "$a")"
  [ -n "$dir" ] || continue
  run mkdir -p "$dir"
  # Enlaces: un `git pull` de este repo actualiza las skills en todos los agentes.
  run ln -sfn "$HG_ROOT/skills/gentle-herdr" "$dir/gentle-herdr"
  [ -e "$dir/herdr-core" ] && [ ! -L "$dir/herdr-core" ] && info "$a: ya tiene su skill herdr-core; la dejo" \
    || run ln -sfn "$HG_ROOT/skills/herdr-core" "$dir/herdr-core"
  # La skill de la TUI (`herdr`) confunde a los agentes dentro de la app.
  if [ -f "$dir/herdr/SKILL.md" ] && grep -q '^name: herdr$' "$dir/herdr/SKILL.md"; then
    warn "$a: tiene la skill 'herdr' de la TUI en $dir/herdr; si solo usas la app, bórrala"
  fi
  ok "$a → $dir/{herdr-core,gentle-herdr}"
done

# ---------------------------------------------------------------------------
step "6/7 Roles de Gentle como templates de herdr-core"
# ---------------------------------------------------------------------------
run mkdir -p "$HC_TEMPLATES"
for a in $AGENT_LIST; do
  cmd="$(agent_hc_command "$a")"; short="$(agent_short "$a")"
  for role_file in "$HG_ROOT"/templates/*.md; do
    role="$(basename "$role_file" .md)"
    out="$HC_TEMPLATES/gentle-$role-$short.md"
    desc="$(head -1 "$role_file") Runs $short."
    if [ "$HG_DRY_RUN" = 1 ]; then info "escribiría $out"; continue; fi
    {
      echo "---"
      echo "description: $desc"
      echo "command: $cmd"
      if ! agent_reports_status "$a"; then echo "ready: quiet"; echo "submit: enter"; fi
      echo "---"
      sed '1,/^---$/d' "$role_file"
    } > "$out"
  done
  ok "gentle-{explorer,writer,verifier,worker}-$short"
done

# ---------------------------------------------------------------------------
step "7/7 App Herdr: mod Gentle, tema y comandos"
# ---------------------------------------------------------------------------
bin_dir="$HOME/.local/bin"
run mkdir -p "$bin_dir"
run ln -sf "$HG_ROOT/usage/cli.mjs" "$bin_dir/gentle-usage"
run ln -sf "$HG_ROOT/scripts/doctor.sh" "$bin_dir/herdr-gentle-doctor"
run ln -sf "$HG_ROOT/scripts/project-init.sh" "$bin_dir/herdr-gentle-init"
case ":$PATH:" in *":$bin_dir:"*) ;; *) warn "Añade $bin_dir a tu PATH";; esac

mod_dir="$APP_HOME/mods/gentle"
if [ "$HG_DRY_RUN" = 1 ]; then
  info "copiaría app/mods/gentle → $mod_dir y app/themes/gentleman.json → $APP_HOME/themes/"
else
  mkdir -p "$mod_dir" "$APP_HOME/themes"
  cp "$HG_ROOT/app/mods/gentle/main.js" "$HG_ROOT/app/mods/gentle/mod.json" "$mod_dir/"
  # La app no hereda siempre tu PATH: rutas absolutas a node y al lector de consumo.
  node_bin="$(command -v node)"
  printf '// Written by herdr-gentle install.sh.\nexport const NODE = %s;\nexport const CLI = %s;\n' \
    "\"$node_bin\"" "\"$HG_ROOT/usage/cli.mjs\"" > "$mod_dir/config.js"
  cp "$HG_ROOT/app/themes/gentleman.json" "$APP_HOME/themes/gentleman.json"
  ok "mod Gentle → $mod_dir (se acopla a la derecha la primera vez)"
  ok "tema → $APP_HOME/themes/gentleman.json"
  if have herdr-app; then
    if herdr-app check "$mod_dir"; then ok "herdr-app check: el mod carga"; else warn "herdr-app check falló; mira el error de arriba"; fi
    if [ "$APPLY_THEME" = 1 ]; then herdr-app do app.theme '{"name":"gentleman"}' >/dev/null 2>&1 && ok "tema Gentleman activo" || warn "abre la app y elige el tema Gentleman en Ajustes"; fi
  fi
fi

step "Listo"
info "1. Abre la app Herdr. El panel Gentle aparece a la derecha."
info "2. Reinicia tus agentes para que carguen las skills nuevas."
info "3. Pide a cualquier agente: \"explora X con un subagente codex\" (usa gentle-explorer-codex)."
info "4. gentle-usage --table   consumo en la terminal · herdr-gentle-doctor   verifica todo"
