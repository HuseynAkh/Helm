# Can Helm be the default file manager?

What it takes for Helm to stand in for Finder day to day, what this pass built, and what's still missing. Written 2026-11-08 against `handoff/mac-fixups`. Row numbers (P-…) are from docs/rebuild/02-finder-parity.md; status for everything else is in P0_P1_STATUS.md.

## How macOS lets another app stand in for Finder

There's no single switch. Path Finder, ForkLift and Marta use the same two settings, and Helm now uses them too:

1. **The global `NSFileViewer` preference.** When an app calls `NSWorkspace` to show a file (Show in Finder, Reveal in Finder), AppKit sends the request to the app this preference names instead of Finder. On 2026-11-08 this was checked with a throwaway probe app and a per-process preference, so no real setting changed. AppKit delivered the request as an ordinary open-documents event carrying the file itself, with nothing but its sender to tell it apart from `open -a` (see "How requests are routed now"). So a file manager that receives a file must show it in its folder, not launch it.
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

## How requests are routed now (2026-11-10)

Huseyn double-clicked an archive in Finder and got Helm's Home window. Two throwaway probe apps, each with its own test bundle ID and `NSFileViewer` set only in the caller's own preferences, showed what macOS 26.7 sends the file viewer. Neither was ever a default.

| The other app calls | Helm receives |
|---|---|
| `activateFileViewerSelecting` (Show in Finder) | An open-documents event naming the items, with the sender's process number. If Helm isn't running, this event starts it and arrives before the first window. |
| `selectFile(_:inFileViewerRootedAtPath:)` | The same event. The root folder is dropped. |
| `selectFile(nil, inFileViewerRootedAtPath:)`, or a reveal of no items | A reopen naming nothing. If Helm isn't running, a plain launch that names no sender. |
| Opening a folder | Nothing: folders go to Finder, which macOS keeps as the folder handler. |

No NSWorkspace call sends the old reveal event ('misc'/'mvis'). Helm handles it anyway.

Sandboxed apps add two checks, made by CoreServicesUIAgent. The file viewer must claim the item's type, and the sender must have sandbox access to the item's location. Helm claimed only folders, so a sandboxed app's Show in Finder on a file failed (kLSAppDoesNotClaimTypeErr). Helm now also claims any item at rank None. That passes the check, and Helm still isn't listed in any file's Open With menu.

**Why the archive opened Home.** The system log from 2026-11-10 at 00:51 shows the order:
1. Finder had Archive Utility expand the archive.
2. Archive Utility revealed the result through the file viewer, Helm. CoreServicesUIAgent refused that: Archive Utility had no sandbox access where the result was (permErr -54). The item never reached Helm.
3. As Archive Utility quit, it asked for the file viewer again, naming nothing. Helm got a plain reopen, as if its Dock icon had been clicked.
4. With no window showing, Helm opened a new window at its "New windows open" folder: Home.

One more problem turned up: a request that arrived while Helm was still placing its first windows was dropped, and the launch showed Home.

**What Helm does now:**
- Each request's sender is looked up from its process number: the running app, its executable, or a helper that quit within the last minute.
- **What Finder itself sends stays in Helm:** Open With › Helm, a drop on Helm's icon, and a double-click on Helm in a Finder window. A running Helm gets that double-click as a reopen from Finder. The first version sent Finder's reopens back to Finder, so a double-click on Helm brought Finder forward instead.
- **Archive Utility and DiskImageMounter go back to Finder.** Finder opens the item's folder through Launch Services (no Apple Events to Finder). A request naming nothing only brings Finder forward.
- **Unless Helm started that helper for that item** in the last 10 minutes, through Expand Archive, Open, a double-click, Open With or a drop on the app. Then Helm shows the item. On Archive Utility's last request, Helm shows the archive's folder with what was expanded selected.
- **A hand-off also ends 10 seconds after its helper quits.** The helper's last request comes as it quits. If that request never reaches Helm, the hand-off still ends, so a later double-click on an archive in Finder isn't taken for Helm's.
- **Any other app, or a sender Helm can't identify, stays with Helm** as before. Show in Finder from Safari, Mail and the rest keeps working.
- **Requests that arrive while Helm starts wait for the first window.** None ends in a Home window. A launch that only passed something to Finder opens no window; the next click on Helm's Dock icon launches as usual.

Checked by `ViewerRoutingTests`, `ViewerEventTests` (events built in the test), `ViewerLaunchTests` (a fixture app, invisible windows), and the smoke steps in `scripts/rebuild/smoke.d/finder-route.txt`. Those use a stand-in for Finder, so Finder, Archive Utility and DiskImageMounter are never started. The smoke steps also send real events through AppKit's open and reopen handlers and Helm's reveal handler. An event built in Helm can't carry another app's process number, so the step names the sender, and Helm reads it through the same lookup while the event is handled. Reading the process number itself was checked only with the probe apps.

