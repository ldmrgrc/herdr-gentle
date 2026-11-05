// Per-session usage (model, tokens, context, cost) read from each agent's own
// session files. The parsers are exported so cli.mjs can match herdr-core
// terminals to their session by folder and start time.
import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { join, dirname } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { createHash } from "node:crypto";

const HOME = homedir();
const CLAUDE_DIR = process.env.CLAUDE_CONFIG_DIR || join(HOME, ".claude");
const CODEX_DIR = process.env.CODEX_HOME || join(HOME, ".codex");
const XDG_DATA = process.env.XDG_DATA_HOME || join(HOME, ".local", "share");
const OPENCODE_DIR = join(XDG_DATA, "opencode");
const GEMINI_DIR = join(HOME, ".gemini");

// ---------------------------------------------------------------------------
// Prices (USD per million tokens). Defaults ship with the plugin; a copy in
// ~/.config/herdr-gentle/prices.json wins so you can fix or extend them.
// ---------------------------------------------------------------------------
let pricesCache;
export function loadPrices() {
  if (pricesCache) return pricesCache;
  const here = dirname(fileURLToPath(import.meta.url));
  const candidates = [
    join(process.env.XDG_CONFIG_HOME || join(HOME, ".config"), "herdr-gentle", "prices.json"),
    join(here, "prices.json"),
  ].filter(Boolean);
  for (const file of candidates) {
    try { pricesCache = JSON.parse(readFileSync(file, "utf8")).models || []; return pricesCache; } catch { /* next */ }
  }
  return (pricesCache = []);
}

export function priceFor(model) {
  if (!model) return null;
  const m = model.toLowerCase();
  // Longest matching prefix/substring wins, so "gpt-5-mini" beats "gpt-5".
  let best = null;
  for (const p of loadPrices()) {
    if (m.includes(p.match.toLowerCase()) && (!best || p.match.length > best.match.length)) best = p;
  }
  return best;
}

function estimateCost(u) {
  const p = priceFor(u.model);
  if (!p) return null;
  return ((u.input || 0) * p.input + (u.output || 0) * p.output +
    (u.cacheRead || 0) * (p.cache_read ?? p.input) + (u.cacheWrite || 0) * (p.cache_write ?? p.input)) / 1e6;
}

// ---------------------------------------------------------------------------
// File helpers with a (path, size, mtime) cache — dashboards refresh often.
// ---------------------------------------------------------------------------
const parseCache = new Map();
function cached(file, parse) {
  let st;
  try { st = statSync(file); } catch { return null; }
  const key = `${st.size}:${st.mtimeMs}`;
  const hit = parseCache.get(file);
  if (hit && hit.key === key) return hit.value;
  let value = null;
  try { value = parse(readFileSync(file, "utf8")); } catch { value = null; }
  if (value) value.updatedAt = st.mtimeMs;
  parseCache.set(file, { key, value });
  return value;
}

function* jsonLines(text) {
  for (const line of text.split("\n")) {
    if (!line) continue;
    try { yield JSON.parse(line); } catch { /* partial line while writing */ }
  }
}

function findFile(root, predicate, maxDepth = 5) {
  let best = null;
  const walk = (dir, depth) => {
    let entries;
    try { entries = readdirSync(dir, { withFileTypes: true }); } catch { return; }
    for (const e of entries) {
      const p = join(dir, e.name);
      if (e.isDirectory()) { if (depth < maxDepth) walk(p, depth + 1); }
      else if (predicate(e.name, p)) {
        const m = statSync(p).mtimeMs;
        if (!best || m > best.m) best = { p, m };
      }
    }
  };
  walk(root, 0);
  return best?.p ?? null;
}

const empty = (agent) => ({ agent, model: null, input: 0, output: 0, cacheRead: 0, cacheWrite: 0, context: null, contextWindow: null, cost: null, costExact: false, turns: 0 });

