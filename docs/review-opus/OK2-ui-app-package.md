# OK2: Helm UI, App, package and Mac handoff

**Review of Astra draft, 2026-11-04 after 22:00 Toronto**

Scope: `Sources/HelmUI`, `Sources/HelmApp`, `Package.swift`, project and manifest files, `scripts/rebuild`, `docs/handoff/MAC_HANDOFF.md`, `docs/handoff/VERIFICATION.md`.

## Summary

- **Helm cannot launch.** HelmUI is a kit of leaf views and models. There is no app delegate, window controller, split view, tab host, toolbar, grid, list, menu or executable.
- **One definite compile error was found by reading:** `DropProposal` in `ContentOverlays.swift`. The fix exists only in the uncommitted working tree.
- **No other definite compile error was found** in HelmUI or HelmApp. Nothing has been compiled against an Apple SDK, so that is a reading result only.
- **The Mac prompt is not ready to paste.** Its staged Stage 1 and Stage 2 patches are correct. It assigns no owner, so the session stops at inventory, and Stage 3 contradicts the architecture.
- **Findings:** 39 in total: 3 Blocker, 10 Major, 26 Minor. 21 fixes are SIMPLE and 18 are JUDGEMENT.

## Baseline and evidence limits

- **Branch:** `forge/rebuild-build`. HEAD is `4ab4d8f` according to the session's git snapshot. This session has no shell, so `git log -1` could not be run.
- **Moving tree:** the working tree is dirty with uncommitted AK1 and AK2 lanes. File lines below refer to the working tree as read at the time of writing. In scope, only `ContentOverlays.swift`, `scripts/rebuild/run_all.sh` and the new `scripts/rebuild/check_core_type_names.py` changed during this review.
- **Handoff pin:** the handoff documents are pinned to `0021ac6`, which is older than HEAD.
- **Nothing was built or run.** All results come from reading source, tests and documents.
- **O1 was not read,** as instructed. Undo and journal safety belongs to that review. OK2-6 covers only the composition root.

Evidence tags:

| Tag | Meaning |
| --- | --- |
| [S] | Read directly in source or a document |
| [K] | SDK knowledge, not compiled |
| [Mac] | Needs a compile or hosted check on a Mac to confirm |

## What the Mac session must do first

Do these in order, and stop at the first step that fails.

1. **Freeze and record.** Record the revision, `git status --short`, Xcode, SDK, Swift and hardware. Edit nothing.
2. **Check the known fix is present.** `Sources/HelmUI/Content/ContentOverlays.swift:30,32` must read `HelmCore.DropProposal`. If it does not, the revision predates AK1, so stop and report (OK2-3).
3. **Read the new review records.** Read `docs/review-opus/` (O1, OK1, OK2 and the fixes-AO and fixes-AK reports) along with the prompt's reading list. The prompt omits this directory.
4. **Run the inventory** at `MAC_HANDOFF.md:197-209`. Then run `python3 scripts/rebuild/check_core_type_names.py --self-test`. The full guard is expected to exit 1 on four retained Core names until the rename decision (OK2-35).
5. **Get a Darwin baseline before any manifest change.** Run the six `swift build --target` commands at `:216-221`, then the test filters at `:227-233`. Record counts, skips and failures. Do this first because `swift test --filter` compiles every declared test target, so one HelmUI compile error would hide the whole portable result (`:224`). Do not compare against 1,198 tests; the tree has changed since that count.
6. **Confirm written ownership** from Huseyn for `Package.swift`, `Sources/HelmUI`, `Sources/HelmApp`, `Tests/HelmUITests` and `Tests/HelmAppTests`. Without it, stop and report here (OK2-2).
7. **Apply Stage 1** (`:243-252`). Run `swift package dump-package`, then `swift build --scratch-path /tmp/build-MAC-HANDOFF --target HelmUI`. Fix the earliest error and recompile its consumers.
8. **Run HelmUITests from the repository root.** Confirm `SettingsBindingsTests` and `ContentNativeAdapterTests` are discovered and execute; neither has ever been compiled. Do not count `testSearchAdapterTypechecksAgainstCurrentCore` as evidence, because it is empty on macOS (OK2-31).
9. **Apply Stage 2** (`:258-267`). Build HelmApp and run HelmAppTests.
10. **Run the strict concurrency passes** (`:286`) on the targets that now build. Record expected Binding-closure noise separately (OK2-37).
11. **Run the hosted spike before any host build-out:** popover focus, IME composition and `List(selection:)` with row gestures. Three Major findings depend on it (OK2-11, OK2-12, OK2-13).
12. **Stop and report.** The native host and entry point do not exist. Assign that lane using `HelmDev` and `App/project.yml` (OK2-4). Do not touch real user data, Trash, deletion, sending or sharing without Huseyn's approval of that exact action.

