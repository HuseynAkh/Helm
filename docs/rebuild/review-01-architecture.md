# Review of 01-architecture.md (Helm rebuild)

Reviewer: Opus, acting as strict reviewer. Date: 2026-11-04. Reviewed copy: the working-tree `docs/rebuild/01-architecture.md` on branch `forge/rebuild-plan`, which was untracked when the review began. References such as `:738` are lines in that copy. Source paths are relative to `Helm/Helm/`.

| Criterion | Grade | Short reason |
|---|---|---|
| 1. Soundness | **FAIL** | The module list is acyclic but the type signatures are not. `HelmCore` names types owned by modules that depend on it, and three core modules need APIs they are forbidden to import. |
| 2. Preserved interactions | **PASS-WITH-FIXES** | All 72 F items are mapped and much of the detail is faithful, but real regressions exist in completion, multi-rename, the Devices filter and grid icon size, and user-data migration can silently lose data. |
| 3. Feasibility on macOS 14+ | **PASS-WITH-FIXES** | Most API choices are sound. The undo design, responder insertion point, drag modifier source, `canImport` guard, monitor path filter and XcodeGen `info` block are wrong or risky. |
| 4. Gaps | **PASS-WITH-FIXES** | Required sections exist. The search service has no specification, and several expected Finder capabilities have no disposition. |
| 5. Compile-safety | **FAIL** | The checklist is good but misses the largest error cascades, the documented Linux test command cannot work, and several rules conflict with required APIs. |

The fix list has 65 items: 10 Blocker, 42 Major, 13 Minor. The overall verdict and unresolved risks follow it at the end.

## Method and evidence labels

Nothing was compiled or run. No Swift toolchain was found on this machine (a check of `/usr/bin/swift*` returned nothing). Claims about what the compiler or an SDK does therefore come from knowledge, not from observation here, and are labelled.

| Label | Meaning |
|---|---|
| [D] | Visible by reading the document itself: a contradiction, an undeclared type, a forbidden edge. |
| [S] | Checked against the current source, cited as `file:line`. |
| [K] | Swift, Foundation, AppKit or XcodeGen behaviour from knowledge. Not verifiable on this machine. |
| [Mac] | Needs a Mac to confirm. Goes on the handoff checklist. |

Mechanical checks performed: grep for all F rows, disposition counts, Critical and High bug coverage, declarations of every type used in signatures, and absence of expected Finder capabilities. The owner's brief (`/workspace/forge/runs/p1_arch.v2.txt`) and `git` commit `08f0cea` were also read.

Severity meaning used below:

- **Blocker:** as specified, the code cannot compile on a supported path, the Linux test story cannot work, a rule would be repeated wrongly in every file, or user data can be silently lost.
- **Major:** a behaviour regression, a runtime defect, or a substantial blind-authoring cost.
- **Minor:** a cleanup that does not change outcomes much.

## Criterion 1: Soundness. Grade: FAIL

The direction is right. A reducer, immutable snapshots, generation tokens, a planner and executor split, and a package of modules are the correct structure for this project, and the module-level DAG as drawn contains no cycle. The failure is in the concrete contracts, which is exactly what blind authors will copy.

| Finding | Evidence | Fix |
|---|---|---|
| **Type-level cycle.** `HelmCore` signatures name `MonitorEvent` (declared in section 6.1, `HelmFileSystem`), `SearchResult` and `SearchQuery` (`HelmSearch` layout), `OperationResult` and `OperationID` (`HelmOperations`). Those modules depend on `HelmCore`, which "imports nothing but Foundation". This cannot compile. | [D] `:460`, `:548-577`, `:234`, `:780` | 1 |
| **Forbidden module edges.** `RecentSource` in `HelmFileSystem` "serves from `RecentStore`" (`HelmPersistence`), though the two "do not know about each other". `TrashCoordinator` in `HelmOperations` writes `RecentStore`'s companion file, though operations must "never" depend on persistence. Search needs bookmarks, which it reads straight from defaults today. | [D] `:711`, `:235`, `:980`, `:236`; [S] `Services/SpotlightSearchService.swift:154`, `:296` | 2 |
| **AppKit in a Foundation-only module.** `VolumeProvider` uses `NSWorkspace.shared.notificationCenter`, `ApplicationProvider` uses `urlsForApplications`, and `PropertiesLoader` needs image dimensions and the default app. All sit in `HelmFileSystem`, where AppKit is banned. | [D] `:186`, `:237`, `:803`, `:131`, `:119` | 3 |
| **Combine in a Linux-testable module.** `SettingsStore` and the JSON stores are `ObservableObject` with Combine publishers in `HelmPersistence`, whose imports are Foundation and HelmCore and which is marked Linux-testable. Combine does not exist on Linux [K]. `RecentStore` is also both an `actor` and a `@MainActor ObservableObject`. | [D] `:189`, `:1109`, `:1134`, `:600` | 4 |
| **Core contracts never declared.** Used in signatures with no declaration: `Location`, `LocationKind`, `TabID`, `ViewMode`, `SortDescriptor`, `NavigationIntent`, `SelectionSource`, `SearchState`, `SearchQuery`, `SearchResult`, `SearchService`, `AddressBarState`, `AddressBarAction`, `CompletionRequest`, `LoadOptions`, `LoadEvent`, `MonitorFailure`, `ReducerContext`, `OperationID`, `StepID`, `ImageRequestToken`, `Conflict`, `PlanningIssue`, `PlanSummary`, `FileNameError`, `OperationError`, `CrossVolumeMoveBehaviour`, `TabStore`, `WindowStore`, `ContentWidget`, `SidebarMode`, `AccessBroker`, `StoreLocation`, `ImageRequesting`. Authors would each invent their own. | [D] grep of declarations | 5 |
| **`mutationTarget` cannot work as declared.** The B-031 row says `Location.mutationTarget`. Section 5.6 declares it on `LocationSource` with no location argument, so `DirectoryLoader` has nothing to return. | [D] `:157`, `:707` | 5 |
| **Search is two things.** Principle 6 calls search a location kind, while `TabState.search` makes it an overlay. | [D] `:41`, `:449` | 5 |
| **Non-escaping closure stored in a task.** `policyResolver: @Sendable (Conflict) async -> ConflictResolution` must outlive the call to serve the returned `Task`. It needs `@escaping`, otherwise a compile error [K]. | [D] `:911` | 6 |
| **Reducer is incomplete.** `.monitorEvent` needs I/O but no effect exists to refresh paths. There are no actions for star or settings changes, tab activation (required by `:803`), scroll anchor, inline rename, open completion or cut-set changes. There are no effects for `persistShowHidden` (F-042) or cache invalidation. `TabState` has no place for a pending navigation or the last directory used by F-043. | [D] `:439-454`, `:548-577` | 11 |
| **No commit point.** A failed load must not enter history (`:1080`, B-017), the first batch must be visible quickly, and the action list has no pending stage. Nothing says when history, Recent and `representedURL` change, or whether Back and Forward record Recent (00b M-16). | [D] | 12 |
| **Snapshot identity undefined.** One load produces many snapshots, and `==` is on `id` only, so a rebuild reusing an id is swallowed by `removeDuplicates()`, which reintroduces the stale-datasource class of B-009. `.loadProgress(Generation, [FileEntry])` forces merging on the main actor, against the off-main rule at `:484`. | [D] `:521`, `:551` | 13 |
| **`@Published` and re-entrancy.** `$state` publishes in `willSet`, so `store.state` is stale inside a sink [K]. A sink applying selection to `NSOutlineView` fires the selection delegate synchronously [S `Views/AppKit/FileListView.swift`], which calls `send` while the outer assignment is unfinished. That is a lost update. Grid `selectItems` behaves differently (00b M-22). | [K], [S] | 14 |
| **Protocol witnesses.** `FileSystem` and `LocationSource` have synchronous stream-returning requirements. An actor cannot witness those without `nonisolated` [K], and `InMemoryFileSystem` has no stated form. | [D] `:705` | 15 |
| **Name collisions.** `HelmCore.SortDescriptor` collides with `Foundation.SortDescriptor` in every `HelmUI` file importing both: an "ambiguous for type lookup" cascade [K]. `Clock` overlaps `_Concurrency.Clock` (possibly resolved by shadowing, not verifiable here). `GridItem` overlaps `SwiftUI.GridItem`, which is confusing though own-module shadowing should resolve it. | [D] `:108`, `:261`, `:292` | 16 |
| **Cross-module UI wiring.** `MainMenuBuilder` in `HelmUI` cannot name `AppDelegate` selectors in `HelmApp`. `MainWindowController` cannot name `AppEnvironment`. | [D] | 17 |
| **`IOExecutor` is incoherent.** "Task.detached closures dispatched to OperationQueue" conflicts with the checklist's guidance on `Task.detached` and with rule 10's `DispatchSemaphore` exemption. A checked continuation does not propagate cancellation. A hung SMB mount can hold the global width of 4 and stall all I/O, though B-107 asks for protection. | [D] `:600`, `:1163`, `:1220` | 18 |
| **`deinit` claims.** "`deinit` cancels tasks and stops monitors" and `OperationJournal.deinit` calling into `UndoManager`. `deinit` of a `@MainActor` class is nonisolated and cannot `await` or call isolated methods [K]. | [D] `:603`, `:958` | 19, 35 |

