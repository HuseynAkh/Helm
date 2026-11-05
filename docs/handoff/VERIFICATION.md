<!-- DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04 -->
# Verification record — DRAFT, NOT FINAL: blockers remain

## Current handoff pin

DRAFT: pending review, 2026-11-05. Reviewed revision: `<HEAD at handoff>` (orchestrator fills after review). Current Linux commands and counts are in [fixes-AK3](../review-opus/fixes-AK3.md). Re-record counts on Mac; 1,198 and the clean-tree statement below describe only the historical F25 snapshot. OWNER ASSIGNMENT PENDING (see OWNER_OPTIONS.md).

AK3 fresh Linux verification, 2026-11-05: `swift build --build-tests --scratch-path /tmp/build-AK3` and all six explicit target builds passed. The six-target XCTest filter completed 1,281 tests, 2 disclosed FileSystem skips, 0 failures. Portable UI/App runner: 60 passed; separate App runner: 14 passed (overlapping, not additive). Python: 15 rebuild + 4 static-check + 2 runner-configuration tests passed. Syntax parse: 43 files, 0 failures. `run_all.sh` exited 1 solely for the four retained Core SDK-name collisions pending owner-approved rename. Static checks: 246 Swift files, 0 errors. Report-only coverage still has 14 gaps (567 catalogue IDs, 565 ledger rows). No Mac compile/runtime evidence. The linked AK3 report preserves the earlier moving-tree step-count failure and incremental-build crash, both absent from the final fresh-build run.

## Historical F25 verification — through wave 24

DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04.
Baseline: `0021ac623e2cb55645ee00fd279992ba0880d0f5` on `forge/rebuild-build`.
Git history records P16–P19 at `30c826b`, F19–F22 at `6400fa5`, then
F23/F24, P20/P21 and T4 at `0021ac6`. The Package/Sources/Tests/scripts diff
against HEAD is empty. F25 changes only top-level README and docs/handoff.

Fresh local execution, Linux Swift 6.0.3, tools 5.9 / Swift 5 mode:

| Check | Result | Evidence |
| --- | --- | --- |
| Explicit HelmCore build | PASS, zero errors | `/tmp/build-F25/logs/build.log` |
| Six portable XCTest target filter | **1,198 executed, zero failures, zero skips**, 51.379 seconds | `/tmp/build-F25/logs/tests.log`; selected suite passed `2026-11-04 21:28:08.732` (log timestamp; no timezone inferred) |
| Strict coverage audit | **565 unique rows, zero gaps**; 408 planned, 84 drafted, 73 linux-tested | `/tmp/build-F25/logs/ledger-audit.log` |
| Ledger evidence audit | All 445 distinct cited test names occur among 1,198 passed cases; all rows retain draft label | `/tmp/F25-evidence.py` |
| Static checks | **242 Swift files, zero errors** | `/tmp/build-F25/logs/static.log` |

The test command compiled the six portable libraries and their test targets.
F25 did not rerun the full orchestration runner or supplemental UI/App harness;
F23/F24's existing runner logs independently report 1,198 tests and zero failed
checks. No test was changed, skipped or disabled by F25. UI/App native targets
remain unconfigured; no SDK type-check, native run or Mac acceptance is claimed.

T4's five serial passes were 1,185 tests each; its later two-worker parallel run
was 1,195 after concurrent additions. Neither count is five serial passes of the
final 1,198-test tree. Historical benchmark sensitivity remains; T4 did not relax
performance thresholds. Do not sum overlapping executions.

### Reproduction and identity

```sh
source /workspace/toolchains/env.sh
swift build --scratch-path /tmp/build-F25 --target HelmCore
swift test --scratch-path /tmp/build-F25 --filter 'Helm(Core|FileSystem|Persistence|Operations|Search|TestKit)Tests'
python3 -B scripts/rebuild/check_coverage.py \
  --parity /workspace/forge/helm-plan/docs/rebuild/02-finder-parity.md \
  --current-state /workspace/forge/helm-plan/docs/rebuild/00-current-state.md \
  --build-plan /workspace/forge/helm-plan/docs/rebuild/03-build-plan.md \
  --generate --test-log /tmp/build-F25/logs/tests.log \
  --ledger docs/handoff/coverage-ledger.csv
# Reapply inspected supplemental attribution and normalize CSV to LF:
python3 /tmp/F25-evidence.py
python3 -B scripts/rebuild/check_coverage.py \
  --parity /workspace/forge/helm-plan/docs/rebuild/02-finder-parity.md \
  --current-state /workspace/forge/helm-plan/docs/rebuild/00-current-state.md \
  --ledger docs/handoff/coverage-ledger.csv
bash scripts/static_checks.sh
```

