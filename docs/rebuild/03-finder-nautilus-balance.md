# Finder underneath, Nautilus on top

Huseyn's brief, 2026-11-06: paths and URLs should be easy to type, it should be "tied to Finder management", and it should "feel like Nautilus on GNOME".

This is the rule that settles those together. When a feature could go either way, decide it here first.

## The rule

**What happens to your files follows macOS. How you get around follows Nautilus.**

If a behaviour affects what's on disk or how other Mac apps see it, Helm does what Finder does, so nothing surprises you when you switch between them. If a behaviour is about moving through folders and choosing things, Helm does what Nautilus does, because that's why Helm exists.

| Finder decides | Nautilus decides |
|---|---|
| What a copy keeps: clones, dates, extended attributes, ACLs, links stay links | One window, one pane, tabs |
| Moving to the real Trash, and Put Back | A path bar that turns into a typed location |
| Which names count as the same name | A flat Places sidebar with Starred and Recent |
| Finder tags, aliases, packages as single items | Grid and list only, with expandable folders in the list |
| Quick Look, Open With, Share, Services | A quiet header bar with few controls |
| Spotlight for search, Connect to Server for mounts | Cut and Paste for files |
| Whether a drag copies or moves | Search starts in the folder you're in |

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
