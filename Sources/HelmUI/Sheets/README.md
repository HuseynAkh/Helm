<!-- DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04 -->
# K16 leaf views — Astra (codex)

Draft M15/M20 leaf slice, pending Opus compile-correctness and behaviour review
at/after 22:00 Toronto on November 4, 2026. This is not milestone closure.

## Integration

The host owns models/bindings and all I/O. Views do not read metadata, execute operations, access the workspace, change
sharing or dismiss themselves. BatchRenameSheet starts only pure evaluation tasks.
Present with the retained SheetPresenter hosting controller and dismiss that
same controller from completion callbacks (B-117). Cancel and Done callbacks
must also cancel any host-owned metadata/recursive-size work.

- BatchRenameSheet takes a binding to BatchRenameViewModel. Supply the complete
  selected URL list, directory occupancy snapshots, volume case-sensitivity and
  a frozen date/time zone. Refresh/recreate the model if those inputs change.
  The three legacy modes, template tokens, basename/final-extension rules and
  first-20 preview are preserved by delegating to Core Naming. Counter input
  is a string so invalid text cannot silently reuse an older integer value.
  Every item is validated, including rows beyond the preview. A returned plan
  is only a proposal: pass its validated renames through the operation planner,
  refresh occupancy before execution, and use the operation engine's ordering;
  never execute raw preview strings or replay temporary steps as user commands.
  Core's raw preview can contain whitespace which ValidFileName trims; the
  executable rename pair is authoritative. The model memoizes one immutable evaluation per input revision. The sheet
  debounces edits for 150 ms, evaluates a captured model off the main actor and
  rejects obsolete completions. Rename stays disabled until the displayed revision
  matches the current model. Validation display is capped at 20 issues plus a
  summary; the plan retains every issue. Direct model getters remain synchronous
  for compatibility; hosts should not call them on the main actor for large inputs.
- ConflictSheet returns a resolution and Apply to All flag. The host must retain
  that policy across conflicts and resume/cancel the suspended operation exactly
  once. Keep Both is Return; Stop is Escape. Replace never merges directories.
  Opening/closing the sheet does not itself mutate the filesystem.
- NewItemNameValidation maps all Core FileNameError cases. This is a message
  adapter for the creation/inline-rename host, not a resurrection of the dead
  F-058 New File sheet. The planner owns occupancy and template eligibility;
  directory templates must not be filtered out by the host.
- OperationsPanel receives immutable OperationRowModel snapshots. Feed progress
  and result with the same OperationID; mismatches are discarded. The host must
  mark cancellationRequested when accepting cancel and retain completed/failed
  rows until acknowledged. Counts represent executor steps (including temporary
  moves/verification), not files or bytes. Details include every outcome and
  actual destination paths in 50-outcome pages; failure reconciliation is explicit.
  Collapsed details do no formatting. Retain each immutable completed row model
  across progress updates to preserve its current-page formatting cache. This panel does
  not create journal entries or retry operations.
- PropertiesViewModel deduplicates ItemID and delegates aggregates to Core's
  PropertiesModel. PropertiesSupplement is single-item enrichment only; multi-
  item instances discard it to avoid presenting one item's permissions as all
  items' permissions. POSIX bits retain Read/Write/Execute/None wording. Exact
  known bytes, overflow, unknown size and non-recursive directory sizes are
  explicit. Missing permissions/ACLs are unavailable, not inferred from a mode
  or an isReadable bit. The host may provide image dimensions/default app/lock/
  ACL text. Reveal emits selected URLs; it never calls NSWorkspace itself.

## Preserved behaviour and deviations

References: old Views/SwiftUI/BatchRenameView.swift, PropertiesView.swift,
OperationProgressView.swift, NewFileView.swift and ViewModels/PropertiesViewModel.swift;
F-050/F-052–F-058/F-061, B-038/B-046/B-047/B-066/B-100/B-117.
Review fixes 1/5/8/9 take precedence over old architecture sketches.