// ---------------------------------------------------------------------------
// Claude Code: ~/.claude/projects/<cwd-slug>/<session-id>.jsonl
// ---------------------------------------------------------------------------
function parseClaude(text) {
  const u = empty("claude");
  const seen = new Set();
  for (const ev of jsonLines(text)) {
    const msg = ev.message;
    if (ev.type !== "assistant" || !msg?.usage) continue;
    const id = `${msg.id ?? ""}:${ev.requestId ?? ""}`;
    if (msg.id && seen.has(id)) continue; // streamed chunks repeat the same usage
    seen.add(id);
    const x = msg.usage;
    if (msg.model && msg.model !== "<synthetic>") u.model = msg.model;
    u.input += x.input_tokens || 0;
    u.output += x.output_tokens || 0;
    u.cacheRead += x.cache_read_input_tokens || 0;
    u.cacheWrite += x.cache_creation_input_tokens || 0;
    u.context = (x.input_tokens || 0) + (x.cache_read_input_tokens || 0) + (x.cache_creation_input_tokens || 0);
    u.turns++;
  }
  if (u.model) u.contextWindow = /\[1m\]|-1m/i.test(u.model) ? 1_000_000 : 200_000;
  u.cost = estimateCost(u);
  return u;
}

const claudeSlug = (cwd) => cwd.replace(/[^A-Za-z0-9]/g, "-");

function claudeFile(session, cwd) {
  if (session?.kind === "path" && existsSync(session.value)) return session.value;
  const projects = join(CLAUDE_DIR, "projects");
  if (session?.kind === "id") {
    const direct = cwd && join(projects, claudeSlug(cwd), `${session.value}.jsonl`);
    if (direct && existsSync(direct)) return direct;
    return findFile(projects, (n) => n === `${session.value}.jsonl`, 2);
  }
  // No integration: newest transcript for this folder (best effort).
  if (cwd) return findFile(join(projects, claudeSlug(cwd)), (n) => n.endsWith(".jsonl"), 0);
  return null;
}

// ---------------------------------------------------------------------------
// Codex: ~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<id>.jsonl
// ---------------------------------------------------------------------------
function parseCodex(text) {
  const u = empty("codex");
  let total = null;
  for (const ev of jsonLines(text)) {
    const p = ev.payload;
    if (!p) continue;
    if (ev.type === "turn_context" && p.model) u.model = p.model;
    if (p.type === "token_count" && p.info) {
      total = p.info.total_token_usage || total;
      if (p.info.model_context_window) u.contextWindow = p.info.model_context_window;
      const last = p.info.last_token_usage;
      if (last) u.context = (last.input_tokens || 0) + (last.output_tokens || 0);
      u.turns++;
    }
  }
  if (total) {
    u.cacheRead = total.cached_input_tokens || 0;
    u.input = Math.max(0, (total.input_tokens || 0) - u.cacheRead);
    u.output = (total.output_tokens || 0) + (total.reasoning_output_tokens || 0);
  }
  u.cost = estimateCost(u);
  return u;
}

function codexFile(session) {
  if (session?.kind === "path" && existsSync(session.value)) return session.value;
  if (session?.kind === "id") return findFile(join(CODEX_DIR, "sessions"), (n) => n.includes(session.value) && n.endsWith(".jsonl"));
  return null;
}

// ---------------------------------------------------------------------------
// OpenCode: per-message JSON (storage/message/<session>/) or opencode.db.
// OpenCode records real cost, so it is exact.
// ---------------------------------------------------------------------------
function foldOpenCode(messages) {
  const u = empty("opencode");
  for (const m of messages) {
    if (m.role !== "assistant" || !m.tokens) continue;
    u.model = m.modelID || u.model;
    u.input += m.tokens.input || 0;
    u.output += (m.tokens.output || 0) + (m.tokens.reasoning || 0);
    u.cacheRead += m.tokens.cache?.read || 0;
    u.cacheWrite += m.tokens.cache?.write || 0;
    u.context = (m.tokens.input || 0) + (m.tokens.cache?.read || 0) + (m.tokens.cache?.write || 0);
    if (typeof m.cost === "number") { u.cost = (u.cost || 0) + m.cost; u.costExact = true; }
    u.turns++;
  }
  if (!u.costExact) u.cost = estimateCost(u);
  return u;
}

