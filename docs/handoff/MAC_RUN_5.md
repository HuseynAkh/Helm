# Mac run 5

**Status: Huseyn's list for AI mode is built: This Folder / Whole Mac, Read contents, the file type row in AI search, the panel's resize and new style, and the trefoil mark. The onboarding is now one window, step by step, with AI mode as a step. It was all checked on fixtures with a scripted model and invisible windows. No real provider, key, cloud folder or server was used, so the list under "Needs Huseyn's Mac" is not verified. The consent wording for Read contents waits for Huseyn. Nothing was pushed. Run 6 changed what Read contents sends and the wording: see [`MAC_RUN_6.md`](MAC_RUN_6.md).**

Run on 2026-11-15 to 17. The work was merged on `agentic/next` and then moved onto `handoff/mac-fixups` on this Mac. Huseyn's words and the choices made for him are in [`OWNER_RULINGS.md`](OWNER_RULINGS.md#ai-mode-mac-run-5-2026-11-15-to-17).

## What Huseyn asked

- Fix the ChatGPT sign-in page that never finished loading, and the Organize suggestion that answered with a description instead of a plan (2026-11-15).
- Show the folder each group of a plan goes to (2026-11-15).
- A This Folder / Whole Mac switch, so AI mode can decide whether files belong somewhere else.
- A switch that lets the panel and AI search read file contents, such as pictures and video.
- A file type choice in AI search: Photo, Video, Document, Folder, Code and one or two more.
- A panel edge that really resizes it, and a lighter, Apple-like panel that fits the Nautilus look.
- A new AI mark in the spirit of the Apple Intelligence logo, with no background. He chose the trefoil on 2026-11-17.
- An onboarding that doesn't break on macOS's Quit & Reopen, with AI mode as one of its steps rather than a pop-up over the file window.
- A README redesign: tidy and correct, a new banner, premium throughout, in the new mark's style.

## What was built

- **The sign-in listener** reads each browser connection as a blocking read with a time limit, so a browser that sends its request a moment after connecting is answered.
- **Plans from suggestions.** A request for changes answered with words alone asks the model once more for the plan. Each group of a plan shows its destination from `~`, shortened in the middle.
- **This Folder / Whole Mac**, at the end of the panel's folders row. Whole Mac adds the home folder, iCloud Drive, each cloud folder and each mounted disk, under the same rules as a folder you name, and shows them as one Whole Mac chip. System folders, Library and other apps' data stay out. Every new thread starts in This Folder.
- **Read contents**, a switch beside the composer and at the end of AI search's file type row, off for every new thread and search. Helm reads text, RTF, PDFs, pictures (text and what they show) and sampled video frames on this Mac with PDFKit, Vision and AVFoundation. The model gets short summaries, marked as untrusted data, never the files. Files that aren't downloaded, links, packages and key files are never read. In AI search it looks through up to 200 pictures and videos, and each result says what was seen.
- **The file type row** under the header while AI search is on: Any, Photo, Video, Document, Folder, Code, Audio and Archive. The choice holds the model's plan and the results to that kind.
- **The panel's edge** takes every press along it; the thread's view had covered the handle. **The panel's style** follows the sidebar's material, with native type, soft bubbles, grouped plan cards and a rounded composer, in light and dark.
- **The trefoil**, one line in amber, coral and violet that loops three times over and under itself, drawn by `SparkMark.swift` with a weight tuned for each size. It replaced the four-point spark in the header, the search field, the panel, the AI Mode screen, Settings, `docs/brand` and the README. The app icon is unchanged.
- **The onboarding**: Welcome, Full Disk Access, Default File Viewer, AI Mode, You're All Set, in one window of one size, with Back and Continue. Its place is saved at every step, so macOS's Quit & Reopen after Full Disk Access carries on at the next step. The file window opens at the end, and no AI pop-up follows. Helm never quits itself for a permission; the quit Huseyn saw was macOS's own.
- **The README**, redone: a new banner, with the unchanged icon beside a lockup of the trefoil, the words "AI mode" and the name, on a soft field in the mark's colours, in light and dark, drawn by `scripts/readme/make_brand.swift`. Every picture was taken again from the current app, 24 in all, with light and dark pairs for AI mode. The pictures draw the window as the one in front (a switch only a scripted fixture run can turn on), so the window buttons and the accent show, and Helm still never comes to the front. The badges are gone, and the text was checked against the code.
- **Two fixes the pictures showed:** the composer's hint and Send's grey were hard to see on the dark panel, and Whole Mac's consent line said names come from the home folder only. It now says "from your home folder and disks".

## Verified here

All on this Mac, on fixtures, with Helm's windows invisible and its networking blocked by `sandbox-exec`. The scripted model stands in for every provider.

| Check | Result |
|---|---|
| `swift test`, whole suite | 3,141 tests, 0 failures, 1 skipped |
| `bash scripts/static_checks.sh` | 454 Swift files, 0 errors; privacy check, 459 files, 0 problems |
| Script tests | 57 in `scripts`; `scripts/rebuild` all pass |
| Full smoke, Debug | 2,140 checks passed, none failed |
| Release build (`make_release.sh`, ad hoc) and `check_binary_privacy.sh` | Every check passes, with PDFKit, Vision and AVFoundation on the allowed list for Read contents |
| Full smoke on the Release build | 2,138 checks passed; the only failure is the known 14-point band (run 3, Open 6) |
| README pictures (`make_readme_images.sh`) | All 24 and both banners taken in the background with the network blocked, every step passing, and each picture looked at: fixture names only |
| Each feature on its own branch, before the merge | Whole Mac, Read contents, the file type row, the panel, the mark and the onboarding each passed the whole suite and the full smoke |

## Needs Huseyn's Mac

None of these was verified. Each needs real files, a real account or a person at a real window.

| Item | Status |
|---|---|
| Read contents on real files: a scanned PDF, photos with text, a long video, and how long a big folder takes | Not verified |
| Read contents and Whole Mac leaving out a cloud file that isn't downloaded, with nothing fetched | Not verified |
| Whole Mac with a real model on a real home folder, including iCloud Desktop & Documents | Not verified |
| The panel's edge dragged by hand, and its new style, in a real window built with the 27 SDK | Not verified |
| The onboarding with real permissions: Full Disk Access, macOS's Quit & Reopen alert, the default viewer and the Dock | Not verified |
| The trefoil at header size on a standard, non-Retina display | Not verified |
| Continue with ChatGPT through to a plan, after the listener fix | Not verified |
| The file type row with Spotlight's real index | Not verified |

## Open

1. **The Read contents consent wording** is Huseyn's call. The wording in this build is in [`OWNER_RULINGS.md`](OWNER_RULINGS.md#waiting-for-huseyn).
2. **Speech in video** is not read; only sampled frames are.
3. **The onboarding floats over System Settings** while it waits for Full Disk Access, so it may cover macOS's Quit & Reopen alert. This needs real permissions to check.
4. **Finder stays in the Dock.** macOS doesn't let an app remove it. Helm's option puts Helm first instead.
5. **From run 4:** the Release build's 14-point band under the header, keys after an ad hoc update, and the sidebar at about 760 points in invisible-window runs ([`MAC_RUN_4.md`](MAC_RUN_4.md#open)).
6. **The icon variants** in `docs/brand/logo-variants/` stay, since his "Yes" to the question about them could mean keep or remove.

## Disclosures

- No real key or provider was used. Every picture and check ran on a made-up home folder with invisible windows; Helm was never brought to the front.
- The pictures' run never took the screen: windows stayed invisible, and keys kept going to the app in front.
