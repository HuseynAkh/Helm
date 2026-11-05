# Review of Astra draft, 2026-11-04 after 22:00 Toronto

## FB1 — HelmFileSystem live I/O, monitors, providers, tags, virtual sources; I/O-facing HelmOperations

Reviewer lane: Fable (slot B). Baseline reviewed: worktree `forge/rebuild-build` at
`0021ac6` / `fe1e5ab` plus the uncommitted wave-25 diff listed in the session git status
(OperationHistory, F2SafetyTests, AO1/AO2 docs). No build, test or Mac run was performed.
Nothing outside this file was modified. Opus O1 (`docs/review-opus/O1-operation-safety.md`)
was not read; executor admission, undo and journal safety are deferred to it and are only
mentioned here where I/O semantics change the outcome.

### Evidence labels used below

- **[static]** — conclusion from reading source and Foundation/Darwin API contracts; not executed.
- **[Linux-run]** — behaviour backed by a test that Astra reports green on Linux (1198 tests).
- **[Mac-unverified]** — depends on `#if os(macOS)` / `canImport(Darwin|CoreServices)` code that
  has never been type-checked or executed. Treat every such claim as a prediction, not a result.

Fix labels: **SIMPLE** = mechanical, Astra lane can apply without a design decision;
**JUDGEMENT** = needs an owner or architecture decision first.

---

## 1. Verdict

**Not ready for Mac acceptance.** No definite Swift 5.9 / macOS 14 compile error was found by
static reading of the Apple-only branches (section 4), but two behavioural regressions that
only manifest on Darwin (FB1-1 symlinks classified as aliases, FB1-11 symlinked ancestors such
as `/var` and `/tmp` refused by the executor) will turn the existing live-filesystem tests red
on the first Mac run and break navigation into symlinked folders for users. The core user
operations (copy, move, Trash through the executor) remain refused on the live filesystem by
documented owner deferral (FB1-6); that is the single largest gap against the original Helm.
The I/O executor's permanent, path-prefix-keyed quarantine (FB1-2) can disable all boot-volume
I/O for the rest of the process after one slow directory listing.

Recommended order: apply the SIMPLE fixes (FB1-1, FB1-9, FB1-12, FB1-13, FB1-14, FB1-17,
FB1-18, test items T-1/T-3/T-7) in the Astra lane before the first Mac compile; route FB1-2,
FB1-3, FB1-4, FB1-5, FB1-6, FB1-8, FB1-10, FB1-11 to the owner as JUDGEMENT items.

### The five riskiest places

1. **Live copy/move/Trash refused** — `LiveFileSystem.mutationPrecondition` /
   `FileSystem.mutate` default (`Protocol/FileSystem.swift:85-92`, `Live/LiveFileSystem.swift:91-97`),
   `FoundationFileCopier.copy(requiring:)` (`Execute/FileCopier.swift:22-24`), executor Trash path
   (`Execute/OperationExecutor.swift:174`). Every forward operation on a real Mac returns
   `verificationUnavailable`. FB1-6.
2. **IOExecutor quarantine** — `Live/IOExecutor.swift:9,19,28,44-54,75-77` plus `queueKey`
   (`Live/LiveFileSystem.swift:27-35`). Read-only timeouts permanently quarantine the shared `"/"`
   key. FB1-2, amplified by FB1-5 and FB1-15.
3. **Darwin symlink handling** — `Live/MetadataReader.swift:34` and the ancestor walk
   `Execute/OperationExecutor.swift:139-146`. Symlinks become `.alias`; `/var`, `/tmp`, `/etc`
   and user symlinked folders are refused as ancestors. FB1-1, FB1-11; Mac canaries in
   `FileSystemTests.swift:45,67` and `F2SafetyTests.swift:28`.
4. **FSEvents monitor** — `Monitor/FSEventsMonitor.swift:5-13,24,44-53,81`. Deleted children
   under `/private`-aliased roots are filtered out; context retain/release pairing and C
   callback bridging are unverified on the SDK. FB1-3.
5. **Large-folder cost** — per-step full `childNames` listing in the executor
   (`OperationExecutor.swift:190,206`, default `Protocol/FileSystem.swift:101-107`), 4–5
   syscalls per listed entry (`MetadataReader.swift:14,22,31,39,45`), one dispatch timer per I/O
   call (`IOExecutor.swift:75`). FB1-5, FB1-15, FB1-16.

---

## 2. Findings

### Major

#### FB1-1 — Major — `isAliasFileKey` reclassifies every symlink as `.alias` on macOS [Mac-unverified, static]

**Location:** `Sources/HelmFileSystem/Live/MetadataReader.swift:17-26` (symlink classification),
`:34` (`if values.isAliasFile == true { kind = .alias }`).

**Why wrong:** On Darwin `URLResourceValues.isAliasFile` is documented as true for Finder alias
files **and** symbolic links. Line 34 runs after the symlink branch and unconditionally
overwrites `.symlinkToDirectory`, `.symlinkToFile` and `.danglingSymlink` with `.alias`. The
Linux build never executes line 34, so all 1198 green tests prove nothing about it.

