<!-- DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04 -->

# K24 content logic

Foundation-only Sendable values; no I/O or UI imports. Draft for Opus compile and
behaviour review after 22:00 Toronto, November 4, 2026. macOS validation is pending.

## Integration and behaviour decisions

- **SelectionModel (F-038/F-039/F-041, P-067–P-069/P-080/P-083):** provide the
  already sorted visible order from PresentationSnapshot / ItemSort. For outline
  mode pass `snapshot.visibleIDs(expanding:)`, including expanded children. IDs
  are deduplicated once and indexed; selection never sorts. Apply selected IDs to
  the widget after every reload with the adapter's programmatic-selection guard
  (B-009/B-011/B-033/B-101). Right-click explicitly updates this model. Invalid
  click IDs are ignored; background context-click and clear remove anchor/focus.
- Shift replaces the contiguous anchor range; Command-Shift unions it. Command
  click toggles and becomes the new anchor/focus, even when deselecting. Shift
  arrow contracts as well as extends. Invert sets anchor/focus to the first
  remaining selection. Home/End/Page keys move selection here (P-068); a UI
  wanting scroll-only Home/End must route those events separately. Page size is
  viewport-derived in items. List Left/Right are no-ops (disclosure is separate).
  Grid horizontal arrows stop at row edges; Up stops in the first row; Down
  reaches the last cell of a short final row and stops there. With no focus,
  Up/Page Up/End start at the last item; other movement starts at the first.
- Reload drops vanished selected IDs without automatically selecting neighbours.
  Surviving anchor/focus remain; vanished ones choose the closest surviving old
  neighbour, preferring the next on ties. If no old item survives, use the old
  positional index clamped into the new order. Explicit operation rename maps
  preserve identity; external renames are not inferred (P-080). TypeSelect uses
  the existing clock/timeout and matches visible order (F-041); UI owns Space,
  modifier, text-editor, and IME routing (B-060/B-118).
- **GridGeometry (F-035, P-027/P-028/P-052):** legacy defaults: 140×140 cells,
  horizontal/vertical spacing 10/14, symmetric insets 16/12. Coordinates are
  top-left. Cells are half-open for point hits, and marquee selection needs
  positive-area intersection; gutters and touching edges are excluded. Visible
  ranges contain intersecting rows, including partially visible cells. Work is
  bounded by intersecting rows/columns, not total item count. Non-finite query
  values yield no matches; configuration values are normalized to finite,
  nonnegative metrics (cell dimensions >=1, metrics capped at 1e9 points).
- **ColumnBrowserState (P-043, F-007/F-038):** each column retains its own
  selection. Exactly one directory-like selection produces a load request;
  files, packages and unresolved aliases produce a preview target. Multiple
  selections suppress navigation/preview. Push validates the parent selection
  and returned directory path. Changing ancestor selection or reloading an
  ancestor truncates descendants. Same selection preserves existing columns;
  Right focuses an existing next column or requests a load. Left pops children
  back to the parent; root Left/pop do nothing. Resizing/preview visibility are
  UI settings. The root can be a virtual source, but pushed columns are directories.
- **InlineRenameModel (F-054, P-071, B-046/B-066):** begin on exactly one resolved
  entry; multiple-selection batch rename belongs to the command router. Stem
  preselection excludes the last extension, preserves a leading-only dot, uses
  UTF-16 offsets, and selects the full name for directory-like entries. Packages
  use the file extension policy. Existing ValidFileName trimming/colon/byte-limit
  rules are authoritative. Return emits a pure request; Escape dismisses; Tab
  captures the next visible ID without wrapping. A pending request suppresses
  duplicate commits. Completion requires session plus attempt identity and the
  full request, so old successes/collisions cannot close a new edit/retry. Typed
  collision feedback retains text; edit clears it after validation. Only success
  returns the next editing target. Unchanged names also emit a request so the
  operations adapter can handle a no-op consistently. Vanished items cancel.

## Needed changes elsewhere

No shared type or manifest changes required. UI/App integration must apply these
values atomically with displayed snapshots, defer reloads while editing, route
keys according to first responder, perform operation requests, and resolve Tab's
next ID from the latest snapshot. Cancel only dismisses editing; it cannot undo
an already submitted operation. Generation checks in the loading adapter must
reject stale same-directory column loads (including A → B → A navigation);
parent path checks alone do not establish freshness. After a successful rename,
complete the request before reconciling away its old ID, then apply the explicit
old/new selection mapping. Mac field-editor, keyboard focus, scroll behaviour,
case-only rename and column UX need Opus/Mac review (M11/M19).

## Verification

Use `/tmp/build-K24` for `swift build --target HelmCore` and
`swift test --filter HelmCoreTests` with `--scratch-path`. ContentTests cover
selection transitions/reloads, geometry against a naive intersection oracle,
100k-item selection and viewport workloads (loose 15-second bounds), column
navigation, validation, Unicode selection and stale rename results. These are
portable logic checks, not claims about AppKit responsiveness or Xcode compilation.

Latest Linux verification: HelmCore target build passed; all 263 HelmCore tests
passed, including 37 new K24 tests; static checks passed with zero errors. The
first test build encountered a transient Volumes-lane compile error; the final
run passed without modifying that lane. SwiftPM reports sandbox cache and
unhandled README warnings. The manifest owner may exclude Content/README.md
alongside the other module READMEs; no manifest edit was made in K24.

K29 supersedes path-only column acceptance: ColumnNavigation.load carries a
ColumnLoadRequest (owning column UUID plus request UUID, directory and index).
Return that same request to push(_:request:); never manufacture one from the
current state when a callback arrives. A successful push consumes the request.
Repeated same-folder selections issue fresh requests; reload, pop and truncation
invalidate pending requests. UI loading adapters should also cancel obsolete work.
