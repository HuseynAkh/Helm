# Mac run 4

**Status: Helm is now an agentic file manager. AI mode is built, checked on fixtures with a scripted model, and off until turned on. No real provider, key, cloud folder or server was used, and no person has tried it yet; the list under "Needs Huseyn's Mac" is all not verified. The version is 0.2. Nothing was pushed, installed or released.**

Run on 2026-11-12 to 14, on the branch `agentic/merge`. Huseyn's words and the choices made for him are in [`OWNER_RULINGS.md`](OWNER_RULINGS.md#ai-mode-mac-run-4-2026-11-12-and-13).

## What Huseyn asked

- An agentic file manager, with an agentic base built separately for it.
- A spark-like action button at the top right, beside the three dots, that opens a sidebar like VS Code's chat, with a text bar at the bottom.
- Three suggested operations for the folder on show, such as organize (with levels), move everything to a folder, copy everything.
- More visibility of the current folder when the panel opens. He later ruled the path bar stays as it is (2026-11-13).
- AI mode in onboarding, with a futuristic screen and an on and off switch, and in Settings.
- Claude, OpenAI, Gemini, Grok, any compatible API, LM Studio and Ollama.
- AI mode only in the folders it is given, with more added by typing a path or a `/` command.
- An AI toggle in search, separate from the folder choice.
- Remote and cloud folders, such as Google Drive and iCloud.
- Best security practice throughout, little text, an Apple-like feel.
- One button in place of the Grid and List pair.
- A README that leads with AI mode, with Nautilus lower down as Helm's DNA, new graphics, and the logo unchanged (2026-11-13).
- A full review of the interface, including the three dots whose circle was sometimes cut (2026-11-13).

## What was built

- **`HelmAgent`**, a new module with no AppKit and no way to change or open a file: providers, one network transport, keys, the conversation, folder rules, plan checks, the three suggestions and AI search's planning. A source check fails if it imports more.
- **Three wire formats:** Anthropic Messages for Claude, OpenAI Responses for OpenAI and Grok, and Chat Completions for Gemini, Ollama, LM Studio and Other. Model lists come from each provider.
- **Keys** in the login keychain, one per provider and host. A key is never in a file, a log, a request body or a picture.
- **The spark** in the header, Helm's own four-point mark, and **the AI panel**: a 340-point column under the header with the folder chips, the consent line, the thread, three suggestions and the composer. `/add` and `/clear`; a typed or dropped path adds a folder; a server address gets one Connect line and goes to macOS.
- **Plans:** the model proposes, Helm checks every step, and the card shows each group with a tick and its full list. Trash, and changes that reach a place that syncs or is shared, start unticked. Apply runs through Helm's own operations, so conflicts keep both, removals go to the Trash, and one Undo puts it all back. Stop works between two steps.
- **Remote and cloud folders:** one classifier names the place on the chip and in the plan's notes. Every agent read and every Apply runs with macOS's downloads switched off, so nothing is fetched.
- **AI search:** the field's spark turns it on. The model plans up to six searches, Helm runs them on the Mac and asks the model to rank the matches. Each result's tooltip says why it matched.
- **The AI Mode screen** after setup, and **Settings › AI**, sharing one model. Done is the only way to leave AI mode on, and it opens the panel in the window in front.
- **One view button** in place of the Grid and List segments.
- **Privacy checks** for the new promise: network code in one file, four web addresses, and a binary check that allows only the listed URL-loading calls and addresses.
- **The README**, rewritten agentic first, with 17 pictures retaken from scripted background runs and a banner and spark drawn by `scripts/readme/make_brand.swift` from the unchanged app icon.

## Verified here

All on this Mac, on fixtures, with Helm's windows invisible and its networking blocked by `sandbox-exec`. The scripted model stands in for every provider.

| Check | Result |
|---|---|
| `swift test`, whole suite, after the last fixes | 2,907 tests. One failure under load, `testRenameAndTrashInsideAnOpenFolderKeepASelection`, passed alone |
| `HelmAgentTests` alone, after the live wiring | 532 tests, 0 failures; 536 after the security fixes |
| Gate, `scripts/rebuild/run_all.sh` (da68a5d) | exit 0, every check passes, 2,295 portable tests, `HelmAgent` built and its tests run |
| `bash scripts/static_checks.sh` | 434 Swift files, 0 errors; privacy check, 439 files, 0 problems |
| Script tests | 51 in `scripts`, 37 in `scripts/rebuild` |
| Full smoke, Debug, after the last fixes | 1,795 checks passed, none failed |
| Smoke with the shipped wiring and AI mode off (`HELM_SMOKE_AGENT=live`) | 1,544 checks passed; no model client was built |
| Smoke with the shipped wiring and AI mode on (`HELM_SMOKE_AGENT=denied`) | Passed: the sandbox stopped HelmDev at its first request, to Ollama on 127.0.0.1 |
| Release build (`make_release.sh`, ad hoc) and `check_binary_privacy.sh` | All nine checks pass: 4 provider addresses, 15 URL session calls, all listed, no build paths |
| Full smoke on the Release build | 1,788 checks passed; the only failure is the known 14-point band (run 3, Open 6) |
| Security, privacy and product | 17 problems found: 12 fixed, the rest under Open |
| The interface, every AI mode state on both SDKs | 60 problems found and 34 fixed; 31 of the fixes shown working by a picture or a test. The three dots are whole at every width from 640 to 1,600 points, light and dark |
| README pictures (`make_readme_images.sh`) | All 17 taken in the background with the network blocked, every step passing, and each picture looked at: fixture names only |

