# DRAFT: pending review, 2026-11-05

AF2 changes require Opus compile-correctness and behaviour-preservation spot-check.

| Finding | Disposition | Evidence |
| --- | --- | --- |
| FB2-1 | FIXED | TabReducer checks standardized root path explicitly before staging Up. Existing root regression runs on Linux; Darwin execution remains required (C-07/F-006). No injectable Foundation seam was added. |
| FB2-2 | FIXED | Stage returns before search cancellation or load admission for push to the same standardized directory path, only without pending navigation. AF2RegressionTests verifies exact state preservation across trailing-slash spelling. |
| FB2-3 | DEFERRED | Complete proposed fix requires WindowStore init/add in Sources/HelmCore/Store, outside explicit ownership. No canonicalization was introduced at stage alone because existing producer/snapshot equality contracts require coordinated default-location handling. FB2-2 independently compares standardized paths. ItemID policy unchanged. |
| FB2-4 | FIXED | Location command now works at virtual locations when text is not focused; virtual commit resets address currentDirectory to home. Regression covers both validation and Recent commit. |
| FB2-5 | FIXED | Properties single-selection validation additionally accepts empty selection with a valid directory destination. Open With remains single-selection only; multi-selection remains disabled. Legacy ContentViewController performProperties confirms fallback. |
| FB2-12 | FIXED | PathEntry joins relative input with NSString.appendingPathComponent. Root-relative regression passes on Linux; original regression was already green there. |
| FB2-13 | FIXED | Refresh preserves caret state; beginEditing and acceptance explicitly set caret to end when replacing text. Tab regression failed before fix. |
| FB2-14 | FIXED | Modifier display now control/option/shift/command; existing display expectation updated and new regression added. |
| FB2-16 | FIXED | StarStore builds cached Set<String> after load, updates on star/unstar, and uses membership lookup. Existing ReducerContext already accepts a Set<ItemID>; no new cross-module wiring introduced. Existing persistence tests pass; no performance threshold test added. Input standardization remains once per lookup for API equivalence. |

Judgement findings FB2-6–11, FB2-15, FB2-17 remain out of scope and untouched.

## Verification

Environment: sourced /workspace/toolchains/env.sh; Swift 6.0.3 Linux, package Swift 5 mode.

New AF2RegressionTests first ran 4 tests with 6 assertion failures; adding caret regression produced 5 tests with 7 assertion failures before production edits. Virtual-commit coverage was added after the fix. Root and star changes relied on existing tests rather than new failing tests: this is a test-first coverage limitation for review.

Final commands (all scratch paths isolated):

- `swift build --build-tests --scratch-path /tmp/build-AF2`: succeeded, 0 errors.
- `swift test --scratch-path /tmp/build-AF2 --filter HelmCoreTests`: 684 tests, 0 failures.
- `swift test --scratch-path /tmp/build-AF2 --filter HelmPersistenceTests`: 81 tests, 0 failures.

Logs: /tmp/af2-build-final.log, /tmp/af2-core-final.log, /tmp/af2-persist-final.log. Package emits existing unhandled README warnings. No network, commit, push, deletion, publication, or external action performed. Concurrent changes outside ownership were left untouched. macOS execution and full FB2-3 remain open.
