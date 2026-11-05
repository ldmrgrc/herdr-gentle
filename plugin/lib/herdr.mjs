// Thin wrapper over the herdr CLI. The CLI is herdr's plugin API; we always
// call it through HERDR_BIN_PATH so it works on Unix sockets and Windows pipes.
import { spawnSync } from "node:child_process";

export const HERDR = process.env.HERDR_BIN_PATH || "herdr";

export class HerdrError extends Error {
  constructor(message, code) {
    super(message);
    this.code = code;
  }
}

/** Run `herdr ...args`. Returns parsed JSON `result` (or raw text with {text:true}). */
export function herdr(args, { text = false, timeout = 15000, allowFail = false } = {}) {
  const res = spawnSync(HERDR, args, { encoding: "utf8", timeout, maxBuffer: 16 * 1024 * 1024 });
  if (res.error) {
    if (allowFail) return null;
    throw new HerdrError(`no pude ejecutar herdr: ${res.error.message}`, "spawn");
  }
  const out = (res.stdout || "").trim();
  if (text) {
    if (res.status !== 0 && !allowFail) throw new HerdrError((res.stderr || out).trim(), "exit");
    return out;
  }
  let parsed = null;
  try { parsed = out ? JSON.parse(out) : null; } catch { /* not JSON */ }
  if (parsed && parsed.error) {
    if (allowFail) return null;
    throw new HerdrError(parsed.error.message || "herdr error", parsed.error.code);
  }
  if (res.status !== 0) {
    if (allowFail) return null;
    throw new HerdrError((res.stderr || out || `herdr ${args.join(" ")} falló`).trim(), "exit");
  }
  return parsed && "result" in parsed ? parsed.result : parsed;
}

export const listAgents = () => herdr(["agent", "list"], { allowFail: true })?.agents ?? [];
export const listPanes = () => herdr(["pane", "list"], { allowFail: true })?.panes ?? [];
export const listWorkspaces = () => herdr(["workspace", "list"], { allowFail: true })?.workspaces ?? [];
export const listTabs = (workspaceId) =>
  herdr(["tab", "list", ...(workspaceId ? ["--workspace", workspaceId] : [])], { allowFail: true })?.tabs ?? [];
export const getPane = (paneId) => herdr(["pane", "get", paneId], { allowFail: true })?.pane ?? null;

/** Patch display tokens on a pane (shown in the sidebar as $name). */
export function reportTokens(paneId, source, tokens, { ttlMs, seq } = {}) {
  const args = ["pane", "report-metadata", paneId, "--source", source];
  for (const [k, v] of Object.entries(tokens)) {
    if (v === null || v === undefined || v === "") args.push("--clear-token", k);
    else args.push("--token", `${k}=${String(v).slice(0, 80)}`);
  }
  if (ttlMs) args.push("--ttl-ms", String(ttlMs));
  args.push("--seq", String(seq ?? Date.now()));
  return herdr(args, { allowFail: true });
}

/** Agent name (if any) else pane id — the canonical herdr agent target. */
export const agentTarget = (a) => a.name || a.pane_id;