**What macOS still sends to Finder:**
- **Disk image windows.** DiskImageMounter calls Finder directly (AESendMessage), never the file viewer, even when Helm opened the image.
- **The item an archive expanded to, after a double-click in Finder.** Archive Utility usually can't hand it to any other file viewer. Finder now comes forward, with the item next to the archive, though not selected.
- **A cold start from Archive Utility.** If Helm isn't running, Archive Utility's last request starts Helm, and a launch names no sender. Helm opens no window while Archive Utility is running, so the item stays with Finder, unless someone asked for Helm: a click on its Dock icon, or the copy Set Up moved to Applications.
- **Folders opened from other apps, Spotlight and the Dock**, and everything in "What no third-party app can take over" above.

## Built in this pass

| Need | What Helm does now | Checked by |
|---|---|---|
| Become the file viewer | Settings › General › Default File Viewer: **Make Default** sets `NSFileViewer`, and asks for the folder handler, which macOS 26 refuses. **Restore Finder** undoes it. The same switches work from Terminal: `/Applications/Helm.app/Contents/MacOS/Helm --default-viewer helm\|finder`, and `--viewer-status` reports the current state. | Smoke `file-viewer` (fixture stand-in); live on this Mac: set, and a Show in Finder request reached Helm |
| Helm in the Dock | **Show next to Finder in the Dock** puts Helm's tile first, right after Finder's, which macOS keeps first. Turning it off puts Helm back where it was, or out of the Dock if it wasn't there. From Terminal: `--dock-first on\|off`. | Smoke `first-in-dock`; live on this Mac: off then on, confirmed in the Dock's settings |
| Show in Finder from other apps | A file sent to Helm opens its folder with the file selected. Several files from one folder are selected together, and other folders open as tabs. This amends OK2-10, under which files launched. | Smoke `open-external` |
| Services | **Open in Helm** (folders) and **Show in Helm** (any item) in the Services menu and Finder's context menu (P-238) | Smoke `service-show` |
| Always available | Settings › General › **Open at login**, through SMAppService. Helm already keeps running with no windows open. | Not run: it changes a login item |
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

## Full Disk Access (Mac run 3, 2026-11-09)

A file manager works best when it can see the whole Mac. Without Full Disk Access, macOS keeps the Trash, Mail, Safari and other apps' data out of reach, and asks before Helm opens Desktop, Documents and Downloads. The music, TV and photo libraries and cloud drives have switches of their own, even with Full Disk Access. Huseyn found the Trash refusing with no way forward: Full Disk Access isn't in Files and Folders, so he couldn't find where to grant it. What Helm does now:

| Need | What Helm does | Checked by |
|---|---|---|
| Say so from the start | One setup screen on first launch, while something is left to do: Use Helm instead of Finder, Full Disk Access, and Move to Applications only when Helm runs from somewhere else. Nothing changes until Set Up; Not Now changes nothing. Help › Set Up Helm… shows it again. (This replaced the first two-page welcome on 2026-11-10.) | Smoke `onboarding` and `setup` steps in `permissions.txt`; the screen counts as seen once it's closed, or when Helm quits with it open |
| Explain a refusal | A card in place of the listing names the place and why: Full Disk Access, Files & Folders, another app's data, a cloud provider, a disk that stopped answering. Buttons: Grant Access…, Open in Finder (Trash only) and Try Again. | Smoke `permissions.txt` on fixture folders locked with `chmod` |
| Find the setting | Help › Full Disk Access… and Settings › General › Access open the guide. It reads System Settings › Privacy & Security › Full Disk Access, + or drag Helm in, then Quit & Reopen. | Smoke; the real list wasn't touched |
| Notice the change | Helm tries refused places again when it comes back to the front, and when Full Disk Access turns on. | Smoke with the stand-in access switch |
| Don't freeze the disk | Folders macOS guards get their own I/O lane, so a folder waiting on a macOS question no longer makes the whole disk "stop responding". | `PrivacyLaneTests` |
| No drop box icon | Folders macOS guards, such as ~/Movies/TV and ~/Music/Music, show a plain folder icon, not the system's drop box picture. | `PrivacyFolderIconTests` |

The project still signs Helm ad hoc, so every rebuild is a new app to macOS: Full Disk Access has to be removed with − and added again, and the folder questions come back. The guide says so when it detects it. Signing with a stable identity would end that, and is Huseyn's call.

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

**Each new build is signed ad hoc,** so macOS treats it as a new app: it asks again for access to Desktop, Documents and Downloads, and Full Disk Access has to be given again. A stable signing identity would end that.