## Is the Mac handoff prompt complete and correct?

**No.** Keep its structure and apply the corrections below.

### Correct as written

- **Stage 1 and Stage 2 patches** (`:243-252`, `:258-267`): all five README excludes exist, as do `Tests/HelmUITests/PortableRunner` and `Tests/HelmAppTests/LinuxRunner`. The test dependencies cover the imports [S].
- **The warning against uncommenting the old template** (`:239`).
- **Explicit `--target` builds and the note on running from the repository root** (`:216-221`, `:254`).
- **The strict coverage command** (`:208`).
- **The file inventory** (`:47-112`): it matches the HelmUI and HelmApp directories on disk.

### Required corrections

| Line | Problem | Correction |
| --- | --- | --- |
| `:186`, `:191`, `:239` | Assigns no paths, yet HelmUI work requires "explicit assignment" | Add an owner-approved sentence naming the paths in step 6 above |
| `:4`, `:10`; `VERIFICATION.md:7-10,17` | Pinned to `0021ac6` and 1,198 tests; "diff against HEAD is empty" no longer holds | Re-pin to the reviewed revision and re-record its counts |
| `:193` | Omits `docs/review-opus`; cites "local AGENTS", but no `AGENTS.md` exists in the worktree | Add the directory; change to "AGENTS.md, if present" |
| `:208` | Omits the new collision guard | Add `check_core_type_names.py --self-test` and state the full guard's expected exit 1 |
| `:233` | Skips `scripts/test_static_checks.py` | Add `python3 -m unittest discover -s scripts -p 'test_static_checks.py' -v` |
| `:224` | States the graph-compile risk but not its consequence | Say the portable baseline must run before Stage 1 |
| `:236` vs `:239-254` | `:236` implies all deliverables must exist before building HelmUI; the stages say otherwise | Limit the `:236` deliverables to Stage 3 |
| `:271-278`, `:282` | Wrong executable name and project path | See OK2-4 |
| `:280` | Omits the failure class that actually occurred | Add "SDK type-name collisions (`X is ambiguous for type lookup`)" |

## Findings

### Blocker

**OK2-1. There is no launchable app.** JUDGEMENT
- **Where:** `Package.swift:26-34`; `Sources/Helm` and `App/` do not exist. A search of `Sources/HelmApp` and `Sources/HelmUI` finds no `NSApplicationDelegate`, `NSWindowController`, `NSOutlineView`, `NSCollectionView`, `QLPreviewPanel` or `NSMetadataQuery`, and no use of `WindowStore`, `DirectoryEffectRunner`, `WindowOperationHistory` or `SearchSessionDriver` [S]. Required structure is at `01-architecture.md:1320-1333`.
- **Failing scenario:** every compile error gets fixed, and there is still nothing to launch. A user cannot open a folder, and no M10-M25 acceptance row can run.
- **Fix:** assign a native host lane. Suggested build order:
  1. `HelmDev` entry point and `AppDelegate`
  2. `AppEnvironment` to `WindowDependencies` wiring
  3. `MainWindowController` with one `WindowStore` and `DirectoryEffectRunner`
  4. Split view and sidebar, then list view (first visible folder)
  5. Menus and responders
  6. Remaining widgets

  Treat all M-gates as open until then.