**Failing scenario:** User's `~/Projects` is a symlink to `/Volumes/Work/Projects`. On macOS
`entry(at:)` returns `.alias`; `FileEntry.isDirectoryLike` (`HelmCore/Model/FileEntry.swift:69`)
is false for `.alias`, so `DirectoryLoader.load` (`Virtual/DirectoryLoader.swift:23`) and
`DirectoryLoadPipeline` (`Loading/DirectoryLoadPipeline.swift:59`) throw "Not a directory";
`FileSystem.isDirectory(_:resolvingSymlinks:)` (`Protocol/FileSystem.swift:97-100`) returns
false, so any drop-target or spring logic built on it treats the folder as a file. No-follow
listings (`EnumerationOptions.resolveSymlinkTargets == false`) also come back as `.alias`, so the
`entry.kind == .danglingSymlink` re-read in `PlanningContextBuilder`
(`HelmOperations/Plan/PlanningContext.swift:73-74`) never fires on Mac. F-069/B-071 symlink
navigation, preserved on Linux, regresses on the only platform that ships.

**Existing canary:** `Tests/HelmFileSystemTests/FileSystemTests.swift:45` and `:67` assert
`.symlinkToDirectory` against `LiveFileSystem`. Expect both to fail on the first Mac run.

**Exact fix (SIMPLE):** keep the symlink classification authoritative:
`if values.isAliasFile == true && type != .typeSymbolicLink { kind = .alias }`. Add a
`#if os(macOS)` test that creates a symlink and a bookmark-file alias in a temp directory and
asserts `.symlinkToDirectory` and `.alias` respectively.

#### FB1-2 — Major — read-only timeouts permanently quarantine the shared `"/"` queue [static, Linux-run]

**Location:** `Sources/HelmFileSystem/Live/IOExecutor.swift:9` (`quarantined` is never cleared),
`:19,28,38` (admission refuses quarantined keys forever), `:44-54` (`expire` quarantines the whole
footprint on any timeout), `:75-77` (one 30 s deadline per call). Key derivation
`Sources/HelmFileSystem/Live/LiveFileSystem.swift:27-35`: anything not under a registered
`volumeRoots` entry or `/Volumes/<name>` maps to `"/"`. The entire directory listing runs inside
one `executor.run` body (`LiveFileSystem.swift:41-81`).

**Why wrong:** Review Fix 18 asked for an "unresponsive-volume state"; the implementation is an
executor-lifetime refusal keyed by path prefix. Reads cannot "still complete and require
reconciliation" (the stated rationale at `:5`), yet they quarantine identically to mutations.
Mounts outside `/Volumes` (autofs `/net`, `/Network`, sshfs/FUSE mounts in `$HOME`, SMB mounted
by `mount_smbfs` to an arbitrary directory) share the `"/"` key with the boot volume.

**Failing scenario:** User opens a 300k-entry folder on the boot volume, or any folder on a
hung SMB mount at `~/mnt/nas`. The single enumeration body exceeds 30 s (see FB1-15 for why),
`expire` adds `"/"` to `quarantined`, and every subsequent `entry`, `enumerate`, `createDirectory`,
`trashItem`, `volumeIdentifier` and `isCaseSensitive` on the boot volume throws `.timedOut`
until the app is relaunched. The Devices sidebar (FB1-4) and Trash (FB1-8) fail with it.
`ExecutorAndRegistryTests.swift:16-17` codifies the permanence; nothing tests that a read
should not quarantine.

**Exact fix (JUDGEMENT):**
1. Separate `run(readOnly:)` from mutating calls; read timeouts fail the call but do not
   quarantine, or quarantine with a bounded TTL.
2. Key queues by mount identity (`st_dev` of the path, which `volumeIdentifier(for:)` already
   computes at `LiveFileSystem.swift:215-220`), not by path prefix.
3. Expose `IOExecutor.reset(volume:)` and call it from the volume registry on
   mount/unmount/rename events so a reconnected volume is usable again.
4. For enumeration, reset the deadline each time a batch is yielded (`LiveFileSystem.swift:75-77`)
   so a slow but progressing listing is not a "stalled native call".
5. Add tests: read timeout does not block a later call on the same key; mutation timeout does;
   reset clears quarantine.

#### FB1-3 — Major — FSEvents direct-child filter drops deletions under `/private`-aliased roots [Mac-unverified, static]

**Location:** `Sources/HelmFileSystem/Monitor/FSEventsMonitor.swift:6-12` (`MonitorPathFilter`
uses `standardizedFileURL` on both the event path and the canonical root), `:24`
(`canonicalRoot = root.resolvingSymlinksInPath()`), `:81` (stream registered on the canonical path).

**Why wrong:** For a root such as `/tmp/work`, `resolvingSymlinksInPath()` yields
`/private/tmp/work` and FSEvents reports children as `/private/tmp/work/<name>`. Darwin's
`standardizedFileURL` (via `stringByStandardizingPath`) removes the `/private` prefix **only
when the resulting path exists**. A created or modified child therefore standardizes to
`/tmp/work/<name>` and its parent `/tmp/work` equals the standardized root `/tmp/work`. A deleted
child does not exist at `/tmp/work/<name>`, stays `/private/tmp/work/<name>`, its parent
`/private/tmp/work` does not equal `/tmp/work`, and line 10 returns nil. The same holds for
roots the user types as `/private/var/...`, `/var/...`, `/etc/...`.

**Failing scenario:** User browses `/tmp/build` (or any folder reached through `/var`, `/etc`),
deletes a file in Terminal. The creation of a sibling refreshes the row set, but the deletion
event is filtered out; the listing keeps a row for a file that no longer exists until a
`MustScanSubDirs`/root event or manual refresh. B-073's displayed-path mapping is otherwise
preserved.

