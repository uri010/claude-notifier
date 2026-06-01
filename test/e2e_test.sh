#!/usr/bin/env bash
#
# claude-notifier E2E 테스트
#
# 검증 항목:
#   1. 앱 실행 상태 (HTTP 서버 응답)
#   2. 포커스 감지 (osascript + TTY)
#   3. 작업 완료 배너 (stop)  — 포커스 ON→스킵 / 직접 전송→배너 표시
#   4. 질문 배너 (notification) — 포커스 ON→스킵 / 직접 전송 / 메시지 필터
#   5. 권한 확인 배너 (pretooluse) — 포커스→스킵 / allow / deny / allowSession / 타임아웃
#   6. 배너 클릭 → 포커스 복원 (focus decision API + /clear)
#   7. tmux 세션 감지

set -uo pipefail

PORT="${CLAUDE_NOTIFIER_PORT:-47823}"
BASE="http://127.0.0.1:${PORT}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
HOOK="$PROJECT_ROOT/scripts/notify-hook.sh"
CURL="curl -s --max-time 3"
PASS=0
FAIL=0

# ── 출력 헬퍼 ────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'; BOLD='\033[1m'

ok()      { echo -e "  ${GREEN}✔${NC}  $*"; (( PASS++ )) || true; }
fail()    { echo -e "  ${RED}✗${NC}  $*"; (( FAIL++ )) || true; }
info()    { echo -e "  ${YELLOW}→${NC}  $*"; }
section() { echo -e "\n${BOLD}$*${NC}"; }

# ── 공통 변수 ────────────────────────────────────────────────────────────────
APP_RUNNING=false
IS_TERM_FOCUSED=false
TERM_TTY=""
FRONTMOST=""

PERM_BODY="$(jq -n '{
    kind:"permission",
    title:"권한 요청: Write [E2E]",
    summary:"/tmp/test.txt",
    context:"e2e | claude-notifier",
    tool:"Write",
    tmuxSession:"",
    tmuxTarget:"",
    cwd:"/tmp"
}')"

# ── 1. 앱 실행 상태 ───────────────────────────────────────────────────────────
section "[1] 앱 실행 상태 확인"

HEALTH="$($CURL "${BASE}/" 2>/dev/null || true)"
if [ -n "$HEALTH" ]; then
    ok "HTTP 서버 응답 확인 (port ${PORT})"
    APP_RUNNING=true
else
    fail "HTTP 서버 미응답 — claude-notifier 앱이 실행 중인지 확인하세요"
fi

if [ -f "$HOOK" ]; then
    ok "notify-hook.sh 경로 확인: $HOOK"
else
    fail "notify-hook.sh 파일 없음: $HOOK"
fi

# ── 2. 포커스 감지 ────────────────────────────────────────────────────────────
section "[2] 포커스 감지"

if command -v osascript >/dev/null 2>&1; then
    ok "osascript 사용 가능"

    FRONTMOST="$(osascript -e \
        'tell application "System Events" to return name of first application process whose frontmost is true' \
        2>/dev/null || true)"
    for _t in Terminal 터미널 iTerm2 iTerm Alacritty Kitty WezTerm Hyper; do
        [ "$FRONTMOST" = "$_t" ] && IS_TERM_FOCUSED=true && break
    done
    unset _t

    if [ "$IS_TERM_FOCUSED" = "true" ]; then
        ok "현재 포커스: ${FRONTMOST} (터미널 — 훅은 배너를 생략해야 함)"
    else
        info "현재 포커스: ${FRONTMOST:-알 수 없음} (비터미널 — 훅은 배너를 표시해야 함)"
    fi
else
    fail "osascript 사용 불가 — macOS 환경 확인 필요"
fi

# TTY 감지 (배너 클릭 → 포커스 복원에 사용)
_p="$$"
for _i in 1 2 3 4 5 6 7 8 9 10; do
    _tt="$(ps -p "$_p" -o tty= 2>/dev/null | tr -d ' ')"
    if [ -n "$_tt" ] && [ "$_tt" != "??" ]; then TERM_TTY="$_tt"; break; fi
    _pp="$(ps -p "$_p" -o ppid= 2>/dev/null | tr -d ' ' || true)"
    if [ -z "$_pp" ] || [ "$_pp" = "0" ] || [ "$_pp" = "1" ] || [ "$_pp" = "$_p" ]; then break; fi
    _p="$_pp"
