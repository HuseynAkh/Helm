DRAFT: pending review, 2026-11-05

# Owner decisions note (OP1)

For Huseyn. Every recommendation here is proposed, owner decision pending. Except for the explicitly disclosed FB1-11 symlink allowlist already implemented by OP1, these decisions remain unimplemented. No option authorizes a push, a release or any other external action. `OWNER_OPTIONS.md` (lane AK3) has fuller wording on paths and hosting; this note refers to it and does not replace it.

First Mac run: options A of OK2-2 and OK2-4 are a scaffold-only working assumption. Every decision below remains open.

Nothing in this rebuild has ever compiled on macOS, and pass OP1 did not compile anything on any platform (see `docs/review-opus/fixes-OP1.md`). Treat claims about Apple behaviour here as unconfirmed until a Mac run.

## Decide these first

| Order | Decide | Why it comes first |
|---|---|---|
| 1 | Q7 (how code reaches the Mac) and Q8 (release bar) | Without Q7 there is no Mac run at all. Q8 sets the scope of everything after it, and G0 stays open until it is answered. |
| 2 | OK2-2 (paths), rename (OK2-35), OK2-1 (host lane) | These allow the first HelmUI compile and the first launch. |
| 3 | O1-1 / FB1-6 (native mutation) | Largest product gap: on a real Mac the app can only create items. |
| 4 | OK2-8, OK2-6, OK2-9, OK2-10 | Contracts the first host commit depends on. |
| 5 | OK1-2, OK1-3, FB2-9, FB2-10 | Needed before the host wires those features. |
| 6 | OK1-12, Q9, FB1-11, OK1-5, OK1-11 and the rulings table | Limited to one feature each; safe defaults exist. |

## Operations

### O1-1 / FB1-6: live copy, move and Trash are refused

**Problem.** On `LiveFileSystem`, every `.copy`, `.move` and `.trash` step ends in `verificationUnavailable`. Only create-file and create-folder run, and even their undo refuses, because undo is a Trash step. The contract says "refuse if you cannot guarantee this", and Darwin has no atomic compare-identity-and-rename, so no live conformer can ever comply as worded. All tests of conditional mutation run on the in-memory fake.

**Options.**
- **A. Bounded-race contract.** Compare, admit exclusively, mutate, verify the output, report anything unconfirmed as needing reconciliation. Implement `LiveFileSystem.mutate` with `O_NOFOLLOW` + `fstat`, `fcopyfile` into `O_CREAT | O_EXCL`, `renamex_np(RENAME_EXCL)` with `ENOTSUP` as refusal, and `trashItem` + `lstat`, returning a typed receipt. Copy, move, Trash and undo work. A small race window remains between check and rename, and it is disclosed rather than hidden. Needs Mac tests on APFS and SMB.
- **B. Keep the strict contract.** Safest on paper, but the app stays create-only and cannot pass GM.
- **C. Plain native calls with plan-time checks only.** Simplest, and closest to legacy. It loses detection of a file replaced after planning, and requires rewriting the safety tests that pin this.

**Recommendation: A.**

**Blocked until decided:** every forward copy, move and Trash on a real Mac, undo of New File and New Folder, F-052, F-053, F-055, and milestone M22.

## Persistence and state

### FB2-9: one malformed legacy key stops the whole migration

**Problem.** A truncated `helm.recentAccessRecords` stops `com.helm.starredFiles` and `helm.bookmarks` migrating too, on every launch. The user sees no stars, bookmarks or recents, and the legacy data stays intact but unreachable from the app. Spec line `01-architecture.md:1514` can be read either way, and `MigrationTests.swift:48-64` pins "writes nothing", so I did not change it.

**Options.**
- **A. Per-key.** Valid keys migrate; the bad key stays untouched, reports once, and keeps migration incomplete so it retries. Requires changing the pinned test on your ruling.
- **B. All-or-nothing with a recovery action.** Keeps the test, but needs new UI to skip a bad key.
- **C. Leave as is.** No work; a single bad key costs all three collections.

**Recommendation: A.**

**Blocked until decided:** first-launch stars, bookmarks and recents if any one legacy key is damaged. A clean machine is unaffected.

### FB2-10: expanding a folder in list view never loads its children

**Problem.** The reducer records the expansion, but no effect asks anyone to load children, and no lane owns this. The disclosure triangle does nothing visible.

