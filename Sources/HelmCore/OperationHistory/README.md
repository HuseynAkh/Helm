DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04

K38 / P15 N1 owns this directory. Pure per-window history reservations and named
undo/redo stacks preserve F-059 while addressing B-038/B-043/B-100/B-105.
All Core signatures use Core-owned values. No I/O or responder integration.

Host integration: reserve forward work before starting it; retain the window owner
across tab closure; complete exactly once. Route field-editor undo before file undo.
A new admitted forward intent clears redo even if it later fails (conservative
branch policy). Reused request IDs and stale completions are ignored. Known forward
partial work remains undoable through the existing ownership checks. Uncertain
forward work and partial/uncertain inverses are retained and block history.

`acknowledgeReconciliation` is an explicit exit after the host shows original and
inverse journal outcomes (including hidden stage/backup paths) and obtains user
confirmation. It retires only the blocked top undo entry and clears the latch;
it does not repair files, retry work, create redo authority, or erase evidence.
Pending work and absent latches make acknowledgement a no-op.

Redo is explicitly unsupported even when an undone entry exists. Safe reconstruction
from intent and fresh evidence needs a later reviewed integration. Reconciliation UI,
durable recovery, bounded history retention and native text routing remain open.

F22 status pointer (DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04):
read the [Opus/Fable review queue](../../../docs/handoff/REVIEW_QUEUE.md) and
[current verification](../../../docs/handoff/VERIFICATION.md) before acceptance.
Historical lane counts above are not current-suite certification; P16–P18 and
concurrent F19–F21 dispositions require review. Native integration remains pending.
