<!-- DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04 -->

# K10 presentation values

Production-quality draft for M13/M18/M20/M24; Opus compile-correctness and behaviour
review after 22:00 Toronto on 2026-11-04 remains required. Linux Swift 6.0.3,
Swift 5 language mode verified; macOS/Xcode has not been verified.

## Integration

- Call `StatusText.format(StatusPresentation(...), bytes: ...)` for localized sizes,
  cached capacity and explicit activity. K2 owns the pre-existing overload in Text;
  it is unchanged. Default legacy wording and separator match
  `Helm/Helm/Views/AppKit/StatusBar.swift:44-58`. The requested `M of N selected`
  wording is opt-in through `.fraction`. New progress labels are `Searching…`,
  `Gathering items…`, and `Permission denied`; they have no legacy equivalent.
  Counts must come from one snapshot; selection is clamped to its item count.
  Negative size/capacity is omitted. Inject `StatusByteFormatting` in exact-string tests.
- `FinderTag` retains the original plist string, including unknown colors, missing
  suffixes, malformed suffixes, duplicates and empty strings. The final newline
  separates name and color. Known colors are 0 none, 1 gray, 2 green, 3 purple,
  4 blue, 5 yellow, 6 red, 7 orange. No tag is conflated with a Helm star.
  `TagSet` edits use exact tag equality; removing one tag removes its duplicate
  occurrences, while all other entries remain unchanged. A color change requires
  explicit remove/add. Invalid non-string plist entries reject the whole decode;
  adapters must retain the original data on failure rather than overwrite it.
- `TagStorage.apply` is an atomic per-item read/modify/write seam. The FS adapter
  must serialize edits and address external-writer conflicts. Core supplies only
  an in-memory actor and sequential multi-item aggregation; no xattrs are touched.
  Duplicate item IDs execute once. Failures retain item IDs and display messages.
- `ViewOptions` schema 1 encodes its version, defaults absent fields, clamps icon
  size to 16–512 and text size to 9–32, and always includes Name. Defaults are grid,
  name ascending/directories first, no grouping, 96-point icons, 12-point text,
  and Name/Size/Modified/Kind. Unknown enum/schema values throw; persistence must
  preserve unsupported records. The store falls back to its current defaults for
  absent records. Reads touch LRU order; serialization does not. Capacity zero
  disables storage. Directory keys standardize paths without resolving symlinks;
  Recent and Trash remain distinct. Persist records per location using the codec;
  the LRU itself owns no persistence or global setting mutation.
- `FileGrouping` preserves input order within every section. Kind/tag sections use
  first appearance order; date/size sections use enum order. Tags can put one item
  in multiple sections; selection must continue to use ItemID. Supply tags by ID
  because K1 FileEntry has no tag member. Missing tag map entries mean untagged
  within this projection; callers must separately show unreadable metadata.
  Dates use local calendar days: today, yesterday, 2–7 days, 8–30 days, earlier;
  future days and `.distantPast` (unknown) have separate buckets. This uses calendar
  arithmetic across DST. Size buckets are zero, below 1 MB, below 1 GB, at least
  1 GB, and unknown (negative); boundaries are decimal bytes, not a Finder-private
  bucket claim. No further sort is performed by grouping.
- `PropertiesModel` deduplicates ItemIDs, aggregates known nonnegative metadata
  sizes, and reports unknown sizes and saturated Int64 overflow explicitly.
  Directories include directory symlinks; packages remain file-like, following
  FileEntry.isDirectoryLike. Directory metadata size is NOT recursive content size;
  the loader must supply recursive totals separately with cancellation. Empty
  selections have no common kind and no mixed flags.
- Toolbar defaults preserve sidebar/navigation/location/view-mode/search order.
  `ToolbarCommand` describes only toolbar commands, not a second global command
  router. Validation requires independently reachable Cmd+L/Cmd+F routes even when
  the toolbar is hidden or fields are removed; UI must actually implement those
  fallback routes. Repeated flexible spacers are allowed; repeated controls are not.

## Needed changes elsewhere / review questions

UI must opt into the new StatusText overload, wire snapshot/selection/cached
capacity, render groups by section and ItemID, implement keyboard fallback editors,
and adapt the property aggregate. FS must implement TagStorage; persistence must
own location-keyed view-option records. No changes to their files were made.
K1's ViewMode has grid/list only; column/gallery cannot be represented here until
that shared contract is extended. Existing ItemSort keys are reused unchanged;
new ListColumn values do not imply those fields are loaded or sortable yet.
Global SettingsSchema currently clamps grid icons to 48–128, unlike M24's folder
range 16–512; the settings/UI owners should reconcile this when wiring options.
The 12-point text default and explicit date/size buckets need UI review.
SwiftPM may warn that this required README is unhandled; manifest exclusions belong
to the manifest owner and were not edited.

## Verification

`source /workspace/toolchains/env.sh`

- `swift build --scratch-path /tmp/build-K10 --target HelmCore`: passed, zero errors.
- `swift test --scratch-path /tmp/build-K10 --filter HelmCoreTests`: 69 tests passed,
  zero failures, including 13 K10 tests in four XCTest classes.
- `bash scripts/static_checks.sh`: passed, zero errors.

All changes are confined to Sources/HelmCore/Presentation and
Tests/HelmCoreTests/PresentationTests. No network, commit, push, publishing, paid
render, sharing change, or external metadata write was performed.
