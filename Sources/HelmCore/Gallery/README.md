DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04

K41 / P15 N8: portable gallery state reuses SelectionModel and ThumbnailKey.
Selected metadata and large preview share one ItemID. Unique request generations
reject ABA; full ChangeToken also captures child-count changes. Eligibility must
be supplied explicitly and defaults to none. No image, cloud or filesystem work
occurs. Snapshot replacement reconciles identity and invalidates old completions.
Deleted selection becomes empty rather than assigning neighbour metadata.

Filmstrip demand is visible cells plus prefetch, capped at 512 (default 128), with
at most one separate selected preview. Hosts diff requests and cancel subscriptions
that leave demand; use previewCompleted before displaying selected preview results.
Snapshot/selection setup is O(n); viewport demand is O(bounded window). Host must
scroll the filmstrip to filmstripIndex on keyboard navigation. Large-preview and
filmstrip dimensions currently share one supplied size; separate rendering sizes
are a future host policy. ViewMode/menu activation, native rendering, imaging
lifetime and macOS acceptance remain deferred; this is not native gallery parity.