The pictures' run also checks AI mode end to end: the AI Mode screen connects with a stand-in key, the panel's three suggestions read "Organize 10 items", the plan reads "9 moves · 3 new folders" with the Trash group off, Apply moves 9 items, Undo puts every file back, and AI search finds the three fall invoice PDFs, newest first, and gives Invoice October.pdf the reason "Name has “invoice” · PDF".

## Needs Huseyn's Mac

None of these was verified. Each needs a real account, a real cloud folder or server, or a person at a real window.

| Item | Status |
|---|---|
| The keychain prompt after an update, and whether Always Allow sticks | Not verified |
| A local model from the bundled Release app, with and without a system web proxy set; this also settles whether `App/Info.plist` needs a local-networking key | Not verified |
| The not-downloaded flag (`SF_DATALESS`) and the iCloud keys on a real Google Drive, Dropbox or OneDrive folder | Not verified |
| With iCloud Desktop & Documents on, `~/Documents` reads as iCloud, and a not-downloaded file there is left out of a move to Downloads | Not verified |
| The mirror shortcut Google leaves, and the sync apps' attribute names | Not verified |
| A Google Drive shortcut folder as the tab's folder | Not verified |
| A real server's missing Trash | Not verified |
| After a live session, nothing with a file name in `~/Library/Caches`, `~/Library/HTTPStorages` or saved state for Helm's bundle ID | Not verified |
| Whether a folder a plan made and filled gets macOS's first-open check | Not verified |
| One request to each real provider: Claude, OpenAI, Gemini, Grok, and Other | Not verified |
| Continue with ChatGPT against OpenAI: the browser sign-in, the callback, the token signature, renewal, Remove, the plan's model list and a plan request | Not verified |
| Setup showing before any access prompt after this reinstall, and the Full Disk Access row | Not verified |
| Spotlight's part of AI search on a real index, and Connect handing a real server address to macOS | Not verified |
| The panel's top inset, the sparks and Settings › AI in a real window built with the 27 SDK | Not verified |
| The three dots after dragging a window between a Retina and a standard display, the AI Mode screen's resize animation, and the beep when Done can't close | Not verified |

## Open questions

Each one has a default, used in this build. Huseyn can change any of them.

| Question | Default used |
|---|---|
| 1. Download cloud files on request? | No. Version 0.2 never downloads. A step that needs a file that isn't downloaded is left out, with a count. A ticked "Download N files" line could come later. |
| 2. Read inside files? | No. Only names and details are sent. A fourth tool and a Settings row are the first follow-up. |
| 3. OpenAI's preselected model | `gpt-6-astra`, the vendor's stated starting point. One constant to change. |
| 4. The About line | Settled on 2026-11-14: it reads "An agentic file manager for your Mac." |
| 5. A separate model for search | No. AI search uses the model picked in Settings › AI. |
| 6. Did "your current URL" mean `~ / Documents / Reports` or the literal path? | Settled by the path bar ruling of 2026-11-13: the path bar is unchanged, and the panel's chip shows the folder and its place. |
| 7. The version number | Settled on 2026-11-14: 0.2. `App/Info.plist` reads 0.2 (build 2), and the notes are in `docs/releases/0.2.md`. |

## Open

1. **The Release build's 14-point band** under the header (run 3, Open 6) remains, and the panel's top sits under it the same way.
2. **Keys after an update.** Re-saving a key after another build's first read is not built, so macOS may ask for the keychain password after each ad hoc update.
3. **Small local models** can miss files in big folders; a native Ollama adapter with a larger context is the first fix if testing shows that.
4. **Opening the panel in the list** hides the sidebar at the default width so the columns keep their words, and gives it back on close. Keeping the sidebar with a narrower list is a one-line change.
5. **Light-mode header icons** draw in the full label colour since the last fix; their contrast was not looked at again in a real window.
6. **Draft header lines.** Removed on 2026-11-14 at Huseyn's word, in a commit of their own.
7. **The README's footer** that named the tools the first version was built with was removed on 2026-11-14 at Huseyn's word.
8. **The icon variants** from run 2 stay in `docs/brand/logo-variants/` as the record of the icon Huseyn chose. No new variant was made.
9. **Sidebar at narrow widths.** In the invisible-window smoke runs, hiding the sidebar in a window about 760 points wide sometimes does nothing (header.txt, `header-leading-is 84`). It also fails with an older commit when that file runs alone. Not yet seen in a real window.

## Disclosures

- Nothing was pushed, fetched, installed or released, and no real key or provider was used. The pictures' stand-in key lives only in the scripted run's memory.
- Every run used invisible windows on a made-up home folder. Helm was never brought to the front, and the installed app was never opened.
