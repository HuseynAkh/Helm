# Cloud admission policy — K37 / P15 N4

DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04

Foundation-only values supplement F-035 metadata listing and F-007/F-049 explicit
activation. Listing always stays metadata-only. Only known-local items admit
passive content demand; evicted, downloading and unknown suppress thumbnails.
Explicit evicted access requires materialization capability; downloading access
may await the provider. Unknown is unsupported, even with capabilities. Local
content admission is not proof of readability, sync status or uploaded content.
Explicit eviction requires known-local content and provider support. Its intent
is not removeItem, Trash or a guarantee that eviction is safe: a native provider
must validate uploaded state and coordination before accepting it.

CloudRequestState allocates a fresh UUID for each admitted request. Progress is
finite, bounded and monotonic; progress reaching one is not completion. Stale,
cancelled and duplicate completions are rejected. Cancellation stops awaiting,
not necessarily the provider transfer. Completion never mutates availability;
a new metadata observation is required. CloudMoveWarning examines every source
provider domain; unknown domains require a warning, even in mixed selections.

No filesystem, network, content reads, provider operations or automatic execution.
Hosts must retain request IDs, inject trustworthy per-item capabilities/domain
facts, present boundary warnings and obtain explicit approval before external
operations. Native Mac provider and preview integration is deferred.

Tests: CloudPolicyTests (6 XCTest methods), including all 64 access-table rows,
128 eviction-table rows and 64 mixed-source/destination warning combinations.

K37 Linux verification: HelmCore build and 18 focused tests pass. Final isolated
run_all.sh passes all six portable builds, 1,034 XCTest tests (zero skipped or
failed), Python checks, static checks, UI syntax parse and report-only coverage.
Logs: /tmp/K37-focused.log, /tmp/K37-run-all-final.log, /tmp/build-K37/logs/.
The first full run saw eight failures in two concurrently authored F16 cancellation
cases outside this lane; their four-test retry and the final full run passed.
macOS SDK compilation/native behavior and Opus review remain unverified.
