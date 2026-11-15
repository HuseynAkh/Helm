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
| OK2-10 | **A, amended 2026-11-08.** Folders navigate the key window; files are shown selected in their folder. | Files launched at first. To be the default file viewer, Helm receives other apps' "Show in Finder" as plain open requests, which can't be told apart, so a file sent to Helm is shown rather than launched. See DEFAULT_FILE_MANAGER.md. |

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

## Asked by Huseyn on 2026-11-09

Huseyn's requests after using the 8a6657d build: the search field stayed in focus; sidebar rows couldn't be arranged or hidden, "both by dragging and in settings"; Movies and Music showed a file over the folder icon; Recent should keep folders apart from files; two three-line buttons in the header looked wrong; folders opening in the list weren't smooth; the Trash asked for Full Disk Access with no way to give it; and Helm should say from the start that it works best with Full Disk Access, with an onboarding flow. He also found the window edges hard to grab. What was built is in [`MAC_RUN_3.md`](MAC_RUN_3.md).

### Delegated choices in Mac run 3

Huseyn can overrule any of these.

| Topic | Choice | Why |
|---|---|---|
| Search focus | **The header follows the tab.** An empty search closes when you click away; one with words keeps its results and gives the keys back to the files. Going anywhere ends it. | What Finder and Nautilus both do. |
| Header buttons | **Search, one view button, the sort button with words and a chevron, then the main menu as dots in a circle.** Run 4 put the spark between the sort button and the menu. | Two three-line buttons became one dots button, in the existing style. The circle tells the main menu apart from the path's own ⋯. The view button is one button since Huseyn's request of 2026-11-12, below. |
| Window edges | **macOS 26's own resizing, unchanged.** Smoke checks make sure nothing of Helm's covers the resize band. | Finder's edges behave the same on macOS 26; Helm's content wasn't in the way. |
| Sidebar | **Rows move within their own group. Any row can be hidden, Recent and Trash included. Go › Trash is added so a hidden Trash stays reachable. The drives group is called Locations in Settings.** | Moving a drive among Favorites would mix kinds of place. |
| Access | **A card in place of the listing, with Grant Access…, Open in Finder for the Trash, and Try Again. A once-only welcome. Signing stays ad hoc.** | Signing with a real identity is Huseyn's call (see Open in `MAC_RUN_3.md`). |
| Protected folders | **A plain folder icon,** decided by the folder's path, not the system's drop box picture. | The drop box means "you can put things in but not look", which isn't what's happening. |
| List motion | **One 0.28 s ease-in-ease-out curve** for opening and closing; Reduce Motion fades only. | About as long as before, but smooth. |
| Recent | **Folders and Files sections, sorted by Last Opened.** | Keeps the folders Huseyn likes seeing, apart from the files. |

### Asked by Huseyn later in the same run (2026-11-10)

| Topic | Huseyn's words, in short | What was built |
|---|---|---|
| Privacy | Helm collects nothing about the person and exports nothing; everything stays on the Mac. | Three audits found no network code or telemetry, and nothing that reads who you are or which Mac this is; disks' IDs are read only to tell disks apart, and kept only in memory. The release binary is stripped of build paths and has no entitlements, a source and a binary check guard it, and smoke runs block the network by default. Recent can be turned off, and Helm keeps less. |
| Install | A full release that people can download, audit and install, perhaps a DMG. | A DMG with an Applications shortcut, a zip, SHA-256 checksums and release notes, from `scripts/release/make_release.sh`. A GitHub workflow that runs only for a pushed tag or when started by hand builds them, with provenance attestations, as a draft. |
| Onboarding | Minimal: one screen, two at most, only what matters, with Helm replacing Finder set up there. | One setup screen: Use Helm instead of Finder, Full Disk Access, and Move to Applications only when needed. |
| Text | Onboarding and Settings text massively de-loaded, one sentence at most per explanation. | Several passes over 129 strings; two Settings › Advanced rows that did nothing are hidden. |
| Finder | Opening an archive in Finder shouldn't jump to Helm, and shouldn't open Home. Finder's own actions stay Finder's. | Requests from Finder's helpers go back to Finder; Helm-started ones and other apps' Show in Finder stay with Helm. |
| Open With | It was greyed out. | The cause and the fix are in `MAC_RUN_3.md`. |
| Names | Long names shortened on show until clicked, in a controlled way, not excessive in the list. | Finder's rule in the grid: two lines, one middle cut that keeps the extension, the full name when selected or hovered. The list is unchanged. |

### Delegated choices, 2026-11-10

