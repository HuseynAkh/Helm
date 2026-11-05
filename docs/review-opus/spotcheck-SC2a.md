# SC2a spot-check: lanes AF2, AF2b, AK3, AK3b

Date: 2026-11-05. Worktree: `/workspace/forge/helm-build`, branch `forge/rebuild-build`, HEAD `fd526cf`.

**Verdict: accept all four lanes after corrections.** Nothing needs reverting. Three corrections (C1 to C3) should land before host wiring starts. C1 is the most serious: AK3b can leave the app unable to quit.

## Limits

- This review came from reading only. I built and ran nothing, so the lanes' test counts and logs are their own claims, not results I reproduced.
- Nothing here has compiled against an Apple SDK. `[K, Mac]` marks a conclusion that rests on SDK knowledge and needs a Mac run to confirm.
- Code was read at HEAD, not only in the diffs. OP1 later changed `TabNavigation.swift` and `TabReducer.swift` (`steps`, monitor handling) without altering the lines cited for these lanes.

## Verification table

42 changes checked: 27 yes, 14 partial, 1 no. `C` numbers refer to the correction list below. Paths are shortened where the module is obvious.

### AF2

| Change / ID | Verified | Evidence | Action |
| --- | --- | --- | --- |
| FB2-1 Cmd+Up at root | yes | `Sources/HelmCore/State/TabReducer.swift:34`; `Tests/HelmCoreTests/StateTests/TabReducerTests.swift:151-157` | Run this test first on Mac; the bug only ever appeared under Apple Foundation |
| FB2-2 same-directory push is a no-op | partial | Guard at `State/TabNavigation.swift:15-18` runs before `endSearch` at `:19`. No failed-phase check. `.home` is not covered. `Tests/HelmCoreTests/AF2RegressionTests.swift:6-13` covers none of these | C2, C3, C8 |
| FB2-4 Cmd+L in Recent and Trash | partial | Reset to Home is correct: `TabNavigation.swift:89`, `AF2RegressionTests.swift:29-36`. `Commands/CommandValidation.swift:112` also disables Cmd+L in every text field | C5 |
| FB2-5 Properties with empty selection | yes | `CommandValidation.swift:95-97`; legacy `Helm/Helm/Controllers/ContentViewController.swift:716-723`; `AF2RegressionTests.swift:18-20` | None |
| FB2-12 relative path at `/` | yes | `AddressBar/PathEntry.swift:16`; `AF2RegressionTests.swift:40-45` | None; the report already says the regression was green on Linux before the fix |
| FB2-13 caret preserved on refresh | yes | `AddressBar/AddressEditor.swift:11,90-96,99`; `AF2RegressionTests.swift:22-28`; host caret duty at `AddressBar/README.md:25-26` | None |
| FB2-14 modifier display order | yes | `Commands/KeyBinding.swift:31`; `Tests/HelmCoreTests/CommandsTests/CommandsTests.swift:40` | None |
| FB2-16 star lookup uses a Set | yes | `Sources/HelmPersistence/StarStore.swift:7,15,18,22,27`; `Tests/HelmPersistenceTests/StoresTests.swift:59-62`. The Set cannot drift from records: `JSONFileStore.swift:82` refuses writes only after a failed load, and a failed load makes `StarStore.init` throw (`StarStore.swift:14`) | None |

### AF2b

