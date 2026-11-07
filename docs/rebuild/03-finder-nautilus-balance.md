# Finder underneath, Nautilus on top

Huseyn's brief, 2026-11-06: paths and URLs should be easy to type, it should be "tied to Finder management", and it should "feel like Nautilus on GNOME".

This is the rule that settles those together. When a feature could go either way, decide it here first.

## The rule

**What happens to your files follows macOS. How Helm looks and how you get around follow Nautilus.**

If a behaviour affects what's on disk or how other Mac apps see it, Helm does what Finder does, so nothing surprises you when you switch between them. If it's about how the app looks, or moving through folders and choosing things, Helm does what Nautilus does, because that's why Helm exists. Huseyn, 2026-11-06: "I meant that it should have Finder functionality", with the feel of Nautilus and the transparency of the original Helm.

| Finder decides | Nautilus decides |
|---|---|
| What a copy keeps: clones, dates, extended attributes, ACLs, links stay links | One window, one pane, tabs |
| Moving to the real Trash, and Put Back | A path bar that turns into a typed location |
| Which names count as the same name | A flat Places sidebar with Starred and Recent |
| Finder tags, aliases, packages as single items | Grid and list only, with expandable folders in the list |
| Quick Look, Open With, Share, Services | A flat header bar, drawn by Helm instead of macOS's glass toolbar |
| Spotlight for search, Connect to Server for mounts | Cut and Paste for files |
| Whether a drag copies or moves | Search starts in the folder you're in |

## The look

| Part | What it is |
|---|---|
| Header bar | Flat icon buttons that light up under the pointer: sidebar, back, forward, then the path, then search, sort and view options, grid or list, and the main menu |
| Path bar | One rounded field reading `Home / Documents / Reports`, with the current folder in bold. It starts from Home or the drive, not `/Users/you`. A trailing `…` opens the folder's menu. |
| Sidebar | One full-height translucent pane with monochrome icons, soft selection and thin lines between groups instead of headings |
| Transparency | On by default at 50%: the desktop shows through the sidebar, and less through the files so text stays readable. Settings › View has a slider from solid to clear, where the sidebar clears first, and a switch to turn it off. |
| Text | 14 pt names by default, in both views, shown as 100%. Text steps by 10% from 80% to 170%, with the percentage between − and + in the view options popover; clicking the percentage resets it. Cmd+Plus and Cmd+Minus scale text and icons together. |
| Tabs | Flat, with a soft fill on the active tab and the close button on the right |
| Sorting | A button in the header always names the current sort, such as "A to Z" or "Newest first". Its popover lists Name, Modified, Size and Kind: pick one, and pick it again to reverse it, as with a column heading. A new field starts in its natural direction, newest or largest first for dates and sizes. In the list, the sorted column shows an arrow. |
| App icon | A small horned Norse helmet sitting on a blue folder, on a rounded-square tile. Drawn in code by `scripts/rebuild/make_app_icon.swift`, so every size is sharp. |

## Drag and drop, previews and Open With

These follow Finder, because they decide what happens to files and which app gets them.

| Part | What Helm does |
|---|---|
| Drop targets | The grid, the list, sidebar places, path segments and tabs all use one set of rules, so the pointer's badge is what will happen. |
| Modifiers | Option copies, Cmd moves, Option and Cmd leave an alias. Otherwise a drop moves within a volume and copies across volumes. |
| Refused drops | A folder can't go into itself or a folder inside it. Moving something to where it already is isn't offered. Both are refused while you're dragging. |
| Apps | Files dropped on an app open in it if it can open them. |
| Documents | A drop on a document goes into the folder it's in, and the whole view lights up. |
| File promises | Pictures from Photos, Mail attachments and Safari images are accepted. They're written to a private folder on the destination's volume, then copied in, so a name that's taken asks first and Undo removes them. |
| Spring-loaded folders | Hold a drag over a folder, sidebar place, path segment or tab and it opens. This follows the system's spring-loading switch and delay. |
| Previews | Every file with content gets a Quick Look preview: pictures, films, PDFs, text, and office and iWork documents. Previews are made at the size shown and the screen's real pixel density, in the grid and the list. A quick low-resolution version shows first, and a better image is never replaced by a worse one. Cloud files that aren't downloaded keep their icon. |
| Quick Look | It follows the selection however it changes. With several items it pages through them in display order. It zooms out of the item's own thumbnail. |
| Open With | The default app first, then apps you've used for this kind of file, newest first. Then Recommended, ranked by how closely each app claims the type (an owner before an alternate, an editor before a viewer). Apps that only accept any file go under Other Apps. Each app is listed once, even with several copies installed. |
| Default app | Hold Option for "Always Open With", or use Change Default App… or the chooser's "Always open … files with this app". This changes the default for that kind of file, as Finder's Get Info › Change All does. Helm never changes a default on its own. |

## 1. Where the two disagree

