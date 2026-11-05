<!-- DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04 -->
# T1 adversarial test hardening

All changes are draft pending Opus compile-correctness and behaviour-preservation review after 22:00 Toronto on November 4, 2026. No production source, existing test, manifest, script or old app file was edited by T1.

## Integration notes

Five new T1-prefixed Swift files add 102 XCTest methods: 37 content, 20 drag/drop, 25 archive/volume, and 20 search tests. `T1PermutedListingFixture.swift` is a test-only FileSystem adapter. It forwards operations to an in-memory filesystem and permutes enumeration with a fixed seed while preserving metadata. It performs no real filesystem mutations or network requests.

Coverage includes empty/single-item inputs, UTF-8 name limits and UTF-16 rename ranges, stale sessions, cancellation, exact geometric boundaries, exhaustive tab reorder slots, rename retries, canonical archive path collisions, UInt64 overflow, server normalization round trips, volume event idempotence, criteria serialization, search budgets, cumulative stream prefixes and deterministic traversal. Scale cases exercise 100,000 selection IDs, grid geometry over 100,000 items, and archive validation of 100,000 members. Seeded selection and grid tests compare results against independently computed oracles.

Behaviour references: F-007 (activation/archive delegation), F-031/F-060 (volumes/origins), F-035/F-038/F-039/F-041 (content and selection), F-043–F-046 (search), F-054 (rename), F-067 (drag/drop); B-009/B-011/B-101 (selection identity/scale), B-021 (search cancellation), B-026 (truncation), B-040/B-045 (drop intent), B-046/B-066 (rename validation/selection).

The column tests use K29's new `ColumnLoadRequest` API. Initial test compilation encountered an existing F1 rename test mid-edit; T1 waited 60 seconds and retried without modifying that file. The subsequent compilation succeeded.

An initial search determinism test created two filesystems in different creation orders. That changes InMemoryFileSystem modification dates, which legitimately affect ranking. This was a test-fixture defect, not a production finding. The corrected test changes delivery order only, preserving identical metadata.

## T1-001: Put Back origin validation depends on duplicate record order

Status: reproduced; quarantined with `XCTSkipUnless(ProcessInfo.processInfo.environment["T1_RUN_BUGS"] == "1", ...)`.

Test: `T1ArchiveVolumeAdversarialTests.testPutBackMixedAuthorityOriginsFailClosedRegardlessOfOrder`.

Reproduction: pass item `file:///trash/a` with two matching origin records. One records `file:///original/a`; the other records `file://remote/original/a`. Both records refer to the same trashed item. Invoke `PutBackPlanner.plan` with `.exists` for the parent, then reverse the records and repeat.

Expected: fail closed with `.invalidPath` for either ordering because one matching origin is a remote file URL that the planner otherwise rejects. At minimum, the decision must not depend on record order.

Actual: local-first produces `.restore(source: file:///trash/a, destination: file:///original/a)`; remote-first produces `.invalidPath`. The planner deduplicates destinations using only `.path`, losing the authority distinction, then validates only `records.first.originalURL`.

Suggested fix (outside T1 ownership): validate every matching record's original URL before reducing to a destination path; reject invalid/remote origins consistently, then perform ambiguity detection on validated canonical local destinations. Add the regression to normal execution once resolved. The test invokes only the pure planner; it does not restore anything.

Reproduce explicitly:

```sh
source /workspace/toolchains/env.sh
T1_RUN_BUGS=1 swift test --scratch-path /tmp/build-T1 --filter T1ArchiveVolumeAdversarialTests.testPutBackMixedAuthorityOriginsFailClosedRegardlessOfOrder
```

## Verification

- Linux Swift 6.0.3, package Swift 5 mode, isolated scratch directory `/tmp/build-T1`.
- Target builds: HelmCore, HelmFileSystem, HelmSearch.
- Explicit bug-enabled T1 run: 102 tests executed; 101 passed, one intentional failing regression (T1-001).
- Normal run: `swift test --scratch-path /tmp/build-T1 --filter 'HelmCoreTests|HelmFileSystemTests|HelmSearchTests'` passed: 534 tests, one quarantined test skipped, zero failures (13.365 seconds). This includes all 102 T1 methods: 101 pass and T1-001 skips by default.
- `bash scripts/static_checks.sh`: 196 production Swift files, zero errors. The stock script scans Sources only; an additional direct invocation of its lexical checker over the five T1 Swift files, with test-target import dependencies supplied, also reported zero errors.
- All three requested target builds completed with zero errors. Nonfatal SwiftPM cache warnings reported an unavailable manifest-cache database; they did not prevent builds or tests.

## Open questions and deviations

- Needed changes elsewhere: fix T1-001 in `Sources/HelmFileSystem/Volumes/PutBackPlanner.swift`; T1 cannot edit Sources.
- No source README was added: T1's explicit ownership allows only new T1-prefixed test files and this findings document. Integration notes and deviations therefore live here.
- Shared brain/network context was not fetched because this lane explicitly prohibits network access.
- macOS 14/Xcode execution and Opus review remain outstanding; Linux results do not establish native adapter behaviour.
