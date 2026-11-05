# Spot-check SC2b: lanes AO3 and OP1

Date: 2026-11-05. Branch `forge/rebuild-build`, HEAD `fd526cf`.

**Method and limits:** I reviewed by reading only, with no shell and no compile. Evidence is from the code at HEAD, not only the diffs. The Linux result is confirmed from the log (`/tmp/OP1fix-full.log:3153`: 1313 tests, 0 failures). Nothing here has been compiled or run on macOS. Statements about Apple behaviour are marked where they come from memory.

## Verdict

**Accept after corrections.**

- **AO3:** accept after small test corrections. I found no data-loss regression in replace, evidence or quarantine logic. All of it is proven on the fake only, because native copy, move and Trash still refuse (`LiveFileSystem.swift:91-92`).
- **OP1:** accept after C-1 and C-2. C-1 can make FSEvents drop every child event under `/tmp` and `/var` on a Mac. C-2 is an owner-decision boundary problem.
- **Owner-only items:** none was silently implemented, with one disclosed exception (FB1-11, C-2).
- **Tests:** no skip was added. Every removed or changed assertion traces to a step that no longer exists or to an intended behaviour change. Two tests prove less than their reports claim (C-4, C-8).

## AO3 changes

| Change / ID | Verified | Evidence | Action |
|---|---|---|---|
| O1-3 replace trashes original in place | yes | `OperationPlanner.swift:187-196`; `ForwardEvidence.swift:77-84`; inverse order `UndoPlanner.swift:26-44`; `AO3SafetyTests.swift:10` | None |
| O1-4 repeated basename blocks plan | yes | `OperationPlanner.swift:151-153,168,173`; `AO3SafetyTests.swift:30` | None |
| O1-7 parts 2-3 read lane, mutation latch | yes | `IOExecutor.swift:52-84,106-128`; lock order is executor then state, and `expireIfIdle` drops the state lock before the callback (`:144-156`); read callers `LiveFileSystem.swift:41,99,219,227,233`, `CloudAvailability.swift:13`; `AO3QuarantineTests.swift:7,29` | C-11 |
| O1-7 part 4 inactivity watchdog | partial | Atomic against expiry: `IOExecutor.swift:138-156`. Skipped entries give no progress: `LiveFileSystem.swift:69,73,75-76`. `runWithProgress` has no caller or test: `IOExecutor.swift:99-102` | C-10, C-12 |
| O1-10 execution cache | partial | Code is correct: `ExecutionCache.swift:30-54`; `OperationExecutor.swift:201-206,217-220`; ancestors still read per step at `:146-156`. Test is weaker than the claim: `AO3WorkBudgetTests.swift:19,24` | C-4 |
| O1-11 path-keyed evidence, fail closed | yes | `ForwardEvidence.swift:14,33,46-48`; `OperationExecutor.swift:37-40`; `AO3SafetyTests.swift:47,57,130`. Matches `O1-operation-safety.md:290-299`. Side effect is in C-9 | C-9 |
| O1-13 alias classification | yes | `MetadataReader.swift:42`; `AF1DarwinRegressionTests.swift:17-29` | Mac run owed |
| O1-15 destination revalidated before retirement | yes | `OperationExecutor.swift:167-170`; `AO3SafetyTests.swift:67` | None |
| O1-16, O1-17 admission signature and order | yes | `OperationExecutor.swift:24-25,29,35`; `History/README.md:9-10`; `AO3SafetyTests.swift:88`; grep finds no one-argument admission closure in code | None |
| O1-18 host duty documented, no reset | yes | `History/README.md:44-50`; latch still at `OperationExecutor.swift:115` | Residual, see below |
| O1-19 explicit origins | yes | `OperationExecutor.swift:17`; `WindowOperationHistory.swift:102`; grep confirms no Sources caller, so the "no host constructs these" claim holds | None |
| O1-23 fake volume IDs, bounded stage name | yes | `InMemoryFileSystem.swift:22-30`; `OperationPlanner.swift:189`; `AO3SafetyTests.swift:38,115` | None |
| O1-20, O1-21, O1-22 deferred | yes | No change to ChangeToken or verifier rules; `UniqueNamer.swift:26-27` still splits the final extension; README corrected | None |
| T-6 live refusal maps correctly | yes | `AO3SafetyTests.swift:97`; `OperationExecutor.swift:104-106` | None |

## OP1 changes

