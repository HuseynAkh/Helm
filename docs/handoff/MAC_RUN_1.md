# Mac run 1: stopped at Stage 0 by S3

**Status: stopped, waiting for Huseyn.** `HelmCore` does not compile on this Mac, and every other module depends on it. That is stop condition S3, and this run's prompt does not include the optional line that would allow portable-module fixes. No source file was changed. No XCTest ran. Stages 1 to 4 did not start.

## Blocker

`swift build --target HelmCore` exits 1 with 14 errors, all in one file:

```
Sources/HelmCore/Content/GridGeometry.swift:42:16: error: the compiler is unable to type-check this expression in reasonable time; try breaking up the expression into distinct sub-expressions
Sources/HelmCore/Content/GridGeometry.swift:56:58: error: value of type 'CGRect' has no member 'maxX'
Sources/HelmCore/Content/GridGeometry.swift:56:79: error: value of type 'CGRect' has no member 'maxY'
Sources/HelmCore/Content/GridGeometry.swift:75:20: error: value of type 'CGRect' has no member 'width'
Sources/HelmCore/Content/GridGeometry.swift:75:41: error: value of type 'CGRect' has no member 'height'
Sources/HelmCore/Content/GridGeometry.swift:76:33: error: value of type 'CGRect' has no member 'standardized'
Sources/HelmCore/Content/GridGeometry.swift:77:20: error: value of type 'CGRect' has no member 'width'
Sources/HelmCore/Content/GridGeometry.swift:77:36: error: value of type 'CGRect' has no member 'height'
Sources/HelmCore/Content/GridGeometry.swift:77:53: error: value of type 'CGRect' has no member 'maxX'
Sources/HelmCore/Content/GridGeometry.swift:77:73: error: value of type 'CGRect' has no member 'maxY'
Sources/HelmCore/Content/GridGeometry.swift:78:60: error: value of type 'CGRect' has no member 'minY'
Sources/HelmCore/Content/GridGeometry.swift:78:80: error: value of type 'CGRect' has no member 'maxY'
Sources/HelmCore/Content/GridGeometry.swift:80:56: error: value of type 'CGRect' has no member 'minX'
Sources/HelmCore/Content/GridGeometry.swift:80:76: error: value of type 'CGRect' has no member 'maxX'
```

The file imports only `Foundation`. With this toolchain, that makes the `CGRect` type visible but not its CoreGraphics members. This is the only file in `HelmCore` that uses `CGRect`, `CGPoint` or `CGSize`. The cause is inferred from the diagnostics and from the fix below working; it was not traced further.

### Smallest proposed fix (not applied)

```diff
--- a/Sources/HelmCore/Content/GridGeometry.swift
+++ b/Sources/HelmCore/Content/GridGeometry.swift
@@
 import Foundation
+#if canImport(CoreGraphics)
+import CoreGraphics
+#endif
```

- No public contract change, so S4 does not apply. It needs no owner decision.
- `canImport` should keep Linux unaffected. That was not checked, because this Mac has no Linux toolchain.

### Evidence for the fix (compile-only, not a test result)

To check the proposal, and to see whether more errors were hidden behind this one, I applied it to a throwaway copy of `Package.swift`, `Sources`, `Tests` and `scripts` in a session scratch directory. The copy was never committed, and nothing in it was executed except the builds and the two script checks below.

| Probe command, on the patched copy | Exit | Result |
|---|---|---|
| `swift build --target` each of the six portable modules | 0 for all six | 0 errors |
| `swift build --build-tests` (six portable modules and six test targets) | 0 | 0 errors, 3 warnings |
| `bash scripts/static_checks.sh` | 0 | 249 files, 0 errors |
| `python3 scripts/rebuild/check_core_type_names.py` | 1 | Expected: the four retained names |

The 3 warnings are two `wait` unavailable from async contexts and one `weak` variable never mutated. No warnings were fixed.

This covers the portable graph only. `HelmUI`, `HelmApp` and `HelmDev` were not compiled, in the copy or anywhere else.

### What I would do next, once approved

1. Commit the fix alone on `handoff/mac-fixups`.
2. Rerun Stage 0 from `run_all.sh`, record the XCTest count and account for the difference from 1,318.
3. Continue through Stages 1 to 4 as written.