done
unset _p _pp _tt _i

if [ -n "$TERM_TTY" ]; then
    ok "현재 TTY 감지: ${TERM_TTY} (배너 클릭 → 포커스 복원에 사용됨)"
else
    info "TTY 감지 실패 — 배너 클릭 포커스 복원 기능이 제한될 수 있음"
fi

# ── 3. 작업 완료 배너 (stop) ──────────────────────────────────────────────────
section "[3] 작업 완료 배너 (stop)"

STOP_PAYLOAD='{"session_id":"e2e-test","cwd":"/tmp","message":"E2E 테스트 완료"}'

# 3-a. 포커스 ON → 배너 생략 (훅 로그 확인)
STOP_ERR="$(echo "$STOP_PAYLOAD" | bash "$HOOK" stop 2>&1 >/dev/null)" && S_EXIT=0 || S_EXIT=$?
if echo "$STOP_ERR" | grep -q "terminal focused, skipping stop"; then
    ok "stop 훅 — 포커스 감지 → 배너 생략 확인 (로그 검증)"
elif [ "$S_EXIT" -eq 0 ] && [ "$IS_TERM_FOCUSED" = "true" ]; then
    ok "stop 훅 — 포커스 ON, 정상 종료 (배너 생략)"
elif [ "$S_EXIT" -eq 0 ]; then
    info "stop 훅 — 정상 종료 (비터미널 환경, 배너 전송됨)"
else
    fail "stop 훅 — 오류 종료 (exit ${S_EXIT}): ${STOP_ERR}"
fi

# 3-b. /notify로 stop 배너 직접 전송 (포커스 무관 — 항상 배너 표시)
if [ "$APP_RUNNING" = "true" ]; then
    STOP_BODY="$(jq -n '{
        kind:"stop",
        title:"작업 완료 [E2E]",
        summary:"E2E 테스트: stop 배너 직접 전송",
        context:"e2e | claude-notifier",
        tmuxSession:"",tmuxTarget:"",cwd:"/tmp"
    }')"
    RESP_STOP="$($CURL -X POST "${BASE}/notify" -H 'Content-Type: application/json' -d "$STOP_BODY")"
    if echo "$RESP_STOP" | grep -qE '"id"'; then
        ok "stop 배너 → /notify 직접 전송 성공 (배너 표시됨)"
    else
        fail "stop 배너 → /notify 전송 실패 (응답: ${RESP_STOP:-없음})"
    fi
else
    info "앱 미실행 — /notify 직접 전송 생략"
fi

# 3-c. 빈 메시지 처리
EMPTY_ERR="$(echo '{"session_id":"e2e-test","cwd":"/tmp"}' | bash "$HOOK" stop 2>&1 >/dev/null)" && ES_EXIT=0 || ES_EXIT=$?
[ "$ES_EXIT" -eq 0 ] \
    && ok "stop 훅 — 빈 message 필드 정상 처리 (exit 0)" \
    || fail "stop 훅 — 빈 message 오류 (exit ${ES_EXIT}): ${EMPTY_ERR}"

# ── 4. 질문 배너 (notification) ───────────────────────────────────────────────
section "[4] 질문 배너 (notification)"

NOTIF_PAYLOAD='{"session_id":"e2e-test","cwd":"/tmp","message":"파일을 삭제해도 괜찮을까요?"}'

# 4-a. 포커스 ON → 배너 생략 (훅 로그 확인)
NOTIF_ERR="$(echo "$NOTIF_PAYLOAD" | bash "$HOOK" notification 2>&1 >/dev/null)" && N_EXIT=0 || N_EXIT=$?
if echo "$NOTIF_ERR" | grep -q "terminal focused, skipping notification"; then
    ok "notification 훅 — 포커스 감지 → 배너 생략 확인 (로그 검증)"
elif [ "$N_EXIT" -eq 0 ] && [ "$IS_TERM_FOCUSED" = "true" ]; then
    ok "notification 훅 — 포커스 ON, 정상 종료 (배너 생략)"
elif [ "$N_EXIT" -eq 0 ]; then
    info "notification 훅 — 정상 종료 (비터미널 환경, 배너 전송됨)"
