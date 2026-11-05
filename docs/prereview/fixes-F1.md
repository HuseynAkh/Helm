<!-- DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04 -->

# F1 prereview fixes

All five findings in P1.md were re-verified by XCTest before fixes. No finding was
rejected. Public-contract changes are prohibited by this lane assignment; P1-1 and
P1-4 therefore remain deferred, not repaired or safe to ship.

| ID | Status | Files | Test coverage | Residual risk / needed change |
| --- | --- | --- | --- | --- |
| P1-1 | DEFERRED | `Tests/HelmCoreTests/NamingTests/F1NestedRenameTests.swift` | `testNestedSourcesMustBeRefusedBeforeMutation` reproduced four failed assertions for both input orders; `testSiblingSourcesRemainExecutable` passes | Add an explicit public `BatchRenameIssue.overlappingSources` case and reject standardized component ancestor/descendant pairs under volume comparison semantics before emitting steps, retaining previews. This is a forbidden public-contract change for F1. Nested plans remain executable and unsafe. No mutation was performed. |
| P1-2 | FIXED | `Sources/HelmCore/DragDrop/DropPlanner.swift`, `DragDrop/README.md`; `Tests/HelmCoreTests/DragDropTests/F1DropWorkTests.swift` | `testOverlapValidationHasLinearPrefixCheckBound`, `testPermutationsMatchAllPairsReference`, `testLargeUnrelatedSelectionPreservesExecutionOrder` | Sorted component arrays plus adjacent comparisons replace the quadratic scan. Original source order is retained. Session caching remains deferred to the adapter/API owner; this stateless API has no session identity. Sorting still runs per proposal; comparison costs depend on path depth/length. |
| P1-3 | FIXED | `Sources/HelmCore/State/TabReducer.swift`, `TabNavigation.swift`, `README.md`; `Tests/HelmCoreTests/StateTests/F1StateRegressionTests.swift` | `testMetadataRepublishRetainsDeferredAddsAndRemovals` | Sort and all three error metadata paths use the most recent deferred snapshot. Tests cover added/deleted entries, visible-list deferral, resulting order/selection and preserved error phase. Native editor lifecycle still requires Mac review. |
| P1-4 | DEFERRED | `Tests/HelmCoreTests/ContentTests/F1ColumnGenerationTests.swift` | `testReturningToSameDirectoryMustRejectOldReply` reproduced two failed assertions | Add owning-column identity and per-request generation to public `ColumnNavigation.load`, require both in public `push`, invalidate on new requests, selection/ancestor replacement and truncation/pop, and migrate `HelmUI/Content/ColumnBrowserView.swift` consumers/load adapters. Cancellation alone is insufficient. Same-path stale replies remain accepted. |
| P1-5 | FIXED | `Sources/HelmCore/State/TabNavigation.swift`, `State/README.md`; `Tests/HelmCoreTests/StateTests/F1StateRegressionTests.swift` | `testHistoryRestorationSurvivesRestartUntilExplicitSelection` | Same-location load restart retains existing restoration IDs. Back/Forward × refresh/hidden toggle × explicit selection cases verify restoration, retired callback rejection and terminal cleanup. Existing navigation/selection tests are unchanged. |

## Failure-first evidence

`/tmp/build-F1-before.log` records the initial run: 6 tests, 23 failed assertions,
zero unexpected failures. The drag planner's original all-pairs loop was first
extracted unchanged into an internal helper with an injectable prefix predicate;
its test counted **999,000** prefix checks for 1,000 unrelated paths against a
maximum of 1,000. After replacing the algorithm, it performs **999**. The timing
fixture is diagnostic only (10,000 sources approximately 0.13 seconds on the first
post-fix Linux debug run); it has no wall-clock assertion. Small permutations are
checked against an independent all-pairs reference, including root, duplicates,
standardization, reversed ancestry and `/a` versus `/ab` boundaries.

The two deferred tests retain their original failing assertions and are explicitly
skipped by default, with the deferral reason reported by XCTest. They are **not
passing regressions**. Reproduce the still-open defects with:

```sh
source /workspace/toolchains/env.sh
F1_RUN_DEFERRED_REGRESSIONS=1 swift test --scratch-path /tmp/build-F1 \
  --filter 'F1NestedRenameTests.testNestedSourcesMustBeRefusedBeforeMutation|F1ColumnGenerationTests'
```

No existing tests were removed, skipped, or weakened. The new state tests extend
the interrupted-history and inline-rename fixtures named in P1; the new rename
fixture exposes the full nested paths absent from the older basename simulation.

## Integration and scope

Changes are limited to F1-owned paths. No public API, manifest, script, old Helm
source, or other lane's file was changed. All code is draft pending Opus review
after 22:00 Toronto on 2026-11-04; macOS 14/Xcode validation remains outstanding.
No network, commit, push, paid operation, send, publish, delete, or sharing change.

Needed changes elsewhere: approve and coordinate the two public-contract changes
above, and add drag-session validation caching in the owning adapter with an
explicit invalidation lifetime (source set changes and drag end). Do not introduce
a process-global cache of user paths merely to avoid the current stateless API.

## Verification

- `swift build --scratch-path /tmp/build-F1 --target HelmCore`: PASS, zero errors.
- Full portable suite: initially 515 discovered, 2 skipped, 0 failures. The final
  scripted run includes concurrent lane additions: **529 discovered, 527 passed,
  2 explicitly skipped deferred F1 regressions, 0 failures** (above the 492 floor).
- `HELM_K11_SCRATCH=/tmp/build-F1 bash scripts/rebuild/run_all.sh`: PASS, all six
  portable target builds, XCTest, Python tests, static checks, UI syntax parse and
  report-only coverage; zero failed checks. Log: `/tmp/build-F1-run-all-retry.log`;
  detailed logs: `/tmp/build-F1/logs/`.
- `bash scripts/static_checks.sh`: PASS, zero errors.
- `git diff --check` on F1-owned edited paths: PASS.

Concurrent-lane note: an intermediate Core run caught F3's failure-first tests;
an intermediate scripted run caught F2/F3's failure-first tests (518 discovered,
three failures). Those files were not edited. After waiting for the other lanes,
the complete scripted run passed as reported above. Baseline failures are retained
in `/tmp/build-F1-core.log` and `/tmp/build-F1-run-all.log`. SwiftPM emitted existing
unhandled-README and unwritable user-cache warnings; no manifest changes were made.
UI parse and coverage reporting do not establish macOS compilation or acceptance.
