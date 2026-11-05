<!-- DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04 -->

K31 directory loading integration (M3/M5/M6)

Use one DirectoryLoadPipeline per tab load lane. Feed TabEffect.load's Location,
Generation and LoadOptions to load(), then dispatch each returned TabAction.
Starting another request cancels and closes the prior stream; an internal UUID
also gates late emissions. Cancellation finishes silently. The reducer remains
responsible for rejecting already-buffered stale generations and allocating
accepted snapshot IDs. The checked-in contracts have Generation + Location,
not a distinct K29 LoadRequest type; no replacement Core contract is invented.

Snapshots are cumulative, newest-buffered (one pending action), naturally sorted
and directory-grouped through SnapshotBuilder/ItemSort on a detached worker.
Progress publication grows geometrically to avoid sorting 100k rows every 512
entries. Final completion always replaces pending progress. Entries are deduped
by ItemID, retaining latest metadata. Cache is deliberately bypassed for access
validation; useCache is accepted for effect compatibility. Sorting itself is
synchronous and cannot be interrupted mid-sort; cancellation is checked around
it and identity gates publication immediately.

Use DirectoryReloadCoalescer.actions for the monitor lane; run consume(events)
in a caller-owned task and cancel that task on replacement. Quiet/max deadlines
use HelmClock; flush() supports FakeClock tests. Changed sets become rescan so
bounded buffering never loses an affected path. Root/unmount remain sticky until composition consumes the validation action and
calls acknowledgeRootValidation() after successful validation, or replaces the
watch. Unavailable errors never demote root validation and do not suppress later
recovered changes. The reducer requests validation for unavailable errors too.
Handle reducer refreshPaths by using a SEPARATE pipeline's reload(), forwarding
monitorSnapshot. It emits only a complete snapshot so the reducer preserves
selection IDs absent from intermediate batches. Do not restart the navigation
worker for monitor events. Composition owns monitor start/stop and cancellation.

Needed changes elsewhere / deviations:
- FileSystem.enumerate and both existing live/fake adapters have unbounded raw
  batch buffers. This pipeline bounds its OUTPUT, not upstream producer memory;
  lossless end-to-end backpressure needs a pull-based enumeration protocol or
  acknowledged producer channel in their owned files. Dropping raw batches is
  incorrect and is deliberately avoided.
- LiveFileSystem currently throws on a child's metadata failure. Optional
  RecoverableDirectoryEnumerating lets an adapter yield LoadEvent.warning and
  continue after skipping that child. Wire that capability in the live adapter;
  ordinary terminal stream errors cannot be resumed. The pipeline reports them
  as failures, never claims a truncated listing is complete. isReadable=false
  entries remain visible with diagnostics rather than disappearing.
- TabAction/PresentationSnapshot has no partial-read warning field; diagnostics
  use a synchronous Sendable callback. The composition root must surface these.
- There is no independent grouping parameter on SnapshotBuilder; ItemSort's
  directory grouping is preserved, not a second invented grouping contract.
- macOS/Xcode and Opus review remain required. No external actions performed.

F6 integration: use the new monitor generation after every foreground refresh;
return reload cancellation handles to WindowStore. Root acknowledgement belongs
to the validation adapter (outside this lane); never acknowledge before consuming
and successfully completing validation. Native macOS watcher behavior remains
pending Opus/Xcode review. No public action contract changes were needed.

K34 adds DirectoryEffectRunner for WindowStore startMonitor, refreshPaths and
validateNavigation effects. Compose its fallback with the host's other effects;
load/search/persistence remain with that fallback. Supply current per-tab options.
WindowStore retains and cancels validation handles alongside watch/reload handles.
Validation success acknowledges only the coalescer revision it inspected; a newer
root event remains sticky. Validation failure emits monitorValidationFailed once,
so the reducer reports failure without an unavailable/validate feedback loop.
Full reloads intentionally subsume changed-path sets. No native watcher acceptance
is claimed by the Linux adapter tests.
