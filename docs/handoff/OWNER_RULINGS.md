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
| Logo | "Decide on a good logo." Then, on 2026-11-13: "I would not personally change the Helm logo, however." | 2026-11-12 and 13 | The app icon is unchanged. Helm's four-point spark, in amber, coral and violet, was the mark of AI mode until 2026-11-17, when Huseyn chose the trefoil (run 5, below). The banner is drawn by `scripts/readme/make_brand.swift`. No variant icon was made. |
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
| What is sent | **Names and details only. Reading inside files was not built in run 4; run 5 added Read contents, off until switched on.** | Contents never leave the Mac unless a person turns that on. |
| Folders | **The folder on show plus up to seven added ones, inside the home folder, `/Volumes` or the Shared folder. Added folders aren't saved.** | An allow list can't miss a system place or leave standing access. |
| Tools | **Three: list a folder, find items, propose changes. Items are named by ids Helm issues, never by path. Run 5 adds a fourth, read contents, offered only while Read contents is on.** | No path parsing and no escapes. |
| Plans | **Nothing changes until Apply. Trash, and changes that reach a place that syncs or is shared, start unticked. Conflicts keep both. No delete, no shell, no web tool. 1,000 changes at most.** | Nothing is destroyed or overwritten unseen. |
| Undo | **One Apply is one Undo. An undone plan can't be redone.** | A redo would run the plan again without Apply's checks. |
| Cloud folders | **Never download. Files that aren't downloaded are left out, with a count.** | A wrong guess then fails with nothing fetched (question 1 in `MAC_RUN_4.md`). |
| Panel | **A column 340 points wide by default, 300 to 560 when dragged, shut at every launch. Opening it hides the sidebar first, then widens the window if the files need room.** | The header and today's layout stay as they were. |
| Spark | **Opens the panel when a model is ready, and the AI Mode screen otherwise. Done on that screen opens the panel.** | One door for "not ready". |
| Commands | **`/add` and `/clear`. A path typed alone adds a folder. A server address gets one Connect line and goes to macOS.** | Two commands cover it, and macOS does the sign-in. |
| Suggestions | **Three, worked out on the Mac with no model: Organize, Move everything to…, Copy everything to…** | Huseyn's three examples, shown whenever the panel opens. |
| AI search | **Two model calls at most. The model plans searches, Helm runs them, and the reasons are facts Helm writes, shown as each result's tooltip.** | A hostile file name can only reorder results. |
| Consent line | **"Sends your requests and file names to {destination}, never file contents."** On the AI Mode screen, in Settings and at the top of each thread. Run 5 adds the Whole Mac and Read contents lines. | One sentence says what is sent and to whom. |
| Claude | **No fallback model and no beta header.** | The person picked the model. |
| OpenAI's first model | **`gpt-6-astra`.** | It's the vendor's stated starting point, and one constant to change. |
| Model menu | **The model's name opens a menu of every connected provider's models, then AI Settings….** | Huseyn asked for it on 2026-11-14. |
| Version | **0.2.** The About line reads "An agentic file manager for your Mac." | Huseyn agreed to both on 2026-11-14. |

## AI mode, Mac run 5 (2026-11-15 to 17)

What was built and checked is in [`MAC_RUN_5.md`](MAC_RUN_5.md).

### Rulings by Huseyn

