# Helm: independent review of the Phase 0 audit (00b)

**Reviewer:** Opus 5.5, independent checker
**Date:** 2026-11-04
**Document under review:** `docs/rebuild/00-current-state.md`
**Snapshot:** worktree on `forge/rebuild-plan` at `7359ca5`

**Method:**
- Read-only static review on Linux. Nothing was compiled, run, or changed, and I took no external actions.
- I read these in full: all 58 Swift files plus `Package.swift`, `README.md`, `project.yml`, `Info.plist`, the entitlements file, and all of `00-current-state.md`.
- I read `00a-astra-first-pass.md` lines 1-276 and searched the rest.
- I checked `project.pbxproj` by search and read only the start of the AppIcon manifest.
- I had no shell, so git history is not independently verified.

**Evidence labels:** the same as the audit. **[Observed]** is visible in source. **[Inferred]** follows from source plus AppKit/Foundation behaviour as I understand it, and needs a run on macOS. Paths are relative to `Helm/Helm/` unless they start with `Helm/`, `README.md`, or `docs/`.

## Summary

The audit is a reliable map of the code. Line references are almost always right. Its weak spots are runtime consequences and a few overclaims, not locations.

| Measure | Result |
|---|---|
| Citations checked | 123 (selection deliberately weighted toward doubtful claims) |
| Fully correct | 105 (85.4%) |
| Claim right, line wrong | 2 |
| Wrong claim | 10 |
| Unverifiable here | 6 |
| Location right | 121 of 123 (98.4%) |
| Claim right, of the 117 I could verify | 107 (91.5%) |

Findings that change the rebuild plan:

1. **B-009 is understated.** In the grid, stale widgets map a visible cell to a different file. Trash, the context menu and drops can then act on the wrong item.
2. **B-011 is under-rated.** After Back or a view-mode switch, a selection the user cannot see stays live, and Trash and Rename act on it.
3. **New crash risk (B-100).** Undo targets a per-tab object that is freed when the tab closes.
4. **New scaling failure (B-101).** Grid selection sync costs about O(n² log n) on the main thread.
5. **New keyboard gap (B-102).** No code ever gives the file pane keyboard focus, which undercuts the keyboard-first vision.
6. **Wrong as written:** F-051, the §2.8 Paste row and B-036. AppKit auto-enabling overrides the assignment they describe.
7. **Must run first on macOS:** B-117, a possibly undismissable sheet. See §3.4.

---

## 1. Citation audit

### Critical and High bugs (all 24)