Smaller contradictions are handled in Fixes 46 and 53 to 58: wrong disposition counts at `:138`, two JSON envelopes at `:1117-1124`, journal entry mutability, B-041 wording, reload rules at `:521` versus `:799` and `:1238`, `TreeSnapshot` overlap, the diagram, and `GeometryReader`.

## Criterion 2: Preserved interactions. Grade: PASS-WITH-FIXES

**Coverage.** Grep confirms all 72 rows, F-001 to F-072. The coverage claim holds, but the disposition counts do not: actual counts are Keep 12, Keep+fix 45, Redesign 13, Drop 2, against the claimed 15, 40, 15, 2 at `:138` (Fix 53). All Critical and High bugs per 00 and 00b appear in section 2.2. Eight lower-severity bugs are mentioned nowhere: B-004, B-005, B-006, B-007, B-008, B-014, B-064, B-065 (Fix 59).

**Sample.** These rows were read in detail against 00 and 00b: F-001, 002, 003, 004, 011, 012, 013, 016, 017, 018, 019, 021, 023, 024, 026, 027, 028, 029, 030, 031, 035, 037, 040, 041, 042, 043, 044, 045, 046, 049, 050, 051, 052, 053, 054, 055, 056, 057, 059, 062, 067, 072. That is 42 rows, above the required 30.

**Source opened for the most intricate items:**

| Area | Rows | Source read |
|---|---|---|
| Address bar and completion | F-012 to F-024 | `Views/AppKit/BreadcrumbBar.swift`, `Services/PathCompletionService.swift`, `Views/AppKit/PathCompletionWindowController.swift` |
| Clipboard routing | F-051 | `Services/ClipboardService.swift`, `App/main.swift:72-75`, `Windows/MainWindowController.swift:289-299` |
| Keyboard map | section 2.7 | `App/main.swift:60-118` |
| Search | F-043 to F-046 | `Services/SpotlightSearchService.swift` |
| Recent | F-030 | `Services/RecentItemsService.swift`, `Controllers/ContentViewController.swift` |
| Places | F-027 to F-029 | `ViewModels/SidebarViewModel.swift`, `Views/SwiftUI/SidebarPlacesView.swift` |
| Devices | F-031 | `Services/VolumeService.swift` |
| Rename | F-054, F-055 | `Views/SwiftUI/BatchRenameView.swift`, `Controllers/ContentViewController.swift:696-703` |
| Creation and templates | F-052, F-056, F-057 | `Services/FileOperationService.swift`, `Views/AppKit/FileContextMenuBuilder.swift` |
| Drag and drop, list, grid | F-035, F-041, F-067 | `Views/AppKit/FileGridView.swift`, `Views/AppKit/FileListView.swift` |
| Tabs and window | F-002, F-003, F-004, F-011 | `Controllers/TabContainerViewController.swift`, `Windows/MainWindowController.swift`, `Windows/MainSplitViewController.swift` |
| Persistence | section 10 | `Services/StarredFilesService.swift`, `Services/RecentItemsService.swift`, `ViewModels/SidebarViewModel.swift`, `Views/SwiftUI/PreferencesView.swift` |

**Must-not-regress contracts: preserved or merely named?**

| Contract | Verdict | Detail | Fix |
|---|---|---|---|
| Address-bar contract | Partly preserved | Faithful: Esc twice, Tab and backtab rules (F-019, F-021), ghost-text rule, popup metrics. Regressions: completion early stop, focus survival, segment clicks. | 20, 21, 29 |
| Text-first Cut, Copy, Paste | Preserved | Selectors are right and match `App/main.swift:72-75`. Second paste after a cut-move still needs handling. | 33 |
| Other commands while typing | Not preserved | Only Rename gets a first-responder rule. Cmd+Backspace in the address field, search field or inline rename fires Move to Trash, because menu equivalents run before the text view and nothing validates them (`App/main.swift:80-81`). The rebuild should close this rather than inherit it. | 23 |
| Keyboard map | Named, not specified | Return for multi-select is broken. Space and Return are both menu equivalents (F-049, section 2.7) and "not menu equivalents" (`:1043`). `toggleSidebar(_:)` collides with AppKit. | 22, 34 |
| Places | Partly preserved | Highlight rule matches `ViewModels/SidebarViewModel.swift:178-186`. Tap-action design removes the only known keyboard path. Devices filter changes. | 25, 26 |
| Recent | Mostly preserved | Limits and pruning match. Recording on Back and Forward is unstated. Module edge is illegal. | 2, 12 |
| Per-tab model | Preserved | Close logic `index > 0 ? index - 1 : 1` matches `Controllers/TabContainerViewController.swift`. Per-tab query is an improvement. | None |
| Search ranking | Numbers preserved, inputs not | The score table matches `Services/SpotlightSearchService.swift:317-385`. Omitted: the Library exclusion, the depth formula, the doc-like definition and the query sort descriptors that decide which candidates survive the cap. Row is marked Keep, so an author would drop these silently. | 31, 32 |
| Creation and rename | Partly preserved | Batch-rename modes, tokens and preview match `BatchRenameView.swift`. Return no longer opens it. Templates lose directories. Collision check misses case and normalization. | 22, 30, 43 |
| Migration of `helm.*` data | **Not preserved** | See below. | 10 |

**Specific regressions.**

1. **Completion early stop** (`:738`, `:85`). "Stops after the limit is satisfied" and "a streaming first page" cannot reproduce F-016 and F-017. The source enumerates the whole parent, filters, sorts directories first, and only then caps at 50 [S `Services/PathCompletionService.swift:57-85`]. Enumeration order is arbitrary, so an early stop returns an arbitrary subset, can miss prefix matches, and breaks directories-first. The source's slash path is synchronous with no debounce, and its comment records that an async version "caused multi-level drilling to silently fail" [S `BreadcrumbBar.swift:467-535`]. The rebuild's generation guard can recreate that bug if a programmatic edit bumps the generation after the request.
2. **Multi-select Return** (`:1041`). "Exactly one item is selected" disables Return for multi-select, but F-055 and the source open batch rename on it [S `ContentViewController.swift:696-703`].
3. **Devices filter** (`:99`). The row drops the internal-name dedupe [S `Services/VolumeService.swift:97-100`], and "whole-word `VM`" still hides "VM Images", which is B-080's own example.
4. **Grid icon size** (`:103`, `:1098`). The grid draws 96 pt today [S `FileGridView.swift`] and no code reads `helm.gridIconSize`, which defaults to 64 [S `PreferencesView.swift:12`]. Wiring it up as specified shrinks every icon on first launch. `:1098` also says int where the stored type is Double.
5. **Trash confirmation** (`:122`). Honouring `helm.confirmBeforeTrash` (default true, unread today per B-048) adds a sheet to every Cmd+Backspace in a keyboard-first app. That is a product decision, not a bug fix, and it needs the owner's input.
6. **Segment clicks** (`:81`, `:1298`). The default reverses commit `08f0cea`, in which the owner deliberately removed ancestor navigation and made segment clicks enter editing. The document calls this a "product decision" while also listing it as an open question, which conflicts with tie-breaker 1 at `:48`.
7. **Templates** (`:126`). "Files only; directories excluded" is a silent change. The source lists directories and copies them [S `FileContextMenuBuilder.swift`].
8. **Focus steal** (`:1055`). "Load finished with no editor active" moves focus to the pane, including while the user is typing in the search field or using the sidebar.
9. **Sidebar arrows** (`:95`). 00b M-14 infers that arrow keys navigate through the selection binding today [S `SidebarPlacesView.swift:78-87`]. The row replaces that binding with a tap action and names no keyboard replacement.
10. **Kind sort** (`:108`). The source sorts by `contentType?.localizedDescription` [S `Models/FileItemSort.swift:38-41`], while `FileEntry` carries only a type identifier, so a pure core sort would order by identifier.

**Migration.** Three defects can lose or strand user data:

- `:1134` "renames the defaults key ... so a rollback to the old build keeps working" contradicts itself. A renamed key is invisible to the old build.
- `:1109` "no settings migration is needed" assumes one defaults domain. 00b M-34 and C-25 flag that the README's primary route, `swift run Helm`, probably writes a different domain from bundle id `com.helm.filemanager` [Mac]. If the owner has used that route, stars, bookmarks, recents and settings would all appear empty after the rebuild, with no error.
- The legacy formats are not specified precisely enough to decode blind: `[URL]` JSON Data under `com.helm.starredFiles` and `helm.bookmarks`, and `[{path, lastAccessedAt}]` with the default date strategy under `helm.recentAccessRecords` [S]. Bookmark load filters to existing directories today, so migrating through that path could drop bookmarks on unmounted volumes (B-029).

## Criterion 3: Feasibility on macOS 14+. Grade: PASS-WITH-FIXES

**Wrong or risky claims.**

