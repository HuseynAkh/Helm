# Handoff notes

Start at [MAC_HANDOFF.md](MAC_HANDOFF.md). Prompt: [MAC_CLAUDE_PROMPT.md](MAC_CLAUDE_PROMPT.md). Code pin 1c4f3fe; docs commit follows.

## Mac steps for Huseyn

These are Huseyn's own steps; Mac Claude does none of them. Pasting the block authorizes tests to remove only their own temp fixtures.

1. Push `forge/rebuild-build`.
2. Clone with the branch named, because the default branch `main` is legacy and has no handoff:
   `git clone --branch forge/rebuild-build https://github.com/HuseynAkh/Helm.git Helm-rebuild`
3. `cd Helm-rebuild`, start Claude Code, paste the block.

Optional: to pre-authorize Darwin-only portable-module compile fixes, add this exact line to the prompt; otherwise S3 requires stopping and reporting:

`Also compile-fix Darwin-only branches of portable modules, no contract changes.`

Historical (F25): Read the [Opus/Fable queue](REVIEW_QUEUE.md): P1–P21, R1, fixes-F1–F24 and
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
Permissions for the Mac run are only those in MAC_CLAUDE_PROMPT.md.
