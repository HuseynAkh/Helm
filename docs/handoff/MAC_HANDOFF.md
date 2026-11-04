<!-- DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04 -->
# Mac handoff — K30 refresh

Snapshot: 2026-11-04, root package on `forge/rebuild-build`. Parallel K29/T1 work can change this inventory; freeze revision plus dirty diff before review. All code is draft pending Opus review after 22:00 Toronto. No gate closes merely because time has elapsed. Final K30 opt-in portable run: 650 cases, 0 skips, 0 failures. See [VERIFICATION.md](VERIFICATION.md) for current evidence and historical counts; citation coverage is not feature acceptance.

The root [Package.swift](../../Package.swift) is authoritative for actual membership. `Helm/` is the untouched legacy behavior reference. External planning files are under `/workspace/forge/helm-plan/docs/rebuild` on this machine; set `PLAN_DIR` to the owner's supplied local equivalent on Mac. `review-01-architecture.md` fixes win over `01-architecture.md`, especially public type homes, contracts, Linux guards and explicit public initializers (Fixes 1/5/8/9). No network fetch is authorized, including shared GitHub memory.

## Actual module layout

All directory names below are inventoried from `Sources/`; `(root)` means Swift files directly in the module. README files are integration notes, not build resources. The six portable modules and their matching `Tests/<Module>Tests` targets are enabled. UI/App directories exist but their targets remain disabled. `Sources/Helm`, `Sources/HelmApp/macOS`, a rebuilt root project and automation target are absent at this snapshot.

| Module | Actual source directories | Manifest status |
|---|---|---|
| [HelmApp](../../Sources/HelmApp/) | `(root)` | Disabled; Mac template only |
| [HelmCore](../../Sources/HelmCore/) | `AddressBar`, `Commands`, `Content`, `Contracts`, `DragDrop`, `Identity`, `Imaging`, `Model`, `Naming`, `OpenWith`, `Places`, `Presentation`, `Search`, `Settings`, `State`, `Support`, `Text` | Enabled portable library + XCTest target |
| [HelmFileSystem](../../Sources/HelmFileSystem/) | `(root)`, `Archive`, `Fake`, `Live`, `Monitor`, `Protocol`, `Providers`, `Tags`, `Virtual`, `Volumes` | Enabled portable library + XCTest target |
| [HelmOperations](../../Sources/HelmOperations/) | `(root)`, `Clipboard`, `Execute`, `Journal`, `Plan`, `Undo` | Enabled portable library + XCTest target |
| [HelmPersistence](../../Sources/HelmPersistence/) | `(root)` | Enabled portable library + XCTest target |
| [HelmSearch](../../Sources/HelmSearch/) | `(root)`, `Engine`, `Fallback`, `Query`, `Rank`, `SavedSearch` | Enabled portable library + XCTest target |
| [HelmTestKit](../../Sources/HelmTestKit/) | `(root)`, `Fixtures` | Enabled portable library + XCTest target |
| [HelmUI](../../Sources/HelmUI/) | `Content`, `Operations`, `Properties`, `SearchBar`, `Settings`, `Sheets`, `Sidebar`, `Status`, `TagDots`, `Tags`, `Toolbar`, `ViewOptions` | Disabled; Mac template only |

## Apple SDK compilation inventory: NOT RUN

No Apple SDK compilation evidence is available for **any** file listed below. “Never compiled” here means never established by the supplied repository evidence, not a claim about unknown machines. Portable model execution and `swiftc -parse` do not validate Apple branches. Every file under HelmUI is listed, including README integration inputs (not compilation units). HelmApp is currently portable composition glue; `Sources/HelmApp/macOS/` has **no files** to list and its native host is missing.

