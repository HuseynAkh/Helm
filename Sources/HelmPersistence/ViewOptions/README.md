<!-- DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04 -->
# K33 location options persistence

LocationViewOptionsStore retains Core ViewOptions (mode, sort, grouping, columns,
icon/text size). Use one MainActor instance per document, await initialization,
and explicitly flush on save/quit. Disk access uses Tags/PreferenceDocumentFile;
there are no automatic writes, existence probes, timers or global settings writes.

Keys are path:<standardized path> or symbol:recent/symbol:trash. Symlinks and case
are not resolved, preserving K10 identity. Records are persisted in LRU order;
reads touch recency, missing locations inherit global defaults without a slot.
Use-as-defaults changes inheritance without changing explicit overrides. Capacity
is clamped to zero, defaults to 256, and applies on both restore and mutation.
Last duplicate record wins. Explicit removeRecords(forVanishedLocations:) removes
only supplied keys; disconnected volumes survive unless the caller removes them.

Envelope schema 1 stores defaults plus records. Core owns nested option versioning
and validation. Unsupported envelope versions throw; nested unknown versions/enum
values are treated as unreadable data, backed up and exposed as read-only defaults.
Both paths retain original bytes. Corruption recovery never authorizes overwrite;
a future recovery UI must explicitly resolve the original and create a fresh store.
This is stricter than JSONFileStore's recoverCorruption=true path (F3/B-029).

Needed changes elsewhere: connect view-options UI to this store and explicit flush,
show recoveryBackupURL/isReadOnly, and handle thrown initialization/save errors.
Core's in-memory ViewOptionsStore cannot expose its records for restoration, so
this adapter owns its serializable LRU rather than changing K10's shared contract.
Reconcile global SettingsSchema icon limits (48–128) with Core folder options
(16–512) in the owning lane. macOS/Xcode and Opus review remain outstanding.
