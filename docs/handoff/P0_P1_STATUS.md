# P0 and P1 status audit

Audit of the 293 P0 and P1 rows of docs/rebuild/02-finder-parity.md against the code in Sources/ and the scripted smoke run, as of 2026-11-06.
This is an audit of code and scripted checks, not human acceptance. It was done by reading, while the code was still changing, and the rows for fixes made straight afterwards were then updated by hand. The later interface pass (header bar, sidebar, sorting, text size, cloud drives) has not been re-audited, so some rows understate it.

Rows that Mac run 3 (2026-11-09 and 10) changed were updated by hand: P-021, P-026, P-064, P-184, P-188, P-189, P-035, P-197, P-225 to P-228, P-268 and P-306, and the evidence for P-002, P-200 and P-295. P-139, P-171 and P-238, built in Mac run 2, were brought up to date at the same time.

## Summary

| Priority | Verified | Built, unverified | Partial | Missing | Ruled out | Total |
|---|---|---|---|---|---|---|
| P0 | 39 | 58 | 33 | 2 | 2 | 134 |
| P1 | 6 | 39 | 29 | 64 | 21 | 159 |
| Total | 45 | 97 | 62 | 66 | 23 | 293 |

Reading notes:
- Verified needs the real entry path exercised by a smoke step of scripts/rebuild/host_smoke_steps.txt (cited by section heading) or a test on the real file system; pure-logic model tests count only where the window passes the model straight through.
- Smoke steps drive the window's handlers, not real keystrokes or drags. The Trash steps use a fixture stand-in Trash, so the real Trash is never covered. The relaunch run (`quit` in host_smoke_steps.txt, then host_smoke_restore_steps.txt) now passes and is credited in the P-013 and P-339 rows.
- Tag rows are marked Ruled out per the owner's instruction and CommandID.tags isPlanned; OWNER_RULINGS.md does not name tags in its text. Ruling Q8 says all P0/P1 rows must work before first use, so the bar is not met, and Ruled out rows still count against that bar.

## Most important gaps

Missing or Partial P0 rows, most damaging to daily use first.

1. P-120 Progress window (Partial): a step bar in the window, with no byte counts or time remaining
2. P-013 Session and window restoration (Partial): relaunch restores windows, tabs, locations, view and sort, but not selection or scroll
3. P-036 List view columns (Partial): Name, Size, Date Modified and Kind only
4. P-202 Eject (Partial): no eject glyph or Option-eject-all, and never run on a real volume
5. P-127 Empty Trash (Partial): no no-prompt key, and the real Trash has never been exercised
6. P-233 Share (Partial): no toolbar item
7. P-152 Display names (Partial): no hidden-extension handling or localized folder names
8. P-010 Go menu locations (Partial): no Computer, Network, AirDrop or iCloud
9. P-072 Quick Look keys (Partial): no Option-Space
10. P-001 Multiple windows (Partial): not cascaded, and no setting for where new windows open
11. P-002 Window tabs (Partial): no show/hide control or open-in-tabs setting

## P0 rows