| # | ID | Claim | Verdict | Evidence |
|---|---|---|---|---|
| 1 | B-009 | Monitor refresh changes `items` with no widget reload; unchecked indexing | Correct, understated | `ViewModels/DirectoryViewModel.swift:97-107`; `Views/AppKit/FileGridView.swift:66-68`, `:111`, `:148`; `Views/AppKit/FileListView.swift:143` |
| 2 | B-041 | Undo of copy or create permanently deletes | Correct | `Services/UndoService.swift:17-21`, `:64-68`; `Services/FileOperationService.swift:129-133` |
| 3 | B-001 | pbxproj has 25/49 app files, 3/7 test files, no `main.swift` | Correct | `Helm/Helm.xcodeproj/project.pbxproj:384-408`, `:416-418`; search finds no `main.swift` |
| 4 | B-002 | `SWIFT_VERSION: "5.9"` | Correct | `Helm/project.yml:21`, `:43`, `:55`; pbxproj `:460`. The xcodebuild failure itself was not run |
| 5 | B-003 | Unit-test target lacks `TestingSupport` | Correct | `Helm/project.yml:33-43` |
| 6 | B-076 | Local module named `Testing` | Wrong line, right claim | `Helm/Package.swift:18-21` is right. `HelmTests/*.swift:2-3` misses `TestManifest.swift:1` |
| 7 | B-010 | Full sort on every `displayItems` read | Correct, understated | `ViewModels/DirectoryViewModel.swift:17-19` |
| 8 | B-012 | Side effects after await with no generation check | Correct | `Controllers/ContentViewController.swift:305-311`, `:321` |
| 9 | B-017 | `error` and `isLoading` never read | Correct | Writes only at `ViewModels/DirectoryViewModel.swift:43`, `:59`, `:64` and `Controllers/ContentViewController.swift:318` |
| 10 | B-022 | Ranked order destroyed by directory sort | Correct | `Services/SpotlightSearchService.swift:219-220`; `Controllers/ContentViewController.swift:365`; `ViewModels/DirectoryViewModel.swift:18` |
| 11 | B-027 | Independent star services | Correct | `Controllers/ContentViewController.swift:10`; `ViewModels/SidebarViewModel.swift:18`, `:28`; `Services/StarredFilesService.swift:56-61` |
| 12 | B-031 | Wrong-target mutations in Recent | Correct | `Controllers/ContentViewController.swift:34`, `:319`, `:638`, `:663`; `Views/AppKit/FileGridView.swift:92` |
| 13 | B-033 | Menu commands resolve root items only | Correct | `Controllers/ContentViewController.swift:650`, `:656`, `:682`, `:697`, `:706`, `:717` |
| 14 | B-036 | Internal URLs win; menu enablement follows the pasteboard | Wrong claim (second clause) | `Services/ClipboardService.swift:32-40` is right. `isEnabled` at `Views/AppKit/FileContextMenuBuilder.swift:55`, `:119` has no effect under default auto-enabling, and the repo never sets `autoenablesItems` |
| 15 | B-037 | Cut state consumed before the move | Correct | `Services/ClipboardService.swift:34-38` |
| 16 | B-038 | Partial failure returns nothing | Correct | `Services/FileOperationService.swift:67-74`, `:91-98`, `:112-118` |
| 17 | B-040 | Same-folder move renames to `name 2` | Correct, understated | `Views/AppKit/FileGridView.swift:167`, `:191`, `:202`; `Services/FileOperationService.swift:92-96` |
| 18 | B-042 | Undo keeps destination name; zip can misalign | Correct | `Services/UndoService.swift:28-31`, `:40-43` |
| 19 | B-043 | Fire-and-forget undo, swallowed errors | Correct | `Services/UndoService.swift:18-20` |
| 20 | B-046 | Raw rename input appended as a path | Correct | `Services/FileOperationService.swift:138` |
| 21 | B-070 | Open With alert on a non-main handler | Correct, mis-rated | `Controllers/ContentViewController.swift:436-444` |
| 22 | B-050 | Slash browsing does synchronous main-thread I/O | Correct | `Views/AppKit/BreadcrumbBar.swift:477-520` |
| 23 | B-057 | Caches bounded by directory count | Correct, mis-rated | `Services/FileSystemService.swift:109`; `Services/PathCompletionService.swift:29` |
| 24 | B-067 | "Exact" ranking test is really a prefix match | Correct | `Helm/HelmTests/Services/SearchRankingTests.swift:30-51` |

### Other bugs

