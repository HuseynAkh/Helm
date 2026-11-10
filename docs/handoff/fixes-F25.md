<!-- DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04 -->
# F25 — final pre-review handoff refresh

Documentation only, through `0021ac6` (wave 24). Updated top-level README,
handoff README, MAC_HANDOFF, VERIFICATION, CONTRACT_INTEGRATION, REVIEW_QUEUE
and the 565-row coverage ledger. Reconciled F19–F24/P16–P21 and T4 evidence;
retained historical results without presenting them as current certification.
The queue starts at 22:00 Toronto and permits at most two active Claude runs;
it includes the complete reading list, owner decisions and staged Mac validation.

Fresh HelmCore build passed. Six-target portable XCTest suite: **1,198 tests,
zero failures/skips**. Static checks: **242 Swift files, zero errors**. Ledger:
**565 rows, zero gaps**, 408 planned / 84 drafted / 73 linux-tested; every named
test appears in the fresh passing log. Details and hashes: [VERIFICATION](VERIFICATION.md).

Open: Opus review, Mac SDK/host validation, native conditional mutation/receipts,
tree undo/redo, global ItemID policy and the deferred owner decisions in the queue.
No Swift, tests, scripts, manifest or legacy Helm files were edited; no network,
external action, commit or push. The explicitly requested prereview report path
conflicts with “own exactly docs/handoff/* and top-level README; do NOT edit other
docs”, so this report stays at `docs/handoff/fixes-F25.md`. Relocation into
`docs/prereview/` is left to the orchestrator with ownership of that directory.
