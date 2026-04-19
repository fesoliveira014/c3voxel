# Bridge Protocol

Operational reference for the cross-session bridge. Every bridge-participating project copies this file to `.bridge/protocol.md` and reads it at runtime.

This is the **how**. For the **why**, see `docs/superpowers/specs/2026-04-17-mcp-bridge-protocol-design.md`.

## Identity

- This project's bridge identity is a **stable project id** (e.g. `c3voxel`, `vault`, `notes`). It is configured per project in `.mcp.json`, via the `X-Bridge-Session` header or a bearer token. Identity is fixed per repo, not per invocation.
- The broker clamps `sender` to the connection identity. **Never populate `sender` client-side.** Any value you pass is ignored or overwritten. If you want a message to appear to come from another project, you cannot — run the session as that project instead.
- `to` is always a single project id. Multi-target sends are explicit duplicate calls.
- The vault is architecturally symmetric with any repo. Its role differs (primary aggregator, human-driven planner), but at the protocol layer it is just another project id.

**Terminology.** "Project" is any bridge participant (has a project id). "Repo" is the conventional shorthand for a code-bearing project (not the vault) — it is the entity that allocates and owns task ids. "Vault" is a single distinguished project that aggregates state. "Peer" means "the other project id relative to this session" (used in state-store keys).

## Kinds

Dot-notation kinds. Append-only: new kinds may be added; existing kinds are never renamed or repurposed. If unsure which kind to use, use `note.captured`. **Never invent kinds.**

| kind | direction | tier | key payload fields | required tags |
| --- | --- | --- | --- | --- |
| `task.proposed` | vault→repo | gated | `type`, `title`, `rationale?`, `links[]` | `type:*` recommended |
| `task.created` | repo→vault | auto-ingest | `id`, `type`, `title`, `status`, `links[]` | `type:*` |
| `task.updated` | repo→vault | auto-ingest | `id`, `changes{}` | `type:*` |
| `task.update.requested` | vault→repo | gated | `id`, `changes{}`, `reason?` | `type:*` |
| `task.completed` | repo→vault | auto-ingest | `id`, `commit_sha?`, `closed_at` | `type:*` |
| `task.proposal.declined` | repo→vault | auto-ingest | `reason`, `in_reply_to` | none |
| `decision.logged` | either | auto-ingest | `title`, `context`, `decision`, `consequences` | none |
| `doc.sync` | either | gated | `path`, `direction`, `base_sha`, `incoming_sha`, `content`, `diff?` | none |
| `doc.sync.ack` | either | auto-ingest | `path`, `new_sha`, `in_reply_to` | none |
| `doc.sync.conflict` | either | auto-ingest | `path`, `local_sha`, `base_sha`, `incoming_sha`, `unresolved_hunks[]`, `file_state` | none |
| `commit.landed` | repo→vault | auto-ingest | `sha`, `branch`, `message`, `task_ids[]` | none |
| `question.asked` | either | auto-ingest | `question`, `context?` | none |
| `question.answered` | either | auto-ingest | `answer`, `sources[]` | none |
| `note.captured` | either | auto-ingest | `title`, `body` | none |

Notes:

- `type:*` is required on id-bearing `task.*` messages (i.e. all `task.*` except `task.proposed` and `task.proposal.declined`). The tag MUST match the `<type>` segment of the task id. Include `type:*` on `task.proposed` as well so repo-side filters work before acceptance.
- Status transitions flow through `task.updated` with `changes: {"status": "..."}`. When a task reaches a terminal state (`done`, `wontfix`, `duplicate`), emit `task.completed` **in addition to** the final `task.updated`. Treat `task.completed` as the authoritative close signal.
- Before using a new kind, document it here (payload schema + intent). Renames are forbidden; deprecate by adding a new kind and leaving the old one unused.

## Tags

Tags are orthogonal to `kind`. All tags are optional except `type:*` on id-bearing `task.*` messages.

Reserved prefixes:

- `area:<subsystem>` — subsystem within the project (e.g. `area:rendering`, `area:build`, `area:docs`).
- `type:<task-type>` — `type:impl`, `type:bug`, `type:todo`, `type:chore`. Required on id-bearing `task.*` messages. Must match the task id's `<type>` segment.
- `src:<origin>` — `src:commit`, `src:manual`, `src:hook`, `src:agent`, `src:vault`. Identifies emitter.
- `p:*` — reserved for future priority. Do not use in v1.
- `status:*` — reserved. Status lives in payload; do not put it in tags.

Unprefixed tags are topical (e.g. `voxel-lod`, `performance`). Ad-hoc, no approval needed.

## Task identity

Task ids are **owned by the accepting repo** — the project that will do the work. Format:

```
<project>/<type>-<n>
```

- `<project>` — project id (same as bridge identity).
- `<type>` — one of `impl`, `bug`, `todo`, `chore`.
- `<n>` — monotonically increasing integer, per-type, per-project.

Repos allocate. A simple counter file (e.g. `.bridge/task-counters.json`) or deriving from git log is acceptable.

**The vault cannot allocate task ids.** If the vault originates a task idea, it emits `task.proposed` (no id). The target repo allocates on acceptance and emits `task.created` with `in_reply_to` pointing back at the proposal.

Commits that touch a task include a trailer:

```
Task: c3voxel/impl-17
```

Multiple trailers permitted. `commit.landed` populates `task_ids[]` from trailers.

## Threading rules

`thread_id` groups related messages. `in_reply_to` points to the specific message id being answered. `thread_id` groups; `in_reply_to` links point-to-point.

| scenario | thread_id | example |
| --- | --- | --- |
| Task lifecycle (accepted task) | `<project>/<type>-<n>` (same as task id) | `c3voxel/impl-17` |
| Task proposal (pre-acceptance) | `q/<ulid>` (proposal thread; contains only the proposal and, if rejected, its `task.proposal.declined`) | `q/01HV9...` |
| Decision | `decision/<slug>` (slug = kebab-case of `title`) | `decision/voxel-lod` |
| Doc sync | `doc/<path>` (path relative to project root) | `doc/docs/render/plan.md` |
| Question thread | `q/<ulid>` (new ulid per question) | `q/01HV9...` |
| Commit heartbeat | none — `commit.landed` is unthreaded. Correlation is via `payload.task_ids[]`, which consumers fan out into the relevant task threads. | — |

**Proposal to task handoff.** See Task lifecycle → Vault-originated proposal flow for the full handoff procedure.

Set `in_reply_to` whenever the message answers another, in particular:

- `question.answered` → the `question.asked` id it answers.
- `task.created` when it is an acceptance → the `task.proposed` id.
- `task.proposal.declined` → the `task.proposed` id.
- `task.updated` / `task.completed` emitted in response to a `task.update.requested` → the request id.
- `doc.sync.ack` / `doc.sync.conflict` → the originating `doc.sync` id.

## Task lifecycle

Single source of truth: **the repo that owns the id.** Vault state is a reflection; vault-originated changes are advisory until the repo confirms.

### Invariants

- A task id exists iff the repo that owns it has ever emitted `task.created` for that id.
- On conflict between vault-local edits and a later authoritative `task.updated` from the repo, **repo wins.** The vault overwrites its own state.
- `in_reply_to` on `task.created` MUST be set when accepting a proposal. It stays null on unsolicited creation (task minted from a commit or CLI).
- `task.update.requested` is vault→repo only. A repo MUST NOT emit it. Doing so would collapse authority.

### Vault-originated proposal flow

1. Vault emits `task.proposed` to repo. `thread_id = q/<ulid>` (proposal thread). Payload has no `id`.
2. Repo Claude receives (gated — logs to `.bridge/inbox.md`, awaits human cue).
3. Human approves → repo allocates `<project>/<type>-<n>` and emits `task.created` on the NEW `thread_id = <project>/<type>-<n>` (the task id itself), with `in_reply_to` = the proposal message id. The proposal thread is not reused. All subsequent `task.*` messages thread under `<project>/<type>-<n>`.
4. Human declines → repo emits `task.proposal.declined` on the proposal `thread_id` (`q/<ulid>`), with `in_reply_to` = proposal. No id allocated. Proposal thread closes.
5. No reply yet = still pending. Vault UI shows the proposal as "awaiting". Not a protocol-level timeout.

