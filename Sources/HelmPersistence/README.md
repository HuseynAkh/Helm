<!-- DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04 -->
# F3 persistence integration

Load before editing; share one store per document. Only a definite missing-file
read permits an empty new store. Permission, non-directory ancestors, I/O errors
and future schemas leave the instance read-only (F-028–F-030, B-029).
Corrupt JSON recovery still backs up exact bytes before allowing replacement.

Flush dirty edits before reloading. Dirty or concurrent reloads throw the existing
`modifiedDuringLoad` error without disabling an otherwise writable store. During
an active load, replace refuses the edit and flush throws; callers must await load
before enabling editing. No public signature was changed. The internal async read
seam supports permission and suspended-load tests without root-permission assumptions.

Open questions: a distinct public dirty/busy error and a throwing replace API would
improve caller diagnostics, but public contract changes are outside F3 authority.
macOS Foundation error bridging remains for Opus/Xcode validation. The direct Linux
ENOTDIR regression and injected EACCES/EIO errors verify that failed reads cannot
later overwrite restored documents. Explicit flush on quit remains required.

## K33/K34 tags and folder options

[TagCatalogStore](Tags/README.md) persists an ordered Helm tag catalogue;
[LocationViewOptionsStore](ViewOptions/README.md) persists per-location options,
defaults and LRU order. Both use PreferenceDocumentFile with explicit flush and
one shared MainActor owner per document. Their corruption recovery retains original
bytes plus a backup and returns read-only defaults; it does not grant permission
to overwrite the damaged document. Unsupported envelope versions and read failures
throw. This is deliberately stricter than JSONFileStore's opt-in corruption recovery.

Catalogue edits do not change file tags or Finder preferences. Folder defaults
use 96-point icons while preserving explicit 16–512 overrides; the separate global
slider stays 48–128. K33PreferenceDocumentTests, K33TagCatalogTests,
K33LocationViewOptionsTests and K34ViewDefaultsTests exercise persistence, recovery,
revision ordering and defaults. Native catalogue/options bindings, recovery UI,
shared-store composition and explicit quit flush still require integration.

## ai.json

AIConfigStore follows SidebarLayoutStore: one shared MainActor owner over
`JSONFileStore<AIConfig>`, in ai.json (`StoreLocation.ai`), with the same corruption
backup and the same refusal of a newer schema. It holds the chosen provider, a model for
each provider, local ports and a typed address. A key is never written here: the payload
has no field for one, and unknown fields in a file are dropped on the next save.