| ID | Item | Status | Evidence or what is missing |
|---|---|---|---|
| P-001 | Multiple windows | Partial | Smoke 'Windows' (newWindow, windows 2); not cascaded, opens at current folder, no 'new windows show' setting |
| P-002 | Window tabs | Partial | Custom tab strip, smoke 'Tabs' (newTab, tabs 2); many tabs shorten their names, then the strip scrolls to the tab on show (smoke.d/hunt-navigation.txt); no show/hide bar, no open-in-tabs setting; native tabs off by ruling |
| P-004 | Keyboard tab switching | Partial | Ctrl-Tab and Show Next/Previous Tab wired (smoke 'Tabs' cmd nextTab); Cmd-1/2 switch views, Cmd-3/4 ruled out; key chords not driven |
| P-008 | Back / Forward | Partial | Smoke 'Navigation and history' back/forward; buttons disable at ends; no click-and-hold history menu |
| P-009 | Enclosing folder and open | Partial | Up (smoke cmd up), Open via Cmd-Down/Cmd-O (smoke symlink cmd open); Ctrl-Cmd-Up (enclosing folder in new window) absent |
| P-010 | Go menu locations | Partial | Recents, Home, Desktop, Documents, Downloads, Applications, Utilities; Computer, Network, AirDrop, iCloud, Option-Library absent |
| P-011 | Go to Folder | Partial | Inline location bar: typed paths, ~, file URLs, completion verified (smoke 'Typed paths'); no floating panel, no recent paths |
| P-013 | Session and window restoration | Partial | Relaunch smoke verifies windows, tabs, location, view, stars, bookmarks; selection and scroll not saved |
| P-015 | Window title and proxy icon | Partial | window.title and representedURL set, but titleVisibility is .hidden so no visible title or proxy icon |
| P-018 | Opening folders from outside | Built, unverified | application(_:open:) plus public.folder document type, OK2-10 (folders to key window, files launch); needs a real `open -a` run |
| P-020 | Breadcrumb ancestor click | Built, unverified | Ancestor segment navigates, current segment edits (Q1) in PathBarView; no click test |
| P-021 | Keyboard focus model | Verified | Mac run 3: a tab switch, a navigation, Escape and a closed search give the files the keys; keys never go into a hidden listing (smoke.d/header.txt, HeaderWindowTests) |
| P-024 | Show enclosing folder of a result | Built, unverified | Show in Enclosing Folder (Go menu and context) wired; Cmd-R is Refresh by ruling; not run in smoke |
| P-026 | Loading, empty and denied states | Verified | Mac run 3: cards for refused, waiting, missing, disconnected and timed-out places replace the listing, and empty states let clicks through (smoke.d/permissions.txt, with fixture folders locked by chmod; macOS privacy itself not exercised) |
| P-027 | Icon size | Partial | Cmd-+/- and Settings slider resize grid icons globally; list fixed; no status slider, not per folder |
| P-035 | Icon labels | Verified | Mac run 3: two lines; a longer name gets one middle cut that keeps its end and extension; the selected item shows its whole name over the row below; a tooltip shows shortened names (smoke.d/grid-names.txt) |
| P-036 | List view columns | Partial | Name, Size, Date Modified, Kind (+Location in search); Created, Last Opened, Added, Version, Comments, Tags absent |
| P-037 | Column management | Partial | Header right-click show/hide plus native resize/reorder; not persisted, no Use as Defaults |
| P-038 | Header-click sorting | Built, unverified | Header sort indicator wired; smoke 'sort' calls contentSetSort directly, not a header click |
| P-039 | Disclosure triangles | Verified | Smoke 'Expand in the list' (expand, child); Option-click recursive variants not exercised |
| P-046 | View switching and defaults | Verified | Smoke 'View modes' and 'Per-folder view memory' (view-is, sorted-by); Cmd-3/4 ruled out |
| P-047 | Preserve scroll, selection, expansion | Built, unverified | Scroll kept on same-location render, selection in store; no step for Back or view switch |
| P-048 | Large folders | Built, unverified | Loader tests at 100k entries (K31LoadingTests, fake FS); no timed run in the window |
| P-049 | Live updates | Verified | Smoke 'External changes show up by themselves' (watch-external); selection and scroll retention not asserted |
| P-051 | Custom icons | Built, unverified | Icons come from NSWorkspace.icon(forFile:), so custom icons show; no step |
| P-055 | Sort keys | Partial | Name, Size, Date Modified, Kind only; Application, Last Opened, Added, Created, Tags, None absent |
| P-056 | Direction and tie-breaks | Verified | ItemSort.compare ties on path; smoke 'lists' order, K31LoadingTests |
| P-057 | Keep folders on top | Verified | Smoke 'lists' shows folders first; Settings and Sort menu toggle; one toggle, no Desktop variant |
| P-061 | `.DS_Store` policy | Built, unverified | No code writes .DS_Store; view memory uses Helm's own store; absence untested |
| P-063 | Natural, locale-aware name sort | Verified | localizedStandardCompare; smoke 'lists' order, K31LoadingTests.testNaturalOrderHiddenFilteringAndGrouping |
| P-064 | Sort in virtual locations | Verified | Search ranks by relevance; Recent sorts by Last Opened, newest first, and keeps another sort chosen there (smoke.d/recent.txt) |
| P-067 | Type-select | Built, unverified | Native outline type-select; grid uses TypeSelect; no step |
| P-068 | Arrow navigation | Built, unverified | Native arrow keys in outline and collection views; Option-Up/Down jumps absent; no step |
| P-069 | Selection gestures | Built, unverified | Native click, Shift/Cmd-click, Cmd-A (selectAll) and empty-click deselect; no step |
| P-070 | Open and navigate keys | Verified | Smoke 'Symlinked folder lands on the real folder' (cmd open); Cmd-Down handled in handleContentKey |
| P-071 | Rename in place | Verified | Smoke 'Inline rename through the real field' (both views, cancel); Return renames by ruling; Tab-to-next absent |
| P-072 | Quick Look keys | Partial | Space and Cmd-Y toggle (smoke opens it; closing needs a person); arrows forward; Option-Space absent |
| P-073 | Delete keys | Partial | Cmd-Delete, Option-Cmd-Delete, Shift-Cmd-Delete wired (smoke trash, permanentDelete, window-empty-trash); no-prompt Empty Trash absent |
| P-074 | Undo and redo | Verified | Smoke 'Menus' (undo-title Copy/Rename, 'Undo Rename'), copy/cut/dup/rename/trash undo+redo steps; errors shown via messages |
| P-076 | ⌘D | Ruled out | OWNER_RULINGS: Cmd-D stays Toggle Star; Duplicate has no shortcut (smoke 'Duplicate' via command) |
| P-077 | Remaining File/Edit/View/Go equivalents | Partial | Make Alias, Cmd-K, Ctrl-Cmd-N, Option-Cmd-C/V, Shift-Cmd-., Cmd-E wired; Cmd-R is Refresh by ruling; Cmd-J absent |
| P-078 | Menu and toolbar validation | Verified | Smoke 'Menus: enablement and named undo' (menu steps) |
| P-080 | Selection identity | Verified | Smoke 'Rename' (selected beta.md, selected after trash/duplicate/copy) |
| P-083 | Right-click semantics | Built, unverified | FileOutlineView.menu(for:) and FileCollectionView.menu(for:) select-if-unselected; list background does not clear selection; no step |
| P-085 | Panel lifecycle | Partial | One shared QLPreviewPanel reloads on selection change; does not close on navigation |
| P-090 | Keyboard while previewing | Built, unverified | Arrow keys forward to the content while the panel is open (previewPanel handle-event); needs a person, since the panel needs key focus |
| P-091 | Preview in virtual locations | Built, unverified | selectedEntries works in search, Recent, Trash; no step |
| P-092 | Third-party Quick Look extensions | Built, unverified | System Quick Look hosts extensions; nothing here to test |
| P-094 | Info window | Ruled out | OWNER_RULINGS: read-only Properties sheet instead of an Info window |
| P-095 | General section | Partial | Properties sheet opens (smoke 'Sheets open and close'); no live recursive size for folders, version, tags or label |
| P-113 | Copy and Paste | Verified | Smoke 'Copy' (copy, paste, contents, same-mtime, has-xattr, undo, redo); pastes into current folder only |
| P-114 | Move pasted items | Verified | Smoke 'Cut and paste moves' and 'Move Items Here' |
| P-116 | Duplicate | Verified | Smoke 'Duplicate' (alpha 2.md, undo); name 2 convention kept by ruling |
| P-117 | Conflict naming | Verified | Smoke 'A name that already exists' (notes 2.txt) and conflict keepBoth; name 2 kept by ruling, not Finder's 'copy' |
| P-118 | Move vs copy default | Partial | Smoke 'Drag and drop moves within a volume'; Option copy, Cmd move, cross-volume copy coded (needs 2nd volume); Option-Cmd alias absent |
| P-119 | Conflict dialog | Verified | Smoke 'Conflicts through the real dialog' (replace, skip, stop, keepBoth); folder merge semantics unchecked |
| P-120 | Progress window | Partial | OperationsPanel in the window with step progress, Cancel; no byte counts, time remaining or separate window; no smoke step reads it |
| P-121 | Cancel semantics | Built, unverified | Cancel button wired; LiveMutationTests.testCancelledCopyLeavesNothingBehind covers the engine; button not driven |
| P-122 | Copy fidelity | Verified | Smoke 'Copy' (same-mtime, has-xattr), LiveMutationTests; ACL, resource fork, clone, sparse not checked |
| P-124 | Symbolic links | Partial | Smoke 'Symlinked folder' and 'Folder copy keeps its link' (is-link); no alias badge drawn; dangling link untested |
| P-126 | Move to Trash and Put Back | Built, unverified | Smoke 'Trash' (trash, undo, Put Back) uses the fixture stand-in Trash only; real ~/.Trash and .Trashes never run; needs approved real-Trash run |
| P-127 | Empty Trash | Partial | Empties ~/.Trash and each external volume's Trash; smoke on fixture only; no Option no-prompt key; real Trash never exercised |
| P-128 | Delete Immediately | Verified | Smoke 'Delete Immediately' (permanentDelete, confirm bypassed for test); bypasses operation engine, no undo or progress |
| P-132 | New Folder | Verified | Smoke 'New folder, undo' (untitled folder, inline rename, undo) |
| P-134 | New file from template | Built, unverified | Empty Text File and ~/Templates in background context menu (createFile); no step; no File-menu entry |
| P-135 | Filename validation | Built, unverified | FileNameValidator on rename and new items, messages shown; NamingTests; no step enters an invalid name |
| P-136 | Batch rename | Built, unverified | Smoke opens the batch sheet (cmd rename, 2 items); BatchRename view-model tests; running a batch untested |
| P-137 | Undo for every entry point | Verified | Undo shown for paste, cut, duplicate, rename, trash, new folder and drag (smoke); batch rename undo untested |
| P-138 | Operations outlive the view | Built, unverified | Coordinator is app-wide, tasks do not die with the window; no step closes a window mid-copy |
| P-139 | Partial failure | Verified | Mac run 2: Skip, Try Again (when nothing was half done) or Stop, with 'Skip any other items' (smoke fail-answer); run 3 made Skip of a Replace skip the whole item |
| P-140 | Preflight | Verified | Smoke 'Move a folder into itself is refused' and 'A folder into itself is refused' |
| P-141 | Cross-volume move | Built, unverified | Planner copy-then-remove logic tested (K15 transfer tests); needs a second volume |
| P-149 | Opening items | Built, unverified | NSWorkspace.open with default app, several files at once, packages as files; smoke only opens folders |
| P-152 | Display names | Partial | Applications drop .app; no hasHiddenExtension or localized folder names |
| P-157 | Expand | Built, unverified | Open hands archives to the default app via NSWorkspace; decompress isPlanned; no step |
| P-170 | Scope bar | Missing | No scope bar; scope fixed by OK2-23 (folder in directories, everywhere in Recent) |
| P-171 | Name versus contents | Built, unverified | Mac run 2: names first, then Spotlight's content index, and Settings › Search turns contents off; fixture homes aren't indexed, so no smoke step covers contents |
| P-176 | Result location | Built, unverified | Location column in search results and Show in Enclosing Folder wired; not asserted |
| P-178 | Result order | Built, unverified | SearchRanker and relevance sort wired; no step checks order |
| P-181 | Spotlight privacy | Built, unverified | NSMetadataQuery honours the index exclusions; the folder walk does not; untested |
| P-183 | Query lifecycle | Verified | Smoke 'Search' (search, then clear); debounce cancels, reducer drops stale results (T3CancellationTests) |
| P-184 | Field behaviour | Verified | Mac run 3: Cmd-F opens or reselects, Escape closes from the field or the files, an empty search closes on blur, going anywhere ends a search, each tab keeps its own (smoke.d/header.txt) |
| P-187 | Sections | Partial | Recent, Favorites, Bookmarks, Starred, Devices, Trash; no collapse, iCloud or Tags section, no visibility setting |
| P-188 | Editing Favorites | Verified | Mac run 3: rows reorder within their group by drag, hide by menu, drag-out or Settings › Sidebar, and Restore Defaults; bookmarks insert where dropped (smoke.d/sidebar.txt drives the drop and drag-end code, not a real pointer drag) |
| P-190 | Sidebar drop targets | Built, unverified | Trash drop now trashes; folder places move or copy (Option copies); sidebar drops not driven by a real drag |
| P-192 | Eject buttons | Partial | Eject only in the context menu, no glyph; busy volume shows the system error alert |
| P-195 | Starred place | Built, unverified | Starred section and star toggle wired (SidebarModelTests); starred files reveal rather than open |
| P-196 | Highlight rule | Verified | SidebarModelTests.testDeepestAncestorUsesCorePolicyIncludingStarredRows; renderSidebar uses the model |
| P-198 | Width and collapse | Built, unverified | Split item resize and collapse with autosave (toggleSidebar); no step |
| P-201 | Volume list | Built, unverified | VolumeReader and VolumeFilter wired; fixture runs skip real mounts; verify with a real mount |
| P-202 | Eject | Partial | Sidebar context eject and Cmd-E on the external volume holding the current folder; no eject glyph, no Option-eject-all; never run on a real volume |
| P-203 | Mount and unmount reactions | Built, unverified | VolumeCenter listens to mount/unmount/rename notifications; needs a real mount |
| P-204 | Disk images | Built, unverified | Double-click hands .dmg to the system; needs a real image |
| P-209 | Volume capacity | Partial | Free space shown in status text (availableCapacity); no capacity or format in Properties; not asserted |
| P-211 | System volume presentation | Built, unverified | VolumeFilter hides helper mounts (tests); needs real volumes |
| P-225 | Open With submenu | Verified | Mac run 3: the row is on in the right-click menu and File › Open With, default first, Recently Used, Recommended, Other Apps, Choose App…, in HelmDev and an Xcode Release build (smoke.d/open-with.txt); no App Store entry |
| P-230 | Open With bookkeeping | Built, unverified | Open With records Recents and shows failures in the window; needs a person to open a real app |
| P-231 | Open from an app's Dock icon | Built, unverified | Drag source offers file URLs to other apps; needs a person |
| P-232 | Services for files | Built, unverified | validRequestor and writeSelection send the selected files to the Services menu; needs a person to run a Service |
| P-233 | Share | Partial | File > Share opens the picker; context Share submenu; no toolbar item; never run |
| P-238 | "Open in Helm" Service | Verified | Mac run 2: Open in Helm and Show in Helm in the Services menu (smoke service-show) |
| P-251 | Status bar text | Built, unverified | Counts, selected size and free space shown (StatusAndTagsTests); text not asserted; .DS_Store not special-cased |
| P-255 | Toggle hidden files | Verified | Smoke 'Hidden files' (cmd hidden); persists, applies to all tabs via settingsChanged |
| P-256 | What counts as hidden | Built, unverified | Dot files verified (smoke 'Hidden files'); isHiddenKey flag covered by API; FinderInfo bit and /.hidden list not handled |
| P-259 | Show Package Contents | Built, unverified | Show Package Contents in context menu; packages open as files; no step |
| P-261 | Hidden rule everywhere | Built, unverified | showHidden reaches children, completion, search, Recent, Trash; only folder listing exercised (smoke) |
| P-268 | Denied folders and Full Disk Access | Verified | Mac run 3: cards name the place and offer Grant Access… (Full Disk Access or Files & Folders guide), Open in Finder for the Trash and Try Again; once-only welcome; Help › Full Disk Access… (smoke.d/permissions.txt on fixture folders; the real Full Disk Access list not tried) |
| P-269 | Drag source | Built, unverified | File URLs on drag, all operations offered; real drag not driven |
| P-270 | Drag destination from other apps | Built, unverified | Accepts file URLs, modifier rules in dragOperation; smoke drives acceptDrop, not another app |
| P-274 | Live modifier feedback | Built, unverified | validateDrop re-runs on modifier change; needs a person |
| P-275 | Drag to Dock and other apps | Built, unverified | Source mask is .every so Dock Trash and apps work natively; needs a person |
| P-276 | Drop on Helm's Dock icon | Built, unverified | application(_:open:) navigates folders; files launch (OK2-10); needs a Dock drop |
| P-278 | Drag threshold and selection | Built, unverified | Native AppKit drag selection behaviour; no step |
| P-282 | Helm Recent place | Verified | Smoke 'Recent' (location recent, clearRecent); opened files and folders recorded |
| P-288 | Desktop as a place | Verified | Desktop in Favorites (SidebarModelTests, Place.defaultFavorites); smoke goes to Desktop |
| P-289 | Unified Trash | Partial | Smoke 'Trash view and put back' on fixture; Trash view also reads volume .Trashes (untested); no iCloud trash; no Empty button in the view |
| P-292 | VoiceOver file browsing | Built, unverified | Labels on Files, Places and rows; no VoiceOver pass |
| P-293 | Accessible tabs and toolbar | Built, unverified | Tab labels, selected state, Close/New Tab names; no VoiceOver pass |
| P-294 | Accessible location completion | Partial | Field and breadcrumbs labelled; suggestion popup rows carry no announcements |
| P-295 | Keyboard-only task completion | Built, unverified | Most commands have keys; sidebar arrows and Return navigate (smoke.d/hunt-sidebar-settings.txt); no keyboard-only run |
| P-300 | Accessible progress and errors | Partial | Cancel labelled, errors in sheets; Core announcement logic never posted (no NSAccessibility.post) |
| P-302 | Settings window and live changes | Verified | Smoke 'Settings window' and setting steps; changes apply live via settings.changes |
| P-313 | Preference migration and defaults | Verified | EnvironmentTests migration and corrupt-preference tests; no reset action |
| P-336 | Smart Folder operations | Missing | No Smart Folders to operate on |
| P-338 | Launch precedence | Built, unverified | LaunchRouter precedence (LaunchTests plan); needs a real launch with a folder argument |
| P-339 | Restore tab presentation | Partial | View, sort, hidden restored, verified by relaunch smoke; selection and scroll not saved |
| P-340 | Missing restored locations | Built, unverified | isAvailableDirectory falls back to Home (LaunchTests); needs a real relaunch with missing folder |
| P-347 | Hide, minimize and resume | Built, unverified | Standard AppKit hide and minimize; untested |
| P-350 | Unicode filenames and normalization | Verified | Smoke 'Typed paths' and 'Unicode name rename' (NFC/NFD select, rename, reveal) |
| P-351 | IME and composed input | Built, unverified | Standard NSTextField editing; needs a person with an IME |
| P-359 | Placeholder-safe browsing | Built, unverified | Listing reads metadata only; untested with a real provider |
| P-375 | Copy as Pathname | Built, unverified | Option-Cmd-C writes paths (copyAsPathname); not driven |
| P-378 | Explicit command-line opening | Built, unverified | CLI paths parsed by LaunchOptions, folders by application(_:open:); needs a real `open -a` |
| P-388 | Missing volumes and disconnected shares | Partial | Overlay says the disk was disconnected, sidebar still navigates; no reconnect |

