DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04

K38 / F19: WindowOperationHistory is a value-only actor, one per window.
Capture it before planning and call beginForward(command). If preparation throws
or is cancelled before execution, call abortForward(request:failure:). This is
single-use, request-matched and unavailable once execution has been bound.

For forward and inverse execution, capture the reservation and exact plan in
OperationExecutor.execute(plan, admission: { operation in
    await history.bindExecution(request: request, operation: operation, plan: plan)
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
