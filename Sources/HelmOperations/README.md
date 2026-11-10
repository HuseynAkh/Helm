<!-- DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04 -->
# K6 integration notes

Portable M7 implementation and conservative M8 draft. Preserves F-051–F-057,
F-059/F-061; addresses B-031/B-036–B-043/B-046/B-047/B-100/B-105.
No network, commits, publishing, real pasteboard writes, or real system Trash
operations were performed. Tests mutate only InMemoryFileSystem and isolated
TempDirectory fixtures. The old Helm app and other lanes are untouched.

## Integration

- Build PlanningContext asynchronously with PlanningContextBuilder; pass complete
  destination snapshots and volume case-sensitivity values. Unknown sensitivity
  defaults to case-insensitive. The manifest enumerates hidden children without
  following links. Available capacity is checked cumulatively for transfer copies.
- OperationPlanner is pure. Use `transfer(...to: Location...)` and
  `creation(...in: Location...)` for background commands so Recent/Trash cannot
  reuse a stale directory. Explicit source operations remain available in Recent.
  Overlapping selections are rejected. Same-parent moves produce no steps.
- ConflictPolicy supports per-source decisions and apply-to-all. `resolve` replans
  against the retained snapshot. K2 UniqueNamer and BatchRenamePlanner provide all
  numbering and swap ordering, including case-only rename. Final-extension
  splitting currently follows K2/legacy (`a.tar 2.gz`). This is the unresolved
  B-116 deviation: architecture requires `a 2.tar.gz`; HelmCore owns the fix.
- Retain one OperationExecutor and its OperationJournal per window association
  in the app registry until pending work finishes. Call async `execute`, retain
  the caller task for cancellation, and optionally supply an async progress
  callback. Counts are filesystem primitives, including staging/verification,
  NOT user-selected item counts or byte progress. Reentrant execution is refused.
  `PlannedStep.item` ties the steps of one item together (a replacement's stage,
  check, retirement and install; a move between disks). `PlanItems` turns steps
  into items: Skip leaves a whole item, and questions, the operations panel and
  results count and name items, never a private stage.
- Journal records each completed boundary, exact actual destinations, all later
  unattempted steps, and completion exactly once. Generic mutation failures mark
  reconciliation required. A timeout quarantines this executor; never recreate it
  merely to retry a possibly still-running mutation.
- UndoPlanner reverses successful primitives, including temporary swap names and
  retained replacements. It uses exact recorded Trash origins and checks final
  output change tokens at execution. Nil Trash URLs or missing tokens/origins
  block automatic undo. Known pre-mutation cancellation/conflict can reverse the
  completed prefix; uncertain mutations require explicit reconciliation first.
- ClipboardTransaction is pure and invalidates on external changeCount changes.
  Feed `OperationResult.completedMoveSources` to partial-cut acknowledgment. The
  MainActor FilePasteboard adapter must implement atomic compare-and-write in one
  synchronous turn and return the post-write counter. No adapter is instantiated
  by this module.

## Draft deviations and review questions

- Cross-volume moves copy, verify tree kinds/sizes plus original source tokens,
  then move the source to Trash instead of permanently removing it. This retains
  recovery data and never falls back to deletion if Trash is unsupported. Source
  and copied destination are reverified immediately before source retirement.
- Replacement stages and verifies a whole new tree, trashes the original in
  place under its real name, then installs the stage. Each mutation is
  journaled separately. Failure retains artifacts; there is no automatic rollback
  or directory merge. This is recoverable, not atomic replacement.
- Whole-tree Foundation copying supplies no intra-file or per-child cancellation
  or progress. TreeCopyVerifier checks kinds/sizes, not byte hashes, symlink target
  strings, ACLs, xattrs, resource forks or provider metadata. Native fidelity,
  directory metadata ordering and conditional identity-safe source retirement
  need Fable/Opus review. Parent symlinks are conservatively refused rather than
  silently redirecting writes; path checks cannot eliminate external TOCTOU races.
- Runtime name rechecks reuse K2 numbering. Bounded retries require the explicit
  ExclusiveDestinationConflict guarantee that NO mutation occurred. Live exclusive
  creation maps EEXIST to collision(noMutation: true); generic
  copy/move collisions retain noMutation: false. Ordinary uncertain races stop
  instead of guessing from an error string. Staged/dependent steps
  never silently choose a different destination.
