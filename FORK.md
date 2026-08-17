# Godsenal/cmux 포크 규율

upstream(manaflow-ai/cmux)은 하루 100–270 커밋, 주 ~1.5 릴리즈로 움직인다.
포크 유지비를 최소로 유지하기 위한 규칙. (조사: 2026-08-17)

## 브랜치 모델

- `main` — upstream/main 미러. **절대 커밋하지 않는다** (ff-only).
- `godsenal` — 개인 개발 브랜치이자 기본 브랜치. upstream은 여기로 머지.
- 동기화: `scripts/sync-upstream.sh [--push]` — **최신 릴리즈 태그(v0.x)** 를 머지한다.
  main 팁이 아니라 태그를 따라가면 upstream의 릴리즈 검증을 공짜로 얻는다.
  ⚠️ `v1.x` 태그는 리네임 전(GhosttyTabs) 역사라 버전이 커도 더 오래됐다 — v0.*만 본다.

## 커스터마이즈 사다리 — 포크 패치는 최후의 수단

1. **`~/.config/cmux/cmux.json`** — 단축키, notifications.hooks(알림을 외부 명령으로 필터),
   terminal.textBoxSubmitActions(커스텀 에이전트 버튼), uploadCommands, 프로젝트별 `.cmux/cmux.json`.
2. **외부 데몬** — `cmux events`(NDJSON, 커서 재개) 구독 + `cmux rpc`/CLI 로 반응.
   court(~/LTH/court)가 이 방식. 릴리즈가 바뀌어도 살아남는다.
3. **커스텀 사이드바** — `~/.config/cmux/sidebars/<name>.swift`, 인터프리트 SwiftUI, 핫리로드,
   Xcode 불필요. `docs/custom-sidebars.md`.
4. **CmuxExtensionKit** — 별도 저장소의 컴파일 확장(사이드바). `Examples/SampleSidebarExtensionApp`.
5. 위로 안 되는 것만 코어 패치.

## 코어를 패치할 때

- **새 코드는 새 SPM 패키지로**: `Packages/macOS/<이름>` 생성 후
  `python3 scripts/check-workspace-package-groups.py --write`. 워크스페이스 그룹 수동 편집 금지.
  머지 비용을 줄이는 가장 큰 단일 레버.
- **방사능 파일** (최근 400커밋 중 touch 횟수): `project.pbxproj`(69) `Localizable.xcstrings`(41)
  `Workspace.swift`(32) `CLI/cmux.swift`(30, ArgumentParser 이전 중) `AppDelegate.swift`(29)
  `TerminalController.swift`(22) `ContentView.swift`(18, 타이핑 레이턴시 민감) `TabManager.swift`(15).
  건드려야 하면 내 모듈로의 호출 한 줄만 넣는다.
- **패치마다 exit note를 쓴다** (upstream의 docs/ghostty-fork.md 방식): 어떤 파일을 왜 바꿨고,
  upstream이 뭘 하면 이 패치를 버릴 수 있는지 한 문장. 머지가 고고학이 아니라 기계 작업이 된다.
- 작은 패치 스택은 머지보다 **태그 위로 rebase**가 낫다.
- **가능하면 upstream에 PR**. 단 CONTRIBUTING.md에 Manaflow에 영구적 상업 재라이선스 권리를
  주는 CLA성 조항이 있다는 걸 알고 서명할 것.

## 빌드

- 최초: `./scripts/setup.sh` (Xcode 26 pin, zig + rustup 필요 — CONTRIBUTING.md의 prereq는 낡았다).
- GhosttyKit은 체크섬 고정된 프리빌드를 받는다(`scripts/ensure-ghosttykit.sh`) — 엔진을
  패치할 때만 zig 빌드가 필요하다.
- **항상 태그 빌드**: `./scripts/reload.sh --tag <slug>`. 태그 없는 빌드는 본 앱의 소켓/번들ID를
  뺏는다. CLI 조작은 `CMUX_TAG=<tag> scripts/cmux-debug-cli.sh ...` (절대 /tmp/cmux-cli 쓰지 말 것).
- git hooks 필수(setup.sh가 설치): pbxproj 정규화가 없으면 diff가 머지 불가능한 노이즈가 된다.
- 테스트 함정: `cmuxTests/`의 .swift가 pbxproj에 배선 안 되면 조용히 스킵된다 —
  `./scripts/lint-pbxproj-test-wiring.sh`로 검사.

## 주의

- `cmux-tui/`(레포의 2번째 활발한 디렉토리)는 **별도의 Rust TUI 멀티플렉서**다. SDK/플러그인
  시스템(`cmux-tui/spec/*.md`)은 전부 TUI용 — Swift 맥 앱에는 일반 플러그인 API가 없다.
- 포크를 배포하면 GPL-3 소스 공개 의무 발생. 개인 사용은 무관.

## 현재 캐리 중인 패치

- `Packages/macOS/CmuxSimulator`를 upstream `8e03abb930`("Restore Xcode 16 simulator package
  compatibility", #10009) 버전으로 교체. 로컬 Xcode 16.4에서 v0.64.22가 sendability 에러로 안 빌드됨.
  **exit**: 8e03abb930을 포함한 릴리즈 태그로 sync하면 이 diff는 자연 소멸된다.
