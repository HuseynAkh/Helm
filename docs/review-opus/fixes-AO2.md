# DRAFT: pending review, 2026-11-04

AO2 checked the assigned proposals against the implementation. All changes remain pending Opus review for compile correctness and behavior preservation. No network, commit, push, publication, or external action was performed. Changes are confined to AO2-owned source/test paths and this report.

## Disposition

| Finding | Status | Evidence and change |
|---|---|---|
| O1-5 | FIXED | Read-only failures were incorrectly marked uncertain. `OperationExecutor` now bases uncertainty on entry into a primitive, retaining the missing-output-evidence reconciliation rule and existing quarantine rule. The revised `ExecutorTests.testFailureKeepsEarlierOutcomesAndStopsLaterItems` failed before the fix, then passed with an executable and successfully executed prefix inverse. `AO2OperationSafetyTests.testInverseMismatchAfterProgressHasNoUncertainMutation` also verifies a post-progress identity/token mismatch refuses without reconciliation. |
| O1-6 | FIXED | Output observation now runs in an unstructured task that does not inherit caller cancellation. The existing gated-copy regression failed its evidence, inverse, and undo assertions before the fix. It now passes. A new final-copy case also asserts successful completion, destination evidence, and successful undo after cancellation inside the primitive. Genuine metadata failures still produce missing evidence; existing refusal tests pass. |
| O1-7 part 1 | FIXED | `IOExecutor` starts its timer only after `begin` admits the work item. A width-one, gated queue regression failed with `timedOut` before the fix, then passed: each native body stays within its deadline while the queued third item waits longer than a deadline. A subsequent call succeeds, proving no false quarantine. |
| O1-7 parts 2–4 | DEFERRED | Explicitly outside this assignment. Requires distinguishing read/mutation admission, tracking timed-out bodies, releasing read quarantine only after all relevant bodies return, an explicit reconciled-mutation reset, and progress-aware deadlines for listing/copy. This patch intentionally retains permanent quarantine for a genuinely timed-out body. |
| O1-8 | FIXED | Only live exclusive-file and directory creation use a private wrapper translating `IOExecutor`'s pre-admission `CancellationError` to `ConditionalMutationError.cancelledBeforeMutation`; their synchronous bodies do not emit `CancellationError`. Fake creates now check cancellation before inserting. Before the fix, tests observed untyped cancellation from queued live creates and actual mutation from precancelled fake creates. Afterward, both create variants refuse without mutation. An executor-level fixture puts only the live create on the occupied queue and verifies `.cancelled`, no reconciliation, no output, and a subsequent operation that is not `.busy`. Started-body cancellation and uncertain primitive tests remain passing. |
| O1-9 | FIXED | Live enumeration skips a child metadata read that maps to `.notFound`. Permission and other failures still diagnose and throw. A mixed vanished/surviving-child fixture failed before the fix and now returns the surviving name. The existing permission-denied listing regression remains passing. |
| O1-10 | DEFERRED | Not mechanical. Name-cache updates must account for actual keep-both destinations, move/trash source removal, temporary rename chains, replacement stages, and external writers. Ancestor caching would also remove current per-step checks against replacement/symlink races; that needs a reviewed invalidation/identity policy. Required follow-up: a per-execution cache with explicit invalidation, folded-name/sensitivity handling, collision refresh, a top-level manifest index, and an executed counting-spy budget test. The no-follow default `childNames` implementation is in `Sources/HelmFileSystem/Protocol`, outside AO2 ownership; any shared contract/default change needs that owner. No unsafe caching shortcut or production behavior change was made for this finding. |
| O1-14 | FIXED | Added a fake-backed regression that executes copy, same-volume move, and create-directory, obtains inverses from real journal outcomes, asserts destination identity evidence and directory kind, edits descendants, and checks refusal, zero successes, and unchanged metadata/identity/payload inventory. For the newly created directory, the fixture restores the root timestamp after adding a child so a token mismatch cannot mask the tree guard. Mutation verification: temporarily deleting the directory/package guard in `validateUndoKind` makes the test fail three assertions because the directory move succeeds and changes inventory. Restoring the guard returns the test to green. No production tree guard was weakened. |

## Files

Modified:
- `Sources/HelmOperations/Execute/OperationExecutor.swift`
- `Sources/HelmFileSystem/Live/IOExecutor.swift`
- `Sources/HelmFileSystem/Live/LiveFileSystem.swift`
- `Sources/HelmFileSystem/Fake/InMemoryFileSystem.swift`
- The two finding-named tests in `Tests/HelmOperationsTests/ExecutorTests.swift` and `F2SafetyTests.swift`.

Created:
- `Tests/HelmOperationsTests/AO2SafetyTests.swift`
- `Tests/HelmFileSystemTests/AO2SafetyTests.swift`
- `docs/review-opus/fixes-AO2.md`

No changes to `OperationExecutor.execute`'s signature or history/origin defaults. No edits to HelmCore, operations History, the old app, or another lane's tests.

## Verification

All commands used the Swift 6.0.3 environment from `source /workspace/toolchains/env.sh`, Swift 5 language mode, and scratch path `/tmp/build-AO2`.

- Red run: six selected original/new regressions failed before production changes (16 assertion/error reports), covering O1-5/6/7.1/8/9. Log: `/tmp/AO2-red.log`.
- Tree-guard mutation run: failed as expected; production source restored before final build. Log: `/tmp/AO2-tree-mutant.log`.
- `swift build --build-tests --scratch-path /tmp/build-AO2`: passed, zero errors. Log: `/tmp/AO2-build.log`.
- `swift test --scratch-path /tmp/build-AO2 --skip-build --filter HelmOperationsTests`: 167 tests passed, zero failures. Log: `/tmp/AO2-operations.log`.
- `swift test --scratch-path /tmp/build-AO2 --skip-build --filter HelmFileSystemTests`: 205 tests passed, zero failures. Log: `/tmp/AO2-filesystem.log`.

One intermediate test build encountered another lane's new history tests before its new history action existed. Continued independent AO2 work while the other lane completed, then retried; the final build passed. Existing SwiftPM cache/resource warnings and deferred trailing-closure warnings remain. macOS 14/Xcode execution has not been available; Opus/macOS review remains required. Live conditional mutation remains conservatively unsupported, unchanged by this lane.