| Change / ID | Verified | Evidence | Action |
| --- | --- | --- | --- |
| FB2-3 canonical navigation spelling | partial | `Identity/Location.swift:7-10`; `TabNavigation.swift:14`; `Store/WindowStore.swift:34,96`; `State/TabState.swift:58-64`. Supplied tabs stay raw (`WindowStore.swift:30,101-102`), and `NavigationHistory.swift:21` and `TabNavigation.swift:79` still compare spellings. The report's "no unresolved FB2-3 implementation issue" overstates this | C7, C9 |
| Load admission stays strict | yes | `TabNavigation.swift:52-53`; `Sources/HelmFileSystem/Loading/DirectoryLoadPipeline.swift:115-120`; `Tests/HelmCoreTests/AF2bRegressionTests.swift:21-30` | None |
| FB2-2 preserved through the address flow | yes | `AF2bRegressionTests.swift:35-48,77-97`; editing ends in `AddressEditor.swift:71` before the no-op | None |
| Symlink and `/private` behaviour of the spelling | partial | Root stat goes through `url.path` with FileManager, so the added trailing slash should not change link handling: `Live/LiveFileSystem.swift:101`, `Live/MetadataReader.swift:22-31` `[K, Mac]`. `Location.swift:9` calls `standardizedFileURL` from the main-actor reducer; on Darwin this can stat and strip `/private` `[K, Mac]` | Mac check M3 |
| ItemID policy unchanged (owner item) | yes | No `Identity/ItemID` entry in `.spotcheck/AF2-src.diff`, `AF2b-src.diff` or `OP1-src.diff`; comment at `Location.swift:6` | None |

### AK3

| Change / ID | Verified | Evidence | Action |
| --- | --- | --- | --- |
| OK2-3 `DropProposal` qualifier | yes | `Sources/HelmUI/Content/ContentOverlays.swift:30,32` | None |
| OK2-4 host options only | yes | `docs/handoff/OWNER_OPTIONS.md:19-28`; `docs/handoff/MAC_HANDOFF.md:286`; `scripts/static_checks.py:13,115` | None |
| OK2-5 handoff corrections | partial | Every requested item is present: `MAC_HANDOFF.md:4,6,200,202,221,236,246,249,269,290`; `docs/handoff/VERIFICATION.md:231`. The reading list at `:4,:200` omits `docs/review-fable`, `fixes-AF*`, `fixes-OP1*` and `OWNER_DECISIONS_NOTE.md` | C6 |
| OK2-14 sidebar follows Core | partial | Code is correct: `Sidebar/SidebarModel.swift:42-43`, `Places/PlacesModel.swift:56-63`, `Tests/HelmUITests/SidebarModelTests.swift:25-37`. Docs still describe the old behaviour: `MAC_HANDOFF.md:130,160`, `Sources/HelmUI/README.md:94,129-131` | C6 |
| OK2-15 Properties icon and size | partial | `Properties/PropertiesView.swift:9,12-19`; `PropertiesViewModel.swift:49-51`; legacy `Helm/Helm/Views/SwiftUI/PropertiesView.swift:15`. Output reads "42 bytes (42 bytes)" and, for one byte, "1 byte (1 bytes)": `Text/ByteCountText.swift:15,29`; pinned at `Tests/HelmUITests/SheetsTests/LeafPresentationTests.swift:54` | C10 |
| OK2-16 no Relevance in folder picker | yes | `ViewOptions/ViewOptionsView.swift:18` | Mac check M5 for a persisted `.relevance` value |
| OK2-17 column identity | partial | `Content/ColumnBrowserView.swift:28-29,34,38-45` fixes the sibling case. `Content/ColumnBrowserState.swift:5-12,103` gives a column a new UUID on every reload, pinned by `Tests/HelmCoreTests/ContentTests/K29ColumnRequestTests.swift:24-32`, so a reload now resets that column's view `[K, Mac]` | C4 |
| OK2-19 single-line rename field | yes | `Content/InlineRenameField.swift:51-53`; the properties exist on NSControl and NSCell `[K]` | Hosted check (already required) |
| OK2-20 dismiss and reconciliation warning | partial | `Operations/OperationsPanel.swift:26-32,38-40`. The warning is correct. The Dismiss button lacks the row name the Cancel button has (`:29` vs `:31`), and `OperationRowModel.swift:37` scans all outcomes on every render | C12 |
| OK2-21 duplicate tag by name | partial | `Tags/TagEditorModel.swift:18-20` only trims. `TagCatalogStore.swift:82-84` treats case and Unicode form as the same name, so the editor admits "work" beside "Work". The report discloses this but marks the finding fixed | C11 |
| OK2-24 lock not held during planning | yes | `Sheets/BatchRenameEvaluation.swift:30-43`; `BatchRenameSheet.swift:61`; `Tests/HelmUITests/SheetsTests/BatchRenameViewModelTests.swift:8-29` | None |
| OK2-25 double-submit guard | partial | `Sheets/BatchRenameSheet.swift:9,49-52,68-74` stops double submit. `submitted` never resets, so Rename stays disabled if the host keeps the sheet open | C13 |
| OK2-26 frame-name allocation | yes | `Sources/HelmApp/LaunchRouter.swift:51,56-68,79`; `Tests/HelmAppTests/FrameIdentityTests.swift:9-18` | C14 (test gap only) |
| OK2-31 Linux-only skip and paths | yes | `Tests/HelmUITests/PrereviewTests/F4RegressionTests.swift:8-11,24,28-29,43`; the four path deletions reach the repository root | None |
| OK2-33 empty parse is a failure | yes | `scripts/rebuild/parse_check_ui.sh:18`; `test_shell_scripts.py:27-31` | None |
| OK2-34 plan directory and static tests | yes | `scripts/rebuild/run_all.sh:9-10,42` | None |
| OK2-35 wider SDK-name guard | yes | `scripts/rebuild/check_core_type_names.py:81-99`; `test_core_type_names.py`; `run_all.sh:46`. My search of `Sources` for a large subset of `SDK_NAMES` found only the four retained names, plus two `State` enums nested inside other types, which the guard skips | None |
| OK2-36 Darwin test names | yes | `scripts/rebuild/check_coverage.py:89-95,110`; `test_check_coverage.py:28-35` | None |
| OK2-38 manifest snippets replaced | partial | All four links resolve. `Sources/HelmUI/README.md:99` still says "after adding the snippet" | C6 |
| OK2-39 direct imports | yes | `OperationsPanel.swift:4`; `PropertiesView.swift:4` | None |

