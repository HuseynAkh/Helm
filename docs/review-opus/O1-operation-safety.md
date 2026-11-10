# O1: contracts and operation safety

**Opus review of Astra draft, 2026-11-04 after 22:00 Toronto**

- **Revision:** `fe1e5ab` on `forge/rebuild-build`. `REVIEW_QUEUE.md` names `0021ac6`. The log describes `fe1e5ab` as a docs commit on top of it, but this session has no shell, so I did not diff them.
- **Evidence:** I read source and tests only. Nothing was built or run, so every scenario, fix and proposed test below is unexecuted.
- **Labels:** `[K]` marks platform knowledge I did not verify here. `[Mac]` means the finding needs confirming on macOS. An unlabelled finding follows from the portable code.
- **Paths:** file names resolve under `Sources/` and `Tests/`. The test module is given where a name repeats.
- **Severity:** Review-01 definitions, with one stated exception: O1-1 and O1-2 are ranked Blocker because no host can ship a working file manager on them, even though neither destroys bytes on its own.

## Findings

### Blockers

#### O1-1: The live provider cannot satisfy the conditional mutation contract

**Where:** `FileSystem.swift:45-51, 85-92`; `LiveFileSystem.swift:88-94`; `FileCopier.swift:13-15, 22-24`; `ExecutorTests.swift:161-178` pins the refusal; `docs/handoff/REVIEW_QUEUE.md:46-48` discloses it.

**Failing scenario:**
- On `LiveFileSystem`, every `.copy`, `.move` and `.trash` step ends in `.verificationUnavailable`. Only `createFile` and `createDirectory` execute.
- Undo of New File or New Folder also refuses, because its inverse is `.trash`. On a real Mac the executor can create items and do nothing else.
- This goes beyond a missing implementation. `[K]` Darwin has no atomic compare-identity-and-rename: `renamex_np(RENAME_EXCL)` only guarantees destination exclusivity, and `trashItem` is path-based. As worded ("must refuse if it cannot guarantee this"), no live conformer can ever comply.
- All 1,198 tests exercise conditional mutation only through the fake's actor-atomic `mutate` (`InMemoryFileSystem.swift:169-179`).

**Fix (owner decision; keep refusing until approved):**
1. Amend the contract to a bounded race: compare, admit exclusively, mutate, verify the output, and report anything unconfirmed as needing reconciliation.
2. Implement `LiveFileSystem.mutate`:
   - Open the source with `O_RDONLY | O_NOFOLLOW` (`O_SYMLINK` for links), `fstat` it, compare dev, inode, mtime and size with the precondition, and confirm the path with `fcntl(F_GETPATH)`.
   - Regular-file copy: `fcopyfile` from that verified descriptor into `open(O_CREAT | O_EXCL)`.
   - Move: `renamex_np(src, dst, RENAME_EXCL)`, treating `ENOTSUP` as refusal.
   - Trash: `trashItem`, then `lstat` the resulting URL.
3. Return a typed receipt from `mutate` (`output: URL?`, `evidence: FileMutationPrecondition?`), which replaces the separate read at `OperationExecutor.swift:72`.
4. Add `ConditionalMutationError.outputUnverified` for a post-mutation identity mismatch, and change `OperationExecutor.swift:117` so this one case stays uncertain.
5. Add Mac fixtures for a swap before rename, an exclusive collision, the Trash receipt and a non-APFS volume. Document the remaining swap window.

#### O1-2: The reconciliation latch has no exit and fires on ordinary cancel or failure

**Where:** `OperationHistoryState.swift:57-60, 83, 90-95`; `HistoryContracts.swift:24-29`; `HistoryResultMapping.swift:9-16`; `Sources/HelmCore/OperationHistory/README.md:10-11`.

**Contradicted by:** `UndoPlanner.swift:10-12`, `Sources/HelmOperations/README.md:36-38`, and tests that bypass `WindowOperationHistory`: `BoundaryTests.swift:43-58`, `K15OperationAdversarialTests.swift:36-45`, `F16CancellationTests.swift:98-108`.

**Failing scenarios:**
1. Cancel a 3-file copy after file 1. Mapping returns `.partial` (`:16`) and the latch sets (`OperationHistoryState.swift:60`). `admit` then refuses every `beginForward` and `beginUndo`, although `UndoPlanner` can build the prefix undo that those three test files prove safe.
2. One rename fails with permission denied inside the primitive. The result is `.reconciliationRequired` and the same latch.
3. A Replace install fails after the backup move. The only original is now at hidden `.helm-backup-report.txt`, the new copy is at hidden `.helm-stage-report.txt`, and `report.txt` is gone. `UndoPlanner.swift:10` stops undo, the latch blocks history, and nothing in `Sources` offers recovery.

Nothing ever sets `reconciliation = nil`. A host's only way out is to discard the actor and the window's whole stack. The README's "no blind retry" is sound, but there is no explicit path either.

