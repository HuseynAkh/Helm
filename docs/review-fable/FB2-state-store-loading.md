# FB2 — state, store, loading, address bar, commands, persistence

Review of Astra draft, 2026-11-04 after 22:00 Toronto.

Reviewer: Fable (strict read-only review). Revision: worktree `forge/rebuild-build` at HEAD `4ab4d8f`. The dirty tree at review time touches only DragDrop, Gallery, Imaging, InspectorSessions, Search, SearchSessions, SpringNavigation and new AK1/AK2 tests; no file in this review's scope is modified, so every citation below is HEAD-stable.

Scope: `Sources/HelmCore/{State, Store, Model, Contracts, Content, Presentation, Commands, AddressBar, Support, Text, Naming, Settings, Places, Identity}`, `Sources/HelmFileSystem/Loading`, `Sources/HelmPersistence`, and their tests. Method: source and test reading only; no build, no test run, no edits outside this file. Reference order: review-01-architecture (wins), 01-architecture, 00-current-state/00b, legacy `Helm/Helm` sources. `docs/review-opus/O1-operation-safety.md` was not read; executor/undo/journal are outside this report.

Evidence standard: every finding names a scenario that fails against the code as written. Where a claim depends on Apple Foundation behaving differently from swift-foundation on Linux, the finding says so and the Linux test that passes anyway is named.

## Summary

| Severity | Count | SIMPLE | JUDGEMENT |
| --- | --- | --- | --- |
| Blocker | 0 | — | — |
| Major | 10 | 5 | 5 |
| Minor | 7 | 4 | 3 |

No Swift 5.9 / macOS 14 compile error was found in scope by reading. Sites checked for platform sensitivity and found acceptable: `AsyncStream.makeStream` (back-deployed), `NSError` underlying-POSIX classification in `JSONFileStore.swift:15-26`, `NSNumber.objCType` "c" for plist booleans in `SettingsStore.swift:47-61`, tuple reassignment `(next, effects) = reduce(...)` at `TabReducer.swift:57`, `FileEntry` custom decoder with synthesized keys, `@MainActor` effect-runner closures captured by `Task {}` in `DirectoryEffectRunner.swift:45-48`.

## Findings

### Major

#### FB2-1 — Major — SIMPLE — Cmd+Up at `/` navigates to `/..` on macOS; the root test is green only on Linux

- **Where:** `Sources/HelmCore/State/TabReducer.swift:25-30`. Test enshrining the requirement: `Tests/HelmCoreTests/StateTests/TabReducerTests.swift:151-157`.
- **Why it fails:** `URL(fileURLWithPath: "/").standardizedFileURL.deletingLastPathComponent()` returns `file:///..` under Apple Foundation (CFURL), so `parent.path` is `/..` and the comparison at `:29` stages `.directory(file:///..)`. swift-foundation on Linux returns `/`, which is the only reason the no-op assertion passes. This repeats the legacy defect that 00b C-07 identified and that `01-architecture.md:75` (F-006) explicitly committed to fix with "root detection uses the standardized path, not `deletingLastPathComponent`".
- **Failing scenario (Mac):** at `/`, press Cmd+Up. A load of `/..` is staged; on commit, history pushes `/` and the address bar shows `/..`. Back then returns to `/` (R-11 in 00b fails).
- **Exact fix:** compute `let parentPath = parent.standardizedFileURL.path` and stage only when `parentPath != normalized.path`; alternatively guard `normalized.path != "/"` first. Keep the existing test and add a Mac-only comment that it is the regression for C-07.

#### FB2-2 — Major — SIMPLE — Navigating to the current location is not a no-op

