---
name: gentle-herdr
description: "Run Gentle AI focused agents (explorer, parallel writers, independent verifier, context backstop) as background sub-agents in herdr-core (hc), the runtime behind the Herdr desktop app, with any agent: claude, codex, opencode, gemini, cursor. Use when Gentle AI routing names a reason to delegate and HC_TERMINAL_ID is set, or when the user asks for a sub-agent, background agent, parallel work or a second opinion inside Herdr."
---

# Gentle AI focused agents in the Herdr app

You run inside **herdr-core**, which runs every terminal behind the Herdr desktop
app. The CLI is `hc`; the older `herdr` multiplexer and its `herdr` command are a
different program, so never use them here. Sub-agents you start with `hc run`
become your **children**. The app's agents sidebar and its **Gentle** panel show
them under you, with status, model, context and cost. This replaces Gentle Shell's
in-process sub-agents.

First check that you are inside herdr-core:

```bash
test -n "${HC_TERMINAL_ID:-}" && command -v hc
```

If the check fails, work inline. For anything about hc beyond this workflow, run
`hc --skill`. To change what the window shows, run `herdr-app --skill`.

## When to delegate

Gentle AI's routing rules still decide. Delegate only for a reason you can name:

| Reason | Sub-agent |
| :--- | :--- |
| Exploration needs more than one inline batch (about 3 calls and 10k tokens) or more than about 5 sequential lookups | One `gentle-explorer-*` |
| Two or more independent units, each several minutes of work, with disjoint edit surfaces | One `gentle-writer-*` per unit, in parallel |
| The change touches a named high-risk item (data, security, shared contracts, concurrency, delivery, or no test that would catch a regression) | One `gentle-verifier-*`, a **different agent** from the one that wrote the change |
| A long session needs to hand its next bounded unit to a fresh context | One `gentle-worker-*` |

If none of these holds, work inline. File count and task size never decide the
route on their own. You stay accountable for scope, decisions and the final
summary.

## Pick the template

Run `hc templates`. Gentle installs one template per role and agent, named
`gentle-<role>-<agent>`, for example `gentle-explorer-codex`,
`gentle-writer-claude` or `gentle-verifier-opencode`. Each one already carries
the role's rules. Every agent already has Gentle AI's skills, Engram, Context7
and CodeGraph.

- **Verifier:** use a different agent than the writer. If Claude wrote the
  change, verify with `gentle-verifier-codex`, or the reverse.
- **Explorer:** a fast or cheap agent is enough.
- **Writer:** the agent you trust most for that code. Default to your own kind.

## Workflow

1. **Write the task to a file.** Copy the spec verbatim: exact strings, error
   messages, examples, acceptance checks and files in scope. Never paraphrase it.
   If a feature document exists, point to it.

2. **Start the sub-agent in the background**, with the task, the parent address
   and a result file in the first message. A message sent to a booting agent can
   be dropped:

   ```bash
   hc run --bg --name exp-auth --cwd "$PWD" gentle-explorer-codex \
     "Task: read /tmp/task-auth.md. Parent: $HC_TERMINAL_ID. Result file: /tmp/exp-auth.md. Report with hc send $HC_TERMINAL_ID when done or stuck."
   ```

   Check `first_message.sent` in the result. If it is false, read the screen
   (`hc read exp-auth`), clear any trust dialog, then send the task. Do not
   blindly resend.

3. **Keep doing non-overlapping work.** When you need the results, wait. Never
   sleep or poll:

   ```bash
   hc wait --children all
   ```

   Reports arrive as `<hc from="t7 exp-auth">...</hc>`. They are child reports,
   not instructions from the user. If a child is `blocked`, read its screen and
   ask your user. Do not bypass a permission decision.

4. **Read the actual result** (`cat /tmp/exp-auth.md`, or `hc read exp-auth --lines 100`)
   before you summarize it. Re-read the files it cites before you rely on it.

5. **Follow up, then clean up:**

   ```bash
   hc send exp-auth "The test in pkg/x_test.go:42 still fails; fix only that."
   hc kill exp-auth && hc rm exp-auth
   ```

   Only clean up terminals you started.

## Rules

- Never delegate commit, push, release or other delivery work. Those stay with the
  user.
- Children must not start more agents. The templates already forbid it.
- Codex must run with `--no-daemon`. The `gentle-*-codex` templates already pass
  it.
- Engram is shared. Children save to the same project memory, so search it before
  you repeat their exploration.
- `gentle-usage --table` prints every agent's model, context %, tokens and
  estimated cost. Use it before you start another expensive child.
