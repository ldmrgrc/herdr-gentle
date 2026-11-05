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
for bin in herdr gentle-ai engram codegraph node; do
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
for a in $(split_list "$AGENTS"); do
  dir="$(agent_skills_dir "$a")"
  [ -d "$dir" ] || { info "$a: sin carpeta de skills ($dir)"; continue; }
  n=$(find -L "$dir" -name SKILL.md 2>/dev/null | wc -l | tr -d ' ')
  missing_s=""
  for s in herdr gentle-herdr; do [ -f "$dir/$s/SKILL.md" ] || missing_s="$missing_s $s"; done
  if [ -z "$missing_s" ]; then ok "$a: $n skills (incluye herdr y gentle-herdr)"
  else fail "$a: faltan skills:$missing_s"; problems=$((problems+1)); fi
done

step "Plugin gentle.herdr"
if have herdr && herdr plugin list 2>/dev/null | grep -q gentle.herdr; then ok "enlazado"
else fail "plugin no enlazado → herdr plugin link $HG_ROOT/plugin"; problems=$((problems+1)); fi
have gentle-herdr && ok "gentle-herdr en PATH" || { fail "gentle-herdr no está en PATH"; problems=$((problems+1)); }

step "Integraciones de herdr"
have herdr && { herdr integration status 2>&1 | sed 's/^/    /'; }

step "Proyecto actual ($PWD)"
[ -d .codegraph ] && ok "CodeGraph indexado" || info "Sin índice CodeGraph → herdr-gentle-init ."

step "gentle-ai doctor"
have gentle-ai && { gentle-ai doctor 2>&1 | sed 's/^/    /'; }

echo
if [ "$problems" = 0 ]; then ok "Todo en orden"; else warn "$problems problema(s) — vuelve a ejecutar ./install.sh"; fi
exit $(( problems > 0 ))
