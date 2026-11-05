# F17 — recovery, criteria admission and regression strength

DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04.

Local draft only. No network, commit, push, external action, manifest/script edit or
legacy app edit. Read K1_HANDOFF, CONTRACT_INTEGRATION, P13/P14/P15, architecture
and overriding review contracts, current-state/audit references, and legacy
DirectoryViewModel, FileMonitorService and SearchViewModel behavior. Shared GitHub
memory was not fetched because network access is prohibited.

## Finding decisions

- **P13-1 CONFIRMED / FIXED.** Retry success previously sent both monitorWatching
  and synthetic rootChanged; the latter caused successful validation to discard
  the healthy replacement and reset its three-attempt budget. Keep only the
  existing monitorWatching reconciliation for a fresh native watch. Actual
  rootChanged/volume invalidation still validates and rebinds. The integrated
  real-store regression alternates failed and healthy factories, gates the first
  retry, requires exactly two creations, accepts the fresh listing and proves
  the same replacement receives a later change. Existing three-failure exhaustion
  and finite-stream recovery tests remain. A shutdown-during-backoff test gates
  retry, shuts down the real store, releases retry and awaits watch task exit
  before asserting no additional factory call. The former test's expectation of a
  third factory call was the faulty behavior, not a preservation requirement.
- **P13-2 CONFIRMED / FIXED.** Accepted failed validation consumes a recorded dirty
  invalidation through replayMonitor once. A failure alone remains idle. Replay
  refuses pending validation, degraded monitoring, inactive ownership, loading
  and staged navigation; deferred intent remains available to terminal replay.
  The store regression delivers unavailable → validation → optional rescan →
  failure, requires exactly one follow-up only with rescan, then independently
  asserts recovered contents and ready phase.
- **P15-1 CONFIRMED / FIXED.** Whitespace ends search only when typed filters are
  also empty. Kind-only and tag-only searches preserve the entire query, issue
  start effects, survive Refresh with a newer generation, and exit for truly
  empty input. No Search-owned contract or service code changed.
- **P14-1 CONFIRMED / STRENGTHENED.** Current validation must publish exact fresh
  entries/ready or exact missing failure and advance snapshot identity before
  stale replies are injected. A separate two-reload case holds watch generation
  constant, accepts latest success, then rejects old success AND failure.
- **P14-2 CONFIRMED / STRENGTHENED.** The reload-only cancellation test unwraps
  handles, gates the read after entry, keeps its watch alive, cancels only the
  read, releases it, awaits worker exit and requires zero callbacks. An uncancelled
  read on that same watch must publish the expected child. Watch retirement is
  separately checked by the original validation test. Internal reloadDidFinish
  observes actual task exit; it does not gate/suppress publication or change the
  public API. watchDidFinish similarly acknowledges watch-task teardown. This
  replaces the ambiguous 50 ms inverted expectation.
- **P14-3 CONFIRMED / STRENGTHENED.** Concurrent edits record actual MainActor
  admission order and reopen without a repair flush; task-group errors propagate.
  A separate gate pauses captured revision 1 until revision 2 is saved, releases
  the old flush, and immediately reopens expecting exactly iconSize 140. Internal
  beforeSave is nil by default; flush explicitly captures value and revision
  together before the optional suspension. Existing file actor stale-revision
  rejection remains unchanged. K33PreferenceDocumentTests retains explicit
  failed-write/retry coverage.
- **P14-4 CONFIRMED / STRENGTHENED.** Eight concurrent producers enqueue 1,000
  uniquely named navigation targets each. The injected effect recorder verifies
  every producer's complete ordered load trace, with arbitrary interleaving
  between producers allowed, plus all 8,008 publications. No FIFO implementation
  change is needed.