### AK3b

| Change / ID | Verified | Evidence | Action |
| --- | --- | --- | --- |
| Two new `StoreLocation` URLs | yes | `Sources/HelmPersistence/StoreLocation.swift:11-12`; `Tests/HelmPersistenceTests/StoreLocationTests.swift` | None |
| Both stores composed | yes | `Sources/HelmApp/AppEnvironment.swift:35-36,67-68,71,91` | None |
| Seven-document flush | partial | All seven are attempted with no short-circuit: `AppEnvironment.swift:97-107`, `Tests/HelmAppTests/SevenDocumentFlushTests.swift:9-24`. A recovered read-only document fails every quit, and no test covers it | C1 |
| Store protocols | partial | `AppPreferenceStoreContracts.swift` omits `isReadOnly` and `recoveryBackupURL`, which `Tags/README.md:22` and `ViewOptions/README.md:25` expect the host to use | C1 |
| Memory fakes match real stores | yes | Compared line by line: `MemoryTagCatalog.swift` against `Tags/TagCatalogStore.swift:38-91`; `MemoryViewOptions.swift` against `ViewOptions/LocationViewOptionsStore.swift:51-78` | None |
| Actor isolation | yes | `AppStoreContracts.swift:7`; new protocols and fakes are `@MainActor`; the stores are `@MainActor` | None |
| Load-failure policy unchanged (owner item) | yes | `AppEnvironment.swift:67-68` throws as before. Two more documents can now block launch under OK2-9 | Add to the OK2-9 note (C6) |
| LinuxRunner registration | yes | `Tests/HelmAppTests/LinuxRunner/main.swift` per `.spotcheck/AK3b-tests.diff:57` | None |
| Handoff docs reflect AK3b | **no** | `OWNER_OPTIONS.md:48` still says OK2-7 is blocked; `MAC_HANDOFF.md:93-99` lacks the three new App files; `:131` says composition is absent; `Sources/HelmApp/README.md:45` says five stores | C6 |