| Topic | Huseyn's words | Date | What was built |
|---|---|---|---|
| Push and reinstall | "Reinstall Helm and erase all cache on my computer. You can also push it to GitHub now / merge" | 2026-11-15 | `handoff/mac-fixups` was pushed at 0fc297b and merged into `main` as PR #4. The 0.2 build was reinstalled. |
| Reset | "Yes, reset to fresh" | 2026-11-15 | Helm's settings, saved state and keychain items went to the Trash or were deleted, and the file viewer and the Dock went back to Finder, so the next launch was a first run. |
| ChatGPT sign-in | "Got stuck on page not loading after confirming everything on the site of ChatGPT on ChatGPT sign-in." | 2026-11-15 | The sign-in listener now reads each browser connection as a blocking read with a time limit, so a browser that sends its request a moment after connecting is answered. |
| Suggestions make plans | "Also fix this issue." (a screenshot of Organize answered with a description) | 2026-11-15 | A request that asks for changes and gets words alone asks the model once more for the plan. |
| Whole Mac | "I think when you're in AI sidebar mode, there should also be a toggle for "This folder only" or "Whole system". When it's "Whole system", it should be able to look at your entire system and decide if these files even belong in this folder or should go somewhere else." | 2026-11-15 | A This Folder / Whole Mac switch at the end of the panel's folders row. Whole Mac adds the home folder, iCloud Drive, cloud folders and mounted disks. System folders, Library and other apps' data stay out. |
| Destination path | "You can keep the UI for moving similar, but also include the URL path that would be moved to under the name or something like that." | 2026-11-15 | Each group of a plan shows the folder it goes to, from `~`, shortened in the middle when long. |
| Hold and list | "yes let's hold till after, let's keep a list of things to build." | 2026-11-15 | The list was kept in [`NEXT.md`](NEXT.md) and built on 2026-11-17. |
| Read contents | "Also we want to make sure that the search tool and sidebar can read and open file contents (so maybe that's the toggle name instead). e.g. search by images, video content, etc." | 2026-11-15 | A Read contents switch in the panel and in AI search. Helm reads text, PDFs, pictures and video frames on this Mac and gives the model short summaries, never the files. Speech in video is not read. The consent wording waits for Huseyn (below). |
| File type in AI search | "Also when using ai search makes you choose file type (Photo, Video, Document, Folder, Code, [other 1-2])" | 2026-11-15 | A row under the header while AI search is on: Any, Photo, Video, Document, Folder, Code, Audio and Archive. |
| Panel resize and style | "Also, you can't properly adjust the sizing of the AI sidebar. I would investigate and try to fix that. Overall, we would want to upgrade the style of the sidebar. Right now, it feels very code-ask. I want to make it feel more Apple-esque and better fitting for Nautilus UI too. It feels kind of dark and like a code editor." | 2026-11-15 | The edge takes every press along it now; the thread's view had covered it. The panel sits on the sidebar's own material, with native type, soft bubbles and grouped plan cards, in light and dark. |
| AI mark | "we wanted the AI logo to look more like the Apple Intelligence logo (attached). (no background though) Explore the different logos we can design for this and suggest them." Then, choosing from four drawn options: "D, Trefoil knot" | 2026-11-15 and 17 | The trefoil, one line in amber, coral and violet that loops three times over and under itself, drawn by `SparkMark.swift`. It replaced the four-point spark in the header, the search field, the panel, the AI Mode screen, Settings, the banner and every picture. The app icon is unchanged. |
| Start | "You can start this now, parallelize as necessary. we can do the logos / ai mark first while I'm awake" | 2026-11-17 | All six items of the list were built that night. |
| Finder in the Dock | "Is there a way to hide Finder from Doc that can be done in app here? We definitely want to have the ability to restore that as necessary." | 2026-11-17 | Not built: macOS keeps Finder in the Dock, and no app can take it out. Helm's own option puts Helm first in the Dock, and `--dock-first off` puts it back. |
| Onboarding | "on first launch, after the app is installed and you enable full disk access, the quit and reopen dialog pops up. And I think the app tries to quit and reopen itself, which creates a weird behavior. And also the AI mode pops up as a pop-up with the actual file manager already open. We would probably want to continue onboarding and make it clear that AI mode is part of the Finder onboarding rather than presenting everything at the same time." | 2026-11-17 | One window, step by step: Welcome, Full Disk Access, Default File Viewer, AI Mode, You're All Set. macOS's Quit & Reopen no longer ends it: the next launch carries on at the next step. The file window opens only at the end, and no AI pop-up follows. |
| README | "Make sure the redesign of the README is complete and descriptions are updated as necessary, keeping the information tidy and correct. Additionally, make sure the banner at the top of the README has a newer, updated, and improved design, and that everything looks premium throughout rather than cheap. Update images as necessary, and styles in line with our new AI logo." | 2026-11-17 | A new banner with the unchanged icon and the trefoil, every picture retaken from the current app, and the text checked against the code. |