**OK2-2. HelmUI and HelmApp are undeclared, and nobody may declare them.** JUDGEMENT
- **Where:** `Package.swift:26-34` (comment says targets arrive "once their source directories exist"; they already do); `MAC_HANDOFF.md:191,239`.
- **Failing scenario:** `swift build --target HelmUI` fails with no such target. The prompt forbids editing the manifest without assignment, so the session ends at inventory and no SwiftUI or AppKit line is ever type-checked.
- **Fix:** Huseyn assigns the paths in step 6. The patch itself is then mechanical. Apply it after the portable baseline, and replace the stale comment at `Package.swift:27`.

**OK2-3. The `DropProposal` fix is not committed.** SIMPLE
- **Where:** `ContentOverlays.swift:2-5,30,32` imports SwiftUI and HelmCore, and both export `DropProposal` (`HelmCore/DragDrop/DropValues.swift:59`). The working tree has the qualifier, but git lists the file as modified against HEAD. Same root cause as OK1-1; tracked here for its handoff consequence.
- **Failing scenario:** a Mac session on HEAD gets `'DropProposal' is ambiguous for type lookup` [K], and the first HelmUI build stops there.
- **Fix:** the orchestrator commits the two-line AK1 change before handoff. `HelmCore.DropProposal` is safe because no type named `HelmCore` exists to shadow the module [S]. `ContentLeafPresentation.swift:44` imports only Foundation and HelmCore, so it needs no change.

### Major

**OK2-4. Stage 3 contradicts the architecture.** SIMPLE
- **Where:** `MAC_HANDOFF.md:271-278,282` use executable `Helm`, a root `project.yml` and `Helm.xcodeproj`. `01-architecture.md:372,420,427` specify `App/project.yml`, an executable named `HelmDev` "to avoid an app module collision", and `App/Helm.xcodeproj`. A root project is only the documented fallback.
- **Failing scenario:** the host owner follows the prompt. A package module `Helm` meets the Xcode app target `Helm` [K, Mac], or the project lands where the architecture's static checks do not look.
- **Fix:** replace the Stage 3 snippet with the following, and use `xcodegen generate --spec App/project.yml` and `-project App/Helm.xcodeproj`. Verify that the `Helm` key in the `static_checks.py` DAG still maps correctly.

```swift
products += [.executable(name: "HelmDev", targets: ["HelmDev"])]
targets += [.executableTarget(name: "HelmDev", dependencies: ["HelmApp"], path: "Sources/Helm")]
```

**OK2-5. The prompt and verification record are stale and incomplete.** SIMPLE
- **Where:** the lines in the corrections table above. Also `VERIFICATION.md:225` ("No new likely-to-fail SDK line was established by P11"), now superseded by OK2-3.
- **Failing scenario:** the session never reads OK1 or O1, compares its counts against an old tree, and treats a known red collision gate as a new failure.
- **Fix:** apply the table. Mark `VERIFICATION.md:225` as superseded rather than deleting it.

**OK2-6. One shared journal across all windows.** JUDGEMENT
- **Where:** `AppEnvironment.swift:27,36,65,84`, against `01-architecture.md:1272,1320,1333` ("keys journals by window"; "menus only expose the active window journal"). `MAC_HANDOFF.md:129,153` disclose the conflict. K38's `WindowOperationHistory` exists but is not composed.
- **Failing scenario:** move a file in window A, press Cmd+Z in window B, and A's move is reversed.
- **Fix:** remove `journal` from `AppEnvironment`, and compose one app-lifetime operation coordinator that owns per-window history. Architecture `:1333` says the ticket, event and journal initializer details need a separate contract decision, so O1 and the owner should settle them first.

**OK2-7. Tag catalogue and per-location view options sit outside the composition root.** SIMPLE
- **Where:** `AppEnvironment.swift:29-34,58-62,89-96`; `StoreLocation.swift:7-11` has no URL for either document; no HelmApp source references `TagCatalogStore` or `LocationViewOptionsStore` [S]. `MAC_HANDOFF.md:132,305` require one owner per document and explicit flush.
- **Failing scenario:** the user edits tags or a folder's view options and quits. `flushStores` covers five documents and neither of these, so unflushed edits can be lost. Two windows creating their own instances can also overwrite each other.
- **Fix:**
  1. Add `tagCatalog` and `viewOptions` URLs to `StoreLocation`.
  2. Add both stores to `AppEnvironment.init`, `live` and `test`, using the same flushable contract and memory fakes.
  3. Add both to `flushStores`.
  4. Add a test asserting seven documents are flushed and that a failure in one does not skip the others.

