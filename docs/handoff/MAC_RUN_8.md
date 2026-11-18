# Mac run 8

**Status: The onboarding carries on after any quit, macOS's Quit & Reopen and a force quit included, and its Full Disk Access step marks access that's off in red. The AI panel offers Organize alone, as a plain button. A read that macOS holds shuts only the folder it was reading, and AI search says when the disk didn't answer. Properties changes the permissions of your own items, as Finder and Nautilus do, with Undo. A model on this Mac that sees pictures looks at 24 files. Nothing was pushed.**

Run on 2026-11-18, on `handoff/mac-fixups` after `ccdad94` (run 7, merged to main as PR #7). Huseyn's words and the choices made for him are in [`OWNER_RULINGS.md`](OWNER_RULINGS.md#mac-run-8-2026-11-18).

## What Huseyn asked

- The Full Disk Access step should show something red, like a red X, so people see they have to act rather than press Continue.
- After Full Disk Access and macOS's own Quit & Reopen, Helm skipped the rest of the onboarding and opened its file window. "We have talked about this bug multiple times now. Fix it. Onboarding flow should be maintained after quiting / force quitting."
- Organize isn't a drop-down: no chevron, and no Move and Copy buttons, since people can ask for those themselves.
- The open items: decide how Helm should cope with a disk that stops answering ("maybe even hybrid"), test with the vision model now that Qwen's download finished, and decide editable permissions, replicating Finder and Nautilus and staying stable.
- Then reinstall Helm with its data cleared again.

## What was built

- **The onboarding carries on after any quit.** Only the person's own close (the close button, Command-W, Escape) or Get Started now counts as going through it; a close Helm or AppKit makes doesn't. From the moment Helm is asked to quit, by the person or by macOS's Quit & Reopen, nothing the window does counts, and a quit that's cancelled puts that back. Before, a quit only told the AI mode screen, and a close of the window on the way out counted as going through setup, which forgot the step it had reached; the next launch then went straight to its file window, as Huseyn saw. A force quit runs no code at all, and the step is kept as each step opens, so the next launch carries on there too. A test quits as AppKit may, closing the window on the way out, and the next launch carries on at the next step.
- **Full Disk Access off is marked in red**: a red ✕ where the green check goes once it's on, on the onboarding's step and in the guide.
- **Organize alone.** The panel's suggestion is one plain button, Organize, for the folder on show or the items selected. Its menu of depths, and the Move and Copy suggestions and the sentences they typed, are gone. Typed requests to move or copy are as before.
- **A read that macOS holds shuts only its folder** (`IOExecutor`, B-107). A read that times out records the folder it read; reads of that folder, or inside it, fail at once, and every other read on the disk carries on. The whole disk is still shut, as before, when reads stall in two places at once that aren't inside each other, when a read with no folder stalls, or when stalled reads hold every one of the lane's workers; a change can't say where it lands, so it's refused while any read on its disk is stalled, as before. A search leaves out a folder inside that doesn't answer and goes on with the rest, and AI search that found nothing because the disk didn't answer says "The disk didn't answer, so nothing there was searched." rather than "0 matches". Not looking inside Desktop, Documents and Downloads before they're opened was left out: with a folder's stall kept to itself, macOS's question is there for the person to answer when they search their home.
- **Permissions in Properties.** For items the person owns, Owner, Group and Others each have Finder's Read & Write, Read only or No access (rwx, r-x, --- for a folder; rw-, r--, --- for a file, its execute bits kept), a mode none of those fits shows as Custom, and a file has Nautilus's "Allow executing file as program". A change applies at once and is one Undo, "Change Permissions", in the window's own history, from Properties or the browser window. It's refused, with nothing changed, if the item was replaced or its mode changed meanwhile, if it's locked, on a read-only disk, or on a disk that keeps no permissions. Another account's or root's items, and links, are shown as before. Helm still reads no account names. "Apply to enclosed items" was left out.
- **A model on this Mac that sees pictures looks at 24 files**, rather than 12, shown 4 files and at most 6 pictures a question so each question fits the 4,096 tokens LM Studio gives a model unless told otherwise; one that reads text only still looks at 12, 12 a question. A lone letter such as the "a" of "a bird" is no longer a word looked for inside files or in names.
- **The README is a landing page** (`4eef8fc`), at Huseyn's word: "benefit-centric", "just calling it agentic at first", with AI search's picture first, then typing a path, then the sidebar. It opens with what Helm does for you, then four short sections with five pictures, retaken from this build: AI search, the path bar, a plan and its Undo, and the window with its sidebar. The details went, word for word where still true, into `docs/AI_MODE.md`, `docs/PRIVACY.md`, `docs/INSTALL.md`, `docs/SHORTCUTS.md` and `CONTRIBUTING.md`, and the 16 pictures no page shows any more were removed with their steps.

## Verified here

On `16229a5`, with an external 1080p display as the Mac's main one:

- `swift test`: 3,329 tests, 1 skipped. The only failures are twelve pixel checks in two header tests (`HeaderBarTests.testIconButtonsDrawTheirSymbolInTheFullLabelColour` and `testTheFieldsSparkAddsNoWidth`), which `ccdad94` fails the same way on this display (open item 4).
- New tests: the onboarding left to carry on when its window is closed on the way out of a quit, and counted through by the person's close after a cancelled one; the red mark; Organize alone; folder stalls in the I/O executor (`FolderStallTests`, and `PrivacyLaneTests` for `LiveFileSystem`); a search that leaves out a folder that doesn't answer; the disk-didn't-answer line; a question's time starting once the keychain has answered; the plan's folder word naming the place searched and lone letters left out; permissions (`PermissionChoicesTests`, `PermissionsWriterTests`, `PermissionHistoryTests`, `PropertiesPermissionsTests`, `PermissionChangeFlowTests`); and the look's size for a model on this Mac.
- Debug smoke: 2,450 checks passed. The three that fail are the list-width steps `names-list-width 340`, `names-list-width 560` and `names-list-whole`, which `ccdad94` fails the same way on this display.
- Release build: built clean, with the same 16 compiler warnings as before. Its smoke passed 2,448 checks; the failures are the same three list-width steps and the known 14-point title-bar band (run 3, open 6).
- `privacy_check.py`: 470 files, 0 problems. `static_checks.py`: 465 Swift files, 0 errors. All eight script tests pass.

## Live on this Mac

In the installed app, each a build of this branch as it was then:

| What | How | Seen |
|---|---|---|
| Full Disk Access off, on `4da7e3d` | A new build, so Full Disk Access was off; Continue on the welcome | The step's card says "Full Disk Access is off" with the red ✕ beside it |
| A quit with the onboarding open, on `4da7e3d` | With the Full Disk Access step on show, Helm asked to quit the way macOS's Quit & Reopen asks (`NSRunningApplication.terminate`), then opened again | Helm's settings kept "access:welcome,access,viewer,ai,done:" and the onboarding wasn't counted through; the next launch opened on the Full Disk Access step, with no file window |
| A force quit, on `4da7e3d` | `kill -9` with the same step on show, then opened again | The same: back on the Full Disk Access step |
| The person's close, on `4da7e3d` | The window's close button | The onboarding counted as through, the kept step cleared, and the file window opened |
| Qwen2.5-VL 7B in LM Studio, loaded with 4,096 tokens, on `fa00847` | "a bird" in `~/Helm Test/Pictures/Image Tests`, Read contents on | "3 matches · Image · Mentions “a”, “bird” · Looked at 12": the eagle, owl and penguin. LM Studio's log showed one look answer, for the first two items only: twelve 512-point pictures, some 330 tokens each, ran past the model's 4,096 tokens, and the rest of the question was cut. Its plan asked for "Image Tests", the folder searched, as a folder word, which `fa00847` already leaves out, and for "a" inside every picture |
| The same, on `4da7e3d` (24 files, 12 a question) | Again | "3 matches · Image · Mentions “bird” · Looked at 23": the "a" gone, every photo shown, the parrot still missed |
| The same, on `16229a5` (4 files and 6 pictures a question) | Again | "8 matches · Image · Mentions “bird” · Looked at 24", in about four minutes: the eagle, owl, parrot and penguin and the penguin video, the parrot seen by the model itself, since Apple's reader says nothing of it. Also three it called fits on its own: the zebra, the soccer ball and the tennis ball, each with what it saw written right ("zebra", "ball"); a model of 7 billion parameters on this Mac judges less well than a hosted one |

LM Studio's own log was read with `lms log stream`, LM Studio's command line for it.

## Left installed

`/Applications/Helm.app` is the Release build of `16229a5` (CDHash `c8f270b8…`), installed as a fresh install at Huseyn's word, "Reinstall / clear helm cache again", with his earlier choices "Everything" and "Restore Finder first". Before it, Helm's own `--default-viewer finder` and `--dock-first off` made Finder the file viewer again and took Helm off first in the Dock, so setup offers both; Helm's data folder and an export of its preferences went to the Trash, named "before fresh install 2, 18 Nov", and the preferences were deleted. There were no keychain items to delete: the sign-in in use was LM Studio's, which keeps none. The build that was installed went to the Trash as "Helm 0.2 (16229a5, 18 Nov).app", and the same build was installed again from its disk image. It hasn't been opened: setup, Full Disk Access, AI mode and any sign-in are Huseyn's. Nothing was pushed.

## Open

1. **The onboarding with macOS's real Quit & Reopen** is fixed by what the code shows and by tests that quit as AppKit may; it hasn't been watched live with a real Full Disk Access switch, which only Huseyn can turn on.
2. **The same macOS question in two folders.** Two reads outside the folders macOS asks about, waiting on one question in two places, still count as a disk that stopped answering.
3. **Permissions:** "Apply to enclosed items", and the read-only and FAT disk refusals, untested on a real disk of each kind.
4. **Display-bound checks.** With an external 1080p display as the main one, three list-width smoke steps and two header tests (twelve pixel checks) fail; they fail the same way on `ccdad94`, which passed them earlier the same day, before the main display changed.
5. ~~**The README pictures**~~ Taken again with the README rewrite (`4eef8fc`): the plan shows Organize alone.

## Disclosures

- Fixture runs used made-up folders and invisible windows; the live searches used `~/Helm Test`, a made-up home, with a handful of small requests to LM Studio on this Mac.
- The disk handling and the permissions were built by two helpers in worktrees of their own, from this branch, and merged here; their branches are `worktree-agent-a538ba5b9add5580b` and `worktree-agent-adf63aecfc4974ee1`.
