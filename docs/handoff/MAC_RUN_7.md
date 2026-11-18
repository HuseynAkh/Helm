# Mac run 7

**Status: AI search waits long enough for a model that reasons and says what it's doing and why it failed. The onboarding restarts Helm as a step of its own and always has the AI Mode step, and the welcome window has room under Continue. Go to Folder starts with the path selected. Folders gain Open in Terminal and a Properties window that counts what's inside them, and the search's kind row was brought in line with the tab strip. All of it was checked on fixtures with invisible windows; see "Live on this Mac" for what was tried in the installed app. Nothing was pushed.**

Run on 2026-11-17 and 18, on `handoff/mac-fixups` after `23978dd`. Huseyn's words and the choices made for him are in [`OWNER_RULINGS.md`](OWNER_RULINGS.md#mac-run-7-2026-11-18); the AI search and onboarding rows are in the run 6 table, where they were first recorded.

## What Huseyn asked

- AI search "not working at all": find out why with his LM Studio and OpenAI connections, on a small test folder, without overusing them.
- The Full Disk Access step still asks for a restart, the AI Mode screen no longer appears, and the first onboarding screen's Continue sits on the window's bottom edge. Make restarts a standard step.
- Open in Terminal on every folder's right-click menu, opening that folder.
- A folder's Properties should show its size and Nautilus's other details.
- The search's kind row "looks kind of weird": padding in line with Helm's style.

## What was built

- **AI search.** A plan now has 60 seconds and each look 120 with a cloud model, or 120 and 180 with one on this Mac. Before, a model that reasons ran out of time and its looks were dropped without a word, so a search ended with no matches. The status bar says "Reading inside files…" and "Looking at 34 files…" while it works, and ends with "Couldn't look at 12: OpenAI took too long to answer", or the reason a plan failed. A file whose words hold the home folder's path is left out of its question, rather than the whole question.
- **Onboarding.** Once Full Disk Access is on, its step's button is **Restart Helm**, which keeps the next step, quits and reopens Helm; the next launch carries on there, as it does after macOS's own Quit & Reopen. Every onboarding has the AI Mode step. Each window is sized below its title bar, whose height changes with the SDK, so every step keeps 16 points under its buttons.
- **Go to Folder** (⌘L) starts with the path on show selected, so what's typed replaces it.
- **Open in Terminal** is on a folder's right-click menu, the empty space's (the folder on show), every folder row in the sidebar, each piece of the path bar, and File in the menu bar. Helm hands the folder to the app through macOS, as Finder's New Terminal at Folder does, so it runs no shell and types nothing. Settings › General › Terminal picks the app among the ones on this Mac that can open a folder; this Mac has Terminal and Ghostty.
- **Properties** is a window of its own. For a folder it counts everything inside, hidden files too, with running totals, and says which folders it couldn't read or that are in the cloud and not downloaded; counting never downloads anything. It shows the parent folder with a button to show the item there, the disk with its free space as the status bar words it, Created, Modified and Accessed, and the owner, group and others with what each can do. A file shows its size, MIME type, a picture's dimensions, the app that opens it and whether it runs as a program; an app shows everything inside it as its size; several items show how many of each and their size together. The owner is "You" for your own items, root for the system's and "Another account (ID 502)" for any other, since Helm reads no account's name: the binary privacy check refuses the call that would. Escape or ⌘W closes the window, and several can be open.
- **The kind row** is 36 points tall like the tab strip, with 13-point words, the chosen one a step heavier, 7-point corners and 4 points between choices, centred between the lines above and below it.

## Verified here

| Check | Result |
|---|---|
| `swift test` | See the end of the run |
| `static_checks.sh` and the privacy check | 0 errors and 0 problems, with nothing added to the allowed list |
| Script tests | 59 pass. Of 39, one fails: the README's path pictures, which are on the README branch that isn't merged yet |
| Smoke steps for this run | 51 checks for Properties, Open in Terminal and the kind row pass in a hidden fixture run: a folder of 8 items and 45 bytes with one folder it can't read, a file, an app, two items, two windows at once, Escape, the folder on show, and the terminal from a selected folder, the empty space, the sidebar and the menus, never from a file, two items or an app |
| The kind row, measured | At 2x, the chosen choice had 9 pixels above and 5 below; it now has 9 and 9 |

## Live on this Mac

To be filled in after the installed build is tried.

## Open

1. **The README branch** (`claude/modest-visvesvaraya-113d31`) is waiting for Huseyn's word to be merged. Until it is, the script test for the README's pictures fails here, since this branch's picture script already takes the path pictures.
2. **Permissions are shown, not changed.** Nautilus can change them from its Properties window. That would be a change to the disk, with Undo, and waits for Huseyn's word.
3. **From run 6:** Apple's readers inside Helm's process, and a folder swapped for a link between plan and Apply ([`MAC_RUN_6.md`](MAC_RUN_6.md#open)).

## Disclosures

- Fixture runs used made-up folders and invisible windows, and handed folders to a stand-in, so no terminal opened.
- The AI search findings came from `~/Helm Test`, a made-up home, with a handful of small requests.
