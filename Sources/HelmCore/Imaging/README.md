<!-- DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04 -->
K19 implements the portable parts of M14/M20 (F-047–F-049, F-062; B-055/B-056/B-058/B-060/B-070).

Integration: inject a cancellation-aware asynchronous thumbnail producer returning encoded Data or
another Sendable image payload and actual allocation cost in bytes. Do not wrap NSImage as unchecked
Sendable. Pass point dimensions and backing scale separately to the platform request. Subscribe once
per cell binding, retain its token, consume its single-consumer stream, and call delivery.image(ifCurrent:)
on the UI actor immediately before assigning. Clear the current token synchronously on reuse and cancel
the old subscription. Cancellation cannot retract an already buffered delivery: the token comparison is
mandatory. A cancellation-ignoring producer cannot publish into a replacement flight. Stream task
cancellation also removes that subscriber. Explicit cancellation/invalidation finishes without a value.

Cache costs have a one-byte minimum, including negative cache entries, so failure floods remain bounded.
Failure expiry is lazy and uses the injected clock. Cancellation is never cached. Live limit changes evict
least recently used entries. Oversized results are delivered but not cached. Call invalidate on metadata
monitor events even when filesystem timestamps have coarse precision. Metadata-only keys cannot detect
same-size edits that preserve mtime; no content I/O is performed. LRU bookkeeping is linear in cache count.

Quick Look consumes selected IDs in display order, including expanded children/virtual-source entries.
It retains the current ID across reorder, otherwise selects the first item; empty selection closes it.
Arrows clamp within the preview list. Pane arrow forwarding can instead update the selection model.
Adapters own source frames, panel lifecycle, first-responder checks and keyboard modifier extraction.
Generic icons share keys by type/extension/folder/volume; file-specific lookup requires explicit policy.
Dimensions sanitize invalid nonpositive/nonfinite inputs to one; extremely large products may be infinite,
so platform adapters must enforce practical render bounds before allocating images.

Needed changes elsewhere: wire these contracts into HelmUI imaging/Quick Look and application adapters.
No shared-contract or manifest edits are required. macOS SDK behavior and NSImage construction remain
unverified here. The architecture places platform caches in HelmUI; these Core values intentionally
extract only their portable mechanics. Opus review after 22:00 Toronto remains required.
