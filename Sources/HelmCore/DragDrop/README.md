<!-- DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04 -->
# K25 drag and drop values

Foundation-only, synchronous, Sendable models; no filesystem reads, scheduling,
pasteboard writes or operations execute here. Tests live in
`Tests/HelmCoreTests/DragDropTests` (the existing HelmCoreTests target).

## Integration

- Resolve dragged sources and row targets from the same presentation snapshot by
  ItemID (B-009). DragSourceModel preserves snapshot order and selected descendants.
  The planner rejects overlapping sources rather than silently dropping children.
- Supply actual destination metadata and cached volume IDs. DropDestination's
  directory/writable defaults are convenience inputs, not filesystem verification.
  For expanded list rows resolve their actual parent before constructing a background
  destination (B-079). A file row is not a directory: UI may explicitly target its
  parent to preserve legacy F-067 fallback. No insertion gap is requested (B-074).
- Cache the entire DropProposal from the last drag update. Execute its exact sources,
  destination and operation, without rereading modifiers at acceptance (B-045,
  P-270/P-274). Intersect source masks through allowedOperations. A refused desired
  operation is not silently replaced with another operation. UI maps AppKit's source
  move capability to moveToTrash where appropriate. Include `.generic` in the source
  mask for Command semantics (architecture review Fix 37).
- Convert copy/move/trash intents into HelmOperations Command, then preflight and
  execute through the existing journal (B-044, P-137). Do not treat this lexical
  preflight as filesystem authorization: aliases, symlinks, case-insensitive volumes,
  source changes and write permissions must be validated by the operations layer.
- SpringLoadingModel accepts the existing HelmClock. Feed settings-derived seconds,
  poll from an adapter timer, cancel on leave/drop/Escape/end. Space uses
  `poll(openImmediately: true)`. Repeated updates do not reset a hover or fire twice;
  leave/re-entry rearms, and changing eligible folders restarts the delay (P-273).
- PromisedFilePlaceholder names are display metadata, never paths. The AppKit promise
  receiver owns materialization, cancellation and validation (P-271). Classify chooses
  file URLs, then promises, then nonempty text. Text is classified but never written.
- Tab insertion slots refer to the original array; reorderIndex adjusts for removal.
  Midpoints select the following slot. Transfer preserves tab/controller identity,
  and the adapter must detach before attaching to another window (P-003/P-005).
  A single-tab tear-off is a no-op; moving that existing window belongs to UI.
- Auto-scroll returns signed points/second independently per axis. Integrate using
  elapsed seconds, clamp to scroll bounds, and stop polling outside the viewport.

## Behaviour choices and deviations

F-067 source URL semantics remain; P-118 replaces unconditional moves with same-volume
moves and cross-volume copies. Unknown/empty IDs and mixed source volumes use one
conservative copy proposal. Option forces copy, Command move, Option+Command alias;
Control also aliases as explicitly requested by K25. Trash ignores these modifiers
and proposes only moveToTrash (P-155/P-277). Search overlays and Recents reject drops.
Same-parent moves and unmodified same-parent drops (even with unknown volume IDs)
reject the whole batch (B-040); explicit copy/alias remains allowed
for intentional duplication. Self/descendant checks apply to all operation kinds
except Trash and use standardized path components, so `/a` does not contain `/ab`.
Mixed no-op and actionable move batches reject as a whole; no partial proposal.
Invalid spring delays fall back to one second; negative delays become zero. Invalid
geometry is inert. Drag threshold is Euclidean and inclusive; no movement never
starts a drag. Image stacks default to three images with the full multi-item badge.
These geometry constants are adapter-configurable choices, pending Mac review.

## Needed changes elsewhere

- Architecture places DropPlanner/DropModifiers in HelmOperations; this explicit K25
  assignment places them in HelmCore. Consumers should import/reuse these declarations,
  not introduce duplicate types (review Fix 1). No manifest change is needed.
- Existing HelmOperations Command/PlannedStep lacks alias creation. Add a guarded
  macOS alias command/executor before advertising alias in a live adapter's source mask.
- Wire the UI adapters, settings delay, timer cancellation, negotiated proposal retention,
  journal routing and promise receiver. No AppKit behaviour has been validated on Linux.
- Location has no search case; pass isSearchResults for that overlay. A future shared
  destination contract could carry this context directly.

Opus compile-correctness and behaviour-preservation review remains required after
22:00 Toronto on 2026-11-04. macOS 14/Xcode validation remains outstanding.

F1 prereview integration (draft): overlap validation sorts standardized component
arrays and checks adjacent paths, retaining the original execution order (P1-2).
The overlap scan performs at most n-1 prefix checks after O(n log n) sorting;
component depth/string comparison costs still apply. A 10k selection test reports
elapsed time diagnostically, without a platform-dependent latency assertion.
Selection validation caching remains adapter/public-contract work: this stateless
API has no drag-session lifetime. No global mutable cache was introduced.

K29 adds DropSession for the deferred session cache. Construct once per native drag,
retain across target/modifier updates, replaceSources when ordered source metadata
changes, and end on termination. The session caches source path normalization and
overlap validation, not target permissions or execution preconditions. End is
terminal and releases source paths; no global cache or native drag owner exists.
