DRAFT: pending review, 2026-11-05

# OP2 spot-check corrections

All changes are drafts pending Opus compile-correctness and behaviour review. Read SC2a and SC2b in full before edits; checked the relevant implementations and legacy navigation/Cmd+L handlers. Architecture review fixes take precedence. No manifest, scripts, legacy application, other lane report, git history, network or external action was changed. Existing `.spotcheck/` was left alone.

## Findings and dispositions

| Finding | Disposition | Verified evidence and change |
| --- | --- | --- |
| SC2a C1 | FIXED | `PreferenceDocumentFile.save` throws `recoveryReadOnly` before writing; both preference stores refuse edits in recovery. `AppEnvironment.flushStores` now ignores only that error, while still visiting all seven stores and collecting real errors. Both App protocols expose recovery state; memory stores/spies provide false/nil. `EnvironmentTests` loads corrupt bytes in both documents, flushes twice, checks intact originals/backups and edit refusal. A separate actual directory obstruction makes both writes fail; after renaming the obstruction, retry persists retained edits. Existing store-level T2 refusal remains unchanged. No OK2-29 discard policy was chosen. |
| SC2a C2 | FIXED | The same-directory early return preceded `endSearch`. Legacy `ContentViewController.navigateTo` exits search first. The no-op branch now ends search; `OP2NavigationTests` requires the restored selection and exactly one search-cancel effect, with no load/Recent/history change. |
| SC2a C3 | FIXED | `loadFailed` publishes failure over the committed base. The same-folder no-op now excludes a failed underlying/deferred/current snapshot, using that same base ordering. Regression fails a push, navigates to the committed folder, requires a load and ready completion, and checks unchanged history. AF2's healthy-idle preservation test still passes. |
| SC2a C4 | DEFERRED, Mac check only | Verified `ColumnBrowserView` keys ForEach, view ID and scrollTo by `BrowserColumn.id`; `replaceSnapshot` creates a new BrowserColumn. No identity/token change, as expressly requested. Scroll preservation and sibling reset checks are in MAC_HANDOFF. |
| SC2a C5 | FIXED | Legacy `MainWindowController.editPathBar` has no text-focus restriction; `CommandValidation` did. Cmd+L is now always enabled, with a formerly failing text-field-focus regression. |
| SC2a C6 | FIXED within ownership; report pointers DEFERRED | OWNER_OPTIONS now records OK2-7 implemented by AK3b (`7dfe1ba`). MAC_HANDOFF lists all seven stores, the three added App files, new/updated tests and the full review reading list; sidebar policy and App/UI READMEs are current. OK2-9 lists all seven potential throwing loads. Historical AF2/AK3 reports are outside OP2 ownership: forward-pointer corrections are recorded in MAC_HANDOFF instead of editing them. DRAFT/NOT FINAL, OWNER ASSIGNMENT PENDING and `<HEAD at handoff>` remain intact. |
| SC2b C-1 / OP1 item 1 | FIXED draft; native verification pending | Production context used `resolvingSymlinksInPath`. It now uses the Linux/Darwin POSIX `realpath` helper and fails closed if resolution fails. Event paths stay lexical, including nonexistent/deleted children. Linux test resolves a real symlink into a `private/tmp` fixture and checks direct `/private/tmp` → `/tmp` display mapping. Mac-only test starts FSEvents beneath `/tmp` and deletes its own child. No mutation allowlist changes. Darwin's old failure is not claimed reproduced on Linux. |
| SC2b C-2 / OP1 item 2 | FIXED documentation; owner decision DEFERRED | Verified exact-path/kind allowlist in `OperationExecutor`; `/private/<same>` resolution check is absent and FileSystem has no link-target seam. OWNER_DECISIONS_NOTE now discloses implementation, rationale, omitted check/assumption and exact keep/tighten/revert choices. OP2 does not ratify or revert FB1-11. |
| SC2b C-3 | FIXED fake success coverage; native check DEFERRED | `InMemoryFileSystem.createAlias` supports aliases. New test requires alias kind at the destination and preserved regular source. Native reserved-placeholder/bookmark success and collision checks are in MAC_HANDOFF; the fake cannot validate Apple bookmark writes. |
| SC2b C-4 | FIXED | AO3 budget assertions were `<= 1` and `<= 2`; they are now exactly 1 and 2, so a cache surviving between executions fails the second assertion. No executor change was needed. |
| SC2b C-8 cancelled-planning assertions / stale comment | FIXED | The filesystem and journal were unconnected locals. They now construct the executor that would run immediately after successful planning; cancellation bypasses that call. Assertions inspect precisely that injected journal/filesystem. Existing reservation/next-request assertions remain. K15's stale backup/Trash comment now says Trash; assertions are unchanged. |
| SC2b C-9 documentation | FIXED documentation; additional behavioural test DEFERRED | `ForwardEvidence.capture` only takes fallback source observations when both planning-evidence collections are empty. Operations README now requires hosts to supply the template in builder sources and explains the incomplete-plan destination dependence. No evidence-policy change. The extra template test is outside the requested test corrections. |
| SC2b C-14 documentation | FIXED within ownership; historical citation DEFERRED | Verified coalescer only substitutes a sticky root when it publishes; reducer comment corrected. Parser comment now distinguishes strict errors from typing-driver literal-name fallback. OP1's FB2-17 line-184 citation correction is recorded in MAC_HANDOFF; its report file is outside ownership. |

