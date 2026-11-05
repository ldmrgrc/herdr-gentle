// Gentle: Gentle Shell's agent cards and usage view, for the Herdr app.
// Every agent herdr-core runs (sub-agents too, nested under their parent) with
// its role, model, context used, tokens and cost; then today's totals.
// Numbers come from `gentle-usage` (this repo's usage/cli.mjs) via exec.

import { View, div } from "gpui-kit";
import { v_flex, h_flex } from "gpui-base";
import { exec, terminals, theme, run, notify } from "herdr";
import { NODE, CLI } from "./config.js";

const REFRESH_MS = 10000;
const ORDER = { blocked: 0, error: 0, working: 1, done: 2, idle: 3 };

// "gentle-explorer-codex" → "explorer"
const roleOf = (template) => (template?.startsWith("gentle-") ? template.split("-")[1] : template) || null;
const money = (v, exact) => (v == null ? "" : `${exact ? "" : "≈"}$${v < 10 ? v.toFixed(2) : v.toFixed(1)}`);

export default class Gentle extends View {
  init(_props, cx) {
    this.data = null;
    this.error = null;
    this.busy = false;
    this.sig = "";
    this.warned = new Set();
    this.last = 0;
    // Cheap check every 2 s: re-read usage when an agent changed state (a turn
    // ended) or every REFRESH_MS. The heavy work runs in gentle-usage, not here.
    cx.timer.every(2000, (cx) => {
      const sig = terminals().filter((t) => t.state === "live").map((t) => `${t.address}:${t.status}`).join(",");
      if (sig !== this.sig || Date.now() - this.last > REFRESH_MS) { this.sig = sig; this.refresh(cx); }
    });
    this.refresh(cx);
  }

  refresh(cx) {
    if (this.busy) return;
    this.busy = true;
    this.last = Date.now();
    cx.spawn(async (cx) => {
      try {
        const r = await exec(NODE, [CLI], { timeout: 20000 });
        this.data = JSON.parse(r.stdout);
        this.error = null;
        this.warnContext();
      } catch (e) {
        this.error = String(e?.message ?? e);
      }
      this.busy = false;
      cx.notify();
    });
  }

  // One toast per agent when it crosses 80% of its context window.
  warnContext() {
    for (const a of Object.values(this.data?.agents ?? {})) {
      if ((a.ctxPct ?? 0) < 80 || this.warned.has(a.address)) continue;
      this.warned.add(a.address);
      const t = terminals().find((x) => x.address === a.address);
      notify({ title: `${a.name || t?.program?.name || a.address}: contexto ${a.ctxPct}%`, body: "Compacta o pasa el siguiente paso a un subagente.", level: "warning", action: { name: "agent.focus", args: { terminal: a.address } } });
    }
  }

  // Agents = live terminals that report a status, plus anything gentle-usage recognized.
  rows() {
    const usage = this.data?.agents ?? {};
    const live = terminals().filter((t) => t.state === "live" && (t.status || usage[t.address]));
    const byParent = new Map();
    for (const t of live) {
      const key = live.some((p) => p.address === t.parent) ? t.parent : "";
      if (!byParent.has(key)) byParent.set(key, []);
      byParent.get(key).push(t);
    }
    const sort = (list) => list.sort((a, b) => (ORDER[a.status] ?? 4) - (ORDER[b.status] ?? 4) || (a.created_ms ?? 0) - (b.created_ms ?? 0));
    const out = [];
    const walk = (key, depth) => {
      for (const t of sort(byParent.get(key) ?? [])) {
        out.push({ t, u: usage[t.address] ?? {}, depth });
        walk(t.address, depth + 1);
      }
    };
    walk("", 0);
    return out;
  }

