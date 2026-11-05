<!-- DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04 -->
# F2 mutation-safety fixes

All work is local draft Swift 5 code, pending Opus compile-correctness and behavior review after 22:00 Toronto on 2026-11-04. No commits, pushes, network, external messages, publication, paid actions or sharing changes. Other lanes' files, including Tags, were not edited. No public signatures changed.

| Finding | Status | Files (worktree-relative) | Regression coverage | Residual risk / needed work |
|---|---|---|---|---|
| P2-1 | FIXED | `Sources/HelmFileSystem/Live/IOExecutor.swift`; `Sources/HelmOperations/Execute/OperationExecutor.swift`; both `Tests/Helm{FileSystem,Operations}Tests/F2SafetyTests.swift` | `testCancellationAfterStartRetainsCompletion`; `testCancelledStartedCopyKeepsExecutorBusyAndJournalsCompletion`; existing queued-cancellation/timeout tests | Cancellation atomically cancels queued work; running work returns its actual completion before the mutation lane releases. Generic adapters throwing cancellation during a primitive quarantine the operation executor. Existing timeout still quarantines and requires reconciliation; late timeout results remain outside the journal. No byte-level cancellation or macOS Trash validation claimed. |
| P2-2 | FIXED | `Sources/HelmFileSystem/Live/LiveFileSystem.swift`; filesystem F2 tests | `testFailedExclusiveWritePreservesReplacementBytes` | Internal write syscall seam replaces the pathname after exclusive open, then throws; replacement bytes survive. Failed writes intentionally retain partial artifacts, requiring reconciliation. No inode-check/unlink race substituted. |
| P2-3 | DEFERRED | `Sources/HelmOperations/Execute/OperationExecutor.swift`; operations F2 tests; module READMEs | `testUndoRefusesTreeWithoutDescendantEvidence` | **Unsafe retirement mitigated:** automatic inverse Trash of directory/package roots refuses with `verificationUnavailable`, even if the tree is unchanged. Live fixture proves nested edits leave root tokens unchanged. Complete post-copy descendant evidence requires a reviewed public journal/plan contract, forbidden in F2. See exact needed changes below. |
| P2-4 | FIXED | `Sources/HelmOperations/Execute/OperationExecutor.swift`; operations F2 tests | `testUndoRechecksAfterProgress`; existing exact-path copy/undo and swap/case-rename tests | Tokens are checked after progress and other preflight immediately before Trash/move; successful internal moves remap expected tokens to actual output paths. Native stat/mutate race remains; coordinated compare-and-mutate needs native contract review. |
| P2-5 | FIXED | `Sources/HelmOperations/Plan/OperationPlanner.swift`; operations F2 tests | `testCopyReplaceAncestorRefused`; `testMoveReplaceAncestorRefused`; `testKeepBothCopyToAncestorRemainsAllowed`; existing selected-target/case tests | Replace rejects containing targets, including the current source, before emitting executable steps. Component-boundary indexes preserve other-source protection. Ordinary keep-both ancestor copies remain available. Filesystem aliases/identity races remain native-coordination concerns. |
| P2-6 | FIXED | `Sources/HelmFileSystem/Live/LiveFileSystem.swift`, `ModuleInfo.swift`, `README.md`; filesystem F2 tests | `testEntryReadFailureCannotProduceSuccessfulListing`; existing planning/verifier tests | Conservative alternative to a new strict-mode contract: live enumeration throws on every child metadata error after reporting diagnostics. Already-yielded batches are partial; consumers must observe terminal failure. Existing mutation consumers fully drain the stream. Separate permissive UI enumeration is not introduced; future adapters must also propagate entry-read failures. |
| P2-7 | FIXED | `Sources/HelmOperations/Plan/OperationPlanner.swift`, `SourcePathIndex.swift`, `Journal/OperationJournal.swift`; operations F2 tests | `testSourceIndexComparisonBudget`; `testIndexComponentBoundariesAndExclusion`; `testHundredThousandSiblingPlanAndJournal` | Component-prefix indexes replace selection/target scans; normalized paths/names are cached; manifest bytes aggregate once by ancestor; journal duplicate IDs use sets. Benchmark plans 100k distinct sibling copies, checks destinations, and records each of 100k outcomes twice. No wall-clock threshold. Synchronous planning still has no cancellation API; extreme path depth or many identical basename collisions remain separate costs. |
| P2-8 | FIXED | `Sources/HelmFileSystem/Archive/ArchiveSafety.swift`; filesystem F2 tests | `testArchiveRootDirectoryMarkers`; `testArchiveUnsafeRootMarkersRemainRejected`; `testArchiveRootMarkerPlanningAndBudgets` | Accept zero-payload `.`/`./` directory markers; reject root files, traversal, absolute/empty names and payload-bearing root markers. Member budgets still count root markers. Confined runtime runner must ignore their metadata; planner does not itself extract archives. |

