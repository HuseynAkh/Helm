> **Reading note (added during the fold-in pass).** This document is Fable's Phase 0 audit. An independent Opus check (`00b-opus-review.md`, 123 citations checked, 85.4% fully correct, location right in 98.4%) produced corrections. They are folded in below as **Appendix C (Errata and additions)**, which takes precedence over the body wherever the two conflict (notably F-051, the Paste row of section 2.8, and B-036). Orchestrator spot-checks against source: B-101 (`FileGridView.swift:81-84` re-reads the sorting `displayItems` per selected index path) and B-102 (the only `makeFirstResponder` calls are the search and address fields) are confirmed; B-100 and B-117 are plausible but depend on AppKit runtime behaviour and are flagged for the first run on macOS. Bug IDs B-100 and above come from the review.

**Helm — Phase 0 current-state audit (00-current-state)**

Reviewer: Fable 5.1 (lead analyst, Phase 0)
Snapshot audited: worktree at `7359ca5` (branch `forge/rebuild-plan`); application source identical to `f0a00d0` (`origin/main`), the snapshot used by the Astra first pass.
Input document: `docs/rebuild/00a-astra-first-pass.md` (read in full first; treated as input, not ground truth).
Method: read-only static review on Linux. Every Swift file (58, plus `Package.swift`), `README.md`, `project.yml`, `Info.plist`, `Helm.entitlements`, both asset-catalog manifests, the checked-in `project.pbxproj`, the workspace file, `.gitignore`, and the test suite were read in full. Nothing was compiled, run, or modified.
Limitation on history: this session has no shell, so `git log -p --stat` could not be executed. Git history evidence is limited to the worktree reflogs and `packed-refs` (which confirm `origin/main = f0a00d0` and the single docs commit on this branch), the five commit subjects visible in the session context, and the two earlier commits (`727ea51` init, `10b9d39` project setup) reported by 00a, which I could not independently confirm. Per-commit diffs below are therefore attributed to 00a or inferred from code comments.

Citation convention: paths under `Helm/Helm/` are written relative to that directory (for example `Controllers/ContentViewController.swift:124`). Paths beginning `Helm/Package.swift`, `Helm/project.yml`, `Helm/HelmTests/`, `Helm/HelmUITests/`, `Helm/TestingSupport/`, or `Helm/Helm.xcodeproj/` are repository-relative. `README.md` is at the repository root.

Claim marking: **[Observed: path:line]** is a fact visible in the source. **[Inferred]** is a consequence, intent, or runtime behaviour reasoned from the source but not executed here.

Status vocabulary for inventory items: **Full** (reachable implementation of the described behaviour), **Partial** (implemented but incomplete or materially defective), **Stub** (advertised or modelled, no working behaviour), **Dead** (code exists, no production caller).

---

## 1. Purpose and vision

### 1.1 What Helm is for

- Helm is a personal, native macOS file manager intended as a keyboard-driven, uncluttered alternative to Finder, explicitly modelled on GNOME Files (Nautilus). [Observed: `README.md:1-3`, `README.md:95-97`]
- The owner's stated growth target is a full Finder replacement; the current code is a single-window-type browser with Places sidebar, tabs, grid/list views, an address bar, Spotlight search, clipboard operations, trash, rename, stars, recents, templates and a read-only properties sheet. [Observed: menu map at `App/main.swift:45-144`; feature surface in Section 2] [Inferred: "full replacement" is the owner's brief, not something the code claims]
- The most recent three commits (`23d6222` Addressbar Path Completion, `08f0cea` Breadcrumb bar autocomplete, `f0a00d0` Breadcrumb bar full navigation) are all about the address bar. The 930-line `BreadcrumbBar` with its own completion actor, popup panel, ghost text and focus-survival heuristics is the single most invested interaction in the codebase. [Observed: `Views/AppKit/BreadcrumbBar.swift:1-930`; commit subjects in session context] [Inferred: a terminal-like typed-path experience is a signature interaction the owner wants preserved]

### 1.2 What concretely mirrors GNOME Files

| Nautilus behaviour | Helm equivalent | Evidence |
|---|---|---|
| Places sidebar with Recent on top, Starred section, Trash at the bottom, user bookmarks | Sections render in the order Recent, Favorites, Bookmarks, Starred, Devices, Trash | [Observed: `Views/SwiftUI/SidebarPlacesView.swift:10-59`] |
| Starred files/folders (Nautilus 3.30+) with a Starred sidebar entry | `StarredFilesService` persisted set; "Star"/"Remove from Starred" context item; Starred sidebar section | [Observed: `Services/StarredFilesService.swift:3-62`, `Views/AppKit/FileContextMenuBuilder.swift:61-69`, `ViewModels/SidebarViewModel.swift:94-106`] |
| "New Document" from `~/Templates` | Background context menu lists `~/Templates` children plus "Empty Text File" | [Observed: `Views/AppKit/FileContextMenuBuilder.swift:195-229`] |
| Explicit file Cut/Copy/Paste on Ctrl+X/C/V | File cut/copy/paste on Cmd+X/C/V via responder fallback; Cut sets a move flag | [Observed: `Services/ClipboardService.swift:18-49`, `Windows/MainWindowController.swift:284-299`] |
| Location entry toggled by Ctrl+L, with tab completion | Cmd+L enters typed-path mode in the breadcrumb; Tab completes; trailing `/` lists a directory | [Observed: `App/main.swift:120`, `Views/AppKit/BreadcrumbBar.swift:183-234`, `:726-753`] |
| Batch rename with "Add text", "Find and replace", template tokens such as `[Original file name]` | Modes "Add Text", "Find & Replace", "Template"; tokens `[Original Name]`, `[Counter]`, `[Date]` | [Observed: `Views/SwiftUI/BatchRenameView.swift:17-21`, `:141-166`] |
| "Expandable folders in list view" preference | List view is an `NSOutlineView` whose non-package directories expand | [Observed: `Views/AppKit/FileListView.swift:113-164`] |
| "Properties" dialog (not "Get Info"), "Open With" submenu, "Move to Trash" | Same names in menus; read-only Properties sheet | [Observed: `Views/AppKit/FileContextMenuBuilder.swift:23-31`, `:87`, `:97`; `App/main.swift:84`] |
| Preference "Single click to open items" | Present in Preferences with the text "like Nautilus" | [Observed: `Views/SwiftUI/PreferencesView.swift:77-80`] (Stub; see F-041/B-059) |
| Icon view and list view only | `ViewMode` has exactly `grid` and `list` | [Observed: `Models/ViewMode.swift:3-6`] |
| Tabs (Ctrl+T / Ctrl+W) | Cmd+T / Cmd+W with a custom tab strip | [Observed: `App/main.swift:51`, `:60`; `Views/AppKit/TabBarView.swift`] |
| Recent as a browsable location | Virtual URL `helm://recent` backed by an app-local access log | [Observed: `Utilities/URL+Extensions.swift:4`, `Services/RecentItemsService.swift:22-57`] |

### 1.3 What it deliberately does differently from Finder

- Cmd+L is "Go to Folder" (Finder uses Shift+Cmd+G), and the result is an editable path in the toolbar, not a sheet. [Observed: `App/main.swift:120`, `Windows/MainWindowController.swift:317-319`]
- Cmd+D toggles a Star (Finder duplicates). Note that in Nautilus Ctrl+D adds a bookmark, so this binding is Helm's own. [Observed: `App/main.swift:123`, `Controllers/ContentViewController.swift:705-710`]
- Cut/Paste moves files (Finder requires Option+Cmd+V). [Observed: `Services/ClipboardService.swift:24-28`, `Controllers/ContentViewController.swift:661-679`]
- Only grid and list views; no column or gallery view. [Observed: `Models/ViewMode.swift:3`]
- "Properties" is a read-only sheet; Finder's Get Info is editable. [Observed: `Views/SwiftUI/PropertiesView.swift:8-91`]
- "Recent" is Helm's own navigation/open history (folders and files), capped at 300 records, not the system's recent-items list. [Observed: `Services/RecentItemsService.swift:13`, `Controllers/ContentViewController.swift:310`, `:387-391`]
- New Folder is created immediately as "New Folder" (with " 2", " 3" suffixes) with no inline rename. [Observed: `Controllers/ContentViewController.swift:634-647`, `Services/FileOperationService.swift:150-159`, `:191-212`]
- A status bar is always present. [Observed: `Controllers/ContentViewController.swift:101-120`]
- No desktop management, no volume eject, no tags, no aliases, no "Open in new tab", no spatial windows, no native `NSWindow` tabbing. [Observed: absence across `App/main.swift:45-144`, `Views/SwiftUI/SidebarPlacesView.swift:9-88`, `Views/AppKit/FileContextMenuBuilder.swift:11-145`]

### 1.4 README claims versus the code

| README claim | Reality |
|---|---|
| "Dual-pane layout — Sidebar with Places and Folder Tree views" (`README.md:7`) | Sidebar plus one content pane; no folder tree exists anywhere. [Observed: `Controllers/SidebarContainerController.swift:33-52`] |
| "Click path segments to jump up the hierarchy" (`README.md:10`) | Every segment click opens the path editor; stored ancestor URLs are ignored. [Observed: `Views/AppKit/BreadcrumbBar.swift:173-175`, `:113`] |
| "intelligent ranking that prioritizes your most-used directories" (`README.md:11`) | Ranking is a static heuristic table (name match, preferred roots, bookmarks, active directory, recency). No usage frequency is recorded or consulted. [Observed: `Services/SpotlightSearchService.swift:303-388`] |
| "Full keyboard shortcut coverage" (`README.md:13`) | No keyboard binding opens the selection (no Cmd+O/Cmd+Down), switches tabs, duplicates, ejects, or empties the trash. [Observed: `App/main.swift:45-144`] |
| "Swift 5.9+" (`README.md:22`) | `nonisolated(unsafe)` requires Swift 5.10. [Observed: `Views/AppKit/BreadcrumbBar.swift:928`, `Views/AppKit/TabBarView.swift:179`] |

### 1.5 History relevant to the product contract

| Commit | What I can establish |
|---|---|
| `727ea51` init, `10b9d39` project setup | Reported by 00a as empty patches. Not verifiable here (no shell). |
| `48e2451` Add README, .gitignore, and repository cleanup | Per 00a, the effective initial snapshot (66 files), already containing the stale `project.pbxproj` that lists only 25 of 49 app sources. Consistent with the current `Helm/Helm.xcodeproj/project.pbxproj:380-410`. |
| `23d6222` Addressbar Path Completion | Introduced `PathCompletionService`, the popup, ghost text and `helm.completionDebounceMilliseconds`. [Observed: `Services/PathCompletionService.swift`, `Views/AppKit/PathCompletionWindowController.swift`, `Utilities/AppSettings.swift:16`] |
| `08f0cea` Breadcrumb bar autocomplete | Per 00a: replaced ancestor navigation with click-to-edit, routed Cut/Copy/Paste through standard responder selectors, enlarged grid cells. The code comment at `Windows/MainWindowController.swift:284-288` documents the responder-chain change; `Views/AppKit/BreadcrumbBar.swift:173` shows the click-to-edit behaviour. |
| `f0a00d0` Breadcrumb bar full navigation | Added synchronous slash-ended directory browsing, `..`, empty-path Home, toolbar/focus survival. The code comments at `Views/AppKit/BreadcrumbBar.swift:460-466` and `:795-802` explain the motivation: async completion was "cancelled" during multi-level drilling, so a synchronous path was added. "Full navigation" means browsing directories inside the completion popup, not restoring ancestor-segment navigation. [Observed: `:452-535`] |
| `7359ca5` docs(rebuild) | Adds `docs/rebuild/00a-astra-first-pass.md` only. [Observed: worktree reflog] |

---

## 2. Feature and interaction inventory

IDs F-001 to F-067 are 00a's; each was re-derived from source. Corrections are called out inline and summarised in Appendix B. New items start at F-068.

### 2.1 Window, lifecycle, navigation, tabs