**Fix:** stop latching a known-good forward prefix, and add an explicit exit.

```swift
// OperationHistoryState.swift:60. By mapping order, a forward .partial has no uncertain outcome.
if case .reconciliationRequired = outcome { state.reconciliation = outcome }
// Keep line 83: a partly applied inverse cannot be re-run.

// HistoryContracts.swift, HistoryAction
case acknowledgeReconciliation

// OperationHistoryState.swift, reducer. The latched entry is always on top.
case .acknowledgeReconciliation:
    guard state.pending == nil, state.reconciliation != nil else { return [] }
    if !state.undoEntries.isEmpty { state.undoEntries.removeLast() }
    state.reconciliation = nil

// WindowOperationHistory.swift. entries[...] stays as evidence.
@discardableResult public func acknowledgeReconciliation() -> Bool {
    guard state.pending == nil, state.reconciliation != nil else { return false }
    OperationHistoryReducer.reduce(&state, .acknowledgeReconciliation)
    return true
}
```

The host calls this only after explicit user confirmation that shows the journal outcomes, including any hidden stage or backup paths.

**Tests:**
- A forward partial through `WindowOperationHistory` produces an executable prefix from `beginUndo`.
- `.reconciliationRequired` stays blocked until acknowledged, and the entry is gone afterwards.
- `OperationHistoryTests.swift:97-112` should keep passing unchanged.

### Majors

#### O1-3: Replace leaves the displaced original in Trash under a hidden, fabricated name

**Where:** `OperationPlanner.swift:183-184, 188, 190`; `OperationExecutor.swift:173-175`. The sequence is pinned by `PlannerTests.swift:47`, `K15ReplacementBoundaryTests.swift:10-20, 31`, `ExecutorTests.swift:66-86` and `F7RegressionTests.swift:16-57`.

**Failing scenario:** Replace `report.txt` succeeds. The Trash step's source is `.helm-backup-report.txt`, so Trash holds the user's file under that name, with that path recorded as its origin.
- `[K][Mac]` Finder hides dotfiles in Trash, and restoring returns the hidden name.
- The journal is in memory, so after a restart nothing leads back to the file.
- No test asserts the Trash leaf name.

Only O1-1's refusal keeps this off real disks today. It becomes a Blocker the day O1-1 lands.

**Fix:** trash the original in place, after the verified copy exists.

```swift
// OperationPlanner.swift:181-192; also remove the backup reservation at :184
steps.append(PlannedStep(kind: .copy, source: source, destination: stage))
steps.append(PlannedStep(kind: .verifyCopy, source: source, destination: stage))
steps.append(PlannedStep(kind: .trash, source: original))
steps.append(PlannedStep(kind: .move, source: stage, destination: target))
if moving { steps.append(PlannedStep(kind: .trash, source: source, verificationDestination: target)) }
```

This keeps "never remove before the new copy exists" (architecture §7.4, review Fix 42), with these failure behaviours:
- A failed install leaves the stage in place and the original in Trash under its real name, with prefix undo available.
- A volume without Trash refuses before the target is touched.

**Tests:** update `PlannerTests.swift:47` to `[.copy, .verifyCopy, .trash, .move]` and update the boundary indexes. Assert that the Trash leaf equals the original spelling and that its recorded origin is `original`.

#### O1-4: Replace with repeated basenames silently trashes another selected item

**Where:** `OperationPlanner.swift:146-166`, especially `:148`, `:155`, `:163`. No test among the Replace-policy call sites covers it. `docs/prereview/P6.md:66` left it as a policy question.

**Failing scenario:** Move `/a/x` and `/c/x` into empty `/b` with Replace applied to all.
1. Step 1 moves `/a/x` to `/b/x`.
2. The second item collides with the reservation made by the first (`:148`) and enters `replacement`.
3. `/b/x`, which is the user's `/a/x`, is backed up and trashed. `/c/x` is installed and then trashed from its old location.
4. The result is `.succeeded`, and `/a/x` survives only in Trash as `.helm-backup-x`.

P6 reasoned that Apply to All may authorize sequential replacement. That reasoning fits items already in the destination, not a file from the same selection, so I am raising it to a defect.

**Fix:** block it in the planner. If the owner prefers sequential replacement, the conflict UI must state that explicitly and a test must pin it.

```swift
// OperationPlanner, new stored property
private var plannedTargets: [String: Set<String>] = [:]

// transfer(_:parent:moving:), before line 155
let parentKey = parent.standardizedFileURL.path
let nameKey = FileNameComparison.key(source.lastPathComponent, caseSensitive: sensitive)
if collision && policy == .replace && plannedTargets[parentKey, default: []].contains(nameKey) {
    issues.append(.overlappingSelection(target)); return
}
// After appending steps, insert the folded key of the name actually planned
// (target for Replace, destination for the other branches).
```

