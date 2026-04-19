#!/usr/bin/env bash
set -uo pipefail
ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
cd "$ROOT"

pass=0; fail=0
check() {
  local ok=$1; local msg=$2
  if [ "$ok" = "1" ]; then echo "  ✓ $msg"; pass=$((pass+1)); else echo "  ✗ $msg"; fail=$((fail+1)); fi
}

echo "[bridge verify]"
# config
if [ -f .bridge/config.json ]; then
  check 1 "config.json present"
else
  check 0 "config.json MISSING"
fi
# hook scripts
for h in claude-task-create.sh claude-task-update.sh git-post-commit.sh git-pre-push.sh; do
  if [ -x ".bridge/hooks/$h" ]; then check 1 "hook $h executable"; else check 0 "hook $h missing/not-executable"; fi
done
# git hooks
for hook in post-commit pre-push; do
  t=".git/hooks/$hook"
  if [ -x "$t" ] && grep -q "bridge/hooks/git-$hook.sh" "$t"; then
    check 1 "$t wired"
  else
    check 0 "$t not wired"
  fi
done
# settings
if [ -f .claude/settings.json ] && grep -q "claude-task-create.sh" .claude/settings.json; then
  check 1 ".claude/settings.json has TaskCreate hook"
else
  check 0 ".claude/settings.json missing hook entries"
fi
# broker ping
BROKER_URL=$(python3 -c "import json;print(json.load(open('.bridge/config.json'))['broker_url'])" 2>/dev/null || true)
if [ -n "$BROKER_URL" ] && curl -sf --max-time 2 "$BROKER_URL/healthz" >/dev/null; then
  check 1 "broker reachable at $BROKER_URL"
else
  check 0 "broker unreachable at $BROKER_URL"
fi
# rescue any orphaned queued entries
if [ -f .bridge/doc-sync-state.json ]; then
  python3 - <<'PY'
import json
from pathlib import Path
p = Path(".bridge/doc-sync-state.json")
data = json.loads(p.read_text())
orphaned = [k for k, v in data.items() if v.get("queued") and not v.get("in_flight_sha")]
if orphaned:
    print(f"  ! rescue: {len(orphaned)} orphaned queued entries — run `mcp-bridge emit ack-pop --path <p> --acked-sha <s>` for each")
PY
fi
echo "[bridge verify] $pass passed, $fail failed"
exit 0
