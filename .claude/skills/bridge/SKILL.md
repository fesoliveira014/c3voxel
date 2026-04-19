---
name: bridge
description: Use this skill to set up the cross-session message bridge in a project (install hooks, seed .bridge/ state) OR when `.bridge/config.json` already exists and Claude is about to make a decision, ask a cross-project question, or capture an observation worth persisting across sessions. Trigger phrases include "set up bridge", "install bridge hooks", "wire project to vault", "emit bridge message", or any moment where a decision/question/note would be lost without bridge persistence. Do NOT use for general project setup unrelated to the bridge, and do NOT use when `mcp-bridge` package is not installed on the user's PATH.
---

# Bridge — cross-session messaging setup + runtime guidance

This skill has two modes, gated on whether `.bridge/config.json` exists in the project root.

## Mode 1 — Install (no `.bridge/` present)

Run the bootstrapper. Ask the user for their bridge session id (the project's identifier, e.g. `c3voxel`) and the broker URL (usually `http://127.0.0.1:7891`).

```bash
bash bridge/scripts/install.sh <session_id> <broker_url>
```

The script is idempotent and refuses to overwrite existing files (config, git hooks). It produces a summary at the end via `verify.sh`. Surface any ✗ lines to the user.

## Mode 2 — Runtime guidance (`.bridge/` present)

The hooks already emit these kinds automatically — do NOT call `mcp-bridge emit` or the MCP tool for them:

- `task.created` / `task.updated` / `task.completed` — Claude's TaskCreate/TaskUpdate firing.
- `doc.sync` — on `git commit`.
- `commit.landed` — on `git push`.

Call the CLI directly (or the matching MCP tool) for the kinds the hooks do NOT cover:

- **`decision.logged`** — after you and the user converge on any design decision: "we will use approach X because Y". Capture context/decision/consequences.
- **`question.asked`** — when you need information from another project/session and want the answer to arrive asynchronously.
- **`note.captured`** — a freeform observation worth persisting: an invariant, a gotcha, an insight that would be lost otherwise. Skip routine progress notes.
- **`task.proposed`** — only when accepting a vault-originated proposal: use `emit task-created --in-reply-to <proposal_id>`.

**Ack-pop on inbox polling (v1 manual step).** When you poll the bridge inbox (via `mcp__bridge__read_messages`) and observe a `doc.sync.ack` addressed to this project, run `mcp-bridge emit ack-pop --path <payload.path> --acked-sha <payload.new_sha>` once per ack. This drains any queued doc.sync entry the hook stashed while the previous sync was in flight. Automatic wiring is deferred; for v1, Claude is the loop.

Examples:

```bash
mcp-bridge emit decision-logged --title "Use flock for counter" --context "..." --decision "..." --consequences "..."
mcp-bridge emit question-asked --question "..." --context "..."
echo "body text" | mcp-bridge emit note-captured --title "..." --body-file -
```

At session start, check `.bridge/errors.log` (if present) and surface any recent entries to the user.

See `references/troubleshooting.md` for install and runtime failure modes.
