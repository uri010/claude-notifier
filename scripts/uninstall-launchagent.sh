#!/usr/bin/env bash
# Remove ClaudeNotifier LaunchAgent (stop auto-start).
set -euo pipefail

PLIST="$HOME/Library/LaunchAgents/com.claude.notifier.plist"

launchctl unload "$PLIST" 2>/dev/null && echo "Stopped com.claude.notifier" || true
rm -f "$PLIST" && echo "Removed $PLIST"
echo "ClaudeNotifier will no longer start on login."
