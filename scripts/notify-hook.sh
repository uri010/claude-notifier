#!/usr/bin/env bash
#
# Claude Code notification hook dispatcher.
#
# Modes:
#   pretooluse  – smart-gate: bypass check → session cache → danger filter → banner
#   stop        – fire-and-forget completion banner via /notify (no long-poll)
#
# Permission rules (bypass OFF only):
#   Read tool          – banner only if file path is OUTSIDE cwd
#   Write/Edit/*Edit   – always banner
#   Bash               – banner only for delete commands (rm, rmdir, unlink, shred)
#   Other tools        – auto-allow, no banner
#
# Session cache:  /tmp/claude-notifier-allowed-<session>
#   Written when user clicks "Allow Session"; checked at next invocation.

set -uo pipefail

HOOK_TYPE="${1:-stop}"
PORT="${CLAUDE_NOTIFIER_PORT:-47823}"
BASE="http://127.0.0.1:${PORT}"
PERMISSION_WAIT="${CLAUDE_NOTIFIER_WAIT:-45}"
CURL="curl -s --max-time"
SETTINGS_FILE="$HOME/.claude/settings.json"

log() { echo "[notify-hook] $*" >&2; }

# ── Read stdin (cap at 1 MB to avoid hangs on huge payloads) ──────────────────
INPUT="$(head -c 1048576)"

field() { printf '%s' "$INPUT" | jq -r "$1 // empty" 2>/dev/null; }

SESSION_ID="$(field '.session_id')"
CWD="$(field '.cwd')"
[ -z "$CWD" ] && CWD="$(pwd)"
FOLDER="$(basename "$CWD")"

TMUX_SESSION="" TMUX_TARGET=""
if command -v tmux >/dev/null 2>&1 && [ -n "${TMUX:-}" ]; then
    TMUX_SESSION="$(tmux display-message -p '#S' 2>/dev/null || true)"
    TMUX_TARGET="$(tmux display-message -p '#S:#I.#P' 2>/dev/null || true)"
fi

# TTY of the current terminal — walk process tree upward until we find a real TTY.
# Claude Code runs hooks in a piped subprocess with no controlling terminal (tty=??),
# but a parent process (the bash shell in Terminal.app) has the real TTY.
TERMINAL_TTY=""
_tp="$$"
for _ti in 1 2 3 4 5 6 7 8 9 10; do
    _tt="$(ps -p "$_tp" -o tty= 2>/dev/null | tr -d ' ')"
    if [ -n "$_tt" ] && [ "$_tt" != "??" ]; then
        TERMINAL_TTY="$_tt"; break
    fi
    _tpp="$(ps -p "$_tp" -o ppid= 2>/dev/null | tr -d ' ' || true)"
    if [ -z "$_tpp" ] || [ "$_tpp" = "0" ] || [ "$_tpp" = "1" ] || [ "$_tpp" = "$_tp" ]; then break; fi
    _tp="$_tpp"
done
unset _tp _tpp _tt _ti

CONTEXT="session: ${TMUX_SESSION:-${SESSION_ID:-local}} | ${FOLDER}"

# Session cache: one allowed tool name per line
# Stored under ~/.claude-notifier/sessions/ (0700) to prevent /tmp poisoning.
SESSION_KEY="${TMUX_SESSION:-${SESSION_ID:-global}}"
SESSION_DIR="$HOME/.claude-notifier/sessions"
SESSION_CACHE="${SESSION_DIR}/allowed-${SESSION_KEY//[^a-zA-Z0-9_-]/_}"
[ -d "$SESSION_DIR" ] || mkdir -m 0700 -p "$SESSION_DIR" 2>/dev/null

# ── Helpers ───────────────────────────────────────────────────────────────────

# Returns 0 if the session cache file is safe to trust:
# must be owned by the current user and have no group/other read bits (0600).
_cache_is_safe() {
    local f="$1"
    [ -f "$f" ] || return 1
    local owner perm
    owner="$(stat -f '%u' "$f" 2>/dev/null)"
    perm="$(stat -f '%Lp' "$f" 2>/dev/null)"
    [ "$owner" = "$(id -u)" ] || return 1
    [ "$perm" = "600" ] && return 0
    return 1
}