| # | ID | Claim | Verdict | Evidence |
|---|---|---|---|---|
| 25 | B-005 | `@testable` already forces a debug build | Wrong line, right claim | The import is at `SearchRankingTests.swift:4`; cited `:3` is `import Testing` |
| 26 | B-006 | Runner depends on the SwiftPM entry point | Correct | `Helm/TestingSupport/Testing.swift:70-93`; `Helm/HelmTests/TestManifest.swift:3-4` |
| 27 | B-011 | Restored selection reaches the model only | Correct, mis-rated | `Controllers/ContentViewController.swift:273-276`; `ViewModels/DirectoryViewModel.swift:72` |
| 28 | B-013 | Hidden tab keeps stale results; nothing resumes | Correct | `Controllers/ContentViewController.swift:66-72`, `:364`; `ViewModels/SearchViewModel.swift:40-41` |
| 29 | B-014 | Unversioned stop task | Correct | `ViewModels/DirectoryViewModel.swift:116-118` |
| 30 | B-015 | Start result ignored; silent finish on failure | Correct | `Services/FileMonitorService.swift:49-50`, `:55` |
| 31 | B-016 | Debounce can starve; setting does not stop a monitor | Correct | `ViewModels/DirectoryViewModel.swift:83`, `:97-100` |
| 32 | B-018 | Initial URL reaches the breadcrumb only | Correct | `Windows/MainWindowController.swift:155`; `Controllers/TabContainerViewController.swift:27-28` |
| 33 | B-019 | History gaps and duplicates | Correct | `Controllers/ContentViewController.swift:154`, `:298-300`; `Models/NavigationState.swift:24` |
| 34 | B-020 | Segment and search field are window-level | Correct | `Controllers/TabContainerViewController.swift:149-156` |
| 35 | B-021 | Deferred stop is latent in current wiring | Correct, could be lower | `ViewModels/SearchViewModel.swift:77-78`; `Services/SpotlightSearchService.swift:35`, `:93-97` |
| 36 | B-023 | Old results can land while a new query is pending | Correct | `ViewModels/SearchViewModel.swift:71`; `Controllers/ContentViewController.swift:364` |
| 37 | B-024 | Local-computer scope turned into a path | Correct | `Services/SpotlightSearchService.swift:172`, `:178` |
| 38 | B-026 | Candidate cap; lowercased Home | Correct | `Services/SpotlightSearchService.swift:197`, `:236`, `:274` |
| 39 | B-028 | Starred files fail as folders | Correct | `ViewModels/SidebarViewModel.swift:33`; `Controllers/ContentViewController.swift:126-128` |
| 40 | B-029 | Bookmarks saved whole; Recent pruned | Correct, understated | `ViewModels/SidebarViewModel.swift:138-141`, `:154-158`; `Services/RecentItemsService.swift:80` |
| 41 | B-030 | Recency lost; hidden toggle inert | Correct | `Controllers/ContentViewController.swift:185-187`, `:321` |
| 42 | B-032 | Child load ignores settings | Correct | `Views/AppKit/FileListView.swift:14`, `:128-136` |
| 43 | B-034 | Sort headers have no handler | Correct | `Views/AppKit/FileListView.swift:39`, `:48`, `:56` |
| 44 | B-035 | Descending comparator negates equality | Correct, latent | `Models/FileItemSort.swift:44`; no `.toggling(` callers, no writes to `sortDescriptor` |
| 45 | B-039 | Check-then-act naming | Correct | `Services/FileOperationService.swift:165`, `:192-212` |
| 46 | B-044 | Drag results discarded | Correct | `Views/AppKit/FileGridView.swift:200`, `:202`; `Views/AppKit/FileListView.swift:362`, `:364` |
| 47 | B-045 | Global Option flag only | Correct | `Views/AppKit/FileGridView.swift:164`, `:194`; `Services/FileOperationService.swift:215` |
| 48 | B-047 | No batch conflict planning | Correct | `Views/SwiftUI/BatchRenameView.swift:53`; `Controllers/ContentViewController.swift:612-622` |
| 49 | B-048 | Confirm-before-trash unused | Correct | `Views/SwiftUI/PreferencesView.swift:7`; `Controllers/ContentViewController.swift:681-694` |
| 50 | B-052 | Popup and in-flight request not cleared on edit | Correct, understated | `Views/AppKit/BreadcrumbBar.swift:428`, `:438-441`, `:794-812` |
| 51 | B-053 | Mouse selection does not refresh ghost | Correct | `Views/AppKit/PathCompletionWindowController.swift:305-308`; `Views/AppKit/BreadcrumbBar.swift:640`, `:656` |
| 52 | B-054 | Files suggested but not committable | Correct | `Services/PathCompletionService.swift:136-140`; `Views/AppKit/BreadcrumbBar.swift:251-260` |
| 53 | B-055 | Duplicate thumbnail subscribers dropped | Correct | `Services/ThumbnailService.swift:53-55`, `:86-90` |
| 54 | B-056 | Keys unversioned; 4× pixels | Correct | `Services/ThumbnailService.swift:59-60`, `:100-102`; `Services/FileIconService.swift:15-16` |
| 55 | B-058 | Main-thread I/O list | Correct, incomplete | `Views/AppKit/StatusBar.swift:53`; `Services/VolumeService.swift:139-140`; `ViewModels/SidebarViewModel.swift:122-126` |
| 56 | B-060 | Space has no modifier check | Correct | `Controllers/FileListViewController.swift:114-116` |
| 57 | B-061 | Editor traps Tab and re-grabs focus | Correct | `Views/AppKit/BreadcrumbBar.swift:726-758`, `:876` |
| 58 | B-066 | `sizeInBytes` unused; preselect ineffective | Correct | `ViewModels/PropertiesViewModel.swift:57`, `:97`; `Controllers/ContentViewController.swift:574-575` |
| 59 | B-068 | Tests write to real defaults | Correct | `Helm/HelmTests/Services/StarredFilesServiceTests.swift:7`; `Helm/HelmTests/Flows/FileManagerFlowTests.swift:108-111` |
| 60 | B-069 | Cancelled navigation splits location state | Correct | `Controllers/ContentViewController.swift:68`, `:271`, `:278`, `:305-311` |
| 61 | B-071 | Symlinked folders treated as files | Correct | `Models/FileItem.swift:10`, `:47`; `Controllers/ContentViewController.swift:382-385` |
| 62 | B-072 | No `deinit` in the monitor | Correct, mis-rated | Search finds `deinit` only in `Services/VolumeService.swift:30` and `Controllers/SidebarContainerController.swift:27` |
| 63 | B-073 | Recursive event noise | Correct, understated | `Services/FileMonitorService.swift:34-38`, `:117-137` |
| 64 | B-075 | No menu or toolbar validation | Correct | No validation hooks in search; `Models/NavigationState.swift:15-16` |
| 65 | B-079 | Row drop targets the pane root | Correct | `Views/AppKit/FileListView.swift:349-354` |
| 66 | B-080 | Broad volume-name filter | Correct | `Services/VolumeService.swift:15-23`, `:128-131` |
| 67 | B-081 | Tabs rebuilt on every navigation | Correct | `Views/AppKit/TabBarView.swift:6-8`, `:79-87`; `Controllers/TabContainerViewController.swift:160` |
| 68 | B-083 | Deprecated sharing API | Correct | `Views/AppKit/FileContextMenuBuilder.swift:175` |
| 69 | B-086 | Sixteen `runModal` sites | Correct | Search: 14 in `Controllers/ContentViewController.swift`, 1 each in grid and list |
| 70 | B-099 | No indexing fallback or empty state | Correct | `Services/SpotlightSearchService.swift:48-98` |

