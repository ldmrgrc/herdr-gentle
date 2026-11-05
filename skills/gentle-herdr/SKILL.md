---
name: gentle-herdr
description: "Run Gentle AI focused agents (explorer, parallel writers, independent verifier, context backstop) as background subagents in Herdr panes, with any agent kind (claude, codex, opencode, gemini, cursor). Use when Gentle AI routing names a reason to delegate and HERDR_ENV=1, when the user asks for a subagent, background agent, parallel work or a second opinion inside Herdr, or to publish an activity summary to the Herdr sidebar."
---

# Gentle AI focused agents on Herdr

You run inside Herdr, which owns your terminal. Herdr can start other coding
agents in sibling panes, watch whether they are working, blocked or idle, and read
their output. The `gentle-herdr` command packages that as Gentle AI's
focused-agent workflow. It replaces Gentle Shell's in-process subagents.

First check that you are inside Herdr:

```bash
test "${HERDR_ENV:-}" = 1 && command -v gentle-herdr
```

If the check fails, work inline and do not try to delegate through Herdr.

## When to delegate

Gentle AI's routing rules still decide. Delegate only for a reason you can name:

| Reason | Herdr subagent |
| :--- | :--- |
| Exploration needs more than one inline batch (about 3 calls and 10k tokens) or more than about 5 sequential lookups | One `--role explorer`. It returns a short map with `path:line` evidence |
| Two or more independent units, each several minutes of work, with disjoint edit surfaces | One `--role writer` per unit, in parallel |
| The change touches a named high-risk item (data, security, shared contracts, concurrency, delivery, or no test that would catch a regression) | One `--role verifier`, of a different kind or model than the agent that wrote the change |
| A long session needs to hand its next bounded unit to a fresh context | One `--role worker` |

If none of these holds, work inline. File count and task size never decide the
route on their own. You stay accountable for scope, decisions and the final
summary.

## Choose the agent kind

Herdr can start any installed agent, so pick the kind for the job:

- **Verifier:** use a different kind or model than the writer. For example, if
  Claude wrote the change, verify with `--kind codex`, or the reverse. This
  gives the independent second opinion Gentle AI asks for.
- **Explorer:** a fast or cheap model is enough (`--model` with a small model of
  that kind).
- **Writer:** the kind you trust most for that code. Default to your own kind.

Every kind already has Gentle AI's skills, Engram, Context7 and CodeGraph.

## Workflow

1. **Write the task to a file.** Copy the spec verbatim: exact strings, error
   messages, examples, acceptance checks and the files in scope. Never paraphrase
   it. If a feature document exists, point to it.

2. **Start the subagent.** It opens in the background tab `gentle:agents` and does
   not steal focus:

   ```bash
   gentle-herdr spawn exp-auth --kind codex --role explorer --task-file /tmp/task-auth.md
   gentle-herdr spawn fix-api  --kind claude --role writer   --task-file .odd/feature.md --cwd "$PWD"
   ```

   The output is JSON with `pane_id`, `task_file` and `result_file`. Names must
   match `[a-z][a-z0-9_-]{0,31}` and be unique among live agents.

3. **Keep working, or wait.** While a subagent runs, do non-overlapping work. To
   block until one or more settle:

   ```bash
   gentle-herdr wait exp-auth fix-api --timeout 1800000
   ```

   `blocked` means the subagent is waiting on an approval or a question. Read its
   output and decide. Answer it with `gentle-herdr prompt <name> "..."`, or tell
   the user that it needs them.

4. **Collect the result:**

   ```bash
   gentle-herdr result exp-auth
   ```

   Treat the report as evidence to check, not as truth. Re-read the files it cites
   before you rely on it.

5. **Follow up or stop:**

   ```bash
   gentle-herdr prompt fix-api "The test in pkg/x_test.go:42 still fails; fix only that."
   gentle-herdr stop exp-auth --close
   ```

   Close finished subagents so the background tab stays tidy, unless the user
   wants to inspect them.

## Show what you are doing

Publish a one-line activity summary to the Herdr sidebar at real milestones, not
on every step. It expires after 30 minutes:

```bash
gentle-herdr status "ODD 3/5 · implementing token refresh"
gentle-herdr status --clear
```

`gentle-herdr list` shows every agent with its state, role, parent, model,
context %, tokens and estimated cost. Use it before spawning, to avoid
duplicate names or duplicated work.

## Rules

- Never delegate commit, push, release or other delivery work. Those stay with the
  user.
- Do not let subagents start subagents. The handoff prompt already forbids it.
- Do not send input to a pane you did not start, unless the user asks.
- Engram is shared. Subagents save to the same project memory, so search it
  before you repeat their exploration.
- For anything Herdr can do beyond this workflow (layouts, logs, servers, waiting
  on output), use the `herdr` skill.
