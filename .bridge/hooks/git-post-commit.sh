#!/usr/bin/env bash
set -e
# Enumerate changed paths from HEAD; pass them all to the CLI.
# The CLI filters against docs_glob from .bridge/config.json using pathlib
# globstar semantics (Python's PurePath.match, upgraded for **) — the shell
# `case` statement cannot reliably handle `**`, so filtering happens in Python.
cd "$(git rev-parse --show-toplevel)"
CHANGED=$(git diff-tree --no-commit-id --name-only -r HEAD 2>/dev/null || true)
[ -z "$CHANGED" ] && exit 0
ARGS=()
while IFS= read -r f; do
  [ -z "$f" ] && continue
  ARGS+=(--path "$f")
done <<< "$CHANGED"
[ ${#ARGS[@]} -eq 0 ] && exit 0
mcp-bridge emit doc-sync "${ARGS[@]}" >/dev/null 2>&1 || true
exit 0
