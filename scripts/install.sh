#!/usr/bin/env bash
#
# ClaudeNotifier one-line installer.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/uri010/claude-notifier/main/scripts/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/uri010/claude-notifier/main/scripts/install.sh | bash -s -- --all
#
# --all  게이트 대상을 모든 도구("*")로 확장

set -euo pipefail

REPO="uri010/claude-notifier"
INSTALL_DIR="$HOME/.local/share/claude-notifier"
BIN_DIR="$INSTALL_DIR/bin"
SCRIPTS_DIR="$INSTALL_DIR/scripts"
LOG_DIR="$HOME/.claude-notifier"
LABEL="com.claude.notifier"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
PORT="${CLAUDE_NOTIFIER_PORT:-47823}"
MATCHER="Bash|Write|Edit|MultiEdit|NotebookEdit|AskUserQuestion"
[ "${1:-}" = "--all" ] && MATCHER="*"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[install]${NC} $*"; }
warn()  { echo -e "${YELLOW}[install]${NC} $*"; }
error() { echo -e "${RED}[install] Error:${NC} $*" >&2; exit 1; }

# ── Prerequisites ──────────────────────────────────────────────────────────────
[[ "$(uname -s)" == "Darwin" ]] || error "macOS only."

OS_VER="$(sw_vers -productVersion)"
MAJOR="${OS_VER%%.*}"
(( MAJOR >= 13 )) || error "macOS 13 Ventura 이상 필요 (현재 $OS_VER)"

for cmd in curl jq; do
    command -v "$cmd" >/dev/null 2>&1 || error "$cmd 없음. 설치: brew install $cmd"
done

# ── Fetch latest release ───────────────────────────────────────────────────────
info "최신 릴리스 확인 중..."
API_JSON="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest")"
LATEST_TAG="$(echo "$API_JSON" | jq -r '.tag_name // empty')"
[[ -n "$LATEST_TAG" ]] || error "GitHub 릴리스를 찾을 수 없습니다. https://github.com/$REPO/releases 확인"
info "버전: $LATEST_TAG"

# ── Download binary ────────────────────────────────────────────────────────────
mkdir -p "$BIN_DIR" "$SCRIPTS_DIR" "$LOG_DIR"

BIN_URL="https://github.com/$REPO/releases/download/$LATEST_TAG/ClaudeNotifier"
info "바이너리 다운로드 중... ($BIN_URL)"
curl -fsSL --progress-bar "$BIN_URL" -o "$BIN_DIR/ClaudeNotifier"
chmod +x "$BIN_DIR/ClaudeNotifier"
xattr -d com.apple.quarantine "$BIN_DIR/ClaudeNotifier" 2>/dev/null || true

# ── Download hook script ───────────────────────────────────────────────────────
HOOK_URL="https://raw.githubusercontent.com/$REPO/main/scripts/notify-hook.sh"
info "훅 스크립트 다운로드 중..."
curl -fsSL "$HOOK_URL" -o "$SCRIPTS_DIR/notify-hook.sh"
chmod +x "$SCRIPTS_DIR/notify-hook.sh"

# ── LaunchAgent ────────────────────────────────────────────────────────────────
info "LaunchAgent 설치 중..."
launchctl unload "$PLIST" 2>/dev/null || true

cat > "$PLIST" << PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${BIN_DIR}/ClaudeNotifier</string>
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
PLIST_EOF

launchctl load "$PLIST"
sleep 2

if curl -s --max-time 5 "http://127.0.0.1:${PORT}/health" | grep -q '"status":"ok"'; then
    info "앱 실행 중 (port $PORT)"
else
    warn "앱 시작 실패. 로그 확인: tail -20 $LOG_DIR/notifier.log"
fi

# ── Register hooks ─────────────────────────────────────────────────────────────
info "Claude Code 훅 등록 중 (matcher: $MATCHER)..."
SETTINGS="$HOME/.claude/settings.json"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
cp "$SETTINGS" "$SETTINGS.bak-notifier.$(date +%s)"

HOOK="\$HOME/.local/share/claude-notifier/scripts/notify-hook.sh"
PRETOOLUSE_HOOK='[{"matcher":"'"$MATCHER"'","hooks":[{"type":"command","command":"'"$HOOK"' pretooluse"}]}]'
STOP_HOOK='[{"hooks":[{"type":"command","command":"'"$HOOK"' stop"}]}]'

tmp="$(mktemp)"
jq \
  --argjson ptu "$PRETOOLUSE_HOOK" \
  --argjson stp "$STOP_HOOK" '
  def drop_notifier: map(select(.hooks[].command | test("notify-hook\\.sh") | not));
  .hooks.PreToolUse = ((.hooks.PreToolUse // []) | drop_notifier) + $ptu |
  .hooks.Stop       = ((.hooks.Stop       // []) | drop_notifier) + $stp |
  del(.hooks.Notification)
' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"

# ── Done ───────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}ClaudeNotifier $LATEST_TAG 설치 완료!${NC}"
echo ""
echo "  바이너리: $BIN_DIR/ClaudeNotifier"
echo "  훅 스크립트: $SCRIPTS_DIR/notify-hook.sh"
echo "  로그: $LOG_DIR/notifier.log"
echo ""
echo "Claude Code 세션을 재시작하면 훅이 활성화됩니다."
echo ""
echo "업데이트: 동일한 curl 명령 재실행"
echo "제거:     curl -fsSL https://raw.githubusercontent.com/$REPO/main/scripts/uninstall.sh | bash"
