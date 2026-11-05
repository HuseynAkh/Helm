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


## K29

DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04.

- **P1-1:** Core `BatchRenameIssue.overlappingSources(URL, URL)` rejects selected
  ancestor/descendant paths before any steps, including unchanged selected ancestors.
  Uses standardized components and supplied volume case semantics; previews remain.
  Non-nested rename and two-phase swap behavior are unchanged.
- **P1-4:** Core `BrowserColumn.id` and `ColumnLoadRequest` bind each load to an
  owning-column UUID and single-use request UUID. `ColumnNavigation.load(request)`
  replaces the path/index-only case; adapters must retain that request and call
  `push(snapshot, request: request)`. There is no unsafe compatibility overload.
  New requests, selections, ancestor replacement and truncation/pop invalidate old
  callbacks. ColumnBrowserView forwards the value unchanged; no concrete load host
  exists in this tree. F1's A→B→A regression now runs unconditionally.
- **P2-3:** Core `UndoVerificationPolicy.leafOnly`; Operations
  `ItemOutcome.destinationKind`, `OperationPlan.expectedKinds` and `undoVerification`.
  UndoPlanner always selects leaf-only verification. Executor refuses directory and
  package inverses (including move/restore), missing evidence and kind changes,
  checks the whole initial token set before mutation and rechecks immediately before
  each inverse. Kinds/tokens follow actual internal moves. F2's edited-descendant
  regression remains unconditional; new tests cover moves, absent evidence and kinds.
  **Deliberate limitation:** all tree undo, even unchanged trees, reports
  `verificationUnavailable`; no root-token-only tree authorization or purported
  complete manifest is introduced. Full content/object-identity manifests and atomic
  native compare-and-mutate remain future work. UI must report refusal, not retry it.
- **F3:** `await ThumbnailCoordinator.shutdown()` is terminal/idempotent. It removes
  flights, cancels producers, finishes streams and clears cache; future subscriptions
  finish empty and late callbacks cannot publish/cache. Producers must cooperate to
  stop native work. No thumbnail owner exists in HelmUI/App yet; its future teardown
  must await this API. Deinit remains a synchronous safety net.
- **F1:** Core `DropSession` caches normalized source paths and overlap validation
  for one drag UUID. Keep it across target/modifier updates; `replaceSources` rebuilds
  only when ordered source metadata changes; terminal `end()` releases all paths.
  No global path cache. Existing stateless DropPlanner delegates to the same logic.
  No native file-drag adapter exists yet; its lifecycle must adopt this session API.

All new public Core signature types remain in Core. Existing manifest, scripts and
legacy Helm sources are untouched. Portable verification results follow after runs;
macOS native compilation and behavior remain pending Opus review.

The full-suite gate also exposed T1-001: PutBackPlanner previously validated only
the first origin after path-only deduplication. K29 now validates every matching
origin before deduplication, refusing mixed local/remote authorities in either
order. No public contract changed; valid duplicates and ambiguous valid origins
retain their behavior. K29 adds unconditional regressions; T1's independently
owned gated regression is exercised with `T1_RUN_BUGS=1` for final verification.

### K29 verification

- Linux Swift 6.0.3, Swift 5 language mode, scratch `/tmp/build-K29`.
- Full portable XCTest suite with `T1_RUN_BUGS=1`: **650 executed, 0 failures,
  0 skips** (`/tmp/K29-full-final.log`). F1 deferred regressions and the P2-3 live
  edited-descendant regression run unconditionally. T1's separate Put Back gate
  is enabled by the environment; the added K29 equivalents are unconditional.
- All K29 source/test changes pass standalone static checks (**196 Swift files,
  0 errors**) and scoped `git diff --check`.
- Earlier attempts recorded T1's in-progress column-API compile errors and search
  fixture ordering failures. T1 fixed its own files; K29 did not edit them. An
  initial K29 test lookup used a differently directory-hinted URL; it now checks
  the journal's actual destination URL and asserts the same path and expected kind.
- macOS 14/Xcode type checking, native drag/thumbnail lifecycle integration and
  Opus compile/behavior review remain outstanding. Automatic tree undo is
  intentionally refused; descendant manifests and atomic native mutation are not
  claimed. No network, commit, push or external action was performed.
- Final `T1_RUN_BUGS=1 HELM_K11_SCRATCH=/tmp/build-K29 bash scripts/rebuild/run_all.sh`:
  **PASS**, all six portable target builds, **650 tests / 0 failures / 0 skips**,
  Python tests, static checks, UI syntax parse and report-only coverage; **0 failed
  checks**. Summary `/tmp/K29-run-all-final.log`; detailed `/tmp/build-K29/logs/`.