| ID | Feature | Status | Behaviour, evidence, details a rewrite could lose |
|---|---|---|---|
| F-001 | Application lifecycle | Full | Top-level `main.swift` builds `NSApplication`, sets `.regular`, installs the delegate and menus, runs. One window at launch; app stays alive after last window closes; Dock reopen creates a window only when none is visible. Window controllers retained in an array; removal via `willCloseNotification` block observer whose token is never stored. [Observed: `App/main.swift:3-9`, `:146-148`; `App/AppDelegate.swift:7-24`, `:64-82`] |
| F-002 | External open requests (Dock drop, `open -a`, "Open with Helm") | Partial | Folders navigate the **first** window controller (not the key window), or create a window if none exists. Regular files are launched in their default app and `openFile` returns that result. `Info.plist` registers Helm as an Alternate viewer for `public.folder`. The initial URL passed to a new window reaches only the breadcrumb; the initial tab always loads Home (B-018). [Observed: `App/AppDelegate.swift:26-50`; `App/Info.plist:41-55`; `Windows/MainWindowController.swift:24-25`, `:155`; `Controllers/TabContainerViewController.swift:26-28`] |
| F-003 | Main window and toolbar | Full | 1100×750 initial, 700×450 minimum, unified toolbar, hidden title, frame autosave `HelmMainWindow`, centred. Toolbar is icon-only, customization disabled, fixed order: sidebar toggle, back/forward group (momentary, automatic representation), path (`.user` visibility priority so it never overflows; width 60–1000, height 34), view-mode segmented control (`.low`), search field (`.low`, sends immediately, placeholder "Search files and folders"). [Observed: `Windows/MainWindowController.swift:27-39`, `:66-82`, `:116-208`] |
| F-004 | Sidebar split and collapse | Full | `NSSplitViewItem(sidebarWithViewController:)`, thickness 180–320, collapsible, content minimum 400, thin divider, autosave `HelmMainSplitView`; toggle animates 0.12 s then `adjustSubviews`. Ctrl+Cmd+S and toolbar button. [Observed: `Windows/MainSplitViewController.swift:11-27`, `:42-48`; `App/main.swift:96-98`] |
| F-005 | Back/Forward history | Partial | Per-tab `NavigationState` keeps `[NavigationEntry]` stacks of URL plus selected-URL set; `navigateTo` pushes current and clears forward; back/forward swap entries and restore the selection set, which the controller intersects with loaded items. Same-URL navigation is pushed again (no dedup). Restored selection reaches the model only, never the widgets (B-011). Back/Forward controls are never disabled (B-075). [Observed: `Models/NavigationState.swift:4-56`; `Controllers/ContentViewController.swift:124-149`, `:273-276`] |
| F-006 | Up and Home | Partial | Cmd+Up: no-op at virtual locations and at `/`; does not snapshot the current selection into history before moving (unlike `navigateTo`). Shift+Cmd+H navigates to `homeDirectoryForCurrentUser`. [Observed: `Controllers/ContentViewController.swift:151-156`; `Models/NavigationState.swift:50-55`; `Windows/MainWindowController.swift:313-315`] |
| F-007 | Opening items | Full | Double-click (grid `mouseDown` clickCount 2; list `doubleAction`) → non-package directory navigates; anything else `NSWorkspace.shared.open`. Successful file opens are recorded in Recent; failures show "Unable to Open Item". "Open N Items" iterates; multiple directories end at the last one because each navigation cancels the previous load. [Observed: `Views/AppKit/FileGridView.swift:305-310`, `:113-119`; `Views/AppKit/FileListView.swift:100-109`; `Controllers/ContentViewController.swift:381-403`, `:427-432`; `ViewModels/DirectoryViewModel.swift:128-135`] |
| F-008 | Refresh | Partial | Cmd+R: invalidates the directory cache entry, reloads without cache, restores selection by intersection (model only), reloads the widget, updates status, restarts monitoring, reruns an active search. In Recent it reloads the recents collection. [Observed: `Controllers/ContentViewController.swift:201-216`; `ViewModels/DirectoryViewModel.swift:67-73`] |
| F-009 | Tab creation | Partial | Cmd+T and the "+" button open a new tab at the active tab's **location** only (no selection, history, view mode, or search carried over). Each tab owns a full `ContentViewController` with its own services. The very first tab always starts at Home. [Observed: `Controllers/TabContainerViewController.swift:26-28`, `:72-95`; `Controllers/ContentViewController.swift:9-17`] |
| F-010 | Tab bar | Partial | Custom `TabBarView`: horizontal stack, `fillEqually`, 30 pt bar, 28 pt tab containers, 12 pt titles truncating tail, 16 pt close buttons, 24 pt "+" button, selected tint accent 15% with radius 6. Shown only when more than one tab exists (height constraint 0 otherwise). Switching reparents the retained content view and updates breadcrumb and sidebar only; view-mode segment and search field are window-level (B-020). Title rules: `Recent`, `/`, else last path component (so the Home tab shows the user's folder name while the breadcrumb says "Home"). No reordering, overflow, keyboard switching, or session restore. [Observed: `Views/AppKit/TabBarView.swift:31-145`; `Controllers/TabContainerViewController.swift:129-167`; `Models/Tab.swift:27-36`] |
| F-011 | Tab closing | Full | Close button, middle-click, Cmd+W. Only when more than one tab; closing the active tab selects the left neighbour (or the second tab when closing the first). Cmd+W with one tab closes the window. [Observed: `Controllers/TabContainerViewController.swift:97-127`; `Views/AppKit/TabBarView.swift:152-175`] |
| F-068 (new) | Window/state restoration | Partial | Only window frame (`HelmMainWindow`), split position (`HelmMainSplitView`), and settings-window frames are autosaved. No `restorationClass`, no persisted tabs or locations, no reopening of the last session. [Observed: `Windows/MainWindowController.swift:37`; `Windows/MainSplitViewController.swift:27`; `Windows/PreferencesWindowController.swift:15`; `Windows/AdvancedOptionsWindowController.swift:14`; absence of restoration APIs] |

### 2.2 Breadcrumb and address bar

| ID | Feature | Status | Behaviour, evidence, details a rewrite could lose |
|---|---|---|---|
| F-012 | Breadcrumb rendering | Full | Ancestors from `/`; `/` labelled "/", home labelled "Home", others by last component. Current segment bold 13 pt label colour; ancestors 13 pt secondary; separators `›` (U+203A) 11 pt light tertiary; stack spacing 2, insets 6; scroll area 26 pt high inside a 34 pt bar with radius 8 and 10 % quaternary background. Rightmost end kept visible after rebuild and on resize. Recent shows a single semibold "Recent" label; other non-file URLs show `absoluteString`. Segment buttons highlight on hover (7 % label colour, radius 4). [Observed: `Views/AppKit/BreadcrumbBar.swift:42-81`, `:85-171`, `:271-281`, `:345-354`, `:664-672`, `:883-907`; `Utilities/URL+Extensions.swift:13-24`] |
| F-013 | Segment and empty-space clicks | Partial | **Every** segment click and any click on empty stack space call `startEditing()`; the per-segment ancestor URL attached as an associated object is never read. This contradicts `README.md:10` (B-051). [Observed: `Views/AppKit/BreadcrumbBar.swift:109-114`, `:173-175`, `:911-925`] |
| F-014 | Entering typed-path mode | Full | Cmd+L or click: refuses non-file URLs (so Recent cannot use it), hides the segment scroller, inserts a borderless 13 pt text field with the current path plus trailing `/`, inset 10. After 50 ms it becomes first responder, caret placed at end (not select-all), delegate attached only then, and the directory listing is shown immediately. Focus failure falls back to the segment view. [Observed: `Views/AppKit/BreadcrumbBar.swift:183-234`; `App/main.swift:120`] |
| F-015 | Commit and validation | Partial | Trims whitespace/newlines, expands `~`, builds and standardizes a file URL, accepts existing **directories** only. Empty input → Home. Invalid → `NSSound.beep()`, 0.4 s shake, red 11 pt "Invalid path or folder not accessible" label below the bar for 2.5 s, exit editing, typed text discarded. Relative paths resolve against the process working directory. No `$VAR`, shell escaping, or URL schemes. [Observed: `Views/AppKit/BreadcrumbBar.swift:236-269`, `:285-321`] |
| F-016 | Prefix completion (no trailing slash) | Partial | Debounced by `helm.completionDebounceMilliseconds` (default 100, floor 30), then the `PathCompletionService` actor enumerates the parent (3 s cache, 30 directories), filters anchored case-insensitive, sorts directories first then `localizedStandardCompare`, caps 50, builds items with 16 pt `NSWorkspace` icons on the main actor. Request IDs guard stale results. Always hidden-filtered regardless of the app setting. [Observed: `Views/AppKit/BreadcrumbBar.swift:419-445`, `:791-813`; `Services/PathCompletionService.swift:27-107`; `Utilities/AppSettings.swift:70-73`] |
| F-017 | Slash-ended directory browsing | Partial | Synchronous on the main thread: enumerates all visible children, reads `isDirectory`, creates an icon for every entry, sorts, then prepends `..` (parent, except at `/`) and appends the first 50 children (max 51 rows). Bypasses actor, cache, debounce and cancellation by design (comment explains the async version "silently failed"). [Observed: `Views/AppKit/BreadcrumbBar.swift:452-535`] |
| F-018 | Completion popup | Full | Borderless, non-activating child `NSPanel` at `.popUpMenu` level, shadow, clear background, `.menu` visual effect with radius 6, `hidesOnDeactivate`, `.utilityWindow` animation; plain `NSTableView` with 24 pt rows, no header, single selection; at most 8 visible rows then scrolls; width tracks the bar; repositioned on parent move/resize; first row selected on every show/update. Rows: 16 pt icon, 13 pt name, trailing `/` for directories. [Observed: `Views/AppKit/PathCompletionWindowController.swift:20-21`, `:25-99`, `:124-209`, `:213-259`, `:313-366`] |
| F-019 | Mouse acceptance | Partial | Single click changes selection only (no ghost refresh); double-click accepts the row: text becomes the row's full path; directories re-list their contents without navigating; files fill the path and hide the popup (and will fail folder-only commit). [Observed: `Views/AppKit/PathCompletionWindowController.swift:263-269`, `:305-308`; `Views/AppKit/BreadcrumbBar.swift:538-551`] |
| F-020 | Tab completion | Full | Tab: accept ghost suffix if present; else accept the selected popup row (directories drill deeper); else request completions for the current text. Tab and Shift+Tab are always consumed so focus never leaves the field. Because `..` is row 0 in non-root browse mode, an immediate Tab moves the path up one level. [Observed: `Views/AppKit/BreadcrumbBar.swift:726-758`] |
| F-021 | Return | Partial | If the text does not end in `/` and the popup is visible, Return first substitutes the selected row's path, then commits. With a trailing `/`, Return commits the field text even if another row is highlighted. An empty field commits Home unless a stale popup (within the debounce window) still has a selection, in which case that row is committed (B-052). [Observed: `Views/AppKit/BreadcrumbBar.swift:691-712`, `:244-249`] |
| F-022 | Escape and arrows | Partial | First Escape hides the popup and clears ghost text; second exits editing without navigating. Up/Down move the selection with clamping (no wrap) and refresh ghost text. Right arrow accepts ghost text only when the caret is collapsed at the end. Other arrows fall through to the text editor. [Observed: `Views/AppKit/BreadcrumbBar.swift:714-724`, `:760-786`; `Views/AppKit/PathCompletionWindowController.swift:103-115`] |
| F-023 | Ghost text | Partial | Tertiary-colour overlay label positioned by measuring the typed text width plus the cell's title-rect inset; shown only when the selected row's full path case-insensitively starts with the typed text and the caret is at the end; accepting appends the canonical suffix to the **typed** casing. Not refreshed on mouse selection or caret-only moves. [Observed: `Views/AppKit/BreadcrumbBar.swift:579-662`] |
| F-024 | Editing and focus survival | Partial | Programmatic text changes write into the field editor's text storage (to avoid `abortEditing`), suppress change notifications until the next run-loop pass, and re-establish the field editor if lost. End-editing handling: Return → commit; suppressed change → keep; mouse-down outside the bar → cancel; field removed from window → wait 150 ms and resume if re-added; any other focus loss → re-establish focus. `viewDidMoveToWindow` re-establishes the editor after toolbar relayout. Native `NSTextField` completions are disabled. [Observed: `Views/AppKit/BreadcrumbBar.swift:370-405`, `:674-685`, `:815-877`] |
| F-025 | Copy Path | Full | Breadcrumb context menu has one item, "Copy Path", only for file URLs; copies the current location's POSIX path as a plain string (not the clicked segment, not a file URL). No shortcut, no button. [Observed: `Views/AppKit/BreadcrumbBar.swift:325-341`] |

### 2.3 Sidebar and virtual locations

| ID | Feature | Status | Behaviour, evidence, details a rewrite could lose |
|---|---|---|---|
| F-026 | Places sections and icons | Full | Order: Recent (`clock.arrow.circlepath`, secondary); Favorites: Home `house`, Desktop `menubar.dock.rectangle`, Documents `doc`, Downloads `arrow.down.circle`, Applications `square.grid.2x2` (blue); Bookmarks `bookmark.fill` (orange, section hidden when empty); Starred `star.fill` (yellow, hidden when empty); Devices `externaldrive`/`internaldrive` (gray, hidden when empty); Trash `trash` (secondary). `.sidebar` list style, rows padded 2. `PlaceKind.network` and `.recent` exist but are never instantiated. [Observed: `Views/SwiftUI/SidebarPlacesView.swift:9-59`, `:90-116`; `Models/Place.swift:11-92`] |
| F-027 | Selection mapping | Partial | Navigation drives highlight: Recent maps to the Recent row; otherwise exact match among favorites+bookmarks+devices+trash, else the deepest containing place. Starred rows are never highlight candidates. Clicking a row dispatches navigation; the highlight follows only after the load succeeds, and re-clicking the already-selected row cannot re-trigger navigation (SwiftUI binding no-op). [Observed: `ViewModels/SidebarViewModel.swift:32-40`, `:165-195`; `Views/SwiftUI/SidebarPlacesView.swift:78-87`] |
| F-028 | Bookmarks and sidebar drops | Partial | Dropping file-URL providers anywhere on the list shows "Drop Folder to Add Bookmark" (caption in a regular-material capsule, bottom-leading) and adds existing directories as bookmarks (standardized, deduplicated, sorted by name, JSON array under `helm.bookmarks`). Files are ignored; the drop still returns `true`. Context menu on a bookmark: "Remove Bookmark" only. Dropping files onto a sidebar folder never moves or copies them. [Observed: `Views/SwiftUI/SidebarPlacesView.swift:23-35`, `:63-75`; `ViewModels/SidebarViewModel.swift:46-92`, `:130-159`] |
| F-029 | Starred | Partial | Set of standardized URLs under `com.helm.starredFiles`, guarded by an `NSLock`. Cmd+D toggles each selected root item; single-item context menu shows "Star"/"Remove from Starred" with the `d` equivalent. The sidebar reads stars once at construction; `FileItem.isStarred` is flipped in the model but no cell shows a badge. Every tab and the sidebar hold independent service instances (B-027). [Observed: `Services/StarredFilesService.swift:3-62`; `ViewModels/DirectoryViewModel.swift:121-126`; `Controllers/ContentViewController.swift:705-710`; `Views/AppKit/FileContextMenuBuilder.swift:61-69`; `ViewModels/SidebarViewModel.swift:25-29`, `:94-106`] |
| F-030 | Recent | Partial | Virtual URL `helm://recent`. Shared actor stores `[path, lastAccessedAt]` under `helm.recentAccessRecords`, dedupes on access, keeps 300, prunes missing paths on read, saves to defaults on every record. Folder navigations and successful default-app opens are recorded (Open With is not). The controller shows up to 180 items, stops monitoring, points `currentURL` at the last stable directory, and the view then re-sorts by name (recency order lost, B-030). No clear-history UI although `clear()` exists. [Observed: `Utilities/URL+Extensions.swift:4`, `:34-40`; `Services/RecentItemsService.swift:12-84`; `Controllers/ContentViewController.swift:310`, `:387-391`, `:314-324`] |
| F-031 | Devices | Partial | `VolumeService` refreshes on `didMount`/`didUnmount` and on every `UserDefaults.didChangeNotification`. Default filtering: skip hidden volumes, non-browsable, paths under `/System/Volumes/`, `/private/`, `/dev/`, names containing `preboot`, `recovery`, `vm`, `update`, `hardware`, ` xarts`, ` - data`; dedupe by UUID, dedupe internal volumes by lowercase name; internal first then name order (resource reads inside the comparator). "Show all mounted volumes" disables all filtering. All volumes are `.device`; no eject, no network section. [Observed: `Services/VolumeService.swift:10-23`, `:35-147`; `ViewModels/SidebarViewModel.swift:113-128`] |
| F-032 | Trash | Partial | A Place pointing at the literal `~/.Trash`; browsing it is ordinary directory browsing. No Empty Trash, Put Back, or per-volume `.Trashes`. [Observed: `Models/Place.swift:82-92`] |
| F-033 | Folder Tree sidebar | Stub | README only; no tree model, outline view, or mode switch exists. [Observed: `README.md:7`; `Controllers/SidebarContainerController.swift:33-52`] |
| F-034 | Translucent sidebar | Full | `helm.sidebarLiquidGlass` toggles an `NSVisualEffectView` (`.sidebar`, within-window) under the hosting view plus clear SwiftUI backgrounds; re-applied on every defaults change. [Observed: `Controllers/SidebarContainerController.swift:58-104`; `Views/SwiftUI/SidebarPlacesView.swift:6`, `:60-62`] |

### 2.4 Grid, list, selection, sorting, hidden files

| ID | Feature | Status | Behaviour, evidence, details a rewrite could lose |
|---|---|---|---|
| F-035 | Grid view | Full | `NSCollectionViewFlowLayout`: items 140×140, inter-item 10, line 14, section insets 12/16/12/16; clear background; multiple selection; icon 96×96 scaled proportionally; name 11 pt centred, two lines, middle truncation; selection = accent 20 % background, radius 8. Registered for `.fileURL` drags. [Observed: `Views/AppKit/FileGridView.swift:31-64`, `:224-255`, `:291-300`] |
| F-036 | List view | Partial | `NSOutlineView`, `.fullWidth`, 24 pt rows, alternating backgrounds, multiple selection. Columns: Name (min 200, 13 pt, 18 pt icon), Size (80/60, `--` for directories, `ByteCountFormatter .file`), Date Modified (160/100, medium date + short time), Kind (120/80, `UTType.localizedDescription`); secondary 12 pt text for non-name columns. Sort prototypes on Name/Size/Date but no `sortDescriptorsDidChange` handler (B-034); Kind has none. No column autosave. [Observed: `Views/AppKit/FileListView.swift:34-93`, `:168-289`] |
| F-037 | Expandable folders | Partial | Non-package directories are expandable. First `numberOfChildrenOfItem` returns 0 and starts an async load through the list's **own** `FileSystemService` (default sort, hidden files and stars not applied); completion caches children and calls `reloadItem(reloadChildren:)`. Any `reloadData` clears the cache. A placeholder item guards index races. [Observed: `Views/AppKit/FileListView.swift:14`, `:19`, `:95-98`, `:113-164`] |
| F-038 | Selection | Partial | Widgets own selection; delegate callbacks copy selected URLs into `DirectoryViewModel.selectedItems`. Right-click on an unselected item replaces selection; on a selected item keeps the group; on background clears. No reverse binding (model → widget). Expanded children can be selected in the list, but menu-driven commands resolve against root `displayItems` only (B-033). [Observed: `Views/AppKit/FileGridView.swift:72-94`, `:125-140`; `Views/AppKit/FileListView.swift:273-278`, `:293-314`; `Controllers/ContentViewController.swift:649-723`] |
| F-039 | View-mode switching | Partial | Cmd+1/Cmd+2/segment: the controller sets `viewModel.viewMode` and `FileListViewController` tears down one widget and builds the other (scroll, expansion and visible selection lost). The menu route updates the segment; the segment route does not synchronise across tabs; `helm.defaultViewMode` is never read. [Observed: `Controllers/FileListViewController.swift:48-74`; `Controllers/ContentViewController.swift:158-161`; `Windows/MainWindowController.swift:228-244`; `ViewModels/DirectoryViewModel.swift:11`] |
| F-040 | Sorting | Partial | `FileItemSort` supports name/size/dateModified/kind, direction, directories-first (applied before the field regardless of direction). Default name ascending, directories first, `localizedStandardCompare`. `displayItems` re-sorts on **every** access. Nothing updates the descriptor at runtime. Descending negates the comparator (B-035). [Observed: `Models/FileItemSort.swift:3-50`; `ViewModels/DirectoryViewModel.swift:12`, `:17-19`] |
| F-041 | Type-select and keyboard open | Partial (corrected from 00a "Stub") | No app code. The list is a view-based `NSTableView`, which supplies native type-to-select over the Name cell's text field and arrow-key selection [Inferred from AppKit defaults]; the grid has arrow navigation but no type-select. No binding opens the selection from the keyboard. [Observed: `Views/AppKit/FileListView.swift:187-243`; `App/main.swift:45-144`] |
| F-042 | Hidden files | Partial | Cmd+. toggles the active tab's model and writes `helm.showHiddenFiles`; new models read the key at init. Listing uses `.skipsHiddenFiles` unless enabled. Expanded children, path completions and slash browsing stay hidden-filtered; Recent ignores the toggle (it just reloads); Spotlight applies its own dot-prefix exclusion. Menu item has no check state. [Observed: `Controllers/ContentViewController.swift:182-199`; `ViewModels/DirectoryViewModel.swift:35`; `Services/FileSystemService.swift:34-38`; `Views/AppKit/FileListView.swift:130`; `Views/AppKit/BreadcrumbBar.swift:480`; `Services/PathCompletionService.swift:34`, `:123-126`] |
| F-069 (new) | Symlinks and aliases | Stub | `FileItem.isSymlink` is captured and never read. `isDirectory` is taken from the link itself, so a symlink to a folder is treated as a file (opened via `NSWorkspace`, not navigated). Finder aliases are ordinary files. [Observed: `Models/FileItem.swift:10`, `:47-48`; grep: no consumer of `isSymlink`] [Inferred: `isDirectoryKey` on an unresolved symlink URL is false] |

### 2.5 Search, previews, properties

| ID | Feature | Status | Behaviour, evidence, details a rewrite could lose |
|---|---|---|---|
| F-043 | Search entry and scope | Partial | Toolbar field sends every change; Cmd+F focuses and selects it. Query is trimmed; empty → exit search and reload. In a directory: `.currentFolder(url)`; in Recent: `.everywhere` boosted toward the last stable directory. Debounce `helm.searchDebounceMilliseconds` (default 180, floor 40). Navigation/back/up exit search and clear the field. No scope selector, no loading indicator. [Observed: `Windows/MainWindowController.swift:197-208`, `:246-254`; `Controllers/ContentViewController.swift:163-180`, `:337-357`; `ViewModels/SearchViewModel.swift:26-73`] |
| F-044 | Spotlight predicate and scopes | Partial | `kMDItemFSName CONTAINS[cd] query` (filename only, whole string). Unless "include system locations": also excludes dot-prefixed names and paths under `/system/ /library/ /private/ /usr/ /bin/ /sbin/ /dev/ /opt/`. Everywhere scope with "prefer user folders" (default): Home, existing Desktop/Documents/Downloads/Movies/Music/Pictures/Public, bookmarks, removable browsable volumes, optionally the local-computer scope; otherwise `NSMetadataQueryUserHomeScope` (+ local computer). No filesystem fallback for unindexed locations. [Observed: `Services/SpotlightSearchService.swift:18-27`, `:113-185`] |
| F-045 | Ranking | Partial | Static score: exact name +1200 / prefix +800 / contains +500; +100 per whitespace token found; preferred root +380 plus depth bonus max(0, 150−30·depth); other Home content +220; inside bookmark +300; under active directory +200; directory +80; document-like +140; hidden −280; system-like −650 when excluded; modified <1 day +90, <7 days +55, <30 days +25; current-folder scope +40. Ties: newer modification, then natural name. Preferred roots: a fixed list (documents, desktop, downloads, projects, work, pictures, movies, music, developer, sites, code, coding, applications, public) plus every visible top-level Home folder except Library, discovered by enumerating Home on every rank. [Observed: `Services/SpotlightSearchService.swift:224-421`] |
| F-046 | Result delivery | Partial | Observes `DidFinishGathering` and `DidUpdate`; disables updates while reading; reads at most `max(limit×3, 450)` items in the query's own order (modification date desc, name asc), builds `FileItem`s with disk reads on the main actor, dedupes paths, ranks, returns `limit` (default 300). Results are written into `DirectoryViewModel.items` and then re-sorted by the directory sort (ranking order lost, B-022). [Observed: `Services/SpotlightSearchService.swift:48-98`, `:187-222`; `Controllers/ContentViewController.swift:359-371`; `ViewModels/DirectoryViewModel.swift:17`] |
| F-047 | File icons | Full | MainActor singleton, `NSCache` keyed `path#WxH`, count limit refreshed from `helm.maxCachedIcons` (default 800, floor 100). No invalidation on change. [Observed: `Services/FileIconService.swift:4-38`; `Utilities/AppSettings.swift:39-42`] |
| F-048 | Thumbnails | Partial | Eligible UTTypes: image, movie, video, pdf, presentation, spreadsheet, html, svg; never directories. Generic icon first, cached QL thumbnail synchronously if present, else async `QLThumbnailGenerator` request at `size×2` with scale 2.0, `.thumbnail` representation; result cached (limit `helm.maxCachedThumbnails`, default 400, read once). Cells cancel their request on reuse and verify the URL before assigning. Grid 96 pt, list 18 pt. [Observed: `Services/ThumbnailService.swift:13-103`; `Views/AppKit/FileGridView.swift:257-289`, `:312-323`; `Views/AppKit/FileListView.swift:187-243`] |
| F-049 | Quick Look | Partial | Space in `FileListViewController.keyDown` toggles `QLPreviewPanel.shared()` when the selection is non-empty; the controller accepts panel control and supplies selected **root** items in display order as `NSURL`s. No menu item (the `performQuickLook` chain through window/tab containers exists but is unreachable), no reload on selection change, expanded children omitted. [Observed: `Controllers/FileListViewController.swift:114-162`; `Windows/MainWindowController.swift:325-327`; `Controllers/TabContainerViewController.swift:254-256`; `Controllers/ContentViewController.swift:712-714`; `App/main.swift:45-144`] |
| F-050 | Properties | Partial | Cmd+I (first selected root item, else current directory) or single-item context menu opens a 360×480 sheet: 64 pt icon, name, kind; Size (human-readable), Location (parent path), Created, Modified (long date, medium time), Type (UTI); Image dimensions when `CGImageSource` can read the file; Open With → default app name; Permissions as Read/Write/Execute words per owner/group/others plus octal; "Show in Enclosing Folder" (`activateFileViewerSelecting`, i.e. opens Finder); Done = Escape. `sizeInBytes` and `availableApplications` are loaded but not displayed; folder size is metadata size. [Observed: `ViewModels/PropertiesViewModel.swift:40-110`; `Views/SwiftUI/PropertiesView.swift:8-91`; `Controllers/ContentViewController.swift:716-735`] |

### 2.6 File operations, clipboard, undo

| ID | Feature | Status | Behaviour, evidence, details a rewrite could lose |
|---|---|---|---|
| F-051 | Cut/Copy/Paste | Partial | Shared `ClipboardService`: writes `NSURL`s to the general pasteboard and remembers URLs plus `isCut`. Paste prefers internal state; cut state is cleared on read (before the move runs); pasteboard fallback is always a copy. Edit-menu items use `NSText` selectors so a focused text field gets text semantics and otherwise the window controller performs file semantics. Context-menu Paste enablement checks only the system pasteboard. No visual dimming of cut items. [Observed: `Services/ClipboardService.swift:18-59`; `App/main.swift:72-75`; `Windows/MainWindowController.swift:284-299`; `Controllers/ContentViewController.swift:447-475`, `:649-679`; `Views/AppKit/FileContextMenuBuilder.swift:52-56`, `:116-120`] |
| F-052 | Copy/move semantics | Partial | Actor loops over items with `FileManager.copyItem`/`moveItem` (whole-item, blocking, non-cancellable). Collisions become `name 2.ext`, `name 3.ext`… (never "copy"); no replace/merge/skip dialog. Cross-volume moves are whatever `moveItem` does. First failure aborts; partial results are not returned. [Observed: `Services/FileOperationService.swift:61-105`, `:191-212`] |
| F-053 | Move to Trash | Partial | Cmd+Backspace or context menu → `FileManager.trashItem` per item; trash URLs recorded for undo when returned. No confirmation despite `helm.confirmBeforeTrash` (B-048). [Observed: `Services/FileOperationService.swift:109-125`; `Controllers/ContentViewController.swift:492-503`, `:681-694`] |
| F-054 | Rename | Partial | Return (menu equivalent with empty modifier mask) with one selected root item, or context "Rename": modal `NSAlert` titled "Rename"/"Enter a new name:" with a 300×24 field prefilled with the name, Rename/Cancel buttons; attempts to preselect the basename (ineffective, B-066); trims whitespace; ignores empty/unchanged; `moveItem` to the new name without validation (B-046). No inline editing. [Observed: `Controllers/ContentViewController.swift:561-591`, `:696-703`; `App/main.swift:77-79`; `Services/FileOperationService.swift:137-146`] |
| F-055 | Batch rename | Partial | Multiple selection + Return or "Rename N Items…" presents a 500×450 SwiftUI sheet: segmented modes Add Text (Prepend/Append), Find & Replace (plain substring), Template (default `[Original Name]-[Counter]`, counter start field, tokens `[Original Name]`, `[Counter]`, `[Date]`=`yyyy-MM-dd`). Operates on the basename, preserves the `NSString` extension. Monospaced preview of the first 20 ("… and N more"), Rename disabled when nothing changes, Return/Escape bound. Execution: skip unchanged, sequential, stop at first error, one undo registration per item. [Observed: `Views/SwiftUI/BatchRenameView.swift:3-193`; `Controllers/ContentViewController.swift:593-630`] |
| F-056 | New Folder | Full | Shift+Cmd+N (targets `directoryViewModel.currentURL`) or background context menu (carries its directory): creates "New Folder" with collision suffix, registers undo, refreshes. No name prompt, no rename initiation. [Observed: `Controllers/ContentViewController.swift:520-531`, `:634-647`; `Services/FileOperationService.swift:150-159`] |
| F-057 | New File and templates | Partial | Background menu "New File" submenu: every visible direct child of `~/Templates` in enumeration order (directories included), separator, "Empty Text File" (`Untitled.txt`). Template copies keep the template's filename with collision suffix. No main-menu New File. [Observed: `Views/AppKit/FileContextMenuBuilder.swift:195-229`; `Controllers/ContentViewController.swift:533-557`; `Services/FileOperationService.swift:163-187`] |
| F-058 | New File sheet | Dead | `NewFileView` (name field, template list, Create/Cancel with Return/Escape) has no production caller; its `directoryURL` is unused. [Observed: `Views/SwiftUI/NewFileView.swift:3-76`; grep] |
| F-059 | Undo | Partial | After a successful operation the controller registers an inverse on `view.window?.undoManager` (one stack per window, shared across tabs) with action names Copy, Move, Move to Trash, Rename, New Folder, New File. Inverses run in detached tasks, swallow errors, register no redo, and never refresh the UI. Drag/drop and failed partial operations register nothing. Undo of copy/create deletes permanently. [Observed: `Services/UndoService.swift:11-71`; `Controllers/ContentViewController.swift:405-411`; `Views/AppKit/FileGridView.swift:197-209`] |
| F-060 | Permanent delete | Dead as a user command | `deleteItems` exists and is used only by undo. [Observed: `Services/FileOperationService.swift:129-133`; `Services/UndoService.swift:19`, `:66`] |
| F-061 | Operation progress and cancellation | Stub/Dead | `OperationProgress` and `OperationProgressView` (circular progress, kind label, file name, cancel button) exist; nothing publishes progress or hosts the view. [Observed: `Services/FileOperationService.swift:15-36`; `Views/SwiftUI/OperationProgressView.swift:3-44`; grep] |
| F-062 | Open With | Full | Single-item submenu: first ten `urlsForApplications(toOpen:)` with 16 pt icons; disabled "No Applications" when empty. Launch via `NSWorkspace.open(_:withApplicationAt:)`; failure shows an alert from the completion handler (B-070). Not recorded in Recent. [Observed: `Views/AppKit/FileContextMenuBuilder.swift:149-170`; `Controllers/ContentViewController.swift:434-445`] |
| F-063 | Share | Full (not exercised) | Submenu of `NSSharingService.sharingServices(forItems:)` (deprecated API) or disabled "No Sharing Options"; selecting calls `perform(withItems:)`. [Observed: `Views/AppKit/FileContextMenuBuilder.swift:172-193`; `Controllers/ContentViewController.swift:515-518`] |
| F-064 | Status bar | Partial | Always-present 24 pt bar with top separator and an 11 pt secondary label: "N items" (or "1 item"), optional "N selected", optional "X free" (`volumeAvailableCapacityForImportantUsage` of the active location, read synchronously on every update), joined by "  •  ". No selected-bytes total, no progress, no error state. [Observed: `Views/AppKit/StatusBar.swift:17-59`; `Controllers/ContentViewController.swift:101-120`, `:225-229`] |
| F-065 | Settings and Advanced Options | Partial | Two singleton windows (titled "Helm Settings", 450×300 tabs General/Appearance/Behavior; "Advanced Options", 500×440 form). Most General controls are unwired (see 2.9). [Observed: `Windows/PreferencesWindowController.swift:4-30`; `Windows/AdvancedOptionsWindowController.swift:4-29`; `Views/SwiftUI/PreferencesView.swift:3-85`; `Views/SwiftUI/AdvancedOptionsView.swift:3-71`] |
| F-066 | Standard menus | Full (platform) | About, Settings… (Cmd+,), Advanced Options…, Services (registered), Hide/Hide Others/Show All, Quit; Window: Minimize, Zoom, Bring All to Front; Help menu installed empty. [Observed: `App/main.swift:14-43`, `:126-142`] |
| F-067 | Drag and drop (grid/list) | Partial | Detailed in 2.8. [Observed: `Views/AppKit/FileGridView.swift:46-49`, `:142-212`; `Views/AppKit/FileListView.swift:75-78`, `:316-374`] |
| F-070 (new) | Multi-open semantics | Full | "Open N Items" calls `openItem` for each: files launch, packages launch, folders navigate; successive folder navigations cancel each other so the last folder wins. [Observed: `Controllers/ContentViewController.swift:427-432`, `:259-287`] |

### 2.7 Complete menu and shortcut map

`⌘` Command, `⇧` Shift, `⌥` Option, `⌃` Control. Items created without an explicit mask take AppKit's default Command modifier. All from `App/main.swift` unless noted.

| Menu / item | Binding | Route | Notes |
|---|---|---|---|
| Helm → About Helm | none | `orderFrontStandardAboutPanel` | `:19` |
| Helm → Settings… | ⌘, | `AppDelegate.showPreferences` | `:22-24` |
| Helm → Advanced Options… | none | `AppDelegate.showAdvancedOptions` | `:25-27` |
| Helm → Services | system | `app.servicesMenu` | `:30-34` |
| Helm → Hide / Hide Others / Show All / Quit | ⌘H / ⌥⌘H / none / ⌘Q | standard | `:37-43` |
| File → New Window | ⌘N | `AppDelegate.newWindow` | `:50` |
| File → New Tab | ⌘T | `MainWindowController.newTab` | `:51` |
| File → New Folder | ⇧⌘N (explicit mask, uppercase `N`) | `performNewFolder` | `:53-55` |
| File → Find… | ⌘F | `toggleSearch` (focus + select search field) | `:58` |
| File → Close Tab | ⌘W | `closeTab` (window when last tab) | `:60` |
| Edit → Undo / Redo | ⌘Z / ⇧⌘Z | `undo:` / `redo:` responder selectors | `:67-70`; redo has no filesystem implementation |
| Edit → Cut / Copy / Paste / Select All | ⌘X / ⌘C / ⌘V / ⌘A | `NSText` selectors through the responder chain | `:72-75`; file fallback at `Windows/MainWindowController.swift:289-299`; Select All relies on the widgets' native `selectAll:` [Inferred] |
| Edit → Rename | Return (empty mask) | `performRename` | `:77-79` |
| Edit → Move to Trash | ⌘⌫ (`\u{8}`, explicit ⌘) | `performTrash` | `:80-82` |
| Edit → Properties | ⌘I | `performProperties` | `:84` |
| View → as Grid / as List | ⌘1 / ⌘2 | `switchToGridView` / `switchToListView` | `:92-93` |
| View → Toggle Sidebar | ⌃⌘S | `toggleSidebar` | `:96-98` |
| View → Show Hidden Files | ⌘. | `toggleHiddenFiles` | `:101`; no check state |
| View → Refresh | ⌘R | `refreshDirectory` | `:104-105` |
| Go → Back / Forward | ⌘[ / ⌘] | `goBack` / `goForward` | `:112-113`; never disabled |
| Go → Enclosing Folder | ⌘↑ (function key, explicit ⌘) | `goUp` | `:114-116` |
| Go → Home | ⇧⌘H (uppercase `H`, default mask) | `goHome` | `:118` |
| Go → Go to Folder… | ⌘L | `editPathBar` → `BreadcrumbBar.startEditing` | `:120-121`; no effect in Recent |
| Go → Toggle Star | ⌘D | `performToggleStar` | `:123-124` |
| Window → Minimize / Zoom / Bring All to Front | ⌘M / none / none | standard | `:131-134` |
| Help | empty | `app.helpMenu` | `:137-142` |
| File pane → Quick Look | Space (no modifier check) | `FileListViewController.keyDown` | `Controllers/FileListViewController.swift:114-120` |
| Address editor | Return, Esc, Tab, ⇧Tab, ↑, ↓, → | `doCommandBy` | `Views/AppKit/BreadcrumbBar.swift:691-789` |
| Batch Rename sheet | Return / Esc | default / cancel actions | `Views/SwiftUI/BatchRenameView.swift:77-80` |
| Properties sheet | Esc | Done is `.cancelAction` | `Views/SwiftUI/PropertiesView.swift:85-86` |
| Tab strip | middle-click closes | `otherMouseDown` | `Views/AppKit/TabBarView.swift:162-175` |

Not bound anywhere: open selection (⌘O/⌘↓), next/previous tab, tab by number, duplicate, make alias, eject, empty trash, permanent delete, reopen closed tab, select next/previous column sort, search scope. [Observed: `App/main.swift:45-144`; `Controllers/FileListViewController.swift:114-120`]

### 2.8 Context menus and drag-and-drop contracts

Context menus (`Views/AppKit/FileContextMenuBuilder.swift`):

| Context | Items in order | Evidence |
|---|---|---|
| Exactly one item | Open; Open With ▸; — ; Cut ⌘X; Copy ⌘C; Paste ⌘V; — ; Star / Remove from Starred ⌘D; — ; Rename ↩; Move to Trash ⌘⌫; — ; Properties ⌘I; Share ▸ | `:19-108` |
| Multiple items | Open N Items; — ; Cut; Copy; Paste; — ; Rename N Items…; Move to Trash; — ; Share ▸ (no Star, no Properties) | `:33-37`, `:78-84`, `:96-106` |
| Background | Paste ⌘V; — ; New Folder ⇧⌘N; New File ▸; — ; Properties (directory, no shortcut) | `:112-145` |
| Paste enablement | `NSPasteboard.general.canReadObject(forClasses: [NSURL.self])`; target is always the pane's current directory even when a folder row was clicked | `:52-56`, `:116-120`; `Views/AppKit/FileGridView.swift:92` |
| Sidebar bookmark row | Remove Bookmark | `Views/SwiftUI/SidebarPlacesView.swift:28-32` |
| Breadcrumb | Copy Path (file URLs only) | `Views/AppKit/BreadcrumbBar.swift:325-334` |
| Expanded-child rows (list) | Same menus; the menu receives the actual outline items, so Cut/Copy/Trash work on children here even though menu-bar commands do not | `Views/AppKit/FileListView.swift:298-312` |

Drag and drop:

| Surface | Rules | Evidence |
|---|---|---|
| Grid/list as source | Writes `NSURL` per item; local mask `[.copy, .move]`, external mask `[.copy]`; no link, no custom image | `Views/AppKit/FileGridView.swift:46-49`, `:144-149`; `Views/AppKit/FileListView.swift:75-78`, `:318-321` |
| Grid as destination | Drop **on** a non-package directory → that directory; otherwise the proposal is coerced to `.before` (an insertion gap is drawn as if reordering) and the target is the current directory. Option → copy, else move, read from global `NSEvent.modifierFlags` at validate and at accept | `Views/AppKit/FileGridView.swift:153-212` |
| List as destination | Row is a non-package directory → that directory; any other row or background → the current directory (not the row's parent, even inside an expanded subfolder). Option → copy, else move | `Views/AppKit/FileListView.swift:325-374` |
| Execution | A fresh `FileOperationService` per drop; accept returns `true` immediately; success calls `onDirectoryMutated` (refresh), failure runs a modal alert; the `FileOperationResult` is discarded so nothing is undoable | same |
| Sidebar | Whole list is a drop target that adds directory bookmarks; never moves/copies files; no row highlighting of a specific target | `Views/SwiftUI/SidebarPlacesView.swift:63-75`; `ViewModels/SidebarViewModel.swift:78-92` |
| Not implemented | Spring-loading, tab-hover switching, breadcrumb-segment drops, tab reordering, drag to Dock/Trash semantics beyond the system default, promise drags | absence across the files above |

### 2.9 Preferences and persistence keys

| Key | Default / UI | Consumer | Status |
|---|---|---|---|
| `helm.defaultViewMode` | "grid"; Settings picker | none (`DirectoryViewModel.viewMode` hard-coded `.grid`) | Stub [Observed: `Views/SwiftUI/PreferencesView.swift:5`, `:32-35`; `ViewModels/DirectoryViewModel.swift:11`] |
| `helm.showHiddenFiles` | false; Settings toggle | read at model init; written by Cmd+. | Partial [Observed: `ViewModels/DirectoryViewModel.swift:35`; `Controllers/ContentViewController.swift:184`] |
| `helm.confirmBeforeTrash` | true; Settings toggle | none | Stub [Observed: `Views/SwiftUI/PreferencesView.swift:7`, `:39`] |
| `helm.defaultSortField` / `helm.defaultSortAscending` / `helm.directoriesFirst` | "name" / true / true | none | Stub [Observed: `Views/SwiftUI/PreferencesView.swift:8-10`, `:41-50`] |
| `helm.singleClickToOpen` | false | none | Stub [Observed: `Views/SwiftUI/PreferencesView.swift:11`, `:77`] |
| `helm.gridIconSize` | 64; slider 48–128 step 16 | none (grid hard-codes 96) | Stub [Observed: `Views/SwiftUI/PreferencesView.swift:12`, `:60-63`; `Views/AppKit/FileGridView.swift:248-249`] |
| `helm.liveMonitoringEnabled` | true | checked when monitoring starts; no live stop | Partial [Observed: `Utilities/AppSettings.swift:23-25`; `ViewModels/DirectoryViewModel.swift:83-85`] |
| `helm.showAllMountedVolumes` | false | volume refresh; refresh on defaults change | Full [Observed: `Services/VolumeService.swift:73`, `:97`, `:118`] |
| `helm.enableDirectoryCache` | true | cache read/write; disabling does not purge | Full-ish [Observed: `Services/FileSystemService.swift:25-30`, `:53-56`] |
| `helm.directoryCacheTTL` | 1.5 s; slider 0.2–5.0; floor 0.1 | cache age | Full [Observed: `Utilities/AppSettings.swift:35-37`; `Views/SwiftUI/AdvancedOptionsView.swift:53`] |
| `helm.maxCachedIcons` | 800; stepper 100–4000 step 100; floor 100 | icon cache limit (lazy) | Full [Observed: `Utilities/AppSettings.swift:39-42`; `Services/FileIconService.swift:32-37`] |
| `helm.searchPreferUserFolders` | true | scope construction only (ranking boosts unconditional) | Partial [Observed: `Services/SpotlightSearchService.swift:132`] |
| `helm.searchIncludeSystemLocations` | false | predicate, scopes, penalty, dot-name exclusion | Partial [Observed: `Services/SpotlightSearchService.swift:115`, `:133`, `:171`, `:368`] |
| `helm.searchResultLimit` | 300; stepper 100–800 step 50; floor 50 | candidate cap and output | Full [Observed: `Utilities/AppSettings.swift:52-54`; `Services/SpotlightSearchService.swift:197`, `:220`] |
| `helm.searchDebounceMilliseconds` | 180; stepper 60–500 step 20; floor 40 | debounce | Full [Observed: `Utilities/AppSettings.swift:56-59`; `ViewModels/SearchViewModel.swift:65`] |
| `helm.sidebarLiquidGlass` | false | sidebar appearance | Full [Observed: `Controllers/SidebarContainerController.swift:71`] |
| `helm.maxCachedThumbnails` | 400; floor 50; no UI | read once at singleton init | Partial [Observed: `Services/ThumbnailService.swift:14`] |
| `helm.completionDebounceMilliseconds` | 100; floor 30; no UI | prefix completion delay | Full [Observed: `Views/AppKit/BreadcrumbBar.swift:807`] |
| `helm.bookmarks` | JSON `[URL]` | sidebar (load once, save whole), search scopes and ranking | plain paths, not security-scoped data [Observed: `ViewModels/SidebarViewModel.swift:130-159`; `Services/SpotlightSearchService.swift:154-159`, `:295-301`] |
| `com.helm.starredFiles` | JSON `[URL]` | each `StarredFilesService` instance | [Observed: `Services/StarredFilesService.swift:5-16`, `:56-61`] |
| `helm.recentAccessRecords` | JSON `[{path,lastAccessedAt}]` | `RecentItemsService` | [Observed: `Services/RecentItemsService.swift:7-19`, `:64-75`] |

Registered defaults cover only the `AppSettings` keys and only at launch; SwiftUI `@AppStorage` declares its own fallbacks. [Observed: `Utilities/AppSettings.swift:4-21`; `App/AppDelegate.swift:8`]

---

## 3. Current architecture

### 3.1 Layers and ownership

```
main.swift (top-level code) ─ NSApplication + menus ─▶ AppDelegate
AppDelegate ──[MainWindowController]* (array; block observer tokens discarded)
  MainWindowController (NSWindowController, NSToolbarDelegate)
   ├─ NSToolbar: SidebarToggle | Back/Forward group | BreadcrumbBar | ViewMode segment | NSSearchToolbarItem
   │     BreadcrumbBar (NSView, 930 lines)
   │       ├─ PathCompletionService (actor)#            ← enumerates, caches, builds NSImages via MainActor.run
   │       └─ PathCompletionWindowController (NSObject) ← child NSPanel + NSTableView
   └─ MainSplitViewController (NSSplitViewController)
        ├─ SidebarContainerController
        │    └─ NSHostingController<SidebarPlacesView> ← SidebarViewModel (@MainActor)
        │          ├─ StarredFilesService#  ├─ VolumeService (@MainActor, Combine)
        └─ TabContainerViewController ── TabBarView
             └─ {UUID → ContentViewController}#  (one per tab; retained, re-parented on switch)
                  ├─ NavigationState (Combine, history + selection snapshots)
                  ├─ DirectoryViewModel (@MainActor)
                  │    ├─ FileSystemService (actor)#   ├─ StarredFilesService#   └─ FileMonitorService (actor, FSEvents)#
                  ├─ SearchViewModel (@MainActor) ── SpotlightSearchService (@MainActor, NSMetadataQuery)
                  ├─ FileOperationService (actor)#   ├─ UndoService (@MainActor; owns its own FileOperationService#)
                  ├─ FileContextMenuBuilder (@MainActor)
                  ├─ FileListViewController (QLPreviewPanel data source)
                  │    └─ FileGridView (NSCollectionView)  |  FileListView (NSOutlineView; owns another FileSystemService#)
                  └─ StatusBar
Process-wide singletons: ClipboardService (@MainActor), RecentItemsService (actor), FileIconService (@MainActor),
                         ThumbnailService (@MainActor), PreferencesWindowController, AdvancedOptionsWindowController
Persistence: UserDefaults only (keys in 2.9)           # = instantiated per owner → duplicated state
```

[Observed: `App/main.swift:3-148`; `App/AppDelegate.swift:5`, `:64-82`; `Windows/MainWindowController.swift:5-8`, `:74-82`; `Views/AppKit/BreadcrumbBar.swift:22-23`; `Windows/MainSplitViewController.swift:5-6`; `Controllers/SidebarContainerController.swift:8-12`; `ViewModels/SidebarViewModel.swift:18-19`; `Controllers/TabContainerViewController.swift:6-7`; `Controllers/ContentViewController.swift:7-23`; `ViewModels/DirectoryViewModel.swift:21-23`; `ViewModels/SearchViewModel.swift:17`; `Services/UndoService.swift:8`; `Views/AppKit/FileListView.swift:14`; `Services/ClipboardService.swift:8`; `Services/RecentItemsService.swift:5`; `Services/FileIconService.swift:6`; `Services/ThumbnailService.swift:7`]

### 3.2 Data flow

1. **Input → navigation.** Toolbar, menu, sidebar and item actions funnel through `MainWindowController` → `MainSplitViewController` → `TabContainerViewController` → active `ContentViewController`. `navigateTo` standardizes the URL, validates it is a directory (or `helm://recent`), exits search, snapshots selection into `NavigationState`, pushes history, and starts a cancellable `navigationTask`. [Observed: `Windows/MainWindowController.swift:52-54`, `:212-331`; `Windows/MainSplitViewController.swift:38-80`; `Controllers/TabContainerViewController.swift:198-260`; `Controllers/ContentViewController.swift:124-135`, `:259-287`]
2. **Load.** `loadLocation` re-validates, records `lastStableDirectoryURL`, sets `directoryViewModel.currentURL`, awaits `loadDirectory` (generation-guarded; actor lists, prefetches metadata, caches, applies stars), then **manually** calls `fileListController.reloadData()`, restarts monitoring, and records Recent access. Only after that does the task set `activeLocationURL`, update status, and notify tab/breadcrumb/sidebar. [Observed: `Controllers/ContentViewController.swift:289-312`, `:278-285`; `ViewModels/DirectoryViewModel.swift:38-65`; `Services/FileSystemService.swift:17-59`]
3. **Monitoring.** `FileMonitorService` creates one FSEventStream per tab (since-now, FileEvents + UseCFTypes + NoDefer, 0.3 s latency, utility dispatch queue) bridged to an `AsyncStream` via a retained box; the view model debounces 250 ms by cancelling the previous refresh task and calls `refresh()`. This path never reloads the widgets or status bar. [Observed: `Services/FileMonitorService.swift:18-93`, `:104-138`; `ViewModels/DirectoryViewModel.swift:80-111`]
4. **Search.** `SearchViewModel` debounces and iterates an `AsyncStream` from the MainActor `SpotlightSearchService`; the controller writes each emission into `directoryViewModel.items` (the same array as directory contents) and reloads. Recent also overwrites that array. There is no distinct presentation model for "directory", "search results", or "recents". [Observed: `ViewModels/SearchViewModel.swift:45-92`; `Controllers/ContentViewController.swift:359-371`, `:314-324`]
5. **Selection.** Widgets push selected URLs into `selectedItems`; nothing pushes the other way. Commands resolve URLs against root `displayItems`. [Observed: `Views/AppKit/FileGridView.swift:133-140`; `Views/AppKit/FileListView.swift:273-278`; `Controllers/ContentViewController.swift:649-723`]
6. **Mutation.** Menu/context routes call the tab's `FileOperationService`, then `applyOperationResult` (undo registration, model refresh, widget reload, status). Drag/drop creates its own service and skips that path. Undo runs through yet another service instance inside `UndoService`. [Observed: `Controllers/ContentViewController.swift:405-411`, `:457-475`; `Views/AppKit/FileGridView.swift:194-209`; `Services/UndoService.swift:8-71`]
7. **Location fan-out.** A location change is announced three ways: `onLocationChanged` → `TabContainer.updateTab` (title, breadcrumb, sidebar) and directly `updateBreadcrumb` from the content controller; `switchToTab` repeats the same for tab switches. [Observed: `Controllers/ContentViewController.swift:231-237`; `Controllers/TabContainerViewController.swift:150-157`, `:182-194`]

### 3.3 Filesystem and platform access

| Mechanism | Use and limits |
|---|---|
| `FileManager` | Whole-directory `contentsOfDirectory` with prefetch keys; per-item `resourceValues`; copy/move/trash/remove/create; mounted volumes; `fileExists` checks everywhere as "is navigable". No enumerator streaming, no `NSFileCoordinator`, no `FileManagerDelegate`, no progress. [Observed: `Services/FileSystemService.swift:32-51`; `Services/FileOperationService.swift:57-187`; `Services/VolumeService.swift:71-77`] |
| FSEvents | As in 3.2 step 3. Flags beyond created/removed/renamed/modified collapse to `directoryChanged`; `RootChanged`, `MustScanSubDirs`, mount/unmount and `FSEventStreamStart` failure are ignored; no `DispatchSource` watcher; no deinit cleanup. [Observed: `Services/FileMonitorService.swift:34-62`, `:117-137`; grep] |
| `NSWorkspace` | Open, Open With, icons, app discovery, mount notifications, reveal in Finder. [Observed: `ViewModels/DirectoryViewModel.swift:134`; `Controllers/ContentViewController.swift:436`; `Services/FileIconService.swift:22`; `Services/VolumeService.swift:36-58`; `Views/SwiftUI/PropertiesView.swift:73`] |
| Spotlight | `NSMetadataQuery` only; no index fallback. [Observed: `Services/SpotlightSearchService.swift:48-98`] |
| Quick Look | `QLPreviewPanel` and `QLThumbnailGenerator`. [Observed: `Controllers/FileListViewController.swift:122-158`; `Services/ThumbnailService.swift:10`, `:57-80`] |
| Sandbox, TCC, Full Disk Access | Entitlements file is an empty dictionary: **not sandboxed**. Hardened runtime is enabled in the XcodeGen spec. Info.plist carries Desktop/Documents/Downloads/removable/network usage strings. There is no security-scoped bookmark code, no `NSOpenPanel` grant flow, no detection or recovery UI for TCC denial or missing Full Disk Access; a denied folder simply lists as empty (B-017). Running via `swift run` attributes TCC prompts to the parent terminal. [Observed: `Helm.entitlements:4`; `Helm/project.yml:24`, `:29`; `App/Info.plist:31-40`; grep for security-scope/bookmark APIs: none] |
| Packaging | SwiftPM builds a bare executable with the processed asset catalog and excludes Info.plist/entitlements; only the XcodeGen route produces a signed `.app`. [Observed: `Helm/Package.swift:10-17`; `Helm/project.yml:9-31`] |

### 3.4 Threading and concurrency model

- **Actors:** `FileSystemService`, `FileOperationService`, `FileMonitorService`, `PathCompletionService`, `RecentItemsService`. They serialize state but every filesystem call inside is synchronous and blocking; `async` does not make them cancellable or incremental. [Observed: `Services/FileSystemService.swift:4`; `Services/FileOperationService.swift:55`; `Services/FileMonitorService.swift:12`; `Services/PathCompletionService.swift:14`; `Services/RecentItemsService.swift:3`]
- **MainActor classes:** all view models, `SpotlightSearchService`, `VolumeService`, `ClipboardService`, `UndoService`, `FileIconService`, `ThumbnailService`, `FileContextMenuBuilder`. Search materialization and ranking, properties loading, volume sorting, status-bar capacity reads, template/app enumeration, and slash-ended path browsing therefore do disk I/O on the main thread. [Observed: `Services/SpotlightSearchService.swift:11`, `:187-222`; `ViewModels/PropertiesViewModel.swift:40-98`; `Services/VolumeService.swift:138-141`; `Views/AppKit/StatusBar.swift:53`; `Views/AppKit/FileContextMenuBuilder.swift:151`, `:201`; `Views/AppKit/BreadcrumbBar.swift:477-499`]
- **Manual locking:** `StarredFilesService` is `@unchecked Sendable` with an `NSLock`; the FSEvents box is `@unchecked Sendable`. [Observed: `Services/StarredFilesService.swift:3-7`; `Services/FileMonitorService.swift:96`]
- **Task topology:** unstructured `Task {}` for navigation, search, debounce, monitoring, operations, undo, drops, child loads; generation guards exist only in `loadDirectory` and path completion request IDs; sixteen `NSAlert.runModal()` calls run nested modal sessions from inside those tasks. [Observed: `Controllers/ContentViewController.swift:259-287`, `:461-475`; `ViewModels/DirectoryViewModel.swift:40-41`; `Views/AppKit/BreadcrumbBar.swift:428-441`; grep: 16 `runModal()` sites]
- **Cross-actor values:** `PathCompletionItem` carries `NSImage` across the actor boundary; `representedObject` holds Swift tuples boxed as `Any`. [Observed: `Services/PathCompletionService.swift:5-10`, `:88-104`; `Views/AppKit/FileContextMenuBuilder.swift:157`, `:180`, `:213`]

### 3.5 Settings mechanism

Two parallel systems: `AppSettings` static getters with registered defaults and clamping, and SwiftUI `@AppStorage` with independent defaults. Services poll `AppSettings` on each use; nothing observes changes except the sidebar (appearance + volumes) and the sidebar view model (volumes), which react to **every** defaults write, including the Recent log's write on each navigation. [Observed: `Utilities/AppSettings.swift:3-74`; `Views/SwiftUI/PreferencesView.swift:5-12`; `Views/SwiftUI/AdvancedOptionsView.swift:4-13`; `Controllers/SidebarContainerController.swift:58-66`; `ViewModels/SidebarViewModel.swift:122-127`; `Services/RecentItemsService.swift:34`, `:72-75`]

### 3.6 Build and test topology

- Three descriptions of the same project: `Package.swift` (executable + `Testing` support target + test target), `project.yml` (app, unit-test, UI-test targets, Swift version "5.9", hardened runtime), and a checked-in `project.pbxproj` that lists 25 of 49 app sources, 3 of 7 unit-test sources, omits `main.swift`, and mixes `SWIFT_VERSION = 5.9` (targets) with `5.0` (project). [Observed: `Helm/Package.swift:10-26`; `Helm/project.yml:10-56`; `Helm/Helm.xcodeproj/project.pbxproj:380-429`, `:460`, `:550`, `:585`, `:648`]
- Tests use a repository-defined module named `Testing` (`Check`, `TestRuntime`, a public `__swiftPMEntryPoint`) wired by `@_silgen_name`/`@_cdecl` to a manifest that registers 17 closures (one `#if DEBUG`). One XCTest UI smoke test checks a window exists. [Observed: `Helm/TestingSupport/Testing.swift:20-93`; `Helm/HelmTests/TestManifest.swift:3-11`; `Helm/HelmTests/Flows/FileManagerFlowTests.swift:71-100`; `Helm/HelmUITests/HelmUITests.swift:5-10`]
- Coverage: navigation stacks, hidden filtering, metadata names, recents ordering/pruning, two ranking cases, star toggles, an operation lifecycle, directory model navigation, callback wiring, sidebar bookmark/selection mapping. Nothing covers undo, clipboard, partial failure, monitoring, completion, tabs, UI reload, permissions, or scale. [Observed: all files under `Helm/HelmTests/`]

---

## 4. Bugs and flaws

Severity scale used here: **Critical** (crash or data loss on an ordinary path, or blocks the primary advertised build route), **High** (destructive mistakes, feature-defeating defects, severe stalls), **Medium**, **Low**. 00a's "Blocker" items are re-rated by route (SwiftPM route is primary per `README.md:26-37`). Items marked (confirmed) keep 00a's substance; (corrected) notes what changed; new items start at B-069.

### 4.1 Build and test integrity

| ID | Sev. | Category | Finding |
|---|---|---|---|
| B-001 (corrected: Blocker→High) | High | Build system | Checked-in Xcode project is a stale artifact: 25/49 app files, no `main.swift`, 3/7 test files. Since `README.md:39-47` instructs `xcodegen generate`, this is confusion rather than a hard block, but anyone opening the project directly cannot build. [Observed: `Helm/Helm.xcodeproj/project.pbxproj:380-429`] Fix: delete the generated project from the repo or regenerate in CI and verify membership. |
| B-002 (corrected: Blocker→High, route-specific) | High | Build system | `SWIFT_VERSION: "5.9"` is a language-mode setting; valid modes are 4, 4.2, 5, 6. [Observed: `Helm/project.yml:21`, `:43`, `:55`; `project.pbxproj:460`] [Inferred: xcodebuild rejects the value] The SwiftPM route (`swift-tools-version: 5.9`) is unaffected. Fix: `SWIFT_VERSION: "5"` (or 6 once strict concurrency is clean). |
| B-003 (confirmed) | High | Test route | XcodeGen unit-test target has no dependency on `TestingSupport`; under Xcode 16 `import Testing` would resolve to Apple's swift-testing, where `TestRuntime`/`Check` do not exist. [Observed: `Helm/project.yml:33-43`; `Helm/HelmTests/Services/FileSystemServiceTests.swift:2`; `Helm/TestingSupport/Testing.swift:20`, `:46`] |
| B-004 (corrected: High→Low) | Low | Documentation | README/manifest say Swift 5.9+, code needs 5.10 (`nonisolated(unsafe)`). Any current toolchain compiles it; only the documented minimum is wrong. [Observed: `README.md:22`; `Views/AppKit/BreadcrumbBar.swift:928`; `Views/AppKit/TabBarView.swift:179`] |
| B-005 (corrected: Medium→Low) | Low | Test configuration | `debugRank` is `#if DEBUG` but tests call it unconditionally; however the tests also `@testable import Helm`, which already requires a testability-enabled (debug) build, so release test compilation is impossible regardless. [Observed: `Services/SpotlightSearchService.swift:423-427`; `Helm/HelmTests/Services/SearchRankingTests.swift:3`, `:21`, `:44`] |
| B-006 (confirmed, expanded) | Medium | Test discovery | Custom runner depends on SwiftPM calling `Testing.__swiftPMEntryPoint()` and on `@_silgen_name` cross-module linkage. On a toolchain where XCTest discovery runs instead, the bundle contains zero `XCTestCase`s and "passes" vacuously. [Observed: `Helm/TestingSupport/Testing.swift:70-93`; `Helm/HelmTests/TestManifest.swift:3-4`] |
| B-076 (new) | High | Test route | The local module is literally named `Testing`, the same name as Apple's swift-testing module shipped with Xcode 16 toolchains. Which one `import Testing` binds to depends on search-path precedence; in Xcode the collision is a compile error or silent shadowing. [Observed: `Helm/Package.swift:18-21`; `Helm/HelmTests/*.swift:2-3`] Fix: rename the support module (for example `HelmTestKit`) and adopt XCTest or swift-testing proper. |
| B-007 (confirmed) | Medium | Distribution | `swift run Helm` produces an unbundled executable: no Info.plist, no usage strings, no document types, no icon, TCC attributed to the terminal. Only the Xcode route yields an app. [Observed: `Helm/Package.swift:13`; `README.md:33-37`] |
| B-008 (confirmed) | Low | Assets | AppIcon set declares sizes with no filenames; no artwork exists. [Observed: `Resources/Assets.xcassets/AppIcon.appiconset/Contents.json:2-53`] |

### 4.2 Directory state, navigation, monitoring

| ID | Sev. | Category | Finding |
|---|---|---|---|
| B-009 (corrected: High→Critical) | Critical | Crash / stale UI | FSEvents-triggered `refresh()` mutates `items` without any widget reload; grid and list never observe `$items`. The collection/outline views keep stale counts; unchecked indexing in `itemForRepresentedObjectAt`, `pasteboardWriterForItemAt`, and root `child:ofItem:` then reads past the end once the directory shrinks (file deleted externally, then scroll/resize/drag). [Observed: `ViewModels/DirectoryViewModel.swift:89-111`, `:67-73`; `Views/AppKit/FileGridView.swift:66-68`, `:111`, `:148`; `Views/AppKit/FileListView.swift:95-98`, `:143`] [Inferred: index-out-of-range trap] Fix: one immutable presentation snapshot published to the views; widgets apply updates atomically; bounds-check every datasource access. |
| B-010 (confirmed) | High | Scaling | `displayItems` sorts the whole array on every access; cell configuration, counts, selection sync, context menus, drag writers and status all call it. For 100k entries that is O(n log n) per cell. [Observed: `ViewModels/DirectoryViewModel.swift:17-19`; `Views/AppKit/FileGridView.swift:81-83`, `:98-99`, `:111`, `:134-136`, `:148`; `Controllers/ContentViewController.swift:226`] |
| B-011 (confirmed) | Medium | Selection | Selection restored from history/refresh exists only in the model; widgets are never told. [Observed: `Controllers/ContentViewController.swift:273-276`; `ViewModels/DirectoryViewModel.swift:72`] |
| B-012 (confirmed) | High | Races | `loadLocation` performs side effects (reload, monitoring restart, Recent record, `currentURL`) after an await with no generation check; `loadRecents` assigns awaited results unguarded; the outer cancellation check comes afterwards. [Observed: `Controllers/ContentViewController.swift:270-271`, `:305-311`, `:315-324`] |
| B-069 (new) | Medium | State consistency | `viewWillDisappear` cancels `navigationTask`; if the tab is switched mid-load, the model, monitor and Recent log have already moved to the new directory but `activeLocationURL` (used for status, operations target, tab title, breadcrumb) stays at the old one. The tab then shows new contents under an old title/path. [Observed: `Controllers/ContentViewController.swift:66-72`, `:270-285`, `:305-311`] Fix: commit all location state in one step or make cancellation roll back. |
| B-013 (confirmed) | Medium | Lifecycle | Tabs stop monitoring and exit search on disappearance; nothing resumes on reappearance (no `viewWillAppear`). Hidden tabs also keep stale search results in `items` because `exitSearch` clears the query before results, so the results sink ignores the clear. [Observed: `Controllers/ContentViewController.swift:66-72`, `:359-370`; `ViewModels/SearchViewModel.swift:35-43`; grep: no `viewWillAppear`] |
| B-014 (confirmed) | Medium | Races | `stopMonitoring` fires an unversioned task that can stop a monitor started afterwards. [Observed: `ViewModels/DirectoryViewModel.swift:113-119`; `Services/FileMonitorService.swift:66-76`] |
| B-015 (confirmed) | Medium | Monitoring | Start result ignored; creation failure silently finishes; no root-changed/must-scan/mount handling; no fallback polling. [Observed: `Services/FileMonitorService.swift:40-55`, `:117-137`] |
| B-016 (confirmed) | Medium | Monitoring | Each event cancels the pending 250 ms refresh, so sustained event traffic starves refresh indefinitely; disabling the setting does not stop a running monitor. [Observed: `ViewModels/DirectoryViewModel.swift:97-107`, `:83-85`] |
| B-073 (new) | Medium | Monitoring | `kFSEventStreamCreateFlagFileEvents` on a directory path delivers events for the entire subtree, so browsing Home while a build writes deep inside a project triggers continuous root refreshes (and, with B-016, starvation). Events are not filtered to direct children. [Observed: `Services/FileMonitorService.swift:34-38`, `:117-137`] |
| B-072 (new) | Medium | Leak | `FileMonitorService` has no `deinit`; the FSEventStream and its retained continuation box are released only by an explicit stop. Any teardown path that skips `viewWillDisappear` leaks a running stream per tab. [Observed: `Services/FileMonitorService.swift:12-94`; grep: `deinit` only in `SidebarContainerController` and `VolumeService`] |
| B-017 (confirmed) | High | Error visibility | `error`/`isLoading` are never read by any view; a permission-denied or disconnected folder renders as empty and counts as a successful navigation (history entry, Recent record). `isLoading` is also left `true` when a load is superseded. [Observed: `ViewModels/DirectoryViewModel.swift:43-64`; grep: no consumer] |
| B-018 (confirmed) | Medium | Navigation | Requested initial directory reaches only the breadcrumb; initial tab loads Home. [Observed: `Windows/MainWindowController.swift:24-25`, `:155`; `Controllers/TabContainerViewController.swift:26-28`] |
| B-019 (confirmed) | Medium | History | Fallback-to-Home bypasses `NavigationState`; `goUp` skips the selection snapshot; same-location navigation appends duplicates. [Observed: `Controllers/ContentViewController.swift:295-302`, `:151-156`; `Models/NavigationState.swift:22-28`] |
| B-020 (confirmed) | Medium | Tabs | Search field and view-mode segment are window-level; switching tabs leaves them describing the previous tab. [Observed: `Controllers/TabContainerViewController.swift:150-156`; `Windows/MainWindowController.swift:7-8`, `:238-244`] |
| B-075 (new) | Low | Validation | No `validateMenuItem`/`validateToolbarItem`: Back/Forward are always enabled, "Show Hidden Files" and view-mode items show no state, Edit → Cut/Copy/Trash/Rename are enabled with nothing selected. [Observed: `Models/NavigationState.swift:15-16` (never read in production); grep: no validation hooks] |

### 4.3 Search, sidebar, expanded folders

| ID | Sev. | Category | Finding |
|---|---|---|---|
| B-021 (corrected: High→Medium) | Medium | Races (latent) | `search()` finishes the previous continuation, whose `onTermination` schedules an unconditional `stopSearch()` that would stop the **new** query. In today's wiring `SearchViewModel` cancels the consuming task first, so the deferred stop usually runs before the new query is installed; the hazard is real for any other caller and ordering-dependent. [Observed: `Services/SpotlightSearchService.swift:35`, `:93-97`, `:101-111`; `ViewModels/SearchViewModel.swift:77-78`] Fix: scope termination cleanup to query identity. |
| B-022 (confirmed) | High | Search | Ranked order is destroyed by the directory sort; ranking only decides which 300 survive. [Observed: `Services/SpotlightSearchService.swift:218-221`; `Controllers/ContentViewController.swift:365`; `ViewModels/DirectoryViewModel.swift:17`] |
| B-023 (confirmed) | Medium | Search | Old-query results can land while a new query is pending; the sink checks only that some query is non-empty. [Observed: `ViewModels/SearchViewModel.swift:61-73`; `Controllers/ContentViewController.swift:364`] |
| B-024 (confirmed) | Medium | Search | `NSMetadataQueryLocalComputerScope` is appended to path strings and then run through `URL(fileURLWithPath:)`, turning the symbolic scope into a bogus path under the working directory. [Observed: `Services/SpotlightSearchService.swift:171-183`] |
| B-025 (confirmed) | Medium | Search | Settings conflate scope, ranking, hidden-file policy and system filtering; explicit current-folder searches still get global exclusions. [Observed: `Services/SpotlightSearchService.swift:113-125`, `:131-137`, `:329`, `:368`] |
| B-026 (confirmed) | Medium | Performance / correctness | Newest `max(limit×3,450)` candidates only; per-result disk reads and Home enumeration on the main actor; Home path lowercased before enumeration (breaks on case-sensitive volumes). [Observed: `Services/SpotlightSearchService.swift:197-216`, `:236`, `:274-279`] |
| B-099 (new) | Medium | Search | Unindexed or indexing-disabled locations (many network/external volumes, folders excluded in Spotlight privacy) return nothing with no indication; there is no enumeration fallback and no "no results because…" state. [Observed: `Services/SpotlightSearchService.swift:48-98`; absence of fallback] |
| B-027 (confirmed) | High | Stars | Independent `StarredFilesService` instances per tab and sidebar each persist their full set; last writer wins; sidebar never refreshes after init. [Observed: `Controllers/ContentViewController.swift:10`; `ViewModels/SidebarViewModel.swift:18`, `:25-29`; `Services/StarredFilesService.swift:9-16`, `:56-61`] |
| B-028 (confirmed) | Medium | Stars | Starred files in the sidebar route to folder navigation and fail with "Unable to Open Folder"; starred rows never highlight. [Observed: `ViewModels/SidebarViewModel.swift:32-34`, `:178`; `Controllers/ContentViewController.swift:244-250`] |
| B-029 (confirmed) | Medium | Persistence | Bookmarks loaded once and saved whole per window; stars/bookmarks/recents keyed by path (moves break them; transient unavailability prunes Recent permanently). [Observed: `ViewModels/SidebarViewModel.swift:130-159`; `Services/RecentItemsService.swift:77-84`] |
| B-030 (confirmed) | Medium | Recent | Recency order lost to name sort; hidden toggle has no effect. [Observed: `Controllers/ContentViewController.swift:185-187`, `:321`; `ViewModels/DirectoryViewModel.swift:17`] |
| B-031 (confirmed) | High | Wrong-target mutations | In Recent, `currentURL` is the last stable directory, so New Folder, Paste and background drops create or move files there while the pane shows Recent; a tab opened from Recent initializes the stable directory to `helm://recent`, so those operations hit a non-file URL. Successful operations then replace the Recent/search listing with that directory's contents. [Observed: `Controllers/ContentViewController.swift:31-35`, `:319`, `:405-411`, `:634-647`, `:661-679`; `Views/AppKit/FileGridView.swift:92`, `:188-191`] |
| B-032 (confirmed) | Medium | Expanded folders | Child loads use a separate service, default sort, no hidden/star settings, no in-flight dedupe or generation; a full reload clears the cache while late tasks repopulate it. [Observed: `Views/AppKit/FileListView.swift:14`, `:95-98`, `:127-136`] |
| B-033 (confirmed) | High | Commands vs selection | Menu-bar Copy/Cut/Trash/Rename/Star/Properties and Quick Look resolve against root items only; selected expanded children are silently dropped, and Properties falls back to the directory. [Observed: `Controllers/ContentViewController.swift:649-723`; `Controllers/FileListViewController.swift:160-162`; `Views/AppKit/FileListView.swift:273-278`] |
| B-034 (confirmed) | Medium | Sorting | Column headers advertise sorting but no handler exists; preference keys unused. [Observed: `Views/AppKit/FileListView.swift:39`, `:48`, `:56`; grep: no `sortDescriptorsDidChange`] |
| B-035 (confirmed) | Medium | Sorting | Descending comparator negates equality, violating strict weak ordering. [Observed: `Models/FileItemSort.swift:44`] |
| B-079 (new) | Low | Drag target | Dropping on a non-directory row inside an expanded subfolder targets the pane's root directory rather than that row's parent. [Observed: `Views/AppKit/FileListView.swift:349-354`] |
| B-080 (new) | Low | Volumes | Name-fragment filter hides any volume whose name contains `vm`, `update`, `hardware`, `recovery` or `preboot` (for example a user disk named "VM Images"). [Observed: `Services/VolumeService.swift:15-23`, `:128-131`] |

### 4.4 Mutation, clipboard, undo

| ID | Sev. | Category | Finding |
|---|---|---|---|
| B-036 (confirmed) | High | Clipboard | Internal URLs always win; no `changeCount` tracking, so copying elsewhere (or Copy Path in Helm) still pastes old files; context-menu enablement meanwhile follows the system pasteboard. [Observed: `Services/ClipboardService.swift:30-40`; `Views/AppKit/FileContextMenuBuilder.swift:55`, `:119`] |
| B-037 (confirmed) | High | Clipboard | Cut state is consumed when read, before the move succeeds; a failed move leaves no retry and a later paste copies from stale pasteboard URLs. [Observed: `Services/ClipboardService.swift:32-39`; `Controllers/ContentViewController.swift:662-673`] |
| B-038 (confirmed) | High | Operations | Multi-item loops throw mid-way and return nothing; earlier items stay mutated, un-refreshed and un-undoable. [Observed: `Services/FileOperationService.swift:67-74`, `:91-98`, `:112-118`] |
| B-039 (corrected: High→Medium) | Medium | Operations | Check-then-act unique naming across several independent service instances; `createFile(atPath:)` overwrites if a file appears in between. Requires concurrency to bite. [Observed: `Services/FileOperationService.swift:163-166`, `:192-212`] |
| B-040 (corrected: Medium→High) | High | Data mangling | Dropping an item onto its own folder's background (a sloppy intra-view drag) is a "move into the same directory", which the unique-name helper turns into a **rename** to `name 2`. No same-parent, self, or descendant preflight exists. [Observed: `Views/AppKit/FileGridView.swift:167-168`, `:190-203`; `Views/AppKit/FileListView.swift:352-365`; `Services/FileOperationService.swift:91-96`, `:195-209`] |
| B-041 (corrected: High→Critical) | Critical | Data loss | Undo of Copy, New Folder, New File or template calls permanent `removeItem` on the recorded paths with no identity or emptiness check: Cmd+Z after filling a new folder deletes it and its contents, bypassing the Trash. [Observed: `Services/UndoService.swift:15-21`, `:62-69`; `Services/FileOperationService.swift:129-133`] |
| B-042 (confirmed) | High | Undo | Move/trash undo keeps the destination basename (collision suffix survives) and zips a possibly shorter trash array against sources. [Observed: `Services/UndoService.swift:26-45`; `Services/FileOperationService.swift:112-118`] |
| B-043 (confirmed) | High | Undo | Undo closures are fire-and-forget tasks that swallow errors, register no redo, and never refresh any view. [Observed: `Services/UndoService.swift:17-20`, `:26-33`, `:52-59`] |
| B-044 (confirmed) | Medium | Undo | Drag/drop discards results; the same move is undoable via Paste but not via drag. [Observed: `Views/AppKit/FileGridView.swift:200-202`; `Views/AppKit/FileListView.swift:362-364`] |
| B-045 (confirmed) | Medium | Drag | Operation decided from the global Option flag only; source mask, negotiated operation and volume identity ignored; `isSameVolume` is dead. [Observed: `Views/AppKit/FileGridView.swift:164`, `:194`; `Services/FileOperationService.swift:215-220`] |
| B-046 (confirmed) | High | Rename | Raw names appended as path components; `../x` or `a/b` moves the item elsewhere; batch rename has no validation at all. [Observed: `Services/FileOperationService.swift:137-139`; `Controllers/ContentViewController.swift:579-580`; `Views/SwiftUI/BatchRenameView.swift:172-178`] |
| B-047 (confirmed) | Medium | Batch rename | No conflict/duplicate/swap planning; stops at first error; per-item undo; preview keyed by old name (duplicates across Recent/search). [Observed: `Views/SwiftUI/BatchRenameView.swift:53`, `:141-166`; `Controllers/ContentViewController.swift:609-630`] |
| B-048 (corrected: High→Medium) | Medium | Preferences | `helm.confirmBeforeTrash` (default true) is never consulted. Trash is recoverable, hence Medium. [Observed: `Views/SwiftUI/PreferencesView.swift:7`; `Controllers/ContentViewController.swift:492-503`, `:681-694`] |
| B-049 (confirmed) | Medium | Operations | No progress, cancellation, or per-item reporting; operations outlive the view. [Observed: `Services/FileOperationService.swift:15-36`, `:61-105`; `Views/SwiftUI/OperationProgressView.swift`] |
| B-086 (new) | Medium | Modal handling | Sixteen `runModal()` sites, most invoked from inside `Task { @MainActor }` bodies; nested modal sessions re-enter the main actor while other tasks (loads, monitors, drops) continue, and multi-item failures can stack alerts. [Observed: `Controllers/ContentViewController.swift:378`, `:402`, `:440`, `:472`, `:500`, `:528`, `:541`, `:554`, `:577`, `:588`, `:619`, `:644`, `:676`, `:691`; `Views/AppKit/FileGridView.swift:207`; `Views/AppKit/FileListView.swift:369`] |
| B-070 (new, split out of B-064 and elevated) | High | Main-thread safety | The Open With completion handler constructs and runs an `NSAlert` directly. `NSWorkspace.open(_:withApplicationAt:configuration:completionHandler:)` invokes its handler off the main thread [Inferred from API documentation], so the failure path performs AppKit work on a background thread. [Observed: `Controllers/ContentViewController.swift:436-444`] Fix: hop to `MainActor` before presenting. |

### 4.5 Completion, previews, performance, accessibility, remaining

| ID | Sev. | Category | Finding |
|---|---|---|---|
| B-050 (confirmed) | High | Main-thread I/O | Slash-ended browsing enumerates every child, reads metadata and builds an `NSWorkspace` icon for each before capping at 50, synchronously on the main thread, on every `/` keystroke and every drill. [Observed: `Views/AppKit/BreadcrumbBar.swift:477-520`] |
| B-051 (confirmed) | Medium | Regression | Ancestor segments no longer navigate; hover highlighting still advertises clickability. [Observed: `Views/AppKit/BreadcrumbBar.swift:173-175`, `:883-907`; `README.md:10`] |
| B-052 (confirmed) | Medium | Completion | Text edits clear ghost/debounce but not the visible popup or in-flight request; request IDs advance only when a request starts, so a stale result passes the guard; Escape hides without cancelling pending work. [Observed: `Views/AppKit/BreadcrumbBar.swift:419-445`, `:714-724`, `:791-813`] |
| B-053 (confirmed) | Medium | Completion | Mouse selection does not refresh ghost text; accepted suffix keeps typed casing; caret moves alone do not clear ghost state. [Observed: `Views/AppKit/PathCompletionWindowController.swift:305-308`; `Views/AppKit/BreadcrumbBar.swift:638-646`, `:648-662`] |
| B-054 (confirmed) | Medium | Completion contract | Files are suggested but cannot be committed; Cmd+L is unavailable in Recent; relative paths resolve against the process cwd; invalid entry exits instead of allowing correction. [Observed: `Services/PathCompletionService.swift:136-140`; `Views/AppKit/BreadcrumbBar.swift:184`, `:250-251`, `:256-260`] |
| B-055 (confirmed) | Medium | Thumbnails | Duplicate in-flight requests drop the second subscriber; any holder of the key can cancel the shared request. [Observed: `Services/ThumbnailService.swift:52-55`, `:86-90`] |
| B-056 (confirmed) | Medium | Caches | Keys are path+size with no version; no invalidation on change; thumbnail limit fixed at init; requests ask for `size×2` **and** scale 2.0 (4× intended pixels). [Observed: `Services/ThumbnailService.swift:14`, `:57-62`, `:100-102`; `Services/FileIconService.swift:15-16`] |
| B-057 (confirmed) | High | Memory | Caches bounded by directory count (80 listings per filesystem service, 30 enumerations per completion service), duplicated per tab and per list view; disabling caching keeps old arrays. [Observed: `Services/FileSystemService.swift:108-116`; `Services/PathCompletionService.swift:29`, `:143-150`; `Views/AppKit/FileListView.swift:14`] |
| B-058 (confirmed) | Medium | Main-thread I/O | Status capacity on every selection change; properties metadata/permissions/image header/app list; context-menu template/app/share enumeration; resource reads inside the volume sort comparator; volume refresh and sidebar restyle on **every** defaults write, which includes each navigation's Recent save. [Observed: `Views/AppKit/StatusBar.swift:53`; `ViewModels/PropertiesViewModel.swift:40-98`; `Views/AppKit/FileContextMenuBuilder.swift:151`, `:175`, `:201`; `Services/VolumeService.swift:138-141`; `ViewModels/SidebarViewModel.swift:122-127`; `Controllers/SidebarContainerController.swift:58-66`; `Services/RecentItemsService.swift:34`] |
| B-059 (confirmed) | Medium | Preferences | Default view, sort, directories-first, single-click, icon size are UI-only. [Observed: `Views/SwiftUI/PreferencesView.swift:5-12`; consumers absent] |
| B-060 (confirmed) | Medium | Quick Look | Space handled at a parent controller without modifier checks; `NSTableView` type-select may consume Space in list mode [Inferred]; no panel reload on selection change. [Observed: `Controllers/FileListViewController.swift:114-131`, `:151-162`] |
| B-061 (confirmed) | Medium | Accessibility | Address editor traps Tab/Shift+Tab and re-grabs focus after non-mouse focus loss; no accessible label or suggestion relationship; tabs convey selection by tint only; grid items lack explicit roles. The only accessibility work is SF Symbol descriptions. [Observed: `Views/AppKit/BreadcrumbBar.swift:726-758`, `:826-877`; `Views/AppKit/TabBarView.swift:136-145`; `Views/AppKit/FileGridView.swift:228-255`; grep] |
| B-062 (confirmed) | Low | Appearance/layout | `CGColor`s captured at setup (no effective-appearance hook); equal-width tabs with no overflow; popup not clamped to the screen; temporary error label added to the toolbar superview. [Observed: `Views/AppKit/BreadcrumbBar.swift:271-281`, `:293-306`; `Views/AppKit/TabBarView.swift:38`; `Views/AppKit/PathCompletionWindowController.swift:188-209`] |
| B-063 (confirmed) | Medium | Lifetimes | Discarded observer tokens in `AppDelegate`; completion controller has no deinit; search task holds strong `self` across an indefinite loop. [Observed: `App/AppDelegate.swift:77-79`; `Views/AppKit/PathCompletionWindowController.swift:213-246`; `ViewModels/SearchViewModel.swift:78-91`] |
| B-064 (confirmed, narrowed) | Medium | Concurrency hygiene | `NSImage` across actor boundaries; non-isolated `NSObject` helper driving AppKit; locked static storage in the test runtime; `@unchecked Sendable` boxes. (The Open With case is now B-070.) [Observed: `Services/PathCompletionService.swift:5-10`, `:88-104`; `Views/AppKit/PathCompletionWindowController.swift:5`; `Helm/TestingSupport/Testing.swift:54-55`] |
| B-065 (confirmed) | Medium | Sandbox/permissions | Not sandboxed by design or by accident; plain paths everywhere; enabling App Sandbox would break every persisted reference; no TCC/Full Disk Access guidance. [Observed: `Helm.entitlements:4`; `ViewModels/SidebarViewModel.swift:130-141`] |
| B-066 (confirmed) | Low | Presentation | `sizeInBytes` is a second human-readable string and is unused; folder size is metadata size; app list loaded but hidden; rename preselection uses Character count for an `NSRange` on a not-yet-existing editor. [Observed: `ViewModels/PropertiesViewModel.swift:55-57`, `:97`; `Controllers/ContentViewController.swift:573-575`] |
| B-067 (confirmed) | High | Test gap | No coverage of undo, clipboard, partial failure, nested selection, monitoring/reload, completion, tabs, preferences, permissions, scale, accessibility; the "exact match" ranking test actually exercises a prefix match. [Observed: `Helm/HelmTests/`; `Helm/HelmTests/Services/SearchRankingTests.swift:30-51`] |
| B-068 (confirmed) | Medium | Test hygiene | Star and sidebar tests write to real `UserDefaults.standard` (`com.helm.starredFiles`, `helm.bookmarks`) without restoring; ranking tests read the live Home directory. [Observed: `Helm/HelmTests/Services/StarredFilesServiceTests.swift:7-30`; `Helm/HelmTests/Flows/FileManagerFlowTests.swift:108-111`; `Services/SpotlightSearchService.swift:236`, `:274-279`] |
| B-071 (new) | Medium | Navigation | Symlinked folders are not navigable in-app (treated as files, opened via `NSWorkspace`); `isSymlink` is never used; no alias resolution. [Observed: `Models/FileItem.swift:10`, `:47-48`; `Controllers/ContentViewController.swift:381-395`] [Inferred: `isDirectoryKey` is false on the link itself] |
| B-074 (new) | Low | Drag UX | Coercing the proposal to `.before` draws an insertion gap in the grid as if items could be reordered; the real action is "move into this folder". [Observed: `Views/AppKit/FileGridView.swift:167-168`] |
| B-078 (new) | Low | List view | No `autosaveName`/`autosaveTableColumns`; column widths and order reset on every view switch and launch; no column visibility menu. [Observed: `Views/AppKit/FileListView.swift:34-72`] |
| B-081 (new) | Low | Tabs | Every navigation rebuilds all tab buttons (`tabs` didSet → `rebuildTabs`) and the Home tab is titled by folder name while the breadcrumb says "Home". [Observed: `Views/AppKit/TabBarView.swift:6-8`, `:79-91`; `Controllers/TabContainerViewController.swift:182-186`; `Models/Tab.swift:27-36`] |
| B-083 (new) | Low | Deprecated API | `NSSharingService.sharingServices(forItems:)` is deprecated; replacement is `NSSharingServicePicker`. [Observed: `Views/AppKit/FileContextMenuBuilder.swift:175`] |
| B-087 (new) | Low | Trash | Trash browses only `~/.Trash`; items trashed from other volumes (`/Volumes/X/.Trashes/<uid>`) never appear, and there is no Empty Trash or Put Back. [Observed: `Models/Place.swift:82-92`] |

### 4.6 Why the architecture is unsound

1. **There is no single source of truth for "what is displayed" or "where am I".** The location lives in six places: `NavigationState.currentURL`, `DirectoryViewModel.currentURL` (which lies in Recent), `ContentViewController.activeLocationURL`, `lastStableDirectoryURL`, `Tab.url`, and `BreadcrumbBar.url`; they are updated at different moments by different code. The content array `DirectoryViewModel.items` is overloaded for directory listings, search results, and recents, with the controller sprinkling `isHelmRecentsLocation` checks across seven files to compensate. B-012, B-019, B-020, B-030, B-031, B-069 are all symptoms. [Observed: `Controllers/ContentViewController.swift:7-28`, `:305-306`, `:319`, `:330-335`; `Models/Tab.swift:6`; `Views/AppKit/BreadcrumbBar.swift:5`; `Utilities/URL+Extensions.swift:38-40`]
2. **Model-to-view updates are manual and one-directional.** Views read the model on demand and are refreshed only when the controller remembers to call `reloadData()`; the monitoring path forgets. Selection flows widget→model only. This produces the Critical B-009 and the selection-mismatch class (B-011, B-033). [Observed: `Views/AppKit/FileGridView.swift:66-68`; `ViewModels/DirectoryViewModel.swift:89-111`; `Controllers/ContentViewController.swift:308`, `:409`]
3. **Derived state is recomputed on every read.** `displayItems` sorts on access; `FileItem` arrays are copied through filters per command. Nothing is indexed by URL. This is the direct cause of the 100k-entry scaling problem (B-010). [Observed: `ViewModels/DirectoryViewModel.swift:17-19`]
4. **Services are instantiated per owner instead of injected.** Stars, filesystem cache, monitor, operations, undo, completion and even a second filesystem service inside the list view are created with `= Service()` in property initializers. Consistency bugs (B-027, B-029), cache multiplication (B-057), and racing operation actors (B-039) follow directly; tests cannot substitute fakes. [Observed: `Controllers/ContentViewController.swift:9-17`; `ViewModels/SidebarViewModel.swift:18-19`; `Views/AppKit/FileListView.swift:14`; `Services/UndoService.swift:8`; `Views/AppKit/BreadcrumbBar.swift:23`]
5. **Mutations have no command layer.** Five entry points (menu, context menu, grid drop, list drop, undo) use three different code paths; results are path arrays without identity, undo is a closure over strings, and partial failure is unrepresentable. B-036 to B-049 and the Critical B-041 are consequences of the absence of an operation model, not individual slips. [Observed: `Services/FileOperationService.swift:39-52`; `Services/UndoService.swift:11-71`; `Views/AppKit/FileGridView.swift:194-209`]
6. **The address bar is a monolith that owns policy, I/O and UI.** `BreadcrumbBar` (930 lines) owns a service actor, two task handles, a panel controller, run-loop suppression flags, and timing heuristics (50 ms, 150 ms, next-run-loop). The last commit deliberately added synchronous main-thread I/O to escape its own cancellation bugs (comments at `:460-466`, `:795-802`). The behaviours are good; the structure cannot be tested or extended. [Observed: `Views/AppKit/BreadcrumbBar.swift:18-30`, `:213`, `:385-387`, `:863`]
7. **Concurrency is nominal.** Actors wrap blocking calls; MainActor services do disk I/O; `Task {}` is used as a fire-and-forget primitive with `weak self` and occasional generation counters; modal alerts are run from inside tasks. There is no structured ownership that cancellation can follow. [Observed: Section 3.4]
8. **Virtual locations are not modelled.** Recent is a URL scheme plus special cases rather than a location type with its own data source, sort, operations policy and breadcrumb. Trash is a literal path. Search is a mutation of the directory array. Each new virtual location (tags, network, smart folders) would multiply the special cases. [Observed: `Controllers/ContentViewController.swift:174`, `:185`, `:202`, `:291`, `:331`; `Models/Place.swift:82-92`]
9. **Settings are duplicated and mostly inert.** Two mechanisms, half the keys unwired, change observation by "any defaults write". [Observed: Section 3.5]
10. **The build/test topology is forked three ways and the test harness shadows a toolchain module.** [Observed: Section 3.6; B-001 to B-007, B-076]

### 4.7 What is actually good and worth keeping

- **The address-bar interaction contract** (not its code): path shown with trailing slash, caret at end, immediate listing, trailing `/` lists, `..` first outside root, directories before files, Tab accepts/drills, ghost suffix, Right-arrow accept, Esc twice, empty → Home, beep+shake+message on invalid, outside click cancels, focus survives toolbar relayout. [Observed: `Views/AppKit/BreadcrumbBar.swift:183-234`, `:244-261`, `:467-535`, `:691-789`]
- **Immutable metadata snapshots.** `FileItem` with a fixed prefetch-key set, URL identity, and no live I/O is the right shape for large listings. [Observed: `Models/FileItem.swift:5-66`]
- **Generation-guarded loading and the actor boundary for listing.** `loadDirectory`'s generation check and `FileSystemService` as an actor are the right skeleton; they need extending, not replacing. [Observed: `ViewModels/DirectoryViewModel.swift:38-65`; `Services/FileSystemService.swift:4-59`]
- **`NavigationState` with per-entry selection snapshots.** Small, tested, correct. [Observed: `Models/NavigationState.swift`; `Helm/HelmTests/ViewModels/DirectoryViewModelTests.swift`]
- **The search ranking table and scope policy** as a tunable spec (Section 2.5 F-044/F-045), including the idea of boosting the active directory, bookmarks and shallow user roots; only the plumbing is wrong.
- **Product decisions that express the Nautilus vision:** explicit Cut/Paste moving files; Starred as a first-class place; Recent that includes folders and records app-local access; `~/Templates` as the New File source; Places sidebar ordering; immediate "New Folder"; grid+list only; batch rename modes and tokens; Properties naming. [Observed: Section 1.2]
- **Volume filtering rules** (browsable, system-path and helper-name exclusions, UUID/internal-name dedupe, internal-first sort) encode real-world macOS knowledge worth porting, with the over-broad fragments fixed. [Observed: `Services/VolumeService.swift:10-23`, `:117-147`]
- **The thumbnail pipeline shape:** generic icon immediately, synchronous cache hit, async generation, cancel on reuse, URL check before assignment. [Observed: `Views/AppKit/FileGridView.swift:257-289`]
- **The menu/shortcut map** (Section 2.7) as the keyboard contract, including Return-to-rename, Space-to-preview, Cmd+. hidden files, Cmd+L location entry, Cmd+D star.
- **Tests exist for pure logic** (ranking, navigation, operations, recents, sidebar mapping) and use isolated defaults where the service permits injection; the coverage targets are right even though the harness is not. [Observed: `Helm/HelmTests/Services/RecentItemsServiceTests.swift:15-21`; `Services/RecentItemsService.swift:17-20`]

---

## 5. Open questions

1. **History.** Could not run `git log -p`; the two earliest commits and per-commit diffs are taken from 00a. Confirm whether `727ea51`/`10b9d39` exist and whether `08f0cea` intentionally removed ancestor-segment navigation (is click-to-edit the desired contract, or a regression?).
2. **Build routes.** Does `swift build` succeed on the owner's toolchain, and does `swift test` actually execute the 17 custom cases (versus XCTest reporting zero tests)? Does the XcodeGen route fail on `SWIFT_VERSION 5.9` as inferred?
3. **Folder Tree.** Is the README's Folder Tree sidebar still intended, and should it replace or sit beside Places?
4. **Single-click to open.** The preference exists with Nautilus wording; is it a real requirement for the rebuild?
5. **Distribution and permissions.** Direct download (non-sandboxed, Full Disk Access prompt) or App Store (sandbox, security-scoped bookmarks)? This decides the whole access layer.
6. **Recent semantics.** Should Recent be ordered by access time (service intent) and include folders? Should there be a clear-history action?
7. **Starred versus Finder tags/favorites.** Keep Helm-private stars, or map to Finder tags so they survive outside Helm?
8. **Search.** What does "most-used directories" mean concretely: frequency learning from the Recent log, or the current static preferred-root heuristic? Is a non-Spotlight fallback required for network volumes?
9. **Cross-volume drags and modifiers.** Finder copies across volumes by default; Helm always moves. Which is wanted, and should Cmd force a move?
10. **Collision policy.** Keep automatic `name 2` suffixing, or introduce Replace/Keep Both/Skip dialogs?
11. **Trash model.** Unified per-volume Trash with Empty/Put Back, or keep browsing `~/.Trash`?
12. **Multi-window consistency.** Should stars, bookmarks and tabs sync live across windows (implies one shared store)?
13. **List sorting.** Column-click sorting is advertised by headers; confirm desired semantics (directories-first regardless of direction?).
14. **Quick Look in list mode.** Needs a runtime check that Space reaches the controller rather than type-select.
15. **Open With completion threading.** Confirm on macOS whether the handler runs off-main (B-070).

---

## Appendix A — Coverage

Read in full during this audit:

- Prior document: `docs/rebuild/00a-astra-first-pass.md` (455 lines).
- Root and build files: `README.md`, `.gitignore`, `Helm/Package.swift`, `Helm/project.yml`, `Helm/Helm.xcodeproj/project.pbxproj`, `Helm/Helm.xcodeproj/project.xcworkspace/contents.xcworkspacedata`, `Helm/Helm/App/Info.plist`, `Helm/Helm/Helm.entitlements`, `Helm/Helm/Resources/Assets.xcassets/Contents.json`, `Helm/Helm/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json`.
- App (2): `App/main.swift`, `App/AppDelegate.swift`.
- Models (6): `Models/FileItem.swift`, `Models/FileItemSort.swift`, `Models/NavigationState.swift`, `Models/Place.swift`, `Models/Tab.swift`, `Models/ViewMode.swift`.
- Utilities (3): `Utilities/AppSettings.swift`, `Utilities/FileSize+Formatting.swift`, `Utilities/URL+Extensions.swift`.
- Services (12): `Services/ClipboardService.swift`, `Services/FileIconService.swift`, `Services/FileMonitorService.swift`, `Services/FileOperationService.swift`, `Services/FileSystemService.swift`, `Services/PathCompletionService.swift`, `Services/RecentItemsService.swift`, `Services/SpotlightSearchService.swift`, `Services/StarredFilesService.swift`, `Services/ThumbnailService.swift`, `Services/UndoService.swift`, `Services/VolumeService.swift`.
- ViewModels (4): `ViewModels/DirectoryViewModel.swift`, `ViewModels/PropertiesViewModel.swift`, `ViewModels/SearchViewModel.swift`, `ViewModels/SidebarViewModel.swift`.
- Controllers (4): `Controllers/ContentViewController.swift`, `Controllers/FileListViewController.swift`, `Controllers/SidebarContainerController.swift`, `Controllers/TabContainerViewController.swift`.
- Windows (4): `Windows/AdvancedOptionsWindowController.swift`, `Windows/MainSplitViewController.swift`, `Windows/MainWindowController.swift`, `Windows/PreferencesWindowController.swift`.
- Views/AppKit (7): `Views/AppKit/BreadcrumbBar.swift`, `Views/AppKit/FileContextMenuBuilder.swift`, `Views/AppKit/FileGridView.swift`, `Views/AppKit/FileListView.swift`, `Views/AppKit/PathCompletionWindowController.swift`, `Views/AppKit/StatusBar.swift`, `Views/AppKit/TabBarView.swift`.
- Views/SwiftUI (7): `Views/SwiftUI/AdvancedOptionsView.swift`, `Views/SwiftUI/BatchRenameView.swift`, `Views/SwiftUI/NewFileView.swift`, `Views/SwiftUI/OperationProgressView.swift`, `Views/SwiftUI/PreferencesView.swift`, `Views/SwiftUI/PropertiesView.swift`, `Views/SwiftUI/SidebarPlacesView.swift`.
- Tests (9): `Helm/TestingSupport/Testing.swift`, `Helm/HelmTests/TestManifest.swift`, `Helm/HelmTests/Flows/FileManagerFlowTests.swift`, `Helm/HelmTests/Services/FileSystemServiceTests.swift`, `Helm/HelmTests/Services/RecentItemsServiceTests.swift`, `Helm/HelmTests/Services/SearchRankingTests.swift`, `Helm/HelmTests/Services/StarredFilesServiceTests.swift`, `Helm/HelmTests/ViewModels/DirectoryViewModelTests.swift`, `Helm/HelmUITests/HelmUITests.swift`.
- Git metadata (read-only): `.git` worktree pointer, `/workspace/forge/helm/.git/logs/HEAD`, `.git/logs/refs/heads/forge/rebuild-plan`, `.git/worktrees/helm-plan/logs/HEAD`, `.git/worktrees/helm-plan/COMMIT_EDITMSG`, `.git/packed-refs`.

Swift file count: 58 source/test files plus `Package.swift` (00a's "59" includes the manifest). Supplementary greps confirmed the absence of: `validateMenuItem`/`validateToolbarItem`, `viewWillAppear`, `sortDescriptorsDidChange`, security-scoped bookmark APIs, Full Disk Access handling, `RootChanged`/`MustScanSubDirs` handling, and any production consumer of `isSymlink`, `isSameVolume`, `invalidateCache`/`clearCache`, `formatExact`, `pathComponentsFromRoot`, `isRoot`, `volumePath`, `canGoBack`/`canGoForward`, `updateActiveTabTitle`, `isTabBarVisible`, `Place.icon`, `OperationProgress`, `NewFileView`, `DirectoryViewModel.error`/`isLoading`.

## Appendix B — Reconciliation with 00a

**Citation spot-check.** I re-derived every file:line reference in 00a's feature inventory, menu map, context-menu table, drag table, preferences table, architecture section and all Critical/High bugs, plus most Medium/Low bugs: approximately 180 citations. Wrong file or wrong claim: **0**. Imprecise by a few lines (pointing at an adjacent comment or declaration rather than the operative statement): **3** — `F-003` MWC:163 (comment; code at :167), `F-034` SidebarPlacesView:60 (list style; backgrounds at :61-62), `B-061` BreadcrumbBar:192 (field creation; Tab handling at :726-758). 00a's history table (`727ea51`, `10b9d39`, per-commit contents) could not be verified without a shell.

**Confirmed as written (IDs retained):** F-001, F-003 to F-040, F-042 to F-067 (all 00a feature items except F-002 and F-041, which are confirmed with refinements noted in their rows); B-003, B-006 to B-020, B-022 to B-038, B-042 to B-047, B-049 to B-068.

**Corrected (ID retained, change noted):**
- B-001, B-002: "Blocker" → High; they block only the optional Xcode route, the SwiftPM route is documented as primary.
- B-004: High → Low (documentation-only mismatch).
- B-005: Medium → Low; `@testable import` already precludes release test builds.
- B-009: High → Critical (plausible crash on an everyday external change plus stale UI).
- B-021: High → Medium; in the current wiring the ViewModel's task cancellation runs the deferred stop before the new query is installed, so the defect is latent/ordering-dependent rather than "every replacement search is cancelled".
- B-039: High → Medium (needs concurrent operations).
- B-040: Medium → High (an ordinary intra-view drag silently renames files).
- B-041: High → Critical (Cmd+Z permanently deletes user work placed in a created folder or an edited copy).
- B-048: High → Medium (trash is recoverable).
- B-064: narrowed; its Open With sub-point becomes B-070 at High.
- F-002: refined; initial-tab propagation failure is tracked as B-018.
- F-041: "Stub" → Partial; list view inherits native type-to-select from view-based `NSTableView` (inferred), grid has none.
- F-010/F-030/F-049: details added (tab title rule for Home, 180/300 limits, unreachable `performQuickLook` chain).

**Rejected:** none outright. The only substantive disagreement is the practical severity of B-021 (above).

**Newly found in this pass:** F-068 (state restoration scope), F-069 (symlink/alias handling absent), F-070 (multi-open semantics); B-069 (cancelled navigation leaves location state split), B-070 (Open With alert off-main), B-071 (symlinked folders not navigable), B-072 (FSEventStream leak without deinit), B-073 (recursive FSEvents noise), B-074 (misleading insertion indicator), B-075 (no menu/toolbar validation), B-076 (`Testing` module shadows swift-testing), B-078 (list columns not autosaved), B-079 (drop target inside expanded subfolder), B-080 (over-broad volume name filter), B-081 (tab rebuild per navigation, Home title mismatch), B-083 (deprecated sharing API), B-086 (modal alerts from tasks), B-087 (single-volume Trash), B-099 (silent empty search on unindexed locations).

**Suggested ordering for Phase 1 (unchanged in spirit from 00a, re-prioritised by severity):** stabilise the build/test routes (B-001 to B-007, B-076); introduce one location model and one published presentation snapshot to retire B-009, B-012, B-013, B-020, B-031, B-033, B-069; replace the mutation paths with a single command/journal layer before touching features (B-036 to B-049, B-041 first); then performance (B-010, B-050, B-057, B-058). Preserve the behaviours catalogued in Section 2 and 4.7 as the acceptance contract for the rewrite.


---

# Appendix C: Errata and additions from the Opus review (takes precedence)

## 3. Missed and wrong bugs

### 3.1 New rows (written to fold verbatim into the audit)

| ID | Sev. | Category | Finding |
|---|---|---|---|
| B-100 (new) | High | Crash / undo lifetime | Undo actions are registered on the per-window `UndoManager` with the per-tab `UndoService` as target. Closing the tab releases the controller and the service, and nothing calls `removeAllActions(withTarget:)`. `UndoManager` holds that target unowned, so Cmd+Z after closing the tab that made the change dereferences a freed object. [Observed: `Services/UndoService.swift:17`, `:26`, `:38`, `:52`, `:64`; `Controllers/ContentViewController.swift:15`, `:407`; `Controllers/TabContainerViewController.swift:110-114`; search: no `removeAllActions`] [Inferred: crash, from the `registerUndo(withTarget:handler:)` contract] Fix: one window-scoped journal as undo target, or remove actions on teardown. |
| B-101 (new) | High | Scaling / main thread | Grid selection sync reads `displayItems` twice per selected index path, and each read re-sorts everything. A Select All, range, or rubber-band selection on n items costs about 2n full sorts, O(n² log n) localized compares, on the main thread. The grid context menu repeats this. Estimated, not measured: tens of seconds at 1,000 items, effectively a hang at 10,000. List mode avoids it through `outlineView.item(atRow:)`. [Observed: `Views/AppKit/FileGridView.swift:81-84`, `:134-137`; `ViewModels/DirectoryViewModel.swift:17-19`; `Views/AppKit/FileListView.swift:275`] Fix: immutable sorted snapshot with a URL index. |
| B-102 (new) | High | Keyboard / focus | Nothing gives the file pane keyboard focus. The only `makeFirstResponder` calls target the search field and the address field, and the main window has no `initialFirstResponder` or key-view loop. After launch, a tab switch, a view-mode switch (which destroys the focused widget), or leaving the address bar, arrow keys, type-select, Space, and Select All cannot reach the pane until a click. This contradicts the keyboard-first goal. [Observed: `Windows/MainWindowController.swift:248`; `Views/AppKit/BreadcrumbBar.swift:215`, `:264-265`, `:398`; `Controllers/TabContainerViewController.swift:134`; `Controllers/FileListViewController.swift:52-53`; `README.md:13`] [Inferred: runtime focus result] Fix: explicit focus model covering load, tab switch, mode switch, and address-bar exit. |
| B-103 (new) | Medium | Lifecycle | `application(_:openFile:)` is documented to arrive before `applicationDidFinishLaunching` when an open request launches the app. A cold `open -a Helm <folder>` therefore builds a window before `AppSettings.registerDefaults()` runs, then a second window at launch. With B-018 both show Home. [Observed: `App/AppDelegate.swift:7-10`, `:33-38`] [Inferred: ordering from delegate docs] Fix: buffer open requests until launch completes. |
| B-104 (new) | Medium | Races / monitoring | Stream termination is matched by pointer value. `monitor()` releases the old stream and creates a new one in the same actor turn, and the old stream's deferred `handleTermination` runs afterwards. If the allocator reused the address, it tears down the new stream and clears `continuation` without finishing it, leaving monitoring dead and the consumer suspended. [Observed: `Services/FileMonitorService.swift:19`, `:57-62`, `:66-87`] [Inferred: address reuse plausible, not shown] Fix: monotonically increasing generation token. |
| B-105 (new) | Medium | Undo | Undo registration reads `view.window?.undoManager` after the awaited operation. If the tab was hidden meanwhile, `view.window` is nil and registration silently does nothing. [Observed: `Controllers/ContentViewController.swift:407`, `:615`; `Services/UndoService.swift:12`; `Controllers/TabContainerViewController.swift:134`] Fix: capture the journal before the operation starts. |
| B-106 (new) | Medium | Clipboard / drop | Paste and drop read `[NSURL.self]` without `.urlReadingFileURLsOnly`, so a web link on the pasteboard is treated as a file and ends in an error alert. [Observed: `Services/ClipboardService.swift:43`, `:52`; `Views/AppKit/FileGridView.swift:177`; `Views/AppKit/FileListView.swift:344`] Fix: file-URL-only read option. |
| B-107 (new) | Medium | Concurrency | Actors run blocking `FileManager` calls on Swift's fixed-width cooperative pool, with no timeout. Hung mounts or long copies pin pool threads, and enough of them stall unrelated async work across tabs. [Observed: `Services/FileSystemService.swift:34`; `Services/FileOperationService.swift:72`, `:96`; `Services/PathCompletionService.swift:128`; `Services/RecentItemsService.swift:80`] [Inferred] Fix: dedicated I/O executor with cancellation and timeouts. |
| B-108 (new) | Medium | Keyboard trap | While the address editor is open, Cmd+F moves focus to search, the end-editing notification is not a mouse event, and `ensureFieldEditorActive()` takes focus back. With Tab consumed, Esc is the only keyboard exit. [Observed: `Windows/MainWindowController.swift:246-250`; `Views/AppKit/BreadcrumbBar.swift:726-758`, `:826-877`] [Inferred: runtime focus order] Fix: treat programmatic focus moves as intentional. |
| B-109 (new) | Medium | Permissions | `~/.Trash` is TCC-protected on current macOS. Without Full Disk Access the Trash place probably lists as empty (B-017), and undo of Move to Trash, which moves out of that folder, can fail silently (B-043). [Observed: `Models/Place.swift:82-92`; `Services/UndoService.swift:38-45`] [Inferred: TCC behaviour] Fix: detect denial, show it, and define a real Trash and Put Back model. |
| B-110 (new) | Low | Completion | `..` from a first-level folder gets `fullPath` `//`, which passes the `expanded != "/"` check, so root keeps a `..` row that can produce `/../`. Commit still standardizes the path. [Observed: `Views/AppKit/BreadcrumbBar.swift:508-517`] Fix: normalize paths before building rows. |
| B-111 (new) | Low | Completion | `show()` reloads and selects row 0 without scrolling to it, so the selected row can be out of view. [Observed: `Views/AppKit/PathCompletionWindowController.swift:36-39`; scrolling only at `:107`, `:114`] Fix: scroll on show. |
| B-112 (new) | Low | Input | Keys typed in the 50 ms between Cmd+L and focus reach the previous responder. [Observed: `Views/AppKit/BreadcrumbBar.swift:213`] Fix: establish focus synchronously where possible. |
| B-113 (new) | Low | Stars | Starred rows come from `Array(Set)` with no sort, so order can change between launches. [Observed: `Services/StarredFilesService.swift:52`; `ViewModels/SidebarViewModel.swift:95-105`] Fix: stable sort. |
| B-114 (new) | Low | Lifecycle | `application(_:openFiles:)` never calls `NSApp.reply(toOpenOrPrint:)`. [Observed: `App/AppDelegate.swift:46-50`] Fix: reply after handling. |
| B-115 (new) | Low | Editing | Programmatic editor writes go directly to text storage, bypassing `shouldChangeText`, so Cmd+Z after a Tab completion may apply stale ranges. [Observed: `Views/AppKit/BreadcrumbBar.swift:373-377`] [Inferred] Fix: use the text-view editing API. |
| B-116 (new) | Low | Naming | Collision checks follow symlinks, so a dangling link at the destination fails instead of suffixing. `a.tar.gz` becomes `a.tar 2.gz`. [Observed: `Services/FileOperationService.swift:195`, `:199-207`] Fix: use a no-follow check and specify multi-part extensions. |
| B-117 (new, unverified) | High if confirmed | Sheets | Properties Done and Batch Rename Cancel and Rename call `self?.dismiss(nil)` on the presenting controller. That overload acts on the receiver's own presentation, and this controller is not presented, so I expect a no-op and a sheet that cannot be closed. [Observed: `Controllers/ContentViewController.swift:597`, `:601`, `:606`, `:731`, `:734`] [Inferred: needs a run] Fix: `dismiss(hostingController)`. |
| B-118 (new, unverified) | Medium if confirmed | Menus | Rename binds unmodified Return with no validation. Depending on AppKit's dispatch order, Return in the address bar, search field, or Settings windows could run Rename on the pane's selection. [Observed: `App/main.swift:77-79`; `Windows/MainWindowController.swift:305-307`; no validation hooks in search] [Inferred] Fix: validate against first responder and selection. |

### 3.2 Existing bugs understated

- **B-009:** grid index mapping makes destructive actions hit the wrong file. See C-30.
- **B-010:** the practical ceiling is probably low thousands of items, not 100k. List reload may be quadratic if `child:ofItem:` runs eagerly.
- **B-013:** `viewWillDisappear` may also fire on miniaturize or hide, with no resume path.
- **B-029:** bookmarks on unmounted volumes are filtered at load, then lost on the next save.
- **B-040:** Cut then Paste into the same folder has the same rename effect as a sloppy drag.
- **B-041:** Cmd+Z typed in a text field can walk from typing undo into this permanent delete, because the stack is shared [Inferred].
- **B-052:** typing and pressing Return before the debounce commits the stale selected row, including `..`.
- **B-058:** `NSWorkspace.icon(forFile:)` per visible cell belongs on this list. Window move, window resize, and split drag also write defaults, so they probably trigger the same volume refresh [Inferred].
- **B-073:** every event also hops to the main actor and allocates a task, with an unbounded stream buffer.

### 3.3 Re-ratings and false positives

No register entry is an outright false positive. These need adjusting:

| ID | Change | Reason |
|---|---|---|
| B-011 | Medium → High | Destructive commands act on a selection the user cannot see |
| B-021 | Medium → Low | The only caller cancels first, so the path is unreachable today |
| B-035 | Medium → Low | Latent: nothing produces a descending sort |
| B-036 | Keep High, fix text | First clause true, second clause wrong at runtime |
| B-057 | High → Medium | Real, but bounded and low impact for typical folders |
| B-070 | High → Medium | Failure path only |
| B-072 | Medium → Low | Normal teardown stops the stream; leak needs a race (B-014) |

### 3.4 Runtime checks, in priority order

| # | Check | Decides |
|---|---|---|
| R-1 | Open Properties and press Done, then Esc. Repeat with Batch Rename Cancel | B-117 |
| R-2 | Copy in tab 2, close tab 2, press Cmd+Z | B-100 |
| R-3 | With a file selected, Cmd+L, type a path, press Return. Also Return in search and in Settings | B-118 |
| R-4 | Grid: select a file, enter a folder, go Back, press Cmd+⌫ | B-011 |
| R-5 | Change a directory externally, then click and Trash a grid item | B-009 |
| R-6 | Time Select All at 1k and 10k grid items, and list reload at 5k | B-010, B-101 |
| R-7 | Right-click an unselected grid item, dismiss the menu, check the status bar | F-038 |
| R-8 | Check highlight against status count after navigation and Cmd+R in both views | B-011 |
| R-9 | Expand a list folder for the first time | F-037 |
| R-10 | Context-menu Paste with an empty pasteboard | F-051 |
| R-11 | Cmd+Up at `/`, then Back | F-006 |
| R-12 | Cold `open -a Helm <folder>` | B-103 |
| R-13 | Browse Trash and undo a trash without Full Disk Access | B-109 |
| R-14 | Minimize and restore, then change a file externally | B-013 |
| R-15 | Search inside `/System` or `/Library` with default settings | F-044 |
| R-16 | Press Cmd+F while the address editor is open | B-108 |
| R-17 | Commit an invalid path and check whether the red label is visible or clipped | F-015 |
| R-18 | Rename `foo` to `Foo` on a case-insensitive volume | F-054 |
| R-19 | Run `swift build`, `swift test`, and the XcodeGen route | B-002, B-003, B-006, B-076 |

---


## C.5 Corrections to fold in (C-xx items)

### 5.1 Vision and inventory

**C-01. §1.2, batch rename row, first cell.** Replace with: `Batch rename with "Find and replace" and template tokens such as [Original file name]; Helm's "Add Text" mode is its own.`

**C-02. §1.3 heading.** Replace with `### 1.3 Observed differences from Finder (intent is not established by the source)`. Append this bullet: `The shortcut map is largely Finder-compatible rather than Nautilus-derived (⌘[ ⌘] ⌘↑ ⇧⌘N ⇧⌘H ⌘1 ⌘2 ⌃⌘S ⌘I ⌘⌫, Return to rename, Space to preview). [Observed: App/main.swift:45-124]`

**C-03. §1.1.** Append: `The keyboard goal is not met today: no code gives the file pane keyboard focus (B-102). [Observed: Windows/MainWindowController.swift:248; Views/AppKit/BreadcrumbBar.swift:215, :398]`

**C-04. F-002.** Append: `On a launch caused by an open request, the request probably arrives before launch finishes, producing two windows, both at Home (B-103). application(_:openFiles:) never replies (B-114).`

**C-05. F-003.** Replace `frame autosave HelmMainWindow, centred` with: `autosave name HelmMainWindow, then center() at every creation, so the saved origin is overwritten and new windows open at the same spot.`

**C-06. F-068.** Replace its first sentence with: `Split position and settings-window sizes may persist through autosave names, but window position is not restored because center() follows the autosave call.`

**C-07. F-006.** Replace `no-op at virtual locations and at /` with: `no-op at virtual locations. At / the guard relies on deletingLastPathComponent returning /, which I expect it does not, so a history entry may be pushed while the view stays at /. [Inferred]`

**C-08. F-013.** Append: `Clicking a separator does nothing. [Observed: Views/AppKit/BreadcrumbBar.swift:916-920]`

**C-09. F-017.** Replace `(parent, except at /)` with: `(parent, except when the text is exactly /; from a first-level folder the row's path is //, B-110)`

**C-10. F-021.** Replace its last sentence with: `Any text not ending in / is exposed to a stale popup until the debounced request replaces it. Fast typing then Return commits the old selected row, which may be .. or an empty-field selection (B-052).`

**C-11. F-023.** Append: `Input using ~ or a relative path gets the popup but no ghost text, because rows hold absolute paths. Tab rewrites the field to the absolute path.`

**C-12. F-024.** Append: `Cmd+F cannot leave the editor because non-mouse focus loss is taken back (B-108). Esc is the only keyboard exit.`

**C-13. F-031.** Replace `"Show all mounted volumes" disables all filtering` with: `"Show all mounted volumes" removes the hidden, browsable, path, name, and internal-name filters, but UUID dedupe still applies. [Observed: Services/VolumeService.swift:89-91]`

**C-14. F-032.** Append: `Without Full Disk Access this folder probably lists as empty (B-109). [Inferred]`

**C-15. F-035.** Replace `two lines, middle truncation` with: `maximumNumberOfLines 2 with middle truncation, which probably renders one line [Inferred]`

**C-16. F-037.** Append: `Items are Swift structs boxed for AppKit, so reloadItem identity needs a macOS check.`

**C-17. F-038.** Replace `No reverse binding (model → widget).` with: `No reverse binding. Grid right-click uses selectItems, which I expect does not call the delegate, so the model and status bar can stay stale. List selection may persist by row index across reloads. See B-011.`

**C-18. F-039.** Replace `(scroll, expansion and visible selection lost)` with: `(scroll and expansion lost; visible selection lost while model selection survives, so commands act on an invisible selection, B-011)`

**C-19. F-043.** Append: `Search is subtree-wide. Results show names without location, so same-named files are indistinguishable.`

**C-20. F-044.** Append: `The kMDItemPath exclusions may have no effect, since API documentation says the attribute cannot be queried. Then only the −650 rank penalty applies. [Inferred; R-15]`

**C-21. F-049.** Append: `No previewPanel(_:handle:) or source frame, and Space can preview an invisible selection.`

**C-22. F-050.** Replace `folder size is metadata size` with: `size is totalFileSize ?? fileSize ?? 0 with no recursive total, so folders probably show "Zero KB" [Inferred]; background Properties in Recent shows the last stable directory.`

**C-23. F-051.** Replace `Context-menu Paste enablement checks only the system pasteboard.` with: `The builder assigns isEnabled from the system pasteboard, but menus use default auto-enabling, so Paste is probably always enabled and an empty paste silently does nothing. [Inferred: R-10]`

**C-24. §2.8.** Replace the Paste enablement row's middle cell with: `isEnabled is assigned from the system pasteboard, but auto-enabling overrides it, so Paste is probably always enabled. The target is always the pane's current directory, even when a folder row was clicked.`

**C-25. §2.8 Execution row and §2.9.**
- Append to the Execution row: `Only the destination pane refreshes. A tiny intra-view drag, or Cut then Paste in the same folder, renames the item to name 2.`
- Append to §2.9: `AppKit also persists window and split frames under their autosave names. SwiftPM and Xcode builds probably use different defaults domains, so stored bookmarks, stars, and recents may not carry between them. [Inferred]`
- Add these rows to §2.1:
  - `| F-071 (new) | Keyboard focus | Stub | No code focuses the file pane; no initial first responder or key-view loop (B-102). |`
  - `| F-072 (new) | Window identity | Partial | Title stays "Helm" and is hidden; no representedURL or proxy icon. [Observed: Windows/MainWindowController.swift:33, :36] |`

### 5.2 Architecture

**C-26. §3.2 step 1, first sentence.** Replace with: `Toolbar and menu actions go through MainWindowController; many reach TabContainerViewController directly. Sidebar navigation starts at MainSplitViewController. Item open, context menu, and selection go straight from FileListViewController to ContentViewController.`

**C-27. §3.3 Sandbox row.** Mark the `swift run` sentence `[Inferred]`.

**C-28. §3.4 Task topology.** Replace `generation guards exist only in loadDirectory and path completion request IDs` with: `identity guards exist in loadDirectory, path completion request IDs, Spotlight query IDs, and thumbnail URL checks; navigation, monitoring, undo, and drops have none.` Append: `Blocking FileManager calls in actors occupy cooperative-pool threads (B-107).`

**C-29. §4.6 and §4.7.**
- §4.6 item 1: replace `six places` with `at least seven places, adding SidebarViewModel.currentDirectoryURL`.
- §4.6 item 1: replace `across seven files` with `seven checks in ContentViewController, twelve occurrences across five files`.
- §4.7: replace `Small, tested, correct.` with `Small and a sound shape. Back and forward stacks are tested; goUp is untested and duplicates are allowed (B-019).`
- §4.7 immutable snapshots bullet, append: `Caution: equality and hash use URL only, and URL form varies, so canonicalize identity and compare content separately.`
- §4.7 product decisions: remove `immediate "New Folder"`. Add under §5: `New Folder flow: keep immediate creation, or prompt or inline-rename?`

### 5.3 Bug register

**C-30. Replace the B-009 row with:**
`| B-009 (corrected: High→Critical, scope widened) | Critical | Crash / wrong target / stale UI | FSEvents-triggered refresh() replaces items with no widget reload, and grid and list never observe $items. (1) Wrong target: the grid maps widget index paths through the current model, so after an external add, remove, or rename, the visible cell and the resolved file differ. Selection, context-menu targets, and drop-on-folder targets can act on a different item than the one displayed, including Move to Trash. List mode resolves selection through cached row items and is not exposed in the same way. (2) Crash: unchecked indexing reads past the end once the directory shrinks. (3) View replacement: monitoring continues during search, so an event overwrites results in the model while widgets still show them; a drop refreshes only the destination pane. [Observed: ViewModels/DirectoryViewModel.swift:54, :97-107; Views/AppKit/FileGridView.swift:66-68, :81-84, :111, :134-137, :148, :162, :184, :204; Views/AppKit/FileListView.swift:143; Controllers/ContentViewController.swift:365] [Inferred: trap and wrong-file outcome] Fix: one immutable presentation snapshot; atomic widget updates; resolve actions by stable identity. |`

**C-31. B-010.** Append: `Practical ceiling is probably low thousands of items. List reload may be quadratic if child:ofItem: is called eagerly. See B-101.`

**C-32. Replace the B-011 row with:**
`| B-011 (corrected: Medium→High) | High | Selection / destructive commands | Model selection and visible selection diverge. After Back or Forward, the model restores a selection with no widget update; after a view-mode switch, it survives while the new widget shows none. The status bar reports N selected, and Trash, Cut, Rename, Star, and Space act on those items. Example: double-click a folder, go Back, press Cmd+⌫, and that folder is trashed with nothing highlighted. List selection may also persist by row index across reloads, highlighting a different file than the model holds. [Observed: Controllers/ContentViewController.swift:273-279, :682-687; ViewModels/DirectoryViewModel.swift:72; Controllers/FileListViewController.swift:52-70] [Inferred: widget retention] Fix: URL-keyed selection as source of truth, applied to widgets after every reload. |`

**C-33. B-013.** Append: `viewWillDisappear may also fire on miniaturize or hide, with no resume path. [Inferred; R-14]`

**C-34. B-021.** Change severity to Low. Append: `The only caller cancels first, so the path is unreachable today.`

**C-35. B-029.** Append: `Bookmarks on unmounted volumes are filtered at load and lost on the next save. [Observed: ViewModels/SidebarViewModel.swift:138-141, :154-158]`

**C-36. B-035.** Change severity to Low. Append: `Latent: nothing produces a descending sort.`

**C-37. B-036.** Replace `context-menu enablement meanwhile follows the system pasteboard` with: `context-menu Paste is probably always enabled, because auto-enabling overrides the assigned isEnabled.`

**C-38. B-040.** Append: `Cut then Paste into the same folder has the same effect. [Observed: Controllers/ContentViewController.swift:663, :669]`

**C-39. B-041.** Append: `The undo stack is shared with field-editor typing, so repeated Cmd+Z in a text field can reach this delete. [Inferred]`

**C-40. B-052.** Append: `Consequence: type a name and press Return before the debounce, and the stale selected row is committed, including .. (F-021).`

**C-41. B-057.** Change severity to Medium.

**C-42. B-058.** Append: `Also NSWorkspace.icon(forFile:) per visible cell. Window move, window resize, and split drag write autosaved frames, so they probably trigger the same volume refresh. [Inferred]`

**C-43. B-070.** Change severity to Medium. Append: `Failure path only.`

**C-44. B-072.** Change severity to Low. Append: `Normal teardown stops the stream; the leak needs the B-014 race.`

**C-45. B-073.** Append: `Each event also hops to the main actor and allocates a task, with an unbounded stream buffer.`

**C-46. Citation fixes.**
- B-005: change `SearchRankingTests.swift:3` to `:4`.
- B-076: change `Helm/HelmTests/*.swift:2-3` to `Helm/HelmTests/TestManifest.swift:1 and the import Testing line (2 or 3) of each test file`.

**C-47. New bugs.** Append rows B-100 to B-118 from §3.1 of `docs/rebuild/00b-opus-review.md` to §4.5. Keep B-117 and B-118 marked unverified.

**C-48. §5 Open questions.** Add: `Run checks R-1 to R-19 from docs/rebuild/00b-opus-review.md §3.4 on macOS before treating Inferred runtime findings as fact.`

**C-49. Appendix A.** Add these to the dead-code list: `ClipboardService.hasItems, FileSystemService.volumeInfo, MainWindowController.performCopy/performCut/performPaste, FileItem.displayName/fileExtension, ViewMode.displayName/systemImageName, FileItemSort.toggling, PathCompletionWindowController.updateItems.`

**C-50. Appendix B.** Add: `A later independent check found the "0 wrong" result for 00a did not carry through to this document's own runtime claims: 00a's note on default menu auto-validation was dropped, and F-051 became wrong as a result.`

### 5.4 Verdict

The audit is safe to use as the base document once these corrections are folded in. Treat its line references as dependable, its static claims as about 90% reliable, and its runtime consequences as hypotheses until §3.4 has been run. Its severity ordering needs B-009, B-011, B-100, B-101, and B-102 near the top.

### 5.5 Top 10 things a rebuilder must not lose

1. **The address-bar contract.** Path with trailing slash, caret at end, immediate listing, `..` first outside root, directories first, Tab accepts or drills, ghost suffix, Right-arrow accept, Esc twice, empty means Home, beep and shake on invalid, outside click cancels, and editing survives toolbar relayout.
2. **The address-bar safety rules.** Keep the file-versus-folder commit distinction, and fix the stale-row Return rather than porting it.
3. **Explicit Cut and Paste moves with text-first routing.** ⌘X, ⌘C, and ⌘V act on text when an editor has focus and on files otherwise.
4. **The full keyboard map in §2.7.** Include Return to rename, Space for Quick Look, ⌘. for hidden files, ⌘L for location, ⌘D for star, and ⌃⌘S for the sidebar, and add real pane focus.
5. **Places structure and behaviour.** Section order, drop to bookmark, deepest-ancestor highlight, and first-class Starred.
6. **Recent as a Helm-owned location.** Files and folders, 300-record history, and virtual-location behaviour.
7. **Per-tab model.** Independent history with selection snapshots, new tab inherits location only, left-neighbour selection on close, last tab closes the window, tab bar hidden for one tab.
8. **Search policy as a tunable spec.** Scope rules and the F-045 ranking table, including active-directory, bookmark, and shallow-root boosts, with ranked order actually displayed.
9. **Creation and rename rules.** `~/Templates` plus Empty Text File, ` 2` collision naming, batch rename modes, tokens, and preview.
10. **Platform knowledge and user data.** Volume filter rules with the over-broad fragments fixed, the thumbnail pipeline shape, list expandable folders, and a migration path for `helm.bookmarks`, `com.helm.starredFiles`, and `helm.recentAccessRecords`.

