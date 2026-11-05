<!-- DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04 -->
# K33 catalogue persistence

Share one TagCatalogStore per document across windows; await initialization before
editing and explicitly await flush at save/quit. MainActor serializes mutations;
a private disk actor performs reads, atomic writes and monotonic-revision checks.
There is no debounce or automatic write. Flush failures throw and preserve edits.

Catalogue array order is the favourite-tag order. Seven initial colours use Finder
indices from HelmCore. Case folding uses a fixed POSIX locale and canonical Unicode
composition; first spelling/colour wins during merge. Invalid empty, newline or NUL
names are ignored on discovery and rejected on rename. Unknown colour suffixes are
retained. Rename/recolour/delete affect only this catalogue, never file xattrs,
Finder preferences, stars, or disk-wide tags (F-029, M18/P-305).

The shared VersionedDocument envelope writes schema 1 with [FinderTag] items.
An explicitly defined draft schema 0 ([String] raw metadata items) migrates in memory
and writes schema 1 only on explicit flush. There is no pre-existing legacy Helm
catalogue to import; confirm this migration fixture format during Opus review.
Unknown envelope versions throw without touching the original. Malformed documents
are copied byte-for-byte to a unique .corrupt-UUID backup, then return defaults with
isReadOnly and recoveryBackupURL. All mutations and flush are refused thereafter.
The original is never silently replaced; recovery/replacement UI is outside K33.
Read/backup failures throw; only definite ENOENT authorizes a new document.

Needed changes elsewhere: wire catalogue UI and explicit save/error/recovery flow.
No Core signature change is required; FinderTag remains owned by HelmCore.
The helper lives here because K33 owns only Tags/ and ViewOptions/; both stores use
it rather than JSONFileStore's more permissive corruption recovery. No changes to
JSONFileStore or its F3 safety behavior were made. macOS/Xcode validation and Opus
compile/behavior review remain outstanding after 22:00 Toronto, 2026-11-04.

Verification evidence: K33TagCatalogTests asserts exact ordered round trips,
Unicode merge identity, invalid edit refusal, v0 migration, unknown envelope refusal,
byte-identical corrupt backup/original retention and concurrent merge/flush results.
K33PreferenceDocumentTests checks stale-revision refusal and retry after save
failure. These are local document tests, not Finder interoperability acceptance.
