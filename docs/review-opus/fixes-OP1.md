DRAFT: pending review, 2026-11-05

# OP1 judgement-fix pass (Opus lead)

## READ THIS FIRST: nothing in this pass was compiled or run

This session had file tools only (Read, Write, Edit, Glob, Grep) and **no shell**. So:

- `swift build`, `swift test` and `scripts/rebuild/run_all.sh` were **NOT RUN**.
- `git status` / `git diff` were **NOT RUN**, so the baseline is the session-start snapshot (clean at
  `7dfe1ba`) plus what the Read tool showed.
- "Failing test first" could **not be observed**. Tests were written with the fix; none has been seen red
  or green.

**FIXED below means "edited and desk-checked only".** It does not mean verified. Treat every entry as
unverified until the commands in "Verification owed" have been run. Do not count this pass as evidence
that the tree builds.

The remote Higgsfield `sandbox_exec` tool was visible but deliberately not used: it is not this worktree,
and the brief says no network.

## Scope 5: signal 11 in AK2SearchRegressionTests

**Disposition: no production race found; not a test-specific flake. Most likely a stale incremental build
of the HelmSearch test/product objects. Inference from logs, not proven. No code changed. Owner action below.**

### Evidence

1. **It reproduces on the same binary, so it is not timing-dependent there.** `lane_AK3.log:5086-5125`:
   full run crashes; the isolated test on the same scratch directory crashes again (`Search retry exit: 1`,
   with a backtrace); the scratch directory is moved aside, a fresh `swift build --build-tests` runs, and the
   same test passes (`Fresh Search retry exit: 0`). `lane_F2.log` has two consecutive crashes at one test.
   `fixes-F3.md:39-44`: `swift package clean` plus rebuild went from crash to 529 tests passing.
2. **The location is a code path, not a test.** All logged crashes are at the first call from HelmSearch
   code through `any FileSystem`:
   - F2/F3: `ContractIntegrationTests.testLegacyAndSymbolicScopesUseOnlyTheirDeclaredRoots`, then the first
     HelmSearch suite to run.
   - K11/AK3: `AK2...testDirectoryVanishingAtEnumerationKeepsEarlierResults`. The test before it,
     `testDefaultScopes...`, stays on the metadata path (`reason == nil`) and never touches `fileSystem`.
3. **The fault address is image-relative, not heap garbage.** Low 12 bits repeat within a build under ASLR:
   `...4f5` three times (F2, F2, F3), then `...355` (AK3), `...5f5` (K11). Every one ends in hex `5`.
4. **The fault address matches a sync function being treated as an `AsyncFunctionPointer`.** An async call
   through a witness computes `entry = slot + *(int32 *)slot`. If the slot holds a plain sync function with
   the usual `push rbp; mov rbp,rsp` prologue (`55 48 89 e5`, as int32 `-0x1A76B7AB`), then
   `F = fault + 0x1A76B7AB` should be an aligned code address:

   | Run | fault (`rax`/`rip`) | `F` | `rcx` (a real continuation, prologue `55 41 56 48`) | `rcx - F` |
   |---|---|---|---|---|
   | K11 | `0x55845cee55f5` | `0x558477650da0` | `0x558477c986c0` | `0x647920` (6.58 MB) |
   | AK3 | `0x55adcfc2b355` | `0x55adea396b00` | `0x55adea9dd280` | `0x646780` (6.58 MB) |

   Different builds and ASLR slides give almost the same distance, so `F` looks like a stable location in the
   test image. F3's `rcx` held a heap pointer, so that run adds nothing to this table (`lane_F3.log:3006`).
   This is why the backtrace shows only `swift_job_run`: async tail calls leave that as the return address.
5. **The K11 build log fits.** `crash_tests_K11.log:1-76`: the `swift test` phase re-wraps
   HelmCore/FileSystem/Persistence/Operations ASTs and recompiles HelmCoreTests, HelmFileSystemTests,
   HelmOperationsTests and HelmPersistenceTests, but has **no `Compiling HelmSearchTests` line**. HelmSearchTests
   defines `FileSystem` conformers (`AK2ListingFixture`, `SearchListingFixture`), whose witness tables live in
   those objects.
   - Caveat: the preceding `swift build --target HelmSearch` phase may have rebuilt the HelmSearch product
     module. Its log was not readable here. This row covers HelmSearchTests only.
