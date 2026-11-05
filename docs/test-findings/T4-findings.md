# T4 flaky-test hunt

DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04

## Scope and changes

Only Tests/ and this report are authored. No Sources/, manifest, scripts, legacy
Helm/, network, commits, pushes or external actions. Linux Swift 6.0.3, Swift 5
language mode, isolated scratch `/tmp/build-T4`.

- `HelmSearchTests/SearchEngineTests.swift` and `SearchListingFixture.swift`:
  replace 20 ms cancellation sleeps and fake five-second latency with suspended
  enumeration streams and explicit entry expectations. Cancellation now demonstrably
  occurs during enumeration; both CancellationError and stream diagnostics remain
  asserted. Normal fixture enumeration still uses its existing implementation.
- `HelmFileSystemTests/ExecutorAndRegistryTests.swift`: hold timed-out work behind
  a semaphore released in defer, instead of racing 30 ms timeout against 150 ms
  sleep. Use a one-second executor timeout to allow independent-volume admission
  under load. Preserve timeout, quarantine and isolation assertions. Self-cancel
  before executor admission; parent cancellation could previously race native body
  admission, where cancellation intentionally does not interrupt work (B-107).
  Add an explicit assertion that the precancelled body never enters.
- `HelmPersistenceTests/JSONFileStoreTests.swift`: observe the automatic write
  with a five-second monotonic deadline and 10 ms polling, replacing the fixed
  700 ms sleep. Do not flush to satisfy the test: automatic debounce still must
  write the exact latest payload, and write-failure assertions are unchanged.
- `HelmSearchTests/SessionTests/SearchSessionDriverTests.swift`: replace arbitrary
  1,000 scheduler-yield limits with five-second monotonic state-observation bounds.
  All identity, completion, disclosure and error assertions remain unchanged.

## Audit disposition

Reviewed sleeps, deadlines, Date comparisons, timeouts, shared paths, mutable
statics and ordering assumptions throughout Tests/. Raw inventories are
`/tmp/T4-static-audit.txt` and `/tmp/T4-ordering-audit.txt`.

The existing F21/P12 enumeration benchmark and F8 BoundaryTests findings are
already documented in their owner reports; this report does not claim new product
findings or a resolution of those historical findings. BoundaryTests currently
contains no timing waits. The five-second enumeration performance assertion is
retained without relaxation. It can still be affected by host contention; repeat
passes cannot establish a load-independent performance guarantee. The other
15-second geometry/selection budgets are also retained.

Remaining waits have distinct purposes: F5's 200 ms sleep spaces a queued timeout
scenario, but correctness still depends on the returned timeout/quarantine results;
removing it cannot prove queue registration because no registration observation
seam exists. The registry's ten yields do not synchronize teardown; its assertions
check the surviving watch and explicit stopAll. Existing one/two-second expectation
watchdogs and 0.1/0.2-second executor timers were audited and retained unless a
failure is observed. UI's condition deadline is a bounded release watchdog, not a
sleep; its tests are outside the root manifest's Linux targets. Date() fixture
metadata and diagnostic timings do not order asynchronous work; the SystemHelmClock
comparison intentionally exercises wall time. No shared writable temp fixture path
was identified: disk helpers append UUIDs; fixed /tmp paths are value-only inputs.
Existing reversed/seeded search fixtures cover listing-order independence.

No product race was reproduced, so no T4_RUN_BUGS quarantine or skip was added.

## Verification

Baseline: 1,185 tests, zero failures/skips, 60.983 seconds; `/tmp/T4-baseline.log`.
Focused changed tests: 29 tests, zero failures/skips; `/tmp/T4-focused.log`.
Static checks: 242 Swift files, zero errors; `/tmp/T4-static.log`.
Scoped `git diff --check -- Tests` passes. Final repeated-run evidence follows.

Five consecutive full runs on the final test tree passed. Each uses:

```sh
source /workspace/toolchains/env.sh
swift test --scratch-path /tmp/build-T4 --filter 'HelmCoreTests|HelmFileSystemTests|HelmPersistenceTests|HelmOperationsTests|HelmSearchTests|HelmTestKitTests'
```

| Run | Tests | Failures/skips | Seconds | Log |
| --- | ---: | --- | ---: | --- |
| 1 | 1185 | 0 / 0 | 51.872 | `/tmp/T4-full-1.log` |
| 2 | 1185 | 0 / 0 | 51.153 | `/tmp/T4-full-2.log` |
| 3 | 1185 | 0 / 0 | 51.672 | `/tmp/T4-full-3.log` |
| 4 | 1185 | 0 / 0 | 52.618 | `/tmp/T4-full-4.log` |
| 5 | 1185 | 0 / 0 | 60.097 | `/tmp/T4-full-5.log` |

Slow-test inventory (at least one second; maximum across baseline, focused and
five full runs; full individual timings remain in the logs):

| Test | Maximum seconds |
| --- | ---: |
| `K31LoadingTests.testHundredThousandEntriesHaveBoundedProgressAndCompleteFinalSnapshot` | 15.386 |
| `FileSystemTests.testHundredThousandEntriesAndCancellation` | 13.310 |
| `F2SafetyTests.testHundredThousandSiblingPlanAndJournal` | 13.286 |
| `T2LoadingTests.testHundredThousandDuplicateUpdates` | 8.598 |
| `K15FileSystemAdversarialTests.testHugeFolderBatchIntegrity` | 1.724 |
| `T1ContentAdversarialTests.testSelectionHundredThousandRange` | 1.187 |
| `ExecutorAndRegistryTests.testExecutorCancellationTimeoutAndIsolation` | 1.002 |

There were no failing tests in baseline, focused or the five full runs.
The root manifest executes six portable test targets; macOS UI/App targets are
not declared there. No macOS SDK/type-check or hosted behavior claim is made.

Parallel verification also passed (exit 0):

```sh
swift test --scratch-path /tmp/build-T4 --parallel --num-workers 2 --filter 'HelmCoreTests|HelmFileSystemTests|HelmPersistenceTests|HelmOperationsTests|HelmSearchTests|HelmTestKitTests'
```

Log: `/tmp/T4-parallel.log`, 1,195 discovered/executed cases, no reported failures
or skips. Two workers bound local resource contention while exercising parallel
isolation. SwiftPM's successful parallel output does not include individual case
durations, so the slow-test table above covers serial/focused logs only.

Concurrent F23/F24 source/test additions appeared after the five serial runs and
were included in the parallel rebuild; this explains the increase from 1,185 to
1,195. T4 did not author or modify those files. The five serial passes establish
consecutive success for the unchanged T4 edits against the tree available during
those runs, not five serial certifications of the later F23/F24 work.

Final static recheck: 242 Swift files, zero errors
(`/tmp/T4-static-final.log`); scoped whitespace/diff check passes. Build output
contains pre-existing SwiftPM cache-access/unhandled-file warnings and existing
Swift warnings, but no compile errors. No test assertion was removed, no performance
threshold relaxed, and no quarantine added. Remaining review limits are host-load
sensitivity of existing performance budgets and macOS/Opus acceptance.
