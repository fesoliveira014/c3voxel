# Bridge troubleshooting

## Install

- **"must run from inside a git repository"** — `cd` into the repo root first.
- **".bridge/config.json exists — refusing to overwrite"** — intentional. Delete or edit by hand.
- **"WARNING: .git/hooks/post-commit exists and does not dispatch"** — merge manually: add `exec "$(git rev-parse --show-toplevel)/.bridge/hooks/git-post-commit.sh" "$@"` to your existing hook.

## Runtime

- **Hook emissions appearing in `.bridge/errors.log` as "broker unreachable"** — start the broker: `mcp-bridge run --bind 127.0.0.1 --port 7891` or check its daemon status with `mcp-bridge status`.
- **`.bridge/errors.log` full of 422 errors** — payload schema mismatch. Likely a protocol upgrade happened but the repo's copy wasn't refreshed. Re-copy `docs/bridge-protocol.md` → `.bridge/protocol.md`, and update `mcp-bridge` if behind.
- **TaskCreate does not produce a bridge emission** — check `.claude/settings.json` for the `PostToolUse.TaskCreate` entry. Run `bash bridge/scripts/verify.sh`.
- **`doc.sync` never sends** — the file probably didn't match `docs_glob`. Check `.bridge/config.json["docs_glob"]`.
- **Orphaned queued entries in `doc-sync-state.json`** — run `verify.sh`; it prints rescue commands. The fix is one `mcp-bridge emit ack-pop --path <p> --acked-sha <s>` per entry.