### Waiting for Huseyn

| Question | Default used |
|---|---|
| The consent line while Read contents is on. Today's promise says "never file contents". | Replaced in run 6, after Huseyn asked whether the run 5 wording was true. Huseyn approved the new wording; it is under [run 6](#the-consent-wording-run-6). |

### Delegated choices in run 5

Huseyn can overrule any of these. Each one's reason is in its last column.

| Topic | Choice | Why |
|---|---|---|
| Whole Mac's places | **The home folder, iCloud Drive, each folder in `~/Library/CloudStorage` and each mounted disk, under the same folder rules as a folder you name. Every new thread starts in This Folder.** | The model can see where files belong without system folders, Library or other apps' data. |
| Whole Mac's consent line | **"Sends your requests and file names from your home folder and disks to {destination}, never file contents."** | The line says what is sent and from where, disks included. |
| Read contents | **Off for every new thread and search. Turning it on or off starts the thread over.** | Contents are read only after a person asks, and a thread never mixes the two promises. |
| What is read | **Text, RTF, PDFs (PDFKit), pictures (Vision: text and what they show) and sampled video frames (AVFoundation), four files at a time, within a time limit. Never a file that isn't downloaded, a link, a folder, a package or a key file.** | Apple's frameworks on this Mac; nothing is fetched and nothing secret is read. |
| What the model gets | **Short summaries, escaped, with the home folder written as `~`, marked as untrusted data.** | A file's text can't pass for an instruction. |
| AI search with Read contents | **Up to 200 pictures and videos per search, kept for that search by path and date. Each result says what was seen.** | It stays quick, and the reason is a fact Helm wrote. |
| File type row | **One kind at a time, Any by default. It goes back to Any when the search closes.** | A search is never narrowed by a choice made earlier. |
| The mark's weight | **The trefoil's line is about 1 point at 10 points, 1.45 at the header's 18, and a little over 6 % from 64 up.** | It stays open and crisp at every size. |
| Onboarding's place | **Saved at every step in `helm.setupProgress`. Get Started or closing the window finishes it.** | Any quit, macOS's included, comes back to the same place. |
| The Dock | **Restarted on the Default File Viewer step, not while System Settings opens.** | Helm's tile no longer blinks as if Helm restarted. |
| The separate AI Mode screen | **Shown once, after the window, only to people who set Helm up before AI mode. The mark still opens it when no model is ready.** | New people meet AI mode inside the onboarding. |

## AI mode, Mac run 6 (2026-11-17)

What was built and checked is in [`MAC_RUN_6.md`](MAC_RUN_6.md).

### Rulings by Huseyn

