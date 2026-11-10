<!-- DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04 -->
# F5 review fixes

All changes require Opus compile-correctness and behaviour-preservation review after
22:00 Toronto on 2026-11-04. No network, commit, push, publication, message, paid render,
ads, or sharing action was performed. The old `Helm/` app, Package.swift, and scripts
were not edited. K31 Loading and K32 Store files were left untouched.

| ID | Status | Files and fix | Regression evidence | Residual risk |
| --- | --- | --- | --- | --- |
| R1-1 | FIXED | `Sources/HelmFileSystem/Live/IOExecutor.swift`: shared executor lock covers registration, begin, and timeout quarantine; registered queued states fail immediately on quarantine. Started states retain their completion semantics. | `F5RegressionTests.testQuarantineRejectsQueuedAndFreshWorkButNotOtherVolumes` failed before the fix (queued body ran), passes after. Deterministic result-state tests cover cancel-before-install, started cancellation, and exactly-once completion. Existing F2 started-copy/journaling regression retained. | Timed-out kernel calls can finish; reconciliation is still required. Per-volume identity depends on caller. Native macOS validation pending. |
| R1-2 | FIXED | `Sources/HelmFileSystem/Tags/CompositeTagStorage.swift`: cancellation check before primary and immediately before unsupported-only fallback write. | Suspended-primary/external-cancellation test failed before the fix with one fallback call and a successful item; passes with zero fallback calls and cancelled outcomes. Pre-cancelled-primary test also failed first. Successful-write cancellation control and existing unsupported/denied controls pass. | Cancellation after primitive entry cannot retract a completed write; preserving that success is intentional. |
| R1-3 | FIXED | `Tests/HelmUITests/PortableRunner/run.py`, `PrereviewTests/F4RegressionTests.swift`: explicit `HELM_UI_SCRATCH`, validated module/object inputs, one root used for compile/link/runtime/typecheck. | New `PortableRunner/test_configuration.py` tests failed before the fix because missing/invalid configuration was ignored; both pass afterward. Configured portable UI suite verifies the valid path. | Caller must build current dependencies into its configured directory. A populated directory alone cannot prove freshness. Mac UI hosting remains unverified. |
| R1-4 | FIXED | `Sources/HelmOperations/Plan/{OperationPlanner,SourcePathIndex,PlannerWork}.swift`, `Journal/OperationJournal.swift`: invocation-local planner counters and actor-isolated journal membership counter at production work sites. | `F5WorkBudgetTests`: counters initially zero caused six runtime assertion failures; production wiring passes. 2,048 selected plus 2,048 unrelated manifest entries exercise containment, selection indexing, manifest visits/aggregation and byte lookups; 4,096 journal outcomes inserted twice enforce one set operation per attempt. Existing functional 100,000-item plan/journal test is unchanged. | Counters measure algorithmic operations, not hash collision cost, path byte length, native I/O, or wall-clock performance. Future implementations must count each comparison/visit if replacing these sites. |
| T1-001 | FIXED (existing source fix verified; test enabled) | `Tests/HelmFileSystemTests/T1ArchiveVolumeAdversarialTests.swift`: removed `T1_RUN_BUGS` gate. `Volumes/PutBackPlanner.swift` already validated every matching original URL in clean HEAD when F5 began; no source change needed. | Both duplicate record orders run in normal XCTest and refuse the remote authority. T1's original failure-first reproduction is documented in `T1-findings.md`; F5 did not revert a committed safety fix to reproduce it. | No Finder-origin inference or restoration execution is added. |

## Integration and scope

`Sources/HelmFileSystem/Live/README.md` documents locking, uncertain native completion,
the internal test seam, and portable UI invocation. Public APIs remain unchanged;
`IOResultState` is internal for deterministic tests. PlannerWork is synchronous and
confined to a planner invocation; no global mutable instrumentation is introduced.
Journal membership diagnostics are actor-isolated. All new Swift tests use XCTest.

The architectural review fixes take precedence. References include B-107 for blocking
I/O, B-039 for partial mutation outcomes, F-052 for transfer preflight, F-059 for journal
behaviour, and the existing rebuild's Put Back/tag annotations. The current-state audit
uses F-060 for permanent delete and F-029 for stars; inherited newer tag/Put Back labels
should not be read as proof that those were native legacy features. Relevant legacy
`FileSystemService` and `UndoService` were read only.

## Verification and deviations

- Initial F5 test authoring used nonexistent `TagEdit.removeAll` / outcome properties;
  corrected to the actual add-tag/failure API before the meaningful failure-first run.
  One overlapping early build saw the test file change; subsequent builds were serialized.
- The unmodified runner's failure-first configuration tests unexpectedly succeeded by
  using its hard-coded `/tmp/build-F4`, rebuilding its portable UI artifacts. This was
  an accidental scratch-isolation violation, not accepted verification evidence. The
  runner is now explicitly configured, and subsequent verification uses `/tmp/build-F5`.
- A concurrent K32 `WindowStoreTests.swift` compile error was left untouched; F5 waited
  60 seconds and retried successfully, as required.
- Failure-first logs: `/tmp/F5-red.log`, `/tmp/F5-harness-red.log`,
  `/tmp/F5-budget-red-runtime.log`. Focused green log: `/tmp/F5-focused.log`.

Final verification results are recorded below after the complete run.

## Needed changes elsewhere

No additional source/manifest/script changes are required for these five findings.
Opus review and macOS 14/Xcode compilation/runtime acceptance remain outstanding.