## Test changes: weakening and skip audit

No assertion was weakened to hide a failure. One skip was added, and it was requested.

| Change | Verified | Evidence | Finding |
| --- | --- | --- | --- |
| Skip on non-Linux | yes | `F4RegressionTests.swift:28-29` | Requested by OK2-31; the test was empty on Mac before, and its Linux body is unchanged |
| `parse_check` expected exit flipped | yes | `test_shell_scripts.py:30` | Stricter, per OK2-33 |
| `run_all` warning became a failure | yes | `run_all.sh:46` | Stricter, per OK2-35 |
| Sidebar test renamed, expected value changed | yes | `SidebarModelTests.swift:25-30` | Follows the OK2-14 ruling; sibling, exact and unrelated assertions remain |
| Display string expectation | yes | `CommandsTests.swift:40` | Follows FB2-14 |
| Size expectations | yes | `F18PropertiesSizeTests.swift`, `LeafPresentationTests.swift:54,66` | Exact and stricter, but they pin the duplicated text (C10) |
| Tag test | yes | `Part3AdapterTests.swift:39-40` | Stricter: tests a trimmed name in a different colour |
| Five fixture files gain `isDirectory: true` | yes | `.spotcheck/AF2b-tests.diff`: F10, F1, TabReducer, T3, WindowStore | Fixtures only; assertions intact |
| Back expectation now fixed, not read from state | yes | `Tests/HelmCoreTests/StoreTests/WindowStoreTests.swift:202-207` | Not weaker, but it pins the spelling change on a supplied tab (C7) |
| Late-result test keeps a raw `old` location | yes | `WindowStoreTests.swift:99-107` | Still rejected by generation first, as before |

**Behaviour removed with no test:**

- Search exit on same-location navigation (C2)
- Recovery from a failed listing by navigating to the same location (C3)
- Cmd+L while another text field has focus (C5)

## Owner-decision items: none silently implemented

| Item | Implemented? | Evidence |
| --- | --- | --- |
| OK2-1 host, OK2-2 paths, OK2-4 host location | No | `Package.swift:26-34` unchanged; no `App/` or `Sources/Helm` exists; `MAC_HANDOFF.md:6,252,286` say pending |
| OK2-6 per-window journal | No | Single journal: `AppEnvironment.swift:38,72,92` |
| OK2-8 `WindowDependencies` | No | No such type in `Sources`. AK3b adds two more HelmApp-local protocols, which follows the existing pattern but enlarges any later move |
| OK2-9 store load failures | No | `AppEnvironment.swift:62-68` still throws |
| OK2-10 external-open policy | No | `LaunchRouter.swift:70-83` same routing; only name allocation was extracted |
| OK2-35 Core rename | No | `DragDrop/DropValues.swift:13,59`; `DragDrop/DropSession.swift:7`; `Presentation/ToolbarItem.swift:5` |
| ItemID lexical or physical policy | No | See AF2b table |
| OK2-11, 12, 13, 18, 22, 23, 27, 29, 30, 32, 37 | No | Absent from `.spotcheck/AK3-src.diff` |
| OK2-28 | Not by AK3 | The comment at `SessionRestorePlan.swift:29-31` came from OP1, not this lane |
| FB2-6 to 11, 15, 17 | Not by AF2 | Absent from `.spotcheck/AF2-src.diff`; later changes belong to OP1 |

## Corrections, in priority order

### P1: fix before host wiring starts