# Returns 0 if the bash command contains a destructive operation.
# Covers pipes, subshells ($(...)), absolute paths, sudo, and quoted names.
_is_destructive_cmd() {
    local cmd="$1"
    # rm/rmdir/shred/unlink — at any command boundary, with optional path/sudo/quotes
    printf '%s' "$cmd" | grep -qE \
        '(^|[|;&`]|\$\()[[:space:]]*(sudo[[:space:]]+)?([^[:space:]|;&>"'"'"'`]*/)?'"'"'?"?(rm|rmdir|shred|unlink)[[:space:]]' \
    && return 0
    # dd/mkfs/fdisk — at any command boundary
    printf '%s' "$cmd" | grep -qE \
        '(^|[|;&`]|\$\()[[:space:]]*(sudo[[:space:]]+)?([^[:space:]|;&>"'"'"'`]*/)?'"'"'?"?(dd[[:space:]]|mkfs|fdisk)\b' \
    && return 0
    # diskutil erase, find -delete, truncate
    printf '%s' "$cmd" | grep -qE \
        'diskutil[[:space:]]+erase|find\b.*[[:space:]]-delete([[:space:]]|$)|truncate\b' \
    && return 0
    return 1
}

# Returns 0 (true) when the user is watching the SPECIFIC tab/session where
# this Claude Code instance is running. If the user is in a different terminal
# tab or a different tmux session, returns 1 (show banner).
# osascript failure → returns 1 (show banner by default).
is_terminal_focused() {
    local frontmost
    frontmost="$(osascript -e \
        'tell application "System Events" to return name of first application process whose frontmost is true' \
        2>/dev/null)" || return 1

    local frontmost_tty=""
    case "$frontmost" in
        Terminal|터미널)
            frontmost_tty="$(osascript -e \
                'tell application "Terminal" to return tty of selected tab of front window' \
                2>/dev/null)" ;;
        iTerm2|iTerm)
            frontmost_tty="$(osascript -e \
                'tell application "iTerm2" to return tty of current session of current window' \
                2>/dev/null)" ;;
        Alacritty|Kitty|WezTerm|Hyper)
            # Single-window terminals: if frontmost, user is watching this process.
            return 0 ;;
        *) return 1 ;;
    esac

    [ -z "$frontmost_tty" ] && return 1
    local ft="${frontmost_tty#/dev/}"

    if [ -n "$TMUX_SESSION" ]; then
        # tmux mode: the visible tab must be a client attached to our session AND
        # must currently be viewing the same window+pane where this hook is running.
        # Without the window check, any pane in the session would suppress banners
        # from every other pane in the same session.
        local tmux_path=""
        for _p in /opt/homebrew/bin/tmux /usr/local/bin/tmux /usr/bin/tmux; do
            [ -x "$_p" ] && tmux_path="$_p" && break
        done
        [ -z "$tmux_path" ] && return 0
        # Parse our own window and pane index from TMUX_TARGET (e.g. "SON:4.0").
        local our_win our_pane
        our_win="${TMUX_TARGET#*:}"; our_win="${our_win%%.*}"   # "4"
        our_pane="${TMUX_TARGET##*.}"                           # "0"
        while IFS= read -r client; do
            if [ "${client#/dev/}" = "$ft" ]; then
                # TTY matches — now check which window+pane this client is viewing.
                local cli_win cli_pane
                cli_win="$(  "$tmux_path" display-message -c "$client" -p '#I' 2>/dev/null || true)"
                cli_pane="$( "$tmux_path" display-message -c "$client" -p '#P' 2>/dev/null || true)"
                [ "$cli_win" = "$our_win" ] && [ "$cli_pane" = "$our_pane" ] && return 0
            fi
        done < <("$tmux_path" list-clients -t "$TMUX_SESSION" -F "#{client_name}" 2>/dev/null)
        return 1
    else
        # Non-tmux: the visible tab must be our terminal.
        [ -n "$TERMINAL_TTY" ] || return 1
        [ "${TERMINAL_TTY#/dev/}" = "$ft" ] && return 0
        return 1
    fi
}

build_event() {
    local kind="$1" title="$2" summary="$3" err="${4:-}" tool="${5:-}"
    jq -n \
        --arg kind    "$kind"    \
        --arg title   "$title"   \
        --arg summary "$summary" \
        --arg context "$CONTEXT" \
        --arg error   "$err"     \
        --arg session "$TMUX_SESSION" \
        --arg target  "$TMUX_TARGET"  \
        --arg cwd     "$CWD"     \
        --arg tool    "$tool"    \
        --arg tty     "$TERMINAL_TTY" \
        '{kind:$kind,title:$title,summary:$summary,context:$context,
          tmuxSession:$session,tmuxTarget:$target,cwd:$cwd}
         + (if $error == "" then {} else {error:$error} end)
         + (if $tool  == "" then {} else {tool:$tool}   end)
         + (if $tty   == "" then {} else {tty:$tty}     end)'
}