- This journal is an in-memory begin/step/complete store, not durable storage or
  the complete menu-facing undo/redo stack/coordinator. Recovery is planned and
  executed explicitly. Crash recovery, app ownership wiring, undo/redo UI titles,
  conflict sheets, per-volume scheduling and Mac Trash integration remain M8/M22.
- Creation retains legacy keep-both naming; replace/skip/stop choices apply to
  transfers. Rename collisions block up front. Unknown available capacity is not
  a zero-space assertion; template creation capacity is not yet estimated.
- Public primitive/result types intentionally reflect this smaller executor,
  rather than claiming every proposed section 7 command/summary field exists.
  Permanent delete and Empty Trash are not in this lane's commands. Aliases and
  symbolic links are (`Command.link`), so Undo moves what they made to the Trash.

## Needed changes elsewhere

- K23/K34 provide typed collision and conditional no-follow contracts. A native
  conditional implementation, stronger content/link verification and atomic output
  evidence remain needed. No string matching is used here.
- Composition/UI: inject actual per-volume case sensitivity, retain journal/task
  lifetime, supply the pasteboard adapter and confirmation/conflict presentation.
- Persistence: inject TrashOriginRecording; its current nonthrowing contract
  cannot report an origin persistence failure. Add durability acknowledgment when
  designing persistent journal/Put Back recovery.
- Manifest owner: exclude README.md files from Swift target source discovery to
  remove SwiftPM unhandled-file warnings. K6 does not edit Package.swift.

## Verification

Use `source /workspace/toolchains/env.sh` followed by:

```
swift build --scratch-path /tmp/build-K6 --target HelmOperations
swift test --scratch-path /tmp/build-K6 --filter HelmOperationsTests
bash scripts/static_checks.sh
```

Linux Swift 6.0.3, Swift 5 language mode. Tests cover planning policies and virtual
refusal, K2 numbering, swap and replacement failure at every boundary, recovery
round trips, partial cut, cancellation, stale output/source protection, reentrancy,
exclusive collision retries, timeout quarantine, no-follow manifests, nullable
Trash origins, and real temporary-directory copying/creation. macOS 14/Xcode and
native Trash remain unverified; all files require Opus review after 22:00 Toronto.

## K17 fixes and integration

BUG-K15-1: executor equality/ancestry checks now use the source parent's declared
PlanningContext.caseSensitive value for both normalized paths. This tests whether
the destination denotes the source or lies inside it in the source namespace;
a different destination volume's semantics must not redefine that ancestry.
Destination-name collision checks continue to use destination-parent semantics.
Supply case sensitivity for source parents as well as destination parents; absent
entries retain the conservative case-insensitive default. K23 added
FileSystem.isCaseSensitive and FileSystemError.collision(noMutation:).
PlanningContextBuilder queries missing case capabilities; explicit inputs win.
Only a collision with noMutation == true authorizes retry. Generic live copy/move
collisions do not make that guarantee. The local failure remains OperationError.conflict.
K15 regressions and K17 namespace-boundary tests cover these planning rules.

## F2 safety pre-review fixes

DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04.
Cancellation after a native primitive starts waits for its real completion (or
existing timeout quarantine); completed mutations remain journaled. An adapter
that throws cancellation during mutation quarantines this executor for reconciliation.
Undo tokens are rechecked after progress and preflight immediately before move or
Trash; successful internal moves remap the token to the actual output path.
The residual native stat/mutate race needs a coordinated compare-and-mutate seam.

Automatic undo refuses to Trash directories/packages with only root-token evidence,
including unchanged copied trees and newly created folders. This deliberately does
less until complete no-follow identity/content manifests can be added through a
reviewed public contract (P2-3 DEFERRED, unsafe retirement mitigated). UI should
surface verificationUnavailable as requiring review, never silently retry without
preconditions. Ordinary user-requested Trash requires a supporting conditional provider;
LiveFileSystem executor Trash remains unavailable.

Planning uses component-prefix indexes, cached normalized paths/names and aggregate
manifest byte counts; journal duplicate checks use StepID sets. The 100k sibling
copy/journal fixture reports elapsed time without machine-dependent timing gates.
No public signature was changed. See docs/prereview/fixes-F2.md for all findings.

## K29 automatic undo contract