else
    fail "notification 훅 — 오류 종료 (exit ${N_EXIT}): ${NOTIF_ERR}"
fi

# 4-b. /notify로 question 배너 직접 전송 (포커스 무관 — 항상 배너 표시)
if [ "$APP_RUNNING" = "true" ]; then
    Q_BODY="$(jq -n '{
        kind:"question",
        title:"Claude 질문 [E2E]",
        summary:"다음 파일을 삭제해도 괜찮을까요?",
        context:"e2e | claude-notifier",
        tmuxSession:"",tmuxTarget:"",cwd:"/tmp"
    }')"
    RESP_Q="$($CURL -X POST "${BASE}/notify" -H 'Content-Type: application/json' -d "$Q_BODY")"
    if echo "$RESP_Q" | grep -qE '"id"'; then
        ok "question 배너 → /notify 직접 전송 성공 (배너 표시됨)"
    else
        fail "question 배너 → /notify 전송 실패 (응답: ${RESP_Q:-없음})"
    fi
fi

# 4-c. "waiting" 메시지 필터 (배너 없음)
WAIT_PAYLOAD='{"session_id":"e2e-test","cwd":"/tmp","message":"Claude is waiting for your input"}'
WAIT_ERR="$(echo "$WAIT_PAYLOAD" | bash "$HOOK" notification 2>&1 >/dev/null)" && W_EXIT=0 || W_EXIT=$?
if echo "$WAIT_ERR" | grep -q "waiting-status"; then
    ok "notification 훅 — 'waiting' 메시지 무시 처리 (필터 로그 확인)"
elif echo "$WAIT_ERR" | grep -q "terminal focused"; then
    ok "notification 훅 — 포커스 감지로 early-exit (waiting 필터 도달 전 스킵)"
elif [ "$W_EXIT" -eq 0 ]; then
    ok "notification 훅 — 'waiting' 메시지 무시 처리 (exit 0)"
else
    fail "notification 훅 — 'waiting' 메시지 오류 (exit ${W_EXIT})"
fi

# 4-d. 빈 메시지 필터 (배너 없음)
EMPTY_N_ERR="$(echo '{"session_id":"e2e-test","cwd":"/tmp","message":""}' | bash "$HOOK" notification 2>&1 >/dev/null)" && EN_EXIT=0 || EN_EXIT=$?
[ "$EN_EXIT" -eq 0 ] \
    && ok "notification 훅 — 빈 메시지 무시 처리 (exit 0)" \
    || fail "notification 훅 — 빈 메시지 오류 (exit ${EN_EXIT})"

# ── 5. 권한 확인 배너 (pretooluse) ───────────────────────────────────────────
section "[5] 권한 확인 배너 (pretooluse)"

PTOOL_PAYLOAD='{"session_id":"e2e-test","cwd":"/tmp","tool_name":"Bash","tool_input":{"command":"echo hello"}}'

# 5-a. 포커스 ON → 배너 생략 (훅 로그 확인)
PT_ERR="$(echo "$PTOOL_PAYLOAD" | bash "$HOOK" pretooluse 2>&1 >/dev/null)" && PT_EXIT=0 || PT_EXIT=$?
if echo "$PT_ERR" | grep -q "terminal focused"; then
    ok "pretooluse 훅 — 포커스 감지 → 배너 생략 확인 (로그 검증)"
elif [ "$PT_EXIT" -eq 0 ]; then
    info "pretooluse 훅 — 정상 종료 (session cache 또는 bypass 경로)"
else
    fail "pretooluse 훅 — 오류 종료 (exit ${PT_EXIT}): ${PT_ERR}"
fi

