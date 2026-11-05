DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04

K41 / P15 N8: portable gallery state reuses SelectionModel and ThumbnailKey.
Selected metadata and large preview share one ItemID. Unique request generations
reject ABA; full ChangeToken also captures child-count changes. Eligibility must
be supplied explicitly and defaults to none. No image, cloud or filesystem work
occurs. Snapshot replacement reconciles identity and invalidates previews only when selected
identity, eligibility or content changes; unrelated refreshes retain completed previews.
Deleted selection becomes empty rather than assigning neighbour metadata.

Filmstrip demand is visible cells plus prefetch, capped at 512 (default 128), with
at most one separate selected preview. Hosts diff requests and cancel subscriptions
that leave demand; use previewCompleted before displaying selected preview results.
Snapshot/selection setup is O(n); viewport demand is O(bounded window). Host must
scroll the filmstrip to filmstripIndex on keyboard navigation. Large-preview and
filmstrip dimensions are independent (defaults 640×480 and 96×96 points). Filmstrip
requests contain a key and full change token, without a preview generation, so
selection changes do not cancel unchanged cell subscriptions. ViewMode/menu activation, native rendering, imaging
lifetime and macOS acceptance remain deferred; this is not native gallery parity.

F22 status pointer (DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04):
read the [Opus/Fable review queue](../../../docs/handoff/REVIEW_QUEUE.md) and
[current verification](../../../docs/handoff/VERIFICATION.md) before acceptance.
Historical lane counts above are not current-suite certification; P16–P18 and
concurrent F19–F21 dispositions require review. Native integration remains pending.

F21: Page Up/Down uses the clipped visible-cell geometry count independently
of thumbnail prefetch and requestLimit, with one-cell fallback for empty geometry.