#### O1-5: Read-only refusals are marked as uncertain mutations

**Where:** `OperationExecutor.swift:109-117`. Read-only throw sites are `:141`, `:189`, `:205`, `:234`, `:246`, `:257`, `:267-268`. `UndoPlanner.swift:10-12` is the consequence. The wrong behaviour is pinned by `ExecutorTests.swift:90-96`.

P12-1 named this class of bug; F16 fixed only the cancellation case (`:54-55`, `:231`).

**Failing scenarios:**
1. In `ExecutorTests.swift:90-96`, a copy of x and y fails when y's `entry` read throws at `:257`, before any primitive. `.other` falls into `default: uncertain = true`, so x's finished copy can no longer be undone, and the test asserts that outcome.
2. An inverse's second step finds its token changed at `:234`. No primitive was entered for that step, yet the outcome requires reconciliation, undo stops and O1-2 latches. The same condition from the provider correctly gives `false` (`K34AtomicExecutorTests.swift:14-16`).

**Fix:** only a primitive that was entered can leave unknown state.

```swift
// Replaces OperationExecutor.swift:109-117. Leave the quarantine rule at :107 unchanged.
let uncertain = (executionFailure != nil && !(cause is ConditionalMutationError) && mapped != .conflict)
    || (mapped == .verificationUnavailable && (forward.isMissing(step.source) || forward.isMissing(step.destination)))
let outcome = ItemOutcome(step: step, destination: executionFailure?.destination ?? step.destination,
                          result: .failure(mapped), requiresReconciliation: uncertain)
```

**Tests:**
- `F7RegressionTests.swift:202` and `CapabilityIntegrationTests.swift:51` stay true through the second clause.
- `K15OperationAdversarialTests.swift:46` stays false because its failure is inside the create primitive.
- Change `ExecutorTests.swift:96` to expect an executable inverse and run it.
- Add an inverse-mismatch test that asserts no reconciliation.

#### O1-6: Cancelling during a primitive discards the output evidence, so the operation can never be undone

**Where:** `OperationExecutor.swift:70-74`; `UndoPlanner.swift:18-19`; `IOExecutor.swift:61`; `InMemoryFileSystem.swift:30-33, 66`. Test gap: `HelmOperationsTests/F2SafetyTests.swift:89-113` asserts only `.succeeded`.

**Failing scenario:**
1. The user cancels while the last file of a Copy is finishing, and the primitive returns success.
2. The `try?` read at `:72` runs in the cancelled task and throws at `IOExecutor.swift:61`, so `metadata` is nil and the outcome is `.success(nil)`.
3. With nothing left to do, `error` is nil, the result maps to `.succeeded`, and an entry is pushed.
4. Every Cmd+Z then stops at `UndoPlanner.swift:19` and is refused. The entry stays on top, so older entries are unreachable (`WindowOperationHistory.swift:110-114`).

**Fix:** observe the output outside the cancelled task. O1-1's receipt replaces this later.

```swift
// OperationExecutor.swift:72. An unstructured task does not inherit cancellation; IOExecutor still bounds it.
if let destination {
    let fs = fileSystem
    metadata = await Task { try? await fs.entry(at: destination) }.value
} else { metadata = nil }
```

**Tests:** with a gated copier, cancel during the primitive and assert `destinationEvidence != nil` and an executable inverse. `K15OperationAdversarialTests.swift:155-160` still holds for a genuine `.success(nil)`.

#### O1-7: IOExecutor quarantines falsely and permanently, including the boot-volume key

**Where:** `IOExecutor.swift:13, 19, 28, 44-54, 77-79`; `LiveFileSystem.swift:27-35, 41, 44, 104-106`; `AppEnvironment.swift:65`; `Sources/HelmFileSystem/ModuleInfo.swift:11-12`.

**Failing scenarios:**
1. The timer starts at submission (`:77-79`) and `expire` does not check `started`. A healthy backlog on the four-wide queue can leave a read waiting over 30 s, which quarantines the volume though nothing stalled.
2. A whole listing is one timed `run` (`LiveFileSystem.swift:41`). SMB, a very large directory, or `[K][Mac]` a TCC prompt blocking `opendir` can exceed 30 s. So can a future `copyItem`.
3. `queueKey` returns `"/"` for anything outside `volumeRoots` and `/Volumes`, such as `~/Library/CloudStorage` or `/net` `[K]`.

After any of these, every read on that key fails `.timedOut` until the process restarts, even after the slow body has returned. There is no `quarantined.remove`, and the app holds one instance.

**Fix (additive to review Fix 18):**
1. Start the timer only once work has started:

```swift
queue.addOperation {
    guard self.begin(state, id: id, volumes: footprint) else { return }
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + self.timeout) { [weak self, weak state] in
        if let state { self?.expire(state, volumes: footprint) }
    }
    do { state.complete(.success(try body())) }
    catch { state.complete(.failure(error)) }
}
```