| Topic | Huseyn's words | Date | What was built |
|---|---|---|---|
| The consent wording | "Regarding your wording, check if that's actually true and if that is the best way to word this and talk about it. I would want us to give enough information and point out that no metadata is collected by us, if that's the case correctly." | 2026-11-17 | The run 5 line said "short summaries", which stopped being true once the model looks at pictures. Each line now names what goes: text, and small copies of pictures and video frames. Settings and the onboarding say "Helm has no servers and collects nothing", which is true: Helm has no server, no analytics and no crash reporting, and `scripts/privacy_check.py` fails the build on any of them. Huseyn approved it the same day (below). |
| The model looks inside files | "For the cloud providers, I'm surprised that it says sends your request file names and short summaries of file contents, as we wanted AI search to actually be able to find specific images from the directories that it's searching. … The AI models have to be able to read the local documents and identify what is being searched for, and the README should reflect that accordingly. That's image analysis, document analysis, and maybe even video analysis." | 2026-11-17 | With Read contents on, the model gets a small copy of each picture, of sampled video frames and of a scanned PDF's first page, and the text of text files, PDFs, RTF and Word files. AI search has the model look at the best candidates and keeps the ones it says fit. The README says so. |
| File type in the plain search | "And we would probably want the option of identifying what document you're searching for as well in the file manager search." | 2026-11-17 | The kind row shows whenever the search is open, AI or not, and keeps a plain search to that kind. The status bar names it. |
| The panel as a local harness | "One more thing I want to make sure that if you're using a sidebar chat in the directory with an AI model, it can almost act as a local harness. So you can tell it to create files, folders, different documents on request, and it can work in your directory to do that. No need to overbuild crazy harness logic. However, for basic functionality, we definitely want that to be the case. And it should support general operations on the directory and the general AI functions of creating documents, files, and so forth. Make sure you're not overbloating this. And that it can work with the different models supported." | 2026-11-17 | A plan can now make new files with the model's text, beside the folders, moves, copies, renames and Trash it could already do. It's one more list in the same plan, so every provider can do it, and Apply and Undo work as before. |
| Push and merge | "You're free to merge and push after all of these changes, but make sure you review everything for security and private data. Make sure everything is secure and in accordance." | 2026-11-17 | A security review and a private-data scan ran on the whole change. What they found was fixed before the push, apart from two items in [`MAC_RUN_6.md`](MAC_RUN_6.md#open). |
| AI search not working | "Also AI search functionality not working at all. Search is broken ... Choose a directory to test this in and run tests to fix. You can use my LM studio models and openai models that are already connected, just make sure you're not abusing it and running this on smaller local tests to make sure the filters and search functionality works." | 2026-11-17 | Tested in `~/Helm Test`, a made-up home made by `scripts/readme/make_demo_home.swift`. The plain search and the kind row worked. AI search with Read contents found the café receipt through the ChatGPT plan, but took about two minutes with only "Thinking…" on show. Each look question had 30 seconds, and the plan 20, which a model that reasons can pass, and a question that failed was dropped without a word. Now a plan has 60 seconds and a look 120 (120 and 180 on this Mac), the status bar says "Reading inside files…" and "Looking at 34 files…", and it ends with "Couldn't look at 12: OpenAI took too long to answer" or the reason a plan failed. A file whose words hold the home folder's path is left out of its question rather than the whole question. |
| Wording approved | "approve wording and push" | 2026-11-17 | The consent lines below stand as they shipped in PR #5. This record of his approval was pushed. |
| Onboarding: restart, AI step, layout | "the Full Disk access prompt on Macos still asks to restart the app and the AI mode screen doesn't appear now ... Also the very first onboarding screen didn't scale well with the "continue" button being at the very bottom edge of the box / app display. Since full disk access always asks to restart the mac (and you seem to get disk access without a restart) maybe we just standardize restarts in the flow to make it better adapted." | 2026-11-17 | The restart is a step of the flow: once Full Disk Access is on, its step stays and its button is **Restart Helm**, which keeps the next step, quits and reopens Helm, and the next launch carries on there, as after macOS's own Quit & Reopen. Every onboarding has the AI Mode step, showing AI mode as it stands, so someone who set it up just clicks Continue; AI mode alone, once seen, still doesn't open an onboarding by itself. The window is now sized below its title bar, whose height changes with the SDK, so every step keeps 16 points under its buttons; a smoke step and a window test check it on every step, the guide and the AI Mode screen. |

### The consent wording (run 6)

Approved by Huseyn on 2026-11-17.

| Lines | Wording |
|---|---|
| The consent lines while Read contents is on | Settings and the onboarding: "Sends your requests and file names to {destination}; file contents only while Read contents is on. Helm has no servers and collects nothing." A thread with a model on this Mac: "Reads text, pictures and video frames inside files on this Mac; nothing leaves your Mac." With any other model: "Sends your requests, file names and what it reads inside files to {destination}: text, and small copies of pictures and video frames." AI search's hint: "Return sends your words, file names and the contents of files the model looks at to {destination}." With Whole Mac, the lines add "from your home folder and disks". |

### Delegated choices in run 6

Huseyn can overrule any of these. Each one's reason is in its last column.

| Topic | Choice | Why |
|---|---|---|
| The pictures a model gets | **A JPEG made on this Mac, 512 pixels on its longer side at quality 0.7, with no location, camera, date or other metadata. Helm reads each one back and doesn't send it if any metadata is left. A picture of more than 100 megapixels isn't read.** | Small enough to send quickly, big enough to recognize what's in it, and nothing about where or when it was taken goes with it. |
| Videos | **The 3 frames Helm already samples, or 5 for half a minute or more, each as such a JPEG. Speech isn't read.** | Enough to tell what a video shows without sending the video. |
| Documents | **Text, Markdown, RTF, PDFs, .docx and .odt, by their first characters. A .docx or .odt is checked before it's unpacked and refused if it would unpack to more than 16 MB. Old .doc files aren't read.** | Word files are read without running anything in them, and the old format's reader isn't worth the risk. |
| A model that can't take pictures | **Helm asks once more without pictures and stops sending them for that thread or search. Apple's on-device labels and text are in every summary.** | Local and older models still work. |
| AI search's look | **The model looks at the best 48 candidates with a cloud model and 12 with a model on this Mac, 12 per question. Across the whole Mac it looks only at files the search or the on-device labels matched. Code only when you choose Code, and settings files such as JSON or YAML only with Code or Document.** | It finds the photo you mean without sending unrelated files, and code and settings go only when asked for. |
| A result's reason | **"Model saw: …", with the model's words.** | The reason says it's the model's reading, not Helm's. |
| Secret files | **Names with a word such as secret, token, password or credentials, and env, netrc, Terraform state and service account files, are never read for a model and never shown in AI search.** | What's inside files that hold logins never reaches a model, at the cost of hiding a few ordinary files with those words in their names. |
| New files | **Up to 20 per plan, 100,000 characters each and 500,000 in all, as plain text, Markdown, CSV, JSON, YAML, HTML, code, RTF or Word. Code and web pages start unticked, and so does any new file where others see it. Scripts Windows runs on a double click, files that run on a routine command such as `package.json` or `setup.py`, and names Windows keeps for devices are refused.** | The panel can write a document for you, and a file that would run something is never made without a look. |
| The kind row | **It shows whenever the search is open. Each tab keeps its search's kind, and it goes back to Any when the search closes. The status bar ends with the kind.** | It works the same with AI mode on or off, and a search is never narrowed by a choice made earlier. |

## Mac run 7 (2026-11-18)

What was built and checked is in [`MAC_RUN_7.md`](MAC_RUN_7.md).

### Rulings by Huseyn

| Topic | Huseyn's words | Date | What was built |
|---|---|---|---|
| Open in Terminal | "can you add an option to right click open in terminal for all folders? So the terminal opens the existing folder." | 2026-11-18 | **Open in Terminal** on a folder's right-click menu, the empty space's (the folder on show), every folder row in the sidebar, each piece of the path bar, and File in the menu bar. Helm hands the folder to the terminal app through macOS, as Finder's New Terminal at Folder does, so it runs no shell and types nothing. |
| Folder Properties | "Also fix right click properties of folder (should show file size, other nautilus features etc.)" | 2026-11-18 | Properties is a window of its own, as in Nautilus. For a folder it counts what's inside, hidden files too, with running totals ("1,204 items, totalling 2.1 GB so far"), and says which folders it couldn't read or are in the cloud and not downloaded. It shows the parent folder with a button to show the item there, the disk with its free space, Created, Modified and Accessed, and the owner, group and others with what each can do, in Nautilus's words. A file shows its size, MIME type, dimensions for a picture, the app that opens it and whether it runs as a program. Before, a folder's size said "Calculating contents size" forever and the permission rows said "Unavailable". |
| The default terminal | "my default terminal app is ghostty, add a setting to change this for others" | 2026-11-18 | Open in Terminal starts on **Default**, the Mac's default terminal. macOS keeps no one setting for that, so it's the first terminal other than Terminal that the Mac opens shell scripts or executables with; on Huseyn's Mac `.sh` files open in Ghostty, so it's Ghostty. Settings › General › Terminal lists "Default (Ghostty)" first, then each terminal on the Mac that can open a folder. |
| AI search with a model on this Mac | (from "make sure the filters and search functionality works", 2026-11-17) | 2026-11-18 | Tried live in `~/Helm Test` with LM Studio's `gpt-oss-20b`: "a receipt from a cafe" ended with "0 matches · PDF, Document, Text · Looked at 12" in about a minute, because the model planned documents only and the receipt is a photo. The plan's prompt now says to leave kinds empty unless the person names one, since a receipt, a ticket, a letter or a form can be a photo or a scan; asked again, the same model left them empty, in 2 seconds rather than 29. And with the kind row at Any and no kind named, the plan's last query runs over every kind too. |
| Image testing in AI mode | "Make sure you do extensive image testing for AI mode. I find that to be one of the main functionalities missing." And: "You can also use the OpenAI one, as I indicated before. The subscription for small localized tests in a folder." He also allowed one vision model to be downloaded in LM Studio. | 2026-11-18 | A folder of real photos, `~/Helm Test/Pictures/Image Tests`, from macOS's own sample pictures under camera-style names, with a photo stored on its side with a location, a transparent PNG and a 48-megapixel JPEG. Searched with OpenAI through his ChatGPT plan, a few minutes apart; the results are in [`MAC_RUN_7.md`](MAC_RUN_7.md#image-testing). It found that LM Studio's text-only models were sent pictures they dropped without a word, so Helm now sends such a model none and says so in Settings › AI. |
| The Settings › AI window | "Do you see the bug currently happening on your screen with the extended drop-down menu on the AI tab? We should fix that. Not sure what causes it." | 2026-11-18 | Three causes, all fixed: fixed pane heights measured with an older SDK, too short in a Release build; a window that shrinks keeping its forms' bottom edge, so a pane opened after General came up scrolled under the toolbar; and an animated resize that Settings › AI started again as its model loaded. |
| The kind row | "also this bar looks kind of weird, improve padding etc in line with our style" | 2026-11-18 | The row now matches the tab strip, the other row under the header: 36 points tall, 13-point words with the chosen one a step heavier, 7-point corners and 4 points between choices. The choices are centred between the lines above and below the row; before, the chosen one sat 2 points nearer the bottom line. |
| The keychain and a search's time | "Yes, fix it" (to "Fix the search timer so a keychain question doesn't count as a slow ChatGPT?") | 2026-11-18 | A model client reads its key or ChatGPT sign-in first, and a search question's time, or the AI panel's request's, starts after macOS's keychain question is answered. A refusal ends it as the keychain's refusal, with nothing sent. |
| PDF and video search, and the push | "Also confirm that you have also tested PDF search and video search. Make sure that is tested, and if everything passes, push all to the main branch and make sure it's finished." | 2026-11-18 | Searched live with OpenAI and LM Studio: the lightning video, a lease renewal and an invoice that only their scans' words name ([`MAC_RUN_7.md`](MAC_RUN_7.md#pdf-and-video-search)). "All" was taken to take in the README branch, the one decision then waiting on him. Pushed and merged to main. |
| A fresh install | "After all tests pass and if everything works rebuild my Helm with all cache cleared so I get a fresh install experience (having to turn on AI again etc)". Asked what to clear: "Everything (Recommended)"; asked about the default viewer: "Restore Finder first (Recommended)". | 2026-11-18 | Built clean and installed with Helm's data, preferences and keychain items gone and Finder the file viewer again; the details are under "Left installed" in [`MAC_RUN_7.md`](MAC_RUN_7.md#left-installed). |

### Delegated choices in run 7

Huseyn can overrule any of these. Each one's reason is in its last column.

| Topic | Choice | Why |
|---|---|---|
| Which terminals | **The list holds the ones on this Mac that macOS says can open a folder, among Terminal, Ghostty, iTerm, Warp, WezTerm and kitty. If the chosen one is removed, Helm uses Terminal.** | The menu item keeps Nautilus's name whichever app it opens. |
| Where it's offered | **One folder, selected or on show. Not on files, several items, apps and other packages, Recent or the Trash.** | It's what Nautilus offers, and a terminal can only start in one folder. |
| Properties as a window | **A window beside the browser window, several at once, closed with Escape or ⌘W, instead of a sheet over the window.** | Counting a big folder takes time, and a sheet would hold the window up meanwhile. Nautilus opens a window too. |
| What counts | **Every file and folder inside, hidden ones too. An app or other package counts as one item, with all its bytes. Links count as items and aren't followed. Sizes are as each file says, as Finder's Size is.** | Nautilus counts hidden files too, and on a Mac an app is one thing. |
| A model that can't see pictures | **Where the provider says so, as LM Studio does with "llm", Helm sends that model no pictures, only Apple's descriptions of them, and Settings › AI says under the model "Reads text only". Other providers say nothing, so their models get pictures and Helm still asks again without them if one is turned away.** | LM Studio took pictures for gpt-oss-20b and dropped them silently, so "Model saw:" was wrong and every look made pictures for nothing. |
| Permissions | **Changed in Properties for your own items, as in Finder's Get Info and Nautilus's Permissions page: "Read & Write", "Read only" or "No access" for you, the group and others (with execute for a folder; a file keeps its own), and "Allow executing file as program" for a file. Bits that match none show "Custom". A change applies at once and is one Undo, there or in the browser window: "Undo Change Permissions". Another account's or root's items, and links, are only shown: "Shown as macOS keeps them. Only the owner can change these." Locked items and read-only disks say why they can't change. Nothing inside a folder changes: no "Apply to enclosed items".** | On a Mac only an item's owner can change it without an administrator's password, and Helm never asks for one. Each change is checked against the item and mode it was asked about and read back from the disk, so the window shows what the disk keeps. Changing everything inside a folder is a bulk change, left for later. |
| The owner's name | **"You" for your own items, root for the system's, and "Another account (ID 502)" for any other.** | Helm reads no account's name, which its privacy checks hold it to, so Nautilus's owner names would mean loosening that promise. |

## Mac run 8 (2026-11-18)

What was built and checked is in [`MAC_RUN_8.md`](MAC_RUN_8.md).

### Rulings by Huseyn

| Topic | Huseyn's words | Date | What was built |
|---|---|---|---|
| Full Disk Access off | "This screen should have something red near "Full Disk Accesses Off," like a red X, so that people can see that they need to do something rather than press and continue." | 2026-11-18 | A red ✕ where the green check goes once access is on, on the onboarding's Full Disk Access step and in the guide. |
| The onboarding after a quit | "When full disk access is granted and you hit quit and reopen auto mac dialogue (not inside helm), it skips the onboarding. Make sure that when helm is opened again after that it continues onboarding flow instead of going to the default file manager view. We have talked about this bug multiple times now. Fix it. Onboarding flow should be maintained after quiting / force quitting" | 2026-11-18 | Only the person's own close or Get Started counts as going through the onboarding. From the moment Helm is asked to quit, by the person or by macOS's Quit & Reopen, nothing the window does counts, so the next launch carries on at the step it reached; a force quit runs no code, and the step is kept as each one opens. |
| Organize | "Also organize isn't a drop down, remove drop down symbol and get rid of the move and copy buttons, users can command it themselves" | 2026-11-18 | The panel's one suggestion is a plain Organize button, for the folder on show or the items selected. Its depth menu and the Move and Copy suggestions are gone; asking to move or copy in the composer works as before. |
| A disk that stops answering | "Decide what is best here. Maybe even hybrid, up to you for user UX." | 2026-11-18 | Hybrid: a read that macOS holds shuts only the folder it was reading, and the disk is shut as before only when reads stall in two places at once or the disk itself looks stuck. A search leaves out a folder inside that doesn't answer, and AI search says the disk didn't answer rather than "0 matches". |
| A vision model on this Mac | "Qwen download finished" | 2026-11-18 | Tested with Qwen2.5-VL 7B in LM Studio. A model on this Mac that sees pictures now looks at 24 files, 4 and at most 6 pictures a question, so a question fits LM Studio's 4,096 tokens, and a lone letter such as "a" is no word to look for. |
| Permissions | "Decide what is best here, should replicate Finder / Nautilus behaviour and be stable" | 2026-11-18 | See "Permissions" under the delegated choices of run 7, whose row describes what was built: Finder's Read & Write, Read only and No access for your own items, Nautilus's "Allow executing file as program", each change one Undo. |
| A fresh install | "Reinstall / clear helm cache again" | 2026-11-18 | Done as the fresh install of run 7, with Huseyn's earlier "Everything" and "Restore Finder first": the details are under "Left installed" in [`MAC_RUN_8.md`](MAC_RUN_8.md#left-installed). |

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
