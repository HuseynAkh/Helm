# Selected-result path presentation — K37 / P15 N7

DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04

Adds the selected-result path projection requested by P15 while preserving F-012
root ancestry, F-030 virtual locations and F-050 reveal identity. It does not
change the existing top address bar's F-014 click-to-edit behavior or F-025 copy
current-location command. New segment actions belong to the result path bar.

One selected entry shows its actual ancestry, including the leaf, in Recent or
an ordinary directory/search overlay. Multiple unique entries show the common
ancestor of their containing directories and an explicit mixed-selection count.
Common ancestry compares components: /a and /ab share only /. No selection uses
the committed directory, or a virtual Recent/Trash context with no fake Home.
Invalid selection URLs reject the whole projection; they are never silently
filtered to a misleading valid subset. Disappeared entries must be removed by
the caller supplying current metadata. No filesystem existence probing occurs.

Standardized file URLs identify segments; symlinks are not resolved. Ancestors
are directory intents; the selected leaf uses supplied isDirectoryLike metadata,
so packages do not become navigation/drop destinations. Reveal carries parent
and ItemID; root cannot reveal itself. Each intent must name a segment in this
projection. All intents require host revalidation before execution; no mutations,
clipboard writes, native NSPathControl, drop execution or navigation occurs here.

Tests: PathPresentationTests (6 XCTest methods), including lexical boundaries,
Unicode/spaces, mixed parents, virtual/removed selection and remote URL rejection.

K37 Linux verification: HelmCore build and 18 focused tests pass. Final isolated
run_all.sh passes all six portable builds, 1,034 XCTest tests (zero skipped or
failed), Python checks, static checks, UI syntax parse and report-only coverage.
Logs: /tmp/K37-focused.log, /tmp/K37-run-all-final.log, /tmp/build-K37/logs/.
The first full run saw eight failures in two concurrently authored F16 cancellation
cases outside this lane; their four-test retry and the final full run passed.
macOS SDK compilation/native behavior and Opus review remain unverified.