### Vault-originated advisory edit flow (existing task)

1. Vault emits `task.update.requested` with `id`, `changes{}`, optional `reason`. `thread_id = <project>/<type>-<n>` (existing task thread). `in_reply_to` optional.
2. Repo Claude receives (gated).
3. Human accepts → repo emits authoritative `task.updated` (or `task.completed` if terminal) in the same thread, `in_reply_to` = the request. Vault mirrors repo's version as canonical.
4. Human declines → repo emits `task.updated` with `changes{}` explicitly reaffirming current state, `in_reply_to` = the request. Reason optionally in `summary`. There is no dedicated decline kind for edits; re-asserting state is the decline signal.

## Consumer contract

Two tiers:

- **auto-ingest** — you may act without a new human prompt, writing files into specific bridge-managed locations.
- **gated** — you MUST log the item to `.bridge/inbox.md` and wait for explicit human approval before writing or emitting any authoritative reply.

| kind | direction | tier | receiver action |
| --- | --- | --- | --- |
| `task.created` | repo→vault (unsolicited) | auto-ingest | Create card at `project/<sender>/todos/<task-id>.md`, id from payload. |
| `task.created` | repo→vault (with `in_reply_to` = `task.proposed`) | auto-ingest | Same path (`project/<sender>/todos/<task-id>.md`), plus update the vault's local record of the proposal thread to "accepted" and cross-link to the new task id. Vault-local bookkeeping only — do NOT emit a synthetic message into the (now-closed) `q/<ulid>` proposal thread. |
| `task.updated` | repo→vault | auto-ingest | Apply `changes{}` to `project/<sender>/todos/<task-id>.md`. Authoritative overwrite of state. |
| `task.completed` | repo→vault | auto-ingest | Move `project/<sender>/todos/<task-id>.md` to done state (e.g. `status: done` frontmatter or `done/` subfolder); stamp `closed_at`, link `commit_sha`. |
| `task.proposed` | vault→repo | gated | Log to `.bridge/inbox.md`. Await human accept/decline. |
| `task.update.requested` | vault→repo | gated | Log with diff vs current state. Human approves before the repo emits an authoritative reply. |
| `task.proposal.declined` | repo→vault | auto-ingest | Mark vault proposal declined; store reason. |
| `decision.logged` | either | auto-ingest | Repo: write ADR to `docs/decisions/<slug>.md`. Vault: write to `project/<sender>/decisions/<slug>.md`. Slug from `thread_id`. |
| `note.captured` | either | auto-ingest | Repo: append to `.bridge/notes/<YYYY-MM>.md`. Vault: append to `project/<sender>/notes/<YYYY-MM>.md`. |
| `question.asked` | either | auto-ingest | Repo: append to `.bridge/questions.md`. Vault: append to `project/<sender>/questions/<thread_id>.md`. Surface to human next session. |
| `question.answered` | either | auto-ingest | Append under matching question thread. If Claude is mid-task and awaiting the answer, inject into context. |
| `commit.landed` | repo→vault | auto-ingest | Update cards under `project/<sender>/todos/` referenced in `task_ids[]`. |
| `doc.sync` | either | gated | Run merge (see Doc sync). Do not write until human approves the merge result. |
| `doc.sync.conflict` | either | auto-ingest | Record conflict state for the path; surface to human. No file writes beyond `.bridge/`. |
| `doc.sync.ack` | either | auto-ingest | Clear in-flight state for the path; update last-known `base_sha`. |
| unknown kind | either | auto-ingest (log only) | Log `summary`, ignore payload. |

### Auto-ingest security envelope

Auto-ingest writes are confined to:

- `.bridge/` subtree of the project (protocol state only — see Vault routing),
- on the vault: the `project/<sender>/` subtree for the sender of the current message (tasks, docs, notes, decisions, questions),
- on repos: the canonical ADR folder (`docs/decisions/`) and the project-relative path named in `doc.sync.payload.path`.

**Auto-ingest NEVER edits source code, configuration, or arbitrary paths.** Those require a gated kind (`doc.sync`) that the human has approved, or an explicit human prompt.

### Inbox

Both sides maintain `.bridge/inbox.md`. Format: one line per pending gated item — message id, kind, sender, summary, age. The consumer writes; the human reads. At session start, always check `.bridge/inbox.md` and treat gated items as requiring explicit user direction.

### Vault routing

On the vault, `.bridge/` holds **only protocol machinery** — nothing semantic that the human would want to browse inside Obsidian:

- `.bridge/protocol.md` — this file
- `.bridge/inbox.md` — gated-item queue
- `.bridge/merge/<path>` — doc-sync conflict scratch
- `.bridge/doc-sync-state.json` — last-agreed base shas
- `.bridge/questions.md` — protocol-level question index (cross-reference; per-project question notes live elsewhere, see below)

Received **content** is routed into a per-sender namespace so Obsidian's graph, search, and backlinks work against ordinary folders:

```
project/
  <sender>/
    todos/      # task.created / task.updated / task.completed
    docs/       # doc.sync content (see below)
    notes/      # note.captured → <YYYY-MM>.md, one per calendar month
    decisions/  # decision.logged → <slug>.md (slug from thread_id)
    questions/  # question.asked / question.answered → <thread_id>.md
```

**Doc sync on the vault.** `doc.sync.payload.path` is project-relative *to the sender's repo*. The vault stores it at `project/<sender>/docs/<payload.path>` — preserving the sender's tree layout under the per-project namespace. Merge scratch stays at `.bridge/merge/<sender>/<payload.path>`. `doc.sync.ack` still carries the hash of the written content; it is independent of where the vault chose to store it.

**On repos**, no routing is applied: tasks, docs, notes, and decisions land at the conventional repo paths (`.bridge/` for protocol state, `docs/decisions/` for ADRs, the path named in `doc.sync.payload.path` for synced files). Repos are single-project and don't namespace by sender.

### Summary and payload contract

- `summary` — REQUIRED on every message. One-line human-readable string. This is what `peek_messages` and inbox UIs display. Convention: ≤ 120 chars.
- `payload` — REQUIRED. JSON object matching the schema for the declared `kind`. Unknown fields are ignored by consumers but preserved.
- `sender` — set by the server. Do not populate client-side.

### Routing expectations

Not enforced by the broker. Conventions:

- **Repo → vault:** `task.created`, `task.updated`, `task.completed`, `task.proposal.declined`, `decision.logged`, `commit.landed`, `doc.sync` (direction `repo→vault`), `note.captured`, `question.asked`, `question.answered`.
- **Vault → repo:** `task.proposed`, `task.update.requested`, `decision.logged`, `note.captured`, `doc.sync` (direction `vault→repo`), `question.asked`, `question.answered`.
- **Repo ↔ repo:** rare. Same rules apply — use `question.*` for interactive, `note.captured` for one-shot. Task lifecycle across two repos follows the same proposal/acceptance flow; whichever repo accepts owns the id.

Ack/conflict messages always go back in the opposite direction of the originating `doc.sync`.

Filter by `to == self` and kind/tags as needed.

## Doc sync

### Payload shape

```json
{
  "path": "docs/render/plan.md",
  "direction": "vault→repo",
  "base_sha": "sha256:…",
  "incoming_sha": "sha256:…",
  "content": "…",
  "diff": "--- a\n+++ b\n@@ …"
}
```

- `content` is always the full new text — self-contained, independent of delivery order.
- `diff` is present when the sender has the base available; receivers prefer the diff for 3-way merge.
- Paths MUST be project-relative. No absolute paths. No `..`.