6. **Related precedent.** `fixes-AO3.md:75-78` records "an incremental link referenced the fake's former
   initializer symbol": a dependent not rebuilt after a dependency's API change. A removed symbol fails at link;
   a moved witness slot fails like this, at run time.
7. **Conditions.** Lanes edit one worktree while long-lived scratch directories build incrementally
   (`input file ... was modified during the build` appears repeatedly in `lane_F2.log`).

### Production code reviewed

Package-wide grep for `withUnsafe*Continuation`, `Unmanaged`, `unowned`, `nonisolated(unsafe)`,
`unsafeBitCast`, `assumeIsolated`: the only `Unmanaged` uses are in the macOS-only `FSEventsMonitor`, which
Linux does not compile. Every `@unchecked Sendable` in `Sources/` was listed; none is in HelmSearch.
`SearchEngine` and `CompositeSearchSource` use no unsafe constructs and no shared mutable state. There is
nothing to fix there on this evidence.

### What does not fit, and limits

- **The "~1 in 10" framing and the passing reruns are not explained by this data.** I could not see whether
  those reruns rebuilt first. If any passed with no recompilation of the HelmSearch objects, this hypothesis
  is wrong and the crash is a real race. The proof below distinguishes the two.
- `F`'s identity is inferred from arithmetic; symbols were not available. I did not establish why the driver
  skipped the recompile, or which protocol change moved a slot.
- `lane_K23.log` has a different crash (SIGILL in `URL.standardizedFileURL`, called from
  `InMemoryFileSystem.setFailure`). It may be related; I did not investigate it.

### Owner action

1. **Prove or refute it**, using the preserved directory (the commands are read-only on the sources):
   ```
   swift test --skip-build --scratch-path /tmp/build-AK3-incremental-evidence \
       --filter AK2SearchRegressionTests.testDirectoryVanishingAtEnumerationKeepsEarlierResults
   nm -S /tmp/build-AK3-incremental-evidence/debug/HelmSearchTests.build/*.o | grep 'FileSystem.*WP$'
   nm -S /tmp/build-AK3/debug/HelmSearchTests.build/*.o                      | grep 'FileSystem.*WP$'
   ```
   Same crash on every `--skip-build` run plus a witness-table size difference confirms it. A crash that comes
   and goes on that fixed binary refutes it and reopens the race question.
2. **If confirmed, run acceptance `run_all.sh` from a clean scratch directory**, and while lanes are editing,
   treat signal 11 as "rebuild clean and rerun once" while keeping the log. I did not edit `run_all.sh`:
   the brief scopes this item to documenting the recommendation, and the script is another lane's.
3. The test was not changed or weakened.

## Findings

**FIXED = edited and desk-checked only, never compiled or run.** Tests named here have not been seen to pass or fail.

**Totals for the 31 scoped findings:** 12 FIXED; 2 partly fixed; 2 already fixed by AO3 (confirmed by reading); 2 DEFERRED; 2 REJECTED; 11 OPTIONS. Another 14 owner-decision items are OPTIONS only, in `docs/handoff/OWNER_DECISIONS_NOTE.md`.

### FB1

