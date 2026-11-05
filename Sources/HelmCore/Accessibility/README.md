<!-- DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04 -->
# K36 accessibility values

Pure Foundation/HelmCore logic for M24 and P-292/P-293/P-299/P-300. Preserves
F-003 toolbar action meanings, F-035/F-036 file identity, F-025 navigation and
F-064 counts; supplies missing speech for B-061 and operation feedback for B-049.
No notifications, commands, filesystem reads or external actions occur here.

## Integration

- Construct `AccessibilityFormatting` with the UI locale, calendar (including its
  time zone), and a `HelmClock`. Recreate it when those preferences change. Formatters
  are local to each call, not shared mutable Foundation objects.
- Give `RowDescription` the full FileEntry name, selected state and separately read
  TagSet. Brief speaks name/kind/selected; standard adds size, tags and known cloud
  state; detailed adds modified date. Directory sizes are omitted because metadata
  size is not recursive content size. Negative sizes and distantPast dates are unknown.
  Unknown cloud state makes no availability claim. Use localizedKindDescription
  supplied by the reader where present. Avoid duplicate icon/text accessibility children.
- Selection byte totals must be computed by the snapshot consumer; nil omits an
  unknown total, zero is valid, and zero selection suppresses any stale byte count.
- Announce navigation after an accepted generation, not for stale loads. Loading
  and partial results remain explicit even when their current item count is zero.
- Retain one mutable `OperationAnnouncement` per operation ID on the owning actor.
  Deliver non-nil results through the macOS accessibility adapter. Progress reports
  the highest crossed milestone after the time gate; suppressed updates do not
  consume it. Completion/failure/cancellation bypass the gate and terminate speech.
  100 percent is not success: the backend must explicitly report completion. Keep
  failed operations reachable in the UI. A retry uses a fresh announcement value.
- Context-menu descriptions use the actual dynamic menu title and caller-provided
  enabled state. Toolbar descriptions cover every ToolbarCommand. Native adapters
  still supply roles, shortcuts, values, selection traits and actionable controls.
- AccessibilityIdentifier uses versioned, delimiter-safe UTF-8 hex of ItemID paths.
  Pass a stable window/tab scope to distinguish repeated presentations. Sorting and
  selection do not change IDs; rename does, matching ItemID. IDs are reversible and
  contain private paths: do not log them to telemetry. They are UI-test identifiers,
  not spoken labels. This intentionally avoids randomized Swift Hasher output.

## Open questions and deviations

- Locale controls numeric digits/grouping/decimal separators and absolute date/time.
  Speech phrases and unit abbreviations remain English, matching the existing UI;
  full phrase translation needs an approved localization catalogue in a later lane.
  Relative dates use calendar days (today/yesterday/tomorrow), including DST, then
  fall back to absolute date/time. No unavailable Linux relative-date formatter is used.
- Selected state is spoken when selected; unselected rows omit the redundant phrase.
  The UI must still expose the native selected-state trait for both values.
- Byte formatting mirrors decimal ByteCountText behavior with explicit locale rather
  than using LocalizedStatusByteFormatter, whose locale is not injectable.
- macOS VoiceOver, Full Keyboard Access, focus, reduced motion/contrast and avoiding
  duplicate native announcements require adapter/device acceptance. Linux tests do
  not establish end-to-end accessibility parity or an Opus sign-off.

Needed changes elsewhere: wire these values into HelmUI/AppKit and supply stable
per-tab/window scopes, notification delivery and localization resources. No changes
to shared contracts or Package.swift are needed.