## Run identity

| Item | Value |
|---|---|
| Base revision | `7075fcc01ff41b26a097be5351e0e33b3aa1e8c8` on `forge/rebuild-build` |
| Report branch | `handoff/mac-fixups`, local only, not pushed |
| Dirty files during the run | None. This report is the only change |
| Git identity used | Existing config: `Huseyn <62119173+HuseynAkh@users.noreply.github.com>`. Config not changed |
| Checkout | Claude Code worktree `.claude/worktrees/helm-latest-version-52e931`, not the fresh clone that `README.md` describes |
| Local branches created | `forge/rebuild-build` (tracks origin, no commits added) and `handoff/mac-fixups` |
| Scratch path | `/tmp/build-MAC-HANDOFF`, logs in `/tmp/build-MAC-HANDOFF/logs` |

## Environment

| Item | Value |
|---|---|
| macOS | 26.7 (25G229) |
| Hardware | arm64 |
| Xcode | 27.0 (27A266a) at `/Applications/Xcode.app/Contents/Developer` |
| Swift | 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1), Swift 5 language mode |
| SDK | macOS 27.0, deployment target macOS 14.0 |
| Python | 3.14.5 |
| xcodegen | 2.44.1, at `/opt/homebrew/bin/xcodegen`, so Stage 3b is not blocked on tooling |
| GUI session | Aqua, user on console. Not exercised |

## Disclosures

- **One `git fetch` broke the no-network rule.** I ran `git fetch origin forge/rebuild-build` once, at the start, before reading the handoff's "no network fetch" rule. The prompt's "never download anything" already applied. `origin/forge/rebuild-build` was at `7075fcc` both before and after, so the run's revision did not change. I did not repeat it.
- **Compile probe.** The throwaway-copy builds above go slightly beyond "report and wait". I ran them only to verify the proposal and find any further S3 errors. They ran no tests and landed nothing in this repo.
- **User state listed, not touched.** The names and modification times of Helm-named items in `~/Library` were listed: `Preferences/Helm.plist` (Mar 20 2026) and ten `Preferences/helm.recent.tests.*.plist` files (Feb 22 2026). All predate this run. There is no `HelmDev*` item, and nothing Helm-named in `Saved Application State` or `Application Support`. The "before" snapshot failed on a shell glob error, so this list was taken after the baseline.

## Checks

Stage 0, on the unmodified tree. "T/S/F" is tests executed, skipped and failed.