post_event()  { $CURL 3 -X POST "${BASE}/event"  -H 'Content-Type: application/json' -d "$1" 2>/dev/null; }
post_notify() { $CURL 3 -X POST "${BASE}/notify" -H 'Content-Type: application/json' -d "$1" 2>/dev/null; }

# Returns true (0) if path is outside CWD, false (1) if inside.

# ── bypass detection: walk process tree for --dangerouslySkipPermissions ──────
BYPASS_ON="false"
_p="$$"
for _i in 1 2 3 4 5 6 7 8 9 10; do
    _a="$(ps -p "$_p" -o args= 2>/dev/null || true)"
    if echo "$_a" | grep -qE 'dangerously.skip.permissions'; then
        BYPASS_ON="true"; break
    fi
    _pp="$(ps -p "$_p" -o ppid= 2>/dev/null | tr -d ' ' || true)"
    if [ -z "$_pp" ] || [ "$_pp" = "0" ] || [ "$_pp" = "1" ] || [ "$_pp" = "$_p" ]; then break; fi
    _p="$_pp"
done
unset _p _pp _a _i

# ═════════════════════════════════════════════════════════════════════════════
case "$HOOK_TYPE" in

# ── PreToolUse ────────────────────────────────────────────────────────────────
  pretooluse)
    TOOL_NAME="$(field '.tool_name')"

    # 0. AskUserQuestion: user must respond in terminal — show notification banner only,
    #    never output a permissionDecision (Claude Code must display its own UI).
    #    Input schema: tool_input.questions[0].question  (questions array, not single field)
    if [ "$TOOL_NAME" = "AskUserQuestion" ]; then
        if ! is_terminal_focused; then
            Q="$(printf '%s' "$INPUT" | jq -r '
                .tool_input.questions[0].question //
                .tool_input.question //
                empty' 2>/dev/null | head -c 200)"
            if [ -n "$Q" ]; then
                BODY="$(build_event question "Claude 질문" "$Q" "" "AskUserQuestion")"
                post_notify "$BODY" >/dev/null 2>&1
            fi
        fi
        exit 0
    fi

    # 1. Bypass mode → explicit allow so Claude Code skips its own prompt too
    if [ "$BYPASS_ON" = "true" ]; then
        jq -n '{hookSpecificOutput:{hookEventName:"PreToolUse",
          permissionDecision:"allow",
          permissionDecisionReason:"dangerouslySkipPermissions active"}}'
        exit 0
    fi

    # 2. Session cache → explicit allow so Claude Code skips its own prompt too.
    #    Exception: destructive Bash commands always require confirmation even when
    #    Bash is session-cached — "allow session" for ls must not silently allow rm.
    if _cache_is_safe "$SESSION_CACHE" && grep -qxF "$TOOL_NAME" "$SESSION_CACHE" 2>/dev/null; then
        _is_destructive=false
        if [ "$TOOL_NAME" = "Bash" ]; then
            _cmd="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null)"
            if _is_destructive_cmd "$_cmd"; then
                _is_destructive=true
                log "session-cache bypass: destructive bash command — $(printf '%s' "$_cmd" | head -c 80)"
            fi
        fi
        if [ "$_is_destructive" = "false" ]; then
            log "session-cached allow for $TOOL_NAME"
            jq -n '{hookSpecificOutput:{hookEventName:"PreToolUse",
              permissionDecision:"allow",
              permissionDecisionReason:"Session-cached allow"}}'
            exit 0
        fi
        unset _cmd _is_destructive
    fi

    # 3. Terminal focused → exit 0 without JSON so Claude Code shows its own prompt
    #    (user is watching the terminal, so the native UI is appropriate)
    if is_terminal_focused; then
        log "terminal focused, skipping banner for $TOOL_NAME"
        exit 0
    fi

    # 4. Build summary ─────────────────────────────────────────────────────────
    TOOL_SUMMARY="$(printf '%s' "$INPUT" | jq -r '
        .tool_input as $i |
        if $i.command   then $i.command
        elif $i.file_path then $i.file_path
        elif $i.url     then $i.url
        else ($i | tojson) end' 2>/dev/null | head -c 300)"
    [ -z "$TOOL_SUMMARY" ] && TOOL_SUMMARY="(내용 없음)"

    TITLE="권한 요청: ${TOOL_NAME}"
    BODY="$(build_event permission "$TITLE" "$TOOL_SUMMARY" "" "$TOOL_NAME")"

    # 5. Post event and long-poll ──────────────────────────────────────────────
    RESP="$(post_event "$BODY")"
    ID="$(printf '%s' "$RESP" | jq -r '.id // empty' 2>/dev/null)"

    if [ -z "$ID" ]; then
        log "app unreachable, failing open"
        exit 0
    fi
    log "event id=$ID tool=$TOOL_NAME waiting <= ${PERMISSION_WAIT}s"

    DEADLINE=$(( $(date +%s) + PERMISSION_WAIT ))
    DECISION="timeout"
    while :; do
        REMAIN=$(( DEADLINE - $(date +%s) ))
        [ "$REMAIN" -le 0 ] && break
        POLL="$REMAIN"; [ "$POLL" -gt 10 ] && POLL=10
        PR="$($CURL $(( POLL + 2 )) "${BASE}/response/${ID}?timeout=${POLL}" 2>/dev/null)"
        D="$(printf '%s' "$PR" | jq -r '.decision // "pending"' 2>/dev/null)"
        if [ "$D" != "pending" ] && [ -n "$D" ]; then DECISION="$D"; break; fi
        if [ -z "$PR" ]; then log "lost contact, failing open"; exit 0; fi
    done
    log "decision=$DECISION"

    case "$DECISION" in
      allow)
        jq -n '{hookSpecificOutput:{hookEventName:"PreToolUse",
          permissionDecision:"allow",
          permissionDecisionReason:"Approved via notifier banner"}}'
        ;;
      allowSession)
        # Write to session cache (0600) so this tool is auto-allowed going forward.
        # Create file with correct permissions atomically to avoid a brief 644 window.
        [ -f "$SESSION_CACHE" ] || install -m 0600 /dev/null "$SESSION_CACHE" 2>/dev/null
        printf '%s\n' "$TOOL_NAME" >> "$SESSION_CACHE"
        # Do NOT return updatedPermissions to Claude Code: that undocumented field caused
        # Claude Code to add its own session rule, bypassing this hook on future calls
        # and breaking the session-cache auto-allow path (no banner + no auto-allow).
        jq -n '{hookSpecificOutput:{hookEventName:"PreToolUse",
          permissionDecision:"allow",
          permissionDecisionReason:"Allowed for session via notifier banner"}}'
        ;;
      deny)
        jq -n '{hookSpecificOutput:{hookEventName:"PreToolUse",
          permissionDecision:"deny",
          permissionDecisionReason:"Denied via notifier banner"}}'
        ;;
      focus|dismiss)
        # User clicked banner body / dismiss → banner closed, terminal focused.
        # Pass control back to Claude Code's own permission UI (no permissionDecision output).
        log "decision=$DECISION — deferring to Claude Code terminal UI"
        exit 0
        ;;
      *)
        log "no explicit decision ($DECISION), failing open"
        exit 0
        ;;
    esac
    ;;