Supplemental attribution is class-level evidence, not feature acceptance. F-050
adds InspectorReuseRegressionTests to F22's F18/Inspector classes; B-066 retains
F18PropertiesSizeTests/InspectorSizeProjectionTests. F-063 retains SharingTests
and adds F24LexicalPathTests; F-012/F-067 also cite that class. F-059 adds
HistoryAdmissionTests, F23HistorySafetyTests and F23UndoPreparationTests. The
parser-only generator cannot discover these associations without F/B comments.
The exact paths are retained in each row and `/tmp/build-F25/supplemental-attribution.json`.
All other evidence is regenerated from current source comments and the fresh log.
No Mac-passed state is introduced, and unrelated feature gates remain open.

| Artifact | SHA-256 |
| --- | --- |
| `/tmp/build-F25/inputs.json` (tracked Package/Sources/Tests/scripts input hashes) | `fafedbc09873bbcdd9edbeb7457b8a46b5617dc5952991e2061073407685638b` |
| `/tmp/build-F25/logs/tests.log` | `5197e82bda95129590a5c553eda6c92c0e7b452fb81e0989748c92ae5d191b4e` |
| `docs/handoff/coverage-ledger.csv` | `e163a7f3ec4ced935bd0f04eec1af361f53c432e19b254ffd5b6315436536e43` |

The input diff is empty (`/tmp/build-F25/input-diff.patch`); the working tree was
clean at lane start. This binds the fresh checks to the committed code baseline,
with documentation edits only. Local `/tmp` artifacts are not committed; preserve
locally before cleanup. Earlier hashes and counts below are historical snapshots.
[REVIEW_QUEUE.md](REVIEW_QUEUE.md) defines remaining owner and Mac gates.

## Historical F22 verification — through wave 21

DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04.
First read the [complete Opus/Fable queue](REVIEW_QUEUE.md). Linux Swift 6.0.3,
tools 5.9 / Swift 5 mode. F22 changes documentation only; no Swift, manifest,
scripts or legacy app changes, network, commits, pushes or external actions.

- **Historical wave 21 baseline verified:** K41's `/tmp/build-K41/logs/tests.log`
  ends with **1,159 executed, zero failures/skips**, selected suite passed at
  `2026-11-04 20:45:21.850` (log timestamp, no timezone inferred).
  `/tmp/K41-run-all.log` records all six explicit builds and all checks passing.
  Test-log SHA-256: `7aa690321dfe0e8f471c7c05166cf76c2903934d36f095239db0ea1cc5e0f51a`.
  This is historical execution evidence; no frozen K41 source identity is supplied.
- Initial F22 moving-tree suite: **1,159 tests, zero failures/skips**, exit 0,
  `/tmp/build-F22/logs/tests.log`; UI/App harness **58**, zero failures, `ui.log`.
  Concurrent source edits made this unsuitable as a frozen current-source claim.
- **Frozen committed wave 21 suite: 1159 tests, zero failures/skips**, exit 0, `wave21-tests.log`;
  explicit `HelmCore` build PASS, `wave21-build.log`. Test compilation also builds
  all six portable libraries and XCTest targets. Separate frozen UI/App portable
  harness: **58 tests, zero failures/skips**, exit 0, `wave21-ui.log`.
  These overlapping runs are not summed. UI/App portable execution does not
  type-check SwiftUI/AppKit or establish native host behavior.
- Standalone static checks PASS (**242 Swift files, zero errors**, `static.log`); ledger
  strict audit **565 rows, zero gaps**. States: **408 planned,
  86 drafted, 71 linux-tested**. Every row
  retains its draft label. No Mac-passed state or feature acceptance is implied.

