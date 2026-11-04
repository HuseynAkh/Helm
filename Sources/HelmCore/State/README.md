<!-- DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04 -->

K8 implements M3 portable state values and reducers. No I/O is performed here.
All code remains subject to Opus compile-correctness and behavior review after
22:00 Toronto on November 4, 2026, and subsequent macOS 14/Xcode validation.

Integration:
- Call TabReducer.reduce with a sampled ReducerContext. Execute returned effects
  in the store, retaining lane generations on every callback. Cancellation alone
  is insufficient. Use the FIFO/non-reentrant store publication rule from the spec.
- Navigation starts loading without changing committed state. The first successful
  batch (including an empty finished listing) commits history, location and Recent.
  A pre-commit error preserves the old listing and records the attempted destination.
  Producers supply cumulative batches, not deltas. Failure callbacks use loadFailed.
- SnapshotBuilder runs in the producer task. Publication stamps a per-tab counter
  without rebuilding arrays. A changed sort performs one rebuild; a late batch with
  an obsolete sort is reordered before publication. Index reads never sort.
- Snapshot equality intentionally compares presentation identity only, scoped to a
  tab. Compare entries explicitly in content tests. The constructor derives its own
  index and safely deduplicates entries instead of accepting a caller-supplied index.
- Views must apply the selection and snapshot together, suppressing programmatic
  selection feedback. Expanded children are represented only by snapshot.children.
  Producers supply expanded topology in snapshots; this milestone does not initiate
  per-folder child enumeration. Collapse removes hidden selected children.
- Monitor snapshots are cumulative and ignored while a load/navigation is in flight;
  the adapter should coalesce/rescan afterward. Monitor root changes emit validation
  requests, never an invented replacement path. Monitor identity renews on commit
  and activation. validateNavigation carries the monitor lane token.
- Search is a separate overlay. Background loads/monitor snapshots update the stored
  base listing, never the search display. Clearing search restores that listing and
  selection without recording Recent or creating a history entry. Search starts from
  an explicit SearchQuery (scope belongs to the caller). Hidden changes restart it.
- Inline rename defers listing publication until endInlineRename. Explicit navigation
  or search ends the rename. The store remains responsible for the editor lifecycle.
- Completion delegates to K3 AddressEditorState/Action/Effect, with its generation as
  the independent completion lane. This deliberately avoids the older minimal K1
  AddressBarState contract. Forward wrapped editor effects to the K3 adapter.
- Window closeTab keeps the last tab; closeCurrentTab emits closeWindow for it.
  IDs are caller-supplied, so reducers create no random identities. Tab teardown is
  an effect; it does not delete app-owned operation state.

Deviations/open questions:
- The architecture's broad UI action inventory (operation summaries, star propagation,
  loadChildren/watch-scope updates, automatic search-text scope derivation) is outside
  this focused M3 transition surface and requires adapter integration/later milestones.
- Sort changes are synchronous pure rebuilds here; moving their execution off the UI
  actor requires a tagged sort effect or invoking the reducer off that actor. The
  100k fixture validates stable indexed lookups, not macOS latency or widget behavior.
- Public mutable TabState fields follow the architecture, but callers should transition
  through reducers to preserve invariants. WindowState enforces tab identity invariants.
- No changes to other lanes' types are required. Reconcile the broad architecture
  signatures with this concrete action/effect API when wiring HelmUI.

Verification uses /tmp/build-K8, Swift 6.0.3 in Swift 5 language mode, XCTest and
scripts/static_checks.sh. No network, commits, or external actions were used.
