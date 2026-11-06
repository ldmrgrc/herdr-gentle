#!/usr/bin/env bash
# Deshace todo lo que hizo install.sh (y herdr-gentle-init) y deja tu máquina
# como estaba antes, usando el registro ~/.local/state/herdr-gentle/install.log.
#
#   - borra lo que creamos y restaura lo que pisamos (skills, templates, mod,
#     tema, comandos en ~/.local/bin), y las carpetas que quedaron vacías
#   - quita CodeGraph solo de los agentes donde lo pusimos nosotros, y la CLI
#     solo si la instalamos nosotros
#   - quita el índice de CodeGraph de los proyectos que indexó herdr-gentle-init
#   - vuelve a poner el tema de la app que tenías
#   - restaura la configuración de Gentle AI al backup previo a la instalación
#
# Uso: ./uninstall.sh [opciones]
#   --dry-run       Solo mostrar lo que se haría
#   --yes           No pedir confirmación
#   --keep-gentle   No restaurar la configuración de Gentle AI
#   --keep-projects No tocar los índices de CodeGraph de tus proyectos
#   -h, --help      Esta ayuda
set -u

HG_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HG_ROOT/lib/common.sh"
# shellcheck source=lib/state.sh
. "$HG_ROOT/lib/state.sh"

YES=0; KEEP_GENTLE=0; KEEP_PROJECTS=0
usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)       HG_DRY_RUN=1; export HG_DRY_RUN; shift ;;
    --yes|-y)        YES=1; shift ;;
    --keep-gentle)   KEEP_GENTLE=1; shift ;;
    --keep-projects) KEEP_PROJECTS=1; shift ;;
    -h|--help)       usage 0 ;;
    *) fail "Opción desconocida: $1"; usage 1 ;;
  esac
done

[ -s "$HG_LOG" ] || die "No hay registro de instalación en $HG_LOG: no hay nada que deshacer (o se instaló con una versión sin registro; ver README)."

entries() { awk -F'\t' -v t="$1" '$1==t' "$HG_LOG"; }
field() { printf '%s' "$1" | cut -f"$2"; }
errors=0
soft() { "$@" || { warn "falló: $*"; errors=$((errors+1)); }; }

# ---------------------------------------------------------------------------
step "Lo que se va a deshacer"
# ---------------------------------------------------------------------------
n_new=$(entries new | wc -l | tr -d ' '); n_orig=$(entries orig | wc -l | tr -d ' ')
info "$n_new archivos/enlaces creados por herdr-gentle se borran"
info "$n_orig archivos que existían antes se restauran desde $HG_BACKUP"
cg_targets="$(entries cg_target | cut -f2 | paste -sd, -)"
[ -n "$cg_targets" ] && info "CodeGraph se quita de: $cg_targets"
entries cg_cli | grep -q . && info "la CLI de CodeGraph se desinstala ($(entries cg_cli | cut -f2))"
[ "$KEEP_PROJECTS" = 0 ] && entries project | while IFS= read -r l; do info "índice CodeGraph de $(field "$l" 2)"; done
entries theme | grep -q . && info "tema de la app → $(entries theme | cut -f2)"
entries layout | grep -q . && info "layout de la app → $(entries layout | cut -f2 | sed 's/^-$/main/')"
gentle_line="$(entries gentle | head -1)"
gentle_id="$(field "$gentle_line" 3)"
if [ "$KEEP_GENTLE" = 0 ] && [ -n "$gentle_id" ] && [ "$gentle_id" != "-" ]; then
  info "Gentle AI vuelve al backup $gentle_id (de antes de instalar)."
  warn "Eso también deshace cambios que hayas hecho a la config de tus agentes después de instalar. Usa --keep-gentle si no lo quieres."
fi
if [ "$HG_DRY_RUN" != 1 ] && [ "$YES" != 1 ]; then
  printf '\n    ¿Continuar? Escribe "si": '
  read -r answer
  [ "$answer" = si ] || [ "$answer" = sí ] || die "Cancelado; no se cambió nada."
fi

