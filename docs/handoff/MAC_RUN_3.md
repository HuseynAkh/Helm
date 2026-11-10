# Mac run 3

**Status: every request from Huseyn's use of the 8a6657d build is built and checked on fixtures, Helm keeps everything on the Mac, and a DMG release can be made with one script. Nothing here was tried on the real Mac by a person yet. At the end of the run the installed app is replaced with a DMG built from the pushed commit. The Release build shows a 14-point band under the header, as 8a6657d does (Open 6).**

Run on 2026-11-09 and 10, on `handoff/mac-fixups`. Huseyn's requests and the choices made for him are in [`OWNER_RULINGS.md`](OWNER_RULINGS.md). Row status is in [`P0_P1_STATUS.md`](P0_P1_STATUS.md).

## What Huseyn asked

From using the installed build:
- The search field stayed in focus after clicking elsewhere.
- Sidebar rows couldn't be arranged or hidden, "both by dragging and in settings".
- Movies and Music showed a file over the folder icon.
- Recent should keep folders apart from files.
- Two three-line buttons in the header looked wrong.
- Opening folders in the list wasn't smooth.
- The Trash asked for Full Disk Access with no way to give it, and the warning looked bad.
- Helm should say from the start that it works best with Full Disk Access.
- The window edges were hard to grab.

Later in the run:
- Nothing about the person collected and nothing exported.
- An easy, auditable download: a DMG or whatever is best.
- Onboarding of one screen, two at most, that sets Helm up to replace Finder.
- Much shorter text in onboarding and Settings.
- Opening a zip in Finder opened Helm at Home; Finder's own actions should stay Finder's.
- Open With was greyed out.
- Long names shortened in the grid until clicked.
- Test runs kept taking the screen.

## What changed

**Header and search.** The search follows the tab: an empty search closes when you click away, one with words keeps its results and gives the keys back, and going anywhere ends it. The two three-line buttons became a Grid | List switch and the main menu as dots in a circle, next to Search and the sort button, whose words now come with a chevron and drop first in a narrow window.

**Sidebar.** Rows move within their group by dragging and can be hidden by dragging out, from their menu or in the new Settings › Sidebar pane, which also restores the defaults. Go › Trash keeps a hidden Trash reachable. The layout is in `sidebar.json`.

**Access.** A place macOS won't let Helm open gets a card in place of the listing, with Grant Access…, Open in Finder for the Trash, and Try Again. Folders macOS guards show a plain folder icon, not the drop box. Each guarded folder gets its own I/O lane, so one folder waiting on macOS no longer stalls the disk.

**Setup.** One screen: "Welcome to Helm", "Nothing leaves your Mac.", then Use Helm instead of Finder (the default file viewer and a Dock tile next to Finder) and Full Disk Access, with Not Now and Set Up. Move to Applications shows only when Helm runs from a disk image or another place; it copies Helm, asks before replacing an existing copy, and reopens it, which is the only second screen. Help › Set Up Helm… brings it back.

**Recent and the list.** Recent sorts by Last Opened, with Folders and Files sections. Folders open and close in place on one 0.28 s curve, with a Loading row for a slow folder.

**Window edges.** Left to macOS 26's own resizing, which Finder's windows share; a smoke check makes sure nothing of Helm's covers the resize band.

**Bug hunt.** Six testers each hunted one area, and a fixer reproduced every finding before fixing it: 67 findings, 66 fixed by their fixer and the last by another track's change. Among them: Skip during a Replace no longer puts the item it would have replaced in the Trash; a change asked for while another runs waits its turn instead of beeping; cut and paste work across windows; Recent stays current; Go › Utilities opens macOS's utilities; Return in the sidebar opens a place instead of renaming the files; and many window, sidebar and Settings fixes.

