# T3 adversarial test findings

DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04.

Only seven new T3-prefixed XCTest files and this report were created. No Sources,
existing tests, Package.swift, scripts, legacy Helm files, network, commits, pushes,
messages, sharing changes or external actions were used.

## Coverage

| File | XCTest methods | Adversarial coverage |
| --- | ---: | --- |
| Tests/HelmCoreTests/T3AccessibilityTests.swift | 25 | fr_FR/ar/de/ja digits, negative and Int.max counts, English singular/plural contract, selection clamping, byte-unit boundaries/overflow scale, independent eight-kind size table, RTL/CJK/combining text, monotonic operation milestones, terminal suppression, reversible identifier distinctions |
| Tests/HelmCoreTests/T3PermissionTests.swift | 24 | Seed 0x7A31; 64 generated original modes per subject/access combination (1,536 scenarios); independent bit-mask oracle, special-bit preservation, whole-mode/row/plan agreement, revert-to-original, recursive intent and reset |
| Tests/HelmCoreTests/T3CancellationTests.swift | 8 | Eight input/collision scenarios; measure checkpoints then inject a distinct error at every checkpoint; assert exact propagation, no extra calls, complete two-phase success and deterministic steps |
| Tests/HelmCoreTests/T3InspectorTests.swift | 15 | Invalid attributes, extension confirmation scoped to draft, lock ordering, original identity, atomic selection rejection, unknown permissions in either order, recursive rejection, 4,096-item deduplicated deterministic plan |
| Tests/HelmCoreTests/T3NavigationTests.swift | 8 | Fifty repeated staged invalidations, both failure paths, inactive failures, root/unmount priority, superseded navigation, 100 activation cycles and retired-watch rejection |
| Tests/HelmFileSystemTests/T3ConditionalMutationTests.swift | 10 | Pre-cancelled copy/move/Trash, same-path replacement for all three mutations, wrong kind/token, 64 competing exclusive copies (exactly one winner), move-away/back identity |
| Tests/HelmFileSystemTests/T3SnapshotWorkerTests.swift | 6 | Empty/single/1,000/100,000 entries, every index and metadata lookup, no second sort, first-wins duplicate metadata, off-main build hook, active and queued cancellation with explicit gates |

Total: **96 XCTest methods**. Generated cases are separate named XCTest methods
where parameter combinations are independently meaningful; loops additionally
exercise seeds, checkpoints and scale. These tests assert concrete outputs and
mutation refusals; empty/no-op implementations cannot satisfy the positive controls.

## Findings and boundaries

No new production defect was established by the 96 T3 tests. Consequently no
T3_RUN_BUGS quarantine was needed. Existing F10/F11 repairs remained green.

The locale tests intentionally verify the current documented contract: locale
digits/grouping with English phrases, English plural selection and English units.
Arabic plural categories, bidi isolation and native VoiceOver are not implemented
claims. Mixed-direction names are checked for preservation, not visual rendering.
No Linux duration is used as proof of macOS responsiveness.

Tests avoid P8-1/P8-2/P9-1/P9-3 behavior under concurrent F13/F14 ownership.
Native conditional mutation remains default-refusing; tests use the atomic
in-memory provider and perform no user-file mutations. Native permission execution,
macOS 14/Xcode compilation, hosted RTL/VoiceOver and Opus review remain outstanding.

## Verification

All Swift commands source /workspace/toolchains/env.sh and use /tmp/build-T3.
Logs are local /tmp artifacts.

- Explicit HelmFileSystem target build (including HelmCore): PASS, zero errors,
  /tmp/T3-build.log.
- Initial complete T3 selection: 96 tests, zero failures/skips,
  /tmp/T3-focused.log.
- Initial full suite: 999 tests, one failure, /tmp/T3-full.log.
  The failure is outside T3 ownership:
  Tests/HelmCoreTests/StateTests/TabReducerTests.swift:180,
  testHiddenSettingsAndMonitorEffects. It sends rootChanged then changed while
  validation is outstanding; the test expects refreshPaths but concurrent F14
  validation priority returns no effect. This is an existing assertion against
  changing P9-1 behavior, not a new T3 bug; T3 neither edits nor quarantines it.
- Initial static checks: 222 Swift source files, zero errors,
  /tmp/T3-static.log. Static checks count production files, not the new XCTest files.
- Final verification follows below.

### Final results

- After strengthening the worker gate to ensure the second request starts while
  the first build is held: **96 T3 tests, 0 failures, 0 skips**;
  /tmp/T3-focused-final.log.
- Final full-suite retry: **999 tests, 1 failure, 0 skips**;
  /tmp/T3-full-final.log. The same existing TabReducerTests assertion at line 180
  fails. No T3 test fails. The F14 owner must reconcile that existing expectation
  with validation priority; changing it is outside T3 ownership and explicitly
  excluded behavior for this lane. Full-suite green is therefore not claimed.
- Final scripts/static_checks.sh: **222 Swift files, 0 errors**;
  /tmp/T3-static-final.log. All eight T3-created files pass whitespace checks.
- Build and test execution used Linux Swift 6.0.3 / Swift 5 language mode.
  Everything remains a draft for Opus after 22:00 Toronto, 2026-11-04.
