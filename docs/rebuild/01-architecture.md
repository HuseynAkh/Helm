# Helm rebuild: target architecture (01-architecture)

Author: Fable 5.1 (architecture lead, Phase 1)
Inputs: `docs/rebuild/00-current-state.md` (Phase 0 audit with Appendix C errata), `docs/rebuild/00b-opus-review.md` (independent checker; wins over 00 where they conflict), `docs/rebuild/00a-astra-first-pass.md`, `/workspace/forge/runs/git-history.txt`, and spot-checks of the current source under `Helm/Helm/`.
Status: design for a full rebuild on a new branch of the same repository. Nothing here has been compiled. Every API named below is a stable, documented macOS 14 API chosen for blind authoring on Linux; the first compile happens in the owner's Mac handoff session.

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
- **Grid and list views only**, with expandable folders in the list (F-035 to F-037). Column and gallery views are not goals for this rebuild; the view layer leaves a seam for them.
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
6. **Explicit virtual locations.** Recent, Trash and Search results are location kinds with their own data source, sort, operations policy and address-bar behaviour. No URL-scheme special cases scattered through controllers.
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

Dispositions: **Keep** (reproduce as is), **Keep+fix** (reproduce the contract, fix the listed bugs), **Redesign** (same user outcome, different mechanism), **Drop** (not carried, with reason). Module names refer to section 3.