2. Add a read-only `run` path that counts timed-out bodies per volume, and lift the quarantine when the count reaches zero with no timed-out mutation outstanding.
3. Keep mutation lanes quarantined until a new `clearQuarantine(volume:)` is called after reconciliation.
4. Reset the watchdog on progress, per enumeration batch and per copy progress callback, instead of using one deadline per call.

**Tests:** using gated bodies, a queued expiry does not quarantine, a read lane recovers when its body returns, and a mutation lane stays quarantined until cleared.

#### O1-8: The P8-2 quarantine bug survives on the only primitives that run natively

**Where:** `IOExecutor.swift:61, 81, 97-105`; `LiveFileSystem.swift:143-156`; `OperationExecutor.swift:107, 111, 273-278`. The fake hides it: `InMemoryFileSystem.swift:109-110` has no cancel check.

**Failing scenario:** the user cancels while New Folder is queued. `IOExecutor` throws a plain `CancellationError` before the body runs, and `:275` wraps it as an execution failure. `:107` then quarantines the executor permanently, and `:111` requires reconciliation, which triggers O1-2. Nothing happened on disk, yet every later operation reports `.busy`.

**Fix:** the create bodies never throw `CancellationError`, so catching it proves they did not start. `OperationExecutor.swift:100, 107, 117` already classify the mapped error correctly.

```swift
// LiveFileSystem, used by createDirectory and createFileExclusively
private func runCreate(at url: URL, _ body: @escaping @Sendable () throws -> Void) async throws {
    do { try await executor.run(volume: queueKey(url), body) }
    catch is CancellationError { throw ConditionalMutationError.cancelledBeforeMutation }
}
```

**Tests:**
- Add `if Task.isCancelled { throw ConditionalMutationError.cancelledBeforeMutation }` to the fake's create methods so its behaviour matches.
- With a width-1 executor and a blocked body, queue a create and cancel it. Assert `.cancelled`, no reconciliation, and that the next plan is not `.busy`.

#### O1-9: A child vanishing mid-listing fails the whole listing

**Where:** `LiveFileSystem.swift:59-69`; `MetadataReader.swift:14`; `FileSystem.swift:30`. Reaches the UI through `DirectoryLoader.swift:26-36` and operations through `FileSystem.swift:101-107` and `OperationExecutor.swift:189, 205`.

**Failing scenario:** a temp file is deleted between readdir and `attributesOfItem` in an active folder such as Downloads. The listing ends with `.notFound`, so the UI load fails and any operation targeting that parent fails too, with O1-5's wrong classification.

P2-6 was right to stop accepting incomplete listings, but a child that no longer exists is not a gap. `DirectoryLoader.swift:77-80` already treats it as a removal.

**Fix:**

```swift
// LiveFileSystem.swift:66-69
} catch {
    let mapped = FileSystemError.mapping(error)
    if mapped == .notFound { continue }
    diagnostic(url, mapped)
    throw mapped
}
```

Permission and other errors still throw, so `HelmFileSystemTests/F2SafetyTests.swift:58-68` should hold. Add a vanished-child test through the `readMetadata` seam.

#### O1-10: Execution is still quadratic after the planner fix

**Where:** `OperationExecutor.swift:139-145, 189, 191, 237, 243`; `FileSystem.swift:101-107`; `PlanningContext.swift:35-36`; `OperationPlanner.swift:134`; `IOExecutor.swift:77`. Tests are plan-only: `HelmOperationsTests/F2SafetyTests.swift:50-71` and `F5WorkBudgetTests.swift`.

**Failing scenario:** paste 100,000 files into one folder.
- Each step re-enumerates the destination, with an `lstat` and symlink resolution per child, totalling about 5×10⁹ `lstat` calls.
- Each step also stats every ancestor twice and schedules 30 s timers per call.
- Each cross-volume item filters the whole manifest twice.

This misses architecture §12's budgets (10,000-file copy, 1,000-item undo under 2 s).

**Fix:** add per-`execute` caches.
- `occupied: [String: Set<String>]` for folded names per parent, filled with `resolveSymlinkTargets` false, updated on success and refreshed only after `.collision(noMutation: true)`. Exclusive creation remains the arbiter.
- A manifest index built once, keyed by top-level source.
- Sensitivity per parent.
- Verified ancestors above the immediate parent. Keep one `entry` on the immediate parent per step.

**Tests:** an executed work-budget test using a counting `FileSystem` spy, asserting `childNames` calls ≤ parents + collisions.

#### O1-11: URL-keyed evidence can fail open `[K][Mac]`

**Where:** `ForwardEvidence.swift:14, 35, 46`; `OperationTypes.swift:70-73`; `PlanningContext.swift:23`; `OperationPlanner.swift:146, 163`; `OperationExecutor.swift:243`. Precedent: `docs/handoff/CONTRACT_INTEGRATION.md:182-183`.

