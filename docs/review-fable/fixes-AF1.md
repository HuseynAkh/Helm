# DRAFT: pending review, 2026-11-04

AF1 only. Production changes require Opus compile-correctness and behaviour-preservation review.
No network, publication, commit, or push. Old `Helm/`, Loading, Core, Operations and Persistence
sources are unchanged by this lane. New disk fixtures are retained.

## Finding dispositions

| Finding | Disposition | Evidence and limits |
| --- | --- | --- |
| FB1-1 | FIXED (Mac unverified) | `MetadataReader` keeps lstat symlink classification authoritative over `isAliasFile`. Guarded Mac test covers directory/file/dangling links, no-follow classification, and a real bookmark-file alias. Existing symlink canaries are unchanged. |
| FB1-7 | FIXED in owned loader; DEFERRED in Loading | `Virtual/DirectoryLoader` admits explicit package navigation without changing `FileEntry.isDirectoryLike`. Linux test loads and caches package contents using the metadata seam. `Loading/DirectoryLoadPipeline.swift` has the same guard, but ownership explicitly excludes Loading; that lane must apply and test the equivalent change. The review's example `/Safari.app/Contents` already has a normal directory root; the defect is loading `/Safari.app` itself. |
| FB1-9 | FIXED | Failed starts remove only the matching registry generation, deliver unavailable, finish all listeners, and stop the failed monitor. Removal happens before the stop await. A subsequent subscriber creates a fresh monitor; regression test verifies termination, count and event delivery. |
| FB1-12 | FIXED | Cocoa 3328 and native ENOTSUP/EXDEV map to unsupported; Cocoa 642 and EROFS to permissionDenied; Cocoa 640 and ENOSPC to stable `.other("No space")`. Uses platform constants, avoiding Darwin/Linux errno-number confusion. No new public enum case or cross-module exhaustive-switch changes. Table tests cover wrapped errors and preserve conservative EEXIST semantics. ENOTEMPTY/ENAMETOOLONG retain existing `.other` diagnostics; no extra public error categories were requested by the proposed exact fix. |
| FB1-13 | FIXED (Mac unverified) | All four Darwin xattr operations use XATTR_NOFOLLOW. Mac canary tests read/list/write/remove on a symlink and preservation of the target's user tags; a volume's explicit refusal to tag links is accepted only when the target remains unchanged. Linux xattr semantics are outside this Darwin finding and unchanged. |
| FB1-14 | FIXED | `entry(at:)` uses the injected metadata reader once, resolves symlink target kind as before, supplies the no-follow device identifier with the listing's fallback, and maps pre-read failures. Linux regression verifies seam invocation count and matching listing/single-entry volume evidence. |
| FB1-17 | FIXED | Polling remembers the last failure, suppresses identical repetitions (including root loss), and emits one rescan on recovery even if the successful listing is unchanged. Regression covers permission failure, different failure, missing root, and two recoveries. |
| FB1-18 | FIXED | Case-insensitive fake keys use `FileNameComparison.key`; case-sensitive behaviour remains intact. Unicode tests include sharp s, sigma, canonical accents, dotted/dotless-I case and titlecase digraphs. Live EEXIST remains authoritative because the shared planner oracle is not a claim of exact APFS semantics. |

## Test-quality dispositions

| Item | Disposition | Evidence and limits |
| --- | --- | --- |
| T-1 | FIXED | Named fallback test now watches a TempDirectory with LiveFileSystem, asserts a valid mechanism on every platform and polling on Linux. Mac branch creates a child and requires changed/rescan with a bounded timeout, then stops the monitor. |
| T-2 | FIXED (Mac unverified) | New Mac test checks native case-sensitivity resource metadata, local-file cloud unknown, root mount presence, and resource-value/xattr tag-name agreement. REJECTED the proposed unconditional case-insensitive expectation: APFS can be case-sensitive, so the test compares with that volume's native resource value. |
| T-3 | FIXED by FB1-1; canaries retained | Existing `FileSystemTests` symlink assertions were not weakened. |
| T-6 | FIXED for filesystem contract; DEFERRED executor mapping | New live conditional-copy refusal test verifies unsupported plus unchanged source bytes and absent destination. Operations mapping coverage cannot be added in this lane's owned tests and FB1-11 remains a separate judgement issue. |
| T-7 | DEFERRED production correction; canary added | A missing direct child under canonical `/private/tmp` maps to nil on this Linux host too (observed failing assertion before disposition). The responsible production correction is FB1-3, explicitly excluded. Canary skips on Linux only when the defect reproduces; Mac marks it as an expected failure. This is known missing behaviour, not a passing fix claim. |
| T-9 | FIXED for seam counts | Regression checks exactly one injected metadata call per listed child and one for a single-entry lookup. It does not claim to measure native syscall count or solve FB1-15. |
| T-4, T-5, T-8 | DEFERRED | Depend on excluded FB1-11/FB1-2/FB1-4 decisions or files outside ownership. |

All JUDGEMENT findings FB1-2..6, 8, 10, 11, 15, 16 and 19 remain outside this change.
The T-7 skip/expected failure must be removed when the owner-authorized FB1-3 fix lands.
No claim of Darwin execution or SDK type-checking is made.

## Verification

Toolchain: sourced `/workspace/toolchains/env.sh`; Swift 6.0.3 on Linux, package Swift 5 mode.
Scratch directory: `/tmp/build-AF1`.

Initial red run: six tests executed, 23 failed assertions across five tests in
`/tmp/AF1-red.log`. The package test initially passed because FB1-14 bypassed its injected
package metadata; it requires an isolated red run after that seam fix (recorded below).
First focused green run: six tests, zero failures (`/tmp/AF1-green.log`).
Mac-only tests were written before their source fixes but cannot execute on this host.

Isolated package red run: restored only the old directory guard after fixing the metadata
seam; the package test failed with `other("Not a directory")` (one test, one failure).
Restored the package fix before final validation. Log: `/tmp/AF1-package-red.log`.

Final commands and results:

- `swift build --build-tests --scratch-path /tmp/build-AF1`: PASS, zero compiler errors.
  Only sandbox user-cache/manifest-cache warnings. Log: `/tmp/AF1-build.log`.
- `swift test --scratch-path /tmp/build-AF1 --filter HelmFileSystemTests`: PASS,
  213 tests executed, one explicit FB1-3/T-7 skip, zero failures, 37.255 seconds.
  Log: `/tmp/AF1-filesystem.log`.
- `swift test --scratch-path /tmp/build-AF1 --filter HelmOperationsTests`: PASS,
  167 tests, zero failures, 9.010 seconds. Log: `/tmp/AF1-operations.log`.
- `git diff --check`: PASS.

Created `AF1RegressionTests.swift`, `AF1DarwinRegressionTests.swift`, and this report;
modified eight owned production files and the review-named `MonitorAndCacheTests.swift`.
The three Mac-only tests and native fallback-event branch are not included in the Linux
execution count. Opus must review and run them on macOS 14/Xcode before acceptance.