### Features, menus, and preferences

| # | ID | Claim | Verdict | Evidence |
|---|---|---|---|---|
| 71 | F-002 | Folders go to the first window; plist Alternate viewer | Correct, incomplete | `App/AppDelegate.swift:34-38`, `:43`; `App/Info.plist:41-55` |
| 72 | F-003 | Window and toolbar values | Correct | `Windows/MainWindowController.swift:28`, `:33-39`, `:69-70`, `:167`, `:172-174` |
| 73 | F-005 | Per-tab stacks with selection snapshots | Correct | `Models/NavigationState.swift:22-48` |
| 74 | F-006 | Cmd+Up is a no-op at `/` | Unverifiable | `Models/NavigationState.swift:51-52` depends on `deletingLastPathComponent` of `/`, which I expect returns `/../` |
| 75 | F-012 | Breadcrumb metrics | Correct | `Views/AppKit/BreadcrumbBar.swift:44`, `:50-51`, `:72`, `:142-152`, `:277`, `:901` |
| 76 | F-014 | Editor entry and 50 ms focus | Correct | `Views/AppKit/BreadcrumbBar.swift:184`, `:191-196`, `:213-228` |
| 77 | F-015 | Commit and invalid-path handling | Correct | `Views/AppKit/BreadcrumbBar.swift:242-260`, `:285-291`, `:313` |
| 78 | F-016 | Prefix completion rules | Correct | `Services/PathCompletionService.swift:28-30`, `:72`, `:77-85`; `Utilities/AppSettings.swift:71` |
| 79 | F-017 | Slash browse caps at 51 rows | Correct, detail below | `Views/AppKit/BreadcrumbBar.swift:508-520` |
| 80 | F-018 | Panel properties | Correct | `Views/AppKit/PathCompletionWindowController.swift:20-21`, `:27`, `:129-148` |
| 81 | F-020 | Tab rules | Correct | `Views/AppKit/BreadcrumbBar.swift:727-757` |
| 82 | F-021 | Return rules | Correct, incomplete | `Views/AppKit/BreadcrumbBar.swift:700-710` |
| 83 | F-023 | Ghost text rules | Correct | `Views/AppKit/BreadcrumbBar.swift:586-593`, `:625-628`, `:656-658` |
| 84 | F-026 | Section order and icons | Correct | `Views/SwiftUI/SidebarPlacesView.swift:12-57`, `:104-114`; `Models/Place.swift:33-68` |
| 85 | F-027 | Deepest-ancestor highlight; Starred excluded | Correct | `ViewModels/SidebarViewModel.swift:171-186` |
| 86 | F-031 | "Show all" disables all filtering | Wrong claim | UUID dedupe at `Services/VolumeService.swift:89-91` still runs |
| 87 | F-035 | Grid name shows two lines | Unverifiable | `Views/AppKit/FileGridView.swift:238-239` sets 2 lines and middle truncation; I expect one line at runtime |
| 88 | F-036 | Columns and metrics | Correct | `Views/AppKit/FileListView.swift:36-71`, `:177` |
| 89 | F-037 | Async child load and placeholder | Correct at source | `Views/AppKit/FileListView.swift:128-136`, `:151-158` |
| 90 | F-041 | Type-select only from native list behaviour | Correct | No `typeSelectString` in search |
| 91 | F-045 | Ranking table | Correct | `Services/SpotlightSearchService.swift:317-385` |
| 92 | F-046 | Delivery and caps | Correct | `Services/SpotlightSearchService.swift:73-87`, `:197-198`, `:219-220` |
| 93 | F-048 | Thumbnail pipeline | Correct | `Services/ThumbnailService.swift:14`, `:18-22`, `:57-62`; `Views/AppKit/FileGridView.swift:262-265`, `:284` |
| 94 | F-049 | Quick Look wiring | Correct | `Controllers/FileListViewController.swift:114-116`, `:135-162` |
| 95 | F-050 | "Folder size is metadata size" | Unverifiable | Source only has `totalFileSize ?? fileSize ?? 0` at `ViewModels/PropertiesViewModel.swift:55` |
| 96 | F-051 | Context-menu Paste enablement checks the pasteboard | Wrong claim | Auto-enabling overrides it. 00a line 224 noted this, and the audit dropped it |
| 97 | F-055 | Batch rename rules | Correct | `Views/SwiftUI/BatchRenameView.swift:14-21`, `:67-69`, `:157-160`, `:190` |
| 98 | F-059 | Action names; no redo; no refresh | Correct | `Services/UndoService.swift:22`, `:34`, `:46`, `:60`, `:69` |
| 99 | F-064 | Status bar content | Correct | `Views/AppKit/StatusBar.swift:41-58` |
| 100 | F-068 | Window frame is autosaved | Wrong claim (origin) | `window.center()` at `Windows/MainWindowController.swift:39` runs after the autosave name at `:37` and overwrites the origin at every creation |
| 101 | §2.7 | Home is ⇧⌘H through uppercase `H` | Correct | `App/main.swift:118` |
| 102 | §2.7 | Trash is ⌘⌫ | Correct | `App/main.swift:80-82` |
| 103 | §2.8 | Multi-item menu order | Correct | `Views/AppKit/FileContextMenuBuilder.swift:33-37`, `:78-84`, `:87`, `:104` |
| 104 | §2.8 | Paste enablement row | Wrong claim | Same as #96 |
| 105 | §2.9 | `helm.gridIconSize` is a stub | Correct | `Views/SwiftUI/PreferencesView.swift:12`, `:61`; `Views/AppKit/FileGridView.swift:248` |
| 106 | §2.9 | Thumbnail limit read once | Correct | `Services/ThumbnailService.swift:14`; `Utilities/AppSettings.swift:65-68` |