### Frozen execution identity

Local read-only verification copy: `/tmp/build-F22/wave21` (Package.swift,
Sources, Tests and scripts); build artifacts: `/tmp/build-F22/wave21-build`.
Recorded base revision: `30c826b1db39bf3613bdcd64abae1735ee49ec8f`.
This copy was extracted from that local Git revision with `git ls-tree`/`git show`,
including every tracked Package/Sources/Tests/scripts file. Its dirty diff is empty;
untracked wave 23 tests and concurrent edits are excluded by revision selection,
not by test filtering or disabled assertions. The manifest identifies all inputs.
This certifies the requested committed baseline, not later F19–F21 fixes.

A separate dirty snapshot `/tmp/build-F22/snapshot` captured unfinished concurrent
work: **1,173 tests, 45 failures**, exit 1 (`frozen-tests.log`); its UI harness
passed 58 tests (`frozen-ui.log`). Failures were in F21RegressionTests (5 cases), InspectorReuseRegressionTests
(4 cases) and SearchSessionDriverTests (1 case); their owners were in progress. No foreign files were edited or tests weakened. This
failed snapshot is retained with `frozen-inputs.json`, `frozen-dirty.patch` and
`frozen-revision.txt`; it is not used to generate the passing baseline ledger.

| Local evidence | SHA-256 |
| --- | --- |
| `/tmp/build-F22/wave21-inputs.json` (committed input files) | `cf19434437158c53b19b9f3a936b44a89eaa09ee344d78307734edb5da60c9dd` |
| `/tmp/build-F22/wave21-dirty.patch` (Package/Sources/Tests/scripts) | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `/tmp/build-F22/logs/wave21-tests.log` | `73828ab03538ed56cd9543edf3a9063347020fb0ab1c6fae5fc543ae977913f4` |
| `/tmp/build-F22/logs/wave21-ui.log` | `429fde57a94c9b9a8fa21799c4f64f57c88ee388977fbe02fe54bb93ebdd5c9d` |
| `docs/handoff/coverage-ledger.csv` | `6502ca1130a3a76edf97aaf0dc3ce8840e5a49e687760b569189df0b1274181e` |

Logs and frozen inputs are local `/tmp` artifacts, not committed deliverables;
preserve them before cleaning the workspace. Re-freeze the full dirty tree and rerun after final fix
lanes for acceptance; these hashes do not certify a later shared worktree.

### Reproduction and coverage attribution

```sh
source /workspace/toolchains/env.sh
swift test --package-path /tmp/build-F22/wave21 --scratch-path /tmp/build-F22/wave21-build --filter 'Helm(Core|FileSystem|Persistence|Operations|Search|TestKit)Tests'
swift build --package-path /tmp/build-F22/wave21 --scratch-path /tmp/build-F22/wave21-build --target HelmCore
HELM_UI_SCRATCH=/tmp/build-F22/wave21-build python3 -B /tmp/build-F22/wave21/Tests/HelmUITests/PortableRunner/run.py
bash scripts/static_checks.sh
python3 -B scripts/rebuild/check_coverage.py \
  --root /tmp/build-F22/wave21 \
  --parity /workspace/forge/helm-plan/docs/rebuild/02-finder-parity.md \
  --current-state /workspace/forge/helm-plan/docs/rebuild/00-current-state.md \
  --build-plan /workspace/forge/helm-plan/docs/rebuild/03-build-plan.md \
  --generate --test-log /tmp/build-F22/logs/wave21-tests.log \
  --ledger /workspace/forge/helm-build/docs/handoff/coverage-ledger.csv
```

Normalize generated CSV to LF. The generator only discovers F/P/B comments and
file/class-level names. F22 additionally inspected these tests, whose files lack
those citation comments, and added their actually passed class methods and paths:

| Ledger row | Supplemental portable test classes |
| --- | --- |
| F-050 | F18PropertiesSizeTests, InspectorSizeProjectionTests, InspectorSessionRegistryTests |
| B-066 | F18PropertiesSizeTests, InspectorSizeProjectionTests |
| F-063 | SharingTests |

