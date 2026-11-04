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
