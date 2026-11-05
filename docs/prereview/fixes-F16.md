# F16 — Operations cancellation and undo regression fixes

DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04

## Dispositions

- **P12-1 CONFIRMED / FIXED.** Before production edits, the two new gated
  `F16CancellationTests` undo regressions failed with `sourceChanged(/x)` instead
  of cancellation. The second inverse also required reconciliation, stopped the
  recovery plan, and prevented reversal of its completed first move. Evidence:
  `/tmp/F16-red.log` (four tests, eight failed assertions/errors across the two
  undo tests; both admission controls passed). Initial token validation now maps
  `CancellationError` to `.cancelled`; per-step token validation propagates it.
  Other metadata errors still refuse as changed source; uncertain mutation
  cancellation still quarantines. No ownership contract or public API changed.
- **P14 Operations coverage recommendation 1 ADDRESSED.** Existing F13 create,
  copy, move, installed-output and backup substitution cases now compare the
  complete recursive fake inventory, metadata (including identity) and bytes
  before/after refusal. This catches physical effects even with zero reported
  successes. Original assertions remain.
- **P12 complete Replace coverage recommendation ADDRESSED.** A new test builds
  and executes the real planner's Replace copy through backup Trash, substitutes
  that actual Trash URL with equal-token/different-identity data both before
  inverse construction and before execution, and requires unchanged complete
  inventories and explicit refusal.
- **P14 Operations coverage recommendation 3 ADDRESSED.** Gated Move and Trash
  conditional-admission cancellation tests verify unchanged source metadata and
  bytes, exact root inventory, zero recorded Trash origins, zero success, no
  reconciliation, no output evidence, and successful subsequent executor reuse.
- **P14-6 CONFIRMED / DEFERRED (ownership).** The existing two tests cancel both
  worker requests and never submit A/B/C or complete normally. Actual files are
  `Sources/HelmUI/Sheets/BatchRenameWorker.swift` and
  `Tests/HelmUITests/SheetsTests/K34BatchRenameWorkerTests.swift`, outside this
  lane and unavailable to the Operations test target. The UI owner must gate A
  despite cancellation, admit B then C, require B cancellation without execution,
  release A, require C's distinct success exactly once with peak concurrency one,
  and add success/cache, outer-caller cancellation and late-success suppression
  cases with explicit gates and bounded completion watchdogs. No worker relocation
  or manifest dependency change is warranted.
- **P14 recommendation 2 remains additional coverage work:** a second-inverse
  conditional-admission identity-substitution gate is not added here. Existing
  whole-plan substitution controls and per-step cancellation/recovery regressions
  do not claim to establish that exact interleaving. No production bypass is
  asserted by P14 or this report.
- P14-1–5/7 target Core, Persistence or FileSystem Loading tests outside this
  lane; their exact requested changes remain with their owners. No finding is
  rejected or silently marked fixed by a passing unrelated test.

## Verification and boundaries

Linux Swift 6.0.3, Swift 5 mode, `/tmp/build-F16`; all Swift commands sourced
`/workspace/toolchains/env.sh`. The first two regression build attempts encountered
concurrent out-of-lane edits (PropertiesModel and T2PreferenceTests/beforeSave);
each was followed by a 60-second wait and retry, without editing those files.

- `swift build --scratch-path /tmp/build-F16 --target HelmOperations`: PASS.
- Operations suite after production fix: 127 tests, zero failures/skips
  (`/tmp/F16-operations.log`). Final origin-spy assertion is covered in the full run.
- Full portable suite and rebuild/static results recorded below after completion.

No network, commits, pushes, external actions, manifest/script edits or legacy Helm
edits. Shared GitHub memory was not fetched because network use is prohibited.
Only OperationExecutor, two Operations test files and this authorized report were
changed. Mac SDK compilation/behavior and Opus review after 22:00 remain pending.
Native conditional mutations remain unsupported; tree undo remains refused;
post-mutation observation is not an atomic completion receipt.

### Final results

- Full portable XCTest selection: **1,034 tests, 0 failures, 0 skips**
  (`/tmp/F16-full.log`).
- `HELM_K11_SCRATCH=/tmp/build-F16 bash scripts/rebuild/run_all.sh`: **PASS**;
  all six explicit portable builds, **1,035 tests, 0 failures, 0 skips**, Python
  fixtures, static, UI syntax and report-only coverage; **0 failed checks**.
  Concurrent lanes added a test between the two runs. Summary:
  `/tmp/F16-run-all.log`; detailed logs: `/tmp/build-F16/logs/`.
- Standalone `bash scripts/static_checks.sh`: **227 Swift files, 0 errors**
  (`/tmp/F16-static.log`). Scoped `git diff --check`: PASS.
