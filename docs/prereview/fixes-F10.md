<!-- DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04 -->
# F10 — P9 store/loading fixes

All changes are drafts pending Opus compile-correctness and behavior-preservation review after 22:00 Toronto, 2026-11-04. No network, external actions, commits, pushes, manifest/script edits, or legacy app edits. Persistence had no new P9 finding and is unchanged.

## Dispositions

### P9-1 — DEFERRED (confirmed; public-contract change)

Reverified `WindowStore.execute`: `monitorValidations` and `monitorReloads` cancel only their own class. `DirectoryEffectRunner.reload` sends both classes with only the watch generation; `TabReducer` admits both with that same generation. Thus R→V→V-result→R-result still accepts stale R, including after V fails. Cancellation alone cannot reject an already queued reply. No claim of repair or rejection.

Exact needed change: Core `TabAction` success/failure replies and `TabEffect.refreshPaths`/`validateNavigation` must carry a shared per-tab monitor-work request identity in addition to watch generation. Core state must allocate/retire this identity at effect admission, reject obsolete success AND failure replies, and preserve root-validation priority over ordinary reloads. Store must cancel superseded work across both classes; FileSystem adapters and their callers/tests must propagate identities. This is a public-contract change prohibited in F10 even though the Core declaration files are in State. The integration owner must add gated success/failure R→V→V-result→R-result tests. Residual risk: reverse-freshness publication remains possible.

### P9-2 — FIXED

Files: `Sources/HelmCore/State/{TabState,TabNavigation,TabReducer}.swift`; `Tests/HelmCoreTests/StateTests/F10MonitorStateTests.swift`.

Staging retains committed-location invalidations. Matching monitor events and snapshots during staging mark the retained listing dirty without publishing old snapshots. Root-change/unmount/unavailable events retain validation priority. Both pre-commit failure paths replay exactly one reconciliation, without changing history. Successful different-location commit clears old dirtiness and validation intent with the retired watch. Retired watch generations remain rejected.

Regression: `testFailedStagingReconcilesRetainedDirectoryExactlyOnce` covers preexisting dirtiness and changes received during staging, both loadFailed and failed-snapshot terminals; `testStagedRootInvalidationTakesPriorityAndRetiredEventsStayRejected` covers priority/generation rejection. Existing F6 successful-commit coverage remains unchanged. Before fix, the four new state tests executed with seven assertion failures (`/tmp/F10-state-red.log`). Residual risk: validation/reload identity ordering remains P9-1; failed monitor startup remains P9-3.

### P9-3 — DEFERRED (confirmed; public-contract/platform change)

Reverified `DirectoryEffectRunner.startMonitor`: installs `watches[tab]` before `start`, catch sends unavailable, cleanup finishes coalescer and stops monitor without retiring that record. `DirectoryReloadCoalescer.acknowledgeRootValidation(revision:)` explicitly refuses stopped instances. A recovered read therefore cannot publish; finite completion also leaves ownership stale. Existing K34 validation tests do not simulate failed startup. No retry fix is claimed.

Exact needed change: add Core monitor lifecycle/termination action(s), with generation and bounded recovery state, so startup/finite-source failure retires ownership and successful independent root validation requests a fresh monitor/coalescer with a new generation. Separate validating the location from acknowledging a live watch; do not clear failure until replacement startup succeeds. Adapter cleanup must retire only its matching watch, never a replacement. Native vnode/FSEvents root-object replacement must be verified and updated in `Sources/HelmFileSystem/Monitor` (outside this lane). Tests must inject first-start failure, await cleanup, allow root recovery, assert fresh startup and subsequent delivered changes, and bound repeated failures. Public actions and native monitor changes require integration-owner work. Residual risk: automatic recovery can remain stopped until manual refresh/reactivation.

### P9-4 — FIXED

Files: `Sources/HelmCore/State/TabReducer.swift`; the F10 state test file; `Tests/HelmFileSystemTests/LoadingTests/F10SnapshotWorkerTests.swift`.

Deactivation marks the committed listing dirty. Activation emits startMonitor before reconciliation; ongoing loads/staged navigation retain the request until terminal load handling. Different-target commit retires the old request. Tests cover clean activation, deferred foreground-load completion and a real WindowStore/DirectoryEffectRunner/InMemoryFileSystem sequence: old entry removed and new entry created while inactive, with no post-activation mutation/event injected. The new snapshot contains only the new ID. Residual risk: native platform watch startup remains unverified and P9-3 still applies.

### P9-5 — FIXED (off-main construction/duplicate sorting)

Files: `Sources/HelmFileSystem/Loading/{DirectoryEffectRunner,MonitorSnapshotWorker}.swift`; `Tests/HelmFileSystemTests/LoadingTests/F10SnapshotWorkerTests.swift`.

An internal serial actor builds immutable PresentationSnapshot indexes from DirectoryLoader's already-sorted input, using the existing sorted-input initializer. The reload directly awaits this worker; no detached/unowned task is added. One construction executes at a time per runner; cancelled queued calls refuse before building. Cancellation is checked before/after construction and again on MainActor before dispatch. Existing store cancellation handles own reload lifetime.

Tests assert construction is off the main dispatch queue even when called from MainActor, supplied order is retained (no second sort), indexes/root counts are correct, pre-cancelled work never builds, and cancellation while a gated build is active discards its result. Existing K34 adapter cancellation/retired-watch tests remain. Worker tests first failed compilation because MonitorSnapshotWorker did not exist (`/tmp/F10-worker-red.log`); the actor-placement defect itself was source-confirmed, not timed. Residual risks: synchronous indexing cannot be interrupted mid-initializer, but runs off the UI actor; the generic sorted-input constructor still allocates O(n). Complete queued-reply request identity protection is explicitly deferred as P9-1. A 100k-directory macOS profile and native SDK build remain required; no Linux timing threshold is used as responsiveness evidence.

## Verification

Toolchain: `/workspace/toolchains/env.sh`, Linux Swift 6.0.3, Swift 5 language mode, isolated `/tmp/build-F10`. Final results recorded below after completion. No tests weakened, deleted or skipped by F10.

- Initial focused state regression: **4 tests, 7 assertion failures** before production edits. Worker regression: compile failure for the missing internal worker before implementation.
- Focused F10/F6/K34 run: **13 tests, 0 failures**; subsequent gated cancellation and store integration coverage are included in the final full runs.
- `swift build --scratch-path /tmp/build-F10 --target HelmFileSystem`: **PASS**, including Core; `/tmp/F10-build.log`.
- Final `swift test --scratch-path /tmp/build-F10`: **889 tests, 0 failures, 0 skips**; `/tmp/F10-full-final.log`. Eight tests are new F10 regressions. Counts include concurrently integrated work from other lanes.
- `HELM_K11_SCRATCH=/tmp/build-F10 bash scripts/rebuild/run_all.sh`: **PASS**, six explicit portable builds, **889 tests / 0 failures / 0 skips**, Python checks, static checks, UI syntax parse and report-only coverage; **0 failed checks**. Summary `/tmp/F10-run-all.log`, detailed `/tmp/build-F10/logs/`.
- Standalone `bash scripts/static_checks.sh`: **222 Swift files, 0 errors**; `/tmp/F10-static.log`. Scoped `git diff --check`: **PASS**.
- macOS 14/Xcode type checking, 100k-directory profiling, and Opus review remain outstanding. No public contract changed. The two deferred findings remain open and are not masked by passing tests.