**OK2-8. `AppEnvironment` cannot supply the planned `WindowDependencies`.** JUDGEMENT
- **Where:** `AppEnvironment.swift:30-34` exposes `any AppBookmarkStoring`-style protocols declared in HelmApp. `01-architecture.md:1329` requires `HelmUI.WindowDependencies` to take concrete `SettingsStore`, `StarStore`, `BookmarkStore` and `RecentStore`, plus `search`, `executor`, and ten more services at `:1331` that `AppEnvironment` lacks.
- **Failing scenario:** the first host commit cannot compile without downcasts. HelmUI also cannot name the protocols, because HelmApp depends on HelmUI.
- **Fix:** decide one contract before host work. Recommended: move the store protocols to HelmPersistence, have `WindowDependencies` take them, and extend `AppEnvironment` with the missing services.

**OK2-9. Any store load failure prevents launch.** JUDGEMENT
- **Where:** `AppEnvironment.swift:57-62`, with `JSONFileStore.swift:21-25,30,38,79`. Corrupt JSON recovers, but an unsupported schema, a permission error or a failed backup throws. The doc comment at `JSONFileStore.swift:53` says an unsupported schema makes the instance read-only, but `live` never reaches that state [S].
- **Failing scenario:** after a downgrade, `stars.json` has schema 2, or `recent.json` is unreadable. `live` throws, so the host has no environment and no window, and one optional document blocks all file browsing.
- **Fix:** give the stores a non-throwing construction path followed by an explicit load. Have `live` return per-document load failures alongside the environment, keep failed stores read-only, and show the failures to the user. Keep migration failure handling as a separate owner decision.

**OK2-10. External open policy differs from the architecture.** JUDGEMENT
- **Where:** `LaunchRouter.swift:6,31-34,58-71` and locked by `LaunchTests.swift:20-21`. `01-architecture.md:71` says folders navigate the key window and files launch through `NSWorkspace`. `MAC_HANDOFF.md:134` flags this for review. Cold-launch precedence itself is correct (`LaunchRouter.swift:41-48`, Fix 49).
- **Failing scenario:** with Helm running, each "Open With Helm" on a folder creates another window instead of navigating the key window. Opening a document reveals it in Helm rather than launching it.
- **Fix:** Huseyn confirms the policy. Recommended: follow the architecture after launch, with `route` returning separate `navigateKeyWindow` and `launchFiles` lists, and update the tests. Cold-launch requests keep creating the first window.

**OK2-11. The rename error popover likely breaks typing.** JUDGEMENT
- **Where:** `InlineRenameField.swift:28-35`.
- **Failing scenario:**
  1. The user types `/`, and the popover presents. A SwiftUI `.popover` can take key focus from the field editor [K, Mac], so further typing may stop.
  2. A click outside dismisses the popover, but `set: { _ in }` ignores the dismissal while `get` stays true. The next invalid character then has no false-to-true transition, so no message appears [K].
- **Fix:** replace the popover with inline, non-interactive text bound to `model.editing?.error`, with `allowsHitTesting(false)` and an accessibility announcement. If a list cell clips it, use a non-activating child `NSPanel`. Confirm in the hosted spike.

**OK2-12. Rename has no end-of-editing path.** JUDGEMENT
- **Where:** `InlineRenameField.swift:70-92` has no `controlTextDidEndEditing` and no callback. `:86` handles `insertTab` only, not `insertBacktab`. The README assigns focus loss to the host, but the host has no hook.
- **Failing scenario:** the user clicks elsewhere mid-rename. The field editor resigns, the Core session stays in editing state, and no commit or cancel happens. Shift-Tab also falls through to default behaviour.
- **Fix:** add an `ended` closure parameter and implement `controlTextDidEndEditing` in the coordinator. Add `insertBacktab` with a matching Core key. The owner decides whether focus loss commits or cancels, using legacy behaviour as the reference.

