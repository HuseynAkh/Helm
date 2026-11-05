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

## F7 multi-volume admission

Native copy, move, replacement, metadata transfer and alias creation register all
source/destination/backup volumes with one IOExecutor admission lock. Worker queue
selection stays independent of the safety footprint. Timeout quarantines every
registered volume; admission checks every volume before registration and again
before body entry. Unrelated volumes remain available. The existing single-volume
public run API remains source-compatible; the multi-volume overload is internal.
Symbolic-link creation only writes its link directory and does not access its target.

Share this LiveFileSystem/IOExecutor across windows. Quarantine remains per executor,
not a process-global mount registry; do not recreate it to bypass reconciliation.
Native macOS cross-volume completion and alias writes still require acceptance.

K34: entry metadata now includes optional no-follow device/inode identity.
mutationPrecondition returns identity/kind/change evidence; inode reuse means this
observation is not an authorization token. LiveFileSystem deliberately inherits
FileSystem's unsupported conditional-mutation default: portable POSIX supplies no
atomic compare-source-identity + exclusive destination mutation. Native direct
primitive APIs remain available for explicit callers, but OperationExecutor now
refuses copy/move/Trash through this provider with verificationUnavailable. A
reviewed native provider is needed to enable these operations safely. Do not
implement the conditional API as a metadata read followed by a pathname mutation.