## Deferred, needs judgement

- **SC2b C-5: hung Devices mount delay.** `VolumeReader.details` collects the whole task group before returning; `IOExecutor` defaults to 30 seconds. Healthy results can wait for that timeout. Timeout versus streaming delivery needs a design decision. No implementation change; first-Mac measurement added.
- **SC2b C-6: volume Trash warnings.** `TrashSource` emits warning events, but `DirectoryLoadPipeline` routes them only to a diagnostic callback whose default is a no-op. Visible warning ownership remains a host decision. No warning implementation change; native presentation check added.
- **SC2b C-7: per-directory queue growth/quarantine.** `FallbackMonitor.volumeIsLocal` uses `url.path` as the static probe executor key, and `IOExecutor.queues` has no eviction. Mount-key derivation, bounded queue lifetime and quarantine sharing need judgement. No implementation change.
- **SC2a C7–C14 code/test cleanup, except C6/P3 documentation above:** supplied-tab spelling/Home/non-file admission, small-byte formatting, tag-name identity, dismiss accessibility/cache, rename-sheet reset and post-launch frame-allocation coverage were not part of the requested OP2 code corrections. Remain open for their assigned follow-up. C4 explicitly stays Mac-check-only.
- **SC2b remaining C-8 duplicate F7/boundary names, C-9 extra test, C-10 progress on skipped entries, C-11 timing tests, C-12 multi-volume progress coverage, C-13 runner cancellation/recovery coverage:** not implemented in this bounded correction pass. No claim that their parent reports are fully accepted.
- **Cross-lane report edits:** `docs/review-fable/fixes-AF2.md` → AF2b, `docs/review-opus/fixes-AK3.md` → AK3b, and `fixes-OP1.md` citation correction require those report owners. This lane owns only this new report under review-opus.
- **Mac-only acceptance:** C4 scroll reset, Foundation spellings/root navigation, persisted relevance picker, FSEvents child create/delete, native createAlias, Trash warning, hung mounts, and probe queue behaviour are listed in MAC_HANDOFF. Linux evidence does not close them.

No requested correction was rejected. Claims outside the requested correction scope remain deferred, not silently marked fixed.

## Verification

