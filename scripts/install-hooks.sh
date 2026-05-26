#!/usr/bin/env bash
#
# Install the ClaudeNotifier hooks into ~/.claude/settings.json.
# Idempotent: re-running overwrites the notifier hook entries only.
#
# Usage:
#   install-hooks.sh             # scoped matcher (Bash|Write|Edit|MultiEdit|NotebookEdit)
#   install-hooks.sh --all       # match every tool ("*") — gates ALL tool calls
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/notify-hook.sh"
SETTINGS="$HOME/.claude/settings.json"

MATCHER="Bash|Write|Edit|MultiEdit|NotebookEdit"
[ "${1:-}" = "--all" ] && MATCHER="*"

[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
cp "$SETTINGS" "$SETTINGS.bak-notifier.$(date +%s)"

PRETOOLUSE_HOOK='[{"matcher":"'"$MATCHER"'","hooks":[{"type":"command","command":"'"$HOOK"' pretooluse"}]}]'
STOP_HOOK='[{"hooks":[{"type":"command","command":"'"$HOOK"' stop"}]}]'

tmp="$(mktemp "$(dirname "$SETTINGS")/settings.XXXXXX.json")"
jq \
  --argjson ptu "$PRETOOLUSE_HOOK" \
  --argjson stp "$STOP_HOOK" '
  # Remove any previous notifier entries (identified by notify-hook.sh in the command)
  def drop_notifier: map(select(.hooks[].command | test("notify-hook\\.sh") | not));
  .hooks.PreToolUse = ((.hooks.PreToolUse // []) | drop_notifier) + $ptu |
  .hooks.Stop       = ((.hooks.Stop       // []) | drop_notifier) + $stp |
  del(.hooks.Notification)
' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"

echo "Installed notifier hooks (matcher: $MATCHER) into $SETTINGS"
echo "Restart Claude Code sessions to pick up the new hooks."