| Claim | Problem | Label | Fix |
|---|---|---|---|
| `windowWillReturnUndoManager` returns nil for text views so "field-editor typing keeps its own stack" (`:958`) | Text views get their undo manager through the window. Returning nil gives them none, so typing undo stops working rather than being separated. | [K], [Mac] | 35 |
| `UndoBridge` with async `journal.undo()` (`:958`) | `UndoManager` records redo only for registrations made during the undo handler. A registration after an `await` lands as a new undo and clears redo. | [K] | 35 |
| `CommandDispatcher` "inserted between the window and the content controller" (`:1007`) | A view controller's next responder is managed by AppKit, and tab swaps re-parent. This is not a stable insertion point. The source already has a proven alternative at `MainWindowController.swift:289-299`. | [K], [Mac] | 36 |
| "Modifier flags from `draggingInfo`" (`:1047`, `:136`) | `NSDraggingInfo` has no modifier flags. Only `draggingSourceOperationMask` exists, and Cmd maps to `.generic`, which the source mask must include. | [K]; [S] the source reads `NSEvent.modifierFlags` | 37 |
| `tableView(...)` drag methods in the checklist (`:1182`) | The list is an `NSOutlineView`. Authors would write methods that never get called. | [D], [S] `FileListView.swift:318-343` | 37 |
| `#if canImport(Foundation.NSMetadataQuery)` (`:188`) | `canImport` takes modules and submodules. This is false on macOS or an error, so search could be compiled out silently. | [K] | 38 |
| `path.deletingLastPathComponent == watched` (`:772`) | FSEvents reports real paths such as `/private/tmp`, while `standardizedFileURL` strips `/private`, so events would be dropped. | [K], [Mac] | 39 |
| "`WatchRoot` survives a rename", `rootChanged(newPath:)` (`:770`, `:782`) | FSEvents gives no new path. | [K], [Mac] | 39 |
| "Two tabs share one stream" (`:773`) | `AsyncStream` is single-consumer. Sharing needs fan-out. | [K] | 39 |
| Direct-children filter (`:772`) | Expanded list subfolders (F-037) produce deeper events that get dropped, and `TabEffect` has no monitor effect per expansion. | [D] | 39 |
| "A failure to open the directory throws" (`:685`) | `FileManager.enumerator(at:...)` reports through `errorHandler` rather than throwing. Iterating it inside an `async` function is flagged as unavailable from async contexts. 00b M-18 also infers `~/.Trash` may list empty, not fail, without Full Disk Access. | [K], [Mac] R-13 | 40 |
| `volumeIdentifierKey`, `contentTypeKey` prefetch (`:681`) | The volume identifier is an opaque object, not a string, and costly per entry. The `.contentType` value needs `UniformTypeIdentifiers`, not allowed in `HelmFileSystem`, and is absent on Linux. | [K] | 40 |
| `func trashItem(at:) async throws -> URL` (`:627`) | The resulting URL can be nil; the source handles this with `if let` [S `FileOperationService.swift:115`]. Some network volumes have no trash, and no flow is defined. | [S], [K] | 41 |
| Pure planner with `PlanningContext` (`:836`) | The context holds no source tree, so the planner cannot produce per-file steps. `existingNames: Set<String>` misses case and normalization collisions, including `foo` to `Foo` (R-18). | [D] | 42, 43 |
| Directory shell plus per-file copy (`:858`) | Loses directory metadata unless handled. Whole-file `copyItem` has no progress or cancel. Replace semantics are undefined. | [K] | 42 |
| Flow layout and batch updates at scale (`:103`, `:521`) | `NSCollectionViewFlowLayout` is unlikely to be O(visible) for 100k items. `NSOutlineView` asks for every root child on reload. A blind `performBatchUpdates` mismatch raises an exception. Budgets are targets until measured. | [K], [Mac] | 44 |
| `info:` and `entitlements:` blocks in `project.yml` (`:388-391`) | From memory of XcodeGen's source, these generate and overwrite the file at that path from `properties`. That would erase the usage strings and the `public.folder` Alternate Viewer from Info.plist [S `App/Info.plist`]. The current `project.yml` uses settings instead. | [K], [Mac] | 45 |
| `SWIFT_STRICT_CONCURRENCY` on the Xcode target (`:360`) | Does not apply to package targets, where nearly all the code lives. | [K] | 45 |
| `packages: path: .` (`:375-377`) | A local package rooted at the directory that holds the project is an unusual setup. Package and app both named `Helm` may also collide on scheme names. | [Mac] | 45 |
| `Thread.isMainThread` debug check (`:1246`) | Unavailable from async contexts. | [K] | 63 |
| Hidden-title proxy icon (F-072) | A proxy icon normally needs a visible title. | [Mac] | 64 |

**Sound as far as can be judged without a Mac** [K]: the not-sandboxed posture and its consequences (`:1073-1081`); `QLThumbnailGenerator` request and representation APIs; `NSWorkspace.open` with `OpenConfiguration`; `readObjects(forClasses:options:)`; `beginSheetModal`; `presentAsSheet` and `dismiss`; FSEvents flags as a concept; `NSSearchToolbarItem`; memory-pressure sources on macOS; "Put Back has no public API" for items trashed by other apps; the Privacy Settings URL scheme (label [Mac] on future OS versions).

**File Provider and Launch Services.** The document does not design for File Provider placeholders (Fix 48). The Launch Services claim in F-062 is plausible and belongs in `HelmUI` (Fix 3). `NSWorkspace.activateFileViewerSelecting` at `PropertiesView.swift:72-73` still opens Finder, which conflicts with the Finder-replacement aim (Fix 48).

## Criterion 4: Gaps. Grade: PASS-WITH-FIXES

All sections required by the brief exist. The gaps are below, and Fixes 47 and 48 carry the additions.

**Against the brief.**

- **Search service (brief section 5).** `SearchService` is named but undeclared. There are no `SearchQuery` fields, no lifecycle, no fallback trigger, and F-046's "materialisation off the main actor" conflicts with "`NSMetadataItem` never crosses a boundary" (`:601`).
- **Conflict policy (brief section 7).** The sheet is designed, but with `defaultResolution` keepBoth (`:852`) it appears only through `helm.askOnConflict` (`:1306`), and that key is absent from section 10.1. No user could reach it (Fix 46).
- **Column and gallery (brief section 8).** Deferred at `:1330`, which is acceptable, but `ContentWidget` is undeclared, so the seam does not exist yet (Fix 5).
- **Compile-safety scripting (brief section 11).** See criterion 5.

**Against a full Finder replacement.** Grep finds no mention of eject or unmount for devices, Services for the selection, the default folder viewer, disabling automatic window tabbing, Open in New Tab, Connect to Server, or compress. Also missing or deferred without a stated disposition: Close Window (00b M-05), Reopen Closed Tab, Get Info editing and multi-select, preview pane, selection after trash, iCloud placeholders, free-space preflight, hung-volume state. Alias and symlink commands exist with no menu, binding or selector. Keyboard tab switching defaults to out of scope (Q6), which sits poorly with a keyboard-first identity.

## Criterion 5: Compile-safety for blind authoring. Grade: FAIL

The list at section 11.2 and the standard at 11.3 are useful and specific. One type per file is the right habit. The grade comes from four things.

**1. The documented Linux commands do not work** [K]. `swift test --filter X` filters what runs, not what builds. Every test target and its dependencies are built, so `HelmUITests` pulls in `HelmUI` and `import AppKit` fails (`:361`). The entire Linux test story depends on this (Fix 7).

**2. The largest cascades are missing.**

- Implicit memberwise initializers are `internal`, so every `public struct` used across modules fails to construct unless it has an explicit `public init` [K]. With this many cross-module value types, this alone would produce hundreds of errors (Fix 9).
- The `SortDescriptor` ambiguity (Fix 16).
- Undeclared core types, invented differently by each author (Fix 5).
- Linux availability: "compiles everywhere" is claimed for modules that use `NSPredicate(format:)`, `DispatchSource.makeMemoryPressureSource`, `trashItem`, `autoreleasepool` and more (Fix 8).

**3. Rules conflict with required APIs.** An author following the rules literally cannot write correct code (Fix 50).

| Rule | Conflict |
|---|---|
| No `fatalError` (`:1174`) | `required init?(coder:)` on every `NSView`, `NSViewController` and `NSResponder` subclass with a custom init. |
| No `as!` (`:1174`) | `makeItem(withIdentifier:for:)` returns the base class; the source force-casts at `FileGridView.swift`. |
| No IUO (`:1213`) | `QLPreviewPanel` overrides require `QLPreviewPanel!` and `(any QLPreviewItem)!` [S `FileListViewController.swift`]; `:1185` itself cites one. |
| No `!` (`:1174`, `:1207`) | `:1080` writes `URL(string: "...")!`; `App/main.swift:114` builds arrow-key equivalents with `UnicodeScalar(...)!`. |
| No `nonisolated(unsafe)` (`:1198`) | Known-good code being ported contains it (B-004: `BreadcrumbBar.swift:928`, `TabBarView.swift:179`). |
| No `DispatchQueue.main.async` (`:1207`) | The source's run-loop deferrals need a stated replacement. |

**4. Designs that invite cascades.** Blind batch updates (Fix 44), the `UndoManager` bridge (Fix 35), a custom responder in the chain (Fix 36), and any `@MainActor` API called from `deinit` (Fix 19).

**Additional rules, banned APIs and scriptable checks** are in Fixes 51 and 52. A symbol-table check (Fix 52, check 2) would have caught the first three Blockers mechanically, and it needs no toolchain.

## Fix list

### Blockers

