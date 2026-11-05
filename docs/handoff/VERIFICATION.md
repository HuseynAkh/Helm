<!-- DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04 -->
# Verification record — F12 current, K30 history

## Current F12 verification — wave 17

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
No new likely-to-fail SDK line was established by P11. Re-resolve line numbers after
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

## F12 final evidence identity

These hashes supersede historical K30 ledger hashes above. Local logs remain in
`/tmp/build-F12`; no upload is authorized. Parallel dirty source files are not
identified by HEAD alone; final Opus review must freeze the complete inputs.

- `/tmp/build-F12/logs/tests.log` SHA-256: `50fd97c84f7fa6f67dedb6a793c893e70c7de354aec9c4b937f52e542deaab08`
- `/tmp/build-F12/logs/ui-app.log` SHA-256: `125a01b3b7bb07db27815fa5471a22d554c9be8ea8f040e495fedefc16677dec`
- `/tmp/build-F12/run-all.log` SHA-256: `d79b880729753b1af541e52c005ea77e721452d6365ad7b22d08564d71ad1267`
- `docs/handoff/coverage-ledger.csv` SHA-256: `b755bafce667fd3c450d77e7b57736d09f7579e48dbc34181d8e93c350d9d3c5`