Preserve/reapply these audited attributions after generation; the local procedure
is `/tmp/F22-enrich.py`. F18PropertiesAdapterTests has separate UI evidence above,
not fabricated portable-suite passes. All CSV test names are checked against the
frozen portable log. F-050 covers package unknown/partial totals and session tokens;
F-063 covers immutable selection, picker lifecycle and stale callbacks, not delivery.
Strict audit uses the same catalogue and ledger arguments without `--generate`.
Catalogue/schema completeness and citations do not prove every associated feature.

P16–P18/fixes-F19–F21 remain in the first reading list; native SDK compilation,
conditional mutation receipts, safe redo, host integration and P14-5 producer
construction bounds remain review/acceptance obligations. Historical records follow.

## Historical F12 verification — wave 17

DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04.
Linux Swift 6.0.3 / tools 5.9 / Swift 5 mode; isolated scratch `/tmp/build-F12`.
F12 changes handoff documentation, the top-level README and the explicitly requested fixes-F12 report.
All counts below are executions, not declarations. Parallel source changes are
outside F12 ownership; freeze revision plus dirty diff for final Mac acceptance.

- Initial full portable suite: **877 tests, 0 failures, 0 skips**, exit 0,
  `/tmp/build-F12/logs/full-suite.log`. The T1 environment flag was supplied for
  historical compatibility; F5 already removed that test's gate.
- Coverage regenerated from the final runner’s 889-test passing log: **565 rows / 0 gaps**; **411 planned,
  88 drafted, 66 linux-tested**. Logs: `ledger-generate.log`, `ledger-audit.log`
  in the same log directory. Historical K30 counts/hashes below do not describe
  this regenerated CSV. Its increased citation evidence is not feature acceptance.
- Final `run_all.sh`: **PASS, 889 tests, 0 failures, 0 skips; 0 failed checks**.
  All six explicit target builds, 13 Python tooling tests, static checks, 43-file
  UI/App syntax parse and report-only coverage pass. `/tmp/build-F12/run-all.log`
  and `/tmp/build-F12/logs/`. The rise from 877 reflects concurrent source/test
  additions; no source or test was changed by F12.
- Standalone static checks: **222 Swift files, 0 errors**, `final-static.log`.
  Portable harness configuration: **2 tests, PASS**, `ui-configuration.log`.
- Configured portable UI/App harness: **53 tests, 0 failures, 0 skips**, exit 0,
  `ui-app.log`. This exercises worker/adapter/App logic, excluding native SDK tests.
- Documentation checks: all UI inventory paths present, 27 milestone rows,
  Markdown links resolve, 565 unique ledger IDs retain draft labels, and all 291
  named ledger tests passed in the final log. Scoped `git diff --check` passes.

Commands (repository root; no bare swift build):

```sh
source /workspace/toolchains/env.sh
T1_RUN_BUGS=1 swift test --scratch-path /tmp/build-F12 --filter 'Helm(Core|FileSystem|Persistence|Operations|Search|TestKit)Tests'
HELM_K11_SCRATCH=/tmp/build-F12 bash scripts/rebuild/run_all.sh
HELM_UI_SCRATCH=/tmp/build-F12 python3 -B Tests/HelmUITests/PortableRunner/run.py
bash scripts/static_checks.sh
python3 -B scripts/rebuild/check_coverage.py \
  --parity /workspace/forge/helm-plan/docs/rebuild/02-finder-parity.md \
  --current-state /workspace/forge/helm-plan/docs/rebuild/00-current-state.md \
  --build-plan /workspace/forge/helm-plan/docs/rebuild/03-build-plan.md \
  --generate --test-log /tmp/build-F12/logs/tests.log \
  --ledger docs/handoff/coverage-ledger.csv
```

CSV is normalized to LF and audited again with the same catalogue/ledger arguments
without `--generate` or `--test-log`. The ledger's header remains unchanged and all
565 rows retain the DRAFT note. File/class-level citations do not assert every
associated feature; B-009's broad class attribution remains an example of this
limitation. Neither report-only coverage nor UI parsing closes a Mac gate.

## First things to check on the Mac