- **P14-7 CONFIRMED / STRENGTHENED, exact-fix qualification.** Added independent
  root-read, one-entry access-probe and full-enumeration counters. Hits require
  fresh access probes without another full listing; hidden partitions, descending
  sort, cache bypass and invalidation are asserted. Permission refusal remains.
  REJECTED: requiring zero enumerate calls or a separate sort cache partition
  would contradict the actual safe cache contract. DirectoryLoader intentionally
  probes open access with a one-entry iterator and sorts the cached entry array.
  Its Virtual/ source is outside this lane and was not edited. Concurrent F18
  additions in this same test file were observed and preserved, not overwritten.

## Red/green and mutation evidence

- `/tmp/F17-red.log`: nine focused tests, twelve assertion failures before fixes,
  including P13-1 factory count, P13-2 missing follow-up and criteria-only searches.
  An earlier discovery compile issue in the new MainActor tests was corrected by
  making the methods async before this assertion-based red run.
- `/tmp/F17-seams-red.log`: tests initially fail compilation without internal
  save-admission / worker-exit seams; no assertion-based production failure is
  claimed for the existing correct cancellation or revision protection.
- `/tmp/F17-focused.log`: 87 focused tests passed, zero failures.
- Temporary mutations in owned sources were each restored immediately:
  `/tmp/F17-mutation-drop-completions.log` rejects dropping all monitor replies;
  `...-reload-cancel.log` detects a no-op reload cancellation closure;
  `...-stale-save.log` detects removing the saved-revision guard;
  `...-fifo-interior.log` detects swapping interior markers 1/2 while retaining
  every count and terminal marker. All four runs fail XCTest assertions as intended.
  The cache test asserts counters directly; no Virtual/ mutation was performed.

## Remaining boundaries

No assigned finding requires an out-of-ownership production edit. P14-5/6 and
P15-2 belong to other lanes. Search result envelopes/native host wiring remain
previously deferred: the owner must bridge ranked batch truncation/disclosure
through the tab/host boundary. macOS 14 SDK compilation, actual vnode/FSEvents
root replacement and native lifecycle acceptance remain unverified on Linux.
All code awaits Opus compile-correctness and behavior-preservation review.

Final full-suite and runner results follow below.

The first full run (`/tmp/F17-full.log`) executed 1,034 tests and reported eight
failures in two concurrently edited F16CancellationTests cases, all outside F17.
Those files were not edited. The subsequent runner (`/tmp/F17-run-all.log`)
passed 1,034 tests, zero failures/skips and all six builds/checks after the owning
lane's changes. Final verification includes the additional gated shutdown case.

F17 created `Tests/HelmCoreTests/StateTests/F17SearchTests.swift`,
`Tests/HelmFileSystemTests/LoadingTests/F17FileSystemProbe.swift` and this report.
Production edits are limited to TabSearch, TabReducer, TabNavigation,
DirectoryEffectRunner and LocationViewOptionsStore. Six existing test files were
strengthened: F14MonitorOrderingTests, T2StoreTests, F14MonitorRecoveryTests,
K34MonitorAdapterTests, T2DirectoryLoaderTests and T2PreferenceTests.

## Final verification

Linux Swift 6.0.3, Swift 5 mode, isolated `/tmp/build-F17`:

- Final `HELM_K11_SCRATCH=/tmp/build-F17 bash scripts/rebuild/run_all.sh`: PASS;
  all six explicit portable target builds, **1,035 XCTest tests, zero failures,
  zero skips**, Python fixtures, static checks, UI syntax parse and report-only
  coverage; zero failed checks. `/tmp/F17-run-all-final.log`,
  `/tmp/build-F17/logs/tests.log` (261.665 seconds).
- Standalone `bash scripts/static_checks.sh`: **227 Swift files, zero errors**;
  `/tmp/F17-static-final.log`. Scoped `git diff --check`: PASS.
- The final suite includes the gated shutdown regression. Earlier foreign-lane
  failures are superseded by this successful shared-tree run. No Mac SDK/native
  behavior acceptance is claimed; Opus review remains pending.