- **Where:** `Sources/HelmCore/State/TabNavigation.swift:5-13` (`stage` has no same-target guard) and `:51-69` (commit clears selection, expansion and anchor, and re-records Recent). History dedupe exists at `NavigationHistory.swift:21` but only history is protected.
- **Requirement:** review must-preserve row F-005 / B-019: same-location navigation is a no-op.
- **Failing scenario:** in `/a` with two files selected and a folder expanded, press Cmd+L, Return without editing (or click the current sidebar place). The load restarts with the cache, `selection` becomes `[]`, `expandedIDs` becomes `[]`, `anchorID` resets, and `.recordRecent` fires again. Legacy behaviour kept selection and did nothing.
- **Exact fix:** at the top of `stage`, `if state.pendingNavigation == nil, intent == .push, sameDirectory(target, state.location) { return }` where `sameDirectory` compares `mutationTarget?.standardizedFileURL.path` (see FB2-3). Explicit `.refresh` remains the reload path. Add a reducer test: stage current location, assert state unchanged and no effects.

#### FB2-3 — Major — SIMPLE — `Location.directory` equality is spelling-sensitive, so history dedupe and same-location checks miss the same folder

- **Where:** `Sources/HelmCore/Identity/Location.swift:4-5` (synthesized `Hashable` on the raw `URL`); consumers `NavigationHistory.swift:21`, `TabNavigation.swift:41` and `:59`.
- **Why it fails:** the same directory enters as different URL spellings: enumeration yields `file:///a/b/` (directory URLs carry a trailing slash on Darwin), `PathEntry.swift:17` yields `file:///a/b` when the typed text has no trailing slash (`isDirectory: false`), `goUp` yields `file:///a/`. `URL ==` compares absolute strings, so these are unequal.
- **Failing scenario:** double-click `b` inside `/a` (location `file:///a/b/`), then type `/a/b` in the address bar and press Return. `NavigationHistory.push` sees a different location and appends a back entry for `/a/b/`; Back now lands in the same folder. Recent is recorded twice for one folder. The FB2-2 guard would be bypassed for the same reason.
- **Exact fix:** canonicalize at construction time: in `stage` (and in `WindowStore.init`/`.add` default tabs) replace `.directory(url)` with `.directory(URL(fileURLWithPath: url.standardizedFileURL.path, isDirectory: true))`. The loader echoes the requested location (`DirectoryLoadPipeline.swift:118-120`), so `acceptLoad` still matches. This is independent of the deferred ItemID lexical/physical policy; it only removes trailing-slash and `//` spelling drift. Add tests: push `file:///a/b` after `file:///a/b/` leaves `back` unchanged.

#### FB2-4 — Major — SIMPLE — Address editing is blocked in Recent and Trash, and would start from a stale directory if enabled

- **Where:** `Sources/HelmCore/Commands/CommandValidation.swift:110` (`.location` enabled only when `locationKind == .directory`); `Sources/HelmCore/State/TabNavigation.swift:66-69` (`addressBar.currentDirectory` updated only when the committed target has a mutation target).
- **Requirement:** review must-preserve row F-014 / B-054: Cmd+L works in Recent and Trash and editing starts at Home.
- **Failing scenario:** navigate `/a/deep` → Recent. Cmd+L is disabled. If a host ignores validation and begins editing, `AddressEditorState.currentDirectory` is still `/a/deep`, so a relative entry like `docs` resolves under `/a/deep` instead of Home, contradicting the initial-state rule at `TabState.swift:61-62` (`mutationTarget ?? homeDirectory`).
- **Exact fix:** (a) `CommandValidation.swift:110`: `case .location: enabled = !context.textFieldFocused` (any location kind). (b) `TabNavigation.swift:66-69`: add `else { state.addressBar.currentDirectory = state.addressBar.home }` so virtual locations reset to Home. Add `CommandValidationTests` rows for `.recent`/`.trash`, and a reducer test asserting `currentDirectory == home` after committing `.recent`.

#### FB2-5 — Major — SIMPLE — Cmd+I requires exactly one selected item; legacy falls back to the current directory

