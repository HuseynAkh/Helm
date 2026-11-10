DRAFT by Astra, pending Opus review
Status: revised draft by Astra, pending Opus re-review after 10 PM Toronto

# Helm rebuild: target architecture (01-architecture)

Author: Fable 5.1 (architecture lead, Phase 1)
Inputs: `docs/rebuild/00-current-state.md` (Phase 0 audit with Appendix C errata), `docs/rebuild/00b-opus-review.md` (independent checker; wins over 00 where they conflict), `docs/rebuild/00a-astra-first-pass.md`, `/workspace/forge/runs/git-history.txt`, and spot-checks of the current source under `Helm/Helm/`.
Revision basis: full rebuild on a new branch; review-01 fixes take precedence, except source-verified rejections recorded below. Linux Swift 6.0.3 is available through `source /workspace/toolchains/env.sh`, with Swift 5 language mode and tools 5.9. See the current as-built record for module status; this document does not claim their implementation compiled. AppKit and macOS runtime claims remain handoff checks [Mac]. No owner answers or external approvals are inferred.

Conventions used in this document:

- `F-xxx` and `B-xxx` are the Phase 0 feature and bug IDs. B-100 and above come from the Opus review.
- "Must not regress" notes describe observable behaviour the rebuild has to reproduce, including the exact numbers the audit recorded (sizes, timings, limits), unless a row says otherwise.
- Type and protocol signatures are declarations only. No implementations appear in this document.
- "Core" means a Foundation-only SwiftPM module that compiles and tests on Linux. "UI" means a module that imports AppKit or SwiftUI and compiles only on macOS.

---

## 1. Vision and principles

### 1.1 The Helm identity to preserve

Helm is a personal, keyboard-first macOS file manager modelled on GNOME Files (Nautilus), built for one power user, intended to grow into a full Finder replacement. Phase 0 established what that identity concretely is, and the rebuild treats the following as the product contract:

- **A Places sidebar beside one content pane**, sections in the order Recent, Favorites, Bookmarks, Starred, Devices, Trash, with first-class Starred items and folder bookmarks added by drag (F-026 to F-029).
- **Grid and list views only**, with expandable folders in the list (F-035 to F-037). Column and gallery views are not preservation goals; scheduled as parity by the ledger.
- **Tabs with a custom strip** hidden for a single tab, per-tab history with selection snapshots, new tab inherits the location only, closing selects the left neighbour, last tab closes the window (F-009 to F-011).
- **A typed-path address bar** entered by Cmd+L or click: path with trailing slash, caret at end, immediate listing, `..` first outside root, directories before files, Tab accepts or drills, ghost suffix, Right arrow accepts, Esc twice, empty means Home, beep and shake on invalid, outside click cancels, survives toolbar relayout (F-014 to F-024, 00b 5.5 item 1).
- **Explicit Cut, Copy and Paste for files** on Cmd+X, Cmd+C, Cmd+V, where a focused text editor gets text semantics and the file pane gets file semantics (F-051).
- **Recent as a Helm-owned virtual location** that records folders and successful file opens, capped at 300 records (F-030).
- **New File from `~/Templates`** plus "Empty Text File" (F-057).
- **Batch rename** with Add Text, Find & Replace and Template modes using `[Original Name]`, `[Counter]`, `[Date]` tokens and a live preview (F-055).
- **The keyboard map of audit section 2.7**: Return renames, Space previews, Cmd+. toggles hidden files, Cmd+D stars, Cmd+L edits the location, Ctrl+Cmd+S toggles the sidebar, Cmd+1 and Cmd+2 switch views, Cmd+[ and Cmd+] go back and forward, Cmd+Up goes up, Shift+Cmd+H goes Home, Shift+Cmd+N makes a folder, Cmd+Backspace trashes, Cmd+I shows Properties.
- **Spotlight search with a tunable ranking table** (F-044, F-045), with ranked order actually displayed (fixing B-022).
- **A read-only Properties sheet**, an always-present status bar, `name 2` collision naming as the default, and the volume-filtering knowledge in the Devices section (F-031, F-050, F-052, F-064).

### 1.2 Principles for the rebuild

1. **One source of truth per tab.** A single immutable `TabState` value holds location, history, selection, sort, view mode and the presentation snapshot. Views render it; they never own it. This retires the B-009, B-011, B-012, B-019, B-020, B-031, B-033 and B-069 family.
2. **Pure logic in Foundation-only modules.** Everything that can be tested without a Mac lives in a core module: navigation, sorting, diffing, path completion, naming, operation planning, undo journaling, search ranking, settings migration. AppKit and SwiftUI layers are thin adapters.
3. **Compile-safety over cleverness.** Swift 5 language mode, Swift tools 5.9, macOS 14 APIs only, no macros, no third-party packages, no result-builder gymnastics outside small SwiftUI islands, explicit types at every closure and generic boundary, no force unwraps. The code is written blind; the design must make wrong code hard to write.
4. **Every mutation is a planned, journaled command.** Copy, move, trash, rename, create and batch rename go through one planner and one executor, produce per-item outcomes, and register exactly one undoable journal entry. No path is allowed to bypass it (fixes B-036 to B-049, B-041 first).
5. **Identity, not index.** Views resolve items by a stable `ItemID`, never by row or index path into a mutable array. Selection is a set of IDs.
6. **Explicit virtual locations.** Recent and Trash are location kinds with their own data source, sort, operations policy and address-bar behaviour. Search is an overlay held in `TabState.search`, not a `Location` case. No URL-scheme special cases scattered through controllers.
7. **Cancellation follows structure.** Work runs in tasks owned by the object whose lifetime it matches; every awaited result is checked against a generation token before it is applied.

### 1.3 Tie-breaker principles

When two reasonable designs conflict, decide in this order:

1. Does it reproduce a behaviour in the preservation map? Behaviour wins over elegance.
2. Can it be compiled correctly by an author who cannot run the compiler? The more boring API wins.
3. Can the logic be unit-tested on Linux? Push the decision into a core module.
4. Does it keep the main thread free of disk I/O? Anything that touches the filesystem runs off the main actor.
5. Does it remove a class of bugs rather than one bug? Prefer the structural fix.
6. Is it the smallest design that still leaves room for Finder-replacement features (column view, tags, aliases, per-volume Trash, multi-window sync)? Leave the seam, do not build the feature.

---

## 2. Preservation map

### 2.1 Feature map (F-001 to F-072)

The 00 feature rows and Appendix C, as corrected by 00b, are normative for details omitted here; 00 sections 2.7 and 2.8 govern menus, bindings and context menus. Explicit changes here override that baseline. `02-finder-parity.md.partial` is an incomplete catalogue, not owner approval of additional scope.

Dispositions: **Keep** (reproduce as is), **Keep+fix** (reproduce the contract, fix the listed bugs), **Redesign** (same user outcome, different mechanism), **Drop** (not carried, with reason). Module names refer to section 3.

| ID | Feature | Owner module / type | Disposition | Must not regress |
|---|---|---|---|---|
| F-001 | Application lifecycle | `HelmApp/AppDelegate`, `HelmApp/WindowRegistry` | Keep+fix | Launch precedence in 10.3: explicit open request, else saved session if enabled, else one Home window; stays alive after last window closes; Dock reopen creates a window only if none visible. Fix: observer tokens stored and removed (B-063); open requests buffered until launch finishes (B-103); `reply(toOpenOrPrint:)` called (B-114). |
| F-002 | External open requests | `HelmApp/AppDelegate`, `HelmApp/OpenRequestRouter` | Keep+fix | Folders navigate the key window (not the first); files launch via `NSWorkspace`; `public.folder` Alternate viewer registration kept in Info.plist. Initial URL reaches the first tab (B-018). |
| F-003 | Main window and toolbar | `HelmUI/Window/MainWindowController`, `HelmUI/Window/ToolbarFactory` | Keep+fix | 1100×750 initial, 700×450 minimum, unified toolbar, hidden title, autosave `HelmMainWindow`; fixed item order sidebar toggle, back/forward group, path, view-mode segment, search field; path item `.user` priority, width 60 to 1000, height 34; search placeholder "Search files and folders". Fix: `center()` only when no saved frame exists; extra windows cascade (M-03). Toolbar `.iconOnly`, no customization, view-mode/search `.low`, path `.user`; search sendsSearchStringImmediately true, sendsWholeSearchString false. Use `setFrameUsingName` result after autosave-name setup to decide whether to center; test grouped-item validation [Mac]. |
| F-004 | Sidebar split and collapse | `HelmUI/Window/MainSplitViewController` | Keep | `NSSplitViewItem(sidebarWithViewController:)`, sidebar 180 to 320, content minimum 400, thin divider, autosave `HelmMainSplitView`, collapse animates 0.12 s then `adjustSubviews`, Ctrl+Cmd+S and toolbar button. Set `collapseBehavior = .preferResizingSiblingsWithFixedSplitView`. |
| F-005 | Back/Forward history | `HelmCore/Tab/NavigationHistory` inside `TabState` | Keep+fix | Per-tab stacks of location plus selection snapshot; navigate pushes and clears forward; back/forward restore selection and the widgets show it (B-011). Fix: same-location navigation is a no-op (B-019); Back/Forward validated (B-075). |
| F-006 | Up and Home | `HelmCore/Tab/TabReducer` | Keep+fix | Cmd+Up no-op at virtual locations and at `/`; Shift+Cmd+H goes to Home. Fix: Up snapshots selection like any navigation; root detection uses the standardized path, not `deletingLastPathComponent` (00b F-006). |
| F-007 | Opening items | `HelmCore/Tab/OpenPolicy`, `HelmUI/Content/ItemActivation` | Keep+fix | Double-click: non-package directory navigates (now also symlinks to directories, B-071); anything else opens via `NSWorkspace`; successful opens recorded in Recent; failure alert "Unable to Open Item". |
| F-070 | Multi-open semantics | `HelmCore/Tab/OpenPolicy` | Keep | "Open N Items": files and packages launch; folders navigate; several folders: last wins in the current tab (documented, deliberate). |
| F-008 | Refresh | `HelmCore/Tab/TabReducer` (`.refresh`) | Keep+fix | Cmd+R invalidates cache, reloads, keeps selection by ID intersection, applies it to widgets, updates status, restarts the monitor, re-runs an active search; in Recent reloads the recents collection. |
| F-009 | Tab creation | `HelmUI/Tabs/TabContainerController`, `HelmCore/Tab/TabState` | Keep | Cmd+T and "+" open a new tab at the active tab's location only (no selection, history, view mode or search carried over). First tab opens at the requested initial URL or Home. |
| F-010 | Tab bar | `HelmUI/Tabs/TabBarView` | Keep+fix | Custom strip: 30 pt bar, 28 pt tabs, 12 pt titles truncating tail, 16 pt close buttons, 24 pt "+", accent 15 % selected tint radius 6, fill-equally, hidden when one tab. Titles: `Recent`, `/`, else last path component. Fix: whole tab container clickable (M-06); titles diffed instead of full rebuild (B-081); toolbar segment and search field follow the active tab (B-020). Keyboard tab switching and reordering are in scope for drafting per 04 Q3; custom tabs stay. Proposed, owner decision pending; Mac acceptance pending. Overflow remains a parity seam. |
| F-011 | Tab closing | `HelmUI/Tabs/TabContainerController`, `HelmCore/Window/TabListReducer` | Keep | Close button, middle-click, Cmd+W; only when more than one tab; closing active selects left neighbour (second tab when closing the first); Cmd+W with one tab closes the window. |
| F-068 | Window/state restoration | `HelmPersistence/SessionStore` | Redesign | Window frame and split position persist as today. New: tabs and locations persist per window in a versioned JSON session file and are restored on launch (section 10). Settings-window autosave names kept. |
| F-071 | Keyboard focus | `HelmUI/Focus/FocusCoordinator` | Redesign | New explicit focus model: pane receives focus after launch, tab switch, view-mode switch and address-bar exit; `initialFirstResponder` set; key-view loop defined (B-102). All pane commands use `paneCommandsAllowed` (§8.3), including sheet/key-window and sidebar-focus guards. |
| F-072 | Window identity | `HelmUI/Window/MainWindowController` | Keep+fix | Title stays visually hidden but `window.title` and `representedURL` follow the active tab so the Window menu and proxy icon work. Verify proxy-icon interaction with hidden title [Mac]. |
| F-012 | Breadcrumb rendering | `HelmUI/AddressBar/BreadcrumbView` | Keep | Ancestors from `/`; `/` labelled "/", home "Home", others last component; current bold 13 pt label colour; ancestors 13 pt secondary; `›` separators 11 pt tertiary; stack spacing 2, insets 6; 26 pt scroller in 34 pt bar, radius 8, 10 % quaternary background; rightmost end visible after rebuild and resize; Recent shows one semibold "Recent" label; hover highlight 7 % radius 4. Colours re-resolved on appearance change (B-062). Recent label is 14 pt semibold. |
| F-013 | Segment and empty-space clicks | `HelmUI/AddressBar/BreadcrumbView` | Keep | A single click on any segment enters edit mode, preserving the deliberate change in commit `08f0cea`; empty space and Cmd+L edit too. Separator clicks do nothing. Q1 remains open; keep click-to-edit until answered. |
| F-014 | Entering typed-path mode | `HelmUI/AddressBar/AddressEditor` | Keep+fix | Field shows the path with trailing `/`, caret at end (no select-all), listing shown immediately, borderless 13 pt, inset 10. Fix: focus taken synchronously with one deferred retry (B-112); allowed in Recent and Trash, where the field starts with Home (B-054). |
| F-015 | Commit and validation | `HelmCore/AddressBar/PathEntry` (pure), `HelmUI/AddressBar/AddressEditor` | Keep+fix | Trim, expand `~`, standardize, accept existing directories (and symlinks to directories); empty commits Home; invalid: `NSSound.beep()`, 0.4 s shake, red 11 pt "Invalid path or folder not accessible" for 2.5 s. Fix: typed text kept for correction; relative paths resolve against the current directory, not the process cwd. Committing a file path navigates to its parent and selects the file. Intentional change from today’s error (B-054); proposed, owner decision pending (04 Q9). |
| F-016 | Prefix completion | `HelmCore/AddressBar/PathCompletionEngine` (pure), `HelmFileSystem/Providers/CompletionProvider` | Keep+fix | Debounce from `helm.completionDebounceMilliseconds` (default 100, floor 30); anchored case-insensitive match; directories first then `localizedStandardCompare`; cap 50. Fix: hidden-file filter follows the app setting; icons loaded only for visible rows; request generation checked on every edit (B-052). |
| F-017 | Slash-ended browsing | `HelmCore/AddressBar/PathCompletionEngine`, `HelmFileSystem/Providers/CompletionProvider` | Redesign | Same order and cap. Intentional change: hidden files follow the app setting; legacy hard-codes `.skipsHiddenFiles` (`BreadcrumbBar.swift:480`). `..` first (except at `/`), then up to 50 children (51 total outside root; source appends `items.prefix(50)` after the parent row), directories first. Mechanism: the same async, generation-guarded pipeline as F-016 no main-thread I/O (B-050), normalized paths (B-110). Zero debounce; always re-list. Programmatic text changes assign the generation before issuing the request, never afterward. |
| F-018 | Completion popup | `HelmUI/AddressBar/CompletionPanel` | Keep+fix | Borderless non-activating child `NSPanel` at `.popUpMenu`, `.menu` material radius 6, 24 pt rows, no header, single selection, 8 visible rows then scroll, width tracks the bar, repositions on move/resize, first row selected on show. Fix: scroll to the selected row (B-111); clamp to screen (B-062). Keep `hidesOnDeactivate`, `becomesKeyOnlyIfNeeded`, `.utilityWindow`; 16 pt icons, 13 pt names, trailing `/` for directories. |
| F-019 | Mouse acceptance | `HelmUI/AddressBar/CompletionPanel` | Keep+fix | Single click selects (and now refreshes ghost text, B-053); double-click accepts: directories re-list without navigating, files fill the path and hide the popup. |
| F-020 | Tab completion | `HelmCore/AddressBar/PathCompletionEngine` (`tabAction`) | Keep | Tab accepts the ghost suffix, else the selected row (directories drill), else requests completions; Tab and Shift+Tab consumed while editing; `..` as row 0 means an immediate Tab with rows already showing goes up one level. Pending Tab follows §5.7 (one held Tab; second consumed). |
| F-021 | Return | `HelmCore/AddressBar/PathCompletionEngine` (`returnAction`) | Keep+fix | Text without trailing `/` plus visible popup substitutes the selected row then commits; trailing `/` or pending completion commits the literal field text. Fix: a stale popup can never be committed because every edit invalidates the generation (B-052, 00b C-10). |
| F-022 | Escape and arrows | `HelmUI/AddressBar/AddressEditor` | Keep | First Esc hides popup and clears ghost; second exits without navigating; Up/Down clamp; Right accepts ghost only with collapsed caret at end; other arrows fall through. |
| F-023 | Ghost text | `HelmCore/AddressBar/PathCompletionEngine` (`ghostSuffix`), `HelmUI/AddressBar/GhostOverlay` | Keep+fix | Tertiary overlay positioned by measured text width; shown only when the selected row's path starts with the typed text case-insensitively and caret at end. Fix: accepting replaces the typed prefix with canonical casing; `~` and relative input get ghost text because rows are matched against the expanded form (B-053, M-12). Intentional change: preserve a typed `~` prefix on acceptance while canonicalizing the remaining casing; today Tab expands it to absolute. |
| F-024 | Editing and focus survival | `HelmUI/AddressBar/AddressEditor` | Redesign | Same outcomes: outside click cancels; survives toolbar relayout; programmatic edits do not fire change notifications. Mechanism [Mac]: call `shouldChangeText`, replace via `textStorage`, call `didChangeText` within `isApplyingProgrammaticEdit`; reset on the next run-loop as a safety net. Do not use `insertText`. Focus-loss order: if a programmatic edit is in progress, re-establish the field editor and return (`:839-843`); Return commits; intentional FocusCoordinator move ends; outside mouse-down cancels; detached field waits 150 ms to resume or end; another control taking focus ends; otherwise re-acquire. Port from BreadcrumbBar.swift:370–405, 674–685, 815–824 and 826–877, adding B-115 notifications and the B-108 intentional-focus exception. `viewDidMoveToWindow` re-establishes editing (`:674-685`). Native text completion stays disabled (`:815-824`). |
| F-025 | Copy Path | `HelmUI/AddressBar/BreadcrumbView` | Keep | Context menu "Copy Path" for file locations copies the current location's POSIX path as a string. |
| F-026 | Places sections and icons | `HelmUI/Sidebar/SidebarPlacesView`, `HelmCore/Places/PlacesModel` | Keep | Order Recent; Favorites (Home `house`, Desktop `menubar.dock.rectangle`, Documents `doc`, Downloads `arrow.down.circle`, Applications `square.grid.2x2`, blue); Bookmarks `bookmark.fill` orange (hidden when empty); Starred `star.fill` yellow (hidden when empty); Devices `externaldrive`/`internaldrive` gray (hidden when empty); Trash `trash`. `.sidebar` list style, rows padded 2. Recent icon `clock.arrow.circlepath`, Recent and Trash `.secondary` (00/source Place.swift and SidebarPlacesView.swift). |
| F-027 | Selection mapping | `HelmCore/Places/PlacesModel` (`highlightedPlace`, pure) | Keep+fix | Recent maps to Recent; exact match among favorites, bookmarks, devices, trash; else deepest containing place. Fix: starred folders become highlight candidates; a click dispatches navigation and the highlight follows the committed location; re-clicking the highlighted row re-navigates (`List(selection:)` retains highlight and arrow-key navigation; a `simultaneousGesture` handles re-click of the highlighted row, M-14; verify on Mac). |
| F-028 | Bookmarks and sidebar drops | `HelmUI/Sidebar/SidebarPlacesView`, `HelmPersistence/BookmarkStore` | Keep+fix | Drop of directories anywhere on the list shows "Drop Folder to Add Bookmark" caption and adds standardized, deduplicated, name-sorted bookmarks; files ignored; context menu "Remove Bookmark". Fix: one shared store (B-029); unavailable bookmarks kept and dimmed rather than dropped. Dropping files onto a sidebar folder still never moves them. |
| F-029 | Starred | `HelmPersistence/StarStore`, `HelmUI/Sidebar`, `HelmCore/Places/PlacesModel` | Keep+fix | Cmd+D toggles each selected item; context item "Star"/"Remove from Starred"; Starred section in sidebar. Fix: one observable store shared by all windows and tabs (B-027); stable name order (B-113); starred files open instead of failing as folders (B-028). Data migrates from `com.helm.starredFiles` (section 10). |
| F-030 | Recent | `HelmPersistence/RecentStore`, `HelmCore/Identity/Location` (`.recent`), `HelmFileSystem/Virtual/RecentSource` | Keep+fix | Virtual location; records folder navigations and successful default-app opens; dedupe; cap 300; shows up to 180; missing paths pruned only when the containing volume is mounted (B-029). Fix: ordered by last access (B-030); hidden toggle applies; mutations in Recent rejected unless they target a concrete item's parent (B-031); Open With records access. New: "Clear Recent" menu item. |
| F-031 | Devices | `HelmFileSystem/Providers/VolumeReader`, `HelmCore/Places/VolumeFilter` (pure) | Keep+fix | Refresh on `didMount`/`didUnmount`; filter hidden, non-browsable, paths under `/System/Volumes/`, `/private/`, `/dev/`; dedupe by UUID; internal first then name. Fix: name filter restricted to exact case-insensitive `Preboot`, `Recovery`, `VM`, `Update`, `Hardware`, `xarts` and the ` - Data` suffix (B-080); resource reads done once outside the comparator (B-058); no refresh on unrelated defaults writes. "Show all mounted volumes" removes every filter except UUID dedupe (00b C-13). `VM Images` remains visible. Internal-name dedupe by lowercase name stays when show-all is off; UUID dedupe falls back to mount path (VolumeService.swift:89–100). The startup volume at `/` is exempt from the hidden and non-browsable filters (`VolumeService.swift:124`). |
| F-032 | Trash | `HelmCore/Identity/Location` (`.trash`), `HelmFileSystem/Virtual/TrashSource` | Redesign | Trash becomes a virtual location aggregating `~/.Trash` and `/Volumes/*/.Trashes/<uid>` (B-087), with Empty Trash and Put Back commands (section 7.8) and a permission-denied state when Full Disk Access is missing (B-109). |
| F-033 | Folder Tree sidebar | none | Drop | README-only promise; no code exists. Open product question (section 14). The sidebar keeps a `SidebarMode` seam so a tree can be added later. |
| F-034 | Translucent sidebar | `HelmUI/Sidebar/SidebarContainerController` | Keep | `helm.sidebarLiquidGlass` toggles an `NSVisualEffectView` (`.sidebar`, within-window) behind the hosting view and clear SwiftUI backgrounds; observed through the settings model, not every defaults write. |
| F-035 | Grid view | `HelmUI/Content/GridView` (NSCollectionView) | Keep+fix | Flow layout 140×140 items, inter-item 10, line 14, insets 12/16/12/16; clear background; multiple selection; icon 96×96 proportional; name 11 pt centred, two lines with middle truncation (verify rendering at handoff, M-19); selection accent 20 % radius 8; `.fileURL` drags. Fix: icon size follows `helm.gridIconSize` (B-059); every datasource access is by ID against the snapshot (B-009, B-101). Default icon size 96 pt; item dimensions are icon size + 44 (140×140 at default). Explicitly stored sizes are honoured. Show starred badge and hidden-file dimming, with cut opacity composed consistently. |
| F-036 | List view | `HelmUI/Content/ListView` (NSOutlineView) | Keep+fix | `.fullWidth`, 24 pt rows, alternating backgrounds, multiple selection; columns Name (min 200, 13 pt, 18 pt icon), Size (80/60, `--` for directories, `ByteCountFormatter .file`), Date Modified (160/100, medium date short time), Kind (120/80, `UTType.localizedDescription`); secondary 12 pt text. Fix: header clicks sort (B-034); Kind sortable; column autosave (B-078). Show starred badge and hidden-file dimming consistently with grid. |
| F-037 | Expandable folders | `HelmUI/Content/ListView`, `HelmCore/Snapshot/PresentationSnapshot` | Keep+fix | Non-package directories expand; children load asynchronously with a placeholder. Fix: children use the tab's sort, hidden-file setting and stars (B-032); nodes are class instances keyed by ID so `reloadItem` identity works (M-21); loads are generation-guarded. |
| F-038 | Selection | `HelmCore/Tab/TabState` (`selection: Set<ItemID>`) | Redesign | Model selection is the source of truth; widgets apply it after every snapshot change and report user changes back; right-click on unselected replaces, on selected keeps, on background clears; status bar follows. Expanded children are first-class selectable items for every command (B-033). |
| F-039 | View-mode switching | `HelmCore/Tab/TabState` (`viewMode`), `HelmUI/Content/ContentHostController` | Keep+fix | Cmd+1/Cmd+2 and segment; one widget visible at a time. Fix: selection and scroll anchor (first visible ID) survive the switch; segment synchronised per tab (B-020); default from `helm.defaultViewMode` (B-059). |
| F-040 | Sorting | `HelmCore/Model/ItemSort`, `HelmCore/Snapshot/PresentationSnapshot` | Keep+fix | Fields name, size, dateModified, kind; direction; directories-first applied before the field regardless of direction; default name ascending with `localizedStandardCompare`. Fix: sorted once per snapshot, never on access (B-010); three-way comparator with ID tie-break (B-035); column clicks, menu and settings all write the same descriptor (B-034). |
| F-041 | Type-select and keyboard open | `HelmUI/Content/ListView`, `HelmUI/Content/GridView`, `HelmCore/Text/TypeSelect` (pure) | Keep+fix | List keeps native type-select; grid gains type-select through the same pure matcher; Cmd+O and Cmd+Down open the selection (new bindings, section 8.5). |
| F-042 | Hidden files | `HelmCore/Tab/TabState` (`showHidden`), settings model | Keep+fix | Cmd+. toggles per tab and writes `helm.showHiddenFiles`; menu item shows a check mark (B-075); applies to expanded children, completions and Recent. |
| F-069 | Symlinks and aliases | `HelmCore/Model/FileEntryKind`, `HelmFileSystem/Live/MetadataReader` | Redesign | Directory-ness resolved through the link target for navigation; dangling links badged; Finder aliases resolved via `URL(resolvingAliasFileAt:options:)` on open (B-071). |
| F-043 | Search entry and scope | `HelmUI/Window/ToolbarFactory` (search field), `HelmCore/Tab/SearchState` | Keep+fix | Field sends on every change; Cmd+F focuses and selects; trimmed; empty exits search; current-folder scope in a directory, everywhere scope boosted toward the last directory in Recent; debounce `helm.searchDebounceMilliseconds` (default 180, floor 40); navigation exits search. Fix: per-tab query (B-020); results tagged with query generation (B-023); loading indicator and "not indexed" state (B-099); results show a Location column (M-24). In Trash, search uses the concrete aggregated trash roots; Recent remains everywhere scope, using `lastDirectory` or Home only for ranking boost. Search remains an overlay. |
| F-044 | Spotlight predicate and scopes | `HelmSearch/Spotlight/SpotlightQueryBuilder` (pure), `HelmSearch/Spotlight/SpotlightSearchService` | Keep+fix | `kMDItemFSName CONTAINS[cd]`; everywhere scope is Home, standard folders that exist, bookmarks, removable browsable volumes, optionally local computer. Fix: `NSMetadataQueryLocalComputerScope` passed as the symbolic constant (B-024); path exclusions applied in ranking, not the predicate (00b C-20); scope, hidden policy and system filter are separate settings (B-025). |
| F-045 | Ranking | `HelmSearch/Rank/SearchRanker` (pure) | Keep | Full score table: exact +1200, prefix +800, contains +500, +100 per token, preferred root +380 plus depth bonus max(0, 150−30·depth), other Home +220, bookmark +300, under active directory +200, directory +80, document-like +140, hidden −280, system-like −650 when excluded, modified <1 d +90, <7 d +55, <30 d +25, current-folder +40; ties by newer modification then natural name; preferred roots list plus visible top-level Home folders except Library. Home enumerated once per search, casing preserved (B-026). |
| F-046 | Result delivery | `HelmSearch/Spotlight/SpotlightSearchService` | Keep+fix | `DidFinishGathering` and `DidUpdate` observed; updates disabled while reading; candidate cap `max(limit×3, 450)`; dedupe; rank; return `limit` (default 300). Fix: bounded metadata materialisation on main; ranking off the main actor; ranked order preserved in a `.searchResults` snapshot (B-022); termination scoped to query identity (B-021). |
| F-047 | File icons | `HelmUI/Imaging/IconCache` | Keep+fix | `NSCache` keyed by path plus size, limit from `helm.maxCachedIcons` (default 800, floor 100). Fix: keys include content type and change token; invalidated on monitor events (B-056); NSWorkspace icon work stays within the HelmUI platform adapter and is cached/throttled. Its SDK isolation and queue-safe transfer must be verified on Mac; do not invent NSImage Sendable conformance. |
| F-048 | Thumbnails | `HelmUI/Imaging/ThumbnailPipeline` | Keep+fix | Eligible UTTypes image, movie, video, pdf, presentation, spreadsheet, html, svg; never directories; generic icon first, cached result if present, async `QLThumbnailGenerator` otherwise; cells cancel on reuse and verify the ID before assigning; grid 96 pt, list 18 pt. Fix: request size in points with the view's backing scale (B-056); per-key subscriber sets (B-055); cost-based limit from `helm.maxCachedThumbnails` read live. |
| F-049 | Quick Look | `HelmUI/Content/QuickLookCoordinator` | Keep+fix | Space toggles `QLPreviewPanel.shared()` when the selection is non-empty; selected items in display order. Fix: Space handled only when the pane is first responder and no modifiers (B-060); panel reloads on selection change; `previewPanel(_:handle:)` forwards arrows; source frame supplied; expanded children included; a "Quick Look" menu item validates and carries no key equivalent. |
| F-050 | Properties | `HelmUI/Sheets/PropertiesView`, `HelmFileSystem/Providers/PropertiesLoader` | Keep+fix | Cmd+I (selection else current directory) or context menu; 360×480 sheet; 64 pt icon, name, kind, Size, Location, Created, Modified, Type, Image dimensions, Open With, Permissions words plus octal, "Show in Enclosing Folder", Done is Escape. Fix: filesystem attributes loaded off main (B-058); image dimensions/default app enriched by HelmUI/Providers/PropertiesEnricher; folder size computed lazily with cancellation; dismissed via `dismiss(hostingController)` (B-117); exact byte count shown beside the formatted size (B-066). |
| F-051 | Cut/Copy/Paste | `HelmUI/Commands/ClipboardCommands`, `HelmOperations/Clipboard/ClipboardState` (pure) | Keep+fix | Edit menu uses `NSText` selectors so text fields win; the window controller performs file semantics otherwise; Cut marks a move. Fix: `changeCount` tracked so an external copy invalidates internal state (B-036); cut state cleared only after the move succeeds (B-037); reads use `.urlReadingFileURLsOnly` (B-106); Paste validated through `validateMenuItem` (00b C-23); cut items drawn dimmed. |
| F-052 | Copy/move semantics | `HelmOperations/Plan/OperationPlanner` (pure), `HelmOperations/Execute/OperationExecutor` | Redesign | Default collision policy stays "keep both" with `name 2.ext` naming; the planner also supports Replace, Skip and Stop with apply-to-all (section 7.3); multi-part extensions preserved (`a.tar.gz` becomes `a 2.tar.gz`, B-116); same-parent moves are no-ops (B-040); per-item outcomes (B-038); progress and cancellation (B-049). |
| F-053 | Move to Trash | `HelmOperations` command `.trash` | Keep+fix | Cmd+Backspace or context menu; `FileManager.trashItem` per item recording the resulting URL. Fix: honours explicitly stored helm.confirmBeforeTrash; absent value registers false pending Q10 (B-048); partial failures reported; undo restores exact names (B-042). |
| F-054 | Rename | `HelmUI/Content` inline editing, `HelmCore/Naming/FileNameValidator` (pure) | Redesign | Return with one selected item renames. Mechanism: inline cell editing in grid and list (basename preselected with a UTF-16 range, B-066) replaces the modal `NSAlert`; the validator rejects separators, `..`, empty and reserved names (B-046). Context "Rename" kept. |
| F-055 | Batch rename | `HelmCore/Naming/BatchRenamePlanner` (pure), `HelmUI/Sheets/BatchRenameView` | Keep+fix | Multiple selection plus Return or "Rename N Items…": 500×450 sheet; modes Add Text (Prepend/Append), Find & Replace, Template default `[Original Name]-[Counter]`, counter start, `[Date]` = `yyyy-MM-dd`; basename only, extension preserved; monospaced preview of first 20 ("… and N more"); Rename disabled when nothing changes; Return/Escape. Fix: full plan validated for duplicates, existing targets and swaps using temporary names (B-047); one journal entry per batch; preview keyed by ID. |
| F-056 | New Folder | `HelmOperations` command `.createFolder` | Keep+fix | Shift+Cmd+N or background menu creates "New Folder" with collision suffix immediately, then starts inline rename of the new folder (section 14 Q2; immediate creation preserved, rename additive). Target is the displayed directory; refused in Recent (B-031). |
| F-057 | New File and templates | `HelmOperations` command `.createFile`, `HelmFileSystem/Providers/TemplateProvider` | Keep+fix | Background menu "New File" submenu lists visible children of `~/Templates` (files and directories; directory templates copy recursively as today; sort with localizedStandardCompare as an intentional improvement), separator, "Empty Text File" (`Untitled.txt`); template copies keep the template name with collision suffix. Fix: enumeration cached off the main thread (B-058). New: File menu "New File ▸" mirrors it. |
| F-058 | New File sheet | none | Drop | Dead code with no caller; the template submenu covers the use. |
| F-059 | Undo | `HelmOperations/Journal/OperationJournal`, `HelmUI/Window/MainSplitViewController` | Redesign | Cmd+Z and Shift+Cmd+Z undo and redo whole operations with action names Copy, Move, Move to Trash, Rename, New Folder, New File, Duplicate; one window-scoped journal owns file undo/redo stacks independently of text UndoManager (B-100); undo of copy/create always trashes, warning if its token changed (B-041); errors surface; affected tabs refresh (B-043); drags are undoable (B-044). |
| F-060 | Permanent delete | `HelmOperations` command `.deletePermanently` | Redesign | Becomes a real user command (Option+Cmd+Backspace, confirmation required, not undoable, labelled as such). |
| F-061 | Operation progress and cancellation | `HelmOperations/Execute/OperationProgress`, `HelmUI/Operations/OperationsPanelView` | Redesign | Progress published per operation with bytes, items, ETA and a cancel button in a window-bottom panel; operations are owned by the app and survive tab closing. |
| F-062 | Open With | `HelmUI/Menus/ContextMenuBuilder`, `HelmUI/Providers/ApplicationProvider` | Keep+fix | Single-item submenu, first ten `urlsForApplications(toOpen:)` with 16 pt icons, disabled "No Applications" when empty; launch via `NSWorkspace.open(_:withApplicationAt:configuration:completionHandler:)`. Fix: failure alert hops to the main actor (B-070); access recorded in Recent; application queries stay inside the UI adapter under the actual NSWorkspace SDK isolation; cache them and verify main-thread cost at handoff; still offered for folders (M-32). New: "Other…" opens an `NSOpenPanel` restricted to applications. |
| F-063 | Share | `HelmUI/Menus/ContextMenuBuilder` | Keep+fix | Share uses `NSSharingServicePicker.standardShareMenuItem` to preserve its submenu position (B-083); picker presentation is fallback, verified on Mac. |
| F-064 | Status bar | `HelmUI/Content/StatusBarView`, `HelmCore/Text/StatusText` (pure) | Keep+fix | 24 pt bar, top separator, 11 pt secondary label: "N items"/"1 item", optional "N selected", optional "X free", joined by "  •  ". Fix: free space read asynchronously and cached per volume (B-058); optional selected-bytes total; loading and error states shown here (B-017). |
| F-065 | Settings and Advanced Options | `HelmUI/Settings/*`, `HelmCore/Settings` | Keep+fix | Two windows: "Helm Settings" 450×300 tabs General/Appearance/Behavior; "Advanced Options" 500×440 form; autosave names `HelmPreferences`, `HelmAdvancedOptions`. Fix: every control wired through one settings model (B-059); unimplemented controls removed (single-click stays only if section 14 Q4 is answered yes). |
| F-066 | Standard menus | `HelmUI/Menus/MainMenuBuilder` | Keep | About, Settings… (Cmd+,), Advanced Options…, Services, Hide/Hide Others/Show All, Quit; Window menu Minimize, Zoom, Bring All to Front; Help menu present. Built in code, no nib. |
| F-067 | Drag and drop (grid/list) | `HelmUI/Content/DragDropCoordinator`, `HelmOperations/Plan/DropPlanner` (pure) | Keep+fix | Source writes `NSURL` per item; local mask copy+move, external copy; drop on a non-package directory targets it, otherwise the displayed directory; Option forces copy. Fix: default is move within a volume and copy across volumes (section 14 Q5), Cmd forces move; modifiers read from the drag info (B-045); no insertion gap drawn (B-074); drops inside an expanded subfolder target that row's parent (B-079); result journaled (B-044); source and destination tabs refresh via the monitor. |