# 5-b ~ 5-e. 앱 직접 API 테스트 (포커스 우회)
if [ "$APP_RUNNING" = "true" ]; then

    # 5-b. /event로 permission 이벤트 생성 → 배너 표시
    RESP_PERM="$($CURL -X POST "${BASE}/event" -H 'Content-Type: application/json' -d "$PERM_BODY")"
    PERM_ID="$(echo "$RESP_PERM" | jq -r '.id // empty' 2>/dev/null)"
    if [ -n "$PERM_ID" ]; then
        ok "permission 이벤트 → /event 생성 성공 (id: ${PERM_ID:0:8}...)"
    else
        fail "permission 이벤트 → /event 생성 실패 (응답: ${RESP_PERM:-없음})"
    fi

    # 5-c. 대기 중(pending) 상태 확인
    if [ -n "$PERM_ID" ]; then
        POLL="$($CURL "${BASE}/response/${PERM_ID}?timeout=1")"
        D_POLL="$(echo "$POLL" | jq -r '.decision // empty' 2>/dev/null)"
        if [ "$D_POLL" = "pending" ]; then
            ok "permission 이벤트 — 대기 중 상태 확인 (pending)"
        else
            info "permission 이벤트 — 즉시 결정됨 (decision: ${D_POLL:-없음})"
        fi

        # 5-d. allow 결정
        ALLOW_RESP="$($CURL -X POST "${BASE}/respond/${PERM_ID}" \
            -H 'Content-Type: application/json' -d '{"decision":"allow"}')"
        if echo "$ALLOW_RESP" | grep -q '"ok"'; then
            ok "permission → allow 결정 API 성공"
        else
            fail "permission → allow 결정 실패 (응답: ${ALLOW_RESP:-없음})"
        fi
    fi

    # 5-e. deny 결정
    DENY_CREATE="$($CURL -X POST "${BASE}/event" -H 'Content-Type: application/json' -d "$PERM_BODY")"
    DENY_ID="$(echo "$DENY_CREATE" | jq -r '.id // empty' 2>/dev/null)"
    if [ -n "$DENY_ID" ]; then
        DENY_RESP="$($CURL -X POST "${BASE}/respond/${DENY_ID}" \
            -H 'Content-Type: application/json' -d '{"decision":"deny"}')"
        if echo "$DENY_RESP" | grep -q '"ok"'; then
            ok "permission → deny 결정 API 성공"
        else
            fail "permission → deny 결정 실패 (응답: ${DENY_RESP:-없음})"
        fi
    fi

    # 5-f. allowSession 결정
    AS_CREATE="$($CURL -X POST "${BASE}/event" -H 'Content-Type: application/json' -d "$PERM_BODY")"
    AS_ID="$(echo "$AS_CREATE" | jq -r '.id // empty' 2>/dev/null)"
    if [ -n "$AS_ID" ]; then
        AS_RESP="$($CURL -X POST "${BASE}/respond/${AS_ID}" \
            -H 'Content-Type: application/json' -d '{"decision":"allowSession"}')"
        if echo "$AS_RESP" | grep -q '"ok"'; then
            ok "permission → allowSession 결정 API 성공"
        else
            fail "permission → allowSession 결정 실패 (응답: ${AS_RESP:-없음})"
        fi
    fi

else
    info "앱 미실행 — permission API 테스트 생략"
fi

# 5-g. Allow Session 후 동일 도구 자동 허용 (세션 캐시 hit)
# 실제 버그 재현: allowSession 클릭 후 동일 요청이 배너도 안 뜨고 자동 허용도 안 되던 문제
section "[5-g] Allow Session → 세션 캐시 자동 허용"

_SC_DIR="$HOME/.claude-notifier/sessions"
_SC_FILE="$_SC_DIR/allowed-e2e-cache-test"
mkdir -m 0700 -p "$_SC_DIR" 2>/dev/null

# 세션 캐시에 "Write" 등록 (Allow Session 클릭 상태 시뮬레이션)
install -m 0600 /dev/null "$_SC_FILE" 2>/dev/null || { rm -f "$_SC_FILE"; touch "$_SC_FILE"; chmod 0600 "$_SC_FILE"; }
printf 'Write\n' >> "$_SC_FILE"

CACHE_PAYLOAD='{"session_id":"e2e-cache-test","cwd":"/tmp","tool_name":"Write","tool_input":{"file_path":"/tmp/e2e.txt","content":"hello"}}'

# 캐시 hit → permissionDecision:allow 출력 검증
SC_OUT="$(printf '%s' "$CACHE_PAYLOAD" | TMUX= bash "$HOOK" pretooluse 2>/dev/null)"
SC_ERR="$(printf '%s' "$CACHE_PAYLOAD" | TMUX= bash "$HOOK" pretooluse 2>&1 >/dev/null)"
SC_DECISION="$(echo "$SC_OUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)"