**Exact fix (JUDGEMENT, small):** make `MonitorPathFilter` purely lexical. Compute
`rootPath = canonicalRoot.path` once (already resolved), and compare
`eventPath.hasPrefix(rootPath + "/") && !eventPath.dropFirst(rootPath.count + 1).contains("/")`
(with `eventPath == rootPath` for the root itself), without calling `standardizedFileURL` on
the event path. FSEvents always reports paths under the exact string registered at
`FSEventStreamCreate`, so no filesystem consultation is needed. Add a pure test with
`canonicalRoot: /private/tmp/w`, event `/private/tmp/w/gone` (nonexistent) expecting
`/tmp/w/gone`; it passes on both platforms with the lexical filter.

#### FB1-4 — Major — `VolumeReader.details()` is all-or-nothing on a private `"/"` key [Mac-unverified, static]

**Location:** `Sources/HelmFileSystem/Providers/VolumeReader.swift:9` (default `IOExecutor()`
private to the reader), `:17` (default volume key `"/"`), `:22-23` (`try urls.map { try
url.resourceValues(forKeys:) }`).

**Why wrong:** One blocking or failing volume fails the whole Devices list, and a single 30 s
block quarantines the reader's own `"/"` key for the life of the reader (FB1-2 semantics), after
which `details()` throws `.timedOut` on every call. Review Fix 18's intent was per-volume
isolation; here all volumes share one key and one `try`.

**Failing scenario:** A stale SMB share remains in `/Volumes` after the Wi-Fi drops.
`resourceValues` on it blocks until the kernel times out (minutes). The sidebar shows no devices
at all, including the boot volume, and never recovers in this process. Separately, one volume
answering EPERM/EIO makes `map` throw and hides every other volume.

**Exact fix (JUDGEMENT):** iterate volumes individually; run each `resourceValues` under
`executor.run(volume: url.path)`; on failure emit a `VolumeDetails` placeholder flagged
unavailable (or skip it with a diagnostic) instead of throwing; share the application
`IOExecutor` rather than creating one per reader so quarantine state is observable in one place.
Prefer the values pre-fetched by `mountedVolumeURLs(includingResourceValuesForKeys:)` and avoid
a second `resourceValues` round trip where the cache answers. Add a test with an injected
per-volume failure asserting the remaining volumes are returned (`K27VolumeTests` currently
covers only the pure registry).

#### FB1-5 — Major (performance, data completeness) — executor lists the destination parent in full for every step [static]

**Location:** `Sources/HelmOperations/Execute/OperationExecutor.swift:190` (`childNames(of:
parent)` before each mutation), `:206` (again on every keep-both retry); default implementation
enumerates the whole directory with hidden entries
(`Sources/HelmFileSystem/Protocol/FileSystem.swift:101-107`); each entry costs the full
`MetadataReader.read` (FB1-15). Ancestor walk `:139-146` also calls `entry(at:)` for every
ancestor of every step.

**Failing scenario:** Paste 5,000 files into a folder with 50,000 entries. The executor performs
5,000 full listings of 50,000 entries (2.5×10^8 metadata reads at 4–5 syscalls each) before it
has created a single file. Each listing is one `IOExecutor` body with a 30 s deadline; the first
one that exceeds it quarantines the destination volume (FB1-2) and the remaining 4,999 steps fail
`.timedOut`, leaving a partial operation. The original Helm (F-052 `uniqueDestinationURL`,
`FileOperationService.swift:192-212`) used one `fileExists` probe per name.

**Exact fix (JUDGEMENT):** use `PlanningContext.existingNames[parent]` captured once by
`PlanningContextBuilder` as the baseline, union the names this operation has created so far,
and let the exclusive primitives (`mkdir` EEXIST, `open O_EXCL`,
`collision(noMutation: true)`) arbitrate races, which they already do at `:202`. Re-list only on
a collision retry, and cache ancestor `entry` results per operation. Keep the case-fold
comparison via `FileNameComparison.key`.

#### FB1-6 — Major (behaviour not preserved; documented deferral) — copy, move and Trash are refused on the live filesystem [static]

**Location:** `Sources/HelmFileSystem/Protocol/FileSystem.swift:85-92` (default `mutate` throws
`ConditionalMutationError.unsupported`), `Sources/HelmFileSystem/Live/LiveFileSystem.swift:91-97`
(comment states conditional mutations inherit refusal "including on macOS"),
`Sources/HelmOperations/Execute/FileCopier.swift:22-24` (copier delegates to `mutate`),
`Sources/HelmOperations/Execute/OperationExecutor.swift:174` (Trash via `mutate(.trash)`).
Recorded as a deferred owner decision in `docs/handoff/REVIEW_QUEUE.md:46-48`.

**Failing scenario:** Any Paste, drag-move or Delete through the executor on macOS returns
`verificationUnavailable` with zero steps attempted. `F2SafetyTests.testUndoRefusesTreeWithoutDescendantEvidence`
(`Tests/HelmOperationsTests/F2SafetyTests.swift:28`) asserts exactly this refusal, so the test
suite enshrines the regression. F-052 (copy/move with keep-both), F-053 (Trash per item),
F-055 (rename via move) from `00-current-state.md` are not preserved.

**Exact fix (JUDGEMENT, owner design):** a native conditional-mutation adapter for Darwin:
open the source with `O_NOFOLLOW | O_EVTONLY`, `fstat` and compare `st_dev/st_ino` plus the
change token against the precondition, then within the same queue slot perform
`renamex_np(..., RENAME_EXCL)` for same-volume moves, `clonefile(..., CLONE_NOFOLLOW)` or
`copyfile(..., COPYFILE_EXCL | COPYFILE_NOFOLLOW_SRC)` for copies, and
`FileManager.trashItem` for Trash. Document that Trash is "verified immediately before, not
atomically" and route its outcome through reconciliation. Until then, the capability UI must
state that these commands are unavailable rather than failing per item.