| Situation | Finder | Nautilus | Helm | Why |
|---|---|---|---|---|
| Return on a file | Rename | Open | **Rename** | The legacy map and macOS habit. F2 also renames, for Nautilus hands. |
| Opening | Cmd+Down or double-click | Return or double-click | **Cmd+Down, Cmd+O or double-click** | Follows from the row above. |
| Preview | Space | Space | **Space** | They agree. |
| Moving files by keyboard | Copy, then Option+Cmd+V | Cut, then Paste | **Both** | Cmd+X and Cmd+V are the identity. Option+Cmd+V costs nothing to keep. |
| Duplicate's name | `x copy` | `x (copy)` | **`x 2`** | Kept from legacy Helm by the preservation map. |
| Name already taken | Ask | Ask | **Ask** | They agree. `helm.askOnConflict` turns it off. |
| Clicking in the path | Finder's path bar navigates | A parent navigates | **A parent navigates. The current folder or empty space starts typing.** | Clicking the folder you're already in has nothing to navigate to. |
| Go to a location | Shift+Cmd+G, in a floating panel | Ctrl+L, in place | **Cmd+L, Ctrl+L and Shift+Cmd+G, all in place** | Three habits, one bar. |
| Typing with files focused | Selects by name | Starts a search | **Selects by name** | Matches macOS, and Cmd+F is one key away. |
| Search scope | This Mac | Current folder | **Current folder** | Search where you are. In Recent or Trash, there's no folder, so it searches the Mac. |
| Hidden files | Shift+Cmd+. | Ctrl+H | **Cmd+. and Shift+Cmd+.** | Cmd+. is the legacy key. |
| Up one folder | Cmd+Up | Alt+Up | **Cmd+Up** | On a Mac, Cmd plays the part of Alt here. |
| Symlink to a folder | Lands on the real folder | Stays on the link's path | **Lands on the real folder** | It affects where operations happen, so Finder decides. |
| Sidebar highlight | Exact match only | Deepest containing place | **Deepest containing place** | A navigation choice. |
| Trash confirmation | None | None | **None** | Undo is the safety net. |
| Moving between volumes | Removes the original once copied | Removes the original once copied | **Original goes to the Trash** | One deliberate deviation. Helm never destroys what it can keep recoverable. |

## 2. Unicode: which names are "the same"

Measured on this Mac, on APFS:

- `café` written in its composed (NFC) and decomposed (NFD) forms is one file. Creating the second fails with `EEXIST`.
- A directory listing returns the name exactly as stored.
- `URL(fileURLWithPath:)` always decomposes, so URLs hold NFD whatever you gave them.

So the old test assumption, that the two spellings stay distinct, can't hold on macOS, and fighting it would make Helm disagree with every other Mac app about which file is which. Helm's rule:

1. **Two spellings macOS treats as one name are one item in Helm.** Selection, sharing, path segments and collision checks compare by canonical form. On Linux, where a byte difference can be a different file, comparison stays byte-exact.
2. **Names are shown as the disk stores them.** Helm never rewrites a name just because it read it.
3. **A rename that only changes the Unicode form isn't a change,** so it does nothing, as in Finder.

## 3. Typing locations

The location bar should accept whatever you'd reasonably paste or type, then land on the real folder.

| You type | Helm does |
|---|---|
| `/Users/me/Documents` | Goes there |
| `~` or `~/Documents` | Goes to Home, or inside it |
| Nothing | Goes Home |
| `Reports` or `../Reports` | Relative to the current folder |
| `~/documents` | Goes to `~/Documents`, the disk's real spelling, because the volume isn't case-sensitive |
| `~/café` in either Unicode form | Goes to the folder, however its name is stored |
| A path through a symlink | Goes to the real folder |
| `file:///Users/me/My%20Files/` | Goes to `/Users/me/My Files` |
| A path to a file | Shows its folder and selects it. Nothing launches (Q9). |
| `smb://`, `cifs://`, `afp://`, `nfs://`, `ftp://`, `webdav://`, `webdavs://`, `vnc://` | Hands the address to macOS, as Connect to Server does. macOS handles the sign-in, and Helm never sees a password. |
| `http://` or `https://` | Treated as a path, so it fails visibly. Helm is not a browser. |
| Anything that doesn't exist | The bar shakes and beeps, and you stay where you are |

While you type, completions match on any case and either Unicode form, directories come first, Tab accepts or drills in, Right arrow accepts the ghost suffix, and Esc closes the list, then the bar. These come from the legacy address bar (F-014 to F-024) and are unchanged.

A name that's typed but doesn't exist yet, such as a new folder name, is stored however Foundation writes it, which is the same thing Finder does.

## 4. What Helm is not

These follow from the rule, so they don't need deciding again:

- **No column view, gallery view or preview pane.** Grid and list are the identity, and the seam stays for later.
- **No folder tree in the sidebar.** Places only.
- **No per-folder view memory in `.DS_Store`.** Helm keeps its own.
- **No OS default changes.** Helm can open folders when asked, but it never makes itself the default on its own.
- **No overwriting.** A name that appears after planning is never replaced silently. This is stricter than Finder in one way: if a file changes between planning and running, Helm refuses instead of acting on something you didn't see.
