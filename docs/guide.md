# ClaudeNotifier 상세 가이드

> Claude Code용 macOS 플로팅 배너 알림 시스템 — 설치부터 운영까지

---

## 목차

1. [개요](#개요)
2. [요구사항](#요구사항)
3. [설치](#설치)
4. [Hook 동작 방식](#hook-동작-방식)
5. [배너 종류](#배너-종류)
6. [설정 레퍼런스](#설정-레퍼런스)
7. [HTTP API](#http-api)
8. [LaunchAgent 자동 시작](#launchagent-자동-시작)
9. [문제 해결](#문제-해결)
10. [제거](#제거)
11. [개발 노트](#개발-노트)

---

## 개요

ClaudeNotifier는 Claude Code를 **macOS Terminal + tmux** 환경에서 백그라운드로 실행할 때 발생하는 UX 문제를 해결합니다.

Claude Code가 터미널 안에서 실행되기 때문에, 다른 앱을 사용하는 도중에는 권한 요청이나 작업 완료를 알 수 없습니다. ClaudeNotifier는 이를 **macOS 플로팅 배너**로 해결합니다.

```
[다른 앱 사용 중]
      ↓ Claude Code가 파일 쓰기 권한 요청
      ↓ hook이 ClaudeNotifier 앱에 이벤트 전달
      ↓ 화면 우상단에 배너 표시
      ↓ Yes 클릭 → Claude Code가 즉시 작업 계속
```

### 핵심 설계 원칙

| 원칙 | 구현 |
|------|------|
| **Fail-open** | 앱 미실행 / 타임아웃 시 Claude Code 기본 동작으로 폴백 |
| **스마트 표시** | 터미널이 이미 포커스 상태면 배너 생략 |
| **소리 없음** | 어떤 상황에도 사운드 재생 없음 |
| **자동 소멸 없음** | 명시적 닫기 전까지 배너 유지 |

---

## 요구사항

- **macOS 13 Ventura** 이상
- **Xcode Command Line Tools** (`xcode-select --install`)
- **Claude Code** CLI 설치 및 실행 중
- **tmux** (선택 — 없어도 TTY 방식으로 터미널 포커스 작동)

---

## 설치

### 1. 저장소 클론

```bash
git clone https://github.com/uri010/claude-notifier.git
cd claude-notifier
```

### 2. 앱 빌드 및 실행

```bash
./scripts/run-app.sh
```

내부적으로 `swift build -c release`를 실행한 뒤 앱을 백그라운드 프로세스로 시작합니다.  
기본 포트: `47823` (환경 변수 `CLAUDE_NOTIFIER_PORT`로 변경 가능)

실행 확인:

```bash
curl http://localhost:47823/health
# {"status":"ok","version":"1.0","pending":0}
```

### 3. Hook 등록

```bash
./scripts/install-hooks.sh
```

`~/.claude/settings.json`에 다음 세 hook을 등록합니다.

| Hook 이벤트 | 매처 | 역할 |
|------------|------|------|
| `PreToolUse` | `Bash\|Write\|Edit\|MultiEdit\|NotebookEdit` | 권한 배너 (blocking) |
| `Stop` | (전체) | 작업 완료 배너 |
| `Notification` | (전체) | 질문/알림 배너 |

모든 도구를 게이트하려면:

```bash
./scripts/install-hooks.sh --all
```

> **주의**: `--all` 옵션은 Read, WebFetch 등 모든 도구 호출에도 배너를 띄웁니다.  
> 앱이 실행 중이 아니면 3초 후 자동으로 통과합니다(fail-open).

### 4. Claude Code 재시작

hook은 Claude Code 세션 시작 시에만 로딩됩니다. 기존 세션을 종료하고 새로 시작하세요.

```bash
# 기존 세션 종료 후
claude
```

---

## Hook 동작 방식

### PreToolUse (권한 요청)

```
Claude Code → hook stdin JSON
                    ↓
           [bypass 감지] dangerouslySkipPermissions 플래그 → 즉시 통과
                    ↓
           [세션 캐시 확인] allowSession 이력 있음 → 즉시 통과
                    ↓
           [터미널 포커스 확인] 터미널 앱이 전면에 있음 → 즉시 통과
                    ↓
           POST /event → 앱이 배너 표시
                    ↓
           GET /response/{id} long-poll (최대 45초)
                    ↓
           사용자 클릭 → decision 수신
                    ↓
      allow → permissionDecision: allow
      allowSession → session 캐시 기록 + allow
      deny → permissionDecision: deny
      timeout → exit 0 (fail-open)
```

### Stop / Notification (알림)

```
Claude Code → hook stdin JSON
                    ↓
           [터미널 포커스 확인] 전면에 있음 → 종료 (배너 불필요)
                    ↓
           POST /notify → 앱이 배너 표시 (응답 대기 없음)
```

### 터미널 포커스 감지

`osascript`로 현재 최전면 앱 이름을 확인합니다.  
다음 앱이 전면이면 **배너를 표시하지 않습니다**:

```
Terminal, iTerm2, iTerm, Alacritty, Kitty, WezTerm, Hyper
```

그 외 모든 앱(브라우저, IDE, Finder 등)이 전면이면 배너를 표시합니다.

---

## 배너 종류

### 권한 요청 배너 (PreToolUse)

![권한 요청 배너](../assets/banner-permission.png)

- **Yes** — 이번 한 번만 허용
- **Session** — 이 세션 동안 해당 도구 자동 허용
- **No** — 거부 (Claude Code가 작업 중단)
- 배너 탭/클릭 — 터미널로 포커스 이동 후 배너 닫힘

### 작업 완료 배너 (Stop)

![작업 완료 배너](../assets/banner-stop.png)

- 프롬프트 처리 완료 시 표시
- 클릭 시 해당 터미널로 포커스 이동
- X 버튼으로 수동 닫기

### 질문 배너 (Notification)

![질문 배너](../assets/banner-question.png)

- Claude가 질문하거나 안내를 표시할 때 사용
- **Focus Session** 버튼 또는 배너 클릭으로 터미널 이동
- 긴 질문은 앞부분만 표시 (최대 300자)

---

## 설정 레퍼런스

### 환경 변수

| 변수 | 기본값 | 설명 |
|------|--------|------|
| `CLAUDE_NOTIFIER_PORT` | `47823` | HTTP 서버 포트 |
| `CLAUDE_NOTIFIER_WAIT` | `45` | PreToolUse 응답 대기 시간(초) |

`CLAUDE_NOTIFIER_WAIT`는 Claude Code hook 타임아웃(60초)보다 짧게 설정해야 합니다.

### `~/.claude/settings.json` 구조

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash|Write|Edit|MultiEdit|NotebookEdit",
        "hooks": [
          {
            "type": "command",
            "command": "/path/to/claude-notifier/scripts/notify-hook.sh pretooluse"
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/path/to/claude-notifier/scripts/notify-hook.sh stop"
          }
        ]
      }
    ],
    "Notification": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/path/to/claude-notifier/scripts/notify-hook.sh notification"
          }
        ]
      }
    ]
  }
}
```

---

## HTTP API

앱은 `http://127.0.0.1:47823`에서만 요청을 받습니다.

### `GET /health`

서버 상태 확인.

```bash
curl http://localhost:47823/health
# {"status":"ok","version":"1.0","pending":2}
```

### `POST /event`

Blocking 배너를 등록하고 ID를 반환합니다.

```bash
curl -X POST http://localhost:47823/event \
  -H 'Content-Type: application/json' \
  -d '{
    "kind": "permission",
    "title": "권한 요청: Bash",
    "summary": "rm -rf /tmp/test",
    "context": "session: main | myproject",
    "tool": "Bash"
  }'
# {"id":"XXXXXXXX-..."}
```

### `GET /response/{id}?timeout=N`

결정이 날 때까지 최대 N초 대기합니다.

```bash
curl "http://localhost:47823/response/XXXXXXXX-...?timeout=30"
# {"decision":"allow"} 또는 {"decision":"pending"}
```

### `POST /notify`

Fire-and-forget 배너를 표시합니다.

```bash
curl -X POST http://localhost:47823/notify \
  -H 'Content-Type: application/json' \
  -d '{"kind":"stop","title":"작업 완료","summary":"빌드 성공","context":"session: main | myproject"}'
```

### `POST /respond/{id}`

외부에서 결정을 주입합니다 (테스트, 자동화 용도).

```bash
curl -X POST http://localhost:47823/respond/XXXXXXXX-... \
  -H 'Content-Type: application/json' \
  -d '{"decision":"allow"}'
```

### `POST /clear`

현재 화면의 모든 배너를 닫습니다.

```bash
curl -X POST http://localhost:47823/clear
```

#### decision 값

| 값 | 의미 |
|----|------|
| `allow` | 이번 한 번 허용 |
| `allowSession` | 세션 동안 허용 |
| `deny` | 거부 |
| `dismiss` | X 버튼 닫기 |
| `focus` | 배너 클릭 (터미널 포커스) |
| `timeout` | 응답 시간 초과 |

---

## LaunchAgent 자동 시작

macOS 로그인 시 앱을 자동으로 시작하려면:

```bash
./scripts/install-launchagent.sh
```

등록 내용 확인:

```bash
launchctl list | grep claude.notifier
```

즉시 시작/종료:

```bash
launchctl start com.claude.notifier
launchctl stop com.claude.notifier
```

제거:

```bash
./scripts/uninstall-launchagent.sh
```

---

## 문제 해결

### 배너가 전혀 표시되지 않는다

1. 앱 실행 확인: `curl http://localhost:47823/health`
2. hook 등록 확인: `cat ~/.claude/settings.json | grep notify-hook`
3. 터미널이 전면에 있지 않은지 확인 (터미널 포커스 시 배너 생략)
4. 로그 확인: `tail -f ~/.claude-notifier/notifier.log`

### 권한 배너가 안 뜨고 바로 통과된다

- `--dangerously-skip-permissions` 플래그로 Claude Code가 실행 중일 때 정상 동작입니다.
- Session 캐시가 쌓인 경우: `/tmp/claude-notifier-allowed-*` 파일 삭제 후 재시도.

### 배너를 클릭해도 터미널로 이동하지 않는다

1. tmux 사용 중이라면 `tmux list-clients`로 클라이언트 확인
2. TTY 기반 포커스: Terminal.app이 아닌 iTerm2 등을 쓰는 경우 AppleScript 지원 확인
3. 로그에서 `TMUX_FOCUS` 항목 확인: `grep TMUX_FOCUS ~/.claude-notifier/notifier.log`

### 앱이 시작되지 않는다 (빌드 오류)

```bash
# Xcode Command Line Tools 설치 확인
xcode-select -p

# Swift 버전 확인 (5.9 이상)
swift --version

# 수동 빌드
swift build -c release 2>&1
```

### 포트 충돌

다른 프로세스가 47823 포트를 사용 중인 경우:

```bash
# 사용 중인 프로세스 확인
lsof -i :47823

# 다른 포트로 변경
export CLAUDE_NOTIFIER_PORT=48000
./scripts/run-app.sh
```

`~/.claude/settings.json`의 hook 명령에도 `CLAUDE_NOTIFIER_PORT=48000`을 추가해야 합니다.

---

## 제거

### Hook만 제거

```bash
./scripts/uninstall-hooks.sh
```

`~/.claude/settings.json`에서 ClaudeNotifier 관련 hook만 제거합니다.

### LaunchAgent 제거

```bash
./scripts/uninstall-launchagent.sh
```

### 앱 프로세스 종료

```bash
pkill -f ClaudeNotifier
```

### 세션 캐시 초기화

```bash
rm -f /tmp/claude-notifier-allowed-*
```

---

## 개발 노트

### 소스 구조

```
Sources/ClaudeNotifier/
├── main.swift          # 앱 진입점, NSApp 설정
├── HTTPServer.swift    # BSD 소켓 기반 HTTP 서버
├── Store.swift         # PendingResponse 저장소
├── Model.swift         # EventRequest, UserDecision 모델
├── PanelManager.swift  # NSPanel 생성·배치·제거
├── BannerView.swift    # SwiftUI 배너 뷰
├── TmuxFocus.swift     # tmux + TTY 포커스 로직
└── Logger.swift        # 파일 + stderr 로거
```

### 주요 설계 결정

**HTTP 서버 (BSD 소켓 직접 구현)**  
Foundation의 `URLSession` 서버 기능 부재로 BSD 소켓을 직접 사용합니다.  
`accept()` 루프를 백그라운드 스레드에서 실행하고 각 요청을 Task로 처리합니다.

**Long-poll 방식**  
WebSocket 대신 long-poll을 채택한 이유: 셸 스크립트에서 `curl` 하나로 구현 가능하고, 연결 유지 오버헤드가 없습니다.

**TTY 기반 터미널 포커스**  
Claude Code hook은 파이프된 서브프로세스로 실행되어 TTY가 없습니다(`ps -o tty=` → `??`).  
프로세스 트리를 10단계까지 거슬러 올라가 실제 TTY를 찾습니다.

**Fail-open**  
hook이 Claude Code를 영구적으로 멈추게 해서는 안 됩니다.  
앱 미응답 시 3초 내 `exit 0`으로 통과, 사용자 무응답 시 `CLAUDE_NOTIFIER_WAIT` 초 후 통과합니다.