| Change / ID | Verified | Evidence | Action |
|---|---|---|---|
| FB1-3 lexical monitor filter | partial | Pure function is correct: `FSEventsMonitor.swift:8-25`. The production root is not `/private/...` by construction: `:37,94`. The test only passes a literal `/private/tmp` root: `AF1RegressionTests.swift:172` | **C-1** |
| FB1-4 per-volume reads | partial | Omit and throw logic is correct: `VolumeReader.swift:32-56`; `AO3DeferredVolumeTests.swift`. The group awaits every child, so a hung mount delays the whole list | C-5 |
| FB1-8 volume Trash warns | partial | Control flow is correct: `TrashSource.swift:23-38`; `VirtualSourceTests`. The warning reaches only `diagnostic`, which defaults to a no-op: `DirectoryLoadPipeline.swift:26,84` | C-6 |
| FB1-10 remote volumes poll, on-demand flush | partial | Selection, backoff and flush are correct: `FallbackMonitor.swift:47-54,75-96`; `PollingMonitor.swift:34-47`. The probe lane is keyed per directory: `FallbackMonitor.swift:34` | C-7 |
| FB1-11 `/tmp`, `/var`, `/etc` allowlist | partial | Exact-path match: `OperationExecutor.swift:140,150-153`; `RecoveryTests.swift:61-78`. `testSymlinkAncestorCannotRedirectMutation` is unchanged (`:53-60`). The check required by the review is missing, and the owner boundary is unclear | **C-2** |
| FB1-15 prefetch keys | yes (as partly fixed) | `LiveFileSystem.swift:51`; `MetadataReader.swift:12-18` match the keys read at `:39` | None |
| FB1-16 deferred | yes | One timer per call: `IOExecutor.swift:47`. The reason given for rejecting `DispatchWorkItem` matches my recollection of the dispatch cancel docs | None |
| FB1-19 exclusive alias reservation | partial | Matches the review's fix: `LiveFileSystem.swift:203-211`. `mapping` keeps `.collision(noMutation: true)`: `FileSystem.swift:26`. Only the refusal path is tested: `OP1MonitorSelectionTests.swift:35` | C-3 |
| FB2-6 repeated Back/Forward | yes | `TabReducer.swift:17-29`; `TabNavigation.swift:43,66-75`; intermediate entries keep their selection; `OP1MonitorAndHistoryTests` | None |
| FB2-7 retrying stop | yes | `TabReducer.swift:78-89,210-213`; `TabNavigation.swift:6`. I traced every exit: cancel, new start, final stop and watching all clear `monitorRetrying` | C-13 |
| FB2-8 deferred validation | yes | `TabReducer.swift:96-99,126-137`; `DirectoryEffectRunner.swift:132-141`; `WindowStore.swift:128-131`. I traced for stuck `monitorValidationPending` and found none: `monitorWorkCompleted` clears it first (`TabReducer.swift:54`) and `monitorStopped` clears it on watch loss (`:80`) | C-13, C-14 |
| FB2-11 passive watch | yes | `DirectoryEffectRunner.swift:43-51`; `OP1EffectRunnerTests` | None |
| OK1-7 typing policy | yes | `SearchQueryParser.swift:46-62`; `SearchSessionDriver.swift:36-37,45,52`; `OP1TypingPolicyTests`. Any `kind:nope` through the driver now broadens to a name search, which contradicts the comment at `SearchQueryParser.swift:6` | C-14 |
| OK1-22 gallery roots only | yes | `GalleryState.swift:22-29,37,46,58`; root prefix contract `PresentationSnapshot.swift:29,46-49,62` | None |
| OK2-28 doc only | yes | `SessionRestorePlan.swift:29-31` | None |
| FB2-15, FB2-17 rejected | yes | `Rank/SearchRanker.swift:79,86,89`. The FB2-17 pin is `TabReducerTests.swift:184`, not `:185` as cited | C-14 |
| FB1-2, FB1-5 "already fixed by AO3" | yes | `IOExecutor.swift:85-92`; `ExecutionCache.swift`. `clearQuarantine` and `volumeRoots` have no host wiring, as disclosed | Residual |
| OP1 report totals and file list | yes | Recounted: 31 findings (12/2/2/2/2/11), 18 source files, 33 test functions | None |

## Test deletions and changes

