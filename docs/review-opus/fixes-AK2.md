# DRAFT — AK2 fixes for OK1

Pending Opus compile-correctness and behaviour-preservation review. No commits, network access, publishing, or external actions. Changes are confined to AK2-owned source/tests plus this requested report. The old Helm app is read-only reference.

## Dispositions

| Finding | Disposition | Code and evidence |
| --- | --- | --- |
| OK1-4 | FIXED (library); DEFERRED (host wiring) | `Engine/SearchRootResolver.swift` accepts bookmark and browsable removable-volume roots and returns their stable deduplicated union with Home for `.home`/`.userFolders`. Current-folder and computer scopes remain separate. `testDefaultScopesIncludeInjectedBookmarksAndRemovableVolumes` proves an external bookmark survives composite metadata filtering. Legacy `SpotlightSearchService.swift:154–169` confirms this scope. Host must supply roots. `CONTRACT_INTEGRATION.md` is outside ownership; the updated HelmSearch README and this report supply its correction. |
| OK1-5 SIMPLE | FIXED | Engine emits `.rootNotSearchable` for refused explicit symlink/package roots and `.droppedEntry` for non-child adapter results; both set `truncated`. Tests assert refusal and partial status, including simulated `/private/search` non-child paths. The compatibility fallback delegates to the same engine. |
| OK1-5 JUDGEMENT | DEFERRED | No depth-zero following or Spotlight real-path/lexical-root alias policy change. Actual Darwin `/private` enumeration behavior remains unverified. |
| OK1-6 | FIXED | Engine tolerates `.notFound` for descendants and roots in a multi-root search, preserving other results and reporting `.unreadable` plus truncation. A single distinct missing root remains fatal. Tests cover both `entry(at:)` failure and disappearance at enumeration. `LiveFileSystem.swift` already maps `opendir` and entry errors to `FileSystemError`; no LiveFileSystem edit was necessary. |
| OK1-7 SIMPLE | FIXED | Private tokenizer tokens retain `isLiteral` for any quoted/escaped token; compilation sends these directly to `.name`. Public `tokenize` remains source-compatible. Tests cover fully/partially quoted filter syntax, escaped colons, flag reset, and 500 seeded compile-level literal round trips. Per the requested rule, `tag:"Work Stuff"` is literal; spaced tag filters use typed `.tag("Work Stuff")`. |
| OK1-7 JUDGEMENT | DEFERRED | Unterminated quotes, dangling escapes, partial/unknown filter values and user-facing error wording are unchanged. |
| OK1-13 | FIXED (discovery seam); DEFERRED (host wiring) | `Rank/PreferredRoots.swift` provides async discovery through injected FileSystem, retaining standard roots and visible immediate Home directories except Library. Ranking performs no IO. Tests cover Clients boost, exclusions, deduplication, read errors and cancellation. Legacy `preferredRootPaths` confirms discovery intent. The host must await once per search and inject the result; this lane does not own the host. |
| OK1-18 | FIXED | Engine uses a FIFO array/index walk, with standardized entry URL/path/parent keys computed before sorting. A tight-budget tree test demonstrates siblings are visited before grandchildren; existing delivery-order determinism tests pass. |
| OK1-19 | FIXED (shared validation); DEFERRED (making parser public) | Both CloudActionPlan and SavedSearchOpenPlan route through `Core/Search/LocalFileURLAdmission.swift`, a narrow public wrapper around the existing F24 `LexicalLocalPath`. The parser itself is outside ownership, so it remains internal and unchanged. Tests reject query/fragment/credentials/encoded separators/NUL and accept uppercase LOCALHOST. No duplicate parser was introduced. |
| OK1-20 | FIXED | Parser rejects nonlocal explicit current-folder/Trash roots with `.nonLocalRoot(URL)` before saved-definition acceptance. Engine also validates injected resolver roots before enumeration and metadata boundary filtering. Tests cover remote schemes/hosts and malformed local URLs, plus accepted local spellings. |
| OK1-24 | FIXED | SearchSpecification reuses one POSIX Locale. SearchSessionState preserves the prior batch through nonempty start/refresh until a replacement batch arrives; empty input still clears. Regression covers refresh identity, old-event rejection, replacement, and empty exit; existing Unicode matching tests preserve semantics. Locale reuse is a structural optimization, not a new matching policy. |
| OK1-28 | FIXED | `settled` explicitly fails at its deadline. A continuation gate holds the old terminal producer until the replacement is subscribed and the old stream has terminated; the late terminal attempt is awaited before assertions. Invalid/empty-query tests shut down the driver before returning. The test forces the late-producer ordering; it does not claim to simulate native Spotlight or an internal cleanup suspension (cleanup has no suspension). |
| OK1-31 / OK1-32, search portions | FIXED | Existing SearchEngineTests now assert truncation for refused roots. New tests cover vanished directories and simulated `/private` non-children; CriteriaHardeningTests now checks compiled literals, not only tokenization. |
| Test-quality “tests of dead code” / OK1-23 | FIXED (duplicate traversal); DEFERRED (API deletion) | EnumerationSearchService now delegates to SearchEngine, so its existing tests exercise the real engine. Retained its public API and SearchFallbackPolicy instead of deleting unrelated callers. Its permission test now requires the engine's diagnostic and partial-result behavior. This also ensures OK1-5/6 fixes apply to both entry points. |