**Failing scenario:** `[K]` on Darwin, `appendingPathComponent(_:)` stats the path and adds a trailing slash for a directory, and `URL ==` treats `/b/x` and `/b/x/` as different. A directory Replace target can therefore miss its planning evidence.
- `capture` then re-snapshots at `:35`, adopting whatever occupies the path at execution start, including a substitute.
- `validate` returns silently for an unknown URL at `:46`.
- `precondition` (`:58`) still fails closed, so results range from spurious refusal to adopting the wrong object.

The fake's URLs and path keys cannot reproduce this.

**Fix:**
1. Key all evidence maps by `url.path`, which has no trailing slash `[K]`. Do not use `standardizedFileURL`, because it strips `/private` (review-01:129).
2. Fail closed for unknown paths:

```swift
// ForwardEvidence.validate
guard let url else { return }
guard let observation = observations[url.path] else { throw OperationError.verificationUnavailable }
```

3. Restrict the snapshot at `:35` to plans whose `context.sourceManifest` and `existingEntries` are both empty.
4. Expect fixtures with bare `verifyCopy` steps to need evidence. Add a Mac test using real directories and slash-bearing URLs.

#### O1-12: The ancestor walk refuses OS symlinks, so Linux-green tests go red on a Mac `[K][Mac]`

**Where:** `OperationExecutor.swift:138-145`; `Sources/HelmTestKit/Fixtures/TempDirectory.swift:6`; `K29UndoSafetyTests.swift:10, 21-22`; `HelmOperationsTests/F2SafetyTests.swift:27-28`; `ExecutorTests.swift:162-177`.

**Failing scenario:** `[K]` `/tmp`, `/var` and `/etc` are symlinks on macOS, and `FileManager.default.temporaryDirectory` is under `/var/folders`. The walk reaches `/var`, sees a non-directory and throws `.invalidPlan`.
- `ExecutorTests.swift:171` then gets `.invalidPlan` instead of `.verificationUnavailable`.
- `ExecutorTests.swift:177` fails its `XCTAssertNil(created.error)`.
- `K29UndoSafetyTests.swift:22` fails the same way.

Real user operations under these paths also refuse.

**Fix:** canonicalize at the boundary, not in the guard.
- Resolve location roots with `realpath(3)` before planning, so steps carry `/private/var/...`, and keep refusing symlink ancestors of a canonical path. Use `realpath` because `standardizedFileURL` removes `/private` (review-01:129).
- Make `TempDirectory` and the K29 fixture use it too.
- If the owner defers the ItemID decision in `REVIEW_QUEUE.md:43-45`, allow only `/tmp`, `/var` and `/etc` when they resolve to `/private/<same>`.

#### O1-13: Every symlink is classified as an alias on macOS `[K][Mac]`

**Where:** `MetadataReader.swift:17-26, 31, 34`; reach: `PlanningContext.swift:73-74`, `FileSystem.swift:97-100`.

**Failing scenario:** `[K]` `isAliasFile` is true for Finder aliases and for symlinks, so `:34` overwrites the symlink kinds computed at `:17-26`. No symlink kind ever surfaces on a Mac.
- `isDirectory(resolvingSymlinks:)` is false for a link to a folder.
- F-069/B-071 navigation and the dangling badge are lost.
- The builder's dangling re-stat is dead code.

Linux skips this `#if os(macOS)` block, so no current test can see it.

**Fix:**

```swift
// MetadataReader.swift:34
if values.isAliasFile == true && type != .typeSymbolicLink { kind = .alias }
```

Add a Mac fixture covering a link to a file, a link to a directory, a dangling link and a Finder alias.

#### O1-14: The tree-undo refusal tests pass vacuously

**Where:** `K29UndoSafetyTests.swift:30, 44-46, 56-59`; `HelmOperationsTests/F2SafetyTests.swift:36, 46-47`; `HistoryTests/WindowOperationHistoryTests.swift:110-128`. Guards: `OperationExecutor.swift:164-166, 216-218`.

**Failing scenario:** these plans and outcomes carry no `destinationEvidence` or `expectedEvidence`. If the tree guards are deleted, the tests still get `.verificationUnavailable`, now from `forward.precondition` at `:48`. Real forward executions do carry evidence, so a regression that re-enables tree undo on that path stays green. F13's own tests use leaves only.

**Fix:** add a test through the fake.
1. Execute a directory copy, a same-volume directory move and a `createDirectory`.
2. Assert `inverse.expectedEvidence[output] != nil` and `expectedKinds[output] == .directory`.
3. Edit a descendant and run the inverse.
4. Assert `.verificationUnavailable`, zero successes and an unchanged tree inventory.

Confirm by mutation: removing `:216-218` must turn it red.

### Minors

