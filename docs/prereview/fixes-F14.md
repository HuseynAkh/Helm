<!-- DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04 -->
# F14 — P9 monitor ordering and recovery

All code is DRAFT pending Opus compile-correctness and behavior-preservation review after 22:00 Toronto, 2026-11-04. No network, external actions, commits, pushes, manifest/script changes, or legacy app edits. Persistence is unchanged. CONTRACT_INTEGRATION.md is not owned by F14; additive integration contracts are recorded here.

## P9-1 — repaired at reducer/store admission

`TabState.monitorWorkGeneration` is the shared monotonically advancing reload/validation identity. Reducer effect admission advances it; completion and watch retirement invalidate it. WindowStore captures that identity when running existing `refreshPaths`/`validateNavigation` effects and converts their legacy success/failure callbacks to `monitorWorkCompleted(watchGeneration, request: workGeneration, Result)`. Reducer rejects obsolete success and failure before publication, including callbacks already queued or delivered despite cancellation. Effects retain their existing public signatures, and DirectoryEffectRunner callers continue compiling. Adapters must return their callbacks through the supplied WindowStore callback; directly injecting untagged legacy actions bypasses work ordering and is only a compatibility seam.

Validation cancels ordinary reload work as well as prior validation. Ordinary events during validation retain dirtiness without replacing validation. Failed validation retains validation intent for the next event. Successful validation rebinds the watch with a fresh watch generation, preventing a vnode monitor from remaining attached to an old object. Startup acknowledgement reconciles again after startup to close the read-to-watch observation gap. Staged navigation and foreground loading retain reconciliation intent.

Regression `F14MonitorOrderingTests` holds callbacks for R→V→V-result→R-result, tests successful and failed V, delivers both obsolete success and failure, and checks phase, entries and snapshot identity. It also checks cancellation and validation priority. Before implementation: **2 tests, 7 assertion failures** (`/tmp/F14-red-retry.log`). No tests weakened or deleted.

## P9-3 — bounded recovery and surfaced degradation

DirectoryEffectRunner retires the matching failed/ended watch after cleanup. Each retry creates a fresh monitor and coalescer. Three attempts total per monitor lifetime, with default 250 ms and 500 ms delays, prevent recursive unlimited startup failure. Successful retry acknowledges startup and requests root reconciliation. Exhaustion leaves no stopped watch registered and publishes a failed snapshot with `monitorDegraded == true`; foreground refresh or reactivation can explicitly retry. Cleanup and cancellation use lifetime/attempt identities so they cannot retire a replacement. Reload completion verifies the current watch identity before sending.

New Core actions: `monitorStopped(Generation, LoadError, retrying: Bool)`, `monitorWatching(Generation)`, and `monitorWorkCompleted(Generation, request: Generation, Result<PresentationSnapshot, LoadError>)`. New defaulted state values: `monitorWorkGeneration`, `monitorDegraded`; validation priority bookkeeping is internal. New optional/defaulted runner initializer inputs: `monitorFactory` and `retryDelay`, providing deterministic failure injection without editing FileSystem protocols, Fake or Live. No protocol change is required.

FallbackMonitor now finishes/stops when its selected event source ends, allowing the adapter to observe termination. Darwin vnode rename/delete/revoke flags emit rootChanged; callback identity prevents delayed events from addressing a replacement source. FSEvents already emits rootChanged and uses WatchRoot; the shared successful-validation rebind recreates its canonical-root context too.

`F14MonitorRecoveryTests` covers failed-first startup then recovery, cleanup, subsequent events, three-failure exhaustion/record retirement, finite-source replacement, and real WindowStore/DirectoryLoader/InMemoryFileSystem recovery through successful snapshot publication, fresh generation/watch and a later changed listing. Before the additive API existed the recovery tests failed compilation (`/tmp/F14-recovery-red.log`). The tests do not claim native macOS execution.

## Verification and remaining limits

Linux Swift 6.0.3 / Swift 5 language mode; isolated `/tmp/build-F14`. Initial builds encountered concurrently edited Operations and T3 test files; those files were left untouched and verification retried after waiting. Focused F14/F10/F6/K34 suite passed **25 tests, 0 failures** before the final post-start reconciliation refinement. Final full-suite and runner results follow below.

macOS 14/Xcode type checking and actual FSEvents/vnode replacement behavior remain for Opus/Mac acceptance. Exhausted retries deliberately remain visibly degraded until explicit refresh/reactivation; this is bounded recovery, not indefinite retry. Hosts must expose the failure/degraded state; native host wiring is outside this lane. Retry delays are injected and must honor cancellation for prompt teardown. No claims about a native monitor whose start() silently reports success without establishing observation are made.

The first full run executed 1001 tests with one expected contract mismatch: `TabReducerTests.testHiddenSettingsAndMonitorEffects` assumed an ordinary reload could supersede pending validation. Its original changed-path reload assertion is retained after an explicit successful validation completion. Added assertions require deferral while pending and a fresh monitor plus reconciliation after completion; no assertion was removed or relaxed. Final verification uses this stronger sequence.

A subsequent full run exposed a startup/validation race in existing `K34MonitorAdapterTests`: the missing-root polling watch can retire before the simultaneously admitted validation read throws. Suppressing that error by adapter watch identity left the direct caller without its terminal error. The adapter now always returns an uncancelled read failure; WindowStore's captured request identity still rejects it after retirement/supersession. Success remains guarded by the live watch identity. The existing K34 failure assertions are unchanged. Two intermediate 1001-test runs and the first run_all invocation reported this single failure; the final runs below supersede them.

### Final verification

- `swift build --scratch-path /tmp/build-F14 --target HelmFileSystem`: PASS (`/tmp/F14-build.log`); final runner rebuilt all six explicit portable targets successfully.
- Final focused F14/K34 adapter selection: **9 tests, 0 failures** (`/tmp/F14-focused-last.log`).
- `swift test --scratch-path /tmp/build-F14`: **1001 tests, 0 failures, 0 skips** (`/tmp/F14-full-verified.log`).
- `HELM_K11_SCRATCH=/tmp/build-F14 bash scripts/rebuild/run_all.sh`: **PASS**, six portable builds, **1001 tests / 0 failures / 0 skips**, Python checks, static checks, UI syntax parse and report-only coverage; **0 failed checks** (`/tmp/F14-run-all-verified.log`, `/tmp/build-F14/logs/`).
- Final standalone `bash scripts/static_checks.sh`: **222 Swift files, 0 errors** (`/tmp/F14-static-verified.log`). Scoped `git diff --check`: PASS.
- Created two regression test files and this report; changed seven production files and extended one existing reducer test. All changes remain local/uncommitted drafts. Mac SDK/native behavior and Opus review remain open as described above.