#### FB1-11 — Major — ancestor walk refuses any path under a symlinked directory, including `/var`, `/tmp`, `/etc` [Mac-unverified, static]

**Location:** `Sources/HelmOperations/Execute/OperationExecutor.swift:139-146`: every ancestor of
every source and destination must be `.directory` or `.package`, else `invalidPlan`.

**Why wrong:** On macOS `/tmp`, `/var` and `/etc` are symlinks into `/private`, and
`FileManager.default.temporaryDirectory` returns `/var/folders/.../T/`. `entry(at: "/var")` is
lstat-based (`MetadataReader.swift:14-26`) and reports `.symlinkToDirectory` (or `.alias` with
FB1-1), never `.directory`. User-created symlinked folders (`~/Dropbox -> /Volumes/...`,
`~/Projects -> ...`) have the same shape. B-039's no-follow rule protects the *item*; applying
it to the spelling of the *path* refuses legitimate locations.

**Failing scenario:** Create New Folder in a tab showing `/tmp/scratch` → `invalidPlan`. Every
live-filesystem executor test that uses `TempDirectory` / `temporaryDirectory`
(`Tests/HelmOperationsTests/F2SafetyTests.swift:16-28`, `ExecutorTests` live cases) returns
`invalidPlan` on macOS instead of the asserted error, so the whole live operations suite goes
red on first Mac run for a reason unrelated to the behaviour under test.

