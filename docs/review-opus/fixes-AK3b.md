# DRAFT: pending review, 2026-11-05

## Finding disposition

| Finding | Status | Evidence |
| --- | --- | --- |
| OK2-7 | FIXED in draft | `StoreLocation` now supplies `tag-catalog.json` and `view-options.json` beneath its injected directory, retaining its explicit `public init(directory:)` and all five existing URLs. `AppEnvironment.init`, `live`, and `test` own both stores; `flushStores` attempts all seven documents and collects failures without short-circuiting. `SevenDocumentFlushTests` verifies exactly one attempt per document with no failure and with each of the seven documents failing individually. |

Checked the proposal against current source before implementing: the concrete stores are **HelmPersistence** types at `Tags/TagCatalogStore.swift` and `ViewOptions/LocationViewOptionsStore.swift`, not Core types. Both accept `init(url:) async throws` and expose `flush() async throws`; no missing hook or Core change was necessary. `Sources/HelmCore/Presentation/README.md:67–68` also identifies these Persistence implementations and distinguishes Core's in-memory ViewOptionsStore. AK3's ownership blocker is resolved by this lane's explicit StoreLocation assignment. No finding in this lane is deferred or rejected.

App-specific protocols extend the existing MainActor `AppFlushable` contract and expose the existing editing APIs. Concrete Persistence stores conform directly. Test composition uses memory fakes with no disk/defaults access: tag admission, case-folded identity, metadata suffix preservation and ordering follow TagCatalogStore; view options preserve stable keys, defaults, overrides and the default 256-entry LRU. The three supporting HelmApp files provide the declarations required to compile the new environment dependencies while keeping files small. Existing live migration/load failure behavior is retained. No fallback from a failed live store to a writable memory store was introduced.

## Files

Created:

- `Sources/HelmApp/AppPreferenceStoreContracts.swift`
- `Sources/HelmApp/MemoryTagCatalog.swift`
- `Sources/HelmApp/MemoryViewOptions.swift`
- `Tests/HelmAppTests/SevenDocumentFlushTests.swift`
- `Tests/HelmPersistenceTests/StoreLocationTests.swift`
- `docs/review-opus/fixes-AK3b.md`

Modified: `Sources/HelmPersistence/StoreLocation.swift`, `Sources/HelmApp/AppEnvironment.swift`, `Tests/HelmAppTests/EnvironmentTests.swift`, `Tests/HelmAppTests/LinuxRunner/main.swift`. The environment regressions also verify isolated memory edits, concrete live store types, exact injected document paths, and tag/view edits surviving flush and reload.

## Test-first and verification evidence

All commands ran after `source /workspace/toolchains/env.sh`, using Linux Swift 6.0.3 and Swift 5 language mode, with `/tmp/build-AK3b` exclusively. Logs below are relative to `/tmp/build-AK3b/logs/`.

Before implementation, the new StoreLocation regression failed compilation because `tagCatalog`/`viewOptions` were absent (`red-location.log`). The App regression compilation likewise failed on missing environment members/contracts (`red-app.log`). After implementation, the first Persistence run had 82 tests / 1 failure: the new test compared directory URL values with differing trailing slash forms. The assertion now compares the parent paths, preserving its intended root-containment check. The original run remains in `persistence.log`.

| Final command/check | Result | Log |
| --- | --- | --- |
| `swift build --target HelmPersistence --scratch-path /tmp/build-AK3b` | PASS, 0 errors | `persistence-build.log` |
| `swift build --build-tests --scratch-path /tmp/build-AK3b` | PASS, 0 errors | `build-tests.log` |
| `swift test --scratch-path /tmp/build-AK3b --filter HelmPersistenceTests` | PASS, **82 tests, 0 failures, 0 skips** | `persistence-final.log` |
| Portable HelmApp module compilation with `swiftc -swift-version 5` | PASS, 0 errors | `app-build.log` |
| HelmAppTests LinuxRunner compilation and execution | PASS, **15 tests, 0 failures, 0 skips** | `app-tests-build.log`, `app-final.log` |
| `git diff --check` | PASS | Terminal output |

The App runner follows the existing handoff/AK3 procedure: link the scratch `debug/<Module>.build/*.swift.o` objects for HelmCore, HelmFileSystem, HelmPersistence, HelmOperations, HelmSearch and HelmTestKit into `/tmp/build-AK3b/libF4Dependencies.so`; compile all `Sources/HelmApp/*.swift` into an enable-testing `HelmApp` module/library with `debug/Modules` as its import directory. Then:

```sh
swiftc -swift-version 5 -I /tmp/build-AK3b -I /tmp/build-AK3b/debug/Modules \
  -L /tmp/build-AK3b -lHelmApp -lF4Dependencies Tests/HelmAppTests/*.swift \
  Tests/HelmAppTests/LinuxRunner/main.swift -o /tmp/build-AK3b/HelmAppTests
LD_LIBRARY_PATH=/tmp/build-AK3b:$LD_LIBRARY_PATH /tmp/build-AK3b/HelmAppTests
```

The seven-document regression is explicitly registered in LinuxRunner. Its eight scenarios are one XCTest case, not eight tests. SwiftPM's unrelated trailing Swift Testing banner reports zero tests; the counts above are XCTest suite totals. No tests were disabled. Manifest cache warnings reflect the restricted environment and did not prevent builds or tests.

## Open issues

Opus compile-correctness/behavior spot-check and macOS 14/Xcode compilation remain pending. HelmApp remains undeclared in Package.swift, so Linux App evidence comes from the documented manual runner, not a claimed SwiftPM App target build. Broader OK2 composition/host decisions remain outside this lane. No Core, UI, filesystem, operations, scripts, manifest or legacy app edits were made; no network, publishing, sending, sharing, commits or pushes were performed.
