#!/usr/bin/env bash
set -euo pipefail

usage() { echo "usage: install.sh <session_id> <broker_url> [docs_glob...]"; exit 2; }

[ $# -ge 2 ] || usage
SESSION_ID="$1"; shift
BROKER_URL="$1"; shift
DOCS_GLOB_ARGS=("$@")
[ ${#DOCS_GLOB_ARGS[@]} -eq 0 ] && DOCS_GLOB_ARGS=("docs/**/*.md" "*.md")

# 1. Cwd must be git repo root
ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
[ -n "$ROOT" ] || { echo "must run from inside a git repository"; exit 1; }
cd "$ROOT"

# 2. Locate skill dir (where this script lives)
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 3. .bridge/config.json
mkdir -p .bridge
if [ -f .bridge/config.json ]; then
  echo ".bridge/config.json exists — refusing to overwrite. Remove or edit manually."
else
  docs_json=$(printf '%s\n' "${DOCS_GLOB_ARGS[@]}" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read().splitlines()))')
  cat > .bridge/config.json <<EOF
{
  "session_id": "$SESSION_ID",
  "broker_url": "$BROKER_URL",
  "target_project": "vault",
  "docs_glob": $docs_json
}
EOF
  echo "wrote .bridge/config.json"
fi

# 4. Copy hook shims
mkdir -p .bridge/hooks
cp "$SKILL_DIR/scripts/hooks/"*.sh .bridge/hooks/
chmod +x .bridge/hooks/*.sh
echo "copied hook shims to .bridge/hooks/"

# 5. Initialize state files
for f in task-counters.json task-map.json doc-sync-state.json; do
  [ -f ".bridge/$f" ] || echo "{}" > ".bridge/$f"
done

# 6. Copy protocol doc
if [ -f "$ROOT/docs/bridge-protocol.md" ]; then
  cp "$ROOT/docs/bridge-protocol.md" .bridge/protocol.md
elif [ -f "$SKILL_DIR/references/protocol.md" ]; then
  cp "$SKILL_DIR/references/protocol.md" .bridge/protocol.md
fi

# 7. Git hooks
for hook in post-commit pre-push; do
  target=".git/hooks/$hook"
  if [ -f "$target" ] && ! grep -q "bridge/hooks/git-$hook.sh" "$target" 2>/dev/null; then
    echo "WARNING: $target exists and does not dispatch to .bridge/hooks/. Skipping. Merge manually:"
    echo "  exec .bridge/hooks/git-$hook.sh \"\$@\""
  else
    cat > "$target" <<EOF
#!/usr/bin/env bash
exec "\$(git rev-parse --show-toplevel)/.bridge/hooks/git-$hook.sh" "\$@"
EOF
    chmod +x "$target"
    echo "installed .git/hooks/$hook"
  fi
done

# 8. Merge Claude Code settings
mkdir -p .claude
python3 "$SKILL_DIR/scripts/_merge_settings.py" .claude/settings.json
echo "merged .claude/settings.json hook entries"

# 9. Verify
bash "$SKILL_DIR/scripts/verify.sh"