| ID | Feature | Owner module / type | Disposition | Must not regress |
|---|---|---|---|---|
| F-001 | Application lifecycle | `HelmApp/AppDelegate`, `HelmApp/WindowRegistry` | Keep+fix | One window at launch; stays alive after last window closes; Dock reopen creates a window only if none visible. Fix: observer tokens stored and removed (B-063); open requests buffered until launch finishes (B-103); `reply(toOpenOrPrint:)` called (B-114). |
| F-002 | External open requests | `HelmApp/AppDelegate`, `HelmApp/OpenRequestRouter` | Keep+fix | Folders navigate the key window (not the first); files launch via `NSWorkspace`; `public.folder` Alternate viewer registration kept in Info.plist. Initial URL reaches the first tab (B-018). |
| F-003 | Main window and toolbar | `HelmUI/Window/MainWindowController`, `HelmUI/Window/ToolbarFactory` | Keep+fix | 1100×750 initial, 700×450 minimum, unified toolbar, hidden title, autosave `HelmMainWindow`; fixed item order sidebar toggle, back/forward group, path, view-mode segment, search field; path item `.user` priority, width 60 to 1000, height 34; search placeholder "Search files and folders". Fix: `center()` only when no saved frame exists; extra windows cascade (M-03). |
| F-004 | Sidebar split and collapse | `HelmUI/Window/MainSplitViewController` | Keep | `NSSplitViewItem(sidebarWithViewController:)`, sidebar 180 to 320, content minimum 400, thin divider, autosave `HelmMainSplitView`, collapse animates 0.12 s then `adjustSubviews`, Ctrl+Cmd+S and toolbar button. |
| F-005 | Back/Forward history | `HelmCore/Tab/NavigationHistory` inside `TabState` | Keep+fix | Per-tab stacks of location plus selection snapshot; navigate pushes and clears forward; back/forward restore selection and the widgets show it (B-011). Fix: same-location navigation is a no-op (B-019); Back/Forward validated (B-075). |
| F-006 | Up and Home | `HelmCore/Tab/TabReducer` | Keep+fix | Cmd+Up no-op at virtual locations and at `/`; Shift+Cmd+H goes to Home. Fix: Up snapshots selection like any navigation; root detection uses the standardized path, not `deletingLastPathComponent` (00b F-006). |
| F-007 | Opening items | `HelmCore/Tab/OpenPolicy`, `HelmUI/Content/ItemActivation` | Keep+fix | Double-click: non-package directory navigates (now also symlinks to directories, B-071); anything else opens via `NSWorkspace`; successful opens recorded in Recent; failure alert "Unable to Open Item". |
| F-070 | Multi-open semantics | `HelmCore/Tab/OpenPolicy` | Keep | "Open N Items": files and packages launch; folders navigate; several folders: last wins in the current tab (documented, deliberate). |
| F-008 | Refresh | `HelmCore/Tab/TabReducer` (`.refresh`) | Keep+fix | Cmd+R invalidates cache, reloads, keeps selection by ID intersection, applies it to widgets, updates status, restarts the monitor, re-runs an active search; in Recent reloads the recents collection. |
| F-009 | Tab creation | `HelmUI/Tabs/TabContainerController`, `HelmCore/Tab/TabState` | Keep | Cmd+T and "+" open a new tab at the active tab's location only (no selection, history, view mode or search carried over). First tab opens at the requested initial URL or Home. |
| F-010 | Tab bar | `HelmUI/Tabs/TabBarView` | Keep+fix | Custom strip: 30 pt bar, 28 pt tabs, 12 pt titles truncating tail, 16 pt close buttons, 24 pt "+", accent 15 % selected tint radius 6, fill-equally, hidden when one tab. Titles: `Recent`, `/`, else last path component. Fix: whole tab container clickable (M-06); titles diffed instead of full rebuild (B-081); toolbar segment and search field follow the active tab (B-020). Not added: reordering, overflow, keyboard tab switching (seams left, section 14). |
| F-011 | Tab closing | `HelmUI/Tabs/TabContainerController`, `HelmCore/Window/TabListReducer` | Keep | Close button, middle-click, Cmd+W; only when more than one tab; closing active selects left neighbour (second tab when closing the first); Cmd+W with one tab closes the window. |
| F-068 | Window/state restoration | `HelmPersistence/SessionStore` | Redesign | Window frame and split position persist as today. New: tabs and locations persist per window in a versioned JSON session file and are restored on launch (section 10). Settings-window autosave names kept. |
| F-071 | Keyboard focus | `HelmUI/Focus/FocusCoordinator` | Redesign | New explicit focus model: pane receives focus after launch, tab switch, view-mode switch and address-bar exit; `initialFirstResponder` set; key-view loop defined (B-102). |
| F-072 | Window identity | `HelmUI/Window/MainWindowController` | Keep+fix | Title stays visually hidden but `window.title` and `representedURL` follow the active tab so the Window menu and proxy icon work. |
| F-012 | Breadcrumb rendering | `HelmUI/AddressBar/BreadcrumbView` | Keep | Ancestors from `/`; `/` labelled "/", home "Home", others last component; current bold 13 pt label colour; ancestors 13 pt secondary; `›` separators 11 pt tertiary; stack spacing 2, insets 6; 26 pt scroller in 34 pt bar, radius 8, 10 % quaternary background; rightmost end visible after rebuild and resize; Recent shows one semibold "Recent" label; hover highlight 7 % radius 4. Colours re-resolved on appearance change (B-062). |
| F-013 | Segment and empty-space clicks | `HelmUI/AddressBar/BreadcrumbView` | Redesign | Product decision (section 14, Q1): a single click on an ancestor segment navigates to that ancestor (restoring the README promise, B-051); click on the current segment, empty space, or Cmd+L enters edit mode; Option-click on any segment enters edit mode. Separator clicks do nothing. |
| F-014 | Entering typed-path mode | `HelmUI/AddressBar/AddressEditor` | Keep+fix | Field shows the path with trailing `/`, caret at end (no select-all), listing shown immediately, borderless 13 pt, inset 10. Fix: focus taken synchronously with one deferred retry (B-112); allowed in Recent and Trash, where the field starts with Home (B-054). |
| F-015 | Commit and validation | `HelmCore/AddressBar/PathEntry` (pure), `HelmUI/AddressBar/AddressEditor` | Keep+fix | Trim, expand `~`, standardize, accept existing directories (and symlinks to directories); empty commits Home; invalid: `NSSound.beep()`, 0.4 s shake, red 11 pt "Invalid path or folder not accessible" for 2.5 s. Fix: typed text kept for correction; relative paths resolve against the current directory, not the process cwd. Committing a file path opens the file (replaces the dead end in B-054). |
| F-016 | Prefix completion | `HelmCore/AddressBar/PathCompletionEngine` (pure), `HelmFileSystem/Providers/CompletionProvider` | Keep+fix | Debounce from `helm.completionDebounceMilliseconds` (default 100, floor 30); anchored case-insensitive match; directories first then `localizedStandardCompare`; cap 50. Fix: hidden-file filter follows the app setting; icons loaded only for visible rows; request generation checked on every edit (B-052). |
| F-017 | Slash-ended browsing | `HelmCore/AddressBar/PathCompletionEngine`, `HelmFileSystem/Providers/CompletionProvider` | Redesign | Same rows: `..` first (except at `/`), then up to 50 children, directories first. Mechanism: the same async, generation-guarded pipeline as F-016 with a streaming first page, no main-thread I/O (B-050), normalized paths (B-110). |
| F-018 | Completion popup | `HelmUI/AddressBar/CompletionPanel` | Keep+fix | Borderless non-activating child `NSPanel` at `.popUpMenu`, `.menu` material radius 6, 24 pt rows, no header, single selection, 8 visible rows then scroll, width tracks the bar, repositions on move/resize, first row selected on show. Fix: scroll to the selected row (B-111); clamp to screen (B-062). |
| F-019 | Mouse acceptance | `HelmUI/AddressBar/CompletionPanel` | Keep+fix | Single click selects (and now refreshes ghost text, B-053); double-click accepts: directories re-list without navigating, files fill the path and hide the popup. |
| F-020 | Tab completion | `HelmCore/AddressBar/PathCompletionEngine` (`tabAction`) | Keep | Tab accepts the ghost suffix, else the selected row (directories drill), else requests completions; Tab and Shift+Tab consumed while editing; `..` as row 0 means an immediate Tab goes up one level. |
| F-021 | Return | `HelmCore/AddressBar/PathCompletionEngine` (`returnAction`) | Keep+fix | Text without trailing `/` plus visible popup substitutes the selected row then commits; trailing `/` commits the field text. Fix: a stale popup can never be committed because every edit invalidates the generation (B-052, 00b C-10). |
| F-022 | Escape and arrows | `HelmUI/AddressBar/AddressEditor` | Keep | First Esc hides popup and clears ghost; second exits without navigating; Up/Down clamp; Right accepts ghost only with collapsed caret at end; other arrows fall through. |
| F-023 | Ghost text | `HelmCore/AddressBar/PathCompletionEngine` (`ghostSuffix`), `HelmUI/AddressBar/GhostOverlay` | Keep+fix | Tertiary overlay positioned by measured text width; shown only when the selected row's path starts with the typed text case-insensitively and caret at end. Fix: accepting replaces the typed prefix with canonical casing; `~` and relative input get ghost text because rows are matched against the expanded form (B-053, M-12). |
| F-024 | Editing and focus survival | `HelmUI/AddressBar/AddressEditor` | Redesign | Same outcomes: outside click cancels; survives toolbar relayout; programmatic edits do not fire change notifications. Mechanism: edits go through `NSTextView.insertText(_:replacementRange:)` guarded by `shouldChangeText` (B-115); only mouse-down and `viewDidMoveToWindow` relayout trigger re-acquisition; a programmatic focus move (Cmd+F, Esc, tab switch) ends editing (B-108). |
| F-025 | Copy Path | `HelmUI/AddressBar/BreadcrumbView` | Keep | Context menu "Copy Path" for file locations copies the current location's POSIX path as a string. |
| F-026 | Places sections and icons | `HelmUI/Sidebar/SidebarPlacesView`, `HelmCore/Places/PlacesModel` | Keep | Order Recent; Favorites (Home `house`, Desktop `menubar.dock.rectangle`, Documents `doc`, Downloads `arrow.down.circle`, Applications `square.grid.2x2`, blue); Bookmarks `bookmark.fill` orange (hidden when empty); Starred `star.fill` yellow (hidden when empty); Devices `externaldrive`/`internaldrive` gray (hidden when empty); Trash `trash`. `.sidebar` list style, rows padded 2. |
| F-027 | Selection mapping | `HelmCore/Places/PlacesModel` (`highlightedPlace`, pure) | Keep+fix | Recent maps to Recent; exact match among favorites, bookmarks, devices, trash; else deepest containing place. Fix: starred folders become highlight candidates; a click dispatches navigation and the highlight follows the committed location; re-clicking the highlighted row re-navigates (tap action, not a selection binding, M-14). |
| F-028 | Bookmarks and sidebar drops | `HelmUI/Sidebar/SidebarPlacesView`, `HelmPersistence/BookmarkStore` | Keep+fix | Drop of directories anywhere on the list shows "Drop Folder to Add Bookmark" caption and adds standardized, deduplicated, name-sorted bookmarks; files ignored; context menu "Remove Bookmark". Fix: one shared store (B-029); unavailable bookmarks kept and dimmed rather than dropped. Dropping files onto a sidebar folder still never moves them. |
| F-029 | Starred | `HelmPersistence/StarStore`, `HelmUI/Sidebar`, `HelmCore/Places/PlacesModel` | Keep+fix | Cmd+D toggles each selected item; context item "Star"/"Remove from Starred"; Starred section in sidebar. Fix: one observable store shared by all windows and tabs (B-027); stable name order (B-113); starred files open instead of failing as folders (B-028). Data migrates from `com.helm.starredFiles` (section 10). |
| F-030 | Recent | `HelmPersistence/RecentStore`, `HelmCore/Identity/Location` (`.recent`), `HelmFileSystem/Virtual/RecentSource` | Keep+fix | Virtual location; records folder navigations and successful default-app opens; dedupe; cap 300; shows up to 180; missing paths pruned only when the containing volume is mounted (B-029). Fix: ordered by last access (B-030); hidden toggle applies; mutations in Recent rejected unless they target a concrete item's parent (B-031); Open With records access. New: "Clear Recent" menu item. |
| F-031 | Devices | `HelmFileSystem/Providers/VolumeProvider`, `HelmCore/Places/VolumeFilter` (pure) | Keep+fix | Refresh on `didMount`/`didUnmount`; filter hidden, non-browsable, paths under `/System/Volumes/`, `/private/`, `/dev/`; dedupe by UUID; internal first then name. Fix: name filter restricted to whole-word `Preboot`, `Recovery`, `VM`, `Update`, `Hardware`, `xarts` and the ` - Data` suffix (B-080); resource reads done once outside the comparator (B-058); no refresh on unrelated defaults writes. "Show all mounted volumes" removes every filter except UUID dedupe (00b C-13). |
| F-032 | Trash | `HelmCore/Identity/Location` (`.trash`), `HelmFileSystem/Virtual/TrashSource` | Redesign | Trash becomes a virtual location aggregating `~/.Trash` and `/Volumes/*/.Trashes/<uid>` (B-087), with Empty Trash and Put Back commands (section 7.8) and a permission-denied state when Full Disk Access is missing (B-109). |
| F-033 | Folder Tree sidebar | none | Drop | README-only promise; no code exists. Open product question (section 14). The sidebar keeps a `SidebarMode` seam so a tree can be added later. |
| F-034 | Translucent sidebar | `HelmUI/Sidebar/SidebarContainerController` | Keep | `helm.sidebarLiquidGlass` toggles an `NSVisualEffectView` (`.sidebar`, within-window) behind the hosting view and clear SwiftUI backgrounds; observed through the settings model, not every defaults write. |
| F-035 | Grid view | `HelmUI/Content/GridView` (NSCollectionView) | Keep+fix | Flow layout 140×140 items, inter-item 10, line 14, insets 12/16/12/16; clear background; multiple selection; icon 96×96 proportional; name 11 pt centred, two lines with middle truncation (verify rendering at handoff, M-19); selection accent 20 % radius 8; `.fileURL` drags. Fix: icon size follows `helm.gridIconSize` (B-059); every datasource access is by ID against the snapshot (B-009, B-101). |
| F-036 | List view | `HelmUI/Content/ListView` (NSOutlineView) | Keep+fix | `.fullWidth`, 24 pt rows, alternating backgrounds, multiple selection; columns Name (min 200, 13 pt, 18 pt icon), Size (80/60, `--` for directories, `ByteCountFormatter .file`), Date Modified (160/100, medium date short time), Kind (120/80, `UTType.localizedDescription`); secondary 12 pt text. Fix: header clicks sort (B-034); Kind sortable; column autosave (B-078). |
| F-037 | Expandable folders | `HelmUI/Content/ListView`, `HelmCore/Snapshot/TreeSnapshot` | Keep+fix | Non-package directories expand; children load asynchronously with a placeholder. Fix: children use the tab's sort, hidden-file setting and stars (B-032); nodes are class instances keyed by ID so `reloadItem` identity works (M-21); loads are generation-guarded. |
| F-038 | Selection | `HelmCore/Tab/TabState` (`selection: Set<ItemID>`) | Redesign | Model selection is the source of truth; widgets apply it after every snapshot change and report user changes back; right-click on unselected replaces, on selected keeps, on background clears; status bar follows. Expanded children are first-class selectable items for every command (B-033). |
| F-039 | View-mode switching | `HelmCore/Tab/TabState` (`viewMode`), `HelmUI/Content/ContentHostController` | Keep+fix | Cmd+1/Cmd+2 and segment; one widget visible at a time. Fix: selection and scroll anchor (first visible ID) survive the switch; segment synchronised per tab (B-020); default from `helm.defaultViewMode` (B-059). |
| F-040 | Sorting | `HelmCore/Model/SortDescriptor`, `HelmCore/Snapshot/PresentationSnapshot` | Keep+fix | Fields name, size, dateModified, kind; direction; directories-first applied before the field regardless of direction; default name ascending with `localizedStandardCompare`. Fix: sorted once per snapshot, never on access (B-010); three-way comparator with ID tie-break (B-035); column clicks, menu and settings all write the same descriptor (B-034). |
| F-041 | Type-select and keyboard open | `HelmUI/Content/ListView`, `HelmUI/Content/GridView`, `HelmCore/Text/TypeSelect` (pure) | Keep+fix | List keeps native type-select; grid gains type-select through the same pure matcher; Cmd+O and Cmd+Down open the selection (new bindings, section 8.5). |
| F-042 | Hidden files | `HelmCore/Tab/TabState` (`showHidden`), settings model | Keep+fix | Cmd+. toggles per tab and writes `helm.showHiddenFiles`; menu item shows a check mark (B-075); applies to expanded children, completions and Recent. |
| F-069 | Symlinks and aliases | `HelmCore/Model/FileEntryKind`, `HelmFileSystem/Live/MetadataReader` | Redesign | Directory-ness resolved through the link target for navigation; dangling links badged; Finder aliases resolved via `URL(resolvingAliasFileAt:options:)` on open (B-071). |
| F-043 | Search entry and scope | `HelmUI/Window/ToolbarFactory` (search field), `HelmCore/Tab/SearchState` | Keep+fix | Field sends on every change; Cmd+F focuses and selects; trimmed; empty exits search; current-folder scope in a directory, everywhere scope boosted toward the last directory in Recent; debounce `helm.searchDebounceMilliseconds` (default 180, floor 40); navigation exits search. Fix: per-tab query (B-020); results tagged with query generation (B-023); loading indicator and "not indexed" state (B-099); results show a Location column (M-24). |
| F-044 | Spotlight predicate and scopes | `HelmSearch/Spotlight/SpotlightQueryBuilder` (pure), `HelmSearch/Spotlight/SpotlightSearchService` | Keep+fix | `kMDItemFSName CONTAINS[cd]`; everywhere scope is Home, standard folders that exist, bookmarks, removable browsable volumes, optionally local computer. Fix: `NSMetadataQueryLocalComputerScope` passed as the symbolic constant (B-024); path exclusions applied in ranking, not the predicate (00b C-20); scope, hidden policy and system filter are separate settings (B-025). |
| F-045 | Ranking | `HelmSearch/Rank/SearchRanker` (pure) | Keep | Full score table: exact +1200, prefix +800, contains +500, +100 per token, preferred root +380 plus depth bonus max(0, 150−30·depth), other Home +220, bookmark +300, under active directory +200, directory +80, document-like +140, hidden −280, system-like −650 when excluded, modified <1 d +90, <7 d +55, <30 d +25, current-folder +40; ties by newer modification then natural name; preferred roots list plus visible top-level Home folders except Library. Home enumerated once per search, casing preserved (B-026). |
| F-046 | Result delivery | `HelmSearch/Spotlight/SpotlightSearchService` | Keep+fix | `DidFinishGathering` and `DidUpdate` observed; updates disabled while reading; candidate cap `max(limit×3, 450)`; dedupe; rank; return `limit` (default 300). Fix: metadata materialisation off the main actor; ranked order preserved in a `.searchResults` snapshot (B-022); termination scoped to query identity (B-021). |
| F-047 | File icons | `HelmUI/Imaging/IconCache` | Keep+fix | `NSCache` keyed by path plus size, limit from `helm.maxCachedIcons` (default 800, floor 100). Fix: keys include content type and change token; invalidated on monitor events (B-056); `NSWorkspace.icon(forFile:)` called off the main thread and delivered to the main actor. |
| F-048 | Thumbnails | `HelmUI/Imaging/ThumbnailPipeline` | Keep+fix | Eligible UTTypes image, movie, video, pdf, presentation, spreadsheet, html, svg; never directories; generic icon first, cached result if present, async `QLThumbnailGenerator` otherwise; cells cancel on reuse and verify the ID before assigning; grid 96 pt, list 18 pt. Fix: request size in points with the view's backing scale (B-056); per-key subscriber sets (B-055); cost-based limit from `helm.maxCachedThumbnails` read live. |
| F-049 | Quick Look | `HelmUI/Content/QuickLookCoordinator` | Keep+fix | Space toggles `QLPreviewPanel.shared()` when the selection is non-empty; selected items in display order. Fix: Space handled only when the pane is first responder and no modifiers (B-060); panel reloads on selection change; `previewPanel(_:handle:)` forwards arrows; source frame supplied; expanded children included; a "Quick Look" menu item with Space equivalent validates. |
| F-050 | Properties | `HelmUI/Sheets/PropertiesView`, `HelmFileSystem/Providers/PropertiesLoader` | Keep+fix | Cmd+I (selection else current directory) or context menu; 360×480 sheet; 64 pt icon, name, kind, Size, Location, Created, Modified, Type, Image dimensions, Open With, Permissions words plus octal, "Show in Enclosing Folder", Done is Escape. Fix: loader off the main actor (B-058); folder size computed lazily with cancellation; dismissed via `dismiss(hostingController)` (B-117); exact byte count shown beside the formatted size (B-066). |
| F-051 | Cut/Copy/Paste | `HelmUI/Commands/ClipboardCommands`, `HelmOperations/Clipboard/ClipboardState` (pure) | Keep+fix | Edit menu uses `NSText` selectors so text fields win; the window controller performs file semantics otherwise; Cut marks a move. Fix: `changeCount` tracked so an external copy invalidates internal state (B-036); cut state cleared only after the move succeeds (B-037); reads use `.urlReadingFileURLsOnly` (B-106); Paste validated through `validateMenuItem` (00b C-23); cut items drawn dimmed. |
| F-052 | Copy/move semantics | `HelmOperations/Plan/OperationPlanner` (pure), `HelmOperations/Execute/OperationExecutor` | Redesign | Default collision policy stays "keep both" with `name 2.ext` naming; the planner also supports Replace, Skip and Stop with apply-to-all (section 7.3); multi-part extensions preserved (`a.tar.gz` becomes `a 2.tar.gz`, B-116); same-parent moves are no-ops (B-040); per-item outcomes (B-038); progress and cancellation (B-049). |
| F-053 | Move to Trash | `HelmOperations` command `.trash` | Keep+fix | Cmd+Backspace or context menu; `FileManager.trashItem` per item recording the resulting URL. Fix: honours `helm.confirmBeforeTrash` (B-048); partial failures reported; undo restores exact names (B-042). |
| F-054 | Rename | `HelmUI/Content` inline editing, `HelmCore/Naming/FileNameValidator` (pure) | Redesign | Return with one selected item renames. Mechanism: inline cell editing in grid and list (basename preselected with a UTF-16 range, B-066) replaces the modal `NSAlert`; the validator rejects separators, `..`, empty and reserved names (B-046). Context "Rename" kept. |
| F-055 | Batch rename | `HelmCore/Naming/BatchRenamePlanner` (pure), `HelmUI/Sheets/BatchRenameView` | Keep+fix | Multiple selection plus Return or "Rename N Items…": 500×450 sheet; modes Add Text (Prepend/Append), Find & Replace, Template default `[Original Name]-[Counter]`, counter start, `[Date]` = `yyyy-MM-dd`; basename only, extension preserved; monospaced preview of first 20 ("… and N more"); Rename disabled when nothing changes; Return/Escape. Fix: full plan validated for duplicates, existing targets and swaps using temporary names (B-047); one journal entry per batch; preview keyed by ID. |
| F-056 | New Folder | `HelmOperations` command `.createFolder` | Keep+fix | Shift+Cmd+N or background menu creates "New Folder" with collision suffix immediately, then starts inline rename of the new folder (section 14 Q2; immediate creation preserved, rename additive). Target is the displayed directory; refused in Recent (B-031). |
| F-057 | New File and templates | `HelmOperations` command `.createFile`, `HelmFileSystem/Providers/TemplateProvider` | Keep+fix | Background menu "New File" submenu lists visible children of `~/Templates` (files only; directories excluded), separator, "Empty Text File" (`Untitled.txt`); template copies keep the template name with collision suffix. Fix: enumeration cached off the main thread (B-058). New: File menu "New File ▸" mirrors it. |
| F-058 | New File sheet | none | Drop | Dead code with no caller; the template submenu covers the use. |
| F-059 | Undo | `HelmOperations/Journal/OperationJournal`, `HelmUI/Commands/UndoBridge` | Redesign | Cmd+Z and Shift+Cmd+Z undo and redo whole operations with action names Copy, Move, Move to Trash, Rename, New Folder, New File, Duplicate; one window-scoped journal is the `NSUndoManager` target (B-100); undo of a copy or create trashes instead of deleting when the item changed since creation (B-041); errors surface; affected tabs refresh (B-043); drags are undoable (B-044). |
| F-060 | Permanent delete | `HelmOperations` command `.deletePermanently` | Redesign | Becomes a real user command (Option+Cmd+Backspace, confirmation required, not undoable, labelled as such). |
| F-061 | Operation progress and cancellation | `HelmOperations/Execute/OperationProgress`, `HelmUI/Operations/OperationsPanelView` | Redesign | Progress published per operation with bytes, items, ETA and a cancel button in a window-bottom panel; operations are owned by the app and survive tab closing. |
| F-062 | Open With | `HelmUI/Menus/ContextMenuBuilder`, `HelmFileSystem/Providers/ApplicationProvider` | Keep+fix | Single-item submenu, first ten `urlsForApplications(toOpen:)` with 16 pt icons, disabled "No Applications" when empty; launch via `NSWorkspace.open(_:withApplicationAt:configuration:completionHandler:)`. Fix: failure alert hops to the main actor (B-070); access recorded in Recent; app list enumerated off the main thread; still offered for folders (M-32). New: "Other…" opens an `NSOpenPanel` restricted to applications. |
| F-063 | Share | `HelmUI/Menus/ContextMenuBuilder` | Keep+fix | Share submenu replaced by `NSSharingServicePicker` (B-083) presented from the item; same menu position. |
| F-064 | Status bar | `HelmUI/Content/StatusBarView`, `HelmCore/Text/StatusText` (pure) | Keep+fix | 24 pt bar, top separator, 11 pt secondary label: "N items"/"1 item", optional "N selected", optional "X free", joined by "  •  ". Fix: free space read asynchronously and cached per volume (B-058); optional selected-bytes total; loading and error states shown here (B-017). |
| F-065 | Settings and Advanced Options | `HelmUI/Settings/*`, `HelmCore/Settings` | Keep+fix | Two windows: "Helm Settings" 450×300 tabs General/Appearance/Behavior; "Advanced Options" 500×440 form; autosave names `HelmPreferences`, `HelmAdvancedOptions`. Fix: every control wired through one settings model (B-059); unimplemented controls removed (single-click stays only if section 14 Q4 is answered yes). |
| F-066 | Standard menus | `HelmUI/Menus/MainMenuBuilder` | Keep | About, Settings… (Cmd+,), Advanced Options…, Services, Hide/Hide Others/Show All, Quit; Window menu Minimize, Zoom, Bring All to Front; Help menu present. Built in code, no nib. |
| F-067 | Drag and drop (grid/list) | `HelmUI/Content/DragDropCoordinator`, `HelmOperations/Plan/DropPlanner` (pure) | Keep+fix | Source writes `NSURL` per item; local mask copy+move, external copy; drop on a non-package directory targets it, otherwise the displayed directory; Option forces copy. Fix: default is move within a volume and copy across volumes (section 14 Q5), Cmd forces move; modifiers read from the drag info (B-045); no insertion gap drawn (B-074); drops inside an expanded subfolder target that row's parent (B-079); result journaled (B-044); source and destination tabs refresh via the monitor. |

