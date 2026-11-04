<!-- DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04 -->
# F5 integration notes

IOExecutor preserves bounded, per-volume blocking work for B-107. Its executor lock
serializes request registration, queued-to-running admission, and timeout quarantine.
A timeout rejects every registered request that has not started. Already-running
requests retain their actual result unless their own deadline expires. Cancellation
before continuation installation is retained; cancellation after begin cannot erase
a successful primitive. Lock order is executor then result state; cancellation takes
only the result-state lock. Continuations resume after releasing the result-state lock.

A timed-out native call can still finish. The caller must reconcile uncertain mutations;
quarantine lasts for this executor's lifetime. Native macOS execution and Opus review
remain open. No attempt is made to interrupt a kernel call or recreate a hung queue.
The internal result state is test-visible for deterministic cancellation-before-install
coverage; public API is unchanged.

Related F5 changes: composite tag writes check cancellation before primary/fallback
entry, but preserve a successful write; the existing all-origin Put Back validation
now runs its T1 regression without an environment gate. Planner and journal internal
work diagnostics exercise production paths without elapsed-time assertions.

Portable UI tests require an explicitly built scratch directory:
`HELM_UI_SCRATCH=/tmp/build-F5 python3 -B Tests/HelmUITests/PortableRunner/run.py`.
The runner validates dependency modules/objects and uses the same root for compile,
link, runtime lookup, and subprocess typechecking. No manifest or script changes.

Deviations and verification details are recorded in `docs/prereview/fixes-F5.md`.