| ID | Disposition | What changed and why | Evidence |
|---|---|---|---|
| FB1-2 | Already FIXED by AO3; part REJECTED; part DEFERRED | AO3 added the read lane, inactivity deadlines and `clearQuarantine`, so a read timeout no longer disables a volume for good. **REJECTED:** `st_dev` keying, because it needs a `stat` on a possibly hung mount from the caller. **DEFERRED:** host wiring of `volumeRoots` and `clearQuarantine`. Not an owner policy call. | `IOExecutor.swift:85-92`, read only |
| FB1-3 | FIXED | `displayedPath` is now purely lexical, so deleted children under `/private`-aliased roots survive the filter. T-7 skip removed. | `FSEventsMonitor.swift`; `AF1RegressionTests.testMonitorFilterIsLexicalForRootDescendantsAndSiblings` |
| FB1-4 | FIXED | Each volume reads under its own executor key. A failed volume goes to `diagnostic` and is omitted; if all fail, the first failure is thrown. The mount table is read with no keys, because "prefer pre-fetched values" could block the whole list on a stale mount. T-8 skip removed. | `VolumeReader.swift`; 4 tests in `AO3DeferredVolumeTests` |
| FB1-5 | Already FIXED by AO3; part DEFERRED | `ExecutionCache` holds the per-operation names. **DEFERRED:** ancestor `entry` caching, because the ancestor walk is a safety check and caching it widens the race. | `ExecutionCache.swift`, read only |
| FB1-8 | FIXED | Home Trash failure still throws. A volume Trash failure yields a warning and the listing continues. `.notFound` is skipped; cancellation is rethrown. `TrashLocation.Availability` is not wired. | `TrashSource.swift`; `VirtualSourceTests.testDeniedVolumeTrashWarnsWithoutHidingHomeTrash` |
| FB1-10 | FIXED, Mac-unverified | Remote volumes go straight to polling, and a mount that does not answer a 2 s probe counts as remote. Polling backs off for slow reads. The 50 ms flush timer now runs only while events wait. | `FallbackMonitor.swift`, `PollingMonitor.swift`, `EventCoalescer.swift`; `OP1MonitorSelectionTests` (the polling-selection test is trivially true on Linux and only exercises the branch on macOS) |
| FB1-11 | FIXED narrowly; residual is OPTIONS | Exact-path allowlist `/tmp`, `/var`, `/etc`. The review's "accept symlink ancestors" would have weakened `RecoveryTests.testSymlinkAncestorCannotRedirectMutation`, which still applies to everything else. T-4 should resolve on a Mac; unverified. | `OperationExecutor.swift:140,151`; `RecoveryTests.testOnlyOSManagedSymlinkAncestorsPassTheWalk` (its assumption about the fake was checked against `InMemoryFileSystem.swift:67`) |
| FB1-15 | Partly FIXED; rest DEFERRED | The enumerator now pre-fetches the listing keys on macOS. **DEFERRED:** folding the keys into one `resourceValues` call and making cloud keys opt-in, which needs syscall measurement on a Mac. | `LiveFileSystem.swift`, `MetadataReader.listingPrefetchKeys`; no test (T-9 still open) |
| FB1-16 | DEFERRED | Timing-sensitive safety code, so I did not edit it unrun. A cancelled `DispatchWorkItem`, as the review proposes, does not release the timer before its deadline. The design to use is one sweeper per executor that checks start timestamps. | `IOExecutor.swift:47`, still one timer per call |
| FB1-19 | FIXED, macOS branch only | `createAlias` reserves the name with an exclusive create before writing the bookmark, because `writeBookmarkData` replaces silently. On a later write failure the placeholder stays, as with any partial exclusive write. | `LiveFileSystem.swift:201-215`; `OP1MonitorSelectionTests.testAliasCreationRefusesAnOccupiedDestination` (macOS only) |

### FB2

| ID | Disposition | What changed and why | Evidence |
|---|---|---|---|
| FB2-6 | FIXED | Repeated Back or Forward before the first batch now accumulates steps, bounded by history, and commit moves that many. History still moves only on commit. I read the existing users (`WindowStoreTests:200-212`, `TabReducerTests:35`, `F1StateRegressionTests:58`, the `K15` and `T2StoreTests` fuzz) and found no conflict. | `TabReducer.swift:17-29`, `NavigationHistory.swift`, `TabNavigation.swift`; 5 tests in `OP1MonitorAndHistoryTests` |
| FB2-7 | FIXED | A retrying stop sets `monitorRetrying` and publishes no failure, so a retry window does not flash a failed listing. Exhausted stops still degrade visibly. | `TabReducer.swift`, `TabState.swift`; 3 tests in `OP1MonitorAndHistoryTests` |
| FB2-8 | FIXED | Root, unmount and unavailable events during busy states defer validation instead of restarting it, and they no longer overwrite a foreground load. A superseded validation still finishes and publishes, because returning silently left the reducer pending forever. | `TabReducer.swift`, `TabNavigation.swift`, `DirectoryEffectRunner.swift:132-141`; 4 tests in `OP1MonitorAndHistoryTests`, `OP1EffectRunnerTests.testValidationStillCompletesWhenANewerRootEventArrivesDuringTheRead` |
| FB2-9 | OPTIONS | Spec line 1514 can be read per source or as all-or-nothing, and `testMalformedSourceReportsOnceAndWritesNothing` pins all-or-nothing. Changing it would be weakening a test without a ruling. Recommend per key. | `OWNER_DECISIONS_NOTE.md` |
| FB2-10 | OPTIONS | Contract change needing an owner assignment, as the brief says. | `OWNER_DECISIONS_NOTE.md` |
| FB2-11 | FIXED | A nil factory on a directory now keeps a passive watch, so refresh and validation still run. Virtual locations still return nil: publishing `.failed` there, the first option I looked at, would paint healthy Trash and Recents as failed. | `DirectoryEffectRunner.swift:43-51`; 2 tests in `OP1EffectRunnerTests` |
| FB2-15 | REJECTED | `SearchRanker.swift:89` assigns a unique rank by offset, and `tieLess` handles scoring ties. The reported instability does not occur. | Read only |
| FB2-17 | REJECTED as proposed | `TabReducerTests.swift:185` pins an immediate `.refreshPaths`. The usual case costs two reads, and the `.monitorWatching` reconcile is needed for correctness. | Read only |

