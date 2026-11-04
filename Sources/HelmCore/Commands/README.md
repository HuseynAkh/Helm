<!-- DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04 -->

K14 command and menu tables

All values are pure, Sendable HelmCore data. No command executes any action.
MenuModel.legacy preserves App/main.swift:19–142, including raw uppercase Home H
with the default Command mask and the double File separator. MenuModel.menuBar
adds explicitly marked entries; defaultBindings also includes the Cmd+Down alias.
Quick Look is an existing action newly exposed in the menu (architecture 8.3),
with Space restricted to pane focus outside a type-select run. Return enables
both single inline rename and multiple-item batch rename (F-054/F-055).

Integration:
- Build separators between sections; an empty section intentionally adds a separator.
- Map command identities to selectors in HelmUI, with nil targets. Cut/Copy/Paste/
  Select All must use NSText selectors; text Undo/Redo must remain with AppKit.
  An enabled text command means delegate validation to that responder, not force
  it enabled or execute the file operation. Use helmToggleSidebar, not toggleSidebar.
- Feed snapshot selection, actual pane/text focus, history, journal, validated
  clipboard state, and type-select activity into CommandContext. Default history
  and mutation permissions are conservative. Do not fabricate a mutation target
  for Recent, Trash, or search. Missing selection and unavailable actions disable.
- Render each item's validationRuleID using CommandValidation. Planned placeholders
  remain disabled with no shortcut. Filter hidden results for location-only actions.
  The data contains no authorization to execute external or destructive actions.
- Context menus preserve FileContextMenuBuilder.swift:12–144 ordering. File and folder
  have the same baseline, as in that builder. Pass the actual selection count for
  multiple, Trash, and Recent contexts. Validate against the actual location.
- Open With, Share, Services and New File are dynamic submenu slots. Platform adapters
  supply first ten applications, sharing providers, and visible direct Templates
  children in enumeration order (including directories). Append newFileFallback
  after the templates separator. Resolve payloads by stable snapshot identity.
- CommandID includes breadcrumb Copy Path and sidebar Remove Bookmark, which live
  outside the file context-menu builder. Their target capabilities require adapter
  validation as they refer to a breadcrumb/bookmark, not the pane selection.

Deviations / open questions:
- This lane uses Commands/ rather than architecture Support/, as explicitly assigned.
  KeyModifiers is an OptionSet rather than the architecture's Set<KeyModifier>, per
  the lane request. Raw masks are preserved; effectiveModifiers normalizes uppercase
  ASCII for display/conflict detection. Display orders Command before Shift (⌘⇧N).
- The scoped Finder command additions follow architecture 8.3 and 14.5, which override
  the wider parity catalogue. Proposed tab/alias/eject and later feature shortcuts
  are not installed. isNew marks new menu entries; CommandID.isPlanned marks disabled
  deferred commands. Duplicate has no binding because Cmd+D remains Toggle Star.
- Ordinary selection mutations are conservatively disabled for virtual locations and
  search overlays (B-031), even if a caller mistakenly supplies a destination. Trash
  explicitly permits Put Back and Delete Immediately. Empty Trash and Clear Recent
  are location-only; operation-level permission/empty-content checks remain adapters'
  responsibility. A later decision to mutate selected search/Recent originals needs
  an explicit selected-item capability contract, not the stale last-directory URL.
- F-050 Properties retains single-selection behavior; background Properties requires
  a concrete directory. Help remains empty. No editor/sheet gestures are registered
  as global menu shortcuts: their existing local completion/cancel handling remains.
- macOS still must verify disabled Return/Space/Cmd+Backspace equivalents reach text
  responders, standard Services population, and function-key translation. Linux tests
  establish data/validation correctness only. Opus review after 22:00 is outstanding.

Needed changes elsewhere: HelmUI must adapt these data tables and supply the above
focus/capability facts; no cross-lane source edits or shared-type changes are required.