**C1. AK3b: one corrupt preference file stops the app from quitting.**
- Scenario: `tag-catalog.json` or `view-options.json` fails to decode. The store backs it up and becomes read-only (`Tags/PreferenceDocumentFile.swift:37-40`). `flush()` then always throws `recoveryReadOnly` (`:45`, pinned at `Tests/HelmPersistenceTests/T2PreferenceTests.swift:98`). `flushStores` reports that as a failure (`AppEnvironment.swift:103-104`), and `QuitCoordinator` never terminates (`QuitCoordinator.swift:20-24`). Retry fails the same way and the file never heals, so Force Quit is the only exit. The five older documents recover as writable (`JSONFileStore.swift:36-39`), so this could not happen before AK3b.
- Fix: a read-only store refuses every edit, so there is nothing to lose. Treat the error as nothing to save, in `flushStores` only:
  ```swift
  do { try await store.flush() }
  catch PreferenceDocumentError.recoveryReadOnly { continue }
  catch { failures.append(AppFlushFailure(document: name, message: String(describing: error))) }
  ```
  Keep the store-level refusal and its T2 test. Add `isReadOnly` and `recoveryBackupURL` to both App protocols so the host can show the recovery state; the fakes return `false` and `nil`.
- Test: call `live` with corrupt bytes in both documents. Assert `flushStores()` returns `[]` and the original bytes and backups are intact. Assert a real I/O failure is still reported.
- Note for Huseyn: this needs no OK2-29 ruling, because it discards no user edit. "Quit Anyway" remains open for real failures such as a full disk.

**C2. AF2: navigating to the current folder no longer exits search.**
- Scenario: searching in `/a`, the user clicks the highlighted `/a` in the sidebar or commits `/a` in the address bar. Nothing happens and the overlay stays. Legacy exits search first (`ContentViewController.swift:131`), and `stage` did too before AF2.
- Fix: in the same-path branch at `TabNavigation.swift:15-18`, call `endSearch(&state, effects: &effects)` before `return`.
- Test: active search plus same-path push. Assert search is cleared, the underlying selection is restored, the only effect is `.cancel(.search, …)`, and there is no load or Recent effect.

**C3. AF2: same-location navigation can no longer clear a failure.**
- Scenario: at `/a`, a push to `/b` fails, so `.failed` is published over the `/a` listing (`TabReducer.swift:43-49`). The user then clicks or types `/a`. The guard returns and the failure stays until a manual refresh. A degraded monitor state after a remount is stuck the same way. Before AF2 this path reloaded.
- Fix: bypass the guard when `(state.underlyingSnapshot ?? state.deferredSnapshot ?? state.snapshot).phase` is `.failed`, the same base `TabReducer.swift:47` uses.
- Test: fail a push, push the current path, finish the load. Assert a load was emitted, the phase is `.ready`, and history is unchanged.

### P2: fix in the next pass, before the Mac prompt is final

**C4. AK3 OK2-17: every column reload resets that column's view `[K, Mac]`.**
- `BrowserColumn.id` is a request-ownership token that changes on `replaceSnapshot`. As a view identity, it discards scroll position each time a monitor reloads the folder.
- Fix: keep the token as it is, because K29 pins it. Key `ForEach`, `.id` and `scrollTo` on a private `ColumnViewID: Hashable { slot: Int; location: Location }`. A sibling folder still gets fresh identity, so OK2-17 stays fixed. Add this to the hosted column check.

**C5. AF2 FB2-4: Cmd+L is disabled in every text field. Needs a reviewer ruling.**
- AF2 followed FB2-4's exact text, so this is a problem with the prescription, not the implementation. `CommandContext` cannot tell the address field from the search field, so Cmd+L from search now does nothing. It worked before AF2 in directories. Legacy has no such limit (`Helm/Helm/Windows/MainWindowController.swift:317-319`), and Fix 23's list of pane commands does not include it (`docs/rebuild/review-01-architecture.md:358`). Re-entry is already harmless (`AddressEditor.swift:9`).
- Recommendation: `case .location: enabled = true`, plus a test with `textFieldFocused: true`. If the current rule stays, record it as deliberate in `fixes-AF2.md`.