  render() {
    const th = theme();
    const rows = this.rows();

    const color = (s) => th[s === "error" ? "blocked" : s] ?? th.unknown ?? th.muted;
    const ctxColor = (p) => (p == null ? th.dim : p >= 80 ? th.blocked : p >= 50 ? th.done : th.idle);
    const today = this.data?.today;

    const bar = (pct) => div().w(36).h(4).rounded(2).bg(th.border).flex_none()
      .child(div().h(4).rounded(2).w(Math.max(1, Math.round((36 * (pct ?? 0)) / 100))).bg(ctxColor(pct)));

    const agentRow = ({ t, u, depth }) => {
      const role = roleOf(t.template);
      const name = t.name || t.program?.name || u.kind || t.address;
      return v_flex().id(`g-${t.address}`).px(10).py(5).gap(2).rounded(4)
        .hover((s) => s.bg(th.hover))
        .on_click(() => run("agent.focus", { terminal: t.address }))
        .child(h_flex().gap(6).items_center().pl(depth * 14)
          .child(div().w(7).h(7).rounded(4).flex_none().bg(color(t.status)))
          .child(div().flex_1().truncate().text_color(th.foreground).child(depth ? `└ ${name}` : name))
          .when(Boolean(role), (el) => el.child(div().px(5).rounded(3).bg(th.raised).text_size(11).text_color(th.accent).child(role)))
          .child(div().text_color(th.muted).text_size(11).child(money(u.cost_usd, u.cost_exact))))
        .child(h_flex().gap(6).items_center().pl(depth * 14 + 13).text_size(11).text_color(th.dim)
          .child(div().flex_1().truncate().child(u.model ?? (t.status ? t.status : "sin datos de sesión")))
          .when(u.ctxPct != null, (el) => el.child(bar(u.ctxPct)).child(div().w(30).text_color(ctxColor(u.ctxPct)).child(`${u.ctxPct}%`)))
          .when(Boolean(u.tok), (el) => el.child(div().child(u.tok))));
    };

    const section = (label, right) => h_flex().px(10).pt(10).pb(4).justify_between().text_size(11)
      .text_color(th.muted).font_semibold().child(label).child(div().text_color(th.dim).child(right ?? ""));

    const working = rows.filter((r) => r.t.status === "working").length;
    const blocked = rows.filter((r) => r.t.status === "blocked" || r.t.status === "error").length;
    const liveCost = rows.reduce((s, r) => s + (r.u.cost_usd ?? 0), 0);

    return v_flex().id("gentle").size_full().bg(th.chrome).text_size(13).overflow_y_scrollbar()
      .child(h_flex().px(10).pt(10).pb(2).justify_between().items_center()
        .child(div().font_semibold().text_color(th.accent).child("Gentle"))
        .child(div().text_size(11).text_color(th.dim).child(this.busy ? "actualizando…" : `${working} trabajando · ${blocked} te esperan`)))
      .child(section("AGENTES", liveCost ? money(liveCost) : ""))
      .children(rows.length ? rows.map(agentRow) : [div().px(10).py(6).text_size(12).text_color(th.dim)
        .child("Sin agentes. Abre uno desde + o pide a tu agente que delegue con gentle-hc.")])
      .child(section("HOY", today ? `${today.sessions} sesiones · ${money(today.cost_usd)}` : ""))
      .children((today?.models ?? []).map((m, i) => h_flex().id(`m-${i}`).px(10).py(2).gap(6).text_size(12)
        .child(div().w(52).text_color(th.muted).child(m.agent))
        .child(div().flex_1().truncate().text_color(th.foreground).child(m.model ?? "?"))
        .child(div().text_color(th.dim).child(m.tok))
        .child(div().w(52).text_color(th.muted).child(m.cost_usd == null ? "—" : money(m.cost_usd)))))
      .child(div().px(10).pt(10).pb(10).text_size(10).text_color(th.dim)
        .child(this.error ? `gentle-usage falló: ${this.error}` : "Costos ≈ = estimados a precio de API (usage/prices.json). OpenCode reporta el real."));
  }
}
