#!/usr/bin/env node
// Builds the personal "gentle" layout from the app's own shipped main.json:
// the same window, plus the Gentle panel under Spaces and Agents in the left
// sidebar. The app never docks new mods into its shipped layouts, so a
// personal layout is the way to show the panel without editing main.
//   node make-layout.mjs <main.json> <gentle.json> [theme]
// With a theme, it goes on this layout's root, which is where the app keeps a
// layout's look: deleting the layout leaves your main and its theme untouched.
import { readFileSync, writeFileSync } from "node:fs";

const [src, dest, theme] = process.argv.slice(2);
if (!src || !dest) { console.error("uso: make-layout.mjs <main.json> <gentle.json>"); process.exit(2); }

const layout = JSON.parse(readFileSync(src, "utf8"));
const panel = { id: "gentle", type: "block", size: { weight: 1 }, min: 120, content: { mod: "gentle" } };

const find = (node, id) => {
  if (node?.id === id) return node;
  for (const c of node?.children ?? []) { const f = find(c, id); if (f) return f; }
  return null;
};
const hasGentle = (node) => node?.content?.mod === "gentle" || (node?.children ?? []).some(hasGentle);

if (!hasGentle(layout)) {
  // Preferred: below Agents in the sidebar list column. Fallbacks keep it visible
  // if a future main.json renames those nodes.
  const lists = find(layout, "sidebar-lists") ?? find(layout, "sidebar");
  if (lists?.children) {
    const at = lists.children.findIndex((c) => c.id === "agents");
    lists.children.splice(at >= 0 ? at + 1 : lists.children.length, 0, panel);
  } else {
    layout.children = [...(layout.children ?? []), { ...panel, size: { px: 320 } }];
  }
}
delete layout.cloned_from;
if (theme) layout.theme = theme;
writeFileSync(dest, `${JSON.stringify(layout, null, 2)}\n`);
console.log(dest);
