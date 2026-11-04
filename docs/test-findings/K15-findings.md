<!-- DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04 -->
# K15 test findings

## BUG-K15-1 — valid case-sensitive copy/move rejected

- Tests: `K15CaseSensitiveTransferTests.testCopyBetweenCaseDistinctDirectories` and `testMoveBetweenCaseDistinctDirectories`.
- Source: `Sources/HelmOperations/Execute/OperationExecutor.swift:96` (also lines 97–98).
- Diagnosis: the executor unconditionally folds source and destination case, rejecting distinct `/a/file` and `/A/file` even when the planning context and filesystem explicitly declare case sensitivity.
- Protects F-052 / B-039. Both reproductions produced `.invalidPlan` and left the destination missing on Linux Swift 6.0.3 before being skipped.
- Expected: an executable copy/move plan between these separate directories completes; copy retains its source, move removes its source, and the destination retains the payload size.
- Both tests use `try XCTSkipIf(true, "BUG-K15-1: ...")`; remove the skip after the source owner fixes the comparison. Production sources were not changed.

## Needed changes elsewhere

HelmOperations owner: make the executor's source/destination equality and ancestry checks honor filesystem case semantics while retaining recursive-destination protection. Opus should review differing source/destination volume semantics; do not merely remove the guard.

## Verification

Final counts and commands are recorded below after verification. No network, commits, external actions, or source edits were performed by K15.

Final verification (Linux Swift 6.0.3, scratch directory `/tmp/build-K15`):

- Added 84 XCTest methods across seven new Swift test files: AddressBar 27, State 16, Operations 26, FileSystem 15. Each method cites its protected F/B audit item.
- K15: 82 passed, 2 skipped for BUG-K15-1; one distinct source bug found.
- Full portable suite: 352 executed, 3 skipped, 0 failures, 10.267 seconds. The third skip is the existing `K13PlacesTests.testStarredFolderHighlight` / BUG-K13-1, outside this lane.
- `swift build --scratch-path /tmp/build-K15 --target HelmCore`: passed.
- `swift build --scratch-path /tmp/build-K15 --target HelmFileSystem`: passed.
- `swift build --scratch-path /tmp/build-K15 --target HelmOperations`: passed.
- `swift test --scratch-path /tmp/build-K15 --filter 'HelmCoreTests|HelmOperationsTests|HelmFileSystemTests|HelmSearchTests|HelmPersistenceTests|HelmTestKitTests'`: passed, covering every declared portable test target.
- `bash scripts/static_checks.sh`: 135 Swift files, 0 errors.
- SwiftPM reports inaccessible user caches and unhandled README files; no compilation errors. The manifest owner may exclude `Tests/HelmOperationsTests/README.md` to silence that resource warning. K15 did not edit Package.swift.

New files: `Tests/HelmCoreTests/AddressBarTests/K15AddressAdversarialTests.swift`,
`Tests/HelmCoreTests/AddressBarTests/K15CompletionCancellationTests.swift`,
`Tests/HelmCoreTests/StateTests/K15StateAdversarialTests.swift`,
`Tests/HelmOperationsTests/K15OperationAdversarialTests.swift`,
`Tests/HelmOperationsTests/K15ReplacementBoundaryTests.swift`,
`Tests/HelmOperationsTests/K15CaseSensitiveTransferTests.swift`,
`Tests/HelmFileSystemTests/K15FileSystemAdversarialTests.swift`,
`Tests/HelmOperationsTests/README.md`, and this findings file.

Limits: Opus compile/behaviour review after 22:00 Toronto and macOS 14/Xcode validation remain pending. The generated scenarios are deterministic and bounded, not exhaustive filesystem interleavings. In-memory payload preservation is checked by size and identity because the fake exposes no byte-reading API. Failure injection covers every primitive boundary of replacement moves and every item boundary of creation; it does not simulate every possible failure inside native kernel operations.