**Options.**
- **A. New Core effect and action** to load children, handled by `DirectoryEffectRunner`, cancelled on collapse, with stale-generation checks. Contract change across Core and FileSystem, and needs an assigned lane.
- **B. Host-owned loading.** Less contract change, but splits ownership and bypasses the stale-result checks.
- **C. Ship without disclosure.** Hide the triangle and record F-037 as a deviation.

**Recommendation: A**, assigned before list-view work starts.

**Blocked until decided:** F-037.

### OK2-9: any store load failure prevents launch

**Problem.** An unsupported schema or an unreadable `recent.json` makes `AppEnvironment.live` throw, so one optional document blocks all file browsing. All seven JSON documents are now composed: bookmarks, stars, recent, session, trash-origins, tag-catalog and view-options. Any throwing load among these can block launch. Decodable corruption recovery in the last two is a separate read-only state: OP2 permits quit because edits are refused, preserves original bytes/backups, and still reports genuine save failures (OK2-29 remains open).

**Options** (detail in `OWNER_OPTIONS.md`).
- **A.** Non-throwing construction plus explicit load; failed stores read-only and shown to the user. Needs persistence API changes and recovery UI.
- **B.** Fail-fast with a recovery screen. Less work, but no browsing until repaired.
- **C.** Defer; remains a known launch blocker.

**Recommendation: A.** No option allows overwriting an unsupported document.

**Blocked until decided:** `AppEnvironment.live`, store construction APIs, recovery UI.

## App host and package

### OK2-1: there is no launchable app

**Problem.** No entry point, `AppDelegate`, window controller or wiring of the store exists. Fixing every compile error would still leave nothing to launch.

**Options.**
- **A.** Dedicated host lane after the contract decisions, built in reviewable steps.
- **B.** The Mac integration owner builds it after compile triage. Fewer handoffs, longer lane.
- **C.** Defer. Library-only prototype; every M10–M25 hosted gate stays NOT RUN.

**Recommendation: A.**

**Blocked until decided:** opening a folder in the app, and every hosted acceptance row.

### OK2-2: HelmUI and HelmApp are undeclared and nobody may declare them

**Problem.** `swift build --target HelmUI` fails with no such target, and no lane is allowed to edit the manifest. No SwiftUI or AppKit line has ever been type-checked.

**Options.**
- **A.** One Mac integration owner for `Package.swift`, `Sources/HelmUI`, `Sources/HelmApp` and their test targets. Keeps target membership and compile fixes together.
- **B.** Manifest with an integrator, each source/test pair with a named owner. Parallel, but needs explicit handoffs.
- **C.** Stay unassigned. Inventory only; native targets stay blocked.

**Recommendation: A.**

**Blocked until decided:** the first native compile, and therefore OK2-11, OK2-12 and OK2-13.

### OK2-8: `AppEnvironment` cannot supply the planned `WindowDependencies`

**Problem.** The architecture wants concrete stores plus services `AppEnvironment` lacks. The current protocols live in HelmApp, which HelmUI cannot name because HelmApp depends on HelmUI.

**Options.**
- **A.** Move the store protocols to HelmPersistence and have `WindowDependencies` take them. Keeps memory fakes; needs cross-module review.
- **B.** Use concrete stores and redesign test injection. Less abstraction, less fake flexibility.
- **C.** Defer. No host can claim integration.

**Recommendation: A.**

**Blocked until decided:** the first host commit.

### OK2-6: one journal is shared across all windows

**Problem.** Move a file in window A, press Cmd+Z in window B, and A's move is reversed.

**Options.**
- **A.** One app-lifetime coordinator with per-window histories and active-window menu routing.
- **B.** Distinct journals injected per window. Extra lifecycle work.
- **C.** Keep the shared journal as a disclosed limitation and block multi-window undo acceptance.

**Recommendation: A**, settled together with O1-1, since the ticket and journal contract is shared.

**Blocked until decided:** journal composition in `AppEnvironment`, and multi-window undo acceptance.

### OK2-10: external open differs from the architecture

**Problem.** With Helm running, each "Open With Helm" on a folder opens a new window, and opening a document reveals it rather than launching it. `LaunchTests.swift:20-21` locks this in.

**Options.**
- **A.** Follow the architecture after launch: folders navigate the key window, files launch. Cold launch still creates the first window. Routing and tests change together.
- **B.** Approve current behaviour as a product difference and revise the acceptance rows.
- **C.** Postpone, keep the tests, and do not claim F-002 parity.

