<!-- DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04 -->

# K28 content leaves

Draft for Opus compile-correctness and behaviour-preservation review after 22:00
Toronto on 2026-11-04. UI SDK types and runtime behaviour are unverified on Linux.
No network access, commits, pushes or external actions were performed.

## Integration

- `ColumnBrowserView` binds to `ColumnBrowserState`, resolves rows by snapshot ID,
  forwards Command/Shift selection to Core, and emits `ColumnNavigation`. Inject
  cached `Image` values, tags and a preview builder. The caller loads directories,
  generation-checks results (including A → B → A), and calls `push`. Left/Right
  delegate to Core; the host owns pane focus and remaining keyboard/type-select
  routing. Preview content performs its own asynchronous, cancellable loading.
- `InlineRenameField` binds to `InlineRenameModel`. Begin with a current entry;
  pass current visible order including expanded children. The field preselects
  Core's UTF-16 stem range once per session, after attachment to a window. Escape,
  Return and Tab route locally, with IME composition left to the native editor.
  Editing forwards live validation; collision/validation messages appear in a
  popover. A pending request blocks new text through the delegate and duplicate
  submissions through Core. Escape cancels the editor, not an in-flight operation.
  The caller submits requests and calls `complete`; after success, resolve the
  returned next ID against the latest snapshot before starting its editor. Apply
  completion before reconciling away the renamed ID. Focus-loss cancellation,
  menu validation and text-first responder routing remain host responsibilities.
- `GridCellView` and `ListRowView` are passive leaves; supply selection from
  `SelectionModel.selected`, cut membership, tags and an already-resolved icon.
  Neither reads the filesystem nor starts thumbnail/download requests. Tags reuse
  `TagDotView`; stars remain separate. Local/unknown cloud metadata has no badge.
  Grid retains the 96-point default icon, icon+44 cell dimensions, 11-point name,
  two-line limit/middle truncation and 20% accent selection with radius 8 (F-035).
  List provides the 24-point name cell, 18-point icon and 13-point name (F-036).
  The outline host owns other columns, alternating backgrounds and disclosure.
  Hidden and cut opacity multiply; selection background remains fully visible.
- `RubberBandOverlay` uses top-left grid content coordinates, clips decoration to
  `GridGeometry` bounds, and never handles gestures. The host must convert viewport
  points using its scroll offset and use the same content rectangle with Core's
  `indices(intersecting:)`/selection APIs. Do not attach it in viewport coordinates.
- `DropHighlightOverlay` uses the proposal's stable row/background target; rejected
  proposals never highlight. `DragBadgeView` consumes `FileDropProposal.feedback` and
  the full source count. These leaves never accept a drop or perform operations.

## Deviations and open macOS checks

These are leaves, not the full NSCollectionView/NSOutlineView adapters from the
architecture. Column mode is a SwiftUI column strip with injected preview, not
NSBrowser. Icon dimensions are defensively bounded to 16...512 points (nonfinite
values use 96); column width to 160...800 (nonfinite uses 240). The host must use
the same icon size when configuring its GridGeometry. No new Core contracts.

MAC-VERIFY: Xcode/macOS 14 SDK type checking; SwiftUI/AppKit actor annotations;
field attachment, UTF-16 stem selection with emoji/combining marks, marked-text
composition, Escape/Return/Tab, pending-operation edits, popover focus retention,
collision correction, intentional focus moves and outside clicks; column
scroll/focus and modifier selection; VoiceOver selected traits and badge labels;
two-line middle truncation (audit M-19), large tag sets, light/dark selection,
marquee alignment after scrolling, and rejected/accepted drop visuals.
`ContentNativeAdapterTests` contains two macOS-only delegate tests, unrun here.

## Verification

Linux Swift 6.0.3 / Swift 5 language mode:

- `swift build --scratch-path /tmp/build-K28 --target HelmCore`: passed.
- `swift test --scratch-path /tmp/build-K28 --filter HelmCoreTests`: 263 passed.
- Seven `ContentLeafPresentationTests` passed in a temporary local harness at
  `/tmp/K28-content-harness`, using scratch `/tmp/build-K28/adapters`. The harness
  symlinks the real HelmCore source, this Content directory as HelmUI, and
  `Tests/HelmUITests/ContentTests` as ContentLeafTests. Its tools-5.9 manifest has
  HelmCore and HelmUI library targets and ContentLeafTests depending on both;
  Swift language version 5. It has no dependencies or network resolution.
  Run `swift test --package-path /tmp/K28-content-harness --scratch-path
  /tmp/build-K28/adapters --filter ContentLeafPresentationTests`.
- `bash scripts/rebuild/parse_check_ui.sh`: passed; recursively discovers all
  Content Swift files without a script edit. This is syntax only, not SDK checking.
- Content test files also pass `swiftc -parse`.
- `bash scripts/static_checks.sh`: passed with zero errors.

## Needed changes elsewhere

The manifest owner must enable HelmUI/HelmUITests on macOS to compile these leaves
and run the native tests. The root manifest remains untouched; its current Linux
configuration excludes HelmUI and HelmUITests. App/content-host integration must
supply loading, operation completion, preview/icon services, focus/menu routing,
right-click selection, keyboard navigation, scroll conversion and drag acceptance
as described above. No changes to another lane's types are required.