## Reproduction evidence

XCTest failure logs retained outside the worktree:

- `/tmp/F2-before.log`: seven tests, ten failed assertions, reproducing P2-1, P2-2, P2-4, P2-5 and P2-8 before their fixes. P2-2 had only an internal syscall seam extracted before this run; the unsafe unlink remained present.
- `/tmp/F2-scale-before.log`: P2-7 extracted the existing pairwise algorithm into an internal index with comparison instrumentation. The 1,024-sibling test failed with **523,776 comparisons**, exceeding its deterministic 16,384 budget. The optimized index passes the same assertion.
- `/tmp/F2-tree-before.log`: P2-3 and P2-6 failed before mitigations. P2-3 observed identical live root tokens after a nested edit; inverse execution reached Linux's unsupported Trash instead of refusing for missing tree evidence. P2-6 used an internal metadata-read seam to inject permission failure; childNames incorrectly succeeded. No real Trash was used on Linux.

Existing tests were not deleted or weakened. `K15ReplacementBoundaryTests.swift` now asserts original byte payloads survive all six failure boundaries using an internal in-memory fixture reader, retaining its previous size/presence assertions too.

## Needed changes elsewhere

For P2-3, coordinate contract owners to add a Sendable, complete no-follow post-mutation manifest to journal outcomes and inverse-plan preconditions: relative path, kind, object identity, content-change evidence, and explicit completeness/read-error state. Capture after each whole-tree copy, remap through internal moves, and compare immediately before inverse tree retirement. Unreadable or changed trees require explicit reviewed confirmation/reconciliation. A root child count is insufficient. Until this is reviewed, automatic undo of copied/new directories is deliberately unavailable. Strong object identity/content evidence belongs in Core wherever used in Core public signatures.

For P2-4, a native identity/token compare-and-mutate seam would close the remaining stat/rename race; F2 only closes the unbounded application-level validation gap. App/UI owners should surface `verificationUnavailable` and quarantine errors and must not retry without preconditions. A separate permissive UI listing API, if desired, needs explicit partial/completeness semantics; F2 keeps live listing fail-closed.

Shared GitHub memory was not fetched because this lane forbids network access. macOS 14/Xcode branches and actual Trash behavior remain unverified on Linux.

## Verification

Results appended after final checks. All Swift commands use `/tmp/build-F2`; runner logs use its `logs/` directory. Initial compilation collided with another lane editing a Core test; that file was left untouched and the later retry succeeded. An earlier local test-file edit during compilation also required a rerun; neither build failure is counted as regression evidence.

Additional P2-5 regression: `/tmp/F2-case-before.log` records two failed assertions for a case-sensitive destination with missing source-parent sensitivity. Replacement now normalizes both containment operands using destination-volume semantics; `testReplaceAncestorUsesDestinationCaseSemantics` covers it. Selected-target indexing uses the same namespace.

Two initial full-suite attempts crashed with signal 11 in the Search `ContractIntegrationTests.testLegacyAndSymbolicScopesUseOnlyTheirDeclaredRoots` test, after all F2 tests had passed. Logs: `/tmp/F2-full.log` and the initial `/tmp/F2-run-all.log`. No Search files were modified. The private F2 SwiftPM scratch artifacts were cleaned before a complete rebuild; this is a verification retry, not a hidden passing run. See final results below.

Final verification: **PASS**.

- Clean full XCTest suite: **530 tests, 2 existing F1 skips, 0 failures** (`/tmp/F2-full-clean.log`). All 16 new F2 tests run without skips. The 100k planning fixture took approximately 8.56 seconds on that run; elapsed time is diagnostic only.
- `HELM_K11_SCRATCH=/tmp/build-F2 bash scripts/rebuild/run_all.sh`: **all checks PASS**, six explicit target builds, **530 XCTest tests / 2 existing skips / 0 failures**, Python tests, static checks, UI syntax parse, report-only coverage; **0 failed checks**. `/tmp/F2-run-all-final.log` and `/tmp/build-F2/logs/`.
- Final standalone `bash scripts/static_checks.sh`: **194 Swift files, 0 errors** (`/tmp/F2-static-final.log`). Scoped `git diff --check`: clean.
- Clean rebuild resolved the observed crash; stale incremental artifacts are a plausible explanation, not a proven root cause. macOS SDK compilation and behavior still require Opus review.

Disposition: **7 FIXED, 1 DEFERRED with fail-closed mitigation (P2-3), 0 REJECTED**. Test count exceeds the required 492; no existing tests were removed, weakened or newly skipped by F2.
