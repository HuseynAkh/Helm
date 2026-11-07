# Owner rulings

Recorded 2026-11-06. This replaces "open" for every decision listed in `OWNER_DECISIONS_NOTE.md` and `OWNER_OPTIONS.md`.

Huseyn ruled directly on three items and delegated the rest: "For everything else, choose your best educated guess for the brand that we're going for. And of course, make sure it's macOS functional."

- **Huseyn** means Huseyn's own ruling.
- **Delegated** means Claude chose under that instruction. Huseyn can overrule any of these.

No ruling authorizes a push, a release or any other external action. The product reasoning behind these choices is in [`docs/rebuild/03-finder-nautilus-balance.md`](../rebuild/03-finder-nautilus-balance.md).

## Rulings by Huseyn

| ID | Ruling | Consequence |
|---|---|---|
| Q8 | **All.** Option B: all 296 reconciled P0/P1 rows must work before first use, not the staged bar. | The acceptance bar is the full set, so this is larger than one session. The ledger stays the record of what is and isn't done. |
| O1-1 / FB1-6 | **It should work like Finder.** | Implemented through option A, the bounded-race contract, because that is what makes the app behave like Finder without giving up the checks. See below. |
| Unicode paths | **Whatever is best for typing URLs, tied to Finder, feeling like Nautilus.** | Spellings that macOS treats as the same file are the same file in Helm. See the balance document. |

### What "like Finder" means for O1-1

- Copy, move, Trash, rename, duplicate and undo all work on real volumes, including for folders and packages.
- Copies clone on APFS and keep metadata, extended attributes and resource forks.
- Nothing ever overwrites a name that appeared after planning: destinations are admitted exclusively.
- A file replaced between planning and execution is refused, not silently moved. Finder doesn't check this, so it is one place Helm stays stricter.
- A small race window remains between the check and the rename, because macOS has no atomic compare-identity-and-rename. It is disclosed here, not hidden.
- Undo checks that it still has the same object (volume and file number). It doesn't refuse just because a file's contents or a folder's children changed, because undoing a create only moves it to the Trash and undoing a move only moves it back. Neither destroys anything, and this is what Finder allows.

## Delegated: needed for the real app

| ID | Ruling | Why |
|---|---|---|
| OK2-1 | **B.** The Mac integration owner builds the host. | With one owner there are no lanes to hand off between. |
| OK2-2 | **A.** One Mac integration owner for the manifest, `HelmUI`, `HelmApp` and their tests. | Worked in Mac run 1. |
| OK2-4 | **A.** `HelmDev` at `Sources/Helm`, project under `App/`, Xcode target `Helm`. | Worked in Mac run 1. |
| OK2-8 | **A.** Store protocols move into `HelmPersistence`. | Lets `HelmUI` name them without depending on `HelmApp`, and keeps memory fakes. |
| OK2-9 | **A.** A store that won't load goes read-only and browsing continues. | A damaged preference file must not stop someone reaching their files. |
| OK2-6 | **A.** One app-lifetime coordinator with per-window histories. | Cmd+Z in one window must not reverse work done in another. |
| OK2-10 | **A.** Folders navigate the key window, files launch. | What both Finder and Nautilus do. |

## Delegated: judgement calls with no recommendation in the docs

| ID | Ruling | Why |
|---|---|---|
| Arabic digits (B3) | **Use what macOS formats.** Tests use `ar-EG`, which has Arabic-Indic digits on both platforms, instead of bare `ar`. | Measured on this Mac: `ar` is Latin-digit, while `ar-EG` and `ar-SA` are Arabic-Indic. Helm follows the user's region, so this is a fixture fix and the product code doesn't change. |
| FB1-11 | **Keep** the exact-path allowlist for `/tmp`, `/var` and `/etc`. | Measured on this Mac: they point to `private/<same>`, carry the `restricted` flag, and SIP is on. Revisit if Helm ever runs on other Macs. |

## Delegated: repo

| ID | Ruling | Why |
|---|---|---|
| OK2-35 | **A.** Rename to `FileDropSession`, `FileDropOperation`, `FileDropProposal`, `HelmToolbarItem`. | Clears the guard, so a red `run_all.sh` means something new. |
| Q6 (Xcode project) | **Generated, not committed.** Listed in `.gitignore`. | `xcodegen` regenerates it from `App/project.yml`. |
| Q7 | **A.** Work leaves this Mac by a push to `HuseynAkh/Helm`, once Huseyn approves that exact push. | On 2026-11-07 Huseyn approved pushing `handoff/mac-fixups`, authored by him alone. Each later push needs its own approval. |

## Delegated: features

