# shellcheck shell=bash
# Registro de todo lo que cambia install.sh, para que uninstall.sh lo deshaga.
# Una línea por cambio, separada por tabuladores:  <tipo> <ruta-o-valor> <extra>
#   new      <ruta>  -          creado por el instalador: se borra
#   orig     <ruta>  <backup>   existía antes: se restaura desde <backup>
#   mkdir    <dir>   -          carpeta creada: se borra si queda vacía
#   cg_target <t>    -          CodeGraph registrado por nosotros en ese agente
#   cg_cli   <npm|pnpm> -       CLI de CodeGraph instalada por nosotros
#   gentle   <modo>  <id|->     modo sync/install y backup de Gentle AI previo
#   theme    <previo|-> -       (versiones anteriores) tema de la app antes de --theme
#   layout   <previo|-> -       layout de la app antes de cambiar a "gentle"
#   project  <ruta>  <0|1>      proyecto indexado; 1 = añadimos .codegraph/ al exclude
# Si instalas dos veces, solo cuenta la primera vez: así "orig" siempre es el
# estado de antes de herdr-gentle, no una copia de nuestros propios archivos.

HG_STATE_DIR="${HG_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/herdr-gentle}"
HG_LOG="$HG_STATE_DIR/install.log"
HG_BACKUP="$HG_STATE_DIR/backup"

# Las carpetas padre que crea el propio registro (p. ej. ~/.local/state) se
# anotan aparte: uninstall.sh las borra al final, después del registro.
st_init() {
  [ "${HG_DRY_RUN:-0}" = 1 ] && return 0
  if [ ! -d "$HG_STATE_DIR" ]; then
    local d; d="$(dirname "$HG_STATE_DIR")"; local parents=()
    while [ -n "$d" ] && [ "$d" != "/" ] && [ ! -e "$d" ]; do parents+=("$d"); d="$(dirname "$d")"; done
    mkdir -p "$HG_STATE_DIR"
    [ "${#parents[@]}" -gt 0 ] && printf '%s\n' "${parents[@]}" > "$HG_STATE_DIR/.created_parents"
  fi
  mkdir -p "$HG_BACKUP"; touch "$HG_LOG"
}

# st_add_once <tipo> <valor> — solo si todavía no hay ninguna línea de ese tipo.
st_add_once() { [ -f "$HG_LOG" ] && awk -F'\t' -v t="$1" '$1==t {f=1} END {exit !f}' "$HG_LOG" && return 0; st_add "$@"; }

# st_has <tipo> <clave>
st_has() { [ -f "$HG_LOG" ] && awk -F'\t' -v t="$1" -v k="$2" '$1==t && $2==k {f=1} END {exit !f}' "$HG_LOG"; }

# st_add <tipo> <clave> [extra] — solo la primera vez.
st_add() {
  [ "${HG_DRY_RUN:-0}" = 1 ] && return 0
  st_has "$1" "$2" && return 0
  printf '%s\t%s\t%s\n' "$1" "$2" "${3:--}" >> "$HG_LOG"
}

# Antes de crear carpetas: registra cada nivel que todavía no existe.
track_mkdir() {
  [ "${HG_DRY_RUN:-0}" = 1 ] && return 0
  local d="$1" missing=()
  while [ -n "$d" ] && [ "$d" != "/" ] && [ ! -e "$d" ]; do missing=("$d" "${missing[@]}"); d="$(dirname "$d")"; done
  local m; for m in "${missing[@]}"; do st_add mkdir "$m"; done
  mkdir -p "$1"
}

# Antes de escribir o enlazar <ruta>: guarda lo que había (archivo, enlace o carpeta).
track_path() {
  [ "${HG_DRY_RUN:-0}" = 1 ] && return 0
  local p="$1"
  st_has new "$p" && return 0
  st_has orig "$p" && return 0
  if [ -e "$p" ] || [ -L "$p" ]; then
    local bk="$HG_BACKUP/$(printf '%s' "$p" | sed 's#^/##; s#/#__#g')"
    rm -rf "$bk"
    cp -a "$p" "$bk"
    st_add orig "$p" "$bk"
  else
    st_add new "$p"
  fi
}