**Final review.** Four reviewers each read one part of the finished change (core, interface, app, and scripts with docs) and fixed 17 findings they could show. Among them:
- Hidden items shown for a reveal no longer vanish when another setting changes.
- A folder renamed or trashed inside an open one no longer reads "no longer exists".
- A drop on a tab that shows an access card no longer moves files into the folder under it.
- Show in Helm at launch shows its item, not Home.
- The location bar's suggestions no longer crash on a very long pause.

What they left became three last fixes, each checked again by someone else:
- **Thumbnails.** A stopped Quick Look request no longer leaves the file icon in place of a thumbnail.
- **`sidebar.json`.** It forgets removed stars and bookmarks.
- **Smoke runs.** A scripted run turns down AppKit's own requests to come to the front, so those no longer break the run. One more failure under load is under Smoke under load.

The release workflow also now stops a run started by hand when its tag already sits on another commit.

**Privacy.** Three audits (source, built app, and a live run with networking blocked) found no network code, telemetry or analytics. They found nothing that reads who the person is or which Mac this is, apart from disks' IDs, which Helm reads only to tell disks apart and keeps only in memory. Then:
- The release binary is stripped: no build paths, about half the size, and no debugging entitlement.
- `scripts/privacy_check.py` fails the static checks and the release build on network and tracking code, and on the user, host and hardware ID calls it lists; disks' IDs are allowed. The release script and workflow run it first, and `scripts/release/check_binary_privacy.sh` then checks the built app.
- Smoke runs, and now the README pictures too, run HelmDev under `sandbox-exec` with the network denied. Only a smoke run started with `HELM_SMOKE_NETWORK=allow`, or a Mac without `sandbox-exec`, goes without it.
- Menus check only what kind of thing is on the clipboard. ⌘C puts names, not paths, on it as text.
- Trash records are pruned, the session isn't saved when Reopen windows and tabs is off, and Settings › General › Remember recent items turns Recent off.

**Finder keeps its own.** The zip case, from the system log: Archive Utility's reveal was refused by its sandbox, then its last request, naming nothing, brought Helm forward, and Helm opened its Home window. Helm now reads who sent each request. Archive Utility's and DiskImageMounter's go back to Finder unless Helm handed them the item; other apps' Show in Finder still comes to Helm. A launch while Archive Utility runs opens no window. Helm also claims files at rank None, so sandboxed apps' Show in Finder reaches it, and requests during launch are no longer dropped.

**Open With.** The cause of the grey row: Helm attached the list of apps, then cleared the row's command, and AppKit greys out a row with no command. Fixed in both menus, with Share, New File and Services, and checked in HelmDev and in an Xcode Release build. Several selected items now get Open With, aliases list their original's apps, a big selection no longer freezes the menu, and folders don't offer to change the app for every folder.

**Shorter text.** Two editors went over 129 strings in onboarding, the guide and every Settings pane, and shortened, removed or reworded 74 of them, then a final read on screenshots. Two Advanced rows that did nothing are hidden.

**Grid names.** A name gets two lines. A longer one gets one cut in the middle of its last line, so its start and its end, extension included, stay in view. With one item selected, its name shows in full, up to five lines, and a shortened name is in full in its tooltip. The list is unchanged.

**Release.** `scripts/release/make_release.sh` builds, checks and packages Helm: a DMG with an Applications shortcut, a zip, `SHA256SUMS.txt` and release notes. `.github/workflows/release.yml` builds the same on a pushed tag, with provenance attestations, as a draft. `docs/RELEASING.md` explains both, and why Helm isn't notarized yet.

**Release check.** The first release build of the finished tree stopped at its own binary privacy check. Grid names measure their lines with CoreText, which wasn't on the check's list of system libraries. It's on the list now, with that reason, and the build passes. The release notes now give a `codesign --verify` line that checks an installed copy is intact and has this build's CDHashes, for both kinds of Mac.

