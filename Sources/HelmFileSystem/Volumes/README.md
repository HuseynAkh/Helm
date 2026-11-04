<!-- DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04 -->
# K27 volumes and restoration seams

Foundation-only, pure plans; no mount, eject, network connection, restore, deletion,
sharing change or process execution occurs. VolumeRegistry folds an initial unfiltered
VolumeReader.details() snapshot and UI notifications, retaining Core VolumeFilter's
ordering and UUID dedupe (F-031/B-080). Duplicate events produce empty diffs. Unmount
matches the old path; a late rename cannot resurrect a removed mount. Consumers
serialize folds in their owning actor and refresh metadata after uncertain events.
A UUID-less rename is represented as remove/insert. Busy reasons are caller-supplied;
planning does not discover handles or prove that a device is safe to eject.

ServerAddress rejects credentials, queries and fragments, normalizes host/scheme,
default ports and root slash, and maps webdav(s) to http(s). Favorites retain insertion
order, recents retain most-recent-first order; both dedupe and have a configurable cap
(default 20, draft product choice). Record recents only after successful connection.
No credentials, reachability probing, discovery or shares are implemented.

PutBackPlanner accepts exact persisted origins via PutBackOrigin. Duplicate conflicting
origins are refused. Parent absence returns a UI decision offering recreation or choosing
another location; denied/offline parents remain errors. Caller supplies parent state and
occupied names, including dangling links and destinations reserved earlier in a batch.
TrashLocation models home, mounted-volume current-user and explicitly supplied cloud
roots with availability; it never scans another user's trash or guesses origins.

DiskImagePlanner creates hdiutil attach arguments and parses plist mount points; successful
exit without mount points is not mounted. Read-only is the draft default. No password
arguments or credentials are accepted; encrypted images should delegate to system UI.

Needed changes elsewhere: composition root maps TrashOriginStore.records to PutBackOrigin
and updates/removes origins only after successful journaled restoration. UI owns actual
NSWorkspace VolumeEventSource notifications, handle release/eject and connection delegation.
The requested portable VolumeEventSource protocol lives here; architecture's live event
source remains in UI and should use a distinct concrete name. If Core signatures need any
of these types, move the shared values to Core first (review Fix 1); no reverse dependency.
Manifest owner should exclude README.md files to suppress SwiftPM unhandled-file warnings.

Open review: macOS 14/Xcode validation, hdiutil flags/plist fixtures, server URL system
routing, encrypted-image cancellation and rename notification metadata. Live M21/M22
integration and parity gates remain open; these pure tests do not establish live behavior.

Verification: Linux Swift 6.0.3 in Swift 5 mode, scratch `/tmp/build-K27`:
`swift build --scratch-path /tmp/build-K27 --target HelmFileSystem` passed;
`swift test --scratch-path /tmp/build-K27 --filter HelmFileSystemTests` passed 77 tests,
including 23 K27 tests, zero failures. `bash scripts/static_checks.sh`: 184 Swift files,
zero errors. README resource warnings require the manifest owner's exclusions.
No commit, push, network request or live process/volume/archive operation was performed.