### OK1

| ID | Disposition | What changed and why | Evidence |
|---|---|---|---|
| OK1-5 (judgement part) | DEFERRED, with a recommendation | Following roots at depth 0 conflicts with `testSkippedExplicitRootsAreDisclosed`, `testLegacyFallbackAlsoDisclosesSkippedAndVanishedRoots` and `SearchEngineTests.swift:112-113,157-159`. AK2 already removed the silent empty. | `OWNER_DECISIONS_NOTE.md` |
| OK1-7 (judgement part) | FIXED | While typing, a grammar failure becomes a literal name search, and strict `compile` is unchanged. An invalid explicit filter or oversize query is not broadened. Users see a plain message instead of a case name. | `SearchQueryParser.swift`, `SearchSessionDriver.swift`; 6 tests in `OP1TypingPolicyTests` |
| OK1-11 (judgement part) | OPTIONS | Custom folder icons. Recommend accepting the loss for now, with a Mac spike. | `OWNER_DECISIONS_NOTE.md` |
| OK1-22 | FIXED | Gallery uses root items only, because it has no disclosure. Children are out of order, selection and filmstrip. | `GalleryState.swift`; `GalleryTests.testChildrenExpandedInListViewStayOutOfGalleryOrder` |

### OK2

No HelmUI code was changed. That target has never compiled, so a change could not be checked even in principle.

| ID | Disposition | Notes |
|---|---|---|
| OK2-11 | OPTIONS, spike plan below | Rename error popover |
| OK2-12 | OPTIONS, spike plan below | Rename end-of-editing; the owner also rules on commit or cancel |
| OK2-13 | OPTIONS, spike plan below | Sidebar row in `List(selection:)` |
| OK2-22 | OPTIONS | Recommend aligning panes to F-065 after a ruling |
| OK2-23 | OPTIONS | Recommend current folder in a directory, everywhere in Recent |
| OK2-27 | OPTIONS | Recommend reporting the rejection, then normal precedence |
| OK2-28 | Partly FIXED; host DEFERRED | Doc comment only, in `SessionRestorePlan.swift`: `isAvailableDirectory` must not touch the disk, and the host precomputes off-main with a timeout. The host does not exist yet, so nothing enforces this. |
| OK2-29 | OPTIONS | Recommend "Quit Anyway" naming the unsaved documents |
| OK2-30 | OPTIONS | Recommend the host reports the outcome through the operations panel |

### Owner-decision items (no code)

O1-1 / FB1-6, OK1-2, OK1-3, OK1-12, OK2-1, OK2-2, OK2-6, OK2-8, OK2-9, OK2-10, the rename of the 4 colliding Core types (OK1-1 gate / OK2-35), Q7, Q8, Q9. All are in `docs/handoff/OWNER_DECISIONS_NOTE.md`.

## Hosted spike plan: OK2-11, OK2-12, OK2-13

Prerequisite: OK2-2 is decided and HelmUI compiles. Use a throwaway window with no store wiring. Record the macOS version and the result of each step. Keep the legacy rename open as the reference.

**OK2-11, rename error popover (`InlineRenameField.swift:28-35`).** Host `InlineRenameField` in a `List` row.
1. Type `a/`. **Pass:** the field editor stays first responder and the message shows.
2. Keep typing `bc`. **Pass:** characters land in the field.
3. Use a Japanese IME and type `/` during composition. **Pass:** composition is not cancelled.
4. Click outside to dismiss the popover, then type `/` again. **Pass:** the message shows again.

Any failure means replacing the popover with inline text bound to `model.editing?.error`, with `allowsHitTesting(false)` and an accessibility announcement. If the row clips that text, use a non-activating child `NSPanel`.

