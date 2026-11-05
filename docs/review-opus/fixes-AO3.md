# DRAFT: pending review, 2026-11-05

AO3 changes require Opus compile-correctness and behaviour-preservation spot-check.
Only assigned Operations/FileSystem source and matching tests were edited, plus
this report. No network, commits, pushes, publication, sharing changes, paid work,
or external actions. New disk fixtures are retained. The old Helm app was read
as a behaviour reference and not edited. No HelmCore or other lane files were edited.

## Finding dispositions

| Finding | Disposition | Evidence and limits |
| --- | --- | --- |
| O1-3 | FIXED | Replacement now copies to a short destination-local stage, verifies it, trashes the original in place, then installs the stage. The original Trash leaf and recorded origin retain their spelling. Updated every replacement failure boundary and retained payload/inverse checks. A failed install retains the stage and real-name Trash original; native mutation still refuses under O1-1. |
| O1-4 | FIXED | Planner tracks folded targets produced by this selection separately from pre-existing names. Replace against an earlier selected output blocks the entire plan. Regression starts with an empty destination and repeated selected basenames. |
| O1-7 parts 2–3 | FIXED | IOExecutor has explicit read-only admission and conservative mutation admission. Timeout records each still-running body's entire volume footprint. Read quarantine clears only when all timed-out bodies return and no mutation latch remains. `clearQuarantine(volume:)` refuses while a timed-out body remains; mutation latches otherwise require this explicit post-reconciliation call. Live metadata/capability reads, enumeration, volume and cloud reads use the read lane. Existing mutation callers retain conservative defaults. Gated tests cover two timed-out reads, attempted early clear, mutation persistence and recovery. Part 1 from AO2 remains intact. |
| O1-7 part 4 | FIXED watchdog/seam; DEFERRED native copy callback | Monotonic inactivity deadlines reset on progress, atomically against expiration. Enumeration batches report progress. `runWithProgress(volumes:)` supports mutation/copy callbacks and retains full-footprint quarantine. A progressing body exceeding its initial deadline succeeds. FileManager copy has no byte-progress callback, and native conditional copy remains O1-1's owner decision; this patch does not invent that implementation. Mount-key discovery outside configured roots remains the excluded FB1-2 judgement item. |
| O1-10 | FIXED assigned caches; DEFERRED ancestor caching | New per-execute ExecutionCache holds folded occupied names, sensitivity by parent path and a once-built ancestor-path manifest index. Success updates the actual chosen destination and removes moved/trashed sources. Safe exclusive collisions refresh names before retry. Default childNames enumerates without resolving symlink targets. Counting spy: 128 creates in one parent use one listing; a second execute uses a fresh listing; one injected exclusive collision uses exactly two listings. Every ancestor is still read for every step. Caching ancestor verification is explicitly deferred because it removes symlink/replacement-race checks. These call-count tests do not claim the full architecture wall-time budget. |
| O1-11 | FIXED internal evidence | Forward observations and executor token/kind working maps use `url.path`, never standardized paths. Unknown observations refuse. Execution-start source snapshots are restricted to contexts with both manifest and existing-entry evidence empty; partial contexts cannot adopt replacement occupants. Portable slash-bearing directory and partial-context tests pass. A native-directory slash test is guarded for macOS and remains unexecuted here. Public URL-keyed input value contracts are retained; no HelmCore/API ownership redesign. |
| O1-12 | DEFERRED | Canonicalizing production roots belongs at the navigation/planning boundary and changes path/ItemID policy, involving HelmCore and excluded FB1-11. The proposed OS-symlink allowlist is an alternative owner decision. Ancestor refusal remains unchanged. |
| O1-13 | FIXED already by AF1 | Actual MetadataReader condition is `isAliasFile == true && type != .typeSymbolicLink`. AF1DarwinRegressionTests already cover file/directory/dangling links and Finder alias. No duplicate production change; Darwin execution still required. |
| O1-15 | FIXED | Source retirement now validates the destination's recorded ownership after the copy verifier. Progress-hook regression replaces the verified destination with equal-size different bytes; source remains and execution reports sourceChanged(destination). This is identity revalidation, not content hashing. |
| O1-16 | FIXED | Admission receives `(OperationID, OperationPlan)` from the executor, including busy refusals. Owned history callbacks forward that supplied plan. New regression checks the exact executing plan and refusal; existing weakened-inverse and binding tests remain passing. |
| O1-17 | FIXED | Progress precedes admission in execute's parameter list. Existing unlabeled progress closures compile without deprecated backward-match warnings. |
| O1-18 | FIXED host-duty documentation; DEFERRED error/reset integration | History README explicitly requires matching abort after rejected binding. Adding a quarantined error requires HelmUI's exhaustive mapping and recovery UX outside ownership. OperationExecutor's timeout latch remains conservative, without a unilateral reset. IOExecutor's separate reconciled-volume reset is covered by O1-7; it does not reset an OperationExecutor. |
| O1-19 | FIXED | Removed default origin store from OperationExecutor and default empty origins from beginUndo. All owned callers explicitly supply their stores/maps; existing shared-store Trash/replacement undo fixtures retain their shared instance. This is compile-time dependency enforcement, not automatic loading of persistent origins. No source host currently constructs these actors. |
| O1-20 | DEFERRED | Hashing versus size-only source retirement needs an owner decision. Sidecar exclusions require reliable per-volume extended-attribute capability policy, which the current contracts do not supply. No verifier rule weakened. |
| O1-21 | DEFERRED | ChangeToken is HelmCore-owned; populating child count needs an agreed enumeration/cost contract. Changed-output override and dropping refused entries require owner-approved history actions and confirmation UX. Existing conservative leaf/tree checks remain. |
| O1-22 | DEFERRED production; FIXED misleading documentation | UniqueNamer lives in HelmCore, outside ownership. README now identifies final-extension splitting as unresolved B-116, not an approved override of supposedly stale architecture. No owner sign-off is claimed. |
| O1-23 | FIXED | Cancelled-planning test now asserts empty journal, absent output, cleared reservation/execution and successful fresh reservation; removed unreachable execute. Fake accepts optional longest-prefix volume IDs while preserving its original initializer and default behaviour; regression proves direct move refuses cross-volume paths without mutation. Replacement uses bounded `.helm-stage` plus existing unique suffixes rather than expanding the user's basename; 250-byte basename regression passes. |

