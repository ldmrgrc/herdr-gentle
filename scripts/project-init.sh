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

with_engram=0
[ "${1:-}" = "--engram" ] && { with_engram=1; shift; }
target="$(cd "${1:-.}" && pwd)" || die "Ruta inválida: ${1:-.}"

step "CodeGraph → $target"
if [ ! -e "$target/.git" ]; then
  die "$target no es la raíz de un repo git (CodeGraph lo exige). Ejecuta: git -C \"$target\" init"
fi
run gentle-ai codegraph init --cwd "$target" || die "codegraph init falló"

step "Engram"
if [ "$with_engram" = 0 ]; then
  info "Detección automática del proyecto (usa --engram para fijarlo en .engram/config.json)"
elif [ -f "$target/.engram/config.json" ]; then
  ok "ya inicializado"
else
  (cd "$target" && run engram init) || warn "engram init falló; Engram detectará el proyecto por el directorio"
fi

ok "Proyecto listo. Abre un agente en un panel de herdr dentro de $target."
