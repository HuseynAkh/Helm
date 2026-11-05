# F23 — P20 history admission fixes

DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04.

## Dispositions

- **P20-1 CONFIRMED / FIXED.** The pre-fix executable regression accepted all
  twelve altered safety/context fields (12 assertion failures). A second test
  executed the reconstructed inverse against a replacement occupant: admission
  succeeded and the fake filesystem trashed the replacement (2 assertion failures).
  Evidence: `/tmp/F23-safety-red.log`, 2 XCTest tests, 14 expected failures.
  `OperationPlan` and `PlanningContext` now use synthesized Equatable conformances;
  inverse admission compares the entire plan before recording any execution.
  This covers command, ordered full steps, issues, verification policy, tokens,
  kinds, ownership evidence, manifest, entries, capacity, case sensitivity, names,
  volume IDs and every conflict-policy field. Adding a stored field participates
  automatically in synthesized equality rather than silently bypassing a manual list.
  Tests verify rejection without consuming pending/attempts, then legitimate
  settlement. The replacement retains its identity and the genuine inverse refuses it.
- **P20-2 CONFIRMED / FIXED.** Source inspection confirmed there was no inverse
  preparation terminal path. API-first XCTest failed compilation because abortUndo
  was absent (`/tmp/F23-abort-red.log`); no pre-fix runtime assertion is claimed.
  Added request-matched `abortUndo(request:failure:)`, Core startUndo/abortUndo
  actions, and inverse execution-phase tracking. Abort preserves both stacks,
  records cancellation/failure and clears the pending inverse only before binding.
  Actor methods contain no suspension between validation and transition. Tests
  deterministically exercise both race orders: abort rejects late executor admission
  with zero mutation; binding rejects abort and requires normal terminal settlement.
  Stale/duplicate aborts, cancellation before dispatch (no new journal), subsequent
  undo/forward admission and nonempty redo preservation are covered.

## Scope and integration

Production changes are confined to Sources/HelmCore/OperationHistory and
Sources/HelmOperations. Added only new F23-prefixed XCTest files:
`Tests/HelmOperationsTests/HistoryTests/F23HistorySafetyTests.swift` and
`Tests/HelmCoreTests/OperationHistoryTests/F23UndoPreparationTests.swift`.
Existing tests, Package.swift, scripts and legacy Helm sources were not edited.
The Operations History README documents the host protocol.

**DEFERRED (outside ownership):** a future native host must catch undo preparation
cancellation/failure and call abortUndo with the reserved request; dispatch through
executor admission with the exact reserved plan; retain bound tasks until complete.
There is no native host added by this lane. macOS 14/Xcode compile and behavior
validation, Opus review, native conditional mutation and atomic completion receipts
remain outstanding. No redo support or tree-undo capability is introduced.
No network, commits, pushes, posting, sending, sharing changes or paid actions.
All file mutations in the new behavioral regressions use InMemoryFileSystem.

## Verification

Linux Swift 6.0.3, Swift 5 language mode, isolated `/tmp/build-F23`.
Focused Operations regressions: 4 tests, 0 failures (`/tmp/F23-green.log`).
Final full-suite and runner results follow below.

- Full portable XCTest suite: **1,198 tests, 0 failures, 0 skips**;
  `/tmp/F23-full.log`. Seven new F23 XCTest methods passed, including the
  twelve-field admission table and three Core phase/stack regressions.
- Standalone `bash scripts/static_checks.sh`: **242 Swift files, 0 errors**;
  `/tmp/F23-static.log`.
- Scoped `git diff --check`: PASS.
- `HELM_K11_SCRATCH=/tmp/build-F23 bash scripts/rebuild/run_all.sh`: **PASS**,
  all six explicit portable target builds, **1,198 tests / 0 failures / 0 skips**,
  Python checks, static checks, UI syntax parsing and report-only coverage;
  **0 failed checks**. Summary `/tmp/F23-run-all.log`; details
  `/tmp/build-F23/logs/`. UI parsing is not macOS SDK type checking.
