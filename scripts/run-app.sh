#!/usr/bin/env bash
#
# Build (if needed) and launch the ClaudeNotifier app in the background.
# Re-running restarts a fresh instance.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

swift build -c release >/dev/null 2>&1 || swift build >/dev/null
BIN="$(swift build -c release --show-bin-path 2>/dev/null)/ClaudeNotifier"
[ -x "$BIN" ] || BIN="$(swift build --show-bin-path)/ClaudeNotifier"

pkill -f 'ClaudeNotifier' 2>/dev/null || true
sleep 1
nohup "$BIN" >/tmp/claude-notifier.log 2>&1 &
sleep 2

PORT="${CLAUDE_NOTIFIER_PORT:-47823}"
if curl -s "http://127.0.0.1:${PORT}/health" | grep -q '"status":"ok"'; then
    echo "ClaudeNotifier running on port ${PORT} (pid $(pgrep -f ClaudeNotifier | head -1))"
else
    echo "ClaudeNotifier failed to start; see /tmp/claude-notifier.log" >&2
    exit 1
fi