**OK2-13. The sidebar row conflicts with `List(selection:)`.** JUDGEMENT
- **Where:** `SidebarRowView.swift:18-30`, against review Fix 25 (`review-01-architecture.md:363-364`) and `01-architecture.md:100,2020`.
- **Failing scenario:** inside the host's `List(selection:)`, the plain `Button` likely takes the click, so List selection does not change [K, Mac]. Arrow keys move a selection that this row does not reflect, and the hand-drawn background doubles or replaces the native highlight. This regresses 00b M-14.
- **Fix:** remove the `Button` and manual background. Render the row content with `.tag(place.id)`, and add `.simultaneousGesture(TapGesture().onEnded { if isSelected { activate(place) } })` for re-click. The host navigates when the selection changes. Keep the context menu. Confirm in the hosted spike.

### Minor

| ID | Where | Failing scenario | Exact fix | Type |
| --- | --- | --- | --- | --- |
| OK2-14 | `SidebarModel.swift:42-55`; `SidebarModelTests.swift:25-37`; `01-architecture.md:100` | Local override removes starred highlight, though the architecture says starred folders are candidates. It also re-implements path matching with string prefixes | **Ruling: architecture and Core win.** Delete the override and update the test | SIMPLE |
| OK2-15 | `PropertiesView.swift:15-18`; `PropertiesViewModel.swift:40-51`; `ByteCountText.swift:8,22` | Properties has no 64 pt icon (F-050) and shows only "N bytes" | Add the icon closure and show `ByteCountText.format` beside `formatExact` | SIMPLE |
| OK2-16 | `ViewOptionsView.swift:18`; `ItemSort.swift:6` | Picker offers `.relevance` for a folder. Every rank is equal, so order falls back to raw path (F-040) | Filter `.relevance` out of the folder picker | SIMPLE |
| OK2-17 | `ColumnBrowserView.swift:28-29,34` | Columns use numeric slot identity and a shared `"preview"` ID, so a sibling folder inherits scroll and view state | Use `BrowserColumn.id` for `ForEach` and `.id`; derive the preview ID from the target | SIMPLE |
| OK2-18 | `ColumnBrowserView.swift:43,57` | `.onMoveCommand` has no `.focusable()`, so arrow keys may never arrive [Mac]. `Button` rows offer no double-click or open route | Add focus handling and an `open` callback; verify hosted | JUDGEMENT |
| OK2-19 | `InlineRenameField.swift:47-53` | Long names can wrap or lose position; pasted newlines are not handled at the field | Set single-line mode, `cell?.isScrollable = true` and `cell?.wraps = false` | SIMPLE |
| OK2-20 | `OperationsPanel.swift:5-11,34` | Finished rows have no dismiss action, though the host must retain them until acknowledged. Reconciliation warnings appear only inside collapsed Details | Add a `dismiss` closure for finished rows; show warnings in the row | SIMPLE |
| OK2-21 | `TagEditorModel.swift:18` | Duplicate check uses the raw value, so the same name with another colour is allowed | Compare the normalized name only | SIMPLE |
| OK2-22 | `SettingsPane.swift:6-7` | Panes differ from F-065's General, Appearance and Behavior plus Advanced windows | Owner rules; then align panes or the row | JUDGEMENT |
| OK2-23 | `SearchBarModel.swift:35`; `01-architecture.md:117` | Search defaults to `.home`, though F-043 says current-folder scope in a directory | Owner rules. Recommended: current folder in a directory, everywhere in Recent | JUDGEMENT |
| OK2-24 | `BatchRenameEvaluation.swift:30-36` | The lock is held during planning, so a main-thread getter can stall for the whole plan on a large selection | Compute outside the lock; lock only for cache read and write, re-checking the revision | SIMPLE |
| OK2-25 | `BatchRenameSheet.swift:28,39,47-49` | Long expressions risk type-checker timeouts [K]; a double click can submit twice | Extract computed properties; guard submit with a submitted flag | SIMPLE |
| OK2-26 | `LaunchRouter.swift:27,64-69` | `usedFrameNames` is private, so a Cmd+N window can reuse a name and `setFrameAutosaveName` can fail [K]. Ordinals never free | Add public `allocateFrameName()` and `releaseFrameName(_:)`; use them for all windows | SIMPLE |
| OK2-27 | `LaunchRouter.swift:41-45`; `LaunchTests.swift:36-44` | A cold open with only invalid URLs produces zero windows, and the user sees only a menu bar (F-001) | Owner rules. Recommended: report the rejection, then apply normal precedence | JUDGEMENT |
| OK2-28 | `SessionRestorePlan.swift:31,45` | A synchronous availability check on a stalled network volume can hang launch | Precompute availability off-main with a timeout; pass the result in | JUDGEMENT |
| OK2-29 | `QuitCoordinator.swift:20-28` | A persistent flush failure (full disk) leaves only retry or cancel, so Force Quit is the only exit. `flushing` cannot be cancelled | Owner rules on a "Quit Anyway" effect that names the unsaved documents | JUDGEMENT |
| OK2-30 | `InlineRenameModel.swift:81,98` (Core) | Escape during a pending rename drops a later collision or error, because `complete` no longer matches | Host reports the outcome through the operations panel; owner confirms | JUDGEMENT |
| OK2-31 | `F4RegressionTests.swift:9-24,37` | The first test is empty on macOS and passes vacuously. The source check uses a relative path, so it fails under `xcodebuild` | Throw `XCTSkip` with a reason on non-Linux; resolve the path from `#filePath` | SIMPLE |
| OK2-32 | `run.py:26,29-32`; `SettingsBindingsTests.swift`; `ContentNativeAdapterTests.swift` | Both native files have never compiled anywhere, and delegate tests use an unattached field. The runner's regex would silently drop other class forms; each of the 13 files has exactly one class today, so nothing is lost yet | Assert discovery on Mac; add hosted tests with a real window; make the runner fail on unmatched classes | JUDGEMENT |
| OK2-33 | `parse_check_ui.sh:16-18` | Exits 0 when zero files were checked | Exit nonzero with `NOT RUN`; update any test that pins the old result | SIMPLE |
| OK2-34 | `run_all.sh:8,39-40` | Uses `HELM_PLAN_DIR` where the prompt uses `PLAN_DIR`, and its default path is absent on a Mac. `test_static_checks.py` never runs | Use `${HELM_PLAN_DIR:-${PLAN_DIR:-...}}`, fail clearly if the directory is missing, and add the test run | SIMPLE |
| OK2-35 | `check_core_type_names.py:81-93`; `run_all.sh:42`; `static_checks.py:87-90` | The guard scans Core only and checks one name in one file, so `DropOperation` in a new SwiftUI file passes. The full gate stays red by design | Scan all six libraries; check retained names in every HelmUI file importing SwiftUI. Rename per Fix 16 once authorized: `FileDropProposal`, `FileDropOperation`, `FileDropSession`, `HelmToolbarItem` | SIMPLE |
| OK2-36 | `check_coverage.py:89-91,106` | Darwin names look like `-[HelmCoreTests.Foo testBar]`. One skip marks the whole module incomplete, and `:106` never matches, so `--generate` records no test evidence | Normalize Darwin names to `Module.Class.method` at `:89`; add a fixture | SIMPLE |
| OK2-37 | `SettingsPane.swift:33-44`; `ViewOptionsView.swift:38-51`; `ColumnBrowserView.swift:58` | Binding closures and `NSApp` access are likely diagnostics under `-strict-concurrency=complete -warnings-as-errors` [K, Mac] | Record the actual output first, then fix or list narrow exceptions | JUDGEMENT |
| OK2-38 | `HelmUI/README.md:30-38`; `HelmApp/README.md:67-75`; `Sheets/README.md:76-82`; `Part3-README.md:49-52` | Four conflicting manifest snippets can mislead the manifest owner | Replace each with a link to the staged patches | SIMPLE |
| OK2-39 | `OperationsPanel.swift:2-3`; `PropertiesView.swift` | Members resolve through leaky imports. This is fine at tools 5.9 but breaks under `MemberImportVisibility` | Add `import HelmOperations` and `import HelmCore` | SIMPLE |

