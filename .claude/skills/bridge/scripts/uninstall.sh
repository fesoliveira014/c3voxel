#!/usr/bin/env bash
set -euo pipefail
ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
[ -n "$ROOT" ] || { echo "must run inside a git repo"; exit 1; }
cd "$ROOT"

# Remove git hooks we installed (only if they dispatch to .bridge/hooks/)
for hook in post-commit pre-push; do
  target=".git/hooks/$hook"
  if [ -f "$target" ] && grep -q ".bridge/hooks/git-$hook.sh" "$target"; then
    rm -f "$target"
    echo "removed .git/hooks/$hook"
  fi
done

# Remove .bridge/hooks/ copies (state files preserved — user may want to re-install)
rm -rf .bridge/hooks

# Remove our entries from .claude/settings.json
python3 - <<'PY'
import json
from pathlib import Path
p = Path(".claude/settings.json")
if not p.exists():
    raise SystemExit(0)
data = json.loads(p.read_text())
hooks = data.get("hooks", {})
post = hooks.get("PostToolUse", [])
post[:] = [e for e in post if not any(
    h.get("command", "").startswith(".bridge/hooks/claude-")
    for h in e.get("hooks", [])
)]
if not post:
    hooks.pop("PostToolUse", None)
if not hooks:
    data.pop("hooks", None)
p.write_text(json.dumps(data, indent=2))
PY

echo "bridge uninstalled. .bridge/config.json and state files preserved."
