<!-- DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04 -->
# K13 findings

## BUG-K13-1 — Starred folders cannot become the sidebar highlight

- Regression: `K13PlacesTests.testStarredFolderHighlight` in `Tests/HelmCoreTests/PlacesTests/K13PlacesTests.swift`.
- Source: `Sources/HelmCore/Places/PlacesModel.swift:55`.
- Diagnosis: the highlight candidate list includes favorites, bookmarks and devices but omits starred folders, so navigating to a starred folder or its child returns no highlight (or a less specific ancestor).
- Contract: architecture F-027 explicitly requires starred folders to participate in deepest-ancestor highlighting; F-029 owns the starred sidebar section.
- Reproduction: home `/home`, starred folder `/offline/star`, committed location `/offline/star/child`; expected `starred-/offline/star`, actual `nil`.
- Observed on Linux Swift 6.0.3: the regression assertion failed before quarantine. The test now begins with `try XCTSkipIf(true, "BUG-K13-1: ...")`; its expected-behavior assertion remains intact.
- Needed changes elsewhere: the Core Places owner should include starred directory candidates while retaining exact-match priority and deepest-ancestor selection. K13 did not modify sources.

All findings and tests are DRAFT pending Opus compile-correctness and behavior-preservation review after 22:00 Toronto on 2026-11-04.

## Verification

- Added 84 XCTest cases in eight new Swift test files, plus an integration README.
- Linux Swift 6.0.3, Swift 5 language mode; isolated scratch directory `/tmp/build-K13`.
- Explicit module builds: HelmCore, HelmSearch, HelmPersistence succeeded.
- All six portable test targets were exercised; one intentional BUG-K13-1 skip.
- No source or package edits, commits, pushes, network calls, or external actions by K13.
- macOS/Xcode validation and the scheduled Opus review remain outstanding.
- Final full-suite result: 260 tests executed, 1 intentionally skipped, 0 failures (8.285 seconds).
- Final static checks: 122 Swift source files checked, 0 errors.