Coverage: the audit (00 plus 00b additions) defines F-001 to F-072 with no gaps, 72 feature IDs. All 72 are mapped above. Dispositions: Keep 13, Keep+fix 45, Redesign 12, Drop 2 (F-033, F-058).

### 2.2 Critical and High bug map

Severities are the audit's after the Opus re-ratings (00b 3.3). Each row names the design element that removes the bug class, not a patch.

| Bug | Severity | Eliminated by |
|---|---|---|
| B-009 stale items, wrong target, index crash | Critical | `PresentationSnapshot` is immutable and published atomically; widgets hold the snapshot they were last given and resolve every datasource call by `ItemID`; monitor events produce a new snapshot through the same reducer as navigation (sections 4.2, 5.4). |
| B-041 undo of copy/create deletes permanently | Critical | `OperationJournal` undo of create or copy compares the destination's change token and child count; undo always trashes, never removes, warning if changed; file-operation journal stacks are separate from text-field undo (section 7.6). |
| B-001 stale pbxproj | High | Generated project removed from the repo; `project.yml` is the only description; CI regenerates (section 3.5). |
| B-002 `SWIFT_VERSION 5.9` | High | `SWIFT_VERSION: "5"` in `project.yml`, `swiftLanguageVersions: [.v5]` in `Package.swift` (section 3.4). |
| B-003, B-076 test module named `Testing` | High | XCTest only; support module named `HelmTestKit` (section 11). |
| B-010 sort on every read | High | Sorted once per snapshot; `indexByID` stored with the snapshot (section 4.2). |
| B-011 invisible selection acted on | High | Selection lives in `TabState`; `ContentHostController.apply(_:)` pushes it into the visible widget after every change; commands read `TabState.selection` (section 4.3). |
| B-012 side effects after await | High | Every async result is applied through `TabStore.commit(_:for:)` which drops stale generations (section 4.5). |
| B-017 errors indistinguishable from empty | High | `SnapshotPhase` is `.loading`, `.ready` or `.failed(LoadError, attempted: Location)`; status bar and content pane render it; failed loads do not enter history or Recent (section 4.2). |
| B-022 ranked order lost | High | `.searchResults` snapshots carry `sortedEntries` in rank order with `sort == .relevance` (section 5.6). |
| B-027 independent star services | High | One `StarStore` built by the composition root and injected everywhere, observable through Foundation `Broadcast`, bridged to Combine only in HelmUI (section 10.2). |
| B-031 wrong-target mutations in Recent | High | `Location.mutationTarget` is `nil` for virtual locations; the planner rejects commands without a concrete target (section 7.2). |
| B-033 commands ignore expanded children | High | `PresentationSnapshot` includes children as items with IDs; selection is `Set<ItemID>`; commands resolve through the snapshot (section 4.2). |
| B-036 stale internal clipboard | High | `ClipboardState` stores the pasteboard `changeCount` and compares before honouring internal URLs (section 7.7). |
| B-037 cut consumed early | High | Paste builds a `ClipboardTransaction`; sources are acknowledged per item after success (section 7.7). |
| B-038 partial failure returns nothing | High | `OperationResult` carries `[ItemOutcome]`; the executor never throws past the first item (section 7.4). |
| B-040 same-folder move renames | High | `OperationPlanner.preflight` detects same-parent, self and descendant relationships before any I/O (section 7.3). |
| B-042 undo keeps destination names | High | Journal entries store exact source and destination URLs per item (section 7.6). |
| B-043 fire-and-forget undo | High | Undo runs as a tracked operation with progress and error surfacing; redo registered (section 7.6). |
| B-046 rename accepts path components | High | `FileNameValidator` is the only constructor of `ValidFileName`; the operations module accepts nothing else (section 7.5). |
| B-050 main-thread completion I/O | High | `CompletionProvider` is an actor whose I/O runs on the I/O executor; the UI receives value rows only (section 5.7). |
| B-067 test gap | High | Section 11 defines the test matrix; the pure modules make the dangerous boundaries testable on Linux. |
| B-100 undo target freed with tab | High | The journal is window-scoped, owned by `MainWindowController`, and owns its stacks independently of tab lifetime (section 7.6). |
| B-101 O(n² log n) selection sync | High | Selection translated through the snapshot's `indexByID`; cost O(k) (section 4.2). |
| B-102 pane never focused | High | `FocusCoordinator` with defined transitions (section 8.5). |
| B-117 undismissable sheets (unverified) | High if confirmed | Sheets presented and dismissed through one `SheetPresenter` that keeps the hosting controller reference (section 8.6). |

Medium and Low bugs are addressed by the same mechanisms; the feature map lists them row by row. Remaining explicit dispositions:

| Bug | Disposition |
|---|---|
| B-004 | Retired: remove nonisolated(unsafe) while porting; tools 5.9 baseline (11.3) |
| B-005 | Retired: pure ranker has no DEBUG-only test API (5.9) |
| B-006 | Retired: custom runner replaced by XCTest (11.1) |
| B-007 | Documented: swift run is development-only; bundle is product (9) |
| B-008 | Handoff asset task: app icon artwork; do not claim complete (3.5, 14.3) |
| B-014 | Retired by generation-scoped monitor teardown (4.5, 6) |
| B-064 | Sendable/isolation rules and real core compile (4.5, 11) |
| B-065 | Hardened runtime/non-sandboxed design, owner signing choice (9, ADR-006) |

---

## 3. Module boundaries

### 3.1 Module list

Nine SwiftPM targets in one package plus one Xcode app target that consumes the package as a local dependency.

| Module | Kind | Imports allowed | Linux-testable | Responsibility |
|---|---|---|---|---|
| `HelmCore` | library | Foundation | Yes | Value types and pure logic: `Location`, `ItemID`, `FileEntry`, `PresentationSnapshot`, `ItemSort`, `NavigationHistory`, `TabState`, reducers, `PathEntry`, `PathCompletionEngine`, `FileNameValidator`, `BatchRenamePlanner`, `VolumeFilter`, `PlacesModel`, `StatusText`, `TypeSelect`, settings schema, snapshot diffing. |
| `HelmFileSystem` | library | Foundation, HelmCore, Dispatch; Darwin/Glibc platform guards; CoreServices and UniformTypeIdentifiers only under `#if os(macOS)` | Yes (with the in-memory fake) | `FileSystem` protocol, `LiveFileSystem`, `InMemoryFileSystem`, `DirectoryEnumerator`, `MetadataReader`, `DirectoryMonitor` protocol with FSEvents, dispatch-source and polling implementations, `CompletionProvider`, `VolumeReader`, `TemplateProvider`, `RecentSource`, `TrashSource`, `ListingCache`, I/O executor. |
| `HelmOperations` | library | Foundation, HelmCore, HelmFileSystem | Yes | `OperationPlanner`, `OperationExecutor`, `OperationJournal`, `OperationProgress`, `DropPlanner`, conflict policy, Trash and Put Back, clipboard transaction logic. |
| `HelmSearch` | library | Foundation, HelmCore, HelmFileSystem | Partially (ranker and query builder yes; query builder returns format and arguments; NSMetadataQuery and predicate construction exist only under `#if os(macOS)`) | `SearchRanker`, `SpotlightQueryBuilder`, `SpotlightSearchService`, `EnumerationSearchService` fallback. |
| `HelmPersistence` | library | Foundation, HelmCore | Yes | `SettingsStore`, `StarStore`, `BookmarkStore`, `RecentStore`, `SessionStore`, versioned JSON codecs, `UserDefaults` migration. |
| `HelmTestKit` | library | Foundation, XCTest, HelmCore, HelmFileSystem | Yes | Fixtures: in-memory trees, fake clock, fake monitor, snapshot builders, temp-dir helpers, assertion helpers. Test-only dependency. |
| `HelmUI` | library | AppKit, SwiftUI, Combine, QuickLookUI, QuickLookThumbnailing, UniformTypeIdentifiers, all core modules | No (macOS only) | Windows, toolbar, tabs, address bar, sidebar, grid, list, status bar, menus, sheets, settings windows, imaging caches, focus, drag and drop, Quick Look, journal routing, operations panel. |
| `HelmApp` | library | AppKit, HelmUI and all core modules | No | `AppDelegate`, `WindowRegistry`, `OpenRequestRouter`, `LaunchSequence`, the composition root `AppEnvironment` that builds every store and service once and injects them. |
| `HelmDev` (SwiftPM executable) | executable | HelmApp | No | `main.swift` only: `NSApplication` bootstrap for `swift run` during development. |
| `Helm.app` (Xcode target from `App/project.yml`) | application | HelmApp | No | Signed bundle with Info.plist, entitlements, asset catalog. Its only source file is `App/main.swift`, checked against the optional development entry. |

Test targets: `HelmCoreTests`, `HelmFileSystemTests`, `HelmOperationsTests`, `HelmSearchTests`, `HelmPersistenceTests` (all Linux-capable), `HelmUITests` (macOS, XCTest unit tests for view adapters), `HelmAppTests` (macOS, application composition tests), and `HelmUIAutomationTests` (XCUITest, Xcode target only).

### 3.2 Dependency graph

```text
Imports (each arrow means “depends on”; no implicit edges):
HelmCore -> Foundation
HelmFileSystem -> HelmCore
HelmPersistence -> HelmCore
HelmOperations -> HelmCore, HelmFileSystem
HelmSearch -> HelmCore, HelmFileSystem
HelmTestKit -> HelmCore, HelmFileSystem, XCTest
HelmUI -> HelmCore, HelmFileSystem, HelmOperations, HelmSearch, HelmPersistence
HelmApp -> HelmUI, HelmCore, HelmFileSystem, HelmOperations, HelmSearch, HelmPersistence
HelmDev executable / Helm.app -> HelmApp
```

Rules that keep the graph acyclic and compiler-enforced:

- `HelmCore` imports nothing but Foundation. The `FileSystem` protocol lives in `HelmFileSystem`; `HelmCore` types never reference it. Every non-SDK type named in a public HelmCore signature is declared in HelmCore (section 4.6). Contracts injected by AppEnvironment remove persistence back-edges.
- `HelmFileSystem` and `HelmPersistence` depend only on `HelmCore` and do not know about each other.
- `HelmOperations` and `HelmSearch` depend on `HelmCore` and `HelmFileSystem`, never on each other or on persistence.
- Only `HelmUI` and `HelmApp` may contain `import AppKit`, `import SwiftUI`, `import Cocoa`, `import QuickLookUI`, `import QuickLookThumbnailing`. A CI grep over the other targets enforces this (section 11.6).
- `UniformTypeIdentifiers` is not imported in `HelmCore`; `FileEntry.contentTypeIdentifier` is a `String?` and the UI accessor lives in HelmUI; MetadataReader may use UniformTypeIdentifiers behind `#if os(macOS)` to produce strings and booleans.
- `CoreServices` (FSEvents) is imported only in `HelmFileSystem` behind `#if os(macOS)`; the polling monitor is the Linux and last-resort implementation.

### 3.3 Directory layout