| Topic | Choice | Why |
|---|---|---|
| Open With on folders | **No Always Open With or Change Default App… for folders.** | A folder's default app is the one for every folder, the setting Helm's own file viewer switch uses. Finder offers neither. |
| Archive Utility starting Helm | **A launch while Archive Utility runs, naming nothing, opens no window.** | That launch is Archive Utility's last request after a double-click in Finder. A click on Helm's Dock icon still opens a window. |
| Dead settings | **"Remember folder contents briefly" and "Remember for" are hidden.** Their keys stay, so stored settings still read. | No window load used them. |
| Release | **Draft releases only, built on a pushed tag or by hand.** | A person publishes each release, and no workflow runs on ordinary pushes or pull requests. |

## AI mode, Mac run 4 (2026-11-12 to 14)

What was built and checked is in [`MAC_RUN_4.md`](MAC_RUN_4.md).

### Rulings by Huseyn

| Topic | Huseyn's words | Date | What was built |
|---|---|---|---|
| AI mode | "I want to build it into an agentic file manager with an agentic base separately built for it." | 2026-11-12, the request for run 4 | AI mode, off until turned on: the spark, the AI panel with three suggestions, plans with Apply and one Undo, AI search, the AI Mode screen and Settings › AI. The new module `HelmAgent` holds the providers, the transport and the conversation. |
| Providers | "This should be compatible with Claude, OpenAI, Gemini and other main models (e.g. general API connect / more with grok), LM studio for local running, Olamma" | 2026-11-12 | Claude, OpenAI, Gemini, Grok, Ollama, LM Studio, and Other for any OpenAI-compatible https address. |
| One view button | "combine the functionality of these 2 buttons into 1 to save space" | 2026-11-12 | One button shows the view you'd switch to. ⌘1 and ⌘2 stay. |
| Remote folders | "Make sure that it can detect when you are in a remote directory and can work with them as well, such as Google Drive, iCloud, and so forth." | 2026-11-12 | The panel's chip names the place, plans say when changes sync or reach others, and nothing is downloaded. |
| Path bar | "just thought about it and I'm not sure if we should force the path bar to fully expand after we press the AI mode. It's current state might be fine and users can click on it when needed" | 2026-11-13 | The path bar is not changed. Opening the panel does nothing to it. |
| README | "Make sure you design an effective README at the end. You don't have to fully remove mentions of Nautilus, as I believe it still keeps parts of its DNA, but definitely the defining feature now becomes this being an agentic system. So make sure that the designs, the first pictures and so forth reflect that. I would not personally change the Helm logo, however." | 2026-11-13 | The README leads with AI mode: the title line, the banner, then the panel, a plan and AI search. "Nautilus on top, Finder underneath" stays, lower down, as Helm's DNA. |
| Logo | "Decide on a good logo." Then, on 2026-11-13: "I would not personally change the Helm logo, however." | 2026-11-12 and 13 | The app icon is unchanged. Helm's four-point spark, in amber, coral and violet, is the mark of AI mode. The banner is the icon with the spark beside it, drawn by `scripts/readme/make_brand.swift`. No variant icon was made. |
| Interface review | "Make sure you check the UI and UX elements comprehensively and that they are in their best placement and functionality that we would need." He also asked to review the three dots, whose circle "would sometimes get shrunk and compressed". | 2026-11-13 | A review of every AI mode state on both SDKs, and 34 fixes. Icon-only header buttons now draw their symbol whole at every width. |
| Reinstall | "You're good to do a full reinstall." | 2026-11-14 | `/Applications/Helm.app` is the 0.2 build of this run. |
| README footer | "You can remove the tools Helm was built with." | 2026-11-14 | The footer that named them is gone. |
| About line | "Yes" to "An agentic file manager for your Mac." | 2026-11-14 | The About panel reads "An agentic file manager for your Mac." |
| Draft markers | "Sure" to removing the "DRAFT: pending … review" header lines | 2026-11-14 | Removed from source, tests, scripts and docs in a commit of their own. Old review reports keep their wording. |
| Version | "Sure" to 0.2 | 2026-11-14 | This run ships as 0.2. |
| Subscriptions | "We don't want to be using AI keys, instead subscriptions for OpenAI and Claude if available etc. (also need mini tooltips or guide links to explain how to do this, e.g. docs links + extra info in tooltip)." | 2026-11-14 | OpenAI connects with Continue with ChatGPT, using the plan; a key stays as a quiet second choice. Anthropic doesn't allow apps like Helm to use a Claude subscription, so Claude keeps a key. Gemini, Grok and Other keep keys; LM Studio and Ollama need none. Every provider has an info button with a one-sentence tooltip and a "How to connect" link. |
| Setup before access | "We should have us go through onboarding before it requesting access to "Downloads, Documents, etc"." | 2026-11-14 | Setup shows before any window when it was never seen or the build changed, and nothing guarded is read until it closes. Its Full Disk Access row explains why in one line. |
| Panel width and models | "the AI sidebar size should be adjustable and models changeable for LM studio as well as if you connect multiple AI tools." | 2026-11-14 | The panel's edge drags between 300 and 560 points and the width is kept. The model name is a menu of every connected provider's models. |
| Address field | "if you open the address /url tab and then press on the AI sidebar the url tab stays open (should close after clicking off)." | 2026-11-14 | A press anywhere outside it closes it, as Escape does. `PathBarView.swift` is unchanged. |
| Search spark | "check if the AI mode actually toggles on and off in search" | 2026-11-14 | The search field shows the spark whenever AI mode is on; with no model ready, pressing it opens the AI Mode screen. A connected local provider always has a model chosen. |