Coverage: the audit (00 plus 00b additions) defines F-001 to F-072 with no gaps, 72 feature IDs. All 72 are mapped above. Dispositions: Keep 15, Keep+fix 40, Redesign 15, Drop 2 (F-033, F-058).

### 2.2 Critical and High bug map

Severities are the audit's after the Opus re-ratings (00b 3.3). Each row names the design element that removes the bug class, not a patch.

| Bug | Severity | Eliminated by |
|---|---|---|
| B-009 stale items, wrong target, index crash | Critical | `PresentationSnapshot` is immutable and published atomically; widgets hold the snapshot they were last given and resolve every datasource call by `ItemID`; monitor events produce a new snapshot through the same reducer as navigation (sections 4.2, 5.4). |
| B-041 undo of copy/create deletes permanently | Critical | `OperationJournal` undo of create or copy compares the destination's change token and child count; if changed it trashes, never removes; the journal's undo manager is never shared with text-field undo (section 7.6). |
| B-001 stale pbxproj | High | Generated project removed from the repo; `project.yml` is the only description; CI regenerates (section 3.5). |
| B-002 `SWIFT_VERSION 5.9` | High | `SWIFT_VERSION: "5"` in `project.yml`, `swiftLanguageVersions: [.v5]` in `Package.swift` (section 3.4). |
| B-003, B-076 test module named `Testing` | High | XCTest only; support module named `HelmTestKit` (section 11). |
| B-010 sort on every read | High | Sorted once per snapshot; `indexByID` stored with the snapshot (section 4.2). |
| B-011 invisible selection acted on | High | Selection lives in `TabState`; `ContentHostController.apply(_:)` pushes it into the visible widget after every change; commands read `TabState.selection` (section 4.3). |
| B-012 side effects after await | High | Every async result is applied through `TabStore.commit(_:for:)` which drops stale generations (section 4.5). |
| B-017 errors indistinguishable from empty | High | `SnapshotPhase` is `.loading`, `.ready` or `.failed(LoadError)`; status bar and content pane render it; failed loads do not enter history or Recent (section 4.2). |
| B-022 ranked order lost | High | `.searchResults` snapshots carry `sortedIDs` in rank order with `sort == .relevance` (section 5.6). |
| B-027 independent star services | High | One `StarStore` built by the composition root and injected everywhere, observable through Combine (section 10.2). |
| B-031 wrong-target mutations in Recent | High | `Location.mutationTarget` is `nil` for virtual locations; the planner rejects commands without a concrete target (section 7.2). |
| B-033 commands ignore expanded children | High | `TreeSnapshot` includes children as items with IDs; selection is `Set<ItemID>`; commands resolve through the snapshot (section 4.2). |
| B-036 stale internal clipboard | High | `ClipboardState` stores the pasteboard `changeCount` and compares before honouring internal URLs (section 7.7). |
| B-037 cut consumed early | High | Paste builds a `ClipboardTransaction`; sources are acknowledged per item after success (section 7.7). |
| B-038 partial failure returns nothing | High | `OperationResult` carries `[ItemOutcome]`; the executor never throws past the first item (section 7.4). |
| B-040 same-folder move renames | High | `OperationPlanner.preflight` detects same-parent, self and descendant relationships before any I/O (section 7.3). |
| B-042 undo keeps destination names | High | Journal entries store exact source and destination URLs per item (section 7.6). |
| B-043 fire-and-forget undo | High | Undo runs as a tracked operation with progress and error surfacing; redo registered (section 7.6). |
| B-046 rename accepts path components | High | `FileNameValidator` is the only constructor of `ValidFileName`; the operations module accepts nothing else (section 7.5). |
| B-050 main-thread completion I/O | High | `CompletionProvider` is an actor whose I/O runs on the I/O executor; the UI receives value rows only (section 5.7). |
| B-067 test gap | High | Section 11 defines the test matrix; the pure modules make the dangerous boundaries testable on Linux. |
| B-100 undo target freed with tab | High | The journal is window-scoped, owned by `MainWindowController`, and removes its actions in `deinit` (section 7.6). |
| B-101 O(n² log n) selection sync | High | Selection translated through the snapshot's `indexByID`; cost O(k) (section 4.2). |
| B-102 pane never focused | High | `FocusCoordinator` with defined transitions (section 8.5). |
| B-117 undismissable sheets (unverified) | High if confirmed | Sheets presented and dismissed through one `SheetPresenter` that keeps the hosting controller reference (section 8.6). |

Medium and Low bugs are addressed by the same mechanisms; the feature map lists them row by row.

---

## 3. Module boundaries

### 3.1 Module list

Nine SwiftPM targets in one package plus one Xcode app target that consumes the package as a local dependency.

| Module | Kind | Imports allowed | Linux-testable | Responsibility |
|---|---|---|---|---|
| `HelmCore` | library | Foundation | Yes | Value types and pure logic: `Location`, `ItemID`, `FileEntry`, `PresentationSnapshot`, `TreeSnapshot`, `SortDescriptor`, `NavigationHistory`, `TabState`, reducers, `PathEntry`, `PathCompletionEngine`, `FileNameValidator`, `BatchRenamePlanner`, `VolumeFilter`, `PlacesModel`, `StatusText`, `TypeSelect`, settings schema, snapshot diffing. |
| `HelmFileSystem` | library | Foundation (CoreServices behind `#if canImport`) | Yes (with the in-memory fake) | `FileSystem` protocol, `LiveFileSystem`, `InMemoryFileSystem`, `DirectoryEnumerator`, `MetadataReader`, `DirectoryMonitor` protocol with FSEvents, dispatch-source and polling implementations, `CompletionProvider`, `VolumeProvider`, `TemplateProvider`, `ApplicationProvider`, `RecentSource`, `TrashSource`, `ListingCache`, I/O executor. |
| `HelmOperations` | library | Foundation, HelmCore, HelmFileSystem | Yes | `OperationPlanner`, `OperationExecutor`, `OperationJournal`, `OperationProgress`, `DropPlanner`, conflict policy, Trash and Put Back, clipboard transaction logic. |
| `HelmSearch` | library | Foundation, HelmCore, HelmFileSystem | Partially (ranker and query builder yes; the `NSMetadataQuery` service compiles everywhere behind `#if canImport(Foundation.NSMetadataQuery)` style guards and runs only on macOS) | `SearchRanker`, `SpotlightQueryBuilder`, `SearchService` protocol, `SpotlightSearchService`, `EnumerationSearchService` fallback. |
| `HelmPersistence` | library | Foundation, HelmCore | Yes | `SettingsStore`, `StarStore`, `BookmarkStore`, `RecentStore`, `SessionStore`, versioned JSON codecs, `UserDefaults` migration. |
| `HelmTestKit` | library | Foundation, XCTest, HelmCore, HelmFileSystem | Yes | Fixtures: in-memory trees, fake clock, fake monitor, snapshot builders, temp-dir helpers, assertion helpers. Test-only dependency. |
| `HelmUI` | library | AppKit, SwiftUI, Combine, QuickLookUI, QuickLookThumbnailing, UniformTypeIdentifiers, all core modules | No (macOS only) | Windows, toolbar, tabs, address bar, sidebar, grid, list, status bar, menus, sheets, settings windows, imaging caches, focus, drag and drop, Quick Look, undo bridge, operations panel. |
| `HelmApp` | library | AppKit, HelmUI and all core modules | No | `AppDelegate`, `WindowRegistry`, `OpenRequestRouter`, `LaunchSequence`, the composition root `AppEnvironment` that builds every store and service once and injects them. |
| `Helm` (SwiftPM executable) | executable | HelmApp | No | `main.swift` only: `NSApplication` bootstrap for `swift run` during development. |
| `Helm.app` (Xcode target from `project.yml`) | application | HelmApp | No | Signed bundle with Info.plist, entitlements, asset catalog. Its only source file is the same `main.swift`. |

Test targets: `HelmCoreTests`, `HelmFileSystemTests`, `HelmOperationsTests`, `HelmSearchTests`, `HelmPersistenceTests` (all Linux-capable), `HelmUITests` (macOS, XCTest unit tests for view adapters), and `HelmUIAutomationTests` (XCUITest, Xcode target only).

### 3.2 Dependency graph

```
                 ┌──────────────┐
                 │   HelmCore   │  Foundation only
                 └──────┬───────┘
                        │
        ┌───────────────┼────────────────────┐
        ▼               ▼                    ▼
┌───────────────┐ ┌───────────────┐  ┌────────────────┐
│HelmFileSystem │ │HelmPersistence│  │  HelmTestKit   │ (tests only)
└──────┬────────┘ └──────┬────────┘  └────────────────┘
       │                 │
   ┌───┴─────────┐       │
   ▼             ▼       │
┌────────────┐ ┌────────────┐
│HelmOperat. │ │ HelmSearch │
└──────┬─────┘ └─────┬──────┘
       │             │
       └──────┬──────┘───────────┐
              ▼                  │
         ┌─────────┐             │
         │ HelmUI  │ AppKit, SwiftUI
         └────┬────┘             │
              ▼                  │
         ┌─────────┐             │
         │ HelmApp │◀────────────┘ (HelmApp also imports HelmPersistence for the composition root)
         └────┬────┘
              ▼
   ┌──────────────────────┐
   │ Helm (exe) / Helm.app│
   └──────────────────────┘
```

Rules that keep the graph acyclic and compiler-enforced:

- `HelmCore` imports nothing but Foundation. The `FileSystem` protocol lives in `HelmFileSystem`; `HelmCore` types never reference it.
- `HelmFileSystem` and `HelmPersistence` depend only on `HelmCore` and do not know about each other.
- `HelmOperations` and `HelmSearch` depend on `HelmCore` and `HelmFileSystem`, never on each other or on persistence.
- Only `HelmUI` and `HelmApp` may contain `import AppKit`, `import SwiftUI`, `import Cocoa`, `import QuickLookUI`, `import QuickLookThumbnailing`. A CI grep over the other targets enforces this (section 11.6).
- `UniformTypeIdentifiers` is not imported in `HelmCore`; `FileEntry.contentTypeIdentifier` is a `String?` and the `UTType` accessor is an extension in `HelmUI`.
- `CoreServices` (FSEvents) is imported only in `HelmFileSystem` behind `#if canImport(CoreServices)`; the polling monitor is the Linux and last-resort implementation.

### 3.3 Directory layout