Properties preserves General/Image/Open With/Permissions, enclosing-folder and
Done wording. Multi-item display is additive per this lane's explicit request;
it does not add commands to the context menu. Unsupported editing remains
read-only, including ACL, name, extension, lock and permissions. No editable
M20 parity claim, recursive scanner, icon provider, inspector window, Open With
picker or sharing adapter is included. Conflict wording is new: the old app
kept both without a conflict sheet. New validation text fixes unsafe names.
The leaf does not implement inline rename or New Folder dispatch.

## Manifest and target needs (changes elsewhere)

Use the [staged Mac manifest patches](../../../docs/handoff/MAC_HANDOFF.md) after explicit owner assignment.
Tools 5.9, Swift 5 and macOS 14 remain required; this note grants no ownership.

On macOS, run:

```sh
swift build --scratch-path /tmp/build-K16 --target HelmUI
swift test --scratch-path /tmp/build-K16 --filter HelmUITests
```

## MAC-VERIFY and verification limits

- OperationsPanel.swift: DisclosureGroup expansion, selectable detail text and
  keyboard focus inside the hosted operations panel.
- PropertiesView.swift: selectable text wrapping inside the 360-point sheet.
- All SwiftUI still needs macOS SDK typechecking (Binding dynamic members,
  ViewBuilder switches, enumerated ForEach closures, keyboard shortcuts and
  actor isolation). Linux parsing does not resolve types or SDK availability.
- Check Return/Escape, first responder restoration, disabled Rename, collision
  feedback, VoiceOver labels, long filenames/paths, scrolling, all three modes,
  20-row preview, extension retention, negative/overflow/invalid counter input,
  all conflict choices, and apply-to-all host lifetime.
- Check cancellation during work and completed/partial/uncertain operations,
  single/multiple/empty Properties, missing enrichment, dark/high contrast and
  narrow text wrapping. No screenshot or runtime UI validation was possible.

Linux Swift 6.0.3: all 8 source Swift files and 2 XCTest files parse in Swift 5
mode with zero errors. Static checks passed with zero errors. The 10 XCTest
methods cover model adapters and audit edge cases; they cannot run through
HelmUITests on Linux because that target requires SwiftUI/macOS. Actual macOS
build and XCTest execution remain pending. `swift build --scratch-path
/tmp/build-K16 --target HelmOperations` passed (including Core/FileSystem).
The four Foundation-only adapters were emitted as an isolated temporary HelmUI
module under /tmp/build-K16 and both XCTest files typechecked against it with
zero errors. This supplemental check excludes every SwiftUI view and does not
constitute building the real HelmUI target or executing tests.

No network, commits, pushes, sends, deletion, paid rendering, publication or
sharing changes were performed. Remote shared memory was not fetched because
network access is explicitly prohibited.

## K34 batch rename cancellation

BatchRenameSheet retains BatchRenameWorker across revisions. It runs at most one
calculation, retaining only the latest pending request. Replacement, Cancel and
disappearance cancel obsolete work; the outer task forwards cancellation by request
identity. Core's throwing cancellation hook checks generation/occupancy/targets,
temporary-name probes and sort boundaries, throwing without a partial plan.
Cancelled evaluations do not fill the cache. Revision checks still guard display
and execution independently of cancellation. Synchronous compatibility getters
remain available and should not be used to plan large selections during rendering.

K34BatchRenameWorkerTests checks cancellation delivery, maximum concurrency of one
and empty cache after cancellation; K34CancellationTests covers planner interruption.
The configured portable UI/App runner executes Foundation adapters and worker tests.
The K16 parse/typecheck-only counts above are historical. SwiftUI task isolation,
hosted dismissal/Return/Escape and large-selection responsiveness remain Mac checks.
See ../README.md for the paired HELM_K11_SCRATCH/HELM_UI_SCRATCH recipe.
