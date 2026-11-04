<!-- DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04 -->
# K23 contract integration

Scope: the six authorized contract changes. Inventory includes every matching README
under Sources, Tests, docs/test-findings and docs/handoff, K1_HANDOFF.md, plus all
Sources/*/ModuleInfo.swift integration notes. No matching README requests occurred
under Tests or docs. Existing prose is historical; this table records current decisions.
No network, commits, external actions, manifest edits or old-app edits were performed.

| Item | Source lane | Decision | Files touched |
| --- | --- | --- | --- |
| Replace minimal address types with K3 editor contracts; migrate K1 smoke test | K1/K3/K9, AddressBar README and K1 handoff | DONE; no production callers of removed types, so no compatibility aliases needed | Core/Contracts/AddressContracts.swift; CoreTests/SupportTests.swift |
| Symbolic search scope, kind/date filters, truncation envelope in Core | K7, Search README/ModuleInfo | DONE; preserve legacy scope cases and saved-search case names; parser request/specification and ranked batch now Core-owned | Core/Search/*; Search/Query, Rank, Fallback, SavedSearch; SearchTests/ContractIntegrationTests.swift |
| Cloud availability in FileEntry and cheap listing metadata | K5/K9, FileSystem README/ModuleInfo | DONE; default unknown, legacy decode fallback, metadata failure does not omit listing entry; K9 reader remains provider | Core/Model/{CloudAvailability,FileEntry}.swift; FileSystem/Providers/CloudAvailability.swift; FileSystem/Live/MetadataReader.swift; CoreTests/CloudContractTests.swift |
| Column/gallery ViewMode | K10, Presentation README | DEFERRED-needs-owner-decision; old Helm/Helm/Models/ViewMode.swift has only grid/list. New cases would advertise unimplemented views | None |
| Snapshot stamping bridge | K5/K8/K9, FileSystem README/ModuleInfo | DONE; additive generation-bearing load action bridge, accepted IDs still allocated by reducer | FileSystem/Providers/SnapshotStamp.swift; FileSystemTests/ProviderMetadataTests.swift |
| Query filesystem case sensitivity and typed collision guarantee | K6/K17, Operations README | DONE; conservative default for third-party conformers; capability used in builder/executor; retry only guaranteed no-mutation collision | FileSystem/Protocol, Live, Fake; Operations/Plan/PlanningContext.swift; Operations/Execute/OperationExecutor.swift; integration tests |
| Starred as Location | K9/Persistence ModuleInfo, FileSystem README | DEFERRED-needs-owner-decision; explicitly prohibited in K23 | None |
| ReducerContext SettingsSnapshot dependency | K1 handoff | DONE by K8 already; current Core/State/TabState.swift owns context | None |
| Stronger content/link verification and conditional no-follow mutations | K6 Operations README | DEFERRED-needs-owner-decision; native coordination/fidelity design exceeds six-item scope | None |
| Persistent journal, Trash origin durability acknowledgment | K6 Operations README | DEFERRED-needs-owner-decision; requires recovery/persistence design | None |
| Actual volume capability injection | K6 Operations README | DONE for filesystem capability; UI lifetime/clipboard/confirmation wiring deferred below | Same capability files above |
| Journal/task lifetime, pasteboard and confirmation/conflict UI wiring | K6 Operations README | DEFERRED-needs-owner-decision; composition work outside contract scope | None |
| README manifest exclusions, UI/App/test target declarations and Linux runner exclusion | K6/K10/K12/K22 READMEs | DEFERRED-needs-owner-decision; Package.swift edits explicitly prohibited | None |
| UI menu tables, focus/capability facts and responders | Commands README | DEFERRED-needs-owner-decision; host adapter work beyond six contracts | None |
| Imaging/Quick Look producers and UI adapters | Imaging README | DEFERRED-needs-owner-decision; macOS adapter work | None |
| NSWorkspace Open With resolver, picker, default setter, error UI, Recent recording | OpenWith README | DEFERRED-needs-owner-decision; macOS adapter work | None |
| Status/group/property rendering and keyboard fallback editors | K10 Presentation README | DEFERRED-needs-owner-decision; UI integration outside contract scope | None |
| TagStorage filesystem implementation | K10 Presentation README; Tags README | DONE by existing K21 adapters; no further shared contract change requested | None |
| Location-keyed view-option persistence | K10 Presentation README | DEFERRED-needs-owner-decision; persistence schema work outside scope | None |
| Global 48–128 vs folder 16–512 icon range; 12pt text and date/size buckets | K10 Presentation README | DEFERRED-needs-owner-decision; product/UI policy | None |
| UI hosting and composition root wiring | K12 UI README | DEFERRED-needs-owner-decision; macOS hosting integration | None |
| Shared store adapters, search/executor/menu host wiring | K22 App README | DEFERRED-needs-owner-decision; application integration | None |
| External-open delegate/replies and initial content ordering | K22 App README | DEFERRED-needs-owner-decision; macOS integration and changed launch policy need review | None |
| File reveal vs opening; ordered multiple windows | K22 App README | DEFERRED-needs-owner-decision; explicit behavior policy confirmation requested | None |
| Session selection/history/scroll/expanded rows; frame clamping, focus, observers, native tabs, termination replies | K22 App README | DEFERRED-needs-owner-decision; schema and macOS lifecycle integration | None |
| Listing diagnostics to partial-read UI; cache memory-pressure lifecycle | K5 ModuleInfo | DEFERRED-needs-owner-decision; composition-root/UI work | None |
| Timed-out mutation reconciliation; quarantine; macOS FSEvents/vnode/Trash/alias/resource-key verification | K5 ModuleInfo | DEFERRED-needs-owner-decision; platform verification remains required, existing conservative behavior retained | None |
| Tags in FileEntry/listings | K5 ModuleInfo | DEFERRED-needs-owner-decision; no authorization to expand listing metadata beyond cloud | None |
| Migration before store registration; one store/document; flush and future-schema handling | Persistence ModuleInfo | DEFERRED-needs-owner-decision; composition-root sequencing | None |
| Optional volume ejectability | Persistence ModuleInfo | DONE by existing VolumeReader.details() | None |
| FakeClock lock synchronization review | K1 handoff | DEFERRED-needs-owner-decision; Opus review, no contract change required | None |
| Tags adapter additional shared changes | Tags README | REJECTED-with-reason; source explicitly says none required | None |

Paths in the table are relative to Sources/ or Tests/ as appropriate.

## Verification

All six portable manifest targets built after each item using `/tmp/build-K23`.
The entire portable XCTest selection passed after each item: address 385; search 387;
cloud 388; ViewMode deferral 388; snapshot bridge 389; filesystem capabilities 396.
A final scope-boundary regression brought the full suite to **397 tests, 0 skipped,
0 failures**. `HELM_K11_SCRATCH=/tmp/build-K23 bash scripts/rebuild/run_all.sh`
passed every check (six builds, XCTest, Python checks, static, UI parse, coverage).
The separately requested `bash scripts/static_checks.sh` passed: **164 Swift files,
0 errors**. `git diff --check` passed. Final logs: `/tmp/build-K23/logs/`.

During API changes, SwiftPM incremental artifacts produced an old-initializer link
failure and later a crash in an existing search test after the FileSystemError enum
layout changed. Each cleared after `swift package --scratch-path /tmp/build-K23 clean`
and rebuilding all targets/tests; the final full runner passed without a clean or
retries. No unrelated source workaround was applied.

## Integration limits and needed changes elsewhere

- All code remains DRAFT pending Opus review after 22:00 Toronto on 2026-11-04.
  Linux builds do not verify macOS resource keys, SDK types or behavior. UI parsing is
  syntax only; coverage remains report-only.
- No manifest, scripts, old app, commit or push changes. Manifest exclusions and
  macOS UI/App target activation remain with their owner.
- Search service adapters must consume Core's result batch and preserve its truncation
  through UI state. The existing array-only TabAction search seam is unchanged; a
  subsequent host/UI integration must retain and render the batch flag.
- Legacy `userFolders` is treated as Home and `computer` as explicitly supplied roots
  in enumeration. No search expands roots implicitly. Recents still requires a
  metadata source. Cloud availability stays unknown for unreported providers.
- Live generic copy/move collisions retain `noMutation: false`; safe automatic retry
  is available only where the primitive supplies a true guarantee (exclusive
  open/mkdir, or fake insertion before any tree mutation). Stronger native mutation
  guarantees remain deferred.
- Column/gallery, Starred Location, schema changes and host adapter work remain
  deferred as detailed in the table. No new view mode or Location case was introduced.