**Last read.** Five more reviewers each read part of the tree as it stood at dee0cbc: personal data, the pictures, the release files, the changes made after the review, and the public docs. A second reviewer re-checked each finding. They found nothing private that isn't already on GitHub. Their findings fixed before the push:
- The docs said more than the code does about disks' IDs, the Trash records, Full Disk Access, removing Helm, what `codesign --verify` shows for an ad hoc app, and smoke runs blocking the network.
- The setup screen and Settings said Full Disk Access shows "every folder"; it now says the Trash and other apps' folders, as Helm's own model has it.
- Forgetting gone stars at launch asked the disk about each starred path, which a server that stopped answering could hold up; it now asks once per star instead of twice (Open 11).
- The binary check gained the `_r` forms of the user lookups and two more kinds of build path, and its header says what it can't see.

Then three more reviewers, each again re-checked by a second, read this report, the commit messages, the PR text and those fixes. What they found is fixed here: wrong or unlabelled counts, wording that said more than the code, and release notes whose CDHash step would have passed a changed copy. A last pair read the final wording and found that commands with a trailing `#` comment fail when pasted into zsh, the Mac's default shell; the README and the release notes no longer use them.

**README.** Rewritten for people who might use Helm, with pictures from a made-up home (`scripts/readme/make_readme_images.sh`), privacy, install and build steps. The pictures are taken in the background, so they show Helm as an inactive window: grey window buttons, and no accent colour on Set Up, the switches or the list's selection. `HELM_README_FOREGROUND=1` should take the browser windows in colour (not the setup screen's Set Up; not tried in this run), but it takes the screen while it runs.

**Test runs stay in the background.** Scripted windows are invisible and let clicks through, and a scripted run never activates.

**Smoke under load.** The first full run on the finished tree ran alongside a full build and test run, and failed 2 of its 1,525 checks. Under that load, Helm turned away a scripted Redo with "Helm is still working on a change in this window", because the Undo before it was still finishing. That is right for a person, so the fix goes in the test: before a scripted Undo or Redo, the smoke driver now waits up to 10 s for the window's last change. A test that pastes 3,000 files and sends Undo at once shows the difference:
- the old driver got 2 failures and 3 refusals;
- the new one got none.

## Results

All on this Mac (macOS 26.7, Apple silicon), on fixtures, with Helm never in front: a watcher read the front app every 0.3 s through every run.