### Vision and architecture

| # | ID | Claim | Verdict | Evidence |
|---|---|---|---|---|
| 107 | §1.4 | Segment clicks do not navigate | Correct | `README.md:10`; `Views/AppKit/BreadcrumbBar.swift:173-175` |
| 108 | §1.4 | No usage-frequency ranking | Correct | `README.md:11`; no frequency input in `Services/SpotlightSearchService.swift:303-388` |
| 109 | §1.4 | Needs Swift 5.10, not 5.9 | Correct | `README.md:22`; `Views/AppKit/BreadcrumbBar.swift:928` |
| 110 | §1.5 | Details of `727ea51`, `10b9d39` | Unverifiable | No shell in this session either |
| 111 | §3.1 | Ownership diagram | Correct, nuance | Services are created in `Controllers/ContentViewController.swift:9-17` and injected at `:37-41` |
| 112 | §3.2 | All actions funnel through the window controller | Wrong claim | Item actions bypass it at `Controllers/ContentViewController.swift:81-99`; sidebar at `Windows/MainSplitViewController.swift:30-32` |
| 113 | §3.2 | FSEvents flags and latency | Correct | `Services/FileMonitorService.swift:16`, `:34-38`, `:46` |
| 114 | §3.3 | Entitlements empty | Correct | `Helm.entitlements:4` |
| 115 | §3.3 | Hardened runtime in spec | Correct | `Helm/project.yml:29` |
| 116 | §3.3 | `swift run` attributes TCC to the terminal | Unverifiable | Unmarked inference; plausible |
| 117 | §3.4 | Guards exist only in load and completion | Wrong claim | Also `Services/SpotlightSearchService.swift:56-61`, `Views/AppKit/FileGridView.swift:284`, `Views/AppKit/FileListView.swift:236` |
| 118 | §3.4 | Five actors | Correct | Each file's class declaration |
| 119 | §3.6 | 17 test closures | Correct | 2+3+2+2+2+6 across registrations |
| 120 | §4.6 | Recents checks across seven files | Wrong claim | 12 occurrences in 5 files, 7 of them in `Controllers/ContentViewController.swift` |
| 121 | §4.6 | Location lives in six places | Wrong claim (undercount) | Also `ViewModels/SidebarViewModel.swift:21` and `ViewModels/SearchViewModel.swift:15` |
| 122 | §4.7 | `NavigationState` is "tested, correct" | Wrong claim | `goUp` is untested and B-019 cites this type's defects |
| 123 | §4.7 | Immediate New Folder expresses Nautilus | Unverifiable from source | Conflicts with GNOME Files as I know it, which asks for a name |

