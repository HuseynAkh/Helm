<!-- DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04 -->

K32 supplies the portable M3/M10 FIFO store integration seam. Opus review after
22:00 Toronto on 2026-11-04 and macOS 14/Xcode validation remain required.

Integration
- Construct WindowStore on MainActor with an EffectRunner, HelmClock and context.
  WindowStoreSnapshot contains both window ownership and all tab values. Missing
  values are seeded from home, extras ignored, duplicate inputs keep the first.
  Initialization performs no effects. Bootstrap the active tab with navigate to
  its restored location using .restore; a successful first batch starts monitoring.
- send is synchronous on MainActor. enqueue is nonisolated, admits synchronously
  through a lock, and schedules a main-actor drain. Admission order defines FIFO
  for simultaneous callers (wall-clock call start order cannot define concurrency).
  drain is a synchronous test flush. Runner callbacks may synchronously enqueue.
  Subscribers and runner callbacks never recursively reduce: the current action's
  publication and complete ordered effect list finish before the next action.
- Broadcast has no initial replay. Read state once when binding, then subscribe
  without suspending on MainActor. Each admitted action, even an ignored stale
  callback/no-op, publishes once; there is no coalescing. Sequence is a wrapping
  delivery counter; timestamps come from the injected clock, sampled per action.
  Snapshots have value semantics. Subscribers consume their delivered argument.
  Cancellation during broadcast immediately suppresses later delivery to that
  subscriber; one subscriber cannot mutate another's delivered value.
- Forward actual TabEffect/WindowEffect values to adapters. Return an idempotent
  StoreEffectCancellation for load, monitor, search and completion-request work.
  Store cancels matching retired generations before forwarding cancel descriptors,
  cancels superseded lane handles before starting new work, and cancels all handles
  on tab disposal. Tabs and lanes own independent handles. Fixed cancellation order
  avoids dictionary iteration affecting callback order. Completed handles may remain
  retained until replacement/disposal; their cancellation must be harmless.
- Runners own one-shot work (Recent, validation, refreshPaths, openFile, persistence)
  and should return nil for those descriptors. Runners must implement cancellation
  descriptors for auxiliary work they spawn, and cancel all their tab work on
  .window(.dispose). Callbacks retain their original generations; cancellation does
  not substitute for reducer stale-generation guards. Weak store callback captures
  avoid a runner/store cycle. Keep cancellation closures free of strong store cycles.
- Send .shutdown before releasing a store. It closes admission, drops queued actions,
  publishes the terminal snapshot, then cancels owned handles exactly once. The
  composition root owns runner teardown and one-shot task lifetime. A closeWindow
  effect is only forwarded; the window owner decides when to shut down.
- .persistSession explicitly hands the current atomic snapshot to the runner; the
  app decides save/debounce policy. No disk writes or automatic session saves occur.
- StoreSelectionBinder guards reload plus selection application in one closure,
  filters IDs against the delivered snapshot/expansion state, and suppresses delegate
  feedback during application. Dispatch its userSelection result as setSelection;
  grid command/right-click paths must call it explicitly (00b M-22). It does not
  clear reducer restoration intent when a later cumulative batch can restore IDs.
- Navigation undo/redo uses existing goBack/goForward and NavigationHistory. The
  store adds no second history: failed loads cannot commit navigation (B-069).

Deviations / needed changes elsewhere
- Lane instructions place the Foundation store in HelmCore/Store rather than the
  architecture's HelmUI/State. UI adapters should wrap/reuse this store, qualifying
  HelmCore.WindowStore if they already define a same-named wrapper.
- Reducers already return effects, so no parallel diff-to-effect vocabulary was
  introduced. No reducer changes are required for the implemented surface.
- Persistence policy, service adapters and actual UI bindings remain integration
  work. Context star/settings values are fixed at construction; settingsChanged
  still reaches TabReducer, but app-wide context replacement needs a future action
  if reducers begin using context.settings/starredIDs dynamically.
- No platform widget behaviour or macOS latency is claimed by Linux tests. SwiftPM
  may warn about this README being unhandled; manifest edits are outside K32.

Verification: Swift 6.0.3 in Swift 5 mode, /tmp/build-K32, XCTest, static_checks.sh.
No network, commits, pushes, shared-file edits, or external actions are used.

F6: return a cancellation handle for refreshPaths work. WindowStore now retains
that auxiliary handle independently of the watch, cancels it on monitor retirement,
replacement, tab disposal and shutdown. Generation guards also reject already
queued results. Adapters returning nil remain responsible for cancelling work.