| Check | Result |
|---|---|
| `swift test`, all 8 bundles | 1,930 tests, 0 failures; 1 skipped, which runs only on Linux |
| Compiler warnings | 8 in a clean build of 2754e65, the same 8 as 8a6657d's, so none from this run; the last full Release build (d283a6c, the binary in the DMG) shows the same 8 once per architecture, which `make_release.sh` counts as 16 |
| `bash scripts/static_checks.sh` | 341 Swift files, 0 errors; privacy check, 346 files, 0 problems |
| Gate, `scripts/rebuild/run_all.sh` | 15 of 15 checks, with 1,528 portable tests |
| Full smoke on the final code, with the full tests running alongside | 1,485 checks on the first launch and 40 on the restore launch, 0 failures |
| Full smoke alone, on 2754e65 (before the last read's star-cleanup and Full Disk Access text fixes) | the same 1,525 checks, 0 failures |
| Full smoke on the final Release build, the one in the DMG | 1,524 of 1,525; the one failure is the band under the header (Open 6) |
| Undo and Redo sent while a 3,000-file paste runs | old driver: 2 failures and 3 refusals; new driver: none |
| Each of the four commits on its own | its script tests, static checks and privacy checks pass |
| README pictures | taken again in the background with the network blocked; all 10 looked at; every hero thumbnail shows |
| `scripts/release/make_release.sh` | a 7.8 MB DMG and a 6.8 MB zip; the source and binary privacy checks, the signature and the checksums pass, the app is built for both architectures, and the notes' `codesign --verify` line passes on the zipped app |
| Read-only checks before the push | five reviewers on dee0cbc, then three on this report, the commit messages, the PR text and the fixes, then two on the last changes, each finding re-checked by a second: nothing private that isn't already on GitHub; the rest fixed, listed under Open, or accepted there |

## NOT RUN

| Item | Why |
|---|---|
| A person using the build: setup, Full Disk Access in the real list, Move to Applications from a real DMG, Gatekeeper's Open Anyway | Fixture runs only; the installed app is replaced at the end for Huseyn to try |
| Real Archive Utility and DiskImageMounter routing | They can't be launched on real files here; the probes reproduced the requests |
| Open With handing files to real apps, and real default-app changes | A stand-in launcher took them |
| The GitHub release workflow | Nothing was tagged |
| macOS 14 and 15, and Intel Macs | Only this Mac (macOS 26.7, Apple silicon) |
| A look at a real, composited Release window: the band under the header, the list's header colour | Scripted windows are invisible and drawn by hand; a real one would take the screen |

## Open

1. **Signing.** Builds are signed ad hoc, so each update needs Open Anyway again and Full Disk Access re-added. A Developer ID and notarization would end that.
2. **License.** None yet.
3. **Bundle ID.** Releases ship as `com.helm.filemanager.dev`; changing it after people install resets their settings and Full Disk Access.
4. **Publishing 0.1** needs Huseyn's go-ahead. It should be made as `docs/RELEASING.md` describes, by tagging the pushed commit, so the workflow's notes name that commit and carry the attestations and the run's link. A DMG built on this Mac has neither.
5. **XcodeGen on CI** isn't pinned to a version, and it runs in the job that can sign attestations. Pinning it with a checksum, or attesting in a job of its own, would close that.
6. **A band under the header in the shipped build.** Xcode links Helm against the macOS 27 SDK, so macOS gives the window its new design, where a unified toolbar's title bar area is 66 points, not 52. The window buttons still line up with Helm's 52-point header. The list and grid, though, start below the whole title bar area, which leaves a 14-point band under the header. 8a6657d, in use since run 2, has the same band. The likely fix is to turn off the list's and grid's automatic content insets. That moves their column headers into the area where macOS can blur scrolling content, so it needs a look at a real window first.
7. **Smoke runs test the old design.** SwiftPM records SDK 14 in HelmDev, so every smoke run gets the old design. A full smoke on the final Release build passes 1,524 of 1,525 checks; the one failure is `title-bar-fits-header`, the band above. Running the smoke on the Xcode build too (`HELM_SMOKE_BIN`), or linking HelmDev against the 27 SDK, would test what ships.
8. **Layout notices in tests.** Tests that open a window log a passing Auto Layout conflict as the window takes its content (`BrowserWindowController.swift:223`); AppKit resolves it.
9. **Trash records without Full Disk Access.** A Trash emptied in Finder leaves its records in `trash-origins.json`, up to 1,000, until Helm can look in the Trash. An age limit would cap that, at the cost of Put Back for older items.
10. **Polish.** In light mode the list's column header is white over grey rows. Old "pending Opus review" draft headers are still in 464 files (50 of them touched here), as they already were on GitHub.
11. **Star cleanup at launch.** Forgetting gone stars at launch still standardizes each starred path, which can ask the disk. Moving it after the first window, as the Trash cleanup already is, would keep a launch only for Finder off the disk.
12. **Accepted as they are.** The setup screen's "Nothing leaves your Mac." stays: Helm makes no connections, and files leave only when someone sends them. macOS tags each file on a DMG built here with its `com.apple.provenance` attribute, an opaque value it gives every file a session on this Mac writes.

## Disclosures

- Probe apps registered with Launch Services during the routing work were unregistered and deleted. xcodebuild registered its scratch builds of Helm.app with Launch Services, as every Xcode build does.
- A check that ran the installed Helm with `--help` started a second copy for about two minutes before it was stopped.
- An auditor's probe left two empty cache folders in `~/Library`; they were deleted.