```
Helm/                                   repository root
├── Package.swift                       the one SwiftPM manifest (section 3.4)
├── project.yml                         XcodeGen spec for Helm.app and the XCUITest target
├── README.md
├── docs/rebuild/
├── Sources/
│   ├── HelmCore/
│   │   ├── Identity/        ItemID.swift, Location.swift, LocationKind.swift
│   │   ├── Model/           FileEntry.swift, FileEntryKind.swift, SortDescriptor.swift, ViewMode.swift, ChangeToken.swift
│   │   ├── Snapshot/        PresentationSnapshot.swift, TreeSnapshot.swift, SnapshotDiff.swift, SnapshotBuilder.swift, SnapshotPhase.swift
│   │   ├── Tab/             TabState.swift, TabAction.swift, TabReducer.swift, TabEffect.swift, NavigationHistory.swift, SearchState.swift, OpenPolicy.swift
│   │   ├── Window/          WindowState.swift, TabListReducer.swift
│   │   ├── AddressBar/      PathEntry.swift, PathCompletionEngine.swift, CompletionRow.swift
│   │   ├── Naming/          FileNameValidator.swift, ValidFileName.swift, UniqueNamer.swift, BatchRenamePlanner.swift, RenameToken.swift
│   │   ├── Places/          Place.swift, PlacesModel.swift, VolumeFilter.swift, VolumeInfo.swift
│   │   ├── Settings/        SettingsSchema.swift, SettingKey.swift, SettingsSnapshot.swift
│   │   ├── Text/            StatusText.swift, TypeSelect.swift, ByteCountText.swift
│   │   └── Support/         Generation.swift, Clock.swift, Debouncer.swift
│   ├── HelmFileSystem/
│   │   ├── Protocol/        FileSystem.swift, DirectoryMonitor.swift, FileSystemError.swift, EnumerationOptions.swift
│   │   ├── Live/            LiveFileSystem.swift, DirectoryEnumerator.swift, MetadataReader.swift, IOExecutor.swift
│   │   ├── Monitor/         FSEventsMonitor.swift, DispatchSourceMonitor.swift, PollingMonitor.swift, EventCoalescer.swift, MonitorRegistry.swift
│   │   ├── Fake/            InMemoryFileSystem.swift, InMemoryMonitor.swift
│   │   ├── Providers/       CompletionProvider.swift, VolumeProvider.swift, TemplateProvider.swift, ApplicationProvider.swift, PropertiesLoader.swift
│   │   └── Virtual/         LocationSource.swift, DirectoryLoader.swift, RecentSource.swift, TrashSource.swift, ListingCache.swift
│   ├── HelmOperations/
│   │   ├── Plan/            Command.swift, OperationPlan.swift, OperationPlanner.swift, ConflictPolicy.swift, DropPlanner.swift, PlanningContext.swift
│   │   ├── Execute/         OperationExecutor.swift, OperationProgress.swift, ItemOutcome.swift, OperationResult.swift, ProgressEstimator.swift
│   │   ├── Journal/         OperationJournal.swift, JournalEntry.swift, UndoPlanner.swift
│   │   ├── Trash/           TrashCoordinator.swift, PutBackResolver.swift
│   │   └── Clipboard/       ClipboardState.swift, ClipboardTransaction.swift
│   ├── HelmSearch/
│   │   ├── SearchService.swift, SearchQuery.swift, SearchResult.swift
│   │   ├── Rank/            SearchRanker.swift, RankingWeights.swift, PreferredRoots.swift
│   │   ├── Spotlight/       SpotlightQueryBuilder.swift, SpotlightSearchService.swift
│   │   └── Fallback/        EnumerationSearchService.swift
│   ├── HelmPersistence/
│   │   ├── SettingsStore.swift, StarStore.swift, BookmarkStore.swift, RecentStore.swift, SessionStore.swift
│   │   ├── Codec/           VersionedDocument.swift, JSONFileStore.swift
│   │   └── Migration/       LegacyDefaultsMigrator.swift, MigrationStep.swift
│   ├── HelmTestKit/
│   │   ├── Fixtures/        TreeFixture.swift, FakeClock.swift, SnapshotFixtures.swift, TempDirectory.swift
│   │   └── Assertions/      SnapshotAssertions.swift, OutcomeAssertions.swift
│   ├── HelmUI/
│   │   ├── Window/          MainWindowController.swift, MainSplitViewController.swift, ToolbarFactory.swift, WindowStateBinder.swift
│   │   ├── Tabs/            TabContainerController.swift, TabBarView.swift, TabButton.swift
│   │   ├── AddressBar/      AddressBarView.swift, BreadcrumbView.swift, AddressEditor.swift, CompletionPanel.swift, GhostOverlay.swift, AddressBarController.swift
│   │   ├── Sidebar/         SidebarContainerController.swift, SidebarPlacesView.swift, SidebarViewModel.swift
│   │   ├── Content/         ContentHostController.swift, GridView.swift, GridItem.swift, ListView.swift, ListNode.swift, StatusBarView.swift, DragDropCoordinator.swift, QuickLookCoordinator.swift, SelectionBinder.swift, ItemActivation.swift
│   │   ├── Commands/        CommandDispatcher.swift, ClipboardCommands.swift, UndoBridge.swift, MenuValidation.swift
│   │   ├── Menus/           MainMenuBuilder.swift, ContextMenuBuilder.swift
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
├── App/                                bundle resources, consumed by project.yml only
│   ├── Info.plist
│   ├── Helm.entitlements
│   └── Assets.xcassets/
├── Tests/
│   ├── HelmCoreTests/  HelmFileSystemTests/  HelmOperationsTests/  HelmSearchTests/  HelmPersistenceTests/  HelmUITests/
└── UITests/
    └── HelmUIAutomationTests/          XCUITest, Xcode only
```

The current `Helm/Helm/...` tree is deleted on the rebuild branch once the new tree compiles (ADR-007). It stays reachable through git history for behaviour reference.

### 3.4 Package.swift sketch

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Helm",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Helm", targets: ["Helm"]),
        .library(name: "HelmApp", targets: ["HelmApp"])
    ],
    targets: [
        .target(name: "HelmCore"),
        .target(name: "HelmFileSystem", dependencies: ["HelmCore"]),
        .target(name: "HelmPersistence", dependencies: ["HelmCore"]),
        .target(name: "HelmOperations", dependencies: ["HelmCore", "HelmFileSystem"]),
        .target(name: "HelmSearch", dependencies: ["HelmCore", "HelmFileSystem"]),
        .target(name: "HelmTestKit", dependencies: ["HelmCore", "HelmFileSystem"]),
        .target(
            name: "HelmUI",
            dependencies: ["HelmCore", "HelmFileSystem", "HelmOperations", "HelmSearch", "HelmPersistence"]
        ),
        .target(
            name: "HelmApp",
            dependencies: ["HelmUI", "HelmCore", "HelmFileSystem", "HelmOperations", "HelmSearch", "HelmPersistence"]
        ),
        .executableTarget(name: "Helm", dependencies: ["HelmApp"]),

        .testTarget(name: "HelmCoreTests", dependencies: ["HelmCore", "HelmTestKit"]),
        .testTarget(name: "HelmFileSystemTests", dependencies: ["HelmFileSystem", "HelmTestKit"]),
        .testTarget(name: "HelmOperationsTests", dependencies: ["HelmOperations", "HelmTestKit"]),
        .testTarget(name: "HelmSearchTests", dependencies: ["HelmSearch", "HelmTestKit"]),
        .testTarget(name: "HelmPersistenceTests", dependencies: ["HelmPersistence", "HelmTestKit"]),
        .testTarget(name: "HelmUITests", dependencies: ["HelmUI", "HelmTestKit"])
    ],
    swiftLanguageVersions: [.v5]
)
```

Notes for the author:

- No `swiftSettings` with upcoming or experimental features. Strict concurrency is enabled at *targeted* level in the Xcode target (`SWIFT_STRICT_CONCURRENCY: targeted`) so the handoff session sees diagnostics without being blocked by them.
- `HelmUI` and `HelmApp` compile only on macOS. On Linux the supported commands are `swift build --target HelmCore` (and the other four core modules) and `swift test --filter HelmCoreTests` and so on. A bare `swift build` on Linux fails at `HelmUI`; this is expected and documented in the README.
- `platforms: [.macOS(.v14)]` applies to the Mac build; Linux ignores it.

### 3.5 Xcode app target and XcodeGen

`project.yml` describes exactly two targets:

```yaml
name: Helm
options:
  bundleIdPrefix: com.helm
  deploymentTarget:
    macOS: "14.0"
  xcodeVersion: "16.0"
packages:
  HelmPackage:
    path: .
targets:
  Helm:
    type: application
    platform: macOS
    sources:
      - path: Sources/Helm            # main.swift only
      - path: App/Assets.xcassets
    dependencies:
      - package: HelmPackage
        product: HelmApp
    info:
      path: App/Info.plist
    entitlements:
      path: App/Helm.entitlements
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.helm.filemanager
        PRODUCT_NAME: Helm
        SWIFT_VERSION: "5"
        SWIFT_STRICT_CONCURRENCY: targeted
        MACOSX_DEPLOYMENT_TARGET: "14.0"
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
        ENABLE_HARDENED_RUNTIME: YES
        CODE_SIGN_STYLE: Automatic
        LD_RUNPATH_SEARCH_PATHS: "$(inherited) @executable_path/../Frameworks"
  HelmUIAutomationTests:
    type: bundle.ui-testing
    platform: macOS
    sources:
      - path: UITests/HelmUIAutomationTests
    dependencies:
      - target: Helm
    settings:
      base:
        SWIFT_VERSION: "5"
```

Single-source-of-truth rules:

- All compiled code lives in the package. The app target has one source file so the SwiftPM executable and the bundled app can never diverge in source membership (fixes B-001).
- `Helm.xcodeproj` is not committed; `.gitignore` lists it. The README build steps are `xcodegen generate` then Xcode or `xcodebuild`.
- Unit tests run through SwiftPM on both platforms; Xcode runs the same package test targets because the package is a dependency. The only Xcode-exclusive target is XCUITest.
- `Info.plist` and `Helm.entitlements` live under `App/` so SwiftPM never sees them. The asset catalog is attached to the Xcode target; the SwiftPM executable does not process it, because `swift run` is a development convenience and the bundled app is the product.
- `Info.plist` keeps its current content (`NSPrincipalClass` `NSApplication`, no main nib, the five usage descriptions, the `public.folder` Alternate viewer type) and adds `NSSupportsSuddenTermination` false and `LSApplicationCategoryType` `public.app-category.utilities`.
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
}

public struct TabState: Sendable, Equatable {
    public let id: TabID
    public var location: Location
    public var history: NavigationHistory
    public var selection: Set<ItemID>
    public var anchorID: ItemID?                 // first visible item, restored on view-mode switch
    public var viewMode: ViewMode
    public var sort: SortDescriptor
    public var showHidden: Bool
    public var expandedIDs: Set<ItemID>          // list-view expansion
    public var search: SearchState?              // nil when not searching
    public var snapshot: PresentationSnapshot
    public var loadGeneration: Generation
    public var monitorGeneration: Generation
    public var addressBar: AddressBarState       // editing text, completion rows, popup visibility
}

public struct WindowState: Sendable, Equatable {
    public var tabs: [TabID]
    public var activeTabID: TabID
    public var isSidebarVisible: Bool
    public var activeOperationIDs: [OperationID]
}
```

`NavigationHistory` is the current `NavigationState` turned into a value type with the same semantics plus a dedupe rule:

```swift
public struct NavigationHistory: Sendable, Equatable, Codable {
    public struct Entry: Sendable, Equatable, Codable {
        public let location: Location
        public let selection: Set<ItemID>
    }
    public private(set) var back: [Entry]
    public private(set) var forward: [Entry]
    public var canGoBack: Bool { get }
    public var canGoForward: Bool { get }
    public mutating func push(current: Entry, movingTo location: Location) -> Bool   // false when location == current.location
    public mutating func goBack(current: Entry) -> Entry?
    public mutating func goForward(current: Entry) -> Entry?
}
```

### 4.2 The presentation snapshot

The snapshot is the only thing views read. It is immutable, built off the main actor, and replaced wholesale.

```swift
public enum SnapshotPhase: Hashable, Sendable {
    case loading(loadedCount: Int)
    case ready
    case failed(LoadError)
}

public enum LoadError: Hashable, Sendable {
    case notFound, permissionDenied, volumeUnmounted, notIndexed, cancelled, other(String)
}

public struct TreeChildren: Hashable, Sendable {
    public let phase: SnapshotPhase
    public let sortedIDs: [ItemID]
}

public struct PresentationSnapshot: Sendable, Equatable {
    public let id: Generation
    public let location: Location
    public let phase: SnapshotPhase
    public let sort: SortDescriptor                 // .relevance for search results
    public let entries: [ItemID: FileEntry]
    public let sortedIDs: [ItemID]                  // root level, in display order
    public let indexByID: [ItemID: Int]
    public let children: [ItemID: TreeChildren]     // expanded folders (list view)
    public let rankByID: [ItemID: Int]?             // search results only
    public let freeCapacityBytes: Int64?

    public func entry(_ id: ItemID) -> FileEntry?
    public func index(of id: ItemID) -> Int?
    public var rootCount: Int { get }
    public func visibleIDs(expanding expanded: Set<ItemID>) -> [ItemID]   // flattened for the outline
}
```

Equality is defined on `id` only, so Combine's `removeDuplicates()` is cheap. `SnapshotBuilder` (pure) produces snapshots from `[FileEntry]` plus sort, hidden flag and star set; `SnapshotDiff` (pure) computes inserted, removed and moved IDs between two snapshots for animated updates when both are under 5,000 root items; above that, widgets call `reloadData()`.

Why this removes B-009, B-010, B-011, B-033 and B-101 at once: the widget's datasource methods take `indexPath.item` or `row`, look up `sortedIDs[index]` in the snapshot the widget was last given, and return the entry. Nothing is sorted on access; nothing is indexed into a mutable array; selection maps through `indexByID` in O(k).

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
    case loadStarted(Generation)
    case loadProgress(Generation, [FileEntry])
    case loadFinished(Generation, PresentationSnapshot)
    case loadFailed(Generation, LoadError)
    case monitorEvent(Generation, MonitorEvent)
    case setSelection(Set<ItemID>, source: SelectionSource)
    case setSort(SortDescriptor)
    case setViewMode(ViewMode)
    case toggleHidden
    case expand(ItemID), collapse(ItemID), childrenLoaded(ItemID, Generation, [FileEntry])
    case searchTextChanged(String), searchResults(Generation, [SearchResult]), searchEnded
    case addressBar(AddressBarAction)
    case refresh
    case operationCompleted(OperationResult)
}

public enum TabEffect: Sendable, Equatable {
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
}