**Recommendation: A.** Any real external launch during testing still needs your approval of that exact action.

**Blocked until decided:** `LaunchRouter.route` and its tests.

### Rename of the four colliding public Core types (OK1-1 gate / OK2-35)

**Problem.** `DropSession`, `DropOperation`, `DropProposal` and `ToolbarItem` share names with SwiftUI types, and the guard in `run_all.sh` stays red by design until this is ruled on. `HelmCore.DropProposal` is already qualified at `ContentOverlays.swift:30,32`. A grep finds 53 occurrences across 16 files, so the change is mechanical. `DropSession` may also collide on a newer SDK; that is the reviewer's recollection, unconfirmed.

**Options.**
- **A. Rename** to `FileDropSession`, `FileDropOperation`, `FileDropProposal`, `HelmToolbarItem` across Core, HelmUI and tests. Guard goes green, and review Fix 16 is met.
- **B. Qualify at call sites** and exempt the four from the guard. Smallest change; leaves the ambiguity for every future file, and departs from Fix 16.
- **C. Defer.** `run_all.sh` keeps exiting 1, which hides any new failure behind a known one.

**Recommendation: A**, in one small lane while no other lane is editing Core.

**Blocked until decided:** a green `run_all.sh`.

## Search and media

### OK1-3: no working search path

**Problem.** The planned Spotlight files do not exist, and four shapes need adapting to one another. The finite snapshot seam cannot carry live `NSMetadataQuery` updates, and tab state has no field for truncation or disclosure.

**Options.**
- **A. Streaming seam.** `updates(for:)` as an async stream, the composite emits a stream, the driver adapts it, tab state gains disclosure, and the Spotlight files get built. Live updates are preserved; three contracts change.
- **B. Keep the one-shot seam** and re-run on demand. Less churn, but F-046 live updates are lost.
- **C. Enumeration only for the first version.** No new seam; slower and narrower, recorded as deviations on F-044 to F-046.

**Recommendation: A.**

**Blocked until decided:** any end-to-end search on macOS.

### OK1-5: explicit symlink and package roots

**Problem.** Searching from a symlinked folder, or inside a package, skips that root. AK2 made this a disclosure rather than a silent empty result, so results are now honest but still missing. Tests pin not following (`testSkippedExplicitRootsAreDisclosed`, `testLegacyFallbackAlsoDisclosesSkippedAndVanishedRoots`, `SearchEngineTests.swift:112-113,157-159`), so I did not change it.

**Options.**
- **A.** Follow the root at depth 0 for the current folder only, and compare Spotlight results against both the lexical and resolved root. Changes the pinned tests.
- **B.** Keep not following, with the disclosure. No work; search from those folders stays empty.

**Recommendation: A**, with the OK1-3 work.

**Blocked until decided:** search from symlinked folders and from Show Package Contents.

### OK1-2: `.unknown` means both "unread" and "ordinary local file"

**Problem.** A normal file on APFS reads as `.unknown`, so the documented plan suppresses its thumbnail and refuses open and preview. Nothing calls `CloudActionPlan` yet, so this breaks nothing today, but a host built to the docs would break F-007, F-048 and F-049.

**Options.**
- **A.** Add `.notCloud`; on a true `.unknown`, let the host attempt explicit open. A failed metadata read does not stop a file opening.
- **B.** Add `.notCloud` but keep refusing on `.unknown`. Stricter; a transient read failure makes a file unopenable.
- **C.** Map non-iCloud files to `.local`. Smallest, but every row would announce "available offline". The review rejects it.

**Recommendation: A.** `CloudPolicyTests.swift:18,20,37-44` change with it.

**Blocked until decided:** host wiring of thumbnails, open and preview through `CloudActionPlan`.

### OK1-12: no limit on in-flight thumbnail work

**Problem.** A grid with 500 cells starts 500 producers at once.

**Options.**
- **A.** `maxConcurrent` (default 4) with a pending queue, visible cells first. Cancelling a queued key removes it without starting it.
- **B.** The same limit with plain FIFO. Simpler; prefetched cells can take slots from visible ones until they are cancelled.
- **C.** No limit in the coordinator; leave it to the host. Nothing enforces it.

**Recommendation: A.**

**Blocked until decided:** P-054 acceptance on large folders. Nothing else depends on it.

### OK1-11: custom folder icons