#### O1-15: Trash-with-verification does not revalidate the destination's identity

**Where:** `OperationExecutor.swift:156-158`; `TreeCopyVerifier.swift:6, 11-15, 25`; the false claim is at `Sources/HelmOperations/README.md:47-50`.

**Failing scenario:** after `verifyCopy` in a cross-volume move, a writer replaces the destination with an equal-size file. The kind-and-size check passes and the source is retired. This is Minor only because the source goes to Trash and stays recoverable.

**Fix:** add `try await forward.validate(destination, fileSystem: fileSystem)` after `:157`, with a progress-hook test at the Trash step.

#### O1-16: The admission closure cannot see the plan being executed

**Where:** `OperationExecutor.swift:24, 29, 35`; `WindowOperationHistory.swift:45, 53-54`; `HistoryTests/F23HistorySafetyTests.swift:84-87` passes the same weakened plan to both sides.

**Failing scenario:** `execute(weakened, admission: { await history.bindExecution(request: r, operation: $0, plan: genuine) })` binds successfully and runs `weakened`. F23 compares the host's claim, not the executing plan.

**Fix:** change the parameter to `admission: @Sendable (OperationID, OperationPlan) async -> Bool` and pass `plan` from `:29` and `:35`, so hosts forward what the executor provides.

#### O1-17: Trailing-closure calls rely on deprecated backward matching `[K]`

**Where:** `OperationExecutor.swift:23-25`. Call sites: `ExecutorTests.swift:75, 134`; `BoundaryTests.swift:20, 48, 68`; `HelmOperationsTests/F2SafetyTests.swift:137`; `K15OperationAdversarialTests.swift:16`; `K15ReplacementBoundaryTests.swift:35`; `RecoveryTests.swift:65`; `F7RegressionTests.swift:23, 45`.

**Failing scenario:** `execute(plan) { progress in … }` no longer forward-matches `progress`, because `admission` comes first. Swift 5 mode falls back to the SE-0286 backward scan, and Swift 6 mode removes that fallback.

**Fix:** declare `progress:` before `admission:`.

#### O1-18: `.busy` conflates quarantine with busy, and the rejected-binding duty is undocumented

**Where:** `OperationExecutor.swift:27-31, 35`; `Sources/HelmUI/Operations/OperationRowModel.swift:62`; `Sources/HelmOperations/History/README.md:8-16`.

**Failing scenario:**
- After one timeout, every operation says "Another operation is running", with no reset.
- A rejected admission returns `.invalidPlan` but leaves the reservation pending. A host that does not abort stays `.busy` indefinitely.

**Fix:** add `OperationError.quarantined` and its UI string, plus `OperationExecutor.clearQuarantine()` for use after reconciliation. Document that hosts must abort after a rejected bind.

#### O1-19: Defaults make Trash undo refuse silently

**Where:** `WindowOperationHistory.swift:102`; `OperationExecutor.swift:17`; `UndoPlanner.swift:39-41`.

**Failing scenario:** `beginUndo()` with its default `[:]` refuses every Move to Trash undo. Separately defaulted executors also hold separate origin stores.

**Fix:** remove both defaults so `recordedOrigins` and `origins` must be supplied.

#### O1-20: Verifier gaps

**Where:** `OperationExecutor.swift:19`; `FileCopier.swift:28-32`; `TreeCopyVerifier.swift:6, 11-15, 25`.

**Failing scenarios:**
- The comment on `UnavailableCopyVerifier` says size alone is insufficient, yet the default verifier authorizes source retirement on kind and size. A right-size, wrong-bytes copy retires the source.
- `[K][Mac]` AppleDouble `._*` and `.DS_Store` files on non-native volumes cause a false `verificationFailed` after a complete copy.

**Fix:** record an owner decision between content hashing and size-only retirement. Exclude known sidecars from the shape comparison on volumes without native extended attributes.

#### O1-21: Fix 55 and B-041 are half implemented

**Where:** `MetadataReader.swift:38-46`; `FileEntry.swift:31, 70`; `WindowOperationHistory.swift:110-114`; `helm-plan/docs/rebuild/01-architecture.md:1212`.

**Failing scenario:**
- `ChangeToken.childCount` is never populated natively.
- Undo refuses a changed output instead of warning and then trashing as the architecture specifies, and no override API exists.
- A refused top entry blocks older entries. It is disclosed, but one folder copy dead-ends the stack because tree undo is refused.

**Fix:** populate or remove the field, define an owner-approved override, and add an explicit "drop refused entry" action after user confirmation.

#### O1-22: The B-116 deviation is self-approved

**Where:** `UniqueNamer.swift:14`; `Sources/HelmOperations/README.md:22-24`; `NamingTests.swift:39`; `PlannerTests.swift:34-35`; `helm-plan/docs/rebuild/01-architecture.md:126, 1127`.

