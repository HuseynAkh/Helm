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

## Overnight, 18 November

At Huseyn's word ("you can install the build right now as well. Make sure you do extensive image testing for AI mode"), with OpenAI through his ChatGPT plan for small searches in one folder. He also said yes to one vision model for LM Studio (Qwen2.5-VL 7B); its download stopped at 98.65% and three tries later still sat at 0%, so LM Studio was tested with gpt-oss-20b, which reads text only.

### What was built

- **Settings › AI, cut off under the toolbar.** Four causes, all fixed. Each pane had a fixed height measured with SDK 14, and a Release build's rows are taller, so General, View, Search, Advanced and AI were a little short; each pane is now as tall as its form, measured as it's drawn. A window that shrinks keeps its forms' bottom edge where it was, so a pane opened after General came up scrolled with its top under the toolbar; a pane that fits now goes back to its top. And the window animated its size while Settings › AI fitted itself again as its model loaded, which is what left the frosted area below it; it now changes size at once. The fourth was the frosted band Huseyn saw over the AI mode row and its note, with a line through the note: on macOS 26 AppKit draws an edge where a scroll view meets the toolbar, and a pane that crossfaded in kept that edge, a toolbar's height tall, inside its own top until the window closed. Panes now change without the crossfade. A fixture step checks every pane on Debug and Release: all it holds in view, at its top, and no edge inside it.
- **LM Studio planned searches that found nothing.** Live, "a bird" with gpt-oss-20b found none of the four bird photos and looked at nothing. Asked for its plan with a `response_format`, strict or not, LM Studio has gpt-oss answer at once without thinking, and the plan is junk: words nobody typed, dates such as "202-???", or no searches. Told the shape of the answer at the end of its instructions instead, it thinks for 13 to 21 seconds and plans what was asked, the word "bird" inside pictures. LM Studio now gets the shape that way; every other provider is as before.
- **AI search's hint** names the provider chosen as soon as it's chosen, rather than the one before until the search is opened again.
- **Models that can't see pictures.** LM Studio took pictures sent to gpt-oss-20b, a text-only model, and dropped them without a word, so results said "Model saw" of pictures it never saw. Helm now lists LM Studio's models from LM Studio's own list, which names each one a vision model or not, and sends a text-only model Apple's description of each picture instead, from the first look and the panel's first request. Settings › AI says under the model "Sees pictures" or "Reads text only".
- **Videos are described all the way through.** A video's labels were cut to the five most certain of all its frames, so a clip that changes scene was described by one frame. Each frame now keeps its own five, up to twelve for the video.
- **The kind row with the AI panel open.** The narrower row put the Read contents switch on top of Archive; where there's no room for its words it now shows its symbol alone.
- **A search that stayed on "Thinking…" for good.** With gpt-oss's better plans came queries of folder words alone, the name of the folder searched. Spotlight can't check those, so Helm asked it a predicate that is just false; Spotlight throws on one ("Unknown kind of NSPredicate … (FALSEPREDICATE)"), and the exception ended the search without a word, and kept Helm from quitting. Such a query is no longer asked of Spotlight, and a test starts a real Spotlight query with every kind of predicate Helm builds. Fixture runs answer the fan-out with a stand-in, which is why none met it. The plan's instructions also say a folder word is never the name of the place searched.
- **Small models' plans that never read a picture.** gpt-oss planned "a bird" two ways, and neither read a photo: "bird" in the name and inside the file in every query (choosing what to read kept the name, so only a file named for a bird would be read), or "bird" in the name alone (Read contents had nothing to look for). A name word that repeats a word looked for inside is now left out when choosing what to read, and with Read contents on a plan of names alone gets one more query that looks inside files for the person's own words. A window test runs both plans through a local, text-only model and reads the pictures each time.

### Image testing

`~/Helm Test/Pictures/Image Tests` holds 20 of macOS's own sample photos (animals, flowers, instruments, sports, nature, food) renamed `IMG_3001.HEIC` and on, so no name gives a photo away, plus a zebra stored on its side with orientation 6 and a made-up location, a guitar on transparency (`Untitled 2.png`), a 48-megapixel sunflower (`DSC09981.JPG`) and an 8-second video of a penguin then lightning (`MOV_0412.MOV`).

What Apple's on-device recognition says of them, as Helm reads them: confident and right for the eagle, owl, penguin, zebra, sunflower, rose, violin, guitar and lightning; nothing at all for the parrot, lotus and daisy; and wrong for the cactus (an ant), the snowflake (a jellyfish) and the fortune cookie (a bagel). So a model that can't see pictures misses those, and one that can finds them.

Live, in the installed app, with OpenAI (`gpt-6.2-sol` through the ChatGPT plan), Read contents on, a few minutes apart:

| Request | Expected | Found |
|---|---|---|
| a bird | eagle, owl, parrot, penguin | the four, the parrot included |
| flowers | the five flowers, the 48-megapixel one included | the five |
| a striped animal | both zebras | both, the one stored on its side included |
| a string instrument | guitar, violin, the guitar PNG | those three |
| a ball used in sports | basketball, soccer, tennis | "ChatGPT is busy, so try again in a moment." the first time; the three, 15 minutes later |
| something sweet to eat | gingerbread man, fortune cookie | both, the "bagel" included |
| a plant that grows in the desert | cactus | the cactus, the "ant" |
| AI panel: what does IMG_3021.JPG show, and is it upright? | a zebra, upright | "a close-up of a zebra in profile, facing right, with golden grass and blue sky behind it. The picture is upright." |
| AI panel: make a Birds folder and move every photo of a bird into it | the four birds | a plan moving exactly those four; Apply moved them, Undo put them back |
| Video kind: a storm with lightning | the video | nothing, and nothing looked at: the click meant for Read contents most likely landed on the kind row, under the switch that sat on Archive (fixed above) |

