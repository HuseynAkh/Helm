<!-- DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04 -->
# F4 fixes — Astra (codex)

All four P4 findings were reproduced before production edits. Changes are drafts
pending Opus compile-correctness and behaviour-preservation review after 22:00
Toronto on 2026-11-04. No Core/public contract or manifest changes were made.

| ID | Status | Files | Regression coverage | Residual risk |
| --- | --- | --- | --- | --- |
| P4-1 | FIXED | `Sources/HelmUI/SearchBar/SearchBarModel.swift`, `Part3-README.md` | `F4RegressionTests.testSearchAdapterTypechecksAgainstCurrentCore` failed with missing SearchDomain before the edit; passes with HelmCore.SearchScope. Existing `Part3AdapterTests.testSearchScopesAndLiteralText` and missing-folder tests execute successfully. | Actual SwiftUI target remains undeclared; macOS SDK compilation pending. |
| P4-2 | FIXED | `Sheets/BatchRenameViewModel.swift`, `BatchRenameEvaluation.swift`, `BatchRenameSheet.swift` | `testValidationPresentationIsBoundedWithoutDiscardingIssues` failed with 100 displayed issues before the edit. Existing preview-limit test strengthened with exact evaluation counts. `testEditsInvalidateCopiesAndRejectObsoleteCompletion` checks every editable field and an older completion delivered after the new one; `testConcurrentReadsShareOneEvaluation` checks shared memoization. | Hosted 100k-selection timing remains macOS work. A detached synchronous planner already started is allowed to finish; obsolete results cannot publish or enable Rename. Compatibility getters are synchronous; the sheet only consumes completed evaluations. |
| P4-3 | FIXED | `Sources/HelmApp/SessionRestorePlan.swift`, `Tests/HelmAppTests/FrameIdentityTests.swift`, app Linux runner | `testRepairsReserveLaterValidFrameIdentities` failed for both reported sequences before the fix; now asserts original later names, uniqueness and unchanged tab ownership. | Actual AppKit saved-frame placement remains macOS work. |
| P4-4 | FIXED | `Operations/OperationRowModel.swift`, `OperationDetailCache.swift`, `OperationDetailsView.swift`, `OperationsPanel.swift` | `testCollapsedDisclosureDoesNotReadEagerDetails` failed both eager-render source assertions before the edit. `testLargeOperationDetailsAreLazyBoundedAndCached` exercises 100,001 outcomes, zero collapsed formatting, repeated reads, 50-row pages, final partial page and invalid indices. Existing failure/path wording tests preserved. | Source regression is explicitly structural, not a hosted UI measurement. Retain immutable completed row models across other operations' progress to retain their cache. Expansion/pagination accessibility and macOS frame-time/memory measurement remain pending. |

## Evidence and verification

Before fixes, the portable package baseline ran **492 tests, 0 failures**.
The first standalone UI/app run executed 38 tests and failed nine assertions:
six from the four P4 regressions (two frame assertions, one compilation assertion,
one issue-limit assertion, two eager-disclosure assertions), two from duplicate
Swift type metadata in the initial dynamic-library harness, and one existing
sidebar regression. Logs: `/tmp/F4-before.log` and `/tmp/F4-baseline.log`.
No existing test was removed or weakened.

The harness now links dependencies exactly once through a shared library; the
existing concrete-store type assertions pass unchanged. The existing sidebar
`testDeepestAncestorUsesPathBoundariesAndIgnoresStarredRows` exposed Core's expanded
starred candidates. A local SidebarModel fallback preserves the documented UI
bookmark/favorite/device/trash policy without editing Core. Existing exact-match,
path-boundary, virtual-root and trash tests all pass.

Final verification:

- `source /workspace/toolchains/env.sh`; Swift 6.0.3, Swift 5 language mode.
- `HELM_K11_SCRATCH=/tmp/build-F4 bash scripts/rebuild/run_all.sh`: six portable
  target builds, full portable XCTest suite, Python checks, static checks, UI
  syntax parsing and report-only coverage all passed. **520 tests, 2 skipped,
  0 failures; 0 failed checks.** Parallel lanes added tests after the baseline.
- `python3 Tests/HelmUITests/PortableRunner/run.py`: **50 tests, 0 failures**,
  including actual portable UI/app modules and all portable test classes.
  SettingsBindingsTests and ContentNativeAdapterTests require Apple frameworks
  and are excluded from this Linux harness, not removed from the repository.
- `bash scripts/static_checks.sh`: zero errors. `git diff --check`: clean.
- Reproducible runner is in the owned tests directory; build artifacts and logs
  are under `/tmp/build-F4` or `/tmp/F4-*.log`.

## Integration and needed changes elsewhere

The manifest owner must declare HelmUI, HelmApp and their XCTest targets on macOS,
exclude UI `PortableRunner` and app `LinuxRunner` from normal test targets, and
compile/run them with the macOS 14 SDK. Linux parse checks are not typechecking of
SwiftUI or evidence of frame-time performance. Opus should verify the sidebar's
legacy highlight policy against Core's newer starred-selection policy. No shared
API change is necessary for these four fixes.

The sheet owns its 150 ms pure-computation debounce and revision gate. Host still
owns occupancy refresh before execution, actual mutation, cancellation/dismissal,
and retained operation-row lifetime. UI/main and sheet README integration notes
were updated; app README documents reserved-name restoration.

No network, commits, pushes, publication, messages, paid renders, sharing changes
or deletion were performed.