**C6. Handoff documents are stale after AK3b and OP1.** The Mac session will read these.
- `OWNER_OPTIONS.md:48`: remove the OK2-7 blocker.
- `MAC_HANDOFF.md:4,200`: add `docs/review-fable/`, `fixes-AF*`, `fixes-OP1*` and `OWNER_DECISIONS_NOTE.md` to the reading list.
- `MAC_HANDOFF.md:93-99`: add `AppPreferenceStoreContracts.swift`, `MemoryTagCatalog.swift` and `MemoryViewOptions.swift`.
- `MAC_HANDOFF.md:130,160`: remove the sidebar exclusion text (OK2-14).
- `MAC_HANDOFF.md:131`: state that all seven documents are composed.
- `Sources/HelmApp/README.md:45`: change five stores to seven.
- `Sources/HelmUI/README.md:94,99,129-131`: remove the starred-exclusion text and the dangling "snippet" reference.
- `OWNER_DECISIONS_NOTE.md` OK2-9: state that seven documents can now block launch.
- `fixes-AF2.md` FB2-3 row and `fixes-AK3.md` OK2-7 row: add forward pointers to AF2b and AK3b.

### P3: cleanup

| ID | Where | Fix |
| --- | --- | --- |
| C7 | `NavigationHistory.swift:21`, `TabNavigation.swift:79`, `SessionRestorePlan.swift:45-52`, `LaunchRouter.swift:75-77` | A restored tab keeps its raw spelling, so a Home press or a push made during a pending load can still add a Back entry for the same folder. Canonicalize in `TabState.init`, or compare standardized paths in `push`. Then simplify `WindowStoreTests.swift:202-207` |
| C8 | `TabNavigation.swift:15`; `TabReducer.swift:15` | Home pressed while at Home still clears selection and re-records Recent, against F-005. Extend the guard to `.home`; FB2-2 prescribed `.push` only |
| C9 | `Location.swift:8` | Add `url.isFileURL` to the guard. Today a non-file `.directory` is rewritten to a local path of the same name. No current path reaches this: `SessionRestorePlan.swift:48` and `LaunchRouter.swift:74` reject non-file URLs first |
| C10 | `PropertiesViewModel.swift:50`, `ByteCountText.swift:15,29` | Drop the parenthesis below 1,000 bytes; update the expected values in F18 and `LeafPresentationTests` |
| C11 | `TagEditorModel.swift:18-20` | Use the same case-folded, composed comparison as `TagCatalogStore.key`; add a "work" vs "Work" test |
| C12 | `OperationsPanel.swift:31`, `OperationRowModel.swift:37` | Add `.accessibilityLabel("Dismiss \(row.title)")`; compute `requiresReconciliation` once in `init` to keep the lazy-details rule (P4-4) |
| C13 | `BatchRenameSheet.swift:9,49-52` | Reset `submitted` when `model.revision` changes |
| C14 | `FrameIdentityTests.swift:9-18` | Add `allocateFrameName` after `finishLaunch` with a restored `HelmMainWindow`, which is the claim the test does not exercise. The trailing `receive([])` assertion is unrelated to allocation |

## Mac checks to add to the first run

- **M1.** `AF2bRegressionTests`, especially `/a//b/../b` on a path that does not exist, under Apple Foundation.
- **M2.** `testRootUpAndVirtualMutations` and `AF2RegressionTests.testRootRelativePath`.
- **M3.** Navigate to `/private/tmp/x`, and through a symlink to a directory. Record the committed spelling, the entry kind, and whether `stage` stats the disk on the main actor (`Location.swift:9`).
- **M4.** Column view: scroll position after a reload (C4); a sibling folder gets a fresh view.
- **M5.** Folder picker with a persisted `.relevance` sort: there is no matching tag, so confirm it stays usable.
