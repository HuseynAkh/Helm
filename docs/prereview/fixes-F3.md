<!-- DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04 -->
# F3 pre-review fixes

All seven findings were reproduced before production edits. `/tmp/F3-before.log`
records 8 failing XCTest cases / 23 assertions across P3-1 through P3-7.
`/tmp/F3-bulk-before.log` additionally records both filesystem bulk cancellation
regressions failing before that adapter was fixed. No existing test was removed or
weakened: the existing write-failure fixture now installs its blocker after load,
so it continues exercising write failure under the stricter read policy.

| ID | Status | Files | Regression coverage | Residual risk |
|---|---|---|---|---|
| P3-1 | FIXED | HelmPersistence/JSONFileStore.swift; F3StoreTests.swift; JSONFileStoreTests.swift | testFailedExistenceProbeDoesNotAuthorizeOverwrite; testPermissionAndIOErrorsRemainReadOnly | Direct ENOTDIR and injected EACCES/EIO; live permission-denial behavior on macOS needs validation. Missing-file errors with non-ENOENT underlying POSIX causes are rejected. |
| P3-2 | FIXED | HelmCore/Presentation/TagStorage.swift; HelmFileSystem/Tags/CompositeTagStorage.swift; F3TagCancellationTests.swift; F3TagBulkTests.swift | Precancelled calls; storage CancellationError stops next write; testCancellationDuringWritePreservesCompletedOutcome | In-progress synchronous mutations cannot be rolled back. Successful completed calls remain successes; unattempted items carry cancellation failures. |
| P3-3 | FIXED | HelmPersistence/JSONFileStore.swift; F3StoreTests.swift | testDirtyReloadPreservesPendingEditAndWritableState; testConcurrentReloadAndReplaceCannotInvalidateStore | Existing void replace API refuses calls during loading; callers must await load. Existing modifiedDuringLoad error reused rather than changing public contracts. |
| P3-4 | FIXED | HelmCore/Imaging/ThumbnailCoordinator.swift; ThumbnailCoordinatorTests.swift | testF3OwnerReleaseCancelsProducerAndFinishesStream | Synchronous deinit safety net fixes released-owner leak; producer must cooperate. Optional public shutdown/host integration deferred below. |
| P3-5 | FIXED | HelmSearch/Query/SearchQueryParser.swift; F3SearchTests.swift | testTypedAndTextExtensionsMatch | Dotted/undotted and uppercase typed/text values match; dot-only rejected. Original editor text retained. |
| P3-6 | FIXED | HelmSearch/SavedSearch/SavedSearchDocument.swift; F3SearchTests.swift | testOversizedEncodingsAreRejected; testDocumentByteBoundaryRoundTrips | JSON/XML exact 1 MiB boundaries round-trip; next byte rejected; escaped strings/large names and Finder replacement tested. Allocation occurs before size rejection. |
| P3-7 | FIXED | HelmSearch/Fallback/EnumerationSearchService.swift; F3SearchTests.swift; SearchListingFixture.swift | testExplicitPackageAndSymlinkRootsAreNotEnumerated | Spy fails on any enumeration of either explicit root. Entry inspection and enumeration are not atomic against external path changes. |

## Needed changes elsewhere

DEFERRED: the proposed public `ThumbnailCoordinator.shutdown()` contract (cancel
and remove all flights, finish continuations, define whether future subscriptions
are refused) and an awaited HelmUI/HelmApp owner-teardown call need contract/host
owner approval and implementation. F3 deliberately adds no public API. The actual
released-coordinator leak is fixed by synchronous teardown. Platform generator
throttling is unchanged and was not one of the seven findings.

No network, external action, commit, push, manifest edit, or legacy-app edit was
performed. All source/test changes are inside the F3 ownership boundaries.

## Verification

Linux Swift 6.0.3 in Swift 5 language mode, scratch `/tmp/build-F3`.
Initial full suite after the seven fixes: 515 tests, 2 skips, zero failures.
Focused expanded regression suite: 23 tests, zero failures.

The first final `run_all.sh` attempt passed all six builds, Python tests, static
checks (194 Swift files), UI parse and report-only coverage, but its XCTest process
crashed with signal 11 during ContractIntegrationTests (no useful symbolic stack).
The crash log is `/tmp/F3-crash.log`. A clean F3 scratch rebuild subsequently passed all 529 tests (2 skipped, zero
failures), consistent with stale incremental artifacts, though the crash cause
was not conclusively established. That run caught an unrelated concurrent edit
to HelmFileSystem/ModuleInfo.swift during its individual module build; no file
outside F3 ownership was edited. Waited 60 seconds before the required retry.

The next complete attempt built all six modules and passed static/Python/UI checks,
but the parallel lane's newly added
`F2SafetyTests.testReplaceAncestorUsesDestinationCaseSemantics` failed two assertions
(530 tests, 2 skips). All F3 cases passed. Saved its log as
`/tmp/F3-outside-lane-failures.log`; left F2 files untouched and waited another
60 seconds before retrying the full verification script.

**Final verification passed:** `/tmp/F3-run-all-retry.log` and `/tmp/build-F3/logs`:
all six explicit module builds; **530 XCTest tests, 2 skipped, zero failures**;
Python tests; static checks; UI syntax parse; report-only coverage. `run_all.sh`
reported **zero failed checks**. Standalone `bash scripts/static_checks.sh` also
passed: **194 Swift files, zero errors**. The F2 test passed on this retry without
any F3 edit to that lane. macOS 14/Xcode and Opus review remain outstanding.