function openCodeUsage(session) {
  if (session?.kind !== "id") return null;
  const dir = join(OPENCODE_DIR, "storage", "message", session.value);
  if (existsSync(dir)) {
    const msgs = [];
    for (const f of readdirSync(dir)) {
      if (!f.endsWith(".json")) continue;
      try { msgs.push(JSON.parse(readFileSync(join(dir, f), "utf8"))); } catch { /* skip */ }
    }
    msgs.sort((a, b) => (a.time?.created || 0) - (b.time?.created || 0));
    const u = foldOpenCode(msgs);
    u.updatedAt = Date.now();
    return u;
  }
  const db = join(OPENCODE_DIR, "opencode.db");
  if (existsSync(db)) {
    const id = session.value.replace(/[^A-Za-z0-9_-]/g, "");
    const res = spawnSync("sqlite3", ["-readonly", db, `select data from message where session_id='${id}' order by time_created;`], { encoding: "utf8", timeout: 4000 });
    if (res.status === 0) {
      const msgs = [];
      for (const line of res.stdout.split("\n")) { try { msgs.push(JSON.parse(line)); } catch { /* skip */ } }
      const u = foldOpenCode(msgs);
      u.updatedAt = statSync(db).mtimeMs;
      return u;
    }
  }
  return null;
}

// ---------------------------------------------------------------------------
// Gemini CLI: ~/.gemini/tmp/<project-hash>/chats/session-*.json
// ---------------------------------------------------------------------------
function parseGemini(text) {
  const u = empty("gemini");
  const data = JSON.parse(text);
  for (const m of data.messages || []) {
    if (!m.tokens) continue;
    u.model = m.model || u.model;
    u.cacheRead += m.tokens.cached || 0;
    u.input += Math.max(0, (m.tokens.input || 0) - (m.tokens.cached || 0));
    u.output += (m.tokens.output || 0) + (m.tokens.thoughts || 0);
    u.context = m.tokens.input || 0;
    u.turns++;
  }
  u.cost = estimateCost(u);
  return u;
}

function geminiFile(session) {
  if (session?.kind === "path" && existsSync(session.value)) return session.value;
  if (session?.kind === "id") return findFile(join(GEMINI_DIR, "tmp"), (n, p) => n.endsWith(".json") && p.includes("chats") && n.includes(session.value.slice(0, 8)), 3);
  return null;
}

// ---------------------------------------------------------------------------
/** Usage for one herdr agent (an entry of `herdr agent list`). */
export function usageForAgent(agent) {
  const kind = (agent.agent || "").toLowerCase();
  const session = agent.agent_session || null;
  const cwd = agent.foreground_cwd || agent.cwd;
  try {
    if (kind === "claude") { const f = claudeFile(session, cwd); return f && cached(f, parseClaude); }
    if (kind === "codex") { const f = codexFile(session); return f && cached(f, parseCodex); }
    if (kind === "opencode" || kind === "kilo") return openCodeUsage(session);
    if (kind === "gemini") { const f = geminiFile(session); return f && cached(f, parseGemini); }
  } catch { /* unreadable session: show nothing rather than wrong numbers */ }
  return null;
}

