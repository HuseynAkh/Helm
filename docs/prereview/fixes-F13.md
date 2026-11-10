# F13 — P8 ownership and clean cancellation fixes

DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04.

P8-1 and P8-2 are fixed in the authorized Core Identity, Operations and
FileSystem Protocol/Fake scope. Public additions/defaults are recorded under F13
in `docs/handoff/CONTRACT_INTEGRATION.md`. No existing tests were weakened,
deleted or disabled. No network, external actions, commits, pushes, manifest,
scripts or legacy Helm edits were performed.

## Safety behavior

Undo retains the successful output's identity, kind and token across the journal
boundary. Inverse execution never snapshots the current occupant to acquire
ownership. All initial output evidence is checked before the first inverse,
then revalidated at each primitive's conditional admission. Identity evidence
follows internal move/Trash destinations. Missing journal identity refuses,
including older manually created leaf outcomes; tree undo remains unavailable.

Conditional providers can explicitly report cancelled-before-mutation only when
no effects occurred. The fake does so before admission. Executor read-only
validation no longer falls inside the primitive uncertainty wrapper. Ordinary
cancellation from a potentially started primitive remains quarantining, while
clean cancellation permits a subsequent operation on the same executor. Started
successful work remains journaled, and timeout quarantine is preserved.

## Tests and verification

The two F9 probes were copied into the real XCTest suite as F13ContractTests
before production changes. `/tmp/F13-red.log`: **2 tests, 4 expected assertion
failures**, reproducing both findings. The original assertions remain unchanged.

Additional tests cover same-token/different-identity create/copy/move replacements
before inverse construction and before execution; Replace installed/backup
substitution with zero inverse effects; valid multi-step move and Trash restore
identity remapping; missing journal identity; gated cancellation before admission;
read-only validation cancellation; and ordinary uncertain cancellation quarantine.
Existing K29 tree/kind checks, K34 atomic substitution, F2 started-copy and timeout
controls remain enabled. Initial implementation changed refusal diagnostics;
production code was corrected to preserve those existing test expectations.

Linux Swift 6.0.3, Swift 5 mode, sourced `/workspace/toolchains/env.sh`;
all build products use `/tmp/build-F13`. Final results follow below.

## Remaining limits

Native copy/move/Trash conditional execution still refuses until a reviewed
atomic provider exists. Post-mutation metadata observation is not an atomic
completion receipt; that previously disclosed window is unchanged. Root evidence
cannot prove descendant contents or same-object/same-token edits. macOS 14/Xcode
SDK compilation and behavior preservation require Opus review after 22:00 Toronto.

## Final verification results

- Final F13 selection: **10 tests, 0 failures, 0 skips**,
  `/tmp/F13-final-focused.log`. Focused K29/Recovery compatibility checks also pass.
- Full portable suite: **1001 tests, 1 failure, 0 skips**,
  `/tmp/F13-full-retry.log`. The sole failure is outside this lane:
  `Tests/HelmCoreTests/StateTests/TabReducerTests.swift:180`,
  `testHiddenSettingsAndMonitorEffects` expects `refreshPaths` but receives `[]`.
  F13 does not own or modify Core State/Store or their tests.
- First full attempt hit another lane's transient compile error in
  `F14MonitorOrderingTests`; waited 60 seconds before retry. After the reducer
  assertion failed, waited another 60 seconds before the final runner. No edits
  were made to the concurrent lane's implementation or tests.
- `HELM_K11_SCRATCH=/tmp/build-F13 bash scripts/rebuild/run_all.sh` completed:
  all six portable target builds pass, Python tests/static/UI syntax/coverage
  checks pass; full XCTest remains **1001 / 1 failure / 0 skips** with the same
  monitor assertion. Runner reports 2 failed gates (tests and its failure gate),
  both caused by that one assertion. Log `/tmp/F13-run-all.log`, detailed logs
  `/tmp/build-F13/logs/`. This is **not** a green full-suite acceptance claim.
- Standalone `bash scripts/static_checks.sh`: **222 Swift files, 0 errors**,
  `/tmp/F13-static.log`. Scoped `git diff --check` passes.

The requested zero-failure full-suite gate remains blocked by the monitor lane's
assertion above. F13 production changes and all ten new safety regressions pass.