These are P11's exact C/compile-risk review sites, **not confirmed compile errors**.
**SUPERSEDED by OK2-3:** “No new likely-to-fail SDK line was established by P11.” The DropProposal ambiguity was subsequently identified; the qualifier is present in AK3-start HEAD and working tree. Verify it at handoff. Re-resolve line numbers after
parallel source changes. Use Xcode 16 with macOS 14 deployment and Swift 5 mode.

| P11 site | Required SDK / hosted check |
| --- | --- |
| `Package.swift:27–35` | Mac declarations remain commented. Assign manifest owner; add UI/App/test targets in stages, exclude PortableRunner/LinuxRunner. Do not uncomment the missing Sources/Helm executable template wholesale. |
| `Sources/HelmUI/Content/InlineRenameField.swift:44`, `:72`, `:80`, `:98` | NSViewRepresentable/NSTextFieldDelegate witnesses and isolation, selectors, subclass overrides; real field-editor focus/IME lifecycle. Native tests are excluded on Linux. |
| `Sources/HelmUI/Sheets/BatchRenameSheet.swift:8`, `:58`, `:63` | MainActor worker access from SwiftUI task/disappearance closures, cancellation and hosted dismissal under a large selection. Worker tests alone do not type-check view closures. |
| `Sources/HelmUI/Content/ColumnBrowserView.swift:38`, `:58` | macOS 14 two-argument onChange and AppKit current-event access in the view builder; these APIs are not alleged unavailable. |
| `Sources/HelmUI/Toolbar/ToolbarCustomizationView.swift:33` | String Transferable drag/drop overload inference and hosted behavior. |
| `Sources/HelmApp/AppStoreContracts.swift:39` | MainActor persistence protocol witnesses under Apple Foundation annotations. App portable sources already compile on Linux; native SDK annotations remain unverified. |

Also prioritize live executor capability UI (copy/move/Trash refusal), per-window
journal ownership, WindowStore/DirectoryEffectRunner lifetime and one authoritative
persistent store per document. See MAC_HANDOFF for the complete platform inventory.

## Historical K30 record

Linux Swift 6.0.3, Swift tools 5.9 manifest / Swift 5 language mode. Root package, branch `forge/rebuild-build`; dedicated scratch `/tmp/build-K30`. K30 edits only `docs/handoff/`. No network, commit, push or external action. The worktree changed during these checks: K29 edits production/existing tests and T1 adds tests. A git HEAD hash does not identify those dirty inputs. No Mac SDK compilation, hosted UI test, app launch or Opus gate closure is claimed.

## Historical K30 checks

| Check | Result and evidence |
|---|---|
| Initial six explicit target builds | PASS, exit 0 each; `/tmp/build-K30/logs/build-<Module>.log`, modules HelmCore, HelmFileSystem, HelmPersistence, HelmOperations, HelmSearch, HelmTestKit. |
| Initial portable XCTest selection | PASS, **530 executed, 2 skipped, 0 failures**; `/tmp/build-K30/logs/tests.log`. This predates K29's new contracts and T1 files and is not a pass for later edits. |
| Six builds after K29 edits appeared | PASS, exit 0 each; `/tmp/build-K30/logs/current-build-<Module>.log`. |
| First test attempt after K29/T1 changes | FAIL to compile; `/tmp/build-K30/logs/current-tests.log`. T1ContentAdversarialTests still called old column push API and had ambiguous `.infinity`; K30 left it untouched, waited 60 seconds and retried. |
| Static checks | PASS, 196 production Swift files, 0 errors at initial refresh; `/tmp/build-K30/logs/static.log`. Lexical checks, not compiler proof. |
| UI/App parse | PASS, 42 Swift files, 0 parse failures; `/tmp/build-K30/logs/parse.log`. No SDK typechecking or runtime evidence. |
| Python tooling fixtures | PASS, 13 tests; `/tmp/build-K30/logs/python.log`. |

The initial skips were `F1NestedRenameTests.testNestedSourcesMustBeRefusedBeforeMutation` and `F1ColumnGenerationTests.testReturningToSameDirectoryMustRejectOldReply`. Their skip guards were subsequently removed by K29 alongside overlap validation and request tokens. Historical F1 deferral reports remain valid as history, not a description of the latest draft. See the final-run addendum below before interpreting current acceptance.