**Problem.** The per-kind part of icon policy is a simple fix. Custom folder icons need a cheap signal, or they are lost.

**Options.**
- **A.** Accept the loss for the first version, and run a Mac spike on FinderInfo and `Icon\r` as signals.
- **B.** File-specific lookup for every folder. Correct but costly on large folders.

**Recommendation: A.**

**Blocked until decided:** only custom folder icons.

## Safety residual

### FB1-11: implemented OS-managed symlink allowlist; ratification pending

**Current code.** `OperationExecutor.osManagedAncestorSymlinks` already admits exactly `/tmp`, `/var` and `/etc` when their entry kind is `.symlinkToDirectory`. OP1 implemented this reversible exception so normal macOS temporary/variable/configuration paths are not all refused as symlink ancestors. This is implemented code, not an approved owner ruling. OP2 leaves its semantics unchanged.

**Dropped check.** The O1 alternative required each allowlisted link to resolve to `/private/<same>` (for example `/tmp` to `/private/tmp`). Execution currently checks only the exact path and entry kind, not the resolved target. The `FileSystem` protocol has no link-target read seam; the implementation instead relies on these being OS-managed paths. That assumption, including protection on the owner's system, is unverified and does not replace the required target check. Adding it needs an agreed filesystem/evidence contract; the monitor's new realpath helper does not validate mutation ancestors.

**Exact owner decision owed.** Choose one:
- **Keep** the implemented exact-path/kind allowlist and explicitly accept its unchecked OS-managed-target assumption.
- **Tighten** it to require resolution to `/private/<same>`, assigning the new read/evidence seam and execution revalidation tests.
- **Revert** the exception and again refuse these symlinked ancestors, accepting unavailable operations beneath them until the broader identity contract is settled.

**Separate residual.** User-created symlink ancestors still refuse operations; `RecoveryTests.testSymlinkAncestorCannotRedirectMutation` pins this. Supporting them needs plan-time resolved evidence and execution validation with O1-1. Nothing here authorizes relaxing that refusal.

## Plan questions

### Q7: how the code reaches your Mac

**Options.**
- **A.** You approve one exact action: push a private branch `rebuild/handoff` to `HuseynAkh/Helm`. Fixes come back through normal git.
- **B.** A `git bundle` file you copy yourself. Nothing goes on a remote; fixes come back by bundle too.

In both, the Mac session commits only to `handoff/mac-fixups` and pushes nothing without separate approval.

**Recommendation: A**, or B if you would rather keep this off GitHub for now. I have not pushed or bundled anything.

**Blocked until decided:** all Mac verification, which is the largest unknown in the project.

### Q8: what must be true before you switch to Helm

**Options.**
- **A. Staged bar.** GM requires all 72 preserved features, all Critical and High bugs and the reconciled P0 set. P1 is finished after handoff; P2 is backlog.
- **B. All 296 reconciled P0/P1 rows before first use.** Roughly 18–28k LOC accepted in one Mac session.

**Recommendation: A.** The review also warns that one Mac session may not be enough even with the staged bar.

**Blocked until decided:** G0 closure and the coverage-ledger dispositions.

### Q9: typing a file's path and pressing Return

**Options.**
- **A.** Reveal and select it in its folder. Nothing launches.
- **B.** Open it.
- **C.** Keep today's error.

**Recommendation: A.**

**Blocked until decided:** F-015 and P-391 acceptance. Low cost if wrong.

## Rulings that need only a yes or no

| Item | Question | Recommendation | Blocked |
|---|---|---|---|
| OK2-12 | Does clicking away from a rename commit or cancel it? | Follow legacy behaviour once the hosted spike has recorded it | Rename end-of-editing hook |
| OK2-22 | Which Settings panes: the code's, or F-065's General, Appearance, Behavior and Advanced? | Align the code to F-065 | `SettingsPane` layout |
| OK2-23 | Default search scope? | Current folder in a directory, everywhere in Recent | `SearchBarModel` default |
| OK2-27 | Cold open with only invalid URLs: zero windows today. What should happen? | Report the rejection, then apply normal launch precedence | `LaunchRouter` cold path |
| OK2-29 | Disk full at quit: allow discarding unsaved documents? | Add "Quit Anyway" that names the unsaved documents | `QuitCoordinator` |
| OK2-30 | Escape during a pending rename drops a later error. How should it surface? | Host reports the outcome through the operations panel | Rename completion path |
