# F19 — P16 history admission fixes

DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04.

## Disposition

- **P16-1 VERIFIED / FIXED.** Previously the sole forward terminal API required
  a journal entry, while executor busy returned an unjournaled ID. New Core
  HistoryPreparationFailure and request-matched abortForward settle cancellation
  or planning failure without an operation ID. Core startForward records execution
  binding; abort cannot clear it. The adapter clears forwardCommand exactly once,
  retains the displayed error and preserves redo invalidation.
- **P16-2 VERIFIED / FIXED.** The pre-fix foreign-inverse regression executed and
  failed three assertions: unrelated evidence was accepted, pending was consumed,
  and an incorrect attempt was retained. Both completion methods now require the
  operation ID bound before execution and exact ordered step IDs/definitions.
  Rejected evidence does not change seen IDs, entries, attempts or pending state.
  Forward entries retain the admitted plan rather than supplied replacement metadata.
- **No findings rejected.** Both reports describe actual source behavior.

## Execution boundary

OperationExecutor.execute has an additive asynchronous admission callback. It
creates the journal ID, awaits binding and refuses all filesystem access if the
callback returns false. Existing non-history callers retain the default admission.
Busy/quarantined refusals now create real journal entries with every step marked
notAttempted and invoke the binding callback; no host-manufactured evidence or
arbitrary empty recovery result is needed. Execution cancellation cannot release
a bound history reservation before its result. The running gate is set before
the first suspension for admitted work and is never cleared by a busy caller.

WindowOperationHistory remains value-only: no filesystem, tasks or executor
ownership were added. Hosts must capture the reservation/plan in the admission
closure and retain the task through terminal completion. Bind is an explicit
host handshake, not cryptographic proof against a host fabricating evidence.

## Regression evidence

- API-first P16-1 tests initially failed compilation because preparation abort and
  binding did not exist: /tmp/F19-red.log. That run also exposed a test fixture
  name-type error, corrected to ValidFileName; no runtime P16-1 red is claimed.
- P16-2 existing-API regression failed **1 test / 3 assertions** before the fix:
  /tmp/F19-foreign-red.log.
- Existing tests were migrated to bind before completing; original success,
  refusal, partial-work, stale-request and redo assertions remain intact.
- New tests cover cancellation/planning failure, stale/double abort, subsequent
  forward admission, cancellation after binding, stale/duplicate binding,
  busy executor journaling, rejected admission without mutation, foreign
  success/failure, same-spelling steps with different IDs, malformed empty outcomes,
  and actual independently executed window inverses followed by genuine completion.
- Core tests cover phase guards, bound operation IDs, single-use requests and redo
  invalidation after preparation failure.

## Deferred outside ownership

**DEFERRED — App/UI composition:** at every future forward/undo execution site,
capture the history reservation and exact plan and pass execute's admission closure
to bindExecution. Use abortForward only for preparation errors; after binding,
cancel/await the task and submit its terminal journal/result. Keep the window owner,
text-first undo routing and refresh behavior. No concrete native host was present
in the inspected call-site inventory; direct unbound completion is now refused.

**DEFERRED — macOS/Opus:** type-check with macOS 14/Xcode Swift 5, review compile
correctness and behavior after 22:00 Toronto. Native atomic mutation, atomic output
receipts, tree undo, redo reconstruction, reconciliation UI, durability and history
retention remain inherited limitations, not claims closed by F19.

No network, external actions, commits, pushes, manifest/script or legacy-app edits.
Other lanes' existing edits were preserved, including F22's Core README addition.

## Final verification

Linux Swift 6.0.3, Swift 5 language mode, isolated /tmp/build-F19.

- Explicit HelmOperations target build: PASS (/tmp/F19-build.log).
- Focused suite before the final two-window integration test: **177 tests,
  0 failures, 0 skips** (/tmp/F19-focused-final.log). The final full suite also
  executes that added test; all F19 history tests pass.
- Initial full-suite snapshot: **1179 tests, 28 failures, 0 skips**
  (/tmp/F19-full.log). Failures were in concurrent SearchSessionDriver,
  InspectorReuseRegression, PathPresentation, Sharing and SpringNavigation tests.
  No out-of-lane fixes were made. The subsequent required runner rebuilt the
  updated sources and passed.
- Final full portable suite via
  HELM_K11_SCRATCH=/tmp/build-F19 bash scripts/rebuild/run_all.sh:
  **1185 tests, 0 failures, 0 skips**; all six explicit target builds, Python
  tests, static checks, UI syntax parsing and report-only coverage PASS;
  **0 failed checks**. /tmp/F19-run-all.log and /tmp/build-F19/logs/.
- Separate bash scripts/static_checks.sh: **242 Swift files, 0 errors**
  (/tmp/F19-static.log).
- Scoped git diff --check: PASS. No tests were weakened, disabled or skipped.
  UI parse and Linux compilation do not certify macOS SDK behavior.

Files created by F19: Tests/HelmOperationsTests/HistoryTests/HistoryAdmissionTests.swift
and this report. Modified owned files: Core OperationHistory contracts/reducer,
Operations executor/history adapter and History README, and existing Core/Operations
history XCTest files. Other lanes' source and documentation changes remain theirs.
