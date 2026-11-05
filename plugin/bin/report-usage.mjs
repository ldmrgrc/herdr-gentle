#!/usr/bin/env node
// Publishes model / context % / tokens / cost of each agent as herdr pane
// tokens ($model, $ctx, $tok, $cost) so the sidebar can show them.
// Runs from: startup hook (all agents), pane.agent_status_changed and
// pane.agent_detected hooks (one pane), or by hand: report-usage.mjs [pane_id]
import { listAgents, reportTokens } from "../lib/herdr.mjs";
import { usageForAgent, sidebarTokens } from "../lib/usage.mjs";

const SOURCE = "gentle:usage";

function targetPane() {
  if (process.argv[2]) return process.argv[2];
  const raw = process.env.HERDR_PLUGIN_EVENT_JSON;
  if (!raw) return null;
  try {
    const ev = JSON.parse(raw);
    return ev?.data?.pane_id ?? ev?.pane_id ?? null;
  } catch { return null; }
}

const pane = targetPane();
const agents = listAgents().filter((a) => a.agent && (!pane || a.pane_id === pane));
for (const agent of agents) {
  const usage = usageForAgent(agent);
  // Agent files are flushed slightly after the state flips; one retry catches the last turn.
  reportTokens(agent.pane_id, SOURCE, sidebarTokens(usage));
}
if (pane && agents.length) {
  await new Promise((r) => setTimeout(r, 1500));
  for (const agent of agents) reportTokens(agent.pane_id, SOURCE, sidebarTokens(usageForAgent(agent)));
}
