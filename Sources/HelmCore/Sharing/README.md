# Sharing lifecycle — K37 / P15 N5

DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04

F-063's explicitly selected URLs become an immutable ordered snapshot. Validation
rejects non-file URLs, remote file authorities and decorated URLs before deduping
lexical keys (without collapsing parent components). It performs no existence or readability checks. Capability
facts separately gate Share and AirDrop; defaults are unsupported.

Only invoke emits presentation intents. Empty selection asks for a file picker;
its returned selection creates a fresh request identity, retiring file-picker
callbacks. Active requests cannot be retargeted by current selection changes.
Picker presentation and provider acceptance are distinct from provider-reported
completion; no state claims verified delivery. Cancellation/failure/completion
are terminal for that request. Owner close retires the session and emits only a
dismiss intent for an active picker/provider request. It cannot guarantee provider
transport cancellation. Recipients and transport remain system-owned.

No service objects, sending code, sharing changes or native picker implementation.
A later host must route explicit approved user gestures and retain request IDs.
Tests: SharingTests (6 XCTest methods), all value-only.

K37 Linux verification: HelmCore build and 18 focused tests pass. Final isolated
run_all.sh passes all six portable builds, 1,034 XCTest tests (zero skipped or
failed), Python checks, static checks, UI syntax parse and report-only coverage.
Logs: /tmp/K37-focused.log, /tmp/K37-run-all-final.log, /tmp/build-K37/logs/.
The first full run saw eight failures in two concurrently authored F16 cancellation
cases outside this lane; their four-test retry and the final full run passed.
macOS SDK compilation/native behavior and Opus review remain unverified.

F22 status pointer (DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04):
read the [Opus/Fable review queue](../../../docs/handoff/REVIEW_QUEUE.md) and
[current verification](../../../docs/handoff/VERIFICATION.md) before acceptance.
Historical lane counts above are not current-suite certification; P16–P18 and
concurrent F19–F21 dispositions require review. Native integration remains pending.

F21: captured action URLs retain the first validated supplied URL verbatim.
Deduplication ignores empty/dot components and local directory hints/localhost,
but retains parent components: `/link/../x` is never collapsed to `/x`.
No normalization probes the filesystem or resolves symlinks.