**OK2-12, rename end of editing (`InlineRenameField.swift:70-92`).**
1. Start a rename and click another row. Record whether `controlTextDidEndEditing` fires and what legacy does, commit or cancel. **Pass:** the session leaves editing state with the outcome the owner rules.
2. Press Shift-Tab. Record whether `insertBacktab` reaches the coordinator. **Pass:** handled, not default behaviour.
3. Click into another app while renaming. Record the same.

The fix is an `ended` closure, `controlTextDidEndEditing` in the coordinator, and `insertBacktab` with a matching Core key.

**OK2-13, sidebar row (`SidebarRowView.swift:18-30`).** Host in `List(selection:)`.
1. Click a row. **Pass:** the selection binding changes.
2. Use arrow keys. **Pass:** the highlight follows the selection.
3. Look at the highlight. **Pass:** one native highlight, not doubled.
4. Click the already selected row. **Pass:** it activates through `.simultaneousGesture`.
5. Open the context menu. **Pass:** it still opens and targets that row.

Any failure means removing the `Button` and manual background, using `.tag(place.id)`, and navigating on selection change.

## Files touched

- **Sources (18):** `HelmApp/SessionRestorePlan`, `HelmCore/Gallery/GalleryState`, `HelmCore/State/{NavigationHistory,TabNavigation,TabReducer,TabState}`, `HelmFileSystem/Live/{LiveFileSystem,MetadataReader}`, `HelmFileSystem/Loading/DirectoryEffectRunner`, `HelmFileSystem/Monitor/{EventCoalescer,FSEventsMonitor,FallbackMonitor,PollingMonitor}`, `HelmFileSystem/Providers/VolumeReader`, `HelmFileSystem/Virtual/TrashSource`, `HelmOperations/Execute/OperationExecutor`, `HelmSearch/Query/SearchQueryParser`, `HelmSearch/Sessions/SearchSessionDriver`.
- **Existing tests (6):** `GalleryTests`, `AF1RegressionTests`, `AO3DeferredVolumeTests` (rewritten), `VirtualSourceTests`, `AO3SafetyTests` (one comment only), `RecoveryTests`.
- **New tests (4):** `OP1MonitorAndHistoryTests` (12), `OP1EffectRunnerTests` (3), `OP1MonitorSelectionTests` (3 + 1 macOS-only), `OP1TypingPolicyTests` (6).
- **Docs:** this file and `docs/handoff/OWNER_DECISIONS_NOTE.md`.

**Tests written: 33 functions, 1 of them macOS-only:** 25 in new files, 4 in the rewritten `AO3DeferredVolumeTests`, and 1 each added to `GalleryTests`, `AF1RegressionTests`, `VirtualSourceTests` and `RecoveryTests`. No existing assertion was weakened. Skips removed: T-7 and T-8. A grep finds the remaining `XCTSkip` calls only in `F4RegressionTests.swift:29` and `TagsTests.swift:22,39`.

This list was checked against the `git status` snapshot the harness attached when the session resumed. I did not run git myself.

## Verification owed

**All of these were NOT RUN.** There are no test counts from this pass. Figures from earlier lanes (from their commit messages, and they predate these edits) were Core 690, FileSystem 217 with 2 skips, Operations 177, Persistence 82, App 15.

```
swift build --build-tests --scratch-path /tmp/build-OP1
swift test --scratch-path /tmp/build-OP1
bash scripts/rebuild/run_all.sh
```

Run from a clean `/tmp/build-OP1`, because of Scope 5. Expect `run_all.sh` to exit 1 for the 4 known Core name collisions even if everything else passes (`f411338`); any other failure is new. Check these first, as the edits most likely to fail:

1. **`OP1EffectRunnerTests.testValidationStillCompletes...`:** depends on task ordering through the coalescer.
2. **`OP1MonitorAndHistoryTests` monitor cases:** the reducer's busy-state logic was changed in several places by reading alone.
3. **`F14` and `K34` monitor tests:** read as compatible, not run.
4. **macOS only, on the first Mac run:** the `FallbackMonitor` local/remote branch, `createAlias`, and the `/tmp` ancestor rule.

Also still owed: the Scope 5 proof commands above, and the failing-test-first check the brief asked for. To get that, temporarily revert each source change and confirm its test goes red.

## Open issues

- The tree may not compile; nothing here has been built.
- Copy, move and Trash stay refused on a real Mac until O1-1 is decided.
- There is no launchable app until OK2-1, OK2-2 and OK2-8 are decided.
- `run_all.sh` stays red until the rename is decided.
- Scope 5 is an inference, not a proven cause, and `lane_K23.log`'s SIGILL was not investigated.
