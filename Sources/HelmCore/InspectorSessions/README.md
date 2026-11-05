<!-- DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04 -->
# K40 Inspector sessions

Foundation-only value policy for F-050, with B-009 callback identity and B-066
honest contents-size projection. This is additive session policy, not a claim
that the old single-item sheet already had summary/follow-selection windows.

Feed explicit presentation intent into InspectorSessionRegistry. Per-item requests
count ordered unique ItemIDs; more than ten requires the exact confirmation token.
Reusing a window is scoped to owner and mode. Summary reuse requires the same
ordered IDs. One following Inspector is retained per owner. Owner closure is
terminal for that UUID and invalidates pending confirmations; allocate a fresh
owner UUID for a new host lifetime.

The host executes open/reuse/close effects and retains read tokens unchanged.
Use the existing HelmFileSystem PropertiesLoader for metadata/tree-size reads;
Core neither imports that module nor introduces another walker. The host maps
metadata to InspectorItem, with explicit edit capabilities, and submits enrichment
and size events with the original token. Every selection replacement gets a new
generation, even A/B/A. Final/unavailable size events are terminal; enrichment is
accepted once per item. Cancel effects ask adapters to stop work; admission guards
still reject late results even if cancellation is uncooperative.

Edits delegate to InspectorEditModel. They are admitted only after all selected
items have enrichment, so late reads cannot replace a partial selection's draft.
Missing metadata should be represented by InspectorItem with absent attributes,
not inferred edit permissions. Dirty selection changes require the latest explicit
keep/discard decision. Saving/attribute execution is deliberately not implemented;
keep selection, validate the existing edit plan, and integrate a reviewed save
workflow separately. There is no implied write effect.

InspectorSizeProjection exposes rawMetadata separately from contents. Packages and
actual directories begin calculating; ordinary file/link sizes remain metadata
bytes. Computed values must be trusted, generation-admitted adapter results. Values
are sums of supplied item totals, not a distinct-file/disk-usage measurement:
overlapping ancestor/descendant selections require host-defined disjoint totals if
that measurement is desired. Unknown, partial and overflow states remain explicit.
F18 already repaired PropertiesModel/UI; K40 does not change those consumers.

Open integration questions: native window lifecycle and UI prompts, metadata-error
presentation, save completion/revalidation, recursive progress conversion, and
macOS SDK/behavior acceptance. No I/O, services, network, commits or publication.