## K34

DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04.

- **P7-2:** Core Naming adds throwing cancellation-hook overloads while retaining
  both nonthrowing planner signatures. Checks cover generation, overlap map/sort
  boundaries, occupied names, target/changed scans and temporary-name probing.
  Hook errors propagate unchanged, including a one-shot non-CancellationError.
  UI's BatchRenameWorker keeps one active detached calculation and one latest
  pending revision; cancellation handlers, replacement, Cancel and disappearance
  cancel work. No cancelled partial evaluation is cached or published. The sheet
  is explicitly MainActor-isolated for Swift 5/macOS compatibility.
- **P6-1:** Core owns FileObjectIdentity, FileMutationPrecondition,
  ConditionalFileMutation and ConditionalMutationError. FileEntry and SourceEntry
  carry optional identities with backwards-compatible initializer/decoding defaults.
  FileSystem has default-refusing observation/mutation requirements. Preconditions
  include identity, kind and root ChangeToken; destination admission is exclusive.
  Conditional errors guarantee no mutation; ordinary errors retain uncertainty.
  InMemoryFileSystem compares and mutates without an actor suspension, preserves
  identities on move/Trash, and allocates new identities on copy. Live supplies
  no-follow device/inode observations but deliberately inherits mutation refusal.
  Inodes can be recycled; portable POSIX cannot atomically compare and mutate a
  pathname against external writers. Executor copy/move/Trash use the conditional
  seam, and unadopted FileCopier conformers refuse by default. Root evidence never
  authorizes directory undo. Original timeout errors remain visible/quarantining.
- **F6:** DirectoryEffectRunner composes with a host fallback for unrelated effects.
  It handles monitor startup, refresh and root validation, returning cancellation
  handles retained by WindowStore. Validation acknowledgement carries a coalescer
  revision so an old successful validation cannot clear a newer root change.
  Additive monitorValidationFailed publishes terminal failure without recursively
  requesting validation. WindowStore cancels validation on replacement, monitor
  retirement, tab disposal and shutdown. Full refresh intentionally subsumes path
  deltas; current per-tab load options are injected by the host.
- **K33:** Existing Persistence defaults already delegated to Core ViewOptions().
  Core now names the shared 96-pixel default and uses it for construction, decode
  fallback and nonfinite values. Persistence round-trip tests lock down this policy.
  Folder range remains 16–512; global legacy slider range remains 48–128. Stored
  overrides are not migrated. Legacy PreferencesView's 64 fallback is not adopted.
- **F3:** Already completed in K29. Inspected existing terminal/idempotent shutdown,
  stream finishing, producer cancellation, cache clearing and post-shutdown tests;
  no duplicate implementation. No concrete thumbnail host exists to wire here.

### K34 tests and compatibility changes

API-first regressions failed compilation before the cancellation, atomic and
revision-acknowledgement seams existed (`/tmp/K34-cancel-red.log`,
`/tmp/K34-atomic-red.log`, `/tmp/K34-monitor-red.log`). No failing assertion is
claimed for defaults/shutdown, which were already consistent/implemented. The
full suite was invoked after the cancellation and atomic edits; concurrent T2
partial-file errors interrupted initial runs. Those files were not edited; later
runs proceeded after more than 60 seconds. A clean K34 scratch rebuild resolved
stale FileEntry initializer link artifacts after the additive identity parameter.

Existing injected copier fixtures now opt into conditional fake mutations while
retaining their original collision, timeout and unreadable-output injection.
The gated copier models an already-admitted uncancellable native operation in a
detached task, retaining its original success-journaling assertions on cancellation.
Native executor tests now assert explicit no-mutation refusal. The two native
edited-descendant undo tests retain their real filesystem edits and all inverse
refusal/content assertions: raw fixture copy/move seeds a journal after asserting
forward refusal. No safety regression is skipped or disabled.

### K34 needed changes elsewhere / limitations

- Native conditional copy/move/Trash through OperationExecutor is intentionally
  unavailable. A reviewed native coordination/identity provider must implement
  the contract; stat-then-mutate is not an acceptable substitute. Direct filesystem
  primitives remain available to explicit callers. This behavior change needs
  particular attention in Opus review.
- Root identity/change evidence is not content hashing or a complete descendant
  manifest. Output mutation-to-metadata observation remains an open ownership
  window; an atomic completion receipt is future work. Persistent object identity
  across process restarts and durable Trash origin acknowledgement remain open.
- Host composition must install DirectoryEffectRunner with current tab options and
  its fallback; no runnable macOS host wiring is invented here. Thumbnail host
  teardown must await the existing shutdown API when a host is introduced.