### Sync state store

Each side keeps `.bridge/doc-sync-state.json`:

```json
{ "<peer>/<path>": { "base_sha": "…", "last_ack_at": "…" } }
```

Represents the last version both sides agreed on. Updated on successful ack emit or receive.

### Receiver flow (gated)

1. Log to `.bridge/inbox.md`. Wait for the human to prompt "apply".
2. Read local file, compute `local_sha`.
3. Dispatch:
   - `local_sha == base_sha`: fast-forward. Write `content`. Emit `doc.sync.ack` with `new_sha = incoming_sha`.
   - `base_sha` unknown (no state entry) and local file absent: treat as first sync. Write `content`, ack.
   - `base_sha` unknown and local file present: force conflict flow.
   - `local_sha ≠ base_sha` and `diff` present: 3-way merge via `git merge-file` (or equivalent) on (local, reconstructed-base, incoming). Clean → write merged, ack. Conflict → conflict flow.
   - `local_sha ≠ base_sha` and no `diff`: read both versions and attempt a semantic merge. Confident → propose, human approves, write, ack. Otherwise → conflict flow.

### Conflict flow

1. Write merged file with `<<<<<<<` markers to scratch path `.bridge/merge/<path>` first.
2. Attempt to resolve each hunk using surrounding context and understanding of both sides' intent.
3. All hunks resolvable with high confidence → write resolved content to the real path, show the human the diff, await confirmation, emit `doc.sync.ack`.
4. Any hunk ambiguous → surface specific hunks to the human with both versions + your recommendation. Human chooses per hunk. Resolved → write, ack.
5. Human opts out or the file is unmergeable → write a conflict-marker file to the real path, emit `doc.sync.conflict` with `file_state: "markers"` and `unresolved_hunks[]`. The human resolves in an editor, commits, and triggers a follow-up `doc.sync` in the other direction.

### After ack

Both sides update `doc-sync-state.json[<peer>/<path>].base_sha = incoming_sha`. That content is the new shared base.

### Concurrency rules

- **Receiver side:** if a second `doc.sync` for the same path arrives before the first is acked, reject it with `doc.sync.conflict`, `file_state: "rejected"`, `reason: "sync in flight"`. Sender retries after observing the ack.
- **Sender side:** if your local file changes again while awaiting an ack, do NOT emit a second `doc.sync` immediately. Queue the new content locally and emit after the ack lands, using the newly-acked sha as the next `base_sha`. This keeps the sync-state chain linear.

## Failure modes

- **Unknown kind received.** Log `summary`, ignore payload. Do not crash. (Append-only means older consumers will see new kinds.)
- **Missing required tag** (e.g. `task.created` without `type:*`). Reject the message: log and drop. Emitters must include required tags; rejection surfaces emitter bugs early.
- **Duplicate task id.** Last-write-wins on the vault side. The repo is authoritative for identity; duplicates indicate a repo-side bug (counter regression).
- **Unresolved `in_reply_to`.** Message is still valid. Show it as a top-level thread entry with a dangling reply marker.
- **Bridge down.** Emitters MUST NOT block work on send failure. A hook that cannot reach the bridge should log locally and continue. No retry queue in v1.
- **`task.update.requested` for an unknown id.** Log, drop. Optionally emit `question.asked` asking the sender to clarify. Do not auto-create.
- **`task.updated` / `task.completed` for an id the vault has no card for.** Vault auto-creates a stub card from the payload (title inferred from `summary` if not in `changes{}`) and applies the update. Repo is authoritative; a missing card is a vault-side gap, not a protocol error.
- **`doc.sync` for an untracked or out-of-tree path.** Reject with `doc.sync.conflict`, `file_state: "rejected"`, `reason: "path not allowed"`.

## Example messages

**Task proposed from vault to repo:**