## API and host contract results

Checked by reading against macOS 14 SDK knowledge [K]. No Apple SDK compile backs any row.

### No problem found

| Area | Result |
| --- | --- |
| SwiftUI availability | Two-argument `onChange` (14), `draggable` and `dropDestination` (13), `formStyle(.grouped)` (13), `textSelection` (12), `background(_:in:)` (12), materials (12) all fit macOS 14 |
| AppKit in `InlineRenameField` | `NSViewRepresentable` witnesses, `dismantleNSView`, `cancelOperation`, `insertNewline`, `insertTab`, `currentEditor()`, `hasMarkedText()`, `.roundedBezel` |
| Actor isolation | The `Coordinator` inherits main-actor isolation from AppKit's delegate protocol; `DispatchQueue.main.async` at `InlineRenameField.swift:104` is the special-cased closure; `BatchRenameSheet` worker access fits. All still need the compile |
| Foundation and XCTest | `TimeZone.gmt` (13) and async `fulfillment(of:)` fit |
| Name collisions | A search of all modules found `DropProposal`, `DropOperation`, `DropSession` and `ToolbarItem` as the real module-level collisions. `ToolbarItem` is already qualified in HelmUI. `Command` has no SDK clash |

### HelmUI against exported types

All of these exist with the expected shapes [S]:

- **Settings and view options:** all 23 `SettingKey` cases, `SettingValue`, `SettingsSnapshot` accessors, `ViewMode`, `ItemSort.Field`, `GroupBy`, `ListColumn`, `ViewOptions`.
- **Tags and places:** `FinderTagColor`, `FinderTag.color`, `TagSet.tags`, all eight `Place.PlaceKind` cases.
- **Columns and content:** `ColumnBrowserState`, `BrowserColumn`, `PresentationSnapshot`, `FileEntry`.
- **Rename and overlays:** `InlineRenameModel` and its session, `InlineRenameError.message`, `GridGeometry`, `DropFeedback`, `DropHighlight`, `StatusText.format(_:)`.
- **Sheets and properties:** `Conflict.source` and `.destination`, `ConflictResolution`, `OperationProgress.currentName`, `PropertiesModel.fileCount` and `.directoryCount`, `RenamePreview.source` and `.proposedName`.
- **App and persistence:** `UserDefaultsAdapter`, `LegacyUserDefaultsReader`, `KeyValueStoring`, `LegacyDefaultsReading`, `SessionTab`, `SessionWindow`.

### Host wiring

There is no host, so these contracts have no consumer: `WindowStore`, `DirectoryEffectRunner`, `StoreSelectionBinder`, `DropSession`, `SpringNavigationSession`, `WindowOperationHistory`, `SearchSessionDriver`, `InspectorSessionRegistry`, `ThumbnailCoordinator.shutdown()`. The one contract that visibly mismatches the plan is OK2-8.

## Prior finding dispositions

Only these reports reference in-scope paths: P4, P7, P8, P11, P14, P15, P19, R1 and fixes F1, F3, F4, F5, F8, F12, F15, F16. T1-T4, K13, K15, P10, P17 and P21 have none.

