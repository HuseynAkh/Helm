<!-- DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04 -->
# Opus / Fable review queue — F25, through wave 24

Start no earlier than **22:00 America/Toronto, 2026-11-04**. Keep **at most two
Claude runs active at once**, including Opus and Fable combined. This is a proposed
owner/orchestrator queue, not a scheduled job or permission to launch agents.
Time alone approves no draft. Baseline: `0021ac6`; no Mac acceptance is claimed.

## Reading list

Read the local architecture plus review fixes first: `/workspace/forge/helm-plan/docs/rebuild/01-architecture.md`
and `review-01-architecture.md` (review wins; especially Fixes 1/5/8/9), then
`00-current-state.md` and `00b-opus-review.md`. No network/shared-memory fetch.

1. Prereviews: [P1](../prereview/P1.md), [P2](../prereview/P2.md), [P3](../prereview/P3.md), [P4](../prereview/P4.md), [P5](../prereview/P5.md), [P6](../prereview/P6.md), [P7](../prereview/P7.md), [P8](../prereview/P8.md), [P9](../prereview/P9.md), [P10](../prereview/P10.md), [P11](../prereview/P11.md), [P12](../prereview/P12.md), [P13](../prereview/P13.md), [P14](../prereview/P14.md), [P15](../prereview/P15.md), [P16](../prereview/P16.md), [P17](../prereview/P17.md), [P18](../prereview/P18.md), [P19](../prereview/P19.md), [P20](../prereview/P20.md), [P21](../prereview/P21.md), [R1](../prereview/R1.md).
2. Fix dispositions: [fixes-F1](../prereview/fixes-F1.md), [fixes-F2](../prereview/fixes-F2.md), [fixes-F3](../prereview/fixes-F3.md), [fixes-F4](../prereview/fixes-F4.md), [fixes-F5](../prereview/fixes-F5.md), [fixes-F6](../prereview/fixes-F6.md), [fixes-F7](../prereview/fixes-F7.md), [fixes-F8](../prereview/fixes-F8.md), [fixes-F9](../prereview/fixes-F9.md), [fixes-F10](../prereview/fixes-F10.md), [fixes-F11](../prereview/fixes-F11.md), [fixes-F12](../prereview/fixes-F12.md), [fixes-F13](../prereview/fixes-F13.md), [fixes-F14](../prereview/fixes-F14.md), [fixes-F15](../prereview/fixes-F15.md), [fixes-F16](../prereview/fixes-F16.md), [fixes-F17](../prereview/fixes-F17.md), [fixes-F18](../prereview/fixes-F18.md), [fixes-F19](../prereview/fixes-F19.md), [fixes-F20](../prereview/fixes-F20.md), [fixes-F21](../prereview/fixes-F21.md), [fixes-F22](../prereview/fixes-F22.md), [fixes-F23](../prereview/fixes-F23.md), [fixes-F24](../prereview/fixes-F24.md).
3. Every test-findings report: [K13-findings](../test-findings/K13-findings.md), [K15-findings](../test-findings/K15-findings.md), [T1-findings](../test-findings/T1-findings.md), [T2-findings](../test-findings/T2-findings.md), [T3-findings](../test-findings/T3-findings.md), [T4-findings](../test-findings/T4-findings.md).
4. [Mac inventory](MAC_HANDOFF.md), [verification](VERIFICATION.md),
   [contracts](CONTRACT_INTEGRATION.md), [ledger](coverage-ledger.csv) and
   [F25 documentation disposition](fixes-F25.md).

Read each original finding with its latest fix and current source. P16–P19 are
round-five reviews; P20/P21 follow up F19–F21. F23/F24 address their new findings
as drafts, not accepted closures. F22 is the earlier handoff snapshot. T4's five
serial passes cover 1,185 tests; wave-24 final F23/F24 logs cover 1,198, zero skips.

## Priority queue from 22:00 (maximum two active Claude runs)