```
repository/                             planned repository root (legacy Helm/ retained until Mac compile)
├── Package.swift                       package root manifest (section 3.4)
├── README.md
├── docs/rebuild/
├── Sources/
│   ├── HelmCore/
│   │   ├── Identity/        ItemID.swift, Location.swift, LocationKind.swift, OperationID.swift, StepID.swift, TabID.swift
│   │   ├── Model/           FileEntry.swift, FileEntryKind.swift, ItemSort.swift, ViewMode.swift, ChangeToken.swift
│   │   ├── Snapshot/        PresentationSnapshot.swift, SnapshotDiff.swift, SnapshotBuilder.swift, SnapshotPhase.swift
│   │   ├── Tab/             TabState.swift, TabAction.swift, TabReducer.swift, TabEffect.swift, PendingNavigation.swift, LoadOptions.swift, ReducerContext.swift, NavigationHistory.swift, SearchState.swift, OpenPolicy.swift
│   │   ├── Window/          WindowState.swift, TabListReducer.swift
│   │   ├── Contracts/       MonitorEvent.swift, MonitorFailure.swift, OperationSummary.swift, RecentRecordsProviding.swift, TrashOriginRecording.swift, RecentRecord.swift, TrashedItem.swift
│   │   ├── Search/          SearchQuery.swift, SearchScope.swift, SearchResult.swift, SearchEvent.swift, SearchService.swift
│   │   ├── AddressBar/      PathEntry.swift, PathCompletionEngine.swift, CompletionRow.swift, AddressBarState.swift, AddressBarAction.swift, CompletionRequest.swift
│   │   ├── Naming/          FileNameValidator.swift, ValidFileName.swift, UniqueNamer.swift, BatchRenamePlanner.swift, RenameToken.swift, RenamePair.swift, FileNameError.swift
│   │   ├── Places/          Place.swift, PlacesModel.swift, VolumeFilter.swift, VolumeInfo.swift
│   │   ├── Settings/        SettingsSchema.swift, SettingKey.swift, SettingsSnapshot.swift
│   │   ├── Text/            StatusText.swift, TypeSelect.swift, ByteCountText.swift
│   │   └── Support/         CommandID.swift, KeyBinding.swift, Generation.swift, HelmClock.swift, Debouncer.swift, Broadcast.swift, AutoreleaseScope.swift, Limits.swift
│   ├── HelmFileSystem/
│   │   ├── Protocol/        FileSystem.swift, DirectoryMonitor.swift, FileSystemError.swift, EnumerationOptions.swift
│   │   ├── Live/            LiveFileSystem.swift, DirectoryEnumerator.swift, MetadataReader.swift, IOExecutor.swift
│   │   ├── Monitor/         FSEventsMonitor.swift, DispatchSourceMonitor.swift, PollingMonitor.swift, EventCoalescer.swift, MonitorRegistry.swift
│   │   ├── Fake/            InMemoryFileSystem.swift, InMemoryMonitor.swift
│   │   ├── Providers/       CompletionProvider.swift, VolumeReader.swift, TemplateProvider.swift, PropertiesLoader.swift
│   │   └── Virtual/         LocationSource.swift, DirectoryLoader.swift, RecentSource.swift, TrashSource.swift, ListingCache.swift
│   ├── HelmOperations/
│   │   ├── Plan/            Command.swift, OperationPlan.swift, OperationPlanner.swift, ConflictPolicy.swift, DropPlanner.swift, PlanningContext.swift
│   │   ├── Execute/         OperationExecutor.swift, OperationProgress.swift, ItemOutcome.swift, OperationResult.swift, ProgressEstimator.swift
│   │   ├── Journal/         OperationJournal.swift, JournalEntry.swift, UndoPlanner.swift
│   │   ├── Trash/           TrashCoordinator.swift, PutBackResolver.swift
│   │   └── Clipboard/       ClipboardState.swift, ClipboardTransaction.swift
│   ├── HelmSearch/
│   │   ├── SearchConfiguration.swift    injected ranker/scope inputs; shared query/service types live in Core
│   │   ├── Rank/            SearchRanker.swift, RankingWeights.swift, PreferredRoots.swift
│   │   ├── Spotlight/       SpotlightQueryBuilder.swift, SpotlightSearchService.swift
│   │   └── Fallback/        EnumerationSearchService.swift
│   ├── HelmPersistence/
│   │   ├── SettingsStore.swift, StarStore.swift, BookmarkStore.swift, RecentStore.swift, SessionStore.swift, TrashOriginStore.swift, StoreLocation.swift
│   │   ├── Codec/           VersionedDocument.swift, JSONFileStore.swift
│   │   └── Migration/       LegacyDefaultsMigrator.swift, MigrationStep.swift
│   ├── HelmTestKit/
│   │   ├── Fixtures/        TreeFixture.swift, FakeClock.swift, SnapshotFixtures.swift, TempDirectory.swift
│   │   └── Assertions/      SnapshotAssertions.swift, OutcomeAssertions.swift
│   ├── HelmUI/
│   │   ├── Window/          MainWindowController.swift, WindowDependencies.swift, MainSplitViewController.swift, ToolbarFactory.swift, WindowStateBinder.swift
│   │   ├── State/           TabStore.swift, WindowStore.swift, SettingsModel.swift, StarsModel.swift, BookmarksModel.swift, RecentsModel.swift
│   │   ├── Providers/       VolumeEventSource.swift, ApplicationProvider.swift, PropertiesEnricher.swift
│   │   ├── Tabs/            TabContainerController.swift, TabBarView.swift, TabButton.swift
│   │   ├── AddressBar/      AddressBarView.swift, BreadcrumbView.swift, AddressEditor.swift, CompletionPanel.swift, GhostOverlay.swift, AddressBarController.swift
│   │   ├── Sidebar/         SidebarContainerController.swift, SidebarPlacesView.swift, SidebarViewModel.swift
│   │   ├── Content/         ContentHostController.swift, GridView.swift, GridItemCell.swift, ListView.swift, ListNode.swift, StatusBarView.swift, DragDropCoordinator.swift, QuickLookCoordinator.swift, SelectionBinder.swift, ItemActivation.swift
│   │   ├── Commands/        CommandDispatcher.swift, ClipboardCommands.swift, JournalRouting.swift, MenuValidation.swift
│   │   ├── Menus/           MainMenuBuilder.swift, AppLevelActions.swift, ContextMenuBuilder.swift
│   │   ├── Sheets/          SheetPresenter.swift, PropertiesView.swift, BatchRenameView.swift, ConflictView.swift
│   │   ├── Operations/      OperationsPanelView.swift, OperationsPanelController.swift
│   │   ├── Settings/        SettingsWindowController.swift, GeneralSettingsView.swift, AppearanceSettingsView.swift, BehaviorSettingsView.swift, AdvancedOptionsView.swift
│   │   ├── Imaging/         IconCache.swift, ThumbnailPipeline.swift, ImageRequest.swift
│   │   ├── Focus/           FocusCoordinator.swift
│   │   └── Support/         NSViewExtensions.swift, AppearanceObserver.swift, MainActorBridge.swift
│   ├── HelmApp/
│   │   └── AppDelegate.swift, AppEnvironment.swift, WindowRegistry.swift, OpenRequestRouter.swift, LaunchSequence.swift
│   └── Helm/
│       └── main.swift
├── App/                                Xcode inputs and bundle resources
│   ├── project.yml                      generates App/Helm.xcodeproj
│   ├── main.swift                       checked against Sources/Helm/main.swift if retained
│   ├── Info.plist
│   ├── Helm.entitlements
│   └── Assets.xcassets/
├── Tests/
│   ├── HelmCoreTests/  HelmFileSystemTests/  HelmOperationsTests/  HelmSearchTests/  HelmPersistenceTests/  HelmUITests/
└── UITests/
    └── HelmUIAutomationTests/          XCUITest, Xcode only
```

`Helm/` stays until GM passes and the owner approves its removal, because blind authors and the handoff need it as the behaviour reference.

### 3.4 Package.swift sketch

```swift
// swift-tools-version: 5.9
import PackageDescription

var products: [Product] = [
    .library(name: "HelmCore", targets: ["HelmCore"]),
    .library(name: "HelmFileSystem", targets: ["HelmFileSystem"]),
    .library(name: "HelmOperations", targets: ["HelmOperations"]),
    .library(name: "HelmSearch", targets: ["HelmSearch"]),
    .library(name: "HelmPersistence", targets: ["HelmPersistence"])
]
var targets: [Target] = [
    .target(name: "HelmCore"),
    .target(name: "HelmFileSystem", dependencies: ["HelmCore"]),
    .target(name: "HelmPersistence", dependencies: ["HelmCore"]),
    .target(name: "HelmOperations", dependencies: ["HelmCore", "HelmFileSystem"]),
    .target(name: "HelmSearch", dependencies: ["HelmCore", "HelmFileSystem"]),
    .target(name: "HelmTestKit", dependencies: ["HelmCore", "HelmFileSystem"]),
    .testTarget(name: "HelmCoreTests", dependencies: ["HelmCore", "HelmTestKit"]),
    .testTarget(name: "HelmFileSystemTests", dependencies: ["HelmFileSystem", "HelmTestKit"]),
    .testTarget(name: "HelmOperationsTests", dependencies: ["HelmOperations", "HelmTestKit"]),
    .testTarget(name: "HelmSearchTests", dependencies: ["HelmSearch", "HelmTestKit"]),
    .testTarget(name: "HelmPersistenceTests", dependencies: ["HelmPersistence", "HelmTestKit"])
]
#if os(macOS)
products += [
    .library(name: "HelmApp", targets: ["HelmApp"]),
    .executable(name: "HelmDev", targets: ["HelmDev"])
]
targets += [
    .target(name: "HelmUI", dependencies: ["HelmCore", "HelmFileSystem", "HelmOperations", "HelmSearch", "HelmPersistence"]),
    .target(name: "HelmApp", dependencies: ["HelmUI", "HelmCore", "HelmFileSystem", "HelmOperations", "HelmSearch", "HelmPersistence"]),
    .executableTarget(name: "HelmDev", dependencies: ["HelmApp"], path: "Sources/Helm"),
    .testTarget(name: "HelmUITests", dependencies: ["HelmUI", "HelmTestKit"]),
    .testTarget(name: "HelmAppTests", dependencies: ["HelmApp", "HelmTestKit"])
]
#endif
let package = Package(name: "Helm", platforms: [.macOS(.v14)],
                      products: products, targets: targets, swiftLanguageVersions: [.v5])
```

Before G3, restore HelmUI, HelmApp and their tests under the `#if os(macOS)` guard, and add HelmAppTests in the implementation manifest. Check that every directory under Sources/ and Tests/ is declared, conditionally or not, and each test target has at least one XCTest case.

Notes for the author:

- No `swiftSettings` with upcoming or experimental features. Strict concurrency is enabled at *targeted* level in the Xcode target (`SWIFT_STRICT_CONCURRENCY: targeted`) so the handoff session sees diagnostics without being blocked by them. That setting does not reach package targets: also run `swift build -Xswiftc -strict-concurrency=targeted` at the repository root.
- On Linux, `swift build` and `swift test` from the repository root cover exactly the core modules and tests. `--filter` selects tests to run, not targets to build; all Mac targets, including HelmUITests, must be excluded by the manifest guard.
- `platforms: [.macOS(.v14)]` applies to the Mac build; Linux ignores it.

### 3.5 Xcode app target and XcodeGen

`App/project.yml` describes exactly two targets (paths relative to App/):

```yaml
name: Helm
options:
  bundleIdPrefix: com.helm
  deploymentTarget:
    macOS: "14.0"
  xcodeVersion: "16.0"
packages:
  HelmPackage:
    path: ..
targets:
  Helm:
    type: application
    platform: macOS
    sources:
      - path: main.swift
      - path: Assets.xcassets
    dependencies:
      - package: HelmPackage
        product: HelmApp
    settings:
      base:
        INFOPLIST_FILE: Info.plist
        CODE_SIGN_ENTITLEMENTS: Helm.entitlements
        PRODUCT_BUNDLE_IDENTIFIER: com.helm.filemanager
        PRODUCT_NAME: Helm
        SWIFT_VERSION: "5"
        SWIFT_STRICT_CONCURRENCY: targeted
        MACOSX_DEPLOYMENT_TARGET: "14.0"
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
        ENABLE_HARDENED_RUNTIME: YES
        CODE_SIGN_STYLE: Manual
        CODE_SIGN_IDENTITY: "-"
        LD_RUNPATH_SEARCH_PATHS: "$(inherited) @executable_path/../Frameworks"
  HelmUIAutomationTests:
    type: bundle.ui-testing
    platform: macOS
    sources:
      - path: ../UITests/HelmUIAutomationTests
    dependencies:
      - target: Helm
    settings:
      base:
        SWIFT_VERSION: "5"
```

The package stays at the repository root. The app entry is `App/main.swift`; a static check requires it to match `Sources/Helm/main.swift` if retained. The SwiftPM executable is named `HelmDev` to avoid an app module collision [K, Mac]. The handoff verifies this layout first; if it fails, only the manifest owner changes to a root-project fallback.

A `schemes:` block still needs a verified Helm build action and test action listing automation and package tests [K, Mac]. Exact package-test syntax is not supplied by the review and is left for the manifest owner; M1 requires `xcodebuild -list` and one test action run. Fallback: `swift test` for package tests plus `xcodebuild` for automation only.

Single-source-of-truth rules:

- Shared implementation lives in the package. The app target compiles only `App/main.swift`; a static equality check against `Sources/Helm/main.swift` keeps the optional development entry aligned (fixes B-001).
- Proposed, owner decision pending under 04 Q6: generated `App/Helm.xcodeproj` is not committed; `.gitignore` lists it. The README build steps are `xcodegen generate --spec App/project.yml` then Xcode or `xcodebuild`.
- Unit tests run through SwiftPM on both platforms; Xcode runs the same package test targets only after explicit package-test entries are added to the shared scheme. The only Xcode-exclusive target is XCUITest.
- `Info.plist` and `Helm.entitlements` live under `App/` so SwiftPM never sees them. The asset catalog is attached to the Xcode target; the SwiftPM executable does not process it, because `swift run` is a development convenience and the bundled app is the product.
- `Info.plist` keeps its current content (`NSPrincipalClass` `NSApplication`, no main nib, the five usage descriptions, the `public.folder` Alternate viewer type) and adds `NSSupportsSuddenTermination` false and `LSApplicationCategoryType` `public.app-category.utilities`.
- When P-207 discovery ships, Info.plist includes `NSLocalNetworkUsageDescription` and `NSBonjourServices` with `_smb._tcp`, `_afpovertcp._tcp`, `_nfs._tcp`, `_webdav._tcp` [K, Mac]. Run `smbutil` only with an argument array and a validated host. Add a Mac test for denied local-network permission.
- Entitlements remain an empty dictionary under the hardened runtime (section 9).

---

## 4. State management

### 4.1 Shape of the state

Each window owns a `WindowStore`; each tab owns a `TabStore`. Both are `@MainActor final class` objects conforming to `ObservableObject` with one `@Published private(set) var state`. The state itself is a plain `Sendable` value.

```swift
// HelmCore
public struct Generation: Hashable, Sendable, Comparable {
    public let rawValue: UInt64
    public func next() -> Generation
    public static func < (lhs: Generation, rhs: Generation) -> Bool
    public init(rawValue: UInt64)
}

public struct TabState: Sendable, Equatable {
    public let id: TabID
    public var location: Location
    public var history: NavigationHistory
    public var selection: Set<ItemID>
    public var anchorID: ItemID?                 // first visible item, restored on view-mode switch
    public var viewMode: ViewMode
    public var sort: ItemSort
    public var showHidden: Bool
    public var expandedIDs: Set<ItemID>          // list-view expansion
    public var search: SearchState?              // nil when not searching
    public var snapshot: PresentationSnapshot
    public var loadGeneration: Generation
    public var monitorGeneration: Generation
    public var pendingNavigation: PendingNavigation?
    public var lastDirectory: URL?
    public var inlineRenameID: ItemID?
    public var snapshotCounter: UInt64
    public var starredIDs: Set<ItemID>
    public var cutIDs: Set<ItemID>
    public var addressBar: AddressBarState       // editing text, completion rows, popup visibility
    public init(id: TabID, location: Location, history: NavigationHistory, selection: Set<ItemID>, anchorID: ItemID?, viewMode: ViewMode, sort: ItemSort, showHidden: Bool, expandedIDs: Set<ItemID>, search: SearchState?, snapshot: PresentationSnapshot, loadGeneration: Generation, monitorGeneration: Generation, pendingNavigation: PendingNavigation?, lastDirectory: URL?, inlineRenameID: ItemID?, snapshotCounter: UInt64, cutIDs: Set<ItemID>, starredIDs: Set<ItemID>, addressBar: AddressBarState)
}

public struct WindowState: Sendable, Equatable {
    public var tabs: [TabID]
    public var activeTabID: TabID
    public var isSidebarVisible: Bool
    public var activeOperationIDs: [OperationID]
    public init(tabs: [TabID], activeTabID: TabID, isSidebarVisible: Bool, activeOperationIDs: [OperationID])
}
```

`NavigationHistory` is the current `NavigationState` turned into a value type with the same semantics plus a dedupe rule:

```swift
public struct NavigationHistory: Sendable, Equatable, Codable {
    public struct Entry: Sendable, Equatable, Codable {
        public let location: Location
        public let selection: Set<ItemID>
        public init(location: Location, selection: Set<ItemID>)
    }
    public private(set) var back: [Entry]
    public private(set) var forward: [Entry]
    public var canGoBack: Bool { get }
    public var canGoForward: Bool { get }
    public mutating func push(current: Entry, movingTo location: Location) -> Bool   // false when location == current.location
    public mutating func goBack(current: Entry) -> Entry?
    public mutating func goForward(current: Entry) -> Entry?
    public init(back: [Entry], forward: [Entry])
}
```

### 4.2 The presentation snapshot

The snapshot is the only thing views read. It is immutable, built off the main actor, and replaced wholesale.

```swift
public enum SnapshotPhase: Hashable, Sendable {
    case loading(loadedCount: Int)
    case ready
    case failed(LoadError, attempted: Location)
}

public enum LoadError: Hashable, Sendable {
    case notFound, permissionDenied, volumeUnmounted, notIndexed, cancelled, timedOut, other(String)
}

public struct TreeChildren: Hashable, Sendable {
    public let phase: SnapshotPhase
    public let sortedIDs: [ItemID]
    public init(phase: SnapshotPhase, sortedIDs: [ItemID])
}

public struct PresentationSnapshot: Sendable, Equatable {
    public let id: Generation
    public let location: Location
    public let phase: SnapshotPhase
    public let sort: ItemSort                 // .relevance for search results
    public let sortedEntries: [FileEntry]           // roots first in display order, then expanded entries
    public let rootCount: Int                      // root prefix length
    public let indexByID: [ItemID: Int]
    public let children: [ItemID: TreeChildren]     // expanded folders (list view)
    public let rankByID: [ItemID: Int]?             // search results only
    public let freeCapacityBytes: Int64?

    public static func == (lhs: PresentationSnapshot, rhs: PresentationSnapshot) -> Bool
    public func entry(_ id: ItemID) -> FileEntry?
    public func index(of id: ItemID) -> Int?
    public func visibleIDs(expanding expanded: Set<ItemID>) -> [ItemID]   // flattened for the outline
    public init(id: Generation, location: Location, phase: SnapshotPhase, sort: ItemSort, sortedEntries: [FileEntry], rootCount: Int, indexByID: [ItemID: Int], children: [ItemID: TreeChildren], rankByID: [ItemID: Int]?, freeCapacityBytes: Int64?)
}
```

Equality is defined on `id` only. The reducer stamps a fresh per-tab `snapshotCounter` value on every accepted snapshot, distinct from its load or monitor generation. A monitor rebuild with identical entries must still pass `removeDuplicates()`. `SnapshotBuilder` merges and sorts off the main actor; the reducer stamps metadata without rebuilding arrays. `sortedEntries` plus `indexByID` is the only entry store; `children` is the sole expanded-child topology (there is no separate TreeSnapshot).

Widgets initially call `reloadData()` and reapply selection and anchor. `SnapshotDiff` maps selection and anchors and is tested on Linux. Animated `performBatchUpdates` may be enabled behind a flag at Mac handoff only after count invariants are proven; a mismatch raises an Objective-C exception. While `inlineRenameID` is set, defer snapshot reload/application until editing ends so the field editor survives; retain the widget's old snapshot and resolve interactions through it until the queued snapshot is applied.

Why this removes B-009, B-010, B-011, B-033 and B-101 at once: the widget's datasource methods take `indexPath.item` or `row`, index `sortedEntries` for root items in the snapshot last applied, or resolve a TreeChildren.sortedIDs child through indexByID, and return that entry. Nothing is sorted on access; nothing is indexed into a mutable array; selection maps through `indexByID` in O(k).

### 4.3 Unidirectional flow

```
 user input / monitor / timer
        │
        ▼
   TabAction  ──▶  TabReducer.reduce(state, action) ──▶ (newState, [TabEffect])
                                                              │
   ┌──────────────────────────────────────────────────────────┘
   ▼
 TabStore (MainActor) publishes newState, runs effects in owned Tasks
   │                                   │
   ▼                                   ▼
 ContentHostController.apply(state)   effects complete ──▶ TabAction.completed(...)
 AddressBarController.apply(state)                           (dropped if generation stale)
 StatusBarView.apply(state)
 Toolbar/menu validation reads state
```

Signatures:

```swift
// HelmCore, pure
public enum TabAction: Sendable {
    case navigate(Location, NavigationIntent)      // .push, .back, .forward, .up, .home, .restore
    case goBack, goForward
    case loadStarted(Generation)
    case loadProgress(Generation, PresentationSnapshot)
    case loadFinished(Generation, PresentationSnapshot)
    case loadFailed(Generation, LoadError)
    case monitorEvent(Generation, MonitorEvent)
    case setSelection(Set<ItemID>, source: SelectionSource)
    case setSort(ItemSort)
    case setViewMode(ViewMode)
    case toggleHidden
    case expand(ItemID), collapse(ItemID), childrenLoaded(ItemID, Generation, PresentationSnapshot)
    case searchTextChanged(String), searchResults(Generation, [SearchResult]), searchEnded
    case addressBar(AddressBarAction)
    case starsChanged(Set<ItemID>), settingsChanged(SettingsSnapshot)
    case activated, deactivated
    case setScrollAnchor(ItemID?), beginInlineRename(ItemID), endInlineRename
    case openCompleted(URL, Bool), cutSetChanged(Set<ItemID>)
    case snapshotRebuilt(Generation, PresentationSnapshot)
    case monitorSnapshot(Generation, PresentationSnapshot)
    case refresh
    case operationCompleted(OperationSummary)
}

public enum TabEffect: Sendable, Equatable {
    case rebuildSnapshot(SnapshotRebuildRequest, Generation)
    case load(Location, Generation, LoadOptions)
    case loadChildren(ItemID, Generation)
    case startMonitor(Location, Generation)
    case stopMonitor(Generation)
    case startSearch(SearchQuery, Generation)
    case stopSearch
    case recordRecent(URL)
    case requestCompletions(CompletionRequest)
    case openItems([URL])
    case focusPane
    case refreshPaths(Set<String>, Generation)
    case persistShowHidden(Bool), invalidateCache(URL), beginInlineRename(ItemID)
    case updateMonitorScope(Set<URL>, Generation)
}

public enum TabReducer {
    public static func reduce(_ state: TabState, _ action: TabAction, context: ReducerContext) -> (TabState, [TabEffect])
}
```

`SnapshotRebuildRequest` is Equatable and Sendable and holds `baseRevision`, `sort`, `showHidden`, `expanded` and any `childrenPatch` identifiers, not row arrays. The store supplies the current listing to an off-main `SnapshotBuilder`. `.setSort`, `.toggleHidden`, `.settingsChanged` and `.searchResults` emit `.rebuildSnapshot`. Children deliver a built snapshot. `commit` compares generations only within its lane. Test: sorting 100k synthetic rows performs no sort inside `TabReducer.reduce`. The children/rebuild generation-field declarations and complete lane table still require contract design (Opus Fix 6).

`.starsChanged` sets `TabState.starredIDs`, like cut state. Row configuration reads stars at bind time. Test: toggling one star produces no new `FileEntry` values and refreshes one row.

`ReducerContext` carries a sampled `now` value (the store reads the injected HelmClock), the home URL, the current star set and the settings snapshot so the reducer stays pure and testable. The entire navigation, history, selection restoration, search lifecycle, hidden toggle and address-bar state machine are therefore unit-tested on Linux.

Navigation has an explicit commit boundary: `.navigate` stages `PendingNavigation` and starts loading; committed location, history and snapshot remain unchanged. First batch, or an empty successful finish, commits exactly once for that generation: update history by intent, location, selection (reset or restored), `lastDirectory`, Recent and `representedURL`. `.goBack` / `.goForward` peek history to stage their target; they mutate stacks only on commit. A pre-commit failure clears pending navigation, retains old location/history, and publishes `.failed(error, attempted: target)`; Try Again navigates to that target. A post-commit failure keeps the committed partial location and shows its error. NavigationIntent.back/forward are reducer-internal pending intents; UI sends goBack/goForward without duplicating a history target. Recent records push/up/home/back/forward, but not refresh or search clearing; stopping recording on search-clear reload is an intentional change from 00b M-16.

`TabStore.send` appends to a FIFO; a drain flag makes nested calls enqueue and return. Publish a completed reducer value, then run effects. A sink must use its delivered parameter, never `store.state` (`@Published` publishes in willSet). `SelectionBinder.isApplying` suppresses synchronous outline delegate callbacks during programmatic selection. Collection selection does not reliably emit delegates; grid user/programmatic command paths send explicitly. Tests must send an action from a sink without losing updates, and accept equal-content monitor snapshots with fresh IDs.

### 4.4 Observation choice

UI observation: **Combine `ObservableObject` with `@Published`** in HelmUI only. Foundation stores use `Broadcast` (4.6), adapted in HelmUI. Reasons (ADR-003):

- Combine and `@Published` are available on macOS 14, stable since 2019, and have no macro expansion that could fail blind.
- AppKit controllers observe with `store.$state.removeDuplicates().sink { [weak self] state in ... }.store(in: &cancellables)`. Because the store is `@MainActor` and publishes on the main actor, no `receive(on:)` is needed; `MainActor.assertIsolated()` in debug guards it.
- SwiftUI islands (`SidebarPlacesView`, `PropertiesView`, `BatchRenameView`, `OperationsPanelView`, settings views) take `@ObservedObject var model: SomeViewModel` where the view model is a `@MainActor ObservableObject` adapter owned by the hosting controller.
- UI callbacks use one-shot closures (`onCommit`, `onCancel`); core-store broadcasting uses the explicitly declared Broadcast contract, never Combine.

Controllers diff fields to avoid redundant work: `if old.snapshot.id != new.snapshot.id { reloadOrDiff() }`, `if old.selection != new.selection { applySelection() }`. The previous state is kept in the controller.

### 4.5 Concurrency model

- **Main actor:** every store, controller, view, view model, the icon and thumbnail caches (their lookups), menu and toolbar code, `NSMetadataQuery` ownership. Annotated `@MainActor` at the class level.
- **Actors:** `LiveFileSystem`, `InMemoryFileSystem`, `MonitorRegistry`, `ListingCache`, `CompletionProvider` and `OperationExecutor` own Sendable state. RecentStore is a main-actor class, not an actor. Blocking work uses `IOExecutor.run<T: Sendable>(volumeKey: String, _ work: @escaping @Sendable (CancellationFlag) throws -> T) async throws -> T`, bridging OperationQueue with `withCheckedThrowingContinuation` inside `withTaskCancellationHandler`. One queue per volume: local width 4, network width 1. Closures poll CancellationFlag; a locked completion guard resumes exactly once. A metadata/enumeration timeout returns `.timedOut`, marks the volume lane hung and causes later requests to fail fast with an unresponsive-volume UI. Mutations use a progress watchdog, not a wall-clock timeout. The OS call may remain blocked: quarantine the lane; never spawn unlimited replacement queues. No Task.detached dispatch wrapper or semaphore.
- **Sendable rules:** everything in `HelmCore`, `HelmFileSystem`, `HelmOperations`, `HelmSearch` and `HelmPersistence` public API is a `struct` or `enum` with Sendable members, or an actor, or a `final class` marked `@MainActor`. `NSImage`, `NSURL`, `NSMetadataItem` never enter core actors. UI image creation/cache access stays on main under SDK isolation; Thumbnail completion hops to the main actor carrying the generated representation, and the image is built and cached there. Do not re-encode images to cross an actor boundary. If the SDK’s Sendable annotations produce a warning in Swift 5 mode, record it for the Mac session and do not add an unchecked wrapper [Mac]. Platform icon work may have main-thread cost; measure it rather than asserting no AppKit-internal I/O. No `@unchecked Sendable` outside two documented places: the FSEvents callback context box and the locked `CancellationFlag` (including the exactly-once completion guard).
- **Cancellation:** each `TabStore` keeps `loadTask`, `childrenTasks: [ItemID: Task<Void, Never>]`, `searchTask`, `monitorTask`, `completionTask`. Starting a new one cancels the old one. Results carry the `Generation` they were started with; `TabStore.commit(_ action: TabAction, for generation: Generation)` ignores actions whose generation is older than the current one for that lane. Synchronous enumerators poll CancellationFlag between batches; async orchestrators check Task.isCancelled. No `runModal()` from inside a task; alerts are presented with `beginSheetModal(for:completionHandler:)` and the completion feeds back an action (B-086).
- **Lifetimes:** stores are owned by controllers; controllers are owned by the window controller; the window controller is owned by `WindowRegistry`. Explicit `teardown()` from `windowWillClose` stops monitors, removes observer tokens and cancels tasks. Main-actor `deinit` is nonisolated: it may cancel stored tasks or touch Sendable stored values, but cannot await or call isolated methods. If a Sendable monitor reference needs fallback cleanup, copy it to a local before `Task { await monitor?.stop() }`; never capture self from deinit. Controller work uses weak self; service tasks may capture immutable Sendable values.

