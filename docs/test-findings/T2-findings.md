<!-- DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04 -->
# T2 adversarial hardening

Five new test files provide 100 independently discoverable XCTest cases:

- `Tests/HelmCoreTests/T2StoreTests.swift`: 26 cases. Eight fixed PRNG seeds each compare 500 interleaved store actions against direct `TabReducer` reduction, including emitted effects and intermediate state. Covers reentrant delivery, shutdown admission, stale load/monitor results, tab isolation, TaskGroup producers, and 100,000 FIFO actions.
- `Tests/HelmFileSystemTests/T2LoadingTests.swift`: 22 cases. Entry and enumeration gates expose cancellation and supersession without sleeps. Covers cumulative batch boundaries, 100,000 entries with duplicate updates, warning/error termination, final-only monitor reloads, root/unmount priority, acknowledgement, and concurrent notification storms.
- `Tests/HelmFileSystemTests/T2DirectoryLoaderTests.swift`: 10 cases. Cache/fresh equivalence, hidden cache partition, permission revalidation, direct-child reconciliation, root rescans, irrelevant paths, precancellation, and virtual-location rejection.
- `Tests/HelmPersistenceTests/T2PreferenceTests.swift`: 35 cases. Tag identity, canonical Unicode, malformed names, atomic rejection, ordering, v0 migration, byte-preserving corruption backup, recovery write rejection, future schema refusal, per-location defaults/LRU/capacity, round trips, and concurrent flushes.
- `Tests/HelmOperationsTests/T2EvidenceTests.swift`: seven cases. Source evidence retirement/retention, verification refusing to invent ownership, and replacement undo restoring exact case/Unicode bytes and both files' contents.

## Integration and limitations

Run with Swift 6.0.3 in the package's Swift 5 language mode, after sourcing `/workspace/toolchains/env.sh`. All builds use `/tmp/build-T2`. No source, existing test, manifest, or script changes belong to this lane. No commit, push, network, publishing, sharing, or paid action was performed.

The requested source README is deliberately represented by these integration notes: the lane permits only new `T2` test files and this findings document. Public APIs remain untouched. The private filesystem fixture refuses mutations and exposes only controlled listing behavior. Tests needing mutation use isolated in-memory storage or uniquely named temporary preference documents, with teardown confined to those documents.

Cancellation gates cover both externally controllable pipeline await boundaries (root metadata lookup and stream enumeration). Actor-internal snapshot publication is not exposed for a deterministic gate; stale-generation reducer checks cover retired results at delivery. Native filesystem race windows, AppKit, and macOS/Xcode behavior require later review. Seeded equivalence checks establish store orchestration equivalence, while independent assertions cover reducer-visible invariants; they do not claim an independent specification of the reducer itself.

## Validation and needed changes elsewhere

Final Linux validation: all 100 T2 tests passed, zero failures, in 8.93 seconds. Explicit builds of HelmCore, HelmFileSystem, HelmPersistence, and HelmOperations passed. The focused lexical check passed all five T2 files with zero errors. No reproducible production bug was found in these cases, so no test was quarantined; this is not a claim that the audited modules are bug-free.

Commands: `swift build --scratch-path /tmp/build-T2 --target <Module>` for each module above, and `swift test --scratch-path /tmp/build-T2 --filter T2`. No broader suite or macOS build is claimed.

Initial cross-lane compile failures referenced K34 conditional-mutation APIs before their implementation landed. A later linker failure retained the previous `FileEntry` initializer ABI in cached objects; after the prescribed 60-second wait the T2 scratch build was cleaned and rebuilt.

The mandatory `bash scripts/static_checks.sh` currently reports two existing forbidden `try!` uses in `Sources/HelmCore/Naming/UniqueNamer.swift` (lines 25 and 34). These are outside T2 ownership. The script checks production sources by default; its dependency-DAG policy is not designed for test-target names. T2 files therefore also receive a focused lexical check with test imports allowed, plus authoritative Swift compilation.