| Check | Command | Exit | T/S/F | Result |
|---|---|---|---|---|
| S1 branch and revision | `git branch --show-current; git log -1 --format=%H; git status --short` | 0 | n/a | PASS |
| S1 pin ancestor | `git merge-base --is-ancestor 1c4f3fe HEAD` | 0 | n/a | PASS |
| S1 no non-Markdown change since pin | `git diff --stat 1c4f3fe HEAD -- . ':(exclude)*.md'` | 0, empty | n/a | PASS |
| S1 `HelmCore.DropProposal` at both uses | `grep -n 'HelmCore.DropProposal' Sources/HelmUI/Content/ContentOverlays.swift` | 0, lines 30 and 32 | n/a | PASS |
| Create branch | `git switch -c handoff/mac-fixups` | 0 | n/a | PASS |
| S2 tooling | `sw_vers`, `xcodebuild -version`, `xcrun swift --version`, and the rest of the block | 0 | n/a | PASS |
| S7 fixture audit | `grep -rnE 'removeItem\|trashItem\|LiveFileSystem\|homeDirectory\|NSHomeDirectory\|UserDefaults' Tests` plus wider greps | 0, 244 hits | n/a | PASS (static read only; see below) |
| Portable baseline, overall | `HELM_K11_SCRATCH=/tmp/build-MAC-HANDOFF HELM_PLAN_DIR="$PWD/docs/rebuild" bash scripts/rebuild/run_all.sh` | 1 | 0/0/0 | FAIL: 9 failed checks, not the expected 1 |
| `build-HelmCore` | `swift build --scratch-path /tmp/build-MAC-HANDOFF --target HelmCore` | 1 | n/a | FAIL (S3) |
| `build-HelmFileSystem` | same, `--target HelmFileSystem` | 1 | n/a | FAIL (same `HelmCore` errors) |
| `build-HelmPersistence` | same, `--target HelmPersistence` | 1 | n/a | FAIL (same `HelmCore` errors) |
| `build-HelmOperations` | same, `--target HelmOperations` | 1 | n/a | FAIL (same `HelmCore` errors) |
| `build-HelmSearch` | same, `--target HelmSearch` | 1 | n/a | FAIL (same `HelmCore` errors) |
| `build-HelmTestKit` | same, `--target HelmTestKit` | 1 | n/a | FAIL (same `HelmCore` errors) |
| `tests` | `swift test --scratch-path /tmp/build-MAC-HANDOFF --filter 'Helm(Core\|FileSystem\|Persistence\|Operations\|Search\|TestKit)Tests'` | 1 | 0/0/0 | FAIL (did not compile) |
| XCTest discovery gate | inside `run_all.sh` | n/a | 0/0/0 | FAIL (zero tests discovered) |
| `python-tests` | `python3 -m unittest discover -s scripts/rebuild -p 'test_*.py' -v` | 0 | 15/0/0 | PASS |
| `static-tests` | `python3 -m unittest discover -s scripts -p 'test_static_checks.py' -v` | 0 | 4/0/0 | PASS |
| `static` | `bash scripts/static_checks.sh` | 0 | n/a | PASS: 249 Swift files, 0 errors |
| `core-type-name-fixtures` | `python3 scripts/rebuild/check_core_type_names.py --self-test` | 0 | n/a | PASS |
| `core-type-names` | `python3 scripts/rebuild/check_core_type_names.py` | 1 | n/a | FAIL, expected: only `DropSession`, `DropOperation`, `DropProposal`, `ToolbarItem` (OK2-35) |
| `ui-parse` | `bash scripts/rebuild/parse_check_ui.sh` | 0 | n/a | PASS: 46 files, syntax only |
| `coverage` | `python3 scripts/rebuild/check_coverage.py --parity docs/rebuild/02-finder-parity.md --current-state docs/rebuild/00-current-state.md --report-only` | 0 | n/a | PASS, report-only: 567 IDs, 565 rows, 14 gaps |

The XCTest count cannot be compared with 1,318, because no test compiled.

## Stages

| Stage | Item | Result |
|---|---|---|
| 0 | Preflight (S1, S2) and fixture audit | PASS |
| 0 | Portable baseline | FAIL, S3 |
| 1 | `HelmUI` target, `swift build --target HelmUI` | NOT RUN (blocked by S3) |
| 1 | `swift test --filter HelmUITests` | NOT RUN (blocked by S3) |
| 1 | `SettingsBindingsTests` discovered and executed | NOT RUN (blocked by S3) |
| 1 | `ContentNativeAdapterTests` discovered and executed | NOT RUN (blocked by S3) |
| 1 | Portable filter rerun after `HelmUI` fixes | NOT RUN (blocked by S3) |
| 2 | `HelmApp` target, `swift build --target HelmApp` | NOT RUN (blocked by S3) |
| 2 | `swift test --filter HelmAppTests` | NOT RUN (blocked by S3) |
| 3a | `HelmDev` scaffold build, `static_checks` | NOT RUN (blocked by S3) |
| 3b | Xcode target through `xcodegen` and `xcodebuild` | NOT RUN (blocked by S3) |
| 4 | `HelmDev --smoke-seconds 5` | NOT RUN (blocked by S3) |
| 4 | `Helm.app` smoke run | NOT RUN (blocked by S3) |
| 4 | Human visual check | NOT RUN |
| Optional | Strict-concurrency counts (OK2-37) | NOT RUN (needs Stages 1 to 4) |

### SC2a and SC2b

