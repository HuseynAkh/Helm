<!-- DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04 -->
# Handoff integration notes

K30 owns only this directory. No source-directory README was written because source ownership belongs to K29. Start with [MAC_HANDOFF.md](MAC_HANDOFF.md) for the actual module layout, unverified Apple SDK inventory, integration gaps, M0–M26 status and pasteable Mac review prompt. [VERIFICATION.md](VERIFICATION.md) records fresh K30 checks separately from historical F1–F4 results. [CONTRACT_INTEGRATION.md](CONTRACT_INTEGRATION.md) contains the K23 decision record plus K29’s concurrent addendum, preserved without K30 edits.

The generated [coverage ledger](coverage-ledger.csv) is a citation inventory, not a parity or gate closure. Its required CSV header is preserved; every data row carries the DRAFT label. Regenerate only against a complete passing XCTest log and the externally supplied current plan catalogues. Counts can change as K29/T1 finish; freeze revision plus dirty diff and rerun checks before Mac review.

Open questions/deviations: native host/executable/manifest ownership; per-window journal association; review of K29 nested rename and column request public contracts; complete descendant evidence for safe inverse tree retirement; launch/Starred/view-mode policies. See the handoff gap table for exact sources. No Apple SDK or runtime behavior is validated by Linux parsing/testing. Mac fixture effects remain subject to the owner's exact-action approval rule. No network, commit, push, publish/send, paid render or sharing change is part of K30.
