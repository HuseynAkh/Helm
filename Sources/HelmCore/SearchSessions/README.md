<!-- DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04 -->
# Search session values

K39 / P15 N2. SearchSessionState preserves F-043/F-046 and rejects stale B-021
callbacks with a new UUID for every start/refresh, including A→B→A. Typed filters
admit empty text. Core admission is structural; the Search driver validates the
existing AND grammar before invoking its source. No State files were modified.

A final results event completes gathering, not the live subscription. Stream finish,
failure, cancellation and shutdown close admission. Cancel keeps the last snapshot
and query for explicit refresh; shutdown is terminal. Ranked batch flags are kept
verbatim. Availability remains unknown unless explicitly reported; no result count
implies an available index. Fallback and unsupported criteria are separate facts.

Integration: host must retain one driver per session and project its snapshots.
Envelope-to-TabAction wiring is deferred; current TabAction cannot carry this full
state. Native Spotlight lifecycle/debounce, publication and macOS SDK verification
remain host/Opus follow-up. No I/O, service invocation or persistence occurs here.

F22 status pointer (DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04):
read the [Opus/Fable review queue](../../../docs/handoff/REVIEW_QUEUE.md) and
[current verification](../../../docs/handoff/VERIFICATION.md) before acceptance.
Historical lane counts above are not current-suite certification; P16–P18 and
concurrent F19–F21 dispositions require review. Native integration remains pending.
