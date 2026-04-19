#!/usr/bin/env bash
set -e
cat - | mcp-bridge emit task-created >/dev/null 2>&1 || true
exit 0
