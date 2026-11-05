DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04

K38 / P15 N1: WindowOperationHistory is a value-only actor, one per window. Capture
it before execution; call beginForward(command), execute through the existing host,
then completeForward with that completed journal entry. beginUndo returns one
reservation and the existing UndoPlanner plan; the host executes it unchanged and
calls complete(request:outcome:). All overlapping work is rejected while reserved.
Host must retain results for reconciliation and refresh affected directories even
on failure. Do not register inverse/recovery journal entries as forward commands.

No executor, filesystem, journal storage, app or text responder wiring is changed.
Tree inverses and missing ownership evidence still encounter the existing executor
refusal. Planning refusal and execution refusal leave the original entry in place.
Partial/uncertain completion blocks all history; recovery UI/receipts are future work.
A reservation cannot be released by a UI cancellation before native work has settled.

Redo is intentionally unsupported for all commands: no stale plan replay, no claim
that old source paths still identify the same objects. A future implementation must
reconstruct recorded intent using fresh validated ownership and planning facts.
Open: native atomic receipts, safe redo, reconciliation resolution, durable storage,
history retention limits, host refresh/text-focus routing and macOS/Opus review.
