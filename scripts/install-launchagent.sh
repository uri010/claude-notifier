#!/usr/bin/env bash
# Install ClaudeNotifier as a macOS LaunchAgent (auto-start on login).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLIST_SRC="$ROOT/scripts/com.claude.notifier.plist"
PLIST_DST="$HOME/Library/LaunchAgents/com.claude.notifier.plist"
LABEL="com.claude.notifier"
LOG_DIR="$HOME/.claude-notifier"

# Build release binary
echo "Building release binary..."
(cd "$ROOT" && swift build -c release 2>&1 | tail -2)
BIN="$(cd "$ROOT" && swift build -c release --show-bin-path 2>/dev/null)/ClaudeNotifier"
[ -x "$BIN" ] || { echo "Build failed"; exit 1; }
xattr -d com.apple.quarantine "$BIN" 2>/dev/null || true

mkdir -p "$LOG_DIR"

# Write plist with actual binary path
cat > "$PLIST_DST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${BIN}</string>
    </array>
    <key>KeepAlive</key>
    <true/>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${LOG_DIR}/notifier.log</string>
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/notifier.log</string>
    <key>ThrottleInterval</key>
    <integer>30</integer>
</dict>
</plist>
PLIST

# Unload old instance if running, then load fresh
launchctl unload "$PLIST_DST" 2>/dev/null || true
sleep 1
launchctl load "$PLIST_DST"
sleep 2

PORT="${CLAUDE_NOTIFIER_PORT:-47823}"
if curl -s --max-time 5 "http://127.0.0.1:${PORT}/health" | grep -q '"status":"ok"'; then
    echo "ClaudeNotifier running (pid $(launchctl list | awk '/claude\.notifier/{print $1}'), port ${PORT})"
    echo "Log: ${LOG_DIR}/notifier.log"
else
    echo "Failed to start. Check: tail -20 ${LOG_DIR}/notifier.log" >&2
    exit 1
fi
