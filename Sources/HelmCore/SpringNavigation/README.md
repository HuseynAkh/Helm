DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04

K41 / P15 N6: value-only F-067 spring unwind transaction. The host retains one
session per drag/tab and polls the existing SpringLoadingModel through this API.
Load callbacks must return the exact request and fresh target metadata. Only a
commit effect may enter history/Recent; displayTemporary and restore must bypass
normal committed navigation. Escape/failed drop restores original selection and
scroll. Owner close terminates silently. DropSession validates accepted intent;
execution must still perform its own filesystem validation. This model does no I/O.

Virtual destinations are unsupported for spring/drop acceptance, including Trash;
original virtual contexts can be restored. Destination equality conservatively
includes all supplied metadata, not an atomic object identity guarantee. Failed
hover loads retain the current transient location; cancel unwinds the transaction.
Host load cancellation, per-level live scroll capture, native drag lifecycle and
commit routing remain integration work. No existing navigation/store is changed.
