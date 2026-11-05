# F18 — Properties contents size and test sensitivity

DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04.

No network, external actions, commits, pushes, manifest/script changes or legacy-app
edits. GitHub shared memory was not fetched under the no-network instruction.
Read K1 handoff, contract integration, P14/P15, overriding architecture fixes and
F-050/B-066 reference behavior; inspected the legacy Properties view model.

## Finding dispositions

- **P15-2 CONFIRMED / FIXED.** Package metadata 4096 was previously presented as
  `4096 bytes`. `PropertiesModel.contentsSize` now aggregates InspectorSizeState:
  directories/packages are calculating, regular metadata is final, mixed known
  and unknown contents are partial. Legacy `totalSize`, counts and metadata flags
  retain their meaning; package navigation is unchanged. Properties UI uses the
  contents projection and accepts an explicitly trusted total for the exact
  selection. Completed, partial, unavailable and overflow results stay distinct.
  The former directory qualifier assertion was migrated to an exact known-contents
  byte assertion, not removed. No recursive I/O or session coordinator is added.
- **P14-5 CONFIRMED / PARTIALLY FIXED.** Existing terminal checks remain. Added
  acknowledged pre-EOF progress for batch sizes 1/7/64/512 with exact cumulative
  entries, phases, generation and duplicate-ID replacement metadata. EOF is held
  until both progress assertions run. **DEFERRED:** producer snapshot-build count
  and 100k-single-entry geometric bound need an instrumentation hook immediately
  around `DirectoryLoadPipeline.snapshot` construction, in owned-by-other-lane
  `Sources/HelmFileSystem/Loading/DirectoryLoadPipeline.swift`. Received event
  counts cannot certify this bound because bufferingNewest can discard snapshots.
- **P14-6 CONFIRMED / FIXED.** Worker tests now gate noncooperative A, admit B then
  C on MainActor, require B cancellation without execution while A stays blocked,
  reject A's late success, and require C's distinct success after A exits. Added
  successful cache reuse, caller-task cancellation and subsequent worker reuse.
  Retained separate cancelAll/dismissal and precancelled-cache checks. Gates use
  bounded condition waits and XCTest watchdogs with unconditional release cleanup;
  no millisecond polling. Existing worker implementation satisfies these checks;
  no production worker change was needed.
- **P14-7 CONFIRMED / FIXED with correction to proposed oracle.** Added separate
  full-enumeration, one-batch access-validation and root-read counters. Tests assert
  hit reuse, visibility partitions, sorting cached data, forced reads and
  invalidation. Retained permission-denied checks. Literal “no enumeration” is
  REJECTED: DirectoryLoader intentionally opens an iterator on hits to validate
  read access. Sort is a projection of cached entries, not a separate raw-cache
  partition. Neither behavior should be weakened to match the proposed oracle.
- **P14-1/2/3/4 DEFERRED to F16/F17 ownership.** Store ordering, loading/monitor
  handles, persistence flush and Store FIFO are outside this lane. In particular,
  `T2StoreTests.swift` is ambiguous by filename/location but clearly Store behavior;
  F18 leaves it untouched. P14's additional operations acceptance suggestions are
  outside this lane. No speculative production finding is rejected as “green”.

## Red/green evidence and verification

P15-2 API-first regression fails compilation against the old model (missing
contentsSize), `/tmp/F18-red.log`, then passes with the implementation,
`/tmp/F18-size.log` (2 tests). This is an API-first red, not a claimed failing
runtime assertion. P14 findings are missing-test sensitivity findings; strengthened
tests pass the current implementation and do not imply a production fix.
Focused loading: 23 tests; cache: 12 tests; zero failures. First UI integration
run caught the old directory wording assertions; the replacement is an exact
byte-and-partial-status oracle. Final suite results appended below.

The initial full runner encountered other lanes' in-progress missing beforeSave
and reloadDidFinish seams in Persistence and Loading tests. No outside-ownership
file was changed; the runner is retried after the required 60-second wait.

Native SwiftUI/AppKit SDK compilation and hosted behavior remain unverified.
Future size-session owners must bind trusted recursive measurements to selection
identity before constructing PropertiesViewModel; this patch creates no job API.

### Final verification

- Linux Swift 6.0.3, Swift 5 mode, isolated `/tmp/build-F18`.
- `HELM_K11_SCRATCH=/tmp/build-F18 bash scripts/rebuild/run_all.sh`: PASS;
  all six explicit target builds; full portable XCTest **1034 tests, 0 failures,
  0 skips**; Python fixtures, static checks, UI syntax and report-only coverage
  pass; **0 failed checks**. `/tmp/F18-run-all-final.log`,
  `/tmp/build-F18/logs/tests.log`. Other lanes completed their seams during the
  mandated wait; the retry required no F18 edits to their files.
- Final portable UI/App harness: **58 tests, 0 failures, 0 skips**, including five
  worker tests and two Properties adapter tests; `/tmp/F18-ui-final.log`.
- Final standalone static checks: **227 Swift files, 0 errors**,
  `/tmp/F18-static-final.log`. Scoped `git diff --check`: PASS.
- Counts describe the shared moving worktree, including other lanes' additions.
  Opus review after 22:00 Toronto and Mac SDK validation remain pending.

Created two F18 Properties test files (Core PresentationTests and UI Part3Tests)
and this report. Modified PropertiesModel, PropertiesViewModel, the named
T2Loading/T2DirectoryLoader tests, K34 worker tests and the existing leaf Properties
assertion. No other lane's production source or tests were edited.
