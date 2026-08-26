# RoutePic

## 커밋 · PR

**형식은 `pr-body-format` 스킬이 정한다.** 여기에는 이 저장소에만 해당하는 것만 적는다.

- **제목과 본문 모두 영어.** 커밋과 PR 양쪽 다
- 제목은 Conventional Commits 접두어. **기법이 아니라 문제나 결과를 적는다**
- 본문은 `## What` · `## How` · `## Why` (+ 필요할 때 `## Note`), 불릿만, 섹션당 5줄 이내
- **1 PR = 1 Commit.** 여러 개가 쌓였으면 squash 해서 올린다
- 커밋 메시지에 AI 표기 금지 (`Co-Authored-By: Claude`, `Claude-Session:`, "Generated with Claude Code")
  - 다른 세션·도구가 만든 커밋을 가져올 때도 붙어 있으면 지우고 올린다. **저장소의 열린 PR 전부를 확인한다**

## 워크플로

1. **PR 생성 전에 `trim-comments`를 먼저 돌린다.** 주석 정리 후에 PR을 만든다
2. **PR을 올린 뒤에는 항상 codex 리뷰 코멘트를 먼저 확인한다.** 다음 작업으로 넘어가기 전에
   - **저장소의 열린 PR 전부.** 이번에 만든 것뿐 아니라 이미 열려 있던 것도 본다. 다른 저장소에 올린 것도 포함한다
3. 코멘트는 하나씩 검증한다. 판정 없이 넘어가지 않는다
   - **정당하면** — 고치고 **resolve만 한다. 코멘트를 달지 않는다**
   - **정당하지 않으면** — **그 스레드에 답글로** 사유를 적고 resolve 한다
   - 어느 쪽이든 PR 최상단에 요약 코멘트를 새로 달지 않는다. 판단은 그 지적이 달린 자리에 남는다
4. resolve가 끝나면 **`codex-review` 게이트를 재실행한다.** 스레드를 닫아도 자동으로 다시 안 돌아서, 화면에는 계속 "미해결 코멘트 N건"이 빨갛게 남는다

```sh
gh run rerun $(gh run list --branch <branch> --limit 1 --json databaseId --jq '.[0].databaseId')
```

5. `@codex review`로 재리뷰를 요청한다. 봇이 👀를 달면 접수된 것
6. **새 코멘트가 더 이상 안 달릴 때까지 3~5를 반복한다**

## 빌드

- 패키지: 각 `Packages/*`에서 `swift test`
- 앱: **Xcode 26.2로 빌드한다.** 선택된 Xcode 26.6에는 iOS 플랫폼이 설치돼 있지 않다

```sh
DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer \
  xcodebuild -project App/RoutePic.xcodeproj -scheme RoutePic \
  -destination 'generic/platform=iOS Simulator' build
```

## 문서

- 구현이 시작된 이후로는 **코드가 SoT**다. `DESIGN.md`·`PLAN.md`는 `PLAN.md` 부록의 갱신 규칙을 따른다.
- `[가설]`·`[미검증]` 라벨이 실측으로 바뀌면 라벨도 같이 바꾼다.
