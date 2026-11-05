#!/usr/bin/env node
// Gentle dashboard for herdr: the Gentle Shell "Agents", "Usage" and
// "Changes" views, as a herdr plugin pane. Dependency-free ANSI TUI.
//   1 Agentes  — every agent in every workspace: state, role/parent, model, ctx, tokens, cost
//   2 Consumo  — live sessions plus today's totals per model
//   3 Cambios  — uncommitted git changes in every folder agents work in
import { spawnSync } from "node:child_process";
import { herdr, listAgents, listWorkspaces } from "../lib/herdr.mjs";
import { usageForAgent, sidebarTokens, todayUsage, fmtTokens, totalTokens, shortModel, ctxPercent } from "../lib/usage.mjs";

const VIEWS = ["Agentes", "Consumo", "Cambios"];
const initial = Math.max(0, VIEWS.findIndex((v) => v.toLowerCase().startsWith((process.argv[2] || process.env.GENTLE_VIEW || "").toLowerCase().slice(0, 3))));
const S = { view: process.argv[2] ? initial : 0, sel: 0, rows: [], detail: null, confirm: null, flash: "", today: null, todayAt: 0 };

const E = "\x1b[";
const c = { dim: (s) => `${E}2m${s}${E}22m`, bold: (s) => `${E}1m${s}${E}22m`, inv: (s) => `${E}7m${s}${E}27m`,
  fg: (n, s) => `${E}38;5;${n}m${s}${E}39m` };
const STATE_COLOR = { working: 75, blocked: 203, idle: 114, done: 150, unknown: 245 };
const ICON = { working: "●", blocked: "▲", idle: "○", done: "✔", unknown: "?" };
const pad = (s, n) => { s = String(s ?? ""); const len = [...s].length; return len >= n ? [...s].slice(0, n - 1).join("") + "…" : s + " ".repeat(n - len); };
const padL = (s, n) => { s = String(s ?? ""); return s.length >= n ? s : " ".repeat(n - s.length) + s; };
const ctxColor = (p) => (p == null ? 245 : p >= 80 ? 203 : p >= 50 ? 221 : 114);

// ------------------------------------------------------------------ data
function wsNames() { const m = new Map(); for (const w of listWorkspaces()) m.set(w.workspace_id, w.label || w.workspace_id); return m; }

function loadAgents() {
  const names = wsNames();
  return listAgents().filter((a) => a.agent).map((a) => {
    const u = usageForAgent(a);
    return { a, u, t: sidebarTokens(u), ws: names.get(a.workspace_id) || a.workspace_id };
  }).sort((x, y) => (x.ws + (x.a.tokens?.parent ? "1" : "0") + x.a.pane_id).localeCompare(y.ws + (y.a.tokens?.parent ? "1" : "0") + y.a.pane_id));
}