**Exact fix (JUDGEMENT; interacts with O1's identity rules):** resolve the *parent* path once
with `resolvingSymlinksInPath()` before the walk and walk the resolved path, or accept
`.symlinkToDirectory` ancestors when the resolved target is a directory on the same device as
the operation's destination volume. Keep the item itself no-follow. Record the resolved spelling
in the journal so undo compares like with like (ItemID normalisation is a deferred owner
decision in REVIEW_QUEUE; this fix does not need to settle it).

### Minor

#### FB1-7 — Minor — `.package` roots cannot be loaded as directories [static]

**Location:** `Sources/HelmFileSystem/Virtual/DirectoryLoader.swift:23`,
`Sources/HelmFileSystem/Loading/DirectoryLoadPipeline.swift:59` (`guard root.isDirectoryLike`);
`isDirectoryLike` excludes `.package` by design (`HelmCore/Model/FileEntry.swift:69`, P10-3/P15-2).

**Failing scenario:** User types `/Applications/Safari.app/Contents` into the address bar or
invokes a "Show Package Contents" equivalent. The root entry for `Safari.app` is `.package`, the
load fails with "Not a directory", although `Contents` itself is a plain directory and the
pipeline would list it fine. `PlanningContextBuilder:57` and `TreeCopyVerifier:23` already treat
`.package` as traversable, so the loaders are the odd ones out.

**Exact fix (SIMPLE):** `guard root.isDirectoryLike || root.kind == .package`. Keep
`isDirectoryLike` unchanged so double-click still opens packages.

#### FB1-8 — Minor — Trash load fails entirely when any secondary `.Trashes` root errors [static]

**Location:** `Sources/HelmFileSystem/Virtual/TrashSource.swift:23-31`: any error other than
`.notFound` from any of the aggregated roots aborts the stream. `TrashLocation.Availability`
(`Volumes/PutBackPlanner.swift`) exists but is not consulted here.

**Failing scenario:** `~/.Trash` is readable; `/Volumes/USB/.Trashes/501` returns EACCES (volume
mounted with a different owner) or `.timedOut` (network volume, FB1-2). The user's own Trash
shows nothing. B-109's requirement is that *denied home Trash* is visible, not that one volume
hides all the others.

**Exact fix (JUDGEMENT):** fail only when the first (home) root fails; for volume roots, yield
`.warning("<volume> Trash unavailable: <error>")` and continue, and surface the degraded state
through `TrashLocation.Availability`.

#### FB1-9 — Minor — `MonitorRegistry` keeps a dead subscription after `start()` throws [static]

**Location:** `Sources/HelmFileSystem/Monitor/MonitorRegistry.swift:25-32`: on `start()` failure
the task broadcasts `.unavailable` but `subscriptions[key]` keeps the failed monitor. Later
`subscribe(path:)` callers for the same key (`:20`) attach to it and never receive events or a
retry. Low production impact: `DirectoryEffectRunner` does not use the registry.

**Exact fix (SIMPLE):** in the catch, after broadcasting, `self?.retire(key:generation:)` which
removes the subscription if the generation matches and finishes its listeners, so the next
subscriber triggers a fresh factory call. Add a test with a factory whose first monitor throws.

#### FB1-10 — Minor — FSEvents is always preferred, including on network volumes [Mac-unverified, static]

**Location:** `Sources/HelmFileSystem/Monitor/FallbackMonitor.swift:28-34` (candidate order),
`:41-46` (a 50 ms flush timer per monitor for its whole lifetime).

**Why wrong:** FSEvents reports changes made through the local kernel only; edits by other
clients on SMB/NFS/AFP shares produce no events, so a listing of a shared folder goes stale even
though `PollingMonitor` exists. The original Helm had the same limitation (B-015), so this is a
preserved gap rather than a regression, but the fallback design makes it easy to close. The
50 ms wake-up per open tab is a continuous CPU cost; `EventCoalescer` could instead schedule a
single flush when it has pending events.

**Exact fix (JUDGEMENT):** read `.volumeIsLocalKey` for the root; for remote volumes run
`PollingMonitor` (alone, or alongside FSEvents). Replace the fixed 50 ms loop with an on-demand
flush task created when the coalescer first buffers an event.

#### FB1-12 — Minor — error mapping misses the Cocoa/POSIX codes the Mac paths will produce [static]

**Location:** `Sources/HelmFileSystem/Protocol/FileSystem.swift:20-35`.

**Gaps:** `NSFeatureUnsupportedError` (3328), which `FileManager.trashItem` returns for volumes
without a Trash, maps to `.other(...)` instead of `.unsupported`, so review Fix 41's
"volume without trash" flow cannot trigger; `ENOSPC` (28) and `NSFileWriteOutOfSpaceError` (640)
become `.other(localizedDescription)`; `EROFS` (30) / `NSFileWriteVolumeReadOnlyError` (642),
`ENOTEMPTY` (66), `ENAMETOOLONG` (63), `EXDEV` (18) likewise. `ResourceValuesTagStorage.swift:17-25`
already maps 3328 correctly, so the two mappers disagree.

**Exact fix (SIMPLE):** add `.unsupported` for Cocoa 3328 and POSIX `ENOTSUP`/`EXDEV`; add
`.permissionDenied` for 642/`EROFS`; add a typed `.noSpace` case (or map 640/28 to a stable
`.other("No space")`) so the UI can show the right message. Add table-driven mapping tests.

#### FB1-13 — Minor — xattr tag writes follow symlinks while every other read is no-follow [Mac-unverified, static]

**Location:** `Sources/HelmFileSystem/Tags/NativeTagAttributes.swift:19,56,68,80` (`options = 0`,
comments at `:18,55,68,80` claim this matches Foundation resource values).

**Why wrong:** `URL.resourceValues(forKeys: [.tagNamesKey])` (`ResourceValuesTagStorage.swift:14`)
and `MetadataReader` (lstat) describe the link itself; `getxattr`/`setxattr` with `options = 0`
operate on the target. Tagging a symlink row therefore reads the link's tags through one storage
and writes the target's tags through the other, and `CompositeTagStorage`'s read-compare-write
loop (`XattrTagStorage.swift:36-40`) compares the target against itself while the displayed row
never changes.

**Exact fix (SIMPLE):** pass `XATTR_NOFOLLOW` to all four Darwin calls and correct the comments;
add a Mac test that tags a symlink and asserts the target's `_kMDItemUserTags` is untouched.

#### FB1-14 — Minor — `entry(at:)` bypasses the metadata seam and omits `volumeIdentifier` [static]

**Location:** `Sources/HelmFileSystem/Live/LiveFileSystem.swift:14-16` (injectable `readMetadata`),
`:58,64` (listing supplies `volume`), `:98-100` (`entry(at:)` calls `MetadataReader().read(url)`
directly, no volume).

**Failing scenario:** The same file read through a listing and through `entry(at:)` yields
`FileEntry` values that differ in `volumeIdentifier`; any equality or evidence comparison
between the two (planning manifest vs. execution re-read, cache token vs. fresh read) can
mismatch for no real change. Tests that inject `readMetadata` cannot gate single-entry reads.

**Exact fix (SIMPLE):** `try readMetadata(url, true, volumeKey)` where `volumeKey` is the
`st_dev` string of `url` (fall back to `queueKey(url)` as the listing does).

#### FB1-15 — Minor (performance) — four to five syscalls per listed entry [static]

**Location:** `Sources/HelmFileSystem/Live/MetadataReader.swift:14` (`attributesOfItem`, lstat),
`:22` (`fileExists(isDirectory:)`, stat, links only), `:31` (`resourceValues`, getattrlist),
`:39` (`isReadableFile`, access(2)), `:45` (`CloudAvailabilityReader.readMetadata`, a second
getattrlist for ubiquitous keys, on every entry). `LiveFileSystem.swift:51` passes
`includingPropertiesForKeys: nil`, so the enumerator pre-fetches nothing.

**Failing scenario:** 100k-entry folder ≈ 450k syscalls inside one executor slot; on a
spinning disk or SMB this exceeds the 30 s deadline and trips FB1-2. The original Helm listing
(F-035) read one `resourceValues` batch per entry.

**Exact fix (JUDGEMENT):** fold the ubiquitous keys and `.isReadableKey`/`.isSymbolicLinkKey`
/`.fileResourceTypeKey`/`.fileSizeKey`/`.contentModificationDateKey` into the single
`resourceValues` call, pass that key set to `enumerator(at:includingPropertiesForKeys:)` so the
kernel batch (`getattrlistbulk`) serves it, keep `attributesOfItem` only for `systemNumber`/
`systemFileNumber`, and make cloud keys opt-in via `EnumerationOptions`.

#### FB1-16 — Minor (performance) — one 30 s dispatch timer per I/O call [static]

**Location:** `Sources/HelmFileSystem/Live/IOExecutor.swift:75-77`.

**Failing scenario:** `TreeCopyVerifier.tree` and `PlanningContextBuilder` call `entry(at:)` per
node; a 100k-node tree schedules 100k `asyncAfter` closures that each hold the footprint set for
30 s after the call completed. **Fix (JUDGEMENT):** a `DispatchWorkItem` cancelled in `complete`,
or one periodic sweeper per queue that checks start timestamps.

#### FB1-17 — Minor — `PollingMonitor` re-emits the same `.unavailable` every tick [Linux-run, static]

**Location:** `Sources/HelmFileSystem/Monitor/PollingMonitor.swift:50-55`.

**Failing scenario:** A permission-denied root produces an `.unavailable` event every 3 s for as
long as the tab is open, each one admitting a validation read upstream (P13-2 territory).
**Fix (SIMPLE):** remember the last failure and emit only on transition; emit `.rescan` once
when a read succeeds after failure.

#### FB1-18 — Minor — fake and live collision oracles differ [static]

**Location:** `Sources/HelmFileSystem/Fake/InMemoryFileSystem.swift` key = NFC + `lowercased()`;
planner and executor use `FileNameComparison.key` = NFD + `caseInsensitiveCompare` under
`en_US_POSIX` (`HelmCore/Naming/UniqueNamer.swift`); APFS uses Unicode simple case folding with
normalisation-insensitive comparison, and HFS+ stores NFD.

**Why it matters:** every collision/keep-both test runs against the fake, so disagreements
between `lowercased()` and locale case-insensitive comparison (e.g. dotted/dotless I, sharp s,
titlecase digraphs) are invisible on Linux and will surface as either a false conflict or an
EEXIST on APFS. **Fix (SIMPLE):** make the fake's key `FileNameComparison.key(name, caseSensitive:
false)` when `caseSensitive == false`, so fake, planner and executor share one oracle; document
that APFS may still differ and that EEXIST is the final arbiter.

#### FB1-19 — Minor — `createAlias` can overwrite an existing destination [Mac-unverified, static]

**Location:** `Sources/HelmFileSystem/Live/LiveFileSystem.swift:195-200`. `URL.writeBookmarkData`
replaces an existing file; unlike `createDirectory`/`createFileExclusively` it offers no EEXIST
arbitration, so two "Make Alias" commands racing on the same name silently overwrite.
**Fix (JUDGEMENT):** create the destination with `open(O_CREAT|O_EXCL)` first (reusing
`writeExclusively`), then write the bookmark data into it; map EEXIST to `collision(noMutation:
true)` so keep-both retries work.

---

## 3. Compile-risk review of the Apple-only branches [Mac-unverified]

No definite compile error was found by reading. Each item below is a prediction from the
public API signatures and must be confirmed by the Mac compile in the MAC_HANDOFF sequence.

| Site | What was checked | Assessment |
| --- | --- | --- |
| `FSEventsMonitor.swift:44-53` | `FSEventStreamContext(version:info:retain:release:copyDescription:)` memberwise init; retain/release closures match `CFAllocatorRetainCallBack`/`ReleaseCallBack` (`UnsafeRawPointer?` in/out); closures capture nothing | Expected to compile. Lifetime: `passUnretained` + stream `retain` callback gives the stream +1 after `FSEventStreamCreate`; local `owner` may die, `release` balances on `FSEventStreamRelease`. If `Create` returns nil no retain occurred and `owner` is freed normally. Correct as written, but unverified at runtime. |
| `FSEventsMonitor.swift:54-55` | `FSEventStreamCreateFlags(k... \| k...)`: constants import as `Int`, flags as `UInt32` | Same pattern as original `FileMonitorService.swift:34-38`; expected to compile. |
| `FSEventsMonitor.swift:56-80` | `FSEventStreamCallback` arity and types; `paths` is `UnsafeMutableRawPointer` bridged to `CFArray` via `Unmanaged`; `flags[index]` is `UInt32`; `kFSEventStreamEventIdSinceNow` wrapped in `FSEventStreamEventId` | Mirrors the shipping original (`FileMonitorService.swift:104-138`); expected to compile. |
| `FSEventsMonitor.swift:96-99` | Actor `deinit` reading isolated `stream` | Allowed in Swift 5.9 (deinit is nonisolated but the actor is uniquely referenced). |
| `DispatchSourceMonitor.swift:23-37` | `open(_, O_EVTONLY)`, `DispatchSource.makeFileSystemObjectSource`, `.revoke`, `watcher.data`, cancel handler closes fd | Expected to compile. Handler captures `watcher` (self-cycle) which `stop()`/`deinit` break by `setEventHandler(handler: nil)`; the actor is captured weakly, so no actor leak. |
| `LiveFileSystem.swift:137-138` | `var result: NSURL?` passed as `AutoreleasingUnsafeMutablePointer<NSURL?>`, `result as URL?` | Identical to original `FileOperationService.swift:113-115`; expected to compile. |
| `LiveFileSystem.swift:198-199` | `bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)`, `URL.writeBookmarkData(_:to:)` | Expected to compile. |
| `LiveFileSystem.swift:209` | `.volumeSupportsCaseSensitiveNamesKey` → `volumeSupportsCaseSensitiveNames: Bool?` | Expected to compile. |
| `LiveFileSystem.swift:154,169` | Darwin `mkdir(_, mode_t)`, 3-arg `open` overlay | Expected to compile. |
| `MetadataReader.swift:5,31-36` | `UniformTypeIdentifiers` import; `.contentTypeKey`, `.isPackageKey`, `.isAliasFileKey`; `UTType.identifier/localizedDescription` | Expected to compile (macOS 11+). Behaviour bug FB1-1. |
| `CloudAvailability.swift:20-29` | `URLUbiquitousItemDownloadingStatus` is an `Equatable` struct; `case .current?:` pattern on an Optional of it | Expected to compile via `~=` on Equatable. |
| `VolumeReader.swift:19-23` | `mountedVolumeURLs(includingResourceValuesForKeys: [URLResourceKey], options: [])`, `.volumeIsEjectableKey` | Expected to compile. Behaviour FB1-4. |
| `NativeTagAttributes.swift:19,56,68,80` | Darwin `getxattr/setxattr/removexattr/listxattr` arities (position `u_int32_t`, options `Int32`), `ENOATTR`, `E2BIG` | Expected to compile. Behaviour FB1-13. |
| `ResourceValuesTagStorage.swift:17-22` | `NSFileNoSuchFileError`, `NSFileReadNoSuchFileError`, `NSFileReadNoPermissionError`, `NSFeatureUnsupportedError` as `Int` globals | Expected to compile on Darwin Foundation. |
| `HelmCore/Support/AutoreleaseScope.swift` | `autoreleasepool(invoking:)` rethrows generic | Expected to compile. |
| `Loading/DirectoryEffectRunner.swift` | `@MainActor` closures stored in `StoreEffectCancellation(@MainActor () -> Void)` | Expected to compile under Swift 5 mode with targeted concurrency checking; re-check if the manifest owner enables strict concurrency. |

Runtime items that only Mac can settle: FSEvents coalescing latency 0.3 s with `NoDefer`;
`kFSEventStreamCreateFlagWatchRoot` delivering `RootChanged` on parent rename (B-072);
`FileManager.enumerator` skipping `.skipsHiddenFiles` by `isHidden` semantics (consistent with
`MetadataReader.swift:32`); `trashItem` behaviour on volumes without `.Trashes` (FB1-12);
`setAttributes(.creationDate)` in `applyDirectoryMetadata` (`LiveFileSystem.swift:124-133`).

---

## 4. Test-quality findings

- **T-1 — Vacuous on Mac, heavy on Mac.** `Tests/HelmFileSystemTests/MonitorAndCacheTests.swift:103-115`
  `testFallbackStartsAndStopsOnLinux` watches `/` and asserts the mechanism only under
  `#if os(Linux)`. On macOS it opens a recursive FSEvents stream on the boot volume root
  (`FileEvents | WatchRoot`), asserts nothing about which mechanism started, then stops.
  **Fix (SIMPLE):** use `TempDirectory`; assert `mechanism` is one of the three names on every
  platform; under `#if os(macOS)` create a file and await a `.changed`/`.rescan` event.
