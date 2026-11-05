<!-- DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04 -->
# K3 AddressBar draft

Draft pending Opus compile-correctness and behaviour review after 22:00 Toronto,
2026-11-04. Only this directory and Tests/HelmCoreTests/AddressBarTests are owned.

Integration:
- K23 already replaced the minimal AddressBar contracts with
  AddressEditorState/AddressEditorAction in HelmCore; Contracts/AddressContracts.swift
  retains CompletionRequest. CompletionRequest is shared. Do not introduce duplicate
  types; native address controller, completion debounce and IME/focus wiring remain
  host work.
- Execute requestCompletions via PathCompletionEngine and a DirectoryListing
  adapter. Return completions/completionFailed with the request generation.
  Prefix debounce belongs in the adapter; slash requests have zero debounce.
  The engine intentionally has no cache, so slash requests always re-list.
- Listing supplies hidden metadata and symlinkTargetIsDirectory. Symlink rows
  retain the link's path while drilling as directories. No filesystem calls run
  in the reducer. Enumeration errors propagate instead of masquerading as empty.
- Execute validate off main; return validated with the same URL and generation.
  Directory symlinks validate as directories, ordinary files as files, missing
  or inaccessible targets as invalid. Only then execute navigate/openFile.
- invalidPathFeedback requests the UI beep/shake. error retains the error message;
  invalid text stays editable. cancel covers outside clicks and intentional focus
  transfers. The UI remains responsible for text-storage/focus survival, caret
  reporting, consuming Tab/Backtab, popup layout and icon loading.
- Paste supplies the entire field string after native text selection replacement;
  it neither reads nor changes the system pasteboard.
- Current-directory and Home are injected. Virtual locations should inject Home
  as currentDirectory. Current-user '~' and '~/' are supported without I/O;
  named-user '~someone' lookup is not performed by this pure parser.

K9 correction: F-017 caps sorted, filtered children at 50, then prepends '..'
for slash browsing outside root (51 rows maximum). Root has no parent row.
Nonpositive custom limits disable completion rows. The user's explicit correction
supersedes review Fix 60's incorrect cap wording. Tilde is preserved on acceptance as
requested by Fix 60/revised F-023; absolute/relative acceptance uses canonical
candidate casing. The old app expanded tilde on acceptance.

No network, external action, commit, push, or edits to the old Helm app.

Prior K3 Linux verification (Swift 6.0.3, Swift 5 language mode):
- `swift build --scratch-path /tmp/build-K3 --target HelmCore`: passed.
- `swift test --scratch-path /tmp/build-K3 --filter HelmCoreTests`: 55 tests,
  zero failures, including all 24 K3 tests.
- `bash scripts/static_checks.sh`: 76 production Swift files, zero errors.
- macOS/Xcode compilation and UI behaviour remain pending Opus/Mac review.

Earlier parallel-lane compile failures cleared on retry without changes from K3.
An isolated scratch package also verified 23 K3 tests before the final additional
re-entry/hidden-setting test. The final root test run above is authoritative.
SwiftPM warns that this handoff Markdown is unhandled; K3 cannot add a manifest
exclusion because Package.swift is owned by K1. Cache-directory warnings reflect
the restricted workspace permissions. Neither warning prevents build or tests.

K9 verification: the full six-target XCTest selection passed 98 tests with zero
failures using /tmp/build-K9; HelmFileSystem target build passed (including Core).
Static checks passed for 98 production Swift files. K23 subsequently completed the AddressEditor contract replacement described above;
native controller/debounce/IME/focus integration remains host work.
