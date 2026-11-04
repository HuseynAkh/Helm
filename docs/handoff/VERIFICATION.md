<!-- DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04 -->
# K11 verification record

Linux Swift 6.0.3, Swift 5 language mode; branch forge/rebuild-build. Shared
worktree was changing during verification. No commit, push or network access.
Only scripts/rebuild/ and docs/handoff/ were authored by K11.

- `bash scripts/rebuild/run_all.sh`: exit 0 on second run; all six portable target
  builds passed with `/tmp/build-K11`. XCTest: 260 reported, 259 passed, one skipped,
  zero failures. Logs: `/tmp/build-K11/logs/` (local, not checked in).
- First run: 245 XCTest cases, one failure in
  `K13PlacesTests.testStarredFolderHighlight`. Its owner subsequently marked it
  skipped as BUG-K13-1. K11 did not change or suppress the case. Acceptance stays open.
- Final Python fixture suite: 13 tests passed (coverage and shell gate tests).
  Command: `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts/rebuild -p 'test_*.py' -v`.
- `bash scripts/static_checks.sh`: zero errors. Concurrent source counts may grow.
- `bash scripts/rebuild/parse_check_ui.sh`: 10 Swift UI source files, zero parse errors;
  syntax only, no SDK typechecking. Mac test files are outside this script's scope.
- Strict coverage check: 565 rows = 72 F + 390 P + 103 B definition IDs, zero gaps;
  all 134 P0 and 159 P1 rows have milestone/module acceptance owners. Bug IDs are
  parsed from actual definitions, not manufactured from a numeric range.
- `bash -n scripts/rebuild/run_all.sh scripts/rebuild/parse_check_ui.sh`: passed.

Ledger generated from the successful XCTest log and citation scan. A class with
any skipped case supplies no linux-tested evidence. File citations remain coarse
precursor evidence, never whole-feature acceptance. F-033/F-058 may have citations
in shared files; their deferred/dead behavior dispositions still need explicit
review. None of the P rows currently has a P citation in passing portable tests.

Open: BUG-K13-1 conflicts with K12's documented intentional Starred exclusion;
Opus must resolve the preserved behavior. SwiftPM reports inaccessible user cache
paths and unhandled module README files. Manifest exclusions belong to its owner.
M0 parser-based selector/project checks, Mac compilation/runtime, strict-concurrency
acceptance and all Opus gates remain unverified. See MAC_HANDOFF.md for all other
needed changes elsewhere. Report-only coverage does not block the Linux runner on
planned work; strict coverage detects ownership/schema gaps, not unfinished features.

## Input/evidence SHA-256 at generation

- `/tmp/build-K11/logs/tests.log`: `1d0f56f1f17f620bbdb4f8c8e4d9a0f5297ba7a322c7c4c7507e2260210b5a92`
- `Package.swift`: `50ee83aa912c68f0ffdf02572ffe0c5912eac0a11a5c532e2bb9fdf2c95e6a80`
- `/workspace/forge/helm-plan/docs/rebuild/00-current-state.md`: `2bda1324433e5adf8a2cab91d4b3ca43830776e1b8f4e87512455dbfb8ed521e`
- `/workspace/forge/helm-plan/docs/rebuild/00a-astra-first-pass.md`: `39d0397add152f66a27b35ea44ed31cc925c79075bbcb678ef2c8a300fe36035`
- `/workspace/forge/helm-plan/docs/rebuild/00b-opus-review.md`: `6c4253b9befa714b7b2beadb4bac7a612d3016ab4efd95cf4c75278f71dae9e1`
- `/workspace/forge/helm-plan/docs/rebuild/01-architecture.md`: `6bdc2396b2c0bad1c4166f92d57122d4a4f14358c2241d56866f88aa5ffcc79b`
- `/workspace/forge/helm-plan/docs/rebuild/02-finder-parity.md`: `6139522dc7f08f3434430fd5b2d9f4b2c497adc032d6c6f66f39bd794606276e`
- `/workspace/forge/helm-plan/docs/rebuild/03-build-plan.md`: `33f56c3dd649d2087d379f2da59f7f4ab88f3f587b0972bec801be2d451d5647`

Repository HEAD (parallel dirty files are not captured by this hash): `0f80aa71cf7f8cb35ad44f0a3208480a4763c3b9`