- **T-2 — Linux-only guards leave Mac behaviour untested.** `CapabilityIntegrationTests.swift:46-51`
  (case sensitivity, cloud availability), `ProviderMetadataTests.swift:50-76` (VolumeReader,
  CloudAvailabilityReader), `TagsTests/TagsTests.swift:20-39` (xattr round trip on `/dev/shm`).
  No Mac counterpart exists for `tagNamesKey` vs `_kMDItemUserTags` agreement
  (`ResourceValuesTagStorage.swift:8` MAC-VERIFY), `volumeSupportsCaseSensitiveNames` on APFS,
  or `isUbiquitousItem` on a non-iCloud path. **Fix (SIMPLE):** add `#if os(macOS)` branches
  with the inverse expectations (APFS default volume → case-insensitive; `/tmp` file → cloud
  `.unknown`; real `/` mount present in `details()`).
- **T-3 — Expected Mac red (good canary).** `FileSystemTests.swift:45,67` assert symlink kinds
  against `LiveFileSystem`; they detect FB1-1 and should be kept, not weakened.
- **T-4 — Expected Mac red for the wrong reason.** `Tests/HelmOperationsTests/F2SafetyTests.swift:16-28`
  builds under `temporaryDirectory` (`/var/folders/...`) and asserts
  `.verificationUnavailable`; with FB1-11 the result on Mac is `.invalidPlan` from the ancestor
  walk, so the assertion fails before the behaviour under test runs. Every other live executor
  test under `TempDirectory` shares this. Fix FB1-11 or have `TempDirectory` resolve symlinks in
  its root (`HelmTestKit/Fixtures/TempDirectory.swift`).
