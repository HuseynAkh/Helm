<!-- DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04 -->
# K15 integration notes

K15 adds audit-driven XCTest coverage in the four owned test directories. Run with
`source /workspace/toolchains/env.sh`, then
`swift test --scratch-path /tmp/build-K15 --filter K15`.

The tests use seeded generators for tab navigation, an independent history model,
window membership, clipboard acknowledgment, and copy/move plans. Executor tests
inject failure and cancellation at every boundary of five-item creation plans,
and failure at every primitive of six-step replacement moves. Undo checks retain
copies in Trash. Completion cancellation uses actor/continuation handshakes without
wall-clock sleeps. Folder tests cover 25,000 entries, batch boundaries, symlink
loops, canonical Unicode collisions, and path normalization. Completion tests
cover 50 children plus the separate parent row, and sorting before the cap.

`docs/test-findings/K15-findings.md` records source bugs and named skipped regressions.
The files remain drafts for Opus review after 22:00 Toronto on 2026-11-04.

Deviation: this README lives in the owned test directory because K15 may not edit
Sources. Tests inspect payload sizes and retained identities; the in-memory FS has
no byte-reading API, so this is not a content-hash integrity proof. Linux tests do
not establish macOS filesystem, AppKit focus, or native Trash correctness. Native
macOS validation remains open. The filesystem fake normalizes Unicode even when
case-sensitive; tests intentionally document that fake contract.
