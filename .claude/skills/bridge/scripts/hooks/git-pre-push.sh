#!/usr/bin/env bash
set -e
cd "$(git rev-parse --show-toplevel)"
cat - | mcp-bridge emit commit-landed >/dev/null 2>&1 || true
exit 0