**Fix 1. Break the type cycle.** Location: `:185`, section 3.3 layout, `:460`, `:548-577`, `:780`, `:234`.
Move these into `HelmCore`: `MonitorEvent`, `MonitorFailure`, `SearchQuery`, `SearchResult`, `OperationID`, `LoadOptions`, `CompletionRequest`, `AddressBarState`, `AddressBarAction`, `ReducerContext`, `TrashedItem`, `RecentRecord`. Replace `case operationCompleted(OperationResult)` with `case operationCompleted(OperationSummary)` and add:

```swift
public struct OperationSummary: Sendable, Equatable {
    public let id: OperationID
    public let affectedDirectories: Set<URL>
    public let renamedIDs: [ItemID: ItemID]
    public let createdIDs: [ItemID]
    public let failureCount: Int
    public init(id: OperationID, affectedDirectories: Set<URL>, renamedIDs: [ItemID: ItemID], createdIDs: [ItemID], failureCount: Int)
}
```

`TabStore` in `HelmUI` maps `OperationResult` to this. Add after `:234`: "Every type named in a public `HelmCore` signature is declared in `HelmCore`."

**Fix 2. Remove forbidden edges.** Location: `:711`, `:980`, `:235-236`, F-044.
Add to `HelmCore/Contracts`:

```swift
public protocol RecentRecordsProviding: Sendable {
    func recentRecords() async -> [RecentRecord]
}
public protocol TrashOriginRecording: Sendable {
    func record(_ items: [TrashedItem]) async
    func originalURL(forTrashed url: URL) async -> URL?
}
```

`RecentStore` conforms in `HelmPersistence`. `RecentSource` and `TrashCoordinator` take these through `init`, and `AppEnvironment` injects them. Add `bookmarkPaths: [String]` to `SearchQuery`; `HelmSearch` never reads `UserDefaults`.

**Fix 3. Take AppKit out of `HelmFileSystem`.** Location: `:186`, `:237`, section 3.3 layout, `:803`, F-031, F-050, F-062.

- `VolumeProvider` splits into `VolumeReader` (`HelmFileSystem`: mount list and resource values, macOS-only keys under `#if os(macOS)`) and `VolumeEventSource` (`HelmUI`: `NSWorkspace` notifications, which it forwards to the sidebar and `MonitorRegistry`).
- `ApplicationProvider` moves to `HelmUI/Providers`.
- `PropertiesLoader` keeps file attributes. Image dimensions and default app move to `HelmUI/Providers/PropertiesEnricher`.

**Fix 4. Remove Combine from `HelmPersistence`.** Location: `:189`, `:600`, `:1109`, `:1134`.
Stores become plain `@MainActor public final class` types, including `RecentStore`; delete `RecentStore` from the actor list at `:600`. Add to `HelmCore/Support`:

```swift
@MainActor public final class Broadcast<Value: Sendable> {
    public struct Token: Hashable, Sendable {}
    public init()
    public func subscribe(_ handler: @escaping @MainActor (Value) -> Void) -> Token
    public func cancel(_ token: Token)
    public func send(_ value: Value)
}
```

Each store exposes `public let changes: Broadcast<...>`. `ObservableObject` adapters (`SettingsModel`, `StarsModel` and so on) live in `HelmUI` and bridge to `@Published`.

**Fix 5. Declare every core contract.** Location: new section 4.6, plus `:41`, `:157`, `:707`.
Add this declaration and delete `var mutationTarget` from `LocationSource`:

```swift
public enum Location: Hashable, Sendable, Codable {
    case directory(URL)
    case recent
    case trash
    public var mutationTarget: URL? { get }   // the URL for .directory; nil otherwise
}
```

Amend principle 6: "Search is an overlay held in `TabState.search`, not a `Location` case." Then add a table giving a home and minimum shape for each of these. Every type gets an explicit `public init`, and `Sendable` plus `Equatable` where `TabState` or `TabEffect` need it.

| Type | Home | Minimum shape |
|---|---|---|
| `TabID`, `OperationID`, `StepID` | `HelmCore` | Struct wrapping `UUID`; `Hashable`, `Sendable`, `Codable` |
| `ViewMode` | `HelmCore/Tab` | `enum: String` with `grid`, `list`, matching stored values in `PreferencesView.swift:33-34` |
| `ItemSort` (Fix 16) | `HelmCore/Model` | Field with raw values matching `helm.defaultSortField`, ascending, directoriesFirst, plus relevance |
| `NavigationIntent`, `SelectionSource` | `HelmCore/Tab` | Enums as used at `:549` and `:555` |
| `SearchState`, `SearchQuery`, `SearchResult` | `HelmCore/Search` | See Fix 47 |
| `AddressBarState`, `AddressBarAction`, `CompletionRequest` | `HelmCore/AddressBar` | Editing text, rows, selection, popup flag; request carries path, showHidden, generation |
| `LoadOptions`, `ReducerContext` | `HelmCore/Tab` | `LoadOptions` Equatable; `ReducerContext` as described at `:584` |
| `LoadEvent`, `AccessBroker`, `AccessGrant` | `HelmFileSystem` | As at `:705`, `:1078` |
| `Conflict`, `PlanningIssue`, `PlanSummary`, `OperationError`, `CrossVolumeMoveBehaviour` | `HelmOperations` | Value types; errors conform to `Error`, `Sendable` |
| `FileNameError`, `SidebarMode` | `HelmCore` | Enums |
| `ImageRequesting`, `ImageRequestToken`, `ContentWidget` | `HelmUI` | Protocols; `ContentWidget` has `apply(snapshot:)`, `apply(selection:)`, `scrollAnchor`, `focusView`, `activate()`, `deactivate()` |
| `TabStore`, `WindowStore` | `HelmUI/State/` | `@MainActor` classes that run effects |
| `StoreLocation`, `UserStrings`, `Limits` | `HelmPersistence`, per module, `HelmCore` | As used; add to section 3.3 |

**Fix 6. Make the resolver escaping.** Location: `:911`. Replace with:

```swift
public func execute(_ plan: OperationPlan, policyResolver: @escaping @Sendable (Conflict) async -> ConflictResolution) -> (progress: AsyncStream<OperationProgress>, result: Task<OperationResult, Never>)
```

**Fix 7. Make the manifest buildable on Linux.** Location: section 3.4 sketch and `:361`.
Replace the static target list with:

```swift
var products: [Product] = [ /* core library products */ ]
var targets: [Target] = [ /* core and core test targets */ ]
#if os(macOS)
products += [ /* HelmApp library, Helm executable */ ]
targets += [ /* HelmUI, HelmApp, Helm, HelmUITests */ ]
#endif
let package = Package(name: "Helm", platforms: [.macOS(.v14)], products: products, targets: targets)
```

Replace `:361` with: "On Linux, `swift build` and `swift test` cover exactly the core modules. `swift test --filter` selects what runs, not what builds, so a macOS-only test target in the manifest would break it."

**Fix 8. Add a Linux availability table.** Location: new subsection of 11.2, and amend `:186-189`.
"From memory of swift-corelibs-foundation; confirm on the first toolchain run. Anything listed stays behind `#if os(macOS)` in core modules."

| API | Linux [K] | Rule |
|---|---|---|
| `NSPredicate(format:)` | Unavailable | `SpotlightQueryBuilder` returns format string and arguments; only `SpotlightSearchService` builds the predicate. Correct the `:188` claim. |
| `NSMetadataQuery`, `CoreServices`, `Combine`, `UTType` | Absent | Guarded or kept out of core |
| `DispatchSource.makeMemoryPressureSource` (`:695`), `makeFileSystemObjectSource` (`:775`) | Unavailable | Guarded; polling monitor on Linux |
| `FileManager.trashItem`, `AutoreleasingUnsafeMutablePointer`, `URL.bookmarkData` | Absent or unimplemented | Behind `LiveFileSystem` macOS paths; fake used in tests |
| `URLResourceValues.contentType`, `volumeAvailableCapacityForImportantUsage` | Absent | Guarded |
| `autoreleasepool` | Absent | Wrap in `HelmCore/Support/AutoreleaseScope` with `#if canImport(ObjectiveC)` |
| `@objc`, `#selector`, dynamic `NSObject` behaviour | Absent | None in core modules |
| `as NSString`, `as NSURL` | No implicit bridging | Use URL APIs or `NSString(string:)` |
| `Date.FormatStyle` | Absent at 5.9 | Use `DateFormatter` |
| `localizedStandardCompare`, `ByteCountFormatter` | Present; output may differ | Do not assert exotic orderings or exact byte strings in Linux tests |

**Fix 9. Require explicit public initializers.** Location: `:1211-1227`, new rule 18.
"Every `public struct` in a core module declares an explicit `public init`. Implicit memberwise initializers are internal and fail across modules. Custom `==` and `hash(into:)` are `public`. Script check 4 enforces this."