/** Today's usage across every Claude Code / Codex / Gemini session file, grouped by model. */
export function todayUsage() {
  const start = new Date(); start.setHours(0, 0, 0, 0);
  const since = start.getTime();
  const files = [];
  const collect = (root, test, depth) => {
    const walk = (dir, d) => {
      let entries;
      try { entries = readdirSync(dir, { withFileTypes: true }); } catch { return; }
      for (const e of entries) {
        const p = join(dir, e.name);
        if (e.isDirectory()) { if (d < depth) walk(p, d + 1); }
        else if (test(e.name, p)) { try { if (statSync(p).mtimeMs >= since) files.push(p); } catch { /* gone */ } }
      }
    };
    walk(root, 0);
  };
  collect(join(CLAUDE_DIR, "projects"), (n) => n.endsWith(".jsonl"), 1);
  collect(join(CODEX_DIR, "sessions"), (n) => n.endsWith(".jsonl"), 4);
  collect(join(GEMINI_DIR, "tmp"), (n, p) => n.endsWith(".json") && p.includes(`${"chats"}`), 3);
  const byModel = new Map();
  let sessions = 0;
  for (const f of files) {
    const parse = f.startsWith(CLAUDE_DIR) ? parseClaude : f.startsWith(CODEX_DIR) ? parseCodex : parseGemini;
    const u = cached(f, parse);
    if (!u || !u.turns) continue;
    sessions++;
    const key = `${u.agent}:${u.model || "?"}`;
    const acc = byModel.get(key) || { ...empty(u.agent), model: u.model, cost: 0, sessions: 0 };
    for (const k of ["input", "output", "cacheRead", "cacheWrite", "turns"]) acc[k] += u[k];
    if (u.cost != null) acc.cost += u.cost; else acc.unpriced = true;
    acc.sessions++;
    byModel.set(key, acc);
  }
  return { sessions, models: [...byModel.values()].sort((a, b) => (b.cost || 0) - (a.cost || 0)) };
}