Commands actually used (from the repository root):

```bash
source /workspace/toolchains/env.sh
for module in HelmCore HelmFileSystem HelmPersistence HelmOperations HelmSearch HelmTestKit; do
  swift build --scratch-path /tmp/build-K30 --target "$module"
done
swift test --scratch-path /tmp/build-K30 --filter 'Helm(Core|FileSystem|Persistence|Operations|Search|TestKit)Tests'
bash scripts/static_checks.sh
bash scripts/rebuild/parse_check_ui.sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts/rebuild -p 'test_*.py' -v
```

Actual executions redirected output to the logs above and stopped the build loop on failure. The coverage generator supports `--generate`, `--build-plan` and `--test-log`; no script edits were needed. CSV output is normalized from generated CRLF to LF so `git diff --check` can pass. Schema and row content remain unchanged by normalization.

## Historical results, not additional tests

| Record | Reported evidence | Limitation |
|---|---|---|
| `docs/handoff/CONTRACT_INTEGRATION.md` (K23) | 397 XCTest, 0 skips/failures | Earlier contracts snapshot; K29 later appended its integration notes independently. |
| `docs/prereview/fixes-F1.md` | 529 XCTest, 2 explicit deferred skips, 0 failures | Before K29 public-contract changes. |
| `docs/prereview/fixes-F2.md` | 530 XCTest, 2 skips, 0 failures; 16 new F2 tests | Full tree undo remains conservatively refused. |
| `docs/prereview/fixes-F3.md` | 530 XCTest, 2 skips, 0 failures on final retry | Earlier failures/crash documented there; cause not conclusively proven. |
| `docs/prereview/fixes-F4.md` | 492 baseline; 520 final portable tests, 2 skips; supplemental 50 UI/App portable tests, 0 failures | These overlapping runs must not be summed. UI/App targets remain undeclared; SDK-only tests excluded from Linux harness. |

At the K30 snapshot, K30 did not rerun the F4 portable UI/App harness: `Tests/HelmUITests/PortableRunner/run.py` then hardcoded `/tmp/build-F4`, and its F4RegressionTests Linux subprocess also hardcoded that scratch path. K30's private-scratch rule prevents using it unchanged. macOS XCTest declaration and commands are in MAC_HANDOFF.md. F5 subsequently fixed both paths to require HELM_UI_SCRATCH; the current configured recipe is below. The K30 limitation is historical.

## Coverage interpretation

`coverage-ledger.csv` inventories 565 catalogue definitions: 72 F, 390 P and 103 B. The generator reads comment/test-name citations and attributes passed cases at file/class granularity. It does not prove a cited behavior was asserted, nor execute a feature. A class with skipped/failed cases contributes no successful-log evidence. The schema intentionally has no Mac-passed state; no row closes a Mac gate. P0/P1 ownership is a plan assignment, not delivery.

Do not use an old successful log to certify K29/T1 edits. Final ledger evidence policy and exact counts are recorded below. F-033/F-058 and all mandatory acceptance rows retain their explicit behavior/gate review obligations. `--report-only` is not a completeness gate; strict audit checks schema/catalogue/owners, not finished functionality.

## Remaining validation

Apple SDK branches and all HelmUI/HelmApp source inventory are listed in MAC_HANDOFF.md. Missing native host/executable, Mac target activation, SDK compile classes, per-window journal and complete tree evidence are needed changes elsewhere. Existing SwiftPM user-cache and unhandled-README warnings remain; no manifest changes were made. Concurrency diagnostics, real Finder interoperability, permissions, native monitoring, launch/session acceptance, performance/soak and all Opus gates are NOT RUN by K30.

## Evidence identity

Repository HEAD: `8787479022d5c92e9bfba1591ba7d77e2902f765` (does not capture parallel dirty edits).