- `Sources/HelmUI/Content/ColumnBrowserView.swift`
- `Sources/HelmUI/Content/ContentLeafPresentation.swift`
- `Sources/HelmUI/Content/ContentOverlays.swift`
- `Sources/HelmUI/Content/GridCellView.swift`
- `Sources/HelmUI/Content/InlineRenameField.swift`
- `Sources/HelmUI/Content/ListRowView.swift`
- `Sources/HelmUI/Content/README.md`
- `Sources/HelmUI/Operations/OperationDetailCache.swift`
- `Sources/HelmUI/Operations/OperationDetailsView.swift`
- `Sources/HelmUI/Operations/OperationRowModel.swift`
- `Sources/HelmUI/Operations/OperationsPanel.swift`
- `Sources/HelmUI/Part3-README.md`
- `Sources/HelmUI/Properties/PropertiesView.swift`
- `Sources/HelmUI/Properties/PropertiesViewModel.swift`
- `Sources/HelmUI/README.md`
- `Sources/HelmUI/SearchBar/SearchBarModel.swift`
- `Sources/HelmUI/SearchBar/SearchBarView.swift`
- `Sources/HelmUI/Settings/AdvancedSettings.swift`
- `Sources/HelmUI/Settings/GeneralSettings.swift`
- `Sources/HelmUI/Settings/SearchSettings.swift`
- `Sources/HelmUI/Settings/SettingsPane.swift`
- `Sources/HelmUI/Settings/SidebarSettings.swift`
- `Sources/HelmUI/Settings/ViewSettings.swift`
- `Sources/HelmUI/Sheets/BatchRenameEvaluation.swift`
- `Sources/HelmUI/Sheets/BatchRenameSheet.swift`
- `Sources/HelmUI/Sheets/BatchRenameViewModel.swift`
- `Sources/HelmUI/Sheets/ConflictSheet.swift`
- `Sources/HelmUI/Sheets/NewItemNameValidation.swift`
- `Sources/HelmUI/Sheets/README.md`
- `Sources/HelmUI/Sidebar/SidebarModel.swift`
- `Sources/HelmUI/Sidebar/SidebarRowView.swift`
- `Sources/HelmUI/Status/StatusBarView.swift`
- `Sources/HelmUI/TagDots/TagDotView.swift`
- `Sources/HelmUI/Tags/TagEditorModel.swift`
- `Sources/HelmUI/Tags/TagEditorView.swift`
- `Sources/HelmUI/Toolbar/ToolbarCustomizationModel.swift`
- `Sources/HelmUI/Toolbar/ToolbarCustomizationView.swift`
- `Sources/HelmUI/ViewOptions/README.md`
- `Sources/HelmUI/ViewOptions/ViewOptionsModel.swift`
- `Sources/HelmUI/ViewOptions/ViewOptionsView.swift`

Other Apple SDK review inputs (whole-file paths; some portable branches do compile on Linux):

- `Sources/HelmApp/AppEnvironment.swift`
- `Sources/HelmApp/AppStoreContracts.swift`
- `Sources/HelmApp/LaunchRouter.swift`
- `Sources/HelmApp/MemoryStores.swift`
- `Sources/HelmApp/QuitCoordinator.swift`
- `Sources/HelmApp/SessionRestorePlan.swift`
- `Sources/HelmApp/WindowRegistry.swift`
- `Sources/HelmFileSystem/Live/LiveFileSystem.swift`
- `Sources/HelmFileSystem/Live/MetadataReader.swift`
- `Sources/HelmFileSystem/Monitor/DispatchSourceMonitor.swift`
- `Sources/HelmFileSystem/Monitor/FSEventsMonitor.swift`
- `Sources/HelmFileSystem/Monitor/FallbackMonitor.swift`
- `Sources/HelmFileSystem/Providers/CloudAvailability.swift`
- `Sources/HelmFileSystem/Providers/VolumeReader.swift`
- `Sources/HelmFileSystem/Tags/CompositeTagStorage.swift`
- `Sources/HelmFileSystem/Tags/NativeTagAttributes.swift`
- `Sources/HelmFileSystem/Tags/ResourceValuesTagStorage.swift`
- `Sources/HelmFileSystem/Tags/TagAdapterError.swift`
- `Sources/HelmFileSystem/Tags/XattrTagStorage.swift`
- `Sources/HelmFileSystem/Virtual/ListingCache.swift`
- `Sources/HelmFileSystem/Virtual/TrashSource.swift`
- `Sources/HelmFileSystem/Volumes/PutBackPlanner.swift`

Specifically inspect ResourceValuesTagStorage Foundation setters/keys; NativeTagAttributes Darwin xattr signatures and TagAdapterError errno mapping; FSEventsMonitor callback/context ownership; DispatchSourceMonitor vnode descriptor lifetime; FallbackMonitor selection; LiveFileSystem Trash URL bridging, alias/bookmark creation and volume semantics; MetadataReader aliases/UTType; CloudAvailability/VolumeReader resource keys; ListingCache memory-pressure source. Sources: the listed files and [filesystem integration notes](../../Sources/HelmFileSystem/ModuleInfo.swift). Linux Trash/alias fallback errors are not evidence of native behavior.

## Known integration gaps and resolved prerequisites

[CONTRACT_INTEGRATION.md](CONTRACT_INTEGRATION.md) contains the K23 decision record and a concurrent K29 integration addendum; neither is itself a K30 pass log. The table below reconciles it with prereview fixes; deferred decisions remain with their owners. K29 draft changes appeared during verification; current source supersedes the historical F1/F3 deferrals where explicitly noted below. Review and native acceptance remain open.

