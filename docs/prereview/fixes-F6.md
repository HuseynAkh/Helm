<!-- DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04 -->

# F6 fixes for P5

All four findings reproduced before implementation: five regression tests failed
with 24 assertions (`/tmp/F6-red.log`). No findings rejected. No public action or
effect signatures changed. Legacy code, other lanes, manifest and scripts untouched.

| ID | Status | Files / change | Regression evidence | Residual risk |
| --- | --- | --- | --- | --- |
| P5-1 | FIXED | State/TabNavigation.swift retires/restarts watch generation on foreground refresh; Store/WindowStore.swift retains and cancels auxiliary reload handles. | F6StateTests.testHeldMonitorResultCannotUndoHiddenToggleOrRefresh; F6StoreTests.testForegroundRefreshCancelsAuxiliaryMonitorReload | Adapters must return cancellation handles; queued callbacks are independently rejected by generation. |
| P5-2 | FIXED | State/TabState.swift, TabReducer.swift, TabNavigation.swift coalesce dirty monitor changes and replay once after success or either failure form; preserve same-location supersession, retire different-location dirty state. | F6StateTests.testDirtyMonitorReplaysOnceAfterAllTerminalLoadPaths; testDirtyStateRetiresOnDifferentNavigationAndWaitsForActivation | Validation and native watcher delivery still require macOS integration checks. |
| P5-3 | FIXED | Loading/DirectoryReloadCoalescer.swift preserves root validation priority, does not retain unavailable errors across recovery, exposes explicit successful-root-validation acknowledgement. TabReducer requests validation for unavailable errors. | F6CoalescerTests.testUnavailableRecoveryAndRootPriority checks failure recovery, slow-consumer root priority and post-ack recovery through reducer effects. | Adapter must acknowledge successful validation or replace the watch; absent acknowledgement root validation intentionally remains sticky. |
| P5-4 | FIXED | State/TabReducer.swift refresh uses existing restart helper to rerun active searches while refreshing underlying listing. | F6StateTests.testRefreshRestartsCompletedSearchAndRejectsOldResults | Finite search adapters must execute the new startSearch effect. |

Updated existing WindowStore shutdown test to assert both load and monitor handles
are cancelled exactly once, including their generations: refresh now starts both.
No tests deleted or weakened. Integration notes updated in all three owned READMEs.

## Needed changes elsewhere

Composition/validation adapter: return a cancellation handle for refreshPaths;
consume validateNavigation, then call acknowledgeRootValidation() after successful
root validation or replace the watch/coalescer on failure. This wiring is outside
F6 ownership (DEFERRED integration); no public-contract breaking change is required.
macOS 14/Xcode and Opus behavior/compile review remain pending after 22:00 Toronto.

## Verification

Final verification results are recorded below. All commands source
/workspace/toolchains/env.sh and use /tmp/build-F6. Earlier full-suite runs sampled
F7's intentionally failing regression tests during concurrent implementation;
those files were not modified by F6.

- Initial fixed-code full suite: 716 tests, 22 failures (20 assertions/errors in
  concurrent F7 tests, plus 2 expected shutdown-count assertions now strengthened).
- First run_all.sh: all six portable builds, Python checks, static checks, UI
  syntax parsing and coverage reporting passed; 717 XCTest tests, 0 skips,
  13 failures, all confined to concurrent F7RegressionTests. F6 tests passed.
- Explicit `bash scripts/static_checks.sh`: 206 Swift files, 0 errors.
- Owned-scope regression suite: 72 XCTest tests, 0 failures, 0 skips
  (`/tmp/F6-owned.log`), including all six F6 regression tests.
- FINAL `HELM_K11_SCRATCH=/tmp/build-F6 bash scripts/rebuild/run_all.sh`:
  PASS, all six portable module builds; **725 XCTest tests, 0 failures, 0 skips**;
  Python tests, static checks, UI parse and report-only coverage all passed.
  Logs: `/tmp/build-F6/logs`, summary `/tmp/F6-final-verification.log`.
  Concurrent F7 failures resolved without edits outside this lane.