# ---------------------------------------------------------------------------
step "1/6 Proyectos indexados"
# ---------------------------------------------------------------------------
if [ "$KEEP_PROJECTS" = 1 ]; then info "Omitido (--keep-projects)"
else
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    proj="$(field "$l" 2)"; added_exclude="$(field "$l" 3)"
    [ -d "$proj" ] || { info "$proj ya no existe"; continue; }
    if have codegraph; then soft run codegraph uninit --force "$proj"; fi
    if [ "$added_exclude" = 1 ]; then
      ex="$(git -C "$proj" rev-parse --git-path info/exclude 2>/dev/null)"
      case "$ex" in /*) ;; ?*) ex="$proj/$ex" ;; *) ex="$proj/.git/info/exclude" ;; esac
      if [ -f "$ex" ]; then
        info "quito .codegraph/ de $ex"
        [ "$HG_DRY_RUN" = 1 ] || { grep -vxF '.codegraph/' "$ex" > "$ex.hg-tmp"; cat "$ex.hg-tmp" > "$ex"; rm -f "$ex.hg-tmp"; }
      fi
    fi
  done < <(entries project)
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    proj="$(field "$l" 2)"
    if [ -f "$proj/.engram/config.json" ]; then
      run rm -f "$proj/.engram/config.json"
      [ "$HG_DRY_RUN" = 1 ] || rmdir "$proj/.engram" 2>/dev/null || true
    fi
  done < <(entries project_engram)
fi

# ---------------------------------------------------------------------------
step "2/6 Tema y layout de la app"
# ---------------------------------------------------------------------------
prev_theme="$(entries theme | head -1 | cut -f2)"
if [ -z "$prev_theme" ]; then info "El tema iba en el layout Gentle: al borrarlo vuelves a tu tema"
elif [ "$prev_theme" = "-" ]; then
  warn "Antes no tenías un tema fijado; elige el tuyo en Ajustes de la app (Gentleman deja de estar disponible)."
elif printf '%s' "$prev_theme" | grep -q '^[A-Za-z0-9_.-]*$'; then
  if have herdr-app && [ "$HG_DRY_RUN" != 1 ] && herdr-app do app.theme "{\"name\":\"$prev_theme\"}" >/dev/null 2>&1; then ok "tema $prev_theme"
  elif [ "$HG_DRY_RUN" = 1 ]; then info "volvería al tema $prev_theme"
  else warn "abre la app y vuelve al tema $prev_theme en Ajustes"; fi
else
  warn "Tu tema anterior era $prev_theme; vuelve a elegirlo en Ajustes de la app."
fi

# Layout: volver al que tenías antes de borrar el nuestro.
prev_layout="$(entries layout | head -1 | cut -f2)"
app_home="${HERDR_APP_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr-app}"
if [ -n "$prev_layout" ]; then
  target_layout="$prev_layout"; [ "$target_layout" = "-" ] && target_layout="main"
  if have herdr-app && [ "$HG_DRY_RUN" != 1 ] && herdr-app do layout.switch "{\"name\":\"$target_layout\"}" >/dev/null 2>&1; then
    ok "la app vuelve al layout $target_layout"
  elif [ "$HG_DRY_RUN" = 1 ]; then info "volvería al layout $target_layout"
  else
    node -e 'const fs=require("fs"),[f,v]=process.argv.slice(1);let s={};try{s=JSON.parse(fs.readFileSync(f,"utf8"))}catch{process.exit(0)};if(v==="-")delete s.layout;else s.layout=v;fs.writeFileSync(f,JSON.stringify(s))' "$app_home/shared.json" "$prev_layout" \
      && ok "la app abrirá con el layout $target_layout"
  fi
  # Tamaños y clics que la app guardó para el layout Gentle.
  [ -f "$app_home/layouts/.state/gentle.json" ] && run rm -f "$app_home/layouts/.state/gentle.json"
fi

# ---------------------------------------------------------------------------
step "3/6 CodeGraph"
# ---------------------------------------------------------------------------
if [ -n "$cg_targets" ]; then
  if have codegraph; then soft run codegraph uninstall --target "$cg_targets" --keep-cli --yes
  else warn "codegraph no está en PATH; no pude quitarlo de: $cg_targets"; errors=$((errors+1)); fi
else info "No registramos CodeGraph en ningún agente"; fi
case "$(entries cg_cli | head -1 | cut -f2)" in
  npm)  soft run npm uninstall -g @colbymchenry/codegraph ;;
  pnpm) soft run pnpm remove -g @colbymchenry/codegraph ;;
  *)    info "La CLI de CodeGraph ya estaba antes: se queda" ;;
esac

# ---------------------------------------------------------------------------
step "4/6 Archivos, enlaces y carpetas"
# ---------------------------------------------------------------------------
# Orden inverso: lo último que se hizo se deshace primero.
safe_remove() {
  local p="$1"
  if [ -L "$p" ] || [ -f "$p" ]; then run rm -f "$p"
  elif [ -d "$p" ]; then
    # Solo borramos carpetas enteras que son nuestras (el mod de la app).
    case "$p" in */mods/gentle) run rm -r "$p" ;; *) warn "no borro la carpeta $p (no reconocida)"; errors=$((errors+1)) ;; esac
  fi
}
while IFS=$'\t' read -r kind path extra; do
  case "$kind" in
    new)  { [ -e "$path" ] || [ -L "$path" ]; } && safe_remove "$path" ;;
    orig)
      if [ -e "$extra" ] || [ -L "$extra" ]; then
        { [ -e "$path" ] || [ -L "$path" ]; } && safe_remove "$path"
        run cp -a "$extra" "$path" && ok "restaurado $path"
      else warn "falta el backup de $path ($extra)"; errors=$((errors+1)); fi ;;
    mkdir)
      if [ -d "$path" ]; then
        if [ "$HG_DRY_RUN" = 1 ]; then info "borraría $path si queda vacía"
        elif rmdir "$path" 2>/dev/null; then ok "carpeta vacía borrada: $path"
        else info "queda $path (tiene otros archivos)"; fi
      fi ;;
  esac
