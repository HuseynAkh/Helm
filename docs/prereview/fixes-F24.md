<!-- DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04 -->
# F24 — P21 lexical path corrections

Both P21 findings were reverified with failing XCTest assertions before source
changes. No finding was rejected. Scope is four existing source files under
Core PathPresentation, Sharing and SpringNavigation, one new F24-prefixed test
file, and this report. No existing tests, manifest, scripts or legacy app files
were edited by F24. Other lanes' concurrent changes remain theirs.

## P21-1 — FIXED (draft)

`LexicalLocalPath` now admits a URL with one fallible parse of URLComponents'
percentEncodedPath. Authority/decorations and absolute path are checked together.
It splits literal separators, decodes each component exactly once and rejects
failed UTF-8 decoding, decoded NUL and embedded slash. Literal percent names,
including `%2F` and `%00`, remain valid when correctly escaped as `%252F` and
`%2500`. Decoded dot components retain the existing removal policy; parent
components remain literal and are refused for spring navigation and non-copy
breadcrumb actions. No filesystem lookup or symlink resolution is added.

PathPresentation consumes admitted components for ancestry and explicitly hints
directory construction. Its public nonthrowing standalone segment initializer
preserves an invalid input URL verbatim instead of manufacturing a different local
address; invalid inputs still cannot enter a projection or produce an intent.
Sharing uses this same parser and retains the first admitted action URL verbatim.
Spring checks both sources and targets with the same admission rules.

## P21-2 — FIXED (draft)

Selection deduplication and breadcrumb membership use arrays of component UTF-8
bytes; common ancestry uses UTF-8 element comparison. Display strings remain
unchanged. Spring's same-target check uses the same byte key alongside its existing
kind/object-identity checks. NFC/NFD and case spellings are not implicitly merged.
No public contract or global ItemID equality semantics changed.

## Regression evidence

`Tests/HelmCoreTests/PathPresentationTests/F24LexicalPathTests.swift` adds six
unconditional XCTest methods covering uppercase/lowercase encoded slash, NUL,
invalid UTF-8, literal percent names, encoded dots/parents, spaces, non-ASCII
round trips, NFC/NFD sharing and membership, byte-distinct common ancestry,
and spring load/drop refusal for cross-spelling callbacks. These tests only
construct values and intents; no sharing, navigation or filesystem mutation runs.

- Before fix: 6 tests, 43 failing assertions, zero unexpected failures
  (`/tmp/F24-red.log`). This reproduces both findings, not merely a compile error.
- After fix: 6 tests, zero failures/skips (`/tmp/F24-green.log`).
- Final verification results are recorded below.

## Deferred outside ownership

The previously reported wider `ItemID` normalization remains DEFERRED. Its owner
must define filesystem-aware identity and reconcile selection/reveal/drop identity
consumers before replacing the current standardized-path/String representation.
This scoped fix does not claim to fix that wider contract. Native host adapters
must still revalidate targets and obtain owner approval for actual external actions.
macOS 14/Xcode compilation and behavior acceptance remain pending Opus review
after 22:00 Toronto on 2026-11-04; Linux verification is not Mac acceptance.
No network, sending, deletion, sharing changes, paid work, commit or push occurred.

## Final verification

- Linux Swift 6.0.3, Swift 5 language mode, isolated scratch `/tmp/build-F24`.
- `swift build --target HelmCore --scratch-path /tmp/build-F24`: PASS
  (`/tmp/F24-build.log`).
- Full six-target portable XCTest filter: **1,198 tests, 0 failures, 0 skips**
  (`/tmp/F24-full.log`). Concurrent F23/T4 work was included in the shared tree;
  no unrelated test/source corrections were made by F24.
- Standalone `bash scripts/static_checks.sh`: **242 Swift files, 0 errors**
  (`/tmp/F24-static.log`). Scoped `git diff --check`: PASS.
- `HELM_K11_SCRATCH=/tmp/build-F24 bash scripts/rebuild/run_all.sh`: PASS,
  six explicit portable target builds, **1,198 tests / 0 failures / 0 skips**,
  Python checks, static checks, UI syntax parse and report-only coverage;
  **0 failed checks**. Summary `/tmp/F24-run-all.log`; detailed logs
  `/tmp/build-F24/logs/`. UI parse does not type-check against the macOS SDK.