- `Package.swift` SHA-256: `50ee83aa912c68f0ffdf02572ffe0c5912eac0a11a5c532e2bb9fdf2c95e6a80`
- `/tmp/build-K30/logs/tests.log` SHA-256: `67423d0563f7a48384df1ac81135393226260c05211a4bfaa77ae1dcd0e8eb63`
- `/tmp/build-K30/logs/current-tests.log` SHA-256: `efdadc6d0c537acd84020b70325cd76a3f0859c6155ebf872d6f84275d308c5c`
- `/workspace/forge/helm-plan/docs/rebuild/00-current-state.md` SHA-256: `2bda1324433e5adf8a2cab91d4b3ca43830776e1b8f4e87512455dbfb8ed521e`
- `/workspace/forge/helm-plan/docs/rebuild/00b-opus-review.md` SHA-256: `6c4253b9befa714b7b2beadb4bac7a612d3016ab4efd95cf4c75278f71dae9e1`
- `/workspace/forge/helm-plan/docs/rebuild/01-architecture.md` SHA-256: `6bdc2396b2c0bad1c4166f92d57122d4a4f14358c2241d56866f88aa5ffcc79b`
- `/workspace/forge/helm-plan/docs/rebuild/review-01-architecture.md` SHA-256: `9835041cff5c7deccd47503042039a43b2b2d3707368ab18a6151f53f048c12d`
- `/workspace/forge/helm-plan/docs/rebuild/02-finder-parity.md` SHA-256: `6139522dc7f08f3434430fd5b2d9f4b2c497adc032d6c6f66f39bd794606276e`
- `/workspace/forge/helm-plan/docs/rebuild/03-build-plan.md` SHA-256: `33f56c3dd649d2087d379f2da59f7f4ab88f3f587b0972bec801be2d451d5647`
- `/workspace/forge/helm-plan/docs/rebuild/review-03-astra-selfcheck.md` SHA-256: `8e78de298a0f6b914d047416c4923dcf0a4ee783b22143b41c7fd0ec4bd4c1c3`

## Moving-tree retry evidence

The 60-second retry compiled and executed **647 tests, 0 skips, 3 assertion failures in 2 cases**, exit 1: `/tmp/build-K30/logs/retry-tests.log`. Failed cases: `T1SearchAdversarialTests.testEngineShuffledCreationDeterministic` and `K29UndoSafetyTests.testMovedDirectoryWithEditedDescendantRefusesUndoBeforeAnyMutation`. Neither source/test is K30-owned; no assertions were changed or suppressed. The removed F1 skips ran as tests in this attempt. A subsequent check, if any, is recorded below rather than erasing this failed run.

[The R1 review](../prereview/R1.md) appeared during K30 work and adds residual quarantine/fallback-cancellation findings plus confirmation of the fixed-scratch UI test issue. These remain review inputs, not K30 repairs or approval. K30's table now includes them.

## Final K30 result

**PASS with one explicitly skipped open defect:** `/tmp/build-K30/logs/final-tests.log`, exit 0, **648 XCTest cases: 647 passed, 1 skipped, 0 failures**. The skipped case is `T1ArchiveVolumeAdversarialTests.testPutBackMixedAuthorityOriginsFailClosedRegardlessOfOrder` (T1-001: mixed local/remote origins depend on record order), in `Tests/HelmFileSystemTests/T1ArchiveVolumeAdversarialTests.swift`. This defect is not accepted or counted as a passing regression. The previous two F1 skips now execute. T1 replaced the earlier creation-order search fixture with seeded delivery against the same underlying metadata; K29's directory-undo case now passes. K30 changed neither test nor production code.

Final `bash scripts/static_checks.sh`: **196 Swift files, 0 errors** (`final-static.log`). Final UI/App syntax parse: **42 files, 0 failures** (`final-parse.log`). Markdown destination checks, complete HelmUI file inventory, exactly 27 milestone rows, and scoped `git diff --check -- docs/handoff` pass. Static/source counts are snapshots and do not count test declarations as passing tests.

Ledger regenerated with the actual supported script command:

```bash
python3 scripts/rebuild/check_coverage.py \
  --parity /workspace/forge/helm-plan/docs/rebuild/02-finder-parity.md \
  --current-state /workspace/forge/helm-plan/docs/rebuild/00-current-state.md \
  --build-plan /workspace/forge/helm-plan/docs/rebuild/03-build-plan.md \
  --generate --test-log /tmp/build-K30/logs/final-tests.log \
  --ledger docs/handoff/coverage-ledger.csv
```