---

`volumeKey` comes from a cached mount table refreshed on mount and unmount events, using `getfsstat(MNT_NOWAIT)` [K, Mac]. It never comes from a blocking read on the target path.

| Work | Timeout policy |
|---|---|
| Metadata and enumeration batches | Wall-clock timeout, with values measured on the Mac. |
| Mutations | No wall-clock timeout. A progress watchdog marks them stalled, offers Cancel, and an outcome that stays unknown blocks automatic retry. |

A quarantined lane probes after a backoff with a bounded single request. A successful probe or a mount-table change clears it. At most one replacement queue exists per volume.

### 4.6 Shared contracts and ownership inventory

No authored file may reference a cross-module type absent from this inventory. Missing signatures and owner-lane assignments identified in Opus Fix 10 must be resolved at G0; this mechanical pass does not invent them.

These declarations supplement the signatures in 4.1–4.3 and 5.2. All declarations in this block belong to HelmCore; platform services implement these contracts without reversing the module graph. Declaration-only notation omits bodies, not access levels. Each stored-field initializer is public (see rule 18); computed properties are not initializer parameters. Codable/Hashable requirements propagate through their member types.

```swift
// HelmCore/Identity
public enum Location: Hashable, Sendable, Codable {
    case directory(URL), recent, trash
    public var mutationTarget: URL? { get } // directory URL only
    public var kind: LocationKind { get }
}
public enum LocationKind: String, Hashable, Sendable, Codable { case directory, recent, trash }
public struct TabID: Hashable, Sendable, Codable {
    public let rawValue: UUID
    public init(rawValue: UUID)
}
public struct OperationID: Hashable, Sendable, Codable {
    public let rawValue: UUID
    public init(rawValue: UUID)
}
public struct StepID: Hashable, Sendable, Codable {
    public let rawValue: UUID
    public init(rawValue: UUID)
}
public enum ViewMode: String, Hashable, Sendable, Codable { case grid, list }
public struct ItemSort: Hashable, Sendable, Codable {
    public enum Field: String, Hashable, Sendable, Codable { case name, size, dateModified, kind, relevance }
    public let field: Field
    public let ascending: Bool
    public let directoriesFirst: Bool
    public init(field: Field, ascending: Bool, directoriesFirst: Bool)
    public static var relevance: ItemSort { get }
}
public enum NavigationIntent: Hashable, Sendable { case push, back, forward, up, home, restore }
public enum SelectionSource: Hashable, Sendable { case user, history, operation, widget }
public struct PendingNavigation: Sendable, Equatable {
    public let target: Location
    public let intent: NavigationIntent
    public let restoredSelection: Set<ItemID>
    public let generation: Generation
    public init(target: Location, intent: NavigationIntent, restoredSelection: Set<ItemID>, generation: Generation)
}
public struct LoadOptions: Sendable, Equatable {
    public let showHidden: Bool
    public let sort: ItemSort
    public let useCache: Bool
    public init(showHidden: Bool, sort: ItemSort, useCache: Bool)
}
public enum MonitorFailure: Hashable, Sendable { case permissionDenied, unavailable, timedOut, other(String) }
public struct OperationSummary: Sendable, Equatable {
    public let id: OperationID
    public let affectedDirectories: Set<URL>
    public let renamedIDs: [ItemID: ItemID]
    public let createdIDs: [ItemID]
    public let failureCount: Int
    public init(id: OperationID, affectedDirectories: Set<URL>, renamedIDs: [ItemID: ItemID], createdIDs: [ItemID], failureCount: Int)
}
public struct RecentRecord: Hashable, Sendable, Codable {
    public let path: String
    public let lastAccessedAt: Date
    public let kind: FileEntryKind
    public init(path: String, lastAccessedAt: Date, kind: FileEntryKind)
}
public struct TrashedItem: Hashable, Sendable, Codable {
    public let trashedURL: URL
    public let originalURL: URL
    public init(trashedURL: URL, originalURL: URL)
}
public protocol RecentRecordsProviding: Sendable {
    func recentRecords() async -> [RecentRecord]
}
public protocol TrashOriginRecording: Sendable {
    func record(_ items: [TrashedItem]) async
    func originalURL(forTrashed url: URL) async -> URL?
}
public enum SettingValue: Hashable, Sendable, Codable { case bool(Bool), integer(Int), double(Double), string(String) }
public struct SettingsSnapshot: Sendable, Equatable, Codable {
    public let values: [String: SettingValue] // typed schema validates keys/defaults in section 10.1
    public init(values: [String: SettingValue])
}
public struct ReducerContext: Sendable {
    public let now: Date
    public let home: URL
    public let stars: Set<ItemID>
    public let settings: SettingsSnapshot
    public init(now: Date, home: URL, stars: Set<ItemID>, settings: SettingsSnapshot)
}
public protocol HelmClock: Sendable { func now() -> Date }
public enum SidebarMode: String, Hashable, Sendable, Codable { case places, tree }
public enum FileNameError: Error, Hashable, Sendable { case empty, separator, nul, dot, tooLong }
public struct RenamePair: Hashable, Sendable {
    public let source: URL
    public let newName: ValidFileName
    public init(source: URL, newName: ValidFileName)
}
// RenamePair is shared because the pure BatchRenamePlanner returns it; never import operations into core.
public struct CompletionRequest: Hashable, Sendable {
    public let parent: URL
    public let prefix: String
    public let isSlashBrowsing: Bool
    public let showHidden: Bool
    public let generation: Generation
    public init(parent: URL, prefix: String, isSlashBrowsing: Bool, showHidden: Bool, generation: Generation)
}
public struct AddressBarState: Sendable, Equatable {
    public var isPending: Bool
    public var text: String
    public var rows: [CompletionRow]
    public var selectedIndex: Int?
    public var isEditing: Bool
    public var popupVisible: Bool
    public var caretAtEnd: Bool
    public var generation: Generation
    public init(text: String, isPending: Bool, rows: [CompletionRow], selectedIndex: Int?, isEditing: Bool, popupVisible: Bool, caretAtEnd: Bool, generation: Generation)
}
public enum AddressBarAction: Sendable, Equatable {
    case tabWhilePending
    case begin, edit(String), select(Int?), hidePopup, cancel, commit(String)
    case accept(CompletionRow), request(CompletionRequest)
    case completed(Generation, [CompletionRow])
}
public enum SearchScope: Hashable, Sendable { case currentFolder(URL), userFolders, computer, trash([URL]) }
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
public struct SearchResult: Hashable, Sendable {
    public let entry: FileEntry
    public let rank: Int
    public let isDocumentLike: Bool
    public init(entry: FileEntry, rank: Int, isDocumentLike: Bool)
}
public enum SearchEvent: Sendable { case gathering, results([SearchResult], isFinal: Bool), notIndexed }
public protocol SearchService: Sendable {
    func search(_ query: SearchQuery) -> AsyncThrowingStream<SearchEvent, Error>
}
public struct SearchState: Sendable, Equatable {
    public var query: SearchQuery
    public var generation: Generation
    public var results: [SearchResult]
    public var isGathering: Bool
    public init(query: SearchQuery, generation: Generation, results: [SearchResult], isGathering: Bool)
}
@MainActor public final class Broadcast<Value: Sendable> {
    public struct Token: Hashable, Sendable {
        public let rawValue: UUID
        public init(rawValue: UUID)
    }
    public init()
    public func subscribe(_ handler: @escaping @MainActor (Value) -> Void) -> Token
    public func cancel(_ token: Token)
    public func send(_ value: Value)
}
public enum AutoreleaseScope {
    public static func run<T>(_ body: () throws -> T) rethrows -> T
}
public enum Limits {} // named constants from F-IDs; no shared mutable state
```

`TabStore` maps OperationResult to OperationSummary before reducing. `RecentStore` implements RecentRecordsProviding; a persistence-owned TrashOriginStore implements TrashOriginRecording. AppEnvironment injects them into RecentSource and TrashCoordinator. Broadcast snapshots handlers before delivery; subscriptions are explicitly cancelled at teardown. AutoreleaseScope uses autoreleasepool only under `#if canImport(ObjectiveC)`, otherwise calls body directly.

Minimum non-core contracts (declared in the stated module; not legal dependencies of HelmCore):

| Type | Declaring module | Required shape / initializer |
|---|---|---|
| LoadEvent | HelmFileSystem | Sendable enum: `batch([FileEntry])`, `finished`, `warning(String)` |
| AccessBroker / AccessGrant | HelmFileSystem | Sendable protocol `access(_ url: URL) async -> AccessGrant`; Sendable struct `(url: URL, allowed: Bool)`, public init(url:allowed:); release policy is broker-owned |
| FileSystemError | HelmFileSystem | Error, Sendable enum: notFound, permissionDenied, timedOut, unsupported, other(String) |
| Conflict | HelmOperations | Hashable, Sendable struct source/destination URL; public init(source:destination:) |
| PlanningIssue | HelmOperations | Hashable, Sendable enum: sourceEqualsDestination, destinationInsideSource, sameParentMove, overlappingSelection, virtualLocationTarget, invalidName, insufficientSpace, unreadableSource |
| PlanSummary | HelmOperations | Sendable struct itemCount:Int, totalBytes:Int64, conflicts:[Conflict]; public init(itemCount:totalBytes:conflicts:) |
| OperationError | HelmOperations | Error, Hashable, Sendable enum: cancelled, permissionDenied, notFound, conflict, timedOut, unsupported, other(String) |
| CrossVolumeMoveBehaviour | HelmOperations | Hashable, Sendable enum: copyThenDeleteSource |
| EntryID | HelmOperations | typealias OperationID; identifies pending/final journal entry |
| TabStore / WindowStore | HelmUI/State | Main-actor ObservableObject final classes; public init(state:dependencies:), send action through FIFO; explicit teardown. Dependencies use WindowDependencies (8.3); state types are TabState/WindowState |
| ImageRequestToken | HelmUI | Hashable struct UUID, public init(rawValue:) |
| ImageRequesting | HelmUI | Main-actor protocol requestIcon(for:size:completion:) -> ImageRequestToken, cancel(_:); NSImage callbacks remain UI-local |
| ContentWidget | HelmUI | Main-actor protocol: apply(snapshot: PresentationSnapshot), apply(selection: Set<ItemID>), scrollAnchor: ItemID?, focusView: NSView, activate(), deactivate() |
| StoreLocation | HelmPersistence | Sendable struct directory:URL, public init(directory:); injected into codecs and tests |
| UserStrings | Each module | enum of static string constants, no Foundation/UI cross-module dependency |

Synchronous stream-returning protocols (FileSystem, LocationSource, SearchService) are witnessed by a struct or by `nonisolated func` on an actor/main-actor service, creating a stream and a Task that awaits isolated work. InMemoryFileSystem uses the actor form. AsyncStream.Continuation is Sendable for Sendable elements; no extra unchecked box is needed. Synchronous makeMonitor/monitor factories follow the same isolation rule, returning Sendable handles without reading isolated mutable state.

---

## 5. Async file-system layer

### 5.1 Protocols

```swift
// HelmFileSystem
public struct EnumerationOptions: Sendable, Equatable {
    public var includeHidden: Bool
    public var batchSize: Int                 // default 512
    public var resolveSymlinkTargets: Bool    // default true
    public init(includeHidden: Bool, batchSize: Int, resolveSymlinkTargets: Bool)
}

public protocol FileSystem: Sendable {
    func enumerate(_ directory: URL, options: EnumerationOptions) -> AsyncThrowingStream<[FileEntry], Error>
    func entry(at url: URL) async throws -> FileEntry
    func exists(_ url: URL) async -> Bool
    func isDirectory(_ url: URL, resolvingSymlinks: Bool) async -> Bool
    func childNames(of directory: URL) async throws -> Set<String>     // for collision planning
    func copyItem(at source: URL, to destination: URL) async throws
    func moveItem(at source: URL, to destination: URL) async throws
    func replaceItem(at destination: URL, with temporary: URL, backup: URL) async throws
    func applyDirectoryMetadata(from source: URL, to destination: URL) async throws
    func trashItem(at url: URL) async throws -> URL?
    func removeItem(at url: URL) async throws
    func createDirectory(at url: URL) async throws
    func createFileExclusively(at url: URL, contents: Data) async throws   // O_EXCL semantics (B-039)
    func createSymbolicLink(at url: URL, destination: URL) async throws
    func createAlias(for url: URL, at destination: URL) async throws
    func volumeIdentifier(for url: URL) async throws -> String
    func availableCapacity(of url: URL) async throws -> Int64
    func sizeOfTree(at url: URL) -> AsyncThrowingStream<Int64, Error>    // running total for Properties
    func makeMonitor(for directory: URL) -> any DirectoryMonitor
}
```

Two implementations: `LiveFileSystem` (FileManager, `URLResourceValues`, POSIX `open` with `O_CREAT | O_EXCL` for exclusive create) and `InMemoryFileSystem` (a dictionary tree with injectable failures and latency, used by every planner, executor, loader and reducer test on Linux).

### 5.2 Entries and identity

```swift
// HelmCore
public struct ItemID: Hashable, Sendable, Codable {
    public let rawValue: String          // standardized POSIX path for file-backed items
    public init(url: URL)
    public var url: URL { get }
}

public enum FileEntryKind: String, Hashable, Sendable, Codable {
    case regular, directory, package, symlinkToDirectory, symlinkToFile, danglingSymlink, alias, other
}

public struct ChangeToken: Hashable, Sendable, Codable {
    public let modificationDate: Date
    public let size: Int64
    public let childCount: Int?
    public init(modificationDate: Date, size: Int64, childCount: Int?)
}

public struct FileEntry: Hashable, Sendable, Identifiable, Codable {
    public let id: ItemID
    public let parentURL: URL
    public var url: URL { get }  // derived from parentURL and name
    public let name: String
    public let kind: FileEntryKind
    public let isHidden: Bool
    public let isReadable: Bool
    public let size: Int64
    public let modificationDate: Date
    public let creationDate: Date
    public let kindDescription: String?
    public let childCount: Int?
    public let contentTypeIdentifier: String?
    public let volumeIdentifier: String?
    public var availability: CloudAvailability
    public var isDirectoryLike: Bool { get }         // directory or symlinkToDirectory
    public var changeToken: ChangeToken { get }
    public init(id: ItemID, parentURL: URL, name: String, kind: FileEntryKind, isHidden: Bool, isReadable: Bool, size: Int64, modificationDate: Date, creationDate: Date, kindDescription: String?, childCount: Int?, contentTypeIdentifier: String?, volumeIdentifier: String?, availability: CloudAvailability)
}
```

HelmCore declares `public enum CloudAvailability: Sendable, Equatable { case local, notDownloaded, downloading, unknown }`. Reconcile this contract with as-built `Core/Model/CloudAvailability.swift` before implementation.

