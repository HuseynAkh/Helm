# Mac run 7

**Status: AI search waits long enough for a model that reasons and says what it's doing and why it failed. The onboarding restarts Helm as a step of its own and always has the AI Mode step, and the welcome window has room under Continue. Go to Folder starts with the path selected. Folders gain Open in Terminal and a Properties window that counts what's inside them, and the search's kind row was brought in line with the tab strip. All of it was checked on fixtures with invisible windows; see "Live on this Mac" for what was tried in the installed app. Nothing was pushed.**

Run on 2026-11-17 and 18, on `handoff/mac-fixups` after `23978dd`. Huseyn's words and the choices made for him are in [`OWNER_RULINGS.md`](OWNER_RULINGS.md#mac-run-7-2026-11-18); the AI search and onboarding rows are in the run 6 table, where they were first recorded.

## What Huseyn asked

- AI search "not working at all": find out why with his LM Studio and OpenAI connections, on a small test folder, without overusing them.
- The Full Disk Access step still asks for a restart, the AI Mode screen no longer appears, and the first onboarding screen's Continue sits on the window's bottom edge. Make restarts a standard step.
- Open in Terminal on every folder's right-click menu, opening that folder; then, since his default terminal is Ghostty, follow the default and let others pick theirs in Settings.
- A folder's Properties should show its size and Nautilus's other details.
- The search's kind row "looks kind of weird": padding in line with Helm's style.

## What was built

- **AI search.** A plan now has 60 seconds and each look 120 with a cloud model, or 120 and 180 with one on this Mac. Before, a model that reasons ran out of time and its looks were dropped without a word, so a search ended with no matches. The status bar says "Reading inside files…" and "Looking at 34 files…" while it works, and ends with "Couldn't look at 12: OpenAI took too long to answer", or the reason a plan failed. A file whose words hold the home folder's path is left out of its question, rather than the whole question.
- **Onboarding.** Once Full Disk Access is on, its step's button is **Restart Helm**, which keeps the next step, quits and reopens Helm; the next launch carries on there, as it does after macOS's own Quit & Reopen. Every onboarding has the AI Mode step. Each window is sized below its title bar, whose height changes with the SDK, so every step keeps 16 points under its buttons.
- **Go to Folder** (⌘L) starts with the path on show selected, so what's typed replaces it.
- **Open in Terminal** is on a folder's right-click menu, the empty space's (the folder on show), every folder row in the sidebar, each piece of the path bar, and File in the menu bar. Helm hands the folder to the app through macOS, as Finder's New Terminal at Folder does, so it runs no shell and types nothing. It opens the Mac's default terminal: the first terminal other than Terminal that the Mac opens shell scripts or executables with, which on this Mac is Ghostty, or Terminal. Settings › General › Terminal lists "Default (Ghostty)" first, then each terminal on this Mac that can open a folder.
- **Properties** is a window of its own. For a folder it counts everything inside, hidden files too, with running totals, and says which folders it couldn't read or that are in the cloud and not downloaded; counting never downloads anything. It shows the parent folder with a button to show the item there, the disk with its free space as the status bar words it, Created, Modified and Accessed, and the owner, group and others with what each can do. A file shows its size, MIME type, a picture's dimensions, the app that opens it and whether it runs as a program; an app shows everything inside it as its size; several items show how many of each and their size together. The owner is "You" for your own items, root for the system's and "Another account (ID 502)" for any other, since Helm reads no account's name: the binary privacy check refuses the call that would. Escape or ⌘W closes the window, and several can be open.
- **AI search with a small model.** The plan's prompt says to leave kinds empty unless the person names one, since receipts, tickets, letters and forms are often photos or scans, and with the kind row at Any and no kind named, the plan's last query runs over every kind too. See "Live on this Mac" for why.
- **The kind row** is 36 points tall like the tab strip, with 13-point words, the chosen one a step heavier, 7-point corners and 4 points between choices, centred between the lines above and below it.

## Verified here

| Check | Result |
|---|---|
| `swift test` | 3,254 tests, 0 failures, 1 skipped, on `2910091`. The suites changed after it (Properties, Open in Terminal, settings, AI search) were run again and pass |
| `static_checks.sh` and the privacy check | 0 errors and 0 problems, with nothing added to the allowed list |
| Script tests | 59 pass. Of 39, one fails: the README's path pictures, which are on the README branch that isn't merged yet |
| Smoke steps for this run | 51 checks for Properties, Open in Terminal and the kind row pass in a hidden fixture run: a folder of 8 items and 45 bytes with one folder it can't read, a file, an app, two items, two windows at once, Escape, the folder on show, and the terminal from a selected folder, the empty space, the sidebar and the menus, never from a file, two items or an app |
| The kind row, measured | At 2x, the chosen choice had 9 pixels above and 5 below; it now has 9 and 9 |
| Full smoke, Debug | 2,349 checks passed. Two steps failed: `recent.txt` found Measured where it expected Documents, since the Properties steps had moved the tab, so they now run in a tab of their own; and `header-leading-is 84`, which passed on its own and in the Release run, as it has before when the Mac is busy. The three list-width failures of run 6 are gone, the main display being the Retina one again |
| Full smoke, Release build of `bd603c1` | 2,351 checks passed. The one failure is the known 14-point title-bar band ([`MAC_RUN_4.md`](MAC_RUN_4.md#open)) |
| `make_release.sh` and `check_binary_privacy.sh` | Every check passes. A first build failed it on `getpwuid`, which Properties used for owner names; it now reads none |

## Live on this Mac

Tried in the installed Release build of `232b5b7` (CDHash `da80f346…`), on the 1x external display, with Huseyn at the Mac.

| Check | Result |
|---|---|
| The welcome window | 540 × 592 with room under Continue; its list names Full Disk Access and AI Mode |
| The AI Mode step | There, between Full Disk Access and the end, showing AI mode on with LM Studio |
| Full Disk Access and the restart | Huseyn switched it on and Helm came back finished with setup at 01:19; Settings › General says it's on. Which button he used, Helm's Restart Helm or macOS's Quit & Reopen, wasn't seen |
| Go to Folder | The path came up selected in the field |
| File › Open in Terminal, and the empty space's menu | Both there. A real terminal wasn't opened, as it would come up in front of Huseyn |
| The kind row | Centred, lined up with the header's buttons |
| AI search, LM Studio `gpt-oss-20b`, Read contents on, "a receipt from a cafe" in `~/Helm Test` | Done in about a minute with "0 matches · PDF, Document, Text · Mentions “receipt”, “cafe” · Looked at 12". The status said what it looked for, but the model had kept the search to documents and the receipt is a photo; fixed as above, after this build, and the model's new plan was checked straight against LM Studio |
| AI search with OpenAI | Not run: the provider was LM Studio, from run 6's tests, and Settings' provider menu can't be opened from the background |

## Open

1. **The README branch** (`claude/modest-visvesvaraya-113d31`) is waiting for Huseyn's word to be merged. Until it is, the script test for the README's pictures fails here, since this branch's picture script already takes the path pictures.
2. **Permissions are shown, not changed.** Nautilus can change them from its Properties window. That would be a change to the disk, with Undo, and waits for Huseyn's word.
3. **From run 6:** Apple's readers inside Helm's process, and a folder swapped for a link between plan and Apply ([`MAC_RUN_6.md`](MAC_RUN_6.md#open)).

## Disclosures

- Fixture runs used made-up folders and invisible windows, and handed folders to a stand-in, so no terminal opened.
- The AI search findings came from `~/Helm Test`, a made-up home, with a handful of small requests.
