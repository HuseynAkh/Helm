# K3 AddressBar draft

Draft pending Opus compile-correctness and behaviour review after 22:00 Toronto,
2026-11-04. Only this directory and Tests/HelmCoreTests/AddressBarTests are owned.

Integration:
- AddressEditorState / AddressEditorAction should replace K1's minimal
  AddressBarState / AddressBarAction in Contracts/AddressContracts.swift when the
  orchestrator integrates. CompletionRequest is reused unchanged.
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

Review conflict: review Fix 60 requires 50 total rows including '..', while the
actual old source and revised architecture specify 50 children plus '..' (51).
This implementation follows the user's explicit review-wins rule: 50 total.
Tests pin that choice for Opus to resolve. Tilde is preserved on acceptance as
requested by Fix 60/revised F-023; absolute/relative acceptance uses canonical
candidate casing. The old app expanded tilde on acceptance.

No network, external action, commit, push, or edits to the old Helm app.

Final Linux verification (Swift 6.0.3, Swift 5 language mode):
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