## P1 rows

| ID | Item | Status | Evidence or what is missing |
|---|---|---|---|
| P-003 | Tabs between windows | Missing | No tear-off, merge or move-tab-to-window; strip only activates, closes, adds |
| P-005 | Tab reorder and overflow | Ruled out | OWNER_RULINGS Q6: tab drag-reorder comes later; overflow menu also absent |
| P-006 | Open in new tab / window | Partial | Cmd-double-click and context Open in New Tab/Window wired; Option-double-click absent; no smoke step |
| P-007 | Close semantics | Partial | Cmd-W (smoke 'Tabs' closeTab, 'Windows' close-window) and Shift-Cmd-W wired; Option-Cmd-W close-all absent |
| P-012 | Recent Folders menu | Missing | No Recent Folders menu; only Clear Recent for the Recent place |
| P-016 | Window menu and cycling | Built, unverified | NSApp.windowsMenu set, Minimize/Zoom wired so the system lists windows and Cmd-`; no step; verify by hand |
| P-017 | New-window default location | Missing | No new-window location setting; new windows open at the current folder |
| P-019 | Computer location | Missing | Go > Computer is isPlanned (disabled); no Computer root |
| P-022 | Show/hide chrome | Partial | Sidebar toggle (Ctrl-Cmd-S) only; no toolbar, path bar, status bar or tab bar toggles |
| P-028 | Grid spacing | Missing | No spacing control |
| P-029 | Label text size | Missing | No label size control |
| P-032 | Show icon preview | Partial | Grid shows QuickLook thumbnails for image/movie/pdf always; no toggle |
| P-040 | Calculate all sizes | Missing | Folder size shows a dash; no calculate-all-sizes |
| P-041 | Relative dates | Partial | Dates use relative formatting always; no toggle |
| P-043 | Column view | Ruled out | Column view: columns isPlanned, OWNER_RULINGS 14.5 (column and gallery views later); ColumnBrowserView unwired |
| P-045 | Preview pane | Ruled out | Preview pane: previewPane isPlanned, OWNER_RULINGS 14.5 |
| P-050 | Item badges | Partial | Star badge and hidden dimming only; no alias, lock, cloud, tag or shared badge drawn |
| P-052 | Rubber-band selection | Built, unverified | Native marquee in NSCollectionView and NSOutlineView; no step |
| P-054 | Thumbnails everywhere | Partial | Thumbnails in grid only at pixel size (key includes mtime); list uses file icons |
| P-058 | Group by | Missing | Core Grouping exists; no UI or view wiring |
| P-059 | Show View Options | Missing | ViewOptionsView exists but unwired; viewOptions isPlanned and disabled |
| P-060 | Per-folder view settings | Partial | View mode and sort per folder (smoke 'Per-folder view memory'); icon size, columns, text size not applied |
| P-062 | Date Added and Date Last Opened | Missing | No Date Added or Last Opened sort or column |
| P-065 | Sort/Group controls | Partial | Sort in Actions menu and list header with checkmarks; no View > Sort By submenu, no Group |
| P-075 | Get Info keys | Ruled out | OWNER_RULINGS: read-only Properties sheet, no Info window; Cmd-I opens one sheet |
| P-079 | Full Keyboard Access | Built, unverified | Key view loop automatic, field-level focus rings are AppKit default; no Full Keyboard Access pass |
| P-082 | Action (gear) menu | Partial | Actions menu holds New Folder/Tab/Window, Sort, Hidden, Refresh, Settings; not the selection's context menu |
| P-084 | Status text for selection | Built, unverified | StatusText via StatusPresentation (StatusAndTagsTests); window text not asserted |
| P-086 | Zoom animation | Built, unverified | sourceFrameOnScreenFor supplies the icon frame; needs eyes |
| P-087 | Multi-item preview | Built, unverified | Quick Look panel handles several items natively; not exercised |
| P-097 | Tags field | Ruled out | Tags deferred (CommandID.tags isPlanned); TagEditorView unwired; tags not named in OWNER_RULINGS text |
| P-099 | Locked | Ruled out | OWNER_RULINGS 14.5: Get Info editing later |
| P-100 | Name & Extension | Ruled out | OWNER_RULINGS 14.5: Get Info editing later |
| P-102 | More Info | Missing | No metadata section in Properties |
| P-103 | Open with | Missing | No Open with or Change All in Properties |
| P-104 | Preview section | Missing | No preview in Properties |
| P-105 | Sharing & Permissions | Ruled out | OWNER_RULINGS 14.5: Get Info editing later |
| P-107 | Inspector | Missing | Inspector Core logic exists; no panel or key wired |
| P-108 | Volume info | Missing | No volume info in Properties |
| P-110 | Where and enclosing folder | Partial | Properties shows path text and a Show in Enclosing Folder button; Where is not a clickable path |
| P-115 | Cut items dimmed | Built, unverified | cutIDs dim cells (ContentLeafPresentation test); visual, needs eyes |
| P-125 | Aliases | Partial | Make Alias and Show Original wired, alias open resolves; only symlink creation in smoke; no Fix Alias; Ctrl-Cmd-A not driven |
| P-129 | Locked item handling | Missing | No locked-flag detection or unlock prompt |
| P-131 | Items in use | Built, unverified | Filesystem errors surface via OperationText.describe; no busy-file test |
| P-133 | New Folder with Selection | Built, unverified | createFolderWithSelection wired; no smoke step |
| P-142 | Space check | Built, unverified | Planner insufficientSpace wired (PlannerTests); needs a full volume |
| P-143 | Quarantine and Gatekeeper | Built, unverified | Copy keeps xattrs (smoke has-xattr), so quarantine should survive; Gatekeeper is the system's; not tested |
| P-144 | Coordinated file access | Missing | No NSFileCoordinator anywhere |
| P-148 | Fast delete of large trees | Built, unverified | removeItem runs async per item, no timing test on a large tree |
| P-150 | Special document types | Built, unverified | All delegated to NSWorkspace default handlers; .savedSearch opens elsewhere; no step |
| P-153 | Localized system folders | Missing | No localized system-folder names or special icons |
| P-155 | Trash as a drop target | Missing | Trash place has no URL, so sidebar drops fall through to add a bookmark |
| P-156 | Compress | Ruled out | OWNER_RULINGS 14.5: Compress later; compress isPlanned |
| P-160 | Archive progress and cancel | Ruled out | OWNER_RULINGS 14.5: Compress later |
| P-161 | Assign tags | Ruled out | Tags deferred (CommandID.tags isPlanned); tag menu and editor unwired |
| P-162 | Storage format | Ruled out | Tags deferred; storage logic exists, nothing wired |
| P-163 | Tag list and colours | Ruled out | Tags deferred; MemoryTagCatalog not shown anywhere |
| P-164 | Tag dots and search | Ruled out | Tags deferred; TagDotView unwired |
| P-166 | Tag editor sheet | Ruled out | Tags deferred; TagEditorView unwired |
| P-168 | Stars versus tags | Verified | Smoke 'Stars' (star, starred, unstarred); Helm-private per Q7 |
| P-172 | Search tokens | Missing | No tokens or suggestion popup |
| P-173 | Criteria rows | Missing | No criteria rows |
| P-174 | Save as Smart Folder | Missing | No save as Smart Folder; HelmSearch SavedSearch exists unwired |
| P-175 | Open smart folders | Missing | No .savedSearch opening; NSWorkspace hands them to the default app |
| P-177 | Live results | Built, unverified | Spotlight NSMetadataQuery stream merged live; fixture is unindexed so live updates never exercised |
| P-179 | Unindexed locations | Verified | Smoke 'Search' (q2 found in an unindexed fixture through the folder walk); Spotlight side unverified |
| P-180 | System file exclusion | Built, unverified | SearchSpecification skips hidden entries; system-file rule not tested in the window |
| P-186 | System Recents | Missing | Recent stays an app-local log (RecentStore), not a Spotlight last-used query |
| P-189 | Standard favourites | Partial | Recent, Home, Desktop, Documents, Downloads, Pictures, Music, Movies, Applications and Trash, each can be hidden or moved (Mac run 3); no AirDrop |
| P-191 | Sidebar icon size | Built, unverified | Source list uses system row size; not checked |
| P-193 | Locations content | Partial | Mounted volumes only (VolumeReader); no iCloud, cloud providers, Bonjour or servers section |
| P-197 | Sidebar context menus | Partial | Open in New Tab, Remove Bookmark, Hide from Sidebar, Sidebar Settings…, Eject, Empty Trash; no Open in New Window, Show in Enclosing Folder, Get Info, Clear Recents |
| P-200 | Keyboard in the sidebar | Partial | Arrows and type-select open the place the highlight lands on, and Return opens the highlighted row (smoke.d/hunt-sidebar-settings.txt); ⌘Return for a new tab is unverified |
| P-206 | Connect to Server | Partial | Cmd-K prompt and typed smb:// hand off to macOS; no recent servers, favourites or Browse |
| P-207 | Network location | Missing | Go > Network isPlanned (disabled) |
| P-208 | Connected servers | Built, unverified | Mounted network volumes appear as devices via VolumeReader; needs a real share |
| P-216 | iCloud Drive place | Missing | No iCloud Drive place |
| P-217 | Cloud status badges | Missing | cloudAvailability is read but no badge is drawn in the cells |
| P-218 | Download Now and Remove Download | Missing | No Download Now or Remove Download |
| P-219 | Third-party providers | Missing | No CloudStorage provider places |
| P-220 | Avoid accidental materialization | Built, unverified | Thumbnails skip evicted files, listing reads metadata only; untested with a real provider |
| P-226 | Always Open With | Verified | Mac run 3: Option turns each app into Always Open With, which sets the default for each selected kind (stand-in launcher in fixture runs); not offered for folders |
| P-227 | Change All | Verified | Mac run 3: Change Default App… sets the default for every file of the selected kinds (stand-in in fixture runs); not offered for folders |
| P-228 | Multi-item Open With | Verified | Mac run 3: several items list the apps that open all of them, each ranked by the item it suits least, with their shared default first |
| P-229 | Open in Terminal | Missing | No Open in Terminal |
| P-234 | AirDrop from Share | Built, unverified | AirDrop appears among system sharing services; needs a person |
| P-235 | Quick Actions submenu | Missing | No Quick Actions submenu |
| P-242 | Customize Toolbar | Missing | ToolbarCustomization views unwired; allowsUserCustomization is false |
| P-243 | Standard item set | Partial | Back/Forward, path, search, view switch, Actions only; no Share, Tags, Quick Look, Get Info, Eject, AirDrop |
| P-245 | Show/hide toolbar | Missing | No toolbar toggle |
| P-249 | Breadcrumb drop targets | Built, unverified | PathBarView accepts drops on segments (acceptDrop); no step |
| P-250 | Breadcrumb context menu | Partial | Open in New Tab and Copy Path only; no new window, Reveal, Terminal or Get Info |
| P-252 | Icon size slider | Missing | No slider; icon size via Cmd-+/- |
| P-253 | Status for state | Built, unverified | Gathering, searching and denied states wired in renderStatus; not asserted |
| P-257 | Hidden items dimmed | Built, unverified | Hidden dimming via ContentLeafPresentation.opacity (test); visual |
| P-258 | Show Library Folder | Missing | No Show Library Folder |
| P-260 | Show all filename extensions | Missing | No setting; extensions always show because names are raw |
| P-262 | Permissions display | Missing | Properties permission rows read 'Unavailable'; no PropertiesSupplement is ever supplied |
| P-263 | Edit POSIX permissions | Ruled out | OWNER_RULINGS 14.5: Get Info editing later |
| P-271 | File promises | Missing | No file promise receiver |
| P-273 | Spring-loaded folders | Missing | SpringNavigation Core exists; nothing in the window calls it |
| P-277 | Drops in virtual locations | Partial | Search and Recent refuse drops; Trash drop absent |
| P-279 | Auto-scroll and expand on hover | Partial | Native edge autoscroll only; no hover expansion |
| P-281 | Copy also writes names | Partial | Pasteboard string carries full paths, not names |
| P-283 | Apple menu and Open Recent | Missing | No Open Recent or noteNewRecentDocument |
| P-284 | AirDrop place | Missing | No AirDrop place |
| P-296 | Full Keyboard Access compatibility | Built, unverified | Standard controls; not exercised |
| P-297 | Reduce Motion | Missing | PathBar shake() animation ignores Reduce Motion |
| P-298 | Increased contrast and reduced transparency | Built, unverified | System materials adapt; no explicit handling |
| P-299 | Differentiate without colour | Built, unverified | Star shape and selection highlight; tags absent; not checked |
| P-301 | Voice Control, Switch Control and text scale | Built, unverified | Native controls; not exercised |
| P-304 | General: window destination and tab preference | Missing | No new-window folder or tab preference |
| P-305 | Tags preferences | Ruled out | Tags deferred; no Tags pane |
| P-306 | Sidebar preferences | Verified | Mac run 3: Settings › Sidebar lists every row with a checkbox and a drag handle, plus Show system volumes and Restore Defaults (smoke.d/sidebar.txt) |
| P-307 | Advanced: all extensions | Missing | No setting; extensions always shown |
| P-308 | Advanced: folders on top | Partial | One Directories first setting (smoke 'lists'); no Desktop variant |
| P-309 | Advanced: extension-change warning | Missing | No extension-change warning |
| P-310 | Advanced: trash and cloud warnings | Partial | Empty Trash always confirms (no setting; trash itself unconfirmed by Q10); no cloud warning; confirmBeforeTrash inert |
| P-311 | Advanced: search default | Partial | Search scope fixed by OK2-23; no setting |
| P-314 | Advanced Helm controls | Partial | Live monitoring and conflict ask wired; cache, icon limit, completion debounce, cross-volume default inert |
| P-315 | Encrypted image opening | Built, unverified | System DiskImageMounter handles passwords; needs a real encrypted image |
| P-316 | Read-only and writable images | Built, unverified | Mounted images show as devices; needs a real image |
| P-317 | Image detach with multiple volumes | Built, unverified | unmountAndEjectDevice detaches; multi-volume image untested |
| P-320 | Send selection through AirDrop | Built, unverified | AirDrop through Share submenu; needs a person |
| P-322 | Transfer outcome and cancellation | Built, unverified | System UI; same Share path |
| P-323 | Receive and Downloads refresh | Built, unverified | Downloads refresh by folder monitor; needs a real receive |
| P-324 | Hover activation and delay | Missing | SpringNavigation Core unwired |
| P-325 | Unwind temporary navigation | Missing | SpringNavigation Core unwired |
| P-326 | Sidebar, tabs and breadcrumbs | Missing | No spring targets on sidebar, tabs or breadcrumbs |
| P-327 | Hover expansion and autoscroll | Partial | Native edge autoscroll only; no hover expansion |
| P-328 | Favourite tag order | Ruled out | Tags deferred |
| P-329 | Mixed-selection tag editing | Ruled out | Tags deferred |
| P-331 | Provider and volume limitations | Ruled out | Tags deferred |
| P-333 | Save editable query | Missing | No save query |
| P-334 | Import Finder Smart Folders | Missing | No Smart Folder import; SavedSearch logic unwired |
| P-335 | Edit and resave criteria | Missing | No criteria editing |
| P-337 | Scope and live-update lifecycle | Missing | No saved queries |
| P-341 | Window frames and displays | Built, unverified | Frame autosave and center; display changes untested |
| P-342 | Restore preferences and crash recovery | Built, unverified | isRestorable false so only Helm restores; duplicate restore untested |
| P-343 | Spaces membership | Built, unverified | Plain NSWindow; untested |
| P-344 | Stage Manager grouping | Built, unverified | Plain NSWindow; untested |
| P-345 | Full screen and Split View | Built, unverified | Resizable window; full screen and Split View untested |
| P-346 | Auxiliary window placement | Built, unverified | Properties, conflict and batch are attached sheets; QL panel shared; untested |
| P-349 | Dates, numbers and sizes | Built, unverified | DateFormatter and ByteCountFormatter follow the user's locale; untested |
| P-353 | Locale changes and localized names | Ruled out | OWNER_RULINGS 14.5: localization later |
| P-354 | Read Spotlight comments | Missing | No comments |
| P-356 | More Info attributes and provenance | Missing | No More Info metadata |
| P-357 | Metadata changes and searching | Missing | No metadata editing or columns |
| P-358 | Discover provider roots and accounts | Missing | No provider discovery |
| P-360 | Explicit materialization | Missing | No explicit download or offline error; opens go to the system |
| P-362 | Coordinated edits and conflicts | Missing | No NSFileCoordinator anywhere |
| P-368 | Automator Quick Actions through Services | Missing | No Services requestor, so no Quick Actions |
| P-373 | Automation consent and capabilities | Missing | No Apple event or Automation handling |
| P-374 | New Terminal at Folder | Missing | No Terminal service or command |
| P-376 | Reveal in Finder and Show Original | Partial | Show Original resolves aliases and symlinks; no Reveal in Finder |
| P-383 | Grouping independent of sorting | Missing | Core Grouping exists; no UI |
| P-384 | View defaults and inheritance | Partial | Per-folder view and sort kept; no defaults UI or browse-in-view choice |
| P-385 | Date and size group boundaries | Missing | Core Grouping buckets exist; no UI |
| P-389 | Safe archive extraction | Missing | Archive logic exists (K27ArchiveTests), nothing wired; decompress isPlanned |