public enum TabReducer {
    public static func reduce(_ state: TabState, _ action: TabAction, context: ReducerContext) -> (TabState, [TabEffect])
}
```

`ReducerContext` carries the clock, the home URL, the current star set and the settings snapshot so the reducer stays pure and testable. The entire navigation, history, selection restoration, search lifecycle, hidden toggle and address-bar state machine are therefore unit-tested on Linux.

### 4.4 Observation choice

Conservative choice: **Combine `ObservableObject` with `@Published`**, not the Observation framework, not bespoke closures. Reasons (ADR-003):

- Combine and `@Published` are available on macOS 14, stable since 2019, and have no macro expansion that could fail blind.
- AppKit controllers observe with `store.$state.removeDuplicates().sink { [weak self] state in ... }.store(in: &cancellables)`. Because the store is `@MainActor` and publishes on the main actor, no `receive(on:)` is needed; one `assertMain` in debug guards it.
- SwiftUI islands (`SidebarPlacesView`, `PropertiesView`, `BatchRenameView`, `OperationsPanelView`, settings views) take `@ObservedObject var model: SomeViewModel` where the view model is a `@MainActor ObservableObject` adapter owned by the hosting controller.
- Closures are used only for one-shot callbacks (`onCommit`, `onCancel`) from a view to its controller, never for broadcasting state.

Controllers diff fields to avoid redundant work: `if old.snapshot.id != new.snapshot.id { reloadOrDiff() }`, `if old.selection != new.selection { applySelection() }`. The previous state is kept in the controller.

### 4.5 Concurrency model

- **Main actor:** every store, controller, view, view model, the undo bridge, the icon and thumbnail caches (their lookups), menu and toolbar code, `NSMetadataQuery` ownership. Annotated `@MainActor` at the class level.
- **Actors:** `LiveFileSystem` work runs on `IOExecutor` (a serial-executor-free design: an actor that wraps a `DispatchQueue` with a concurrent attribute and bounded concurrency through `DispatchSemaphore` is error-prone; instead every blocking call is performed inside `Task.detached(priority:)` closures dispatched to a private `OperationQueue` with `maxConcurrentOperationCount = 4` and bridged with `withCheckedThrowingContinuation`). This keeps blocking `FileManager` calls off the cooperative pool (B-107). `MonitorRegistry`, `ListingCache`, `CompletionProvider`, `OperationExecutor` and `RecentStore` are `actor` types holding only Sendable state.
- **Sendable rules:** everything in `HelmCore`, `HelmFileSystem`, `HelmOperations`, `HelmSearch` and `HelmPersistence` public API is a `struct` or `enum` with Sendable members, or an actor, or a `final class` marked `@MainActor`. `NSImage`, `NSURL`, `NSMetadataItem` never cross an actor boundary; images are created and cached only on the main actor or on the imaging queue and delivered via `@MainActor` continuations. No `@unchecked Sendable` outside two documented places: the FSEvents callback context box and the `OperationQueue` bridge.
- **Cancellation:** each `TabStore` keeps `loadTask`, `childrenTasks: [ItemID: Task<Void, Never>]`, `searchTask`, `monitorTask`, `completionTask`. Starting a new one cancels the old one. Results carry the `Generation` they were started with; `TabStore.commit(_ action: TabAction, for generation: Generation)` ignores actions whose generation is older than the current one for that lane. Enumerators check `Task.isCancelled` between batches. No `runModal()` from inside a task; alerts are presented with `beginSheetModal(for:completionHandler:)` and the completion feeds back an action (B-086).
- **Lifetimes:** stores are owned by controllers; controllers are owned by the window controller; the window controller is owned by `WindowRegistry`. `deinit` cancels tasks and stops monitors. `Task { [weak self] in }` is the only allowed capture form inside controllers.

---

## 5. Async file-system layer

### 5.1 Protocols

```swift
// HelmFileSystem
public struct EnumerationOptions: Sendable, Equatable {
    public var includeHidden: Bool
    public var batchSize: Int                 // default 512
    public var resolveSymlinkTargets: Bool    // default true
}

public protocol FileSystem: Sendable {
    func enumerate(_ directory: URL, options: EnumerationOptions) -> AsyncThrowingStream<[FileEntry], Error>
    func entry(at url: URL) async throws -> FileEntry
    func exists(_ url: URL) async -> Bool
    func isDirectory(_ url: URL, resolvingSymlinks: Bool) async -> Bool
    func childNames(of directory: URL) async throws -> Set<String>     // for collision planning
    func copyItem(at source: URL, to destination: URL) async throws
    func moveItem(at source: URL, to destination: URL) async throws
    func trashItem(at url: URL) async throws -> URL
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
}

public struct FileEntry: Hashable, Sendable, Identifiable, Codable {
    public let id: ItemID
    public let url: URL
    public let name: String
    public let kind: FileEntryKind
    public let isHidden: Bool
    public let isReadable: Bool
    public let size: Int64
    public let modificationDate: Date
    public let creationDate: Date
    public let contentTypeIdentifier: String?
    public let volumeIdentifier: String?
    public var isStarred: Bool
    public var isDirectoryLike: Bool { get }         // directory or symlinkToDirectory
    public var changeToken: ChangeToken { get }
}
```

Identity is the standardized path. A rename produces a new ID; the journal records the mapping so selection follows renamed items. Equality includes all fields (the audit's caution about URL-only equality, 00b A-7), so a diff detects metadata changes.

Prefetch keys read in one `resourceValues(forKeys:)` call: `.nameKey`, `.isDirectoryKey`, `.isSymbolicLinkKey`, `.isAliasFileKey`, `.isPackageKey`, `.isHiddenKey`, `.isReadableKey`, `.fileSizeKey`, `.totalFileSizeKey`, `.contentModificationDateKey`, `.creationDateKey`, `.contentTypeKey`, `.volumeIdentifierKey`. For symlinks, a second `resourceValues` on `url.resolvingSymlinksInPath()` determines `symlinkToDirectory` versus `danglingSymlink`.

### 5.3 Enumeration

`DirectoryEnumerator` wraps `FileManager.enumerator(at:includingPropertiesForKeys:options:errorHandler:)` with `.skipsSubdirectoryDescendants` and, when hidden files are off, `.skipsHiddenFiles`. It yields batches of 512 `FileEntry` values and checks cancellation between batches. The first batch is yielded as soon as it is full or 50 ms have elapsed, so a slow network directory shows something quickly. Enumeration errors on individual entries are skipped; a failure to open the directory itself throws `FileSystemError.permissionDenied` or `.notFound`, which the reducer maps to `SnapshotPhase.failed`.

### 5.4 Large-folder strategy

| Size | Behaviour |
|---|---|
| up to 5,000 root items | Batches merged into a sorted array as they arrive (insertion through binary search per batch); `SnapshotDiff` drives animated inserts; selection preserved by ID. |
| 5,000 to 100,000 | Batches accumulated unsorted; the snapshot phase shows `.loading(loadedCount:)` with a count in the status bar; one sort at completion; `reloadData()` instead of diffing; thumbnails requested only for visible cells with a 100 ms scroll-settle delay. |
| above 100,000 | Same as above, plus the grid refuses live thumbnails until scrolling stops for 300 ms and the list disables alternating-row animation. No upper cap; `NSCollectionView` and `NSOutlineView` virtualize cells. |

Memory: a `FileEntry` is roughly 300 bytes including its URL and strings; 100k entries are about 30 MB per snapshot. `ListingCache` (actor) keeps at most 200,000 entries across all cached listings, evicting least recently used listings first, and is cleared on `DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical])`.

### 5.5 Caching and invalidation

`ListingCache` is keyed by `Location` and stores `(snapshotEntries, directoryChangeToken, timestamp)`. A navigation serves the cached listing immediately with phase `.ready` while a background revalidation enumerates; if the directory's own change token (modification date) differs or `helm.directoryCacheTTL` expired, the fresh result replaces it. Invalidation sources: monitor events for the directory, `OperationResult` touching the directory, explicit refresh, and setting `helm.enableDirectoryCache` to false (which also empties the cache).

### 5.6 Virtual locations and the search snapshot

```swift
public protocol LocationSource: Sendable {
    func load(_ location: Location, options: LoadOptions) -> AsyncThrowingStream<LoadEvent, Error>
    func monitor(_ location: Location) -> (any DirectoryMonitor)?
    var mutationTarget: URL? { get }
}
```

`DirectoryLoader` serves `.directory`; `RecentSource` serves `.recent` from `RecentStore` ordered by last access; `TrashSource` serves `.trash` by enumerating every trash directory; search results are produced by `HelmSearch` and committed as a snapshot with `sort == .relevance` and `rankByID`. `SnapshotBuilder` refuses to re-sort a `.relevance` snapshot by anything else, which is the structural fix for B-022; the user can still choose a column sort, at which point the snapshot sort changes explicitly and the rank is kept only as a tiebreaker.

### 5.7 Path completion service

```swift
// HelmCore, pure
public struct CompletionRow: Hashable, Sendable {
    public let name: String
    public let path: String        // absolute, normalized
    public let isDirectory: Bool
    public let isParentLink: Bool  // ".."
}
public enum PathCompletionEngine {
    public static func request(for text: String, currentDirectory: URL, home: URL) -> CompletionRequest?
    public static func rows(for request: CompletionRequest, children: [FileEntry], showHidden: Bool, limit: Int) -> [CompletionRow]
    public static func ghostSuffix(typed: String, selected: CompletionRow?, caretAtEnd: Bool) -> String?
    public static func tabAction(state: AddressBarState) -> AddressBarAction
    public static func returnAction(state: AddressBarState) -> AddressBarAction
}

// HelmFileSystem
public actor CompletionProvider {
    public init(fileSystem: any FileSystem)
    public func complete(_ request: CompletionRequest, generation: Generation, showHidden: Bool) async throws -> [CompletionRow]
}
```

The provider enumerates the parent with a `batchSize` of 64 and stops after the limit is satisfied, caches listings for 3 s and at most 30 directories as today, and never creates images. The panel asks `IconCache` for icons of visible rows only.

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

Keys are `ItemID` plus change token plus size. `QLThumbnailGenerator.shared.generateBestRepresentation(for:completion:)` is called with `QLThumbnailGenerator.Request(fileAt:size:scale:representationTypes: .thumbnail)` where size is in points and scale is the window backing scale, which fixes the 4× pixel request (B-056). Each key keeps a subscriber list; cancelling a token removes one subscriber and cancels the generator request only when the list empties (B-055). Cost accounting uses pixel bytes.

---

## 6. Directory monitoring

### 6.1 Mechanism choice

FSEvents remains the primary mechanism (ADR-004): it is the only API that reports which path changed, works for whole directories without an open file descriptor per watched node, and survives the watched directory being renamed when `kFSEventStreamCreateFlagWatchRoot` is set. Flags: `FileEvents | UseCFTypes | NoDefer | WatchRoot`, latency 0.3 s, `sinceWhen` now, dispatch queue utility. The current implementation's defects are fixed structurally:

- **Non-recursive scope.** `FileEvents` streams are recursive; `FSEventsMonitor` filters callback paths to the watched directory itself and its direct children (`path.deletingLastPathComponent == watched`). Deeper events are dropped unless the event carries `MustScanSubDirs` or `RootChanged` (B-073).
- **Shared streams.** `MonitorRegistry` (actor) refcounts monitors by directory path so two tabs on one directory share one stream, and so closing a tab stops nothing another tab still needs.
- **Generation tokens.** Each stream gets a monotonically increasing token; termination handlers compare tokens, not pointer values (B-104).
- **Failure handling.** `FSEventStreamCreate` or `FSEventStreamStart` failure falls back to `DispatchSourceMonitor` (a `DispatchSource.makeFileSystemObjectSource` on the directory's file descriptor with `[.write, .rename, .delete, .attrib]`), which reports coarse `.rescan` events; if that fails too (network volumes without vnode events), `PollingMonitor` compares the directory's modification date and child count every 3 s. Which mechanism is active is visible in the status bar tooltip for debugging (B-015).
- **Lifetime.** Handles stop, invalidate and release the stream in `deinit` (B-072).

```swift
public enum MonitorEvent: Hashable, Sendable {
    case changed(paths: Set<String>)          // watched directory or direct children
    case rescan
    case rootChanged(newPath: String?)
    case volumeUnmounted
    case unavailable(MonitorFailure)
}
public protocol DirectoryMonitor: Sendable {
    var events: AsyncStream<MonitorEvent> { get }
    func start() async throws
    func stop() async
}
```

### 6.2 Coalescing

`EventCoalescer` (pure, `HelmFileSystem/Monitor`, testable with a fake clock) merges events within a 250 ms quiet window and forces delivery at most every 1 s during sustained traffic, so a build writing continuously no longer starves refresh (B-016). `.rescan` and `.rootChanged` flush immediately.

### 6.3 Event-to-diff

`DirectoryLoader.refresh(location:changed:)` handles a `.changed(paths)` event by re-reading `FileEntry` for each listed path: a path that no longer exists becomes a removal, a path that is new becomes an insertion, a path whose change token differs becomes an update. The directory's own path in the set means an add or remove happened that FSEvents attributed to the parent; the loader then runs `childNames(of:)` and reconciles by name against the current snapshot before fetching metadata only for the differences. The result goes through `SnapshotBuilder.applying(changes:to:)` producing a new snapshot with the same sort and the same selection intersected by ID. `.rescan` performs a full reload through the cache. This keeps external changes to a 100k folder proportional to the number of changed items.

### 6.4 Mounts and permission loss

`VolumeProvider` (main actor, `NSWorkspace.shared.notificationCenter` `didMountNotification` and `didUnmountNotification`) feeds both the sidebar and `MonitorRegistry`. When a watched directory's volume unmounts, the registry emits `.volumeUnmounted`; the reducer sets `phase = .failed(.volumeUnmounted)` and keeps the location so Back still works; the content pane shows a "Volume is no longer available" state with a Go Home button. A `.permissionDenied` error from the loader produces the Full Disk Access guidance state (section 9). Monitoring is stopped while a tab is inactive and restarted with a `.rescan` on activation (B-013).

---

## 7. Undoable operations engine

### 7.1 Commands

```swift
// HelmOperations
public struct RenamePair: Hashable, Sendable { public let source: URL; public let newName: ValidFileName }
public struct TrashedItem: Hashable, Sendable, Codable { public let trashedURL: URL; public let originalURL: URL }

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
    public let existingNames: [URL: Set<String>]        // per destination directory
    public let volumeIDs: [URL: String]                 // per source and destination
    public let isDirectoryLike: [URL: Bool]
    public let defaultPolicy: ConflictPolicy
    public let crossVolumeMoveBehaviour: CrossVolumeMoveBehaviour   // .copyThenDeleteSource
}
```

`OperationPlanner.preflight` runs before any I/O and produces `[PlanningIssue]`: `.sourceEqualsDestination`, `.destinationInsideSource`, `.sameParentMove` (treated as no-op for move, keep-both duplicate for copy), `.overlappingSelection` (ancestor plus descendant, descendant dropped), `.virtualLocationTarget` (refused; B-031), `.invalidName`. The UI shows blocking issues before starting.

### 7.3 Conflict policy and the plan

```swift
public enum ConflictResolution: Hashable, Sendable { case keepBoth, replace, skip, stop }
public struct ConflictPolicy: Hashable, Sendable {
    public var defaultResolution: ConflictResolution        // keepBoth, matching current behaviour
    public var perItem: [URL: ConflictResolution]
    public var applyToAll: Bool
}