**Fix 10. Replace the migration design.** Location: `:1109` last sentence and `:1134` first two sentences.
Replace with: "`LegacyDefaultsMigrator` runs once at launch before any store loads, guarded by `helm.migration.v1.done`. It reads `UserDefaults.standard` and `persistentDomain(forName: "Helm")`, the domain the `swift run` route is expected to use (00b M-34, C-25; confirm at handoff). It never deletes or renames a legacy key, so the old build keeps working after a rollback. Merge rules: stars and bookmarks union by standardized path; recents keep the newest `lastAccessedAt` per path; settings copy from the `Helm` domain only where the bundle domain has no value. Formats: `com.helm.starredFiles` and `helm.bookmarks` are `[URL]` JSON Data; `helm.recentAccessRecords` is `[{path, lastAccessedAt}]` JSON with `JSONEncoder`'s default date strategy. Bookmarks migrate unfiltered, so a bookmark on an unmounted volume survives (B-029). Derived fields: `name` from today's `displayName`, `addedAt` the migration date, `kind` directory. Each JSON file is written atomically before the flag is set. A decode failure leaves the legacy value untouched and reports once. The reader sits behind a protocol so `HelmPersistenceTests` cover it on Linux with literal fixture bytes." Delete "so no settings migration is needed" from `:1109`.

### Majors

**Fix 11. Complete the reducer.** Location: `:439-454`, `:548-577`.
Add actions: `starsChanged(Set<ItemID>)`, `settingsChanged(SettingsSnapshot)`, `activated`, `deactivated`, `setScrollAnchor(ItemID?)`, `beginInlineRename(ItemID)`, `endInlineRename`, `openCompleted(URL, Bool)`, `cutSetChanged(Set<ItemID>)`, `monitorSnapshot(Generation, PresentationSnapshot)`. Add effects: `refreshPaths(Set<String>, Generation)`, `persistShowHidden(Bool)`, `invalidateCache(URL)`, `beginInlineRename(ItemID)`. Add fields: `pendingNavigation: PendingNavigation?`, `lastDirectory: URL?`, `inlineRenameID: ItemID?`, `snapshotCounter: UInt64`, `cutIDs: Set<ItemID>`. Change `.navigate` to carry `Location?`, or split out `.goBack` and `.goForward`, so the history value is not duplicated. State Trash search scope in F-043.

**Fix 12. Define the commit point.** Location: section 4.3, new paragraph; `:1080`.
"`.navigate` sets `pendingNavigation` and starts the load. Location, history and snapshot do not change yet. Commit happens on the first batch or on an empty finish for that generation: history updates per intent, `location` is set, selection resets or restores, `recordRecent` is emitted, and `representedURL` updates. `.loadFailed` before commit clears `pendingNavigation`, keeps the old location and history, and sets `phase = .failed(error, attempted: Location)`, which retires B-069. Try Again re-navigates to `attempted`. Recent records on push, up, home, back and forward (preserving 00b M-16), and no longer on the reload after clearing a search; list that one as an intentional change."

**Fix 13. Define snapshot identity and move merging off main.** Location: `:521`, `:551`, snapshot declaration.
"`id` is a per-tab counter stamped by the reducer from `snapshotCounter` on every accepted snapshot, and is distinct from `loadGeneration`." Change to `case loadProgress(Generation, PresentationSnapshot)`, built by `SnapshotBuilder` in the load task. Add a test that a monitor rebuild with identical entries but a new id passes `removeDuplicates`.

**Fix 14. Make `send` non-reentrant and define sink rules.** Location: `:591`, `:595`, section 4.3.
"`TabStore.send` appends to a FIFO queue. A drain flag means a nested call enqueues and returns. Sinks use their parameter and never read `store.state`, because `@Published` fires in `willSet`. `SelectionBinder` sets `isApplying` around programmatic selection and ignores delegate callbacks while it is set. `NSOutlineView.selectRowIndexes` fires the delegate; `NSCollectionView.selectItems` does not (00b M-22), so grid paths send explicitly." Add a test: a sink that sends during delivery loses no action.

**Fix 15. State the witness rule.** Location: `:601`, `:705`, section 11.2.
"Synchronous stream-returning requirements are witnessed by a struct, or on an actor by `nonisolated func` that creates the stream and a `Task` that awaits the actor. `InMemoryFileSystem` is an actor using this form." Also correct `:1170`: `AsyncStream.Continuation` is itself Sendable for Sendable elements, so it needs no box [K].

**Fix 16. Rename colliding types.** Location: `:108`, `:185`, `:261`, `:292`, `:446`, `:556`, `:1218`.
`SortDescriptor` becomes `ItemSort`; `Clock` becomes `HelmClock`; `GridItem` becomes `GridItemCell`. Add to the checklist: "Never name a public type after a Foundation, SwiftUI, AppKit or `_Concurrency` type. Script check 3 holds the list."

**Fix 17. Define cross-module UI wiring.** Location: section 8.3, section 3.1 `:192`.
Add `@objc public protocol AppLevelActions` in `HelmUI`, covering new window, settings and about, used by `MainMenuBuilder` through `#selector(AppLevelActions....)` and adopted by `AppDelegate`. Add `public struct WindowDependencies` in `HelmUI`, built by `AppEnvironment` and passed to `MainWindowController.init`.

**Fix 18. Replace the `IOExecutor` text.** Location: `:600`, `:1163`, `:1220`.
"`IOExecutor.run<T: Sendable>(volumeKey: String, _ work: @escaping @Sendable (CancellationFlag) throws -> T) async throws -> T` bridges a blocking closure with `withCheckedThrowingContinuation` inside `withTaskCancellationHandler`. It owns one `OperationQueue` per volume key: width 4 on local volumes, width 1 on network volumes. Closures poll the flag. A guard ensures the continuation resumes exactly once. A timeout resumes with `.timedOut` and marks the lane hung; later calls on it fail fast and the UI shows an unresponsive-volume state (B-107)." Delete `DispatchSemaphore` from rule 10. The two documented `@unchecked Sendable` uses become the FSEvents context box and `CancellationFlag`.

**Fix 19. Correct lifetime rules.** Location: `:603`, `:1221`.
"`deinit` of a `@MainActor` class is nonisolated. It may cancel stored `Task`s and touch Sendable stored values. It may not call isolated methods or await. To stop a monitor: `let monitor = self.monitor; Task { await monitor?.stop() }`. Never capture `self` in a task from `deinit`. Real teardown happens in an explicit `teardown()` called from `windowWillClose`."

**Fix 20. Restore completion semantics.** Location: `:738`, F-016 (`:84`), F-017 (`:85`).
Replace the first clause of `:738` with: "The provider enumerates the whole parent off the main actor (names and isDirectory only), filters anchored and case-insensitive, sorts directories first then `localizedStandardCompare`, and only then caps at 50, as `PathCompletionService.swift:57-85` does. It never stops early, because enumeration order is arbitrary. The 3 s cache applies to prefix completion only. Slash browsing has zero debounce and always re-lists." In F-017, delete "with a streaming first page". Add: "A programmatic edit must not bump the generation after its request is issued." Add test `tabTabTabDrillShowsLastDirectory` with a fake provider that responds late, recording the failure noted in the source comment at `BreadcrumbBar.swift:467-535`.

**Fix 21. Correct the address-editor mechanism.** Location: F-024 (`:92`).
Replace the mechanism sentence with: "Programmatic edits call `shouldChangeText`, replace through `textStorage`, and call `didChangeText` inside a synchronous `isApplyingProgrammaticEdit` guard, with a next-run-loop reset as a safety net (`BreadcrumbBar.swift:370-392`). `insertText(_:replacementRange:)` is not used; it is documented for user typing and fires change notifications. Focus-loss decision order in `controlTextDidEndEditing`: Return commits; an intentional `FocusCoordinator` move ends editing; a mouse-down outside the bar cancels; `field.window == nil` waits 150 ms then resumes or ends; another control having taken first responder ends editing; otherwise re-acquire (`BreadcrumbBar.swift:826-877`, `:674-685`)." As written, the row drops the default re-acquire and the deferred path, which is what keeps editing alive through toolbar relayout (commit `f0a00d0`). Label [Mac].

**Fix 22. Settle Return, Space and Rename.** Location: `:1041`, `:1043`, F-049 (`:118`).
Replace the `:1041` Rename sentence with: "Rename on bare Return validates that the pane is first responder, there are no modifiers, and at least one item is selected. One item starts inline rename; several open batch rename (F-055, B-118)." Replace the first sentence of `:1043` with: "Return and Space are menu key equivalents, as `main.swift:77-78` and F-049 require. Their validation requires the pane as first responder and no modifiers. Space's validation also returns false while a type-select run is active, so the space reaches `TypeSelect`. `keyDown` handles only type-select characters." Verify at handoff that a disabled key equivalent passes through to the responder [Mac].

**Fix 23. Make pane commands safe inside text.** Location: `:1041`.
Add: "Rule: `moveSelectionToTrash`, `deleteSelectionPermanently`, `renameSelection`, `toggleStar`, `duplicateSelection`, `openSelection` and `toggleQuickLook` validate false when `window.firstResponder is NSText`, so the key reaches the text view. Cmd+Backspace in the address field edits text; it does not trash the selection." Add to handoff tests [Mac].

**Fix 24. Stop focus theft.** Location: `:1055`.
Split the row: "Window shown, tab switched, view mode switched: the active content widget." and "Navigation-initiated load finished: the active content widget, only if the first responder is nil, the window, or the previous widget. Never from search results or monitor reloads."