**Failing scenario:** a collision on `a.tar.gz` yields `a.tar 2.gz`, the defect B-116 records, while F-052 requires `a 2.tar.gz`. The draft calls the architecture "stale", and review-01 contains no override.

**Fix:** implement multi-part extensions, or get owner sign-off and remove the "stale" wording.

#### O1-23: Test and naming hygiene

- `HistoryTests/HistoryAdmissionTests.swift:84-102` is near-tautological, and line 92 is unreachable. Assert on the journal and reservation state instead.
- The fake reports a single volume (`InMemoryFileSystem.swift:209`), so the cross-volume refusal at `OperationExecutor.swift:264-266` is unexercised. Add a path-prefix volume map to the fake.
- Replace refuses target names of about 243 bytes or more because of the `.helm-backup-` and `.helm-stage-` prefixes (`OperationPlanner.swift:183-184`). Use a short generated stage name.

## Disposition of original findings

**Totals:** 12 Confirmed-fixed, 7 Fixed-with-new-issue, 0 Not-fixed, 0 Rejected-finding.

"Confirmed" means the source and tests at this revision support the fix on portable code. It does not mean executed on macOS. P2 was fixed by F2 and F5, and F9 deferred P8 to F13.

| Finding | Issue | Fix | Disposition | Evidence | See |
| --- | --- | --- | --- | --- | --- |
| P2-1 | Cancel released the lane while the kernel call continued | F2 | Fixed-with-new-issue | `IOExecutor.swift:81, 91-105`; `OperationExecutor.swift:107`; `HelmFileSystemTests/F2SafetyTests.swift:28-44`; `HelmOperationsTests/F2SafetyTests.swift:89-113` | O1-6, O1-8 |
| P2-2 | Failed exclusive write could unlink another writer's file | F2 | Confirmed-fixed | `LiveFileSystem.swift:178-181`; `HelmFileSystemTests/F2SafetyTests.swift:45-57` | |
| P2-3 | Undo trashed edited descendants | F2 | Confirmed-fixed, by refusal; folder undo is lost | `OperationExecutor.swift:45, 164-166, 213-221` | O1-14, O1-21 |
| P2-4 | Undo tokens went stale between steps | F2 | Confirmed-fixed on portable code | `OperationExecutor.swift:75-83, 168, 267-268`; `HelmOperationsTests/F2SafetyTests.swift:131-146` | O1-1 |
| P2-5 | Replace could trash the selected source | F2 | Confirmed-fixed, lexically | `OperationPlanner.swift:155-161`; `HelmOperationsTests/F2SafetyTests.swift:114-130`; `RecoveryTests.swift:84-86` | O1-4 is distinct |
| P2-6 | Incomplete listings accepted as complete | F2 | Fixed-with-new-issue | `LiveFileSystem.swift:59-69, 76`; `HelmFileSystemTests/F2SafetyTests.swift:58-68` | O1-9 |
| P2-7 | 100k selection caused billions of comparisons | F5 | Fixed-with-new-issue: plan and journal fixed, execution not | `OperationPlanner.swift:47-56`; `SourcePathIndex.swift`; `OperationJournal.swift:18, 30-33`; `OperationExecutor.swift:189, 243` | O1-10 |
| P2-8 | Tar root `./` member rejected | F2 | Confirmed-fixed | `ArchiveSafety.swift:46-53`; `HelmFileSystemTests/F2SafetyTests.swift:69-93` | |
| P6-1 | Forward mutations lacked preconditions | F7 | Fixed-with-new-issue: portable path fixed, native refused | `ForwardEvidence.swift:16-62, 75-82`; `OperationExecutor.swift:169-170, 181-184, 257-258, 268-269`; `F7RegressionTests.swift:16-57, 93-119, 133-145`; `K34AtomicExecutorTests.swift:9-19` | O1-1, O1-11, O1-15 |
| P6-2 | Cross-volume copy left destination writable | F7 | Confirmed-fixed | `IOExecutor.swift:26-54, 60-63`; `LiveFileSystem.swift:99-103, 188`; `F7AdmissionTests.swift` | O1-7 is separate |
| P6-3 | Replace undo restored the wrong case | F7 | Confirmed-fixed | `OperationPlanner.swift:109-114, 162-164, 188`; `F7RegressionTests.swift:58-77, 169-189`; `T2EvidenceTests.swift:52-111` | |
| P6-4 | Quadratic cut completion | F7 | Confirmed-fixed | `OperationResult.swift:38-52`; `F7RegressionTests.swift:78-89, 146-152` | |
| P8-1 | Undo discarded output identity | F13 | Confirmed-fixed; post-mutation window disclosed | `OperationResult.swift:17`; `OperationExecutor.swift:84-87`; `UndoPlanner.swift:13-24, 46-47`; `ForwardEvidence.swift:18-24`; `F13ContractTests.swift:9-31`; `F13UndoEvidenceTests.swift:9-64, 104-147` | O1-6 |
| P8-2 | Pre-admission cancel quarantined a clean executor | F13, F16 | Fixed-with-new-issue: conditional path only | `FileMutationPrecondition.swift:27-31`; `InMemoryFileSystem.swift:172`; `OperationExecutor.swift:96-101, 107, 117`; `F13ContractTests.swift:32-45`; `F13CancellationTests.swift:9-47`; `F16CancellationTests.swift:15-56` | O1-8 |
| P12-1 | Undo token check turned clean cancel into reconciliation | F16 | Fixed-with-new-issue: cancel only | `OperationExecutor.swift:54-55, 109-115, 231`; `F16CancellationTests.swift:9-14, 57-112` | O1-2, O1-5 |
| P16-1 | Forward reservation had no terminal path | F19 | Confirmed-fixed | `WindowOperationHistory.swift:64-69`; `OperationHistoryState.swift:41-48`; `OperationExecutor.swift:27-31, 126-132`; `HistoryAdmissionTests.swift:14-32, 54-102` | |
| P16-2 | Unrelated recovery consumed the inverse reservation | F19 | Confirmed-fixed | `WindowOperationHistory.swift:44-60, 84-91, 122-127`; `HistoryAdmissionTests.swift:33-53, 106-163`; `WindowOperationHistoryTests.swift:209-235` | |
| P20-1 | Inverse binding accepted different policy and evidence | F23 | Fixed-with-new-issue: compares the host's argument | `WindowOperationHistory.swift:53-54`; `OperationTypes.swift:64`; `PlanningContext.swift:20`; `FileEntry.swift:18`; `F23HistorySafetyTests.swift:31-108` | O1-16 |
| P20-2 | Pre-bind undo cancel had no terminal path | F23 | Confirmed-fixed | `WindowOperationHistory.swift:45-47, 74-80`; `OperationHistoryState.swift:66-73`; `F23HistorySafetyTests.swift:110-174`; `F23UndoPreparationTests.swift:20-59` | |

