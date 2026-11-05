# AO1 operation-history fixes

DRAFT: pending review, 2026-11-04

## O1-2 — FIXED

Verified the proposal against `HistoryResultMapping.outcome`: it checks every
`requiresReconciliation` flag before returning `.partial`. A forward partial therefore
has known successful mutations and no uncertain outcome. `UndoPlanner` already
supports the successful prefix and retains its ownership/leaf checks.

- Forward `.partial` is retained in undo history without latching reconciliation.
- Forward `.reconciliationRequired` still latches; partial/uncertain undo still latches.
- Added Core `HistoryAction.acknowledgeReconciliation` and actor
  `WindowOperationHistory.acknowledgeReconciliation() -> Bool`.
- Acknowledgement requires no pending reservation and an existing latch. It removes
  only the blocked top undo entry, clears the latch, preserves older entries and
  journal evidence, and creates no redo authority. Repeated/no-latch calls refuse.
- The host must show original and inverse journal outcomes, including hidden stage
  and backup paths, and obtain explicit user confirmation before acknowledging.
  This API does not repair or verify filesystem state.

`HistoryOutcome.needsReconciliation` retains its conservative partial-undo meaning;
its documentation now explains the distinction. Mapping itself was not changed.
The existing partial-undo regression tests remain unchanged.

## Regression evidence

Tests were written before the production fix. The executable-prefix test failed
with a latched `partial("cancelled")` and a nil `beginUndo` result
(`/tmp/AO1-red-prefix.log`). Acknowledgement tests initially failed compilation
because the proposed API did not exist (`/tmp/AO1-red-ack.log`).

Created:
- `Tests/HelmCoreTests/OperationHistoryTests/OperationHistoryReconciliationTests.swift`
- `Tests/HelmOperationsTests/HistoryTests/HistoryReconciliationTests.swift`

The seven new tests cover actual known-prefix undo execution after cancellation or
known failure, uncertainty taking precedence over successful work, blocked admission,
acknowledgement, retained hidden-path evidence, older-entry preservation, no redo,
partial-inverse latching, repeated acknowledgement, and pending/no-latch refusal.

## Verification

Linux Swift 6.0.3, Swift 5 mode; sourced `/workspace/toolchains/env.sh`.
Scratch directory: `/tmp/build-AO1`.

- `swift build --build-tests --scratch-path /tmp/build-AO1`: PASS, zero errors.
- `swift test --scratch-path /tmp/build-AO1 --filter HelmCoreTests`: PASS, 660 tests.
- `swift test --scratch-path /tmp/build-AO1 --filter HelmOperationsTests`: initial
  run had 165 tests, one failure in the concurrent AO2 lane's
  `AO2OperationSafetyTests.testTreeUndoWithJournalEvidenceRefusesEditedDescendants`
  (directory change-token timestamp expectation). All history tests passed.
  Retry after 60 seconds: PASS, 167 tests, zero failures
  (`/tmp/AO1-operations-retry.log`); the concurrent lane updated its tests.
- Scoped `git diff --check`: PASS.

## Open integration work

Host UI confirmation/recovery presentation is outside AO1 ownership. Its owner must
present journal outcomes and call acknowledgement only after explicit confirmation;
no UI files were changed. Filesystem recovery and other O1 findings are outside this
assignment. macOS/Xcode correctness and behaviour preservation await Opus review.
No network, commits, pushes, or external actions were performed.
