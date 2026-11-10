<!-- DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04 -->
# F7 — P6 operations and live filesystem fixes

All four source-level findings reproduced in XCTest before their fixes. Initial
red run: nine tests, 20 assertion/unexpected-error failures (`/tmp/F7-red.log`).
The unexpected errors were reads of substituted objects the unfixed executor had
already moved/trashed. No tests were deleted, disabled, or weakened. Changes are
uncommitted drafts, restricted to HelmOperations, HelmFileSystem/Live, their tests,
and this explicitly requested report. No network or external actions were used.

| Finding | Status | Implementation and tests | Residual risk |
| --- | --- | --- | --- |
| P6-1 | DEFERRED in part; portable mitigation FIXED | `Sources/HelmOperations/Execute/ForwardEvidence.swift`, `OperationExecutor.swift`, `Plan/PlanningContext.swift`: seed source kind/token evidence from the manifest; capture existing destination entries with names; record completed copy/move outputs; retain evidence across verification; check after progress/preflight before mutation. Missing artifact metadata stops dependent work with reconciliation while preserving successful primitives. `F7RegressionTests`: source Move/Trash substitution, stage installation, backup Trash, replacement target at progress and after planning, missing metadata, equal-token kind mismatch, unchanged directory Move/Trash and symlink replacement. | Persistent identity, atomic compare/mutate, same-token content substitution, descendant changes and the mutation-to-metadata-read window remain unproven. The exact external contract work is below. Legacy/manual contexts lacking snapshots establish their destructive-source evidence at execution start, not planning time. |
| P6-2 | FIXED | `Sources/HelmFileSystem/Live/IOExecutor.swift`, `LiveFileSystem.swift`: register/check the complete volume footprint under the existing admission lock, recheck at body entry, quarantine all touched volumes on timeout. Copy, move, replacement (including backup), metadata transfer and macOS alias creation supply every accessed volume. `F7AdmissionTests`: gated timeout quarantines A and B while C works; incoming copy into quarantined B refuses before native body entry; Live copy/move/replace/metadata tests prove caller wiring. Existing F5 queued-admission/cancellation tests remain unchanged. | Native calls can still finish after timeout. Quarantine is scoped to a shared executor instance, not process-global. Real macOS cross-volume blocking, alias and Trash behavior require acceptance. |
| P6-3 | FIXED | `Sources/HelmOperations/Plan/OperationPlanner.swift`: retain a folded-name-to-original-spelling map; journal the old target's exact URL separately from the installed incoming URL. `F7RegressionTests.testReplaceUndoRestoresOriginalCaseAndBytes` asserts child names and original bytes; `testNormalizedReplacementUndoRetainsOriginalScalars` asserts decomposed UTF-8 spelling after undo. Existing case-only rename/swap regressions remain unchanged. | Path identity and native race limits from P6-1 still apply. No directory-merge policy was added. |
| P6-4 | FIXED | `Sources/HelmOperations/Execute/OperationResult.swift`: one outcome pass collects successful move/trash sources, one command-source pass builds the original-source set, then intersection. Production extraction exposes an internal visit callback. `F7RegressionTests.testCutCompletionVisitsAreLinear`: 100,000 sources, 100,001 outcomes including failures and an unrelated intermediate; exactly 200,001 loop visits, unchanged completion set. Non-Move commands return empty without visits. | Set operations rely on normal hashed-set complexity. No wall-clock pass threshold. |

## Compatibility and integration

`PlanningContext.existingEntries` is additive with an empty default. The standard
builder fills it, and conflict-policy replanning retains it. Its values use Core's
existing `FileEntry`; no HelmCore signature, protocol requirement, manifest, script,
legacy app file, or other lane's source was changed. The no-follow destination
listing retains metadata; symlink classification is aligned with `entry(at:)`
without enumerating target children. Planning still supports directory operations.

Forward evidence is separate from `.leafOnly` undo. Undo uses its recorded outputs,
not the earlier forward context's stale source snapshots. Verification preserves
its existing `.verificationFailed` outcome for a changed source. A successful
verification cannot adopt a changed stage as newly owned. Public single-volume
IOExecutor callers retain their existing API and cancellation behavior.

Both owned source README files contain integration notes and remaining questions.

## Needed changes elsewhere

P6-1's full native guarantee is DEFERRED. The HelmCore identity/entry owners must
provide a stable, no-follow object identity and a reviewed change/content evidence
contract. The owner of `Sources/HelmFileSystem/Protocol/FileSystem.swift` must then
add a conditional mutation seam (source identity/evidence, destination admission,
and explicit no-mutation versus uncertain completion outcomes), with all conformers
updated together. F7 can implement the Live adapter only after that contract review.
Root path IDs and modification-date/size tokens cannot supply this guarantee.
Complete descendant evidence is needed before relaxing directory undo refusal.

## Verification

Every Swift invocation sourced `/workspace/toolchains/env.sh`, used Swift 6.0.3 in
Swift 5 language mode, and used `/tmp/build-F7`. The required `run_all.sh` uses only
explicit portable build targets. The final run's results are recorded below.

- `HELM_K11_SCRATCH=/tmp/build-F7 bash scripts/rebuild/run_all.sh`: PASS; all
  six portable targets build, **727 XCTest tests, zero failures, zero skips**.
  Python checks, static checks, UI syntax parsing and report-only coverage pass.
  Summary: `/tmp/F7-all-final.log`; detailed logs: `/tmp/build-F7/logs/`.
- Final `bash scripts/static_checks.sh`: PASS, 206 Swift files, zero errors.
- Scoped `git diff --check`: PASS. Only the owned files and this report were edited.
- New F7 regressions total 19 tests. The initial linear-work failure used 1,000
  sources (601,000 visits versus a 2,001 bound); the fixed regression was increased
  to 100,000 sources and passes its 200,001-visit bound.
- Linux does not validate macOS SDK compilation or native Trash, alias, filesystem
  fidelity and cross-volume behavior. UI parsing checks syntax only; coverage is
  report-only. All production changes await Opus review after 22:00 Toronto.