Each search took about a minute, said "Reading inside files…" and "Looking at 23 files…" while it worked, and ended with its count, what it looked for and "Looked at 23".

Then with LM Studio's `gpt-oss-20b` (text only), on each build as it was fixed, in the same folder: no plan read a photo until the fixes above, and on the last build, `d8840d7`, the search ended "0 matches" with nothing read even so. Printing what the search did showed why: the walk of the folder failed at once with "timed out". Each new build is a new signature, so Full Disk Access was off, and macOS asked, through `sandboxd`, whether Helm may see Documents; nobody was there to answer, a read waited on the question, and after 30 seconds Helm took the whole disk as not responding. The home window said so: the disk holding the home folder "isn't responding". Every read on it fails until the question is answered, so AI search walked nothing. The same walk, run outside the app, finds all 24 files, and Apple's reader reads them in under half a second, the eagle as "bird". So the last live check of LM Studio waits for Full Disk Access.

Tested on this Mac with real photos, in `AgentRealPictureTests`: a model's copy of a picture is at most 512 pixels a side with no metadata; a photo stored on its side arrives upright, without its location; transparency is drawn on white; a 48-megapixel photo is read and scaled down; and a clip that changes scene is described all the way through.

### Morning retest, with Full Disk Access on

Huseyn turned Full Disk Access on for `d8840d7` in the morning. Settings › General then said "Full Disk Access is on", and the home window listed its 24 items with no word of a disk not responding. In the same folder, with Read contents on, on the installed build:

| Provider | Request | Expected | Found |
|---|---|---|---|
| LM Studio, `gpt-oss-20b` (text only) | a bird | eagle, owl, penguin; the parrot only for a model that sees, since Apple's reader says nothing of it | in about a minute, the eagle, owl and penguin and the penguin video: "4 matches · Image · “bird” · Looked at 12", from three queries, "bird" in pictures, in images and in any file |
| LM Studio, `gpt-oss-20b` | Video kind: a storm with lightning | the video | the video: "1 match · “storm”, “lightning” · Mentions “storm”, “lightning” · Videos · Looked at 1" |
| OpenAI, `gpt-6.2-sol` (ChatGPT plan) | a bird | eagle, owl, parrot, penguin | the first time, "ChatGPT took too long to answer.": the new build's first ChatGPT request waited on macOS's keychain question until Huseyn answered it (open item 6). Asked again, the four, the parrot included, and the penguin video: "5 matches · “bird” · Mentions “bird” · Looked at 24" |

A model on this Mac looks at 12 files in one search and a hosted one at 48 (`AgentContentLimits.searchLooks`), so "Looked at 12" is as built. So LM Studio's search now plans, reads and finds what Apple's reader can name, and the parrot waits for a local model that sees pictures (open item 5). OpenAI's search finds every bird on this build, as it did on `232b5b7` overnight.

### Left installed

`/Applications/Helm.app` is `d8840d7` (CDHash `e811f7f8…`), still the default file viewer, with Full Disk Access on, the keychain question for the ChatGPT sign-in answered, and AI search's provider set back to OpenAI (`ai.json` as it was before the retest). Nothing was pushed.

## Open

1. **The README branch** (`claude/modest-visvesvaraya-113d31`) is waiting for Huseyn's word to be merged. Until it is, the script test for the README's pictures fails here, since this branch's picture script already takes the path pictures.
2. **Permissions are shown, not changed.** Nautilus can change them from its Properties window. That would be a change to the disk, with Undo, and waits for Huseyn's word.
3. **From run 6:** Apple's readers inside Helm's process, and a folder swapped for a link between plan and Apply ([`MAC_RUN_6.md`](MAC_RUN_6.md#open)).
4. **One unanswered macOS question takes the whole disk.** Without Full Disk Access, a read that waits on macOS's question about Documents is timed out after 30 seconds, and the I/O executor (B-107) then fails every read on that disk until the question is answered: the home window says the disk isn't responding, and AI search says "0 matches" rather than why. Three things would help, each a change to how Helm reads the disk: not looking inside Desktop, Documents and Downloads before the person opens them; a timed-out read shutting only the folder it waited on; and AI search saying the disk didn't answer. They wait for Huseyn's word. With Full Disk Access on, as after the morning retest, it doesn't arise.
5. **The vision model.** Qwen2.5-VL 7B never finished downloading in LM Studio (stopped at 98.65%, then 0% three times), so a local model that sees pictures is untested. LM Studio's Downloads may still hold the stalled download.
6. **A keychain question counts as a slow ChatGPT.** An AI search question's time limit (`AISearchSession.answer`) starts before the client reads the ChatGPT sign-in from the keychain (`AgentChatGPTBearer.savedTokens`, off the main thread), so while macOS asks the person about the keychain, the search runs out of time and says "ChatGPT took too long to answer." Seen live on the morning's first OpenAI search. Reading the sign-in before the clock starts, or saying the search is waiting for the keychain, would fix it.

## Disclosures

- Fixture runs used made-up folders and invisible windows, and handed folders to a stand-in, so no terminal opened.
- The AI search findings came from `~/Helm Test`, a made-up home, with a handful of small requests.