**Tally:** Correct 105, Wrong line 2, Wrong claim 10, Unverifiable 6, Total 123. While reading the source I also cross-checked most other cited ranges and found no further location errors.

---

## 2. Missed or misdescribed features and interactions

| # | Area | Correction | Evidence |
|---|---|---|---|
| M-01 | Keyboard focus (new) | No code focuses the file pane. No `initialFirstResponder`, no key-view loop. See B-102 | `Windows/MainWindowController.swift:248`; `Views/AppKit/BreadcrumbBar.swift:215`, `:398` |
| M-02 | F-002 | Cold-launch open likely creates two windows, both showing Home. `openFiles` never replies | `App/AppDelegate.swift:7-10`, `:33-38`, `:46-50` |
| M-03 | F-003, F-068 | `center()` overwrites the saved origin. Every new window opens at the same spot with no cascade. A second window's reuse of the autosave name is ignored | `Windows/MainWindowController.swift:37-39`; `Windows/PreferencesWindowController.swift:15-16`; `Windows/AdvancedOptionsWindowController.swift:14-15` |
| M-04 | Window identity (new) | Title stays "Helm" and is hidden. No `representedURL`, so windows are indistinguishable in the Window menu | `Windows/MainWindowController.swift:33`, `:36` |
| M-05 | F-011 | There is no Close Window command. Closing a window discards all its tabs without a prompt | `App/main.swift:60`; `Controllers/TabContainerViewController.swift:119-127` |
| M-06 | F-010 | Only the title button selects a tab. The rest of the tab container has no click handler | `Views/AppKit/TabBarView.swift:98`, `:113-118` |
| M-07 | F-013 | Clicking a `›` separator does nothing, because it counts as a stack subview | `Views/AppKit/BreadcrumbBar.swift:916-920` |
| M-08 | F-014 | Keystrokes in the 50 ms before focus go to the previous responder | `Views/AppKit/BreadcrumbBar.swift:213` |
| M-09 | F-017 | `..` from a first-level folder produces `//`, and root can keep a `..` row | `Views/AppKit/BreadcrumbBar.swift:508-517` |
| M-10 | F-018 | Only double-click accepts, despite the comment. `updateItems` is dead. Re-show does not scroll to row 0 | `Views/AppKit/PathCompletionWindowController.swift:15`, `:36-39`, `:70` |
| M-11 | F-021 | The stale-row hazard covers any text not ending in `/`, not just an empty field | `Views/AppKit/BreadcrumbBar.swift:700-705`, `:794-812` |
| M-12 | F-023 | `~/…` and relative input get the popup but no ghost text. Tab then rewrites them to absolute paths | `Views/AppKit/BreadcrumbBar.swift:654-661`; `Services/PathCompletionService.swift:99` |
| M-13 | F-024 | Cmd+F cannot leave the editor. See B-108 | `Windows/MainWindowController.swift:246-250`; `Views/AppKit/BreadcrumbBar.swift:826-877` |
| M-14 | F-027 | Sidebar arrow keys probably navigate on each selection change [Inferred] | `Views/SwiftUI/SidebarPlacesView.swift:78-87` |
| M-15 | F-029 | Starred row order comes from a Set and is unstable. The Star or Remove title can be stale across tabs | `Services/StarredFilesService.swift:52`; `ViewModels/SidebarViewModel.swift:95-105` |
| M-16 | F-030 | Access is also recorded on Back, Forward, and the reload after clearing a search | `Controllers/ContentViewController.swift:141`, `:148`, `:310`, `:341` |
| M-17 | F-031 | UUID dedupe survives "show all". Drive glyph depends only on removable. `volumeIsLocalKey` is fetched and unused | `Services/VolumeService.swift:66`, `:89-91`, `:102-103` |
| M-18 | F-032 | Without Full Disk Access, `~/.Trash` probably lists as empty [Inferred]. See B-109 | `Models/Place.swift:82-92` |
| M-19 | F-035 | Name is probably one line, since middle truncation does not wrap [Inferred] | `Views/AppKit/FileGridView.swift:238-239` |
| M-20 | F-036 | Header click probably moves the sort indicator while order stays the same [Inferred] | `Views/AppKit/FileListView.swift:39` |
| M-21 | F-037 | Items are Swift structs boxed for AppKit, so `reloadItem` may not match by identity. Needs a run | `Views/AppKit/FileListView.swift:132`, `:143` |
| M-22 | F-038 | Grid right-click uses `selectItems`, which I expect does not call the delegate. Model and status bar can stay stale | `Views/AppKit/FileGridView.swift:78-79`, `:125-140` |
| M-23 | F-039 | Model selection survives a view switch while the new widget shows none, so Trash and Rename act on it | `Controllers/FileListViewController.swift:52-70`; `Controllers/ContentViewController.swift:682` |
| M-24 | F-043 | Search is subtree-wide. Results show names with no location, so same-named files look identical | `Services/SpotlightSearchService.swift:130`; `Views/AppKit/FileListView.swift:36-64` |
| M-25 | F-044 | `kMDItemPath` predicates may do nothing. API docs say the attribute cannot be queried [Inferred]. Then only the −650 rank penalty acts | `Services/SpotlightSearchService.swift:120-122` |
| M-26 | F-049 | No key forwarding or source frame for the panel. Space can preview an invisible selection | `Controllers/FileListViewController.swift:123`, `:139-162` |
| M-27 | F-050 | Folders probably display "Zero KB". Background Properties in Recent shows the last stable directory | `ViewModels/PropertiesViewModel.swift:55-56`; `Views/AppKit/FileGridView.swift:92`; `Controllers/ContentViewController.swift:510-513` |
| M-28 | F-051 | Paste stays enabled regardless of pasteboard. An empty paste silently does nothing | `Views/AppKit/FileContextMenuBuilder.swift:55`, `:119`; `Controllers/ContentViewController.swift:458-459` |
| M-29 | F-052 | `a.tar.gz` becomes `a.tar 2.gz`. A dangling symlink at the destination causes failure, not a suffix | `Services/FileOperationService.swift:195`, `:199-207` |
| M-30 | F-054 | Return with no selection silently consumes the key. The behaviour in Settings windows is unverified | `Controllers/ContentViewController.swift:696-703` |
| M-31 | F-059 | Undo is lost if the tab hid during the operation. The stack is shared with field-editor typing | `Controllers/ContentViewController.swift:407`; `Services/UndoService.swift:12` |
| M-32 | F-062 | Open With also appears for folders. 00a had this; the audit dropped it | `Views/AppKit/FileContextMenuBuilder.swift:29-31`, `:151` |
| M-33 | §2.8 | A tiny drag can rename the file. Cut then Paste in the same folder does the same. Only the destination pane refreshes | `Views/AppKit/FileGridView.swift:167`, `:204`; `Controllers/ContentViewController.swift:669` |
| M-34 | §2.9 | AppKit also persists window and split frames. SwiftPM and Xcode builds probably use different defaults domains [Inferred], which matters for migration | `Helm/project.yml:19`; `Helm/Package.swift:10-17` |
| M-35 | Dead code | Absent from Appendix A: `ClipboardService.hasItems`, `FileSystemService.volumeInfo`, `MainWindowController.performCopy/Cut/Paste`, `FileItem.displayName/fileExtension`, `ViewMode.displayName/systemImageName`, `FileItemSort.toggling`, `PathCompletionWindowController.updateItems` | Search results |