**Fix 25. Keep sidebar keyboard navigation.** Location: F-027 (`:95`).
Replace the parenthesis with: "`List(selection:)` stays for highlight and arrow keys, and a selection change navigates as today (00b M-14). A `simultaneousGesture` handles re-click on the highlighted row, which re-navigates. Highlight follows the committed location." Label [Mac].

**Fix 26. Correct the Devices filter.** Location: F-031 (`:99`).
Replace the name-filter fix with: "Exact case-insensitive names `Preboot`, `Recovery`, `VM`, `Update`, `Hardware`, `xarts`, and the ` - Data` suffix, so `VM Images` stays visible (B-080). Internal-name dedupe by lowercase name stays when show-all is off (`VolumeService.swift:97-100`). UUID dedupe falls back to path (`:89-91`). Sort internal first (`:138`)."

**Fix 27. Keep the grid icon size.** Location: `:1098`, F-035.
Replace with: "`helm.gridIconSize` | Double, default 96, 48 to 128 step 16 | grid layout (live)". Note: "The stored default was 64 but nothing read it (B-059). 96 preserves today's rendering. An explicitly stored value is honoured." Add: "Item size is the icon size plus 44 in each dimension, which gives today's 140×140 at 96."

**Fix 28. Ask about trash confirmation.** Location: F-053 (`:122`), `:1095`, section 14.
Add Q10: "`helm.confirmBeforeTrash`: confirm on every Move to Trash? Today's behaviour is no prompt, because the key is unread (B-048). Default assumed: registered default false, so Cmd+Backspace stays immediate and undoable. A value the user explicitly stored is honoured."

**Fix 29. Do not reverse the owner's decision by default.** Location: F-013 (`:81`), Q1 (`:1298`).
Change the disposition to Keep, pending Q1. Row text: "A single click on any segment enters edit mode, as commit `08f0cea` made deliberately. Separator clicks do nothing." Q1 default: "Keep current click-to-edit until answered. The alternative restores the README promise (B-051)." Delete "Product decision". This needs the owner's answer before `BreadcrumbView` is written.

**Fix 30. Keep directories in templates.** Location: F-057 (`:126`).
Replace "(files only; directories excluded)" with "(files and directories; a directory template is copied recursively, as today)". State the order: `localizedStandardCompare`, listed as an intentional improvement on today's enumeration order.

**Fix 31. Make the audit normative, and add omitted details.** Location: start of section 2.1, plus the rows below, plus a new section 8 entry.
Add: "The 00 row and its 00b corrections are normative for every detail a row here omits. 00 sections 2.7 and 2.8 are normative for menus, the keyboard map and context menus. A row overrides them only where it says so."

| Row | Add | Source |
|---|---|---|
| F-012 | Recent label is 14 pt semibold | `BreadcrumbBar.swift:159` |
| F-018 | `hidesOnDeactivate`, `becomesKeyOnlyIfNeeded`, `.utilityWindow`; 16 pt icon, 13 pt name, trailing "/" for directories; double-click accepts | `PathCompletionWindowController.swift` |
| F-003 | `.iconOnly`, no customization, view-mode and search at `.low` priority, path at `.user`; search item `sendsSearchStringImmediately` true, `sendsWholeSearchString` false; `center()` after autosave name | `MainWindowController.swift` |
| F-004 | `collapseBehavior = .preferResizingSiblingsWithFixedSplitView`; 0.12 s animation then `adjustSubviews` | `MainSplitViewController.swift:18`, `:42-48` |
| F-026 | Recent icon and Trash colour from the 00 row | 00 |
| F-045 | `relativeDepth = max(0, itemComponents - homeComponents - 1)`; `isInUserContent` excludes `home/library/`; roots: documents, desktop, downloads, projects, work, pictures, movies, music, developer, sites, code, coding, applications, public, plus visible Home folders except library and .trash | `SpotlightSearchService.swift:264-293`, `:336`, `:396-399` |
| F-046 | Query sort `kMDItemFSContentChangeDate` descending, then `NSMetadataItemFSNameKey` ascending; these decide which candidates survive the cap | `:51-54` |
| Section 2.8 | New `ContextMenuBuilder` entry: item order verbatim from 00, plus stated positions for new items | `FileContextMenuBuilder.swift` |

**Fix 32. Give the pure sort and ranker their inputs.** Location: F-040 (`:108`), F-045 (`:114`), `FileEntry`.
Add `public let kindDescription: String?` to `FileEntry`, filled by `MetadataReader` on macOS and cached per type identifier; `.kind` sorts by it with `localizedStandardCompare`. The ranker takes `isDocumentLike: Bool` per candidate, computed under `#if os(macOS)` as `UTType` conforming to text, pdf, image or audiovisualContent, or by an extension in `txt, md, rtf, pdf, doc, docx, odt, pages, xls, xlsx, numbers, ppt, pptx, key, csv, json, yaml, yml, xml` (`SpotlightSearchService.swift:405-421`). Linux tests use the extension list.

**Fix 33. Finish clipboard semantics.** Location: `ClipboardTransaction`, F-051.
"Record `changeCount` immediately after writing. After a successful cut-move, clear the pasteboard if `changeCount` is unchanged, so a second paste does not fail on moved URLs. If it changed, leave it alone." `selectAll(_:)` on the pane must leave the model and status bar updated; verify the delegate fires [Mac].

**Fix 34. Fix the sidebar selector and write the binding table.** Location: `:1032`, section 8.3.
Rename to `helmToggleSidebar(_:)`. `NSSplitViewController` already implements `toggleSidebar(_:)` and sits in the chain, so it would run AppKit's version and bypass F-004's animation [K]. Add a binding table covering every entry in 00 section 2.7 plus new bindings. Keep the proven forms verbatim: `Selector(("undo:"))`, `Selector(("redo:"))`, `#selector(NSText.cut(_:))` and siblings, Return `"\r"`, Trash `"\u{8}"` with Cmd, Home `"H"` (`main.swift:67-118`). Put `CommandID` and a `KeyBinding` table in `HelmCore`, tested on Linux against a fixture copied from 2.7.

**Fix 35. Drive file-operation undo from the journal, not `UndoManager`.** Location: `:958`, `:187`, section 13 undo ADR.
Replace `:958` with: "File-operation undo does not use `UndoManager`. `OperationJournal` holds the undo and redo stacks and exposes `canUndo`, `canRedo`, `undoTitle`, `redoTitle`. `MainSplitViewController`, which sits in the pane's responder chain just before the window, implements `undo(_:)` and `redo(_:)` and validates them, setting the menu title from the journal. If `window.firstResponder is NSText`, it forwards to `window.undoManager`. Address and search fields are in the toolbar, so their chain does not pass through this controller and they reach the window's own undo. The delegate does not implement `windowWillReturnUndoManager`. The journal entry reference is captured before the awaited execution, so a tab hidden mid-operation still records (B-105). Undo and redo run as tracked operations and refresh affected directories (B-043)." This removes the nil-manager and async-redo defects, retires the target-lifetime problem behind B-100 by construction, and makes `OperationJournal` fully Linux-testable. Keep `Selector(("undo:"))`. Routing to verify at handoff [Mac].

**Fix 36. Use the proven responder position.** Location: `:1007`, `:1010`.
Replace with: "`MainWindowController` is the responder for commands, as it already is for `copy`, `cut` and `paste` (`MainWindowController.swift:289-299`). It implements every `@objc` action and `NSMenuItemValidation`, forwarding to `CommandDispatcher`, a plain `@MainActor final class` holding the logic. Because the window controller follows the window, a text view always gets the first chance. `undo(_:)` is the exception (Fix 35)." The class declaration becomes `@MainActor public final class CommandDispatcher` with plain methods, unit-tested in `HelmUITests`.

**Fix 37. Correct drag modifiers and signatures.** Location: `:136`, `:984`, `:1047`, `:1182`.
Add `public struct DropModifiers: OptionSet, Sendable` in `HelmOperations`, filled in `HelmUI` from the class property `NSEvent.modifierFlags`, as `FileGridView.swift` already does for Option. Replace "the modifier flags from `draggingInfo`" with this. Source mask includes `.generic` so Cmd survives `draggingSourceOperationMask` [K], [Mac]. Replace `:1182` with the signatures in `FileListView.swift:318-343` (`outlineView(_:pasteboardWriterForItem:)`, `outlineView(_:validateDrop:proposedItem:proposedChildIndex:)`, `outlineView(_:acceptDrop:item:childIndex:)`), and add the collection-view `validateDrop` signature from `FileGridView.swift`, including `AutoreleasingUnsafeMutablePointer<NSIndexPath>`.

**Fix 38. Correct the search guard.** Location: `:188`. Replace the guard text with `#if os(macOS)`, and add `canImport(Foundation.X)` to the forbidden tokens.

**Fix 39. Correct the monitor.** Location: `:770-782`, `:773`, `:1264`.

- Filter by comparing against `realpath` of the watched directory, and map changes back by last path component.
- `MonitorRegistry.subscribe(path:) -> AsyncStream<MonitorEvent>` creates one stream per subscriber, fanned out from one FSEvents stream per path.
- Replace `rootChanged(newPath:)` with `rootChanged`, meaning "revalidate the location". Do not claim `WatchRoot` provides a new path. An optional `F_GETPATH` on an `O_EVTONLY` descriptor can be added at handoff [Mac].
- Watched set is the tab's directory plus `expandedIDs`, with a new effect `updateMonitorScope(Set<URL>, Generation)`.
- Port callback code from the proven `Services/FileMonitorService.swift`.