### Delegated choices in run 4

Huseyn can overrule any of these. Each one's reason is in its last column.

| Topic | Choice | Why |
|---|---|---|
| Off by default | **AI mode is off until turned on, and no network client exists while it's off.** | Helm then connects only to the provider you chose, and only while AI mode is on. |
| Separate base | **`HelmAgent` can reach the network but can't change or open a file. HelmUI applies plans.** | The module that talks to a model can't touch the disk. |
| Keys | **The login keychain, one key per provider and host.** | A changed `ai.json` can't send a saved key to another host. |
| What is sent | **Names and details only. Reading inside files is not built.** | Contents never leave the Mac. |
| Folders | **The folder on show plus up to seven added ones, inside the home folder, `/Volumes` or the Shared folder. Added folders aren't saved.** | An allow list can't miss a system place or leave standing access. |
| Tools | **Three: list a folder, find items, propose changes. Items are named by ids Helm issues, never by path.** | No path parsing and no escapes. |
| Plans | **Nothing changes until Apply. Trash, and changes that reach a place that syncs or is shared, start unticked. Conflicts keep both. No delete, no shell, no web tool. 1,000 changes at most.** | Nothing is destroyed or overwritten unseen. |
| Undo | **One Apply is one Undo. An undone plan can't be redone.** | A redo would run the plan again without Apply's checks. |
| Cloud folders | **Never download. Files that aren't downloaded are left out, with a count.** | A wrong guess then fails with nothing fetched (question 1 in `MAC_RUN_4.md`). |
| Panel | **A column 340 points wide by default, 300 to 560 when dragged, shut at every launch. Opening it hides the sidebar first, then widens the window if the files need room.** | The header and today's layout stay as they were. |
| Spark | **Opens the panel when a model is ready, and the AI Mode screen otherwise. Done on that screen opens the panel.** | One door for "not ready". |
| Commands | **`/add` and `/clear`. A path typed alone adds a folder. A server address gets one Connect line and goes to macOS.** | Two commands cover it, and macOS does the sign-in. |
| Suggestions | **Three, worked out on the Mac with no model: Organize, Move everything to…, Copy everything to…** | Huseyn's three examples, shown whenever the panel opens. |
| AI search | **Two model calls at most. The model plans searches, Helm runs them, and the reasons are facts Helm writes, shown as each result's tooltip.** | A hostile file name can only reorder results. |
| Consent line | **"Sends your requests and file names to {destination}, never file contents."** On the AI Mode screen, in Settings and at the top of each thread. | One sentence says what is sent and to whom. |
| Claude | **No fallback model and no beta header.** | The person picked the model. |
| OpenAI's first model | **`gpt-6-astra`.** | It's the vendor's stated starting point, and one constant to change. |
| Model menu | **The model's name opens a menu of every connected provider's models, then AI Settings….** | Huseyn asked for it on 2026-11-14. |
| Version | **0.2.** The About line reads "An agentic file manager for your Mac." | Huseyn agreed to both on 2026-11-14. |

## Ruled but not built yet

The app works without these, but each ruling above is still owed. Row-level status is in [`P0_P1_STATUS.md`](P0_P1_STATUS.md).

| ID | What's left |
|---|---|
| OK2-22 | Settings has six panes, General, View, Appearance, Sidebar, Search and Advanced, not F-065's four. Huseyn asked on 2026-11-09 to arrange and hide sidebar rows "both by dragging and in settings", and that got a pane of its own. |
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