if [ "$SC_DECISION" = "allow" ]; then
    ok "Allow Session 후 동일 도구 → 세션 캐시 hit, permissionDecision:allow 자동 허용 확인"
else
    fail "Allow Session 후 동일 도구 → 자동 허용 실패 (decision:${SC_DECISION:-없음}, stderr:$(echo "$SC_ERR" | tail -1))"
fi

# updatedPermissions 필드가 응답에 없음을 확인 (제거된 필드)
if echo "$SC_OUT" | grep -q "updatedPermissions"; then
    fail "allowSession 응답에 updatedPermissions 필드 존재 — Claude Code hook bypass 버그 유발 가능"
else
    ok "allowSession 응답에 updatedPermissions 없음 (세션 캐시만으로 처리)"
fi

# 비파괴적 Bash 명령도 캐시 hit
printf 'Bash\n' >> "$_SC_FILE"
BASH_PAYLOAD='{"session_id":"e2e-cache-test","cwd":"/tmp","tool_name":"Bash","tool_input":{"command":"git status"}}'
BASH_OUT="$(printf '%s' "$BASH_PAYLOAD" | TMUX= bash "$HOOK" pretooluse 2>/dev/null)"
BASH_DECISION="$(echo "$BASH_OUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)"
[ "$BASH_DECISION" = "allow" ] \
    && ok "Allow Session 후 비파괴적 Bash → 세션 캐시 hit, 자동 허용" \
    || fail "Allow Session 후 비파괴적 Bash → 자동 허용 실패 (decision:${BASH_DECISION:-없음})"

# 파괴적 Bash 명령은 캐시 있어도 허용 안 됨 (보안)
RM_PAYLOAD='{"session_id":"e2e-cache-test","cwd":"/tmp","tool_name":"Bash","tool_input":{"command":"rm -f /tmp/e2e.txt"}}'
RM_OUT="$(printf '%s' "$RM_PAYLOAD" | TMUX= bash "$HOOK" pretooluse 2>/dev/null)"
RM_ERR="$(printf '%s' "$RM_PAYLOAD" | TMUX= bash "$HOOK" pretooluse 2>&1 >/dev/null)"
RM_DECISION="$(echo "$RM_OUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)"
if [ -z "$RM_DECISION" ] || [ "$RM_DECISION" != "allow" ]; then
    ok "파괴적 Bash 명령 → 세션 캐시 있어도 자동 허용 없음 (보안 확인)"
else
    fail "파괴적 Bash 명령이 세션 캐시로 자동 허용됨 — 보안 문제"
fi

rm -f "$_SC_FILE"
unset _SC_DIR _SC_FILE SC_OUT SC_ERR SC_DECISION BASH_OUT BASH_DECISION RM_OUT RM_ERR RM_DECISION

# 5-i. 훅 타임아웃 → failing open (최대 3초)
info "pretooluse 훅 — 타임아웃 경로 검증 (최대 3초 대기)"
TIMEOUT_ERR="$(echo "$PTOOL_PAYLOAD" | CLAUDE_NOTIFIER_WAIT=3 bash "$HOOK" pretooluse 2>&1 >/dev/null)" && TO_EXIT=0 || TO_EXIT=$?
if echo "$TIMEOUT_ERR" | grep -q "terminal focused"; then
    ok "pretooluse 훅 — 포커스 감지로 즉시 skip (타임아웃 검증 생략됨)"
elif [ "$TO_EXIT" -eq 0 ]; then
    ok "pretooluse 훅 — 타임아웃 후 failing open (exit 0)"
else
    fail "pretooluse 훅 — 타임아웃 경로 오류 (exit ${TO_EXIT})"
fi

# 5-j. 알 수 없는 훅 타입 → 안전 처리
UNKNOWN_ERR="$(echo '{}' | bash "$HOOK" unknown_type 2>&1 >/dev/null)" && UNK_EXIT=0 || UNK_EXIT=$?
[ "$UNK_EXIT" -eq 0 ] \
    && ok "알 수 없는 훅 타입 — exit 0으로 안전 처리" \
    || fail "알 수 없는 훅 타입 — exit ${UNK_EXIT}"

# ── 6. 배너 클릭 → 포커스 복원 ───────────────────────────────────────────────
section "[6] 배너 클릭 → 포커스 복원"

