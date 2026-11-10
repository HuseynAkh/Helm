<!-- DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04 -->
# K27 archive planning

Pure M22 drafts extending F-007/F-052/F-059. No live Process implementation or execution.
Compression names a single selection `<name>.zip`, multiple selections `Archive.zip`,
and applies Core UniqueNamer numeric suffixes with supplied case sensitivity and occupied
names. Sibling selections are deduped; cross-directory selections are rejected. All user
paths are separate arguments. ZIP creation uses symlink-preserving `zip -r -y` and a fresh
owned staging output, never the final destination. Tool arguments target macOS system tools;
Linux tests check values without invoking tools.

| Format | Plan |
| --- | --- |
| zip | unzip into staged output directory |
| tar, tar.gz, tgz, tar.bz2 | tar into staged output directory |
| gz | gzip stdout into exclusively created staged output file |
| dmg | typed mountDiskImageInstead; use DiskImagePlanner |
| 7z, rar, others | typed unsupportedFormat |

Extraction always receives a complete inspected listing and marks its command as requiring
confined extraction. Preflight rejects absolute/parent paths, Windows separators/drive
prefixes, controls, links (even apparently safe links), special entries, duplicate canonical
names, file/descendant conflicts, member-count/expanded-byte overflow and excessive ratios.
Zero compressed bytes with nonzero expanded bytes is rejected. Archive names are literal
filesystem strings, not URL-decoded strings. Formats and metadata parser fidelity need Mac
fixtures; no listing parser is claimed here. Default limits: 100,000 members, 10 GB expanded,
1,000:1 per-member ratio. Empty archives are allowed. Limits are configurable.

SECURITY / needed changes elsewhere: a production adapter MUST exclusively reserve a new
empty staging directory, reject symlinked ancestors, pin/verify the inspected archive against
replacement, enforce filesystem confinement and streaming count/size/ratio limits, suppress
ownership/permission restoration, honor cancellation, and validate the resulting tree before
a journaled no-overwrite final move. Generic Process + tar -xf is NOT this adapter. The command
flag is a requirement, not sandbox enforcement. Directory extraction stages a containing folder;
gzip stages a file. The adapter creates the output directory before unzip/tar. ProcessRunning
accepts a command only; the orchestration layer must retain ArchivePlan.safetyLimits and owned
staging state, and must not hand a confined command to an unrestricted runner. Planning-time
listing validation alone cannot guarantee extraction safety (P-389 remains partial).

On failure/cancellation, retain source and owned partial staging for explicit reconciliation;
never automatically delete user data or report complete output. Exit status, diagnostic,
signal and cancellation are typed; script exhaustion is an error, not implicit success.
Unknown progress stays unknown. Reserve final output atomically and replan on EEXIST (B-039).

Deviations/open questions: archive seam is in FileSystem per lane ownership, while architecture
places runtime orchestration in Operations. No Core API references these types. Production
runner, archive inspection/identity and sandbox implementation, metadata fidelity, encrypted
archives, live cancellation, and macOS tool validation remain required before M22/G9 signoff.
Manifest owner should exclude this README to remove SwiftPM unhandled-file warnings.

Verification: Linux Swift 6.0.3/Swift 5 mode, HelmFileSystem target build passed;
77 HelmFileSystem XCTest cases passed, including 23 new K27 cases (12 archive, 11 volume).
Scratch `/tmp/build-K27`; static checks passed with zero errors. No archive tools executed.