```json
{
  "to": "c3voxel",
  "kind": "task.proposed",
  "thread_id": "q/01HV9PROPOSAL01",
  "tags": ["area:rendering", "type:impl", "src:vault", "voxel-lod"],
  "summary": "Proposing: add LOD selection pass to voxel renderer",
  "payload": {
    "type": "impl",
    "title": "Add LOD selection pass to voxel renderer",
    "rationale": "Decision c3voxel/decision/voxel-lod selected screen-space thresholds; this is the implementation arm.",
    "links": ["docs/render/lod.md"]
  }
}
```

**Repo accepts and allocates id** (note: `thread_id` is the NEW task id, not the proposal's `q/...`; correlation is via `in_reply_to`):

```json
{
  "to": "vault",
  "kind": "task.created",
  "thread_id": "c3voxel/impl-17",
  "in_reply_to": 1287,
  "tags": ["area:rendering", "type:impl", "src:manual", "voxel-lod"],
  "summary": "Accepted q/01HV9PROPOSAL01 as c3voxel/impl-17",
  "payload": {
    "id": "c3voxel/impl-17",
    "type": "impl",
    "title": "Add LOD selection pass to voxel renderer",
    "status": "open",
    "links": ["docs/render/lod.md"]
  }
}
```

**Vault requests a status change:**

```json
{
  "to": "c3voxel",
  "kind": "task.update.requested",
  "thread_id": "c3voxel/impl-17",
  "tags": ["area:rendering", "type:impl", "src:vault"],
  "summary": "Request: move c3voxel/impl-17 to in_progress (draft branch up)",
  "payload": {
    "id": "c3voxel/impl-17",
    "changes": { "status": "in_progress" },
    "reason": "draft branch pushed; card edited in vault"
  }
}
```

**Repo confirms authoritatively:**

```json
{
  "to": "vault",
  "kind": "task.updated",
  "thread_id": "c3voxel/impl-17",
  "in_reply_to": 1340,
  "tags": ["area:rendering", "type:impl", "src:manual"],
  "summary": "c3voxel/impl-17 → in_progress",
  "payload": {
    "id": "c3voxel/impl-17",
    "changes": { "status": "in_progress" }
  }
}
```

**Doc sync from vault to repo:**

```json
{
  "to": "c3voxel",
  "kind": "doc.sync",
  "thread_id": "doc/docs/render/plan.md",
  "tags": ["area:rendering", "src:vault"],
  "summary": "doc.sync vault→repo: docs/render/plan.md (+12/-3)",
  "payload": {
    "path": "docs/render/plan.md",
    "direction": "vault→repo",
    "base_sha": "sha256:abc…",
    "incoming_sha": "sha256:def…",
    "content": "…full new content…",
    "diff": "--- a/docs/render/plan.md\n+++ b/docs/render/plan.md\n@@ …"
  }
}
```

**Commit that closes a task:**

```json
{
  "to": "vault",
  "kind": "commit.landed",
  "tags": ["area:rendering", "src:hook"],
  "summary": "ab12cd3 on main — closes c3voxel/impl-17",
  "payload": {
    "sha": "ab12cd3...",
    "branch": "main",
    "message": "Implement LOD selection pass\n\nTask: c3voxel/impl-17",
    "task_ids": ["c3voxel/impl-17"]
  }
}
```

**Cross-project question:**

```json
{
  "to": "vault",
  "kind": "question.asked",
  "thread_id": "q/01HV9ABCDEF",
  "tags": ["area:rendering", "voxel-lod"],
  "summary": "What did we decide about screen-space LOD thresholds?",
  "payload": {
    "question": "What did we decide about screen-space LOD thresholds?",
    "context": "Implementing c3voxel/impl-17; need the threshold from the ADR."
  }
}
```

## CLAUDE.md fence

Every bridge-participating project pastes the canonical snippet between `<!-- bridge:begin -->` / `<!-- bridge:end -->` markers in its CLAUDE.md. See the snippet file shipped alongside this protocol for the exact text and substitutions (`<PROJECT_ID>`, `<VERSION>`). Auto-ingest and bootstrap tooling will only edit content inside that fence.

## Version

`v1`