done < <(awk -F'\t' '$1=="new"||$1=="orig"||$1=="mkdir"' "$HG_LOG" | awk '{l[NR]=$0} END {for (i=NR; i>0; i--) print l[i]}')

# ---------------------------------------------------------------------------
step "5/6 Gentle AI"
# ---------------------------------------------------------------------------
if [ "$KEEP_GENTLE" = 1 ]; then info "Omitido (--keep-gentle)"
elif [ -z "$gentle_line" ]; then info "El instalador no tocó Gentle AI"
elif [ "$gentle_id" = "-" ]; then warn "No había backup de Gentle AI previo; revisa con: gentle-ai restore --list"
elif have gentle-ai; then
  soft run gentle-ai restore "$gentle_id" --yes
else warn "gentle-ai no está en PATH; restaura a mano con: gentle-ai restore $gentle_id"; errors=$((errors+1)); fi
if [ "$(field "$gentle_line" 2)" = install ]; then
  info "Si Engram lo instaló gentle-ai en esta instalación y no lo quieres: brew uninstall engram (o borra el binario)."
fi

# ---------------------------------------------------------------------------
step "6/6 Registro"
# ---------------------------------------------------------------------------
if [ "$HG_DRY_RUN" = 1 ]; then info "dry-run: no se cambió nada"
elif [ "$errors" = 0 ]; then
  parents="$(cat "$HG_STATE_DIR/.created_parents" 2>/dev/null)"
  run rm -r "$HG_STATE_DIR" && ok "registro y backups borrados"
  # Las carpetas que creó el registro (de la más profunda a la más alta).
  for d in $parents; do rmdir "$d" 2>/dev/null || true; done
else
  warn "$errors paso(s) fallaron; dejo el registro en $HG_LOG para reintentar ./uninstall.sh"
fi

step "Listo"
info "Cierra el panel Gentle si sigue abierto en la app (sin el mod queda vacío) y reinicia tus agentes."
exit $(( errors > 0 ))
