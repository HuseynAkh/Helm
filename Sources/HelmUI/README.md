<!-- DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04 -->
# K12 UI leaf draft

Author: Astra (codex). M13/M24 leaf slice only, pending Opus compile-correctness
and behaviour-preservation review after 22:00 Toronto on 2026-11-04.
No network, commits, pushes, sends, sharing changes or external actions.

## Integration

Add these declarations to the root Package.swift's existing `#if os(macOS)` block
(the K12 lane deliberately does not edit the manifest):

```swift
products += [.library(name: "HelmUI", targets: ["HelmUI"])]
targets += [
    .target(name: "HelmUI", dependencies: [
        "HelmCore", "HelmFileSystem", "HelmPersistence", "HelmOperations", "HelmSearch"
    ]),
    .testTarget(name: "HelmUITests", dependencies: ["HelmUI", "HelmCore"])
]
```

Keep macOS 14 and Swift 5 language mode. No package dependencies are added.
The only imports used by this slice are Foundation, SwiftUI and HelmCore.
No State/K8 types, Combine, observation macros, stores, defaults or I/O are used.

- Construct `SidebarModel(places:committedDestination:)` after committed navigation,
  not a pending load. It delegates exact/deepest-ancestor mapping to Core. Preserve
  the returned section/row order. Pass its selected ID to `SidebarRowView`.
- Row `activate` fires even on a re-click. The host must resolve starred file vs.
  directory activation; Core Place alone has no file-kind metadata. `perform`
  receives `.removeBookmark` and the originating Place; it never mutates a store.
  The host owns list keyboard navigation, focus, collapse, translucency and drops.
  Do not use a selection-binding no-op as the sole row activation mechanism.
- `SettingsPaneView(pane:snapshot:supportsSingleClick:change:)` reads immutable
  snapshots. Route changes through the shared SettingsStore, then redraw with its
  new snapshot. The callback does not optimistically modify a captured snapshot.
  Store validation remains authoritative. Errors must be surfaced by the host.
  Enable `supportsSingleClick` only after the product decision and a working
  content consumer; the legacy control was an unwired stub (B-059).
- Feed `StatusBarView(status:)` one snapshot's StatusPresentation, with cached
  capacity. Formatting stays in Core StatusText. It performs no capacity lookup.
- `TagDotView(tag:)` uses Finder colors; absent/unknown/zero color is an outline.
  Names remain available through help and accessibility, separate from Helm stars.

## Preservation and deviations

Old references: Views/SwiftUI/PreferencesView.swift, AdvancedOptionsView.swift,
SidebarPlacesView.swift and Views/AppKit/StatusBar.swift. Audit: F-026–F-031,
F-064/F-065, B-027/B-029/B-058/B-059 and 00b M-14/M-15.

The requested General/Sidebar/View/Search/Advanced leaf split supersedes the old
General/Appearance/Behavior tabs; labels, captions, form style, row icon colors,
row spacing and 24-point/11-point status treatment are retained. Window titles,
sizing and autosave remain host responsibilities; these are not whole windows.
The expanded General/Advanced forms require a scrollable/resizable host.

Defaults come only from Core (including 96-point icons and no Trash confirmation),
not the legacy @AppStorage defaults. Search/TTL bounds follow current Core minima
(50 results, 40 ms, 0.1 seconds), differing from old controls (100, 60, 0.2).
Cache controls retain a 4000 UI ceiling; completion debounce uses a 1000 ms UI
ceiling, while Core permits larger persisted values. No persisted value is
clamped merely by displaying the view. Session restore, conflict prompting,
thumbnail cache, completion debounce and cross-volume drag controls expose
existing Core keys; consumers must be wired by integration.

Sidebar preserves Recent, Favorites, optional Bookmarks/Starred/Devices, Trash.
Individual starred rows are not highlight candidates. The Core virtual Starred
root is intentionally not inserted into the old layout; a committed virtual
Starred destination has no highlighted row. Unavailable bookmarks are retained.
The row uses a subtle accent background instead of owning native List selection;
validate active/inactive/high-contrast appearance when composing the sidebar.

Core ViewOptions was inspected. This slice edits global defaults only; per-folder
ViewOptions editing, toolbar customization and full accessibility milestone
closure remain future M24 integration work. No broader M13/M24 completion claimed.

## Verification and open questions

Linux Swift 6.0.3, Swift 5 parse mode: all 10 source Swift files and 2 XCTest files
parsed with zero errors. `bash scripts/static_checks.sh`: zero errors.
Seven XCTest cases are written for section projection, path boundaries, exact
and deepest matching, starred exclusion, unavailable bookmarks, virtual routes,
context actions, committed highlights and typed snapshot bindings.
They have NOT run: HelmUI/HelmUITests are absent from the Linux manifest, and
`swiftc -parse` does not resolve imports, types, SDK availability or actor isolation.

On macOS, after adding the snippet:

```sh
swift build --scratch-path /tmp/build-K12 --target HelmUI
swift test --scratch-path /tmp/build-K12 --filter HelmUITests
```

MAC-VERIFY (also marked at the call site): `accessibilityAddTraits` selected-state
announcement and keyboard activation in the hosting sidebar. SwiftUI APIs are
otherwise conventional macOS 14 APIs; all still require SDK typechecking.
Verify VoiceOver names/selection, Full Keyboard Access and re-click navigation;
light/dark/high contrast row states; all Finder colors and unnamed/unknown tags;
status singular/plural, progress/denied states and narrow-width truncation;
every setting's real consumer and live versus next-query behavior; settings
scrolling; host-provided multi-window refresh, drop targets and error feedback.
No visual or runtime behavior has been verified on this Linux machine.

Needed changes elsewhere: manifest snippet and composition-root/hosting wiring
above. No Core contract edits are required. Shared remote memory was not fetched
because this session explicitly prohibits network access.