| ID | Ruling | Why |
|---|---|---|
| OK1-3 | **A.** Streaming search seam. | Keeps live Spotlight updates. |
| OK1-2 | **A.** Add `.notCloud`; on a true `.unknown`, try opening anyway. | A failed metadata read must not stop a file opening. |
| FB2-9 | **A.** Migrate per key. | One damaged key must not cost all three collections. |
| FB2-10 | **A.** New Core action for loading children. | Keeps stale-result checks, and expanding folders is core Nautilus behaviour. |
| OK1-5 | **A.** Follow the root at depth 0 for the current folder only. | Searching from where you are should work. |
| OK1-12 | **A.** 4 at a time, visible cells first. | Keeps large grids responsive. |
| OK1-11 | **A.** Accept the loss for now and test signals on the Mac. | Correct lookups are too costly on large folders. |
| Q9 | **A.** Typing a file's path reveals and selects it; nothing launches. | Matches Finder's Go to Folder, and typing a path shouldn't launch anything. |
| OK2-12 | **Commit** when clicking away from a rename. | What both Finder and Nautilus do. |
| OK2-22 | **F-065's panes:** General, Appearance, Behavior, Advanced. | Matches the parity spec. |
| OK2-23 | **Current folder** in a directory, **everywhere** in Recent. | Nautilus searches where you are. |
| OK2-27 | **Report the rejection,** then launch normally. | Launching with no window looks broken. |
| OK2-29 | **Add "Quit Anyway",** naming the unsaved documents. | The choice is the user's, with the loss named. |
| OK2-30 | **Report through the operations panel.** | A pending rename's failure must not vanish. |

## Delegated: architecture defaults

These had working defaults in `01-architecture.md` sections 14.1 and 14.5. The numbering below is the architecture's own: its Q6 to Q9 are not the plan questions above.

| ID | Ruling | Why |
|---|---|---|
| Q1 breadcrumb click | **An ancestor segment navigates. The current segment or empty space edits.** | Nautilus behaviour, and it keeps the deliberate click-to-edit for the part of the bar where navigation would do nothing. |
| Q2 New Folder | Create immediately, then inline rename. | Keeps the default. Both Finder and Nautilus get you naming it straight away. |
| Q3 Folder Tree sidebar | Not built. | The sidebar stays Places only, like Nautilus. |
| Q4 single-click open | Setting removed. | Double-click everywhere, matching the macOS default. |
| Q5 cross-volume drags | Copy across volumes, move within, Cmd forces move, Option forces copy. | Finder parity. |
| Q6 tab keys | In scope: Shift+Cmd+] and [ switch tabs. Dragging a tab to reorder comes later. | Finder's keys. |
| Q7 stars | Helm-private. | Stars stay distinct from Finder tags. |
| Q8 search frequency | Not in this rebuild. | The seam stays. |
| Q9 collision dialog | **Show it,** with Keep Both, Replace, Skip and Stop. | The default was silent keep-both. Finder asks, and a surprise `name 2` is not "works like Finder". `helm.askOnConflict` now defaults to on. |
| Q10 Trash confirmation | No confirmation; undo is the safety net. | Finder and Nautilus both trash immediately. |

### Finder scope table (14.5)

| Capability | Ruling |
|---|---|
| Eject and unmount | In scope, from the sidebar and File menu |
| Open in New Tab or Window, Cmd-double-click | In scope |
| Close Window, Reopen Closed Tab | In scope: Shift+Cmd+W, Shift+Cmd+T |
| Alias and symlink creation | In scope, no default shortcut |
| Native window tabbing | Off, to protect the custom tab strip |
| Selection after Trash | Next visible item, previous at the end, empty if none |
| Star badge, hidden-file dimming | Kept |
| iCloud placeholders | Read-only availability badge; download and evict come later |
| Free-space preflight | Kept |
| Services, default folder viewer | Standard Services menu only. Helm never changes an OS default on its own |
| Connect to Server | In scope: typed `smb://` and similar URLs hand off to macOS |
| Compress, Get Info editing, preview pane, column and gallery views, localization | Later |
| Linux toolchain, macOS CI | No action. Nothing installed, provisioned or spent |

## Ruled but not built yet

The app works without these, but each ruling above is still owed. Row-level status is in [`P0_P1_STATUS.md`](P0_P1_STATUS.md).

| ID | What's left |
|---|---|
| OK2-22 | Settings still has the five panes General, Sidebar, View, Search and Advanced, not F-065's four. |
| OK1-2 | `.notCloud` isn't added. Nothing in the app consults `CloudActionPlan`, so no file is refused today. |
| OK1-3 | Search streams live Spotlight results in the host. The shared search contracts weren't changed to match. |
| OK1-5 | Navigation lands on the real folder, so a symlinked starting point no longer arises. Searching inside a package still skips it. |
| OK1-12 | Icons load 4 at a time, in the order requested, not visible cells first. |
| OK2-30 | A failed rename shows an alert, not a row in the operations panel. |

## Not changed by these rulings

These still need Huseyn's explicit approval of the exact action:

- Pushing any branch.
- Moving anything into the real Trash during testing.
- Mounting or ejecting a real volume during testing.
- Pointing a test run at real files, or at the legacy `Helm` defaults domain.
