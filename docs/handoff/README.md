<!-- DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04 -->
# Handoff integration notes — F25 / through wave 24

Read the [Opus/Fable queue](REVIEW_QUEUE.md): P1–P21, R1, fixes-F1–F24 and
all test-findings reports. Latest committed baseline: `0021ac6`, wave 24;
**1,198 portable tests, zero failures/skips** in F23/F24 logs. The separate T4
five-run serial evidence covers 1,185 tests, not five passes of wave 24.

[MAC_HANDOFF.md](MAC_HANDOFF.md) inventories native gaps and the latest fixes.
[VERIFICATION.md](VERIFICATION.md) records F25 execution evidence and the refreshed
[565-row ledger](coverage-ledger.csv). Citations do not establish feature acceptance.
Earlier F22/K41 counts and hashes are retained as historical evidence only.

[CONTRACT_INTEGRATION.md](CONTRACT_INTEGRATION.md) describes exact-plan history
binding, pre-binding aborts, session teardown and byte-preserving path admission.
Live executor copy/move/Trash still refuse conditional mutations. Native host,
Mac SDK validation, safe redo and broader ItemID identity policy remain open.

The [F25 disposition](fixes-F25.md) is kept in this owned directory because the
requested `docs/prereview/fixes-F25.md` is outside the explicit lane boundary.
No network, external actions, commits or pushes are authorized by this handoff.