public struct PlannedStep: Hashable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable { case copyFile, copyDirectoryShell, moveSameVolume, moveCrossVolume, trash, remove, rename, createDirectory, createFile, link, alias, putBack }
    public let id: StepID
    public let kind: Kind
    public let source: URL?
    public let destination: URL?
    public let estimatedBytes: Int64
    public let conflict: Conflict?                  // destination exists; resolution applied
}

public struct OperationPlan: Sendable {
    public let command: Command
    public let steps: [PlannedStep]
    public let issues: [PlanningIssue]
    public let totalBytes: Int64
    public var isExecutable: Bool { get }
    public var summary: PlanSummary { get }         // for the conflict sheet and tests
}

public enum OperationPlanner {
    public static func plan(_ command: Command, context: PlanningContext) -> OperationPlan
    public static func resolve(_ plan: OperationPlan, with policy: ConflictPolicy) -> OperationPlan
}
```

`UniqueNamer` (pure, `HelmCore`) produces `name 2.ext`, `name 3.ext`, and treats a known multi-part extension list (`tar.gz`, `tar.bz2`, `tar.xz`, `tar.zst`) as a unit (B-116). Keep-both is the default so current behaviour is unchanged; Replace, Skip and Stop appear only in the conflict sheet, which the executor requests when a plan contains conflicts and the policy has no resolution. The planner is pure and fully testable on Linux with `InMemoryFileSystem` supplying the context.

### 7.4 Execution, progress, cancellation

```swift
public struct ItemOutcome: Sendable, Hashable {
    public let step: StepID
    public let source: URL?
    public let destination: URL?
    public let result: Result<ChangeToken?, OperationError>
}
public struct OperationResult: Sendable {
    public let id: OperationID
    public let command: Command
    public let outcomes: [ItemOutcome]
    public let affectedDirectories: Set<URL>
    public var succeededCount: Int { get }
    public var failedCount: Int { get }
    public var wasCancelled: Bool { get }
}
public struct OperationProgress: Sendable, Equatable {
    public let id: OperationID
    public let itemsDone: Int, itemsTotal: Int
    public let bytesDone: Int64, bytesTotal: Int64
    public let currentName: String?
    public let estimatedRemaining: TimeInterval?
}
public actor OperationExecutor {
    public init(fileSystem: any FileSystem)
    public func execute(_ plan: OperationPlan, policyResolver: @Sendable (Conflict) async -> ConflictResolution) -> (progress: AsyncStream<OperationProgress>, result: Task<OperationResult, Never>)
}
```

Rules: steps run sequentially; directories are copied as a created shell followed by per-file steps so progress and cancellation have file granularity; cross-volume move is copy, verify size, then remove source; same-volume move uses `moveItem` (rename semantics). `Task.isCancelled` is checked before each step. Partial failure never throws; every step produces an outcome (B-038). Cancellation leaves completed steps in place and reports them; the operations panel offers "Revert" which journals an inverse of the completed steps. `ProgressEstimator` (pure) computes ETA from an exponential moving average of bytes per second with a 2 s warm-up.

### 7.5 Names

```swift
// HelmCore
public struct ValidFileName: Hashable, Sendable, Codable {
    public let value: String
    public init?(_ raw: String)   // trims, rejects empty, "/", ":", NUL, ".", "..", and names over 255 UTF-8 bytes
}
public enum FileNameValidator {
    public static func validate(_ raw: String) -> Result<ValidFileName, FileNameError>
}
```

Rename and batch rename inputs reach the operations module only as `ValidFileName` (B-046). `BatchRenamePlanner.plan(items:rule:)` returns `[RenamePair]` plus an ordering that uses temporary names (`.helm-rename-<uuid>`) when targets overlap or swap (B-047).

### 7.6 Journal and undo semantics

```swift
public struct JournalEntry: Sendable, Identifiable {
    public let id: OperationID
    public let actionName: String                  // "Copy", "Move", "Move to Trash", ...
    public let forward: Command
    public let outcomes: [ItemOutcome]             // exact sources and destinations
    public let completedAt: Date
}
@MainActor public final class OperationJournal {
    public init(executor: OperationExecutor, fileSystem: any FileSystem, undoManager: UndoManager)
    public func record(_ result: OperationResult)
    public func undo() async -> OperationResult?
    public func redo() async -> OperationResult?
    public var canUndo: Bool { get }
    public var canRedo: Bool { get }
    public var undoActionName: String? { get }
}
public enum UndoPlanner {
    public static func inverse(of entry: JournalEntry, currentTokens: [URL: ChangeToken?]) -> Command?
}
```

Inverse mapping: copy and duplicate become `trash(destinations)` (never `removeItem`; B-041), and the journal warns first if any destination's change token differs from the recorded one; move becomes move back to the exact original URLs (B-042); trash becomes `putBack` using recorded trash URLs; rename and batch rename invert pairwise with temporary names where needed; createFolder and createFile become trash; makeAlias and makeSymbolicLink become trash; putBack becomes trash; emptyTrash and deletePermanently are not undoable and clear the stack with a confirmation. Redo re-executes the forward command through the same planner so it respects conflicts that appeared meanwhile.

The `UndoManager` instance belongs to the window and is created by `MainWindowController`; `windowWillReturnUndoManager(_:)` returns it only when the first responder is not an `NSTextView`, so field-editor typing keeps its own stack (00b C-39). `UndoBridge` registers `registerUndo(withTarget: journal) { journal in ... }` with `setActionName`; `OperationJournal.deinit` calls `removeAllActions(withTarget: self)` (B-100). The journal entry is created before the awaited execution starts, so a tab hidden mid-operation still records (B-105). Undo and redo run as tracked operations in the operations panel and refresh affected directories through the monitor plus an explicit `.refresh` on the originating tab (B-043).

### 7.7 Clipboard semantics

```swift
public struct ClipboardState: Sendable, Equatable {
    public let urls: [URL]
    public let isCut: Bool
    public let changeCount: Int           // NSPasteboard.general.changeCount at write time
}
public struct ClipboardTransaction: Sendable {
    public let sources: [URL]
    public let isMove: Bool
    public let destination: URL
    public func command() -> Command
}
```

Copy and Cut write `NSURL` objects to the general pasteboard and record `ClipboardState`. Paste reads the pasteboard's current `changeCount`; if it differs from the recorded one, the internal state is discarded and the pasteboard URLs are treated as a copy (B-036). Reads use `readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])` (B-106). After a successful move the cut state is cleared and the pasteboard is left untouched; after a partial failure the failed sources remain marked cut (B-037). Cut items are drawn at 50 % opacity in both views. Paste with a cut source into the same directory is a no-op; with a copied source it is a duplicate with keep-both naming. Menu validation enables Paste only when a file-URL read would succeed and the location has a mutation target (00b C-23).

### 7.8 Trash and Put Back

`TrashCoordinator` lists trash directories: `~/.Trash` plus `/Volumes/<name>/.Trashes/<uid>` for mounted volumes. Move to Trash uses `trashItem(at:resultingItemURL:)` and records `TrashedItem` pairs in the journal and in `RecentStore`'s companion `trash-origins.json` so Put Back works across launches for items Helm trashed. Items trashed by other apps show Put Back disabled (no public API for Finder's put-back record). Empty Trash enumerates each trash directory and removes items with a confirmation sheet; it is not undoable and clears the journal. Without Full Disk Access, `~/.Trash` enumeration fails with EPERM and the Trash location shows the permission state (B-109).

### 7.9 Drops and the dry-run planner

`DropPlanner.proposal(sources:destination:modifiers:volumeIDs:)` (pure) returns `.move`, `.copy` or `.none` with the reason, honouring Finder's defaults: same volume moves, cross volume copies, Option forces copy, Cmd forces move, and the drag source's `draggingSourceOperationMask` is intersected (B-045). The resulting `Command` goes through `OperationPlanner.plan` exactly like a Paste, so drags are journaled (B-044). Every command can be dry-run: `OperationPlanner.plan` has no side effects and its `PlanSummary` is what the conflict sheet shows and what tests assert on.

---

## 8. View layer

### 8.1 AppKit, SwiftUI or hybrid

Hybrid, AppKit-dominant (ADR-002): AppKit for the window, split view, toolbar, tabs, address bar, grid, list, status bar, menus, drag and drop, Quick Look and focus; SwiftUI islands for the sidebar list, the Properties and Batch Rename sheets, the conflict sheet, the operations panel and the settings forms.

Performance justification for the content pane: `NSCollectionView` and `NSOutlineView` recycle cells and lay out only visible rows, so a 100k-item snapshot costs memory for entries, not for views. They provide native rubber-band and keyboard selection, type-select, inline editing, drag sessions with `NSPasteboardWriting`, accessibility roles and `reloadData` or batch updates with stable identity through the snapshot. SwiftUI `List` and `LazyVGrid` on macOS 14 do not expose first-responder control, type-select, inline rename, drag session operation masks, or incremental batch updates by identity, and their diffing cost grows with the number of rows handed to them. Their known scrolling stalls on tens of thousands of rows would reintroduce the B-010 class at the view layer.

Grid uses `NSCollectionView` with `NSCollectionViewFlowLayout` rather than an `NSTableView` with one wide column (ADR-008): the flow layout gives per-cell selection, variable icon sizes, rubber-band selection and drop-on-item highlighting without custom hit testing.

### 8.2 Window, tabs, split

- `MainWindowController` (`NSWindowController`, `NSWindowDelegate`, `NSMenuItemValidation`, `NSToolbarItemValidation`, `NSToolbarDelegate`) owns `WindowStore`, the `OperationJournal`, the `UndoManager`, `FocusCoordinator`, `SheetPresenter`, the toolbar and the `MainSplitViewController`.
- `MainSplitViewController` (`NSSplitViewController`) holds the sidebar item and the content item; the content item's view controller is `TabContainerController`.
- `TabContainerController` keeps one retained `ContentHostController` per tab in a dictionary keyed by `TabID` and swaps the active one as a child view controller. It calls `activate()` and `deactivate()` explicitly on switch rather than relying on `viewWillAppear` (B-013), and the `WindowStore` publishes the active tab so the toolbar, address bar, title and `representedURL` all follow it (B-020).
- `ContentHostController` hosts exactly one of `GridView` or `ListView`, the `StatusBarView`, the `QuickLookCoordinator`, the `DragDropCoordinator` and the `SelectionBinder`. It applies `TabState` and translates widget events into `TabAction`s.

### 8.3 Keyboard handling and command routing

Menus are built in code by `MainMenuBuilder` with `target: nil` so the responder chain decides. Commands are `@objc` selectors declared once on `CommandDispatcher` (an `NSResponder` subclass inserted between the window and the content controller) and implemented by forwarding to the `TabStore` or the journal:

```swift
@MainActor public final class CommandDispatcher: NSResponder, NSMenuItemValidation {
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
    @objc public func toggleSidebar(_ sender: Any?)
    @objc public func focusSearch(_ sender: Any?)
    @objc public func clearRecent(_ sender: Any?)
    @objc public func emptyTrash(_ sender: Any?)
    @objc public func putBack(_ sender: Any?)
    public func validateMenuItem(_ item: NSMenuItem) -> Bool
}
```

Cut, Copy, Paste and Select All keep the `NSText` selectors so text views win; `CommandDispatcher` implements `cut(_:)`, `copy(_:)`, `paste(_:)` and `selectAll(_:)` for the file pane and validates them against `TabState` and the clipboard (00b 5.5 item 3). `validateMenuItem` sets `state` for Show Hidden Files and the view-mode items and enables Back and Forward from `history` (B-075). Rename on bare Return validates that the pane is first responder and exactly one item is selected (B-118). Toolbar items validate through `validateToolbarItem(_:)`.

Keys that are not menu equivalents (Space, Return in the pane, arrow keys for type-select) are handled in `ContentHostController.keyDown(with:)` only when `window.firstResponder` is the grid or list; everything else calls `super`. `AddressEditor` handles Tab, Shift+Tab, Return, Esc and arrows in `control(_:textView:doCommandBy:)` and returns `false` for everything else.

### 8.4 Drag and drop

`DragDropCoordinator` implements the `NSCollectionViewDelegate` and `NSOutlineViewDataSource` drag methods. Sources write `NSURL` through `pasteboardWriterForItem`. Validation calls `DropPlanner` with the item under the pointer (resolved by ID), the `draggingSourceOperationMask`, the modifier flags from `draggingInfo`, and the volume IDs cached in the snapshot entries; it returns the `NSDragOperation` to display and never coerces the proposal to an insertion gap (B-074). Acceptance returns `true` after dispatching a `Command` to the journal and shows failures through the operations panel. Drops onto a row inside an expanded subfolder resolve the row's parent through `TreeSnapshot` (B-079). Sidebar drops remain bookmark-only.

### 8.5 Focus model

`FocusCoordinator` owns these transitions (B-102, B-108, B-112):

| Event | First responder becomes |
|---|---|
| Window shown, tab switched, view mode switched, load finished with no editor active | the active content widget |
| Cmd+L or segment edit click | the address editor field |
| Address editor ends (commit, cancel, Esc, outside click, programmatic move) | the active content widget |
| Cmd+F | the search field; the address editor, if open, ends editing without navigating |
| Sheet dismissed | whatever was first responder before the sheet |

`initialFirstResponder` is the content widget; `nextKeyView` loop is sidebar → address editor (when present) → content widget → search field. New bindings added to the keyboard contract: Cmd+O and Cmd+Down open the selection; Option+Cmd+Backspace deletes permanently (with confirmation); Shift+Cmd+Backspace empties the Trash; Cmd+Shift+] and Cmd+Shift+[ switch tabs (seam; implemented only if section 14 Q6 says yes).

### 8.6 Sheets, Quick Look, accessibility

- `SheetPresenter` is the only way to show a sheet: it creates the `NSHostingController`, keeps a strong reference, presents with `presentAsSheet`, and dismisses through `dismiss(hostingController)` from the completion closure (B-117).
- `QuickLookCoordinator` makes `ContentHostController` accept panel control, serves selected IDs in display order from the snapshot, calls `reloadData()` on the panel when selection changes, forwards arrow keys through `previewPanel(_:handle:)`, and returns the item's cell frame for the zoom animation.
- Accessibility: tab buttons expose `accessibilityRole = .radioButton` within a `.radioGroup`, the address editor is labelled "Location" and its popup "Location suggestions", grid items are accessibility elements with the file name as label and "selected" state, the status bar is a static text, and an invalid path posts an `announcementRequested` notification with the error text (B-061).

---

## 9. Sandboxing, entitlements and Full Disk Access

**Decision (ADR-006): not sandboxed, hardened runtime, Developer ID signed, distributed by direct download.** A file manager that aims to replace Finder must browse any mounted volume, `~/Library`, other users' readable folders, `/Volumes/*/.Trashes` and arbitrary paths typed into the address bar. Under App Sandbox every one of those needs a user-granted security-scoped bookmark, which contradicts the typed-path interaction that defines Helm. App Store eligibility is therefore given up, which is acceptable for a single-user personal tool.

Consequences:

- `App/Helm.entitlements` stays an empty dictionary. No `com.apple.security.app-sandbox`, no `files.user-selected` entitlement.
- Bookmarks, stars and recents stay plain standardized paths. `BookmarkStore` keeps an optional `bookmarkData` field reserved for a future sandboxed variant; it is unused and `nil` in this build. The `AccessBroker` protocol in `HelmFileSystem` has one method, `access(_ url: URL) async -> AccessGrant`, with a trivial implementation; a sandboxed build would replace it.
- TCC still applies: Desktop, Documents, Downloads, removable and network volumes prompt through the usage strings already in Info.plist; `~/.Trash`, `~/Library/Mail`, Safari data and Time Machine backups require Full Disk Access.
- Permission-recovery UX: a load that fails with EPERM or EACCES produces `SnapshotPhase.failed(.permissionDenied)`. The content pane shows "Helm needs Full Disk Access to show this folder" with an "Open Privacy Settings" button that calls `NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)` built from a validated constant (the one place a URL literal is allowed, wrapped in a helper that returns `URL?`). A "Try Again" button re-dispatches `.refresh`. The same state appears for the Trash location. The status bar shows "No access" instead of an item count. Such a load does not enter history, does not record Recent, and does not update the window's `representedURL`.
- Development: `swift run` attributes TCC prompts to the terminal (00b C-27 inference); the README tells the owner to grant Full Disk Access to the built `Helm.app` and to test permission flows only with the bundled app.

---

## 10. Persistence and settings

### 10.1 Settings

One `SettingsSchema` in `HelmCore` declares every key with type, default, range and whether changing it applies live:

| Key | Type, default, range | Consumers (live) |
|---|---|---|
| `helm.defaultViewMode` | string, `grid` | new tabs |
| `helm.showHiddenFiles` | bool, false | new tabs; Cmd+. writes it |
| `helm.confirmBeforeTrash` | bool, true | trash command (live) |
| `helm.defaultSortField`, `helm.defaultSortAscending`, `helm.directoriesFirst` | string `name`, bool true, bool true | new tabs |
| `helm.singleClickToOpen` | bool, false | item activation (live), only if Q4 is yes |
| `helm.gridIconSize` | int 64, 48 to 128 step 16 | grid layout (live) |
| `helm.liveMonitoringEnabled` | bool, true | monitor registry (live: stops or starts) |
| `helm.showAllMountedVolumes` | bool, false | volume filter (live) |
| `helm.enableDirectoryCache`, `helm.directoryCacheTTL` | bool true; double 1.5, 0.1 to 5.0 | listing cache (live; disabling clears) |
| `helm.maxCachedIcons`, `helm.maxCachedThumbnails` | int 800 floor 100; int 400 floor 50 | caches (live) |
| `helm.searchPreferUserFolders`, `helm.searchIncludeSystemLocations`, `helm.searchResultLimit`, `helm.searchDebounceMilliseconds` | bool true; bool false; int 300, 50 to 800; int 180, 40 to 500 | search (next query) |
| `helm.sidebarLiquidGlass` | bool, false | sidebar (live) |
| `helm.completionDebounceMilliseconds` | int 100, floor 30 | address bar (next request) |
| `helm.crossVolumeDragDefault` (new) | string `copy` | drop planner (live) |
| `helm.restoreSessionOnLaunch` (new) | bool, true | launch sequence |

`SettingsStore` (`HelmPersistence`, `@MainActor ObservableObject`) registers defaults, exposes a `SettingsSnapshot` value and a Combine publisher of changes per key, and is the only writer. Consumers observe the keys they need; nothing observes `UserDefaults.didChangeNotification` any more (B-058). The SwiftUI settings views bind to the store, not to `@AppStorage`, so the two parallel systems become one (B-059). Existing key names are kept unchanged, so no settings migration is needed; the `UserDefaults` suite is the app's standard domain for `com.helm.filemanager`.

### 10.2 JSON stores

User data moves out of `UserDefaults` into `~/Library/Application Support/Helm/` as versioned JSON documents written atomically:

| File | Content | Replaces |
|---|---|---|
| `stars.json` | `{schemaVersion, items: [{path, addedAt}]}` | `com.helm.starredFiles` |
| `bookmarks.json` | `{schemaVersion, items: [{path, name, addedAt, bookmarkData?}]}` | `helm.bookmarks` |
| `recent.json` | `{schemaVersion, records: [{path, lastAccessedAt, kind}]}` capped at 300 | `helm.recentAccessRecords` |
| `trash-origins.json` | `{schemaVersion, items: [{trashedPath, originalPath, trashedAt}]}` | new |
| `session.json` | `{schemaVersion, windows: [{frameAutosaveName, tabs: [{location, viewMode, sort, showHidden}], activeTabIndex}]}` | new |

```swift
public struct VersionedDocument<Payload: Codable & Sendable>: Codable, Sendable {
    public let schemaVersion: Int
    public let payload: Payload
}
public protocol MigrationStep: Sendable {
    var fromVersion: Int { get }
    func migrate(_ json: [String: Any]) throws -> [String: Any]
}
```

`LegacyDefaultsMigrator` runs once at launch: if a JSON file is absent and the legacy defaults key exists, it decodes the legacy value, writes the JSON file at schema version 1, and renames the defaults key to `<key>.migrated` (never deleted, so a rollback to the old build keeps working). Each store is a `@MainActor ObservableObject` with `@Published private(set)` state and debounced (500 ms) atomic writes; all windows share the single instance from `AppEnvironment` (B-027, B-029). Stores read file state at launch only; cross-process sync is out of scope.

### 10.3 Session restoration

`LaunchSequence` reads `session.json` when `helm.restoreSessionOnLaunch` is true and recreates windows and tabs; locations that no longer exist are replaced by Home with a status-bar note. Window frames continue to use AppKit autosave names, one per window index (`HelmMainWindow`, `HelmMainWindow-2`, ...). The session file is rewritten on tab or location change (debounced) and on quit.

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

Because no compiler runs during authoring, review is the compiler. Each feature build (by Opus) is followed by a strict compile-correctness review using this checklist, and nothing merges without it.

**Actor isolation**
- Every class that touches AppKit or SwiftUI is declared `@MainActor`. Every `Task {}` inside such a class inherits main-actor isolation; do not call it `Task.detached` unless the body is pure.
- Calls from a `@MainActor` context into an `actor` are `await`ed; calls into a `@MainActor` method from an actor hop with `await MainActor.run { }` or a `@MainActor` closure.
- Protocol requirements implemented by `@MainActor` classes are either declared on a `@MainActor` protocol or marked `nonisolated` with a hop inside.
- Delegate and callback APIs that run on arbitrary queues (`QLThumbnailGenerator` completion, `NSWorkspace.open` completion, FSEvents callback, `NSMetadataQuery` notifications on non-main queues) are bridged with `Task { @MainActor in }` before touching UI.

**Sendable**
- Values crossing an actor boundary are `struct` or `enum` of Sendable members; no `NSImage`, `NSURL`, `NSMetadataItem`, `NSAttributedString`, closures without `@Sendable`.
- `AsyncStream` element types are Sendable; continuations are captured in a single `@unchecked Sendable` box only in the two documented places.
- No `static var` mutable state without `@MainActor` or an actor.

**Optionals and force operations**
- No `!` on optionals, no `try!`, no `as!`, no `fatalError` outside `preconditionFailure` in unreachable `switch` defaults, no `URL(string:)!`. Pattern: `guard let x = ... else { return }`.
- `URL(fileURLWithPath:)` for paths; `URL(string:)` only in `Support/URLLiterals.swift` returning `URL?`.
- Dictionary subscripts and `first` are optionals; arrays are indexed only after a bounds check or through `indices.contains`.

**AppKit signatures that are commonly wrong**
- `NSCollectionViewDataSource`: `collectionView(_:numberOfItemsInSection:)`, `collectionView(_:itemForRepresentedObjectAt:)`; items are registered with `register(_:forItemWithIdentifier:)` and dequeued with `makeItem(withIdentifier:for:)`.
- `NSOutlineViewDataSource`: `outlineView(_:numberOfChildrenOfItem:)`, `outlineView(_:child:ofItem:)`, `outlineView(_:isItemExpandable:)`; items are `AnyObject` (use `ListNode` class instances, never structs).
- `NSOutlineViewDelegate`: `outlineView(_:viewFor:item:)` returns `NSView?`; cells via `makeView(withIdentifier:owner:)`.
- `NSTableViewDataSource` drag: `tableView(_:pasteboardWriterForRow:)`, `tableView(_:validateDrop:proposedRow:proposedDropOperation:)`, `tableView(_:acceptDrop:row:dropOperation:)`.
- `NSMenuItemValidation.validateMenuItem(_:)` and `NSToolbarItemValidation.validateToolbarItem(_:)` are protocol methods; the class must declare conformance.
- `NSTextFieldDelegate.control(_:textView:doCommandBy:)` returns `Bool`; compare selectors with `#selector(NSResponder.insertTab(_:))`, `insertNewline`, `cancelOperation`, `moveUp`, `moveDown`, `moveRight`, `insertBacktab`.
- `QLPreviewPanelDataSource`: `numberOfPreviewItems(in:)`, `previewPanel(_:previewItemAt:)` returning `QLPreviewItem!`; wrap URLs in a class conforming to `QLPreviewItem`.
- `FileManager.trashItem(at:resultingItemURL:)` takes `AutoreleasingUnsafeMutablePointer<NSURL?>?`; declare `var result: NSURL?` and pass `&result`.
- `NSWorkspace.shared.open(_:withApplicationAt:configuration:completionHandler:)` is the non-deprecated form; `NSWorkspace.OpenConfiguration()`.
- `NSSharingServicePicker(items:)` then `show(relativeTo:of:preferredEdge:)`.
- `NSPasteboard.general.readObjects(forClasses:options:)` with `[.urlReadingFileURLsOnly: true]`.
- `NSAlert.beginSheetModal(for:completionHandler:)`, never `runModal()` from a task.
- `NSHostingController(rootView:)` requires the root view type to be concrete; `AnyView` is avoided.
- `presentAsSheet(_:)` and `dismiss(_:)` with the presented controller as the argument.

**Availability and deprecation**
- Deployment target macOS 14; do not use `@available(macOS 15, *)` APIs (no `NSSplitViewItem` inspector tricks, no new `NSCollectionView` APIs from 15).
- Avoid deprecated: `NSSharingService.sharingServices(forItems:)`, `NSWorkspace.open(_:withApplication:)`, `launchApplication`, `NSOpenPanel.runModal` from tasks, `URL.resourceValues` keys removed in 14 (none used), `NSUserDefaults.synchronize`.
- `Observation` framework, `@Observable`, `#Preview` macros: not used.
- Swift 5.10 syntax such as `nonisolated(unsafe)`: not used. `if let x {}` shorthand is fine (Swift 5.7).

**Generics and closures**
- Explicit parameter and return types on every closure stored in a property or passed across modules: `{ (state: TabState) -> Void in ... }`.
- No single-expression implicit returns in closures longer than one line.
- No nested generic constraints beyond one `where` clause.

**Review mechanics**
- The reviewer reads every file top to bottom once for structure, then once per checklist section. Findings are fixed before the next file. The reviewer also cross-checks each public type against the signatures in this document and lists deviations.
- A CI script (runs on Linux) greps for forbidden tokens: `!` after an identifier at line end or before `.`, `try!`, `as!`, `fatalError(`, `runModal(`, `nonisolated(unsafe)`, `@Observable`, `import AppKit` outside `HelmUI` and `HelmApp`, `DispatchQueue.main.async` (use `MainActor.run`), `Thread.sleep`.

### 11.3 Blind-build coding standard

1. Swift 5 language mode; tools version 5.9; no upcoming-feature flags.
2. No third-party dependencies. No binary targets.
3. No force unwraps, force tries, force casts, implicitly unwrapped optionals (except `@IBOutlet`, which do not exist here because there are no nibs).
4. Explicit types on closure parameters and returns, on empty collection literals, on numeric literals assigned to properties (`let latency: TimeInterval = 0.3`).
5. One type per file, file named after the type. Extensions in `TypeName+Topic.swift`.
6. Every `final class` unless designed for subclassing (only `NSView`, `NSViewController`, `NSResponder`, `NSWindowController` subclasses are open to AppKit).
7. `@MainActor` on every UI class and every store; `actor` for services holding mutable state; `struct` for everything else.
8. Protocols for every AppKit seam that core modules need to reason about: `FileSystem`, `DirectoryMonitor`, `SearchService`, `LocationSource`, `Clock`, `ImageRequesting`. Core modules never name an AppKit type.
9. No result builders outside SwiftUI `body` properties; SwiftUI views stay under 80 lines and use plain `VStack`, `HStack`, `List`, `Form`, `Text`, `Button`, `Toggle`, `Picker`, `TextField`, `Slider`, `Stepper`; no custom `ViewModifier` generics, no `PreferenceKey`, no `GeometryReader` except in `GhostOverlay`.
10. No `DispatchQueue.main.async`; use `Task { @MainActor in }` or `MainActor.run`. No `DispatchSemaphore` outside `IOExecutor`.
11. Every `Task` created in a class is stored and cancelled in `deinit` or on replacement; capture `[weak self]`.
12. Every async result applied to state passes through a generation check.
13. Errors are typed enums conforming to `Error` and `Sendable`; `localizedDescription` is provided through `LocalizedError`.
14. Strings shown to the user live in `UserStrings.swift` per module as `static let` constants (no localization tables yet, but one place to add them).
15. Magic numbers from the preservation map live in `Metrics.swift` (`HelmUI`) and `Limits.swift` (`HelmCore`) as named constants with a comment citing the F-ID.
16. Public API of core modules is documented with one-line `///` comments stating thread-safety and the F or B IDs it serves.
17. Tests for every pure function land in the same commit as the function.

---

## 12. Performance budgets

| Scenario | Budget | Verified by |
|---|---|---|
| Navigate to a cached directory with 1,000 items | first frame under 50 ms | `measure` in `HelmUITests` with a fixture snapshot |
| Enumerate 100,000 items on local APFS | first batch visible under 200 ms; complete under 3 s; sort under 400 ms | integration test on a generated temp tree, timed with `ContinuousClock` |
| Select All on 100,000 items (grid or list) | under 100 ms to update model and widget | `HelmUITests` with a synthetic snapshot |
| External change to one file in a 100,000-item folder | new snapshot under 50 ms after the coalescing window; no full reload | `DirectoryLoader` unit test on the fake with timing |
| Address bar: typing a character in a directory of 10,000 entries | rows under 100 ms on the I/O queue; zero main-thread disk calls | unit test on the fake plus a debug assertion that `LiveFileSystem` is never entered on the main thread |
| Slash browse of a network directory that takes 2 s to list | UI stays responsive; popup shows a spinner row; result or cancel within the generation | integration test with a fake latency of 2 s |
| Copy 10,000 small files (1 GB total) same volume | progress updates at least every 250 ms; cancellation reacts within 500 ms; throughput within 20 % of `cp -R` | integration test on a temp tree (budget check is informational on CI, enforced manually at handoff) |
| Undo of a 1,000-item move | completes under 2 s; one journal entry; selection restored | `OperationJournal` test on the fake |
| Spotlight search typing | debounce 180 ms; first results within 500 ms of query settle on an indexed volume; ranking of 900 candidates under 30 ms | ranker benchmark on Linux; end-to-end timed manually at handoff |
| Memory with 10 tabs on 20,000-item folders | under 150 MB resident beyond baseline | measured at handoff with `footprint`; `ListingCache` entry cap of 200,000 is the enforced proxy |
| App launch to first window interactive | under 400 ms with session restore of 5 tabs | XCUITest launch measurement |
| Main-thread I/O | zero `open`, `stat`, `readdir` from the main thread outside startup | debug build installs a check in `LiveFileSystem` entry points asserting `!Thread.isMainThread`; XCUITest run with the check enabled |

Where a budget cannot be measured on Linux the handoff prompt includes the measurement step, and the number is a target, not a gate.

---

## 13. Decision records

### ADR-001: SwiftPM package of modules, not a single app target
Context: the current project has one target and three conflicting build descriptions. Pure logic cannot be tested without a Mac. Options: single Xcode target; single SwiftPM executable; package of library modules plus a thin app. Decision: package of nine targets with a one-file app target consuming it. Consequences: strict import boundaries enforced by the compiler; five modules test on Linux; XcodeGen describes only the bundle; slightly more boilerplate in `Package.swift`.

### ADR-002: AppKit for the content pane and chrome, SwiftUI for small islands
Context: 100k-item folders, keyboard-first interaction, drag and drop, inline rename, Quick Look. Options: all SwiftUI; all AppKit; hybrid. Decision: hybrid, AppKit for everything performance- or focus-sensitive, SwiftUI for sidebar list, sheets, settings, operations panel. Consequences: more code for the pane; full control of first responder and virtualization; SwiftUI islands stay tiny and compile-safe.

### ADR-003: Combine `ObservableObject` for state publication
Context: AppKit controllers and SwiftUI islands must observe the same stores; authoring is blind. Options: Observation framework with `@Observable`; Combine; hand-rolled closures. Decision: Combine with `@Published` and `removeDuplicates()`. Consequences: no macro expansion risk; well-known `sink` and `store(in:)` patterns; SwiftUI `@ObservedObject` works directly; slightly more manual diffing in controllers.

### ADR-004: FSEvents primary, dispatch source and polling fallback
Context: the current monitor is recursive, leaky and silent on failure. Options: FSEvents only; kqueue or `DispatchSource` per directory; polling. Decision: FSEvents with `WatchRoot`, filtered to direct children, shared per path, with `DispatchSource` and polling fallbacks. Consequences: accurate changed paths for incremental diffs; two extra small implementations; the registry is an actor with refcounts.

### ADR-005: Actors plus a dedicated I/O queue, not GCD-first
Context: blocking FileManager calls inside actors pin the cooperative pool. Options: GCD queues everywhere with completion handlers; actors doing blocking I/O; actors that delegate blocking I/O to an `OperationQueue`. Decision: actors own state; blocking calls run on an `OperationQueue` (max 4 concurrent) bridged by checked continuations. Consequences: async API throughout; cancellation checked between steps; no pool starvation; two `@unchecked Sendable` bridges, documented.

### ADR-006: Not sandboxed, hardened runtime, direct distribution
See section 9. Consequences: no App Store; plain-path persistence; Full Disk Access guidance UI; `AccessBroker` seam for a future sandboxed build.

### ADR-007: Rebuild in place on a new branch of the same repository
Context: keep history, docs, issues and the owner's workflow. Options: new repo; new branch replacing the tree; incremental refactor. Decision: branch `rebuild/v2` from `main`; new tree under `Sources/`, `App/`, `Tests/`; old `Helm/` tree deleted in the first commit that compiles; old code remains in history for behaviour reference. Consequences: one repo, one README; the rebuild branch is merged to `main` only after the handoff build passes the XCUITest suite; no incremental refactor because the audit shows the state model must change everywhere at once.

### ADR-008: NSCollectionView for the grid, NSOutlineView for the list
Context: grid needs rubber-band selection, variable icon sizes, drop-on-item; list needs expandable folders and columns. Options: `NSTableView` with a custom cell for the grid; `NSCollectionView`; one `NSOutlineView` for both. Decision: `NSCollectionView` flow layout for the grid, `NSOutlineView` for the list, both fed by the same snapshot. Consequences: two datasource adapters; shared `SelectionBinder` and `DragDropCoordinator`; a column-view adapter can be added later against the same snapshot.

### ADR-009: Command journal with an `NSUndoManager` bridge, not `NSUndoManager` closures as the model
Context: undo today is closures over strings with no redo and a dangerous delete. Options: register inverse closures directly; a journal that owns the truth and uses `NSUndoManager` only for menu integration. Decision: journal. Consequences: exact per-item inverses; redo; one window-scoped target; undo manager separated from text-field undo; undo operations show progress and errors.

### ADR-010: No third-party dependencies
Context: blind authoring, compile safety, a single owner. Decision: none. Consequences: own small JSON stores, own snapshot assertions, own diffing; nothing to pin or audit.

### ADR-011: Swift 5 language mode, tools 5.9, macOS 14 APIs only
Context: `SWIFT_VERSION 5.9` is invalid; Swift 6 mode would turn every concurrency warning into an error on an uncompiled codebase. Decision: `swiftLanguageVersions: [.v5]`, `SWIFT_VERSION "5"`, strict concurrency at `targeted` as warnings. Consequences: the handoff session sees concurrency diagnostics without being blocked; a later switch to Swift 6 mode is a follow-up once the warnings are at zero.

### ADR-012: Identity is the standardized path, with change tokens for content
Context: `fileResourceIdentifier` is opaque, not Sendable-friendly and awkward to persist. Decision: `ItemID` wraps the standardized path; `ChangeToken` (modification date plus size) detects content change; renames produce new IDs mapped by the journal. Consequences: simple, Codable, testable; a rename briefly loses selection unless the journal maps it, which it does for Helm-initiated renames.

---

## 14. Risks and open items

### 14.1 Product questions that change the build

| # | Question | Default assumed in this document |
|---|---|---|
| Q1 | Breadcrumb segments: should a single click navigate to the ancestor (README) or enter edit mode (last two commits)? | Click navigates; current segment, empty space, Option-click and Cmd+L edit (F-013). |
| Q2 | New Folder: immediate creation, name prompt, or inline rename? | Immediate creation followed by inline rename (F-056). |
| Q3 | Folder Tree sidebar: still wanted? | Not built; `SidebarMode` seam kept (F-033). |
| Q4 | Single-click to open: real requirement? | Setting removed unless answered yes. |
| Q5 | Cross-volume drags: Finder parity (copy) or always move? | Copy across volumes, move within; Cmd forces move; `helm.crossVolumeDragDefault` exposes it (F-067). |
| Q6 | Keyboard tab switching and tab reordering: in scope now? | Out of scope; selectors reserved. |
| Q7 | Stars: keep Helm-private or map to Finder tags? | Helm-private JSON; a tag-backed `StarStore` could replace it behind the same protocol. |
| Q8 | Search: frequency learning from the Recent log? | Not in this rebuild; ranker takes an optional `usageBoost: [URL: Int]` input that is empty. |
| Q9 | Collision dialog: show it by default or keep silent keep-both? | Silent keep-both by default; dialog only when the plan has conflicts and the user has set `helm.askOnConflict` (default false). |

### 14.2 Technical risks

- **Blind compile.** The largest risk is a cascade of small signature errors in `HelmUI`. Mitigation: the checklist in 11.2, the forbidden-token grep, one type per file so errors localise, and a handoff prompt that compiles module by module starting with `HelmCore`.
- **Grid label rendering** (M-19): two-line middle-truncated labels may render one line; verify and fall back to `.byTruncatingTail` with `maximumNumberOfLines = 2`.
- **FSEvents path filtering on case-insensitive volumes:** compare with `standardizedFileURL.path` and `caseInsensitiveCompare` when the volume reports `volumeSupportsCaseSensitiveNamesKey` false.
- **`NSMetadataQuery` on a non-main queue:** the service stays on the main actor for the query object and moves only materialisation off; `kMDItemPath` predicate behaviour (00b C-20) is handled by not using it.
- **Cross-volume move verification:** size comparison only; a content hash would double the cost. Acceptable for a personal tool, noted in the operations panel as "verified by size".
- **Session restore with unmounted volumes:** locations are replaced by Home; the user may see unexpected tabs. Mitigation: status note and the "Reopen Last Session" menu item.
- **Trash Put Back for non-Helm items:** no public API; the command stays disabled rather than guessing.
- **Memory with many 100k-item tabs:** cap enforced by `ListingCache`, but live snapshots held by open tabs are not evicted; ten such tabs is roughly 300 MB. Acceptable; documented.
- **Thumbnail cost on network volumes:** generation is throttled to 4 concurrent requests and cancelled on scroll; still may feel slow on SMB shares.

### 14.3 Items for the handoff session (must run on macOS)

1. Compile `HelmCore` first and run its tests; then `HelmFileSystem`, `HelmOperations`, `HelmSearch`, `HelmPersistence`; then `HelmUI`; then `HelmApp` and the bundle.
2. Run the 19 checks from 00b 3.4 against the new build, especially R-1 (sheets), R-4 and R-5 (selection and stale targets), R-6 (10k Select All), R-10 (Paste validation), R-16 (Cmd+F while editing).
3. Grant Full Disk Access to the built app and verify the Trash and permission-denied states.
4. Measure the section 12 budgets that need a Mac and record the numbers in `docs/rebuild/02-handoff-results.md`.
5. Verify the two-line grid label (M-19) and the `reloadItem` identity of list nodes (M-21).

### 14.4 Deferred features with seams in place

Column and gallery views (`ContentHostController` accepts any `ContentWidget`), tags, aliases creation UI (command exists), per-tab split panes, network locations in Places (`PlaceKind.network` kept), Finder-tag-backed stars, sandboxed distribution (`AccessBroker`), tab reordering and overflow, spring-loaded folders, promise drags.
