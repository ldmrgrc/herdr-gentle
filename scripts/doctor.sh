#!/usr/bin/env bash
# Verifica skills, MCP (engram, context7, codegraph), templates de herdr-core y
# el mod Gentle de la app Herdr para cada agente. Solo lectura.
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
for bin in herdr-app hc gentle-ai engram codegraph node gentle-usage; do
  if have "$bin"; then ok "$bin → $(command -v "$bin")"; else fail "$bin no encontrado"; problems=$((problems+1)); fi
done

step "Dentro de herdr-core"
if [ -n "${HC_TERMINAL_ID:-}" ]; then ok "HC_TERMINAL_ID=$HC_TERMINAL_ID (terminal de la app Herdr)"; else info "No estás en una terminal de herdr-core (normal si lo ejecutas fuera de la app)"; fi

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
  for s in herdr-core gentle-herdr; do [ -f "$dir/$s/SKILL.md" ] || missing_s="$missing_s $s"; done
  if [ -z "$missing_s" ]; then ok "$a: $n skills (incluye herdr-core y gentle-herdr)"
  else fail "$a: faltan skills:$missing_s"; problems=$((problems+1)); fi
done

step "Templates de herdr-core"
tdir="${XDG_CONFIG_HOME:-$HOME/.config}/herdr-core/templates"
n=$(ls "$tdir"/gentle-*.md 2>/dev/null | wc -l | tr -d ' ')
if [ "$n" -gt 0 ]; then ok "$n templates gentle-* en $tdir"; else fail "sin templates gentle-* → ./install.sh"; problems=$((problems+1)); fi

step "App Herdr: mod Gentle"
app_home="${HERDR_APP_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr-app}"
if [ -f "$app_home/mods/gentle/main.js" ]; then
  ok "mod en $app_home/mods/gentle"
  if have herdr-app; then
    if herdr-app check "$app_home/mods/gentle" >/dev/null 2>&1; then ok "herdr-app check OK"
    else fail "herdr-app check falló → herdr-app check $app_home/mods/gentle"; problems=$((problems+1)); fi
  fi
else fail "mod Gentle no instalado → ./install.sh"; problems=$((problems+1)); fi
if have gentle-usage; then
  if gentle-usage 2>/dev/null | grep -q '"hc_ok":true'; then ok "gentle-usage lee herdr-core"
  else fail "gentle-usage no pudo leer 'hc ls' (¿está corriendo la app/herdr-core?)"; problems=$((problems+1)); fi
fi

step "Proyecto actual ($PWD)"
[ -d .codegraph ] && ok "CodeGraph indexado" || info "Sin índice CodeGraph → herdr-gentle-init ."

step "gentle-ai doctor"
have gentle-ai && { gentle-ai doctor 2>&1 | sed 's/^/    /'; }

echo
if [ "$problems" = 0 ]; then ok "Todo en orden"; else warn "$problems problema(s) — vuelve a ejecutar ./install.sh"; fi
exit $(( problems > 0 ))