- Failing-first Core run: `/tmp/OP2-red-core.log`, 3 tests with 6 assertion failures (Cmd+L, search exit/selection/effect, failed retry/load/ready).
- Preference regression was written before the fix. Initial manual runner registration mixed test classes and did not compile; corrected registration. Reproduced the prior flush behaviour using isolated `/tmp/OP2-red-app-sources` copies with only the new catch removed: `/tmp/OP2-red-app.log`, 16 tests with 2 failures, one per quit retry. This was a runtime failure, not a claimed successful initial runner.
- Path test was added before the helper: `/tmp/OP2-red-path.log` fails compilation for the missing `canonicalRoot` API. The native `/private` bug cannot be reproduced on Linux; subsequent Linux checks prove POSIX resolution, lexical deletion mapping and missing-root refusal, not native event delivery.
- Targeted green run: `/tmp/OP2-green-targeted.log`, 19 tests, 0 failures. Includes OP2 Core/FS, AF2, exact AO3 budget and connected HistoryAdmission checks.
- Portable App runner: `/tmp/OP2-green-app.log`, 17 tests, 0 failures. Manual Swift 5 module/runner build follows Sources/HelmApp/README with every scratch path replaced by `/tmp/build-OP2`; App is not a declared SwiftPM target. Recovery-state assertions are included in the final rerun.

| Required check | Result | Log |
| --- | --- | --- |
| `swift build --scratch-path /tmp/build-OP2 --build-tests` | PASS, zero errors; final rebuild also passes | `/tmp/OP2-build-tests.log`, `/tmp/OP2-build-tests-final.log` |
| `swift test --scratch-path /tmp/build-OP2` | PASS: **1,318 tests, 0 skipped, 0 failures** | `/tmp/OP2-full.log`, `/tmp/OP2-full-final.log` |
| `python3 -m unittest discover -s scripts/rebuild -p 'test_*.py'` | PASS: **15 tests** | `/tmp/OP2-python.log` |
| `HELM_K11_SCRATCH=/tmp/build-OP2 bash scripts/rebuild/run_all.sh` | Expected **exit 1 only for four existing Core type-name collisions**; all six module builds pass, 1,318 XCTest / 0 skipped / 0 failures; Python/static tests, static gate, type-name fixtures, UI syntax parse and coverage report pass | `/tmp/OP2-run-all.log`, `/tmp/build-OP2/logs/` |
| Manual App XCTest runner | PASS: **17 tests, 0 failures**; outside the SwiftPM total | `/tmp/OP2-green-app.log` |
| `git diff --check` | PASS | Local check |

The four retained names are `DropSession`, `DropOperation`, `DropProposal` and
`ToolbarItem`. Existing manifest-cache/unhandled-README warnings remain; no compiler
errors. A final repeat of the full suite also passes all 1,318 tests; the subsequent Mac-only test error-cleanup branch was syntax-parsed but remains unexecuted. The static gate reports 249 Swift source files and zero errors; its separate
Python suite passes 4 tests. UI parse and report-only coverage do not establish Mac
compilation or feature acceptance. No Mac test was run.

## Files

Created:
- `Tests/HelmCoreTests/OP2NavigationTests.swift`
- `Tests/HelmFileSystemTests/OP2MonitorPathTests.swift`
- `docs/review-opus/fixes-OP2.md`

Changed source: `Sources/HelmApp/{AppEnvironment,AppPreferenceStoreContracts,MemoryTagCatalog,MemoryViewOptions}.swift`, `Sources/HelmCore/Commands/CommandValidation.swift`, `Sources/HelmCore/State/TabNavigation.swift`, `Sources/HelmFileSystem/Monitor/FSEventsMonitor.swift`. Comment-only source corrections: `Sources/HelmCore/State/TabReducer.swift`, `Sources/HelmSearch/Query/SearchQueryParser.swift`.

Changed tests: `Tests/HelmAppTests/{EnvironmentTests,SevenDocumentFlushTests}.swift`, `Tests/HelmAppTests/LinuxRunner/main.swift`, `Tests/HelmOperationsTests/AO3WorkBudgetTests.swift`, `Tests/HelmOperationsTests/HistoryTests/HistoryAdmissionTests.swift`, and the stale comment in `Tests/HelmOperationsTests/K15ReplacementBoundaryTests.swift`.

Changed documentation: `Sources/{HelmApp,HelmUI,HelmOperations}/README.md`, `docs/handoff/{OWNER_OPTIONS,OWNER_DECISIONS_NOTE,MAC_HANDOFF}.md`.

