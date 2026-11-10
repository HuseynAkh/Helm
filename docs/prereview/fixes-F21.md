# F21 — P18 fixes

DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04

All five findings were reverified. The initial regression run was interrupted by
an outside-owned Operations test file disappearing during compilation. After the
required 60-second wait, the unchanged regression suite ran: **5 tests, 26 failing
assertions** (`/tmp/F21-red-retry.log`). Every finding had a failing XCTest before
production edits. No findings were rejected.

| Finding | Disposition and minimal change |
| --- | --- |
| P18-1 | FIXED in the value model: compare validated lexical destination path, kind and objectIdentity, not mutable FileEntry fields. Same-object content/star updates retain hover timing and permit completion; different object identities restore. Missing identities explicitly emit destinationUnverified and restore without committing history. Host/executor evidence wiring is DEFERRED below. |
| P18-2 | FIXED: validate local file URL authority, absolute path and absence of credentials/port/query/fragment before hover loads and drop admission. Cache source admission at initialization. Parent components are additionally refused at this action boundary. Localhost remains supported. |
| P18-3 | FIXED in scoped code: lexical component keys remove empty/dot components but retain literal parent components; never call standardizedFileURL. All constructed presentation URLs have explicit directory hints. Sharing retains the first validated supplied action URL verbatim, including parent spelling. Path segments containing parent components permit copy-text only. Shared ItemID reconciliation is DEFERRED below. |
| P18-4 | FIXED: segment membership compares validated lexical path keys independently of directory hints and localhost; emitted URLs carry the known segment directory hint. |
| P18-5 | FIXED: visibleCellCount derives a bounded, overflow-safe count from geometry and collection bounds independently of imaging budget/prefetch; page movement uses it, with existing one-cell fallback for empty geometry. |

Ten new regression methods cover real temporary symlinks with existing and missing
final components, literal action URL preservation, absent/present directory hints,
localhost and remote authority admission, copied parent spelling/action refusal,
hover deadlines, replacement identities, explicit unverified completion, clipping,
nonfinite/overflow geometry and every requested prefetch/requestLimit combination.

Existing spring tests now carry explicit stable object identities; their changed-
identity cases use actual replacement identities rather than size as a proxy.
Existing sharing assertions now require parent spelling to remain distinct, while
still testing dot-key deduplication. Existing path assertions require explicit
output directory hints. No tests were removed, skipped or weakened.

## Exact work deferred outside F21 ownership

- Executor/native drag host must pass trustworthy destination-directory identity
  evidence from acceptance and successful completion into the request target and
  destination FileEntry.objectIdentity. File-copy output evidence identifies the
  copied child, not its parent directory; it must not be substituted. Route
  destinationUnverified as refusal/restoration, never as committed navigation or
  an instruction to repeat a mutation. Core matching values do not establish
  atomic filesystem identity and are not authorization for an operation.
- The Identity owner must reconcile ItemID's standardizedFileURL-based normalization
  with an explicit lexical versus physical path policy (including macOS `/private`
  spelling), and audit consumers before enabling parent-containing reveal/action
  identities. F21 does not edit ItemID; it refuses such path-segment actions today.
- macOS 14/Xcode compile and behavior review remains pending Opus. Linux checks do
  not certify native sharing, drag execution, filesystem identity or gallery UI.

## Verification

Linux Swift 6.0.3, Swift 5 mode; isolated scratch `/tmp/build-F21`.
HelmCore target build PASS. Focused suite: **56 tests, zero failures, zero skips**
(`/tmp/F21-build.log`, `/tmp/F21-focused.log`). Full suite and mandatory runner
results are recorded below after completion.

Only owned source/test directories and this requested report were authored by F21.
Pre-existing F22 README status pointers were preserved. No old-app, manifest or
script edits; no network, publishing, sharing changes, paid renders, commit or push.

Final mandatory runner: **PASS**, six explicit portable target builds, **1,185
XCTest tests / 0 failures / 0 skips**, Python tests, static checks, UI syntax parse
and report-only coverage; **0 failed checks** (`/tmp/F21-run-all.log`, detailed
`/tmp/build-F21/logs/`). Separately requested static checks: **242 Swift files,
0 errors** (`/tmp/F21-static.log`). Scoped `git diff --check` passes.

The preceding standalone full suite executed 1,185 tests with one outside-owned
wall-clock benchmark failure: FileSystemTests.testHundredThousandEntriesAndCancellation
measured 5.4655 seconds against its 5-second limit (`/tmp/F21-full.log`). The full
mandatory runner repeated all tests and passed that unchanged assertion. No timing
threshold, test skip, or outside-owned workaround was introduced.
