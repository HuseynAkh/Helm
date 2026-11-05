<!-- DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04 -->
# F8 fixes for P7

## P7-1 — FIXED

Reproduced before the production edit: after adding the XCTest regression,
the portable runner failed emitting HelmUI with `switch must be exhaustive`,
specifically missing `.overlappingSources(_, _)`. XCTest execution was blocked
by this compilation failure; no pre-fix assertion run is claimed.

Files: `Sources/HelmUI/Sheets/BatchRenameViewModel.swift` and
`Tests/HelmUITests/SheetsTests/BatchRenameViewModelTests.swift`.
The exhaustive mapping now explains that a folder and its descendant cannot be
renamed together and includes both full paths. Core still determines validity.
`testOverlappingSourcesExplainBothPathsAndRefuseExecution` checks both selection
orders, the explanation, disabled rename, zero steps and no executable plan.
The portable UI/App suite passed all 51 tests after the fix.

Residual risk: long-path layout and accessibility need macOS hosted verification;
Linux validates the adapter and execution guard, not SwiftUI rendering.

## P7-2 — DEFERRED (confirmed; requires another owner)

Read `BatchRenameSheet.swift` and `HelmCore/Naming/BatchRenamePlanner.swift`.
The detached worker has no cancellation forwarding; Core's synchronous planner
has no cancellation checks in name generation, overlap sorting, occupancy,
target construction or temporary-step generation. Revision checks prevent stale
publication/execution but do not interrupt the calculation. This is a real
resource-lifetime defect. No production or test change is claimed for P7-2.

Needed changes elsewhere: the Core Naming owner must add a throwing cancellable
planning seam (preserving existing callers), checking cancellation in those
loops, in temporary-name collision probing, and before/after sorting. It must
throw cancellation without returning any partial plan. Keep validation and
temporary-step semantics centralized in Core rather than copying them into UI.

After that seam lands, the UI owner must retain one worker, forward outer-task
cancellation with `withTaskCancellationHandler`, cancel on replacement and
disappearance, and retain at most the latest pending revision. Cancelled work
must not populate the evaluation cache. Add an injected slow-worker XCTest:
start A, replace with B, dismiss, assert cancellation delivery, maximum active
worker count of one and no post-dismissal publication. Handle cancellation alone
would not fix this finding, so no misleading partial fix was made.

Residual risk: large selections and successive edits can still leave concurrent
obsolete calculations running. Duration and peak memory require macOS profiling.

## Verification

All commands source `/workspace/toolchains/env.sh`; scratch is `/tmp/build-F8`.
Initial full rebuild executed 707 portable tests, with 24 assertion failures in
concurrently introduced F6 tests and zero skips. No F6 files were edited by F8.
All six portable target builds, rebuild Python checks, static checks, UI syntax
checks and coverage report passed. Waited 60 seconds and reran full verification.
Final retry: `HELM_K11_SCRATCH=/tmp/build-F8 bash scripts/rebuild/run_all.sh`
ran 723 tests, zero skips, one assertion failure. The failure is outside F8:
`Tests/HelmOperationsTests/BoundaryTests.swift:76`,
`testSourceChangedBeforeVerificationIsRetained` expects `.verificationFailed`
but receives `.sourceChanged(file:///source)`. The Operations owner must resolve
the expected error contract and implementation/test mismatch. F8 did not change
that test or its implementation. The required zero-failure gate is NOT met.

All six module builds passed again. Rebuild Python checks, static checks (206
Swift files, zero errors), UI parse (42 files, zero failures) and report-only
coverage passed. The final portable UI/App run against the rebuilt dependencies
passed 51 XCTest tests, zero failures, zero skips. Thus 774 XCTest tests ran
across the two final suites, with one failure outside F8. Logs:
`/tmp/F8-all-retry.log`, `/tmp/build-F8/logs/tests.log`, `/tmp/F8-ui-final.log`.

Portable runner configuration tests: 2 passed. Static checks: 205 Swift files,
zero errors in the initial run. Existing tests were neither removed nor weakened.
Integration notes were added to `Sources/HelmUI/README.md`.

No network, commit, push, publication, messaging, sharing changes or paid renders.
No old-app, manifest, scripts or other lane files were edited. macOS SDK builds
and Opus compile/behaviour review remain pending.