- **Where:** `Sources/HelmCore/Commands/CommandValidation.swift:55` (`.properties` → `.singleSelection`) and `:95`.
- **Legacy:** `Helm/Helm/Controllers/ContentViewController.swift:716-723`: with no selection, `performProperties` shows properties for `currentURL`. Review row F-050 preserves this.
- **Failing scenario:** empty selection in `/a`, press Cmd+I. Rebuild: menu disabled. Legacy: Properties for `/a`.
- **Exact fix:** keep `.openWith` on `.singleSelection`; give `.properties` its own rule: enabled when `selectionCount == 1`, or when `selectionCount == 0 && hasMutationTarget && locationKind == .directory && !textFieldFocused` (reuse `destination`). The host maps the zero-selection case to the directory. Multi-selection stays disabled per 00 §2.8. Add a validation test for the three cases.

#### FB2-6 — Major — JUDGEMENT — A second Back (or Forward) while the first is still loading re-stages the same entry, so two presses move one step

- **Where:** `Sources/HelmCore/State/TabReducer.swift:17-24` reads `history.back.last`; history is only mutated at commit in `TabNavigation.swift:52-58`.
- **Failing scenario:** history back = [`/x`, `/y`], current `/z`. Press Cmd+[ twice quickly (before the first batch of `/y` arrives). Second press stages `/y` again (cancelling the first load); on commit, history pops once. Legacy `NavigationState` popped synchronously, so two presses reached `/x`. B-069 (failed loads do not commit) does not require losing the second step.
- **Exact fix:** record the step count in the pending value: add `steps: Int` to `PendingNavigation`; when `.goBack` arrives with `pendingNavigation?.intent == .back`, target `history.back[history.back.count - steps - 1]` and bump `steps` (bounded by `back.count`); on commit, pop `steps` entries and push the intermediate ones onto `forward` in order. Mirror for Forward. A pending Back cancelled by a push resets to one. Add a reducer test for double Back before any batch, asserting location `/x` after commit and forward = [`/z`, `/y`].

#### FB2-7 — Major — JUDGEMENT — `monitorStopped` ignores `retrying`, so every retry window publishes a failed listing and a degraded flag

- **Where:** `Sources/HelmCore/State/TabReducer.swift:73-78` (the third associated value is discarded; `monitorDegraded = true` and a `.failed` snapshot are published unconditionally). Sender: `Sources/HelmFileSystem/Loading/DirectoryEffectRunner.swift:94-95` sends `retrying: true` for attempts 1 and 2.
- **Failing scenario:** a transient `start()` failure (EACCES on a volume still mounting). For 250 ms the tab shows `.failed(.other(...))` over the existing listing and `monitorDegraded == true`; `.monitorWatching` at `:79-84` then clears it. A host that renders the F-008 "Try Again"/"No access" surface flashes it twice per recovery. `F14MonitorRecoveryTests.swift:67-106` asserts `monitorDegraded == false` only after recovery and never asserts that no failed phase was published during the gated retry.
- **Exact fix:** bind the flag: `case .monitorStopped(let generation, let error, let retrying)`. If `retrying`: advance `monitorWorkGeneration`, clear `monitorValidationPending`, set `monitorDirty = true`, and return without publishing or setting `monitorDegraded`. If not retrying: current behaviour. Strengthen the recovery test to assert the published phase stays `.ready` while the retry gate is held.

#### FB2-8 — Major — JUDGEMENT — Root validation can be restarted on every coalesced flush and can be left pending forever

- **Where:** `Sources/HelmCore/State/TabReducer.swift:113-115` (`.rootChanged`, `.volumeUnmounted`, `.unavailable` append `.validateNavigation` even when `monitorValidationPending`, `isLoading` or `monitorDegraded` is true), `:85-88` (`.monitorValidationFailed` publishes `.failed` without `!isLoading`); `Sources/HelmCore/Store/WindowStore.swift:126-129` (a new validation cancels the in-flight one); `Sources/HelmFileSystem/Loading/DirectoryReloadCoalescer.swift:81-91` (sticky root event substituted for every publication until acknowledged); `Sources/HelmFileSystem/Loading/DirectoryEffectRunner.swift:124-127` (stale revision → `return` with no action sent).
- **Failing scenario A (livelock on a slow volume):** `rootChanged` arrives, validation V1 starts reading a 100k-entry network directory (>1 s). Changes keep arriving; every flush (at most one per `maximumInterval` = 1 s) publishes `.rootChanged` because `revalidation` is still set, the reducer appends another `validateNavigation`, the store cancels V1 and starts V2, and so on. The listing never updates and each cancelled read wastes I/O until the directory goes quiet.
- **Failing scenario B (stuck pending):** V1 is reading; a second `rootChanged` is received (`rootValidationRevision` changes). V1 finishes, `acknowledgeRootValidation(revision:)` returns false, the adapter returns silently. `monitorValidationPending` stays true: `replayMonitor` is blocked (`TabNavigation.swift:85`) and `.changed`/`.rescan` only set `monitorDirty` (`TabReducer.swift:106`, `:110`). Recovery needs another root event, a manual refresh, or reactivation. If the watch is exhausted (`monitorDegraded`), `:113` still emits `validateNavigation`; the runner returns nil (`:57`), and the same stuck state results.
- **Failing scenario C (loading flash):** during a foreground load, `rootChanged` at `:113` starts validation; its failure is reduced at `:57` through `:85-88`, which publishes `.failed` over the loading snapshot before `:64` records `monitorNeedsValidation`.
- **Exact fix:** (1) `TabReducer.swift:113-115`: when `monitorValidationPending || isLoading || pendingNavigation != nil || monitorDegraded`, set `monitorDirty = true; monitorNeedsValidation = true` and (for `.unavailable`, only when not loading) publish the failed phase; otherwise emit `validateNavigation`. (2) `:86`: add `!next.isLoading` to the guard and set `monitorNeedsValidation = true` when loading. (3) `DirectoryEffectRunner.swift:124-127`: never return silently; when the revision is stale, still send `.monitorSnapshot` (on success the reducer rebinds at `:66-71`, which retires the old coalescer, and `.monitorWatching` reconciles again) or send `.monitorValidationFailed(.other("superseded"))` so `monitorWorkCompleted` can replay. (4) Tests: gate V1, deliver a second `rootChanged` and three `.rescan` flushes, assert exactly one cancellation and one follow-up validation, and that the final phase is `.ready` with fresh entries; add a loading-overlap case asserting no `.failed` publication.

#### FB2-9 — Major — JUDGEMENT — One malformed legacy key aborts the whole migration on every launch; stars and bookmarks never appear

- **Where:** `Sources/HelmPersistence/LegacyDefaultsMigrator.swift:57-67` (any decode failure throws out of `perform`), `:44-52` (nothing is written, flag unset, re-run every launch). `Tests/HelmPersistenceTests/MigrationTests.swift:48-64` enshrines "writes nothing".
- **Requirement:** `01-architecture.md:1514`: "A malformed source remains untouched, reports once, and leaves migration incomplete; do not replace it with an empty collection." The natural reading is per source: the bad key is left alone and not replaced; the others still migrate. The same paragraph's "decode all sources before committing" is satisfied by decoding each key fully across all three domains before writing that key's store.
- **Failing scenario:** the owner's Mac has valid `com.helm.starredFiles` and `helm.bookmarks` but a truncated `helm.recentAccessRecords` (recent records were rewritten on every access in the legacy app, so partial writes are the most likely corruption). First launch: sidebar has no bookmarks, no stars, no recents; every launch repeats the failure and the report (`reported` is per instance, so once per process). Legacy keys are intact, but the user has no way to recover from inside the app.
- **Exact fix:** decode per key with `do/catch` into `Result`s; after the loop, write and verify only the stores whose key decoded in every domain where it was present; skip the failed key's store entirely (no empty collection); copy settings regardless; report once listing the failed keys; leave the done flag unset so a later run unions (already supported by `:74-90`). Change the test to assert `stars.json` exists with `/safe`, `bookmarks.json` absent, flag unset, one report. If the owner prefers the all-or-nothing reading, record that decision in CONTRACT_INTEGRATION and keep the test; the stuck-forever consequence should then be surfaced in the recovery UI.

#### FB2-10 — Major — JUDGEMENT (disclosed gap) — Expanding a folder in list view never loads its children

- **Where:** `Sources/HelmCore/State/TabReducer.swift:139-140` only inserts into `expandedIDs`; `Sources/HelmCore/State/README.md:22-24` states producers supply topology and "this milestone does not initiate per-folder child enumeration"; `LoadOptions` (`Contracts/Loading.swift`) carries no expanded set; no `TabEffect` requests children.
- **Requirement:** F-037 list-view expand/collapse (legacy loaded children on disclosure).
- **Failing scenario:** list view, click the disclosure triangle on `folder`. `expandedIDs` contains it, `snapshot.children[folder.id]` is nil, nothing is rendered beneath it, and no effect is emitted for any adapter to act on. No lane owns this ("outside" at README:44).
- **Exact fix:** add `TabEffect.loadChildren(ItemID, Generation)` emitted from `.expand`, a `TabAction.childrenLoaded(Generation, ItemID, [FileEntry])` that merges into `snapshot.children` via `SnapshotBuilder.build(location:entries:children:)` (already accepts `children`), rejected when the parent is no longer present or expanded; carry the expanded set through `startLoad` so refresh re-requests them. This is a contract change and needs an owner assignment; it is listed here because it is a preserved-behaviour gap with no current owner.

### Minor

#### FB2-11 — Minor — JUDGEMENT — Locations whose monitor factory returns nil silently never reconcile after reactivation

- **Where:** `Sources/HelmFileSystem/Loading/DirectoryEffectRunner.swift:41` (nil factory → return nil, no `monitorStopped`), `:53-55` (`refreshPaths` with no watch → nil). `TabReducer.swift:164-169` emits `startMonitor` then `refreshPaths` on activation after `:170-176` marked the listing dirty.
- **Failing scenario:** a tab whose location has no monitor (virtual location or an unsupported volume) is deactivated and reactivated. `monitorDirty` is consumed by `replayMonitor`, the `refreshPaths` effect is dropped by the runner, and the stale listing stays until a manual refresh. No degraded state is shown.
- **Exact fix:** when the factory returns nil, send `.monitorStopped(generation, .other("Monitoring unavailable"), retrying: false)` so the tab is visibly degraded, or serve `refreshPaths` without a watch by reading `loader.snapshot` directly (no coalescer) and sending `.monitorSnapshot`. Virtual locations additionally need the host's own load path, since `DirectoryLoadPipeline.swift:55` throws `.unsupported` for them.

#### FB2-12 — Minor — SIMPLE — Relative entry at `/` builds `//name`

- **Where:** `Sources/HelmCore/AddressBar/PathEntry.swift:16`.
- **Failing scenario:** current directory `/`, type `Users`. `absolute` is `//Users`; `directory`/`prefix` at `:25-27` are derived from the raw string, and the resolved location spelling differs from the enumerated one (see FB2-3).
- **Exact fix:** `let absolute = expanded.hasPrefix("/") ? expanded : (currentDirectory.path as NSString).appendingPathComponent(expanded)`.

#### FB2-13 — Minor — SIMPLE — Tab-triggered refresh asserts the caret is at the end

- **Where:** `Sources/HelmCore/AddressBar/AddressEditor.swift:89-91` (`refresh` sets `caretAtEnd = true` even when the text was not replaced); `:101` is correct because text was replaced.
- **Failing scenario:** caret in the middle of `/a/doc|uments`, press Tab with no selected row. `refresh` runs, `caretAtEnd` becomes true, and the ghost suffix (`AddressEditorState.swift:31`) is shown until the host sends `.caretChanged(atEnd:)`.
- **Exact fix:** move `state.caretAtEnd = true` out of `refresh` into `accept` only; hosts already report caret moves through `.caretChanged`.

#### FB2-14 — Minor — SIMPLE — Key equivalents display ⌘ before ⇧

- **Where:** `Sources/HelmCore/Commands/KeyBinding.swift:31`.
- **Failing scenario:** Shift+Cmd+N renders as "⌘⇧N"; macOS convention is "⇧⌘N" (order ⌃ ⌥ ⇧ ⌘).
- **Exact fix:** reorder the array to control, option, shift, command and update the display test.

#### FB2-15 — Minor — JUDGEMENT — Equal-rank search results order by full path

- **Where:** `Sources/HelmCore/Model/ItemSort.swift:27-30`: relevance ties fall through to `ItemID.rawValue` (standardized path), so `/a/zeta/file` sorts before `/b/alpha/file`.
- **Exact fix:** for `.relevance`, tie-break on `localizedStandardCompare` of `name` before the ID; confirm against the legacy `SearchViewModel` ordering before changing.

#### FB2-16 — Minor — SIMPLE — `isStarred` is a linear scan with URL standardization per call

- **Where:** `Sources/HelmPersistence/StarStore.swift:15-17`.
- **Failing scenario:** a list of 100k rows asking `isStarred` per cell against 2k stars performs 200M comparisons plus 100k `standardizedFileURL` calls (which may stat under `/private` on macOS).
- **Exact fix:** keep a `Set<String>` of paths updated in `star`/`unstar`/load, and let `ReducerContext.starredIDs` be built from it once per listing.

#### FB2-17 — Minor — JUDGEMENT — A successful root validation causes up to three full directory reads

- **Where:** `Sources/HelmCore/State/TabReducer.swift:66-71` (rebind then `replayMonitor`), `:79-84` (`.monitorWatching` marks dirty and replays again).
- **Failing scenario:** one `rootChanged` on a 100k-entry directory: validation read, an immediate `refreshPaths` replay if anything was dirty, then the startup reconcile of the new watch. Three reads and three snapshot builds.
- **Exact fix:** at `:71`, replay only when `monitorNeedsValidation` is set (a root event arrived during the read); let the startup reconcile at `:83-84` be the single post-rebind refresh.

## Verified as correct (no finding)

- Monitor work ordering: `monitorWorkGeneration` is advanced at effect admission (`TabReducer.swift:187-202`), captured at execution (`WindowStore.swift:139-159`), checked once (`:45-51`); queued stale success and failure are rejected (`F14MonitorOrderingTests.swift:39-48`, `:93-115`).
- Deferred validation replay after failure (`TabReducer.swift:58-63`; `F14MonitorOrderingTests.swift:67-91`) and no synthetic `rootChanged` on retry (`DirectoryEffectRunner.swift:74-77`).
- Staged navigation retains committed-location dirtiness and validation intent (`TabReducer.swift:96-103`; `TabNavigation.swift:59-61`).
- Hidden/refresh restarts retire the watch generation (`TabNavigation.swift:18-21`) and restart an active search (`:33-36`).
- `JSONFileStore` fails closed on non-ENOENT read errors, backs up corrupt documents before emptying, and refuses dirty reloads (`JSONFileStore.swift:15-40`, `:71-80`).
- Migration formats match the legacy writers (`[URL]` JSON for stars/bookmarks, `[{path,lastAccessedAt}]` with default date strategy for recents); explicit bundle values win over the `Helm` domain (`LegacyDefaultsMigrator.swift:96-100`).
- Keyboard map mirrors `main.swift:19-142`; Return and Space are menu equivalents as review Fix 22 requires (`MenuModel.swift:63`); pane commands validate false inside text per Fix 23 (`CommandValidation.swift:87-104`); context-menu order matches `FileContextMenuBuilder.swift:12-144`.
- `ColumnBrowserState` rejects same-folder A→B→A replies by column identity plus single-use request generation (`ColumnBrowserState.swift:20-29`, `:62-68`).
- `BatchRenamePlanner` refuses ancestor/descendant pairs before emitting steps and throws cancellation without a partial plan (`BatchRenamePlanner.swift:69-74`, `:128-138`).
- Tag batch loop stops on cancellation and keeps completed successes (`TagStorage.swift:38-49`).
- `WindowStore` FIFO admission, nested-send ordering, single cancellation per lane, and shutdown behaviour (`WindowStore.swift:42-62`, `:182-191`; `T2StoreTests.swift:141-164`).

## Dispositions of prior Astra findings in scope

Status values: Confirmed-fixed, Fixed-with-new-issue, Not-fixed, Rejected-finding.

| Finding | Status | Evidence |
| --- | --- | --- |
| P1-1 nested batch rename | Confirmed-fixed | `BatchRenamePlanner.swift:69-74` emits `.overlappingSources` before steps; `RenamePair.swift:23`; `F1NestedRenameTests` runs ungated (no `XCTSkip`/env gate remains under `Tests/HelmCoreTests`). |
| P1-3 sort during rename | Confirmed-fixed | `TabReducer.swift:128` resorts `deferredSnapshot ?? snapshot`; error paths `:42`, `:77`, `:87`, `:116` base on `underlying ?? deferred ?? snapshot`. |
| P1-4 column ABA | Confirmed-fixed | `ColumnBrowserState.swift:20-29`, `:62-68`; `F1ColumnGenerationTests.swift:7-17` ungated; `K29ColumnRequestTests.swift:51-56`. |
| P1-5 restoration across restart | Confirmed-fixed | `TabNavigation.swift:24-26`. |
| P3-1 missing-file classification | Confirmed-fixed | `JSONFileStore.swift:15-26`. |
| P3-2 tag batch cancellation (Core loop) | Confirmed-fixed | `TagStorage.swift:38-49`. Composite fallback part is FileSystem/Tags, outside scope. |
| P3-3 dirty reload | Confirmed-fixed | `JSONFileStore.swift:71-80`, `:82`, `:94`. |
| P5-1 held monitor result after refresh | Confirmed-fixed | `TabNavigation.swift:18-21`; `T2StoreTests.swift:166-186`. |
| P5-2 lost change during load | Confirmed-fixed | `TabReducer.swift:92`, `:106`, `:110`; `TabNavigation.swift:78-92`. |
| P5-3 sticky unavailable | Fixed-with-new-issue | `DirectoryReloadCoalescer.swift:29-33` (only root events sticky), `:42-51` (revision ack). New issue FB2-8: silent stale-revision return and unconditional re-request. |
| P5-4 refresh with search | Confirmed-fixed | `TabNavigation.swift:33-36`. |
| P9-1 validation vs reload order | Confirmed-fixed | `TabState.swift:30-31`; `TabReducer.swift:45-51`, `:187-202`; `WindowStore.swift:139-159`. FB2-8 is a different interleaving (validation vs validation). |
| P9-2 failed staging loses changes | Confirmed-fixed | `TabReducer.swift:96-103`, `:44`; `TabNavigation.swift:59-61`. |
| P9-3 stopped watch left registered | Fixed-with-new-issue | `DirectoryEffectRunner.swift:92-96` retires the record; bounded at `:68`. New issues FB2-7 (retrying flag ignored) and FB2-11 (nil factory silent). |
| P9-4 reactivation reconcile | Fixed-with-new-issue | `TabReducer.swift:170-176`, `:164-169`. New issue FB2-11 when no watch exists. |
| P9-5 main-actor snapshot build | Confirmed-fixed | `DirectoryEffectRunner.swift:128` awaits `MonitorSnapshotWorker` (actor) with sorted input. |
| P11-2 Store README nil-return recipe | Confirmed-fixed | `Store/README.md:25-38`. |
| P13-1 retry budget reset | Confirmed-fixed | `DirectoryEffectRunner.swift:74-77`; `F14MonitorRecoveryTests.swift:67-106` requires exactly two creations. Residual cost noted as FB2-17. |
| P13-2 stranded recovery event | Confirmed-fixed | `TabReducer.swift:58-63`; `F14MonitorOrderingTests.swift:67-91`. |
| P14-1 ordering test oracle | Confirmed-fixed | `F14MonitorOrderingTests.swift:39-42` asserts fresh entries/phase before stale replies; `:93-115` same-watch two reloads. |
| P14-2 reload cancellation masked | Confirmed-fixed | `DirectoryEffectRunner.swift:23` `reloadDidFinish` seam; adapter test keeps the watch alive and awaits worker exit (F17). |
| P14-3 flush repairs disk | Confirmed-fixed | `LocationViewOptionsStore.swift:27`, `:82` `beforeSave` seam; reopen without repair flush (F17). |
| P14-4 FIFO final-only check | Confirmed-fixed | `T2StoreTests.swift:144-164` verifies each producer's full ordered load trace. |
| P14-5 progressive publication | Not-fixed (partial) | Pre-EOF progress assertions exist (F18). Producer build-count / 100k geometric-bound instrumentation around `DirectoryLoadPipeline.swift:118-120` is still absent; newest-buffered output cannot prove it. |
| P14-7 cache equivalence | Confirmed-fixed | `T2DirectoryLoaderTests.swift:18-40` counts full reads, validation reads and root reads separately; the "zero enumeration" oracle was correctly rejected. |
| P15-1 criteria-only search | Confirmed-fixed | `TabSearch.swift:6` ends search only when text and filters are both empty. |
| P15-2 package contents size | Confirmed-fixed | `PropertiesModel.swift:12-13`, `:28-31` (`contentsSize` marks packages/directories calculating). |
| P18-3 (ItemID normalization part) | Not re-counted | Deferred owner decision per REVIEW_QUEUE. FB2-3 covers only the spelling subset that is independent of the lexical/physical policy. |

Out of scope and not dispositioned here: P1-2, P2-x, P4-x, P6-x, P7-x, P8-x, P10-x, P11-1/3/4, P12, P14-6, P16, P17, P18-1/2/4/5, P19, R1-x (UI, App, Operations, FileSystem Live/Tags, Inspector, Accessibility, Search sessions, documentation). They belong to the other queue slots.

## Verdict

Not ready for Mac acceptance in this scope. By reading, nothing in scope should fail to compile with Swift 5.9 on macOS 14, and the prior fix waves largely hold: 23 prior findings confirmed fixed, 3 fixed with a new issue, 1 partially fixed. The open risk is behavioural: five Major findings are mechanically fixable by an Astra lane today (FB2-1 to FB2-5, all preserved-behaviour regressions against review rows F-005, F-006, F-014, F-050 and B-019), and five need an owner decision (FB2-6 to FB2-10). FB2-1 is the clearest example of the blind-authoring hazard: the rebuild's own root test passes only because Linux Foundation differs from Apple's. Any Mac run should begin with that test.

## Five riskiest places

1. `Sources/HelmCore/State/TabReducer.swift:45-118` with `Sources/HelmFileSystem/Loading/DirectoryEffectRunner.swift:111-142` and `DirectoryReloadCoalescer.swift:81-91`: validation priority, retry publication and sticky root events (FB2-7, FB2-8, FB2-17). Native FSEvents/vnode root replacement will exercise exactly these paths.
2. `Sources/HelmCore/State/TabNavigation.swift:5-13` and `:38-82` with `NavigationHistory.swift:19-23`: the staged-commit model versus the legacy synchronous history (FB2-2, FB2-3, FB2-6).
3. `Sources/HelmCore/State/TabReducer.swift:25-30` and every other `deletingLastPathComponent` / `fileURLWithPath` site in scope: Apple-versus-swift-foundation divergence, with a Linux-green test hiding it (FB2-1, FB2-12).
4. `Sources/HelmPersistence/LegacyDefaultsMigrator.swift:44-101` on the owner's real defaults domains: first-launch visibility of stars, bookmarks and recents (FB2-9), plus the still-unconfirmed development domain name.
5. `Sources/HelmCore/Commands/CommandValidation.swift:82-126` with `MenuModel.swift`: keyboard-contract preservation (FB2-4, FB2-5) and the Fix 22/23 responder behaviours that only a hosted Mac run can verify.