| Area | Current disposition / remaining work | Traceable evidence |
|---|---|---|
| Shared contracts | Address editor contracts, Core search scopes/filters/ranked batches, cloud FileEntry metadata, snapshot bridge, filesystem case sensitivity and typed no-mutation collision guarantee landed. ReducerContext already exists. Do not repeat these as missing work. | [K23 decisions](CONTRACT_INTEGRATION.md), `Sources/HelmCore/Contracts`, `Sources/HelmCore/Search`, `Sources/HelmFileSystem/Providers/SnapshotStamp.swift` |
| Batch rename safety | Historical P1-1 deferral now has a K29 draft: BatchRenameIssue.overlappingSources and planner rejection retaining previews; the original regression no longer skips. Opus contract/behavior review remains open. | [F1](../prereview/fixes-F1.md), `Tests/HelmCoreTests/NamingTests/F1NestedRenameTests.swift`, `Sources/HelmCore/Naming/BatchRenamePlanner.swift`, `Sources/HelmCore/Naming/RenamePair.swift` |
| Column replies | Historical P1-4 deferral now has a K29 draft: ColumnLoadRequest carries owner identity/generation and push requires the accepted request; ColumnBrowserView migrated and regression no longer skips. ViewMode still grid/list; Apple SDK review remains open. | [F1](../prereview/fixes-F1.md), `Sources/HelmCore/Content/ColumnBrowserState.swift`, `Sources/HelmUI/Content/ColumnBrowserView.swift` |
| Operation recovery | P2-3 mitigated, still deferred: automatic inverse Trash of directories/packages refuses without complete descendant evidence. K29 adds Core UndoVerificationPolicy and leafOnly propagation; it does not supply complete tree verification. Native compare-and-mutate race, metadata fidelity, durable journal/Trash origins and reconciliation UI remain open. Timed-out mutations can still complete. | [F2](../prereview/fixes-F2.md), [Operations notes](../../Sources/HelmOperations/README.md), `Sources/HelmCore/Contracts/UndoVerificationPolicy.swift` |
| Fixed prereview safety | F1 P1-2/3/5 fixes drag scan cost, deferred snapshot republishing/history; K29 adds `Sources/HelmCore/DragDrop/DropSession.swift` for adapter-owned session caching (host wiring pending); F2 P2-1/2/4/5/6/7/8 fixes cancellation lane ownership, unsafe write cleanup, inverse recheck, ancestor replace, fail-closed listing, plan scaling and archive root markers. Native races and performance acceptance remain open. | [F1](../prereview/fixes-F1.md), [F2](../prereview/fixes-F2.md) |
| Persistence/tag/search hardening | F3 P3-1..7 fixed read failure overwrite, tag cancellation, dirty reload, released-thumbnail teardown, extension normalization, encoded search limits, package/symlink roots. K29 now adds ThumbnailCoordinator.shutdown(); native host teardown must call it. Darwin tags and live permission behavior remain untested. | [F3](../prereview/fixes-F3.md), `Sources/HelmCore/Imaging/ThumbnailCoordinator.swift` |
| UI/App prereview | F4 fixes SearchScope seam, bounded/debounced rename evaluation, reserved frame identities and lazy paged operation details. Host occupancy refresh, mutation dispatch, immutable row retention, accessibility and SDK validation remain open. Sidebar locally preserves legacy exclusion of starred rows; reconcile with Core highlight policy. | [F4](../prereview/fixes-F4.md), [UI notes](../../Sources/HelmUI/README.md) |
| Composition/lifetime | Native app host, TabStore/FIFO publication, effect execution, menus/responders, retained tasks, search service adapters and one-store-per-document wiring remain absent. Shared AppEnvironment journal conflicts with planned per-window undo association. Migration-before-registration and quit flush need hosted evidence. | [App notes](../../Sources/HelmApp/README.md), `Sources/HelmApp/AppEnvironment.swift`, [D2 review](../../../helm-plan/docs/rebuild/review-03-astra-selfcheck.md) |
| Search | Engine/composite source/criteria models now exist. NSMetadataQuery lifecycle, truncation/fallback disclosure through reducer/UI, Recents metadata and save/open host still need integration. | [Search notes](../../Sources/HelmSearch/README.md), `Sources/HelmSearch/Engine`, [K23 limits](CONTRACT_INTEGRATION.md) |
| UI/native adapters | Content leaves do not supply grid/list widget, selection binder, address text/IME controller, Quick Look producer, NSWorkspace Open With resolver, native clipboard/drop/session hosts. Verify text-first responders and no hidden selection targets. | `Sources/HelmUI/Content/README.md`, `Sources/HelmCore/AddressBar/README.md`, `Sources/HelmCore/Imaging/README.md`, `Sources/HelmCore/OpenWith/README.md`, `Sources/HelmCore/DragDrop/README.md` |
| Presentation/storage | Starred Location, column/gallery modes, folder option persistence, tag listing/catalogue, mixed-selection editing and icon/text policy remain deferred. Source models/planners are not live integrations. | [K23 decisions](CONTRACT_INTEGRATION.md), `Sources/HelmCore/Presentation/README.md` |
| Filesystem/volume/archive | Wire diagnostics, memory-pressure lifecycle and monitors; review late mutation quarantine. Archive/connect/disk-image/PutBack planners exist; process runner, confinement, mount/eject and durable origin integration remain missing. | `Sources/HelmFileSystem/ModuleInfo.swift`, `Sources/HelmFileSystem/Archive/README.md`, `Sources/HelmFileSystem/Volumes/README.md` |
| Launch/session policy | File reveal vs legacy opening and ordered multiple windows need review. Selection/history/scroll/expansion schema, screen clamping, focus, external-open replies/native tabs/termination remain missing. | [App notes](../../Sources/HelmApp/README.md), [K23 decisions](CONTRACT_INTEGRATION.md) |
| Packaging | UI/App/tests disabled; executable entry point, bundle resources, root project/scheme and automation absent. Exclude manual runners and READMEs when declaring targets. | [Package.swift](../../Package.swift), [F4](../prereview/fixes-F4.md) |
| R1 residual safety findings | Wave-10 review reports queued work may start after IOExecutor quarantine (R1-1), and cancelled CompositeTagStorage fallback may begin another write (R1-2). R1-3 confirms fixed F4 scratch paths. These are review findings, not K30 fixes; reconcile with subsequent K29 edits before closure. | [R1 review](../prereview/R1.md), `Sources/HelmFileSystem/Live/IOExecutor.swift`, `Sources/HelmFileSystem/Tags/CompositeTagStorage.swift` |
| Put Back mixed authorities | T1-001 was skipped in the 648-case standard run. K29 subsequently validates all matching origins before deduplication and adds unconditional regressions; the opt-in T1 full run passed 650 cases with no skips. Native Put Back integration remains untested. | `Tests/HelmFileSystemTests/T1ArchiveVolumeAdversarialTests.swift`, `Sources/HelmFileSystem/Volumes/PutBackPlanner.swift`, [K29 addendum](CONTRACT_INTEGRATION.md#k29), [verification](VERIFICATION.md) |

## M0–M26 status, reconciled with D2

Source: `$PLAN_DIR/review-03-astra-selfcheck.md`, “As-built vs plan”, plus paths below. D2's `done-draft` means bounded portable work, **not** milestone acceptance. All Mac runtime gates remain open. K30 updates stale inventory without claiming missing host work is merely platform-blocked.

| Milestone | D2 status | K30 disposition / current evidence and remaining gap |
|---|---|---|
| M0 tooling | partial | `scripts/static_checks.{sh,py}`, `scripts/rebuild/{run_all.sh,parse_check_ui.sh,check_coverage.py,test_*.py,fixtures/}`; K11 reports 13 fixtures; remaining: Planned check_static.py/--root interface does not exist; selector/project parser checks, full API inventory and configuration gate remain incomplete. |
| M1 skeleton | partial | Root Package.swift; six libraries/tests, TestKit fixtures; remaining: Mac declarations commented; no executable/app bundle/project/scheme/automation; public-interface freeze not closed. |
| M2 values | done-draft | Core Identity/Model/Naming/Support; ModelTests, NamingTests, K13 naming cases; remaining: Resolve compound-extension design conflict, hard-coded byte-limit behavior vs destination capability input; Mac collation/case fixtures. |
| M3 state | partial | Core State (snapshots/history/tab/window reducers), AddressBar integration; StateTests/K15; remaining: Broad actions, child enumeration/watch effects and off-main sort integration missing; no FIFO UI store/selection binder; 100k fixture is not widget timing. |
| M4 persistence | done-draft | Core Settings; Persistence versioned JSON/stores/migrator; 24 declared persistence cases; remaining: Live notification/composition and migration-domain Mac review; future schemas/flush failures need integration evidence. No whole M25 migration closure. |
| M5 filesystem | partial | partial — snapshot bridge/case-sensitive capability and collision guarantee now landed (CONTRACT_INTEGRATION.md); native identity coordination and Mac verification remain. |
| M6 monitors | partial | FS Monitor: registry/coalescer/polling/FSEvents/vnode/fallback; tests in FS suite; remaining: Not future greenfield Fable work: review existing draft; actual FSEvents/vnode teardown, expanded watches, activation and UI reconciliation unverified on Mac. |
| M7 plans | partial | partial — Core/DragDrop and filesystem capability integration now exist; native drag proposal and execution host remain (Sources/HelmCore/DragDrop/README.md). |
| M8 execution | partial | Ops Execute/Journal; executor/recovery/adversarial tests (68 Ops declarations total); remaining: In-memory journal is not menu undo/redo stack or durable recovery; whole-tree copier lacks byte cancellation/fidelity; app shares global journal contrary to per-window policy. |
| M9 search logic | done-draft | done-draft — Core query/filter/batch contracts reconciled; Engine/CompositeSearchSource now exist; preserve truncation through host/reducer and validate locale ranking (Sources/HelmSearch/README.md). |
| M10 composition | partial | AppEnvironment, local store protocols/memory stores, LaunchRouter, WindowRegistry, SessionRestorePlan, QuitCoordinator; 12 App test declarations; remaining: No AppKit launch host, TabStore, windows/split/tab controllers, executable or target wiring. Portable runner is supplemental, not app acceptance. |
| M11 grid/list | not started | partial (was not started) — Core/Content models and HelmUI/Content leaves exist; grid/list native widgets, selection binding and hosted timing remain missing (Sources/HelmUI/Content/README.md). |
| M12 address | partial | Core AddressBar (K3/K9), delayed/cancellation tests; remaining: No AppKit address controller/text field/popup; debounce/cache adapter, focus/IME/undo and 8-visible-row behavior absent. 51-total logic already exists. |
| M13 places/status | partial | partial — F4 SidebarModel preserves legacy starred exclusion; reconcile product policy and wire subscriptions/keyboard/drop (docs/prereview/fixes-F4.md). |
| M14 imaging/Properties | partial | Core Imaging, Properties models, FS PropertiesLoader, UI Properties leaves; ImagingTests; remaining: No native thumbnail producer, icon adapter, QuickLookCoordinator, SheetPresenter or recursive totals integration. Pure cache is not native imaging. |
| M15 rename/operations UI | partial | UI Sheets/Operations and Core batch planning; K16's 10 UI adapter tests; remaining: Host dispatch, one-item inline rename, New Folder flow, retained sheet lifetime and journal/progress wiring missing; Mac SwiftUI compile pending. |
| M16 live search | partial | UI SearchBar model/view/location cell; portable Search service precursor; remaining: No NSMetadataQuery/Spotlight adapter or per-tab search host, run-loop/cancellation integration, fallback disclosure. K21's 9 UI methods are shared across several milestones. |
| M17 commands/drop | partial | partial — Core/DragDrop planners, autoscroll, spring/tab models now exist; native responders/pasteboard/session wiring and virtual selected-item capability remain open (Sources/HelmCore/DragDrop/README.md). |
| M18 tags/grouping | partial | Core tag/group/storage values, FS Tags (K20), UI TagEditor/TagDot; TagsTests and grouping cases; remaining: No persistent tag catalogue/TagStore, mixed-selection edit resolver or grouped widgets; xattr concurrency best effort, synchronous actor I/O; Darwin/Finder interoperability blocked on Mac. |
| M19 column/gallery | not started | partial (was not started) — ColumnBrowserState/View exist, K29 request-token draft addresses the historical stale-reply F1 deferral; ViewMode still grid/list and gallery/native wiring absent (docs/prereview/fixes-F1.md). |
| M20 info/open/share | partial | Core OpenWith/Properties, UI read-only Properties, FS attribute provider; remaining: No native application resolver/picker, Inspector/windows, editable attributes, Services/Share adapters. No sending/sharing action permitted. |
| M21 volumes/cloud | partial | partial — cloud metadata is in FileEntry; Volumes planners/registry exist; actual mount/eject/event/provider coordination untested (CONTRACT_INTEGRATION.md; Sources/HelmFileSystem/Volumes/README.md). |
| M22 trash/copy/archive | partial | partial — Archive safety/process planners and PutBackPlanner exist; execution/confinement, native fidelity and durable Trash origins remain open (Sources/HelmFileSystem/Archive/README.md; docs/prereview/fixes-F2.md). |
| M23 saved search | partial | partial — SearchCriteriaEditor and saved-search codecs exist with F3 bounds fixes; native criteria/save/open/RawQuery integration remains (Sources/HelmSearch/SavedSearch; docs/prereview/fixes-F3.md). |
| M24 customization/a11y | partial | Core Settings/Presentation, UI Settings/ViewOptions/Toolbar leaves; K12/K21 tests; remaining: No persistent per-folder records or native toolbar host/live consumers; icon range mismatch; keyboard/VoiceOver/IME and SDK verification pending Mac. |
| M25 tabs/migration/integration | partial | Persistence LegacyDefaultsMigrator, Core WindowState, App launch/session primitives; remaining: No tab strip/reorder/transfer/overflow, external-open delegate/Services/default-handler adapter; session lacks selection/anchor/history/expansion/frame-clamp acceptance. |
| M26 stability/handoff | partial | partial — current K30 evidence/ledger refreshed (VERIFICATION.md); missing mandatory features, Apple SDK/runtime review, G11 and GM remain open. |

## Mac acceptance checklist (all NOT RUN by K30)

Use `$PLAN_DIR/00-current-state.md`, `00b-opus-review.md` (R-1–R-19), `02-finder-parity.md` and `03-build-plan.md` acceptance rows for exact expected behavior. Track each ID individually; F-033/F-058 deferred/dead behavior needs explicit disposition, not citation-based closure.

- Launch: requested URLs vs restore vs Home; first displayed contents, file reveal policy, multiple windows, duplicate frame IDs, Dock reopen and quit-flush failures.
- Navigation/content: failed Back/Forward history, hidden refresh, stale callbacks, accepted selection IDs, grid/list keyboard and type-select, column reply generation, address parent + 50 children, tilde, rapid Tab and IME/focus/undo.
- Mutations with approved fixtures only: nested rename refusal, conflict/Replace ancestry, exact paths, clipboard compare/write, partial/late outcomes, quarantine, fail-closed child reads, directory undo refusal, per-window task/journal lifetime and close-during-operation. Never test actual Trash/delete without exact approval.
- Search/metadata: scoped roots, ranking, cancellation generations, fallback/truncation disclosure, packages/symlinks, saved-search limits and opaque Finder queries, Finder tags preserving unknown entries, cloud metadata without hydration.
- UI integration: text-first clipboard/undo and responder routing; visible selection equals command targets; rename debounce/stale evaluation; lazy operation disclosure; sidebar policy; thumbnails/Quick Look reuse/cancellation; settings and location persistence; VoiceOver and keyboard access.
- Runtime/performance: approved synthetic 100k selection/snapshot/planning fixtures separately from widget frame timing; ten tabs/two windows; monitor storms/teardown; offline/denied/disk-full cases; 30–60 minute soak with memory/latency/hardware and warm/cold context. Portable timing is not Mac acceptance.

## Ready-to-paste owner Claude Code prompt

The following is self-contained, with the staged manifest proposal and exact commands included. It assigns no additional file ownership and authorizes no external effect.

````text
Do not publish or post anything (including TikTok), activate or change ads, or run paid renders (e.g. Higgsfield) on your own; stop and report instead. Do not send, delete or change sharing.

You are performing Huseyn's local Mac compile-and-validation handoff for the Helm rebuild. All Astra code and plans remain DRAFT pending the applicable Opus review record. Claude work may begin only after 22:00 America/Toronto on November 4, 2026; time alone closes no gate. Do not use the network, install dependencies, purchase, publish, send, delete, change sharing, change OS defaults, commit or push. Exact-action approval comes only from Huseyn in chat. Prepare concrete module-sized fixes for the orchestrator within your explicitly assigned paths; do not assume this prompt grants ownership of all files.

The rebuilt package is the repository-root Package.swift with Sources/, Tests/, scripts/rebuild/ and docs/handoff/. The branch is forge/rebuild-build unless the owner identifies its reviewed successor. Legacy Helm/ stays untouched and is the behavioral reference. Planning documents are supplied separately: set PLAN_DIR to their verified local docs/rebuild directory; do not fetch them or assume the code checkout's copied documents are current. Read local AGENTS, scripts/K1_HANDOFF.md, all current ModuleInfo/README notes, docs/handoff/VERIFICATION.md and MAC_HANDOFF.md, the external 00/00b/01/review-01/02/03/04 documents and review-03-astra-selfcheck.md. Frozen review records win over stale notes; review-01 corrected public type homes win over older architecture sketches. Do not import UI into Core to repair a compile. Public types named by Core signatures belong in Core; public structs/classes need explicit public initializers. Keep actor-crossing values Sendable and core modules free of Combine/AppKit/@Observable/macros/third-party packages. Use XCTest, preserve error handling, and avoid force unwraps or try! on user-input paths.

Record revision plus dirty files, Xcode/compiler/SDK/XcodeGen versions and hardware. Require macOS 14+, full Xcode, tools 5.9 support and Swift 5 language mode. Report missing tools without installing them. Perform inventory from the rebuilt repository root:

```sh
pwd
git status --short
xcode-select -p
xcodebuild -version
xcrun swift --version
xcrun --sdk macosx --show-sdk-version
xcodegen --version
swift package dump-package
bash scripts/static_checks.sh
bash scripts/rebuild/parse_check_ui.sh
python3 scripts/rebuild/check_coverage.py --parity "$PLAN_DIR/02-finder-parity.md" --current-state "$PLAN_DIR/00-current-state.md"
```

Do not run --generate on the coverage ledger without assigned ownership. Source/test citations and counts are not acceptance. Historical K11 results do not cover subsequent waves. Audit fixture side effects before tests: no sending, deletion (including cleanup), mounts, downloads, sharing changes or real-default writes without exact approval. Split/hold affected cases and continue permitted checks; do not claim a filtered or skipped run is a complete passing suite.

Use a dedicated scratch path, shown below as /tmp/build-MAC-HANDOFF. Explicitly build each portable target in dependency order:

```sh
swift build --scratch-path /tmp/build-MAC-HANDOFF --target HelmCore
swift build --scratch-path /tmp/build-MAC-HANDOFF --target HelmFileSystem
swift build --scratch-path /tmp/build-MAC-HANDOFF --target HelmPersistence
swift build --scratch-path /tmp/build-MAC-HANDOFF --target HelmOperations
swift build --scratch-path /tmp/build-MAC-HANDOFF --target HelmSearch
swift build --scratch-path /tmp/build-MAC-HANDOFF --target HelmTestKit
```

Run permitted suites with these commands after inspecting their fixtures. SwiftPM may compile all declared test dependencies even when filtered; record graph failures honestly.

```sh
swift test --scratch-path /tmp/build-MAC-HANDOFF --filter HelmCoreTests
swift test --scratch-path /tmp/build-MAC-HANDOFF --filter HelmFileSystemTests
swift test --scratch-path /tmp/build-MAC-HANDOFF --filter HelmPersistenceTests
swift test --scratch-path /tmp/build-MAC-HANDOFF --filter HelmOperationsTests
swift test --scratch-path /tmp/build-MAC-HANDOFF --filter HelmSearchTests
swift test --scratch-path /tmp/build-MAC-HANDOFF --filter HelmTestKitTests
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts/rebuild -p 'test_*.py' -v
```

At the D2 snapshot the macOS target template was commented, HelmAppTests was undeclared, and there was no rebuilt executable, root project.yml, root Xcode project or UI automation target. Verify current state first. Missing targets/sources are implementation gaps, not an SDK error. Have the assigned manifest/host owner supply reviewed membership, README exclusions, one app entry point, plist/entitlements, explicit shared test action and HelmAppTests excluding LinuxRunner. Keep legacy project inputs untouched. Once those deliverables exist, build HelmUI, HelmApp and Helm with explicit --target and the same scratch path; run HelmUITests and HelmAppTests with --filter after fixture inspection. Do not run a nonexistent target or report zero tests as success.


Enable the Mac manifest in stages, only after explicit assignment of Package.swift/host ownership. This is a proposed patch, not an instruction to edit another lane's files. Do not simply uncomment the entire old template: Sources/Helm is absent and HelmAppTests is omitted there.

1. Keep all six portable declarations unchanged and retain the existing `#if os(macOS)` boundary. Add HelmUI and its existing tests first. Use this replacement inside the conditional (not alongside duplicate uncommented declarations):

```swift
targets += [
    .target(name: "HelmUI", dependencies: ["HelmCore", "HelmFileSystem",
        "HelmPersistence", "HelmOperations", "HelmSearch"],
        exclude: ["README.md", "Part3-README.md", "Content/README.md",
                  "Sheets/README.md", "ViewOptions/README.md"]),
    .testTarget(name: "HelmUITests", dependencies: ["HelmUI", "HelmCore",
        "HelmOperations", "HelmSearch", "HelmTestKit"], exclude: ["PortableRunner"])
]
```

Run `swift package dump-package`, then `swift build --scratch-path /tmp/build-MAC-HANDOFF --target HelmUI`. Once graph compilation succeeds, run `swift test --scratch-path /tmp/build-MAC-HANDOFF --filter HelmUITests` from the repository root (F4 structural tests read relative source paths). A library product for HelmUI is optional for target compilation.

2. Add the existing portable composition module and its tests inside the same conditional:

```swift
products += [.library(name: "HelmApp", targets: ["HelmApp"])]
targets += [
    .target(name: "HelmApp", dependencies: ["HelmUI", "HelmCore",
        "HelmFileSystem", "HelmPersistence", "HelmOperations", "HelmSearch"],
        exclude: ["README.md"]),
    .testTarget(name: "HelmAppTests", dependencies: ["HelmApp", "HelmCore",
        "HelmPersistence", "HelmTestKit"], exclude: ["LinuxRunner"])
]
```

Run `swift build --scratch-path /tmp/build-MAC-HANDOFF --target HelmApp` and `swift test --scratch-path /tmp/build-MAC-HANDOFF --filter HelmAppTests`. This only validates current composition glue, not nonexistent AppKit controllers. Excluding LinuxRunner prevents its XCTMain/main.swift becoming a second entry point in XCTest. UI PortableRunner is Linux-only and hardcodes F4 scratch artifacts; do not run it on Mac.

3. Assign and implement the missing native host and exactly one executable entry point under Sources/Helm. Only once those source files exist and the reviewed host can launch, add:

```swift
products += [.executable(name: "Helm", targets: ["Helm"])]
targets += [.executableTarget(name: "Helm", dependencies: ["HelmApp"])]
```

Run `swift build --scratch-path /tmp/build-MAC-HANDOFF --target Helm`. A successful SwiftPM executable link does not produce a complete Finder-replacement app bundle. Root project.yml/Info.plist/entitlements, app resources and shared scheme/test action remain separate assigned deliverables. Do not invent signing settings or reuse the legacy project as proof of rebuild acceptance. Re-inventory README paths before applying excludes; manifest warnings do not justify dropping actual source files.

Expected first-compile failure classes (risks to investigate, not observed Mac errors): missing target/source directory or duplicate XCTMain entry point; public initializer/access/type-home mismatches; Foundation resource-value mutability and Darwin ABI differences; SwiftUI generic/binding/API availability errors; MainActor protocol witnesses and deinit isolation; Sendable callback captures and native pointer lifetimes; link/bundle/entry point/resource membership errors. SwiftPM test filters still compile the declared graph. Fix the earliest underlying error, recompile its consumers, and preserve behavioral tests. Do not count skipped fixtures or zero discovered tests as success.

Generate a rebuilt project only from its inspected, assigned root project.yml. Confirm source membership and selected signing configuration first; do not select credentials or enable provisioning updates. Run xcodegen generate, then xcodebuild -list -project Helm.xcodeproj only if that is the verified new project path. Inspect the actual shared scheme and automation target before running xcodebuild build/test; Helm and HelmUIAutomationTests remain proposals until inventory confirms them. Use -destination 'platform=macOS', local derived data and local result bundles. Unsigned compilation is separate from launch/privacy validation.

Fix the first underlying module error in DAG order. Check accessible initializers, imported SDK signatures, delegate witnesses, MainActor/Sendable crossings, explicit teardown, selector arity and text-first routing. Review live mutation/quarantine, per-window journal retention, search/query generation and migration-before-default-registration against their closed contracts. Reopen the affected gate for any public-contract change and list all consumers. Never suppress a failing test or add blanket unchecked Sendable to obtain a pass.

After ordinary compilation, rerun each existing target build with -Xswiftc -strict-concurrency=targeted, then separately with -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors. Apply the same diagnostics to the approved XCTest filters. Keep Swift 5 mode and distinguish targeted baseline from complete-strict acceptance. Xcode app settings do not configure Swift package targets. For the verified rebuilt app scheme, also inspect SWIFT_VERSION=5 and run its approved tests with SWIFT_STRICT_CONCURRENCY=complete and SWIFT_TREAT_WARNINGS_AS_ERRORS=YES. Record narrow SDK exceptions explicitly for review.

Run the preserved-interaction and parity checklists in docs/handoff/MAC_HANDOFF.md, all 00b R-1 through R-19, and each mandatory ledger acceptance case against approved fixtures. Prioritize launch precedence, failed navigation/history, visible selection versus command targets, text-first clipboard/undo, address 50 children plus parent and rapid Tab/IME/focus, rename/sheet lifetime, operation partial/late outcomes, per-window undo, thumbnail reuse, search overlay isolation, multi-window persistence and cloud non-materialization. No Share/Services/AirDrop send or default-handler change is authorized. Missing implementations stay NOT RUN, not passed through a fake.

Measure synthetic 100k snapshot/Select All and approved real directory timing separately, with hardware/warm-cold context. Exercise ten tabs/two windows, monitor storms, late callbacks, denied/offline/disk-full fixtures, close-during-operation and migration retry. Use fakes before any prohibited effect. Run the 30–60 minute local soak only after the app and permitted fixtures are ready. Launch the bundle from the verified build product path; bare swift run does not validate bundle integration.

Finish with revision, commands/exit codes/test and skip counts, compile fixes, review gates, F/P/B evidence, R-1–R-19 outcomes, concurrency/performance results and exact remaining work. Mark each item PASS, FAIL, NOT RUN or BLOCKED. State separately whether G11 is ready for Mac validation and whether GM actually passes; neither permits release or external effects. Report any exact action requiring approval with its concrete target, effect and cost, then stop that action. No automatic commit, upload or publication follows.
````
