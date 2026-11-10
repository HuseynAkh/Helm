# DRAFT — AK1 fixes pending Opus review

2026-11-04. Linux Swift 6.0.3, Swift 5 language mode, tools 5.9.
Scope: assigned SIMPLE findings in OK1 only. No network, native execution, commits,
pushes or external actions. Legacy `Helm/` was read, not modified. Changes from other
lanes in this shared worktree are not part of this report.

## Dispositions

| Finding | Status | Evidence and remaining limits |
| --- | --- | --- |
| OK1-1 | FIXED (assigned minimum) | Both overlay annotations now use `HelmCore.DropProposal`. `scripts/rebuild/check_core_type_names.py` detects known module-level SDK collisions and unqualified overlay references; wired into `run_all.sh`. UI check failed at lines 30/32 before the fix and passes afterward. Eight guard fixtures pass. Mass rename deliberately not performed. Full guard exits 1 on the four retained names listed below; native type-check remains pending. |
| OK1-8 | FIXED | `GalleryFilmstripRequest` contains key/token without selected-preview generation. Separate filmstrip dimensions default to 96×96, with initializer and viewport-update injection. Unrelated snapshot refreshes retain preview/completion; identity, eligibility and full token changes invalidate. Regression tests cover selection stability, reorder/unrelated refresh, independent dimensions, child tokens and eligibility ABA. |
| OK1-9 | FIXED (implementation; one legacy test blocked by scope) | `acceptDrop` requires and forwards the source mask. Planner/session default masks exclude alias. Regression coverage refuses forced move with copy-only/empty masks and default alias; accepts allowed copy. Existing named tests explicitly request alias only when testing supported modifier semantics. Spring callers pass explicit masks. The unnamed T1 test still expects the old default; see open items. |
| OK1-10 | FIXED | Spring destination admission compares `LexicalLocalPath.key`, rejecting parent components and unsafe URLs. Tests accept trailing slash/localhost spellings against a target with a different URL spelling, and reject remote/query/fragment/user/parent URLs. No filesystem resolution introduced. |
| OK1-11 | FIXED (SIMPLE only) | Default `IconPolicy.recommended(for:)` selects file identity for package, alias and all symlink kinds. Tests cover every special kind, explicit overrides, generic ordinary kinds and content invalidation. Custom-folder-icon metadata remains an owner decision. |
| OK1-14 | FIXED | `DraggedItem.isInTrash` is an explicit host fact, propagated by both initializers. Trash proposals reject any marked source as `.sameParentNoOp`, including mixed batches. Tests cover normal Trash proposals, move-out, entry conversion and session source replacement. Hosts must supply membership; no path-name heuristic added. |
| OK1-25 | DEFERRED | Actual planner/source code still standardizes paths; reviewer marks the finding JUDGEMENT and ties it to ItemID's deferred identity decision. No separable SIMPLE change established. No normalization policy or related expectation changed. |
| OK1-27 | FIXED | Existing-session edits before complete enrichment return `.editRejectedAwaitingMetadata(sessionID:)`; no edits are applied or queued. Tests cover no metadata, partial metadata, successful retry after complete enrichment, and stale edits after close. Native hosts must display/handle the effect. |
| OK1-29 | FIXED | The existing 10k test now asserts exactly n−1 adjacent prefix checks and preserves execution order, replacing its diagnostic timing print. This bounds prefix comparisons, not sorting or wall-clock time. No production defect was alleged; the strengthened assertion passes. |
| OK1-30 | FIXED | The existing release test polls a weak reference with a monotonic one-second deadline and 1ms suspension, then fails with an explicit message. Producer-cancellation and stream-finish assertions remain. No deterministic Linux timing failure reproduced; Darwin scheduling still needs native validation. |

No assigned finding was rejected. JUDGEMENT work (including OK1-2/3/12) was not performed.

## Regression-first evidence

Before production edits, seven new XCTest cases compiled and produced 17 expected
assertion failures: unstable filmstrip demand, cleared unchanged preview, shared
image dimensions, default alias, generic special icons, raw spring URL equality,
and silent early inspector edit. Log: `/tmp/AK1-red.log`.

Source-mask and Trash-membership cases were then added before their new APIs existed;
the compile failed on missing `allowedOperations` and `isInTrash` arguments
(`/tmp/AK1-api-red.log`). After implementation, all 16 AK1 regression cases pass.
The static UI check also failed before qualification. Test-hardening findings
OK1-29/30 do not claim an artificially reproduced production failure.

## Verification

- `source /workspace/toolchains/env.sh` used for Swift commands.
- `swift build --build-tests --scratch-path /tmp/build-AK1`: PASS, zero errors (`/tmp/AK1-final-build.log`). Existing sandbox cache/README resource warnings remain.
- `swift test --scratch-path /tmp/build-AK1 --filter HelmCoreTests`: 678 executed, 1 failure, 0 unexpected (`/tmp/AK1-final-tests.log`). Sole failure: `T1DragAdversarialTests.testDropModifierOverrides`, line 104, expects default alias rather than OK1-9 rejection.
- Scoped filter covering AK1, drag planner/session/interaction/work, gallery, spring/F21/F24, icons/thumbnails and inspector session/reuse/size suites: **124 executed, 0 failures**, including 16 new regression cases (`/tmp/AK1-scoped-tests.log`).
- Static guard self-test: 8 fixtures pass; `--ui-only` passes.
- Full static guard: expected exit 1 for `DropProposal`, `DropOperation`, `DropSession`, `ToolbarItem`. No allowlist hides these; the new `run_all.sh` gate will stay red until separately authorized naming work resolves them. This is a curated known-SDK-name check, not a complete SDK symbol index; nested types do not collide at module import and are excluded.
- `swiftc -frontend -parse Sources/HelmUI/Content/ContentOverlays.swift`: PASS (syntax only, not macOS type-check).
- `bash -n scripts/rebuild/run_all.sh` and scoped `git diff --check`: PASS.
- A transient AK2 search compile failure occurred on the first green attempt; left untouched and retried after more than 60 seconds. The retry passed.

## Open items for Opus/orchestrator

1. `T1DragAdversarialTests.swift` was not named by the assigned findings; the ownership rule forbids editing it without a scope exception. Requested permission for its single stale alias assertion. Until approved, leave it unchanged and expect the full HelmCore target to report this one failure. The required correction is to check `.rejection == .unsupportedOperation` for the default Option+Command proposal; explicit alias-mask tests already cover alias planning.
2. Full collision gate intentionally fails on four retained declarations. Minimum qualification fix is complete; mass renaming is outside AK1 scope.
3. OK1-25 and custom folder icons remain deferred policy decisions. Native macOS 14/Xcode compilation and behavior (including release scheduling) remain unverified.

## Files created

- `Tests/HelmCoreTests/AK1RegressionTests.swift`
- `scripts/rebuild/check_core_type_names.py`
- `docs/review-opus/fixes-AK1.md`

Existing changes stay in owned Core subdirectories, the two necessary overlay
annotations, trivial `run_all.sh` wiring, and named regression test files.
F24/F21/Spring test edits are mechanical required-mask call-site updates; their
URL/identity assertions were preserved. No other lane's implementation was edited.