function loadChanges() {
  const dirs = new Map();
  for (const w of listWorkspaces()) if (w.cwd) dirs.set(w.cwd, w.label || w.cwd);
  for (const a of listAgents()) { const d = a.foreground_cwd || a.cwd; if (d && !dirs.has(d)) dirs.set(d, a.name || a.agent || d); }
  const roots = new Map();
  for (const [dir, label] of dirs) {
    const top = spawnSync("git", ["-C", dir, "rev-parse", "--show-toplevel"], { encoding: "utf8" });
    if (top.status !== 0) continue;
    const root = top.stdout.trim();
    if (roots.has(root)) continue;
    const st = spawnSync("git", ["-C", root, "status", "--porcelain=v1", "-b"], { encoding: "utf8" }).stdout || "";
    const [branchLine, ...files] = st.split("\n").filter(Boolean);
    const stat = (spawnSync("git", ["-C", root, "diff", "--shortstat", "HEAD"], { encoding: "utf8" }).stdout || "").trim();
    roots.set(root, { root, label, branch: (branchLine || "").replace(/^## /, ""), files, stat });
  }
  return [...roots.values()].sort((a, b) => b.files.length - a.files.length);
}

// ------------------------------------------------------------------ render
function header(cols) {
  const tabs = VIEWS.map((v, i) => (i === S.view ? c.inv(` ${i + 1} ${v} `) : c.dim(` ${i + 1} ${v} `))).join(" ");
  return `${c.fg(211, c.bold(" gentle "))} ${tabs}${" ".repeat(Math.max(1, cols - 40))}`.slice(0, cols * 3);
}

function renderAgents(lines, cols) {
  S.rows = loadAgents();
  lines.push(c.dim(`   ${pad("agente", 18)}${pad("estado", 10)}${pad("rol / padre", 20)}${pad("modelo", 16)}${padL("ctx", 5)} ${padL("tokens", 7)} ${padL("costo", 8)}  ${pad("espacio", 14)}tarea`));
  let total = 0;
  S.rows.forEach((r, i) => {
    const st = r.a.agent_status;
    const name = r.a.name || r.a.agent;
    const role = r.a.tokens?.role ? `${r.a.tokens.role} ← ${r.a.tokens.parent || "?"}` : "";
    const pct = ctxPercent(r.u);
    const ctx = pct == null ? "-" : `${pct}%`;
    if (r.u?.cost) total += r.u.cost;
    const line = ` ${c.fg(STATE_COLOR[st] || 245, ICON[st] || "?")} ${pad((r.a.tokens?.parent ? "└ " : "") + name, 18)}${c.fg(STATE_COLOR[st] || 245, pad(st, 10))}${pad(role, 20)}${pad(r.t.model || "-", 16)}${c.fg(ctxColor(pct), padL(ctx, 5))} ${padL(r.t.tok || "-", 7)} ${padL(r.t.cost || "", 8)}  ${pad(r.ws, 14)}${r.a.tokens?.task || r.a.tokens?.summary || ""}`;
    lines.push(i === S.sel ? c.inv(line.padEnd(cols)) : line);
  });
  if (!S.rows.length) lines.push(c.dim("   No hay agentes. Lanza uno en un panel o con: gentle-herdr spawn <nombre> --kind claude --task \"...\""));
  lines.push("", c.dim(`   ${S.rows.length} agentes · ${S.rows.filter((r) => r.a.agent_status === "working").length} trabajando · ${S.rows.filter((r) => r.a.agent_status === "blocked").length} esperando respuesta · costo en vivo ≈$${total.toFixed(2)}`));
  return "↑↓ elegir · enter ir · r leer salida · x interrumpir · c cerrar panel · 1-3 vistas · q salir";
}

function renderUsage(lines) {
  if (!S.today || Date.now() - S.todayAt > 15000) { S.today = todayUsage(); S.todayAt = Date.now(); }
  const live = loadAgents();
  S.rows = [];
  lines.push(c.bold("  Sesiones abiertas en herdr"));
  lines.push(c.dim(`   ${pad("agente", 18)}${pad("modelo", 22)}${padL("entrada", 9)}${padL("salida", 9)}${padL("caché", 9)}${padL("turnos", 8)}${padL("costo", 9)}`));
  for (const r of live) {
    const u = r.u;
    if (!u) { lines.push(`   ${pad(r.a.name || r.a.agent, 18)}${c.dim("sin datos de sesión (¿falta herdr integration install?)")}`); continue; }
    lines.push(`   ${pad(r.a.name || r.a.agent, 18)}${pad(shortModel(u?.model) || "-", 22)}${padL(fmtTokens(u?.input), 9)}${padL(fmtTokens(u?.output), 9)}${padL(fmtTokens((u?.cacheRead || 0) + (u?.cacheWrite || 0)), 9)}${padL(u?.turns ?? "-", 8)}${padL(r.t.cost || "-", 9)}`);
  }
  lines.push("", c.bold(`  Hoy (${S.today.sessions} sesiones de Claude Code, Codex y Gemini)`));
  lines.push(c.dim(`   ${pad("agente", 10)}${pad("modelo", 30)}${padL("tokens", 9)}${padL("sesiones", 10)}${padL("costo", 10)}`));
  let sum = 0;
  for (const m of S.today.models) {
    sum += m.cost || 0;
    lines.push(`   ${pad(m.agent, 10)}${pad(shortModel(m.model) || "?", 30)}${padL(fmtTokens(totalTokens(m)), 9)}${padL(m.sessions, 10)}${padL(m.unpriced ? "sin precio" : `≈$${m.cost.toFixed(2)}`, 10)}`);
  }
  lines.push(c.dim(`   total ≈$${sum.toFixed(2)} (equivalente API; precios en prices.json, OpenCode usa su costo real)`));
  return "1-3 vistas · q salir";
}

function renderChanges(lines, cols) {
  S.rows = loadChanges();
  S.rows.forEach((r, i) => {
    const head = ` ${r.files.length ? c.fg(221, "●") : c.fg(114, "○")} ${pad(r.label, 18)}${pad(r.branch, 32)}${r.files.length} archivos  ${c.dim(r.stat)}`;
    lines.push(i === S.sel ? c.inv(head.padEnd(cols)) : head);
    if (i === S.sel) for (const f of r.files.slice(0, 12)) lines.push(`      ${c.fg(f.startsWith("??") ? 245 : f[0] === "D" || f[1] === "D" ? 203 : 114, f.slice(0, 2))} ${f.slice(3)}`);
    if (i === S.sel && r.files.length > 12) lines.push(c.dim(`      … ${r.files.length - 12} más`));
  });
  if (!S.rows.length) lines.push(c.dim("   Ningún repositorio git en los espacios abiertos."));
  return "↑↓ elegir · enter ver diff · 1-3 vistas · q salir";
}

function render() {
  const cols = process.stdout.columns || 100;
  const rowsMax = process.stdout.rows || 30;
  const lines = [header(cols), ""];
  let hint;
  if (S.detail) {
    lines.push(c.bold(`  salida de ${S.detail.name}`), "");
    lines.push(...S.detail.text.split("\n").slice(-(rowsMax - 6)).map((l) => `  ${l}`));
    hint = "esc volver";
  } else hint = [renderAgents, renderUsage, renderChanges][S.view](lines, cols);
  if (S.confirm) hint = c.fg(203, S.confirm.text);
  else if (S.flash) hint = c.fg(221, S.flash);
  const body = lines.slice(0, rowsMax - 2);
  while (body.length < rowsMax - 2) body.push("");
  process.stdout.write(`${E}H${body.map((l) => `${l}${E}K`).join("\n")}\n${E}K\n${c.dim(` ${hint}`)}${E}K`);
}

// ------------------------------------------------------------------ input
function cleanup() { process.stdout.write(`${E}?25h${E}?1049l`); try { process.stdin.setRawMode(false); } catch { /* not a tty */ } }
function quit() { cleanup(); process.exit(0); }

function withTerminal(fn) {
  cleanup();
  process.stdin.pause();
  try { fn(); } finally {
    process.stdout.write(`${E}?1049h${E}?25l`);
    process.stdin.setRawMode(true); process.stdin.resume(); render();
  }
}

function onKey(k) {
  S.flash = "";
  if (S.confirm) { const go = k === "y"; const act = S.confirm.act; S.confirm = null; if (go) act(); return render(); }
  if (k === "q" || k === "\x03") return quit();
  if (k === "\x1b") { if (S.detail) { S.detail = null; return render(); } return quit(); }
  if (["1", "2", "3"].includes(k)) { S.view = Number(k) - 1; S.sel = 0; S.detail = null; return render(); }
  if (k === "\t") { S.view = (S.view + 1) % VIEWS.length; S.sel = 0; return render(); }
  if (k === "\x1b[A" || k === "k") S.sel = Math.max(0, S.sel - 1);
  if (k === "\x1b[B" || k === "j") S.sel = Math.min(Math.max(0, S.rows.length - 1), S.sel + 1);
  const row = S.rows[S.sel];
  if (S.view === 0 && row) {
    const target = row.a.name || row.a.pane_id;
    if (k === "\r") { herdr(["agent", "focus", target], { allowFail: true }); return quit(); }
    if (k === "r") S.detail = { name: target, text: herdr(["agent", "read", target, "--source", "recent-unwrapped", "--lines", "200"], { text: true, allowFail: true }) || "(sin salida)" };
    if (k === "x") { herdr(["agent", "send-keys", target, "esc"], { allowFail: true }); S.flash = `esc enviado a ${target}`; }
    if (k === "c") S.confirm = { text: `¿Cerrar el panel de ${target}? (y/n)`, act: () => herdr(["pane", "close", row.a.pane_id], { allowFail: true }) };
  }
  if (S.view === 2 && row && k === "\r") {
    const script = '( git -C "$1" -c color.ui=always diff HEAD; echo; git -C "$1" status --short | grep "^??" ) | ${PAGER:-less -R}';
    withTerminal(() => spawnSync("sh", ["-c", script, "sh", row.root], { stdio: "inherit" }));
  }
  render();
}

process.stdout.write(`${E}?1049h${E}?25l`);
process.on("exit", cleanup);
process.on("SIGTERM", quit);
process.stdout.on("resize", render);
if (process.stdin.isTTY) process.stdin.setRawMode(true);
process.stdin.setEncoding("utf8");
process.stdin.on("data", onKey);
render();
setInterval(() => { if (!S.confirm) render(); }, 2000);