| Change | Verified | Evidence | Action |
|---|---|---|---|
| Replacement boundaries 5 to 4; `testReplacementFailureAtTrashBackup` deleted; planner kinds updated | yes, legitimate | The backup step no longer exists; payload and journal checks kept: `K15ReplacementBoundaryTests.swift:10-18`; `ExecutorTests.swift:58,66-85`; `PlannerTests.swift:47`. Required by `O1-operation-safety.md:108` | C-8 (stale names) |
| `testBackupTrashRejectsSubstitution` became `testOriginalTrashRejectsSubstitution` | partial | Now the same call as `testReplacementTargetRejectsSubstitution`: both are `checkArtifact(index: 2)`, `F7RegressionTests.swift:35-37` | C-8 |
| `testCancelledPlanningDoesNotEnterExecutor` lost its executor | partial | Unreachable call removed, and new state assertions are real. The empty-journal and absent-file assertions now check objects nothing is connected to: `HistoryAdmissionTests.swift:84-105` | C-8 |
| `origins:` added across about 20 test files | yes | Mechanical. Undo fixtures keep their shared store: `ExecutorTests.swift:55` | None |
| AF1 `XCTExpectFailure` and `XCTSkip` removed | yes, stronger | `AF1RegressionTests.swift:172-192` | See C-1 |
| `AO3DeferredVolumeTests` skip canary replaced by 4 tests | yes, stronger | `AO3DeferredVolumeTests.swift` | None |
| K34 lifecycle test rewritten (OP1fix) | yes | Both cancellation assertions kept; started and pending assertions added; change follows FB2-8: `K34MonitorLifecycleTests.swift:14,17-26` | None |
| Recovery test fixture and `/tmp` assertion (OP1fix) | yes | Exact fake refusal: `InMemoryFileSystem.swift:80`; mapping `OperationExecutor.swift:112`. Proves admission only, as disclosed | None |
| `OP1MonitorAndHistoryTests` canonical helper (OP1fix) | yes | Spelling only; all order and step assertions remain: `:9` | None |
| Skip inventory | yes | Exactly three sites: `TagsTests.swift:22,39`; `HelmUITests/.../F4RegressionTests.swift:29` (target not compiled) | None |

## Owner-decision items

| Item | Verified not implemented | Evidence | Action |
|---|---|---|---|
| O1-1 / FB1-6 native mutation | yes | `LiveFileSystem.swift:91-92`; `AO3SafetyTests.swift:97` | None |
| OK2-1, OK2-2 host and targets | yes | `Package.swift:28-33` still commented; no `@main` or app delegate in Sources | None |
| Rename of 4 Core types | yes | `DropSession.swift:7`; `DropValues.swift:13,59`; `ToolbarItem.swift:5` | None |
| OK1-2, OK1-3, OK1-12 | yes | No `notCloud`, `updates(for`, or thumbnail `maxConcurrent` in Sources | None |
| FB2-9, FB2-10 | yes | `MigrationTests.swift:48` kept; `loadChildren` appears only in a README | None |
| OK1-5, OK1-11, OK2-6/8/9/10, OK2-11/12/13/22/23/27/29/30, Q7-Q9 | yes | Neither lane's diff touches `HelmUI`, `HelmPersistence`, search roots or address entry. The only `HelmApp` edit is the OK2-28 doc comment | None |
| FB1-11 / O1-12 allowlist | **no: disclosed, not silent** | See C-2 | **C-2** |
| `OWNER_DECISIONS_NOTE.md:5` "Nothing below has been implemented" | **no** | Contradicted by its own `:225` and by `OperationExecutor.swift:140` | **C-2** |

## Concurrency and macOS API check

- **New hazards found:** none, apart from C-7. `VolumeReader` closures capture only Sendable state. `FallbackMonitor.start` guards its new suspension with `starting` and `stopped`. `ExecutionCache` is used only from the single running `execute`.
- **macOS branches read but never compiled:** `createAlias`, `FallbackMonitor.volumeIsLocal`, `VolumeReader.readVolume`, `listingPrefetchKeys`. I found no signature problem, but the first Mac compile must confirm them.

## Prioritized corrections

### P1: before accepting OP1

**C-1. Canonicalize the FSEvents root with `realpath(3)`.** At `FSEventsMonitor.swift:37`, replace `resolvingSymlinksInPath()`.

- FB1-3 assumes that call returns `/private/tmp/w`. As I recall Apple's documentation, it strips a leading `/private` when the stripped path exists, which would give `/tmp/w`. I also recall FSEvents reporting real paths (`/private/tmp/w/x`) for a `/tmp` registration. Neither has been run here, and the comment at `:5-6` repeats the review's unverified claim.
- The old filter standardized both sides, so existing children matched either way. If both recollections hold, the new lexical filter matches **no** children under `/tmp` and `/var`. That is worse than the deleted-child bug it fixes. Paths like `~/Documents` are unaffected.
- `O1-operation-safety.md:290,314` already says to use `realpath`.
- `MonitorAndCacheTests.swift:113-124` covers child creation under `TempDirectory`, so the first Mac run will show the create case. Add a macOS test that also deletes a child, then correct the comment.

**C-2. Settle the FB1-11 allowlist with the owner.**