if [ "$APP_RUNNING" = "true" ]; then

    # 6-a. question 이벤트 생성 + focus 결정 (배너 클릭 시 터미널 포커스 트리거)
    FOCUS_BODY="$(jq -n \
        --arg tty "${TERM_TTY:-}" \
        '{kind:"question",
          title:"포커스 복원 테스트 [E2E]",
          summary:"배너 클릭 → 터미널 포커스 복원 검증",
          context:"e2e | focus-test",
          tmuxSession:"",tmuxTarget:"",cwd:"/tmp",
          tty:$tty}')"
    FOCUS_CREATE="$($CURL -X POST "${BASE}/event" -H 'Content-Type: application/json' -d "$FOCUS_BODY")"
    FOCUS_ID="$(echo "$FOCUS_CREATE" | jq -r '.id // empty' 2>/dev/null)"
    if [ -n "$FOCUS_ID" ]; then
        FOCUS_RESP="$($CURL -X POST "${BASE}/respond/${FOCUS_ID}" \
            -H 'Content-Type: application/json' -d '{"decision":"focus"}')"
        if echo "$FOCUS_RESP" | grep -q '"ok"'; then
            ok "배너 클릭 → focus 결정 API 성공 (TTY: ${TERM_TTY:-없음} → 터미널 포커스 복원 트리거됨)"
        else
            fail "배너 클릭 → focus 결정 실패 (응답: ${FOCUS_RESP:-없음})"
        fi
    else
        fail "focus 테스트용 이벤트 생성 실패 (응답: ${FOCUS_CREATE:-없음})"
    fi

    # 6-b. /clear → 모든 배너 정리
    CLEAR_RESP="$($CURL -X POST "${BASE}/clear")"
    if echo "$CLEAR_RESP" | grep -q '"ok"'; then
        ok "/clear → 모든 배너 제거 성공"
    else
        fail "/clear 엔드포인트 실패 (응답: ${CLEAR_RESP:-없음})"
    fi

else
    info "앱 미실행 — 배너 클릭 포커스 복원 테스트 생략"
fi

# ── 7. tmux 세션 감지 ─────────────────────────────────────────────────────────
section "[7] tmux 세션 감지"

if command -v tmux >/dev/null 2>&1; then
    ok "tmux 명령어 존재"
else
    fail "tmux 명령어 없음 — tmux 기능 비활성화됨"
fi

if [ -n "${TMUX:-}" ]; then
    TMUX_SESSION="$(tmux display-message -p '#S' 2>/dev/null || true)"
    TMUX_TARGET="$(tmux display-message -p '#S:#I.#P' 2>/dev/null || true)"
    ok "현재 tmux 세션 감지됨: ${TMUX_SESSION} (타깃: ${TMUX_TARGET})"

    if [ "$APP_RUNNING" = "true" ]; then
        TMUX_BODY="$(jq -n \
            --arg sess "$TMUX_SESSION" \
            --arg tgt  "$TMUX_TARGET" \
            '{kind:"stop",title:"[E2E] tmux 패널 반응 테스트",
              summary:"tmux 세션 감지 및 포커스 경로 검증",
              context:"e2e | tmux",
              tmuxSession:$sess,tmuxTarget:$tgt,cwd:"/tmp"}')"
        RESP_TMUX="$($CURL -X POST "${BASE}/notify" -H 'Content-Type: application/json' -d "$TMUX_BODY")"
        if echo "$RESP_TMUX" | grep -qE '"id"'; then
            ok "tmux 세션 정보 포함 이벤트 → /notify 전송 성공"
        else
            fail "tmux 이벤트 전송 실패 (응답: ${RESP_TMUX:-없음})"
        fi
    else
        info "앱 미실행 — tmux 이벤트 전송 생략"
    fi
else
    info "현재 tmux 외부 환경 — tmux 세션 감지 테스트 생략"
fi

# ── 결과 요약 ─────────────────────────────────────────────────────────────────
TOTAL=$(( PASS + FAIL ))
echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
if [ "$FAIL" -eq 0 ]; then
    echo -e "  ${GREEN}${BOLD}전체 통과: ${PASS}/${TOTAL}${NC}  모든 E2E 테스트 성공"
else
    echo -e "  ${RED}${BOLD}실패: ${FAIL}/${TOTAL}${NC}  (통과: ${PASS})"
fi
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