| Finding | Disposition | Evidence |
| --- | --- | --- |
| P1-4 column replies (UI side) | Confirmed-fixed | `ColumnBrowserView.swift:8`; `ColumnBrowserState.swift:62-68` |
| P3 thumbnail host teardown | Not-fixed | `shutdown()` exists; no host calls it (`fixes-F3.md:25`) |
| P4-1 search scope seam | Confirmed-fixed | `SearchBarModel.swift:45` |
| P4-2 bounded rename evaluation | Fixed-with-new-issue | Memoized in `BatchRenameEvaluation.swift`, `BatchRenameViewModel.swift:30-40`; see OK2-24 |
| P4-3 frame identity | Confirmed-fixed | `SessionRestorePlan.swift:32-41`; `FrameIdentityTests.swift` |
| P4-4 lazy operation details | Confirmed-fixed | `OperationRowModel.swift:36-45`; `OperationDetailsView.swift:11-19`; `OperationsPanel.swift:34`. The test is a source check only (`F4RegressionTests.swift:36-40`) |
| P7-1 overlapping sources UI | Confirmed-fixed | `BatchRenameViewModel.swift:70-71`; `fixes-F8.md:11` |
| P7-2 rename cancellation | Confirmed-fixed, hosted check open | `BatchRenameWorker.swift`; `BatchRenameSheet.swift:52-63`; `K34BatchRenameWorkerTests.swift` |
| P8 worker lifecycle residual | Not-fixed (Mac only) | `P8.md:48,71`; no compile yet |
| P11-1 live executor disclosure | Confirmed-fixed | `MAC_HANDOFF.md:125,153` |
| P11-2 effect cancellation guidance | Confirmed-fixed (handoff) | `MAC_HANDOFF.md:312-317` |
| P11-3 inventory reconciliation | Confirmed-fixed | `HelmUI/README.md:10-15`; handoff tables |
| P11-4 runner recipe | Confirmed-fixed | `HelmUI/README.md:145-149` |
| P11 "no likely-to-fail SDK line" | Rejected-finding (superseded) | OK2-3. P11's own listed sites remain low-confidence risks, and `VERIFICATION.md:230` cites stale `Package.swift` lines |
| P14-6 worker test | Confirmed-fixed | `K34BatchRenameWorkerTests.swift:7-55` |
| P14 Mac discovery gate | Not-fixed (Mac only) | No Mac run exists |
| P14 Darwin test names | Not-fixed | `P14.md:247-248`; `check_coverage.py:89-91,106`; OK2-36 |
| P15-2 Properties aggregation | Confirmed-fixed | `PropertiesViewModel.swift:24,27-33,40-51` |
| P19-1 stale handoff entry points | Fixed-with-new-issue | Fixed for its wave; stale again (OK2-5) |
| R1-3 scratch path | Confirmed-fixed | `run.py:5-12`; `F4RegressionTests.swift:10-16` |
| F4 sidebar exclusion note | Rejected-finding | The local override should go (OK2-14) |
| F12 P11-C SDK checklist | Fixed-with-new-issue | `VERIFICATION.md:224-232` exists; its "no new line" claim is superseded |
| F15, F16 UI documentation | Confirmed-fixed | `fixes-F15.md:22`; `fixes-F16.md:32-33` |

## Verdict

**Not ready for Mac acceptance or feature use.** No milestone gate can close, and Helm cannot launch.

**Ready for Mac compile triage** once three things happen:
1. The AK1 overlay fix is committed (OK2-3).
2. Huseyn assigns the manifest and UI/App paths (OK2-2).
3. The prompt corrections are applied (OK2-4, OK2-5).

Decisions Huseyn needs to make, none of which an Astra lane should settle alone:
- **Per-window journal contract** (OK2-6, with O1).
- **External open policy** (OK2-10).
- **Whether a failed store blocks launch** (OK2-9) and **whether quit can discard unsaved documents** (OK2-29).
- **Whether to authorize the Fix 16 rename** (OK2-35).

Until the rename is authorized, `run_all.sh` stays red by design.

### The 5 riskiest places

1. **The absent native host and composition** (`Sources/Helm`, `AppEnvironment.swift`). Most of the product's behaviour lives in code that does not exist yet, and existing contracts have never met a real consumer.
2. **`InlineRenameField.swift`.** It combines popover focus, IME composition, field-editor lifecycle and a missing end-of-editing path. Linux can test none of this.
3. **`SidebarRowView.swift` inside `List(selection:)`.** The row design works against the required selection and keyboard behaviour.
4. **`AppEnvironment.swift` journal and store ownership.** A shared journal, two uncomposed stores and an all-or-nothing `live` affect undo correctness, quit data loss and whether the app starts at all.
5. **`LaunchRouter.swift` open policy and frame-name authority.** It differs from the architecture on the first thing users see from Finder, and tests currently lock in that behaviour.