- **T-5 — Quarantine permanence is codified, not decided.** `ExecutorAndRegistryTests.swift:8-19`
  asserts a timed-out key stays refused and uses a blocking body with no distinction between read
  and mutation. Add the decision tests listed under FB1-2 once the owner rules.
- **T-6 — Conditional mutation refusal on live FS.** `K34ConditionalMutationTests` and
  `T3ConditionalMutationTests` exercise only `InMemoryFileSystem`. Add one live test asserting
  `LiveFileSystem.mutate` throws `ConditionalMutationError.unsupported` and that the executor
  maps it to `verificationUnavailable` without touching the disk (asserts the deferral stays
  honest until FB1-6 is implemented).
- **T-7 — No filter test for `/private`.** Add the pure `MonitorPathFilter` case from FB1-3.
- **T-8 — No partial-volume-failure test.** `K27VolumeTests` covers `VolumeRegistry` only; add
  the injected-failure case from FB1-4.
- **T-9 — Listing cost is untested.** `T2LoadingTests.swift:137-144` uses synthetic entries;
  nothing measures syscalls per entry on `LiveFileSystem`. A counting `readMetadata` injection
  (seam exists at `LiveFileSystem.swift:23-26`) can assert one metadata read per entry and zero
  extra reads for `entry(at:)` after FB1-14.

---

## 5. Behaviour preservation against `00-current-state.md` / `00b-opus-review.md`