- macOS 14/Xcode compile and behavior review remains pending. Linux validates
  Foundation adapters and syntax only for SwiftUI; it cannot certify native views.
- No network, external actions, old Helm edits, manifest/script edits, commit or push.

Final verification results are appended below.

### K34 final verification

- Linux Swift 6.0.3, Swift 5 language mode, isolated `/tmp/build-K34`.
- Full suite after integration: **874 tests, 0 failures, 0 skips**
  (`/tmp/K34-full-final.log`). Final edge-case additions increase this to **877**.
- `HELM_K11_SCRATCH=/tmp/build-K34 bash scripts/rebuild/run_all.sh`: all six
  explicit portable module builds, **877 tests / 0 failures / 0 skips**, Python
  checks, static checks, SwiftUI syntax parsing and report-only coverage pass.
  Summary `/tmp/K34-run-all.log`; detailed logs `/tmp/build-K34/logs/`.
- Portable Foundation UI/App runner: **53 tests / 0 failures / 0 skips**,
  including the two worker cancellation regressions (`/tmp/K34-ui-final.log`).
  This temporary runner links the K34-built modules and leaves Package.swift and
  scripts unchanged; it does not type-check SwiftUI or AppKit against a Mac SDK.
- Standalone static checks: **221 Swift files, 0 errors**. `git diff --check` passes.
- All changes remain uncommitted drafts pending Opus review after 22:00 Toronto.

## F12 current disposition of historical deferrals

DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04.

The K23 table and its verification counts above are a dated decision record.
K29/K34 and the current source supersede these specific earlier deferrals:

- Location-keyed option persistence now exists as Persistence
  `LocationViewOptionsStore`; tag catalogue persistence exists as `TagCatalogStore`.
  Native consumers, explicit flush/recovery composition and one-store ownership
  remain deferred, not the portable storage implementation.
- Core `WindowStore` supplies FIFO state publication, retained task handles and
  `StoreSelectionBinder`; FileSystem `DirectoryEffectRunner` supplies monitor,
  refresh and validation work. Application wiring remains deferred. Both refresh
  and validation work must return cancellation handles.
- Core's no-follow identity/conditional mutation values and provider seam exist.
  Native atomic mutation remains deferred: the default LiveFileSystem executor
  path refuses copy/move/Trash. Exclusive creation is available; direct primitive
  APIs are not evidence of executor capability. Tree undo remains refused.
- K34 cancellable Naming APIs and UI `BatchRenameWorker` supersede F8's P7-2
  deferral. The bounded worker and cancellation checks exist; hosted Mac validation
  is outstanding. K35 Inspector and K36 Accessibility provide portable values,
  not native attribute execution or VoiceOver integration.
- F5 removed the T1 Put Back opt-in gate and fixed both UI runner scratch inputs.
  Use `HELM_UI_SCRATCH` with freshly built dependencies. The earlier K29 gated-run
  discussion is historical.

Current counts, logs and exact Mac SDK priorities are in [VERIFICATION.md](VERIFICATION.md).
Wave 12–17 inventory and deferred integration are in [MAC_HANDOFF.md](MAC_HANDOFF.md).
No source contracts were changed by F12.

## F13

DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04.

- **P8-1:** `ItemOutcome.destinationEvidence: FileMutationPrecondition?` and
  `OperationPlan.expectedEvidence: [URL: FileMutationPrecondition]` are additive
  initializer arguments defaulting to nil/empty. Successful output metadata now
  records identity, token and kind together. UndoPlanner carries that record and
  removes retired source paths as moves/Trash remap outputs. Inverse execution
  seeds ownership exclusively from the journal, verifies all initial output
  identities before any mutation, and retains per-step conditional admission.
  Missing evidence refuses with `verificationUnavailable`; it never adopts the
  current occupant. Legacy manually constructed plans still compile. Tree undo
  still refuses, and missing evidence cannot authorize legacy leaf undo.
- **P8-2:** Core `ConditionalMutationError.cancelledBeforeMutation` guarantees
  zero effects. Fake conditional admission emits it when already cancelled;
  providers must use ordinary errors if effects may have started. Executor maps
  this guarantee to `.cancelled` without reconciliation/quarantine. Read-only
  validation sits outside the uncertain mutation wrapper; ordinary cancellation
  from an invoked primitive still quarantines. Exclusive collision retry retains
  the actual attempted destination and its no-mutation requirement.
- Native atomic mutation remains unsupported, and post-mutation output observation
  is not an atomic receipt. Root evidence is not descendant/content proof. macOS
  SDK compilation and behavior review remain pending Opus after 22:00 Toronto.
- Verification and regression coverage: `docs/prereview/fixes-F13.md`.
