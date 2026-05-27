# /tistory-post — Tistory 블로그 자동 발행

Playwright를 사용해 yulee.tistory.com에 블로그 포스트를 작성·발행하는 스킬.

**트리거 예시**: `/tistory-post`, "티스토리에 올려줘", "블로그 발행해줘", "tistory 업로드"

---

## 전제 조건

- `/opt/homebrew/bin/python3.12` 에 `playwright` 설치 완료
- 발행할 HTML 본문 초안이 준비되어 있어야 함
- 이미지 파일 경로 목록 (없으면 생략)

## 세션 관리 (자동 로그인)

Playwright `storage_state`로 쿠키를 `~/.tistory_session.json`에 저장한다.
이후 실행 시 세션을 자동으로 불러오고, 만료된 경우에만 수동 로그인을 요청한다.

```
첫 실행: 수동 로그인 → 세션 저장 (~/.tistory_session.json)
이후 실행: 세션 자동 로드 → 로그인 없이 진행
세션 만료 시: 수동 로그인 → 세션 갱신
```

---

## 콘텐츠 작성 스타일 (yulee.tistory.com 기준)

### 제목 형식
- 대제목: `[카테고리] 본문 제목 — 부제목` (em-dash `—` 사용)

### 본문 HTML 형식
```html
<!-- h2 앞뒤에 빈 줄 한 칸 -->
<p>도입부 단락...</p>

<h2>섹션 제목 — 부제목</h2>
<p>본문 단락. 한 단락이 너무 길어지면 두 개로 나눈다.</p>
<p>인용은 blockquote 사용:</p>
<blockquote>"인용 내용"</blockquote>
<p>계속 이어지는 설명...</p>

<h2>다음 섹션</h2>
<p><strong>① 항목 제목:</strong> 설명 내용.</p>
<p><strong>② 항목 제목:</strong> 설명 내용.</p>
```

### 주의사항
- `<p>` 태그 안에서 줄바꿈을 쓰지 않는다 (Tistory가 `\n` → `<br>`로 처리)
- h2 섹션 전환 시 앞에 빈 `<p>` 줄을 하나 넣으면 시각적 여백이 생김
- 이미지: `style="max-width:560px;width:100%;display:block;margin:16px auto;border-radius:8px;"`

### 태그 규칙
- 포스트 주제와 직결된 키워드 4~6개
- 영문은 소문자 연속 (예: `claudecode`, `macos`)

---

## 발행 흐름

### 1단계: 스크립트 준비

`/tmp/tistory_post_<slug>.py` 파일을 아래 템플릿으로 생성한다.

