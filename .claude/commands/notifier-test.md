# /notifier-test — claude-notifier E2E 테스트

claude-notifier의 핵심 기능을 자동으로 검증하는 E2E 테스트 스킬.

**트리거 예시**: `/notifier-test`, `/run-test`, "테스트 실행", "e2e 테스트", "notifier 테스트"

## 검증 항목

| # | 항목 | 내용 |
|---|------|------|
| 1 | 앱 실행 상태 | HTTP 서버(port 47823) 응답 확인 |
| 2 | 포커스 감지 | osascript로 현재 최전방 앱 및 TTY 감지 |
| 3 | stop 훅 | 포커스 ON→배너 생략 / /notify 직접 전송 / 빈 메시지 처리 |
| 4 | notification 훅 | 포커스 ON→배너 생략 / question 배너 전송 / waiting·빈 메시지 필터 |
| 5 | pretooluse 훅 | 포커스→스킵 / allow / deny / allowSession / 타임아웃 |
| 6 | 배너 클릭 → 포커스 복원 | focus decision API + /clear |
| 7 | tmux 세션 감지 | 세션 감지 및 tmux 이벤트 전송 검증 |

### 포커스 감지 동작 원칙

- **터미널 앱이 최전방**: 사용자가 Claude를 보고 있음 → 훅이 배너를 생략해야 함
- **다른 앱·탭·tmux**: 사용자가 자리를 비웠음 → 훅이 배너를 표시해야 함
- **배너 클릭**: 터미널 탭(또는 tmux 패널)을 최전방으로 가져와야 함

자동화 가능한 것: 포커스 ON 시 배너 생략(로그 검증), API 직접 호출로 배너 표시, focus 결정 API.
**수동 확인이 필요한 것**: 실제로 다른 앱 전환 후 배너가 뜨는지, 배너 클릭 시 터미널이 앞으로 오는지.

---

## 실행 순서

### 1단계: 사전 확인

```bash
# 앱 실행 여부 확인
curl -s --max-time 2 http://127.0.0.1:47823/

# tmux 환경 여부
echo "TMUX=${TMUX:-없음}"
```

앱이 실행 중이 아니면 API 기반 배너 테스트는 생략되고 훅 스크립트 동작만 검증된다.
사용자에게 앱 상태를 간략히 알린다.

### 2단계: 테스트 실행

```bash
bash /Users/yuri/mobigen/AI/claude-notifier/test/e2e_test.sh
```

- `CLAUDE_NOTIFIER_PORT` 환경 변수로 포트 변경 가능 (기본값: 47823)
- pretooluse 타임아웃 테스트는 `CLAUDE_NOTIFIER_WAIT=3`으로 단축 실행됨

### 3단계: 결과 해석 및 보고

테스트 완료 후 아래 형식으로 결과를 요약한다.

```
## E2E 테스트 결과

**앱 상태**: 실행 중 / 미실행
**현재 포커스**: Terminal (터미널 환경)
**통과**: N / 전체 M

| 항목 | 결과 | 비고 |
|------|------|------|
| 앱 실행 상태    | ✔/✗ | ... |
| 포커스 감지     | ✔/✗ | TTY, 최전방 앱 |
| stop 훅        | ✔/✗ | 포커스 스킵 / 직접 배너 |
| notification 훅 | ✔/✗ | 포커스 스킵 / 메시지 필터 |
| pretooluse 훅  | ✔/✗ | allow/deny/allowSession/타임아웃 |
| 배너→포커스 복원 | ✔/✗ | focus API |
| tmux 감지      | ✔/✗ | ... |
```

실패 항목이 있으면 원인을 분석하고 해결 방법을 제안한다.

### 실패 시 공통 원인

| 증상 | 원인 | 해결 |
|------|------|------|
| HTTP 서버 미응답 | 앱 미실행 | `swift run ClaudeNotifier` 또는 LaunchAgent 확인 |
| `/notify` 전송 실패 | 포트 불일치 | `CLAUDE_NOTIFIER_PORT` 환경 변수 확인 |
| 훅 스크립트 오류 | `jq` 미설치 | `brew install jq` |
| osascript 실패 | 권한 없음 | 시스템 환경설정 → 손쉬운 사용 권한 확인 |
| focus 결정 실패 | 앱 미응답 | 앱 재시작 후 재시도 |
| pretooluse 훅 오류 | 훅 경로 불일치 | `install-hooks.sh` 재실행 |