- `fixes-AO3.md:19` calls the allowlist "an alternative owner decision". `O1-operation-safety.md:316` allows it only "if the owner defers" the ItemID decision (`REVIEW_QUEUE.md:43-45`), and no ruling is recorded.
- The same line requires `/tmp`, `/var` and `/etc` to resolve to `/private/<same>`. `OperationExecutor.swift:151` checks only the kind. The `FileSystem` protocol has no link-target read, so adding the check needs a new seam. Add it, or record why it was dropped (as I recall, these links are SIP-protected).
- Change `OWNER_DECISIONS_NOTE.md:5` and the FB1-11 section to say the allowlist is live and reversible, and ask the owner to ratify it.

### P2: before the first Mac acceptance run

**C-3. Add a macOS success test for `createAlias`.** `URL.writeBookmarkData` writing over the zero-byte placeholder is never executed; `AF1DarwinRegressionTests.swift:28` writes to a fresh path. If it refuses to overwrite, every alias creation fails and leaves an empty file.

**C-4. Tighten the O1-10 budget test.** At `AO3WorkBudgetTests.swift:19,24`, use `XCTAssertEqual(calls, 1)` and `XCTAssertEqual(finalCalls, 2)`. With the current `<=` checks, a cache leaked across executions still passes: `finalCalls` stays 1 and the name is still `file0 2`. So "a second execute uses a fresh listing" is not proven.

**C-5. Bound the Devices list delay.** `VolumeReader.details()` waits for all children, so one hung mount holds back the healthy ones for up to the 30 s timeout. That conflicts with "cannot hide the others" (`VolumeReader.swift:7`). Use a short-timeout executor for volume reads or return results incrementally. At minimum, correct the comment and the report.

**C-6. Make the volume Trash warning truthful.** `TrashSource.swift:34-35` says the failure "stays visible". With the default `diagnostic` nothing is shown. Wire it for the host or `TrashLocation.Availability`, or change the comment and record the gap.

**C-7. Stop keying the volume probe per directory.** `FallbackMonitor.swift:34` uses `url.path` on a static executor, and `IOExecutor.queues` is never pruned.

- The dictionary grows with every directory visited.
- On a hung mount, each new directory gets a new lane and blocks another thread. Quarantine does not carry between directories.
- Key by mount and bound the lanes.

### P3: cleanup, can follow

**C-8. Remove misleading tests and names.**
- Delete or differentiate one of the duplicate F7 tests (`F7RegressionTests.swift:35-37`).
- Rename `testFailureAtEveryReplacementBoundaryKeepsOriginalOrBackup`, and update the "backup" comment in `K15ReplacementBoundaryTests`.
- In `HistoryAdmissionTests.swift:84-105`, remove the two assertions on unconnected objects, or keep a real executor and assert it was not entered.

**C-9. Document the template consequence of O1-11.** A create-from-template plan built without the template in `sources` now depends on the destination. An empty folder snapshots the template, while a non-empty folder refuses, because `existingEntries` is populated and the snapshot is skipped (`ForwardEvidence.swift:33`). This follows the review's fix and only affects fakes today. Add a test and a README line telling hosts to pass the template as a source.

**C-10. Report progress before skipping entries.** At `LiveFileSystem.swift:69,73`, the `continue` paths skip `progress()`, so a long run of skipped entries can cause a false read timeout.

**C-11. Reduce timing margins in `AO3QuarantineTests`.** The 20 ms sleeps after `signal()`, and the 25 ms steps against a 100 ms timeout at `:42-47`, can flake on a busy Mac. Poll to a deadline instead.

**C-12. Test `runWithProgress(volumes:)`.** The claim that it retains the full footprint rests on reading the code alone (`IOExecutor.swift:99-102`).

**C-13. Add the tests the reviews asked for.** FB2-7 asks for the F14 recovery test to assert the phase stays `.ready` while the retry gate is held. FB2-8 asks for "exactly one cancellation". Only reducer-level equivalents exist.

**C-14. Correct small inaccuracies.**
- `TabReducer.swift:127` says "on every flush". The sticky root event is substituted only when something publishes (`DirectoryReloadCoalescer.swift:81-90`).
- `fixes-OP1.md` should cite `TabReducerTests.swift:184` for FB2-17.
- `SearchQueryParser.swift:6` should say the driver path broadens invalid grammar.

## Residuals confirmed, not lane defects

- A read timeout inside an operation still latches `OperationExecutor.quarantined` with no reset (`OperationExecutor.swift:115`). `IOExecutor.clearQuarantine` has no callers, so on a Mac one 30 s stall disables that window's executor until it is recreated. Disclosed under O1-18 and FB1-2.
- Mounts outside `/Volumes` and configured roots still share the `"/"` lane (`LiveFileSystem.swift:27-35`). Read lanes now recover, which limits the damage.
- The Scope 5 signal 11 remains an unproven inference. OP1fix recorded nonrecurrence over three clean runs, and I did not reassess it.
