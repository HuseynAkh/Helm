# DRAFT: pending review, 2026-11-05

AF2b follow-up requires Opus compile-correctness and behaviour-preservation spot-check.

| Finding | Disposition | Evidence |
| --- | --- | --- |
| FB2-3 | FIXED | `Location.canonicalNavigationLocation` constructs directory targets with exactly `URL(fileURLWithPath: url.standardizedFileURL.path, isDirectory: true)`. `TabReducer.stage` uses it before creating pending navigation and emitting the load. `WindowStore.init` missing-tab defaults and bare `.add` defaults use the same helper, so their location, initial snapshot, lastDirectory and address directory agree. Virtual locations are unchanged. |
| FB2-2 (preservation check) | FIXED, preserved | Existing standardized-path same-directory push guard remains in place with its pending-navigation condition. Regression tests confirm unchanged state/history, preserved selection, and no additional load or Recent effect for `/a/b` after `/a/b/`, including the actual address editor validation flow. |
| ItemID lexical/physical owner decision | DEFERRED, unchanged | This lane changes navigation URL spelling only, as explicitly requested. No ItemID implementation or identity policy changed. |

## Contract evidence

Read FB2 review and AF2 fixes, architecture module layout/core contracts and review fixes, current-state/Opus behaviour references, and legacy `Helm/Helm/Models/NavigationState.swift`. Legacy navigation pushes unconditionally; F-005/B-019 dedupe is the rebuild's specified correction.

`DirectoryLoadPipeline.snapshot` passes the requested Location through SnapshotBuilder and PresentationSnapshot. Therefore canonicalizing the request does not require a producer change. `acceptLoad` retains exact Location equality plus generation/loading guards. A regression explicitly rejects a non-echoed raw spelling and accepts the actual emitted canonical request. No public API or global Location equality/Codable changes were needed.

Supplied TabState values and their existing snapshots are preserved by WindowStore. Only store-created default tabs are canonicalized at construction; subsequent staged navigation canonicalizes its target. Back to a supplied unslashed initial tab commits its canonical spelling while retaining selection/history behaviour. Refresh continues to use the committed location and its exact echoed snapshot.

Five existing test files needed directory fixture/expected-value updates: F10MonitorStateTests, F1StateRegressionTests, TabReducerTests, T3NavigationTests and WindowStoreTests. Their synthetic load responses previously used raw unslashed destinations instead of the newly canonical request. They now use directory URLs; behavioural assertions remain intact. WindowStore's Back expectation explicitly allows the canonical spelling, and its missing-tab expectation no longer depends on whether `/home` exists on the host. All changes are within AF2b ownership; no cross-lane producer contract required deferral.

## Verification

Environment: sourced `/workspace/toolchains/env.sh`; Linux Swift 6.0.3, package Swift 5 language mode; isolated scratch path `/tmp/build-AF2b`.

Test-first evidence: before production changes, the initial five AF2bRegressionTests ran with **14 assertion failures**, exposing staged-target and default-tab spelling differences. History/Recent no-op coverage already passed because AF2's path guard works. After implementation, added an end-to-end address validation regression and strict raw-snapshot rejection assertions. Final AF2b coverage: **6 tests, 0 failures** (included in HelmCoreTests).

Final required commands:

- `swift build --target HelmCore --scratch-path /tmp/build-AF2b`: succeeded, 0 errors.
- `swift build --build-tests --scratch-path /tmp/build-AF2b`: succeeded, 0 errors.
- `swift test --scratch-path /tmp/build-AF2b --filter HelmCoreTests`: **690 tests, 0 failures**.
- `swift test --scratch-path /tmp/build-AF2b --filter HelmPersistenceTests`: **81 tests, 0 failures**.

Logs: `/tmp/AF2b-red.log`, `/tmp/AF2b-target.log`, `/tmp/AF2b-build-final.log`, `/tmp/AF2b-core-final.log`, `/tmp/AF2b-persistence-final.log`.

One intermediate build encountered a syntax error in concurrently edited `Tests/HelmOperationsTests/AO2SafetyTests.swift`; waited 60 seconds and retried successfully without touching that file. Existing unhandled README and inaccessible manifest-cache warnings remain nonfatal. An intermediate fixture edit referenced an out-of-scope local variable; corrected before final checks.

Open issues: Opus review and macOS 14/Xcode execution remain pending; Linux results do not establish Apple Foundation runtime behaviour. ItemID ownership remains the pre-existing separate deferral. No unresolved FB2-3 implementation issue. No network, commit, push, deletion, sharing change or external action performed.
