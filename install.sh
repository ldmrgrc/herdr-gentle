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
#   --theme            Usa el tema Gentleman en el layout Gentle (tu main no cambia)
#   --no-codegraph     No instalar CodeGraph
#   --dry-run          Solo mostrar lo que se haría
#   -h, --help         Esta ayuda
#
# Todo cambio queda anotado en ~/.local/state/herdr-gentle/install.log;
# ./uninstall.sh lo deshace y deja tu máquina como estaba.
set -u

HG_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HG_ROOT/lib/common.sh"
# shellcheck source=lib/state.sh
. "$HG_ROOT/lib/state.sh"

AGENTS=""; PERSONA="gentleman"; GENTLE_MODE="auto"; WITH_CODEGRAPH=1; APPLY_THEME=0
APP_HOME="${HERDR_APP_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr-app}"
HC_TEMPLATES="${XDG_CONFIG_HOME:-$HOME/.config}/herdr-core/templates"

usage() { sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
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
st_init
[ "$HG_DRY_RUN" = 1 ] || info "Registro de cambios: $HG_LOG"

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
# IDs de backups de Gentle AI, del más nuevo al más viejo.
gentle_backups() {
  node -e '
    const fs = require("fs"), path = require("path");
    const root = path.join(process.env.GENTLE_AI_HOME || path.join(require("os").homedir(), ".gentle-ai"), "backups");
    let out = [];
    try { for (const d of fs.readdirSync(root)) { try { const m = JSON.parse(fs.readFileSync(path.join(root, d, "manifest.json"), "utf8")); out.push({ id: m.id || d, t: Date.parse(m.created_at || m.timestamp || m.createdAt || 0) || fs.statSync(path.join(root, d)).mtimeMs }); } catch {} } } catch {}
    out.sort((a, b) => b.t - a.t); console.log(out.map((b) => b.id).join("\n"));' 2>/dev/null
}
GA_BEFORE="$(gentle_backups)"
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
if [ "$GENTLE_MODE" != skip ] && [ "$HG_DRY_RUN" != 1 ]; then
  # gentle-ai guarda un backup antes de escribir. El más viejo de los nuevos es
  # el estado de antes; si no creó ninguno (nada cambió), vale el último previo.
  new_ids="$(gentle_backups | grep -vxF -f <(printf '%s\n' "$GA_BEFORE") || true)"
  pre_id="$(printf '%s\n' "$new_ids" | sed '/^$/d' | tail -1)"
  [ -n "$pre_id" ] || pre_id="$(printf '%s\n' "$GA_BEFORE" | sed -n 1p)"
  st_add gentle "$GENTLE_MODE" "${pre_id:--}"
  [ -n "$pre_id" ] && ok "backup previo de Gentle AI: $pre_id"
fi

# ---------------------------------------------------------------------------
step "4/7 CodeGraph"
# ---------------------------------------------------------------------------
if [ "$WITH_CODEGRAPH" = 1 ]; then
  targets=""
  for a in $AGENT_LIST; do t="$(agent_codegraph_target "$a")"; [ -n "$t" ] && targets="$targets${targets:+,}$t"; done
  if have codegraph; then ok "codegraph ya instalado"
  elif have npm; then run npm install -g @colbymchenry/codegraph@latest || die "No pude instalar CodeGraph"; st_add cg_cli npm
  elif have pnpm; then run pnpm add -g @colbymchenry/codegraph@latest || die "No pude instalar CodeGraph"; st_add cg_cli pnpm
  else die "CodeGraph necesita npm o pnpm"; fi
  # Solo anotamos los agentes donde CodeGraph no estaba: el uninstall no toca los tuyos.
  for a in $AGENT_LIST; do
    t="$(agent_codegraph_target "$a")"; [ -n "$t" ] || continue
    if agent_has_mcp "$a" codegraph; then info "$a ya tenía CodeGraph"; else st_add cg_target "$t"; fi
  done
  run codegraph install --target "$targets" --location global --yes || die "codegraph install falló ($targets)"
else info "Omitido (--no-codegraph)"; fi

# ---------------------------------------------------------------------------
step "5/7 Skills herdr-core + gentle-herdr en cada agente"
# ---------------------------------------------------------------------------
for a in $AGENT_LIST; do
  dir="$(agent_skills_dir "$a")"
  [ -n "$dir" ] || continue
  track_mkdir "$dir"
  # Enlaces: un `git pull` de este repo actualiza las skills en todos los agentes.
  track_path "$dir/gentle-herdr"
  run ln -sfn "$HG_ROOT/skills/gentle-herdr" "$dir/gentle-herdr"
  if [ -e "$dir/herdr-core" ] && [ ! -L "$dir/herdr-core" ]; then info "$a: ya tiene su skill herdr-core; la dejo"
  else track_path "$dir/herdr-core"; run ln -sfn "$HG_ROOT/skills/herdr-core" "$dir/herdr-core"; fi
  # La skill de la TUI (`herdr`) confunde a los agentes dentro de la app.
  if [ -f "$dir/herdr/SKILL.md" ] && grep -q '^name: herdr$' "$dir/herdr/SKILL.md"; then
    warn "$a: tiene la skill 'herdr' de la TUI en $dir/herdr; si solo usas la app, bórrala"
  fi
  ok "$a → $dir/{herdr-core,gentle-herdr}"
done

# ---------------------------------------------------------------------------
step "6/7 Roles de Gentle como templates de herdr-core"
# ---------------------------------------------------------------------------
track_mkdir "$HC_TEMPLATES"
for a in $AGENT_LIST; do
  cmd="$(agent_hc_command "$a")"; short="$(agent_short "$a")"
  for role_file in "$HG_ROOT"/templates/*.md; do
    role="$(basename "$role_file" .md)"
    out="$HC_TEMPLATES/gentle-$role-$short.md"
    desc="$(head -1 "$role_file") Runs $short."
    if [ "$HG_DRY_RUN" = 1 ]; then info "escribiría $out"; continue; fi
    track_path "$out"
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
track_mkdir "$bin_dir"
for pair in "usage/cli.mjs:gentle-usage" "scripts/doctor.sh:herdr-gentle-doctor" "scripts/project-init.sh:herdr-gentle-init"; do
  track_path "$bin_dir/${pair#*:}"
  run ln -sf "$HG_ROOT/${pair%%:*}" "$bin_dir/${pair#*:}"
done
case ":$PATH:" in *":$bin_dir:"*) ;; *) warn "Añade $bin_dir a tu PATH";; esac

mod_dir="$APP_HOME/mods/gentle"
if [ "$HG_DRY_RUN" = 1 ]; then
  info "copiaría app/mods/gentle → $mod_dir y app/themes/gentleman.json → $APP_HOME/themes/"
  info "crearía el layout $APP_HOME/layouts/gentle.json (tu main + panel Gentle) y cambiaría la app a él"
else
  track_mkdir "$APP_HOME/mods"
  track_path "$mod_dir"
  track_mkdir "$mod_dir"
  track_mkdir "$APP_HOME/themes"
  track_path "$APP_HOME/themes/gentleman.json"
  cp "$HG_ROOT/app/mods/gentle/main.js" "$HG_ROOT/app/mods/gentle/mod.json" "$mod_dir/"
  # La app no hereda siempre tu PATH: rutas absolutas a node y al lector de consumo.
  node_bin="$(command -v node)"
  printf '// Written by herdr-gentle install.sh.\nexport const NODE = %s;\nexport const CLI = %s;\n' \
    "\"$node_bin\"" "\"$HG_ROOT/usage/cli.mjs\"" > "$mod_dir/config.js"
  cp "$HG_ROOT/app/themes/gentleman.json" "$APP_HOME/themes/gentleman.json"
  ok "mod Gentle → $mod_dir"
  ok "tema → $APP_HOME/themes/gentleman.json"

  # La app nunca acopla mods nuevos en sus layouts de fábrica (main, terminals,
  # win98). Creamos un layout personal "gentle": tu main + el panel Gentle bajo
  # Agents. El main de fábrica no se toca; ctrl-shift-l cambia entre layouts.
  main_layout="$APP_HOME/layouts/main.json"
  if [ -f "$main_layout" ]; then
    track_path "$APP_HOME/layouts/gentle.json"
    theme_arg=""; [ "$APPLY_THEME" = 1 ] && theme_arg="gentleman"
    node "$HG_ROOT/scripts/make-layout.mjs" "$main_layout" "$APP_HOME/layouts/gentle.json" $theme_arg >/dev/null \
      && ok "layout Gentle → $APP_HOME/layouts/gentle.json${theme_arg:+ (con tema Gentleman)}"
    prev_layout="$(node -e 'try{const s=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));console.log(typeof s.layout==="string"?s.layout:"-")}catch{console.log("-")}' "$APP_HOME/shared.json")"
    # Si ya estabas en "gentle" por una instalación anterior, no lo cuentes como el previo.
    [ "$prev_layout" = gentle ] && prev_layout="-"
    st_add_once layout "$prev_layout"
    if have herdr-app && herdr-app do layout.switch '{"name":"gentle"}' >/dev/null 2>&1; then
      ok "la app ya muestra el layout Gentle"
    else
      # App cerrada: la app arranca con el layout guardado en shared.json.
      node -e 'const fs=require("fs"),f=process.argv[1];let s={};try{s=JSON.parse(fs.readFileSync(f,"utf8"))}catch{};s.layout="gentle";fs.writeFileSync(f,JSON.stringify(s))' "$APP_HOME/shared.json" \
        && ok "la app abrirá con el layout Gentle"
    fi
  else
    warn "No encuentro $main_layout: abre la app Herdr una vez, ciérrala y vuelve a ejecutar ./install.sh"
  fi
  if have herdr-app; then
    if herdr-app check "$mod_dir"; then ok "herdr-app check: el mod carga"; else warn "herdr-app check falló; mira el error de arriba"; fi
  fi
fi

step "Listo"
info "1. Abre (o reinicia) la app Herdr: el panel Gentle está bajo Agents, en el layout Gentle."
info "2. Reinicia tus agentes para que carguen las skills nuevas."
info "3. Pide a cualquier agente: \"explora X con un subagente codex\" (usa gentle-explorer-codex)."
info "4. gentle-usage --table   consumo en la terminal · herdr-gentle-doctor   verifica todo"
info "Para dejar todo como estaba: ./uninstall.sh"
