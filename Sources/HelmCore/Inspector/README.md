<!-- DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04 -->
# Inspector integration (K35 / M20)

Pure Foundation values extend F-050/F-062 without I/O. Supply InspectorItem metadata
and explicit editableFields from a permission-aware adapter (default: none). Absent
metadata is unavailable, not empty; mixed values expose the literal `mixed` label.
Construct a fresh model when selection changes. Drafts are not cleared by planning;
replace originals only after verified success. Deduplication uses ItemID, first wins.

EditPlan contains original/proposed attributes for conflict checking and undo. Future
executor must recheck capability, system/user locks, collisions, provider support and
identity; handle partial failures, order unlock before writes and lock last, and resolve
paths after rename. Recursive permissions require directory selections and explicit
intent, including when the parent's mode is unchanged. The executor must not follow
symlinks or apply a parent's special bits blindly to descendants; capture child originals
for undo. This lane supplies no executor or filesystem mutation authorization.

PermissionsModel offers row edits with independent execute flags, preserving all other
bits. Edit `InspectorEditModel.permissions` for per-row multi-item changes; each item keeps
its untouched bits. An explicit `.permissions` draft clears earlier row edits, even when reverting to originals,
while preserving recursive intent. Rows display that draft; later row edits modify it.
Unknown original modes keep aggregate rows unavailable unless a whole mode is explicitly
assigned; planning still rejects missing metadata. Finder
labels describe read/write only; execute is a separate control. ACLs, ownership changes,
and administrative authentication remain read-only/out of scope.

Names use the existing validator (trim spaces, 255 UTF-8 bytes, POSIX colon allowed).
Extension changes require explicit confirmation for the current draft. Multi-selection
rename belongs to batch rename. Hidden flag and hide-extension are distinct fields.
Tags replace the full list explicitly, preserving spelling/order; empty clears it.
Nil default application explicitly requests per-file reset; adapters may disable this
if unsupported. No Change All/type-wide default mutation is implied. Comments are draft
strings; Finder interoperability requires macOS validation. Capabilities must remain
absent until corresponding adapters are implemented.

Size totals require disjoint inputs (do not count a selected child twice under a selected
parent). Directories start calculating, never report metadata size as final. Cancellation,
generation filtering, cloud-materialization policy and allocated/logical-byte choice
belong to the supplying calculator. Negative direct total inputs clamp to zero; use
metadata(bytes:isDirectory:) for unknown/negative metadata. Sections encode raw keys
and preserve unknown keys; storage and window/inspector preference scope remain external.

Needed changes elsewhere: loader enrichment for editable attributes/capabilities,
executor and journal wiring, UI bindings, cancellable size calculator, persistence
adapter. No existing files changed. Mac/Xcode and Opus review remain pending.

F11 verification: InspectorEditModelTests covers row → whole-mode → original-mode
reversion, row/value/plan agreement, recursive-intent preservation and unknown
permissions in both selection orders. Explicit drafts may be displayed even for
unsupported items; planning still rejects them. T3InspectorTests and
T3PermissionTests add plan/permission edge cases. These tests validate pure values
and plans, not native permission changes or an enabled Inspector editing UI.
