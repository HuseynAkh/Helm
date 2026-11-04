<!-- DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04 -->
# K30 verification record

Linux Swift 6.0.3, Swift tools 5.9 manifest / Swift 5 language mode. Root package, branch `forge/rebuild-build`; dedicated scratch `/tmp/build-K30`. K30 edits only `docs/handoff/`. No network, commit, push or external action. The worktree changed during these checks: K29 edits production/existing tests and T1 adds tests. A git HEAD hash does not identify those dirty inputs. No Mac SDK compilation, hosted UI test, app launch or Opus gate closure is claimed.

## Fresh K30 checks

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

K30 did not rerun the F4 portable UI/App harness: `Tests/HelmUITests/PortableRunner/run.py` hardcodes `/tmp/build-F4`, and its F4RegressionTests Linux subprocess also hardcodes that scratch path. K30's private-scratch rule prevents using it unchanged. macOS XCTest declaration and commands are in MAC_HANDOFF.md. This is an unverified integration slice, not permission to modify those files.

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

## Final opt-in verification (supersedes the standard-run ledger)

**PASS: 650 XCTest cases, 0 skips, 0 failures**, exit 0. Command: `T1_RUN_BUGS=1 swift test --scratch-path /tmp/build-K30 --filter 'Helm(Core|FileSystem|Persistence|Operations|Search|TestKit)Tests'`. Log: `/tmp/build-K30/logs/opt-in-tests.log`. This explicitly executes the formerly gated Put Back mixed-authority regression. It does not establish native Trash/Put Back behavior.

The final ledger was regenerated with the same command shown above, substituting `--test-log /tmp/build-K30/logs/opt-in-tests.log`; LF normalization and strict audit were repeated. `opt-in-coverage.log` records 565 rows / 0 catalogue-schema-owner gaps. The earlier ledger hash is historical; the current hash follows.

Final ledger states: 89 drafted, 61 linux-tested, 415 planned.

- `/tmp/build-K30/logs/opt-in-tests.log` SHA-256: `fd92f23f8317801ff5df715607e3d39e2adf2997d711fdb56db1d95d3bf3c3aa`
- `/tmp/build-K30/logs/opt-in-coverage.log` SHA-256: `167c270889e38577a62a4a67490b440b2dc71da497ea5e5e0bde464024035e3d`
- `docs/handoff/coverage-ledger.csv` SHA-256: `46440a2f823dcd6e043a6de989a4e334ee34856d36c69c1d6e458d11a1c6c438`
