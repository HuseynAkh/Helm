K38 / F19: WindowOperationHistory is a value-only actor, one per window.
Capture it before planning and call beginForward(command). If preparation throws
or is cancelled before execution, call abortForward(request:failure:). This is
single-use, request-matched and unavailable once execution has been bound.

For forward and inverse execution, capture the reservation and exact plan in
OperationExecutor.execute(plan, admission: { operation, executingPlan in
    await history.bindExecution(request: request, operation: operation, plan: executingPlan)
}).
The executor awaits this callback before filesystem access. Returning false
prevents mutation. Never launch an unbound execution and later attempt to bind
its result. Retain the execution task; cancellation after binding must await its
terminal result. A busy/quarantined executor now journals a genuine refusal with
one notAttempted outcome per step and calls admission before returning it.

Forward completion takes the completed journal entry. beginUndo returns a
reservation and the existing UndoPlanner plan; execute that unchanged, then call
complete(request:outcome:). Both completion paths require the bound operation ID
and the entire ordered step definitions/IDs. Malformed, empty-for-nonempty-plan,
foreign and duplicate evidence leaves the pending reservation untouched.
Forward history retains the bound plan, not replacement metadata supplied at
completion. Inverse attempts never enter the forward stack.

Host must retain results for reconciliation and refresh affected directories even
on failure. All overlapping history work is rejected while reserved. Preparation
abort preserves redo invalidation. Tree inverses and missing ownership evidence
still encounter executor refusal. Planning/execution refusal retains the original
undo entry. Partial/uncertain completion blocks history until future reconciliation.

Redo remains unsupported: no stale-plan replay. Open: native atomic receipts,
safe redo, reconciliation resolution, durable storage, retention limits, host
refresh/text-focus routing and macOS/Opus review. Host integration must adopt the
admission callback; direct unbound completions now intentionally return false.

F23: inverse admission compares the entire immutable plan, including verification,
all ownership maps, issues and every planning context field. Reconstructing a plan
with default fields is refused before filesystem access. If undo preparation is
cancelled or fails before binding, call abortUndo(request:failure:); it preserves
both stacks and records the failure. Abort and bind are serialized by the actor:
a successful abort rejects late binding, and successful binding rejects abort.

AO3 DRAFT (2026-11-05): admission receives `(operation, executingPlan)`; forward
that supplied plan directly to `bindExecution`. If binding returns false, the
host must call the matching `abortForward` or `abortUndo` for its still-pending
reservation. Rejected binding itself does not consume the reservation.
Construct executors with an explicit shared `TrashOriginRecording` store and
supply `beginUndo(recordedOrigins:)` explicitly. Empty origins are appropriate
only when the inverse contains no Trash restoration.

`beginForward(command, group:)` reserves under a `HistoryGroup`: the reservation and the
entry it leads to take the group's name, and the entry carries the group. Without a group
nothing changes.

A host undoes a group by undoing the top entry and going on while the next one carries the
same group and the last Undo succeeded. A failed Undo leaves that entry and the rest in place;
one left unsure latches the history, and acknowledging it retires that entry only.

A step that stalls leaves the executor refusing every later operation as busy. After the
person acknowledges the stalled change, the host calls `OperationExecutor.clearQuarantine()`.
It asks `FileSystem.reopenAfterStall()` and lets operations run again only when that answers
true; false means a stalled call is still out, so the host asks again before its next operation.

A permissions change from Properties is one entry too, named "Change Permissions", made by the
host without the executor: one item's mode, never anything inside a folder. Reserve with
`beginPermissionChange()`, make the change, then `finishPermissionChange(request:change:)` with
the `PermissionChange` (item, identity, mode before and the mode the disk kept), or nil when
nothing changed. When `permissionChangeToUndo()` names the top entry, Undo is
`beginPermissionUndo()` then `finishPermissionUndo(request:restored:)`; a refusal leaves the
entry, as an operation's refused Undo does. Redo is `beginPermissionRedo()`, ended by
`finishPermissionChange` as a new entry. The plain `beginUndo` and `beginRedoForward` don't
handle these entries, so the host asks first.
