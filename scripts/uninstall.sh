#!/usr/bin/env bash
#
# ClaudeNotifier 제거 스크립트.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/uri010/claude-notifier/main/scripts/uninstall.sh | bash
#
# 소스 빌드로 설치한 경우에도 동작합니다.

set -euo pipefail

INSTALL_DIR="$HOME/.local/share/claude-notifier"
LABEL="com.claude.notifier"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SETTINGS="$HOME/.claude/settings.json"

GREEN='\033[0;32m'; NC='\033[0m'
info() { echo -e "${GREEN}[uninstall]${NC} $*"; }

# ── Stop + remove LaunchAgent ─────────────────────────────────────────────────
if [ -f "$PLIST" ]; then
    launchctl unload "$PLIST" 2>/dev/null && info "LaunchAgent 중지됨" || true
    rm -f "$PLIST"
    info "LaunchAgent plist 제거됨"
fi

# 소스 빌드로 설치한 경우의 LaunchAgent plist도 제거
pkill -f 'ClaudeNotifier' 2>/dev/null && info "실행 중인 ClaudeNotifier 종료" || true

# ── Remove hooks from settings.json ──────────────────────────────────────────
if [ -f "$SETTINGS" ]; then
    cp "$SETTINGS" "$SETTINGS.bak-notifier.$(date +%s)"
    tmp="$(mktemp)"
    jq '
      if .hooks == null then .
      else
        .hooks |= with_entries(
          .value |= map(
            .hooks |= map(select((.command // "") | test("notify-hook\\.sh") | not))
          ) | map(select((.hooks | length) > 0))
        )
        | .hooks |= with_entries(select((.value | length) > 0))
        | if (.hooks | length) == 0 then del(.hooks) else . end
      end
    ' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
    info "Claude Code 훅 제거됨"
fi

# ── Remove install directory ──────────────────────────────────────────────────
if [ -d "$INSTALL_DIR" ]; then
    rm -rf "$INSTALL_DIR"
    info "설치 디렉토리 제거됨: $INSTALL_DIR"
fi

echo ""
echo -e "${GREEN}ClaudeNotifier 제거 완료.${NC} Claude Code를 재시작하면 변경사항이 적용됩니다."