**Fix 40. Correct enumeration and keys.** Location: `:681`, `:685`.
"Iteration runs in a synchronous closure inside `IOExecutor`, never in an `async` function. Root open failure arrives through `errorHandler` and is mapped, including `NSFileReadNoPermissionError` and underlying `EPERM`. A preflight `contentsOfDirectory` or `opendir` distinguishes empty from unreadable, because `~/.Trash` may otherwise list empty (00b M-18, R-13). Each batch runs in `AutoreleaseScope`." Read the volume identifier once per directory and store a string from `volumeUUIDString` or mount path. Keep `.contentTypeKey` under `#if os(macOS)` with `UniformTypeIdentifiers` allowed there only.

**Fix 41. Complete Trash behaviour.** Location: `:627`, `:956`, `:980`.
Change to `func trashItem(at url: URL) async throws -> URL?`, journaling a nil result as not restorable. A volume without trash produces a "Delete immediately?" sheet listing the affected items. Add iCloud Drive's trash location to `TrashCoordinator` [K], [Mac]. Empty Trash drops only journal entries that reference emptied items, not the whole stack. Moving items out of `~/.Trash` without Full Disk Access is unverified [Mac].

**Fix 42. Make the copy engine plannable and safe.** Location: `:836-882`, `:887-915`.
Add `sourceManifest: [SourceEntry]` to `PlanningContext`, built by an async `PlanningContextBuilder` that does not follow symlinks; the planner stays pure. Add free-space preflight data. Directory metadata (dates, permissions, xattrs, flags) is applied after its children finish. Add a `FileCopier` protocol; the first live implementation uses `copyItem`, with the limitation stated that a single large file has no progress or cancel until `copyfile(3)` replaces it at handoff. Replace semantics: "Never remove before the new copy exists. Copy to a temporary name in the destination, swap, move the old item to Trash and journal it. Folder replace replaces; merge is not offered." Keep-both retries on `EEXIST` (B-039).

**Fix 43. Compare names the way the volume does.** Location: `:837`, `ValidFileName`.
Add `caseSensitive: Bool` per destination. Collision checks compare canonically decomposed, case-folded names when the volume is case-insensitive. A rename from `foo` to `Foo` of the same item is not a conflict (R-18). Do not reject `:` without a stated reason; POSIX allows it, Finder displays it as `/`, and rejecting it is a new restriction. Trim with `.whitespaces`, as the source does.

**Fix 44. Remove blind batch updates and fix scale claims.** Location: `:521`, `:799`, `:1238`, F-035.
Replace the `:521` diff sentence with: "In this rebuild widgets call `reloadData()` and reapply selection and anchor. `SnapshotDiff` serves selection and anchor mapping and is tested on Linux. Animated `performBatchUpdates` is added behind a flag at handoff, because a count mismatch raises an exception and cannot be caught by review." Reword `:799` and `:1238` so that a 100k external change is one reload bounded by visible cells, measured at handoff. Keep a `UniformGridLayout: NSCollectionViewLayout` seam in case flow layout misses budget [Mac]. Add: "While `inlineRenameID` is set, reloads are deferred until editing ends, since a reload would kill the field editor."

**Fix 45. Correct `project.yml` and build notes.** Location: `:375-377`, `:388-391`, `:360`, `:419`, section 9.
Replace the `info` and `entitlements` blocks with build settings, as the current `Helm/project.yml` does:

```yaml
settings:
  base:
    INFOPLIST_FILE: App/Info.plist
    CODE_SIGN_ENTITLEMENTS: App/Helm.entitlements
```

Move the package to `HelmKit/`, and reference it as `path: HelmKit`. A local package in a subfolder is the common layout, and moving it now costs nothing. Replace the strict-concurrency note with: "At handoff, run `swift build -Xswiftc -strict-concurrency=targeted` in `HelmKit`; the Xcode target's setting does not reach package targets." State that package tests in Xcode need explicit scheme entries. Note for the owner: `CODE_SIGN_STYLE: Automatic` needs a team, ad-hoc rebuilds can lose Full Disk Access grants tied to the signature, and Developer ID needs a paid membership.

**Fix 46. Make the conflict sheet reachable.** Location: `:852`, `:1306`, section 10.1.
Add `helm.askOnConflict` | bool, false | operations planner, with a toggle in settings. Add a section 7 sentence: "When the plan has conflicts and this setting is on, the sheet offers keep both, replace, skip, stop and apply to all; otherwise keep both applies silently as today."

**Fix 47. Specify the search service.** Location: new section 5.8 content, F-046, `:601`.

```swift
public struct SearchQuery: Sendable, Equatable {
    public var text: String
    public var scope: SearchScope
    public var bookmarkPaths: [String]
    public var homeDirectory: URL
    public var lastDirectory: URL?
    public var showHidden: Bool
    public var limit: Int
    public init(text: String, scope: SearchScope, bookmarkPaths: [String], homeDirectory: URL, lastDirectory: URL?, showHidden: Bool, limit: Int)
}
public enum SearchEvent: Sendable { case gathering, results([SearchResult], isFinal: Bool), notIndexed }
public protocol SearchService: Sendable {
    func search(_ query: SearchQuery) -> AsyncThrowingStream<SearchEvent, Error>
}
```

Lifecycle: "The `NSMetadataQuery` is owned on the main actor. On `DidFinishGathering` and `DidUpdate`, updates are disabled and at most `max(limit×3, 450)` items are read into value types on the main actor; this cap bounds the work. `NSMetadataItem` never leaves. Ranking runs off the main actor. Results carry the query generation. Cancelling the stream stops the query, scoped to its identity (B-021). `EnumerationSearchService` runs when gathering ends empty and the location appears not indexed; since no direct API reports this, the check is a heuristic [Mac]." Correct F-046 to "ranking off the main actor".

**Fix 48. Add a Finder-parity scope table.** Location: section 14, new table. Each line is for the owner to confirm.

| Capability | Status in doc | Recommended disposition |
|---|---|---|
| Eject and unmount devices | Absent | In scope: sidebar control and context menu [K] |
| Open in New Tab or Window, Cmd+double-click | Absent | In scope |
| Close Window (00b M-05), Reopen Closed Tab | Absent | In scope |
| Keyboard tab switching (Q6) | Out of scope by default | In scope; matches the keyboard-first identity. Change the Q6 default if the owner agrees. |
| Alias and symlink creation | Commands only (`:1330`) | Add menu items, bindings and selectors |
| Services for selection | Absent | In scope, small: `validRequestor`, `writeSelection` [K] |
| Default folder viewer; "Show in Enclosing Folder" still opens Finder (F-050) | Absent | Route reveal to Helm now; decide the viewer default with the owner. The mechanism is unsupported territory [Mac]. |
| `NSWindow.allowsAutomaticWindowTabbing = false` | Absent | Add, or the system adds tab items that conflict with Helm's tabs |
| Selection after trash | Absent | Select the next item |
| Starred badge, hidden-file dimming | Unclear | State in F-035 and F-036 |
| iCloud placeholders, File Provider | Absent | Handle evicted items in `MetadataReader`; test at handoff [Mac] |
| Free-space preflight | Absent | Fix 42 |
| Connect to Server, network places | `PlaceKind.network` seam | Later |
| Compress and decompress | Absent | Later |
| Get Info editing and multi-select, preview pane, tags | Read-only or deferred | Later |
| Column and gallery | Deferred (`:1330`) | Later; declare `ContentWidget` now (Fix 5) |
| Localization | Rule 14 only | Later; note in risks |

**Fix 49. Define launch precedence.** Location: F-001, `:1107`, section 10.3.
"A launch carrying an open request opens only the requested window and does not restore. Otherwise, with `helm.restoreSessionOnLaunch` true and a saved session, restore it. Otherwise open one window at Home. Implement only one of `application(_:open:)` and `application(_:openFiles:)`."

**Fix 50. Resolve rule conflicts.** Location: `:1174`, `:1185`, `:1198`, `:1207`, `:1213`, `:1220`, `:1080`.

| Case | Canonical form |
|---|---|
| Custom init on an AppKit subclass | `required init?(coder: NSCoder) { return nil }` |
| `makeItem` | `guard let item = view.makeItem(withIdentifier: id, for: path) as? GridItemCell else { return NSCollectionViewItem() }` |
| QL overrides | Exempt the exact signatures copied from `FileListViewController.swift`, including their IUOs |
| Function-key equivalents | `KeyEquivalent.string(for: Int) -> String` helper that returns `""` on failure |
| System URL | Change `:1080` to use `Support/URLLiterals.swift` returning `URL?`; no `!` |
| Run-loop deferral | `Task { @MainActor in }`; timers use `Task.sleep` in a stored, cancelled task |
| Porting | `nonisolated(unsafe)` in ported code (B-004) is removed during the port, not copied |

**Fix 51. Add these blind-build rules.** Location: `:1209-1227`.

