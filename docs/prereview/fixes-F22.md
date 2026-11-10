# F22 — P19 handoff freshness

DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04.

## P19-1 disposition

Documentation refreshed through wave 21. Top-level README and handoff entry points
now lead reviewers to the complete Opus/Fable queue: P1–P19, R1, fixes-F1–F21,
then this report, current verification and native integration obligations. F19–F21
are concurrent owner reports, not fixes certified by F22. F12's 877/889-test
snapshots are explicitly historical; K41's actual log confirms the supplied
1,159-test baseline. Overlapping runs are never added together.

MAC_HANDOFF inventories K37 CloudPolicy/Sharing/PathPresentation, K38 Core
OperationHistory/Operations History, K39 Core SearchSessions/Search Sessions,
K40 InspectorSessions and K41 SpringNavigation/Gallery. Source READMEs, APIs and
XCTest assertions support the portable-policy descriptions. F13–F18 corrections
and residual review gaps are included. CONTRACT_INTEGRATION links the additions
and distinguishes host obligations from existing values/adapters. Only status
pointers were appended to the nine authorized module READMEs; concurrent owner
changes were preserved. No Swift, manifest, script or legacy app file was edited.

## Evidence and coverage limits

The baseline ledger is generated from a frozen, committed wave 21 copy and its
passing portable execution log, then normalized to LF and strictly audited. All
565 catalogue IDs remain unique and draft-labelled. Because the generator misses
tests without F/B comments, F22 inspected and supplemented F-050 with
F18PropertiesSizeTests, InspectorSizeProjectionTests and InspectorSessionRegistryTests;
B-066 with the first two; and F-063 with SharingTests. Every added test name must
occur as passed in that exact log. UI F18PropertiesAdapterTests is separately
verified by the portable harness, not attributed to the six-target test run.
These are citation-level records, not acceptance or proof of native functionality.

An initial moving-tree run passed 1,159 tests. A subsequent frozen dirty copy
captured in-progress F20/F21 regression tests: 1,173 tests, 45 failures in ten
cases. Those failures remain recorded, not hidden by the passing baseline. F22
left their files untouched and extracted the committed revision into a separate
local copy to verify the requested wave 21 baseline. The revision, empty baseline
diff identity, full input manifest, logs and hashes are in VERIFICATION.md.
Final F19–F21 fixes require their own full shared-tree run and Opus review.

Native SDK/host acceptance, conditional mutation receipts, safe redo, Inspector
save execution, cloud/share integration and P14-5 producer snapshot construction
bounds remain open. No network/shared-memory fetch, external action, commit or
push was performed. The explicit lane instruction authorizes this report despite
its location outside docs/handoff; no other prereview report was changed.

## Verification

See [VERIFICATION.md](../handoff/VERIFICATION.md) for exact commands, counts and
input/log hashes. Final results: frozen committed baseline **1,159 XCTest tests, zero failures/skips**;
explicit HelmCore build PASS; separate portable UI/App harness **58 tests, zero
failures/skips**. Ledger audit: **565 rows, zero gaps**; states **408 planned,
86 drafted, 71 linux-tested**. All ledger test names passed in the frozen log.
Standalone static: **242 Swift files, zero errors**; scoped diff/link checks PASS.
The dirty snapshot failure above remains open to F20/F21 owners; baseline success
is not evidence that their new regressions pass.
