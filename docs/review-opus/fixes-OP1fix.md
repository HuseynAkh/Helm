DRAFT: pending review, 2026-11-05

# OP1fix: Linux verification and minimal test repairs

All changes remain pending Opus spot-check. This lane changes three existing test files and creates this report; it changes no production code, package manifest, scripts, or legacy app files. No tests were deleted, skipped, or added. No network, commits, pushes, or external actions were used.

## Lane file inventory

Modified:
- `Tests/HelmOperationsTests/RecoveryTests.swift`
- `Tests/HelmCoreTests/StoreTests/K34MonitorLifecycleTests.swift`
- `Tests/HelmCoreTests/StateTests/OP1MonitorAndHistoryTests.swift`

Created: `docs/review-opus/fixes-OP1fix.md`. Existing OP1 production changes and its original report were left untouched.

## Finding decisions

| Finding | Disposition | Evidence and repair |
|---|---|---|
| RecoveryTests.testOnlyOSManagedSymlinkAncestorsPassTheWalk: fixture throws collision | FIXED (test fixture) | InMemoryFileSystem.key uses standardizedFileURL; Foundation folds `/private/tmp` into `/tmp`, so constructing the link collides with the target before OperationExecutor runs. Use `/managed-temp-target` as the fake target. Keep `/tmp` and `/tmpx` as the tested ancestor spellings. Strengthen the managed-path assertion from merely “not invalidPlan” to the exact downstream fake insertion refusal, mapped through OperationError.other. The fake deliberately does not insert through symlink parents; this checks admission by the ancestor walk, not successful native mutation. The lookalike must still return invalidPlan, and the separate arbitrary-symlink safety test is unchanged. |
| K34MonitorLifecycleTests.testValidationHandlesCancelledByRefreshAndShutdown: one cancellation versus two | FIXED (test sequencing); production-regression interpretation REJECTED | OP1 FB2-8 explicitly requires root events during foreground loads to defer validation. TabReducer.rootChanged checks monitorIsBusy; TabNavigation.replayMonitor starts the deferred work after acceptLoad finishes. The old test left refresh loading forever and expected shutdown to cancel a validation that should never have started. Complete the refresh before shutdown; assert that only one validation started while loading, validation was deferred, and the second validation starts and is pending after completion. Preserve both original cancellation assertions (one after refresh, two after shutdown). Restoring the former production behavior would break the new deferred-start assertion. |
| OP1MonitorAndHistoryTests: four URL spelling failures across three tests | FIXED (test fixture) | TabReducer.stage uses Location.canonicalNavigationLocation, which constructs standardized directory URLs with isDirectory: true (FB2-3, F-005/B-019). The test helper now invokes that same canonicalization for history entries, navigation targets, and expectations. All history order, step count, pre-commit preservation, and failure assertions remain. Production is consistent; changing Location equality or navigation would be inappropriate. |

Three failure groups fixed; zero scoped groups deferred. The production-regression interpretation of the lifecycle failure is rejected for the reason above, not treated as permission to weaken cancellation coverage.

## Red-first evidence

Before edits, `swift test --scratch-path /tmp/build-OP1fix --filter 'RecoveryTests|K34MonitorLifecycleTests|OP1MonitorAndHistoryTests'` exited 1: **28 tests, 6 failures, 1 unexpected**. The broad RecoveryTests match also includes five F14MonitorRecoveryTests. Log: `/tmp/OP1fix-before.log`.

The initial repair run had **28 tests, 1 failure, 0 unexpected**: the strengthened recovery assertion needed the existing executor's String(describing: FileSystemError) wrapper. That assertion was corrected to use the same error mapping, without changing production. Log: `/tmp/OP1fix-after.log`.

## Verification

Toolchain: Linux Swift 6.0.3, sourced from `/workspace/toolchains/env.sh`. Python uses PYTHONDONTWRITEBYTECODE=1 to avoid writing bytecode into unowned scripts directories.

- `swift build --build-tests --scratch-path /tmp/build-OP1fix`: exit 0, zero compiler errors. Log: `/tmp/OP1fix-build.log`.
- `swift test --scratch-path /tmp/build-OP1fix`: exit 0, **1,313 tests, 0 skips, 0 failures, 0 unexpected**. Log: `/tmp/OP1fix-full.log`.
- `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts/rebuild -p 'test_*.py'`: exit 0, **15 tests passed**. Log: `/tmp/OP1fix-python.log`.
- Affected classes in the full run: RecoveryTests **9**, K34MonitorLifecycleTests **2**, OP1MonitorAndHistoryTests **12**, all passing. Other new OP1 classes: EffectRunner **3**, MonitorSelection **3** (one additional macOS-only test is excluded by compilation), TypingPolicy **6**, all passing. No skips were introduced.

- Initial aggregate `HELM_K11_SCRATCH=/tmp/build-OP1fix bash scripts/rebuild/run_all.sh`: exit **1**, exactly **1 failed check out of 14**. All six module builds passed; XCTest **1,313 / 0 skipped / 0 failures**; rebuild Python **15 passed**; static Python **4 passed**; static guard fixtures **8 passed**; UI syntax **46 files / 0 failures**. Only `core-type-names` fails, naming exactly **DropSession, DropOperation, DropProposal, ToolbarItem**. Coverage is report-only: **567 catalogue IDs, 565 ledger rows, 14 gaps**. Log: `/tmp/OP1fix-run-all.log`; detailed logs: `/tmp/build-OP1fix/logs/`.

- Signal-11 check: ran `swift test --filter 'Helm(Core|FileSystem|Persistence|Operations|Search|TestKit)Tests' --scratch-path /tmp/build-OP1fix-clean` **three times**, all exit **0**. The scratch directory did not exist before the first run; later runs reused its clean-built artifacts. Each run executed **1,313 tests, 0 skips, 0 failures, 0 unexpected** (**3,939 test executions** total). **Zero signal-11 crashes or other crashes recurred.** Logs: `/tmp/OP1fix-clean-1.log`, `/tmp/OP1fix-clean-2.log`, `/tmp/OP1fix-clean-3.log`. This is nonrecurrence evidence, not proof of the historical crash cause.

- Final aggregate rerun **after all three crash checks** used the same `HELM_K11_SCRATCH=/tmp/build-OP1fix bash scripts/rebuild/run_all.sh` command: exit **1**, **13 checks passed, 1 failed**, solely the same four Core names. XCTest again **1,313 tests / 0 skips / 0 failures**; Python **15 + 4 passed**, static fixtures **8 passed**, UI parse **46 files / 0 failures**, coverage **14 report-only gaps**. Log: `/tmp/OP1fix-run-all-final.log`. Detailed logs in `/tmp/build-OP1fix/logs/` now represent this final run.
- `git diff --check`: exit **0**, no whitespace errors. No concurrent-file build retries were necessary.

## Remaining limits

- macOS/Xcode compilation and native symlink behavior remain unverified; Linux fake coverage does not establish native mutation correctness.
- Coverage reports 14 existing gaps; this test-repair lane does not close feature acceptance.
- The existing Core type-name collision decision remains with the owner. This lane does not rename public APIs or edit the guard.
- Three clean-scratch repetitions can report recurrence or nonrecurrence, but cannot prove OP1's stale incremental witness-table hypothesis. Preserved-binary symbol comparison is outside this requested check.
- Other OP1 owner decisions remain as recorded in `docs/handoff/OWNER_DECISIONS_NOTE.md`.
