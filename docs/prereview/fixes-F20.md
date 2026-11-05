<!-- DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04 -->
# F20 — P17 search and Inspector session fixes

All three findings reverified as real and fixed locally. No findings rejected.
No network, external actions, commits, pushes, manifest/script edits or legacy Helm
edits. Other lanes' work remains untouched. Linux is not macOS SDK certification.

## P17-1 — FIXED

Per-item and summary reuse formerly matched paths and returned without reconciling
FileEntry metadata or object identity. A shared reconciliation helper now applies
the existing follow-selection policy to every reuse mode. Unchanged entries retain
the incarnation; changed clean entries retain the window UUID but cancel old reads
and allocate a new generation. Dirty entries retain their draft and selection until
the current keep/discard token is resolved. Stale decisions cannot discard drafts.
Tests cover metadata changes, identity-only replacement, unchanged reuse, obsolete
size/enrichment rejection, keep, discard and superseded decision tokens.

## P17-2 — FIXED

Admission previously constructed N read requests and searched them for each event.
Each session now builds one immutable ItemID-to-URL dictionary at construction;
admission checks session UUID, generation UUID, item ID and URL without traversing
entries. Session lookup still scales with the number of open Inspector windows,
not the number of entries in a summary. Read/cancel effect lists are materialized
only at session lifecycle boundaries.

Enrichment accumulates by ID, then constructs the ordered edit model once, when
all entries are enriched. Partial edit projection is intentionally absent, matching
the existing requirement that edits wait for complete enrichment. A deterministic
scale regression delivers N enrichment plus N size events for N=64 and N=2048.
It sums the projected original-item counts after enrichment: exactly N, versus
N(N+1)/2 before the fix. All entries retain their input order and final sizes.
Separate tests verify every callback-token component. This is a structural and
work-count regression, not a 100,000-item latency or native UI benchmark.

## P17-3 — FIXED

The consumer now stops when envelope admission ends. The actor cancels/releases
its task only after an event is admitted for the current generation; there is no
suspension between that check and cleanup. Rejected old events return without
changing the replacement task. Final ranked results remain live-update capable.

AsyncThrowingStream requires cancellation to reach iterator.next() to invoke
onTermination when a producer retains its stream/continuation. The consumer makes
that cancelled wait before returning, including cancellation between delivery and
admission. Tests hold continuations without finishing streams and require cleanup
for both failed and finished envelopes. Supersession plus final-result/live-update
coverage verifies the replacement stays admitted until explicitly cancelled.

## Red/green evidence

The initial build encountered a transient missing Operations test source from
another lane. After waiting at least 60 seconds, the unmodified production code
ran the new regressions: 5 tests, 19 failed assertions, 0 unexpected failures
(`/tmp/F20-red.log`). All three findings had failing XCTest evidence before fixes.
Strengthening the terminal fixture to retain both stream and continuation exposed
2 further failures in the first cancellation-only fix (`/tmp/F20-retained.log`);
the iterator cancellation fix closes that gap. Focused final regression run:
32 tests, 0 failures (`/tmp/F20-green.log`).

## Deferred integration

DEFERRED (outside F20 ownership): the macOS Search service/host must bind native
query/watcher teardown to stream termination and verify cleanup against the Mac
SDK. Inspector host adapters must execute cancel/read effects with their exact
tokens, present the existing keep/discard decision, and render metadata pending
until complete enrichment. No native execution or host publication was added.
Opus compile-correctness and behavior-preservation review after 22:00 Toronto on
2026-11-04 remains required for all changes.

Final full-suite and runner results are recorded below.

## Final verification

- Linux Swift 6.0.3, Swift 5 language mode, isolated scratch `/tmp/build-F20`.
- Explicit `swift build --target HelmSearch`: PASS (including Core dependency),
  `/tmp/F20-build.log`.
- Full portable XCTest suite: **1185 tests, 0 failures, 0 skips**, satisfying the
  requested minimum of 1159 (`/tmp/F20-full.log`).
- Standalone `scripts/static_checks.sh`: **242 Swift files, 0 errors**;
  `/tmp/F20-static.log`. Scoped `git diff --check`: PASS.
- `HELM_K11_SCRATCH=/tmp/build-F20 bash scripts/rebuild/run_all.sh`: **PASS**,
  all six portable target builds, **1185 tests / 0 failures / 0 skips**, Python
  checks, static checks, UI syntax parse and report-only coverage; **0 failed
  checks**. Summary `/tmp/F20-run-all.log`; detailed `/tmp/build-F20/logs/`.
- Existing manifest cache/unhandled README warnings remain; no compiler errors.
  Native macOS SDK type checking and behavior acceptance remain deferred.
