#!/usr/bin/env bash
# Verifica que skills, MCP (engram, context7, codegraph) e integraciones de herdr
# estén activos para cada agente configurado. Solo lectura.
#
# Uso: herdr-gentle-doctor [--agents a,b]
set -u
SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
HG_ROOT="$(cd "$(dirname "$SELF")/.." && pwd)"
# shellcheck source=../lib/common.sh
. "$HG_ROOT/lib/common.sh"

AGENTS=""
[ "${1:-}" = "--agents" ] && AGENTS="${2:-}"
[ -n "$AGENTS" ] || AGENTS="$(detect_agents)"
problems=0

step "Binarios"
for bin in herdr gentle-ai engram codegraph node npx; do
  if have "$bin"; then ok "$bin → $(command -v "$bin")"; else fail "$bin no encontrado"; problems=$((problems+1)); fi
done

step "Dentro de herdr"
if [ "${HERDR_ENV:-}" = 1 ]; then ok "HERDR_ENV=1 (este shell es un panel de herdr)"; else info "No estás en un panel de herdr (normal si lo ejecutas fuera)"; fi

step "MCP por agente"
for a in $(split_list "$AGENTS"); do
  cmd="$(agent_mcp_list_cmd "$a")"
  if [ -z "$cmd" ] || ! have "$(agent_bin "$a")"; then
    info "$a: sin CLI para listar MCP; revisa su config manualmente"
    continue
  fi
  out="$($cmd 2>&1 || true)"
  for mcp in engram context7 codegraph; do
    if echo "$out" | grep -qi "$mcp"; then ok "$a: $mcp"; else fail "$a: falta MCP '$mcp'"; problems=$((problems+1)); fi
  done
done

step "Skills"
claude_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
if [ -d "$claude_dir/skills" ]; then
  n=$(find "$claude_dir/skills" -name SKILL.md 2>/dev/null | wc -l | tr -d ' ')
  ok "Claude Code: $n skills en $claude_dir/skills"
  [ -f "$claude_dir/skills/herdr/SKILL.md" ] && ok "skill herdr presente" || warn "skill herdr ausente en Claude Code"
fi

step "Integraciones de herdr"
have herdr && { herdr integration status 2>&1 | sed 's/^/    /'; }

step "Proyecto actual ($PWD)"
[ -d .codegraph ] && ok "CodeGraph indexado" || info "Sin índice CodeGraph → herdr-gentle-init ."

step "gentle-ai doctor"
have gentle-ai && { gentle-ai doctor 2>&1 | sed 's/^/    /'; }

echo
if [ "$problems" = 0 ]; then ok "Todo en orden"; else warn "$problems problema(s) — vuelve a ejecutar ./install.sh"; fi
exit $(( problems > 0 ))
