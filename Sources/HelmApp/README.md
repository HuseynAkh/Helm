<!-- DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04 -->
# K22 composition glue

Portable draft for M10 A6, with M4/M25 migration ordering. No AppKit or SwiftUI
code is required for this slice. All files remain pending Opus review.

Create one `AppEnvironment.live` per application, after buffering external requests.
Pass explicit Home/Application Support/volume roots, `UserDefaultsAdapter`, and
`LegacyUserDefaultsReader`. Migration completes before settings defaults register;
errors propagate to the launch host. All windows retain the same environment.
The journal is shared across tabs/windows and currently in-memory, as provided by
HelmOperations. `.test()` uses only in-memory stores, settings, and filesystem;
inject a HelmClock for deterministic dates. Mutations accept explicit dates.

`AppStoreContracts` are local seams because persistence's final store classes
cannot use an injected memory backend. Live instances are the actual persistence
stores; memory stores implement the subset needed by composition. They publish
Foundation Broadcast snapshots. SettingsStore is used directly with memory key/value
storage. This is not a replacement persistence implementation for production.

Resolve URL metadata outside `LaunchRouter`; feed folder/file/unavailable values
in arrival order. Before readiness, receive returns nil and buffers. Finish launch
once after composition: requests override restoration, which overrides default
Home. Each accepted request produces a window in input order, with the first URL
in the first window's actual tab contents. A file selects itself in its parent.
All-invalid requests produce rejections and no Home/restore windows; show the error
and reply failure. Later requests create windows with unused frame names. Preserve
router state for the application lifetime. New-window commands must coordinate
frame names with the same host allocation authority.

`SessionRestorePlan` consumes the existing `[SessionWindow]` payload (there is no
SessionRecord type). It preserves tab mode/sort/hidden preference and selected tab,
repairs empty tabs and duplicate/empty frame names, preserves virtual locations,
and replaces unavailable folders with Home plus `unavailableLocation` for a status
note. Availability is a caller-supplied snapshot, not synchronous filesystem I/O in
the reducer. Home itself is the fallback, even if temporarily inaccessible.

`WindowRegistry` tracks creation order independently from activation order. The
first window remains the first registered surviving ID; frontmost and close order
use most-recent activation. Controllers/observer tokens stay in the macOS host.
Dock reopen visibility comes from AppKit; closing the last window does not quit.

For quit, stop accepting operations and persistence edits, snapshot sessions, and
feed the current in-flight count to `QuitCoordinator`. Wait for completion before
`flushStores()`. That method attempts all seven JSON stores (bookmarks, stars, recent, session, trash origins, tag catalogue and view options), collecting failures. Read-only corruption recovery refuses edits and has nothing to save, so that error alone is ignored at this application boundary; original bytes and backups remain intact. Both preference protocols expose `isReadOnly` and `recoveryBackupURL` for recovery UI. Real I/O failures remain quit blockers pending OK2-29.
SettingsStore writes immediately and exposes no flush API. Reply terminate only
after a successful flush; show errors and allow retry or cancellation otherwise.
The host owns operation counts; journal entries do not establish executor liveness.
Cancellation during flushing is deliberately disabled to avoid stale completion.

`AppEnvironment+Privacy` keeps only what Settings allows. Call `followPrivacySettings()`
once after launch. With Reopen windows and tabs off, session.json is deleted, and
`saveSession(_:)` keeps nothing. With Remember recent items off, Recent and the apps
used for each kind of file are cleared. `forgetItemsGoneFromTrash()` runs after launch,
off the launch path. It drops the record of a trashed item that's gone from a Trash
that's still there, and keeps records for a Trash it can't reach, such as an unplugged disk.
Every environment forgets a starred item's or bookmark's row in sidebar.json when the star
or bookmark goes, however it goes. A rename or a move updates the layout before the stores,
so a row that only moved isn't forgotten. `live` also drops rows an earlier Helm kept for
stars and bookmarks already gone, but only when no document failed to load. A damaged file
that a store set aside as .corrupt-… and started over counts as read, so its rows go too.
A drive's row stays while the drive is unplugged.

## Needed changes elsewhere / review questions

- Manifest owner adds HelmApp/HelmAppTests on macOS; staged patches linked below. No manifest edits
  were made by K22. The Linux runner directory must be excluded from the test target.
- UI's proposed WindowDependencies uses concrete stores. Adopt these seams in the
  host adapter or pass the live concrete instances with a checked cast; do not create
  another store per window. Search/executor/menu wiring belongs to host integration.
- Implement one external-open delegate API and its success/failure reply (B-114).
  Route initial contents before showing a window (B-018/B-103).
- Confirm the intentional requested policy: files reveal in parent (legacy launched
  the default app), multiple requests create ordered windows (legacy reused first).
- Session schema has no selection/history/scroll/expanded-row payload. Persisting
  those, screen-frame clamping, observers, UI focus, native-tab disabling and actual
  termination replies remain macOS integration work. Do not call center after frame
  restoration. No macOS SDK/Xcode validation is claimed.

Use the [staged Mac manifest patches](../../docs/handoff/MAC_HANDOFF.md) after explicit owner assignment.
Tools 5.9, Swift 5 and macOS 14 remain required; this note grants no ownership.

## Linux verification outside the manifest

Run from the worktree root. `swift test --filter HelmAppTests` cannot discover an
undeclared target; instead these commands compile and execute the actual XCTest
classes using the small checked-in XCTMain runner. Disk round-trip tests write only
unique `/tmp/K22-*` fixtures and intentionally leave them intact (no deletion).

```bash
set -e
source /workspace/toolchains/env.sh
swift build --scratch-path /tmp/build-K22 --target HelmOperations
swift build --scratch-path /tmp/build-K22 --target HelmPersistence
swift build --scratch-path /tmp/build-K22 --target HelmSearch
swiftc -typecheck -swift-version 5 -I /tmp/build-K22/debug/Modules Sources/HelmApp/*.swift
swiftc -emit-library -emit-module -enable-testing -module-name HelmApp -swift-version 5 \
  -I /tmp/build-K22/debug/Modules Sources/HelmApp/*.swift \
  /tmp/build-K22/debug/{HelmCore,HelmFileSystem,HelmPersistence,HelmOperations}.build/*.swift.o \
  -o /tmp/build-K22/libHelmApp.so -emit-module-path /tmp/build-K22/HelmApp.swiftmodule
swiftc -typecheck -swift-version 5 -I /tmp/build-K22 -I /tmp/build-K22/debug/Modules Tests/HelmAppTests/*.swift
swiftc -swift-version 5 -I /tmp/build-K22 -I /tmp/build-K22/debug/Modules \
  -L /tmp/build-K22 -lHelmApp Tests/HelmAppTests/*.swift \
  Tests/HelmAppTests/LinuxRunner/main.swift -o /tmp/build-K22/HelmAppTests
LD_LIBRARY_PATH=/tmp/build-K22 /tmp/build-K22/HelmAppTests
bash scripts/static_checks.sh
```

## F4 frame identity repair

SessionRestorePlan reserves all nonempty saved frame names before allocating any
repair, so an earlier empty/duplicate name cannot steal a later window's frame.
The first occurrence of a valid name is preserved; repairs remain unique. New
FrameIdentityTests exercise both reported displacement sequences and tab ownership.
The UI PortableRunner also runs these app tests without duplicate dependency type
metadata. macOS frame restoration behaviour still requires hosted verification.
