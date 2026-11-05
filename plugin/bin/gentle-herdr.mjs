#!/usr/bin/env node
// gentle-herdr — Gentle AI's "focused agents" on top of herdr panes.
// Deterministic helper so every agent (claude, codex, opencode, gemini, ...)
// delegates the same way: one background tab, named subagents, the task
// passed by reference (a file, never a paraphrase), and a result file.
import { mkdirSync, writeFileSync, readFileSync, existsSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import { herdr, listAgents, listTabs, listPanes, reportTokens, HerdrError } from "../lib/herdr.mjs";
import { usageForAgent, sidebarTokens } from "../lib/usage.mjs";

const STATE = process.env.GENTLE_HERDR_STATE || join(process.env.XDG_STATE_HOME || join(homedir(), ".local", "state"), "gentle-herdr");
const RUNS = join(STATE, "runs");
const TAB_LABEL = "gentle:agents";
const SOURCE = "gentle:delegate";
const ROLES = {
  explorer: "Read-only explorer. Do NOT edit files, run destructive commands, commit or push. Map the relevant code and answer with path:line evidence.",
  writer: "Writer. Implement exactly the bounded unit described, inside the files it names. Test-first when a runnable test applies. Do not commit or push.",
  verifier: "Independent verifier. Do NOT edit files. Check the change against the spec, run the relevant tests/checks, and report pass/fail with evidence.",
  worker: "Worker. Do the bounded task described. Do not commit or push unless the task says so.",
};
// How each herdr agent kind takes a model flag.
const MODEL_FLAG = { claude: "--model", codex: "-m", opencode: "--model", gemini: "-m", cursor: "--model", kilo: "--model", qwen: "-m", pi: "--model" };

const USAGE = `gentle-herdr — delegar subagentes en paneles de herdr

  gentle-herdr spawn <name> --kind <claude|codex|opencode|gemini|cursor|...>
                    [--role explorer|writer|verifier|worker] [--model M]
                    [--task TEXT | --task-file FILE] [--cwd DIR] [--focus]
  gentle-herdr wait <name>... [--timeout MS]     espera a idle/done/blocked
  gentle-herdr result <name>                      informe final (o salida reciente)
  gentle-herdr list [--json]                      subagentes, estado y consumo
  gentle-herdr prompt <name> <text>               seguimiento a un subagente
  gentle-herdr stop <name> [--close]              interrumpe (y cierra el panel)
  gentle-herdr status <text>|--clear              resumen de actividad en la barra lateral

Requiere ejecutarse dentro de un panel de herdr (HERDR_ENV=1).`;

function die(msg, code = 1) { process.stderr.write(`gentle-herdr: ${msg}\n`); process.exit(code); }
function out(obj) { process.stdout.write(`${JSON.stringify(obj, null, 2)}\n`); }

function parseFlags(argv) {
  const pos = []; const flags = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith("--")) { pos.push(a); continue; }
    const key = a.slice(2);
    const next = argv[i + 1];
    if (next === undefined || next.startsWith("--")) flags[key] = true;
    else { flags[key] = next; i++; }
  }
  return { pos, flags };
}

function requireHerdr() {
  if (process.env.HERDR_ENV !== "1") die("no estoy dentro de un panel de herdr (HERDR_ENV != 1)");
}

function selfAgent() {
  const pane = process.env.HERDR_PANE_ID;
  return listAgents().find((a) => a.pane_id === pane) || null;
}

/** Background tab for subagents in the caller's workspace; returns a free shell pane. */
function freeShellPane(cwd) {
  const ws = process.env.HERDR_WORKSPACE_ID;
  const tab = listTabs(ws).find((t) => t.label === TAB_LABEL);
  if (!tab) {
    const r = herdr(["tab", "create", ...(ws ? ["--workspace", ws] : []), "--label", TAB_LABEL, "--cwd", cwd, "--no-focus"]);
    return r.root_pane.pane_id;
  }
  const panes = listPanes().filter((p) => p.tab_id === tab.tab_id);
  const busy = new Set(listAgents().map((a) => a.pane_id));
  // Reuse an idle shell left by a finished subagent before splitting again.
  const reusable = panes.find((p) => !busy.has(p.pane_id) && !p.agent);
  if (reusable) {
    herdr(["pane", "run", reusable.pane_id, `cd ${JSON.stringify(cwd)}`], { allowFail: true });
    return reusable.pane_id;
  }
  const last = panes[panes.length - 1];
  const dir = panes.length % 2 ? "right" : "down";
  const r = herdr(["pane", "split", last.pane_id, "--direction", dir, "--cwd", cwd, "--no-focus"]);
  return r.pane.pane_id;
}

function handoffPrompt({ name, role, parent, taskFile, resultFile }) {
  return [
    `You are subagent "${name}" delegated by "${parent}" through Herdr (Gentle AI focused agent).`,
    `Role: ${ROLES[role] || ROLES.worker}`,
    `Your full task is in ${taskFile} — read it first and follow it verbatim; it is the source of truth.`,
    `When done, write your final report to ${resultFile} (Markdown: outcome, evidence with path:line, files touched, open questions).`,
    `If you need a decision from the parent, write the question at the top of that file and stop.`,
    `Do not start other subagents.`,
  ].join(" ");
}