Identity is the standardized path. A rename produces a new ID; the journal records the mapping so selection follows renamed items. Equality includes all fields (the audit's caution about URL-only equality, 00b A-7), so a diff detects metadata changes.

Prefetch keys read in one `resourceValues(forKeys:)` call: `.nameKey`, `.isDirectoryKey`, `.isSymbolicLinkKey`, `.isAliasFileKey`, `.isPackageKey`, `.isHiddenKey`, `.isReadableKey`, `.fileSizeKey`, `.totalFileSizeKey`, `.contentModificationDateKey`, `.creationDateKey`, `.contentTypeKey` on macOS only. Read volume UUID once per directory, falling back to mount path; store that string, not an opaque volume identifier. For symlinks, a second `resourceValues` on `url.resolvingSymlinksInPath()` determines `symlinkToDirectory` versus `danglingSymlink`.

Also prefetch ubiquitous-item resource keys, guarded so a passive listing never reads content. Unknown availability is treated as not safe to thumbnail. The exact SDK key list remains a Mac-verified implementation task.

### 5.3 Enumeration

`DirectoryEnumerator` wraps `FileManager.enumerator(at:includingPropertiesForKeys:options:errorHandler:)` with `.skipsSubdirectoryDescendants` and, when hidden files are off, `.skipsHiddenFiles`. It yields batches of 512 `FileEntry` values and checks cancellation between batches. The first batch is yielded as soon as it is full or 50 ms have elapsed, so a slow network directory shows something quickly. Iteration occurs only in a synchronous IOExecutor closure, never directly in an async function. Each batch uses AutoreleaseScope. A preflight contentsOfDirectory/opendir distinguishes unreadable from empty (especially ~/.Trash); map root errorHandler failures including NSFileReadNoPermissionError and underlying EPERM. Enumeration errors on individual entries are surfaced as partial-read diagnostics and skipped; a failure to open the directory itself throws `FileSystemError.permissionDenied` or `.notFound`, which the reducer maps to `SnapshotPhase.failed`.

### 5.4 Large-folder strategy

| Size | Behaviour |
|---|---|
| up to 5,000 root items | Batches merged into a sorted array as they arrive (insertion through binary search per batch); off-main SnapshotBuilder produces snapshots; widgets reload and restore selection by ID (no blind batch updates). |
| 5,000 to 100,000 | Batches accumulated unsorted; the snapshot phase shows `.loading(loadedCount:)` with a count in the status bar; one sort at completion; `reloadData()` instead of diffing; thumbnails requested only for visible cells with a 100 ms scroll-settle delay. |
| above 100,000 | Same as above, plus the grid refuses live thumbnails until scrolling stops for 300 ms and the list disables alternating-row animation. No upper cap; `NSCollectionView` and `NSOutlineView` virtualize cells. |

Memory: 30 MB for 100k entries is a target to measure, not a 300-byte assertion. Derive URL from parent/name, intern content-type and volume strings, and use sortedEntries plus indexByID rather than a dictionary plus another sorted-ID array. Expanded topology and ranks still cost memory. `ListingCache` keeps at most 200,000 entries, evicts least recently used listings, and clears on macOS memory-pressure notifications (guarded); Linux uses the entry cap and explicit purge.

### 5.5 Caching and invalidation

`ListingCache` is keyed by `(Location, showHidden)` and stores `(snapshotEntries, directoryChangeToken, timestamp)`. A navigation may display cached data with `.loading` pending an existence/access check; it never presents `.ready` for a deleted or unreadable directory. After validation, a cached first batch can commit while background revalidation enumerates; if the directory's own change token (modification date) differs or `helm.directoryCacheTTL` expired, the fresh result replaces it. Invalidation sources: monitor events for the directory, `OperationResult` touching the directory, explicit refresh, and setting `helm.enableDirectoryCache` to false (which also empties the cache).

### 5.6 Virtual locations and the search snapshot

```swift
public protocol LocationSource: Sendable {
    func load(_ location: Location, options: LoadOptions) -> AsyncThrowingStream<LoadEvent, Error>
    func monitor(_ location: Location) -> (any DirectoryMonitor)?
}
```

`DirectoryLoader` serves `.directory`; `RecentSource` serves `.recent` through injected `RecentRecordsProviding` (implemented by RecentStore), ordered by last access; `TrashSource` serves `.trash` by enumerating every trash directory; search results are produced by `HelmSearch` and committed as a snapshot with `sort == .relevance` and `rankByID`. `SnapshotBuilder` refuses to re-sort a `.relevance` snapshot by anything else, which is the structural fix for B-022; the user can still choose a column sort, at which point the snapshot sort changes explicitly and the rank is kept only as a tiebreaker.

### 5.7 Path completion service

```swift
// HelmCore, pure
public struct CompletionRow: Hashable, Sendable {
    public let name: String
    public let path: String        // absolute, normalized
    public let isDirectory: Bool
    public let isParentLink: Bool  // ".."
    public init(name: String, path: String, isDirectory: Bool, isParentLink: Bool)
}
public enum PathCompletionEngine {
    public static func request(for text: String, currentDirectory: URL, home: URL, showHidden: Bool, generation: Generation) -> CompletionRequest?
    public static func rows(for request: CompletionRequest, children: [FileEntry], showHidden: Bool, limit: Int) -> [CompletionRow]
    public static func ghostSuffix(typed: String, selected: CompletionRow?, caretAtEnd: Bool) -> String?
    public static func tabAction(state: AddressBarState) -> AddressBarAction
    public static func returnAction(state: AddressBarState) -> AddressBarAction
}

// HelmFileSystem
public actor CompletionProvider {
    public init(fileSystem: any FileSystem)
    public func complete(_ request: CompletionRequest) async throws -> [CompletionRow]
}
```

The provider enumerates the whole parent off main (names and isDirectory), filters anchored/case-insensitive, sorts directories first then localizedStandardCompare, and only then caps prefix results at 50. Arbitrary enumeration order makes early stop incorrect. Prefix-only cache: 3 s, at most 30 directories. Slash browsing has no debounce or cache and re-lists; it prepends parent then takes 50 children (51 total outside root, verified source; review Fix 60 cap claim rejected). Programmatic edits set generation before issuing requests. Test `tabTabTabDrillShowsLastDirectory` with late fake responses so the old multi-level-drilling failure cannot return. Never create images here. The panel asks `IconCache` for icons of visible rows only.

Address pending semantics (proposed, pending Mac feel test):

- An edit clears rows immediately and sets pending.
- A popup shows one non-selectable spinner row after 100 ms.
- Return with trailing `/` or while pending commits the literal text.
- Tab while pending is held, at most one. On arrival, a held Tab accepts row 1 (first child) when the list came from a slash-ended drill and a child exists, and otherwise follows F-020. A second Tab while one is held is consumed.
- Esc while pending cancels the request and hides the popup.
- Up and Down while pending do nothing.

The held-Tab rule protects drilling from `..` at row 0 when a reply arrives late. Immediate Tab with rows already showing keeps today's `..` behaviour. This is my proposal, because source has no equivalent state. Test it with a delayed provider on a Mac for feel.

### 5.8 Icons and thumbnails

```swift
// HelmUI
@MainActor public final class IconCache {
    public init(limit: Int)
    public func icon(for entry: FileEntry, size: CGFloat) -> NSImage?            // synchronous cache hit
    public func requestIcon(for entry: FileEntry, size: CGFloat, completion: @escaping @MainActor (NSImage) -> Void) -> ImageRequestToken
    public func cancel(_ token: ImageRequestToken)
    public func invalidate(_ id: ItemID)
    public func setLimit(_ limit: Int)
}

@MainActor public final class ThumbnailPipeline {
    public init(cache: IconCache, costLimitBytes: Int)
    public func thumbnail(for entry: FileEntry, size: CGSize, scale: CGFloat) -> NSImage?
    public func requestThumbnail(for entry: FileEntry, size: CGSize, scale: CGFloat, completion: @escaping @MainActor (NSImage) -> Void) -> ImageRequestToken
    public func cancel(_ token: ImageRequestToken)
    public func invalidate(_ id: ItemID)
}
```

Thumbnail completion follows §4.5: hop to main with the generated representation, build/cache there, and never re-encode merely to cross actors.

Keys are `ItemID` plus change token plus size. `QLThumbnailGenerator.shared.generateBestRepresentation(for:completion:)` is called with `QLThumbnailGenerator.Request(fileAt:size:scale:representationTypes: .thumbnail)` where size is in points and scale is the window backing scale, which fixes the 4× pixel request (B-056). Each key keeps a subscriber list; cancelling a token removes one subscriber and cancels the generator request only when the list empties (B-055). Cost accounting uses pixel bytes.

---

### 5.9 Search service lifecycle and ranking inputs

SearchService, SearchQuery, SearchResult and SearchEvent belong to HelmCore (4.6). HelmSearch implements SpotlightSearchService under `#if os(macOS)` and EnumerationSearchService for tests/fallback. SpotlightQueryBuilder returns format plus typed arguments; only the Mac implementation constructs NSPredicate. Bookmark paths are injected in each query; search never reads UserDefaults. Settings and discovered preferred roots are immutable injected values, refreshed by replacing/reconfiguring the service on the next query.

NSMetadataQuery is owned on the main actor. On DidFinishGathering and DidUpdate, disable updates and read at most `max(limit * 3, 450)` candidates into Sendable values on main; re-enable updates afterward. NSMetadataItem never leaves that actor. On main, read only `NSMetadataItem` attribute values (path, name, dates, content type) for at most the cap, then dedupe. No filesystem calls on main. An off-main `MetadataReader` builds `FileEntry` values and silently skips items that fail, as today (`:213`). Ranking runs off main. Sort the query by `kMDItemFSContentChangeDate` descending, then NSMetadataItemFSNameKey ascending, before the candidate cap. The TabStore tags deliveries with its query generation; cancellation stops only the captured query identity (B-021). Empty final gathering plus apparently unindexed roots triggers EnumerationSearchService; no direct indexing API proves this, so it is a heuristic [Mac], and a truly empty indexed directory must not loop forever. Fallback respects the same scope, hidden policy, cancellation and result limit.

`systemPathPrefixes = /system/, /library/, /private/, /usr/, /bin/, /sbin/, /dev/, /opt/`, matched lowercased (`SpotlightSearchService.swift:18-27`).

| Scope policy (`:127-185`) | Query scopes |
|---|---|
| Not preferring; no system | `[HomeScope]` |
| Not preferring; with system | `[HomeScope, LocalComputerScope]` |
| Preferring | Home, the seven standard folders, bookmarks and removable browsable volumes, plus optional LocalComputer, deduped. |

`SearchQuery.showHidden` is the separate hidden policy. Keep `NOT (kMDItemFSName BEGINSWITH '.')` when hidden is off (`:113-125`).

Preserve the full F-045 score table. `relativeDepth = max(0, itemComponents - homeComponents - 1)`; user-content excludes `home/library/`. Preferred roots are documents, desktop, downloads, projects, work, pictures, movies, music, developer, sites, code, coding, applications, public, plus visible Home directories except library and .trash. Discover roots off main and inject them; do not lowercase URLs used for filesystem access. Kind sorting uses cached FileEntry.kindDescription and localizedStandardCompare. Ranker candidate input includes isDocumentLike: Mac metadata uses UTType conformity to text/pdf/image/audiovisualContent OR extension `txt, md, rtf, pdf, doc, docx, odt, pages, xls, xlsx, numbers, ppt, pptx, key, csv, json, yaml, yml, xml`; Linux fixtures use that extension list.

---

## 6. Directory monitoring

### 6.1 Mechanism choice

FSEvents remains the primary mechanism (ADR-004): it is the only API that reports which path changed, works for whole directories without an open file descriptor per watched node, and reports a root-change signal for revalidation when `kFSEventStreamCreateFlagWatchRoot` is set; it does not supply a replacement path. Flags: `FileEvents | UseCFTypes | NoDefer | WatchRoot`, latency 0.3 s, `sinceWhen` now, dispatch queue utility. The current implementation's defects are fixed structurally:

- **Non-recursive scope.** `FileEvents` streams are recursive; `FSEventsMonitor` filters callback paths to the watched directory itself and its direct children (compare direct-parent paths against realpath of the watched directory; map children back to the displayed path by last component). Deeper events are dropped unless the event carries `MustScanSubDirs` or `RootChanged` (B-073).
- **Shared streams.** `MonitorRegistry` (actor) refcounts monitors by directory path so two tabs on one directory share one FSEvents source but get separate AsyncStreams via `subscribe(path:) -> AsyncStream<MonitorEvent>` fan-out, and so closing a tab stops nothing another tab still needs.
- **Generation tokens.** Each stream gets a monotonically increasing token; termination handlers compare tokens, not pointer values (B-104).
- **Failure handling.** `FSEventStreamCreate` or `FSEventStreamStart` failure falls back to `DispatchSourceMonitor` (a `DispatchSource.makeFileSystemObjectSource` on the directory's file descriptor with `[.write, .rename, .delete, .attrib]`), which reports coarse `.rescan` events; if that fails too (network volumes without vnode events), `PollingMonitor` compares the directory's modification date and child count every 3 s. Which mechanism is active is visible in the status bar tooltip for debugging (B-015).
- **Lifetime.** Handles stop, invalidate and release the stream in `deinit` (B-072).

```swift
// HelmCore (shared event values; not owned by HelmFileSystem)
public enum MonitorEvent: Hashable, Sendable {
    case changed(paths: Set<String>)          // watched directory or direct children
    case rescan
    case rootChanged  // revalidate; no replacement path promised
    case volumeUnmounted
    case unavailable(MonitorFailure)
}
// HelmFileSystem
public protocol DirectoryMonitor: Sendable {
    var events: AsyncStream<MonitorEvent> { get }
    func start() async throws
    func stop() async
}
```

### 6.2 Coalescing

`EventCoalescer` (pure, `HelmFileSystem/Monitor`, testable with a fake clock) merges events within a 250 ms quiet window and forces delivery at most every 1 s during sustained traffic, so a build writing continuously no longer starves refresh (B-016). `.rescan` and `.rootChanged` flush immediately.

### 6.3 Event-to-diff

`DirectoryLoader.refresh(location:changed:)` handles a `.changed(paths)` event by re-reading `FileEntry` for each listed path: a path that no longer exists becomes a removal, a path that is new becomes an insertion, a path whose change token differs becomes an update. The directory's own path in the set means an add or remove happened that FSEvents attributed to the parent; the loader then runs `childNames(of:)` and reconciles by name against the current snapshot before fetching metadata only for the differences. The result goes through `SnapshotBuilder.applying(changes:to:)` producing a new snapshot with the same sort and the same selection intersected by ID. `.rescan` performs a full reload through the cache. Metadata reads can be incremental; snapshot sorting/indexing can still be O(n). Initial widgets perform one reload, with cell creation bounded by visible cells; measure layout cost at 100k on Mac. Keep a UniformGridLayout: NSCollectionViewLayout seam if flow layout misses budget. Inline rename defers applying these reloads (4.2).

### 6.4 Mounts and permission loss

`VolumeEventSource` in HelmUI owns NSWorkspace mount/unmount notifications and feeds sidebar and MonitorRegistry. `VolumeReader` in HelmFileSystem reads mounts/resource values off main, with macOS-only keys guarded. ApplicationProvider and image/default-app PropertiesEnricher live in HelmUI; PropertiesLoader retains only file attributes in HelmFileSystem. The watched set is the tab directory plus expanded directory IDs, updated by `updateMonitorScope(Set<URL>, Generation)`. Port the callback bridge from Services/FileMonitorService.swift. Optional F_GETPATH on an O_EVTONLY descriptor is a Mac experiment, not a rootChanged payload guarantee. When a watched directory's volume unmounts, the registry emits `.volumeUnmounted`; the reducer sets `phase = .failed(.volumeUnmounted, attempted: location)` and keeps the location so Back still works; the content pane shows a "Volume is no longer available" state with a Go Home button. A `.permissionDenied` error from the loader produces the Full Disk Access guidance state (section 9). Monitoring is stopped while a tab is inactive and restarted with a `.rescan` on activation (B-013).

---

## 7. Undoable operations engine

### 7.1 Commands

```swift
// HelmOperations
// RenamePair and TrashedItem are declared in HelmCore (4.6).

public enum Command: Hashable, Sendable {
    case copy(sources: [URL], destinationDirectory: URL)
    case move(sources: [URL], destinationDirectory: URL)
    case duplicate(sources: [URL])
    case trash(items: [URL])
    case rename(RenamePair)
    case batchRename([RenamePair])
    case createFolder(parent: URL, name: ValidFileName)
    case createFile(parent: URL, name: ValidFileName, template: URL?)
    case makeAlias(item: URL, destinationDirectory: URL)
    case makeSymbolicLink(item: URL, destinationDirectory: URL)
    case putBack([TrashedItem])
    case emptyTrash(directories: [URL])
    case deletePermanently(items: [URL])
}
```

### 7.2 Planning context and preflight

```swift
public struct PlanningContext: Sendable {
    public let sourceManifest: [SourceEntry]
    public let availableBytes: [URL: Int64]
    public let caseSensitive: [URL: Bool]
    public let existingNames: [URL: Set<String>]        // per destination directory
    public let volumeIDs: [URL: String]                 // per source and destination
    public let isDirectoryLike: [URL: Bool]
    public let defaultPolicy: ConflictPolicy
    public let crossVolumeMoveBehaviour: CrossVolumeMoveBehaviour   // .copyThenDeleteSource
    public init(sourceManifest: [SourceEntry], availableBytes: [URL: Int64], caseSensitive: [URL: Bool], existingNames: [URL: Set<String>], volumeIDs: [URL: String], isDirectoryLike: [URL: Bool], defaultPolicy: ConflictPolicy, crossVolumeMoveBehaviour: CrossVolumeMoveBehaviour)
}
```

`PlanningContextBuilder` performs async I/O first: collect a source manifest without following symlinks, destination-volume case sensitivity and available capacity. `SourceEntry` (HelmOperations, Hashable/Sendable struct) contains source URL, relativePath String, kind FileEntryKind, size Int64 and changeToken ChangeToken, with public init(source:relativePath:kind:size:changeToken:). Free-space preflight estimates copies/temporary replacement space per destination; unknown capacity is shown as unknown, not zero. `OperationPlanner.preflight` then runs purely over that context before any mutation and produces `[PlanningIssue]`: `.sourceEqualsDestination`, `.destinationInsideSource`, `.sameParentMove` (treated as no-op for move, keep-both duplicate for copy), `.overlappingSelection` (ancestor plus descendant, descendant dropped), `.virtualLocationTarget` (refused; B-031), `.invalidName`. The UI shows blocking issues before starting.

### 7.3 Conflict policy and the plan

```swift
public enum ConflictResolution: Hashable, Sendable { case keepBoth, replace, skip, stop }
public struct ConflictPolicy: Hashable, Sendable {
    public var defaultResolution: ConflictResolution        // keepBoth, matching current behaviour
    public var perItem: [URL: ConflictResolution]
    public var applyToAll: Bool
    public init(defaultResolution: ConflictResolution, perItem: [URL: ConflictResolution], applyToAll: Bool)
}

public struct PlannedStep: Hashable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable { case copyFile, copyDirectoryShell, moveSameVolume, moveCrossVolume, trash, remove, rename, createDirectory, createFile, link, alias, putBack }
    public let id: StepID
    public let kind: Kind
    public let source: URL?
    public let destination: URL?
    public let estimatedBytes: Int64
    public let conflict: Conflict?                  // destination exists; resolution applied
    public init(id: StepID, kind: Kind, source: URL?, destination: URL?, estimatedBytes: Int64, conflict: Conflict?)
}

public struct OperationPlan: Sendable {
    public let command: Command
    public let steps: [PlannedStep]
    public let issues: [PlanningIssue]
    public let totalBytes: Int64
    public var isExecutable: Bool { get }
    public var summary: PlanSummary { get }         // for the conflict sheet and tests
    public init(command: Command, steps: [PlannedStep], issues: [PlanningIssue], totalBytes: Int64)
}

public enum OperationPlanner {
    public static func plan(_ command: Command, context: PlanningContext) -> OperationPlan
    public static func resolve(_ plan: OperationPlan, with policy: ConflictPolicy) -> OperationPlan
}
```

`UniqueNamer` (pure, `HelmCore`) produces `name 2.ext`, `name 3.ext`, and treats a known multi-part extension list (`tar.gz`, `tar.bz2`, `tar.xz`, `tar.zst`) as a unit (B-116). Keep-both is the default. If conflicts exist and helm.askOnConflict is on, the sheet offers Keep Both, Replace, Skip, Stop and Apply to All; otherwise keep-both applies silently. Execution-time collisions invoke the same policy and keep-both retries on EEXIST (B-039). The planner is pure and fully testable on Linux with `InMemoryFileSystem` supplying the context.

### 7.4 Execution, progress, cancellation

```swift
public struct ItemOutcome: Sendable, Hashable {
    public let step: StepID
    public let source: URL?
    public let destination: URL?
    public let result: Result<ChangeToken?, OperationError>
    public init(step: StepID, source: URL?, destination: URL?, result: Result<ChangeToken?, OperationError>)
}
public struct OperationResult: Sendable {
    public let id: OperationID
    public let command: Command
    public let outcomes: [ItemOutcome]
    public let affectedDirectories: Set<URL>
    public var succeededCount: Int { get }
    public var failedCount: Int { get }
    public var wasCancelled: Bool { get }
    public init(id: OperationID, command: Command, outcomes: [ItemOutcome], affectedDirectories: Set<URL>)
}
public struct OperationProgress: Sendable, Equatable {
    public let id: OperationID
    public let itemsDone: Int, itemsTotal: Int
    public let bytesDone: Int64, bytesTotal: Int64
    public let currentName: String?
    public let estimatedRemaining: TimeInterval?
    public init(id: OperationID, itemsDone: Int, itemsTotal: Int, bytesDone: Int64, bytesTotal: Int64, currentName: String?, estimatedRemaining: TimeInterval?)
}
public actor OperationExecutor {
    public init(fileSystem: any FileSystem, copier: any FileCopier)
    public func execute(_ plan: OperationPlan, policyResolver: @escaping @Sendable (Conflict) async -> ConflictResolution) -> (progress: AsyncStream<OperationProgress>, result: Task<OperationResult, Never>)
}
```

Rules: steps run sequentially; directories are copied as a created shell followed by per-file steps so progress and cancellation have file granularity; cross-volume move is copy, verify size, then remove source; same-volume move uses `moveItem` (rename semantics). `Task.isCancelled` is checked before each step. Partial failure never throws; every step produces an outcome (B-038). Cancellation leaves completed steps in place and reports them; the operations panel offers "Revert" which journals an inverse of the completed steps. `ProgressEstimator` (pure) computes ETA from an exponential moving average of bytes per second with a 2 s warm-up.

`FileCopier` is a HelmOperations Sendable protocol: `copy(from: URL, to: URL) async throws`. The initial live implementation delegates to copyItem; one large file has no byte progress or cancellation until the call returns. A copyfile(3) implementation is a Mac handoff improvement, not claimed implemented. Directory dates, permissions, xattrs and flags are applied only after children finish. Replacement never removes an existing item before the new copy exists: copy to a destination-local temporary name, swap/rename safely, move the displaced original to Trash and journal its URL. If swap or trash fails, retain recovery artifacts and report their paths; never silently remove the old item. Folder replace replaces, with no merge option. Cross-volume source deletion happens only after successful copy verification.

### 7.5 Names

```swift
// HelmCore
public struct ValidFileName: Hashable, Sendable {
    public let value: String
    public init?(_ raw: String)   // trims .whitespaces; rejects empty, "/", NUL, ".", "..", and names over 255 UTF-8 bytes; permits ":"
}
public enum FileNameValidator {
    public static func validate(_ raw: String) -> Result<ValidFileName, FileNameError>
}
```

Compare canonically decomposed names, additionally case-folding on case-insensitive destinations. A case-only rename of the same item is not a collision (R-18); use a temporary intermediate name if necessary. Colon is valid POSIX input (Finder renders it as slash), so do not invent a restriction.

Stores persist a raw `String` and call the validator on read. A failure becomes an explicit error, not a silently accepted name. Test: a journal containing `a/b` fails to load that entry and reports it.

Rename and batch rename inputs reach the operations module only as `ValidFileName` (B-046). `BatchRenamePlanner.plan(items:rule:)` returns `[RenamePair]` plus an ordering that uses temporary names (`.helm-rename-<uuid>`) when targets overlap or swap (B-047).

### 7.6 Journal and undo semantics

```swift
public struct JournalEntry: Sendable, Identifiable {
    public let id: OperationID
    public let actionName: String                  // "Copy", "Move", "Move to Trash", ...
    public let forward: Command
    public let outcomes: [ItemOutcome]             // exact sources and destinations
    public let completedAt: Date
    public init(id: OperationID, actionName: String, forward: Command, outcomes: [ItemOutcome], completedAt: Date)
}
@MainActor public final class OperationJournal {
    public init(executor: OperationExecutor, fileSystem: any FileSystem)
    public func begin(_ command: Command) -> EntryID
    public func complete(_ id: EntryID, outcomes: [ItemOutcome])
    public func record(_ result: OperationResult) // convenience for already completed external results
    public func undo() async -> OperationResult?
    public func redo() async -> OperationResult?
    public var canUndo: Bool { get }
    public var canRedo: Bool { get }
    public var undoTitle: String { get }
    public var redoTitle: String { get }
}
public enum UndoPlanner {
    public static func inverse(of entry: JournalEntry, currentTokens: [URL: ChangeToken?]) -> Command?
}
```

Inverse mapping: copy and duplicate become `trash(destinations)` (never `removeItem`; B-041), and the journal warns first if any destination's change token differs from the recorded one; move becomes move back to the exact original URLs (B-042); trash becomes `putBack` using recorded trash URLs; rename and batch rename invert pairwise with temporary names where needed; createFolder and createFile become trash; makeAlias and makeSymbolicLink become trash; putBack becomes trash; emptyTrash and deletePermanently are not undoable and invalidate only journal entries referencing affected removed items, after confirmation. Redo re-executes the forward command through the same planner so it respects conflicts that appeared meanwhile.

File operations do not use UndoManager. OperationJournal owns undo/redo stacks, canUndo/canRedo and undoTitle/redoTitle. `begin(command)` allocates a pending record before awaiting; `complete(id, outcomes)` finalizes an immutable JournalEntry with its completedAt timestamp. Capture the entry ID before execution so a tab hidden or closed mid-operation still records (B-105). The app's operation registry retains the originating journal for operations surviving window closure; menus only expose the active window journal.

MainSplitViewController, in the pane's chain before the window, implements `undo(_:)` and `redo(_:)`, validates and titles those items from the journal. If firstResponder is NSText, forward to window.undoManager. Toolbar address/search editors bypass this controller and reach their text/window undo normally. Do not implement windowWillReturnUndoManager or register file inverses with UndoManager. Keep `Selector(("undo:"))` and `Selector(("redo:"))`. Undo/redo are tracked operations with progress/errors and explicit invalidation of every affected directory (B-043); routing is a required Mac check.

### 7.7 Clipboard semantics

`ClipboardState` is one app-level owner; a change broadcasts `cutSetChanged` to every tab in every window.

```swift
public struct ClipboardState: Sendable, Equatable {
    public let urls: [URL]
    public let isCut: Bool
    public let changeCount: Int           // NSPasteboard.general.changeCount at write time
    public init(urls: [URL], isCut: Bool, changeCount: Int)
}
public struct ClipboardTransaction: Sendable {
    public let sources: [URL]
    public let isMove: Bool
    public let destination: URL
    public func command() -> Command
    public init(sources: [URL], isMove: Bool, destination: URL)
}
```

Copy and Cut write `NSURL` objects to the general pasteboard and record `ClipboardState`. Paste reads the pasteboard's current `changeCount`; if it differs from the recorded one, the internal state is discarded and the pasteboard URLs are treated as a copy (B-036). Reads use `readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])` (B-106). Record changeCount immediately after writing. After a successful cut-move, clear pasteboard only if changeCount still matches; otherwise leave it alone. This prevents a second paste of moved URLs. After partial success, rewrite remaining failed cut URLs only if changeCount still matches, updating the count; after a partial failure the failed sources remain marked cut (B-037). Cut items are drawn at 50 % opacity in both views. Paste with a cut source into the same directory is a no-op; with a copied source it is a duplicate with keep-both naming. Menu validation enables Paste only when a file-URL read would succeed and the location has a mutation target (00b C-23).

### 7.8 Trash and Put Back

`TrashCoordinator` lists trash directories: `~/.Trash` plus `/Volumes/<name>/.Trashes/<uid>` for mounted volumes and the iCloud Drive trash candidate `~/Library/Mobile Documents/com~apple~CloudDocs/.Trash` [K, Mac]. Probe permission/existence and dedupe; provider-specific eviction/trash behavior must be validated, not assumed. Move to Trash uses `trashItem(at:resultingItemURL:)` and records `TrashedItem` pairs in the journal and in the injected `TrashOriginRecording` persistence implementation backed by `trash-origins.json` so Put Back works across launches for items Helm trashed. Items trashed by other apps show Put Back disabled (no public API for Finder's put-back record). Empty Trash enumerates each trash directory and removes items with a confirmation sheet; it is not undoable and removes only journal entries referring to emptied items. ItemOutcome.destination stores the actual resulting trash URL, not a guessed path; origin persistence uses only non-nil results. A nil resulting trash URL is a successful trash outcome without a restorable origin; journal it as not restorable. A volume without Trash gets a separate “Delete immediately?” sheet listing affected items, never silent permanent deletion. Preflight distinguishes EPERM from an empty directory and shows the permission state (B-109). Moving out of ~/.Trash without Full Disk Access, and iCloud trash behavior, remain unverified [Mac].

### 7.9 Drops and the dry-run planner

`DropModifiers` is a HelmOperations `public struct: OptionSet, Sendable` with `public let rawValue: Int`, `public init(rawValue: Int)`, and static option/command flags. UI fills it from the class property NSEvent.modifierFlags and includes .generic in the source operation mask so Cmd survives mask intersection [K, Mac]. `DropPlanner.proposal(sources:destination:modifiers:volumeIDs:)` (pure) returns `.move`, `.copy` or `.none` with the reason, honouring Finder's defaults: same volume moves, cross volume copies, Option forces copy, Cmd forces move, and the drag source's `draggingSourceOperationMask` is intersected (B-045). The resulting `Command` goes through `OperationPlanner.plan` exactly like a Paste, so drags are journaled (B-044). Every command can be dry-run: `OperationPlanner.plan` has no side effects and its `PlanSummary` is what the conflict sheet shows and what tests assert on.

---

## 8. View layer

### 8.1 AppKit, SwiftUI or hybrid

Hybrid, AppKit-dominant (ADR-002): AppKit for the window, split view, toolbar, tabs, address bar, grid, list, status bar, menus, drag and drop, Quick Look and focus; SwiftUI islands for the sidebar list, the Properties and Batch Rename sheets, the conflict sheet, the operations panel and the settings forms.

Performance justification for the content pane: `NSCollectionView` and `NSOutlineView` recycle cells and lay out only visible rows, so a 100k-item snapshot costs memory for entries, not for views. They provide native rubber-band and keyboard selection, type-select, inline editing, drag sessions with `NSPasteboardWriting`, accessibility roles and `reloadData` or batch updates with stable identity through the snapshot. SwiftUI `List` and `LazyVGrid` on macOS 14 do not expose first-responder control, type-select, inline rename, drag session operation masks, or incremental batch updates by identity, and their diffing cost grows with the number of rows handed to them. Their known scrolling stalls on tens of thousands of rows would reintroduce the B-010 class at the view layer.

Grid uses `NSCollectionView` with `NSCollectionViewFlowLayout` rather than an `NSTableView` with one wide column (ADR-008): the flow layout gives per-cell selection, variable icon sizes, rubber-band selection and drop-on-item highlighting without custom hit testing.

### 8.2 Window, tabs, split

- `MainWindowController` (`NSWindowController`, `NSWindowDelegate`, `NSMenuItemValidation`, `NSToolbarItemValidation`, `NSToolbarDelegate`) owns `WindowStore`, the `OperationJournal`, `FocusCoordinator`, `SheetPresenter`, the toolbar and the `MainSplitViewController`.
- `MainSplitViewController` (`NSSplitViewController`) holds the sidebar item and the content item; the content item's view controller is `TabContainerController`.
- `TabContainerController` keeps one retained `ContentHostController` per tab in a dictionary keyed by `TabID` and swaps the active one as a child view controller. It calls `activate()` and `deactivate()` explicitly on switch rather than relying on `viewWillAppear` (B-013), and the `WindowStore` publishes the active tab so the toolbar, address bar, title and `representedURL` all follow it (B-020).
- `ContentHostController` hosts exactly one of `GridView` or `ListView`, the `StatusBarView`, the `QuickLookCoordinator`, the `DragDropCoordinator` and the `SelectionBinder`. It applies `TabState` and translates widget events into `TabAction`s.

### 8.3 Keyboard handling and command routing

Menus are built by MainMenuBuilder with nil targets for responder routing. MainWindowController remains the command responder after the window, as in today's cut/copy/paste wiring. It implements the @objc actions and NSMenuItemValidation, forwarding to CommandDispatcher, a plain @MainActor final class tested in HelmUITests. Text responders get first chance. Undo/redo are the MainSplitViewController exception described in 7.6. Do not insert an invented responder between window and content.

HelmUI declares `@objc public protocol AppLevelActions` with `newWindow(_:)`, `showPreferences(_:)`, `showAdvancedOptions(_:)`; AppDelegate adopts it. MainMenuBuilder uses `#selector(AppLevelActions.newWindow(_:))` and siblings, never names AppDelegate. `@MainActor public struct WindowDependencies` in HelmUI contains `settings: SettingsStore`, `stars: StarStore`, `bookmarks: BookmarkStore`, `recents: RecentStore`, `fileSystem: any FileSystem`, `search: any SearchService`, `executor: OperationExecutor`, `journal: OperationJournal`, with public init(settings:stars:bookmarks:recents:fileSystem:search:executor:journal:). AppEnvironment builds it and passes `MainWindowController.init(dependencies: WindowDependencies)`; the window controller never names AppEnvironment.

`WindowDependencies` also contains `clipboard: ClipboardState`, `directoryLoader: DirectoryLoader`, `monitors: MonitorRegistry`, `completions: CompletionProvider`, `listingCache: ListingCache`, `templates: TemplateProvider`, `volumes: VolumeReader`, `imaging: ImagingServices`, `trash: TrashCoordinator`, `operations: OperationCoordinator`; its public initializer takes these dependencies too.

One app-lifetime `@MainActor OperationCoordinator` outlives windows. Its public surface is `submit(_ command: Command, window: WindowID) -> OperationTicket`, `cancel(_:)`, `undo(window:)`, `redo(window:)`, and `events: AsyncStream<OperationEvent>`. It alone calls journal begin, executor run and journal complete. It keys journals by window and retains them while operations are pending. Ticket/event declarations and the conflicting journal initializer require a separate contract decision; no initializer choice is inferred here.

```swift
// HelmUI: action surface on MainWindowController; bodies forward to plain CommandDispatcher.
@MainActor public final class MainWindowController: NSWindowController, NSMenuItemValidation {
    public init(dependencies: WindowDependencies)
    public required init?(coder: NSCoder) { return nil }
    @objc public func goBack(_ sender: Any?)
    @objc public func goForward(_ sender: Any?)
    @objc public func goUp(_ sender: Any?)
    @objc public func goHome(_ sender: Any?)
    @objc public func editLocation(_ sender: Any?)
    @objc public func newTab(_ sender: Any?)
    @objc public func closeTab(_ sender: Any?)
    @objc public func newFolder(_ sender: Any?)
    @objc public func newFileFromTemplate(_ sender: Any?)
    @objc public func openSelection(_ sender: Any?)
    @objc public func renameSelection(_ sender: Any?)
    @objc public func moveSelectionToTrash(_ sender: Any?)
    @objc public func deleteSelectionPermanently(_ sender: Any?)
    @objc public func duplicateSelection(_ sender: Any?)
    @objc public func toggleStar(_ sender: Any?)
    @objc public func showProperties(_ sender: Any?)
    @objc public func toggleQuickLook(_ sender: Any?)
    @objc public func toggleHiddenFiles(_ sender: Any?)
    @objc public func refresh(_ sender: Any?)
    @objc public func switchToGrid(_ sender: Any?)
    @objc public func switchToList(_ sender: Any?)
    @objc public func helmToggleSidebar(_ sender: Any?)
    @objc public func focusSearch(_ sender: Any?)
    @objc public func clearRecent(_ sender: Any?)
    @objc public func emptyTrash(_ sender: Any?)
    @objc public func putBack(_ sender: Any?)
    public func validateMenuItem(_ item: NSMenuItem) -> Bool
}
```

Cut, Copy, Paste and Select All keep the `NSText` selectors so text views win; `MainWindowController` implements `cut(_:)`, `copy(_:)`, `paste(_:)` and `selectAll(_:)` for the file pane and validates them against `TabState` and the clipboard (00b 5.5 item 3). `validateMenuItem` sets `state` for Show Hidden Files and the view-mode items and enables Back and Forward from `history` (B-075). Rename on bare Return validates pane first responder, no modifiers and at least one selection: one starts inline rename; several open batch rename (F-055, B-118). Toolbar items validate through `validateToolbarItem(_:)`.

Return remains a validated menu equivalent, as today (main.swift:77–79). Space stays in the content widget's `keyDown`, as today (FileListViewController.swift:114–116): handled only with no modifiers, only when the widget is first responder and only when no TypeSelect run is active. Otherwise it goes to `super`. The Quick Look menu item has no live key equivalent. A bare Space equivalent is rejected: it would rely on unverified pass-through in every text field in every sheet.

Every pane command (moveSelectionToTrash, deleteSelectionPermanently, renameSelection, toggleStar, duplicateSelection, openSelection, toggleQuickLook, and pane cut, copy, paste and selectAll) validates through one function, `paneCommandsAllowed`. It returns true only when `window.attachedSheet == nil`, `NSApp.keyWindow === window`, and the window's first responder is inside the content host view, or is the window itself when no view holds focus. A first responder that is `NSText` always returns false. Because sheets replace `runModal` (§4.5), the responder chain can reach this controller while a sheet is key [Mac]. A Quick Look panel that is key is handled by its own delegate. `helmToggleSidebar(_:)` avoids NSSplitViewController.toggleSidebar interception. Pane Select All must update state/status even when native selection does not notify; test the delegate [Mac].

The collection view subclass handles type-select characters in keyDown; arrow keys retain native selection behavior. NSTableCellView.textField is always assigned for outline name cells (FileListView.swift:211), or provide typeSelectStringFor. AddressEditor handles Tab/Shift+Tab/Return/Esc/arrows in control(_:textView:doCommandBy:), returning false for other commands.

Binding fixture (HelmCore `CommandID: String, Sendable, Codable` enum has one case per action label below; `KeyBinding: Sendable, Equatable` stores command:CommandID, key:String, modifiers:Set<KeyModifier>, public init(command:key:modifiers:). `KeyModifier: String, Hashable, Sendable` has command/shift/option/control. AppKit adapters translate these values; no selectors in core). Preserve uppercase `H` and `N`, Return `"\r"`, Cmd Trash `"\u{8}"`, `Selector(("undo:"))`, `Selector(("redo:"))`, `#selector(NSText.cut(_:))` and siblings. Function keys use UI KeyEquivalent.string(for: Int) -> String, returning empty on invalid scalar.

| Action / CommandID | Binding | Target / selector |
|---|---|---|
| about / settings / advancedOptions | none / Cmd+, / none | NSApplication.orderFrontStandardAboutPanel(_:) / AppLevelActions.showPreferences/showAdvancedOptions |
| services | system | NSApplication.servicesMenu |
| hide / hideOthers / showAll / quit | Cmd+H / Option+Cmd+H / none / Cmd+Q | NSApplication standard actions |
| newWindow / newTab / newFolder | Cmd+N / Cmd+T / Shift+Cmd+N | AppLevelActions.newWindow; MainWindowController.newTab; MainWindowController.newFolder |
| find / closeTab | Cmd+F / Cmd+W | focusSearch / closeTab (last tab closes window) |
| undo / redo | Cmd+Z / Shift+Cmd+Z | undo: / redo:; 7.6 routing |
| cut / copy / paste / selectAll | Cmd+X / Cmd+C / Cmd+V / Cmd+A | NSText selectors, MainWindowController fallback |
| rename / trash / properties | Return / Cmd+Backspace / Cmd+I | renameSelection / moveSelectionToTrash / showProperties |
| grid / list / sidebar | Cmd+1 / Cmd+2 / Control+Cmd+S | switchToGrid / switchToList / helmToggleSidebar |
| hidden / refresh | Cmd+. / Cmd+R | toggleHiddenFiles / refresh |
| back / forward / up / home | Cmd+[ / Cmd+] / Cmd+Up / Shift+Cmd+H | goBack / goForward / goUp / goHome |
| location / star | Cmd+L / Cmd+D | editLocation / toggleStar |
| minimize / zoom / bringAllToFront / help | Cmd+M / none / none / empty menu | standard window/application actions |
| quickLook | Space in widget keyDown only; no menu key equivalent | toggleQuickLook, pane-only validation |
| address editor | Return/Esc/Tab/Shift+Tab/Up/Down/Right | control(_:textView:doCommandBy:) |
| batch rename sheet / properties sheet | Return or Esc / Esc | default or cancel / Done cancelAction |
| tab strip | middle click | otherMouseDown closes clicked tab |
| open (new) | Cmd+O, Cmd+Down | openSelection |
| permanentDelete / emptyTrash (new) | Option+Cmd+Backspace / Shift+Cmd+Backspace | deleteSelectionPermanently / emptyTrash |
| clearRecent / putBack / duplicate (new menu commands) | none | clearRecent / putBack / duplicateSelection |
| nextTab / previousTab (drafting per 04 Q3) | Shift+Cmd+] / Shift+Cmd+[ | nextTab / previousTab; proposed, owner decision pending; Mac acceptance pending |

Add a fixture test that every table row’s selector exists on its declared owner.

The fixture includes menu entries without shortcuts as well as editor/sheet gestures. Test it against 00 §2.7 and the deliberate additions above. No alias/eject/new-window-selection bindings are silently approved; proposed additions are in 14.5.

### 8.3.1 Context menus

ContextMenuBuilder preserves the exact baseline order from 00 §2.8: single item Open, Open With, separator, Cut/Copy/Paste, separator, Star/Remove from Starred, separator, Rename, Move to Trash, separator, Properties, Share; multiple items Open N Items, separator, Cut/Copy/Paste, separator, Rename N Items, Move to Trash, separator, Share; background Paste, separator, New Folder/New File, separator, directory Properties. Paste targets the pane's concrete mutation target and is validated through the command layer (auto-enabling must not override correctness). Sidebar bookmark Remove Bookmark and breadcrumb Copy Path remain. Expanded rows resolve by snapshot ID.

New Duplicate goes before Rename; Delete Permanently after Move to Trash; Put Back before Move to Trash in Trash; Empty Trash follows New File in Trash background; Clear Recent occupies the corresponding Recent background position. Open With adds Other… after the ten apps. Proposed Finder-scope commands, if approved, place Open in New Tab/Window after Open, Make Alias/Symbolic Link after Duplicate, Eject after device navigation. None changes the preserved multi-selection Star/Properties omission without an explicit scope decision.

### 8.4 Drag and drop

`DragDropCoordinator` implements the `NSCollectionViewDelegate` and `NSOutlineViewDataSource` drag methods. Sources write `NSURL` through `pasteboardWriterForItem`. Validation calls `DropPlanner` with the item under the pointer (resolved by ID), the `draggingSourceOperationMask`, DropModifiers populated from `NSEvent.modifierFlags`, and the volume IDs cached in the snapshot entries; it returns the `NSDragOperation` to display and never coerces the proposal to an insertion gap (B-074). Acceptance returns `true` after submitting a `Command` to the coordinator and shows failures through the operations panel. Drops onto a row inside an expanded subfolder resolve the row's parent through `PresentationSnapshot` (B-079). Sidebar drops remain bookmark-only.

### 8.5 Focus model

`FocusCoordinator` owns these transitions (B-102, B-108, B-112):

| Event | First responder becomes |
|---|---|
| Window shown, tab switched, view mode switched | active content widget |
| Navigation-initiated load finished | active widget only if first responder is nil, the window or previous widget; never steal from search/editor, search results or monitor reload |
| Cmd+L or segment edit click | the address editor field |
| Address editor commit/cancel/Esc | active widget |
| Outside click or intentional programmatic move | clicked/requested control retains focus; do not steal it back |
| Cmd+F | the search field; the address editor, if open, ends editing without navigating |
| Sheet dismissed | whatever was first responder before the sheet |

`initialFirstResponder` is the content widget; `nextKeyView` loop is sidebar → address editor (when present) → content widget → search field. New bindings added to the keyboard contract: Cmd+O and Cmd+Down open the selection; Option+Cmd+Backspace deletes permanently (with confirmation); Shift+Cmd+Backspace empties the Trash; Cmd+Shift+] and Cmd+Shift+[ switch tabs (in scope for drafting per 04 Q3; proposed, owner decision pending).

### 8.6 Sheets, Quick Look, accessibility

- `SheetPresenter` is the only way to show a sheet: it creates the `NSHostingController`, keeps a strong reference, presents with `presentAsSheet`, and dismisses through `dismiss(hostingController)` from the completion closure (B-117).
- `QuickLookCoordinator` makes `ContentHostController` accept panel control, serves selected IDs in display order from the snapshot, calls `reloadData()` on the panel when selection changes, forwards arrow keys through `previewPanel(_:handle:)`, and returns the item's cell frame for the zoom animation.
- Accessibility: tab buttons expose `accessibilityRole = .radioButton` within a `.radioGroup`, the address editor is labelled "Location" and its popup "Location suggestions", grid items are accessibility elements with the file name as label and "selected" state, the status bar is a static text, and an invalid path posts an `announcementRequested` notification with the error text (B-061).

---

## 9. Sandboxing, entitlements and Full Disk Access

When P-207 discovery ships, Info.plist includes `NSLocalNetworkUsageDescription` and `NSBonjourServices` with `_smb._tcp`, `_afpovertcp._tcp`, `_nfs._tcp`, `_webdav._tcp` [K, Mac]. Run `smbutil` only with an argument array and a validated host. Add a Mac test for denied local-network permission.

**Design (ADR-006): not sandboxed, hardened runtime; direct distribution proposed, signing choice pending owner.** A file manager that aims to replace Finder must browse any mounted volume, `~/Library`, other users' readable folders, `/Volumes/*/.Trashes` and arbitrary paths typed into the address bar. Under App Sandbox every one of those needs a user-granted security-scoped bookmark, which contradicts the typed-path interaction that defines Helm. App Store eligibility is therefore given up, which is acceptable for a single-user personal tool.

Consequences:

- `App/Helm.entitlements` stays an empty dictionary. No `com.apple.security.app-sandbox`, no `files.user-selected` entitlement.
- Bookmarks, stars and recents stay plain standardized paths. `BookmarkStore` keeps an optional `bookmarkData` field reserved for a future sandboxed variant; it is unused and `nil` in this build. The `AccessBroker` protocol in `HelmFileSystem` has one method, `access(_ url: URL) async -> AccessGrant`, with a trivial implementation; a sandboxed build would replace it.
- TCC still applies: Desktop, Documents, Downloads, removable and network volumes prompt through the usage strings already in Info.plist; `~/.Trash`, `~/Library/Mail`, Safari data and Time Machine backups require Full Disk Access.
- Permission-recovery UX: a load that fails with EPERM or EACCES produces `SnapshotPhase.failed(.permissionDenied, attempted: target)`. The content pane shows "Helm needs Full Disk Access to show this folder" with an "Open Privacy Settings" button that calls NSWorkspace.open using an optional URL from Support/URLLiterals.swift for `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`, guarded with if let (no force unwrap). A "Try Again" button navigates to the failed attempted location. The same state appears for the Trash location. The status bar shows "No access" instead of an item count. Such a load does not enter history, does not record Recent, and does not update the window's `representedURL`.
- Signing: draft default is `CODE_SIGN_STYLE: Manual` with `CODE_SIGN_IDENTITY: "-"`; an optional untracked `App/Local.xcconfig` lets the owner supply a team [K, Mac]. Ad-hoc rebuilds can lose signature-bound Full Disk Access grants; a free personal development identity may keep them stable [needs Mac check]. Developer ID needs paid membership, pending owner; no purchase/signing/distribution action is authorized by this draft.
- Development: `swift run` attributes TCC prompts to the terminal (00b C-27 inference); the README tells the owner to grant Full Disk Access to the built `Helm.app` and to test permission flows only with the bundled app.

---

## 10. Persistence and settings

### 10.1 Settings

One `SettingsSchema` in `HelmCore` declares every key with type, default, range and whether changing it applies live:

| Key | Type, default, range | Consumers (live) |
|---|---|---|
| `helm.defaultViewMode` | string, `grid` | new tabs |
| `helm.showHiddenFiles` | bool, false | new tabs; Cmd+. writes it |
| `helm.confirmBeforeTrash` | bool, false (pending Q10; honour explicit stored value) | trash command (live) |
| `helm.defaultSortField`, `helm.defaultSortAscending`, `helm.directoriesFirst` | string `name`, bool true, bool true | new tabs |
| `helm.singleClickToOpen` | bool, false | item activation (live), only if Q4 is yes |
| `helm.gridIconSize` | Double 96, 48 to 128 step 16 | grid layout (live) |
| `helm.liveMonitoringEnabled` | bool, true | monitor registry (live: stops or starts) |
| `helm.showAllMountedVolumes` | bool, false | volume filter (live) |
| `helm.enableDirectoryCache`, `helm.directoryCacheTTL` | bool true; double 1.5, 0.1 to 5.0 | listing cache (live; disabling clears) |
| `helm.maxCachedIcons`, `helm.maxCachedThumbnails` | int 800 floor 100; int 400 floor 50 | caches (live) |
| `helm.searchPreferUserFolders`, `helm.searchIncludeSystemLocations`, `helm.searchResultLimit`, `helm.searchDebounceMilliseconds` | bool true; bool false; int 300, 50 to 800; int 180, 40 to 500 | search (next query) |
| `helm.sidebarLiquidGlass` | bool, false | sidebar (live) |
| `helm.completionDebounceMilliseconds` | int 100, floor 30 | address bar (next request) |
| `helm.crossVolumeDragDefault` (new) | string `copy` | drop planner (live) |
| `helm.askOnConflict` (new) | bool, false | planner/conflict sheet; Settings toggle |
| `helm.restoreSessionOnLaunch` (new) | bool, true | launch sequence; off, session.json is deleted and not written |
| `helm.rememberRecentItems` (new) | bool, true | Recent and Open With (live); off, both are cleared and nothing new is kept |

`SettingsStore` (HelmPersistence, `@MainActor public final class`) registers defaults, exposes SettingsSnapshot and `public let changes: Broadcast<SettingsSnapshot>`, and is the only writer. Consumers observe the keys they need; nothing observes `UserDefaults.didChangeNotification` any more (B-058). The SwiftUI settings views bind to the HelmUI SettingsModel ObservableObject adapter, not to `@AppStorage`, so the two parallel systems become one (B-059). Existing keys are kept; run the cross-domain migration before defaults registration so registered values cannot mask absence; the `UserDefaults` suite is the app's standard domain for `com.helm.filemanager`.

### 10.2 JSON stores

User data moves out of `UserDefaults` into `~/Library/Application Support/Helm/` as versioned JSON documents written atomically:

| File | Content | Replaces |
|---|---|---|
| `stars.json` | `{schemaVersion, items: [{path, addedAt}]}` | `com.helm.starredFiles` |
| `bookmarks.json` | `{schemaVersion, items: [{path, name, addedAt, bookmarkData?}]}` | `helm.bookmarks` |
| `recent.json` | `{schemaVersion, items: [{path, lastAccessedAt, kind}]}` capped at 300; kept only while Settings › General › Remember recent items is on, and emptied when it's turned off | `helm.recentAccessRecords` |
| `trash-origins.json` | `{schemaVersion, items: [{trashedPath, originalPath, trashedAt}]}`; a record goes when its item leaves the Trash (Put Back, Empty Trash, Delete Immediately, or found gone at launch); at launch only the newest 1,000 are kept, and none goes for room while Helm runs, so Undo of a big Move to Trash still works | new |
| `session.json` | `{schemaVersion, items: [{frameAutosaveName, tabs: [{location, viewMode, sort, showHidden}], activeTabIndex}]}`; written only while Reopen windows and tabs is on, and deleted when it's off | new |
| `open-with.json` | `{schemaVersion, items: [{contentType, application, lastUsed}]}`; the apps used for each kind of file, cleared by Go › Clear Recent and by turning Remember recent items off | new |

```swift
public struct VersionedDocument<Payload: Codable & Sendable>: Codable, Sendable {
    public let schemaVersion: Int
    public let items: Payload
    public init(schemaVersion: Int, items: Payload)
}
public protocol MigrationStep: Sendable {
    var fromVersion: Int { get }
    func migrate(_ json: [String: Any]) throws -> [String: Any]
}
```

`LegacyDefaultsMigrator` runs before stores load or defaults register, guarded by `helm.migration.v1.done`. Read UserDefaults.standard and persistent domains `com.helm.filemanager` and `Helm`; the development domain is expected to be Helm but must be confirmed on the owner's Mac (00b M-34). Read explicit persistent values to distinguish stored settings from registered fallbacks. Never delete or rename legacy keys: rollback must still work.

Verified source formats: `com.helm.starredFiles` and `helm.bookmarks` are JSON Data encoding [URL]; `helm.recentAccessRecords` is JSON [{path,lastAccessedAt}] with JSONEncoder's default date strategy. Merge stars/bookmarks by standardized path; recents retain newest lastAccessedAt per path, then sort/cap at 300. Prefer explicit bundle settings; copy Helm-domain settings only when bundle values are absent. Migrate bookmarks without filtering missing/unmounted paths. Derive bookmark name using today's displayName rule (Home special case, otherwise last component), addedAt from migration time, directory kind; recent kind uses readable metadata if available, otherwise conservative `.other`, never discards an unavailable record. Existing new-format documents participate in the merge so retry after a partial write is idempotent; preserve their addedAt values.

Decode all sources before committing. A malformed source remains untouched, reports once, and leaves migration incomplete; do not replace it with an empty collection. Atomically write and verify each schemaVersion 1 file before setting the done flag. Failures keep the flag unset; reruns union with already-written data. LegacyDefaultsReading is a HelmPersistence protocol returning Data/settings values for injected domains; tests use literal fixture bytes (including dates/URLs), missing volumes, both domains, decode failure and interrupted writes. No real user defaults in tests.

All JSON documents have `{ "schemaVersion": 1, "items": ... }`; VersionedDocument.items is the payload key for every file (an array for each current store, including session windows). Each store is a plain `@MainActor public final class` with read-only state, `public let changes: Broadcast<...>`, and debounced 500 ms atomic writes delegated off main. SettingsModel, StarsModel, BookmarksModel and RecentsModel are HelmUI ObservableObject adapters. AppEnvironment shares one instance per store across windows. Disk state loads only at launch; cross-process sync remains out of scope.

The previously unread grid setting used a Double fallback of 64; absent an explicit stored value, 96 preserves the existing rendered size. The previously unread trash confirmation fallback was true; pending Q10, register false to preserve immediate undoable Trash, while honouring an explicit stored value.

LaunchSequence runs the migration step before defaults registration, using M4’s decoders. Copied real-domain fixtures round-trip on Mac. Migration remains non-destructive, keeps original keys and sets its completion marker last.

### 10.3 Session restoration

`LaunchSequence` first buffers open requests until migration/composition completes. Launch with an open request opens only the requested window and skips restore. Otherwise restore saved windows/tabs when helm.restoreSessionOnLaunch is true; otherwise open one window at Home. Implement only one of application(_:open:) and application(_:openFiles:), with reply(toOpenOrPrint:) on the latter. During restore, locations that no longer exist are replaced by Home with a status-bar note. Window frames continue to use AppKit autosave names, one per window index (`HelmMainWindow`, `HelmMainWindow-2`, ...). The session file is rewritten on tab or location change (debounced) and on quit.

---

## 11. Testing strategy

### 11.1 Layers

| Layer | Where it runs | What it covers |
|---|---|---|
| Unit, pure (XCTest) | Linux and Mac, `swift test` | reducers, history, snapshot building and diffing, sort comparators, path entry and completion engine, naming and batch rename planning, operation planner, undo planner, drop planner, clipboard state, search ranker and query builder, volume filter, places highlighting, status text, type-select, settings migration. |
| Unit, fake filesystem | Linux and Mac | `DirectoryLoader`, `ListingCache`, `OperationExecutor` and `OperationJournal` against `InMemoryFileSystem` with injected failures and latency; `EventCoalescer` with `FakeClock`; `RecentSource` and `TrashSource`. |
| Integration, temp directory | Mac (and Linux for the FileManager-only parts) | `LiveFileSystem` enumeration, exclusive create, copy, move, trash, symlink and alias handling in a `TempDirectory` fixture; `FSEventsMonitor` end-to-end with real writes; cross-volume move using a RAM disk created by the test with `hdiutil` (skipped when unavailable). |
| View adapter unit tests | Mac, `HelmUITests` | `ContentHostController.apply` maps snapshot to datasource counts and selection; `MenuValidation` states; `AddressBarController` state machine against the editor; `SheetPresenter` dismiss path. |
| Snapshot tests | Mac | Rendered `NSImage` of grid cells, list rows, breadcrumb and tab bar in light and dark appearance, compared against committed PNGs with a 1 % tolerance. |
| XCUITest | Mac, Xcode | the 19 runtime checks in 00b 3.4 turned into automated flows where possible (R-1, R-2, R-4, R-5, R-7, R-8, R-9, R-10, R-11, R-16, R-17, R-18), plus launch, tab lifecycle, address-bar contract and drag within a window. |
| Performance | Mac, `measure {}` | budgets in section 12. |

Test hygiene fixed from B-068: every test gets its own `UserDefaults(suiteName:)`, its own temp Application Support directory through an injected `StoreLocation`, and a `TempDirectory` that is removed in `tearDown` even on failure.

### 11.2 Compile-safety review process for blind authoring

Linux Swift 6.0.3 is installed and usable; activate with `source /workspace/toolchains/env.sh`. Compile/test Foundation modules as they land; review supplements real core compilation. AppKit authoring still needs Mac compilation. Each feature draft, regardless of author, receives the assigned strict review; platform compilation remains mandatory. is followed by a strict compile-correctness review using this checklist, and nothing merges without it.

**Actor isolation**
- Every class that touches AppKit or SwiftUI is declared `@MainActor`. Every `Task {}` inside such a class inherits main-actor isolation; do not call it `Task.detached` unless the body is pure.
- Calls from a `@MainActor` context into an `actor` are `await`ed; calls into a `@MainActor` method from an actor hop with `await MainActor.run { }` or a `@MainActor` closure.
- Protocol requirements implemented by `@MainActor` classes are either declared on a `@MainActor` protocol or marked `nonisolated` with a hop inside.
- Delegate and callback APIs that run on arbitrary queues (`QLThumbnailGenerator` completion, `NSWorkspace.open` completion, FSEvents callback, `NSMetadataQuery` notifications on non-main queues) are bridged with `Task { @MainActor in }` before touching UI.

**Sendable**
- Values crossing an actor boundary are `struct` or `enum` of Sendable members; no `NSImage`, `NSURL`, `NSMetadataItem`, `NSAttributedString`, closures without `@Sendable`.
- `AsyncStream` element types and their continuations are Sendable; do not box a continuation solely for sendability. Only the FSEvents callback context and locked CancellationFlag/exactly-once guard use documented unchecked conformance.
- No `static var` mutable state without `@MainActor` or an actor.

**Optionals and force operations**
- No `!` on optionals, no `try!`, no `as!`, no `fatalError`, no `URL(string:)!`. Pattern: `guard let x = ... else { return }`.
- Custom AppKit initializers include `required init?(coder: NSCoder) { return nil }`. Dequeue safely: `guard let item = view.makeItem(withIdentifier: id, for: path) as? GridItemCell else { return NSCollectionViewItem() }`.
- `URL(fileURLWithPath:)` for paths; `URL(string:)` only in `Support/URLLiterals.swift` returning `URL?`.
- Dictionary subscripts and `first` are optionals; arrays are indexed only after a bounds check or through `indices.contains`.

**AppKit signatures that are commonly wrong**
- `NSCollectionViewDataSource`: `collectionView(_:numberOfItemsInSection:)`, `collectionView(_:itemForRepresentedObjectAt:)`; items are registered with `register(_:forItemWithIdentifier:)` and dequeued with `makeItem(withIdentifier:for:)`.
- `NSOutlineViewDataSource`: `outlineView(_:numberOfChildrenOfItem:)`, `outlineView(_:child:ofItem:)`, `outlineView(_:isItemExpandable:)`; items are `AnyObject` (use `ListNode` class instances, never structs).
- `NSOutlineViewDelegate`: `outlineView(_:viewFor:item:)` returns `NSView?`; cells via `makeView(withIdentifier:owner:)`.
- `NSOutlineViewDataSource` drag: `outlineView(_:pasteboardWriterForItem:) -> (any NSPasteboardWriting)?`, `outlineView(_:validateDrop:proposedItem:proposedChildIndex:) -> NSDragOperation`, `outlineView(_:acceptDrop:item:childIndex:) -> Bool` (port FileListView.swift:318–343). Collection validate: `collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: any NSDraggingInfo, proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>, dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation` (FileGridView.swift:153–159).
- `NSMenuItemValidation.validateMenuItem(_:)` and `NSToolbarItemValidation.validateToolbarItem(_:)` are protocol methods; the class must declare conformance.
- `NSTextFieldDelegate.control(_:textView:doCommandBy:)` returns `Bool`; compare selectors with `#selector(NSResponder.insertTab(_:))`, `insertNewline`, `cancelOperation`, `moveUp`, `moveDown`, `moveRight`, `insertBacktab`.
- `QLPreviewPanelDataSource`: `numberOfPreviewItems(in:)`, `previewPanel(_:previewItemAt:)` returning `QLPreviewItem!`; wrap URLs in a class conforming to `QLPreviewItem`.
- `FileManager.trashItem(at:resultingItemURL:)` takes `AutoreleasingUnsafeMutablePointer<NSURL?>?`; declare `var result: NSURL?` and pass `&result`.
- `NSWorkspace.shared.open(_:withApplicationAt:configuration:completionHandler:)` is the non-deprecated form; `NSWorkspace.OpenConfiguration()`.
- Prefer NSSharingServicePicker.standardShareMenuItem for submenu; picker show(relativeTo:of:preferredEdge:) is fallback [Mac].
- `NSPasteboard.general.readObjects(forClasses:options:)` with `[.urlReadingFileURLsOnly: true]`.
- `NSAlert.beginSheetModal(for:completionHandler:)`, never `runModal()` from a task.
- `NSHostingController(rootView:)` requires the root view type to be concrete; `AnyView` is avoided.
- `presentAsSheet(_:)` and `dismiss(_:)` with the presented controller as the argument.

**Availability and deprecation**
- Deployment target macOS 14; do not use `@available(macOS 15, *)` APIs (no `NSSplitViewItem` inspector tricks, no new `NSCollectionView` APIs from 15).
- Avoid deprecated: `NSSharingService.sharingServices(forItems:)`, `NSWorkspace.open(_:withApplication:)`, `launchApplication`, `NSOpenPanel.runModal` from tasks, `URL.resourceValues` keys removed in 14 (none used), `NSUserDefaults.synchronize`.
- `Observation` framework, `@Observable`, `#Preview` macros: not used.
- Swift 5.10 syntax such as `nonisolated(unsafe)`: removed when porting old source, not copied. `if let x {}` shorthand is fine (Swift 5.7).

**Generics and closures**
- Explicit parameter and return types on every closure stored in a property or passed across modules: `{ (state: TabState) -> Void in ... }`.
- No single-expression implicit returns in closures longer than one line.
- No nested generic constraints beyond one `where` clause.

**Review mechanics**
- The reviewer reads every file top to bottom once for structure, then once per checklist section. Findings are fixed before the next file. The reviewer also cross-checks each public type against the signatures in this document and lists deviations.
- A CI script (runs on Linux) greps for forbidden tokens: `!` after an identifier at line end or before `.`, `try!`, `as!`, `fatalError(`, `runModal(`, `nonisolated(unsafe)`, `@Observable`, `import AppKit` outside `HelmUI` and `HelmApp`, `DispatchQueue.main.async` (use `MainActor.run`), `Thread.sleep`. Use token-aware checking for force unwrap before punctuation, including x!) and x!,; whitelist only documented QL signature IUOs.

### 11.3 Blind-build coding standard

1. Swift 5 language mode; tools version 5.9; no upcoming-feature flags.
2. No third-party dependencies. No binary targets.
3. No force unwraps, force tries, force casts, implicitly unwrapped optionals except the exact QL overrides ported from FileListViewController.swift, including QLPreviewPanel! and (any QLPreviewItem)!. No nibs or IBOutlet exception.
4. Explicit types on closure parameters and returns, on empty collection literals, on numeric literals assigned to properties (`let latency: TimeInterval = 0.3`).
5. One type per file, file named after the type. Extensions in `TypeName+Topic.swift`.
6. Every `final class` unless designed for subclassing (only `NSView`, `NSViewController`, `NSResponder`, `NSWindowController` subclasses are open to AppKit).
7. `@MainActor` on every UI class and every store; `actor` for services holding mutable state; `struct` for everything else.
8. Protocols for every AppKit seam that core modules need to reason about: `FileSystem`, `DirectoryMonitor`, `SearchService`, `LocationSource`, `HelmClock`, `ImageRequesting`. Core modules never name an AppKit type.
9. No result builders outside SwiftUI `body` properties; SwiftUI views stay under 80 lines and use plain `VStack`, `HStack`, `List`, `Form`, `Text`, `Button`, `Toggle`, `Picker`, `TextField`, `Slider`, `Stepper`; no custom `ViewModifier` generics, no `PreferenceKey`, no `GeometryReader`; GhostOverlay is AppKit.
10. No `DispatchQueue.main.async`; use `Task { @MainActor in }` or `MainActor.run`. No DispatchSemaphore, including IOExecutor.
11. Every `Task` created in a class is stored, cancelled on replacement and cancelled in explicit `teardown()`; `deinit` follows §4.5.
12. Every async result applied to state passes through a generation check.
13. Errors are typed enums conforming to `Error` and `Sendable`; `localizedDescription` is provided through `LocalizedError`.
14. Strings shown to the user live in `UserStrings.swift` per module as `static let` constants (no localization tables yet, but one place to add them).
15. Magic numbers from the preservation map live in `Metrics.swift` (`HelmUI`) and `Limits.swift` (`HelmCore`) as named constants with a comment citing the F-ID.
16. Public API of core modules is documented with one-line `///` comments stating thread-safety and the F or B IDs it serves.
17. Tests for every pure function land with the function (orchestrator owns commits).
18. Every public struct has explicit public initializers; implicit memberwise initializers are internal. Custom ==, hash(into:) and Comparable operators are public. Never name a new public type after an SDK type (ItemSort, HelmClock, GridItemCell avoid known collisions).
19. Port FSEvents, Quick Look, drag/drop, thumbnail and menu call sites from the old tree. `Helm/` stays until GM passes and the owner approves its removal, because blind authors and the handoff need it as the behaviour reference.
20. Never read store.state inside a sink; use its parameter and the non-reentrant FIFO (4.3).
21. Never capture self in a task created in deinit; explicit teardown owns isolated cleanup (4.5).
22. Every #selector(X.y(_:)) resolves to an @objc action/protocol requirement y on X (or an SDK-declared selector).
23. Responder overrides such as selectAll/cancelOperation from optional protocols are a Mac SDK uncertainty; confirm once per superclass at handoff, rather than guessing throughout the tree.
24. Name NSTableCellView.textField is set for native type-select; grid subclasses NSCollectionView for keyDown.
25. Use URL(fileURLWithPath:) and appendingPathComponent; avoid URL(filePath:) and appending(path:) for common source compatibility.
26. Directory enumerators are consumed only in synchronous IOExecutor closures, with cancellation flags and AutoreleaseScope.
27. Build order: core modules, HelmUI leaf views, windows, HelmApp. Merge a declaring file before any file referring to it.
28. The owner's Xcode compiler may differ from Linux 6.0.3; keep Swift 5 language mode/tools 5.9 and do not rely on a specific compiler's diagnostics.

---

Additional compile-safety rules from Opus Fixes 34–35:

- All modules ban `Synchronization.Mutex`, regex literals and `Regex` builders, parameter packs, macros, `consume`, `@Observable`, `#Preview`, `runModal` from tasks, and deprecated sharing and launch APIs. Core modules also ban `OSAllocatedUnfairLock`, `.formatted()`, `String(localized:)`, `URL(filePath:)`, and `FileManager.enumerator` iteration inside async contexts. Check with Linux grep and explicit allowlisted exceptions.
- No-nib view controllers call `super.init(nibName: nil, bundle: nil)` and implement `loadView()`.
- Window controllers call `super.init(window:)`.
- Every file using Combine imports it explicitly.
- Every public struct has an explicit public init.
- The HelmUI public surface used by HelmApp is listed in planned `docs/handoff/public-surface.txt`, and a script diffs it against declarations. Neither artifact is created by this docs lane.

### 11.4 Linux availability and observed checks

On 2026-11-04, `swiftc --version` reported Swift 6.0.3, x86_64-unknown-linux-gnu after sourcing the supplied environment. Stdin `swiftc -swift-version 5 -typecheck -` checks succeeded for Foundation URL/Date Sendable values, ByteCountFormatter, localizedStandardCompare, Date.FormatStyle and explicit `as NSString`. They rejected NSPredicate(format:), URLResourceKey.contentTypeKey, DispatchSource.makeMemoryPressureSource and autoreleasepool. This is a signature probe, not a build of the future modules. No SDK/network installation was attempted.

Additional local verification: extracted the 59 Core declarations, supplied non-executing bodies only for declaration-only methods/initializers/getters in memory, and typechecked them with Foundation alone in Swift 5 mode. This resolves their types and synthesized conformances without downstream declarations. A second probe typechecked the Foundation service/operation/persistence shapes with the minimum table types supplied, and the conditional Package.swift sketch typechecked against PackageDescription 5.9 on Linux. These probes do not execute code or validate module implementations. Mechanical checks counted 72 unique F-IDs (13 Keep, 45 Keep+fix, 12 Redesign, 2 Drop), all 65 fix-log rows, and an acyclic import DAG.

| API | Linux status / rule |
|---|---|
| NSPredicate(format:) | Observed unavailable; query builder returns strings/arguments; Mac-only service creates predicate |
| NSMetadataQuery / CoreServices / UTType | Guard in designated platform services; require Mac build for live paths |
| memory-pressure / file-system-object DispatchSource | memory pressure observed absent; both stay Mac-only, Linux polling fallback |
| FileManager.trashItem / AutoreleasingUnsafeMutablePointer / URL.bookmarkData | Mac-only live paths; Linux fakes report unsupported or emulate explicitly |
| URLResourceValues.contentType / capacity-for-important-usage | Mac guards; contentTypeKey absence observed |
| autoreleasepool | Observed absent; AutoreleaseScope conditionally uses ObjectiveC |
| Combine / ObservableObject | HelmUI only; never in Foundation core even behind a guard |
| @objc / #selector / dynamic NSObject | No core usage |
| NSString / NSURL bridging | Review's blanket prohibition rejected: explicit `as NSString` works on this toolchain; prefer URL APIs and NSString(string:) for portable spelling; no implicit bridge assumption |
| Date.FormatStyle | Available on installed 6.0.3; review's 5.9-corelibs historical claim does not describe this host; DateFormatter remains conservative baseline |
| localizedStandardCompare / ByteCountFormatter | Observed typecheck success; locale/output can differ, avoid exotic exact-output tests |

Run `swift build --target HelmCore` (then each core target) and `swift test --filter HelmCoreTests` etc at the verified repository root with a lane-specific scratch path. See the current as-built record for target readiness; this docs pass does not claim compilation. Linux compiler availability supersedes the review's /usr/bin-only discovery, but toolchain installation/change approval remains open (14.5); default is use the already installed toolchain without changing it.

### 11.5 Required regression fixtures

In addition to 11.1: delayed Tab/Tab/Tab completion; pre-commit failed navigation and Back/Forward Recent recording; equal-content fresh snapshot IDs; reentrant send from a sink; case-only rename/normalization; replacement failure retaining old content; cancellation/timeout exactly-once continuation; per-subscriber monitor fan-out and expanded-scope changes; partial cut retry/changeCount; journal survival after tab/window close; migration of both domains, unavailable bookmarks, decode errors and interrupted writes. Mac checks include all R-1–R-19, undo/text routing, disabled key-equivalent pass-through, grouped toolbar validation, proxy icon, sidebar arrows/re-click, modifier mask, realpath events, iCloud/File Provider placeholders and TCC grants.

### 11.6 Scripted static checks (implementation gate)

Planned M0 deliverable (not created by this docs pass): add `scripts/rebuild/stubsdk/` with minimal AppKit, SwiftUI, Combine and QuickLook declarations, grown from legacy call sites and reviewed, not invented from memory where a legacy site exists. The gate runs `swiftc -typecheck -swift-version 5` on HelmUI and HelmApp against these stubs. A pass means own-type, access, import and actor checks succeeded, and proves nothing about the real SDK. Any stub mismatch found on the Mac is recorded as a stub bug.

Planned M0 deliverable (not created by this docs pass): add `scripts/rebuild/check_api_oracle.py` (standard library only). It extracts AppKit, SwiftUI, Foundation and QuickLook member names used in `Helm/Helm/**` into an allowlist, then reports members used in `Sources/HelmUI` and `Sources/HelmApp` that aren't on it. Reported items need a reviewer note citing an SDK source or a [Mac] label. Matching is by name only, so it gives warnings rather than a pass or fail on correctness.

The implementation gate uses `bash scripts/static_checks.sh` and `python3 scripts/rebuild/check_coverage.py --parity <02> --current-state <00>`. Extend the real scripts with selector, import DAG, plist and YAML checks, each with a fixture that must fail. These script changes belong to M0, not this docs lane. The following Python blocks are illustrative; the tree-sitter/YAML companion is optional and reports NOT RUN if dependencies are unavailable, never a gate pass. They are embedded here because this lane may edit only this document; no script file was created. Run from the new repository root. Regex symbol checks are candidate diagnostics: parse nested scopes/typealiases and approve SDK identifiers explicitly rather than treating capitalized names in comments as types. They supplement swift build; they cannot prove actor isolation.

```python
from pathlib import Path
import re, subprocess, plistlib
root = Path("Sources")
allowed = {
    "HelmCore": {"Foundation"},
    "HelmFileSystem": {"Foundation", "HelmCore", "Dispatch", "Darwin", "Glibc", "CoreServices", "UniformTypeIdentifiers"},
    "HelmPersistence": {"Foundation", "HelmCore"},
    "HelmOperations": {"Foundation", "HelmCore", "HelmFileSystem"},
    "HelmSearch": {"Foundation", "HelmCore", "HelmFileSystem"},
    "HelmTestKit": {"Foundation", "XCTest", "HelmCore", "HelmFileSystem"},
}
files = {p: p.read_text() for p in root.rglob("*.swift")}
assert files, "No implementation to check"
symbols = {}
for p, text in files.items():
    module = p.relative_to(root).parts[0]
    symbols.setdefault(module, set()).update(re.findall(r"\b(?:struct|class|enum|protocol|actor|typealias)\s+(\w+)", text))
for p, text in files.items():
    module = p.relative_to(root).parts[0]
    imports = set(re.findall(r"^import (\w+)", text, re.M))
    if module in allowed:
        assert imports <= allowed[module], (p, imports - allowed[module])
    banned = [r"try!", r"as!", r"fatalError\(", r"nonisolated\(unsafe\)",
              r"canImport\(Foundation\.", r"URL\(filePath:", r"appending\(path:",
              r"DispatchSemaphore", r"Thread\.sleep", r"DispatchQueue\.main\.async"]
    if module in allowed and module != "HelmTestKit":
        banned += [r"\bCombine\b", r"\bObservableObject\b", r"@objc", r"#selector"]
    for pattern in banned:
        assert not re.search(pattern, text), (p, pattern)
    for match in re.finditer(r"[\w)\]]!(?=\s*[).,;\]}]|\s*$)", text, re.M):
        print("force-unwrap candidate (allow only exact QL signature):", p, match.group())
    for name in symbols[module] & {"SortDescriptor", "Clock", "GridItem"}:
        raise AssertionError((p, "SDK name collision", name))
for name in ("Info.plist", "Helm.entitlements"):
    with (Path("App") / name).open("rb") as f:
        plistlib.load(f)
# Optional companion below: missing parser dependencies report NOT RUN.
```

The optional companion uses tree-sitter for syntax, then conservative lexical checks for ownership, initializers, selectors, actor calls and drift. Findings fail the gate and require a reviewed correction/allowlist entry; they are not definitive Swift diagnostics. All allowlists below are checker inputs, not inferred permission to ignore findings. No tool installation is performed by the checker.

```python
import sys
try:
    import yaml
    import tree_sitter_swift
    from tree_sitter import Language, Parser
except ImportError as error:
    raise SystemExit(f"NOT RUN: optional tree-sitter/YAML checks unavailable: {error}")
parser = Parser(Language(tree_sitter_swift.language()))
errors = []
def report(path, message):
    errors.append(f"{path}: {message}")
def scrub(text):
    # Preserve newline offsets while ignoring ordinary comments/string contents.
    return re.sub(r'"(?:\\.|[^"\\])*"|//[^\n]*|/\*.*?\*/',
                  lambda m: "\n" * m.group().count("\n") + " ", text, flags=re.S)
def extent(text, opening):
    depth = 1
    for i in range(opening + 1, len(text)):
        depth += (text[i] == "{") - (text[i] == "}")
        if depth == 0:
            return i
    return len(text)
def direct_body(text):
    depth = 0
    out = []
    for c in text:
        if c == "}": depth -= 1
        out.append(c if depth == 0 else "\n" if c == "\n" else " ")
        if c == "{": depth += 1
    return "".join(out)
sdk = set("""String Bool Int Int64 UInt UInt64 UUID URL Date Data TimeInterval Error
Result Set Array Dictionary Optional Never Void Any AnyObject Self T Value Payload
Hashable Equatable Codable Sendable Comparable Identifiable OptionSet LocalizedError
AsyncStream AsyncThrowingStream Task MainActor CGFloat CGSize CGRect NSImage NSView
NSWindow NSWindowController NSResponder NSMenuItem NSMenuItemValidation NSCoder
NSCollectionViewItem NSCollectionView NSToolbarItem NSToolbarItemValidation
NSPasteboardWriting NSDraggingInfo NSDragOperation NSIndexPath UnsafeMutablePointer
AutoreleasingUnsafeMutablePointer QLPreviewItem QLPreviewPanel Foundation Dispatch
NSObject NSApplication NSText NSTextView NSEvent NSButton NSWorkspace NSOutlineView
NSViewController NSSplitViewController NSWindowDelegate NSToolbarDelegate
NSCollectionViewDelegate NSCollectionViewDataSource NSOutlineViewDelegate
NSOutlineViewDataSource NSTextFieldDelegate NSCollectionViewLayout
ObservableObject Published SwiftUI AppKit Combine XCTest XCTestCase""".split())
# Checked SDK selector owners: all custom owners still require a matching declaration.
sdk_selector_owners = {"NSText", "NSResponder", "NSApplication", "NSWindow"}
clean = {p: scrub(text) for p, text in files.items()}
actors = set()
for text in clean.values():
    actors |= set(re.findall(r"\bactor\s+(\w+)", text))
for p, text in files.items():
    tree = parser.parse(text.encode())
    if tree.root_node.has_error: report(p, "Swift syntax ERROR or missing node")
    c = clean[p]
    module = p.relative_to(root).parts[0]
    for m in re.finditer(r"public\s+struct\s+(\w+)[^{]*\{", c):
        end = extent(c, m.end() - 1)
        body = direct_body(c[m.end():end])
        if not re.search(r"public\s+init[?]?\s*\(", body):
            report(p, f"public struct {m[1]} lacks explicit public init")
    # All own-module/nested declarations resolve; exported SDK/generic identifiers
    # must be explicitly in the allowlist or declared on the public generic signature.
    dependencies = allowed.get(module, set())
    if module in {"HelmUI", "HelmApp"}:
        dependencies = set(symbols) - {"Helm", "HelmApp", "HelmTestKit"}
    own = symbols.get(module, set()) | set().union(*(symbols.get(d, set()) for d in dependencies))
    for line in c.splitlines():
        if "public " not in line: continue
        unknown = set(re.findall(r"\b[A-Z][A-Za-z0-9_]*\b", line)) - own - sdk
        if unknown: report(p, f"resolve public-signature identifiers: {sorted(unknown)}")
    for owner, method in re.findall(r"#selector\((\w+)\.(\w+)\(", text):
        if owner in sdk_selector_owners: continue
        owners = [t for q, t in files.items() if owner in symbols.get(q.relative_to(root).parts[0], set())
                  and re.search(r"\b(?:class|protocol|extension)\s+" + re.escape(owner) + r"\b", t)]
        if not any(re.search(r"(?:@objc\s+(?:public\s+)?)?func\s+" + re.escape(method) + r"\s*\(", t) for t in owners):
            report(p, f"missing selector {owner}.{method}; verify @objc exposure/inheritance")
    # Conservative await candidates: receiver declarations with known actor types.
    receivers = re.findall(r"\b(?:let|var)\s+(\w+):\s*(\w+)", c)
    for receiver, actor in receivers:
        if actor not in actors: continue
        for line in c.splitlines():
            if re.search(r"\b" + re.escape(receiver) + r"\.\w+\(", line) and "await " not in line:
                report(p, f"verify await/isolation or nonisolated witness: {line.strip()}")
    # Track lexical guards; conditional API allowance is never a module-edge exception.
    guards = []
    for line in c.splitlines():
        stripped = line.strip()
        if stripped.startswith("#if "): guards.append(stripped)
        elif stripped.startswith(("#else", "#elseif")):
            if guards: guards[-1] = stripped
        elif stripped.startswith("#endif"):
            if guards: guards.pop()
        if module in allowed and re.search(r"\b(?:UTType|NSMetadataQuery|CoreServices)\b|\.contentTypeKey|makeMemoryPressureSource|makeFileSystemObjectSource", line):
            if not any("os(macOS)" in g for g in guards): report(p, "macOS API outside os(macOS) guard")
# Doc-to-code drift: compare declared member labels, not implementation bodies.
doc = Path("docs/rebuild/01-architecture.md").read_text()
def contracts(text):
    found = {}
    for m in re.finditer(r"public\s+(?:final\s+)?(?:struct|enum|class|actor|protocol)\s+(\w+)[^{]*\{", text):
        body = text[m.end():extent(text, m.end() - 1)]
        labels = set(re.findall(r"public\s+(?:(?:static|mutating|required)\s+)*(?:func\s+(\w+)|(?:let|var)\s+(\w+))", body))
        found.setdefault(m[1], set()).update(a or b for a,b in labels)
    return found
doc_contracts = contracts("\n".join(re.findall(r"```swift\n(.*?)\n```", doc, re.S)))
code_contracts = contracts("\n".join(clean.values()))
for name, members in doc_contracts.items():
    if name not in code_contracts: report(name, "documented declaration missing in implementation")
    elif members - code_contracts[name]: report(name, f"documented members missing: {sorted(members - code_contracts[name])}")
# Coverage fixtures must cite F-IDs; Mac/deferred/drop records must state their disposition.
coverage = "\n".join(p.read_text() for base in (Path("Tests"), Path("UITests"))
                     for p in base.rglob("*") if p.suffix in {".swift", ".md"})
for fid in {f"F-{i:03d}" for i in range(1,73)}:
    if fid not in coverage: report(fid, "missing test or explicit Mac/deferred/drop coverage record")
config = yaml.safe_load(Path("App/project.yml").read_text())
for name, target in config.get("targets", {}).items():
    if "info" in target or "entitlements" in target: report(name, "XcodeGen generator block would overwrite files")
    for source in target.get("sources", []):
        path = source.get("path") if isinstance(source, dict) else source
        if path and not Path(path).exists(): report(name, f"missing source path {path}")
if not config.get("schemes"): report("project.yml", "explicit package-test scheme entries required")
for target in ("HelmCoreTests", "HelmFileSystemTests", "HelmOperationsTests", "HelmSearchTests", "HelmPersistenceTests", "HelmUITests"):
    if target not in repr(config.get("schemes", {})): report(target, "not in explicit Xcode test scheme")
if errors:
    print("\n".join(errors))
    sys.exit(1)
print("Static gate passed; Swift build/tests and Mac handoff remain required")
```

This deliberately flags unresolved generic/nested SDK names, nonisolated actor calls and inherited selectors for review; keep reviewed allowlists narrow. Multiline signatures and conditional compilation still require the public-signature comparison and actual Swift compiler described below. The checks do not substitute for typechecking or imply a successful gate before implementation exists.

| Companion check | Required algorithm / failure condition |
|---|---|
| Public signature symbol table | Strip comments/strings, collect module and nested declarations/typealiases/generics; resolve public parameter/property/return/conformance identifiers through allowed imports and a checked SDK allowlist; fail unresolved identifiers and forbidden cross-module ownership |
| Public init | Parse each public struct body separately; require a public initializer for each constructible cross-module value; do not count a nested struct's initializer |
| Selector audit | Parse #selector owner/member, compare against @objc methods/protocol requirements/inherited SDK allowlist; report missing actions |
| Await lint | Resolve known actor receivers/caller isolation and flag cross-isolation calls without await for review; compiler is authoritative |
| Platform guard check | Track conditional regions; require os(macOS) around UTType/macOS resource keys/metadata query/FSEvents/dispatch live APIs; ObjectiveC guard only for AutoreleaseScope |
| Doc-to-code drift | Extract the Swift fences and 4.6 ownership table; normalize signatures, compare code public interfaces; explicit reviewed deviation required |
| F coverage | Parse all F-001…F-072 rows; require each to map to test names or a documented Mac/deferred test, rather than just counting rows |
| Config validity | Python plistlib plus an optional YAML parser (NOT RUN when absent); assert App/project.yml has no info/entitlements generation blocks, paths resolve and package tests have explicit scheme entries |
| Syntax | Optional: parse each Swift file with installed tree-sitter-swift (NOT RUN when absent); fail on ERROR/missing nodes; swiftc -parse can additionally run, but neither validates Mac SDK types |

No dependencies are installed in this revision; missing static-check tools are reported, not silently treated as passing. Linux toolchain changes and any macOS CI runner require owner approval. macOS CI is recommended but default remains no provisioning/spend; no copying a macOS SDK to Linux.

---

## 12. Performance budgets

| Scenario | Budget | Verified by |
|---|---|---|
| Navigate to a cached directory with 1,000 items | first frame under 50 ms | `measure` in `HelmUITests` with a fixture snapshot |
| Enumerate 100,000 items on local APFS | first batch visible under 200 ms; complete under 3 s; sort under 400 ms | integration test on a generated temp tree, timed with `ContinuousClock` |
| Select All on 100,000 items (grid or list) | under 100 ms to update model and widget | `HelmUITests` with a synthetic snapshot |
| External change to one file in a 100,000-item folder | target new snapshot under 50 ms after coalescing; one reload, visible-cell work; snapshot/index/layout costs measured on Mac | `DirectoryLoader` unit test on the fake with timing |
| Address bar: typing a character in a directory of 10,000 entries | rows under 100 ms on the I/O queue; zero main-thread disk calls | unit test on the fake plus a debug assertion inside the synchronous IOExecutor closure that it is not on the main queue |
| Slash browse of a network directory that takes 2 s to list | UI stays responsive; popup shows a spinner row; result or cancel within the generation | integration test with a fake latency of 2 s |
| Copy 10,000 small files (1 GB total) same volume | progress updates at least every 250 ms; cancellation reacts within 500 ms; throughput within 20 % of `cp -R` | integration test on a temp tree (budget check is informational on CI, enforced manually at handoff) |
| Undo of a 1,000-item move | completes under 2 s; one journal entry; selection restored | `OperationJournal` test on the fake |
| Spotlight search typing | debounce 180 ms; first results within 500 ms of query settle on an indexed volume; ranking of 900 candidates under 30 ms | ranker benchmark on Linux; end-to-end timed manually at handoff |
| Memory with 10 tabs on 20,000-item folders | under 150 MB resident beyond baseline | measured at handoff with `footprint`; `ListingCache` entry cap of 200,000 is the enforced proxy |
| App launch to first window interactive | under 400 ms with session restore of 5 tabs | XCUITest launch measurement |
| Main-thread I/O | zero application-owned `open`, `stat`, `readdir` on main outside startup; measure opaque AppKit icon/query costs separately | debug build asserts `dispatchPrecondition(condition: .notOnQueue(.main))` inside each synchronous IOExecutor closure, not actor entry; UI uses MainActor.assertIsolated or .onQueue(.main); XCUITest run with the check enabled |

Where a budget cannot be measured on Linux the handoff prompt includes the measurement step, and the number is a target, not a gate.

---

## 13. Decision records

### ADR-001: SwiftPM package of modules, not a single app target
Context: the current project has one target and three conflicting build descriptions. Pure logic cannot be tested without a Mac. Options: single Xcode target; single SwiftPM executable; package of library modules plus a thin app. Decision: package of nine targets with a one-file app target consuming it. Consequences: strict import boundaries enforced by the compiler; five modules test on Linux; XcodeGen describes only the bundle; slightly more boilerplate in `Package.swift`.

### ADR-002: AppKit for the content pane and chrome, SwiftUI for small islands
Context: 100k-item folders, keyboard-first interaction, drag and drop, inline rename, Quick Look. Options: all SwiftUI; all AppKit; hybrid. Decision: hybrid, AppKit for everything performance- or focus-sensitive, SwiftUI for sidebar list, sheets, settings, operations panel. Consequences: more code for the pane; full control of first responder and virtualization; SwiftUI islands stay tiny and compile-safe.

### ADR-003: Combine `ObservableObject` for state publication
Context: AppKit controllers and SwiftUI islands must observe the same stores; authoring is blind. Options: Observation framework with `@Observable`; Combine; hand-rolled closures. Decision: HelmUI uses Combine with @Published and removeDuplicates, with FIFO sends and sink-parameter-only reads. Foundation persistence publishes through Broadcast and UI adapters. Consequences: no macro expansion risk; well-known `sink` and `store(in:)` patterns; SwiftUI `@ObservedObject` works directly; slightly more manual diffing in controllers.

### ADR-004: FSEvents primary, dispatch source and polling fallback
Context: the current monitor is recursive, leaky and silent on failure. Options: FSEvents only; kqueue or `DispatchSource` per directory; polling. Decision: FSEvents with `WatchRoot`, filtered to direct children, shared per path, with `DispatchSource` and polling fallbacks. Consequences: accurate changed paths for incremental diffs; two extra small implementations; the registry is an actor with refcounts.

### ADR-005: Actors plus a dedicated I/O queue, not GCD-first
Context: blocking FileManager calls inside actors pin the cooperative pool. Options: GCD queues everywhere with completion handlers; actors doing blocking I/O; actors that delegate blocking I/O to an `OperationQueue`. Decision: actors own state; blocking calls run on per-volume OperationQueues (local width 4, network width 1, timeout quarantine) bridged by checked continuations. Consequences: async API throughout; cancellation checked between steps; bounded blocking lanes; OS calls may remain hung but later calls fail fast; unchecked context/flag boxes documented.

### ADR-006: Not sandboxed, hardened runtime, direct distribution
See section 9. Consequences: no App Store; plain-path persistence; Full Disk Access guidance UI; `AccessBroker` seam for a future sandboxed build.

### ADR-007: Rebuild in place on a new branch of the same repository
Context: keep history, docs, issues and the owner's workflow. Options: new repo; new branch replacing the tree; incremental refactor. Decision: branch `rebuild` (proposed, owner decision pending under 04 Q6) from `main`; new tree under `Sources/`, `App/`, `Tests/`; `Helm/` stays until GM passes and the owner approves its removal, because blind authors and the handoff need it as the behaviour reference. Consequences: one repo, one README; the rebuild branch is merged to `main` only after the handoff build passes the XCUITest suite; no incremental refactor because the audit shows the state model must change everywhere at once.

### ADR-008: NSCollectionView for the grid, NSOutlineView for the list
Context: grid needs rubber-band selection, variable icon sizes, drop-on-item; list needs expandable folders and columns. Options: `NSTableView` with a custom cell for the grid; `NSCollectionView`; one `NSOutlineView` for both. Decision: `NSCollectionView` flow layout for the grid, `NSOutlineView` for the list, both fed by the same snapshot. Consequences: two datasource adapters; shared `SelectionBinder` and `DragDropCoordinator`; a column-view adapter can be added later against the same snapshot.

### ADR-009: File-operation journal stacks with responder routing
Context: undo today uses closures over strings, has no redo and can permanently delete. Decision: OperationJournal owns pending/final entries and undo/redo stacks; MainSplitViewController routes pane undo before the window, while text uses its own UndoManager. No file-operation UndoManager bridge. Consequences: Linux-testable inverses and redo, exact per-item URLs, always-trash copy/create undo with changed-token warnings, lifetime independent of tabs, tracked operations and Mac routing validation.

### ADR-010: No third-party dependencies
Context: blind authoring, compile safety, a single owner. Decision: none. Consequences: own small JSON stores, own snapshot assertions, own diffing; nothing to pin or audit.

### ADR-011: Swift 5 language mode, tools 5.9, macOS 14 APIs only
Context: `SWIFT_VERSION 5.9` is invalid; Swift 6 mode would turn every concurrency warning into an error on an uncompiled codebase. Decision: `swiftLanguageVersions: [.v5]`, `SWIFT_VERSION "5"`, strict concurrency at `targeted` as warnings. Consequences: the handoff session sees concurrency diagnostics without being blocked; a later switch to Swift 6 mode is a follow-up once the warnings are at zero.

### ADR-012: Identity is the standardized path, with change tokens for content
Context: `fileResourceIdentifier` is opaque, not Sendable-friendly and awkward to persist. Decision: `ItemID` wraps the standardized path; `ChangeToken` (modification date plus size plus optional child count) detects content change; renames produce new IDs mapped by the journal. Consequences: simple, Codable, testable; a rename briefly loses selection unless the journal maps it, which it does for Helm-initiated renames.

---

## 14. Risks and open items

### 14.1 Product questions that change the build

| # | Question | Default assumed in this document |
|---|---|---|
| Q1 | Breadcrumb segments: should a single click navigate to the ancestor (README) or enter edit mode (last two commits)? | Keep current click-to-edit until answered; ancestor navigation would restore the README promise but reverse the last deliberate source change. Needs owner before changing BreadcrumbView behavior. |
| Q2 | New Folder: immediate creation, name prompt, or inline rename? | Immediate creation followed by inline rename (F-056). |
| Q3 | Folder Tree sidebar: still wanted? | Not built; `SidebarMode` seam kept (F-033). |
| Q4 | Single-click to open: real requirement? | Setting removed unless answered yes. |
| Q5 | Cross-volume drags: Finder parity (copy) or always move? | Copy across volumes, move within; Cmd forces move; `helm.crossVolumeDragDefault` exposes it (F-067). |
| Q6 | Keyboard tab switching and tab reordering: in scope now? | In scope for drafting per 04 Q3; custom tabs retained; Mac acceptance pending. |
| Q7 | Stars: keep Helm-private or map to Finder tags? | Helm-private JSON; a tag-backed `StarStore` could replace it behind the same protocol. |
| Q8 | Search: frequency learning from the Recent log? | Not in this rebuild; ranker takes an optional `usageBoost: [URL: Int]` input that is empty. |
| Q10 | Confirm every Move to Trash (previous unread default true, B-048)? | Needs owner: register false, preserve immediate undoable Cmd+Backspace; honour an explicitly stored value. |
| Q9 | Collision dialog: show it by default or keep silent keep-both? | Silent keep-both by default; dialog only when the plan has conflicts and the user has set `helm.askOnConflict` (default false). |

### 14.2 Technical risks

- **Blind compile.** The largest risk is a cascade of small signature errors in `HelmUI`. Mitigation: the checklist in 11.2, the forbidden-token grep, one type per file so errors localise, and a handoff prompt that compiles module by module starting with `HelmCore`.
- **Grid label rendering** (M-19): two-line middle-truncated labels may render one line; verify and fall back to `.byTruncatingTail` with `maximumNumberOfLines = 2`.
- **FSEvents path filtering on case-insensitive volumes:** compare against realpath of the watched directory and map direct children back by name; verify symlink/case behavior on Mac.
- **`NSMetadataQuery` on a non-main queue:** the service stays on the main actor for the query object and materializes a capped batch on main and moves only ranking off; `kMDItemPath` predicate behaviour (00b C-20) is handled by not using it.
- **Cross-volume move verification:** size comparison only; a content hash would double the cost. Acceptable for a personal tool, noted in the operations panel as "verified by size".
- **Session restore with unmounted volumes:** locations are replaced by Home; the user may see unexpected tabs. Mitigation: status note and the "Reopen Last Session" menu item.
- **Trash Put Back for non-Helm items:** no public API; the command stays disabled rather than guessing.
- **Memory with many 100k-item tabs:** cap enforced by `ListingCache`, but live snapshots held by open tabs are not evicted; the old 300 MB estimate for ten such tabs is an unverified target, not a claim of acceptability; measure all live snapshots/indexes/layout and provide cache pressure behavior.
- **Thumbnail cost on network volumes:** generation is throttled to 4 concurrent requests and cancelled on scroll; still may feel slow on SMB shares.

### 14.3 Items for the handoff session (must run on macOS)

1. Compile `HelmCore` first and run its tests; then `HelmFileSystem`, `HelmOperations`, `HelmSearch`, `HelmPersistence`; then `HelmUI`; then `HelmApp` and the bundle.
2. Run the 19 checks from 00b 3.4 against the new build, especially R-1 (sheets), R-4 and R-5 (selection and stale targets), R-6 (10k Select All), R-10 (Paste validation), R-16 (Cmd+F while editing).
3. Grant Full Disk Access to the built app and verify the Trash and permission-denied states.
4. Measure the section 12 budgets that need a Mac and record the numbers in `docs/rebuild/02-handoff-results.md`.
5. Verify the two-line grid label (M-19) and the `reloadItem` identity of list nodes (M-21).

### 14.4 Deferred features with seams in place

Column and gallery views (`ContentHostController` accepts any `ContentWidget`), tags, alias creation UI pending scope decision (command exists), per-tab split panes, network locations in Places (`PlaceKind.network` kept), Finder-tag-backed stars, sandboxed distribution (`AccessBroker`), tab reordering and overflow, spring-loaded folders, promise drags.

### 14.5 Finder scope and infrastructure decisions awaiting owner

Every row below is **needs-owner**, including recommendations that fit the identity. Defaults permit drafting and preserve current scope; they are not owner answers or permission to implement external actions. Q1 remains click-to-edit, Q6 is in scope for drafting per 04 Q3, proposed, owner decision pending, Q10 remains immediate undoable Trash unless an explicit stored setting requests confirmation. Q5 and the other 14.1 questions remain unanswered too.

| Capability | Present design / recommendation | Default until owner answers |
|---|---|---|
| Eject / unmount | Recommend sidebar control/context action, NSWorkspace adapter [Mac] | No new control; reserve ejectDevice selector |
| Open in New Tab / Window, Cmd-double-click | Recommend navigation destination intent and menu after Open | Existing F-007/F-070 behavior; reserve openInNewTab/openInNewWindow |
| Close Window / Reopen Closed Tab | Recommend Shift+Cmd+W / Shift+Cmd+T; ordinary Cmd+W remains | Only current close semantics; reserve closeWindow/reopenClosedTab |
| Keyboard tab switching (Q6) / reorder | Recommend switching now, reorder later; retain custom strip | In scope for drafting per 04 Q3; proposed, owner decision pending; Mac acceptance pending |
| Alias / symlink creation | Recommend menu after Duplicate, makeAlias/makeSymbolicLink; no default shortcut | Commands remain planned; UI deferred |
| Services for selection | Recommend validRequestor/writeSelection adapter [Mac] | Standard Services menu retained; no selection-service claim |
| Reveal / default folder viewer | Recommend Show in Enclosing Folder routes to Helm; default viewer registration is separate unsupported territory [Mac] | Preserve existing reveal behavior and Alternate viewer registration; no OS-default changes |
| Native automatic window tabbing | Recommend NSWindow.allowsAutomaticWindowTabbing = false to protect custom tabs | Draft this defensive setting; owner scope confirmation still outstanding |
| Selection after trash | Recommend next visible item (previous at end, empty if none) | Draft deterministic next-item reducer behavior; not claimed owner-approved |
| Star badge / hidden dimming | Explicit in F-035/F-036 | Preserve existing visual intent; confirm parity scope |
| iCloud placeholders / File Provider | MetadataReader must distinguish evicted from missing, avoid hydration during listing; Mac tests required | Draft read-only availability state; download/evict commands deferred |
| Free-space preflight | Included in PlanningContextBuilder (7.2) | Draft preflight, report unknown capacity; no external action |
| Connect to Server / network places | PlaceKind.network seam | Later |
| Compress / decompress | Additional operation types needed | Later |
| Get Info editing / multi-select, preview pane, tags | Current Properties remains read-only single-item sheet | Later |
| Column / gallery | ContentWidget seam declared (4.6) | Later; grid/list preserved |
| Localization | UserStrings centralized; layouts currently English | Later; localization/layout risk remains |
| Linux toolchain approval | Existing Swift 6.0.3 observed usable; installation recommendation obsolete for this host | Use installed env only; installing/updating toolchains still needs owner, no action taken |
| macOS CI approval | Recommended to replace blind AppKit authoring with actual compile loop; cost not quoted/approved | No runner provisioning, network, spend or CI activation; use owner Mac handoff |

The partial Finder catalogue contains proposals conflicting with this architecture (native tabs P-002, folder merge P-119, Get Info windows P-094, Tab release P-079, and its old UndoManager bridge). Those do not override the preservation map or review-01: custom tabs, replace-without-merge, read-only Properties sheet, existing completion Tab behavior, and independent journal stacks remain the draft defaults. Resolving broader parity scope is an owner decision; no catalogue priority silently expands this lane.

## Revision log (review-01 fix cycle, Astra draft)

Evidence: document contradictions were checked against the original sections; behavior against local `Helm/Helm/` source and 00/00b; broader scope against the partial Finder catalogue. Compiler probes are described in 11.4. [Mac] claims are handoff obligations, not verified runtime facts. No owner decisions were inferred. Each review number has one disposition below; partial rejections name the exact subclaim.

| Fix | Disposition and location |
|---|---|
| 1 | Fixed (3, 4.6, 6.1): shared values/protocols in Core; OperationSummary breaks operations cycle. |
| 2 | Fixed (4.6, 5.6, 5.9, 7.8): injected recents/trash contracts and query bookmark paths remove persistence edges. |
| 3 | Fixed (3, 6.4, F-031/F-050/F-062): VolumeReader split; AppKit application/events/enrichment in UI. |
| 4 | Fixed (4.4, 4.6, 10): Foundation Broadcast stores and UI Combine adapters; RecentStore main-actor class. |
| 5 | Fixed (4.6): shared declarations and ownership inventory; Location.mutationTarget; search overlay. |
| 6 | Fixed (7.4): escaping Sendable policy resolver. |
| 7 | Fixed (3.4): manifest excludes all Mac targets/tests on Linux; filter does not change build graph. |
| 8 | Fixed with qualified rejection (11.4): platform guards retained; installed 6.0.3 supports Date.FormatStyle and explicit NSString cast, so blanket absence/no-bridge claim is not applied to this host. |
| 9 | Fixed (all declaration blocks, 11.3 rule 18): explicit public initializers and public comparison witnesses. |
| 10 | Fixed (10.1–10.2): actual Data formats, both domains, no legacy renames/deletes, atomic idempotent merge before done flag. |
| 11 | Fixed (4.1–4.3): pending navigation, snapshot/cut/rename state and missing actions/effects, activation/monitor scope. |
| 12 | Fixed (4.3, 9): first-batch/empty-success commit, attempted-location failures, Back/Forward Recent; intentional search-clear change. |
| 13 | Fixed (4.2–4.3): reducer-stamped unique snapshot IDs; off-main merging; equal-content delivery fixture. |
| 14 | Fixed (4.3–4.4, 11.5): FIFO send, sink parameters, selection reentrancy guard and test. |
| 15 | Fixed (4.6, 11.2): nonisolated stream factories/actor witnesses and Sendable continuations. |
| 16 | Fixed (throughout, 11.3): ItemSort, HelmClock, GridItemCell; collision lint. |
| 17 | Fixed (8.3): AppLevelActions and WindowDependencies prevent UI naming AppDelegate/AppEnvironment. |
| 18 | Fixed (4.5, ADR-005): per-volume queues, cancellation flag, exactly-once resume, timeout quarantine. |
| 19 | Fixed (4.5, 11.3): explicit teardown and legal nonisolated deinit cleanup. |
| 20 | Fixed (F-016/F-017, 5.7): full enumerate/filter/sort/cap; zero-debounce slash re-list; delayed drill regression. |
| 21 | Fixed (F-024, 8.5): guarded textStorage notifications and focus-loss decision order; Mac survival test. |
| 22 | Fixed (8.3): Return handles multi-rename; Space/type-select validation. Reject source attribution of Space to main.swift: source handles it in FileListViewController.keyDown; menu route is a proposed change. |
| 23 | Fixed (8.3): destructive/pane commands disabled in NSText; Cmd+Backspace text test. |
| 24 | Fixed (8.5): navigation focus only when responder is eligible; no search/monitor focus theft. |
| 25 | Fixed (F-027): List selection/arrow navigation retained with re-click gesture; Mac check. |
| 26 | Fixed (F-031): exact names, internal-name dedupe, UUID/path fallback; VM Images visible. |
| 27 | Fixed (F-035, 10.1–10.2): Double 96 fallback, stored values honoured, icon +44 item geometry. |
| 28 | Needs-owner Q10 (F-053, 10, 14.1): default false until answered, explicit stored values honoured. |
| 29 | Needs-owner Q1 (F-013, 14.1): source-preserving click-to-edit; no assumed reversal. |
| 30 | Fixed (F-057): file/directory templates preserved; natural sort declared intentional improvement. |
| 31 | Fixed (2.1 rows, 5.9, 8.3.1): normative audit fallback, metrics, ranking inputs, candidate sort and context-menu order. |
| 32 | Fixed (5.2, 5.9): kindDescription and isDocumentLike inputs; explicit extension/type rules. |
| 33 | Fixed (7.7, 8.3): post-write changeCount, conditional pasteboard clear/retry, Select All state test. |
| 34 | Fixed (8.3): helmToggleSidebar, complete binding fixture/selector table including additions/reservations. |
| 35 | Fixed (7.6, 8.2–8.3, ADR-009): journal stacks, no file UndoManager bridge; text routing [Mac]. |
| 36 | Fixed (8.3): existing MainWindowController responder position; dispatcher is plain logic. |
| 37 | Fixed (7.9, 8.4, 11.2): NSEvent class flags, DropModifiers, generic mask and source-derived drag signatures [Mac]. |
| 38 | Fixed (3, 5.9, 11.6): os(macOS) query guard; canImport(Foundation.X) forbidden. |
| 39 | Fixed (4.3, 6): realpath/direct-child mapping, per-subscriber streams, root revalidation and expanded watch set. |
| 40 | Fixed (5.2–5.3): synchronous enumeration, permission preflight, AutoreleaseScope, volume string once, guarded content type. |
| 41 | Fixed (5.1, 7.8): optional trash result, no-trash confirmation, iCloud candidate [Mac], selective journal invalidation. |
| 42 | Fixed (7.2–7.4): source manifest, space preflight, metadata postorder, copier seam, safe replacement and EEXIST retry. |
| 43 | Fixed (7.2, 7.5): destination-sensitive normalized comparison, case-only rename, colon allowed, whitespaces trim. |
| 44 | Fixed (4.2, 5.4, 6.3, 8.1, 12): reload baseline, inline-rename deferral, measured scale and alternate layout seam. |
| 45 | Fixed (3.3–3.5, 9): HelmKit path, settings-based plist/entitlements, package concurrency/scheme checks and signing caveats. |
| 46 | Fixed (7.3, 10.1): askOnConflict setting/toggle and reachable sheet; silent keep-both default. |
| 47 | Fixed (4.6, 5.9, F-046): query/event/service contracts, capped main-actor materialization, off-main ranking and scoped cancellation. |
| 48 | Needs-owner (14.5): complete Finder scope table with recommendations/defaults; Q6 remains unanswered/out of scope. |
| 49 | Fixed (F-001, 10.3): open request beats restore, then Home; one delegate API. |
| 50 | Fixed (9, 11.2–11.3): failable coder init, safe cast, exact QL IUOs, safe key/URL helpers, stored-task deferral and porting rules. |
| 51 | Fixed (11.3 rules 19–28): source porting, sink/lifetime/selector rules, type-select, URLs, synchronous iterators and build order. |
| 52 | Fixed drafting/specification (11.4–11.6); needs-owner (14.5) for toolchain changes/macOS CI, default no install/provision/spend. Executable static-gate blocks and conservative-review limits documented; future modules/tooling not falsely reported tested. |
| 53 | Fixed (2.1): recounted 13 Keep, 45 Keep+fix, 12 Redesign, 2 Drop after F-013 change. |
| 54 | Fixed (10.2): one schemaVersion/items envelope, including generic document payload. |
| 55 | Fixed (5.2, 7.6, B-041): begin/complete lifecycle, child-count token, always-trash undo with change warning. |
| 56 | Fixed (4.2): PresentationSnapshot.children is sole expanded topology; no duplicate TreeSnapshot. |
| 57 | Fixed (3.2): explicit import DAG includes TestKit→FileSystem, no Persistence→Search. |
| 58 | Fixed (11.3 rule 9): no GeometryReader exception for AppKit GhostOverlay. |
| 59 | Fixed (2.2): B-004/005/006/007/008/014/064/065 explicitly mapped. |
| 60 | Partially rejected (F-017, 5.7): BreadcrumbBar.swift:520 appends items.prefix(50) after parent, so 51 total is correct (also 00b citation audit row 79); retain cap. Fixed F-023 tilde acceptance policy as intentional change. |
| 61 | Fixed (8.3, 11.3): textField/type-select dependency and collection subclass; native arrow selection retained. |
| 62 | Fixed (4.2, 5.2–5.4, 14.2): derived URL, interned strings, sortedEntries/index, memory estimate a measurement target. |
| 63 | Fixed (4.4, 11, 12): main isolation assertion and notOnQueue assertion inside synchronous I/O. |
| 64 | Fixed (F-003/F-072/F-063, 11.2): frame-restore result, proxy/icon/group validation checks, standard share item [Mac]. |
| 65 | Fixed (5.5): showHidden in cache key; stale listing not ready until existence/access validation. |

Revision-log note (Opus review of 02/03/04, draft application 2026-11-04): Opus review of 02/03/04 confirms the rejection of Fix 60’s cap claim and Fix 22’s Space attribution, and rejects Fix 22’s menu-equivalent mechanism.