# ── Stop (task complete) ──────────────────────────────────────────────────────
  stop)
    if is_terminal_focused; then
        log "terminal focused, skipping stop banner"
        exit 0
    fi
    MSG="$(field '.message' | head -c 200)"
    [ -z "$MSG" ] && MSG="프롬프트 처리가 완료되었습니다."
    BODY="$(build_event stop "작업 완료" "$MSG" "" "")"
    post_notify "$BODY" >/dev/null 2>&1
    exit 0
    ;;

# ── Notification (Claude question / status) ───────────────────────────────────
  notification)
    if is_terminal_focused; then
        log "terminal focused, skipping notification banner"
        exit 0
    fi
    MSG="$(field '.message' | head -c 300)"
    [ -z "$MSG" ] && exit 0   # 빈 메시지는 무시
    log "notification msg=$(printf '%s' "$MSG" | head -1 | head -c 120)"
    # "Claude is waiting" 계열 상태 메시지는 배너 불필요
    if printf '%s' "$MSG" | grep -qiE 'claude is waiting|waiting for (your )?input'; then
        log "notification skipped: waiting-status message"
        exit 0
    fi
    # 첫 줄만 제목으로 사용, 나머지는 summary
    FIRST_LINE="$(printf '%s' "$MSG" | head -1 | head -c 80)"
    BODY="$(build_event question "${FIRST_LINE:-Claude 질문}" "$MSG" "" "")"
    post_notify "$BODY" >/dev/null 2>&1
    exit 0
    ;;

  *)
    log "unknown hook type: $HOOK_TYPE"
    exit 0
    ;;
esac