## Verdict

**Not accepted for release or for Mac behaviour validation.** SDK compile triage in slot B can proceed, but expect test failures from O1-12 and O1-13. There are two reasons:
- No native copy, move, Trash, rename or undo exists (O1-1).
- Under the documented host protocol, an ordinary cancel or failure ends file operations for the window (O1-2).

**What holds, by reading the code:**
- `HelmOperations` has no permanent-delete path, and `UndoPlanner` emits only `.trash` and `.move`.
- Abort and bind are serialized by the actor with no suspension between check and transition.
- Inverse binding compares the whole plan it is given.
- F13's ownership evidence refuses a same-token replacement.
- The portable executor mostly fails closed, and none of the 19 original findings is simply unfixed.

**Recommended fix order:**
1. O1-2, O1-5, O1-6 and O1-8: small, portable and tightly coupled.
2. O1-12 and O1-13: before the first Mac test run.
3. O1-3 and O1-4: before any native Replace.
4. O1-7, O1-9, O1-10, O1-11 and O1-14.
5. The owner decision on O1-1.

**Limits that stay open:** native conditional mutation and completion receipts, tree undo and descendant evidence, safe redo, durable journal and Trash origins, and reconciliation UI. No host constructs `OperationExecutor` or `WindowOperationHistory` anywhere in `Sources`, so the host protocol is unexercised end to end.

**Coverage limits:**
- No Swift 5.9 compile error is proven, but nothing was compiled.
- I searched `Sources` for language features newer than 5.9 and read the in-scope Darwin branches (`LiveFileSystem.swift:132-137, 187-191, 198-201`; `MetadataReader.swift:30-37`). The only compile-class issue found is O1-17.
- Tag and monitor Darwin code and full SDK triage belong to other queue items.
- `[K]` claims are from platform knowledge and need Mac fixtures.

### Five riskiest places

1. **`FileSystem.mutate` and its future live conformer** (`FileSystem.swift:45-51`, `LiveFileSystem.swift:88-94`). Every safety claim about native operations depends on code that does not exist yet.
2. **The reconciliation latch and outcome mapping** (`OperationHistoryState.swift:57-60, 90-95`; `HistoryResultMapping.swift:9-16`). These decide whether a user can recover or is stuck.
3. **Post-mutation observation and failure classification** (`OperationExecutor.swift:70-74, 107-117`). Errors here discard undo or wrongly mark clean work as uncertain.
4. **IOExecutor timeouts with `queueKey`** (`IOExecutor.swift:44-54, 77-79`; `LiveFileSystem.swift:27-35, 41`). One slow call can disable browsing of the boot volume until relaunch.
5. **The Replace sequence and Trash origin** (`OperationPlanner.swift:146-166, 181-192`; `OperationExecutor.swift:173-175`). This is the path where users' files can end up hidden from them.
