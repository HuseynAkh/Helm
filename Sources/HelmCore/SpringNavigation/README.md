DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04

K41 / P15 N6: value-only F-067 spring unwind transaction. The host retains one
session per drag/tab and polls the existing SpringLoadingModel through this API.
Load callbacks must return the exact request and fresh target metadata. Only a
commit effect may enter history/Recent; displayTemporary and restore must bypass
normal committed navigation. Escape/failed drop restores original selection and
scroll. Owner close terminates silently. FileDropSession validates accepted intent;
execution must still perform its own filesystem validation. This model does no I/O.

Virtual destinations are unsupported for spring/drop acceptance, including Trash;
original virtual contexts can be restored. Destination comparison uses local lexical path, kind and objectIdentity; mutable
size, dates, child counts and star state do not restart hover or reject success.
Commit requires nonnil matching object identities. Missing identity emits
`destinationUnverified` and restores the original context without history commit.
Hosts must supply verified destination evidence; these values never authorize a
filesystem mutation. Remote/decorated URLs and parent components are refused at
the spring boundary; invalid sources refuse drop admission. Failed
hover loads retain the current transient location; cancel unwinds the transaction.
Host load cancellation, per-level live scroll capture, native drag lifecycle and
commit routing remain integration work. No existing navigation/store is changed.

F22 status pointer (DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04):
read the [Opus/Fable review queue](../../../docs/handoff/REVIEW_QUEUE.md) and
[current verification](../../../docs/handoff/VERIFICATION.md) before acceptance.
Historical lane counts above are not current-suite certification; P16–P18 and
concurrent F19–F21 dispositions require review. Native integration remains pending.