19. Port call sites from the old source for FSEvents, Quick Look, drag and drop, thumbnails and menus rather than writing them from memory. Keep the old tree until the first successful compile.
20. Never read `store.state` inside a sink (Fix 14).
21. Never capture `self` in a task created in `deinit` (Fix 19).
22. Every `#selector(X.y(_:))` has an `@objc func y(_` in `X`.
23. Responder-method `override` is a known uncertainty: `selectAll(_:)`, `cancelOperation(_:)` and similar come from an optional protocol and may or may not need `override` on a direct `NSResponder` subclass [K]. Fix at handoff; do not guess repeatedly.
24. `NSTableCellView.textField` is always set on the name cell, as native type-select relies on it (`FileListView.swift:211`).
25. Use `URL(fileURLWithPath:)` and `appendingPathComponent`, not `URL(filePath:)` or `appending(path:)`, for Linux and macOS consistency.
26. Directory enumerators are used only in synchronous closures (Fix 40).
27. Build order is core modules, then `HelmUI` leaf views, then windows, then `HelmApp`. No file may reference a type before its declaring file is merged.
28. The handoff compiler will be whatever the owner's Xcode ships, in Swift 5 language mode. Do not rely on a specific compiler's diagnostics.

**Fix 52. Script the static checks.** Location: `:1207`, new subsection of section 11. All run on Linux with no toolchain, using Python and grep, except where noted.

1. **Import boundary** per target, from the `:183-194` table.
2. **Symbol-table module check.** Regex declarations per module, then verify every capitalized identifier in a public signature resolves to its own module, an allowed dependency, or an SDK allowlist. This would have caught Fixes 1, 2 and 3.
3. **Forbidden tokens.** Extend `:1207` with `canImport(Foundation.`, `Combine` and `ObservableObject` in core, `UTType` in core outside guards, `@objc` and `#selector` in core, `URL(filePath:`, and public type names that collide with an SDK list. Tighten the `!` pattern; as written it misses `x!)` and `x!,`.
4. **`public struct` without `public init`.**
5. **Selector audit:** `#selector(X.y(_:))` against `@objc func y(_` in `X`.
6. **Await lint:** calls to known actor types without `await` from non-actor context.
7. **Doc-to-code drift:** public signatures in code against this document's signatures.
8. **Coverage table:** F-ID to test mapping.
9. **Config validity:** `plistlib` for Info.plist and entitlements; YAML parse of `project.yml`, and assert it has no `info:` block.
10. **Syntax check** with tree-sitter-swift.

Recommendations that need the owner's approval, and which this review does not act on:

- Install a Swift toolchain on the Linux machine. Then `swiftc -parse` covers all files, `swift build` and `swift test` really run for core modules, and `swift-format lint` becomes available. This turns much of the [K] in Fix 8 into observation.
- Use a macOS CI runner for a real compile loop before handoff. This is the highest-value single change, and it may cost money.
- Copying the macOS SDK to Linux is not recommended because of licence restrictions.

### Minors

**Fix 53. Correct coverage counts.** Location: `:138`. Replace with "Keep 12, Keep+fix 45, Redesign 13, Drop 2" and re-count after Fix 29 moves F-013 to Keep.

**Fix 54. Use one JSON envelope.** Location: `:1117-1124`. Choose `{ "schemaVersion": 1, "items": [...] }` and make `VersionedDocument` match it, with the payload key stated.

**Fix 55. Journal entry lifecycle and B-041 wording.** Location: `:147`, `:956`, `:958`. Add `journal.begin(command) -> EntryID` and `journal.complete(id, outcomes)`; "created before execution" cannot hold for an immutable entry with outcomes. Align the B-041 row with `:956`: undo always trashes and warns on a changed token. Add child count to `ChangeToken` so directories are detected.

**Fix 56. `TreeSnapshot` overlap.** Location: `PresentationSnapshot.children` and `TreeSnapshot`. Keep one source for expanded children and say which.

**Fix 57. Diagram.** Location: `:200-230`. Remove the implied edge from `HelmPersistence` to `HelmSearch`, and add `HelmTestKit` to `HelmFileSystem`.

**Fix 58. `GhostOverlay` rule.** Location: `:1219`. F-023 places `GhostOverlay` in AppKit, so delete the `GeometryReader` exception.

**Fix 59. Map remaining bugs.** Location: section 2.2. Add one line each.

| Bug | Disposition |
|---|---|
| B-004 | Retired: `nonisolated(unsafe)` banned, tools 5.9 true |
| B-005 | Retired: ranker has no `#if DEBUG` API |
| B-006 | Retired: custom runner removed, XCTest only |
| B-007 | Documented: `swift run` is for development only (`:1081`) |
| B-008 | Handoff asset task: icon artwork |
| B-014 | Retired by monitor generation lanes |
| B-064 | Sendable rules in `:601` |
| B-065 | ADR-006, section 9 |

**Fix 60. Pin two address-bar details.** Location: F-017, F-023. The source prepends `..` and then takes `prefix(50)`, so `..` counts inside the cap; state this rather than "`..` then up to 50 children" (`BreadcrumbBar.swift:467-535`). For F-023, state whether accepting with `~` input keeps `~` or expands it. Today Tab rewrites to absolute (00b M-12). Recommended: keep `~` as typed, listed as an intentional change.

**Fix 61. Type-select.** Location: F-041. State the `cell.textField` dependency, or implement the outline view's `typeSelectStringFor` delegate. The grid needs a `NSCollectionView` subclass for `keyDown`. Remove "arrow keys for type-select" from `:1043`.

**Fix 62. Memory estimate.** Location: `:695`. 300 bytes is optimistic given a URL, two path strings, type strings and three ID-keyed structures [K]. Derive `url` from parent and name, intern content type and volume strings, and replace `entries` plus `sortedIDs` with `sortedEntries` plus an index. Mark 30 MB as a target to measure.

**Fix 63. Main-thread checks.** Location: `:591`, `:1246`. Use `dispatchPrecondition(condition: .notOnQueue(.main))` inside the synchronous I/O closure, and `dispatchPrecondition(condition: .onQueue(.main))` or `MainActor.assertIsolated()` for `assertMain`, which is otherwise undefined.

**Fix 64. Small API notes.** Location: as listed; all [Mac].

- F-072: test the proxy icon with a hidden title.
- F-003: use `setFrameUsingName` to decide when to centre.
- Share menu: prefer `standardShareMenuItem` for the submenu, over a picker alone.
- Grouped toolbar items may validate differently; test `validateToolbarItem` on them.

**Fix 65. `ListingCache` key.** Location: section 5.3. Key includes `showHidden`, as `FileSystemService.swift:7-10` does. Stale-while-revalidate never presents `.ready` for a directory that has been deleted.

## Overall verdict

**Not ready for feature authors as written. Revise and do a targeted re-review; a redesign is not needed.**

The architecture direction is sound and worth keeping: reducer plus immutable snapshots, generation guards, planner and executor split, one package of modules with a thin app target, and no sandbox. Preservation work is extensive and mostly accurate, and the 72-row map is a real asset. As written, however, the first author would hit a compile-impossible core module, the Linux test command would fail, and user data could silently disappear at first launch.

Recommended sequence:

1. Apply Blockers 1 to 10, along with Fixes 16, 50, 51 and 52, since they change what authors copy.
2. Get the owner's answers on Q1 (Fix 29), Q10 (Fix 28), Q6 and the scope table (Fix 48), and on the toolchain and CI recommendations (Fix 52).
3. Apply the remaining Majors.
4. Re-review sections 3, 4, 7.6, 8.3, 10 and 11 only, and run the symbol-table check once against the revised signatures.

## Unresolved risks

- **Nothing here has been compiled.** All [K] statements, including the Linux availability table, the XcodeGen overwrite behaviour, `canImport` handling and shadowing rules, are from knowledge and could be wrong in detail. The number of errors at handoff remains unknown until something compiles.
- **Runtime verification list R-1 to R-19 from 00b remains open,** and this review adds to it:
  - undo routing (Fix 35)
  - disabled key equivalents passing through (Fixes 22, 23)
  - window controller responder position (Fix 36)
  - Cmd in the drag mask (Fix 37)
  - FSEvents paths (Fix 39)
  - sidebar keyboard and re-click (Fix 25)
- **Scale.** Flow layout and `NSOutlineView` at 100k items, select-all budget, and memory per entry are unmeasured. The `UniformGridLayout` seam may become required work.
- **TCC.** Behaviour of `~/.Trash` enumeration and moving items out of it without Full Disk Access is inferred only. Grants may not survive ad-hoc re-signing, which can make handoff testing confusing.
- **Defaults domain.** Whether the owner's real data sits under `Helm`, `com.helm.filemanager` or both is unknown until checked on the owner's Mac. Fix 10 handles both, but a first-launch check should confirm counts.
- **Product decisions unanswered:** Q1, Q5, Q6, the proposed Q10, and the scope table. Q1 in particular blocks `BreadcrumbView`.
- **Signing and distribution.** Developer ID needs a paid membership, which is the owner's decision. `:1073` assumes it.
- **Large-file copy** has no progress or cancel until `copyfile(3)` replaces the first implementation.
- **Xcode layout.** The package location and scheme naming can only be proven by opening the project on a Mac.
- **Compiler version.** The owner's Xcode may ship a later compiler than 5.9. Swift 5 language mode limits the effect, but warnings and some availability diagnostics may differ from what this document assumes.
- **Localization** is deferred. Rule 14 centralizes strings, but layouts are specified for English.
