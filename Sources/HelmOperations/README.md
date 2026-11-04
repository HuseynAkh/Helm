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
  splitting deliberately follows K2/legacy (`a.tar 2.gz`), winning over the stale
  architecture sentence about compound-extension splitting.
- Retain one OperationExecutor and its OperationJournal per window association
  in the app registry until pending work finishes. Call async `execute`, retain
  the caller task for cancellation, and optionally supply an async progress
  callback. Counts are filesystem primitives, including staging/verification,
  NOT user-selected item counts or byte progress. Reentrant execution is refused.
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
- Replacement stages and verifies a whole new tree, moves the original to an
  owned backup path, installs the stage, then trashes the backup. Each mutation is
  journaled separately. Failure retains artifacts; there is no automatic rollback
  or directory merge. This is recoverable, not atomic replacement.
- Whole-tree Foundation copying supplies no intra-file or per-child cancellation
  or progress. TreeCopyVerifier checks kinds/sizes, not byte hashes, symlink target
  strings, ACLs, xattrs, resource forks or provider metadata. Native fidelity,
  directory metadata ordering and conditional identity-safe source retirement
  need Fable/Opus review. Parent symlinks are conservatively refused rather than
  silently redirecting writes; path checks cannot eliminate external TOCTOU races.
- Runtime name rechecks reuse K2 numbering. Bounded retries require the explicit
  ExclusiveDestinationConflict guarantee that NO mutation occurred. K5 currently
  collapses EEXIST into a generic error, so ordinary live races stop and retain
  their failure instead of guessing from an error string. Staged/dependent steps
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
  Permanent delete, Empty Trash, aliases and links are not in this lane's commands.

## Needed changes elsewhere

- K5: preserve a typed exclusive EEXIST/no-mutation guarantee for safe live retries;
  expose content/link verification and conditional no-follow mutations for stronger
  copy verification and race protection. No string matching is used here.
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
entries retain the conservative case-insensitive default. K5's FileSystem protocol
currently has no sensitivity query, so the builder still requires caller input.

K15's two regressions are enabled. K17 covers sensitive and insensitive same-item
checks, recursive destinations, mixed declarations, component boundaries, and the
unknown-sensitivity fallback for manually constructed plans.

Needed changes elsewhere: K5's FileSystemError still has only notFound,
permissionDenied, timedOut, unsupported and other(String), with no typed collision.
K5 must expose collision semantics (including whether any mutation occurred)
before this executor can safely map/retry them. No string-based translation was
added. The existing typed local failure is OperationError.conflict (the current
implementation's name for the proposed OperationFailure). Public API unchanged.
