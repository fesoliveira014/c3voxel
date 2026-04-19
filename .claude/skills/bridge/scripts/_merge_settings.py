#!/usr/bin/env python3
"""Idempotent merge of bridge hook entries into .claude/settings.json."""
import json
import sys
from pathlib import Path

ENTRIES = [
    {"matcher": "TaskCreate", "hooks": [{"type": "command", "command": ".bridge/hooks/claude-task-create.sh"}]},
    {"matcher": "TaskUpdate", "hooks": [{"type": "command", "command": ".bridge/hooks/claude-task-update.sh"}]},
]

def main(path_str: str) -> int:
    p = Path(path_str)
    data = json.loads(p.read_text()) if p.exists() else {}
    hooks = data.setdefault("hooks", {})
    post = hooks.setdefault("PostToolUse", [])
    for entry in ENTRIES:
        if not any(e.get("matcher") == entry["matcher"] for e in post):
            post.append(entry)
    p.write_text(json.dumps(data, indent=2))
    return 0

if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
