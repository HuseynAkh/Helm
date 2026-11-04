<!-- DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04 -->
# K9 integration notes

VolumeReader.details() returns unfiltered VolumeDetails. Existing hidden,
browsable, removable and internal flags live in its VolumeInfo; isEjectable is
optional because missing metadata must not imply permission to eject. volumes()
retains the existing filter/sort path. Linux returns only the synthetic root;
its existing flags are fallback policy, and ejectability is unknown.

CloudAvailabilityReader inspects ubiquitous metadata on the I/O executor, never
contents and never requests downloads. Non-ubiquitous or unreported metadata is
unknown (third-party File Providers are not proven local). Linux always returns
unknown, even for missing paths. macOS metadata errors propagate. Validate the
Apple-only resource keys and real cloud transitions on macOS/Xcode during review.

SnapshotStamp is a standalone value for an accepted ID and a load generation.
The reducer must allocate the per-tab accepted ID; it is not a presentation
snapshot and does not change DirectoryLoader's array return contract.

Needed changes elsewhere: K1 needs shared presentation-snapshot stamping integration
and FileEntry cloud availability before these helpers can enter Core signatures.
Core must own any such shared types; do not make Core depend on this module.
Location still needs Starred; PlaceDestination.resolved preserves its intent now.
AddressEditor contract replacement requires Contracts/AddressContracts.swift.

No runtime integration of cloud metadata into listings is attempted in this fix
lane. This avoids changing enumeration cost or the existing FileEntry contract.

Verification (Linux Swift 6.0.3, Swift 5 mode): HelmFileSystem target build passed;
all six XCTest targets selected explicitly, 98 tests passed, zero failures;
static checks passed, 98 production Swift files, zero errors. Scratch path:
/tmp/build-K9. macOS validation remains pending Opus after 22:00 Toronto.
