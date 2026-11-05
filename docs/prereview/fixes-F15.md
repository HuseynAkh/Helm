# F15 — module documentation reconciliation

DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04

Documentation only. Applied all six groups under F12's “README edits to apply
later” and reconciled module notes with waves 12–18. Historical slice counts remain
historical; the current portable suite is **1001 tests**, verified below. No source,
test code, Package.swift, scripts, legacy Helm files, commits, network requests or
external actions were changed/performed.

## Changes and checked evidence

| Documentation | Reconciliation | Source/test evidence |
| --- | --- | --- |
| `Sources/HelmOperations/README.md` | F12 provider-dependent directory Move/Trash and completed Core/conditional prerequisites; K23 case/collision contracts; F13 journal-owned inverse evidence and clean versus uncertain cancellation | FileSystem defaults, Live exclusive primitives, ForwardEvidence, OperationExecutor, UndoPlanner; K34 conditional/atomic tests and F13ContractTests/F13UndoEvidenceTests/F13CancellationTests |
| `Sources/HelmCore/Store/README.md` | Required asynchronous reload/validation handles; synchronous/host-owned nil guidance; shared request stamping, validation priority, retirement and reactivation | WindowStore, TabReducer/TabNavigation; K34MonitorLifecycleTests, F10MonitorStateTests, F14MonitorOrderingTests |
| `Sources/HelmFileSystem/Loading/README.md` | Serial off-main sorted-input indexing, cancellation boundaries, three-attempt watch recovery and degraded-state reporting | MonitorSnapshotWorker, DirectoryEffectRunner; F10SnapshotWorkerTests, F14MonitorRecoveryTests |
| `Sources/HelmFileSystem/Monitor/README.md` (created) | Fallback termination, root revalidation and fresh-watch lifecycle; native acceptance remains open | FallbackMonitor, DispatchSourceMonitor, FSEventsMonitor; MonitorAndCacheTests and F14MonitorRecoveryTests |
| `Sources/HelmPersistence/README.md`, `Tags/README.md`, `ViewOptions/README.md` | K33 stores exist; one owner/document, explicit flush, original/backup retention and read-only corruption recovery; separate icon ranges/defaults | TagCatalogStore, LocationViewOptionsStore, PreferenceDocumentFile; K33 store/document tests and K34ViewDefaultsTests |
| `Sources/HelmCore/Inspector/README.md` | Effective permission drafts, original-mode reversion, unknown-selection metadata and pure-plan limits | InspectorEditModel/PermissionsModel; InspectorEditModelTests and T3 Inspector/Permission tests |
| `Sources/HelmCore/Accessibility/README.md` | Package and directory raw metadata sizes omitted; independent expected-kind regression and native/localization limits | RowDescription; AccessibilityTests and T3AccessibilityTests |
| `Sources/HelmUI/README.md`, `Sheets/README.md` | K34 supersedes P7-2 deferral; one active/latest pending worker, cooperative cancellation and cache guards; configured runner recipe and historical K12/K16 evidence | BatchRenameSheet/Worker/ViewModel, Core cancellable planner; K34CancellationTests, K34BatchRenameWorkerTests; configured portable runner |
| `Sources/HelmCore/AddressBar/README.md` | Both stale minimal-contract requests replaced by K23 completion and remaining host work | Contracts/AddressContracts.swift and AddressEditor contracts |
| `Sources/HelmFileSystem/README.md` | K23 cloud/listing/stamping/editor prerequisites completed; current loading/monitor/provider pointers | MetadataReader, CloudAvailabilityReader, SnapshotStamp and Core contracts |
| `Sources/HelmCore/Presentation/README.md` | Filesystem tag adapters and persistent K33 owners already exist; Core store remains in-memory | TagStorage adapters, ViewOptionsStore and persistence stores |
| `Sources/HelmCore/README.md`, `Tests/HelmOperationsTests/README.md` | Current component inventory, ownership/cancellation contracts and named F13 evidence | Corresponding implementations and regressions above |

F12's exact required meanings are retained, with wrapped prose and additional
F13/F14 details. Earlier findings are not recounted as new defects. No passing fake
operation test is presented as evidence that native executor copy/move/Trash works.

## Verification

All Swift commands sourced `/workspace/toolchains/env.sh`; Swift 6.0.3, Swift 5
language mode, isolated `/tmp/build-F15`.

- `swift build --scratch-path /tmp/build-F15 --target HelmFileSystem`: PASS,
  including Core; `/tmp/F15-build.log`.
- `swift test --scratch-path /tmp/build-F15 --filter 'Helm(Core|FileSystem|Persistence|Operations|Search|TestKit)Tests'`:
  **1001 tests, 0 failures, 0 skips**; `/tmp/F15-tests.log`.
- `HELM_UI_SCRATCH=/tmp/build-F15 python3 -B Tests/HelmUITests/PortableRunner/run.py`:
  **53 portable UI/App tests, 0 failures**; `/tmp/F15-ui.log`. This is separate
  from the 1001-test package count and excludes native SwiftUI/AppKit tests.
- `bash scripts/static_checks.sh`: PASS, **222 Swift files, 0 errors**;
  `/tmp/F15-static.log`.
- Scoped `git diff --check`: PASS. No tests were added, removed or weakened.

## Review limits and remaining work

The F14 held-reply test asserts that stale replies preserve the snapshot captured
after validation, but does not independently assert that this captured snapshot
contains the expected fresh entries/failure. In isolation it could pass if both
validation and stale replies were dropped. F14's separate recovery integration test
checks successful publication. The README therefore describes the held-reply test
as ordering evidence, not complete validation-acceptance proof. No test edit is
made in this documentation lane; reviewers can strengthen that focused assertion.

Native conditional mutation and atomic output receipts remain missing; root
identity/token evidence cannot prove descendants or same-object/same-token content
changes. Monitor native root replacement, retry/degraded UI, persistent-store host
wiring, Inspector execution, VoiceOver and hosted rename dismissal/responsiveness
remain acceptance work. macOS 14/Xcode compile correctness and behavior preservation
still require Opus review after 22:00 Toronto. Linux results do not close those gates.

Created only the Monitor README and this report; updated 15 existing README files.