## FB1 test leftovers

| Item | Disposition | Evidence and limits |
| --- | --- | --- |
| T-4 | DEFERRED | Globally canonicalizing TempDirectory or changing expected errors would conceal the real FB1-11 ancestor-walk refusal on macOS. TempDirectory and existing canaries remain unchanged. The new T-6 fixture explicitly resolves its own root to isolate conditional-mutation mapping; that does not claim production root handling is fixed. |
| T-6 | FIXED | Live mutation explicitly throws unsupported; executor maps it to verificationUnavailable. Regression asserts unchanged source bytes and absent destination. Linux executed; macOS remains pending. |
| T-7 | FIXED test already in AF1; production DEFERRED | AF1RegressionTests.testPrivateCanonicalRootMapsMissingChildToDisplayedPath is the pure missing `/private/tmp` child case, with Linux XCTSkip when reproduced and macOS expected failure. Retained unchanged; FB1-3 remains excluded. |
| T-8 | FIXED canary; production DEFERRED | Added internal VolumeReader injection seam and test with a healthy mount followed by a denied mount. Existing all-or-nothing map is preserved. Its permissionDenied result produces an explicit XCTSkip documenting FB1-4; successful future partial results must contain the healthy mount. No partial-result policy implemented. |

No rejected underlying finding in this lane. Ancestor-cache optimization is
explicitly deferred rather than accepted. O1-1/FB1-6, O1-2, O1-5/6/8/9/14, T-5
and all excluded FB1 judgement production changes remain outside this work.

## Verification

Linux Swift 6.0.3, package Swift 5 mode, environment sourced from
`/workspace/toolchains/env.sh`; private scratch `/tmp/build-AO3` throughout.

Tests were written before the associated fixes. Initial AO3 safety run reproduced
six failing tests (13 assertions/errors) for replacement, partial/URL evidence,
long stage names and retirement substitution; live refusal already passed.
The first executed work-budget test observed 128 then 129 name reads against
budgets of 1 then 2. New quarantine/admission/volume-seam tests initially failed
compilation against absent APIs before their implementation. Logs:
`/tmp/AO3-red.log`, `/tmp/AO3-budget-red.log`, `/tmp/AO3-io-red.log`,
`/tmp/AO3-admission-red.log`, `/tmp/AO3-volume-red.log`,
`/tmp/AO3-partial-volume-red.log`.

Final required command results:

- `swift build --build-tests --scratch-path /tmp/build-AO3`: PASS, zero errors
  (4.04 s). Log: `/tmp/AO3-final-build.log`.
- `swift test --scratch-path /tmp/build-AO3 --filter HelmOperationsTests`: PASS,
  **177 tests, zero failures, zero skips** (9.376 s).
  Log: `/tmp/AO3-final-operations.log`.
- `swift test --scratch-path /tmp/build-AO3 --filter HelmFileSystemTests`: first
  attempt stopped on another lane's transient `WindowStoreTests.swift:203`
  undefined `home`. Left that file untouched, waited 60 seconds, retried the exact
  command: PASS, **217 tests, two explicit skips, zero failures** (37.811 s).
  Skips are FB1-3/T-7 and FB1-4/T-8. Logs:
  `/tmp/AO3-final-filesystem.log`, `/tmp/AO3-final-filesystem-retry1.log`.
- Scoped `git diff --check`: PASS.

An earlier intermediate build also saw an externally modified Core test during
compilation. Subsequent builds passed after independent AO3 work. An incremental
link referenced the fake's former initializer symbol; retaining the original
initializer alongside the new explicit volume-map overload resolved it without
changing other lanes or clearing their builds. An intermediate Operations run
had one outdated replacement step-count assertion; updated to four successful
copy-replacement boundaries and reran the full suite successfully.

Only SwiftPM sandbox cache and unhandled-resource warnings remain in the final
build; no trailing-closure warnings. No macOS SDK compilation or execution was
available. Native alias/slash fixtures and OS-root behaviour require Opus/macOS
review. Native conditional mutation still refuses; the changes do not claim a
shipping Finder replacement.

Created files:
- `Sources/HelmOperations/Execute/ExecutionCache.swift`
- `Tests/HelmOperationsTests/AO3SafetyTests.swift`
- `Tests/HelmOperationsTests/AO3WorkBudgetTests.swift`
- `Tests/HelmFileSystemTests/AO3QuarantineTests.swift`
- `Tests/HelmFileSystemTests/AO3DeferredVolumeTests.swift`
- `docs/review-opus/fixes-AO3.md`

Other changed owned files contain planner/executor/evidence/quarantine/provider
fixes, the short fake volume-map seam, explicit origin/admission call-site
updates, replacement boundary expectations, and Operations README corrections.