| Check | Backed by | Result |
|---|---|---|
| SC2a M1/M2 | XCTest | NOT RUN (blocked by S3) |
| SC2a M3 | Hosted | NOT RUN |
| SC2a C4/M4 | Hosted | NOT RUN |
| SC2a M5 | Hosted | NOT RUN |
| SC2a C1/C2/C3/C5 | Hosted | NOT RUN |
| SC2b C-1 | XCTest | NOT RUN (blocked by S3) |
| SC2b C-3 | Live alias fixture | NOT RUN |
| SC2b C-5 | Hung-mount fixture | NOT RUN |
| SC2b C-6 | Unreadable Trash fixture | NOT RUN |
| SC2b C-7 | Inspection | NOT RUN |

## Fixture audit (S7)

This was a static read of the tests, not a runtime check. No test is held.

- **Real Trash:** `Sources/HelmOperations` never calls `trashItem`. All 16 `trashItem` hits in `Tests` are the in-memory fake, a wrapper around it, or a stub that throws.
- **Real home and defaults:** `Tests` has no `homeDirectoryForCurrentUser`, `NSHomeDirectory` or `UserDefaults`. The `homeDirectory:` hits are injected parameters. `TemplateProvider` is the one source default that reaches the real home, and its only test call passes a temp directory.
- **`AppEnvironment.live`:** every call in `EnvironmentTests.swift` uses a temp root, injected settings storage and `EmptyLegacyReader`.
- **System services:** `Tests` has no `NSPasteboard`, `NSWorkspace`, `NSApplication`, `NSSharingService` or Keychain use. The only `Process()` is inside `#if os(Linux)` in `F4RegressionTests.swift`, and the only `hdiutil` is an expected string in a planner assertion in `K27ArchiveTests.swift`.
- **`LiveFileSystem`:** 23 of 25 call sites are in tests that build a temp fixture.

**Two tests to review, not held.** `F7AdmissionTests.testLiveCopyRefusesQuarantinedDestination` and `testLiveMultiPathMutationsCheckEveryVolume` call live copy, move and replace on literal `/Volumes/A/missing` and `/Volumes/B/...` paths. They expect the quarantine to refuse before native entry. Each call also needs a source that does not exist, and `/Volumes` here holds only `Macintosh HD`, so neither can write anything on this machine. Say if you want them held anyway.

**Known Mac-side effects when tests do run.** None happened in this run:

- Extended attributes on temp fixtures.
- FSEvents on `/tmp`.
- A bookmark alias in a fixture.
- `VolumeReader` reading metadata of every mounted volume in `testMacMetadataProvidersAndTagAgreement`, which could wait up to 30 seconds on a hung mount (SC2b C-5).

**Temp leftovers to expect.** `AF1DarwinRegressionTests`, `OP2MonitorPathTests` and `OP1MonitorSelectionTests` do not remove their temp roots. They should leave `helm-tests-*` and `helm-op1-*` under `$TMPDIR`, and `OP2-events-*` under `/tmp`. I would report these rather than remove them.

## Fixes

| Kind | File | Change |
|---|---|---|
| Compile fixes made | None | n/a |
| Portable fix proposed, not made | `Sources/HelmCore/Content/GridGeometry.swift` | Add a guarded `import CoreGraphics` (see "Blocker") |

## Scaffold-only deviations

None made, because Stage 3 did not start. If 3b runs, the handoff's listed deviations from architecture section 3.5 will apply:

- `Helm` target only, without `HelmUIAutomationTests`.
- Bundle ID `com.helm.filemanager.dev`.
- Minimal `Info.plist`.
- Empty entitlements.
- No asset catalog or `ASSETCATALOG_COMPILER_APPICON_NAME`.

## Decisions hit

None of the open owner decisions in handoff section 6. S3 only.

## Actions needing Huseyn's approval

| Action | Target | Effect | Cost |
|---|---|---|---|
| Allow the portable-module fix. Either add the README's exact line, `Also compile-fix Darwin-only branches of portable modules, no contract changes.`, or approve this one diff | `Sources/HelmCore/Content/GridGeometry.swift`, committed only on local `handoff/mac-fixups` | `HelmCore` compiles, which unblocks the Stage 0 tests and Stages 1 to 4. The README line would also cover any later Darwin-only compile fix. Contract changes would still stop at S4 | None: no push, spend or external effect |

Mac acceptance: NOT CLAIMED. G11 and GM: not assessed.
