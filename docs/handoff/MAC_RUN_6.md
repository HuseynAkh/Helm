# Mac run 6

**Status: With Read contents on, the model now reads documents and looks at small copies of pictures, video frames and scanned pages, in the AI panel and in AI search. The plain search has the kind row too, and an AI plan can make new files. A security review and a private-data scan ran on the whole change, and what they found was fixed, apart from the two items under Open. It was all checked on fixtures with a scripted model and invisible windows. No real provider, key or picture was sent anywhere, so the list under "Needs Huseyn's Mac" is not verified. The consent wording is a draft that waits for Huseyn. At his word, it was pushed and merged.**

Run on 2026-11-17. The work was merged on `agentic/vision` and then moved onto `handoff/mac-fixups` on this Mac. Huseyn's words and the choices made for him are in [`OWNER_RULINGS.md`](OWNER_RULINGS.md#ai-mode-mac-run-6-2026-11-17).

## What Huseyn asked

- Check that the Read contents wording is true and the best way to say it, give enough information, and say that no metadata is collected, if that's so.
- Let the model itself read local documents and look at pictures and videos, so AI search finds a specific picture. The README must say so.
- The file type choice in the plain search, not only in AI search.
- Let the AI panel work as a light local harness: make files, folders and documents on request, without bloat, with every supported model.
- Push and merge after a review for security and private data.

## What was built

- **The model looks.** With Read contents on, Helm makes a small JPEG of each picture on this Mac, 512 pixels on its longer side, with no metadata, and sends it with the request. It does the same for the 3 or 5 frames it samples from a video and for a scanned PDF's first page. Text files, Markdown, RTF, PDFs, .docx and .odt send their first 1,500 characters. Apple's on-device labels and found text stay in every summary. Each provider gets pictures in its own form: Claude as image blocks in the tool result, OpenAI and Grok as `input_image`, and Gemini, LM Studio, Ollama and other servers as `image_url`. A provider that refuses pictures gets the request again without them, and none for the rest of that thread or search.
- **AI search looks too.** After Helm finds candidates on this Mac, the model looks at the best of them, 48 with a cloud model and 12 with a model on this Mac, 12 per question, and says which fit and what it saw. Those come first, and a result's tooltip says "Model saw: …". The status bar says how many it looked at. Across the whole Mac it looks only at files the search or the on-device labels matched. Code goes only when you choose Code, and settings files only with Code or Document.
- **The kind row in the plain search.** It shows whenever the search is open, AI or not, and keeps the search to that kind. Each tab keeps its search's kind, and the status bar ends with it. It goes back to Any when the search closes.
- **New files in plans.** A plan can make files with the model's text: plain text, Markdown, CSV, JSON, YAML, HTML, code, RTF or Word. That's up to 20 a plan, 100,000 characters each and 500,000 in all. A new file's row shows its first lines as a tooltip. Code and web pages start unticked, and so does a new file anywhere other people or devices see it. Scripts that Windows runs on a double click, files that run on a routine command (`package.json`, `setup.py` and the like) and the names Windows keeps for devices are refused. Undo sends new files to the Trash.
- **The wording.** Settings and the onboarding say what is sent and that Helm has no servers and collects nothing. A thread's first line names what Read contents sends. The README's Read contents, Find with AI, Plan and Privacy sections were rewritten to match.

## The security review

A review of the whole change found these, and each was fixed in this run:

| Finding | Fix |
|---|---|
| A new file could land in a shared or synced place ticked, and its text was never shown before Apply | New files are guarded like copies arriving there, and the row's tooltip shows the first lines, escaped |
| New files could be scripts or files that run on a routine command | Those names are refused, and code and web pages start unticked |
| A .docx or .odt could be a zip bomb | Helm reads the zip's directory first and refuses one that unpacks to more than 16 MB, packs too tightly, has more than 2,000 parts or is Zip64. Old .doc files aren't read at all |
| AI search across the whole Mac could send files unrelated to the request | The look takes only what the search or the on-device labels matched |
| Pictures were decoded at full size | One decode with ImageIO, at most 1,600 pixels, and nothing past 100 megapixels. Each JPEG is read back and not sent if any metadata is left |
| The home folder was hidden only in its exact spelling | It is written as `~` in any case, Unicode form, percent-encoding or file URL, and a question that still holds it isn't sent |
| A new file's text could hide reading-order or control characters | They're refused |
| Names Windows keeps for devices | Refused |
| Nothing stopped a future change from reading HTML documents, which load what they link to | `privacy_check.py` has a new rule against it |
| A result's reason read as Helm's fact | It says "Model saw:" |
| Files named for secrets, `.env`, `.netrc`, Terraform state and service account keys | Never read for a model and never shown in AI search |
| A QuickTime reference movie could name other videos on the Mac, whose frames would then be sent | Read contents follows no reference: only the file's own frames are read |

## Verified here

All on this Mac, on fixtures, with Helm's windows invisible and its networking blocked by `sandbox-exec`. The scripted model stands in for every provider.

| Check | Result |
|---|---|
| `swift test`, whole suite | 3,234 tests, 0 failures, 1 skipped (run 5: 3,141) |
| `bash scripts/static_checks.sh` | 455 Swift files, 0 errors; privacy check, 460 files, 0 problems |
| Script tests | 59 in `scripts`, 39 in `scripts/rebuild`, all pass |
| Full smoke, Debug | 2,230 checks passed (run 5: 2,140). Three failed, all where the list's Name column is widened by a test hook. Run 5's own commit fails the same three on this Mac now, since an external 1080p display became the main screen during the run, so they come from the display, not from this run |
| Release build (`make_release.sh`, ad hoc) and `check_binary_privacy.sh` | Every check passes, with ImageIO added to the allowed list for Read contents |
| Full smoke on the Release build | 2,228 checks passed (run 5: 2,138). The failures are the known 14-point band (run 3, Open 6) and the same three list-width steps as the Debug run |
| README pictures (`make_readme_images.sh`) | All 24 and both banners taken in the background with the network blocked, all 120 steps passing. The seven that changed were looked at: fixture names only |
| Private data | No names, emails, keys, home paths or real files in the change or its pictures. Every commit is Huseyn's, with no other author line |

## Needs Huseyn's Mac

None of these was verified. Each needs a real provider, real files or a person at a real window.

| Item | Status |
|---|---|
| Each provider taking pictures: Claude, OpenAI with a key, OpenAI through a ChatGPT plan, Gemini, Grok | Not verified |
| Which Ollama and LM Studio models refuse pictures, and the retry without them | Not verified |
| AI search finding a real photo by what it shows, and how long the look takes with 48 files | Not verified |
| Real Word files, and a scanned PDF's page read by a real model | Not verified |
| New RTF and Word files opening in TextEdit, Pages and Word | Not verified |
| The kind row with Spotlight's real index | Not verified |

## Open

1. **The consent wording** is Huseyn's call. The draft is in [`OWNER_RULINGS.md`](OWNER_RULINGS.md#waiting-for-huseyn-run-6).
2. **The reader runs inside Helm.** Apple's readers for PDFs, Word files, pictures and video run in Helm's own process, so a file built to break one of them would reach Helm. Moving them into a separate helper with no access to the network would close that, and is a bigger change than this run. Dropping .doc removed the riskiest of them.
3. **A folder swapped for a link.** Between the plan and Apply, someone with access to the disk could swap a plan's folder for a link to somewhere else, and a new file would be written there. It needs another process running as you, and is low risk.
4. **Speech in video** is not read; only sampled frames are.
5. **From earlier runs:** the Release build's 14-point band under the header ([`MAC_RUN_4.md`](MAC_RUN_4.md#open)).

## Disclosures

- No real key or provider was used. Every picture and check ran on a made-up home folder with invisible windows; Helm was never brought to the front.
- The pictures the model got in these checks were drawn by the fixture scripts.
