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

## F2 mutation-safety integration

DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04.
IOExecutor cancels queued work without starting it; once begun, native work returns
its real result despite cancellation. A timeout still quarantines the volume and
requires external reconciliation. Cancellation is therefore not a prompt-return
promise for blocking native calls.

Live enumeration now terminates with an error on any child metadata failure;
already-delivered batches are partial and must not be treated as a completed
snapshot. The diagnostic callback is still invoked. This conservative policy also
protects childNames, planning manifests and copy verification without adding a new
public strict-listing contract. A distinct permissive UI stream with explicit
warnings is deferred to contract review.

Failed exclusive writes retain their artifacts. Never unlink a failed write by
pathname: another writer may have replaced it. Reconciliation must inspect actual
paths. Internal syscall/metadata seams are test-only injection points, not new
public APIs. Archive root directory markers are accepted only with no payload;
confined runners must ignore their metadata and continue enforcing runtime budgets.
Native timeout recovery, coordinated mutations and macOS behavior need Opus review.