UndoPlanner emits OperationPlan.undoVerification = .leafOnly, with expectedKinds
captured from ItemOutcome.destinationKind. The executor refuses missing kind/token
evidence and directory/package inverses before starting any planned mutations,
then rechecks each inverse immediately before mutation. Successful internal moves
remap kinds and tokens. This extends F2's Trash-only guard to directory moves and
restores as well. P2-3 is resolved by explicit conservative refusal, not by claiming
root metadata verifies descendants: unchanged trees also require reconciliation.
Source token comparison and native mutation are still separate calls; full tree
manifests and atomic identity/content comparison remain future contract work.

## F7 forward safety and replacement fixes

Forward execution now carries source kind/change-token evidence from the manifest,
and destination evidence from `PlanningContext.existingEntries`. The builder fills
that additive snapshot field together with destination names; callers constructing
contexts manually should supply it. Legacy/manual destructive plans snapshot their
initial sources before progress starts, so their protection begins at execution,
not at planning. Undo keeps its separate leaf-only policy and recorded output tokens.

Completed copies/moves capture output evidence before the next progress
callback. Dependent mutations recheck it after preflight; missing metadata preserves
the successful outcome and stops dependent work for reconciliation. Verification
cannot replace an artifact's earlier ownership evidence.

Directory Move and Trash are provider-dependent: InMemoryFileSystem supports the
conditional boundary; LiveFileSystem inherits refusal, so live executor
copy/move/Trash are unavailable. Exclusive creation remains available. Direct
primitives are distinct from executor support. Directory root evidence does not
prove unchanged descendants; see the K34 conditional contract below.

Replacement tracks the actual original destination spelling separately from the
incoming installed name, including case/Unicode equivalence. Undo restores that
original spelling. Cut completion uses one outcome pass and one source pass; its
internal visit hook tests the production extraction path at 100,000 sources.

K34 supersedes the missing-contract prerequisite: Core identity values and
conditional FileSystem/FileCopier APIs now exist. A reviewed native conditional
mutation provider and atomic output evidence remain needed. Root identity/token
evidence is not complete content or descendant proof; post-mutation observation
races remain open. Native macOS and Opus review
remain required. See `docs/prereview/fixes-F7.md` for verification and residual risks.

K34: forward evidence retains provider identity with kind/token; the executor uses
conditional filesystem move/Trash and the conditional FileCopier overload. Legacy
copiers compile but refuse the new overload until they implement the atomic
contract. Confirmed conditional refusals do not request reconciliation; unknown
I/O completion still does. InMemoryFileSystem provides the atomic boundary. Live
conditional operations refuse, so native copy/move/Trash through this executor
remain unavailable pending a reviewed native implementation. Exclusive creation
is unaffected. Tree undo remains refused: root identity is not descendant proof.
The output-mutation-to-metadata-read window remains a separate open limitation;
no complete content proof or durable identity receipt is claimed by this change.

## F13 recorded undo evidence and cancellation

ItemOutcome.destinationEvidence records optional identity, kind and change token;
UndoPlanner carries it into OperationPlan.expectedEvidence. Inverse execution seeds
ownership only from the journal, checks all initial outputs before any inverse,
and supplies evidence at each conditional mutation. Internal move/Trash paths
remap evidence. Missing recorded identity refuses automatic leaf undo; a fresh
pathname observation cannot supply it. Tree/package undo still refuses even when
unchanged. Output metadata is observed after mutation, so the completion-to-read
race and same-object/same-token content edits remain unproven.

ConditionalMutationError.cancelledBeforeMutation guarantees zero effects and maps
to cancelled without reconciliation or quarantine. Read-only validation cancellation
also leaves the executor usable. Ordinary cancellation thrown by a potentially
started primitive remains uncertain and quarantining; successful started work is
journaled and timeout quarantine remains. Providers must not use the clean case
for uncertain completion. F13ContractTests, F13UndoEvidenceTests and
F13CancellationTests cover substitution, missing identity, remapping and both
cancellation boundaries; native conditional support remains absent.

## SC2b template evidence note

Hosts must include a create-from-template source in `PlanningContextBuilder`'s
`sources`, so the plan carries source evidence. A manually assembled plan without
that evidence only snapshots its template when both `sourceManifest` and
`existingEntries` are empty; a non-empty destination can therefore turn the same
incomplete plan into a refusal. `ForwardEvidence.capture` deliberately refuses
missing evidence rather than adopting a replaced object (O1-11). This note does
not change the evidence contract or authorize native mutation.