| Audit item | Status in draft | Evidence |
| --- | --- | --- |
| F-035 nonrecursive listing, batches, hidden preference | Preserved (Linux); cost regressed | `LiveFileSystem.swift:36-87`; FB1-15 |
| F-052 copy/move with keep-both, F-053 Trash per item, F-055 rename | **Not preserved on live FS** (refused) | FB1-6; `F2SafetyTests.swift:28` |
| F-069 / B-071 symlink navigation | Preserved on Linux, **regresses on macOS** | FB1-1 |
| F-032 Trash listing (`~/.Trash` only in original) | Extended to volume `.Trashes`; all-or-nothing | `TrashSource.swift:12-15`; FB1-8 |
| F-057 templates include directories | Preserved | `FileSystemTests.swift:60-63` |
| F-031 Devices list, B-080 dedupe | Preserved in pure `VolumeRegistry`; live read fragile | FB1-4 |
| FileMonitorService flags (`FileEvents|UseCFTypes|NoDefer`, 0.3 s) | Preserved, plus `WatchRoot` (B-072) | `FSEventsMonitor.swift:54-55,82` |
| B-073 displayed path for symlinked root | Preserved except `/private` deletions | FB1-3 |
| B-015 polling fallback | Present but never chosen when FSEvents starts | FB1-10 |
| B-109 denied Trash visible, never empty success | Preserved intent; over-broad failure | FB1-8 |
| B-107 unresponsive-volume isolation (review Fix 18) | Implemented as permanent executor-wide refusal | FB1-2 |
| Review Fix 40 (enumeration in sync closure, opendir preflight) | Preserved | `LiveFileSystem.swift:41-47` |
| Review Fix 41 (`trashItem -> URL?`, volume without Trash flow) | Signature preserved; flow blocked by mapping | FB1-12 |
| Review Fix 42/43 (case-folded collision checks) | Preserved in planner; fake oracle differs | FB1-18 |
| Review Fix 65 (cache key includes showHidden) | Preserved | `DirectoryLoader.swift:33` |

---

## 6. Dispositions of prior findings and fixes in this scope

| Finding / fix | Disposition | Evidence |
| --- | --- | --- |
| P2-1 (R1-1 → F5) | Confirmed-fixed | Reviewed in the F5 record and the current `LiveFileSystem.enumerate` body; no regression found. |
| P2-2 | Confirmed-fixed | Current executor/listing paths match the F2 record. |
| P2-3 | Deferred to O1 | Admission/undo semantics; I/O side has no additional defect beyond FB1-6. |
| P2-6 (fail-closed enumeration) | Confirmed-fixed | `LiveFileSystem.swift:66-72,79`: any non-`notFound` child error or enumerator error throws; vanished children skipped. |
| P2-8 | Confirmed-fixed | Exclusive create maps EEXIST to `collision(noMutation: true)` (`LiveFileSystem.swift:156,172`). |
| P3-2 | Confirmed-fixed | No divergence found between the F3 record and current source. |
| P6-1 | Deferred to O1 | Executor safety. |
| P6-2 (per-volume executor keys) | Confirmed-fixed with residual | Keys exist (`LiveFileSystem.swift:27-35`) but `VolumeReader`, `CloudAvailabilityReader` and non-`/Volumes` mounts default to `"/"`: FB1-2, FB1-4. |
| P8-1 | Deferred to O1 | Replacement/identity attack; FB1-14 notes a `volumeIdentifier` inconsistency that evidence comparisons should not rely on. |
| P8-2 (clean cancellation before mutation) | Confirmed-fixed | `ConditionalMutationError.cancelledBeforeMutation` emitted only when `IOExecutor` cancels before admission (`LiveFileSystem.swift:146-151`; contract `FileSystem.swift:48-49`). |
| P9-4, P11-1 | Confirmed (documentation-level) | README/handoff wording matches current behaviour. |
| P12-1 | Deferred to O1 | Token validation path is executor logic. |
| P13-1, P13-2 (F17) | Fixed per F17 evidence; not independently re-derived | Logic is platform-independent; the recovery loop sits in reducer/runner, outside the I/O lane. FB1-17 adds a source of repeated `.unavailable` that F17's bound must absorb. |
| P14-5 (F18) | Confirmed-fixed | `T2LoadingTests.swift:62-104` gates early progress before EOF across batch sizes. |
| P14-7 (F18) | Confirmed-fixed | F18 counters for root read / access probe / enumeration; the rejected "zero enumerate" oracle is correctly rejected because `DirectoryLoader.swift:24-31` intentionally probes access. |
| P10-3, P15-2 | Out of scope (presentation); input noted | `MetadataReader.swift:33,40` supplies raw directory size for `.package`; FB1-15's key consolidation should keep that field unchanged. |
| R1-2 | Confirmed-fixed | No regression in current source. |
| R1-3, R1-4 | Out of scope | Planner/drop budgets and search; not I/O. |
| fixes-F2 | Confirmed-fixed with new issue | Keep-both/ancestor logic present and tested (`F2SafetyTests.swift:81-137`); per-step full listing is FB1-5. |
| fixes-F3, F5, F9 | Confirmed-fixed | No divergence between the records and current source in this scope. |
| fixes-F7, F13, F16, F19, F23 | Deferred to O1 | Admission, binding, history. |
| fixes-F14 | Not independently re-verified | Monitor recovery bound; see P13 row. |
| T1-001 (`PutBackPlanner`) | Not re-verified | Pure planner; outside the I/O defects above. |

---

## 7. Notes handed to Opus O1 (not duplicated here)

- FB1-11's ancestor rule and FB1-1's kind change both alter what `entry(at:)` returns for
  symlink evidence used by `ForwardEvidence`/`validateExpectedSource`; O1 should assume kinds
  `.alias` on Mac for every symlink until FB1-1 lands.
- FB1-2's `.timedOut` from a *read* inside `perform(_:)` becomes a `StepExecutionFailure` only
  for mutation wrappers; for the pre-mutation `childNames`/`entry` reads it propagates as a
  plain error. O1 should confirm which classification (clean vs. uncertain) that path receives.
- FB1-14's `volumeIdentifier` inconsistency means any evidence equality that includes the whole
  `FileEntry` will spuriously fail between listing-derived and `entry`-derived values.