```python
#!/opt/homebrew/bin/python3.12
from playwright.sync_api import sync_playwright
import json, time, base64, os, re

BLOG_ID   = "yulee"
TITLE     = "제목"
TAGS      = "tag1,tag2,tag3"   # 쉼표 구분
TOPIC     = "IT/인터넷"         # 발행 레이어 주제 텍스트

SESSION_FILE = os.path.expanduser("~/.tistory_session.json")

IMAGE_PATHS = {
    # "key": "/절대/경로/image.png",
}

CONTENT_HTML = """
<p>본문...</p>
"""

def upload_image(page, path):
    fn = os.path.basename(path)
    with open(path, "rb") as f:
        b64 = base64.b64encode(f.read()).decode()
    r = page.evaluate(f"""async () => {{
        const bytes = Uint8Array.from(atob("{b64}"), c => c.charCodeAt(0));
        const form  = new FormData();
        form.append('file', new Blob([bytes], {{type:'image/png'}}), '{fn}');
        const res = await fetch('/manage/post/attach.json',
            {{method:'POST', body:form, credentials:'include'}});
        return await res.json();
    }}""")
    return r.get("url")

def ensure_login(browser, viewport):
    """세션 파일이 있으면 자동 로그인, 없거나 만료되면 수동 로그인 후 세션 저장."""
    storage = SESSION_FILE if os.path.exists(SESSION_FILE) else None
    ctx = browser.new_context(viewport=viewport,
                              storage_state=storage if storage else None)
    page = ctx.new_page()

    # 로그인 상태 확인
    page.goto("https://www.tistory.com/", timeout=15_000)
    page.wait_for_load_state("networkidle")
    is_logged_in = page.evaluate(
        "() => !!document.querySelector('[class*=profile], [class*=user], .link_profile')"
    )

    if not is_logged_in:
        print("[로그인] 브라우저에서 Tistory에 로그인해주세요...")
        page.goto("https://www.tistory.com/auth/login")
        page.wait_for_url(lambda u: "login" not in u, timeout=300_000)
        time.sleep(1)
        # 세션 저장
        ctx.storage_state(path=SESSION_FILE)
        print(f"✅ 로그인 완료 — 세션 저장: {SESSION_FILE}")
    else:
        print("✅ 자동 로그인 (세션 재사용)")

    return ctx, page

def main():
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=False, slow_mo=150)
        ctx, page = ensure_login(browser, {"width": 1400, "height": 900})
        time.sleep(1)

        # ── 글쓰기 페이지 ────────────────────────────────────────────
        page.goto(f"https://{BLOG_ID}.tistory.com/manage/newpost/")
        page.wait_for_load_state("networkidle"); time.sleep(3)

        # ── 이미지 업로드 ────────────────────────────────────────────
        img_urls = {}
        for key, path in IMAGE_PATHS.items():
            url = upload_image(page, path)
            img_urls[key] = url or ""
            print(f"  이미지 {key}: {url[:60] if url else '실패'}...")

        # ── HTML 본문 (플레이스홀더 교체) ───────────────────────────
        html = CONTENT_HTML
        for key, url in img_urls.items():
            tag = (f'<img src="{url}" '
                   f'style="max-width:560px;width:100%;display:block;'
                   f'margin:16px auto;border-radius:8px;" alt="{key}">'
                   if url else f"<p><em>[{key} 이미지]</em></p>")
            html = html.replace(f"%%IMG_{key.upper()}%%", tag)

        # ── 제목 ─────────────────────────────────────────────────────
        page.wait_for_selector("#post-title-inp"); time.sleep(1)
        page.locator("#post-title-inp").fill(TITLE)

        # ── 태그 ─────────────────────────────────────────────────────
        if TAGS:
            tag_input = page.locator("#tagText")
            for tag in TAGS.split(","):
                tag_input.fill(tag.strip())
                tag_input.press("Enter")
                time.sleep(0.3)

        # ── TinyMCE 본문 삽입 (save()로 textarea 동기화) ─────────────
        page.wait_for_function(
            "() => typeof tinymce !== 'undefined' && tinymce.get('editor-tistory')",
            timeout=15_000)
        r = page.evaluate(f"""() => {{
            const ed = tinymce.get('editor-tistory');
            ed.setContent({json.dumps(html)});
            ed.save();
            ed.fire('change');
            return ed.getContent().length;
        }}""")
        print(f"  본문 삽입: {r}자"); time.sleep(2)

        # ── 완료(발행 레이어 열기) ───────────────────────────────────
        page.locator("#publish-layer-btn").click(); time.sleep(2)

        # ── 공개 설정 (#open20 = 공개) ──────────────────────────────
        page.evaluate("""() => {
            const el = document.getElementById('open20');
            if (el) { el.checked = true;
                ['change','click'].forEach(e =>
                    el.dispatchEvent(new Event(e, {bubbles:true}))); }
            const lbl = document.querySelector('label[for="open20"]');
            if (lbl) lbl.click();
        }""")
        time.sleep(0.5)

        # ── 주제 선택 (IT/인터넷) ────────────────────────────────────
        # 발행 레이어의 주제 드롭다운: "선택 안 함" 버튼이 주제 선택기
        try:
            topic_btns = page.locator(".select_btn")
            for i in range(topic_btns.count()):
                btn = topic_btns.nth(i)
                if "선택 안 함" in (btn.text_content() or ""):
                    btn.click(); time.sleep(1)
                    # 드롭다운 항목에서 일치 항목 클릭
                    items = page.locator(".select_list li, .layer-select li")
                    for j in range(items.count()):
                        item = items.nth(j)
                        if TOPIC in (item.text_content() or ""):
                            item.click()
                            print(f"  주제 선택: {TOPIC}")
                            break
                    break
        except Exception as e:
            print(f"  주제 선택 실패 (수동 설정): {e}")

        time.sleep(0.5)

        # ── 발행 버튼 확인 후 클릭 ───────────────────────────────────
        btn_text = page.locator("#publish-btn").text_content()
        print(f"  발행 버튼: '{btn_text}'")
        page.locator("#publish-btn").click(); time.sleep(4)

        print(f"📌 URL: {page.url}")
        page.screenshot(path="/tmp/tistory_post_result.png")
        # 발행 성공 시 세션 갱신 저장
        ctx.storage_state(path=SESSION_FILE)
        print("✅ 완료!")
        time.sleep(3)
        browser.close()

if __name__ == "__main__":
    main()
```

### 2단계: 실행

```bash
PYTHONUNBUFFERED=1 /opt/homebrew/bin/python3.12 -u /tmp/tistory_post_<slug>.py
```

세션 파일(`~/.tistory_session.json`)이 있으면 로그인 없이 자동 진행된다.
세션이 만료됐거나 파일이 없으면 브라우저에서 한 번만 로그인하면 된다.

### 세션 초기화 (강제 재로그인 필요 시)

```bash
rm ~/.tistory_session.json
```

---

## 발행 레이어 주요 셀렉터 (2026-05 기준)

| 요소 | 셀렉터 | 비고 |
|------|---------|------|
| 완료(레이어 열기) | `#publish-layer-btn` | |
| 공개 라디오 | `#open20` (value=20) | JS로 checked + dispatchEvent |
| 공개(보호) | `#open15` (value=15) | |
| 비공개 | `#open0` (value=0) | 기본값 |
| 주제 드롭다운 | `.select_btn` ("선택 안 함") | 두 번째 select_btn |
| 발행 버튼 | `#publish-btn` | 공개시 "공개 발행" 텍스트 |
| 취소 | `#unpublish-btn` | |

---

## 알려진 주의사항

| 문제 | 원인 | 해결 |
|------|------|------|
| 매번 로그인 필요 | 세션 없음 | `~/.tistory_session.json` 자동 저장·재사용 |
| 세션 만료 | Kakao 쿠키 유효기간 | `rm ~/.tistory_session.json` 후 재실행 |
| 발행 후 내용이 비어 있음 | `setContent` 후 `editor.save()` 미호출 | 반드시 `ed.save()` 호출 |
| 비공개로 저장됨 | `#open0`이 기본값 | JS로 `#open20` 강제 체크 |
| 이미지 업로드 405 | 잘못된 엔드포인트 | `/manage/post/attach.json` 사용 |
| 이미지 URL 만료 걱정 | `expires` 파라미터 | Tistory CDN이 자체 서빙 → 만료 무관 |
| 카테고리 미지정 | 자동 감지 어려움 | 발행 후 관리 페이지에서 수동 설정 |

---

## 실행 후 확인

1. `https://yulee.tistory.com/manage/posts/` 에서 발행 확인
2. 카테고리 미지정 시 수동으로 수정
3. 중복 임시저장 포스트가 있으면 삭제
