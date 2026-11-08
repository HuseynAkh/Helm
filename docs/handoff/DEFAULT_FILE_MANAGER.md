# Can Helm be the default file manager?

What it takes for Helm to stand in for Finder day to day, what this pass built, and what's still missing. Written 2026-11-08 against `handoff/mac-fixups`. Row numbers (P-…) are from docs/rebuild/02-finder-parity.md; status for everything else is in P0_P1_STATUS.md.

## How macOS lets another app stand in for Finder

There's no single switch. Path Finder, ForkLift and Marta use the same two settings, and Helm now uses them too:

1. **The global `NSFileViewer` preference.** When an app calls `NSWorkspace` to show a file (Show in Finder, Reveal in Finder), AppKit sends the request to the app this preference names instead of Finder. On 2026-11-08 this was checked with a throwaway probe app and a per-process preference, so no real setting changed. AppKit delivered the request as an ordinary open-documents event carrying the file itself, with nothing to tell it apart from `open -a`. So a file manager that receives a file must show it in its folder, not launch it.
2. **The default app for `public.folder`.** Folders opened from other apps, Spotlight and `open` go to this app.

What happened on this Mac (macOS 26, 2026-11-08, with Huseyn's go-ahead):
- **`NSFileViewer` works.** `--default-viewer helm` set it. A new process that called `NSWorkspace.activateFileViewerSelecting`, as "Show in Finder" does, read the preference and sent the request to Helm, which received it.
- **`public.folder` is locked.** macOS refused to change the folder handler:
  - `NSWorkspace.setDefaultApplication(at:toOpen: .folder)` answered "The file couldn't be opened".
  - `LSSetDefaultRoleHandlerForContentType` answered paramErr (-50), even when asked for Finder.

  Folders opened from Spotlight, Dock stacks and `open` therefore stay with Finder. Helm asks anyway and doesn't treat the refusal as a failure.
- **Default apps for documents need your confirmation.** Setting `.docx` to ONLYOFFICE through `setDefaultApplication`, the call behind Helm's Change Default App, got no answer while the screen was locked. The older Launch Services call reported success and changed nothing. So Helm's Change Default App completes only once you confirm macOS's prompt. `.docx` was left opening in Pages, as before.
- **The Dock:** writing the Dock's settings and restarting it right away can lose the change. A Dock that restarted moments earlier saved its old tiles over the new ones. Helm now checks after the Dock comes back and writes again if needed. Off then on was confirmed both ways.

What no third-party app can take over:
- **The desktop.** Finder still draws it and its icons.
- **The Dock's Finder icon.**
- **Apps that ask Finder by name.** These are apps that use AppleScript or Finder's bundle ID instead of `NSWorkspace`. Those requests still go to Finder.
- **Apps already running.** They read the preference when they start, so they keep asking Finder until they are reopened.

## Built in this pass

| Need | What Helm does now | Checked by |
|---|---|---|
| Become the file viewer | Settings › General › Default File Viewer: **Make Default** sets `NSFileViewer`, and asks for the folder handler, which macOS 26 refuses. **Restore Finder** undoes it. The same switches work from Terminal: `/Applications/Helm.app/Contents/MacOS/Helm --default-viewer helm\|finder`, and `--viewer-status` reports the current state. | Smoke `file-viewer` (fixture stand-in); live on this Mac: set, and a Show in Finder request reached Helm |
| Helm in the Dock | **Show Helm first in the Dock** puts Helm's tile first, right after Finder's, which macOS keeps first. Turning it off puts Helm back where it was, or out of the Dock if it wasn't there. From Terminal: `--dock-first on\|off`. | Smoke `first-in-dock`; live on this Mac: off then on, confirmed in the Dock's settings |
| Show in Finder from other apps | A file sent to Helm opens its folder with the file selected. Several files from one folder are selected together, and other folders open as tabs. This amends OK2-10, under which files launched. | Smoke `open-external` |
| Services | **Open in Helm** (folders) and **Show in Helm** (any item) in the Services menu and Finder's context menu (P-238) | Smoke `service-show` |
| Always available | Settings › General › **Open Helm when you log in**, through SMAppService. Helm already keeps running with no windows open. | Not run: it changes a login item |
| Compress and Expand | File › Compress "name" / Compress N Items: one item uses `ditto` (keeps extended attributes and resource forks, as Finder does); several items make `Archive.zip`. Taken names get numbers. **Expand Archive** hands the archive to Archive Utility, as double-clicking in Finder does. | Smoke: one item, several items, and a taken name |
| A failure doesn't stop a whole copy | Skip, Try Again (only when nothing was half done) or Stop, with "Skip any other items that can't be copied" (P-139) | Smoke `fail-answer` with an unreadable file: Skip copies the rest; Stop doesn't |
| One failure no longer blocks the window | **Bug fixed.** A batch that ended partly done left the window's undo history waiting for a confirmation nothing asked for. After one unreadable file, every later copy, move, rename and duplicate in that window only beeped until Helm restarted. Helm now says what may be partly done, offers Show Item, and carries on. | Smoke: later duplicate and new-folder steps now pass after the failure steps |
| Search inside documents | Spotlight's content index, as Finder: names first, then contents (P-171). Settings › Search can turn it off. | Spotlight test on this repo: contents found 2 files that a name-only search missed |
| Search scope | The search field shows where it looks: the folder you're in, or **This Mac** (P-170). | Smoke `search-scope` |
| New windows | Settings › General › New windows open: the same folder, Home, Desktop, Documents or Downloads (P-017) | Smoke |
| Sidebar bookmarks | New bookmarks go at the end, folders dropped between two bookmarks land there, bookmarks can be dragged into a new order, and dragging one out of the sidebar removes it with the system's puff of smoke (P-188). Bookmarks were sorted by name before. | Smoke `bookmark-at`, `bookmark-move`; dragging itself needs a person |
| Shortcuts | View › Show View Options ⌘J, Go › Computer ⇧⌘C (every mounted disk) | Smoke `cmd viewOptions`, validation tests |

## UX refined in this pass

- **Settings** are rebuilt as a toolbar window: General, View, Appearance, Search and Advanced, with icons, grouped sections, captions and a window that fits each pane.
  - Wording is plain: "Directory cache TTL" is now "Remember folder contents for", and "Search typing debounce" is now "Start searching … after you stop typing".
  - The duplicate "liquid glass" switch is gone; the Sidebar pane's one remaining setting moved into View.
- **Operations panel:** "2 steps completed, 1 unsuccessful — permissionDenied" now reads "2 of 3 done. You don't have permission." The panel has a divider and a bar background.
- **Search results** are counted as results in the status bar, and the field says "Search Documents".
- **List rows:** text files show their type's icon. A preview of a page of text at list size was a blank white rectangle.
- **Smoke harness:** the first run ended with a real Quit, which exits 0, so a failing step before Quit never failed the run. It now reads failures from the log.

## Still missing, most important first

**Blocks daily use:**
1. **Progress with sizes and time left** (P-120). Large copies show item counts only.
2. **Selection and scroll after relaunch** (P-013, P-339). Windows, tabs, folders and views come back.
3. **More list columns and sorts** (P-036, P-055, P-040): Date Created, Date Added, Last Opened, Tags and Calculate All Sizes.
4. **Get Info** (P-095, P-209): live folder size, plus capacity and format for disks.
5. **Moving tabs between windows** (P-003): tear-off and merge.

**Expected by Finder users:**

6. **Network and AirDrop** (P-019): Go › Network is still disabled, AirDrop isn't a place, and Connect to Server works.
7. **Smart Folders and search filters** (P-336): kind, date and saved searches.
8. **Tags:** ruled out for now; Finder's tag colours aren't shown.
9. **Menus:** Recent Folders (P-012) and the click-and-hold Back history (P-008).
10. **iCloud:** download and remove-download actions, plus badges for cloud, shared, alias and locked items (P-050).
11. **Names:** hidden extensions and localized folder names (P-152).
12. **Ruled later:** Columns, Gallery, the preview pane and Print.

**Never run on real hardware, each needs your approval:**

13. **Real Trash:** Empty Trash and Put Back.
14. **A second disk:** eject, and drags across disks.
15. **Open at login:** registering it as a login item.
16. **The remaining live checks:** dragging sidebar bookmarks out and back, and Change Default App with macOS's confirmation. Both need the screen unlocked; on 2026-11-08 it was locked.

**Each new build is signed ad hoc,** so macOS treats it as a new app and asks again for access to Desktop, Documents and Downloads. A Developer ID signature would end that.