---

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

## 4. Vision and architecture claims

| # | Section | Problem | Correction |
|---|---|---|---|
| V-1 | §1.3 | "Deliberately" is marked Observed, but source cannot show intent. Several bullets are plain absences | Retitle as observed differences |
| V-2 | §1.2 | "Add text" is not a GNOME Files mode as I know it | State that Add Text is Helm's own |
| V-3 | §4.7 | Immediate New Folder is listed as Nautilus-derived. As I know it, GNOME Files asks for a name and Finder enters inline rename | Treat it as an open product decision |
| V-4 | §1, §4.7 | The shortcut map is mostly Finder-compatible, not Nautilus-derived. Return-to-rename is the clearest case | Say so, so the keyboard contract is a conscious choice |
| V-5 | §1.1 | Repeats the keyboard-driven goal without noting that the pane cannot receive keyboard focus by default | Link B-102 |
| A-1 | §3.2 | "Funnel" overclaims. Item actions and sidebar navigation take other routes, and many commands skip the split controller | See C-26 |
| A-2 | §3.4 | "Generation guards exist only in…" is wrong | See C-28 |
| A-3 | §3.4 | Misses the cooperative-pool risk of blocking in actors | See B-107 |
| A-4 | §4.6 | "Seven files" and "six places" are both wrong | See C-29 |
| A-5 | §4.6 | "Tests cannot substitute fakes" is broadly right, but `DirectoryViewModel` and `RecentItemsService` already take injected dependencies. The missing piece is protocols | Add this nuance |
| A-6 | §4.7 | `NavigationState` as "correct" overclaims | See C-29 |
| A-7 | §4.7 | `FileItem` equality and hash use URL only, so a future diff cannot see size or date changes. URL form also varies (`Desktop` vs `Desktop/`) | See C-29 |

---

## 5. Corrections to fold in

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
