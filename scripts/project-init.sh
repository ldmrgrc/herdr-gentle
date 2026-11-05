#!/usr/bin/env bash
# Prepara un proyecto para trabajar con Gentle AI dentro de herdr:
#   - indexa el código con CodeGraph (requisito para su MCP)
#   - con --engram, fija el nombre del proyecto de Engram (.engram/config.json);
#     sin él, Engram detecta el proyecto solo, a partir del directorio/remoto git
#
# Uso: herdr-gentle-init [--engram] [ruta]   (por defecto: directorio actual)
set -u
SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
HG_ROOT="$(cd "$(dirname "$SELF")/.." && pwd)"
# shellcheck source=../lib/common.sh
. "$HG_ROOT/lib/common.sh"
# shellcheck source=../lib/state.sh
. "$HG_ROOT/lib/state.sh"

with_engram=0
[ "${1:-}" = "--engram" ] && { with_engram=1; shift; }
target="$(cd "${1:-.}" && pwd)" || die "Ruta inválida: ${1:-.}"

step "CodeGraph → $target"
if [ ! -e "$target/.git" ]; then
  die "$target no es la raíz de un repo git (CodeGraph lo exige). Ejecuta: git -C \"$target\" init"
fi
had_index=0; [ -d "$target/.codegraph" ] && had_index=1
exclude="$(git -C "$target" rev-parse --git-path info/exclude 2>/dev/null)"
case "$exclude" in /*) ;; ?*) exclude="$target/$exclude" ;; *) exclude="$target/.git/info/exclude" ;; esac
had_exclude=0; grep -qxF '.codegraph/' "$exclude" 2>/dev/null && had_exclude=1
run gentle-ai codegraph init --cwd "$target" || die "codegraph init falló"
# Para uninstall.sh: solo los proyectos que indexamos nosotros.
if [ "$had_index" = 0 ]; then st_init; st_add project "$target" "$([ "$had_exclude" = 0 ] && echo 1 || echo 0)"; fi

step "Engram"
if [ "$with_engram" = 0 ]; then
  info "Detección automática del proyecto (usa --engram para fijarlo en .engram/config.json)"
elif [ -f "$target/.engram/config.json" ]; then
  ok "ya inicializado"
else
  st_init; st_add project_engram "$target"
  (cd "$target" && run engram init) || warn "engram init falló; Engram detectará el proyecto por el directorio"
fi

ok "Proyecto listo. Abre la app Herdr en $target y lanza tu agente."