// ---------------------------------------------------------------------------
// Formatting for sidebar tokens (≤80 chars each) and the dashboard.
// ---------------------------------------------------------------------------
export function fmtTokens(n) {
  if (!n) return "0";
  if (n >= 1e6) return `${(n / 1e6).toFixed(n >= 1e7 ? 0 : 1)}M`;
  if (n >= 1e3) return `${(n / 1e3).toFixed(n >= 1e4 ? 0 : 1)}k`;
  return String(n);
}
export const fmtCost = (u) => (u?.cost == null ? null : `${u.costExact ? "" : "≈"}$${u.cost < 10 ? u.cost.toFixed(2) : u.cost.toFixed(1)}`);
export const ctxPercent = (u) => (u?.context && u?.contextWindow ? Math.min(100, Math.round((u.context / u.contextWindow) * 100)) : null);
export const shortModel = (m) => (m ? m.replace(/^(anthropic|openai|google)\//, "").replace(/^claude-/, "").replace(/-\d{8}$/, "") : null);
export const totalTokens = (u) => (u ? u.input + u.output + u.cacheRead + u.cacheWrite : 0);

export function sidebarTokens(u) {
  if (!u) return { model: null, ctx: null, ctxwarn: null, tok: null, cost: null };
  const pct = ctxPercent(u);
  return {
    model: shortModel(u.model),
    ctx: pct == null ? null : `${pct}%`,
    // Separate token so the sidebar can style it red without numeric rules.
    ctxwarn: pct != null && pct >= 80 ? `contexto ${pct}%: compacta o delega` : null,
    tok: fmtTokens(totalTokens(u)),
    cost: fmtCost(u),
  };
}

// ---------------------------------------------------------------------------
// herdr-core terminals → session files. herdr-core does not know an agent's
// session id, so we match by folder and start time, and never give one file
// to two terminals.
// ---------------------------------------------------------------------------
function firstTimestamp(file) {
  try {
    const head = readFileSync(file, "utf8").slice(0, 64 * 1024);
    for (const ev of jsonLines(head)) {
      const ts = ev.timestamp || ev.payload?.timestamp;
      if (ts) return Date.parse(ts);
    }
  } catch { /* unreadable */ }
  return statSync(file).birthtimeMs || statSync(file).mtimeMs;
}

function pickClosest(files, createdMs, used) {
  let best = null;
  for (const f of files) {
    if (used.has(f)) continue;
    let st; try { st = statSync(f); } catch { continue; }
    if (createdMs && st.mtimeMs < createdMs - 5000) continue; // not touched since the terminal started
    const d = createdMs ? Math.abs(firstTimestamp(f) - createdMs) : -st.mtimeMs;
    if (!best || d < best.d) best = { f, d };
  }
  if (best) used.add(best.f);
  return best?.f ?? null;
}

function listDir(dir, test) {
  try { return readdirSync(dir).filter(test).map((n) => join(dir, n)); } catch { return []; }
}

function codexCandidates(createdMs, cwd) {
  const out = [];
  const root = join(CODEX_DIR, "sessions");
  const days = new Set();
  for (const t of [createdMs || Date.now(), Date.now()]) {
    const d = new Date(t);
    days.add(join(root, String(d.getFullYear()), String(d.getMonth() + 1).padStart(2, "0"), String(d.getDate()).padStart(2, "0")));
  }
  for (const dir of days) {
    for (const f of listDir(dir, (n) => n.endsWith(".jsonl"))) {
      try {
        const first = JSON.parse(readFileSync(f, "utf8").split("\n", 1)[0]);
        if (!cwd || first?.payload?.cwd === cwd) out.push(f);
      } catch { /* skip */ }
    }
  }
  return out;
}

function openCodeSessionFor(cwd, createdMs) {
  const db = join(OPENCODE_DIR, "opencode.db");
  if (!existsSync(db) || !cwd) return null;
  const q = `select id from session where directory='${cwd.replace(/'/g, "''")}' and time_updated >= ${Math.floor((createdMs || 0) - 5000)} order by abs(time_created - ${Math.floor(createdMs || Date.now())}) limit 1;`;
  const res = spawnSync("sqlite3", ["-readonly", db, q], { encoding: "utf8", timeout: 4000 });
  return res.status === 0 && res.stdout.trim() ? { kind: "id", value: res.stdout.trim() } : null;
}

/** Normalize what herdr-core says a terminal runs into one of our agent kinds. */
export function agentKind(t) {
  const names = [t.status?.app, ...(Object.values(t.records || {}).map((r) => r?.app)),
    t.foreground?.name, t.foreground?.argv?.[0], t.argv?.[0], t.template].filter(Boolean).map((s) => String(s).toLowerCase());
  for (const n of names) {
    if (n.includes("claude")) return "claude";
    if (n.includes("codex")) return "codex";
    if (n.includes("opencode") || n.includes("kilo")) return "opencode";
    if (n.includes("gemini")) return "gemini";
  }
  return null;
}

/** Usage for a herdr-core terminal ({address, kind, cwd, createdMs}). `used` avoids double matches. */
export function usageForTerminal({ kind, cwd, createdMs }, used = new Set()) {
  try {
    if (kind === "claude" && cwd) {
      const f = pickClosest(listDir(join(CLAUDE_DIR, "projects", claudeSlug(cwd)), (n) => n.endsWith(".jsonl")), createdMs, used);
      return f && cached(f, parseClaude);
    }
    if (kind === "codex") {
      const f = pickClosest(codexCandidates(createdMs, cwd), createdMs, used);
      return f && cached(f, parseCodex);
    }
    if (kind === "opencode") return openCodeUsage(openCodeSessionFor(cwd, createdMs));
    if (kind === "gemini" && cwd) {
      const hash = createHash("sha256").update(cwd).digest("hex");
      const f = pickClosest(listDir(join(GEMINI_DIR, "tmp", hash, "chats"), (n) => n.endsWith(".json")), createdMs, used);
      return f && cached(f, parseGemini);
    }
  } catch { /* show nothing rather than wrong numbers */ }
  return null;
}