## Test-first evidence

- `/tmp/AK2-red.log`: nine new regression tests ran against original behavior: 43 failed assertions/unexpected-error records, covering quoted filters, unsafe scope/definition URLs, cloud admission, skipped roots, vanished directories, BFS budget ordering, and refresh retention.
- `/tmp/AK2-red2.log`: tests for the new resolver injection and preferred-root discovery were written first; compilation failed because the proposed APIs did not exist. After implementing those APIs, all 11 AK2 tests passed (`/tmp/AK2-green2.log`).
- `/tmp/AK2-red3.log`: additional fallback regression failed with missing truncation and uncaught `notFound`; the adapter was then switched to the engine. Non-child and enumeration-disappearance tests passed against the first engine fix.
- `/tmp/AK2-search.log`: full search run found three stale assertions (quoted tag grammar and fallback permission behavior). Updated them alongside the corresponding fixes. `/tmp/AK2-search2.log`: 111 search tests, zero failures.
- An intermediate compile encountered another lane's unfinished AK1 test/API edits. No AK1 files were modified; subsequent verification after more than 60 seconds of independent AK2 work passed that compile stage.

## Final verification

All commands first sourced `/workspace/toolchains/env.sh` and used `/tmp/build-AK2`.

- `swift build --target HelmSearch --scratch-path /tmp/build-AK2`: PASS.
- `swift build --build-tests --scratch-path /tmp/build-AK2`: PASS, zero compile errors (also passed on retry).
- `swift test --scratch-path /tmp/build-AK2 --filter 'HelmSearchTests|AK2SearchCoreRegressionTests|SearchSessionStateTests|CloudPolicyTests'`: **138 tests, zero failures**. This includes 115 search tests and 18 new AK2 regression tests across both targets. Log: `/tmp/AK2-owned-tests.log`.
- `swift test --scratch-path /tmp/build-AK2 --filter 'HelmSearchTests|HelmCoreTests'`: **793 tests, one out-of-lane failure**, unchanged on retry more than 60 seconds later. `Tests/HelmCoreTests/T1DragAdversarialTests.swift:104`, `testDropModifierOverrides`, expects `.alias` but receives nil after the parallel drag lane's default-operation change. That test/file is outside AK2 ownership and was not edited. Logs: `/tmp/AK2-tests-final.log`, `/tmp/AK2-tests-retry.log`. Thus the entire Core target is not green, while all AK2-related tests pass.
- `git diff --check` scoped to AK2 files: PASS.
- SwiftPM reported manifest-cache permission warnings; compilation and linking succeeded. No network dependency fetch was needed.

Created six Swift files plus this report; updated thirteen owned files. No modifications were made to LiveFileSystem, OpenWith, the old app, Package.swift, or other lanes' files.

## Limits and integration notes

All code remains DRAFT. Linux Swift 6.0.3 uses the package's Swift 5 language mode; no macOS/Xcode compile or native behavior run was available. No AppKit, Combine, macros, third-party dependencies or platform-only APIs were added. New public structs retain explicit public initializers.

Owner decisions OK1-2/3/12 and other unassigned findings were not changed. The scope resolver and preferred-root helper require host injection; this is not a working end-to-end Spotlight implementation. Core's internal F24 path parser was not moved or exposed because its directory belongs to another lane.
