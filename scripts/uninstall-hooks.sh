#!/usr/bin/env bash
#
# Remove the ClaudeNotifier hooks from ~/.claude/settings.json.
# Only deletes hook entries whose command points at notify-hook.sh; leaves any
# other hooks intact.
#
set -euo pipefail

SETTINGS="$HOME/.claude/settings.json"
[ -f "$SETTINGS" ] || { echo "no settings.json"; exit 0; }
cp "$SETTINGS" "$SETTINGS.bak-notifier.$(date +%s)"

tmp="$(mktemp)"
jq '
  if .hooks == null then .
  else
    .hooks |= with_entries(
      .value |= map(
        .hooks |= map(select((.command // "") | test("notify-hook.sh") | not))
      ) | map(select((.hooks | length) > 0))
    )
    | .hooks |= with_entries(select((.value | length) > 0))
    | if (.hooks | length) == 0 then del(.hooks) else . end
  end
' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"

echo "Removed notifier hooks from $SETTINGS"
echo "Restart Claude Code sessions for the change to take effect."