Strict audit: **565 catalogue IDs, 565 rows, 0 gaps**, exit 0 (`final-coverage.log`). This is the final evidence source, replacing the initial 530-test ledger. CSV lines were normalized to LF after generation; no script was modified.

Final states: **89 drafted**, **61 linux-tested**, **415 planned**. No Mac acceptance is inferred.

- `/tmp/build-K30/logs/final-tests.log` SHA-256: `135b98082d699f790068134f136313e7135e80e6d5710dd255a9818ae64b96fa`
- `/tmp/build-K30/logs/final-static.log` SHA-256: `b40d3b4b4892a37c4dfc3ec93a7230718b2dee3ad110eec7cec7c505189d581c`
- `/tmp/build-K30/logs/final-parse.log` SHA-256: `7a2f1cce62add107165edf7cd60031698c7add57aa7460b8d004eddbf2ee341f`
- `/tmp/build-K30/logs/final-coverage.log` SHA-256: `167c270889e38577a62a4a67490b440b2dc71da497ea5e5e0bde464024035e3d`
- `docs/handoff/coverage-ledger.csv` SHA-256: `46440a2f823dcd6e043a6de989a4e334ee34856d36c69c1d6e458d11a1c6c438`

Local logs under `/tmp` are not repository artifacts. Preserve them with the handoff locally if needed; no upload is authorized. Parallel source changes after this run require another revision-scoped verification.


K29 appended `CONTRACT_INTEGRATION.md#k29` during final checks and added a PutBackPlanner origin-validation fix. K30 preserved that concurrent edit, updated its own table, and ran the opt-in T1 regression through another full suite rather than treating the existing skip as validation. The result is recorded below. The K23 397-test result remains historical.

## Historical K30 opt-in verification (superseded by F12 ledger)

**PASS: 650 XCTest cases, 0 skips, 0 failures**, exit 0. Command: `T1_RUN_BUGS=1 swift test --scratch-path /tmp/build-K30 --filter 'Helm(Core|FileSystem|Persistence|Operations|Search|TestKit)Tests'`. Log: `/tmp/build-K30/logs/opt-in-tests.log`. This explicitly executes the formerly gated Put Back mixed-authority regression. It does not establish native Trash/Put Back behavior.

The final ledger was regenerated with the same command shown above, substituting `--test-log /tmp/build-K30/logs/opt-in-tests.log`; LF normalization and strict audit were repeated. `opt-in-coverage.log` records 565 rows / 0 catalogue-schema-owner gaps. The earlier ledger hash is historical; the current hash follows.

Final ledger states: 89 drafted, 61 linux-tested, 415 planned.

- `/tmp/build-K30/logs/opt-in-tests.log` SHA-256: `fd92f23f8317801ff5df715607e3d39e2adf2997d711fdb56db1d95d3bf3c3aa`
- `/tmp/build-K30/logs/opt-in-coverage.log` SHA-256: `167c270889e38577a62a4a67490b440b2dc71da497ea5e5e0bde464024035e3d`
- `docs/handoff/coverage-ledger.csv` SHA-256: `46440a2f823dcd6e043a6de989a4e334ee34856d36c69c1d6e458d11a1c6c438`

## Historical F12 final evidence identity

These hashes supersede historical K30 ledger hashes above. Local logs remain in
`/tmp/build-F12`; no upload is authorized. Parallel dirty source files are not
identified by HEAD alone; final Opus review must freeze the complete inputs.

- `/tmp/build-F12/logs/tests.log` SHA-256: `50fd97c84f7fa6f67dedb6a793c893e70c7de354aec9c4b937f52e542deaab08`
- `/tmp/build-F12/logs/ui-app.log` SHA-256: `125a01b3b7bb07db27815fa5471a22d554c9be8ea8f040e495fedefc16677dec`
- `/tmp/build-F12/run-all.log` SHA-256: `d79b880729753b1af541e52c005ea77e721452d6365ad7b22d08564d71ad1267`
- `docs/handoff/coverage-ledger.csv` SHA-256: `b755bafce667fd3c450d77e7b57736d09f7579e48dbc34181d8e93c350d9d3c5`
