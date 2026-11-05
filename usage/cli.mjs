#!/usr/bin/env node
// gentle-usage: model, context, tokens and cost of every agent herdr-core runs,
// plus today's totals. The Gentle mod in the Herdr app calls this with exec().
//   gentle-usage            → JSON for the mod
//   gentle-usage --table    → readable table (for you or an agent)
import { spawnSync } from "node:child_process";
import { agentKind, usageForTerminal, todayUsage, sidebarTokens, ctxPercent, fmtTokens, totalTokens, shortModel } from "./lib.mjs";

const hc = spawnSync(process.env.HC_BIN || "hc", ["ls", "--json"], { encoding: "utf8", timeout: 10000 });
let terminals = [];
try { terminals = JSON.parse(hc.stdout).terminals ?? []; } catch { /* hc missing or no core */ }

// Newest first, so a resumed old session goes to the terminal really using it.
const live = terminals.filter((t) => t.state === "live").sort((a, b) => (b.created_ms || 0) - (a.created_ms || 0));
const used = new Set();
const agents = {};
for (const t of live) {
  const kind = agentKind(t);
  if (!kind) continue;
  const u = usageForTerminal({ kind, cwd: t.foreground?.cwd || t.cwd, createdMs: t.created_ms }, used);
  agents[t.address] = {
    address: t.address, name: t.name, kind, parent: t.parent, template: t.template, status: t.status?.state ?? null,
    ...sidebarTokens(u), ctxPct: ctxPercent(u), cost_usd: u?.cost ?? null, cost_exact: Boolean(u?.costExact), turns: u?.turns ?? 0,
  };
}
const today = todayUsage();
const result = {
  hc_ok: hc.status === 0,
  agents,
  today: {
    sessions: today.sessions,
    cost_usd: today.models.reduce((s, m) => s + (m.cost || 0), 0),
    models: today.models.map((m) => ({ agent: m.agent, model: shortModel(m.model), tok: fmtTokens(totalTokens(m)), sessions: m.sessions, cost_usd: m.unpriced ? null : m.cost })),
  },
};

if (process.argv.includes("--table")) {
  for (const a of Object.values(agents)) {
    console.log(`${(a.name || a.address).padEnd(16)} ${a.kind.padEnd(9)} ${String(a.status ?? "-").padEnd(8)} ${(a.model ?? "-").padEnd(18)} ctx ${String(a.ctx ?? "-").padStart(4)} ${String(a.tok ?? "-").padStart(6)} ${a.cost ?? ""}${a.parent ? `  ← ${a.parent}` : ""}`);
  }
  console.log(`\nhoy: ${result.today.sessions} sesiones ≈$${result.today.cost_usd.toFixed(2)}`);
  for (const m of result.today.models) console.log(`  ${m.agent.padEnd(8)} ${String(m.model).padEnd(24)} ${m.tok.padStart(6)}  ${m.cost_usd == null ? "sin precio" : `≈$${m.cost_usd.toFixed(2)}`}`);
} else {
  process.stdout.write(JSON.stringify(result));
}
