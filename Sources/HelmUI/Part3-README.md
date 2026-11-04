<!-- DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04 -->
# K21 leaf views (Astra / codex)

Draft pending Opus compile-correctness and behaviour-preservation review after
22:00 Toronto on November 4, 2026. This does not close M16/M18/M23/M24.

## Integration

All views are binding-driven proposals with no stores, tasks, I/O or command
execution. Public model values are Sendable. The host owns persistence, errors,
query generations, debounce, cancellation, focus and sheet lifetime (B-117).

- ViewOptionsView binds directly to the folder's effective Core ViewOptions.
  Each edit reconstructs the immutable value through Core validation, retaining
  unrelated fields. Name stays mandatory; grouping and sorting are independent.
  Persist in the per-folder store; Use as defaults returns the current options
  to the host. Opening the panel does not persist or reset an inherited value.
- TagEditorView binds a draft TagEditorModel. Apply returns TagSet, Cancel does
  not apply. Adding/removing delegates to Core and retains unrelated unknown raw
  tags. The host must recheck metadata/version and surface write/partial failures
  through errorMessage. This is a single/common-set editor, not a mixed-selection
  resolver; do not overwrite heterogeneous selections with one common TagSet.
  No global tag rename, Finder settings write or private-star conversion exists.
- SearchBarView binds a model per tab, preserving “Search files and folders”.
  Observe text/scope/kind/hidden changes in the host, not status-only changes.
  Empty trimmed text exits search. A nil request with scopeUnavailable is an
  error, never permission to broaden scope. Cancel must stop the active query,
  clear input and restore the directory snapshot in the host. Keep generation
  rejection and monitor isolation in the host (B-020/B-023).
  SearchRequest keeps text literal; any advanced grammar must be explicitly
  parsed through HelmSearch before constructing a specification. Kind chips
  select regular files or directories, not all file-like/package kinds.
  Recents maps to SearchDomain.recents, never Helm's private Recent location.
  Denied, failed, cancelled, gathering and no-results are distinct. Empty results
  do not assert missing indexing or automatically start enumeration fallback.
  Feed the service's truncated flag. Install SearchLocationColumnView in the
  host's Location column; its model retains the full enclosing path (M-24).
- ToolbarCustomizationView binds a draft layout. Available items come from
  Core's ToolbarItem table; labels preserve Toggle Sidebar/Navigation/Path/
  View Mode/Search. Dragging reorders rows; Add Item and Remove configure them;
  Move Up/Down provide keyboard alternatives. Repeated flexible spaces are valid.
  Supply actual reachableKeyboardCommands, never assume visible fields suffice.
  Apply stays disabled until Core validates the layout. The host must revalidate
  on application and install .location/.find command routes independently of
  toolbar visibility (Cmd+L/Cmd+F). Cancel discards the host's draft.

## MAC-VERIFY and needed changes elsewhere

The manifest owner must enable macOS-only HelmUI and HelmUITests, with HelmCore
and HelmSearch dependencies (plus existing K12/K16 requirements), and exclude
README files. No manifest or other lane changes were made. Tools 5.9, Swift 5,
macOS 14 are required. No Core contract change is required.

MAC-VERIFY markers cover Form/popover sizing, sliders, tag Return/Escape,
Cmd+F focus/select-all and IME composition, and String Transferable drag/drop.
All SwiftUI overloads, Binding writes, ForEach identity, keyboard navigation,
VoiceOver, long names, dark/high contrast and host sheet dismissal need macOS
SDK typechecking/runtime review. Toolbar row indices are local to the current
sheet draft; do not replace that draft externally during a drag. Host must
keep keyboard reachability synchronized with its actual command routes.

Deliberate scope limits: no saved-search save/open flows, rich criteria editor,
indexing diagnosis, automatic fallback, mixed-tag selection or metadata writes.
These are host/integration work. Expanded scope and customization wording is
new because the old app had neither control. Search placeholder and toolbar
labels were read from the legacy MainWindowController; old Views and audit
F-003/F-029/F-036/F-040/F-043–F-046/F-065 and B-099 informed the adapters.

## Verification

Linux Swift 6.0.3: eight source files and one XCTest file parse in Swift 5 mode
with zero errors. HelmSearch and dependencies build with /tmp/build-K21.
Four Foundation-only adapter files emit an isolated temporary HelmUI module;
the nine XCTest methods typecheck against it with zero errors. This does not
build SwiftUI or execute HelmUITests. Those tests await macOS and target wiring.
HelmSearchTests ran with /tmp/build-K21: 36 tests passed, zero failures.
Static checks pass with zero errors.

No network, remote memory fetch, commits, pushes, publication, paid renders,
messages, file deletion or sharing changes were performed.