| Priority | Reviewer / work | Dependency and exit evidence |
| --- | --- | --- |
| 1, slot A at 22:00 | Opus: contracts and operation safety. Review architecture fixes, P2/P6/P8/P12/P16/P20, F7/F9/F13/F16/F19/F23; inspect whole-plan binding, abort/bind ordering, journal evidence and refusal semantics. | Record each finding's disposition against the exact revision; native receipt/tree-undo limits stay explicit. No source ownership implied. |
| 2, slot B at 22:00 | Fable: Mac environment, manifest/source inventory and SDK compile triage using staged instructions in MAC_HANDOFF. | Read-only inventory first; manifest/host edits require assigned ownership. Record SDK/toolchain/target evidence; absent targets are gaps, not passing tests. |
| 3, next free slot | Opus: sessions and lexical identity. P17/P18/P21 with F20/F21/F24; search termination, Inspector reuse/enrichment costs, UTF-8 paths, spring evidence and gallery paging. | Check changed behavior against audits and regressions; distinguish scoped path fixes from deferred ItemID policy. |
| 4, next free slot | Opus: remaining P1–P21/R1 findings and fixes; emphasize P13/P14/P15/P19, monitor/load ordering, persistence, UI/App composition, T1–T4 and K13/K15 findings. | Complete finding matrix; review tests for behavior preservation and retained performance limits. Do not count citation coverage as acceptance. |
| 5, after relevant reviews and target assignment | Fable: staged Mac XCTest and hosted fixture validation, native adapters, focus/IME/undo routing, query teardown, monitoring and Inspector publication. | Use approved fixtures; stop before deletion/sending/sharing or other unapproved effects. Record unavailable/held checks explicitly. |
| 6, after all prior evidence | Opus: reconcile review records, Mac failures and owner decisions; recommend readiness or remaining blockers. | No release, commit, push or publication. The orchestrator owns commits; Huseyn owns exact external-action approval. |

Queued work has no promised duration. Reuse freed slots; never start a third run.
Independent review can overlap, but edits must have disjoint explicit ownership.

## Deferred owner decisions

- Define global lexical versus filesystem identity for ItemID (including symlinks,
  parent components, Unicode/case and macOS `/private` spelling); F24 intentionally
  does not change this contract.
- Decide native conditional mutation/atomic completion receipt design, durable
  journal and Trash origins, complete descendant evidence, reconciliation, history
  retention and safe redo. Current live executor copy/move/Trash remain refused.
- Assign manifest/native host/executable ownership and composition: text-first undo,
  history admission, search envelope projection/producer teardown, Inspector reads
  and saves, spring destination-directory evidence/commit routing, gallery rendering,
  cloud/share execution and one authoritative persistent store per document.
- Resolve architecture owner questions Q1/Q10/Q6 and scope decisions in the review,
  including F-033/F-058 dispositions; no documentation refresh answers them.
- Set acceptance for P14-5 snapshot-construction/100k geometric work bounds. F18's
  event-count tests and P21's isolated Inspector timing probe do not close that gate.
- Confirm Mac migration domains/data counts and fixture permissions. No real-data
  deletion, sharing change, sending, default changes or external action follows
  from a test plan; stop and report when exact approval is absent.

## Mac validation sequence

1. Freeze revision plus dirty diff/input identity. Read current Package.swift and
   local plan; select macOS 14 deployment and Swift 5 language mode with Xcode.
2. Run six explicit portable target builds, then the six-target XCTest filter in
   MAC_HANDOFF. Record counts/failures/skips, not Swift Testing's zero-test footer.
3. Assigned manifest owner enables HelmUI/HelmApp/test targets in stages, excluding
   portable runner directories; supply missing executable/host separately. Never
   uncomment the missing executable template wholesale or use bare swift build.
4. Type-check Apple branches: Foundation resource keys/setters, Darwin xattrs,
   FSEvents/vnode lifetimes, Trash/alias bridging, SwiftUI isolation and AppKit
   delegate/field editor APIs. Linux UI syntax parsing is not SDK verification.
5. After fixture inspection/approval, run explicit HelmUITests/HelmAppTests and
   hosted focus/IME, operation-history, search teardown, Inspector stale-token,
   monitor and path Unicode/encoding cases. Validate destination-directory identity
   for spring completion and capability UI for refused live operations.
6. Record native performance/soak and behavior against each audit ID; retain
   unavailable or prohibited checks as open. Run static checks and scoped whitespace
   checks. Hand review evidence to the orchestrator; do not commit/push/publish.