function cmdSpawn(pos, f) {
  requireHerdr();
  const name = pos[0];
  if (!name || !/^[a-z][a-z0-9_-]{0,31}$/.test(name)) die("el nombre debe cumplir [a-z][a-z0-9_-]{0,31}");
  const kind = f.kind || die("falta --kind (claude, codex, opencode, gemini, cursor, ...)");
  const role = f.role || "worker";
  if (!ROLES[role]) die(`rol desconocido: ${role}`);
  const task = f["task-file"] ? readFileSync(f["task-file"], "utf8") : (typeof f.task === "string" ? f.task : die("falta --task o --task-file"));
  const cwd = resolve(typeof f.cwd === "string" ? f.cwd : process.cwd());

  const parentAgent = selfAgent();
  const parent = parentAgent?.name || process.env.HERDR_PANE_ID || "user";
  mkdirSync(RUNS, { recursive: true });
  const taskFile = join(RUNS, `${name}.task.md`);
  const resultFile = join(RUNS, `${name}.result.md`);
  writeFileSync(taskFile, task);
  if (existsSync(resultFile)) writeFileSync(resultFile, "");

  const pane = freeShellPane(cwd);
  const args = ["agent", "start", name, "--kind", kind, "--pane", pane, "--timeout", "60000"];
  if (typeof f.model === "string") args.push("--", MODEL_FLAG[kind] || "--model", f.model);
  herdr(args, { timeout: 70000 });
  reportTokens(pane, SOURCE, { parent, role, task: task.split("\n").find((l) => l.trim())?.replace(/^#+\s*/, "") || name });
  herdr(["agent", "prompt", name, handoffPrompt({ name, role, parent, taskFile, resultFile })]);
  if (f.focus) herdr(["agent", "focus", name], { allowFail: true });
  writeFileSync(join(RUNS, `${name}.json`), JSON.stringify({ name, kind, role, parent, pane, cwd, taskFile, resultFile, startedAt: Date.now() }, null, 2));
  out({ name, kind, role, pane_id: pane, task_file: taskFile, result_file: resultFile });
}

function cmdWait(pos, f) {
  if (!pos.length) die("uso: gentle-herdr wait <name>...");
  const res = {};
  for (const name of pos) {
    const args = ["agent", "wait", name, "--until", "idle", "--until", "done", "--until", "blocked"];
    if (f.timeout) args.push("--timeout", String(f.timeout));
    try {
      const r = herdr(args, { timeout: Number(f.timeout || 3_600_000) + 5000 });
      res[name] = r?.agent?.agent_status ?? "settled";
    } catch (e) { res[name] = e instanceof HerdrError ? `error:${e.code}` : "error"; }
  }
  out(res);
}

function cmdResult(pos) {
  const name = pos[0] || die("uso: gentle-herdr result <name>");
  const file = join(RUNS, `${name}.result.md`);
  const text = existsSync(file) ? readFileSync(file, "utf8").trim() : "";
  if (text) { process.stdout.write(`${text}\n`); return; }
  process.stdout.write(`(sin informe en ${file}; salida reciente del agente)\n\n`);
  process.stdout.write(`${herdr(["agent", "read", name, "--source", "recent-unwrapped", "--lines", "120"], { text: true, allowFail: true }) ?? ""}\n`);
}

function cmdList(_pos, f) {
  const rows = listAgents().map((a) => {
    const u = sidebarTokens(usageForAgent(a));
    return { name: a.name || null, pane_id: a.pane_id, kind: a.agent, status: a.agent_status,
      parent: a.tokens?.parent || null, role: a.tokens?.role || null, task: a.tokens?.task || null, ...u };
  });
  if (f.json) return out(rows);
  for (const r of rows) {
    process.stdout.write(`${(r.name || r.pane_id).padEnd(16)} ${String(r.kind).padEnd(9)} ${r.status.padEnd(8)} ${(r.role || "").padEnd(9)} ctx ${String(r.ctx ?? "-").padStart(4)}  ${String(r.tok ?? "-").padStart(6)}  ${r.cost ?? ""}  ${r.task ?? ""}\n`);
  }
}

function cmdPrompt(pos) {
  const [name, ...text] = pos;
  if (!name || !text.length) die("uso: gentle-herdr prompt <name> <text>");
  out(herdr(["agent", "prompt", name, text.join(" ")]));
}

function cmdStop(pos, f) {
  const name = pos[0] || die("uso: gentle-herdr stop <name> [--close]");
  const agent = listAgents().find((a) => a.name === name || a.pane_id === name);
  if (!agent) die(`no hay un agente vivo llamado ${name}`);
  herdr(["agent", "send-keys", name, "esc"], { allowFail: true });
  if (f.close) herdr(["pane", "close", agent.pane_id], { allowFail: true });
  out({ stopped: name, closed: Boolean(f.close) });
}

function cmdStatus(pos, f) {
  requireHerdr();
  const pane = process.env.HERDR_PANE_ID;
  const text = f.clear ? null : pos.join(" ");
  if (!f.clear && !text) die("uso: gentle-herdr status <texto> | --clear");
  reportTokens(pane, "gentle:activity", { summary: text }, { ttlMs: f.clear ? undefined : 30 * 60 * 1000 });
  out({ pane_id: pane, summary: text });
}

const [cmd, ...rest] = process.argv.slice(2);
const { pos, flags } = parseFlags(rest);
const table = { spawn: cmdSpawn, wait: cmdWait, result: cmdResult, list: cmdList, prompt: cmdPrompt, stop: cmdStop, status: cmdStatus };
if (!cmd || cmd === "-h" || cmd === "--help" || !table[cmd]) { process.stdout.write(`${USAGE}\n`); process.exit(cmd && !table[cmd] && cmd !== "-h" && cmd !== "--help" ? 1 : 0); }
try { table[cmd](pos, flags); } catch (e) { die(e.message); }
